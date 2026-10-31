# Zed reference ledger

The reference checkout is inspected, never linked or edited. These are the source
areas informing the current design; they are not claims that Zid has ported all of
the corresponding behavior.

| Reference source | Observation | Zid decision |
| --- | --- | --- |
| `.ref/zed/assets/settings/default.json` | Default dark theme is One Dark; icon theme is Zed Default; `.ZedMono` and `.ZedSans` are the font defaults | Bundle the corresponding upstream theme, icons, Lilex and IBM Plex Sans |
| `.ref/zed/assets/themes/one/one.json` | UI text, editor text and each shell surface have separate semantic colors | Decode the upstream JSON schema directly; preserve distinct UI/editor fields |
| `.ref/zed/crates/rope/src/rope.rs` | Rope wraps chunks in a `SumTree` | Use tree-indexed pieces rather than treating a piece table and a rope as mutually exclusive choices |
| `.ref/zed/crates/sum_tree/src/sum_tree.rs` | `SumTree` is an Arc-backed B+ tree with subtree summaries and seek dimensions | Cache bytes/newlines in persistent nodes; benchmark our treap before deciding on a wider tree |
| `.ref/zed/crates/text/src/text.rs` | Buffer snapshots separate visible/deleted text and fragment/history state | Keep storage/snapshots and edit transactions headless; omit collaboration machinery for the personal editor |
| `.ref/zed/crates/editor/src/display_map.rs` | Display layout composes inlay/fold/tab/wrap/block maps over text snapshots | Keep text coordinates separate from display coordinates, rather than embedding wrapping or rendering in storage |
| `.ref/zed/crates/editor/src/display_map/tab_map.rs` | Tab expansion has its own versioned map and explicit bounds | Tab stops must retain the original line column across highlighted runs; richer display maps belong to the next text milestone |
| `.ref/zed/crates/title_bar/src/title_bar.rs` | Title bar belongs to the workspace shell, separate from the editor model | Isolate title-bar rendering and caption actions from document editing |
| `/home/addo/dev/stupid/chatƺpt/src/ui/window.zig` | Transparent borderless SDL window; radius 10 restored, 0 maximized | Same native-window treatment and hit-test behavior |
| `/home/addo/dev/stupid/chatƺpt/src/ui/app.zig` | Breeze caption controls and Adwaita caption controls have distinct spacing/backgrounds | Use the reference sizing, hover treatment and desktop symbolic glyph resolver |
| `/home/addo/dev/stupid/chatƺpt/patch/sdl-gpu-vulkan-transparent.patch` | SDL's transparent-window guard needs an exception for Vulkan | Build pinned SDL from a patched disposable source copy |

The current UI still uses its older gap-buffer Document. The persistent tree and
Source are independently tested and await M2 integration. Zed's complete display
maps, collaboration/history model and B+ tree have not been copied or declared
implemented. Future LSP, terminal, diff, database and notebook work must start with
a fresh source check in the relevant reference crates and a bounded design note.
