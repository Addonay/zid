//! Incremental SQL lexer. State bit 0 carries a block comment; bit 1 a single quote, bit 2 double quote.
const std = @import("std");
const token = @import("token.zig");
const Sink = token.Sink;
const words = std.StaticStringMap(token.Kind).initComptime(.{
    .{ "SELECT", .keyword }, .{ "FROM", .keyword }, .{ "WHERE", .keyword }, .{ "AS", .keyword }, .{ "AND", .keyword_control }, .{ "OR", .keyword_control }, .{ "NOT", .keyword_control }, .{ "NULL", .constant }, .{ "TRUE", .constant }, .{ "FALSE", .constant }, .{ "INSERT", .keyword }, .{ "INTO", .keyword }, .{ "VALUES", .keyword }, .{ "UPDATE", .keyword }, .{ "SET", .keyword }, .{ "DELETE", .keyword }, .{ "CREATE", .keyword }, .{ "TABLE", .keyword }, .{ "DROP", .keyword }, .{ "ALTER", .keyword }, .{ "JOIN", .keyword }, .{ "LEFT", .keyword }, .{ "RIGHT", .keyword }, .{ "INNER", .keyword }, .{ "ON", .keyword }, .{ "GROUP", .keyword }, .{ "BY", .keyword }, .{ "ORDER", .keyword }, .{ "HAVING", .keyword }, .{ "LIMIT", .keyword }, .{ "OFFSET", .keyword }, .{ "UNION", .keyword }, .{ "CASE", .keyword }, .{ "WHEN", .keyword }, .{ "THEN", .keyword }, .{ "ELSE", .keyword }, .{ "END", .keyword }, .{ "BEGIN", .keyword }, .{ "COMMIT", .keyword }, .{ "ROLLBACK", .keyword }, .{ "PRIMARY", .keyword }, .{ "KEY", .keyword }, .{ "REFERENCES", .keyword }, .{ "DISTINCT", .keyword }, .{ "COUNT", .builtin }, .{ "SUM", .builtin }, .{ "AVG", .builtin }, .{ "MIN", .builtin }, .{ "MAX", .builtin },
});
fn ident(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}
pub fn lexLine(state: u32, line: []const u8, sink: *Sink) u32 {
    var i: usize = 0;
    var mode = state & 7;
    while (i < line.len) {
        const s = i;
        if (mode == 1) {
            while (i < line.len) {
                if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                    i += 2;
                    mode = 0;
                    break;
                }
                i += 1;
            }
            sink.emit(s, i, .comment);
            continue;
        }
        if (mode == 2 or mode == 4) {
            const q: u8 = if (mode == 2) '\'' else '"';
            while (i < line.len) {
                if (line[i] == q) {
                    if (i + 1 < line.len and line[i + 1] == q) {
                        i += 2;
                        continue;
                    }
                    i += 1;
                    mode = 0;
                    break;
                }
                if (line[i] == '\\' and i + 1 < line.len) i += 1;
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
        if (i + 1 < line.len and c == '-' and line[i + 1] == '-') {
            sink.emit(i, line.len, .comment);
            break;
        }
        if (i + 1 < line.len and c == '/' and line[i + 1] == '*') {
            mode = 1;
            i += 2;
            while (i < line.len) {
                if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                    i += 2;
                    mode = 0;
                    break;
                }
                i += 1;
            }
            sink.emit(s, i, .comment);
            continue;
        }
        if (c == '\'') {
            mode = 2;
            i += 1;
            continue;
        }
        if (c == '"') {
            mode = 4;
            i += 1;
            continue;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            i += 1;
            while (i < line.len and ident(line[i])) : (i += 1) {}
            const w = std.ascii.allocUpperString(std.heap.page_allocator, line[s..i]) catch unreachable;
            defer std.heap.page_allocator.free(w);
            if (words.get(w)) |k| sink.emit(s, i, k);
            continue;
        }
        if (std.ascii.isDigit(c)) {
            i += 1;
            while (i < line.len and (ident(line[i]) or line[i] == '.')) : (i += 1) {}
            sink.emit(s, i, .number);
            continue;
        }
        if (std.mem.indexOfScalar(u8, "()[],.;", c) != null) sink.emit(i, i + 1, .punctuation) else if (std.mem.indexOfScalar(u8, "=<>!+-*/%", c) != null) sink.emit(i, i + 1, .operator);
        i += 1;
    }
    return mode;
}
test "SQL block comments and strings continue" {
    var b: [32]token.Span = undefined;
    var s = Sink.init(&b);
    var n = lexLine(0, "select /* open", &s);
    try std.testing.expectEqual(@as(u32, 1), n);
    s = Sink.init(&b);
    n = lexLine(n, "continued */ 'a''b'", &s);
    try std.testing.expectEqual(@as(u32, 0), n);
}
test "SQL random span bounds" {
    var p = std.Random.DefaultPrng.init(0x5151);
    const r = p.random();
    var l: [80]u8 = undefined;
    var b: [128]token.Span = undefined;
    for (0..500) |_| {
        const n = r.uintLessThan(usize, 81);
        for (l[0..n]) |*c| c.* = r.int(u8);
        var s = Sink.init(&b);
        _ = lexLine(r.uintLessThan(u32, 8), l[0..n], &s);
        var e: u32 = 0;
        for (s.items()) |x| {
            try std.testing.expect(x.start < x.end);
            try std.testing.expect(x.start >= e);
            try std.testing.expect(x.end <= n);
            e = x.end;
        }
    }
}
