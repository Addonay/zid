//! Adapter for unmodified upstream Zed theme JSON. Source palettes stay in
//! assets/themes; only runtime values needed by Zid's current views are decoded.
const std = @import("std");
const token = @import("zid").syntax;
const sources = @import("theme_assets");
pub const Color = [4]u8;
pub const ThemeName = sources.ThemeName;
const TokenStyle = struct { color: ?Color = null, italic: bool = false };
pub const Theme = struct {
    background: Color = .{ 59, 65, 77, 255 },
    surface: Color = .{ 47, 52, 62, 255 },
    border: Color = .{ 70, 75, 87, 255 },
    text: Color = .{ 220, 224, 229, 255 },
    muted: Color = .{ 169, 175, 188, 255 },
    line_number: Color = .{ 78, 90, 95, 255 },
    selected: Color = .{ 69, 74, 86, 255 },
    selection: Color = .{ 116, 173, 232, 61 },
    accent: Color = .{ 116, 173, 232, 255 },
    comment: Color = .{ 93, 99, 111, 255 },
    keyword: Color = .{ 180, 119, 207, 255 },
    string: Color = .{ 161, 193, 129, 255 },
    number: Color = .{ 191, 149, 106, 255 },
    type: Color = .{ 110, 180, 191, 255 },
    function_color: Color = .{ 115, 173, 233, 255 },
    error_text: Color = .{ 208, 114, 119, 255 },
    title_bar: Color = .{ 59, 65, 77, 255 },
    tab_bar: Color = .{ 47, 52, 62, 255 },
    active_tab: Color = .{ 40, 44, 51, 255 },
    panel: Color = .{ 47, 52, 62, 255 },
    editor: Color = .{ 40, 44, 51, 255 },
    status: Color = .{ 59, 65, 77, 255 },
    editor_foreground: Color = .{ 172, 178, 190, 255 },
    active_line: Color = .{ 47, 52, 62, 191 },
    border_variant: Color = .{ 54, 60, 70, 255 },
    border_focused: Color = .{ 71, 103, 158, 255 },
    elevated_surface: Color = .{ 47, 52, 62, 255 },
    element_background: Color = .{ 46, 52, 62, 255 },
    element_hover: Color = .{ 54, 60, 70, 255 },
    element_selected: Color = .{ 69, 74, 86, 255 },
    ghost_element_hover: Color = .{ 54, 60, 70, 255 },
    ghost_element_selected: Color = .{ 69, 74, 86, 255 },
    placeholder: Color = .{ 135, 138, 152, 255 },
    indent_guide: Color = .{ 59, 62, 69, 255 },
    indent_guide_active: Color = .{ 84, 89, 99, 255 },
    scrollbar_thumb: Color = .{ 200, 204, 212, 76 },
    tokens: [@typeInfo(token.Kind).@"enum".field_names.len]TokenStyle = @splat(.{}),

    pub fn builtin(gpa: std.mem.Allocator, name: ThemeName) !Theme {
        const source = sources.builtin(name);
        return parse(gpa, source.bytes, source.selector_name);
    }
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8) !Theme {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidTheme;
        const themes = root.object.get("themes") orelse return error.InvalidTheme;
        if (themes != .array) return error.InvalidTheme;
        for (themes.array.items) |entry| {
            if (entry != .object) continue;
            const n = entry.object.get("name") orelse continue;
            if (n != .string or !std.mem.eql(u8, n.string, name)) continue;
            const style = entry.object.get("style") orelse return error.InvalidTheme;
            if (style != .object) return error.InvalidTheme;
            var result: Theme = .{};
            const fields = .{
                .{ "background", "background" },          .{ "surface", "surface.background" }, .{ "border", "border" },                    .{ "text", "text" },              .{ "muted", "text.muted" },         .{ "line_number", "editor.line_number" }, .{ "selected", "element.selected" },           .{ "accent", "text.accent" },                        .{ "error_text", "error" },
                .{ "title_bar", "title_bar.background" }, .{ "tab_bar", "tab_bar.background" }, .{ "active_tab", "tab.active_background" }, .{ "panel", "panel.background" }, .{ "editor", "editor.background" }, .{ "status", "status_bar.background" },   .{ "editor_foreground", "editor.foreground" }, .{ "active_line", "editor.active_line.background" },
                .{ "border_variant", "border.variant" },  .{ "border_focused", "border.focused" }, .{ "elevated_surface", "elevated_surface.background" }, .{ "element_background", "element.background" }, .{ "element_hover", "element.hover" }, .{ "element_selected", "element.selected" }, .{ "ghost_element_hover", "ghost_element.hover" }, .{ "ghost_element_selected", "ghost_element.selected" }, .{ "placeholder", "text.placeholder" },
                .{ "indent_guide", "panel.indent_guide" }, .{ "indent_guide_active", "panel.indent_guide_active" }, .{ "scrollbar_thumb", "scrollbar.thumb.background" },
            };
            inline for (fields) |pair| if (style.object.get(pair[1])) |value| {
                if (try parseColor(value)) |color| @field(result, pair[0]) = color;
            };
            if (style.object.get("players")) |players| if (players == .array and players.array.items.len > 0) {
                const player = players.array.items[0];
                if (player == .object) if (player.object.get("selection")) |value| {
                    if (try parseColor(value)) |color| result.selection = color;
                };
            };
            if (style.object.get("syntax")) |syntax| if (syntax == .object) {
                const basics = .{ .{ "comment", "comment" }, .{ "keyword", "keyword" }, .{ "string", "string" }, .{ "number", "number" }, .{ "type", "type" }, .{ "function_color", "function" } };
                inline for (basics) |pair| {
                    const decoded = try decodeStyle(syntax, pair[1]);
                    if (decoded.color) |color| @field(result, pair[0]) = color;
                }
                inline for (@typeInfo(token.Kind).@"enum".field_names, 0..) |kind, i| result.tokens[i] = try decodeStyle(syntax, syntaxKey(@field(token.Kind, kind)));
            };
            return result;
        }
        return error.ThemeNotFound;
    }
    pub fn syntaxColor(self: Theme, kind: token.Kind) Color {
        if (self.tokens[@backingInt(kind)].color) |color| return color;
        return switch (kind) {
            .comment, .comment_doc => self.comment,
            .keyword, .keyword_control, .preprocessor, .attribute => self.keyword,
            .string, .char, .link_uri => self.string,
            .number, .constant, .string_escape => self.number,
            .type, .title, .strong => self.type,
            .function, .builtin, .link_text => self.function_color,
            else => self.editor_foreground,
        };
    }
    pub fn italic(self: Theme, kind: token.Kind) bool {
        return self.tokens[@backingInt(kind)].italic;
    }
};
fn syntaxKey(kind: token.Kind) []const u8 {
    return switch (kind) {
        .plain => "variable",
        .comment_doc => "comment.doc",
        .keyword_control => "keyword.control",
        .string_escape => "string.escape",
        .char => "string",
        .builtin => "function.builtin",
        .variable_special => "variable.special",
        .preprocessor => "preproc",
        .title => "title",
        .code => "string.special",
        .link_text => "link_text",
        .link_uri => "link_uri",
        .list_marker => "punctuation.list_marker",
        else => @tagName(kind),
    };
}
fn decodeStyle(syntax: std.json.Value, key: []const u8) !TokenStyle {
    var entry = syntax.object.get(key);
    if (entry == null) if (std.mem.indexOfScalar(u8, key, '.')) |dot| {
        entry = syntax.object.get(key[0..dot]);
    };
    const value = entry orelse return .{};
    if (value == .null) return .{};
    if (value != .object) return error.InvalidTheme;
    var result: TokenStyle = .{};
    if (value.object.get("color")) |color| result.color = try parseColor(color);
    if (value.object.get("font_style")) |font| if (font == .string) {
        result.italic = std.mem.eql(u8, font.string, "italic");
    };
    return result;
}
fn parseColor(value: std.json.Value) !?Color {
    if (value == .null) return null;
    if (value != .string) return error.InvalidThemeColor;
    const hex = value.string;
    if ((hex.len != 7 and hex.len != 9) or hex[0] != '#') return error.InvalidThemeColor;
    var color: Color = .{ 0, 0, 0, 255 };
    for (0..(hex.len - 1) / 2) |i| color[i] = std.fmt.parseInt(u8, hex[1 + i * 2 ..][0..2], 16) catch return error.InvalidThemeColor;
    return color;
}
test "unmodified upstream JSON supplies builtin palettes at runtime" {
    var last: Color = undefined;
    for (std.enums.values(ThemeName), 0..) |name, i| {
        const theme = try Theme.builtin(std.testing.allocator, name);
        if (i == 0) {
            try std.testing.expectEqual(Color{ 220, 224, 229, 255 }, theme.text);
            try std.testing.expectEqual(Color{ 40, 44, 51, 255 }, theme.editor);
        }
        if (i > 0) try std.testing.expect(!std.mem.eql(u8, &last, &theme.editor));
        last = theme.editor;
    }
}
test "JSON theme adapter retains transparency and italic token styles" {
    const t = try Theme.parse(std.testing.allocator, "{\"themes\":[{\"name\":\"Example\",\"style\":{\"background\":\"#01020304\",\"syntax\":{\"keyword\":{\"color\":\"#aabbcc\",\"font_style\":\"italic\"}}}}]}", "Example");
    try std.testing.expectEqual(Color{ 1, 2, 3, 4 }, t.background);
    try std.testing.expectEqual(Color{ 170, 187, 204, 255 }, t.syntaxColor(.keyword_control));
    try std.testing.expect(t.italic(.keyword));
}
