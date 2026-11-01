const std = @import("std");
const App = @import("app.zig").App;
const Rect = @import("layout.zig").Rect;
const sdl = @import("sdl3");
fn area(a: *App) Rect {
    return .{ .x = 8, .y = 40, .w = @max(0, a.layout.width - 16), .h = @max(0, a.layout.height - 74) };
}
fn button(a: *App, x: f32, y: f32, w: f32, label: []const u8) !void {
    try a.renderer.rect(x, y, w, 25, a.settings.theme.status);
    try a.renderer.textUi(label, x + 8, y + 18, a.settings.theme.text);
}
pub fn draw(a: *App) !void {
    const r = area(a);
    const t = a.settings.theme;
    const s = &a.database;
    var background = t.editor;
    background[3] = 255;
    try a.fill(r, background);
    a.clip(r);
    const x = r.x + 16;
    const w = @max(0, r.w - 32);
    try a.renderer.textUi("DATABASES  /  SQLite — READ ONLY", x, r.y + 23, t.text);
    try a.renderer.textUi("PostgreSQL · MySQL · Convex: unavailable", x, r.y + 44, t.muted);
    try a.renderer.textUi("File path", x, r.y + 68, t.muted);
    try a.renderer.rect(x, r.y + 73, w, 27, t.background);
    a.clip(.{ .x = x + 4, .y = r.y + 73, .w = @max(0, w - 8), .h = 27 });
    const path_offset = @max(0, a.renderer.widthUi(s.path.text()[0..s.path.cursor]) - w + 22);
    try a.renderer.textUi(s.path.text(), x + 6 - path_offset, r.y + 92, t.text);
    if (s.focus == .path) try a.renderer.textUi("│", x + 6 + a.renderer.widthUi(s.path.text()[0..s.path.cursor]) - path_offset, r.y + 92, t.accent);
    a.clip(r);
    try a.renderer.textUi("SQL", x, r.y + 120, t.muted);
    try a.renderer.rect(x, r.y + 125, w, 27, t.background);
    a.clip(.{ .x = x + 4, .y = r.y + 125, .w = @max(0, w - 8), .h = 27 });
    const sql_offset = @max(0, a.renderer.widthUi(s.sql.text()[0..s.sql.cursor]) - w + 22);
    try a.renderer.textUi(s.sql.text(), x + 6 - sql_offset, r.y + 144, t.text);
    if (s.focus == .sql) try a.renderer.textUi("│", x + 6 + a.renderer.widthUi(s.sql.text()[0..s.sql.cursor]) - sql_offset, r.y + 144, t.accent);
    a.clip(r);
    try button(a, x, r.y + 160, 75, "Run");
    try button(a, x + 82, r.y + 160, 105, "Schema");
    try button(a, x + 194, r.y + 160, 75, "Cancel");
    try a.renderer.textUi(s.status, x, r.y + 207, t.text);
    if (w > 460) try a.renderer.textUi("Scroll rows · Shift + wheel: columns", x + 300, r.y + 207, t.muted);
    const top = r.y + 220;
    const colw: f32 = 160;
    const rowh: f32 = 24;
    if (s.table) |*table| {
        const rows = table.rows();
        if (rows.len == 0) {
            try a.renderer.textUi("No rows (column metadata unavailable)", x, top + 18, t.muted);
        } else {
            const keys = rows[0].object.keys();
            a.clip(.{ .x = x, .y = top, .w = w, .h = @max(0, r.y + r.h - top) });
            for (keys[s.column_scroll..], 0..) |column, i| {
                const cx = x + @as(f32, @floatFromInt(i)) * colw;
                if (cx >= x + w) break;
                a.clip(.{ .x = cx, .y = top, .w = @min(colw - 4, @max(0, x + w - cx)), .h = @max(0, r.y + r.h - top) });
                try a.renderer.textUi(column, cx + 4, top + 18, t.muted);
                var j = s.scroll;
                while (j < rows.len) : (j += 1) {
                    const y = top + rowh * @as(f32, @floatFromInt(j - s.scroll + 1));
                    if (y + rowh > r.y + r.h) break;
                    const value = rows[j].object.get(column) orelse .null;
                    var buf: [128]u8 = undefined;
                    const text: []const u8 = switch (value) {
                        .null => "NULL",
                        .string => |v| v,
                        .integer => |v| std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?",
                        .float => |v| std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?",
                        .bool => |v| if (v) "true" else "false",
                        .number_string => |v| v,
                        else => "?",
                    };
                    try a.renderer.textUi(text, cx + 4, y + 18, t.text);
                }
            }
        }
    }
    a.renderer.setClip(null);
}
pub fn click(a: *App, x: f32, y: f32) void {
    const r = area(a);
    const left = r.x + 16;
    const rel = y - r.y;
    if (rel >= 73 and rel < 100) a.database.focus = .path else if (rel >= 125 and rel < 152) a.database.focus = .sql else if (rel >= 160 and rel < 185) {
        if (x >= left and x < left + 75) a.database.start(a.gpa, a.io, false) else if (x >= left + 82 and x < left + 187) a.database.start(a.gpa, a.io, true) else if (x >= left + 194 and x < left + 269) a.database.cancel(a.io);
    }
}
pub fn key(a: *App, k: sdl.keycode.Keycode, mods: sdl.keycode.KeyModifier) void {
    const s = &a.database;
    const line = s.input();
    const shift = mods.left_shift or mods.right_shift;
    switch (k) {
        .escape => {
            s.cancel(a.io);
            s.open = false;
        },
        .tab => s.focus = if (s.focus == .path) .sql else .path,
        .return_key, .kp_enter => s.start(a.gpa, a.io, s.focus == .path),
        .backspace => line.backspace(),
        .delete => line.delete(),
        .left => line.left(shift),
        .right => line.right(shift),
        .home => line.home(shift),
        .end => line.end(shift),
        .a => if (mods.left_control or mods.right_control) {
            line.selectAll();
        },
        .v => if (mods.left_control or mods.right_control) {
            const text = sdl.clipboard.getText() catch return;
            defer sdl.free(text);
            line.insert(text);
        },
        .up => s.scroll -|= 1,
        .down => if (s.table) |*table| {
            s.scroll = @min(s.scroll + 1, table.rows().len -| 1);
        },
        else => {},
    }
}
