//! Scoped startup and operation logs. File I/O is explicit and logging never
//! propagates errors into editing. Logs rotate at startup once they exceed 4 MiB.
//! UTC timestamps, levels and scopes use fixed columns; only terminals get ANSI color.
const std = @import("std");
var destination: ?std.Io.File = null;
var log_io: std.Io = undefined;
var color = false;
var active = false;
var file_offset: u64 = 0;
var rules: ?[]const u8 = null;
var lock: std.atomic.Mutex = .unlocked;
pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !void {
    log_io = io;
    color = env.get("NO_COLOR") == null and
        !std.mem.eql(u8, env.get("TERM") orelse "", "dumb") and
        (std.Io.File.stderr().supportsAnsiEscapeCodes(io) catch false);
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
test "plain records have aligned time, level, scope and message columns" {
    var buffer: [256]u8 = undefined;
    for ([_]std.log.Level{ .debug, .info, .warn, .err }) |level| {
        const record = try formatRecord(&buffer, 6 * 3600 + 29 * 60 + 34, level, "app", "hello", false);
        try std.testing.expectEqualStrings("06:29:34 | ", record[0..11]);
        try std.testing.expectEqualStrings(" | app                  | hello\n", record[16..]);
        try std.testing.expect(std.mem.indexOfScalar(u8, record, '\x1b') == null);
    }
}

test "long scopes stay bounded and colored records reset before the message" {
    var buffer: [256]u8 = undefined;
    const plain = try formatRecord(&buffer, 86400, .info, "abcdefghijklmnopqrstuvwxyz", "hello", false);
    try std.testing.expectEqualStrings("00:00:00 | INFO  | abcdefghijklmnopq... | hello\n", plain);
    const colored = try formatRecord(&buffer, 0, .err, "app", "hello", true);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[31mERROR\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[35mapp") != null);
    try std.testing.expect(std.mem.endsWith(u8, colored, "\x1b[0m | hello\n"));
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
// UTC wall time and bounded scope names keep every message in the same column.
fn formatRecord(buffer: []u8, seconds: i64, level: std.log.Level, scope: []const u8, message: []const u8, ansi: bool) ![]const u8 {
    const day_seconds: u64 = @intCast(@mod(seconds, 24 * 60 * 60));
    const label, const level_color = switch (level) {
        .debug => .{ "DEBUG", "\x1b[36m" },
        .info => .{ "INFO", "\x1b[32m" },
        .warn => .{ "WARN", "\x1b[33m" },
        .err => .{ "ERROR", "\x1b[31m" },
    };
    var scope_buffer: [20]u8 = @splat(' ');
    if (scope.len <= scope_buffer.len) {
        @memcpy(scope_buffer[0..scope.len], scope);
    } else {
        @memcpy(scope_buffer[0..17], scope[0..17]);
        @memcpy(scope_buffer[17..], "...");
    }
    const reset = if (ansi) "\x1b[0m" else "";
    return std.fmt.bufPrint(buffer, "{s}{d:0>2}:{d:0>2}:{d:0>2}{s} | {s}{s: <5}{s} | {s}{s}{s} | {s}\n", .{
        if (ansi) "\x1b[90m" else "",
        day_seconds / 3600,
        day_seconds / 60 % 60,
        day_seconds % 60,
        reset,
        if (ansi) level_color else "",
        label,
        reset,
        if (ansi) "\x1b[35m" else "",
        scope_buffer,
        reset,
        message,
    });
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    if (!active) {
        std.log.defaultLog(level, scope, fmt, args);
        return;
    }
    if (!enabled(level, scope)) return;
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    const seconds = std.Io.Clock.real.now(log_io).toSeconds();
    var message_buffer: [4096]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, fmt, args) catch return;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, message, "\n"), '\n');
    while (lines.next()) |line| {
        var buffer: [4352]u8 = undefined;
        const console = formatRecord(&buffer, seconds, level, @tagName(scope), line, color) catch return;
        std.Io.File.stderr().writeStreamingAll(log_io, console) catch {};
        if (destination) |file| {
            const plain = formatRecord(&buffer, seconds, level, @tagName(scope), line, false) catch return;
            file.writePositionalAll(log_io, plain, file_offset) catch return;
            file_offset += plain.len;
        }
    }
}
