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
    if (args.len == 2 and std.mem.eql(u8, args[1], "--check")) {
        try smoke.check(init.gpa);
        std.debug.print("OK: headless SDL3, FreeType, HarfBuzz and Zafi integration\n", .{});
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Zid\n  zid [file-or-directory]  Open editor\n  zid --check              Headless dependency smoke check\n\nCtrl+O open · Ctrl+S save · Ctrl+N new · Ctrl+W close · Ctrl+B project panel\n", .{});
        return;
    }
    if (args.len > 2 or (args.len == 2 and std.mem.startsWith(u8, args[1], "--"))) return error.InvalidArguments;
    const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd);
    const path = try std.fs.path.resolve(init.gpa, &.{ cwd, if (args.len == 2) args[1] else "." });
    defer init.gpa.free(path);
    const stat = try std.Io.Dir.cwd().statFile(init.io, path, .{});
    var workspace = try zid.Workspace.init(init.gpa, init.io, if (stat.kind == .directory) path else std.fs.path.dirname(path) orelse cwd);
    defer workspace.deinit();
    try workspace.scan();
    if (stat.kind == .file) try workspace.open(path) else if (stat.kind != .directory) return error.NotRegularFile;
    if (workspace.documents.items.len == 0) try workspace.newDocument();
    var app = try App.init(init.gpa, init.io, &workspace, init.environ_map);
    defer app.deinit();
    try app.run();
}
