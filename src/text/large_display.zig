//! Bounded decoding of a single LF-delimited byte window. No file I/O.
const std = @import("std");

pub const Result = struct { consumed: usize, written: usize, newline: bool, truncated: bool };

/// Decodes one logical line into valid UTF-8. Tabs advance to tab stops;
/// CR before LF is omitted. Invalid bytes and controls become U+FFFD.
/// The input may end mid-line or mid-codepoint; incomplete input is not
/// consumed unless `eof` is true. Output exhaustion never splits a codepoint.
pub fn decodeLine(input: []const u8, output: []u8, tab_width: usize, eof: bool) Result {
    var i: usize = 0;
    var o: usize = 0;
    var column: usize = 0;
    while (i < input.len) {
        const b = input[i];
        if (b == '\n') return .{ .consumed = i + 1, .written = o, .newline = true, .truncated = false };
        if (b == '\r' and i + 1 == input.len and !eof) break;
        if (b == '\r' and i + 1 < input.len and input[i + 1] == '\n') {
            i += 1;
            continue;
        }
        if (b == '\t') {
            const width = @max(tab_width, 1);
            const spaces = width - column % width;
            if (spaces > output.len - o) break;
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
        @memcpy(output[o..][0..bytes.len], bytes);
        o += bytes.len;
        i += if (valid == null) 1 else len;
        column += 1;
    }
    return .{ .consumed = i, .written = o, .newline = false, .truncated = i < input.len or !eof };
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
