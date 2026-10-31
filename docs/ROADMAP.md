# Zid goal and roadmap

## Goal

A fast, low-memory, Zed-looking editor that is the user's daily driver for Zig, C/C++,
Python and SQL work. It has a first-class database client, Colab-quality notebooks,
remote SSH projects, and opens multi-gigabyte files without loading them into RAM.

**"Done" for v1** means all of the following hold on this machine:

1. Cold start to first paint < 150 ms (Debug < 400 ms); idle CPU 0%; empty-window RSS < 30 MiB.
2. Opening a 10 GiB file is interactive within 200 ms, and RSS stays below 100 MiB.
3. Zig projects: zls completion, diagnostics, go-to-definition, hover, `zig build` tasks,
   and format on save.
4. The editor runs SQL against SQLite and Postgres and browses schemas.
5. It runs `.ipynb` notebooks with rich outputs.
6. It edits a project on a remote host over SSH.

## Milestones

Each milestone ends with tests (`zig build test`, `test-layout`, `smoke`, `check`) and an
adversarial Codex review before the next one starts.

| # | Milestone | Contents |
| --- | --- | --- |
| M1 | **Shell** | Logging, settings/keymap/theme loading, SDL_GPU renderer + glyph atlas, Zed-style title bar, project panel, tab bar, editor view, status bar, basic editing, clipboard, Zig/C/Python lexer highlighting |
| M2 | **Text engine** | Piece tree + snapshots, bounded positional reads + background line index for huge files, read-only large-file mode, history budget, multi-cursor, find/replace in buffer |
| M3 | **Navigation** | Command palette, fuzzy file finder, go to line, project search (worker), file watcher, external change reload |
| M4 | **LSP** | Client, zls/clangd/ty, diagnostics, completion, hover, go-to-def, semantic tokens, format |
| M5 | **Terminal** | PTY + libghostty-vt, bottom dock, multiple terminals |
| M6 | **Git + diff** | Status in the project panel, gutter hunks, diff view, histogram diff engine |
| M7 | **Database** | SQLite + Postgres drivers, connection manager, SQL editor, results grid, schema browser |
| M8 | **Markdown** | Parser + preview pane |
| M9 | **Notebooks** | ipynb model, kernel bridge, cell UI, rich outputs |
| M10 | **Remote** | zid-server, ssh transport, remote worktrees, LSP/terminal proxying |
| M11 | **AI chat** | Deferred. Claude Agent SDK + Codex app server, chat view, history sidebar |

## Status

- [x] M1 basic shell delivered (see acceptance ledger and current limits below)

### M1 acceptance ledger

Implemented: typed SDL_GPU renderer, bounded glyph/SVG atlas, transparent rounded
window, native caption glyphs, Zafi shell, project folders, tabs, editor and status,
clipboard, history commands, safe-close/Save As flow, JSONC settings/keymaps, sourced
built-in themes and Zed default fonts/icons, incremental lexers.

M2 is still required for persistent-tree Document integration, background indexing,
large-file mode, long-line windowing, bounded/coalesced undo and performance targets.
The existing application remains capped at 32 MiB, with read-only previews for lines
over 64 KiB. Later milestone features have not been implemented by this shell work.
