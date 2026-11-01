//! Minimal Zig bindings to the tree-sitter C API (v0.27.1), plus the grammar
//! entry points and the upstream highlight queries embedded by build.zig.
//! No SDL/Zafi/rendering types live here; higher-level highlighting policy is
//! `src/syntax/ts_highlight.zig` in the `zid` module.
const std = @import("std");

pub const queries = @import("ts_queries");

pub const Language = opaque {};
pub const Parser = opaque {
    pub fn create() ?*Parser {
        return ts_parser_new();
    }
    pub fn destroy(self: *Parser) void {
        ts_parser_delete(self);
    }
    pub fn setLanguage(self: *Parser, language: *const Language) bool {
        return ts_parser_set_language(self, language);
    }
    /// Parse `input` from the start; `old_tree` is ignored unless callers also
    /// report edits via ts_tree_edit (zid currently reparses whole documents).
    pub fn parse(self: *Parser, input: Input, old_tree: ?*const Tree) ?*Tree {
        return ts_parser_parse(self, input, old_tree);
    }
    pub fn parseString(self: *Parser, old_tree: ?*const Tree, string: []const u8) ?*Tree {
        return ts_parser_parse_string(self, old_tree, string.ptr, @intCast(string.len));
    }
};
pub const Tree = opaque {
    pub fn destroy(self: *Tree) void {
        ts_tree_delete(self);
    }
    pub fn rootNode(self: *const Tree) Node {
        return ts_tree_root_node(self);
    }
};
pub const Node = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const Tree,

    pub fn startByte(self: Node) u32 {
        return ts_node_start_byte(self);
    }
    pub fn endByte(self: Node) u32 {
        return ts_node_end_byte(self);
    }
};
pub const Point = extern struct { row: u32, column: u32 };
pub const InputEncoding = enum(c_int) { utf8 = 0, utf16_le = 1, utf16_be = 2, custom = 3 };
pub const DecodeFunction = ?*const fn (string: [*c]const u8, length: u32, code_point: [*c]i32) callconv(.c) u32;
pub const Input = extern struct {
    payload: ?*anyopaque,
    read: ?*const fn (payload: ?*anyopaque, byte_index: u32, position: Point, bytes_read: *u32) callconv(.c) [*c]const u8,
    encoding: InputEncoding,
    decode: DecodeFunction,
};

/// Chunked text provider: `read` fills `dst` from `offset` and returns the
/// byte count written (fewer than `dst.len` at EOF). `chunk` is scratch space
/// the tree-sitter read callback hands to the parser.
pub const Source = struct {
    ctx: *const anyopaque,
    len: u32,
    read: *const fn (ctx: *const anyopaque, offset: usize, dst: []u8) usize,
    chunk: [chunk_size]u8 = undefined,

    pub const chunk_size = 16 * 1024;

    pub fn input(self: *Source) Input {
        return .{ .payload = self, .read = readThunk, .encoding = .utf8, .decode = null };
    }
    fn readThunk(payload: ?*anyopaque, byte_index: u32, _: Point, bytes_read: *u32) callconv(.c) [*c]const u8 {
        const source: *Source = @ptrCast(@alignCast(payload.?));
        bytes_read.* = @intCast(source.read(source.ctx, byte_index, &source.chunk));
        return @ptrCast(&source.chunk);
    }
};

pub const Capture = extern struct { node: Node, index: u32 };
pub const Match = extern struct {
    id: u32,
    pattern_index: u16,
    capture_count: u16,
    captures: [*c]const Capture,
};
pub const PredicateStepType = enum(c_uint) { done = 0, capture, string };
pub const PredicateStep = extern struct { type: PredicateStepType, value_id: u32 };
pub const QueryError = enum(c_int) { none = 0, syntax, node_type, field, capture, structure, language };

pub const Query = opaque {
    pub fn create(language: *const Language, source: []const u8) error{QueryFailed}!*Query {
        var error_offset: u32 = 0;
        var error_type: QueryError = .none;
        return ts_query_new(language, source.ptr, @intCast(source.len), &error_offset, &error_type) orelse error.QueryFailed;
    }
    pub fn destroy(self: *Query) void {
        ts_query_delete(self);
    }
    /// Capture name for `id` (the @name in the query), without the '@'.
    pub fn captureNameForId(self: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        const ptr = ts_query_capture_name_for_id(self, id, &len);
        return if (ptr == null) "" else ptr[0..len];
    }
    /// Literal string value for `value_id` in predicates.
    pub fn stringValueForId(self: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        const ptr = ts_query_string_value_for_id(self, id, &len);
        return if (ptr == null) "" else ptr[0..len];
    }
    /// Predicate steps for `pattern_index`, each predicate starting with a
    /// `string` step (the operator) and terminated by a `done` step.
    pub fn predicatesForPattern(self: *const Query, pattern_index: u16) []const PredicateStep {
        var count: u32 = 0;
        const ptr = ts_query_predicates_for_pattern(self, pattern_index, &count);
        return if (ptr == null) &.{} else ptr[0..count];
    }
};

pub const QueryCursor = opaque {
    pub fn create() ?*QueryCursor {
        return ts_query_cursor_new();
    }
    pub fn destroy(self: *QueryCursor) void {
        ts_query_cursor_delete(self);
    }
    pub fn exec(self: *QueryCursor, query: *const Query, node: Node) void {
        ts_query_cursor_exec(self, query, node);
    }
    /// Iterate matches; `match.captures` is valid for `capture_count` entries.
    pub fn nextMatch(self: *QueryCursor, match: *Match) bool {
        return ts_query_cursor_next_match(self, match);
    }
};

// Grammar entry points (each exports its parser tables as a TSLanguage).
pub extern fn tree_sitter_zig() *const Language;
pub extern fn tree_sitter_c() *const Language;
pub extern fn tree_sitter_cpp() *const Language;
pub extern fn tree_sitter_python() *const Language;
pub extern fn tree_sitter_json() *const Language;
pub extern fn tree_sitter_markdown() *const Language;
pub extern fn tree_sitter_markdown_inline() *const Language;

extern fn ts_parser_new() callconv(.c) ?*Parser;
extern fn ts_parser_delete(parser: ?*Parser) callconv(.c) void;
extern fn ts_parser_set_language(parser: ?*Parser, language: ?*const Language) callconv(.c) bool;
extern fn ts_parser_parse(parser: ?*Parser, input: Input, old_tree: ?*const Tree) callconv(.c) ?*Tree;
extern fn ts_parser_parse_string(parser: ?*Parser, old_tree: ?*const Tree, string: [*c]const u8, length: u32) callconv(.c) ?*Tree;
extern fn ts_tree_delete(tree: ?*Tree) callconv(.c) void;
extern fn ts_tree_root_node(tree: ?*const Tree) callconv(.c) Node;
extern fn ts_node_start_byte(node: Node) callconv(.c) u32;
extern fn ts_node_end_byte(node: Node) callconv(.c) u32;
extern fn ts_query_new(language: ?*const Language, source: [*c]const u8, source_len: u32, error_offset: *u32, error_type: *QueryError) callconv(.c) ?*Query;
extern fn ts_query_delete(query: ?*Query) callconv(.c) void;
extern fn ts_query_capture_name_for_id(query: ?*const Query, id: u32, length: *u32) callconv(.c) [*c]const u8;
extern fn ts_query_string_value_for_id(query: ?*const Query, id: u32, length: *u32) callconv(.c) [*c]const u8;
extern fn ts_query_cursor_new() callconv(.c) ?*QueryCursor;
extern fn ts_query_cursor_delete(cursor: ?*QueryCursor) callconv(.c) void;
extern fn ts_query_cursor_exec(cursor: ?*QueryCursor, query: ?*const Query, node: Node) callconv(.c) void;
extern fn ts_query_cursor_next_match(cursor: ?*QueryCursor, match: *Match) callconv(.c) bool;
extern fn ts_query_predicates_for_pattern(query: ?*const Query, pattern_index: u32, step_count: *u32) callconv(.c) [*c]const PredicateStep;
