//! Literal byte search over a piece-backed TextBuffer.
//!
//! SearchPlan preprocesses a nonempty, valid UTF-8 pattern once, then scans the
//! requested range with KMP and a fixed 4 KiB text window. Offsets are bytes.
//! Optional case-insensitivity folds ASCII A-Z only; every non-ASCII byte is
//! compared exactly. Matches are returned only when both ends are UTF-8
//! boundaries, so search never reports a match in the middle of a codepoint.
const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;

const window_size = 4096;

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn valid(self: Range, len: usize) bool {
        return self.start <= self.end and self.end <= len;
    }
};

pub const Enumeration = struct {
    written: usize,
    /// Pass this back as `cursor` to continue. Null means exhausted.
    cursor: ?usize,
};

pub const SearchPlan = struct {
    allocator: std.mem.Allocator,
    pattern: []u8,
    failure: []usize,
    ascii_case_insensitive: bool,

    /// Rejects empty and malformed UTF-8 patterns. Pattern ownership belongs to
    /// the plan and is released by deinit.
    pub fn init(allocator: std.mem.Allocator, pattern: []const u8, ascii_case_insensitive: bool) !SearchPlan {
        if (pattern.len == 0) return error.EmptyPattern;
        if (!std.unicode.utf8ValidateSlice(pattern)) return error.InvalidUtf8;
        const owned_pattern = try allocator.dupe(u8, pattern);
        errdefer allocator.free(owned_pattern);
        const failure = try allocator.alloc(usize, pattern.len);
        errdefer allocator.free(failure);
        failure[0] = 0;
        var matched: usize = 0;
        for (1..pattern.len) |i| {
            while (matched > 0 and fold(pattern[i], ascii_case_insensitive) != fold(pattern[matched], ascii_case_insensitive)) {
                matched = failure[matched - 1];
            }
            if (fold(pattern[i], ascii_case_insensitive) == fold(pattern[matched], ascii_case_insensitive)) matched += 1;
            failure[i] = matched;
        }
        return .{ .allocator = allocator, .pattern = owned_pattern, .failure = failure, .ascii_case_insensitive = ascii_case_insensitive };
    }

    pub fn deinit(self: *SearchPlan) void {
        self.allocator.free(self.failure);
        self.allocator.free(self.pattern);
        self.* = undefined;
    }

    /// Finds the first match whose start is >= `from`, constrained to range.
    /// Invalid ranges or cursors return null. `from == range.end` is valid.
    pub fn next(self: *const SearchPlan, buffer: *const TextBuffer, range: Range, from: usize) ?usize {
        if (!range.valid(buffer.len()) or from < range.start or from > range.end) return null;
        if (self.pattern.len > range.end - from) return null;
        var scanner = Scanner{ .plan = self, .buffer = buffer, .start = from, .end = range.end, .offset = from };
        while (scanner.advance()) |found| {
            if (isBoundary(buffer, found) and isBoundary(buffer, found + self.pattern.len)) return found;
        }
        return null;
    }

    /// Finds the last match whose start is < `before`, constrained to range.
    /// Overlapping matches are considered. Invalid bounds return null.
    pub fn previous(self: *const SearchPlan, buffer: *const TextBuffer, range: Range, before: usize) ?usize {
        if (!range.valid(buffer.len()) or before < range.start or before > range.end) return null;
        const limit = @min(before, range.end);
        if (self.pattern.len > range.end - range.start) return null;
        var scanner = Scanner{ .plan = self, .buffer = buffer, .start = range.start, .end = range.end, .offset = range.start };
        var result: ?usize = null;
        while (scanner.advance()) |found| {
            if (found >= limit) break;
            if (isBoundary(buffer, found) and isBoundary(buffer, found + self.pattern.len)) result = found;
        }
        return result;
    }

    /// Fills caller storage with consecutive matches at or after cursor.
    /// A zero-length output slice writes nothing and returns the same cursor
    /// (unless already exhausted), allowing callers to control work in batches.
    pub fn enumerate(self: *const SearchPlan, buffer: *const TextBuffer, range: Range, cursor: ?usize, out: []usize) Enumeration {
        const at = cursor orelse return .{ .written = 0, .cursor = null };
        if (!range.valid(buffer.len()) or at < range.start or at > range.end) return .{ .written = 0, .cursor = null };
        if (out.len == 0) return .{ .written = 0, .cursor = at };
        var written: usize = 0;
        var search_at = at;
        while (written < out.len) {
            const found = self.next(buffer, range, search_at) orelse return .{ .written = written, .cursor = null };
            out[written] = found;
            written += 1;
            search_at = found + 1; // retain overlaps
        }
        // Do not scan ahead just to determine whether the batch exhausted.
        return .{ .written = written, .cursor = search_at };
    }

    const Scanner = struct {
        plan: *const SearchPlan,
        buffer: *const TextBuffer,
        start: usize,
        end: usize,
        window: [window_size]u8 = undefined,
        window_start: usize = 0,
        window_len: usize = 0,
        offset: usize = 0,
        matched: usize = 0,

        fn advance(self: *Scanner) ?usize {
            while (self.offset < self.end) {
                if (self.offset < self.window_start or self.offset >= self.window_start + self.window_len) {
                    self.window_start = self.offset;
                    self.window_len = @min(window_size, self.end - self.offset);
                    self.buffer.copy(self.window_start, self.window[0..self.window_len]);
                }
                const byte = self.window[self.offset - self.window_start];
                self.offset += 1;
                while (self.matched > 0 and fold(byte, self.plan.ascii_case_insensitive) != fold(self.plan.pattern[self.matched], self.plan.ascii_case_insensitive)) {
                    self.matched = self.plan.failure[self.matched - 1];
                }
                if (fold(byte, self.plan.ascii_case_insensitive) == fold(self.plan.pattern[self.matched], self.plan.ascii_case_insensitive)) self.matched += 1;
                if (self.matched == self.plan.pattern.len) {
                    const found = self.offset - self.plan.pattern.len;
                    self.matched = self.plan.failure[self.matched - 1];
                    return found;
                }
            }
            return null;
        }
    };
};

fn fold(byte: u8, enabled: bool) u8 {
    return if (enabled and byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn isBoundary(buffer: *const TextBuffer, offset: usize) bool {
    return offset == 0 or offset == buffer.len() or buffer.byteAt(offset) & 0xc0 != 0x80;
}

const testing = std.testing;

test "literal search handles overlaps ranges UTF-8 and ASCII case" {
    var buffer = try TextBuffer.init(testing.allocator, "ababa éÉ ABC");
    defer buffer.deinit();
    var plan = try SearchPlan.init(testing.allocator, "aba", false);
    defer plan.deinit();
    const whole = Range{ .start = 0, .end = buffer.len() };
    try testing.expectEqual(@as(?usize, 0), plan.next(&buffer, whole, 0));
    try testing.expectEqual(@as(?usize, 2), plan.next(&buffer, whole, 1));
    try testing.expectEqual(@as(?usize, 2), plan.previous(&buffer, whole, whole.end));
    try testing.expectEqual(@as(?usize, null), plan.next(&buffer, .{ .start = 1, .end = 4 }, 1));

    var folded = try SearchPlan.init(testing.allocator, "abc", true);
    defer folded.deinit();
    try testing.expectEqual(@as(?usize, 11), folded.next(&buffer, whole, 0));
    var non_ascii = try SearchPlan.init(testing.allocator, "é", true);
    defer non_ascii.deinit();
    try testing.expectEqual(@as(?usize, 6), non_ascii.next(&buffer, whole, 0));
    try testing.expectEqual(@as(?usize, null), non_ascii.next(&buffer, whole, 7));
}

test "empty pattern rejected and enumeration resumes with overlaps" {
    try testing.expectError(error.EmptyPattern, SearchPlan.init(testing.allocator, "", false));
    var buffer = try TextBuffer.init(testing.allocator, "aaaaa");
    defer buffer.deinit();
    var plan = try SearchPlan.init(testing.allocator, "aa", false);
    defer plan.deinit();
    var out: [2]usize = undefined;
    const a = plan.enumerate(&buffer, .{ .start = 0, .end = 5 }, 0, &out);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, out[0..2]);
    const b = plan.enumerate(&buffer, .{ .start = 0, .end = 5 }, a.cursor, &out);
    try testing.expectEqualSlices(usize, &.{ 2, 3 }, out[0..2]);
    try testing.expectEqual(@as(usize, 2), b.written);
    const c = plan.enumerate(&buffer, .{ .start = 0, .end = 5 }, b.cursor, &out);
    try testing.expectEqual(@as(usize, 0), c.written);
    try testing.expect(c.cursor == null);
}

test "search crosses fixed windows and piece boundaries" {
    const text = try testing.allocator.alloc(u8, 10000);
    defer testing.allocator.free(text);
    @memset(text, 'x');
    @memcpy(text[4094..4100], "needle");
    var buffer = try TextBuffer.init(testing.allocator, text);
    defer buffer.deinit();
    var plan = try SearchPlan.init(testing.allocator, "needle", false);
    defer plan.deinit();
    try testing.expectEqual(@as(?usize, 4094), plan.next(&buffer, .{ .start = 0, .end = text.len }, 0));
}

test "random edited buffers agree with flat reference" {
    var buffer = try TextBuffer.init(testing.allocator, "ababaxyz");
    defer buffer.deinit();
    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(testing.allocator);
    try reference.appendSlice(testing.allocator, "ababaxyz");
    var random = std.Random.DefaultPrng.init(19073);
    for (0..180) |_| {
        const start = random.random().uintAtMost(usize, reference.items.len);
        const end = start + random.random().uintAtMost(usize, @min(4, reference.items.len - start));
        const insertions = [_][]const u8{ "", "a", "b", "xyz", "aba" };
        const insert = insertions[random.random().uintLessThan(usize, insertions.len)];
        try buffer.replace(start, end, insert);
        try reference.replaceRange(testing.allocator, start, end - start, insert);
        const patterns = [_][]const u8{ "a", "ab", "aba", "xyz", "ba" };
        for (patterns) |needle| {
            var plan = try SearchPlan.init(testing.allocator, needle, false);
            defer plan.deinit();
            const range = Range{ .start = 0, .end = reference.items.len };
            const expected = std.mem.indexOf(u8, reference.items, needle);
            try testing.expectEqual(expected, plan.next(&buffer, range, 0));
            var last: ?usize = null;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, reference.items, from, needle)) |hit| {
                last = hit;
                from = hit + 1;
            }
            try testing.expectEqual(last, plan.previous(&buffer, range, range.end));
        }
    }
}
