const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const Node = @import("../text/piece_tree.zig").Node;

pub const Document = struct {
    allocator: std.mem.Allocator,
    buffer: TextBuffer,
    path: ?[:0]u8 = null,
    cursor: usize = 0,
    anchor: usize = 0,
    scroll_line: usize = 0,
    scroll_x: f32 = 0,
    history: std.ArrayList(Edit) = .empty,
    history_index: usize = 0,
    revision: u64 = 0,
    saved_revision: u64 = 0,
    next_revision: u64 = 1,
    crlf: bool = false,
    /// Temporary M1 rendering boundary, until windowed long-line layout lands.
    /// Keep such files inspectable without allowing edits to invisible bytes.
    preview_only: bool = false,
    disk_identity: ?DiskIdentity = null,

    pub const max_line_bytes = 64 * 1024;
    pub const DiskIdentity = struct {
        size: u64,
        mtime: std.Io.Timestamp,
        inode: std.Io.File.INode,

        pub fn fromStat(stat: std.Io.File.Stat) DiskIdentity {
            return .{ .size = stat.size, .mtime = stat.mtime, .inode = stat.inode };
        }
        pub fn eql(a: DiskIdentity, b: DiskIdentity) bool {
            return a.size == b.size and a.inode == b.inode and std.meta.eql(a.mtime, b.mtime);
        }
    };

    /// An undo entry is a pair of retained tree versions plus selection state; it never
    /// copies text. Consecutive typing coalesces into one entry (see `insert`).
    const Edit = struct {
        before: ?*Node,
        after: ?*Node,
        before_cursor: usize,
        before_anchor: usize,
        after_cursor: usize,
        after_anchor: usize,
        before_revision: u64,
        after_revision: u64,
        typing: bool,
    };
    pub fn init(allocator: std.mem.Allocator, text: []const u8, path: ?[]const u8) !Document {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.BinaryFile;
        var self: Document = .{ .allocator = allocator, .buffer = try TextBuffer.init(allocator, text), .crlf = std.mem.indexOf(u8, text, "\r\n") != null };
        errdefer self.deinit();
        if (path) |value| self.path = try allocator.dupeSentinel(u8, value, 0);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| if (line.len > max_line_bytes) {
            self.preview_only = true;
            break;
        };
        return self;
    }
    pub fn deinit(self: *Document) void {
        for (self.history.items) |edit| self.freeEdit(edit);
        self.history.deinit(self.allocator);
        if (self.path) |path| self.allocator.free(path);
        self.buffer.deinit();
    }
    fn freeEdit(self: *Document, edit: Edit) void {
        self.buffer.releaseRoot(edit.before);
        self.buffer.releaseRoot(edit.after);
    }
    pub fn dirty(self: *const Document) bool {
        return self.revision != self.saved_revision;
    }
    pub fn lineCount(self: *const Document) usize {
        return self.buffer.lineCount();
    }
    pub fn lineStart(self: *const Document, line: usize) usize {
        return self.buffer.lineStart(line);
    }
    pub fn lineOf(self: *const Document, offset: usize) usize {
        return self.buffer.lineOf(offset);
    }
    pub fn lineEnd(self: *const Document, line: usize) usize {
        var end = if (line + 1 < self.lineCount()) self.lineStart(line + 1) - 1 else self.buffer.len();
        if (end > self.lineStart(line) and self.buffer.byteAt(end - 1) == '\r') end -= 1;
        return end;
    }
    /// Sets the selection after an edit; redo then restores exactly this selection.
    pub fn setSelection(self: *Document, anchor: usize, cursor: usize) void {
        self.anchor = @min(anchor, self.buffer.len());
        self.cursor = @min(cursor, self.buffer.len());
        if (self.history_index > 0) {
            const last = &self.history.items[self.history_index - 1];
            if (last.after_revision == self.revision) {
                last.after_cursor = self.cursor;
                last.after_anchor = self.anchor;
            }
        }
    }
    pub fn selection(self: *const Document) struct { start: usize, end: usize } {
        return .{ .start = @min(self.cursor, self.anchor), .end = @max(self.cursor, self.anchor) };
    }
    pub fn move(self: *Document, offset: usize, extend: bool) void {
        const previous_cursor = self.cursor;
        self.cursor = @min(offset, self.buffer.len());
        while (self.cursor > 0 and self.cursor < self.buffer.len() and self.buffer.byteAt(self.cursor) & 0xc0 == 0x80) self.cursor -= 1;
        if (self.cursor > 0 and self.cursor < self.buffer.len() and
            self.buffer.byteAt(self.cursor - 1) == '\r' and self.buffer.byteAt(self.cursor) == '\n')
        {
            self.cursor = if (self.cursor > previous_cursor) self.cursor + 1 else self.cursor - 1;
        }
        if (!extend) self.anchor = self.cursor;
    }
    pub fn moveVertical(self: *Document, delta: i32, extend: bool) void {
        const row = self.lineOf(self.cursor);
        var column: usize = 0;
        var byte = self.lineStart(row);
        while (byte < self.cursor) : (column += 1) byte = self.buffer.next(byte);
        const target: usize = @intCast(std.math.clamp(@as(i64, @intCast(row)) + delta, 0, @as(i64, @intCast(self.lineCount() - 1))));
        byte = self.lineStart(target);
        for (0..column) |_| {
            if (byte >= self.lineEnd(target)) break;
            byte = self.buffer.next(byte);
        }
        self.move(byte, extend);
    }
    /// Replaces the selection with `text` (typing, paste, delete); the cursor lands after it.
    pub fn insert(self: *Document, text: []const u8) !void {
        const range = self.selection();
        const typing = range.start == range.end and text.len > 0 and std.mem.indexOfAny(u8, text, "\r\n") == null;
        try self.applyEdit(range.start, range.end, text, typing);
    }
    /// Replaces [start, end) with `text` as one undo step, independent of the selection.
    /// The cursor lands after the inserted text; callers may then adjust the selection.
    pub fn replaceRange(self: *Document, start: usize, end: usize, text: []const u8) !void {
        try self.applyEdit(start, end, text, false);
    }
    fn applyEdit(self: *Document, start: usize, end: usize, text: []const u8, typing: bool) !void {
        if (self.preview_only) return error.ReadOnlyLongLinePreview;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.BinaryFile;
        std.debug.assert(start <= end and end <= self.buffer.len());
        const range: struct { start: usize, end: usize } = .{ .start = start, .end = end };
        // Validate the resulting affected lines before modifying storage/history.
        var width = range.start - self.lineStart(self.lineOf(range.start));
        for (text) |byte| {
            if (byte == '\n') width = 0 else width += 1;
            if (width > max_line_bytes) return error.LineTooLong;
        }
        width += self.lineEnd(self.lineOf(range.end)) -| range.end;
        if (width > max_line_bytes) return error.LineTooLong;
        if (range.start == range.end and text.len == 0) return;
        // Coalesce typing into the previous entry while it continues at the same place,
        // and break groups at word boundaries so undo removes roughly a word at a time.
        const coalesce = typing and self.history_index == self.history.items.len and self.history_index > 0 and blk: {
            const last = self.history.items[self.history_index - 1];
            const starts_word = text[0] != ' ' and range.start > 0 and self.buffer.byteAt(range.start - 1) == ' ';
            break :blk last.typing and last.after_revision == self.revision and last.after_cursor == range.start and !starts_word;
        };
        if (!coalesce) try self.history.ensureTotalCapacity(self.allocator, self.history_index + 1);
        const before = self.buffer.root();
        errdefer self.buffer.releaseRoot(before);
        try self.buffer.replace(range.start, range.end, text);
        const after = self.buffer.root();
        const after_cursor = range.start + text.len;
        if (coalesce) {
            self.buffer.releaseRoot(before);
            const last = &self.history.items[self.history_index - 1];
            self.buffer.releaseRoot(last.after);
            last.after = after;
            last.after_cursor = after_cursor;
            last.after_anchor = after_cursor;
            last.after_revision = self.next_revision;
        } else {
            for (self.history.items[self.history_index..]) |edit| self.freeEdit(edit);
            self.history.shrinkRetainingCapacity(self.history_index);
            self.history.appendAssumeCapacity(.{
                .before = before,
                .after = after,
                .before_cursor = self.cursor,
                .before_anchor = self.anchor,
                .after_cursor = after_cursor,
                .after_anchor = after_cursor,
                .before_revision = self.revision,
                .after_revision = self.next_revision,
                .typing = typing,
            });
            self.history_index += 1;
        }
        self.revision = self.next_revision;
        self.next_revision += 1;
        self.move(after_cursor, false);
    }
    pub fn backspace(self: *Document) !void {
        const previous_anchor = self.anchor;
        errdefer self.anchor = previous_anchor;
        if (self.cursor == self.anchor and self.cursor > 0) {
            self.anchor = self.buffer.previous(self.cursor);
            if (self.buffer.byteAt(self.anchor) == '\n' and self.anchor > 0 and self.buffer.byteAt(self.anchor - 1) == '\r') self.anchor -= 1;
        }
        try self.insert("");
    }
    pub fn deleteForward(self: *Document) !void {
        const previous_anchor = self.anchor;
        errdefer self.anchor = previous_anchor;
        if (self.cursor == self.anchor) {
            self.anchor = self.buffer.next(self.cursor);
            if (self.cursor < self.buffer.len() and self.buffer.byteAt(self.cursor) == '\r' and self.anchor < self.buffer.len() and self.buffer.byteAt(self.anchor) == '\n') self.anchor += 1;
        }
        try self.insert("");
    }
    pub fn undo(self: *Document) !void {
        if (self.history_index == 0) return;
        const edit = self.history.items[self.history_index - 1];
        self.buffer.setRoot(edit.before);
        self.history_index -= 1;
        self.cursor = @min(edit.before_cursor, self.buffer.len());
        self.anchor = @min(edit.before_anchor, self.buffer.len());
        self.revision = edit.before_revision;
    }
    pub fn redo(self: *Document) !void {
        if (self.history_index == self.history.items.len) return;
        const edit = self.history.items[self.history_index];
        self.buffer.setRoot(edit.after);
        self.history_index += 1;
        self.cursor = @min(edit.after_cursor, self.buffer.len());
        self.anchor = @min(edit.after_anchor, self.buffer.len());
        self.revision = edit.after_revision;
    }
};

fn expectText(document: *Document, text: []const u8) !void {
    const actual = try document.buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(text, actual);
}
test "selection replacement, undo, redo and branching preserve saved revision" {
    var document = try Document.init(std.testing.allocator, "hello\nworld", null);
    defer document.deinit();
    document.move(5, false);
    document.move(0, true);
    try document.insert("hi");
    try expectText(&document, "hi\nworld");
    document.saved_revision = document.revision;
    try document.undo();
    try std.testing.expect(document.dirty());
    try document.redo();
    try std.testing.expect(!document.dirty());
    try document.undo();
    try document.insert("bye");
    try document.redo();
    try expectText(&document, "bye\nworld");
    try std.testing.expect(document.dirty());
}
test "UTF-8 deletion and CRLF indexing retain file bytes" {
    var document = try Document.init(std.testing.allocator, "é\r\n中\r\n", null);
    defer document.deinit();
    try std.testing.expectEqual(@as(usize, 3), document.lineCount());
    try std.testing.expectEqual(@as(usize, 2), document.lineEnd(0));
    document.move(2, false);
    try document.backspace();
    try expectText(&document, "\r\n中\r\n");
    document.move(2, false);
    try document.backspace();
    try expectText(&document, "中\r\n");
    try document.undo();
    try expectText(&document, "\r\n中\r\n");
}
test "binary and malformed UTF-8 inputs are rejected" {
    try std.testing.expectError(error.BinaryFile, Document.init(std.testing.allocator, "a\x00b", null));
    try std.testing.expectError(error.InvalidUtf8, Document.init(std.testing.allocator, "\xff", null));
}

test "CRLF navigation and deletion use whole newline boundaries" {
    var document = try Document.init(std.testing.allocator, "a\r\nb\nc", null);
    defer document.deinit();
    document.move(1, false);
    document.move(document.buffer.next(document.cursor), false);
    try std.testing.expectEqual(@as(usize, 3), document.cursor);
    document.move(document.buffer.previous(document.cursor), true);
    try std.testing.expectEqual(@as(usize, 1), document.cursor);
    try std.testing.expectEqual(@as(usize, 3), document.anchor);
    document.move(3, false);
    try document.backspace();
    try expectText(&document, "ab\nc");
    try document.undo();
    document.move(1, false);
    try document.deleteForward();
    try expectText(&document, "ab\nc");
}

test "long lines are explicit read-only previews and oversized edits are atomic" {
    const bytes = try std.testing.allocator.alloc(u8, Document.max_line_bytes + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    var preview = try Document.init(std.testing.allocator, bytes, null);
    defer preview.deinit();
    try std.testing.expect(preview.preview_only);
    try std.testing.expectError(error.ReadOnlyLongLinePreview, preview.insert("a"));
    var editable = try Document.init(std.testing.allocator, "short", null);
    defer editable.deinit();
    try std.testing.expectError(error.LineTooLong, editable.insert(bytes));
    try expectText(&editable, "short");
}

test "failed newline deletion preserves cursor and selection" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, Document.max_line_bytes + 2);
    defer allocator.free(bytes);
    @memset(bytes, 'x');
    bytes[Document.max_line_bytes] = '\n';
    var document = try Document.init(allocator, bytes, null);
    defer document.deinit();
    document.move(Document.max_line_bytes, false);
    try std.testing.expectError(error.LineTooLong, document.deleteForward());
    try std.testing.expectEqual(Document.max_line_bytes, document.cursor);
    try std.testing.expectEqual(document.cursor, document.anchor);
    document.move(Document.max_line_bytes + 1, false);
    try std.testing.expectError(error.LineTooLong, document.backspace());
    try std.testing.expectEqual(Document.max_line_bytes + 1, document.cursor);
    try std.testing.expectEqual(document.cursor, document.anchor);
    try expectText(&document, bytes);
    try std.testing.expectEqual(@as(usize, 0), document.history_index);
}

test "typing coalesces into word-sized undo steps" {
    var document = try Document.init(std.testing.allocator, "", null);
    defer document.deinit();
    for ("hello world") |c| try document.insert(&.{c});
    try expectText(&document, "hello world");
    try std.testing.expectEqual(@as(usize, 2), document.history.items.len);
    try document.undo();
    try expectText(&document, "hello ");
    try document.undo();
    try expectText(&document, "");
    try document.redo();
    try document.redo();
    try expectText(&document, "hello world");
    try std.testing.expectEqual(@as(usize, 11), document.cursor);
}
