//! Project tree geometry follows Zed's ListItem: 6px inner horizontal padding,
//! 20px configured indent steps, 16px file icons, and 14px disclosure icons.
//! The 24px row pitch is sized for the app's 14px UI label metrics.
const std = @import("std");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const icons = @import("icons");
const geometry = @import("geometry.zig");

pub const row_h: f32 = 24;
pub fn rowHeight(self: *const App) f32 {
    return if (self.settings.panel_standard_spacing) 20 else 24;
}
pub fn visibleRowsFor(self: *const App, panel_h: f32) usize {
    return geometry.visibleRows(panel_h, top_pad, rowHeight(self));
}
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
    return (if (self.project_collapsed) @as(usize, 1) else 1 + self.visible.items.len) + @as(usize, if (self.project_edit != null and self.project_edit.?.renaming == null) 1 else 0);
}

/// Row index under a panel-relative y coordinate, or null above the first row.
pub fn rowAt(self: *App, panel: Rect, my: f32) ?usize {
    if (my < panel.y + top_pad) return null;
    const row = self.panel_scroll + @as(usize, @intFromFloat((my - panel.y - top_pad) / rowHeight(self)));
    return if (row < totalRows(self)) row else null;
}

pub fn drawPanel(self: *App) !void {
    if (!self.panel_open) return;
    const p = try self.layout.rect(self.layout.panel);
    const t = self.settings.theme;
    const pitch = rowHeight(self);

    try self.fill(p, t.panel);
    try self.renderer.rect(if (self.settings.panel_right) p.x else p.x + p.w - 1, p.y, 1, p.h, t.border);
    const body: Rect = .{ .x = p.x, .y = p.y, .w = p.w - 1, .h = p.h };
    self.clip(body);
    defer self.renderer.setClip(null);

    const total = totalRows(self);
    const fit = visibleRowsFor(self, p.h);
    const draw_count = geometry.drawnRows(p.h, top_pad, pitch);
    const doc_path: []const u8 = if (self.workspace.currentOrNull()) |doc| doc.path orelse "" else "";
    const hovered_row: ?usize = if (body.contains(self.mouse_x, self.mouse_y)) rowAt(self, p, self.mouse_y) else null;

    var slot: usize = 0;
    while (slot < draw_count and self.panel_scroll + slot < total) : (slot += 1) {
        const row = self.panel_scroll + slot;
        const y = geometry.rowY(p.y, top_pad, slot, pitch);

        if (self.project_edit) |*edit| if (row == edit.row) {
            const x = p.x + pad_x + @as(f32, @floatFromInt(edit.depth * self.settings.panel_indent));
            const field: Rect = .{ .x = x, .y = y + 1, .w = @max(0, p.x + p.w - x - 6), .h = pitch - 2 };
            try self.fill(field, t.editor);
            try outline(self, field, t.accent);
            const input = &edit.input;
            const selected = input.selection();
            const text_x = field.x + 4;
            if (selected.start != selected.end) try self.renderer.rect(text_x + self.renderer.widthUi(input.text()[0..selected.start]), y + 2, self.renderer.widthUi(input.text()[selected.start..selected.end]), pitch - 4, t.element_selected);
            try self.renderer.textUi(input.text(), text_x, y + pitch / 2 + 5, t.text);
            try self.renderer.rect(text_x + self.renderer.widthUi(input.text()[0..input.cursor]), y + 3, 1, pitch - 6, t.text);
            continue;
        };
        const entry_row = if (self.project_edit) |edit| row - @as(usize, if (row > edit.row and edit.renaming == null) 1 else 0) else row;
        var depth: usize = 0;
        var name: []const u8 = std.fs.path.basename(self.workspace.root);
        var icon = self.fileIcon("");
        icon = @import("../icon_theme.zig").folder(self.settings.icon_theme, std.fs.path.basename(self.workspace.root), !self.project_collapsed);
        var is_directory = true;
        var is_collapsed = self.project_collapsed;
        var active = false;
        if (entry_row > 0) {
            const e = self.project.entries.items[self.visible.items[entry_row - 1]];
            depth = e.depth + 1;
            name = e.name;
            active = !e.directory and isActivePath(doc_path, e.path);
            is_directory = e.directory;
            is_collapsed = e.collapsed;
            icon = if (e.directory) @import("../icon_theme.zig").folder(self.settings.icon_theme, std.fs.path.basename(e.path), !e.collapsed) else self.fileIcon(e.path);
        }

        const selected = self.panel_focus and self.panel_row == row;
        const row_rect: Rect = .{ .x = body.x, .y = y, .w = body.w, .h = pitch };
        if (active or selected) {
            try self.fill(row_rect, t.element_selected);
        } else if (hovered_row == row) {
            try self.fill(row_rect, t.element_hover);
        }

        if (self.settings.show_indent_guides and depth > 0) {
            for (0..depth) |level| {
                const gx = geometry.guideX(p.x, guide_offset, level, @floatFromInt(self.settings.panel_indent));
                try self.renderer.rect(gx, y, 1, pitch, t.indent_guide);
            }
        }

        const row_origin_x = p.x + @as(f32, @floatFromInt(depth * self.settings.panel_indent));
        if (is_directory and self.settings.panel_folder_indicator != .icon) {
            // Zed positions the disclosure button one rem before the indented row;
            // its 24px square centers the 14px chevron four pixels before row_origin_x.
            const center_x = @max(p.x + disclosure_size / 2, row_origin_x - 4);
            const chevron = if (is_collapsed) "icons/file_icons/chevron_right.svg" else "icons/file_icons/chevron_down.svg";
            try self.renderer.icon(icons.svg(chevron), center_x - disclosure_size / 2, y + (pitch - disclosure_size) / 2, disclosure_size, t.muted);
        }
        const icon_x = geometry.contentX(p.x, pad_x, depth, @floatFromInt(self.settings.panel_indent));
        const show_icon = if (is_directory) self.settings.panel_folder_indicator != .chevron else self.settings.panel_file_icons;
        if (show_icon) try self.drawIcon(icon, icon_x, y + (pitch - icon_size) / 2, icon_size, t.muted);
        try self.renderer.textUi(name, icon_x + (if (show_icon) icon_size + gap else @as(f32, 0)), y + pitch / 2 + 5, t.text);
    }

    if (self.settings.panel_scrollbar) try drawScrollbar(self, body, total, fit);
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
