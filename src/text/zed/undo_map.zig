//! Port of Zed's `text::UndoMap` (`.ref/zed/crates/text/src/undo_map.rs`): for each
//! edit, the undo count recorded by each undo operation. An edit is undone when its
//! count is odd.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const clock = @import("../../clock/clock.zig");
const st = @import("../../sum_tree/sum_tree.zig");
const Lamport = clock.Lamport;

pub const UndoMapKey = struct {
    edit_id: Lamport,
    undo_id: Lamport,

    pub fn zero(_: void) UndoMapKey {
        return .{ .edit_id = Lamport.min, .undo_id = Lamport.min };
    }

    pub fn addSummary(self: *UndoMapKey, other: *const UndoMapKey, _: void) void {
        if (self.cmp(other) == .lt) self.* = other.*;
    }

    pub fn cmp(a: *const UndoMapKey, b: *const UndoMapKey) Order {
        return switch (a.edit_id.cmp(&b.edit_id)) {
            .eq => a.undo_id.cmp(&b.undo_id),
            else => |order| order,
        };
    }
};

const UndoMapEntry = struct {
    entry_key: UndoMapKey,
    undo_count: u32,

    pub const Summary = UndoMapKey;
    pub const Key = UndoMapKey;

    pub fn summary(self: *const UndoMapEntry, _: void) UndoMapKey {
        return self.entry_key;
    }

    pub fn key(self: *const UndoMapEntry) UndoMapKey {
        return self.entry_key;
    }
};

/// One `(edit_id, count)` pair of an `UndoOperation`.
pub const UndoCount = struct { edit_id: Lamport, count: u32 };

pub const UndoMap = struct {
    const Tree = st.SumTree(UndoMapEntry);
    tree: Tree,

    pub fn init(gpa: Allocator) Allocator.Error!UndoMap {
        return .{ .tree = try Tree.init(gpa, {}) };
    }

    pub fn deinit(self: *UndoMap, gpa: Allocator) void {
        self.tree.deinit(gpa);
    }

    pub fn clone(self: *const UndoMap) UndoMap {
        return .{ .tree = self.tree.clone() };
    }

    pub fn insert(self: *UndoMap, gpa: Allocator, undo_timestamp: Lamport, counts: []const UndoCount) Allocator.Error!void {
        const edits = try gpa.alloc(Tree.KeyedEdit, counts.len);
        defer gpa.free(edits);
        for (counts, edits) |entry, *e| {
            e.* = .{ .insert = .{ .entry_key = .{ .edit_id = entry.edit_id, .undo_id = undo_timestamp }, .undo_count = entry.count } };
        }
        var removed = try self.tree.edit(gpa, edits, {});
        removed.deinit(gpa);
    }

    pub fn isUndone(self: *const UndoMap, edit_id: Lamport) bool {
        return self.undoCount(edit_id) % 2 == 1;
    }

    pub fn wasUndone(self: *const UndoMap, edit_id: Lamport, version: *const clock.Global) bool {
        var c = self.tree.cursor(UndoMapKey, {});
        _ = c.seek(UndoMapKey{ .edit_id = edit_id, .undo_id = Lamport.min }, .left);
        var undo_count: u32 = 0;
        while (c.nextIter()) |entry| {
            if (!entry.entry_key.edit_id.eql(edit_id)) break;
            if (version.observed(entry.entry_key.undo_id)) undo_count = @max(undo_count, entry.undo_count);
        }
        return undo_count % 2 == 1;
    }

    pub fn undoCount(self: *const UndoMap, edit_id: Lamport) u32 {
        var c = self.tree.cursor(UndoMapKey, {});
        _ = c.seek(UndoMapKey{ .edit_id = edit_id, .undo_id = Lamport.min }, .left);
        var undo_count: u32 = 0;
        while (c.nextIter()) |entry| {
            if (!entry.entry_key.edit_id.eql(edit_id)) break;
            undo_count = @max(undo_count, entry.undo_count);
        }
        return undo_count;
    }
};

const testing = std.testing;

test "undo counts" {
    const gpa = testing.allocator;
    var map = try UndoMap.init(gpa);
    defer map.deinit(gpa);
    const edit_a: Lamport = .{ .value = 2, .replica_id = .new(0) };
    const edit_b: Lamport = .{ .value = 3, .replica_id = .new(0) };
    try testing.expect(!map.isUndone(edit_a));
    try map.insert(gpa, .{ .value = 4, .replica_id = .new(0) }, &.{ .{ .edit_id = edit_a, .count = 1 }, .{ .edit_id = edit_b, .count = 1 } });
    try testing.expect(map.isUndone(edit_a));
    try testing.expect(map.isUndone(edit_b));
    try map.insert(gpa, .{ .value = 5, .replica_id = .new(0) }, &.{.{ .edit_id = edit_a, .count = 2 }});
    try testing.expect(!map.isUndone(edit_a));
    try testing.expect(map.isUndone(edit_b));
    try testing.expectEqual(@as(u32, 2), map.undoCount(edit_a));

    var version: clock.Global = .empty;
    version.observe(.{ .value = 4, .replica_id = .new(0) });
    try testing.expect(map.wasUndone(edit_a, &version));
    version.observe(.{ .value = 5, .replica_id = .new(0) });
    try testing.expect(!map.wasUndone(edit_a, &version));
}
