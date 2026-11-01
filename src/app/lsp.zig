//! Poll-driven ZLS document synchronization. No SDL or rendering dependencies.
const std = @import("std");
const zid = @import("zid");
const Client = zid.lsp.Client;
const Message = zid.lsp.protocol.Message;
const Diagnostics = zid.lsp.protocol.Diagnostics;

/// Bounds per-document snapshots and LSP traffic on the UI thread. Larger files
/// remain editable/viewable but are deliberately not sent to the server.
pub const max_document_bytes = 1024 * 1024;
pub const max_documents = 32;
pub const max_hover_bytes = 8192;
const HoverRequest = struct { id: u32, instance_id: u64, revision: u64, cursor: usize };
const DefinitionRequest = HoverRequest;
pub const Definition = struct {
    path: []u8,
    position: zid.lsp.position.Position,
    encoding: zid.lsp.position.Encoding,

    pub fn deinit(self: *Definition, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};
const Tracked = struct {
    path: []u8,
    uri: []u8,
    text: []u8,
    revision: u64,
    saved_revision: u64,
    version: i32,
    instance_id: u64,
    diagnostics: ?Message = null,

    fn clearDiagnostics(self: *Tracked) void {
        if (self.diagnostics) |*message| message.deinit();
        self.diagnostics = null;
    }
    fn deinit(self: *Tracked, a: std.mem.Allocator) void {
        self.clearDiagnostics();
        a.free(self.path);
        a.free(self.uri);
        a.free(self.text);
    }
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    client: Client,
    documents: std.ArrayList(Tracked) = .empty,
    next_version: i32 = 1,
    /// Updated on every poll. Documents can be skipped for size, unsupported
    /// server sync capabilities, or because max_documents has been reached.
    skipped: usize = 0,
    generation: u64 = 0,
    hover_pending: bool = false,
    hover_request: ?HoverRequest = null,
    hover_text: ?[]u8 = null,
    hover_target: ?HoverRequest = null,
    definition_pending: bool = false,
    definition_request: ?DefinitionRequest = null,
    definition_target: ?DefinitionRequest = null,
    definition: ?Definition = null,

    /// Root must identify the workspace root. argv is direct, without a shell.
    pub fn start(a: std.mem.Allocator, io: std.Io, root: []const u8, argv: []const []const u8) !Controller {
        const absolute = try std.fs.path.resolve(a, &.{root});
        defer a.free(absolute);
        const uri = try pathUri(a, absolute);
        defer a.free(uri);
        var client = try Client.create(a, io, argv, .{});
        errdefer client.destroy();
        try client.initialize(uri);
        return .{ .allocator = a, .client = client };
    }

    pub fn deinit(self: *Controller) void {
        self.clearHover();
        self.clearDefinition();
        self.client.destroy();
        for (self.documents.items) |*doc| doc.deinit(self.allocator);
        self.documents.deinit(self.allocator);
        self.* = undefined;
    }

    /// Invalidates an in-flight hover as well as any displayed text. A later
    /// response is still consumed by Client but cannot restore the popup.
    pub fn clearHover(self: *Controller) void {
        const changed = self.hover_pending or self.hover_text != null;
        if (self.hover_text) |text| self.allocator.free(text);
        self.hover_text = null;
        self.hover_request = null;
        self.hover_target = null;
        self.hover_pending = false;
        if (changed) self.generation +%= 1;
    }

    /// Caller should poll first to reconcile edits; this deliberately rejects
    /// documents not yet synchronized with the server.
    pub fn requestHover(self: *Controller, doc: *const zid.Document) !void {
        if (self.client.state != .ready) return error.ServerNotReady;
        const path = doc.path orelse return error.DocumentNotSynced;
        var found: ?*const Tracked = null;
        for (self.documents.items) |*item| {
            if (item.instance_id == doc.instance_id and item.revision == doc.revision and std.mem.eql(u8, item.path, path)) {
                found = item;
                break;
            }
        }
        const tracked = found orelse return error.DocumentNotSynced;
        const pos = try zid.lsp.position.fromOffset(tracked.text, doc.cursor, self.client.capabilities.?.encoding);
        const id = try self.client.request("textDocument/hover", .{ .textDocument = .{ .uri = tracked.uri }, .position = pos });
        self.clearHover();
        self.hover_request = .{ .id = id, .instance_id = doc.instance_id, .revision = doc.revision, .cursor = doc.cursor };
        self.hover_pending = true;
        self.generation +%= 1;
    }

    /// Returned text is owned by the controller, and is invalidated by
    /// clearHover, a later poll, or deinit. Mismatched editor state is hidden.
    pub fn hoverFor(self: *const Controller, doc: *const zid.Document) ?[]const u8 {
        const target = self.hover_target orelse return null;
        if (!sameHoverTarget(target, doc)) return null;
        return self.hover_text;
    }

    /// Invalidates pending and completed navigation. Late replies are consumed
    /// by Client but never applied to a different document or cursor.
    pub fn clearDefinition(self: *Controller) void {
        const changed = self.definition_pending or self.definition != null;
        if (self.definition) |*value| value.deinit(self.allocator);
        self.definition = null;
        self.definition_request = null;
        self.definition_target = null;
        self.definition_pending = false;
        if (changed) self.generation +%= 1;
    }

    /// Request at a synchronized document's current cursor. QueueFull may be retried.
    pub fn requestDefinition(self: *Controller, doc: *const zid.Document) !void {
        if (self.client.state != .ready) return error.ServerNotReady;
        const path = doc.path orelse return error.DocumentNotSynced;
        var tracked: ?*const Tracked = null;
        for (self.documents.items) |*item| {
            if (item.instance_id == doc.instance_id and item.revision == doc.revision and std.mem.eql(u8, item.path, path)) {
                tracked = item;
                break;
            }
        }
        const item = tracked orelse return error.DocumentNotSynced;
        const pos = try zid.lsp.position.fromOffset(item.text, doc.cursor, self.client.capabilities.?.encoding);
        const id = try self.client.request("textDocument/definition", .{ .textDocument = .{ .uri = item.uri }, .position = pos });
        self.clearDefinition();
        self.definition_request = .{ .id = id, .instance_id = doc.instance_id, .revision = doc.revision, .cursor = doc.cursor };
        self.definition_pending = true;
        self.generation +%= 1;
    }

    /// Transfers ownership of a completed target to the caller. A mismatched
    /// document invalidates the target. Free the result with Definition.deinit.
    pub fn takeDefinition(self: *Controller, doc: *const zid.Document) ?Definition {
        const source = self.definition_target orelse return null;
        if (!sameHoverTarget(source, doc)) {
            self.clearDefinition();
            return null;
        }
        const result = self.definition;
        self.definition = null;
        self.definition_target = null;
        return result;
    }

    /// Borrowed until next poll or deinit. Unversioned diagnostics are best
    /// effort: a delayed server result may refer to an earlier revision.
    pub fn diagnosticsFor(self: *const Controller, path: []const u8, instance_id: u64, revision: u64) ?Diagnostics {
        for (self.documents.items) |*doc| {
            if (!std.mem.eql(u8, path, doc.path) or instance_id != doc.instance_id or revision != doc.revision) continue;
            if (doc.diagnostics) |message| return message.kind.diagnostics;
        }
        return null;
    }

    /// Processes a bounded number of incoming messages and reconciles open Zig
    /// documents. QueueFull is retried next poll; other errors are returned.
    /// A workspace root change requires destroying and starting a new controller.
    pub fn poll(self: *Controller, workspace: *const zid.Workspace) !void {
        if (self.hover_request orelse self.hover_target) |target| {
            if (workspace.active >= workspace.documents.items.len or !sameHoverTarget(target, &workspace.documents.items[workspace.active])) self.clearHover();
        }
        if (self.definition_request orelse self.definition_target) |target| {
            if (workspace.active >= workspace.documents.items.len or !sameHoverTarget(target, &workspace.documents.items[workspace.active])) self.clearDefinition();
        }
        for (0..32) |_| {
            if (try self.client.poll()) |m| {
                var msg = m;
                switch (msg.kind) {
                    .response => |response| {
                        defer msg.deinit();
                        if (self.hover_request) |request| {
                            if (request.id == response.id) {
                                self.hover_request = null;
                                self.hover_pending = false;
                                self.generation +%= 1;
                                if (!response.is_error) {
                                    const result = msg.parsed.value.object.get("result") orelse .null;
                                    self.hover_text = try hoverText(self.allocator, result);
                                    if (self.hover_text != null) self.hover_target = request;
                                }
                            }
                        }
                        if (self.definition_request) |request| {
                            if (request.id == response.id) {
                                self.definition_request = null;
                                self.definition_pending = false;
                                self.generation +%= 1;
                                if (!response.is_error) {
                                    const result = msg.parsed.value.object.get("result") orelse .null;
                                    self.definition = try definitionResult(self.allocator, result, self.client.capabilities.?.encoding);
                                    if (self.definition != null) self.definition_target = request;
                                }
                            }
                        }
                    },
                    .diagnostics => |d| {
                        var accepted = false;
                        for (self.documents.items) |*doc| {
                            if (std.mem.eql(u8, d.uri, doc.uri) and (d.version == null or d.version.? == doc.version)) {
                                doc.clearDiagnostics();
                                doc.diagnostics = msg;
                                self.generation +%= 1;
                                accepted = true;
                                break;
                            }
                        }
                        if (!accepted) msg.deinit();
                    },
                    else => msg.deinit(),
                }
            }
        }
        if (self.client.state != .ready) return;
        const caps = self.client.capabilities.?;
        self.skipped = 0;

        // Close deleted, renamed, oversized, or otherwise ineligible documents.
        var i: usize = 0;
        while (i < self.documents.items.len) {
            const tracked = &self.documents.items[i];
            var keep = false;
            for (workspace.documents.items) |*doc| {
                if (eligible(doc) and doc.instance_id == tracked.instance_id and std.mem.eql(u8, doc.path.?, tracked.path)) {
                    keep = true;
                    break;
                }
            }
            if (keep) {
                i += 1;
                continue;
            }
            if (caps.open_close) self.client.notify("textDocument/didClose", .{ .textDocument = .{ .uri = tracked.uri } }) catch |err| switch (err) {
                error.QueueFull => return,
                else => return err,
            };
            var removed = self.documents.orderedRemove(i);
            if (removed.diagnostics != null) self.generation +%= 1;
            removed.deinit(self.allocator);
        }

        for (workspace.documents.items) |*doc| {
            if (!isZig(doc)) continue;
            if (!eligible(doc) or !caps.open_close or caps.change == .none) {
                self.skipped += 1;
                continue;
            }
            var tracked: ?*Tracked = null;
            for (self.documents.items) |*existing| if (std.mem.eql(u8, existing.path, doc.path.?)) {
                tracked = existing;
                break;
            };
            if (tracked) |existing| {
                if (existing.revision != doc.revision) {
                    if (existing.diagnostics != null) self.generation +%= 1;
                    existing.clearDiagnostics();
                    const text = try doc.buffer.toOwnedSlice(self.allocator);
                    errdefer self.allocator.free(text);
                    const version = self.next_version;
                    const next_version = std.math.add(i32, version, 1) catch return error.VersionExhausted;
                    if (caps.change == .incremental) {
                        const end = try zid.lsp.position.fromOffset(existing.text, existing.text.len, caps.encoding);
                        const change = .{ .range = zid.lsp.position.Range{ .start = .{ .line = 0, .character = 0 }, .end = end }, .text = text };
                        self.client.notify("textDocument/didChange", .{ .textDocument = .{ .uri = existing.uri, .version = version }, .contentChanges = [_]@TypeOf(change){change} }) catch |err| switch (err) {
                            error.QueueFull => {
                                self.allocator.free(text);
                                continue;
                            },
                            else => return err,
                        };
                    } else {
                        const change = .{ .text = text };
                        self.client.notify("textDocument/didChange", .{ .textDocument = .{ .uri = existing.uri, .version = version }, .contentChanges = [_]@TypeOf(change){change} }) catch |err| switch (err) {
                            error.QueueFull => {
                                self.allocator.free(text);
                                continue;
                            },
                            else => return err,
                        };
                    }
                    self.allocator.free(existing.text);
                    existing.text = text;
                    existing.version = version;
                    existing.revision = doc.revision;
                    self.next_version = next_version;
                }
                if (existing.saved_revision != doc.saved_revision and doc.saved_revision == doc.revision) {
                    switch (caps.save) {
                        .none => {},
                        .without_text => self.client.notify("textDocument/didSave", .{ .textDocument = .{ .uri = existing.uri } }) catch |err| switch (err) {
                            error.QueueFull => continue,
                            else => return err,
                        },
                        .with_text => self.client.notify("textDocument/didSave", .{ .textDocument = .{ .uri = existing.uri }, .text = existing.text }) catch |err| switch (err) {
                            error.QueueFull => continue,
                            else => return err,
                        },
                    }
                    existing.saved_revision = doc.saved_revision;
                }
            } else {
                if (self.documents.items.len >= max_documents) {
                    self.skipped += 1;
                    continue;
                }
                const path = try self.allocator.dupe(u8, doc.path.?);
                errdefer self.allocator.free(path);
                const uri = try pathUri(self.allocator, path);
                errdefer self.allocator.free(uri);
                const text = try doc.buffer.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(text);
                try self.documents.ensureUnusedCapacity(self.allocator, 1);
                const version = self.next_version;
                const next_version = std.math.add(i32, version, 1) catch return error.VersionExhausted;
                self.client.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = version, .text = text } }) catch |err| switch (err) {
                    error.QueueFull => {
                        self.allocator.free(path);
                        self.allocator.free(uri);
                        self.allocator.free(text);
                        continue;
                    },
                    else => return err,
                };
                self.documents.appendAssumeCapacity(.{ .path = path, .uri = uri, .text = text, .revision = doc.revision, .saved_revision = doc.saved_revision, .version = version, .instance_id = doc.instance_id });
                self.next_version = next_version;
            }
        }
    }
};

fn sameHoverTarget(target: HoverRequest, doc: *const zid.Document) bool {
    return target.instance_id == doc.instance_id and target.revision == doc.revision and target.cursor == doc.cursor;
}

/// A definition response may contain a Location, LocationLink, or an array of
/// either. Prefer the first valid local file; no remote URI is opened by Zid.
fn definitionResult(a: std.mem.Allocator, result: std.json.Value, encoding: zid.lsp.position.Encoding) !?Definition {
    if (result == .array) {
        for (result.array.items) |item| if (try definitionItem(a, item, encoding)) |target| return target;
        return null;
    }
    return definitionItem(a, result, encoding);
}

fn definitionItem(a: std.mem.Allocator, item: std.json.Value, encoding: zid.lsp.position.Encoding) !?Definition {
    if (item != .object) return null;
    const uri = item.object.get("targetUri") orelse item.object.get("uri") orelse return null;
    const range = item.object.get("targetSelectionRange") orelse item.object.get("range") orelse return null;
    if (uri != .string or range != .object) return null;
    const start = parsePosition(range.object.get("start") orelse return null) orelse return null;
    _ = parsePosition(range.object.get("end") orelse return null) orelse return null;
    const path = (try uriPath(a, uri.string)) orelse return null;
    return .{ .path = path, .position = start, .encoding = encoding };
}

fn parsePosition(value: std.json.Value) ?zid.lsp.position.Position {
    if (value != .object) return null;
    const line = value.object.get("line") orelse return null;
    const character = value.object.get("character") orelse return null;
    if (line != .integer or character != .integer or line.integer < 0 or character.integer < 0 or line.integer > std.math.maxInt(u32) or character.integer > std.math.maxInt(u32)) return null;
    return .{ .line = @intCast(line.integer), .character = @intCast(character.integer) };
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Strictly accept local file URIs and decode percent-encoded path bytes. URI
/// fragments, query strings, remote authorities, NULs and overlong paths fail.
fn uriPath(a: std.mem.Allocator, uri: []const u8) !?[]u8 {
    if (uri.len < 8 or !std.ascii.eqlIgnoreCase(uri[0..7], "file://")) return null;
    const tail = uri[7..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return null;
    if (slash != 0 and !std.ascii.eqlIgnoreCase(tail[0..slash], "localhost")) return null;
    const source = tail[slash..];
    if (source.len > 3 * std.fs.max_path_bytes or std.mem.indexOfAny(u8, source, "?#") != null) return null;
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(a);
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        var c = source[i];
        if (c == '%') {
            if (i + 2 >= source.len) return null;
            const hi = hexValue(source[i + 1]) orelse return null;
            const lo = hexValue(source[i + 2]) orelse return null;
            c = hi * 16 + lo;
            i += 2;
        }
        if (c == 0 or path.items.len >= std.fs.max_path_bytes) return null;
        try path.append(a, c);
    }
    if (!std.fs.path.isAbsolute(path.items)) return null;
    return try path.toOwnedSlice(a);
}

/// LSP permits a string, MarkupContent, MarkedString, or array of marked
/// strings. Preserve the server's Markdown as text; styling is the view's job.
fn hoverText(a: std.mem.Allocator, result: std.json.Value) !?[]u8 {
    if (result != .object) return null;
    const contents = result.object.get("contents") orelse return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    switch (contents) {
        .array => |items| for (items.items) |item| {
            if (out.items.len >= max_hover_bytes) break;
            if (hoverPart(item)) |part| {
                if (part.len == 0) continue;
                if (out.items.len != 0) try appendHover(a, &out, "\n\n");
                try appendHover(a, &out, part);
            }
        },
        else => if (hoverPart(contents)) |part| try appendHover(a, &out, part),
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(a);
}

fn hoverPart(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        .object => |obj| if (obj.get("value")) |v| (if (v == .string) v.string else null) else null,
        else => null,
    };
}

fn appendHover(a: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(value)) return;
    var n = @min(value.len, max_hover_bytes - out.items.len);
    while (n > 0 and n < value.len and value[n] & 0xc0 == 0x80) n -= 1;
    try out.appendSlice(a, value[0..n]);
}

fn isZig(doc: *const zid.Document) bool {
    const path = doc.path orelse return false;
    return std.mem.endsWith(u8, path, ".zig");
}
fn eligible(doc: *const zid.Document) bool {
    return isZig(doc) and doc.large == null and !doc.preview_only and doc.buffer.len() <= max_document_bytes;
}

/// RFC 3986 percent encoding over filesystem bytes, preserving absolute slash.
fn pathUri(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.ExpectedAbsolutePath;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "file://");
    const hex = "0123456789ABCDEF";
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(a, c);
        } else {
            try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
    return out.toOwnedSlice(a);
}

test "file URI encodes reserved and UTF-8 bytes" {
    const a = std.testing.allocator;
    const uri = try pathUri(a, "/tmp/a b#é.zig");
    defer a.free(uri);
    try std.testing.expectEqualStrings("file:///tmp/a%20b%23%C3%A9.zig", uri);
    try std.testing.expectError(error.ExpectedAbsolutePath, pathUri(a, "relative"));
}

test "definition accepts local locations and rejects unsafe URIs" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{ "file://remote/tmp/a", "https://example.com/a", "file:///tmp/a%00b", "file:///tmp/a%zz", "file:///tmp/a#fragment", "file:///tmp/a?query" };
    for (cases) |uri| try std.testing.expect((try uriPath(a, uri)) == null);
    const path = (try uriPath(a, "file://localhost/tmp/a%20b%23%C3%A9.zig")).?;
    defer a.free(path);
    try std.testing.expectEqualStrings("/tmp/a b#é.zig", path);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "[{\"uri\":\"file://remote/x\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}},{\"targetUri\":\"file:///tmp/a%20b.zig\",\"targetSelectionRange\":{\"start\":{\"line\":4,\"character\":7},\"end\":{\"line\":4,\"character\":9}},\"targetRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":9,\"character\":0}}}]", .{});
    defer parsed.deinit();
    var target = (try definitionResult(a, parsed.value, .utf16)).?;
    defer target.deinit(a);
    try std.testing.expectEqualStrings("/tmp/a b.zig", target.path);
    try std.testing.expectEqual(zid.lsp.position.Position{ .line = 4, .character = 7 }, target.position);
    try std.testing.expectEqual(zid.lsp.position.Encoding.utf16, target.encoding);
}

test "hover decodes markup and bounds UTF-8 output" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"contents\":[\"plain\",{\"language\":\"zig\",\"value\":\"const a = 1;\"},{\"kind\":\"markdown\",\"value\":\"doc\"}]}", .{});
    defer parsed.deinit();
    const text = (try hoverText(a, parsed.value)).?;
    defer a.free(text);
    try std.testing.expectEqualStrings("plain\n\nconst a = 1;\n\ndoc", text);
    const source = try a.alloc(u8, max_hover_bytes + 2);
    defer a.free(source);
    @memset(source, 'x');
    source[max_hover_bytes - 1] = 0xc3;
    source[max_hover_bytes] = 0xa9;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendHover(a, &out, source);
    try std.testing.expectEqual(@as(usize, max_hover_bytes - 1), out.items.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.items));
}

test "hover ignores superseded and dismissed responses" {
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
        \\init=read(); send({'jsonrpc':'2.0','id':init['id'],'result':{'capabilities':{'textDocumentSync':{'openClose':True,'change':2}}}})
        \\assert read()['method']=='initialized'; assert read()['method']=='textDocument/didOpen'
        \\first=read(); second=read()
        \\assert first['params']['position']=={'line':0,'character':1}
        \\assert second['params']['position']=={'line':0,'character':3}
        \\send({'jsonrpc':'2.0','id':first['id'],'result':{'contents':'obsolete'}})
        \\send({'jsonrpc':'2.0','id':second['id'],'result':{'contents':{'kind':'markdown','value':'fresh'}}})
        \\third=read(); send({'jsonrpc':'2.0','id':third['id'],'result':{'contents':'dismissed'}})
        \\sys.stdin.buffer.read()
    ;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var workspace = try zid.Workspace.init(a, io, "/tmp");
    defer workspace.deinit();
    try workspace.documents.append(a, try zid.Document.init(a, "a😀b", "/tmp/hover.zig"));
    var controller = try Controller.start(a, io, "/tmp", &.{ "python3", "-u", "-c", script });
    defer controller.deinit();
    const Wait = struct {
        fn input(c: *Controller) !void {
            const w = c.client.worker;
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            while (w.incoming.items.len == 0 and w.failure == null) try w.changed.waitTimeout(w.io, &w.mutex, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        }
    };
    try Wait.input(&controller);
    try controller.poll(&workspace);
    workspace.current().cursor = 1;
    try controller.requestHover(workspace.current());
    workspace.current().cursor = 5;
    try controller.requestHover(workspace.current());
    for (0..4) |_| {
        try Wait.input(&controller);
        try controller.poll(&workspace);
        if (!controller.hover_pending) break;
    }
    try std.testing.expectEqualStrings("fresh", controller.hoverFor(workspace.current()).?);
    try controller.requestHover(workspace.current());
    controller.clearHover();
    try Wait.input(&controller);
    try controller.poll(&workspace);
    try std.testing.expect(controller.hoverFor(workspace.current()) == null);
    try std.testing.expect(!controller.hover_pending);
}

test "definition rejects superseded and dismissed responses" {
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
        \\init=read(); send({'jsonrpc':'2.0','id':init['id'],'result':{'capabilities':{'textDocumentSync':{'openClose':True,'change':2}}}})
        \\assert read()['method']=='initialized'; assert read()['method']=='textDocument/didOpen'
        \\a=read(); b=read(); assert a['method']==b['method']=='textDocument/definition'
        \\assert a['params']['position']=={'line':0,'character':1} and b['params']['position']=={'line':0,'character':3}
        \\def result(req,path): send({'jsonrpc':'2.0','id':req['id'],'result':{'uri':path,'range':{'start':{'line':1,'character':2},'end':{'line':1,'character':3}}}})
        \\result(a,'file:///tmp/old.zig'); result(b,'file:///tmp/new%20file.zig')
        \\c=read(); result(c,'file:///tmp/dismissed.zig'); sys.stdin.buffer.read()
    ;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var workspace = try zid.Workspace.init(a, io, "/tmp");
    defer workspace.deinit();
    try workspace.documents.append(a, try zid.Document.init(a, "a😀b", "/tmp/definition.zig"));
    var controller = try Controller.start(a, io, "/tmp", &.{ "python3", "-u", "-c", script });
    defer controller.deinit();
    const Wait = struct {
        fn input(c: *Controller) !void {
            const w = c.client.worker;
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            while (w.incoming.items.len == 0 and w.failure == null) try w.changed.waitTimeout(w.io, &w.mutex, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        }
    };
    try Wait.input(&controller);
    try controller.poll(&workspace);
    workspace.current().cursor = 1;
    try controller.requestDefinition(workspace.current());
    workspace.current().cursor = 5;
    try controller.requestDefinition(workspace.current());
    for (0..4) |_| {
        try Wait.input(&controller);
        try controller.poll(&workspace);
        if (!controller.definition_pending) break;
    }
    var target = controller.takeDefinition(workspace.current()).?;
    defer target.deinit(a);
    try std.testing.expectEqualStrings("/tmp/new file.zig", target.path);
    try std.testing.expectEqual(zid.lsp.position.Position{ .line = 1, .character = 2 }, target.position);
    try controller.requestDefinition(workspace.current());
    controller.clearDefinition();
    try Wait.input(&controller);
    try controller.poll(&workspace);
    try std.testing.expect(controller.takeDefinition(workspace.current()) == null);
    try std.testing.expect(!controller.definition_pending);
}

test "document synchronization and versioned diagnostics" {
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
        \\init=read(); send({'jsonrpc':'2.0','id':init['id'],'result':{'capabilities':{'textDocumentSync':{'openClose':True,'change':2}}}})
        \\assert read()['method']=='initialized'
        \\opened=read(); assert opened['method']=='textDocument/didOpen'
        \\uri=opened['params']['textDocument']['uri']; assert opened['params']['textDocument']['text']=='abc'
        \\def diag(version,text): send({'jsonrpc':'2.0','method':'textDocument/publishDiagnostics','params':{'uri':uri,'version':version,'diagnostics':[{'range':{'start':{'line':0,'character':0},'end':{'line':0,'character':1}},'message':text}]}})
        \\diag(1,'old')
        \\change=read(); assert change['method']=='textDocument/didChange'
        \\c=change['params']['contentChanges'][0]; assert c['range']['end']=={'line':0,'character':3} and c['text']=='Xabc'
        \\diag(1,'stale'); diag(2,'new')
        \\send({'jsonrpc':'2.0','method':'textDocument/publishDiagnostics','params':{'uri':uri,'diagnostics':[{'range':{'start':{'line':0,'character':0},'end':{'line':0,'character':1}},'message':'unversioned'}]}})
        \\closed=read(); assert closed['method']=='textDocument/didClose'
        \\reopened=read(); assert reopened['method']=='textDocument/didOpen' and reopened['params']['textDocument']['text']=='replacement'
        \\sys.stdin.buffer.read()
    ;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var workspace = try zid.Workspace.init(a, io, "/tmp");
    defer workspace.deinit();
    try workspace.documents.append(a, try zid.Document.init(a, "abc", "/tmp/controller.zig"));
    var controller = try Controller.start(a, io, "/tmp", &.{ "python3", "-u", "-c", script });
    defer controller.deinit();
    const Wait = struct {
        fn input(c: *Controller) !void {
            const w = c.client.worker;
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            while (w.incoming.items.len == 0 and w.failure == null) try w.changed.waitTimeout(w.io, &w.mutex, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        }
    };
    try Wait.input(&controller);
    try controller.poll(&workspace);
    try Wait.input(&controller);
    try controller.poll(&workspace);
    const instance_id = workspace.current().instance_id;
    try std.testing.expectEqualStrings("old", controller.diagnosticsFor("/tmp/controller.zig", instance_id, 0).?.diagnostics[0].message);
    try workspace.current().insert("X");
    const revision = workspace.current().revision;
    try std.testing.expect(controller.diagnosticsFor("/tmp/controller.zig", instance_id, revision) == null);
    try controller.poll(&workspace);
    for (0..4) |_| {
        try Wait.input(&controller);
        try controller.poll(&workspace);
        if (controller.diagnosticsFor("/tmp/controller.zig", instance_id, revision)) |d| {
            if (std.mem.eql(u8, d.diagnostics[0].message, "unversioned")) break;
        }
    }
    const latest = controller.diagnosticsFor("/tmp/controller.zig", instance_id, revision).?;
    try std.testing.expectEqualStrings("unversioned", latest.diagnostics[0].message);
    try std.testing.expect(latest.version == null);
    var doc = workspace.documents.pop().?;
    doc.deinit();
    try workspace.documents.append(a, try zid.Document.init(a, "replacement", "/tmp/controller.zig"));
    try std.testing.expect(controller.diagnosticsFor("/tmp/controller.zig", workspace.current().instance_id, 0) == null);
    try controller.poll(&workspace);
    try std.testing.expectEqual(@as(usize, 1), controller.documents.items.len);
    try std.testing.expectEqualStrings("replacement", controller.documents.items[0].text);
    try std.testing.expectEqual(workspace.current().instance_id, controller.documents.items[0].instance_id);
}
