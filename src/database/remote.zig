//! Configuration and secret resolution for future remote SQL adapters.
const std = @import("std");
const db = @import("root.zig");

pub const SecretProvider = struct {
    context: ?*anyopaque,
    /// Returns an allocated secret. The caller must clear and free it.
    resolveFn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, db.SecretRef) anyerror![]u8,

    pub fn resolve(self: SecretProvider, a: std.mem.Allocator, io: std.Io, ref: db.SecretRef) ![]u8 {
        if (!validField(ref.name)) return error.InvalidConfiguration;
        const secret = try self.resolveFn(self.context, a, io, ref);
        errdefer {
            @memset(secret, 0);
            a.free(secret);
        }
        if (std.mem.indexOfScalar(u8, secret, 0) != null) return error.InvalidConfiguration;
        return secret;
    }
};

pub const Connection = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    user: []const u8,
    credential: ?db.SecretRef = null,
    secret_provider: ?SecretProvider = null,

    pub fn validate(self: Connection) !void {
        if (!validField(self.host) or !validField(self.database) or !validField(self.user) or self.port == 0)
            return error.InvalidConfiguration;
        if (self.credential) |ref| {
            if (!validField(ref.name) or self.secret_provider == null) return error.InvalidConfiguration;
        }
    }
};

fn validField(value: []const u8) bool {
    return value.len != 0 and value[0] != '-' and std.mem.indexOfScalar(u8, value, 0) == null;
}

test "remote configuration and secret resolver" {
    const Test = struct {
        fn resolve(_: ?*anyopaque, a: std.mem.Allocator, _: std.Io, ref: db.SecretRef) ![]u8 {
            try std.testing.expectEqualStrings("db-secret", ref.name);
            return a.dupe(u8, "secret");
        }
    };
    const provider: SecretProvider = .{ .context = null, .resolveFn = Test.resolve };
    var connection: Connection = .{ .host = "localhost", .port = 5432, .database = "app", .user = "reader", .credential = .{ .name = "db-secret" }, .secret_provider = provider };
    try connection.validate();
    const secret = try provider.resolve(std.testing.allocator, std.testing.io, connection.credential.?);
    defer {
        @memset(secret, 0);
        std.testing.allocator.free(secret);
    }
    try std.testing.expectEqualStrings("secret", secret);
    connection.host = "-option";
    try std.testing.expectError(error.InvalidConfiguration, connection.validate());
    connection.host = "local\x00host";
    try std.testing.expectError(error.InvalidConfiguration, connection.validate());
    connection.host = "localhost";
    connection.secret_provider = null;
    try std.testing.expectError(error.InvalidConfiguration, connection.validate());
}
