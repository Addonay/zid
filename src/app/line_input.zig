//! Single-line text field used by pickers, go-to-line and keymap search. Pure state:
//! views draw it and the command layer maps Zed `editor::*` actions onto these methods.
const std = @import("std");

pub const LineInput = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    anchor: usize = 0,

    pub fn text(self: *const LineInput) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn clear(self: *LineInput) void {
        self.* = .{};
    }
    pub fn set(self: *LineInput, value: []const u8) void {
        self.clear();
        self.insert(value);
    }
    pub fn selection(self: *const LineInput) struct { start: usize, end: usize } {
        return .{ .start = @min(self.cursor, self.anchor), .end = @max(self.cursor, self.anchor) };
    }
    fn replaceSelection(self: *LineInput, value: []const u8) void {
        const sel = self.selection();
        // Keep only whole codepoints that fit.
        var n = @min(value.len, self.buf.len - (self.len - (sel.end - sel.start)));
        while (n > 0 and n < value.len and value[n] & 0xc0 == 0x80) n -= 1;
        const tail = self.len - sel.end;
        if (sel.start + n > sel.end)
            std.mem.copyBackwards(u8, self.buf[sel.start + n ..][0..tail], self.buf[sel.end..][0..tail])
        else
            std.mem.copyForwards(u8, self.buf[sel.start + n ..][0..tail], self.buf[sel.end..][0..tail]);
        @memcpy(self.buf[sel.start..][0..n], value[0..n]);
        self.len = sel.start + n + tail;
        self.cursor = sel.start + n;
        self.anchor = self.cursor;
    }
    /// Inserts text, dropping control characters (newlines from paste become spaces).
    pub fn insert(self: *LineInput, value: []const u8) void {
        var clean: [256]u8 = undefined;
        var n: usize = 0;
        for (value) |c| {
            if (n == clean.len) break;
            clean[n] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
            if (clean[n] < 0x20) continue;
            n += 1;
        }
        // The staging buffer can fill in the middle of a UTF-8 sequence.
        // Drop that incomplete sequence before passing it to replaceSelection.
        if (n == clean.len) {
            var start = n - 1;
            while (start > 0 and clean[start] & 0xc0 == 0x80) start -= 1;
            const width = std.unicode.utf8ByteSequenceLength(clean[start]) catch 1;
            if (n - start < width) n = start;
        }
        self.replaceSelection(clean[0..n]);
    }
    fn prev(self: *const LineInput, at: usize) usize {
        var i = at;
        if (i == 0) return 0;
        i -= 1;
        while (i > 0 and self.buf[i] & 0xc0 == 0x80) i -= 1;
        return i;
    }
    fn next(self: *const LineInput, at: usize) usize {
        var i = at;
        if (i >= self.len) return self.len;
        i += 1;
        while (i < self.len and self.buf[i] & 0xc0 == 0x80) i += 1;
        return i;
    }
    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
    }
    fn wordLeft(self: *const LineInput, at: usize) usize {
        var i = at;
        while (i > 0 and !isWord(self.buf[i - 1])) i -= 1;
        while (i > 0 and isWord(self.buf[i - 1])) i -= 1;
        return i;
    }
    fn wordRight(self: *const LineInput, at: usize) usize {
        var i = at;
        while (i < self.len and !isWord(self.buf[i])) i += 1;
        while (i < self.len and isWord(self.buf[i])) i += 1;
        return i;
    }
    pub fn moveTo(self: *LineInput, at: usize, extend: bool) void {
        self.cursor = @min(at, self.len);
        if (!extend) self.anchor = self.cursor;
    }
    pub fn left(self: *LineInput, extend: bool) void {
        const sel = self.selection();
        if (!extend and sel.start != sel.end) return self.moveTo(sel.start, false);
        self.moveTo(self.prev(self.cursor), extend);
    }
    pub fn right(self: *LineInput, extend: bool) void {
        const sel = self.selection();
        if (!extend and sel.start != sel.end) return self.moveTo(sel.end, false);
        self.moveTo(self.next(self.cursor), extend);
    }
    pub fn wordLeftMove(self: *LineInput, extend: bool) void {
        self.moveTo(self.wordLeft(self.cursor), extend);
    }
    pub fn wordRightMove(self: *LineInput, extend: bool) void {
        self.moveTo(self.wordRight(self.cursor), extend);
    }
    pub fn home(self: *LineInput, extend: bool) void {
        self.moveTo(0, extend);
    }
    pub fn end(self: *LineInput, extend: bool) void {
        self.moveTo(self.len, extend);
    }
    pub fn selectAll(self: *LineInput) void {
        self.anchor = 0;
        self.cursor = self.len;
    }
    pub fn backspace(self: *LineInput) void {
        if (self.cursor == self.anchor) self.anchor = self.prev(self.cursor);
        self.replaceSelection("");
    }
    pub fn delete(self: *LineInput) void {
        if (self.cursor == self.anchor) self.anchor = self.next(self.cursor);
        self.replaceSelection("");
    }
    pub fn deleteWordLeft(self: *LineInput) void {
        if (self.cursor == self.anchor) self.anchor = self.wordLeft(self.cursor);
        self.replaceSelection("");
    }
    pub fn deleteWordRight(self: *LineInput) void {
        if (self.cursor == self.anchor) self.anchor = self.wordRight(self.cursor);
        self.replaceSelection("");
    }
    pub fn deleteToStart(self: *LineInput) void {
        self.anchor = 0;
        self.replaceSelection("");
    }
};

test "line input edits, selects and respects codepoints" {
    var input: LineInput = .{};
    input.insert("hello wörld");
    try std.testing.expectEqualStrings("hello wörld", input.text());
    input.backspace();
    input.backspace();
    try std.testing.expectEqualStrings("hello wör", input.text());
    input.backspace();
    try std.testing.expectEqualStrings("hello wö", input.text());
    input.backspace();
    try std.testing.expectEqualStrings("hello w", input.text());
    input.deleteWordLeft();
    try std.testing.expectEqualStrings("hello ", input.text());
    input.home(false);
    input.wordRightMove(true);
    input.insert("bye");
    try std.testing.expectEqualStrings("bye ", input.text());
    input.selectAll();
    input.insert("a\nb");
    try std.testing.expectEqualStrings("a b", input.text());
}

test "line input does not split a codepoint at staging limit" {
    var input: LineInput = .{};
    var value: [257]u8 = undefined;
    @memset(value[0..255], 'a');
    @memcpy(value[255..], "é");
    input.insert(&value);
    try std.testing.expectEqual(@as(usize, 255), input.text().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(input.text()));
}
