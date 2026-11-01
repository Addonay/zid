//! Database viewer backend. No rendering or global I/O state.
const std = @import("std");
pub const sqlite = @import("sqlite.zig");
pub const remote = @import("remote.zig");

/// Credentials are referenced, never serialized or formatted by this module.
pub const SecretRef = struct { name: []const u8 };
pub const Connection = union(enum) {
    sqlite: sqlite.Connection,
    mysql: remote.Connection,
    postgres: remote.Connection,
    convex: Remote,
};
pub const Remote = struct { endpoint: []const u8, credential: ?SecretRef = null };
pub const Limits = struct { max_bytes: usize = 1024 * 1024, max_rows: usize = 1000, max_columns: usize = 128 };
pub const Error = error{ UnsupportedBackend, InvalidQuery, ClientUnavailable, QueryFailed, OutputLimit, InvalidOutput, RowLimit, ColumnLimit, OutOfMemory, Cancelled };

/// Output owns its parsed data. Empty SQLite results do not provide column names.
pub const Table = struct {
    parsed: std.json.Parsed(std.json.Value),
    pub fn deinit(self: *Table) void {
        self.parsed.deinit();
    }
    pub fn rows(self: *const Table) []const std.json.Value {
        return self.parsed.value.array.items;
    }
};

/// Caller must run this blocking operation off the UI thread. The Io context's
/// cancellation propagates to process execution; no backend errors are logged.
pub fn query(a: std.mem.Allocator, io: std.Io, conn: Connection, sql: []const u8, limits: Limits) Error!Table {
    return switch (conn) {
        .sqlite => |c| sqlite.query(a, io, c, sql, limits),
        else => error.UnsupportedBackend,
    };
}

test {
    _ = sqlite;
    _ = remote;
}
