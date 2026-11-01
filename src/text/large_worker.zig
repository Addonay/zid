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
pub const max_copy = 1024 * 1024;
pub const CopyResult = struct { generation: u64, bytes: ?[:0]u8 = null, failure: ?anyerror = null };
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
pub const Boundary = enum { start, end };
const Request = union(enum) { window: u64, line: u64, relative: struct { offset: u64, lines: i64 }, boundary: struct { offset: u64, which: Boundary } };

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
    copy_generation: u64 = 0,
    copy_request: ?struct { start: u64, end: u64 } = null,
    copy_result: ?CopyResult = null,

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
    pub fn requestRelative(self: *Worker, offset: u64, lines: i64) u64 {
        return self.submit(.{ .relative = .{ .offset = offset, .lines = lines } });
    }
    pub fn requestBoundary(self: *Worker, offset: u64, which: Boundary) u64 {
        return self.submit(.{ .boundary = .{ .offset = offset, .which = which } });
    }
    /// Copy results are independently superseded and transferred to the caller.
    pub fn requestCopy(self: *Worker, start: u64, end: u64) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.copy_generation +%= 1;
        if (self.copy_result) |result| if (result.bytes) |bytes| self.allocator.free(bytes);
        self.copy_result = null;
        self.copy_request = .{ .start = start, .end = end };
        self.condition.signal(self.io);
        return self.copy_generation;
    }
    pub fn cancelCopy(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.copy_generation +%= 1;
        self.copy_request = null;
        if (self.copy_result) |result| if (result.bytes) |bytes| self.allocator.free(bytes);
        self.copy_result = null;
    }
    pub fn takeCopy(self: *Worker) ?CopyResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.copy_result;
        self.copy_result = null;
        return result;
    }
    fn copyBytes(self: *Worker, generation: u64, start: u64, end: u64) ![:0]u8 {
        if (end < start or end > self.file.size()) return error.OutOfRange;
        if (end - start > max_copy) return error.SelectionTooLarge;
        const len: usize = @intCast(end - start);
        const bytes = try self.allocator.allocSentinel(u8, len, 0);
        errdefer self.allocator.free(bytes);
        var pos: usize = 0;
        while (pos < len) {
            self.mutex.lockUncancelable(self.io);
            const canceled = self.stop or generation != self.copy_generation;
            self.mutex.unlock(self.io);
            if (canceled) return error.Superseded;
            const n = @min(max_window, len - pos);
            _ = try self.file.readWindow(self.io, start + pos, bytes[pos..][0..n]);
            pos += n;
        }
        // Even an empty selection must validate the source identity.
        try self.file.validate(self.io);
        if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.ClipboardContainsNul;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.ClipboardInvalidUtf8;
        return bytes;
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
        if (self.copy_result) |result| if (result.bytes) |bytes| self.allocator.free(bytes);
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
            while (!self.stop and self.request == null and self.copy_request == null and (self.complete or self.index_error != null))
                self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stop) {
                self.mutex.unlock(self.io);
                return;
            }
            const req = self.request;
            const copy = self.copy_request;
            const copy_gen = self.copy_generation;
            self.copy_request = null;
            if (copy != null) {
                self.mutex.unlock(self.io);
                const result: CopyResult = if (self.copyBytes(copy_gen, copy.?.start, copy.?.end)) |bytes|
                    .{ .generation = copy_gen, .bytes = bytes }
                else |err|
                    .{ .generation = copy_gen, .failure = err };
                self.mutex.lockUncancelable(self.io);
                if (self.copy_generation == copy_gen and !self.stop) {
                    self.copy_result = result;
                    self.condition.broadcast(self.io);
                } else if (result.bytes) |bytes| self.allocator.free(bytes);
                self.mutex.unlock(self.io);
                continue;
            }
            const gen = self.generation;
            self.request = null;
            const index_failed = self.index_error;
            self.mutex.unlock(self.io);

            if (req) |request| {
                const maybe_off: ?u64 = switch (request) {
                    .window => |value| value,
                    .relative => |value| self.relativeOffset(gen, value.offset, value.lines) catch |err| {
                        if (err != error.Superseded) self.finishError(gen, err);
                        continue;
                    },
                    .boundary => |value| self.boundaryOffset(gen, value.offset, value.which) catch |err| {
                        if (err != error.Superseded) self.finishError(gen, err);
                        continue;
                    },
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
    fn checkCurrent(self: *Worker, gen: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stop or self.generation != gen) return error.Superseded;
    }

    // Find an LF strictly before pos, or at/after pos. Each read is bounded,
    // and the mutex is held only for the cancellation check, never for I/O.
    fn findLf(self: *Worker, gen: u64, pos: u64, forward: bool) !?u64 {
        var cursor = @min(pos, self.file.size());
        var buf: [max_window]u8 = undefined;
        while (if (forward) cursor < self.file.size() else cursor > 0) {
            try self.checkCurrent(gen);
            const start = if (forward) cursor else cursor -| max_window;
            const len: usize = @intCast(if (forward) @min(max_window, self.file.size() - cursor) else cursor - start);
            _ = try self.file.readWindow(self.io, start, buf[0..len]);
            try self.checkCurrent(gen);
            if (forward) {
                if (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |i| return start + i;
                cursor += len;
            } else {
                if (std.mem.lastIndexOfScalar(u8, buf[0..len], '\n')) |i| return start + i;
                cursor = start;
            }
        }
        return null;
    }
    fn lineStartAt(self: *Worker, gen: u64, offset: u64) !u64 {
        return if (try self.findLf(gen, offset, false)) |lf| lf + 1 else 0;
    }
    fn relativeOffset(self: *Worker, gen: u64, offset: u64, lines: i64) !u64 {
        var start = try self.lineStartAt(gen, @min(offset, self.file.size()));
        var remaining = lines;
        while (remaining > 0) : (remaining -= 1) {
            const lf = (try self.findLf(gen, start, true)) orelse break;
            start = lf + 1;
        }
        while (remaining < 0) : (remaining += 1) {
            if (start == 0) break;
            start = try self.lineStartAt(gen, start - 1);
        }
        return start;
    }
    fn boundaryOffset(self: *Worker, gen: u64, offset: u64, which: Boundary) !u64 {
        const at = @min(offset, self.file.size());
        if (which == .start) return self.lineStartAt(gen, at);
        const lf = (try self.findLf(gen, at, true)) orelse return self.file.size();
        if (lf > 0) {
            var byte: [1]u8 = undefined;
            _ = try self.file.readWindow(self.io, lf - 1, &byte);
            try self.checkCurrent(gen);
            if (byte[0] == '\r') return lf - 1;
        }
        return lf;
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
fn awaitCopy(w: *Worker) CopyResult {
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    while (w.copy_result == null) w.condition.waitUncancelable(w.io, &w.mutex);
    const result = w.copy_result.?;
    w.copy_result = null;
    return result;
}

test "queued copy and viewport both complete without losing a request" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "both", .data = "first\nsecond\n" });
    const w = try Worker.createIn(std.testing.allocator, io, tmp.dir, "both");
    defer w.destroy();
    // Publish both together so this covers the copy-priority branch regardless
    // of how quickly the worker is scheduled.
    w.mutex.lockUncancelable(io);
    w.generation += 1;
    const generation = w.generation;
    w.request = .{ .window = 6 };
    w.loading = true;
    w.copy_generation += 1;
    w.copy_request = .{ .start = 0, .end = 5 };
    w.condition.signal(io);
    w.mutex.unlock(io);
    const copied = awaitCopy(w);
    defer if (copied.bytes) |bytes| std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("first", copied.bytes.?);
    w.waitForRequest(generation);
    var bytes: [32]u8 = undefined;
    const snapshot = w.snapshot(&bytes);
    try std.testing.expectEqualStrings("second\n", bytes[0..snapshot.len]);
    try std.testing.expectEqual(generation, snapshot.generation);
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

test "relative navigation and boundaries across LF CRLF and trailing newline" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines", .data = "abc\r\ndef\n\nz\n" });
    const w = try Worker.createIn(std.testing.allocator, io, tmp.dir, "lines");
    defer w.destroy();
    const cases = [_]struct { offset: u64, lines: i64, expected: u64 }{
        .{ .offset = 2, .lines = 1, .expected = 5 },
        .{ .offset = 6, .lines = -1, .expected = 0 },
        .{ .offset = 0, .lines = 3, .expected = 10 },
        .{ .offset = 0, .lines = 99, .expected = 12 },
        .{ .offset = 12, .lines = -1, .expected = 10 },
        .{ .offset = 12, .lines = -99, .expected = 0 },
    };
    for (cases) |c| {
        const gen = w.requestRelative(c.offset, c.lines);
        awaitRequest(w, gen);
        const snap = w.snapshot(&.{});
        try std.testing.expectEqual(@as(?anyerror, null), snap.request_error);
        try std.testing.expectEqual(c.expected, snap.offset);
    }
    for ([_]struct { offset: u64, which: Boundary, expected: u64 }{
        .{ .offset = 2, .which = .start, .expected = 0 },
        .{ .offset = 2, .which = .end, .expected = 3 },
        .{ .offset = 6, .which = .end, .expected = 8 },
        .{ .offset = 12, .which = .end, .expected = 12 },
    }) |c| {
        const gen = w.requestBoundary(c.offset, c.which);
        awaitRequest(w, gen);
        try std.testing.expectEqual(c.expected, w.snapshot(&.{}).offset);
    }
}

test "distant unindexed long line and latest request" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "long", .{});
    const end: u64 = 32 * 1024 * 1024;
    try f.writePositionalAll(io, "\nlast", end);
    f.close(io);
    const w = try Worker.createIn(std.testing.allocator, io, tmp.dir, "long");
    defer w.destroy();
    var gen = w.requestRelative(end - 3, 1);
    awaitRequest(w, gen);
    try std.testing.expectEqual(end + 1, w.snapshot(&.{}).offset);
    gen = w.requestRelative(end + 2, -1);
    awaitRequest(w, gen);
    try std.testing.expectEqual(@as(u64, 0), w.snapshot(&.{}).offset);
    _ = w.requestBoundary(end - 1, .start);
    _ = w.requestRelative(end - 1, 1);
    gen = w.requestWindow(end + 1);
    awaitRequest(w, gen);
    const snap = w.snapshot(&.{});
    try std.testing.expectEqual(gen, snap.generation);
    try std.testing.expectEqual(end + 1, snap.offset);
    try std.testing.expectEqual(@as(?anyerror, null), snap.request_error);
}

test "bounded copy preserves cross-window UTF-8 and CRLF and rejects invalid text" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try std.testing.allocator.alloc(u8, max_window + 16);
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    @memcpy(data[max_window - 2 ..][0..7], "é\r\n中");
    try tmp.dir.writeFile(io, .{ .sub_path = "copy", .data = data });
    const w = try Worker.createIn(std.testing.allocator, io, tmp.dir, "copy");
    defer w.destroy();
    _ = w.requestCopy(0, data.len);
    const result = awaitCopy(w);
    const exact = result.bytes.?;
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualSlices(u8, data, exact);
    _ = w.requestCopy(max_window - 1, max_window + 2);
    try std.testing.expectEqual(error.ClipboardInvalidUtf8, awaitCopy(w).failure.?);
}

test "copy rejects oversized and NUL selections, supersedes and detects changed files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "copy", .{});
    try f.setLength(io, max_copy + 1);
    try f.writePositionalAll(io, "ok\x00", 0);
    f.close(io);
    const w = try Worker.createIn(std.testing.allocator, io, tmp.dir, "copy");
    defer w.destroy();
    _ = w.requestCopy(0, max_copy + 1);
    try std.testing.expectEqual(error.SelectionTooLarge, awaitCopy(w).failure.?);
    _ = w.requestCopy(0, 3);
    try std.testing.expectEqual(error.ClipboardContainsNul, awaitCopy(w).failure.?);
    _ = w.requestCopy(0, max_copy);
    const generation = w.requestCopy(0, 2);
    const result = awaitCopy(w);
    try std.testing.expectEqual(generation, result.generation);
    defer std.testing.allocator.free(result.bytes.?);
    try std.testing.expectEqualStrings("ok", result.bytes.?);
    const changed = try tmp.dir.openFile(io, "copy", .{ .mode = .write_only });
    try changed.setLength(io, 1);
    changed.close(io);
    _ = w.requestCopy(0, 2);
    try std.testing.expectEqual(error.FileChanged, awaitCopy(w).failure.?);
}
