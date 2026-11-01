const std = @import("std");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
pub const position = @import("position.zig");

/// A single-owner session. Callers serialize access and run blocking transport
/// reads on their own Io task; callbacks may not retain the body slice.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    decoder: framing.Decoder,
    next_id: u32 = 1,
    pending: std.AutoHashMap(u32, void),
    max_pending: usize = 256,

    pub fn spawn(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Session {
        if (argv.len == 0) return error.EmptyCommand;
        const child = try std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
        return .{ .allocator = allocator, .io = io, .child = child, .decoder = framing.Decoder.init(allocator), .pending = std.AutoHashMap(u32, void).init(allocator) };
    }
    /// Forcefully terminates and reaps the process. Stop any read task first.
    pub fn deinit(self: *Session) void {
        self.child.kill(self.io);
        self.pending.deinit();
        self.decoder.deinit();
        self.* = undefined;
    }
    fn send(self: *Session, message: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.allocator, message, .{});
        defer self.allocator.free(body);
        try self.sendBody(body);
    }
    fn sendBody(self: *Session, body: []const u8) !void {
        if (body.len > self.decoder.body_limit) return error.BodyTooLarge;
        const wire = try framing.encode(self.allocator, body);
        defer self.allocator.free(wire);
        try self.child.stdin.?.writeStreamingAll(self.io, wire);
    }
    /// Send a response to a decoded server request after read() returns. The
    /// message must remain alive through this call; its ID and params are owned
    /// by its parsed arena. This does not implement an asynchronous dispatcher.
    pub fn replyToServer(self: *Session, message: *const protocol.Message) !void {
        const server_request = switch (message.kind) {
            .server_request => |server_request| server_request,
            else => return error.NotServerRequest,
        };
        const params = message.parsed.value.object.get("params");
        const body = protocol.serverReply(self.allocator, server_request.id, server_request.method, params) catch |err| switch (err) {
            error.InvalidParams => try std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = server_request.id, .@"error" = .{ .code = @as(i32, -32602), .message = "Invalid params" } }, .{}),
            else => return err,
        };
        defer self.allocator.free(body);
        try self.sendBody(body);
    }
    pub fn request(self: *Session, method: []const u8, params: anytype) !u32 {
        if (self.pending.count() >= self.max_pending) return error.TooManyPending;
        const id = self.next_id;
        self.next_id = std.math.add(u32, id, 1) catch return error.IdExhausted;
        try self.pending.put(id, {});
        errdefer _ = self.pending.remove(id);
        try self.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        return id;
    }
    pub fn notify(self: *Session, method: []const u8, params: anytype) !void {
        try self.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }
    pub fn initialize(self: *Session, root_uri: ?[]const u8) !u32 {
        return self.request("initialize", .{ .processId = @as(?u32, null), .rootUri = root_uri, .capabilities = .{ .general = .{ .positionEncodings = [_][]const u8{ "utf-16", "utf-8" } } } });
    }
    pub fn initialized(self: *Session) !void {
        try self.notify("initialized", struct {}{});
    }
    pub fn shutdown(self: *Session) !u32 {
        return self.request("shutdown", @as(?u8, null));
    }
    pub fn exit(self: *Session) !void {
        try self.notify("exit", @as(?u8, null));
    }
    pub fn didOpen(self: *Session, uri: []const u8, language: []const u8, version: i32, text: []const u8) !void {
        try self.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = language, .version = version, .text = text } });
    }
    pub fn didChange(self: *Session, uri: []const u8, version: i32, text: []const u8) !void {
        try self.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = [_]@TypeOf(.{ .text = text }){.{ .text = text }} });
    }
    /// Range is expressed in the negotiated encoding and the previous document version.
    pub fn didChangeRange(self: *Session, uri: []const u8, version: i32, range: position.Range, text: []const u8) !void {
        const change = .{ .range = range, .text = text };
        try self.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = [_]@TypeOf(change){change} });
    }
    pub fn didSave(self: *Session, uri: []const u8) !void {
        try self.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
    }
    pub fn didSaveWithText(self: *Session, uri: []const u8, text: []const u8) !void {
        try self.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri }, .text = text });
    }
    pub fn didClose(self: *Session, uri: []const u8) !void {
        try self.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
    }
    pub fn completion(self: *Session, uri: []const u8, pos: position.Position) !u32 {
        return self.positionRequest("textDocument/completion", uri, pos);
    }
    pub fn hover(self: *Session, uri: []const u8, pos: position.Position) !u32 {
        return self.positionRequest("textDocument/hover", uri, pos);
    }
    pub fn definition(self: *Session, uri: []const u8, pos: position.Position) !u32 {
        return self.positionRequest("textDocument/definition", uri, pos);
    }
    fn positionRequest(self: *Session, method: []const u8, uri: []const u8, pos: position.Position) !u32 {
        return self.request(method, .{ .textDocument = .{ .uri = uri }, .position = pos });
    }
    pub fn formatting(self: *Session, uri: []const u8, tab_size: u32, insert_spaces: bool) !u32 {
        return self.request("textDocument/formatting", .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = tab_size, .insertSpaces = insert_spaces } });
    }
    /// Read one chunk. Call on a background task, never the UI thread.
    pub fn read(self: *Session, context: anytype, comptime onFrame: anytype) !void {
        var buf: [4096]u8 = undefined;
        const n = try self.child.stdout.?.readStreaming(self.io, &.{&buf});
        if (n == 0) {
            try self.decoder.finish();
            return error.EndOfStream;
        }
        try self.decoder.feed(buf[0..n], context, onFrame);
    }
    /// Mark a validated integer response ID complete; false means unknown ID.
    pub fn complete(self: *Session, id: u32) bool {
        return self.pending.remove(id);
    }
};

test "server reply is framed and sent through session transport" {
    const Context = struct {
        received: bool = false,
        fn frame(ctx: *@This(), body: []const u8) !void {
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("server-id", parsed.value.object.get("id").?.string);
            try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("result").?.array.items.len);
            ctx.received = true;
        }
    };
    var session = try Session.spawn(std.testing.allocator, std.testing.io, &.{"cat"});
    defer session.deinit();
    var message = try protocol.decode(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"server-id\",\"method\":\"workspace/configuration\",\"params\":{\"items\":[{},{}]}}");
    defer message.deinit();
    try session.replyToServer(&message);
    var ctx: Context = .{};
    while (!ctx.received) try session.read(&ctx, Context.frame);
}

test "incremental changes carry the old range and replacement" {
    const Context = struct {
        received: bool = false,
        fn frame(ctx: *@This(), body: []const u8) !void {
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
            defer parsed.deinit();
            const params = parsed.value.object.get("params").?.object;
            try std.testing.expectEqual(@as(i64, 2), params.get("textDocument").?.object.get("version").?.integer);
            const change = params.get("contentChanges").?.array.items[0].object;
            try std.testing.expectEqualStrings("é", change.get("text").?.string);
            try std.testing.expectEqual(@as(i64, 3), change.get("range").?.object.get("end").?.object.get("character").?.integer);
            ctx.received = true;
        }
    };
    var session = try Session.spawn(std.testing.allocator, std.testing.io, &.{"cat"});
    defer session.deinit();
    try session.didChangeRange("file:///x", 2, .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 0, .character = 3 } }, "é");
    var ctx: Context = .{};
    while (!ctx.received) try session.read(&ctx, Context.frame);
}
