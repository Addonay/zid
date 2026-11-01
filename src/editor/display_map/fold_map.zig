//! Initial FoldMap port from Zed's `display_map/fold_map.rs`.
//! Fold endpoints are buffer anchors. Snapshots retain their InlaySnapshot and
//! a sum tree of input/output summaries. Rebuild currently scans all folds;
//! incremental FoldEdit generation, unfold, point/chunk/row APIs and render
//! metadata are not implemented.
const std = @import("std");
const Allocator = std.mem.Allocator;
const st = @import("../../sum_tree/sum_tree.zig");
const rope = @import("../../rope/rope.zig");
const mb = @import("../../multi_buffer/multi_buffer.zig");
const im = @import("inlay_map.zig");
const TextSummary = mb.MBTextSummary;
const Dims = st.Dimensions;
pub const Bias = st.Bias;
pub const InlayOffset = im.InlayOffset;

pub const FoldOffset = struct {
    value: usize = 0,
    pub fn cmp(a: *const FoldOffset, b: *const FoldOffset) std.math.Order {
        return std.math.order(a.value, b.value);
    }
    pub fn zero(_: anytype) FoldOffset {
        return .{};
    }
    pub fn addSummary(self: *FoldOffset, summary: *const TransformSummary, _: anytype) void {
        self.value += summary.output.len;
    }
};

const TransformSummary = struct {
    input: TextSummary = .{},
    output: TextSummary = .{},
    pub fn zero(_: void) TransformSummary {
        return .{};
    }
    pub fn addSummary(self: *TransformSummary, other: *const TransformSummary, _: void) void {
        self.input.addAssign(&other.input);
        self.output.addAssign(&other.output);
    }
    pub fn handlesDimension(comptime D: type) bool {
        return D == InlayOffset;
    }
    pub fn dimensionZero(comptime D: type, _: void) D {
        return .{};
    }
    pub fn addToDimension(comptime D: type, dimension: *D, summary: *const TransformSummary, _: void) void {
        if (D == InlayOffset) dimension.value += summary.input.len;
    }
};
const Transform = struct {
    input: TextSummary,
    output: TextSummary,
    placeholder: ?rope.Rope = null,
    pub const Summary = TransformSummary;
    pub fn summary(self: *const Transform, _: void) TransformSummary {
        return .{ .input = self.input, .output = self.output };
    }
    pub fn retain(self: *const Transform) Transform {
        var copy = self.*;
        if (self.placeholder) |*p| copy.placeholder = p.clone();
        return copy;
    }
    pub fn release(self: *Transform, a: Allocator) void {
        if (self.placeholder) |*p| p.deinit(a);
    }
};
const Transforms = st.SumTree(Transform);

pub const FoldSnapshot = struct {
    inlay_snapshot: im.InlaySnapshot,
    transforms: Transforms,
    version: usize,
    pub fn clone(self: *const FoldSnapshot) FoldSnapshot {
        return .{ .inlay_snapshot = self.inlay_snapshot.clone(), .transforms = self.transforms.clone(), .version = self.version };
    }
    pub fn deinit(self: *FoldSnapshot, a: Allocator) void {
        self.transforms.deinit(a);
        self.inlay_snapshot.deinit(a);
    }
    pub fn len(self: *const FoldSnapshot) FoldOffset {
        return .{ .value = self.transforms.summary().output.len };
    }

    /// Input inside a fold maps to the placeholder edge selected by bias;
    /// the fold's starting boundary always maps to its start.
    pub fn toFoldOffset(self: *const FoldSnapshot, value: InlayOffset, bias: Bias) FoldOffset {
        const target = InlayOffset{ .value = @min(value.value, self.inlay_snapshot.len().value) };
        const found = self.transforms.find(Dims(InlayOffset, FoldOffset, void), {}, target, .right);
        const item = found.item orelse return self.len();
        if (item.placeholder != null) {
            if (bias == .left or target.value == found.start.d1.value) return found.start.d2;
            return found.end.d2;
        }
        return .{ .value = found.start.d2.value + target.value - found.start.d1.value };
    }

    /// A position within placeholder text clips to the requested edge.
    pub fn toInlayOffset(self: *const FoldSnapshot, value: FoldOffset, bias: Bias) InlayOffset {
        const target = FoldOffset{ .value = @min(value.value, self.len().value) };
        const found = self.transforms.find(Dims(FoldOffset, InlayOffset, void), {}, target, .right);
        const item = found.item orelse return self.inlay_snapshot.len();
        if (item.placeholder != null) {
            if (bias == .left or target.value == found.start.d1.value) return found.start.d2;
            return found.end.d2;
        }
        return .{ .value = found.start.d2.value + target.value - found.start.d1.value };
    }
    pub fn clipOffset(self: *const FoldSnapshot, value: FoldOffset, bias: Bias) FoldOffset {
        const target = FoldOffset{ .value = @min(value.value, self.len().value) };
        const found = self.transforms.find(Dims(FoldOffset, InlayOffset, void), {}, target, .right);
        const item = found.item orelse return self.len();
        if (item.placeholder != null) {
            if (bias == .left or target.value == found.start.d1.value) return found.start.d1;
            return found.end.d1;
        }
        const input = InlayOffset{ .value = found.start.d2.value + target.value - found.start.d1.value };
        const point = self.inlay_snapshot.toPoint(input);
        const clipped = self.inlay_snapshot.toOffset(self.inlay_snapshot.clipPoint(point, bias));
        return self.toFoldOffset(clipped, bias);
    }
    pub fn textAlloc(self: *const FoldSnapshot, a: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        var c = self.transforms.cursor(Dims(InlayOffset, FoldOffset, void), {});
        _ = c.seek(InlayOffset{}, .right);
        while (c.item()) |item| : (c.next()) {
            if (item.placeholder) |*placeholder| {
                var chunks = placeholder.chunksAll();
                while (chunks.next()) |s| try out.appendSlice(a, s);
            } else {
                const start = c.start().d1;
                const end = c.end().d1;
                var chunks = self.inlay_snapshot.chunks(start, end, .{ .tree_sitter = false, .diagnostics = false });
                while (chunks.next()) |chunk| try out.appendSlice(a, chunk.chunk.text);
            }
        }
        return out.toOwnedSlice(a);
    }
};

const Fold = struct { start: mb.Anchor, end: mb.Anchor, placeholder: rope.Rope, merge_adjacent: bool };
const Resolved = struct { start: usize, end: usize, fold_index: usize };

pub const FoldMap = struct {
    allocator: Allocator,
    snapshot: FoldSnapshot,
    folds: std.ArrayList(Fold) = .empty,

    /// Clones the lower snapshot; caller retains its own copy.
    pub fn init(a: Allocator, lower: *const im.InlaySnapshot) Allocator.Error!FoldMap {
        const summary = lower.textSummary();
        const transforms = try Transforms.fromItem(a, .{ .input = summary, .output = summary }, {});
        return .{ .allocator = a, .snapshot = .{ .inlay_snapshot = lower.clone(), .transforms = transforms, .version = 0 } };
    }
    pub fn deinit(self: *FoldMap) void {
        self.snapshot.deinit(self.allocator);
        for (self.folds.items) |*item| item.placeholder.deinit(self.allocator);
        self.folds.deinit(self.allocator);
    }
    /// Range is in buffer bytes and must be a valid UTF-8 boundary. Empty ranges
    /// are ignored as in Zed. Anchors retain identity across lower edits.
    pub fn fold(self: *FoldMap, start: usize, end: usize, placeholder: []const u8, merge_adjacent: bool) !void {
        const lower = &self.snapshot.inlay_snapshot;
        if (start > end or end > lower.buffer.len() or lower.buffer.clipOffset(start, .left) != start or lower.buffer.clipOffset(end, .left) != end or !std.unicode.utf8ValidateSlice(placeholder) or placeholder.len == 0) return error.InvalidFold;
        if (start == end) return;
        var replacement = try rope.Rope.fromStr(self.allocator, placeholder);
        errdefer replacement.deinit(self.allocator);
        try self.folds.append(self.allocator, .{ .start = lower.buffer.anchorAfter(start), .end = lower.buffer.anchorBefore(end), .placeholder = replacement, .merge_adjacent = merge_adjacent });
        errdefer _ = self.folds.pop();
        try self.rebuild(lower);
    }
    /// Re-resolves anchors against an updated lower snapshot. This is a full
    /// rebuild and does not yet return the invalidation edits Zed emits.
    pub fn sync(self: *FoldMap, lower: *const im.InlaySnapshot) !void {
        try self.rebuild(lower);
    }

    fn rebuild(self: *FoldMap, lower: *const im.InlaySnapshot) !void {
        const a = self.allocator;
        var resolved: std.ArrayList(Resolved) = .empty;
        defer resolved.deinit(a);
        for (self.folds.items, 0..) |fold_item, index| {
            const start = lower.toInlayOffset(lower.buffer.toOffset(fold_item.start)).value;
            const end = lower.toInlayOffset(lower.buffer.toOffset(fold_item.end)).value;
            if (start < end) try resolved.append(a, .{ .start = start, .end = end, .fold_index = index });
        }
        std.mem.sort(Resolved, resolved.items, {}, struct {
            fn less(_: void, x: Resolved, y: Resolved) bool {
                if (x.start != y.start) return x.start < y.start;
                if (x.end != y.end) return x.end > y.end;
                return x.fold_index < y.fold_index;
            }
        }.less);
        var items: std.ArrayList(Transform) = .empty;
        defer items.deinit(a);
        var transferred = false;
        defer if (!transferred) for (items.items) |*item| item.release(a);
        var pos: usize = 0;
        var i: usize = 0;
        while (i < resolved.items.len) {
            const first = resolved.items[i];
            var end = first.end;
            i += 1;
            while (i < resolved.items.len) {
                const next = resolved.items[i];
                if (!(next.start < end or (next.start == end and self.folds.items[first.fold_index].merge_adjacent and self.folds.items[next.fold_index].merge_adjacent))) break;
                end = @max(end, next.end);
                i += 1;
            }
            if (pos < first.start) {
                const s = lower.textSummaryForRange(.{ .value = pos }, .{ .value = first.start });
                try items.append(a, .{ .input = s, .output = s });
            }
            const p = self.folds.items[first.fold_index].placeholder.clone();
            items.append(a, .{ .input = lower.textSummaryForRange(.{ .value = first.start }, .{ .value = end }), .output = p.summary(), .placeholder = p }) catch |err| {
                var to_free = p;
                to_free.deinit(a);
                return err;
            };
            pos = end;
        }
        if (pos < lower.len().value) {
            const s = lower.textSummaryForRange(.{ .value = pos }, lower.len());
            try items.append(a, .{ .input = s, .output = s });
        }
        transferred = true; // fromItems consumes the items on success and failure
        const tree = try Transforms.fromItems(a, items.items, {});
        const replacement: FoldSnapshot = .{ .inlay_snapshot = lower.clone(), .transforms = tree, .version = self.snapshot.version + 1 };
        self.snapshot.deinit(a);
        self.snapshot = replacement;
    }
};

test "folds merge and preserve snapshot text and biased boundaries" {
    const a = std.testing.allocator;
    const text = @import("../../text/zed/root.zig");
    var multi = try mb.MultiBuffer.singleton(a, try text.Buffer.init(a, .local, try text.BufferId.new(1), "abcdefghijkl"));
    defer multi.deinit();
    var created = try im.InlayMap.init(a, multi.snapshot());
    defer created.map.deinit();
    defer created.snapshot.deinit(a);
    var map = try FoldMap.init(a, &created.snapshot);
    defer map.deinit();
    try map.fold(5, 8, "⋯", true);
    var saved = map.snapshot.clone();
    defer saved.deinit(a);
    try map.fold(2, 5, "⋯", true);
    try map.fold(8, 10, "⋯", true);
    const actual = try map.snapshot.textAlloc(a);
    defer a.free(actual);
    try std.testing.expectEqualStrings("ab⋯kl", actual);
    const old = try saved.textAlloc(a);
    defer a.free(old);
    try std.testing.expectEqualStrings("abcde⋯ijkl", old);
    try std.testing.expectEqual(@as(usize, 2), map.snapshot.toFoldOffset(.{ .value = 4 }, .left).value);
    try std.testing.expectEqual(@as(usize, 5), map.snapshot.toFoldOffset(.{ .value = 4 }, .right).value);
    try std.testing.expectEqual(@as(usize, 2), map.snapshot.toFoldOffset(.{ .value = 2 }, .right).value);
    try std.testing.expectEqual(@as(usize, 2), map.snapshot.toInlayOffset(.{ .value = 3 }, .left).value);
    try std.testing.expectEqual(@as(usize, 10), map.snapshot.toInlayOffset(.{ .value = 3 }, .right).value);
    try std.testing.expectEqual(@as(usize, 2), map.snapshot.clipOffset(.{ .value = 3 }, .left).value);
    try std.testing.expectEqual(@as(usize, 5), map.snapshot.clipOffset(.{ .value = 3 }, .right).value);
}

test "reference basic folds produce the expected visible text" {
    const a = std.testing.allocator;
    const text = @import("../../text/zed/root.zig");
    var multi = try mb.MultiBuffer.singleton(a, try text.Buffer.init(a, .local, try text.BufferId.new(1), "aaaaaa\nbbbbbb\ncccccc\ndddddd\neeeeee"));
    defer multi.deinit();
    var created = try im.InlayMap.init(a, multi.snapshot());
    defer created.map.deinit();
    defer created.snapshot.deinit(a);
    var map = try FoldMap.init(a, &created.snapshot);
    defer map.deinit();
    try map.fold(2, 16, "⋯", true);
    try map.fold(18, 29, "⋯", true);
    const actual = try map.snapshot.textAlloc(a);
    defer a.free(actual);
    try std.testing.expectEqualStrings("aa⋯cc⋯eeeee", actual);
}

test "nonmerging adjacent folds and invalid UTF-8 boundaries" {
    const a = std.testing.allocator;
    const text = @import("../../text/zed/root.zig");
    var multi = try mb.MultiBuffer.singleton(a, try text.Buffer.init(a, .local, try text.BufferId.new(1), "aébc"));
    defer multi.deinit();
    var created = try im.InlayMap.init(a, multi.snapshot());
    defer created.map.deinit();
    defer created.snapshot.deinit(a);
    var map = try FoldMap.init(a, &created.snapshot);
    defer map.deinit();
    try std.testing.expectError(error.InvalidFold, map.fold(2, 3, "⋯", true));
    try map.fold(1, 3, "⋯", false);
    try map.fold(3, 4, "⋯", false);
    const actual = try map.snapshot.textAlloc(a);
    defer a.free(actual);
    try std.testing.expectEqualStrings("a⋯⋯c", actual);
}

test "anchors resolve after lower text edits" {
    const a = std.testing.allocator;
    const text = @import("../../text/zed/root.zig");
    var multi = try mb.MultiBuffer.singleton(a, try text.Buffer.init(a, .local, try text.BufferId.new(1), "abcdefghijkl"));
    defer multi.deinit();
    const edits = try multi.subscribe();
    defer edits.release(a);
    var inlays = try im.InlayMap.init(a, multi.snapshot());
    defer inlays.map.deinit();
    defer inlays.snapshot.deinit(a);
    var map = try FoldMap.init(a, &inlays.snapshot);
    defer map.deinit();
    try map.fold(3, 8, "⋯", true);
    var old = map.snapshot.clone();
    defer old.deinit(a);
    try multi.edit(&.{.{ .start = 0, .end = 0, .text = "XY" }});
    var patch = edits.consume();
    defer patch.deinit(a);
    var result = try inlays.map.sync(multi.snapshot(), patch.edits());
    defer result.deinit(a);
    try map.sync(&result.snapshot);
    const now = try map.snapshot.textAlloc(a);
    defer a.free(now);
    try std.testing.expectEqualStrings("XYabc⋯ijkl", now);
    const before = try old.textAlloc(a);
    defer a.free(before);
    try std.testing.expectEqualStrings("abc⋯ijkl", before);
}

test "fold output preserves inlays outside folded buffer range" {
    const a = std.testing.allocator;
    const text = @import("../../text/zed/root.zig");
    var multi = try mb.MultiBuffer.singleton(a, try text.Buffer.init(a, .local, try text.BufferId.new(1), "abcdef"));
    defer multi.deinit();
    var inlays = try im.InlayMap.init(a, multi.snapshot());
    defer inlays.map.deinit();
    defer inlays.snapshot.deinit(a);
    const hint = try im.Inlay.mockHint(a, 1, inlays.snapshot.buffer.anchorAt(@as(usize, 1), .right), "[hint]");
    var result = try inlays.map.splice(&.{}, &.{hint});
    defer result.deinit(a);
    var map = try FoldMap.init(a, &result.snapshot);
    defer map.deinit();
    try map.fold(3, 5, "⋯", true);
    const output = try map.snapshot.textAlloc(a);
    defer a.free(output);
    try std.testing.expectEqualStrings("a[hint]bc⋯f", output);
}
