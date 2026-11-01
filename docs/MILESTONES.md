# Zid milestones: Zed, rebuilt in Zig

Goal: a faithful Zig clone of Zed. Same look, same behavior, same keymaps, settings and
themes (read in Zed's own JSON formats). Every milestone names the Zed crates it covers
(`.ref/zed/crates/*`) and is checked against the reference Zed build
(`zed-linux-x86_64/`, screenshots under Xvfb as in REFERENCE_NOTES.md) before it is
marked done. Our own improvements (large-file mode, piece treap, database client) wait
until parity, as ZED_PARITY.md records.

Status: **done**, **partial**, **next**, **later**. "Done" means it matches Zed in the
side-by-side check and has tests. It does not mean "exists".

## Z0 — Shell and chrome (partial, mostly done)

Crates: `title_bar`, `workspace` (status bar, modal layer, pane chrome), `ui`
(ContextMenu, Tooltip, prompts), `onboarding`, `workspace::welcome`, `client` (sign-in),
`image_viewer`.

- [x] Title bar segments, application menu bar, user menu, Sign In with zed.dev and avatar
- [x] Status bar items and LSP menu; tooltips with the 500ms delay
- [x] Tab bar (nav buttons, + / split / zoom, hover close, content-sized tabs)
- [x] Context menus: editor, tab, project panel, application, user
- [x] Prompts (unsaved changes, quit, trash/delete) and system path pickers
- [x] Command palette and file finder (preview pane, history, footers, hover selection)
- [x] Onboarding and Welcome pages
- [x] Image decoding (PNG, JPEG, GIF, BMP in pure Zig) and the image viewer
- [ ] Settings as Zed's separate settings **window** (currently an in-window dialog)
- [ ] Branch, worktree and language pickers; theme and icon-theme selectors
- [ ] "Unrecognized project" trust modal and Restricted Mode
- [ ] Toasts and notifications (bottom-right stack, 10s timeout)

## Z1 — Text model and editor core (partial)

Crates: `sum_tree`, `rope`, `clock`, `text`, `editor` (display map, selections,
movement), `multi_buffer`.

- [x] `sum_tree`, `rope`, `clock`, `text` ported and tested
- [ ] Editor storage switched to `text::Buffer` (anchors, transactions, `edits_since`)
- [ ] Display map: inlay → fold → tab → wrap → block maps; soft wrap
- [ ] Multiple cursors and selections (add above/below, select next occurrence, column select)
- [ ] Auto-indent, autoclose brackets, bracket matching, rewrap, toggle comments, move/duplicate lines
- [ ] Folding (fold markers, unfold), indent guides from the display map
- [ ] Rounded selections, whitespace rendering, current-line and search highlights
- [ ] Buffer search parity (regex, whole word, case, replace all, selection-only)

## Z2 — Workspace and panes (later)

Crates: `workspace` (pane groups, docks, persistence), `project`, `worktree`, `fs`.

- [ ] Split panes (SplitUp/Down/Left/Right), pane focus and resize, zoom
- [ ] Left, right and bottom docks with panel switching and resizing
- [ ] Preview tabs, pinned tabs, `max_tabs`, back/forward navigation history
- [ ] Workspace persistence: reopen windows, tabs, scroll and cursor on restart (sqlite `db`)
- [ ] Multi-root worktrees, file watcher and external-change reload, .gitignore handling
- [ ] Multiple windows (`workspace::NewWindow`)

## Z3 — Languages and LSP (later)

Crates: `language`, `languages`, `lsp`, `project` (lsp_store), `editor` (completions,
hover, code actions, inlay hints), `diagnostics`, `outline`, `outline_panel`.

- [ ] Syntax: decide the parser strategy (see decisions below), syntax map, highlight queries
- [ ] Language registry with Zed's built-in languages and `languages/*/config.toml` settings
- [ ] LSP client parity: completions menu, hover, signature help, code actions, rename,
      formatting, references, go-to-definition/type/implementation, inlay hints, semantic tokens
- [ ] Diagnostics: underlines, gutter, inline, project diagnostics view, status counts
- [ ] Outline (symbols in editor) and the outline panel

## Z4 — Search and navigation (later)

Crates: `search`, `project_symbols`, `file_finder` (remaining), `tab_switcher`, `go_to_line`.

- [ ] Project search in a multibuffer with replace, include/exclude filters
- [ ] Project symbols, recent-file history persistence, file finder actions menu
- [ ] Multibuffer excerpts (needed by search, references and diagnostics)

## Z5 — Terminal (later)

Crates: `terminal`, `terminal_view`. Zid plans libghostty-vt instead of alacritty's parser.

- [ ] PTY, terminal panel in the bottom dock, multiple terminals, tabs
- [ ] Terminal keymap context, copy/paste, hyperlinks, `terminal: open in terminal` from menus

## Z6 — Git (later)

Crates: `git`, `git_ui`, `project` (git_store), `editor` (git gutter, blame).

- [ ] Git panel (stage, unstage, commit, amend, push/pull/fetch)
- [ ] Gutter hunks, inline blame, blame view, file history, diff view
- [ ] Branch picker, worktree picker, stash; permalinks; restore file

## Z7 — Settings, keymap, themes, extensions (later)

Crates: `settings_ui`, `keymap_editor`, `theme_selector`, `extensions_ui`, `extension_host`.

- [ ] Settings window parity (every page in Zed's order, search, project settings)
- [ ] Keymap editor parity: edit/add/remove bindings, conflicts, context editing
- [ ] Theme and icon-theme selectors with live preview
- [ ] Extensions: decide the runtime (see decisions), then install themes/languages from zed.dev

## Z8 — Tasks and debugger (later)

Crates: `task`, `tasks_ui`, `debugger_ui`, `dap`.

- [ ] tasks.json, the task spawn modal, runnables in the gutter
- [ ] DAP client, debugger panel, breakpoints, stepping, variables

## Z9 — Remote development (later)

Crates: `remote`, `remote_server`, `recent_projects` (ssh).

- [ ] SSH connections, remote worktrees, remote LSP and terminal

## Z10 — Collaboration and AI (deferred)

Crates: `collab_ui`, `call`, `channel`, `agent_ui`, `edit_prediction`. AI stays deferred
(AGENTS.md). Collaboration needs Zed's servers; signing in already works.

## Zid additions after parity

Large-file mode, piece treap / JumpRope buffer experiments, database client, and the
performance goals in ROADMAP.md.

## Decisions needed

1. **Parser strategy.** Zed uses tree-sitter grammars and queries, which are C libraries.
   AGENTS.md allows C bridges only for fonts and SVG. Options: allow tree-sitter as a pinned
   C dependency (exact parity with Zed's queries), or write incremental parsers in Zig
   (large, and they can drift from Zed's highlighting).
2. **Extensions.** Zed extensions are WebAssembly components. Matching them needs a Wasm
   runtime. Options: a pure-Zig interpreter, or a pinned C runtime (wasmtime/wamr).
   Theme-only and language-only extensions work without one.
3. **Settings window.** Zed opens settings in a separate OS window. That needs
   multi-window support from Z2 first.
