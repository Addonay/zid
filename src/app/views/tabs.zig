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
};

pub fn geometry(tab: Rect) TabGeometry {
    return .{
        .label_clip = .{ .x = tab.x + 8, .y = tab.y, .w = @max(0, tab.w - 36), .h = tab.h },
        .icon_x = tab.x + 10,
        .icon_y = tab.y + 10,
        .label_x = tab.x + 34,
        .label_baseline = tab.y + 23,
        .end_slot = blk: {
            const slot = pure_geometry.tabEndSlot(tab.x, tab.w, tab.y, tab.h);
            break :blk .{ .x = slot.x, .y = slot.y, .w = slot.w, .h = slot.h };
        },
        .close_icon_x = tab.x + tab.w - 24,
        .close_icon_y = tab.y + 10,
    };
}

/// Parent mouse handling should use this instead of a fixed `tab.x + tab.w - 24` test.
pub fn closeHit(tab: Rect, mx: f32, my: f32) bool {
    const g = geometry(tab);
    return tab.contains(mx, my) and pure_geometry.contains(.{ .x = g.end_slot.x, .y = g.end_slot.y, .w = g.end_slot.w, .h = g.end_slot.h }, mx, my);
}

pub fn drawTabs(self: *App) !void {
    const bar = try self.layout.rect(self.layout.tabs);
    const t = self.settings.theme;
    self.tab_hits.clearRetainingCapacity();
    try self.fill(bar, t.tab_bar);
    self.clip(bar);
    defer self.renderer.setClip(null);
    try self.renderer.rect(bar.x, bar.y + bar.h - 1, bar.w, 1, t.border);
    self.tabs_first = @min(self.tabs_first, self.workspace.active);
    // Ensure the active tab is visible, even when many documents are open.
    var needed: f32 = 0;
    for (self.workspace.documents.items[self.tabs_first .. self.workspace.active + 1]) |doc| needed += self.tabWidth(&doc);
    while (needed > bar.w and self.tabs_first < self.workspace.active) {
        needed -= self.tabWidth(&self.workspace.documents.items[self.tabs_first]);
        self.tabs_first += 1;
    }
    var x = bar.x;
    for (self.workspace.documents.items[self.tabs_first..], self.tabs_first..) |*doc, index| {
        if (x >= bar.x + bar.w) break;
        const w = @min(self.tabWidth(doc), @max(0, bar.x + bar.w - x));
        const r: Rect = .{ .x = x, .y = bar.y, .w = w, .h = bar.h };
        const g = geometry(r);
        const is_active = index == self.workspace.active and !self.keymap_editor_open;
        if (is_active) {
            try self.fill(r, t.active_tab);
            try self.renderer.rect(x, bar.y, w, 1, t.accent);
        }
        try self.renderer.rect(x + w - 1, bar.y, 1, bar.h, t.border);
        const name = if (doc.path) |path| std.fs.path.basename(path) else "untitled";
        self.clip(g.label_clip);
        try self.drawIcon(self.fileIcon(doc.path orelse ""), g.icon_x, g.icon_y, 16, t.muted);
        try self.renderer.textUi(name, g.label_x, g.label_baseline, if (is_active) t.text else t.muted);
        self.clip(bar);
        if (doc.dirty()) try self.renderer.icon(icons.svg("circle"), x + w - 22, bar.y + 12, 10, t.muted) else try self.renderer.icon(icons.svg("close"), g.close_icon_x, g.close_icon_y, 14, t.muted);
        try self.tab_hits.append(self.gpa, .{ .rect = r, .index = index });
        x += w;
    }
    // The keymap editor is a workspace item like in Zed; it has no document behind it.
    if (self.keymap_editor_open and x < bar.x + bar.w) {
        const label = "Keymap Editor";
        const w = @min(self.renderer.widthUi(label) + 72, bar.x + bar.w - x);
        try self.fill(.{ .x = x, .y = bar.y, .w = w, .h = bar.h }, t.active_tab);
        try self.renderer.rect(x, bar.y, w, 1, t.accent);
        try self.renderer.rect(x + w - 1, bar.y, 1, bar.h, t.border);
        try self.renderer.icon(icons.svg("ui:notepad"), x + 10, bar.y + 10, 16, t.muted);
        try self.renderer.textUi(label, x + 34, bar.y + 23, t.text);
        const g = geometry(.{ .x = x, .y = bar.y, .w = w, .h = bar.h });
        try self.renderer.icon(icons.svg("close"), g.close_icon_x, g.close_icon_y, 14, t.muted);
        self.keymap_tab = .{ .x = x, .y = bar.y, .w = w, .h = bar.h };
    }
}
pub fn tabWidth(self: *App, doc: *const zid.Document) f32 {
    return std.math.clamp(self.renderer.widthUi(if (doc.path) |p| std.fs.path.basename(p) else "untitled") + 72, 130, 250);
}
