//! Zed's default status bar (`workspace/src/status_bar.rs`, items registered in
//! `zed/src/zed.rs` and `workspace.rs`). Left: left-dock buttons, project search,
//! LSP tool and diagnostic summary, then activity text. Right items render in
//! reverse registration order: cursor position, active language, then the
//! bottom-dock (terminal, debugger) and right-dock buttons (project, git, collab,
//! outline) sorted by `activation_priority`.
//!
//! Buttons are `IconButton`s with `IconSize::Small` (14px) in a 22px
//! `ButtonSize::Default` box, `gap_1` apart with `Base04` padding; labels use
//! `LabelSize::Small` (12px). AI items (agent panel, edit prediction) are omitted
//! while AI features are deferred. Panels Zid does not have yet show a notice.
const std = @import("std");
const zid = @import("zid");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const icons = @import("icons");

pub const Item = enum { project_panel, search, lsp, diagnostics, cursor, language, image_info, terminal, debugger, git_panel, collab_panel, outline_panel };
pub const Hit = struct { item: Item, x: f32, w: f32 };
const button: f32 = 22;
const gap: f32 = 4;
const pad: f32 = 4;
const label_pad: f32 = 6;
pub const max_items = @typeInfo(Item).@"enum".field_names.len;

const Counts = struct { errors: usize = 0, warnings: usize = 0 };
fn diagnosticCounts(self: *const App) Counts {
    var counts: Counts = .{};
    const diagnostics = self.currentDiagnostics() orelse return counts;
    for (diagnostics.diagnostics) |d| switch (d.severity orelse 1) {
        1 => counts.errors += 1,
        2 => counts.warnings += 1,
        else => {},
    };
    return counts;
}
fn countWidth(self: *App, n: usize) f32 {
    var buf: [24]u8 = undefined;
    return self.renderer.widthSmall(std.fmt.bufPrint(&buf, "{d}", .{n}) catch "");
}
fn diagnosticsWidth(self: *App) f32 {
    const c = diagnosticCounts(self);
    if (c.errors == 0 and c.warnings == 0) return button;
    var w: f32 = label_pad * 2;
    if (c.errors > 0) w += 14 + gap + countWidth(self, c.errors);
    if (c.warnings > 0) w += (if (c.errors > 0) gap else 0) + 14 + gap + countWidth(self, c.warnings);
    return w;
}
fn activeDocument(self: *App) ?*zid.Document {
    // Non-editor items (onboarding, keymap editor) have no cursor or language.
    if (self.keymap_editor_open or @import("onboarding.zig").isActive(self)) return null;
    const doc = self.workspace.currentOrNull() orelse return null;
    return if (doc.image) null else doc;
}
fn cursorText(self: *App, buf: []u8) ?[]const u8 {
    const doc = activeDocument(self) orelse return null;
    if (doc.large) |large| {
        const sel = large.selection();
        return std.fmt.bufPrint(buf, "Byte {d} / {d} ({d} selected)", .{ large.offset, large.size, sel.end - sel.start }) catch null;
    }
    const row = doc.lineOf(doc.cursor);
    return std.fmt.bufPrint(buf, "{d}:{d}", .{ row + 1, doc.cursor - doc.lineStart(row) + 1 }) catch null;
}
var image_info_buf: [128]u8 = undefined;
fn imageInfo(self: *App) ?[]const u8 {
    if (self.keymap_editor_open or @import("onboarding.zig").isActive(self)) return null;
    const doc = self.workspace.currentOrNull() orelse return null;
    if (!doc.image) return null;
    return @import("image_view.zig").info(self, doc, &image_info_buf);
}
fn languageText(self: *App) ?[]const u8 {
    const doc = activeDocument(self) orelse return null;
    return zid.syntax.Language.fromPath(doc.path orelse "").displayName();
}

/// Item rectangles for the current frame; `out` must hold `max_items` entries.
pub fn items(self: *App, status: Rect, out: *[max_items]Hit) []Hit {
    var n: usize = 0;
    var x = status.x + pad;
    const s = self.settings;
    if (s.panel_button and !s.panel_right) {
        out[n] = .{ .item = .project_panel, .x = x, .w = button };
        n += 1;
        x += button + gap;
    }
    for ([_]Item{ .search, .lsp }) |item| {
        out[n] = .{ .item = item, .x = x, .w = button };
        n += 1;
        x += button + gap;
    }
    out[n] = .{ .item = .diagnostics, .x = x, .w = diagnosticsWidth(self) };
    n += 1;

    // Placed right-to-left: right dock (project, git, collab, outline by
    // activation priority), then bottom dock (terminal, debugger).
    var right = status.x + status.w - pad;
    const project_right = s.panel_button and s.panel_right;
    const trailing = [_]Item{ .outline_panel, .collab_panel, .git_panel, .project_panel, .debugger, .terminal };
    for (trailing) |item| {
        if (item == .project_panel and !project_right) continue;
        right -= button;
        out[n] = .{ .item = item, .x = right, .w = button };
        n += 1;
        right -= gap;
    }
    // Zed's `ImageInfo` item for image documents.
    if (imageInfo(self)) |label| {
        const w = self.renderer.widthSmall(label) + label_pad * 2;
        right -= w;
        out[n] = .{ .item = .image_info, .x = right, .w = w };
        n += 1;
        right -= gap;
    }
    if (s.status_language) if (languageText(self)) |label| {
        const w = self.renderer.widthSmall(label) + label_pad * 2;
        right -= w;
        out[n] = .{ .item = .language, .x = right, .w = w };
        n += 1;
        right -= gap;
    };
    var buf: [96]u8 = undefined;
    if (s.status_cursor) if (cursorText(self, &buf)) |label| {
        const w = self.renderer.widthSmall(label) + label_pad * 2;
        right -= w;
        out[n] = .{ .item = .cursor, .x = right, .w = w };
        n += 1;
    };
    return out[0..n];
}

pub fn itemAt(self: *App, status: Rect, mx: f32, my: f32) ?Item {
    if (!self.settings.status_visible or !status.contains(mx, my)) return null;
    var buf: [max_items]Hit = undefined;
    for (items(self, status, &buf)) |hit| if (mx >= hit.x and mx < hit.x + hit.w) return hit.item;
    return null;
}

pub fn click(self: *App, item: Item) !void {
    switch (item) {
        .project_panel => try self.runCommand(.@"workspace::ToggleLeftDock"),
        .cursor => try self.runCommand(.@"go_to_line::Toggle"),
        .search => self.notice("Project search is not implemented yet", .{}),
        .lsp => {
            const status = try self.layout.rect(self.layout.status);
            var buf: [max_items]Hit = undefined;
            for (items(self, status, &buf)) |hit| if (hit.item == .lsp) {
                @import("context_menu.zig").open(self, @import("../menus.zig").lsp(self, hit.x, status.y - 2));
            };
        },
        .diagnostics => self.notice("Project diagnostics view is not implemented yet", .{}),
        .language => self.notice("Language selector is not implemented yet", .{}),
        .image_info => {},
        .terminal => self.notice("Terminal panel is not implemented yet (milestone M5)", .{}),
        .debugger => self.notice("Debugger panel is not implemented yet", .{}),
        .git_panel => self.notice("Git panel is not implemented yet (milestone M6)", .{}),
        .collab_panel => self.notice("Collaboration panel is out of scope for Zid", .{}),
        .outline_panel => self.notice("Outline panel is not implemented yet", .{}),
    }
}

/// Zed's tooltip titles and actions for the status-bar items.
fn tipFor(item: Item) struct { []const u8, []const u8 } {
    return switch (item) {
        .project_panel => .{ "Project Panel", "project_panel::ToggleFocus" },
        .search => .{ "Project Search", "pane::DeploySearch" },
        .lsp => .{ "Language Servers", "lsp_tool::ToggleMenu" },
        .diagnostics => .{ "Project Diagnostics", "diagnostics::Deploy" },
        .cursor => .{ "Go to Line/Column", "go_to_line::Toggle" },
        .language => .{ "Select Language", "language_selector::Toggle" },
        .image_info => .{ "Image Info", "" },
        .terminal => .{ "Terminal Panel", "terminal_panel::Toggle" },
        .debugger => .{ "Debug Panel", "debug_panel::ToggleFocus" },
        .git_panel => .{ "Git Panel", "git_panel::ToggleFocus" },
        .collab_panel => .{ "Collab Panel", "collab_panel::ToggleFocus" },
        .outline_panel => .{ "Outline Panel", "outline_panel::ToggleFocus" },
    };
}

fn iconFor(item: Item) []const u8 {
    return switch (item) {
        .project_panel => "ui:file_tree",
        .search => "ui:magnifying_glass",
        .lsp => "ui:bolt_outlined",
        .terminal => "ui:terminal_alt",
        .debugger => "ui:debug",
        .git_panel => "ui:git_branch",
        .collab_panel => "ui:user_group",
        .outline_panel => "ui:list_tree",
        .diagnostics, .cursor, .language, .image_info => unreachable,
    };
}

pub fn draw(self: *App) !void {
    const t = self.settings.theme;
    const status = try self.layout.rect(self.layout.status);
    try self.fill(status, t.status);
    try self.renderer.rect(0, status.y, status.w, 1, t.border);
    if (!self.settings.status_visible) return;
    const by = status.y + (status.h - button) / 2;
    const iy = status.y + (status.h - 14) / 2;
    const baseline = status.y + status.h / 2 + 4.5;
    const hovered = itemAt(self, status, self.mouse_x, self.mouse_y);
    var buf: [max_items]Hit = undefined;
    const hits = items(self, status, &buf);
    var text_x: f32 = status.x + pad;
    var text_end: f32 = status.x + status.w;
    for (hits) |hit| {
        const tip = tipFor(hit.item);
        @import("tooltip.zig").register(self, .{ .rect = .{ .x = hit.x, .y = by, .w = hit.w, .h = button }, .title = tip[0], .action = tip[1] });
        const selected = hit.item == .project_panel and self.panel_open;
        if (selected) try self.renderer.roundRect(hit.x, by, hit.w, button, 4, t.ghost_element_selected) else if (hovered == hit.item) try self.renderer.roundRect(hit.x, by, hit.w, button, 4, t.ghost_element_hover);
        switch (hit.item) {
            .diagnostics => {
                text_x = hit.x + hit.w + gap * 2;
                const c = diagnosticCounts(self);
                if (c.errors == 0 and c.warnings == 0) {
                    try self.renderer.icon(icons.svg("ui:check"), hit.x + 4, iy, 14, t.icon);
                    continue;
                }
                var x = hit.x + label_pad;
                var num: [24]u8 = undefined;
                if (c.errors > 0) {
                    try self.renderer.icon(icons.svg("ui:x_circle"), x, iy, 14, t.error_text);
                    const label = try std.fmt.bufPrint(&num, "{d}", .{c.errors});
                    try self.renderer.textSmall(label, x + 14 + gap, baseline, t.text);
                    x += 14 + gap + self.renderer.widthSmall(label) + gap;
                }
                if (c.warnings > 0) {
                    try self.renderer.icon(icons.svg("ui:warning"), x, iy, 14, t.warning);
                    const label = try std.fmt.bufPrint(&num, "{d}", .{c.warnings});
                    try self.renderer.textSmall(label, x + 14 + gap, baseline, t.text);
                }
            },
            .cursor => {
                var text: [96]u8 = undefined;
                if (cursorText(self, &text)) |label| try self.renderer.textSmall(label, hit.x + label_pad, baseline, t.text);
                text_end = @min(text_end, hit.x);
            },
            .language => {
                if (languageText(self)) |label| try self.renderer.textSmall(label, hit.x + label_pad, baseline, t.text);
                text_end = @min(text_end, hit.x);
            },
            .image_info => {
                if (imageInfo(self)) |label| try self.renderer.textSmall(label, hit.x + label_pad, baseline, t.text);
                text_end = @min(text_end, hit.x);
            },
            else => {
                if (hit.x > text_x) text_end = @min(text_end, hit.x);
                try self.renderer.icon(icons.svg(iconFor(hit.item)), hit.x + 4, iy, 14, t.icon);
            },
        }
    }
    // Activity text (Zed's activity indicator area) after the diagnostic summary.
    const width = @max(0, text_end - gap * 2 - text_x);
    self.clip(.{ .x = text_x, .y = status.y, .w = width, .h = status.h });
    defer self.renderer.setClip(null);
    const doc = self.workspace.currentOrNull();
    if (self.message_len > 0) {
        try self.renderer.textSmall(self.message[0..self.message_len], text_x, baseline, t.text);
    } else if (doc != null and doc.?.large != null) {
        try self.renderer.textSmall("Large file: read-only", text_x, baseline, t.muted);
    } else if (self.docPreview()) {
        try self.renderer.textSmall("Read-only preview: line exceeds 64 KiB", text_x, baseline, t.error_text);
    } else if (self.renderer.degraded) {
        try self.renderer.textSmall("Some glyphs replaced: font/atlas limit", text_x, baseline, t.error_text);
    } else if (self.currentDiagnostics()) |diagnostics| {
        const cursor_row = doc.?.lineOf(doc.?.cursor);
        for (diagnostics.diagnostics) |diagnostic| if (diagnostic.range.start.line == cursor_row) {
            try self.renderer.textSmall(diagnostic.message, text_x, baseline, t.muted);
            break;
        };
    }
}
