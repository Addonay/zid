//! Editor state stays independent of SDL, rendering, and the layout engine.
pub const TextBuffer = @import("editor/text_buffer.zig").TextBuffer;
pub const Document = @import("editor/document.zig").Document;
pub const commands = @import("editor/commands.zig");
pub const search = @import("editor/search.zig");
pub const find = @import("editor/find.zig");
pub const Workspace = @import("editor/workspace.zig").Workspace;
pub const git = @import("git/root.zig");
pub const database = @import("database/root.zig");
pub const lsp = @import("lsp/root.zig");
/// Zed crate ports (`.ref/zed/crates/*`).
pub const sum_tree = @import("sum_tree/sum_tree.zig");
pub const clock = @import("clock/clock.zig");
pub const rope = @import("rope/rope.zig");
pub const zed_text = @import("text/zed/root.zig");
pub const language = @import("language/language.zig");
pub const multi_buffer = @import("multi_buffer/multi_buffer.zig");
pub const display_map = @import("editor/display_map/root.zig");
test {
    _ = sum_tree;
    _ = clock;
    _ = rope;
    _ = zed_text;
    _ = language;
    _ = multi_buffer;
    _ = display_map;
    _ = lsp;
    _ = git;
    _ = database;
    _ = @import("editor/text_buffer.zig");
    _ = @import("editor/document.zig");
    _ = @import("editor/commands.zig");
    _ = search;
    _ = find;
    _ = @import("editor/workspace.zig");
}

pub const syntax = @import("syntax/root.zig");
pub const text = @import("text/piece_tree.zig");
test {
    _ = syntax;
    _ = text;
}

/// Read-only positional access and incremental indexing for large files.
pub const large_file = @import("text/large_file.zig");
pub const large_display = @import("text/large_display.zig");
pub const large_worker = @import("text/large_worker.zig");
test {
    _ = large_file;
    _ = large_display;
    _ = large_worker;
}

/// RSA for the zed.dev native-app sign-in flow.
pub const rsa = @import("core/rsa.zig");
test {
    _ = rsa;
}
