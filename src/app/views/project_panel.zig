//! One responsibility per view/controller; application owns retained state.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const syntax = zid.syntax;
const icons = @import("icons");
pub fn drawPanel(self: *App) !void {
    if (!self.panel_open) return;
    const p = try self.layout.rect(self.layout.panel);
    const t = self.settings.theme;
    try self.fill(p, t.panel);
    self.clip(p);
    defer self.renderer.setClip(null);
    try self.renderer.rect(p.x + p.w - 1, p.y, 1, p.h, t.border);
    try self.renderer.textUi(std.fs.path.basename(self.workspace.root), 14, p.y + 24, t.text);
    const rows: usize = @intFromFloat(@max(0, p.h - 35) / 25);
    const doc_path: []const u8 = self.workspace.current().path orelse "";
    var r: usize = 0;
    while (r <= rows and self.panel_scroll + r < self.visible.items.len) : (r += 1) {
        const index = self.panel_scroll + r;
        const e = self.project.entries.items[self.visible.items[index]];
        const y = p.y + 35 + @as(f32, @floatFromInt(r)) * 25;
        const active = !e.directory and std.mem.endsWith(u8, doc_path, e.path) and doc_path.len > e.path.len and doc_path[doc_path.len - e.path.len - 1] == '/';
        if (active or (self.panel_focus and self.panel_row == index)) try self.renderer.rect(4, y, p.w - 9, 25, t.selected);
        const x = 12 + @as(f32, @floatFromInt(e.depth)) * 16;
        if (e.directory) {
            try self.renderer.icon(icons.svg(if (e.collapsed) "chevron_right" else "chevron_down"), x, y + 5, 14, t.muted);
        } else try self.renderer.icon(icons.fileForPath(e.path), x, y + 4, 16, t.muted);
        try self.renderer.textUi(std.fs.path.basename(e.path), x + 18, y + 18, if (active) t.text else t.muted);
    }
}
