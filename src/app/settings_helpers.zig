const std = @import("std");
const config = @import("config.zig");
pub const Id = enum { open_keymap, open_keymap_file, open_file, reload, theme, icon_theme, font_size, line_height, tab_size, cursor_blink, panel_width, auto_fold_dirs, indent_guides };

pub fn changed(s: config.Settings, id: Id) bool {
    const d: config.Settings = .{};
    return switch (id) {
        .theme => s.theme_name != d.theme_name,
        .icon_theme => s.icon_theme != d.icon_theme,
        .font_size => s.font_size != d.font_size,
        .line_height => s.line_height != d.line_height,
        .tab_size => s.tab_size != d.tab_size,
        .panel_width => s.panel_width != d.panel_width,
        .cursor_blink => s.cursor_blink != d.cursor_blink,
        .auto_fold_dirs => s.auto_fold_dirs != d.auto_fold_dirs,
        .indent_guides => s.show_indent_guides != d.show_indent_guides,
        else => false,
    };
}
pub fn reset(s: *config.Settings, id: Id) void {
    const d: config.Settings = .{};
    switch (id) {
        .theme => s.theme_name = d.theme_name,
        .icon_theme => s.icon_theme = d.icon_theme,
        .font_size => s.font_size = d.font_size,
        .line_height => {
            s.line_height = d.line_height;
            s.font_size = @min(s.font_size, d.line_height);
        },
        .tab_size => s.tab_size = d.tab_size,
        .panel_width => s.panel_width = d.panel_width,
        .cursor_blink => s.cursor_blink = d.cursor_blink,
        .auto_fold_dirs => s.auto_fold_dirs = d.auto_fold_dirs,
        .indent_guides => s.show_indent_guides = d.show_indent_guides,
        else => {},
    }
}
/// Keyboard reset only applies to a focused, changed setting.
pub fn keyboardResetTarget(s: config.Settings, id: ?Id, controls_focused: bool) ?Id {
    const target = id orelse return null;
    return if (controls_focused and changed(s, target)) target else null;
}

/// Return the end of a line at a word boundary, falling back to UTF-8 codepoint boundaries.
pub fn lineEnd(text: []const u8, width: f32, ctx: anytype, measure: anytype) usize {
    var end: usize = 0;
    var space: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        var next = i + 1;
        while (next < text.len and text[next] & 0xc0 == 0x80) : (next += 1) {}
        if (measure(ctx, text[0..next]) > width and end > 0) return if (space > 0) space else end;
        end = next;
        if (text[i] == ' ') space = i;
        i = next;
    }
    return end;
}
pub fn lineCount(text: []const u8, width: f32, ctx: anytype, measure: anytype) usize {
    var rest = text;
    var n: usize = 0;
    while (rest.len > 0) {
        const end = lineEnd(rest, width, ctx, measure);
        rest = std.mem.trimStart(u8, rest[end..], " ");
        n += 1;
    }
    return @max(1, n);
}
pub fn height(lines: usize, stacked: bool) f32 {
    return @max(60, 48 + @as(f32, @floatFromInt(lines - 1)) * 16 + (if (stacked) @as(f32, 34) else 0));
}

test "reset supported values to config defaults" {
    var s: config.Settings = .{};
    s.cursor_blink = false;
    s.tab_size = 8;
    s.theme_name = .ayu;
    for ([_]Id{ .cursor_blink, .tab_size, .theme }) |id| {
        try std.testing.expect(changed(s, id));
        reset(&s, id);
        try std.testing.expect(!changed(s, id));
    }
    try std.testing.expect(!changed(s, .reload));
    s.font_size = 30;
    s.line_height = 30;
    reset(&s, .line_height);
    try config.validate(s);
}
test "wrapping increases geometry and preserves words" {
    const M = struct {
        fn width(_: void, t: []const u8) f32 {
            return @floatFromInt(t.len);
        }
    };
    const text = "A longer description wraps here";
    const wide = lineCount(text, 100, {}, M.width);
    const narrow = lineCount(text, 10, {}, M.width);
    try std.testing.expect(narrow > wide);
    try std.testing.expect(height(narrow, true) > height(wide, false));
    try std.testing.expectEqualStrings("A longer", text[0..lineEnd(text, 10, {}, M.width)]);
}

test "reset values survive config save and reload" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const root = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    var s: config.Settings = .{};
    s.cursor_blink = false;
    s.tab_size = 8;
    s.theme_name = .ayu;
    for ([_]Id{ .cursor_blink, .tab_size, .theme }) |id| reset(&s, id);
    try config.saveSettings(std.testing.allocator, io, root, s);
    const loaded = try config.loadSettings(std.testing.allocator, io, root);
    for ([_]Id{ .cursor_blink, .tab_size, .theme }) |id| try std.testing.expect(!changed(loaded, id));
    try std.testing.expectEqual((try config.Theme.builtin(std.testing.allocator, .one_dark)).editor, loaded.theme.editor);
}

test "keyboard reset requires a focused changed value" {
    var s: config.Settings = .{};
    s.tab_size = 8;
    try std.testing.expectEqual(Id.tab_size, keyboardResetTarget(s, .tab_size, true).?);
    try std.testing.expectEqual(@as(?Id, null), keyboardResetTarget(s, .tab_size, false));
    try std.testing.expectEqual(@as(?Id, null), keyboardResetTarget(s, .theme, true));
    try std.testing.expectEqual(@as(?Id, null), keyboardResetTarget(s, null, true));
}
