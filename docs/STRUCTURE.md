# Module plan

Zid is one application with a headless core, platform services, and a presentation
layer. Features grow inside these boundaries; they do not become additions to one
application file. Planned directories are introduced when they contain real code.

| Directory | Owns | May depend on |
| --- | --- | --- |
| `core/` | logging, jobs, mailbox, IDs, cancellation, configuration primitives | Zig standard library |
| `text/` | byte sources, piece tree, snapshots, indexing, Unicode, history | core, standard library |
| `editor/` | documents (`document`), treap-backed storage (`text_buffer`), editor commands behind `editor::*` actions (`commands`), workspace lifecycle | text, core, standard library |
| `syntax/` | incremental lexers, checkpoint state, later structure | text, core, standard library |
| `project/` (planned) | file tree, watches, fuzzy search, project metadata | editor IDs, core, filesystem interface |
| `app/` | application ownership, scheduling, configuration and action routing | headless modules, platform, gfx |
| `app/views/` | title bar, files, tabs, editor, status, dialogs, settings, pickers (`picker_view`, `modals`), keymap editor | application view state, gfx, layout |
| `app/input/` | event translation, keymap dispatch (`events`), Zed action registry and focus contexts (`commands`), picker controllers (`pickers`) | app actions, typed SDL events |
| `app/` (pure helpers) | `keymap` (Zed keymap parse/resolve), `fuzzy`, `line_input`, `recent_projects`, `icon_theme`, `text_match` | standard library only; tested by `test-ui` |
| `util/` | dependency-free encoders (PNG for `--screenshot`) | standard library |
| `app/config/` (planned) | settings, keymap and theme registry | standard library; no SDL |
| `gfx/` | GPU pipelines, batching, clipping, glyph/icon atlas | typed zig-sdl3 GPU, font/SVG raster interfaces |
| `platform/` | windows, native caption icons, clipboard, fonts | typed zig-sdl3, native font libraries |
| `lsp/` (planned) | JSON-RPC framing, processes, document versions | core, editor IDs, process interface |
| `terminal/` (planned) | PTYs, libghostty screen model | core, process interface |
| `diff/` (planned) | histogram/Myers and intraline differences | text, standard library |
| `db/` (planned) | connections, drivers, query execution and result streams | core; no presentation |
| `markdown/` (planned) | block/inline model | text, standard library |
| `notebook/` (planned) | ipynb model, kernel sessions and output lifecycle | editor, core, process interface |
| `remote/` (planned) | transport, server, filesystem/process proxies | core, protocol interfaces |

The application owns documents and workers. Views borrow state for a frame and
record hit geometry from the same layout used to draw. Worker results carry a
document ID, generation and revision; workers never hold pointers into UI arrays.
Persistent text snapshots own their backing source. Every file operation accepts
`std.Io`. Feature modules expose commands and state, never SDL events or GPU handles.

The shell uses the persistent tree for memory-backed documents. Stable document IDs and a history byte budget remain M2 work; large-file indexing now has a heap-owned worker.

Before M3, workspace file access and process spawning gain explicit interfaces so
local and SSH projects share the editor model. The terminal, database, notebook and
remote milestones each get headless protocol/model tests before their views.

`text/large_file.zig` provides an independent read-only, positional byte backend
with budgeted chunk newline indexing and stale-file checks. The heap-owned `text/large_worker.zig` exclusively accesses this backend after opening. Separate read-only Document state owns the worker pointer and requests windows/lines by generation. Rendering polls bounded snapshots, retains the previous window while loading, and decodes UTF-8 with `text/large_display.zig`; invalid bytes and controls become replacement characters. Worker destruction stops and joins, so closing can still wait for an outstanding filesystem operation.
