//! Fuzzy matching for pickers (file finder, command palette, recent projects, keymap search).
//!
//! Case-insensitive subsequence matching scored by dynamic programming, in the spirit of
//! fzf and Zed's `fuzzy` crate: matches at word starts, after path separators and in the
//! basename score higher; consecutive runs earn a bonus and gaps a penalty. Positions of
//! the best alignment are returned so views can highlight them.
const std = @import("std");

pub const max_needle = 32;
pub const max_haystack = 512;

pub const Match = struct {
    score: i32,
    positions: [max_needle]u16 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Match) []const u16 {
        return self.positions[0..self.len];
    }
    pub fn contains(self: *const Match, index: usize) bool {
        for (self.slice()) |p| if (p == index) return true;
        return false;
    }
};

const score_match = 16;
const bonus_boundary = 8;
const bonus_separator = 10;
const bonus_consecutive = 6;
const bonus_basename = 3;
const bonus_first = 4;
const gap_open = 3;
const gap_extend = 1;
const neg_inf: i32 = std.math.minInt(i32) / 4;

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn boundaryBonus(hay: []const u8, j: usize) i32 {
    if (j == 0) return bonus_separator;
    const prev = hay[j - 1];
    const cur = hay[j];
    if (prev == '/' or prev == '\\') return bonus_separator;
    if (prev == '_' or prev == '-' or prev == '.' or prev == ' ' or prev == ':') return bonus_boundary;
    if (std.ascii.isLower(prev) and std.ascii.isUpper(cur)) return bonus_boundary;
    if (!std.ascii.isDigit(prev) and std.ascii.isDigit(cur)) return @divTrunc(bonus_boundary, 2);
    return 0;
}

/// Scores `needle` against `haystack`; null when it is not a subsequence.
/// Whitespace in the needle is ignored, so "set fon" matches "Settings: Font".
pub fn match(needle_raw: []const u8, haystack: []const u8) ?Match {
    var needle_buf: [max_needle]u8 = undefined;
    var n: usize = 0;
    for (needle_raw) |c| {
        if (c == ' ') continue;
        if (n == max_needle) break;
        needle_buf[n] = lower(c);
        n += 1;
    }
    const needle = needle_buf[0..n];
    if (n == 0) return .{ .score = 0 };
    const hay = haystack[0..@min(haystack.len, max_haystack)];
    const m = hay.len;
    if (n > m) return null;

    // Fast reject: subsequence check.
    {
        var i: usize = 0;
        for (hay) |c| {
            if (lower(c) == needle[i]) {
                i += 1;
                if (i == n) break;
            }
        }
        if (i < n) return null;
    }

    const basename_start = (std.mem.lastIndexOfScalar(u8, hay, '/') orelse std.math.maxInt(usize)) +% 1;

    // score[i][j]: best score with needle[i] matched exactly at hay[j]; from[i][j]: previous j.
    var score: [max_needle][max_haystack]i32 = undefined;
    var from: [max_needle][max_haystack]u16 = undefined;
    for (0..n) |i| {
        // Running best over earlier columns of row i-1, decayed by gap penalties.
        var best_prev: i32 = neg_inf;
        var best_prev_at: u16 = 0;
        for (0..m) |j| {
            score[i][j] = neg_inf;
            if (i > 0 and j > 0) {
                // Extend the gap for the column we are moving past.
                if (best_prev != neg_inf) best_prev -= gap_extend;
                const candidate = score[i - 1][j - 1];
                if (candidate != neg_inf and candidate - gap_open > best_prev) {
                    best_prev = candidate - gap_open;
                    best_prev_at = @intCast(j - 1);
                }
            }
            if (lower(hay[j]) != needle[i]) continue;
            var s: i32 = score_match + boundaryBonus(hay, j);
            if (j >= basename_start) s += bonus_basename;
            if (i == 0) {
                if (j == 0) s += bonus_first;
                score[i][j] = s - @as(i32, @intCast(@min(j, 32) / 4));
                from[i][j] = 0;
                continue;
            }
            const consecutive = if (j > 0 and score[i - 1][j - 1] != neg_inf) score[i - 1][j - 1] + bonus_consecutive else neg_inf;
            if (consecutive >= best_prev and consecutive != neg_inf) {
                score[i][j] = consecutive + s;
                from[i][j] = @intCast(j - 1);
            } else if (best_prev != neg_inf) {
                score[i][j] = best_prev + s;
                from[i][j] = best_prev_at;
            }
        }
    }
    var best: i32 = neg_inf;
    var best_j: usize = 0;
    for (0..m) |j| if (score[n - 1][j] > best) {
        best = score[n - 1][j];
        best_j = j;
    };
    if (best == neg_inf) return null;
    var out: Match = .{ .score = best - @as(i32, @intCast(m / 16)), .len = @intCast(n) };
    var j = best_j;
    var i = n;
    while (i > 0) {
        i -= 1;
        out.positions[i] = @intCast(j);
        j = from[i][j];
    }
    return out;
}

const testing = std.testing;

test "fuzzy matching prefers boundaries, basenames and consecutive runs" {
    try testing.expect(match("xyz", "abc") == null);
    const a = match("doc", "src/editor/document.zig").?;
    const b = match("doc", "docs/ARCHITECTURE.md").?;
    try testing.expect(a.score > 0 and b.score > 0);
    const basename = match("main", "src/main.zig").?;
    const scattered = match("main", "src/app/input/manifest.zig") orelse Match{ .score = std.math.minInt(i32) };
    try testing.expect(basename.score > scattered.score);
    const m = match("tb", "src/editor/text_buffer.zig").?;
    try testing.expectEqualSlices(u16, &.{ 11, 16 }, m.slice());
    const palette = match("save as", "workspace: save as").?;
    try testing.expect(palette.score > 0);
    try testing.expectEqual(@as(i32, 0), match("", "anything").?.score);
}
