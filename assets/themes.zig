//! Byte-exact upstream Zed theme bundles used by Zid's runtime schema adapter.
pub const ThemeName = enum {
    one_dark,
    one_dark_pro_glass,
    ayu,
    gruvbox,
    solarized,
    tokyo_night,
    catppuccin,
    vscode,
};

pub const Builtin = struct {
    /// Original upstream JSON bytes, embedded without schema conversion.
    bytes: []const u8,
    /// Exact entry name used inside the upstream theme bundle.
    selector_name: []const u8,
};

pub fn builtin(name: ThemeName) Builtin {
    return switch (name) {
        .one_dark => .{ .bytes = @embedFile("themes/one.json"), .selector_name = "One Dark" },
        .one_dark_pro_glass => .{ .bytes = @embedFile("themes/one-dark-pro-glass.json"), .selector_name = "One Dark Pro Glass" },
        .ayu => .{ .bytes = @embedFile("themes/ayu.json"), .selector_name = "Ayu Dark" },
        .gruvbox => .{ .bytes = @embedFile("themes/gruvbox.json"), .selector_name = "Gruvbox Dark" },
        .solarized => .{ .bytes = @embedFile("themes/solarized-dark.json"), .selector_name = "Solarized Dark (VS Code)" },
        .tokyo_night => .{ .bytes = @embedFile("themes/tokyo-night.json"), .selector_name = "Tokyo Night" },
        .catppuccin => .{ .bytes = @embedFile("themes/catppuccin-mauve.json"), .selector_name = "Catppuccin Mocha" },
        .vscode => .{ .bytes = @embedFile("themes/dark-modern.json"), .selector_name = "Dark Modern (VS Code)" },
    };
}

test "built-in selections identify original JSON entries" {
    const std = @import("std");
    for ([_]ThemeName{ .one_dark, .one_dark_pro_glass, .ayu, .gruvbox, .solarized, .tokyo_night, .catppuccin, .vscode }) |name| {
        const entry = builtin(name);
        try std.testing.expect(std.mem.startsWith(u8, entry.bytes, "{"));
        try std.testing.expect(entry.selector_name.len != 0);
    }
}
