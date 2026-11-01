//! Port of Zed's `text::Selection` and `SelectionGoal` (`.ref/zed/crates/text/src/selection.rs`).
const std = @import("std");
const patch = @import("patch.zig");

pub const SelectionGoal = union(enum) {
    none,
    horizontal_position: f64,
    horizontal_range: struct { start: f64, end: f64 },
    wrapped_horizontal_position: struct { row: u32, x: f32 },
};

pub fn Selection(comptime T: type) type {
    return struct {
        const Self = @This();
        const C = patch.Coordinate(T);

        id: usize,
        start: T,
        end: T,
        reversed: bool,
        goal: SelectionGoal = .none,

        /// Where the selection stopped.
        pub fn head(self: Self) T {
            return if (self.reversed) self.start else self.end;
        }

        /// Where the selection was initiated.
        pub fn tail(self: Self) T {
            return if (self.reversed) self.end else self.start;
        }

        pub fn map(self: Self, comptime S: type, context: anytype, comptime f: fn (@TypeOf(context), T) S) Selection(S) {
            return .{ .id = self.id, .start = f(context, self.start), .end = f(context, self.end), .reversed = self.reversed, .goal = self.goal };
        }

        pub fn collapseTo(self: *Self, point: T, new_goal: SelectionGoal) void {
            self.start = point;
            self.end = point;
            self.goal = new_goal;
            self.reversed = false;
        }

        pub fn isEmpty(self: Self) bool {
            return C.order(self.start, self.end) == .eq;
        }

        pub fn setHead(self: *Self, new_head: T, new_goal: SelectionGoal) void {
            if (C.order(new_head, self.tail()) == .lt) {
                if (!self.reversed) {
                    self.end = self.start;
                    self.reversed = true;
                }
                self.start = new_head;
            } else {
                if (self.reversed) {
                    self.start = self.end;
                    self.reversed = false;
                }
                self.end = new_head;
            }
            self.goal = new_goal;
        }

        pub fn setTail(self: *Self, new_tail: T, new_goal: SelectionGoal) void {
            if (C.order(new_tail, self.head()) != .gt) {
                if (self.reversed) {
                    self.end = self.start;
                    self.reversed = false;
                }
                self.start = new_tail;
            } else {
                if (!self.reversed) {
                    self.start = self.end;
                    self.reversed = true;
                }
                self.end = new_tail;
            }
            self.goal = new_goal;
        }

        pub fn setHeadTail(self: *Self, new_head: T, new_tail: T, new_goal: SelectionGoal) void {
            if (C.order(new_head, new_tail) == .lt) {
                self.reversed = true;
                self.start = new_head;
                self.end = new_tail;
            } else {
                self.reversed = false;
                self.start = new_tail;
                self.end = new_head;
            }
            self.goal = new_goal;
        }

        /// Matches Zed: a reversed selection only clears `reversed`; otherwise the
        /// endpoints are swapped.
        pub fn swapHeadTail(self: *Self) void {
            if (self.reversed) {
                self.reversed = false;
            } else {
                std.mem.swap(T, &self.start, &self.end);
            }
        }

        pub fn range(self: Self) patch.Range(T) {
            return .{ .start = self.start, .end = self.end };
        }

        pub fn len(self: Self) C.Delta {
            return C.sub(self.end, self.start);
        }

        pub fn fromOffset(offset: T) Self {
            return .{ .id = 0, .start = offset, .end = offset, .reversed = false };
        }
    };
}

const testing = std.testing;

test "selection head tail" {
    var selection = Selection(usize).fromOffset(5);
    selection.setHead(9, .none);
    try testing.expectEqual(@as(usize, 5), selection.tail());
    try testing.expectEqual(@as(usize, 9), selection.head());
    selection.setHead(2, .none);
    try testing.expect(selection.reversed);
    try testing.expectEqual(@as(usize, 2), selection.start);
    try testing.expectEqual(@as(usize, 5), selection.end);
    selection.setTail(1, .none);
    try testing.expectEqual(@as(usize, 1), selection.tail());
    try testing.expectEqual(@as(usize, 2), selection.head());
    try testing.expectEqual(@as(usize, 1), selection.len());
    selection.setHeadTail(3, 8, .{ .horizontal_position = 12.5 });
    try testing.expect(selection.reversed);
    try testing.expectEqual(@as(usize, 3), selection.head());
}
