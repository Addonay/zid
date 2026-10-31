//! One responsibility per view/controller; application owns retained state.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const syntax = zid.syntax;
const icons = @import("icons");
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
        const w = @min(self.tabWidth(doc), bar.w);
        const r: Rect = .{ .x = x, .y = bar.y, .w = w, .h = bar.h };
        if (index == self.workspace.active) {
            try self.fill(r, t.active_tab);
            try self.renderer.rect(x, bar.y, w, 1, t.accent);
        }
        try self.renderer.rect(x + w - 1, bar.y, 1, bar.h, t.border);
        const name = if (doc.path) |path| std.fs.path.basename(path) else "untitled";
        self.clip(.{ .x = x + 8, .y = bar.y, .w = @max(0, w - 36), .h = bar.h });
        try self.renderer.icon(icons.fileForPath(doc.path orelse ""), x + 10, bar.y + 10, 16, t.muted);
        try self.renderer.textUi(name, x + 34, bar.y + 23, if (index == self.workspace.active) t.text else t.muted);
        self.clip(bar);
        if (doc.dirty()) try self.renderer.icon(icons.svg("circle"), x + w - 22, bar.y + 12, 10, t.muted) else try self.renderer.icon(icons.svg("close"), x + w - 24, bar.y + 10, 14, t.muted);
        try self.tab_hits.append(self.gpa, .{ .rect = r, .index = index });
        x += w;
    }
}
pub fn tabWidth(self: *App, doc: *const zid.Document) f32 {
    return std.math.clamp(self.renderer.widthUi(if (doc.path) |p| std.fs.path.basename(p) else "untitled") + 72, 130, 250);
}
