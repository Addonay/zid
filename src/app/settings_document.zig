//! Lossless-value Zed settings model. Unsupported keys are retained, not applied.
//! JSONC comments are accepted on input; UI writes normalize JSON formatting.
const std = @import("std");
const config = @import("config.zig");
pub const assets = @import("settings_assets");
pub const Document = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Document {
        const clean = try config.jsonc(gpa, bytes);
        defer gpa.free(clean);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, clean, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSettings;
        return .{ .parsed = parsed };
    }
    pub fn load(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !Document {
        const path = try std.fs.path.join(gpa, &.{ root, "settings.json" });
        defer gpa.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return parse(gpa, "{}");
            return err;
        };
        defer gpa.free(bytes);
        return parse(gpa, bytes);
    }
    pub fn deinit(self: *Document) void {
        self.parsed.deinit();
    }
    pub fn get(self: *const Document, path: []const []const u8) ?std.json.Value {
        var value = self.parsed.value;
        for (path) |key| {
            if (value != .object) return null;
            value = value.object.get(key) orelse return null;
        }
        return value;
    }
    pub fn set(self: *Document, path: []const []const u8, value: std.json.Value) !void {
        std.debug.assert(path.len > 0);
        const arena = self.parsed.arena.allocator();
        var target = &self.parsed.value;
        for (path[0 .. path.len - 1]) |key| {
            const entry = try target.object.getOrPut(arena, try arena.dupe(u8, key));
            if (!entry.found_existing or entry.value_ptr.* != .object) entry.value_ptr.* = .{ .object = .empty };
            target = entry.value_ptr;
        }
        // Clone into the document's arena so callers can release temporary JSON.
        const bytes = try std.json.Stringify.valueAlloc(arena, value, .{});
        const clone = try std.json.parseFromSlice(std.json.Value, arena, bytes, .{ .allocate = .alloc_always });
        try target.object.put(arena, try arena.dupe(u8, path[path.len - 1]), clone.value);
    }
    /// Object fields merge recursively; scalars and arrays replace the default value.
    pub fn merge(self: *Document, overlay: *const Document) !void {
        try mergeValue(self.parsed.arena.allocator(), &self.parsed.value, overlay.parsed.value);
    }
    fn mergeValue(arena: std.mem.Allocator, target: *std.json.Value, value: std.json.Value) !void {
        if (target.* == .object and value == .object) {
            var it = value.object.iterator();
            while (it.next()) |field| {
                const entry = try target.object.getOrPut(arena, try arena.dupe(u8, field.key_ptr.*));
                if (!entry.found_existing) entry.value_ptr.* = .null;
                try mergeValue(arena, entry.value_ptr, field.value_ptr.*);
            }
        } else {
            const bytes = try std.json.Stringify.valueAlloc(arena, value, .{});
            const clone = try std.json.parseFromSlice(std.json.Value, arena, bytes, .{ .allocate = .alloc_always });
            target.* = clone.value;
        }
    }
    pub fn setJson(self: *Document, path: []const []const u8, bytes: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.parsed.arena.allocator(), bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        try self.set(path, parsed.value);
    }
    pub fn remove(self: *Document, path: []const []const u8) void {
        var target = &self.parsed.value;
        for (path[0 .. path.len - 1]) |key| {
            if (target.* != .object) return;
            target = target.object.getPtr(key) orelse return;
        }
        if (target.* == .object) _ = target.object.swapRemove(path[path.len - 1]);
    }
    pub fn save(self: *const Document, gpa: std.mem.Allocator, io: std.Io, root: []const u8) !void {
        const requested = try std.fs.path.join(gpa, &.{ root, "settings.json" });
        defer gpa.free(requested);
        try std.Io.Dir.cwd().createDirPath(io, root);
        const path = std.Io.Dir.cwd().realPathFileAlloc(io, requested, gpa) catch |err| switch (err) {
            error.FileNotFound => blk: {
                if (std.Io.Dir.cwd().statFile(io, requested, .{ .follow_symlinks = false })) |stat| {
                    if (stat.kind == .sym_link) return error.DanglingSymlink;
                } else |stat_err| if (stat_err != error.FileNotFound) return stat_err;
                break :blk try gpa.dupeSentinel(u8, requested, 0);
            },
            else => return err,
        };
        defer gpa.free(path);
        const bytes = try std.json.Stringify.valueAlloc(gpa, self.parsed.value, .{ .whitespace = .indent_2 });
        defer gpa.free(bytes);
        try std.Io.Dir.cwd().createDirPath(io, root);
        // Randomized sibling temp files avoid clobbering an existing settings.json.tmp.
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
            .replace = true,
            .permissions = if (stat) |existing| existing.permissions else .default_file,
        });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, bytes);
        if (stat) |existing| try file.file.setPermissions(io, existing.permissions);
        try file.file.sync(io);
        try file.replace(io);
    }
};

test "all bundled defaults parse and catalogue paths resolve including literal dots" {
    var defaults = try Document.parse(std.testing.allocator, assets.defaults);
    defer defaults.deinit();
    for (assets.entries) |entry| {
        if (defaults.get(entry.segments) == null) try std.testing.expectEqualStrings("null", entry.default);
        var value = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, entry.default, .{});
        value.deinit();
    }
    try std.testing.expect(assets.entries.len > 600);
}

test "nested edits preserve unknown settings and literal dotted keys" {
    var doc = try Document.parse(std.testing.allocator, "{\"future\":{\"enabled\":true},\"status_bar\":{\"experimental.show\":true},}");
    defer doc.deinit();
    try doc.setJson(&.{ "status_bar", "experimental.show" }, "false");
    try std.testing.expect(!doc.get(&.{ "status_bar", "experimental.show" }).?.bool);
    try std.testing.expect(doc.get(&.{ "future", "enabled" }).?.bool);
    doc.remove(&.{ "status_bar", "experimental.show" });
    try std.testing.expect(doc.get(&.{ "status_bar", "experimental.show" }) == null);
}
