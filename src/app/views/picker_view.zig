//! Zed-style picker modal rendering (file finder, command palette, recent projects,
//! tab switcher) and the go-to-line modal. Rendering + hit-testing only; controllers live
//! in src/app/input/.
//!
//! Measurements adopted (rem = 16px; Tailwind-style gpui units: N => N*0.25rem = N*4px):
//! - Picker default modal: width `DEFAULT_MODAL_WIDTH = 34rem` (544px), max height
//!   `DEFAULT_MODAL_MAX_HEIGHT = 24rem` (384px) (crates/picker/src/picker.rs:45-46,
//!   shape.rs:210-211). Width is `opts.width`, max rows derived from the 384px cap.
//! - Modal layer: content is `v_flex().h(0).top_20()` => 80px below the window top,
//!   horizontally centred (crates/workspace/src/modal_layer.rs:315-318).
//! - Query editor: `h_9` (36px) with `px_2p5` (10px) side padding, followed by a 1px
//!   `Divider::horizontal()` (crates/picker/src/render.rs:82-98 `render_editor`).
//! - Results list: `py_1` (4px) top/bottom padding on the list container
//!   (crates/picker/src/picker.rs:1548 `DynamicSpacing::Base04`, render.rs uniform_list `.py_1()`).
//! - Row height: no explicit `h_6`/`h_7` exists in crates/ui/src/components/list/list_item.rs;
//!   rows are `ListItemSpacing::Sparse` (`py_1` = 4px each side, command_palette.rs:777,
//!   file_finder.rs:2345) around a ~20px label line. Adopted 28px; this is an estimate.
//! - Visible rows: picker height cap 384px minus editor (36+1) and list padding (8) with
//!   28px rows => 12 rows max, then scroll (`results_max_height`, shape.rs:540).
//! - Row content: start slot (icon, 16px, `Icon::new(..).color(Color::Muted)`) then
//!   `gap_1p5` (6px) then file name (text colour) then directory (`Color::Muted`) with
//!   `gap_1p5` between them (file_finder.rs ~2345-2360). End slot / keybinding is right
//!   aligned with `justify_between` + `gap_2` (command_palette.rs:779-800).
//! - KeyBinding keycaps: `gap(Base04)` = 4px between keys, key chip `py_0p5` + `rounded_xs`
//!   (2px), `px_0p5` (2px) per side (crates/ui/src/components/keybinding.rs:269-290, 549-560).
//! - Selected row: `ghost_element_selected`, hovered row: `ghost_element_hover`
//!   (list_item.rs:323-327). Radius 4px (`rounded_sm`), inset 4px from list edges (task spec).
//! - Modal surface: `elevated_surface_background` fill, `border` outline, radius 8px (task
//!   spec; Zed's elevation_3 radius was not re-verified). Shadow: ModalSurface shadows are
//!   (0,2px,blur 3,a .12) and (0,3px,blur 6,a .08) (elevation.rs:58-70); approximated with
//!   translucent round rects.
//! - Separators: `border_variant` 1px (picker.rs:1491-1492, go_to_line.rs:331).
//! - Go-to-line: `w(rems(24))` = 384px, `elevation_2`, input box `px_2 py_1` (8px / 4px) with
//!   `border_b_1` `border_variant`, help row `px_2 py_1` with muted label. Footer text is
//!   `"Current Line: {line} of {last_line} (column {column})"` (go_to_line.rs:137-141).
//!   Placeholder in Zed is the current `line:column` (go_to_line.rs:127-128).
//! - Scrollbar: 4px wide thumb (task spec) with `scrollbar_thumb`, minimum 24px high.
//!
//! Limits: no keyboard/mouse controllers here, no preview pane, no multi-select checkboxes,
//! no tooltips. Label truncation is a per-row clip, not an ellipsis.
const std = @import("std");
const sdl = @import("sdl3");
const Renderer = @import("../../gfx/renderer.zig").Renderer;
const Theme = @import("../theme.zig").Theme;
const Rect = @import("../layout.zig").Rect;
const LineInput = @import("../line_input.zig").LineInput;

pub const Item = struct {
    label: []const u8,
    detail: []const u8 = "",
    icon: ?[]const u8 = null,
    /// Multi-color icon (icon themes such as Catppuccin): drawn with its own colors.
    icon_colored: bool = false,
    label_positions: []const u16 = &.{},
    detail_positions: []const u16 = &.{},
    hint: []const u8 = "",
};

pub const Options = struct {
    placeholder: []const u8,
    width: f32 = 544,
    empty_text: []const u8 = "No matches",
};

pub const Geometry = struct { modal: Rect, input: Rect, list: Rect, row_h: f32, visible_rows: usize };

const modal_top: f32 = 80;
const modal_radius: f32 = 8;
const editor_h: f32 = 36;
const separator_h: f32 = 1;
const editor_pad_x: f32 = 10;
const list_pad_y: f32 = 4;
const row_h: f32 = 28;
const max_rows: usize = 12;
const row_radius: f32 = 4;
const row_inset_x: f32 = 4;
const text_pad_x: f32 = 10;
const icon_size: f32 = 16;
const icon_gap: f32 = 6;
const detail_gap: f32 = 6;
const hint_gap: f32 = 8;
const keycap_h: f32 = 18;
const keycap_pad_x: f32 = 4;
const keycap_gap: f32 = 4;
const scrollbar_w: f32 = 4;
const scrollbar_min_h: f32 = 24;

pub const go_to_line_width: f32 = 384;
pub const go_to_line_placeholder = "line:column";
const go_to_line_input_h: f32 = 28;
const go_to_line_footer_h: f32 = 28;

/// Computes the modal geometry for a window of size `window` (x=0,y=0,w,h).
pub fn geometry(window: Rect, item_count: usize, opts: Options) Geometry {
    const width = @min(opts.width, @max(0, window.w - 16));
    // Never extend past the window: keep a 16px bottom margin below the list.
    const room = window.h - modal_top - editor_h - separator_h - 2 * list_pad_y - 16;
    const fit: usize = @max(1, @as(usize, @intFromFloat(@max(0, room) / row_h)));
    const visible: usize = if (item_count == 0) 1 else @min(item_count, @min(max_rows, fit));
    const list_h = @as(f32, @floatFromInt(visible)) * row_h + 2 * list_pad_y;
    const x = window.x + (window.w - width) / 2;
    const y = window.y + modal_top;
    return .{
        .modal = .{ .x = x, .y = y, .w = width, .h = editor_h + separator_h + list_h },
        .input = .{ .x = x, .y = y, .w = width, .h = editor_h },
        .list = .{ .x = x, .y = y + editor_h + separator_h, .w = width, .h = list_h },
        .row_h = row_h,
        .visible_rows = visible,
    };
}

/// Index of the item under the mouse using the same geometry, or null.
pub fn itemAt(window: Rect, item_count: usize, scroll: usize, opts: Options, mx: f32, my: f32) ?usize {
    const g = geometry(window, item_count, opts);
    if (!g.list.contains(mx, my)) return null;
    const top = g.list.y + list_pad_y;
    if (my < top) return null;
    const slot: usize = @intFromFloat(@floor((my - top) / row_h));
    if (slot >= g.visible_rows) return null;
    const index = scroll + slot;
    if (index >= item_count) return null;
    return index;
}

/// Draws the modal; adjusts `scroll.*` so `selected` stays visible. mouse = {x,y} for hover.
pub fn draw(r: *Renderer, t: Theme, window: Rect, input: *const LineInput, items: []const Item, selected: usize, scroll: *usize, opts: Options, caret_visible: bool, mouse: [2]f32) !void {
    const count = items.len;
    const g = geometry(window, count, opts);
    const visible = g.visible_rows;
    const max_scroll: usize = if (count > visible) count - visible else 0;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
    if (count > 0) {
        const sel = @min(selected, count - 1);
        if (sel < scroll.*) scroll.* = sel;
        if (sel >= scroll.* + visible) scroll.* = sel + 1 - visible;
    }
    const hovered = itemAt(window, count, scroll.*, opts, mouse[0], mouse[1]);

    try drawShadow(r, g.modal, modal_radius);
    try r.roundBox(g.modal.x, g.modal.y, g.modal.w, g.modal.h, modal_radius, t.elevated_surface, t.border);
    try drawInputField(r, t, input, insetInput(g.input), opts.placeholder, caret_visible);
    try r.rect(g.modal.x + 1, g.input.y + g.input.h, g.modal.w - 2, separator_h, t.border_variant);

    const list = g.list;
    const inner_top = list.y + list_pad_y;
    r.setClip(clipOf(list));
    if (count == 0) {
        try r.textUi(opts.empty_text, list.x + text_pad_x, inner_top + row_h / 2 + 5, t.muted);
    } else {
        const end = @min(count, scroll.* + visible);
        var index = scroll.*;
        while (index < end) : (index += 1) {
            const row_y = inner_top + @as(f32, @floatFromInt(index - scroll.*)) * row_h;
            try drawRow(r, t, items[index], list, row_y, index == selected, hovered == index);
        }
        if (count > visible) {
            const inner_h = @as(f32, @floatFromInt(visible)) * row_h;
            const thumb_h = @max(scrollbar_min_h, inner_h * @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(count)));
            const fraction = @as(f32, @floatFromInt(scroll.*)) / @as(f32, @floatFromInt(max_scroll));
            const thumb_y = inner_top + (inner_h - thumb_h) * fraction;
            try r.roundRect(list.x + list.w - scrollbar_w - 2, thumb_y, scrollbar_w, thumb_h, scrollbar_w / 2, t.scrollbar_thumb);
        }
    }
    r.setClip(null);
}

/// Go-to-line modal: single-line input with placeholder and a muted footer line (e.g. "Current Line: 12 of 300 (column 4)").
pub fn drawGoToLine(r: *Renderer, t: Theme, window: Rect, input: *const LineInput, footer: []const u8, caret_visible: bool) !void {
    const width = @min(go_to_line_width, @max(0, window.w - 16));
    const x = window.x + (window.w - width) / 2;
    const y = window.y + modal_top;
    const box = Rect{ .x = x, .y = y, .w = width, .h = go_to_line_input_h + separator_h + go_to_line_footer_h };

    try drawShadow(r, box, modal_radius);
    try r.roundBox(box.x, box.y, box.w, box.h, modal_radius, t.elevated_surface, t.border);
    try drawInputField(r, t, input, .{ .x = x + 8, .y = y + 4, .w = width - 16, .h = 20 }, go_to_line_placeholder, caret_visible);
    try r.rect(x + 1, y + go_to_line_input_h, width - 2, separator_h, t.border_variant);
    try r.textUi(footer, x + 8, y + go_to_line_input_h + separator_h + go_to_line_footer_h / 2 + 5, t.muted);
}

fn insetInput(input: Rect) Rect {
    return .{ .x = input.x + editor_pad_x, .y = input.y, .w = input.w - 2 * editor_pad_x, .h = input.h };
}

fn clipOf(rect: Rect) sdl.rect.IRect {
    return .{
        .x = @intFromFloat(@floor(rect.x)),
        .y = @intFromFloat(@floor(rect.y)),
        .w = @intFromFloat(@ceil(@max(0, rect.w))),
        .h = @intFromFloat(@ceil(@max(0, rect.h))),
    };
}

fn drawShadow(r: *Renderer, box: Rect, radius: f32) !void {
    try r.roundRect(box.x - 2, box.y + 1, box.w + 4, box.h + 4, radius + 2, .{ 0, 0, 0, 20 });
    try r.roundRect(box.x - 1, box.y + 2, box.w + 2, box.h + 2, radius + 1, .{ 0, 0, 0, 30 });
}

fn drawInputField(r: *Renderer, t: Theme, input: *const LineInput, rect: Rect, placeholder: []const u8, caret_visible: bool) !void {
    const baseline = rect.y + rect.h / 2 + 5;
    const text = input.text();
    const sel = input.selection();
    const caret_x = r.widthUi(text[0..input.cursor]);
    const scroll_x = @max(0, caret_x - (rect.w - 2));
    const origin_x = rect.x - scroll_x;

    r.setClip(clipOf(rect));
    defer r.setClip(null);
    if (text.len == 0) {
        try r.textUi(placeholder, rect.x, baseline, t.placeholder);
    } else {
        if (sel.end > sel.start) {
            const start_x = origin_x + r.widthUi(text[0..sel.start]);
            const end_x = origin_x + r.widthUi(text[0..sel.end]);
            try r.rect(start_x, rect.y + (rect.h - 18) / 2, end_x - start_x, 18, t.selection);
        }
        try r.textUi(text, origin_x, baseline, t.text);
    }
    if (caret_visible) {
        try r.rect(origin_x + caret_x, rect.y + (rect.h - 16) / 2, 1, 16, t.accent);
    }
}

fn highlighted(positions: []const u16, text: []const u8, index: usize) bool {
    // UTF-8 continuation bytes share the highlight state of their lead byte.
    var start = index;
    while (start > 0 and text[start] & 0xc0 == 0x80) start -= 1;
    if (start > std.math.maxInt(u16)) return false;
    return std.mem.indexOfScalar(u16, positions, @intCast(start)) != null;
}

fn drawHighlighted(r: *Renderer, text: []const u8, positions: []const u16, x: f32, baseline: f32, base: [4]u8, hl: [4]u8) !f32 {
    var cursor_x = x;
    var i: usize = 0;
    while (i < text.len) {
        const on = highlighted(positions, text, i);
        var j = i + 1;
        while (j < text.len and highlighted(positions, text, j) == on) j += 1;
        const segment = text[i..j];
        try r.textUi(segment, cursor_x, baseline, if (on) hl else base);
        cursor_x += r.widthUi(segment);
        i = j;
    }
    return cursor_x - x;
}

fn keycapWidth(r: *Renderer, key: []const u8) f32 {
    return r.widthSmall(key) + 2 * keycap_pad_x;
}

fn hintWidth(r: *Renderer, hint: []const u8) f32 {
    var total: f32 = 0;
    var first = true;
    var it = std.mem.tokenizeAny(u8, hint, "- ");
    while (it.next()) |key| {
        if (!first) total += keycap_gap;
        first = false;
        total += keycapWidth(r, key);
    }
    return total;
}

fn drawHint(r: *Renderer, t: Theme, hint: []const u8, right_edge: f32, row_y: f32) !void {
    var x = right_edge - hintWidth(r, hint);
    const chip_y = row_y + (row_h - keycap_h) / 2;
    var first = true;
    var it = std.mem.tokenizeAny(u8, hint, "- ");
    while (it.next()) |key| {
        if (!first) x += keycap_gap;
        first = false;
        const width = keycapWidth(r, key);
        try r.roundBox(x, chip_y, width, keycap_h, 2, t.element_hover, t.border_variant);
        try r.textSmall(key, x + keycap_pad_x, chip_y + keycap_h / 2 + 4, t.muted);
        x += width;
    }
}

fn drawRow(r: *Renderer, t: Theme, item: Item, list: Rect, row_y: f32, selected: bool, hovered: bool) !void {
    const band_x = list.x + row_inset_x;
    const band_w = list.w - 2 * row_inset_x;
    if (selected) {
        try r.roundRect(band_x, row_y, band_w, row_h, row_radius, t.ghost_element_selected);
    } else if (hovered) {
        try r.roundRect(band_x, row_y, band_w, row_h, row_radius, t.ghost_element_hover);
    }

    const baseline = row_y + row_h / 2 + 5;
    const right = list.x + list.w - text_pad_x;
    const hint_w = if (item.hint.len > 0) hintWidth(r, item.hint) else 0;
    const text_right = if (hint_w > 0) right - hint_w - hint_gap else right;
    var x = list.x + text_pad_x;
    if (item.icon) |svg| {
        if (item.icon_colored)
            try r.colorIcon(svg, x, row_y + (row_h - icon_size) / 2, icon_size, 255)
        else
            try r.icon(svg, x, row_y + (row_h - icon_size) / 2, icon_size, t.muted);
        x += icon_size + icon_gap;
    }

    r.setClip(clipOf(.{ .x = x, .y = row_y, .w = text_right - x, .h = row_h }));
    const label_w = try drawHighlighted(r, item.label, item.label_positions, x, baseline, t.text, t.accent);
    if (item.detail.len > 0) {
        _ = try drawHighlighted(r, item.detail, item.detail_positions, x + label_w + detail_gap, baseline, t.muted, t.accent);
    }
    r.setClip(clipOf(list));

    if (hint_w > 0) try drawHint(r, t, item.hint, right, row_y);
}

test "geometry and itemAt agree" {
    const window = Rect{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const opts = Options{ .placeholder = "" };

    const small = geometry(window, 3, opts);
    try std.testing.expectEqual(@as(usize, 3), small.visible_rows);
    var index: usize = 0;
    while (index < 3) : (index += 1) {
        const center_y = small.list.y + list_pad_y + (@as(f32, @floatFromInt(index)) + 0.5) * row_h;
        try std.testing.expectEqual(@as(?usize, index), itemAt(window, 3, 0, opts, small.list.x + 20, center_y));
    }
    const beyond_y = small.list.y + list_pad_y + 3.5 * row_h;
    try std.testing.expectEqual(@as(?usize, null), itemAt(window, 3, 0, opts, small.list.x + 20, beyond_y));

    const large = geometry(window, 40, opts);
    try std.testing.expectEqual(max_rows, large.visible_rows);
    const scrolled_y = large.list.y + list_pad_y + 0.5 * row_h;
    try std.testing.expectEqual(@as(?usize, 5), itemAt(window, 40, 5, opts, large.list.x + 20, scrolled_y));

    const empty = geometry(window, 0, opts);
    const empty_y = empty.list.y + list_pad_y + 0.5 * row_h;
    try std.testing.expectEqual(@as(?usize, null), itemAt(window, 0, 0, opts, empty.list.x + 20, empty_y));
}
