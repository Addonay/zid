//! Zed picker modal rendering (file finder, command palette, recent projects, tab
//! switcher) and the go-to-line modal. Rendering and hit-testing only; controllers live
//! in src/app/input/. Measurements are from `crates/picker`, `crates/command_palette`,
//! `crates/file_finder` and screenshots of Zed at 1x:
//!
//! - Modal 80px below the window top (`top_20`), `elevation_3`-style surface (8px
//!   radius, `border`), centred. Widths: picker default 34rem (544px), command palette
//!   38rem (608px); the file finder doubles its width when the preview is shown.
//! - Query row 37px with 11px text inset, then a 1px `border_variant` divider.
//! - Rows: 33px in the command palette, 31px elsewhere, with a 1px-inset 4px-radius
//!   highlight `ghost_element_selected` on the selected row only. Moving the mouse over
//!   a row selects it (one highlight, as Zed); the wheel scrolls the list without
//!   moving the selection; keyboard moves keep the selection visible.
//! - Keybindings are plain muted text ("Ctrl-Shift-P"), not keycaps.
//! - Footers (`render_footer`, `p_1p5`, `border_t_1`): command palette "Change
//!   Keybinding…"/"Add Keybinding…" + "Run"; file finder "Preview" toggle, layout
//!   icons and "Actions…". Button labels 14px, their keybindings 12px muted.
//! - File-finder preview: the selected file, syntax highlighted with line numbers, in
//!   the right half, full height.
//! - The scrollbar appears only while the pointer is over the list (Zed `auto`).
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
    /// File finder: a recently opened file (Zed shows a history icon at the end).
    history: bool = false,
};

pub const Footer = enum { none, command_palette, file_finder };

pub const Options = struct {
    placeholder: []const u8,
    width: f32 = 544,
    row_h: f32 = 31,
    empty_text: []const u8 = "No matches",
    footer: Footer = .none,
    /// Command palette: the selected command already has a binding ("Change" vs "Add").
    has_binding: bool = false,
    /// File finder: the preview pane is shown.
    preview: bool = false,
    /// Footer keybinding texts, resolved by the caller from the keymap.
    keys: FooterKeys = .{},
};
pub const FooterKeys = struct {
    secondary_confirm: []const u8 = "",
    confirm: []const u8 = "",
    toggle_preview: []const u8 = "",
    actions: []const u8 = "",
};

pub const Geometry = struct {
    modal: Rect,
    input: Rect,
    list: Rect,
    footer: Rect,
    preview: Rect,
    row_h: f32,
    visible_rows: usize,
};

const modal_top: f32 = 80;
const modal_radius: f32 = 8;
const editor_h: f32 = 37;
const separator_h: f32 = 1;
const text_pad_x: f32 = 11;
const list_pad_y: f32 = 5;
const default_list_max_h: f32 = 384;
const footer_h: f32 = 35;
const row_radius: f32 = 4;
const row_inset_x: f32 = 5;
const icon_size: f32 = 16;
const icon_gap: f32 = 6;
const detail_gap: f32 = 6;
const hint_gap: f32 = 12;
const scrollbar_w: f32 = 4;
const scrollbar_min_h: f32 = 24;

pub const go_to_line_width: f32 = 384;
pub const go_to_line_placeholder = "line:column";
const go_to_line_input_h: f32 = 28;
const go_to_line_footer_h: f32 = 28;

/// Computes the modal geometry for a window of size `window` (x=0,y=0,w,h).
pub fn geometry(window: Rect, item_count: usize, opts: Options) Geometry {
    const preview = opts.preview and window.w >= opts.width * 2 + 32;
    const list_w = @min(opts.width, @max(0, window.w - 16));
    const total_w = if (preview) list_w * 2 else list_w;
    const footer: f32 = if (opts.footer != .none) footer_h else 0;
    // A preview picker is taller; plain pickers cap their list at 24rem.
    const max_list = if (preview) @max(default_list_max_h, @min(590, window.h - modal_top - editor_h - footer - 60)) else default_list_max_h;
    const room = @min(max_list, window.h - modal_top - editor_h - separator_h - footer - 16);
    const fit: usize = @max(1, @as(usize, @intFromFloat(@max(0, room - 2 * list_pad_y) / opts.row_h)));
    const visible: usize = if (item_count == 0) 1 else @min(item_count, fit);
    // Zed keeps the full 24rem list height once results overflow it.
    const list_h = if (item_count > fit) room else @as(f32, @floatFromInt(visible)) * opts.row_h + 2 * list_pad_y;
    const body_h = if (preview) room else list_h;
    const x = window.x + (window.w - total_w) / 2;
    const y = window.y + modal_top;
    const modal_h = editor_h + separator_h + body_h + footer;
    return .{
        .modal = .{ .x = x, .y = y, .w = total_w, .h = modal_h },
        .input = .{ .x = x, .y = y, .w = list_w, .h = editor_h },
        .list = .{ .x = x, .y = y + editor_h + separator_h, .w = list_w, .h = body_h },
        .footer = .{ .x = x, .y = y + modal_h - footer, .w = list_w, .h = footer },
        .preview = if (preview) .{ .x = x + list_w, .y = y, .w = list_w, .h = modal_h } else .{},
        .row_h = opts.row_h,
        .visible_rows = visible + @as(usize, if (item_count > fit) 1 else 0),
    };
}

/// Index of the item under the mouse using the same geometry, or null.
pub fn itemAt(window: Rect, item_count: usize, scroll: usize, opts: Options, mx: f32, my: f32) ?usize {
    const g = geometry(window, item_count, opts);
    if (!g.list.contains(mx, my)) return null;
    const top = g.list.y + list_pad_y;
    if (my < top) return null;
    const slot: usize = @intFromFloat(@floor((my - top) / g.row_h));
    const index = scroll + slot;
    if (index >= item_count) return null;
    return index;
}

pub const FooterButton = enum { change_keybinding, run, toggle_preview, actions };
pub const FooterHit = struct { button: FooterButton, rect: Rect };

/// Footer buttons right to left (Zed `justify_end`, `gap_1`), plus the file finder's
/// left-aligned Preview toggle.
pub fn footerButtons(r: *Renderer, g: Geometry, opts: Options, out: *[4]FooterHit) []FooterHit {
    var n: usize = 0;
    if (opts.footer == .none) return out[0..0];
    const y = g.footer.y + 6;
    const h: f32 = 23;
    var right = g.footer.x + g.footer.w - 6;
    const add = struct {
        fn f(rr: *Renderer, label: []const u8, key: []const u8) f32 {
            return rr.widthUi(label) + (if (key.len > 0) 6 + rr.widthSmall(key) else 0) + 12;
        }
    }.f;
    switch (opts.footer) {
        .command_palette => {
            const run_w = add(r, "Run", opts.keys.confirm);
            right -= run_w;
            out[n] = .{ .button = .run, .rect = .{ .x = right, .y = y, .w = run_w, .h = h } };
            n += 1;
            right -= 4;
            const label = if (opts.has_binding) "Change Keybinding…" else "Add Keybinding…";
            const w = add(r, label, opts.keys.secondary_confirm);
            right -= w;
            out[n] = .{ .button = .change_keybinding, .rect = .{ .x = right, .y = y, .w = w, .h = h } };
            n += 1;
        },
        .file_finder => {
            const w = add(r, "Actions…", opts.keys.actions);
            right -= w;
            out[n] = .{ .button = .actions, .rect = .{ .x = right, .y = y, .w = w, .h = h } };
            n += 1;
            const pw = add(r, "Preview", opts.keys.toggle_preview);
            out[n] = .{ .button = .toggle_preview, .rect = .{ .x = g.footer.x + 6, .y = y, .w = pw, .h = h } };
            n += 1;
        },
        .none => {},
    }
    return out[0..n];
}
fn footerLabel(b: FooterButton, opts: Options) struct { []const u8, []const u8 } {
    return switch (b) {
        .run => .{ "Run", opts.keys.confirm },
        .change_keybinding => .{ if (opts.has_binding) "Change Keybinding…" else "Add Keybinding…", opts.keys.secondary_confirm },
        .toggle_preview => .{ "Preview", opts.keys.toggle_preview },
        .actions => .{ "Actions…", opts.keys.actions },
    };
}

/// Draws the modal; keeps `selected` visible when `follow.*` is set (keyboard moves).
pub fn draw(r: *Renderer, t: Theme, window: Rect, input: *const LineInput, items: []const Item, selected: usize, scroll: *usize, follow: *bool, opts: Options, caret_visible: bool, mouse: [2]f32) !Geometry {
    const count = items.len;
    const g = geometry(window, count, opts);
    const full_rows: usize = @intFromFloat(@max(1, (g.list.h - 2 * list_pad_y) / g.row_h));
    const max_scroll: usize = if (count > full_rows) count - full_rows else 0;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
    if (follow.* and count > 0) {
        const sel = @min(selected, count - 1);
        if (sel < scroll.*) scroll.* = sel;
        if (sel >= scroll.* + full_rows) scroll.* = sel + 1 - full_rows;
        follow.* = false;
    }

    try drawShadow(r, g.modal, modal_radius);
    try r.roundBox(g.modal.x, g.modal.y, g.modal.w, g.modal.h, modal_radius, t.elevated_surface, t.border);
    try drawInputField(r, t, input, .{ .x = g.input.x + text_pad_x, .y = g.input.y + 8, .w = g.input.w - 2 * text_pad_x, .h = 20 }, opts.placeholder, caret_visible);
    try r.rect(g.modal.x + 1, g.input.y + g.input.h, g.list.w - 1, separator_h, t.border_variant);

    const list = g.list;
    const inner_top = list.y + list_pad_y;
    r.setClip(clipOf(list));
    if (count == 0) {
        try r.textUi(opts.empty_text, list.x + text_pad_x, inner_top + g.row_h / 2 + 5, t.muted);
    } else {
        var index = scroll.*;
        const end = @min(count, scroll.* + g.visible_rows + 1);
        while (index < end) : (index += 1) {
            const row_y = inner_top + @as(f32, @floatFromInt(index - scroll.*)) * g.row_h;
            if (row_y > list.y + list.h) break;
            try drawRow(r, t, items[index], list, row_y, g.row_h, index == selected);
        }
        // Zed's `auto` scrollbar: only while the pointer is over the list.
        if (count > full_rows and list.contains(mouse[0], mouse[1])) {
            const inner_h = list.h - 2 * list_pad_y;
            const thumb_h = @max(scrollbar_min_h, inner_h * @as(f32, @floatFromInt(full_rows)) / @as(f32, @floatFromInt(count)));
            const fraction = @as(f32, @floatFromInt(scroll.*)) / @as(f32, @floatFromInt(@max(1, max_scroll)));
            try r.roundRect(list.x + list.w - scrollbar_w - 3, inner_top + (inner_h - thumb_h) * fraction, scrollbar_w, thumb_h, scrollbar_w / 2, t.scrollbar_thumb);
        }
    }
    r.setClip(null);

    if (opts.footer != .none) {
        try r.rect(g.footer.x + 1, g.footer.y, g.footer.w - 1, 1, t.border_variant);
        var buf: [4]FooterHit = undefined;
        for (footerButtons(r, g, opts, &buf)) |hit| {
            const b = hit.rect;
            const active = hit.button == .toggle_preview and opts.preview;
            if (b.contains(mouse[0], mouse[1])) try r.roundRect(b.x, b.y, b.w, b.h, 4, t.ghost_element_hover);
            const text = footerLabel(hit.button, opts);
            try r.textUi(text[0], b.x + 6, b.y + 16, if (active) t.accent else t.text);
            if (text[1].len > 0) try r.textSmall(text[1], b.x + 6 + r.widthUi(text[0]) + 6, b.y + 16, t.muted);
        }
    }
    if (g.preview.w > 0) try r.rect(g.preview.x, g.preview.y + 1, 1, g.preview.h - 2, t.border_variant);
    return g;
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

fn clipOf(rect: Rect) sdl.rect.IRect {
    return .{ .x = @intFromFloat(@floor(rect.x)), .y = @intFromFloat(@floor(rect.y)), .w = @intFromFloat(@max(0, @ceil(rect.w))), .h = @intFromFloat(@max(0, @ceil(rect.h))) };
}

fn drawShadow(r: *Renderer, box: Rect, radius: f32) !void {
    try r.roundRect(box.x - 1, box.y + 2, box.w + 2, box.h + 2, radius + 1, .{ 0, 0, 0, 31 });
    try r.roundRect(box.x - 3, box.y + 3, box.w + 6, box.h + 6, radius + 3, .{ 0, 0, 0, 20 });
}

fn drawInputField(r: *Renderer, t: Theme, input: *const LineInput, rect: Rect, placeholder: []const u8, caret_visible: bool) !void {
    const text = input.text();
    const baseline = rect.y + rect.h / 2 + 5;
    r.setClip(clipOf(.{ .x = rect.x - 2, .y = rect.y - 4, .w = rect.w + 4, .h = rect.h + 8 }));
    defer r.setClip(null);
    const sel = input.selection();
    if (sel.start != sel.end) try r.rect(rect.x + r.widthUi(text[0..sel.start]), rect.y, r.widthUi(text[sel.start..sel.end]), rect.h, t.element_selected);
    if (text.len == 0) try r.textUi(placeholder, rect.x, baseline, t.placeholder) else try r.textUi(text, rect.x, baseline, t.text);
    if (caret_visible) try r.rect(rect.x + r.widthUi(text[0..input.cursor]), rect.y, 2, rect.h, t.accent);
}

fn highlighted(positions: []const u16, text: []const u8, index: usize) bool {
    _ = text;
    return std.mem.indexOfScalar(u16, positions, @intCast(index)) != null;
}

fn drawHighlighted(r: *Renderer, text: []const u8, positions: []const u16, x: f32, baseline: f32, base: [4]u8, hl: [4]u8, small: bool) !f32 {
    var cursor_x = x;
    var i: usize = 0;
    while (i < text.len) {
        const on = highlighted(positions, text, i);
        var j = i + 1;
        while (j < text.len and highlighted(positions, text, j) == on) : (j += 1) {}
        const segment = text[i..j];
        if (small) try r.textSmall(segment, cursor_x, baseline, if (on) hl else base) else try r.textUi(segment, cursor_x, baseline, if (on) hl else base);
        cursor_x += if (small) r.widthSmall(segment) else r.widthUi(segment);
        i = j;
    }
    return cursor_x - x;
}

fn drawRow(r: *Renderer, t: Theme, item: Item, list: Rect, row_y: f32, row_h: f32, selected: bool) !void {
    const band_x = list.x + row_inset_x;
    const band_w = list.w - 2 * row_inset_x;
    if (selected) try r.roundRect(band_x, row_y + 0.5, band_w, row_h - 1, row_radius, t.ghost_element_selected);

    const baseline = row_y + row_h / 2 + 5;
    const right = list.x + list.w - text_pad_x;
    const hint_w = if (item.hint.len > 0) r.widthUi(item.hint) else 0;
    const end_icon: f32 = if (item.history) 14 + 8 else 0;
    const text_right = right - end_icon - (if (hint_w > 0) hint_w + hint_gap else 0);
    var x = list.x + text_pad_x;
    if (item.icon) |svg| {
        if (item.icon_colored)
            try r.colorIcon(svg, x, row_y + (row_h - 14) / 2, 14, 255)
        else
            try r.icon(svg, x, row_y + (row_h - 14) / 2, 14, t.muted);
        x += 14 + icon_gap;
    }

    r.setClip(clipOf(.{ .x = x, .y = row_y, .w = @max(0, text_right - x), .h = row_h }));
    const label_w = try drawHighlighted(r, item.label, item.label_positions, x, baseline, t.text, t.accent, false);
    // File-finder directories are smaller and muted, after the name.
    if (item.detail.len > 0) _ = try drawHighlighted(r, item.detail, item.detail_positions, x + label_w + detail_gap, baseline, t.muted, t.accent, item.icon != null);
    r.setClip(clipOf(list));

    if (hint_w > 0) try r.textUi(item.hint, right - end_icon - hint_w, baseline, t.muted);
    if (item.history) try r.icon(@import("icons").svg("ui:history_rerun"), right - 14, row_y + (row_h - 14) / 2, 14, t.muted);
}

test "geometry and itemAt agree" {
    const window = Rect{ .x = 0, .y = 0, .w = 1000, .h = 800 };
    const opts = Options{ .placeholder = "" };
    const small = geometry(window, 3, opts);
    try std.testing.expectEqual(@as(usize, 3), small.visible_rows);
    var index: usize = 0;
    while (index < 3) : (index += 1) {
        const center_y = small.list.y + list_pad_y + (@as(f32, @floatFromInt(index)) + 0.5) * opts.row_h;
        try std.testing.expectEqual(@as(?usize, index), itemAt(window, 3, 0, opts, small.list.x + 20, center_y));
    }
    const large = geometry(window, 40, opts);
    const scrolled_y = large.list.y + list_pad_y + 0.5 * opts.row_h;
    try std.testing.expectEqual(@as(?usize, 5), itemAt(window, 40, 5, opts, large.list.x + 20, scrolled_y));
    try std.testing.expectEqual(@as(?usize, null), itemAt(window, 0, 0, opts, large.list.x + 20, scrolled_y));
}
