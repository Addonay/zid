//! Shell geometry comes from Zafi; text layout stays in the editor grid.
const std = @import("std");
const zafi = @import("zafi");
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
};
pub const Layout = struct {
    tree: zafi.Tree,
    root: zafi.NodeId,
    title: zafi.NodeId,
    body: zafi.NodeId,
    panel: zafi.NodeId,
    pane: zafi.NodeId,
    tabs: zafi.NodeId,
    editor: zafi.NodeId,
    status: zafi.NodeId,
    width: f32 = 0,
    height: f32 = 0,
    panel_width: f32 = -1,
    pub fn init(gpa: std.mem.Allocator) !Layout {
        var tree = zafi.Tree.init(gpa);
        errdefer tree.deinit();
        const title = try tree.new_leaf(.{ .size = .{ .width = .auto, .height = .length(34) }, .flex_shrink = 0 });
        const panel = try tree.new_leaf(.{ .size = .{ .width = .length(240), .height = .auto }, .flex_shrink = 0 });
        const tabs = try tree.new_leaf(.{ .size = .{ .width = .auto, .height = .length(32) }, .flex_shrink = 0 });
        const editor = try tree.new_leaf(.{ .flex_grow = 1, .min_size = .{ .height = .length(0), .width = .length(0) } });
        const pane = try tree.new_with_children(.{ .flex_direction = .column, .flex_grow = 1, .min_size = .{ .width = .length(0), .height = .length(0) } }, &.{ tabs, editor });
        const body = try tree.new_with_children(.{ .flex_grow = 1, .min_size = .{ .width = .length(0), .height = .length(0) } }, &.{ panel, pane });
        const status = try tree.new_leaf(.{ .size = .{ .width = .auto, .height = .length(26) }, .flex_shrink = 0 });
        const root = try tree.new_with_children(.{ .flex_direction = .column }, &.{ title, body, status });
        return .{ .tree = tree, .root = root, .title = title, .body = body, .panel = panel, .pane = pane, .tabs = tabs, .editor = editor, .status = status };
    }
    pub fn deinit(self: *Layout) void {
        self.tree.deinit();
    }
    pub fn resize(self: *Layout, w: f32, h: f32, panel: f32) !void {
        if (w == self.width and h == self.height and panel == self.panel_width) return;
        try self.tree.set_style(self.root, .{ .flex_direction = .column, .size = .{ .width = .length(w), .height = .length(h) } });
        try self.tree.set_style(self.panel, .{ .size = .{ .width = .length(panel), .height = .auto }, .flex_shrink = 0 });
        try self.tree.compute_layout(self.root, .{ .width = .{ .definite = w }, .height = .{ .definite = h } });
        self.width = w;
        self.height = h;
        self.panel_width = panel;
    }
    pub fn rect(self: *Layout, id: zafi.NodeId) !Rect {
        const l = try self.tree.layout_of(id);
        var result: Rect = .{ .x = l.location.x, .y = l.location.y, .w = l.size.width, .h = l.size.height };
        if (id == self.panel or id == self.pane) {
            const p = try self.tree.layout_of(self.body);
            result.x += p.location.x;
            result.y += p.location.y;
        }
        if (id == self.tabs or id == self.editor) {
            const p = try self.rect(self.pane);
            result.x += p.x;
            result.y += p.y;
        }
        return result;
    }
};
test "shell resizes and hides project panel without overlapping status" {
    var l = try Layout.init(std.testing.allocator);
    defer l.deinit();
    try l.resize(1000, 700, 240);
    const editor = try l.rect(l.editor);
    try std.testing.expectEqual(@as(f32, 240), editor.x);
    try std.testing.expectEqual(@as(f32, 66), editor.y);
    try std.testing.expectEqual(@as(f32, 608), editor.h);
    try l.resize(640, 480, 0);
    const small = try l.rect(l.editor);
    try std.testing.expectEqual(@as(f32, 0), small.x);
    try std.testing.expectEqual(@as(f32, 640), small.w);
}
