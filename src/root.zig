//! Editor state stays independent of SDL, rendering, and the layout engine.
pub const TextBuffer = @import("editor/text_buffer.zig").TextBuffer;
pub const Document = @import("editor/document.zig").Document;
pub const commands = @import("editor/commands.zig");
pub const search = @import("editor/search.zig");
pub const find = @import("editor/find.zig");
pub const Workspace = @import("editor/workspace.zig").Workspace;
pub const git = @import("git/root.zig");
pub const database = @import("database/root.zig");
test {
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
