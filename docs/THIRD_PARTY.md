# Third-party provenance

- **zig-sdl3**: `7Games/zig-sdl3`, commit
  `f0500f824ff2768a3cc0ece2918df56576dde11c`, URL/hash-pinned Zig package.
  Application SDL calls use its typed API; no raw C SDL namespace is used.
- **Zafi**: `Addonay/zafi`, commit `9062288c3c8cabfdf505a3d450dd56e4a2b66098`,
  URL/hash-pinned Zig package, never vendored. `zig-pkg/` is disposable.
- **SDL 3.4.18**: built statically from zig-sdl3's pinned transitive dependency.
  `patch/sdl-gpu-vulkan-transparent.patch` is the Vulkan transparency exception
  used by the user's chatƺpt reference project. The build applies it to a generated
  source copy through the pinned `zig-patch` dependency; upstream package files are
  not changed. See `build.zig` for the compile-source redirection.
- **FreeType and HarfBuzz**: system libraries; their C bridge in
  `src/platform/font.c` performs font opening, shaping and glyph rasterization.
  It makes no SDL calls. Zig owns SDL textures/GPU resources and drawing.
- **NanoSVG**: `src/gfx/c/nanosvg.h` and `nanosvgrast.h`, taken from the provided
  chatƺpt renderer's copies. Each header retains its upstream license notice.
  `font.c` also exposes the small SVG alpha-mask rasterization bridge.

## Fonts

Fonts are copied from the Zed reference checkout at revision
`ba63a022c9a22ca66d68ef2a8f0bb9b5b0a9984d`:

- Lilex Regular and Italic from `assets/fonts/lilex/`; SIL Open Font License in
  `assets/fonts/Lilex-OFL.txt` (the earlier `OFL.txt` copy is retained).
- IBM Plex Sans Regular, Italic, SemiBold and SemiBoldItalic from
  `assets/fonts/ibm-plex-sans/`; license in
  `assets/fonts/IBM-Plex-Sans-LICENSE.txt`.

The renderer currently uses regular Lilex, italic Lilex and regular IBM Plex Sans.
Other weights are retained as upstream assets for subsequent style support.

## Icons

`assets/icons.zig` embeds Zed Default file icons and UI SVGs. File associations
come from the reference default icon theme, not the installed Catppuccin theme.
The reference icon license notices are retained beside the assets. Some internal
names alias the corresponding original Zed SVG (for example `panel_left` uses the
reference's sidebar icon). SVG file bytes are not redrawn or replaced with text.

Native caption icons are resolved at runtime from the desktop icon theme using
`src/platform/caption_icons/icon_theme.zig`, following the user's chatƺpt project.
The Breeze/Adwaita caption spacing and background treatments are adapted from that
project. A small SVG fallback is used when the desktop theme has no caption glyph.

## Themes

Original, unmodified upstream Zed theme-family JSON is stored in `assets/themes/`
and embedded by `assets/themes.zig`. `src/app/theme.zig` adapts the existing
`themes/style/syntax` schema at runtime. It does not generate replacement palettes.

Full source URLs, immutable revisions, selected entries and licenses are recorded
in [assets/themes/README.md](../assets/themes/README.md). The bundles include One,
One Dark Pro Glass, Ayu, Gruvbox, Solarized Dark, Tokyo Night, Catppuccin and VS Code
Dark Modern. Importing theme assets does not make the Zed checkout a source or
runtime dependency.
