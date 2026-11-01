# Zid vs Zed UI gap list

Date: 2026-11-01. Scope: Zid's shell and UI surfaces (`src/app/`) against the Zed
reference checkout (`.ref/zed/`, read-only). Language servers, git, database, terminal
and AI features are out of scope except where they touch chrome.

## Method and limits

- Static reading only. The app was not run and no screenshots were compared. Geometry
  comes from source constants. `~` marks an approximate line number.
- Zed values come from `crates/**` and from `assets/settings/default.json` (defaults)
  and `assets/themes/one/one.json` (One Dark). Zid values come from `src/app/` and
  `src/app/config.zig`.
- Keymap coverage is a name match: 569 unique action names in
  `.ref/zed/assets/keymaps/default-linux.json` against the `Command` enum in
  `src/app/input/commands.zig`. 113 names match. This says nothing about behaviour.
- Zed's `Label` default is `TextSize::Default` = 14px (`ui/src/styles/typography.rs:99-100,139`).
  Zid's 14px UI text (`src/gfx/renderer.zig:16`) matches it, so text size is not a gap.

## Priority legend

- **P0**: visible every frame or on every open file, with a visible mismatch against
  Zed defaults.
- **P1**: a common workflow is missing or behaves differently from Zed.
- **P2**: rare workflow, later milestone, or a decision to revisit.

**intentional** marks divergences that AGENTS.md or the product choices require:
native caption icons and rounded corners from `chatƺpt`, the keymap editor's "not in
Zid" tag, the database title-bar toggle, and path-based open and save dialogs.

---

## Summary: top 10 gaps

1. Editor indent guides are not drawn (P0). Zed enables them by default.
2. The editor line pitch is 23px (`config.zig:6`). Zed's default "comfortable" height is
   1.618 x 15px, about 24px (P0).
3. The editor scrollbar is always drawn as a 5px bar when the file overflows (P0).
   Zed's default is `auto` with a 15px track.
4. The mouse cursor never changes shape (P0). `src/` has no cursor API call.
5. The tab bar is 35px and inactive tabs use the bar colour (P0). Zed uses 32px and
   `tab.inactive_background`.
6. Search matches are counted but never painted in the editor (P1).
7. Diagnostics show only a gutter bar. Zed underlines the range (P1).
8. Notices last 5 seconds in the status bar. Zed uses bottom-centre toasts with a 10s
   timeout, hover pause and middle-click dismiss (P1).
9. There are no context menus, and right click is ignored everywhere (P1).
10. The status bar shows UTF-8, LF and "Spaces: N" and the cursor position is not
    clickable. Zed's defaults show language and cursor position, and that button opens
    Go to Line (P1).

The top-25 checklist at the end gives one focused task per item.

---

## 1. Theme keys (cross-cutting)

Zed:
- `one.json` defines keys Zid never reads: `editor.active_line_number`,
  `tab.inactive_background`, `search.match_background` and
  `search.active_match_background` (`one.json:47-48`), `scrollbar.thumb.hover_background`,
  `title_bar.inactive_background`, `panel.focused_border`.
- `one.json` does **not** define `editor.indent_guide`, `editor.indent_guide_active` or
  `panel.indent_guide`. Fallbacks: panel guides from the neutral alpha scale
  (`crates/theme/src/default_colors.rs:99-101`); editor guides from the built-in
  fallback theme (`fallback_themes.rs:178-179`).
- Current line number uses `editor_active_line_number`; others `editor_line_number`
  (`crates/editor/src/element.rs:136-137`).

Zid:
- `src/app/theme.zig:66-70` maps 27 keys. It includes `panel.indent_guide` and no
  `editor.indent_guide*`, `editor.active_line_number`, `tab.inactive_background`,
  `search.*`, or the scrollbar and title-bar variants.
- Missing keys fall back to literals (`theme.zig:9-46`), e.g. `indent_guide =
  .{ 59, 62, 69, 255 }` (`theme.zig:43`), which is not Zed's derived value.
- `theme.zig:75-80` reads only `players[0].selection`, not the cursor colour.

Gap:
- **P0**: map `editor.indent_guide`, `editor.indent_guide_active`,
  `editor.active_line_number`, `tab.inactive_background`; derive missing guide colours
  the way Zed does instead of literals.
- **P1**: map `search.match_background` and `search.active_match_background` (item 10).
- **P2**: `scrollbar.thumb.hover_background`, `title_bar.inactive_background`,
  `panel.focused_border`, and `players[0].cursor` for the caret (Zid draws the caret in
  `text.accent`, `views/editor.zig:339`).

---

## 2. Title bar

Zed:
- Height `max(1.75 * rem, 34px)` on non-Windows (`ui/src/utils/constants.rs:17-19`).
- Segments (`crates/title_bar/src/title_bar.rs:298-325`): application menu (hidden by
  default, `default.json:638` `show_menus: false`), project host, project name, and a
  worktree and branch segment (`title_bar.rs:915`; `show_branch_name` defaults true).
- The project name is a button that opens a recent-projects popover
  (`title_bar.rs:783`, `:864`).
- Right side: call, sign-in and user menu (`title_bar.rs:371-395`). Collaboration, out of
  scope.
- Background `title_bar_color` (`title_bar.rs:411-420`). The inactive-window variant is
  not verified in this pass.

Zid:
- `src/app/views/title_bar.zig:29-61`: 34px bar. Left: `panel_left` icon at x=12
  (`title_bar.zig:33`), which toggles the left dock for clicks with `mx < 36`
  (`app.zig`, click path around line 918). Root basename text at x=44
  (`title_bar.zig:36`, clipped). Right: database toggle (`title_bar.zig:38`, Zid-specific),
  then the three window controls (`title_bar.zig:8-21`, `:45-59`).
- The project name is painted text only and is not clickable.
- Drag region: `app.zig:186-206` (`hitTest`). No double-click maximize was found in
  `input/events.zig` or `hitTest`.
- Background is `t.title_bar` regardless of focus (`title_bar.zig:32`).

Gap:
- Height matches. No change.
- **P1**: make the project name open the recent-projects picker (`projects::OpenRecent`
  is already in `commands.zig`).
- **P2**: branch and worktree segment (depends on git milestone M6).
- **P2**: inactive-window title colour; double-click maximize (check SDL behaviour
  first).
- **intentional**: window controls and rounded corners (AGENTS.md).

---

## 3. Workspace layout: docks, panes, splits

Zed:
- Dock resize handle 6px (`crates/workspace/src/dock.rs:25`, centred on the edge,
  `dock.rs:1313-1334`). Pane group handle hitbox 4px (`pane_group.rs:22`).
- Splits and pane moves: `pane::SplitRight/Left/Up/Down`, `pane::SwapItem*`,
  `workspace::ActivatePane*` (`default-linux.json`).
- Docks: left, right, bottom, with `ToggleRightDock`, `ToggleBottomDock`,
  `ToggleAllDocks`, and dock sizing commands.
- Project panel default width 240 (`default.json:888`), dock `"right"`
  (`default.json:890`).
- Tab bar nav-history buttons on by default (`default.json:1477-1490` region).

Zid:
- `src/app/layout.zig:242-249`: title 34px, body (panel and pane), status 26px, tabs 35px,
  editor flex.
- Panel width from `settings.panel_width` (240, `config.zig:7`), clamped to 45% of the
  window (`app.zig` draw, around line 972). No drag handle.
- One pane. No `pane::Split*` or `workspace::ActivatePane*` in `commands.zig`.
- Only a left dock (`workspace::ToggleLeftDock`).
- Tab overflow scrolls by `tabs_first` (`views/tabs.zig:116-123`) with no buttons or
  wheel handling.

Gap:
- **P1**: panel edge drag handle (6px), clamped, saved to `panel_width`.
- **P1**: split panes. Large: needs a pane tree in `Layout` and per-pane tab lists.
- **P2**: right and bottom docks (bottom depends on terminal M5).
- **P2**: default dock side. Zed's reference default is right. Zid's left dock is a
  product choice; record it in `docs/REFERENCE_NOTES.md` rather than changing silently.
- **P2**: pinned and preview tabs, `max_tabs`, back and forward (`pane::GoBack/GoForward`),
  `pane::ReopenClosedItem`.

---

## 4. Tab bar

Zed:
- Container height `Base32` = 32px at default density (`ui/src/components/tab.rs:79-85`).
  Content height 31px. Density factors: compact 0.75, default 1.0, comfortable 1.25
  (`crates/theme/src/ui_density.rs:39-41`).
- Tab width `min_w_6()` (24px) and `flex_grow_1()` (`crates/workspace/src/pane.rs:3738-3740`,
  `:3782-3784`). Tabs fill the bar; no content-based clamp.
- Start slot 12px, end slot 14px (`tab.rs:6-7`).
- Selected `tab.active_background`; unselected `tab.inactive_background`; bar
  `tab_bar.background` (`tab.rs` render, colour selection).
- Defaults (`default.json:1497-1531`): `close_position: "right"` (1500),
  `file_icons: false` (1502), `show_close_button: "hover"` (1511),
  `activate_on_close: "history"` (1520), `show_diagnostics: "off"` (1531). `max_tabs`
  null (`default.json:1473`).
- Overflow handled by `tab_bar_scroll_handle` (`pane.rs:3655-3658`).

Zid:
- Bar 35px (`layout.zig:244`).
- `views/tabs.zig:108-158` draws tabs. Width is clamped to 130-250 from label width + 72
  (`tabs.zig:159-161`). Tabs do not grow to fill.
- Active tab: `t.active_tab` fill and a 1px `t.accent` top line (`tabs.zig:131-134`).
  Inactive tabs have no fill and show `t.tab_bar` (`tabs.zig:112`).
- Icons always drawn (`tabs.zig:138`).
- End slot 28px (`tabs.zig:93-98`, `views/geometry.zig:187-189`). Dirty documents get a
  10px dot at `x + w - 22` (`tabs.zig:141`); otherwise a 14px close icon, always visible.
- Hit test `tabs.zig:103-106` (`closeHit`) and the click path (around line 893-899).
- Keymap editor is drawn as a tab with a close icon (`tabs.zig:145-157`).

Gap:
- **P0**: bar height 35 to 32 (`layout.zig:244`, `tabs.zig:112-115`), keeping label
  baselines consistent.
- **P0**: inactive tabs use `tab.inactive_background` (item 1).
- **P1**: close button on hover; dirty dot in the same slot (Zid shows both always).
- **P1**: flex widths with a 24px minimum instead of the 130-250 clamp.
- **P1**: scroll buttons or wheel scrolling for overflow.
- **P2**: tab file icons off by default (`default.json:1502`); tab diagnostics (off by
  default); tab context menu (depends on item 16); `activate_on_close` modes.

---

## 5. Project panel

Zed:
- Rows are `ListItem`s (`crates/ui/src/components/list/list_item.rs`). Comfortable maps to
  `ListItemSpacing::Dense` (`project_panel.rs:6631-6632`), which has no vertical padding
  (`list_item.rs:366`). Height is content-derived; `list_item.rs:304` applies a height
  only when set.
- Padding `Base04` (`list_item.rs:309`) and `Base06` (`list_item.rs:364`).
- Indent 20px (`default.json:907`; `project_panel.rs:6630`).
- Colours (`project_panel.rs:659-678`): default `panel_background`, hover `element_hover`,
  marked `element_selected`, focused `panel_focused_border`, drop target
  `drop_target_background`; sticky rows use `panel_overlay_*`.
- Sticky scroll on (`default.json:950`), tracked by `sticky_items_count`
  (`project_panel.rs:165`).
- Scrollbar `show: null` inherits the editor default `auto` (`default.json:934`, `:668`).
- Right-click menu via `deploy_context_menu` (`project_panel.rs:1128`, `:6832`) on
  `ContextMenu` (min width 200px, `ui/src/components/context_menu.rs:22`).
- File operations: new file, new directory, rename (`h_6` appears only on the rename
  editor, `project_panel.rs:6785`), delete, trash, copy, cut, paste, copy path.
- File icons, git status, diagnostics on by default (`default.json:894`, `:905`, `:948`).
  `auto_fold_dirs: true` (`default.json:916`).

Zid:
- `src/app/views/project_panel.zig:10-18`: row 24px, top pad 4, pad_x 6, indent 20, icon
  16, gap 4, guide offset 15, disclosure 14. Geometry shared with hit testing through
  `views/geometry.zig`.
- Row pitch is fixed at 24px, a Zid choice (Zed's height is content-derived).
- Selection: `element_selected` for the selected row or active document; hover
  `element_hover`; focused row has a 1px `border_focused` outline
  (`project_panel.zig:92-99`, `:129-134`).
- Indent guides per depth in `panel.indent_guide` (`project_panel.zig:101-106`).
- Disclosure chevrons `ui:chevron_down` / `ui:chevron_right` (`project_panel.zig:113-114`).
- Scrollbar: 6px rounded thumb, 25px minimum, overflow only, not draggable
  (`project_panel.zig:136-146`).
- Input: left click selects and activates (`activateProject`, click path around line
  896-902). Keyboard: `project_panel::Collapse*`, `Expand*`, `Open` only.
- `config.zig:10` `auto_fold_dirs: true` and `config.zig:7` width 240 match Zed.

Gap:
- **P1**: right-click menu (depends on item 16).
- **P1**: new file, new directory, rename, delete, copy path (none in `commands.zig`).
- **P1**: scrollbar behaviour and drag matching the editor's `auto` scrollbar.
- **P2**: sticky scroll headers; git and diagnostic row colours (M6 and LSP); drag and
  drop; dock side (section 3).
- **check**: 24px fixed pitch vs content-derived height. Keep unless a visual comparison
  shows a difference.
- **doc fix**: `docs/REFERENCE_NOTES.md:17` says rows are `h_6`. In the reference, `h_6`
  appears only on the rename editor (`project_panel.rs:6785-6788`). Fix the note and the
  comment at `project_panel.zig:1-3`.

---

## 6. Editor element

### 6.1 Gutter and line numbers

Zed:
- Line numbers on (`default.json:755`); `min_line_number_digits: 4` (`default.json:763`).
- Gutter width (`crates/editor/src/editor.rs:12529-12585`): left padding `ch * 2` with
  git gutter, `ch * 3` when runnables, breakpoints or bookmarks show, else `ch`. Right
  padding `ch * 4` with folds, `ch * 3` for multibuffer, else `ch`.
- Numbers right-aligned to `gutter.width - right_padding` (`element.rs:2927-2931`).
- Gutter click selects the line in singletons (`element.rs:5342-5396`). Gutter cursor
  arrow (`element.rs:5343-5344`).
- Fold markers on (`default.json:757`).

Zid:
- Numbers right-aligned at `e.x + 48` (`views/editor.zig:44`); text starts at `e.x + 64`
  (`editor.zig:199`). Gutter width is fixed.
- Current row `t.text`, others `t.line_number` (`editor.zig:190`).
- Diagnostics: 3px bar at `e.x + 3` (`editor.zig:191-198`).
- No fold, git, breakpoint or bookmark column. Line-number click does nothing.

Gap:
- **P0**: active line number colour (item 1).
- **P1**: gutter width from `ch` metrics with a 4-digit minimum; line-number click selects
  the line.
- **P2**: fold column (later milestone); git gutter (M6); breakpoints (debugger, out of
  scope).

### 6.2 Current-line highlight

- Zed: `current_line_highlight: "all"` (`default.json:359`), `editor_active_line_background`
  (`element.rs:5139`).
- Zid: `t.active_line` across the full editor width from `e.x`, including the gutter
  (`editor.zig:187`).
- Gap: matches in intent. **P2**: check the highlight width against Zed before changing.

### 6.3 Caret and blink

- Zed: `cursor_shape: "bar"` (`default.json:307`), 2px bar (`element.rs:11081-11084`);
  block, hollow, underline also supported (`element.rs:11085-11092`). `cursor_blink: true`
  (`default.json:295`). 500ms interval, paused on keystroke (`blink_manager.rs:46-53`,
  `:65-80`).
- Zid: 2px accent bar (`views/editor.zig:327-340`); hidden when unfocused, panel-focused,
  search-focused or in a dialog (`editor.zig:329`). 500ms toggle in `app.zig:369-425`;
  keystrokes reset it (`input/events.zig:30-31`, `:70-71`). Setting `config.zig:9`.
- Gap: caret colour from the player (theme item 1, **P1**); block and hollow shapes
  (**P2**). Pointer shape is item 17 (**P0**).

### 6.4 Selections

- Zed: rounded corners, `rounded_selection: true` (`default.json:363`), radius
  `0.15 * line_height` (`element.rs:5993-5997`). `show_whitespaces: "selection"`
  (`default.json:583`).
- Zid: rectangle in `t.selection`, past-EOL width 8px (`editor.zig:202-208`). No
  whitespace display. Double-click selects a word; triple-click is not handled.
- Gap: rounded corners and whitespace (**P2**); triple-click line selection (**P1**).

### 6.5 Editor indent guides

- Zed: enabled, `line_width: 1`, `coloring: "fixed"` (`default.json:770-790`). Colours
  `editor_indent_guide` and `_active` (`element.rs:5285-5291`); indent-aware mode blends
  accent colours (`element.rs:5263-5279`). Painted in `paint_indent_guides`
  (`element.rs:5258-5300`).
- Zid: no editor indent guides. `show_indent_guides` only affects the project panel
  (`project_panel.zig:101`).
- Gap: **P0**. Visible on every indented file (item 2).

### 6.6 Scrollbar

- Zed: `scrollbar.show: "auto"` (`default.json:668`). The comment at `default.json:656-667`
  says auto shows when there is important information or follows the system. Editor
  track width 15px (`crates/ui/src/components/scrollbar.rs:29`, `:425`); padding 4px
  (`scrollbar.rs:30`); minimum thumb 25px (`crates/editor/src/element.rs:10463`).
  Overlays for git, search results, selections, diagnostics and cursors
  (`default.json:657-678`). Thumb drag and track click. `paint_scrollbars`
  (`element.rs:6152`).
- Zid: 5px rect at `e.x + e.w - 8`, minimum 20px, whenever the document is longer than
  one page (`views/editor.zig:219-224`). No drag, no track click, no horizontal bar
  (`doc.scroll_x` exists, `editor.zig:199`).
- Gap: **P0** always-visible bar at the wrong width. **P1** drag, track click, horizontal
  bar. **P2** overlays (after items 10 and 11).

### 6.7 Diagnostics

- Zed: range underlines (`element.rs:5765`, `diagnostic_underline_style`).
- Zid: gutter bar only (`editor.zig:191-198`). The status bar names the diagnostic on the
  cursor line (`app.zig` draw, around line 1013-1022).
- Gap: underlines (**P1**, item 11); inline messages (**P2**).

### 6.8 Search highlights

- Zed: all matches in `search.match_background`, the active one in
  `search.active_match_background` (`one.json:47-48`).
- Zid: `updateSearch` (`app.zig:634-655`) computes the count, but `views/editor.zig` paints
  no match ranges.
- Gap: **P1** (item 10). The count already exists.

### 6.9 Scroll and cursor reveal

- Zed: `vertical_scroll_margin: 3` (`default.json:794`); `horizontal_scroll_margin: 5`
  (`default.json:799-800` region); `scroll_beyond_last_line: "one_page"`
  (`default.json:792`).
- Zid: `revealCursor` (`app.zig:826-838`) moves only when the cursor is off screen, no
  margin. Wheel scrolls 3 lines per notch (`input/events.zig:97`) and clamps at
  `lineCount - 1`.
- Gap: **P1** vertical margin (item 9). **P2** one-page overscroll; horizontal margin.

### 6.10 Soft wrap

- Zed: `soft_wrap: "none"` (`default.json:1687`); `editor_width` and `bounded` modes exist
  (`default.json:1684-1686`).
- Zid: no soft wrap. Long lines scroll horizontally. Files over 32 MiB and lines over
  64 KiB are read-only previews (roadmap and `editor.zig`).
- Gap: **P2**. Off by default in Zed, so not visible on open.

### 6.11 Hover

- Zed: markdown popovers (`crates/editor/src/hover_popover.rs`).
- Zid: plain text, 520px wide and up to 240px tall, 19px lines (`views/hover.zig:215-264`).
  Wheel scrolls it (`input/events.zig:98-101`).
- Gap: **P2** markdown (M8).

### 6.12 Large-file mode

- Zid-specific (roadmap M2): `drawLarge` (`views/editor.zig:226-297`) shows a READ ONLY
  header and byte-offset gutter, no indent guides, search or diagnostics. Keep and
  document as a limit (**P2**).

---

## 7. Status bar

Zed:
- Container `h_flex`, `justify_between`, `gap: Base08` (8px), `p: Base04`
  (`crates/workspace/src/status_bar.rs:116-160`, `:151-153`). Left and right groups use
  `gap_1` (`status_bar.rs:190-230`).
- Hideable items: right click gives "Hide Button" (`status_bar.rs:292-320`).
- Defaults (`default.json:2031-2050` region): `active_language_button: true`,
  `cursor_position_button: true`, `line_endings_button: false`,
  `active_encoding_button: "non_utf8"`, `show_active_file: false`.
- Cursor button text `"{line}:{column}"` (`crates/go_to_line/src/cursor_position.rs:217-222`),
  opens Go to Line (`cursor_position.rs:226-256`).

Zid (`app.zig` draw, around lines 997-1033):
- Left: `panel_left` icon at x=12 (toggles the left dock, click path around line 883-885).
  Then message slot (`app.zig:208-213`, 5s), or a warning: large file, read-only preview,
  glyph replacement, or a ZLS summary.
- Right: `ui:settings` at `status.w - 26` (opens settings, around line 887-889), then
  `"{row}:{col}    {LF|CRLF}    UTF-8    {language}    Spaces: {tab_size}"` (around line
  1034), or `"Byte {offset} / {size}    Selected: {n} bytes"` for large files.
- Clicks on the position text do nothing. Height 26px (`layout.zig:248`).

Gap:
- **P1**: clickable cursor position opens Go to Line (`go_to_line::Toggle`).
- **P1**: default content matches Zed: language and position; LF/CRLF hidden; UTF-8 shown
  only when not UTF-8; no always-on "Spaces".
- **P1**: message slot becomes a toast (item 15).
- **P1**: language button opens a picker (start with built-in languages).
- **P2**: hide-item menu; content-driven height; pending multi-stroke indicator.

---

## 8. Tab switcher

Zed:
- Width `rems(28)` = 448px (`crates/tab_switcher/src/tab_switcher.rs:45`, `:193`, `:244`).
- MRU order from `activation_history()` reversed (`tab_switcher.rs:518`).
- `tab_switcher.show_file_preview: true` (`default.json:1488` block).

Zid:
- Generic picker, 544px (`picker_view.zig:61`).
- Order is a rotation, not MRU: `tabOrder` returns `(active + index) % count`
  (`input/pickers.zig:121-124`). Initial selection is index 1 (`pickers.zig:156`), so the
  first Ctrl+Tab goes to the next tab in document order, not the previous one.
- Confirms on Ctrl release (`input/events.zig:49-51`), matching Zed.
- Dirty `●` hint (`views/modals.zig:82`). No preview.

Gap:
- **P1**: MRU order with a real activation history. Without it, flipping between the two
  most recent files is wrong.
- **P2**: 448px width; file preview.

---

## 9. Command palette

Zed:
- 544px wide, 384px max height (`crates/picker/src/picker.rs:45-46`), 80px from the top
  (`crates/workspace/src/modal_layer.rs:315-318`).
- Sorted by usage: `sort_by_key(|c| (Reverse(c.usage), c.name.clone()))`
  (`crates/command_palette/src/command_palette.rs:610`), persisted in `CommandPaletteDB`.
- Up arrow recalls recent queries (`command_palette.rs:235`).
- Query normalisation (`command_palette.rs:50-65`).
- Sparse rows (`command_palette.rs:777`); key bindings on the right (`:823-834`).

Zid:
- 544px wide, 80px from the top, 12 rows (`picker_view.zig:61`, `:67`, `:74`). Matches.
- Order is the enum order (`pickers.zig:96-103`). No usage ordering or persistence.
- Key hints from the active keymap (`views/modals.zig:66-71`, `picker_view.zig:263-276`).
  Good match.
- Lists only the 116 implemented commands. Unimplemented Zed commands do not appear.
- `humanize` ports Zed's mapping (`pickers.zig:68-93`).

Gap:
- **P1**: usage ordering (in-memory first, then persisted).
- **P2**: recent-query recall; disabled rows for unimplemented commands.

---

## 10. File finder

Zed:
- Same modal size. Name plus directory detail, Sparse rows, icons, highlights.
- History section from recent navigation (`MAX_RECENT_SELECTIONS`).
- `:line:column` parsing via `PathWithPosition` (not re-verified in this pass).

Zid:
- Same geometry. Label and detail split at the last `/` (`views/modals.zig:60-64`).
- Empty query promotes open files only (`pickers.zig:152-155`, `promoteOpenFiles`
  `:160-179`). Not a true history.
- Cap 200 entries (`pickers.zig:65`, `:137`, `:151`).
- No `:line:column` parsing.

Gap:
- **P1**: real recent-file history, sharing the MRU list from item 8.
- **P2**: `file:line:column`; preview pane.

---

## 11. Go to line

- Zed: `rems(24)` = 384px (`crates/go_to_line/src/go_to_line.rs:328`); footer
  `"Current Line: {line} of {last} (column {column})"` (`go_to_line.rs:137-141`);
  previews while typing and restores on cancel.
- Zid: 384px (`picker_view.zig:88`); placeholder `line:column` (`picker_view.zig:89`);
  same footer (`views/modals.zig:43-44`); preview in `lineInputChanged` (`app.zig:486-515`);
  cancel restores cursor and anchor (`app.zig:539`). Large files add `b<offset>` and `%`.
- Gap: none at P0 or P1. Matches on width, placeholder, footer and preview.

---

## 12. Buffer search

Zed:
- Toolbar above the editor (`crates/search/src/buffer_search.rs:102`).
- Placeholders `"Search…"` (`buffer_search.rs:180`) and `"Replace with…"` (`:185`).
- Count `"{index}/{count}"` (`buffer_search.rs:202`); zero matches show `"0/0"` in error
  colour (`:204-205`).
- Toggles (`crates/search/src/search.rs:75-82` `SearchOption`): whole word, case, include
  ignored, regex, one match per line, backwards; tooltips (`search_bar.rs:52-70`).
- Seeds from cursor word or selection (`default.json:842`
  `seed_search_query_from_cursor: "always"`).
- Matches painted in the editor (item 6.8).

Zid:
- `views/buffer_search.zig:165-199`. Placeholder `"Find"` (`buffer_search.zig:188`) and
  `"Replace with"`; status `"{count} match(es) · {Case | ASCII fold}"`, `"No matches"`, or
  `"Search unavailable for large files"` (`:197`).
- Case sensitive on by default (`app.zig` `search_case_sensitive`). Command
  `search::ToggleCaseSensitive` exists with no visible button.
- Replace row (`search::ToggleReplace`, `ReplaceNext`) from commit `5656c22`.
- No whole-word or regex, no next and previous buttons, no close button, no seeding.
- Height 40px, or 76px with replace (`buffer_search.zig:173`).

Gap:
- **P1**: paint matches (item 6.8).
- **P1**: seed the query from the selection or word under the cursor.
- **P1**: `{index}/{count}` with error colour on zero (item 22).
- **P2**: visible toggles for case, word and regex; next, previous and close buttons;
  the Zed placeholder text.

---

## 13. Settings UI

Zed:
- Separate OS window titled `"Zed — Settings"` (`crates/settings_ui/src/settings_ui.rs:897`),
  226px sidebar (`settings_ui.rs:75`), 400px minimum content (`settings_ui.rs:76`).
- Many pages; rows have a title, muted description and a control.

Zid:
- In-window modal, `min(920, w - 48)` by `min(640, h - 48)` (`views/settings_dialog.zig:161-164`).
- 226px sidebar (`settings_dialog.zig:52`); five pages (`settings_dialog.zig:15-16`).
- 13 items in a static table (`settings_dialog.zig` `items`, around lines 24-38) and 8
  themes (`theme_list`, around lines 40-49).
- Focus traversal and search implemented (commits `f44fe67`, `2d5fd2b`).

Gap:
- **P1**: settings for daily Zed changes: scrollbar visibility, vertical margin, line
  numbers, tab close visibility, tab icons, status bar items, `cursor_shape`,
  `soft_wrap`. Add each once the feature exists (items 4, 6.6, 6.9).
- **P2**: separate window (intentional for now).

---

## 14. Keymap editor and keymap coverage

Zed:
- Keymap editor is a workspace item with search, keystroke search, conflict filter, edit
  and create bindings, and row context menus (`keymap_editor::*` actions).
- 569 unique action names in `default-linux.json`.

Zid:
- Table in place of the editor area (`views/keymap_editor.zig` header): Action,
  Arguments, Keystrokes, Context, Source. Context shows "—" for globals. Unimplemented
  actions are muted and tagged "not in Zid" (intentional).
- No edit, create, conflict filter, keystroke search or context menu. Editing is
  not implemented (`docs/REFERENCE_NOTES.md:22`).
- 113 of 569 names are implemented. Missing, UI-relevant ones:
  - `editor::`: `AddSelectionAbove/Below`, `SelectNext/Previous`, `ToggleBlockComments`,
    `ToggleSoftWrap`, `ToggleLineNumbers`, `Fold*`, `Unfold*`, `GoToDiagnostic`,
    `GoToPreviousDiagnostic`, `MoveToEnclosingBracket`, `SelectAllMatches`, `Rewrap`,
    `SelectLargerSyntaxNode`.
  - `pane::`: `SplitRight/Left/Up/Down`, `GoBack`, `GoForward`, `ReopenClosedItem`,
    `CloseItemsToTheLeft/Right`, `TogglePinTab`, `RevealInProjectPanel`.
  - `workspace::`: `ToggleRightDock`, `ToggleBottomDock`, `ToggleAllDocks`, `NewWindow`,
    `ActivatePane*`, `ToggleZoom`, dock size commands.
  - `project_panel::`: `NewFile`, `NewDirectory`, `Rename`, `Delete`, `Trash`, `Copy`,
    `Cut`, `Paste`, `CopyPath`, `Undo`, `Redo`, `ExpandAllEntries`, `OpenContextMenu`.
  - `search::`: `ToggleRegex`, `ToggleWholeWord`, `ToggleIncludeIgnored`, `ReplaceAll`,
    history queries.
  - `zed::`: `Increase/DecreaseUiFontSize`, `ResetUiFontSize`.
  - Later-milestone groups (agent, git, debugger, terminal, notebook, markdown, collab)
    are out of scope here.
- `zid::ReloadConfiguration`, `editor::DeleteToBeginningOfLine` and
  `DeleteToEndOfLine` exist in Zid only. Not gaps.

Gap:
- **P1**: common editor, pane and project-panel actions (see item 25).
- **P2**: keymap edit and create; conflict filter; keystroke search.

---

## 15. Context menus

Zed:
- `ui::ContextMenu`, minimum width 200px (`ui/src/components/context_menu.rs:22`). Used by
  project panel rows (`project_panel.rs:1128`), status bar hide entries
  (`status_bar.rs:292-320`), and the editor mouse menu (`crates/editor/src/mouse_context_menu.rs`).
  Opens on right click; rows show key-binding hints.

Zid:
- None. `input/events.zig:73` handles the left button only. Right-button events fall
  through.

Gap:
- **P1**: minimal menu primitive (rows, separators, hints, keyboard navigation, outside
  click dismiss), then attach to the project panel and tab bar (item 16).
- **P2**: editor right-click menu; status bar hide menu.

---

## 16. Toasts and notices

Zed:
- Toast layer (`crates/workspace/src/toast_layer.rs`): bottom-centre, animated from the
  bottom (`toast_layer.rs:227-263`). Default dismiss 10s (`toast_layer.rs:15`). Hover
  pauses the timer; leaving restarts it (`toast_layer.rs:245-250`); resume minimum 800ms
  (`:16`). Middle-click dismisses (`:252-258`).
- Modal backdrop off for pickers (`modal_layer.rs:58-60`, `fade_out_background` false).

Zid:
- `App.notice` sets a 5-second message in the status bar (`app.zig:208-213`). One message
  at a time; no click dismiss, no hover pause.
- Path dialogs use a full-window black alpha 150 dim (`views/dialogs.zig:281`).

Gap:
- **P1**: toast layer with timeout, hover pause, middle-click dismiss, a small stack.
  Route `ZLS unavailable` and `Definition:` errors through it (`app.zig:323-340`).
- **P2**: notifications panel with history; dialog backdrop policy.

---

## 17. Mouse and cursor

Zed:
- I-beam over text, arrow over the gutter, pointer over links; `IBeam` over line numbers
  in singletons (`element.rs:5343-5344`, `:5391-5396`).
- Scrollbar drag and track click; triple-click line selection; right-click menu.

Zid:
- Left button only (`input/events.zig:73-79`). Double-click selects a word.
- No cursor shape anywhere in `src/`. Only `sdl.mouse.capture` is used
  (`input/events.zig:83`, `app.zig:949`).
- Wheel: 3 lines per notch in the editor and the panel (`input/events.zig:93-123`).

Gap:
- **P0**: cursor shapes (item 7).
- **P1**: triple-click line selection (item 24); right-click menus (section 15).

---

## 18. Geometry that already matches

Keep these unless there is a reason to change them:

- Title bar minimum 34px (`layout.zig:242` vs `constants.rs:17-19`).
- Picker width 544px, top 80px, 12 rows (`picker_view.zig:61`, `:67`, `:74` vs
  `picker.rs:45-46`, `modal_layer.rs:317`).
- Go to line width 384px (`picker_view.zig:88` vs `go_to_line.rs:328`).
- Settings sidebar 226px (`settings_dialog.zig:52` vs `settings_ui.rs:75`).
- Project panel default width 240px (`config.zig:7` vs `default.json:888`) and indent 20px
  (`project_panel.zig:13` vs `default.json:907`).
- Editor font 15px and tab size 4 (`config.zig:5`, `:8` vs `default.json:41`, `:1701`).
- Caret width 2px (`views/editor.zig:339` vs `element.rs:11081-11084`).
- Blink interval 500ms (`app.zig:417`); UI label 14px (`renderer.zig:16`).
- Auto-fold directories on (`config.zig:10` vs `default.json:916`).

---

## 19. Documentation corrections

- `docs/REFERENCE_NOTES.md:17` and `src/app/views/project_panel.zig:1-3` say project rows
  are `h_6`. `h_6` is only on the rename editor (`project_panel.rs:6785-6788`); row height
  is content-derived (`list_item.rs:304`).
- `docs/ROADMAP.md` M2 paragraph says "Replacement controls, case options ... remain
  unfinished". Commit `5656c22` added the replace row and a case toggle exists in
  `commands.zig`. The paragraph looks stale.
- `src/app/views/tabs.zig:73-74` says Zed's close control is 24px. The reference end slot
  is 14px (`tab.rs:6-7`) with an icon button inside. Re-check before relying on 24px.

---

## Top-25 parity checklist

One focused change per item. P0 first, then P1 in visibility order.

### P0

1. **Default editor line height to "comfortable"**: about 1.618 x 15px (about 24px).
   `config.zig:6` (currently 23); keep the explicit setting as an override. Reference:
   `crates/theme/src/buffer_line_height.rs:17-19`, `default.json:54`.
2. **Draw editor indent guides**: 1px `editor.indent_guide` lines per indent level in
   visible rows, active guide in `editor.indent_guide_active`, on by default. In
   `views/editor.zig` before text. Reference: `element.rs:5258-5300`, `default.json:770-790`.
3. **Map editor indent-guide keys with Zed fallbacks**: read `editor.indent_guide*` in
   `theme.zig:66-70`; replace literals at `theme.zig:43-44` with derived fallbacks.
   Reference: `default_colors.rs:99-101`, `fallback_themes.rs:178-179`.
4. **Active line number colour**: use `editor.active_line_number` at `views/editor.zig:190`.
   Reference: `element.rs:136-137`.
5. **Tab bar height 32px**: `layout.zig:244` 35 to 32; adjust `views/tabs.zig:86-115`
   geometry and baselines. Reference: `tab.rs:79-85`.
6. **Inactive tab background**: `tab.inactive_background` for inactive tabs
   (`views/tabs.zig:112`, `:131-134`); add the key to `theme.zig`.
7. **Mouse cursor shapes**: I-beam over editor content, arrow elsewhere, pointer over
   clickable rows, resize cursors on window edges. Typed `zig-sdl3` cursor API only
   (AGENTS.md). Hook from `input/events.zig:85-92` and `app.zig:186-206`. Reference:
   `element.rs:5343-5344`.
8. **Editor scrollbar behaviour**: `views/editor.zig:219-224` to an auto scrollbar with a
   15px track, 25px minimum thumb, 4px padding, shown only when needed or in use.
   Reference: `scrollbar.rs:29,425`, `element.rs:10463`, `default.json:668`.

### P1

9. **Vertical scroll margin of 3**: in `revealCursor` (`app.zig:826-838`). Reference:
   `default.json:794`.
10. **Paint search matches**: in `views/editor.zig:drawEditor`, matches in
    `search.match_background` and the active one in `search.active_match_background`,
    using the plan and count from `app.zig:634-655`. Reference: `one.json:47-48`.
11. **Diagnostic underlines**: wavy underline on the range; keep the gutter bar as
    secondary (`views/editor.zig:191-198`). Reference: `element.rs:5765`.
12. **Close button on hover, dirty dot in the same slot**: `views/tabs.zig:141`.
    Reference: `default.json:1511`.
13. **Flex tab widths**: replace the 130-250 clamp (`views/tabs.zig:159-161`) with a
    24px minimum and growth to fill. Reference: `pane.rs:3738-3740`.
14. **MRU tab switcher**: track activation history and sort by it
    (`input/pickers.zig:121-124`, `:156`). Reference: `tab_switcher.rs:518`.
15. **Toast layer**: replace the 5s status message (`app.zig:208-213`) with a
    bottom-centre toast: 10s timeout, hover pause, middle-click dismiss. Route ZLS and
    definition errors through it. Reference: `toast_layer.rs:15-16,227-263`.
16. **Context menu primitive**: 200px minimum width, keyboard navigation, outside-click
    dismiss; opened from right click in `input/events.zig`. Reference:
    `context_menu.rs:22`.
17. **Project panel right-click menu and file operations**: attach item 16 to rows; add
    new file, new directory, rename, delete, copy path. Reference:
    `project_panel.rs:1128`, `:6832`.
18. **Project panel scrollbar**: match the editor's auto scrollbar with thumb drag
    (`views/project_panel.zig:136-146`). Reference: `default.json:934`.
19. **Status bar defaults**: hide the always-on UTF-8 and "Spaces" text; show encoding
    only when not UTF-8; keep language and cursor position (`app.zig` status section).
    Reference: `default.json:2031-2050`.
20. **Clickable cursor position**: route clicks on the position text (`app.zig:879-890`)
    to `go_to_line::Toggle`. Reference: `cursor_position.rs:211-256`.
21. **Project name opens recent projects**: make `views/title_bar.zig:36` clickable and
    open the `projects::OpenRecent` picker. Reference: `title_bar.rs:783`, `:864`.
22. **Buffer search seed and count**: seed the query from the selection or word
    (`default.json:842`), show `{index}/{count}` with error colour on zero
    (`buffer_search.rs:202-205`), placeholders `Search…` and `Replace with…`
    (`buffer_search.rs:180,185`).
23. **Panel width drag handle**: 6px hit area on the panel edge in `layout.zig`; drag
    updates `settings.panel_width`, persisted with `saveSettings`. Reference:
    `crates/workspace/src/dock.rs:25`.
24. **Triple-click line selection and gutter line selection**: in the click path
    (`app.zig:867-905`), `clicks >= 3` selects the line; a gutter click selects the row.
    Reference: `element.rs:5342-5396`.
25. **Common editor, pane and panel action batch**: add to `commands.zig` and dispatch the
    commands that need no new feature: `editor::ToggleLineNumbers` (setting-backed) and
    `editor::ToggleSoftWrap` (reports "not in Zid" until soft wrap exists). Reference:
    `assets/keymaps/default-linux.json` (section 14).
