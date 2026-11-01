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

M2 has integrated the persistent-tree Document and word-coalesced undo, capped at
1000 entries with save/navigation boundaries. Files above 32 MiB open in a separate read-only byte viewer with bounded positional reads, incremental indexing and byte/percentage navigation. A heap-owned worker performs post-open reads, indexing and line lookup; rendering polls bounded in-memory snapshots. Close currently joins the worker, which may wait on an outstanding filesystem operation. The viewer decodes valid UTF-8, tabs and CRLF, replaces invalid/control bytes, and truncates long logical lines with a marker. Up/down, page and wheel navigation resolve logical LF-delimited lines asynchronously; Home/End resolve line boundaries, while left/right and percentage navigation remain byte-based. Long lines can take time to scan, with bounded reads and superseding requests; navigation is line-start based rather than column-preserving. Keyboard byte selection and asynchronous clipboard copy are available, capped at 1 MiB and requiring valid UTF-8 without NUL; a selection that splits a UTF-8 sequence fails validation. The status bar shows selected bytes and the viewer highlights decoded selection, including selected line endings; partial UTF-8 character selections highlight the whole displayed character. Mouse selection is not implemented; it is not yet the complete large-file editor experience. Indexed line lookup is available; no index scan is required before the first view. A history byte budget, add-buffer compaction and performance targets remain. Memory-backed files with lines over 64 KiB remain read-only previews. Later milestone features have not been implemented by this shell work.

Literal find is available as a tested streaming KMP core (`editor/search.zig`) with ASCII case folding, overlapping matches and bounded result batches. A compact Ctrl+F literal exact-case bar now supports query retention, Enter/F3 next, Shift+Enter/Shift+F3 previous, Escape focus return and capped counts for memory-backed files. Counting is currently synchronous. Replacement controls, case options and large-file search remain unfinished.
