//! Thin Zig wrappers over the translate-c bindings to the tree-sitter C API
//! (v0.27.1, `ts_api` module built from api.h by build.zig), plus the grammar
//! entry points and the upstream highlight queries embedded by build.zig.
//! No SDL/Zafi/rendering types live here; higher-level highlighting policy is
//! `src/syntax/ts_highlight.zig` in the `zid` module.
const std = @import("std");
const api = @import("ts_api");

/// C ABI structs (TSInput, TSNode, TSQueryMatch, ...) have the same layout as
/// zid's local decls below; convert by casting through the address.
fn castIn(comptime T: type, value: anytype) T {
    return @as(*const T, @ptrCast(&value)).*;
}

pub const queries = @import("ts_queries");

pub const Language = opaque {};
pub const Parser = opaque {
    pub fn create() ?*Parser {
        return @ptrCast(api.ts_parser_new());
    }
    pub fn destroy(self: *Parser) void {
        api.ts_parser_delete(@ptrCast(self));
    }
    pub fn setLanguage(self: *Parser, language: *const Language) bool {
        return api.ts_parser_set_language(@ptrCast(self), @ptrCast(language));
    }
    /// Parse `input` from the start; `old_tree` is ignored unless callers also
    /// report edits via ts_tree_edit (zid currently reparses whole documents).
    pub fn parse(self: *Parser, input: Input, old_tree: ?*const Tree) ?*Tree {
        return @ptrCast(api.ts_parser_parse(@ptrCast(self), @ptrCast(old_tree), castIn(api.TSInput, input)));
    }
    pub fn parseString(self: *Parser, old_tree: ?*const Tree, string: []const u8) ?*Tree {
        return @ptrCast(api.ts_parser_parse_string(@ptrCast(self), @ptrCast(old_tree), string.ptr, @intCast(string.len)));
    }
};
pub const Tree = opaque {
    pub fn destroy(self: *Tree) void {
        api.ts_tree_delete(@ptrCast(self));
    }
    pub fn rootNode(self: *const Tree) Node {
        return castIn(Node, api.ts_tree_root_node(@ptrCast(self)));
    }
};
pub const Node = extern struct {
    context: [4]u32,
    id: ?*const anyopaque,
    tree: ?*const Tree,

    pub fn startByte(self: Node) u32 {
        return api.ts_node_start_byte(castIn(api.TSNode, self));
    }
    pub fn endByte(self: Node) u32 {
        return api.ts_node_end_byte(castIn(api.TSNode, self));
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
        return @ptrCast(api.ts_query_new(@ptrCast(language), source.ptr, @intCast(source.len), &error_offset, @ptrCast(&error_type)) orelse return error.QueryFailed);
    }
    pub fn destroy(self: *Query) void {
        api.ts_query_delete(@ptrCast(self));
    }
    /// Capture name for `id` (the @name in the query), without the '@'.
    pub fn captureNameForId(self: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        const ptr = api.ts_query_capture_name_for_id(@ptrCast(self), id, &len);
        return if (ptr == null) "" else ptr[0..len];
    }
    /// Literal string value for `value_id` in predicates.
    pub fn stringValueForId(self: *const Query, id: u32) []const u8 {
        var len: u32 = 0;
        const ptr = api.ts_query_string_value_for_id(@ptrCast(self), id, &len);
        return if (ptr == null) "" else ptr[0..len];
    }
    /// Predicate steps for `pattern_index`, each predicate starting with a
    /// `string` step (the operator) and terminated by a `done` step.
    pub fn predicatesForPattern(self: *const Query, pattern_index: u16) []const PredicateStep {
        var count: u32 = 0;
        const ptr: [*c]const api.TSQueryPredicateStep = api.ts_query_predicates_for_pattern(@ptrCast(self), pattern_index, &count);
        return if (ptr == null) &.{} else @as([*]const PredicateStep, @ptrCast(ptr))[0..count];
    }
};

pub const QueryCursor = opaque {
    pub fn create() ?*QueryCursor {
        return @ptrCast(api.ts_query_cursor_new());
    }
    pub fn destroy(self: *QueryCursor) void {
        api.ts_query_cursor_delete(@ptrCast(self));
    }
    pub fn exec(self: *QueryCursor, query: *const Query, node: Node) void {
        api.ts_query_cursor_exec(@ptrCast(self), @ptrCast(query), castIn(api.TSNode, node));
    }
    /// Iterate matches; `match.captures` is valid for `capture_count` entries.
    pub fn nextMatch(self: *QueryCursor, match: *Match) bool {
        return api.ts_query_cursor_next_match(@ptrCast(self), @ptrCast(match));
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


