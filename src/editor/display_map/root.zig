//! Port of Zed's editor display map (`.ref/zed/crates/editor/src/display_map.rs` and
//! `display_map/`). Spec: docs/zed_port/display_map.md. Layers: InlayMap -> FoldMap ->
//! TabMap -> WrapMap -> BlockMap. InlayMap and an initial FoldMap are present.
pub const inlay_map = @import("inlay_map.zig");
pub const fold_map = @import("fold_map.zig");

test {
    _ = inlay_map;
    _ = fold_map;
}
