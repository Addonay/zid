# Original bundled theme sources

Theme JSON files in this directory are the upstream Zed family bundles, kept
byte-for-byte in their original schema. assets/themes.zig embeds their bytes
and associates each Zid ThemeName with the exact upstream entry selector.
tools/import_themes.py validates JSON and copies bytes without reformatting
or converting palette data.

| Bundle | Upstream URL | Pinned revision | Selected entry |
| --- | --- | --- | --- |
| one.json | [zed-industries/zed](https://github.com/zed-industries/zed/blob/ba63a022c9a22ca66d68ef2a8f0bb9b5b0a9984d/assets/themes/one/one.json) | ba63a022c9a22ca66d68ef2a8f0bb9b5b0a9984d | One Dark |
| one-dark-pro-glass.json | [kussumma/one-dark-pro-max](https://github.com/kussumma/one-dark-pro-max/blob/34f3949c22806a416700b3548066df04f8692f29/themes/one-dark-pro-glass.json) | 34f3949c22806a416700b3548066df04f8692f29 | One Dark Pro Glass |
| ayu.json | [zed-industries/zed](https://github.com/zed-industries/zed/blob/ba63a022c9a22ca66d68ef2a8f0bb9b5b0a9984d/assets/themes/ayu/ayu.json) | ba63a022c9a22ca66d68ef2a8f0bb9b5b0a9984d | Ayu Dark |
| gruvbox.json | [zed-industries/zed](https://github.com/zed-industries/zed/blob/ba63a022c9a22ca66d68ef2a8f0bb9b5b0a9984d/assets/themes/gruvbox/gruvbox.json) | ba63a022c9a22ca66d68ef2a8f0bb9b5b0a9984d | Gruvbox Dark |
| solarized-dark.json | [alanisme/vscode-themes-for-zed](https://github.com/alanisme/vscode-themes-for-zed/blob/9bda62bbd33f417284e4b1550bf6d5f2ff5a224a/themes/solarized-dark.json) | 9bda62bbd33f417284e4b1550bf6d5f2ff5a224a | Solarized Dark (VS Code) |
| tokyo-night.json | [ssaunderss/zed-tokyo-night](https://github.com/ssaunderss/zed-tokyo-night/blob/a4ef7dd64e146434d4ac289b59abe17ff98ba680/themes/tokyo-night.json) | a4ef7dd64e146434d4ac289b59abe17ff98ba680 | Tokyo Night |
| catppuccin-mauve.json | [catppuccin/zed](https://github.com/catppuccin/zed/blob/4314cb05c74d141b7962290a41d6087e8c0ad02f/themes/catppuccin-mauve.json) | 4314cb05c74d141b7962290a41d6087e8c0ad02f | Catppuccin Mocha |
| dark-modern.json | [alanisme/vscode-themes-for-zed](https://github.com/alanisme/vscode-themes-for-zed/blob/9bda62bbd33f417284e4b1550bf6d5f2ff5a224a/themes/dark-modern.json) | 9bda62bbd33f417284e4b1550bf6d5f2ff5a224a | Dark Modern (VS Code) |

## Other bundled assets

- Default One Dark, Ayu, and Gruvbox files came from .ref/zed at revision
  ba63a022c9a22ca66d68ef2a8f0bb9b5b0a9984d.
- assets/icons/file_icons/ contains Zed's complete default file-icon SVG
  directory from the same revision; mappings follow
  crates/theme/src/icon_theme.rs.
- Lilex regular/italic and IBM Plex Sans regular/italic/semibold faces came
  from that revision's assets/fonts/lilex and assets/fonts/ibm-plex-sans.
- Font and theme license texts are retained beside the assets.

.ref/zed is only the local source reference. Runtime embeds these copied
assets and never reads the reference checkout or Zed configuration.
