const std = @import("std");

pub const Entry = struct {
    path: []u8,
    name: []u8,
    depth: usize,
    directory: bool,
    collapsed: bool = false,
    guide_mask: u32 = 0,
};

pub fn naturalLessThan(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var num_a: u64 = 0;
            while (i < a.len and std.ascii.isDigit(a[i])) : (i += 1) {
                num_a = num_a *% 10 +% (a[i] - '0');
            }
            var num_b: u64 = 0;
            while (j < b.len and std.ascii.isDigit(b[j])) : (j += 1) {
                num_b = num_b *% 10 +% (b[j] - '0');
            }
            if (num_a != num_b) return num_a < num_b;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return ca < cb;
        i += 1;
        j += 1;
    }
    if (i < a.len) return false;
    if (j < b.len) return true;
    return std.mem.lessThan(u8, a, b);
}

const Node = struct {
    name: []u8,
    full_path: []u8,
    is_dir: bool,
    children: std.ArrayList(Node),

    fn init(gpa: std.mem.Allocator, name: []const u8, full_path: []const u8, is_dir: bool) !Node {
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        const p = try gpa.dupe(u8, full_path);
        errdefer gpa.free(p);
        return .{
            .name = n,
            .full_path = p,
            .is_dir = is_dir,
            .children = .empty,
        };
    }

    fn deinit(self: *Node, gpa: std.mem.Allocator) void {
        for (self.children.items) |*child| {
            child.deinit(gpa);
        }
        self.children.deinit(gpa);
        gpa.free(self.name);
        gpa.free(self.full_path);
    }
};

pub const SortMode = enum { directories_first, mixed, files_first };
pub const Options = struct { directories: []const []u8 = &.{}, auto_fold_dirs: bool = true, sort_mode: SortMode = .directories_first };

pub const Project = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator, files: []const []u8) !Project {
        return initWithOptions(gpa, files, .{});
    }
    pub fn initWithOptions(gpa: std.mem.Allocator, files: []const []u8, options: Options) !Project {
        var self: Project = .{ .allocator = gpa };
        errdefer self.deinit();

        var root = try Node.init(gpa, "", "", true);
        defer root.deinit(gpa);

        for (0..files.len + options.directories.len) |path_index| {
            const file = if (path_index < files.len) files[path_index] else options.directories[path_index - files.len];
            var cur = &root;
            var it = std.mem.splitScalar(u8, file, '/');
            var path_buf: std.ArrayList(u8) = .empty;
            defer path_buf.deinit(gpa);

            while (it.next()) |part| {
                if (part.len == 0) continue;
                if (path_buf.items.len > 0) try path_buf.append(gpa, '/');
                try path_buf.appendSlice(gpa, part);

                const is_file = !std.mem.endsWith(u8, file, "/") and (it.index == null or it.index.? >= file.len);
                var found: ?*Node = null;
                for (cur.children.items) |*child| {
                    if (std.mem.eql(u8, child.name, part) and child.is_dir != is_file) {
                        found = child;
                        break;
                    }
                }
                if (found) |child| {
                    cur = child;
                } else {
                    var new_node = try Node.init(gpa, part, path_buf.items, !is_file);
                    errdefer new_node.deinit(gpa);
                    try cur.children.append(gpa, new_node);
                    cur = &cur.children.items[cur.children.items.len - 1];
                }
            }
        }

        if (options.auto_fold_dirs) try autoFold(&root, gpa);
        sortNode(&root, options.sort_mode);

        const count = root.children.items.len;
        for (root.children.items, 0..) |*child, i| {
            try self.flatten(child, 0, 0, i + 1 == count);
        }

        return self;
    }

    fn autoFold(node: *Node, gpa: std.mem.Allocator) !void {
        for (node.children.items) |*child| {
            try autoFold(child, gpa);
        }

        if (node.full_path.len > 0 and node.is_dir) {
            while (node.children.items.len == 1 and node.children.items[0].is_dir) {
                const child = &node.children.items[0];
                const combined_name = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ node.name, child.name });
                gpa.free(node.name);
                node.name = combined_name;

                gpa.free(node.full_path);
                node.full_path = child.full_path;

                gpa.free(child.name);
                const next_children = child.children;
                node.children.deinit(gpa);
                node.children = next_children;
            }
        }
    }

    fn sortNode(node: *Node, mode: SortMode) void {
        std.mem.sort(Node, node.children.items, mode, struct {
            fn less(sort_mode: SortMode, a: Node, b: Node) bool {
                if (a.is_dir != b.is_dir and sort_mode != .mixed) return if (sort_mode == .directories_first) a.is_dir else !a.is_dir;
                return naturalLessThan(a.name, b.name);
            }
        }.less);
        for (node.children.items) |*child| {
            sortNode(child, mode);
        }
    }

    fn appendEntry(self: *Project, node: *Node, depth: usize, guide_mask: u32) !void {
        const path = try self.allocator.dupe(u8, node.full_path);
        errdefer self.allocator.free(path);
        const name = try self.allocator.dupe(u8, node.name);
        errdefer self.allocator.free(name);

        try self.entries.append(self.allocator, .{
            .path = path,
            .name = name,
            .depth = depth,
            .directory = node.is_dir,
            .collapsed = false,
            .guide_mask = guide_mask,
        });
    }

    fn flatten(self: *Project, node: *Node, depth: usize, running_mask: u32, is_last: bool) !void {
        const guide_mask = if (depth == 0) 0 else running_mask | (@as(u32, 1) << @intCast(depth - 1));
        try self.appendEntry(node, depth, guide_mask);

        const next_mask = if (is_last) running_mask else running_mask | (@as(u32, 1) << @intCast(depth));
        const count = node.children.items.len;
        for (node.children.items, 0..) |*child, i| {
            try self.flatten(child, depth + 1, next_mask, i + 1 == count);
        }
    }

    pub fn deinit(self: *Project) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.path);
            self.allocator.free(e.name);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn visible(self: *const Project, gpa: std.mem.Allocator, out: *std.ArrayList(usize)) !void {
        out.clearRetainingCapacity();
        var hide_prefix: ?[]const u8 = null;
        for (self.entries.items, 0..) |e, i| {
            if (hide_prefix) |prefix| {
                if (std.mem.startsWith(u8, e.path, prefix) and (e.path.len == prefix.len or e.path[prefix.len] == '/')) {
                    continue;
                }
                hide_prefix = null;
            }
            try out.append(gpa, i);
            if (e.directory and e.collapsed) {
                hide_prefix = e.path;
            }
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

test "directory folding can be disabled and sort mode changes entry order" {
    var files = [_][]u8{ @constCast("a/b/file.zig"), @constCast("README.md") };
    var project = try Project.initWithOptions(std.testing.allocator, &files, .{ .auto_fold_dirs = false, .sort_mode = .files_first });
    defer project.deinit();
    try std.testing.expectEqualStrings("README.md", project.entries.items[0].name);
    try std.testing.expectEqualStrings("a", project.entries.items[1].name);
    try std.testing.expectEqualStrings("b", project.entries.items[2].name);
}

test "project auto-folds single child directories and sorts dirs before files" {
    const files = [_][]const u8{ "docs/guide/start.md", "README.md", "assets/icons/zig.svg", "build.zig" };
    var files_mut: [files.len][]u8 = undefined;
    for (files, 0..) |f, i| files_mut[i] = @constCast(f);
    var project = try Project.init(std.testing.allocator, &files_mut);
    defer project.deinit();

    // Check that directories come first: assets and docs come before README.md and build.zig
    try std.testing.expect(project.entries.items[0].directory); // assets / icons
    try std.testing.expectEqualStrings("assets/icons", project.entries.items[0].name);
    try std.testing.expectEqualStrings("assets/icons", project.entries.items[0].path);

    try std.testing.expectEqualStrings("docs/guide", project.entries.items[2].name);
    try std.testing.expectEqualStrings("docs/guide", project.entries.items[2].path);
}
