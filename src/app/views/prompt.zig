//! Zed's in-window prompt (`crates/ui_prompt`, used on Linux by `window.prompt`).
//!
//! A 20% black wash covers the window; a 320px (`w_80`) `elevation_3` box is centred
//! with `p_4`/`gap_4`: the message (14px, default colour), an optional detail (12px,
//! muted) and full-width `Outlined` buttons stacked with `gap_1`. The active button is
//! `Tinted(Accent)` (`info.background` fill, `info.border`). Key context `Prompt`:
//! tab/down/right/l select the next button, shift-tab/up/left/h the previous one,
//! enter confirms, escape picks the cancel answer. Clicking a button answers.
//!
//! Messages and answers follow Zed's: "`name` contains unsaved edits. Do you want to
//! save it?" (Save / Don't Save / Cancel), "Do you want to save changes to the
//! following files?" (Save all / Discard all / Cancel), and the project panel's
//! trash/delete confirmations.
const std = @import("std");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const helpers = @import("../settings_helpers.zig");

pub const Kind = union(enum) {
    /// Close one document (index into workspace.documents).
    close_item: usize,
    /// Close every listed dirty document after saving or discarding them.
    close_dirty,
    /// Quit after saving or discarding the dirty documents.
    quit,
    /// Remove the project-panel entry at `path` (absolute).
    trash,
    delete,
};

pub const Prompt = struct {
    kind: Kind,
    message: [768]u8 = undefined,
    message_len: usize = 0,
    detail: [512]u8 = undefined,
    detail_len: usize = 0,
    buttons: [3][]const u8 = undefined,
    count: usize = 0,
    /// Answer index used by escape (Zed treats the last "Cancel" as the cancel answer).
    cancel: usize = 0,
    active: usize = 0,
    path: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    rect: Rect = .{},
    button_rects: [3]Rect = undefined,

    fn messageText(self: *const Prompt) []const u8 {
        return self.message[0..self.message_len];
    }
    fn detailText(self: *const Prompt) []const u8 {
        return self.detail[0..self.detail_len];
    }
    pub fn pathText(self: *const Prompt) []const u8 {
        return self.path[0..self.path_len];
    }
};

fn setText(buf: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
    len.* = (std.fmt.bufPrint(buf, fmt, args) catch buf[0..buf.len]).len;
}
fn show(app: *App, prompt: Prompt) void {
    app.prompt = prompt;
    app.context_menu = null;
}

/// Pane `close_item` prompt for one dirty item.
pub fn closeItem(app: *App, index: usize) void {
    var p: Prompt = .{ .kind = .{ .close_item = index } };
    const doc = &app.workspace.documents.items[index];
    if (doc.path) |path| {
        setText(&p.message, &p.message_len, "{s} contains unsaved edits. Do you want to save it?", .{std.fs.path.basename(path)});
    } else setText(&p.message, &p.message_len, "This buffer contains unsaved edits. Do you want to save it?", .{});
    p.buttons = .{ "Save", "Don't Save", "Cancel" };
    p.count = 3;
    p.cancel = 2;
    show(app, p);
}
/// Workspace prompt for several dirty items (closing a pane or quitting).
pub fn saveDirty(app: *App, quit: bool) void {
    var p: Prompt = .{ .kind = if (quit) .quit else .close_dirty };
    setText(&p.message, &p.message_len, "{s}", .{if (quit) "Do you want to save all changes in the following files?" else "Do you want to save changes to the following files?"});
    // Pane::file_names_for_prompt: one name per line, at most ten listed.
    var writer: std.Io.Writer = .fixed(&p.detail);
    var listed: usize = 0;
    var dirty: usize = 0;
    for (app.workspace.documents.items) |*doc| if (doc.dirty()) {
        dirty += 1;
        if (listed == 10) continue;
        const name = if (doc.path) |path| std.fs.path.basename(path) else "untitled";
        writer.print("{s}{s}", .{ if (listed > 0) "\n" else "", name }) catch {};
        listed += 1;
    };
    if (dirty > listed) writer.print("\n...and {d} more", .{dirty - listed}) catch {};
    p.detail_len = writer.buffered().len;
    p.buttons = .{ "Save all", "Discard all", "Cancel" };
    p.count = 3;
    p.cancel = 2;
    show(app, p);
}
/// Project panel `build_removal_prompt` for one entry.
pub fn remove(app: *App, absolute: []const u8, trash: bool) void {
    var p: Prompt = .{ .kind = if (trash) .trash else .delete };
    const name = std.fs.path.basename(absolute);
    var dirty = false;
    for (app.workspace.documents.items) |*doc| if (doc.dirty()) if (doc.path) |path| {
        if (std.mem.startsWith(u8, path, absolute)) dirty = true;
    };
    setText(&p.message, &p.message_len, "{s} {s}?{s}", .{
        if (trash) "Do you want to trash" else "Are you sure you want to permanently delete",
        name,
        if (dirty) "\n\nIt has unsaved changes, which will be lost." else "",
    });
    if (!trash) setText(&p.detail, &p.detail_len, "This cannot be undone.", .{});
    p.buttons = .{ if (trash) "Trash" else "Delete", "Cancel", "" };
    p.count = 2;
    p.cancel = 1;
    const n = @min(absolute.len, p.path.len);
    @memcpy(p.path[0..n], absolute[0..n]);
    p.path_len = n;
    show(app, p);
}

pub fn isOpen(app: *const App) bool {
    return app.prompt != null;
}

/// `menu::*` actions in the `Prompt` context.
pub fn command(app: *App, name: []const u8) !void {
    const p = &(app.prompt orelse return);
    const eql = std.mem.eql;
    if (eql(u8, name, "menu::SelectNext")) p.active = (p.active + 1) % p.count else if (eql(u8, name, "menu::SelectPrevious")) p.active = (p.active + p.count - 1) % p.count else if (eql(u8, name, "menu::SelectFirst")) p.active = 0 else if (eql(u8, name, "menu::SelectLast")) p.active = p.count - 1 else if (eql(u8, name, "menu::Confirm") or eql(u8, name, "menu::SecondaryConfirm")) try answer(app, p.active) else if (eql(u8, name, "menu::Cancel")) try answer(app, p.cancel);
}

pub fn click(app: *App, mx: f32, my: f32) !void {
    const p = app.prompt orelse return;
    for (p.button_rects[0..p.count], 0..) |r, i| if (r.contains(mx, my)) return answer(app, i);
}

fn answer(app: *App, index: usize) !void {
    const p = app.prompt orelse return;
    app.prompt = null;
    if (index == p.cancel) return;
    try @import("../workspace_actions.zig").promptAnswered(app, p, index);
}

/// The message renders as Markdown at `ui_font_size` (16px by default).
fn measureUi(app: *App, text: []const u8) f32 {
    return app.renderer.widthHeadline(text);
}
fn measureSmall(app: *App, text: []const u8) f32 {
    return app.renderer.widthSmall(text);
}
/// Wraps `text` at word boundaries and explicit newlines; returns the height used.
fn paragraph(app: *App, text: []const u8, x: f32, y: f32, w: f32, small: bool, color: [4]u8, draw_text: bool) !f32 {
    const line_h: f32 = if (small) 19 else 22;
    var height: f32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var rest = line;
        if (rest.len == 0) height += line_h;
        while (rest.len > 0) {
            const end = if (small) helpers.lineEnd(rest, w, app, measureSmall) else helpers.lineEnd(rest, w, app, measureUi);
            if (draw_text) {
                if (small) try app.renderer.textSmall(rest[0..end], x, y + height + 14, color) else try app.renderer.textHeadline(rest[0..end], x, y + height + 16, color);
            }
            height += line_h;
            rest = std.mem.trimStart(u8, rest[end..], " ");
        }
    }
    return height;
}

pub fn draw(app: *App) !void {
    const p = &(app.prompt orelse return);
    const t = app.settings.theme;
    const r = &app.renderer;
    try r.rect(0, 0, app.layout.width, app.layout.height, .{ 0, 0, 0, 51 });
    const w: f32 = 320;
    const pad: f32 = 16;
    const inner = w - pad * 2;
    const message_h = try paragraph(app, p.messageText(), 0, 0, inner, false, t.text, false);
    const detail_h = if (p.detail_len > 0) try paragraph(app, p.detailText(), 0, 0, inner, true, t.muted, false) else 0;
    const button_h: f32 = 22;
    const buttons_h = @as(f32, @floatFromInt(p.count)) * button_h + @as(f32, @floatFromInt(p.count - 1)) * 4;
    const h = pad * 2 + message_h + (if (p.detail_len > 0) 16 + detail_h else 0) + 16 + buttons_h;
    const box: Rect = .{ .x = @round((app.layout.width - w) / 2), .y = @round((app.layout.height - h) / 2), .w = w, .h = h };
    p.rect = box;
    // ModalSurface shadows.
    try r.roundRect(box.x - 2, box.y + 1, box.w + 4, box.h + 4, 10, .{ 0, 0, 0, 24 });
    try r.roundRect(box.x - 4, box.y + 3, box.w + 8, box.h + 8, 12, .{ 0, 0, 0, 12 });
    try r.roundBox(box.x, box.y, box.w, box.h, 8, t.elevated_surface, t.border_variant);
    var y = box.y + pad;
    y += try paragraph(app, p.messageText(), box.x + pad, y, inner, false, t.text, true);
    if (p.detail_len > 0) {
        y += 16;
        y += try paragraph(app, p.detailText(), box.x + pad, y, inner, true, t.muted, true);
    }
    y += 16;
    for (p.buttons[0..p.count], 0..) |label, i| {
        const b: Rect = .{ .x = box.x + pad, .y = y, .w = inner, .h = button_h };
        p.button_rects[i] = b;
        const active = i == p.active;
        const hovered = b.contains(app.mouse_x, app.mouse_y);
        try r.roundBox(b.x, b.y, b.w, b.h, 4, if (hovered and !active) t.ghost_element_hover else t.elevated_surface, if (active) t.info_border else t.border);
        // The accent tint is translucent, so it goes over the opaque surface.
        if (active) try r.roundRect(b.x + 1, b.y + 1, b.w - 2, b.h - 2, 3, t.info_background);
        try r.textUi(label, b.x + (b.w - r.widthUi(label)) / 2, b.y + 16, t.text);
        y += button_h + 4;
    }
}
