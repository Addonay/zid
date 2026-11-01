//! Workspace flows that go through prompts and path pickers, after Zed's
//! `Pane::close_item_by_id` / `save_item`, `Workspace::prepare_to_close` and the
//! project panel's remove flow.
//!
//! Path pickers follow `use_system_path_prompts` (default true): the desktop's own
//! dialog through SDL3 (the XDG file-chooser portal on Linux, as Zed uses), otherwise
//! Zid's in-window path dialog. SDL may call back on another thread, so the result is
//! copied into `PathPrompt` and published with an atomic flag that `poll` reads on the
//! UI thread.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("app.zig").App;
const prompt = @import("views/prompt.zig");

pub const Purpose = enum { open_files, open_folder, save_as };
pub const PathPrompt = struct {
    /// 0 idle, 1 waiting for the dialog, 2 result ready.
    status: std.atomic.Value(u8) = .init(0),
    purpose: Purpose = .open_files,
    /// NUL-separated chosen paths.
    result: [16 * 1024]u8 = undefined,
    result_len: usize = 0,
    /// Document (instance id) to save, and whether to close it afterwards.
    doc_instance: u64 = 0,
    close_after: bool = false,
    quit_after: bool = false,
    location: [std.fs.max_path_bytes + 1]u8 = undefined,
};

fn callback(state: ?*PathPrompt, files: ?[]const [*:0]const u8, _: ?usize, err: bool) void {
    const s = state orelse return;
    s.result_len = 0;
    if (!err) if (files) |list| for (list) |item| {
        const path = std.mem.span(item);
        if (s.result_len + path.len + 1 > s.result.len) break;
        @memcpy(s.result[s.result_len..][0..path.len], path);
        s.result[s.result_len + path.len] = 0;
        s.result_len += path.len + 1;
    };
    s.status.store(2, .release);
}

fn location(app: *App, s: *PathPrompt, name: ?[]const u8) [:0]const u8 {
    const text = if (name) |n|
        std.fmt.bufPrintSentinel(&s.location, "{s}/{s}", .{ app.workspace.root, n }, 0) catch return "."
    else
        std.fmt.bufPrintSentinel(&s.location, "{s}/", .{app.workspace.root}, 0) catch return ".";
    return text;
}

/// `workspace::OpenFiles`.
pub fn openFiles(app: *App) !void {
    if (!app.settings.system_path_prompts) return app.pathDialog(.open);
    const s = &app.path_prompt;
    if (s.status.load(.acquire) == 1) return;
    s.* = .{ .purpose = .open_files };
    s.status.store(1, .release);
    sdl.dialog.showOpenFile(PathPrompt, callback, s, app.window, null, location(app, s, null), true);
}
/// `workspace::Open` ("Open Folder..." on Linux).
pub fn openFolder(app: *App) !void {
    if (!app.settings.system_path_prompts) return app.pathDialog(.open);
    const s = &app.path_prompt;
    if (s.status.load(.acquire) == 1) return;
    s.* = .{ .purpose = .open_folder };
    s.status.store(1, .release);
    sdl.dialog.showOpenFolder(PathPrompt, callback, s, app.window, location(app, s, null), false);
}
/// `workspace::SaveAs` for the active document; optionally close it (or quit) after.
pub fn saveAs(app: *App, close_after: bool, quit_after: bool) !void {
    const doc = app.workspace.currentOrNull() orelse return;
    if (!app.settings.system_path_prompts) {
        app.close_after_save = close_after;
        return app.pathDialog(.save);
    }
    const s = &app.path_prompt;
    if (s.status.load(.acquire) == 1) return;
    s.* = .{ .purpose = .save_as, .doc_instance = doc.instance_id, .close_after = close_after, .quit_after = quit_after };
    s.status.store(1, .release);
    const name = if (doc.path) |p| std.fs.path.basename(p) else "untitled";
    sdl.dialog.showSaveFile(PathPrompt, callback, s, app.window, null, location(app, s, name));
}

fn documentIndex(app: *App, instance: u64) ?usize {
    for (app.workspace.documents.items, 0..) |*d, i| if (d.instance_id == instance) return i;
    return null;
}

/// UI-thread half of the path pickers; call once per frame.
pub fn poll(app: *App) !void {
    const s = &app.path_prompt;
    if (s.status.load(.acquire) != 2) return;
    s.status.store(0, .release);
    if (s.result_len == 0) return; // cancelled
    var paths = std.mem.splitScalar(u8, s.result[0 .. s.result_len - 1], 0);
    switch (s.purpose) {
        .open_files => while (paths.next()) |path| {
            app.workspace.open(path) catch |err| app.notice("Open {s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
        },
        .open_folder => if (paths.next()) |path| try app.openProject(path),
        .save_as => if (paths.next()) |path| {
            const index = documentIndex(app, s.doc_instance) orelse return;
            app.workspace.active = index;
            const stat = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch |err| blk: {
                if (err != error.FileNotFound) return err;
                break :blk null;
            };
            // The portal dialog already asked about replacing an existing file.
            const expectation: zid.Workspace.SaveExpectation = if (stat) |st| .{ .existing = zid.Document.DiskIdentity.fromStat(st) } else .absent;
            try app.workspace.saveWithExpectation(path, expectation);
            app.refreshProject() catch {};
            app.notice("Saved {s}", .{std.fs.path.basename(path)});
            if (s.close_after) try app.workspace.closeActive();
            if (s.quit_after) try continueQuit(app);
        },
    }
}

/// Pane close of document `index`: prompt when dirty (Zed `close_item_by_id`).
pub fn closeItem(app: *App, index: usize) !void {
    if (index >= app.workspace.documents.items.len) return;
    app.workspace.active = index;
    if (app.workspace.documents.items[index].dirty()) return prompt.closeItem(app, index);
    try app.workspace.closeActive();
    app.syntax_doc = std.math.maxInt(usize);
}

/// Close every document for which `keep` returns false; dirty ones are prompted for
/// together (Save all / Discard all) when there is more than one, as Zed's pane does.
pub fn closeWhere(app: *App, ctx: anytype, comptime keep: fn (@TypeOf(ctx), usize) bool) !void {
    var dirty: usize = 0;
    var last_dirty: usize = 0;
    for (app.workspace.documents.items, 0..) |*d, i| if (!keep(ctx, i) and d.dirty()) {
        dirty += 1;
        last_dirty = i;
    };
    // Mark the documents to close (by instance id); the prompt answer re-reads the marks.
    app.close_count = 0;
    for (app.workspace.documents.items, 0..) |*d, i| if (!keep(ctx, i) and app.close_count < app.close_ids.len) {
        app.close_ids[app.close_count] = d.instance_id;
        app.close_count += 1;
    };
    if (dirty > 1) return prompt.saveDirty(app, false);
    if (dirty == 1) {
        closeMarkedClean(app);
        return closeItem(app, documentIndex(app, app.workspace.documents.items[last_dirty].instance_id) orelse return);
    }
    closeMarkedClean(app);
}
fn marked(app: *const App, instance: u64) bool {
    return std.mem.indexOfScalar(u64, app.close_ids[0..app.close_count], instance) != null;
}
fn closeMarkedClean(app: *App) void {
    var i = app.workspace.documents.items.len;
    while (i > 0) {
        i -= 1;
        const d = &app.workspace.documents.items[i];
        if (!marked(app, d.instance_id) or d.dirty()) continue;
        app.workspace.active = i;
        app.workspace.closeActive() catch {};
    }
    app.workspace.active = @min(app.workspace.active, app.workspace.documents.items.len -| 1);
    app.syntax_doc = std.math.maxInt(usize);
}

pub const CloseMode = enum { all, clean, others, left, right };
const Keep = struct {
    mode: CloseMode,
    pivot: usize,
    fn keep(k: Keep, i: usize) bool {
        return switch (k.mode) {
            .all, .clean => false,
            .others => i == k.pivot,
            .left => i >= k.pivot,
            .right => i <= k.pivot,
        };
    }
};
/// `pane::Close{All,Clean,Other}Items`, `CloseItemsToThe{Left,Right}` relative to `pivot`.
pub fn closeTabs(app: *App, mode: CloseMode, pivot: usize) !void {
    const k: Keep = .{ .mode = mode, .pivot = pivot };
    if (mode == .clean) {
        app.close_count = 0;
        for (app.workspace.documents.items) |*d| if (app.close_count < app.close_ids.len) {
            app.close_ids[app.close_count] = d.instance_id;
            app.close_count += 1;
        };
        closeMarkedClean(app);
        return;
    }
    try closeWhere(app, k, Keep.keep);
}

/// `zed::Quit`: one dirty item gets the per-item prompt, several the "save all" one.
pub fn quit(app: *App) !void {
    var dirty: usize = 0;
    var index: usize = 0;
    for (app.workspace.documents.items, 0..) |*d, i| if (d.dirty()) {
        dirty += 1;
        index = i;
    };
    if (dirty == 0) {
        app.running = false;
        return;
    }
    app.quitting = true;
    if (dirty == 1) {
        app.workspace.active = index;
        return prompt.closeItem(app, index);
    }
    prompt.saveDirty(app, true);
}
fn continueQuit(app: *App) !void {
    for (app.workspace.documents.items) |*d| if (d.dirty()) return quit(app);
    app.running = false;
}

/// Saves every dirty document with a path; returns the number left (untitled).
fn saveAllWithPaths(app: *App) !usize {
    const active = app.workspace.active;
    defer app.workspace.active = @min(active, app.workspace.documents.items.len -| 1);
    var untitled: usize = 0;
    for (app.workspace.documents.items, 0..) |*d, i| if (d.dirty()) {
        if (d.path == null) {
            untitled += 1;
            continue;
        }
        app.workspace.active = i;
        try app.workspace.save(null);
    };
    return untitled;
}
fn firstUntitledDirty(app: *App) ?usize {
    for (app.workspace.documents.items, 0..) |*d, i| if (d.dirty() and d.path == null) return i;
    return null;
}

pub fn promptAnswered(app: *App, p: prompt.Prompt, index: usize) !void {
    switch (p.kind) {
        .close_item => |doc_index| {
            if (doc_index >= app.workspace.documents.items.len) return;
            app.workspace.active = doc_index;
            const doc = &app.workspace.documents.items[doc_index];
            if (index == 0) {
                // Save: untitled buffers ask for a path first (Zed `save_item` -> SaveAs).
                if (doc.path == null) return saveAs(app, true, app.quitting);
                try app.workspace.save(null);
            } else doc.saved_revision = doc.revision; // Don't Save
            try app.workspace.closeActive();
            app.syntax_doc = std.math.maxInt(usize);
            if (app.quitting) try continueQuit(app);
        },
        .close_dirty, .quit => {
            if (index == 0) {
                if (try saveAllWithPaths(app) > 0) {
                    // Untitled buffers each need a path; ask for the first one.
                    if (firstUntitledDirty(app)) |i| {
                        app.workspace.active = i;
                        return saveAs(app, p.kind == .close_dirty, p.kind == .quit);
                    }
                }
            } else for (app.workspace.documents.items) |*d| {
                d.saved_revision = d.revision;
            }
            if (p.kind == .quit) {
                app.running = false;
                return;
            }
            closeMarkedClean(app);
        },
        .trash, .delete => try removeEntry(app, p.pathText(), p.kind == .trash),
    }
}

/// Removes a project entry: `trash` moves it to the freedesktop.org trash
/// (`$XDG_DATA_HOME/Trash`), otherwise it is deleted. Open documents under it close.
pub fn removeEntry(app: *App, absolute: []const u8, trash: bool) !void {
    const cwd = std.Io.Dir.cwd();
    if (trash) try moveToTrash(app, absolute) else {
        const stat = try cwd.statFile(app.io, absolute, .{ .follow_symlinks = false });
        if (stat.kind == .directory) try cwd.deleteTree(app.io, absolute) else try cwd.deleteFile(app.io, absolute);
    }
    var i = app.workspace.documents.items.len;
    while (i > 0) {
        i -= 1;
        const d = &app.workspace.documents.items[i];
        const path = d.path orelse continue;
        if (!std.mem.startsWith(u8, path, absolute)) continue;
        d.saved_revision = d.revision;
        app.workspace.active = i;
        try app.workspace.closeActive();
    }
    app.syntax_doc = std.math.maxInt(usize);
    try app.refreshProject();
}

/// freedesktop.org Trash specification 1.0: move into `files/` and write a matching
/// `info/<name>.trashinfo` with the original path and deletion date.
fn moveToTrash(app: *App, absolute: []const u8) !void {
    const gpa = app.gpa;
    const env_home = app.env_home orelse return error.NoHome;
    const data_home = app.env_data_home orelse try std.fs.path.join(gpa, &.{ env_home, ".local", "share" });
    defer if (app.env_data_home == null) gpa.free(data_home);
    const files = try std.fs.path.join(gpa, &.{ data_home, "Trash", "files" });
    defer gpa.free(files);
    const info = try std.fs.path.join(gpa, &.{ data_home, "Trash", "info" });
    defer gpa.free(info);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(app.io, files);
    try cwd.createDirPath(app.io, info);
    const base = std.fs.path.basename(absolute);
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        const name = if (attempt == 0) base else try std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ base, attempt });
        const info_path = try std.fmt.allocPrint(gpa, "{s}/{s}.trashinfo", .{ info, name });
        defer gpa.free(info_path);
        const file = cwd.createFile(app.io, info_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        const now = std.Io.Clock.real.now(app.io);
        const secs: u64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
        const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const day = es.getEpochDay().calculateYearDay();
        const md = day.calculateMonthDay();
        const ds = es.getDaySeconds();
        var body: [std.fs.max_path_bytes * 3 + 128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&body);
        try w.writeAll("[Trash Info]\nPath=");
        for (absolute) |c| {
            if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-_.~", c) != null) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
        }
        try w.print("\nDeletionDate={d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
        file.writeStreamingAll(app.io, w.buffered()) catch |err| {
            file.close(app.io);
            return err;
        };
        file.close(app.io);
        const target = try std.fs.path.join(gpa, &.{ files, name });
        defer gpa.free(target);
        cwd.rename(absolute, cwd, target, app.io) catch |err| {
            cwd.deleteFile(app.io, info_path) catch {};
            return err;
        };
        return;
    }
    return error.TrashNameExhausted;
}
