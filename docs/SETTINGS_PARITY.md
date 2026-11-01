# Settings and shell parity (2026-11-01)

## Implemented in this pass

- Byte-exact bundle of Zed's `assets/settings/default.json`; no Zed runtime config reads.
- Read-only-source catalogue generator for 689 explicit default paths and 38 optional
  unset/inherited paths (727 total), using directly declared settings UI metadata from `crates/settings_ui/src/page_data.rs`.
- Fifteen settings categories, search by title/description/JSON path, keyboard focus,
  scrolling navigation, reset, switches for booleans, existing typed number/theme/icon
  controls, and inline JSON-value editing for remaining types. Ctrl+A/C/X/V work in
  JSON-value fields. Very large values (>4 KiB) require settings.json.
- Supplied JSON/SVG assets are consumed unchanged. UI icons use Zed's original
  `icons/<snake_case_name>.svg` paths; file icons use Zed's association tables and
  whole-name / suffix / first-stem resolution, including Dockerfile.prod and Podfile.lock.
- Keymap loading follows Zed: platform default, selected base, Vim/Helix bindings,
  specific overrides, then user bindings. The supplied initial keymap/settings
  templates seed missing files when opened. Loading Vim bindings does not implement
  missing Vim actions.
- Zed JSON names (`buffer_font_size`, `buffer_line_height`, `theme`, `icon_theme`,
  nested `project_panel`, `title_bar`, `status_bar`). Legacy Zid scalar keys still load.
- Unknown keys and unsupported values survive saves. Unchanged settings aren't
  overwritten; editing tab size, for example, keeps the theme's system/light/dark mode.
- JSONC input, validation of implemented values before UI writes, atomic replacement,
  file permission preservation, and following existing settings-file symlinks.
  UI writes normalize JSON and do not preserve comments/whitespace.
- Project panel defaults to the right, 240px wide, with folder-only indicators,
  optional file icons, 20px indentation, 24px comfortable / 20px standard rows.
- Panel dock side, startup visibility, icons, folder indicator, indentation, spacing,
  scrollbar visibility, indent guides, auto folding, and directory/file sort mode apply.
- Compact folders use `a/b/c` labels. Disabling auto-fold actually rebuilds the tree.
- Panel width can be dragged and saved. Switching documents reveals ancestor directories
  and scrolls the corresponding file into view when auto-reveal is enabled.
- Title bar has an application-command entry, recent-project trigger, and real branch
  label. Git HEAD metadata is read without launching subprocesses, including worktrees
  and detached HEAD. Existing native caption controls are retained.
- Status-bar visibility and language/cursor/line-ending/encoding controls apply. UTF-8
  and line endings are hidden by default, like the reference. The project toggle follows
  the dock side and the project-panel button setting.

## Explicit remaining gaps — not exact Zed parity

- Zed settings is a separate native window. Zid still uses an in-app modal.
- Dynamic settings subpages, per-language/project/profile scopes, organization overrides,
  enum-specific dropdowns for every field, rich descriptions, and complete schema validation
  are not ported. Fallback category/label metadata is heuristic, not guaranteed identical.
- The supplied default JSON is the runtime defaults layer and is fully represented
  as value paths. Optional UI paths absent from that file appear unset/inherited;
  defaults synthesized by Rust types or extensions are not inferred automatically.
- Unsupported settings are stored only: terminals, collaboration, AI, debugger, etc. do not
  become implemented because their settings are visible. Most editor settings beyond
  font size/line height, tab size and cursor blinking remain inactive.
- Font-family and UI font-size settings are retained but not applied. System appearance
  following and arbitrary external theme/icon-theme installation remain unavailable.
- Project panel: multi-worktree roots, empty directories, filesystem watching, contextual
  new/rename/delete/duplicate/copy operations, multi-selection, drag-and-drop file moves,
  preview/pinned tabs, sticky ancestors, git/diagnostic decoration and sorting variants
  beyond `sort_mode` still need ports. Scanning remains synchronous and bounded by the
  existing workspace scanner (4,000 files / 12 levels).
- Title bar: command palette substitutes for Zed's application menu; the recent-project
  trigger opens Zid's existing picker, not Zed's popover. Branch switching, account menus,
  collaboration controls, and exact platform spacing are incomplete. The existing Zid
  database shortcut is retained, so the title bar is not visually identical.
- Status bar: dedicated selectors/popovers, diagnostics aggregation, bottom/right dock
  toolbar groups, and per-tool keyboard navigation are incomplete. Cursor columns still
  use byte positions rather than grapheme/display columns. Large-file and font-atlas
  warnings remain deliberate Zid additions.

Passing tests establish these bounded behaviors, not complete editor or pixel parity.
