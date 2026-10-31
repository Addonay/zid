//! One responsibility per view/controller; application owns retained state.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const syntax = zid.syntax;
const max_line_bytes = 64 * 1024;
pub fn action(self: *App, action_value: config.Action) !void {
    if (action_value == .close or action_value == .new) self.syntax_doc = std.math.maxInt(usize);
    const doc = self.workspace.current();
    switch (action_value) {
        .save => {
            if (doc.path == null) {
                try self.pathDialog(.save);
                return;
            }
            try self.workspace.save(null);
            self.notice("Saved {s}", .{doc.path.?});
        },
        .save_as => try self.pathDialog(.save),
        .open => try self.pathDialog(.open),
        .new => {
            try self.workspace.newDocument();
            self.panel_focus = false;
        },
        .close => {
            if (doc.dirty()) self.dialog = .close else try self.workspace.closeActive();
        },
        .quit => {
            for (self.workspace.documents.items) |*d| if (d.dirty()) {
                self.dialog = .quit;
                return;
            };
            self.running = false;
        },
        .undo => try doc.undo(),
        .redo => try doc.redo(),
        .select_all => {
            doc.anchor = 0;
            doc.cursor = doc.buffer.len();
        },
        .copy, .cut => {
            const range = doc.selection();
            if (range.start == range.end) return;
            const text = try self.gpa.allocSentinel(u8, range.end - range.start, 0);
            defer self.gpa.free(text);
            doc.buffer.copy(range.start, text);
            try sdl.clipboard.setText(text);
            if (action_value == .cut) try doc.insert("");
        },
        .paste => {
            const text = try sdl.clipboard.getText();
            defer sdl.free(text);
            try doc.insert(text);
        },
        .toggle_panel => {
            self.panel_open = !self.panel_open;
            self.panel_focus = false;
        },
        .next_tab => self.workspace.active = (self.workspace.active + 1) % self.workspace.documents.items.len,
        .previous_tab => self.workspace.active = (self.workspace.active + self.workspace.documents.items.len - 1) % self.workspace.documents.items.len,
        .reload_config => {
            try self.reloadConfig();
            self.notice("Configuration reloaded", .{});
        },
    }
    self.tabs_first = @min(self.tabs_first, self.workspace.active);
    if (action_value == .undo or action_value == .redo or action_value == .paste or action_value == .cut) try self.revealCursor();
}
pub fn pathDialog(self: *App, kind: @FieldType(App, "dialog")) !void {
    self.path_input.clearRetainingCapacity();
    if (kind == .save) {
        try self.path_input.appendSlice(self.gpa, self.workspace.current().path orelse "");
    }
    self.dialog = kind;
}
pub fn dialogKey(self: *App, key: sdl.keycode.Keycode) !void {
    if (key == .escape) {
        self.dialog = .none;
        self.close_after_save = false;
        return;
    }
    if (self.dialog == .open or self.dialog == .save) {
        if (key == .backspace and self.path_input.items.len > 0) {
            var n = self.path_input.items.len - 1;
            while (n > 0 and self.path_input.items[n] & 0xc0 == 0x80) n -= 1;
            self.path_input.shrinkRetainingCapacity(n);
        } else if (key == .return_key and self.path_input.items.len > 0) {
            if (self.dialog == .open) try self.workspace.open(self.path_input.items) else {
                // Existing targets require an explicit overwrite choice.
                const requested = try std.fs.path.resolve(self.gpa, &.{ self.workspace.root, self.path_input.items });
                defer self.gpa.free(requested);
                const approved_stat = std.Io.Dir.cwd().statFile(self.io, requested, .{}) catch |err| blk: {
                    if (err != error.FileNotFound) return err;
                    break :blk null;
                };
                const expectation: zid.Workspace.SaveExpectation = if (approved_stat) |stat| .{ .existing = zid.Document.DiskIdentity.fromStat(stat) } else .absent;
                const exists = approved_stat != null;
                if (exists and (self.workspace.current().path == null or !std.mem.eql(u8, requested, self.workspace.current().path.?))) {
                    const buttons = [_]sdl.message_box.Button{ .{ .flags = .{ .mark_default_with_escape_key = true }, .value = 0, .text = "Cancel" }, .{ .flags = .{}, .value = 1, .text = "Replace" } };
                    const data: sdl.message_box.BoxData = .{ .flags = .{ .warning_dialog = true }, .parent_window = self.window, .title = "Replace file?", .message = "This file exists. Replace its contents?", .buttons = &buttons, .color_scheme = null };
                    const choice = try sdl.message_box.show(data);
                    if (choice != 1) return;
                }
                try self.workspace.saveWithExpectation(self.path_input.items, expectation);
                self.refreshProject() catch |err| self.notice("Saved; project refresh: {s}", .{@errorName(err)});
            }
            if (self.close_after_save) {
                try self.workspace.closeActive();
                self.close_after_save = false;
                self.syntax_doc = std.math.maxInt(usize);
            }
            self.dialog = .none;
            self.panel_focus = false;
            self.message_len = 0;
        } else if (key == .v and App.ctrlHeld()) {
            const text = try sdl.clipboard.getText();
            defer sdl.free(text);
            try self.path_input.appendSlice(self.gpa, text);
        } else if (key == .a and App.ctrlHeld()) self.path_input.clearRetainingCapacity();
        return;
    }
    if (key == .d) {
        self.suppress_choice_text = true;
        if (self.dialog == .quit) self.running = false else {
            self.workspace.current().saved_revision = self.workspace.current().revision;
            try self.workspace.closeActive();
        }
        self.syntax_doc = std.math.maxInt(usize);
        self.dialog = .none;
    } else if (key == .s) {
        self.suppress_choice_text = true;
        if (self.dialog == .quit) {
            for (self.workspace.documents.items) |*d| if (d.dirty() and d.path == null) {
                self.notice("Untitled documents need Save As before quitting", .{});
                self.dialog = .none;
                return;
            };
            const active = self.workspace.active;
            defer self.workspace.active = active;
            for (self.workspace.documents.items, 0..) |*d, i| if (d.dirty()) {
                self.workspace.active = i;
                try self.workspace.save(null);
            };
            self.running = false;
        } else if (self.workspace.current().path == null) {
            self.close_after_save = true;
            try self.pathDialog(.save);
            return;
        } else {
            try self.workspace.save(null);
            try self.workspace.closeActive();
        }
        self.dialog = .none;
    }
}
