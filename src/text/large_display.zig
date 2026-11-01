//! Bounded decoding of a single LF-delimited byte window. No file I/O.
const std = @import("std");

pub const Result = struct { consumed: usize, written: usize, newline: bool, truncated: bool, selection: ?Selection = null, selected_newline: bool = false };
pub const Selection = struct { start: usize, end: usize };

/// Decodes one logical line into valid UTF-8. Tabs advance to tab stops;
/// CR before LF is omitted. Invalid bytes and controls become U+FFFD.
/// The input may end mid-line or mid-codepoint; incomplete input is not
/// consumed unless `eof` is true. Output exhaustion never splits a codepoint.
pub fn decodeLine(input: []const u8, output: []u8, tab_width: usize, eof: bool) Result {
    return decodeSelected(input, output, tab_width, eof, null);
}

/// Selection is relative to input. Any selected byte of a decoded character
/// selects the whole displayed character; output offsets are UTF-8 boundaries.
pub fn decodeSelected(input: []const u8, output: []u8, tab_width: usize, eof: bool, selected: ?Selection) Result {
    var mapped: ?Selection = null;
    var i: usize = 0;
    var o: usize = 0;
    var column: usize = 0;
    while (i < input.len) {
        const b = input[i];
        if (b == '\n') return .{ .consumed = i + 1, .written = o, .newline = true, .truncated = false, .selection = mapped, .selected_newline = overlaps(selected, i, i + 1) };
        if (b == '\r' and i + 1 == input.len and !eof) break;
        if (b == '\r' and i + 1 < input.len and input[i + 1] == '\n') {
            return .{ .consumed = i + 2, .written = o, .newline = true, .truncated = false, .selection = mapped, .selected_newline = overlaps(selected, i, i + 2) };
        }
        if (b == '\t') {
            const width = @max(tab_width, 1);
            const spaces = width - column % width;
            if (spaces > output.len - o) break;
            mark(&mapped, selected, i, i + 1, o, o + spaces);
            @memset(output[o..][0..spaces], ' ');
            o += spaces;
            i += 1;
            column += spaces;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(b) catch 0;
        const len: usize = if (sequence_len == 0) 1 else sequence_len;
        if (len > input.len - i and !eof) break;
        const valid: ?u21 = if (sequence_len != 0 and len <= input.len - i) std.unicode.utf8Decode(input[i..][0..len]) catch null else null;
        const cp = valid orelse 0xfffd;
        const replace = cp < 0x20 or (cp >= 0x7f and cp < 0xa0) or valid == null;
        const bytes = if (replace) "\xef\xbf\xbd" else input[i..][0..len];
        if (bytes.len > output.len - o) break;
        const consumed = if (valid == null) @as(usize, 1) else len;
        mark(&mapped, selected, i, i + consumed, o, o + bytes.len);
        @memcpy(output[o..][0..bytes.len], bytes);
        o += bytes.len;
        i += if (valid == null) 1 else len;
        column += 1;
    }
    return .{ .consumed = i, .written = o, .newline = false, .truncated = i < input.len or !eof, .selection = mapped };
}

fn overlaps(selection: ?Selection, start: usize, end: usize) bool {
    const s = selection orelse return false;
    return s.start < s.end and s.start < end and s.end > start;
}

fn mark(mapped: *?Selection, selected: ?Selection, start: usize, end: usize, out_start: usize, out_end: usize) void {
    if (!overlaps(selected, start, end)) return;
    if (mapped.*) |*m| m.end = out_end else mapped.* = .{ .start = out_start, .end = out_end };
}

test "selection maps decoded units and line endings" {
    var out: [64]u8 = undefined;
    const bytes = "aé\t中\xff\r\n";
    const r = decodeSelected(bytes, &out, 4, true, .{ .start = 2, .end = 9 });
    try std.testing.expectEqualStrings("aé  中�", out[0..r.written]);
    try std.testing.expectEqual(@as(usize, 1), r.selection.?.start);
    try std.testing.expectEqual(r.written, r.selection.?.end);
    try std.testing.expect(r.selected_newline);
    const cr = decodeSelected(bytes, &out, 4, true, .{ .start = 8, .end = 9 });
    try std.testing.expect(cr.selection == null);
    try std.testing.expect(cr.selected_newline);
}

test "selection respects truncation and incomplete windows" {
    var out: [4]u8 = undefined;
    const limited = decodeSelected("abéZ\n", &out, 4, true, .{ .start = 3, .end = 6 });
    try std.testing.expectEqual(@as(usize, 2), limited.selection.?.start);
    try std.testing.expectEqual(@as(usize, 4), limited.selection.?.end);
    try std.testing.expect(!limited.selected_newline);
    try std.testing.expect(limited.truncated);
    const partial = decodeSelected("\xb8X\xe4\xb8", &out, 4, false, .{ .start = 0, .end = 4 });
    try std.testing.expectEqualStrings("�X", out[0..partial.written]);
    try std.testing.expectEqual(@as(usize, 4), partial.selection.?.end);
    try std.testing.expectEqual(@as(usize, 2), partial.consumed);
}

test "UTF-8, tabs, CRLF and invalid controls" {
    var output: [64]u8 = undefined;
    const result = decodeLine("é\t中\r\nrest", &output, 4, false);
    try std.testing.expectEqualStrings("é   中", output[0..result.written]);
    try std.testing.expect(result.newline);
    const invalid = decodeLine("\xff\x00", &output, 4, true);
    try std.testing.expectEqualStrings("��", output[0..invalid.written]);
}

test "partial codepoints, output limits and trailing empty line" {
    var output: [4]u8 = undefined;
    const partial = decodeLine("a\xe4\xb8", &output, 4, false);
    try std.testing.expectEqual(@as(usize, 1), partial.consumed);
    try std.testing.expect(partial.truncated);
    const limited = decodeLine("é中\n", &output, 4, true);
    try std.testing.expectEqual(@as(usize, 2), limited.consumed);
    try std.testing.expect(limited.truncated);
    const empty = decodeLine("", &output, 4, true);
    try std.testing.expectEqual(@as(usize, 0), empty.written);
    try std.testing.expect(!empty.truncated);
}
