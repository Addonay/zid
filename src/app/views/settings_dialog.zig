//! Settings dialog modelled on Zed's settings window (`crates/settings_ui`): a 226px navigation
//! sidebar with search, pages split into muted section headers, and rows with a title, a small
//! muted description and a right-aligned control (switch, number field, dropdown or button).
//!
//! Items are a static table; `layout` produces content rows once and both drawing and hit-testing
//! consume the same geometry, so the two can't drift apart.
const std = @import("std");
const sdl = @import("sdl3");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const icons = @import("icons");
const theme_mod = @import("../theme.zig");

pub const Page = enum { general, appearance, editor, panels, keymap };
const page_titles = [_][]const u8{ "General", "Appearance", "Editor", "Panels", "Keymap" };

const Kind = enum { toggle, number, dropdown, button };
const helpers = @import("../settings_helpers.zig");
const Id = helpers.Id;

const Item = struct { id: Id, page: Page, section: []const u8, title: []const u8, desc: []const u8, kind: Kind, button: []const u8 = "" };

const items = [_]Item{
    .{ .id = .open_file, .page = .general, .section = "Configuration", .title = "Settings File", .desc = "Open settings.json in an editor tab", .kind = .button, .button = "Edit in settings.json" },
    .{ .id = .reload, .page = .general, .section = "Configuration", .title = "Reload Configuration", .desc = "Re-read settings.json and keymap.json from disk", .kind = .button, .button = "Reload" },
    .{ .id = .theme, .page = .appearance, .section = "Theme", .title = "Theme", .desc = "The color theme for the editor and UI", .kind = .dropdown },
    .{ .id = .icon_theme, .page = .appearance, .section = "Theme", .title = "Icon Theme", .desc = "File and folder icons in the project panel and tabs", .kind = .dropdown },
    .{ .id = .font_size, .page = .appearance, .section = "Buffer Font", .title = "Font Size", .desc = "Font size for editor text, in pixels", .kind = .number },
    .{ .id = .line_height, .page = .appearance, .section = "Buffer Font", .title = "Line Height", .desc = "Height of each buffer line, in pixels", .kind = .number },
    .{ .id = .tab_size, .page = .editor, .section = "Indentation", .title = "Tab Size", .desc = "Number of spaces inserted for a tab", .kind = .number },
    .{ .id = .cursor_blink, .page = .editor, .section = "Cursor", .title = "Cursor Blink", .desc = "Whether the cursor blinks in the editor", .kind = .toggle },
    .{ .id = .panel_width, .page = .panels, .section = "Project Panel", .title = "Default Width", .desc = "Width of the project panel, in pixels", .kind = .number },
    .{ .id = .auto_fold_dirs, .page = .panels, .section = "Project Panel", .title = "Auto Fold Directories", .desc = "Show single-child directory chains as one compact entry", .kind = .toggle },
    .{ .id = .open_keymap, .page = .keymap, .section = "Keybindings", .title = "Keymap Editor", .desc = "Browse and search every keybinding (Zed default keymap plus keymap.json)", .kind = .button, .button = "Open Keymap" },
    .{ .id = .open_keymap_file, .page = .keymap, .section = "Keybindings", .title = "Keymap File", .desc = "Edit keymap.json (Zed format; later entries override defaults)", .kind = .button, .button = "Edit keymap.json" },
    .{ .id = .indent_guides, .page = .panels, .section = "Project Panel", .title = "Indent Guides", .desc = "Show indent guides in the project panel", .kind = .toggle },
};

pub const theme_list = [_]struct { id: theme_mod.ThemeName, label: []const u8 }{
    .{ .id = .one_dark, .label = "One Dark" },
    .{ .id = .one_dark_pro_glass, .label = "One Dark Pro Glass" },
    .{ .id = .ayu, .label = "Ayu Dark" },
    .{ .id = .gruvbox, .label = "Gruvbox Dark" },
    .{ .id = .solarized, .label = "Solarized Dark" },
    .{ .id = .tokyo_night, .label = "Tokyo Night" },
    .{ .id = .catppuccin, .label = "Catppuccin Mocha" },
    .{ .id = .vscode, .label = "Dark Modern (VS Code)" },
};

// Geometry (Zed: SIDEBAR_WIDTH 226, sidebar p_2p5, search h_7, content px_8).
const sidebar_w: f32 = 226;
const sidebar_pad: f32 = 10;
const search_h: f32 = 28;
const nav_row_h: f32 = 26;
const nav_footer_h: f32 = 32;
const content_pad_x: f32 = 32;
const content_pad_top: f32 = 20;
const title_h: f32 = 44;
const header_h: f32 = 40;
const item_h: f32 = 60;
const binding_h: f32 = 32;
const control_h: f32 = 26;
const radius: f32 = 4;
const max_rows = 96;

const RowKind = union(enum) { title: Page, header: []const u8, item: usize };
const Row = struct { kind: RowKind, y: f32, h: f32 };
const Layout = struct {
    rows: [max_rows]Row = undefined,
    len: usize = 0,
    height: f32 = 0,
    fn slice(self: *const Layout) []const Row {
        return self.rows[0..self.len];
    }
    fn push(self: *Layout, kind: RowKind, h: f32) void {
        if (self.len == max_rows) return;
        self.rows[self.len] = .{ .kind = kind, .y = self.height, .h = h };
        self.len += 1;
        self.height += h;
    }
};

pub fn open(self: *App) void {
    self.dialog = .settings;
    self.settings_row = 0;
    self.settings_scroll = 0;
    self.settings_dropdown = false;
    self.settings_focus = .search;
    self.settings_editing_number = false;
}

fn query(self: *App) []const u8 {
    return self.settings_query[0..self.settings_query_len];
}

fn matches(item: Item, q: []const u8) bool {
    if (q.len == 0) return true;
    const path: ?[]const u8 = switch (item.id) {
        .theme => "theme_name",
        .auto_fold_dirs => "auto_fold_dirs",
        .open_keymap, .open_keymap_file, .open_file, .reload => null,
        else => @tagName(item.id),
    };
    return @import("../settings_search.zig").score(.{
        .title = item.title,
        .description = item.desc,
        .section = item.section,
        .page = page_titles[@backingInt(item.page)],
        .jsonpath = path,
    }, q) != null;
}

fn currentPage(self: *App) Page {
    return @fromBackingInt(@intCast(@min(self.settings_category, page_titles.len - 1)));
}

/// Content rows: the active page, or every matching item grouped by page while searching.
fn layout(self: *App) Layout {
    var out: Layout = .{};
    const q = query(self);
    for (0..page_titles.len) |p| {
        const page: Page = @fromBackingInt(@intCast(p));
        if (q.len == 0 and page != currentPage(self)) continue;
        var titled = false;
        var section: []const u8 = "";
        for (items, 0..) |item, i| {
            if (item.page != page or !matches(item, q)) continue;
            if (!titled) out.push(.{ .title = page }, title_h);
            titled = true;
            if (!std.mem.eql(u8, section, item.section)) out.push(.{ .header = item.section }, header_h);
            section = item.section;
            const width = @max(1, contentRect(dialogRect(self)).w - 2 * content_pad_x);
            const stacked = width < controlWidth(self, item) + 180;
            const desc_width = if (stacked) width else @max(1, width - controlWidth(self, item) - 12);
            out.push(.{ .item = i }, helpers.height(helpers.lineCount(item.desc, desc_width, self, measureSmall), stacked));
        }
    }
    return out;
}

/// Items in display order; the keyboard focus (`settings_row`) indexes this list.
fn focusable(lay: *const Layout, buf: *[items.len]usize) []usize {
    var n: usize = 0;
    for (lay.slice()) |row| if (row.kind == .item) {
        buf[n] = row.kind.item;
        n += 1;
    };
    return buf[0..n];
}

fn focusedItem(self: *App, lay: *const Layout) ?usize {
    var buf: [items.len]usize = undefined;
    const list = focusable(lay, &buf);
    if (list.len == 0) return null;
    return list[@min(self.settings_row, list.len - 1)];
}

// ---------------------------------------------------------------- geometry

pub fn dialogRect(self: *App) Rect {
    const w = @max(1, @min(920, self.layout.width - 48));
    const h = @max(1, @min(640, self.layout.height - 48));
    return .{ .x = @round((self.layout.width - w) / 2), .y = @round((self.layout.height - h) / 2), .w = w, .h = h };
}
fn contentRect(r: Rect) Rect {
    return .{ .x = r.x + sidebar_w, .y = r.y + 1, .w = r.w - sidebar_w - 1, .h = r.h - 2 };
}
fn searchRect(r: Rect) Rect {
    return .{ .x = r.x + sidebar_pad, .y = r.y + sidebar_pad, .w = sidebar_w - 2 * sidebar_pad, .h = search_h };
}
fn closeRect(r: Rect) Rect {
    return .{ .x = r.x + r.w - 34, .y = r.y + 10, .w = 24, .h = 24 };
}
fn rowRect(self: *App, c: Rect, row: Row) Rect {
    return .{ .x = c.x + content_pad_x, .y = c.y + content_pad_top + row.y - self.settings_scroll, .w = c.w - 2 * content_pad_x, .h = row.h };
}
fn controlWidth(self: *App, item: Item) f32 {
    return switch (item.kind) {
        .toggle => 32,
        .number => 116,
        .dropdown => 200,
        .button => self.renderer.widthUi(item.button) + 24,
    };
}
fn measureSmall(self: *App, text: []const u8) f32 {
    return self.renderer.widthSmall(text);
}
fn controlRect(self: *App, item: Item, rr: Rect) Rect {
    const w = controlWidth(self, item);
    const h: f32 = if (item.kind == .toggle) 18 else control_h;
    return .{ .x = rr.x + rr.w - w, .y = if (rr.w < w + 180) rr.y + rr.h - h - 5 else @round(rr.y + (rr.h - h) / 2), .w = w, .h = h };
}
fn minusRect(ctrl: Rect) Rect {
    return .{ .x = ctrl.x + 1, .y = ctrl.y + 1, .w = 26, .h = ctrl.h - 2 };
}
fn plusRect(ctrl: Rect) Rect {
    return .{ .x = ctrl.x + ctrl.w - 27, .y = ctrl.y + 1, .w = 26, .h = ctrl.h - 2 };
}
fn popupRect(ctrl: Rect, count: usize, bottom: f32) Rect {
    const h = @as(f32, @floatFromInt(count)) * 26 + 8;
    const below = ctrl.y + ctrl.h + 4;
    const y = if (below + h <= bottom) below else ctrl.y - h - 4;
    return .{ .x = ctrl.x, .y = y, .w = ctrl.w, .h = h };
}
fn optionRect(popup: Rect, i: usize) Rect {
    return .{ .x = popup.x + 4, .y = popup.y + 4 + @as(f32, @floatFromInt(i)) * 26, .w = popup.w - 8, .h = 26 };
}

const NavEntry = struct { page: Page, section: ?[]const u8, rect: Rect };
/// Sidebar tree: every page, with the active page expanded into its sections (Zed's TreeViewItem).
fn navEntries(self: *App, r: Rect, buf: *[32]NavEntry) []NavEntry {
    var n: usize = 0;
    var y = r.y + sidebar_pad + search_h + 12;
    const x = r.x + sidebar_pad;
    const w = sidebar_w - 2 * sidebar_pad;
    for (0..page_titles.len) |p| {
        const page: Page = @fromBackingInt(@intCast(p));
        buf[n] = .{ .page = page, .section = null, .rect = .{ .x = x, .y = y, .w = w, .h = nav_row_h } };
        n += 1;
        y += nav_row_h;
        if (page != currentPage(self) or query(self).len > 0) continue;
        var last: []const u8 = "";
        for (items) |item| if (item.page == page and !std.mem.eql(u8, last, item.section)) {
            last = item.section;
            if (n == buf.len) break;
            buf[n] = .{ .page = page, .section = item.section, .rect = .{ .x = x, .y = y, .w = w, .h = nav_row_h } };
            n += 1;
            y += nav_row_h;
        };
    }
    return buf[0..n];
}

// ---------------------------------------------------------------- values

fn numberValue(self: *App, id: Id) u32 {
    return switch (id) {
        .font_size => self.settings.font_size,
        .line_height => self.settings.line_height,
        .tab_size => self.settings.tab_size,
        .panel_width => self.settings.panel_width,
        else => 0,
    };
}
/// Ranges mirror `config.validate`, so saved files always reload.
fn numberRange(self: *App, id: Id) struct { min: u32, max: u32, step: u32 } {
    return switch (id) {
        .font_size => .{ .min = 10, .max = 40, .step = 1 },
        .line_height => .{ .min = self.settings.font_size, .max = 80, .step = 1 },
        .tab_size => .{ .min = 1, .max = 16, .step = 1 },
        .panel_width => .{ .min = 140, .max = 600, .step = 10 },
        else => .{ .min = 0, .max = 0, .step = 0 },
    };
}
fn stepNumber(self: *App, id: Id, dir: i32) !void {
    const range = numberRange(self, id);
    const cur = numberValue(self, id);
    const next = if (dir > 0) @min(range.max, cur + range.step) else @max(range.min, cur -| range.step);
    if (next == cur) return;
    switch (id) {
        .font_size => {
            try self.renderer.setMonoSize(next);
            self.settings.font_size = next;
            self.settings.line_height = @max(self.settings.line_height, next);
        },
        .line_height => self.settings.line_height = next,
        .tab_size => self.settings.tab_size = next,
        .panel_width => self.settings.panel_width = next,
        else => return,
    }
    try self.saveAndApplySettings();
}
fn boolValue(self: *App, id: Id) bool {
    return switch (id) {
        .cursor_blink => self.settings.cursor_blink,
        .auto_fold_dirs => self.settings.auto_fold_dirs,
        .indent_guides => self.settings.show_indent_guides,
        else => false,
    };
}
fn toggle(self: *App, id: Id) !void {
    switch (id) {
        .cursor_blink => self.settings.cursor_blink = !self.settings.cursor_blink,
        .auto_fold_dirs => {
            self.settings.auto_fold_dirs = !self.settings.auto_fold_dirs;
            try self.refreshProject();
        },
        .indent_guides => self.settings.show_indent_guides = !self.settings.show_indent_guides,
        else => return,
    }
    try self.saveAndApplySettings();
}
const IconThemeName = @import("../icon_theme.zig").Name;

fn optionCount(id: Id) usize {
    return switch (id) {
        .icon_theme => std.enums.values(IconThemeName).len,
        else => theme_list.len,
    };
}
fn optionLabel(id: Id, i: usize) []const u8 {
    return switch (id) {
        .icon_theme => std.enums.values(IconThemeName)[i].label(),
        else => theme_list[i].label,
    };
}
fn selectedOption(self: *App, id: Id) usize {
    switch (id) {
        .icon_theme => return @backingInt(self.settings.icon_theme),
        else => {
            for (theme_list, 0..) |item, i| if (item.id == self.settings.theme_name) return i;
            return 0;
        },
    }
}
fn selectOption(self: *App, id: Id, index: usize) !void {
    const i = index % optionCount(id);
    switch (id) {
        .icon_theme => self.settings.icon_theme = std.enums.values(IconThemeName)[i],
        else => {
            const choice = theme_list[i];
            self.settings.theme = try theme_mod.Theme.builtin(self.gpa, choice.id);
            self.settings.theme_name = choice.id;
        },
    }
    try self.saveAndApplySettings();
}
fn stepOption(self: *App, id: Id, dir: i32) !void {
    const n = optionCount(id);
    try selectOption(self, id, if (dir > 0) selectedOption(self, id) + 1 else selectedOption(self, id) + n - 1);
}

fn press(self: *App, id: Id) !void {
    switch (id) {
        .open_file => {
            // Write current values first so a missing file opens with real content.
            try self.saveAndApplySettings();
            const path = try std.fs.path.join(self.gpa, &.{ self.config_root, "settings.json" });
            defer self.gpa.free(path);
            try self.workspace.open(path);
            self.dialog = .none;
            self.panel_focus = false;
        },
        .open_keymap => {
            self.dialog = .none;
            try self.openKeymapEditor();
        },
        .open_keymap_file => try self.openConfigFile("keymap.json"),
        .reload => {
            try self.reloadConfig();
            self.notice("Configuration reloaded", .{});
        },
        else => {},
    }
}
fn activate(self: *App, index: usize) !void {
    const item = items[index];
    switch (item.kind) {
        .toggle => try toggle(self, item.id),
        .button => try press(self, item.id),
        .dropdown => {
            self.settings_option = selectedOption(self, item.id);
            self.settings_dropdown = true;
        },
        .number => {},
    }
}

// ---------------------------------------------------------------- drawing

fn hovered(self: *App, r: Rect) bool {
    return r.contains(self.mouse_x, self.mouse_y);
}

pub fn drawSettings(self: *App) !void {
    const t = self.settings.theme;
    const r = dialogRect(self);
    var lay = layout(self);
    clampScroll(self, r, &lay);
    const focused = focusedItem(self, &lay);

    try self.fill(.{ .w = self.layout.width, .h = self.layout.height }, .{ 0, 0, 0, 140 });
    // Soft drop shadow, then the card itself.
    for (0..4) |i| {
        const s: f32 = @floatFromInt(4 - i);
        try self.renderer.roundRect(r.x - s, r.y - s + 4, r.w + 2 * s, r.h + 2 * s, 10 + s, .{ 0, 0, 0, 22 });
    }
    try self.renderer.roundBox(r.x, r.y, r.w, r.h, 8, t.editor, t.border);

    // Sidebar.
    try self.renderer.roundRect(r.x + 1, r.y + 1, sidebar_w, r.h - 2, 7, t.panel);
    try self.renderer.rect(r.x + 8, r.y + 1, sidebar_w - 7, r.h - 2, t.panel);
    try self.renderer.rect(r.x + sidebar_w, r.y + 1, 1, r.h - 2, t.border);
    try drawSearch(self, r);
    try drawNav(self, r, &lay);
    const foot_y = r.y + r.h - nav_footer_h;
    try self.renderer.rect(r.x + 1, foot_y, sidebar_w - 1, 1, t.border_variant);
    try keyHint(self, r.x + sidebar_pad, foot_y + 7, "Del", "Reset focused setting");

    // Content.
    const c = contentRect(r);
    self.clip(c);
    for (lay.slice(), 0..) |row, ri| {
        const rr = rowRect(self, c, row);
        if (rr.y + rr.h < c.y or rr.y > c.y + c.h) continue;
        switch (row.kind) {
            .title => |page| try self.renderer.textUi(page_titles[@backingInt(page)], rr.x, rr.y + 28, t.text),
            .header => |name| {
                try self.renderer.textSmall(name, rr.x, rr.y + 26, t.muted);
                try self.renderer.rect(rr.x, rr.y + rr.h - 6, rr.w, 1, t.border_variant);
            },
            .item => |index| {
                const next_is_item = ri + 1 < lay.len and lay.rows[ri + 1].kind == .item;
                try drawItem(self, rr, index, self.settings_focus == .controls and focused == index, next_is_item);
            },
        }
    }
    if (lay.len == 0) try self.renderer.textUi("No matching settings", c.x + content_pad_x, c.y + content_pad_top + 28, t.muted);
    try drawContentScrollbar(self, c, &lay);
    self.renderer.setClip(null);

    // Close button.
    const close = closeRect(r);
    if (hovered(self, close)) try self.renderer.roundRect(close.x, close.y, close.w, close.h, radius, t.ghost_element_hover);
    try self.renderer.icon(icons.svg("ui:close"), close.x + 4, close.y + 4, 16, if (hovered(self, close)) t.text else t.muted);

    // Expanded dropdown floats over everything, unclipped.
    if (self.settings_dropdown) if (focused) |index| if (items[index].kind == .dropdown) {
        if (findRow(&lay, index)) |row| try drawPopup(self, items[index].id, controlRect(self, items[index], rowRect(self, c, row)), r);
    };
}

fn drawSearch(self: *App, r: Rect) !void {
    const t = self.settings.theme;
    const s = searchRect(r);
    try self.renderer.roundBox(s.x, s.y, s.w, s.h, radius, t.editor, t.border);
    try self.renderer.icon(icons.svg("ui:magnifying_glass"), s.x + 7, s.y + 7, 14, t.muted);
    const q = query(self);
    const tx = s.x + 28;
    if (q.len == 0) {
        try self.renderer.textUi("Search settings…", tx, s.y + 19, t.placeholder);
    } else {
        try self.renderer.textUi(q, tx, s.y + 19, t.text);
    }
    const caret_x = if (q.len == 0) tx - 2 else tx + self.renderer.widthUi(q) + 1;
    if (self.settings_focus == .search and self.caret_visible) try self.renderer.rect(caret_x, s.y + 6, 1, s.h - 12, t.accent);
}

fn drawNav(self: *App, r: Rect, lay: *const Layout) !void {
    const t = self.settings.theme;
    var buf: [32]NavEntry = undefined;
    const searching = query(self).len > 0;
    for (navEntries(self, r, &buf)) |entry| {
        const is_page = entry.section == null;
        const selected = is_page and entry.page == currentPage(self) and !searching;
        const dimmed = searching and !pageHasMatches(lay, entry.page);
        if (selected) {
            try self.renderer.roundRect(entry.rect.x, entry.rect.y, entry.rect.w, entry.rect.h, radius, t.ghost_element_selected);
        } else if (hovered(self, entry.rect)) {
            try self.renderer.roundRect(entry.rect.x, entry.rect.y, entry.rect.w, entry.rect.h, radius, t.ghost_element_hover);
        }
        const color = if (dimmed) t.placeholder else if (is_page) t.text else t.muted;
        if (is_page) {
            const expanded = entry.page == currentPage(self) and !searching;
            const chevron = if (expanded) "ui:chevron_down" else "ui:chevron_right";
            try self.renderer.icon(icons.svg(chevron), entry.rect.x + 4, entry.rect.y + 6, 14, t.muted);
            try self.renderer.textUi(page_titles[@backingInt(entry.page)], entry.rect.x + 24, entry.rect.y + 18, color);
        } else {
            try self.renderer.textUi(entry.section.?, entry.rect.x + 24 + 16, entry.rect.y + 18, color);
        }
    }
}

fn pageHasMatches(lay: *const Layout, page: Page) bool {
    for (lay.slice()) |row| switch (row.kind) {
        .title => |p| if (p == page) return true,
        else => {},
    };
    return false;
}

fn keyHint(self: *App, x: f32, y: f32, key: []const u8, label: []const u8) !void {
    const t = self.settings.theme;
    const kw = self.renderer.widthSmall(key) + 10;
    try self.renderer.roundBox(x, y, kw, 18, 3, t.element_background, t.border_variant);
    try self.renderer.textSmall(key, x + 5, y + 13, t.muted);
    try self.renderer.textSmall(label, x + kw + 6, y + 13, t.muted);
}

fn resetRect(self: *App, item: Item, rr: Rect) Rect {
    return .{ .x = rr.x + self.renderer.widthUi(item.title) + 8, .y = rr.y + 8, .w = 44, .h = 22 };
}
fn resetValue(self: *App, id: Id) !void {
    if (!helpers.changed(self.settings, id)) return;
    var next = self.settings;
    helpers.reset(&next, id);
    if (next.font_size != self.settings.font_size) try self.renderer.setMonoSize(next.font_size);
    if (id == .theme) next.theme = try theme_mod.Theme.builtin(self.gpa, next.theme_name);
    self.settings = next;
    if (next.font_size != self.saved_font_size) self.saved_font_size = next.font_size;
    if (id == .auto_fold_dirs) try self.refreshProject();
    try self.saveAndApplySettings();
    if (id == .theme) try self.reloadConfig();
}

fn drawItem(self: *App, rr: Rect, index: usize, focused: bool, divider: bool) !void {
    const t = self.settings.theme;
    const item = items[index];
    if (focused) try self.renderer.roundRect(rr.x - 10, rr.y + 2, rr.w + 20, rr.h - 4, 6, t.ghost_element_hover);
    const ctrl = controlRect(self, item, rr);
    const stacked = rr.w < ctrl.w + 180;
    const desc_width = if (stacked) rr.w else @max(1, ctrl.x - rr.x - 12);
    self.clip(.{ .x = rr.x, .y = rr.y, .w = @max(0, desc_width), .h = rr.h });
    try self.renderer.textUi(item.title, rr.x, rr.y + 26, t.text);
    var rest = item.desc;
    var baseline = rr.y + 44;
    while (rest.len > 0) {
        const end = helpers.lineEnd(rest, desc_width, self, measureSmall);
        try self.renderer.textSmall(rest[0..end], rr.x, baseline, t.muted);
        rest = std.mem.trimStart(u8, rest[end..], " ");
        baseline += 16;
    }
    self.clip(contentRect(dialogRect(self)));
    if (helpers.changed(self.settings, item.id)) {
        const reset = resetRect(self, item, rr);
        if (hovered(self, reset)) try self.renderer.roundRect(reset.x, reset.y, reset.w, reset.h, radius, t.element_hover);
        try self.renderer.textSmall("Reset", reset.x + 3, reset.y + 15, t.accent);
    }
    if (divider) try self.renderer.rect(rr.x, rr.y + rr.h - 1, rr.w, 1, t.border_variant);

    switch (item.kind) {
        .toggle => {
            const on = boolValue(self, item.id);
            const track = if (on) t.accent else t.element_background;
            try self.renderer.roundBox(ctrl.x, ctrl.y, ctrl.w, ctrl.h, 9, track, if (on) t.accent else t.border);
            const knob_x = if (on) ctrl.x + ctrl.w - 16 else ctrl.x + 2;
            try self.renderer.roundRect(knob_x, ctrl.y + 2, 14, 14, 7, if (on) t.editor else t.muted);
        },
        .number => {
            try self.renderer.roundBox(ctrl.x, ctrl.y, ctrl.w, ctrl.h, radius, t.element_background, t.border);
            const minus = minusRect(ctrl);
            const plus = plusRect(ctrl);
            if (hovered(self, minus)) try self.renderer.roundRect(minus.x, minus.y, minus.w, minus.h, radius - 1, t.element_hover);
            if (hovered(self, plus)) try self.renderer.roundRect(plus.x, plus.y, plus.w, plus.h, radius - 1, t.element_hover);
            const cy = @round(ctrl.y + ctrl.h / 2);
            try self.renderer.rect(minus.x + 8, cy, 10, 1, t.muted);
            try self.renderer.rect(plus.x + 8, cy, 10, 1, t.muted);
            try self.renderer.rect(plus.x + 13, cy - 5, 1, 11, t.muted);
            var buf: [16]u8 = undefined;
            const text = if (focused and self.settings_editing_number) self.settings_number[0..self.settings_number_len] else std.fmt.bufPrint(&buf, "{d}", .{numberValue(self, item.id)}) catch "?";
            try self.renderer.textUi(text, @round(ctrl.x + (ctrl.w - self.renderer.widthUi(text)) / 2), ctrl.y + 18, t.text);
        },
        .dropdown => {
            const fill = if (hovered(self, ctrl)) t.element_hover else t.element_background;
            try self.renderer.roundBox(ctrl.x, ctrl.y, ctrl.w, ctrl.h, radius, fill, t.border);
            try self.renderer.textUi(optionLabel(item.id, selectedOption(self, item.id)), ctrl.x + 10, ctrl.y + 18, t.text);
            try self.renderer.icon(icons.svg("ui:chevron_down"), ctrl.x + ctrl.w - 22, ctrl.y + 6, 14, t.muted);
        },
        .button => {
            const fill = if (hovered(self, ctrl)) t.element_hover else t.element_background;
            try self.renderer.roundBox(ctrl.x, ctrl.y, ctrl.w, ctrl.h, radius, fill, t.border);
            try self.renderer.textUi(item.button, ctrl.x + 12, ctrl.y + 18, t.text);
        },
    }
}

fn drawPopup(self: *App, id: Id, ctrl: Rect, r: Rect) !void {
    const t = self.settings.theme;
    const popup = popupRect(ctrl, optionCount(id), r.y + r.h);
    try self.renderer.roundRect(popup.x - 2, popup.y, popup.w + 4, popup.h + 4, 8, .{ 0, 0, 0, 50 });
    try self.renderer.roundBox(popup.x, popup.y, popup.w, popup.h, 6, t.elevated_surface, t.border);
    const current = self.settings_option;
    for (0..optionCount(id)) |i| {
        const o = optionRect(popup, i);
        if (hovered(self, o)) try self.renderer.roundRect(o.x, o.y, o.w, o.h, radius, t.ghost_element_hover);
        try self.renderer.textUi(optionLabel(id, i), o.x + 8, o.y + 18, t.text);
        if (i == current) try self.renderer.icon(icons.svg("ui:check"), o.x + o.w - 22, o.y + 6, 14, t.accent);
    }
}

fn drawContentScrollbar(self: *App, c: Rect, lay: *const Layout) !void {
    const view = c.h - content_pad_top;
    const total = lay.height + content_pad_top;
    if (total <= c.h) return;
    const thumb_h = @max(24, c.h * view / total);
    const pos = self.settings_scroll / (total - c.h + content_pad_top);
    try self.renderer.roundRect(c.x + c.w - 9, c.y + 4 + (c.h - 8 - thumb_h) * @min(1, pos), 6, thumb_h, 3, self.settings.theme.scrollbar_thumb);
}

fn findRow(lay: *const Layout, index: usize) ?Row {
    for (lay.slice()) |row| if (row.kind == .item and row.kind.item == index) return row;
    return null;
}

fn maxScroll(r: Rect, lay: *const Layout) f32 {
    return @max(0, lay.height + content_pad_top * 2 - contentRect(r).h);
}
fn clampScroll(self: *App, r: Rect, lay: *const Layout) void {
    self.settings_scroll = std.math.clamp(self.settings_scroll, 0, maxScroll(r, lay));
}

pub fn scroll(self: *App, dy: f32) void {
    self.settings_dropdown = false;
    self.settings_scroll += dy;
    var lay = layout(self);
    clampScroll(self, dialogRect(self), &lay);
}

/// Keep the focused item fully inside the content viewport.
fn revealFocused(self: *App) void {
    const lay = layout(self);
    const index = focusedItem(self, &lay) orelse return;
    const row = findRow(&lay, index) orelse return;
    const view = contentRect(dialogRect(self)).h - content_pad_top * 2;
    if (row.y < self.settings_scroll) self.settings_scroll = row.y;
    if (row.y + row.h > self.settings_scroll + view) self.settings_scroll = row.y + row.h - view;
}

// ---------------------------------------------------------------- input

pub fn handleClick(self: *App, mx: f32, my: f32) !void {
    const r = dialogRect(self);
    const lay = layout(self);
    const c = contentRect(r);

    if (self.settings_dropdown) {
        self.settings_dropdown = false;
        if (focusedItem(self, &lay)) |index| if (findRow(&lay, index)) |row| {
            const id = items[index].id;
            const popup = popupRect(controlRect(self, items[index], rowRect(self, c, row)), optionCount(id), r.y + r.h);
            for (0..optionCount(id)) |i| if (optionRect(popup, i).contains(mx, my)) return selectOption(self, id, i);
            if (popup.contains(mx, my)) return;
        };
    }
    if (!r.contains(mx, my)) {
        self.dialog = .none;
        return;
    }
    if (closeRect(r).contains(mx, my)) {
        self.dialog = .none;
        return;
    }
    if (searchRect(r).contains(mx, my)) {
        self.settings_focus = .search;
        self.settings_editing_number = false;
        return;
    }
    if (mx < r.x + sidebar_w) {
        var buf: [32]NavEntry = undefined;
        for (navEntries(self, r, &buf)) |entry| if (entry.rect.contains(mx, my)) {
            self.settings_query_len = 0;
            self.settings_focus = .controls;
            self.settings_editing_number = false;
            self.settings_category = @backingInt(entry.page);
            self.settings_row = 0;
            self.settings_scroll = 0;
            if (entry.section) |section| scrollToSection(self, section);
            return;
        };
        return;
    }
    if (!c.contains(mx, my)) return;
    var buf: [items.len]usize = undefined;
    const list = focusable(&lay, &buf);
    for (lay.slice()) |row| {
        if (row.kind != .item) continue;
        const rr = rowRect(self, c, row);
        if (!rr.contains(mx, my)) continue;
        const index = row.kind.item;
        for (list, 0..) |item_index, pos| if (item_index == index) {
            self.settings_row = pos;
        };
        self.settings_focus = .controls;
        self.settings_editing_number = false;
        const item = items[index];
        const ctrl = controlRect(self, item, rr);
        if (helpers.changed(self.settings, item.id) and resetRect(self, item, rr).contains(mx, my)) return resetValue(self, item.id);
        switch (item.kind) {
            .number => {
                if (minusRect(ctrl).contains(mx, my)) try stepNumber(self, item.id, -1);
                if (plusRect(ctrl).contains(mx, my)) try stepNumber(self, item.id, 1);
                if (ctrl.contains(mx, my) and !minusRect(ctrl).contains(mx, my) and !plusRect(ctrl).contains(mx, my)) beginNumber(self, item.id);
            },
            // Zed toggles a switch from anywhere on its row.
            .toggle => try toggle(self, item.id),
            .dropdown, .button => if (ctrl.contains(mx, my)) try activate(self, index),
        }
        return;
    }
}

fn scrollToSection(self: *App, section: []const u8) void {
    const lay = layout(self);
    for (lay.slice()) |row| switch (row.kind) {
        .header => |name| if (std.mem.eql(u8, name, section)) {
            self.settings_scroll = row.y;
            var copy = lay;
            clampScroll(self, dialogRect(self), &copy);
            return;
        },
        else => {},
    };
}

pub fn typeText(self: *App, text: []const u8) void {
    if (self.settings_editing_number) {
        for (text) |ch| if (std.ascii.isDigit(ch) and self.settings_number_len < self.settings_number.len) {
            self.settings_number[self.settings_number_len] = ch;
            self.settings_number_len += 1;
        };
        return;
    }
    if (self.settings_focus != .search) return;
    const room = self.settings_query.len - self.settings_query_len;
    const n = @min(room, text.len);
    @memcpy(self.settings_query[self.settings_query_len..][0..n], text[0..n]);
    self.settings_query_len += n;
    resetFocus(self);
}

fn beginNumber(self: *App, id: Id) void {
    const value = std.fmt.bufPrint(&self.settings_number, "{d}", .{numberValue(self, id)}) catch unreachable;
    self.settings_number_len = value.len;
    self.settings_editing_number = true;
}

fn commitNumber(self: *App, id: Id) !void {
    self.settings_editing_number = false;
    const value = std.fmt.parseInt(u32, self.settings_number[0..self.settings_number_len], 10) catch return;
    const range = numberRange(self, id);
    if (value < range.min or value > range.max) return;
    switch (id) {
        .font_size => {
            try self.renderer.setMonoSize(value);
            self.settings.font_size = value;
            self.settings.line_height = @max(self.settings.line_height, value);
        },
        .line_height => self.settings.line_height = value,
        .tab_size => self.settings.tab_size = value,
        .panel_width => self.settings.panel_width = value,
        else => return,
    }
    try self.saveAndApplySettings();
}

fn resetFocus(self: *App) void {
    self.settings_row = 0;
    self.settings_scroll = 0;
    self.settings_dropdown = false;
}

pub fn handleKey(self: *App, key: sdl.keycode.Keycode) !void {
    const lay = layout(self);
    var buf: [items.len]usize = undefined;
    const list = focusable(&lay, &buf);
    const focused = focusedItem(self, &lay);
    const mods = sdl.keyboard.getModState();
    const shift = mods.left_shift or mods.right_shift;

    if (self.settings_editing_number) {
        switch (key) {
            .escape => self.settings_editing_number = false,
            .return_key, .tab => if (focused) |index| try commitNumber(self, items[index].id),
            .backspace => if (self.settings_number_len > 0) {
                self.settings_number_len -= 1;
            },
            else => {},
        }
        if (key != .tab) return;
    }
    if (self.settings_dropdown) {
        switch (key) {
            .escape => self.settings_dropdown = false,
            .return_key => if (focused) |index| {
                try selectOption(self, items[index].id, self.settings_option);
                self.settings_dropdown = false;
            },
            .up => if (focused) |index| {
                self.settings_option = (self.settings_option + optionCount(items[index].id) - 1) % optionCount(items[index].id);
            },
            .down => if (focused) |index| {
                self.settings_option = (self.settings_option + 1) % optionCount(items[index].id);
            },
            else => {},
        }
        return;
    }
    switch (key) {
        .escape => if (self.settings_query_len > 0) {
            self.settings_query_len = 0;
            resetFocus(self);
        } else {
            self.dialog = .none;
        },
        .backspace => if (self.settings_focus == .search and self.settings_query_len > 0) {
            var n = self.settings_query_len - 1;
            while (n > 0 and self.settings_query[n] & 0xc0 == 0x80) n -= 1;
            self.settings_query_len = n;
            resetFocus(self);
        },
        .tab => {
            if (self.settings_focus == .search) {
                if (list.len > 0) {
                    self.settings_focus = .controls;
                    self.settings_row = if (shift) list.len - 1 else 0;
                }
            } else if ((!shift and self.settings_row + 1 >= list.len) or (shift and self.settings_row == 0)) {
                self.settings_focus = .search;
            } else if (shift) {
                self.settings_row -= 1;
            } else {
                self.settings_row += 1;
            }
            revealFocused(self);
        },
        .up => if (self.settings_row > 0) {
            self.settings_row -= 1;
        } else if (list.len == 0 and currentPage(self) == .keymap) {
            scroll(self, -binding_h);
        },
        .down => if (list.len > 0) {
            self.settings_row = @min(self.settings_row + 1, list.len - 1);
        } else if (currentPage(self) == .keymap) {
            scroll(self, binding_h);
        },
        .page_up => scroll(self, -200),
        .page_down => scroll(self, 200),
        .left, .right => if (self.settings_focus == .controls) {
            if (focused) |index| {
                const dir: i32 = if (key == .right) 1 else -1;
                const item = items[index];
                switch (item.kind) {
                    .number => try stepNumber(self, item.id, dir),
                    .toggle => if (boolValue(self, item.id) != (dir > 0)) try toggle(self, item.id),
                    .dropdown => try stepOption(self, item.id, dir),
                    .button => {},
                }
            }
        },
        .delete => {
            const id: ?Id = if (focused) |index| items[index].id else null;
            if (helpers.keyboardResetTarget(self.settings, id, self.settings_focus == .controls)) |target| try resetValue(self, target);
        },
        .return_key => if (self.settings_focus == .controls) {
            if (focused) |index| {
                if (items[index].kind == .number) beginNumber(self, items[index].id) else try activate(self, index);
            }
        },
        else => {},
    }
    if (key == .up or key == .down) {
        self.settings_focus = .controls;
        revealFocused(self);
    }
}
