//! One responsibility per view/controller; application owns retained state.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const syntax = zid.syntax;
const max_line_bytes = 64 * 1024;
pub fn event(self: *App, e: sdl.events.Event) !void {
    const doc = self.workspace.current();
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
        .quit, .window_close_requested => try self.action(.quit),
        .key_down => |key_event| {
            self.suppress_choice_text = false;
            const key = key_event.key orelse return;
            self.caret_visible = true;
            self.last_blink = sdl.timer.getMillisecondsSinceInit();
            if (self.dialog != .none) {
                try self.dialogKey(key);
                return;
            }
            const keys = if (self.bindings) |p| p.value else &config.defaults;
            for (keys) |binding| if (bindingMatches(binding, key, key_event.mod)) {
                try self.action(binding.action);
                return;
            };
            // User bindings override defaults without erasing unrelated shortcuts.
            if (self.bindings != null) for (config.defaults) |binding| if (bindingMatches(binding, key, key_event.mod)) {
                try self.action(binding.action);
                return;
            };
            const extend = (key_event.mod.left_shift or key_event.mod.right_shift);
            if (self.panel_focus) {
                switch (key) {
                    .up => self.panel_row -|= 1,
                    .down => self.panel_row = @min(self.panel_row + 1, self.visible.items.len -| 1),
                    .return_key, .right => try self.activateProject(),
                    .escape => self.panel_focus = false,
                    else => {},
                }
                self.keepPanelVisible();
                return;
            }
            switch (key) {
                .left => doc.move(doc.buffer.previous(doc.cursor), extend),
                .right => doc.move(doc.buffer.next(doc.cursor), extend),
                .up => doc.moveVertical(-1, extend),
                .down => doc.moveVertical(1, extend),
                .page_up => doc.moveVertical(-@as(i32, @intCast(self.pageLines())), extend),
                .page_down => doc.moveVertical(@intCast(self.pageLines()), extend),
                .home => doc.move(if ((key_event.mod.left_control or key_event.mod.right_control)) 0 else doc.lines.items[doc.lineOf(doc.cursor)], extend),
                .end => doc.move(if ((key_event.mod.left_control or key_event.mod.right_control)) doc.buffer.len() else doc.lineEnd(doc.lineOf(doc.cursor)), extend),
                .backspace => try doc.backspace(),
                .delete => try doc.deleteForward(),
                .return_key => try doc.insert(if (doc.crlf) "\r\n" else "\n"),
                .tab => try doc.insert("                "[0..self.settings.tab_size]),
                else => {},
            }
            try self.revealCursor();
        },
        .text_input => |input| {
            if (self.suppress_choice_text) {
                self.suppress_choice_text = false;
                return;
            }
            const text = input.text;
            if (self.dialog == .open or self.dialog == .save) try self.path_input.appendSlice(self.gpa, text) else if (self.dialog == .none and !self.panel_focus) {
                try doc.insert(text);
                try self.revealCursor();
            }
            self.caret_visible = true;
            self.last_blink = sdl.timer.getMillisecondsSinceInit();
        },
        .mouse_button_down => |button| if (button.button == .left) {
            self.pointer_down = true;
            self.mouse_x = button.x;
            self.mouse_y = button.y;
            try self.click(button.x, button.y, button.clicks);
        },
        .mouse_button_up => {
            self.pointer_down = false;
            self.dragging = false;
            sdl.mouse.capture(false) catch {};
        },
        .mouse_motion => |motion| {
            self.mouse_x = motion.x;
            self.mouse_y = motion.y;
            if (self.dragging) try self.placeCursor(motion.x, motion.y, true);
        },
        .mouse_wheel => |wheel| {
            const mx = wheel.x;
            const my = wheel.y;
            const panel = try self.layout.rect(self.layout.panel);
            const delta: i64 = @intFromFloat(-wheel.scroll_y * 3);
            if (panel.contains(mx, my)) self.panel_scroll = @intCast(std.math.clamp(@as(i64, @intCast(self.panel_scroll)) + delta, 0, @as(i64, @intCast(self.visible.items.len -| 1)))) else {
                doc.scroll_line = @intCast(std.math.clamp(@as(i64, @intCast(doc.scroll_line)) + delta, 0, @as(i64, @intCast(doc.lines.items.len -| 1))));
                doc.scroll_x = @max(0, doc.scroll_x - wheel.scroll_x * 30);
            }
        },
        .drop_file => |drop| {
            try self.workspace.open(drop.file_name);
            self.panel_focus = false;
        },
        else => {},
    }
}
pub fn bindingMatches(binding: config.Binding, key: ?sdl.keycode.Keycode, mods: sdl.keycode.KeyModifier) bool {
    var parts = std.mem.splitScalar(u8, binding.key, '+');
    var ctrl = false;
    var shift = false;
    var alt = false;
    var name: []const u8 = "";
    while (parts.next()) |p| {
        if (std.ascii.eqlIgnoreCase(p, "Ctrl")) ctrl = true else if (std.ascii.eqlIgnoreCase(p, "Shift")) shift = true else if (std.ascii.eqlIgnoreCase(p, "Alt")) alt = true else name = p;
    }
    if (ctrl != ((mods.left_control or mods.right_control)) or shift != ((mods.left_shift or mods.right_shift)) or alt != ((mods.left_alt or mods.right_alt))) return false;
    var buffer: [64]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buffer, "{s}", .{name}, 0) catch return false;
    return key == (sdl.keyboard.getKeyFromName(z) catch return false);
}
pub fn ctrlHeld() bool {
    const m = sdl.keyboard.getModState();
    return m.left_control or m.right_control;
}
pub fn shiftHeld() bool {
    const m = sdl.keyboard.getModState();
    return m.left_shift or m.right_shift;
}
