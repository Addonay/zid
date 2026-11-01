//! Port of Zed's `clock` crate (`.ref/zed/crates/clock/src/clock.rs`): replica ids,
//! Lamport timestamps and version vectors. `system_clock.rs` is not ported.
const std = @import("std");
const Order = std.math.Order;

pub const ReplicaId = enum(u16) {
    local = 0,
    remote_server = 1,
    agent = 2,
    local_branch = 3,
    first_collab_id = 8,
    _,

    pub fn new(id: u16) ReplicaId {
        return @fromBackingInt(@intCast(id));
    }

    pub fn asU16(self: ReplicaId) u16 {
        return @backingInt(self);
    }

    pub fn isRemote(self: ReplicaId) bool {
        return self == .remote_server or self.asU16() >= ReplicaId.first_collab_id.asU16();
    }
};

pub const Seq = u32;

pub const Lamport = struct {
    value: Seq,
    replica_id: ReplicaId,

    pub const min: Lamport = .{ .replica_id = .new(0), .value = 0 };
    pub const max: Lamport = .{ .replica_id = .new(std.math.maxInt(u16)), .value = std.math.maxInt(Seq) };

    pub fn init(replica_id: ReplicaId) Lamport {
        return .{ .value = 1, .replica_id = replica_id };
    }

    /// Orders by value, breaking ties between concurrent events by replica id.
    pub fn cmp(a: *const Lamport, b: *const Lamport) Order {
        return switch (std.math.order(a.value, b.value)) {
            .eq => std.math.order(a.replica_id.asU16(), b.replica_id.asU16()),
            else => |order| order,
        };
    }

    pub fn eql(a: Lamport, b: Lamport) bool {
        return a.value == b.value and a.replica_id == b.replica_id;
    }

    pub fn asU64(self: Lamport) u64 {
        return (@as(u64, self.value) << 32) | self.replica_id.asU16();
    }

    pub fn tick(self: *Lamport) Lamport {
        const timestamp = self.*;
        self.value += 1;
        return timestamp;
    }

    pub fn observe(self: *Lamport, timestamp: Lamport) void {
        self.value = @max(self.value, timestamp.value) + 1;
    }
};

/// A version vector. Zed stores it in a `SmallVec<[u32; 4]>` that spills to the heap.
/// Here it is a plain value with room for every non-collaborative replica id
/// (`ReplicaId.first_collab_id` = 8), so it can live inside SumTree summaries.
/// Collaborative replica ids are not supported yet; observing one is a checked error.
pub const Global = struct {
    pub const capacity = ReplicaId.first_collab_id.asU16();

    len: u8 = 0,
    seqs: [capacity]u32 = @splat(0),

    pub const empty: Global = .{};

    pub fn values(self: *const Global) []const u32 {
        return self.seqs[0..self.len];
    }

    fn resize(self: *Global, new_len: usize) void {
        std.debug.assert(new_len <= capacity);
        if (new_len > self.len) @memset(self.seqs[self.len..new_len], 0);
        self.len = @intCast(new_len);
    }

    pub fn get(self: *const Global, replica_id: ReplicaId) Seq {
        const index = replica_id.asU16();
        return if (index < self.len) self.seqs[index] else 0;
    }

    pub fn observe(self: *Global, timestamp: Lamport) void {
        std.debug.assert(timestamp.replica_id != Lamport.max.replica_id);
        if (timestamp.value > 0) {
            const index = timestamp.replica_id.asU16();
            if (index >= capacity) @panic("collaborative replica ids are not supported yet");
            if (index + 1 > self.len) self.resize(index + 1);
            self.seqs[index] = @max(self.seqs[index], timestamp.value);
        }
    }

    pub fn join(self: *Global, other: *const Global) void {
        if (other.len > self.len) self.resize(other.len);
        for (self.seqs[0..other.len], other.values()) |*left, right| left.* = @max(left.*, right);
    }

    pub fn meet(self: *Global, other: *const Global) void {
        if (other.len > self.len) self.resize(other.len);
        var new_len: usize = 0;
        for (self.seqs[0..other.len], other.values(), 0..) |*left, right, ix| {
            if (left.* == 0) {
                left.* = right;
            } else if (right != 0) {
                left.* = @min(left.*, right);
            }
            if (left.* != 0) new_len = ix + 1;
        }
        // Only truncate when `other` was not shorter; otherwise the unprocessed tail
        // holds non-zero timestamps.
        if (other.len == self.len) self.len = @intCast(new_len);
    }

    pub fn observed(self: *const Global, timestamp: Lamport) bool {
        return self.get(timestamp.replica_id) >= timestamp.value;
    }

    pub fn observedAny(self: *const Global, other: *const Global) bool {
        const n = @min(self.len, other.len);
        for (self.seqs[0..n], other.seqs[0..n]) |left, right| {
            if (right > 0 and left >= right) return true;
        }
        return false;
    }

    pub fn observedAll(self: *const Global, other: *const Global) bool {
        if (self.len < other.len) return false;
        for (self.seqs[0..other.len], other.values()) |left, right| {
            if (left < right) return false;
        }
        return true;
    }

    pub fn changedSince(self: *const Global, other: *const Global) bool {
        if (self.len > other.len) return true;
        for (self.values(), other.seqs[0..self.len]) |left, right| {
            if (left > right) return true;
        }
        return false;
    }

    pub fn mostRecent(self: *const Global) ?Lamport {
        var best: ?Lamport = null;
        for (self.values(), 0..) |seq, replica| {
            // `Iterator::max_by_key` keeps the last maximum.
            if (best == null or seq >= best.?.value) best = .{ .replica_id = .new(@intCast(replica)), .value = seq };
        }
        return best;
    }

    pub fn eql(a: *const Global, b: *const Global) bool {
        return std.mem.eql(u32, a.values(), b.values());
    }
};

const testing = std.testing;

test "lamport ordering and tick" {
    var clock = Lamport.init(.new(3));
    const first = clock.tick();
    try testing.expectEqual(@as(Seq, 1), first.value);
    try testing.expectEqual(@as(Seq, 2), clock.value);
    const a: Lamport = .{ .value = 5, .replica_id = .new(1) };
    const b: Lamport = .{ .value = 5, .replica_id = .new(2) };
    try testing.expectEqual(Order.lt, a.cmp(&b));
    clock.observe(.{ .value = 10, .replica_id = .new(0) });
    try testing.expectEqual(@as(Seq, 11), clock.value);
    try testing.expectEqual((@as(u64, 5) << 32) | 2, b.asU64());
}

test "global observe join meet" {
    var a: Global = .empty;
    var b: Global = .empty;
    a.observe(.{ .value = 3, .replica_id = .new(0) });
    a.observe(.{ .value = 2, .replica_id = .new(7) });
    b.observe(.{ .value = 5, .replica_id = .new(0) });
    b.observe(.{ .value = 1, .replica_id = .new(2) });
    try testing.expect(a.observed(.{ .value = 2, .replica_id = .new(7) }));
    try testing.expect(!a.observed(.{ .value = 4, .replica_id = .new(0) }));
    try testing.expect(a.changedSince(&b));
    try testing.expect(!b.observedAll(&a));

    var joined = a;
    joined.join(&b);
    try testing.expectEqual(@as(Seq, 5), joined.get(.new(0)));
    try testing.expectEqual(@as(Seq, 1), joined.get(.new(2)));
    try testing.expectEqual(@as(Seq, 2), joined.get(.new(7)));
    try testing.expect(joined.observedAll(&a) and joined.observedAll(&b));

    var met = b;
    met.meet(&a);
    try testing.expectEqual(@as(Seq, 3), met.get(.new(0)));
    try testing.expectEqual(@as(Seq, 1), met.get(.new(2)));
    try testing.expectEqual(@as(Seq, 2), met.get(.new(7)));
    try testing.expectEqual(@as(u16, 0), met.mostRecent().?.replica_id.asU16());
}
