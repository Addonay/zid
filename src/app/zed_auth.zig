//! Zed's native-app sign-in protocol (`crates/client/src/client.rs`
//! `authenticate_with_browser`, `crates/rpc/src/auth.rs`): the localhost callback
//! server, token decryption and credential storage. No SDL or UI; `account.zig` runs it
//! on a worker thread and opens the browser when `Sink.open_url` is set.
const std = @import("std");
const zid = @import("zid");

pub const server_url = "https://zed.dev";
pub const cloud_url = "https://cloud.zed.dev";
pub const Pair = zid.rsa.KeyPair(2048);
pub const Credentials = struct { user_id: []const u8, access_token: []const u8 };

/// Where the flow publishes the sign-in URL for the UI thread.
pub const Sink = struct {
    open_url: std.atomic.Value(bool) = .init(false),
    url: [1024]u8 = undefined,
    url_len: usize = 0,
};

fn percentEncode(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}
fn percentDecode(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
            try out.append(arena, try std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16));
            i += 2;
        } else try out.append(arena, if (text[i] == '+') ' ' else text[i]);
    }
    return out.items;
}

pub fn authenticateWithBrowser(self: *Sink, arena: std.mem.Allocator, io: std.Io) !Credentials {
    const pair = try Pair.generate(io);
    return awaitCallback(self, arena, io, &pair);
}

/// Steps 2-3 of the flow for any key size (tests use a small key).
pub fn awaitCallback(self: *Sink, arena: std.mem.Allocator, io: std.Io, pair: anytype) !Credentials {
    const P = @TypeOf(pair.*);
    var der_buf: [P.modulus_bytes + 64]u8 = undefined;
    const der = try pair.publicKeyDer(&der_buf);
    const encoder = std.base64.url_safe.Encoder;
    const key = try arena.alloc(u8, encoder.calcSize(der.len));
    _ = encoder.encode(key, der);

    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var w: std.Io.Writer = .fixed(&self.url);
    try w.print("{s}/native_app_signin?native_app_port={d}&native_app_public_key=", .{ server_url, port });
    try percentEncode(&w, key);
    self.url_len = w.buffered().len;
    self.open_url.store(true, .release);

    // Zed waits up to 100 one-second polls; accept blocks until the browser returns.
    var stream = try server.accept(io);
    defer stream.close(io);
    var read_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const request_line = try reader.interface.takeDelimiterExclusive('\n');
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, request_line, "\r"), ' ');
    _ = parts.next(); // method
    const target = parts.next() orelse return error.BadCallback;
    const query = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[q + 1 ..] else return error.BadCallback;
    var user_id: ?[]const u8 = null;
    var token: ?[]const u8 = null;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair_text| {
        const eq = std.mem.indexOfScalar(u8, pair_text, '=') orelse continue;
        const value = try percentDecode(arena, pair_text[eq + 1 ..]);
        if (std.mem.eql(u8, pair_text[0..eq], "user_id")) user_id = value else if (std.mem.eql(u8, pair_text[0..eq], "access_token")) token = value;
    }
    var write_buf: [512]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.print("HTTP/1.1 302 Found\r\nLocation: {s}/native_app_signin_succeeded\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{server_url});
    try writer.interface.flush();

    const encrypted = token orelse return error.MissingAccessToken;
    const decoder = std.base64.url_safe.Decoder;
    const cipher = try arena.alloc(u8, try decoder.calcSizeForSlice(encrypted));
    try decoder.decode(cipher, encrypted);
    var plain: [P.modulus_bytes]u8 = undefined;
    const access_token = try arena.dupe(u8, try pair.decrypt(cipher, &plain));
    return .{ .user_id = user_id orelse return error.MissingUserId, .access_token = access_token };
}


fn credentialsPath(arena: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(arena, &.{ data_dir, "zed_credentials" });
}
pub fn loadCredentials(arena: std.mem.Allocator, io: std.Io, data_dir: []const u8) !Credentials {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, try credentialsPath(arena, data_dir), arena, .limited(16 * 1024));
    return std.json.parseFromSliceLeaky(Credentials, arena, bytes, .{ .ignore_unknown_fields = true });
}
/// Zed keeps these in the OS keychain; Zid writes an owner-only (0600) file.
pub fn saveCredentials(arena: std.mem.Allocator, io: std.Io, data_dir: []const u8, credentials: Credentials) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, data_dir);
    const json = try std.json.Stringify.valueAlloc(arena, credentials, .{});
    var file = try cwd.createFileAtomic(io, try credentialsPath(arena, data_dir), .{ .replace = true, .permissions = @enumFromInt(0o600) });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, json);
    try file.file.setPermissions(io, @enumFromInt(0o600));
    try file.file.sync(io);
    try file.replace(io);
}

test "browser callback round trip: public key in URL, encrypted token decrypted" {
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Small = zid.rsa.KeyPair(1024);
    const pair = try Small.generate(io);
    var account: Sink = .{};
    const Result = struct { credentials: ?Credentials = null, err: ?anyerror = null };
    var result: Result = .{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(a: *Sink, ar: std.mem.Allocator, p: *const Small, r: *Result) void {
            r.credentials = awaitCallback(a, ar, std.testing.io, p) catch |err| blk: {
                r.err = err;
                break :blk null;
            };
        }
    }.run, .{ &account, arena, &pair, &result });
    while (!account.open_url.load(.acquire)) std.Thread.yield() catch {};
    const url = account.url[0..account.url_len];
    try std.testing.expect(std.mem.startsWith(u8, url, "https://zed.dev/native_app_signin?native_app_port="));
    const port_start = std.mem.indexOf(u8, url, "port=").? + 5;
    const port_end = std.mem.indexOfScalarPos(u8, url, port_start, '&').?;
    const port = try std.fmt.parseInt(u16, url[port_start..port_end], 10);

    // Play zed.dev: encrypt a token to the key and hit the callback.
    var cipher: [Small.modulus_bytes]u8 = undefined;
    try pair.encrypt(io, "secret-token", &cipher);
    var encoded: [256]u8 = undefined;
    const token = std.base64.url_safe.Encoder.encode(&encoded, &cipher);
    var request_buf: [1024]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&request_buf);
    try rw.writeAll("GET /?user_id=42&access_token=");
    try percentEncode(&rw, token);
    try rw.writeAll(" HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [64]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(rw.buffered());
    try writer.interface.flush();
    var rbuf: [512]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const status = try reader.interface.takeDelimiterExclusive('\n');
    try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 302"));
    thread.join();
    if (result.err) |err| return err;
    try std.testing.expectEqualStrings("42", result.credentials.?.user_id);
    try std.testing.expectEqualStrings("secret-token", result.credentials.?.access_token);
}
