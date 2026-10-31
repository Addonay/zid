#!/usr/bin/env python3
"""Generate assets/icon_themes/catppuccin_latte.zig from the bundled Zed icon theme.

Reads assets/icon_themes/catppuccin-latte/catppuccin-zig-icons.json (kept byte-for-byte
from the upstream/local Zed extension) and writes a Zig module that @embedFile's every
referenced SVG exactly once and exposes allocation-free lookups.

Usage (from the repository root):

    python3 scripts/gen_icon_theme.py

Stdlib only. Output is deterministic. The JSON is never edited; the display name is set
by DISPLAY_NAME below.
"""

import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
THEME_DIR = REPO / "assets/icon_themes/catppuccin-latte"
THEME_JSON = THEME_DIR / "catppuccin-zig-icons.json"
OUT = REPO / "assets/icon_themes/catppuccin_latte.zig"
GENERATOR_CMD = "python3 scripts/gen_icon_theme.py"

# The JSON theme name carries a "(Zig Build Icons)" suffix; the Zig side uses this name.
DISPLAY_NAME = "Catppuccin Latte"


def warn(msg: str) -> None:
    print(f"gen_icon_theme: warning: {msg}", file=sys.stderr)


def zig_str(s: str) -> str:
    """Encode s as a Zig string literal (byte-wise, ASCII-safe)."""
    out = ['"']
    for b in s.encode("utf-8"):
        if b == 0x5C:  # backslash
            out.append("\\\\")
        elif b == 0x22:  # double quote
            out.append('\\"')
        elif 0x20 <= b < 0x7F:
            out.append(chr(b))
        else:
            out.append(f"\\x{b:02x}")
    out.append('"')
    return "".join(out)


def resolve_svg(icon_path: str, where: str):
    """Return the SVG's path relative to OUT's directory, or None (with a warning)."""
    if not isinstance(icon_path, str) or not icon_path:
        warn(f"{where}: icon path is not a string: {icon_path!r}")
        return None
    rel = icon_path[2:] if icon_path.startswith("./") else icon_path
    src = (THEME_DIR / rel).resolve()
    try:
        src.relative_to(THEME_DIR.resolve())
    except ValueError:
        warn(f"{where}: icon path escapes the theme directory: {icon_path}")
        return None
    if not src.is_file():
        warn(f"{where}: SVG not found, skipped: {icon_path}")
        return None
    return os.path.relpath(src, OUT.parent).replace(os.sep, "/")


def main() -> int:
    with THEME_JSON.open("rb") as f:
        doc = json.loads(f.read().decode("utf-8"))
    themes = doc.get("themes", [])
    if not themes:
        print("gen_icon_theme: error: no themes in JSON", file=sys.stderr)
        return 1
    theme = themes[0]
    appearance = theme.get("appearance")
    if appearance not in ("light", "dark"):
        print(f"gen_icon_theme: error: unexpected appearance {appearance!r}", file=sys.stderr)
        return 1

    file_icons = theme.get("file_icons", {})

    def icon_rel(icon_key: str, where: str):
        spec = file_icons.get(icon_key)
        if not isinstance(spec, dict) or "path" not in spec:
            warn(f"{where}: icon key {icon_key!r} has no file_icons entry, skipped")
            return None
        return resolve_svg(spec["path"], where)

    # --- Collect tables (keys -> svg relative paths) ---------------------------------
    stems = []
    for key, icon_key in theme.get("file_stems", {}).items():
        rel = icon_rel(icon_key, f"file_stems[{key!r}]")
        if rel is not None:
            stems.append((key, rel))

    suffixes = []
    for key, icon_key in theme.get("file_suffixes", {}).items():
        rel = icon_rel(icon_key, f"file_suffixes[{key!r}]")
        if rel is not None:
            suffixes.append((key, rel))

    named_dirs = []
    for key, variants in theme.get("named_directory_icons", {}).items():
        collapsed = resolve_svg(variants.get("collapsed"), f"named_directory_icons[{key!r}].collapsed") \
            if variants.get("collapsed") else None
        expanded = resolve_svg(variants.get("expanded"), f"named_directory_icons[{key!r}].expanded") \
            if variants.get("expanded") else None
        if collapsed is None and expanded is None:
            warn(f"named_directory_icons[{key!r}]: no usable variant, skipped")
            continue
        named_dirs.append((key, collapsed, expanded))

    dir_default = theme.get("directory_icons", {})
    dir_collapsed = resolve_svg(dir_default.get("collapsed"), "directory_icons.collapsed")
    dir_expanded = resolve_svg(dir_default.get("expanded"), "directory_icons.expanded")
    if dir_collapsed is None or dir_expanded is None:
        print("gen_icon_theme: error: directory_icons must have collapsed and expanded SVGs",
              file=sys.stderr)
        return 1

    chevrons = theme.get("chevron_icons", {})
    chev_collapsed = resolve_svg(chevrons["collapsed"], "chevron_icons.collapsed") \
        if chevrons.get("collapsed") else None
    chev_expanded = resolve_svg(chevrons["expanded"], "chevron_icons.expanded") \
        if chevrons.get("expanded") else None

    default_file = None
    if "default" in file_icons:
        default_file = icon_rel("default", "file_icons['default']")

    # --- Assign one @embedFile constant per distinct referenced SVG -----------------
    referenced = set()
    referenced.update(p for _, p in stems)
    referenced.update(p for _, p in suffixes)
    for _, c, e in named_dirs:
        referenced.update(p for p in (c, e) if p is not None)
    referenced.update([dir_collapsed, dir_expanded])
    referenced.update(p for p in (chev_collapsed, chev_expanded, default_file) if p is not None)

    const_of = {}
    for i, rel in enumerate(sorted(referenced)):
        const_of[rel] = f"svg_{i:04d}"

    def c(rel):
        return "null" if rel is None else const_of[rel]

    def entries(rows):
        return [(key, c(rel)) for key, rel in rows]

    def sorted_by_key(rows):
        return sorted(rows, key=lambda r: r[0].encode("utf-8"))

    stems_s = sorted_by_key(stems)
    suffixes_s = sorted_by_key(suffixes)
    named_s = sorted_by_key(named_dirs)

    # --- Emit Zig --------------------------------------------------------------------
    L = []
    w = L.append
    w("//! GENERATED FILE. Do not edit by hand.")
    w("//!")
    w("//! Regenerate with:")
    w(f"//!     {GENERATOR_CMD}")
    w("//!")
    w("//! Source: assets/icon_themes/catppuccin-latte/catppuccin-zig-icons.json")
    w("//!   (Zed icon theme \"Catppuccin Latte (Zig Build Icons)\" from the local")
    w("//!   \"Catppuccin Zig Icons\" extension v0.0.1; upstream MIT, see assets/icon_themes/README.md).")
    w(f"//! The display name is set by the generator; the JSON is copied byte-for-byte.")
    w("")
    w('const std = @import("std");')
    w("")
    w(f"pub const display_name = {zig_str(DISPLAY_NAME)};")
    w("")
    w("pub const Appearance = enum { light, dark };")
    w(f"pub const appearance: Appearance = .{appearance};")
    w("")
    w("pub const Entry = struct { key: []const u8, svg: []const u8 };")
    w("pub const DirEntry = struct { key: []const u8, collapsed: ?[]const u8, expanded: ?[]const u8 };")
    w("")
    w("// Embedded SVGs: each referenced file appears exactly once.")
    for rel, name in sorted(const_of.items(), key=lambda kv: kv[1]):
        w(f"// {rel.removeprefix('catppuccin-latte/')}")
        w(f"const {name} = @embedFile({zig_str(rel)});")
    w("")

    w("// file_stems: exact file name -> svg (sorted by key).")
    w("const file_stems = [_]Entry{")
    for key, name in entries(stems_s):
        w(f"    .{{ .key = {zig_str(key)}, .svg = {name} }},")
    w("};")
    w("")

    w("// file_suffixes: suffix (may contain dots, e.g. \"d.ts\") -> svg (sorted by key).")
    w("const file_suffixes = [_]Entry{")
    for key, name in entries(suffixes_s):
        w(f"    .{{ .key = {zig_str(key)}, .svg = {name} }},")
    w("};")
    w("")

    w("// named_directory_icons: exact directory name -> variants (sorted by key).")
    w("const named_directories = [_]DirEntry{")
    for key, cl, ex in named_s:
        w(f"    .{{ .key = {zig_str(key)}, .collapsed = {c(cl)}, .expanded = {c(ex)} }},")
    w("};")
    w("")

    w("// directory_icons (default folder) and chevron_icons.")
    w(f"const directory_collapsed: []const u8 = {c(dir_collapsed)};")
    w(f"const directory_expanded: []const u8 = {c(dir_expanded)};")
    w(f"const chevron_collapsed: ?[]const u8 = {c(chev_collapsed)};")
    w(f"const chevron_expanded: ?[]const u8 = {c(chev_expanded)};")
    w("")
    w('/// The theme\'s "default" file icon (file_icons["default"]), or null if the theme has none.')
    w(f"pub const default_file: ?[]const u8 = {c(default_file)};")
    w("")

    w("const max_lower_name = 256;")
    w("")
    w("fn lookup(table: []const Entry, key: []const u8) ?[]const u8 {")
    w("    var lo: usize = 0;")
    w("    var hi: usize = table.len;")
    w("    while (lo < hi) {")
    w("        const mid = lo + (hi - lo) / 2;")
    w("        switch (std.mem.order(u8, table[mid].key, key)) {")
    w("            .lt => lo = mid + 1,")
    w("            .gt => hi = mid,")
    w("            .eq => return table[mid].svg,")
    w("        }")
    w("    }")
    w("    return null;")
    w("}")
    w("")
    w("fn findDirectory(name: []const u8) ?DirEntry {")
    w("    var lo: usize = 0;")
    w("    var hi: usize = named_directories.len;")
    w("    while (lo < hi) {")
    w("        const mid = lo + (hi - lo) / 2;")
    w("        switch (std.mem.order(u8, named_directories[mid].key, name)) {")
    w("            .lt => lo = mid + 1,")
    w("            .gt => hi = mid,")
    w("            .eq => return named_directories[mid],")
    w("        }")
    w("    }")
    w("    return null;")
    w("}")
    w("")
    w("/// Last path component, accepting both '/' and '\\\\' separators.")
    w("fn baseName(path: []const u8) []const u8 {")
    w("    var i = path.len;")
    w("    while (i > 0) : (i -= 1) {")
    w("        const ch = path[i - 1];")
    w("        if (ch == '/' or ch == '\\\\') return path[i..];")
    w("    }")
    w("    return path;")
    w("}")
    w("")
    w("/// Longest-suffix match: the whole name first, then each suffix after a '.' (left to right).")
    w("fn matchSuffix(name: []const u8) ?[]const u8 {")
    w("    if (lookup(&file_suffixes, name)) |svg| return svg;")
    w("    var rest = name;")
    w("    while (std.mem.indexOfScalar(u8, rest, '.')) |dot| {")
    w("        rest = rest[dot + 1 ..];")
    w("        if (rest.len == 0) break;")
    w("        if (lookup(&file_suffixes, rest)) |svg| return svg;")
    w("    }")
    w("    return null;")
    w("}")
    w("")
    w("/// Resolve a file icon for a path or bare file name. Order: exact file_stems entry,")
    w("/// longest file_suffixes match (case-sensitive), then the same suffix match on the")
    w("/// lowercased name. Returns null when nothing matches.")
    w("pub fn fileIcon(path: []const u8) ?[]const u8 {")
    w("    const name = baseName(path);")
    w("    if (name.len == 0) return null;")
    w("    if (lookup(&file_stems, name)) |svg| return svg;")
    w("    if (matchSuffix(name)) |svg| return svg;")
    w("    var buf: [max_lower_name]u8 = undefined;")
    w("    if (name.len > buf.len) return null;")
    w("    const lower = std.ascii.lowerString(&buf, name);")
    w("    if (std.mem.eql(u8, lower, name)) return null;")
    w("    return matchSuffix(lower);")
    w("}")
    w("")
    w("/// Icon for a directory by exact name (named_directory_icons), falling back to the")
    w("/// default folder icon (directory_icons) for the requested variant.")
    w("pub fn directoryIcon(name: []const u8, expanded: bool) []const u8 {")
    w("    if (findDirectory(name)) |d| {")
    w("        if (expanded) {")
    w("            if (d.expanded) |svg| return svg;")
    w("        } else {")
    w("            if (d.collapsed) |svg| return svg;")
    w("        }")
    w("    }")
    w("    return if (expanded) directory_expanded else directory_collapsed;")
    w("}")
    w("")
    w("/// Disclosure chevron. The upstream theme ships none, so this is null for now.")
    w("pub fn chevronIcon(expanded: bool) ?[]const u8 {")
    w("    return if (expanded) chevron_expanded else chevron_collapsed;")
    w("}")
    w("")
    w('test "fileIcon resolves common names" {')
    w('    try std.testing.expect(fileIcon("build.zig") != null);')
    w('    try std.testing.expect(fileIcon("main.zig") != null);')
    w('    try std.testing.expect(fileIcon("README.md") != null);')
    w('    try std.testing.expect(fileIcon("src/app/main.zig") != null);')
    w("}")
    w("")
    w('test "fileIcon returns null for an unknown extension" {')
    w('    try std.testing.expect(fileIcon("notes.zidnonsense") == null);')
    w("}")
    w("")
    w('test "directoryIcon falls back to the default folder" {')
    w('    try std.testing.expect(directoryIcon("src", false).len > 0);')
    w('    try std.testing.expect(directoryIcon("src", true).len > 0);')
    w('    try std.testing.expect(directoryIcon("no-such-directory-name", true).len > 0);')
    w("}")
    w("")
    w('test "display name has no parenthesised suffix" {')
    w("    try std.testing.expect(std.mem.indexOfScalar(u8, display_name, '(') == null);")
    w('    try std.testing.expectEqualStrings("Catppuccin Latte", display_name);')
    w("    try std.testing.expectEqual(Appearance.light, appearance);")
    w("}")
    w("")
    w('test "chevronIcon is null (upstream ships none)" {')
    w("    try std.testing.expect(chevronIcon(false) == null);")
    w("    try std.testing.expect(chevronIcon(true) == null);")
    w("}")

    text = "\n".join(L) + "\n"
    with OUT.open("wb") as f:
        f.write(text.encode("utf-8"))

    print(
        f"gen_icon_theme: wrote {os.path.relpath(OUT, REPO)}: "
        f"{len(const_of)} SVGs embedded, {len(stems_s)} file_stems, "
        f"{len(suffixes_s)} file_suffixes, {len(named_s)} named directories"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
