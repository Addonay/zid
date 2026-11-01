//! Ports of Zed's `text::LineEnding` and `text::LineIndent` (`text.rs`).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const LineEnding = enum {
    unix,
    windows,

    pub const default: LineEnding = if (builtin.os.tag == .windows) .windows else .unix;

    pub fn asStr(self: LineEnding) []const u8 {
        return switch (self) {
            .unix => "\n",
            .windows => "\r\n",
        };
    }

    pub fn label(self: LineEnding) []const u8 {
        return switch (self) {
            .unix => "LF",
            .windows => "CRLF",
        };
    }

    /// Looks at the first newline within the first 1000 bytes.
    pub fn detect(text: []const u8) LineEnding {
        var max_ix = @min(text.len, 1000);
        while (max_ix > 0 and max_ix < text.len and (text[max_ix] & 0xC0) == 0x80) max_ix -= 1;
        const ix = std.mem.indexOfScalar(u8, text[0..max_ix], '\n') orelse return default;
        return if (ix > 0 and text[ix - 1] == '\r') .windows else .unix;
    }

    /// Whether `text` contains `\r\n` or `\r` (Zed's `LINE_SEPARATORS_REGEX`).
    pub fn needsNormalization(text: []const u8) bool {
        return std.mem.indexOfScalar(u8, text, '\r') != null;
    }

    /// Replaces `\r\n` and lone `\r` with `\n`. Returns `text` itself when unchanged,
    /// otherwise a new allocation owned by the caller.
    pub fn normalize(gpa: Allocator, text: []const u8) Allocator.Error![]const u8 {
        if (!needsNormalization(text)) return text;
        var result: std.ArrayList(u8) = try .initCapacity(gpa, text.len);
        errdefer result.deinit(gpa);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\r') {
                result.appendAssumeCapacity('\n');
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            } else result.appendAssumeCapacity(text[i]);
        }
        return result.toOwnedSlice(gpa);
    }

    /// Converts `text` to this line ending (detection uses the first newline). The
    /// result is always a new allocation.
    pub fn apply(self: LineEnding, gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
        const detected = detect(text);
        if (detected == self) return gpa.dupe(u8, text);
        if (self == .unix) {
            const normalized = try normalize(gpa, text);
            if (normalized.ptr == text.ptr) return gpa.dupe(u8, text);
            return @constCast(normalized);
        }
        return std.mem.replaceOwned(u8, gpa, text, "\n", "\r\n");
    }
};

pub const LineIndent = struct {
    tabs: u32,
    spaces: u32,
    line_blank: bool,

    pub fn fromStr(text: []const u8) LineIndent {
        var indent: LineIndent = .{ .tabs = 0, .spaces = 0, .line_blank = true };
        _ = indent.feed(text);
        return indent;
    }

    /// Accumulates leading indentation from a chunk; returns false once a
    /// non-indentation byte ends the indent (Zed's `from_chunks` loop).
    pub fn feed(self: *LineIndent, chunk: []const u8) bool {
        for (chunk) |byte| {
            switch (byte) {
                '\t' => self.tabs += 1,
                ' ' => self.spaces += 1,
                else => {
                    if (byte != '\n') self.line_blank = false;
                    return false;
                },
            }
        }
        return true;
    }

    pub fn initSpaces(spaces: u32) LineIndent {
        return .{ .tabs = 0, .spaces = spaces, .line_blank = true };
    }

    pub fn initTabs(tabs: u32) LineIndent {
        return .{ .tabs = tabs, .spaces = 0, .line_blank = true };
    }

    pub fn isLineEmpty(self: LineIndent) bool {
        return self.tabs == 0 and self.spaces == 0 and self.line_blank;
    }

    pub fn isLineBlank(self: LineIndent) bool {
        return self.line_blank;
    }

    pub fn rawLen(self: LineIndent) u32 {
        return self.tabs + self.spaces;
    }

    pub fn len(self: LineIndent, tab_size: u32) u32 {
        return self.tabs * tab_size + self.spaces;
    }
};

const testing = std.testing;

test "line ending detect normalize apply" {
    const gpa = testing.allocator;
    try testing.expectEqual(LineEnding.windows, LineEnding.detect("a\r\nb"));
    try testing.expectEqual(LineEnding.unix, LineEnding.detect("a\nb\r\n"));
    try testing.expectEqual(LineEnding.default, LineEnding.detect("no newline"));

    const same = try LineEnding.normalize(gpa, "plain\n");
    try testing.expectEqual(@as([*]const u8, "plain\n".ptr), same.ptr);
    const normalized = try LineEnding.normalize(gpa, "a\r\nb\rc\n");
    defer gpa.free(normalized);
    try testing.expectEqualStrings("a\nb\nc\n", normalized);

    const crlf = try LineEnding.windows.apply(gpa, "a\nb\n");
    defer gpa.free(crlf);
    try testing.expectEqualStrings("a\r\nb\r\n", crlf);
    const lf = try LineEnding.unix.apply(gpa, crlf);
    defer gpa.free(lf);
    try testing.expectEqualStrings("a\nb\n", lf);
}

test "line indent" {
    const indent = LineIndent.fromStr("\t  x");
    try testing.expectEqual(@as(u32, 1), indent.tabs);
    try testing.expectEqual(@as(u32, 2), indent.spaces);
    try testing.expect(!indent.isLineBlank());
    try testing.expectEqual(@as(u32, 6), indent.len(4));
    try testing.expect(LineIndent.fromStr("   \n").isLineBlank());
    try testing.expect(LineIndent.fromStr("").isLineEmpty());
}
