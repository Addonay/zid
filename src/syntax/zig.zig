//! Incremental Zig line lexer built on `std.zig.Tokenizer`.
//!
//! Zig has no multi-line comments or block constructs, so the state is always 0.
//! The std tokenizer skips `//` comments silently, so comments are recovered from
//! the gaps between tokens. Lines longer than 4095 bytes are only coloured up to
//! that point; the remainder stays plain.
const std = @import("std");
const token = @import("token.zig");
const Kind = token.Kind;
const Sink = token.Sink;

const max_line = 4095;

const primitive_names = [_][]const u8{
    "bool",   "void",         "anyerror",       "anyopaque",   "noreturn",
    "type",   "comptime_int", "comptime_float", "usize",       "isize",
    "f16",    "f32",          "f64",            "f80",         "f128",
    "c_char", "c_short",      "c_ushort",       "c_int",       "c_uint",
    "c_long", "c_ulong",      "c_longlong",     "c_ulonglong", "c_longdouble",
};

fn isPrimitive(text: []const u8) bool {
    inline for (primitive_names) |name| {
        if (std.mem.eql(u8, text, name)) return true;
    }
    // Arbitrary-width integers: uN / iN.
    if (text.len < 2 or (text[0] != 'u' and text[0] != 'i')) return false;
    for (text[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn identKind(text: []const u8, after_dot: bool, call: bool) ?Kind {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false") or
        std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "undefined")) return .constant;
    if (std.ascii.isUpper(text[0]) or isPrimitive(text)) return .type;
    if (call) return .function;
    if (after_dot) return .property;
    return null;
}

/// Emit `[start, end)` as `base`, splitting out backslash escapes when `escapes` is set.
fn emitBody(sink: *Sink, line: []const u8, start: usize, end: usize, base: Kind, escapes: bool) void {
    var run = start;
    var i = start;
    while (i < end) {
        if (!escapes or line[i] != '\\') {
            i += 1;
            continue;
        }
        sink.emit(run, i, base);
        var e = i + 2;
        if (i + 1 < end) switch (line[i + 1]) {
            'x' => e = i + 4,
            'u' => if (i + 2 < end and line[i + 2] == '{') {
                if (std.mem.indexOfScalar(u8, line[i + 2 .. end], '}')) |rel| e = i + 2 + rel + 1 else e = end;
            },
            else => {},
        };
        e = @min(e, end);
        sink.emit(i, e, .string_escape);
        run = e;
        i = e;
    }
    sink.emit(run, end, base);
}

fn followedByParen(line: []const u8, end: usize) bool {
    var i = end;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i < line.len and line[i] == '(';
}

fn emitToken(sink: *Sink, line: []const u8, s: usize, e: usize, tag: std.zig.Token.Tag, call: bool, after_dot: bool) void {
    const Tag = std.zig.Token.Tag;
    switch (tag) {
        .identifier => if (identKind(line[s..e], after_dot, call)) |k| sink.emit(s, e, k),
        .keyword_anytype => sink.emit(s, e, .type),
        .builtin => sink.emit(s, e, .builtin),
        .number_literal => sink.emit(s, e, .number),
        .string_literal => emitBody(sink, line, s, e, .string, true),
        .char_literal => emitBody(sink, line, s, e, .char, true),
        .multiline_string_literal_line => sink.emit(s, e, .string),
        .doc_comment, .container_doc_comment => sink.emit(s, e, .comment_doc),
        .l_paren, .r_paren, .l_brace, .r_brace, .l_bracket, .r_bracket, .semicolon, .comma, .colon => sink.emit(s, e, .punctuation),
        .keyword_if, .keyword_else, .keyword_switch, .keyword_while, .keyword_for, .keyword_return, .keyword_break, .keyword_continue, .keyword_try, .keyword_catch, .keyword_orelse, .keyword_defer, .keyword_errdefer, .keyword_unreachable => sink.emit(s, e, .keyword_control),
        .invalid => {
            // The tokenizer marks unterminated literals invalid; still colour the opener.
            if (line[s] == '"') emitBody(sink, line, s, e, .string, true) else if (line[s] == '\'') emitBody(sink, line, s, e, .char, true);
        },
        .eof => {},
        else => {
            if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) {
                sink.emit(s, e, .keyword);
            } else if (Tag.lexeme(tag) != null) {
                sink.emit(s, e, .operator);
            }
        },
    }
}

/// Lex one Zig source line. Always returns state 0.
pub fn lexLine(state: u32, line: []const u8, sink: *Sink) u32 {
    _ = state;
    var buf: [max_line + 1:0]u8 = undefined;
    const n = @min(line.len, max_line);
    @memcpy(buf[0..n], line[0..n]);
    buf[n] = 0;
    var tz: std.zig.Tokenizer = .{ .buffer = buf[0..n :0], .index = 0 };

    var pos: usize = 0;
    var after_dot = false;
    while (pos < n) {
        tz.index = pos;
        const tok = tz.next();
        const gap_end = if (tok.tag == .eof) n else @max(tok.loc.start, pos);
        // Gaps hold only whitespace, or a line comment that runs to the end of the line.
        if (std.mem.indexOf(u8, line[pos..gap_end], "//")) |rel| sink.emit(pos + rel, n, .comment);
        if (tok.tag == .eof) break;

        const s = gap_end;
        const e = @min(tok.loc.end, n);
        if (e <= s) {
            pos = s + 1;
            continue;
        }
        emitToken(sink, line, s, e, tok.tag, followedByParen(line, e), after_dot);
        after_dot = tok.tag == .period;
        pos = e;
    }
    return 0;
}

fn check(state: u32, line: []const u8, expected: []const u8, next_state: u32) !void {
    const r = try token.debugSpans(std.testing.allocator, lexLine, state, line);
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqualStrings(expected, r.text);
    try std.testing.expectEqual(next_state, r.state);
}

test "empty and blank lines" {
    try check(0, "", "", 0);
    try check(0, "    \t  ", "", 0);
}

test "declarations, calls and punctuation" {
    try check(0, "pub fn main() void {}", "keyword:pub keyword:fn function:main punctuation:() type:void punctuation:{}", 0);
    try check(0, "const x: u8 = 42;", "keyword:const punctuation:: type:u8 operator:= number:42 punctuation:;", 0);
    try check(0, "if (a) return error.Foo;", "keyword_control:if punctuation:( punctuation:) keyword_control:return keyword:error operator:. type:Foo punctuation:;", 0);
    try check(0, "ArrayList(u8)", "type:ArrayList punctuation:( type:u8 punctuation:)", 0);
}

test "primitive types including arbitrary width" {
    try check(0, "i32 usize f64 bool anyerror u7 i65535 c_int", "type:i32 type:usize type:f64 type:bool type:anyerror type:u7 type:i65535 type:c_int", 0);
    try check(0, "fn f(x: anytype) type", "keyword:fn function:f punctuation:( punctuation:: type:anytype punctuation:) type:type", 0);
    // "u" or "i" alone, or with non-digits, is an ordinary identifier.
    try check(0, "u i ux", "", 0);
}

test "constants, builtins and numbers" {
    try check(0, "true false null undefined", "constant:true constant:false constant:null constant:undefined", 0);
    try check(0, "@import(\"std\")", "builtin:@import punctuation:( string:\"std\" punctuation:)", 0);
    try check(0, "0x1F 1.5e10 0b101 1_000 0o7", "number:0x1F number:1.5e10 number:0b101 number:1_000 number:0o7", 0);
}

test "properties, methods and enum literals" {
    try check(0, "a.b.c", "operator:. property:b operator:. property:c", 0);
    try check(0, "std.debug.print(\"x\")", "operator:. property:debug operator:. function:print punctuation:( string:\"x\" punctuation:)", 0);
    try check(0, ".Ok", "operator:. type:Ok", 0);
}

test "line comments and doc comments" {
    try check(0, "const a = 1; // note", "keyword:const operator:= number:1 punctuation:; comment:// note", 0);
    try check(0, "/// Doc here", "comment_doc:/// Doc here", 0);
    try check(0, "//! container doc", "comment_doc://! container doc", 0);
    try check(0, "// plain", "comment:// plain", 0);
    try check(0, "\"a // b\"", "string:\"a // b\"", 0);
}

test "string escapes" {
    try check(0, "const s = \"a\\n\";", "keyword:const operator:= string:\"a string_escape:\\n string:\" punctuation:;", 0);
    try check(0, "\"\\x41\\u{1F600}\"", "string:\" string_escape:\\x41\\u{1F600} string:\"", 0);
    try check(0, "'\\''", "char:' string_escape:\\' char:'", 0);
    try check(0, "'x'", "char:'x'", 0);
}

test "multiline string lines and unterminated literals" {
    try check(0, "    \\\\multi \"quoted\" line", "string:\\\\multi \"quoted\" line", 0);
    try check(0, "const s = \"abc", "keyword:const operator:= string:\"abc", 0);
    try check(0, "'x", "char:'x", 0);
}

test "escaping at end of line and invalid bytes stay total" {
    try check(0, "\"abc\\", "string:\"abc string_escape:\\", 0);
    try check(0, "\xff", "", 0);
    try check(0, "x = 1 \xff", "operator:= number:1", 0);
}

test "state is always zero" {
    var buffer: [16]token.Span = undefined;
    var sink = token.Sink.init(&buffer);
    try std.testing.expectEqual(@as(u32, 0), lexLine(0, "/* not zig */ \"", &sink));
    try std.testing.expectEqual(@as(u32, 0), lexLine(0, "", &sink));
}

test "very long line is lexed up to the buffer limit" {
    const allocator = std.testing.allocator;
    const line = try allocator.alloc(u8, 5000);
    defer allocator.free(line);
    @memset(line, ' ');
    @memcpy(line[0..8], "const x ");
    var spans: [4096]token.Span = undefined;
    var sink = token.Sink.init(&spans);
    _ = lexLine(0, line, &sink);
    try std.testing.expect(sink.len >= 1);
    try std.testing.expectEqual(Kind.keyword, sink.items()[0].kind);
    for (sink.items()) |span| try std.testing.expect(span.end <= line.len);
}

test "fuzz: random lines produce ordered, non-overlapping, in-bounds spans" {
    var prng = std.Random.DefaultPrng.init(0x7a1d_c0de);
    const rnd = prng.random();
    // Bias towards Zig-significant bytes so the tokenizer sees real constructs.
    const alphabet = "abcXYZ_09 \t\"'\\/@.(){}[];,:=+-*&|<>!%^~?#x\xff\x00\x80";
    var line_buf: [160]u8 = undefined;
    var spans: [256]token.Span = undefined;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, line_buf.len + 1);
        for (line_buf[0..len]) |*c| {
            c.* = if (rnd.boolean()) alphabet[rnd.uintLessThan(usize, alphabet.len)] else rnd.int(u8);
        }
        const line = line_buf[0..len];
        var sink = token.Sink.init(&spans);
        const next = lexLine(0, line, &sink);
        try std.testing.expectEqual(@as(u32, 0), next);
        var prev_end: u32 = 0;
        for (sink.items()) |span| {
            try std.testing.expect(span.start < span.end);
            try std.testing.expect(span.start >= prev_end);
            try std.testing.expect(span.end <= line.len);
            prev_end = span.end;
        }
    }
}
