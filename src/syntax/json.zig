//! JSON/JSONC lexer. Carries block-comment state for JSONC; JSON strings cannot span lines.
const std = @import("std");
const token = @import("token.zig");
const Sink = token.Sink;
pub fn lexLine(state: u32, line: []const u8, sink: *Sink) u32 {
    var i: usize = 0;
    var block = state & 1;
    while (i < line.len) {
        const s = i;
        if (block != 0) {
            while (i < line.len) {
                if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                    i += 2;
                    block = 0;
                    break;
                }
                i += 1;
            }
            sink.emit(s, i, .comment);
            continue;
        }
        const c = line[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (i + 1 < line.len and c == '/' and line[i + 1] == '/') {
            sink.emit(i, line.len, .comment);
            break;
        }
        if (i + 1 < line.len and c == '/' and line[i + 1] == '*') {
            block = 1;
            const e = if (std.mem.indexOf(u8, line[i + 2 ..], "*/")) |r| i + 2 + r + 2 else line.len;
            sink.emit(i, e, .comment);
            i = e;
            if (e < line.len or (e >= 2 and std.mem.eql(u8, line[e - 2 .. e], "*/"))) block = 0;
            continue;
        }
        if (c == '"') {
            i += 1;
            var run = s;
            while (i < line.len) {
                if (line[i] == '\\') {
                    sink.emit(run, i, .string);
                    const e = @min(i + 2, line.len);
                    sink.emit(i, e, .string_escape);
                    i = e;
                    run = i;
                    continue;
                }
                if (line[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            sink.emit(run, i, .string);
            continue;
        }
        if (std.ascii.isDigit(c) or c == '-') {
            i += 1;
            while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '.' or line[i] == '+' or line[i] == '-')) : (i += 1) {}
            sink.emit(s, i, .number);
            continue;
        }
        if (std.ascii.isAlphabetic(c)) {
            i += 1;
            while (i < line.len and std.ascii.isAlphabetic(line[i])) : (i += 1) {}
            const w = line[s..i];
            if (std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "false") or std.mem.eql(u8, w, "null")) sink.emit(s, i, .constant);
            continue;
        }
        if (std.mem.indexOfScalar(u8, "{}[]:,", c) != null) sink.emit(i, i + 1, .punctuation) else if (c == '/') sink.emit(i, i + 1, .operator);
        i += 1;
    }
    return block;
}
test "JSONC block comment crosses lines" {
    var b: [16]token.Span = undefined;
    var s = Sink.init(&b);
    var n = lexLine(0, "{ /* open", &s);
    try std.testing.expectEqual(@as(u32, 1), n);
    s = Sink.init(&b);
    n = lexLine(n, "end */ \"x\": true", &s);
    try std.testing.expectEqual(@as(u32, 0), n);
}
test "JSON random span bounds" {
    var p = std.Random.DefaultPrng.init(0x2020);
    const r = p.random();
    var l: [80]u8 = undefined;
    var b: [128]token.Span = undefined;
    for (0..500) |_| {
        const n = r.uintLessThan(usize, 81);
        for (l[0..n]) |*c| c.* = r.int(u8);
        var s = Sink.init(&b);
        _ = lexLine(r.uintLessThan(u32, 2), l[0..n], &s);
        var e: u32 = 0;
        for (s.items()) |x| {
            try std.testing.expect(x.start < x.end);
            try std.testing.expect(x.start >= e);
            try std.testing.expect(x.end <= n);
            e = x.end;
        }
    }
}
