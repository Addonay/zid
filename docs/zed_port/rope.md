# Porting spec: Zed `rope` crate to Zig

Source: `/home/addo/dev/stupid/zid/.ref/zed/crates/rope/src/`
Files: `rope.rs` (2552 lines), `chunk.rs` (1249), `point.rs` (146), `point_utf16.rs` (119), `offset_utf16.rs` (49), `unclipped.rs` (51).

Citations are `file:line`, relative to the source directory above.

External items this spec does not re-derive: `sum_tree::SumTree`, `Cursor`, `Dimension(s)`, `Bias`, `TREE_BASE` (`sum_tree/src/sum_tree.rs:15-18`, `cursor.rs`); `gpui_util::is_utf8_char_boundary(b)` = `(b as i8) >= -0x40`, i.e. "not a continuation byte" (`gpui_util/src/lib.rs:158-161`); `unicode_segmentation::GraphemeCursor` (only `ChunkSlice::clip_point`); `heapless` fixed containers; `rayon` (optional).

---

## 0. Build-mode constants

`chunk.rs:8-11`: `Bitmap = u128` normally, `Bitmap = u16` under `cfg(all(test, not(rust_analyzer)))`.

| Constant | Production | `cfg(test)` | Source |
|---|---|---|---|
| `MAX_BASE` (`= Bitmap::BITS`) | 128 | 16 | `chunk.rs:13-14` |
| `MIN_BASE` (`= MAX_BASE/2`) | 64 | 8 | `chunk.rs:13` |
| `NUM_CHUNKS` (push fast-path cap) | 4 | 16 | `rope.rs:175-178` |
| `PARALLEL_THRESHOLD` | `84 * (2 * TREE_BASE)` | 4 | `rope.rs:232-235` |
| `TREE_BASE` | 6 | 2 | `sum_tree.rs:15-18` |

**The crate's own tests run with 16-byte chunks.** The 128-bit chunk path is only covered by `nth_set_bit` tests at 128 bits. The port must make width a comptime parameter and run the suite at both 16 and 128.

`MIN_CHUNK_SIZE = MAX_BASE - 3` (`rope.rs:215`). `Chunk::new` groups bytes in 8s (`chunk.rs:56`).

---

## 1. Chunk: storage, bitmaps, O(1) queries

### 1.1 Struct

`chunk.rs:16-33`. All bitmaps are indexed by **byte** offset within the chunk and have zero bits at positions `>= text.len()`.

| Field | Bit `i` set when | Popcount is |
|---|---|---|
| `chars` | byte `i` is not a continuation byte (starts a scalar) (`chunk.rs:18-20`) | number of scalars, including `'\n'` |
| `chars_utf16` | `i` starts a scalar, and also `i+1` for 4-byte scalars (`chunk.rs:21-26`) | UTF-16 length |
| `newlines` | byte `i` is `'\n'` (`chunk.rs:28-29`) | rows terminated |
| `tabs` | byte `i` is `'\t'` (`chunk.rs:30-31`) | tab count |
| `text` | `ArrayString<MAX_BASE, u8>` (`chunk.rs:32`) | - |

`ChunkSlice` (`chunk.rs:217-224`) is the same bitmaps with `text: &str`; bit 0 is the slice start.

Zig: `text: [MAX_BASE]u8` plus `len`, and four `Bitmap` fields.

### 1.2 Mask helpers and shifts

```rust
saturating_shl_mask(o) = (1 as Bitmap).unbounded_shl(o).wrapping_sub(1)   // bits < o      (chunk.rs:35-38)
saturating_shr_mask(o) = !Bitmap::MAX.unbounded_shr(o)                    // top o bits    (chunk.rs:40-43)
```

Both return all-ones for `o >= BITS`. Zig's `<<`/`>>` with a shift `>= width` is illegal, so port every `unbounded_*` as `if (s >= BITS) 0 else x << s`. Several sites pass `offset == MAX_BASE` (`chunk.rs:183, 251, 284, 409, 473, 501`).

### 1.3 Building a chunk: `Chunk::new` (`chunk.rs:49-102`)

1. Copy text into the fixed buffer. `unwrap()` panics if `len > MAX_BASE` (`chunk.rs:50-54`). Callers split first.
2. For each byte at lane `ix`:
```rust
chars       |= (is_utf8_char_boundary(b) as u8) << ix;   // chunk.rs:76
newlines    |= ((b == b'\n') as u8) << ix;              // chunk.rs:77
tabs        |= ((b == b'\t') as u8) << ix;              // chunk.rs:78
chars_utf16 |= ((b >= 240) as u8) << ix;                // chunk.rs:82  (4-byte lead)
```
3. Assemble the per-group bytes little-endian (`chunk.rs:93-100`).
4. Shift and merge:
```rust
chars_utf16: (Bitmap::from_le_bytes(chars_utf16_bytes) << 1) | chars,   // chunk.rs:98
```
A 4-byte scalar at `i` sets bits `i` and `i+1`, so popcount equals UTF-16 length. Rust scalars never exceed two UTF-16 units (`chunk.rs:24-26`). The `<< 1` drops bit 127, which is safe because a valid 4-byte lead cannot start at byte 127 of a 128-byte chunk.

A per-byte loop that builds the same four bitmaps is a valid port.

### 1.4 Append, prepend, slice

- `push_str(t)` = `append(new(t).as_slice())` (`chunk.rs:105-107`); `prepend_str` likewise (`110-112`).
- `append(s)` (`chunk.rs:115-126`): return if empty (before any shift, since `<< BITS` is invalid); else `base = text.len()`, each bitmap `|= s.bitmap << base`, then append text. Caller guarantees `base + s.len <= MAX_BASE`.
- `prepend(s)` (`chunk.rs:129-148`): return if empty; if self is empty, replace with `new(s.text)`; else `shift = s.len`, each bitmap `= s.bitmap | (self.bitmap << shift)`, then `text = s.text ++ text`.
- `as_slice`, `slice(range)`, `chars()`, `tabs()`, `newlines()` (`chunk.rs:151-179`).

### 1.5 Split and slice of `ChunkSlice`

`split_at(mid)` (`chunk.rs:250-280`):
```rust
if mid == MAX_BASE { return (self, empty) }                 // chunk.rs:251
mask = (1 << mid) - 1
left  = { bitmaps & mask,  text[..mid] }
right = { bitmaps >> mid,  text[mid..] }                    // chunk.rs:262-276
```

`slice(range)` (`chunk.rs:283-314`):
```rust
if range.start == MAX_BASE { return empty }                 // 284
if !is_char_boundary(range.start) { range.start = ceil(range.start) }     // 293-295
if !is_char_boundary(range.end) {                           // 296-302
    range.end = if range.end < range.start { range.start } else { floor(range.end) }
}
mask = (1 << range.end) - 1                                 // 303-305
bitmaps = (bitmaps & mask) >> range.start                   // 307-310
```
The assertion behind this is `assert_char_boundary::<false>` (`chunk.rs:204-214`, `442-452`), which panics in debug builds regardless of `PANIC` (`chunk.rs:208`).

`is_char_boundary(o)` = `(1 << o) & chars != 0 || o == len` (`chunk.rs:182-184`, `245-247`).

### 1.6 O(1) queries from bitmaps

Notation: `m(o) = saturating_shl_mask(o)`, `B = BITS`.

**Rows and last line**
- Rows: `row = newlines.count_ones()` (`chunk.rs:348`).
- Last-line bytes:
```rust
let column = self.newlines.leading_zeros() - (Bitmap::BITS - self.text.len() as u32);   // chunk.rs:349
```
If the highest newline is at `h`, then `lz = B-1-h` and `column = len-1-h = lz - (B - len)`. With no newline, `lz = B` and `column = len`.
- First-line chars: `(chars & m(newlines.trailing_zeros())).count_ones()` (`chunk.rs:355-357`).
- Last-line chars: `(chars & saturating_shr_mask(newlines.leading_zeros())).count_ones()` (`chunk.rs:361-363`).
- Last-line UTF-16: same on `chars_utf16` (`chunk.rs:367-369`).

**Byte offset to point** (`chunk.rs:407-414`):
```rust
let mask = (1 << offset) - 1;                               // bits < offset
let row = (newlines & mask).count_ones();
let newline_ix = B - (newlines & mask).leading_zeros();     // last newline before offset, +1; 0 if none
let column = offset - newline_ix;
```

**Point to byte offset** (`chunk.rs:417-438`): `offset_range_for_row(row)`, then clamp column to the row length (`debug_panic` if column is past the row end, then return `row_range.end`).

**Row range** (`chunk.rs:655-674`):
```rust
row_start = if row > 0 { nth_set_bit(newlines, row) + 1 } else { 0 }        // 656-664
row_len   = if row_start == MAX_BASE { 0 }
            else { min((newlines >> row_start).trailing_zeros(), len - row_start) }   // 665-672
row_start .. row_start + row_len
```
Precondition: `row <= lines().row`.

**Byte offset to UTF-16 offset** (`chunk.rs:471-475`): `popcount(chars_utf16 & m(offset))`.

**UTF-16 offset to byte offset** (`chunk.rs:477-497`):
```rust
if target == 0 { return 0 }
ix = nth_set_bit(chars_utf16, target) + 1                   // 486
if ix == MAX_BASE { return MAX_BASE }                       // 487-489
ix + min(tz(chars_utf16 >> ix), len - ix)                   // 490-494
```
If the target falls mid-surrogate, the result is a **non-boundary** offset (the byte after a 4-byte lead). Callers must clip first.

**UTF-16 offset to point** (`chunk.rs:500-510`): `row = popcount(newlines & m(o))`; column is `popcount((chars_utf16 & mask) >> newline_ix)` where `newline_ix` is as in 1.6 (column 0 if `newline_ix == MAX_BASE`).

**Point to UTF-16 point**: `offset_to_point_utf16(point_to_offset(p))` (`chunk.rs:513-515`).

**UTF-16 point to byte offset** `point_utf16_to_offset(p, clip)` (`chunk.rs:518-562`):
1. `p.row > lines.row`: return `len` (debug_panic if `!clip`).
2. `line = slice(offset_range_for_row(row))`.
3. `p.column > line.last_line_len_utf16`: return `row_range.end` (debug_panic if `!clip`).
4. `offset = row.start + line.offset_utf16_to_offset(column)`.
5. If not a char boundary, step **left** to one. This happens regardless of `clip`; `clip` only controls the debug panic.

**Unclipped UTF-16 point to point** (`chunk.rs:565-584`): row past end gives `lines`; column 0 gives col 0; column `>= len_utf16` gives `len`; else `offset_utf16_to_offset`, stepping left to a boundary.

**Clipping**
- `clip_offset_utf16(t, bias)` (`chunk.rs:636-652`): `t == 0` gives 0; `t >= len_utf16` gives `len_utf16`; else step the byte offset left (`Left`) or right (`Right`) to a char boundary, then `offset_to_offset_utf16`.
- `clip_point_utf16(p, bias)` (`chunk.rs:624-633`): row past end gives `(lines.row, last_line_len_utf16)`; else `line.clip_offset_utf16(column, bias)`.
- `clip_point(p, bias)` (`chunk.rs:587-621`): **grapheme**-aware.
  1. Row past end gives `lines`. Column 0 is identity. Column `>= len` gives `len`.
  2. Fast path (`chunk.rs:601-603`): if both `bytes[c-1]` and `bytes[c]` are `< 128`, return `c`. This is valid because the slice is one row and has no `'\n'`, so the CR-LF grapheme case cannot occur.
  3. Else loop with `GraphemeCursor::new(c, len, true)`. Accept `c` when `is_char_boundary(c) && is_boundary(text, 0)`; otherwise move `c` by `-1` (Left) or `+1` (Right).

**Tabs** (`chunk.rs:696-718`): each `next()` takes `t = tz(tabs)`, reports `byte = t` and `char = popcount(chars & ((1<<t)-1))`, then clears bit `t`. Check `tabs == 0` first, since `tz(0) = B`.

### 1.7 `nth_set_bit` (`chunk.rs:720-819`)

Returns the bit index of the **1-based** `n`-th set bit. Tested at 128 bits by `test_nth_set_bit_random`.

`nth_set_bit(v: u128, n)` (`chunk.rs:721-732`): split into `u64` halves; if `n > popcount(low)` return `64 + select(high, n - lo)`, else `select(low, n)`.

`nth_set_bit_u64` (`chunk.rs:783-819`) is a branchless parallel-prefix select (`reverse_bits` at 785, popcount tree at 789-792, then six conditional steps at 795-816, final `65 - s - 1` at 818).

Porting advice: a loop that clears the lowest set bit `n-1` times and returns `@ctz` is correct and simpler. Use the branchless version only after profiling. Confirm `@ctz(0)`/`@clz(0)` semantics in Zig 0.17 before relying on them.

---

## 2. Summaries and dimensions

### 2.1 TextSummary (`rope.rs:1278-1302`)

| Field | Type | Meaning |
|---|---|---|
| `len` | usize | bytes |
| `chars` | usize | scalars, **including** `'\n'` |
| `len_utf16` | OffsetUtf16 | UTF-16 units |
| `lines` | Point | row = count of `'\n'`; column = **bytes** after last `'\n'` |
| `first_line_chars`, `last_line_chars` | u32 | chars in row 0 / last row |
| `last_line_len_utf16` | u32 | UTF-16 units in last row |
| `longest_row`, `longest_row_chars` | u32 | longest row by chars; ties go to the earliest row |

`lines_utf16() = PointUtf16 { row: lines.row, column: last_line_len_utf16 }` (`rope.rs:1305-1310`).
`TextSummary::newline()` = `{len 1, chars 1, len_utf16 1, lines (1,0)}` (`rope.rs:1312-1324`). `add_newline` is broken; see section 7.

### 2.2 From a string (`rope.rs:1335-1381`)

Single pass over `text.chars()`:
```
chars += 1; len_utf16 += c.len_utf16()
if c == '\n': lines += (1,0); last_line_len_utf16 = 0; last_line_chars = 0
else:         lines.column += c.len_utf8(); last_line_len_utf16 += c.len_utf16(); last_line_chars += 1
if lines.row == 0: first_line_chars = last_line_chars
if last_line_chars > longest_row_chars: longest_row = lines.row; longest_row_chars = last_line_chars
len = text.len()
```

### 2.3 `AddAssign` (`rope.rs:1402-1431`): `self += other` appends `other` after `self`

1. Seam: `joined = self.last_line_chars + other.first_line_chars`. If `joined > self.longest_row_chars`, set `longest_row = self.lines.row`, `longest_row_chars = joined` (`1404-1408`).
2. If `other.longest_row_chars > self.longest_row_chars` (after step 1), set `longest_row = self.lines.row + other.longest_row` and `longest_row_chars = other.longest_row_chars` (`1409-1412`).
3. If `self.lines.row == 0`: `first_line_chars += other.first_line_chars` (`1414-1416`).
4. If `other.lines.row == 0`: `last_line_chars += other.first_line_chars`; `last_line_len_utf16 += other.last_line_len_utf16`. Else take `other`'s `last_line_chars` and `last_line_len_utf16` (`1418-1424`).
5. Sum `chars`, `len`, `len_utf16`; then `lines += other.lines` with the Point rule (section 5.1).

`Add`, `AddAssign<Self>` delegate (`rope.rs:1393-1400, 1433-1437`). `ContextLessSummary`: `zero = default`, `add_summary = +=` (`1383-1391`).

### 2.4 ChunkSummary and per-chunk summary

- `Item for Chunk` (`rope.rs:1253-1261`): `summary = ChunkSummary { text: chunk.as_slice().text_summary() }`.
- `ChunkSummary { text: TextSummary }` (`rope.rs:1263-1276`), zero and add forward to `text`.
- `ChunkSlice::text_summary` (`chunk.rs:316-331`): `len`, `chars` and `(longest_row, longest_row_chars)` from one pass, `len_utf16`, `lines`, `first/last_line_chars`, `last_line_len_utf16`.
- `longest_row(&mut total)` (`chunk.rs:374-405`) walks newlines:
```rust
while newlines > 0 {
    ix = tz(newlines)
    row_chars = popcount(chars & ((1 << ix) - 1))
    total += row_chars; if row_chars > best { best_row = row; best = row_chars }
    newlines >>= ix; newlines >>= 1;     // two shifts avoid shifting by B
    chars    >>= ix; chars    >>= 1;
    row += 1; total += 1                 // the '\n' is a scalar
}
last = popcount(chars); total += last; if last > best { (row, last) } else { (best_row, best) }
```

### 2.5 Dimensions

A dimension is a type accumulated from `ChunkSummary` and used as a seek key.

| Dimension | zero | add (`ChunkSummary`) | `from_chunk` | `from_text_summary` | Source |
|---|---|---|---|---|---|
| `usize` | 0 | `+= text.len` | `len()` | `len` | `rope.rs:1490-1512` |
| `OffsetUtf16` | 0 | `+= text.len_utf16` | `len_utf16()` | `len_utf16` | `rope.rs:1514-1536` |
| `Point` | (0,0) | `+= text.lines` | `lines()` | `lines` | `rope.rs:1538-1560` |
| `PointUtf16` | (0,0) | `+= text.lines_utf16()` | `(lines.row, last_line_len_utf16)` | `lines_utf16()` | `rope.rs:1562-1587` |
| `TextSummary` | default | `+= text` | `text_summary()` | copy | `rope.rs:1466-1488` |
| `Dimensions<A,B>` | both | both | both | both | `rope.rs:1447-1464` |
| `DimensionPair<K,V>` | key; `Some(V::zero)` | key always; value if `Some` | both | both | `rope.rs:1589-1723` |
| `Unclipped<T>` | `T::zero` | forwards to `T` | - | - | `unclipped.rs:13-23` |

`TextDimension` (`rope.rs:1439-1445`) adds `from_text_summary`, `from_chunk`, `add_assign`.
Seeking and ordering use the **first** component (`Dimensions`) or `key` (`DimensionPair`, `rope.rs:1606-1631`). `DimensionPair` add, when RHS value is `None`, clears LHS value (`1648-1663`). `Point += DimensionPair<Point,_>` adds only the key (`1665-1669`).

---

## 3. The SumTree dependency

`Rope { chunks: SumTree<Chunk> }` (`rope.rs:25-28`). Clone must be cheap and share structure. The port needs a persistent (or cheaply sliceable and appendable) balanced tree of chunks whose internal nodes cache `ChunkSummary`.

Operations `rope.rs` uses:

- `extent::<D>(())`, `summary()`, `first()`, `last()`: whole-tree dimension, summary, end chunks (`317-329, 105-109, 286`).
- `update_last(f)`, `update_first(f)`: mutate an end chunk and refresh its summary (`148, 249, 290`). On an empty tree these are no-ops (inferred: `push` on an empty rope works).
- `push`, `extend`, `par_extend`, `append(tree)` (`198, 238, 272, 117, 119`).
- `find::<D>(&target, Bias) -> (start, end, Option<&Chunk>)`: `Left` on an exact boundary returns the **earlier** chunk; `Right` returns the later one. `overshoot = target - start`.
- Cursor `D`: `new` is positioned **before item 0** (`did_seek = false`, `cursor.rs:64-71`). `next()` (`cursor.rs:291-294`) moves onto item 0 first. `start()` is the dimension at the item start. `seek(t, bias)`, `seek_forward(t, bias)` move onto the item containing `t` (`423-431`). `slice(t, bias)` returns items from the current item up to `t`; `suffix()` = `slice(End)` (`432-450`). `summary::<O>(t, bias)` sums without building a tree (`452+`). `prev()` (`216`).

---

## 4. Rope public API

Each entry: signature, then algorithm.

### 4.1 Construction, length

- `new()` (`rope.rs:31-33`): empty tree. `From<&str>` = `new()` + `push` (`621-627`). `From<String>`, `From<&String>` via `&str` (`639-651`). `FromIterator<&str>` pushes each piece (`629-637`).
- `len()` = `extent::<usize>` (`316-318`); `is_empty()` (`320-322`); `summary()` = `chunks.summary().text` (`312-314`); `max_point()` = `extent::<Point>` (`324-326`); `max_point_utf16()` = `extent::<PointUtf16>` (`328-330`).
- `Display` concatenates chunks; `Debug` prints a quoted escaped form (`653-676`).

### 4.2 Char boundaries

- `is_char_boundary(o) -> bool` (`rope.rs:42-50`): empty tree gives `o == 0`; else `find(o, Left)` then `chunk.is_char_boundary(o - start)`; `None` gives false. `o == len` is a boundary.
- `assert_char_boundary::<PANIC>(o) -> bool` (`rope.rs:52-80`): panics if `PANIC`, else logs and returns false, when out of bounds or mid-scalar.
- `floor_char_boundary(i)` (`rope.rs:82-91`): `i >= len` gives `len`; else `start + chunk.floor(i - start)`.
- `ceil_char_boundary(i)` (`rope.rs:93-102`): `i > len` gives `len`; else analogous with `ceil`.
- `clip_offset(o, bias)` (`rope.rs:536-541`): `Left` = floor, `Right` = ceil. **Char** boundaries.

### 4.3 `append(rope)` (`rope.rs:104-122`)

```
if let first = rope.chunks.first()
   and (self.chunks.last().len < MIN_BASE or first.len < MIN_BASE):
    push_chunk(first.as_slice())                    // merge seam
    c = rope.chunks.cursor(); c.next(); c.next()    // now before/at item 1
    self.chunks.append(c.suffix())                  // items 1.. appended whole
else:
    self.chunks.append(rope.chunks)
check_invariants()
```
Because a fresh cursor sits before item 0, the first `next()` lands on item 0 (already merged) and the second on item 1. `suffix()` starts at item 1, so nothing is duplicated. The merge repairs only the seam.

`push_tree` does not exist on `Rope`. The only match is an internal aggregate method in sum_tree (`sum_tree/src/cursor.rs:512, 757, 778`).

### 4.4 Slicing and replacement

- `slice(range)` (`rope.rs:134-138`): `c = cursor(0); c.seek_forward(start); c.slice(end)`.
- `slice_rows(Range<u32>)` (`rope.rs:140-145`): byte range from `point_to_offset((r,0))`.
- `replace(range, text)` (`rope.rs:124-132`):
```
new = Rope::new(); c = cursor(0)
new.append(c.slice(range.start))
c.seek_forward(range.end)
new.push(text)
new.append(c.suffix())
self = new
```
Preconditions are asserted inside `slice`/`seek_forward`.

`Cursor` (`rope.rs:678-784`):
- `new(rope, o)` (`685-693`): `chunks.seek(o, Right)`.
- `seek_forward(e)` (`695-709`): asserts `offset <= e <= len`, then `chunks.seek_forward(e, Right)`.
- `slice(e) -> Rope` (`711-743`):
```
out = Rope::new()
if item = chunks.item():  out.push_chunk(item.slice(offset - start .. min(e, end) - start))
if e > chunks.end():
    chunks.next()
    out.append(Rope { chunks: chunks.slice(e, Right) })     // whole middle chunks
    if item = chunks.item(): out.push_chunk(item.slice(0 .. e - start))
offset = e
```
- `summary::<D>(e) -> D` (`745-775`): same control flow, accumulating `D::from_chunk(partial)` and `chunks.summary(e, Right)`.
- `suffix()` = `slice(extent)` (`777-779`); `offset()` (`781-783`).

### 4.5 Iteration

- `chars()` = `chars_at(0)`; `chars_at(s)` = `chunks_in_range(s..len).flat_map(chars)` (`rope.rs:336-342`); `reversed_chars_at(s)` = `reversed_chunks_in_range(0..s)` with each chunk's chars reversed (`344-347`).
- `bytes_in_range(r)`, `reversed_bytes_in_range(r)` (`349-355`); `chunks()`, `chunks_in_range(r)`, `reversed_chunks_in_range(r)` (`357-367`).

**Chunks** (`rope.rs:797-1103`): fields `chunks` cursor, `range`, `offset`, `reversed`.
- `new(rope, r, rev)` (`806-825`): reversed seeks `r.end` with `Left`; forward seeks `r.start` with `Right`. Asserts the start is a char boundary.
- `offset_is_valid` (`827-837`): forward `start <= off < end`; reversed `start < off <= end`.
- `seek(off)` (`843-861`): clamps to range, then seeks forward/back only as needed.
- `set_range(r)` (`863-866`).
- `peek()` and `peek_bytes()` (`964-974`): current chunk slice clipped to `range`. `peek_bytes` may cut inside a scalar. `current_chunk` (`976-994`): forward `[off-cs, min(end, range.end)-cs)`; reversed `[max(cs, range.start)-cs, off-cs)`.
- `peek_with_bitmaps()` (`997-1013`): `text` plus `chars`, `tabs`, `newlines` shifted right by the slice start. Bits past the slice end are not masked.
- `next()` (`1084-1103`): forward `off += len`, then `chunks.next()` if `off >= end`; reversed `off -= len`, then `chunks.prev()` if `off <= start`.
- `next_line()` (`876-908`, forward only): move past the next `'\n'` in range; return true if found and `<= range.end`; else go to range end. Skips newline-free chunks via `search_forward(lines.row > 0)`.
- `prev_line()` (`917-962`, reverse only): go to the start of the current line, or of the previous line if already at a start. Returns true only if the target is in range.
- `lines()` (`1015-1023`) and `equals_str(s)` (`1025-1057`, allocation-free; reversed compares from the end; byte lengths must match).

**Bytes** (`rope.rs:1105-1182`): `peek()` returns chunk bytes clipped to range. It returns `None` when `range.end <= chunk_start` (forward) or `range.start >= chunk end` (reversed). `next()` advances the chunk cursor. `io::Read::read` copies `min(buf, chunk)` bytes and advances range/chunk, reversing the tail for reversed reads.

**Lines** (`rope.rs:1184-1251`): a lending iterator, not `std::iter::Iterator`. `next() -> ?&str` returns a borrowed chunk sub-slice when the line fits in one chunk, else a buffer assembled across chunks. Trailing `'\n'` gives a final `""` forward and a first `""` reversed (tested, section 6).

### 4.6 Offset and point conversions

"find" below is `find::<D>(t, Left)`, `overshoot = t - start`, result `= start.result + chunk_result(overshoot)`, with the default when `item` is `None`.

- `offset_to_offset_utf16(o)` (`369-381`): `o >= len` gives `len_utf16`; else find on `Dimensions<usize,OffsetUtf16>`.
- `offset_utf16_to_offset(u)` (`383-395`): mirror image. **No clipping.**
- `offset_to_point(o)` (`397-409`): `o >= len` gives `lines`; else find on `<usize, Point>`.
- `offset_to_point_utf16(o)` (`411-423`): `o >= len` gives `lines_utf16()`; else find on `<usize, PointUtf16>`.
- `point_to_point_utf16(p)` (`425-437`): `p >= lines` gives `lines_utf16()`; else find on `<Point, PointUtf16>`.
- `point_utf16_to_point(p)` (`439-452`): `p >= lines_utf16()` gives `lines`; else manual cursor on `<PointUtf16, Point>`, `seek(p, Left)`, then `start.1 + chunk.offset_to_point(chunk.point_utf16_to_offset(p - start.0, false))`.
- `point_to_offset(p)` (`454-464`): `p >= lines` gives `len`; else find on `<Point, usize>`. Column past the row is caught by `debug_panic` in the chunk and clamped in release (`chunk.rs:427-435`).
- `point_to_offset_utf16(p)` (`466-477`): manual cursor on `<Point, OffsetUtf16>`.
- `point_utf16_to_offset(p)` = `impl(p, clip=false)` (`479-481`); `unclipped_point_utf16_to_offset(Unclipped(p))` = `impl(p, clip=true)` (`487-489`). `impl` (`491-503`): `p >= lines_utf16()` gives `len`; else find on `<PointUtf16, usize>`.
- `point_utf16_to_offset_utf16(p)` and `_impl` (`483-485, 505-520`): manual cursor on `<PointUtf16, OffsetUtf16>`.
- `unclipped_point_utf16_to_point(Unclipped(p))` (`522-534`): find on `<PointUtf16, Point>` with `Unclipped(p - start)`.

### 4.7 Clipping

- `clip_offset_utf16(o, bias)` (`543-551`): `find::<OffsetUtf16>(o, **Right**)`; `start + chunk.clip_offset_utf16(o - start, bias)`; else `len_utf16`.
- `clip_point(p, bias)` (`553-561`): find on `Point`, `Right`; `start + chunk.clip_point(p - start, bias)` (grapheme-aware); else `lines`.
- `clip_point_utf16(Unclipped(p), bias)` (`563-571`): find on `PointUtf16`, `Right`; else `lines_utf16()`.
- `line_len(row)` (`615-618`) = `clip_point((row, u32::MAX), Left).column`.

`clip_offset` is char-based, `clip_point` is grapheme-based. Do not interchange them.

### 4.8 Prefix and suffix

`starts_with(p)` (`573-592`) and `ends_with(p)` (`594-613`): false if `p.len > len`; walk forward or reversed chunks, comparing with `chunk.get(..)`, which returns false rather than panicking on a non-boundary split.

### 4.9 Mutation: `push`, `push_large`, `push_chunk`, `push_front`

**`push(text)`** (`rope.rs:147-202`)

Phase 1, top up the last chunk (`update_last`, `148-168`):
```
if last.len + text.len <= MAX_BASE: split = text.len
else: split = min(MIN_BASE.saturating_sub(last.len), text.len)
      while !text.is_char_boundary(split): split += 1       // round UP
last.push_str(text[..split]); text = text[split..]
```
Phase 2 (`170-201`): if empty, `check_invariants` and return. If `text.len > NUM_CHUNKS*MAX_BASE - NUM_CHUNKS*4` (`183`), call `push_large`. Else cut into pieces of at most `MAX_BASE`, stepping **down** to a boundary (`189-197`), collect into an `ArrayVec<_, NUM_CHUNKS>`, and `extend` with `Chunk::new`.

Why the `NUM_CHUNKS` push cannot overflow (the `unwrap` at `195`): every piece except the last is at least `MAX_BASE - 3` bytes, because a step down is at most 3 bytes. `N+1` pieces would need `N*(MAX-3) < len <= N*(MAX-4)`, a contradiction.

Result: new chunks are `MAX_BASE` or `MAX_BASE - ≤3` bytes, except the last, which can be any size. No minimum is applied to new chunks.

**`push_large(text)`** (`rope.rs:205-246`): same cut rule, collected into a `Vec` sized `ceil(len / (MAX-3))`. If `>= PARALLEL_THRESHOLD` pieces, `par_extend`, else `extend`. Parallel only changes performance.

**`push_chunk(slice)`** (`rope.rs:248-274`): phase 1 as above, using `ChunkSlice::split_at` and `last.append`. The remainder is pushed as **one** chunk with no split (`271-273`). This is safe because the input is at most `MAX_BASE` bytes. The remainder may be small, and there is no merge with the next chunk.

**`push_front(text)`** (`rope.rs:276-296`):
```
if text empty: return
if self empty: push(text); return
if first.len + text.len <= MAX_BASE: update_first(prepend_str); return
suffix = mem::replace(self, Rope::from(text)); self.append(suffix)
```

**`check_invariants`** (`rope.rs:298-310`, test-only): every chunk except the last has `len + 3 >= MIN_BASE`.

**Chunk-size invariant.** Maintained by phase 1 of `push` and by the seam repair in `append`. It is a performance bound (few tiny chunks), not a correctness requirement, and it is not guaranteed across the whole rope.

---

## 5. Points, UTF-16 points, offsets, Unclipped

### 5.1 Point (`point.rs`)

- `{row: u32, column: u32}` (`9-12`); column is **bytes**. `MAX`, `new`, `zero`, `row_range`, `is_zero`, `saturating_sub` (`21-63`). `parse_str` (`44-51`).
- Ordering (`131-145`): row-major. On 64-bit it compares `(row << 32) | column` as `usize`. On 32-bit it is lexicographic. Either is the same order. Zig: pack to `u64` or use a tuple compare.
- Add (`74-84`): `if other.row == 0: (self.row, self.column + other.column)` else `(self.row + other.row, other.column)`. The second column is absolute.
- Sub (`94-106`, `debug_assert other <= self`): `if same row: (0, self.col - other.col)` else `(self.row - other.row, self.col)`.
- `AddAssign` follows the same rule in place (`114-123`). `&`-variants forward to the value versions (`66-112`).

This relative-point rule is what lets `Point` act as a dimension: summing `TextSummary.lines` values gives an absolute position.

### 5.2 PointUtf16 (`point_utf16.rs`)

Same as `Point`, with the column in UTF-16 units: fields (`6-10`), `MAX`, `new`, `zero`, `saturating_sub` (`12-37`), Add/Sub/AddAssign (`39-96`), ordering (`104-119`). Derives `Debug` (struct form). `Point` has a custom `Point(r:c)` form (`point.rs:14-18`).

### 5.3 OffsetUtf16 (`offset_utf16.rs`)

`struct OffsetUtf16(pub usize)` (`3-4`), derives `Ord`, `Default`. Add and AddAssign are plain. The `&Self` `Sub` variant has `debug_assert!(other <= self)` (`22-29`); the value variant does not (`31-37`).

### 5.4 Unclipped (`unclipped.rs`)

`struct Unclipped<T>(pub T)` (`4-5`), derives `Ord`, `Hash`, `Default`. `From<T>` (`7-11`). Dimension impl when `T: Dimension` (`13-23`) forwards to `T` so that `Unclipped<PointUtf16>` can be a seek key. Add/Sub/AddAssign/SubAssign forward to `T` (`25-51`).

`Unclipped` means "may fall inside a surrogate pair or past a row end." The `clip_*_utf16` functions take it. `point_utf16_to_offset` and `point_utf16_to_point` expect valid positions. Keep that split.

---

## 6. Tests

Random text comes from `util::RandomCharIter` (`rope.rs:1731`, `chunk.rs:825`), which is not in this crate. The port needs a deterministic generator mixing ASCII, multi-byte, 4-byte, `'\n'`, and `'\t'`. `#[gpui::test(iterations = N)]` runs N seeded iterations.

### 6.1 `chunk.rs`

- **test_random_chunks** (`827-856`, 100 iter): random string up to `MAX_BASE` bytes. `chars()` equals the bitmap from `char_indices` (`834-839`). `verify_chunk` on the full chunk, then on 10 random char-boundary slices.
- **test_split_chunk_slice** (`858-870`, 100): `split_at` at a random char offset including `len`; `verify_chunk` on both halves against `str::split_at`.
- **test_nth_set_bit_random** (`872-892`, 1000): random subset of `0..128` as `u128`; `nth_set_bit(n, k)` equals the k-th set index (1-based). The only 128-bit test in the crate's test build.
- **test_append_random_strings** (`908-922`, 1000): `str1` up to `MAX`; `str2` capped at `MAX - len1`; `append` a random char-boundary sub-slice of `str2`; `verify_chunk` against `str1 + sub`.
- **test_prepend_random_strings** (`924-940`, 1000): same with `prepend`; expects `sub + str1`.
- **test_point_utf16_to_offset_clips_to_correct_absolute_offset** (`1235-1248`): `"abc\nde"`. `(0,99)` clipped gives 3; `(1,99)` clipped gives 6 (absolute). Regression test for a row-relative result.

**verify_chunk** (`957-1233`) is the shared oracle. At every char start and at the end it checks: point and offset round-trips (byte, UTF-16, point-UTF-16, unclipped); `clip_point` identity at starts; for interior bytes of multi-byte chars, Left clips to start and Right to end; for the second UTF-16 unit of 4-byte chars, the same for `clip_point_utf16`, `unclipped_point_utf16_to_point`, and `clip_offset_utf16`; `len`, `len_utf16`, `lines`, `first/last_line_chars`, `last_line_len_utf16`, `longest_row` (strict-greater, earliest), and tab positions.

### 6.2 `rope.rs`

Helpers: `Rope::text()` (`2543-2551`) concatenates chunks; `clip_offset(text, o, bias)` (`2533-2541`) steps to a char boundary.

- **test_all_4_byte_chars** (`1738-1744`): 256 × `"🏀"` pushed; `text()` round-trips.
- **test_chunks_peek_bytes** (`1746-1780`): `"aи中🧘z"` × 128, ranges `0..len`, `1..len-1`, `0..2`. Forward and reversed seeks at every offset: `peek_bytes` non-empty, matches source bytes, within `range.end`; equals `peek()` at boundaries. `None` at range end (forward) or start (reversed). Empty rope is `None`.
- **test_clip** (`1782-1828`): on `"🧘"` (one 4-byte scalar, two UTF-16 units). Offsets, points, UTF-16 points and offsets clip Left and Right as the expected values in the file show (e.g. `clip_offset(1, Left)=0`, `(1, Right)=4`; `clip_point_utf16((0,1), Right)=(0,2)`).
- **test_prev_next_line** (`1830-1872`): `"abc\ndef\nghi\njkl"`. `next_line` lands on d, g, j, then false at end. `prev_line` walks back to a, then false. Range `5..7` with `seek(6)`: `prev_line` false, `next_line` false.
- **test_lines** (`1874-1919`): forward and reversed, with and without trailing `'\n'`; reversed trailing gives a first `""`.
- **test_random_rope** (`1921-2236`, 100 iter, `OPERATIONS` env default 10). **Main oracle.** Reference: a `String`. Each op picks clipped `start <= end` and 0-64 random chars, builds `actual` via `slice + push + seek_forward + suffix`, applies `replace_range` to `expected`, and asserts equality. Then 5 random ranges check:
  1. forward chunks and `bytes_in_range` read equal `expected[range]`; reversed chunks reversed equal it;
  2. `next_line` offsets equal every `'\n'`-after index in range (`1972-1989`);
  3. `prev_line` offsets equal the same set, with `start` added when the range starts at a line start, and `end` removed when it is the last start (`1991-2012`);
  4. random walk of 5 steps mixing `next_line`, `prev_line` (checked against `find`/`rfind`), re-seek, and `next()`, staying in `[start, end]` (`2014-2122`);
  5. **full sweep**: for every char index and `len`, `offset_to_point`, `offset_to_point_utf16`, `point_to_offset`, `point_utf16_to_offset`, `offset_to_offset_utf16`, `offset_utf16_to_offset` agree with an incremental model (`2128-2168`);
  6. **UTF-16 sweep**: for each unit index, `clip_offset_utf16(Left) <= (Right)` and both convert without panic; same for `clip_point_utf16` and `point_utf16_to_offset`, including mid-surrogate (`2170-2193`);
  7. `cursor(start).summary::<TextSummary>(end) == TextSummary::from(&expected[range])`, full struct (`2195-2202`);
  8. `line_len(row)` equals each `split('\n')` row length; `summary().longest_row` is **one of** the rows with maximal char count (set membership, ties allowed) (`2204-2234`).
- **test_chunks_equals_str** (`2238-2289`): for every substring of a multi-chunk string, `equals_str` is true for it (both directions) and false for every other non-equal substring. Empty rope cases.
- **test_starts_with**, **test_ends_with** (`2291-2323`): emoji string, prefixes and suffixes, a false match with extra trailing `!`.
- **test_starts_with_ends_with_random** (`2325-2357`, seed 0, 100 × 10): against `str::starts_with` and `ends_with` with boundary-aligned slices.
- **test_is_char_boundary**, **test_floor_char_boundary**, **test_ceil_char_boundary** (`2359-2418`): fixtures `"地"`, `""`, and an emoji-ZWJ string; every offset matches `str`.
- **test_push_front_empty_text_on_empty_rope** (`2420-2426`), **..._on_nonempty_rope** (`2428-2433`), **test_push_front_on_empty_rope** (`2435-2442`: `"hello"`, `len 5`, `max_point (0,5)`), **test_push_front_single_space** (`2444-2450`: `" hint"`).
- **test_push_front_random** (`2452-2509`, 50): 1-10 random prefixes; text, `len`, `len`, `lines`, `chars`, `longest_row` match `TextSummary::from`; `point_to_offset(offset_to_point(i)) == i` at every char start and `len`.
- **test_push_front_large_prefix** (`2511-2531`, 50): prefix of 64-256 chars, forcing the `append` path; text, `len`, `len`, `lines`, `chars` match `prefix + initial`.

### 6.3 Gaps

- `Rope::replace`, `push_chunk`: covered only through `test_random_rope`.
- `add_newline` is untested and wrong (section 7).
- Reversed `next_line` and `prev_line` are asserted to panic but not tested.
- The 128-bit chunk path is not exercised by the crate's test build.

---

## 7. Quirks and porting hazards

1. **`TextSummary::add_newline` is wrong** (`rope.rs:1326-1332`). `self.len_utf16 += OffsetUtf16(self.len_utf16.0 + 1)` computes `2*len_utf16 + 1`. It has no call site in the crate and does not update `first_line_chars` or `longest_row`. Do not port it. Use `summary += TextSummary::newline()`.
2. **Char vs grapheme clipping.** `clip_offset` and `clip_offset_utf16` are char-based. `clip_point`, `clip_point_utf16`, and `line_len` (via `clip_point`) are grapheme-based (section 1.6). Grapheme segmentation needs Unicode data. Until it is ported, document `clip_point` as char-only and list that as a limit (AGENTS.md).
3. **Out-of-range inputs.** `point_to_offset` and `point_to_offset_utf16` require valid columns. They `debug_panic` in debug and clamp in release (`chunk.rs:427-435`). `clip_*` functions accept anything. Keep that split.
4. **`offset_utf16_to_offset` does not clip** (`rope.rs:383-395`). Mid-surrogate input yields a non-boundary offset.
5. **`clip` flag** in `point_utf16_to_offset` only controls the debug panic; mid-scalar columns always step left (`chunk.rs:547-551`).
6. **Reversed `next_line`/`prev_line` panic** (`rope.rs:877, 918`, `assert!(!reversed)`). Keep that or return an error; never return wrong results.
7. **Full-width shifts.** Guard every shift that can reach `MAX_BASE` (section 1.2).
8. **`Chunk::new` and `Into<Chunk>` panic** via `unwrap` if the input exceeds `MAX_BASE` (`chunk.rs:52, 233`). Port as an error or assert, not truncation.
9. **`push_chunk` does not split its remainder** (`rope.rs:271-273`). Safe only because the input is a `ChunkSlice`.
10. **Ties in `longest_row`** use strict `>` throughout (`rope.rs:1363, 1405, 1409`; `chunk.rs:385, 400`): the earliest row wins. Keep it. It is used as a tie-break elsewhere in Zed.
11. **Parallel extend** (`rope.rs:237-243`) changes timing only.
12. **`is_utf8_char_boundary`** is "not a continuation byte" (`gpui_util/src/lib.rs:158-161`). Use that predicate.
13. **Point ordering is row-major everywhere** (`point.rs:131-145`).
14. **`Bytes::peek` boundary checks differ by direction** (`rope.rs:1128-1134`). Port both exactly.
15. **`Lines` is not an `Iterator`.** Expose `next(self) ?[]const u8`, valid until the next call.
16. **`chars` in `TextSummary` counts `'\n'`.** The tests depend on it (`chunk.rs:1172-1232`, `rope.rs:2198-2201`).

---

## 8. Zig translation notes

1. **Comptime width.** `fn Chunk(comptime max_base: usize) type` with `Bitmap = std.meta.Int(.unsigned, max_base)`. Use `u16` for 16 and `u128` for 128, so one implementation serves tests and production.
2. **Bit helpers.** `shlOrZero`, `shrOrZero`, `@popCount`, `@ctz`, `@clz`. Verify zero-input behavior in Zig 0.17.
3. **Summaries.** `TextSummary` is a plain struct; `addAssign(self: *TextSummary, other: TextSummary)` holds all of section 2.3. Test it against the `From(&str)` path, as `test_random_rope` step 7 does.
4. **Dimensions.** Generate per-dimension functions at comptime. `Dimensions<A,B>` is a two-field struct that compares on `A`.
5. **Tree.** A flat array of chunks with linear scans is a correct but not complexity-faithful first port. Record it as a deviation in the feature-limits notes (AGENTS.md).
6. **Errors.** Return errors where a caller can recover. Use `std.debug.assert` for invariant checks that match Rust's `debug_panic`.
7. **Test matrix.** Run the randomized tests at widths 16 and 128 with a seeded `std.Random.DefaultPrng` and fixed iteration counts. Print the seed on failure.
8. **Module placement.** Follow `docs/STRUCTURE.md`. The rope belongs in the `src/text/` set, which must not depend on SDL, Zafi, or rendering.

---

## 9. Absent items and files not read

- `Rope::push_tree`: absent. Use `Rope::append` (section 4.3).
- `Rope::text_summary_for_range`: absent from this crate. Editor and multi-buffer snapshots define methods of that name. The rope-level equivalent is `cursor(start).summary::<TextSummary>(end)` (section 4.4).
- `Rope::lines`: absent. Use `Chunks::lines()` (section 4.5) and `TextSummary.lines`.
- `Rope::chars`: present as `chars()` and `chars_at()` (section 4.5).
- Not read: `rope/benches/rope_benchmark.rs`; `gpui_util`, `sum_tree`, and `util` beyond the lines cited above.
