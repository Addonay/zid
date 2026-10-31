//! Scoped startup and operation logs. File I/O is explicit and logging never
//! propagates errors into editing. Logs rotate at startup once they exceed 4 MiB.
const std = @import("std");
var destination: ?std.Io.File = null;
var log_io: std.Io = undefined;
var started: std.Io.Timestamp = undefined;
var active = false;
var file_offset: u64 = 0;
var rules: ?[]const u8 = null;
var lock: std.atomic.Mutex = .unlocked;
pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    log_io = io;
    started = std.Io.Clock.awake.now(io);
    active = true;
    rules = env.get("ZID_LOG");
    const home = env.get("HOME") orelse ".";
    const root = if (env.get("XDG_STATE_HOME")) |p| try std.fs.path.join(gpa, &.{ p, "zid" }) else try std.fs.path.join(gpa, &.{ home, ".local", "state", "zid" });
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const path = try std.fs.path.join(gpa, &.{ root, "zid.log" });
    defer gpa.free(path);
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |s| {
        if (s.size > 4 * 1024 * 1024) {
            const old = try std.fmt.allocPrint(gpa, "{s}.old", .{path});
            defer gpa.free(old);
            std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), old, io) catch {};
        }
    } else |_| {}
    destination = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    const size = (try destination.?.stat(io)).size;
    file_offset = size;
}
pub fn deinit() void {
    if (destination) |file| file.close(log_io);
    destination = null;
    active = false;
}
fn enabled(comptime level: std.log.Level, comptime scope: @EnumLiteral()) bool {
    var threshold: std.log.Level = .info;
    if (rules) |r| {
        var items = std.mem.splitScalar(u8, r, ',');
        while (items.next()) |item| {
            if (std.mem.indexOfScalar(u8, item, '=')) |at| {
                if (std.mem.eql(u8, item[0..at], @tagName(scope)) or std.mem.eql(u8, item[0..at], "*")) threshold = std.meta.stringToEnum(std.log.Level, item[at + 1 ..]) orelse threshold;
            } else threshold = std.meta.stringToEnum(std.log.Level, item) orelse threshold;
        }
    }
    return @backingInt(level) <= @backingInt(threshold);
}
pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    if (!active) {
        std.log.defaultLog(level, scope, fmt, args);
        return;
    }
    if (!enabled(level, scope)) return;
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const elapsed = started.durationTo(std.Io.Clock.awake.now(log_io)).toMilliseconds();
    var buffer: [4096]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buffer, "+{d}ms {s} [{s}] ", .{ elapsed, @tagName(level), @tagName(scope) }) catch return;
    const body = std.fmt.bufPrint(buffer[prefix.len .. buffer.len - 1], fmt, args) catch return;
    const len = prefix.len + body.len;
    buffer[len] = '\n';
    std.Io.File.stderr().writeStreamingAll(log_io, buffer[0 .. len + 1]) catch {};
    if (destination) |file| {
        file.writePositionalAll(log_io, buffer[0 .. len + 1], file_offset) catch return;
        file_offset += len + 1;
    }
}
