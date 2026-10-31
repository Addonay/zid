//! Picker controllers (Zed's file finder, command palette, recent projects, tab switcher)
//! and go-to-line. State, candidate sources, fuzzy filtering and confirm behavior live here;
//! drawing is `views/picker_view.zig`.
const std = @import("std");
const zid = @import("zid");
const App = @import("../app.zig").App;
const LineInput = @import("../line_input.zig").LineInput;
const fuzzy = @import("../fuzzy.zig");
const commands = @import("commands.zig");

pub const Kind = enum {
    file_finder,
    command_palette,
    recent_projects,
    tab_switcher,

    /// GPUI context name, so the keymap's `FileFinder`, `CommandPalette`, ... sections apply.
    pub fn contextName(self: Kind) []const u8 {
        return switch (self) {
            .file_finder => "FileFinder",
            .command_palette => "CommandPalette",
            .recent_projects => "RecentProjects",
            .tab_switcher => "TabSwitcher",
        };
    }
    pub fn placeholder(self: Kind) []const u8 {
        return switch (self) {
            .file_finder => "Search project files...",
            .command_palette => "Execute a command...",
            .recent_projects => "Search recent projects...",
            .tab_switcher => "Search open tabs...",
        };
    }
};

pub const Entry = struct {
    /// Index into the kind's candidate list.
    index: usize,
    score: i32,
    match: fuzzy.Match,
};

pub const Picker = struct {
    kind: Kind,
    input: LineInput = .{},
    selected: usize = 0,
    scroll: usize = 0,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Picker, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }
};

pub const GoToLine = struct {
    input: LineInput = .{},
    /// Selection and scroll to restore on cancel (Zed previews the target while typing).
    restore_cursor: usize = 0,
    restore_anchor: usize = 0,
    restore_scroll: usize = 0,
};

pub const max_results = 200;

/// Zed command palette naming: "editor::MoveToBeginningOfLine" -> "editor: move to beginning of line".
pub fn humanize(action: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    const sep = std.mem.indexOf(u8, action, "::");
    const namespace = if (sep) |i| action[0..i] else "";
    const name = if (sep) |i| action[i + 2 ..] else action;
    for (namespace) |c| {
        if (n == buf.len) return buf[0..n];
        buf[n] = if (c == '_') ' ' else c;
        n += 1;
    }
    if (namespace.len > 0 and n + 2 <= buf.len) {
        buf[n] = ':';
        buf[n + 1] = ' ';
        n += 2;
    }
    for (name, 0..) |c, i| {
        if (n + 2 > buf.len) break;
        if (std.ascii.isUpper(c) and i > 0 and (std.ascii.isLower(name[i - 1]) or (i + 1 < name.len and std.ascii.isLower(name[i + 1])))) {
            buf[n] = ' ';
            n += 1;
        }
        buf[n] = if (c == '_') ' ' else std.ascii.toLower(c);
        n += 1;
    }
    return buf[0..n];
}

/// Number of candidates for a picker kind.
pub fn candidateCount(app: *App, kind: Kind) usize {
    return switch (kind) {
        .file_finder => app.workspace.files.items.len,
        .command_palette => commands.all().len,
        .recent_projects => app.recentCount(),
        .tab_switcher => app.workspace.documents.items.len,
    };
}

/// Text matched against the query (written into `buf` when it must be generated).
pub fn candidateText(app: *App, kind: Kind, index: usize, buf: []u8) []const u8 {
    return switch (kind) {
        .file_finder => app.workspace.files.items[index],
        .command_palette => humanize(@tagName(commands.all()[index]), buf),
        .recent_projects => app.recentPath(index),
        .tab_switcher => tabName(app, tabOrder(app, index)),
    };
}

pub fn tabName(app: *App, doc_index: usize) []const u8 {
    const doc = &app.workspace.documents.items[doc_index];
    return if (doc.path) |p| std.fs.path.basename(p) else "untitled";
}

/// Tab switcher order: most recently used first (Zed lists the active tab, then previous ones).
pub fn tabOrder(app: *App, index: usize) usize {
    const count = app.workspace.documents.items.len;
    return (app.workspace.active + index) % count;
}

/// Recomputes entries from the query.
pub fn refilter(app: *App, picker: *Picker) !void {
    const gpa = app.gpa;
    picker.entries.clearRetainingCapacity();
    const query = picker.input.text();
    const count = candidateCount(app, picker.kind);
    var buf: [256]u8 = undefined;
    for (0..count) |i| {
        if (picker.kind == .recent_projects and app.isCurrentProject(i)) continue;
        const text = candidateText(app, picker.kind, i, &buf);
        if (query.len == 0) {
            if (picker.entries.items.len >= max_results and picker.kind == .file_finder) break;
            try picker.entries.append(gpa, .{ .index = i, .score = 0, .match = .{ .score = 0 } });
            continue;
        }
        const m = fuzzy.match(query, text) orelse continue;
        try picker.entries.append(gpa, .{ .index = i, .score = m.score, .match = m });
    }
    if (query.len > 0) {
        std.mem.sort(Entry, picker.entries.items, {}, struct {
            fn better(_: void, a: Entry, b: Entry) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.index < b.index;
            }
        }.better);
        if (picker.entries.items.len > max_results) picker.entries.shrinkRetainingCapacity(max_results);
    } else if (picker.kind == .file_finder) {
        // Empty query: open files first, like Zed's history section.
        try promoteOpenFiles(app, picker);
    }
    picker.selected = if (picker.kind == .tab_switcher and query.len == 0 and picker.entries.items.len > 1) 1 else 0;
    picker.scroll = 0;
}

fn promoteOpenFiles(app: *App, picker: *Picker) !void {
    var front: usize = 0;
    for (app.workspace.documents.items) |*doc| {
        const path = doc.path orelse continue;
        const rel = relativeToRoot(app.workspace.root, path) orelse continue;
        for (app.workspace.files.items, 0..) |file, fi| if (std.mem.eql(u8, file, rel)) {
            // Move (or insert) this file to the front.
            var found: ?usize = null;
            for (picker.entries.items, 0..) |e, ei| if (e.index == fi) {
                found = ei;
                break;
            };
            const entry: Entry = .{ .index = fi, .score = 0, .match = .{ .score = 0 } };
            if (found) |ei| _ = picker.entries.orderedRemove(ei);
            try picker.entries.insert(app.gpa, @min(front, picker.entries.items.len), entry);
            front += 1;
            break;
        };
    }
}

pub fn relativeToRoot(root: []const u8, path: []const u8) ?[]const u8 {
    if (path.len <= root.len + 1 or !std.mem.startsWith(u8, path, root) or path[root.len] != '/') return null;
    return path[root.len + 1 ..];
}

/// Parses go-to-line input "row", "row:col" or ":col" (1-based) into a document offset.
pub fn goToLineTarget(doc: *const zid.Document, text: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, text, " ");
    if (trimmed.len == 0) return null;
    var parts = std.mem.splitScalar(u8, trimmed, ':');
    const row_text = parts.next() orelse "";
    const col_text = parts.next() orelse "";
    const current_row = doc.lineOf(doc.cursor);
    const row: usize = if (row_text.len == 0) current_row else ((std.fmt.parseInt(usize, row_text, 10) catch return null) -| 1);
    const clamped = @min(row, doc.lineCount() - 1);
    const start = doc.lineStart(clamped);
    const col: usize = if (col_text.len == 0) 0 else ((std.fmt.parseInt(usize, col_text, 10) catch return null) -| 1);
    var offset = start;
    var i: usize = 0;
    const end = doc.lineEnd(clamped);
    while (i < col and offset < end) : (i += 1) offset = doc.buffer.next(offset);
    return offset;
}

test "humanize matches Zed's command palette names" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("editor: move to beginning of line", humanize("editor::MoveToBeginningOfLine", &buf));
    try std.testing.expectEqualStrings("go to line: toggle", humanize("go_to_line::Toggle", &buf));
    try std.testing.expectEqualStrings("zed: open keymap", humanize("zed::OpenKeymap", &buf));
}

test "go to line accepts row, row:col and clamps" {
    var doc = try zid.Document.init(std.testing.allocator, "ab\ncdef\ng", null);
    defer doc.deinit();
    try std.testing.expectEqual(@as(?usize, 3), goToLineTarget(&doc, "2"));
    try std.testing.expectEqual(@as(?usize, 5), goToLineTarget(&doc, "2:3"));
    try std.testing.expectEqual(@as(?usize, 8), goToLineTarget(&doc, "99"));
    try std.testing.expectEqual(@as(?usize, null), goToLineTarget(&doc, "x"));
}
