# Zid

A native Zig editor with a Zed-style shell. The first UI milestone has a project
panel, document tabs, editing, clipboard, undo/redo, syntax highlighting, a status
bar, and native caption controls. AI remains deferred.

Requires Zig **0.17.0**, `pkg-config`, FreeType and HarfBuzz development packages.
SDL3 and Zafi are URL/hash-pinned Zig packages. SDL3 is built from its pinned source
with the Vulkan transparency patch used by the reference chatƺpt application;
normal builds do not use the system SDL library. Zafi is never vendored.

```sh
zig build run
zig build run -- path/to/project
zig build run -- path/to/file.zig

zig build test
zig build test-layout
zig build test-ui
zig build check
zig build smoke
```

`smoke` uses an in-memory SDL software surface, shapes and rasterizes the bundled
font, and exercises Zafi. It never opens a window or requires a display server.
`check` compiles the full application. GUI testing is separate from these checks.
Use Debug normally; use `-Doptimize=ReleaseFast` only for occasional measurements.

The default appearance uses Zed's One Dark theme, Zed Default SVG icons, IBM Plex
Sans for the UI and Lilex for code. Native caption glyphs follow the desktop icon
theme using the same resolver as chatƺpt. Window corners are 10 px when restored
and square when maximized. Compositor blur is not implemented.

Built-in alternatives: One Dark Pro Glass, Ayu Dark, Gruvbox Dark, Solarized Dark,
Tokyo Night, Catppuccin Mocha and VS Code Dark Modern. Their original JSON is bundled without schema conversion; source revisions and
licenses are recorded in [assets/themes/README.md](assets/themes/README.md).
Zid never reads Zed settings or extensions at runtime.

Settings live in `$XDG_CONFIG_HOME/zid/settings.json` (default
`~/.config/zid/settings.json`), with key overrides in `keymap.json`. Both accept
comments and trailing commas and reload after changes. Invalid configuration
retains the last valid settings. Font-size changes require a restart. Examples
are in [assets/settings](assets/settings).

```json
{
  "theme_name": "one_dark",
  "font_size": 15,
  "tab_size": 4,
  "theme": { "accent": [116, 173, 232, 255] }
}
```

Theme IDs: `one_dark`, `one_dark_pro_glass`, `ayu`, `gruvbox`, `solarized`,
`tokyo_night`, `catppuccin`, `vscode`. Explicit color overrides apply over the chosen
builtin palette.

| Shortcut | Action |
| --- | --- |
| Ctrl+O / Ctrl+N | Open a file by path / new document |
| Ctrl+S / Ctrl+Shift+S | Save / Save As |
| Ctrl+W / Ctrl+Q | Close tab / quit, with unsaved-change handling |
| Ctrl+Z / Ctrl+Shift+Z | Undo / redo |
| Ctrl+C / Ctrl+X / Ctrl+V | Copy / cut / paste |
| Ctrl+A | Select all |
| Ctrl+B | Toggle project panel |
| Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Ctrl+Shift+R | Reload configuration immediately |

Logs include elapsed time, level and scope on stderr and in
`$XDG_STATE_HOME/zid/zid.log` (default `~/.local/state/zid/zid.log`). The log rotates
at startup past 4 MiB. Set `ZID_LOG=files=debug,app=info` for scoped diagnostics.

Memory-backed documents use a persistent piece tree with shared undo roots.
Files above **32 MiB** open read-only through bounded positional reads and a
background indexing/viewport worker. No complete index is required before the
first view. Go-to-line also accepts `b<offset>` and percentages such as `50%`.
The viewer decodes UTF-8, tabs and CRLF; invalid/control bytes become replacement
characters. Long displayed lines are truncated with a marker. Keyboard byte
selections are highlighted; Copy runs asynchronously and rejects selections above
1 MiB, NUL bytes and invalid UTF-8 (including split codepoints). Mouse selection
and column-preserving vertical movement remain unfinished. Closing a large-file tab joins its worker and
can wait for outstanding filesystem I/O. The roadmap's full memory/latency targets
remain unproven.

Memory-backed files with lines over **64 KiB** remain read-only previews;
oversized edits are rejected before mutation. Project scanning is synchronous
and limited to **4,000 files / 12 levels**. Undo groups typing by word and retains
at most 1,000 entries; a byte budget and append-store compaction remain unfinished.

Editing is UTF-8 codepoint based. Grapheme-aware movement, bidi cursor mapping,
font fallback, full IME composition, wrapping, LSP, terminal, Git/diff, databases,
notebooks and SSH remain future milestones.
Highlighting uses incremental line lexers, not a full parser; see the lexer source
for each language's approximations. GPU glyph/icon caches and frame geometry are
bounded; unusual glyphs may be replaced by boxes, and dense content may be omitted
while caret/status/dialog capacity stays reserved.

Save refuses detected external changes and paths owned by another tab. Dangling
symlinks are rejected. New targets commit without replacement; existing targets
are rechecked before atomic replacement. An external writer can still race the
last identity check and rename; there is no atomic compare-and-replace guarantee.

See [module boundaries](docs/STRUCTURE.md), [architecture](docs/ARCHITECTURE.md),
[roadmap](docs/ROADMAP.md), and [provenance](docs/THIRD_PARTY.md).
