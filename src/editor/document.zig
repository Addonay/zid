const std = @import("std");
const TextBuffer = @import("text_buffer.zig").TextBuffer;
const Node = @import("../text/piece_tree.zig").Node;
var next_instance_id: std.atomic.Value(u64) = .init(1);

pub const Document = struct {
    allocator: std.mem.Allocator,
    buffer: TextBuffer,
    /// Stable across edits and moves, distinct for each opened document.
    instance_id: u64,
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
    large: ?LargeState = null,

    pub const LargeState = struct {
        worker: *@import("../text/large_worker.zig").Worker,
        size: u64,
        offset: u64 = 0,
        anchor: u64 = 0,
        expected_copy: ?u64 = null,
        failure: ?anyerror = null,
        requested_offset: ?u64 = null,
        generation: u64 = 0,
        line_pending: bool = false,
        active_extend: bool = false,
        queue: [256]Intent = undefined,
        queue_len: usize = 0,
        needs_redraw: bool = true,
        last_indexed: u64 = 0,
        last_loading: bool = true,
        last_line: ?u64 = null,
        visible_origin: u64 = 0,
        visible_end: u64 = 0,

        const Intent = union(enum) {
            lines: struct { count: i64, extend: bool },
            boundary: struct { which: @import("../text/large_worker.zig").Boundary, extend: bool },
            byte: struct { direction: i8, extend: bool },
        };

        fn window(self: *LargeState, origin: u64) void {
            self.requested_offset = origin;
            self.generation = self.worker.requestWindow(origin);
            self.needs_redraw = true;
        }
        fn follow(self: *LargeState) void {
            // Include the byte immediately before a forward selection endpoint.
            const target = if (self.offset > self.anchor) self.offset - 1 else self.offset;
            const origin = @min(target, self.size -| 1);
            const snap = self.worker.snapshot(&.{});
            if (!snap.loading and snap.offset == self.visible_origin and target >= self.visible_origin and target < self.visible_end) {
                self.needs_redraw = true;
                return;
            }
            self.window(origin);
        }
        pub fn poll(self: *LargeState, out: []u8) @import("../text/large_worker.zig").Snapshot {
            if (self.requested_offset == null and !self.line_pending) self.window(0);
            const snapshot = self.worker.snapshot(out);
            const failure: ?anyerror = snapshot.index_error orelse snapshot.request_error;
            if (snapshot.indexed_bytes != self.last_indexed or snapshot.loading != self.last_loading or snapshot.first_line != self.last_line or failure != self.failure) self.needs_redraw = true;
            self.last_indexed = snapshot.indexed_bytes;
            self.last_loading = snapshot.loading;
            self.last_line = snapshot.first_line;
            self.failure = failure;
            if (self.line_pending and !snapshot.loading and snapshot.generation == self.generation) {
                self.line_pending = false;
                if (snapshot.request_error == null) {
                    self.offset = snapshot.offset;
                    if (!self.active_extend) self.anchor = self.offset;
                    self.needs_redraw = true;
                    self.advance();
                } else self.queue_len = 0;
            }
            return snapshot;
        }
        pub fn cancelCopy(self: *LargeState) void {
            if (self.expected_copy != null) self.worker.cancelCopy();
            self.expected_copy = null;
        }
        pub fn selection(self: *const LargeState) struct { start: u64, end: u64 } {
            return .{ .start = @min(self.anchor, self.offset), .end = @max(self.anchor, self.offset) };
        }
        pub fn restoreSelection(self: *LargeState, anchor: u64, offset: u64) void {
            self.move(offset, true);
            self.anchor = @min(anchor, self.size);
            self.follow();
        }
        /// Absolute navigation supersedes all pending intentions.
        pub fn move(self: *LargeState, offset: u64, extend: bool) void {
            self.cancelCopy();
            self.queue_len = 0;
            self.line_pending = false;
            self.offset = @min(offset, self.size);
            if (!extend) self.anchor = self.offset;
            self.follow();
        }
        pub fn selectAll(self: *LargeState) void {
            self.cancelCopy();
            self.queue_len = 0;
            self.line_pending = false;
            self.anchor = 0;
            self.offset = self.size;
            // Supersede a pending navigation without moving the viewport.
            self.window(self.worker.snapshot(&.{}).offset);
        }
        pub fn copy(self: *LargeState) !void {
            self.cancelCopy();
            if (self.line_pending or self.queue_len != 0) return error.LargeFileNavigationPending;
            const sel = self.selection();
            if (sel.start != sel.end) self.expected_copy = self.worker.requestCopy(sel.start, sel.end);
        }
        pub fn requestLine(self: *LargeState, line: u64) void {
            self.cancelCopy();
            self.queue_len = 0;
            self.active_extend = false;
            self.generation = self.worker.requestLine(line);
            self.line_pending = true;
        }
        fn enqueue(self: *LargeState, intent: Intent) !void {
            self.cancelCopy();
            if (self.queue_len == self.queue.len) return error.LargeFileNavigationQueueFull;
            self.queue[self.queue_len] = intent;
            self.queue_len += 1;
            if (!self.line_pending) self.advance();
        }
        fn advance(self: *LargeState) void {
            while (self.queue_len > 0) {
                const intent = self.queue[0];
                self.queue_len -= 1;
                std.mem.copyForwards(Intent, self.queue[0..self.queue_len], self.queue[1..][0..self.queue_len]);
                switch (intent) {
                    .lines => |n| {
                        self.active_extend = n.extend;
                        self.generation = self.worker.requestRelative(self.offset, n.count);
                        self.line_pending = true;
                        return;
                    },
                    .boundary => |v| {
                        self.active_extend = v.extend;
                        self.generation = self.worker.requestBoundary(self.offset, v.which);
                        self.line_pending = true;
                        return;
                    },
                    .byte => |v| {
                        const sel = self.selection();
                        self.offset = if (!v.extend and sel.start != sel.end)
                            (if (v.direction < 0) sel.start else sel.end)
                        else if (v.direction < 0) self.offset -| 1 else @min(self.size, self.offset +| 1);
                        if (!v.extend) self.anchor = self.offset;
                    },
                }
            }
            self.follow();
        }
        pub fn moveLines(self: *LargeState, lines: i64) !void {
            if (lines != 0) try self.enqueue(.{ .lines = .{ .count = lines, .extend = false } });
        }
        pub fn selectLines(self: *LargeState, lines: i64) !void {
            if (lines != 0) try self.enqueue(.{ .lines = .{ .count = lines, .extend = true } });
        }
        pub fn moveBoundary(self: *LargeState, which: @import("../text/large_worker.zig").Boundary, extend: bool) !void {
            try self.enqueue(.{ .boundary = .{ .which = which, .extend = extend } });
        }
        pub fn moveByte(self: *LargeState, direction: i8, extend: bool) !void {
            try self.enqueue(.{ .byte = .{ .direction = direction, .extend = extend } });
        }
    };

    pub const max_line_bytes = 64 * 1024;
    /// Bounds retained undo versions, not total text storage: the append-only add
    /// buffer still requires a separate compaction policy.
    pub const max_history_entries = 1000;
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
        try validateText(text);
        return initOwned(allocator, try allocator.dupe(u8, text), path);
    }
    /// Consumes allocator-owned text on both success and failure. File loading can
    /// hand its allocation directly to storage instead of retaining a second copy.
    pub fn initOwned(allocator: std.mem.Allocator, text: []u8, path: ?[]const u8) !Document {
        validateText(text) catch |err| {
            allocator.free(text);
            return err;
        };
        const id = next_instance_id.fetchAdd(1, .monotonic);
        std.debug.assert(id != 0 and id != std.math.maxInt(u64));
        var self: Document = .{ .allocator = allocator, .buffer = try TextBuffer.initOwned(allocator, text), .instance_id = id, .crlf = std.mem.indexOf(u8, text, "\r\n") != null };
        errdefer self.deinit();
        if (path) |value| self.path = try allocator.dupeSentinel(u8, value, 0);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| if (line.len > max_line_bytes) {
            self.preview_only = true;
            break;
        };
        return self;
    }
    pub fn initLarge(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Document {
        const worker = try @import("../text/large_worker.zig").Worker.create(allocator, io, path);
        errdefer worker.destroy();
        var self = try init(allocator, "", path);
        self.large = .{ .worker = worker, .size = worker.snapshot(&.{}).file_size };
        _ = self.large.?.poll(&.{});
        self.preview_only = true;
        return self;
    }
    pub fn largeNavigate(self: *Document, offset: u64) void {
        if (self.large) |*large| {
            large.move(offset, false);
        }
    }
    fn validateText(text: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.BinaryFile;
    }
    pub fn deinit(self: *Document) void {
        if (self.large) |*large| large.worker.destroy();
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
        self.breakTypingGroup();
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
        self.breakTypingGroup();
        self.moveInternal(offset, extend);
    }
    fn moveInternal(self: *Document, offset: usize, extend: bool) void {
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
        if (self.large != null) return error.ReadOnlyLargeFile;
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
        const coalesce = typing and self.revision != self.saved_revision and self.history_index == self.history.items.len and self.history_index > 0 and blk: {
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
            if (self.history.items.len > max_history_entries) {
                self.freeEdit(self.history.items[0]);
                std.mem.copyForwards(Edit, self.history.items[0 .. self.history.items.len - 1], self.history.items[1..]);
                self.history.items.len -= 1;
                self.history_index -= 1;
            }
        }
        self.revision = self.next_revision;
        self.next_revision += 1;
        self.moveInternal(after_cursor, false);
    }
    fn breakTypingGroup(self: *Document) void {
        if (self.history_index > 0) self.history.items[self.history_index - 1].typing = false;
    }
    pub fn backspace(self: *Document) !void {
        if (self.large != null) return error.ReadOnlyLargeFile;
        const previous_anchor = self.anchor;
        errdefer self.anchor = previous_anchor;
        if (self.cursor == self.anchor and self.cursor > 0) {
            self.anchor = self.buffer.previous(self.cursor);
            if (self.buffer.byteAt(self.anchor) == '\n' and self.anchor > 0 and self.buffer.byteAt(self.anchor - 1) == '\r') self.anchor -= 1;
        }
        try self.insert("");
    }
    pub fn deleteForward(self: *Document) !void {
        if (self.large != null) return error.ReadOnlyLargeFile;
        const previous_anchor = self.anchor;
        errdefer self.anchor = previous_anchor;
        if (self.cursor == self.anchor) {
            self.anchor = self.buffer.next(self.cursor);
            if (self.cursor < self.buffer.len() and self.buffer.byteAt(self.cursor) == '\r' and self.anchor < self.buffer.len() and self.buffer.byteAt(self.anchor) == '\n') self.anchor += 1;
        }
        try self.insert("");
    }
    pub fn undo(self: *Document) !void {
        if (self.large != null) return error.ReadOnlyLargeFile;
        self.breakTypingGroup();
        if (self.history_index == 0) return;
        const edit = self.history.items[self.history_index - 1];
        self.buffer.setRoot(edit.before);
        self.history_index -= 1;
        self.cursor = @min(edit.before_cursor, self.buffer.len());
        self.anchor = @min(edit.before_anchor, self.buffer.len());
        self.revision = edit.before_revision;
    }
    pub fn redo(self: *Document) !void {
        if (self.large != null) return error.ReadOnlyLargeFile;
        if (self.history_index == self.history.items.len) return;
        const edit = self.history.items[self.history_index];
        self.buffer.setRoot(edit.after);
        self.history_index += 1;
        self.cursor = @min(edit.after_cursor, self.buffer.len());
        self.anchor = @min(edit.after_anchor, self.buffer.len());
        self.revision = edit.after_revision;
        self.breakTypingGroup();
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

test "owned document initialization retains the original allocation" {
    const bytes = try std.testing.allocator.dupe(u8, "one\r\ntwo");
    var document = try Document.initOwned(std.testing.allocator, bytes, "file");
    defer document.deinit();
    try std.testing.expectEqual(bytes.ptr, document.buffer.tree.store.original.memory.ptr);
    try std.testing.expect(document.crlf);
    try expectText(&document, "one\r\ntwo");
    try std.testing.expectEqual(@as(usize, 2), document.lineCount());
    try document.insert("prefix");
    try document.undo();
    try expectText(&document, "one\r\ntwo");
}

fn ownedInitializationScenario(allocator: std.mem.Allocator) !void {
    var document = try Document.initOwned(allocator, try allocator.dupe(u8, "hello\nworld"), "owned.txt");
    defer document.deinit();
}

test "owned document initialization releases transferred text on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownedInitializationScenario, .{});
    try std.testing.expectError(error.InvalidUtf8, Document.initOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "\xff"), null));
    try std.testing.expectError(error.BinaryFile, Document.initOwned(std.testing.allocator, try std.testing.allocator.dupe(u8, "a\x00b"), null));
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

test "saving and cursor navigation separate typing groups" {
    var document = try Document.init(std.testing.allocator, "", null);
    defer document.deinit();
    try document.insert("a");
    document.saved_revision = document.revision;
    try document.insert("b");
    try document.undo();
    try expectText(&document, "a");
    try std.testing.expect(!document.dirty());
    try document.redo();
    document.move(0, false);
    document.move(2, false);
    try document.insert("c");
    try document.undo();
    try expectText(&document, "ab");
    try document.insert("d");
    try document.undo();
    try expectText(&document, "ab");
}

test "history eviction retains a valid undo floor and supports branching" {
    var document = try Document.init(std.testing.allocator, "", null);
    defer document.deinit();
    for (0..Document.max_history_entries + 5) |_| try document.replaceRange(document.buffer.len(), document.buffer.len(), "x");
    try std.testing.expectEqual(Document.max_history_entries, document.history.items.len);
    for (0..Document.max_history_entries + 1) |_| try document.undo();
    try expectText(&document, "xxxxx");
    try std.testing.expectEqual(@as(usize, 0), document.history_index);
    try document.redo();
    try expectText(&document, "xxxxxx");
    try document.insert("y");
    try document.redo();
    try expectText(&document, "xxxxxxy");
    try document.undo();
    try expectText(&document, "xxxxxx");
}

test "large state queues relative movements and resolves boundaries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines", .data = "a\nb\nc\nd\n" });
    const worker = try @import("../text/large_worker.zig").Worker.createIn(std.testing.allocator, io, tmp.dir, "lines");
    defer worker.destroy();
    var state: Document.LargeState = .{ .worker = worker, .size = 8 };
    _ = state.poll(&.{});
    try state.moveLines(1);
    try state.moveLines(2);
    worker.waitForRequest(state.generation);
    _ = state.poll(&.{});
    worker.waitForRequest(state.generation);
    _ = state.poll(&.{});
    try std.testing.expectEqual(@as(u64, 6), state.offset);
    try state.moveLines(-1);
    worker.waitForRequest(state.generation);
    _ = state.poll(&.{});
    try std.testing.expectEqual(@as(u64, 4), state.offset);
    try state.moveBoundary(.end, false);
    worker.waitForRequest(state.generation);
    _ = state.poll(&.{});
    try std.testing.expectEqual(@as(u64, 5), state.offset);
}

test "large byte selection survives window and boundary completion and invalidates copy" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "selection", .data = "abc\ndef\n" });
    const worker = try @import("../text/large_worker.zig").Worker.createIn(std.testing.allocator, io, tmp.dir, "selection");
    defer worker.destroy();
    var state: Document.LargeState = .{ .worker = worker, .size = 8 };
    state.move(2, false);
    state.move(3, true);
    worker.waitForRequest(state.generation);
    _ = state.poll(&.{});
    try std.testing.expectEqual(@as(u64, 2), state.selection().start);
    try std.testing.expectEqual(@as(u64, 3), state.selection().end);
    try state.moveBoundary(.end, true);
    worker.waitForRequest(state.generation);
    _ = state.poll(&.{});
    try std.testing.expectEqual(@as(u64, 2), state.anchor);
    try state.copy();
    try std.testing.expect(state.expected_copy != null);
    state.move(0, false);
    try std.testing.expect(state.expected_copy == null);
    try std.testing.expectEqual(@as(u64, 0), state.anchor);
    try std.testing.expectEqual(@as(u64, 0), state.offset);
}

test "restoring large selection supersedes preview and survives publication" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "restore", .data = "first\nsecond\n" });
    const worker = try @import("../text/large_worker.zig").Worker.createIn(std.testing.allocator, io, tmp.dir, "restore");
    defer worker.destroy();
    var state: Document.LargeState = .{ .worker = worker, .size = 13 };
    state.move(4, true);
    state.requestLine(1);
    state.restoreSelection(1, 4);
    worker.waitForRequest(state.generation);
    _ = state.poll(&.{});
    try std.testing.expectEqual(@as(u64, 1), state.anchor);
    try std.testing.expectEqual(@as(u64, 4), state.offset);
}

test "large navigation composes mixed intentions and preserves viewport for select all" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "mixed", .data = "abc\nde\nfghi\n" });
    const worker = try @import("../text/large_worker.zig").Worker.createIn(std.testing.allocator, io, tmp.dir, "mixed");
    defer worker.destroy();
    var state: Document.LargeState = .{ .worker = worker, .size = 12 };
    _ = state.poll(&.{});
    try state.moveLines(1);
    try state.moveBoundary(.end, false);
    while (state.line_pending) {
        worker.waitForRequest(state.generation);
        _ = state.poll(&.{});
    }
    try std.testing.expectEqual(@as(u64, 6), state.offset);
    state.move(0, false);
    try state.moveBoundary(.end, false);
    try state.moveLines(1);
    while (state.line_pending) {
        worker.waitForRequest(state.generation);
        _ = state.poll(&.{});
    }
    try std.testing.expectEqual(@as(u64, 4), state.offset);
    try state.moveBoundary(.end, true);
    try state.moveByte(-1, true);
    try state.selectLines(-1);
    try state.moveBoundary(.end, true);
    while (state.line_pending) {
        worker.waitForRequest(state.generation);
        _ = state.poll(&.{});
    }
    try std.testing.expectEqual(@as(u64, 4), state.anchor);
    try std.testing.expectEqual(@as(u64, 3), state.offset);
    state.move(0, false);
    worker.waitForRequest(state.generation);
    try state.moveByte(1, true);
    worker.waitForRequest(state.generation);
    var bytes: [32]u8 = undefined;
    var snap = state.poll(&bytes);
    try std.testing.expectEqual(@as(u64, 0), snap.offset);
    try std.testing.expectEqual(@as(u64, 1), state.offset);
    try std.testing.expectEqual(@as(u8, 'a'), bytes[0]);
    state.selectAll();
    worker.waitForRequest(state.generation);
    snap = state.poll(&bytes);
    try std.testing.expectEqual(@as(u64, 0), snap.offset);
    try std.testing.expectEqual(@as(u64, 12), state.offset);
    try std.testing.expect(snap.len > 0);
}
