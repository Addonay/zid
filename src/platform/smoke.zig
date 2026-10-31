const std = @import("std");
const sdl = @import("sdl3");
const Font = @import("font.zig").Font;
const layout = @import("layout_check.zig");
pub fn check(allocator: std.mem.Allocator) !void {
    try layout.check(allocator);
    // Software rendering needs no display server and never opens a host window.
    try sdl.init(.{});
    defer sdl.shutdown();

    const surface = try sdl.surface.Surface.init(640, 160, sdl.pixels.Format.array_rgba_32);
    defer surface.deinit();
    const renderer = try sdl.render.Renderer.initSoftwareRenderer(surface);
    defer renderer.deinit();
    const font = try Font.init(renderer, 18);
    defer font.deinit();
    try renderer.setDrawColor(.{ .r = 24, .g = 26, .b = 31, .a = 255 });
    try renderer.clear();
    try font.draw("Zid dependency smoke test", 24, 40, .{ 220, 224, 232 });
    try font.draw("UTF-8: café — Ελληνικά", 24, 74, .{ 130, 180, 250 });
    try font.draw("HarfBuzz + FreeType / SDL3 / Zafi", 24, 108, .{ 158, 168, 184 });
    const plain = font.width("editor");
    if (!std.math.isFinite(plain) or plain <= 0 or font.width("editor editor") <= plain) return error.TextMeasurementFailed;
    try renderer.present();
}
