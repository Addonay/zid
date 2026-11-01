//! Onboarding page, after Zed's `crates/onboarding` (`onboarding.rs`, `basics_page.rs`,
//! `theme_preview.rs`). A workspace item: its tab stays in the pane until closed or
//! finished, and it can be active or inactive like a document tab.
//!
//! Layout follows Zed: a 780px-max column with `p_12` padding, a header (logo, title,
//! italic tagline, `Finish Setup` with its keybinding), a divider, then the basics
//! sections separated by `gap_6`. The title names Zid; the logo and tagline are Zed's.
//!
//! Omitted while AI features and telemetry do not exist in Zid: Agent Setup and the
//! two telemetry switches. Import Settings and keyboard focus traversal
//! (`menu::SelectNext/Previous` between controls) are not implemented; the import
//! buttons say so. Vim mode and project trust only persist their settings.
const std = @import("std");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const config = @import("../config.zig");
const theme_mod = @import("../theme.zig");
const Theme = theme_mod.Theme;
const Color = [4]u8;
const icons = @import("icons");
const BaseKeymap = @import("keymap_assets").BaseKeymap;

const max_width: f32 = 780;
const padding: f32 = 48; // p_12
const tile_h: f32 = 100;

/// Zed `LIGHT_THEMES`, `DARK_THEMES`, `FAMILY_NAMES`.
const families = [_]struct { name: []const u8, light: []const u8, dark: []const u8, light_id: theme_mod.ThemeName, dark_id: theme_mod.ThemeName }{
    .{ .name = "One", .light = "One Light", .dark = "One Dark", .light_id = .one_light, .dark_id = .one_dark },
    .{ .name = "Ayu", .light = "Ayu Light", .dark = "Ayu Dark", .light_id = .ayu_light, .dark_id = .ayu },
    .{ .name = "Gruvbox", .light = "Gruvbox Light", .dark = "Gruvbox Dark", .light_id = .gruvbox_light, .dark_id = .gruvbox },
};
const modes = [_]struct { label: []const u8, mode: config.ThemeMode }{
    .{ .label = "Light", .mode = .light },
    .{ .label = "Dark", .mode = .dark },
    .{ .label = "System", .mode = .system },
};
/// Zed `render_base_keymap_section`: two rows of four.
const keymaps = [_]struct { label: []const u8, icon: []const u8, value: BaseKeymap }{
    .{ .label = "Zed", .icon = "ui:ai_zed", .value = .Zed },
    .{ .label = "VS Code", .icon = "ui:editor_vs_code", .value = .VSCode },
    .{ .label = "JetBrains", .icon = "ui:editor_jet_brains", .value = .JetBrains },
    .{ .label = "Sublime Text", .icon = "ui:editor_sublime", .value = .SublimeText },
    .{ .label = "Atom", .icon = "ui:editor_atom", .value = .Atom },
    .{ .label = "Emacs", .icon = "ui:editor_emacs", .value = .Emacs },
    .{ .label = "Cursor", .icon = "ui:editor_cursor", .value = .Cursor },
    .{ .label = "TextMate", .icon = "ui:keyboard", .value = .TextMate },
};
const imports = [_][]const u8{ "VS Code", "Cursor" };

pub const Target = union(enum) { finish, mode: usize, tile: usize, keymap: usize, import: usize, vim, trust, welcome: usize, return_to_onboarding };
/// The page item shows Zed's Onboarding page or, after `onboarding::Finish`, its
/// Welcome page (`welcome.zig`), in the same tab slot as Zed's `go_to_welcome_page`.
pub const Kind = enum {
    onboarding,
    welcome,
    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .onboarding => "Onboarding",
            .welcome => "Welcome",
        };
    }
    /// GPUI key context of the page.
    pub fn context(self: Kind) []const u8 {
        return switch (self) {
            .onboarding => "Onboarding",
            .welcome => "Welcome",
        };
    }
};
const Hit = struct { target: Target, rect: Rect };

pub const State = struct {
    kind: Kind = .onboarding,
    active: bool = true,
    scroll: f32 = 0,
    content_h: f32 = 0,
    /// [family][0 = light, 1 = dark], parsed on first draw.
    previews: ?[families.len][2]Theme = null,
    hits: [24]Hit = undefined,
    hit_count: usize = 0,
    /// Document count and active index when last seen; any change means another
    /// item was opened or activated, which takes the pane's focus from onboarding.
    doc_count: usize = 0,
    doc_active: usize = 0,

    pub fn addHit(self: *State, target: Target, rect: Rect) void {
        if (self.hit_count == self.hits.len) return;
        self.hits[self.hit_count] = .{ .target = target, .rect = rect };
        self.hit_count += 1;
    }
};

pub fn isActive(app: *const App) bool {
    return if (app.onboarding) |o| o.active else false;
}
pub fn activeKind(app: *const App) ?Kind {
    const state = app.onboarding orelse return null;
    return if (state.active) state.kind else null;
}
/// `zed::ShowWelcome`.
pub fn showWelcome(app: *App) void {
    activateItem(app);
    app.onboarding.?.kind = .welcome;
    app.onboarding.?.scroll = 0;
}
/// `zed::OpenOnboarding`: reuse the existing item or add one, and activate it.
pub fn openOnboarding(app: *App) void {
    activateItem(app);
    if (app.onboarding.?.kind != .onboarding) {
        app.onboarding.?.kind = .onboarding;
        app.onboarding.?.scroll = 0;
    }
}
/// Activates the page item (creating it as Onboarding if absent) without changing its page.
pub fn activateItem(app: *App) void {
    if (app.onboarding == null) app.onboarding = .{};
    app.onboarding.?.active = true;
    stamp(app);
    // The page reads the user's settings.json; `reloadConfig` keeps it fresh after writes.
    if (app.settings_document == null) app.settings_document = @import("../settings_document.zig").Document.load(app.gpa, app.io, app.config_root) catch |err| blk: {
        app.notice("settings.json: {s}", .{@errorName(err)});
        break :blk null;
    };
    app.keymap_editor_open = false;
    app.panel_focus = false;
    app.search_focused = false;
}
fn stamp(app: *App) void {
    const state = &(app.onboarding orelse return);
    state.doc_count = app.workspace.documents.items.len;
    state.doc_active = app.workspace.active;
}
/// Called once per frame before drawing.
pub fn sync(app: *App) void {
    const state = &(app.onboarding orelse return);
    if (state.active and (state.doc_count != app.workspace.documents.items.len or state.doc_active != app.workspace.active)) state.active = false;
    stamp(app);
}
pub fn close(app: *App) void {
    app.onboarding = null;
}
pub fn deactivate(app: *App) void {
    if (app.onboarding) |*o| o.active = false;
}

/// The current theme selection, decoded like Zed's `ThemeSelection`. A static
/// `"theme": "Name"` has no mode, so it follows the system appearance.
const Selection = struct { mode: config.ThemeMode, light: []const u8, dark: []const u8, static: bool };
fn selection(app: *App) Selection {
    var result: Selection = .{ .mode = .system, .light = "One Light", .dark = "One Dark", .static = false };
    const document = if (app.settings_document) |*d| d else return result;
    const value = document.get(&.{"theme"}) orelse return result;
    switch (value) {
        .string => |name| {
            result = .{ .mode = if (config.systemAppearance() == .light) .light else .dark, .light = name, .dark = name, .static = true };
        },
        .object => |object| {
            result.mode = config.themeMode(value);
            if (object.get("light")) |v| if (v == .string) {
                result.light = v.string;
            };
            if (object.get("dark")) |v| if (v == .string) {
                result.dark = v.string;
            };
        },
        else => {},
    }
    return result;
}
fn boolSetting(app: *App, path: []const []const u8) bool {
    const document = if (app.settings_document) |*d| d else return false;
    const value = document.get(path) orelse return false;
    return value == .bool and value.bool;
}

/// Zed writes through `update_settings_file`; Zid validates the whole file, saves it
/// and reloads, exactly as the Settings dialog does.
fn writeSetting(app: *App, path: []const []const u8, json: []const u8) !void {
    const Document = @import("../settings_document.zig").Document;
    var document = try Document.load(app.gpa, app.io, app.config_root);
    defer document.deinit();
    try document.setJson(path, json);
    _ = config.settingsFromDocument(app.gpa, &document) catch |err| {
        app.notice("Invalid setting: {s}", .{@errorName(err)});
        return;
    };
    try document.save(app.gpa, app.io, app.config_root);
    try app.reloadConfig();
    app.config_stamp = app.configurationStamp();
}
fn writeTheme(app: *App, mode: config.ThemeMode, light: []const u8, dark: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(app.gpa, .{ .mode = @tagName(mode), .light = light, .dark = dark }, .{});
    defer app.gpa.free(json);
    try writeSetting(app, &.{"theme"}, json);
}

pub fn click(app: *App, mx: f32, my: f32) !void {
    const state = &(app.onboarding orelse return);
    var target: ?Target = null;
    for (state.hits[0..state.hit_count]) |hit| if (hit.rect.contains(mx, my)) {
        target = hit.target;
        break;
    };
    try activate(app, target orelse return);
}
pub fn activate(app: *App, target: Target) !void {
    const current = selection(app);
    switch (target) {
        .finish => finish(app),
        // Zed `set_mode`: keep the light and dark names, change only the mode.
        .mode => |i| try writeTheme(app, modes[i].mode, current.light, current.dark),
        // Zed `write_theme_change`: System sets the whole family; Light/Dark set one side.
        .tile => |i| switch (current.mode) {
            .system => try writeTheme(app, .system, families[i].light, families[i].dark),
            .light => try writeTheme(app, .light, families[i].light, current.dark),
            .dark => try writeTheme(app, .dark, current.light, families[i].dark),
        },
        .keymap => |i| {
            const json = try std.json.Stringify.valueAlloc(app.gpa, @tagName(keymaps[i].value), .{});
            defer app.gpa.free(json);
            try writeSetting(app, &.{"base_keymap"}, json);
        },
        .import => |i| app.notice("Importing {s} settings is not implemented yet", .{imports[i]}),
        .vim => try writeSetting(app, &.{"vim_mode"}, if (boolSetting(app, &.{"vim_mode"})) "false" else "true"),
        .trust => try writeSetting(app, &.{ "session", "trust_all_worktrees" }, if (boolSetting(app, &.{ "session", "trust_all_worktrees" })) "false" else "true"),
        .welcome => |i| try @import("welcome.zig").run(app, i),
        // Zed dispatches `zed::OpenOnboarding`; Zid swaps the page back in place.
        .return_to_onboarding => openOnboarding(app),
    }
}
/// `onboarding::Finish`: Zed's `go_to_welcome_page` replaces Onboarding with the
/// Welcome page in the same pane slot.
pub fn finish(app: *App) void {
    showWelcome(app);
}
pub fn scroll(app: *App, dy: f32) !void {
    const state = &(app.onboarding orelse return);
    const area = try app.layout.rect(app.layout.editor);
    state.scroll = std.math.clamp(state.scroll + dy, 0, @max(0, state.content_h - area.h));
}

fn fade(color: Color, opacity: f32) Color {
    return .{ color[0], color[1], color[2], @intFromFloat(@as(f32, @floatFromInt(color[3])) * opacity) };
}
fn withAlpha(color: Color, alpha: f32) Color {
    return .{ color[0], color[1], color[2], @intFromFloat(255 * alpha) };
}
fn hovered(app: *const App, r: Rect) bool {
    return r.contains(app.mouse_x, app.mouse_y);
}

pub fn draw(app: *App) !void {
    const state = &(app.onboarding orelse return);
    const t = app.settings.theme;
    const area = try app.layout.rect(app.layout.editor);
    try app.fill(area, t.editor);
    if (state.kind == .welcome) {
        state.hit_count = 0;
        app.clip(area);
        defer app.renderer.setClip(null);
        try @import("welcome.zig").draw(app, state, area);
        try drawScrollbar(app, state, area);
        return;
    }
    if (state.previews == null) {
        var parsed: [families.len][2]Theme = undefined;
        for (families, 0..) |family, i| {
            parsed[i] = .{ try Theme.builtin(app.gpa, family.light_id), try Theme.builtin(app.gpa, family.dark_id) };
        }
        state.previews = parsed;
    }
    state.hit_count = 0;
    app.clip(area);
    defer app.renderer.setClip(null);

    const column = @min(max_width, area.w);
    const x = area.x + (area.w - column) / 2 + padding;
    const w = @max(0, column - padding * 2);
    const top = area.y + padding - state.scroll;
    var y = top;
    const r = &app.renderer;

    // Header: logo, headline and italic tagline; Finish Setup on the right.
    try drawLogo(app, x, y);
    try r.textHeadline("Welcome to Zid", x + 56, y + 19, t.text);
    try r.textSmallItalic("The editor for what's next", x + 56, y + 36, t.muted);
    {
        const button: Rect = .{ .x = x + w - 200, .y = y + 6, .w = 200, .h = 28 };
        try r.roundRect(button.x, button.y, button.w, button.h, 6, if (hovered(app, button)) t.element_hover else t.element_background);
        const label = "Finish Setup";
        var key_buf: [64]u8 = undefined;
        const key = finishKey(app, &key_buf);
        const gap: f32 = if (key.len > 0) 8 else 0;
        const total = r.widthUi(label) + gap + r.widthUi(key);
        const lx = button.x + (button.w - total) / 2;
        try r.textUi(label, lx, button.y + 19, t.text);
        if (key.len > 0) try r.textUi(key, lx + r.widthUi(label) + gap, button.y + 19, t.muted);
        state.addHit(.finish, button);
    }
    y += 68;
    try r.rect(x, y, w, 1, t.border_variant);

    // Theme: label, Light/Dark/System toggle group, three preview tiles.
    const current = selection(app);
    y += 26;
    try r.textUi("Theme", x, y + 19, t.text);
    {
        const group: Rect = .{ .x = x + w - 192, .y = y, .w = 192, .h = 28 };
        var rects: [modes.len]Rect = undefined;
        for (&rects, 0..) |*cell, i| cell.* = .{ .x = group.x + @as(f32, @floatFromInt(i)) * 64, .y = group.y, .w = 64, .h = group.h };
        const selected: usize = if (current.static) (if (current.mode == .light) 0 else 1) else @intFromEnum(current.mode);
        try drawSegments(app, group, &rects, selected);
        for (modes, rects, 0..) |mode, cell, i| {
            try r.textSmall(mode.label, cell.x + (cell.w - r.widthSmall(mode.label)) / 2, cell.y + 18, if (i == selected) t.accent else t.text);
            state.addHit(.{ .mode = i }, cell);
        }
    }
    y += 41;
    {
        const appearance = config.themeAppearance(current.mode, config.systemAppearance());
        const current_name = if (appearance == .light) current.light else current.dark;
        const tile_w = (w - 16) / 3;
        for (families, 0..) |family, i| {
            const tile: Rect = .{ .x = x + @as(f32, @floatFromInt(i)) * (tile_w + 8), .y = y, .w = tile_w, .h = tile_h };
            const name = if (appearance == .light) family.light else family.dark;
            const selected = std.mem.eql(u8, name, current_name);
            const previews = state.previews.?[i];
            try drawTile(app, tile, previews, appearance, current.mode == .system and !current.static, selected);
            try r.textSmall(family.name, tile.x + (tile.w - r.widthSmall(family.name)) / 2, tile.y + tile_h + 22, t.muted);
            state.addHit(.{ .tile = i }, tile);
        }
    }
    y += tile_h + 54;

    // Base keymap: outlined two-row toggle group across the column.
    try r.textUi("Base Keymap", x, y + 15, t.text);
    y += 28;
    {
        const row_h: f32 = 29;
        const group: Rect = .{ .x = x, .y = y, .w = w, .h = row_h * 2 };
        var rects: [keymaps.len]Rect = undefined;
        const cell_w = w / 4;
        for (&rects, 0..) |*cell, i| cell.* = .{ .x = x + @as(f32, @floatFromInt(i % 4)) * cell_w, .y = y + @as(f32, @floatFromInt(i / 4)) * row_h, .w = cell_w, .h = row_h };
        var selected: ?usize = null;
        for (keymaps, 0..) |k, i| if (k.value == app.settings.base_keymap) {
            selected = i;
        };
        try drawSegments(app, group, &rects, selected);
        for (keymaps, rects, 0..) |k, cell, i| {
            const on = selected == i;
            // `ToggleButtonWithIcon`: `IconSize::XSmall` icon, `gap_1p5`, `LabelSize::Small`.
            const content = 12 + 6 + r.widthSmall(k.label);
            const cx = cell.x + (cell.w - content) / 2;
            try r.icon(icons.svg(k.icon), cx, cell.y + (cell.h - 12) / 2, 12, if (on) t.accent else t.muted);
            try r.textSmall(k.label, cx + 18, cell.y + 18, if (on) t.accent else t.text);
            state.addHit(.{ .keymap = i }, cell);
        }
    }
    y += 58 + 29;

    // Import Settings: label and description with outlined-ghost buttons on the right.
    try r.textUi("Import Settings", x, y + 13, t.text);
    try r.textUi("Automatically pull your settings from other editors", x, y + 38, t.muted);
    {
        var bx = x + w;
        var i: usize = imports.len;
        while (i > 0) {
            i -= 1;
            const bw = r.widthSmall(imports[i]) + 16;
            bx -= bw;
            const button: Rect = .{ .x = bx, .y = y + 6, .w = bw, .h = 28 };
            try r.roundBox(button.x, button.y, button.w, button.h, 6, if (hovered(app, button)) t.ghost_element_hover else t.editor, t.border);
            try r.textSmall(imports[i], button.x + 8, button.y + 18, t.text);
            state.addHit(.{ .import = i }, button);
            bx -= 4;
        }
    }
    y += 72;

    // Switch fields.
    try drawSwitchField(app, state, .vim, "Vim Mode", "Coming from Neovim? Use our first-class implementation of Vim Mode", boolSetting(app, &.{"vim_mode"}), x, y, w, false);
    y += 72;
    try drawSwitchField(app, state, .trust, "Trust All Projects By Default", "Automatically mark all new projects as trusted to unlock all Zid's features", boolSetting(app, &.{ "session", "trust_all_worktrees" }), x, y, w, true);
    y += 48;

    state.content_h = y - top + padding * 2;
    try drawScrollbar(app, state, area);
}

fn finishKey(app: *App, buf: []u8) []const u8 {
    var path_buf: [6]@import("../keymap.zig").Context = undefined;
    var ext_buf: [16]u8 = undefined;
    const path = @import("../input/commands.zig").focusPath(app, &path_buf, &ext_buf);
    const chord = app.keymap.chordFor("onboarding::Finish", path) orelse return "";
    var writer: std.Io.Writer = .fixed(buf);
    chord.format(&writer) catch return "";
    return writer.buffered();
}

/// Zed's `VectorName::ZedLogo` at `rems(2.5)` (40px), in the default text colour.
fn drawLogo(app: *App, x: f32, y: f32) !void {
    try app.renderer.largeIcon(icons.svg("ui:zed_logo"), x, y, 40, app.settings.theme.text);
}

/// Zed `ToggleButtonGroupStyle::Outlined`: 1px border and inner dividers; the selected
/// segment uses `TintColor::Accent` (`info.background` fill, accent label).
fn drawSegments(app: *App, group: Rect, cells: []const Rect, selected: ?usize) !void {
    const t = app.settings.theme;
    const r = &app.renderer;
    try r.roundBox(group.x, group.y, group.w, group.h, 6, t.editor, t.border);
    for (cells, 0..) |cell, i| {
        const inner: Rect = .{ .x = cell.x + 1, .y = cell.y + 1, .w = cell.w - 2, .h = cell.h - 2 };
        if (selected == i) {
            try r.rect(inner.x, inner.y, inner.w, inner.h, t.info_background);
        } else if (hovered(app, cell)) try r.rect(inner.x, inner.y, inner.w, inner.h, t.element_hover);
        if (cell.x > group.x) try r.rect(cell.x, cell.y, 1, cell.h, t.border);
        if (cell.y > group.y) try r.rect(cell.x, cell.y, cell.w, 1, t.border);
    }
}

/// Zed `SwitchField`: title and description on the left, a switch on the right.
fn drawSwitchField(app: *App, state: *State, target: Target, title: []const u8, description: []const u8, on: bool, x: f32, y: f32, w: f32, info: bool) !void {
    const t = app.settings.theme;
    const r = &app.renderer;
    try r.textUi(title, x, y + 13, t.text);
    if (info) try r.icon(icons.svg("ui:info"), x + r.widthUi(title) + 6, y + 1, 12, t.muted);
    try r.textUi(description, x, y + 38, t.muted);
    const control: Rect = .{ .x = x + w - 34, .y = y + 11, .w = 32, .h = 18 };
    try r.roundBox(control.x, control.y, control.w, control.h, 9, if (on) t.accent else t.element_background, if (on) t.accent else t.border);
    try r.roundRect(if (on) control.x + control.w - 16 else control.x + 2, control.y + 2, 14, 14, 7, if (on) t.editor else t.muted);
    state.addHit(target, .{ .x = x, .y = y, .w = w, .h = 48 });
}

/// Zed `ThemePreviewTile`: an 8px-radius root with a 2px state border and 2px padding,
/// then a 1px theme border around an abstract editor (sidebar skeleton + code lines).
fn drawTile(app: *App, tile: Rect, themes: [2]Theme, appearance: config.Appearance, side_by_side: bool, selected: bool) !void {
    const t = app.settings.theme;
    const r = &app.renderer;
    const opacity: f32 = if (selected) 1 else 0.8;
    if (selected) {
        try r.roundRect(tile.x, tile.y, tile.w, tile.h, 8, t.border_selected);
        try r.roundRect(tile.x + 2, tile.y + 2, tile.w - 4, tile.h - 4, 6, t.editor);
    } else if (hovered(app, tile)) {
        try r.roundRect(tile.x, tile.y, tile.w, tile.h, 8, t.border);
        try r.roundRect(tile.x + 2, tile.y + 2, tile.w - 4, tile.h - 4, 6, t.editor);
    }
    const primary = if (side_by_side) themes[0] else themes[if (appearance == .light) 0 else 1];
    const frame: Rect = .{ .x = tile.x + 4, .y = tile.y + 4, .w = tile.w - 8, .h = tile.h - 8 };
    try r.roundRect(frame.x, frame.y, frame.w, frame.h, 4, fade(if (side_by_side) t.border else primary.border, opacity));
    const inner: Rect = .{ .x = frame.x + 1, .y = frame.y + 1, .w = frame.w - 2, .h = frame.h - 2 };
    const outer_clip = try app.layout.rect(app.layout.editor);
    app.clip(intersect(inner, outer_clip));
    defer app.clip(outer_clip);
    if (side_by_side) {
        try drawEditorSkeleton(app, inner, themes[0], 0.20, opacity);
        const half = inner.w / 2;
        app.clip(intersect(.{ .x = inner.x + half, .y = inner.y, .w = inner.w - half, .h = inner.h }, outer_clip));
        try drawEditorSkeleton(app, .{ .x = inner.x + half, .y = inner.y, .w = inner.w, .h = inner.h }, themes[1], 0.20, opacity);
    } else try drawEditorSkeleton(app, inner, primary, 0.25, opacity);
}
fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

const seed: f32 = 0xBEEF;
/// `render_editor`: background, sidebar (`p_2 gap_1`, eight 2px bars at 45% text
/// alpha) and a pane of ten pseudo-code lines coloured from the theme's syntax.
fn drawEditorSkeleton(app: *App, area: Rect, theme: Theme, sidebar_fraction: f32, opacity: f32) !void {
    const r = &app.renderer;
    try r.rect(area.x, area.y, area.w, area.h, fade(theme.background, opacity));
    const sidebar_w = area.w * sidebar_fraction;
    try r.rect(area.x, area.y, sidebar_w, area.h, fade(theme.panel, opacity));
    for (0..8) |index| {
        const value = @sin(seed * 1000.0 + @as(f32, @floatFromInt(index)) * 10.0) * 0.5 + 0.5;
        const bar_w = (sidebar_w - 16) * (0.5 + value * 0.45);
        try r.roundRect(area.x + 8, area.y + 8 + @as(f32, @floatFromInt(index)) * 6, bar_w, 2, 1, fade(withAlpha(theme.text, 0.45), opacity));
    }
    const pane: Rect = .{ .x = area.x + sidebar_w, .y = area.y, .w = area.w - sidebar_w, .h = area.h };
    try r.rect(pane.x, pane.y, pane.w, pane.h, fade(theme.editor, opacity));
    const kinds = [_]@import("zid").syntax.Kind{ .keyword, .function, .string, .plain, .type, .punctuation, .comment };
    const inner_w = pane.w - 24;
    for (0..10) |line| {
        const fl: f32 = @floatFromInt(line);
        const blocks: usize = @as(usize, @intFromFloat(@round((@sin(seed * 30.0 + fl * 12.0) * 0.5 + 0.5) * 3.0))) + 2;
        const step = line % 6;
        const indent: f32 = if (step < 3) @as(f32, @floatFromInt(step)) * 0.1 else @as(f32, @floatFromInt(5 - step)) * 0.1;
        var bx = pane.x + 12 + inner_w * indent;
        const by = pane.y + 12 + fl * 8;
        for (0..blocks) |block| {
            const fb: f32 = @floatFromInt(block);
            const width = 0.05 + (@sin(seed * 100.0 + fl * 20.0 + fb * 5.0) * 0.5 + 0.5) * 0.2;
            const pick: usize = @as(usize, @intFromFloat(@abs(@sin(seed * 10.0 + fl * 7.0 + fb * 3.0) * 3.5))) % kinds.len;
            const color = if (kinds[pick] == .plain) theme.editor_foreground else theme.syntaxColor(kinds[pick]);
            const bw = inner_w * width;
            try r.roundRect(bx, by, bw, 2, 1, fade(color, opacity));
            bx += bw + 2;
        }
    }
}

fn drawScrollbar(app: *App, state: *const State, area: Rect) !void {
    if (state.content_h <= area.h) return;
    const t = app.settings.theme;
    const thumb_h = @max(25, area.h * area.h / state.content_h);
    const travel = area.h - thumb_h;
    const thumb_y = area.y + travel * (state.scroll / (state.content_h - area.h));
    try app.renderer.roundRect(area.x + area.w - 10, thumb_y, 6, thumb_h, 3, t.scrollbar_thumb);
}

/// Zed shows onboarding when the `first_open` key is unset and then writes it
/// (`show_onboarding_view`). Zid keeps the same marker as a file in its data
/// directory.
pub fn showOnFirstOpen(app: *App) void {
    const path = std.fs.path.join(app.gpa, &.{ app.data_dir, "first_open" }) catch return;
    defer app.gpa.free(path);
    if (std.Io.Dir.cwd().statFile(app.io, path, .{})) |_| return else |err| if (err != error.FileNotFound) return;
    activateItem(app);
    std.Io.Dir.cwd().createDirPath(app.io, app.data_dir) catch return;
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = "false" }) catch |err| std.log.warn("onboarding marker: {s}", .{@errorName(err)});
}
