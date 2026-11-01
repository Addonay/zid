//! Port of Zed's `text::Buffer` / `BufferSnapshot` (`.ref/zed/crates/text/src/text.rs`,
//! `anchor.rs`). Spec: docs/zed_port/text.md.
//!
//! The buffer is a sequence of fragments ordered by `Locator`. Insertions add visible
//! fragments; deletions mark fragments invisible and move their bytes from
//! `visible_text` to `deleted_text`. Undo flips visibility through the `UndoMap`.
//! Anchors name a position as (insertion timestamp, offset in that insertion, bias)
//! and resolve through the `insertions` tree.
//!
//! Port notes:
//! - Locators and fragment deletion lists live in a refcounted arena shared by the
//!   buffer and its snapshots, so fragments and summaries stay plain values.
//! - Replication (`apply_ops`, deferred ops, the operation log, `wait_for_*`,
//!   `VersionedFullOffset`) is not ported; local editing, undo/redo, anchors,
//!   subscriptions and `edits_since` are.
//! - `clock.Global` holds 8 replica slots, enough for all non-collaborative ids.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const clock = @import("../../clock/clock.zig");
const st = @import("../../sum_tree/sum_tree.zig");
const rope_mod = @import("../../rope/rope.zig");
pub const Locator = @import("locator.zig").Locator;
const undo_map_mod = @import("undo_map.zig");
const UndoMap = undo_map_mod.UndoMap;
const UndoCount = undo_map_mod.UndoCount;
const patch_mod = @import("patch.zig");
const line = @import("line.zig");
const subscription_mod = @import("subscription.zig");

pub const Rope = rope_mod.Rope;
pub const Point = rope_mod.Point;
pub const PointUtf16 = rope_mod.PointUtf16;
pub const OffsetUtf16 = rope_mod.OffsetUtf16;
pub const TextSummary = rope_mod.TextSummary;
pub const TextDimension = rope_mod.TextDimension;
pub const Unclipped = rope_mod.Unclipped;
pub const Bias = st.Bias;
pub const Lamport = clock.Lamport;
pub const Global = clock.Global;
pub const ReplicaId = clock.ReplicaId;
pub const LineEnding = line.LineEnding;
pub const Patch = patch_mod.Patch;
pub const Edit = patch_mod.Edit;
pub const Subscription = subscription_mod.Subscription(usize);

/// Longest single fragment; larger insertions are split so offsets fit in `u32`.
pub const max_insertion_len: usize = if (builtin.is_test) 16 else std.math.maxInt(u32);

pub const TransactionId = Lamport;
/// Monotonic nanoseconds (`std.Io.Clock.awake`).
pub const Instant = i96;

pub const BufferId = enum(u64) {
    _,

    pub fn new(id: u64) error{ZeroBufferId}!BufferId {
        if (id == 0) return error.ZeroBufferId;
        return @enumFromInt(id);
    }

    pub fn toU64(self: BufferId) u64 {
        return @intFromEnum(self);
    }
};

/// Arena shared by a buffer and its snapshots for locator and deletion storage.
const Store = struct {
    ref_count: std.atomic.Value(u32) = .init(1),
    arena: std.heap.ArenaAllocator,

    fn create(gpa: Allocator) Allocator.Error!*Store {
        const store = try gpa.create(Store);
        store.* = .{ .arena = .init(gpa) };
        return store;
    }

    fn retain(self: *Store) *Store {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    fn release(self: *Store, gpa: Allocator) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.arena.deinit();
            gpa.destroy(self);
        }
    }
};

// ---------------------------------------------------------------------------
// Fragments

pub const FragmentTextSummary = struct {
    visible: usize = 0,
    deleted: usize = 0,

    pub fn zero(_: anytype) FragmentTextSummary {
        return .{};
    }

    pub fn addSummary(self: *FragmentTextSummary, summary: anytype, _: anytype) void {
        self.visible += summary.text.visible;
        self.deleted += summary.text.deleted;
    }

    /// `impl SeekTarget<FragmentTextSummary> for usize` compares visible offsets.
    pub fn seekOrder(target: anytype, location: *const FragmentTextSummary, _: anytype) Order {
        comptime std.debug.assert(@TypeOf(target.*) == usize);
        return std.math.order(target.*, location.visible);
    }
};

const FragmentContext = ?*const Global;

pub const FragmentSummary = struct {
    text: FragmentTextSummary = .{},
    max_id: Locator = .min,
    max_version: Global = .empty,
    min_insertion_version: Global = .empty,
    max_insertion_version: Global = .empty,

    pub const Context = FragmentContext;

    pub fn zero(_: FragmentContext) FragmentSummary {
        return .{};
    }

    pub fn addSummary(self: *FragmentSummary, other: *const FragmentSummary, _: FragmentContext) void {
        self.max_id = other.max_id;
        self.text.visible += other.text.visible;
        self.text.deleted += other.text.deleted;
        self.max_version.join(&other.max_version);
        self.min_insertion_version.meet(&other.min_insertion_version);
        self.max_insertion_version.join(&other.max_insertion_version);
    }

    /// `impl Dimension<FragmentSummary> for usize` counts visible bytes.
    pub fn dimensionZero(comptime D: type, _: FragmentContext) D {
        comptime std.debug.assert(D == usize);
        return 0;
    }

    pub fn addToDimension(comptime D: type, dimension: *D, summary: *const FragmentSummary, _: FragmentContext) void {
        comptime std.debug.assert(D == usize);
        dimension.* += summary.text.visible;
    }
};

/// Offset counting visible and deleted bytes (`FullOffset`).
pub const FullOffset = struct {
    value: usize = 0,

    pub fn zero(_: anytype) FullOffset {
        return .{};
    }

    pub fn addSummary(self: *FullOffset, summary: anytype, _: anytype) void {
        self.value += summary.text.visible + summary.text.deleted;
    }

    pub fn cmp(a: *const FullOffset, b: *const FullOffset) Order {
        return std.math.order(a.value, b.value);
    }
};

/// Zed's `Option<&Locator>` dimension: the max fragment id seen so far.
pub const FragmentIdDim = struct {
    id: ?Locator = null,

    pub fn zero(_: anytype) FragmentIdDim {
        return .{};
    }

    pub fn addSummary(self: *FragmentIdDim, summary: anytype, _: anytype) void {
        self.id = summary.max_id;
    }

    pub fn cmp(a: *const FragmentIdDim, b: *const FragmentIdDim) Order {
        if (a.id == null) return if (b.id == null) .eq else .lt;
        if (b.id == null) return .gt;
        return a.id.?.cmp(&b.id.?);
    }
};

pub const Fragment = struct {
    id: Locator,
    timestamp: Lamport,
    insertion_offset: u32,
    len: u32,
    visible: bool,
    deletions: []const Lamport = &.{},
    max_undos: Global = .empty,

    pub const Summary = FragmentSummary;

    pub fn summary(self: *const Fragment, _: FragmentContext) FragmentSummary {
        var max_version: Global = .empty;
        max_version.observe(self.timestamp);
        for (self.deletions) |deletion| max_version.observe(deletion);
        max_version.join(&self.max_undos);
        var min_insertion_version: Global = .empty;
        min_insertion_version.observe(self.timestamp);
        return .{
            .max_id = self.id,
            .text = if (self.visible) .{ .visible = self.len } else .{ .deleted = self.len },
            .max_version = max_version,
            .min_insertion_version = min_insertion_version,
            .max_insertion_version = min_insertion_version,
        };
    }

    pub fn isVisible(self: *const Fragment, undos: *const UndoMap) bool {
        if (undos.isUndone(self.timestamp)) return false;
        for (self.deletions) |deletion| if (!undos.isUndone(deletion)) return false;
        return true;
    }

    pub fn wasVisible(self: *const Fragment, version: *const Global, undos: *const UndoMap) bool {
        if (!(version.observed(self.timestamp) and !undos.wasUndone(self.timestamp, version))) return false;
        for (self.deletions) |deletion| {
            if (version.observed(deletion) and !undos.wasUndone(deletion, version)) return false;
        }
        return true;
    }
};

pub const InsertionFragmentKey = struct {
    timestamp: Lamport,
    split_offset: u32,

    pub fn zero(_: void) InsertionFragmentKey {
        return .{ .timestamp = Lamport.min, .split_offset = 0 };
    }

    pub fn addSummary(self: *InsertionFragmentKey, other: *const InsertionFragmentKey, _: void) void {
        self.* = other.*;
    }

    pub fn cmp(a: *const InsertionFragmentKey, b: *const InsertionFragmentKey) Order {
        return switch (a.timestamp.cmp(&b.timestamp)) {
            .eq => std.math.order(a.split_offset, b.split_offset),
            else => |order| order,
        };
    }
};

pub const InsertionFragment = struct {
    timestamp: Lamport,
    split_offset: u32,
    fragment_id: Locator,

    pub const Summary = InsertionFragmentKey;
    pub const Key = InsertionFragmentKey;

    pub fn summary(self: *const InsertionFragment, _: void) InsertionFragmentKey {
        return .{ .timestamp = self.timestamp, .split_offset = self.split_offset };
    }

    pub fn key(self: *const InsertionFragment) InsertionFragmentKey {
        return self.summary({});
    }

    fn fromFragment(fragment: *const Fragment) InsertionFragment {
        return .{ .timestamp = fragment.timestamp, .split_offset = fragment.insertion_offset, .fragment_id = fragment.id };
    }
};

/// The part of an insertion touched by an edit; a `TreeSet` in Zed.
pub const InsertionSlice = struct {
    edit_id: Lamport,
    insertion_id: Lamport,
    start: u32,
    end: u32,

    pub const Summary = InsertionSlice;
    pub const Key = InsertionSlice;

    pub fn summary(self: *const InsertionSlice, _: void) InsertionSlice {
        return self.*;
    }

    pub fn key(self: *const InsertionSlice) InsertionSlice {
        return self.*;
    }

    pub fn zero(_: void) InsertionSlice {
        return .{ .edit_id = Lamport.min, .insertion_id = Lamport.min, .start = 0, .end = 0 };
    }

    pub fn addSummary(self: *InsertionSlice, other: *const InsertionSlice, _: void) void {
        self.* = other.*;
    }

    pub fn cmp(a: *const InsertionSlice, b: *const InsertionSlice) Order {
        var order = a.edit_id.cmp(&b.edit_id);
        if (order != .eq) return order;
        order = a.insertion_id.cmp(&b.insertion_id);
        if (order != .eq) return order;
        order = std.math.order(a.start, b.start);
        if (order != .eq) return order;
        return std.math.order(a.end, b.end);
    }

    fn fromFragment(edit_id: Lamport, fragment: *const Fragment) InsertionSlice {
        return .{ .edit_id = edit_id, .insertion_id = fragment.timestamp, .start = fragment.insertion_offset, .end = fragment.insertion_offset + fragment.len };
    }
};

const FragmentTree = st.SumTree(Fragment);
const InsertionTree = st.SumTree(InsertionFragment);
const SliceTree = st.SumTree(InsertionSlice);

// ---------------------------------------------------------------------------
// Anchors

pub const Anchor = struct {
    timestamp_replica_id: ReplicaId,
    timestamp_value: clock.Seq,
    /// Byte offset into the text inserted at `timestamp`.
    offset: u32,
    bias: Bias,
    buffer_id: BufferId,

    pub fn init(insertion: Lamport, offset: u32, bias: Bias, buffer_id: BufferId) Anchor {
        return .{ .timestamp_replica_id = insertion.replica_id, .timestamp_value = insertion.value, .offset = offset, .bias = bias, .buffer_id = buffer_id };
    }

    pub fn minForBuffer(buffer_id: BufferId) Anchor {
        return init(Lamport.min, 0, .left, buffer_id);
    }

    pub fn maxForBuffer(buffer_id: BufferId) Anchor {
        return init(Lamport.max, std.math.maxInt(u32), .right, buffer_id);
    }

    pub fn timestamp(self: Anchor) Lamport {
        return .{ .replica_id = self.timestamp_replica_id, .value = self.timestamp_value };
    }

    pub fn isMin(self: Anchor) bool {
        return self.timestamp().eql(Lamport.min) and self.offset == 0 and self.bias == .left;
    }

    pub fn isMax(self: Anchor) bool {
        return self.timestamp().eql(Lamport.max) and self.offset == std.math.maxInt(u32) and self.bias == .right;
    }

    pub fn eql(a: Anchor, b: Anchor) bool {
        return std.meta.eql(a, b);
    }

    pub fn cmp(self: Anchor, other: Anchor, buffer: *const BufferSnapshot) Order {
        const fragment_order: Order = if (self.timestamp().eql(other.timestamp())) .eq else blk: {
            const a = buffer.fragmentIdForAnchor(self);
            const b = buffer.fragmentIdForAnchor(other);
            break :blk a.cmp(&b);
        };
        if (fragment_order != .eq) return fragment_order;
        const offset_order = std.math.order(self.offset, other.offset);
        if (offset_order != .eq) return offset_order;
        return std.math.order(@intFromEnum(self.bias), @intFromEnum(other.bias));
    }

    pub fn biasLeft(self: Anchor, buffer: *const BufferSnapshot) Anchor {
        return switch (self.bias) {
            .left => self,
            .right => buffer.anchorBefore(self),
        };
    }

    pub fn biasRight(self: Anchor, buffer: *const BufferSnapshot) Anchor {
        return switch (self.bias) {
            .left => buffer.anchorAfter(self),
            .right => self,
        };
    }

    pub fn summary(self: Anchor, comptime D: type, buffer: *const BufferSnapshot) D {
        return buffer.summaryForAnchor(D, self);
    }

    /// Whether the anchor lies inside a visible fragment.
    pub fn isValid(self: Anchor, buffer: *const BufferSnapshot) bool {
        if (self.buffer_id != buffer.remote_id) return false;
        if (self.isMin() or self.isMax()) return true;
        const fragment_id = buffer.tryFragmentIdForAnchor(self) orelse return false;
        const found = buffer.fragments.find(st.Dimensions(FragmentIdDim, usize, void), null, FragmentIdDim{ .id = fragment_id }, .left);
        return if (found.item) |fragment| fragment.visible else false;
    }
};

pub const AnchorRange = struct { start: Anchor, end: Anchor };

// ---------------------------------------------------------------------------
// History

pub const Transaction = struct {
    id: TransactionId,
    edit_ids: std.ArrayList(Lamport) = .empty,
    start: Global,

    pub fn deinit(self: *Transaction, gpa: Allocator) void {
        self.edit_ids.deinit(gpa);
    }

    pub fn clone(self: *const Transaction, gpa: Allocator) Allocator.Error!Transaction {
        return .{ .id = self.id, .edit_ids = try self.edit_ids.clone(gpa), .start = self.start };
    }

    pub fn mergeIn(self: *Transaction, gpa: Allocator, other: Transaction) Allocator.Error!void {
        var owned = other;
        defer owned.deinit(gpa);
        try self.edit_ids.appendSlice(gpa, owned.edit_ids.items);
    }
};

pub const HistoryEntry = struct {
    transaction: Transaction,
    first_edit_at: Instant,
    last_edit_at: Instant,
    suppress_grouping: bool = false,

    pub fn transactionId(self: *const HistoryEntry) TransactionId {
        return self.transaction.id;
    }
};

const History = struct {
    base_text: Rope,
    undo_stack: std.ArrayList(HistoryEntry) = .empty,
    redo_stack: std.ArrayList(HistoryEntry) = .empty,
    transaction_depth: usize = 0,
    /// Zed disables grouping in tests unless opted in.
    group_interval: Instant = if (builtin.is_test) 0 else 300 * std.time.ns_per_ms,

    fn deinit(self: *History, gpa: Allocator) void {
        for (self.undo_stack.items) |*entry| entry.transaction.deinit(gpa);
        for (self.redo_stack.items) |*entry| entry.transaction.deinit(gpa);
        self.undo_stack.deinit(gpa);
        self.redo_stack.deinit(gpa);
        self.base_text.deinit(gpa);
    }

    fn clearRedo(self: *History, gpa: Allocator) void {
        for (self.redo_stack.items) |*entry| entry.transaction.deinit(gpa);
        self.redo_stack.clearRetainingCapacity();
    }

    fn startTransaction(self: *History, gpa: Allocator, start: Global, now: Instant, lamport: *Lamport) Allocator.Error!?TransactionId {
        self.transaction_depth += 1;
        if (self.transaction_depth != 1) return null;
        const id = lamport.tick();
        try self.undo_stack.append(gpa, .{ .transaction = .{ .id = id, .start = start }, .first_edit_at = now, .last_edit_at = now });
        return id;
    }

    fn endTransaction(self: *History, gpa: Allocator, now: Instant) ?*HistoryEntry {
        std.debug.assert(self.transaction_depth != 0);
        self.transaction_depth -= 1;
        if (self.transaction_depth != 0) return null;
        const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
        if (last.transaction.edit_ids.items.len == 0) {
            var entry = self.undo_stack.pop().?;
            entry.transaction.deinit(gpa);
            return null;
        }
        self.clearRedo(gpa);
        last.last_edit_at = now;
        return last;
    }

    fn group(self: *History, gpa: Allocator) Allocator.Error!?TransactionId {
        var count: usize = 0;
        const entries = self.undo_stack.items;
        if (entries.len > 0) {
            var entry = &entries[entries.len - 1];
            var ix = entries.len - 1;
            while (ix > 0) {
                ix -= 1;
                const prev = &entries[ix];
                if (!prev.suppress_grouping and entry.first_edit_at - prev.last_edit_at < self.group_interval) {
                    entry = prev;
                    count += 1;
                } else break;
            }
        }
        return self.groupTrailing(gpa, count);
    }

    fn groupUntil(self: *History, gpa: Allocator, transaction_id: TransactionId) Allocator.Error!void {
        var count: usize = 0;
        var ix = self.undo_stack.items.len;
        while (ix > 0) {
            ix -= 1;
            const entry = &self.undo_stack.items[ix];
            if (entry.transaction.id.eql(transaction_id)) {
                _ = try self.groupTrailing(gpa, count);
                break;
            } else if (entry.suppress_grouping) {
                break;
            } else count += 1;
        }
    }

    fn groupTrailing(self: *History, gpa: Allocator, n: usize) Allocator.Error!?TransactionId {
        const new_len = self.undo_stack.items.len - n;
        if (new_len > 0) {
            const last_entry = &self.undo_stack.items[new_len - 1];
            for (self.undo_stack.items[new_len..]) |*entry| try last_entry.transaction.edit_ids.appendSlice(gpa, entry.transaction.edit_ids.items);
            if (n > 0) last_entry.last_edit_at = self.undo_stack.items[self.undo_stack.items.len - 1].last_edit_at;
        }
        for (self.undo_stack.items[new_len..]) |*entry| entry.transaction.deinit(gpa);
        self.undo_stack.items.len = new_len;
        return if (new_len == 0) null else self.undo_stack.items[new_len - 1].transaction.id;
    }

    fn finalizeLastTransaction(self: *History) ?*const Transaction {
        if (self.undo_stack.items.len == 0) return null;
        const entry = &self.undo_stack.items[self.undo_stack.items.len - 1];
        entry.suppress_grouping = true;
        return &entry.transaction;
    }

    fn pushTransaction(self: *History, gpa: Allocator, pushed: Transaction, now: Instant) Allocator.Error!void {
        std.debug.assert(self.transaction_depth == 0);
        try self.undo_stack.append(gpa, .{ .transaction = pushed, .first_edit_at = now, .last_edit_at = now });
    }

    fn pushEmptyTransaction(self: *History, gpa: Allocator, start: Global, now: Instant, lamport: *Lamport) Allocator.Error!TransactionId {
        std.debug.assert(self.transaction_depth == 0);
        const id = lamport.tick();
        try self.undo_stack.append(gpa, .{ .transaction = .{ .id = id, .start = start }, .first_edit_at = now, .last_edit_at = now });
        return id;
    }

    fn pushUndo(self: *History, gpa: Allocator, op_id: Lamport) Allocator.Error!void {
        std.debug.assert(self.transaction_depth != 0);
        // Zed checks the operation log for an edit; local `edit` always records one.
        const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
        try last.transaction.edit_ids.append(gpa, op_id);
    }

    fn popUndo(self: *History, gpa: Allocator) Allocator.Error!?*const HistoryEntry {
        std.debug.assert(self.transaction_depth == 0);
        try self.redo_stack.ensureUnusedCapacity(gpa, 1);
        const entry = self.undo_stack.pop() orelse return null;
        self.redo_stack.appendAssumeCapacity(entry);
        return &self.redo_stack.items[self.redo_stack.items.len - 1];
    }

    fn popRedo(self: *History, gpa: Allocator) Allocator.Error!?*const HistoryEntry {
        std.debug.assert(self.transaction_depth == 0);
        try self.undo_stack.ensureUnusedCapacity(gpa, 1);
        const entry = self.redo_stack.pop() orelse return null;
        self.undo_stack.appendAssumeCapacity(entry);
        return &self.undo_stack.items[self.undo_stack.items.len - 1];
    }

    fn rposition(stack: []const HistoryEntry, transaction_id: TransactionId) ?usize {
        var ix = stack.len;
        while (ix > 0) {
            ix -= 1;
            if (stack[ix].transaction.id.eql(transaction_id)) return ix;
        }
        return null;
    }

    fn removeFromUndo(self: *History, gpa: Allocator, transaction_id: TransactionId) Allocator.Error!?*const HistoryEntry {
        std.debug.assert(self.transaction_depth == 0);
        const ix = rposition(self.undo_stack.items, transaction_id) orelse return null;
        try self.redo_stack.ensureUnusedCapacity(gpa, 1);
        self.redo_stack.appendAssumeCapacity(self.undo_stack.orderedRemove(ix));
        return &self.redo_stack.items[self.redo_stack.items.len - 1];
    }

    /// Moves entries from the matching one to the top onto the redo stack (reversed);
    /// returns the moved entries.
    fn removeFromUndoUntil(self: *History, gpa: Allocator, transaction_id: TransactionId) Allocator.Error![]const HistoryEntry {
        std.debug.assert(self.transaction_depth == 0);
        const start_len = self.redo_stack.items.len;
        if (rposition(self.undo_stack.items, transaction_id)) |ix| {
            const moved = self.undo_stack.items[ix..];
            try self.redo_stack.ensureUnusedCapacity(gpa, moved.len);
            var i = moved.len;
            while (i > 0) {
                i -= 1;
                self.redo_stack.appendAssumeCapacity(moved[i]);
            }
            self.undo_stack.items.len = ix;
        }
        return self.redo_stack.items[start_len..];
    }

    fn removeFromRedo(self: *History, gpa: Allocator, transaction_id: TransactionId) Allocator.Error![]const HistoryEntry {
        std.debug.assert(self.transaction_depth == 0);
        const start_len = self.undo_stack.items.len;
        if (rposition(self.redo_stack.items, transaction_id)) |ix| {
            const moved = self.redo_stack.items[ix..];
            try self.undo_stack.ensureUnusedCapacity(gpa, moved.len);
            var i = moved.len;
            while (i > 0) {
                i -= 1;
                self.undo_stack.appendAssumeCapacity(moved[i]);
            }
            self.redo_stack.items.len = ix;
        }
        return self.undo_stack.items[start_len..];
    }

    /// Removes the transaction from either stack; the caller owns the result.
    fn forget(self: *History, transaction_id: TransactionId) ?Transaction {
        std.debug.assert(self.transaction_depth == 0);
        if (rposition(self.undo_stack.items, transaction_id)) |ix| return self.undo_stack.orderedRemove(ix).transaction;
        if (rposition(self.redo_stack.items, transaction_id)) |ix| return self.redo_stack.orderedRemove(ix).transaction;
        return null;
    }

    fn transaction(self: *History, transaction_id: TransactionId) ?*Transaction {
        if (rposition(self.undo_stack.items, transaction_id)) |ix| return &self.undo_stack.items[ix].transaction;
        if (rposition(self.redo_stack.items, transaction_id)) |ix| return &self.redo_stack.items[ix].transaction;
        return null;
    }

    fn mergeTransactions(self: *History, gpa: Allocator, source: TransactionId, destination: TransactionId) Allocator.Error!void {
        var forgotten = self.forget(source) orelse return;
        if (self.transaction(destination)) |target| {
            try target.mergeIn(gpa, forgotten);
        } else forgotten.deinit(gpa);
    }
};

// ---------------------------------------------------------------------------
// Snapshot

pub const BufferSnapshot = struct {
    store: *Store,
    visible_text: Rope,
    deleted_text: Rope,
    fragments: FragmentTree,
    insertions: InsertionTree,
    insertion_slices: SliceTree,
    undo_map: UndoMap,
    version: Global,
    remote_id: BufferId,
    replica_id: ReplicaId,
    line_ending: LineEnding,

    /// O(1) shared copy; must be released with `deinit`.
    pub fn clone(self: *const BufferSnapshot) BufferSnapshot {
        var result = self.*;
        result.store = self.store.retain();
        result.visible_text = self.visible_text.clone();
        result.deleted_text = self.deleted_text.clone();
        result.fragments = self.fragments.clone();
        result.insertions = self.insertions.clone();
        result.insertion_slices = self.insertion_slices.clone();
        result.undo_map = self.undo_map.clone();
        return result;
    }

    pub fn deinit(self: *BufferSnapshot, gpa: Allocator) void {
        self.visible_text.deinit(gpa);
        self.deleted_text.deinit(gpa);
        self.fragments.deinit(gpa);
        self.insertions.deinit(gpa);
        self.insertion_slices.deinit(gpa);
        self.undo_map.deinit(gpa);
        self.store.release(gpa);
        self.* = undefined;
    }

    pub fn asRope(self: *const BufferSnapshot) *const Rope {
        return &self.visible_text;
    }

    pub fn text(self: *const BufferSnapshot, gpa: Allocator) Allocator.Error![]u8 {
        return self.visible_text.toOwnedString(gpa);
    }

    pub fn deletedText(self: *const BufferSnapshot, gpa: Allocator) Allocator.Error![]u8 {
        return self.deleted_text.toOwnedString(gpa);
    }

    pub fn textForRange(self: *const BufferSnapshot, gpa: Allocator, start: usize, end: usize) Allocator.Error![]u8 {
        var out = try std.ArrayList(u8).initCapacity(gpa, end - start);
        var it = self.visible_text.chunksInRange(start, end);
        while (it.next()) |chunk| out.appendSliceAssumeCapacity(chunk);
        return out.toOwnedSlice(gpa);
    }

    pub fn chunksInRange(self: *const BufferSnapshot, start: usize, end: usize) rope_mod.Chunks {
        return self.visible_text.chunksInRange(start, end);
    }

    pub fn reversedChunksInRange(self: *const BufferSnapshot, start: usize, end: usize) rope_mod.Chunks {
        return self.visible_text.reversedChunksInRange(start, end);
    }

    pub fn bytesInRange(self: *const BufferSnapshot, start: usize, end: usize) rope_mod.Bytes {
        return self.visible_text.bytesInRange(start, end);
    }

    pub fn charsAt(self: *const BufferSnapshot, offset: usize) rope_mod.Chars {
        return self.visible_text.charsAt(offset);
    }

    pub fn reversedCharsAt(self: *const BufferSnapshot, offset: usize) rope_mod.Chars {
        return self.visible_text.reversedCharsAt(offset);
    }

    pub fn containsStrAt(self: *const BufferSnapshot, offset: usize, needle: []const u8) bool {
        if (offset + needle.len > self.len()) return false;
        var it = self.visible_text.chunksInRange(offset, offset + needle.len);
        return it.equalsStr(needle);
    }

    pub fn rowCount(self: *const BufferSnapshot) u32 {
        return self.maxPoint().row + 1;
    }

    pub fn len(self: *const BufferSnapshot) usize {
        return self.visible_text.len();
    }

    pub fn isEmpty(self: *const BufferSnapshot) bool {
        return self.len() == 0;
    }

    pub fn textSummary(self: *const BufferSnapshot) TextSummary {
        return self.visible_text.summary();
    }

    pub fn maxPoint(self: *const BufferSnapshot) Point {
        return self.visible_text.maxPoint();
    }

    pub fn maxPointUtf16(self: *const BufferSnapshot) PointUtf16 {
        return self.visible_text.maxPointUtf16();
    }

    pub fn pointToOffset(self: *const BufferSnapshot, p: Point) usize {
        return self.visible_text.pointToOffset(p);
    }

    pub fn pointToOffsetUtf16(self: *const BufferSnapshot, p: Point) OffsetUtf16 {
        return self.visible_text.pointToOffsetUtf16(p);
    }

    pub fn pointUtf16ToOffset(self: *const BufferSnapshot, p: PointUtf16) usize {
        return self.visible_text.pointUtf16ToOffset(p);
    }

    pub fn pointUtf16ToOffsetUtf16(self: *const BufferSnapshot, p: PointUtf16) OffsetUtf16 {
        return self.visible_text.pointUtf16ToOffsetUtf16(p);
    }

    pub fn unclippedPointUtf16ToOffset(self: *const BufferSnapshot, p: Unclipped(PointUtf16)) usize {
        return self.visible_text.unclippedPointUtf16ToOffset(p);
    }

    pub fn unclippedPointUtf16ToPoint(self: *const BufferSnapshot, p: Unclipped(PointUtf16)) Point {
        return self.visible_text.unclippedPointUtf16ToPoint(p);
    }

    pub fn offsetUtf16ToOffset(self: *const BufferSnapshot, offset: OffsetUtf16) usize {
        return self.visible_text.offsetUtf16ToOffset(offset);
    }

    pub fn offsetToOffsetUtf16(self: *const BufferSnapshot, offset: usize) OffsetUtf16 {
        return self.visible_text.offsetToOffsetUtf16(offset);
    }

    pub fn offsetToPoint(self: *const BufferSnapshot, offset: usize) Point {
        return self.visible_text.offsetToPoint(offset);
    }

    pub fn offsetToPointUtf16(self: *const BufferSnapshot, offset: usize) PointUtf16 {
        return self.visible_text.offsetToPointUtf16(offset);
    }

    pub fn pointToPointUtf16(self: *const BufferSnapshot, p: Point) PointUtf16 {
        return self.visible_text.pointToPointUtf16(p);
    }

    pub fn pointUtf16ToPoint(self: *const BufferSnapshot, p: PointUtf16) Point {
        return self.visible_text.pointUtf16ToPoint(p);
    }

    pub fn lineLen(self: *const BufferSnapshot, row: u32) u32 {
        const row_start = self.pointToOffset(.{ .row = row, .column = 0 });
        const row_end = if (row >= self.maxPoint().row) self.len() else self.pointToOffset(.{ .row = row + 1, .column = 0 }) - 1;
        return @intCast(row_end - row_start);
    }

    pub fn lineIndentForRow(self: *const BufferSnapshot, row: u32) line.LineIndent {
        var indent: line.LineIndent = .{ .tabs = 0, .spaces = 0, .line_blank = true };
        const start = self.pointToOffset(.{ .row = row, .column = 0 });
        var chunks = self.visible_text.chunksInRange(start, self.len());
        while (chunks.next()) |chunk| if (!indent.feed(chunk)) break;
        return indent;
    }

    pub fn isLineBlank(self: *const BufferSnapshot, row: u32) bool {
        return self.lineIndentForRow(row).isLineBlank();
    }

    pub fn clipOffset(self: *const BufferSnapshot, offset: usize, bias: Bias) usize {
        return self.visible_text.clipOffset(offset, bias);
    }

    pub fn clipPoint(self: *const BufferSnapshot, p: Point, bias: Bias) Point {
        return self.visible_text.clipPoint(p, bias);
    }

    pub fn clipOffsetUtf16(self: *const BufferSnapshot, offset: OffsetUtf16, bias: Bias) OffsetUtf16 {
        return self.visible_text.clipOffsetUtf16(offset, bias);
    }

    pub fn clipPointUtf16(self: *const BufferSnapshot, p: Unclipped(PointUtf16), bias: Bias) PointUtf16 {
        return self.visible_text.clipPointUtf16(p, bias);
    }

    /// Zed's `ToOffset` for `usize`, `Point`, `PointUtf16`, `OffsetUtf16` and `Anchor`.
    pub fn toOffset(self: *const BufferSnapshot, position: anytype) usize {
        const P = @TypeOf(position);
        if (P == usize or P == comptime_int) return position;
        if (P == Point) return self.pointToOffset(position);
        if (P == PointUtf16) return self.pointUtf16ToOffset(position);
        if (P == OffsetUtf16) return self.offsetUtf16ToOffset(position);
        if (P == Anchor) return self.offsetForAnchor(position);
        if (P == Unclipped(PointUtf16)) return self.unclippedPointUtf16ToOffset(position);
        @compileError("cannot convert " ++ @typeName(P) ++ " to an offset");
    }

    pub fn toPoint(self: *const BufferSnapshot, position: anytype) Point {
        if (@TypeOf(position) == Point) return position;
        if (@TypeOf(position) == Anchor) return self.summaryForAnchor(Point, position);
        return self.offsetToPoint(self.toOffset(position));
    }

    pub fn textSummaryForRange(self: *const BufferSnapshot, comptime D: type, start: usize, end: usize) D {
        var c = self.visible_text.cursor(start);
        return c.summary(D, end);
    }

    pub fn summaryForAnchor(self: *const BufferSnapshot, comptime D: type, anchor: Anchor) D {
        return self.textSummaryForRange(D, 0, self.offsetForAnchor(anchor));
    }

    pub fn offsetForAnchor(self: *const BufferSnapshot, anchor: Anchor) usize {
        if (anchor.isMin()) return 0;
        if (anchor.isMax()) return self.visible_text.len();
        std.debug.assert(anchor.buffer_id == self.remote_id);
        std.debug.assert(self.version.observed(anchor.timestamp()));
        const insertion = self.tryFindFragment(anchor) orelse @panic("invalid anchor");
        if (!insertion.timestamp.eql(anchor.timestamp())) @panic("invalid anchor");
        const found = self.fragments.find(st.Dimensions(FragmentIdDim, usize, void), null, FragmentIdDim{ .id = insertion.fragment_id }, .left);
        const fragment = found.item.?;
        var fragment_offset = found.start.d2;
        if (fragment.visible) fragment_offset += anchor.offset - insertion.split_offset;
        return fragment_offset;
    }

    /// Resolves sorted anchors with one forward pass (`summaries_for_anchors`).
    pub fn summariesForAnchors(self: *const BufferSnapshot, comptime D: type, anchors: []const Anchor, out: []D) void {
        std.debug.assert(out.len == anchors.len);
        const TD = TextDimension(D);
        var fragment_cursor = self.fragments.cursor(st.Dimensions(FragmentIdDim, usize, void), null);
        var text_cursor = self.visible_text.cursor(0);
        var position = TD.zero();
        for (anchors, out) |anchor, *result| {
            if (anchor.isMin()) {
                result.* = TD.zero();
                continue;
            }
            if (anchor.isMax()) {
                result.* = TD.fromTextSummary(&self.visible_text.summary());
                continue;
            }
            const insertion = self.tryFindFragment(anchor) orelse @panic("invalid anchor");
            std.debug.assert(insertion.timestamp.eql(anchor.timestamp()));
            _ = fragment_cursor.seekForward(FragmentIdDim{ .id = insertion.fragment_id }, .left);
            const fragment = fragment_cursor.item().?;
            var fragment_offset = fragment_cursor.start().d2;
            if (fragment.visible) fragment_offset += anchor.offset - insertion.split_offset;
            TD.addAssign(&position, &text_cursor.summary(D, fragment_offset));
            result.* = position;
        }
    }

    fn fragmentIdForAnchor(self: *const BufferSnapshot, anchor: Anchor) Locator {
        return self.tryFragmentIdForAnchor(anchor) orelse @panic("invalid anchor");
    }

    fn tryFragmentIdForAnchor(self: *const BufferSnapshot, anchor: Anchor) ?Locator {
        if (anchor.isMin()) return Locator.min;
        if (anchor.isMax()) return Locator.max;
        const insertion = self.tryFindFragment(anchor) orelse return null;
        if (std.debug.runtime_safety and !insertion.timestamp.eql(anchor.timestamp())) return null;
        return insertion.fragment_id;
    }

    fn tryFindFragment(self: *const BufferSnapshot, anchor: Anchor) ?*const InsertionFragment {
        const anchor_key: InsertionFragmentKey = .{ .timestamp = anchor.timestamp(), .split_offset = anchor.offset };
        const found = self.insertions.findWithPrev(InsertionFragmentKey, {}, anchor_key, anchor.bias);
        if (found.found) |f| {
            const insertion_key = f.item.key();
            const comparison = insertion_key.cmp(&anchor_key);
            if (comparison == .gt or (anchor.bias == .left and comparison == .eq and anchor.offset > 0)) return f.prev;
            return f.item;
        }
        return self.insertions.last();
    }

    pub fn anchorBefore(self: *const BufferSnapshot, position: anytype) Anchor {
        return self.anchorAt(position, .left);
    }

    pub fn anchorAfter(self: *const BufferSnapshot, position: anytype) Anchor {
        return self.anchorAt(position, .right);
    }

    pub fn anchorAt(self: *const BufferSnapshot, position: anytype, bias: Bias) Anchor {
        return self.anchorAtOffset(self.toOffset(position), bias);
    }

    pub fn anchorRangeInside(self: *const BufferSnapshot, start: anytype, end: anytype) AnchorRange {
        return .{ .start = self.anchorAfter(start), .end = self.anchorBefore(end) };
    }

    pub fn anchorRangeOutside(self: *const BufferSnapshot, start: anytype, end: anytype) AnchorRange {
        return .{ .start = self.anchorBefore(start), .end = self.anchorAfter(end) };
    }

    fn anchorAtOffset(self: *const BufferSnapshot, offset_in: usize, bias: Bias) Anchor {
        var offset = offset_in;
        if (bias == .left and offset == 0) return Anchor.minForBuffer(self.remote_id);
        if (bias == .right and ((!std.debug.runtime_safety and offset >= self.len()) or offset == self.len())) return Anchor.maxForBuffer(self.remote_id);
        if (!self.visible_text.isCharBoundary(offset)) {
            std.debug.assert(false);
            offset = switch (bias) {
                .left => self.visible_text.floorCharBoundary(offset),
                .right => self.visible_text.ceilCharBoundary(offset),
            };
        }
        const found = self.fragments.find(usize, null, offset, bias);
        const fragment = found.item orelse {
            std.debug.assert(false);
            return Anchor.maxForBuffer(self.remote_id);
        };
        const overshoot: u32 = @intCast(offset - found.start);
        return Anchor.init(fragment.timestamp, fragment.insertion_offset + overshoot, bias, self.remote_id);
    }

    pub fn canResolve(self: *const BufferSnapshot, anchor: Anchor) bool {
        return self.remote_id == anchor.buffer_id and (anchor.isMin() or anchor.isMax() or self.version.observed(anchor.timestamp()));
    }

    const SinceFilter = struct {
        since: *const Global,
        pub fn filter(self: SinceFilter, summary: *const FragmentSummary) bool {
            return !self.since.observedAll(&summary.max_version);
        }
    };

    pub fn hasEditsSince(self: *const BufferSnapshot, since: *const Global) bool {
        if (since.eql(&self.version)) return false;
        var c = self.fragments.filter(usize, null, SinceFilter{ .since = since });
        c.next();
        while (c.item()) |fragment| : (c.next()) {
            if (fragment.wasVisible(since, &self.undo_map) != fragment.visible) return true;
        }
        return false;
    }

    pub fn hasEditsSinceInRange(self: *const BufferSnapshot, since: *const Global, range: AnchorRange) bool {
        if (since.eql(&self.version)) return false;
        const start_id = self.fragmentIdForAnchor(range.start);
        const end_id = self.fragmentIdForAnchor(range.end);
        var c = self.fragments.filter(usize, null, SinceFilter{ .since = since });
        c.next();
        while (c.item()) |fragment| : (c.next()) {
            if (fragment.id.cmp(&end_id) == .gt) break;
            if (fragment.id.cmp(&start_id) == .gt) {
                if (fragment.wasVisible(since, &self.undo_map) != fragment.visible) return true;
            }
        }
        return false;
    }

    /// Edits between `since` and this snapshot, in dimension `D`.
    pub fn editsSince(self: *const BufferSnapshot, comptime D: type, since: *const Global) Edits(D) {
        return self.editsSinceInRange(D, since, .{ .start = Anchor.minForBuffer(self.remote_id), .end = Anchor.maxForBuffer(self.remote_id) });
    }

    pub fn editsSinceInRange(self: *const BufferSnapshot, comptime D: type, since: *const Global, range: AnchorRange) Edits(D) {
        const TD = TextDimension(D);
        var result: Edits(D) = .{
            .visible_cursor = self.visible_text.cursor(0),
            .deleted_cursor = self.deleted_text.cursor(0),
            .fragments_cursor = null,
            .undos = &self.undo_map,
            .since = since,
            .old_end = TD.zero(),
            .new_end = TD.zero(),
            .range_start = .{ .id = Locator.min, .offset = 0 },
            .range_end = .{ .id = Locator.max, .offset = 0 },
            .buffer_id = self.remote_id,
        };
        if (since.eql(&self.version)) return result;
        var c = self.fragments.filter(FragmentTextSummary, null, SinceFilter{ .since = since });
        c.next();
        const start_fragment_id = self.fragmentIdForAnchor(range.start);
        const found = self.fragments.find(st.Dimensions(FragmentIdDim, FragmentTextSummary, void), null, FragmentIdDim{ .id = start_fragment_id }, .left);
        var visible_start = found.start.d2.visible;
        var deleted_start = found.start.d2.deleted;
        if (found.item) |fragment| {
            const overshoot: usize = range.start.offset - fragment.insertion_offset;
            if (fragment.visible) visible_start += overshoot else deleted_start += overshoot;
        }
        result.fragments_cursor = c;
        result.visible_cursor = self.visible_text.cursor(visible_start);
        result.deleted_cursor = self.deleted_text.cursor(deleted_start);
        result.range_start = .{ .id = start_fragment_id, .offset = range.start.offset };
        result.range_end = .{ .id = self.fragmentIdForAnchor(range.end), .offset = range.end.offset };
        return result;
    }

    pub fn Edits(comptime D: type) type {
        return struct {
            const Self = @This();
            const TD = TextDimension(D);
            pub const Item = struct { edit: Edit(D), start: Anchor, end: Anchor };
            const Position = struct { id: Locator, offset: u32 };

            visible_cursor: rope_mod.Cursor,
            deleted_cursor: rope_mod.Cursor,
            fragments_cursor: ?FragmentTree.FilterCursor(FragmentTextSummary, SinceFilter),
            undos: *const UndoMap,
            since: *const Global,
            old_end: D,
            new_end: D,
            range_start: Position,
            range_end: Position,
            buffer_id: BufferId,

            pub fn next(self: *Self) ?Edit(D) {
                const item = self.nextAnchored() orelse return null;
                return item.edit;
            }

            pub fn nextAnchored(self: *Self) ?Item {
                var pending: ?Item = null;
                const c = if (self.fragments_cursor) |*cursor| cursor else return null;
                while (c.item()) |fragment| {
                    if (fragment.id.cmp(&self.range_start.id) == .lt) {
                        c.next();
                        continue;
                    } else if (fragment.id.cmp(&self.range_end.id) == .gt) break;

                    if (c.start().visible > self.visible_cursor.offset) {
                        const summary = self.visible_cursor.summary(D, c.start().visible);
                        TD.addAssign(&self.old_end, &summary);
                        TD.addAssign(&self.new_end, &summary);
                    }

                    if (pending) |p| {
                        if (lessThan(p.edit.new.end, self.new_end)) break;
                    }

                    const start_anchor = Anchor.init(fragment.timestamp, fragment.insertion_offset, .right, self.buffer_id);
                    const end_anchor = Anchor.init(fragment.timestamp, fragment.insertion_offset + fragment.len, .left, self.buffer_id);
                    const was_visible = fragment.wasVisible(self.since, self.undos);

                    if (!was_visible and fragment.visible) {
                        var visible_end = c.end().visible;
                        if (fragment.id.eql(self.range_end.id)) {
                            visible_end = @min(visible_end, c.start().visible + (self.range_end.offset - fragment.insertion_offset));
                        }
                        const fragment_summary = self.visible_cursor.summary(D, visible_end);
                        var new_end = self.new_end;
                        TD.addAssign(&new_end, &fragment_summary);
                        if (pending) |*p| {
                            p.edit.new.end = new_end;
                            p.end = end_anchor;
                        } else {
                            pending = .{ .edit = .{ .old = .{ .start = self.old_end, .end = self.old_end }, .new = .{ .start = self.new_end, .end = new_end } }, .start = start_anchor, .end = end_anchor };
                        }
                        self.new_end = new_end;
                    } else if (was_visible and !fragment.visible) {
                        var deleted_end = c.end().deleted;
                        if (fragment.id.eql(self.range_end.id)) {
                            deleted_end = @min(deleted_end, c.start().deleted + (self.range_end.offset - fragment.insertion_offset));
                        }
                        if (c.start().deleted > self.deleted_cursor.offset) self.deleted_cursor.seekForward(c.start().deleted);
                        const fragment_summary = self.deleted_cursor.summary(D, deleted_end);
                        var old_end = self.old_end;
                        TD.addAssign(&old_end, &fragment_summary);
                        if (pending) |*p| {
                            p.edit.old.end = old_end;
                            p.end = end_anchor;
                        } else {
                            pending = .{ .edit = .{ .old = .{ .start = self.old_end, .end = old_end }, .new = .{ .start = self.new_end, .end = self.new_end } }, .start = start_anchor, .end = end_anchor };
                        }
                        self.old_end = old_end;
                    }
                    c.next();
                }
                return pending;
            }

            fn lessThan(a: D, b: D) bool {
                return st.compareValues(D, &a, &b) == .lt;
            }

            /// Collects all remaining edits into a patch owned by the caller.
            pub fn collect(self: *Self, gpa: Allocator) Allocator.Error!Patch(D) {
                var result: Patch(D) = .empty;
                errdefer result.deinit(gpa);
                while (self.next()) |e| try result.edits_list.append(gpa, e);
                return result;
            }
        };
    }
};

// ---------------------------------------------------------------------------
// Buffer

pub const RangeEdit = struct { start: usize, end: usize, text: []const u8 };

pub const Buffer = struct {
    gpa: Allocator,
    /// Source of `Instant`s for transaction grouping; null reads as time 0.
    io: ?std.Io = null,
    snapshot: BufferSnapshot,
    history: History,
    lamport_clock: Lamport,
    subscriptions: subscription_mod.Topic(usize) = .{},

    pub fn init(gpa: Allocator, replica_id: ReplicaId, remote_id: BufferId, base_text: []const u8) Allocator.Error!Buffer {
        const line_ending = LineEnding.detect(base_text);
        const normalized = try LineEnding.normalize(gpa, base_text);
        defer if (normalized.ptr != base_text.ptr) gpa.free(normalized);
        return initNormalized(gpa, replica_id, remote_id, line_ending, try Rope.fromStr(gpa, normalized));
    }

    /// Takes ownership of `normalized`.
    pub fn initNormalized(gpa: Allocator, replica_id: ReplicaId, remote_id: BufferId, line_ending: LineEnding, normalized: Rope) Allocator.Error!Buffer {
        var base_text = normalized;
        errdefer base_text.deinit(gpa);
        const store = try Store.create(gpa);
        errdefer store.release(gpa);
        const arena = store.arena.allocator();
        var fragments = try FragmentTree.init(gpa, null);
        errdefer fragments.deinit(gpa);
        var insertions = try InsertionTree.init(gpa, {});
        errdefer insertions.deinit(gpa);
        var lamport_clock = Lamport.init(replica_id);
        var initial_version: Global = .empty;

        const visible_text = base_text.clone();
        if (!visible_text.isEmpty()) {
            const insertion_timestamp = Lamport.init(.local);
            lamport_clock.observe(insertion_timestamp);
            initial_version.observe(insertion_timestamp);
            var insertion_offset: u32 = 0;
            var text_offset: usize = 0;
            var prev_locator = Locator.min;
            while (text_offset < visible_text.len()) {
                const target_end = @min(visible_text.len(), text_offset + max_insertion_len);
                const chunk_end = if (target_end == visible_text.len()) target_end else visible_text.floorCharBoundary(target_end);
                const chunk_len = chunk_end - text_offset;
                const fragment_id = try Locator.between(arena, prev_locator, Locator.max);
                const fragment: Fragment = .{ .id = fragment_id, .timestamp = insertion_timestamp, .insertion_offset = insertion_offset, .len = @intCast(chunk_len), .visible = true };
                try insertions.push(gpa, .fromFragment(&fragment), {});
                try fragments.push(gpa, fragment, null);
                prev_locator = fragment_id;
                insertion_offset += @intCast(chunk_len);
                text_offset = chunk_end;
            }
        }

        return .{
            .gpa = gpa,
            .snapshot = .{
                .store = store,
                .visible_text = visible_text,
                .deleted_text = try Rope.init(gpa),
                .fragments = fragments,
                .insertions = insertions,
                .insertion_slices = try SliceTree.init(gpa, {}),
                .undo_map = try UndoMap.init(gpa),
                .version = initial_version,
                .remote_id = remote_id,
                .replica_id = replica_id,
                .line_ending = line_ending,
            },
            .history = .{ .base_text = base_text },
            .lamport_clock = lamport_clock,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.subscriptions.deinit(self.gpa);
        self.history.deinit(self.gpa);
        self.snapshot.deinit(self.gpa);
        self.* = undefined;
    }

    fn now(self: *const Buffer) Instant {
        const io = self.io orelse return 0;
        return std.Io.Clock.awake.now(io).nanoseconds;
    }

    pub fn version(self: *const Buffer) Global {
        return self.snapshot.version;
    }

    pub fn getSnapshot(self: *const Buffer) *const BufferSnapshot {
        return &self.snapshot;
    }

    /// An O(1) snapshot the caller owns.
    pub fn cloneSnapshot(self: *const Buffer) BufferSnapshot {
        return self.snapshot.clone();
    }

    pub fn replicaId(self: *const Buffer) ReplicaId {
        return self.lamport_clock.replica_id;
    }

    pub fn remoteId(self: *const Buffer) BufferId {
        return self.snapshot.remote_id;
    }

    pub fn transactionGroupInterval(self: *const Buffer) Instant {
        return self.history.group_interval;
    }

    pub fn setGroupInterval(self: *Buffer, interval: Instant) void {
        self.history.group_interval = interval;
    }

    pub fn setLineEnding(self: *Buffer, line_ending: LineEnding) void {
        self.snapshot.line_ending = line_ending;
    }

    pub fn baseText(self: *const Buffer) *const Rope {
        return &self.history.base_text;
    }

    pub fn subscribe(self: *Buffer) Allocator.Error!*Subscription {
        return self.subscriptions.subscribe(self.gpa);
    }

    /// Applies sorted, non-overlapping edits in one transaction; returns the edit
    /// operation's timestamp.
    pub fn edit(self: *Buffer, edits: []const RangeEdit) Allocator.Error!Lamport {
        _ = try self.startTransaction();
        const timestamp = self.lamport_clock.tick();
        try self.applyLocalEdit(edits, timestamp);
        try self.history.pushUndo(self.gpa, timestamp);
        self.snapshot.version.observe(timestamp);
        _ = try self.endTransaction();
        return timestamp;
    }

    fn applyLocalEdit(self: *Buffer, edits: []const RangeEdit, timestamp: Lamport) Allocator.Error!void {
        var edits_patch = try applyEditInternal(self.gpa, &self.snapshot, edits, timestamp);
        defer edits_patch.deinit(self.gpa);
        try self.subscriptions.publish(self.gpa, edits_patch.edits());
    }

    pub fn startTransaction(self: *Buffer) Allocator.Error!?TransactionId {
        return self.startTransactionAt(self.now());
    }

    pub fn startTransactionAt(self: *Buffer, at: Instant) Allocator.Error!?TransactionId {
        return self.history.startTransaction(self.gpa, self.snapshot.version, at, &self.lamport_clock);
    }

    pub const EndedTransaction = struct { id: TransactionId, since: Global };

    pub fn endTransaction(self: *Buffer) Allocator.Error!?EndedTransaction {
        return self.endTransactionAt(self.now());
    }

    pub fn endTransactionAt(self: *Buffer, at: Instant) Allocator.Error!?EndedTransaction {
        const entry = self.history.endTransaction(self.gpa, at) orelse return null;
        const since = entry.transaction.start;
        const id = (try self.history.group(self.gpa)).?;
        return .{ .id = id, .since = since };
    }

    pub fn finalizeLastTransaction(self: *Buffer) ?*const Transaction {
        return self.history.finalizeLastTransaction();
    }

    pub fn groupUntilTransaction(self: *Buffer, transaction_id: TransactionId) Allocator.Error!void {
        try self.history.groupUntil(self.gpa, transaction_id);
    }

    pub fn peekUndoStack(self: *const Buffer) ?*const HistoryEntry {
        const items = self.history.undo_stack.items;
        return if (items.len == 0) null else &items[items.len - 1];
    }

    pub fn peekRedoStack(self: *const Buffer) ?*const HistoryEntry {
        const items = self.history.redo_stack.items;
        return if (items.len == 0) null else &items[items.len - 1];
    }

    pub fn undo(self: *Buffer) Allocator.Error!?TransactionId {
        const entry = (try self.history.popUndo(self.gpa)) orelse return null;
        const id = entry.transaction.id;
        var transaction = try entry.transaction.clone(self.gpa);
        defer transaction.deinit(self.gpa);
        _ = try self.undoOrRedo(&transaction);
        return id;
    }

    pub fn redo(self: *Buffer) Allocator.Error!?TransactionId {
        const entry = (try self.history.popRedo(self.gpa)) orelse return null;
        const id = entry.transaction.id;
        var transaction = try entry.transaction.clone(self.gpa);
        defer transaction.deinit(self.gpa);
        _ = try self.undoOrRedo(&transaction);
        return id;
    }

    pub fn undoTransaction(self: *Buffer, transaction_id: TransactionId) Allocator.Error!bool {
        const entry = (try self.history.removeFromUndo(self.gpa, transaction_id)) orelse return false;
        var transaction = try entry.transaction.clone(self.gpa);
        defer transaction.deinit(self.gpa);
        _ = try self.undoOrRedo(&transaction);
        return true;
    }

    pub fn undoToTransaction(self: *Buffer, transaction_id: TransactionId) Allocator.Error!usize {
        return self.replayEntries(try self.history.removeFromUndoUntil(self.gpa, transaction_id));
    }

    pub fn redoToTransaction(self: *Buffer, transaction_id: TransactionId) Allocator.Error!usize {
        return self.replayEntries(try self.history.removeFromRedo(self.gpa, transaction_id));
    }

    fn replayEntries(self: *Buffer, entries: []const HistoryEntry) Allocator.Error!usize {
        var transactions: std.ArrayList(Transaction) = .empty;
        defer {
            for (transactions.items) |*t| t.deinit(self.gpa);
            transactions.deinit(self.gpa);
        }
        for (entries) |*entry| try transactions.append(self.gpa, try entry.transaction.clone(self.gpa));
        for (transactions.items) |*t| _ = try self.undoOrRedo(t);
        return transactions.items.len;
    }

    /// Removes a transaction from history; the caller owns the result.
    pub fn forgetTransaction(self: *Buffer, transaction_id: TransactionId) ?Transaction {
        return self.history.forget(transaction_id);
    }

    pub fn getTransaction(self: *Buffer, transaction_id: TransactionId) ?*const Transaction {
        return self.history.transaction(transaction_id);
    }

    pub fn mergeTransactions(self: *Buffer, transaction: TransactionId, destination: TransactionId) Allocator.Error!void {
        try self.history.mergeTransactions(self.gpa, transaction, destination);
    }

    /// Takes ownership of `transaction`.
    pub fn pushTransaction(self: *Buffer, transaction: Transaction, at: Instant) Allocator.Error!void {
        try self.history.pushTransaction(self.gpa, transaction, at);
    }

    pub fn pushEmptyTransaction(self: *Buffer, at: Instant) Allocator.Error!TransactionId {
        return self.history.pushEmptyTransaction(self.gpa, self.snapshot.version, at, &self.lamport_clock);
    }

    /// Toggles every edit of `transaction` (Zed's private `undo_or_redo`, used by tests).
    pub fn undoOrRedo(self: *Buffer, transaction: *const Transaction) Allocator.Error!Lamport {
        var counts: std.ArrayList(UndoCount) = .empty;
        defer counts.deinit(self.gpa);
        for (transaction.edit_ids.items) |edit_id| {
            for (counts.items) |*existing| {
                if (existing.edit_id.eql(edit_id)) {
                    existing.count = self.snapshot.undo_map.undoCount(edit_id) +| 1;
                    break;
                }
            } else try counts.append(self.gpa, .{ .edit_id = edit_id, .count = self.snapshot.undo_map.undoCount(edit_id) +| 1 });
        }
        return self.undoOperations(counts.items);
    }

    /// Applies an undo operation with explicit per-edit undo counts.
    pub fn undoOperations(self: *Buffer, counts: []const UndoCount) Allocator.Error!Lamport {
        const timestamp = self.lamport_clock.tick();
        self.snapshot.version.observe(timestamp);
        try self.applyUndo(timestamp, counts);
        return timestamp;
    }

    fn fragmentIdsForEdits(self: *const Buffer, gpa: Allocator, edit_ids: []const UndoCount) Allocator.Error!std.ArrayList(Locator) {
        const snap = &self.snapshot;
        var slices: std.ArrayList(InsertionSlice) = .empty;
        defer slices.deinit(gpa);
        for (edit_ids) |entry| {
            const from: InsertionSlice = .{ .edit_id = entry.edit_id, .insertion_id = Lamport.min, .start = 0, .end = 0 };
            var c = snap.insertion_slices.cursor(InsertionSlice, {});
            _ = c.seek(from, .left);
            while (c.item()) |slice| : (c.next()) {
                if (!slice.edit_id.eql(entry.edit_id)) break;
                try slices.append(gpa, slice.*);
            }
        }
        const SliceOrder = struct {
            fn lessThan(_: void, a: InsertionSlice, b: InsertionSlice) bool {
                switch (a.insertion_id.cmp(&b.insertion_id)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
                if (a.start != b.start) return a.start < b.start;
                return a.end > b.end;
            }
        };
        std.sort.pdq(InsertionSlice, slices.items, {}, SliceOrder.lessThan);

        var fragment_ids: std.ArrayList(Locator) = .empty;
        errdefer fragment_ids.deinit(gpa);
        var c = snap.insertions.cursor(InsertionFragmentKey, {});
        for (slices.items) |slice| {
            if (!slice.insertion_id.eql(c.start().timestamp) or slice.start > c.start().split_offset) {
                _ = c.seekForward(InsertionFragmentKey{ .timestamp = slice.insertion_id, .split_offset = slice.start }, .left);
            }
            while (c.item()) |item| : (c.next()) {
                if (!item.timestamp.eql(slice.insertion_id) or item.split_offset >= slice.end) break;
                try fragment_ids.append(gpa, item.fragment_id);
            }
        }
        const IdOrder = struct {
            fn lessThan(_: void, a: Locator, b: Locator) bool {
                return a.cmp(&b) == .lt;
            }
        };
        std.sort.pdq(Locator, fragment_ids.items, {}, IdOrder.lessThan);
        return fragment_ids;
    }

    fn applyUndo(self: *Buffer, timestamp: Lamport, counts: []const UndoCount) Allocator.Error!void {
        const gpa = self.gpa;
        const snap = &self.snapshot;
        try snap.undo_map.insert(gpa, timestamp, counts);

        var edits: Patch(usize) = .empty;
        defer edits.deinit(gpa);
        var fragment_ids = try self.fragmentIdsForEdits(gpa, counts);
        defer fragment_ids.deinit(gpa);

        var old_fragments = snap.fragments.cursor(st.Dimensions(FragmentIdDim, usize, void), null);
        var new_fragments = try FragmentTree.init(gpa, null);
        errdefer new_fragments.deinit(gpa);
        var new_ropes = try RopeBuilder.init(gpa, &snap.visible_text, &snap.deleted_text);
        errdefer new_ropes.deinit();

        for (fragment_ids.items) |fragment_id| {
            const preceding = try old_fragments.slice(gpa, FragmentIdDim{ .id = fragment_id }, .left);
            try new_ropes.append(preceding.summary().text);
            try new_fragments.append(gpa, preceding, null);
            if (old_fragments.item()) |old| {
                var fragment = old.*;
                const was_visible = fragment.visible;
                fragment.visible = fragment.isVisible(&snap.undo_map);
                fragment.max_undos.observe(timestamp);
                const old_start = old_fragments.start().d2;
                const new_start = new_fragments.summary().text.visible;
                if (was_visible and !fragment.visible) {
                    try edits.push(gpa, .{ .old = .{ .start = old_start, .end = old_start + fragment.len }, .new = .{ .start = new_start, .end = new_start } });
                } else if (!was_visible and fragment.visible) {
                    try edits.push(gpa, .{ .old = .{ .start = old_start, .end = old_start }, .new = .{ .start = new_start, .end = new_start + fragment.len } });
                }
                try new_ropes.pushFragment(&fragment, was_visible);
                try new_fragments.push(gpa, fragment, null);
                old_fragments.next();
            }
        }
        const suffix = try old_fragments.suffix(gpa);
        try new_ropes.append(suffix.summary().text);
        try new_fragments.append(gpa, suffix, null);

        const ropes = try new_ropes.finish();
        snap.fragments.deinit(gpa);
        snap.fragments = new_fragments;
        snap.visible_text.deinit(gpa);
        snap.visible_text = ropes.visible;
        snap.deleted_text.deinit(gpa);
        snap.deleted_text = ropes.deleted;
        try self.subscriptions.publish(gpa, edits.edits());
    }

    /// Creates a branch buffer sharing this snapshot with fresh history
    /// (`Buffer::branch`).
    pub fn branch(self: *const Buffer) Allocator.Error!Buffer {
        return .{
            .gpa = self.gpa,
            .io = self.io,
            .snapshot = self.snapshot.clone(),
            .history = .{ .base_text = self.history.base_text.clone() },
            .lamport_clock = Lamport.init(.local_branch),
        };
    }
};

/// Splits `text` into fragments of at most `max_insertion_len` bytes.
fn pushFragmentsForInsertion(
    gpa: Allocator,
    arena: Allocator,
    new_text: []const u8,
    timestamp: Lamport,
    insertion_offset: *u32,
    new_fragments: *FragmentTree,
    new_insertions: *std.ArrayList(InsertionTree.KeyedEdit),
    insertion_slices: *std.ArrayList(InsertionSlice),
    new_ropes: *RopeBuilder,
    next_fragment_id: Locator,
    edit_timestamp: Lamport,
) Allocator.Error!void {
    var text_offset: usize = 0;
    while (text_offset < new_text.len) {
        const target_end = @min(new_text.len, text_offset + max_insertion_len);
        const chunk_end = if (target_end == new_text.len) target_end else rope_mod.chunk.strFloorCharBoundary(new_text, target_end);
        if (chunk_end == text_offset) break;
        const chunk_len = chunk_end - text_offset;
        const fragment: Fragment = .{
            .id = try Locator.between(arena, new_fragments.summary().max_id, next_fragment_id),
            .timestamp = timestamp,
            .insertion_offset = insertion_offset.*,
            .len = @intCast(chunk_len),
            .visible = true,
        };
        try insertion_slices.append(gpa, .fromFragment(edit_timestamp, &fragment));
        try new_insertions.append(gpa, .{ .insert = .fromFragment(&fragment) });
        try new_fragments.push(gpa, fragment, null);
        insertion_offset.* += @intCast(chunk_len);
        text_offset = chunk_end;
    }
    try new_ropes.pushStr(new_text);
}

fn withDeletion(arena: Allocator, deletions: []const Lamport, timestamp: Lamport) Allocator.Error![]const Lamport {
    const result = try arena.alloc(Lamport, deletions.len + 1);
    @memcpy(result[0..deletions.len], deletions);
    result[deletions.len] = timestamp;
    return result;
}

fn applyEditInternal(gpa: Allocator, snap: *BufferSnapshot, edits: []const RangeEdit, timestamp: Lamport) Allocator.Error!Patch(usize) {
    var edits_patch: Patch(usize) = .empty;
    errdefer edits_patch.deinit(gpa);
    if (edits.len == 0) return edits_patch;
    const arena = snap.store.arena.allocator();

    var new_insertions: std.ArrayList(InsertionTree.KeyedEdit) = .empty;
    defer new_insertions.deinit(gpa);
    var insertion_slices: std.ArrayList(InsertionSlice) = .empty;
    defer insertion_slices.deinit(gpa);
    var insertion_offset: u32 = 0;

    var new_ropes = try RopeBuilder.init(gpa, &snap.visible_text, &snap.deleted_text);
    errdefer new_ropes.deinit();
    var old_fragments = snap.fragments.cursor(FragmentTextSummary, null);
    var new_fragments = try old_fragments.slice(gpa, edits[0].start, .right);
    errdefer new_fragments.deinit(gpa);
    try new_ropes.append(new_fragments.summary().text);

    var fragment_start = old_fragments.start().visible;
    for (edits) |range_edit| {
        const new_text = try LineEnding.normalize(gpa, range_edit.text);
        defer if (new_text.ptr != range_edit.text.ptr) gpa.free(new_text);
        const fragment_end = old_fragments.end().visible;

        // Copy fragments between the previous edit and this one.
        if (fragment_end < range_edit.start) {
            if (fragment_start > old_fragments.start().visible) {
                if (fragment_end > fragment_start) {
                    var suffix = old_fragments.item().?.*;
                    suffix.len = @intCast(fragment_end - fragment_start);
                    suffix.insertion_offset += @intCast(fragment_start - old_fragments.start().visible);
                    try new_insertions.append(gpa, .{ .insert = .fromFragment(&suffix) });
                    try new_ropes.pushFragment(&suffix, suffix.visible);
                    try new_fragments.push(gpa, suffix, null);
                }
                old_fragments.next();
            }
            const slice = try old_fragments.slice(gpa, range_edit.start, .right);
            try new_ropes.append(slice.summary().text);
            try new_fragments.append(gpa, slice, null);
            fragment_start = old_fragments.start().visible;
        }

        // Prefix of the fragment containing the edit start.
        if (fragment_start < range_edit.start) {
            var prefix = old_fragments.item().?.*;
            prefix.len = @intCast(range_edit.start - fragment_start);
            prefix.insertion_offset += @intCast(fragment_start - old_fragments.start().visible);
            prefix.id = try Locator.between(arena, new_fragments.summary().max_id, prefix.id);
            try new_insertions.append(gpa, .{ .insert = .fromFragment(&prefix) });
            try new_ropes.pushFragment(&prefix, prefix.visible);
            try new_fragments.push(gpa, prefix, null);
            fragment_start = range_edit.start;
        }

        // Inserted text.
        if (new_text.len > 0) {
            const new_start = new_fragments.summary().text.visible;
            const next_fragment_id = if (old_fragments.item()) |old| old.id else Locator.max;
            try pushFragmentsForInsertion(gpa, arena, new_text, timestamp, &insertion_offset, &new_fragments, &new_insertions, &insertion_slices, &new_ropes, next_fragment_id, timestamp);
            try edits_patch.push(gpa, .{ .old = .{ .start = fragment_start, .end = fragment_start }, .new = .{ .start = new_start, .end = new_start + new_text.len } });
        }

        // Deleted fragments intersecting the range.
        while (fragment_start < range_edit.end) {
            const fragment = old_fragments.item().?;
            const intersection_fragment_end = old_fragments.end().visible;
            var intersection = fragment.*;
            const intersection_end = @min(range_edit.end, intersection_fragment_end);
            if (fragment.visible) {
                intersection.len = @intCast(intersection_end - fragment_start);
                intersection.insertion_offset += @intCast(fragment_start - old_fragments.start().visible);
                intersection.id = try Locator.between(arena, new_fragments.summary().max_id, intersection.id);
                intersection.deletions = try withDeletion(arena, intersection.deletions, timestamp);
                intersection.visible = false;
            }
            if (intersection.len > 0) {
                if (fragment.visible and !intersection.visible) {
                    const new_start = new_fragments.summary().text.visible;
                    try edits_patch.push(gpa, .{ .old = .{ .start = fragment_start, .end = intersection_end }, .new = .{ .start = new_start, .end = new_start } });
                    try insertion_slices.append(gpa, .fromFragment(timestamp, &intersection));
                }
                try new_insertions.append(gpa, .{ .insert = .fromFragment(&intersection) });
                try new_ropes.pushFragment(&intersection, fragment.visible);
                try new_fragments.push(gpa, intersection, null);
                fragment_start = intersection_end;
            }
            if (intersection_fragment_end <= range_edit.end) old_fragments.next();
        }
    }

    // Remainder of the last fragment.
    if (fragment_start > old_fragments.start().visible) {
        const fragment_end = old_fragments.end().visible;
        if (fragment_end > fragment_start) {
            var suffix = old_fragments.item().?.*;
            suffix.len = @intCast(fragment_end - fragment_start);
            suffix.insertion_offset += @intCast(fragment_start - old_fragments.start().visible);
            try new_insertions.append(gpa, .{ .insert = .fromFragment(&suffix) });
            try new_ropes.pushFragment(&suffix, suffix.visible);
            try new_fragments.push(gpa, suffix, null);
        }
        old_fragments.next();
    }

    const suffix = try old_fragments.suffix(gpa);
    try new_ropes.append(suffix.summary().text);
    try new_fragments.append(gpa, suffix, null);
    const ropes = try new_ropes.finish();

    snap.fragments.deinit(gpa);
    snap.fragments = new_fragments;
    var removed = try snap.insertions.edit(gpa, new_insertions.items, {});
    removed.deinit(gpa);
    snap.visible_text.deinit(gpa);
    snap.visible_text = ropes.visible;
    snap.deleted_text.deinit(gpa);
    snap.deleted_text = ropes.deleted;
    for (insertion_slices.items) |slice| _ = try snap.insertion_slices.insertOrReplace(gpa, slice, {});
    return edits_patch;
}

/// Builds the new visible and deleted ropes while fragments are rewritten.
const RopeBuilder = struct {
    gpa: Allocator,
    old_visible_cursor: rope_mod.Cursor,
    old_deleted_cursor: rope_mod.Cursor,
    new_visible: Rope,
    new_deleted: Rope,

    fn init(gpa: Allocator, old_visible: *const Rope, old_deleted: *const Rope) Allocator.Error!RopeBuilder {
        var new_visible = try Rope.init(gpa);
        errdefer new_visible.deinit(gpa);
        return .{ .gpa = gpa, .old_visible_cursor = old_visible.cursor(0), .old_deleted_cursor = old_deleted.cursor(0), .new_visible = new_visible, .new_deleted = try Rope.init(gpa) };
    }

    fn deinit(self: *RopeBuilder) void {
        self.new_visible.deinit(self.gpa);
        self.new_deleted.deinit(self.gpa);
    }

    fn append(self: *RopeBuilder, length: FragmentTextSummary) Allocator.Error!void {
        try self.push(length.visible, true, true);
        try self.push(length.deleted, false, false);
    }

    fn pushFragment(self: *RopeBuilder, fragment: *const Fragment, was_visible: bool) Allocator.Error!void {
        std.debug.assert(fragment.len > 0);
        try self.push(fragment.len, was_visible, fragment.visible);
    }

    fn push(self: *RopeBuilder, length: usize, was_visible: bool, is_visible: bool) Allocator.Error!void {
        const source = if (was_visible) &self.old_visible_cursor else &self.old_deleted_cursor;
        const slice = try source.slice(self.gpa, source.offset + length);
        if (is_visible) try self.new_visible.append(self.gpa, slice) else try self.new_deleted.append(self.gpa, slice);
    }

    fn pushStr(self: *RopeBuilder, text: []const u8) Allocator.Error!void {
        try self.new_visible.push(self.gpa, text);
    }

    fn finish(self: *RopeBuilder) Allocator.Error!struct { visible: Rope, deleted: Rope } {
        try self.new_visible.append(self.gpa, try self.old_visible_cursor.suffix(self.gpa));
        try self.new_deleted.append(self.gpa, try self.old_deleted_cursor.suffix(self.gpa));
        return .{ .visible = self.new_visible, .deleted = self.new_deleted };
    }
};

test {
    _ = @import("buffer_tests.zig");
}
