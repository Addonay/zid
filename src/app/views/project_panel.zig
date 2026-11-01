//! Project tree geometry follows Zed's ListItem: 6px inner horizontal padding,
//! 20px configured indent steps, 16px file icons, and 14px disclosure icons.
//! The 24px row pitch is sized for the app's 14px UI label metrics.
const std = @import("std");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const icons = @import("icons");
const geometry = @import("geometry.zig");

pub const row_h: f32 = 24;
pub const top_pad: f32 = 4;
const pad_x: f32 = 6;
const indent: f32 = 20;
const icon_size: f32 = 16;
const gap: f32 = 4;
const guide_offset: f32 = 15;
const disclosure_size: f32 = 14;
const min_scroll_thumb: f32 = 25;

/// Rows that fit fully or partially in the panel body.
pub fn visibleRows(panel_h: f32) usize {
    return geometry.visibleRows(panel_h, top_pad, row_h);
}

/// Includes the final clipped row, so drawing and hit geometry agree at the viewport edge.
pub fn drawnRows(panel_h: f32) usize {
    return geometry.drawnRows(panel_h, top_pad, row_h);
}

pub fn rowY(panel_y: f32, slot: usize) f32 {
    return geometry.rowY(panel_y, top_pad, slot, row_h);
}

pub fn contentX(panel_x: f32, depth: usize) f32 {
    return geometry.contentX(panel_x, pad_x, depth, indent);
}

pub fn guideX(panel_x: f32, level: usize) f32 {
    return geometry.guideX(panel_x, guide_offset, level, indent);
}

pub fn totalRows(self: *App) usize {
    return if (self.project_collapsed) 1 else 1 + self.visible.items.len;
}

/// Row index under a panel-relative y coordinate, or null above the first row.
pub fn rowAt(self: *App, panel: Rect, my: f32) ?usize {
    if (my < panel.y + top_pad) return null;
    const row = self.panel_scroll + @as(usize, @intFromFloat((my - panel.y - top_pad) / row_h));
    return if (row < totalRows(self)) row else null;
}

pub fn drawPanel(self: *App) !void {
    if (!self.panel_open) return;
    const p = try self.layout.rect(self.layout.panel);
    const t = self.settings.theme;

    try self.fill(p, t.panel);
    try self.renderer.rect(p.x + p.w - 1, p.y, 1, p.h, t.border);
    const body: Rect = .{ .x = p.x, .y = p.y, .w = p.w - 1, .h = p.h };
    self.clip(body);
    defer self.renderer.setClip(null);

    const total = totalRows(self);
    const fit = visibleRows(p.h);
    const draw_count = drawnRows(p.h);
    const doc_path: []const u8 = self.workspace.current().path orelse "";
    const hovered_row: ?usize = if (body.contains(self.mouse_x, self.mouse_y)) rowAt(self, p, self.mouse_y) else null;

    var slot: usize = 0;
    while (slot < draw_count and self.panel_scroll + slot < total) : (slot += 1) {
        const row = self.panel_scroll + slot;
        const y = rowY(p.y, slot);

        var depth: usize = 0;
        var name: []const u8 = std.fs.path.basename(self.workspace.root);
        var icon = self.fileIcon("");
        icon = @import("../icon_theme.zig").folder(self.settings.icon_theme, std.fs.path.basename(self.workspace.root), !self.project_collapsed);
        var is_directory = true;
        var is_collapsed = self.project_collapsed;
        var active = false;
        if (row > 0) {
            const e = self.project.entries.items[self.visible.items[row - 1]];
            depth = e.depth + 1;
            name = e.name;
            active = !e.directory and isActivePath(doc_path, e.path);
            is_directory = e.directory;
            is_collapsed = e.collapsed;
            icon = if (e.directory) @import("../icon_theme.zig").folder(self.settings.icon_theme, std.fs.path.basename(e.path), !e.collapsed) else self.fileIcon(e.path);
        }

        const selected = self.panel_focus and self.panel_row == row;
        const row_rect: Rect = .{ .x = body.x, .y = y, .w = body.w, .h = row_h };
        if (active or selected) {
            try self.fill(row_rect, t.element_selected);
        } else if (hovered_row == row) {
            try self.fill(row_rect, t.element_hover);
        }
        if (selected) try outline(self, row_rect, t.border_focused);

        if (self.settings.show_indent_guides and depth > 0) {
            for (0..depth) |level| {
                const gx = guideX(p.x, level);
                try self.renderer.rect(gx, y, 1, row_h, t.indent_guide);
            }
        }

        const row_origin_x = p.x + @as(f32, @floatFromInt(depth)) * indent;
        if (is_directory) {
            // Zed positions the disclosure button one rem before the indented row;
            // its 24px square centers the 14px chevron four pixels before row_origin_x.
            const center_x = @max(p.x + disclosure_size / 2, row_origin_x - 4);
            const chevron = if (is_collapsed) "ui:chevron_right" else "ui:chevron_down";
            try self.renderer.icon(icons.svg(chevron), center_x - disclosure_size / 2, y + (row_h - disclosure_size) / 2, disclosure_size, t.muted);
        }
        const icon_x = contentX(p.x, depth);
        try self.drawIcon(icon, icon_x, y + (row_h - icon_size) / 2, icon_size, t.muted);
        try self.renderer.textUi(name, icon_x + icon_size + gap, y + 17, t.text);
    }

    try drawScrollbar(self, body, total, fit);
}

fn isActivePath(doc_path: []const u8, entry_path: []const u8) bool {
    if (std.mem.eql(u8, doc_path, entry_path)) return true;
    return doc_path.len > entry_path.len and std.mem.endsWith(u8, doc_path, entry_path) and doc_path[doc_path.len - entry_path.len - 1] == '/';
}

fn outline(self: *App, r: Rect, color: [4]u8) !void {
    try self.renderer.rect(r.x, r.y, r.w, 1, color);
    try self.renderer.rect(r.x, r.y + r.h - 1, r.w, 1, color);
    try self.renderer.rect(r.x, r.y, 1, r.h, color);
    try self.renderer.rect(r.x + r.w - 1, r.y, 1, r.h, color);
}

/// Overlay thumb shown only when the tree overflows, like Zed's `scrollbar.show: auto`.
fn drawScrollbar(self: *App, body: Rect, total: usize, fit: usize) !void {
    if (total <= fit or fit == 0) return;
    const track_h = body.h - top_pad * 2;
    const ratio = @as(f32, @floatFromInt(fit)) / @as(f32, @floatFromInt(total));
    const thumb_h = @min(track_h, @max(min_scroll_thumb, track_h * ratio));
    const max_scroll: f32 = @floatFromInt(total - fit);
    const pos = @min(1, @as(f32, @floatFromInt(self.panel_scroll)) / max_scroll);
    const thumb_y = body.y + top_pad + (track_h - thumb_h) * pos;
    try self.renderer.roundRect(body.x + body.w - 8, thumb_y, 6, thumb_h, 3, self.settings.theme.scrollbar_thumb);
}
