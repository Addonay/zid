//! Finds the user's window-control glyphs the way GTK does, which is what
//! agentik gets by asking libgtk at runtime, without loading GTK:
//!
//! - the theme names come from gsettings (GNOME) or ~/.config/gtk-3.0/settings.ini;
//! - icons are resolved per the freedesktop icon-theme spec: each theme's
//!   index.theme lists size directories and an Inherits chain, ending in
//!   Adwaita and hicolor;
//! - the size directory closest to the requested size wins.
//!
//! A GTK theme named Breeze* also switches the caption buttons to Breeze's
//! style, as in agentik.
const std = @import("std");
const Io = std.Io;

pub const Desktop = struct {
    icon_theme: []const u8,
    gtk_theme: []const u8,

    pub fn breeze(d: Desktop) bool {
        return d.gtk_theme.len >= 6 and std.ascii.eqlIgnoreCase(d.gtk_theme[0..6], "breeze");
    }
};

/// Reads the theme names (strings live in `a`).
pub fn desktop(a: std.mem.Allocator, io: Io, home: []const u8) Desktop {
    var d: Desktop = .{ .icon_theme = "", .gtk_theme = "" };
    d.icon_theme = gsetting(a, io, "icon-theme") orelse "";
    d.gtk_theme = gsetting(a, io, "gtk-theme") orelse "";
    if (d.icon_theme.len == 0 or d.gtk_theme.len == 0) {
        const path = std.fs.path.join(a, &.{ home, ".config/gtk-3.0/settings.ini" }) catch return d;
        const ini = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 10)) catch return d;
        var lines = std.mem.tokenizeScalar(u8, ini, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r\"");
            if (d.icon_theme.len == 0 and std.mem.eql(u8, key, "gtk-icon-theme-name")) d.icon_theme = val;
            if (d.gtk_theme.len == 0 and std.mem.eql(u8, key, "gtk-theme-name")) d.gtk_theme = val;
        }
    }
    return d;
}

fn gsetting(a: std.mem.Allocator, io: Io, key: []const u8) ?[]const u8 {
    const res = std.process.run(a, io, .{ .argv = &.{ "gsettings", "get", "org.gnome.desktop.interface", key }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return null;
    if (res.term != .exited or res.term.exited != 0) return null;
    const v = std.mem.trim(u8, res.stdout, " \t\r\n'\"");
    return if (v.len > 0) v else null;
}

/// Path of the best `name`.svg for `size` px in `theme` or its ancestors.
/// The result lives in `a`.
pub fn find(a: std.mem.Allocator, io: Io, home: []const u8, theme: []const u8, name: []const u8, size: u32) ?[]const u8 {
    const bases = [_][]const u8{
        std.fs.path.join(a, &.{ home, ".local/share/icons" }) catch return null,
        std.fs.path.join(a, &.{ home, ".icons" }) catch return null,
        "/usr/local/share/icons",
        "/usr/share/icons",
    };
    var queue: std.ArrayList([]const u8) = .empty;
    if (theme.len > 0) queue.append(a, theme) catch return null;
    var i: usize = 0;
    var fallbacks_added = false;
    while (true) : (i += 1) {
        if (i == queue.items.len) {
            if (fallbacks_added) return null;
            fallbacks_added = true;
            queue.appendSlice(a, &.{ "Adwaita", "hicolor" }) catch return null;
        }
        const t = queue.items[i];
        var seen = false;
        for (queue.items[0..i]) |prev| if (std.mem.eql(u8, prev, t)) {
            seen = true;
        };
        if (seen) continue;
        for (bases) |base| {
            const index_path = std.fmt.allocPrint(a, "{s}/{s}/index.theme", .{ base, t }) catch continue;
            const index = Io.Dir.cwd().readFileAlloc(io, index_path, a, .limited(1 << 20)) catch continue;
            if (bestIn(a, io, base, t, index, name, size)) |path| return path;
            if (field(index, "Icon Theme", "Inherits")) |inherits| {
                var it = std.mem.tokenizeScalar(u8, inherits, ',');
                while (it.next()) |parent| queue.append(a, std.mem.trim(u8, parent, " ")) catch {};
            }
            break;
        }
    }
}

/// The candidate in one theme whose directory size is closest to `size`.
fn bestIn(a: std.mem.Allocator, io: Io, base: []const u8, theme: []const u8, index: []const u8, name: []const u8, size: u32) ?[]const u8 {
    const dirs = field(index, "Icon Theme", "Directories") orelse return null;
    var best: ?[]const u8 = null;
    var best_d: u32 = std.math.maxInt(u32);
    var it = std.mem.tokenizeScalar(u8, dirs, ',');
    while (it.next()) |dir_raw| {
        const dir = std.mem.trim(u8, dir_raw, " ");
        const s = if (field(index, dir, "Size")) |v| std.fmt.parseInt(u32, v, 10) catch 16 else 16;
        const d = if (s > size) s - size else size - s;
        if (d >= best_d) continue;
        const path = std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}.svg", .{ base, theme, dir, name }) catch continue;
        Io.Dir.cwd().access(io, path, .{}) catch continue;
        best = path;
        best_d = d;
    }
    return best;
}

/// Value of `key` in `[section]` of an ini-style index.theme.
fn field(ini: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var in_section = false;
    var lines = std.mem.tokenizeScalar(u8, ini, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 1 and line[0] == '[') {
            in_section = line[line.len - 1] == ']' and std.mem.eql(u8, line[1 .. line.len - 1], section);
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " "), key)) return std.mem.trim(u8, line[eq + 1 ..], " ");
    }
    return null;
}

test "index.theme fields" {
    const ini =
        \\[Icon Theme]
        \\Name=Test
        \\Inherits=breeze,hicolor
        \\Directories=actions/16,actions/22
        \\
        \\[actions/16]
        \\Size=16
        \\
        \\[actions/22]
        \\Size=22
    ;
    try std.testing.expectEqualStrings("breeze,hicolor", field(ini, "Icon Theme", "Inherits").?);
    try std.testing.expectEqualStrings("22", field(ini, "actions/22", "Size").?);
    try std.testing.expect(field(ini, "actions/24", "Size") == null);
}
