//! Adapts picker / go-to-line / keymap-editor state into the delegated views
//! (`picker_view.zig`, `keymap_editor.zig`) and routes their mouse input.
const std = @import("std");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const picker_view = @import("picker_view.zig");
const keymap_editor = @import("keymap_editor.zig");
const keymap = @import("../keymap.zig");
const pickers = @import("../input/pickers.zig");
const commands = @import("../input/commands.zig");
const icons = @import("icons");

fn window(app: *App) Rect {
    return .{ .w = app.layout.width, .h = app.layout.height };
}

fn options(kind: pickers.Kind) picker_view.Options {
    return .{ .placeholder = kind.placeholder() };
}

/// Splits match positions on a full path into basename (label) and directory (detail) parts.
fn splitPositions(arena: std.mem.Allocator, positions: []const u16, base_start: usize) !struct { label: []u16, detail: []u16 } {
    var label: std.ArrayList(u16) = .empty;
    var detail: std.ArrayList(u16) = .empty;
    for (positions) |p| {
        if (p >= base_start) try label.append(arena, @intCast(p - base_start)) else try detail.append(arena, p);
    }
    return .{ .label = label.items, .detail = detail.items };
}

fn chordText(arena: std.mem.Allocator, chord: keymap.Chord) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try chord.format(&aw.writer);
    return aw.written();
}

pub fn drawModal(app: *App) !void {
    const arena = app.frame_arena.allocator();
    switch (app.modal) {
        .none => {},
        .go_to_line => |*g| {
            const doc = app.workspace.current();
            const row = doc.lineOf(doc.cursor);
            const footer = if (doc.large != null) "Line, b<offset>, or percentage (e.g. 50%)" else try std.fmt.allocPrint(arena, "Current Line: {d} of {d} (column {d})", .{ row + 1, doc.lineCount(), doc.cursor - doc.lineStart(row) + 1 });
            try picker_view.drawGoToLine(&app.renderer, app.settings.theme, window(app), &g.input, footer, app.caret_visible);
        },
        .picker => |*p| {
            var items: std.ArrayList(picker_view.Item) = .empty;
            var path_buf: [6]keymap.Context = undefined;
            var ext_buf: [16]u8 = undefined;
            // Keybinding hints as they apply in the editor (Zed shows the binding for the focused item).
            const saved_modal = app.modal;
            app.modal = .none;
            const hint_path = commands.focusPath(app, &path_buf, &ext_buf);
            app.modal = saved_modal;
            for (p.entries.items) |entry| {
                var item: picker_view.Item = .{ .label = "" };
                switch (p.kind) {
                    .file_finder => {
                        const path = app.workspace.files.items[entry.index];
                        const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
                        const split = try splitPositions(arena, entry.match.slice(), base_start);
                        const icon = app.fileIcon(path);
                        item = .{ .label = path[base_start..], .detail = path[0..base_start -| 1], .icon = icon.svg, .icon_colored = icon.colored, .label_positions = split.label, .detail_positions = split.detail };
                    },
                    .command_palette => {
                        const c = commands.all()[entry.index];
                        const label = try arena.dupe(u8, pickers.humanize(@tagName(c), try arena.alloc(u8, 128)));
                        const hint = if (app.keymap.chordFor(@tagName(c), hint_path)) |chord| try chordText(arena, chord) else "";
                        item = .{ .label = label, .label_positions = try arena.dupe(u16, entry.match.slice()), .hint = hint };
                    },
                    .recent_projects => {
                        const path = app.recentPath(entry.index);
                        const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0;
                        const split = try splitPositions(arena, entry.match.slice(), base_start);
                        item = .{ .label = path[base_start..], .detail = path, .icon = icons.svg("folder"), .label_positions = split.label };
                    },
                    .tab_switcher => {
                        const doc_index = pickers.tabOrder(app, entry.index);
                        const doc = &app.workspace.documents.items[doc_index];
                        const dir = if (doc.path) |path| (pickers.relativeToRoot(app.workspace.root, std.fs.path.dirname(path) orelse "") orelse std.fs.path.dirname(path) orelse "") else "";
                        item = .{ .label = pickers.tabName(app, doc_index), .detail = dir, .icon = app.fileIcon(doc.path orelse "").svg, .icon_colored = app.fileIcon(doc.path orelse "").colored, .label_positions = try arena.dupe(u16, entry.match.slice()), .hint = if (doc.dirty()) "●" else "" };
                    },
                }
                try items.append(arena, item);
            }
            try picker_view.draw(&app.renderer, app.settings.theme, window(app), &p.input, items.items, p.selected, &p.scroll, options(p.kind), app.caret_visible, .{ app.mouse_x, app.mouse_y });
        },
    }
}

/// Mouse click while a modal is open. Returns true when the click was consumed.
pub fn clickModal(app: *App, mx: f32, my: f32) !bool {
    switch (app.modal) {
        .none => return false,
        .go_to_line => {
            app.closeModal();
            return true;
        },
        .picker => |*p| {
            const geo = picker_view.geometry(window(app), p.entries.items.len, options(p.kind));
            if (picker_view.itemAt(window(app), p.entries.items.len, p.scroll, options(p.kind), mx, my)) |i| {
                p.selected = i;
                try app.menuCommand(.@"menu::Confirm");
            } else if (!geo.modal.contains(mx, my)) app.closeModal();
            return true;
        },
    }
}

/// Mouse wheel over an open picker moves the selection.
pub fn scrollModal(app: *App, dy: f32) bool {
    switch (app.modal) {
        .picker => |*p| {
            const count = p.entries.items.len;
            if (count == 0) return true;
            if (dy > 0) p.selected = @min(count - 1, p.selected + 1) else p.selected -|= 1;
            return true;
        },
        .go_to_line => return true,
        .none => return false,
    }
}

// ---------------------------------------------------------------- keymap editor

fn implemented(_: *anyopaque, action: []const u8) bool {
    return commands.parse(action) != null;
}

pub fn drawKeymapEditor(app: *App) !void {
    const area = try app.layout.rect(app.layout.editor);
    try app.fill(area, app.settings.theme.editor);
    try keymap_editor.draw(&app.renderer, app.settings.theme, area, &app.keymap, &app.keymap_view, .{ .ctx = app, .implemented = implemented }, .{ app.mouse_x, app.mouse_y }, app.caret_visible);
}

pub fn refilterKeymap(app: *App) !void {
    // A new query selects its best match.
    app.keymap_view.selected = 0;
    app.keymap_view.scroll = 0;
    try keymap_editor.refilter(&app.keymap_view, app.gpa, &app.keymap);
}

pub fn keymapMenu(app: *App, c: commands.Command) void {
    switch (c) {
        .@"menu::SelectNext" => keymap_editor.moveSelection(&app.keymap_view, 1),
        .@"menu::SelectPrevious" => keymap_editor.moveSelection(&app.keymap_view, -1),
        .@"menu::SelectFirst" => keymap_editor.moveSelection(&app.keymap_view, -std.math.maxInt(i32)),
        .@"menu::SelectLast" => keymap_editor.moveSelection(&app.keymap_view, std.math.maxInt(i32)),
        .@"menu::Cancel" => app.keymap_editor_open = false,
        else => {},
    }
}

pub fn clickKeymap(app: *App, mx: f32, my: f32) bool {
    const area = app.layout.rect(app.layout.editor) catch return false;
    if (!area.contains(mx, my)) return false;
    if (keymap_editor.rowAt(area, &app.keymap_view, mx, my)) |row| app.keymap_view.selected = row;
    return true;
}

pub fn scrollKeymap(app: *App, dy: f32) void {
    keymap_editor.moveSelection(&app.keymap_view, if (dy > 0) 3 else -3);
}
