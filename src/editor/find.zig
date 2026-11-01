//! Selection controller for literal search in editable, memory-backed documents.
const std = @import("std");
const Document = @import("document.zig").Document;
const search = @import("search.zig");

pub const Direction = enum { next, previous };

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
