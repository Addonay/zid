const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zafi = b.dependency("zafi", .{ .target = target, .optimize = optimize });
    const sdl = b.dependency("sdl3", .{ .target = target, .optimize = optimize });
    patchSdl(b, sdl);
    const core = b.addModule("zid", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
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
