//! Heap-stable background Git status refresh. The caller's allocator and Io
//! backend must remain valid and thread-safe until destroy returns.
const std = @import("std");
const git = @import("root.zig");

pub const Result = struct {
    generation: u64,
    root: ?[]u8 = null,
    status: ?git.Status = null,
    failure: ?anyerror = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.status) |*status| status.deinit(allocator);
        if (self.root) |root| allocator.free(root);
        self.* = undefined;
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    thread: std.Thread = undefined,
    stopping: bool = false,
    generation: u64 = 0,
    requested: ?[]u8 = null,
    result: ?Result = null,

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Queues the newest project path. The returned generation lets consumers
    /// reject results that predate a project change. No subprocess runs here.
    pub fn refresh(self: *Worker, path: []const u8) !u64 {
        const owned = try self.allocator.dupe(u8, path);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.generation +%= 1;
        if (self.requested) |old| self.allocator.free(old);
        if (self.result) |*old| old.deinit(self.allocator);
        self.result = null;
        self.requested = owned;
        self.condition.signal(self.io);
        return self.generation;
    }

    /// Transfers result ownership; the consumer must call Result.deinit.
    pub fn take(self: *Worker) ?Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = self.result;
        self.result = null;
        return result;
    }

    /// Joins the worker. Each subprocess has a timeout, but OS process cleanup
    /// may still delay shutdown; callers must not assume an instant close.
    pub fn destroy(self: *Worker) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.signal(self.io);
        self.mutex.unlock(self.io);
        self.thread.join();
        if (self.requested) |path| self.allocator.free(path);
        if (self.result) |*result| result.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn run(self: *Worker) void {
        const options: git.Options = .{ .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } } };
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (!self.stopping and self.requested == null) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            const path = self.requested.?;
            self.requested = null;
            const generation = self.generation;
            self.mutex.unlock(self.io);

            var result: Result = .{ .generation = generation };
            if (git.Repository.discover(self.allocator, self.io, path, options)) |repo| {
                result.root = repo.root;
                if (repo.status(self.allocator, self.io, options)) |status| result.status = status else |err| result.failure = err;
            } else |err| result.failure = err;
            self.allocator.free(path);

            self.mutex.lockUncancelable(self.io);
            if (!self.stopping and generation == self.generation) {
                if (self.result) |*old| old.deinit(self.allocator);
                self.result = result;
                self.condition.broadcast(self.io);
            } else result.deinit(self.allocator);
            self.mutex.unlock(self.io);
        }
    }
};

test "refresh returns real untracked status and invalid roots fail safely" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const init = try std.process.run(a, io, .{ .argv = &.{ "git", "-C", path, "init", "-q" } });
    defer a.free(init.stdout);
    defer a.free(init.stderr);
    try std.testing.expect(init.term == .exited and init.term.exited == 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "example" });
    const w = try Worker.create(a, io);
    defer w.destroy();
    const generation = try w.refresh(path);
    w.mutex.lockUncancelable(io);
    while (w.result == null) w.condition.waitUncancelable(io, &w.mutex);
    w.mutex.unlock(io);
    var result = w.take().?;
    defer result.deinit(a);
    try std.testing.expectEqual(generation, result.generation);
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqualStrings("new.txt", result.status.?.entries[0].path);
    _ = try w.refresh("/this-path-does-not-exist-zid");
    w.mutex.lockUncancelable(io);
    while (w.result == null) w.condition.waitUncancelable(io, &w.mutex);
    w.mutex.unlock(io);
    var failed = w.take().?;
    defer failed.deinit(a);
    try std.testing.expect(failed.failure != null);
}
