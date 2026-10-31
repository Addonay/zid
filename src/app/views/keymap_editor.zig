//! Zed-style keymap editor (`zed::OpenKeymap`, Ctrl+K Ctrl+S): search field, bindings table and
//! keycap chips. Rendering, filtering and hit-testing only; the app owns input and focus.
//!
//! Adopted Zed measurements (reference checkout `.ref/zed`):
//! - Root padding `p_2` (8px) and `gap_1` (4px) between the search row and the table (`keymap_editor.rs` ~2030-2040).
//! - Search field `h_8` (32px), `px_2` (8px) inset, `border_1` in `colors.border`, rounded (`keymap_editor.rs` ~2050-2060).
//!   Zid uses a 4px radius from the brief. Placeholder text "Filter action names…" (`keymap_editor.rs:585`).
//! - Columns: a 36px leading column, then Action / Arguments / Keystrokes / Context / Source at fractions
//!   0.25 / 0.20 / 0.14 / 0.45 / 0.08 (`keymap_editor.rs` ~650-672). They sum to 1.12, so Zid normalizes them over
//!   the width left after the leading column. Header titles match `keymap_editor.rs:2152`.
//! - Header and rows: `py_1` cells with a 1px `border_variant` rule under the header (`ui/src/components/data_table.rs:760-764`).
//!   Zid uses 24px rows (the brief's body row height) and an 8px cell inset.
//! - Striping: odd rows get `text` at 5% opacity. Hover: `element_hover` at 60% (`data_table.rs:632-653`).
//! - Selection: 1px `border_focused` outline (Zed's `panel_focused_border`, `keymap_editor.rs:2365-2375`) over `element_selected`.
//! - Keystrokes: 4px gap between chord keystrokes (`ui/src/components/keybinding.rs:280`). Zed draws Linux keys as
//!   muted text with no background (`keybinding.rs:259-290, 540-565`). The chip background is a Zid addition.
//! - Action names: `humanize` ports `command_palette/src/command_palette.rs:867` (`humanize_action_name`).
//! - Empty result text "No matches found for the provided query" (`keymap_editor.rs:1270`).
//! - Unimplemented actions: muted text with a "not yet in Zid" tag (Zid addition).
//! - Context shows "—" for global bindings (brief). Zed shows "<global>" (`keymap_editor.rs` ~1936).
const std = @import("std");
const sdl = @import("sdl3");
const Renderer = @import("../../gfx/renderer.zig").Renderer;
const Theme = @import("../theme.zig").Theme;
const Rect = @import("../layout.zig").Rect;
const LineInput = @import("../line_input.zig").LineInput;
const keymap = @import("../keymap.zig");
const fuzzy = @import("../fuzzy.zig");

pub const Availability = struct {
    ctx: *anyopaque,
    /// True when Zid implements this Zed action; unimplemented rows render muted with a small "not yet in Zid" tag.
    implemented: *const fn (ctx: *anyopaque, action: []const u8) bool,
};

pub const State = struct {
    search: LineInput = .{},
    rows: std.ArrayList(u32) = .empty, // indices into keymap.bindings, filtered + sorted
    selected: usize = 0,
    scroll: usize = 0,

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.rows.deinit(gpa);
    }
};

// ---------------------------------------------------------------- metrics (logical px)

const pad: f32 = 8;
const field_gap: f32 = 4;
const field_h: f32 = 32;
const field_radius: f32 = 4;
const row_h: f32 = 24;
const header_h: f32 = 24;
const leading_w: f32 = 36;
const cell_pad: f32 = 8;
const baseline_row: f32 = 17;
const baseline_field: f32 = 21;
const chip_h: f32 = 18;
const chip_gap: f32 = 4;
const chip_pad: f32 = 4;
const tag_h: f32 = 16;
const tag_pad: f32 = 6;
const tag_gap: f32 = 6;

const placeholder_text = "Filter action names…";
const empty_text = "No matches found for the provided query";
const tag_text = "not in Zid";
const ellipsis = "…";
const global_context = "—";
/// Zed uses 0.25/0.20/0.14/0.45/0.08; Zid widens Action (it carries the "not in Zid" tag)
/// and narrows Context, which rarely needs 45%.
const column_fractions = [_]f32{ 0.36, 0.14, 0.16, 0.30, 0.08 };
const column_titles = [_][]const u8{ "Action", "Arguments", "Keystrokes", "Context", "Source" };

const Geometry = struct {
    field: Rect,
    table_x: f32,
    table_w: f32,
    header_y: f32,
    rows_y: f32,
    rows_bottom: f32,
    /// Action, Arguments, Keystrokes, Context, Source (x and width only).
    col_x: [column_fractions.len]f32,
    col_w: [column_fractions.len]f32,
};

fn geometry(area: Rect) Geometry {
    const table_x = area.x + pad;
    const table_w = @max(0, area.w - 2 * pad);
    const header_y = area.y + pad + field_h + field_gap;
    const body_w = @max(0, table_w - leading_w);
    var total: f32 = 0;
    for (column_fractions) |f| total += f;
    var g: Geometry = .{
        .field = .{ .x = table_x, .y = area.y + pad, .w = table_w, .h = field_h },
        .table_x = table_x,
        .table_w = table_w,
        .header_y = header_y,
        .rows_y = header_y + header_h + 1,
        .rows_bottom = area.y + area.h - pad,
        .col_x = undefined,
        .col_w = undefined,
    };
    var x = table_x + leading_w;
    for (column_fractions, 0..) |f, i| {
        g.col_w[i] = body_w * f / total;
        g.col_x[i] = x;
        x += g.col_w[i];
    }
    return g;
}

/// Number of fully visible body rows in `area`.
pub fn pageRows(area: Rect) usize {
    const g = geometry(area);
    const h = g.rows_bottom - g.rows_y;
    if (h < row_h) return 1;
    return @max(1, @as(usize, @intFromFloat(@floor(h / row_h))));
}

/// Index into `state.rows` of the body row under (mx, my), or null.
pub fn rowAt(area: Rect, state: *const State, mx: f32, my: f32) ?usize {
    const g = geometry(area);
    if (mx < g.table_x or mx >= g.table_x + g.table_w) return null;
    if (my < g.rows_y or my >= g.rows_bottom) return null;
    const offset: usize = @intFromFloat(@floor((my - g.rows_y) / row_h));
    const index = state.scroll + offset;
    if (index >= state.rows.items.len) return null;
    return index;
}

/// Moves the selection by `delta` rows, clamped to the filtered list.
pub fn moveSelection(state: *State, delta: isize) void {
    const count = state.rows.items.len;
    if (count == 0) {
        state.selected = 0;
        return;
    }
    const current: isize = @intCast(state.selected);
    const last: isize = @intCast(count - 1);
    state.selected = @intCast(std.math.clamp(current + delta, 0, last));
}

// ---------------------------------------------------------------- filtering

const Haystack = struct {
    buf: [fuzzy.max_haystack]u8 = undefined,
    len: usize = 0,

    fn add(self: *Haystack, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }
    fn slice(self: *const Haystack) []const u8 {
        return self.buf[0..self.len];
    }
};

const Scored = struct {
    index: u32,
    score: i32,

    fn before(_: void, a: Scored, b: Scored) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.index < b.index;
    }
};

/// Default order: humanized action, then keystrokes, then keymap order.
const DefaultOrder = struct {
    km: *const keymap.Keymap,

    fn lessThan(self: DefaultOrder, a: u32, b: u32) bool {
        const x = self.km.bindings.items[a];
        const y = self.km.bindings.items[b];
        var name_a: [256]u8 = undefined;
        var name_b: [256]u8 = undefined;
        const ha = humanize(x.action orelse "", &name_a);
        const hb = humanize(y.action orelse "", &name_b);
        if (!std.mem.eql(u8, ha, hb)) return std.mem.lessThan(u8, ha, hb);
        var keys_a: [96]u8 = undefined;
        var keys_b: [96]u8 = undefined;
        const ka = chordText(x.chord, &keys_a);
        const kb = chordText(y.chord, &keys_b);
        if (!std.mem.eql(u8, ka, kb)) return std.mem.lessThan(u8, ka, kb);
        return a < b;
    }
};

/// Rebuilds `state.rows` from the search text. Empty search lists every bound action sorted by name;
/// otherwise rows are fuzzy-matched against "humanized action, raw action, keystrokes, context" and ordered by score.
/// Bindings that disable a keystroke (null action) are never listed.
pub fn refilter(state: *State, gpa: std.mem.Allocator, km: *const keymap.Keymap) !void {
    state.rows.clearRetainingCapacity();
    const query = std.mem.trim(u8, state.search.text(), " ");
    if (query.len == 0) {
        for (km.bindings.items, 0..) |b, i| {
            if (b.action != null) try state.rows.append(gpa, @intCast(i));
        }
        std.mem.sort(u32, state.rows.items, DefaultOrder{ .km = km }, DefaultOrder.lessThan);
    } else {
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(gpa);
        for (km.bindings.items, 0..) |b, i| {
            const action = b.action orelse continue;
            var name_buf: [256]u8 = undefined;
            var keys_buf: [96]u8 = undefined;
            var hay: Haystack = .{};
            hay.add(humanize(action, &name_buf));
            hay.add(" ");
            hay.add(action);
            hay.add(" ");
            hay.add(chordText(b.chord, &keys_buf));
            hay.add(" ");
            hay.add(b.context);
            const m = fuzzy.match(query, hay.slice()) orelse continue;
            try scored.append(gpa, .{ .index = @intCast(i), .score = m.score });
        }
        std.mem.sort(Scored, scored.items, {}, Scored.before);
        for (scored.items) |s| try state.rows.append(gpa, s.index);
    }
    const count = state.rows.items.len;
    state.selected = if (count == 0) 0 else @min(state.selected, count - 1);
    state.scroll = @min(state.scroll, count -| 1);
}

/// Zed command-palette style humanization: "editor::MoveToBeginningOfLine" -> "editor: move to beginning of line".
/// Namespaces keep their snake_case, `_` becomes a space, CamelCase splits into lowercase words, and acronyms
/// stay upper case ("OpenURL" -> "open URL"). Digits and non-ASCII bytes pass through. Output is truncated to `buf`.
pub fn humanize(action: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < action.len) {
        const c = action[i];
        if (c == ':') {
            if (n > 0 and buf[n - 1] == ':') push(buf, &n, ' ') else push(buf, &n, ':');
            i += 1;
        } else if (c == '_') {
            push(buf, &n, ' ');
            i += 1;
        } else if (std.ascii.isUpper(c)) {
            const start = i;
            i += 1;
            while (i < action.len and std.ascii.isUpper(action[i])) i += 1;
            const run = action[start..i];
            if (run.len > 1) {
                // "URLParser": the last capital starts the next word when a lowercase letter follows.
                const split_before_last = i < action.len and std.ascii.isLower(action[i]);
                const acronym_end = if (split_before_last) run.len - 1 else run.len;
                if (acronym_end > 0) {
                    spaceBefore(buf, &n);
                    for (run[0..acronym_end]) |u| push(buf, &n, u);
                }
                if (split_before_last) {
                    spaceBefore(buf, &n);
                    push(buf, &n, std.ascii.toLower(run[acronym_end]));
                }
            } else {
                spaceBefore(buf, &n);
                push(buf, &n, std.ascii.toLower(c));
            }
        } else {
            push(buf, &n, c);
            i += 1;
        }
    }
    return buf[0..n];
}

fn push(buf: []u8, n: *usize, byte: u8) void {
    if (n.* < buf.len) {
        buf[n.*] = byte;
        n.* += 1;
    }
}

/// Word separator before a new word. Unlike Zed, no leading space is emitted at the very start.
fn spaceBefore(buf: []u8, n: *usize) void {
    if (n.* > 0 and buf[n.* - 1] != ' ') push(buf, n, ' ');
}

fn chordText(chord: keymap.Chord, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    chord.format(&w) catch {};
    return w.buffered();
}

// ---------------------------------------------------------------- drawing

/// Draws the whole view into `area` (the editor pane rectangle). Adjusts `state.scroll` so the selection stays visible.
pub fn draw(r: *Renderer, t: Theme, area: Rect, km: *const keymap.Keymap, state: *State, avail: Availability, mouse: [2]f32, caret_visible: bool) !void {
    const g = geometry(area);
    const visible = pageRows(area);
    const count = state.rows.items.len;
    if (count == 0) {
        state.selected = 0;
        state.scroll = 0;
    } else {
        state.selected = @min(state.selected, count - 1);
        if (state.selected < state.scroll) state.scroll = state.selected;
        if (state.selected >= state.scroll + visible) state.scroll = state.selected + 1 - visible;
        state.scroll = @min(state.scroll, count -| visible);
    }

    try r.rect(area.x, area.y, area.w, area.h, t.editor);
    try drawSearch(r, t, g.field, &state.search, caret_visible);

    for (column_titles, 0..) |title, i| {
        try drawFit(r, title, g.col_x[i] + cell_pad, g.header_y + baseline_row, g.col_w[i] - 2 * cell_pad, t.muted, false);
    }
    try r.rect(g.table_x, g.header_y + header_h, g.table_w, 1, t.border_variant);

    if (count == 0) {
        try r.textUi(empty_text, g.table_x + cell_pad, g.rows_y + baseline_row, t.muted);
        return;
    }

    const hovered = rowAt(area, state, mouse[0], mouse[1]);
    const first = state.scroll;
    const last = @min(count, first + visible);
    r.setClip(clipRect(g.table_x, g.rows_y, g.table_w, g.rows_bottom - g.rows_y));
    for (first..last) |i| {
        const row_y = g.rows_y + @as(f32, @floatFromInt(i - first)) * row_h;
        if (i == state.selected) {
            try r.rect(g.table_x, row_y, g.table_w, row_h, t.element_selected);
            try r.rect(g.table_x, row_y, g.table_w, 1, t.border_focused);
            try r.rect(g.table_x, row_y + row_h - 1, g.table_w, 1, t.border_focused);
            try r.rect(g.table_x, row_y, 1, row_h, t.border_focused);
            try r.rect(g.table_x + g.table_w - 1, row_y, 1, row_h, t.border_focused);
        } else {
            if (i % 2 == 1) try r.rect(g.table_x, row_y, g.table_w, row_h, withAlpha(t.text, 0.05));
            if (hovered) |h| if (h == i) try r.rect(g.table_x, row_y, g.table_w, row_h, withAlpha(t.element_hover, 0.6));
        }
        const index = state.rows.items[i];
        if (index >= km.bindings.items.len) continue;
        try drawRow(r, t, g, row_y, &km.bindings.items[index], avail);
    }
    r.setClip(null);
}

fn drawSearch(r: *Renderer, t: Theme, f: Rect, input: *const LineInput, caret_visible: bool) !void {
    try r.roundBox(f.x, f.y, f.w, f.h, field_radius, t.editor, t.border);
    const inner_x = f.x + 8;
    const inner_w = @max(0, f.w - 16);
    const text = input.text();
    const caret_at = r.widthUi(text[0..input.cursor]);
    // Keep the caret inside the field when the query is wider than it.
    const scroll_x: f32 = if (caret_at > inner_w) caret_at - inner_w + 2 else 0;
    const baseline = f.y + baseline_field;

    r.setClip(clipRect(inner_x, f.y + 1, inner_w, f.h - 2));
    if (text.len == 0) {
        try r.textUi(placeholder_text, inner_x, baseline, t.placeholder);
    } else {
        const sel = input.selection();
        if (sel.start != sel.end) {
            const x0 = inner_x + r.widthUi(text[0..sel.start]) - scroll_x;
            const x1 = inner_x + r.widthUi(text[0..sel.end]) - scroll_x;
            try r.rect(x0, f.y + 7, x1 - x0, chip_h, t.selection);
        }
        try r.textUi(text, inner_x - scroll_x, baseline, t.text);
    }
    if (caret_visible) try r.rect(inner_x + caret_at - scroll_x, f.y + 7, 1, chip_h, t.accent);
    r.setClip(null);
}

fn drawRow(r: *Renderer, t: Theme, g: Geometry, row_y: f32, binding: *const keymap.Binding, avail: Availability) !void {
    const baseline = row_y + baseline_row;
    const missing = if (binding.action) |a| !avail.implemented(avail.ctx, a) else false;
    const text_color = if (missing) t.muted else t.text;

    // Action, with a "not yet in Zid" tag at its right edge when unimplemented.
    const action_x = g.col_x[0] + cell_pad;
    const action_w = g.col_w[0] - 2 * cell_pad;
    if (binding.action) |action| {
        var name_buf: [256]u8 = undefined;
        const name = humanize(action, &name_buf);
        var text_w = action_w;
        if (missing) {
            const tag_w = r.widthSmall(tag_text) + 2 * tag_pad;
            if (tag_w <= action_w) {
                const tag_x = action_x + action_w - tag_w;
                const tag_y = row_y + (row_h - tag_h) / 2;
                try r.roundBox(tag_x, tag_y, tag_w, tag_h, 3, t.element_background, t.border_variant);
                try r.textSmall(tag_text, tag_x + tag_pad, tag_y + 12, t.muted);
                text_w = action_w - tag_w - tag_gap;
            }
        }
        try drawFit(r, name, action_x, baseline, text_w, text_color, false);
    } else {
        try drawFit(r, "<null>", action_x, baseline, action_w, t.muted, false);
    }

    // Arguments: compact JSON of the Zed `["action", arg]` value.
    if (binding.arg) |arg| {
        var arg_buf: [256]u8 = undefined;
        const text = argText(arg, &arg_buf);
        try drawFit(r, text, g.col_x[1] + cell_pad, baseline, g.col_w[1] - 2 * cell_pad, text_color, false);
    }

    try drawChord(r, t, binding.chord, g.col_x[2] + cell_pad, row_y, g.col_x[2] + g.col_w[2] - cell_pad, text_color);

    const context = if (binding.context.len == 0) global_context else binding.context;
    try drawFit(r, context, g.col_x[3] + cell_pad, baseline, g.col_w[3] - 2 * cell_pad, t.muted, false);

    const source = switch (binding.source) {
        .default => "Default",
        .user => "User",
    };
    try drawFit(r, source, g.col_x[4] + cell_pad, baseline, g.col_w[4] - 2 * cell_pad, t.muted, false);
}

/// Keycap chips for each keystroke of `chord`, left to right; stops at `right` with an ellipsis.
fn drawChord(r: *Renderer, t: Theme, chord: keymap.Chord, x0: f32, row_y: f32, right: f32, color: [4]u8) !void {
    const y = row_y + (row_h - chip_h) / 2;
    var x = x0;
    for (chord.slice(), 0..) |key, i| {
        if (i > 0) x += chip_gap;
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        key.format(&w) catch {};
        const label = w.buffered();
        const chip_w = r.widthUi(label) + 2 * chip_pad;
        if (x + chip_w > right) {
            if (x + r.widthUi(ellipsis) <= right) try r.textUi(ellipsis, x, y + 13, color);
            return;
        }
        try r.roundBox(x, y, chip_w, chip_h, 2, t.element_background, t.border_variant);
        try r.textUi(label, x + chip_pad, y + 13, color);
        x += chip_w;
    }
}

/// Serializes an action argument compactly; "…" when it does not fit `buf`.
fn argText(arg: std.json.Value, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    std.json.Stringify.value(arg, .{}, &w) catch return ellipsis;
    return w.buffered();
}

fn measure(r: *Renderer, text: []const u8, small: bool) f32 {
    return if (small) r.widthSmall(text) else r.widthUi(text);
}

fn drawText(r: *Renderer, text: []const u8, x: f32, baseline: f32, color: [4]u8, small: bool) !void {
    if (small) try r.textSmall(text, x, baseline, color) else try r.textUi(text, x, baseline, color);
}

/// Draws `text` inside `max_w`, truncating the end with "…" on a UTF-8 boundary.
fn drawFit(r: *Renderer, text: []const u8, x: f32, baseline: f32, max_w: f32, color: [4]u8, small: bool) !void {
    if (max_w <= 0 or text.len == 0) return;
    if (measure(r, text, small) <= max_w) return drawText(r, text, x, baseline, color, small);
    const ell_w = measure(r, ellipsis, small);
    if (ell_w > max_w) return;
    const budget = max_w - ell_w;

    // Binary search for the longest boundary-aligned prefix that fits the budget.
    var lo: usize = 0;
    var hi: usize = text.len;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        var cut = mid;
        while (cut > lo and cut < text.len and text[cut] & 0xc0 == 0x80) cut -= 1;
        if (cut <= lo) {
            hi = mid - 1;
            continue;
        }
        if (measure(r, text[0..cut], small) <= budget) lo = cut else hi = mid - 1;
    }
    const prefix = text[0..lo];
    try drawText(r, prefix, x, baseline, color, small);
    try drawText(r, ellipsis, x + measure(r, prefix, small), baseline, color, small);
}

fn withAlpha(c: [4]u8, alpha: f32) [4]u8 {
    return .{ c[0], c[1], c[2], @intFromFloat(@round(@as(f32, @floatFromInt(c[3])) * alpha)) };
}

fn clipRect(x: f32, y: f32, w: f32, h: f32) sdl.rect.IRect {
    return .{
        .x = @intFromFloat(@floor(x)),
        .y = @intFromFloat(@floor(y)),
        .w = @intFromFloat(@ceil(@max(0, w))),
        .h = @intFromFloat(@ceil(@max(0, h))),
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "humanize follows the command palette rules" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("editor: move to beginning of line", humanize("editor::MoveToBeginningOfLine", &buf));
    try testing.expectEqualStrings("go to line: toggle", humanize("go_to_line::Toggle", &buf));
    try testing.expectEqualStrings("zed: open keymap", humanize("zed::OpenKeymap", &buf));
    try testing.expectEqualStrings("editor: go to definition", humanize("editor::GoToDefinition", &buf));
    try testing.expectEqualStrings("editor: open URL", humanize("editor::OpenURL", &buf));
    try testing.expectEqualStrings("editor: open URL parser", humanize("editor::OpenURLParser", &buf));
    try testing.expectEqualStrings("agent: open global AGENTS.md rules", humanize("agent::OpenGlobalAGENTS.mdRules", &buf));
    try testing.expectEqualStrings("file finder: toggle", humanize("file_finder::Toggle", &buf));
}

test "humanize truncates to the buffer without overflowing" {
    var buf: [9]u8 = undefined;
    try testing.expectEqualStrings("editor: m", humanize("editor::MoveToBeginningOfLine", &buf));
    var tiny: [3]u8 = undefined;
    try testing.expectEqualStrings("edi", humanize("editor::Move", &tiny));
}

test "moveSelection clamps to the filtered rows" {
    var state: State = .{};
    defer state.deinit(testing.allocator);
    try state.rows.appendSlice(testing.allocator, &.{ 4, 7, 9 });
    moveSelection(&state, 10);
    try testing.expectEqual(@as(usize, 2), state.selected);
    moveSelection(&state, -10);
    try testing.expectEqual(@as(usize, 0), state.selected);
    state.rows.clearRetainingCapacity();
    moveSelection(&state, 1);
    try testing.expectEqual(@as(usize, 0), state.selected);
}
