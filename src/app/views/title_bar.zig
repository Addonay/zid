//! Native caption controls use the same icon-theme resolver and spacing as
//! chatƺpt; the rest of the chrome follows the Zed shell.
const std = @import("std");
const App = @import("../app.zig").App;
const Kind = @import("../../platform/window_controls.zig").Kind;
const icons = @import("icons");

pub fn controlsInset(self: *App) f32 {
    return if (self.controls.breeze) 3 * 22 + 2 * 10 + 8 else 3 * 34 + 2 * 8 + 6;
}
pub fn controlAt(self: *App, x: f32, y: f32) ?usize {
    if (y < 0 or y >= 34) return null;
    const start = self.layout.width - controlsInset(self);
    const step: f32 = if (self.controls.breeze) 32 else 42;
    const width: f32 = if (self.controls.breeze) 22 else 34;
    for (0..3) |i| {
        const left = start + @as(f32, @floatFromInt(i)) * step;
        if (x >= left and x < left + width) return i;
    }
    return null;
}
fn circle(self: *App, cx: f32, cy: f32, radius: f32, color: [4]u8) !void {
    var y: f32 = -radius;
    while (y < radius) : (y += 1) {
        const half = @sqrt(@max(0, radius * radius - (y + 0.5) * (y + 0.5)));
        try self.renderer.rect(cx - half, cy + y, half * 2, 1, color);
    }
}
pub fn draw(self: *App) !void {
    const t = self.settings.theme;
    const title = try self.layout.rect(self.layout.title);
    try self.fill(title, t.title_bar);
    try self.renderer.icon(icons.svg("panel_left"), 12, 9, 16, t.muted);
    const inset = controlsInset(self);
    self.clip(.{ .x = 44, .y = 0, .w = @max(0, title.w - inset - 56), .h = 34 });
    try self.renderer.textUi(std.fs.path.basename(self.workspace.root), 44, 23, t.text);
    self.renderer.setClip(null);
    const breeze = self.controls.breeze;
    const diameter: f32 = if (breeze) 18 else 24;
    const margin: f32 = if (breeze) 2 else 5;
    const step: f32 = if (breeze) 32 else 42;
    const start = title.w - inset;
    const maximized = self.window.getFlags().maximized;
    const kinds = [_]Kind{ .minimize, if (maximized) .restore else .maximize, .close };
    for (kinds, 0..) |kind, i| {
        const x = start + @as(f32, @floatFromInt(i)) * step + margin;
        const hovered = controlAt(self, self.mouse_x, self.mouse_y) == i;
        const pressed = hovered and self.pointer_down;
        var foreground = t.text;
        var background: [4]u8 = .{ t.text[0], t.text[1], t.text[2], if (pressed) 77 else if (hovered) 38 else 26 };
        if (breeze) {
            background = if (hovered) (if (i == 2) (if (pressed) [4]u8{ 109, 34, 41, 255 } else [4]u8{ 255, 152, 162, 255 }) else t.text) else .{ 0, 0, 0, 0 };
            if (hovered) foreground = t.title_bar;
        }
        if (!self.focused) foreground[3] = 128;
        if (background[3] > 0) try circle(self, x + diameter / 2, 17, diameter / 2, background);
        try self.controls.draw(&self.renderer, kind, x + (diameter - 16) / 2, 9, 16, foreground);
    }
    try self.renderer.rect(0, 33, title.w, 1, t.border);
}
