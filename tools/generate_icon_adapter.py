#!/usr/bin/env python3
"""Generate Zig lookup code from Zed's associations and existing SVGs. Never edits assets."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
rust = (root / '.ref/zed/crates/theme/src/icon_theme.rs').read_text()
quote = json.dumps

def associations(name):
    start = rust.index('const ' + name + ':')
    end = rust.index('\n];', start)
    result = []
    for icon, keys in re.findall(r'\(\s*"([^"]+)"\s*,\s*&\[([^\]]*)\]\s*,?\s*\)', rust[start:end], re.S):
        for key in re.findall(r'"([^"]+)"', keys): result.append((key, icon))
    return result

start = rust.index('const FILE_ICONS:')
end = rust.index('\n];', start)
file_icons = re.findall(r'\("([^"]+)", "([^"]+)"\)', rust[start:end])
svg_paths = sorted(p.relative_to(root / 'assets').as_posix() for p in (root / 'assets/icons').rglob('*.svg'))
for name, path in file_icons:
    if path not in svg_paths: raise SystemExit(f'Missing supplied file icon: {path}')
lines = ['//! Generated adapter for existing assets; SVG files are embedded byte-for-byte.', 'const std = @import("std");', 'pub const Icon = struct { name: []const u8, data: []const u8 };', 'const icon_assets = [_]Icon{']
for path in svg_paths:
    lines.append(f'    .{{ .name = {quote(path)}, .data = @embedFile({quote(path)}) }},')
lines += ['};', 'const Association = struct { key: []const u8, icon: []const u8 };']
for name, entries in [('types', file_icons), ('stems', associations('FILE_STEMS_BY_ICON_KEY')), ('suffixes', associations('FILE_SUFFIXES_BY_ICON_KEY'))]:
    lines.append(f'const {name} = [_]Association{{')
    for key, icon in entries: lines.append(f'    .{{ .key = {quote(key)}, .icon = {quote(icon)} }},')
    lines.append('};')
lines.append('''
pub fn asset(path: []const u8) ?[]const u8 {
    for (icon_assets) |icon| if (std.mem.eql(u8, path, icon.name)) return icon.data;
    return null;
}
fn typeIcon(name: []const u8) ?[]const u8 {
    for (types) |entry| if (std.mem.eql(u8, name, entry.key)) return asset(entry.icon);
    return null;
}
pub fn svg(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "icons/")) return asset(name) orelse typeIcon("default").?;
    const ui = std.mem.startsWith(u8, name, "ui:");
    const key = if (ui) name[3..] else name;
    if (!ui) if (typeIcon(key)) |icon| return icon;
    var buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "icons/{s}.svg", .{key}) catch return typeIcon("default").?;
    if (asset(path)) |icon| return icon;
    const file_path = std.fmt.bufPrint(&buffer, "icons/file_icons/{s}.svg", .{key}) catch return typeIcon("default").?;
    return asset(file_path) orelse typeIcon("default").?;
}
fn associated(name: []const u8) ?[]const u8 {
    for (stems) |entry| if (std.mem.eql(u8, name, entry.key)) if (typeIcon(entry.icon)) |icon| return icon;
    for (suffixes) |entry| if (std.mem.eql(u8, name, entry.key)) if (typeIcon(entry.icon)) |icon| return icon;
    return null;
}
/// Zed FileIcons::get_icon: whole filename, progressively shorter dot suffixes,
/// first stem (Dockerfile.prod / Podfile.lock), then default. Comparisons are case-sensitive.
pub fn fileForPath(path: []const u8) []const u8 {
    const last_sep = std.mem.lastIndexOfAny(u8, path, "/\\\\");
    const base = if (last_sep) |index| path[index + 1 ..] else path;
    if (associated(base)) |icon| return icon;
    var remaining = base;
    var first: ?[]const u8 = null;
    while (std.mem.indexOfScalar(u8, remaining, '.')) |dot| {
        if (first == null) first = remaining[0..dot];
        remaining = remaining[dot + 1 ..];
        if (associated(remaining)) |icon| return icon;
    }
    if (first) |stem| if (associated(stem)) |icon| return icon;
    return typeIcon("default").?;
}
test "original SVG paths and Zed filename resolution" {
    try std.testing.expectEqualStrings(@embedFile("icons/git_branch.svg"), svg("ui:git_branch"));
    try std.testing.expectEqualStrings(@embedFile("icons/file_icons/folder.svg"), svg("icons/file_icons/folder.svg"));
    try std.testing.expectEqualStrings(svg("docker"), fileForPath("Dockerfile.prod"));
    try std.testing.expectEqualStrings(svg("ruby"), fileForPath("Podfile.lock"));
    try std.testing.expectEqualStrings(svg("json"), fileForPath("/.data.json"));
    try std.testing.expectEqualStrings(svg("docker"), fileForPath("docker-compose.yml"));
    try std.testing.expectEqualStrings(svg("default"), fileForPath("MY.ZIG"));
    try std.testing.expectEqualStrings(svg("zig"), fileForPath("/build.zig"));
    for (types) |entry| try std.testing.expect(asset(entry.icon) != null);
}
''')
(root / 'assets/icons.zig').write_text('\n'.join(lines))
print(f'Generated adapter: {len(svg_paths)} unchanged SVGs, {len(file_icons)} Zed file types')
