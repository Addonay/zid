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

fn options(app: *App, kind: pickers.Kind) picker_view.Options {
    return switch (kind) {
        // command_palette.rs `initial_width(rems(38.0))` with Change/Add Keybinding + Run.
        .command_palette => .{ .placeholder = kind.placeholder(), .width = 608, .row_h = 33, .footer = .command_palette, .has_binding = paletteHasBinding(app) },
        .file_finder => .{ .placeholder = kind.placeholder(), .footer = .file_finder, .preview = app.picker_preview },
        else => .{ .placeholder = kind.placeholder() },
    };
}
fn paletteHasBinding(app: *App) bool {
    const p = switch (app.modal) {
        .picker => |*p| p,
        else => return false,
    };
    if (p.kind != .command_palette or p.entries.items.len == 0) return false;
    const c = commands.all()[p.entries.items[@min(p.selected, p.entries.items.len - 1)].index];
    var path_buf: [6]keymap.Context = undefined;
    var ext_buf: [16]u8 = undefined;
    const saved = app.modal;
    app.modal = .none;
    defer app.modal = saved;
    return app.keymap.chordFor(@tagName(c), commands.focusPath(app, &path_buf, &ext_buf)) != null;
}
/// Footer keybinding texts in the picker's own context (Zed resolves them there).
fn footerKeys(app: *App, arena: std.mem.Allocator, opts: *picker_view.Options) !void {
    var path_buf: [6]keymap.Context = undefined;
    var ext_buf: [16]u8 = undefined;
    const path = commands.focusPath(app, &path_buf, &ext_buf);
    const lookup = struct {
        fn f(a: *App, ar: std.mem.Allocator, p: []keymap.Context, action: []const u8, fallback: []const u8) ![]const u8 {
            return if (a.keymap.chordFor(action, p)) |chord| try chordText(ar, chord) else fallback;
        }
    }.f;
    opts.keys = .{
        .secondary_confirm = try lookup(app, arena, path, "menu::SecondaryConfirm", "Ctrl-Enter"),
        .confirm = try lookup(app, arena, path, "menu::Confirm", "Enter"),
        .toggle_preview = try lookup(app, arena, path, "picker::TogglePreview", "Ctrl-Alt-P"),
        .actions = try lookup(app, arena, path, "picker::ToggleActionsMenu", "Ctrl-Shift-A"),
    };
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
            const doc = app.workspace.currentOrNull() orelse {
                app.closeModal();
                return;
            };
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
                        // Zed shows the directory with the worktree name prefixed and a trailing slash.
                        const dir = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.fs.path.basename(app.workspace.root), path[0..base_start] });
                        const shift: u16 = @intCast(std.fs.path.basename(app.workspace.root).len + 1);
                        const detail_positions = try arena.alloc(u16, split.detail.len);
                        for (split.detail, detail_positions) |d, *o| o.* = d + shift;
                        item = .{ .label = path[base_start..], .detail = dir, .icon = icon.svg, .icon_colored = icon.colored, .label_positions = split.label, .detail_positions = detail_positions, .history = pickers.inHistory(app, entry.index) };
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
            var opts = options(app, p.kind);
            try footerKeys(app, arena, &opts);
            const g = try picker_view.draw(&app.renderer, app.settings.theme, window(app), &p.input, items.items, p.selected, &p.scroll, &p.follow, opts, app.caret_visible, .{ app.mouse_x, app.mouse_y });
            if (g.preview.w > 0 and p.entries.items.len > 0) try drawPreview(app, g.preview, p.entries.items[@min(p.selected, p.entries.items.len - 1)].index);
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
            var opts = options(app, p.kind);
            try footerKeys(app, app.frame_arena.allocator(), &opts);
            const geo = picker_view.geometry(window(app), p.entries.items.len, opts);
            var buf: [4]picker_view.FooterHit = undefined;
            for (picker_view.footerButtons(&app.renderer, geo, opts, &buf)) |hit| if (hit.rect.contains(mx, my)) {
                switch (hit.button) {
                    .run => try app.menuCommand(.@"menu::Confirm"),
                    .change_keybinding => try openKeybindingFor(app),
                    .toggle_preview => app.picker_preview = !app.picker_preview,
                    .actions => app.notice("File finder actions menu is not implemented yet", .{}),
                }
                return true;
            };
            if (picker_view.itemAt(window(app), p.entries.items.len, p.scroll, opts, mx, my)) |i| {
                p.selected = i;
                try app.menuCommand(.@"menu::Confirm");
            } else if (!geo.modal.contains(mx, my)) app.closeModal();
            return true;
        },
    }
}

/// Mouse wheel over an open picker scrolls the list; the selection stays put.
pub fn scrollModal(app: *App, dy: f32) bool {
    switch (app.modal) {
        .picker => |*p| {
            const steps: usize = @intFromFloat(@max(1, @abs(dy) * 3));
            if (dy > 0) p.scroll += steps else p.scroll -|= steps;
            p.follow = false;
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
    // A new query clears the selection; Zed highlights nothing until you navigate.
    app.keymap_view.selected = 0;
    app.keymap_view.has_selection = false;
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
    if (keymap_editor.rowAt(area, &app.keymap_view, mx, my)) |row| {
        app.keymap_view.selected = row;
        app.keymap_view.has_selection = true;
    }
    return true;
}

pub fn scrollKeymap(app: *App, dy: f32) void {
    keymap_editor.moveSelection(&app.keymap_view, if (dy > 0) 3 else -3);
}

/// Mouse movement over a picker row selects it: Zed shows one highlight that follows
/// the pointer instead of a separate hover state.
pub fn hoverModal(app: *App, mx: f32, my: f32) void {
    const p = switch (app.modal) {
        .picker => |*p| p,
        else => return,
    };
    const opts = options(app, p.kind);
    if (picker_view.itemAt(window(app), p.entries.items.len, p.scroll, opts, mx, my)) |i| {
        if (i != p.selected) {
            p.selected = i;
            p.follow = false;
        }
    }
}

/// "Change/Add Keybinding…": the keymap editor filtered to the selected action.
fn openKeybindingFor(app: *App) !void {
    const p = switch (app.modal) {
        .picker => |*p| p,
        else => return,
    };
    if (p.entries.items.len == 0) return;
    const c = commands.all()[p.entries.items[@min(p.selected, p.entries.items.len - 1)].index];
    app.closeModal();
    try app.openKeymapEditor();
    app.keymap_view.search.set(@tagName(c));
    try app.lineInputChanged();
}

/// File-finder preview: the selected file with line numbers and syntax colours,
/// like Zed's preview editor (read-only, first screenful).
fn drawPreview(app: *App, area: @import("../layout.zig").Rect, file_index: usize) !void {
    const t = app.settings.theme;
    const r = &app.renderer;
    if (app.preview_file != file_index) {
        app.gpa.free(app.preview_bytes);
        app.preview_bytes = &.{};
        app.preview_file = file_index;
        const full = try std.fs.path.join(app.gpa, &.{ app.workspace.root, app.workspace.files.items[file_index] });
        defer app.gpa.free(full);
        app.preview_bytes = blk: {
            const file = std.Io.Dir.cwd().openFile(app.io, full, .{}) catch break :blk &.{};
            defer file.close(app.io);
            const buf = try app.gpa.alloc(u8, 64 * 1024);
            const n = file.readPositionalAll(app.io, buf, 0) catch 0;
            break :blk app.gpa.realloc(buf, n) catch buf[0..n];
        };
    }
    const bytes = app.preview_bytes;
    const inner: @import("../layout.zig").Rect = .{ .x = area.x + 1, .y = area.y + 1, .w = area.w - 2, .h = area.h - 2 };
    app.clip(inner);
    defer r.setClip(null);
    if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null) {
        try r.textUi("Binary file", inner.x + 16, inner.y + 30, t.muted);
        return;
    }
    const zid = @import("zid");
    const language = zid.syntax.Language.fromPath(app.workspace.files.items[file_index]);
    const line_h: f32 = @floatFromInt(app.settings.line_height);
    const gutter: f32 = 52;
    var y = inner.y + 8;
    var state: u32 = 0;
    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var number: [16]u8 = undefined;
    while (lines.next()) |raw| : (line_no += 1) {
        if (y > inner.y + inner.h) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const label = try std.fmt.bufPrint(&number, "{d}", .{line_no});
        const baseline = y + line_h / 2 + 5;
        try r.text(label, inner.x + gutter - 12 - r.width(label), baseline, t.line_number);
        var spans: [256]zid.syntax.Span = undefined;
        var sink: zid.syntax.Sink = .init(&spans);
        state = zid.syntax.lexLine(language, state, line, &sink);
        var x = inner.x + gutter;
        var pos: usize = 0;
        for (sink.items()) |span| {
            if (span.start > pos) {
                try r.text(line[pos..span.start], x, baseline, t.editor_foreground);
                x += r.width(line[pos..span.start]);
            }
            const seg = line[span.start..span.end];
            try r.text(seg, x, baseline, t.syntaxColor(span.kind));
            x += r.width(seg);
            pos = span.end;
        }
        if (pos < line.len) try r.text(line[pos..], x, baseline, t.editor_foreground);
        y += line_h;
    }
}
