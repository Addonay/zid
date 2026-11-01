//! One responsibility per view/controller; application owns retained state.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("../app.zig").App;
const config = @import("../config.zig");
const Rect = @import("../layout.zig").Rect;
const syntax = zid.syntax;
const max_line_bytes = 64 * 1024;
pub fn drawEditor(self: *App) !void {
    const doc = self.workspace.current();
    const e = try self.editorRect();
    const t = self.settings.theme;
    try self.fill(e, t.editor);
    if (doc.large != null) return drawLarge(self);
    const line_height: f32 = @floatFromInt(self.settings.line_height);
    const lang = syntax.Language.fromPath(doc.path orelse "");
    if (self.syntax_doc != self.workspace.active or self.syntax_revision != doc.revision) {
        self.checkpoints.clearRetainingCapacity();
        try self.checkpoints.append(self.gpa, 0);
        self.syntax_doc = self.workspace.active;
        self.syntax_revision = doc.revision;
    }
    self.clip(e);
    defer self.renderer.setClip(null);
    var spans: [2048]syntax.Span = undefined;
    const checkpoint = @min(doc.scroll_line / 64, self.checkpoints.items.len - 1);
    var state = self.checkpoints.items[checkpoint];
    var row = checkpoint * 64;
    const selected = doc.selection();
    const cursor_row = doc.lineOf(doc.cursor);
    while (row < doc.lineCount() and row < doc.scroll_line + self.pageLines() + 1) : (row += 1) {
        const bytes = self.lineBytes(doc, row);
        var sink = syntax.Sink.init(&spans);
        state = syntax.lexLine(lang, state, bytes, &sink);
        if ((row + 1) % 64 == 0 and (row + 1) / 64 == self.checkpoints.items.len) try self.checkpoints.append(self.gpa, state);
        if (row < doc.scroll_line) continue;
        const y = e.y + 8 + @as(f32, @floatFromInt(row - doc.scroll_line)) * line_height;
        const baseline = y + @as(f32, @floatFromInt(self.settings.font_size));
        if (row == cursor_row) try self.renderer.rect(e.x, y, e.w, line_height, t.active_line);
        var number: [24]u8 = undefined;
        const n = try std.fmt.bufPrint(&number, "{d}", .{row + 1});
        try self.renderer.text(n, e.x + 48 - self.renderer.width(n), baseline, if (row == cursor_row) t.text else t.line_number);
        const x = e.x + 64 - doc.scroll_x;
        const start = doc.lineStart(row);
        self.clip(.{ .x = e.x + 60, .y = e.y, .w = @max(0, e.w - 60), .h = e.h });
        const sel_start = @min(bytes.len, selected.start -| start);
        const sel_end = @min(bytes.len, selected.end -| start);
        if (selected.end > start and selected.start <= start + bytes.len) {
            const sx = self.textWidth(bytes[0..sel_start]);
            const ex = self.textWidth(bytes[0..sel_end]);
            try self.renderer.rect(x + sx, y, @max(if (selected.end > start + bytes.len) @as(f32, 8) else 0, ex - sx), line_height, t.selection);
        }
        // Draw plain gaps and token runs once; no full-line underpainting.
        var from: usize = 0;
        for (sink.items()) |span| {
            if (span.start > from) try self.drawRun(bytes, from, span.start, x, baseline, t.editor_foreground, e, false);
            try self.drawRun(bytes, span.start, span.end, x, baseline, t.syntaxColor(span.kind), e, t.italic(span.kind));
            from = span.end;
        }
        if (from < bytes.len) try self.drawRun(bytes, from, bytes.len, x, baseline, t.editor_foreground, e, false);
        self.clip(e);
    }
    if (doc.lineCount() > self.pageLines()) {
        const total: f32 = @floatFromInt(doc.lineCount());
        const h = @max(20, e.h * @as(f32, @floatFromInt(self.pageLines())) / total);
        const y = e.y + (e.h - h) * @as(f32, @floatFromInt(doc.scroll_line)) / @max(1, total - 1);
        try self.renderer.rect(e.x + e.w - 8, y, 5, h, t.selected);
    }
}
fn drawLarge(self: *App) !void {
    const doc = self.workspace.current();
    const large = &self.workspace.current().large.?;
    const e = try self.editorRect();
    const t = self.settings.theme;
    self.clip(e);
    defer self.renderer.setClip(null);
    var data: [64 * 1024]u8 = undefined;
    const snapshot = large.poll(&data);
    large.needs_redraw = false;
    var header: [256]u8 = undefined;
    const label = if (large.failure) |err| try std.fmt.bufPrint(&header, "READ ONLY  |  byte {d}/{d}  |  {s}", .{ large.offset, large.size, @errorName(err) }) else try std.fmt.bufPrint(&header, "READ ONLY  |  byte {d}/{d}  |  indexed {d}/{d}  |  {s}", .{ snapshot.offset, large.size, snapshot.indexed_bytes, large.size, if (snapshot.loading) @as([]const u8, "Loading…") else "Go to: line, b<offset>, or %" });
    try self.renderer.text(label, e.x + 8, e.y + @as(f32, @floatFromInt(self.settings.font_size)), t.text);
    if (large.failure != null) return;
    const n = snapshot.len;
    var at: usize = 0;
    var line: ?u64 = snapshot.first_line;
    var row: usize = 0;
    const height: f32 = @floatFromInt(self.settings.line_height);
    while (at < n and row + 1 < self.pageLines()) : (row += 1) {
        const start = at;
        var text: [4096]u8 = undefined;
        const selection = large.selection();
        const origin = snapshot.offset + start;
        const relative = zid.large_display.Selection{
            .start = @intCast(@min(selection.start -| origin, n - start)),
            .end = @intCast(@min(selection.end -| origin, n - start)),
        };
        const decoded = zid.large_display.decodeSelected(data[at..n], &text, self.settings.tab_size, snapshot.offset + n == large.size, relative);
        at += decoded.consumed;
        // Output exhaustion truncates one logical line rather than wrapping an
        // arbitrary byte count into rows with duplicated line numbers.
        var newline = decoded.newline;
        if (!newline) {
            if (std.mem.indexOfScalar(u8, data[at..n], '\n')) |lf| {
                at += lf + 1;
                newline = true;
            } else at = n;
        }
        const y = e.y + @as(f32, @floatFromInt(row + 1)) * height + @as(f32, @floatFromInt(self.settings.font_size));
        var offset_buf: [32]u8 = undefined;
        const offset = if (line) |number| try std.fmt.bufPrint(&offset_buf, "{d}", .{number + 1}) else try std.fmt.bufPrint(&offset_buf, "@{x}", .{snapshot.offset + start});
        try self.renderer.text(offset, e.x + 8, y, t.line_number);
        const x = e.x + 120 - doc.scroll_x;
        self.clip(.{ .x = e.x + @min(120, e.w), .y = e.y + height, .w = @max(0, e.w - 120), .h = @max(0, e.h - height) });
        if (decoded.selection != null or decoded.selected_newline) {
            const mapped = decoded.selection orelse zid.large_display.Selection{ .start = decoded.written, .end = decoded.written };
            const sx = self.renderer.width(text[0..mapped.start]);
            const ex = self.renderer.width(text[0..mapped.end]);
            try self.renderer.rect(x + sx, y - @as(f32, @floatFromInt(self.settings.font_size)), ex - sx + (if (decoded.selected_newline) @as(f32, 8) else 0), height, t.selection);
        }
        try self.renderer.text(text[0..decoded.written], x, y, t.editor_foreground);
        if (self.focused and self.caret_visible and !self.panel_focus and self.dialog == .none and
            large.offset >= origin and large.offset <= origin + decoded.consumed and
            !(decoded.newline and large.offset == origin + decoded.consumed))
        {
            var prefix: [4096]u8 = undefined;
            const byte_count: usize = @intCast(@min(large.offset - origin, decoded.consumed));
            const caret = zid.large_display.decodeLine(data[start..][0..byte_count], &prefix, self.settings.tab_size, true);
            const cx = x + self.renderer.width(prefix[0..caret.written]);
            try self.renderer.rect(cx, y - @as(f32, @floatFromInt(self.settings.font_size)), 2, height, t.editor_foreground);
        }
        self.clip(e);
        if (decoded.truncated) try self.renderer.text("…", e.x + e.w - 28, y, t.muted);
        if (newline) {
            if (line) |*number| number.* += 1;
        }
        if (snapshot.offset + at > snapshot.indexed_bytes) line = null;
    }
    large.visible_origin = snapshot.offset;
    large.visible_end = snapshot.offset + at;
}
pub fn drawRun(self: *App, bytes: []const u8, start: usize, end: usize, x: f32, baseline: f32, color: [4]u8, e: Rect, italic: bool) !void {
    if (start >= end) return;
    const at = x + self.textWidth(bytes[0..start]);
    if (at >= e.x + e.w) return;
    // Window horizontal text before shaping/rasterizing to keep frame limits
    // independent of enormous single lines. Preserve codepoint boundaries.
    var first = start;
    if (at < e.x - 100) {
        var low = start;
        var high = end;
        while (low < high) {
            var mid = low + (high - low) / 2;
            while (mid > low and bytes[mid] & 0xc0 == 0x80) mid -= 1;
            var next = mid + 1;
            while (next < end and bytes[next] & 0xc0 == 0x80) next += 1;
            if (x + self.textWidth(bytes[0..next]) < e.x - 100) low = next else high = mid;
        }
        first = low;
    }
    var last = @min(end, first + @as(usize, @intFromFloat(e.w)) * 4 + 128);
    while (last < end and last > first and bytes[last] & 0xc0 == 0x80) last -= 1;
    const run_x = x + self.textWidth(bytes[0..first]);
    var column: usize = 0;
    for (bytes[0..first]) |b| {
        if (b == '\t') column += self.settings.tab_size - column % self.settings.tab_size else if (b & 0xc0 != 0x80) column += 1;
    }
    if (italic) try self.renderer.textItalic(self.expandAt(bytes[first..last], column), run_x, baseline, color) else try self.renderer.text(self.expandAt(bytes[first..last], column), run_x, baseline, color);
}

pub fn drawCaret(self: *App) !void {
    if (self.workspace.current().large != null) return;
    if (!self.focused or !self.caret_visible or self.panel_focus or self.search_focused or self.dialog != .none) return;
    const doc = self.workspace.current();
    const row = doc.lineOf(doc.cursor);
    if (row < doc.scroll_line or row >= doc.scroll_line + self.pageLines() + 1) return;
    const e = try self.editorRect();
    const bytes = self.lineBytes(doc, row);
    const offset = @min(bytes.len, doc.cursor - doc.lineStart(row));
    const y = e.y + 8 + @as(f32, @floatFromInt(row - doc.scroll_line)) * @as(f32, @floatFromInt(self.settings.line_height));
    self.clip(.{ .x = e.x + 60, .y = e.y, .w = @max(0, e.w - 60), .h = e.h });
    defer self.renderer.setClip(null);
    try self.renderer.rect(e.x + 64 - doc.scroll_x + self.textWidth(bytes[0..offset]), y, 2, @floatFromInt(self.settings.line_height), self.settings.theme.accent);
}
