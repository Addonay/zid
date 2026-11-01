//! Tree-sitter syntax highlighting, Zed-style: each language maps to a pinned
//! grammar plus its upstream `highlights.scm` (embedded by build.zig), parsed
//! once per document revision into a flat, sorted capture list that the editor
//! turns into line spans. Markdown additionally injects its inline grammar
//! into `(inline)` nodes and any loaded grammar into fenced code blocks, like
//! Zed's `injection` layers.
const std = @import("std");
const ts = @import("tree_sitter");
const token = @import("token.zig");

pub const Language = token.Language;
pub const Span = token.Span;
pub const Sink = token.Sink;
pub const Source = ts.Source;

/// A loaded grammar: its compiled TSLanguage plus the embedded highlights query.
pub const Grammar = struct {
    ts_language: *const ts.Language,
    highlights: []const u8,
};

pub fn grammarOf(language: Language) ?Grammar {
    return switch (language) {
        .zig => .{ .ts_language = ts.tree_sitter_zig(), .highlights = ts.queries.zig },
        .c => .{ .ts_language = ts.tree_sitter_c(), .highlights = ts.queries.c },
        .cpp => .{ .ts_language = ts.tree_sitter_cpp(), .highlights = ts.queries.cpp },
        .python => .{ .ts_language = ts.tree_sitter_python(), .highlights = ts.queries.python },
        .json => .{ .ts_language = ts.tree_sitter_json(), .highlights = ts.queries.json },
        .markdown => .{ .ts_language = ts.tree_sitter_markdown(), .highlights = ts.queries.markdown },
        .plain, .sql => null,
    };
}

pub fn supported(language: Language) bool {
    return grammarOf(language) != null;
}

/// Finds `(inline)` regions and fenced code blocks in a markdown tree. The
/// upstream `injections.scm` also injects YAML/TOML frontmatter and HTML; zid
/// has no grammars for those, so only the two shapes it can serve are queried.
const markdown_injections: [:0]const u8 =
    \\(inline) @injection.content
    \\(fenced_code_block
    \\  (info_string (language) @injection.language)
    \\  (code_fence_content) @injection.content)
;

/// Fenced-code info strings → zid languages with a loaded grammar.
fn injectedLanguage(name: []const u8) ?Language {
    const map = .{
        .{ "zig", .zig },           .{ "c", .c },              .{ "h", .c },
        .{ "cpp", .cpp },           .{ "c++", .cpp },          .{ "cc", .cpp },
        .{ "hpp", .cpp },           .{ "python", .python },    .{ "py", .python },
        .{ "json", .json },        .{ "jsonc", .json },
        .{ "markdown", .markdown }, .{ "md", .markdown },
    };
    inline for (map) |entry| if (std.ascii.eqlIgnoreCase(name, entry[0])) return entry[1];
    return null;
}

pub const Capture = struct { start: u32, end: u32, depth: u16, kind: token.Kind };

/// Syntax layer for one document: a parsed tree plus the highlight captures
/// extracted from it (main query and, for markdown, injection layers).
pub const Layer = struct {
    allocator: std.mem.Allocator,
    language: Language,
    parser: ?*ts.Parser = null,
    cursor: ?*ts.QueryCursor = null,
    tree: ?*ts.Tree = null,
    query: ?*ts.Query = null,
    injections: ?*ts.Query = null,
    /// Parser/query pairs for injected languages (markdown-inline plus fenced
    /// code), keyed by Language tag; `inline` is the markdown inline grammar.
    subs: std.AutoHashMapUnmanaged(u8, Sub) = .empty,
    captures: std.ArrayList(Capture) = .empty,

    const sub_inline = std.math.maxInt(u8);

    const Sub = struct {
        parser: *ts.Parser,
        query: *ts.Query,
        trees: std.ArrayList(*ts.Tree) = .empty,
    };

    pub fn init(allocator: std.mem.Allocator, language: Language) !*Layer {
        const g = grammarOf(language) orelse return error.NoGrammar;
        const layer = try allocator.create(Layer);
        layer.* = .{ .allocator = allocator, .language = language };
        errdefer {
            layer.deinitInternals();
            allocator.destroy(layer);
        }
        layer.parser = ts.Parser.create() orelse return error.OutOfMemory;
        layer.cursor = ts.QueryCursor.create() orelse return error.OutOfMemory;
        if (!layer.parser.?.setLanguage(g.ts_language)) return error.BadGrammar;
        layer.query = ts.Query.create(g.ts_language, g.highlights) catch return error.BadQuery;
        if (language == .markdown) {
            layer.injections = ts.Query.create(g.ts_language, markdown_injections) catch null;
        }
        return layer;
    }

    fn deinitInternals(self: *Layer) void {
        if (self.tree) |t| t.destroy();
        if (self.parser) |p| p.destroy();
        if (self.cursor) |c| c.destroy();
        if (self.query) |q| q.destroy();
        if (self.injections) |q| q.destroy();
        var it = self.subs.valueIterator();
        while (it.next()) |sub| {
            for (sub.trees.items) |t| t.destroy();
            sub.trees.deinit(self.allocator);
            sub.parser.destroy();
            sub.query.destroy();
        }
        self.subs.deinit(self.allocator);
        self.captures.deinit(self.allocator);
    }

    pub fn deinit(self: *Layer) void {
        self.deinitInternals();
        self.allocator.destroy(self);
    }

    /// Reparse `source` and rebuild the capture list. Old trees are dropped:
    /// zid currently does full reparses on revision change (see
    /// docs/REFERENCE_NOTES.md); `ts_tree_edit` hooks are a later step.
    pub fn update(self: *Layer, source: *ts.Source) !void {
        const parser = self.parser orelse return error.NoParser;
        const query = self.query orelse return error.NoQuery;
        const cursor = self.cursor orelse return error.NoCursor;
        if (self.tree) |t| t.destroy();
        self.tree = null;
        const tree = parser.parse(source.input(), null) orelse return error.ParseFailed;
        self.tree = tree;
        var subs = self.subs.valueIterator();
        while (subs.next()) |sub| {
            for (sub.trees.items) |t| t.destroy();
            sub.trees.clearRetainingCapacity();
        }
        self.captures.clearRetainingCapacity();
        try self.collect(query, cursor, tree.rootNode(), 0, source, 0);
        if (self.injections) |injections| try self.inject(source, cursor, injections);
        std.mem.sort(Capture, self.captures.items, {}, struct {
            fn lessThan(_: void, a: Capture, b: Capture) bool {
                if (a.start != b.start) return a.start < b.start;
                return a.depth > b.depth; // injected spans win equal starts
            }
        }.lessThan);
    }

    /// Emit line-relative spans for byte range [start, end) of the document.
    /// Multi-line captures are clipped per line, matching the lexers' shape.
    pub fn spansForRange(self: *const Layer, start: u32, end: u32, sink: *Sink) void {
        var prev_end: u32 = 0;
        for (self.captures.items) |capture| {
            if (capture.end <= start) continue;
            if (capture.start >= end) break;
            const s = @max(capture.start, start) - start;
            const e = @min(capture.end, end) - start;
            const clamped = @max(s, prev_end);
            if (e <= clamped) continue;
            sink.emit(clamped, e, capture.kind);
            prev_end = e;
        }
    }

    /// Run `query` under `node`, appending captures as `base + node offsets`.
    fn collect(self: *Layer, query: *const ts.Query, cursor: *ts.QueryCursor, node: ts.Node, depth: u16, source: *const ts.Source, base: u32) !void {
        cursor.exec(query, node);
        var match: ts.Match = undefined;
        while (cursor.nextMatch(&match)) {
            if (!predicatesPass(query, &match, source)) continue;
            const captures = match.captures[0..match.capture_count];
            for (captures) |capture| {
                const kind = kindOf(query.captureNameForId(capture.index)) orelse continue;
                const start = base + capture.node.startByte();
                const end = base + capture.node.endByte();
                if (end > start) try self.captures.append(self.allocator, .{ .start = start, .end = end, .depth = depth, .kind = kind });
            }
        }
    }

    /// Markdown injections: `(inline)` regions get the inline grammar, fenced
    /// code gets the info-string's grammar when zid has one loaded.
    fn inject(self: *Layer, source: *ts.Source, cursor: *ts.QueryCursor, injections: *const ts.Query) !void {
        cursor.exec(injections, self.tree.?.rootNode());
        // Gather every match before processing: query cursors iterate lazily,
        // so parsing a region mid-iteration can invalidate the walk.
        const Region = struct { node: ts.Node, language: ?Language };
        var pending = std.ArrayList(Region).empty;
        defer pending.deinit(self.allocator);
        var match: ts.Match = undefined;
        while (cursor.nextMatch(&match)) {
            const captures = match.captures[0..match.capture_count];
            var content: ?ts.Node = null;
            var lang_node: ?ts.Node = null;
            for (captures) |capture| {
                const name = injections.captureNameForId(capture.index);
                if (std.mem.eql(u8, name, "injection.content")) content = capture.node;
                if (std.mem.eql(u8, name, "injection.language")) lang_node = capture.node;
            }
            const node = content orelse continue;
            var language: ?Language = null;
            if (lang_node) |lang| {
                var buf: [64]u8 = undefined;
                language = injectedLanguage(nodeText(source, lang, &buf));
            }
            try pending.append(self.allocator, .{ .node = node, .language = language });
        }
        for (pending.items) |region| {
            var key: u8 = sub_inline;
            var g: Grammar = .{ .ts_language = ts.tree_sitter_markdown_inline(), .highlights = ts.queries.markdown_inline };
            if (region.language) |language| {
                key = @intFromEnum(language);
                g = grammarOf(language) orelse continue;
            }
            const sub = try self.subFor(key, g);
            const bytes = try self.regionBytes(source, region.node.startByte(), region.node.endByte());
            defer self.allocator.free(bytes);
            var ctx = SliceSource{ .bytes = bytes };
            var sub_source = ts.Source{ .ctx = &ctx, .len = @intCast(bytes.len), .read = sliceRead };
            const tree = sub.parser.parse(sub_source.input(), null) orelse continue;
            try sub.trees.append(self.allocator, tree);
            try self.collect(sub.query, cursor, tree.rootNode(), 1, &sub_source, region.node.startByte());
        }
    }

    fn subFor(self: *Layer, key: u8, g: Grammar) !*Sub {
        const entry = try self.subs.getOrPut(self.allocator, key);
        if (!entry.found_existing) {
            const parser = ts.Parser.create() orelse return error.OutOfMemory;
            errdefer parser.destroy();
            if (!parser.setLanguage(g.ts_language)) return error.BadGrammar;
            const query = ts.Query.create(g.ts_language, g.highlights) catch return error.BadQuery;
            entry.value_ptr.* = .{ .parser = parser, .query = query };
        }
        return entry.value_ptr;
    }

    /// Copy a node range out of `source` into an owned slice for sub-parsing.
    fn regionBytes(self: *Layer, source: *const ts.Source, start: u32, end: u32) ![]u8 {
        const bytes = try self.allocator.alloc(u8, end - start);
        errdefer self.allocator.free(bytes);
        const got = source.read(source.ctx, start, bytes);
        return bytes[0..got];
    }

    fn nodeText(source: *const ts.Source, node: ts.Node, buf: []u8) []const u8 {
        const n = @min(node.endByte() - node.startByte(), buf.len);
        const got = source.read(source.ctx, node.startByte(), buf[0..n]);
        return buf[0..got];
    }
};

/// Slice-backed `ts.Source` for injected regions.
const SliceSource = struct { bytes: []const u8 };

fn sliceRead(ctx: *const anyopaque, offset: usize, dst: []u8) usize {
    const source: *const SliceSource = @ptrCast(@alignCast(ctx));
    if (offset >= source.bytes.len) return 0;
    const n = @min(dst.len, source.bytes.len - offset);
    @memcpy(dst[0..n], source.bytes[offset..][0..n]);
    return n;
}

/// `#eq?`/`#any-of?`/`#match?`-family predicates gating `match`. Steps are
/// (string operator, args...)* terminated by a `done` step. `set!`/`is?`-style
/// metadata and unknown operators do not gate the match; captures beyond eight
/// per pattern and literals beyond eight per predicate are ignored.
fn predicatesPass(query: *const ts.Query, match: *const ts.Match, source: *const ts.Source) bool {
    const steps = query.predicatesForPattern(match.pattern_index);
    const captures = match.captures[0..match.capture_count];
    var scratch: [8][256]u8 = undefined;
    var i: usize = 0;
    while (i < steps.len) {
        if (steps[i].type != .string) break;
        const op = query.stringValueForId(steps[i].value_id);
        i += 1;
        var texts: [8][]const u8 = undefined;
        var text_count: usize = 0;
        var literals: [8][]const u8 = undefined;
        var literal_count: usize = 0;
        while (i < steps.len and steps[i].type != .done) : (i += 1) {
            switch (steps[i].type) {
                .capture => for (captures) |capture| {
                    if (capture.index == steps[i].value_id and text_count < texts.len) {
                        const start = capture.node.startByte();
                        const end = capture.node.endByte();
                        const got = source.read(source.ctx, start, scratch[text_count][0..@min(256, end - start)]);
                        texts[text_count] = scratch[text_count][0..got];
                        text_count += 1;
                    }
                },
                .string => if (literal_count < literals.len) {
                    literals[literal_count] = query.stringValueForId(steps[i].value_id);
                    literal_count += 1;
                },
                .done => {},
            }
        }
        if (!evalPredicate(op, texts[0..text_count], literals[0..literal_count])) return false;
    }
    return true;
}

fn evalPredicate(op: []const u8, texts: []const []const u8, literals: []const []const u8) bool {
    if (std.mem.eql(u8, op, "eq?") or std.mem.eql(u8, op, "any-eq?")) {
        if (literals.len == 0) {
            if (texts.len < 2) return true;
            return std.mem.eql(u8, texts[0], texts[1]);
        }
        for (texts) |text| {
            var found = false;
            for (literals) |lit| if (std.mem.eql(u8, text, lit)) {
                found = true;
                break;
            };
            if (found) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, op, "not-eq?") or std.mem.eql(u8, op, "not-any-eq?")) {
        if (literals.len == 0) {
            if (texts.len < 2) return true;
            return !std.mem.eql(u8, texts[0], texts[1]);
        }
        for (texts) |text| for (literals) |lit| {
            if (std.mem.eql(u8, text, lit)) return false;
        };
        return true;
    }
    if (std.mem.eql(u8, op, "any-of?")) {
        for (texts) |text| for (literals) |lit| {
            if (std.mem.eql(u8, text, lit)) return true;
        };
        return false;
    }
    if (std.mem.eql(u8, op, "not-any-of?")) {
        for (texts) |text| for (literals) |lit| {
            if (std.mem.eql(u8, text, lit)) return false;
        };
        return true;
    }
    if (std.mem.eql(u8, op, "match?") or std.mem.eql(u8, op, "lua-match?") or std.mem.eql(u8, op, "vim-match?")) {
        if (literals.len == 0 or texts.len == 0) return true;
        return patternMatch(texts[0], literals[0]);
    }
    if (std.mem.eql(u8, op, "not-match?") or std.mem.eql(u8, op, "not-lua-match?")) {
        if (literals.len == 0 or texts.len == 0) return true;
        return !patternMatch(texts[0], literals[0]);
    }
    return true; // `set!`, `is?`, `is-not?`, `gsub!`, unknown operators.
}

/// Minimal pattern matcher covering what grammar queries actually use:
/// `^`/`$` anchors, `[...]` ranges and negated classes, `*`, `+`, `?`
/// quantifiers, `.`, `\\x` regex escapes and `%x` lua classes.
fn patternMatch(text: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern[0] == '^') return matchHere(text, pattern[1..]);
    var i: usize = 0;
    while (true) {
        if (matchHere(text[i..], pattern)) return true;
        if (i == text.len) return false;
        i += 1;
    }
}

const Atom = struct {
    next: usize, // pattern index after this atom (before any quantifier)
    literal: u8 = 0,
    set: [256]bool = undefined,
    uses_set: bool = false,
    fn matches(self: *const Atom, c: u8) bool {
        return if (self.uses_set) self.set[c] else c == self.literal;
    }
};

fn matchHere(text: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    if (pattern[0] == '$' and pattern.len == 1) return text.len == 0;
    const atom = parseAtom(pattern) orelse return false;
    const quantifier: u8 = if (atom.next < pattern.len) pattern[atom.next] else 0;
    const rest = if (quantifier == '*' or quantifier == '+' or quantifier == '?') pattern[atom.next + 1 ..] else pattern[atom.next..];
    switch (quantifier) {
        '*', '+' => {
            var count: usize = 0;
            while (count < text.len and atom.matches(text[count])) count += 1;
            const min: usize = if (quantifier == '+') 1 else 0;
            if (count < min) return false;
            while (true) {
                if (matchHere(text[count..], rest)) return true;
                if (count == min) return false;
                count -= 1;
            }
        },
        '?' => {
            if (matchHere(text, rest)) return true;
            return text.len > 0 and atom.matches(text[0]) and matchHere(text[1..], rest);
        },
        else => return text.len > 0 and atom.matches(text[0]) and matchHere(text[1..], rest),
    }
}

fn applyClass(set: *[256]bool, cls: u8) bool {
    switch (cls) {
        'd' => {
            for ('0'..':') |c| set[c] = true;
        },
        'w' => {
            for ('0'..':') |c| set[c] = true;
            for ('a'..'{') |c| set[c] = true;
            for ('A'..'[') |c| set[c] = true;
            set['_'] = true;
        },
        'a', 'l' => {
            for ('a'..'{') |c| set[c] = true;
            for ('A'..'[') |c| set[c] = true;
        },
        'u' => {
            for ('A'..'[') |c| set[c] = true;
        },
        's' => {
            for ([_]u8{ ' ', '\t', '\n', '\r', 11, 12 }) |c| set[c] = true;
        },
        'x' => {
            for ('0'..':') |c| set[c] = true;
            for ('a'..'g') |c| set[c] = true;
            for ('A'..'G') |c| set[c] = true;
        },
        else => return false,
    }
    return true;
}

fn parseAtom(pattern: []const u8) ?Atom {
    if (pattern.len == 0) return null;
    switch (pattern[0]) {
        '.' => {
            var atom = Atom{ .next = 1, .uses_set = true };
            @memset(&atom.set, true);
            return atom;
        },
        '[' => {
            var i: usize = 1;
            const negate = i < pattern.len and pattern[i] == '^';
            if (negate) i += 1;
            var atom = Atom{ .next = 0, .uses_set = true };
            @memset(&atom.set, false);
            var first = true;
            while (i < pattern.len and (first or pattern[i] != ']')) {
                first = false;
                if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                    var c: u16 = pattern[i];
                    while (c <= pattern[i + 2]) : (c += 1) atom.set[c] = true;
                    i += 3;
                } else if ((pattern[i] == '\\' or pattern[i] == '%') and i + 1 < pattern.len and applyClass(&atom.set, pattern[i + 1])) {
                    i += 2;
                } else if ((pattern[i] == '\\' or pattern[i] == '%') and i + 1 < pattern.len) {
                    atom.set[pattern[i + 1]] = true;
                    i += 2;
                } else {
                    atom.set[pattern[i]] = true;
                    i += 1;
                }
            }
            if (i >= pattern.len) return null;
            if (negate) {
                for (&atom.set) |*b| b.* = !b.*;
            }
            atom.next = i + 1;
            return atom;
        },
        '\\', '%' => {
            if (pattern.len < 2) return null;
            const cls = pattern[1];
            var atom = Atom{ .next = 2, .uses_set = true };
            @memset(&atom.set, false);
            if (applyClass(&atom.set, cls)) {
                const negate = std.ascii.isUpper(cls);
                if (negate) {
                    // Recompute as negation of the lowercase class.
                    @memset(&atom.set, true);
                    var lower: [256]bool = undefined;
                    @memset(&lower, false);
                    _ = applyClass(&lower, std.ascii.toLower(cls));
                    for (&atom.set, lower) |*b, l| b.* = !l;
                }
                return atom;
            }
            return .{ .next = 2, .literal = cls }; // escaped literal
        },
        else => return .{ .next = 1, .literal = pattern[0] },
    }
}

/// Capture name → zid token kind. Longest prefix wins; unmapped captures are
/// left plain, matching Zed's rule that unrecognized names carry no highlight.
fn kindOf(name: []const u8) ?token.Kind {
    const table = .{
        .{ "comment.documentation", .comment_doc }, .{ "comment.doc", .comment_doc }, .{ "string.documentation", .comment_doc },
        .{ "comment", .comment },
        .{ "keyword.directive", .preprocessor },     .{ "preproc", .preprocessor },   .{ "include", .preprocessor },
        .{ "keyword.control", .keyword_control },   .{ "keyword.conditional", .keyword_control },
        .{ "keyword.repeat", .keyword_control },    .{ "keyword.return", .keyword_control },
        .{ "keyword.import", .keyword_control },    .{ "keyword.exception", .keyword_control },
        .{ "keyword", .keyword },
        .{ "string.escape", .string_escape },       .{ "string.special", .string_escape },
        .{ "character.escape", .string_escape },    .{ "escape", .string_escape },
        .{ "string", .string },                     .{ "character", .char },
        .{ "float", .number },                      .{ "number", .number },
        .{ "constant.builtin", .constant },         .{ "constant.macro", .constant },
        .{ "constant", .constant },                 .{ "boolean", .constant },   .{ "symbol", .constant },
        .{ "variable.builtin", .variable_special }, .{ "variable.special", .variable_special },
        .{ "variable.member", .property },          .{ "property", .property },
        .{ "member", .property },                   .{ "field", .property },
        .{ "function.builtin", .builtin },          .{ "function.macro", .function },
        .{ "function.method", .function },          .{ "function.call", .function },
        .{ "function", .function },                 .{ "method", .function },    .{ "constructor", .type },
        .{ "type.builtin", .type },                 .{ "type", .type },
        .{ "module", .type },                       .{ "namespace", .type },
        .{ "operator", .operator },
        .{ "punctuation", .punctuation },           .{ "delimiter", .punctuation },
        .{ "attribute", .attribute },               .{ "label", .label },
        .{ "tag", .keyword },
        .{ "markup.heading", .title },
        .{ "markup.strong", .strong },              .{ "markup.italic", .emphasis },
        .{ "markup.strikethrough", .emphasis },
        .{ "markup.raw", .code },
        .{ "markup.link.label", .link_text },       .{ "markup.link.text", .link_text },
        .{ "markup.link.url", .link_uri },          .{ "markup.link.uri", .link_uri },
        .{ "markup.link", .link_text },             .{ "markup.list", .list_marker },
        .{ "markup.quote", .quote },
        .{ "embedded", .code },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0]) or (name.len > entry[0].len and std.mem.startsWith(u8, name, entry[0]) and name[entry[0].len] == '.')) {
            return entry[1];
        }
    }
    return null;
}

fn sliceSource(text: []const u8, source: *ts.Source, ctx: *SliceSource) *ts.Source {
    ctx.* = .{ .bytes = text };
    source.* = .{ .ctx = ctx, .len = @intCast(text.len), .read = sliceRead };
    return source;
}

fn expectSpan(spans: []const Span, start: usize, end: usize, kind: token.Kind) !void {
    for (spans) |span| {
        if (span.start == start and span.end == end and span.kind == kind) return;
    }
    std.debug.print("missing span {d}..{d} {t} in {any}\n", .{ start, end, kind, spans });
    return error.TestExpectedSpan;
}

test "zig source highlights keywords, strings and numbers" {
    const text = "const x: u32 = 42;\n// hi\n";
    var ctx: SliceSource = undefined;
    var source: ts.Source = undefined;
    const layer = try Layer.init(std.testing.allocator, .zig);
    defer layer.deinit();
    try layer.update(sliceSource(text, &source, &ctx));

    var buf: [64]Span = undefined;
    var sink = Sink.init(&buf);
    layer.spansForRange(0, 18, &sink);
    try expectSpan(sink.items(), 0, 5, .keyword);
    try expectSpan(sink.items(), 9, 12, .type);
    try expectSpan(sink.items(), 15, 17, .number);
    sink = Sink.init(&buf);
    layer.spansForRange(18, text.len, &sink);
    try expectSpan(sink.items(), 1, 6, .comment);
}

test "markdown injects the fenced code block grammar" {
    const text = "# Head\n\n```zig\nconst x = 1;\n```\n";
    var ctx: SliceSource = undefined;
    var source: ts.Source = undefined;
    const layer = try Layer.init(std.testing.allocator, .markdown);
    defer layer.deinit();
    try layer.update(sliceSource(text, &source, &ctx));

    var buf: [64]Span = undefined;
    var sink = Sink.init(&buf);
    // "const" inside the fenced block at byte 14 must come from the zig grammar.
    const fence = std.mem.indexOf(u8, text, "const").?;
    sink = Sink.init(&buf);
    layer.spansForRange(@intCast(fence), @intCast(fence + 5), &sink);
    try expectSpan(sink.items(), 0, 5, .keyword);
}

test "json highlights keys as properties" {
    const text = "{\"k\": true}\n";
    var ctx: SliceSource = undefined;
    var source: ts.Source = undefined;
    const layer = try Layer.init(std.testing.allocator, .json);
    defer layer.deinit();
    try layer.update(sliceSource(text, &source, &ctx));

    var buf: [64]Span = undefined;
    var sink = Sink.init(&buf);
    layer.spansForRange(0, text.len, &sink);
    try expectSpan(sink.items(), 6, 10, .constant);
}

