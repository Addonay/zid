//! Git CLI backend. All paths are byte strings, relative to Repository.root unless noted.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    stdout_limit: usize = 16 * 1024 * 1024,
    stderr_limit: usize = 64 * 1024,
    timeout: std.Io.Timeout = .none,
};

fn run(a: Allocator, io: std.Io, argv: []const []const u8, options: Options) ![]u8 {
    const result = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(options.stdout_limit), .stderr_limit = .limited(options.stderr_limit), .timeout = options.timeout });
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            a.free(result.stdout);
            return error.GitFailed;
        },
        else => {
            a.free(result.stdout);
            return error.GitFailed;
        },
    }
    return result.stdout;
}

pub const Repository = struct {
    root: []u8,
    pub fn discover(a: Allocator, io: std.Io, directory: []const u8, options: Options) !Repository {
        const out = try run(a, io, &.{ "git", "-C", directory, "rev-parse", "--path-format=absolute", "--show-toplevel" }, options);
        defer a.free(out);
        if (out.len == 0 or out[out.len - 1] != '\n') return error.InvalidGitOutput;
        return .{ .root = try a.dupe(u8, out[0 .. out.len - 1]) };
    }
    pub fn deinit(self: *Repository, a: Allocator) void {
        a.free(self.root);
        self.* = undefined;
    }
    pub fn status(self: Repository, a: Allocator, io: std.Io, options: Options) !Status {
        const raw = try run(a, io, &.{ "git", "-C", self.root, "status", "--porcelain=v2", "-z", "--untracked-files=all" }, options);
        defer a.free(raw);
        return parseStatus(a, raw);
    }
    pub fn diff(self: Repository, a: Allocator, io: std.Io, path: []const u8, side: Side, options: Options) !Diff {
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null or std.fs.path.isAbsolute(path)) return error.InvalidPath;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |part| if (std.mem.eql(u8, part, "..")) {
            return error.InvalidPath;
        };
        const cached = if (side == .staged) "--cached" else "--no-ext-diff";
        const raw = try run(a, io, &.{ "git", "--literal-pathspecs", "-C", self.root, "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=3", cached, "--", path }, options);
        errdefer a.free(raw);
        return try parseDiff(a, raw);
    }
};
pub const Side = enum { staged, unstaged };
pub const Entry = struct {
    path: []const u8,
    original_path: ?[]const u8 = null,
    index: u8,
    worktree: u8,
    kind: Kind,
    pub const Kind = enum { ordinary, renamed, unmerged, untracked, ignored };
};
pub const Status = struct {
    storage: []u8,
    entries: []Entry,
    pub fn deinit(self: *Status, a: Allocator) void {
        a.free(self.entries);
        a.free(self.storage);
        self.* = undefined;
    }
};
fn fields(record: []const u8, count: usize) !struct { xy: []const u8, path: []const u8 } {
    var start: usize = 2;
    var xy: []const u8 = "";
    for (0..count) |i| {
        const end = std.mem.indexOfScalarPos(u8, record, start, ' ') orelse return error.InvalidGitOutput;
        if (end == start) return error.InvalidGitOutput;
        if (i == 0) xy = record[start..end];
        start = end + 1;
    }
    if (xy.len != 2 or start >= record.len) return error.InvalidGitOutput;
    return .{ .xy = xy, .path = record[start..] };
}
pub fn parseStatus(a: Allocator, bytes: []const u8) !Status {
    const storage = try a.dupe(u8, bytes);
    errdefer a.free(storage);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(a);
    var pos: usize = 0;
    while (pos < storage.len) {
        const end = std.mem.indexOfScalarPos(u8, storage, pos, 0) orelse return error.InvalidGitOutput;
        const record = storage[pos..end];
        pos = end + 1;
        if (record.len < 3 or record[1] != ' ') return error.InvalidGitOutput;
        switch (record[0]) {
            '1', '2', 'u' => |tag| {
                const f = try fields(record, switch (tag) {
                    '1' => 7,
                    '2' => 8,
                    else => 9,
                });
                var entry: Entry = .{ .path = f.path, .index = f.xy[0], .worktree = f.xy[1], .kind = switch (tag) {
                    '1' => .ordinary,
                    '2' => .renamed,
                    else => .unmerged,
                } };
                if (tag == '2') {
                    const orig_end = std.mem.indexOfScalarPos(u8, storage, pos, 0) orelse return error.InvalidGitOutput;
                    if (orig_end == pos) return error.InvalidGitOutput;
                    entry.original_path = storage[pos..orig_end];
                    pos = orig_end + 1;
                }
                try entries.append(a, entry);
            },
            '?', '!' => |tag| try entries.append(a, .{ .path = record[2..], .index = tag, .worktree = tag, .kind = if (tag == '?') .untracked else .ignored }),
            else => return error.InvalidGitOutput,
        }
    }
    return .{ .storage = storage, .entries = try entries.toOwnedSlice(a) };
}
pub const Hunk = struct { old_start: usize, old_count: usize, new_start: usize, new_count: usize, offset: usize };
pub const Diff = struct {
    text: []u8,
    hunks: []Hunk,
    pub fn deinit(self: *Diff, a: Allocator) void {
        a.free(self.text);
        a.free(self.hunks);
        self.* = undefined;
    }
};
fn range(s: []const u8) !struct { start: usize, count: usize } {
    var it = std.mem.splitScalar(u8, s, ',');
    const start = try std.fmt.parseInt(usize, it.next() orelse return error.InvalidGitOutput, 10);
    const count = if (it.next()) |v| try std.fmt.parseInt(usize, v, 10) else 1;
    if (it.next() != null) return error.InvalidGitOutput;
    return .{ .start = start, .count = count };
}
fn parseDiff(a: Allocator, raw: []u8) !Diff {
    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer hunks.deinit(a);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var offset: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@ -")) {
            const sep = std.mem.indexOf(u8, line, " +") orelse return error.InvalidGitOutput;
            const end = std.mem.indexOfPos(u8, line, sep + 2, " @@") orelse return error.InvalidGitOutput;
            const old = try range(line[4..sep]);
            const new = try range(line[sep + 2 .. end]);
            try hunks.append(a, .{ .old_start = old.start, .old_count = old.count, .new_start = new.start, .new_count = new.count, .offset = offset });
        }
        offset += line.len + 1;
    }
    return .{ .text = raw, .hunks = try hunks.toOwnedSlice(a) };
}

test "porcelain byte paths rename and malformed records" {
    const a = std.testing.allocator;
    var s = try parseStatus(a, "2 R. N... 100644 100644 100644 abc def R100 new \xff\x00old name\x00? untracked\x00");
    defer s.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), s.entries.len);
    try std.testing.expectEqualStrings("new \xff", s.entries[0].path);
    try std.testing.expectEqualStrings("old name", s.entries[0].original_path.?);
    try std.testing.expectError(error.InvalidGitOutput, parseStatus(a, "2 R. N... 100644 100644 100644 abc def R100 new\x00"));
    try std.testing.expectError(error.InvalidGitOutput, parseStatus(a, "? missing terminator"));
}

fn fixtureGit(io: std.Io, root: []const u8, args: []const []const u8) !void {
    const a = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "git", "-C", root });
    try argv.appendSlice(a, args);
    const out = try run(a, io, argv.items, .{});
    a.free(out);
}
test "real repository status and exact staged and unstaged diffs" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    try fixtureGit(io, root, &.{ "init", "-q" });
    try tmp.dir.writeFile(io, .{ .sub_path = "[x] file", .data = "first\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "deleted", .data = "gone\n" });
    try fixtureGit(io, root, &.{ "add", "--", "[x] file", "deleted" });
    try tmp.dir.writeFile(io, .{ .sub_path = "[x] file", .data = "first\nsecond\n" });
    try tmp.dir.deleteFile(io, "deleted");
    try tmp.dir.writeFile(io, .{ .sub_path = "new \xff", .data = "untracked" });
    var repo = try Repository.discover(a, io, root, .{});
    defer repo.deinit(a);
    var status = try repo.status(a, io, .{});
    defer status.deinit(a);
    var seen_file = false;
    var seen_deleted = false;
    var seen_untracked = false;
    for (status.entries) |e| {
        if (std.mem.eql(u8, e.path, "[x] file")) {
            seen_file = e.index == 'A' and e.worktree == 'M';
        }
        if (std.mem.eql(u8, e.path, "deleted")) {
            seen_deleted = e.worktree == 'D';
        }
        if (std.mem.eql(u8, e.path, "new \xff")) {
            seen_untracked = e.kind == .untracked;
        }
    }
    try std.testing.expect(seen_file and seen_deleted and seen_untracked);
    var staged = try repo.diff(a, io, "[x] file", .staged, .{});
    defer staged.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), staged.hunks.len);
    try std.testing.expect(std.mem.indexOf(u8, staged.text, "+first") != null);
    var unstaged = try repo.diff(a, io, "[x] file", .unstaged, .{});
    defer unstaged.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), unstaged.hunks.len);
    try std.testing.expect(std.mem.indexOf(u8, unstaged.text, "+second") != null);
    try std.testing.expectError(error.InvalidPath, repo.diff(a, io, "../outside", .unstaged, .{}));
    try std.testing.expectError(error.StreamTooLong, repo.status(a, io, .{ .stdout_limit = 1 }));
}
