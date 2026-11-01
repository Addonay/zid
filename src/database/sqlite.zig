const std = @import("std");
const db = @import("root.zig");

pub const Connection = struct {
    /// Existing database path, or :memory:. Never passed through a shell.
    path: []const u8,
    executable: []const u8 = "sqlite3",
};

/// Executes via the official sqlite3 CLI in read-only, safe mode. Output is
/// JSON objects with SQLite's scalar types. See implementation notes for limits.
pub fn query(a: std.mem.Allocator, io: std.Io, conn: Connection, sql: []const u8, limits: db.Limits) db.Error!db.Table {
    if (sql.len == 0 or sql.len > 1024 * 1024 or std.mem.indexOfScalar(u8, sql, 0) != null or
        conn.path.len == 0 or conn.path[0] == '-' or std.mem.indexOfScalar(u8, conn.path, 0) != null)
        return error.InvalidQuery;
    // The CLI interprets dot commands itself. Disallow them even in safe mode.
    var lines = std.mem.splitScalar(u8, sql, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '.') return error.InvalidQuery;
    }
    const res = std.process.run(a, io, .{
        .argv = &.{ conn.executable, "-safe", "-readonly", "-json", "--", conn.path, sql },
        .stdout_limit = .limited(limits.max_bytes),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| return switch (err) {
        error.Canceled => error.Cancelled,
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.OutputLimit,
        else => error.ClientUnavailable,
    };
    defer a.free(res.stdout);
    defer a.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return error.QueryFailed;
    const output = if (std.mem.trim(u8, res.stdout, " \r\n\t").len == 0) "[]" else res.stdout;
    var parsed = std.json.parseFromSlice(std.json.Value, a, output, .{ .allocate = .alloc_always }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidOutput,
    };
    errdefer parsed.deinit();
    if (parsed.value != .array) return error.InvalidOutput;
    if (parsed.value.array.items.len > limits.max_rows) return error.RowLimit;
    for (parsed.value.array.items) |row| {
        if (row != .object) return error.InvalidOutput;
        if (row.object.count() > limits.max_columns) return error.ColumnLimit;
        var it = row.object.iterator();
        while (it.next()) |entry| switch (entry.value_ptr.*) {
            .null, .bool, .integer, .float, .number_string, .string => {},
            else => return error.InvalidOutput,
        };
    }
    return .{ .parsed = parsed };
}

test "real sqlite scalar results, errors, bounds and safe mode" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const c: db.Connection = .{ .sqlite = .{ .path = ":memory:" } };
    var table = try db.query(a, io, c, "select 7 as n, null as empty, 'hello' as text", .{});
    defer table.deinit();
    try std.testing.expectEqual(@as(usize, 1), table.rows().len);
    const row = table.rows()[0].object;
    try std.testing.expectEqual(@as(i64, 7), row.get("n").?.integer);
    try std.testing.expect(row.get("empty").? == .null);
    try std.testing.expectEqualStrings("hello", row.get("text").?.string);
    try std.testing.expectError(error.QueryFailed, db.query(a, io, c, "select * from missing", .{}));
    try std.testing.expectError(error.RowLimit, db.query(a, io, c, "select 1 union all select 2", .{ .max_rows = 1 }));
    try std.testing.expectError(error.ColumnLimit, db.query(a, io, c, "select 1 as a, 2 as b", .{ .max_columns = 1 }));
    try std.testing.expectError(error.InvalidQuery, db.query(a, io, c, ".shell echo bad", .{}));
    try std.testing.expectError(error.UnsupportedBackend, db.query(a, io, .{ .convex = .{ .endpoint = "example" } }, "select 1", .{}));
}

/// SQLite's catalog supplies object names and CREATE statements; no user input
/// is interpolated. Objects internal to SQLite are intentionally excluded.
pub fn schema(a: std.mem.Allocator, io: std.Io, conn: Connection, limits: db.Limits) db.Error!db.Table {
    return query(a, io, conn, "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name", limits);
}

test "catalog of a temporary database" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "fixture.db" });
    defer a.free(path);
    const init = try std.process.run(a, io, .{ .argv = &.{ "sqlite3", path, "CREATE TABLE example (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO example VALUES (1, 'Ada');" } });
    defer a.free(init.stdout);
    defer a.free(init.stderr);
    try std.testing.expect(init.term == .exited and init.term.exited == 0);
    var meta = try schema(a, io, .{ .path = path }, .{});
    defer meta.deinit();
    try std.testing.expectEqualStrings("example", meta.rows()[0].object.get("name").?.string);
    var data = try query(a, io, .{ .path = path }, "SELECT name FROM example", .{});
    defer data.deinit();
    try std.testing.expectEqualStrings("Ada", data.rows()[0].object.get("name").?.string);
    try std.testing.expectError(error.QueryFailed, query(a, io, .{ .path = path }, "DELETE FROM example", .{}));
}
