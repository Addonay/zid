//! Ports of the tests in `.ref/zed/crates/sum_tree/src/sum_tree.rs`.
const std = @import("std");
const st = @import("sum_tree.zig");
const testing = std.testing;
const Bias = st.Bias;

const IntegersSummary = struct {
    count: usize = 0,
    sum: usize = 0,
    contains_even: bool = false,
    max: u8 = 0,

    pub fn zero(_: void) IntegersSummary {
        return .{};
    }

    pub fn addSummary(self: *IntegersSummary, other: *const IntegersSummary, _: void) void {
        self.count += other.count;
        self.sum += other.sum;
        self.contains_even = self.contains_even or other.contains_even;
        self.max = @max(self.max, other.max);
    }

    /// `impl Dimension<IntegersSummary> for u8` sets the dimension to `summary.max`.
    pub fn dimensionZero(comptime D: type, _: void) D {
        return 0;
    }

    pub fn addToDimension(comptime D: type, dimension: *D, summary: *const IntegersSummary, _: void) void {
        dimension.* = summary.max;
    }
};

const Int = struct {
    value: u8,

    pub const Summary = IntegersSummary;
    pub const Key = u8;

    pub fn summary(self: *const Int, _: void) IntegersSummary {
        return .{ .count = 1, .sum = self.value, .contains_even = self.value & 1 == 0, .max = self.value };
    }

    pub fn key(self: *const Int) u8 {
        return self.value;
    }
};

const Count = struct {
    value: usize = 0,

    pub fn zero(_: anytype) Count {
        return .{};
    }

    pub fn addSummary(self: *Count, summary: anytype, _: anytype) void {
        self.value += summary.count;
    }

    pub fn cmp(a: *const Count, b: *const Count) std.math.Order {
        return std.math.order(a.value, b.value);
    }

    /// `impl SeekTarget<IntegersSummary, IntegersSummary> for Count`.
    pub fn cmpSeek(self: *const Count, location: anytype, _: anytype) std.math.Order {
        const L = @TypeOf(location.*);
        if (L == Count) return std.math.order(self.value, location.value);
        if (L == IntegersSummary) return std.math.order(self.value, location.count);
        return self.cmpSeek(&location.d1, {});
    }
};

const Sum = struct {
    value: usize = 0,

    pub fn zero(_: anytype) Sum {
        return .{};
    }

    pub fn addSummary(self: *Sum, summary: anytype, _: anytype) void {
        self.value += summary.sum;
    }
};

const Tree = st.SumTree(Int);
const gpa = testing.allocator;

fn ints(comptime values: []const u8) [values.len]Int {
    var result: [values.len]Int = undefined;
    for (values, 0..) |v, i| result[i] = .{ .value = v };
    return result;
}

fn expectItems(tree: Tree, expected: []const u8) !void {
    var list = try tree.items(gpa);
    defer list.deinit(gpa);
    try testing.expectEqual(expected.len, list.items.len);
    for (expected, list.items) |e, actual| try testing.expectEqual(e, actual.value);
}

fn expectItem(actual: ?*const Int, expected: ?u8) !void {
    if (expected) |e| {
        try testing.expect(actual != null);
        try testing.expectEqual(e, actual.?.value);
    } else try testing.expect(actual == null);
}

test "extend and push tree" {
    var tree1 = try Tree.init(gpa, {});
    defer tree1.deinit(gpa);
    var first: [20]Int = undefined;
    for (&first, 0..) |*item, i| item.* = .{ .value = @intCast(i) };
    try tree1.extend(gpa, &first, {});

    var tree2 = try Tree.init(gpa, {});
    var second: [50]Int = undefined;
    for (&second, 50..) |*item, i| item.* = .{ .value = @intCast(i) };
    try tree2.extend(gpa, &second, {});

    try tree1.append(gpa, tree2, {});
    var expected: [70]u8 = undefined;
    for (0..20) |i| expected[i] = @intCast(i);
    for (50..100, 20..) |v, i| expected[i] = @intCast(v);
    try expectItems(tree1, &expected);
}

test "from iter" {
    var items: [100]Int = undefined;
    var expected: [100]u8 = undefined;
    for (&items, &expected, 0..) |*item, *e, i| {
        item.* = .{ .value = @intCast(i) };
        e.* = @intCast(i);
    }
    const tree = try Tree.fromItems(gpa, &items, {});
    defer tree.deinit(gpa);
    try expectItems(tree, &expected);
}

fn sliceItems(c: anytype, target: anytype, bias: Bias) !std.ArrayList(Int) {
    const slice = try c.slice(gpa, target, bias);
    defer slice.deinit(gpa);
    return slice.items(gpa);
}

fn expectSlice(c: anytype, target: anytype, bias: Bias, expected: []const u8) !void {
    var list = try sliceItems(c, target, bias);
    defer list.deinit(gpa);
    try testing.expectEqual(expected.len, list.items.len);
    for (expected, list.items) |e, actual| try testing.expectEqual(e, actual.value);
}

fn expectCursorState(c: anytype, item: ?u8, prev: ?u8, next: ?u8, sum: usize) !void {
    try expectItem(c.item(), item);
    try expectItem(c.prevItem(), prev);
    try expectItem(c.nextItem(), next);
    try testing.expectEqual(sum, c.start().sum);
}

test "cursor" {
    // Empty tree
    {
        var tree = try Tree.init(gpa, {});
        defer tree.deinit(gpa);
        var c = tree.cursor(IntegersSummary, {});
        try expectSlice(&c, Count{ .value = 0 }, .right, &.{});
        try expectCursorState(&c, null, null, null, 0);
        c.prev();
        try expectCursorState(&c, null, null, null, 0);
        c.next();
        try expectCursorState(&c, null, null, null, 0);
    }

    // Single-element tree
    {
        var tree = try Tree.init(gpa, {});
        defer tree.deinit(gpa);
        try tree.extend(gpa, &ints(&.{1}), {});
        var c = tree.cursor(IntegersSummary, {});
        try expectSlice(&c, Count{ .value = 0 }, .right, &.{});
        try expectCursorState(&c, 1, null, null, 0);
        c.next();
        try expectCursorState(&c, null, 1, null, 1);
        c.prev();
        try expectCursorState(&c, 1, null, null, 0);

        var c2 = tree.cursor(IntegersSummary, {});
        try expectSlice(&c2, Count{ .value = 1 }, .right, &.{1});
        try expectCursorState(&c2, null, 1, null, 1);

        _ = c2.seek(Count{ .value = 0 }, .right);
        try expectSlice(&c2, tree.extent(Count, {}), .right, &.{1});
        try expectCursorState(&c2, null, 1, null, 1);
    }

    // Multiple-element tree
    var tree = try Tree.init(gpa, {});
    defer tree.deinit(gpa);
    try tree.extend(gpa, &ints(&.{ 1, 2, 3, 4, 5, 6 }), {});
    var c = tree.cursor(IntegersSummary, {});

    try expectSlice(&c, Count{ .value = 2 }, .right, &.{ 1, 2 });
    try expectCursorState(&c, 3, 2, 4, 3);
    c.next();
    try expectCursorState(&c, 4, 3, 5, 6);
    c.next();
    try expectCursorState(&c, 5, 4, 6, 10);
    c.next();
    try expectCursorState(&c, 6, 5, null, 15);
    c.next();
    c.next();
    try expectCursorState(&c, null, 6, null, 21);
    c.prev();
    try expectCursorState(&c, 6, 5, null, 15);
    c.prev();
    try expectCursorState(&c, 5, 4, 6, 10);
    c.prev();
    try expectCursorState(&c, 4, 3, 5, 6);
    c.prev();
    try expectCursorState(&c, 3, 2, 4, 3);
    c.prev();
    try expectCursorState(&c, 2, 1, 3, 1);
    c.prev();
    try expectCursorState(&c, 1, null, 2, 0);
    c.prev();
    try expectCursorState(&c, null, null, 1, 0);
    c.next();
    try expectCursorState(&c, 1, null, 2, 0);

    var c2 = tree.cursor(IntegersSummary, {});
    try expectSlice(&c2, tree.extent(Count, {}), .right, &.{ 1, 2, 3, 4, 5, 6 });
    try expectCursorState(&c2, null, 6, null, 21);

    _ = c2.seek(Count{ .value = 3 }, .right);
    try expectSlice(&c2, tree.extent(Count, {}), .right, &.{ 4, 5, 6 });
    try expectCursorState(&c2, null, 6, null, 21);

    // Seeking can bias left or right
    _ = c2.seek(Count{ .value = 1 }, .left);
    try expectItem(c2.item(), 1);
    _ = c2.seek(Count{ .value = 1 }, .right);
    try expectItem(c2.item(), 2);

    // Slicing without resetting starts from where the cursor is parked at.
    _ = c2.seek(Count{ .value = 1 }, .right);
    try expectSlice(&c2, Count{ .value = 3 }, .right, &.{ 2, 3 });
    try expectSlice(&c2, Count{ .value = 6 }, .left, &.{ 4, 5 });
    try expectSlice(&c2, Count{ .value = 6 }, .right, &.{6});
}

test "edit" {
    var tree = try Tree.init(gpa, {});
    defer tree.deinit(gpa);

    var edits1 = [_]Tree.KeyedEdit{ .{ .insert = .{ .value = 1 } }, .{ .insert = .{ .value = 2 } }, .{ .insert = .{ .value = 0 } } };
    var removed1 = try tree.edit(gpa, &edits1, {});
    defer removed1.deinit(gpa);
    try expectItems(tree, &.{ 0, 1, 2 });
    try testing.expectEqual(@as(usize, 0), removed1.items.len);
    try expectItem(tree.get(0, {}), 0);
    try expectItem(tree.get(1, {}), 1);
    try expectItem(tree.get(2, {}), 2);
    try expectItem(tree.get(4, {}), null);

    var edits2 = [_]Tree.KeyedEdit{ .{ .insert = .{ .value = 2 } }, .{ .insert = .{ .value = 4 } }, .{ .remove = 0 } };
    var removed2 = try tree.edit(gpa, &edits2, {});
    defer removed2.deinit(gpa);
    try expectItems(tree, &.{ 1, 2, 4 });
    try testing.expectEqual(@as(usize, 2), removed2.items.len);
    try testing.expectEqual(@as(u8, 0), removed2.items[0].value);
    try testing.expectEqual(@as(u8, 2), removed2.items[1].value);
    try expectItem(tree.get(0, {}), null);
    try expectItem(tree.get(1, {}), 1);
    try expectItem(tree.get(2, {}), 2);
    try expectItem(tree.get(4, {}), 4);
}

test "insert or replace and remove" {
    var tree = try Tree.init(gpa, {});
    defer tree.deinit(gpa);
    for ([_]u8{ 5, 1, 3, 9, 7 }) |v| try testing.expect(try tree.insertOrReplace(gpa, .{ .value = v }, {}) == null);
    try expectItems(tree, &.{ 1, 3, 5, 7, 9 });
    try testing.expectEqual(@as(u8, 3), (try tree.insertOrReplace(gpa, .{ .value = 3 }, {})).?.value);
    try testing.expectEqual(@as(u8, 7), (try tree.remove(gpa, 7, {})).?.value);
    try testing.expect(try tree.remove(gpa, 8, {}) == null);
    try expectItems(tree, &.{ 1, 3, 5, 9 });
}

test "clone shares structure and edits path-copy" {
    var tree = try Tree.init(gpa, {});
    defer tree.deinit(gpa);
    var values: [40]Int = undefined;
    for (&values, 0..) |*item, i| item.* = .{ .value = @intCast(i) };
    try tree.extend(gpa, &values, {});
    const snapshot = tree.clone();
    defer snapshot.deinit(gpa);
    try tree.push(gpa, .{ .value = 200 }, {});
    try testing.expectEqual(@as(usize, 40), snapshot.summary().count);
    try testing.expectEqual(@as(usize, 41), tree.summary().count);
}

fn randomInts(gpa_: std.mem.Allocator, random: std.Random, count: usize) ![]Int {
    const result = try gpa_.alloc(Int, count);
    for (result) |*item| item.* = .{ .value = random.int(u8) };
    return result;
}

fn containsEven(summary: *const IntegersSummary) bool {
    return summary.contains_even;
}

test "random" {
    const iterations = 100;
    const operations = 5;
    for (0..iterations) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        var tree = try Tree.init(gpa, {});
        defer tree.deinit(gpa);
        {
            const initial = try randomInts(gpa, random, random.uintLessThan(usize, 10));
            defer gpa.free(initial);
            try tree.extend(gpa, initial, {});
        }

        for (0..operations) |_| {
            const splice_end = random.uintAtMost(usize, tree.extent(Count, {}).value);
            const splice_start = random.uintAtMost(usize, splice_end);
            const new_items = try randomInts(gpa, random, random.uintLessThan(usize, 10));
            defer gpa.free(new_items);
            const tree_end = tree.extent(Count, {});

            var reference = try tree.items(gpa);
            defer reference.deinit(gpa);
            try reference.replaceRange(gpa, splice_start, splice_end - splice_start, new_items);

            {
                var c = tree.cursor(Count, {});
                var new_tree = try c.slice(gpa, Count{ .value = splice_start }, .right);
                errdefer new_tree.deinit(gpa);
                try new_tree.extend(gpa, new_items, {});
                _ = c.seek(Count{ .value = splice_end }, .right);
                try new_tree.append(gpa, try c.slice(gpa, tree_end, .right), {});
                tree.deinit(gpa);
                tree = new_tree;
            }

            var actual = try tree.items(gpa);
            defer actual.deinit(gpa);
            try testing.expectEqualSlices(Int, reference.items, actual.items);

            // `tree.iter()` and the cursor iterator agree.
            {
                var it = tree.iter();
                var c = tree.cursor(void, {});
                while (it.next()) |item| try testing.expectEqual(item.value, c.nextIter().?.value);
                try testing.expect(c.nextIter() == null);
            }

            // Filter cursor over even items.
            {
                var expected_filtered: std.ArrayList(struct { index: usize, value: u8 }) = .empty;
                defer expected_filtered.deinit(gpa);
                for (actual.items, 0..) |item, i| {
                    if (item.value & 1 == 0) try expected_filtered.append(gpa, .{ .index = i, .value = item.value });
                }
                var fc = tree.filter(Count, {}, &containsEven);
                var item_ix: usize = undefined;
                if (random.boolean()) {
                    fc.next();
                    item_ix = 0;
                } else {
                    fc.prev();
                    item_ix = expected_filtered.items.len -| 1;
                }
                while (item_ix < expected_filtered.items.len) {
                    const reference_item = expected_filtered.items[item_ix];
                    try testing.expectEqual(reference_item.value, fc.item().?.value);
                    try testing.expectEqual(reference_item.index, fc.start().value);
                    fc.next();
                    item_ix += 1;
                    while (item_ix > 0 and random.float(f64) < 0.2) {
                        fc.prev();
                        item_ix -= 1;
                        if (item_ix == 0 and random.float(f64) < 0.2) {
                            fc.prev();
                            try testing.expect(fc.item() == null);
                            try testing.expectEqual(@as(usize, 0), fc.start().value);
                            fc.next();
                        }
                    }
                }
                try testing.expect(fc.item() == null);
            }

            // Cursor navigation against the reference.
            {
                const items = reference.items;
                var before_start = false;
                var c = tree.cursor(Count, {});
                const start_pos = random.uintAtMost(usize, items.len);
                _ = c.seek(Count{ .value = start_pos }, .right);
                var pos = start_pos + random.uintAtMost(usize, items.len - start_pos);
                _ = c.seekForward(Count{ .value = pos }, .right);
                for (0..10) |i| {
                    try testing.expectEqual(pos, c.start().value);
                    try expectItem(c.prevItem(), if (pos > 0) items[pos - 1].value else null);
                    try expectItem(c.item(), if (pos < items.len and !before_start) items[pos].value else null);
                    if (before_start) {
                        try expectItem(c.nextItem(), if (items.len > 0) items[0].value else null);
                    } else {
                        try expectItem(c.nextItem(), if (pos + 1 < items.len) items[pos + 1].value else null);
                    }
                    if (i < 5) {
                        c.next();
                        if (pos < items.len) {
                            pos += 1;
                            before_start = false;
                        }
                    } else {
                        c.prev();
                        if (pos == 0) before_start = true;
                        pos -|= 1;
                    }
                }
            }
        }

        for (0..10) |_| {
            const end = random.uintAtMost(usize, tree.extent(Count, {}).value);
            const start = random.uintAtMost(usize, end);
            const start_bias: Bias = if (random.boolean()) .left else .right;
            const end_bias: Bias = if (random.boolean()) .left else .right;

            var c = tree.cursor(Count, {});
            _ = c.seek(Count{ .value = start }, start_bias);
            const slice = try c.slice(gpa, Count{ .value = end }, end_bias);
            defer slice.deinit(gpa);
            _ = c.seek(Count{ .value = start }, start_bias);
            const total = c.summary(Sum, Count{ .value = end }, end_bias);
            try testing.expectEqual(slice.summary().sum, total.value);
        }
    }
}

test "find variants agree with cursor" {
    var tree = try Tree.init(gpa, {});
    defer tree.deinit(gpa);
    var values: [30]Int = undefined;
    for (&values, 0..) |*item, i| item.* = .{ .value = @intCast(i * 2) };
    try tree.extend(gpa, &values, {});
    for (0..31) |n| {
        for ([_]Bias{ .left, .right }) |bias| {
            var c = tree.cursor(Count, {});
            _ = c.seek(Count{ .value = n }, bias);
            const found = tree.find(Count, {}, Count{ .value = n }, bias);
            try testing.expectEqual(c.start().value, found.start.value);
            try testing.expectEqual(c.item(), found.item);
            const with_prev = tree.findWithPrev(Count, {}, Count{ .value = n }, bias);
            if (with_prev.found) |f| {
                try testing.expectEqual(c.item().?, f.item);
                try testing.expectEqual(c.prevItem(), f.prev);
            } else try testing.expect(c.item() == null);
        }
    }
}

test "allocation failures leave no leaks or crashes" {
    try testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var tree = try Tree.init(allocator, {});
            defer tree.deinit(allocator);
            var values: [24]Int = undefined;
            for (&values, 0..) |*item, i| item.* = .{ .value = @intCast(i) };
            try tree.extend(allocator, &values, {});
            const snapshot = tree.clone();
            defer snapshot.deinit(allocator);
            var c = snapshot.cursor(Count, {});
            const prefix = try c.slice(allocator, Count{ .value = 10 }, .right);
            defer prefix.deinit(allocator);
            try tree.push(allocator, .{ .value = 99 }, {});
        }
    }.run, .{});
}
