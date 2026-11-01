# Zid architecture

Zid is a personal, single-user native code editor in Zig 0.17. It is Zed-shaped in look
(title bar, project panel, tab bar, status bar, keymaps, command palette) but deliberately
narrower in scope, and it adds a database client, SQL editor, notebooks and true
very-large-file support. Speed and low memory beat feature count and portability.

## Process and threading model

- **Main thread**: owns all application state, input routing, layout and GPU submission.
  It sleeps in `SDL_WaitEvent` and draws only when something is dirty. No continuous render loop. Current M1 still redraws on input/blink and checks configuration timestamps once per second; the worker/deadline scheduler below is planned.
- **Worker pool** (`src/core/jobs.zig`): file loading, line indexing of huge files,
  project scanning, fuzzy search, diffing, highlighting of off-screen regions. Workers
  never touch UI state; they read immutable buffer *snapshots* and post results.
- **Endpoint threads**: each external process or socket (LSP server, PTY, DB connection,
  Jupyter kernel, SSH channel) has one reader thread that frames messages and posts them.
- **Mailbox**: an MPSC queue drained by the main thread each wake, time-budgeted.
  A `wake_pending` atomic means only one `SDL_EVENT_USER` is pushed per drain; if the
  push fails, the next timed wake drains anyway. Every message carries
  `(target id, generation, revision)`, so results for closed/reopened documents,
  restarted servers or stale revisions are dropped. Payload ownership transfers with
  the message. Replaceable results (highlight, diff, search progress) coalesce.
- **Waiting**: `SDL_WaitEventTimeout` until the earliest deadline (cursor blink,
  animation, debounce timers), so it never busy-loops and never misses timers.

## Module layout

```
src/
  main.zig            entry: argument parsing, logging setup, app run / --check
  root.zig            the `zid` core module (no SDL, no GPU, no Zafi)
  core/               std-only infrastructure: log, jobs, mailbox, paths, json(c) settings
  text/               piece tree, snapshots, line index, UTF-8/grapheme helpers, history
  editor/             Document, Selection set, Workspace, commands on text (headless)
  syntax/             incremental lexers per language, highlight spans, bracket matching
  project/            worktree scan, file watching, fuzzy finder, git status
  diff/               line + word diff engine
  lsp/                JSON-RPC framing, LSP client, server registry (zls, clangd, ty)
  terminal/           PTY + libghostty-vt screen model (no rendering)
  db/                 connection drivers (sqlite, postgres wire), result sets, schema
  notebook/           .ipynb model, kernel bridge
  remote/             ssh transport, remote server protocol
  markdown/           CommonMark-ish parser -> block/inline tree
  app/                the UI: theme, settings, keymap, actions, views (title bar,
                      project panel, panes/tabs, editor view, status bar, palette)
  gfx/                SDL_GPU renderer: quad + glyph pipelines, atlas, scene batching
  platform/           SDL window/events, fonts (FreeType/HarfBuzz/fontconfig), clipboard
```

`src/text`, `src/editor`, `src/syntax`, `src/diff`, `src/lsp`, `src/db`, `src/markdown`
and `src/core` must never import SDL, Zafi or `gfx`. Everything that touches files takes
`std.Io` explicitly. That keeps the bulk of the editor testable headlessly with `zig build test`.

## Text storage and very large files

- **Piece tree**: a persistent treap of pieces (a wider B-tree is a later benchmark-driven option) referencing two kinds of storage: the *original*
  file and an append-only *add* buffer. Each node caches byte length and newline count,
  so offset/line conversion and edits are expected O(log n).
- **Sources**: a piece references a `Source` (`src/text/source.zig`). Small files
  (<= 16 MiB) are read into an immutable heap block. Larger files are a *file source*
  read with positional reads through a bounded per-reader chunk cache (256 KiB chunks,
  LRU, a few MiB per reader). RSS is bounded by cache size, not file size. We do not
  mmap: scanning a mapping makes it resident, external writes break snapshot
  immutability, and SIGBUS is not a sound recovery boundary (adversarial review).
- **Consistency**: a file source records (size, mtime, inode) at open. Reads verify
  length; the watcher and a stat before save detect external change. The document is
  then marked *stale*: it stays readable with a reload banner, and saving over it is refused.
- **Lazy line index**: a big file starts as 64 KiB pieces whose newline counts are
  unknown. A background job counts newlines (SIMD) and posts counts in batches.
  **Semantics**: byte navigation (scrolling, scrollbar, go-to-percentage) is always exact.
  Line numbers are shown only for the indexed prefix. Go-to-line beyond it waits on the
  indexer. A document is **editable only once fully indexed**, so history never holds
  unindexed roots. Intra-piece lookups scan at most one 64 KiB piece.
- **Modes**: files over `large_file_editable_limit` (default 256 MiB) open read-only
  ("Make editable" is explicit). Large-file mode: highlighting is viewport-only, LSP is off,
  and wrapping is off. Long lines are processed in byte windows (<= 64 KiB), and lexer
  spans are window-relative, so `u32` offsets are safe.
- **Snapshots**: nodes are immutable and reference-counted; an edit path-copies O(log n)
  nodes. A snapshot is a root pointer plus revision, cheap to hand to workers.
- **History**: because the tree is persistent, an undo entry is the previous root
  plus selections (O(log n) retained nodes, never a copy of removed text). Typing coalesces
  by word in the current implementation, with boundaries at saves and navigation.
  History retains at most 1000 entries; a retained-node byte budget remains planned. The add buffer is
  append-only in stable 1 MiB blocks; compaction of unreachable add bytes is future work.

### Text engine design (2026-11-01): one structure, three borrowed ideas

We compared the current persistent treap with two strong alternatives: JumpRope (an
indexed skip list whose leaves are small gap buffers, tuned for single-cursor typing) and
an augmented B+ tree with compact contiguous leaves (Zed's `SumTree`, xi, ropey; fast line
lookup, cheap snapshots, batch edits). They answer different questions, so Zid takes one
answer per question instead of running several structures:

| Question | Decision | Borrowed from |
| --- | --- | --- |
| Where bytes live | Pieces over the original (memory or positional file reads) and an append-only add buffer | Piece table / current treap: huge files are never loaded |
| Index shape | Persistent tree with per-node byte/newline/unknown sums; treap today, wide B+ (fan-out 16-32, piece-array leaves) only if traces show it wins | B+ tree |
| Typing speed | (a) *grow-in-place*: inserting where the last add piece ends appends to the add buffer and path-copies only to lengthen that piece, so typing doesn't fragment into 1-byte pieces; (b) *edit cursor cache*: the last located piece is remembered so sequential byte access is O(1); (c) planned: mutate nodes in place when uniquely owned (refcount 1) | JumpRope (gap-buffer locality without a gap that would break snapshots) |
| Undo | Each entry holds the previous and next roots plus selections; typing coalesces into one entry | Persistent trees |
| Line index | Derived from tree sums; no eager per-line array in Document | B+ tree summaries |
| Multi-cursor | Planned: edits sorted descending, applied as one batch and one undo entry | B+ tree batch edits |

A real gap buffer inside a leaf is rejected: workers read snapshots concurrently, and
moving a shared gap would mutate published text. Grow-in-place plus uniquely-owned
mutation gives the same locality.

**Migration.** Step 1 (done in this change): `editor/text_buffer.zig` exposes the old
Buffer API (len, byteAt, copy, next, previous, replace, toOwnedSlice) plus line queries
over the treap, and `Document` uses it; history becomes root pairs. Step 2: file-backed
read-only large-file mode with the background indexer. Step 3: a benchmark harness with
real editing traces (josephg/editing-traces) and large-file scans; switch the index to
a B+ tree behind the same API only if the numbers justify it.

## Syntax highlighting: incremental lexers, not Tree-sitter (for now)

Tree-sitter holds a full concrete syntax tree in memory (often 10-30x the source size)
and costs a C runtime plus a grammar per language. We only support a handful of languages,
so we use hand-written **incremental lexers** with resumable per-line state:

- Each lexer is a state machine `(state, line bytes) -> (spans, next state)`.
- We store the entry state per **checkpoint** every 64 lines (a few bytes each), not per token.
  Highlighting a viewport lexes from the nearest checkpoint. An edit invalidates checkpoints
  after it until the state converges again.
- Memory is O(lines / 64) bytes of state plus the visible spans. Large files work.
- **Zig** uses `std.zig.Tokenizer` for exact tokens; `std.zig.Ast` (in a worker, for files
  under a limit) adds an outline, folds and declaration-aware coloring.
- **Semantic colour** comes from LSP semantic tokens (zls, clangd, ty) layered over lexer spans.
- Highlighting is deliberately separate from structure (folds, symbols, injections),
  which lives in `syntax/structure/` with its own size gates. Lexer state that cannot fit a
  u32 (e.g. C++ raw-string delimiters) is approximated, and we document where.
- Tree-sitter can be added later for structure (it accepts chunked readers, so it is
  compatible with the piece tree) for structural
  features if the lexers prove insufficient. No newer project is clearly better than
  Tree-sitter for structure; for coloring alone, lexers win on memory.

Languages: Zig, C, C++, Python, SQL, Markdown, JSON, plus plain text.

## Rendering

- **SDL_GPU** (Vulkan on Linux) with two pipelines, GPUI-style:
  1. *Quads*: instanced rects with per-corner radius, border width/color, solid fill and
     soft shadow, all evaluated as SDFs in the fragment shader.
  2. *Glyphs/icons*: instanced textured quads sampling an R8 alpha **atlas** (and an RGBA
     atlas for color emoji/icons), tinted per instance.
- GLSL shaders live in `src/gfx/shaders/`, are compiled with `glslc` by a `zig build shaders`
  step, and the SPIR-V is committed so normal builds do not need glslc.
- A frame is a **scene**: a flat list of layered primitives built each frame from view
  state, sorted by layer, uploaded through a persistent transfer buffer. Clip rects
  become scissor runs.
- **Glyph atlas**: shelf packer, glyphs keyed by (font, glyph id, subpixel x bucket).
  Glyph rasterization is FreeType; shaping is HarfBuzz with a per-line shape cache keyed
  by (line content hash, font). The atlas grows by pages and evicts by LRU frame.
- **Icons**: Zed Default SVGs (from the reference checkout's licensed UI and file icon sets) are
  rasterized at the needed size with nanosvg into the color atlas.
- The window supports alpha for rounded corners. One Dark is opaque; the Glass alternative carries upstream transparency. Blur depends on the compositor and is not implemented.

## UI

- **Layout**: Zafi (flexbox) lays out the *shell*: title bar, docks, pane splits, tab
  bar, status bar, palette overlays. Shell layout is recomputed only when the window size
  or dock state changes. Text inside the editor is laid out by our own monospace grid
  code, never by Zafi.
- **Views** build the scene directly in an immediate-mode style from retained state
  (`app/views/*`). Hit-testing uses the same rects recorded while building the scene.
- **Actions and keymap**: every command is a named action (`editor::Copy`,
  `workspace::ToggleLeftDock`, …). Keymaps bind keystroke sequences to actions within a
  context predicate (`Editor`, `ProjectPanel`, `Terminal`). Defaults ship embedded; the
  user overrides them in `~/.config/zid/keymap.json`.
- **Settings**: `~/.config/zid/settings.json` (JSON with comments and trailing commas),
  merged over embedded defaults and hot-reloaded. Zid never reads Zed's config.
- **Theme**: the default theme is Zed's built-in *One Dark*, with Zed Default icons, IBM Plex Sans UI text and Lilex code text. One Dark Pro Glass, Ayu, Gruvbox, Solarized, Tokyo Night, Catppuccin and VS Code are built-in alternatives loaded from their unmodified upstream JSON.

## Language tooling

- LSP client over stdio with Content-Length framing; requests are cancellable and tagged
  with the document version. Servers: **zls** (pinned, buildable from source via
  `zig build zls`, matching our Zig version), **clangd**, **ty** (`ty server`).
- Zig gets the deepest support: `build.zig` awareness (build steps in the palette and
  the `zig build` task runner), `std.zig.Ast` outline, `zig fmt` on save, error-trace
  parsing in the terminal to jump to source.

## Other subsystems (planned)

- **Terminal**: `forkpty` + **libghostty-vt** (Zig package from the Ghostty repo, pinned)
  for parsing and screen state; we render cells with our glyph pipeline.
- **Diff**: histogram diff (with Myers fallback) over interned line hashes, then a word
  diff within changed hunks. Git base text comes from `git cat-file` subprocesses. We do
  not use libgit2.
- **Database client**: SQLite via system `libsqlite3`; PostgreSQL via a native Zig
  implementation of the wire protocol (no libpq); MySQL later. Results stream into a
  virtualized grid with column metadata; schema introspection feeds SQL completion.
- **Notebooks**: `.ipynb` model in Zig; kernels via a tiny Python bridge on stdio
  using `jupyter_client` (Python is needed for the kernel anyway). Cells are embedded
  editors; outputs are text, ANSI, images (PNG via stb_image) and Markdown.
- **Remote development**: `zid-server` is the same codebase built headless and
  cross-compiled by Zig for the remote target. It is uploaded over the system `ssh`
  (ControlMaster) and speaks a framed binary protocol on stdio: fs, search, LSP proxy, PTYs.
- **Markdown**: our own parser to a block/inline tree, rendered by our views (preview pane).
- **AI (deferred)**: a chat view (no agents panel) backed by the Claude Agent SDK and the
  Codex app server, with history in the same sidebar.

## Logging

`std.log` with a custom `logFn`: monotonic timestamp, level, scope (`gfx`, `text`, `lsp`,
…), and message. It writes to stderr (colored when it is a TTY) and to
`$XDG_STATE_HOME/zid/zid.log`. Scope levels are configured with `ZID_LOG=lsp=debug,gfx=info`.
Hot paths log timings at debug level (startup phases, file open, index, first paint).

## Memory budget (targets, measured with `--stats`)

| Scenario | Target RSS (excluding GPU driver) |
| --- | --- |
| Empty window | < 30 MiB |
| Project open + 10 small files | < 50 MiB |
| 10 GiB file open read-only | + < 64 MiB (indexing state + viewport) |
| Per open source file | ~1.1x file size + O(lines/64) highlight state |

## Review log

- 2026-10-31, Codex architecture review: adopted bounded `Source` reads instead of mmap,
  partial-index semantics, mailbox generations and wake protocol, deadline waiting,
  highlight/structure separation, window-relative spans, and painter-order batching.
  Deferred but recorded: add-buffer compaction, a remote `Fs`/process interface before M3
  (`project/` takes an `Fs` vtable from the start), and a richer notebook output model
  (parent routing, display updates, stdin, interrupts, output spooling).

## Current integration boundary

See README.md for implemented M1 behavior and current limits. The running Document
uses the piece treap through `editor/text_buffer.zig` for memory-backed originals. A separate read-only large-file byte viewer uses positional reads and indexes and reads on a heap-owned background worker, publishing bounded snapshots by request generation. Full line-oriented navigation, selection and copy remain unfinished; close currently joins the worker and may wait for filesystem I/O. See STRUCTURE.md for the actual presentation-layer split and planned
feature boundaries. AI remains deferred.

Reference-led decisions and inspected source areas are recorded in REFERENCE_NOTES.md.
