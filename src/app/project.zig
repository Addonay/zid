const std = @import("std");
pub const Entry = struct { path: []u8, depth: usize, directory: bool, collapsed: bool = false };
pub const Project = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    pub fn init(gpa: std.mem.Allocator, files: []const []u8) !Project {
        var self: Project = .{ .allocator = gpa };
        errdefer self.deinit();
        var seen: std.StringHashMap(void) = .init(gpa);
        defer seen.deinit();
        for (files) |file| {
            var depth: usize = 0;
            for (file, 0..) |ch, i| if (ch == '/') {
                const prefix = file[0..i];
                if (!seen.contains(prefix)) {
                    try seen.put(prefix, {});
                    const path = try gpa.dupe(u8, prefix);
                    errdefer gpa.free(path);
                    try self.entries.append(gpa, .{ .path = path, .depth = depth, .directory = true });
                }
                depth += 1;
            };
            const path = try gpa.dupe(u8, file);
            errdefer gpa.free(path);
            try self.entries.append(gpa, .{ .path = path, .depth = depth, .directory = false });
        }
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.less);
        return self;
    }
    pub fn deinit(self: *Project) void {
        for (self.entries.items) |e| self.allocator.free(e.path);
        self.entries.deinit(self.allocator);
    }
    pub fn visible(self: *const Project, gpa: std.mem.Allocator, out: *std.ArrayList(usize)) !void {
        out.clearRetainingCapacity();
        var hidden: ?[]const u8 = null;
        for (self.entries.items, 0..) |e, i| {
            if (hidden) |prefix| {
                if (e.path.len > prefix.len and std.mem.startsWith(u8, e.path, prefix) and e.path[prefix.len] == '/') continue;
                hidden = null;
            }
            try out.append(gpa, i);
            if (e.directory and e.collapsed) hidden = e.path;
        }
    }
};

fn allocationScenario(gpa: std.mem.Allocator) !void {
    const names = [_][]const u8{ "src/main.zig", "src/editor/document.zig", "README.md" };
    var files: [names.len][]u8 = undefined;
    for (names, 0..) |name, i| files[i] = @constCast(name);
    var project = try Project.init(gpa, &files);
    defer project.deinit();
    var rows: std.ArrayList(usize) = .empty;
    defer rows.deinit(gpa);
    try project.visible(gpa, &rows);
    try std.testing.expectEqual(@as(usize, 5), rows.items.len);
    for (project.entries.items) |*e| if (std.mem.eql(u8, e.path, "src")) {
        e.collapsed = true;
    };
    try project.visible(gpa, &rows);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
}
test "project collapse and allocation ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
