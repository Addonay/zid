//! Asynchronous byte-window access to a large, read-only file.
//! All post-open file operations and the non-thread-safe index belong to one
//! worker thread. Offsets and zero-based lines count bytes and LF delimiters;
//! this does not validate UTF-8 or guarantee a Unicode boundary.
//!
//! The Io backend, allocator, and (for createIn) borrowed directory must outlive
//! the worker and support use from its thread. Calls other than destroy may be
//! made concurrently; destroy requires exclusive ownership. destroy joins: it
//! can block on an outstanding filesystem operation, which native threads cannot
//! reliably cancel. Do not call it on a latency-sensitive UI thread if the
//! filesystem might stall. Identity checks have LargeFile's documented limits.
const std = @import("std");
const large = @import("large_file.zig");

pub const max_window = large.max_window;
pub const Snapshot = struct {
    offset: u64,
    len: usize,
    /// Exact zero-based line containing offset, if the prefix was indexed when read.
    first_line: ?u64,
    indexed_bytes: u64,
    file_size: u64,
    complete: bool,
    generation: u64,
    loading: bool,
    /// Failure of the current viewport request, if any.
    request_error: ?anyerror,
    /// Terminal indexing error; FileChanged also invalidates future reads.
    index_error: ?anyerror,
};
const Request = union(enum) { window: u64, line: u64 };

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: large.LargeFile, // worker-only after spawn
    thread: std.Thread = undefined,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    stop: bool = false,
    request: ?Request = null,
    generation: u64 = 0,
    loading: bool = false,
    request_error: ?anyerror = null,
    index_error: ?anyerror = null,
    indexed_bytes: u64 = 0,
    file_size: u64,
    complete: bool,
    offset: u64 = 0,
    len: usize = 0,
    first_line: ?u64 = null,
    bytes: [max_window]u8 = undefined,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Worker {
        return createIn(allocator, io, std.Io.Dir.cwd(), path);
    }

    /// Like create, using a borrowed directory which must remain open.
    pub fn createIn(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        var file = try large.LargeFile.open(allocator, io, dir, path);
        errdefer file.deinit(io);
        self.* = .{ .allocator = allocator, .io = io, .file = file, .file_size = file.size(), .complete = file.complete() };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Queue a 64 KiB window. The returned generation identifies this request.
    pub fn requestWindow(self: *Worker, offset: u64) u64 {
        return self.submit(.{ .window = offset });
    }
    /// Queue the window starting at a zero-based line. Indexing continues until
    /// the line is known, EOF is reached, or another request supersedes it.
    pub fn requestLine(self: *Worker, line: u64) u64 {
        return self.submit(.{ .line = line });
    }
    fn submit(self: *Worker, req: Request) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.generation +%= 1;
        self.request = req;
        self.loading = true;
        self.request_error = null;
        // Keep the previous viewport while its replacement is in flight.
        self.condition.signal(self.io);
        return self.generation;
    }
    /// Copies at most min(out.len, 64 KiB) bytes into caller-owned storage.
    /// len reports bytes actually copied. No file operations occur here.
    pub fn snapshot(self: *Worker, out: []u8) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = @min(out.len, self.len);
        @memcpy(out[0..n], self.bytes[0..n]);
        return .{ .offset = self.offset, .len = n, .first_line = self.first_line, .indexed_bytes = self.indexed_bytes, .file_size = self.file_size, .complete = self.complete, .generation = self.generation, .loading = self.loading, .request_error = self.request_error, .index_error = self.index_error };
    }
    /// Signals shutdown and joins. See module documentation about stalled I/O.
    pub fn destroy(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stop = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();
        self.allocator.destroy(self);
    }

    /// Blocking synchronization for tests/CLI consumers; never use on the UI thread.
    pub fn waitForRequest(self: *Worker, generation: u64) void {
        awaitRequest(self, generation);
    }

    fn run(self: *Worker) void {
        defer self.file.deinit(self.io);
        var data: [max_window]u8 = undefined;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stop and self.request == null and (self.complete or self.index_error != null))
                self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stop) {
                self.mutex.unlock(self.io);
                return;
            }
            const req = self.request;
            const gen = self.generation;
            self.request = null;
            const index_failed = self.index_error;
            self.mutex.unlock(self.io);

            if (req) |request| {
                const maybe_off: ?u64 = switch (request) {
                    .window => |value| value,
                    .line => |value| self.file.lineStart(self.io, value) catch |err| blk: {
                        if (err == error.IndexIncomplete and index_failed == null) {
                            // Keep the pending line request, but let one indexing chunk run.
                            self.mutex.lockUncancelable(self.io);
                            if (self.generation == gen and !self.stop) self.request = request;
                            self.mutex.unlock(self.io);
                            break :blk null;
                        }
                        self.finishError(gen, if (err == error.IndexIncomplete) index_failed orelse err else err);
                        continue;
                    },
                };
                if (maybe_off) |off| {
                    const n = self.file.readWindow(self.io, off, &data) catch |err| {
                        self.finishError(gen, err);
                        continue;
                    };
                    const first: ?u64 = if (off <= self.file.indexedBytes()) self.file.lineOf(self.io, off) catch |err| blk: {
                        self.finishError(gen, err);
                        break :blk null;
                    } else null;
                    // A failed lineOf must not be replaced by a successful result.
                    self.mutex.lockUncancelable(self.io);
                    if (self.generation == gen and self.loading and !self.stop) {
                        @memcpy(self.bytes[0..n], data[0..n]);
                        self.offset = off;
                        self.len = n;
                        self.first_line = first;
                        self.loading = false;
                        self.condition.broadcast(self.io);
                    }
                    self.mutex.unlock(self.io);
                    continue;
                }
            }
            if (index_failed == null and !self.file.complete()) {
                _ = self.file.indexStep(self.io, large.chunk_size) catch |err| {
                    self.mutex.lockUncancelable(self.io);
                    self.index_error = err;
                    self.condition.broadcast(self.io);
                    self.mutex.unlock(self.io);
                    continue;
                };
                self.mutex.lockUncancelable(self.io);
                self.indexed_bytes = self.file.indexedBytes();
                self.complete = self.file.complete();
                const refresh_line = !self.loading and self.first_line == null and self.len > 0 and self.offset <= self.indexed_bytes;
                const offset = self.offset;
                const generation = self.generation;
                self.condition.broadcast(self.io);
                self.mutex.unlock(self.io);
                if (refresh_line) {
                    const line = self.file.lineOf(self.io, offset) catch |err| {
                        self.finishError(generation, err);
                        continue;
                    };
                    self.mutex.lockUncancelable(self.io);
                    if (self.generation == generation and self.offset == offset and !self.loading) self.first_line = line;
                    self.mutex.unlock(self.io);
                }
            }
        }
    }
    fn finishError(self: *Worker, gen: u64, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.generation == gen and !self.stop) {
            self.request_error = err;
            self.loading = false;
            self.len = 0;
            self.condition.broadcast(self.io);
        }
    }
};

// Wait on the same publication condition, rather than sleeping or spinning.
fn awaitRequest(w: *Worker, generation: u64) void {
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    while (w.generation == generation and w.loading)
        w.condition.waitUncancelable(w.io, &w.mutex);
}
fn awaitIndex(w: *Worker) void {
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    while (!w.complete and w.index_error == null)
        w.condition.waitUncancelable(w.io, &w.mutex);
}

test "window, line, latest request and indexed progress" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "zero\none\ntwo\n" });
    const w = try Worker.createIn(std.testing.allocator, io, tmp.dir, "file");
    defer w.destroy();
    const a = w.requestWindow(5);
    awaitRequest(w, a);
    var buf: [max_window]u8 = undefined;
    var s = w.snapshot(&buf);
    try std.testing.expectEqualStrings("one\ntwo\n", buf[0..s.len]);
    awaitIndex(w);
    _ = w.requestWindow(0);
    _ = w.requestLine(1);
    const g = w.requestLine(2);
    awaitRequest(w, g);
    s = w.snapshot(&buf);
    try std.testing.expectEqual(g, s.generation);
    try std.testing.expectEqual(@as(u64, 9), s.offset);
    try std.testing.expectEqual(@as(?u64, 2), s.first_line);
    try std.testing.expectEqualStrings("two\n", buf[0..s.len]);
    try std.testing.expect(s.complete and s.indexed_bytes == s.file_size);
    const bad = w.requestLine(20);
    awaitRequest(w, bad);
    s = w.snapshot(&buf);
    try std.testing.expectEqual(error.LineOutOfRange, s.request_error.?);
}

test "truncation is reported by background read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "abcdef" });
    const w = try Worker.createIn(std.testing.allocator, io, tmp.dir, "file");
    defer w.destroy();
    awaitIndex(w);
    const f = try tmp.dir.openFile(io, "file", .{ .mode = .write_only });
    try f.setLength(io, 1);
    f.close(io);
    const g = w.requestWindow(0);
    awaitRequest(w, g);
    const s = w.snapshot(&.{});
    try std.testing.expectEqual(error.FileChanged, s.request_error.?);
}

test "idle and active destruction and repeated creation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "file", .{});
    try f.setLength(io, 16 * 1024 * 1024);
    f.close(io);
    for (0..12) |i| {
        const w = try Worker.createIn(std.testing.allocator, io, tmp.dir, "file");
        if (i == 0) awaitIndex(w) else _ = w.requestWindow(1024);
        w.destroy();
    }
}

test "index allocation stays bounded for a known file size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "file", .{});
    try f.setLength(io, 4 * 1024 * 1024);
    f.close(io);
    // Worker itself owns a fixed 64 KiB window. The file index stores one u64
    // per complete 64 KiB chunk, subject to ArrayList capacity growth.
    const storage = try std.testing.allocator.alloc(u8, 80 * 1024);
    defer std.testing.allocator.free(storage);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    const w = try Worker.createIn(fixed.allocator(), io, tmp.dir, "file");
    awaitIndex(w);
    const s = w.snapshot(&.{});
    try std.testing.expect(s.complete and s.index_error == null);
    try std.testing.expect(fixed.end_index < storage.len);
    w.destroy();
}
