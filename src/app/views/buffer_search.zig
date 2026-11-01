//! Compact literal search field above the editor.
const std = @import("std");
const App = @import("../app.zig").App;

pub fn draw(app: *App) !void {
    const e = try app.layout.rect(app.layout.editor);
    const t = app.settings.theme;
    const r = &app.renderer;
    try app.fill(.{ .x = e.x, .y = e.y, .w = e.w, .h = 40 }, t.background);
    const x = e.x + 10;
    const w = @max(80, @min(360, e.w - 190));
    try r.roundRect(x, e.y + 6, w, 28, 4, if (app.search_focused) t.border_focused else t.border);
    try r.roundRect(x + 1, e.y + 7, w - 2, 26, 3, t.surface);
    const input = &app.search_input;
    const text = input.text();
    app.clip(.{ .x = x + 8, .y = e.y + 7, .w = w - 16, .h = 26 });
    const caret_x = r.widthUi(text[0..input.cursor]);
    const origin = x + 8 - @max(0, caret_x - (w - 20));
    const sel = input.selection();
    if (sel.end > sel.start) try r.rect(origin + r.widthUi(text[0..sel.start]), e.y + 11, r.widthUi(text[sel.start..sel.end]), 18, t.selection);
    try r.textUi(if (text.len == 0) "Find" else text, origin, e.y + 25, if (text.len == 0) t.placeholder else t.text);
    if (app.search_focused and app.caret_visible) try r.rect(origin + caret_x, e.y + 12, 1, 16, t.accent);
    r.setClip(null);
    var buf: [96]u8 = undefined;
    const doc = app.workspace.current();
    const status = if (doc.large != null or doc.buffer.len() > 32 * 1024 * 1024) "Search unavailable for large files" else if (text.len == 0) "" else if (app.search_count == 0) "No matches" else try std.fmt.bufPrint(&buf, "{d}{s} matches", .{ app.search_count, if (app.search_capped) "+" else "" });
    try r.textUi(status, x + w + 12, e.y + 25, t.muted);
}
