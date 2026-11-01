//! Minimal port of Zed's `language` crate surface used by the display pipeline:
//! `Chunk`, `HighlightId`, `DiagnosticSeverity` and buffer chunk iteration
//! (`.ref/zed/crates/language/src/buffer.rs`, `language_core/src/highlight_map.rs`).
//!
//! Not ported yet: `language::Buffer` (syntax map, tree-sitter highlighting,
//! diagnostics, autoindent). Chunks currently carry no syntax highlights.
const std = @import("std");
const rope_mod = @import("../rope/rope.zig");
const text = @import("../text/zed/root.zig");

/// Zed's `HighlightId(NonZeroU32)`.
pub const HighlightId = enum(u32) {
    _,

    pub const tabstop_insert_id: HighlightId = @enumFromInt(std.math.maxInt(u32) - 1);
    pub const tabstop_replace_id: HighlightId = @enumFromInt(std.math.maxInt(u32) - 2);
};

/// LSP `DiagnosticSeverity` (1 = error ... 4 = hint).
pub const DiagnosticSeverity = enum(u8) {
    @"error" = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

/// Whether chunk styling uses syntax/diagnostic information (`LanguageAwareStyling`).
pub const LanguageAwareStyling = struct {
    tree_sitter: bool = true,
    diagnostics: bool = true,
};

/// A run of text with uniform styling. Bitmaps are always 128-bit, as in Zed, and
/// describe `text` from bit 0.
pub const Chunk = struct {
    text: []const u8 = "",
    syntax_highlight_id: ?HighlightId = null,
    /// Editor highlight style index; styles are resolved by the presentation layer.
    highlight_style: ?u32 = null,
    diagnostic_severity: ?DiagnosticSeverity = null,
    tabs: u128 = 0,
    chars: u128 = 0,
    newlines: u128 = 0,
    is_unnecessary: bool = false,
    is_tab: bool = false,
    is_inlay: bool = false,
    underline: bool = false,

    pub fn fromBitmaps(bitmaps: rope_mod.ChunkBitmaps) Chunk {
        return .{ .text = bitmaps.text, .tabs = bitmaps.tabs, .chars = bitmaps.chars, .newlines = bitmaps.newlines };
    }

    /// Splits off the first `split_index` bytes, shifting the bitmaps of the rest.
    pub fn splitPrefix(self: *Chunk, split_index: usize) Chunk {
        const mask = lowMask128(split_index);
        var prefix = self.*;
        prefix.text = self.text[0..split_index];
        prefix.chars = self.chars & mask;
        prefix.tabs = self.tabs & mask;
        prefix.newlines = self.newlines & mask;
        self.text = self.text[split_index..];
        self.chars = shr128(self.chars, split_index);
        self.tabs = shr128(self.tabs, split_index);
        self.newlines = shr128(self.newlines, split_index);
        return prefix;
    }
};

pub fn lowMask128(n: usize) u128 {
    return if (n >= 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(n)) - 1;
}

pub fn shr128(value: u128, n: usize) u128 {
    return if (n >= 128) 0 else value >> @intCast(n);
}

/// Iterates styled chunks of a text snapshot (`language::BufferChunks`). Without a
/// syntax map every chunk is unstyled.
pub const BufferChunks = struct {
    chunks: rope_mod.Chunks,
    range_start: usize,
    range_end: usize,

    pub fn init(snapshot: *const text.BufferSnapshot, start: usize, end: usize) BufferChunks {
        return .{ .chunks = snapshot.visible_text.chunksInRange(start, end), .range_start = start, .range_end = end };
    }

    pub fn seek(self: *BufferChunks, start: usize, end: usize) void {
        self.range_start = start;
        self.range_end = end;
        self.chunks.setRange(start, end);
    }

    pub fn offset(self: *const BufferChunks) usize {
        return self.chunks.getOffset();
    }

    pub fn next(self: *BufferChunks) ?Chunk {
        const bitmaps = self.chunks.nextWithBitmaps() orelse return null;
        return Chunk.fromBitmaps(bitmaps);
    }
};

const testing = std.testing;

test "buffer chunks carry bitmaps" {
    const gpa = testing.allocator;
    var buffer = try text.Buffer.init(gpa, .local, try text.BufferId.new(1), "a\tb\nc");
    defer buffer.deinit();
    var chunks = BufferChunks.init(&buffer.snapshot, 0, buffer.snapshot.len());
    var total: usize = 0;
    var tab_count: usize = 0;
    var newline_count: usize = 0;
    while (chunks.next()) |chunk| {
        total += chunk.text.len;
        tab_count += @popCount(chunk.tabs & lowMask128(chunk.text.len));
        newline_count += @popCount(chunk.newlines & lowMask128(chunk.text.len));
    }
    try testing.expectEqual(@as(usize, 5), total);
    try testing.expectEqual(@as(usize, 1), tab_count);
    try testing.expectEqual(@as(usize, 1), newline_count);

    var chunk: Chunk = .{ .text = "ab\tc", .tabs = 0b0100, .chars = 0b1111 };
    const prefix = chunk.splitPrefix(3);
    try testing.expectEqualStrings("ab\t", prefix.text);
    try testing.expectEqual(@as(u128, 0b0100), prefix.tabs);
    try testing.expectEqualStrings("c", chunk.text);
    try testing.expectEqual(@as(u128, 0b1), chunk.chars);
}
