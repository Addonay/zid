const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zafi = b.dependency("zafi", .{ .target = target, .optimize = optimize });
    const sdl = b.dependency("sdl3", .{ .target = target, .optimize = optimize });
    patchSdl(b, sdl);
    const core = b.addModule("zid", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    core.addImport("tree_sitter", treeSitterModule(b, target, optimize));
    const app = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true, .strip = (optimize == .debug) });
    app.addImport("zid", core);
    app.addImport("sdl3", sdl.module("sdl3"));
    app.addImport("zafi", zafi.module("zafi"));
    app.addAnonymousImport("assets", .{ .root_source_file = b.path("assets/fonts.zig") });
    app.addAnonymousImport("icons", .{ .root_source_file = b.path("assets/icons.zig") });
    app.linkSystemLibrary("freetype2", .{});
    app.linkSystemLibrary("harfbuzz", .{});
    // nanosvg casts dx/dy of near-horizontal edges to int (upstream behaviour);
    // Debug UBSan would trap on harmless overflow while rasterizing Zed icons.
    app.addCSourceFile(.{ .file = b.path("src/platform/font.c"), .flags = &.{ "-std=c23", "-fno-sanitize=float-cast-overflow" } });
    app.linkSystemLibrary("m", .{});
    app.addAnonymousImport("theme_assets", .{ .root_source_file = b.path("assets/themes.zig") });
    app.addAnonymousImport("settings_assets", .{ .root_source_file = b.path("assets/settings.zig") });
    app.addAnonymousImport("keymap_assets", .{ .root_source_file = b.path("assets/keymaps.zig") });
    app.addAnonymousImport("icon_theme_assets", .{ .root_source_file = b.path("assets/icon_themes/catppuccin_latte.zig") });

    const name = switch (optimize) {
        .debug => "zid",
        .fast => "zid-fast",
        .safe => "zid-safe",
        .small => "zid-small"
    };

    const exe = b.addExecutable(.{ .name = name, .root_module = app });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Zid (optional file or directory)").dependOn(&run.step);
    b.step("test", "Test editing, history, UTF-8 and line indexing").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core })).step);
    const layout_tests = b.createModule(.{ .root_source_file = b.path("src/platform/layout_check.zig"), .target = target, .optimize = optimize });
    layout_tests.addImport("zafi", zafi.module("zafi"));
    b.step("test-layout", "Test Zafi sizing and invalidation").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = layout_tests })).step);
    b.step("check", "Compile the full app without launching").dependOn(&exe.step);
    layout_tests.addImport("zid", core);
    const ui_tests = b.createModule(.{ .root_source_file = b.path("src/app/tests.zig"), .target = target, .optimize = optimize });
    ui_tests.addImport("zafi", zafi.module("zafi"));
    ui_tests.addImport("zid", core);
    ui_tests.addAnonymousImport("icons", .{ .root_source_file = b.path("assets/icons.zig") });
    b.step("test-ui", "Test shell layout and configuration").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ui_tests })).step);
    ui_tests.addAnonymousImport("theme_assets", .{ .root_source_file = b.path("assets/themes.zig") });
    ui_tests.addAnonymousImport("settings_assets", .{ .root_source_file = b.path("assets/settings.zig") });
    ui_tests.addAnonymousImport("keymap_assets", .{ .root_source_file = b.path("assets/keymaps.zig") });
    ui_tests.addAnonymousImport("icon_theme_assets", .{ .root_source_file = b.path("assets/icon_themes/catppuccin_latte.zig") });
    const smoke = b.addRunArtifact(exe);
    smoke.addArg("--check");
    b.step("smoke", "Headless SDL3, FreeType, HarfBuzz and Zafi integration check").dependOn(&smoke.step);
}

/// Resolve a pinned dependency's extracted path without running its build.zig.
/// `b.dependency()` and `std.Build.package_map` both evaluate the dep's own
/// build file; upstream tree-sitter ships one written for another Zig version,
/// so the path is mirrored from the generated dependencies table instead:
/// every package is extracted to `zig-pkg/<multihash>`.
fn depRoot(b: *std.Build, name: []const u8) []const u8 {
    for (b.available_deps) |dep| {
        if (std.mem.eql(u8, dep[0], name)) {
            // Tarballs extract one top-level directory inside zig-pkg/<hash>.
            const pkg_dir = b.pathJoin(&.{ "zig-pkg", dep[1] });
            var dir = std.Io.Dir.cwd().openDir(b.graph.io, pkg_dir, .{ .iterate = true }) catch |err|
                std.process.fatal("open {s}: {s}", .{ pkg_dir, @errorName(err) });
            defer dir.close(b.graph.io);
            var it = dir.iterate();
            const entry = it.next(b.graph.io) catch @panic("iterate failed") orelse
                std.process.fatal("{s} is empty", .{pkg_dir});
            return b.pathJoin(&.{ pkg_dir, entry.name });
        }
    }
    std.process.fatal("unknown dependency '{s}'", .{name});
}

/// Build the pinned tree-sitter runtime library plus every grammar zid
/// highlights, and embed each grammar's upstream `queries/highlights.scm` as a
/// generated Zig module so the queries track the pinned grammar versions.
/// Mirrors Zed's `grammars` crate: grammars are C sources, queries are data.
fn treeSitterModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const ts = b.createModule(.{
        .root_source_file = b.path("src/syntax/tree_sitter.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ts_root = depRoot(b, "tree_sitter");
    // The crates.io tarball roots the C library at src/ and headers at include/.
    // POSIX + default-source feature macros expose fdopen and le16toh/be16toh.
    ts.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ts_root, "include" }) });
    ts.addCSourceFile(.{
        .file = .{ .cwd_relative = b.pathJoin(&.{ ts_root, "src/lib.c" }) },
        .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE" },
    });

    // Zig 0.17: api.h is translated with the official translate-c package
    // (b.addTranslateC is deprecated); tree_sitter.zig wraps the "ts_api" module.
    const translator: @import("translate_c").Translator = .init(b.dependency("translate_c", .{}), .{
        .name = "ts_api",
        .c_source_file = b.addWriteFiles().add("ts_api.h", "#include <tree_sitter/api.h>\n"),
        .target = target,
        .optimize = optimize,
    });
    translator.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ts_root, "include" }) });
    ts.addImport("ts_api", translator.mod);

    const Query = struct { name: []const u8, file: []const u8 };
    const Grammar = struct {
        dep: []const u8, // dependency name in build.zig.zon
        dir: []const u8 = "", // grammar root within the package
        sources: []const []const u8, // C files relative to `dir`
        queries: []const Query = &.{}, // embedded query files relative to `dir`
    };
    const grammars = [_]Grammar{
        .{ .dep = "ts_zig", .sources = &.{"src/parser.c"}, .queries = &.{ .{ .name = "zig", .file = "queries/highlights.scm" } } },
        .{ .dep = "ts_c", .sources = &.{"src/parser.c"}, .queries = &.{ .{ .name = "c", .file = "queries/highlights.scm" } } },
        .{ .dep = "ts_cpp", .sources = &.{ "src/parser.c", "src/scanner.c" }, .queries = &.{ .{ .name = "cpp", .file = "queries/highlights.scm" } } },
        .{ .dep = "ts_python", .sources = &.{ "src/parser.c", "src/scanner.c" }, .queries = &.{ .{ .name = "python", .file = "queries/highlights.scm" } } },
        // tree-sitter-sql ships no generated parser.c; sql keeps the hand lexer.
        .{ .dep = "ts_json", .sources = &.{"src/parser.c"}, .queries = &.{ .{ .name = "json", .file = "queries/highlights.scm" } } },
        .{ .dep = "ts_markdown", .dir = "tree-sitter-markdown", .sources = &.{ "src/parser.c", "src/scanner.c" }, .queries = &.{ .{ .name = "markdown", .file = "queries/highlights.scm" } } },
        .{ .dep = "ts_markdown", .dir = "tree-sitter-markdown-inline", .sources = &.{ "src/parser.c", "src/scanner.c" }, .queries = &.{ .{ .name = "markdown_inline", .file = "queries/highlights.scm" } } },
    };

    var generated = std.ArrayList(u8).empty;
    generated.appendSlice(b.allocator, "// generated by build.zig: upstream grammar queries, pinned by build.zig.zon\n") catch @panic("OOM");
    for (grammars) |g| {
        const dep_root = depRoot(b, g.dep);
        for (g.sources) |src| {
            const rel = if (g.dir.len == 0) src else b.fmt("{s}/{s}", .{ g.dir, src });
            ts.addCSourceFile(.{ .file = .{ .cwd_relative = b.pathJoin(&.{ dep_root, rel }) }, .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE" } });
        }
        const inc = if (g.dir.len == 0) "src" else b.fmt("{s}/src", .{g.dir});
        ts.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dep_root, inc }) });
        for (g.queries) |query| {
            const rel = if (g.dir.len == 0) query.file else b.fmt("{s}/{s}", .{ g.dir, query.file });
            const path = b.pathJoin(&.{ dep_root, rel });
            const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 20)) catch |err|
                std.process.fatal("read {s}:{s}: {s}", .{ g.dep, rel, @errorName(err) });
            const head = std.fmt.allocPrint(b.allocator, "pub const {s}: [:0]const u8 = \"", .{query.name}) catch @panic("OOM");
            generated.appendSlice(b.allocator, head) catch @panic("OOM");
            for (text) |c| {
                const esc: []const u8 = switch (c) {
                    '\\' => "\\\\",
                    '"' => "\\\"",
                    '\n' => "\\n",
                    '\r' => "\\r",
                    '\t' => "\\t",
                    else => "",
                };
                if (esc.len != 0) {
                    generated.appendSlice(b.allocator, esc) catch @panic("OOM");
                } else {
                    generated.append(b.allocator, c) catch @panic("OOM");
                }
            }
            generated.appendSlice(b.allocator, "\";\n") catch @panic("OOM");
        }
    }
    const queries_file = b.addWriteFiles().add("ts_queries.zig", generated.items);
    ts.addAnonymousImport("ts_queries", .{ .root_source_file = queries_file });
    return ts;
}

/// Apply the transparency fix to SDL's dependency-built C sources without
/// modifying the package cache or the typed zig-sdl3 bindings.
fn patchSdl(b: *std.Build, sdl3: *std.Build.Dependency) void {
    var found: ?*std.Build.Step.Compile = null;
    for (sdl3.builder.install_tls.step.dependencies.items) |dep| {
        const install = dep.cast(std.Build.Step.InstallArtifact) orelse continue;
        if (std.mem.eql(u8, install.artifact.name, "SDL3")) found = install.artifact;
    }
    const lib = found orelse std.process.fatal("patchSdl: no dependency-built SDL3 artifact", .{});
    var sdl_root: ?std.Build.LazyPath = null;
    for (lib.root_module.link_objects.items) |obj| switch (obj) {
        .c_source_files => |csf| if (std.mem.eql(u8, csf.files[0], "src/SDL.c")) {
            sdl_root = csf.root;
        },
        else => {},
    };
    const root = sdl_root orelse std.process.fatal("patchSdl: SDL's C sources were not found", .{});
    const patched = b.dependency("patch", .{
        .source = root,
        .patches = &[_]std.Build.LazyPath{b.path("patch/sdl-gpu-vulkan-transparent.patch")},
    }).namedLazyPath("patched");
    const owner = root.src_path.owner;
    for (lib.root_module.link_objects.items) |*obj| switch (obj.*) {
        .c_source_files => |csf| if (csf.root == .src_path and csf.root.src_path.owner == owner) {
            csf.root = patched.path(b, csf.root.src_path.sub_path);
        },
        .c_source_file => |csf| if (csf.file == .src_path and csf.file.src_path.owner == owner) {
            csf.file = patched.path(b, csf.file.src_path.sub_path);
        },
        else => {},
    };
}
