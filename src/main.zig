const std = @import("std");
const zid = @import("zid");
const smoke = @import("platform/smoke.zig");
const logging = @import("core/log.zig");
pub const std_options: std.Options = .{ .logFn = logging.logFn, .log_level = .debug };
const App = @import("app/app.zig").App;

pub fn main(init: std.process.Init) !void {
    logging.init(init.gpa, init.io, init.environ_map) catch |err| std.debug.print("Log file unavailable: {s}\n", .{@errorName(err)});
    defer logging.deinit();
    std.log.info("Zid startup (Zig {s})", .{@import("builtin").zig_version_string});
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const png = @import("util/png.zig");
    var screenshot_path: ?[]const u8 = null;
    var win_w: usize = 1200;
    var win_h: usize = 800;
    var target_frames: u32 = 3;
    var target_path: ?[]const u8 = null;
    var open_settings: ?usize = null;
    var forced_scale: ?f32 = null;
    var keys: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "--check")) {
            try smoke.check(init.gpa);
            std.debug.print("OK: headless SDL3, FreeType, HarfBuzz and Zafi integration\n", .{});
            return;
        } else if (std.mem.eql(u8, s, "--help")) {
            std.debug.print("Zid\n  zid [file-or-directory]  Open editor\n  zid --check              Headless dependency smoke check\n  zid --screenshot <path> [--size WxH] [--frames N] [--settings[=page]] [--scale F] [--keys KEYS]\n\nCtrl+O open · Ctrl+S save · Ctrl+N new · Ctrl+W close · Ctrl+B project panel\n", .{});
            return;
        } else if (std.mem.eql(u8, s, "--screenshot") and i + 1 < args.len) {
            i += 1;
            screenshot_path = args[i];
        } else if (std.mem.eql(u8, s, "--size") and i + 1 < args.len) {
            i += 1;
            var it = std.mem.splitScalar(u8, args[i], 'x');
            win_w = try std.fmt.parseInt(usize, it.next() orelse "1200", 10);
            win_h = try std.fmt.parseInt(usize, it.next() orelse "800", 10);
        } else if (std.mem.eql(u8, s, "--frames") and i + 1 < args.len) {
            i += 1;
            target_frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, s, "--keys") and i + 1 < args.len) {
            i += 1;
            keys = args[i];
        } else if (std.mem.eql(u8, s, "--scale") and i + 1 < args.len) {
            i += 1;
            forced_scale = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, s, "--settings")) {
            open_settings = 0;
        } else if (std.mem.startsWith(u8, s, "--settings=")) {
            open_settings = try std.fmt.parseInt(usize, s["--settings=".len..], 10);
        } else if (std.mem.startsWith(u8, s, "--")) {
            return error.InvalidArguments;
        } else {
            target_path = s;
        }
    }

    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    const path = try std.fs.path.resolve(init.gpa, &.{ cwd, target_path orelse "." });
    defer init.gpa.free(path);
    const stat = try std.Io.Dir.cwd().statFile(init.io, path, .{});
    var workspace = try zid.Workspace.init(init.gpa, init.io, if (stat.kind == .directory) path else std.fs.path.dirname(path) orelse cwd);
    defer workspace.deinit();
    try workspace.scan();
    if (stat.kind == .file) try workspace.open(path) else if (stat.kind != .directory) return error.NotRegularFile;
    if (workspace.documents.items.len == 0) try workspace.newDocument();
    var app = try App.initWithOptions(init.gpa, init.io, &workspace, init.environ_map, win_w, win_h, screenshot_path != null);
    defer app.deinit();

    app.forced_scale = forced_scale;
    if (open_settings) |page| {
        try app.runCommand(.@"zed::OpenSettings");
        app.settings_category = page;
    }
    if (keys) |spec| {
        try app.draw(); // establish layout before replaying keys
        try @import("app/input/events.zig").simulate(&app, spec);
    }
    if (screenshot_path) |shot_path| {
        var frame: u32 = 0;
        while (frame < target_frames) : (frame += 1) {
            try app.draw();
        }
        const shot = try app.renderer.readPixels(init.gpa);
        defer init.gpa.free(shot.data);
        const bytes = try png.encode(init.gpa, shot.w, shot.h, shot.data);
        defer init.gpa.free(bytes);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = shot_path, .data = bytes });
        std.log.info("wrote {s} ({d}x{d})", .{ shot_path, shot.w, shot.h });
        return;
    }

    try app.run();
}
