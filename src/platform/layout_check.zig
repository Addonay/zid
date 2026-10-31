//! Compile and execute the real dependency without committing to a UI design.
const std = @import("std");
const zafi = @import("zafi");
pub fn check(allocator: std.mem.Allocator) !void {
    var tree = zafi.Tree.init(allocator);
    defer tree.deinit();
    const fixed = try tree.new_leaf(.{ .size = .{ .width = .length(120), .height = .length(40) }, .flex_shrink = 0 });
    const flexible = try tree.new_leaf(.{ .flex_grow = 1 });
    const root = try tree.new_with_children(.{ .size = .{ .width = .length(640), .height = .length(480) } }, &.{ fixed, flexible });
    try tree.compute_layout(root, .{ .width = .{ .definite = 640 }, .height = .{ .definite = 480 } });
    const a = try tree.layout_of(fixed);
    const b = try tree.layout_of(flexible);
    if (@abs(a.size.width - 120) > 0.01 or @abs(b.location.x - 120) > 0.01 or @abs(b.size.width - 520) > 0.01) return error.LayoutIntegrationFailed;
    try tree.set_style(root, .{ .size = .{ .width = .length(800), .height = .length(600) } });
    try tree.compute_layout(root, .{ .width = .{ .definite = 800 }, .height = .{ .definite = 600 } });
    if (@abs((try tree.layout_of(flexible)).size.width - 680) > 0.01) return error.LayoutInvalidationFailed;
}
test "Zafi flex sizing and invalidation" {
    try check(std.testing.allocator);
}
