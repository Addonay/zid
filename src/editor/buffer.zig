const std = @import("std");

/// A gap buffer keeps edits near the caret cheap. Offsets are UTF-8 byte offsets;
/// line indexing belongs to Document, not to the storage implementation.
pub const Buffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    gap_start: usize,
    gap_end: usize,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !Buffer {
        const storage = try allocator.alloc(u8, text.len + 4096);
        @memcpy(storage[0..text.len], text);
        return .{ .allocator = allocator, .storage = storage, .gap_start = text.len, .gap_end = storage.len };
    }
    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.storage);
    }
    pub fn len(self: *const Buffer) usize {
        return self.storage.len - (self.gap_end - self.gap_start);
    }
    pub fn byteAt(self: *const Buffer, offset: usize) u8 {
        std.debug.assert(offset < self.len());
        return self.storage[if (offset < self.gap_start) offset else offset + self.gap_end - self.gap_start];
    }
    pub fn copy(self: *const Buffer, start: usize, out: []u8) void {
        for (out, start..) |*byte, index| byte.* = self.byteAt(index);
    }
    pub fn toOwnedSlice(self: *const Buffer, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.len());
        self.copy(0, out);
        return out;
    }
    fn moveGap(self: *Buffer, offset: usize) void {
        if (offset < self.gap_start) {
            const count = self.gap_start - offset;
            std.mem.copyBackwards(u8, self.storage[self.gap_end - count .. self.gap_end], self.storage[offset..self.gap_start]);
            self.gap_end -= count;
        } else if (offset > self.gap_start) {
            const count = offset - self.gap_start;
            std.mem.copyForwards(u8, self.storage[self.gap_start..][0..count], self.storage[self.gap_end..][0..count]);
            self.gap_end += count;
        }
        self.gap_start = offset;
    }
    pub fn reserve(self: *Buffer, additional: usize) !void {
        if (self.gap_end - self.gap_start >= additional) return;
        const capacity = @max(self.storage.len * 2, self.len() + additional + 4096);
        const expanded = try self.allocator.alloc(u8, capacity);
        @memcpy(expanded[0..self.gap_start], self.storage[0..self.gap_start]);
        const tail = self.storage.len - self.gap_end;
        @memcpy(expanded[capacity - tail ..], self.storage[self.gap_end..]);
        self.allocator.free(self.storage);
        self.storage = expanded;
        self.gap_end = capacity - tail;
    }
    pub fn replace(self: *Buffer, start: usize, end: usize, text: []const u8) !void {
        std.debug.assert(start <= end and end <= self.len());
        try self.reserve(text.len);
        self.moveGap(start);
        self.gap_end += end - start;
        @memcpy(self.storage[self.gap_start..][0..text.len], text);
        self.gap_start += text.len;
    }
    pub fn previous(self: *const Buffer, offset: usize) usize {
        if (offset == 0) return 0;
        var index = offset - 1;
        while (index > 0 and self.byteAt(index) & 0xc0 == 0x80) index -= 1;
        return index;
    }
    pub fn next(self: *const Buffer, offset: usize) usize {
        if (offset >= self.len()) return self.len();
        var index = offset + 1;
        while (index < self.len() and self.byteAt(index) & 0xc0 == 0x80) index += 1;
        return index;
    }
};

test "gap moves both directions and grows without losing text" {
    var buffer = try Buffer.init(std.testing.allocator, "abcdef");
    defer buffer.deinit();
    try buffer.replace(2, 4, "XY");
    try buffer.replace(0, 0, "!");
    try buffer.replace(buffer.len(), buffer.len(), "?");
    const text = try buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("!abXYef?", text);
    const many = try std.testing.allocator.alloc(u8, 10000);
    defer std.testing.allocator.free(many);
    @memset(many, 'x');
    try buffer.replace(1, 1, many);
    try std.testing.expectEqual(@as(usize, 10008), buffer.len());
    try std.testing.expectEqual(@as(u8, '?'), buffer.byteAt(buffer.len() - 1));
}
test "UTF-8 navigation stays on codepoint boundaries" {
    var buffer = try Buffer.init(std.testing.allocator, "aé中");
    defer buffer.deinit();
    try std.testing.expectEqual(@as(usize, 3), buffer.previous(6));
    try std.testing.expectEqual(@as(usize, 3), buffer.next(1));
    try std.testing.expectEqual(@as(usize, 0), buffer.previous(0));
}

test "gap buffer agrees with a flat reference over 1000 deterministic edits" {
    var buffer = try Buffer.init(std.testing.allocator, "");
    defer buffer.deinit();
    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(std.testing.allocator);
    var random = std.Random.DefaultPrng.init(731);
    for (0..1000) |_| {
        const start = random.random().uintAtMost(usize, reference.items.len);
        const end = start + random.random().uintAtMost(usize, reference.items.len - start);
        var bytes: [17]u8 = undefined;
        random.random().bytes(&bytes);
        const inserted = bytes[0..random.random().uintAtMost(usize, bytes.len)];
        try buffer.replace(start, end, inserted);
        try reference.replaceRange(std.testing.allocator, start, end - start, inserted);
        const actual = try buffer.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualSlices(u8, reference.items, actual);
    }
}
