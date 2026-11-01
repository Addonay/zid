const std = @import("std");
pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const Encoding = enum { utf8, utf16 };

/// Convert an absolute UTF-8 byte offset to an LSP position. Rejects invalid
/// UTF-8, mid-codepoint offsets and positions inside a CRLF pair.
pub fn fromOffset(text: []const u8, offset: usize, encoding: Encoding) !Position {
    if (offset > text.len) return error.OutOfBounds;
    var pos: Position = .{ .line = 0, .character = 0 };
    var i: usize = 0;
    while (i < offset) {
        if (text[i] == '\n' or text[i] == '\r') {
            const crlf = text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n';
            if (crlf and i + 1 == offset) return error.InvalidOffset;
            pos.line = std.math.add(u32, pos.line, 1) catch return error.Overflow;
            pos.character = 0;
            i += if (crlf) 2 else 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        if (i + n > text.len) return error.InvalidUtf8;
        if (i + n > offset) return error.InvalidOffset;
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch return error.InvalidUtf8;
        const units: u32 = if (encoding == .utf8) n else if (cp > 0xffff) 2 else 1;
        pos.character = std.math.add(u32, pos.character, units) catch return error.Overflow;
        i += n;
    }
    return pos;
}

pub fn toOffset(text: []const u8, pos: Position, encoding: Encoding) !usize {
    var i: usize = 0;
    var line: u32 = 0;
    while (line < pos.line) {
        while (i < text.len and text[i] != '\n' and text[i] != '\r') : (i += 1) {}
        if (i == text.len) return error.OutOfBounds;
        const crlf = text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n';
        i += if (crlf) 2 else 1;
        line += 1;
    }
    var col: u32 = 0;
    while (col < pos.character) {
        if (i >= text.len or text[i] == '\n' or text[i] == '\r') return error.OutOfBounds;
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidUtf8;
        if (i + n > text.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch return error.InvalidUtf8;
        const units: u32 = if (encoding == .utf8) n else if (cp > 0xffff) 2 else 1;
        col = std.math.add(u32, col, units) catch return error.Overflow;
        if (col > pos.character) return error.InvalidPosition;
        i += n;
    }
    return i;
}

test "mixed line endings and trailing lone carriage return" {
    const s = "é\r😀\nX\r\n\r";
    const offsets = [_]usize{ 0, 2, 3, 7, 8, 9, 11, 12 };
    const utf16 = [_]Position{
        .{ .line = 0, .character = 0 }, .{ .line = 0, .character = 1 },
        .{ .line = 1, .character = 0 }, .{ .line = 1, .character = 2 },
        .{ .line = 2, .character = 0 }, .{ .line = 2, .character = 1 },
        .{ .line = 3, .character = 0 }, .{ .line = 4, .character = 0 },
    };
    for (offsets, utf16) |offset, expected| {
        try std.testing.expectEqual(expected, try fromOffset(s, offset, .utf16));
        try std.testing.expectEqual(offset, try toOffset(s, expected, .utf16));
        const utf8 = try fromOffset(s, offset, .utf8);
        try std.testing.expectEqual(offset, try toOffset(s, utf8, .utf8));
    }
    try std.testing.expectError(error.InvalidOffset, fromOffset(s, 10, .utf16));
    try std.testing.expectError(error.OutOfBounds, toOffset(s, .{ .line = 0, .character = 2 }, .utf16));
    try std.testing.expectError(error.OutOfBounds, toOffset(s, .{ .line = 5, .character = 0 }, .utf16));
}

test "UTF-16 surrogate pair and CRLF" {
    const s = "a😀b\r\nz";
    const p = try fromOffset(s, 5, .utf16);
    try std.testing.expectEqual(@as(u32, 3), p.character);
    try std.testing.expectEqual(@as(usize, 5), try toOffset(s, p, .utf16));
    try std.testing.expectError(error.InvalidPosition, toOffset(s, .{ .line = 0, .character = 2 }, .utf16));
    try std.testing.expectError(error.InvalidOffset, fromOffset(s, 7, .utf16));
}
