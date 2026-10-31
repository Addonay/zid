//! Recently opened project folders, persisted as `<dir>/recent_projects.json`.
//! Pure std: no SDL, no rendering. Behavior follows Zed's OpenRecent list:
//! most recent first, exact-path dedupe, bounded length, removable entries.
//! The caller decides whether the current project is shown in a picker.
const std = @import("std");

pub const file_name = "recent_projects.json";
const max_file_bytes = 1024 * 1024;

pub const Entry = struct {
    path: []const u8,
    /// Seconds since the Unix epoch.
    opened_at: i64,
};

pub const RecentProjects = struct {
    gpa: std.mem.Allocator,
    /// Most recent first. Each path is owned by this list.
    entries: std.ArrayList(Entry) = .empty,

    pub const max_entries = 50;

    pub fn init(gpa: std.mem.Allocator) RecentProjects {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *RecentProjects) void {
        self.clear();
        self.entries.deinit(self.gpa);
    }

    fn clear(self: *RecentProjects) void {
        for (self.entries.items) |entry| self.gpa.free(entry.path);
        self.entries.clearRetainingCapacity();
    }

    /// Replaces the in-memory list with the stored one. A missing file yields
    /// an empty list. Malformed content returns `error.InvalidRecentProjects`
    /// and leaves the list empty.
    pub fn load(self: *RecentProjects, io: std.Io, dir: []const u8) !void {
        self.clear();
        const path = try std.fs.path.join(self.gpa, &.{ dir, file_name });
        defer self.gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.gpa.free(bytes);
        try self.parse(bytes);
    }

    fn parse(self: *RecentProjects, bytes: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidRecentProjects,
        };
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidRecentProjects;
        const projects = parsed.value.object.get("projects") orelse return error.InvalidRecentProjects;
        if (projects != .array) return error.InvalidRecentProjects;

        for (projects.array.items) |item| {
            if (item != .object) return error.InvalidRecentProjects;
            const path_value = item.object.get("path") orelse return error.InvalidRecentProjects;
            const time_value = item.object.get("opened_at") orelse return error.InvalidRecentProjects;
            if (path_value != .string or path_value.string.len == 0) return error.InvalidRecentProjects;
            if (time_value != .integer) return error.InvalidRecentProjects;
            // Stored order is already most-recent-first; keep the first copy of
            // any duplicate and stop at the bound.
            if (self.indexOf(path_value.string) != null) continue;
            if (self.entries.items.len >= max_entries) break;
            const owned = try self.gpa.dupe(u8, path_value.string);
            errdefer self.gpa.free(owned);
            try self.entries.append(self.gpa, .{ .path = owned, .opened_at = time_value.integer });
        }
    }

    /// Atomically writes the list to `<dir>/recent_projects.json`, creating
    /// `dir` if needed.
    pub fn save(self: *const RecentProjects, io: std.Io, dir: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.fs.path.join(self.gpa, &.{ dir, file_name });
        defer self.gpa.free(path);

        const Stored = struct { projects: []const Entry };
        const content = try std.json.Stringify.valueAlloc(self.gpa, Stored{ .projects = self.entries.items }, .{ .whitespace = .indent_2 });
        defer self.gpa.free(content);

        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
            .replace = true,
            .permissions = .default_file,
        });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, content);
        try file.file.sync(io);
        try file.replace(io);
    }

    /// Moves `path` to the front with timestamp `now`, inserting it if absent.
    /// Trims the oldest entries beyond `max_entries`.
    pub fn touch(self: *RecentProjects, path: []const u8, now: i64) !void {
        if (path.len == 0) return error.EmptyPath;
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        if (self.indexOf(path)) |index| {
            const removed = self.entries.orderedRemove(index);
            self.gpa.free(removed.path);
        }
        try self.entries.insert(self.gpa, 0, .{ .path = owned, .opened_at = now });
        while (self.entries.items.len > max_entries) {
            const oldest = self.entries.pop().?;
            self.gpa.free(oldest.path);
        }
    }

    pub fn remove(self: *RecentProjects, path: []const u8) void {
        const index = self.indexOf(path) orelse return;
        const removed = self.entries.orderedRemove(index);
        self.gpa.free(removed.path);
    }

    fn indexOf(self: *const RecentProjects, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) return index;
        }
        return null;
    }
};

/// Default data directory: `$XDG_DATA_HOME/zid`, or `$HOME/.local/share/zid`
/// when `XDG_DATA_HOME` is unset or empty. Caller frees the result.
pub fn defaultDir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len != 0) return std.fs.path.join(gpa, &.{ data_home, "zid" });
    }
    const home = env.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home, ".local", "share", "zid" });
}

test "touch moves to front, dedupes exact paths, and updates timestamps" {
    var recent = RecentProjects.init(std.testing.allocator);
    defer recent.deinit();

    try recent.touch("/a", 1);
    try recent.touch("/b", 2);
    try recent.touch("/c", 3);
    try std.testing.expectEqual(@as(usize, 3), recent.entries.items.len);
    try std.testing.expectEqualStrings("/c", recent.entries.items[0].path);
    try std.testing.expectEqualStrings("/a", recent.entries.items[2].path);

    try recent.touch("/a", 10);
    try std.testing.expectEqual(@as(usize, 3), recent.entries.items.len);
    try std.testing.expectEqualStrings("/a", recent.entries.items[0].path);
    try std.testing.expectEqual(@as(i64, 10), recent.entries.items[0].opened_at);
    try std.testing.expectEqualStrings("/c", recent.entries.items[1].path);
    try std.testing.expectEqualStrings("/b", recent.entries.items[2].path);

    // Exact-path dedupe only: a different spelling is a different entry.
    try recent.touch("/a/", 11);
    try std.testing.expectEqual(@as(usize, 4), recent.entries.items.len);
}

test "touch trims the list to max_entries, dropping the oldest" {
    var recent = RecentProjects.init(std.testing.allocator);
    defer recent.deinit();

    var buffer: [32]u8 = undefined;
    for (0..RecentProjects.max_entries + 5) |index| {
        const path = try std.fmt.bufPrint(&buffer, "/p/{d}", .{index});
        try recent.touch(path, @intCast(index));
    }
    try std.testing.expectEqual(@as(usize, RecentProjects.max_entries), recent.entries.items.len);
    try std.testing.expectEqualStrings("/p/54", recent.entries.items[0].path);
    try std.testing.expectEqualStrings("/p/5", recent.entries.items[recent.entries.items.len - 1].path);
}

test "remove deletes only the matching entry" {
    var recent = RecentProjects.init(std.testing.allocator);
    defer recent.deinit();
    try recent.touch("/a", 1);
    try recent.touch("/b", 2);
    recent.remove("/a");
    recent.remove("/missing");
    try std.testing.expectEqual(@as(usize, 1), recent.entries.items.len);
    try std.testing.expectEqualStrings("/b", recent.entries.items[0].path);
}

test "save and load round trip through a nested directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try temporary.dir.realPath(io, &buffer)];
    const dir = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "zid" });
    defer std.testing.allocator.free(dir);

    var original = RecentProjects.init(std.testing.allocator);
    defer original.deinit();
    try original.touch("/home/u/one", 100);
    try original.touch("/home/u/two \"quoted\" é", 200);
    try original.save(io, dir);

    var loaded = RecentProjects.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.load(io, dir);
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.items.len);
    try std.testing.expectEqualStrings("/home/u/two \"quoted\" é", loaded.entries.items[0].path);
    try std.testing.expectEqual(@as(i64, 200), loaded.entries.items[0].opened_at);
    try std.testing.expectEqualStrings("/home/u/one", loaded.entries.items[1].path);
    try std.testing.expectEqual(@as(i64, 100), loaded.entries.items[1].opened_at);
}

test "missing file loads as an empty list" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try temporary.dir.realPath(io, &buffer)];

    var recent = RecentProjects.init(std.testing.allocator);
    defer recent.deinit();
    try recent.load(io, root);
    try std.testing.expectEqual(@as(usize, 0), recent.entries.items.len);
}

test "malformed file returns InvalidRecentProjects and leaves the list empty" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try temporary.dir.realPath(io, &buffer)];

    const cases = [_][]const u8{
        "{not json",
        "[]",
        "{\"projects\":{}}",
        "{\"projects\":[{\"path\":\"/x\"}]}",
        "{\"projects\":[{\"path\":\"/x\",\"opened_at\":\"now\"}]}",
        "{\"projects\":[{\"path\":\"\",\"opened_at\":1}]}",
    };
    for (cases) |case| {
        try temporary.dir.writeFile(io, .{ .sub_path = file_name, .data = case });
        var recent = RecentProjects.init(std.testing.allocator);
        defer recent.deinit();
        try std.testing.expectError(error.InvalidRecentProjects, recent.load(io, root));
        try std.testing.expectEqual(@as(usize, 0), recent.entries.items.len);
    }
}

test "defaultDir honors XDG_DATA_HOME and falls back to HOME" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    try env.put("HOME", "/home/u");
    const fallback = try defaultDir(gpa, &env);
    defer gpa.free(fallback);
    try std.testing.expectEqualStrings("/home/u/.local/share/zid", fallback);

    try env.put("XDG_DATA_HOME", "/data");
    const xdg = try defaultDir(gpa, &env);
    defer gpa.free(xdg);
    try std.testing.expectEqualStrings("/data/zid", xdg);

    try env.put("XDG_DATA_HOME", "");
    const empty_xdg = try defaultDir(gpa, &env);
    defer gpa.free(empty_xdg);
    try std.testing.expectEqualStrings("/home/u/.local/share/zid", empty_xdg);
}
