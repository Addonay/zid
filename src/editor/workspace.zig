const std = @import("std");
const log = std.log.scoped(.files);
const Document = @import("document.zig").Document;

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    documents: std.ArrayList(Document) = .empty,
    files: std.ArrayList([]u8) = .empty,
    active: usize = 0,
    /// Opening remains synchronous and memory-backed in this slice. Bound memory
    /// until the file-backed large-file reader is integrated.
    pub const max_file_bytes = 32 * 1024 * 1024;
    pub fn init(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !Workspace {
        return .{ .allocator = allocator, .io = io, .root = try allocator.dupe(u8, root) };
    }
    pub fn deinit(self: *Workspace) void {
        for (self.documents.items) |*document| document.deinit();
        self.documents.deinit(self.allocator);
        for (self.files.items) |file| self.allocator.free(file);
        self.files.deinit(self.allocator);
        self.allocator.free(self.root);
    }
    /// Switches the project root and rescans it. Open documents stay open (absolute paths).
    pub fn setRoot(self: *Workspace, root: []const u8) !void {
        const owned = try self.allocator.dupe(u8, root);
        const previous = self.root;
        self.root = owned;
        self.scan() catch |err| {
            self.root = previous;
            self.allocator.free(owned);
            return err;
        };
        self.allocator.free(previous);
    }
    pub fn current(self: *Workspace) *Document {
        return &self.documents.items[self.active];
    }
    pub fn newDocument(self: *Workspace) !void {
        var document = try Document.init(self.allocator, "", null);
        errdefer document.deinit();
        try self.documents.append(self.allocator, document);
        self.active = self.documents.items.len - 1;
    }
    pub fn open(self: *Workspace, path: []const u8) !void {
        const requested = try std.fs.path.resolve(self.allocator, &.{ self.root, path });
        defer self.allocator.free(requested);
        const absolute = try std.Io.Dir.cwd().realPathFileAlloc(self.io, requested, self.allocator);
        defer self.allocator.free(absolute);
        for (self.documents.items, 0..) |*document, index| {
            if (document.path) |existing| if (std.mem.eql(u8, existing, absolute)) {
                self.active = index;
                return;
            };
        }
        const before = Document.DiskIdentity.fromStat(try std.Io.Dir.cwd().statFile(self.io, absolute, .{}));
        if (before.size > max_file_bytes) {
            var document = try Document.initLarge(self.allocator, self.io, absolute);
            errdefer document.deinit();
            try self.documents.append(self.allocator, document);
            self.active = self.documents.items.len - 1;
            return;
        }
        const text = blk: {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, absolute, self.allocator, .limited(max_file_bytes));
            errdefer self.allocator.free(bytes);
            const after = Document.DiskIdentity.fromStat(try std.Io.Dir.cwd().statFile(self.io, absolute, .{}));
            if (!before.eql(after)) return error.ExternalFileChanged;
            break :blk bytes;
        };
        var document = try Document.initOwned(self.allocator, text, absolute);
        document.disk_identity = before;
        errdefer document.deinit();
        try self.documents.append(self.allocator, document);
        self.active = self.documents.items.len - 1;
        log.info("opened {s}: {d} bytes, {d} lines, preview={}", .{ absolute, text.len, self.current().lineCount(), self.current().preview_only });
    }
    /// Capture this when deciding whether a Save As replacement is approved.
    /// The caller must pass the same expectation to saveWithExpectation after
    /// the dialog; a later identity check cannot establish what was approved.
    pub const SaveExpectation = union(enum) {
        absent,
        existing: Document.DiskIdentity,
    };

    pub fn save(self: *Workspace, path: ?[]const u8) !void {
        return self.saveWithExpectation(path, null);
    }
    pub fn saveWithExpectation(self: *Workspace, path: ?[]const u8, expectation: ?SaveExpectation) !void {
        const document = self.current();
        if (document.large != null) return error.ReadOnlyLargeFile;
        const target = path orelse document.path orelse return error.PathRequired;
        const requested = try std.fs.path.resolve(self.allocator, &.{ self.root, target });
        defer self.allocator.free(requested);
        // Resolve existing symlinks so atomic replacement updates the target,
        // rather than replacing a user's symlink with a regular file.
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(self.io, requested, self.allocator) catch |err| switch (err) {
            error.FileNotFound => blk: {
                // realPath also fails for a dangling final symlink. Never
                // turn that link into a regular file via the fallback path.
                if (std.Io.Dir.cwd().statFile(self.io, requested, .{ .follow_symlinks = false })) |stat| {
                    if (stat.kind == .sym_link) return error.DanglingSymlink;
                } else |stat_err| switch (stat_err) {
                    error.FileNotFound => {},
                    else => return stat_err,
                }
                const parent = std.fs.path.dirname(requested) orelse return error.FileNotFound;
                const canonical_parent = try std.Io.Dir.cwd().realPathFileAlloc(self.io, parent, self.allocator);
                defer self.allocator.free(canonical_parent);
                const joined = try std.fs.path.join(self.allocator, &.{ canonical_parent, std.fs.path.basename(requested) });
                defer self.allocator.free(joined);
                break :blk try self.allocator.dupeSentinel(u8, joined, 0);
            },
            else => return err,
        };
        errdefer self.allocator.free(absolute);
        for (self.documents.items, 0..) |*other, index| {
            if (index == self.active) continue;
            if (other.path) |owned| if (std.mem.eql(u8, owned, absolute)) return error.DocumentAlreadyOpen;
        }
        const same_target = if (document.path) |old| std.mem.eql(u8, old, absolute) else false;
        if (same_target) try self.checkIdentity(absolute, document.disk_identity);
        // Snapshot the exact object whose permissions and contents would be
        // replaced. This also protects Save As targets during the write.
        const existing = std.Io.Dir.cwd().openFile(self.io, absolute, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const existing_stat: ?std.Io.File.Stat = if (existing) |opened| blk: {
            defer opened.close(self.io);
            break :blk try opened.stat(self.io);
        } else null;
        const existing_identity: ?Document.DiskIdentity = if (existing_stat) |stat| Document.DiskIdentity.fromStat(stat) else null;
        if (expectation) |expected| switch (expected) {
            .absent => if (existing_identity != null) return error.ExternalFileChanged,
            .existing => |identity| if (existing_identity == null or !identity.eql(existing_identity.?)) return error.ExternalFileChanged,
        };
        if (same_target) {
            const identity = document.disk_identity orelse return error.ExternalFileChanged;
            if (existing_identity == null or !identity.eql(existing_identity.?)) return error.ExternalFileChanged;
        }
        var file = try std.Io.Dir.cwd().createFileAtomic(self.io, absolute, .{
            .replace = existing_stat != null,
            .permissions = if (existing_stat) |stat| stat.permissions else .default_file,
        });
        defer file.deinit(self.io);
        try document.buffer.writeTo(self.io, file.file);
        // chmod restores an existing target's mode masked during temp creation.
        // A new file must retain the mode produced by create and the umask.
        if (existing_stat) |stat| try file.file.setPermissions(self.io, stat.permissions);
        try file.file.sync(self.io);
        const new_identity = Document.DiskIdentity.fromStat(try file.file.stat(self.io));
        try self.commitSave(&file, absolute, existing_identity);
        if (document.path) |previous| self.allocator.free(previous);
        document.path = absolute;
        document.disk_identity = new_identity;
        document.saved_revision = document.revision;
        log.info("saved {s}: {d} bytes, revision={d}", .{ document.path.?, document.buffer.len(), document.revision });
    }
    fn commitSave(self: *Workspace, file: *std.Io.File.Atomic, path: []const u8, existing: ?Document.DiskIdentity) !void {
        if (existing) |identity| {
            try self.checkIdentity(path, identity);
            // The identity check and rename are separate operations; another
            // writer can still change the target in between.
            try file.replace(self.io);
        } else {
            file.link(self.io) catch |err| switch (err) {
                error.PathAlreadyExists => return error.ExternalFileChanged,
                else => return err,
            };
        }
    }
    fn checkIdentity(self: *Workspace, path: []const u8, expected: ?Document.DiskIdentity) !void {
        const identity = expected orelse return error.ExternalFileChanged;
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.ExternalFileChanged,
            else => return err,
        };
        if (!identity.eql(Document.DiskIdentity.fromStat(stat))) return error.ExternalFileChanged;
    }
    pub fn closeActive(self: *Workspace) !void {
        if (self.current().dirty()) return error.UnsavedChanges;
        const closing = self.active;
        if (self.documents.items.len == 1) try self.newDocument();
        self.documents.items[closing].deinit();
        _ = self.documents.orderedRemove(closing);
        self.active = @min(self.active, self.documents.items.len - 1);
    }
    pub fn scan(self: *Workspace) !void {
        var directory = try std.Io.Dir.cwd().openDir(self.io, self.root, .{ .iterate = true });
        defer directory.close(self.io);
        var refreshed: std.ArrayList([]u8) = .empty;
        errdefer {
            for (refreshed.items) |file| self.allocator.free(file);
            refreshed.deinit(self.allocator);
        }
        var walker = try directory.walkSelectively(self.allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind == .directory) {
                if (entry.basename[0] != '.' and !excluded(entry.basename) and entry.depth() < 12) try walker.enter(self.io, entry);
            } else if (entry.kind == .file and refreshed.items.len < 4000) {
                const path = try self.allocator.dupe(u8, entry.path);
                errdefer self.allocator.free(path);
                try refreshed.append(self.allocator, path);
            }
            if (refreshed.items.len >= 4000) break;
        }
        std.mem.sort([]u8, refreshed.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (self.files.items) |file| self.allocator.free(file);
        self.files.deinit(self.allocator);
        self.files = refreshed;
        log.debug("scanned {s}: {d} files (limit 4000, depth 12)", .{ self.root, self.files.items.len });
    }
    fn excluded(name: []const u8) bool {
        for ([_][]const u8{ "vendor", "zig-pkg", "zig-out", "node_modules", "target", "dist" }) |item| if (std.mem.eql(u8, name, item)) return true;
        return false;
    }
};

test "workspace opens, edits, atomically saves and closes its final document" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const root = path_buffer[0..try temporary.dir.realPath(io, &path_buffer)];
    try temporary.dir.writeFile(io, .{ .sub_path = "example.zig", .data = "const value = 1;\r\n" });
    var workspace = try Workspace.init(allocator, io, root);
    defer workspace.deinit();
    try workspace.open("example.zig");
    try workspace.open("./example.zig");
    try std.testing.expectEqual(@as(usize, 1), workspace.documents.items.len);
    workspace.current().move(0, false);
    try workspace.current().insert("// hello\r\n");
    try std.testing.expectError(error.UnsavedChanges, workspace.closeActive());
    try workspace.save(null);
    try std.testing.expect(!workspace.current().dirty());
    try workspace.save(null); // The identity must be refreshed after atomic replacement.
    const saved = try temporary.dir.readFileAlloc(io, "example.zig", allocator, .unlimited);
    defer allocator.free(saved);
    try std.testing.expectEqualStrings("// hello\r\nconst value = 1;\r\n", saved);
    try workspace.current().undo();
    try std.testing.expect(workspace.current().dirty());
    try workspace.current().redo();
    try workspace.closeActive();
    try std.testing.expectEqual(@as(usize, 1), workspace.documents.items.len);
    try std.testing.expect(workspace.current().path == null);
}

test "workspace scan skips dependency/build trees and hidden directories" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "src", .default_dir);
    try temporary.dir.createDir(io, "zig-pkg", .default_dir);
    try temporary.dir.createDir(io, ".git", .default_dir);
    try temporary.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = "zig-pkg/ignored.zig", .data = "" });
    try temporary.dir.writeFile(io, .{ .sub_path = ".git/ignored", .data = "" });
    var path_buffer: [4096]u8 = undefined;
    const root = path_buffer[0..try temporary.dir.realPath(io, &path_buffer)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.scan();
    try workspace.scan();
    try std.testing.expectEqual(@as(usize, 1), workspace.files.items.len);
    try std.testing.expectEqualStrings("src/main.zig", workspace.files.items[0]);
}

test "saving through a symlink retains the link and executable permissions" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "target", .data = "old" });
    const original = try temporary.dir.openFile(io, "target", .{});
    try original.setPermissions(io, .executable_file);
    const permissions = (try original.stat(io)).permissions;
    original.close(io);
    try temporary.dir.symLink(io, "target", "link", .{});
    var path_buffer: [4096]u8 = undefined;
    const root = path_buffer[0..try temporary.dir.realPath(io, &path_buffer)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.open("link");
    workspace.current().anchor = workspace.current().buffer.len();
    try workspace.current().insert("new");
    try workspace.save("link");
    const link_stat = try temporary.dir.statFile(io, "link", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, link_stat.kind);
    try std.testing.expectEqual(permissions, (try temporary.dir.statFile(io, "target", .{})).permissions);
    const saved = try temporary.dir.readFileAlloc(io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("new", saved);
}

test "failed save leaves the original file and dirty state intact" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "original", .data = "original" });
    var path_buffer: [4096]u8 = undefined;
    const root = path_buffer[0..try temporary.dir.realPath(io, &path_buffer)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.open("original");
    try workspace.current().insert("modified ");
    try std.testing.expectError(error.FileNotFound, workspace.save("missing/file"));
    try std.testing.expect(workspace.current().dirty());
    const saved = try temporary.dir.readFileAlloc(io, "original", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("original", saved);
}

test "external changes and deletions prevent overwriting an open document" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "initial" });
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.open("file");
    try workspace.current().insert("edited");
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "external change" });
    try std.testing.expectError(error.ExternalFileChanged, workspace.save(null));
    try std.testing.expect(workspace.current().dirty());
    const contents = try tmp.dir.readFileAlloc(io, "file", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("external change", contents);
    try tmp.dir.deleteFile(io, "file");
    try std.testing.expectError(error.ExternalFileChanged, workspace.save(null));
}

test "save as rejects a target owned by another document through an alias" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "first", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second", .data = "second" });
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.open("first");
    try workspace.open("second");
    try workspace.current().insert("edited");
    try std.testing.expectError(error.DocumentAlreadyOpen, workspace.save("./first"));
    try std.testing.expect(workspace.current().dirty());
    const contents = try tmp.dir.readFileAlloc(io, "first", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("first", contents);
}

test "new save retains atomic creation permissions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var baseline = try tmp.dir.createFileAtomic(io, "baseline", .{ .replace = false, .permissions = .default_file });
    defer baseline.deinit(io);
    const permissions = (try baseline.file.stat(io)).permissions;
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.newDocument();
    try workspace.current().insert("new");
    try workspace.save("new");
    try std.testing.expectEqual(permissions, (try tmp.dir.statFile(io, "new", .{})).permissions);
}

test "save refuses a dangling symlink without replacing it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "missing", "link", .{});
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.newDocument();
    try workspace.current().insert("new");
    try std.testing.expectError(error.DanglingSymlink, workspace.save("link"));
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try tmp.dir.statFile(io, "link", .{ .follow_symlinks = false })).kind);
    try std.testing.expect(workspace.current().dirty());
}

test "new destination appearing before commit is preserved" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    var file = try tmp.dir.createFileAtomic(io, "target", .{ .replace = false });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, "ours");
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "theirs" });
    try std.testing.expectError(error.ExternalFileChanged, workspace.commitSave(&file, "target", null));
    const contents = try tmp.dir.readFileAlloc(io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("theirs", contents);
}

test "save as expectation rejects a changed or unexpected target" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "old" });
    const identity = Document.DiskIdentity.fromStat(try tmp.dir.statFile(io, "target", .{}));
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.newDocument();
    try workspace.current().insert("ours");
    try std.testing.expectError(error.ExternalFileChanged, workspace.saveWithExpectation("target", .absent));
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "changed externally" });
    try std.testing.expectError(error.ExternalFileChanged, workspace.saveWithExpectation("target", .{ .existing = identity }));
    const contents = try tmp.dir.readFileAlloc(io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("changed externally", contents);
    try std.testing.expect(workspace.current().dirty());
}

test "replacement target changed before commit is preserved" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "original" });
    const identity = Document.DiskIdentity.fromStat(try tmp.dir.statFile(io, "target", .{}));
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    var file = try tmp.dir.createFileAtomic(io, "target", .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, "ours");
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "external change" });
    const absolute = try std.fs.path.join(std.testing.allocator, &.{ root, "target" });
    defer std.testing.allocator.free(absolute);
    try std.testing.expectError(error.ExternalFileChanged, workspace.commitSave(&file, absolute, identity));
    const contents = try tmp.dir.readFileAlloc(io, "target", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("external change", contents);
}

test "large files open bounded read only, navigate, index and close" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "huge", .{});
    const end: u64 = 5 * 1024 * 1024 * 1024;
    try file.writePositionalAll(io, "end\n", end);
    file.close(io);
    var buf: [4096]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    var workspace = try Workspace.init(std.testing.allocator, io, root);
    defer workspace.deinit();
    try workspace.open("huge");
    const doc = workspace.current();
    try std.testing.expect(doc.large != null);
    try std.testing.expectEqual(@as(usize, 0), doc.buffer.len());
    try std.testing.expectError(error.ReadOnlyLargeFile, doc.insert("x"));
    try std.testing.expectError(error.ReadOnlyLargeFile, doc.replaceRange(0, 0, "x"));
    try std.testing.expectError(error.ReadOnlyLargeFile, doc.undo());
    try std.testing.expectError(error.ReadOnlyLargeFile, workspace.save(null));
    try std.testing.expectError(error.ReadOnlyLargeFile, workspace.save("other"));
    doc.largeNavigate(end);
    var window: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try doc.large.?.file.readWindow(io, doc.large.?.offset, &window));
    try std.testing.expectEqualStrings("end\n", &window);
    _ = try doc.large.?.file.indexStep(io, 65536);
    try std.testing.expectEqual(@as(u64, 65536), doc.large.?.file.indexedBytes());
    const changed = try tmp.dir.openFile(io, "huge", .{ .mode = .write_only });
    try changed.setLength(io, 1);
    changed.close(io);
    try std.testing.expectError(error.FileChanged, doc.large.?.file.readWindow(io, 0, &window));
    try std.testing.expectError(error.FileChanged, doc.large.?.file.readWindow(io, 0, &window));
    try workspace.closeActive();
    try std.testing.expect(workspace.current().large == null);
}
