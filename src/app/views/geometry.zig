//! Pure geometry shared by the SDL view painters and their parent hit testing.
const std = @import("std");

pub const Box = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn visibleRows(panel_h: f32, top_pad: f32, row_h: f32) usize {
    return @intFromFloat(@max(0, panel_h - top_pad) / row_h);
}

pub fn drawnRows(panel_h: f32, top_pad: f32, row_h: f32) usize {
    return @intFromFloat(@ceil(@max(0, panel_h - top_pad) / row_h));
}

pub fn rowY(panel_y: f32, top_pad: f32, slot: usize, row_h: f32) f32 {
    return panel_y + top_pad + @as(f32, @floatFromInt(slot)) * row_h;
}

pub fn contentX(panel_x: f32, pad_x: f32, depth: usize, indent: f32) f32 {
    return panel_x + pad_x + @as(f32, @floatFromInt(depth)) * indent;
}

pub fn guideX(panel_x: f32, offset: f32, level: usize, indent: f32) f32 {
    return panel_x + offset + @as(f32, @floatFromInt(level)) * indent;
}

pub fn tabEndSlot(tab_x: f32, tab_w: f32, tab_y: f32, tab_h: f32) Box {
    return .{ .x = tab_x + @max(0, tab_w - 28), .y = tab_y, .w = @min(28, tab_w), .h = tab_h };
}

pub fn contains(b: Box, x: f32, y: f32) bool {
    return x >= b.x and y >= b.y and x < b.x + b.w and y < b.y + b.h;
}

test "tree geometry preserves full and clipped row counts and shared indent origin" {
    try std.testing.expectEqual(@as(usize, 2), visibleRows(60, 12, 24));
    try std.testing.expectEqual(@as(usize, 2), drawnRows(60, 12, 24));
    try std.testing.expectEqual(@as(usize, 2), visibleRows(60, 4, 24));
    try std.testing.expectEqual(@as(usize, 3), drawnRows(60, 4, 24));
    try std.testing.expectEqual(@as(f32, 56), rowY(4, 4, 2, 24));
    try std.testing.expectEqual(@as(f32, 46), contentX(0, 6, 2, 20));
    try std.testing.expectEqual(@as(f32, 35), guideX(0, 15, 1, 20));
}

test "tab end slot stays within short and normal tabs" {
    const normal = tabEndSlot(100, 130, 20, 35);
    try std.testing.expect(contains(normal, 205, 25));
    try std.testing.expect(!contains(normal, 199, 25));
    try std.testing.expect(!contains(normal, 230, 25));
    const short = tabEndSlot(100, 18, 20, 35);
    try std.testing.expectEqual(@as(f32, 100), short.x);
    try std.testing.expectEqual(@as(f32, 18), short.w);
}
