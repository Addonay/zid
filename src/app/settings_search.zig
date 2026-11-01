//! Small, allocation-free matcher for settings metadata.
//!
//! ASCII letters are folded for case-insensitive matching. Non-ASCII bytes are
//! compared as-is in word-prefix mode; fuzzy fallback is limited to bounded ASCII.
const std = @import("std");
const fuzzy = @import("fuzzy.zig");

pub const Metadata = struct {
    title: []const u8,
    description: []const u8 = "",
    section: []const u8 = "",
    page: []const u8 = "",
    jsonpath: ?[]const u8 = null,
};

pub const Match = struct {
    /// Higher scores rank ahead of lower scores. Path matches rank above text.
    score: i32,
    kind: Kind,
};

pub const Kind = enum { jsonpath, word_prefix, fuzzy };

fn fold(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn eqFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (fold(x) != fold(y)) return false;
    return true;
}

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn isAscii(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAscii(c)) return false;
    return true;
}

fn prefixAtWord(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (i != 0 and wordByte(hay[i - 1])) continue;
        if (eqFold(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn fieldPrefixScore(m: Metadata, q: []const u8) ?i32 {
    // Each query token may be found in any supported metadata field.
    var words = std.mem.tokenizeAny(u8, q, " \t\r\n");
    var total: i32 = 1000;
    var count: i32 = 0;
    while (words.next()) |word| {
        var best: i32 = 0;
        if (prefixAtWord(m.title, word)) best = 40;
        if (prefixAtWord(m.section, word)) best = @max(best, 30);
        if (prefixAtWord(m.page, word)) best = @max(best, 25);
        if (prefixAtWord(m.description, word)) best = @max(best, 20);
        if (best == 0) return null;
        total += best;
        count += 1;
    }
    if (count == 0) return null;
    if (eqFold(m.title, q)) total += 500;
    return total;
}

/// Return a ranking match for `query`, or null when it does not match.
/// A leading `#` searches only JSON paths and accepts a complete path or a
/// dot-delimited descendant, matching Zed's settings search behavior.
pub fn score(m: Metadata, query: []const u8) ?Match {
    if (query.len == 0) return null;
    if (!std.unicode.utf8ValidateSlice(query)) return null;
    if (query[0] == '#') {
        const path_query = query[1..];
        if (path_query.len == 0) return null;
        if (m.jsonpath) |path| {
            if (path.len >= path_query.len and eqFold(path[0..path_query.len], path_query) and
                (path.len == path_query.len or path[path_query.len] == '.'))
                return .{ .score = 100_000 + @as(i32, @intCast(@min(path_query.len, 1000))), .kind = .jsonpath };
        }
        return null;
    }

    if (fieldPrefixScore(m, query)) |s| return .{ .score = s, .kind = .word_prefix };

    // fuzzy.match uses bounded byte buffers. Restrict fallback to ASCII and
    // skip overlong inputs rather than truncating a query or UTF-8 codepoint.
    if (!std.unicode.utf8ValidateSlice(query) or query.len > fuzzy.max_needle or
        !isAscii(query)) return null;
    const fields = [_][]const u8{ m.title, m.description, m.section, m.page };
    var best: ?i32 = null;
    for (fields, 0..) |field, index| {
        if (field.len > fuzzy.max_haystack or !isAscii(field)) continue;
        if (fuzzy.match(query, field)) |fm| {
            // Preserve field priority and keep fuzzy below every prefix match.
            const candidate = 100 + fm.score - @as(i32, @intCast(index * 4));
            best = if (best) |old| @max(old, candidate) else candidate;
        }
    }
    return if (best) |s| .{ .score = s, .kind = .fuzzy } else null;
}

const testing = std.testing;

test "settings search ranks exact and prefix matches" {
    const exact = score(.{ .title = "Font Size", .page = "Appearance" }, "font size").?;
    const prefix = score(.{ .title = "Font Size", .page = "Appearance" }, "fon siz").?;
    try testing.expectEqual(Kind.word_prefix, exact.kind);
    try testing.expect(exact.score > prefix.score);
}

test "settings search fuzzy fallback ranks below word prefixes" {
    const m = Metadata{ .title = "Font Size", .description = "Editor buffer text size" };
    const fuzzy_match = score(m, "fnt").?;
    const prefix = score(m, "fon").?;
    try testing.expectEqual(Kind.fuzzy, fuzzy_match.kind);
    try testing.expect(fuzzy_match.score < prefix.score);
}

test "hash query selects complete JSON path and descendants" {
    const m = Metadata{ .title = "Font Size", .jsonpath = "buffer.font_size.sub" };
    try testing.expect(score(m, "#buffer") != null);
    try testing.expect(score(m, "#buffer.font_size") != null);
    try testing.expect(score(m, "#buffered") == null);
    try testing.expect(score(m, "#font_size") == null);
}

test "all query words may match separate metadata fields" {
    const m = Metadata{ .title = "Font Size", .section = "Buffer", .page = "Appearance", .description = "Text pixels" };
    try testing.expect(score(m, "buf app").?.kind == .word_prefix);
    try testing.expect(score(m, "buf absent") == null);
}

test "no match and oversized or non-ASCII fallback are safe" {
    const m = Metadata{ .title = "Font Size" };
    try testing.expect(score(m, "zzq") == null);
    try testing.expect(score(m, "é") == null);
    try testing.expect(score(m, "abcdefghijklmnopqrstuvwxyz123456789") == null);
}
