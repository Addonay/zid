//! Zed `ui::ContextMenu` (`crates/ui/src/components/context_menu.rs`): the menu used by
//! right-click menus, the title bar's application and user menus and popovers.
//!
//! Look: `elevation_2` (elevated-surface background, 8px radius, 1px `border.variant`,
//! two soft shadows), `py_1`, at least 200px wide. Entries are inset `ListItem`s one
//! comfortable UI line (23px) tall with the label on the left and the action's
//! keybinding, muted, on the right; disabled entries use `text.disabled`; separators
//! are 1px `border.variant` lines with 6px vertical margins; headers are muted small
//! labels. The hovered or keyboard-selected entry gets a rounded highlight.
//!
//! Behaviour: anchored at the click point (or under a trigger), shifted to stay inside
//! the window like GPUI's `anchored().snap_to_window()`. While open it has focus and the
//! `menu` key context: up/down/home/end move, enter confirms, escape cancels. A click
//! outside dismisses it and still reaches whatever was clicked; a click on an enabled
//! entry dismisses it and runs the entry's action. Keybinding hints, labels and
//! disabled state are resolved when the menu opens, as Zed builds menus.
const std = @import("std");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const keymap = @import("../keymap.zig");
const icons = @import("icons");

pub const max_items = 64;
pub const Entry = struct {
    label: []const u8,
    /// Zed action name; menus.zig runs it through Zid's registry or a target handler.
    action: []const u8 = "",
    disabled: bool = false,
    /// A toggle shows a check mark when true (Zed `toggleable_entry`).
    checked: ?bool = null,
    /// Override the keybinding lookup with explicit text (or "" for none).
    key: ?[]const u8 = null,
    /// Action argument (a URL for `zed::OpenBrowser`, a menu index).
    arg: []const u8 = "",
};
pub const Item = union(enum) { separator, header: []const u8, entry: Entry };
/// What the menu acts on; menus.zig interprets actions against it.
pub const Target = union(enum) {
    none,
    editor,
    tab: usize,
    /// Visible project-panel row (0 is the root).
    panel: usize,
    /// Empty project-panel space.
    panel_blank,
    app_menu: usize,
    user,
    lsp,
};
/// `bottom_left` opens upward from a status-bar button.
pub const Anchor = enum { top_left, top_right, bottom_left };

pub const Menu = struct {
    items: [max_items]Item = undefined,
    keys: [max_items][40]u8 = undefined,
    key_lens: [max_items]u8 = @splat(0),
    len: usize = 0,
    target: Target = .none,
    /// Anchor point in window coordinates.
    x: f32 = 0,
    y: f32 = 0,
    anchor: Anchor = .top_left,
    selected: ?usize = null,
    /// Text storage for dynamic labels (a header with the user name, a path).
    text: [256]u8 = undefined,
    text_len: usize = 0,
    /// Computed by `layout`.
    rect: Rect = .{},

    pub fn separator(self: *Menu) void {
        if (self.len == 0 or self.len == max_items) return;
        if (self.items[self.len - 1] == .separator) return;
        self.items[self.len] = .separator;
        self.len += 1;
    }
    pub fn header(self: *Menu, label: []const u8) void {
        if (self.len == max_items) return;
        self.items[self.len] = .{ .header = label };
        self.len += 1;
    }
    pub fn entry(self: *Menu, e: Entry) void {
        if (self.len == max_items) return;
        self.items[self.len] = .{ .entry = e };
        self.len += 1;
    }
    pub fn action(self: *Menu, label: []const u8, name: []const u8) void {
        self.entry(.{ .label = label, .action = name });
    }
    pub fn actionDisabledWhen(self: *Menu, disabled: bool, label: []const u8, name: []const u8) void {
        self.entry(.{ .label = label, .action = name, .disabled = disabled });
    }
    /// Copies `value` into the menu's own storage so the label outlives the caller.
    pub fn ownText(self: *Menu, value: []const u8) []const u8 {
        const n = @min(value.len, self.text.len - self.text_len);
        @memcpy(self.text[self.text_len..][0..n], value[0..n]);
        defer self.text_len += n;
        return self.text[self.text_len..][0..n];
    }
    /// Drops a trailing separator, as Zed's builders never end on one.
    pub fn finish(self: *Menu) void {
        while (self.len > 0 and self.items[self.len - 1] == .separator) self.len -= 1;
    }
    fn selectable(self: *const Menu, i: usize) bool {
        return switch (self.items[i]) {
            .entry => |e| !e.disabled,
            else => false,
        };
    }
};

const pad_y: f32 = 4; // py_1
const pad_x: f32 = 4; // px_1 around inset rows
const row_h: f32 = 23; // comfortable line height for 14px text
const sep_h: f32 = 13; // 1px + my(Base06) * 2
const text_inset: f32 = 6; // ListItem inset padding inside the row
const key_gap: f32 = 24;
const min_width: f32 = 200;

fn itemHeight(item: Item) f32 {
    return switch (item) {
        .separator => sep_h,
        else => row_h,
    };
}
fn keyText(menu: *const Menu, i: usize) []const u8 {
    return menu.keys[i][0..menu.key_lens[i]];
}

/// Resolves keybinding hints with the current focus path and opens the menu.
pub fn open(app: *App, menu: Menu) void {
    // Hints resolve against the view that deployed the menu (Zed `builder.context(focus)`),
    // so the focus path is taken before the menu itself takes focus.
    app.context_menu = null;
    var path_buf: [6]keymap.Context = undefined;
    var ext_buf: [16]u8 = undefined;
    const path = @import("../input/commands.zig").focusPath(app, &path_buf, &ext_buf);
    app.context_menu = menu;
    const m = &app.context_menu.?;
    m.finish();
    for (m.items[0..m.len], 0..) |item, i| {
        m.key_lens[i] = 0;
        const e = switch (item) {
            .entry => |e| e,
            else => continue,
        };
        const text: []const u8 = if (e.key) |k| k else blk: {
            if (e.action.len == 0) break :blk "";
            const chord = app.keymap.chordFor(e.action, path) orelse break :blk "";
            var writer: std.Io.Writer = .fixed(&m.keys[i]);
            chord.format(&writer) catch break :blk "";
            m.key_lens[i] = @intCast(writer.buffered().len);
            continue;
        };
        const n = @min(text.len, m.keys[i].len);
        @memcpy(m.keys[i][0..n], text[0..n]);
        m.key_lens[i] = @intCast(n);
    }
}
pub fn close(app: *App) void {
    app.context_menu = null;
}
pub fn isOpen(app: *const App) bool {
    return app.context_menu != null;
}

/// Size the menu and snap it inside the window (GPUI `snap_to_window`).
fn layout(app: *App, m: *Menu) void {
    var w: f32 = min_width;
    var h: f32 = pad_y * 2 + 2;
    for (m.items[0..m.len], 0..) |item, i| {
        h += itemHeight(item);
        const label = switch (item) {
            .entry => |e| e.label,
            .header => |text| text,
            .separator => continue,
        };
        const check: f32 = if (item == .entry and item.entry.checked != null) 20 else 0;
        const key = keyText(m, i);
        const content = check + app.renderer.widthUi(label) + if (key.len > 0) key_gap + app.renderer.widthUi(key) else 0;
        w = @max(w, content + (pad_x + text_inset) * 2 + 2);
    }
    var x = if (m.anchor == .top_right) m.x - w else m.x;
    var y = if (m.anchor == .bottom_left) m.y - h else m.y;
    const win_w = app.layout.width;
    const win_h = app.layout.height;
    if (x + w > win_w) x = win_w - w;
    if (y + h > win_h) y = win_h - h;
    m.rect = .{ .x = @max(0, x), .y = @max(0, y), .w = w, .h = h };
}
fn rowRect(m: *const Menu, index: usize) Rect {
    var y = m.rect.y + 1 + pad_y;
    for (m.items[0..index]) |item| y += itemHeight(item);
    return .{ .x = m.rect.x + 1 + pad_x, .y = y, .w = m.rect.w - 2 - pad_x * 2, .h = itemHeight(m.items[index]) };
}
pub fn entryAt(app: *App, mx: f32, my: f32) ?usize {
    const m = &(app.context_menu orelse return null);
    if (!m.rect.contains(mx, my)) return null;
    for (0..m.len) |i| if (rowRect(m, i).contains(mx, my)) return i;
    return null;
}

pub fn draw(app: *App) !void {
    const m = &(app.context_menu orelse return);
    layout(app, m);
    const t = app.settings.theme;
    const r = &app.renderer;
    const box = m.rect;
    // ElevatedSurface shadows: (0, 2, 3 blur, 12%) and a wider faint one.
    try r.roundRect(box.x - 1, box.y + 1, box.w + 2, box.h + 2, 9, .{ 0, 0, 0, 20 });
    try r.roundRect(box.x - 2, box.y + 2, box.w + 4, box.h + 3, 10, .{ 0, 0, 0, 10 });
    try r.roundBox(box.x, box.y, box.w, box.h, 8, t.elevated_surface, t.border_variant);
    app.clip(box);
    defer r.setClip(null);
    const hovered = entryAt(app, app.mouse_x, app.mouse_y);
    for (m.items[0..m.len], 0..) |item, i| {
        const row = rowRect(m, i);
        switch (item) {
            .separator => try r.rect(box.x + 1, row.y + 6, box.w - 2, 1, t.border_variant),
            .header => |label| try r.textSmall(label, row.x + text_inset, row.y + 16, t.muted),
            .entry => |e| {
                const highlighted = !e.disabled and (m.selected == i or (hovered == i and m.selected == null));
                if (highlighted) try r.roundRect(row.x, row.y, row.w, row.h, 4, if (m.selected == i) t.ghost_element_selected else t.ghost_element_hover);
                var x = row.x + text_inset;
                if (e.checked) |on| {
                    if (on) try r.icon(icons.svg("ui:check"), x, row.y + 5, 14, t.accent);
                    x += 20;
                }
                try r.textUi(e.label, x, row.y + 16, if (e.disabled) t.text_disabled else t.text);
                const key = keyText(m, i);
                if (key.len > 0) try r.textUi(key, row.x + row.w - text_inset - r.widthUi(key), row.y + 16, if (e.disabled) t.text_disabled else t.muted);
            },
        }
    }
}

/// Mouse movement over the menu clears keyboard selection (Zed `clear_selected` on hover).
pub fn hover(app: *App, mx: f32, my: f32) void {
    const m = &(app.context_menu orelse return);
    if (entryAt(app, mx, my) != null) m.selected = null;
}

/// Returns true when the click was consumed by the menu.
pub fn click(app: *App, mx: f32, my: f32) !bool {
    const m = app.context_menu orelse return false;
    if (!m.rect.contains(mx, my)) {
        close(app);
        return false;
    }
    const i = entryAt(app, mx, my) orelse return true;
    if (!m.selectable(i)) return true;
    try confirmIndex(app, i);
    return true;
}
fn confirmIndex(app: *App, i: usize) !void {
    const m = app.context_menu orelse return;
    const e = m.items[i].entry;
    close(app);
    try @import("../menus.zig").run(app, m.target, e);
}

/// `menu::*` actions while the menu has focus.
pub fn command(app: *App, name: []const u8) !void {
    const m = &(app.context_menu orelse return);
    const eql = std.mem.eql;
    if (eql(u8, name, "menu::Cancel")) return close(app);
    if (eql(u8, name, "menu::Confirm") or eql(u8, name, "menu::SecondaryConfirm")) {
        if (m.selected) |i| try confirmIndex(app, i);
        return;
    }
    const Move = enum { first, last, next, previous };
    const move: Move = if (eql(u8, name, "menu::SelectFirst")) .first else if (eql(u8, name, "menu::SelectLast")) .last else if (eql(u8, name, "menu::SelectNext")) .next else if (eql(u8, name, "menu::SelectPrevious")) .previous else return;
    if (m.len == 0) return;
    const forward = move == .first or move == .next;
    // Start just outside the range for first/last (or nothing selected), else at the selection.
    var i: usize = switch (move) {
        .first => m.len - 1,
        .last => 0,
        .next => m.selected orelse m.len - 1,
        .previous => m.selected orelse 0,
    };
    for (0..m.len) |_| {
        i = if (forward) (i + 1) % m.len else (i + m.len - 1) % m.len;
        if (m.selectable(i)) {
            m.selected = i;
            return;
        }
    }
}
