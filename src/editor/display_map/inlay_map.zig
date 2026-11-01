//! Port of Zed's `InlayMap` (`.ref/zed/crates/editor/src/display_map/inlay_map.rs`).
//! Spec: docs/zed_port/display_map.md §3.1.
//!
//! Interleaves inlay text (hints, edit predictions, color swatches) with buffer text.
//! Transforms are either an isomorphic run of buffer text or one inlay.
//!
//! Not ported yet: text/semantic highlights (`CustomHighlightsChunks`), inlay
//! highlight styles and chunk renderers, `inlay_hint_at_offset`,
//! `buffer_offset_to_inlay_ranges` and its streaming cursor.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const st = @import("../../sum_tree/sum_tree.zig");
const rope_mod = @import("../../rope/rope.zig");
const mb = @import("../../multi_buffer/multi_buffer.zig");
const language = @import("../../language/language.zig");
const text = @import("../../text/zed/root.zig");

const Bias = st.Bias;
const Dims = st.Dimensions;
const Point = rope_mod.Point;
const Rope = rope_mod.Rope;
const TextSummary = rope_mod.TextSummary;
const MBTextSummary = mb.MBTextSummary;
const MultiBufferSnapshot = mb.MultiBufferSnapshot;

pub const InlayId = union(enum) {
    edit_prediction: usize,
    debugger_value: usize,
    repl_result: usize,
    hint: usize,
    color: usize,

    pub fn eql(a: InlayId, b: InlayId) bool {
        return std.meta.eql(a, b);
    }
};

pub const Inlay = struct {
    id: InlayId,
    position: mb.Anchor,
    /// Inlay text; color inlays render as "◼" (Zed's `COLOR_TEXT`).
    text: Rope,
    color: ?u32 = null,

    pub fn initText(gpa: Allocator, id: InlayId, position: mb.Anchor, content: []const u8) Allocator.Error!Inlay {
        return .{ .id = id, .position = position, .text = try Rope.fromStr(gpa, content) };
    }

    pub fn mockHint(gpa: Allocator, id: usize, position: mb.Anchor, content: []const u8) Allocator.Error!Inlay {
        return initText(gpa, .{ .hint = id }, position, content);
    }

    pub fn editPrediction(gpa: Allocator, id: usize, position: mb.Anchor, content: []const u8) Allocator.Error!Inlay {
        return initText(gpa, .{ .edit_prediction = id }, position, content);
    }

    pub fn initColor(gpa: Allocator, id: usize, position: mb.Anchor, rgba: u32) Allocator.Error!Inlay {
        return .{ .id = .{ .color = id }, .position = position, .text = try Rope.fromStr(gpa, "◼"), .color = rgba };
    }

    pub fn bias(self: *const Inlay) Bias {
        return self.position.text_anchor.bias;
    }

    pub fn retain(self: *const Inlay) Inlay {
        var copy = self.*;
        copy.text = self.text.clone();
        return copy;
    }

    pub fn release(self: *Inlay, gpa: Allocator) void {
        self.text.deinit(gpa);
    }
};

pub const InlayOffset = struct {
    value: usize = 0,

    pub const default_value: InlayOffset = .{};
    pub const Delta = usize;

    pub fn cmp(a: *const InlayOffset, b: *const InlayOffset) Order {
        return std.math.order(a.value, b.value);
    }

    pub fn sub(a: InlayOffset, b: InlayOffset) usize {
        return a.value - b.value;
    }

    pub fn addDelta(a: InlayOffset, delta: usize) InlayOffset {
        return .{ .value = a.value + delta };
    }

    pub fn zero(_: anytype) InlayOffset {
        return .{};
    }

    pub fn addSummary(self: *InlayOffset, summary: *const TransformSummary, _: anytype) void {
        self.value += summary.output.len;
    }
};

pub const InlayPoint = struct {
    point: Point = .{},

    pub const default_value: InlayPoint = .{};
    pub const Delta = InlayPoint;

    pub fn new(r: u32, c: u32) InlayPoint {
        return .{ .point = .new(r, c) };
    }

    pub fn row(self: InlayPoint) u32 {
        return self.point.row;
    }

    pub fn column(self: InlayPoint) u32 {
        return self.point.column;
    }

    pub fn cmp(a: *const InlayPoint, b: *const InlayPoint) Order {
        return a.point.cmp(&b.point);
    }

    pub fn eql(a: InlayPoint, b: InlayPoint) bool {
        return a.point.eql(b.point);
    }

    pub fn add(a: InlayPoint, b: InlayPoint) InlayPoint {
        return .{ .point = a.point.add(b.point) };
    }

    pub fn addDelta(a: InlayPoint, b: InlayPoint) InlayPoint {
        return a.add(b);
    }

    pub fn sub(a: InlayPoint, b: InlayPoint) InlayPoint {
        return .{ .point = a.point.sub(b.point) };
    }

    pub fn zero(_: anytype) InlayPoint {
        return .{};
    }

    pub fn addSummary(self: *InlayPoint, summary: *const TransformSummary, _: anytype) void {
        self.point = self.point.add(summary.output.lines);
    }
};

pub const InlayEdit = text.Edit(InlayOffset);

const TransformSummary = struct {
    /// Summary of the text before inlays are applied.
    input: MBTextSummary = .{},
    /// Summary of the text after inlays are applied.
    output: MBTextSummary = .{},

    pub fn zero(_: void) TransformSummary {
        return .{};
    }

    pub fn addSummary(self: *TransformSummary, other: *const TransformSummary, _: void) void {
        self.input.addAssign(&other.input);
        self.output.addAssign(&other.output);
    }

    fn hasInlays(self: *const TransformSummary) bool {
        return self.input.len != self.output.len;
    }

    // Buffer-side dimensions: `MultiBufferOffset` and buffer `Point`.
    pub fn handlesDimension(comptime D: type) bool {
        return D == usize or D == Point;
    }

    pub fn dimensionZero(comptime D: type, _: void) D {
        return if (D == usize) 0 else Point{};
    }

    pub fn addToDimension(comptime D: type, dimension: *D, summary: *const TransformSummary, _: void) void {
        if (D == usize) dimension.* += summary.input.len else dimension.* = dimension.add(summary.input.lines);
    }
};

const Transform = union(enum) {
    isomorphic: MBTextSummary,
    inlay: Inlay,

    pub const Summary = TransformSummary;

    pub fn summary(self: *const Transform, _: void) TransformSummary {
        return switch (self.*) {
            .isomorphic => |s| .{ .input = s, .output = s },
            .inlay => |*inlay| .{ .output = inlay.text.summary() },
        };
    }

    pub fn retain(self: *const Transform) Transform {
        return switch (self.*) {
            .isomorphic => self.*,
            .inlay => |*inlay| .{ .inlay = inlay.retain() },
        };
    }

    pub fn release(self: *Transform, gpa: Allocator) void {
        switch (self.*) {
            .isomorphic => {},
            .inlay => |*inlay| inlay.release(gpa),
        }
    }
};

const Transforms = st.SumTree(Transform);

fn pushIsomorphic(gpa: Allocator, tree: *Transforms, summary: MBTextSummary) Allocator.Error!void {
    if (summary.len == 0) return;
    var pending: ?MBTextSummary = summary;
    const Updater = struct {
        pending: *?MBTextSummary,
        pub fn update(updater: @This(), transform: *Transform) void {
            switch (transform.*) {
                .isomorphic => |*s| {
                    s.addAssign(&updater.pending.*.?);
                    updater.pending.* = null;
                },
                .inlay => {},
            }
        }
    };
    try tree.updateLast(gpa, {}, Updater{ .pending = &pending });
    if (pending) |remaining| try tree.push(gpa, .{ .isomorphic = remaining }, {});
}

pub const InlaySnapshot = struct {
    buffer: MultiBufferSnapshot,
    transforms: Transforms,
    version: usize,

    pub fn clone(self: *const InlaySnapshot) InlaySnapshot {
        return .{ .buffer = self.buffer.clone(), .transforms = self.transforms.clone(), .version = self.version };
    }

    pub fn deinit(self: *InlaySnapshot, gpa: Allocator) void {
        self.buffer.deinit(gpa);
        self.transforms.deinit(gpa);
    }

    pub fn len(self: *const InlaySnapshot) InlayOffset {
        return .{ .value = self.transforms.summary().output.len };
    }

    pub fn maxPoint(self: *const InlaySnapshot) InlayPoint {
        return .{ .point = self.transforms.summary().output.lines };
    }

    pub fn textSummary(self: *const InlaySnapshot) MBTextSummary {
        return self.transforms.summary().output;
    }

    pub fn toPoint(self: *const InlaySnapshot, offset: InlayOffset) InlayPoint {
        const found = self.transforms.find(Dims(InlayOffset, InlayPoint, usize), {}, offset, .right);
        const overshoot = offset.value - found.start.d1.value;
        const item = found.item orelse return self.maxPoint();
        return switch (item.*) {
            .isomorphic => blk: {
                const buffer_start = self.buffer.offsetToPoint(found.start.d3);
                const buffer_end = self.buffer.offsetToPoint(found.start.d3 + overshoot);
                break :blk .{ .point = found.start.d2.point.add(buffer_end.sub(buffer_start)) };
            },
            .inlay => |*inlay| .{ .point = found.start.d2.point.add(inlay.text.offsetToPoint(overshoot)) },
        };
    }

    pub fn toOffset(self: *const InlaySnapshot, target: InlayPoint) InlayOffset {
        const found = self.transforms.find(Dims(InlayPoint, InlayOffset, Point), {}, target, .right);
        const overshoot = target.point.sub(found.start.d1.point);
        const item = found.item orelse return self.len();
        return switch (item.*) {
            .isomorphic => blk: {
                const buffer_offset_start = self.buffer.pointToOffset(found.start.d3);
                const buffer_offset_end = self.buffer.pointToOffset(found.start.d3.add(overshoot));
                break :blk .{ .value = found.start.d2.value + (buffer_offset_end - buffer_offset_start) };
            },
            .inlay => |*inlay| .{ .value = found.start.d2.value + inlay.text.pointToOffset(overshoot) },
        };
    }

    pub fn toBufferPoint(self: *const InlaySnapshot, target: InlayPoint) Point {
        const found = self.transforms.find(Dims(InlayPoint, Point, void), {}, target, .right);
        const item = found.item orelse return self.buffer.maxPoint();
        return switch (item.*) {
            .isomorphic => found.start.d2.add(target.point.sub(found.start.d1.point)),
            .inlay => found.start.d2,
        };
    }

    pub fn toBufferOffset(self: *const InlaySnapshot, offset: InlayOffset) usize {
        const found = self.transforms.find(Dims(InlayOffset, usize, void), {}, offset, .right);
        const item = found.item orelse return self.buffer.len();
        return switch (item.*) {
            .isomorphic => found.start.d2 + (offset.value - found.start.d1.value),
            .inlay => found.start.d2,
        };
    }

    pub fn toInlayOffset(self: *const InlaySnapshot, offset: usize) InlayOffset {
        var c = self.transforms.cursor(Dims(usize, InlayOffset, void), {});
        _ = c.seek(offset, .left);
        while (true) {
            const item = c.item() orelse return self.len();
            switch (item.*) {
                .isomorphic => {
                    if (offset == c.end().d1) {
                        while (c.nextItem()) |next_item| {
                            switch (next_item.*) {
                                .inlay => |*inlay| if (inlay.bias() == .right) break else c.next(),
                                .isomorphic => break,
                            }
                        }
                        return c.end().d2;
                    }
                    return .{ .value = c.start().d2.value + (offset - c.start().d1) };
                },
                .inlay => |*inlay| {
                    if (inlay.bias() == .left) c.next() else return c.start().d2;
                },
            }
        }
    }

    pub fn toInlayPoint(self: *const InlaySnapshot, target: Point) InlayPoint {
        var c = self.inlayPointCursor();
        return c.map(target, .left);
    }

    pub fn inlayPointCursor(self: *const InlaySnapshot) InlayPointCursor {
        return .{ .cursor = self.transforms.cursor(Dims(Point, InlayPoint, void), {}), .transforms = &self.transforms };
    }

    pub fn clipPoint(self: *const InlaySnapshot, point_in: InlayPoint, bias_in: Bias) InlayPoint {
        var target = point_in;
        var bias = bias_in;
        var c = self.transforms.cursor(Dims(InlayPoint, Point, void), {});
        _ = c.seek(target, .left);
        while (true) {
            if (c.item()) |item| switch (item.*) {
                .isomorphic => |transform| {
                    if (c.start().d1.eql(target)) {
                        if (c.prevItem()) |prev| switch (prev.*) {
                            .inlay => |*inlay| {
                                if (inlay.bias() == .left) return target;
                                if (bias == .left) {
                                    c.prev();
                                } else if (transform.first_line_chars == 0) {
                                    target.point = target.point.add(.new(1, 0));
                                } else {
                                    target.point = target.point.add(.new(0, 1));
                                }
                            },
                            .isomorphic => return target,
                        } else return target;
                    } else if (c.end().d1.eql(target)) {
                        if (c.nextItem()) |next_item| switch (next_item.*) {
                            .inlay => |*inlay| {
                                if (inlay.bias() == .right) return target;
                                if (bias == .right) {
                                    c.next();
                                } else if (target.point.column == 0) {
                                    target.point.row -= 1;
                                    target.point.column = self.lineLen(target.point.row);
                                } else {
                                    target.point.column -= 1;
                                }
                            },
                            .isomorphic => return target,
                        } else return target;
                    } else {
                        const overshoot = target.point.sub(c.start().d1.point);
                        const buffer_point = c.start().d2.add(overshoot);
                        const clipped_buffer_point = self.buffer.clipPoint(buffer_point, bias);
                        const clipped_overshoot = clipped_buffer_point.sub(c.start().d2);
                        const clipped: InlayPoint = .{ .point = c.start().d1.point.add(clipped_overshoot) };
                        if (clipped.eql(target)) return clipped;
                        target = clipped;
                    }
                },
                .inlay => |*inlay| {
                    if (target.eql(c.start().d1) and inlay.bias() == .right) {
                        if (c.prevItem()) |prev| switch (prev.*) {
                            .inlay => |*prev_inlay| if (prev_inlay.bias() == .left) return target,
                            .isomorphic => return target,
                        } else return target;
                    } else if (target.eql(c.end().d1) and inlay.bias() == .left) {
                        if (c.nextItem()) |next_item| switch (next_item.*) {
                            .inlay => |*next_inlay| if (next_inlay.bias() == .right) return target,
                            .isomorphic => return target,
                        } else return target;
                    }
                    if (bias == .left) {
                        target = c.start().d1;
                        c.prev();
                    } else {
                        c.next();
                        target = c.start().d1;
                    }
                },
            } else {
                bias = bias.invert();
                if (bias == .left) {
                    target = c.start().d1;
                    c.prev();
                } else {
                    c.next();
                    target = c.start().d1;
                }
            }
        }
    }

    pub fn inlayBiasAtPoint(self: *const InlaySnapshot, target: InlayPoint) ?Bias {
        var c = self.transforms.cursor(Dims(InlayPoint, Point, void), {});
        _ = c.seek(target, .left);
        const item = c.item() orelse return null;
        return switch (item.*) {
            .inlay => |*inlay| inlay.bias(),
            .isomorphic => null,
        };
    }

    pub fn textSummaryForRange(self: *const InlaySnapshot, start: InlayOffset, end: InlayOffset) MBTextSummary {
        var summary: MBTextSummary = .{};
        var c = self.transforms.cursor(Dims(InlayOffset, usize, void), {});
        _ = c.seek(start, .right);
        const overshoot = start.value - c.start().d1.value;
        if (c.item()) |item| {
            const suffix_end_in_transform = @min(c.end().d1.value, end.value) - c.start().d1.value;
            switch (item.*) {
                .isomorphic => {
                    const buffer_start = c.start().d2;
                    summary = self.buffer.textSummaryForRange(MBTextSummary, buffer_start + overshoot, buffer_start + suffix_end_in_transform);
                },
                .inlay => |*inlay| {
                    var rc = inlay.text.cursor(overshoot);
                    summary = rc.summary(TextSummary, suffix_end_in_transform);
                },
            }
            c.next();
        }
        if (end.value > c.start().d1.value) {
            summary.addAssign(&c.summary(TransformSummary, end, .right).output);
            const end_overshoot = end.value - c.start().d1.value;
            if (c.item()) |item| switch (item.*) {
                .isomorphic => {
                    const prefix_start = c.start().d2;
                    summary.addAssign(&self.buffer.textSummaryForRange(MBTextSummary, prefix_start, prefix_start + end_overshoot));
                },
                .inlay => |*inlay| {
                    var rc = inlay.text.cursor(0);
                    summary.addAssign(&rc.summary(TextSummary, end_overshoot));
                },
            };
        }
        return summary;
    }

    pub fn lineLen(self: *const InlaySnapshot, row: u32) u32 {
        const line_start = self.toOffset(.new(row, 0)).value;
        const line_end = if (row >= self.maxPoint().row()) self.len().value else self.toOffset(.new(row + 1, 0)).value - 1;
        return @intCast(line_end - line_start);
    }

    pub fn rowInfos(self: *const InlaySnapshot, start_row: u32) InlayBufferRows {
        var c = self.transforms.cursor(Dims(InlayPoint, Point, void), {});
        const inlay_point = InlayPoint.new(start_row, 0);
        _ = c.seek(inlay_point, .left);
        const max_buffer_row = self.buffer.maxRow();
        var buffer_point = c.start().d2;
        const buffer_row: u32 = if (start_row == 0) 0 else if (c.item()) |item| switch (item.*) {
            .isomorphic => blk: {
                buffer_point = buffer_point.add(inlay_point.point.sub(c.start().d1.point));
                break :blk buffer_point.row;
            },
            .inlay => @min(buffer_point.row + 1, max_buffer_row),
        } else @min(buffer_point.row + 1, max_buffer_row);
        return .{ .transforms = c, .inlay_row = start_row, .buffer_rows = self.buffer.rowInfos(buffer_row), .max_buffer_row = max_buffer_row };
    }

    pub fn chunks(self: *const InlaySnapshot, start: InlayOffset, end: InlayOffset, language_aware: language.LanguageAwareStyling) InlayChunks {
        var c = self.transforms.cursor(Dims(InlayOffset, usize, void), {});
        _ = c.seek(start, .right);
        const buffer_start = self.toBufferOffset(start);
        const buffer_end = self.toBufferOffset(end);
        return .{
            .transforms = c,
            .buffer_chunks = self.buffer.chunks(buffer_start, buffer_end, language_aware),
            .output_offset = start,
            .max_output_offset = end,
            .snapshot = self,
        };
    }

    /// The whole output text (test helper in Zed).
    pub fn textAlloc(self: *const InlaySnapshot, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var it = self.chunks(.{}, self.len(), .{ .tree_sitter = false, .diagnostics = false });
        while (it.next()) |chunk| try out.appendSlice(gpa, chunk.chunk.text);
        return out.toOwnedSlice(gpa);
    }

    pub fn inlayOffsetRange(self: *const InlaySnapshot, inlay_id: InlayId, position: mb.Anchor) ?struct { start: InlayOffset, end: InlayOffset } {
        const buffer_offset = self.buffer.toOffset(position);
        var c = self.transforms.cursor(Dims(usize, InlayOffset, void), {});
        _ = c.seek(buffer_offset, .left);
        while (c.item()) |item| : (c.next()) {
            if (c.start().d1 > buffer_offset) break;
            switch (item.*) {
                .inlay => |*inlay| if (inlay.id.eql(inlay_id)) return .{ .start = c.start().d2, .end = c.end().d2 },
                .isomorphic => {},
            }
        }
        return null;
    }

    pub fn checkInvariants(self: *const InlaySnapshot) void {
        if (!std.debug.runtime_safety) return;
        std.debug.assert(self.transforms.summary().input.eql(self.buffer.textSummary()));
        var it = self.transforms.iter();
        var previous_isomorphic = false;
        while (it.next()) |transform| {
            const isomorphic = transform.* == .isomorphic;
            std.debug.assert(!(previous_isomorphic and isomorphic));
            previous_isomorphic = isomorphic;
        }
    }
};

pub const InlayPointCursor = struct {
    cursor: Transforms.Cursor(Dims(Point, InlayPoint, void)),
    transforms: *const Transforms,

    pub fn map(self: *InlayPointCursor, target: Point, bias: Bias) InlayPoint {
        const c = &self.cursor;
        if (c.didSeek()) _ = c.seekForward(target, .left) else _ = c.seek(target, .left);
        while (true) {
            const item = c.item() orelse return .{ .point = self.transforms.summary().output.lines };
            switch (item.*) {
                .isomorphic => {
                    if (target.eql(c.end().d1)) {
                        while (c.nextItem()) |next_item| {
                            switch (next_item.*) {
                                .inlay => |*inlay| if (bias == .left and inlay.bias() == .right) break else c.next(),
                                .isomorphic => break,
                            }
                        }
                        return c.end().d2;
                    }
                    return .{ .point = c.start().d2.point.add(target.sub(c.start().d1)) };
                },
                .inlay => |*inlay| {
                    if (inlay.bias() == .left or bias == .right) c.next() else return c.start().d2;
                },
            }
        }
    }
};

pub const InlayChunk = struct {
    chunk: language.Chunk,
};

pub const InlayChunks = struct {
    transforms: Transforms.Cursor(Dims(InlayOffset, usize, void)),
    buffer_chunks: mb.MultiBufferChunks,
    buffer_chunk: ?language.Chunk = null,
    inlay_chunks: ?rope_mod.Chunks = null,
    inlay_chunk: ?language.Chunk = null,
    output_offset: InlayOffset,
    max_output_offset: InlayOffset,
    snapshot: *const InlaySnapshot,

    pub fn seek(self: *InlayChunks, start: InlayOffset, end: InlayOffset) void {
        _ = self.transforms.seek(start, .right);
        self.buffer_chunks.seek(self.snapshot.toBufferOffset(start), self.snapshot.toBufferOffset(end));
        self.inlay_chunks = null;
        self.buffer_chunk = null;
        self.output_offset = start;
        self.max_output_offset = end;
    }

    pub fn offset(self: *const InlayChunks) InlayOffset {
        return self.output_offset;
    }

    pub fn next(self: *InlayChunks) ?InlayChunk {
        while (true) {
            if (self.output_offset.value == self.max_output_offset.value) return null;
            const item = self.transforms.item() orelse return null;
            const result: InlayChunk = switch (item.*) {
                .isomorphic => blk: {
                    if (self.buffer_chunk == null) self.buffer_chunk = self.buffer_chunks.next().?;
                    const chunk = &self.buffer_chunk.?;
                    if (chunk.text.len == 0) chunk.* = self.buffer_chunks.next().?;
                    const desired_bytes = self.transforms.end().d1.value - self.output_offset.value;
                    // At the transform boundary: move to the next transform.
                    if (desired_bytes == 0) {
                        self.inlay_chunks = null;
                        self.transforms.next();
                        continue;
                    }
                    const split_index = if (desired_bytes >= chunk.text.len) chunk.text.len else rope_mod.chunk.strCeilCharBoundary(chunk.text, desired_bytes);
                    const prefix = chunk.splitPrefix(split_index);
                    self.output_offset.value += prefix.text.len;
                    break :blk .{ .chunk = prefix };
                },
                .inlay => |*inlay| blk: {
                    const transform_start = self.transforms.start().d1.value;
                    const offset_in_inlay = self.output_offset.value - transform_start;
                    if (self.inlay_chunks == null) {
                        const end = @min(self.max_output_offset.value, self.transforms.end().d1.value) - transform_start;
                        self.inlay_chunks = inlay.text.chunksInRange(offset_in_inlay, end);
                    }
                    if (self.inlay_chunk == null) {
                        const bitmaps = self.inlay_chunks.?.nextWithBitmaps().?;
                        self.inlay_chunk = language.Chunk.fromBitmaps(bitmaps);
                    }
                    const inlay_chunk = &self.inlay_chunk.?;
                    // Without inlay highlights the whole chunk is taken at once.
                    var prefix = inlay_chunk.splitPrefix(inlay_chunk.text.len);
                    if (inlay_chunk.text.len == 0) self.inlay_chunk = null;
                    self.output_offset.value += prefix.text.len;
                    prefix = .{ .text = prefix.text, .chars = prefix.chars, .tabs = prefix.tabs, .newlines = prefix.newlines, .is_inlay = true };
                    break :blk .{ .chunk = prefix };
                },
            };
            if (self.output_offset.value >= self.transforms.end().d1.value) {
                self.inlay_chunks = null;
                self.transforms.next();
            }
            return result;
        }
    }
};

pub const InlayBufferRows = struct {
    transforms: Transforms.Cursor(Dims(InlayPoint, Point, void)),
    buffer_rows: mb.MultiBufferRows,
    inlay_row: u32,
    max_buffer_row: u32,

    pub fn seek(self: *InlayBufferRows, start_row: u32) void {
        const inlay_point = InlayPoint.new(start_row, 0);
        _ = self.transforms.seek(inlay_point, .left);
        var buffer_point = self.transforms.start().d2;
        const buffer_row: u32 = if (start_row == 0) 0 else if (self.transforms.item()) |item| switch (item.*) {
            .isomorphic => blk: {
                buffer_point = buffer_point.add(inlay_point.point.sub(self.transforms.start().d1.point));
                break :blk buffer_point.row;
            },
            .inlay => @min(buffer_point.row + 1, self.max_buffer_row),
        } else @min(buffer_point.row + 1, self.max_buffer_row);
        self.inlay_row = start_row;
        self.buffer_rows.seek(buffer_row);
    }

    pub fn next(self: *InlayBufferRows) ?mb.RowInfo {
        const info: mb.RowInfo = if (self.inlay_row == 0) self.buffer_rows.next().? else blk: {
            const item = self.transforms.item() orelse return null;
            break :blk switch (item.*) {
                .inlay => .{},
                .isomorphic => self.buffer_rows.next().?,
            };
        };
        self.inlay_row += 1;
        _ = self.transforms.seekForward(InlayPoint.new(self.inlay_row, 0), .left);
        return info;
    }
};

pub const SyncResult = struct {
    /// Owned by the caller.
    snapshot: InlaySnapshot,
    /// Owned by the caller.
    edits: text.Patch(InlayOffset),

    pub fn deinit(self: *SyncResult, gpa: Allocator) void {
        self.snapshot.deinit(gpa);
        self.edits.deinit(gpa);
    }
};

pub const InlayMap = struct {
    gpa: Allocator,
    snapshot: InlaySnapshot,
    /// Sorted by anchor position.
    inlays: std.ArrayList(Inlay) = .empty,

    /// Takes ownership of `buffer`; also returns a snapshot the caller owns.
    pub fn init(gpa: Allocator, buffer: MultiBufferSnapshot) Allocator.Error!struct { map: InlayMap, snapshot: InlaySnapshot } {
        var owned = buffer;
        errdefer owned.deinit(gpa);
        const transforms = try Transforms.fromItem(gpa, .{ .isomorphic = owned.textSummary() }, {});
        const snapshot: InlaySnapshot = .{ .buffer = owned, .transforms = transforms, .version = 0 };
        return .{ .map = .{ .gpa = gpa, .snapshot = snapshot }, .snapshot = snapshot.clone() };
    }

    pub fn deinit(self: *InlayMap) void {
        for (self.inlays.items) |*inlay| inlay.release(self.gpa);
        self.inlays.deinit(self.gpa);
        self.snapshot.deinit(self.gpa);
    }

    pub fn currentInlays(self: *const InlayMap) []const Inlay {
        return self.inlays.items;
    }

    /// Takes ownership of `buffer_snapshot`.
    pub fn sync(self: *InlayMap, buffer_snapshot: MultiBufferSnapshot, buffer_edits: []const text.Edit(usize)) Allocator.Error!SyncResult {
        const gpa = self.gpa;
        var buffer = buffer_snapshot;
        // The snapshot is transferred only after the replacement transform and
        // edit patch have been built. Release it on every allocation failure.
        errdefer buffer.deinit(gpa);
        const snapshot = &self.snapshot;
        var inlay_edits: text.Patch(InlayOffset) = .empty;
        errdefer inlay_edits.deinit(gpa);

        if (buffer_edits.len == 0) {
            if (snapshot.buffer.edit_count != buffer.edit_count or snapshot.buffer.non_text_state_update_count != buffer.non_text_state_update_count) {
                snapshot.version += 1;
            }
            snapshot.buffer.deinit(gpa);
            snapshot.buffer = buffer;
            return .{ .snapshot = snapshot.clone(), .edits = inlay_edits };
        }

        if (self.inlays.items.len == 0 and !snapshot.transforms.summary().hasInlays()) {
            // Without inlays the map is a passthrough: one isomorphic transform, and
            // buffer edits are forwarded verbatim.
            var new_transforms = try Transforms.init(gpa, {});
            errdefer new_transforms.deinit(gpa);
            try pushIsomorphic(gpa, &new_transforms, buffer.textSummary());
            if (new_transforms.isEmpty()) try new_transforms.push(gpa, .{ .isomorphic = .{} }, {});
            for (buffer_edits) |e| {
                try inlay_edits.push(gpa, .{ .old = .{ .start = .{ .value = e.old.start }, .end = .{ .value = e.old.end } }, .new = .{ .start = .{ .value = e.new.start }, .end = .{ .value = e.new.end } } });
            }
            snapshot.transforms.deinit(gpa);
            snapshot.transforms = new_transforms;
            snapshot.version += 1;
            snapshot.buffer.deinit(gpa);
            snapshot.buffer = buffer;
            snapshot.checkInvariants();
            return .{ .snapshot = snapshot.clone(), .edits = inlay_edits };
        }

        var new_transforms = try Transforms.init(gpa, {});
        errdefer new_transforms.deinit(gpa);
        {
            var c = snapshot.transforms.cursor(Dims(usize, InlayOffset, void), {});
            for (buffer_edits, 0..) |buffer_edit, edit_ix| {
                try new_transforms.append(gpa, try c.slice(gpa, buffer_edit.old.start, .left), {});
                if (c.item()) |item| switch (item.*) {
                    .isomorphic => |transform| if (c.end().d1 == buffer_edit.old.start) {
                        try pushIsomorphic(gpa, &new_transforms, transform);
                        c.next();
                    },
                    .inlay => {},
                };

                // Remove all the inlays and transforms contained by the edit.
                const old_start: InlayOffset = .{ .value = c.start().d2.value + (buffer_edit.old.start - c.start().d1) };
                _ = c.seek(buffer_edit.old.end, .right);
                const old_end: InlayOffset = .{ .value = c.start().d2.value + (buffer_edit.old.end - c.start().d1) };

                // Push the unchanged prefix.
                const prefix_start = new_transforms.summary().input.len;
                try pushIsomorphic(gpa, &new_transforms, buffer.textSummaryForRange(MBTextSummary, prefix_start, buffer_edit.new.start));
                const new_start: InlayOffset = .{ .value = new_transforms.summary().output.len };

                var start_ix: usize = 0;
                {
                    var low: usize = 0;
                    var high: usize = self.inlays.items.len;
                    while (low < high) {
                        const mid = low + (high - low) / 2;
                        if (buffer.toOffset(self.inlays.items[mid].position) < buffer_edit.new.start) low = mid + 1 else high = mid;
                    }
                    start_ix = low;
                }
                for (self.inlays.items[start_ix..]) |*inlay| {
                    if (!inlay.position.text_anchor.isValid(&buffer.buffer)) continue;
                    const buffer_offset = buffer.toOffset(inlay.position);
                    if (buffer_offset > buffer_edit.new.end) break;
                    const inlay_prefix_start = new_transforms.summary().input.len;
                    try pushIsomorphic(gpa, &new_transforms, buffer.textSummaryForRange(MBTextSummary, inlay_prefix_start, buffer_offset));
                    try new_transforms.push(gpa, .{ .inlay = inlay.retain() }, {});
                }

                // Apply the rest of the edit.
                const transform_start = new_transforms.summary().input.len;
                try pushIsomorphic(gpa, &new_transforms, buffer.textSummaryForRange(MBTextSummary, transform_start, buffer_edit.new.end));
                const new_end: InlayOffset = .{ .value = new_transforms.summary().output.len };
                try inlay_edits.push(gpa, .{ .old = .{ .start = old_start, .end = old_end }, .new = .{ .start = new_start, .end = new_end } });

                // If the next edit doesn't intersect the current isomorphic transform,
                // push its remainder.
                const next_edit = if (edit_ix + 1 < buffer_edits.len) buffer_edits[edit_ix + 1] else null;
                if (next_edit == null or next_edit.?.old.start >= c.end().d1) {
                    const remainder_start = new_transforms.summary().input.len;
                    const remainder_end = buffer_edit.new.end + (c.end().d1 - buffer_edit.old.end);
                    try pushIsomorphic(gpa, &new_transforms, buffer.textSummaryForRange(MBTextSummary, remainder_start, remainder_end));
                    c.next();
                }
            }
            try new_transforms.append(gpa, try c.suffix(gpa), {});
        }
        if (new_transforms.isEmpty()) try new_transforms.push(gpa, .{ .isomorphic = .{} }, {});

        snapshot.transforms.deinit(gpa);
        snapshot.transforms = new_transforms;
        snapshot.version += 1;
        snapshot.buffer.deinit(gpa);
        snapshot.buffer = buffer;
        snapshot.checkInvariants();
        return .{ .snapshot = snapshot.clone(), .edits = inlay_edits };
    }

    /// Removes inlays by id and inserts new ones (taking ownership of them).
    pub fn splice(self: *InlayMap, to_remove: []const InlayId, to_insert: []const Inlay) Allocator.Error!SyncResult {
        const gpa = self.gpa;
        const snapshot = &self.snapshot;
        var offsets: std.ArrayList(usize) = .empty;
        defer offsets.deinit(gpa);

        var write: usize = 0;
        for (self.inlays.items) |*inlay| {
            const removed = for (to_remove) |id| {
                if (id.eql(inlay.id)) break true;
            } else false;
            if (removed) {
                try offsets.append(gpa, snapshot.buffer.toOffset(inlay.position));
                inlay.release(gpa);
            } else {
                self.inlays.items[write] = inlay.*;
                write += 1;
            }
        }
        self.inlays.items.len = write;

        for (to_insert) |inlay_to_insert| {
            var owned = inlay_to_insert;
            // Avoid inserting empty inlays.
            if (owned.text.isEmpty()) {
                owned.release(gpa);
                continue;
            }
            const offset = snapshot.buffer.toOffset(owned.position);
            var low: usize = 0;
            var high: usize = self.inlays.items.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (self.inlays.items[mid].position.cmp(owned.position, &snapshot.buffer) != .gt) low = mid + 1 else high = mid;
            }
            self.inlays.insert(gpa, low, owned) catch |err| {
                owned.release(gpa);
                return err;
            };
            try offsets.append(gpa, offset);
        }

        std.sort.pdq(usize, offsets.items, {}, std.sort.asc(usize));
        var buffer_edits: std.ArrayList(text.Edit(usize)) = .empty;
        defer buffer_edits.deinit(gpa);
        for (offsets.items, 0..) |offset, i| {
            if (i > 0 and offsets.items[i - 1] == offset) continue;
            try buffer_edits.append(gpa, .{ .old = .{ .start = offset, .end = offset }, .new = .{ .start = offset, .end = offset } });
        }
        return self.sync(snapshot.buffer.clone(), buffer_edits.items);
    }
};

test {
    _ = @import("inlay_map_tests.zig");
}
