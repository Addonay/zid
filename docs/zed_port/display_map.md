# Porting spec: Zed's `DisplayMap` pipeline → zid

Source of truth: `.ref/zed/crates/editor/src/display_map.rs` and
`.ref/zed/crates/editor/src/display_map/*.rs` (Zed reference checkout, GPL,
read-only for us). All `file:line` references below are into that checkout
unless stated otherwise. Everything outside the quotes is our own
paraphrase/spec text; direct quotes are kept short and are there to pin exact
semantics, not to be copied wholesale.

Goal of this document: a Zig programmer should be able to port the display-map
pipeline faithfully — layer by layer, in the right order, against the same
invariants — without re-reading the Rust.

---

## 1. The layer stack

`display_map.rs:8-15` enumerates the layers from bottom to top. Combining that
with the constructor (`display_map.rs:370-417`) and the type chain, the order is:

```
MultiBufferSnapshot                     <- the text being displayed (below all layers)
  -> InlayMap      / InlaySnapshot      (InlayOffset, InlayPoint)
  -> FoldMap       / FoldSnapshot       (FoldOffset, FoldPoint)
  -> TabMap        / TabSnapshot        (TabPoint; edits as TabEdit)
  -> WrapMap       / WrapSnapshot       (WrapPoint, WrapRow; edits as WrapEdit = Edit<WrapRow>)
  -> BlockMap      / BlockSnapshot      (BlockPoint, BlockRow)
  -> DisplaySnapshot                    (BlockSnapshot + highlight maps + crease snapshot + flags)
```

Each layer's snapshot *derefs* to the one below, so a bottom layer pointer can
be used as any upper layer type (`InlaySnapshot: Deref<Target=MultiBufferSnapshot>`
at `inlay_map.rs:47-53`, `FoldSnapshot -> InlaySnapshot` at `fold_map.rs:758-764`,
`TabSnapshot -> FoldSnapshot` at `tab_map.rs:219-225`,
`WrapSnapshot -> TabSnapshot` at `wrap_map.rs:63-69`,
`BlockSnapshot -> WrapSnapshot` at `block_map.rs:84-90`). In zid, model this as
`snapshot.lower` field + comparable `Deref`-style helpers; do **not** inherit.

Also `DisplaySnapshot` exposes decomposed accessors that skip `Deref` and name
the exact layer (`display_map.rs:1616-1650`):

```rust
pub fn wrap_snapshot(&self) -> &WrapSnapshot     // block_snapshot.wrap_snapshot
pub fn tab_snapshot(&self) -> &TabSnapshot       // block_snapshot.wrap_snapshot.tab_snapshot
pub fn fold_snapshot(&self) -> &FoldSnapshot     // ... .fold_snapshot
pub fn inlay_snapshot(&self) -> &InlaySnapshot   // ... .inlay_snapshot
pub fn buffer_snapshot(&self) -> &MultiBufferSnapshot
```

### 1.1 The per-layer pattern

`display_map.rs:19-57` documents a shape every layer follows:

- a `Transform` item type: regions the layer "manages" — either passthrough
  ("Isomorphic") or a slot where the layer injects the new coordinate space;
- a `TransformSummary { input, output }`: `input` summarizes text in the layer
  below's space, `output` summarizes what this layer shows the layer above.
  Passthrough items have `input == output`; injected items have (usually)
  empty/non-zero `input`/`output` respectively;
- newtype coordinate types per layer;
- a `Snapshot` type;
- point/offset conversion APIs (`to_point`, `to_offset`, `*_point_to_*_point`);
  an edit-mapping function `sync(lower_snapshot, edits_in_lower_space)`
  `-> (own_snapshot, edits_in_own_space)`;
- both a `RowInfo` iterator (`InlayBufferRows`, `FoldRows`, `WrapRows`,
  `BlockRows`) and a text `Chunk` iterator (`InlayChunks`, `FoldChunks`,
  `TabChunks`, `WrapChunks`, `BlockChunks`) that wrap the equivalent iterator of
  the layer below.

Important interpretation note from `display_map.rs:47-54`: an `Edit<T>` is
*not* "what changed" — it is a *region to invalidate* (`old` range in the
previous snapshot's space, `new` range in the new snapshot's space). Correctness
only requires regions; producing the tightest regions is a performance concern,
which is why every layer widens/merges edits loosely rather than computing exact
diffs.

### 1.2 The edit pump

`DisplayMap::sync_through_wrap` (`display_map.rs:561-571`) is the canonical
sequence;`DisplayMap::fold` (`display_map.rs:722-737`) and
`update_fold_widths` (`display_map.rs:1259-1287`) show the same seam:

```rust
let tab_size = Self::tab_size(&self.buffer, cx);
let buffer_snapshot = self.buffer.read(cx).snapshot(cx);
let edits = self.buffer_subscription.consume().into_inner();

let (snapshot, edits) = self.inlay_map.sync(buffer_snapshot, edits);
let (snapshot, edits) = self.fold_map.read(snapshot, edits);
let (snapshot, edits) = self.tab_map.sync(snapshot, edits, tab_size);
self.wrap_map.update(cx, |map, cx| map.sync(snapshot, edits, cx)) // -> (WrapSnapshot, WrapPatch)
```

Then `DisplayMap::snapshot` (`display_map.rs:608-671`) hands the
`WrapSnapshot` + `WrapPatch` to `block_map.read(...)` which syncs the block
layer *in place* and returns a `BlockSnapshot`; the result plus highlight maps,
crease snapshot and flags is packaged as a `DisplaySnapshot`.

In zid terms: one `sync_buffer(buffer_snapshot, Vec<Edit<Offset>>)` call must
walk the whole chain; the *only* mutation entry points for fold/block state are
`read`-like sync plus explicit writer operations (`FoldMapWriter::fold`,
`BlockMapWriter::insert/...`), which internally re-run the same sync first
(see `display_map.rs:731-737` for the fold case).

Version counters: every `*Snapshot` has a `version: usize` bumped on every
content-affecting change (e.g. `inlay_map.rs:599/622`, `fold_map.rs:743`,
`tab_map.rs:66-67`, wrap uses the tab version). Consumers (notably the wrap
map's pending-edit queue at `wrap_map.rs:382-390`) compare versions; do keep
them exact.

### 1.3 Coordinate space quick reference

| Field      | Type          | Underlying definition   | Notes                                  |
|------------|---------------|-------------------------|----------------------------------------|
| `MultiBufferOffset` / `Point` | source text | `MultiBufferSnapshot` | lower bound of everything below |
| `InlayOffset(usize)` / `InlayPoint` | after inlay hints inserted | offset & Point in displayed-with-inlays text | full replacement of lower space |
| `FoldOffset(usize)` / `FoldPoint` | after folds replace ranges with placeholders | Point & byte offset | placeholders have no `input` length |
| `TabPoint` | after hard tabs expanded to tab stops | `(row, column)` in displayed chars | no offset type; purely per-row computation |
| `WrapPoint` / `WrapRow(u32)` | after soft wrapping adds visual rows | Point in wrapped text; `WrapRow` = row index | only lower layers' rows map 1:1; wrapped rows have column = indent |
| `BlockPoint` / `BlockRow(u32)` | after blocks insert/replace rows | Point | block lines are pure newline rows, column 0 |
| `DisplayPoint` / `DisplayRow` | final presented text | Point & row | built on BlockMap; used by all editor movement/rendering |

`Point` is `(row: u32, column: u32)`; in all lower layers (inlay/fold/tab/wrap/
block) `column` is measured in chars for `*_chars` summaries, and all
dimension types are `Copy + Ord` on `(row, column)`.

---

## 2. Shared machinery to port first

### 2.1 Sum-tree with dual dimensions

All layers except TabMap are a `SumTree<Transform>` where each `Item` carries an
`Item::Summary` and callers search using "dimensions": types that start at
`zero()` and, as the seek cursor walks items, accumulate the matching summary
field via `add_summary(summary: &TransformSummary)`. Concretely for inlay:

- `InlayOffset` accumulates `summary.output.len` (`inlay_map.rs:160-168`);
- `InlayPoint` accumulates `summary.output.lines` (`inlay_map.rs:189-197`);
- plain `MultiBufferOffset` accumulates `summary.input.len` (`inlay_map.rs:199-207`);
- plain `Point` accumulates `summary.input.lines` (`inlay_map.rs:209-217`).

The dual-dimension cursor `Dimensions<A, B>` (`inlay_map.rs:630-632`) tracks two
 such sums at once (e.g. buffer offset & inlay offset), so code can hold
`cursor.start(): Dimensions<InlayOffset, InlayPoint, MultiBufferOffset>` and
compute overshoot arithmetic like `old_end = cursor.start().1 + (edit.old.end
- cursor.start().0)` (`inlay_map.rs:644-646r`). A faithful Zig port needs a
cursor abstraction exposing, at the bookmark of the current item:

- `start` / `end` dimension tuples (with the same component orders),
- `item()`, `next()`, `next_item()` (peek), `prev()`, `prev_item()`,
- `slice(&target, Bias)` (append items under `target`, advancing),
- `seek(&target, Bias)` / `seek_forward` (forward-only hint),
- `suffix()` (append everything left).

Zed's `sum_tree` crate semantics: `seek(target, Bias::Left)` positions at the
first leaf whose end-summary is strictly greater than... reached target biased
left/right — the whole pipeline leans on standard monotone seek with bias; port
those exact semantics (see existing usage patterns in `inlay_map.rs` tests).
`sum_tree::Bias` is `Left | Right` and is used *everywhere* (anchor insertion,
clip, conversions); treat it as a core enum in zid `src/core`.

### 2.2 Summary data types

`MBTextSummary` (`crates/multi_buffer/src/multi_buffer.rs:933-953`) is the
rich text summary used by Inlay and Fold layers. Fields: `len`
(byte length), `chars`, `len_utf16`, `lines: Point` ("point after the last
byte", i.e. `(line_count, last_line_len)`), `first_line_chars`,
`last_line_chars`, `last_line_len_utf16`, `longest_row`, `longest_row_chars`.
Addition is field-wise min/max: `longest_row` takes the max by chars
(standard `TextSummary` semantics; port the same combine rules).

Tab and Wrap layers use a smaller summary, `tab_map::TextSummary`
(`tab_map.rs:631-638`):

```rust
pub struct TextSummary {
    pub lines: Point,          // (new_row_count, last_row_column)
    pub first_line_chars: u32,
    pub last_line_chars: u32,
    pub longest_row: u32,
    pub longest_row_chars: u32,
}
```

Built `From<&str>` via the text crate's `TextSummary` (tab_map.rs:640-645).

Zid currently tracks rows/columns with `u32` extents in `src/text`; the
display-map port needs at least `first_line_chars`/`last_line_chars` and a
`(row, col)` summary pair — plan the zig `TextSummary` type accordingly. We do
**not** need `len_utf16` in zid until UTF-16 selects are ported, but design
structs with it so anchoring later is painless.

### 2.3 Chunk iteration

The `Chunk` type in the language/text crate carries, besides `text: &str`:

- `chars: u128` bitmap: bit `i` set iff a char *boundary* at byte `i`;
- `tabs: u128` bitmap: bit `i` set iff byte `i` starts a tab character;
- `newlines: u128` bitmap (newline positions);
- flags like `is_tab`, `is_inlay`, `syntax_highlight_id`, `highlight_style`,
  `diagnostic_severity`, `renderer`, `measured_width`, `is_unnecessary`,
  `underline`.

The u128 mask is what lets layers split chunks cheaply and recombine bitmaps:
`inlay_map.rs:295-312` shows the canonical split idiom (compute `split_index`
by `ceil_char_boundary(desired_bytes)`, then `mask = (1 << split) - 1`, prefix
keeps `chunk.chars & mask`, suffix keeps `chunk.chars >> split`, etc). The
tab layer relies on the `tabs` bitmap to find tab bytes after an edit
(`tab_map.rs:116-137`); the wrap layer burns whole lines through the mask-free
`LineFragmentBuilder` path. In zid, port `Chunk` with these u128 bitmaps as a
prerequisite (`zid/src/text` already has similar bitmaps for the display layer;
align definitions there).

### 2.4 `push_isomorphic` (shared helper)

Used by all transform-tree layers (`fold_map.rs:1134-1158`, inlay equivalent at
`inlay_map.rs:~505`): merge the summary into the last transform **only if** it
is passthrough (`!is_fold()` / `!is_wrap()` / `block.is_none()`); otherwise push
a fresh passthrough transform. Port once, parameterize by an "is passthrough"
predicate.

---

## 3. Layer-by-layer spec

### 3.1 InlayMap (`display_map/inlay_map.rs`, 2706 lines)

**State.** `InlayMap { snapshot: InlaySnapshot, inlays: Vec<Inlay> }`
(`inlay_map.rs:35-38`). `InlaySnapshot { buffer: MultiBufferSnapshot,
transforms: SumTree<Transform>, version: usize }` (`inlay_map.rs:41-45`).

**Transform & summary.** (`inlay_map.rs:55-102`)

```rust
enum Transform {
    Isomorphic(MBTextSummary),
    Inlay(Inlay),
}
struct TransformSummary {   // ContextLessSummary
    input: MBTextSummary,   // text below (before inlays)
    output: MBTextSummary,  // text shown above (after inlays)
}
```

- `Transform::Isomorphic(s).summary()` = `{ input: s, output: s }`.
- `Transform::Inlay(inlay).summary()` = `{ input: default, output:
  inlay.text().summary() }` — **empty input**, i.e. injected text occupies no
  lower-layer space.
- `add_summary` (`inlay_map.rs:98-101`): `self.input += other.input; self.output
  += other.output;` (component-wise).
- `has_inlays()` ⇔ `input.len != output.len` (`inlay_map.rs:88-91`).

**sync (`inlay_map.rs:575-728`).** Signature:
`sync(&mut self, buffer_snapshot: MultiBufferSnapshot, buffer_edits:
Vec<Edit<MultiBufferOffset>>) -> (InlaySnapshot, Vec<Edit<InlayOffset>>)`.

Three branches, in order:

1. **No edits, but buffer structurally changed** — if
   `trailing_excerpt_update_count` differs (new trailing excerpt appeared, e.g.
   empty trailing excerpt replaced), synthesize a zero-width edit at EOF
   (`inlay_map.rs:582-590`) and fall through to the general path. If edits are
   empty after that: bump `version` when `edit_count`,
   `non_text_state_update_count`, or `trailing_excerpt_update_count` changed;
   swap in the new buffer snapshot; return unchanged transforms and no edits
   (`inlay_map.rs:592-603`).
2. **No inlays exist and the transform tree's summary has none**
   (`inlay_map.rs:604-627`) — rebuild one `Isomorphic` over the full
   `buffer_snapshot.text_summary()` and forward each buffer edit to
   `InlayOffset` space verbatim (`old/new` offsets shift by nothing). This is
   the identity-pass-through port shortcut mentioned later.
3. **General path** (`inlay_map.rs:628-727`). Per buffer edit, walking a
   `Dimensions<MultiBufferOffset, InlayOffset>` cursor over the *old* tree:
   - append untouched prefix `cursor.slice(&edit.old.start, Bias::Left)`;
   - if the item ending exactly at the edit start is `Isomorphic`, carry it over
     and advance (`inlay_map.rs:636-641`);
   - compute inlay-space old range: `old_start = cursor.start().1 +
     (edit.old.start - cursor.start().0)`, then
     `cursor.seek(edit.old.end, Bias::Right)` and same formula for `old_end`
     (`inlay_map.rs:644-646`);
   - push new isomorphic text up to `edit.new.start` from the *new buffer*;
     record `new_start = output-so-far` (`inlay_map.rs:648-655`);
   - re-insert inlays whose position is valid and whose buffer offset falls in
     `[edit.new.start, edit.new.end]`, each preceded by the isomorphic gap
     since the previous insertion point (`inlay_map.rs:657-684`); binary search
     uses `probe.position.to_offset(...).cmp(&edit.new.start).then(Greater)` —
     i.e. Left-biased inlays before the position are included;
   - push isomorphic text from last inlay to `edit.new.end`; emit the mapped
     edit `{ old: old_start..old_end, new: new_start..new_end }`
     (`inlay_map.rs:686-696`);
   - if the next edit doesn't intersect the current old transform, push its
     remainder and `cursor.next()` (`inlay_map.rs:698-712`);
   - finish with `cursor.suffix()`, ensure the tree is non-empty (an empty
     isomorphic transform is pushed if needed, `inlay_map.rs:716-718`), assign
     `snapshot.transforms`, `version += 1`, swap buffer snapshot.

**splice (`inlay_map.rs:731-779`).** Remove inlays by id, skip inserting empty
inlays, keep `inlays` sorted by `(position, position.bias()` ties → *Less*, so
equal-position Right-biased inlay sorts before a later one; compare with
`fold`'s `Greater` usage; describe per file), collect the offsets of all
touches, convert each to a zero-width point edit `{ old: o..o, new: o..o }`,
then delegate to `sync(buffer.clone(), edits)` so one code path does the tree
rebuild.

**Conversions (`InlaySnapshot`).**

- `to_point(InlayOffset) -> InlayPoint` (`inlay_map.rs:857-878`): find by
  `Dimensions<InlayOffset, InlayPoint, MultiBufferOffset>` `Bias::Right`;
  inside `Isomorphic`: map the byte overshoot through the buffer
  (`offset_to_point`); inside `Inlay`: map overshoot through the inlay test
  (`inlay.text().offset_to_point`); `None` (past end) → `max_point()`.
- `to_offset(InlayPoint) -> InlayOffset` (`inlay_map.rs:891-910`): mirror image.
- `to_buffer_point(InlayPoint) -> Point` (`inlay_map.rs:912-924`): inside an
  Inlay transform, the answer is the transform *start* row/col
  (`start.1`) — inlay interior has no buffer position.
- `to_buffer_offset(InlayOffset)` (`inlay_map.rs:926-938`): same start-snapping.
- `to_inlay_offset(MultiBufferOffset) -> InlayOffset` (`inlay_map.rs:941-975`):
  walks the tree skipping Left-biased inlays at the target, stopping at the
  first Right-biased one; if the offset lands exactly at the end of an
  Isomorphic item, walk `next_item()` over trailing Right-biased inlays.
- `to_inlay_point(Point)` / `point_to_*` streaming: `InlayPointCursor`
  (`inlay_map.rs:1355-...`) wraps `Dimensions<Point, InlayPoint>` for repeated
  forward mapping; `BufferOffsetToInlayPointCursor` (`inlay_map.rs:1409-...`)
  for offset-based mapping.
- `buffer_offset_to_inlay_ranges(range)` (`inlay_map.rs:986-1025`): yields the
  sub-ranges of *buffer text only* inside a lower range (skips inlay interiors);
  used to translate highlight ranges when inlays exist.

**clip_point (`inlay_map.rs:1046-1136`).** This is the subtlest function in the
layer; port its state machine exactly:

- Seek `Bias::Left` to the point.
- If inside an `Isomorphic` run, first handle the boundary adjacency rules with
  a neighboring `Inlay` item:
  - point == cursor start and previous item is a Right-biased inlay → the
    point is legitimately "inside" that inlay's left edge → return unchanged;
  - otherwise, if bias Left and adjacent inlay, back the cursor up; if bias
    Right, advance: `point.0 += (1, 0)` when the current isomorphic run starts
    at column 0 (i.e. `first_line_chars == 0`) else `+= (0, 1)`;
  - point == cursor end, with next item a Left-biased inlay → return unchanged;
  - other adjustments move one char to the left End (`point.column - 1`), or to
    the previous row's end (`row -= 1; column = line_len(row)` from the
    buffer);
  - interior point: clip the buffer-space point via
    `self.buffer.clip_point(point, bias)` and repeat from the clipped position
    if it changed (the loop re-seeks implicitly because `point` was updated).
- Inside an `Inlay` transform: if the point sits exactly at the transform start
  and the inlay is Right-biased (or at end with Left-biased), the bias-alpha
  neighbor decides (walk `prev/next_item()` to see if the *other* inlay at the
  built point is the compatible edge); if it doesn't line up, move the point to
  the transform start (bias Left) or to the start of the next transform
  (bias Right) and continue.
- On `None` the loop inverts bias and marches to the other end.

Translate this verbatim; there are tests (`test_clip_point` in
`display_map.rs` tests, and `inlay_map.rs:~1000` variants) that will catch any
shortcut.

**Rows & chunks.** `InlayBufferRows` (`inlay_map.rs:220-225`) wraps
`MultiBufferRows` and yields `RowInfo` per inlay row; `InlayChunks` /
`InlayChunk` (`inlay_map.rs:227-267`) walk the transform cursor and either split
buffer chunks at transform boundaries (the u128-idiom above) or emit the inlay
text as an `InlayChunk { chunk, renderer: None }`; inlay highlight styles
(edit-prediction, hint) are attached from `highlights.inlay_highlights`
(`inlay_map.rs:325-345`).

### 3.2 FoldMap (`display_map/fold_map.rs`, 2570 lines)

**State.** `FoldMap { snapshot: FoldSnapshot, next_fold_id: FoldId }`
(`fold_map.rs:360-363`). Snapshot:
`FoldSnapshot { inlay_snapshot, transforms: SumTree<Transform>, folds:
SumTree<Fold>, fold_metadata_by_id: TreeMap<FoldId, FoldMetadata>, version }`
(`fold_map.rs:749-756`) — Deref to `InlaySnapshot`.

`Fold { id: FoldId, range: FoldRange(Range<Anchor>), placeholder:
FoldPlaceholder }` (`fold_map.rs:1306-1314`). Note folds are stored in
*anchor* space sorted by `FoldRange` (a summary-based SeekTarget order,
`fold_map.rs:1357-1441` builds `FoldSummary` from `min_start/max_end` anchors)
with a *buffer-context* `add_summary` (`fold_map.rs:1384`).

**Transform & summary.** (`fold_map.rs:1253-1295`)

```rust
struct Transform {
    summary: TransformSummary,
    placeholder: Option<TransformPlaceholder>,  // Some = fold
}
struct TransformPlaceholder {
    text: SharedString,   // ellipsis or language-provided text
    chars: u128,          // char boundary bitmap of `text`
    renderer: ChunkRenderer,
}
struct TransformSummary { output: MBTextSummary, input: MBTextSummary }
```

`is_fold()` ⇔ `placeholder.is_some()`. Same field-wise `add_summary`.

**FoldPlaceholder (`fold_map.rs:26-103`).** Fields: `render: Arc<Fn(FoldId,
Range<Anchor>, &mut App) -> AnyElement>`, `constrain_width: bool` (clamp
element to measured ellipsis width), `merge_adjacent: bool` (merge with an
adjacent fold of same flag), `type_tag: Option<TypeId>` (used when removing
overlapping fold sets), `collapsed_text: Option<SharedString>` (override the
default `⋯`; consumed at sync time, `fold_map.rs:573-579`). Equality is
pointer-identity on `render` + flags. Zid will model `render` as a
`RenderFold` function pointer; text substitution uses `collapsed_text` or
constant `"⋯"` (`fold_map.rs:573-574` names it `const ELLIPSIS`).

**fold() — the writer op (`fold_map.rs:168-232`).** `FoldMapWriter::fold`
converts each incoming range `(Range<T: ToOffset>, placeholder)` to a buffer
offset range (skipping empty ranges and ranges that cross an excerpt boundary,
`fold_map.rs:179-195`), converts anchors via `anchor_after(start) ..
anchor_before(end)`, assigns sequential `FoldId`s, records
`fold_metadata_by_id[id] = FoldMetadata { range, width: None }`, and *replaces*
the folds tree with a rebuilt tree appending each new fold in sorted position
(`fold_map.rs:212-230`, using
`fold_range.cmp` order). Note: within a single call, duplicates and
overlaps are allowed and resolved only at *sync* time (the sync merges
overlaps with a "last one wins" merge policy at `fold_map.rs:554-565`).

**sync (`fold_map.rs:456-747`).** `sync(&mut self, inlay_snapshot,
inlay_edits: Vec<InlayEdit>) -> Vec<FoldEdit>` (note: not recursive; folds are
updated *inside* this pass). Structure:

1. Empty-edits fast path: bump version if inlay snapshot version changed;
   swap in incoming snapshot (`fold_map.rs:461-466`).
2. Otherwise, per inlay edit (walking old transforms cursor by `InlayOffset`):
   - Pre-merge an isomorphic transform that immediately precedes the edit into
     the tail of `new_transforms` if the item at the cursor is also isomorphic,
     avoiding zero-length splits (`fold_map.rs:474-487`).
   - Move the cursor to `edit.old.start` (Bias Left) applying the slice, then
     adjust: `edit.new.start -= edit.old.start - cursor.start().0` (i.e. edit
     boundaries snap to transform boundaries) and set
     `edit.old.start = cursor.start().0` (`fold_map.rs:488-490`).
   - Seek past `edit.old.end` (`Bias::Right`, then one more) and *widen the
     edit to cover subsequent inlay edits that overlap it*, accumulating
     `delta = sum(new_len - old_len)` of merged edits, recomputing
     `edit.new.end = edit.new.start + edit.old_len + delta`
     (`fold_map.rs:492-519`).
3. Convert `edit.new.start` into buffer space and open a `folds_cursor`
   (`seek(&fold_snapshot.to_buffer_offset(edit.new.start), Bias::Left)`)
   over the *new* fold tree, mapping each fold to its inlay-offset range via
   `to_inlay_offset` per fold anchor (`fold_map.rs:521-543`).
4. While `fold_range.start < edit.new.end`:
   - merge following folds while they overlap (`next.start < cur.end`) or
     vanish into adjacency with equal `merge_adjacent` placeholders; extend
     `fold_range.end` to the maximum end (`fold_map.rs:554-565`).
   - push `Isomorphic` for the gap from tree-so-far's input end to
     `fold_range.start` (`fold_map.rs:566-570`).
   - push the fold `Transform`:
     `output = MBTextSummary::from(placeholder_text)`,
     `input = inlay_snapshot.text_summary_for_range(fold_range)` and a
     `TransformPlaceholder { text, chars: char-boundary bitmap, renderer:
     ChunkRenderer { id: ChunkRendererId::Fold(fold.id), render:
     placeholder.render(fold_id, fold.range.0, cx), constrain_width,
     measured_width: self.snapshot.fold_width(&fold.id) } }`
     (`fold_map.rs:572-612`). `fold_width` returns the measured width recorded
     by `update_fold_widths` (later).
   - continue until folds_cursor is past the edit; then push trailing
     isomorphic text to `edit.new.end` (`fold_map.rs:616-621`).
5. Append `cursor.suffix()`; guarantee non-empty tree
   (`fold_map.rs:624-628`).
6. Compute fold edits out (`fold_map.rs:632-739`):
   - walk old tree (`Dimensions<InlayOffset, FoldOffset>`) and the *new tree*
     simultaneously, widening each edit in both spaces outward so that it does
     not start or end inside a fold transform ("pull" backwards when the
     containing transform is a fold; "extension" forwards likewise), merging
     with the previous widened edit when pulled into it (`fold_map.rs:643-715`);
   - map each widened edit through old/new cursors to FoldOffset ranges
     (`fold_map.rs:717-736`) and `consolidate_fold_edits` them
     (`fold_map.rs:1229-1251`).
7. Commit: `snapshot.transforms = new_transforms; snapshot.inlay_snapshot =
   incoming; snapshot.version += 1` (`fold_map.rs:741-744`).

**Conversions.**

- `FoldPoint::to_inlay_point(snapshot)` (`fold_map.rs:131-137`): find by
  `Dimensions<FoldPoint, InlayPoint>` `Bias::Right`; overshoot in fold space
  added in inlay space. Works because fold placeholders occupy zero
  *input* length, so `InlayPoint.start() + overshoot` may cross the start of a
  placeholder transform harmlessly in inlay space.
- `FoldPoint::to_offset(snapshot)` (`fold_map.rs:140-155`): find by
  `Dimensions<FoldPoint, TransformSummary>`; offsets add the output length of
  the prefix transforms plus the fold-internal offset; asserts the transform
  under the point is not a fold (`assert!(transform.placeholder.is_none())`).
- `to_fold_point(InlayPoint, bias) -> FoldPoint` (`fold_map.rs:863-877`):
  - if the found transform is a fold: return its *start* fold point when
    `bias == Left` **or** `point == start.0` in inlay space (so a point exactly
    at a fold's left edge stays left of the placeholder even with Right bias);
    otherwise its *end* fold point;
  - else overshoot, clamped to `min(start.1.0 + overshoot, end.1.0)`.
- `FoldPointCursor` (`fold_map.rs:1103-1132`): streaming variant of the above
  with the same rules; also `reset()` to re-seek backwards by restarting the
  cursor.
- `len()` → `FoldOffset(output.len)`; `line_len(row)` computed from
  `FoldPoint.to_offset` of `(row,0)` and (row+1, 0) minus 1
  (`fold_map.rs:893-901`); `max_point()` (`fold_map.rs:927-929`);
  `longest_row` from summary (`fold_map.rs:932-934`).

**clip_point (`fold_map.rs:1079-1100`).** Find the transform under the point:

- fold transform: return `transform_start` when `point == start` or bias is
  Left; else return `end.0.0` (the fold's right edge);
- passthrough: `overshoot = point - transform_start`, clip
  `inlay_point = start.1 + overshoot` through the inlay snapshot, then map
  back; return `start.0.0 + (clipped_inlay_point - start.1).0`;
- `None` → `max_point()`.

**Row/chunk/buffer iteration.** `FoldRows` (`fold_map.rs:1441-...`) walks
transforms and the inlay snapshot's `row_infos` simultaneously, and `RowInfo`
for fold rows preserves `buffer_row` of the *displayed* row when the row is not
inside a fold. `FoldChunks` (`fold_map.rs:1566-...`) runs `inlay_snapshot.chunks
..` for passthrough segments and manually emits fold placeholder chunks with
`text = placeholder.text`, a `ChunkRenderer` reference and correct `chars`
bitmap; `FoldChunks.seek` (`fold_map.rs:~1650`) handles re-seek similar to
`InlayChunks`; `ChunkRenderer` (`fold_map.rs:1525-1540`) carries
`id: ChunkRendererId::Fold(FoldId)` and the render closure plus the lazy
`measured_width: Option<Pixels>`. `ChunkRendererId` is the enum{
`Fold(FoldId)` for fold placeholders (later `Comment(CommentId)` etc appear in
`display_map.rs` re-exports) — port the variant set zid needs (initially just
`Fold(fold_id)`).

**Buffer/fold queries.**

- `is_inlay_offset_folded(offset)` (`fold_map.rs:771-776`): find transform by
  `InlayOffset`, check `placeholder.is_some()`.
- `folds_in_range(range)` (`fold_map.rs:937-949`): via a filter cursor over
  `SumTree<Fold>` using only `min_start/max_end` summaries against the query
  range converted to anchors (`intersecting_folds`, `fold_map.rs:1160-1181`).
- `is_line_folded(buffer_row)` (`fold_map.rs:962-988`): convert row start to
  InlayPoint, walk transforms per row until a placeholder transform covering
  the whole row is found.
- `intersects_fold(offset)` (`fold_map.rs:952-959`).
- `placeholder_range_at(FoldPoint)` (`fold_map.rs:990-996`).
- `chunks(...)`/`chars_at`/`chunks_at` (`fold_map.rs:999-1066`).
- `has_folds()` = `!folds.is_empty()` (`fold_map.rs:802-805`).
- `update_fold_widths(widths)` (`fold_map.rs:...` `display_map.rs:1259-1287`):
  after the fold placeholder metal-elements are measured on screen,
  `DisplayMap::update_fold_widths` sets `FoldMetadata.width` and then pipes the
  resulting fold-map edit through tab→wrap→block again so downstream layers re-
  lay. In zid this is the "re-render after glyph measurement" trigger.

### 3.3 TabMap (`display_map/tab_map.rs`, 2198 lines)

The *only* layer without a transform SumTree: because tab expansion is local to
a row, TabMap converts points on demand, walking fold chunks of the row. Keep
this design (do not "fix" it into a second tree): it keeps sync O(edits) and
makes `fold_point_to_tab_point` O(row).

**State.** `TabMap(TabSnapshot)` (`tab_map.rs:21`); snapshot fields:
`fold_snapshot`, `tab_size: NonZeroU32`,
`max_expansion_column: u32`, `version` (`tab_map.rs:210-217`).
`max_expansion_column` is a constant `MAX_EXPANSION_COLUMN` (see
`tab_map.rs` namespace tests use `set_max_expansion_column`, i.e. tests vary
it); the shipped value is the column beyond which tabs no longer expand
(default constant visible right above its uses; grep `MAX_EXPANSION_COLUMN =
` to copy the exact number into zid — we did not change this constant in the
checkout).

**Tab expansion rules.**

- The display width of the `i`-th tab on a row (0-indexed) is computed from
  `expanded_chars` (display chars so far, tab expansion included). Given
  `tab_size` `t` and current expanded column `e` (chars, exclusive of the tab):
  `tab_len = t - ((e_t - 1) % t)` where `e_t = tab_stop.char_offset +
  expanded_tab_len - tab_count` (see both `expand_tabs` `tab_map.rs:441-477`
  and `collapse_tabs` `tab_map.rs:480-533` — the mu formula appears in both,
  at `tab_map.rs:459` and `tab_map.rs:495`);
- A tab only expands if the *displayed* column where it occurs is <
  `max_expansion_column`; a tab after that renders as a single space.
  `max_expansion_column` defaults to `u32::MAX`-ish (every tab expands); tests
  set smaller values.
- `expand_tabs(cursor, tab_count, expanded_tab_len, column)` (`tab_map.rs:441-477`):
  from the cursor (`TabStopCursor` over fold chunks of this row), for each tab
  stop before `min(column, max_expansion_column)` add `tab_len` as above and
  charge `tab_count`/`expanded_tab_len`; the final result adds the run of
  normal chars past the last tab: `expanded_bytes + column -
  collapsed_bytes`. Both `tab_size` clamping to `MAX_TABS` (max of
  `u128`-bitmask chunks, `tab_map.rs:15-16`) and the `column.min(...)` clamp
  matter for porting.
- `collapse_tabs(cursor, column, bias)` (`tab_map.rs:480-533`) inverts this,
  returning `(collapsed_column, expanded_char_column, to_next_stop)`:
  `to_next_stop` > 0 means the query point sits *inside* an expanded tab's
  padding; bias Left puts it at `cursor.byte_offset - 1` with the overshoot
  recorded; bias Right lands on the tab byte itself (`cursor.byte_offset()`,
  no overshoot).

The per-row conversion entry points:
`fold_point_to_tab_point(FoldPoint) -> TabPoint` (`tab_map.rs:378-383`) creates
fresh `TabStopCursor` from `fold_snapshot.chunks_at(row_start)`; `tab_point_to
_fold_point(TabPoint, bias) -> (FoldPoint, expanded_char_column, to_next_stop)`
(`tab_map.rs:399-414`); `point_to_tab_point(Point, bias)` composes Inlay →
Fold → Tab for buffer-space points (`tab_map.rs:422-426`); and
`tab_point_to_point(TabPoint, bias) -> Point` (`tab_map.rs:429-435`).
`buffer_row_to_tab_row` maps row starts (`tab_map.rs:416-419`).

`TabPointCursor` (`tab_map.rs:540-600`) is a stateful, forward-only cursor with
`needs_seek` reset; it advances row starts when the next query row is ahead
(`cursor.advance_rows(...)`), resuming the tab scan cheaply; used by sync and
chunk iteration. `MAX_ROW_SCAN_CHUNKS` bounds the row skip.

**sync (`tab_map.rs:42-206`).** `sync(&mut self, fold_snapshot, fold_edits:
Vec<FoldEdit>, tab_size: NonZeroU32) -> (TabSnapshot, Vec<TabEdit>)`.

1. Tab-size change (regardless of edits): rewrite everything as a single
   whole-document edit `(zero..old_max) -> (zero..new_max)`, bump version
   (`tab_map.rs:50-62`). Zid note: also recompute `soft_wrap_indent`'s
   `IndentAdjustment` downstream because the wrap layer depends on `tab_size`
   (`wrap_map.rs:281-283`).
2. Otherwise: for each fold edit, widen its end to include the next tab and
   any tab that crossed the max-expansion boundary because of the edit
   (`tab_map.rs:77-155`). Precisely, per edit, scanning old fold chunks
   *forward* from `edit.old.end` (reusing one `FoldChunks` across edits via
   `seek(fold_edit.old.end..old_fold_len)`):
   - `first_tab_offset` = first tab byte ≥ `old_end`;
   - for each tab after that at offset `o` (column `old_end.column + o` vs
     `new_end.column + o`): if `old_expanded ⇔ old_col < max_expansion_column`
     differs from `new_expanded`, record the *last* such `o`;
     - stops at the first row end (`chunk.newlines != 0`), and also stops once
       both old and new columns exceed max_expansion_column and no boundary
       transition was seen (`tab_map.rs:132-148`).
   - extend both edits' `end` by `last_tab_with_changed_expansion_offset`.
     `+1` byte (`tab_map.rs:151-154`).
   The `chunk.tabs`/`chunk.newlines` bitmaps drive the scan
   (`tab_map.rs:118-137`).
3. Merge overlapping fold edits (`tab_map.rs:167-187`); map each through the
   old/new FoldSnapshots using `TabPointCursor`s
   (`old_cursor.map(old_start)...) into TabPoint ranges
   (`tab_map.rs:188-203`); commit snapshot with the (possibly new) tab_size,
   keeping `max_expansion_column` (`tab_map.rs:158-163`).

**`TabSnapshot` API.** `max_point()` maps fold `max_point` forward
(`tab_map.rs:365-367`; note you cannot derive it from the summary — the sum
tree doesn't exist). `line_len(row)` via fold line_len mapped forward
(`tab_map.rs:234-243`). `text_summary_for_range(TabPoint..TabPoint)`
(`tab_map.rs:251-298`): map the range back to fold points, sum the fold text
summary for lines (which preserves `longest_row` from the input), and compute
`first_line_chars`/`last_line_chars` by counting chunks before `\n`
(really by summing expanded tab lengths) — see `tab_map.rs:263-289` where the
first/last line char counts are recomputed in the *expanded* space.

**chunks (`tab_map.rs:301-342`).** `TabChunks` walks fold chunks; when the
start point sits inside a leading expanded tab
(`to_next_stop > 0`), a synthetic chunk is used — all-space chars from the
`SPACES` table, `is_tab: true`, `chars` bitmap set to
`u128::MAX.unbounded_shr(u128::BITS - to_next_stop)` — and iteration then
proceeds via the `TabStopCursor` per row. The `inside_leading_tab` flag marks
that state. In zid, port this as a small iterator over `(String-ish chunk)`
with re-usable buffers (Rust slices borrowed from `SPACES`; zid can use
`&'static [u8]` constants).

**clip_point (`tab_map.rs:370-375`).** Round-trips:
`fold_point_to_tab_point(fold_snapshot.clip_point(tab_point_to_fold_point(p,
bias).0, bias))`. Since tab expansion never removes rows, exact bias handling
comes from the fold layer.

### 3.4 WrapMap (`display_map/wrap_map.rs`, 2131 lines)

The most infrastructure-heavy layer because wrapping depends on text shaping.
Structure differences from other layers:

- Transform is a *struct with two constructors* (`wrap_map.rs:72-87`):

  ```rust
  struct Transform { summary: TransformSummary, display_text: Option<&'static str> }
  struct TransformSummary { input: TextSummary, output: TextSummary } // tab_text vs wrapped text
  ```

  `Transform::isomorphic(summary)`: `input = output = summary`.
  `Transform::wrap(next_indent)` creates output with `lines = (1, next_indent)`
  and zero input (the shape of a virtual line break; `transform.soft_wrap
  _indent` reads `output.lines.column` as the indent, `wrap_map.rs:916-929`).
  `is_isomorphic()` distinguishes them (equivalent to
  `summary.input.lines == summary.output.lines`; note the incoming summary has
  `input` = tab-space lines, `output` = display lines). `has_wraps()` ⇔ those
  two `lines` differ.

- `WrapMap` (an *entity*) buffers edits while rewrapping:
  `pending_edits: VecDeque<(TabSnapshot, Vec<TabEdit>)>`,
  `interpolated_edits: WrapPatch`, `edits_since_sync: WrapPatch`,
  `wrap_width: Option<Pixels>`, `soft_wrap_indent: SoftWrapIndent`,
  `background_task: Option<Task<()>>`, `font_with_size: (Font, Pixels)`
  (`wrap_map.rs:45-54`).
- `WrapSnapshot { tab_snapshot, transforms: SumTree<Transform>, interpolated:
  bool }` (`wrap_map.rs:57-69`); `interpolated == true` means "row counts are
  correct (the transforms were re-interpolated against a new tab snapshot) but
  wrapping inside rows is stale" — an editor must re-read before trusting
  column values, and `is_rewrapping() = background_task.is_some() ||
  (wrap_width.is_some() && interpolated)` (`wrap_map.rs:210-212`).

**sync (`wrap_map.rs:215-239`).**

- With a wrap width: push `(tab_snapshot, edits)` onto `pending_edits` and call
  `flush_edits(cx)`.
- Without a wrap width: `edits_since_sync = edits_since_sync.compose(
  snapshot.interpolate(tab_snapshot, &edits))` — i.e. the snapshot just
  inherits the tab snapshot's rows undisturbed (identity transform; `interpolated
  = false` afterwards because the map is up to date).
- Return `(snapshot.clone(), take(edits_since_sync))`.

**rewrap (`wrap_map.rs:286-376`).** Triggered by `set_wrap_width`,
`set_font_with_size`, `set_soft_wrap_indent`:
tear down the background task, reset both edit buffers, then:

- No width: rebuild one isomorphic transform over the tab snapshot's
  `text_summary()` (a no-wrap layout) and emit a whole-document
  `WrapEdit(old_rows..new_rows)` (`wrap_map.rs:360-375`).
- With width: snapshot the tab layer; if `total_rows < WRAP_YIELD_ROW_INTERVAL`
  (const = 100, `wrap_map.rs:36`), run `update(...)` *synchronously*
  (`block_on`, `wrap_map.rs:308-317`); else run it in the background but
  `block_with_timeout(5ms)` first — if the timeout hits, the partial result is
  dropped, `background_task` takes over, and, *crucially*, the wrap map keeps
  answering reads from the previous (now stale but valid) snapshot while
  composing `interpolated_edits` backlog when the task lands
  (`wrap_map.rs:334-358`).

**flush_edits (`wrap_map.rs:379-494`).** Drains pending edits older than the
current snapshot version (`wrap_map.rs:382-390`). If rewrapping is in flight,
the pending edits are turned into *interpolated* `WrapPatch`es
(`snapshot.interpolate(tab_snapshot, edits)`) so readers get correct row counts
+ gross row extents immediately; otherwise a single background `update` pass
runs the real wrapping for the batch (`wrap_map.rs:396-476`, with
`block_with_timeout(1ms)`; > 1ms → background with interpolation meanwhile).

**interpolate (`wrap_map.rs:513-581`).** Re-bases the transform tree against a
new tab snapshot *without re-shaping*: fields treated as isomorphic segments
(uses `new_tab_snapshot.text_summary_for_range`), leaving existing wrap
transforms elsewhere intact; then `compute_edits(tab_edits, self)` snapshots
the row-level edits. Fast path when no wraps exist yet: one isomorphic
transform over the new snapshot (`wrap_map.rs:517-522`).

**update (`wrap_map.rs:584-753`).** The actual wrapping:

1. Merge tab edits into row edits: contiguous tab-edit rows become `RowEdit {
   old_rows, new_rows}` ranges (`wrap_map.rs:601-620`).
2. For each row range, open `new_tab_snapshot.chunks(new_rows.start .. max_point)`
   and per row:
   - assemble a `String line` plus a `Vec<LineFragment>` — invisible/`C0` chars
     get replaced by *width-measured placeholder fragments* via
     `LineFragmentBuilder` (`wrap_map.rs:99-145`), using cached replacement
     widths per replacement char (so the wrapper sees them as single-width
     glyphs matching what will be drawn);
   - `for boundary in line_wrapper.wrap_line(&line_fragments, wrap_width,
     indent_adjustment)` (`wrap_map.rs:684-691`, quote):

     ```rust
     for boundary in line_wrapper.wrap_line(&line_fragments, wrap_width, indent_adjustment)
     {
         let wrapped = &line[prev_boundary_ix..boundary.ix];
         push_isomorphic(&mut edit_transforms, TextSummary::from(wrapped));
         edit_transforms.push(Transform::wrap(boundary.next_indent));
         prev_boundary_ix = boundary.ix;
     }
     ```

     i.e. each `boundary` splits the line: the text before it is an isomorphic
     transform (with correct `first_line_chars`, etc.), and the wrap itself is
     a `Transform::wrap(next_indent)` whose `output.lines = (1, next_indent)`.
   - yield to the scheduler every 100 rows (`wrap_map.rs:702-704`);
   - `push_or_extend` merges with a preceding isomorphic transform when
     possible (`wrap_map.rs:535-541` uses `push_or_extend`, e.g. at
     `new_transforms.push_or_extend(Transform::isomorphic(summary))`).
3. Replace `self.transforms`, set `interpolated = false`, and compute the
   outgoing `WrapPatch` (`wrap_map.rs:743-752`).

**compute_edits (`wrap_map.rs:756-790`).** For each tab edit: widen
`old.start` to column 0 and `old.end` 1 row forward (same for new), then map
through the old and new transform cursors to `WrapRow` ranges and
`consolidate_wrap_edits` them. In other words, wrap edits are at row
granularity by construction.

**Conversions (`WrapSnapshot`).**

- `to_tab_point(WrapPoint) -> TabPoint` (`wrap_map.rs:960-969`): find by
  `Dimensions<WrapPoint, TabPoint>` `Bias::Right`; inside an isomorphic
  transform, overshoot in wrap space added to the tab point; inside a wrap
  transform, the point is the wrap's start (tab columns don't progress inside
  a virtual break).
- `tab_point_to_wrap_point(TabPoint) -> WrapPoint` (`wrap_map.rs:983-988`):
  find by `Dimensions<TabPoint, WrapPoint>`; overshoot added in wrap space —
  meaning a tab point that lands *inside* a wrapped segment of a row gets
  pushed to the nearest wrap-transformation boundary. This is exact, there is
  no interior logic needed.
- `to_point(WrapPoint, bias) -> Point` (`wrap_map.rs:972-975`) and
  `make_wrap_point(Point, bias) -> WrapPoint` (`wrap_map.rs:978-980`) chain
  through the tab layer.
- `wrap_point_cursor()` (`wrap_map.rs:991-997`): streaming `WrapPointCursor`
  (`wrap_map.rs:1158-...`) with `map(TabPoint, bias)`.
- `clip_point(WrapPoint, bias)` (`wrap_map.rs:1000-1012`): with bias Left,
  if the point lands inside a wrap transform, snap to the *previous* row's end
  (`point = start; column -= 1`); then round-trip via
  `tab_snapshot.clip_point(to_tab_point(point), bias)`.
- `max_point()`, `line_len(row)` (`wrap_map.rs:828-851`): the line length of a
  wrapped row is the wrapped segment length (i.e. `start.0.column` when the row
  is inside a wrap transform, else `start.0.column + (tab_line_len -
  start.1.column)` … precisely the code in that range); note that
  `line_len` for the *first* wrapped segment starts at column 0 relative to
  the segment, not the tab-logical column — that subtlety is why `line_len` for
  wrapped rows uses `start.0.column()` when `overshoot.0 == 0`.
- `soft_wrap_indent(row)` (`wrap_map.rs:916-929`) = Some(`transform.summary.
  output.lines.column`) when the row *after* `row` begins with a wrap
  transform (i.e. row is a wrapped continuation row). Used for caret x offsets
  and hit testing.
- `text_summary_for_range(rows: Range<WrapRow>)` (`wrap_map.rs:854-913`):
  walk transforms; isomorphic segments sum from the tab snapshot; wrap
  transforms contribute `TextSummary { lines: (1, indent), ... }` shaped
  exactly as `wrap_map.rs:874-880` shows (longest_row: 0, etc.).
- `prev_row_boundary(WrapPoint) -> WrapRow` (`wrap_map.rs:1017-1070`) — walks
  backwards to find the last row that is also a tab row (starts a hard line);
  there is an ASCII diagram in a comment at `wrap_map.rs:1033-1040` that's
  worth keeping next to the port as documentation. Note the comment on line
  `1058`: `tab_summary.lines.row > 1` is *deliberately* `>` (not `>=`);
  walk-back-all-the-way is the intended behavior when every line is wrapped —
  don't "fix" this.
- `next_row_boundary(WrapPoint) -> Option<WrapRow>` (`wrap_map.rs:1073-1089`).

**`LineWrapper` integration.** `gpui::LineWrapper` is the shaping-side
prerequisite: `wrap_line(&line_fragments, wrap_width, indent_adjustment) ->
impl Iterator<WrapBoundary>` where `WrapBoundary { ix: usize (byte offset),
next_indent: u32 }` and `IndentAdjustment` derives from
`SoftWrapIndent × tab_size` (`wrap_map.rs:281-283`, helper
`indent_adjustment_for`). This is the single biggest *rendering* dependency in
the pipeline; in zid it maps onto the shaped-line machinery in `src/text`;
until that exists, wrap Map's wrap path is the only blocker for soft wrap.
The `LineFragmentBuilder` (`wrap_map.rs:99-145`) converts invisible chars into
`LineFragment::element(width, len)` using measured replacement widths — zid
needs an equivalent "invisible char → replacement glyph" mapping from
`invisibles.rs` (below).

### 3.5 BlockMap (`display_map/block_map.rs`, 5819 lines)

Blocks are the rows the *block* layer synthesizes: custom inline renderers
(diagnostics, AI panels, spacers), excerpt headers/footers, folded-buffer
blocks. Unlike inlay/fold (where the block-like item is text), block rows are
*empty text rows* — they render as GPUI elements above/below/instead of
specific wrap rows.

**State.** `BlockMap` (`block_map.rs:38-50`) holds, in RefCells:
`transforms: SumTree<Transform>`, `wrap_snapshot: WrapSnapshot`, plus
`custom_blocks: Vec<Arc<CustomBlock>>` (sorted by placement start point),
`custom_blocks_by_id: TreeMap<CustomBlockId, Arc<CustomBlock>>`,
`folded_buffers: HashSet<BufferId>`,
`buffers_with_disabled_headers`, `next_block_id: AtomicUsize`,
`buffer_header_height/excerpt_header_height`, and
`deferred_edits: Cell<Patch<WrapRow>>`. A `BlockMapReader { blocks, snapshot }`
or `BlockMapWriter { block_map, companion }` is the API surface
(`block_map.rs:51-73`). `BlockSnapshot` (`block_map.rs:75-82`) fields as
explained in §1.

**Transform & summary.** (`block_map.rs:368-374` and `block_map.rs:546-553`)

```rust
struct Transform { summary: TransformSummary, block: Option<Block> } // None = passthrough
struct TransformSummary {
    input_rows: WrapRow,   // rows in wrap space covered
    output_rows: BlockRow, // rows presented (block height or passthrough rows)
    longest_row: BlockRow,
    longest_row_chars: u32,
    has_replacement_blocks: bool, // in-tree aggregation (replace blocks)
}
```

`Block` enum (`block_map.rs:376-396`): `Custom(Arc<CustomBlock>)`,
`FoldedBuffer { first_excerpt, height }`,
`ExcerptBoundary { excerpt, height }` (the inter-excerpt boundary block),
`BufferHeader { excerpt, height }` (the per-buffer header at excerpt start),
`Spacer { id, height, is_below }` (companion/diff synchronization spacers).
`BlockId` (`block_map.rs:339-344`): `Custom(CustomBlockId) | ExcerptBoundary
(Anchor) | FoldedBuffer(BufferId) | Spacer(SpacerId)`. `BlockPlacement<T>`
(`block_map.rs:163-172`): `Above(T) | Below(T) | Near(T) | Replace(Range<T>)`
where placement targets are `Anchor`s for custom blocks (converted to wrap rows
via `placement.to_wrap_row(&wrap_snapshot)`).

`CustomBlock` (`block_map.rs:272-...`) carries `id`, `placement`, `height:
Option<u32>` (None = measured at render), `render: RenderBlock = Arc<Fn(&mut
BlockContext) -> AnyElement>`, `style: BlockStyle`, `properties:
BlockProperties<Anchor>`, plus `excerpt顶部` excerpts and similar for the
replacement diff view. `BlockStyle` (`block_map.rs:303-...`) covers
framing/priority for rendering. `EditorMargins` (`block_map.rs:314-...`) is for
hit testing on block rows.

**new / read / write (`block_map.rs:653-758`).** `new` builds one isomorphic
transform spanning all wrap rows and calls `sync` once with a whole-document
edit. `read(wrap_snapshot, edits, companion_view)` syncs in-place and returns a
snapshot clone. `write(...)` additionally creates a `BlockMapWriter` and, when
a companion view exists, syncs the companion's block map too.

**sync (`block_map.rs:806-~1200`).** `sync(&self, wrap_snapshot, mut edits:
Patch<WrapRow>, companion_view: Option<CompanionView>)` (interior mutability on
purpose: reads also sync).

1. `edits = deferred_edits.take().compose(edits)` (`block_map.rs:814`).
2. Trailing-excerpt special case: if
   `buffer.trailing_excerpt_update_count` changed, compose an edit covering the
   last row range `(prev_row_boundary(max_point)..max_point+1)` so the final
   (empty) excerpt's header gets rebuilt (`block_map.rs:818-832`).
3. Companion edits (Zed's split-diff): translate the companion's wrap edits
   into our wrap rows via `convert_point_from_companion`, expand empty edits to
   at least one row, sort, merge, compose (`block_map.rs:834-911`). In zid this
   is deferrable (only used by the multi-buffer/diff views).
4. Per edit (`block_map.rs:930-1140`):
   - Preserve the untouched prefix: `cursor.slice(&old_start, Bias::Left)`; if
     the transform ending exactly here is non-replacement, also push it and any
     trailing `place_below` blocks (`block_map.rs:937-961`).
   - If the edit starts inside a passthrough transform, push the
     pre-edit isomorphic rows; if inside a *replacement block*, extend the edit
     backwards to the replacement's start (`block_map.rs:963-989`).
   - Find the edit end: seek the transform at/after `old_end` (Bias Left +
     one next), extend `old_end/new_end` to that transform's start, merge with
     subsequent edits that intersect, until the boundary aligns
     (`block_map.rs:991-1024`); then discard trailing `place_below`/Spacer
     transforms (`block_map.rs:1026-1037`).
   - Gather custom blocks in the edited wrap-row region (binary search over
     the sorted `custom_blocks`), dropping blocks whose anchor row is *inside
     a fold* unless they are `Replace` blocks (via
     `wrap_snapshot.intersects_fold`, `block_map.rs:1083-1094`), and dropping
     `Above` blocks that now fall before the edit (`block_map.rs:1095-1099`).
   - Add header/footer blocks for the edited region via the
     `header_and_footer_blocks` helper, using the
     inlay→fold→tab→wrap cursor chain to map buffer points to wrap rows
     (`block_map.rs:1104-1116`) and excerpt boundaries.
   - Companion spacers (`block_map.rs:1118-1132`).
   - Sort blocks (`BlockMap::sort_blocks`); then for each block insert the
     preceding isomorphic rows and the block transform itself into
     `new_transforms` (`block_map.rs:1136-...`).
5. Commit the built transforms and emit nothing (sync is internal).

**BlockSnapshot API.**

- `max_point()` = `BlockPoint::new(summary().output_rows.0, 0)` at EOF
  (`block_map.rs:2386-2394`); `longest_row(_in_range)` from summary
  (`block_map.rs:2396-2401`).
- `to_block_point(WrapPoint) -> BlockPoint` (`block_map.rs:2573-2592`): block
  rows snap to the block's first row (`BlockPoint::new(start.1, 0)`); other
  rows add the wrap-row overshoot.
- `to_wrap_point(BlockPoint, bias) -> WrapPoint` (`block_map.rs:2595-2625`):
  for a block transform: `place_below` → end of the previous wrap row
  (`start.1 - 1, line_len`); `place_above`/`bias Left` → `start.1` col 0;
  otherwise → end of the block's last wrap row; for passthrough: row overshoot
  + column.
- `clip_point(BlockPoint, bias)` (`block_map.rs:2504-2563`): walks
  transforms, clipping replacement blocks to their start row and mapping
  passthrough rows through `wrap_snapshot.clip_point`, turning around to
  search the other direction when nothing fits (the `reversed` flag).
- `block_point_cursor()` (`block_map.rs:2565-2570`): streaming
  `BlockPointCursor::map(WrapPoint) -> BlockPoint` (`block_map.rs:126-157`),
  which is the per-row equivalent of `to_block_point` — used by rendering to
  walk rows cheaply.
- `replacement_block_input_range(row)` (`block_map.rs:2627-2630`).
- `block_for_id(BlockId)`, `blocks_in_range(...)`
  (`block_map.rs:2288-2385`).
- `BlockChunks`/`BlockRows` (`block_map.rs:555-573`): chunk emission advances
  per transform — block transforms contribute only newline-only chunks of the
  block's height (`block_map.rs:2673-2750`), passthrough transforms stream from
  `wrap_chunks`. `line_count_overflow` handles blocks taller than 128 rows
  (the u128 bitmap limit) by emitting multiple chunks.

**Mutations through `BlockMapWriter`.** `insert(properties, ...)` and friends
(`block_map.rs:1811-2095`) add/remove `custom_blocks` entries and then
`block_map.sync` again via `write`. `resize` (height changes),
`remove_intersecting_replace_blocks`, `disable_header_for_buffer`,
`fold_buffers/unfold_buffers` are the remaining operations — direct ports.
`custom_blocks` stays sorted by `(placement.start point)` at all times;
`next_block_id` is an atomic monotonic counter.

### 3.6 Highlight pipeline on top (`display_map.rs`)

`HighlightKey` (`display_map.rs:163-193`) is an enum whose *variant order is
.priority* — "lower means higher priority" (`display_map.rs:161-162`), e.g.
`ColorizeBracket` before `SemanticToken`, both before the lexicographic block
of editor-internal highlights. Highlights live in maps keyed by `HighlightKey`:

- `text_highlights: Arc<HashMap<HighlightKey, Arc<(HighlightStyle,
  Vec<Range<Anchor>>)>>` (`display_map.rs:199`),
- `semantic_token_highlights` per buffer id,
- `inlay_highlights: TreeMap<HighlightKey, TreeMap<InlayId, (style, range)>>`
  (`display_map.rs:202`).

`DisplayMap::highlight_text(key, ranges, style, cx)` (`display_map.rs:1140`),
`highlight_inlays` (`1178`), `clear_highlights(_with)` (`1220-1228`),
`all_text_highlights` (1203), `all_semantic_token_highlights` (1209),
`invalidate_semantic_highlights` (1385).

`DisplaySnapshot::chunks(display_rows, language_aware, highlight_styles)` is a
direct call into `block_snapshot.chunks(...)` with the three highlight maps
passed down (`display_map.rs:1897-1914`); the chunk iterators at each layer
merge them via `custom_highlights::CustomHighlightsChunks` (below) or
`Highlights` + `HighlightStyles` plumbing (inlay/chunk ergonomics around
`inlay_map.rs:325-345`).

`highlighted_chunks(display_rows, language_aware, editor_style)` is the
render loop's entry (`display_map.rs:1917-2011`): it folds

- syntax highlight style (tree-sitter),
- `chunk.highlight_style` (with inlay color blending against the background
  when the color is translucent, `display_map.rs:1942-1958`),
- diagnostic underline (per `diagnostic_underline_style`, `display_map.rs:1598-
  1613`; severity gating `display_map.rs:1588-1596`),
- invisible-char replacement styling (via `HighlightedChunk::highlight
  invisibles(...)` at `display_map.rs:2008`, defined in `display_map.rs:1427-
  1522` which rewrites the chunk's text into replacement glyphs and adds
  styles).

into one merged `HighlightStyle` per text chunk (`acc.highlight(highlight)`
across the three sources, `display_map.rs:1991-1998`) and produces
`HighlightedChunk { text, style, diagnostic_underline_severity, is_tab,
is_inlay, replacement }`.

### 3.7 Supporting modules

**crease_map.rs (520 lines).** Creases are *fold candidates*: explicit ranges
(anchored) that may or may not be folded. `CreaseMap { snapshot: CreaseSnapshot,
next_id: CreaseId, id_to_range: HashMap<CreaseId, Range<Anchor>> }`
(`crease_map.rs:15-19`); `CreaseSnapshot { creases: SumTree<CreaseItem> }`
(`crease_map.rs:32-35`) — this map does **not** transform text; it is a query
side-table in buffer (anchor) space. Key queries:
`query_row(MultiBufferRow)` → first crease starting on the row
(`crease_map.rs:51-73`), `creases_in_range` (`crete_map.rs:76-100`) — index by
`ItemSummary` with an anchor-order `cmp` (`crease_map.rs:~101-135`). DisplayMap
re-exports `Crease`, `CreaseId`, etc. and routes folds through it:
`DisplayMap::fold(Vec<Crease<T>>, ...)` (`display_map.rs:722-737`) →
`insert_creases` (933) → fold adds via `FoldMapWriter::fold`. LSP folding
ranges land in `lsp_folding_crease_ids` (`display_map.rs:244`) and enable
`use_lsp_folding_ranges` (`display_map.rs:1518-1520`), which makes
`crease_for_buffer_row` prefer LSP ranges over the indentation heuristic
(`display_map.rs:2360-2476`).

**custom_highlights.rs (432 lines).** `CustomHighlightsChunks` merges plain
buffer chunks with highlight *endpoints*. Construction builds a sorted
`Vec<HighlightEndpoint { offset, tag, style: Option<HighlightStyle> }>` per
query range from `text_highlights` and `semantic_token_highlights`
(`custom_highlights.rs:73-146`), and on `next()` maintains
`active_highlights: BTreeMap<HighlightKey, HighlightStyle>` opening/closing at
endpoints; the effective style per slice is the highest-priority active key
(`partial_cmp`/`cmp` at `custom_highlights.rs:274-283` implement key ordering
by `(variant_index, payload)`). This is the place to port when zid gains
semantic-token or search highlights.

**invisibles.rs (136 lines).** `is_invisible(char)` (`invisibles.rs:36-46`)
covers ASCII control chars except `\t\n\r`, C1 controls, Unicode whitespace
other than U+3000 IDEOGRAPHIC SPACE, plus the Format/invisible char lists from
`invisibles.rs:64-115`. `replacement(char)` (`invisibles.rs:51-61`) maps C0 to
the `C0_SYMBOLS` glyphs, DEL to `␡`, and everything else invisible to
`FIXED_WIDTH_SPACE` (`␠`) — *unless* the char must be preserved (combining
contexts), see `should_preserve_invisible_character`. `is_standalone_grapheme
(text, start, end)` guards against splitting multi-char graphemes
(`display_map.rs:92` imports it; the wrap layer's `LineFragmentBuilder` uses
it, `wrap_map.rs:117`). Port these tables verbatim.

### 3.8 `DisplayMap` / `DisplaySnapshot` top-level API

`DisplayMap` (`display_map.rs:216-245`) is the bundle; its public surface is
what the editor element and movement code call. `DisplaySnapshot`
(`display_map.rs:1506-1521`) is the read-only view with
`crease_snapshot`, `block_snapshot`, the highlight maps, `clip_at_line_ends`,
`masked`, `diagnostics_max_severity`, `fold_placeholder`,
`use_lsp_folding_ranges` and companion snapshot.

Key semantics worth porting explicitly:

- **`DisplayMap::new` ordering caution** (`display_map.rs:382-387`): take the
  buffer snapshot *before* subscribing, because `snapshot()` may sync and
  publish edits — a subscription created first would capture those edits and
  desync the inlay map. In zid, mirror this in the editor setup code.
- **`snapshot()` (608-671)**: sync through wrap, then `block_map.read(...)`
  with the companion view (split-diff support) then assemble the `DisplaySnapshot`.
  Zid can defer the companion entirely.
- **`set_state(other)` (702-718)** restores folds (`Crease::simple` on the
  other snapshot's fold ranges) and disabled headers — used by pane splitting
  and editor restoration. Worth porting early: it makes fold state
  reconstructable from a snapshot.

---

## 4. Public API used by the editor (prioritized)

Method-call frequency by grep over `crates/editor/src` (excluding display_map
itself), ordered by how load-bearing they are for a working editor:

Tier 0 — core, needed to move a caret and render a line:

1. `to_display_point(&self, map) -> DisplayPoint` trait (`display_map.rs195-197`)
   — used ~184 places.
2. `point_to_display_point(MultiBufferPoint, bias)` (`display_map.rs:1740`)
   — ~41 call sites (mostly via the trait).
3. `display_point_to_point(DisplayPoint, bias)` (`display_map.rs:1805`),
   `display_point_to_anchor` (`display_map.rs:1820`), and the
   `anchor → inlay offset` path `anchor_to_inlay_offset`
   (`display_map.rs:1815`), `display_point_to_inlay_offset`
   (`display_map.rs:1810`) — ~50 sites; this is the *edit* path (all edits are
   expressed in buffer offsets).
4. `clip_point` (`display_map.rs:2188`), `clip_ignoring_line_ends`
   (`display_map.rs:2196`), `clip_at_line_end` (`display_map.rs:2215`),
   `inlay_bias_at` (`display_map.rs:2200`) — ~166 sites downstream in
   movement.rs etc. The bias rules live in each layer's `clip_point` (§3).
5. `DisplaySnapshot::max_point` (`display_map.rs:1855`), `line_len`
   (`display_map.rs:2297`), `longest_row(_in_range)` (`display_map.rs:2301-
   2310`), `is_block_line` (`display_map.rs:2259`).

Tier 1 — rendering:

6. `chunks` / `highlighted_chunks` (`display_map.rs:1897/1917`) and
   `text_chunks(row)` (`display_map.rs:1861`), `reverse_text_chunks`
   (`display_map.rs:1877`), `line(row)` (`display_map.rs:2280`) — all exposed
   to the element renderer.
7. `layout_row` / `LineLayout` (`display_map.rs:2063`) and
   `x_for_display_point` (`display_map.rs:2112`), `display_column_for_x`
   (`display_map.rs:2121`), `grapheme_at` (`display_map.rs:2132`): these wrap
   the gpui `LineLayout` cache; in zid these become the interface to the
   shaped-line cache (line layout keyed by `TextLayoutDetails`).
8. `row_infos(start_row)` / `RowInfo` (`display_map.rs:1673`, layered
   implementations §3), `buffer_chars_at(offset)` (`display_map.rs:2165`).
9. `buffer_header_height`/`excerpt_header_height` (`display_map.rs:2518-2522`).

Tier 2 — folds, blocks, decorations:

10. `fold(creases)` (`display_map.rs:722`), `remove_folds_with_type`
    (`display_map.rs:796`), `unfold_intersecting` (`display_map.rs:826`),
    `is_line_folded` (`display_map.rs:2254`), `intersects_fold`
    (`display_map.rs:2250`), `folds_in_range` (`display_map.rs:2226`),
    `is_folded_buffer_header` (`display_map.rs:2263`).
11. `insert_blocks` (`display_map.rs:1021`), `remove_blocks`
    (`display_map.rs:1069`), `resize_blocks` (`display_map.rs:1044`),
    `replace_blocks` (`display_map.rs:1064`), `row_for_block`
    (`display_map.rs:1089`), `blocks_in_range` (`display_map.rs:2233`),
    `block_for_id` (`display_map.rs:2246`).
12. `highlight_text` (`display_map.rs:1140`) and the `HighlightKey` ordering
    (§3.8); `text_highlight_ranges` / `all_text_highlight_ranges`
    (`display_map.rs:2477-2510`).
13. `splice_inlays` (`display_map.rs:1294`), `current_inlays`
    (`display_map.rs:1289`), `inlay_hint_at` (`display_map.rs:1528`),
    `is_inlay_visible` (`display_map.rs:1563`).

Tier 3 — configuration interactions:

14. `set_wrap_width` (`display_map.rs:1248`), `set_font` (`display_map.rs:1243`),
    `set_soft_wrap_indent` (`display_map.rs:1253`), `is_rewrapping`
    (`display_map.rs:1381`), `update_fold_widths` (`display_map.rs:1259`).
15. `set_state` (`display_map.rs:702`), `crease_snapshot`
    (`display_map.rs:697`), `insert_creases`/`remove_creases`
    (`display_map.rs:933/943`).
16. prev/next `line_boundary` (`display_map.rs:1682-1723`), `expand_to_line`
    (`display_map.rs:1724`), `contiguous_display_point_range_for_buffer_range`
    (`display_map.rs:1762`), `start_of_relative_buffer_row`
    (`display_map.rs:2533`), `line_indent_for_buffer_row`
    (`display_map.rs:2293`), `starts_indent` (`display_map.rs:2311`).

Everything above Tier 3 (companion maps, sticky header excerpts
`display_map.rs:2242`, `DisplayPointConverter`) can be ported last or skipped.

---

## 5. Focused rules (tab expansion, soft wrap, folds)

### 5.1 Tab expansion rules (recapisd from §3.3)

- `tab_size` comes from language settings per buffer (`Self::tab_size`,
  `display_map.rs:1373-1380`), passed into `TabMap::new`/`sync`; clamped by
  `MAX_TABS` = the u128 chunk-limit (`tab_map.rs:15-16`, 581 for our config —
  effectively 128).
- A tab at displayed column `e` (of a row whose fold-space column is `c`)
  expands to `tab_size - ((e - 1) % tab_size)` spaces when `e <
  max_expansion_column`; otherwise it is a single space. The per-row state
  needed to evaluate this is carried by `TabStopCursor` (byte offset, char
  offset, tab count, expanded-tab length; `tab_map.rs:540-600`).
- `max_expansion_column` guards pathological lines: beyond it, tabs never
  expand, so `fold_point_to_tab_point` cost stays bounded per row; tests prove
  the invariant with small values (see `test_long_lines*`).
- Sync must widen every edit to cover the *next* tab on the modified row and
  the last tab whose "expanded vs not" state flipped across the edit
  (`tab_map.rs:77-92` comment paraphrased above at §3.3). Port the scan loop
  and the merge that follows (`tab_map.rs:167-187`).
- Tab text summary: `line_len`, `max_point` and `text_summary_for_range` are
  all computed by mapping through fold space and re-scanning; `first_line
  _chars`/`last_line_chars` counts are done in expanded space, and
  `longest_row` is *inherited from the input* summary (`tab_map.rs:296-297`)
  — note when porting `longest_row` semantics change meaning from "chars" to
  "display chars" only through the wrap layer.

### 5.2 Soft-wrap behavior (recap from §3.4)

- `wrap_width: Option<Pixels>` — `None` disables wrapping entirely (the wrap
  transform tree is then a single isomorphic pass-through of tab rows,
  `wrap_map.rs:360-375`).
- Wrapping is driven by gpui's `LineWrapper::wrap_line` with the current font,
  `wrap_width`, and `IndentAdjustment` (derived from the user's
  `SoftWrapIndent` setting and `tab_size`, `wrap_map.rs:281-283`). Each
  `boundary.ix` is a byte index into the row text, and each virtual break
  carries `next_indent`, the number of *display columns* of indent to render
  on the continuation line; the wrap transform encodes it as
  `output.lines = (1, next_indent)`.
- Only *isomorphic* segments accumulate `TextSummary`s; wrap transforms have
  empty input. Therefore `line_len(wrapped_row)` reads through to
  `start.0.column` (the wrap's own start column in wrap space).
- Invisibles inside a wrapped line become width-measured fragments so that
  wrapping matches rendering exactly (`LineFragmentBuilder`, `wrap_map.rs:99-
  145`, tests `test_invisibles_*`).
- **Background wrapping**: edits are queued (`pending_edits`); a rewrap runs
  synchronously when the document is small (< `WRAP_YIELD_ROW_INTERVAL` = 100
  rows) and otherwise is sent to the background after `block_with_timeout(5ms)`
  at rewrap-time / 1ms at flush-time. While in flight, `snapshot.interpolated`
  stays `true` and row-level correctness is preserved by `interpolate()`
  recreating the transforms as isomorphic over the new tab snapshot. Zid has no
  async executor equivalent yet; a faithful first pass can force the
  synchronous path by always treating `total_rows < 100` OR by making the
  "background" task simply re-run sync on demand — *do* keep the
  `interpolated` flag because `DisplayMap::is_rewrapping` and the editor's
  "frozen scrollbar" logic depend on it.
- Soft-wrap indent settings: `SoftWrapIndent` enum from language settings
  (`display_map.rs:103`); Zed only renders `Minimum`/`Same`-style indents via
  `IndentAdjustment` in `wrap_line`, so this is a wrapper-level behavior, not a
  display-map data change.

### 5.3 Fold placeholder rules (recap from §3.2)

- A fold replaces the *folded range* of rows with a single placeholder
  element (`FoldPlaceholder::render`); in text space the placeholder occupies
  `output = collapsed_text or "⋯"` and `input = folded text` — so it can
  substraddle one or more buffer rows but always appears on one display row.
- `merge_adjacent` (default true): folds that touch —
  `next.start == cur.end` — and both have `merge_adjacent` are merged in sync
  (`fold_map.rs:554-565`); overlapping folds are merged regardless.
- `constrain_width` (default true): the rendered placeholder is constrained to
  the shaped width of the ellipsis glyph; Zed measures the actual rendered
  width and calls `update_fold_widths` with `(ChunkRendererId, Pixels)` pairs
  which updates `FoldMetadata.width` and pushes a new edit through tab→wrap→
  block (`display_map.rs:1259-1287`).
- `type_tag: Option<TypeId>`: used to remove groups of overlapping folds
  created by the same subsystem (`remove_folds_with_type`,
  `display_map.rs:796-825`).
- Fold anchors: `anchor_after(start) .. anchor_before(end)`; init skips empty
  ranges and ranges spanning excerpt boundaries (`fold_map.rs:179-195`).
- Points standing exactly on a fold boundary: bias Left keeps the point left
  of the placeholder even for Right-biased conversions
  (`fold_map.rs:867-876`).

---

## 6. Suggested minimal-first port order

Phase the port so that every phase produces a *self-consistent, testable*
display snapshot. Identity/pass-through states are explicitly part of the
design (each layer's no-op branch above).

**Phase 0 — infrastructure (no behavior).**

- `zid/src/display_map/` module skeleton mirroring `display_map.rs` layout;
- sum-tree cursor with dual `Dimensions` (§2.1), `Bias`, `Edit<T>`/`Patch<T>`,
  `Chunk` + bitmaps (§2.3), `TextSummary`/`MBTextSummary` equivalents (§2.2),
  `push_isomorphic` (§2.4);
- unit tests of cursor/summary arithmetic modeled on the Rust helpers
  (`Dimensions`, `Summary`) before touching behavior.

**Phase 1 — the whole chain as pure identity.**

- InlayMap: implement branch 2 of `sync` (no inlays possible yet) + conversions
  between `MultiBufferPoint`/`InlayPoint`/offset (they are equal when there are
  no inlays; keep the general conversion code so later phases don't rewrite).
- FoldMap: `sync` with no folds (fast path), `to_fold_point`/`to_inlay_point`,
  `clip_point` passthrough.
- TabMap: implement with `tab_size` honored but treat rows as basic (still
  requires the `TabStopCursor` + expand/collapse math; this is where the real
  tab work happens — not identity, but small).
- WrapMap: `wrap_width = None` path only (single isomorphic transform); the
  conversions become identity through tab space.
- BlockMap: no blocks (all isomorphic); `to_block_point`/`to_wrap_point` trivial.
- DisplaySnapshot: coordinate plumbing + `chunks` (plain text, no styling),
  `line`, `line_len`, `max_point`, `point_to_display_point`,
  `display_point_to_point`, `clip_point` chain, `row_infos`.
- Port tests: `test_basic_inlays` (modified: zero inlays), `test_expand_tabs`,
  `test_collapse_tabs`, `test_clip_point`, `test_max_point`.

**Phase 2 — folds.**

- `FoldMapWriter::fold` + full `FoldMap::sync` (folds now replace ranges), plus
  `DisplayMap::fold` via `crease_for_buffer_row` (indent heuristic; LSP creases
  can be deferred), `folds_in_range`, `is_line_folded`, placeholder chunks with
  a stub renderer, `set_state` fold restoration.
- Port tests: `test_basic_folds`, `test_adjacent_folds`,
  `test_overlapping_folds`, `test_merging_folds_via_edit`,
  `test_folds_in_range`, `test_buffer_rows` (fold layer),
  `test_blocks_hidden_in_folds` after Phase 4.

**Phase 3 — inlay hints.**

- `InlayMap::splice` + general `sync` path, `clip_point` state machine,
  `InlayChunks` splitting, `inlay_hint_at`, `is_inlay_visible`.
- Port tests: `test_basic_inlays`, `test_inlay_buffer_rows`,
  `test_inlay_utf8_boundaries`, `test_sync_after_path_key_reused_for_different
  _buffer`, `test_inlay_hint_at*` family in `display_map.rs` tests.

**Phase 4 — blocks.**

- `BlockMap::sync` without companion support; excerpt headers/footers
  (`header_and_footer_blocks`), `Above/Below/Near/Replace` custom blocks,
  `to_block_point`/`to_wrap_point` with the block-bias rules, `BlockChunks`
  with `line_count_overflow`, `blocks_in_range`.
- Port tests: `test_basic_blocks`, `test_multibuffer_headers_and_footers`,
  `test_replace_with_heights`, `test_blocks_on_wrapped_lines`,
  `test_replace_lines`, `test_blocks_hidden_in_folds`,
  `test_custom_blocks_inside_buffer_folds`, `test_basic_buffer_fold`.

**Phase 5 — soft wrap.**

- Requires zid shaping (`LineWrapper` equivalent). Implement `WrapMap::sync`
  without background tasks first (synchronous rewrap); add interpolation
  (`WrapSnapshot::interpolate`, `compute_edits`) afterward; the
  `pending_edits` queue semantics can be simplified to "resize → full rewrap"
  as long as `is_rewrapping()` is truthful.
- Port tests: `test_soft_wrap_indent`, `test_soft_wrap_indent_updates_on_tab
  _size_change`, `test_prev_row_boundary`, `test_chunks_with_soft_wrapping`
  (display level), `test_invisibles_*` (wrap level).

**Phase 6 — highlights, invisibles, crease extras.**

- `HighlightKey` priority ordering, `CustomHighlightsChunks`,
  `highlight_text`/`all_text_highlight_ranges`, `highlighted_chunks` merge
  logic, `invisibles.rs` replacement tables, then `update_fold_widths`
  (needs on-screen measurement hooks).
- Port tests: `test_chunks` (highlights), `test_chunks_with_text_highlights`,
  `test_chunks_with_syntax_highlighting_across_blocks`,
  `test_chunks_with_diagnostics_across_blocks`,
  `test_highlight_invisibles_preserves_compound_emojis`,
  `test_tabs_with_multibyte_chars`.

Deliberately deferred (Zed features zid does not need yet): the split-diff
`companion` machinery (`Companion`, all `*companion*` functions and
spacer blocks), sticky header excerpts (`StickyHeaderExcerpt`,
`display_map.rs:2242`), LSP-provided fold creases, `language_aware`
(tree-sitter) chunk styling inside chunks tree-walk.

---

## 7. Test cases worth porting (names + what they assert)

### display_map.rs tests (`display_map.rs:2791-4980`)

- `test_text_chunks` — chunk text for a simple buffer via
  `DisplaySnapshot::text_chunks`.
- `test_clip_point` — the full `DisplaySnapshot::clip_point` matrix across folds,
  tabs, wraps (uses `clip_ignoring_line_ends` variants inline).
- `test_clip_at_line_ends` — `clip_at_line_end` clamps to `line_len(row)` and
  honors `clip_at_line_ends: bool`.
- `test_max_point` — `max_point` counts buffer rows + block rows + wrapped rows.
- `test_point_translation_with_replace_blocks` — `BlockPlacement::Replace`
  ranges make `point_to_display_point` jump correctly across replaced rows.
- `test_isomorphic_display_point_ranges_for_buffer_range` — ranges that cross
  folds/blocks/wraps split into isomorphic subranges.
- `test_inlay_hint_at*` (4 tests) — `inlay_hint_at` ignores block lines, fold
  placeholders, soft-wrap indent columns and returns the inlay + index.
- `test_is_inlay_visible` — visibility across folds and block lines.
- `test_chunks`, `test_chunks_with_syntax_highlighting_across_blocks`,
  `test_chunks_with_diagnostics_across_blocks`,
  `test_chunks_with_text_highlights` — chunk boundary and style composition.
- `test_tabs_with_multibyte_chars` — tab expansion columns with multi-byte
  chars.
- `test_probe` (soft-wrap) — `test_soft_wraps` exercises the
  `DisplayMap::set_wrap_width` + `prev/next_row_boundary` integration.
- `test_creases` — insert/remove creases and the behavior of
  `crease_for_buffer_row`.
- `test_display_map_subscription_ordering` — the `DisplayMap::new` ordering
  caveat (§3.8): subscription must not capture the initial sync's edits.

### inlay_map.rs tests

- `test_basic_inlays` — randomized splice/`randomly_mutate` rounds checked
  against a naive recomputation (text, point mapping, edits) — the property
  test of the layer.
- `test_inlay_buffer_rows` — `InlayBufferRows` `buffer_row`/`is_blank` fields.
- `test_inlay_utf8_boundary_panic_fix` / `test_inlay_utf8_boundaries` — chunk
  splitting must respect char boundaries (`ceil_char_boundary`).
- `test_sync_after_path_key_reused_for_different_buffer` — buffer id reuse must
  reset per-buffer state.

### fold_map.rs tests

- `test_basic_folds` — placeholder text `"⋯"` appears; resulting fold edits
  span the folded range; asserts the exact `FoldEdit` list
  (`fold_map.rs:1849-1861` shows the call: text becomes `aa⋯cc⋯eeeee` for
  2 folds on a 5×6 sample).
- `test_adjacent_folds` — `merge_adjacent: true` folds touching each other
  merge into one transform.
- `test_overlapping_folds` — later folds swallow overlapping earlier ones.
- `test_merging_folds_via_edit` — a buffer edit bridging two folds merges them.
- `test_folds_in_range` — range filtering semantics (strict vs inclusive
  intersection via `intersecting_folds`).
- `test_buffer_rows` — `FoldRows` mapping across folds.

### tab_map.rs tests

- `test_expand_tabs` / `test_collapse_tabs` — checked against a naive
  reimplementation (`expected_collapse_tabs`/`expected_to_fold_point`,
  `tab_map.rs:1168-1183`).
- `test_long_lines`, `test_long_lines_with_character_spanning_max_expansion
  _column` — `max_expansion_column` bounding.
- `test_marking_tabs` — `chunk.tabs` bitmap plumbing through `TabChunks`.
- `test_max_tab_size_full_chunks` / `..._partial_chunks_and_seek` —
  `MAX_TABS` u128 chunk limit + `TabChunks.seek`.
- `test_tab_map_sync_edits` — the sync widening/merging rules.
- `test_tab_stop_cursor_utf8` / `test_tab_stop_with_end_range_utf8` /
  `test_tab_stop_cursor_utf16` — cursor byte/char/utf16 offsets.

### wrap_map.rs tests

- `test_soft_wrap_indent` — `soft_wrap_indent(row)` values and
  `soft_wrap_indent` setting propagation.
- `test_soft_wrap_indent_updates_on_tab_size_change` — tab size changes flow
  into `IndentAdjustment`.
- `test_prev_row_boundary` — the walk-back semantics incl. the `> 1`
  subtlety (§3.4).
- `test_invisibles_become_width_measured_elements` /
  `test_invisibles_wrap_at_replacement_glyph_width` — `LineFragmentBuilder`
  replacement widths used by the wrapper.

### block_map.rs tests

- `test_basic_blocks` — insert/`Above`/`Below`/`Near` conversions through
  `to_block_point`/`to_wrap_point` and block edits.
- `test_blocks_hidden_in_folds` — blocks anchored inside folds are dropped.
- `test_multibuffer_headers_and_footers` — `BlockId::BufferHeader`/
  `ExcerptBoundary` generation from excerpt boundaries.
- `test_replace_with_heights`, `test_replace_lines` — `BlockPlacement::Replace`
  and re-rendering of replaced ranges.
- `test_blocks_on_wrapped_lines`, `test_insert_and_remove_block_anchored_past
  _soft_wrap` — anchors past a soft wrap boundary.
- `test_custom_blocks_inside_buffer_folds`, `test_basic_buffer_fold` —
  `Block::FoldedBuffer` blocks.
- `test_companion_spacer_blocks` — companion spacers (defer for zid).
- `test_sync_edit_anchored_at_end_of_transforms` — edits anchored exactly at
  EOF (`cursor` exhaustion path in `sync`).
- `test_replacement_input_ranges_preserve_partial_tab_rows` — replacement
  blocks that split a tab-expanded row.

### crease_map.rs / custom_highlights.rs tests

- `test_insert_and_remove_creases` — `CreaseMap` id bookkeeping and query_row.
- `custom_highlights.rs` has a randomized `test_random_chunk_bitmaps` — port
  when porting that module.

---

## 8. Practical porting notes for zid

- **Bounds vs Zed's sum-tree**: zid can implement the transform trees with the
  existing `zid/src/text` segment lists as long as the cursor complies with
  the `Dimensions` contract (§2.1). Do not try to be clever with per-layer
  shortcuts before the reference tests pass.
- **u128 bitmaps**: `Chunk.chars/tabs/newlines` are u128 bitmasks. Zig has
  `u128` natively; masking idiom `@as(u128, 1) << split - 1` etc. ports
  directly. Blocks taller than 128 *rows* must use the
  `line_count_overflow` two-chunk trick (`block_map.rs:2682-2691`).
- **Anchors**: folds, highlights and block placements are stored in
  anchor space, not points, because buffer edits must keep them stable. Zid's
  multibuffer port needs anchors before `FoldMap::fold` is portable.
- **Panic sources**: `fold_point_to_offset` asserts "not inside a
  placeholder" (`fold_map.rs:147-149`), `RowInfo` iteration panics on invalid
  start row (`fold_map.rs:905-907`), `DisplaySnapshot::line_len` relies on
  proper `clip_point`. In zid prefer error returns or debug asserts; keep the
  traps visible during the port.
- **Line endings**: Zed's buffers can have `\n` only in text (other line
  endings normalized); placeholders and inlay texts may contain newlines
  (edit-prediction inlays do), which is why summaries treat `lines: Point`
  rather than a row-count field.
- **`chunk.newlines.trailing_zeros()`** row-end discovery idiom appears in the
  tab sync widening (`tab_map.rs:117-118`); port as a helper
  `chunk.row_end_byte()`.
- **Edit consolidation helpers**: every layer ends with a
  `consolidate_*_edits`/merge step (e.g. `consolidate_inlay_edits`,
  `fold_map.rs:1183-1251`); port one generic `consolidate_edits(edits:
  []Edit(T), merge: fn)` and use it everywhere, keeping Zed's exact merge
  predicate (`old.end >= next.old.start` merging, sort by
  `(old.start, old.end desc)`).

---

*End of spec. Source file inventory read for this document:
`display_map.rs` (4980), `inlay_map.rs` (2706), `fold_map.rs` (2570),
`tab_map.rs` (2198), `wrap_map.rs` (2131), `block_map.rs` (5819),
`crease_map.rs` (520), `custom_highlights.rs` (432), `invisibles.rs` (136),
`dimensions.rs` (100).*
