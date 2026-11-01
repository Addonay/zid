//! Project-panel filename input; never creates an untitled buffer or overwrites a file.
const std = @import("std");
const App = @import("app.zig").App;
const LineInput = @import("line_input.zig").LineInput;

pub const State = struct {
    parent: []u8,
    directory: bool,
    row: usize,
    depth: usize,
    input: LineInput = .{},
    /// Zed `project_panel::Rename`: the edited row replaces this entry (relative path,
    /// owned) instead of inserting a new row.
    renaming: ?[]u8 = null,
};

pub fn cancel(app: *App) void {
    if (app.project_edit) |edit| {
        app.gpa.free(edit.parent);
        if (edit.renaming) |original| app.gpa.free(original);
    }
    app.project_edit = null;
}

pub fn begin(app: *App, directory: bool) !void {
    cancel(app);
    var parent: []const u8 = "";
    var depth: usize = 1;
    if (app.panel_row > 0 and app.panel_row - 1 < app.visible.items.len) {
        const entry = &app.project.entries.items[app.visible.items[app.panel_row - 1]];
        parent = if (entry.directory) entry.path else std.fs.path.dirname(entry.path) orelse "";
        depth = entry.depth + (if (entry.directory) @as(usize, 2) else 1);
        if (entry.directory) entry.collapsed = false;
    }
    const owned = try app.gpa.dupe(u8, parent);
    errdefer app.gpa.free(owned);
    app.project_collapsed = false;
    try app.project.visible(app.gpa, &app.visible);
    var row: usize = 1;
    if (parent.len > 0) for (app.visible.items, 0..) |index, i| {
        if (std.mem.eql(u8, app.project.entries.items[index].path, parent)) {
            row = i + 2;
            break;
        }
    };
    app.project_edit = .{ .parent = owned, .directory = directory, .row = row, .depth = depth };
    app.panel_row = row;
    app.panel_focus = true;
    app.panel_open = true;
    app.keymap_editor_open = false;
    app.keepPanelVisible();
}

/// Starts renaming the entry at visible panel `row` (1-based; 0 is the root). The name
/// is prefilled with its stem selected, as Zed's rename editor does.
pub fn startRename(app: *App, row: usize) !void {
    cancel(app);
    if (row == 0 or row - 1 >= app.visible.items.len) return;
    const entry = &app.project.entries.items[app.visible.items[row - 1]];
    const parent = try app.gpa.dupe(u8, std.fs.path.dirname(entry.path) orelse "");
    errdefer app.gpa.free(parent);
    const original = try app.gpa.dupe(u8, entry.path);
    errdefer app.gpa.free(original);
    app.project_edit = .{ .parent = parent, .directory = entry.directory, .row = row, .depth = entry.depth + 1, .renaming = original };
    const name = std.fs.path.basename(entry.path);
    const input = &app.project_edit.?.input;
    input.set(name);
    const ext = if (entry.directory) "" else std.fs.path.extension(name);
    input.anchor = 0;
    input.cursor = if (ext.len > 0 and ext.len < name.len) name.len - ext.len else name.len;
    app.panel_row = row;
    app.panel_focus = true;
    app.panel_open = true;
}

fn rename(app: *App, original: []const u8, name: []const u8) !void {
    const edit = app.project_edit.?;
    const from = try std.fs.path.join(app.gpa, &.{ app.workspace.root, original });
    defer app.gpa.free(from);
    const to = try std.fs.path.join(app.gpa, &.{ app.workspace.root, edit.parent, name });
    defer app.gpa.free(to);
    cancel(app);
    if (std.mem.eql(u8, from, to)) return;
    const cwd = std.Io.Dir.cwd();
    if (cwd.statFile(app.io, to, .{ .follow_symlinks = false })) |_| return error.PathAlreadyExists else |err| if (err != error.FileNotFound) return err;
    try cwd.rename(from, cwd, to, app.io);
    // Open buffers follow the rename (Zed updates their File).
    for (app.workspace.documents.items) |*doc| {
        const path = doc.path orelse continue;
        const inside = std.mem.startsWith(u8, path, from) and (path.len == from.len or path[from.len] == '/');
        if (!inside) continue;
        const updated = try std.fmt.allocPrintSentinel(doc.allocator, "{s}{s}", .{ to, path[from.len..] }, 0);
        doc.allocator.free(path);
        doc.path = updated;
    }
    try app.refreshProject();
}

pub fn confirm(app: *App) !void {
    const edit = &(app.project_edit orelse return);
    const name = edit.input.text();
    if (name.len == 0) return;
    if (std.fs.path.isAbsolute(name)) return error.InvalidFilename;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidFilename;
    }
    if (edit.renaming) |original| return rename(app, original, name);
    const path = try std.fs.path.join(app.gpa, &.{ app.workspace.root, edit.parent, name });
    defer app.gpa.free(path);
    if (edit.directory) {
        try std.Io.Dir.cwd().createDir(app.io, path, .default_dir);
    } else {
        const file = try std.Io.Dir.cwd().createFile(app.io, path, .{ .exclusive = true });
        file.close(app.io);
    }
    const directory = edit.directory;
    cancel(app);
    try app.refreshProject();
    if (!directory) {
        try app.workspace.open(path);
        app.panel_focus = false;
    } else {
        const rel = path[app.workspace.root.len + 1 ..];
        for (app.visible.items, 0..) |index, row| {
            if (std.mem.eql(u8, app.project.entries.items[index].path, rel)) {
                app.panel_row = row + 1;
                break;
            }
        }
    }
}
