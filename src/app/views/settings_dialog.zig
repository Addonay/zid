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

pub const Page = enum { general, appearance, keymap, editor, languages_and_tools, search_and_files, window_and_layout, panels, debugger, terminal, version_control, collaboration, ai, network, developer };
const page_titles = [_][]const u8{ "General", "Appearance", "Keymap", "Editor", "Languages & Tools", "Search & Files", "Window & Layout", "Panels", "Debugger", "Terminal", "Version Control", "Collaboration", "AI", "Network", "Developer" };
const settings_assets = @import("settings_assets");

const Kind = enum { toggle, number, dropdown, button, value };
const helpers = @import("../settings_helpers.zig");
const Id = helpers.Id;

const Item = struct { id: Id, page: Page, section: []const u8, title: []const u8, desc: []const u8, kind: Kind, button: []const u8 = "", path: []const []const u8 = &.{}, jsonpath: []const u8 = "", default: []const u8 = "null" };

const primary_items = [_]Item{
    .{ .id = .open_keymap, .page = .keymap, .section = "Keybindings", .title = "Edit Keybindings", .desc = "Customize keybindings in the keymap editor.", .kind = .button, .button = "Open Keymap" },
    .{ .id = .open_keymap_file, .page = .keymap, .section = "Keybindings", .title = "Keymap File", .desc = "Edit keymap.json (Zed format; later entries override defaults)", .kind = .button, .button = "Edit keymap.json" },
};

const items = primary_items ++ catalogue: {
    @setEvalBranchQuota(100000);
    var result: [settings_assets.entries.len]Item = undefined;
    for (settings_assets.entries, 0..) |entry, i| {
        const id: Id = if (std.mem.eql(u8, entry.path, "theme")) .theme else if (std.mem.eql(u8, entry.path, "icon_theme")) .icon_theme else if (std.mem.eql(u8, entry.path, "buffer_font_size")) .font_size else if (std.mem.eql(u8, entry.path, "tab_size")) .tab_size else if (std.mem.eql(u8, entry.path, "cursor_blink")) .cursor_blink else if (std.mem.eql(u8, entry.path, "project_panel.default_width")) .panel_width else if (std.mem.eql(u8, entry.path, "project_panel.auto_fold_dirs")) .auto_fold_dirs else .catalogue;
        const kind: Kind = switch (id) {
            .theme, .icon_theme => .dropdown,
            .font_size, .tab_size, .panel_width => .number,
            .cursor_blink, .auto_fold_dirs => .toggle,
            else => .value,
        };
        result[i] = .{ .id = id, .page = @field(Page, entry.page), .section = entry.section, .title = entry.title, .desc = entry.description, .kind = kind, .path = entry.segments, .jsonpath = entry.path, .default = entry.default };
    }
    break :catalogue result;
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
    .{ .id = .one_light, .label = "One Light" },
    .{ .id = .ayu_light, .label = "Ayu Light" },
    .{ .id = .gruvbox_light, .label = "Gruvbox Light" },
};

// Geometry (Zed: SIDEBAR_WIDTH 226, sidebar p_2p5, search h_7, content px_8).
const sidebar_w: f32 = 226;
const sidebar_pad: f32 = 10;
const search_h: f32 = 28;
const nav_row_h: f32 = 26;
const nav_footer_h: f32 = 32;
const content_pad_x: f32 = 32;
const content_pad_top: f32 = 20;
const page_header_h: f32 = 52;
const banner_h: f32 = 60;
const header_button_h: f32 = 26;
/// Client-side titlebar drawn by the frameless settings window (Zed's strip).
const titlebar_h: f32 = 34;
const title_h: f32 = 44;
const header_h: f32 = 40;
const item_h: f32 = 60;
const binding_h: f32 = 32;
const control_h: f32 = 26;
const radius: f32 = 4;
const max_rows = items.len * 3 + page_titles.len;
const max_nav = items.len + page_titles.len;

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
    self.settings_nav_index = 0;
    self.settings_expanded = @as(u32, 1) << @intCast(self.settings_category);
    self.settings_copied = null;
    self.settings_document_error = false;
    self.settings_editing_number = false;
    self.settings_editing_json = false;
    self.settings_nav_scroll = 0;
    if (self.settings_document) |*document| document.deinit();
    self.settings_document = @import("../settings_document.zig").Document.load(self.gpa, self.io, self.config_root) catch |err| blk: {
        if (err != error.FileNotFound) self.settings_document_error = true;
        break :blk null;
    };
    self.openSettingsWindow();
}

fn query(self: *App) []const u8 {
    return self.settings_query[0..self.settings_query_len];
}

fn matches(item: Item, q: []const u8) bool {
    if (q.len == 0) return true;
    const path: ?[]const u8 = if (item.jsonpath.len > 0) item.jsonpath else switch (item.id) {
        .catalogue => item.jsonpath,
        .theme => "theme",
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
    if (self.settings_window != null) return .{ .y = titlebar_h, .w = self.settings_w, .h = @max(1, self.settings_h - titlebar_h) };
    const w = @max(1, @min(920, self.layout.width - 48));
    const h = @max(1, @min(640, self.layout.height - 48));
    return .{ .x = @round((self.layout.width - w) / 2), .y = @round((self.layout.height - h) / 2), .w = w, .h = h };
}
fn contentRect(r: Rect) Rect {
    return .{ .x = r.x + sidebar_w, .y = r.y + 1, .w = r.w - sidebar_w - 1, .h = r.h - 2 };
}
/// Scrollable region under the file-scope header and optional warning banner.
fn scrollRect(self: *App, r: Rect) Rect {
    const c = contentRect(r);
    const top = pageHeaderH(self);
    return .{ .x = c.x, .y = c.y + top, .w = c.w, .h = c.h - top };
}
fn pageHeaderH(self: *App) f32 {
    return page_header_h + if (self.settings_document_error) banner_h else 0;
}
fn expanded(self: *App, page: Page) bool {
    return self.settings_expanded & (@as(u32, 1) << @intCast(@backingInt(page))) != 0;
}
fn setExpanded(self: *App, page: Page, on: bool) void {
    const bit = @as(u32, 1) << @intCast(@backingInt(page));
    if (on) self.settings_expanded |= bit else self.settings_expanded &= ~bit;
}
fn searchRect(r: Rect) Rect {
    return .{ .x = r.x + sidebar_pad, .y = r.y + sidebar_pad, .w = sidebar_w - 2 * sidebar_pad, .h = search_h };
}
fn closeRect(r: Rect) Rect {
    return .{ .x = r.x + r.w - 34, .y = r.y + 10, .w = 24, .h = 24 };
}
fn rowRect(self: *App, c: Rect, row: Row) Rect {
    const s = scrollRect(self, dialogRect(self));
    return .{ .x = c.x + content_pad_x, .y = s.y + content_pad_top + row.y - self.settings_scroll, .w = c.w - 2 * content_pad_x, .h = row.h };
}
fn controlWidth(self: *App, item: Item) f32 {
    return switch (item.kind) {
        .toggle => 32,
        .number => 116,
        .dropdown => 200,
        .button => self.renderer.widthUi(item.button) + 24,
        .value => if (std.mem.eql(u8, item.default, "true") or std.mem.eql(u8, item.default, "false")) 32 else 200,
    };
}
fn measureSmall(self: *App, text: []const u8) f32 {
    return self.renderer.widthSmall(text);
}
fn controlRect(self: *App, item: Item, rr: Rect) Rect {
    const w = @min(controlWidth(self, item), @max(32, rr.w));
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
fn navEntries(self: *App, r: Rect, buf: *[max_nav]NavEntry) []NavEntry {
    var n: usize = 0;
    var y = r.y + sidebar_pad + search_h + 12 - self.settings_nav_scroll;
    const x = r.x + sidebar_pad;
    const w = sidebar_w - 2 * sidebar_pad;
    for (0..page_titles.len) |p| {
        const page: Page = @fromBackingInt(@intCast(p));
        buf[n] = .{ .page = page, .section = null, .rect = .{ .x = x, .y = y, .w = w, .h = nav_row_h } };
        n += 1;
        y += nav_row_h;
        if (!expanded(self, page) and query(self).len == 0) continue;
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
        .open_file => try self.openConfigFile("settings.json"),
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
        .value => try beginValue(self, index),
    }
}

// ---------------------------------------------------------------- drawing

fn hovered(self: *App, r: Rect) bool {
    return r.contains(self.mouse_x, self.mouse_y);
}

/// Frameless-window titlebar: centered "Settings" title, X on the right.
/// The strip itself drags the window via the hit-test, so only the X acts here.
fn drawTitlebar(self: *App, r: Rect) !void {
    const t = self.settings.theme;
    try self.renderer.rect(r.x, r.y, r.w, r.h - 1, t.panel);
    try self.renderer.rect(r.x, r.y + r.h - 1, r.w, 1, t.border_variant);
    const title = "Settings";
    try self.renderer.textUi(title, r.x + (r.w - self.renderer.widthUi(title)) / 2, r.y + 10, t.muted);
    const close: Rect = .{ .x = r.x + r.w - r.h, .y = r.y, .w = r.h, .h = r.h };
    if (hovered(self, close)) try self.renderer.roundRect(close.x + 4, close.y + 4, close.w - 8, close.h - 8, radius, t.ghost_element_hover);
    try self.renderer.icon(icons.svg("ui:close"), close.x + (close.w - 16) / 2, close.y + (close.h - 16) / 2, 16, if (hovered(self, close)) t.text else t.muted);
}
pub fn drawSettings(self: *App) !void {
    const t = self.settings.theme;
    const r = dialogRect(self);
    var lay = layout(self);
    clampScroll(self, r, &lay);
    const focused = focusedItem(self, &lay);

    const windowed = self.settings_window != null;
    if (windowed) {
        try self.renderer.rect(r.x, r.y - titlebar_h, r.w, r.h + titlebar_h, t.editor);
        try drawTitlebar(self, .{ .x = r.x, .y = r.y - titlebar_h, .w = r.w, .h = titlebar_h });
    } else {
        try self.fill(.{ .w = self.layout.width, .h = self.layout.height }, .{ 0, 0, 0, 140 });
        // Soft drop shadow, then the card itself.
        for (0..4) |i| {
            const s: f32 = @floatFromInt(4 - i);
            try self.renderer.roundRect(r.x - s, r.y - s + 4, r.w + 2 * s, r.h + 2 * s, 10 + s, .{ 0, 0, 0, 22 });
        }
        try self.renderer.roundBox(r.x, r.y, r.w, r.h, 8, t.editor, t.border);
    }

    // Sidebar.
    if (windowed) {
        try self.renderer.rect(r.x, r.y, sidebar_w, r.h, t.panel);
    } else {
        try self.renderer.roundRect(r.x + 1, r.y + 1, sidebar_w, r.h - 2, 7, t.panel);
        try self.renderer.rect(r.x + 8, r.y + 1, sidebar_w - 7, r.h - 2, t.panel);
    }
    try self.renderer.rect(r.x + sidebar_w, r.y + 1, 1, r.h - 2, t.border);
    try drawSearch(self, r);
    try drawNav(self, r, &lay);
    const foot_y = r.y + r.h - nav_footer_h;
    try self.renderer.rect(r.x + 1, foot_y, sidebar_w - 1, 1, t.border_variant);
    try keyHint(self, r.x + sidebar_pad, foot_y + 7, "left", if (self.settings_focus == .nav) "Focus Content" else "Focus Navbar");

    // Content: file-scope header, optional warning banner, then the page rows.
    const c = contentRect(r);
    try drawHeader(self, c);
    const s = scrollRect(self, r);
    self.clip(s);
    for (lay.slice(), 0..) |row, ri| {
        const rr = rowRect(self, c, row);
        if (rr.y + rr.h < s.y or rr.y > s.y + s.h) continue;
        switch (row.kind) {
            .title => |page| try self.renderer.textUi(page_titles[@backingInt(page)], rr.x, rr.y + 28, t.text),
            .header => |name| {
                try self.renderer.textMonoXSmall(name, rr.x, rr.y + 26, t.muted);
                try self.renderer.rect(rr.x, rr.y + rr.h - 6, rr.w, 1, t.border_variant);
            },
            .item => |index| {
                const next_is_item = ri + 1 < lay.len and lay.rows[ri + 1].kind == .item;
                try drawItem(self, rr, index, self.settings_focus == .controls and focused == index, next_is_item);
            },
        }
    }
    if (lay.len == 0) {
        const msg = "No Results";
        try self.renderer.textUi(msg, s.x + (s.w - self.renderer.widthUi(msg)) / 2, s.y + s.h / 2 - 8, t.text);
        var detail_buf: [96]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "No settings match \"{s}\"", .{query(self)}) catch "No settings match";
        try self.renderer.textSmall(detail, s.x + (s.w - self.renderer.widthSmall(detail)) / 2, s.y + s.h / 2 + 10, t.muted);
    }
    try drawContentScrollbar(self, s, &lay);
    self.renderer.setClip(null);

    // Close button (dialog mode; the window has its own chrome).
    if (!windowed) {
        const close = closeRect(r);
        if (hovered(self, close)) try self.renderer.roundRect(close.x, close.y, close.w, close.h, radius, t.ghost_element_hover);
        try self.renderer.icon(icons.svg("ui:close"), close.x + 4, close.y + 4, 16, if (hovered(self, close)) t.text else t.muted);
    }

    // Expanded dropdown floats over everything, unclipped.
    if (self.settings_dropdown) if (focused) |index| if (items[index].kind == .dropdown) {
        if (findRow(&lay, index)) |row| try drawPopup(self, items[index].id, controlRect(self, items[index], rowRect(self, c, row)), r);
    };
}

/// Zed's render_files_header: file-scope buttons on the left and an
/// "Edit in settings.json" button on the right. zid has a single (User)
/// settings file, so only the User scope is shown.
fn drawHeader(self: *App, c: Rect) !void {
    const t = self.settings.theme;
    const by = c.y + 20;
    const label = "User";
    const bw = self.renderer.widthUi(label) + 24;
    // Selected scope button: Tinted(Accent) — translucent accent on accent text.
    try self.renderer.roundRect(c.x + content_pad_x, by, bw, header_button_h, radius, .{ t.accent[0], t.accent[1], t.accent[2], 40 });
    try self.renderer.textUi(label, c.x + content_pad_x + 12, by + 18, t.accent);
    if (self.settings_document_error) try drawBanner(self, c, by + header_button_h + 8);
    const edit = "Edit in settings.json";
    const er = editFileRect(self, c);
    const fill = if (hovered(self, er)) t.element_hover else t.element_background;
    try self.renderer.roundBox(er.x, by, er.w, header_button_h, radius, fill, t.border);
    try self.renderer.textUi(edit, er.x + 12, by + 18, t.text);
}
fn editFileRect(self: *App, c: Rect) Rect {
    const w = self.renderer.widthUi("Edit in settings.json") + 24;
    return .{ .x = c.x + c.w - content_pad_x - w, .y = c.y + 20, .w = w, .h = header_button_h };
}
fn bannerRect(c: Rect) Rect {
    return .{ .x = c.x + content_pad_x, .y = c.y + 20 + header_button_h + 8, .w = c.w - 2 * content_pad_x, .h = banner_h - 16 };
}
/// Warning banner shown when settings.json fails to parse (Zed's Banner).
fn drawBanner(self: *App, c: Rect, y: f32) !void {
    const t = self.settings.theme;
    const b: Rect = .{ .x = c.x + content_pad_x, .y = y, .w = c.w - 2 * content_pad_x, .h = banner_h - 16 };
    try self.renderer.roundBox(b.x, b.y, b.w, b.h, radius, t.elevated_surface, t.warning);
    try self.renderer.textUi("Failed to load your settings.", b.x + 14, b.y + 18, t.text);
    try self.renderer.textSmall("Some values may be incorrect and changes may be lost.", b.x + 14, b.y + 34, t.muted);
    const fix = "Fix in settings.json";
    const fw = self.renderer.widthUi(fix) + 24;
    const fr: Rect = .{ .x = b.x + b.w - fw - 12, .y = b.y + (b.h - header_button_h) / 2, .w = fw, .h = header_button_h };
    const fill = if (hovered(self, fr)) t.element_hover else t.element_background;
    try self.renderer.roundBox(fr.x, fr.y, fr.w, fr.h, radius, fill, t.border);
    try self.renderer.textUi(fix, fr.x + 12, fr.y + 18, t.text);
}

fn clearQueryRect(s: Rect) Rect {
    return .{ .x = s.x + s.w - 24, .y = s.y + 5, .w = 18, .h = 18 };
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
        const cr = clearQueryRect(s);
        if (hovered(self, cr)) try self.renderer.roundRect(cr.x, cr.y, cr.w, cr.h, 3, t.ghost_element_hover);
        try self.renderer.icon(icons.svg("ui:close"), cr.x + 2, cr.y + 2, 14, t.muted);
    }
    const caret_x = if (q.len == 0) tx - 2 else tx + self.renderer.widthUi(q) + 1;
    if (self.settings_focus == .search and self.caret_visible) try self.renderer.rect(caret_x, s.y + 6, 1, s.h - 12, t.accent);
}

fn drawNav(self: *App, r: Rect, lay: *const Layout) !void {
    const t = self.settings.theme;
    var buf: [max_nav]NavEntry = undefined;
    const searching = query(self).len > 0;
    self.clip(.{ .x = r.x, .y = searchRect(r).y + search_h + 8, .w = sidebar_w, .h = r.h - search_h - nav_footer_h - 28 });
    defer self.renderer.setClip(null);
    const active = activeSection(self, lay);
    for (navEntries(self, r, &buf), 0..) |entry, ei| {
        const is_page = entry.section == null;
        const selected = !searching and entry.page == currentPage(self) and
            (is_page or (active != null and entry.section != null and std.mem.eql(u8, entry.section.?, active.?)));
        const nav_focused = self.settings_focus == .nav and ei == self.settings_nav_index;
        const dimmed = searching and !pageHasMatches(lay, entry.page);
        if (selected or nav_focused) {
            try self.renderer.roundRect(entry.rect.x, entry.rect.y, entry.rect.w, entry.rect.h, radius, t.ghost_element_selected);
        } else if (hovered(self, entry.rect)) {
            try self.renderer.roundRect(entry.rect.x, entry.rect.y, entry.rect.w, entry.rect.h, radius, t.ghost_element_hover);
        }
        if (nav_focused) try self.renderer.roundBox(entry.rect.x, entry.rect.y, entry.rect.w, entry.rect.h, radius, .{ 0, 0, 0, 0 }, t.border_focused);
        const color = if (dimmed) t.placeholder else if (is_page) t.text else t.muted;
        if (is_page) {
            const is_open = expanded(self, entry.page) or searching;
            const chevron = if (is_open) "ui:chevron_down" else "ui:chevron_right";
            try self.renderer.icon(icons.svg(chevron), entry.rect.x + 4, entry.rect.y + 6, 14, t.muted);
            try self.renderer.textUi(page_titles[@backingInt(entry.page)], entry.rect.x + 24, entry.rect.y + 18, color);
        } else {
            try self.renderer.textUi(entry.section.?, entry.rect.x + 24 + 16, entry.rect.y + 18, color);
        }
    }
}

/// Section scrolled into view on the current page — mirrors Zed's
/// update_navbar_entry_from_scroll_position.
fn activeSection(self: *App, lay: *const Layout) ?[]const u8 {
    if (query(self).len > 0) return null;
    var section: ?[]const u8 = null;
    for (lay.slice()) |row| {
        if (row.y - self.settings_scroll > content_pad_top + 4) break;
        if (row.kind == .header) section = row.kind.header;
    }
    return section;
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
    return .{ .x = rr.x + self.renderer.widthUi(item.title) + 8, .y = rr.y + 9, .w = 18, .h = 18 };
}
/// Hover-only link icon left of the row (Zed's render_settings_item_link).
fn linkRect(rr: Rect) Rect {
    return .{ .x = rr.x - 24, .y = rr.y + 9, .w = 18, .h = 18 };
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

fn clipContent(self: *App, r: Rect) void {
    const c = scrollRect(self, dialogRect(self));
    const x = @max(c.x, r.x);
    const y = @max(c.y, r.y);
    self.clip(.{ .x = x, .y = y, .w = @max(0, @min(c.x + c.w, r.x + r.w) - x), .h = @max(0, @min(c.y + c.h, r.y + r.h) - y) });
}
fn drawItem(self: *App, rr: Rect, index: usize, focused: bool, divider: bool) !void {
    const t = self.settings.theme;
    const item = items[index];
    if (focused) try self.renderer.roundRect(rr.x - 10, rr.y + 2, rr.w + 20, rr.h - 4, 6, t.ghost_element_hover);
    const ctrl = controlRect(self, item, rr);
    const stacked = rr.w < ctrl.w + 180;
    const desc_width = if (stacked) rr.w else @max(1, ctrl.x - rr.x - 12);
    clipContent(self, .{ .x = rr.x, .y = rr.y, .w = @max(0, desc_width), .h = rr.h });
    // Link icon appears on row hover; becomes a green check once copied.
    const link = linkRect(rr);
    if (item.jsonpath.len > 0 and (rr.contains(self.mouse_x, self.mouse_y) or focused or self.settings_copied == index)) {
        if (self.settings_copied == index) {
            try self.renderer.icon(icons.svg("ui:check"), link.x + 1, link.y + 1, 16, .{ 126, 209, 140, 255 });
        } else {
            if (hovered(self, link)) try self.renderer.roundRect(link.x, link.y, link.w, link.h, 3, t.ghost_element_hover);
            try self.renderer.icon(icons.svg("ui:link"), link.x + 1, link.y + 1, 16, t.muted);
        }
    }
    try self.renderer.textUi(item.title, rr.x, rr.y + 26, t.text);
    var rest = if (item.desc.len > 0) item.desc else item.jsonpath;
    var baseline = rr.y + 44;
    var code = false;
    while (rest.len > 0) {
        const end = helpers.lineEnd(rest, desc_width, self, measureSmall);
        // Backtick code spans render in the buffer font (Zed's render_code_spans).
        var seg = rest[0..end];
        var x = rr.x;
        while (seg.len > 0) {
            const tick = std.mem.indexOfScalar(u8, seg, '`') orelse seg.len;
            const part = seg[0..tick];
            if (part.len > 0) {
                if (code) {
                    try self.renderer.textMonoXSmall(part, x, baseline, t.text);
                    x += self.renderer.widthMonoXSmall(part);
                } else {
                    try self.renderer.textSmall(part, x, baseline, t.muted);
                    x += self.renderer.widthSmall(part);
                }
            }
            if (tick < seg.len) {
                code = !code;
                seg = seg[tick + 1 ..];
            } else break;
        }
        rest = std.mem.trimStart(u8, rest[end..], " ");
        baseline += 16;
    }
    self.clip(scrollRect(self, dialogRect(self)));
    if (helpers.changed(self.settings, item.id) or (item.kind == .value and self.settings_document != null and self.settings_document.?.get(item.path) != null)) {
        const reset = resetRect(self, item, rr);
        if (hovered(self, reset)) try self.renderer.roundRect(reset.x, reset.y, reset.w, reset.h, 3, t.element_hover);
        try self.renderer.icon(icons.svg("ui:undo"), reset.x + 1, reset.y + 1, 16, if (hovered(self, reset)) t.text else t.accent);
    }
    if (divider) try self.renderer.rect(rr.x, rr.y + rr.h - 1, rr.w, 1, t.border_variant);

    switch (item.kind) {
        .value => {
            const value = valueText(self, item);
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
                const on = std.mem.eql(u8, value, "true");
                const sy = ctrl.y + (ctrl.h - 18) / 2;
                try self.renderer.roundBox(ctrl.x, sy, ctrl.w, 18, 9, if (on) t.accent else t.element_background, if (on) t.accent else t.border);
                try self.renderer.roundRect(if (on) ctrl.x + ctrl.w - 16 else ctrl.x + 2, sy + 2, 14, 14, 7, if (on) t.editor else t.muted);
                return;
            }
            try self.renderer.roundBox(ctrl.x, ctrl.y, ctrl.w, ctrl.h, radius, t.element_background, if (focused) t.border_focused else t.border);
            clipContent(self, .{ .x = ctrl.x + 8, .y = ctrl.y, .w = ctrl.w - 16, .h = ctrl.h });
            const text = if (focused and self.settings_editing_json) self.settings_number[0..self.settings_number_len] else valueText(self, item);
            try self.renderer.textSmall(text, ctrl.x + 8, ctrl.y + 18, t.text);
            self.clip(scrollRect(self, dialogRect(self)));
        },
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
            try self.renderer.icon(icons.svg("ui:chevron_up_down"), ctrl.x + ctrl.w - 22, ctrl.y + 6, 14, t.muted);
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

fn maxScroll(self: *App, r: Rect, lay: *const Layout) f32 {
    return @max(0, lay.height + content_pad_top * 2 - scrollRect(self, r).h);
}
fn clampScroll(self: *App, r: Rect, lay: *const Layout) void {
    self.settings_scroll = std.math.clamp(self.settings_scroll, 0, maxScroll(self, r, lay));
}


pub fn scroll(self: *App, dy: f32) void {
    self.settings_dropdown = false;
    if (self.mouse_x < dialogRect(self).x + sidebar_w) {
        var nav_buffer: [max_nav]NavEntry = undefined;
        const count = navEntries(self, dialogRect(self), &nav_buffer).len;
        const available = dialogRect(self).h - sidebar_pad - search_h - 12 - nav_footer_h;
        const limit = @max(0, @as(f32, @floatFromInt(count)) * nav_row_h - available);
        self.settings_nav_scroll = std.math.clamp(self.settings_nav_scroll + dy, 0, limit);
        return;
    }
    self.settings_scroll += dy;
    var lay = layout(self);
    clampScroll(self, dialogRect(self), &lay);
}

/// Keep the focused item fully inside the content viewport.
fn revealFocused(self: *App) void {
    const lay = layout(self);
    const index = focusedItem(self, &lay) orelse return;
    const row = findRow(&lay, index) orelse return;
    const view = scrollRect(self, dialogRect(self)).h - content_pad_top * 2;
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
    if (self.settings_window != null and my < r.y) {
        // Titlebar strip: the window manager drags it; the X is clickable here.
        const close: Rect = .{ .x = r.x + r.w - titlebar_h, .y = r.y - titlebar_h, .w = titlebar_h, .h = titlebar_h };
        if (close.contains(mx, my)) self.closeSettings();
        return;
    }
    if (!r.contains(mx, my)) {
        self.closeSettings();
        return;
    }
    if (self.settings_window == null and closeRect(r).contains(mx, my)) {
        self.closeSettings();
        return;
    }
    if (searchRect(r).contains(mx, my)) {
        if (query(self).len > 0 and clearQueryRect(searchRect(r)).contains(mx, my)) {
            self.settings_query_len = 0;
            resetFocus(self);
        }
        self.settings_focus = .search;
        self.settings_editing_number = false;
        return;
    }
    if (mx < r.x + sidebar_w) {
        var buf: [max_nav]NavEntry = undefined;
        for (navEntries(self, r, &buf), 0..) |entry, ei| if (entry.rect.contains(mx, my)) {
            self.settings_focus = .nav;
            self.settings_nav_index = ei;
            self.settings_editing_number = false;
            openNavEntry(self, entry);
            return;
        };
        return;
    }
    // File-scope header and warning banner buttons.
    if (editFileRect(self, c).contains(mx, my)) return self.openConfigFile("settings.json");
    if (self.settings_document_error and bannerRect(c).contains(mx, my)) {
        const b = bannerRect(c);
        const fw = self.renderer.widthUi("Fix in settings.json") + 24;
        const fr: Rect = .{ .x = b.x + b.w - fw - 12, .y = b.y + (b.h - header_button_h) / 2, .w = fw, .h = header_button_h };
        if (fr.contains(mx, my)) return self.openConfigFile("settings.json");
        return;
    }
    if (!scrollRect(self, r).contains(mx, my)) return;
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
        if (item.jsonpath.len > 0 and linkRect(rr).contains(mx, my)) return copySettingsLink(self, index);
        if (resetRect(self, item, rr).contains(mx, my)) {
            if (item.kind == .value) return resetCatalogue(self, index);
            if (helpers.changed(self.settings, item.id)) return resetValue(self, item.id);
        }
        switch (item.kind) {
            .number => {
                if (minusRect(ctrl).contains(mx, my)) try stepNumber(self, item.id, -1);
                if (plusRect(ctrl).contains(mx, my)) try stepNumber(self, item.id, 1);
                if (ctrl.contains(mx, my) and !minusRect(ctrl).contains(mx, my) and !plusRect(ctrl).contains(mx, my)) beginNumber(self, item.id);
            },
            // Zed toggles a switch from anywhere on its row.
            .toggle => try toggle(self, item.id),
            .value => if (ctrl.contains(mx, my) or std.mem.eql(u8, item.default, "true") or std.mem.eql(u8, item.default, "false")) try activate(self, index),
            .dropdown, .button => if (ctrl.contains(mx, my)) try activate(self, index),
        }
        return;
    }
}

/// Zed's open_and_scroll_to_navbar_entry: a root opens the page and toggles
/// expansion; a section opens its page and scrolls the section into view.
fn openNavEntry(self: *App, entry: NavEntry) void {
    const was_current = entry.page == currentPage(self);
    self.settings_category = @backingInt(entry.page);
    self.settings_row = 0;
    self.settings_query_len = 0;
    if (entry.section) |section| {
        setExpanded(self, entry.page, true);
        scrollToSection(self, section);
    } else {
        setExpanded(self, entry.page, !(was_current and expanded(self, entry.page)));
        self.settings_scroll = 0;
    }
}
/// Zed's settings link (`zed://settings/<path>` → zid's own scheme).
fn copySettingsLink(self: *App, index: usize) !void {
    var buf: [256]u8 = undefined;
    const link = std.fmt.bufPrint(&buf, "zid://settings/{s}", .{items[index].jsonpath}) catch return;
    const text = try self.gpa.dupeSentinel(u8, link, 0);
    defer self.gpa.free(text);
    try sdl.clipboard.setText(text);
    self.settings_copied = index;
    self.notice("Copied: {s}", .{link});
}
/// ToggleFocusNav: focus the navbar on the current page's root entry.
fn focusNav(self: *App) void {
    self.settings_focus = .nav;
    self.settings_editing_number = false;
    var nav_buf: [max_nav]NavEntry = undefined;
    for (navEntries(self, dialogRect(self), &nav_buf), 0..) |entry, i| {
        if (entry.page == currentPage(self) and entry.section == null) {
            self.settings_nav_index = i;
            break;
        }
    }
    revealNav(self);
}
fn moveNav(self: *App, dir: i32) void {
    var nav_buf: [max_nav]NavEntry = undefined;
    const n = navEntries(self, dialogRect(self), &nav_buf).len;
    if (n == 0) return;
    const i: i32 = @intCast(self.settings_nav_index);
    self.settings_nav_index = @intCast(std.math.clamp(i + dir, 0, @as(i32, @intCast(n - 1))));
    revealNav(self);
}
/// PageUp/PageDown move between root entries (Zed's Focus{Previous,Next}RootNavEntry).
fn moveNavRoot(self: *App, dir: i32) void {
    var nav_buf: [max_nav]NavEntry = undefined;
    const entries = navEntries(self, dialogRect(self), &nav_buf);
    if (entries.len == 0) return;
    if (dir > 0) {
        var i = self.settings_nav_index + 1;
        while (i < entries.len) : (i += 1) if (entries[i].section == null) {
            self.settings_nav_index = i;
            break;
        };
    } else {
        var i = self.settings_nav_index;
        while (i > 0) {
            i -= 1;
            if (entries[i].section == null) {
                self.settings_nav_index = i;
                break;
            }
        }
    }
    revealNav(self);
}
fn revealNav(self: *App) void {
    const top = @as(f32, @floatFromInt(self.settings_nav_index)) * nav_row_h;
    const available = dialogRect(self).h - sidebar_pad - search_h - 12 - nav_footer_h;
    if (top < self.settings_nav_scroll) self.settings_nav_scroll = top;
    if (top + nav_row_h > self.settings_nav_scroll + available) self.settings_nav_scroll = top + nav_row_h - available;
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
    if (self.settings_editing_json) {
        if (self.settings_replace_input) {
            self.settings_number_len = 0;
            self.settings_replace_input = false;
        }
        const n = @min(text.len, self.settings_number.len - self.settings_number_len);
        @memcpy(self.settings_number[self.settings_number_len..][0..n], text[0..n]);
        self.settings_number_len += n;
        return;
    }
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

    if (self.settings_editing_json) {
        if (mods.left_control or mods.right_control) {
            switch (key) {
                .a => self.settings_replace_input = true,
                .v => {
                    const text = try sdl.clipboard.getText();
                    defer sdl.free(text);
                    typeText(self, text);
                },
                .c, .x => {
                    const text = try self.gpa.dupeSentinel(u8, self.settings_number[0..self.settings_number_len], 0);
                    defer self.gpa.free(text);
                    try sdl.clipboard.setText(text);
                    if (key == .x) self.settings_number_len = 0;
                },
                else => {},
            }
            return;
        }
        switch (key) {
            .escape => self.settings_editing_json = false,
            .return_key, .tab => if (focused) |index| try commitValue(self, index),
            .backspace => {
                if (self.settings_replace_input) {
                    self.settings_number_len = 0;
                    self.settings_replace_input = false;
                } else if (self.settings_number_len > 0) {
                    self.settings_number_len -= 1;
                    while (self.settings_number_len > 0 and self.settings_number[self.settings_number_len] & 0xc0 == 0x80) self.settings_number_len -= 1;
                }
            },
            else => {},
        }
        return;
    }
    // Zed's SettingsWindow bindings: Ctrl+F search, Ctrl+, open file,
    // Ctrl+Shift+E toggle nav focus.
    if (mods.left_control or mods.right_control) {
        switch (key) {
            .f => {
                self.settings_focus = .search;
                self.settings_editing_number = false;
                return;
            },
            .comma => return self.openConfigFile("settings.json"),
            .e => if (shift) {
                if (self.settings_focus == .nav) self.settings_focus = .controls else focusNav(self);
                return;
            },
            else => {},
        }
    }
    if (self.settings_editing_number) {
        switch (key) {
            .escape => self.settings_editing_number = false,
            .return_key, .tab => if (focused) |index| try commitNumber(self, items[index].id),
            // Zed's NumberField steps the value on up/down while editing.
            .up, .down => if (focused) |index| {
                try stepNumber(self, items[index].id, if (key == .up) 1 else -1);
                const v = std.fmt.bufPrint(&self.settings_number, "{d}", .{numberValue(self, items[index].id)}) catch return;
                self.settings_number_len = v.len;
            },
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
        .escape => self.closeSettings(),
        .backspace => if (self.settings_focus == .search and self.settings_query_len > 0) {
            var n = self.settings_query_len - 1;
            while (n > 0 and self.settings_query[n] & 0xc0 == 0x80) n -= 1;
            self.settings_query_len = n;
            resetFocus(self);
        },
        .tab => {
            if (self.settings_focus == .nav) {
                moveNav(self, if (shift) -1 else 1);
                return;
            }
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
        .up => if (self.settings_focus == .nav) {
            moveNav(self, -1);
        } else if (self.settings_row > 0) {
            self.settings_row -= 1;
        } else if (list.len == 0 and currentPage(self) == .keymap) {
            scroll(self, -binding_h);
        },
        .down => if (self.settings_focus == .nav) {
            moveNav(self, 1);
        } else if (list.len > 0) {
            self.settings_row = @min(self.settings_row + 1, list.len - 1);
        } else if (currentPage(self) == .keymap) {
            scroll(self, binding_h);
        },
        .page_up => if (self.settings_focus == .nav) moveNavRoot(self, -1) else scroll(self, -200),
        .page_down => if (self.settings_focus == .nav) moveNavRoot(self, 1) else scroll(self, 200),
        .home => if (self.settings_focus == .nav) {
            self.settings_nav_index = 0;
            revealNav(self);
        },
        .end => if (self.settings_focus == .nav) {
            var nav_buf: [max_nav]NavEntry = undefined;
            self.settings_nav_index = navEntries(self, dialogRect(self), &nav_buf).len -| 1;
            revealNav(self);
        },
        // Zed: left toggles nav focus; in the navbar it collapses the root.
        .left => if (self.settings_focus == .nav) {
            var nav_buf: [max_nav]NavEntry = undefined;
            const entries = navEntries(self, dialogRect(self), &nav_buf);
            if (self.settings_nav_index < entries.len) {
                const entry = entries[self.settings_nav_index];
                if (entry.section == null and expanded(self, entry.page)) {
                    setExpanded(self, entry.page, false);
                    return;
                }
            }
            self.settings_focus = .controls;
        } else focusNav(self),
        .right => if (self.settings_focus == .nav) {
            var nav_buf: [max_nav]NavEntry = undefined;
            const entries = navEntries(self, dialogRect(self), &nav_buf);
            if (self.settings_nav_index < entries.len) {
                const entry = entries[self.settings_nav_index];
                if (entry.section == null and !expanded(self, entry.page)) setExpanded(self, entry.page, true);
            }
        },
        .delete => {
            if (self.settings_focus == .controls) if (focused) |index| if (items[index].kind == .value) {
                return resetCatalogue(self, index);
            };
            const id: ?Id = if (focused) |index| items[index].id else null;
            if (helpers.keyboardResetTarget(self.settings, id, self.settings_focus == .controls)) |target| try resetValue(self, target);
        },
        .return_key => if (self.settings_focus == .nav) {
            var nav_buf: [max_nav]NavEntry = undefined;
            const entries = navEntries(self, dialogRect(self), &nav_buf);
            if (self.settings_nav_index < entries.len) {
                openNavEntry(self, entries[self.settings_nav_index]);
                self.settings_focus = .controls;
            }
        } else if (self.settings_focus == .controls) {
            if (focused) |index| {
                if (items[index].kind == .number) beginNumber(self, items[index].id) else try activate(self, index);
            }
        },
        else => {},
    }
    if ((key == .up or key == .down) and self.settings_focus != .nav) {
        self.settings_focus = .controls;
        revealFocused(self);
    }
}

fn resetCatalogue(self: *App, index: usize) !void {
    if (self.settings_document) |*document| {
        document.remove(items[index].path);
        try document.save(self.gpa, self.io, self.config_root);
        try self.reloadConfig();
        try self.refreshProject();
        self.config_stamp = self.configurationStamp();
    }
}
fn valueText(self: *App, item: Item) []const u8 {
    if (self.settings_document) |*document| if (document.get(item.path)) |value| {
        return std.json.Stringify.valueAlloc(self.frame_arena.allocator(), value, .{}) catch item.default;
    };
    return item.default;
}
fn beginValue(self: *App, index: usize) !void {
    const text = valueText(self, items[index]);
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) {
        const replacement = if (std.mem.eql(u8, text, "true")) "false" else "true";
        @memcpy(self.settings_number[0..replacement.len], replacement);
        self.settings_number_len = replacement.len;
        try commitValue(self, index);
        return;
    }
    if (text.len > self.settings_number.len) {
        self.notice("Value too large for inline editing; use settings.json", .{});
        return;
    }
    @memcpy(self.settings_number[0..text.len], text);
    self.settings_number_len = text.len;
    self.settings_editing_json = true;
    self.settings_replace_input = true;
}
fn commitValue(self: *App, index: usize) !void {
    const Document = @import("../settings_document.zig").Document;
    if (self.settings_document == null) self.settings_document = try Document.parse(self.gpa, "{}");
    const old = try std.json.Stringify.valueAlloc(self.gpa, self.settings_document.?.parsed.value, .{});
    defer self.gpa.free(old);
    var candidate = try Document.parse(self.gpa, old);
    defer candidate.deinit();
    candidate.setJson(items[index].path, self.settings_number[0..self.settings_number_len]) catch {
        self.notice("Invalid JSON value (strings need quotes)", .{});
        return;
    };
    _ = config.settingsFromDocument(self.gpa, &candidate) catch |err| {
        self.notice("Invalid setting: {s}", .{@errorName(err)});
        return;
    };
    try candidate.save(self.gpa, self.io, self.config_root);
    self.settings_editing_json = false;
    try self.reloadConfig();
    try self.refreshProject();
    self.config_stamp = self.configurationStamp();
    self.notice("Setting saved; unimplemented features remain inactive", .{});
}
