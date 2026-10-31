//! Incremental, byte-oriented Python syntax lexer. State 1/2 carries triple quotes.
const std = @import("std");
const token = @import("token.zig");
const Sink = token.Sink;
const Kind = token.Kind;
const keywords = std.StaticStringMap(Kind).initComptime(.{
    .{ "and", .keyword_control }, .{ "as", .keyword }, .{ "assert", .keyword_control }, .{ "async", .keyword }, .{ "await", .keyword_control }, .{ "break", .keyword_control }, .{ "class", .keyword }, .{ "continue", .keyword_control }, .{ "def", .keyword }, .{ "del", .keyword }, .{ "elif", .keyword_control }, .{ "else", .keyword_control }, .{ "except", .keyword_control }, .{ "finally", .keyword_control }, .{ "for", .keyword_control }, .{ "from", .keyword }, .{ "global", .keyword }, .{ "if", .keyword_control }, .{ "import", .keyword }, .{ "in", .keyword_control }, .{ "is", .keyword_control }, .{ "lambda", .keyword }, .{ "nonlocal", .keyword }, .{ "not", .keyword_control }, .{ "or", .keyword_control }, .{ "pass", .keyword_control }, .{ "raise", .keyword_control }, .{ "return", .keyword_control }, .{ "try", .keyword_control }, .{ "while", .keyword_control }, .{ "with", .keyword_control }, .{ "yield", .keyword_control },
});
fn ident(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
pub fn lexLine(state: u32, line: []const u8, sink: *Sink) u32 {
    var i: usize = 0;
    var mode = state & 3;
    var quote: u8 = if (mode == 1) '\'' else if (mode == 2) '"' else 0;
    while (i < line.len) {
        if (mode != 0) {
            const s = i;
            while (i < line.len) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2;
                    continue;
                }
                if (i + 2 < line.len and line[i] == quote and line[i + 1] == quote and line[i + 2] == quote) {
                    i += 3;
                    mode = 0;
                    break;
                }
                i += 1;
            }
            sink.emit(s, i, .string);
            continue;
        }
        const c = line[i];
        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        if (c == '#') {
            sink.emit(i, line.len, .comment);
            break;
        }
        if ((c == '\'' or c == '"') and i + 2 < line.len and line[i + 1] == c and line[i + 2] == c) {
            quote = c;
            mode = if (c == '\'') 1 else 2;
            const s = i;
            i += 3;
            while (i < line.len) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2;
                    continue;
                }
                if (i + 2 < line.len and line[i] == c and line[i + 1] == c and line[i + 2] == c) {
                    i += 3;
                    mode = 0;
                    break;
                }
                i += 1;
            }
            sink.emit(s, i, .string);
            continue;
        }
        if (c == '\'' or c == '"') {
            const s = i;
            i += 1;
            while (i < line.len) {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2;
                    continue;
                }
                if (line[i] == c) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            sink.emit(s, i, .string);
            continue;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const s = i;
            i += 1;
            while (i < line.len and ident(line[i])) : (i += 1) {}
            const word = line[s..i];
            if (std.mem.eql(u8, word, "True") or std.mem.eql(u8, word, "False") or std.mem.eql(u8, word, "None")) sink.emit(s, i, .constant) else if (keywords.get(word)) |k| sink.emit(s, i, k) else if (i < line.len and line[i] == '(') sink.emit(s, i, .function) else if (s > 0 and line[s - 1] == '.') sink.emit(s, i, .property);
            continue;
        }
        if (std.ascii.isDigit(c)) {
            const s = i;
            i += 1;
            while (i < line.len and (ident(line[i]) or line[i] == '.')) : (i += 1) {}
            sink.emit(s, i, .number);
            continue;
        }
        if (std.mem.indexOfScalar(u8, "()[]{}:,. ;", c) != null) sink.emit(i, i + 1, .punctuation) else if (std.mem.indexOfScalar(u8, "+-*/%=<>!&|^~@", c) != null) sink.emit(i, i + 1, if (c == '@' and (i == 0 or std.mem.trim(u8, line[0..i], " \t").len == 0)) .attribute else .operator);
        i += 1;
    }
    return mode;
}
test "Python triple strings carry state" {
    var b: [32]token.Span = undefined;
    var s = Sink.init(&b);
    const n = lexLine(0, "x = '''open", &s);
    try std.testing.expectEqual(@as(u32, 1), n);
    s = Sink.init(&b);
    try std.testing.expectEqual(@as(u32, 1), lexLine(n, "still open", &s));
    s = Sink.init(&b);
    try std.testing.expectEqual(@as(u32, 0), lexLine(n, "close''' + 2", &s));
}
test "Python spans stay bounded for random bytes" {
    var p = std.Random.DefaultPrng.init(0x91a2);
    const r = p.random();
    var line: [96]u8 = undefined;
    var b: [128]token.Span = undefined;
    for (0..500) |_| {
        const n = r.uintLessThan(usize, 97);
        for (line[0..n]) |*c| c.* = r.int(u8);
        var s = Sink.init(&b);
        _ = lexLine(r.uintLessThan(u32, 4), line[0..n], &s);
        var end: u32 = 0;
        for (s.items()) |sp| {
            try std.testing.expect(sp.start < sp.end);
            try std.testing.expect(sp.start >= end);
            try std.testing.expect(sp.end <= n);
            end = sp.end;
        }
    }
}
