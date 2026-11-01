//! Embed the supplied Zed keymaps unchanged; layering lives in the application.
const builtin = @import("builtin");
pub const BaseKeymap = enum { Zed, VSCode, Atom, JetBrains, SublimeText, TextMate, Emacs, Cursor, None };
pub const zed_default_linux = @embedFile("keymaps/default-linux.json");
pub const platform_default = switch (builtin.os.tag) {
    .macos => @embedFile("keymaps/default-macos.json"),
    .windows => @embedFile("keymaps/default-windows.json"),
    else => zed_default_linux,
};
pub const initial = @embedFile("keymaps/initial.json");
pub const vim = @embedFile("keymaps/vim.json");
pub const specific_overrides = if (builtin.os.tag == .macos) @embedFile("keymaps/specific-overrides-macos.json") else @embedFile("keymaps/specific-overrides.json");
pub fn base(name: BaseKeymap) ?[]const u8 {
    if (builtin.os.tag == .macos) return switch (name) {
        .Zed, .None => null,
        .VSCode => @embedFile("keymaps/macos/vscode.json"),
        .Atom => @embedFile("keymaps/macos/atom.json"),
        .JetBrains => @embedFile("keymaps/macos/jetbrains.json"),
        .SublimeText => @embedFile("keymaps/macos/sublime_text.json"),
        .TextMate => @embedFile("keymaps/macos/textmate.json"),
        .Emacs => @embedFile("keymaps/macos/emacs.json"),
        .Cursor => @embedFile("keymaps/macos/cursor.json"),
    };
    return switch (name) {
        .Zed, .None, .TextMate => null,
        .VSCode => @embedFile("keymaps/linux/vscode.json"),
        .Atom => @embedFile("keymaps/linux/atom.json"),
        .JetBrains => @embedFile("keymaps/linux/jetbrains.json"),
        .SublimeText => @embedFile("keymaps/linux/sublime_text.json"),
        .Emacs => @embedFile("keymaps/linux/emacs.json"),
        .Cursor => @embedFile("keymaps/linux/cursor.json"),
    };
}
