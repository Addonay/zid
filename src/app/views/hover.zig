//! A compact, clipped view of LSP hover text. Markdown is shown as plain text.
const std = @import("std");
const App = @import("../app.zig").App;

pub fn draw(app: *App, text: []const u8) !void {
    const doc = app.workspace.current();
    const editor = try app.editorRect();
    const row = doc.lineOf(doc.cursor);
    if (row < doc.scroll_line or row >= doc.scroll_line + app.pageLines()) return;
    const line = app.lineBytes(doc, row);
    const offset = @min(line.len, doc.cursor - doc.lineStart(row));
    const caret_x = editor.x + 64 - doc.scroll_x + app.textWidth(line[0..offset]);
    const caret_y = editor.y + 8 + @as(f32, @floatFromInt(row - doc.scroll_line)) * @as(f32, @floatFromInt(app.settings.line_height));
    var width = @min(520, @max(0, editor.w - 16));
    if (width < 80) return;
    var lines: [8193][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |logical| {
        var start: usize = 0;
        while (count < lines.len) {
            var end = start;
            while (end < logical.len) {
                var next = end + 1;
                while (next < logical.len and logical[next] & 0xc0 == 0x80) next += 1;
                if (end > start and app.renderer.widthUi(logical[start..next]) > width - 22) break;
                end = next;
            }
            lines[count] = logical[start..end];
            count += 1;
            if (end == logical.len) break;
            start = end;
        }
    }
    var widest: f32 = 0;
    for (lines[0..count]) |line_text| widest = @max(widest, app.renderer.widthUi(line_text));
    width = @min(width, @max(180, widest + 24));
    const height = @min(@min(240, @max(0, editor.h - 16)), @max(40, 12 + @as(f32, @floatFromInt(count)) * 19));
    if (height < 40) return;
    const x = std.math.clamp(caret_x, editor.x + 4, editor.x + editor.w - width - 4);
    const below = caret_y + @as(f32, @floatFromInt(app.settings.line_height)) + 4;
    const y = if (below + height <= editor.y + editor.h) below else @max(editor.y + 4, caret_y - height - 4);
    app.hover_rect = .{ .x = x, .y = y, .w = width, .h = height };
    const t = app.settings.theme;
    try app.renderer.roundBox(x, y, width, height, 5, t.elevated_surface, t.border);
    app.clip(.{ .x = x + 10, .y = y + 5, .w = width - 20, .h = height - 10 });
    defer app.renderer.setClip(null);
    const line_height: f32 = 19;
    const visible: usize = @intFromFloat(@max(1, @floor((height - 12) / line_height)));
    app.hover_scroll = @min(app.hover_scroll, count -| visible);
    for (lines[app.hover_scroll..@min(count, app.hover_scroll + visible)], 0..) |line_text, i| {
        try app.renderer.textUi(line_text, x + 10, y + 20 + @as(f32, @floatFromInt(i)) * line_height, t.text);
    }
}
