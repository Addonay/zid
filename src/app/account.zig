//! Zed account sign-in (`crates/client/src/client.rs` `authenticate_with_browser`).
//!
//! 1. Generate an RSA-2048 key pair (`core/rsa.zig`).
//! 2. Listen on 127.0.0.1 with an ephemeral port and open
//!    `https://zed.dev/native_app_signin?native_app_port=<port>&native_app_public_key=<key>`
//!    in the browser.
//! 3. zed.dev redirects to `http://127.0.0.1:<port>/?user_id=..&access_token=..`; the
//!    token is base64url RSA-OAEP ciphertext. Answer with a 302 to
//!    `https://zed.dev/native_app_signin_succeeded`, then decrypt.
//! 4. Fetch `https://cloud.zed.dev/client/users/me` with `Authorization: <id> <token>`
//!    for the GitHub login, name and avatar URL.
//!
//! Zed keeps credentials in the OS keychain; Zid stores them in
//! `$XDG_DATA_HOME/zid/zed_credentials` with mode 0600 and signs back in from them at
//! startup, as Zed does from the keychain. The flow runs on a worker thread; the UI
//! reads `status` (atomic) and the fields it publishes.
const std = @import("std");
const sdl = @import("sdl3");
const zid = @import("zid");
const App = @import("app.zig").App;
const log = std.log.scoped(.account);

pub const Status = enum(u8) { signed_out, signing_in, signed_in, failed };
pub const User = struct { login: []const u8, name: []const u8, avatar_url: []const u8 };
const auth = @import("zed_auth.zig");

pub const Account = struct {
    status: std.atomic.Value(Status) = .init(.signed_out),
    /// Set by the worker when the browser should be opened (UI thread opens it).
    sink: auth.Sink = .{},
    login: [64]u8 = undefined,
    login_len: usize = 0,
    name: [128]u8 = undefined,
    name_len: usize = 0,
    avatar: [512]u8 = undefined,
    avatar_len: usize = 0,
    error_text: [160]u8 = undefined,
    error_len: usize = 0,
    thread: ?std.Thread = null,

    pub fn user(self: *const Account) ?User {
        if (self.status.load(.acquire) != .signed_in) return null;
        return .{ .login = self.login[0..self.login_len], .name = self.name[0..self.name_len], .avatar_url = self.avatar[0..self.avatar_len] };
    }
    pub fn signingIn(self: *const Account) bool {
        return self.status.load(.acquire) == .signing_in;
    }

    /// `client::SignIn`.
    pub fn signIn(self: *Account, app: *App) !void {
        if (self.status.load(.acquire) == .signing_in or self.status.load(.acquire) == .signed_in) return;
        self.join();
        self.status.store(.signing_in, .release);
        self.thread = try std.Thread.spawn(.{}, worker, .{ self, app.gpa, app.io, app.data_dir, Mode.browser });
    }
    /// Startup: resume a stored session, like Zed reading its keychain entry.
    pub fn restore(self: *Account, app: *App) void {
        const path = std.fs.path.join(app.gpa, &.{ app.data_dir, "zed_credentials" }) catch return;
        defer app.gpa.free(path);
        _ = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch return;
        self.status.store(.signing_in, .release);
        self.thread = std.Thread.spawn(.{}, worker, .{ self, app.gpa, app.io, app.data_dir, Mode.stored }) catch {
            self.status.store(.signed_out, .release);
            return;
        };
    }
    /// `client::SignOut`: forget the stored credentials.
    pub fn signOut(self: *Account, app: *App) !void {
        self.join();
        const path = try std.fs.path.join(app.gpa, &.{ app.data_dir, "zed_credentials" });
        defer app.gpa.free(path);
        std.Io.Dir.cwd().deleteFile(app.io, path) catch |err| if (err != error.FileNotFound) return err;
        self.status.store(.signed_out, .release);
    }
    pub fn join(self: *Account) void {
        if (self.status.load(.acquire) == .signing_in) return; // still running; detach on exit
        if (self.thread) |t| t.join();
        self.thread = null;
    }
    pub fn deinit(self: *Account) void {
        if (self.thread) |t| if (self.status.load(.acquire) != .signing_in) t.join() else t.detach();
        self.thread = null;
    }

    /// UI thread: open the sign-in page and report failures. Call once per frame.
    pub fn poll(self: *Account, app: *App) void {
        if (self.sink.open_url.swap(false, .acq_rel)) {
            const url = app.gpa.dupeSentinel(u8, self.sink.url[0..self.sink.url_len], 0) catch return;
            defer app.gpa.free(url);
            sdl.openURL(url) catch |err| app.notice("Open browser: {s}", .{@errorName(err)});
        }
        if (self.status.load(.acquire) == .failed) {
            app.notice("Sign in failed: {s}", .{self.error_text[0..self.error_len]});
            self.status.store(.signed_out, .release);
        }
    }

    fn fail(self: *Account, comptime fmt: []const u8, args: anytype) void {
        self.error_len = if (std.fmt.bufPrint(&self.error_text, fmt, args)) |text| text.len else |_| 0;
        log.warn("sign in: {s}", .{self.error_text[0..self.error_len]});
        self.status.store(.failed, .release);
    }
};

const Mode = enum { browser, stored };
const Credentials = auth.Credentials;

fn worker(self: *Account, gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, mode: Mode) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const credentials = switch (mode) {
        .stored => auth.loadCredentials(arena, io, data_dir) catch |err| {
            self.status.store(.signed_out, .release);
            log.info("stored credentials unusable: {s}", .{@errorName(err)});
            return;
        },
        .browser => auth.authenticateWithBrowser(&self.sink, arena, io) catch |err| return self.fail("{s}", .{@errorName(err)}),
    };
    fetchUser(self, arena, gpa, io, credentials) catch |err| {
        if (mode == .stored) {
            self.status.store(.signed_out, .release);
            log.info("stored credentials rejected: {s}", .{@errorName(err)});
            return;
        }
        return self.fail("{s}", .{@errorName(err)});
    };
    if (mode == .browser) auth.saveCredentials(arena, io, data_dir, credentials) catch |err| log.warn("credentials not saved: {s}", .{@errorName(err)});
    self.status.store(.signed_in, .release);
}

fn copyInto(buf: []u8, len: *usize, value: []const u8) void {
    const n = @min(buf.len, value.len);
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

fn fetchUser(self: *Account, arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, credentials: Credentials) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const authorization = try std.fmt.allocPrint(arena, "{s} {s}", .{ credentials.user_id, credentials.access_token });
    const result = try client.fetch(.{
        .location = .{ .url = auth.cloud_url ++ "/client/users/me" },
        .response_writer = &body.writer,
        .headers = .{ .authorization = .{ .override = authorization } },
    });
    if (result.status != .ok) return error.Unauthorized;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body.written(), .{});
    const user_value = parsed.object.get("user") orelse return error.BadResponse;
    if (user_value != .object) return error.BadResponse;
    const u = user_value.object;
    const login = u.get("github_login") orelse return error.BadResponse;
    if (login != .string) return error.BadResponse;
    copyInto(&self.login, &self.login_len, login.string);
    self.name_len = 0;
    if (u.get("name")) |v| if (v == .string) copyInto(&self.name, &self.name_len, v.string);
    self.avatar_len = 0;
    if (u.get("avatar_url")) |v| if (v == .string) copyInto(&self.avatar, &self.avatar_len, v.string);
}

