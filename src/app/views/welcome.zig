//! Welcome page, after Zed's `crates/workspace/src/welcome.rs` (`WelcomePage` opened by
//! `onboarding::Finish` or `zed::ShowWelcome`). It shares the page item in
//! `onboarding.zig` (tab, focus, activation); this file draws it and runs its buttons.
//!
//! Layout: a column at most `max_w_128` (512px) wide with `p_8`, centred vertically
//! (`justify_center`) and separated by `gap_6`; a centred header (45px logo, default
//! `Headline`, small italic tagline); "Get Started" and "Configure" sections whose
//! headers are uppercase `LabelSize::XSmall` buffer-font labels followed by a divider;
//! `ButtonSize::Medium` rows with a small muted icon, label and the action's keybinding;
//! then a divider and the full-width "Return to Onboarding" button.
//!
//! Omitted: the "Collaborate with Agents" card (AI is deferred) and the launchpad
//! variant ("Welcome back", recent projects) that Zed shows only in an empty pane
//! without a project; Zid always opens a folder.
const std = @import("std");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const icons = @import("icons");
const commands = @import("../input/commands.zig");

pub const Entry = struct { icon: []const u8, title: []const u8, action: []const u8 };
const Section = struct { title: []const u8, entries: []const Entry };
/// Zed `CONTENT`.
pub const sections = [_]Section{
    .{ .title = "Get Started", .entries = &.{
        .{ .icon = "ui:plus", .title = "New File", .action = "workspace::NewFile" },
        .{ .icon = "ui:folder_open", .title = "Open Project", .action = "workspace::Open" },
        .{ .icon = "ui:cloud_download", .title = "Clone Repository", .action = "git::Clone" },
        .{ .icon = "ui:list_collapse", .title = "Open Command Palette", .action = "command_palette::Toggle" },
    } },
    .{ .title = "Configure", .entries = &.{
        .{ .icon = "ui:settings", .title = "Open Settings", .action = "zed::OpenSettings" },
        .{ .icon = "ui:keyboard", .title = "Customize Keymaps", .action = "zed::OpenKeymap" },
        .{ .icon = "ui:blocks", .title = "Explore Extensions", .action = "zed::Extensions" },
    } },
};
pub fn entry(index: usize) ?Entry {
    var i = index;
    for (sections) |section| {
        if (i < section.entries.len) return section.entries[i];
        i -= section.entries.len;
    }
    return null;
}

const max_width: f32 = 512; // max_w_128
const padding: f32 = 32; // p_8
const gap: f32 = 24; // gap_6
const logo: f32 = 45;
const row_h: f32 = 28; // ButtonSize::Medium
const section_header_h: f32 = 24; // label line + mb_2
const return_h: f32 = 22; // ButtonSize::Default

fn contentHeight() f32 {
    var h: f32 = logo + 16; // header + mb_4
    for (sections) |section| h += gap + section_header_h + row_h * @as(f32, @floatFromInt(section.entries.len));
    return h + gap + 1 + 16 + return_h;
}

/// Runs a Welcome button's Zed action through Zid's registry; actions Zid lacks say so.
pub fn run(app: *App, index: usize) !void {
    const e = entry(index) orelse return;
    const command = std.meta.stringToEnum(commands.Command, e.action) orelse {
        app.notice("{s} is not implemented yet", .{e.title});
        return;
    };
    try app.runCommand(command);
}

pub fn draw(app: *App, state: anytype, area: Rect) !void {
    const t = app.settings.theme;
    const r = &app.renderer;
    const column = @min(max_width, area.w);
    const x = area.x + (area.w - column) / 2 + padding;
    const w = @max(0, column - padding * 2);
    const content = contentHeight();
    state.content_h = content + padding * 2;
    var y = area.y + @max(padding, (area.h - content) / 2) - state.scroll;

    // Header, centred as a group.
    {
        const title = "Welcome to Zid";
        const tagline = "The editor for what's next";
        const text_w = @max(r.widthHeadlineMedium(title), r.widthSmall(tagline) + 2);
        const group_w = logo + 16 + text_w;
        const gx = x + (w - group_w) / 2;
        try r.largeIcon(icons.svg("ui:zed_logo"), gx, y, logo, t.text);
        try r.textHeadlineMedium(title, gx + logo + 16, y + 21, t.text);
        try r.textSmallItalic(tagline, gx + logo + 16, y + 39, t.muted);
    }
    y += logo + 16;

    var index: usize = 0;
    var path_buf: [6]@import("../keymap.zig").Context = undefined;
    var ext_buf: [16]u8 = undefined;
    const path = commands.focusPath(app, &path_buf, &ext_buf);
    for (sections) |section| {
        y += gap;
        // SectionHeader: px_1, uppercase XSmall buffer-font label, gap_2, divider.
        var upper: [32]u8 = undefined;
        const label = std.ascii.upperString(upper[0..section.title.len], section.title);
        try r.textMonoXSmall(label, x + 4, y + 11, t.muted);
        const divider_x = x + 4 + r.widthMonoXSmall(label) + 8;
        try r.rect(divider_x, y + 7, @max(0, x + w - 4 - divider_x), 1, t.border_variant);
        y += section_header_h;
        for (section.entries) |e| {
            const row: Rect = .{ .x = x, .y = y, .w = w, .h = row_h };
            if (row.contains(app.mouse_x, app.mouse_y)) try r.roundRect(row.x, row.y, row.w, row.h, 6, t.ghost_element_hover);
            try r.icon(icons.svg(e.icon), x + 8, y + 7, 14, t.muted);
            try r.textUi(e.title, x + 8 + 14 + 8, y + 19, t.text);
            if (app.keymap.chordFor(e.action, path)) |chord| {
                var buf: [64]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buf);
                chord.format(&writer) catch {};
                const key = writer.buffered();
                try r.textSmall(key, x + w - 8 - r.widthSmall(key), y + 18, t.muted);
            }
            state.addHit(.{ .welcome = index }, row);
            index += 1;
            y += row_h;
        }
    }

    // Divider and "Return to Onboarding".
    y += gap;
    try r.rect(x, y, w, 1, t.border);
    y += 17;
    const button: Rect = .{ .x = x, .y = y, .w = w, .h = return_h };
    if (button.contains(app.mouse_x, app.mouse_y)) try r.roundRect(button.x, button.y, button.w, button.h, 6, t.ghost_element_hover);
    const label = "Return to Onboarding";
    try r.textXSmall(label, x + (w - r.widthXSmall(label)) / 2, y + 15, t.text);
    state.addHit(.return_to_onboarding, button);
}
