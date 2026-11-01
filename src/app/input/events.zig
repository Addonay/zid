//! One responsibility per view/controller; application owns retained state.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const syntax = zid.syntax;
const max_line_bytes = 64 * 1024;
const settings_dialog = @import("../views/settings_dialog.zig");
const keymap = @import("../keymap.zig");
const commands = @import("commands.zig");
const modals = @import("../views/modals.zig");
const onboarding = @import("../views/onboarding.zig");
/// Settings lives in its own window when `settings_window` is set.
fn settingsWindowed(self: *App) bool {
    return self.dialog == .settings and self.settings_window != null;
}
/// Routes events tagged with the settings window id to the settings view; the
/// main window keeps behaving normally while the settings window is open.
fn settingsEvent(self: *App, e: sdl.events.Event) !bool {
    const sw = if (self.settings_window) |*sw| sw else return false;
    const swid = sw.getId() catch return false;
    const eid: ?sdl.video.WindowId = switch (e) {
        .key_down => |v| v.window_id,
        .text_input => |v| v.window_id,
        .mouse_button_down => |v| v.window_id,
        .mouse_button_up => |v| v.window_id,
        .mouse_motion => |v| v.window_id,
        .mouse_wheel => |v| v.window_id,
        .window_focus_gained => |v| v.id,
        .window_focus_lost => |v| v.id,
        .window_close_requested => |v| v.id,
        else => null,
    };
    if (eid == null or eid.? != swid) return false;
    self.settings_dirty = true;
    switch (e) {
        .window_close_requested => self.closeSettings(),
        .window_focus_gained => {
            self.focused = true;
            self.caret_visible = true;
        },
        .window_focus_lost => {
            self.focused = false;
            self.caret_visible = false;
        },
        .key_down => |kev| {
            self.suppress_choice_text = false;
            self.caret_visible = true;
            self.last_blink = sdl.timer.getMillisecondsSinceInit();
            if (kev.key) |key| try settings_dialog.handleKey(self, key);
        },
        .text_input => |input| {
            settings_dialog.typeText(self, input.text);
            self.caret_visible = true;
            self.last_blink = sdl.timer.getMillisecondsSinceInit();
        },
        .mouse_button_down => |button| if (button.button == .left) {
            self.mouse_x = button.x;
            self.mouse_y = button.y;
            try settings_dialog.handleClick(self, button.x, button.y);
        },
        .mouse_motion => |motion| {
            self.mouse_x = motion.x;
            self.mouse_y = motion.y;
        },
        .mouse_wheel => |wheel| settings_dialog.scroll(self, -wheel.scroll_y * 64),
        else => {},
    }
    return true;
}
pub fn event(self: *App, e: sdl.events.Event) !void {
    const doc = self.workspace.currentOrNull();
    if (try settingsEvent(self, e)) return;
    switch (e) {
        .window_focus_gained => {
            self.focused = true;
            self.caret_visible = true;
        },
        .window_focus_lost => {
            self.focused = false;
            self.dragging = false;
            self.caret_visible = false;
        },
        .quit, .window_close_requested => try self.runCommand(.@"zed::Quit"),
        // "theme.mode": "system" follows the desktop; reload to pick the other side.
        .system_theme_changed => {
            @import("../config.zig").system_appearance = App.systemAppearanceFromSdl();
            try self.reloadConfig();
        },
        .key_down => |key_event| {
            self.suppress_choice_text = false;
            const key = key_event.key orelse return;
            self.caret_visible = true;
            self.last_blink = sdl.timer.getMillisecondsSinceInit();
            if (self.dialog != .none and !settingsWindowed(self)) {
                try self.dialogKey(key);
                return;
            }
            if (self.database.open) {
                @import("../database_view.zig").key(self, key, key_event.mod);
                return;
            }
            const instance = if (doc) |d| d.instance_id else 0;
            const revision = if (doc) |d| d.revision else 0;
            const cursor = if (doc) |d| d.cursor else 0;
            try dispatchKey(self, key, key_event.mod);
            const current = self.workspace.currentOrNull() orelse return;
            if (current.instance_id != instance or current.revision != revision or current.cursor != cursor) _ = self.dismissHover();
        },
        .key_up => |key_event| {
            // Zed's tab switcher confirms when the modifier that opened it is released.
            const key = key_event.key orelse return;
            if ((key == .left_ctrl or key == .right_ctrl) and self.modal == .picker and self.modal.picker.kind == .tab_switcher) try self.runCommand(.@"menu::Confirm");
        },
        .text_input => |input| {
            if (self.suppress_choice_text) {
                self.suppress_choice_text = false;
                return;
            }
            const text = input.text;
            if (self.database.open and self.dialog == .none) {
                self.database.input().insert(text);
                return;
            }
            if (commands.lineInput(self)) |line| {
                line.insert(text);
                try self.lineInputChanged();
            } else if (self.dialog == .settings) settings_dialog.typeText(self, text) else if (self.dialog == .open or self.dialog == .save) try self.path_input.appendSlice(self.gpa, text) else if ((self.dialog == .none or settingsWindowed(self)) and self.prompt == null and self.context_menu == null and !self.panel_focus and !onboarding.isActive(self)) {
                _ = self.dismissHover();
                const active = doc orelse return;
                try active.insert(text);
                try self.revealCursor();
            }
            self.caret_visible = true;
            self.last_blink = sdl.timer.getMillisecondsSinceInit();
        },
        .mouse_button_down => |button| if (button.button == .right) {
            self.mouse_x = button.x;
            self.mouse_y = button.y;
            _ = self.dismissHover();
            try @import("../menus.zig").rightClick(self, button.x, button.y);
        } else if (button.button == .left) {
            self.pointer_down = true;
            self.mouse_x = button.x;
            self.mouse_y = button.y;
            _ = self.dismissHover();
            try self.click(button.x, button.y, button.clicks);
        },
        .mouse_button_up => {
            if (self.panel_resizing) {
                self.panel_resizing = false;
                try self.saveAndApplySettings();
            }
            self.pointer_down = false;
            self.dragging = false;
            sdl.mouse.capture(false) catch {};
        },
        .mouse_motion => |motion| {
            self.mouse_x = motion.x;
            self.mouse_y = motion.y;
            @import("../views/context_menu.zig").hover(self, motion.x, motion.y);
            modals.hoverModal(self, motion.x, motion.y);
            // Hovering another name while an application menu is open switches menus.
            const title_bar = @import("../views/title_bar.zig");
            if (title_bar.appMenuOpen(self)) |open| if (title_bar.menuNameAt(self, motion.x, motion.y)) |index| {
                if (index != open) title_bar.openAppMenu(self, index);
            };
            if (self.panel_resizing) {
                const width = if (self.settings.panel_right) self.layout.width - motion.x else motion.x;
                self.settings.panel_width = @intFromFloat(std.math.clamp(width, 140, @min(600, self.layout.width * 0.8)));
                return;
            }
            if (self.dragging) {
                _ = self.dismissHover();
                try self.placeCursor(motion.x, motion.y, true);
            }
        },
        .mouse_wheel => |wheel| {
            const mx = wheel.x;
            const my = wheel.y;
            const panel = try self.layout.rect(self.layout.panel);
            const delta: i64 = @intFromFloat(-wheel.scroll_y * 3);
            if (self.hover_rect.contains(mx, my)) {
                self.hover_scroll = @intCast(std.math.clamp(@as(i64, @intCast(self.hover_scroll)) + delta, 0, 4096));
                return;
            }
            if (self.database.open) {
                if (self.database.table) |*table| {
                    if (ctrlHeld() or shiftHeld()) {
                        const columns = if (table.rows().len > 0) table.rows()[0].object.count() else 0;
                        self.database.column_scroll = @intCast(std.math.clamp(@as(i64, @intCast(self.database.column_scroll)) + delta, 0, @as(i64, @intCast(columns -| 1))));
                    } else self.database.scroll = @intCast(std.math.clamp(@as(i64, @intCast(self.database.scroll)) + delta, 0, @as(i64, @intCast(table.rows().len -| 1))));
                }
            } else if (self.dialog == .settings and self.settings_window == null) {
                settings_dialog.scroll(self, -wheel.scroll_y * 64);
            } else if (self.dialog != .none and self.dialog != .settings) {} else if (modals.scrollModal(self, -wheel.scroll_y)) {} else if (panel.contains(mx, my)) {
                self.panel_scroll = @intCast(std.math.clamp(@as(i64, @intCast(self.panel_scroll)) + delta, 0, @as(i64, @intCast(self.maxPanelScroll()))));
            } else if (self.keymap_editor_open) {
                modals.scrollKeymap(self, -wheel.scroll_y);
            } else if (onboarding.isActive(self)) {
                try onboarding.scroll(self, -wheel.scroll_y * 40);
            } else if (doc != null and doc.?.image) {
                try @import("../views/image_view.zig").scroll(self, doc.?, wheel.scroll_x, wheel.scroll_y, mx, my, ctrlHeld());
            } else {
                const active = doc orelse return;
                if (active.large) |*large| {
                    try large.moveLines(delta);
                    return;
                }
                active.scroll_line = @intCast(std.math.clamp(@as(i64, @intCast(active.scroll_line)) + delta, 0, @as(i64, @intCast(active.lineCount() -| 1))));
                active.scroll_x = @max(0, active.scroll_x - wheel.scroll_x * 30);
            }
        },
        .drop_file => |drop| {
            try self.workspace.open(drop.file_name);
            self.panel_focus = false;
        },
        else => {},
    }
}
/// Zed key name for an SDL keycode, or null for keys Zed's keymap doesn't name.
pub fn keyName(key: sdl.keycode.Keycode, buf: *[8]u8) ?[]const u8 {
    const raw: u32 = @intCast(@backingInt(key));
    switch (raw) {
        0x0d => return "enter",
        0x1b => return "escape",
        0x08 => return "backspace",
        0x09 => return "tab",
        0x20 => return "space",
        0x7f => return "delete",
        0x21...0x7e => {
            buf[0] = std.ascii.toLower(@intCast(raw));
            return buf[0..1];
        },
        else => {},
    }
    return switch (key) {
        .up => "up",
        .down => "down",
        .left => "left",
        .right => "right",
        .home => "home",
        .end => "end",
        .page_up => "pageup",
        .page_down => "pagedown",
        .insert => "insert",
        .application => "menu",
        .kp_enter => "enter",
        .func1 => "f1",
        .func2 => "f2",
        .func3 => "f3",
        .func4 => "f4",
        .func5 => "f5",
        .func6 => "f6",
        .func7 => "f7",
        .func8 => "f8",
        .func9 => "f9",
        .func10 => "f10",
        .func11 => "f11",
        .func12 => "f12",
        else => null,
    };
}

/// US-layout shifted symbol for `c` (Zed binds e.g. `ctrl-+` and `ctrl-?`).
fn shifted(c: u8) ?u8 {
    const from = "1234567890-=[]\\;',./`";
    const to = "!@#$%^&*()_+{}|:\"<>?~";
    const i = std.mem.indexOfScalar(u8, from, c) orelse return null;
    return to[i];
}

fn keystrokeFor(name: []const u8, mods: sdl.keycode.KeyModifier) keymap.Keystroke {
    var ks: keymap.Keystroke = .{
        .ctrl = mods.left_control or mods.right_control,
        .alt = mods.left_alt or mods.right_alt,
        .shift = mods.left_shift or mods.right_shift,
        .super = mods.left_gui or mods.right_gui,
    };
    @memcpy(ks.key_buf[0..name.len], name);
    ks.key_len = @intCast(name.len);
    return ks;
}

/// Resolves a key press through the keymap (chords, contexts, availability) and runs it.
fn dispatchKey(self: *App, key: sdl.keycode.Keycode, mods: sdl.keycode.KeyModifier) !void {
    var name_buf: [8]u8 = undefined;
    const name = keyName(key, &name_buf) orelse return;
    const primary = keystrokeFor(name, mods);
    // Alternative spelling for shifted symbols: shift-= is also "+".
    var alternate: ?keymap.Keystroke = null;
    if (primary.shift and name.len == 1) if (shifted(name[0])) |sym| {
        var alt = primary;
        alt.shift = false;
        alt.key_buf[0] = sym;
        alternate = alt;
    };
    const ran = try resolve(self, primary, alternate);
    const printable = name.len == 1 or std.mem.eql(u8, name, "space");
    // A handled printable key must not also insert its character.
    if (ran and printable and !primary.ctrl and !primary.alt) self.suppress_choice_text = true;
}

/// Replays comma-separated Zed keystrokes ("ctrl-p,text:main,down") through the real
/// dispatch path; used by `--screenshot --keys` for headless UI checks.
pub fn simulate(self: *App, spec: []const u8) !void {
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, "database")) {
            try self.click(self.layout.width - @import("../views/title_bar.zig").controlsInset(self) - 20, 17, 1);
            continue;
        }
        if (self.database.open and std.mem.eql(u8, token, "tab")) {
            @import("../database_view.zig").key(self, .tab, .{});
            continue;
        }
        if (self.database.open and std.mem.eql(u8, token, "enter")) {
            @import("../database_view.zig").key(self, .return_key, .{});
            continue;
        }
        // Explicit frame progression for asynchronous offscreen QA scripts.
        if (std.mem.startsWith(u8, token, "frames:")) {
            const count = try std.fmt.parseInt(u32, token["frames:".len..], 10);
            for (0..count) |_| {
                self.pollAsync();
                try self.draw();
            }
            continue;
        }
        // `click:X:Y` replays a left click at logical coordinates (offscreen QA).
        if (std.mem.startsWith(u8, token, "click:")) {
            var parts = std.mem.splitScalar(u8, token["click:".len..], ':');
            const x = try std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidSimulatedClick);
            const y = try std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidSimulatedClick);
            try self.draw();
            try self.click(x, y, 1);
            continue;
        }
        // `wait:MS` lets real time pass (tooltip delays, animations).
        if (std.mem.startsWith(u8, token, "wait:")) {
            sdl.timer.delayMilliseconds(try std.fmt.parseInt(u32, token["wait:".len..], 10));
            continue;
        }
        // `rclick:X:Y` right-clicks; `move:X:Y` moves the pointer (hover).
        if (std.mem.startsWith(u8, token, "rclick:") or std.mem.startsWith(u8, token, "move:")) {
            const right = std.mem.startsWith(u8, token, "rclick:");
            var parts = std.mem.splitScalar(u8, token[(if (right) "rclick:".len else "move:".len)..], ':');
            const x = try std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidSimulatedClick);
            const y = try std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidSimulatedClick);
            try self.draw();
            self.mouse_x = x;
            self.mouse_y = y;
            if (right) try @import("../menus.zig").rightClick(self, x, y) else {
                @import("../views/context_menu.zig").hover(self, x, y);
                modals.hoverModal(self, x, y);
                const title_bar = @import("../views/title_bar.zig");
                if (title_bar.appMenuOpen(self)) |open| if (title_bar.menuNameAt(self, x, y)) |index| {
                    if (index != open) title_bar.openAppMenu(self, index);
                };
            }
            continue;
        }
        if (std.mem.startsWith(u8, token, "text:")) {
            const text = token["text:".len..];
            if (self.dialog == .settings) settings_dialog.typeText(self, text) else if (self.database.open) self.database.input().insert(text) else if (commands.lineInput(self)) |line| {
                line.insert(text);
                try self.lineInputChanged();
            } else if (!self.panel_focus and !onboarding.isActive(self)) {
                if (self.workspace.currentOrNull()) |active| try active.insert(text);
            }
            continue;
        }
        if (self.dialog != .none and !settingsWindowed(self)) {
            const key: sdl.keycode.Keycode = if (std.mem.eql(u8, token, "enter")) .return_key else std.meta.stringToEnum(sdl.keycode.Keycode, token) orelse return error.UnsupportedSimulatedDialogKey;
            try self.dialogKey(key);
            continue;
        }
        const ks = try keymap.Keystroke.parse(token);
        _ = try resolve(self, ks, null);
    }
}

fn resolve(self: *App, primary: keymap.Keystroke, alternate: ?keymap.Keystroke) !bool {
    if (self.search_open and self.search_focused and self.replace_open and
        std.mem.eql(u8, primary.key(), "tab") and !primary.ctrl and !primary.alt and !primary.super)
    {
        self.replace_focused = !self.replace_focused;
        self.pending = .{};
        return true;
    }
    var path_buf: [6]keymap.Context = undefined;
    var ext_buf: [16]u8 = undefined;
    const path = commands.focusPath(self, &path_buf, &ext_buf);
    for ([_]?keymap.Keystroke{ primary, alternate }) |candidate| {
        const ks = candidate orelse continue;
        var typed = self.pending;
        if (typed.len == keymap.max_chord) typed = .{};
        typed.keys[typed.len] = ks;
        typed.len += 1;
        if (self.keymap.isPrefix(typed.slice(), path)) {
            self.pending = typed;
            return true;
        }
        if (try runMatches(self, typed.slice(), path)) {
            self.pending = .{};
            return true;
        }
    }
    // An unmatched chord continuation: drop the prefix and retry the key on its own.
    if (self.pending.len > 0) {
        self.pending = .{};
        return resolve(self, primary, alternate);
    }
    return false;
}

fn runMatches(self: *App, typed: []const keymap.Keystroke, path: []const keymap.Context) !bool {
    const matches = try self.keymap.exact(self.gpa, typed, path);
    defer self.gpa.free(matches);
    for (matches) |m| {
        // `null` disables the keystroke in this context (and shallower ones).
        const name = m.binding.action orelse return true;
        const c = commands.parse(name) orelse continue;
        if (!commands.available(self, c)) continue;
        try commands.run(self, c, m.binding.arg);
        return true;
    }
    return false;
}

pub fn ctrlHeld() bool {
    const m = sdl.keyboard.getModState();
    return m.left_control or m.right_control;
}
pub fn shiftHeld() bool {
    const m = sdl.keyboard.getModState();
    return m.left_shift or m.right_shift;
}
