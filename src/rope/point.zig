//! Ports of Zed's `rope::{Point, PointUtf16, OffsetUtf16, Unclipped}`
//! (`.ref/zed/crates/rope/src/{point,point_utf16,offset_utf16,unclipped}.rs`).
//!
//! Each type is also a SumTree dimension over `ChunkSummary`/`TextSummary` and a
//! `text.Patch` coordinate (`Delta`, `sub`, `addDelta`, `default_value`).
const std = @import("std");
const Order = std.math.Order;

fn PointType(comptime Self: type, comptime field: enum { lines, lines_utf16 }) type {
    return struct {
        pub const max: Self = .{ .row = std.math.maxInt(u32), .column = std.math.maxInt(u32) };
        pub const default_value: Self = .{ .row = 0, .column = 0 };
        pub const Delta = Self;

        pub fn new(row: u32, column: u32) Self {
            return .{ .row = row, .column = column };
        }

        pub fn isZero(self: Self) bool {
            return self.row == 0 and self.column == 0;
        }

        pub fn cmp(a: *const Self, b: *const Self) Order {
            return switch (std.math.order(a.row, b.row)) {
                .eq => std.math.order(a.column, b.column),
                else => |order| order,
            };
        }

        pub fn lt(a: Self, b: Self) bool {
            return a.cmp(&b) == .lt;
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.row == b.row and a.column == b.column;
        }

        /// `Add`: a delta with rows replaces the column; otherwise columns add.
        pub fn add(self: Self, other: Self) Self {
            if (other.row == 0) return .{ .row = self.row, .column = self.column + other.column };
            return .{ .row = self.row + other.row, .column = other.column };
        }

        pub fn addDelta(self: Self, other: Self) Self {
            return self.add(other);
        }

        pub fn sub(self: Self, other: Self) Self {
            std.debug.assert(other.cmp(&self) != .gt);
            if (self.row == other.row) return .{ .row = 0, .column = self.column - other.column };
            return .{ .row = self.row - other.row, .column = self.column };
        }

        pub fn saturatingSub(self: Self, other: Self) Self {
            return if (self.cmp(&other) == .lt) default_value else self.sub(other);
        }

        // SumTree dimension over ChunkSummary or TextSummary.
        pub fn zero(_: anytype) Self {
            return default_value;
        }

        pub fn addSummary(self: *Self, summary: anytype, _: anytype) void {
            const text = textOf(summary);
            self.* = self.add(switch (field) {
                .lines => text.lines,
                .lines_utf16 => text.linesUtf16(),
            });
        }
    };
}

/// Returns the `TextSummary` for a `ChunkSummary` or a `TextSummary`.
pub inline fn textOf(summary: anytype) TextSummary {
    if (comptime @hasField(@TypeOf(summary.*), "text")) return summary.text;
    return summary.*;
}

const TextSummary = @import("rope.zig").TextSummary;

pub const Point = struct {
    row: u32 = 0,
    column: u32 = 0,

    const Impl = PointType(Point, .lines);
    pub const max = Impl.max;
    pub const default_value = Impl.default_value;
    pub const Delta = Impl.Delta;
    pub const new = Impl.new;
    pub const isZero = Impl.isZero;
    pub const cmp = Impl.cmp;
    pub const lt = Impl.lt;
    pub const eql = Impl.eql;
    pub const add = Impl.add;
    pub const addDelta = Impl.addDelta;
    pub const sub = Impl.sub;
    pub const saturatingSub = Impl.saturatingSub;
    pub const zero = Impl.zero;
    pub const addSummary = Impl.addSummary;

    pub fn rowRange(start_row: u32, end_row: u32) struct { start: Point, end: Point } {
        return .{ .start = .{ .row = start_row }, .end = .{ .row = end_row } };
    }

    /// The point at the end of `text`.
    pub fn parseStr(text: []const u8) Point {
        var point: Point = .{};
        var it = std.mem.splitScalar(u8, text, '\n');
        var row: u32 = 0;
        while (it.next()) |line| : (row += 1) {
            point = .{ .row = row, .column = @intCast(line.len) };
        }
        return point;
    }
};

pub const PointUtf16 = struct {
    row: u32 = 0,
    column: u32 = 0,

    const Impl = PointType(PointUtf16, .lines_utf16);
    pub const max = Impl.max;
    pub const default_value = Impl.default_value;
    pub const Delta = Impl.Delta;
    pub const new = Impl.new;
    pub const isZero = Impl.isZero;
    pub const cmp = Impl.cmp;
    pub const lt = Impl.lt;
    pub const eql = Impl.eql;
    pub const add = Impl.add;
    pub const addDelta = Impl.addDelta;
    pub const sub = Impl.sub;
    pub const saturatingSub = Impl.saturatingSub;
    pub const zero = Impl.zero;
    pub const addSummary = Impl.addSummary;
};

pub const OffsetUtf16 = struct {
    value: usize = 0,

    pub const default_value: OffsetUtf16 = .{};
    pub const Delta = OffsetUtf16;

    pub fn new(value: usize) OffsetUtf16 {
        return .{ .value = value };
    }

    pub fn cmp(a: *const OffsetUtf16, b: *const OffsetUtf16) Order {
        return std.math.order(a.value, b.value);
    }

    pub fn add(a: OffsetUtf16, b: OffsetUtf16) OffsetUtf16 {
        return .{ .value = a.value + b.value };
    }

    pub fn addDelta(a: OffsetUtf16, b: OffsetUtf16) OffsetUtf16 {
        return a.add(b);
    }

    pub fn sub(a: OffsetUtf16, b: OffsetUtf16) OffsetUtf16 {
        return .{ .value = a.value - b.value };
    }

    pub fn zero(_: anytype) OffsetUtf16 {
        return .{};
    }

    pub fn addSummary(self: *OffsetUtf16, summary: anytype, _: anytype) void {
        self.value += textOf(summary).len_utf16.value;
    }
};

/// A position that may lie outside the valid range and must be clipped before use.
pub fn Unclipped(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,

        pub fn init(value: T) Self {
            return .{ .value = value };
        }

        pub fn cmp(a: *const Self, b: *const Self) Order {
            return a.value.cmp(&b.value);
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .value = a.value.add(b.value) };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .value = a.value.sub(b.value) };
        }

        pub fn zero(cx: anytype) Self {
            return .{ .value = T.zero(cx) };
        }

        pub fn addSummary(self: *Self, summary: anytype, cx: anytype) void {
            self.value.addSummary(summary, cx);
        }
    };
}

const testing = std.testing;

test "point arithmetic and ordering" {
    const a = Point.new(1, 4);
    const b = Point.new(3, 2);
    try testing.expect(a.lt(b));
    try testing.expect(Point.new(1, 7).eql(a.add(Point.new(0, 3))));
    try testing.expect(Point.new(3, 2).eql(a.add(Point.new(2, 2))));
    try testing.expect(Point.new(2, 2).eql(b.sub(a)));
    try testing.expect(Point.new(0, 3).eql(Point.new(1, 7).sub(a)));
    try testing.expect(Point.default_value.eql(a.saturatingSub(b)));
    try testing.expect(Point.new(2, 3).eql(Point.parseStr("ab\ncd\nefg")));
}
