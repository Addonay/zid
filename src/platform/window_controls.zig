//! Desktop caption glyphs, resolved through the GTK icon theme like the
//! reference UI. The owning shell supplies the home path and explicit Io.
const std = @import("std");
const theme = @import("caption_icons/icon_theme.zig");
const Renderer = @import("../gfx/renderer.zig").Renderer;

pub const Kind = enum(u8) { minimize, maximize, restore, close };
pub const WindowControls = struct {
    allocator: std.mem.Allocator,
    glyphs: [4]?[]const u8 = @splat(null),
    breeze: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, home: []const u8) WindowControls {
        var result: WindowControls = .{ .allocator = allocator };
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const desktop = theme.desktop(a, io, home);
        result.breeze = desktop.breeze();
        const names = [_][]const u8{ "window-minimize-symbolic", "window-maximize-symbolic", "window-restore-symbolic", "window-close-symbolic" };
        for (names, 0..) |name, i| {
            const path = theme.find(a, io, home, desktop.icon_theme, name, 16) orelse continue;
            result.glyphs[i] = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 10)) catch null;
        }
        return result;
    }
    pub fn deinit(self: *WindowControls) void {
        for (self.glyphs) |maybe| if (maybe) |glyph| self.allocator.free(glyph);
        self.* = undefined;
    }
    pub fn draw(self: *const WindowControls, renderer: *Renderer, kind: Kind, x: f32, y: f32, size: f32, color: [4]u8) !void {
        if (self.glyphs[@backingInt(kind)]) |glyph| return renderer.icon(glyph, x, y, size, color);
        const fallback = switch (kind) {
            .minimize => "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round'><path d='M5 12h14'/></svg>",
            .maximize => "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2'><rect x='3' y='3' width='18' height='18' rx='2'/></svg>",
            .restore => "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='8' y='8' width='14' height='14' rx='2'/><path d='M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2'/></svg>",
            .close => "<svg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24' fill='none' stroke='black' stroke-width='2' stroke-linecap='round'><path d='M18 6 6 18M6 6l12 12'/></svg>",
        };
        return renderer.icon(fallback, x + size * 0.15, y + size * 0.15, size * 0.7, color);
    }
};
