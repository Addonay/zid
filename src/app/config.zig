const std = @import("std");
pub const theme_module = @import("theme.zig");
pub const Theme = theme_module.Theme;
pub const Settings = struct {
    font_size: u32 = 15,
    base_keymap: @import("keymap_assets").BaseKeymap = .Zed,
    vim_mode: bool = false,
    helix_mode: bool = false,
    // Zed's "comfortable" buffer line height is 1.618 x font size (`crates/theme/src/buffer_line_height.rs`),
    // which is 24.27px at the default 15px font; integer pixels are stored, so the default is 24.
    line_height: u32 = 24,
    panel_width: u32 = 240,
    tab_size: u32 = 4,
    cursor_blink: bool = true,
    auto_fold_dirs: bool = true,
    show_indent_guides: bool = true,
    theme_name: theme_module.ThemeName = .one_dark,
    icon_theme: @import("icon_theme.zig").Name = .zed_default,
    theme: Theme = .{},
    panel_right: bool = true,
    panel_starts_open: bool = true,
    panel_file_icons: bool = true,
    panel_folder_indicator: enum { icon, chevron, both } = .icon,
    panel_indent: u32 = 20,
    panel_standard_spacing: bool = false,
    panel_auto_reveal: bool = true,
    panel_button: bool = true,
    panel_scrollbar: bool = true,
    panel_sort_mode: @import("project.zig").SortMode = .directories_first,
    title_branch: bool = true,
    tab_nav_buttons: bool = true,
    tab_file_icons: bool = false,
    tab_bar_buttons: bool = true,
    title_project: bool = true,
    title_worktree: bool = true,
    /// Zed `use_system_path_prompts`: native open/save dialogs (default true).
    system_path_prompts: bool = true,
    title_sign_in: bool = true,
    title_user_menu: bool = true,
    title_user_picture: bool = true,
    status_visible: bool = true,
    status_language: bool = true,
    status_cursor: bool = true,
    status_line_endings: bool = false,
    status_encoding: bool = false,
};
/// Zed `ThemeAppearanceMode`. Missing or unknown modes mean `system`, as in Zed's
/// `ThemeSelection::Dynamic` default.
pub const ThemeMode = enum { light, dark, system };
pub const Appearance = enum { light, dark };
pub fn themeMode(selection: std.json.Value) ThemeMode {
    if (selection != .object) return .system;
    const mode = selection.object.get("mode") orelse return .system;
    if (mode != .string) return .system;
    return std.meta.stringToEnum(ThemeMode, mode.string) orelse .system;
}
pub fn themeAppearance(mode: ThemeMode, system: Appearance) Appearance {
    return switch (mode) {
        .light => .light,
        .dark => .dark,
        .system => system,
    };
}
/// Desktop light/dark preference. The app sets it from SDL at startup and on
/// `system_theme_changed`; config stays SDL-free. Dark is Zed's fallback appearance.
pub var system_appearance: Appearance = .dark;
pub fn systemAppearance() Appearance {
    return system_appearance;
}
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
    if (s.font_size < 10 or s.font_size > 40 or s.line_height < s.font_size or s.line_height > 80 or s.panel_width < 140 or s.panel_width > 600 or s.tab_size == 0 or s.tab_size > 16 or s.panel_indent > 64) return error.InvalidSettings;
}
test "JSONC preserves string content and accepts comments and trailing commas" {
    const bytes = try jsonc(std.testing.allocator, "{\"key\":\"https://x/*a*/\\\"\",/*hi*/\"n\":[1,],//x\n}");
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://x/*a*/\"", parsed.value.object.get("key").?.string);
}

pub fn loadSettings(gpa: std.mem.Allocator, io: std.Io, root: []const u8) !Settings {
    var document = try @import("settings_document.zig").Document.load(gpa, io, root);
    defer document.deinit();
    return settingsFromDocument(gpa, &document);
}

pub fn settingsFromDocument(gpa: std.mem.Allocator, document: *const @import("settings_document.zig").Document) !Settings {
    const Document = @import("settings_document.zig").Document;
    var effective = try Document.parse(gpa, @import("settings_assets").defaults);
    defer effective.deinit();
    try effective.merge(document);
    // Only old Zid files use these aliases; never rewrite the supplied default JSON.
    const aliases = .{
        .{ "font_size", &.{"buffer_font_size"} },
        .{ "panel_width", &.{ "project_panel", "default_width" } },
        .{ "auto_fold_dirs", &.{ "project_panel", "auto_fold_dirs" } },
    };
    inline for (aliases) |mapping| {
        if (document.get(mapping[1]) == null) if (document.get(&.{mapping[0]})) |v| try effective.set(mapping[1], v);
    }
    if (document.get(&.{"buffer_line_height"}) == null) if (document.get(&.{"line_height"})) |v| {
        const font = try numeric(effective.get(&.{"buffer_font_size"}).?);
        if (font <= 0) return error.InvalidSettings;
        var buffer: [96]u8 = undefined;
        try effective.setJson(&.{"buffer_line_height"}, try std.fmt.bufPrint(&buffer, "{{\"custom\":{d}}}", .{try numeric(v) / font}));
    };
    if (document.get(&.{ "project_panel", "indent_guides", "show" }) == null) if (document.get(&.{"show_indent_guides"})) |v| {
        if (v != .bool) return error.InvalidSettings;
        try effective.set(&.{ "project_panel", "indent_guides", "show" }, .{ .string = if (v.bool) "always" else "never" });
    };
    if (document.get(&.{"theme"})) |v| {
        if (v == .string or (v == .object and v.object.get("mode") != null)) effective.remove(&.{"theme_name"});
    }
    return decodeSettings(gpa, &effective);
}

fn decodeSettings(gpa: std.mem.Allocator, document: *const @import("settings_document.zig").Document) !Settings {
    var result: Settings = .{};
    if (document.get(&.{"base_keymap"})) |v| {
        if (v != .string) return error.InvalidSettings;
        result.base_keymap = std.meta.stringToEnum(@import("keymap_assets").BaseKeymap, v.string) orelse return error.InvalidSettings;
    }
    if (document.get(&.{"vim_mode"})) |v| try assignScalar(&result, "vim_mode", v);
    if (document.get(&.{"helix_mode"})) |v| try assignScalar(&result, "helix_mode", v);
    // Legacy Zid names remain readable; canonical Zed names take precedence.
    const mappings = .{
        .{ "font_size", &.{"buffer_font_size"} },
        .{ "panel_width", &.{ "project_panel", "default_width" } },
        .{ "tab_size", &.{"tab_size"} },
        .{ "cursor_blink", &.{"cursor_blink"} },
        .{ "auto_fold_dirs", &.{ "project_panel", "auto_fold_dirs" } },
    };
    inline for (mappings) |mapping| {
        if (document.get(&.{mapping[0]})) |value| try assignScalar(&result, mapping[0], value);
        if (document.get(mapping[1])) |value| try assignScalar(&result, mapping[0], value);
    }
    if (document.get(&.{"line_height"})) |v| try assignScalar(&result, "line_height", v);
    if (document.get(&.{"show_indent_guides"})) |v| try assignScalar(&result, "show_indent_guides", v);
    if (document.get(&.{"theme"})) |v| {
        const name = if (v == .string) v.string else if (v == .object) blk: {
            const key = if (themeAppearance(themeMode(v), systemAppearance()) == .light) "light" else "dark";
            const entry = v.object.get(key) orelse break :blk "";
            break :blk if (entry == .string) entry.string else "";
        } else "";
        inline for (std.enums.values(theme_module.ThemeName)) |theme_name| {
            if (std.mem.eql(u8, name, @import("theme_assets").builtin(theme_name).selector_name)) result.theme_name = theme_name;
        }
    }
    if (document.get(&.{"theme_name"})) |v| if (v == .string) {
        result.theme_name = std.meta.stringToEnum(theme_module.ThemeName, v.string) orelse .one_dark;
    };
    if (document.get(&.{"icon_theme"})) |v| if (v == .string) {
        inline for (std.enums.values(@import("icon_theme.zig").Name)) |name| {
            if (std.mem.eql(u8, v.string, name.label()) or std.mem.eql(u8, v.string, @tagName(name))) result.icon_theme = name;
        }
    };
    if (document.get(&.{"buffer_line_height"})) |v| {
        var factor: f64 = 1.618;
        if (v == .string) {
            if (std.mem.eql(u8, v.string, "standard")) factor = 1.3;
        } else if (v == .object) {
            if (v.object.get("custom")) |custom| factor = try numeric(custom);
        }
        if (!std.math.isFinite(factor) or factor < 1 or factor > 8) return error.InvalidSettings;
        result.line_height = @intFromFloat(@as(f64, @floatFromInt(result.font_size)) * factor);
    } else if (document.get(&.{"line_height"}) == null) {
        result.line_height = @intFromFloat(@as(f64, @floatFromInt(result.font_size)) * 1.618);
    }
    const bool_mappings = .{
        .{ "panel_starts_open", &.{ "project_panel", "starts_open" } },
        .{ "panel_file_icons", &.{ "project_panel", "file_icons" } },
        .{ "panel_auto_reveal", &.{ "project_panel", "auto_reveal_entries" } },
        .{ "panel_button", &.{ "project_panel", "button" } },
        .{ "title_branch", &.{ "title_bar", "show_branch_name" } },
        .{ "tab_nav_buttons", &.{ "tab_bar", "show_nav_history_buttons" } },
        .{ "tab_file_icons", &.{ "tabs", "file_icons" } },
        .{ "tab_bar_buttons", &.{ "tab_bar", "show_tab_bar_buttons" } },
        .{ "title_project", &.{ "title_bar", "show_project_items" } },
        .{ "title_worktree", &.{ "title_bar", "show_worktree_name" } },
        .{ "system_path_prompts", &.{"use_system_path_prompts"} },
        .{ "title_sign_in", &.{ "title_bar", "show_sign_in" } },
        .{ "title_user_menu", &.{ "title_bar", "show_user_menu" } },
        .{ "title_user_picture", &.{ "title_bar", "show_user_picture" } },
        .{ "status_visible", &.{ "status_bar", "experimental.show" } },
        .{ "status_language", &.{ "status_bar", "active_language_button" } },
        .{ "status_cursor", &.{ "status_bar", "cursor_position_button" } },
        .{ "status_line_endings", &.{ "status_bar", "line_endings_button" } },
    };
    inline for (bool_mappings) |mapping| if (document.get(mapping[1])) |v| try assignScalar(&result, mapping[0], v);
    if (document.get(&.{ "project_panel", "indent_size" })) |v| try assignScalar(&result, "panel_indent", v);
    if (document.get(&.{ "project_panel", "dock" })) |v| if (v == .string) {
        result.panel_right = std.mem.eql(u8, v.string, "right");
    };
    if (document.get(&.{ "project_panel", "entry_spacing" })) |v| if (v == .string) {
        result.panel_standard_spacing = std.mem.eql(u8, v.string, "standard");
    };
    if (document.get(&.{ "project_panel", "folder_indicator" })) |v| if (v == .string) {
        result.panel_folder_indicator = std.meta.stringToEnum(@FieldType(Settings, "panel_folder_indicator"), v.string) orelse .icon;
    };
    if (document.get(&.{ "project_panel", "sort_mode" })) |v| if (v == .string) {
        result.panel_sort_mode = std.meta.stringToEnum(@FieldType(Settings, "panel_sort_mode"), v.string) orelse .directories_first;
    };
    if (document.get(&.{ "project_panel", "indent_guides", "show" })) |v| if (v == .string) {
        result.show_indent_guides = !std.mem.eql(u8, v.string, "never");
    };
    if (document.get(&.{ "project_panel", "scrollbar", "show" })) |v| if (v == .string) {
        result.panel_scrollbar = !std.mem.eql(u8, v.string, "never");
    };
    if (document.get(&.{ "status_bar", "active_encoding_button" })) |v| if (v == .string) {
        result.status_encoding = std.mem.eql(u8, v.string, "always");
    };
    result.theme = try Theme.builtin(gpa, result.theme_name);
    // Apply only explicitly specified colors over the chosen builtin, rather
    // than replacing the chosen palette with the struct's One Dark defaults.
    if (document.get(&.{"theme"})) |overrides| {
        if (overrides == .object) inline for (@typeInfo(Theme).@"struct".field_names) |field| {
            if (overrides.object.get(field)) |value| {
                var color = try std.json.parseFromValue(@FieldType(Theme, field), gpa, value, .{});
                defer color.deinit();
                @field(result.theme, field) = color.value;
            }
        };
    }
    try validate(result);
    return result;
}

fn numeric(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => error.InvalidSettings,
    };
}
fn assignScalar(s: *Settings, comptime name: []const u8, value: std.json.Value) !void {
    const T = @FieldType(Settings, name);
    if (T == bool) {
        if (value != .bool) return error.InvalidSettings;
        @field(s, name) = value.bool;
    } else {
        const n = try numeric(value);
        if (!std.math.isFinite(n) or n < 0 or n > std.math.maxInt(u32)) return error.InvalidSettings;
        @field(s, name) = @intFromFloat(n);
    }
}

pub fn saveSettings(gpa: std.mem.Allocator, io: std.Io, root: []const u8, s: Settings) !void {
    try validate(s);
    var document = try @import("settings_document.zig").Document.load(gpa, io, root);
    defer document.deinit();
    const previous = try settingsFromDocument(gpa, &document);
    if (previous.font_size != s.font_size or document.get(&.{"font_size"}) != null) try document.set(&.{"buffer_font_size"}, .{ .integer = s.font_size });
    var height_buffer: [96]u8 = undefined;
    const height = try std.fmt.bufPrint(&height_buffer, "{{\"custom\":{d}}}", .{@as(f64, @floatFromInt(s.line_height)) / @as(f64, @floatFromInt(s.font_size))});
    if (previous.line_height != s.line_height or previous.font_size != s.font_size or document.get(&.{"line_height"}) != null) try document.setJson(&.{"buffer_line_height"}, height);
    if (previous.tab_size != s.tab_size) try document.set(&.{"tab_size"}, .{ .integer = s.tab_size });
    if (previous.cursor_blink != s.cursor_blink) try document.set(&.{"cursor_blink"}, .{ .bool = s.cursor_blink });
    if (previous.panel_width != s.panel_width or document.get(&.{"panel_width"}) != null) try document.set(&.{ "project_panel", "default_width" }, .{ .integer = s.panel_width });
    if (previous.auto_fold_dirs != s.auto_fold_dirs or document.get(&.{"auto_fold_dirs"}) != null) try document.set(&.{ "project_panel", "auto_fold_dirs" }, .{ .bool = s.auto_fold_dirs });
    if (previous.show_indent_guides != s.show_indent_guides or document.get(&.{"show_indent_guides"}) != null) try document.set(&.{ "project_panel", "indent_guides", "show" }, .{ .string = if (s.show_indent_guides) "always" else "never" });
    // Keep the legacy color override object intact during migration.
    const old_theme = document.get(&.{"theme"});
    const legacy_colors = if (old_theme) |v| v == .object and v.object.get("text") != null else false;
    if (legacy_colors) {
        try document.set(&.{"theme_name"}, .{ .string = @tagName(s.theme_name) });
    } else if (previous.theme_name != s.theme_name or document.get(&.{"theme_name"}) != null) {
        try document.set(&.{"theme"}, .{ .string = @import("theme_assets").builtin(s.theme_name).selector_name });
        document.remove(&.{"theme_name"});
    }
    if (previous.icon_theme != s.icon_theme) try document.set(&.{"icon_theme"}, .{ .string = s.icon_theme.label() });
    for ([_][]const u8{ "font_size", "line_height", "panel_width", "auto_fold_dirs", "show_indent_guides" }) |key| document.remove(&.{key});
    try document.save(gpa, io, root);
}

test "upstream default snapshot decodes and empty user settings use shell defaults" {
    var doc = try @import("settings_document.zig").Document.parse(std.testing.allocator, @import("settings_assets").defaults);
    defer doc.deinit();
    const s = try settingsFromDocument(std.testing.allocator, &doc);
    try std.testing.expectEqual(@as(u32, 15), s.font_size);
    try std.testing.expect(s.panel_right);
    try std.testing.expectEqual(@as(u32, 240), s.panel_width);
    try std.testing.expect(!s.status_line_endings);
    try std.testing.expect(!s.status_encoding);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const empty = try loadSettings(std.testing.allocator, std.testing.io, root);
    try std.testing.expectEqual(s.font_size, empty.font_size);
    try std.testing.expectEqual(s.panel_folder_indicator, empty.panel_folder_indicator);
}

test "editing one setting preserves unsupported values and theme selection mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{\"theme\":{\"mode\":\"system\",\"dark\":\"One Dark\",\"light\":\"One Light\"},\"terminal\":{\"shell\":\"system\"},\"future_setting\":[1,2,3]}" });
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var s = try loadSettings(std.testing.allocator, io, root);
    s.tab_size = 8;
    try saveSettings(std.testing.allocator, io, root, s);
    var doc = try @import("settings_document.zig").Document.load(std.testing.allocator, io, root);
    defer doc.deinit();
    try std.testing.expectEqualStrings("system", doc.get(&.{ "theme", "mode" }).?.string);
    try std.testing.expectEqualStrings("system", doc.get(&.{ "terminal", "shell" }).?.string);
    try std.testing.expectEqual(@as(usize, 3), doc.get(&.{"future_setting"}).?.array.items.len);
    try std.testing.expect(doc.get(&.{"buffer_font_size"}) == null);
    try std.testing.expectEqual(@as(i64, 8), doc.get(&.{"tab_size"}).?.integer);
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
