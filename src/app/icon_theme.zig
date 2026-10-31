//! Icon theme selection. "Zed Default" (monochrome SVGs tinted by the UI theme) is the
//! default; "Catppuccin Latte" is the bundled multi-color alternative. Like Zed, a theme
//! that has no icon for an entry falls back to the default theme's icon.
const std = @import("std");
const icons = @import("icons");
const latte = @import("icon_theme_assets");

pub const Name = enum {
    zed_default,
    catppuccin_latte,

    pub fn label(self: Name) []const u8 {
        return switch (self) {
            .zed_default => "Zed (Default)",
            .catppuccin_latte => latte.display_name,
        };
    }
};

pub const Icon = struct {
    svg: []const u8,
    /// Colored icons keep their own colors; monochrome ones are tinted.
    colored: bool = false,
};

pub fn file(name: Name, path: []const u8) Icon {
    if (name == .catppuccin_latte) if (latte.fileIcon(std.fs.path.basename(path))) |svg| return .{ .svg = svg, .colored = true };
    return .{ .svg = icons.fileForPath(path) };
}

pub fn folder(name: Name, dir_name: []const u8, expanded: bool) Icon {
    if (name == .catppuccin_latte) return .{ .svg = latte.directoryIcon(dir_name, expanded), .colored = true };
    return .{ .svg = icons.svg(if (expanded) "folder_open" else "folder") };
}
