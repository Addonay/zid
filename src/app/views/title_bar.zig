//! Native caption controls use the same icon-theme resolver and spacing as
//! chatƺpt; the rest of the chrome follows the Zed shell.
const std = @import("std");
const App = @import("../app.zig").App;
const Kind = @import("../../platform/window_controls.zig").Kind;
const icons = @import("icons");
const Rect = @import("../layout.zig").Rect;
const menus = @import("../menus.zig");

/// Index of the open application menu; the title bar then shows the menu bar
/// (Zed `ApplicationMenu` with all menus shown).
pub fn appMenuOpen(self: *const App) ?usize {
    const m = self.context_menu orelse return null;
    return switch (m.target) {
        .app_menu => |i| i,
        else => null,
    };
}
/// Menu-name buttons: `LabelSize::Small` labels with 6px padding, 2px apart.
pub fn menuNameRects(self: *App, out: []Rect) void {
    var x: f32 = 6;
    for (menus.app_menu_names, 0..) |name, i| {
        const w = self.renderer.widthSmall(name) + 12;
        out[i] = .{ .x = x, .y = 6, .w = w, .h = 22 };
        x += w + 2;
    }
}
pub fn menuNameAt(self: *App, mx: f32, my: f32) ?usize {
    var rects: [menus.app_menu_names.len]Rect = undefined;
    menuNameRects(self, &rects);
    for (rects, 0..) |r, i| if (r.contains(mx, my)) return i;
    return null;
}
/// Opens application menu `index` under its name (the hamburger opens the first).
pub fn openAppMenu(self: *App, index: usize) void {
    var rects: [menus.app_menu_names.len]Rect = undefined;
    menuNameRects(self, &rects);
    @import("context_menu.zig").open(self, menus.appMenu(self, index, rects[index].x, 33));
}
/// Signed-in user picture (Zed `Avatar`, 16px): the downloaded GitHub avatar, or the
/// login's initial in a circle until it arrives.
fn drawAvatar(self: *App, login: []const u8, x: f32, y: f32) !void {
    if (self.account.avatar_texture) |id| return self.renderer.drawImage(id, x, y, 16, 16, 255);
    const t = self.settings.theme;
    try self.renderer.roundRect(x, y, 16, 16, 8, t.element_selected);
    var initial: [1]u8 = .{if (login.len > 0) std.ascii.toUpper(login[0]) else '?'};
    try self.renderer.textXSmall(&initial, x + (16 - self.renderer.widthXSmall(&initial)) / 2, y + 12, t.text);
}

pub fn controlsInset(self: *App) f32 {
    return if (self.controls.breeze) 3 * 22 + 2 * 10 + 8 else 3 * 34 + 2 * 8 + 6;
}
pub fn controlAt(self: *App, x: f32, y: f32) ?usize {
    if (y < 0 or y >= 34) return null;
    const start = self.layout.width - controlsInset(self);
    const step: f32 = if (self.controls.breeze) 32 else 42;
    const width: f32 = if (self.controls.breeze) 22 else 34;
    for (0..3) |i| {
        const left = start + @as(f32, @floatFromInt(i)) * step;
        if (x >= left and x < left + width) return i;
    }
    return null;
}
fn circle(self: *App, cx: f32, cy: f32, radius: f32, color: [4]u8) !void {
    var y: f32 = -radius;
    while (y < radius) : (y += 1) {
        const half = @sqrt(@max(0, radius * radius - (y + 0.5) * (y + 0.5)));
        try self.renderer.rect(cx - half, cy + y, half * 2, 1, color);
    }
}
/// Zed's title bar segments (`title_bar.rs` render): project name button, then the
/// worktree and branch buttons joined by a 25%-alpha "/", and on the right the
/// "Sign In" button and user-menu chevron. Buttons use `LabelSize::Small` (12px),
/// `IconSize::XSmall` (12px) start icons and 22px-high ghost backgrounds.
pub const Segment = enum { project, worktree, branch, sign_in, user_menu };
pub const Hit = struct { segment: Segment, x: f32, w: f32 };
const button_y: f32 = 6;
const button_h: f32 = 22;
const pad: f32 = 6;
const icon_gap: f32 = 4;
const worktree_label = "main";

fn hasRepository(self: *App) bool {
    return self.title_branch_len > 0;
}
fn labelButtonWidth(self: *App, label: []const u8, with_icon: bool) f32 {
    return pad * 2 + @min(220, self.renderer.widthSmall(label)) + (if (with_icon) 12 + icon_gap else 0);
}
/// Left-to-right segment rectangles; `out` must hold five entries.
pub fn segments(self: *App, out: *[5]Hit) []Hit {
    var n: usize = 0;
    var x: f32 = 40;
    // Zed hides the project items while the application menu bar is expanded.
    const project_items = appMenuOpen(self) == null;
    if (project_items and self.settings.title_project) {
        const w = labelButtonWidth(self, std.fs.path.basename(self.workspace.root), false);
        out[n] = .{ .segment = .project, .x = x, .w = w };
        n += 1;
        x += w + 2;
    }
    if (project_items and hasRepository(self)) {
        if (self.settings.title_worktree) {
            const w = labelButtonWidth(self, worktree_label, true);
            out[n] = .{ .segment = .worktree, .x = x, .w = w };
            n += 1;
            x += w + 1;
            if (self.settings.title_branch) x += self.renderer.widthSmall("/") + 1;
        }
        if (self.settings.title_branch) {
            const w = labelButtonWidth(self, self.title_branch[0..self.title_branch_len], true);
            out[n] = .{ .segment = .branch, .x = x, .w = w };
            n += 1;
        }
    }
    // Right group: `pr_1().gap_1()` ending left of the database toggle.
    var right = self.layout.width - controlsInset(self) - 36 - 4;
    if (self.settings.title_user_menu) {
        const w: f32 = if (self.account.user() != null and self.settings.title_user_picture) 24 else 22;
        right -= w;
        out[n] = .{ .segment = .user_menu, .x = right, .w = w };
        n += 1;
        right -= 4;
    }
    if (self.account.user() == null and (self.settings.title_sign_in or self.account.signingIn())) {
        const w = labelButtonWidth(self, if (self.account.signingIn()) "Signing in…" else "Sign In", false);
        right -= w;
        out[n] = .{ .segment = .sign_in, .x = right, .w = w };
        n += 1;
    }
    return out[0..n];
}
pub fn segmentAt(self: *App, x: f32, y: f32) ?Segment {
    if (y < button_y or y >= button_y + button_h) return null;
    var buf: [5]Hit = undefined;
    for (segments(self, &buf)) |hit| if (x >= hit.x and x < hit.x + hit.w) return hit.segment;
    return null;
}
/// Kept for callers that only need the end of the left-hand project items.
pub fn projectEnd(self: *App) f32 {
    var buf: [5]Hit = undefined;
    var end: f32 = 40;
    for (segments(self, &buf)) |hit| if (hit.segment != .sign_in and hit.segment != .user_menu) {
        end = hit.x + hit.w;
    };
    return end;
}
pub fn draw(self: *App) !void {
    const t = self.settings.theme;
    const title = try self.layout.rect(self.layout.title);
    try self.fill(title, t.title_bar);
    if (appMenuOpen(self)) |open| {
        var rects: [menus.app_menu_names.len]Rect = undefined;
        menuNameRects(self, &rects);
        for (menus.app_menu_names, rects, 0..) |name, r, i| {
            if (i == open) try self.renderer.roundRect(r.x, r.y, r.w, r.h, 4, t.ghost_element_selected) else if (r.contains(self.mouse_x, self.mouse_y)) try self.renderer.roundRect(r.x, r.y, r.w, r.h, 4, t.ghost_element_hover);
            try self.renderer.textSmall(name, r.x + 6, 21, if (i == open) t.accent else t.text);
        }
    } else try self.renderer.icon(icons.svg("ui:menu"), 12, 9, 16, t.muted);
    const inset = controlsInset(self);
    const baseline: f32 = 21;
    var buf: [5]Hit = undefined;
    const hits = segments(self, &buf);
    const hovered_segment = if (self.mouse_y < 34) segmentAt(self, self.mouse_x, self.mouse_y) else null;
    self.clip(.{ .x = 40, .y = 0, .w = @max(0, title.w - inset - 40), .h = 34 });
    const tooltip = @import("tooltip.zig");
    tooltip.register(self, .{ .rect = .{ .x = 6, .y = 6, .w = 28, .h = 22 }, .title = "Open Application Menu" });
    for (hits) |hit| {
        const rect: Rect = .{ .x = hit.x, .y = button_y, .w = hit.w, .h = button_h };
        switch (hit.segment) {
            .project => tooltip.register(self, .{ .rect = rect, .title = "Recent Projects", .action = "projects::OpenRecent" }),
            .worktree => tooltip.register(self, .{ .rect = rect, .title = "Worktree", .action = "git::Worktree", .meta = "Currently In Use: main" }),
            .branch => tooltip.register(self, .{ .rect = rect, .title = "Branch & Stash", .action = "git::Branch", .meta = "Currently Checked Out" }),
            .sign_in, .user_menu => {},
        }
        if (hovered_segment == hit.segment) try self.renderer.roundRect(hit.x, button_y, hit.w, button_h, 4, t.ghost_element_hover);
        switch (hit.segment) {
            .project => try self.renderer.textSmall(std.fs.path.basename(self.workspace.root), hit.x + pad, baseline, t.text),
            .worktree => {
                try self.renderer.icon(icons.svg("ui:git_worktree"), hit.x + pad, 11, 12, t.muted);
                try self.renderer.textSmall(worktree_label, hit.x + pad + 12 + icon_gap, baseline, t.muted);
                if (self.settings.title_branch) {
                    var slash = t.muted;
                    slash[3] = @intCast(@as(u16, slash[3]) / 4);
                    try self.renderer.textSmall("/", hit.x + hit.w + 1, baseline, slash);
                }
            },
            .branch => {
                try self.renderer.icon(icons.svg("ui:git_branch"), hit.x + pad, 11, 12, t.muted);
                try self.renderer.textSmall(self.title_branch[0..self.title_branch_len], hit.x + pad + 12 + icon_gap, baseline, t.muted);
            },
            .sign_in => if (self.account.signingIn()) {
                // Zed pulses the muted label between 40% and 80% opacity every 2s.
                const phase = @as(f32, @floatFromInt(@import("sdl3").timer.getMillisecondsSinceInit() % 2000)) / 2000;
                var color = t.muted;
                color[3] = @intFromFloat(255 * (0.4 + 0.4 * (0.5 - 0.5 * @cos(phase * 2 * std.math.pi))));
                try self.renderer.textSmall("Signing in…", hit.x + pad, baseline, color);
            } else try self.renderer.textSmall("Sign In", hit.x + pad, baseline, t.text),
            .user_menu => if (self.account.user()) |u| {
                if (self.settings.title_user_picture) try drawAvatar(self, u.login, hit.x + 4, 9) else try self.renderer.icon(icons.svg("ui:chevron_down"), hit.x + 4, 10, 14, t.text);
            } else try self.renderer.icon(icons.svg("ui:chevron_down"), hit.x + 4, 10, 14, t.text),
        }
    }
    self.renderer.setClip(null);
    try self.renderer.icon(icons.svg("ui:database_zap"), title.w - inset - 28, 9, 16, t.muted);
    const breeze = self.controls.breeze;
    const diameter: f32 = if (breeze) 18 else 24;
    const margin: f32 = if (breeze) 2 else 5;
    const step: f32 = if (breeze) 32 else 42;
    const start = title.w - inset;
    const maximized = self.window.getFlags().maximized;
    const kinds = [_]Kind{ .minimize, if (maximized) .restore else .maximize, .close };
    for (kinds, 0..) |kind, i| {
        const x = start + @as(f32, @floatFromInt(i)) * step + margin;
        const hovered = controlAt(self, self.mouse_x, self.mouse_y) == i;
        const pressed = hovered and self.pointer_down;
        var foreground = t.text;
        var background: [4]u8 = .{ t.text[0], t.text[1], t.text[2], if (pressed) 77 else if (hovered) 38 else 26 };
        if (breeze) {
            background = if (hovered) (if (i == 2) (if (pressed) [4]u8{ 109, 34, 41, 255 } else [4]u8{ 255, 152, 162, 255 }) else t.text) else .{ 0, 0, 0, 0 };
            if (hovered) foreground = t.title_bar;
        }
        if (!self.focused) foreground[3] = 128;
        if (background[3] > 0) try circle(self, x + diameter / 2, 17, diameter / 2, background);
        try self.controls.draw(&self.renderer, kind, x + (diameter - 16) / 2, 9, 16, foreground);
    }
    try self.renderer.rect(0, 33, title.w, 1, t.border);
}
