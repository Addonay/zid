//! Zed action registry: every action Zid implements is named exactly as in Zed
//! (`editor::MoveLeft`, `workspace::Save`, ...), so the bundled Zed keymap and users'
//! Zed-format keymap.json files drive Zid directly.
//!
//! `available` mirrors GPUI's action availability: a keystroke resolves to the
//! highest-precedence binding whose action is available for the current focus, which is
//! how the global `up` -> `menu::SelectPrevious` coexists with the editor's `up`.
//! `focusPath` builds the context path (Workspace > Pane > Editor, Workspace > ProjectPanel, ...).
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const keymap = @import("../keymap.zig");
const LineInput = @import("../line_input.zig").LineInput;
const ed = zid.commands;

pub const Command = enum {
    // workspace / app
    @"workspace::Save",
    @"workspace::SaveAs",
    @"workspace::SaveAll",
    @"workspace::NewFile",
    @"workspace::OpenFiles",
    @"workspace::ToggleLeftDock",
    @"workspace::CloseWindow",
    @"zed::Quit",
    @"zed::OpenSettings",
    @"zed::OpenSettingsFile",
    @"zed::OpenKeymap",
    @"zed::OpenKeymapFile",
    @"zed::IncreaseBufferFontSize",
    @"zed::DecreaseBufferFontSize",
    @"zed::ResetBufferFontSize",
    @"zed::ToggleFullScreen",
    @"zid::ReloadConfiguration",
    @"file_finder::Toggle",
    @"command_palette::Toggle",
    @"go_to_line::Toggle",
    @"projects::OpenRecent",
    @"tab_switcher::Toggle",
    @"project_panel::ToggleFocus",
    @"buffer_search::Deploy",
    @"buffer_search::Dismiss",
    @"search::SelectNextMatch",
    @"search::SelectPreviousMatch",
    @"search::FocusSearch",
    // panes / tabs
    @"pane::CloseActiveItem",
    @"pane::CloseAllItems",
    @"pane::CloseCleanItems",
    @"pane::CloseOtherItems",
    @"pane::ActivateNextItem",
    @"pane::ActivatePreviousItem",
    @"pane::ActivateItem",
    @"pane::ActivateLastItem",
    // menus and pickers
    @"menu::SelectNext",
    @"menu::SelectPrevious",
    @"menu::SelectFirst",
    @"menu::SelectLast",
    @"menu::Confirm",
    @"menu::SecondaryConfirm",
    @"menu::Cancel",
    // project panel
    @"project_panel::CollapseSelectedEntry",
    @"project_panel::ExpandSelectedEntry",
    @"project_panel::CollapseAllEntries",
    @"project_panel::Open",
    // editor
    @"editor::Cancel",
    @"editor::Backspace",
    @"editor::Delete",
    @"editor::Tab",
    @"editor::Backtab",
    @"editor::Newline",
    @"editor::NewlineAbove",
    @"editor::NewlineBelow",
    @"editor::Cut",
    @"editor::Copy",
    @"editor::Paste",
    @"editor::Undo",
    @"editor::Redo",
    @"editor::MoveLeft",
    @"editor::MoveRight",
    @"editor::MoveUp",
    @"editor::MoveDown",
    @"editor::MovePageUp",
    @"editor::MovePageDown",
    @"editor::PageUp",
    @"editor::PageDown",
    @"editor::LineUp",
    @"editor::LineDown",
    @"editor::MoveToPreviousWordStart",
    @"editor::MoveToNextWordEnd",
    @"editor::MoveToPreviousSubwordStart",
    @"editor::MoveToNextSubwordEnd",
    @"editor::MoveToBeginningOfLine",
    @"editor::MoveToEndOfLine",
    @"editor::MoveToBeginning",
    @"editor::MoveToEnd",
    @"editor::SelectLeft",
    @"editor::SelectRight",
    @"editor::SelectUp",
    @"editor::SelectDown",
    @"editor::SelectPageUp",
    @"editor::SelectPageDown",
    @"editor::SelectToPreviousWordStart",
    @"editor::SelectToNextWordEnd",
    @"editor::SelectToPreviousSubwordStart",
    @"editor::SelectToNextSubwordEnd",
    @"editor::SelectToBeginningOfLine",
    @"editor::SelectToEndOfLine",
    @"editor::SelectToBeginning",
    @"editor::SelectToEnd",
    @"editor::SelectAll",
    @"editor::SelectLine",
    @"editor::DeleteToPreviousWordStart",
    @"editor::DeleteToNextWordEnd",
    @"editor::DeleteToPreviousSubwordStart",
    @"editor::DeleteToNextSubwordEnd",
    @"editor::DeleteToBeginningOfLine",
    @"editor::DeleteToEndOfLine",
    @"editor::DeleteLine",
    @"editor::MoveLineUp",
    @"editor::MoveLineDown",
    @"editor::DuplicateLineUp",
    @"editor::DuplicateLineDown",
    @"editor::Indent",
    @"editor::Outdent",
    @"editor::ToggleComments",
    @"editor::JoinLines",
    @"editor::CopyPath",
};

pub fn parse(name: []const u8) ?Command {
    return std.meta.stringToEnum(Command, name);
}

/// Where keyboard focus is; decides availability and the context path.
pub const Focus = enum { editor, buffer_search, project_panel, picker, go_to_line, keymap_editor, settings, path_dialog };

pub fn focus(app: *const App) Focus {
    if (app.dialog == .settings) return .settings;
    if (app.dialog != .none) return .path_dialog;
    switch (app.modal) {
        .none => {},
        .picker => return .picker,
        .go_to_line => return .go_to_line,
    }
    if (app.keymap_editor_open) return .keymap_editor;
    if (app.panel_focus and app.panel_open) return .project_panel;
    if (app.search_open and app.search_focused) return .buffer_search;
    return .editor;
}

/// The single-line input that receives editor actions when a modal or view has focus.
pub fn lineInput(app: *App) ?*LineInput {
    return switch (focus(app)) {
        .buffer_search => &app.search_input,
        .picker => &app.modal.picker.input,
        .go_to_line => &app.modal.go_to_line.input,
        .keymap_editor => &app.keymap_view.search,
        else => null,
    };
}

/// Builds the GPUI-style focus path into `buf`.
pub fn focusPath(app: *App, buf: *[6]keymap.Context, ext_buf: *[16]u8) []keymap.Context {
    var n: usize = 0;
    buf[n] = .{ .name = "Workspace" };
    n += 1;
    const single_line = &[_][2][]const u8{.{ "mode", "single_line" }};
    switch (focus(app)) {
        .editor => {
            buf[n] = .{ .name = "Pane" };
            n += 1;
            const ext = std.fs.path.extension(app.workspace.current().path orelse "");
            const e = if (ext.len > 1) ext[1..@min(ext.len, ext_buf.len + 1)] else "";
            @memcpy(ext_buf[0..e.len], e);
            app.focus_pairs = .{ .{ "mode", "full" }, .{ "extension", ext_buf[0..e.len] } };
            buf[n] = .{ .name = "Editor", .pairs = &app.focus_pairs };
            n += 1;
        },
        .buffer_search => {
            buf[n] = .{ .name = "Pane" };
            n += 1;
            buf[n] = .{ .name = "BufferSearchBar" };
            n += 1;
            buf[n] = .{ .name = "Editor", .pairs = single_line };
            n += 1;
        },
        .project_panel => {
            buf[n] = .{ .name = "ProjectPanel", .flags = &.{"not_editing"} };
            n += 1;
        },
        .picker => {
            buf[n] = .{ .name = app.modal.picker.kind.contextName() };
            n += 1;
            buf[n] = .{ .name = "Picker" };
            n += 1;
            buf[n] = .{ .name = "Editor", .pairs = single_line };
            n += 1;
        },
        .go_to_line => {
            buf[n] = .{ .name = "GoToLine" };
            n += 1;
            buf[n] = .{ .name = "Editor", .pairs = single_line };
            n += 1;
        },
        .keymap_editor => {
            buf[n] = .{ .name = "Pane" };
            n += 1;
            buf[n] = .{ .name = "KeymapEditor" };
            n += 1;
            buf[n] = .{ .name = "Editor", .pairs = single_line };
            n += 1;
        },
        .settings => {
            buf[n] = .{ .name = "SettingsWindow" };
            n += 1;
        },
        .path_dialog => {},
    }
    return buf[0..n];
}

fn isEditor(c: Command) bool {
    return std.mem.startsWith(u8, @tagName(c), "editor::");
}
fn isMenu(c: Command) bool {
    return std.mem.startsWith(u8, @tagName(c), "menu::");
}

/// Editor actions a single-line input understands.
fn lineInputCommand(c: Command) bool {
    return switch (c) {
        .@"editor::Backspace", .@"editor::Delete", .@"editor::MoveLeft", .@"editor::MoveRight", .@"editor::SelectLeft", .@"editor::SelectRight", .@"editor::MoveToPreviousWordStart", .@"editor::MoveToNextWordEnd", .@"editor::SelectToPreviousWordStart", .@"editor::SelectToNextWordEnd", .@"editor::MoveToPreviousSubwordStart", .@"editor::MoveToNextSubwordEnd", .@"editor::MoveToBeginningOfLine", .@"editor::MoveToEndOfLine", .@"editor::SelectToBeginningOfLine", .@"editor::SelectToEndOfLine", .@"editor::MoveToBeginning", .@"editor::MoveToEnd", .@"editor::SelectAll", .@"editor::DeleteToPreviousWordStart", .@"editor::DeleteToNextWordEnd", .@"editor::DeleteToPreviousSubwordStart", .@"editor::DeleteToNextSubwordEnd", .@"editor::DeleteToBeginningOfLine", .@"editor::Paste", .@"editor::Copy", .@"editor::Cut" => true,
        else => false,
    };
}

pub fn available(app: *App, c: Command) bool {
    const f = focus(app);
    if (f == .settings or f == .path_dialog) return false;
    if (isEditor(c)) return switch (f) {
        .editor => if (app.workspace.current().large == null) true else switch (c) {
            .@"editor::MoveToBeginning", .@"editor::MoveToEnd", .@"editor::SelectToBeginning", .@"editor::SelectToEnd", .@"editor::SelectAll", .@"editor::Copy", .@"editor::Cancel", .@"editor::MoveUp", .@"editor::LineUp", .@"editor::MoveDown", .@"editor::LineDown", .@"editor::MovePageUp", .@"editor::PageUp", .@"editor::MovePageDown", .@"editor::PageDown", .@"editor::MoveToBeginningOfLine", .@"editor::SelectToBeginningOfLine", .@"editor::MoveToEndOfLine", .@"editor::SelectToEndOfLine", .@"editor::MoveLeft", .@"editor::MoveRight", .@"editor::SelectLeft", .@"editor::SelectRight" => true,
            else => false,
        },
        .picker, .go_to_line, .keymap_editor, .buffer_search => lineInputCommand(c),
        else => false,
    };
    if (isMenu(c)) return switch (f) {
        .picker, .keymap_editor => c != .@"menu::SecondaryConfirm",
        .go_to_line => c == .@"menu::Confirm" or c == .@"menu::Cancel",
        .project_panel => c == .@"menu::SelectNext" or c == .@"menu::SelectPrevious" or c == .@"menu::Cancel" or c == .@"menu::Confirm" or c == .@"menu::SelectFirst" or c == .@"menu::SelectLast",
        else => false,
    };
    return switch (c) {
        .@"buffer_search::Deploy" => f == .editor or f == .buffer_search,
        .@"buffer_search::Dismiss", .@"search::FocusSearch" => f == .buffer_search,
        .@"search::SelectNextMatch", .@"search::SelectPreviousMatch" => f == .editor or f == .buffer_search,
        .@"project_panel::CollapseSelectedEntry", .@"project_panel::ExpandSelectedEntry", .@"project_panel::CollapseAllEntries", .@"project_panel::Open" => f == .project_panel,
        .@"go_to_line::Toggle" => f == .editor or f == .go_to_line,
        .@"pane::ActivateItem", .@"pane::ActivateLastItem", .@"pane::ActivateNextItem", .@"pane::ActivatePreviousItem", .@"pane::CloseActiveItem", .@"pane::CloseAllItems", .@"pane::CloseCleanItems", .@"pane::CloseOtherItems" => f == .editor or f == .project_panel or f == .keymap_editor,
        else => true,
    };
}

fn argInt(arg: ?std.json.Value) ?usize {
    const v = arg orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}
fn argBool(arg: ?std.json.Value, key: []const u8, default: bool) bool {
    const v = arg orelse return default;
    if (v != .object) return default;
    const b = v.object.get(key) orelse return default;
    return if (b == .bool) b.bool else default;
}

/// Runs a command. `arg` is the Zed action argument from the binding, if any.
pub fn run(app: *App, c: Command, arg: ?std.json.Value) anyerror!void {
    if (lineInput(app)) |input| if (isEditor(c)) return runLineInput(app, input, c);
    const doc = app.workspace.current();
    if (doc.large != null and isEditor(c)) {
        const l = &doc.large.?;
        const page: i64 = @intCast(app.pageLines());
        switch (c) {
            .@"editor::MoveToBeginning" => l.move(0, false),
            .@"editor::MoveToEnd" => l.move(l.size, false),
            .@"editor::SelectToBeginning" => l.move(0, true),
            .@"editor::SelectToEnd" => l.move(l.size, true),
            .@"editor::SelectAll" => l.selectAll(),
            .@"editor::Copy" => try l.copy(),
            .@"editor::Cancel" => l.move(l.offset, false),
            .@"editor::SelectUp" => try l.selectLines(-1),
            .@"editor::SelectDown" => try l.selectLines(1),
            .@"editor::MoveUp", .@"editor::LineUp" => try l.moveLines(-1),
            .@"editor::MoveDown", .@"editor::LineDown" => try l.moveLines(1),
            .@"editor::MovePageUp", .@"editor::PageUp" => try l.moveLines(-page),
            .@"editor::MovePageDown", .@"editor::PageDown" => try l.moveLines(page),
            .@"editor::MoveToBeginningOfLine", .@"editor::SelectToBeginningOfLine" => try l.moveBoundary(.start, c == .@"editor::SelectToBeginningOfLine"),
            .@"editor::MoveToEndOfLine", .@"editor::SelectToEndOfLine" => try l.moveBoundary(.end, c == .@"editor::SelectToEndOfLine"),
            .@"editor::MoveLeft" => try l.moveByte(-1, false),
            .@"editor::MoveRight" => try l.moveByte(1, false),
            .@"editor::SelectLeft" => try l.moveByte(-1, true),
            .@"editor::SelectRight" => try l.moveByte(1, true),
            else => return error.UnsupportedLargeFileCommand,
        }
        return;
    }
    if (doc.large != null and c == .@"workspace::SaveAs") return error.ReadOnlyLargeFile;
    const page: i32 = @intCast(app.pageLines());
    switch (c) {
        .@"buffer_search::Deploy", .@"search::FocusSearch" => {
            app.search_open = true;
            app.search_focused = true;
            app.panel_focus = false;
            app.search_input.selectAll();
            try app.updateSearch(false);
        },
        .@"buffer_search::Dismiss" => {
            app.search_open = false;
            app.search_focused = false;
        },
        .@"search::SelectNextMatch" => try app.searchSelect(.next),
        .@"search::SelectPreviousMatch" => try app.searchSelect(.previous),
        .@"workspace::Save" => {
            if (doc.path == null) return app.pathDialog(.save);
            try app.workspace.save(null);
            app.notice("Saved {s}", .{doc.path.?});
        },
        .@"workspace::SaveAs" => try app.pathDialog(.save),
        .@"workspace::SaveAll" => {
            const active = app.workspace.active;
            defer app.workspace.active = active;
            var skipped: usize = 0;
            for (app.workspace.documents.items, 0..) |*d, i| if (d.dirty()) {
                if (d.path == null) {
                    skipped += 1;
                    continue;
                }
                app.workspace.active = i;
                try app.workspace.save(null);
            };
            if (skipped > 0) app.notice("Saved all; {d} untitled document(s) need Save As", .{skipped}) else app.notice("Saved all", .{});
        },
        .@"workspace::NewFile" => {
            try app.workspace.newDocument();
            app.panel_focus = false;
            app.keymap_editor_open = false;
        },
        .@"workspace::OpenFiles" => try app.pathDialog(.open),
        .@"workspace::ToggleLeftDock" => {
            app.panel_open = !app.panel_open;
            app.panel_focus = false;
        },
        .@"workspace::CloseWindow", .@"zed::Quit" => {
            for (app.workspace.documents.items) |*d| if (d.dirty()) {
                app.dialog = .quit;
                return;
            };
            app.running = false;
        },
        .@"zed::OpenSettings" => @import("../views/settings_dialog.zig").open(app),
        .@"zed::OpenSettingsFile" => try app.openConfigFile("settings.json"),
        .@"zed::OpenKeymap" => try app.openKeymapEditor(),
        .@"zed::OpenKeymapFile" => try app.openConfigFile("keymap.json"),
        .@"zed::IncreaseBufferFontSize", .@"zed::DecreaseBufferFontSize", .@"zed::ResetBufferFontSize" => {
            const current = app.settings.font_size;
            const next: u32 = switch (c) {
                .@"zed::IncreaseBufferFontSize" => @min(40, current + 1),
                .@"zed::DecreaseBufferFontSize" => @max(10, current - 1),
                else => app.saved_font_size,
            };
            if (next == current) return;
            try app.renderer.setMonoSize(next);
            // Keep the line-height ratio so text doesn't crowd.
            app.settings.line_height = @max(next, (app.settings.line_height * next + current / 2) / current);
            app.settings.font_size = next;
            if (argBool(arg, "persist", false)) try app.saveAndApplySettings();
        },
        .@"zed::ToggleFullScreen" => try app.window.setFullscreen(!app.window.getFlags().fullscreen),
        .@"zid::ReloadConfiguration" => {
            try app.reloadConfig();
            app.notice("Configuration reloaded", .{});
        },
        .@"file_finder::Toggle" => try app.togglePicker(.file_finder),
        .@"command_palette::Toggle" => try app.togglePicker(.command_palette),
        .@"projects::OpenRecent" => try app.togglePicker(.recent_projects),
        .@"tab_switcher::Toggle" => try app.togglePicker(.tab_switcher),
        .@"go_to_line::Toggle" => app.toggleGoToLine(),
        .@"project_panel::ToggleFocus" => {
            if (app.panel_focus) {
                app.panel_focus = false;
            } else {
                app.panel_open = true;
                app.panel_focus = true;
                app.keymap_editor_open = false;
            }
        },
        .@"pane::CloseActiveItem" => {
            if (app.keymap_editor_open) {
                app.keymap_editor_open = false;
                return;
            }
            if (doc.dirty()) app.dialog = .close else try app.workspace.closeActive();
            app.syntax_doc = std.math.maxInt(usize);
        },
        .@"pane::CloseAllItems", .@"pane::CloseCleanItems", .@"pane::CloseOtherItems" => {
            const keep = app.workspace.active;
            var i = app.workspace.documents.items.len;
            var kept_dirty: usize = 0;
            while (i > 0) {
                i -= 1;
                if (c == .@"pane::CloseOtherItems" and i == keep) continue;
                app.workspace.active = i;
                if (app.workspace.current().dirty()) {
                    kept_dirty += 1;
                    continue;
                }
                try app.workspace.closeActive();
            }
            app.workspace.active = @min(app.workspace.active, app.workspace.documents.items.len - 1);
            app.syntax_doc = std.math.maxInt(usize);
            if (kept_dirty > 0 and c != .@"pane::CloseCleanItems") app.notice("{d} unsaved document(s) kept open", .{kept_dirty});
        },
        .@"pane::ActivateNextItem" => app.workspace.active = (app.workspace.active + 1) % app.workspace.documents.items.len,
        .@"pane::ActivatePreviousItem" => app.workspace.active = (app.workspace.active + app.workspace.documents.items.len - 1) % app.workspace.documents.items.len,
        .@"pane::ActivateItem" => if (argInt(arg)) |i| {
            if (i < app.workspace.documents.items.len) app.workspace.active = i;
        },
        .@"pane::ActivateLastItem" => app.workspace.active = app.workspace.documents.items.len - 1,
        .@"menu::SelectNext", .@"menu::SelectPrevious", .@"menu::SelectFirst", .@"menu::SelectLast", .@"menu::Confirm", .@"menu::SecondaryConfirm", .@"menu::Cancel" => try app.menuCommand(c),
        .@"project_panel::CollapseSelectedEntry" => try app.collapseOrParentProject(),
        .@"project_panel::ExpandSelectedEntry" => try app.expandOrEnterProject(),
        .@"project_panel::CollapseAllEntries" => {
            for (app.project.entries.items) |*e| if (e.directory) {
                e.collapsed = true;
            };
            try app.project.visible(app.gpa, &app.visible);
            app.panel_row = 0;
        },
        .@"project_panel::Open" => try app.activateProject(),
        else => try runEditor(app, doc, c, arg, page),
    }
    app.tabs_first = @min(app.tabs_first, app.workspace.active);
    if (focus(app) == .project_panel) app.keepPanelVisible();
}

fn runEditor(app: *App, doc: *zid.Document, c: Command, arg: ?std.json.Value, page: i32) !void {
    const gpa = app.gpa;
    var reveal = true;
    switch (c) {
        .@"editor::Cancel" => {
            doc.anchor = doc.cursor;
            reveal = false;
        },
        .@"editor::Backspace" => try doc.backspace(),
        .@"editor::Delete" => try doc.deleteForward(),
        .@"editor::Tab" => {
            const sel = doc.selection();
            if (doc.lineOf(sel.start) != doc.lineOf(sel.end)) {
                try ed.indentLines(doc, gpa, app.settings.tab_size, false);
            } else {
                const row = doc.lineOf(doc.cursor);
                const column = doc.cursor - doc.lineStart(row);
                const count = app.settings.tab_size - column % app.settings.tab_size;
                try doc.insert("                "[0..@min(16, count)]);
            }
        },
        .@"editor::Backtab", .@"editor::Outdent" => try ed.indentLines(doc, gpa, app.settings.tab_size, true),
        .@"editor::Indent" => try ed.indentLines(doc, gpa, app.settings.tab_size, false),
        .@"editor::Newline" => try ed.newlineIndented(doc, gpa),
        .@"editor::NewlineAbove" => try ed.newlineAbove(doc, gpa),
        .@"editor::NewlineBelow" => try ed.newlineBelow(doc, gpa),
        .@"editor::Copy", .@"editor::Cut" => {
            const range = ed.clipboardRange(doc);
            if (range.start == range.end) return;
            const text = try gpa.allocSentinel(u8, range.end - range.start, 0);
            defer gpa.free(text);
            doc.buffer.copy(range.start, text);
            try sdl.clipboard.setText(text);
            app.clipboard_whole_line = range.whole_line;
            if (c == .@"editor::Cut") {
                try doc.replaceRange(range.start, range.end, "");
                doc.setSelection(range.start, range.start);
            }
        },
        .@"editor::Paste" => {
            const text = try sdl.clipboard.getText();
            defer sdl.free(text);
            const sel = doc.selection();
            // A whole line copied without a selection pastes above the current line, like Zed.
            if (app.clipboard_whole_line and sel.start == sel.end and std.mem.endsWith(u8, text, "\n")) {
                const at = doc.lineStart(doc.lineOf(doc.cursor));
                const cursor = doc.cursor;
                try doc.replaceRange(at, at, text);
                doc.setSelection(cursor + text.len, cursor + text.len);
            } else try doc.insert(text);
        },
        .@"editor::Undo" => try doc.undo(),
        .@"editor::Redo" => try doc.redo(),
        .@"editor::MoveLeft", .@"editor::SelectLeft" => {
            const extend = c == .@"editor::SelectLeft";
            const sel = doc.selection();
            if (!extend and sel.start != sel.end) doc.move(sel.start, false) else doc.move(doc.buffer.previous(doc.cursor), extend);
        },
        .@"editor::MoveRight", .@"editor::SelectRight" => {
            const extend = c == .@"editor::SelectRight";
            const sel = doc.selection();
            if (!extend and sel.start != sel.end) doc.move(sel.end, false) else doc.move(doc.buffer.next(doc.cursor), extend);
        },
        .@"editor::MoveUp" => doc.moveVertical(-1, false),
        .@"editor::MoveDown" => doc.moveVertical(1, false),
        .@"editor::SelectUp" => doc.moveVertical(-1, true),
        .@"editor::SelectDown" => doc.moveVertical(1, true),
        .@"editor::MovePageUp" => doc.moveVertical(-page, false),
        .@"editor::MovePageDown" => doc.moveVertical(page, false),
        .@"editor::SelectPageUp" => doc.moveVertical(-page, true),
        .@"editor::SelectPageDown" => doc.moveVertical(page, true),
        .@"editor::PageUp", .@"editor::PageDown", .@"editor::LineUp", .@"editor::LineDown" => {
            const delta: i64 = switch (c) {
                .@"editor::PageUp" => -page,
                .@"editor::PageDown" => page,
                .@"editor::LineUp" => -1,
                else => 1,
            };
            doc.scroll_line = @intCast(std.math.clamp(@as(i64, @intCast(doc.scroll_line)) + delta, 0, @as(i64, @intCast(doc.lineCount() - 1))));
            reveal = false;
        },
        .@"editor::MoveToPreviousWordStart", .@"editor::MoveToPreviousSubwordStart" => doc.move(ed.previousWordStart(doc, doc.cursor), false),
        .@"editor::MoveToNextWordEnd", .@"editor::MoveToNextSubwordEnd" => doc.move(ed.nextWordEnd(doc, doc.cursor), false),
        .@"editor::SelectToPreviousWordStart", .@"editor::SelectToPreviousSubwordStart" => doc.move(ed.previousWordStart(doc, doc.cursor), true),
        .@"editor::SelectToNextWordEnd", .@"editor::SelectToNextSubwordEnd" => doc.move(ed.nextWordEnd(doc, doc.cursor), true),
        .@"editor::MoveToBeginningOfLine" => doc.move(ed.smartHome(doc, doc.cursor, argBool(arg, "stop_at_indent", true)), false),
        .@"editor::SelectToBeginningOfLine" => doc.move(ed.smartHome(doc, doc.cursor, argBool(arg, "stop_at_indent", true)), true),
        .@"editor::MoveToEndOfLine" => doc.move(doc.lineEnd(doc.lineOf(doc.cursor)), false),
        .@"editor::SelectToEndOfLine" => doc.move(doc.lineEnd(doc.lineOf(doc.cursor)), true),
        .@"editor::MoveToBeginning" => doc.move(0, false),
        .@"editor::MoveToEnd" => doc.move(doc.buffer.len(), false),
        .@"editor::SelectToBeginning" => doc.move(0, true),
        .@"editor::SelectToEnd" => doc.move(doc.buffer.len(), true),
        .@"editor::SelectAll" => {
            ed.selectAll(doc);
            reveal = false;
        },
        .@"editor::SelectLine" => ed.selectLine(doc),
        .@"editor::DeleteToPreviousWordStart", .@"editor::DeleteToPreviousSubwordStart" => try ed.deleteToPreviousWordStart(doc),
        .@"editor::DeleteToNextWordEnd", .@"editor::DeleteToNextSubwordEnd" => try ed.deleteToNextWordEnd(doc),
        .@"editor::DeleteToBeginningOfLine" => try ed.deleteToLineStart(doc),
        .@"editor::DeleteToEndOfLine" => try ed.deleteToLineEnd(doc),
        .@"editor::DeleteLine" => try ed.deleteLine(doc),
        .@"editor::MoveLineUp" => try ed.moveLines(doc, gpa, false),
        .@"editor::MoveLineDown" => try ed.moveLines(doc, gpa, true),
        .@"editor::DuplicateLineUp" => try ed.duplicateLines(doc, gpa, false),
        .@"editor::DuplicateLineDown" => try ed.duplicateLines(doc, gpa, true),
        .@"editor::ToggleComments" => try ed.toggleComments(doc, gpa, lineComment(doc.path orelse "")),
        .@"editor::JoinLines" => try ed.joinLines(doc, gpa),
        .@"editor::CopyPath" => if (doc.path) |path| {
            try sdl.clipboard.setText(path);
            app.notice("Copied {s}", .{path});
        },
        else => {},
    }
    if (reveal) try app.revealCursor();
}

fn runLineInput(app: *App, input: *LineInput, c: Command) !void {
    switch (c) {
        .@"editor::Backspace" => input.backspace(),
        .@"editor::Delete" => input.delete(),
        .@"editor::MoveLeft" => input.left(false),
        .@"editor::MoveRight" => input.right(false),
        .@"editor::SelectLeft" => input.left(true),
        .@"editor::SelectRight" => input.right(true),
        .@"editor::MoveToPreviousWordStart", .@"editor::MoveToPreviousSubwordStart" => input.wordLeftMove(false),
        .@"editor::MoveToNextWordEnd", .@"editor::MoveToNextSubwordEnd" => input.wordRightMove(false),
        .@"editor::SelectToPreviousWordStart" => input.wordLeftMove(true),
        .@"editor::SelectToNextWordEnd" => input.wordRightMove(true),
        .@"editor::MoveToBeginningOfLine", .@"editor::MoveToBeginning" => input.home(false),
        .@"editor::MoveToEndOfLine", .@"editor::MoveToEnd" => input.end(false),
        .@"editor::SelectToBeginningOfLine" => input.home(true),
        .@"editor::SelectToEndOfLine" => input.end(true),
        .@"editor::SelectAll" => input.selectAll(),
        .@"editor::DeleteToPreviousWordStart", .@"editor::DeleteToPreviousSubwordStart" => input.deleteWordLeft(),
        .@"editor::DeleteToNextWordEnd", .@"editor::DeleteToNextSubwordEnd" => input.deleteWordRight(),
        .@"editor::DeleteToBeginningOfLine" => input.deleteToStart(),
        .@"editor::Paste" => {
            const text = try sdl.clipboard.getText();
            defer sdl.free(text);
            input.insert(text);
        },
        .@"editor::Copy", .@"editor::Cut" => {
            const sel = input.selection();
            if (sel.start == sel.end) return;
            var buf: [257]u8 = undefined;
            @memcpy(buf[0 .. sel.end - sel.start], input.text()[sel.start..sel.end]);
            buf[sel.end - sel.start] = 0;
            try sdl.clipboard.setText(buf[0 .. sel.end - sel.start :0]);
            if (c == .@"editor::Cut") input.insert("");
        },
        else => return,
    }
    try app.lineInputChanged();
}

/// Line-comment prefix for ToggleComments.
pub fn lineComment(path: []const u8) []const u8 {
    return switch (zid.syntax.Language.fromPath(path)) {
        .zig, .c, .cpp, .json => "//",
        .python => "#",
        .sql => "--",
        .markdown, .plain => "",
    };
}

/// Every implemented command, for the command palette.
pub fn all() []const Command {
    return std.enums.values(Command);
}

test "every Zid command name parses back to itself" {
    for (std.enums.values(Command)) |c| try std.testing.expectEqual(c, parse(@tagName(c)).?);
}
