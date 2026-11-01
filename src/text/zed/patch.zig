//! Port of Zed's `text::Edit` and `text::Patch` (`.ref/zed/crates/text/src/patch.rs`,
//! `text.rs` `Edit<D>`). A patch is a sorted list of disjoint edits; composing two
//! patches yields one patch with the combined effect.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

/// Arithmetic over a coordinate type: integers natively, or structs that declare
/// `Delta`, `cmp`, `sub(a, b) Delta`, `addDelta(a, d) T` and `Delta.cmp` when not integral.
pub fn Coordinate(comptime T: type) type {
    const is_int = @typeInfo(T) == .int;
    return struct {
        pub const Delta = if (is_int) T else T.Delta;

        pub inline fn order(a: T, b: T) Order {
            return if (is_int) std.math.order(a, b) else a.cmp(&b);
        }

        pub inline fn lt(a: T, b: T) bool {
            return order(a, b) == .lt;
        }

        pub inline fn sub(a: T, b: T) Delta {
            return if (is_int) a - b else a.sub(b);
        }

        pub inline fn add(a: T, delta: Delta) T {
            return if (is_int) a + delta else a.addDelta(delta);
        }

        pub inline fn minDelta(a: Delta, b: Delta) Delta {
            if (@typeInfo(Delta) == .int) return @min(a, b);
            return if (a.cmp(&b) == .gt) b else a;
        }

        pub inline fn minValue(a: T, b: T) T {
            return if (order(a, b) == .gt) b else a;
        }

        pub inline fn zero() T {
            return if (is_int) 0 else T.default_value;
        }
    };
}

pub fn Range(comptime T: type) type {
    return struct { start: T, end: T };
}

pub fn Edit(comptime T: type) type {
    return struct {
        const Self = @This();
        const C = Coordinate(T);

        old: Range(T),
        new: Range(T),

        pub fn isEmpty(self: Self) bool {
            return C.order(self.old.start, self.old.end) == .eq and C.order(self.new.start, self.new.end) == .eq;
        }

        pub fn oldLen(self: Self) C.Delta {
            return C.sub(self.old.end, self.old.start);
        }

        pub fn newLen(self: Self) C.Delta {
            return C.sub(self.new.end, self.new.start);
        }
    };
}

pub fn Patch(comptime T: type) type {
    return struct {
        const Self = @This();
        const C = Coordinate(T);
        pub const EditT = Edit(T);

        edits_list: std.ArrayList(EditT) = .empty,

        pub const empty: Self = .{};

        /// Takes ownership of `edits`, which must be sorted and disjoint.
        pub fn fromOwned(owned: std.ArrayList(EditT)) Self {
            if (std.debug.runtime_safety) {
                var last: ?EditT = null;
                for (owned.items) |e| {
                    if (last) |l| {
                        std.debug.assert(C.order(e.old.start, l.old.end) == .gt);
                        std.debug.assert(C.order(e.new.start, l.new.end) == .gt);
                    }
                    last = e;
                }
            }
            return .{ .edits_list = owned };
        }

        pub fn fromSlice(gpa: Allocator, source: []const EditT) Allocator.Error!Self {
            var list: std.ArrayList(EditT) = .empty;
            try list.appendSlice(gpa, source);
            return fromOwned(list);
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.edits_list.deinit(gpa);
        }

        pub fn clone(self: *const Self, gpa: Allocator) Allocator.Error!Self {
            return .{ .edits_list = try self.edits_list.clone(gpa) };
        }

        pub fn edits(self: *const Self) []const EditT {
            return self.edits_list.items;
        }

        pub fn invert(self: *Self) *Self {
            for (self.edits_list.items) |*e| std.mem.swap(Range(T), &e.old, &e.new);
            return self;
        }

        pub fn clear(self: *Self) void {
            self.edits_list.clearRetainingCapacity();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.edits_list.items.len == 0;
        }

        pub fn push(self: *Self, gpa: Allocator, e: EditT) Allocator.Error!void {
            if (e.isEmpty()) return;
            try self.pushMaybeEmpty(gpa, e);
        }

        pub fn pushMaybeEmpty(self: *Self, gpa: Allocator, e: EditT) Allocator.Error!void {
            if (self.edits_list.items.len > 0) {
                const last = &self.edits_list.items[self.edits_list.items.len - 1];
                if (C.order(last.old.end, e.old.start) != .lt) {
                    last.old.end = e.old.end;
                    last.new.end = e.new.end;
                    return;
                }
            }
            try self.edits_list.append(gpa, e);
        }

        /// Returns a patch equivalent to applying `self` and then `new_edits`.
        pub fn compose(self: *const Self, gpa: Allocator, new_edits: []const EditT) Allocator.Error!Self {
            var composed: Self = .empty;
            errdefer composed.deinit(gpa);
            const old_edits = self.edits_list.items;
            var old_ix: usize = 0;
            var new_ix: usize = 0;
            // Peeked edits are copied so their starts can be advanced (`peek_mut`).
            var old_peek: ?EditT = if (old_edits.len > 0) old_edits[0] else null;
            var new_peek: ?EditT = if (new_edits.len > 0) new_edits[0] else null;

            var old_start = C.zero();
            var new_start = C.zero();
            while (true) {
                // Push the old edit if its new end is before the new edit's old start.
                if (old_peek) |old_edit| {
                    if (new_peek == null or C.lt(old_edit.new.end, new_peek.?.old.start)) {
                        const catchup = C.sub(old_edit.old.start, old_start);
                        old_start = C.add(old_start, catchup);
                        new_start = C.add(new_start, catchup);
                        const old_end = C.add(old_start, old_edit.oldLen());
                        const new_end = C.add(new_start, old_edit.newLen());
                        try composed.push(gpa, .{ .old = .{ .start = old_start, .end = old_end }, .new = .{ .start = new_start, .end = new_end } });
                        old_start = old_end;
                        new_start = new_end;
                        old_ix += 1;
                        old_peek = if (old_ix < old_edits.len) old_edits[old_ix] else null;
                        continue;
                    }
                }

                // Push the new edit if its old end is before the old edit's new start.
                if (new_peek) |new_edit| {
                    if (old_peek == null or C.lt(new_edit.old.end, old_peek.?.new.start)) {
                        const catchup = C.sub(new_edit.new.start, new_start);
                        old_start = C.add(old_start, catchup);
                        new_start = C.add(new_start, catchup);
                        const old_end = C.add(old_start, new_edit.oldLen());
                        const new_end = C.add(new_start, new_edit.newLen());
                        try composed.push(gpa, .{ .old = .{ .start = old_start, .end = old_end }, .new = .{ .start = new_start, .end = new_end } });
                        old_start = old_end;
                        new_start = new_end;
                        new_ix += 1;
                        new_peek = if (new_ix < new_edits.len) new_edits[new_ix] else null;
                        continue;
                    }
                }

                // Remaining edits intersect, so compose them.
                if (old_peek == null or new_peek == null) break;
                const old_edit = &old_peek.?;
                const new_edit = &new_peek.?;
                if (C.lt(old_edit.new.start, new_edit.old.start)) {
                    const catchup = C.sub(old_edit.old.start, old_start);
                    old_start = C.add(old_start, catchup);
                    new_start = C.add(new_start, catchup);
                    const overshoot = C.sub(new_edit.old.start, old_edit.new.start);
                    const old_end = C.minValue(C.add(old_start, overshoot), old_edit.old.end);
                    const new_end = C.add(new_start, overshoot);
                    try composed.push(gpa, .{ .old = .{ .start = old_start, .end = old_end }, .new = .{ .start = new_start, .end = new_end } });
                    old_edit.old.start = old_end;
                    old_edit.new.start = C.add(old_edit.new.start, overshoot);
                    old_start = old_end;
                    new_start = new_end;
                } else {
                    const catchup = C.sub(new_edit.new.start, new_start);
                    old_start = C.add(old_start, catchup);
                    new_start = C.add(new_start, catchup);
                    const overshoot = C.sub(old_edit.new.start, new_edit.old.start);
                    const old_end = C.add(old_start, overshoot);
                    const new_end = C.minValue(C.add(new_start, overshoot), new_edit.new.end);
                    try composed.push(gpa, .{ .old = .{ .start = old_start, .end = old_end }, .new = .{ .start = new_start, .end = new_end } });
                    new_edit.old.start = C.add(new_edit.old.start, overshoot);
                    new_edit.new.start = new_end;
                    old_start = old_end;
                    new_start = new_end;
                }

                if (C.order(old_edit.new.end, new_edit.old.end) == .gt) {
                    const old_end = C.add(old_start, C.minDelta(old_edit.oldLen(), new_edit.oldLen()));
                    const new_end = C.add(new_start, new_edit.newLen());
                    try composed.push(gpa, .{ .old = .{ .start = old_start, .end = old_end }, .new = .{ .start = new_start, .end = new_end } });
                    old_edit.old.start = old_end;
                    old_edit.new.start = new_edit.old.end;
                    old_start = old_end;
                    new_start = new_end;
                    new_ix += 1;
                    new_peek = if (new_ix < new_edits.len) new_edits[new_ix] else null;
                } else {
                    const old_end = C.add(old_start, old_edit.oldLen());
                    const new_end = C.add(new_start, C.minDelta(old_edit.newLen(), new_edit.newLen()));
                    try composed.push(gpa, .{ .old = .{ .start = old_start, .end = old_end }, .new = .{ .start = new_start, .end = new_end } });
                    new_edit.old.start = old_edit.new.end;
                    new_edit.new.start = new_end;
                    old_start = old_end;
                    new_start = new_end;
                    old_ix += 1;
                    old_peek = if (old_ix < old_edits.len) old_edits[old_ix] else null;
                }
            }
            return composed;
        }

        /// Index of the last edit whose old start is <= `old`, as `binary_search_by` + `ix - 1`.
        fn searchOld(self: *const Self, old: T) ?usize {
            const items = self.edits_list.items;
            var low: usize = 0;
            var high: usize = items.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                switch (C.order(items[mid].old.start, old)) {
                    .eq => return mid,
                    .lt => low = mid + 1,
                    .gt => high = mid,
                }
            }
            return if (low == 0) null else low - 1;
        }

        pub fn oldToNew(self: *const Self, old: T) T {
            const ix = self.searchOld(old) orelse return old;
            const e = self.edits_list.items[ix];
            if (C.order(old, e.old.end) != .lt) return C.add(e.new.end, C.sub(old, e.old.end));
            return e.new.start;
        }

        /// The edit touching `old` (inclusive on the right), or an empty translated edit.
        pub fn editForOldPosition(self: *const Self, old: T) EditT {
            const ix = self.searchOld(old) orelse return .{ .old = .{ .start = old, .end = old }, .new = .{ .start = old, .end = old } };
            const e = self.edits_list.items[ix];
            if (C.order(old, e.old.end) == .gt) {
                const translated = C.add(e.new.end, C.sub(old, e.old.end));
                return .{ .old = .{ .start = old, .end = old }, .new = .{ .start = translated, .end = translated } };
            }
            return e;
        }
    };
}

const testing = std.testing;
const P = Patch(u32);
const E = P.EditT;

fn ed(os: u32, oe: u32, ns: u32, ne: u32) E {
    return .{ .old = .{ .start = os, .end = oe }, .new = .{ .start = ns, .end = ne } };
}

fn applyPatch(gpa: Allocator, text: *std.ArrayList(u8), patch: []const E, new_text: []const u8) !void {
    var i = patch.len;
    while (i > 0) {
        i -= 1;
        const edit = patch[i];
        try text.replaceRange(gpa, edit.old.start, edit.old.end - edit.old.start, new_text[edit.new.start..edit.new.end]);
    }
}

fn assertPatchComposition(old: []const E, new: []const E, composed: []const E) !void {
    const gpa = testing.allocator;
    const original = "abcdefghijklmnopqrstuvwxy";
    const inserted = "ABCDEFGHIJKLMNOPQRSTUVWXY";
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    try expected.appendSlice(gpa, original);
    try applyPatch(gpa, &expected, old, inserted);
    try applyPatch(gpa, &expected, new, inserted);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(gpa);
    try actual.appendSlice(gpa, original);
    try applyPatch(gpa, &actual, composed, expected.items);
    try testing.expectEqualStrings(expected.items, actual.items);

    var old_patch = try P.fromSlice(gpa, old);
    defer old_patch.deinit(gpa);
    var result = try old_patch.compose(gpa, new);
    defer result.deinit(gpa);
    try testing.expectEqualSlices(E, composed, result.edits());
}

test "one disjoint edit" {
    try assertPatchComposition(&.{ed(1, 3, 1, 4)}, &.{ed(0, 0, 0, 4)}, &.{ ed(0, 0, 0, 4), ed(1, 3, 5, 8) });
    try assertPatchComposition(&.{ed(1, 3, 1, 4)}, &.{ed(5, 9, 5, 7)}, &.{ ed(1, 3, 1, 4), ed(4, 8, 5, 7) });
}

test "one overlapping edit" {
    try assertPatchComposition(&.{ed(1, 3, 1, 4)}, &.{ed(3, 5, 3, 6)}, &.{ed(1, 4, 1, 6)});
}

test "two disjoint and overlapping" {
    try assertPatchComposition(&.{ ed(1, 3, 1, 4), ed(8, 12, 9, 11) }, &.{ ed(0, 0, 0, 4), ed(3, 10, 7, 9) }, &.{ ed(0, 0, 0, 4), ed(1, 12, 5, 10) });
}

test "two new edits overlapping one old edit" {
    try assertPatchComposition(&.{ed(0, 0, 0, 3)}, &.{ ed(0, 0, 0, 1), ed(1, 2, 2, 2) }, &.{ed(0, 0, 0, 3)});
    try assertPatchComposition(&.{ed(2, 3, 2, 4)}, &.{ ed(0, 2, 0, 1), ed(3, 3, 2, 5) }, &.{ed(0, 3, 0, 6)});
    try assertPatchComposition(&.{ed(0, 0, 0, 2)}, &.{ ed(0, 0, 0, 2), ed(2, 5, 4, 4) }, &.{ed(0, 3, 0, 4)});
}

test "two new edits touching one old edit" {
    try assertPatchComposition(&.{ ed(2, 3, 2, 4), ed(7, 7, 8, 11) }, &.{ ed(2, 3, 2, 2), ed(4, 4, 3, 4) }, &.{ ed(2, 3, 2, 4), ed(7, 7, 8, 11) });
}

test "old to new" {
    const gpa = testing.allocator;
    var patch = try P.fromSlice(gpa, &.{ ed(2, 4, 2, 4), ed(7, 8, 7, 11) });
    defer patch.deinit(gpa);
    const expected = [_]u32{ 0, 1, 2, 2, 4, 5, 6, 7, 11, 12 };
    for (expected, 0..) |want, old| try testing.expectEqual(want, patch.oldToNew(@intCast(old)));
}

test "random patch compositions" {
    const gpa = testing.allocator;
    const operations = 20;
    for (0..100) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var initial: std.ArrayList(u8) = .empty;
        defer initial.deinit(gpa);
        for (0..random.uintAtMost(usize, 100)) |_| try initial.append(gpa, 'a' + random.uintAtMost(u8, 25));

        var expected: std.ArrayList(u8) = try initial.clone(gpa);
        defer expected.deinit(gpa);
        var patches: [2]std.ArrayList(E) = .{ .empty, .empty };
        defer for (&patches) |*p| p.deinit(gpa);
        for (&patches) |*patch| {
            var delta: i64 = 0;
            var last_edit_end: usize = 0;
            for (0..operations) |_| {
                if (last_edit_end >= expected.items.len) break;
                const end = last_edit_end + random.uintAtMost(usize, expected.items.len - last_edit_end);
                const start = last_edit_end + random.uintAtMost(usize, end - last_edit_end);
                const old_len = end - start;
                var new_len = random.uintAtMost(usize, 3);
                if (start == end and new_len == 0) new_len += 1;
                last_edit_end = start + new_len + 1;
                var new_chars: [3]u8 = undefined;
                for (new_chars[0..new_len]) |*c| c.* = 'A' + random.uintAtMost(u8, 25);
                try patch.append(gpa, ed(
                    @intCast(@as(i64, @intCast(start)) - delta),
                    @intCast(@as(i64, @intCast(end)) - delta),
                    @intCast(start),
                    @intCast(start + new_len),
                ));
                try expected.replaceRange(gpa, start, end - start, new_chars[0..new_len]);
                delta += @as(i64, @intCast(new_len)) - @as(i64, @intCast(old_len));
            }
        }

        var first = try P.fromSlice(gpa, patches[0].items);
        defer first.deinit(gpa);
        var composed = try first.compose(gpa, patches[1].items);
        defer composed.deinit(gpa);

        var actual = try initial.clone(gpa);
        defer actual.deinit(gpa);
        for (composed.edits()) |edit| {
            try actual.replaceRange(gpa, edit.new.start, edit.old.end - edit.old.start, expected.items[edit.new.start..edit.new.end]);
        }
        try testing.expectEqualStrings(expected.items, actual.items);
    }
}
