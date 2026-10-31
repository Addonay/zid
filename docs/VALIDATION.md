# M1 validation — 2026-10-31

Compiler: Zig 0.17.0. Normal Debug builds; no ReleaseFast substitution.

- `zig build test`: document/workspace tests, UTF-8/CRLF, saved-revision history,
  external changes, path collisions, dangling symlinks, no-replace save conflicts,
  creation permissions, rejected-delete state, lexer tests/fuzz span bounds,
  scanning, piece-tree snapshots and exhaustive allocation-failure cases pass.
- `zig build test-layout`: pinned upstream Zafi sizing and invalidation pass.
- `zig build test-ui`: shell geometry, JSONC parsing, settings/theme overrides,
  project collapse/allocation failures and original-schema theme tests pass.
- `zig build check`: complete application compiles.
- `zig build smoke`: SDL in-memory software renderer, bundled FreeType/HarfBuzz
  font and Zafi pass with no window and no display server requirement.
- `zig fmt --check src assets/*.zig build.zig build.zig.zon`: clean.

GUI QA used `zig build run` on a private Xvfb display and software Vulkan. No host
window was opened. Interaction fixtures were all under `/tmp/zid-qa`:

- Clipboard copy/cut/paste round trip preserved fixture bytes.
- An untitled document closed through Save → Save As, wrote the exact text, and
  returned to the preceding tab. The dialog's S text-input leakage was repaired.
- Right across CRLF followed by typing produced `one\r\nXtwo\r\n`.
- Undo/redo and saving preserved the expected edited file.
- Settings hot reload switched all eight builtin themes without restarting.
  Captured opaque editor pixels matched each source palette; Glass blended over
  the Xvfb background as expected. Default One Dark was restored afterward.
- Rounded-frame GPU readback in the renderer harness found alpha 0 at the corner,
  255 in the center and 172 on an antialiased corner edge.
- A separate GPU stress harness exceeded the content geometry budget, then drew a
  save/discard overlay using reserved capacity. Captured overlay pixel was exactly
  `(0, 200, 0)`; the application did not terminate or silently consume the overlay.
- The save regression suite was also run under `umask 077`.

[Default One Dark shell capture](screenshots/m1-one-dark.png).

These checks do not establish KWin compositor blur, every desktop caption theme,
full Unicode/IME behavior or the roadmap's performance/memory targets. Xvfb uses
software Vulkan and is not a representative native-driver performance benchmark.
The UI still uses the 32 MiB-capped gap buffer, and >64 KiB lines are read-only
truncated previews. Large-file/persistent-tree UI integration remains M2.
