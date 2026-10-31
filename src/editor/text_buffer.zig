//! Document text storage over the persistent piece treap (`text/piece_tree.zig`).
//!
//! Exposes the byte API the editor grew up with (len, byteAt, copy, next, previous,
//! replace, toOwnedSlice) plus line queries derived from tree sums, so Document keeps no
//! per-line array. Versions are cheap: `root()` hands out a retained root that undo history
//! or a worker can hold, and `setRoot` restores one.
//!
//! This step supports memory-backed originals only, so reads cannot fail and `io` is never
//! touched. File-backed large-file mode is a separate, read-only path (ARCHITECTURE.md).
const std = @import("std");
const piece_tree = @import("../text/piece_tree.zig");
const source = @import("../text/source.zig");
const Tree = piece_tree.Tree;
const Node = piece_tree.Node;
const Piece = piece_tree.Piece;

/// Memory originals are cut into small pieces so a line lookup scans at most this much.
const memory_chunk: u32 = 4096;

pub const TextBuffer = struct {
    allocator: std.mem.Allocator,
    tree: Tree,
    state: *State,

    /// Mutable lookup state, reachable from `*const` methods.
    const State = struct {
        reader: piece_tree.Reader,
        /// Edit cursor cache: the piece found by the last lookup (JumpRope-style locality).
        cache_start: u64 = 0,
        cache: []const u8 = &.{},
    };

    /// Copies `text` into a new memory-backed original.
    pub fn init(allocator: std.mem.Allocator, text: []const u8) !TextBuffer {
        return initOwned(allocator, try allocator.dupe(u8, text));
    }

    /// Takes ownership of `owned` (allocated with `allocator`) as the original text.
    pub fn initOwned(allocator: std.mem.Allocator, owned: []u8) !TextBuffer {
        const store = source.Store.create(allocator, .{ .memory = owned }) catch |err| {
            allocator.free(owned);
            return err;
        };
        // Memory stores never use io (no file to close, every slice is direct).
        errdefer store.release(undefined);
        var pieces: std.ArrayList(Piece) = .empty;
        defer pieces.deinit(allocator);
        var offset: usize = 0;
        while (offset < owned.len) {
            const n: u32 = @intCast(@min(memory_chunk, owned.len - offset));
            try pieces.append(allocator, .{ .offset = offset, .len = n, .nl = @intCast(std.mem.countScalar(u8, owned[offset..][0..n], '\n')), .origin = .original });
            offset += n;
        }
        const tree = try Tree.fromPieces(store, pieces.items);
        errdefer piece_tree.release(allocator, tree.root);
        const state = try allocator.create(State);
        state.* = .{ .reader = piece_tree.Reader.init(store, undefined) };
        return .{ .allocator = allocator, .tree = tree, .state = state };
    }

    pub fn deinit(self: *TextBuffer) void {
        self.state.reader.deinit();
        self.allocator.destroy(self.state);
        self.tree.deinitShared(undefined);
        self.* = undefined;
    }

    pub fn len(self: *const TextBuffer) usize {
        return @intCast(self.tree.len());
    }

    fn invalidate(self: *TextBuffer) void {
        self.state.cache = &.{};
    }

    /// Bytes of the piece containing `offset` and that piece's start offset.
    fn chunkAt(self: *const TextBuffer, offset: usize) struct { start: usize, bytes: []const u8 } {
        const st = self.state;
        if (offset >= st.cache_start and offset < st.cache_start + st.cache.len) return .{ .start = @intCast(st.cache_start), .bytes = st.cache };
        const loc = self.tree.pieceAt(offset).?;
        const bytes = st.reader.bytes(loc.piece) catch unreachable; // memory-backed: infallible
        st.cache_start = loc.start;
        st.cache = bytes;
        return .{ .start = @intCast(loc.start), .bytes = bytes };
    }

    pub fn byteAt(self: *const TextBuffer, offset: usize) u8 {
        std.debug.assert(offset < self.len());
        const chunk = self.chunkAt(offset);
        return chunk.bytes[offset - chunk.start];
    }

    pub fn copy(self: *const TextBuffer, start: usize, out: []u8) void {
        var written: usize = 0;
        while (written < out.len) {
            const chunk = self.chunkAt(start + written);
            const from = start + written - chunk.start;
            const n = @min(chunk.bytes.len - from, out.len - written);
            @memcpy(out[written..][0..n], chunk.bytes[from..][0..n]);
            written += n;
        }
    }

    pub fn toOwnedSlice(self: *const TextBuffer, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.len());
        self.copy(0, out);
        return out;
    }

    /// Replaces [start, end) with `text`; failure leaves the text unchanged.
    pub fn replace(self: *TextBuffer, start: usize, end: usize, text: []const u8) !void {
        std.debug.assert(start <= end and end <= self.len());
        self.invalidate();
        if (start == end and try self.tree.extendAt(start, text)) return;
        try self.tree.replace(&self.state.reader, start, end, text);
    }

    pub fn previous(self: *const TextBuffer, offset: usize) usize {
        if (offset == 0) return 0;
        var index = offset - 1;
        while (index > 0 and self.byteAt(index) & 0xc0 == 0x80) index -= 1;
        return index;
    }

    pub fn next(self: *const TextBuffer, offset: usize) usize {
        if (offset >= self.len()) return self.len();
        var index = offset + 1;
        while (index < self.len() and self.byteAt(index) & 0xc0 == 0x80) index += 1;
        return index;
    }

    pub fn lineCount(self: *const TextBuffer) usize {
        return @intCast(self.tree.lineCount());
    }

    /// Offset of the first byte of `line`; `line` must be below `lineCount()`.
    pub fn lineStart(self: *const TextBuffer, line: usize) usize {
        std.debug.assert(line < self.lineCount());
        return @intCast((self.tree.lineStart(&self.state.reader, line) catch unreachable).?);
    }

    /// Line containing `offset` (offset <= len).
    pub fn lineOf(self: *const TextBuffer, offset: usize) usize {
        return @intCast((self.tree.lineOf(&self.state.reader, @min(offset, self.len())) catch unreachable).?);
    }

    /// A retained handle to the current version; release with `releaseRoot`.
    pub fn root(self: *const TextBuffer) ?*Node {
        return piece_tree.retain(self.tree.root);
    }
    pub fn releaseRoot(self: *const TextBuffer, node: ?*Node) void {
        piece_tree.release(self.allocator, node);
    }
    /// Restores a version previously obtained from `root()` (retains it again).
    pub fn setRoot(self: *TextBuffer, node: ?*Node) void {
        self.invalidate();
        const old = self.tree.root;
        self.tree.root = piece_tree.retain(node);
        piece_tree.release(self.allocator, old);
    }

    /// Number of pieces; exposed for fragmentation tests and diagnostics.
    pub fn pieceCount(self: *const TextBuffer) usize {
        return countNodes(self.tree.root);
    }
    fn countNodes(node: ?*Node) usize {
        const n = node orelse return 0;
        return 1 + countNodes(n.left) + countNodes(n.right);
    }
};

const testing = std.testing;

fn expectText(buffer: *const TextBuffer, expected: []const u8) !void {
    const actual = try buffer.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "text buffer agrees with a flat reference over deterministic edits" {
    var buffer = try TextBuffer.init(testing.allocator, "");
    defer buffer.deinit();
    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(testing.allocator);
    var random = std.Random.DefaultPrng.init(731);
    for (0..1000) |_| {
        const start = random.random().uintAtMost(usize, reference.items.len);
        const end = start + random.random().uintAtMost(usize, @min(8, reference.items.len - start));
        var bytes: [17]u8 = undefined;
        for (&bytes) |*b| b.* = "ab\ncd e"[random.random().uintLessThan(usize, 7)];
        const inserted = bytes[0..random.random().uintAtMost(usize, bytes.len)];
        try buffer.replace(start, end, inserted);
        try reference.replaceRange(testing.allocator, start, end - start, inserted);
    }
    try expectText(&buffer, reference.items);
    try testing.expectEqual(std.mem.countScalar(u8, reference.items, '\n') + 1, buffer.lineCount());
    var line: usize = 0;
    for (reference.items, 0..) |c, i| {
        try testing.expectEqual(line, buffer.lineOf(i));
        if (c == '\n') {
            line += 1;
            try testing.expectEqual(i + 1, buffer.lineStart(line));
        }
    }
}

test "sequential typing keeps the piece count flat" {
    const original: [10000]u8 = @splat('x');
    var buffer = try TextBuffer.init(testing.allocator, &original);
    defer buffer.deinit();
    const before = buffer.pieceCount();
    var at: usize = 5000;
    for (0..2000) |i| {
        try buffer.replace(at, at, if (i % 40 == 39) "\n" else "a");
        at += 1;
    }
    // One split of the original plus one growing add piece.
    try testing.expect(buffer.pieceCount() <= before + 2);
    try testing.expectEqual(@as(usize, 51), buffer.lineCount());
}

test "roots restore earlier versions" {
    var buffer = try TextBuffer.init(testing.allocator, "hello");
    defer buffer.deinit();
    const v0 = buffer.root();
    defer buffer.releaseRoot(v0);
    try buffer.replace(5, 5, " world");
    const v1 = buffer.root();
    defer buffer.releaseRoot(v1);
    buffer.setRoot(v0);
    try expectText(&buffer, "hello");
    buffer.setRoot(v1);
    try expectText(&buffer, "hello world");
}

test "UTF-8 navigation stays on codepoint boundaries across pieces" {
    var buffer = try TextBuffer.init(testing.allocator, "aé中");
    defer buffer.deinit();
    try buffer.replace(1, 1, "€");
    try testing.expectEqual(@as(usize, 1), buffer.previous(4));
    try testing.expectEqual(@as(usize, 4), buffer.next(1));
    try testing.expectEqual(@as(usize, 0), buffer.previous(0));
}
