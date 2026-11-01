//! Read-only, byte-oriented positional access and incremental newline indexing.
//! No UTF-8 validation or binary detection is performed: LF bytes alone delimit
//! lines, CR remains content, and invalid UTF-8, NULs and arbitrarily long lines
//! are accessible as bytes. Consumers must decode and render bounded windows.
//!
//! The borrowed directory must remain open and its resolution context stable for
//! this object's lifetime. The object is not thread-safe. Identity checks detect
//! ordinary changes/replacements, not adversarial changes that restore metadata,
//! nor races occurring between checks. Never treat this as an immutable snapshot.
const std = @import("std");
const scan = @import("scan.zig");

pub const chunk_size: usize = 64 * 1024;
pub const max_window: usize = chunk_size;

const Identity = struct {
    size: u64,
    mtime: std.Io.Timestamp,
    inode: std.Io.File.INode,
    fn from(s: std.Io.File.Stat) Identity {
        return .{ .size = s.size, .mtime = s.mtime, .inode = s.inode };
    }
    fn eql(a: Identity, b: Identity) bool {
        return a.size == b.size and a.inode == b.inode and std.meta.eql(a.mtime, b.mtime);
    }
};

pub const LargeFile = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    path: []u8,
    file: std.Io.File,
    identity: Identity,
    // Cumulative LF counts at the end of each complete chunk.
    chunks: std.ArrayList(u64) = .empty,
    indexed_bytes: u64 = 0,
    newline_count: u64 = 0,
    stale: bool = false,

    /// Opens a regular file; owns the file and a copy of path, borrows dir.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !LargeFile {
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.NotRegularFile;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        var self: LargeFile = .{ .allocator = allocator, .dir = dir, .path = owned_path, .file = file, .identity = Identity.from(stat) };
        try self.validate(io);
        return self;
    }

    pub fn deinit(self: *LargeFile, io: std.Io) void {
        self.file.close(io);
        self.allocator.free(self.path);
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn size(self: *const LargeFile) u64 {
        return self.identity.size;
    }
    pub fn indexedBytes(self: *const LargeFile) u64 {
        return self.indexed_bytes;
    }
    pub fn indexedNewlines(self: *const LargeFile) u64 {
        return self.newline_count;
    }
    pub fn complete(self: *const LargeFile) bool {
        return self.indexed_bytes == self.identity.size;
    }

    /// A mismatch permanently invalidates this object. Other stat errors propagate.
    pub fn validate(self: *LargeFile, io: std.Io) !void {
        if (self.stale) return error.FileChanged;
        const handle_stat = try self.file.stat(io);
        const path_stat = self.dir.statFile(io, self.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.stale = true;
                return error.FileChanged;
            },
            else => return err,
        };
        if (!self.identity.eql(Identity.from(handle_stat)) or !self.identity.eql(Identity.from(path_stat))) {
            self.stale = true;
            return error.FileChanged;
        }
    }

    /// Reads up to out.len bytes at offset; caller supplies at most max_window.
    /// Offset at EOF returns zero; offset beyond EOF is an error. Output is only
    /// valid on success, including after a post-read identity check.
    pub fn readWindow(self: *LargeFile, io: std.Io, offset: u64, out: []u8) !usize {
        if (out.len > max_window) return error.WindowTooLarge;
        if (offset > self.size()) return error.OutOfRange;
        try self.validate(io);
        const n: usize = @intCast(@min(@as(u64, @intCast(out.len)), self.size() - offset));
        const got = try self.file.readPositionalAll(io, out[0..n], offset);
        if (got != n) {
            self.stale = true;
            return error.FileChanged;
        }
        try self.validate(io);
        return n;
    }

    /// Index at most budget bytes, returning bytes actually indexed. A zero
    /// budget does no I/O. Progress is committed only after a validated read.
    /// Metadata uses one u64 per complete 64 KiB chunk, plus allocator overhead.
    pub fn indexStep(self: *LargeFile, io: std.Io, budget: usize) !usize {
        var buf: [chunk_size]u8 = undefined;
        var done: usize = 0;
        while (done < budget and !self.complete()) {
            const within: usize = @intCast(self.indexed_bytes % chunk_size);
            const n: usize = @intCast(@min(@as(u64, @intCast(@min(budget - done, chunk_size - within))), self.size() - self.indexed_bytes));
            // Reserve before reading so allocation failure cannot partially commit a chunk.
            if (within + n == chunk_size) try self.chunks.ensureUnusedCapacity(self.allocator, 1);
            _ = try self.readWindow(io, self.indexed_bytes, buf[0..n]);
            const count: u64 = scan.countNewlines(buf[0..n]);
            self.newline_count += count;
            self.indexed_bytes += n;
            done += n;
            if (within + n == chunk_size) self.chunks.appendAssumeCapacity(self.newline_count);
        }
        return done;
    }

    /// Number of LF bytes before an offset within the indexed prefix.
    pub fn lineOf(self: *LargeFile, io: std.Io, offset: u64) !u64 {
        if (offset > self.indexed_bytes) return error.IndexIncomplete;
        const chunk: usize = @intCast(offset / chunk_size);
        const count: u64 = if (chunk == 0) 0 else self.chunks.items[chunk - 1];
        const within: usize = @intCast(offset % chunk_size);
        var buf: [chunk_size]u8 = undefined;
        _ = try self.readWindow(io, offset - within, buf[0..within]);
        var result = count;
        for (buf[0..within]) |byte| if (byte == '\n') {
            result += 1;
        };
        return result;
    }

    /// Zero-based line start offset. Line 0 exists even for an empty file; a
    /// trailing LF creates an empty last line. A line whose start is beyond the
    /// indexed prefix returns IndexIncomplete, or LineOutOfRange at EOF.
    /// Lookup rereads at most one chunk and can fail on I/O or stale identity.
    pub fn lineStart(self: *LargeFile, io: std.Io, line: u64) !u64 {
        try self.validate(io);
        if (line == 0) return 0;
        if (line > self.newline_count) return if (self.complete()) error.LineOutOfRange else error.IndexIncomplete;
        var lo: usize = 0;
        var hi = self.chunks.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.chunks.items[mid] < line) lo = mid + 1 else hi = mid;
        }
        const before: u64 = if (lo == 0) 0 else self.chunks.items[lo - 1];
        const offset = @as(u64, @intCast(lo)) * chunk_size;
        const n: usize = @intCast(@min(@as(u64, chunk_size), self.indexed_bytes - offset));
        var buf: [chunk_size]u8 = undefined;
        _ = try self.readWindow(io, offset, buf[0..n]);
        var count = before;
        for (buf[0..n], 0..) |b, i| {
            if (b == '\n') {
                count += 1;
                if (count == line) return offset + i + 1;
            }
        }
        return error.IndexCorrupt;
    }
};

test "budgeted indexing, chunk boundary and trailing newline" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try std.testing.allocator.alloc(u8, chunk_size + 3);
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    data[chunk_size - 1] = '\n';
    data[chunk_size] = '\n';
    data[chunk_size + 2] = '\n';
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = data });
    var f = try LargeFile.open(std.testing.allocator, io, tmp.dir, "file");
    defer f.deinit(io);
    try std.testing.expectEqual(@as(usize, chunk_size - 1), try f.indexStep(io, chunk_size - 1));
    try std.testing.expectError(error.IndexIncomplete, f.lineStart(io, 1));
    try std.testing.expectEqual(@as(usize, 2), try f.indexStep(io, 2));
    try std.testing.expectEqual(@as(u64, chunk_size), try f.lineStart(io, 1));
    try std.testing.expectEqual(@as(u64, chunk_size + 1), try f.lineStart(io, 2));
    try std.testing.expectEqual(@as(u64, 2), try f.lineOf(io, chunk_size + 1));
    try std.testing.expectError(error.IndexIncomplete, f.lineOf(io, chunk_size + 2));
    try std.testing.expectError(error.IndexIncomplete, f.lineStart(io, 3));
    _ = try f.indexStep(io, 100);
    try std.testing.expectEqual(@as(u64, chunk_size + 3), try f.lineStart(io, 3));
    try std.testing.expectError(error.LineOutOfRange, f.lineStart(io, 4));
}

test "empty and binary bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    var f = try LargeFile.open(std.testing.allocator, io, tmp.dir, "empty");
    defer f.deinit(io);
    try std.testing.expect(f.complete());
    try std.testing.expectEqual(@as(u64, 0), try f.lineStart(io, 0));
    try std.testing.expectError(error.LineOutOfRange, f.lineStart(io, 1));
    try tmp.dir.writeFile(io, .{ .sub_path = "binary", .data = "\xff\x00\n" });
    var b = try LargeFile.open(std.testing.allocator, io, tmp.dir, "binary");
    defer b.deinit(io);
    _ = try b.indexStep(io, 3);
    try std.testing.expectEqual(@as(u64, 3), try b.lineStart(io, 1));
}

test "changed truncated and replaced files are stale" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "hello" });
    var f = try LargeFile.open(std.testing.allocator, io, tmp.dir, "file");
    defer f.deinit(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "changed" });
    var buf: [5]u8 = undefined;
    try std.testing.expectError(error.FileChanged, f.readWindow(io, 0, &buf));
    try std.testing.expectError(error.FileChanged, f.lineStart(io, 0));
    var t = try LargeFile.open(std.testing.allocator, io, tmp.dir, "file");
    defer t.deinit(io);
    const w = try tmp.dir.openFile(io, "file", .{ .mode = .write_only });
    try w.setLength(io, 1);
    w.close(io);
    try std.testing.expectError(error.FileChanged, t.indexStep(io, 10));
    var r = try LargeFile.open(std.testing.allocator, io, tmp.dir, "file");
    defer r.deinit(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "replacement", .data = "x" });
    try tmp.dir.rename("replacement", tmp.dir, "file", io);
    try std.testing.expectError(error.FileChanged, r.readWindow(io, 0, &buf));
}

test "sparse multi GiB window and long line use bounded memory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmp.dir.createFile(io, "huge", .{});
    const end: u64 = 5 * 1024 * 1024 * 1024;
    try w.writePositionalAll(io, "end\n", end);
    w.close(io);
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var f = try LargeFile.open(fixed.allocator(), io, tmp.dir, "huge");
    defer f.deinit(io);
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try f.readWindow(io, end, &out));
    try std.testing.expectEqualStrings("end\n", &out);
    try std.testing.expectEqual(@as(usize, chunk_size * 2 + 9), try f.indexStep(io, chunk_size * 2 + 9));
    try std.testing.expectEqual(@as(u64, 0), f.indexedNewlines());
    try std.testing.expectError(error.IndexIncomplete, f.lineStart(io, 1));
    try std.testing.expect(fixed.end_index < storage.len);
}
