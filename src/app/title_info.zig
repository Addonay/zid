//! Read Git's lightweight HEAD metadata without spawning Git on the UI thread.
const std = @import("std");
pub fn branch(gpa: std.mem.Allocator, io: std.Io, root: []const u8, out: []u8) ![]const u8 {
    var directory = root;
    while (true) {
        const marker = try std.fs.path.join(gpa, &.{ directory, ".git" });
        defer gpa.free(marker);
        const stat = std.Io.Dir.cwd().statFile(io, marker, .{}) catch |err| {
            if (err != error.FileNotFound and err != error.NotDir) return err;
            directory = std.fs.path.dirname(directory) orelse return out[0..0];
            continue;
        };
        var git_dir: []const u8 = marker;
        var linked: ?[]u8 = null;
        defer if (linked) |path| gpa.free(path);
        if (stat.kind != .directory) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, marker, gpa, .limited(4096));
            defer gpa.free(bytes);
            if (!std.mem.startsWith(u8, bytes, "gitdir: ")) return out[0..0];
            linked = try std.fs.path.resolve(gpa, &.{ directory, std.mem.trim(u8, bytes[8..], "\r\n ") });
            git_dir = linked.?;
        }
        const head = try std.fs.path.join(gpa, &.{ git_dir, "HEAD" });
        defer gpa.free(head);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, head, gpa, .limited(4096));
        defer gpa.free(bytes);
        const text = std.mem.trim(u8, bytes, "\r\n ");
        const name = if (std.mem.startsWith(u8, text, "ref: refs/heads/")) text[16..] else text[0..@min(7, text.len)];
        const n = @min(name.len, out.len);
        @memcpy(out[0..n], name[0..n]);
        return out[0..n];
    }
}

test "branch reads symbolic and detached HEAD" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".git", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/feature/parity\n" });
    var root_buffer: [4096]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("feature/parity", try branch(std.testing.allocator, io, root, &buffer));
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "123456789abcdef\n" });
    try std.testing.expectEqualStrings("1234567", try branch(std.testing.allocator, io, root, &buffer));
}
