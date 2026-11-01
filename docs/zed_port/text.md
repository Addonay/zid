# Porting spec: Zed `text` and `clock` crates

Source of truth: `/home/addo/dev/stupid/zid/.ref/zed/crates/text/src/*.rs` and
`/home/addo/dev/stupid/zid/.ref/zed/crates/clock/src/*.rs`, inspected 2026-11-01.
Every `file:line` below is relative to `.ref/zed/`.

This document is written so the port can be done without re-reading the Rust. It
covers the data model, the exact edit/undo/anchor algorithms, constants,
invariants, the API surface the editor layer actually uses, a Zig file split, and
the test cases worth porting.

---

## 0. Scope and dependency graph

```
clock            ReplicaId, Lamport (Seq), Global          — no deps
sum_tree         generic Arc-backed B+ tree: Item, Summary, Dimension, SeekTarget,
                 Cursor, FilterCursor, KeyedItem, ContextLessSummary, Bias
rope             Rope (chunked text), Cursor, Chunks, TextSummary, TextDimension,
                 Point, PointUtf16, OffsetUtf16, Unclipped
text             depends on clock, sum_tree, rope
```

`text` does **not** depend on gpui except for test macros and `debug_panic!`
(`gpui_util::debug_panic`, used once at `text.rs:2689`). It uses `anyhow::Result`
in `BufferId::new` and the wait-future methods, `postage::oneshot` for those
futures, `regex` for line-ending normalization, and `parking_lot::Mutex` in
`subscription.rs`.

Not required for a single-user editor port (but noted where relevant):
`network.rs` (test-support only), `wait_for_*` futures, `debug` module
(`text.rs:3724+`, `cfg(debug_assertions)`).

Porting order that works: `clock` → `locator` → `sum_tree` → `rope` → `patch` →
`fragment`/`operation` → `undo_map`/`operation_queue`/`subscription` → `anchor` →
`buffer` → `selection`.

---

## 1. `clock` crate

### 1.1 `ReplicaId`

```rust
pub struct ReplicaId(u16);
pub const LOCAL: ReplicaId = ReplicaId(0);
pub const REMOTE_SERVER: ReplicaId = ReplicaId(1);
pub const AGENT: ReplicaId = ReplicaId(2);
pub const LOCAL_BRANCH: ReplicaId = ReplicaId(3);
pub const FIRST_COLLAB_ID: ReplicaId = ReplicaId(8);
```
`clock.rs:13-39`. Derives `Ord`/`Hash`/`Copy` on the inner `u16`, so ordering is
numeric. `is_remote()` is `self == REMOTE_SERVER || self >= FIRST_COLLAB_ID`.
`Debug` prints `<local>`, `<remote>`, `<agent>`, `<branch>` or the number
(`clock.rs:41-55`).

Zig: `pub const ReplicaId = enum(u16) { local = 0, remote_server = 1, agent = 2, local_branch = 3, _ };`
with a manual `lessThan`/`order` using `@intFromEnum`, because Zig enums with `_`
have no derived ordering.

### 1.2 `Lamport`

```rust
pub type Seq = u32;
pub struct Lamport { pub value: Seq, pub replica_id: ReplicaId }
```
(`clock.rs:57-66`)

Semantics:

| Operation | Behaviour | Ref |
| --- | --- | --- |
| `MIN` | `{value: 0, replica_id: 0}` | `clock.rs:230` |
| `MAX` | `{value: u32::MAX, replica_id: u16::MAX}` | `clock.rs:235` |
| `new(replica)` | `{value: 1, replica_id}` | `clock.rs:240` |
| `tick()` | returns **old** `self`, then `value += 1` | `clock.rs:251-255` |
| `observe(ts)` | `value = max(self.value, ts.value) + 1` | `clock.rs:257-259` |
| `as_u64()` | `((value as u64) << 32) \| replica_id as u64` | `clock.rs:247` |
| `Ord` | `value` first, then `replica_id` (tie-break) | `clock.rs:214-227` |

`tick()` returning the pre-increment value is load-bearing: every operation gets a
unique id and the clock is left strictly greater. `observe` is used when a remote
edit is applied so later local edits sort after it.

### 1.3 `Global` (version vector)

```rust
pub struct Global { values: SmallVec<[u32; 4]> }   // index = replica_id, value = highest observed Seq
```
(`clock.rs:68-74`). Index `i` is `ReplicaId(i)`; a missing index reads as `0`
(`get`, `clock.rs:96-98`).

Exact algorithms (these must be reproduced literally, including the truncation
rule in `meet`):

* `observe(ts)` — `debug_assert` that `ts.replica_id != Lamport::MAX.replica_id`;
  if `ts.value > 0`, grow `values` to `replica_id+1` with zeros, then
  `values[replica_id] = max(values[replica_id], ts.value)` (`clock.rs:103-114`).
  Note: observing value `0` is a no-op and does not grow the vector.
* `join(other)` — grow to `other.len`, then per-index `max` (`clock.rs:120-128`).
* `meet(other)` — grow to `max(len)`, then per index:
  `(0, _) => left = right`, `(_, 0) => keep left`, `_ => left = min(left, right)`;
  track `new_len = last index with a non-zero value + 1`; **truncate to `new_len`
  only if `other.values.len() == self.values.len()` after the resize**
  (`clock.rs:133-158`). Because of the resize, that condition is true whenever
  `other` was at least as long as `self` before the call. The comment in the Rust
  says the opposite of what the code does; port the code. `meet` is used only for
  `FragmentSummary::min_insertion_version`.
* `observed(ts)` — `get(ts.replica_id) >= ts.value` (`clock.rs:160-162`).
* `observed_any(other)` — any index where `other > 0 && self >= other`
  (`clock.rs:164-168`).
* `observed_all(other)` — `false` if `self` is shorter; else all indices
  `self >= other` (`clock.rs:170-177`).
* `changed_since(other)` — `self.len > other.len` or any index `self > other`
  (`clock.rs:179-186`).
* `most_recent()` — `iter().max_by_key(|t| t.value)` (`clock.rs:188-190`).
* `iter()` — every index in `values`, including zeros, as `Lamport`
  (`clock.rs:193-201`).
* `FromIterator<Lamport>` — fold with `observe` (`clock.rs:204-212`).

Zig: `Global` is cloned constantly (every fragment summary). Use a dedicated small
vector (`[4]u32` inline + optional heap slice, explicit allocator) rather than
`std.ArrayListUnmanaged` so the common case (≤4 replicas) never allocates.
Equality is structural over the vector — `Global == Global` compares lengths too,
so a `{0}` vector is not equal to `{}`. `edits_since` relies on that
(`if *since == self.version`, `text.rs:2773`).

---

## 2. `Locator`

```rust
pub struct Locator(SmallVec<[u64; 2]>);
```
`locator.rs:12`. An order-preserving variable-length key: a lexicographic
comparison of `u64` limbs (derived `Ord` on the `SmallVec`, so shorter-is-smaller
only when it is a prefix).

```rust
pub const fn min() -> Self { Self([0]) }            // locator.rs:29
pub const fn max() -> Self { Self([u64::MAX]) }     // locator.rs:34
pub fn assign(&mut self, other: &Self) { resize(other.len); copy_from_slice }  // locator.rs:47
```

`between` is the only allocator of new ids (`locator.rs:52-65`):

```rust
let lhs = lhs.0.iter().copied().chain(iter::repeat(u64::MIN));
let rhs = rhs.0.iter().copied().chain(iter::repeat(u64::MAX));
let mut location = SmallVec::new();
for (lhs, rhs) in lhs.zip(rhs) {
    // This shift is essential! It optimizes for the common case of sequential typing.
    let mid = lhs + ((rhs.saturating_sub(lhs)) >> 48);
    location.push(mid);
    if mid > lhs { break; }
}
```

Read it as: walk limbs in parallel, padding the shorter side with `MIN`/`MAX`;
at each limb take `lhs + ((rhs - lhs) >> 48)` (i.e. 1/65536 of the gap, at least 1
when the gap is ≥ 2^48) and stop as soon as the limb advanced past `lhs`.

Properties worth writing down as tests (they exist in `locator.rs:108-177`):

* Result is strictly between the inputs when `lhs < rhs`.
* Sequential forward appends against `max` stay at depth 1 forever
  (`test_sequential_forward_append_stays_at_depth_1`).
* After one split (a depth-2 prefix), forward typing stays at depth 2 forever
  (`test_typing_at_cursor_stays_at_depth_2`).
* Every limb but the last equals a limb of `lhs` or `rhs` (`test_locators`).

Sum-tree impls (`locator.rs:82-106`): `Item` with `Summary = Locator`
(`summary()` clones self); `KeyedItem` with `Key = Locator`; `ContextLessSummary`
with `zero() = min()` and `add_summary(s) = assign(s)` (i.e. the summary of a
subtree is the **max** id, because `assign` overwrites).

Zig: `Locator = struct { len: u2, limbs: [2]u64 }` with an overflow path (Vec) if
depth can exceed 2. Depth is unbounded in theory; in practice the tests show ≤2.
Implement `between` over a virtual iterator so padding is free.

---

## 3. SumTree contract (what the port must provide)

`crates/sum_tree/src/sum_tree.rs`:

```rust
pub trait Item: Clone { type Summary: Summary;
    fn summary(&self, cx: <Self::Summary as Summary>::Context<'_>) -> Self::Summary; }
pub trait KeyedItem: Item { type Key: for<'a> Dimension<'a, Self::Summary> + Ord;
    fn key(&self) -> Self::Key; }
pub trait Summary: Clone { type Context<'a>: Copy;
    fn zero<'a>(cx: Self::Context<'a>) -> Self; fn add_summary<'a>(&mut self, s: &Self, cx: Self::Context<'a>); }
pub trait ContextLessSummary: Clone { fn zero() -> Self; fn add_summary(&mut self, s: &Self); }
pub trait Dimension<'a, S: Summary>: Clone {
    fn zero(cx: S::Context<'_>) -> Self;
    fn add_summary(&mut self, summary: &'a S, cx: S::Context<'_>); }
pub trait SeekTarget<'a, S: Summary, D: Dimension<'a, S>> {
    fn cmp(&self, cursor_location: &D, cx: S::Context<'_>) -> Ordering; }
pub enum Bias { Left, Right }
```

A `ContextLessSummary` gets a blanket `Summary` impl with `Context = ()`
(`sum_tree.rs:62-72`). `Dimension` has a blanket impl for `T: Summary` itself
(`sum_tree.rs:112`), which is why `Locator` (a Summary) is also usable as a
dimension. `SeekTarget` has a blanket impl for `D: Dimension + Ord`
(`sum_tree.rs:126-130`).

Tree operations used by `text`: `SumTree::new(&cx)`, `default()`, `push(item, &cx)`,
`append(tree, &cx)`, `edit(Vec<Edit<Item>>, cx)` (with
`sum_tree::Edit::Insert`), `cursor::<D>(&cx)`, `filter::<_, D>(&cx, pred)`,
`find::<D, _>(&cx, &target, bias) -> (D, D, Option<&Item>)`,
`find_with_prev::<D,_>(&cx, &target, bias) -> (D, D, Option<(&Item,&Item)>)`,
`items(&cx)`, `summary()`, `last()`, `is_empty()`, `from_iter`, `from_par_iter`,
`to_sum_tree` (on a builder). `Cursor` API: `start()`, `end()`, `item()`,
`next()`, `prev()`, `slice(&target, bias)`, `suffix()`, `seek(&target, bias)`,
`seek_forward(&target, bias)`. `FilterCursor` yields only items matching the
predicate but keeps true `start()`/`end()` dimensions.

Zig port note: the Rust tree is an Arc-backed B+ tree where `clone()` is O(1) and
nodes are shared. `BufferSnapshot: Clone` depends on that. Either implement
copy-on-write nodes (recommended; the project already caches summaries in a
persistent treap) or accept O(n) snapshot clones.

### 3.1 Item/Summary/Dimension table for `text`

| Type | `Item::Summary` | Keyed? | Dimensions seekable on that summary |
| --- | --- | --- | --- |
| `Fragment` (`text.rs:568`) | `FragmentSummary` | no | `usize` (visible), `FullOffset` (visible+deleted), `FragmentTextSummary`, `Option<&Locator>`, `VersionedFullOffset` |
| `InsertionFragment` (`text.rs:605`) | `InsertionFragmentKey` | yes, `Key = InsertionFragmentKey` | `InsertionFragmentKey` |
| `Locator` (`locator.rs:82`) | `Locator` | yes, `Key = Locator` | `Locator` |
| `UndoMapEntry` (`undo_map.rs:6`) | `UndoMapKey` | yes, `Key = UndoMapKey` | `UndoMapKey` |
| `OperationItem<T>` (`operation_queue.rs:10`) | `OperationSummary` | yes, `Key = OperationKey` | `OperationKey` |

`Fragment` has **no** `KeyedItem` impl; locator-ordered seeking is done through
the `Option<&Locator>` dimension (which carries `summary.max_id`).

Summary / dimension behaviour, exactly:

* `Fragment::summary` (`text.rs:3164-3202`):
  `max_version = Global::new().observe(timestamp)` then `observe` every deletion,
  then `join(&self.max_undos)`. `min_insertion_version = max_insertion_version =
  Global::new().observe(timestamp)` (so both are the single-timestamp vector).
  `max_id = self.id`. `text = {visible: len, deleted: 0}` if `self.visible` else
  `{visible: 0, deleted: len}`.
* `FragmentSummary::add_summary` (`text.rs:3211-3220`): `max_id.assign(other.max_id)`
  (max), `text.visible += other.text.visible`, `text.deleted += other.text.deleted`,
  `max_version.join(other.max_version)`,
  `min_insertion_version.meet(other.min_insertion_version)`,
  `max_insertion_version.join(other.max_insertion_version)`. Context is
  `&Option<Global>` and is ignored here. `zero` is `Default`:
  `max_id = Locator::min()`, empty `Global`s (`text.rs:3223-3233`).
* `FragmentTextSummary` as `Dimension` (`text.rs:594-603`): adds `visible` and
  `deleted` separately. This is the dimension used by the **local** edit loop and
  by the `Edits` iterator.
* `usize` as `Dimension` (`text.rs:3307-3315`): adds `summary.text.visible` only.
  `SeekTarget` compares against `cursor_location.visible` (`text.rs:3337-3345`).
* `FullOffset` as `Dimension` (`text.rs:3317-3325`): adds
  `visible + deleted`. `FullOffset(pub usize)` with `AddAssign<usize>`,
  `Add<usize>`, `Sub -> usize` (`text.rs:3281-3305`).
* `Option<&Locator>` as `Dimension` (`text.rs:3327-3335`): `*self = Some(&summary.max_id)`.
* `VersionedFullOffset` (`text.rs:3347-3394`): `enum { Offset(FullOffset), Invalid }`,
  context is `Option<Global>` (must be `Some`). `add_summary`: if
  `version.observed_all(&summary.max_insertion_version)` then add
  `visible + deleted`; else if `version.observed_any(&summary.min_insertion_version)`
  then become `Invalid` (a fragment straddles the version boundary); else do
  nothing. `SeekTarget`: `(Offset, Offset) => cmp`, `(Offset, Invalid) => Less`,
  `(Invalid, _) => unreachable!()`. This is what lets a **remote** edit address
  positions in the coordinate space of the version it was based on.
* `InsertionFragment::summary` = `InsertionFragmentKey { timestamp, split_offset }`
  and `key()` is the same (`text.rs:3235-3252`). `InsertionFragmentKey` is
  `ContextLessSummary` with `zero = {Lamport::MIN, 0}` and
  `add_summary(s) = *self = *summary` (max by key) (`text.rs:3268-3279`).
  Ordering derives `Ord` over `(timestamp, split_offset)` (`text.rs:612-616`).
* `UndoMapKey` is `ContextLessSummary` with `zero = {MIN, MIN}` and
  `add_summary = max(self, summary)` (`undo_map.rs:28-45`). Ordering derives over
  `(edit_id, undo_id)`.
* `OperationSummary` (`operation_queue.rs:18-22`) is `{key: OperationKey, len: usize}`.
  `zero = {Lamport::MIN, 0}`; `add_summary` **asserts `self.key < other.key`**,
  then `self.key = other.key; self.len += other.len`. `Add<&Self>` does the same
  assertion. `OperationKey` as a `Dimension` asserts `*self <= summary.key` and
  assigns. Invariant: keys are strictly increasing, and `insert` sorts + dedups
  by lamport timestamp (`operation_queue.rs:49-58`).

---

## 4. Fragments and insertion bookkeeping

### 4.1 `Fragment` (private)

```rust
struct Fragment {
    id: Locator,
    timestamp: clock::Lamport,     // id of the edit that created this text
    insertion_offset: u32,         // byte offset inside that edit's inserted text
    len: u32,                      // bytes
    visible: bool,
    deletions: SmallVec<[clock::Lamport; 2]>,  // edits that deleted this fragment
    max_undos: clock::Global,      // max undo timestamp observed for this fragment
}
```
`text.rs:568-577`. `len` is `u32` because insertions are capped at
`MAX_INSERTION_LEN` (see §12).

Visibility rules (`text.rs:3150-3162`):

```rust
fn is_visible(&self, undos: &UndoMap) -> bool {
    !undos.is_undone(self.timestamp) && self.deletions.iter().all(|d| undos.is_undone(*d))
}
fn was_visible(&self, version: &clock::Global, undos: &UndoMap) -> bool {
    (version.observed(self.timestamp) && !undos.was_undone(self.timestamp, version))
        && self.deletions.iter().all(|d| !version.observed(*d) || undos.was_undone(*d, version))
}
```

`is_visible` = "visible now"; `was_visible(version)` = "visible at `version`".
A fragment is visible iff its insertion is not undone **and** every deletion of it
is undone.

### 4.2 `InsertionFragment`

```rust
struct InsertionFragment { timestamp: clock::Lamport, split_offset: u32, fragment_id: Locator }
```
`text.rs:605-610`. One entry per fragment ever created (including fragments
created by splitting), keyed by `(timestamp, split_offset)`. This tree is the
index that maps an `Anchor {timestamp, offset}` to a `Locator`:
`split_offset <= anchor.offset < next split_offset`.

### 4.3 `InsertionSlice`

```rust
struct InsertionSlice {
    edit_id_value: clock::Seq, edit_id_replica_id: ReplicaId,       // = edit that caused deletion
    insertion_id_value: clock::Seq, insertion_id_replica_id: ReplicaId, // = fragment.timestamp
    range: Range<u32>,                                              // insertion_offset..+len
}
```
`text.rs:162-215`. `Ord` is `(edit_id, insertion_id, range.start, range.end)`
(`text.rs:174-197`). `from_fragment(edit_id, fragment)` builds it directly.

Stored in `BufferSnapshot::insertion_slices: TreeSet<InsertionSlice>`. Every time
an edit deletes (or newly inserts) text, a slice recording
"edit `E` touched insertion `I` over byte range `R`" is added. Undo uses it to
find which fragments an edit affected without scanning the whole fragment tree.

---

## 5. Core types

### 5.1 `BufferId`

```rust
#[repr(transparent)] pub struct BufferId(NonZeroU64);
```
`text.rs:70-110`. `new(u64)` errors on 0; `next()` is a post-increment
(`saturating_add`) returning the old value; `From<BufferId> for u64`;
`Display` prints the number. `Anchor::opaque_id` packs it as 8 LE bytes.

### 5.2 `Buffer`

```rust
pub struct Buffer {
    snapshot: BufferSnapshot,
    history: History,
    deferred_ops: OperationQueue<Operation>,
    deferred_replicas: HashSet<ReplicaId>,
    pub lamport_clock: clock::Lamport,
    subscriptions: Topic<usize>,
    edit_id_resolvers: HashMap<clock::Lamport, Vec<oneshot::Sender<()>>>,
    wait_for_version_txs: Vec<(clock::Global, oneshot::Sender<()>)>,
}
```
`text.rs:59-68`. `Deref<Target = BufferSnapshot>` (`text.rs:1907-1913`), so all
snapshot methods are callable on `&Buffer`. The two `oneshot` fields only exist to
support `wait_for_edits`/`wait_for_anchors`/`wait_for_version`; drop them if the
port has no async replication.

### 5.3 `BufferSnapshot`

```rust
pub struct BufferSnapshot {
    visible_text: Rope,                     // concatenation of visible fragments
    deleted_text: Rope,                     // concatenation of invisible fragments
    fragments: SumTree<Fragment>,           // in Locator order
    insertions: SumTree<InsertionFragment>, // in (timestamp, split_offset) order
    insertion_slices: TreeSet<InsertionSlice>,
    undo_map: UndoMap,
    pub version: clock::Global,
    remote_id: BufferId,
    replica_id: ReplicaId,
    line_ending: LineEnding,
}
```
`text.rs:112-124`.

Key consequence: **the text is stored twice-ish**. Every fragment's bytes live in
exactly one of `visible_text` or `deleted_text`, and `visible_text` is the buffer
text. Offsets into `visible_text` are "visible offsets" (what `len()`, `Point`,
and `Anchor` resolution use); `FullOffset` counts visible **and** deleted bytes.

### 5.4 `Transaction`, `HistoryEntry`, `History`

```rust
pub struct Transaction { pub id: TransactionId, pub edit_ids: Vec<clock::Lamport>, pub start: clock::Global }
pub type TransactionId = clock::Lamport;
impl Transaction { pub fn merge_in(&mut self, other: Transaction) { self.edit_ids.extend(other.edit_ids) } }

pub struct HistoryEntry {
    transaction: Transaction,
    first_edit_at: Instant,
    last_edit_at: Instant,
    suppress_grouping: bool,
}
impl HistoryEntry { pub fn transaction_id(&self) -> TransactionId }

struct History {
    base_text: Rope,
    operations: TreeMap<clock::Lamport, Operation>,
    undo_stack: Vec<HistoryEntry>,
    redo_stack: Vec<HistoryEntry>,
    transaction_depth: usize,
    group_interval: Duration,
}
```
`text.rs:126-160`. `start` is the snapshot version at the moment the transaction
opened (used by `end_transaction` to report "edits since"). `suppress_grouping`
marks a barrier that time-based grouping must not cross
(`finalize_last_transaction`).

### 5.5 `Operation`, `EditOperation`, `UndoOperation`

```rust
pub enum Operation { Edit(EditOperation), Undo(UndoOperation) }

pub struct EditOperation {
    pub timestamp: clock::Lamport,
    pub version: clock::Global,          // version the edit was based on (pre-edit)
    pub ranges: Vec<Range<FullOffset>>,  // in the base version's full-offset space
    pub new_text: Vec<Arc<str>>,
}

pub struct UndoOperation {
    pub timestamp: clock::Lamport,
    pub version: clock::Global,          // version the undo was based on
    pub counts: HashMap<clock::Lamport, u32>, // edit id -> undo count to apply
}
```
`text.rs:618-637`. `Operation::timestamp()`, `as_edit()`, `is_edit()`,
`replica_id()` (`text.rs:3396-3427`); `operation_queue::Operation` impl returns
the timestamp.

`ranges` are `FullOffset` (visible+deleted) **relative to `version`**, which is
why `apply_remote_edit` needs `VersionedFullOffset` to skip text it has not
observed yet. Local edits always produce `version == current snapshot version`,
so full offsets equal the ones the local edit loop computed.

### 5.6 `LineIndent` and `LineEnding`

`LineIndent { tabs: u32, spaces: u32, line_blank: bool }` (`text.rs:640-745`),
with `from_chunks`, `spaces(n)`, `tabs(n)`, `is_line_empty`, `is_line_blank`,
`raw_len`, `len(tab_size)`.

`LineEnding { Unix, Windows }` (`text.rs:3615-3703`): `as_str` (`"\n"` / `"\r\n"`),
`label` (`"LF"` / `"CRLF"`), `detect(text)` (looks only in the first 1000 bytes,
walked back to a char boundary, for the first `\n`; CRLF if preceded by `\r`),
`normalize(&mut String)` (`\r\n|\r` → `\n` via a static regex),
`normalize_arc`, `normalize_cow`, `apply(String)`.

---

## 6. `Buffer::edit` — the local edit path

### 6.1 Entry point

```rust
pub fn edit<R, I, S, T>(&mut self, edits: R) -> Operation
where R: IntoIterator<IntoIter = I>, I: ExactSizeIterator<Item = (Range<S>, T)>,
      S: ToOffset, T: Into<Arc<str>>
{
    let edits = edits.into_iter().map(|(range, new_text)| (range, new_text.into()));
    self.start_transaction();
    let timestamp = self.lamport_clock.tick();
    let operation = Operation::Edit(self.apply_local_edit(edits, timestamp));
    self.history.push(operation.clone());
    self.history.push_undo(operation.timestamp());
    self.snapshot.version.observe(operation.timestamp());
    self.end_transaction();
    operation
}
```
`text.rs:870-890`. Order matters:

1. open a transaction (implicit; nested if the caller already opened one),
2. tick the lamport clock → `timestamp` (the edit id),
3. apply, producing `EditOperation { timestamp, version: <pre-edit version>, .. }`,
4. record the operation in `history.operations` and append its id to the current
   transaction,
5. make the snapshot observe its own timestamp,
6. close the transaction (which may group it with the previous one, §7).

```rust
fn apply_local_edit<S: ToOffset, T: Into<Arc<str>>>(
    &mut self, edits: impl ExactSizeIterator<Item = (Range<S>, T)>, timestamp: clock::Lamport,
) -> EditOperation {
    let edits: Vec<_> = edits.map(|(range, new_text)| (range.to_offset(&*self), new_text.into())).collect();
    let (edit_op, edits_patch) = self.snapshot.apply_edit_internal(edits, timestamp);
    self.subscriptions.publish_mut(&edits_patch);
    edit_op
}
```
`text.rs:892-903`. Ranges are converted to **visible byte offsets** against the
pre-edit snapshot (`range.to_offset(&*self)`), then the work happens in
`BufferSnapshot::apply_edit_internal`. `edits_patch` is a `Patch<usize>` of
visible-coordinate edits published to subscribers after the snapshot is updated.

### 6.2 `apply_edit_internal` (`text.rs:1916-2070`)

Preconditions the caller must satisfy: ranges are non-overlapping, sorted,
char-boundary aligned, and expressed in the pre-edit visible offset space.
`Buffer::edit` does not sort or validate them.

State:

| Name | Meaning |
| --- | --- |
| `edits_patch: Patch<usize>` | old/new **visible** ranges, one entry per inserted run and per deleted run |
| `edit_op` | `timestamp`, `version` = pre-edit version, `ranges`, `new_text` |
| `new_insertions: Vec<sum_tree::Edit<InsertionFragment>>` | `Insert` ops for the insertions tree |
| `insertion_offset: u32` | running byte offset **within the inserted text of this operation** |
| `insertion_slices: Vec<InsertionSlice>` | slices to add to `insertion_slices` |
| `new_ropes: RopeBuilder` | builds the new visible/deleted ropes by slicing the old ones |
| `old_fragments` | cursor over `fragments` using `FragmentTextSummary` (visible offsets) |
| `new_fragments: FragmentBuilder` | accumulates the rebuilt fragment tree |
| `fragment_start` | visible offset of the start of the current old fragment |

Setup:

```rust
let mut new_ropes = RopeBuilder::new(self.visible_text.cursor(0), self.deleted_text.cursor(0));
let mut old_fragments = self.fragments.cursor::<FragmentTextSummary>(&None);
let mut new_fragments =
    FragmentBuilder::new(old_fragments.slice(&edits.peek().unwrap().0.start, Bias::Right));
new_ropes.append(new_fragments.summary().text);
let mut fragment_start = old_fragments.start().visible;
```
`text.rs:1938-1945`. The prefix before the first edit is sliced off the old tree
and reused as-is (structurally shared, not re-pushed), and its text summary is
appended to the rope builder.

Per edit `(range, new_text)` (`text.rs:1946-2043`):

**(a) Normalize line endings.** `let new_text: Arc<str> = LineEnding::normalize_arc(new_text);`
(`text.rs:1947`) — inserted text is stored with `\n` only.

**(b) Jump ahead if the cursor is behind the range** (`text.rs:1950-1968`):

```rust
let fragment_end = old_fragments.end().visible;
if fragment_end < range.start {
    if fragment_start > old_fragments.start().visible {
        if fragment_end > fragment_start {
            let mut suffix = old_fragments.item().unwrap().clone();
            suffix.len = (fragment_end - fragment_start) as u32;
            suffix.insertion_offset += (fragment_start - old_fragments.start().visible) as u32;
            new_insertions.push(InsertionFragment::insert_new(&suffix));
            new_ropes.push_fragment(&suffix, suffix.visible);
            new_fragments.push(suffix, &None);
        }
        old_fragments.next();
    }
    let slice = old_fragments.slice(&range.start, Bias::Right);
    new_ropes.append(slice.summary().text);
    new_fragments.append(slice, &None);
    fragment_start = old_fragments.start().visible;
}
```
Note the ordering: first flush the *remainder* of a partially consumed fragment
(the fragment we already emitted a prefix of), then take whole fragments up to
`range.start` with `Bias::Right` (include a fragment ending exactly at
`range.start`).

**(c) Record the operation's range in full-offset space** (`text.rs:1970`):

```rust
let full_range_start = FullOffset(range.start + old_fragments.start().deleted);
```
`old_fragments.start().deleted` is the deleted-byte count before the cursor, so
this converts a visible offset into a full offset. Computed **after** the jump so
the cursor is at the right fragment.

**(d) Split off the prefix of the fragment containing `range.start`**
(`text.rs:1972-1981`):

```rust
if fragment_start < range.start {
    let mut prefix = old_fragments.item().unwrap().clone();
    prefix.len = (range.start - fragment_start) as u32;
    prefix.insertion_offset += (fragment_start - old_fragments.start().visible) as u32;
    prefix.id = Locator::between(&new_fragments.summary().max_id, &prefix.id);
    new_insertions.push(InsertionFragment::insert_new(&prefix));
    new_ropes.push_fragment(&prefix, prefix.visible);
    new_fragments.push(prefix, &None);
    fragment_start = range.start;
}
```
The prefix keeps the original timestamp and gets a **new** locator squeezed
between the largest id emitted so far and the original id. This is the only place
`splitting` produces a new locator for pre-existing text.

**(e) Insert the new text before any existing fragment in the range**
(`text.rs:1983-2004`):

```rust
if !new_text.is_empty() {
    let new_start = new_fragments.summary().text.visible;
    let next_fragment_id = old_fragments.item().map_or(Locator::max_ref(), |f| &f.id);
    push_fragments_for_insertion(new_text.as_ref(), timestamp, &mut insertion_offset,
        &mut new_fragments, &mut new_insertions, &mut insertion_slices,
        &mut new_ropes, next_fragment_id, timestamp);
    edits_patch.push(Edit { old: fragment_start..fragment_start,
                            new: new_start..new_start + new_text.len() });
}
```
Inserted text goes **before** the fragment at the cursor, so it sorts before
concurrent text that follows the edit position.

**(f) Delete the intersection with each fragment in `[fragment_start, range.end)`**
(`text.rs:2006-2038`):

```rust
while fragment_start < range.end {
    let fragment = old_fragments.item().unwrap();
    let fragment_end = old_fragments.end().visible;
    let mut intersection = fragment.clone();
    let intersection_end = cmp::min(range.end, fragment_end);
    if fragment.visible {
        intersection.len = (intersection_end - fragment_start) as u32;
        intersection.insertion_offset += (fragment_start - old_fragments.start().visible) as u32;
        intersection.id = Locator::between(&new_fragments.summary().max_id, &intersection.id);
        intersection.deletions.push(timestamp);
        intersection.visible = false;
    }
    if intersection.len > 0 {
        if fragment.visible && !intersection.visible {
            let new_start = new_fragments.summary().text.visible;
            edits_patch.push(Edit { old: fragment_start..intersection_end,
                                    new: new_start..new_start });
            insertion_slices.push(InsertionSlice::from_fragment(timestamp, &intersection));
        }
        new_insertions.push(InsertionFragment::insert_new(&intersection));
        new_ropes.push_fragment(&intersection, fragment.visible);
        new_fragments.push(intersection, &None);
        fragment_start = intersection_end;
    }
    if fragment_end <= range.end { old_fragments.next(); }
}
```
Important details:

* Only **visible** fragments are rewritten (new id, truncated len, deletion
  appended). An already-invisible fragment is copied verbatim (`intersection` is
  the clone; nothing mutated) and its bytes move from `deleted_text` to
  `deleted_text` — the while-loop still terminates because an invisible fragment
  has `fragment_end == fragment_start` and `fragment_end <= range.end` advances
  the cursor.
* `push_fragment(&intersection, fragment.visible)` uses the **old** visibility as
  the source rope selector and the new one as the destination selector.
* `edits_patch` old range is `fragment_start..intersection_end` (visible), new
  range is empty at the current new-visible offset.
* `insertion_slices` is only extended when text actually became invisible.

**(g) Record the operation range** (`text.rs:2040-2042`):

```rust
let full_range_end = FullOffset(range.end + old_fragments.start().deleted);
edit_op.ranges.push(full_range_start..full_range_end);
edit_op.new_text.push(new_text);
```

Teardown (`text.rs:2045-2069`): flush the suffix of a partially consumed last
fragment (same code as (b)), `append(old_fragments.suffix())` for everything after,
`new_ropes.finish()` → `(visible_text, deleted_text)`, then:

```rust
self.fragments = new_fragments.to_sum_tree(&None);
self.insertions.edit(new_insertions, ());
self.visible_text = visible_text;
self.deleted_text = deleted_text;
self.insertion_slices.extend(insertion_slices);
```

Note the insertion tree is updated with `edit(..., ())` inserts keyed by
`(timestamp, insertion_offset)`; a re-split fragment inserts a new key, and the
original key stays (with its original locator) — that is why
`check_invariants` can look up `(fragment.timestamp, fragment.insertion_offset)`
for **every** fragment and get exactly `fragment.id`.

### 6.3 `push_fragments_for_insertion` (`text.rs:1864-1905`)

```rust
let mut text_offset = 0;
while text_offset < new_text.len() {
    let target_end = new_text.len().min(text_offset + MAX_INSERTION_LEN);
    let chunk_end = if target_end == new_text.len() { target_end }
                    else { new_text.floor_char_boundary(target_end) };
    if chunk_end == text_offset { break; }
    let chunk_len = chunk_end - text_offset;
    let fragment = Fragment {
        id: Locator::between(&new_fragments.summary().max_id, next_fragment_id),
        timestamp, insertion_offset: *insertion_offset, len: chunk_len as u32,
        deletions: Default::default(), max_undos: Default::default(), visible: true,
    };
    insertion_slices.push(InsertionSlice::from_fragment(edit_timestamp, &fragment));
    new_insertions.push(InsertionFragment::insert_new(&fragment));
    new_fragments.push(fragment, &None);
    *insertion_offset += chunk_len as u32;
    text_offset = chunk_end;
}
new_ropes.push_str(new_text);
```

* Chunking respects UTF-8 boundaries (`floor_char_boundary`), so a chunk is never
  split mid-character; a chunk can be shorter than `MAX_INSERTION_LEN`.
* Ids are squeezed between the running max id and `next_fragment_id` (the id of
  the fragment that follows the edit), so sequential typing appends ids that
  stay ordered and (per the locator tests) at bounded depth.
* Each new fragment gets an `InsertionSlice` **with the edit's own timestamp as
  the edit id**, which is what makes `fragment_ids_for_edits` able to find newly
  inserted fragments on undo.
* The whole `new_text` is pushed to the visible rope in one call.

### 6.4 `RopeBuilder` (`text.rs:2990-3041`)

```rust
struct RopeBuilder<'a> { old_visible_cursor: rope::Cursor<'a>, old_deleted_cursor: rope::Cursor<'a>,
                         new_visible: Rope, new_deleted: Rope }
```
* `push(len, was_visible, is_visible)` — slice `len` bytes from the old rope
  selected by `was_visible`, append to the new rope selected by `is_visible`.
* `push_fragment(&fragment, was_visible)` — `debug_assert!(fragment.len > 0)`.
* `append(FragmentTextSummary)` — push `visible` (was_visible=true,
  is_visible=true) then `deleted` (false, false); used for untouched subtrees.
* `push_str(text)` — append to `new_visible` (only used for new insertions).
* `finish()` — append the remaining suffixes of both old ropes.

This is why an edit costs O(fragments touched), not O(text): untouched regions
are copied by slicing shared rope chunks.

### 6.5 `FragmentBuilder` (`text.rs:2928-2988`)

Accumulates `FragmentChunk::Tree(SumTree<Fragment>)` (sliced old subtrees, kept
intact so nodes stay shared) and `FragmentChunk::Loose(Vec<Fragment>)` (runs of
individually pushed fragments). `to_sum_tree` appends tree chunks directly and
materialises loose runs with `from_iter` (or `from_par_iter` when > 1024).

---

## 7. Undo / redo

### 7.1 Transaction lifecycle (`text.rs:238-512`)

* `start_transaction(start, now, clock)` — `transaction_depth += 1`; only at depth
  1, `id = clock.tick()` and push `HistoryEntry { transaction: {id, start, edit_ids: []},
  first_edit_at: now, last_edit_at: now, suppress_grouping: false }`; returns
  `Some(id)` at depth 1, else `None`.
* `end_transaction(now)` — `transaction_depth -= 1`; at 0: if the last entry has
  no `edit_ids`, pop it and return `None`; otherwise `redo_stack.clear()`, set
  `last_edit_at = now`, return the entry.
* `group()` — time-based coalescing:

```rust
let mut count = 0;
let mut entries = self.undo_stack.iter();
if let Some(mut entry) = entries.next_back() {
    while let Some(prev_entry) = entries.next_back() {
        if !prev_entry.suppress_grouping
            && entry.first_edit_at - prev_entry.last_edit_at < self.group_interval
        { entry = prev_entry; count += 1; } else { break; }
    }
}
self.group_trailing(count)
```
  (`text.rs:288-304`). Note it walks **backwards from the newest** and compares
  `newer.first_edit_at - older.last_edit_at` (an `Instant` subtraction, which
  panics if the result would be negative — impossible here because entries are
  pushed in time order), so two transactions separated by less than
  `group_interval` merge. `count` is the number of trailing entries to fold in.
* `group_until(transaction_id)` — count entries from the top until the target id
  or a `suppress_grouping` barrier, then `group_trailing(count)`
  (`text.rs:306-318`).
* `group_trailing(n)` — `new_len = undo_stack.len() - n`; append every `edit_id`
  of the trailing `n` entries into `undo_stack[new_len-1]`, copy the newest
  `last_edit_at`, truncate, return the surviving transaction id
  (`text.rs:320-337`).
* `finalize_last_transaction()` — `shrink_to_fit` the id vec, set
  `suppress_grouping = true`, return `&Transaction` (`text.rs:339-345`).
* `push_transaction(tx, now)` — asserts depth 0 and pushes (does **not** clear the
  redo stack).
* `push_empty_transaction(start, now, clock)` — asserts depth 0, ticks a new id,
  pushes an entry with no edits, **does not clear the redo stack**; the caller
  must `forget_transaction` it if nothing is merged in (`text.rs:357-388`).
* `push_undo(op_id)` — asserts depth ≠ 0; **only if** `operations[op_id]` is an
  `Edit` does it append to the current transaction (`text.rs:390-396`). Undo
  operations are therefore not themselves undoable.
* `pop_undo()` / `pop_redo()` — move the top entry between stacks.
* `forget(tx_id)` — remove from undo stack, else redo stack, return the transaction.
* `transaction(tx_id)` / `transaction_mut(tx_id)` — search undo stack then redo
  stack, from the back.
* `merge_transactions(tx, destination)` — `forget(tx)` then extend the
  destination's `edit_ids`.
* `remove_from_undo(tx_id)` — remove the entry, push it onto the redo stack,
  return it. `remove_from_undo_until(tx_id)` — drain `undo_stack[ix..]` reversed
  onto the redo stack, return the newly added redo slice.
  `remove_from_redo(tx_id)` / `remove_from_redo_until` are the mirrors
  (`text.rs:408-433`, `498-511`).

`Buffer::end_transaction_at` (`text.rs:1326-1334`):

```rust
if let Some(entry) = self.history.end_transaction(now) {
    let since = entry.transaction.start.clone();
    let id = self.history.group().unwrap();
    Some((id, since))
} else { None }
```
So the returned `since` is the version **before** the (possibly grouped)
transaction, and the returned id is the id of the surviving entry after grouping.

### 7.2 `undo` / `redo` / `undo_or_redo`

```rust
pub fn undo(&mut self) -> Option<(TransactionId, Operation)> {
    if let Some(entry) = self.history.pop_undo() {
        let transaction = entry.transaction.clone();
        let transaction_id = transaction.id;
        let op = self.undo_or_redo(transaction);
        Some((transaction_id, op))
    } else { None }
}
```
`text.rs:1352-1361`. `redo` is identical against `pop_redo` (`text.rs:1398-1407`).
`undo_transaction(id)` uses `remove_from_undo(id)`; `undo_to_transaction(id)` maps
`remove_from_undo_until(id)`; `redo_to_transaction(id)` mirrors with
`remove_from_redo` (`text.rs:1363-1421`).

```rust
fn undo_or_redo(&mut self, transaction: Transaction) -> Operation {
    let mut counts = HashMap::default();
    for edit_id in transaction.edit_ids {
        counts.insert(edit_id, self.undo_map.undo_count(edit_id).saturating_add(1));
    }
    let operation = self.undo_operations(counts);
    self.history.push(operation.clone());
    operation
}
```
`text.rs:1423-1432`. The "count" is a parity counter per edit id: undo sets it to
`current + 1`, so applying undo an even number of times restores visibility.

```rust
pub fn undo_operations(&mut self, counts: HashMap<clock::Lamport, u32>) -> Operation {
    let timestamp = self.lamport_clock.tick();
    let version = self.version();
    self.snapshot.version.observe(timestamp);
    let undo = UndoOperation { timestamp, version, counts };
    self.apply_undo(&undo);
    Operation::Undo(undo)
}
```
`text.rs:1434-1445`. Note: the snapshot observes the undo timestamp **before**
`apply_undo`, and `version` is the pre-undo version.

### 7.3 `apply_undo` (`text.rs:1221-1274`)

1. `self.snapshot.undo_map.insert(undo)` — inserts one `UndoMapEntry
   { key: {edit_id, undo_id: undo.timestamp}, undo_count }` per count.
2. Iterate `self.fragment_ids_for_edits(undo.counts.keys())` (ascending locator
   order), and for each id:
   * `slice(&Some(fragment_id), Bias::Left)` → append untouched preceding
     fragments (rope text + tree).
   * clone the fragment; `fragment_was_visible = fragment.visible`;
     `fragment.visible = fragment.is_visible(&self.undo_map)`;
     `fragment.max_undos.observe(undo.timestamp)`.
   * if it changed visibility, push a `Patch` edit: hiding →
     `old: old_start..old_start+len, new: new_start..new_start`; showing →
     `old: old_start..old_start, new: new_start..new_start+len`.
   * `new_ropes.push_fragment(&fragment, fragment_was_visible)` and push into the
     new tree; advance the cursor.
3. Append the suffix, finish ropes, assign fragments/visible/deleted text,
   publish the patch.

No new locators are created by undo: visibility flips in place, so anchors keep
resolving.

### 7.4 `fragment_ids_for_edits` (`text.rs:1152-1219`)

1. For each `edit_id`, build a probe `InsertionSlice { edit_id, insertion_id: MIN,
   range: 0..0 }` and `insertion_slices.iter_from(probe)` while
   `slice.edit_id == edit_id`; collect.
2. Sort by `(insertion_id, range.start, Reverse(range.end))`.
3. Walk the `insertions` tree: for each slice, `seek_forward({timestamp:
   insertion_id, split_offset: range.start}, Bias::Left)` unless the cursor
   already sits at a compatible position, then collect every
   `item.fragment_id` while `item.timestamp == insertion_id &&
   item.split_offset < range.end`.
4. `fragment_ids.sort_unstable()` (locator order) and return.

### 7.5 `UndoMap` (`undo_map.rs`)

```rust
pub struct UndoMap(SumTree<UndoMapEntry>);
struct UndoMapEntry { key: UndoMapKey, undo_count: u32 }
struct UndoMapKey { edit_id: Lamport, undo_id: Lamport }
```
* `insert(&UndoOperation)` — one `Edit::Insert` per `(edit_id, count)`.
* `is_undone(edit_id)` — `undo_count(edit_id) % 2 == 1`.
* `undo_count(edit_id)` — seek `{edit_id, MIN}` with `Bias::Left`, then take the
  **max** `undo_count` over entries with the same `edit_id` (`undo_map.rs:95-114`).
* `was_undone(edit_id, version)` — same walk but only counting entries whose
  `undo_id` is `version.observed(..)` (`undo_map.rs:71-93`).

The `max` is what makes concurrent undo work: two replicas undoing the same edit
produce counts 1 and 1, max is 1, still undone; redo produces 2.

---

## 8. Anchor resolution and `Bias`

### 8.1 `Anchor`

```rust
pub struct Anchor {
    pub(crate) timestamp_replica_id: clock::ReplicaId, // inlined Lamport
    pub(crate) timestamp_value: clock::Seq,
    pub offset: u32,   // byte offset into the text inserted by that operation
    pub bias: Bias,
    pub buffer_id: BufferId,
}
```
`anchor.rs:11-28`. The Lamport is stored as two fields to keep the struct 16 bytes.
Constructors: `new(timestamp, offset, bias, buffer_id)`, `min_for_buffer`,
`max_for_buffer`, `min_min_range_for_buffer`, `max_max_range_for_buffer`,
`min_max_range_for_buffer` (`anchor.rs:48-89`).

`is_min` = `timestamp == Lamport::MIN && offset == 0 && bias == Left`;
`is_max` = `timestamp == Lamport::MAX && offset == u32::MAX && bias == Right`
(`anchor.rs:170-180`). `timestamp()` reassembles the Lamport.

Ordering (`anchor.rs:91-103`):

```rust
let fragment_id_comparison = if self.timestamp() == other.timestamp() { Ordering::Equal }
    else { buffer.fragment_id_for_anchor(self).cmp(buffer.fragment_id_for_anchor(other)) };
fragment_id_comparison
    .then_with(|| self.offset.cmp(&other.offset))
    .then_with(|| self.bias.cmp(&other.bias))
```
Anchors are compared **by fragment order**, not by timestamp, so an anchor in
text inserted earlier can sort after one inserted later if the fragments moved.
`min`/`max`/`bias`/`bias_left`/`bias_right` are built on this
(`anchor.rs:105-140`); `bias_left` on a right anchor returns
`buffer.anchor_before(self)`, and vice versa.

`summary::<D>(content)` = `content.summary_for_anchor(self)`.
`is_valid(buffer)` — buffer id must match, min/max are valid, otherwise the
fragment must exist and be `visible` (`anchor.rs:149-168`).
`opaque_id()` — 20 bytes: `buffer_id` (8, LE), `offset` (4), `timestamp_value`
(4), `replica_id` (2), `bias` (1) (`anchor.rs:190-200`).

`OffsetRangeExt` / `AnchorRangeExt` provide `Range<Anchor>::cmp/overlaps/
contains_anchor` and `to_offset/to_point/to_point_utf16`
(`anchor.rs:203-249`). `Range<Anchor>::cmp` orders by start then **reversed** end
(`other.end.cmp(&self.end)`), so wider ranges sort first.

### 8.2 `Bias` semantics

`Bias::Left` = stay with the character before the position; `Bias::Right` = stay
with the character after. In `find`/`seek`, `Bias::Left` picks the item whose
range ends at the target, `Bias::Right` the item that starts at it. In
`anchor_at_offset`, `Bias::Left` at offset 0 gives the min anchor and
`Bias::Right` at `len()` gives the max anchor, so anchors at the buffer edges
survive any edit at that edge.

### 8.3 `offset_for_anchor` (`text.rs:2544-2578`)

```rust
if anchor.is_min() { 0 }
else if anchor.is_max() { self.visible_text.len() }
else {
    debug_assert_eq!(anchor.buffer_id, self.remote_id);
    debug_assert!(self.version.observed(anchor.timestamp()), ...);
    let item = self.try_find_fragment(anchor);
    let Some(insertion) = item.filter(|i| i.timestamp == anchor.timestamp()) else {
        self.panic_bad_anchor(anchor);
    };
    let (start, _, item) = self.fragments.find::<Dimensions<Option<&Locator>, usize>, _>(
        &None, &Some(&insertion.fragment_id), Bias::Left);
    let fragment = item.unwrap();
    let mut fragment_offset = start.1;   // visible offset of the fragment
    if fragment.visible { fragment_offset += (anchor.offset - insertion.split_offset) as usize; }
    fragment_offset
}
```
An anchor inside a deleted fragment resolves to the visible offset where that
fragment was removed (the `if fragment.visible` guard). That is intentional: an
anchor in deleted text collapses onto the deletion point.

`summary_for_anchor::<D>` = `text_summary_for_range(0..offset_for_anchor(anchor))`
(`text.rs:2537-2542`) — i.e. the anchor's position as a `Point`/`usize`/
`OffsetUtf16` summary from the start of the buffer.

### 8.4 `try_find_fragment` (`text.rs:2619-2643`)

```rust
let anchor_key = InsertionFragmentKey { timestamp: anchor.timestamp(), split_offset: anchor.offset };
match self.insertions.find_with_prev::<InsertionFragmentKey, _>((), &anchor_key, anchor.bias) {
    (_, _, Some((prev, insertion))) => {
        let comparison = sum_tree::KeyedItem::key(insertion).cmp(&anchor_key);
        if comparison == Ordering::Greater
            || (anchor.bias == Bias::Left && comparison == Ordering::Equal && anchor.offset > 0)
        { prev } else { Some(insertion) }
    }
    _ => self.insertions.last(),
}
```
`find_with_prev` returns `(prev, found)`; the anchor belongs to the found
insertion unless the found key is *after* the anchor key, or the key is equal and
the bias is left with a non-zero offset (then the anchor belongs to the previous
insertion, i.e. the end of the previous fragment).

### 8.5 `anchor_at_offset` (`text.rs:2669-2704`)

```rust
if bias == Bias::Left && offset == 0 {
    Anchor::min_for_buffer(self.remote_id)
} else if bias == Bias::Right && offset == self.len() {
    Anchor::max_for_buffer(self.remote_id)
} else {
    if !self.visible_text.assert_char_boundary::<{cfg!(debug_assertions)}>(offset) {
        offset = match bias { Bias::Left => floor_char_boundary(offset),
                              Bias::Right => ceil_char_boundary(offset) };
    }
    let (start, _, item) = self.fragments.find::<usize, _>(&None, &offset, bias);
    let Some(fragment) = item else { /* debug_panic, return max anchor */ };
    let overshoot = offset - start;
    Anchor::new(fragment.timestamp, fragment.insertion_offset + overshoot as u32, bias, self.remote_id)
}
```
The `usize` dimension is the visible offset, so `start` is the visible start of
the found fragment and `overshoot` is the byte offset within it. Note the
overshoot is a **byte** offset added to `insertion_offset`, both `u32`.

Two exactness notes: the real condition for the max anchor is
`Bias::Right && ((!cfg!(debug_assertions) && offset >= self.len()) || offset == self.len())`,
i.e. in release builds any out-of-range right-biased offset becomes the max
anchor; and the char-boundary fix-up runs whenever
`assert_char_boundary::<{cfg!(debug_assertions)}>` returns false (a mid-character
offset) — that helper only panics in debug builds when the offset is *out of
bounds*, it returns `false` for a mid-character offset in both profiles.

`anchor_before(pos)` = `anchor_at(pos, Left)`; `anchor_after` = `Right`;
`anchor_range_inside(range)` = `anchor_after(start)..anchor_before(end)` (grows
with text typed at the edges); `anchor_range_outside` =
`anchor_before(start)..anchor_after(end)` (`text.rs:2645-2667`).

### 8.6 `summaries_for_anchors` (`text.rs:2432-2535`)

`summaries_for_anchors::<D>` / `summaries_for_anchors_with_payload` /
`summaries_for_anchors_unordered` share one implementation with a const
`ALLOW_BACKWARDS`. It keeps a fragment cursor (keyed by `Option<&Locator>`) and a
`visible_text` cursor plus a running `D` position:

* min anchor → `D::zero()`, max anchor → `D::from_text_summary(&visible_text.summary())`;
* otherwise `try_find_fragment` (must succeed and its timestamp must equal the
  anchor's), `seek_forward(&fragment_id, Bias::Left)` (or `seek` when backwards
  is allowed and the id is not past the cursor start), take
  `fragment_cursor.start().1` as the fragment's visible start, add
  `anchor.offset - insertion.split_offset` when the fragment is visible, then
  `position.add_assign(&text_cursor.summary(fragment_offset))`.
* the unordered variant restarts the text cursor and position when it has to go
  backwards.

Anchors **must** be supplied in fragment order for the ordered variant; the
unordered variant is O(n) worst case but correct for any order.

`can_resolve(&anchor)` — buffer id matches and (min/max or the version observed
the anchor's timestamp) (`text.rs:2706-2709`).

---

## 9. `edits_since` — patch generation for downstream maps

### 9.1 Entry points (`text.rs:2727-2814`)

```rust
pub fn edits_since<'a, D>(&'a self, since: &'a Global) -> impl Iterator<Item = Edit<D>>
pub fn anchored_edits_since<'a, D>(&'a self, since: &'a Global) -> impl Iterator<Item = (Edit<D>, Range<Anchor>)>
pub fn edits_since_in_range<'a, D>(&'a self, since: &'a Global, range: Range<Anchor>) -> ...
pub fn anchored_edits_since_in_range<'a, D>(&'a self, since: &'a Global, range: Range<Anchor>) -> ...
```
`edits_since` = full-buffer range `min_for_buffer..max_for_buffer`. All are
`D: TextDimension + Ord` (`usize`, `Point`, `PointUtf16`, `OffsetUtf16`).

```rust
if *since == self.version { return None.into_iter().flatten(); }
let mut cursor = self.fragments.filter(&None, move |summary| {
    !since.observed_all(&summary.max_version)
});
cursor.next();
```
`text.rs:2773-2779`. The filter keeps fragments whose `max_version` (insertion
timestamp + deletions + max_undos) has something the caller has not seen. The
extra `cursor.next()` is required because a fresh filter cursor has no current
item; `next()` positions it on the first match (the same idiom appears in
`rope_for_version` and `has_edits_since`).

Start positions (`text.rs:2781-2799`): `fragment_id_for_anchor(range.start)`,
`find::<Dimensions<Option<&Locator>, FragmentTextSummary>>` → `(visible_start,
deleted_start)` of that fragment, then add the anchor's overshoot to whichever
rope the fragment lives in. End anchor gives `end_fragment_id`.

The returned `Edits` iterator carries `range: (start_fragment_id, range.start.offset)
.. (end_fragment_id, range.end.offset)`.

### 9.2 `Edits::next` (`text.rs:3043-3148`)

Per fragment in the filtered cursor:

1. Skip while `fragment.id < *self.range.start.0`; break when
   `fragment.id > *self.range.end.0`.
2. If `cursor.start().visible > visible_cursor.offset()`, advance both `old_end`
   and `new_end` by `visible_cursor.summary(cursor.start().visible)` — untouched
   text between changes moves both coordinate spaces.
3. If a pending edit exists and `pending.new.end < new_end`, break (emit it).
4. Build `start_anchor = Anchor(timestamp, insertion_offset, Right)` and
   `end_anchor = Anchor(timestamp, insertion_offset + len, Left)`.
5. `!fragment.was_visible(since, undos) && fragment.visible` → **insertion**:
   `visible_end = cursor.end().visible`, clamped to
   `cursor.start().visible + (range.end.1 - fragment.insertion_offset)` when this
   is the last fragment of the range; extend `new_end` by that summary; create
   `Edit { old: old_end..old_end, new: new_end..new_end' }` or extend the pending
   edit's `new.end` and its anchor range.
6. `fragment.was_visible(..) && !fragment.visible` → **deletion**: seek
   `deleted_cursor` to `cursor.start().deleted`, clamp `deleted_end` the same way,
   extend `old_end`, create `Edit { old: old_end..old_end', new: new_end..new_end }`.
7. `cursor.next()`; return the pending edit (one per contiguous run).

`has_edits_since` / `has_edits_since_in_range` (`text.rs:2816-2857`) do the cheap
version: scan the same filtered cursor and return `true` on the first fragment
where `was_visible != visible`.

`rope_for_version(version)` (`text.rs:2076-2117`) reconstructs the whole text at
an older version by walking the same filtered cursor and slicing visible/deleted
ropes accordingly — useful for diffing and for tests.

`range_to_version` / `offsets_to_version` (`text.rs:2859-2893`) map current
visible offsets back to offsets at `version` using `edits_since`; offsets inside
an edit clamp to `edit.old.end`.

---

## 10. Remote edits (needed for `apply_ops`, and for understanding invariants)

`Buffer::apply_ops` (`text.rs:909-922`) pushes every op into `history.operations`,
applies it if `can_apply_op` (version `observed_all(op.version)` and the replica
is not in `deferred_replicas`), otherwise defers it; then
`deferred_ops.insert(deferred_ops)` (sorted+deduped) and `flush_deferred_ops`
(retry everything once).

`apply_op` (`text.rs:924-955`): for an `Edit`, if `!version.observed(timestamp)`
→ `apply_remote_edit(&edit.version, &edit.ranges, &edit.new_text, edit.timestamp)`,
then observe the timestamp in `snapshot.version`, `lamport_clock.observe(...)`,
and `resolve_edit(timestamp)`. For an `Undo`, if not observed → `apply_undo`,
observe, `lamport_clock.observe`. Then resolve `wait_for_version` waiters.

`apply_remote_edit` (`text.rs:957-1150`) differs from the local path in exactly
these ways:

* the fragment cursor uses `Dimensions<VersionedFullOffset, usize>` with context
  `Some(version)`, so positions are addressed in the *base version's* full-offset
  space and stop at unobserved fragments (`VersionedFullOffset::Invalid`);
* fragments whose `timestamp > edit.timestamp` at `range.start` are **skipped
  over and kept** before the insert (concurrent insertions at the same offset sort
  after this edit) — `text.rs:1029-1038`;
* a fragment is only rewritten (`len`, `insertion_offset`, new id, deletion) if
  `version.observed(fragment.timestamp)`; unobserved (concurrent) fragments are
  kept whole;
* a deletion is only recorded if `fragment.was_visible(version, &undo_map)`;
* the `edits_patch` old offsets are computed as `old_fragments.start().1 +
  (fragment_start - cursor.start().0.full_offset().0)` only when the old fragment
  is visible, because `old_fragments.start().1` is a visible offset while
  `fragment_start` is a full offset.

If collaboration is out of scope, the port can implement only `apply_local_edit`
and `apply_undo`, but it must keep `EditOperation.version`/`ranges` semantics so
the operation log stays meaningful (redo across a version boundary, and
`rope_for_version`, both rely on them).

---

## 11. `Patch`, subscriptions, operation queue, selection

### 11.1 `Patch<T>` (`patch.rs`)

```rust
pub struct Patch<T>(Vec<Edit<T>>);
pub struct Edit<D> { pub old: Range<D>, pub new: Range<D> }
```
`Edit::is_empty` (both ranges empty), `old_len`, `new_len`, and
`Edit<(D1,D2)>::flatten` (`text.rs:526-566`).

`Patch` API: `empty()`, `new(edits)` (debug-asserts `edit.old.start >
last.old.end` and the same for `new`), `edits()`, `into_inner()`, `invert()`
(swaps old/new in place), `clear()`, `is_empty()`, `push(edit)` (drops empty
edits), `push_maybe_empty(edit)`, `compose(&self, new_edits) -> Patch`,
`old_to_new(old) -> T`, `edit_for_old_position(old) -> Edit<T>`,
`retain_mut`, and `IntoIterator` for owned/`&`/`&mut`.

`push_maybe_empty` (`patch.rs:62-73`):

```rust
if let Some(last) = self.0.last_mut() {
    if last.old.end >= edit.old.start {
        last.old.end = edit.old.end;
        last.new.end = edit.new.end;
    } else { self.0.push(edit); }
} else { self.0.push(edit); }
```
Contiguous or overlapping (in old coordinates) edits coalesce into one. This is
what keeps `edits_since` output to one edit per contiguous run.

`compose` (`patch.rs:88-212`) is a two-pointer merge that produces the patch
equivalent to "apply `self`, then `new_edits`". It maintains `old_start`/`new_start`
cursors and, per step, either copies an untouched old edit (translating it into
the composed new space), copies an untouched new edit (translating into the
composed old space), or splits the two at their intersection and emits the
overlap with `old` from the old patch and `new` from the new patch. It is the
hottest function in the display maps; port it with its unit tests
(`patch.rs:313-654`).

`old_to_new(old)` (`patch.rs:214-234`): binary search for the edit whose
`old.start` is at/just before `old`; if `old >= edit.old.end` translate by the
delta, else clamp to `edit.new.start`. `edit_for_old_position` returns the
touching edit (inclusive on the right: `edit.old.start <= old <= edit.old.end`)
or an empty edit at the translated position (`patch.rs:241-274`).

### 11.2 `Topic` / `Subscription` (`subscription.rs`)

```rust
pub struct Topic<T>(Mutex<Vec<Weak<Mutex<Patch<T>>>>>);
pub struct Subscription<T>(Arc<Mutex<Patch<T>>>);
```
`subscribe()` creates a `Subscription` and stores a weak handle;
`publish(edits)` / `publish_mut(edits)` compose the edits into every live
subscription and drop dead ones; `Subscription::consume()` takes the accumulated
patch (`mem::take`). `Buffer::subscribe()` returns `Subscription<usize>`, i.e.
visible-offset patches.

Zig: a `Topic` of `*Subscription` with refcounted patches, or (simpler, since the
port is single-threaded) a list of `*Patch` owned by subscribers and a
`publish` that composes into each.

### 11.3 `OperationQueue<T: Operation>` (`operation_queue.rs`)

```rust
pub trait Operation: Clone + Debug { fn lamport_timestamp(&self) -> clock::Lamport; }
pub struct OperationQueue<T: Operation>(SumTree<OperationItem<T>>);
pub struct OperationKey(clock::Lamport);
pub struct OperationSummary { pub key: OperationKey, pub len: usize }
```
`new`, `len` (from the summary), `is_empty`, `insert(Vec<T>)` (sort by timestamp,
dedup by timestamp, `Edit::Insert` each), `drain()` (returns a clone and empties),
`iter()`. Used by `Buffer::deferred_ops`.

### 11.4 `Selection<T>` (`selection.rs`)

```rust
pub enum SelectionGoal { None, HorizontalPosition(f64),
    HorizontalRange { start: f64, end: f64 }, WrappedHorizontalPosition((u32, f32)) }

pub struct Selection<T> { pub id: usize, pub start: T, pub end: T, pub reversed: bool,
                          pub goal: SelectionGoal }
```
`head()` = `start` if reversed else `end`; `tail()` the opposite; `map(f)`;
`collapse_to(point, goal)` (both ends, `reversed = false`);
`is_empty`; `set_head(head, goal)`, `set_tail(tail, goal)`,
`set_head_tail(head, tail, goal)`, `swap_head_tail()`; `range()`, `len()`,
`equals(&Range)`, `from_offset` (test-support only).

`set_head` (`selection.rs:71-86`) is the one to get right: if the new head is
before the tail, set `start = head` and `reversed = true` (moving `end` to the old
`start` first if it was not already reversed); otherwise set `end = head` and
`reversed = false` (moving `start` to the old `end` first). `set_tail` is the
mirror with `<=` on the comparison. `set_head_tail` sets `reversed = head < tail`
and stores `start = min`, `end = max`.

`Selection<Anchor>::resolve::<D>(snapshot)` maps both ends through
`snapshot.summary_for_anchor` (`selection.rs:156-169`).

---

## 12. Constants and invariants

| Constant | Value | Ref |
| --- | --- | --- |
| `MAX_INSERTION_LEN` | `16` under `cfg(test)`, else `u32::MAX as usize` | `text.rs:55` |
| default `group_interval` | `Duration::ZERO` under test, else `300ms` | `text.rs:226-230` |
| `Locator::min()` / `max()` | `[0]` / `[u64::MAX]` | `locator.rs:29,34` |
| `Locator::between` shift | `>> 48` | `locator.rs:58` |
| `ReplicaId::LOCAL/REMOTE_SERVER/AGENT/LOCAL_BRANCH/FIRST_COLLAB_ID` | 0/1/2/3/8 | `clock.rs:18-26` |
| `Lamport::new` initial value | `1` | `clock.rs:240` |
| `LineEnding::detect` scan window | first 1000 bytes | `text.rs:3647` |
| `FragmentBuilder` parallel threshold | 1024 loose fragments | `text.rs:2975` |

Invariants (asserted by `check_invariants`, `text.rs:1742-1787`):

1. Fragment ids are strictly increasing in fragment-tree order
   (`fragment.id > prev_fragment_id`, starting from `Locator::min()`).
2. For every fragment there is an `InsertionFragment` at
   `(fragment.timestamp, fragment.insertion_offset)` whose `fragment_id` equals
   `fragment.id`, and vice versa for every insertion fragment (looked up through
   the fragment tree by locator).
3. `fragments.summary().text.visible == visible_text.len()`.
4. `fragments.summary().text.deleted == deleted_text.len()`.
5. The buffer text never contains `"\r\n"` (all line endings normalized on
   ingest and on insert).

Further invariants implied by the code:

6. Every fragment has `len > 0` (`RopeBuilder::push_fragment` debug-asserts it);
   zero-length fragments are never pushed (`if intersection.len > 0`,
   `if chunk_end == text_offset { break }`).
7. A fragment's bytes appear in exactly one rope: `visible_text` if
   `fragment.visible`, else `deleted_text`, in fragment order.
8. `insertion_offset + len` never exceeds the length of the text inserted by
   `timestamp`.
9. `edit_ids` in a transaction are ascending; `history.operations` is keyed by
   lamport timestamp (unique per operation).
10. A `Patch` is sorted, non-overlapping, and `old.start > prev.old.end` /
    `new.start > prev.new.end` (debug assertion in `Patch::new`).
11. `OperationQueue` keys are strictly increasing (`OperationSummary::add_summary`
    asserts `self.key < other.key`).
12. `transaction_depth == 0` outside any transaction; `push_undo` requires depth
    ≠ 0; `pop_undo`/`pop_redo`/`forget`/`merge_transactions` require depth 0.

Known limits: `Fragment::len` and `Anchor::offset` are `u32`, so a single
insertion fragment is at most 4 GiB (in practice `MAX_INSERTION_LEN` splits much
earlier); buffer length itself is `usize` and unbounded in the type system.

---

## 13. What the editor layer actually uses (priority order)

Counts are rough greps over `crates/multi_buffer/src` and `crates/editor/src`
(plus `crates/language/src/buffer.rs`, which wraps `text::Buffer`).

**Tier 1 — every frame / every edit (implement first):**

1. `anchor_before` / `anchor_after` / `anchor_at` / `anchor_range_inside` /
   `anchor_range_outside` — ~160 + 7 + 8 call sites; the display maps
   (`fold_map`, `tab_map`, `wrap_map`, `block_map`, `inlay_map`) and
   `multi_buffer::Anchor` are all built on these.
2. `text()`, `len()`, `max_point()`, `line_len(row)`, `point_to_offset`,
   `offset_to_point`, `clip_offset`, `clip_point`, `chars_at`, `text_for_range`,
   `chunks`/`bytes_in_range` — the render path.
3. `offset_for_anchor`, `summary_for_anchor`, `summaries_for_anchors`,
   `can_resolve` — anchor → `Point`/offset conversions; `can_resolve` gates
   whether a display map can reuse cached layout.
4. `edit(ranges)` (via `language::Buffer::edit`), `apply_ops`, `undo`, `redo`.
5. `snapshot()`, `version()`, `remote_id()`, `replica_id()`, `subscribe()`,
   `edits_since` / `edits_since_in_range` / `anchored_edits_since` /
   `has_edits_since` — 24 + 3 call sites; `multi_buffer` composes these into its
   own patch and `display_map/wrap_map.rs` composes them again.
6. `Patch::compose`, `Patch::push`, `Patch::old_to_new` — used by every display
   map, not just `text`.

**Tier 2 — transaction/undo plumbing (needed for correct editing):**

7. `start_transaction` / `end_transaction_at` / `finalize_last_transaction`
   (24 + 13 call sites) — the editor opens explicit transactions around
   multi-edit commands and finalizes on cursor moves.
8. `group_until_transaction`, `merge_transactions`, `forget_transaction`,
   `push_empty_transaction`, `peek_undo_stack` / `peek_redo_stack` — 8/4/5/1/4
   call sites; used by `editor::Transaction` and by "format selection" flows.
9. `set_group_interval` (12 call sites, mostly tests/settings),
   `transaction_group_interval`.
10. `text_summary_for_range` (14), `common_prefix_at` (completion),
    `contains_str_at` (25, search/selection), `point_from_external_input` (2,
    go-to-line), `line_indent_for_row` / `line_indents_in_row_range` (72,
    auto-indent).

**Tier 3 — less common but public:**

11. `edited_ranges_for_transaction(_id)` (6), `undo_transaction` (3),
    `undo_to_transaction`, `redo_to_transaction`, `undo_operations`,
    `wait_for_anchors` (9), `wait_for_edits`, `wait_for_version`,
    `give_up_waiting`, `has_deferred_ops`, `deferred_ops_len`, `branch`,
    `snapshot_with_edits` / `fast_forward` (formatting), `set_line_ending`,
    `operations()`, `get_transaction`, `rope_for_version`, `range_to_version`,
    `offsets_to_version`, `check_invariants` (26, tests),
    `text_with_line_endings`, `deleted_text`, `reversed_*` iterators.

Note: `Editor` mostly talks to `MultiBuffer`, which talks to
`language::Buffer`, which owns `text::Buffer` and forwards `edit`, `undo`,
`redo`, transactions, `subscribe`, `snapshot`, `set_line_ending`,
`wait_for_*`, `branch`, `snapshot_with_edits`, `fast_forward`. If the port
replaces `MultiBuffer` with a single-buffer model, the same subset still applies.

---

## 14. Suggested Zig file split

`src/text/` already holds the piece-tree implementation and must stay free of
SDL/Zafi. Put the port beside it, in `src/text/zed/`, and expose it through
`src/text/zed.zig`:

| File | Contents | Notes |
| --- | --- | --- |
| `src/text/zed/clock.zig` | `ReplicaId`, `Seq`, `Lamport`, `Global` | `Global` needs an allocator; consider a 4-limb inline small vector |
| `src/text/zed/locator.zig` | `Locator`, `between`, `min`, `max`, `assign` | add a depth guard/overflow path |
| `src/text/zed/sum_tree.zig` | generic `SumTree(T)` with `Item`, `Summary`, `Dimension`, `SeekTarget`, `Cursor`, `FilterCursor`, `Bias`, `Edit` | the biggest prerequisite; if `src/text/piece_tree.zig` already exposes a persistent ordered tree with summaries, adapt it rather than writing a second one |
| `src/text/zed/rope.zig` | thin `Rope`/`Cursor` wrapper over the existing text storage: `slice`, `append`, `push_str`, `summary(D)`, `clip_offset`, `floor/ceil_char_boundary`, `chars_at`, `chunks_in_range` | `RopeBuilder` is written against this |
| `src/text/zed/edit.zig` | `Edit(D)`, `Patch(T)`, `FullOffset` | `compose` gets its own tests |
| `src/text/zed/fragment.zig` | `Fragment`, `FragmentSummary`, `FragmentTextSummary`, `InsertionFragment`, `InsertionFragmentKey`, `InsertionSlice`, all `Item`/`Summary`/`Dimension` impls | the summary table in §3.1 is the spec |
| `src/text/zed/anchor.zig` | `Anchor`, `Bias` helpers, `OffsetRangeExt`/`AnchorRangeExt` equivalents | |
| `src/text/zed/operation.zig` | `Operation`, `EditOperation`, `UndoOperation`, `OperationQueue` | |
| `src/text/zed/history.zig` | `Transaction`, `HistoryEntry`, `History`, grouping | pure, easy to unit test |
| `src/text/zed/undo_map.zig` | `UndoMap`, `UndoMapEntry`, `UndoMapKey` | |
| `src/text/zed/subscription.zig` | `Topic`, `Subscription` | single-threaded list of `*Patch` is enough |
| `src/text/zed/selection.zig` | `Selection(T)`, `SelectionGoal` | |
| `src/text/zed/buffer.zig` | `Buffer`, `BufferSnapshot`, `BufferId`, `LineEnding`, `LineIndent`, `apply_edit_internal`, `apply_undo`, `fragment_ids_for_edits`, `anchor_at_offset`, `offset_for_anchor`, `summaries_for_anchors`, `edits_since`, `Edits` iterator | the port's core; split further only if it exceeds ~1500 lines |
| `src/text/zed.zig` | module root, re-exports | |

Porting rules for Zig:

* Pass `std.mem.Allocator` and `std.Io` explicitly (project constraint); no hidden
  global allocator. `Buffer.edit` allocates temporary `Vec`s for
  `new_insertions`, `insertion_slices`, `edits_patch` — use an arena per edit so
  a failed edit cannot leak.
* Rust's `Arc<str>` for inserted text becomes either `[]const u8` owned by the
  buffer (copied) or a refcounted `*const Text`. Copying is simpler and matches
  the project's "snapshots own their backing source" rule; a 1 MiB typing burst
  is 1 MiB of copies, acceptable.
* Rust's cheap `Clone` for `Rope`/`SumTree`/`BufferSnapshot` becomes explicit
  reference counting. `BufferSnapshot` must be cloneable for
  `snapshot_with_edits`/`branch`; make the tree and ropes refcounted, not deep
  copied.
* `u32` vs `usize`: keep `Fragment.len`, `Anchor.offset`,
  `InsertionFragment.split_offset`, `insertion_offset` as `u32` to preserve the
  memory layout and the `MAX_INSERTION_LEN` invariant; cast at the rope boundary.
* `Instant` for `first_edit_at`/`last_edit_at`: use `std.time.Instant` or an
  `i128` nanosecond counter injected for tests (the tests rely on advancing
  `now` manually — `start_transaction_at(now)` exists for that reason).
* `Global` must be cheap to clone and compare structurally; keep the exact
  truncation behaviour of `meet` (§1.3) or fragment summaries will compare
  unequal and `edits_since` will report spurious edits.
* Do not port `network.rs`, the `debug` module, or the `wait_for_*` futures in the
  first pass; keep `Operation`/`EditOperation` serializable so they can come back.

---

## 15. Tests to port

### 15.1 `crates/text/src/tests.rs`

| Test | What it asserts | Ref |
| --- | --- | --- |
| `test_edit` | Five sequential local edits on `"abc"` produce the expected text; covers append, prepend, middle insert, single-char delete, multi-char replace | `tests.rs:17-32` |
| `test_summaries_for_unordered_anchors` | `offset_for_anchor` for a mixed order of old/new anchors equals `[6,5,9,10,2,0,5]`; `summaries_for_anchors_unordered` matches per-anchor `summary_for_anchor` for `Point` and `usize` | `tests.rs:33-101` |
| `test_summaries_for_unordered_anchors_across_chunks` | Same equality for 200 anchors across a 1100-byte buffer with two edits, shuffled, including deleted and stale anchors | `tests.rs:103-150` |
| `test_point_for_row_and_column_from_external_source` | `point_from_external_input(row, chars)` converts character columns to byte columns (multi-byte text), clamps rows and columns | `tests.rs:152-168` |
| `test_random_edits` | 100 random iterations: buffer text always equals a reference string; random undo/redo; `text_summary_for_range::<TextSummary>` equals `TextSummary::from(&reference[range])`; `check_invariants`; `edits_since` applied to an old snapshot reproduces the new text; `rope_for_version(old)` equals the old text; `edits_since_in_range` reproduces the new text in that range; `has_edits_since` agrees with `edits_since().next().is_some()`; `Subscription::consume()` also reproduces the new text | `tests.rs:170-305` |
| `test_line_endings` | `detect` on LF and CRLF text (including multi-byte prefixes); a `"one\r\ntwo\rthree"` buffer normalizes to `\n` but reports `Windows`; edits containing `\r\n` are normalized | `tests.rs:307-334` |
| `test_line_len` | `line_len(row)` for six rows after several edits, including the empty last row | `tests.rs:336-350` |
| `test_common_prefix_at_position` | `common_prefix_at` returns the case-insensitive common prefix range for prefix, suffix and non-prefix cases, including Greek characters | `tests.rs:352-399` |
| `test_text_summary_for_range` | Six `TextSummary` values for ranges of a multi-line buffer (len/chars/len_utf16/lines/first_line_chars/last_line_chars/last_line_len_utf16/longest_row/longest_row_chars) | `tests.rs:401-492` |
| `test_chars_at` | `chars_at(Point)` from each row yields the exact remaining text; includes a regression case for a 6-row TOML snippet | `tests.rs:494-524` |
| `test_anchors` | Left/right anchors survive three edits with the exact expected offsets and points; `anchor_before(Point)` equals `anchor_before(offset)` for every offset; anchor ordering (`cmp`) is correct for offsets 0/1/2 in both directions | `tests.rs:526-642` |
| `test_anchors_at_start_and_end` | Anchors created at offset 0 (before/after) and at the end survive insertions at both edges: before-start stays 0, after-end stays at the new end, after-start and before-end do not move | `tests.rs:644-665` |
| `test_undo_redo` | With grouping disabled, three transactions; `undo_or_redo` on individual transactions toggles visibility repeatedly in arbitrary order, asserting exact text after each step (parity semantics) | `tests.rs:667-701` |
| `test_history` | Time-based grouping with a 300 ms interval: two transactions inside the interval undo together, a later one separately; redo mirrors; empty transactions return `None`; redo stack cleared by a new edit; `group_until_transaction` merges manually | `tests.rs:703-768` |
| `test_finalize_last_transaction` | `finalize_last_transaction` prevents the next transaction from grouping with it, so undo/redo step separately | `tests.rs:770-804` |
| `test_edited_ranges_for_transaction` | `edited_ranges_for_transaction::<usize>` reports `[2..4, 6..9]`, and re-resolves those same edits to `[2..4, 10..13]` and `[2..4, 11..14]` after later edits | `tests.rs:806-842` |
| `test_concurrent_edits` | Three replicas editing the same base converge to `"a12c34e56"` after `apply_op` | `tests.rs:844-869` |
| `test_edit_partially_intersecting_a_deleted_fragment` | A synthetic remote edit whose full-offset range partially overlaps an already-deleted fragment leaves `"afgh"` and undo restores `"abfgh"` (regression: rope builder must consume only the intersection) | `tests.rs:875-911` |
| `test_random_concurrent_edits` | 5 peers, 10 mutations, random edits/undos/network delivery; all replicas converge and pass `check_invariants` | `tests.rs:913-991` |
| `test_new_normalized_splits_large_base_text` | With `MAX_INSERTION_LEN = 16` in tests, a 100-byte base text becomes several fragments; `anchor_before/after` round-trips at offsets 0,1,15,16,17,50,99; editing still works | `tests.rs:993-1030` |
| `test_new_normalized_splits_large_base_text_with_multibyte_chars` | 108 bytes of 2-byte chars split at char boundaries; every anchor round-trips | `tests.rs:1032-1059` |
| `test_new_normalized_small_text_unchanged` | `"hello world"` yields exactly one fragment | `tests.rs:1061-1076` |
| `test_edit_splits_large_insertion` | A 100-byte insertion into `"abcdefghij"` is split into fragments; text is correct and anchors round-trip at 0,3,50,103,len | `tests.rs:1078-1100` |
| `test_edit_splits_large_insertion_with_multibyte_chars` | 120 bytes of 4-byte chars split at char boundaries | `tests.rs:1102-1115` |
| `test_edit_splits_large_insertion_among_multiple_edits` | Small/large/small edits in one call keep correct positions around the split | `tests.rs:1117-1139` |
| `test_edit_splits_multiple_large_insertions` | Two 40-byte insertions in one call | `tests.rs:1141-1157` |
| `test_edit_undo_after_split` | Undo restores the original text even though the edit produced several fragments | `tests.rs:1159-1176` |

`Buffer::check_invariants` (test-support, `text.rs:1742-1787`) is the harness all
of these rely on; port it early, along with `edit_via_marked_text` /
`edits_for_marked_text` (marked-string editing, `text.rs:1687-1740`) and
`randomly_edit` / `randomly_undo_redo` (`text.rs:1789-1861`) for the randomized
tests.

### 15.2 `patch.rs`, `locator.rs`, `operation_queue.rs` tests

* `patch.rs`: `test_one_disjoint_edit`, `test_one_overlapping_edit`
  (`1..3->1..4` then `3..5->3..6` composes to `1..4->1..6`),
  `test_two_disjoint_and_overlapping`,
  `test_two_new_edits_overlapping_one_old_edit`,
  `test_two_new_edits_touching_one_old_edit`, `test_old_to_new` (offsets 0..9
  against `2..4->2..4` and `7..8->7..11`), `test_random_patch_compositions`.
  The helper `assert_patch_composition` (`patch.rs:624-654`) applies patches
  backwards over a `Vec<char>` alphabet; port it as-is.
* `locator.rs`: `test_locators` (random pairs; `middle` strictly between; all but
  the last limb equal to a limb of an input),
  `test_sequential_forward_append_stays_at_depth_1` (100k appends),
  `test_typing_at_cursor_stays_at_depth_2` (split, then 10k appends).
* `operation_queue.rs`: `test_len` — insert 2, insert 1, `drain`, insert 1;
  `len()` tracks through the summary.

### 15.3 Suggested additional tests for the port

* `Global`: `observe` with value 0 does not grow the vector; `meet` truncation;
  `observed_all` against a shorter vector; `changed_since`.
* `Patch::push` coalescing for contiguous and overlapping old ranges.
* `UndoMap::undo_count` taking the max across concurrent undos, and
  `was_undone` filtering by observed undo timestamps.
* `anchor_at_offset` at 0 and at `len()` for both biases, and on a multi-byte
  boundary.
* `edits_since` returning nothing when `since == version`.
* Delete a whole fragment, undo, then edit again — exercises `max_undos` and the
  redo-stack clearing.
