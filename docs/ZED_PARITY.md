# Zed parity plan

Decision (2026-11-01): Zid now recreates Zed in Zig as faithfully as practical, crate by
crate and behavior by behavior. Our own designs and improvements wait until parity is
reached. The database client is paused. AI features remain deferred.

The rules that still apply: Zafi is pinned upstream, headless modules stay independent of
SDL/rendering, and file operations take `std.Io`. See AGENTS.md.

## Deferred Zid designs (kept, not deleted)

These notes describe changes we plan to make *after* parity. Until then they are not the
target. The existing code stays where it is and keeps passing its tests.

| Topic | Where it is recorded | Status during parity |
| --- | --- | --- |
| Persistent piece treap, grow-in-place typing, edit cursor cache | ARCHITECTURE.md "Piece tree", `src/text/piece_tree.zig`, `src/editor/text_buffer.zig` | Kept. New Zed-style buffers are built on the `sum_tree`/`rope` ports. The current UI keeps the treap until the `text` port can replace it. |
| JumpRope (indexed skip list with gap-buffer leaves), wide B+ alternative, rejecting gaps inside shared leaves | ARCHITECTURE.md "comparison" table and gap-buffer note | Benchmark candidates for after parity. Zed's `SumTree` rope is the parity baseline. |
| Large-file read-only viewer (positional reads, background line index) | ROADMAP M2 ledger, `src/text/large_*.zig` | Kept as-is. Zed loads files fully. Zid's large-file mode is an addition we will revisit. |
| Lazy line index, history byte budget | ARCHITECTURE.md | Deferred. |
| Database client (SQLite/Postgres) | DATABASE_IMPLEMENTATION.md, `src/database/` | Paused. The code stays and its tests still run. |

## Crate map

Each Zed crate gets a Zig module with the same name and the same public API (camelCase).
Specs written while exploring the Zed source live in `docs/zed_port/`.

| Zed crate | Zig module | Spec | Status |
| --- | --- | --- | --- |
| `sum_tree` | `src/sum_tree/sum_tree.zig` | — (ported directly) | Ported: tree, cursor, filter cursor, keyed edits, find variants. 10 tests, including randomized ones and an exhaustive allocation-failure check. Not yet ported: `TreeMap`/`TreeSet`, `from_par_iter` (no parallel build). |
| `rope` | `src/rope/` | `zed_port/rope.md` | Ported: chunks with bitmaps, `Rope`, `Cursor`, `Chunks` (with `next_line`/`prev_line`), `Bytes`, `Lines`, `Chars`, all conversions and clipping. Zed's own tests are ported, including `test_random_rope`. Limits: clipping uses code-point boundaries, not grapheme boundaries (TODO); there is no parallel building. |
| `clock` | `src/clock/` | — | Ported. `Global` is a plain 8-slot vector, so collaborative replica ids (>= 8) are not supported yet. |
| `text` | `src/text/zed/` | `zed_port/text.md` | Ported for local editing: `Buffer`/`BufferSnapshot`, fragments, `Locator`, anchors, `edit`, transactions and grouping, undo/redo, `UndoMap`, `Patch`, `Topic`/`Subscription`, `edits_since`, `Selection`, `LineEnding`/`LineIndent`. The local-editing tests from `tests.rs` are ported, including `test_random_edits`. Not ported: replication (`apply_ops`, deferred ops, operation log, `wait_for_*`), `rope_for_version`, `edited_ranges_for_transaction`. |
| `editor` display map | `src/editor/display_map/` | `zed_port/display_map.md` | Inlay map and an initial anchored fold map exist. Fold invalidation edits, unfolding, point/chunk/row APIs and later layers remain. Neither map drives the UI. |
| `multi_buffer` | `src/multi_buffer/` | — | Singleton-only foundation; multiple excerpts and diff support remain. |
| `language` (buffer, syntax map) | `src/language/` | — | Chunk types and basic iteration only; language buffers, syntax maps and highlighting remain. |
| `gpui` | Zafi + SDL_GPU (Zid shell) | — | Shell exists. Element, action and keymap semantics are matched through Zafi rather than ported directly. |
| `workspace`, `pane`, `dock`, `status_bar` | `src/app/` | `zed_port/ui_gaps.md` | Partial. See the gap list. |
| `project_panel`, `tab_switcher`, `file_finder`, `command_palette`, `go_to_line`, `search` | `src/app/views/`, `src/app/input/` | `zed_port/ui_gaps.md` | Partial |

The milestone plan (Z0–Z10, with acceptance criteria) is [MILESTONES.md](MILESTONES.md).

## Order of work

1. Data model: `sum_tree` → `rope` → `clock` + `text` (Buffer, Anchor, undo/redo,
   `edits_since`) → replace `editor/document.zig` storage with a `text.Buffer`.
2. Display pipeline: identity Inlay and Fold maps → TabMap → WrapMap (soft wrap) →
   BlockMap. The editor element then paints from `DisplaySnapshot`.
3. UI parity: the P0/P1 checklist in `zed_port/ui_gaps.md`, one focused change each.
4. Then MultiBuffer, the language and syntax map, and the rest of the crates.

Every step is checked against `.ref/zed`, which is updated with `git pull` before each
work session. Adopted decisions are recorded in REFERENCE_NOTES.md.
