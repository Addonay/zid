//! Incremental C and C++ line lexers.
//!
//! State layout (u32):
//!   bits 0-1  mode: 0 normal, 1 inside `/* */`, 2 inside C++ raw string
//!   bit 2     a `//` comment continues onto the next line (trailing backslash)
//!   bit 3     a preprocessor directive continues onto the next line
//!   bits 4-8  raw string delimiter length (0..16)
//!   bits 9-31 raw string delimiter hash (23 bits)
//! Raw string closing is matched by hashing the candidate delimiter, so it is
//! exact unless two delimiters collide in 23 bits.
const std = @import("std");
const token = @import("token.zig");
const Kind = token.Kind;
const Sink = token.Sink;

const mode_mask: u32 = 3;
const mode_block: u32 = 1;
const mode_raw: u32 = 2;
const flag_line_comment: u32 = 1 << 2;
const flag_pp: u32 = 1 << 3;
const raw_len_shift = 4;
const raw_hash_shift = 9;
const max_delim = 16;

const c_entries = .{
    .{ "if", Kind.keyword_control },       .{ "else", Kind.keyword_control },
    .{ "switch", Kind.keyword_control },   .{ "case", Kind.keyword_control },
    .{ "default", Kind.keyword_control },  .{ "while", Kind.keyword_control },
    .{ "do", Kind.keyword_control },       .{ "for", Kind.keyword_control },
    .{ "return", Kind.keyword_control },   .{ "break", Kind.keyword_control },
    .{ "continue", Kind.keyword_control }, .{ "goto", Kind.keyword_control },
    .{ "auto", Kind.keyword },             .{ "const", Kind.keyword },
    .{ "enum", Kind.keyword },             .{ "extern", Kind.keyword },
    .{ "inline", Kind.keyword },           .{ "register", Kind.keyword },
    .{ "restrict", Kind.keyword },         .{ "static", Kind.keyword },
    .{ "struct", Kind.keyword },           .{ "typedef", Kind.keyword },
    .{ "union", Kind.keyword },            .{ "volatile", Kind.keyword },
    .{ "_Atomic", Kind.keyword },          .{ "_Noreturn", Kind.keyword },
    .{ "_Thread_local", Kind.keyword },    .{ "_Alignas", Kind.keyword },
    .{ "_Generic", Kind.keyword },         .{ "_Static_assert", Kind.keyword },
    .{ "_Complex", Kind.keyword },         .{ "_Imaginary", Kind.keyword },
    .{ "asm", Kind.keyword },              .{ "__asm__", Kind.keyword },
    .{ "__inline__", Kind.keyword },       .{ "__restrict__", Kind.keyword },
    .{ "typeof", Kind.keyword },           .{ "__typeof__", Kind.keyword },
    .{ "__attribute__", Kind.keyword },    .{ "sizeof", Kind.builtin },
    .{ "_Alignof", Kind.builtin },         .{ "void", Kind.type },
    .{ "char", Kind.type },                .{ "short", Kind.type },
    .{ "int", Kind.type },                 .{ "long", Kind.type },
    .{ "float", Kind.type },               .{ "double", Kind.type },
    .{ "signed", Kind.type },              .{ "unsigned", Kind.type },
    .{ "_Bool", Kind.type },               .{ "bool", Kind.type },
    .{ "true", Kind.constant },            .{ "false", Kind.constant },
    .{ "NULL", Kind.constant },
};

const cpp_entries = c_entries ++ .{
    .{ "try", Kind.keyword_control },       .{ "catch", Kind.keyword_control },
    .{ "throw", Kind.keyword_control },     .{ "co_await", Kind.keyword_control },
    .{ "co_return", Kind.keyword_control }, .{ "co_yield", Kind.keyword_control },
    .{ "class", Kind.keyword },             .{ "namespace", Kind.keyword },
    .{ "template", Kind.keyword },          .{ "typename", Kind.keyword },
    .{ "public", Kind.keyword },            .{ "private", Kind.keyword },
    .{ "protected", Kind.keyword },         .{ "virtual", Kind.keyword },
    .{ "override", Kind.keyword },          .{ "final", Kind.keyword },
    .{ "constexpr", Kind.keyword },         .{ "consteval", Kind.keyword },
    .{ "constinit", Kind.keyword },         .{ "new", Kind.keyword },
    .{ "delete", Kind.keyword },            .{ "operator", Kind.keyword },
    .{ "friend", Kind.keyword },            .{ "explicit", Kind.keyword },
    .{ "mutable", Kind.keyword },           .{ "using", Kind.keyword },
    .{ "noexcept", Kind.keyword },          .{ "decltype", Kind.keyword },
    .{ "static_assert", Kind.keyword },     .{ "thread_local", Kind.keyword },
    .{ "static_cast", Kind.keyword },       .{ "dynamic_cast", Kind.keyword },
    .{ "reinterpret_cast", Kind.keyword },  .{ "const_cast", Kind.keyword },
    .{ "typeid", Kind.keyword },            .{ "concept", Kind.keyword },
    .{ "requires", Kind.keyword },          .{ "export", Kind.keyword },
    .{ "and", Kind.keyword },               .{ "or", Kind.keyword },
    .{ "not", Kind.keyword },               .{ "xor", Kind.keyword },
    .{ "alignof", Kind.builtin },           .{ "this", Kind.variable_special },
    .{ "nullptr", Kind.constant },          .{ "wchar_t", Kind.type },
    .{ "char8_t", Kind.type },              .{ "char16_t", Kind.type },
    .{ "char32_t", Kind.type },
};

const c_words = std.StaticStringMap(Kind).initComptime(c_entries);
const cpp_words = std.StaticStringMap(Kind).initComptime(cpp_entries);

pub fn lexLineC(state: u32, line: []const u8, sink: *Sink) u32 {
    return lexImpl(false, state, line, sink);
}

pub fn lexLineCpp(state: u32, line: []const u8, sink: *Sink) u32 {
    return lexImpl(true, state, line, sink);
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn endsWithBackslash(line: []const u8) bool {
    return line.len > 0 and line[line.len - 1] == '\\';
}

fn followedByParen(line: []const u8, end: usize) bool {
    var i = end;
    while (i < line.len and isSpace(line[i])) i += 1;
    return i < line.len and line[i] == '(';
}

fn identEnd(line: []const u8, start: usize) usize {
    var e = start;
    while (e < line.len and isIdentChar(line[e])) e += 1;
    return e;
}

fn identKind(words: std.StaticStringMap(Kind), ident: []const u8, member: bool, call: bool) ?Kind {
    if (member) return if (call) .function else .property;
    if (words.get(ident)) |k| return k;
    if (ident.len > 2 and std.mem.endsWith(u8, ident, "_t")) return .type;
    if (call) return .function;
    return null;
}

/// Index just past the closing quote, or `line.len` if unterminated.
fn scanQuoted(line: []const u8, quote: usize, q: u8) usize {
    var j = quote + 1;
    while (j < line.len) : (j += 1) {
        if (line[j] == '\\') {
            j += 1;
            continue;
        }
        if (line[j] == q) return j + 1;
    }
    return line.len;
}

/// Emit `[s, e)` as `base`, with escape sequences split out as `string_escape`.
fn emitLiteral(sink: *Sink, line: []const u8, s: usize, e: usize, base: Kind) void {
    var run = s;
    var i = s;
    while (i < e) {
        if (line[i] != '\\') {
            i += 1;
            continue;
        }
        sink.emit(run, i, base);
        var j = i + 2;
        if (i + 1 < e) switch (line[i + 1]) {
            'x' => {
                j = i + 2;
                while (j < e and std.ascii.isHex(line[j])) j += 1;
            },
            'u' => j = i + 6,
            'U' => j = i + 10,
            else => {},
        };
        j = @min(j, e);
        sink.emit(i, j, .string_escape);
        run = j;
        i = j;
    }
    sink.emit(run, e, base);
}

fn scanNumber(line: []const u8, start: usize, cpp: bool) usize {
    var j = start;
    var hex = false;
    if (line[j] == '0' and j + 1 < line.len) {
        switch (std.ascii.toLower(line[j + 1])) {
            'x' => {
                hex = true;
                j += 2;
            },
            'b' => j += 2,
            else => {},
        }
    }
    while (j < line.len) : (j += 1) {
        const c = line[j];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') continue;
        if ((c == '+' or c == '-') and j > start) {
            const p = std.ascii.toLower(line[j - 1]);
            if (p == 'p' or (p == 'e' and !hex)) continue;
        }
        if (cpp and c == '\'' and j > start and j + 1 < line.len and
            std.ascii.isAlphanumeric(line[j - 1]) and std.ascii.isAlphanumeric(line[j + 1])) continue;
        break;
    }
    return @min(j, line.len);
}

fn delimHash(bytes: []const u8) u32 {
    var h: u32 = 0;
    for (bytes) |b| h = (h *% 31 +% b) & 0x7fffff;
    return h;
}

const RawStart = struct { len: u32, hash: u32, body: usize };

/// Parse `"delim(` where `quote` indexes the opening quote.
fn rawStart(line: []const u8, quote: usize) ?RawStart {
    var k = quote + 1;
    while (k < line.len and line[k] != '(') : (k += 1) {
        if (k - quote - 1 >= max_delim) return null;
        switch (line[k]) {
            ' ', '\t', ')', '\\', '"' => return null,
            else => {},
        }
    }
    if (k >= line.len) return null;
    const delim = line[quote + 1 .. k];
    return .{ .len = @intCast(delim.len), .hash = delimHash(delim), .body = k + 1 };
}

/// Index just past `)delim"`, or null if the closing sequence is not on this line.
fn findRawEnd(line: []const u8, from: usize, len: u32, hash: u32) ?usize {
    var k = from;
    while (k < line.len) : (k += 1) {
        if (line[k] != ')') continue;
        const q = k + 1 + len;
        if (q < line.len and line[q] == '"' and delimHash(line[k + 1 .. q]) == hash) return q + 1;
    }
    return null;
}

fn lexImpl(comptime cpp: bool, state: u32, line: []const u8, sink: *Sink) u32 {
    const words = if (cpp) cpp_words else c_words;
    const n = line.len;
    var i: usize = 0;
    var pp = state & flag_pp != 0;

    // Resume multi-line constructs that began on an earlier line.
    switch (state & mode_mask) {
        mode_block => {
            if (std.mem.indexOf(u8, line, "*/")) |k| {
                sink.emit(0, k + 2, .comment);
                i = k + 2;
            } else {
                sink.emit(0, n, .comment);
                return state;
            }
        },
        mode_raw => {
            const len = (state >> raw_len_shift) & 0x1f;
            const hash = state >> raw_hash_shift;
            if (findRawEnd(line, 0, len, hash)) |close| {
                sink.emit(0, close, .string);
                i = close;
            } else {
                sink.emit(0, n, .string);
                return state;
            }
        },
        else => {
            if (state & flag_line_comment != 0) {
                sink.emit(0, n, .comment);
                return if (endsWithBackslash(line)) flag_line_comment | (state & flag_pp) else 0;
            }
        },
    }

    var at_start = true;
    var member = false;
    while (i < n) {
        const c = line[i];
        if (isSpace(c)) {
            i += 1;
            continue;
        }
        const was_member = member;
        member = false;
        const at_line_start = at_start;
        at_start = false;

        if (c == '/' and i + 1 < n and line[i + 1] == '/') {
            sink.emit(i, n, .comment);
            return if (endsWithBackslash(line)) flag_line_comment | (if (pp) flag_pp else 0) else 0;
        }
        if (c == '/' and i + 1 < n and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "*/")) |k| {
                sink.emit(i, k + 2, .comment);
                i = k + 2;
                continue;
            }
            sink.emit(i, n, .comment);
            return mode_block | (if (pp) flag_pp else 0);
        }
        if (c == '"' or c == '\'') {
            const e = scanQuoted(line, i, c);
            emitLiteral(sink, line, i, e, if (c == '"') .string else .char);
            i = e;
            continue;
        }
        if (std.ascii.isDigit(c) or (c == '.' and i + 1 < n and std.ascii.isDigit(line[i + 1]))) {
            const e = scanNumber(line, i, cpp);
            sink.emit(i, e, .number);
            i = e;
            continue;
        }
        if (isIdentStart(c)) {
            const e = identEnd(line, i);
            const ident = line[i..e];
            if (cpp and e < n and line[e] == '"' and isRawPrefix(ident)) {
                if (rawStart(line, e)) |r| {
                    if (findRawEnd(line, r.body, r.len, r.hash)) |close| {
                        sink.emit(i, close, .string);
                        i = close;
                    } else {
                        sink.emit(i, n, .string);
                        return mode_raw | (r.len << raw_len_shift) | (r.hash << raw_hash_shift);
                    }
                    continue;
                }
            }
            if (e < n and (line[e] == '"' or line[e] == '\'') and isEncodingPrefix(ident)) {
                const end = scanQuoted(line, e, line[e]);
                emitLiteral(sink, line, i, end, if (line[e] == '"') .string else .char);
                i = end;
                continue;
            }
            if (identKind(words, ident, was_member, followedByParen(line, e))) |k| sink.emit(i, e, k);
            i = e;
            continue;
        }
        if (c == '#' and at_line_start and !pp) {
            var j = i + 1;
            while (j < n and isSpace(line[j])) j += 1;
            const name_start = j;
            while (j < n and isIdentChar(line[j])) j += 1;
            sink.emit(i, j, .preprocessor);
            pp = true;
            const name = line[name_start..j];
            if (std.mem.eql(u8, name, "include") or std.mem.eql(u8, name, "include_next") or std.mem.eql(u8, name, "import")) {
                var k = j;
                while (k < n and isSpace(line[k])) k += 1;
                if (k < n and line[k] == '<') {
                    const end = if (std.mem.indexOfScalarPos(u8, line, k + 1, '>')) |close| close + 1 else n;
                    sink.emit(k, end, .string);
                    j = end;
                }
            }
            i = j;
            continue;
        }
        if (cpp and c == '[' and i + 1 < n and line[i + 1] == '[') {
            const end = if (std.mem.indexOfPos(u8, line, i + 2, "]]")) |close| close + 2 else n;
            sink.emit(i, end, .attribute);
            i = end;
            continue;
        }
        if (c == '-' and i + 1 < n and line[i + 1] == '>') {
            sink.emit(i, i + 2, .operator);
            member = true;
            i += 2;
            continue;
        }
        if (c == '.') {
            sink.emit(i, i + 1, .operator);
            member = true;
            i += 1;
            continue;
        }
        switch (c) {
            '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?' => sink.emit(i, i + 1, .operator),
            '{', '}', '(', ')', '[', ']', ';', ',', ':' => sink.emit(i, i + 1, .punctuation),
            else => {},
        }
        i += 1;
    }
    return if (pp and endsWithBackslash(line)) flag_pp else 0;
}

fn isRawPrefix(ident: []const u8) bool {
    const prefixes = [_][]const u8{ "R", "LR", "uR", "UR", "u8R" };
    for (prefixes) |p| if (std.mem.eql(u8, ident, p)) return true;
    return false;
}

fn isEncodingPrefix(ident: []const u8) bool {
    const prefixes = [_][]const u8{ "L", "u", "U", "u8" };
    for (prefixes) |p| if (std.mem.eql(u8, ident, p)) return true;
    return false;
}

fn expectLine(
    comptime lex: fn (u32, []const u8, *Sink) u32,
    state: u32,
    line: []const u8,
    expected: []const u8,
    next_state: u32,
) !void {
    const r = try token.debugSpans(std.testing.allocator, lex, state, line);
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqualStrings(expected, r.text);
    try std.testing.expectEqual(next_state, r.state);
}

test "empty and blank lines keep top-level state" {
    try expectLine(lexLineC, 0, "", "", 0);
    try expectLine(lexLineCpp, 0, "   \t", "", 0);
}

test "C declarations, keywords and calls" {
    try expectLine(lexLineC, 0, "int main(void) {", "type:int function:main punctuation:( type:void punctuation:) punctuation:{", 0);
    try expectLine(lexLineC, 0, "for (int i = 0; i < n; i++) return x;", "keyword_control:for punctuation:( type:int operator:= number:0 punctuation:; operator:< punctuation:; operator:++ punctuation:) keyword_control:return punctuation:;", 0);
    try expectLine(lexLineC, 0, "static const size_t n = sizeof(int);", "keyword:static keyword:const type:size_t operator:= builtin:sizeof punctuation:( type:int punctuation:);", 0);
}

test "preprocessor directives and include strings" {
    try expectLine(lexLineC, 0, "#include <stdio.h>", "preprocessor:#include string:<stdio.h>", 0);
    try expectLine(lexLineC, 0, "  #  include \"x.h\"", "preprocessor:#  include string:\"x.h\"", 0);
    try expectLine(lexLineC, 0, "#define MAX(a, b) ((a) > (b))", "preprocessor:#define function:MAX punctuation:( punctuation:, punctuation:) punctuation:(( punctuation:) operator:> punctuation:( punctuation:))", 0);
    // A non-leading '#' is not a directive.
    try expectLine(lexLineC, 0, "x # y", "", 0);
}

test "preprocessor continuation lines" {
    try expectLine(lexLineC, 0, "#define LONG(x) \\", "preprocessor:#define function:LONG punctuation:( punctuation:)", 8);
    try expectLine(lexLineC, 8, "    (x + 1)", "punctuation:( operator:+ number:1 punctuation:)", 0);
}

test "line comments and trailing code" {
    try expectLine(lexLineC, 0, "int x; // hi", "type:int punctuation:; comment:// hi", 0);
    try expectLine(lexLineCpp, 0, "a // \"not a string\"", "comment:// \"not a string\"", 0);
}

test "line comment continued with backslash" {
    try expectLine(lexLineC, 0, "// first \\", "comment:// first \\", 4);
    try expectLine(lexLineC, 4, "second", "comment:second", 0);
}

test "same-line block comment" {
    try expectLine(lexLineC, 0, "a /* b */ c", "comment:/* b */", 0);
    try expectLine(lexLineC, 0, "x/**/y", "comment:/**/", 0);
}

test "block comment across lines" {
    try expectLine(lexLineC, 0, "int a; /* start", "type:int punctuation:; comment:/* start", 1);
    try expectLine(lexLineC, 1, "middle * / x", "comment:middle * / x", 1);
    try expectLine(lexLineC, 1, "end */ int b;", "comment:end */ type:int punctuation:;", 0);
}

test "block comment with a second opener on the same line" {
    try expectLine(lexLineC, 0, "/* a */ /* b", "comment:/* a */ comment:/* b", 1);
}

test "strings and escapes" {
    try expectLine(lexLineC, 0, "char *s = \"a\\n\\\"b\";", "type:char operator:* operator:= string:\"a string_escape:\\n\\\" string:b\" punctuation:;", 0);
    try expectLine(lexLineC, 0, "\"abc", "string:\"abc", 0);
    try expectLine(lexLineC, 0, "\"tail\\", "string:\"tail string_escape:\\", 0);
}

test "char literals and escapes" {
    try expectLine(lexLineC, 0, "'\\0' 'x'", "char:' string_escape:\\0 char:' char:'x'", 0);
    try expectLine(lexLineC, 0, "'a", "char:'a", 0);
}

test "encoding prefixes" {
    try expectLine(lexLineCpp, 0, "u8\"hi\" L'c'", "string:u8\"hi\" char:L'c'", 0);
}

test "numbers: hex, float, suffixes, exponent sign" {
    try expectLine(lexLineC, 0, "0x1Fu 1.5e+10f 0b1010 .5 0xe+1", "number:0x1Fu number:1.5e+10f number:0b1010 number:.5 number:0xe operator:+ number:1", 0);
}

test "C++ digit separators" {
    try expectLine(lexLineCpp, 0, "1'000'000 1'0.5", "number:1'000'000 number:1'0.5", 0);
    // C has no digit separators, so the quote opens a char literal.
    try expectLine(lexLineC, 0, "1'000", "number:1 char:'000", 0);
}

test "C++ attributes and class heads" {
    try expectLine(lexLineCpp, 0, "[[nodiscard]] int f();", "attribute:[[nodiscard]] type:int function:f punctuation:();", 0);
    try expectLine(lexLineCpp, 0, "class Foo : public Bar {", "keyword:class punctuation:: keyword:public punctuation:{", 0);
    try expectLine(lexLineC, 0, "[[nodiscard]]", "punctuation:[[ punctuation:]]", 0);
}

test "C++ this, nullptr and members" {
    try expectLine(lexLineCpp, 0, "this->x = nullptr;", "variable_special:this operator:-> property:x operator:= constant:nullptr punctuation:;", 0);
    try expectLine(lexLineCpp, 0, "obj.method(1)", "operator:. function:method punctuation:( number:1 punctuation:)", 0);
    // `this` is an ordinary identifier in C.
    try expectLine(lexLineC, 0, "this", "", 0);
}

test "types ending in _t and control keywords" {
    try expectLine(lexLineC, 0, "size_t n = uint8_t(x);", "type:size_t operator:= type:uint8_t punctuation:( punctuation:);", 0);
    try expectLine(lexLineCpp, 0, "try { throw e; } catch (...) {}", "keyword_control:try punctuation:{ keyword_control:throw punctuation:; punctuation:} keyword_control:catch punctuation:( operator:... punctuation:) punctuation:{}", 0);
}

test "C++ raw strings span lines" {
    try expectLine(lexLineCpp, 0, "const char* s = R\"xy(first", "keyword:const type:char operator:* operator:= string:R\"xy(first", 2 | (2 << 4) | (hashOf("xy") << 9));
    try expectLine(lexLineCpp, 2 | (2 << 4) | (hashOf("xy") << 9), "middle )\" still", "string:middle )\" still", 2 | (2 << 4) | (hashOf("xy") << 9));
    try expectLine(lexLineCpp, 2 | (2 << 4) | (hashOf("xy") << 9), "more)xy\" + 1;", "string:more)xy\" operator:+ number:1 punctuation:;", 0);
}

test "C++ raw string closed on the same line" {
    try expectLine(lexLineCpp, 0, "R\"(a)\" + R\"d(b)d\"", "string:R\"(a)\" operator:+ string:R\"d(b)d\"", 0);
}

test "C raw string prefix is not special" {
    try expectLine(lexLineC, 0, "R\"(x)\"", "string:\"(x)\"", 0);
}

test "invalid UTF-8 and control bytes stay total" {
    try expectLine(lexLineC, 0, "\xff", "", 0);
    try expectLine(lexLineCpp, 0, "\"abc\xff\x01\"", "string:\"abc\xff\x01\"", 0);
    try expectLine(lexLineC, 0, "a\x00b", "", 0);
}

test "very long line stays within bounds" {
    const allocator = std.testing.allocator;
    const line = try allocator.alloc(u8, 5000);
    defer allocator.free(line);
    @memset(line, 'x');
    line[0] = '"';
    var spans: [64]token.Span = undefined;
    var sink = token.Sink.init(&spans);
    _ = lexLineC(0, line, &sink);
    try std.testing.expect(sink.len == 1);
    try std.testing.expectEqual(@as(u32, 5000), sink.items()[0].end);
}

fn hashOf(delim: []const u8) u32 {
    return delimHash(delim);
}

fn fuzzLexer(comptime lex: fn (u32, []const u8, *Sink) u32, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const alphabet = "abcR_09 \t\"'\\/*#[]<>.-+(){};,:=!&|xe\xff\x00\x80";
    var line_buf: [160]u8 = undefined;
    var spans: [256]token.Span = undefined;
    var state: u32 = 0;
    var iter: usize = 0;
    while (iter < 2000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, line_buf.len + 1);
        for (line_buf[0..len]) |*c| {
            c.* = if (rnd.boolean()) alphabet[rnd.uintLessThan(usize, alphabet.len)] else rnd.int(u8);
        }
        const line = line_buf[0..len];
        var sink = token.Sink.init(&spans);
        // Carry the state across lines so multi-line transitions are exercised too.
        state = lex(state, line, &sink);
        var prev_end: u32 = 0;
        for (sink.items()) |span| {
            try std.testing.expect(span.start < span.end);
            try std.testing.expect(span.start >= prev_end);
            try std.testing.expect(span.end <= line.len);
            prev_end = span.end;
        }
        // Keep states in the reachable domain so random walks do not stay stuck.
        if (rnd.uintLessThan(u8, 8) == 0) state = 0;
    }
}

test "fuzz: C random lines and carried state stay in bounds" {
    try fuzzLexer(lexLineC, 0xc0ffee);
}

test "fuzz: C++ random lines and carried state stay in bounds" {
    try fuzzLexer(lexLineCpp, 0xbeef_1234);
}
