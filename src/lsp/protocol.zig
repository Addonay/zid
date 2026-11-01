const std = @import("std");
const position = @import("position.zig");

/// A snapshot owns all of its strings and remains valid until deinit.
pub const Diagnostic = struct {
    range: position.Range,
    message: []const u8,
    severity: ?u32 = null,
    source: ?[]const u8 = null,
    code: ?std.json.Value = null,
};
pub const Diagnostics = struct {
    uri: []const u8,
    version: ?i32 = null,
    diagnostics: []const Diagnostic,
};

/// Parsed frames own their backing arena, independent of the framing buffer.
pub const Message = struct {
    parsed: std.json.Parsed(std.json.Value),
    kind: Kind,
    pub const Kind = union(enum) {
        response: struct { id: u32, is_error: bool },
        diagnostics: Diagnostics,
        server_request: struct { id: std.json.Value, method: []const u8 },
        notification: []const u8,
    };
    pub fn deinit(self: *Message) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn decode(allocator: std.mem.Allocator, body: []const u8) !Message {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMessage;
    const object = parsed.value.object;
    const version = object.get("jsonrpc") orelse return error.InvalidMessage;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.InvalidMessage;
    const method = object.get("method");
    const id = object.get("id");
    if (method) |m| {
        if (m != .string) return error.InvalidMessage;
        if (id) |request_id| {
            if (request_id != .integer and request_id != .string) return error.InvalidMessage;
            return .{ .parsed = parsed, .kind = .{ .server_request = .{ .id = request_id, .method = m.string } } };
        }
        if (std.mem.eql(u8, m.string, "textDocument/publishDiagnostics")) {
            const params = object.get("params") orelse return error.InvalidMessage;
            const snapshot = try std.json.parseFromValueLeaky(Diagnostics, parsed.arena.allocator(), params, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            return .{ .parsed = parsed, .kind = .{ .diagnostics = snapshot } };
        }
        return .{ .parsed = parsed, .kind = .{ .notification = m.string } };
    }
    const response_id = id orelse return error.InvalidMessage;
    if (response_id != .integer or response_id.integer < 0 or response_id.integer > std.math.maxInt(u32)) return error.InvalidMessage;
    const result = object.contains("result");
    const has_error = object.contains("error");
    if (result == has_error) return error.InvalidMessage;
    return .{ .parsed = parsed, .kind = .{ .response = .{ .id = @intCast(response_id.integer), .is_error = has_error } } };
}

/// Construct a safe response to a server request. Configuration is deliberately
/// unset, and the workspace list empty until the client has a workspace model.
pub fn serverReply(allocator: std.mem.Allocator, id: std.json.Value, method: []const u8, params: ?std.json.Value) ![]u8 {
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        const p = params orelse return error.InvalidParams;
        if (p != .object) return error.InvalidParams;
        const items = p.object.get("items") orelse return error.InvalidParams;
        if (items != .array or items.array.items.len > 1024) return error.InvalidParams;
        const values = try allocator.alloc(?u8, items.array.items.len);
        defer allocator.free(values);
        @memset(values, null);
        return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = values }, .{});
    }
    if (std.mem.eql(u8, method, "workspace/workspaceFolders")) {
        return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = [_]u8{} }, .{});
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32601), .message = "Method not found" } }, .{});
}

test "owned diagnostics and response validation" {
    const a = std.testing.allocator;
    var message = try decode(a, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a\",\"diagnostics\":[{\"range\":{\"start\":{\"line\":0,\"character\":1},\"end\":{\"line\":0,\"character\":2}},\"message\":\"bad\"}]}}");
    defer message.deinit();
    try std.testing.expectEqualStrings("bad", message.kind.diagnostics.diagnostics[0].message);
    var response = try decode(a, "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":null}");
    defer response.deinit();
    try std.testing.expectEqual(@as(u32, 42), response.kind.response.id);
    try std.testing.expectError(error.InvalidMessage, decode(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null,\"error\":{}}"));
}

test "server reply preserves string id" {
    const a = std.testing.allocator;
    const reply = try serverReply(a, .{ .string = "abc" }, "unknown", null);
    defer a.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, reply, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc", parsed.value.object.get("id").?.string);
    try std.testing.expectEqual(@as(i64, -32601), parsed.value.object.get("error").?.object.get("code").?.integer);
}

/// Tracks only client-generated integer IDs. A response claims an ID exactly
/// once; an unknown or duplicate response must not be delivered as a result.
pub const Pending = struct {
    ids: std.AutoHashMap(u32, void),
    limit: usize,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, limit: usize) Pending {
        return .{ .ids = std.AutoHashMap(u32, void).init(allocator), .limit = limit };
    }
    pub fn deinit(self: *Pending) void {
        self.ids.deinit();
        self.* = undefined;
    }
    pub fn reserve(self: *Pending) !u32 {
        if (self.ids.count() >= self.limit) return error.TooManyPending;
        const id = self.next_id;
        const next = std.math.add(u32, id, 1) catch return error.IdExhausted;
        try self.ids.put(id, {});
        self.next_id = next;
        return id;
    }
    pub fn finish(self: *Pending, id: u32) bool {
        return self.ids.remove(id);
    }
};

test "responses claim bounded pending IDs in any order" {
    var pending = Pending.init(std.testing.allocator, 2);
    defer pending.deinit();
    const a = try pending.reserve();
    const b = try pending.reserve();
    try std.testing.expectError(error.TooManyPending, pending.reserve());
    try std.testing.expect(pending.finish(b));
    try std.testing.expect(pending.finish(a));
    try std.testing.expect(!pending.finish(b));
}

test "workspace configuration answers one null per item" {
    const a = std.testing.allocator;
    var params = try std.json.parseFromSlice(std.json.Value, a, "{\"items\":[{},{}]}", .{});
    defer params.deinit();
    const reply = try serverReply(a, .{ .integer = 7 }, "workspace/configuration", params.value);
    defer a.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, reply, .{});
    defer parsed.deinit();
    const values = parsed.value.object.get("result").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expect(values[0] == .null and values[1] == .null);
}
