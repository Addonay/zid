//! Selection controller for literal search in editable, memory-backed documents.
const std = @import("std");
const Document = @import("document.zig").Document;
const search = @import("search.zig");

pub const Direction = enum { next, previous };

/// Incremental result summary for a single document revision and query.
/// The caller discards this state whenever either changes. Each step examines
/// at most 16 KiB plus pattern overlap and retains no match array.
pub const Scan = struct {
    const chunk_size = 16 * 1024;
    const count_limit = 9999;
    revision: u64,
    selection_start: usize,
    selection_end: usize,
    chunk_start: usize = 0,
    cursor: usize = 0,
    count: usize = 0,
    capped: bool = false,
    first: ?usize = null,
    last: ?usize = null,
    next: ?usize = null,
    previous: ?usize = null,
    done: bool = false,

    pub fn init(document: *const Document) Scan {
        const selection = document.selection();
        return .{ .revision = document.revision, .selection_start = selection.start, .selection_end = selection.end };
    }

    /// Returns false for a stale revision; callers must restart rather than
    /// applying offsets from an older document.
    pub fn step(self: *Scan, document: *const Document, plan: *const search.SearchPlan) bool {
        if (document.large != null or document.revision != self.revision) return false;
        if (self.done) return true;
        const len = document.buffer.len();
        const chunk_end = @min(len, self.chunk_start +| chunk_size);
        const scan_end = @min(len, chunk_end +| (plan.pattern.len - 1));
        if (self.capped) {
            // Once the displayed count saturates, retain navigation candidates
            // with bounded scans instead of enumerating every remaining hit.
            const range: search.Range = .{ .start = self.cursor, .end = scan_end };
            if (plan.previous(&document.buffer, range, chunk_end)) |hit| self.last = hit;
            const previous_limit = @min(self.selection_start, chunk_end);
            if (previous_limit >= self.cursor) {
                if (plan.previous(&document.buffer, range, previous_limit)) |hit| self.previous = hit;
            }
            const next_start = @max(self.selection_end, self.cursor);
            if (self.next == null and next_start < chunk_end) {
                if (plan.next(&document.buffer, range, next_start)) |hit| {
                    if (hit < chunk_end) self.next = hit;
                }
            }
            self.chunk_start = chunk_end;
            self.cursor = chunk_end;
            self.done = chunk_end == len;
            return true;
        }
        var hits: [128]usize = undefined;
        const batch = plan.enumerate(&document.buffer, .{ .start = self.chunk_start, .end = scan_end }, self.cursor, &hits);
        var passed_chunk = false;
        for (hits[0..batch.written]) |hit| {
            if (hit >= chunk_end) {
                passed_chunk = true;
                break;
            }
            if (self.first == null) self.first = hit;
            self.last = hit;
            if (hit >= self.selection_end and self.next == null) self.next = hit;
            if (hit < self.selection_start) self.previous = hit;
            if (self.count < count_limit) self.count += 1 else self.capped = true;
        }
        if (passed_chunk or batch.cursor == null) {
            if (chunk_end == len) {
                self.done = true;
            } else {
                self.chunk_start = chunk_end;
                self.cursor = chunk_end;
            }
        } else {
            self.cursor = batch.cursor.?;
        }
        return true;
    }

    pub fn match(self: *const Scan, direction: Direction, wrap: bool) ?usize {
        if (!self.done) return null;
        return switch (direction) {
            .next => self.next orelse if (wrap) self.first else null,
            .previous => self.previous orelse if (wrap) self.last else null,
        };
    }
};

/// Revalidates the current selection against the query before replacing it.
/// A stale/mismatched selection is left untouched; Document validates replacement
/// UTF-8 and line limits before publishing its single undo transaction.
pub fn replaceCurrent(document: *Document, plan: *const search.SearchPlan, replacement: []const u8) !bool {
    if (document.large != null) return error.ReadOnlyLargeFile;
    const selected = document.selection();
    if (selected.end - selected.start != plan.pattern.len) return false;
    const range: search.Range = .{ .start = selected.start, .end = selected.end };
    const found = plan.next(&document.buffer, range, selected.start) orelse return false;
    if (found != selected.start) return false;
    try document.replaceRange(selected.start, selected.end, replacement);
    return true;
}

/// Selects the next match without changing text/history. A failed search leaves
/// the selection untouched. File-backed search needs an asynchronous controller.
pub fn selectMatch(document: *Document, plan: *const search.SearchPlan, direction: Direction, wrap: bool) !?search.Range {
    if (document.large != null) return error.LargeFileSearchUnavailable;
    const selection = document.selection();
    const whole: search.Range = .{ .start = 0, .end = document.buffer.len() };
    const found = switch (direction) {
        .next => plan.next(&document.buffer, whole, selection.end) orelse
            (if (wrap) plan.next(&document.buffer, whole, 0) else null),
        .previous => plan.previous(&document.buffer, whole, selection.start) orelse
            (if (wrap) plan.previous(&document.buffer, whole, whole.end) else null),
    } orelse return null;
    const result: search.Range = .{ .start = found, .end = found + plan.pattern.len };
    document.setSelection(result.start, result.end);
    return result;
}

test "find selection moves in both directions and wraps only when requested" {
    var doc = try Document.init(std.testing.allocator, "one é one", null);
    defer doc.deinit();
    var plan = try search.SearchPlan.init(std.testing.allocator, "one", false);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try selectMatch(&doc, &plan, .next, false)).?.start);
    try std.testing.expectEqual(@as(usize, 7), (try selectMatch(&doc, &plan, .next, false)).?.start);
    try std.testing.expect((try selectMatch(&doc, &plan, .next, false)) == null);
    try std.testing.expectEqual(@as(usize, 7), doc.anchor);
    try std.testing.expectEqual(@as(usize, 0), (try selectMatch(&doc, &plan, .next, true)).?.start);
    try std.testing.expectEqual(@as(usize, 7), (try selectMatch(&doc, &plan, .previous, true)).?.start);
    try std.testing.expectEqual(@as(usize, 0), (try selectMatch(&doc, &plan, .previous, false)).?.start);
    try std.testing.expectEqual(@as(usize, 0), doc.history.items.len);
    try std.testing.expect(!doc.dirty());
}

test "incremental scan crosses chunks, wraps, caps counts, and rejects revisions" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 40_000);
    defer allocator.free(bytes);
    @memset(bytes, 'a');
    @memcpy(bytes[16_383..16_386], "xyz");
    @memcpy(bytes[39_997..40_000], "xyz");
    var doc = try Document.init(allocator, bytes, null);
    defer doc.deinit();
    doc.setSelection(16_383, 16_386);
    var plan = try search.SearchPlan.init(allocator, "xyz", false);
    defer plan.deinit();
    var scan = Scan.init(&doc);
    while (!scan.done) try std.testing.expect(scan.step(&doc, &plan));
    try std.testing.expectEqual(@as(usize, 2), scan.count);
    try std.testing.expectEqual(@as(?usize, 39_997), scan.match(.next, false));
    try std.testing.expectEqual(@as(?usize, 39_997), scan.match(.previous, true));
    var dense = try search.SearchPlan.init(allocator, "a", false);
    defer dense.deinit();
    var dense_scan = Scan.init(&doc);
    var steps: usize = 0;
    while (!dense_scan.done) : (steps += 1) try std.testing.expect(dense_scan.step(&doc, &dense));
    try std.testing.expectEqual(@as(usize, 9999), dense_scan.count);
    try std.testing.expect(dense_scan.capped);
    try std.testing.expect(steps < 100);
    try std.testing.expectEqual(@as(?usize, 39_996), dense_scan.last);
    try std.testing.expectEqual(@as(?usize, 16_386), dense_scan.match(.next, false));
    try std.testing.expectEqual(@as(?usize, 16_382), dense_scan.match(.previous, false));
    try doc.insert("x");
    try std.testing.expect(!scan.step(&doc, &plan));
}

test "replace current revalidates selection and is one undo transaction" {
    var doc = try Document.init(std.testing.allocator, "é one ONE", null);
    defer doc.deinit();
    var plan = try search.SearchPlan.init(std.testing.allocator, "one", true);
    defer plan.deinit();
    _ = try selectMatch(&doc, &plan, .next, false);
    try std.testing.expect(try replaceCurrent(&doc, &plan, "中"));
    const actual = try doc.buffer.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("é 中 ONE", actual);
    try doc.undo();
    try std.testing.expect(!doc.dirty());
    doc.setSelection(0, 3);
    try std.testing.expect(!try replaceCurrent(&doc, &plan, "wrong"));
    try std.testing.expect(!doc.dirty());
    _ = try selectMatch(&doc, &plan, .next, false);
    const revision = doc.revision;
    try std.testing.expectError(error.InvalidUtf8, replaceCurrent(&doc, &plan, "\xff"));
    try std.testing.expectEqual(revision, doc.revision);
}
