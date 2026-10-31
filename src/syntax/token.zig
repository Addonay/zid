//! Shared vocabulary for the incremental line lexers.
//!
//! A lexer is a pure function `lexLine(state, line, sink) -> next_state`.
//! `line` excludes the trailing "\n" (and "\r"). `state` is an opaque u32 the
//! lexer uses to carry multi-line constructs (block comments, triple-quoted
//! strings, fenced code). State 0 always means "top level". Lexers must be
//! total: any byte sequence (including invalid UTF-8) is accepted.
//! Spans must be emitted in increasing, non-overlapping order; gaps are plain text.
const std = @import("std");

pub const Kind = enum(u8) {
    plain,
    comment,
    comment_doc,
    keyword,
    keyword_control,
    string,
    string_escape,
    char,
    number,
    constant, // true/false/null/None/nullptr/undefined
    type,
    builtin, // @import, len(), sizeof
    function, // identifier followed by '('
    property, // identifier after '.'
    variable_special, // self, this, cls
    operator,
    punctuation,
    preprocessor, // #include, #define
    attribute, // python decorators, C++ [[attr]]
    label,
    // markdown
    title,
    emphasis,
    strong,
    code,
    link_text,
    link_uri,
    list_marker,
    quote,
};

pub const Span = struct {
    start: u32,
    end: u32,
    kind: Kind,
};

/// Fixed-capacity span collector. Spans beyond capacity are dropped, which
/// only loses colour on pathological lines; lexer state stays correct.
pub const Sink = struct {
    spans: []Span,
    len: usize = 0,

    pub fn init(buffer: []Span) Sink {
        return .{ .spans = buffer };
    }
    pub fn emit(self: *Sink, start: usize, end: usize, kind: Kind) void {
        if (end <= start or kind == .plain) return;
        if (self.len > 0) {
            const last = &self.spans[self.len - 1];
            // Merge adjacent identical kinds to keep span counts low.
            if (last.kind == kind and last.end == start) {
                last.end = @intCast(end);
                return;
            }
            std.debug.assert(start >= last.end);
        }
        if (self.len == self.spans.len) return;
        self.spans[self.len] = .{ .start = @intCast(start), .end = @intCast(end), .kind = kind };
        self.len += 1;
    }
    pub fn items(self: *const Sink) []const Span {
        return self.spans[0..self.len];
    }
};

pub const Language = enum {
    plain,
    zig,
    c,
    cpp,
    python,
    sql,
    json,
    markdown,

    pub fn fromPath(path: []const u8) Language {
        const base = std.fs.path.basename(path);
        const ext = std.fs.path.extension(base);
        const map = .{
            .{ ".zig", .zig },     .{ ".zon", .zig },           .{ ".c", .c },        .{ ".h", .c },
            .{ ".cc", .cpp },      .{ ".cpp", .cpp },           .{ ".cxx", .cpp },    .{ ".hpp", .cpp },
            .{ ".hh", .cpp },      .{ ".hxx", .cpp },           .{ ".py", .python },  .{ ".pyi", .python },
            .{ ".sql", .sql },     .{ ".json", .json },         .{ ".jsonc", .json }, .{ ".ipynb", .json },
            .{ ".md", .markdown }, .{ ".markdown", .markdown },
        };
        inline for (map) |entry| if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
        return .plain;
    }
    pub fn displayName(self: Language) []const u8 {
        return switch (self) {
            .plain => "Plain Text",
            .zig => "Zig",
            .c => "C",
            .cpp => "C++",
            .python => "Python",
            .sql => "SQL",
            .json => "JSON",
            .markdown => "Markdown",
        };
    }
};

/// Test helper: lex a single line from `state`, return spans rendered as
/// "kind:text" joined by spaces, for compact assertions.
pub fn debugSpans(
    allocator: std.mem.Allocator,
    comptime lexLine: fn (u32, []const u8, *Sink) u32,
    state: u32,
    line: []const u8,
) !struct { text: []u8, state: u32 } {
    var buffer: [256]Span = undefined;
    var sink = Sink.init(&buffer);
    const next = lexLine(state, line, &sink);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (sink.items(), 0..) |span, i| {
        if (i > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, @tagName(span.kind));
        try out.append(allocator, ':');
        try out.appendSlice(allocator, line[span.start..span.end]);
    }
    return .{ .text = try out.toOwnedSlice(allocator), .state = next };
}

test "sink merges adjacent spans of the same kind" {
    var buffer: [4]Span = undefined;
    var sink = Sink.init(&buffer);
    sink.emit(0, 2, .keyword);
    sink.emit(2, 4, .keyword);
    sink.emit(5, 6, .number);
    try std.testing.expectEqual(@as(usize, 2), sink.len);
    try std.testing.expectEqual(@as(u32, 4), sink.items()[0].end);
}

test "language detection" {
    try std.testing.expectEqual(Language.zig, Language.fromPath("/a/build.zig"));
    try std.testing.expectEqual(Language.cpp, Language.fromPath("x.HPP"));
    try std.testing.expectEqual(Language.plain, Language.fromPath("Makefile"));
}
