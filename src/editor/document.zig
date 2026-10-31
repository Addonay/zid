const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;

pub const Document = struct {
    allocator: std.mem.Allocator,
    buffer: Buffer,
    path: ?[:0]u8 = null,
    lines: std.ArrayList(usize) = .empty,
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

    const Edit = struct {
        start: usize,
        removed: []u8,
        inserted: []u8,
        before_cursor: usize,
        before_anchor: usize,
        before_revision: u64,
        after_revision: u64,
    };
    pub fn init(allocator: std.mem.Allocator, text: []const u8, path: ?[]const u8) !Document {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.BinaryFile;
        var self: Document = .{ .allocator = allocator, .buffer = try Buffer.init(allocator, text), .crlf = std.mem.indexOf(u8, text, "\r\n") != null };
        errdefer self.deinit();
        if (path) |value| self.path = try allocator.dupeSentinel(u8, value, 0);
        try self.reindex();
        for (self.lines.items, 0..) |start, row| if (self.lineEnd(row) - start > max_line_bytes) {
            self.preview_only = true;
            break;
        };
        return self;
    }
    pub fn deinit(self: *Document) void {
        for (self.history.items) |edit| self.freeEdit(edit);
        self.history.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        if (self.path) |path| self.allocator.free(path);
        self.buffer.deinit();
    }
    fn freeEdit(self: *Document, edit: Edit) void {
        self.allocator.free(edit.removed);
        self.allocator.free(edit.inserted);
    }
    pub fn dirty(self: *const Document) bool {
        return self.revision != self.saved_revision;
    }
    fn reindex(self: *Document) !void {
        var count: usize = 1;
        for (0..self.buffer.len()) |index| if (self.buffer.byteAt(index) == '\n') {
            count += 1;
        };
        try self.lines.ensureTotalCapacity(self.allocator, count);
        self.lines.clearRetainingCapacity();
        self.lines.appendAssumeCapacity(0);
        for (0..self.buffer.len()) |index| if (self.buffer.byteAt(index) == '\n') {
            self.lines.appendAssumeCapacity(index + 1);
        };
    }
    pub fn lineOf(self: *const Document, offset: usize) usize {
        var low: usize = 0;
        var high = self.lines.items.len;
        while (low + 1 < high) {
            const middle = low + (high - low) / 2;
            if (self.lines.items[middle] <= offset) low = middle else high = middle;
        }
        return low;
    }
    pub fn lineEnd(self: *const Document, line: usize) usize {
        var end = if (line + 1 < self.lines.items.len) self.lines.items[line + 1] - 1 else self.buffer.len();
        if (end > self.lines.items[line] and self.buffer.byteAt(end - 1) == '\r') end -= 1;
        return end;
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
        var byte = self.lines.items[row];
        while (byte < self.cursor) : (column += 1) byte = self.buffer.next(byte);
        const target: usize = @intCast(std.math.clamp(@as(i64, @intCast(row)) + delta, 0, @as(i64, @intCast(self.lines.items.len - 1))));
        byte = self.lines.items[target];
        for (0..column) |_| {
            if (byte >= self.lineEnd(target)) break;
            byte = self.buffer.next(byte);
        }
        self.move(byte, extend);
    }
    pub fn insert(self: *Document, text: []const u8) !void {
        if (self.preview_only) return error.ReadOnlyLongLinePreview;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.BinaryFile;
        const range = self.selection();
        // Validate the resulting affected lines before modifying storage/history.
        var width = range.start - self.lines.items[self.lineOf(range.start)];
        for (text) |byte| {
            if (byte == '\n') width = 0 else width += 1;
            if (width > max_line_bytes) return error.LineTooLong;
        }
        width += self.lineEnd(self.lineOf(range.end)) -| range.end;
        if (width > max_line_bytes) return error.LineTooLong;
        if (range.start == range.end and text.len == 0) return;
        const removed = try self.allocator.alloc(u8, range.end - range.start);
        errdefer self.allocator.free(removed);
        self.buffer.copy(range.start, removed);
        const inserted = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(inserted);
        try self.history.ensureTotalCapacity(self.allocator, self.history_index + 1);
        try self.lines.ensureTotalCapacity(self.allocator, self.lines.items.len + std.mem.countScalar(u8, text, '\n'));
        try self.buffer.replace(range.start, range.end, text);
        for (self.history.items[self.history_index..]) |edit| self.freeEdit(edit);
        self.history.shrinkRetainingCapacity(self.history_index);
        self.history.appendAssumeCapacity(.{
            .start = range.start,
            .removed = removed,
            .inserted = inserted,
            .before_cursor = self.cursor,
            .before_anchor = self.anchor,
            .before_revision = self.revision,
            .after_revision = self.next_revision,
        });
        self.history_index += 1;
        self.revision = self.next_revision;
        self.next_revision += 1;
        self.move(range.start + text.len, false);
        try self.reindex();
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
        try self.lines.ensureTotalCapacity(self.allocator, self.lines.items.len + std.mem.countScalar(u8, edit.removed, '\n'));
        try self.buffer.replace(edit.start, edit.start + edit.inserted.len, edit.removed);
        self.history_index -= 1;
        self.cursor = edit.before_cursor;
        self.anchor = edit.before_anchor;
        self.revision = edit.before_revision;
        try self.reindex();
    }
    pub fn redo(self: *Document) !void {
        if (self.history_index == self.history.items.len) return;
        const edit = self.history.items[self.history_index];
        try self.lines.ensureTotalCapacity(self.allocator, self.lines.items.len + std.mem.countScalar(u8, edit.inserted, '\n'));
        try self.buffer.replace(edit.start, edit.start + edit.removed.len, edit.inserted);
        self.history_index += 1;
        self.move(edit.start + edit.inserted.len, false);
        self.revision = edit.after_revision;
        try self.reindex();
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
    try std.testing.expectEqual(@as(usize, 3), document.lines.items.len);
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
