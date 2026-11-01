//! One responsibility per view/controller; application owns retained state.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const syntax = zid.syntax;
const icons = @import("icons");
const pure_geometry = @import("geometry.zig");

/// Zed's `Tab::container_height` is `DynamicSpacing::Base32` (32px at the Default density)
/// with a 1px bottom border (`crates/ui/src/components/tab.rs`), so content is 31px tall.
/// Children are vertically centred (`items_center`), and the label baseline keeps the
/// optical offset from the previous 35px layout.
const content_offset: f32 = 1;
const padding_x: f32 = 8;
const icon_size: f32 = 16;
const label_gap: f32 = 8;
const label_baseline_offset: f32 = 21;
/// Zed keeps the tab start slot (12px + 2px gap) even when `tabs.file_icons` is off,
/// so labels start 22px in; the end slot adds 4px gap, the close button and padding.
const start_slot: f32 = 14;

/// Shared tab content and end-slot geometry for painting and parent hit testing.
/// Zed's square close control is 24px; this view reserves a 28px trailing slot.
pub const TabGeometry = struct {
    label_clip: Rect,
    icon_x: f32,
    icon_y: f32,
    label_x: f32,
    label_baseline: f32,
    end_slot: Rect,
    close_icon_x: f32,
    close_icon_y: f32,
    dirty_dot_x: f32,
    dirty_dot_y: f32,
};

fn centredY(tab: Rect, size: f32) f32 {
    return tab.y + @round((tab.h - content_offset - size) / 2);
}

pub fn geometry(tab: Rect) TabGeometry {
    return .{
        .label_clip = .{ .x = tab.x + padding_x, .y = tab.y, .w = @max(0, tab.w - 30), .h = tab.h },
        .icon_x = tab.x + padding_x,
        .icon_y = centredY(tab, icon_size),
        .label_x = tab.x + padding_x + icon_size + label_gap,
        .label_baseline = tab.y + label_baseline_offset,
        .end_slot = blk: {
            const slot = pure_geometry.tabEndSlot(tab.x, tab.w, tab.y, tab.h);
            break :blk .{ .x = slot.x, .y = slot.y, .w = slot.w, .h = slot.h };
        },
        .close_icon_x = tab.x + tab.w - 24,
        .close_icon_y = centredY(tab, 14),
        .dirty_dot_x = tab.x + tab.w - 22,
        .dirty_dot_y = centredY(tab, 10),
    };
}

/// Parent mouse handling should use this instead of a fixed `tab.x + tab.w - 24` test.
pub fn closeHit(tab: Rect, mx: f32, my: f32) bool {
    const g = geometry(tab);
    return tab.contains(mx, my) and pure_geometry.contains(.{ .x = g.end_slot.x, .y = g.end_slot.y, .w = g.end_slot.w, .h = g.end_slot.h }, mx, my);
}

/// Zed `TabBar` start and end slots (`ui/src/components/tab_bar.rs`): `Base06`
/// horizontal padding, `Base04` gaps, a 1px border towards the tabs. The start slot
/// holds the nav-history buttons (`pane.rs`, `show_nav_history_buttons`); the end
/// slot holds New, Split and Zoom (`default_render_tab_bar_buttons`), shown only
/// while the pane is focused.
pub const BarButton = enum { back, forward, new, split, zoom };
const slot_pad: f32 = 6;
const slot_gap: f32 = 4;
const slot_button: f32 = 22;
fn slotWidth(count: usize) f32 {
    if (count == 0) return 0;
    const n: f32 = @floatFromInt(count);
    return slot_pad * 2 + n * slot_button + (n - 1) * slot_gap + 1;
}
fn paneFocused(self: *App) bool {
    return switch (@import("../input/commands.zig").focus(self)) {
        .editor, .workspace, .buffer_search => true,
        else => false,
    };
}
const start_buttons = [_]BarButton{ .back, .forward };
const end_buttons = [_]BarButton{ .new, .split, .zoom };
fn startCount(self: *App) usize {
    return if (self.settings.tab_nav_buttons) start_buttons.len else 0;
}
fn endCount(self: *App) usize {
    return if (self.settings.tab_bar_buttons and paneFocused(self)) end_buttons.len else 0;
}
const ButtonHit = struct { button: BarButton, rect: Rect };
fn buttons(self: *App, bar: Rect, out: *[5]ButtonHit) []ButtonHit {
    var n: usize = 0;
    const y = bar.y + @round((bar.h - 1 - slot_button) / 2);
    var x = bar.x + slot_pad;
    for (start_buttons[0..startCount(self)]) |b| {
        out[n] = .{ .button = b, .rect = .{ .x = x, .y = y, .w = slot_button, .h = slot_button } };
        n += 1;
        x += slot_button + slot_gap;
    }
    x = bar.x + bar.w - slotWidth(endCount(self)) + 1 + slot_pad;
    for (end_buttons[0..endCount(self)]) |b| {
        out[n] = .{ .button = b, .rect = .{ .x = x, .y = y, .w = slot_button, .h = slot_button } };
        n += 1;
        x += slot_button + slot_gap;
    }
    return out[0..n];
}
pub fn buttonAt(self: *App, mx: f32, my: f32) !?BarButton {
    const bar = try self.layout.rect(self.layout.tabs);
    var buf: [5]ButtonHit = undefined;
    for (buttons(self, bar, &buf)) |hit| if (hit.rect.contains(mx, my)) return hit.button;
    return null;
}
pub fn clickButton(self: *App, button: BarButton) !void {
    switch (button) {
        // Navigation history is not recorded yet, so both buttons stay disabled.
        .back, .forward => {},
        .new => try self.runCommand(.@"workspace::NewFile"),
        .split => self.notice("Split panes are not implemented yet", .{}),
        .zoom => self.notice("Pane zoom is not implemented yet", .{}),
    }
}

pub fn drawTabs(self: *App) !void {
    const full = try self.layout.rect(self.layout.tabs);
    const t = self.settings.theme;
    self.tab_hits.clearRetainingCapacity();
    try self.fill(full, t.tab_bar);
    try self.renderer.rect(full.x, full.y + full.h - 1, full.w, 1, t.border);
    {
        var buf: [5]ButtonHit = undefined;
        const start_w = slotWidth(startCount(self));
        const end_w = slotWidth(endCount(self));
        if (start_w > 0) try self.renderer.rect(full.x + start_w - 1, full.y, 1, full.h, t.border);
        if (end_w > 0) try self.renderer.rect(full.x + full.w - end_w, full.y, 1, full.h, t.border);
        for (buttons(self, full, &buf)) |hit| {
            const tip: struct { []const u8, []const u8 } = switch (hit.button) {
                .back => .{ "Go Back", "pane::GoBack" },
                .forward => .{ "Go Forward", "pane::GoForward" },
                .new => .{ "New...", "" },
                .split => .{ "Split Pane", "" },
                .zoom => .{ "Zoom In", "workspace::ToggleZoom" },
            };
            @import("tooltip.zig").register(self, .{ .rect = hit.rect, .title = tip[0], .action = tip[1] });
            const disabled = hit.button == .back or hit.button == .forward;
            if (!disabled and hit.rect.contains(self.mouse_x, self.mouse_y)) try self.renderer.roundRect(hit.rect.x, hit.rect.y, hit.rect.w, hit.rect.h, 4, t.ghost_element_hover);
            const name = switch (hit.button) {
                .back => "ui:arrow_left",
                .forward => "ui:arrow_right",
                .new => "ui:plus",
                .split => "ui:split",
                .zoom => "ui:maximize",
            };
            var color = t.icon;
            if (disabled) color = t.icon_disabled;
            try self.renderer.icon(icons.svg(name), hit.rect.x + 4, hit.rect.y + 4, 14, color);
        }
    }
    const start_w = slotWidth(startCount(self));
    const bar: Rect = .{ .x = full.x + start_w, .y = full.y, .w = @max(0, full.w - start_w - slotWidth(endCount(self))), .h = full.h };
    self.clip(bar);
    defer self.renderer.setClip(null);
    self.tabs_first = @min(self.tabs_first, self.workspace.active);
    // Ensure the active tab is visible, even when many documents are open.
    var needed: f32 = 0;
    for (self.workspace.documents.items[self.tabs_first..if (self.workspace.documents.items.len > 0) self.workspace.active + 1 else 0]) |doc| needed += self.tabWidth(&doc);
    while (needed > bar.w and self.tabs_first < self.workspace.active) {
        needed -= self.tabWidth(&self.workspace.documents.items[self.tabs_first]);
        self.tabs_first += 1;
    }
    var x = bar.x;
    // The onboarding page is a pane item ahead of the documents (Zed opens it as the
    // first item of a new workspace). Labels never carry a file icon.
    self.onboarding_tab = .{};
    if (self.onboarding) |state| {
        const label = state.kind.label();
        const w = @min(self.renderer.widthUi(label) + padding_x + start_slot + 26, bar.w);
        const r: Rect = .{ .x = x, .y = bar.y, .w = w, .h = bar.h };
        const g = geometry(r);
        if (state.active) {
            try self.fill(r, t.active_tab);
            try self.renderer.rect(x, bar.y, w, 1, t.accent);
        } else try self.fill(.{ .x = x, .y = bar.y, .w = w, .h = bar.h - 1 }, t.inactive_tab);
        try self.renderer.rect(x + w - 1, bar.y, 1, bar.h, t.border);
        try self.renderer.textUi(label, g.icon_x + start_slot, g.label_baseline, if (state.active) t.text else t.muted);
        if (r.contains(self.mouse_x, self.mouse_y)) try self.renderer.icon(icons.svg("close"), g.close_icon_x, g.close_icon_y, 14, t.muted);
        self.onboarding_tab = r;
        x += w;
    }
    for (self.workspace.documents.items[self.tabs_first..], self.tabs_first..) |*doc, index| {
        if (x >= bar.x + bar.w) break;
        const w = @min(self.tabWidth(doc), @max(0, bar.x + bar.w - x));
        const r: Rect = .{ .x = x, .y = bar.y, .w = w, .h = bar.h };
        const g = geometry(r);
        const is_active = index == self.workspace.active and !self.keymap_editor_open and !(if (self.onboarding) |o| o.active else false);
        // Zed's inactive tabs keep their 1px bottom border; active tabs open into the editor.
        if (is_active) {
            try self.fill(r, t.active_tab);
            try self.renderer.rect(x, bar.y, w, 1, t.accent);
        } else try self.fill(.{ .x = x, .y = bar.y, .w = w, .h = bar.h - 1 }, t.inactive_tab);
        try self.renderer.rect(x + w - 1, bar.y, 1, bar.h, t.border);
        const name = if (doc.path) |path| std.fs.path.basename(path) else "untitled";
        self.clip(g.label_clip);
        // Zed `tabs.file_icons` defaults to false; the label then starts at the padding.
        if (self.settings.tab_file_icons) try self.drawIcon(self.fileIcon(doc.path orelse ""), g.icon_x, g.icon_y, 16, t.muted);
        try self.renderer.textUi(name, if (self.settings.tab_file_icons) g.label_x else g.icon_x + start_slot, g.label_baseline, if (is_active) t.text else t.muted);
        self.clip(bar);
        // `show_close_button: "hover"`: the close button is `visible_on_hover` for every
        // tab; a dirty item shows its dot in the same slot otherwise.
        if (r.contains(self.mouse_x, self.mouse_y)) try self.renderer.icon(icons.svg("close"), g.close_icon_x, g.close_icon_y, 14, t.muted) else if (doc.dirty()) try self.renderer.icon(icons.svg("circle"), g.dirty_dot_x, g.dirty_dot_y, 10, t.muted);
        // Zed's tab tooltip is the item's full path.
        if (doc.path) |path| {
            // Paths under $HOME are shown with `~` (Zed `tildify`).
            const home = self.env_home orelse "";
            const shown = if (home.len > 0 and std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/')
                std.fmt.allocPrint(self.frame_arena.allocator(), "~{s}", .{path[home.len..]}) catch path
            else
                path;
            @import("tooltip.zig").register(self, .{ .rect = r, .title = shown });
        }
        try self.tab_hits.append(self.gpa, .{ .rect = r, .index = index });
        x += w;
    }
    // The keymap editor is a workspace item like in Zed; it has no document behind it.
    if (self.keymap_editor_open and x < bar.x + bar.w) {
        const label = "Keymap Editor";
        const w = @min(self.renderer.widthUi(label) + 72, bar.x + bar.w - x);
        const g = geometry(.{ .x = x, .y = bar.y, .w = w, .h = bar.h });
        try self.fill(.{ .x = x, .y = bar.y, .w = w, .h = bar.h }, t.active_tab);
        try self.renderer.rect(x, bar.y, w, 1, t.accent);
        try self.renderer.rect(x + w - 1, bar.y, 1, bar.h, t.border);
        try self.renderer.icon(icons.svg("ui:notepad"), g.icon_x, g.icon_y, 16, t.muted);
        try self.renderer.textUi(label, g.label_x, g.label_baseline, t.text);
        try self.renderer.icon(icons.svg("close"), g.close_icon_x, g.close_icon_y, 14, t.muted);
        self.keymap_tab = .{ .x = x, .y = bar.y, .w = w, .h = bar.h };
    }
}
pub fn tabWidth(self: *App, doc: *const zid.Document) f32 {
    // Zed tabs are content-sized with `min_w_6` (24px); the 250px cap is Zid's.
    const icon: f32 = if (self.settings.tab_file_icons) icon_size + label_gap else start_slot;
    return std.math.clamp(self.renderer.widthUi(if (doc.path) |p| std.fs.path.basename(p) else "untitled") + padding_x + icon + 26, 24, 250);
}
