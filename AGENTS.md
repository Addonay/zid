# Zid project constraints

- The UI is enabled (2026-10-31): a Zed-style shell (title bar, project panel, tabs, status bar) built on SDL_GPU + Zafi. AI features remain deferred. See docs/ROADMAP.md.
- Zafi is always an upstream URL/hash-pinned Zig package dependency. Never vendor or copy its source into this repository. `zig-pkg/` is an ignored, disposable package cache.
- Keep `src/core/`, `src/text/`, `src/editor/`, `src/syntax/` independent of SDL, Zafi and rendering. Pass `std.Io` explicitly to file operations.
- `.ref/zed/` is a reference checkout, not a source dependency or an edit target.
- Use Zig 0.17.0 APIs. Verify the actual compiler before changing build or I/O integration.
- Validate changes with the relevant `zig build test`, `test-layout`, `check`, and `smoke` steps. The smoke step is headless and must not open a host window.
- Be explicit about incomplete features and large-file/Unicode limits. Passing layout tests is not proof of a complete editor.
- Default UI theme, icons and fonts match Zed's built-in defaults (One Dark, Zed Default icons, IBM Plex Sans UI and Lilex editor). Bundle One Dark Pro Glass and the other requested themes as alternatives using their original upstream JSON schema. Never read Zed config at runtime.
- Use typed zig-sdl3 APIs directly. Do not use `@import("sdl3").c` or hand-written SDL C calls. C bridges are limited to native font/SVG libraries.
- Native caption icons and rounded window corners follow `/home/addo/dev/stupid/chatƺpt`.
- Use Terra 6.1 with xhigh reasoning for delegated complex work; use Luna 6 for simpler tasks.
- Keep upstream theme JSON byte-for-byte; decode the Zed schema instead of generating replacement palettes.
- Consult `.ref/zed` for architecture and behavior; record adopted decisions in docs/REFERENCE_NOTES.md.
- Keep module boundaries in docs/STRUCTURE.md as the app grows.
- Run the app with `zig build run`; use `-Doptimize=ReleaseFast` only for occasional perf checks.
