//! Zed `ui::Tooltip` (`crates/ui/src/components/tooltip.rs`, GPUI `div.tooltip`).
//!
//! Views call `register` while drawing with the hovered element's bounds; when the
//! pointer stays on the same element for GPUI's 500ms `DEFAULT_TOOLTIP_SHOW_DELAY`, the
//! tooltip appears below-right of the pointer (`pl_2 pt_2p5`) in an `elevation_2`
//! container with `py_1 px_2`: the title (14px) and, `gap_4` to its right, the action's
//! keybinding (muted); an optional small muted meta line below. Pressing a button or
//! opening a menu hides it.
const std = @import("std");
const sdl = @import("sdl3");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;

pub const delay_ms = 500;
pub const Tip = struct {
    rect: Rect,
    title: []const u8,
    /// Zed action whose keybinding is shown (`Tooltip::for_action`).
    action: []const u8 = "",
    meta: []const u8 = "",
};
pub const State = struct {
    /// Set by `register` during the current frame (cleared by `beginFrame`).
    candidate: ?Tip = null,
    key: u64 = 0,
    since: u64 = 0,
    shown: bool = false,
    /// A tooltip is waiting for its delay; the run loop wakes for it.
    pending: bool = false,
};

pub fn beginFrame(app: *App) void {
    app.tooltip.candidate = null;
}

/// Called from draw code for each element with a tooltip.
pub fn register(app: *App, tip: Tip) void {
    if (app.pointer_down or app.context_menu != null or app.prompt != null) return;
    if (!tip.rect.contains(app.mouse_x, app.mouse_y)) return;
    app.tooltip.candidate = tip;
}

fn keyOf(tip: Tip) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(tip.title);
    h.update(std.mem.asBytes(&tip.rect.x));
    h.update(std.mem.asBytes(&tip.rect.y));
    return h.final();
}

/// Milliseconds until the pending tooltip should appear, for the run loop's wait.
pub fn pendingMs(app: *const App) ?u64 {
    if (!app.tooltip.pending) return null;
    return delay_ms -| (sdl.timer.getMillisecondsSinceInit() -| app.tooltip.since);
}

/// Draw the tooltip (last, above everything) once its delay has passed.
pub fn finishFrame(app: *App) !void {
    const s = &app.tooltip;
    const tip = s.candidate orelse {
        s.key = 0;
        s.shown = false;
        s.pending = false;
        return;
    };
    const now = sdl.timer.getMillisecondsSinceInit();
    const key = keyOf(tip);
    if (key != s.key) {
        s.key = key;
        s.since = now;
        s.shown = false;
    }
    if (now - s.since < delay_ms) {
        s.pending = true;
        return;
    }
    s.pending = false;
    s.shown = true;
    try draw(app, tip);
}

fn draw(app: *App, tip: Tip) !void {
    const t = app.settings.theme;
    const r = &app.renderer;
    var key_buf: [48]u8 = undefined;
    var key: []const u8 = "";
    if (tip.action.len > 0) {
        var path_buf: [6]@import("../keymap.zig").Context = undefined;
        var ext_buf: [16]u8 = undefined;
        const path = @import("../input/commands.zig").focusPath(app, &path_buf, &ext_buf);
        if (app.keymap.chordFor(tip.action, path)) |chord| {
            var w: std.Io.Writer = .fixed(&key_buf);
            chord.format(&w) catch {};
            key = w.buffered();
        }
    }
    const title_w = r.widthUi(tip.title);
    const key_w = if (key.len > 0) 16 + r.widthUi(key) else 0;
    const meta_w = if (tip.meta.len > 0) r.widthSmall(tip.meta) else 0;
    const w = @max(title_w + key_w, meta_w) + 16 + 2;
    const h: f32 = 4 * 2 + 22 + (if (tip.meta.len > 0) @as(f32, 18) else 0) + 2;
    var x = app.mouse_x + 8;
    var y = app.mouse_y + 10;
    if (x + w > app.layout.width) x = app.layout.width - w;
    if (y + h > app.layout.height) y = app.mouse_y - h - 4;
    x = @max(0, x);
    y = @max(0, y);
    try r.roundRect(x - 1, y + 1, w + 2, h + 2, 9, .{ 0, 0, 0, 20 });
    try r.roundBox(x, y, w, h, 8, t.elevated_surface, t.border_variant);
    try r.textUi(tip.title, x + 9, y + 5 + 15, t.text);
    if (key.len > 0) try r.textUi(key, x + w - 9 - r.widthUi(key), y + 5 + 15, t.muted);
    if (tip.meta.len > 0) try r.textSmall(tip.meta, x + 9, y + 5 + 22 + 13, t.muted);
}
