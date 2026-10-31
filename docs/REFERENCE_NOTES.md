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
| `.ref/zed/crates/project_panel/src/project_panel.rs`, `crates/ui/src/components/list/list_item.rs` | Entries are `ListItem`s with `ListItemSpacing::Dense` (comfortable): `h_6` rows, `Base06` padding, `indent_size` 20, 16px icon slot, `gap_1`, 14px labels in `text`, muted icons; hover `element.hover`, marked `element.selected`; guides at 15px + 20px·depth in `panel.indent_guide` | `app/views/project_panel.zig` uses these metrics, theme keys and Zed's fallback guide color; one geometry module serves draw, click, scroll and reveal |
| `.ref/zed/crates/settings_ui/src/settings_ui.rs`, `components/section_items.rs` | Settings window: 226px panel-colored sidebar with search on top and a page tree, content with muted small section headers and faded dividers, rows of title + small muted description + right-aligned control | `app/views/settings_dialog.zig` is a modal with the same structure, backed by a static item table; Zid's settings are a small subset, saved via `config.saveSettings` which keeps explicit `theme` overrides |
| `.ref/zed/crates/ui/src/styles/typography.rs` | `LabelSize::Default` is 14px and `Small` is 12px | Renderer exposes 14px `textUi` and 12px `textSmall` faces |
| `.ref/zed/assets/keymaps/default-linux.json`, `crates/gpui/src/keymap.rs`, `crates/gpui/src/keymap/context.rs` | Bindings are `[{context, bindings}]`; predicates use `>`, `||`, `&&`, `!`, `==`/`!=`; deeper focus-path matches win, later definitions win at equal depth, only available actions dispatch, `null` disables | The upstream file is bundled unmodified and parsed at runtime (`app/keymap.zig`); `app/input/commands.zig` names Zid's actions exactly like Zed's and reports availability per focus, so unimplemented actions fall through like in GPUI. User `keymap.json` uses Zed's schema |
| `.ref/zed/crates/picker`, `file_finder`, `command_palette`, `go_to_line`, `recent_projects`, `tab_switcher` | Modal pickers over a single-line editor with fuzzy matching and highlighted positions; command palette humanizes action names and shows bindings | `app/input/pickers.zig` (sources, filtering, confirm), `app/fuzzy.zig` (DP scorer), `views/picker_view.zig` (drawing). Tab switcher confirms on Ctrl release |
| `.ref/zed/crates/keymap_editor` | A searchable table of action, arguments, keystrokes, context and source | `views/keymap_editor.zig` replaces the editor area; editing bindings from the table is not implemented yet (edit keymap.json) |
| Zed icon themes (`assets/icons/file_icons`, extension icon-theme schema) | Icon lookup: exact file stem, then longest suffix, then the default theme's icon; colored themes keep their own colors | Zed Default stays the default; Catppuccin Latte is bundled; colored SVGs use a separate RGBA atlas |
| `/home/addo/dev/stupid/chatƺpt/src/ui/window.zig` | Transparent borderless SDL window; radius 10 restored, 0 maximized | Same native-window treatment and hit-test behavior |
| `/home/addo/dev/stupid/chatƺpt/src/ui/app.zig` | Breeze caption controls and Adwaita caption controls have distinct spacing/backgrounds | Use the reference sizing, hover treatment and desktop symbolic glyph resolver |
| `/home/addo/dev/stupid/chatƺpt/patch/sdl-gpu-vulkan-transparent.patch` | SDL's transparent-window guard needs an exception for Vulkan | Build pinned SDL from a patched disposable source copy |

The current UI still uses its older gap-buffer Document. The persistent tree and
Source are independently tested and await M2 integration. Zed's complete display
maps, collaboration/history model and B+ tree have not been copied or declared
implemented. Future LSP, terminal, diff, database and notebook work must start with
a fresh source check in the relevant reference crates and a bounded design note.
