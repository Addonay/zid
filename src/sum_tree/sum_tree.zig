//! Port of Zed's `sum_tree` crate (`.ref/zed/crates/sum_tree/src/sum_tree.rs`, `cursor.rs`).
//!
//! A persistent B+ tree whose nodes cache the summary of their subtree. Nodes are
//! reference counted (Zed's `Arc<Node<T>>`), so cloning a tree is O(1) and mutation
//! path-copies shared nodes (Zed's `Arc::make_mut`).
//!
//! Zig contracts that replace Rust traits:
//! - Item `T`: `pub const Summary = S;` and `pub fn summary(self: *const T, cx: Context) S`.
//!   Optional `pub fn retain(self: *const T) T` / `pub fn release(self: *T, gpa) void` when
//!   items own resources; otherwise items are copied by value.
//! - Summary `S`: optional `pub const Context`, `pub fn zero(cx) S`,
//!   `pub fn addSummary(self: *S, other: *const S, cx) void`. Summaries are plain values.
//! - Dimension `D` over `S`: `D == S`, `void`, a struct with `pub fn zero(cx: anytype) D` and
//!   `pub fn addSummary(self: *D, summary: anytype, cx: anytype) void`, or a foreign type
//!   (such as `usize`) handled by `S.dimensionZero(D, cx)` / `S.addToDimension(D, d, s, cx)`.
//!   `S.handlesDimension(D)` returning true makes `S` handle a struct `D` the same way.
//! - Seek target: a value of type `D`, the first type of a `Dimensions`, a struct with
//!   `pub fn cmpSeek(self: *const Target, location: anytype, cx: anytype) std.math.Order`,
//!   or any type accepted by `D.seekOrder(target: anytype, location: *const D, cx)`.
//! - Keyed item: `pub const Key = K;` and `pub fn key(self: *const T) K`, where `K` is a
//!   dimension.
//!
//! Every allocating operation takes the allocator explicitly. On allocation failure the
//! tree remains valid but may hold a partially applied edit; callers treat OOM as fatal
//! for the edit in progress.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

/// Zed uses `TREE_BASE = 2` under `cfg(test)` so tests exercise deep trees.
pub const default_tree_base: usize = if (builtin.is_test) 2 else 6;

pub const Bias = enum {
    left,
    right,

    pub fn invert(bias: Bias) Bias {
        return switch (bias) {
            .left => .right,
            .right => .left,
        };
    }
};

pub fn ContextOf(comptime S: type) type {
    return if (@hasDecl(S, "Context")) S.Context else void;
}

fn isStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => true,
        else => false,
    };
}

/// Whether summary `S` defines dimension `D` itself (`S.handlesDimension(D)`), taking
/// precedence over `D.addSummary`. Used when one dimension type (such as `Point`)
/// means different fields of different summaries.
fn overrides(comptime S: type, comptime D: type) bool {
    return isStruct(S) and @hasDecl(S, "handlesDimension") and S.handlesDimension(D);
}

/// Dimension operations of `D` over summary `S`.
pub fn Dim(comptime S: type, comptime D: type) type {
    return struct {
        pub inline fn zero(cx: ContextOf(S)) D {
            if (D == void) return {};
            if (D == S) return S.zero(cx);
            if (comptime overrides(S, D)) return S.dimensionZero(D, cx);
            if (comptime isStruct(D) and @hasDecl(D, "addSummary")) return D.zero(cx);
            return S.dimensionZero(D, cx);
        }

        pub inline fn add(dimension: *D, summary: *const S, cx: ContextOf(S)) void {
            if (D == void) return;
            if (D == S) return S.addSummary(dimension, summary, cx);
            if (comptime overrides(S, D)) return S.addToDimension(D, dimension, summary, cx);
            if (comptime isStruct(D) and @hasDecl(D, "addSummary")) return dimension.addSummary(summary, cx);
            return S.addToDimension(D, dimension, summary, cx);
        }

        pub inline fn fromSummary(summary: *const S, cx: ContextOf(S)) D {
            var dimension = zero(cx);
            add(&dimension, summary, cx);
            return dimension;
        }
    };
}

/// Zed's `Dimensions<D1, D2, D3>` tuple. Seeking with a `D1` target compares `d1`.
pub fn Dimensions(comptime D1: type, comptime D2: type, comptime D3: type) type {
    return struct {
        const Self = @This();
        pub const First = D1;
        pub const is_dimensions = true;

        d1: D1,
        d2: D2,
        d3: D3 = if (D3 == void) {} else undefined,

        pub fn addSummary(self: *Self, summary: anytype, cx: anytype) void {
            const S = @TypeOf(summary.*);
            Dim(S, D1).add(&self.d1, summary, cx);
            Dim(S, D2).add(&self.d2, summary, cx);
            Dim(S, D3).add(&self.d3, summary, cx);
        }
    };
}

fn isDimensions(comptime D: type) bool {
    return comptime isStruct(D) and @hasDecl(D, "is_dimensions");
}

/// Zero for any dimension, including `Dimensions` tuples whose element zeros depend on `S`.
pub inline fn dimensionZero(comptime S: type, comptime D: type, cx: ContextOf(S)) D {
    if (comptime isDimensions(D)) {
        return .{
            .d1 = dimensionZero(S, D.First, cx),
            .d2 = dimensionZero(S, @FieldType(D, "d2"), cx),
            .d3 = dimensionZero(S, @FieldType(D, "d3"), cx),
        };
    }
    return Dim(S, D).zero(cx);
}

pub inline fn dimensionAdd(comptime S: type, comptime D: type, dimension: *D, summary: *const S, cx: ContextOf(S)) void {
    if (comptime isDimensions(D)) return dimension.addSummary(summary, cx);
    Dim(S, D).add(dimension, summary, cx);
}

/// Total order of two dimension values: integers, or structs with `cmp`.
pub fn compareValues(comptime V: type, a: *const V, b: *const V) Order {
    return switch (@typeInfo(V)) {
        .int, .float, .comptime_int => std.math.order(a.*, b.*),
        .bool => std.math.order(@intFromBool(a.*), @intFromBool(b.*)),
        .@"enum" => std.math.order(@backingInt(a.*), @backingInt(b.*)),
        else => a.cmp(b),
    };
}

/// Compares a seek target with a cursor location.
pub fn seekCmp(target: anytype, location: anytype, cx: anytype) Order {
    const Target = @TypeOf(target.*);
    const D = @TypeOf(location.*);
    if (comptime isStruct(Target) and @hasDecl(Target, "cmpSeek")) return target.cmpSeek(location, cx);
    if (Target == D) return compareValues(D, target, location);
    // A location type can define how foreign targets compare against it
    // (e.g. Zed's `impl SeekTarget<FragmentTextSummary> for usize`).
    if (comptime isStruct(D) and @hasDecl(D, "seekOrder")) return D.seekOrder(target, location, cx);
    if (comptime isDimensions(D)) return seekCmp(target, &location.d1, cx);
    @compileError("type " ++ @typeName(Target) ++ " is not a seek target for " ++ @typeName(D));
}

/// Seek target greater than every location (`cursor.rs` `End<D>`).
pub const End = struct {
    pub fn cmpSeek(_: *const End, _: anytype, _: anytype) Order {
        return .gt;
    }
};

pub const NoSummary = struct {
    pub fn zero(_: void) NoSummary {
        return .{};
    }
    pub fn addSummary(_: *NoSummary, _: *const NoSummary, _: void) void {}
};

pub fn SumTree(comptime T: type) type {
    return SumTreeWithBase(T, default_tree_base);
}

pub fn SumTreeWithBase(comptime T: type, comptime tree_base: usize) type {
    return struct {
        const Self = @This();
        pub const Item = T;
        pub const Summary = T.Summary;
        pub const Context = ContextOf(Summary);
        pub const base = tree_base;
        pub const capacity = 2 * tree_base;
        const max_height = 16;

        root: *Node,

        pub const Node = struct {
            ref_count: std.atomic.Value(u32) = .init(1),
            height: u8,
            len: u8 = 0,
            summary: Summary,
            child_summaries: [capacity]Summary = undefined,
            payload: union {
                items: [capacity]T,
                children: [capacity]Self,
            },

            pub fn isLeaf(node: *const Node) bool {
                return node.height == 0;
            }

            pub fn items(node: *const Node) []const T {
                std.debug.assert(node.isLeaf());
                return node.payload.items[0..node.len];
            }

            fn itemsMut(node: *Node) []T {
                return node.payload.items[0..node.len];
            }

            pub fn children(node: *const Node) []const Self {
                std.debug.assert(!node.isLeaf());
                return node.payload.children[0..node.len];
            }

            fn childrenMut(node: *Node) []Self {
                return node.payload.children[0..node.len];
            }

            pub fn summaries(node: *const Node) []const Summary {
                return node.child_summaries[0..node.len];
            }

            fn isUnderflowing(node: *const Node) bool {
                return node.len < tree_base;
            }
        };

        // ---- item and node ownership ----

        inline fn retainItem(item: *const T) T {
            if (comptime isStruct(T) and @hasDecl(T, "retain")) return item.retain();
            return item.*;
        }

        inline fn releaseItem(gpa: Allocator, item: *T) void {
            if (comptime isStruct(T) and @hasDecl(T, "release")) item.release(gpa);
        }

        /// O(1) shared copy (`Arc::clone`).
        pub fn clone(self: Self) Self {
            _ = self.root.ref_count.fetchAdd(1, .monotonic);
            return self;
        }

        pub fn deinit(self: Self, gpa: Allocator) void {
            if (self.root.ref_count.fetchSub(1, .acq_rel) != 1) return;
            const node = self.root;
            if (node.isLeaf()) {
                for (node.itemsMut()) |*item| releaseItem(gpa, item);
            } else {
                for (node.childrenMut()) |child| child.deinit(gpa);
            }
            gpa.destroy(node);
        }

        fn allocNode(gpa: Allocator, node_height: u8, node_summary: Summary) Allocator.Error!*Node {
            const node = try gpa.create(Node);
            node.* = .{
                .height = node_height,
                .summary = node_summary,
                .payload = if (node_height == 0) .{ .items = undefined } else .{ .children = undefined },
            };
            return node;
        }

        /// `Arc::make_mut`: returns a uniquely owned node, copying a shared one.
        fn makeMut(self: *Self, gpa: Allocator) Allocator.Error!*Node {
            if (self.root.ref_count.load(.acquire) == 1) return self.root;
            const old = self.root;
            const node = try allocNode(gpa, old.height, old.summary);
            node.len = old.len;
            node.child_summaries = old.child_summaries;
            if (old.isLeaf()) {
                for (old.items(), 0..) |*item, i| node.payload.items[i] = retainItem(item);
            } else {
                for (old.children(), 0..) |child, i| node.payload.children[i] = child.clone();
            }
            self.deinit(gpa);
            self.root = node;
            return node;
        }

        fn sum(summaries: []const Summary, cx: Context) Summary {
            var total = Summary.zero(cx);
            for (summaries) |*child_summary| total.addSummary(child_summary, cx);
            return total;
        }

        // ---- construction ----

        pub fn init(gpa: Allocator, cx: Context) Allocator.Error!Self {
            return fromSummary(gpa, Summary.zero(cx));
        }

        pub fn fromSummary(gpa: Allocator, initial: Summary) Allocator.Error!Self {
            return .{ .root = try allocNode(gpa, 0, initial) };
        }

        pub fn fromItem(gpa: Allocator, item: T, cx: Context) Allocator.Error!Self {
            var tree = try init(gpa, cx);
            errdefer tree.deinit(gpa);
            try tree.push(gpa, item, cx);
            return tree;
        }

        /// Builds a balanced tree from items, taking ownership of them even on failure
        /// (`SumTree::from_iter`).
        pub fn fromItems(gpa: Allocator, source: []const T, cx: Context) Allocator.Error!Self {
            if (source.len == 0) return init(gpa, cx);
            var nodes: std.ArrayList(Self) = .empty;
            defer nodes.deinit(gpa);
            // Live trees are `nodes[0..write]` and `nodes[read..]`; the rest moved into parents.
            var write: usize = 0;
            var read: usize = 0;
            var placed: usize = 0;
            errdefer {
                for (nodes.items[0..write]) |node| node.deinit(gpa);
                for (nodes.items[read..]) |node| node.deinit(gpa);
                for (source[placed..]) |item| {
                    var owned = item;
                    releaseItem(gpa, &owned);
                }
            }

            try nodes.ensureTotalCapacityPrecise(gpa, (source.len + capacity - 1) / capacity);
            while (placed < source.len) {
                const end = @min(placed + capacity, source.len);
                const node = try allocNode(gpa, 0, undefined);
                for (source[placed..end], 0..) |item, i| {
                    node.payload.items[i] = item;
                    node.child_summaries[i] = node.payload.items[i].summary(cx);
                }
                node.len = @intCast(end - placed);
                node.summary = sum(node.summaries(), cx);
                nodes.appendAssumeCapacity(.{ .root = node });
                placed = end;
            }

            var level: u8 = 0;
            while (nodes.items.len > 1) {
                level += 1;
                write = 0;
                read = 0;
                while (read < nodes.items.len) {
                    const end = @min(read + capacity, nodes.items.len);
                    const parent = try allocNode(gpa, level, undefined);
                    for (nodes.items[read..end], 0..) |child, i| {
                        parent.payload.children[i] = child;
                        parent.child_summaries[i] = child.root.summary;
                    }
                    parent.len = @intCast(end - read);
                    parent.summary = sum(parent.summaries(), cx);
                    read = end;
                    nodes.items[write] = .{ .root = parent };
                    write += 1;
                }
                nodes.items.len = write;
                read = write;
            }
            return nodes.pop().?;
        }

        // ---- queries ----

        pub fn summary(self: Self) *const Summary {
            return &self.root.summary;
        }

        pub fn isEmpty(self: Self) bool {
            return self.root.isLeaf() and self.root.len == 0;
        }

        pub fn height(self: Self) u8 {
            return self.root.height;
        }

        pub fn extent(self: Self, comptime D: type, cx: Context) D {
            var dimension = dimensionZero(Summary, D, cx);
            dimensionAdd(Summary, D, &dimension, &self.root.summary, cx);
            return dimension;
        }

        fn leftmostLeaf(self: Self) *const Node {
            var node: *const Node = self.root;
            while (!node.isLeaf()) node = node.children()[0].root;
            return node;
        }

        fn rightmostLeaf(self: Self) *const Node {
            var node: *const Node = self.root;
            while (!node.isLeaf()) node = node.children()[node.len - 1].root;
            return node;
        }

        pub fn first(self: Self) ?*const T {
            const leaf = self.leftmostLeaf();
            return if (leaf.len == 0) null else &leaf.items()[0];
        }

        pub fn last(self: Self) ?*const T {
            const leaf = self.rightmostLeaf();
            return if (leaf.len == 0) null else &leaf.items()[leaf.len - 1];
        }

        pub fn lastSummary(self: Self) ?*const Summary {
            const leaf = self.rightmostLeaf();
            return if (leaf.len == 0) null else &leaf.child_summaries[leaf.len - 1];
        }

        /// Copies every item into a list (`SumTree::items`).
        pub fn items(self: Self, gpa: Allocator) Allocator.Error!std.ArrayList(T) {
            var list: std.ArrayList(T) = .empty;
            errdefer list.deinit(gpa);
            var it = self.iter();
            while (it.next()) |item| try list.append(gpa, item.*);
            return list;
        }

        pub fn cursor(self: *const Self, comptime D: type, cx: Context) Cursor(D) {
            return Cursor(D).init(self, cx);
        }

        pub fn filter(self: *const Self, comptime D: type, cx: Context, filter_node: anytype) FilterCursor(D, @TypeOf(filter_node)) {
            return .{ .cursor = Cursor(D).init(self, cx), .filter_node = filter_node };
        }

        pub fn iter(self: *const Self) Iter {
            return .{ .tree = self };
        }

        pub fn FindResult(comptime D: type) type {
            return struct { start: D, end: D, item: ?*const T };
        }

        pub fn FindWithPrevResult(comptime D: type) type {
            return struct { start: D, end: D, found: ?struct { prev: ?*const T, item: *const T } };
        }

        /// `Cursor::new` + `seek` + `item` without a cursor stack.
        pub fn find(self: Self, comptime D: type, cx: Context, target: anytype, bias: Bias) FindResult(D) {
            return self.findImpl(D, cx, target, bias, false);
        }

        /// Like `find`, but only returns an item whose end exactly matches the target.
        pub fn findExact(self: Self, comptime D: type, cx: Context, target: anytype, bias: Bias) FindResult(D) {
            return self.findImpl(D, cx, target, bias, true);
        }

        fn findImpl(self: Self, comptime D: type, cx: Context, target: anytype, bias: Bias, comptime exact: bool) FindResult(D) {
            var tree_end = dimensionZero(Summary, D, cx);
            dimensionAdd(Summary, D, &tree_end, &self.root.summary, cx);
            const comparison = seekCmp(&target, &tree_end, cx);
            if (comparison == .gt or (comparison == .eq and bias == .right)) {
                return .{ .start = tree_end, .end = tree_end, .item = null };
            }
            var position = dimensionZero(Summary, D, cx);
            var node: *const Node = self.root;
            descend: while (true) {
                if (!node.isLeaf()) {
                    for (node.children(), node.summaries()) |child, *child_summary| {
                        var child_end = position;
                        dimensionAdd(Summary, D, &child_end, child_summary, cx);
                        const order = seekCmp(&target, &child_end, cx);
                        if (order == .lt or (order == .eq and bias == .left)) {
                            node = child.root;
                            continue :descend;
                        }
                        position = child_end;
                    }
                } else {
                    for (node.items(), node.summaries()) |*item, *item_summary| {
                        var child_end = position;
                        dimensionAdd(Summary, D, &child_end, item_summary, cx);
                        const order = seekCmp(&target, &child_end, cx);
                        const found = if (exact) order == .eq else order == .lt or (order == .eq and bias == .left);
                        if (found) return .{ .start = position, .end = child_end, .item = item };
                        position = child_end;
                    }
                }
                return .{ .start = position, .end = position, .item = null };
            }
        }

        pub fn findWithPrev(self: Self, comptime D: type, cx: Context, target: anytype, bias: Bias) FindWithPrevResult(D) {
            var tree_end = dimensionZero(Summary, D, cx);
            dimensionAdd(Summary, D, &tree_end, &self.root.summary, cx);
            const comparison = seekCmp(&target, &tree_end, cx);
            if (comparison == .gt or (comparison == .eq and bias == .right)) {
                return .{ .start = tree_end, .end = tree_end, .found = null };
            }
            var position = dimensionZero(Summary, D, cx);
            var prev: ?*const T = null;
            var node: *const Node = self.root;
            descend: while (true) {
                if (!node.isLeaf()) {
                    for (node.children(), node.summaries()) |child, *child_summary| {
                        var child_end = position;
                        dimensionAdd(Summary, D, &child_end, child_summary, cx);
                        const order = seekCmp(&target, &child_end, cx);
                        if (order == .lt or (order == .eq and bias == .left)) {
                            node = child.root;
                            continue :descend;
                        }
                        prev = child.last();
                        position = child_end;
                    }
                } else {
                    for (node.items(), node.summaries()) |*item, *item_summary| {
                        var child_end = position;
                        dimensionAdd(Summary, D, &child_end, item_summary, cx);
                        const order = seekCmp(&target, &child_end, cx);
                        if (order == .lt or (order == .eq and bias == .left)) {
                            return .{ .start = position, .end = child_end, .found = .{ .prev = prev, .item = item } };
                        }
                        prev = item;
                        position = child_end;
                    }
                }
                return .{ .start = position, .end = position, .found = null };
            }
        }

        // ---- mutation ----

        /// Applies `updater.update(*T)` to the last item and refreshes summaries.
        pub fn updateLast(self: *Self, gpa: Allocator, cx: Context, updater: anytype) Allocator.Error!void {
            _ = try self.updateEdge(gpa, cx, updater, .last);
        }

        pub fn updateFirst(self: *Self, gpa: Allocator, cx: Context, updater: anytype) Allocator.Error!void {
            _ = try self.updateEdge(gpa, cx, updater, .first);
        }

        fn updateEdge(self: *Self, gpa: Allocator, cx: Context, updater: anytype, comptime edge: enum { first, last }) Allocator.Error!?Summary {
            if (self.isEmpty()) return null;
            const node = try self.makeMut(gpa);
            const index: usize = if (edge == .first) 0 else node.len - 1;
            if (!node.isLeaf()) {
                const child = &node.payload.children[index];
                node.child_summaries[index] = (try child.updateEdge(gpa, cx, updater, edge)).?;
            } else {
                const item = &node.payload.items[index];
                updater.update(item);
                node.child_summaries[index] = item.summary(cx);
            }
            node.summary = sum(node.summaries(), cx);
            return node.summary;
        }

        pub fn extend(self: *Self, gpa: Allocator, source: []const T, cx: Context) Allocator.Error!void {
            try self.append(gpa, try fromItems(gpa, source, cx), cx);
        }

        pub fn push(self: *Self, gpa: Allocator, item: T, cx: Context) Allocator.Error!void {
            const node = try allocNode(gpa, 0, item.summary(cx));
            node.payload.items[0] = item;
            node.child_summaries[0] = node.summary;
            node.len = 1;
            try self.append(gpa, .{ .root = node }, cx);
        }

        /// Appends `other`, taking ownership of it.
        pub fn append(self: *Self, gpa: Allocator, other: Self, cx: Context) Allocator.Error!void {
            if (self.isEmpty()) {
                self.deinit(gpa);
                self.* = other;
            } else if (!other.root.isLeaf() or other.root.len != 0) {
                if (self.root.height < other.root.height) {
                    const small = self.*;
                    self.* = other;
                    if (try appendLarge(gpa, small, self, cx)) |tree| {
                        self.* = fromChildTrees(gpa, tree, self.*, cx) catch |err| {
                            tree.deinit(gpa);
                            return err;
                        };
                    }
                } else if (try self.pushTreeRecursive(gpa, other, cx)) |split_tree| {
                    self.* = fromChildTrees(gpa, self.*, split_tree, cx) catch |err| {
                        split_tree.deinit(gpa);
                        return err;
                    };
                }
            } else {
                other.deinit(gpa);
            }
        }

        fn pushTreeRecursive(self: *Self, gpa: Allocator, other: Self, cx: Context) Allocator.Error!?Self {
            const node = self.makeMut(gpa) catch |err| {
                other.deinit(gpa);
                return err;
            };
            const other_node = other.root;
            if (!node.isLeaf()) {
                node.summary.addSummary(&other_node.summary, cx);
                const height_delta = node.height - other_node.height;
                var summaries_to_append: [capacity]Summary = undefined;
                var trees_to_append: [capacity]Self = undefined;
                var append_len: usize = 0;
                if (height_delta == 0) {
                    for (other_node.children(), other_node.summaries()) |child, child_summary| {
                        trees_to_append[append_len] = child.clone();
                        summaries_to_append[append_len] = child_summary;
                        append_len += 1;
                    }
                    other.deinit(gpa);
                } else if (height_delta == 1 and !other_node.isUnderflowing()) {
                    summaries_to_append[0] = other_node.summary;
                    trees_to_append[0] = other;
                    append_len = 1;
                } else {
                    const last_child = &node.payload.children[node.len - 1];
                    const tree_to_append = try last_child.pushTreeRecursive(gpa, other, cx);
                    node.child_summaries[node.len - 1] = last_child.root.summary;
                    if (tree_to_append) |split_tree| {
                        summaries_to_append[0] = split_tree.root.summary;
                        trees_to_append[0] = split_tree;
                        append_len = 1;
                    }
                }

                const child_count = node.len + append_len;
                if (child_count > capacity) {
                    var all_summaries: [2 * capacity]Summary = undefined;
                    var all_trees: [2 * capacity]Self = undefined;
                    @memcpy(all_summaries[0..node.len], node.summaries());
                    @memcpy(all_summaries[node.len..child_count], summaries_to_append[0..append_len]);
                    @memcpy(all_trees[0..node.len], node.children());
                    @memcpy(all_trees[node.len..child_count], trees_to_append[0..append_len]);
                    const midpoint = (child_count + child_count % 2) / 2;
                    const right = allocNode(gpa, node.height, undefined) catch |err| {
                        for (trees_to_append[0..append_len]) |tree| tree.deinit(gpa);
                        node.summary = sum(node.summaries(), cx);
                        return err;
                    };
                    right.len = @intCast(child_count - midpoint);
                    @memcpy(right.child_summaries[0..right.len], all_summaries[midpoint..child_count]);
                    @memcpy(right.payload.children[0..right.len], all_trees[midpoint..child_count]);
                    right.summary = sum(right.summaries(), cx);
                    node.len = @intCast(midpoint);
                    @memcpy(node.child_summaries[0..midpoint], all_summaries[0..midpoint]);
                    @memcpy(node.payload.children[0..midpoint], all_trees[0..midpoint]);
                    node.summary = sum(node.summaries(), cx);
                    return .{ .root = right };
                }
                @memcpy(node.child_summaries[node.len..child_count], summaries_to_append[0..append_len]);
                @memcpy(node.payload.children[node.len..child_count], trees_to_append[0..append_len]);
                node.len = @intCast(child_count);
                return null;
            }

            defer other.deinit(gpa);
            const child_count = node.len + other_node.len;
            if (child_count > capacity) {
                const midpoint = (child_count + child_count % 2) / 2;
                const right = try allocNode(gpa, 0, undefined);
                var all_items: [2 * capacity]T = undefined;
                var all_summaries: [2 * capacity]Summary = undefined;
                @memcpy(all_items[0..node.len], node.items());
                @memcpy(all_summaries[0..node.len], node.summaries());
                for (other_node.items(), other_node.summaries(), node.len..) |*item, item_summary, i| {
                    all_items[i] = retainItem(item);
                    all_summaries[i] = item_summary;
                }
                right.len = @intCast(child_count - midpoint);
                @memcpy(right.payload.items[0..right.len], all_items[midpoint..child_count]);
                @memcpy(right.child_summaries[0..right.len], all_summaries[midpoint..child_count]);
                right.summary = sum(right.summaries(), cx);
                node.len = @intCast(midpoint);
                @memcpy(node.payload.items[0..midpoint], all_items[0..midpoint]);
                @memcpy(node.child_summaries[0..midpoint], all_summaries[0..midpoint]);
                node.summary = sum(node.summaries(), cx);
                return .{ .root = right };
            }
            node.summary.addSummary(&other_node.summary, cx);
            for (other_node.items(), other_node.summaries(), node.len..) |*item, item_summary, i| {
                node.payload.items[i] = retainItem(item);
                node.child_summaries[i] = item_summary;
            }
            node.len = @intCast(child_count);
            return null;
        }

        /// Prepends `small` to `large` (`small.height <= large.height`), consuming `small`.
        fn appendLarge(gpa: Allocator, small: Self, large: *Self, cx: Context) Allocator.Error!?Self {
            if (small.root.height == large.root.height) {
                if (!small.root.isUnderflowing()) return small;
                return mergeIntoRight(gpa, small, large, cx);
            }
            std.debug.assert(small.root.height < large.root.height);
            const node = large.makeMut(gpa) catch |err| {
                small.deinit(gpa);
                return err;
            };
            var full_summary = small.root.summary;
            full_summary.addSummary(&node.summary, cx);
            node.summary = full_summary;

            const first_child = &node.payload.children[0];
            const result = try appendLarge(gpa, small, first_child, cx);
            node.child_summaries[0] = first_child.root.summary;
            const tree = result orelse return null;
            if (node.len < capacity) {
                std.mem.copyBackwards(Self, node.payload.children[1 .. node.len + 1], node.children());
                std.mem.copyBackwards(Summary, node.child_summaries[1 .. node.len + 1], node.summaries());
                node.payload.children[0] = tree;
                node.child_summaries[0] = tree.root.summary;
                node.len += 1;
                return null;
            }
            const left = allocNode(gpa, node.height, undefined) catch |err| {
                tree.deinit(gpa);
                return err;
            };
            left.payload.children[0] = tree;
            left.child_summaries[0] = tree.root.summary;
            @memcpy(left.payload.children[1 .. tree_base + 1], node.payload.children[0..tree_base]);
            @memcpy(left.child_summaries[1 .. tree_base + 1], node.child_summaries[0..tree_base]);
            left.len = tree_base + 1;
            left.summary = sum(left.summaries(), cx);
            const remaining = node.len - tree_base;
            std.mem.copyForwards(Self, node.payload.children[0..remaining], node.payload.children[tree_base..node.len]);
            std.mem.copyForwards(Summary, node.child_summaries[0..remaining], node.child_summaries[tree_base..node.len]);
            node.len = @intCast(remaining);
            node.summary = sum(node.summaries(), cx);
            return .{ .root = left };
        }

        /// Merges underflowing `small` into the front of `large` (same height), consuming
        /// `small`. Returns a new left node when the merged contents overflow.
        fn mergeIntoRight(gpa: Allocator, small: Self, large: *Self, cx: Context) Allocator.Error!?Self {
            defer small.deinit(gpa);
            std.debug.assert(small.root.height == large.root.height);
            const node = try large.makeMut(gpa);
            const small_node = small.root;
            const total = small_node.len + node.len;
            const leaf = node.isLeaf();

            var all_summaries: [2 * capacity]Summary = undefined;
            @memcpy(all_summaries[0..small_node.len], small_node.summaries());
            @memcpy(all_summaries[small_node.len..total], node.summaries());
            var all_items: [2 * capacity]T = undefined;
            var all_trees: [2 * capacity]Self = undefined;
            if (leaf) {
                for (small_node.items(), 0..) |*item, i| all_items[i] = retainItem(item);
                @memcpy(all_items[small_node.len..total], node.items());
            } else {
                for (small_node.children(), 0..) |child, i| all_trees[i] = child.clone();
                @memcpy(all_trees[small_node.len..total], node.children());
            }

            if (total <= capacity) {
                @memcpy(node.child_summaries[0..total], all_summaries[0..total]);
                if (leaf) @memcpy(node.payload.items[0..total], all_items[0..total]) else @memcpy(node.payload.children[0..total], all_trees[0..total]);
                node.len = @intCast(total);
                var full_summary = small_node.summary;
                full_summary.addSummary(&node.summary, cx);
                node.summary = full_summary;
                return null;
            }

            const midpoint = (total + 1) / 2;
            const left = allocNode(gpa, node.height, undefined) catch |err| {
                if (leaf) {
                    for (all_items[0..small_node.len]) |*item| releaseItem(gpa, item);
                } else {
                    for (all_trees[0..small_node.len]) |tree| tree.deinit(gpa);
                }
                return err;
            };
            left.len = @intCast(midpoint);
            @memcpy(left.child_summaries[0..midpoint], all_summaries[0..midpoint]);
            node.len = @intCast(total - midpoint);
            @memcpy(node.child_summaries[0..node.len], all_summaries[midpoint..total]);
            if (leaf) {
                @memcpy(left.payload.items[0..midpoint], all_items[0..midpoint]);
                @memcpy(node.payload.items[0..node.len], all_items[midpoint..total]);
            } else {
                @memcpy(left.payload.children[0..midpoint], all_trees[0..midpoint]);
                @memcpy(node.payload.children[0..node.len], all_trees[midpoint..total]);
            }
            left.summary = sum(left.summaries(), cx);
            node.summary = sum(node.summaries(), cx);
            return .{ .root = left };
        }

        /// Does not consume `left` or `right` on failure.
        fn fromChildTrees(gpa: Allocator, left: Self, right: Self, cx: Context) Allocator.Error!Self {
            const node = try allocNode(gpa, left.root.height + 1, undefined);
            node.payload.children[0] = left;
            node.payload.children[1] = right;
            node.child_summaries[0] = left.root.summary;
            node.child_summaries[1] = right.root.summary;
            node.len = 2;
            node.summary = sum(node.summaries(), cx);
            return .{ .root = node };
        }

        // ---- keyed trees ----

        pub const KeyedEdit = union(enum) {
            insert: T,
            remove: KeyOf(T),
        };

        fn keyOf(item: *const T) KeyOf(T) {
            return keyedKey(T, item);
        }

        /// Inserts `item`, returning a replaced item with the same key.
        pub fn insertOrReplace(self: *Self, gpa: Allocator, item: T, cx: Context) Allocator.Error!?T {
            const K = KeyOf(T);
            const key = keyOf(&item);
            var replaced: ?T = null;
            var c = self.cursor(K, cx);
            var new_tree = try c.slice(gpa, key, .left);
            errdefer new_tree.deinit(gpa);
            if (c.item()) |cursor_item| {
                const cursor_key = keyOf(cursor_item);
                if (compareValues(K, &cursor_key, &key) == .eq) {
                    replaced = retainItem(cursor_item);
                    c.next();
                }
            }
            try new_tree.push(gpa, item, cx);
            try new_tree.append(gpa, try c.suffix(gpa), cx);
            self.deinit(gpa);
            self.* = new_tree;
            return replaced;
        }

        pub fn remove(self: *Self, gpa: Allocator, key: KeyOf(T), cx: Context) Allocator.Error!?T {
            const K = KeyOf(T);
            var removed: ?T = null;
            var c = self.cursor(K, cx);
            var new_tree = try c.slice(gpa, key, .left);
            errdefer new_tree.deinit(gpa);
            if (c.item()) |cursor_item| {
                const cursor_key = keyOf(cursor_item);
                if (compareValues(K, &cursor_key, &key) == .eq) {
                    removed = retainItem(cursor_item);
                    c.next();
                }
            }
            try new_tree.append(gpa, try c.suffix(gpa), cx);
            self.deinit(gpa);
            self.* = new_tree;
            return removed;
        }

        /// Applies sorted keyed edits; returns removed or replaced items (caller owns).
        pub fn edit(self: *Self, gpa: Allocator, edits: []KeyedEdit, cx: Context) Allocator.Error!std.ArrayList(T) {
            const K = KeyOf(T);
            var removed: std.ArrayList(T) = .empty;
            errdefer removed.deinit(gpa);
            if (edits.len == 0) return removed;

            const Sort = struct {
                fn editKey(e: *const KeyedEdit) K {
                    return switch (e.*) {
                        .insert => |*item| keyedKey(T, item),
                        .remove => |key| key,
                    };
                }
                fn lessThan(_: void, a: KeyedEdit, b: KeyedEdit) bool {
                    const ka = editKey(&a);
                    const kb = editKey(&b);
                    return compareValues(K, &ka, &kb) == .lt;
                }
            };
            std.sort.pdq(KeyedEdit, edits, {}, Sort.lessThan);

            var c = self.cursor(K, cx);
            var new_tree = try init(gpa, cx);
            errdefer new_tree.deinit(gpa);
            var buffered: std.ArrayList(T) = .empty;
            defer buffered.deinit(gpa);

            _ = c.seek(dimensionZero(Summary, K, cx), .left);
            for (edits) |*e| {
                const new_key = Sort.editKey(e);
                var old_item = c.item();
                if (old_item) |old| {
                    const old_key = keyOf(old);
                    if (compareValues(K, &old_key, &new_key) == .lt) {
                        try new_tree.extend(gpa, buffered.items, cx);
                        buffered.clearRetainingCapacity();
                        try new_tree.append(gpa, try c.slice(gpa, new_key, .left), cx);
                        old_item = c.item();
                    }
                }
                if (old_item) |old| {
                    const old_key = keyOf(old);
                    if (compareValues(K, &old_key, &new_key) == .eq) {
                        try removed.append(gpa, retainItem(old));
                        c.next();
                    }
                }
                switch (e.*) {
                    .insert => |item| try buffered.append(gpa, item),
                    .remove => {},
                }
            }
            try new_tree.extend(gpa, buffered.items, cx);
            buffered.clearRetainingCapacity();
            try new_tree.append(gpa, try c.suffix(gpa), cx);
            self.deinit(gpa);
            self.* = new_tree;
            return removed;
        }

        pub fn get(self: Self, key: KeyOf(T), cx: Context) ?*const T {
            return self.findExact(KeyOf(T), cx, key, .left).item;
        }

        // ---- iteration ----

        const StackEntry = struct { node: *const Node, index: u32 };

        /// Depth-first item iterator (`cursor.rs` `Iter`).
        pub const Iter = struct {
            tree: *const Self,
            stack: [max_height]StackEntry = undefined,
            stack_len: u8 = 0,

            pub fn next(it: *Iter) ?*const T {
                var descend = false;
                if (it.stack_len == 0) {
                    it.stack[0] = .{ .node = it.tree.root, .index = 0 };
                    it.stack_len = 1;
                    descend = true;
                }
                while (it.stack_len > 0) {
                    const entry = &it.stack[it.stack_len - 1];
                    if (!descend) entry.index += 1;
                    if (!entry.node.isLeaf()) {
                        if (entry.index < entry.node.len) {
                            it.stack[it.stack_len] = .{ .node = entry.node.children()[entry.index].root, .index = 0 };
                            it.stack_len += 1;
                            descend = true;
                            continue;
                        }
                    } else if (entry.index < entry.node.len) {
                        return &entry.node.items()[entry.index];
                    }
                    descend = false;
                    it.stack_len -= 1;
                }
                return null;
            }
        };

        pub fn Cursor(comptime D: type) type {
            return struct {
                const CursorSelf = @This();
                const Entry = struct { node: *const Node, index: u32, position: D };

                tree: *const Self,
                stack: [max_height]Entry = undefined,
                stack_len: u8 = 0,
                position: D,
                did_seek: bool = false,
                at_end: bool,
                cx: Context,

                pub fn init(tree: *const Self, cx: Context) CursorSelf {
                    return .{ .tree = tree, .position = dimensionZero(Summary, D, cx), .at_end = tree.isEmpty(), .cx = cx };
                }

                fn top(self: *const CursorSelf) ?*const Entry {
                    return if (self.stack_len == 0) null else &self.stack[self.stack_len - 1];
                }

                fn pushEntry(self: *CursorSelf, entry: Entry) void {
                    std.debug.assert(self.stack_len < max_height);
                    self.stack[self.stack_len] = entry;
                    self.stack_len += 1;
                }

                pub fn reset(self: *CursorSelf) void {
                    self.did_seek = false;
                    self.at_end = self.tree.isEmpty();
                    self.stack_len = 0;
                    self.position = dimensionZero(Summary, D, self.cx);
                }

                pub fn start(self: *const CursorSelf) *const D {
                    return &self.position;
                }

                pub fn end(self: *const CursorSelf) D {
                    var result = self.position;
                    if (self.itemSummary()) |item_summary| dimensionAdd(Summary, D, &result, item_summary, self.cx);
                    return result;
                }

                pub fn didSeek(self: *const CursorSelf) bool {
                    return self.did_seek;
                }

                /// Null when the tree is empty or the cursor is past the end.
                pub fn item(self: *const CursorSelf) ?*const T {
                    std.debug.assert(self.did_seek);
                    const entry = self.top() orelse return null;
                    return if (entry.index == entry.node.len) null else &entry.node.items()[entry.index];
                }

                pub fn itemSummary(self: *const CursorSelf) ?*const Summary {
                    std.debug.assert(self.did_seek);
                    const entry = self.top() orelse return null;
                    return if (entry.index == entry.node.len) null else &entry.node.child_summaries[entry.index];
                }

                pub fn nextItem(self: *const CursorSelf) ?*const T {
                    std.debug.assert(self.did_seek);
                    if (self.top()) |entry| {
                        if (entry.index == entry.node.len - 1) {
                            const leaf = self.nextLeaf() orelse return null;
                            return &leaf.items()[0];
                        }
                        return &entry.node.items()[entry.index + 1];
                    }
                    if (self.at_end) return null;
                    return self.tree.first();
                }

                fn nextLeaf(self: *const CursorSelf) ?*const Node {
                    var i = self.stack_len - 1;
                    while (i > 0) {
                        i -= 1;
                        const entry = &self.stack[i];
                        if (entry.index < entry.node.len - 1) return entry.node.children()[entry.index + 1].leftmostLeaf();
                    }
                    return null;
                }

                pub fn prevItem(self: *const CursorSelf) ?*const T {
                    std.debug.assert(self.did_seek);
                    if (self.top()) |entry| {
                        if (entry.index == 0) {
                            const leaf = self.prevLeaf() orelse return null;
                            return &leaf.items()[leaf.len - 1];
                        }
                        return &entry.node.items()[entry.index - 1];
                    }
                    if (self.at_end) return self.tree.last();
                    return null;
                }

                fn prevLeaf(self: *const CursorSelf) ?*const Node {
                    var i = self.stack_len - 1;
                    while (i > 0) {
                        i -= 1;
                        const entry = &self.stack[i];
                        if (entry.index != 0) return entry.node.children()[entry.index - 1].rightmostLeaf();
                    }
                    return null;
                }

                pub fn prev(self: *CursorSelf) void {
                    self.searchBackward(acceptAll);
                }

                pub fn next(self: *CursorSelf) void {
                    self.searchForward(acceptAll);
                }

                pub fn searchBackward(self: *CursorSelf, filter_node: anytype) void {
                    if (!self.did_seek) {
                        self.did_seek = true;
                        self.at_end = true;
                    }
                    if (self.at_end) {
                        self.position = dimensionZero(Summary, D, self.cx);
                        self.at_end = self.tree.isEmpty();
                        if (!self.tree.isEmpty()) {
                            var position = dimensionZero(Summary, D, self.cx);
                            dimensionAdd(Summary, D, &position, &self.tree.root.summary, self.cx);
                            self.pushEntry(.{ .node = self.tree.root, .index = self.tree.root.len, .position = position });
                        }
                    }

                    var descending = false;
                    while (self.stack_len > 0) {
                        self.position = if (self.stack_len >= 2) self.stack[self.stack_len - 2].position else dimensionZero(Summary, D, self.cx);
                        const entry = &self.stack[self.stack_len - 1];
                        if (!descending) {
                            if (entry.index == 0) {
                                self.stack_len -= 1;
                                continue;
                            }
                            entry.index -= 1;
                        }
                        for (entry.node.child_summaries[0..entry.index]) |*child_summary| dimensionAdd(Summary, D, &self.position, child_summary, self.cx);
                        entry.position = self.position;

                        descending = callFilter(filter_node, &entry.node.child_summaries[entry.index]);
                        if (!entry.node.isLeaf()) {
                            if (descending) {
                                const child = entry.node.children()[entry.index].root;
                                self.pushEntry(.{ .node = child, .index = child.len - 1, .position = dimensionZero(Summary, D, self.cx) });
                            }
                        } else if (descending) break;
                    }
                }

                pub fn searchForward(self: *CursorSelf, filter_node: anytype) void {
                    var descend = false;
                    if (self.stack_len == 0) {
                        if (!self.at_end) {
                            self.pushEntry(.{ .node = self.tree.root, .index = 0, .position = dimensionZero(Summary, D, self.cx) });
                            descend = true;
                        }
                        self.did_seek = true;
                    }

                    outer: while (self.stack_len > 0) {
                        const entry = &self.stack[self.stack_len - 1];
                        var subtree: ?*const Node = null;
                        if (!entry.node.isLeaf()) {
                            if (!descend) {
                                entry.index += 1;
                                entry.position = self.position;
                            }
                            while (entry.index < entry.node.len) {
                                const next_summary = &entry.node.child_summaries[entry.index];
                                if (callFilter(filter_node, next_summary)) break;
                                entry.index += 1;
                                dimensionAdd(Summary, D, &entry.position, next_summary, self.cx);
                                dimensionAdd(Summary, D, &self.position, next_summary, self.cx);
                            }
                            if (entry.index < entry.node.len) subtree = entry.node.children()[entry.index].root;
                        } else {
                            if (!descend) {
                                const item_summary = &entry.node.child_summaries[entry.index];
                                entry.index += 1;
                                dimensionAdd(Summary, D, &entry.position, item_summary, self.cx);
                                dimensionAdd(Summary, D, &self.position, item_summary, self.cx);
                            }
                            while (entry.index < entry.node.len) {
                                const next_summary = &entry.node.child_summaries[entry.index];
                                if (callFilter(filter_node, next_summary)) break :outer;
                                entry.index += 1;
                                dimensionAdd(Summary, D, &entry.position, next_summary, self.cx);
                                dimensionAdd(Summary, D, &self.position, next_summary, self.cx);
                            }
                        }

                        if (subtree) |node| {
                            descend = true;
                            self.pushEntry(.{ .node = node, .index = 0, .position = self.position });
                        } else {
                            descend = false;
                            self.stack_len -= 1;
                        }
                    }
                    self.at_end = self.stack_len == 0;
                }

                /// Resets and seeks; returns whether the target was found exactly.
                pub fn seek(self: *CursorSelf, target: anytype, bias: Bias) bool {
                    self.reset();
                    var aggregate: NoAggregate = .{};
                    return self.seekInternal(&target, bias, &aggregate) catch unreachable;
                }

                /// Seeks forward from the current position (must have seeked before).
                pub fn seekForward(self: *CursorSelf, target: anytype, bias: Bias) bool {
                    var aggregate: NoAggregate = .{};
                    return self.seekInternal(&target, bias, &aggregate) catch unreachable;
                }

                /// Advances to `end` and returns the traversed items as a new tree.
                pub fn slice(self: *CursorSelf, gpa: Allocator, end_target: anytype, bias: Bias) Allocator.Error!Self {
                    var aggregate: SliceAggregate = .{ .gpa = gpa, .tree = try Self.init(gpa, self.cx), .leaf_summary = Summary.zero(self.cx) };
                    errdefer aggregate.discard();
                    _ = try self.seekInternal(&end_target, bias, &aggregate);
                    return aggregate.tree;
                }

                pub fn suffix(self: *CursorSelf, gpa: Allocator) Allocator.Error!Self {
                    return self.slice(gpa, End{}, .right);
                }

                /// Advances to `end` and returns the summed `Output` dimension.
                pub fn summary(self: *CursorSelf, comptime Output: type, end_target: anytype, bias: Bias) Output {
                    var aggregate: SummaryAggregate(Output) = .{ .value = dimensionZero(Summary, Output, self.cx) };
                    _ = self.seekInternal(&end_target, bias, &aggregate) catch unreachable;
                    return aggregate.value;
                }

                /// Zed's `Iterator for Cursor`: returns the current item and advances.
                pub fn nextIter(self: *CursorSelf) ?*const T {
                    if (!self.did_seek) self.next();
                    const current = self.item() orelse return null;
                    self.next();
                    return current;
                }

                fn seekInternal(self: *CursorSelf, target: anytype, bias: Bias, aggregate: anytype) !bool {
                    std.debug.assert(seekCmp(target, &self.position, self.cx) != .lt);
                    if (!self.did_seek) {
                        self.did_seek = true;
                        self.pushEntry(.{ .node = self.tree.root, .index = 0, .position = dimensionZero(Summary, D, self.cx) });
                    }

                    var ascending = false;
                    outer: while (self.stack_len > 0) {
                        const entry = &self.stack[self.stack_len - 1];
                        if (!entry.node.isLeaf()) {
                            if (ascending) {
                                entry.index += 1;
                                entry.position = self.position;
                            }
                            while (entry.index < entry.node.len) {
                                const child_tree = &entry.node.children()[entry.index];
                                const child_summary = &entry.node.child_summaries[entry.index];
                                var child_end = self.position;
                                dimensionAdd(Summary, D, &child_end, child_summary, self.cx);
                                const comparison = seekCmp(target, &child_end, self.cx);
                                if (comparison == .gt or (comparison == .eq and bias == .right)) {
                                    self.position = child_end;
                                    try aggregate.pushTree(child_tree, child_summary, self.cx);
                                    entry.index += 1;
                                    entry.position = self.position;
                                } else {
                                    self.pushEntry(.{ .node = child_tree.root, .index = 0, .position = self.position });
                                    ascending = false;
                                    continue :outer;
                                }
                            }
                        } else {
                            aggregate.beginLeaf();
                            while (entry.index < entry.node.len) {
                                const leaf_item = &entry.node.items()[entry.index];
                                const item_summary = &entry.node.child_summaries[entry.index];
                                var child_end = self.position;
                                dimensionAdd(Summary, D, &child_end, item_summary, self.cx);
                                const comparison = seekCmp(target, &child_end, self.cx);
                                if (comparison == .gt or (comparison == .eq and bias == .right)) {
                                    self.position = child_end;
                                    try aggregate.pushItem(leaf_item, item_summary, self.cx);
                                    entry.index += 1;
                                } else {
                                    try aggregate.endLeaf(self.cx);
                                    break :outer;
                                }
                            }
                            try aggregate.endLeaf(self.cx);
                        }
                        self.stack_len -= 1;
                        ascending = true;
                    }

                    self.at_end = self.stack_len == 0;
                    var end_position = self.position;
                    if (bias == .left) {
                        if (self.itemSummary()) |item_summary| dimensionAdd(Summary, D, &end_position, item_summary, self.cx);
                    }
                    return seekCmp(target, &end_position, self.cx) == .eq;
                }
            };
        }

        pub fn FilterCursor(comptime D: type, comptime F: type) type {
            return struct {
                const FilterSelf = @This();
                cursor: Cursor(D),
                filter_node: F,

                pub fn start(self: *const FilterSelf) *const D {
                    return self.cursor.start();
                }
                pub fn end(self: *const FilterSelf) D {
                    return self.cursor.end();
                }
                pub fn item(self: *const FilterSelf) ?*const T {
                    return self.cursor.item();
                }
                pub fn itemSummary(self: *const FilterSelf) ?*const Summary {
                    return self.cursor.itemSummary();
                }
                pub fn next(self: *FilterSelf) void {
                    self.cursor.searchForward(self.filter_node);
                }
                pub fn prev(self: *FilterSelf) void {
                    self.cursor.searchBackward(self.filter_node);
                }
                pub fn nextIter(self: *FilterSelf) ?*const T {
                    if (!self.cursor.did_seek) self.next();
                    const current = self.item() orelse return null;
                    self.next();
                    return current;
                }
            };
        }

        const NoAggregate = struct {
            fn beginLeaf(_: *NoAggregate) void {}
            fn endLeaf(_: *NoAggregate, _: Context) error{}!void {}
            fn pushItem(_: *NoAggregate, _: *const T, _: *const Summary, _: Context) error{}!void {}
            fn pushTree(_: *NoAggregate, _: *const Self, _: *const Summary, _: Context) error{}!void {}
        };

        fn SummaryAggregate(comptime Output: type) type {
            return struct {
                value: Output,
                const Agg = @This();
                fn beginLeaf(_: *Agg) void {}
                fn endLeaf(_: *Agg, _: Context) error{}!void {}
                fn pushItem(agg: *Agg, _: *const T, item_summary: *const Summary, cx: Context) error{}!void {
                    dimensionAdd(Summary, Output, &agg.value, item_summary, cx);
                }
                fn pushTree(agg: *Agg, _: *const Self, tree_summary: *const Summary, cx: Context) error{}!void {
                    dimensionAdd(Summary, Output, &agg.value, tree_summary, cx);
                }
            };
        }

        const SliceAggregate = struct {
            gpa: Allocator,
            tree: Self,
            leaf_items: [capacity]T = undefined,
            leaf_summaries: [capacity]Summary = undefined,
            leaf_len: u8 = 0,
            leaf_summary: Summary,

            fn discard(agg: *SliceAggregate) void {
                for (agg.leaf_items[0..agg.leaf_len]) |*item| releaseItem(agg.gpa, item);
                agg.leaf_len = 0;
                agg.tree.deinit(agg.gpa);
            }

            fn beginLeaf(_: *SliceAggregate) void {}

            fn endLeaf(agg: *SliceAggregate, cx: Context) Allocator.Error!void {
                if (agg.leaf_len == 0) return;
                const node = try allocNode(agg.gpa, 0, agg.leaf_summary);
                node.len = agg.leaf_len;
                @memcpy(node.payload.items[0..agg.leaf_len], agg.leaf_items[0..agg.leaf_len]);
                @memcpy(node.child_summaries[0..agg.leaf_len], agg.leaf_summaries[0..agg.leaf_len]);
                agg.leaf_len = 0;
                agg.leaf_summary = Summary.zero(cx);
                try agg.tree.append(agg.gpa, .{ .root = node }, cx);
            }

            fn pushItem(agg: *SliceAggregate, item: *const T, item_summary: *const Summary, cx: Context) Allocator.Error!void {
                agg.leaf_items[agg.leaf_len] = retainItem(item);
                agg.leaf_summaries[agg.leaf_len] = item_summary.*;
                agg.leaf_len += 1;
                agg.leaf_summary.addSummary(item_summary, cx);
            }

            fn pushTree(agg: *SliceAggregate, tree: *const Self, _: *const Summary, cx: Context) Allocator.Error!void {
                try agg.tree.append(agg.gpa, tree.clone(), cx);
            }
        };

        fn acceptAll(_: *const Summary) bool {
            return true;
        }

        inline fn callFilter(filter_node: anytype, node_summary: *const Summary) bool {
            const F = @TypeOf(filter_node);
            return switch (@typeInfo(F)) {
                .@"fn" => filter_node(node_summary),
                .pointer => |pointer| if (@typeInfo(pointer.child) == .@"fn") filter_node(node_summary) else filter_node.filter(node_summary),
                else => filter_node.filter(node_summary),
            };
        }
    };
}

pub fn KeyOf(comptime T: type) type {
    if (comptime isStruct(T) and @hasDecl(T, "Key")) return T.Key;
    return T;
}

fn keyedKey(comptime T: type, item: *const T) KeyOf(T) {
    if (comptime isStruct(T) and @hasDecl(T, "key")) return item.key();
    return item.*;
}

test {
    _ = @import("tests.zig");
}
