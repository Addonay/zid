//! Editor commands behind Zed's `editor::*` actions, independent of SDL and rendering.
//! Each mutating command is one undo step. Word motion uses Zed's character classes
//! (whitespace, word, punctuation); line commands operate on every line the selection touches.
const std = @import("std");
const Document = @import("document.zig").Document;

const Class = enum { space, word, punct };

fn classOf(b: u8) Class {
    if (b == ' ' or b == '\t' or b == '\n' or b == '\r') return .space;
    if (std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80) return .word;
    return .punct;
}

/// Zed `MoveToPreviousWordStart`: skip whitespace, then a run of one class.
pub fn previousWordStart(doc: *const Document, from: usize) usize {
    var i = from;
    while (i > 0 and classOf(doc.buffer.byteAt(i - 1)) == .space) i -= 1;
    if (i == 0) return 0;
    const class = classOf(doc.buffer.byteAt(i - 1));
    while (i > 0 and classOf(doc.buffer.byteAt(i - 1)) == class) i -= 1;
    return i;
}

/// Zed `MoveToNextWordEnd`: skip whitespace, then a run of one class.
pub fn nextWordEnd(doc: *const Document, from: usize) usize {
    const len = doc.buffer.len();
    var i = from;
    while (i < len and classOf(doc.buffer.byteAt(i)) == .space) i += 1;
    if (i == len) return len;
    const class = classOf(doc.buffer.byteAt(i));
    while (i < len and classOf(doc.buffer.byteAt(i)) == class) i += 1;
    return i;
}

/// The word under `at` (for double-click selection and SelectNext seeding).
pub fn wordAt(doc: *const Document, at: usize) struct { start: usize, end: usize } {
    var start = at;
    var end = at;
    while (start > 0 and classOf(doc.buffer.byteAt(start - 1)) == .word) start -= 1;
    while (end < doc.buffer.len() and classOf(doc.buffer.byteAt(end)) == .word) end += 1;
    return .{ .start = start, .end = end };
}

pub fn firstNonBlank(doc: *const Document, row: usize) usize {
    var i = doc.lineStart(row);
    const end = doc.lineEnd(row);
    while (i < end and (doc.buffer.byteAt(i) == ' ' or doc.buffer.byteAt(i) == '\t')) i += 1;
    return i;
}

/// Zed `MoveToBeginningOfLine { stop_at_indent }`: toggles between indent and column 0.
pub fn smartHome(doc: *const Document, at: usize, stop_at_indent: bool) usize {
    const row = doc.lineOf(at);
    const start = doc.lineStart(row);
    if (!stop_at_indent) return start;
    const indent = firstNonBlank(doc, row);
    return if (at == indent) start else indent;
}

pub fn moveTo(doc: *Document, offset: usize, extend: bool) void {
    doc.move(offset, extend);
}

pub fn selectAll(doc: *Document) void {
    doc.setSelection(0, doc.buffer.len());
}

/// Lines touched by the selection: [first, last] rows and their byte span including
/// the trailing newline (when present).
const LineSpan = struct { first: usize, last: usize, start: usize, end: usize };
fn selectedLines(doc: *const Document) LineSpan {
    const sel = doc.selection();
    const first = doc.lineOf(sel.start);
    var last = doc.lineOf(sel.end);
    // A selection ending at column 0 of a later line does not include that line.
    if (last > first and sel.end == doc.lineStart(last)) last -= 1;
    const start = doc.lineStart(first);
    const end = if (last + 1 < doc.lineCount()) doc.lineStart(last + 1) else doc.buffer.len();
    return .{ .first = first, .last = last, .start = start, .end = end };
}

/// Zed `SelectLine`: extend the selection to whole lines (repeat to grow downward).
pub fn selectLine(doc: *Document) void {
    const span = selectedLines(doc);
    const already = doc.selection().start == span.start and doc.selection().end == span.end;
    doc.anchor = span.start;
    if (already and span.end < doc.buffer.len()) {
        const next = doc.lineOf(span.end);
        doc.cursor = if (next + 1 < doc.lineCount()) doc.lineStart(next + 1) else doc.buffer.len();
    } else doc.cursor = span.end;
}

fn copyRange(doc: *const Document, gpa: std.mem.Allocator, start: usize, end: usize) ![]u8 {
    const out = try gpa.alloc(u8, end - start);
    doc.buffer.copy(start, out);
    return out;
}

fn newline(doc: *const Document) []const u8 {
    return if (doc.crlf) "\r\n" else "\n";
}

/// Leading whitespace of `row`.
fn indentOf(doc: *const Document, gpa: std.mem.Allocator, row: usize) ![]u8 {
    return copyRange(doc, gpa, doc.lineStart(row), firstNonBlank(doc, row));
}

/// Zed `Newline` with auto-indent: the new line keeps the current line's indentation.
pub fn newlineIndented(doc: *Document, gpa: std.mem.Allocator) !void {
    const row = doc.lineOf(doc.selection().start);
    const indent = try indentOf(doc, gpa, row);
    defer gpa.free(indent);
    const text = try std.mem.concat(gpa, u8, &.{ newline(doc), indent });
    defer gpa.free(text);
    try doc.insert(text);
}

/// Zed `NewlineBelow` / `NewlineAbove`.
pub fn newlineBelow(doc: *Document, gpa: std.mem.Allocator) !void {
    const row = doc.lineOf(doc.cursor);
    const indent = try indentOf(doc, gpa, row);
    defer gpa.free(indent);
    const at = doc.lineEnd(row);
    const text = try std.mem.concat(gpa, u8, &.{ newline(doc), indent });
    defer gpa.free(text);
    try doc.replaceRange(at, at, text);
}
pub fn newlineAbove(doc: *Document, gpa: std.mem.Allocator) !void {
    const row = doc.lineOf(doc.cursor);
    const indent = try indentOf(doc, gpa, row);
    defer gpa.free(indent);
    const at = doc.lineStart(row);
    const text = try std.mem.concat(gpa, u8, &.{ indent, newline(doc) });
    defer gpa.free(text);
    try doc.replaceRange(at, at, text);
    doc.setSelection(at + indent.len, at + indent.len);
}

/// Zed `DeleteToPreviousWordStart` / `DeleteToNextWordEnd`; a selection is deleted as-is.
pub fn deleteToPreviousWordStart(doc: *Document) !void {
    const previous_anchor = doc.anchor;
    errdefer doc.anchor = previous_anchor;
    if (doc.cursor == doc.anchor) doc.anchor = previousWordStart(doc, doc.cursor);
    try doc.insert("");
}
pub fn deleteToNextWordEnd(doc: *Document) !void {
    const previous_anchor = doc.anchor;
    errdefer doc.anchor = previous_anchor;
    if (doc.cursor == doc.anchor) doc.anchor = nextWordEnd(doc, doc.cursor);
    try doc.insert("");
}
/// Zed `DeleteToBeginningOfLine` / `DeleteToEndOfLine`.
pub fn deleteToLineStart(doc: *Document) !void {
    const previous_anchor = doc.anchor;
    errdefer doc.anchor = previous_anchor;
    if (doc.cursor == doc.anchor) doc.anchor = doc.lineStart(doc.lineOf(doc.cursor));
    try doc.insert("");
}
pub fn deleteToLineEnd(doc: *Document) !void {
    const previous_anchor = doc.anchor;
    errdefer doc.anchor = previous_anchor;
    if (doc.cursor == doc.anchor) doc.anchor = doc.lineEnd(doc.lineOf(doc.cursor));
    try doc.insert("");
}

/// Zed `DeleteLine`: removes every selected line including its newline.
pub fn deleteLine(doc: *Document) !void {
    const span = selectedLines(doc);
    var start = span.start;
    // Deleting the final line also removes the newline before it.
    if (span.end == doc.buffer.len() and start > 0 and span.last + 1 == doc.lineCount()) {
        start -= 1;
        if (start > 0 and doc.crlf and doc.buffer.byteAt(start - 1) == '\r') start -= 1;
    }
    try doc.replaceRange(start, span.end, "");
    doc.setSelection(start, start);
}

/// Zed `MoveLineUp` / `MoveLineDown`: swaps the selected block with the neighbouring line.
pub fn moveLines(doc: *Document, gpa: std.mem.Allocator, down: bool) !void {
    const span = selectedLines(doc);
    if (!down and span.first == 0) return;
    if (down and span.last + 1 >= doc.lineCount()) return;
    const cursor_rel = doc.cursor - span.start;
    const anchor_rel = doc.anchor - span.start;
    const nl = newline(doc);
    const block = try copyRange(doc, gpa, span.start, span.end);
    defer gpa.free(block);
    if (down) {
        const other_start = span.end;
        const other_end = if (span.last + 2 < doc.lineCount()) doc.lineStart(span.last + 2) else doc.buffer.len();
        const other = try copyRange(doc, gpa, other_start, other_end);
        defer gpa.free(other);
        // The last line has no newline; move it to the block that becomes last.
        const other_has_nl = std.mem.endsWith(u8, other, "\n");
        const text = if (other_has_nl)
            try std.mem.concat(gpa, u8, &.{ other, block })
        else
            try std.mem.concat(gpa, u8, &.{ other, nl, block[0 .. block.len - trailingNewline(block)] });
        defer gpa.free(text);
        try doc.replaceRange(span.start, other_end, text);
        const shift = other.len + @as(usize, if (other_has_nl) 0 else nl.len);
        doc.setSelection(span.start + shift + anchor_rel, span.start + shift + cursor_rel);
    } else {
        const other_start = doc.lineStart(span.first - 1);
        const other = try copyRange(doc, gpa, other_start, span.start);
        defer gpa.free(other);
        const block_has_nl = trailingNewline(block) > 0;
        const text = if (block_has_nl)
            try std.mem.concat(gpa, u8, &.{ block, other })
        else
            try std.mem.concat(gpa, u8, &.{ block, nl, other[0 .. other.len - trailingNewline(other)] });
        defer gpa.free(text);
        try doc.replaceRange(other_start, span.end, text);
        doc.setSelection(other_start + anchor_rel, other_start + cursor_rel);
    }
}

fn trailingNewline(bytes: []const u8) usize {
    if (std.mem.endsWith(u8, bytes, "\r\n")) return 2;
    if (std.mem.endsWith(u8, bytes, "\n")) return 1;
    return 0;
}

/// Zed `DuplicateLineDown` / `DuplicateLineUp`.
pub fn duplicateLines(doc: *Document, gpa: std.mem.Allocator, down: bool) !void {
    const span = selectedLines(doc);
    const block = try copyRange(doc, gpa, span.start, span.end);
    defer gpa.free(block);
    const cursor_rel = doc.cursor - span.start;
    const anchor_rel = doc.anchor - span.start;
    const has_nl = trailingNewline(block) > 0;
    const text = if (has_nl) try gpa.dupe(u8, block) else try std.mem.concat(gpa, u8, &.{ newline(doc), block });
    defer gpa.free(text);
    const at = span.end;
    try doc.replaceRange(at, at, text);
    if (down) {
        const base = if (has_nl) at else at + newline(doc).len;
        doc.setSelection(base + anchor_rel, base + cursor_rel);
    } else {
        doc.setSelection(span.start + anchor_rel, span.start + cursor_rel);
    }
}

/// Zed `Indent` / `Outdent` (and Tab/Shift-Tab over multi-line selections).
pub fn indentLines(doc: *Document, gpa: std.mem.Allocator, tab_size: usize, outdent: bool) !void {
    const span = selectedLines(doc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var removed_first: usize = 0;
    var total_delta: isize = 0;
    for (span.first..span.last + 1) |row| {
        const start = doc.lineStart(row);
        const end = if (row + 1 < doc.lineCount()) doc.lineStart(row + 1) else doc.buffer.len();
        const line = try copyRange(doc, gpa, start, end);
        defer gpa.free(line);
        if (outdent) {
            var n: usize = 0;
            while (n < tab_size and n < line.len and line[n] == ' ') n += 1;
            if (n == 0 and line.len > 0 and line[0] == '\t') n = 1;
            if (row == span.first) removed_first = n;
            total_delta -= @intCast(n);
            try out.appendSlice(gpa, line[n..]);
        } else {
            const blank = std.mem.trim(u8, line, " \t\r\n").len == 0;
            if (!blank or span.first == span.last) {
                try out.appendNTimes(gpa, ' ', tab_size);
                total_delta += @intCast(tab_size);
            }
            try out.appendSlice(gpa, line);
        }
    }
    const sel = doc.selection();
    const forward = doc.cursor >= doc.anchor;
    try doc.replaceRange(span.start, span.end, out.items);
    const first_delta: isize = if (outdent) -@as(isize, @intCast(removed_first)) else @intCast(tab_size);
    const new_start: usize = @intCast(@max(@as(isize, @intCast(span.start)), @as(isize, @intCast(sel.start)) + first_delta));
    const new_end: usize = @intCast(@max(@as(isize, @intCast(new_start)), @as(isize, @intCast(sel.end)) + total_delta));
    doc.setSelection(if (forward) new_start else new_end, if (forward) new_end else new_start);
}

/// Zed `ToggleComments`: comments every selected line at the shallowest indent, or
/// uncomments when all non-blank lines already start with `prefix`.
pub fn toggleComments(doc: *Document, gpa: std.mem.Allocator, prefix: []const u8) !void {
    if (prefix.len == 0) return;
    const span = selectedLines(doc);
    var all_commented = true;
    var min_indent: usize = std.math.maxInt(usize);
    for (span.first..span.last + 1) |row| {
        const indent = firstNonBlank(doc, row);
        if (indent == doc.lineEnd(row)) continue;
        min_indent = @min(min_indent, indent - doc.lineStart(row));
        const len = @min(prefix.len, doc.lineEnd(row) - indent);
        const head = try copyRange(doc, gpa, indent, indent + len);
        defer gpa.free(head);
        if (!std.mem.eql(u8, head, prefix)) all_commented = false;
    }
    if (min_indent == std.math.maxInt(usize)) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (span.first..span.last + 1) |row| {
        const start = doc.lineStart(row);
        const end = if (row + 1 < doc.lineCount()) doc.lineStart(row + 1) else doc.buffer.len();
        const line = try copyRange(doc, gpa, start, end);
        defer gpa.free(line);
        const content_end = doc.lineEnd(row) - start;
        const indent = firstNonBlank(doc, row) - start;
        if (indent == content_end) {
            try out.appendSlice(gpa, line);
        } else if (all_commented) {
            var cut = indent + prefix.len;
            if (cut < content_end and line[cut] == ' ') cut += 1;
            try out.appendSlice(gpa, line[0..indent]);
            try out.appendSlice(gpa, line[cut..]);
        } else {
            try out.appendSlice(gpa, line[0..min_indent]);
            try out.appendSlice(gpa, prefix);
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, line[min_indent..]);
        }
    }
    try doc.replaceRange(span.start, span.end, out.items);
    doc.setSelection(span.start, span.start + out.items.len - @min(out.items.len, trailingNewline(out.items)));
}

/// Zed `JoinLines`: joins the selected lines (or the current line and the next) with single spaces.
pub fn joinLines(doc: *Document, gpa: std.mem.Allocator) !void {
    var span = selectedLines(doc);
    if (span.first == span.last) {
        if (span.last + 1 >= doc.lineCount()) return;
        span.last += 1;
        span.end = if (span.last + 1 < doc.lineCount()) doc.lineStart(span.last + 1) else doc.buffer.len();
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var join_at: usize = 0;
    for (span.first..span.last + 1) |row| {
        const start = if (row == span.first) doc.lineStart(row) else firstNonBlank(doc, row);
        const line = try copyRange(doc, gpa, start, doc.lineEnd(row));
        defer gpa.free(line);
        const trimmed = std.mem.trimEnd(u8, line, " \t");
        if (row > span.first and trimmed.len > 0 and out.items.len > 0) try out.append(gpa, ' ');
        if (row == span.last) join_at = out.items.len;
        try out.appendSlice(gpa, trimmed);
    }
    const end = doc.lineEnd(span.last);
    try doc.replaceRange(span.start, end, out.items);
    doc.setSelection(span.start + join_at, span.start + join_at);
}

/// Text copied by Copy/Cut with an empty selection: Zed copies the whole line.
pub fn clipboardRange(doc: *const Document) struct { start: usize, end: usize, whole_line: bool } {
    const sel = doc.selection();
    if (sel.start != sel.end) return .{ .start = sel.start, .end = sel.end, .whole_line = false };
    const row = doc.lineOf(doc.cursor);
    const end = if (row + 1 < doc.lineCount()) doc.lineStart(row + 1) else doc.buffer.len();
    return .{ .start = doc.lineStart(row), .end = end, .whole_line = true };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectText(doc: *Document, expected: []const u8) !void {
    const actual = try doc.buffer.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "word motion uses whitespace, word and punctuation classes" {
    var doc = try Document.init(testing.allocator, "foo.bar  baz_1()", null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), nextWordEnd(&doc, 0));
    try testing.expectEqual(@as(usize, 4), nextWordEnd(&doc, 3));
    try testing.expectEqual(@as(usize, 14), nextWordEnd(&doc, 7));
    try testing.expectEqual(@as(usize, 9), previousWordStart(&doc, 14));
    try testing.expectEqual(@as(usize, 4), previousWordStart(&doc, 9));
}

test "smart home toggles between indent and column zero" {
    var doc = try Document.init(testing.allocator, "    let x;", null);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 4), smartHome(&doc, 8, true));
    try testing.expectEqual(@as(usize, 0), smartHome(&doc, 4, true));
}

test "move, duplicate and delete lines are single undo steps" {
    var doc = try Document.init(testing.allocator, "a\nb\nc", null);
    defer doc.deinit();
    doc.move(2, false);
    try moveLines(&doc, testing.allocator, true);
    try expectText(&doc, "a\nc\nb");
    try testing.expectEqual(@as(usize, 4), doc.cursor);
    try moveLines(&doc, testing.allocator, false);
    try expectText(&doc, "a\nb\nc");
    try doc.undo();
    try expectText(&doc, "a\nc\nb");
    try doc.redo();
    try duplicateLines(&doc, testing.allocator, true);
    try expectText(&doc, "a\nb\nb\nc");
    try testing.expectEqual(@as(usize, 4), doc.cursor);
    try deleteLine(&doc);
    try expectText(&doc, "a\nb\nc");
    doc.move(doc.buffer.len(), false);
    try deleteLine(&doc);
    try expectText(&doc, "a\nb");
}

test "indent, outdent and comments act on every selected line" {
    var doc = try Document.init(testing.allocator, "fn a() {\n    x();\n}", null);
    defer doc.deinit();
    doc.move(0, false);
    doc.move(doc.buffer.len(), true);
    try toggleComments(&doc, testing.allocator, "//");
    try expectText(&doc, "// fn a() {\n//     x();\n// }");
    try toggleComments(&doc, testing.allocator, "//");
    try expectText(&doc, "fn a() {\n    x();\n}");
    try indentLines(&doc, testing.allocator, 4, false);
    try expectText(&doc, "    fn a() {\n        x();\n    }");
    try indentLines(&doc, testing.allocator, 4, true);
    try expectText(&doc, "fn a() {\n    x();\n}");
}

test "newlines keep indentation and join lines collapses whitespace" {
    var doc = try Document.init(testing.allocator, "    foo\n    bar", null);
    defer doc.deinit();
    doc.move(7, false);
    try newlineIndented(&doc, testing.allocator);
    try expectText(&doc, "    foo\n    \n    bar");
    try doc.undo();
    doc.move(0, false);
    try joinLines(&doc, testing.allocator);
    try expectText(&doc, "    foo bar");
    doc.move(2, false);
    try newlineBelow(&doc, testing.allocator);
    try expectText(&doc, "    foo bar\n    ");
}

test "copy with no selection takes the whole line" {
    var doc = try Document.init(testing.allocator, "one\ntwo", null);
    defer doc.deinit();
    doc.move(5, false);
    const r = clipboardRange(&doc);
    try testing.expect(r.whole_line);
    try testing.expectEqual(@as(usize, 4), r.start);
    try testing.expectEqual(@as(usize, 7), r.end);
}
