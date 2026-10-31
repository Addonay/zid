//! Editor state stays independent of SDL, rendering, and the layout engine.
pub const Buffer = @import("editor/buffer.zig").Buffer;
pub const Document = @import("editor/document.zig").Document;
pub const Workspace = @import("editor/workspace.zig").Workspace;
test {
    _ = @import("editor/buffer.zig");
    _ = @import("editor/document.zig");
    _ = @import("editor/workspace.zig");
}

pub const syntax = @import("syntax/root.zig");
pub const text = @import("text/piece_tree.zig");
test {
    _ = syntax;
    _ = text;
}
