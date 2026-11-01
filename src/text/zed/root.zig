//! Port of Zed's `text` crate (`.ref/zed/crates/text/src`). Spec: docs/zed_port/text.md.
pub const patch = @import("patch.zig");
pub const Patch = patch.Patch;
pub const Edit = patch.Edit;
pub const Locator = @import("locator.zig").Locator;
pub const UndoMap = @import("undo_map.zig").UndoMap;
pub const LineEnding = @import("line.zig").LineEnding;
pub const LineIndent = @import("line.zig").LineIndent;
pub const Selection = @import("selection.zig").Selection;
pub const SelectionGoal = @import("selection.zig").SelectionGoal;
pub const buffer = @import("buffer.zig");
pub const subscription = @import("subscription.zig");
pub const Buffer = buffer.Buffer;
pub const BufferSnapshot = buffer.BufferSnapshot;
pub const Anchor = buffer.Anchor;
pub const BufferId = buffer.BufferId;

test {
    _ = patch;
    _ = @import("locator.zig");
    _ = @import("undo_map.zig");
    _ = @import("line.zig");
    _ = @import("selection.zig");
    _ = @import("subscription.zig");
    _ = buffer;
}
