//! Backing storage for piece-tree text.
//!
//! `Store` is shared (reference-counted) by a document and all snapshots of it.
//! It owns two kinds of bytes:
//!   - the *original*: either an immutable heap block (small files) or a file read
//!     on demand with positional reads (large files, bounded RSS);
//!   - the *add* buffer: append-only 1 MiB blocks that never move, so snapshot
//!     readers on other threads can read old blocks while the owner appends.
const std = @import("std");

pub const block_size = 1 << 20;
const max_blocks = 1 << 14; // 16 GiB of inserted text per document

pub const Origin = enum(u1) { original, add };

pub const FileIdentity = struct { size: u64, mtime: i96, inode: u64 };

pub const Store = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    original: Original,
    blocks: [max_blocks]?*[block_size]u8 = @splat(null),
    /// Bytes written to the add buffer. Only the owning thread appends.
    add_len: std.atomic.Value(u64) = .init(0),
    prng: std.Random.DefaultPrng,

    pub const Original = union(enum) {
        none,
        memory: []const u8, // owned, allocated with `allocator`
        file: struct { file: std.Io.File, len: u64, identity: FileIdentity },
    };

    pub fn create(allocator: std.mem.Allocator, original: Original) !*Store {
        const self = try allocator.create(Store);
        self.* = .{ .allocator = allocator, .original = original, .prng = .init(0x5eed_2d1d) };
        return self;
    }
    pub fn retain(self: *Store) *Store {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Store, io: std.Io) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        switch (self.original) {
            .none => {},
            .memory => |bytes| self.allocator.free(bytes),
            .file => |f| f.file.close(io),
        }
        for (self.blocks) |block| if (block) |b| self.allocator.destroy(b);
        self.allocator.destroy(self);
    }
    pub fn originalLen(self: *const Store) u64 {
        return switch (self.original) {
            .none => 0,
            .memory => |bytes| bytes.len,
            .file => |f| f.len,
        };
    }
    pub fn isFileBacked(self: *const Store) bool {
        return self.original == .file;
    }

    /// Appends text and returns the add-buffer offsets of the written ranges.
    /// A range never crosses a block boundary.
    pub fn append(self: *Store, text: []const u8, out: *std.ArrayList(Range), allocator: std.mem.Allocator) !void {
        const initial_ranges = out.items.len;
        errdefer out.shrinkRetainingCapacity(initial_ranges);
        const capacity: u64 = @as(u64, max_blocks) * block_size;
        if (text.len > capacity - self.add_len.load(.monotonic)) return error.AddBufferFull;
        var rest = text;
        var at = self.add_len.load(.monotonic);
        while (rest.len > 0) {
            const index: usize = @intCast(at / block_size);
            if (index >= max_blocks) return error.AddBufferFull;
            const within: usize = @intCast(at % block_size);
            if (self.blocks[index] == null) self.blocks[index] = try self.allocator.create([block_size]u8);
            const n = @min(rest.len, block_size - within);
            @memcpy(self.blocks[index].?[within..][0..n], rest[0..n]);
            try out.append(allocator, .{ .offset = at, .len = @intCast(n) });
            at += n;
            rest = rest[n..];
        }
        self.add_len.store(at, .release);
    }

    /// Add-buffer bytes are always directly addressable.
    pub fn addSlice(self: *const Store, offset: u64, len: u32) []const u8 {
        const block = self.blocks[@intCast(offset / block_size)].?;
        const within: usize = @intCast(offset % block_size);
        return block[within..][0..len];
    }
    /// Memory originals are directly addressable; file originals are not.
    pub fn originalSlice(self: *const Store, offset: u64, len: u32) ?[]const u8 {
        return switch (self.original) {
            .memory => |bytes| bytes[@intCast(offset)..][0..len],
            else => null,
        };
    }
    /// Positional read from a file original. Short reads mean the file shrank.
    pub fn readOriginal(self: *const Store, io: std.Io, offset: u64, out: []u8) !void {
        switch (self.original) {
            .file => |f| {
                const n = try f.file.readPositionalAll(io, out, offset);
                if (n != out.len) return error.FileChangedUnderneath;
            },
            .memory => |bytes| @memcpy(out, bytes[@intCast(offset)..][0..out.len]),
            .none => unreachable,
        }
    }
};

pub const Range = struct { offset: u64, len: u32 };

test "add buffer splits at block boundaries and stays addressable" {
    const store = try Store.create(std.testing.allocator, .none);
    defer store.release(undefined);
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(std.testing.allocator);
    const filler = try std.testing.allocator.alloc(u8, block_size - 3);
    defer std.testing.allocator.free(filler);
    @memset(filler, 'x');
    try store.append(filler, &ranges, std.testing.allocator);
    try store.append("abcdef", &ranges, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), ranges.items.len);
    try std.testing.expectEqualStrings("abc", store.addSlice(ranges.items[1].offset, ranges.items[1].len));
    try std.testing.expectEqualStrings("def", store.addSlice(ranges.items[2].offset, ranges.items[2].len));
}

fn appendAllocationScenario(gpa: std.mem.Allocator) !void {
    const store = try Store.create(gpa, .none);
    defer store.release(undefined);
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(gpa);
    const filler = try gpa.alloc(u8, block_size - 2);
    defer gpa.free(filler);
    @memset(filler, 'q');
    try store.append(filler, &ranges, gpa);
    const old_len = store.add_len.load(.acquire);
    const old_ranges = ranges.items.len;
    store.append("abcd", &ranges, gpa) catch |err| {
        try std.testing.expectEqual(old_len, store.add_len.load(.acquire));
        try std.testing.expectEqual(old_ranges, ranges.items.len);
        try std.testing.expectEqualSlices(u8, filler, store.addSlice(0, @intCast(filler.len)));
        return err;
    };
    try std.testing.expectEqualStrings("ab", store.addSlice(old_len, 2));
    try std.testing.expectEqualStrings("cd", store.addSlice(block_size, 2));
    try std.testing.expectEqualSlices(u8, filler, store.addSlice(0, @intCast(filler.len)));
}

test "append allocation failures preserve published bytes and ranges" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, appendAllocationScenario, .{});
}
