//! Static initialize capabilities relevant to document synchronization.
const std = @import("std");
const position = @import("position.zig");

pub const SyncKind = enum { none, full, incremental };
pub const Save = enum { none, without_text, with_text };
pub const Capabilities = struct {
    encoding: position.Encoding = .utf16,
    open_close: bool = false,
    change: SyncKind = .none,
    save: Save = .none,
};

/// Parse the result of a successful initialize response. Dynamic registration
/// is not represented; unknown position encodings and malformed fields fail.
pub fn parse(result: std.json.Value) !Capabilities {
    if (result != .object) return error.InvalidCapabilities;
    const caps = result.object.get("capabilities") orelse return error.InvalidCapabilities;
    if (caps != .object) return error.InvalidCapabilities;
    var out: Capabilities = .{};
    if (caps.object.get("positionEncoding")) |enc| {
        if (enc != .string) return error.InvalidCapabilities;
        out.encoding = if (std.mem.eql(u8, enc.string, "utf-16")) .utf16 else if (std.mem.eql(u8, enc.string, "utf-8")) .utf8 else return error.UnsupportedEncoding;
    }
    if (caps.object.get("textDocumentSync")) |sync| switch (sync) {
        .integer => out.change = try syncKind(sync),
        .object => |obj| {
            if (obj.get("openClose")) |open| {
                if (open != .bool) return error.InvalidCapabilities;
                out.open_close = open.bool;
            }
            if (obj.get("change")) |change| out.change = try syncKind(change);
            if (obj.get("save")) |save| switch (save) {
                .bool => |enabled| out.save = if (enabled) .without_text else .none,
                .object => |options| {
                    out.save = .without_text;
                    if (options.get("includeText")) |include| {
                        if (include != .bool) return error.InvalidCapabilities;
                        if (include.bool) out.save = .with_text;
                    }
                },
                else => return error.InvalidCapabilities,
            };
        },
        else => return error.InvalidCapabilities,
    };
    return out;
}

fn syncKind(value: std.json.Value) !SyncKind {
    if (value != .integer) return error.InvalidCapabilities;
    return switch (value.integer) {
        0 => .none,
        1 => .full,
        2 => .incremental,
        else => error.InvalidCapabilities,
    };
}

test "initialize capabilities defaults and sync forms" {
    const a = std.testing.allocator;
    var minimal = try std.json.parseFromSlice(std.json.Value, a, "{\"capabilities\":{}}", .{});
    defer minimal.deinit();
    try std.testing.expectEqual(Capabilities{}, try parse(minimal.value));
    var full = try std.json.parseFromSlice(std.json.Value, a, "{\"capabilities\":{\"positionEncoding\":\"utf-8\",\"textDocumentSync\":{\"openClose\":true,\"change\":2,\"save\":{\"includeText\":true}}}}", .{});
    defer full.deinit();
    try std.testing.expectEqual(Capabilities{ .encoding = .utf8, .open_close = true, .change = .incremental, .save = .with_text }, try parse(full.value));
    var numeric = try std.json.parseFromSlice(std.json.Value, a, "{\"capabilities\":{\"textDocumentSync\":1}}", .{});
    defer numeric.deinit();
    try std.testing.expectEqual(SyncKind.full, (try parse(numeric.value)).change);
    var bad = try std.json.parseFromSlice(std.json.Value, a, "{\"capabilities\":{\"positionEncoding\":\"utf-32\"}}", .{});
    defer bad.deinit();
    try std.testing.expectError(error.UnsupportedEncoding, parse(bad.value));
}
