//! Incremental Markdown line lexer. State stores fenced-code delimiter and length.
const std = @import("std");
const token = @import("token.zig");
const Sink = token.Sink;
pub fn lexLine(state: u32, line: []const u8, sink: *Sink) u32 {
    var i: usize = 0;
    var fence = state & 3;
    var flen = (state >> 2) & 0x3f;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (fence != 0) {
        if (i < line.len and line[i] == (if (fence == 1) @as(u8, '`') else @as(u8, '~'))) {
            var j = i;
            while (j < line.len and line[j] == line[i]) : (j += 1) {}
            if (j - i >= flen and std.mem.trim(u8, line[j..], " \t").len == 0) {
                sink.emit(i, j, .code);
                return 0;
            }
        }
        sink.emit(i, line.len, .code);
        return state;
    }
    if (i + 2 < line.len and line[i] == '#') {
        var j = i;
        while (j < line.len and line[j] == '#') : (j += 1) {}
        if (j - i <= 6 and (j == line.len or line[j] == ' ' or line[j] == '\t')) {
            sink.emit(i, line.len, .title);
            return 0;
        }
    }
    if (i + 2 < line.len and (line[i] == '`' or line[i] == '~')) {
        var j = i;
        while (j < line.len and line[j] == line[i]) : (j += 1) {}
        if (j - i >= 3) {
            fence = if (line[i] == '`') @as(u32, 1) else @as(u32, 2);
            flen = @intCast(j - i);
            sink.emit(i, j, .code);
            return fence | (flen << 2);
        }
    }
    if (i < line.len and line[i] == '>') sink.emit(i, i + 1, .quote);
    if (i < line.len and (line[i] == '-' or line[i] == '+' or line[i] == '*' or std.ascii.isDigit(line[i]))) {
        var j = i;
        if (std.ascii.isDigit(line[j])) {
            while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
        }
        if (j < line.len and (line[j] == '-' or line[j] == '+' or line[j] == '*') and (j == i or j - i < 4)) {
            sink.emit(i, j + 1, .list_marker);
        }
    }
    var k: usize = 0;
    while (k < line.len) {
        if (line[k] == '`') {
            var e = k + 1;
            while (e < line.len and line[e] != '`') : (e += 1) {}
            if (e < line.len) e += 1;
            sink.emit(k, e, .code);
            k = e;
            continue;
        }
        if (line[k] == '[') {
            if (std.mem.indexOfScalarPos(u8, line, k, ']')) |close| {
                if (close + 1 < line.len and line[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, line, close + 2, ')')) |end| {
                        sink.emit(k, close + 1, .link_text);
                        sink.emit(close + 1, end + 1, .link_uri);
                        k = end + 1;
                        continue;
                    }
                }
            }
        }
        if (line[k] == '*' or line[k] == '_') {
            const n: usize = if (k + 1 < line.len and line[k + 1] == line[k]) 2 else 1;
            if (std.mem.indexOfScalarPos(u8, line, k + n, line[k])) |e| {
                if (e > k + n) sink.emit(k, e + n, if (n == 2) .strong else .emphasis);
                k = e + n;
                continue;
            }
        }
        k += 1;
    }
    return 0;
}
test "Markdown fenced code spans lines" {
    var b: [32]token.Span = undefined;
    var s = Sink.init(&b);
    const n = lexLine(0, "```zig", &s);
    try std.testing.expect(n != 0);
    s = Sink.init(&b);
    try std.testing.expectEqual(n, lexLine(n, "const x = 1;", &s));
    s = Sink.init(&b);
    try std.testing.expectEqual(@as(u32, 0), lexLine(n, "```", &s));
}
test "Markdown random span bounds" {
    var p = std.Random.DefaultPrng.init(0xada);
    const r = p.random();
    var l: [80]u8 = undefined;
    var b: [128]token.Span = undefined;
    for (0..500) |_| {
        const n = r.uintLessThan(usize, 81);
        for (l[0..n]) |*c| c.* = r.int(u8);
        var s = Sink.init(&b);
        _ = lexLine(0, l[0..n], &s);
        var e: u32 = 0;
        for (s.items()) |x| {
            try std.testing.expect(x.start < x.end);
            try std.testing.expect(x.start >= e);
            try std.testing.expect(x.end <= n);
            e = x.end;
        }
    }
}
