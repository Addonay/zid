//! Concurrent byte transport for an LSP process. No editor or SDL dependency.
//!
//! The caller supplies already-serialized JSON bodies and owns protocol state.
//! One task owns stdout and the decoder; another owns stdin. Both queues have
//! count and byte limits. Overflow terminates the stream rather than dropping a
//! response. `destroy` cancels both tasks before killing and reaping the child.
const std = @import("std");
const framing = @import("framing.zig");

pub const Limits = struct {
    max_body_bytes: usize = 8 * 1024 * 1024,
    max_queue_bytes: usize = 16 * 1024 * 1024,
    max_queue_messages: usize = 256,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    limits: Limits,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    outgoing: std.ArrayList([]u8) = .empty,
    incoming: std.ArrayList([]u8) = .empty,
    outgoing_bytes: usize = 0,
    incoming_bytes: usize = 0,
    stopping: bool = false,
    failure: ?anyerror = null,
    reader: std.Io.Future(void) = undefined,
    writer: std.Io.Future(void) = undefined,

    /// The allocator and Io must support concurrent use and outlive destroy.
    /// The returned pointer is stable; public methods must not race destroy.
    pub fn create(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, limits: Limits) !*Worker {
        if (argv.len == 0) return error.EmptyCommand;
        if (limits.max_body_bytes == 0 or limits.max_queue_bytes == 0 or limits.max_queue_messages == 0) return error.InvalidLimits;
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        const child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
        self.* = .{ .allocator = a, .io = io, .child = child, .limits = limits };
        errdefer self.child.kill(io);
        self.reader = try io.concurrent(readerMain, .{self});
        errdefer self.reader.cancel(io);
        self.writer = try io.concurrent(writerMain, .{self});
        return self;
    }

    /// Enqueue a JSON body, copying it. QueueFull is transient; nothing is sent.
    /// Success means accepted into the local queue, not received by the server.
    pub fn send(self: *Worker, body: []const u8) !void {
        if (body.len > self.limits.max_body_bytes or body.len > self.limits.max_queue_bytes) return error.BodyTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Closed;
        if (self.outgoing.items.len >= self.limits.max_queue_messages or body.len > self.limits.max_queue_bytes - self.outgoing_bytes) return error.QueueFull;
        const copy = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(copy);
        try self.outgoing.append(self.allocator, copy);
        self.outgoing_bytes += copy.len;
        self.changed.broadcast(self.io);
    }

    /// Transfers a received body to the caller, which frees it with the worker's
    /// allocator. Poll failureStatus too: null here can mean empty or closed.
    pub fn take(self: *Worker) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.incoming.items.len == 0) return null;
        const body = self.incoming.orderedRemove(0);
        self.incoming_bytes -= body.len;
        return body;
    }

    /// First terminal transport error, including EOF or incoming queue overflow.
    pub fn failureStatus(self: *Worker) ?anyerror {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure;
    }

    /// Cancels blocked pipe I/O, joins both tasks, then terminates and reaps the
    /// child. This is forced shutdown; graceful LSP shutdown is caller-managed.
    pub fn destroy(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.changed.broadcast(self.io);
        self.mutex.unlock(self.io);
        self.writer.cancel(self.io);
        self.reader.cancel(self.io);
        self.child.kill(self.io);
        for (self.outgoing.items) |body| self.allocator.free(body);
        for (self.incoming.items) |body| self.allocator.free(body);
        self.outgoing.deinit(self.allocator);
        self.incoming.deinit(self.allocator);
        const a = self.allocator;
        a.destroy(self);
    }

    fn fail(self: *Worker, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.stopping) {
            self.failure = err;
            self.stopping = true;
        }
        self.changed.broadcast(self.io);
    }

    fn received(self: *Worker, body: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stopping) return error.Closed;
        if (body.len > self.limits.max_queue_bytes or self.incoming.items.len >= self.limits.max_queue_messages or body.len > self.limits.max_queue_bytes - self.incoming_bytes) return error.IncomingQueueFull;
        const copy = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(copy);
        try self.incoming.append(self.allocator, copy);
        self.incoming_bytes += copy.len;
        self.changed.broadcast(self.io);
    }

    fn readerMain(self: *Worker) void {
        var decoder = framing.Decoder.init(self.allocator);
        defer decoder.deinit();
        decoder.body_limit = self.limits.max_body_bytes;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = self.child.stdout.?.readStreaming(self.io, &.{&buffer}) catch |err| return self.fail(err);
            if (n == 0) {
                decoder.finish() catch |err| return self.fail(err);
                return self.fail(error.EndOfStream);
            }
            decoder.feed(buffer[0..n], self, received) catch |err| return self.fail(err);
        }
    }

    fn writerMain(self: *Worker) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and self.outgoing.items.len == 0) {
                self.changed.wait(self.io, &self.mutex) catch |err| {
                    self.mutex.unlock(self.io);
                    return self.fail(err);
                };
            }
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const body = self.outgoing.orderedRemove(0);
            self.outgoing_bytes -= body.len;
            self.mutex.unlock(self.io);
            const wire = framing.encode(self.allocator, body) catch |err| {
                self.allocator.free(body);
                return self.fail(err);
            };
            self.allocator.free(body);
            self.child.stdin.?.writeStreamingAll(self.io, wire) catch |err| {
                self.allocator.free(wire);
                return self.fail(err);
            };
            self.allocator.free(wire);
        }
    }
};

test "worker transports framed messages and cancels idle tasks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const w = try Worker.create(a, io, &.{"cat"}, .{});
    defer w.destroy();
    try w.send("{\"jsonrpc\":\"2.0\",\"id\":1}");
    w.mutex.lockUncancelable(io);
    while (w.incoming.items.len == 0 and w.failure == null) {
        w.changed.waitTimeout(io, &w.mutex, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch |err| {
            w.mutex.unlock(io);
            return err;
        };
    }
    w.mutex.unlock(io);
    const body = w.take() orelse return error.NoResponse;
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", body);
    try std.testing.expect(w.failureStatus() == null);
}

test "incoming queue overflow closes transport without dropping silently" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const w = try Worker.create(a, io, &.{"cat"}, .{ .max_queue_messages = 1 });
    defer w.destroy();
    try w.send("first");
    w.mutex.lockUncancelable(io);
    while (w.incoming.items.len == 0 and w.failure == null) {
        w.changed.waitTimeout(io, &w.mutex, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch |err| {
            w.mutex.unlock(io);
            return err;
        };
    }
    w.mutex.unlock(io);
    try w.send("second");
    w.mutex.lockUncancelable(io);
    while (w.failure == null) {
        w.changed.waitTimeout(io, &w.mutex, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch |err| {
            w.mutex.unlock(io);
            return err;
        };
    }
    const failure = w.failure;
    w.mutex.unlock(io);
    try std.testing.expectEqual(error.IncomingQueueFull, failure.?);
    try std.testing.expectError(error.Closed, w.send("third"));
    const first = w.take().?;
    defer a.free(first);
    try std.testing.expectEqualStrings("first", first);
}

test "malformed server frame fails transport" {
    const io = std.testing.io;
    const w = try Worker.create(std.testing.allocator, io, &.{ "sh", "-c", "printf 'Content-Length: nope\\r\\n\\r\\n'" }, .{});
    defer w.destroy();
    w.mutex.lockUncancelable(io);
    while (w.failure == null) {
        w.changed.waitTimeout(io, &w.mutex, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } }) catch |err| {
            w.mutex.unlock(io);
            return err;
        };
    }
    const failure = w.failure.?;
    w.mutex.unlock(io);
    try std.testing.expectEqual(error.InvalidHeader, failure);
    try std.testing.expectError(error.Closed, w.send("{}"));
}
