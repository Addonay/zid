const std = @import("std");
pub const theme_module = @import("theme.zig");
pub const Theme = theme_module.Theme;
pub const Settings = struct {
    font_size: u32 = 15,
    line_height: u32 = 23,
    panel_width: u32 = 240,
    tab_size: u32 = 4,
    cursor_blink: bool = true,
    auto_fold_dirs: bool = true,
    show_indent_guides: bool = true,
    theme_name: theme_module.ThemeName = .one_dark,
    icon_theme: @import("icon_theme.zig").Name = .zed_default,
    theme: Theme = .{},
};
pub const Binding = struct { key: []const u8, action: Action };
pub const Action = enum { save, save_as, new, close, quit, undo, redo, copy, cut, paste, select_all, toggle_panel, next_tab, previous_tab, open, reload_config, open_settings };
pub const defaults = [_]Binding{
    .{ .key = "Ctrl+s", .action = .save },                 .{ .key = "Ctrl+Shift+s", .action = .save_as },
    .{ .key = "Ctrl+n", .action = .new },                  .{ .key = "Ctrl+w", .action = .close },
    .{ .key = "Ctrl+q", .action = .quit },                 .{ .key = "Ctrl+z", .action = .undo },
    .{ .key = "Ctrl+Shift+z", .action = .redo },           .{ .key = "Ctrl+y", .action = .redo },
    .{ .key = "Ctrl+c", .action = .copy },                 .{ .key = "Ctrl+x", .action = .cut },
    .{ .key = "Ctrl+v", .action = .paste },                .{ .key = "Ctrl+a", .action = .select_all },
    .{ .key = "Ctrl+b", .action = .toggle_panel },         .{ .key = "Ctrl+Tab", .action = .next_tab },
    .{ .key = "Ctrl+Shift+Tab", .action = .previous_tab }, .{ .key = "Ctrl+o", .action = .open },
    .{ .key = "Ctrl+Shift+r", .action = .reload_config },  .{ .key = "Ctrl+,", .action = .open_settings },
};

/// Replace comments and trailing commas with spaces, retaining byte positions.
/// Strings (including escaped quotes and comment-like content) remain untouched.
pub fn jsonc(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, input);
    var i: usize = 0;
    var quoted = false;
    while (i < out.len) {
        if (quoted) {
            if (out[i] == '\\') {
                i += @min(@as(usize, 2), out.len - i);
                continue;
            }
            if (out[i] == '"') quoted = false;
            i += 1;
            continue;
        }
        if (out[i] == '"') {
            quoted = true;
            i += 1;
            continue;
        }
        if (i + 1 < out.len and out[i] == '/' and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else if (i + 1 < out.len and out[i] == '/' and out[i + 1] == '*') {
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
            while (i + 1 < out.len and !(out[i] == '*' and out[i + 1] == '/')) : (i += 1) {
                if (out[i] != '\n') out[i] = ' ';
            }
            if (i + 1 >= out.len) {
                gpa.free(out);
                return error.UnterminatedComment;
            }
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
        } else i += 1;
    }
    quoted = false;
    i = 0;
    while (i < out.len) : (i += 1) {
        if (quoted) {
            if (out[i] == '\\') {
                i += @intFromBool(i + 1 < out.len);
                continue;
            }
            if (out[i] == '"') quoted = false;
            continue;
        }
        if (out[i] == '"') {
            quoted = true;
            continue;
        }
        if (out[i] == ',') {
            var j = i + 1;
            while (j < out.len and std.ascii.isWhitespace(out[j])) : (j += 1) {}
            if (j < out.len and (out[j] == '}' or out[j] == ']')) out[i] = ' ';
        }
    }
    return out;
}

pub fn load(comptime T: type, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(T) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024));
    defer gpa.free(bytes);
    const clean = try jsonc(gpa, bytes);
    defer gpa.free(clean);
    return std.json.parseFromSlice(T, gpa, clean, .{ .allocate = .alloc_always });
}
pub fn validate(s: Settings) !void {
    if (s.font_size < 10 or s.font_size > 40 or s.line_height < s.font_size or s.line_height > 80 or s.panel_width < 140 or s.panel_width > 600 or s.tab_size == 0 or s.tab_size > 16) return error.InvalidSettings;
}
test "JSONC preserves string content and accepts comments and trailing commas" {
    const bytes = try jsonc(std.testing.allocator, "{\"key\":\"https://x/*a*/\\\"\",/*hi*/\"n\":[1,],//x\n}");
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://x/*a*/\"", parsed.value.object.get("key").?.string);
}

pub fn loadSettings(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !Settings {
    const path = try std.fs.path.join(gpa, &.{ root, "settings.json" });
    defer gpa.free(path);
    var parsed = load(Settings, gpa, io, path) catch |err| {
        if (err == error.FileNotFound) return .{ .theme = try Theme.builtin(gpa, .one_dark) };
        return err;
    };
    defer parsed.deinit();
    var result = parsed.value;
    result.theme = try Theme.builtin(gpa, result.theme_name);
    // Apply only explicitly specified colors over the chosen builtin, rather
    // than replacing the chosen palette with the struct's One Dark defaults.
    var raw = try load(std.json.Value, gpa, io, path);
    defer raw.deinit();
    if (raw.value.object.get("theme")) |overrides| {
        if (overrides != .object) return error.InvalidTheme;
        inline for (@typeInfo(Theme).@"struct".field_names) |field| {
            if (overrides.object.get(field)) |value| {
                var color = try std.json.parseFromValue(@FieldType(Theme, field), gpa, value, .{});
                defer color.deinit();
                @field(result.theme, field) = color.value;
            }
        }
    }
    try validate(result);
    return result;
}

pub fn saveSettings(gpa: std.mem.Allocator, io: std.Io, root: []const u8, s: Settings) !void {
    std.Io.Dir.cwd().createDirPath(io, root) catch {};
    const path = try std.fs.path.join(gpa, &.{ root, "settings.json" });
    defer gpa.free(path);
    // Carry explicit color overrides forward; the UI only edits the scalar settings.
    var overrides: []u8 = &.{};
    defer gpa.free(overrides);
    if (load(std.json.Value, gpa, io, path)) |raw| {
        var parsed = raw;
        defer parsed.deinit();
        if (parsed.value == .object) if (parsed.value.object.get("theme")) |theme| if (theme == .object) {
            const json = try std.json.Stringify.valueAlloc(gpa, theme, .{});
            defer gpa.free(json);
            overrides = try std.fmt.allocPrint(gpa, ",\n    \"theme\": {s}", .{json});
        };
    } else |_| {}
    const content = try std.fmt.allocPrint(gpa,
        \\{{
        \\    "font_size": {d},
        \\    "line_height": {d},
        \\    "panel_width": {d},
        \\    "tab_size": {d},
        \\    "cursor_blink": {},
        \\    "auto_fold_dirs": {},
        \\    "show_indent_guides": {},
        \\    "theme_name": "{s}",
        \\    "icon_theme": "{s}"{s}
        \\}}
        \\
    , .{
        s.font_size,
        s.line_height,
        s.panel_width,
        s.tab_size,
        s.cursor_blink,
        s.auto_fold_dirs,
        s.show_indent_guides,
        @tagName(s.theme_name),
        @tagName(s.icon_theme),
        overrides,
    });
    defer gpa.free(content);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

test "settings save and reload preserves values" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try temporary.dir.realPath(io, &buffer)];
    const original: Settings = .{
        .font_size = 18,
        .line_height = 28,
        .panel_width = 280,
        .tab_size = 2,
        .cursor_blink = false,
        .auto_fold_dirs = true,
        .show_indent_guides = false,
        .theme_name = .catppuccin,
    };
    try saveSettings(std.testing.allocator, io, root, original);
    const loaded = try loadSettings(std.testing.allocator, io, root);
    try std.testing.expectEqual(original.font_size, loaded.font_size);
    try std.testing.expectEqual(original.line_height, loaded.line_height);
    try std.testing.expectEqual(original.panel_width, loaded.panel_width);
    try std.testing.expectEqual(original.tab_size, loaded.tab_size);
    try std.testing.expectEqual(original.cursor_blink, loaded.cursor_blink);
    try std.testing.expectEqual(original.auto_fold_dirs, loaded.auto_fold_dirs);
    try std.testing.expectEqual(original.show_indent_guides, loaded.show_indent_guides);
    try std.testing.expectEqual(original.theme_name, loaded.theme_name);
}

test "saving settings keeps explicit theme color overrides" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"theme_name\":\"ayu\",\"theme\":{\"text\":[1,2,3,255]},}" });
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var s = try loadSettings(std.testing.allocator, io, root);
    s.tab_size = 3;
    try saveSettings(std.testing.allocator, io, root, s);
    const loaded = try loadSettings(std.testing.allocator, io, root);
    try std.testing.expectEqual(@as(u32, 3), loaded.tab_size);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 255 }, loaded.theme.text);
}

test "settings select a builtin then apply only explicit color overrides" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"theme_name\":\"ayu\",\"theme\":{\"text\":[1,2,3,255]},\"tab_size\":2,}" });
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try temporary.dir.realPath(io, &buffer)];
    const s = try loadSettings(std.testing.allocator, io, root);
    try std.testing.expectEqual(@as(u32, 2), s.tab_size);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 255 }, s.theme.text);
    try std.testing.expectEqual((try Theme.builtin(std.testing.allocator, .ayu)).editor, s.theme.editor);
    try temporary.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"font_size\":0}" });
    try std.testing.expectError(error.InvalidSettings, loadSettings(std.testing.allocator, io, root));
}
