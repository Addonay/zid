//! Persistent piece treap.
//!
//! Text is a sequence of pieces, each referencing up to `max_piece` bytes of the
//! original source or the add buffer. Pieces live in an immutable, reference-counted
//! treap ordered by position. Every node caches subtree byte, newline and
//! unknown-count sums, so offset<->line conversion is O(log n) plus a scan of at most
//! one piece. Edits path-copy nodes and commit a new root only after all allocations succeed.
//! Keeping an old root alive (undo history, worker snapshots) is how we keep versions.
const std = @import("std");
const source = @import("source.zig");
const scan = @import("scan.zig");
const Store = source.Store;
const Origin = source.Origin;

pub const max_piece: u32 = 64 * 1024;
pub const unknown_nl = std.math.maxInt(u32);

pub const Piece = struct {
    offset: u64,
    len: u32,
    nl: u32, // newline count, or `unknown_nl` until the indexer reaches it
    origin: Origin,
};

pub const Node = struct {
    refs: std.atomic.Value(u32),
    priority: u32,
    piece: Piece,
    left: ?*Node,
    right: ?*Node,
    bytes: u64,
    lines: u64,
    unknown: u32,

    fn update(self: *Node) void {
        self.bytes = self.piece.len;
        self.unknown = @intFromBool(self.piece.nl == unknown_nl);
        self.lines = if (self.piece.nl == unknown_nl) 0 else self.piece.nl;
        inline for (.{ self.left, self.right }) |child| if (child) |c| {
            self.bytes += c.bytes;
            self.lines += c.lines;
            self.unknown += c.unknown;
        };
    }
};

fn bytesOf(node: ?*Node) u64 {
    return if (node) |n| n.bytes else 0;
}
fn linesOf(node: ?*Node) u64 {
    return if (node) |n| n.lines else 0;
}
fn unknownOf(node: ?*Node) u32 {
    return if (node) |n| n.unknown else 0;
}

pub fn retain(node: ?*Node) ?*Node {
    if (node) |n| _ = n.refs.fetchAdd(1, .monotonic);
    return node;
}

/// Iterative release so deep or long-lived trees never overflow the stack.
pub fn release(allocator: std.mem.Allocator, node: ?*Node) void {
    var stack: [256]*Node = undefined;
    var top: usize = 0;
    if (node) |n| {
        stack[0] = n;
        top = 1;
    }
    while (top > 0) {
        top -= 1;
        const n = stack[top];
        if (n.refs.fetchSub(1, .acq_rel) != 1) continue;
        inline for (.{ n.left, n.right }) |child| if (child) |c| {
            if (top < stack.len) {
                stack[top] = c;
                top += 1;
            } else release(allocator, c); // pathological depth: recurse
        };
        allocator.destroy(n);
    }
}

/// Byte access for scanning pieces. Memory and add-buffer pieces are direct;
/// file-backed originals go through a small per-reader cache (bounded RSS).
pub const Reader = struct {
    store: *Store,
    io: std.Io,
    slots: [slot_count]Slot = @splat(.{}),
    clock: u32 = 0,

    const slot_count = 4;
    const Slot = struct { offset: u64 = std.math.maxInt(u64), len: u32 = 0, stamp: u32 = 0, data: ?*[max_piece]u8 = null };

    pub fn init(store: *Store, io: std.Io) Reader {
        return .{ .store = store, .io = io };
    }
    pub fn deinit(self: *Reader) void {
        for (self.slots) |slot| if (slot.data) |d| self.store.allocator.destroy(d);
    }
    pub fn bytes(self: *Reader, piece: Piece) ![]const u8 {
        if (piece.origin == .add) return self.store.addSlice(piece.offset, piece.len);
        if (self.store.originalSlice(piece.offset, piece.len)) |direct| return direct;
        self.clock +%= 1;
        var victim: usize = 0;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.offset == piece.offset and slot.len >= piece.len and slot.data != null) {
                slot.stamp = self.clock;
                return slot.data.?[0..piece.len];
            }
            if (slot.stamp < self.slots[victim].stamp) victim = i;
        }
        const slot = &self.slots[victim];
        if (slot.data == null) slot.data = try self.store.allocator.create([max_piece]u8);
        slot.offset = std.math.maxInt(u64);
        try self.store.readOriginal(self.io, piece.offset, slot.data.?[0..piece.len]);
        slot.* = .{ .offset = piece.offset, .len = piece.len, .stamp = self.clock, .data = slot.data };
        return slot.data.?[0..piece.len];
    }
};

pub const Tree = struct {
    store: *Store,
    root: ?*Node = null,

    fn allocator(self: *const Tree) std.mem.Allocator {
        return self.store.allocator;
    }
    pub fn len(self: *const Tree) u64 {
        return bytesOf(self.root);
    }
    /// Number of '\n' bytes in the indexed portion of the text.
    pub fn newlines(self: *const Tree) u64 {
        return linesOf(self.root);
    }
    pub fn indexed(self: *const Tree) bool {
        return unknownOf(self.root) == 0;
    }
    pub fn lineCount(self: *const Tree) u64 {
        return self.newlines() + 1;
    }

    /// A second handle to the same version. Release with `deinitShared`.
    pub fn share(self: *const Tree) Tree {
        return .{ .store = self.store.retain(), .root = retain(self.root) };
    }
    pub fn deinitShared(self: *Tree, io: std.Io) void {
        release(self.allocator(), self.root);
        self.store.release(io);
        self.* = undefined;
    }

    fn newNode(self: *Tree, piece: Piece, priority: u32, left: ?*Node, right: ?*Node) !*Node {
        const n = try self.allocator().create(Node);
        n.* = .{ .refs = .init(1), .priority = priority, .piece = piece, .left = left, .right = right, .bytes = 0, .lines = 0, .unknown = 0 };
        n.update();
        return n;
    }

    /// Consumes both inputs on success and failure.
    fn merge(self: *Tree, a: ?*Node, b: ?*Node) !?*Node {
        const x = a orelse return b;
        const y = b orelse return a;
        defer release(self.allocator(), x);
        defer release(self.allocator(), y);
        if (x.priority >= y.priority) {
            const merged = try self.merge(retain(x.right), retain(y));
            errdefer release(self.allocator(), merged);
            const node = try self.newNode(x.piece, x.priority, null, merged);
            node.left = retain(x.left);
            node.update();
            return node;
        } else {
            const merged = try self.merge(retain(x), retain(y.left));
            errdefer release(self.allocator(), merged);
            const node = try self.newNode(y.piece, y.priority, merged, null);
            node.right = retain(y.right);
            node.update();
            return node;
        }
    }

    /// Consumes the input on success and failure.
    fn split(self: *Tree, node: ?*Node, at: u64, reader: *Reader) !struct { ?*Node, ?*Node } {
        const n = node orelse return .{ null, null };
        defer release(self.allocator(), n);
        const lb = bytesOf(n.left);
        if (at <= lb) {
            const a, const b = try self.split(retain(n.left), at, reader);
            errdefer release(self.allocator(), a);
            errdefer release(self.allocator(), b);
            const right = try self.newNode(n.piece, n.priority, b, null);
            right.right = retain(n.right);
            right.update();
            return .{ a, right };
        }
        if (at >= lb + n.piece.len) {
            const a, const b = try self.split(retain(n.right), at - lb - n.piece.len, reader);
            errdefer release(self.allocator(), a);
            errdefer release(self.allocator(), b);
            const left = try self.newNode(n.piece, n.priority, null, a);
            left.left = retain(n.left);
            left.update();
            return .{ left, b };
        }
        const cut: u32 = @intCast(at - lb);
        var first = n.piece;
        var second = n.piece;
        first.len = cut;
        second.offset += cut;
        second.len -= cut;
        if (n.piece.nl != unknown_nl) {
            first.nl = @intCast(scan.countNewlines(try reader.bytes(first)));
            second.nl = n.piece.nl - first.nl;
        }
        const left = try self.newNode(first, n.priority, null, null);
        errdefer release(self.allocator(), left);
        const right = try self.newNode(second, n.priority, null, null);
        left.left = retain(n.left);
        left.update();
        right.right = retain(n.right);
        right.update();
        return .{ left, right };
    }

    /// Builds a treap from pieces in O(n) (Cartesian tree on random priorities).
    pub fn fromPieces(store: *Store, pieces: []const Piece) !Tree {
        var tree: Tree = .{ .store = store };
        var stack: std.ArrayList(*Node) = .empty;
        defer stack.deinit(store.allocator);
        errdefer {
            if (stack.items.len > 0) release(store.allocator, stack.items[0]);
        }
        for (pieces) |piece| {
            if (piece.len == 0) continue;
            try stack.ensureUnusedCapacity(store.allocator, 1);
            const node = try tree.newNode(piece, store.prng.random().int(u32), null, null);
            var last: ?*Node = null;
            while (stack.items.len > 0 and stack.items[stack.items.len - 1].priority < node.priority) {
                last = stack.pop();
            }
            node.left = last;
            if (stack.items.len > 0) stack.items[stack.items.len - 1].right = node;
            stack.appendAssumeCapacity(node);
        }
        // Fix sums bottom-up: post-order over the finished tree.
        if (stack.items.len > 0) {
            fixSums(stack.items[0]);
            tree.root = stack.items[0];
        }
        return tree;
    }
    fn fixSums(node: *Node) void {
        if (node.left) |l| fixSums(l);
        if (node.right) |r| fixSums(r);
        node.update();
    }

    /// Replaces [start, end) with `text`. Appends to the store's add buffer.
    pub fn replace(self: *Tree, reader: *Reader, start: u64, end: u64, text: []const u8) !void {
        std.debug.assert(start <= end and end <= self.len());
        const gpa = self.allocator();
        // Build the inserted pieces first so failure leaves the tree untouched.
        var inserted: ?*Node = null;
        errdefer release(gpa, inserted);
        if (text.len > 0) {
            var ranges: std.ArrayList(source.Range) = .empty;
            defer ranges.deinit(gpa);
            try self.store.append(text, &ranges, gpa);
            var pieces: std.ArrayList(Piece) = .empty;
            defer pieces.deinit(gpa);
            for (ranges.items) |range| {
                var off: u32 = 0;
                while (off < range.len) {
                    const n = @min(max_piece, range.len - off);
                    const bytes = self.store.addSlice(range.offset + off, n);
                    try pieces.append(gpa, .{ .offset = range.offset + off, .len = n, .nl = @intCast(scan.countNewlines(bytes)), .origin = .add });
                    off += n;
                }
            }
            var built = try fromPieces(self.store, pieces.items);
            inserted = built.root;
            built.root = null;
        }
        const a, const rest = try self.split(retain(self.root), start, reader);
        const removed, const b = self.split(rest, end - start, reader) catch |err| {
            release(gpa, a);
            return err;
        };
        release(gpa, removed);
        const ins = inserted;
        inserted = null;
        const left = self.merge(a, ins) catch |err| {
            release(gpa, b);
            return err;
        };
        const root = try self.merge(left, b);
        release(gpa, self.root);
        self.root = root;
    }

    pub const Located = struct { piece: Piece, start: u64 };

    /// The piece containing `offset` (offset < len), with its starting offset.
    pub fn pieceAt(self: *const Tree, offset: u64) ?Located {
        var node = self.root;
        var base: u64 = 0;
        var off = offset;
        while (node) |n| {
            const lb = bytesOf(n.left);
            if (off < lb) {
                node = n.left;
            } else if (off < lb + n.piece.len) {
                return .{ .piece = n.piece, .start = base + lb };
            } else {
                off -= lb + n.piece.len;
                base += lb + n.piece.len;
                node = n.right;
            }
        }
        return null;
    }

    /// Offset of the first byte of `line` (0-based). Requires the prefix to be indexed;
    /// returns null when the line lies beyond the known index or the text.
    pub fn lineStart(self: *const Tree, reader: *Reader, line: u64) !?u64 {
        if (line == 0) return 0;
        var k = line; // we want the position just after the k-th newline
        var node = self.root;
        var base: u64 = 0;
        while (node) |n| {
            const left_lines = linesOf(n.left);
            if (unknownOf(n.left) == 0 and k <= left_lines) {
                node = n.left;
                continue;
            }
            if (unknownOf(n.left) != 0) return null;
            k -= left_lines;
            base += bytesOf(n.left);
            if (n.piece.nl == unknown_nl) return null;
            if (k <= n.piece.nl) {
                const bytes = try reader.bytes(n.piece);
                return base + (scan.nthNewline(bytes, @intCast(k - 1)).?) + 1;
            }
            k -= n.piece.nl;
            base += n.piece.len;
            node = n.right;
        }
        return null;
    }

    /// Line index (0-based) containing `offset`, or null if an unindexed piece precedes it.
    pub fn lineOf(self: *const Tree, reader: *Reader, offset: u64) !?u64 {
        if (offset > self.len()) return null;
        var node = self.root;
        var count: u64 = 0;
        var off = offset;
        while (node) |n| {
            const lb = bytesOf(n.left);
            if (off < lb) {
                node = n.left;
                continue;
            }
            if (unknownOf(n.left) != 0) return null;
            count += linesOf(n.left);
            off -= lb;
            if (off < n.piece.len) {
                const bytes = try reader.bytes(n.piece);
                return count + scan.countNewlines(bytes[0..@intCast(off)]);
            }
            if (n.piece.nl == unknown_nl) return null;
            count += n.piece.nl;
            off -= n.piece.len;
            node = n.right;
        }
        return count;
    }

    /// Copies [start, start+out.len) into `out`.
    pub fn read(self: *const Tree, reader: *Reader, start: u64, out: []u8) !void {
        if (start > self.len() or out.len > self.len() - start) return error.OutOfBounds;
        var at = start;
        var written: usize = 0;
        while (written < out.len) {
            const loc = self.pieceAt(at) orelse return error.OutOfBounds;
            const bytes = try reader.bytes(loc.piece);
            const from: usize = @intCast(at - loc.start);
            const n = @min(bytes.len - from, out.len - written);
            @memcpy(out[written..][0..n], bytes[from..][0..n]);
            written += n;
            at += n;
        }
    }

    pub fn byteAt(self: *const Tree, reader: *Reader, offset: u64) !u8 {
        const loc = self.pieceAt(offset) orelse return error.OutOfBounds;
        return (try reader.bytes(loc.piece))[@intCast(offset - loc.start)];
    }

    /// In-order pieces (for saving, rebuilding, and tests).
    pub fn collect(self: *const Tree, gpa: std.mem.Allocator, out: *std.ArrayList(Piece)) !void {
        try collectNode(self.root, gpa, out);
    }
    fn collectNode(node: ?*Node, gpa: std.mem.Allocator, out: *std.ArrayList(Piece)) !void {
        const n = node orelse return;
        try collectNode(n.left, gpa, out);
        try out.append(gpa, n.piece);
        try collectNode(n.right, gpa, out);
    }

    /// Fills unknown newline counts for original pieces aligned to `max_piece` chunks.
    /// `counts[i]` is the count for chunk i, or `unknown_nl` if not yet computed.
    pub fn applyIndex(self: *Tree, gpa: std.mem.Allocator, counts: []const u32) !void {
        if (self.indexed()) return;
        var pieces: std.ArrayList(Piece) = .empty;
        defer pieces.deinit(gpa);
        try self.collect(gpa, &pieces);
        for (pieces.items) |*p| {
            if (p.nl != unknown_nl or p.origin != .original) continue;
            const chunk: usize = @intCast(p.offset / max_piece);
            if (p.offset % max_piece == 0 and chunk < counts.len and p.len == chunkLen(self.store.originalLen(), chunk)) p.nl = counts[chunk];
        }
        const rebuilt = try fromPieces(self.store, pieces.items);
        release(self.allocator(), self.root);
        self.root = rebuilt.root;
    }
};

pub fn chunkLen(total: u64, chunk: usize) u32 {
    if (chunk >= total / max_piece + @intFromBool(total % max_piece != 0)) return 0;
    const start = @as(u64, chunk) * max_piece;
    return @intCast(@min(max_piece, total - start));
}

/// Pieces covering the whole original source in `max_piece` chunks.
pub fn originalPieces(gpa: std.mem.Allocator, total: u64, counts: ?[]const u32) ![]Piece {
    const n: usize = @intCast(total / max_piece + @intFromBool(total % max_piece != 0));
    if (counts) |c| if (c.len < n) return error.InvalidCounts;
    const pieces = try gpa.alloc(Piece, n);
    for (pieces, 0..) |*p, i| p.* = .{
        .offset = @as(u64, i) * max_piece,
        .len = chunkLen(total, i),
        .nl = if (counts) |c| c[i] else unknown_nl,
        .origin = .original,
    };
    return pieces;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn memoryTree(text: []const u8) !Tree {
    const owned = try testing.allocator.dupe(u8, text);
    const store = Store.create(testing.allocator, .{ .memory = owned }) catch |err| {
        testing.allocator.free(owned);
        return err;
    };
    errdefer store.release(undefined);
    const n: usize = @intCast((text.len + max_piece - 1) / max_piece);
    const counts = try testing.allocator.alloc(u32, n);
    defer testing.allocator.free(counts);
    for (counts, 0..) |*c, i| {
        const s = i * max_piece;
        c.* = @intCast(scan.countNewlines(text[s..@min(text.len, s + max_piece)]));
    }
    const pieces = try originalPieces(testing.allocator, text.len, counts);
    defer testing.allocator.free(pieces);
    return Tree.fromPieces(store, pieces);
}

fn expectTree(tree: *const Tree, reader: *Reader, expected: []const u8) !void {
    try testing.expectEqual(@as(u64, expected.len), tree.len());
    const out = try testing.allocator.alloc(u8, expected.len);
    defer testing.allocator.free(out);
    try tree.read(reader, 0, out);
    try testing.expectEqualStrings(expected, out);
    try testing.expectEqual(@as(u64, scan.countNewlines(expected)), tree.newlines());
}

test "random edits agree with a flat reference, and old versions survive" {
    var tree = try memoryTree("hello\nworld\n");
    defer tree.deinitShared(undefined);
    var reader = Reader.init(tree.store, undefined);
    defer reader.deinit();
    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(testing.allocator);
    try reference.appendSlice(testing.allocator, "hello\nworld\n");

    var versions: std.ArrayList(struct { tree: Tree, text: []u8 }) = .empty;
    defer {
        for (versions.items) |*v| {
            v.tree.deinitShared(undefined);
            testing.allocator.free(v.text);
        }
        versions.deinit(testing.allocator);
    }
    var prng = std.Random.DefaultPrng.init(99);
    const r = prng.random();
    for (0..1500) |i| {
        const start = r.uintAtMost(usize, reference.items.len);
        const end = start + r.uintAtMost(usize, @min(40, reference.items.len - start));
        var buf: [24]u8 = undefined;
        for (&buf) |*b| b.* = if (r.uintLessThan(u8, 5) == 0) '\n' else 'a' + r.uintLessThan(u8, 26);
        const ins = buf[0..r.uintAtMost(usize, buf.len)];
        try tree.replace(&reader, start, end, ins);
        try reference.replaceRange(testing.allocator, start, end - start, ins);
        if (i % 100 == 0) try versions.append(testing.allocator, .{ .tree = tree.share(), .text = try testing.allocator.dupe(u8, reference.items) });
    }
    try expectTree(&tree, &reader, reference.items);
    for (versions.items) |*v| try expectTree(&v.tree, &reader, v.text);

    // line lookups agree with a scan
    var line: u64 = 0;
    for (reference.items, 0..) |c, off| {
        try testing.expectEqual(@as(?u64, line), try tree.lineOf(&reader, off));
        if (c == '\n') {
            line += 1;
            try testing.expectEqual(@as(?u64, off + 1), try tree.lineStart(&reader, line));
        }
    }
    try testing.expectEqual(@as(?u64, null), try tree.lineStart(&reader, line + 1));
}

test "large inserts split into bounded pieces" {
    var tree = try memoryTree("");
    defer tree.deinitShared(undefined);
    var reader = Reader.init(tree.store, undefined);
    defer reader.deinit();
    const big = try testing.allocator.alloc(u8, 3 * max_piece + 17);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = if (i % 80 == 79) '\n' else 'x';
    try tree.replace(&reader, 0, 0, big);
    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(testing.allocator);
    try tree.collect(testing.allocator, &pieces);
    for (pieces.items) |p| try testing.expect(p.len <= max_piece);
    try expectTree(&tree, &reader, big);
    try testing.expectEqual(@as(?u64, 80 * 10), try tree.lineStart(&reader, 10));
}

test "unknown index: byte access works, line lookups degrade, applyIndex completes" {
    const text = try testing.allocator.alloc(u8, 5 * max_piece);
    for (text, 0..) |*b, i| b.* = if (i % 100 == 99) '\n' else 'z';
    const store = try Store.create(testing.allocator, .{ .memory = text });
    const pieces = try originalPieces(testing.allocator, text.len, null);
    defer testing.allocator.free(pieces);
    var tree = try Tree.fromPieces(store, pieces);
    defer tree.deinitShared(undefined);
    var reader = Reader.init(store, undefined);
    defer reader.deinit();
    try testing.expect(!tree.indexed());
    try testing.expectEqual(@as(u8, '\n'), try tree.byteAt(&reader, 99));
    try testing.expectEqual(@as(?u64, null), try tree.lineOf(&reader, 4 * max_piece));
    var counts: [5]u32 = undefined;
    for (&counts, 0..) |*c, i| c.* = @intCast(scan.countNewlines(text[i * max_piece ..][0..max_piece]));
    counts[4] = unknown_nl; // partial batch
    try tree.applyIndex(testing.allocator, &counts);
    try testing.expect(!tree.indexed());
    try testing.expectEqual(@as(?u64, 2000), try tree.lineOf(&reader, 200_000));
    counts[4] = @intCast(scan.countNewlines(text[4 * max_piece ..]));
    try tree.applyIndex(testing.allocator, &counts);
    try testing.expect(tree.indexed());
    try testing.expectEqual(@as(u64, text.len / 100), tree.newlines());
}

// Exercise every allocation in construction, split, merge, indexing and append.
// On OOM the current version and a retained snapshot must remain readable.
fn allocationScenario(gpa: std.mem.Allocator) !void {
    const owned = try gpa.dupe(u8, "alpha\nbeta\ngamma");
    const store = Store.create(gpa, .{ .memory = owned }) catch |err| {
        gpa.free(owned);
        return err;
    };
    var tree: Tree = .{ .store = store };
    defer tree.deinitShared(undefined);
    const pieces = try originalPieces(gpa, owned.len, null);
    defer gpa.free(pieces);
    tree = try Tree.fromPieces(store, pieces);
    var reader = Reader.init(store, undefined);
    defer reader.deinit();
    var snapshot = tree.share();
    defer snapshot.deinitShared(undefined);
    tree.applyIndex(gpa, &.{2}) catch |err| {
        var out: [16]u8 = undefined;
        try tree.read(&reader, 0, &out);
        try testing.expectEqualStrings("alpha\nbeta\ngamma", &out);
        return err;
    };
    // Multiple inserted pieces exercise Cartesian construction and both merges.
    const inserted = try gpa.alloc(u8, max_piece + 7);
    defer gpa.free(inserted);
    @memset(inserted, 'x');
    tree.replace(&reader, 2, 12, inserted) catch |err| {
        try expectTree(&tree, &reader, "alpha\nbeta\ngamma");
        var old: [16]u8 = undefined;
        try snapshot.read(&reader, 0, &old);
        try testing.expectEqualStrings("alpha\nbeta\ngamma", &old);
        // A later append must not overwrite any published snapshot bytes.
        return err;
    };
    try testing.expectEqual(@as(u64, 6 + inserted.len), tree.len());
    var old: [16]u8 = undefined;
    try snapshot.read(&reader, 0, &old);
    try testing.expectEqualStrings("alpha\nbeta\ngamma", &old);
    var added_snapshot = tree.share();
    defer added_snapshot.deinitShared(undefined);
    tree.replace(&reader, 1, tree.len() - 1, "z\n") catch |err| {
        try testing.expectEqual(added_snapshot.root, tree.root);
        return err;
    };
    try testing.expectEqual(@as(u8, 'x'), try added_snapshot.byteAt(&reader, 2));
    try expectTree(&tree, &reader, "az\na");
}

test "allocation failures preserve roots and release every owned allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

test "line boundaries and snapshots after owner destruction" {
    var tree = try memoryTree("a\n\nb\n");
    var snapshot = tree.share();
    tree.deinitShared(undefined);
    defer snapshot.deinitShared(undefined);
    var reader = Reader.init(snapshot.store, undefined);
    defer reader.deinit();
    try testing.expectEqual(@as(?u64, 3), try snapshot.lineOf(&reader, snapshot.len()));
    try testing.expectEqual(@as(?u64, null), try snapshot.lineOf(&reader, snapshot.len() + 1));
    try testing.expectEqual(@as(?u64, 5), try snapshot.lineStart(&reader, 3));
    try snapshot.replace(&reader, 0, snapshot.len(), "");
    try testing.expectEqual(@as(u64, 1), snapshot.lineCount());
}

test "chunk and read bounds reject invalid ranges" {
    try testing.expectEqual(@as(u32, 0), chunkLen(0, 0));
    try testing.expectEqual(@as(u32, 0), chunkLen(1, 2));
    try testing.expectEqual(@as(u32, max_piece - 1), chunkLen(std.math.maxInt(u64), @as(u64, std.math.maxInt(u64)) / max_piece));
    try testing.expectError(error.InvalidCounts, originalPieces(testing.allocator, 1, &.{}));
    var tree = try memoryTree("abc");
    defer tree.deinitShared(undefined);
    var reader = Reader.init(tree.store, undefined);
    defer reader.deinit();
    var out: [2]u8 = undefined;
    try testing.expectError(error.OutOfBounds, tree.read(&reader, 2, &out));
    try testing.expectError(error.OutOfBounds, tree.read(&reader, 4, out[0..0]));
}
