//! One responsibility per view/controller; application owns retained state.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const syntax = zid.syntax;
const max_line_bytes = 64 * 1024;
pub fn drawDialog(self: *App) !void {
    const t = self.settings.theme;
    try self.fill(.{ .w = self.layout.width, .h = self.layout.height }, .{ 0, 0, 0, 150 });
    const w = @min(700, self.layout.width - 40);
    const r: Rect = .{ .x = (self.layout.width - w) / 2, .y = 100, .w = w, .h = 150 };
    try self.fill(r, t.selected);
    const title = switch (self.dialog) {
        .open => "Open file — path relative to project",
        .save => "Save as — path relative to project",
        .close => "This document has unsaved changes",
        .quit => "There are unsaved documents",
        .none => "",
    };
    try self.renderer.textUi(title, r.x + 18, r.y + 28, t.text);
    self.clip(.{ .x = r.x + 18, .y = r.y + 42, .w = w - 36, .h = 50 });
    if (self.dialog == .open or self.dialog == .save) {
        const input = self.path_input.items;
        const offset = @max(0, self.renderer.widthUi(input) - w + 50);
        try self.renderer.textUi(input, r.x + 18 - offset, r.y + 69, t.text);
        try self.renderer.textUi("│", r.x + 18 + self.renderer.widthUi(input) - offset, r.y + 69, t.accent);
    } else try self.renderer.textUi("S: Save     D: Discard     Esc: Cancel", r.x + 18, r.y + 69, t.text);
    self.renderer.setClip(null);
    try self.renderer.textUi(if (self.dialog == .open or self.dialog == .save) "Enter to confirm · Esc to cancel · Ctrl+A to clear" else "Your changes stay intact until you choose.", r.x + 18, r.y + 124, t.muted);
}
