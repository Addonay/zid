//! Single-owner, nonblocking protocol dispatcher over the background transport.
//! The caller polls, owns returned messages, and must deinitialize them. This
//! layer does not access editor state or assume a UI thread.
const std = @import("std");
const transport = @import("worker.zig");
const protocol = @import("protocol.zig");
const caps = @import("capabilities.zig");

pub const State = enum { starting, initializing, initializing_flush, ready, failed };

pub const Client = struct {
    allocator: std.mem.Allocator,
    worker: *transport.Worker,
    pending: protocol.Pending,
    state: State = .starting,
    capabilities: ?caps.Capabilities = null,
    initialize_id: ?u32 = null,
    deferred: ?[]u8 = null,
    failure: ?anyerror = null,

    /// Allocator and Io must be thread-safe and live through destroy. The
    /// client itself is single-owner: do not race its methods or destruction.
    pub fn create(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, limits: transport.Limits) !Client {
        return .{ .allocator = a, .worker = try transport.Worker.create(a, io, argv, limits), .pending = protocol.Pending.init(a, limits.max_queue_messages) };
    }

    pub fn destroy(self: *Client) void {
        self.worker.destroy();
        self.pending.deinit();
        if (self.deferred) |body| self.allocator.free(body);
        self.* = undefined;
    }

    fn sendValue(self: *Client, message: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(self.allocator, message, .{});
        defer self.allocator.free(body);
        try self.worker.send(body);
    }

    fn sendRequest(self: *Client, method: []const u8, params: anytype) !u32 {
        const id = try self.pending.reserve();
        errdefer _ = self.pending.finish(id);
        try self.sendValue(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        return id;
    }

    pub fn initialize(self: *Client, root_uri: ?[]const u8) !void {
        if (self.state != .starting) return error.InvalidState;
        self.initialize_id = try self.sendRequest("initialize", .{ .processId = @as(?u32, null), .rootUri = root_uri, .capabilities = .{ .general = .{ .positionEncodings = [_][]const u8{ "utf-16", "utf-8" } }, .textDocument = .{ .publishDiagnostics = .{ .versionSupport = true } } } });
        self.state = .initializing;
    }

    /// Queueing is nonblocking; QueueFull means the caller may retry. A
    /// returned ID remains pending until its validated response is polled.
    pub fn request(self: *Client, method: []const u8, params: anytype) !u32 {
        if (self.state != .ready) return error.InvalidState;
        if (self.deferred != null) return error.QueueFull;
        return self.sendRequest(method, params);
    }

    pub fn notify(self: *Client, method: []const u8, params: anytype) !void {
        if (self.state != .ready) return error.InvalidState;
        if (self.deferred != null) return error.QueueFull;
        try self.sendValue(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    fn fail(self: *Client, err: anyerror) anyerror {
        self.failure = err;
        self.state = .failed;
        return err;
    }

    /// Retries a mandatory reply if the outbound queue was full. Later messages
    /// are not consumed until it is accepted, so replies are never dropped.
    fn flush(self: *Client) !bool {
        const body = self.deferred orelse return true;
        self.worker.send(body) catch |err| switch (err) {
            error.QueueFull => return false,
            else => return self.fail(err),
        };
        self.allocator.free(body);
        self.deferred = null;
        if (self.state == .initializing_flush) self.state = .ready;
        return true;
    }

    /// Returns at most one owned notification, diagnostic or response per call.
    /// Server requests are answered internally. Null can mean no data, a handled
    /// request, or a reply waiting for queue space; poll again. Errors are sticky.
    pub fn poll(self: *Client) !?protocol.Message {
        if (self.failure) |err| return err;
        if (!try self.flush()) return null;
        const body = self.worker.take() orelse {
            if (self.worker.failureStatus()) |err| return self.fail(err);
            return null;
        };
        defer self.allocator.free(body);
        var message = protocol.decode(self.allocator, body) catch |err| return self.fail(err);
        errdefer message.deinit();
        switch (message.kind) {
            .response => |response| {
                if (!self.pending.finish(response.id)) return self.fail(error.UnknownResponse);
                if (self.initialize_id != null and response.id == self.initialize_id.?) {
                    if (self.state != .initializing) return self.fail(error.InvalidState);
                    if (response.is_error) return self.fail(error.InitializeFailed);
                    self.capabilities = caps.parse(message.parsed.value.object.get("result").?) catch |err| return self.fail(err);
                    self.deferred = std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .method = "initialized", .params = struct {}{} }, .{}) catch |err| return self.fail(err);
                    self.state = .initializing_flush;
                    _ = try self.flush();
                }
            },
            .server_request => |req| {
                const params = message.parsed.value.object.get("params");
                self.deferred = protocol.serverReply(self.allocator, req.id, req.method, params) catch |err| switch (err) {
                    error.InvalidParams => std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = req.id, .@"error" = .{ .code = @as(i32, -32602), .message = "Invalid params" } }, .{}) catch |e| return self.fail(e),
                    else => return self.fail(err),
                };
                _ = try self.flush();
                message.deinit();
                return null;
            },
            else => {},
        }
        return message;
    }
};

fn waitForInput(client: *Client) !void {
    const w = client.worker;
    w.mutex.lockUncancelable(w.io);
    defer w.mutex.unlock(w.io);
    while (w.incoming.items.len == 0 and w.failure == null) {
        try w.changed.waitTimeout(w.io, &w.mutex, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    }
}

test "initialize, answer server request and correlate a feature response" {
    const script =
        \\import json,sys
        \\def read():
        \\ h={}
        \\ while True:
        \\  s=sys.stdin.buffer.readline()
        \\  if s==b'\r\n': break
        \\  k,v=s.decode().split(':',1); h[k.lower()]=v.strip()
        \\ return json.loads(sys.stdin.buffer.read(int(h['content-length'])))
        \\def send(m):
        \\ b=json.dumps(m).encode(); sys.stdout.buffer.write(b'Content-Length: '+str(len(b)).encode()+b'\r\n\r\n'+b); sys.stdout.buffer.flush()
        \\init=read()
        \\assert init['params']['capabilities']['textDocument']['publishDiagnostics']['versionSupport'] is True
        \\send({'jsonrpc':'2.0','id':init['id'],'result':{'capabilities':{'positionEncoding':'utf-8','textDocumentSync':2}}})
        \\initialized=read(); assert initialized['method']=='initialized' and initialized['params']=={}
        \\send({'jsonrpc':'2.0','id':'cfg','method':'workspace/configuration','params':{'items':[{}]}})
        \\reply=read(); assert reply['id']=='cfg' and reply['result']==[None]
        \\send({'jsonrpc':'2.0','method':'window/logMessage','params':{'type':3,'message':'ok'}})
        \\req=read(); send({'jsonrpc':'2.0','id':req['id'],'result':{'contents':'hover'}})
        \\sys.stdin.buffer.read()
    ;
    const a = std.testing.allocator;
    var client = try Client.create(a, std.testing.io, &.{ "python3", "-u", "-c", script }, .{});
    defer client.destroy();
    try client.initialize("file:///tmp");
    try waitForInput(&client);
    var init = (try client.poll()).?;
    defer init.deinit();
    try std.testing.expectEqual(State.ready, client.state);
    try std.testing.expectEqual(caps.SyncKind.incremental, client.capabilities.?.change);
    try waitForInput(&client);
    try std.testing.expect((try client.poll()) == null); // answered configuration
    try waitForInput(&client);
    var notification = (try client.poll()).?;
    defer notification.deinit();
    try std.testing.expectEqualStrings("window/logMessage", notification.kind.notification);
    const id = try client.request("textDocument/hover", .{});
    try waitForInput(&client);
    var response = (try client.poll()).?;
    defer response.deinit();
    try std.testing.expectEqual(id, response.kind.response.id);
    try std.testing.expectEqualStrings("hover", response.parsed.value.object.get("result").?.object.get("contents").?.string);
}

test "unknown response becomes sticky failure" {
    const script =
        \\import sys
        \\b=b'{"jsonrpc":"2.0","id":42,"result":null}'
        \\sys.stdout.buffer.write(b'Content-Length: '+str(len(b)).encode()+b'\r\n\r\n'+b); sys.stdout.buffer.flush()
        \\sys.stdin.buffer.read()
    ;
    var client = try Client.create(std.testing.allocator, std.testing.io, &.{ "python3", "-u", "-c", script }, .{});
    defer client.destroy();
    try waitForInput(&client);
    try std.testing.expectError(error.UnknownResponse, client.poll());
    try std.testing.expectError(error.UnknownResponse, client.poll());
}
