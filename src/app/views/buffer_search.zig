//! Compact literal search field above the editor.
const std = @import("std");
const App = @import("../app.zig").App;

pub fn draw(app: *App) !void {
    const e = try app.layout.rect(app.layout.editor);
    const t = app.settings.theme;
    const r = &app.renderer;
    try app.fill(.{ .x = e.x, .y = e.y, .w = e.w, .h = if (app.replace_open) 76 else 40 }, t.background);
    const x = e.x + 10;
    const w = @max(80, @min(360, e.w - 190));
    for (0..@as(usize, if (app.replace_open) 2 else 1)) |row| {
        const y = e.y + @as(f32, @floatFromInt(row)) * 36;
        const focused = app.search_focused and (app.replace_focused == (row == 1));
        const input = if (row == 0) &app.search_input else &app.replace_input;
        const text = input.text();
        try r.roundRect(x, y + 6, w, 28, 4, if (focused) t.border_focused else t.border);
        try r.roundRect(x + 1, y + 7, w - 2, 26, 3, t.surface);
        app.clip(.{ .x = x + 8, .y = y + 7, .w = w - 16, .h = 26 });
        const caret_x = r.widthUi(text[0..input.cursor]);
        const origin = x + 8 - @max(0, caret_x - (w - 20));
        const sel = input.selection();
        if (sel.end > sel.start) try r.rect(origin + r.widthUi(text[0..sel.start]), y + 11, r.widthUi(text[sel.start..sel.end]), 18, t.selection);
        try r.textUi(if (text.len == 0) (if (row == 0) @as([]const u8, "Find") else "Replace with") else text, origin, y + 25, if (text.len == 0) t.placeholder else t.text);
        if (focused and app.caret_visible) try r.rect(origin + caret_x, y + 12, 1, 16, t.accent);
        r.setClip(null);
    }
    const text = app.search_input.text();
    if (app.replace_open) try r.textUi("Replace", x + w + 12, e.y + 61, t.accent);

    var buf: [96]u8 = undefined;
    const doc = app.workspace.current();
    const status = if (doc.large != null or doc.buffer.len() > 32 * 1024 * 1024) "Search unavailable for large files" else if (text.len == 0) "" else if (app.search_count == 0) "No matches" else try std.fmt.bufPrint(&buf, "{d}{s} {s} · {s}", .{ app.search_count, if (app.search_capped) "+" else "", if (app.search_count == 1) @as([]const u8, "match") else "matches", if (app.search_case_sensitive) @as([]const u8, "Case") else "ASCII fold" });
    try r.textUi(status, x + w + 12, e.y + 25, t.muted);
}

pub fn click(app: *App, e: @import("../layout.zig").Rect, mx: f32, my: f32) !void {
    const w = @max(80, @min(360, e.w - 190));
    app.search_focused = true;
    app.panel_focus = false;
    if (app.replace_open and my >= e.y + 36 and mx > e.x + 10 + w) {
        try app.searchReplace();
        return;
    }
    app.replace_focused = app.replace_open and my >= e.y + 36;
}
