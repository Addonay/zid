# Icon themes

Alternative file-icon themes bundled for Zid. The default icon set remains
Zed Default (`assets/icons.zig`, `assets/icons/`); nothing here replaces it.

## Catppuccin Latte (`catppuccin-latte/`)

| Item | Value |
| --- | --- |
| Local source | `~/.local/share/zed/extensions/installed/catppuccin-zig-icons/` (symlink to `~/.config/zed/extensions/catppuccin-zig-icons/`) |
| Local extension | "Catppuccin Zig Icons", version 0.0.1 (`extension.toml`): Catppuccin Latte with dedicated Zig build and package icons |
| Upstream | <https://github.com/catppuccin/zed-icons> (MIT) |
| Theme in JSON | `Catppuccin Latte (Zig Build Icons)`, appearance `light` |
| Display name in Zid | `Catppuccin Latte` (set in Zig, see below) |
| License | MIT, copied to [`catppuccin-latte/LICENSE`](catppuccin-latte/LICENSE) from the upstream repository `main` branch |

### Contents

- `catppuccin-latte/catppuccin-zig-icons.json`: the theme file, byte-identical to the
  local extension's `icon_themes/catppuccin-zig-icons.json`.
- `catppuccin-latte/icons/latte/`: 658 colored SVGs, byte-identical to the local
  extension's `icons/latte/`. Paths in the JSON (`./icons/latte/x.svg`) resolve
  relative to `catppuccin-latte/`.
- `catppuccin-latte/extension.toml`: copied from the local extension for provenance.
- `catppuccin-latte/LICENSE`: upstream MIT license text.
- `catppuccin_latte.zig`: **generated** Zig module (do not edit by hand). It embeds
  each referenced SVG once with `@embedFile` and exposes `fileIcon`, `directoryIcon`,
  `chevronIcon`, `default_file`, `display_name` and `appearance`.

### Differences from the source

- **Display name.** The JSON name carries a `(Zig Build Icons)` suffix. The JSON is
  not edited; the generator sets `display_name = "Catppuccin Latte"`.
- **Unreferenced SVGs.** The JSON maps 629 distinct SVG paths, but 624 are referenced
  by file stems, file suffixes, named directories or the default folder. The five
  unreferenced files are not embedded. They remain in `icons/latte/` as shipped.
- **Chevrons and default file icon.** The upstream theme defines no chevron icons and
  no `default` file icon, so `chevronIcon` returns `null` and `default_file` is `null`.

## Regenerating

From the repository root:

```sh
python3 scripts/gen_icon_theme.py
zig test assets/icon_themes/catppuccin_latte.zig
```

The generator (stdlib Python only) reads
`catppuccin-latte/catppuccin-zig-icons.json`, skips and warns about any entry whose SVG
is missing, and writes `catppuccin_latte.zig` deterministically. Re-run it whenever the
bundle changes. Do not hand-edit the generated file.

## Updating the bundle

Re-copy from the local extension, then re-run the generator:

```sh
SRC=$(readlink -f ~/.local/share/zed/extensions/installed/catppuccin-zig-icons)
DST=assets/icon_themes/catppuccin-latte
cp "$SRC/icon_themes/catppuccin-zig-icons.json" "$DST/"
cp "$SRC/extension.toml" "$DST/"
rm -rf "$DST/icons" && cp -r "$SRC/icons" "$DST/"
diff -r "$SRC/icons" "$DST/icons" && python3 scripts/gen_icon_theme.py
```

Keep the upstream LICENSE in `catppuccin-latte/` with the bundle.
