//! Singleton-only port of Zed's `multi_buffer` crate
//! (`.ref/zed/crates/multi_buffer/src/multi_buffer.rs`).
//!
//! A Zed multibuffer is a list of excerpts from many buffers. This port supports
//! `MultiBuffer::singleton`: one excerpt covering a whole buffer, where multibuffer
//! offsets, points and rows equal buffer ones. The API mirrors the snapshot methods the
//! display map uses, so excerpts and diff hunks can be added behind it later.
//!
//! `MultiBufferOffset` and `MultiBufferRow` are newtypes in Zed; here they are plain
//! integers (`usize`, `u32`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("../text/zed/root.zig");
const rope_mod = @import("../rope/rope.zig");
const language = @import("../language/language.zig");
const st = @import("../sum_tree/sum_tree.zig");

pub const Point = rope_mod.Point;
pub const PointUtf16 = rope_mod.PointUtf16;
pub const OffsetUtf16 = rope_mod.OffsetUtf16;
pub const Bias = st.Bias;
pub const MultiBufferOffset = usize;
pub const MultiBufferRow = u32;
pub const MBTextSummary = rope_mod.TextSummary;
pub const Edit = text.Edit;
pub const Patch = text.Patch;

/// Row metadata for gutters (`RowInfo`). Diff status and expansion are not ported.
pub const RowInfo = struct {
    buffer_id: ?text.BufferId = null,
    buffer_row: ?u32 = null,
    multibuffer_row: ?MultiBufferRow = null,
    wrapped_buffer_row: ?u32 = null,
};

/// A multibuffer anchor; for a singleton it wraps the buffer anchor.
pub const Anchor = struct {
    text_anchor: text.Anchor,

    pub fn cmp(self: Anchor, other: Anchor, snapshot: *const MultiBufferSnapshot) std.math.Order {
        return self.text_anchor.cmp(other.text_anchor, &snapshot.buffer);
    }
};

pub const MultiBufferSnapshot = struct {
    buffer: text.BufferSnapshot,
    /// Incremented whenever the buffer's text changes (`edit_count`).
    edit_count: usize = 0,
    non_text_state_update_count: usize = 0,

    pub fn clone(self: *const MultiBufferSnapshot) MultiBufferSnapshot {
        var result = self.*;
        result.buffer = self.buffer.clone();
        return result;
    }

    pub fn deinit(self: *MultiBufferSnapshot, gpa: Allocator) void {
        self.buffer.deinit(gpa);
    }

    pub fn isSingleton(_: *const MultiBufferSnapshot) bool {
        return true;
    }

    pub fn len(self: *const MultiBufferSnapshot) MultiBufferOffset {
        return self.buffer.len();
    }

    pub fn isEmpty(self: *const MultiBufferSnapshot) bool {
        return self.len() == 0;
    }

    pub fn maxPoint(self: *const MultiBufferSnapshot) Point {
        return self.buffer.maxPoint();
    }

    pub fn maxRow(self: *const MultiBufferSnapshot) MultiBufferRow {
        return self.maxPoint().row;
    }

    pub fn textSummary(self: *const MultiBufferSnapshot) MBTextSummary {
        return self.buffer.textSummary();
    }

    pub fn textSummaryForRange(self: *const MultiBufferSnapshot, comptime D: type, start: MultiBufferOffset, end: MultiBufferOffset) D {
        return self.buffer.textSummaryForRange(D, start, end);
    }

    pub fn longestRow(self: *const MultiBufferSnapshot) MultiBufferRow {
        return self.textSummary().longest_row;
    }

    pub fn lineLen(self: *const MultiBufferSnapshot, row: MultiBufferRow) u32 {
        return self.buffer.lineLen(row);
    }

    pub fn clipOffset(self: *const MultiBufferSnapshot, offset: MultiBufferOffset, bias: Bias) MultiBufferOffset {
        return self.buffer.clipOffset(offset, bias);
    }

    pub fn clipPoint(self: *const MultiBufferSnapshot, p: Point, bias: Bias) Point {
        return self.buffer.clipPoint(p, bias);
    }

    pub fn clipPointUtf16(self: *const MultiBufferSnapshot, p: rope_mod.Unclipped(PointUtf16), bias: Bias) PointUtf16 {
        return self.buffer.clipPointUtf16(p, bias);
    }

    pub fn offsetToPoint(self: *const MultiBufferSnapshot, offset: MultiBufferOffset) Point {
        return self.buffer.offsetToPoint(offset);
    }

    pub fn pointToOffset(self: *const MultiBufferSnapshot, p: Point) MultiBufferOffset {
        return self.buffer.pointToOffset(p);
    }

    pub fn offsetToPointUtf16(self: *const MultiBufferSnapshot, offset: MultiBufferOffset) PointUtf16 {
        return self.buffer.offsetToPointUtf16(offset);
    }

    pub fn pointToPointUtf16(self: *const MultiBufferSnapshot, p: Point) PointUtf16 {
        return self.buffer.pointToPointUtf16(p);
    }

    pub fn toOffset(self: *const MultiBufferSnapshot, position: anytype) MultiBufferOffset {
        if (@TypeOf(position) == Anchor) return self.buffer.toOffset(position.text_anchor);
        return self.buffer.toOffset(position);
    }

    pub fn toPoint(self: *const MultiBufferSnapshot, position: anytype) Point {
        if (@TypeOf(position) == Anchor) return self.buffer.toPoint(position.text_anchor);
        return self.buffer.toPoint(position);
    }

    pub fn anchorBefore(self: *const MultiBufferSnapshot, position: anytype) Anchor {
        return .{ .text_anchor = self.buffer.anchorBefore(position) };
    }

    pub fn anchorAfter(self: *const MultiBufferSnapshot, position: anytype) Anchor {
        return .{ .text_anchor = self.buffer.anchorAfter(position) };
    }

    pub fn anchorAt(self: *const MultiBufferSnapshot, position: anytype, bias: Bias) Anchor {
        return .{ .text_anchor = self.buffer.anchorAt(position, bias) };
    }

    pub fn charsAt(self: *const MultiBufferSnapshot, offset: MultiBufferOffset) rope_mod.Chars {
        return self.buffer.charsAt(offset);
    }

    pub fn reversedCharsAt(self: *const MultiBufferSnapshot, offset: MultiBufferOffset) rope_mod.Chars {
        return self.buffer.reversedCharsAt(offset);
    }

    pub fn textForRange(self: *const MultiBufferSnapshot, gpa: Allocator, start: MultiBufferOffset, end: MultiBufferOffset) Allocator.Error![]u8 {
        return self.buffer.textForRange(gpa, start, end);
    }

    pub fn text_(self: *const MultiBufferSnapshot, gpa: Allocator) Allocator.Error![]u8 {
        return self.buffer.text(gpa);
    }

    /// Styled chunks in a byte range (`MultiBufferSnapshot::chunks`).
    pub fn chunks(self: *const MultiBufferSnapshot, start: MultiBufferOffset, end: MultiBufferOffset, _: language.LanguageAwareStyling) MultiBufferChunks {
        return .{ .inner = language.BufferChunks.init(&self.buffer, start, end) };
    }

    pub fn rowInfos(self: *const MultiBufferSnapshot, start_row: MultiBufferRow) MultiBufferRows {
        return .{ .row = start_row, .max_row = self.maxRow(), .buffer_id = self.buffer.remote_id };
    }
};

pub const MultiBufferChunks = struct {
    inner: language.BufferChunks,

    pub fn seek(self: *MultiBufferChunks, start: MultiBufferOffset, end: MultiBufferOffset) void {
        self.inner.seek(start, end);
    }

    pub fn offset(self: *const MultiBufferChunks) MultiBufferOffset {
        return self.inner.offset();
    }

    pub fn next(self: *MultiBufferChunks) ?language.Chunk {
        return self.inner.next();
    }
};

/// Iterates `RowInfo`s from a starting row (`MultiBufferRows`).
pub const MultiBufferRows = struct {
    row: MultiBufferRow,
    max_row: MultiBufferRow,
    buffer_id: text.BufferId,
    done: bool = false,

    pub fn seek(self: *MultiBufferRows, row: MultiBufferRow) void {
        self.row = row;
        self.done = row > self.max_row;
    }

    pub fn next(self: *MultiBufferRows) ?RowInfo {
        if (self.done or self.row > self.max_row) return null;
        const info: RowInfo = .{ .buffer_id = self.buffer_id, .buffer_row = self.row, .multibuffer_row = self.row };
        if (self.row == self.max_row) self.done = true else self.row += 1;
        return info;
    }
};

/// A multibuffer over one buffer (`MultiBuffer::singleton`). The buffer is owned.
pub const MultiBuffer = struct {
    gpa: Allocator,
    buffer: text.Buffer,
    /// Edits in multibuffer offsets, published on each buffer edit.
    subscriptions: text.subscription.Topic(MultiBufferOffset) = .{},
    buffer_subscription: *text.buffer.Subscription,
    edit_count: usize = 0,

    pub fn singleton(gpa: Allocator, buffer: text.Buffer) Allocator.Error!MultiBuffer {
        var owned = buffer;
        const subscription = try owned.subscribe();
        return .{ .gpa = gpa, .buffer = owned, .buffer_subscription = subscription };
    }

    pub fn deinit(self: *MultiBuffer) void {
        self.subscriptions.deinit(self.gpa);
        self.buffer_subscription.release(self.gpa);
        self.buffer.deinit();
    }

    pub fn snapshot(self: *const MultiBuffer) MultiBufferSnapshot {
        return .{ .buffer = self.buffer.cloneSnapshot(), .edit_count = self.edit_count };
    }

    pub fn subscribe(self: *MultiBuffer) Allocator.Error!*text.subscription.Subscription(MultiBufferOffset) {
        return self.subscriptions.subscribe(self.gpa);
    }

    /// Forwards buffer edits to multibuffer subscribers (offsets are identical).
    fn sync(self: *MultiBuffer) Allocator.Error!void {
        var patch = self.buffer_subscription.consume();
        defer patch.deinit(self.gpa);
        if (patch.isEmpty()) return;
        self.edit_count += 1;
        try self.subscriptions.publish(self.gpa, patch.edits());
    }

    pub fn edit(self: *MultiBuffer, edits: []const text.buffer.RangeEdit) Allocator.Error!void {
        _ = try self.buffer.edit(edits);
        try self.sync();
    }

    pub fn undo(self: *MultiBuffer) Allocator.Error!?text.buffer.TransactionId {
        const id = try self.buffer.undo();
        try self.sync();
        return id;
    }

    pub fn redo(self: *MultiBuffer) Allocator.Error!?text.buffer.TransactionId {
        const id = try self.buffer.redo();
        try self.sync();
        return id;
    }
};

const testing = std.testing;

test "singleton multibuffer mirrors its buffer" {
    const gpa = testing.allocator;
    var multi = try MultiBuffer.singleton(gpa, try text.Buffer.init(gpa, .local, try text.BufferId.new(1), "one\ntwo"));
    defer multi.deinit();
    const subscription = try multi.subscribe();
    defer subscription.release(gpa);

    try multi.edit(&.{.{ .start = 3, .end = 3, .text = "!" }});
    var snap = multi.snapshot();
    defer snap.deinit(gpa);
    try testing.expectEqual(@as(usize, 8), snap.len());
    try testing.expect(snap.maxPoint().eql(.new(1, 3)));
    try testing.expectEqual(@as(u32, 4), snap.lineLen(0));

    var patch = subscription.consume();
    defer patch.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), patch.edits().len);
    try testing.expectEqual(@as(usize, 3), patch.edits()[0].new.start);
    try testing.expectEqual(@as(usize, 4), patch.edits()[0].new.end);

    var rows = snap.rowInfos(0);
    try testing.expectEqual(@as(?u32, 0), rows.next().?.buffer_row);
    try testing.expectEqual(@as(?u32, 1), rows.next().?.buffer_row);
    try testing.expect(rows.next() == null);

    const anchor = snap.anchorAfter(@as(usize, 5));
    try testing.expect(snap.toPoint(anchor).eql(.new(1, 0)));
}
