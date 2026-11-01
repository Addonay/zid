//! Port of Zed's `text::Locator` (`.ref/zed/crates/text/src/locator.rs`).
//!
//! A locator orders fragments without renumbering: `between(lhs, rhs)` always yields a
//! key strictly between its arguments. Zed stores the parts in a `SmallVec<[u64; 2]>`.
//! Here the parts live in an arena owned by the buffer, so a `Locator` is a plain slice
//! that can be copied into SumTree summaries.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

pub const Locator = struct {
    parts: []const u64,

    const min_parts = [_]u64{std.math.minInt(u64)};
    const max_parts = [_]u64{std.math.maxInt(u64)};

    pub const min: Locator = .{ .parts = &min_parts };
    pub const max: Locator = .{ .parts = &max_parts };

    pub fn between(arena: Allocator, lhs: Locator, rhs: Locator) Allocator.Error!Locator {
        var location: std.ArrayList(u64) = .empty;
        defer location.deinit(arena);
        var ix: usize = 0;
        while (true) : (ix += 1) {
            const left = if (ix < lhs.parts.len) lhs.parts[ix] else std.math.minInt(u64);
            const right = if (ix < rhs.parts.len) rhs.parts[ix] else std.math.maxInt(u64);
            // This shift is essential! It optimizes for the common case of sequential typing.
            const mid = left + ((right -| left) >> 48);
            try location.append(arena, mid);
            if (mid > left) break;
        }
        return .{ .parts = try arena.dupe(u64, location.items) };
    }

    /// Lexicographic order, like Rust's derived `Ord` for `SmallVec`.
    pub fn cmp(a: *const Locator, b: *const Locator) Order {
        return std.mem.order(u64, a.parts, b.parts);
    }

    pub fn eql(a: Locator, b: Locator) bool {
        return std.mem.eql(u64, a.parts, b.parts);
    }

    pub fn len(self: Locator) usize {
        return self.parts.len;
    }

    // SumTree summary: `add_summary` assigns, so a summary holds the last (maximum) id.
    pub fn zero(_: void) Locator {
        return min;
    }

    pub fn addSummary(self: *Locator, other: *const Locator, _: void) void {
        self.* = other.*;
    }
};

const testing = std.testing;

test "locators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (0..100) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var lhs: Locator = .min;
        var rhs: Locator = .min;
        while (lhs.eql(rhs)) {
            const lp = try arena.alloc(u64, 1 + random.uintLessThan(usize, 5));
            for (lp) |*p| p.* = random.uintAtMost(u64, 100);
            const rp = try arena.alloc(u64, 1 + random.uintLessThan(usize, 5));
            for (rp) |*p| p.* = random.uintAtMost(u64, 100);
            lhs = .{ .parts = lp };
            rhs = .{ .parts = rp };
        }
        if (lhs.cmp(&rhs) == .gt) std.mem.swap(Locator, &lhs, &rhs);
        const middle = try Locator.between(arena, lhs, rhs);
        try testing.expect(middle.cmp(&lhs) == .gt);
        try testing.expect(middle.cmp(&rhs) == .lt);
        for (middle.parts[0 .. middle.parts.len - 1], 0..) |part, ix| {
            const left = if (ix < lhs.parts.len) lhs.parts[ix] else 0;
            const right = if (ix < rhs.parts.len) rhs.parts[ix] else 0;
            try testing.expect(part == left or part == right);
        }
    }
}

test "sequential typing stays shallow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var last = try Locator.between(arena, .min, .max);
    for (0..10_000) |_| {
        const next = try Locator.between(arena, last, .max);
        try testing.expect(next.cmp(&last) == .gt);
        last = next;
    }
    try testing.expectEqual(@as(usize, 1), last.len());
}
