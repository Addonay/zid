//! Port of Zed's `rope` crate (`.ref/zed/crates/rope/src/rope.rs`). Spec: docs/zed_port/rope.md.
//!
//! A `Rope` is a SumTree of `Chunk`s. Clones are O(1) and share structure. Every
//! allocating call takes the allocator explicitly; `deinit` releases one reference.
//! Iterators and cursors borrow the rope and must not outlive it or survive a move.
//! Not ported: parallel building (`par_extend`), `io::Read` for `Bytes`, `Display`.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const st = @import("../sum_tree/sum_tree.zig");
pub const Bias = st.Bias;
pub const chunk = @import("chunk.zig");
pub const point = @import("point.zig");
pub const Chunk = chunk.Chunk;
pub const ChunkSlice = chunk.ChunkSlice;
pub const ChunkSummary = chunk.ChunkSummary;
pub const Point = point.Point;
pub const PointUtf16 = point.PointUtf16;
pub const OffsetUtf16 = point.OffsetUtf16;
pub const Unclipped = point.Unclipped;
pub const Bitmap = chunk.Bitmap;

const Tree = st.SumTree(Chunk);
const Dims = st.Dimensions;

/// Summary of a string of text.
pub const TextSummary = struct {
    /// Length in bytes.
    len: usize = 0,
    /// Length in chars.
    chars: usize = 0,
    /// Length in UTF-16 code units.
    len_utf16: OffsetUtf16 = .{},
    /// Rows, and the byte length of the last line.
    lines: Point = .{},
    first_line_chars: u32 = 0,
    last_line_chars: u32 = 0,
    last_line_len_utf16: u32 = 0,
    longest_row: u32 = 0,
    longest_row_chars: u32 = 0,

    pub fn linesUtf16(self: TextSummary) PointUtf16 {
        return .{ .row = self.lines.row, .column = self.last_line_len_utf16 };
    }

    pub fn newline() TextSummary {
        return .{ .len = 1, .chars = 1, .len_utf16 = .{ .value = 1 }, .lines = .{ .row = 1, .column = 0 } };
    }

    /// Faithful to Zed, including its `len_utf16 += len_utf16 + 1` (rope.rs:1328).
    pub fn addNewline(self: *TextSummary) void {
        self.len += 1;
        self.len_utf16.value += self.len_utf16.value + 1;
        self.last_line_chars = 0;
        self.last_line_len_utf16 = 0;
        self.lines = self.lines.add(.{ .row = 1, .column = 0 });
    }

    /// `impl From<&str> for TextSummary`.
    pub fn fromStr(text: []const u8) TextSummary {
        var summary: TextSummary = .{ .len = text.len };
        var view = std.unicode.Utf8View.initUnchecked(text);
        var it = view.iterator();
        while (it.nextCodepoint()) |c| {
            const utf16_len: u32 = if (c >= 0x10000) 2 else 1;
            summary.chars += 1;
            summary.len_utf16.value += utf16_len;
            if (c == '\n') {
                summary.lines = summary.lines.add(.{ .row = 1, .column = 0 });
                summary.last_line_len_utf16 = 0;
                summary.last_line_chars = 0;
            } else {
                summary.lines.column += std.unicode.utf8CodepointSequenceLength(c) catch 1;
                summary.last_line_len_utf16 += utf16_len;
                summary.last_line_chars += 1;
            }
            if (summary.lines.row == 0) summary.first_line_chars = summary.last_line_chars;
            if (summary.last_line_chars > summary.longest_row_chars) {
                summary.longest_row = summary.lines.row;
                summary.longest_row_chars = summary.last_line_chars;
            }
        }
        return summary;
    }

    pub fn addAssign(self: *TextSummary, other: *const TextSummary) void {
        const joined_chars = self.last_line_chars + other.first_line_chars;
        if (joined_chars > self.longest_row_chars) {
            self.longest_row = self.lines.row;
            self.longest_row_chars = joined_chars;
        }
        if (other.longest_row_chars > self.longest_row_chars) {
            self.longest_row = self.lines.row + other.longest_row;
            self.longest_row_chars = other.longest_row_chars;
        }
        if (self.lines.row == 0) self.first_line_chars += other.first_line_chars;
        if (other.lines.row == 0) {
            self.last_line_chars += other.first_line_chars;
            self.last_line_len_utf16 += other.last_line_len_utf16;
        } else {
            self.last_line_chars = other.last_line_chars;
            self.last_line_len_utf16 = other.last_line_len_utf16;
        }
        self.chars += other.chars;
        self.len += other.len;
        self.len_utf16.value += other.len_utf16.value;
        self.lines = self.lines.add(other.lines);
    }

    pub fn plus(self: TextSummary, other: TextSummary) TextSummary {
        var result = self;
        result.addAssign(&other);
        return result;
    }

    pub fn eql(a: TextSummary, b: TextSummary) bool {
        return std.meta.eql(a, b);
    }

    // Summary of itself, and dimension of ChunkSummary.
    pub fn zero(_: anytype) TextSummary {
        return .{};
    }

    pub fn addSummary(self: *TextSummary, other: anytype, _: anytype) void {
        self.addAssign(&point.textOf(other));
    }
};

/// Zed's `TextDimension` trait: dimensions computable from a chunk slice or summary.
pub fn TextDimension(comptime D: type) type {
    return struct {
        pub fn zero() D {
            return st.dimensionZero(ChunkSummary, D, {});
        }

        pub fn fromTextSummary(summary: *const TextSummary) D {
            if (D == usize) return summary.len;
            if (D == OffsetUtf16) return summary.len_utf16;
            if (D == Point) return summary.lines;
            if (D == PointUtf16) return summary.linesUtf16();
            if (D == TextSummary) return summary.*;
            if (@hasDecl(D, "is_dimensions")) return .{ .d1 = TextDimension(D.First).fromTextSummary(summary), .d2 = TextDimension(@FieldType(D, "d2")).fromTextSummary(summary), .d3 = {} };
            return D.fromTextSummary(summary);
        }

        pub fn fromChunk(slice: ChunkSlice) D {
            if (D == usize) return slice.len();
            if (D == OffsetUtf16) return slice.lenUtf16();
            if (D == Point) return slice.lines();
            if (D == PointUtf16) return .{ .row = slice.lines().row, .column = slice.lastLineLenUtf16() };
            if (D == TextSummary) return slice.textSummary();
            if (@hasDecl(D, "is_dimensions")) return .{ .d1 = TextDimension(D.First).fromChunk(slice), .d2 = TextDimension(@FieldType(D, "d2")).fromChunk(slice), .d3 = {} };
            return D.fromChunk(slice);
        }

        pub fn addAssign(self: *D, other: *const D) void {
            if (D == usize) {
                self.* += other.*;
            } else if (D == TextSummary) {
                self.addAssign(other);
            } else if (D == Point or D == PointUtf16 or D == OffsetUtf16) {
                self.* = self.add(other.*);
            } else if (@hasDecl(D, "is_dimensions")) {
                TextDimension(D.First).addAssign(&self.d1, &other.d1);
                TextDimension(@FieldType(D, "d2")).addAssign(&self.d2, &other.d2);
            } else self.addAssign(other);
        }
    };
}

pub const Rope = struct {
    chunks: Tree,

    pub fn init(gpa: Allocator) Allocator.Error!Rope {
        return .{ .chunks = try Tree.init(gpa, {}) };
    }

    pub fn fromStr(gpa: Allocator, text: []const u8) Allocator.Error!Rope {
        var rope = try init(gpa);
        errdefer rope.deinit(gpa);
        try rope.push(gpa, text);
        return rope;
    }

    pub fn deinit(self: *Rope, gpa: Allocator) void {
        self.chunks.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: *const Rope) Rope {
        return .{ .chunks = self.chunks.clone() };
    }

    pub fn isCharBoundary(self: *const Rope, offset: usize) bool {
        if (self.chunks.isEmpty()) return offset == 0;
        const found = self.chunks.find(usize, {}, offset, .left);
        const item = found.item orelse return false;
        return item.isCharBoundary(offset - found.start);
    }

    pub fn floorCharBoundary(self: *const Rope, index: usize) usize {
        if (index >= self.len()) return self.len();
        const found = self.chunks.find(usize, {}, index, .left);
        const item = found.item orelse return self.len();
        return found.start + chunk.strFloorCharBoundary(item.text(), index - found.start);
    }

    pub fn ceilCharBoundary(self: *const Rope, index: usize) usize {
        if (index > self.len()) return self.len();
        const found = self.chunks.find(usize, {}, index, .left);
        const item = found.item orelse return self.len();
        return found.start + chunk.strCeilCharBoundary(item.text(), index - found.start);
    }

    /// Appends `other`, taking ownership of it.
    pub fn append(self: *Rope, gpa: Allocator, other: Rope) Allocator.Error!void {
        var owned = other;
        if (owned.chunks.first()) |first_chunk| {
            const merge = if (self.chunks.last()) |last| last.len < chunk.min_base else false;
            if (merge or first_chunk.len < chunk.min_base) {
                defer owned.deinit(gpa);
                try self.pushChunk(gpa, first_chunk.asSlice());
                var c = owned.chunks.cursor(void, {});
                c.next();
                c.next();
                try self.chunks.append(gpa, try c.suffix(gpa), {});
                self.checkInvariants();
                return;
            }
        }
        try self.chunks.append(gpa, owned.chunks, {});
        self.checkInvariants();
    }

    pub fn replace(self: *Rope, gpa: Allocator, start: usize, end: usize, text: []const u8) Allocator.Error!void {
        var new_rope = try Rope.init(gpa);
        errdefer new_rope.deinit(gpa);
        var cur = Cursor.init(self, 0);
        try new_rope.append(gpa, try cur.slice(gpa, start));
        cur.seekForward(end);
        try new_rope.push(gpa, text);
        try new_rope.append(gpa, try cur.suffix(gpa));
        self.deinit(gpa);
        self.* = new_rope;
    }

    pub fn slice(self: *const Rope, gpa: Allocator, start: usize, end: usize) Allocator.Error!Rope {
        var c = Cursor.init(self, 0);
        c.seekForward(start);
        return c.slice(gpa, end);
    }

    pub fn sliceRows(self: *const Rope, gpa: Allocator, start_row: u32, end_row: u32) Allocator.Error!Rope {
        const start = self.pointToOffset(.{ .row = start_row, .column = 0 });
        const end = self.pointToOffset(.{ .row = end_row, .column = 0 });
        return self.slice(gpa, start, end);
    }

    const num_chunks: usize = if (builtin.is_test) 16 else 4;

    pub fn push(self: *Rope, gpa: Allocator, text_in: []const u8) Allocator.Error!void {
        var text = text_in;
        const Updater = struct {
            text: *[]const u8,
            pub fn update(updater: @This(), last_chunk: *Chunk) void {
                const remaining = updater.text.*;
                const split_ix = if (last_chunk.len + remaining.len <= chunk.max_base) remaining.len else blk: {
                    var ix = @min(chunk.min_base -| last_chunk.len, remaining.len);
                    while (!chunk.strIsCharBoundary(remaining, ix)) ix += 1;
                    break :blk ix;
                };
                last_chunk.pushStr(remaining[0..split_ix]);
                updater.text.* = remaining[split_ix..];
            }
        };
        try self.chunks.updateLast(gpa, {}, Updater{ .text = &text });
        if (text.len == 0) {
            self.checkInvariants();
            return;
        }

        // Up to `num_chunks` full chunks, each possibly cut short by a split character.
        if (text.len > num_chunks * chunk.max_base - num_chunks * 4) return self.pushLarge(gpa, text);

        var new_chunks: [num_chunks]Chunk = undefined;
        var count: usize = 0;
        while (text.len > 0) {
            var split_ix = @min(chunk.max_base, text.len);
            while (!chunk.strIsCharBoundary(text, split_ix)) split_ix -= 1;
            new_chunks[count] = Chunk.new(text[0..split_ix]);
            count += 1;
            text = text[split_ix..];
        }
        try self.chunks.extend(gpa, new_chunks[0..count], {});
        self.checkInvariants();
    }

    fn pushLarge(self: *Rope, gpa: Allocator, text_in: []const u8) Allocator.Error!void {
        var text = text_in;
        // Worst case: each chunk loses 3 bytes to a 4-byte character split.
        const min_chunk_size = chunk.max_base - 3;
        var new_chunks = try std.ArrayList(Chunk).initCapacity(gpa, std.math.divCeil(usize, text.len, min_chunk_size) catch unreachable);
        defer new_chunks.deinit(gpa);
        while (text.len > 0) {
            var split_ix = @min(chunk.max_base, text.len);
            while (!chunk.strIsCharBoundary(text, split_ix)) split_ix -= 1;
            try new_chunks.append(gpa, Chunk.new(text[0..split_ix]));
            text = text[split_ix..];
        }
        try self.chunks.extend(gpa, new_chunks.items, {});
        self.checkInvariants();
    }

    fn pushChunk(self: *Rope, gpa: Allocator, slice_in: ChunkSlice) Allocator.Error!void {
        var remaining = slice_in;
        const Updater = struct {
            slice: *ChunkSlice,
            pub fn update(updater: @This(), last_chunk: *Chunk) void {
                const s = updater.slice.*;
                const split_ix = if (last_chunk.len + s.len() <= chunk.max_base) s.len() else blk: {
                    var ix = @min(chunk.min_base -| last_chunk.len, s.len());
                    while (!s.isCharBoundary(ix)) ix += 1;
                    break :blk ix;
                };
                const parts = s.splitAt(split_ix);
                last_chunk.append(parts[0]);
                updater.slice.* = parts[1];
            }
        };
        try self.chunks.updateLast(gpa, {}, Updater{ .slice = &remaining });
        if (!remaining.isEmpty()) try self.chunks.push(gpa, Chunk.fromSlice(remaining), {});
    }

    pub fn pushFront(self: *Rope, gpa: Allocator, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;
        if (self.isEmpty()) return self.push(gpa, text);
        if (self.chunks.first()) |first_chunk| {
            if (first_chunk.len + text.len <= chunk.max_base) {
                const Updater = struct {
                    text: []const u8,
                    pub fn update(updater: @This(), first: *Chunk) void {
                        first.prependStr(updater.text);
                    }
                };
                try self.chunks.updateFirst(gpa, {}, Updater{ .text = text });
                self.checkInvariants();
                return;
            }
        }
        const suffix = self.*;
        self.* = try Rope.fromStr(gpa, text);
        try self.append(gpa, suffix);
    }

    fn checkInvariants(self: *const Rope) void {
        if (!builtin.is_test) return;
        // All chunks except maybe the last one are not underflowing, allowing for
        // multibyte characters at chunk boundaries.
        var it = self.chunks.iter();
        var previous: ?*const Chunk = null;
        while (it.next()) |item| {
            if (previous) |p| std.debug.assert(p.len + 3 >= chunk.min_base);
            previous = item;
        }
    }

    pub fn summary(self: *const Rope) TextSummary {
        return self.chunks.summary().text;
    }

    pub fn len(self: *const Rope) usize {
        return self.chunks.summary().text.len;
    }

    pub fn isEmpty(self: *const Rope) bool {
        return self.len() == 0;
    }

    pub fn maxPoint(self: *const Rope) Point {
        return self.chunks.summary().text.lines;
    }

    pub fn maxPointUtf16(self: *const Rope) PointUtf16 {
        return self.chunks.summary().text.linesUtf16();
    }

    pub fn cursor(self: *const Rope, offset: usize) Cursor {
        return Cursor.init(self, offset);
    }

    pub fn chunksInRange(self: *const Rope, start: usize, end: usize) Chunks {
        return Chunks.init(self, start, end, false);
    }

    pub fn reversedChunksInRange(self: *const Rope, start: usize, end: usize) Chunks {
        return Chunks.init(self, start, end, true);
    }

    pub fn chunksAll(self: *const Rope) Chunks {
        return self.chunksInRange(0, self.len());
    }

    pub fn bytesInRange(self: *const Rope, start: usize, end: usize) Bytes {
        return Bytes.init(self, start, end, false);
    }

    pub fn reversedBytesInRange(self: *const Rope, start: usize, end: usize) Bytes {
        return Bytes.init(self, start, end, true);
    }

    pub fn charsAt(self: *const Rope, start: usize) Chars {
        return .{ .chunks = self.chunksInRange(start, self.len()), .reversed = false };
    }

    pub fn chars(self: *const Rope) Chars {
        return self.charsAt(0);
    }

    pub fn reversedCharsAt(self: *const Rope, start: usize) Chars {
        return .{ .chunks = self.reversedChunksInRange(0, start), .reversed = true };
    }

    /// Writes the whole text into a new allocation.
    pub fn toOwnedString(self: *const Rope, gpa: Allocator) Allocator.Error![]u8 {
        var out = try std.ArrayList(u8).initCapacity(gpa, self.len());
        var it = self.chunksAll();
        while (it.next()) |text| out.appendSliceAssumeCapacity(text);
        return out.toOwnedSlice(gpa);
    }

    pub fn offsetToOffsetUtf16(self: *const Rope, offset: usize) OffsetUtf16 {
        if (offset >= self.summary().len) return self.summary().len_utf16;
        const found = self.chunks.find(Dims(usize, OffsetUtf16, void), {}, offset, .left);
        const overshoot = offset - found.start.d1;
        return found.start.d2.add(if (found.item) |c| c.asSlice().offsetToOffsetUtf16(overshoot) else .{});
    }

    pub fn offsetUtf16ToOffset(self: *const Rope, offset: OffsetUtf16) usize {
        if (offset.value >= self.summary().len_utf16.value) return self.summary().len;
        const found = self.chunks.find(Dims(OffsetUtf16, usize, void), {}, offset, .left);
        const overshoot = offset.sub(found.start.d1);
        return found.start.d2 + if (found.item) |c| c.asSlice().offsetUtf16ToOffset(overshoot) else 0;
    }

    pub fn offsetToPoint(self: *const Rope, offset: usize) Point {
        if (offset >= self.summary().len) return self.summary().lines;
        const found = self.chunks.find(Dims(usize, Point, void), {}, offset, .left);
        const overshoot = offset - found.start.d1;
        return found.start.d2.add(if (found.item) |c| c.asSlice().offsetToPoint(overshoot) else .{});
    }

    pub fn offsetToPointUtf16(self: *const Rope, offset: usize) PointUtf16 {
        if (offset >= self.summary().len) return self.summary().linesUtf16();
        const found = self.chunks.find(Dims(usize, PointUtf16, void), {}, offset, .left);
        const overshoot = offset - found.start.d1;
        return found.start.d2.add(if (found.item) |c| c.asSlice().offsetToPointUtf16(overshoot) else .{});
    }

    pub fn pointToPointUtf16(self: *const Rope, target: Point) PointUtf16 {
        if (target.cmp(&self.summary().lines) != .lt) return self.summary().linesUtf16();
        const found = self.chunks.find(Dims(Point, PointUtf16, void), {}, target, .left);
        const overshoot = target.sub(found.start.d1);
        return found.start.d2.add(if (found.item) |c| c.asSlice().pointToPointUtf16(overshoot) else .{});
    }

    pub fn pointUtf16ToPoint(self: *const Rope, target: PointUtf16) Point {
        if (target.cmp(&self.summary().linesUtf16()) != .lt) return self.summary().lines;
        var c = self.chunks.cursor(Dims(PointUtf16, Point, void), {});
        _ = c.seek(target, .left);
        const overshoot = target.sub(c.start().d1);
        return c.start().d2.add(if (c.item()) |item| item.asSlice().offsetToPoint(item.asSlice().pointUtf16ToOffset(overshoot, false)) else .{});
    }

    pub fn pointToOffset(self: *const Rope, target: Point) usize {
        if (target.cmp(&self.summary().lines) != .lt) return self.summary().len;
        const found = self.chunks.find(Dims(Point, usize, void), {}, target, .left);
        const overshoot = target.sub(found.start.d1);
        return found.start.d2 + if (found.item) |c| c.asSlice().pointToOffset(overshoot) else 0;
    }

    pub fn pointToOffsetUtf16(self: *const Rope, target: Point) OffsetUtf16 {
        if (target.cmp(&self.summary().lines) != .lt) return self.summary().len_utf16;
        var c = self.chunks.cursor(Dims(Point, OffsetUtf16, void), {});
        _ = c.seek(target, .left);
        const overshoot = target.sub(c.start().d1);
        return c.start().d2.add(if (c.item()) |item| item.asSlice().pointToOffsetUtf16(overshoot) else .{});
    }

    pub fn pointUtf16ToOffset(self: *const Rope, target: PointUtf16) usize {
        return self.pointUtf16ToOffsetImpl(target, false);
    }

    pub fn pointUtf16ToOffsetUtf16(self: *const Rope, target: PointUtf16) OffsetUtf16 {
        return self.pointUtf16ToOffsetUtf16Impl(target, false);
    }

    pub fn unclippedPointUtf16ToOffset(self: *const Rope, target: Unclipped(PointUtf16)) usize {
        return self.pointUtf16ToOffsetImpl(target.value, true);
    }

    fn pointUtf16ToOffsetImpl(self: *const Rope, target: PointUtf16, clip: bool) usize {
        if (target.cmp(&self.summary().linesUtf16()) != .lt) return self.summary().len;
        const found = self.chunks.find(Dims(PointUtf16, usize, void), {}, target, .left);
        const overshoot = target.sub(found.start.d1);
        return found.start.d2 + if (found.item) |c| c.asSlice().pointUtf16ToOffset(overshoot, clip) else 0;
    }

    fn pointUtf16ToOffsetUtf16Impl(self: *const Rope, target: PointUtf16, clip: bool) OffsetUtf16 {
        if (target.cmp(&self.summary().linesUtf16()) != .lt) return self.summary().len_utf16;
        var c = self.chunks.cursor(Dims(PointUtf16, OffsetUtf16, void), {});
        _ = c.seek(target, .left);
        const overshoot = target.sub(c.start().d1);
        return c.start().d2.add(if (c.item()) |item| item.asSlice().offsetToOffsetUtf16(item.asSlice().pointUtf16ToOffset(overshoot, clip)) else .{});
    }

    pub fn unclippedPointUtf16ToPoint(self: *const Rope, target: Unclipped(PointUtf16)) Point {
        if (target.value.cmp(&self.summary().linesUtf16()) != .lt) return self.summary().lines;
        const found = self.chunks.find(Dims(PointUtf16, Point, void), {}, target.value, .left);
        const overshoot = target.value.sub(found.start.d1);
        return found.start.d2.add(if (found.item) |c| c.asSlice().unclippedPointUtf16ToPoint(overshoot) else .{});
    }

    pub fn clipOffset(self: *const Rope, offset: usize, bias: Bias) usize {
        return switch (bias) {
            .left => self.floorCharBoundary(offset),
            .right => self.ceilCharBoundary(offset),
        };
    }

    pub fn clipOffsetUtf16(self: *const Rope, offset: OffsetUtf16, bias: Bias) OffsetUtf16 {
        const found = self.chunks.find(OffsetUtf16, {}, offset, .right);
        const item = found.item orelse return self.summary().len_utf16;
        return found.start.add(item.asSlice().clipOffsetUtf16(offset.sub(found.start), bias));
    }

    pub fn clipPoint(self: *const Rope, target: Point, bias: Bias) Point {
        const found = self.chunks.find(Point, {}, target, .right);
        const item = found.item orelse return self.summary().lines;
        return found.start.add(item.asSlice().clipPoint(target.sub(found.start), bias));
    }

    pub fn clipPointUtf16(self: *const Rope, target: Unclipped(PointUtf16), bias: Bias) PointUtf16 {
        const found = self.chunks.find(PointUtf16, {}, target.value, .right);
        const item = found.item orelse return self.summary().linesUtf16();
        return found.start.add(item.asSlice().clipPointUtf16(target.value.sub(found.start), bias));
    }

    pub fn startsWith(self: *const Rope, pattern: []const u8) bool {
        if (pattern.len > self.len()) return false;
        var remaining = pattern;
        var it = self.chunksAll();
        while (it.next()) |text| {
            const n = @min(remaining.len, text.len);
            if (!std.mem.eql(u8, remaining[0..n], text[0..n])) return false;
            remaining = remaining[n..];
            if (remaining.len == 0) return true;
        }
        return remaining.len == 0;
    }

    pub fn endsWith(self: *const Rope, pattern: []const u8) bool {
        if (pattern.len > self.len()) return false;
        var remaining = pattern;
        var it = self.reversedChunksInRange(0, self.len());
        while (it.next()) |text| {
            const n = @min(remaining.len, text.len);
            if (!std.mem.eql(u8, remaining[remaining.len - n ..], text[text.len - n ..])) return false;
            remaining = remaining[0 .. remaining.len - n];
            if (remaining.len == 0) return true;
        }
        return remaining.len == 0;
    }

    pub fn lineLen(self: *const Rope, row: u32) u32 {
        return self.clipPoint(.{ .row = row, .column = std.math.maxInt(u32) }, .left).column;
    }

    pub fn eqlStr(self: *const Rope, other: []const u8) bool {
        var it = self.chunksAll();
        return it.equalsStr(other);
    }
};

pub const Cursor = struct {
    rope: *const Rope,
    chunks: Tree.Cursor(usize),
    offset: usize,

    pub fn init(rope: *const Rope, offset: usize) Cursor {
        var chunks = rope.chunks.cursor(usize, {});
        _ = chunks.seek(offset, .right);
        return .{ .rope = rope, .chunks = chunks, .offset = offset };
    }

    pub fn seekForward(self: *Cursor, end_offset: usize) void {
        std.debug.assert(end_offset >= self.offset);
        std.debug.assert(end_offset <= self.rope.len());
        _ = self.chunks.seekForward(end_offset, .right);
        self.offset = end_offset;
    }

    pub fn slice(self: *Cursor, gpa: Allocator, end_offset: usize) Allocator.Error!Rope {
        std.debug.assert(end_offset >= self.offset);
        std.debug.assert(end_offset <= self.rope.len());
        var result = try Rope.init(gpa);
        errdefer result.deinit(gpa);
        if (self.chunks.item()) |start_chunk| {
            const start_ix = self.offset - self.chunks.start().*;
            const end_ix = @min(end_offset, self.chunks.end()) - self.chunks.start().*;
            try result.pushChunk(gpa, start_chunk.slice(start_ix, end_ix));
        }
        if (end_offset > self.chunks.end()) {
            self.chunks.next();
            try result.append(gpa, .{ .chunks = try self.chunks.slice(gpa, end_offset, .right) });
            if (self.chunks.item()) |end_chunk| {
                const end_ix = end_offset - self.chunks.start().*;
                try result.pushChunk(gpa, end_chunk.slice(0, end_ix));
            }
        }
        self.offset = end_offset;
        return result;
    }

    pub fn summary(self: *Cursor, comptime D: type, end_offset: usize) D {
        std.debug.assert(end_offset >= self.offset);
        std.debug.assert(end_offset <= self.rope.len());
        const TD = TextDimension(D);
        var result = TD.zero();
        if (self.chunks.item()) |start_chunk| {
            const start_ix = self.offset - self.chunks.start().*;
            const end_ix = @min(end_offset, self.chunks.end()) - self.chunks.start().*;
            TD.addAssign(&result, &TD.fromChunk(start_chunk.slice(start_ix, end_ix)));
        }
        if (end_offset > self.chunks.end()) {
            self.chunks.next();
            TD.addAssign(&result, &self.chunks.summary(D, end_offset, .right));
            if (self.chunks.item()) |end_chunk| {
                const end_ix = end_offset - self.chunks.start().*;
                TD.addAssign(&result, &TD.fromChunk(end_chunk.slice(0, end_ix)));
            }
        }
        self.offset = end_offset;
        return result;
    }

    pub fn suffix(self: *Cursor, gpa: Allocator) Allocator.Error!Rope {
        return self.slice(gpa, self.rope.len());
    }

    pub fn getOffset(self: *const Cursor) usize {
        return self.offset;
    }
};

pub const ChunkBitmaps = struct {
    text: []const u8,
    chars: Bitmap,
    tabs: Bitmap,
    newlines: Bitmap,
};

pub const Chunks = struct {
    chunks: Tree.Cursor(usize),
    range_start: usize,
    range_end: usize,
    offset: usize,
    reversed: bool,

    pub fn init(rope: *const Rope, start: usize, end: usize, reversed: bool) Chunks {
        var chunks = rope.chunks.cursor(usize, {});
        const offset = if (reversed) blk: {
            _ = chunks.seek(end, .left);
            break :blk end;
        } else blk: {
            _ = chunks.seek(start, .right);
            break :blk start;
        };
        if (chunks.item()) |item| std.debug.assert(item.isCharBoundary(offset - chunks.start().*));
        return .{ .chunks = chunks, .range_start = start, .range_end = end, .offset = offset, .reversed = reversed };
    }

    fn offsetIsValid(self: *const Chunks) bool {
        if (self.reversed) return !(self.offset <= self.range_start or self.offset > self.range_end);
        return !(self.offset < self.range_start or self.offset >= self.range_end);
    }

    pub fn getOffset(self: *const Chunks) usize {
        return self.offset;
    }

    pub fn seek(self: *Chunks, offset_in: usize) void {
        const offset = std.math.clamp(offset_in, self.range_start, self.range_end);
        if (self.reversed) {
            if (offset > self.chunks.end()) {
                _ = self.chunks.seekForward(offset, .left);
            } else if (offset <= self.chunks.start().*) {
                _ = self.chunks.seek(offset, .left);
            }
        } else {
            if (offset >= self.chunks.end()) {
                _ = self.chunks.seekForward(offset, .right);
            } else if (offset < self.chunks.start().*) {
                _ = self.chunks.seek(offset, .right);
            }
        }
        self.offset = offset;
    }

    pub fn setRange(self: *Chunks, start: usize, end: usize) void {
        self.range_start = start;
        self.range_end = end;
        self.seek(start);
    }

    fn rowsFilter(summary: *const ChunkSummary) bool {
        return summary.text.lines.row > 0;
    }

    /// Moves to the start of the next line; false if already at the end.
    pub fn nextLine(self: *Chunks) bool {
        std.debug.assert(!self.reversed);
        var found = false;
        if (self.peek()) |text| {
            if (std.mem.indexOfScalar(u8, text, '\n')) |newline_ix| {
                self.offset += newline_ix + 1;
                found = self.offset <= self.range_end;
            } else {
                self.chunks.searchForward(&rowsFilter);
                self.offset = self.chunks.start().*;
                if (self.peek()) |next_text| {
                    if (std.mem.indexOfScalar(u8, next_text, '\n')) |newline_ix| {
                        self.offset += newline_ix + 1;
                        found = self.offset <= self.range_end;
                    } else self.offset = self.chunks.end();
                } else self.offset = self.chunks.end();
            }
            if (self.offset == self.chunks.end()) _ = self.next();
        }
        if (self.offset > self.range_end) {
            self.offset = @min(self.offset, self.range_end);
            _ = self.chunks.seek(self.offset, .right);
        }
        return found;
    }

    /// Moves to the start of the current line, or of the previous line when already
    /// at a line start.
    pub fn prevLine(self: *Chunks) bool {
        std.debug.assert(!self.reversed);
        const initial_offset = self.offset;
        if (self.offset == self.chunks.start().*) self.chunks.prev();
        if (self.chunks.item()) |item| {
            var end_ix = self.offset - self.chunks.start().*;
            if (item.text()[end_ix - 1] == '\n') end_ix -= 1;
            if (std.mem.lastIndexOfScalar(u8, item.text()[0..end_ix], '\n')) |newline_ix| {
                self.offset = self.chunks.start().* + newline_ix + 1;
                if (self.offsetIsValid()) return true;
            }
        }
        self.chunks.searchBackward(&rowsFilter);
        self.offset = self.chunks.start().*;
        if (self.chunks.item()) |item| {
            if (std.mem.lastIndexOfScalar(u8, item.text(), '\n')) |newline_ix| {
                self.offset += newline_ix + 1;
                if (self.offsetIsValid()) {
                    if (self.offset == self.chunks.end()) self.chunks.next();
                    return true;
                }
            }
        }
        if (!self.offsetIsValid() or self.chunks.item() == null) {
            self.offset = self.range_start;
            _ = self.chunks.seek(self.offset, .right);
        }
        return self.offset < initial_offset and self.offset == 0;
    }

    const Current = struct { item: *const Chunk, start: usize, end: usize };

    fn currentChunk(self: *const Chunks) ?Current {
        if (!self.offsetIsValid()) return null;
        const item = self.chunks.item() orelse return null;
        const chunk_start = self.chunks.start().*;
        if (self.reversed) return .{ .item = item, .start = @max(chunk_start, self.range_start) - chunk_start, .end = self.offset - chunk_start };
        return .{ .item = item, .start = self.offset - chunk_start, .end = @min(self.chunks.end(), self.range_end) - chunk_start };
    }

    pub fn peek(self: *const Chunks) ?[]const u8 {
        const current = self.currentChunk() orelse return null;
        return current.item.text()[current.start..current.end];
    }

    /// Same as `peek`; Zed distinguishes `&str` from `&[u8]`.
    pub fn peekBytes(self: *const Chunks) ?[]const u8 {
        return self.peek();
    }

    pub fn peekWithBitmaps(self: *const Chunks) ?ChunkBitmaps {
        const current = self.currentChunk() orelse return null;
        const shift: std.math.Log2Int(Bitmap) = @intCast(current.start);
        return .{
            .text = current.item.text()[current.start..current.end],
            .chars = current.item.chars >> shift,
            .tabs = current.item.tabs >> shift,
            .newlines = current.item.newlines >> shift,
        };
    }

    fn advance(self: *Chunks, length: usize) void {
        if (self.reversed) {
            self.offset -= length;
            if (self.offset <= self.chunks.start().*) self.chunks.prev();
        } else {
            self.offset += length;
            if (self.offset >= self.chunks.end()) self.chunks.next();
        }
    }

    pub fn next(self: *Chunks) ?[]const u8 {
        const text = self.peek() orelse return null;
        self.advance(text.len);
        return text;
    }

    pub fn nextWithBitmaps(self: *Chunks) ?ChunkBitmaps {
        const bitmaps = self.peekWithBitmaps() orelse return null;
        self.advance(bitmaps.text.len);
        return bitmaps;
    }

    pub fn equalsStr(self: *const Chunks, other: []const u8) bool {
        var it = self.*;
        if (it.reversed) {
            var offset = other.len;
            while (it.next()) |text| {
                if (!std.mem.endsWith(u8, other[0..offset], text)) return false;
                offset -= text.len;
            }
            return offset == 0;
        }
        var offset: usize = 0;
        while (it.next()) |text| {
            if (offset >= other.len) return false;
            if (!std.mem.startsWith(u8, other[offset..], text)) return false;
            offset += text.len;
        }
        return offset == other.len;
    }

    pub fn lines(self: Chunks) Lines {
        return .{ .chunks = self, .reversed = self.reversed };
    }
};

pub const Bytes = struct {
    chunks: Tree.Cursor(usize),
    range_start: usize,
    range_end: usize,
    reversed: bool,

    pub fn init(rope: *const Rope, start: usize, end: usize, reversed: bool) Bytes {
        var chunks = rope.chunks.cursor(usize, {});
        if (reversed) _ = chunks.seek(end, .left) else _ = chunks.seek(start, .right);
        return .{ .chunks = chunks, .range_start = start, .range_end = end, .reversed = reversed };
    }

    pub fn peek(self: *const Bytes) ?[]const u8 {
        const item = self.chunks.item() orelse return null;
        if (self.reversed and self.range_start >= self.chunks.end()) return null;
        const chunk_start = self.chunks.start().*;
        if (self.range_end <= chunk_start) return null;
        const start = self.range_start -| chunk_start;
        const end = self.range_end - chunk_start;
        return item.text()[start..@min(item.len, end)];
    }

    pub fn next(self: *Bytes) ?[]const u8 {
        const result = self.peek() orelse return null;
        if (self.reversed) self.chunks.prev() else self.chunks.next();
        return result;
    }
};

/// Splits the chunk stream on `\n`. Lines that cross chunks are assembled in an
/// owned buffer, so `next` needs an allocator; the returned slice is valid until the
/// next call.
pub const Lines = struct {
    chunks: Chunks,
    current_line: std.ArrayList(u8) = .empty,
    done: bool = false,
    reversed: bool,

    pub fn deinit(self: *Lines, gpa: Allocator) void {
        self.current_line.deinit(gpa);
    }

    pub fn next(self: *Lines, gpa: Allocator) Allocator.Error!?[]const u8 {
        if (self.done) return null;
        self.current_line.clearRetainingCapacity();
        while (self.chunks.peek()) |text| {
            if (self.reversed) {
                const newline = std.mem.lastIndexOfScalar(u8, text, '\n');
                const chunk_line = if (newline) |ix| text[ix + 1 ..] else text;
                if (newline != null) {
                    self.chunks.seek(self.chunks.offset - chunk_line.len - 1);
                    if (self.current_line.items.len == 0) return chunk_line;
                }
                try self.current_line.insertSlice(gpa, 0, chunk_line);
                if (newline != null) return self.current_line.items;
            } else {
                const newline = std.mem.indexOfScalar(u8, text, '\n');
                const chunk_line = if (newline) |ix| text[0..ix] else text;
                if (newline != null) {
                    self.chunks.seek(self.chunks.offset + chunk_line.len + 1);
                    if (self.current_line.items.len == 0) return chunk_line;
                }
                try self.current_line.appendSlice(gpa, chunk_line);
                if (newline != null) return self.current_line.items;
            }
            _ = self.chunks.next();
        }
        self.done = true;
        return self.current_line.items;
    }

    pub fn seek(self: *Lines, offset: usize) void {
        self.chunks.seek(offset);
        self.current_line.clearRetainingCapacity();
        self.done = false;
    }

    pub fn getOffset(self: *const Lines) usize {
        return self.chunks.offset;
    }
};

/// Iterates code points forward or backward over a chunk range.
pub const Chars = struct {
    chunks: Chunks,
    reversed: bool,
    current: []const u8 = "",

    pub fn next(self: *Chars) ?u21 {
        while (self.current.len == 0) self.current = self.chunks.next() orelse return null;
        if (self.reversed) {
            var start = self.current.len - 1;
            while (start > 0 and !chunk.isUtf8CharBoundary(self.current[start])) start -= 1;
            const c = std.unicode.utf8Decode(self.current[start..]) catch 0xFFFD;
            self.current = self.current[0..start];
            return c;
        }
        const length = std.unicode.utf8ByteSequenceLength(self.current[0]) catch 1;
        const c = std.unicode.utf8Decode(self.current[0..length]) catch 0xFFFD;
        self.current = self.current[length..];
        return c;
    }
};

test {
    _ = @import("tests.zig");
    _ = point;
}
