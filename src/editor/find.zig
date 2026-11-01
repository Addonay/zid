//! Selection controller for literal search in editable, memory-backed documents.
const std = @import("std");
const Document = @import("document.zig").Document;
const search = @import("search.zig");

pub const Direction = enum { next, previous };

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
