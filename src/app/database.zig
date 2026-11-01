//! SQLite viewer state. The worker owns an immutable request until joined.
const std = @import("std");
const db = @import("zid").database;
const LineInput = @import("line_input.zig").LineInput;
const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    sql: []u8,
    done: std.atomic.Value(bool) = .init(false),
    fn run(job: *Job) db.Error!db.Table {
        defer job.done.store(true, .release);
        return db.query(job.allocator, job.io, .{ .sqlite = .{ .path = job.path } }, job.sql, .{});
    }
};
pub const State = struct {
    open: bool = false,
    path: LineInput = .{},
    sql: LineInput = .{},
    focus: enum { path, sql } = .path,
    table: ?db.Table = null,
    job: ?*Job = null,
    future: ?std.Io.Future(db.Error!db.Table) = null,
    status: []const u8 = "Enter a SQLite file path, then inspect schema or run SQL.",
    scroll: usize = 0,
    column_scroll: usize = 0,
    pub fn input(self: *State) *LineInput {
        return if (self.focus == .path) &self.path else &self.sql;
    }
    pub fn start(self: *State, a: std.mem.Allocator, io: std.Io, schema: bool) void {
        if (self.job != null) {
            self.status = "A query is running; cancel it first.";
            return;
        }
        const job = a.create(Job) catch {
            self.status = "Out of memory";
            return;
        };
        const path = a.dupe(u8, self.path.text()) catch {
            a.destroy(job);
            self.status = "Out of memory";
            return;
        };
        const sql = a.dupe(u8, if (schema) "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name" else self.sql.text()) catch {
            a.free(path);
            a.destroy(job);
            self.status = "Out of memory";
            return;
        };
        job.* = .{ .allocator = a, .io = io, .path = path, .sql = sql };
        self.future = io.concurrent(Job.run, .{job}) catch {
            a.free(path);
            a.free(sql);
            a.destroy(job);
            self.status = "Could not start worker";
            return;
        };
        self.job = job;
        self.status = "Running…";
    }
    fn finish(self: *State, io: std.Io, cancelling: bool) void {
        const job = self.job orelse return;
        const result = if (cancelling) self.future.?.cancel(io) else self.future.?.await(io);
        if (result) |table| {
            if (self.table) |*old| old.deinit();
            self.table = table;
            self.scroll = 0;
            self.column_scroll = 0;
            self.status = "Query complete";
        } else |err| self.status = switch (err) {
            error.InvalidQuery => "Invalid path or query",
            error.ClientUnavailable => "SQLite client unavailable or could not start",
            error.QueryFailed => "SQLite query failed (read-only database or SQL error)",
            error.OutputLimit, error.RowLimit, error.ColumnLimit => "Result exceeds viewer limits",
            error.InvalidOutput => "SQLite returned unsupported output",
            error.Cancelled => "Query cancelled",
            error.OutOfMemory => "Out of memory",
            error.UnsupportedBackend => "Backend unavailable",
        };
        job.allocator.free(job.path);
        job.allocator.free(job.sql);
        job.allocator.destroy(job);
        self.job = null;
        self.future = null;
    }
    pub fn poll(self: *State, io: std.Io) void {
        if (self.job) |job| if (job.done.load(.acquire)) {
            self.finish(io, false);
        };
    }
    pub fn cancel(self: *State, io: std.Io) void {
        self.finish(io, true);
    }
    pub fn deinit(self: *State, io: std.Io) void {
        self.cancel(io);
        if (self.table) |*table| table.deinit();
    }
};
