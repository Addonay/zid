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

The UI Document now uses the persistent piece tree for memory-backed files and
retains root pairs for undo. Like the explicit transaction finalization in
`crates/text/src/text.rs`, navigation and undo/redo end a typing group; a saved
revision also forms a boundary. Zid currently groups by word rather than time
and retains at most 1000 undo entries. This limits retained versions, not the
append-only text store; add-buffer compaction remains unfinished.
Zed's complete display
maps, collaboration/history model and B+ tree have not been copied or declared
implemented. Future LSP, terminal, diff, database and notebook work must start with
a fresh source check in the relevant reference crates and a bounded design note.

### Buffer search integration (inspected 2026-11-01)

`crates/search/src/buffer_search.rs` keeps the active query, options and current
match distinct from editor text. `select_match` moves through results and honors
the wrap setting; `replace_next` replaces the active match before advancing.
The bundled Linux keymap uses `buffer_search::Deploy` (Ctrl+F),
`buffer_search::DeployReplace` (Ctrl+H), `search::SelectNextMatch` (Enter/F3),
`search::SelectPreviousMatch` (Shift+Enter/Shift+F3), and
`buffer_search::Dismiss` (Escape in the search context).

Zid adopts the search action names and separate input focus. Closing the bar retains
the query and restores editor focus. Search is exact-case literal UTF-8; regex, case
toggles and replacement are not implemented. Counts scan bounded batches without a
match array, capped at 9,999. Synchronous search is limited to memory-backed
documents of at most 32 MiB; file-backed large mode reports that search is unavailable.
Replacement remains future work and must validate the active range and revision.

The reference `crates/editor/src/scroll.rs` derives a display position from a scroll
anchor and snapshot. Zid's provisional large-file byte viewer keeps its byte offset
separate from the memory-backed editor's line scroll; it does not implement Zed's
scroll anchor or display map.

Large-file navigation uses the reference distinction between logical lines and display
positions (see `crates/editor/src/scroll.rs`); Zid resolves logical LF boundaries on
the worker without implementing Zed display maps or column-preserving cursor motion.

The default Linux keymap in `.ref/zed/assets/keymaps/default-linux.json` maps
Shift+arrows, Shift+Home/End, Ctrl+Shift+Home/End and Select All to editor
selection actions. Zid uses those actions for large files with byte endpoints;
line boundaries are resolved asynchronously and do not implement Zed smart Home.

Zed's `crates/editor/src/element.rs` builds selection background segments per
visible display row. The large-file viewer similarly paints per-row backgrounds
behind text, but maps byte selections through its bounded decoder instead of
implementing Zed's display map. Partial encoded characters select the complete
displayed replacement or character; a selected line ending gets a small marker.

The large-file viewer keeps the selection head separate from its visible byte
window, following the distinction between Zed's selection state and scroll
anchor in `crates/editor/src/scroll.rs` and row selection painting in
`crates/editor/src/element.rs`. Its asynchronous navigation serializes relative
intentions; it remains byte-based and does not provide Zed's display mapping.

### Settings UI (2026-11-01)

Zed's `crates/settings_ui/src/settings_ui.rs` sets a 226 px navigation rail,
10 px rail padding and 32 px horizontal item padding. Its setting rows pair a
label and muted small description with a control, and save settings as fields
change. Zid uses those dimensions and immediate apply for its supported fields.
Zed uses a separate settings window with independently focusable search,
navigation and controls; Zid currently presents an in-app modal and supports
search and control focus. Zid wraps descriptions using the same measured rows for drawing, scrolling and hit testing, and stacks controls when space is tight. Zed shows an undo control for settings that differ from their default (settings_ui.rs, render setting row); Zid exposes Reset and Delete for its supported values. Resetting line height also reduces font size if necessary to keep the configuration valid. Zed's scope/file selector, full navigation keyboard behavior and complete setting catalog are not yet reproduced. No Zed
reference screenshot was available for a pixel comparison in this pass.

### SQLite viewer (2026-11-01)

The viewer follows Zed's workspace panel approach in `crates/workspace/src/dock.rs`:
feature state belongs to the workspace and is presented inside its shell. Zid's
initial viewer is a dismissible overlay, not a full Zed dock implementation.
SQLite work is submitted as a cancellable Io task with a bounded result; the UI
owns and joins that task before destroying its inputs or result.

### LSP line positions (2026-11-01)

Zed's `crates/text/src/text.rs` normalizes both CRLF and lone CR to LF in
buffer text. Zid's LSP position conversion accepts unnormalized text and treats
those same sequences as logical line breaks, while retaining byte offsets into
the original text. An offset inside a CRLF pair is rejected.

### LSP transport and synchronization (2026-11-01)

Zed separates its stdout handler from message dispatch and bounds the incoming
queue (`crates/lsp/src/input_handler.rs`). Zid now has separate reader and
writer tasks with bounded raw queues; dispatch and response correlation are still
outstanding. Zed's `project/src/lsp_store.rs` interprets numeric synchronization
capabilities as change settings and examines save options separately. Zid's
static capability parser and document synchronization follow that distinction;
dynamic registrations remain unfinished.

Zed's editor maps diagnostics into styled ranges (`crates/editor/src/display_map.rs`)
and draws their underline in `element.rs`. Zid's first integration keeps
diagnostic snapshots per document revision and marks the starting line in the
gutter; it does not yet implement Zed's range underline or diagnostic popovers.
Unversioned ZLS diagnostics are explicitly best effort and marked in the status bar.

Zed's Linux keymap binds `ctrl-k ctrl-i` to `editor::Hover`. Zid uses the same
action and binding for a cursor-anchored popup. Its initial popup displays plain
text rather than Zed's rendered Markdown and does not implement mouse hover.

### Fold map (2026-11-01)

Zed's `crates/editor/src/display_map/fold_map.rs` stores fold endpoints as
buffer anchors and uses a separate transform tree to map input to displayed
text. Zid's initial fold map follows that split, including overlap and optional
adjacency merging. It currently rebuilds the tree and does not emit Zed's
incremental invalidation edits, implement unfolding, or supply the later display
layers' point, chunk and row APIs. The UI still uses the existing editor path.

### Editor chrome parity checklist items 1-6 (2026-11-01)

| Reference source | Observation | Zid decision |
| --- | --- | --- |
| `.ref/zed/crates/theme/src/buffer_line_height.rs` | `Comfortable` is `1.618` x font size (`Standard` 1.3); the default is Comfortable | `config.Settings.line_height` defaults to 24, the integer nearest 1.618 x 15px. It is still a fixed pixel value, not font-relative, and it stays the explicit override. |
| `.ref/zed/crates/editor/src/element.rs` (`layout_indent_guides`, `paint_indent_guides`) | One guide per indent level from the text origin; `Fixed` coloring; line width 1 and active width 1 (`assets/settings/default.json`); active guide chosen from the cursor block | `views/editor.zig:drawIndentGuides` draws 1px rects per level on visible non-blank rows, highlighting the guide one level left of the cursor's indent. Not implemented: continuation across blank lines, folds, indent-aware coloring, and the large read-only viewer. |
| `.ref/zed/crates/editor/src/indent_guides.rs` | Active guides come from the enclosing indent range, not a single row | Approximated per visible row; a guide ends where its block's rows stop being indented. |
| `.ref/zed/crates/theme/src/default_colors.rs` (`ThemeColors::dark/light`), `crates/theme_settings/src/theme_settings.rs` (`refine_theme`) | `editor_indent_guide` is `neutral().dark_alpha().step_4()` (light: `light_alpha().step_5()`); `editor_indent_guide_active` is step 6; the checklist's `panel.indent_guide` references (`default_colors.rs:99-101`) are panel keys, not editor keys | `theme.zig` reads `editor.indent_guide` and `editor.indent_guide_active` with those Sand-scale fallbacks by `appearance`. The bundled One Dark JSON has no editor indent keys, so One Dark uses `#fefef31b` and `#fffaed2d`. |
| `.ref/zed/crates/theme/src/default_colors.rs` (`editor_active_line_number`), `crates/editor/src/element.rs` (`LineNumberSegment` `Active`) | The cursor row's number uses `editor.active_line_number`; the checklist cited `element.rs:136-137`, which is the same mapping | `views/editor.zig` uses `theme.active_line_number` for the cursor row's gutter number (One Dark JSON: `#d0d4da`). |
| `.ref/zed/crates/ui/src/components/tab.rs` (`container_height`, `content_height`, `Tab::render`), `crates/ui/src/styles/spacing.rs` | Container is `DynamicSpacing::Base32` (32px at the Default density), with a 1px bottom border and `px` 8 / `gap` 8; the content box is 31px; the inactive tab has `border_b`, the active tab has no bottom border | `layout.zig` tab bar is 32px. `views/tabs.zig` centres icon, label and close glyphs in 31px, uses 8px padding and gap, keeps the bottom border on inactive tabs, and lets the active tab cover it. The checklist's "35 to 32" was right. |
| `.ref/zed/crates/workspace/src/pane.rs` (`render_tab_bar_drop_target`) | Tab bar drop targets use the same container height | Covered by the same 32px bar; drag-and-drop is still unimplemented. |
| `.ref/zed/crates/theme/src/default_colors.rs` (`tab_inactive_background`), `assets/themes/one/one.json` (`tab.inactive_background`) | Inactive tabs use `tab.inactive_background`, falling back to `neutral().light/dark().step_2()` | `theme.zig` reads `tab.inactive_background` (fallback `#f9f9f8ff` light / `#191918ff` dark); inactive tabs fill it. |
