//! Zed-compatible keymaps: the bundled upstream default (Linux) plus the user's
//! `keymap.json`, both in Zed's schema `[{ "context": "...", "bindings": { "ctrl-k ctrl-s": "zed::OpenKeymap" } }]`.
//!
//! Resolution follows GPUI (`.ref/zed/crates/gpui/src/keymap.rs`): a binding's context
//! predicate is evaluated against the focus path (root → focused element). Deeper
//! matches take precedence, later definitions win at equal depth (so the user keymap
//! overrides defaults), and the caller skips bindings whose action is unavailable in the
//! current state. A `null` action disables a keystroke in its context.
//!
//! Pure Zig, no SDL: the app translates key events into `Keystroke`s.
const std = @import("std");

pub const max_chord = 4;

pub const Keystroke = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
    key_buf: [16]u8 = undefined,
    key_len: u8 = 0,

    pub fn key(self: *const Keystroke) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    pub fn eql(a: Keystroke, b: Keystroke) bool {
        return a.ctrl == b.ctrl and a.alt == b.alt and a.shift == b.shift and a.super == b.super and std.mem.eql(u8, a.key(), b.key());
    }

    /// Parses one Zed keystroke such as `ctrl-shift-p`, `ctrl--`, `alt-ctrl-shift-w`, `f11`.
    pub fn parse(text: []const u8) !Keystroke {
        var out: Keystroke = .{};
        var rest = text;
        while (true) {
            const dash = std.mem.indexOfScalar(u8, rest, '-') orelse break;
            if (dash == 0 or dash + 1 >= rest.len) break; // "-" key itself, or "ctrl--"
            const modifier = rest[0..dash];
            if (std.mem.eql(u8, modifier, "ctrl")) out.ctrl = true else if (std.mem.eql(u8, modifier, "alt")) out.alt = true else if (std.mem.eql(u8, modifier, "shift")) out.shift = true else if (std.mem.eql(u8, modifier, "super") or std.mem.eql(u8, modifier, "cmd") or std.mem.eql(u8, modifier, "win")) out.super = true else if (std.mem.eql(u8, modifier, "fn")) {} else break;
            rest = rest[dash + 1 ..];
        }
        if (rest.len == 0 or rest.len > out.key_buf.len) return error.InvalidKeystroke;
        for (rest, 0..) |c, i| out.key_buf[i] = std.ascii.toLower(c);
        out.key_len = @intCast(rest.len);
        return out;
    }

    /// Display text in Zed's Linux style: `Ctrl-Shift-P`.
    pub fn format(self: Keystroke, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.ctrl) try writer.writeAll("Ctrl-");
        if (self.alt) try writer.writeAll("Alt-");
        if (self.shift) try writer.writeAll("Shift-");
        if (self.super) try writer.writeAll("Super-");
        try writer.writeAll(displayKey(self.key()));
    }
};

/// Human-readable key names used by the keymap UI.
pub fn displayKey(key: []const u8) []const u8 {
    const names = [_][2][]const u8{
        .{ "enter", "Enter" },   .{ "escape", "Esc" },        .{ "backspace", "Backspace" }, .{ "delete", "Delete" },
        .{ "tab", "Tab" },       .{ "space", "Space" },       .{ "up", "Up" },               .{ "down", "Down" },
        .{ "left", "Left" },     .{ "right", "Right" },       .{ "home", "Home" },           .{ "end", "End" },
        .{ "pageup", "PageUp" }, .{ "pagedown", "PageDown" }, .{ "insert", "Insert" },       .{ "menu", "Menu" },
        .{ "a", "A" },           .{ "b", "B" },               .{ "c", "C" },                 .{ "d", "D" },
        .{ "e", "E" },           .{ "f", "F" },               .{ "g", "G" },                 .{ "h", "H" },
        .{ "i", "I" },           .{ "j", "J" },               .{ "k", "K" },                 .{ "l", "L" },
        .{ "m", "M" },           .{ "n", "N" },               .{ "o", "O" },                 .{ "p", "P" },
        .{ "q", "Q" },           .{ "r", "R" },               .{ "s", "S" },                 .{ "t", "T" },
        .{ "u", "U" },           .{ "v", "V" },               .{ "w", "W" },                 .{ "x", "X" },
        .{ "y", "Y" },           .{ "z", "Z" },               .{ "f1", "F1" },               .{ "f2", "F2" },
        .{ "f3", "F3" },         .{ "f4", "F4" },             .{ "f5", "F5" },               .{ "f6", "F6" },
        .{ "f7", "F7" },         .{ "f8", "F8" },             .{ "f9", "F9" },               .{ "f10", "F10" },
        .{ "f11", "F11" },       .{ "f12", "F12" },
    };
    for (names) |pair| if (std.mem.eql(u8, pair[0], key)) return pair[1];
    return key;
}

pub const Chord = struct {
    keys: [max_chord]Keystroke = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Chord) []const Keystroke {
        return self.keys[0..self.len];
    }
    pub fn parse(text: []const u8) !Chord {
        var out: Chord = .{};
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        while (it.next()) |part| {
            if (out.len == max_chord) return error.ChordTooLong;
            out.keys[out.len] = try Keystroke.parse(part);
            out.len += 1;
        }
        if (out.len == 0) return error.InvalidKeystroke;
        return out;
    }
    pub fn format(self: Chord, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.slice(), 0..) |k, i| {
            if (i > 0) try writer.writeByte(' ');
            try k.format(writer);
        }
    }
};

// ---------------------------------------------------------------- contexts

/// One element of the focus path, e.g. `Editor` with `mode=full`, `extension=zig`.
pub const Context = struct {
    name: []const u8,
    flags: []const []const u8 = &.{},
    pairs: []const [2][]const u8 = &.{},

    fn has(self: Context, ident: []const u8) bool {
        if (std.mem.eql(u8, self.name, ident)) return true;
        for (self.flags) |f| if (std.mem.eql(u8, f, ident)) return true;
        return false;
    }
    fn value(self: Context, key: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], key)) return p[1];
        return null;
    }
};

/// Parsed context predicate. Precedence (low → high): `>`, `||`, `&&`, `!`.
pub const Predicate = union(enum) {
    ident: []const u8,
    equal: [2][]const u8,
    not_equal: [2][]const u8,
    not: *const Predicate,
    @"and": [2]*const Predicate,
    @"or": [2]*const Predicate,
    child: [2]*const Predicate,

    /// True when the predicate holds for `path` (root first, focused element last).
    pub fn eval(self: *const Predicate, path: []const Context) bool {
        if (path.len == 0) return false;
        const last = path[path.len - 1];
        return switch (self.*) {
            .ident => |name| last.has(name),
            .equal => |kv| if (last.value(kv[0])) |v| std.mem.eql(u8, v, kv[1]) else false,
            .not_equal => |kv| if (last.value(kv[0])) |v| !std.mem.eql(u8, v, kv[1]) else true,
            .not => |inner| !inner.eval(path),
            .@"and" => |pair| pair[0].eval(path) and pair[1].eval(path),
            .@"or" => |pair| pair[0].eval(path) or pair[1].eval(path),
            .child => |pair| blk: {
                if (!pair[1].eval(path)) break :blk false;
                for (0..path.len - 1) |i| if (pair[0].eval(path[0 .. i + 1])) break :blk true;
                break :blk false;
            },
        };
    }

    pub fn parse(arena: std.mem.Allocator, text: []const u8) !*const Predicate {
        var p: Parser = .{ .arena = arena, .src = text };
        const result = try p.child();
        p.skip();
        if (p.pos != p.src.len) return error.InvalidContext;
        return result;
    }
};

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    fn skip(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] == ' ') self.pos += 1;
    }
    fn eat(self: *Parser, token: []const u8) bool {
        self.skip();
        if (std.mem.startsWith(u8, self.src[self.pos..], token)) {
            self.pos += token.len;
            return true;
        }
        return false;
    }
    fn node(self: *Parser, value: Predicate) !*const Predicate {
        const n = try self.arena.create(Predicate);
        n.* = value;
        return n;
    }
    fn child(self: *Parser) anyerror!*const Predicate {
        var left = try self.orExpr();
        while (self.eat(">")) left = try self.node(.{ .child = .{ left, try self.orExpr() } });
        return left;
    }
    fn orExpr(self: *Parser) anyerror!*const Predicate {
        var left = try self.andExpr();
        while (self.eat("||")) left = try self.node(.{ .@"or" = .{ left, try self.andExpr() } });
        return left;
    }
    fn andExpr(self: *Parser) anyerror!*const Predicate {
        var left = try self.unary();
        while (self.eat("&&")) left = try self.node(.{ .@"and" = .{ left, try self.unary() } });
        return left;
    }
    fn unary(self: *Parser) anyerror!*const Predicate {
        if (self.eat("!")) return self.node(.{ .not = try self.unary() });
        if (self.eat("(")) {
            const inner = try self.child();
            if (!self.eat(")")) return error.InvalidContext;
            return inner;
        }
        const name = try self.ident();
        if (self.eat("==")) return self.node(.{ .equal = .{ name, try self.ident() } });
        if (self.eat("!=")) return self.node(.{ .not_equal = .{ name, try self.ident() } });
        return self.node(.{ .ident = name });
    }
    fn ident(self: *Parser) ![]const u8 {
        self.skip();
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) break;
        }
        if (self.pos == start) return error.InvalidContext;
        return self.src[start..self.pos];
    }
};

// ---------------------------------------------------------------- keymap

pub const Source = enum { default, base, vim, user };

pub const Binding = struct {
    chord: Chord,
    /// Raw context text (empty for global) and its parsed predicate.
    context: []const u8,
    predicate: ?*const Predicate,
    /// Zed action name, or null when the binding disables the keystroke.
    action: ?[]const u8,
    /// Action argument (Zed's `["name", arg]` form), owned by the keymap arena.
    arg: ?std.json.Value,
    source: Source,

    /// Depth of the deepest focus-path prefix on which the context holds, or null.
    pub fn matchDepth(self: *const Binding, path: []const Context) ?usize {
        const predicate = self.predicate orelse return 0;
        var depth = path.len;
        while (depth > 0) : (depth -= 1) if (predicate.eval(path[0..depth])) return depth;
        return null;
    }
};

pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    bindings: std.ArrayList(Binding) = .empty,
    /// Entries skipped while loading (unparseable keystrokes or contexts), for diagnostics.
    skipped: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Keymap {
        return .{ .arena = .init(gpa) };
    }
    pub fn deinit(self: *Keymap) void {
        self.arena.deinit();
    }

    /// Appends every binding of a Zed-schema keymap (JSONC: comments and trailing commas allowed).
    pub fn load(self: *Keymap, json_text: []const u8, source: Source) !void {
        const a = self.arena.allocator();
        const clean = try @import("config.zig").jsonc(a, json_text);
        const root = try std.json.parseFromSliceLeaky(std.json.Value, a, clean, .{});
        if (root != .array) return error.InvalidKeymap;
        for (root.array.items) |section| {
            if (section != .object) continue;
            const context: []const u8 = if (section.object.get("context")) |c| (if (c == .string) c.string else "") else "";
            const predicate: ?*const Predicate = if (context.len == 0) null else Predicate.parse(a, context) catch {
                self.skipped += 1;
                continue;
            };
            const bindings = section.object.get("bindings") orelse continue;
            if (bindings != .object) continue;
            var it = bindings.object.iterator();
            while (it.next()) |entry| {
                const chord = Chord.parse(entry.key_ptr.*) catch {
                    self.skipped += 1;
                    continue;
                };
                var action: ?[]const u8 = null;
                var arg: ?std.json.Value = null;
                switch (entry.value_ptr.*) {
                    .string => |s| action = s,
                    .array => |items| if (items.items.len > 0 and items.items[0] == .string) {
                        action = items.items[0].string;
                        if (items.items.len > 1) arg = items.items[1];
                    } else {
                        self.skipped += 1;
                        continue;
                    },
                    .null => {},
                    else => {
                        self.skipped += 1;
                        continue;
                    },
                }
                try self.bindings.append(a, .{ .chord = chord, .context = context, .predicate = predicate, .action = action, .arg = arg, .source = source });
            }
        }
    }

    pub const Match = struct { binding: *const Binding, depth: usize, index: usize };

    /// Bindings whose chord equals `typed`, matching `path`, in precedence order
    /// (deepest context first, then most recently defined).
    pub fn exact(self: *const Keymap, gpa: std.mem.Allocator, typed: []const Keystroke, path: []const Context) ![]Match {
        var out: std.ArrayList(Match) = .empty;
        errdefer out.deinit(gpa);
        for (self.bindings.items, 0..) |*b, i| {
            if (!chordEql(b.chord.slice(), typed)) continue;
            const depth = b.matchDepth(path) orelse continue;
            try out.append(gpa, .{ .binding = b, .depth = depth, .index = i });
        }
        std.mem.sort(Match, out.items, {}, struct {
            fn before(_: void, x: Match, y: Match) bool {
                if (x.depth != y.depth) return x.depth > y.depth;
                return x.index > y.index;
            }
        }.before);
        return out.toOwnedSlice(gpa);
    }

    /// True when some context-matching binding extends `typed` with more keystrokes.
    pub fn isPrefix(self: *const Keymap, typed: []const Keystroke, path: []const Context) bool {
        for (self.bindings.items) |*b| {
            const keys = b.chord.slice();
            if (keys.len <= typed.len or b.action == null) continue;
            if (!chordEql(keys[0..typed.len], typed)) continue;
            if (b.matchDepth(path) != null) return true;
        }
        return false;
    }

    /// Highest-precedence chord bound to `action` in `path`, for menus and hints.
    pub fn chordFor(self: *const Keymap, action: []const u8, path: []const Context) ?Chord {
        var best: ?Chord = null;
        var best_depth: usize = 0;
        for (self.bindings.items) |*b| {
            const name = b.action orelse continue;
            if (!std.mem.eql(u8, name, action)) continue;
            const depth = b.matchDepth(path) orelse continue;
            if (best == null or depth >= best_depth) {
                best = b.chord;
                best_depth = depth;
            }
        }
        return best;
    }
};

fn chordEql(a: []const Keystroke, b: []const Keystroke) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "keystrokes parse Zed syntax including dash keys" {
    const a = try Keystroke.parse("ctrl-shift-p");
    try testing.expect(a.ctrl and a.shift and !a.alt);
    try testing.expectEqualStrings("p", a.key());
    const minus = try Keystroke.parse("ctrl--");
    try testing.expect(minus.ctrl);
    try testing.expectEqualStrings("-", minus.key());
    try testing.expectEqualStrings("-", (try Keystroke.parse("-")).key());
    const chord = try Chord.parse("ctrl-k ctrl-s");
    try testing.expectEqual(@as(u8, 2), chord.len);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try chord.format(&w);
    try testing.expectEqualStrings("Ctrl-K Ctrl-S", w.buffered());
}

test "context predicates follow Zed precedence and descendant semantics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = [_]Context{
        .{ .name = "Workspace" },
        .{ .name = "Pane" },
        .{ .name = "Editor", .pairs = &.{ .{ "mode", "full" }, .{ "extension", "zig" } } },
    };
    try testing.expect((try Predicate.parse(a, "Editor && mode == full")).eval(&path));
    try testing.expect(!(try Predicate.parse(a, "Editor && mode == auto_height")).eval(&path));
    try testing.expect((try Predicate.parse(a, "Workspace > Editor")).eval(&path));
    try testing.expect(!(try Predicate.parse(a, "Picker > Editor")).eval(&path));
    try testing.expect((try Predicate.parse(a, "!Terminal")).eval(&path));
    try testing.expect((try Predicate.parse(a, "Editor && (extension == md || extension == zig)")).eval(&path));
    try testing.expect((try Predicate.parse(a, "Pane")).eval(path[0..2]));
}

test "supplied Zed platform, base, Vim and override keymaps load unchanged" {
    const assets = @import("keymap_assets");
    for (std.enums.values(assets.BaseKeymap)) |base| {
        var map = Keymap.init(std.testing.allocator);
        defer map.deinit();
        if (base != .None) {
            try map.load(assets.platform_default, .default);
            if (assets.base(base)) |bytes| try map.load(bytes, .base);
            try map.load(assets.vim, .vim);
            try map.load(assets.specific_overrides, .default);
        }
        if (base == .None) try std.testing.expectEqual(@as(usize, 0), map.bindings.items.len) else try std.testing.expect(map.bindings.items.len > 100);
    }
}

test "the bundled Zed keymap loads and resolves by depth and order" {
    var keymap = Keymap.init(testing.allocator);
    defer keymap.deinit();
    try keymap.load(@import("keymap_assets").zed_default_linux, .default);
    try testing.expect(keymap.bindings.items.len > 900);
    const editor_path = [_]Context{ .{ .name = "Workspace" }, .{ .name = "Pane" }, .{ .name = "Editor", .pairs = &.{.{ "mode", "full" }} } };
    const up = [_]Keystroke{try Keystroke.parse("up")};
    const matches = try keymap.exact(testing.allocator, &up, &editor_path);
    defer testing.allocator.free(matches);
    // Editor's binding outranks the global menu binding; both are candidates.
    try testing.expectEqualStrings("editor::MoveUp", matches[0].binding.action.?);
    try testing.expectEqualStrings("menu::SelectPrevious", matches[matches.len - 1].binding.action.?);
    const ctrl_k = [_]Keystroke{try Keystroke.parse("ctrl-k")};
    try testing.expect(keymap.isPrefix(&ctrl_k, &editor_path));
    const chord = keymap.chordFor("file_finder::Toggle", &editor_path).?;
    try testing.expect(chord.keys[0].ctrl);
    // User bindings defined later win at equal depth; null disables.
    try keymap.load("[{\"context\":\"Workspace\",\"bindings\":{\"ctrl-p\":null}}]", .user);
    const ctrl_p = [_]Keystroke{try Keystroke.parse("ctrl-p")};
    const workspace_path = editor_path[0..1];
    const overridden = try keymap.exact(testing.allocator, &ctrl_p, workspace_path);
    defer testing.allocator.free(overridden);
    try testing.expect(overridden[0].binding.action == null);
}

test "buffer search key bindings resolve in the single-line focus path" {
    var map = Keymap.init(testing.allocator);
    defer map.deinit();
    try map.load(@import("keymap_assets").zed_default_linux, .default);
    const path = [_]Context{ .{ .name = "Workspace" }, .{ .name = "Pane" }, .{ .name = "BufferSearchBar" }, .{ .name = "Editor", .pairs = &.{.{ "mode", "single_line" }} } };
    for ([_][2][]const u8{ .{ "enter", "search::SelectNextMatch" }, .{ "shift-enter", "search::SelectPreviousMatch" }, .{ "escape", "buffer_search::Dismiss" } }) |pair| {
        const key = [_]Keystroke{try Keystroke.parse(pair[0])};
        const matches = try map.exact(testing.allocator, &key, &path);
        defer testing.allocator.free(matches);
        var found = false;
        for (matches) |m| if (m.binding.action) |action| {
            if (std.mem.eql(u8, action, pair[1])) found = true;
        };
        try testing.expect(found);
    }
}
