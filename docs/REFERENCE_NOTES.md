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
| `.ref/zed/crates/settings_ui/src/settings_ui.rs`, `components/section_items.rs` | Settings window: 226px panel-colored sidebar with search on top and a page tree, content with muted small section headers and faded dividers, rows of title + small muted description + right-aligned control | `app/views/settings_dialog.zig` remains an in-app modal; fifteen categories and 727 catalogue paths (689 explicit defaults, 38 optional) now come from the reference snapshot and `page_data.rs`. `settings_document.zig` preserves unknown values and `config.zig` applies only implemented settings. See SETTINGS_PARITY.md for gaps |
| `.ref/zed/assets/settings/default.json`, `crates/title_bar/src/title_bar.rs`, `crates/workspace/src/status_bar.rs` | Panel defaults right, folder-only indicators, optional status tools, project/branch title triggers | Apply supported shell flags, preserve unsupported values; separate geometry for dock side and hidden status; Git HEAD reader for actual branch labels. Settings remains a modal; title/menu/popover and panel interaction parity is incomplete (SETTINGS_PARITY.md) |
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

### Workspace startup, title bar, status bar and tab bar defaults (2026-11-01)

| Reference source | Observation | Zid decision |
| --- | --- | --- |
| `.ref/zed/crates/workspace` (empty pane) | Opening a folder shows an empty pane; an untitled buffer exists only after `workspace::NewFile` | `main.zig` no longer creates an untitled document; closing the last tab leaves zero documents. `Workspace.currentOrNull` is the guard; focus resolves to `.workspace` when no document exists. |
| `.ref/zed/crates/project_panel/src/project_panel.rs` (`open`, `open_internal`, click handler) | `project_panel::Open` passes `focus_opened_item = !enable_preview_from_project_panel` (false by default); a single click opens without focus and a double-click focuses | `App.activateProject` keeps panel focus; the editor caret is hidden and typing does nothing until the editor is clicked or focused. New files confirmed in the panel open focused, as in Zed's `confirm_edit`. |
| `.ref/zed/crates/title_bar/src/title_bar.rs` (render, `render_worktree_and_branch`, `render_sign_in_button`, `render_user_menu_button`) | `LabelSize::Small` project button; worktree button ("main" + `GitWorktree`), a 25%-alpha "/", branch button (`GitBranch`, muted); right group `pr_1 gap_1` with "Sign In" and a `ChevronDown` user menu | `views/title_bar.zig` builds these segments from `title_bar.show_project_items/show_worktree_name/show_branch_name/show_sign_in/show_user_menu`. Sign In shows a notice (no accounts); the user menu opens Settings; worktree and branch pickers are not implemented. Linked worktree names are not detected. |
| `.ref/zed/crates/zed/src/zed.rs` (status items), `crates/workspace/src/status_bar.rs`, `dock.rs` (`PanelButtons`) | Left: left-dock buttons, search, LSP (`BoltOutlined`), diagnostics (`Check` or `XCircle`/`Warning` counts), activity. Right items render reversed: cursor `row:col`, language, bottom dock (terminal, debugger), right dock (project, git, collab, outline by activation priority). `IconSize::Small` in 22px buttons, `gap_1`, `Base04` padding | `views/status_bar.zig`. "Tab Size" is no longer shown (not a Zed default). AI items are omitted while AI is deferred. Diagnostics counts cover only the active document, not the whole project. Panels Zid lacks show a notice when clicked. |
| `.ref/zed/crates/ui/src/components/tab_bar.rs`, `crates/workspace/src/pane.rs` (`default_render_tab_bar_buttons`, nav buttons, `ShowCloseButton::Hover`) | Start slot: back/forward (`ArrowLeft`/`ArrowRight`); end slot: `Plus`, `Split`, `Maximize`, only while the pane has focus; `Base06` padding, `Base04` gap, 1px border towards the tabs; close button `visible_on_hover`; `tabs.file_icons` false | `views/tabs.zig` implements both slots (nav buttons stay disabled: no history yet; Split/Zoom show notices; + runs `workspace::NewFile`), hover-only close with the dirty dot otherwise, no file icons by default, and content-sized tabs (24px minimum, 250px cap). |
| nanosvg (`src/gfx/c/nanosvgrast.h`, `nsvg__addActive`) | Near-horizontal edges cast an out-of-range `dx/dy` to `int`; Debug UBSan traps while rasterizing Zed's `plus`/`maximize` icons | `font.c` is compiled with `-fno-sanitize=float-cast-overflow`; the vendored header is unchanged. |

### Onboarding page (2026-11-01)

| Reference source | Observation | Zid decision |
| --- | --- | --- |
| `.ref/zed/crates/onboarding/src/onboarding.rs` | `Onboarding` is a pane item ("Onboarding" tab), key context `Onboarding` + `menu`; 780px-max column, `p_12`, `gap_6`; header with `ZedLogo` (40px), `HeadlineSize::Small` title, small italic tagline and a 200px `Filled`/`Medium` "Finish Setup" button showing `onboarding::Finish` (ctrl-enter); `Finish` replaces it with the Welcome page; shown on first launch (`first_open` KVP) | `views/onboarding.zig` is an item that stays in the tab bar until closed and can be active or inactive; any document activation takes focus from it. `zed::OpenOnboarding` reopens it. It is shown once per data directory (`$XDG_DATA_HOME/zid/first_open`) and with `--onboarding`, never automatically in screenshot runs. The title says "Welcome to Zid"; the logo (`assets/icons/zed_logo.svg`, byte-for-byte) and tagline are Zed's, at the user's request. `Finish` swaps the item to the Welcome page in the same tab slot (Zed's `go_to_welcome_page`). Tab focus traversal between controls is not implemented. |
| `.ref/zed/crates/onboarding/src/basics_page.rs` | Theme (Light/Dark/System outlined toggle group, One/Ayu/Gruvbox tiles), Base Keymap (2×4 `ToggleButtonWithIcon`), Agent Setup, Import Settings (VS Code/Cursor), Vim Mode, Trust All Projects, divider, two telemetry switches; writes via `update_settings_file` | Theme, keymap, Vim and trust controls write `theme`, `base_keymap`, `vim_mode` and `session.trust_all_worktrees` through the same validated save/reload path as the Settings dialog. Agent Setup and telemetry are omitted (no AI or telemetry in Zid). Import buttons show a not-implemented notice. Vim mode and project trust are only persisted. Saving re-serializes settings.json, so its comments are dropped (Zed preserves them). |
| `.ref/zed/crates/onboarding/src/theme_preview.rs` | `ThemePreviewTile`: 8px root radius, 2px state border (`border.selected` when selected, `border` on hover, 0.8 opacity otherwise), 2px padding, 1px theme border; sidebar 25% (20% side-by-side) with eight 2px skeleton bars; ten seeded pseudo-code lines from syntax colours; System mode shows light and dark halves | Ported with the same seed (`0xBEEF`) and formulas. Variable colour uses `editor.foreground`. |
| `.ref/zed/crates/ui/src/components/button/toggle_button.rs`, `button_like.rs` (`TintColor::Accent`) | Group labels `LabelSize::Small`, icons `IconSize::XSmall`; the selected segment fills with `info.background` and uses the accent colour | `theme.zig` maps `info.background`, `border.selected`. |
| `assets/themes.zig`, `config.zig` | Zed resolves `"mode": "system"` from the OS appearance; Zid previously always used the `dark` entry and registered no light themes | One Light, Ayu Light and Gruvbox Light are registered. `config.systemAppearance()` asks SDL (`getSystemTheme`; unknown counts as dark). Live updates on an OS theme change are not wired yet. |
| renderer / nanosvg | Zed's logo is 40px (icon cells are 32px); NanoSVG paints `<mask>` shapes (the Emacs icon became a square) | `Renderer.largeIcon` rasterizes up to 64px into four icon-cell tiles; `font.c` blanks `<mask>` elements before parsing (the SVGs stay unmodified). Added 16px headline and 12px italic UI faces. |
| `.ref/zed/crates/workspace/src/welcome.rs` | `WelcomePage` ("Welcome" tab, key context `Welcome`): `max_w_128` column, `p_8`, vertically centred, `gap_6`; 45px logo with default `Headline` (18px) and tagline; "Get Started" (New File, Open Project, Clone Repository, Open Command Palette) and "Configure" (Open Settings, Customize Keymaps, Explore Extensions) sections with uppercase `XSmall` buffer-font headers and a divider; `Medium` rows with icon, label and keybinding; agent card; divider and "Return to Onboarding". A launchpad variant ("Welcome back", recent projects) appears only in an empty pane with no worktree | `views/welcome.zig`, drawn by the shared page item (`zed::ShowWelcome`, `--welcome`). Buttons run Zid's commands by Zed action name; Clone Repository and Explore Extensions say they are not implemented. `workspace::Open` uses the path dialog, which now opens a directory as the project. Omitted: the agent card (AI deferred) and the launchpad (Zid always opens a folder). "Return to Onboarding" swaps the page in place instead of adding a second item. The renderer's extra fixed-size faces (16/18px headline, 12px italic, 10px UI and buffer-font labels) are one table in `gfx/renderer.zig`. |

### Context menus, prompts, path pickers, title-bar menus and sign-in (2026-11-01)

Reference screenshots of the Zed build were taken under Xvfb (`ZED_STATELESS=1`, `ZED_ALLOW_EMULATED_GPU=1`) with `xdotool` input.

| Reference source | Observation | Zid decision |
| --- | --- | --- |
| `crates/ui/src/components/context_menu.rs`, `list_separator.rs`, `traits/styled_ext.rs` | `elevation_2` (elevated surface, 8px radius, `border.variant`, soft shadows), `py_1`, min width 200, 23px inset rows with right-aligned muted keybindings, disabled `text.disabled`, separators 1px with 6px margins; anchored and snapped to the window; key context `menu` | `views/context_menu.zig`. Hints resolve against the deploying view's focus. Submenus and documentation asides are not implemented (no Zid menu needs them yet). |
| `crates/editor/src/mouse_context_menu.rs`, `crates/workspace/src/pane.rs`, `crates/project_panel/src/project_panel.rs`, `crates/zed/src/zed/app_menus.rs`, `crates/title_bar/src/application_menu.rs`, `title_bar.rs` user menu | Exact entries per menu; Linux application menu flattens one submenu level and drops system menus; the hamburger expands into a menu bar and hovering a name switches menus | `menus.zig` transcribes them. Implemented actions: editor Cut/Copy/Paste/Go to Definition, path copy, reveal in file manager and open with system (SDL `OpenURL`), tab Close/Others/Left/Right/Clean/All and Reveal In Project Panel, project-panel New File/Folder, Rename (in-place editor with the stem selected), Trash (freedesktop.org Trash spec), Delete, Cut/Copy/Paste/Duplicate (files; folder copies are refused), Add to .gitignore / .git/info/exclude, every command Zid already had. Others report "not implemented yet". Git status-dependent entries (Restore File, View History) are omitted. |
| `crates/ui_prompt/src/ui_prompt.rs`, `pane.rs`, `workspace.rs`, `project_panel.rs` `build_removal_prompt` | 20% black wash, 320px `elevation_3` box, `p_4`/`gap_4`, Markdown message at `ui_font_size` (16px), small muted detail, stacked `Outlined` buttons with the active one `Tinted(Accent)`; key context `Prompt`; Zed's exact messages and answers | `views/prompt.zig` replaces the old S/D/Esc dialog. `workspace_actions.zig` implements close item, close several (Save all / Discard all), quit, and trash/delete flows. Inline code in messages renders as plain text. |
| `use_system_path_prompts` (default true) | Linux uses the XDG file-chooser portal | `workspace_actions.zig` uses SDL3's open-file, open-folder and save dialogs (portal-backed), with the in-window path dialog when the setting is false. The portal's own overwrite confirmation replaces the old SDL message box. |
| `crates/client/src/client.rs` `authenticate_with_browser`, `crates/rpc/src/auth.rs`, `crates/cloud_api_client` | RSA-2048 key, localhost callback on an ephemeral port, `zed.dev/native_app_signin`, RSA-OAEP-SHA256 token (PKCS#1 v1.5 fallback), `cloud.zed.dev/client/users/me` with `Authorization: <id> <token>`, keychain storage | `core/rsa.zig` (pure Zig on `std.crypto.ff`), `zed_auth.zig` (protocol, tested end to end against a local fake browser), `account.zig` (worker thread, UI state). Credentials live in `$XDG_DATA_HOME/zid/zed_credentials` (0600) instead of the keychain. The avatar is drawn as an initial (no image decoder yet). Organization headers and the AI "Panel Layout" submenu are omitted. |
| `crates/ui/src/components/tooltip.rs`, GPUI `DEFAULT_TOOLTIP_SHOW_DELAY` | 500ms delay, `pl_2 pt_2p5` from the pointer, `elevation_2`, `py_1 px_2`, title + keybinding, muted meta | `views/tooltip.zig`; registered on title-bar items, status-bar buttons, tab-bar buttons and tabs (full path with `~`). |
| `crates/language_tools/src/lsp_button.rs` | Status-bar LSP menu: servers with status, Restart/Stop All Servers | `menus.lsp` lists ZLS with its state; restart and stop act on Zid's ZLS controller. Per-server submenus and logs are not implemented. |
| `config.zig` system appearance | Config must stay SDL-free for `test-ui` | The app sets `config.system_appearance` from SDL at startup and on `system_theme_changed`, then reloads. |

### Pickers, hover selection, image decoding and the image viewer (2026-11-01)

| Reference source | Observation | Zid decision |
| --- | --- | --- |
| `crates/picker`, `crates/command_palette` (`initial_width(rems(38))`, `render_footer`), `crates/file_finder`, screenshots | One highlight that follows the pointer (hover selects the row); wheel scrolls without moving it; keybindings are plain muted text; palette 608px with 33px rows and "Change/Add Keybinding… / Run" footer; file finder lists history until a query is typed, shows `worktree/dir/` muted with a history icon, a preview pane, and "Preview / Actions…" footer | `views/picker_view.zig` and `modals.zig`. "Change/Add Keybinding…" opens the keymap editor filtered to the action. The preview is read-only and highlights with Zid's lexers. The actions menu and preview layouts (below/hidden) are not implemented. |
| `crates/keymap_editor` (`selected_index: None`), `ui::KeyBinding` | No initial row selection; keystrokes as text | `keymap_editor.zig` `has_selection`; chips removed. |
| `crates/image_viewer` | Fit to view (≤100%), 32px `panel.background` checkerboard, `border` frame, ctrl+wheel zoom about the pointer (0.1–20), wheel pans, `ImageInfo` "W×H • size • FORMAT" | `src/image/` decoders (pure Zig, tested against Pillow references in `src/image/testdata`, regenerated by `tools/gen_image_fixtures.py`) and `views/image_view.zig` (worker-thread decode, GPU texture via `Renderer.createImage`/`drawImage`). WebP, TIFF, ICO and AVIF are not decoded; GIF shows its first frame. |
| `crates/title_bar` user `Avatar` | GitHub avatar | Downloaded at 64px, decoded, circle-masked, drawn at 16px. |

### tree-sitter syntax highlighting (2026-11-02)

| Reference source | Observation | Zid decision |
| --- | --- | --- |
| `crates/grammars/` | Grammar-as-data: a compiled `TSLanguage` per language plus bundled query files, registered in one table | `build.zig` `treeSitterModule` compiles tree-sitter 0.27.1 plus each grammar's `parser.c`/`scanner.c` from URL/hash-pinned Zig packages and embeds each grammar's own `queries/highlights.scm` into generated `ts_queries.zig` (Zed's `.scm` files are GPL-3.0 and are not vendored). `src/syntax/ts_highlight.zig` `grammarOf` is the registry; languages without a grammar (plain, sql) stay on the hand lexers. |
| `crates/language/src/highlight_map.rs`, `syntax_map.rs` | Highlight capture names map to theme style keys; a captured span's color comes from the longest matching prefix | `kindOf` maps upstream capture names onto the existing `token.Kind` enum by longest prefix match (e.g. `keyword.directive.define` → `.keyword`), so themes keep the `syntax` schema unchanged. |
| `crates/language/src/buffer.rs` injection layers | Markdown `(inline)` blocks are parsed with the inline grammar; fenced code blocks get the info-string's language via `injections.scm` `@injection.content` / `@injection.language` captures | `Layer.inject` runs the same query shape over the block tree, parses each region with a sub-parser, and merges sub-captures byte-shifted into the main capture list. Unknown info-string languages are skipped, matching Zed's fallback to no injected highlighting. |
| `crates/editor` render path | Per-visible-line span queries against the parsed tree, reparsed on edits | `App.treeSitterLayer` re-parses the whole buffer when `doc.revision` changes; `editor.zig` asks `Layer.spansForRange` per row and falls back to `lexLine` when `grammarOf` returns null or the buffer is `doc.large`. |

Note: query cursors iterate lazily — an injection pass must gather all matches before parsing any region, or parsing mid-iteration invalidates the walk and later patterns silently never match.
