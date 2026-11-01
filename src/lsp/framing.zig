const std = @import("std");

/// Incremental, bounded Content-Length decoder. Returned frames remain owned by
/// the caller; the decoder never buffers more than one frame plus its header.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    header_limit: usize = 8192,
    body_limit: usize = 8 * 1024 * 1024,
    body_len: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    /// Distinguish a clean stream boundary from a truncated header or body.
    pub fn finish(self: *const Decoder) !void {
        if (self.body_len != null or self.buffer.items.len != 0) return error.TruncatedFrame;
    }

    /// Feed arbitrary fragments. The callback is called synchronously and must
    /// copy the body if it needs to retain it. Errors make the stream unusable.
    pub fn feed(self: *Decoder, bytes: []const u8, context: anytype, comptime onFrame: anytype) !void {
        for (bytes) |byte| {
            try self.buffer.append(self.allocator, byte);
            if (self.body_len) |len| {
                if (self.buffer.items.len == len) {
                    try onFrame(context, self.buffer.items);
                    self.buffer.clearRetainingCapacity();
                    self.body_len = null;
                }
            } else {
                if (self.buffer.items.len > self.header_limit) return error.HeaderTooLarge;
                if (std.mem.endsWith(u8, self.buffer.items, "\r\n\r\n")) {
                    const len = try parseHeader(self.buffer.items[0 .. self.buffer.items.len - 4]);
                    if (len > self.body_limit) return error.BodyTooLarge;
                    self.buffer.clearRetainingCapacity();
                    self.body_len = len;
                    if (len == 0) {
                        try onFrame(context, self.buffer.items);
                        self.body_len = null;
                    }
                }
            }
        }
    }
};

fn parseHeader(header: []const u8) !usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    var found: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (found != null or value.len == 0) return error.InvalidHeader;
            for (value) |c| if (!std.ascii.isDigit(c)) {
                return error.InvalidHeader;
            };
            found = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHeader;
        }
    }
    return found orelse error.MissingContentLength;
}

pub fn encode(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

test "fragmented frames and bounds" {
    const Context = struct {
        count: usize = 0,
        fn frame(ctx: *@This(), body: []const u8) !void {
            try std.testing.expectEqualStrings("{}", body);
            ctx.count += 1;
        }
    };
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();
    var ctx: Context = .{};
    const wire = "Content-Length: 2\r\n\r\n{}Content-Length: 2\r\n\r\n{}";
    for (wire) |*byte| try d.feed(byte[0..1], &ctx, Context.frame);
    try std.testing.expectEqual(@as(usize, 2), ctx.count);
    try std.testing.expectError(error.InvalidHeader, d.feed("Content-Length: 2\r\nContent-Length: 2\r\n\r\n", &ctx, Context.frame));
}

test "end of stream rejects partial header and body" {
    const Context = struct {
        fn frame(_: void, _: []const u8) !void {}
    };
    var d = Decoder.init(std.testing.allocator);
    defer d.deinit();
    try d.finish();
    try d.feed("Content-Len", {}, Context.frame);
    try std.testing.expectError(error.TruncatedFrame, d.finish());
    d.deinit();
    d = Decoder.init(std.testing.allocator);
    try d.feed("Content-Length: 5\r\n\r\n{}", {}, Context.frame);
    try std.testing.expectError(error.TruncatedFrame, d.finish());
}
