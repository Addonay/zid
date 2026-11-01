//! Port of Zed's `rope::Chunk` / `ChunkSlice` (`.ref/zed/crates/rope/src/chunk.rs`).
//!
//! A chunk holds up to `max_base` bytes of UTF-8 plus bitmaps marking char starts,
//! UTF-16 units, newlines and tabs, so offset/point conversions are popcounts.
//! Like Zed, tests use 16-byte chunks (`u16` bitmaps) to exercise chunk boundaries.
//!
//! Limitation: Zed clips points to grapheme boundaries with `unicode-segmentation`.
//! This port clips to code point boundaries (TODO(grapheme)).
const std = @import("std");
const builtin = @import("builtin");
const Bias = @import("../sum_tree/sum_tree.zig").Bias;
const point = @import("point.zig");
const Point = point.Point;
const PointUtf16 = point.PointUtf16;
const OffsetUtf16 = point.OffsetUtf16;
const TextSummary = @import("rope.zig").TextSummary;

pub const Bitmap = if (builtin.is_test) u16 else u128;
pub const bits = @bitSizeOf(Bitmap);
pub const max_base: usize = bits;
pub const min_base: usize = max_base / 2;
const Shift = std.math.Log2Int(Bitmap);

inline fn shl(value: Bitmap, amount: usize) Bitmap {
    return if (amount >= bits) 0 else value << @as(Shift, @intCast(amount));
}

inline fn shr(value: Bitmap, amount: usize) Bitmap {
    return if (amount >= bits) 0 else value >> @as(Shift, @intCast(amount));
}

/// `(1 << offset) - 1`, saturating to all ones.
inline fn lowMask(offset: usize) Bitmap {
    return shl(1, offset) -% 1;
}

/// `!(MAX >> offset)`.
inline fn highMask(offset: usize) Bitmap {
    return ~shr(std.math.maxInt(Bitmap), offset);
}

inline fn popCount(value: Bitmap) u32 {
    return @popCount(value);
}

pub inline fn isUtf8CharBoundary(byte: u8) bool {
    // Equivalent to `(byte as i8) >= -0x40`.
    return (byte & 0xC0) != 0x80;
}

pub fn strIsCharBoundary(text: []const u8, index: usize) bool {
    if (index == 0 or index == text.len) return true;
    if (index > text.len) return false;
    return isUtf8CharBoundary(text[index]);
}

pub fn strFloorCharBoundary(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    var i = index;
    while (i > 0 and !isUtf8CharBoundary(text[i])) i -= 1;
    return i;
}

pub fn strCeilCharBoundary(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    var i = index;
    while (i < text.len and !isUtf8CharBoundary(text[i])) i += 1;
    return i;
}

pub const Chunk = struct {
    /// Bit i set: byte i starts a UTF-8 character.
    chars: Bitmap = 0,
    /// Popcount is the UTF-16 length; a 4-byte character also sets bit i+1.
    chars_utf16: Bitmap = 0,
    newlines: Bitmap = 0,
    tabs: Bitmap = 0,
    buf: [max_base]u8 = undefined,
    len: u8 = 0,

    pub const Summary = ChunkSummary;

    pub fn summary(self: *const Chunk, _: void) ChunkSummary {
        return .{ .text = self.asSlice().textSummary() };
    }

    pub fn text(self: *const Chunk) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn new(source: []const u8) Chunk {
        std.debug.assert(source.len <= max_base);
        var chunk: Chunk = .{};
        @memcpy(chunk.buf[0..source.len], source);
        chunk.len = @intCast(source.len);
        var four_byte: Bitmap = 0;
        for (source, 0..) |byte, ix| {
            const bit = shl(1, ix);
            if (isUtf8CharBoundary(byte)) chunk.chars |= bit;
            if (byte == '\n') chunk.newlines |= bit;
            if (byte == '\t') chunk.tabs |= bit;
            // A first byte >= 240 encodes U+10000 or above: two UTF-16 units.
            if (byte >= 240) four_byte |= bit;
        }
        chunk.chars_utf16 = shl(four_byte, 1) | chunk.chars;
        return chunk;
    }

    pub fn fromSlice(source: ChunkSlice) Chunk {
        var chunk: Chunk = .{ .chars = source.chars, .chars_utf16 = source.chars_utf16, .newlines = source.newlines, .tabs = source.tabs };
        @memcpy(chunk.buf[0..source.text.len], source.text);
        chunk.len = @intCast(source.text.len);
        return chunk;
    }

    pub fn pushStr(self: *Chunk, source: []const u8) void {
        self.append(Chunk.new(source).asSlice());
    }

    pub fn prependStr(self: *Chunk, source: []const u8) void {
        const prefix = Chunk.new(source);
        self.prepend(prefix.asSlice());
    }

    pub fn append(self: *Chunk, other: ChunkSlice) void {
        if (other.isEmpty()) return;
        const base_ix: usize = self.len;
        std.debug.assert(base_ix + other.text.len <= max_base);
        self.chars |= shl(other.chars, base_ix);
        self.chars_utf16 |= shl(other.chars_utf16, base_ix);
        self.newlines |= shl(other.newlines, base_ix);
        self.tabs |= shl(other.tabs, base_ix);
        @memcpy(self.buf[base_ix..][0..other.text.len], other.text);
        self.len += @intCast(other.text.len);
    }

    pub fn prepend(self: *Chunk, other: ChunkSlice) void {
        if (other.isEmpty()) return;
        if (self.len == 0) {
            self.* = Chunk.fromSlice(other);
            return;
        }
        const shift = other.text.len;
        std.debug.assert(shift + self.len <= max_base);
        self.chars = other.chars | shl(self.chars, shift);
        self.chars_utf16 = other.chars_utf16 | shl(self.chars_utf16, shift);
        self.newlines = other.newlines | shl(self.newlines, shift);
        self.tabs = other.tabs | shl(self.tabs, shift);
        std.mem.copyBackwards(u8, self.buf[shift..][0..self.len], self.buf[0..self.len]);
        @memcpy(self.buf[0..shift], other.text);
        self.len += @intCast(shift);
    }

    pub fn asSlice(self: *const Chunk) ChunkSlice {
        return .{ .chars = self.chars, .chars_utf16 = self.chars_utf16, .newlines = self.newlines, .tabs = self.tabs, .text = self.text() };
    }

    pub fn slice(self: *const Chunk, start: usize, end: usize) ChunkSlice {
        return self.asSlice().slice(start, end);
    }

    pub fn isCharBoundary(self: *const Chunk, offset: usize) bool {
        return (shl(1, offset) & self.chars) != 0 or offset == self.len;
    }

    pub fn floorCharBoundary(self: *const Chunk, index: usize) usize {
        return strFloorCharBoundary(self.text(), index);
    }
};

pub const ChunkSlice = struct {
    chars: Bitmap,
    chars_utf16: Bitmap,
    newlines: Bitmap,
    tabs: Bitmap,
    text: []const u8,

    pub const empty: ChunkSlice = .{ .chars = 0, .chars_utf16 = 0, .newlines = 0, .tabs = 0, .text = "" };

    pub fn isEmpty(self: ChunkSlice) bool {
        return self.text.len == 0;
    }

    pub fn isCharBoundary(self: ChunkSlice, offset: usize) bool {
        return (shl(1, offset) & self.chars) != 0 or offset == self.text.len;
    }

    pub fn splitAt(self: ChunkSlice, mid: usize) struct { ChunkSlice, ChunkSlice } {
        if (mid == max_base) return .{ self, empty };
        const mask = lowMask(mid);
        return .{
            .{ .chars = self.chars & mask, .chars_utf16 = self.chars_utf16 & mask, .newlines = self.newlines & mask, .tabs = self.tabs & mask, .text = self.text[0..mid] },
            .{ .chars = shr(self.chars, mid), .chars_utf16 = shr(self.chars_utf16, mid), .newlines = shr(self.newlines, mid), .tabs = shr(self.tabs, mid), .text = self.text[mid..] },
        };
    }

    pub fn slice(self: ChunkSlice, range_start: usize, range_end: usize) ChunkSlice {
        if (range_start == max_base) return empty;
        var start = range_start;
        var end = range_end;
        // Zed logs and rounds misaligned ranges in release builds.
        if (!self.isCharBoundary(start)) {
            std.debug.assert(false);
            start = strCeilCharBoundary(self.text, start);
        }
        if (!self.isCharBoundary(end)) {
            std.debug.assert(false);
            end = if (end < start) start else strFloorCharBoundary(self.text, end);
        }
        const mask = lowMask(end);
        return .{
            .chars = shr(self.chars & mask, start),
            .chars_utf16 = shr(self.chars_utf16 & mask, start),
            .newlines = shr(self.newlines & mask, start),
            .tabs = shr(self.tabs & mask, start),
            .text = self.text[start..end],
        };
    }

    pub fn textSummary(self: ChunkSlice) TextSummary {
        var chars: usize = 0;
        const longest = self.longestRow(&chars);
        return .{
            .len = self.len(),
            .chars = chars,
            .len_utf16 = self.lenUtf16(),
            .lines = self.lines(),
            .first_line_chars = self.firstLineChars(),
            .last_line_chars = self.lastLineChars(),
            .last_line_len_utf16 = self.lastLineLenUtf16(),
            .longest_row = longest.row,
            .longest_row_chars = longest.chars,
        };
    }

    pub fn len(self: ChunkSlice) usize {
        return self.text.len;
    }

    pub fn lenUtf16(self: ChunkSlice) OffsetUtf16 {
        return .{ .value = popCount(self.chars_utf16) };
    }

    /// Rows, and the byte length of the last line.
    pub fn lines(self: ChunkSlice) Point {
        const row = popCount(self.newlines);
        const column = @as(u32, @clz(self.newlines)) - @as(u32, @intCast(bits - self.text.len));
        return .{ .row = row, .column = column };
    }

    pub fn firstLineChars(self: ChunkSlice) u32 {
        return popCount(self.chars & lowMask(@ctz(self.newlines)));
    }

    pub fn lastLineChars(self: ChunkSlice) u32 {
        return popCount(self.chars & highMask(@clz(self.newlines)));
    }

    pub fn lastLineLenUtf16(self: ChunkSlice) u32 {
        return popCount(self.chars_utf16 & highMask(@clz(self.newlines)));
    }

    pub fn longestRow(self: ChunkSlice, total_chars: *usize) struct { row: u32, chars: u32 } {
        var chars = self.chars;
        var newlines = self.newlines;
        total_chars.* = 0;
        var row: u32 = 0;
        var longest_row: u32 = 0;
        var longest_row_chars: u32 = 0;
        while (newlines > 0) {
            const newline_ix: usize = @ctz(newlines);
            const row_chars = popCount(chars & lowMask(newline_ix));
            total_chars.* += row_chars;
            if (row_chars > longest_row_chars) {
                longest_row = row;
                longest_row_chars = row_chars;
            }
            newlines = shr(shr(newlines, newline_ix), 1);
            chars = shr(shr(chars, newline_ix), 1);
            row += 1;
            total_chars.* += 1;
        }
        const row_chars = popCount(chars);
        total_chars.* += row_chars;
        if (row_chars > longest_row_chars) return .{ .row = row, .chars = row_chars };
        return .{ .row = longest_row, .chars = longest_row_chars };
    }

    pub fn offsetToPoint(self: ChunkSlice, offset: usize) Point {
        const mask = lowMask(offset);
        const row = popCount(self.newlines & mask);
        const newline_ix = bits - @as(usize, @clz(self.newlines & mask));
        return .{ .row = row, .column = @intCast(offset - newline_ix) };
    }

    pub fn pointToOffset(self: ChunkSlice, target: Point) usize {
        if (target.row > self.lines().row) {
            std.debug.assert(false);
            return self.len();
        }
        const row_range = self.offsetRangeForRow(target.row);
        if (target.column > row_range.end - row_range.start) {
            std.debug.assert(false);
            return row_range.end;
        }
        return row_range.start + target.column;
    }

    pub fn floorCharBoundary(self: ChunkSlice, index: usize) usize {
        return strFloorCharBoundary(self.text, index);
    }

    pub fn pointToOffsetUtf16(self: ChunkSlice, target: Point) OffsetUtf16 {
        if (target.row > self.lines().row) {
            std.debug.assert(false);
            return self.lenUtf16();
        }
        return self.offsetToOffsetUtf16(self.pointToOffset(target));
    }

    pub fn offsetToOffsetUtf16(self: ChunkSlice, offset: usize) OffsetUtf16 {
        return .{ .value = popCount(self.chars_utf16 & lowMask(offset)) };
    }

    pub fn offsetUtf16ToOffset(self: ChunkSlice, target: OffsetUtf16) usize {
        if (target.value == 0) return 0;
        const ix = nthSetBit(self.chars_utf16, target.value) + 1;
        if (ix == max_base) return max_base;
        const additional = @min(@as(usize, @ctz(shr(self.chars_utf16, ix))), self.text.len - ix);
        return ix + additional;
    }

    pub fn offsetToPointUtf16(self: ChunkSlice, offset: usize) PointUtf16 {
        const mask = lowMask(offset);
        const row = popCount(self.newlines & mask);
        const newline_ix = bits - @as(usize, @clz(self.newlines & mask));
        const column: u32 = if (newline_ix == max_base) 0 else popCount(shr(self.chars_utf16 & mask, newline_ix));
        return .{ .row = row, .column = column };
    }

    pub fn pointToPointUtf16(self: ChunkSlice, target: Point) PointUtf16 {
        return self.offsetToPointUtf16(self.pointToOffset(target));
    }

    pub fn pointUtf16ToOffset(self: ChunkSlice, target: PointUtf16, clip: bool) usize {
        const max_lines = self.lines();
        if (target.row > max_lines.row) {
            if (!clip) std.debug.assert(false);
            return self.len();
        }
        const row_range = self.offsetRangeForRow(target.row);
        const line = self.slice(row_range.start, row_range.end);
        if (target.column > line.lastLineLenUtf16()) {
            if (!clip) std.debug.assert(false);
            return row_range.end;
        }
        var offset = row_range.start;
        if (target.column > 0) {
            offset += line.offsetUtf16ToOffset(.{ .value = target.column });
            if (!strIsCharBoundary(self.text, offset)) {
                offset -= 1;
                while (!strIsCharBoundary(self.text, offset)) offset -= 1;
                if (!clip) std.debug.assert(false);
            }
        }
        return offset;
    }

    pub fn unclippedPointUtf16ToPoint(self: ChunkSlice, target: PointUtf16) Point {
        const max_point = self.lines();
        if (target.row > max_point.row) return max_point;
        const row_range = self.offsetRangeForRow(target.row);
        const line = self.slice(row_range.start, row_range.end);
        if (target.column == 0) return .{ .row = target.row, .column = 0 };
        if (target.column >= line.lenUtf16().value) return .{ .row = target.row, .column = @intCast(line.len()) };
        var column = line.offsetUtf16ToOffset(.{ .value = target.column });
        while (!strIsCharBoundary(line.text, column)) column -= 1;
        return .{ .row = target.row, .column = @intCast(column) };
    }

    pub fn clipPoint(self: ChunkSlice, target: Point, bias: Bias) Point {
        const max_point = self.lines();
        if (target.row > max_point.row) return max_point;
        const row_range = self.offsetRangeForRow(target.row);
        const line = self.slice(row_range.start, row_range.end);
        if (target.column == 0) return target;
        if (target.column >= line.len()) return .{ .row = target.row, .column = @intCast(line.len()) };
        var column: usize = target.column;
        const bytes = line.text;
        if (bytes[column - 1] < 128 and bytes[column] < 128) return .{ .row = target.row, .column = @intCast(column) };
        // TODO(grapheme): Zed also requires a grapheme cluster boundary here.
        while (!line.isCharBoundary(column)) {
            switch (bias) {
                .left => column -= 1,
                .right => column += 1,
            }
        }
        return .{ .row = target.row, .column = @intCast(column) };
    }

    pub fn clipPointUtf16(self: ChunkSlice, target: PointUtf16, bias: Bias) PointUtf16 {
        const max_point = self.lines();
        if (target.row > max_point.row) return .{ .row = max_point.row, .column = self.lastLineLenUtf16() };
        const row_range = self.offsetRangeForRow(target.row);
        const line = self.slice(row_range.start, row_range.end);
        const column = line.clipOffsetUtf16(.{ .value = target.column }, bias);
        return .{ .row = target.row, .column = @intCast(column.value) };
    }

    pub fn clipOffsetUtf16(self: ChunkSlice, target: OffsetUtf16, bias: Bias) OffsetUtf16 {
        if (target.value == 0) return .{};
        const length = self.lenUtf16();
        if (target.value >= length.value) return length;
        var offset = self.offsetUtf16ToOffset(target);
        while (!strIsCharBoundary(self.text, offset)) {
            if (bias == .left) offset -= 1 else offset += 1;
        }
        return self.offsetToOffsetUtf16(offset);
    }

    pub fn offsetRangeForRow(self: ChunkSlice, row: u32) struct { start: usize, end: usize } {
        const row_start: usize = if (row > 0) nthSetBit(self.newlines, row) + 1 else 0;
        const row_len: usize = if (row_start == max_base) 0 else @min(@as(usize, @ctz(shr(self.newlines, row_start))), self.text.len - row_start);
        return .{ .start = row_start, .end = row_start + row_len };
    }

    pub fn tabPositions(self: ChunkSlice) Tabs {
        return .{ .tabs = self.tabs, .chars = self.chars };
    }
};

pub const TabPosition = struct { byte_offset: usize, char_offset: usize };

pub const Tabs = struct {
    tabs: Bitmap,
    chars: Bitmap,

    pub fn next(self: *Tabs) ?TabPosition {
        if (self.tabs == 0) return null;
        const tab_offset: usize = @ctz(self.tabs);
        const char_offset = popCount(self.chars & lowMask(tab_offset));
        self.tabs ^= shl(1, tab_offset);
        return .{ .byte_offset = tab_offset, .char_offset = char_offset };
    }
};

pub const ChunkSummary = struct {
    text: TextSummary = .{},

    pub fn zero(_: void) ChunkSummary {
        return .{};
    }

    pub fn addSummary(self: *ChunkSummary, other: *const ChunkSummary, _: void) void {
        self.text.addAssign(&other.text);
    }

    /// `impl Dimension<ChunkSummary> for usize` (byte offset).
    pub fn dimensionZero(comptime D: type, _: void) D {
        comptime std.debug.assert(D == usize);
        return 0;
    }

    pub fn addToDimension(comptime D: type, dimension: *D, summary: *const ChunkSummary, _: void) void {
        comptime std.debug.assert(D == usize);
        dimension.* += summary.text.len;
    }
};

/// Index of the n-th (1-based) set bit (`nth_set_bit`).
pub fn nthSetBit(value: Bitmap, n: usize) usize {
    const v: u128 = value;
    const low: u64 = @truncate(v);
    const high: u64 = @truncate(v >> 64);
    const low_count: usize = @popCount(low);
    if (n > low_count) return 64 + nthSetBitU64(high, n - low_count);
    return nthSetBitU64(low, n);
}

fn nthSetBitU64(value: u64, n_in: usize) usize {
    const v = @bitReverse(value);
    var s: u64 = 64;
    var n: u64 = n_in;
    const max = std.math.maxInt(u64);

    // Parallel bit count intermediates
    const a = v -% ((v >> 1) & (max / 3));
    const b = (a & (max / 5)) +% ((a >> 2) & (max / 5));
    const c = (b +% (b >> 4)) & (max / 0x11);
    const d = (c +% (c >> 8)) & (max / 0x101);

    // Branchless select
    var t = (d >> 32) +% (d >> 48);
    s -%= (t -% n & 256) >> 3;
    n -%= t & ((t -% n) >> 8);

    t = (d >> @intCast(s - 16)) & 0xff;
    s -%= (t -% n & 256) >> 4;
    n -%= t & ((t -% n) >> 8);

    t = (c >> @intCast(s - 8)) & 0xf;
    s -%= (t -% n & 256) >> 5;
    n -%= t & ((t -% n) >> 8);

    t = (b >> @intCast(s - 4)) & 0x7;
    s -%= (t -% n & 256) >> 6;
    n -%= t & ((t -% n) >> 8);

    t = (a >> @intCast(s - 2)) & 0x3;
    s -%= (t -% n & 256) >> 7;
    n -%= t & ((t -% n) >> 8);

    t = (v >> @intCast(s - 1)) & 0x1;
    s -%= (t -% n & 256) >> 8;

    return @intCast(65 - s - 1);
}
