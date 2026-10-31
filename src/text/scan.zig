//! SIMD byte scanning used by line indexing and line lookup.
const std = @import("std");

const lanes = std.simd.suggestVectorLength(u8) orelse 16;
const V = @Vector(lanes, u8);

pub fn countNewlines(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    const nl: V = @splat('\n');
    // Accumulate in u8 lanes for up to 255 iterations before widening.
    while (i + lanes <= bytes.len) {
        var acc: @Vector(lanes, u8) = @splat(0);
        var rounds: usize = 0;
        while (rounds < 255 and i + lanes <= bytes.len) : ({
            rounds += 1;
            i += lanes;
        }) {
            const chunk: V = bytes[i..][0..lanes].*;
            acc +%= @select(u8, chunk == nl, @as(V, @splat(1)), @as(V, @splat(0)));
        }
        count += @reduce(.Add, @as(@Vector(lanes, u16), acc));
    }
    while (i < bytes.len) : (i += 1) count += @intFromBool(bytes[i] == '\n');
    return count;
}

/// Index of the n-th newline (0-based) in `bytes`, or null.
pub fn nthNewline(bytes: []const u8, n: usize) ?usize {
    var remaining = n;
    var i: usize = 0;
    const nl: V = @splat('\n');
    while (i + lanes <= bytes.len) : (i += lanes) {
        const chunk: V = bytes[i..][0..lanes].*;
        const hits: usize = @popCount(@as(@Int(.unsigned, lanes), @bitCast(chunk == nl)));
        if (hits > remaining) break;
        remaining -= hits;
    }
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') {
            if (remaining == 0) return i;
            remaining -= 1;
        }
    }
    return null;
}

pub fn lastNewline(bytes: []const u8) ?usize {
    return std.mem.lastIndexOfScalar(u8, bytes, '\n');
}

test "count and find newlines across vector boundaries" {
    var buf: [1000]u8 = undefined;
    @memset(&buf, 'a');
    var positions: [20]usize = undefined;
    var prng = std.Random.DefaultPrng.init(4);
    for (&positions, 0..) |*p, k| {
        p.* = k * 49 + prng.random().uintLessThan(usize, 40);
        buf[p.*] = '\n';
    }
    try std.testing.expectEqual(@as(usize, 20), countNewlines(&buf));
    for (positions, 0..) |p, k| try std.testing.expectEqual(@as(?usize, p), nthNewline(&buf, k));
    try std.testing.expectEqual(@as(?usize, null), nthNewline(&buf, 20));
    // Exceeding 255 rounds of u8 accumulation must not overflow.
    const big = try std.testing.allocator.alloc(u8, 200_000);
    defer std.testing.allocator.free(big);
    @memset(big, '\n');
    try std.testing.expectEqual(@as(usize, 200_000), countNewlines(big));
}
