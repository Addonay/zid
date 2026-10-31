//! FreeType/HarfBuzz bridge and typed SDL software renderer adapter.
const std = @import("std");
const sdl = @import("sdl3");
const assets = @import("assets");
const Handle = opaque {};
const Position = extern struct { index: u32, x_advance: i32, y_advance: i32, x_offset: i32, y_offset: i32 };
pub const Bitmap = extern struct { pixels: ?[*]const u8, width: c_int, height: c_int, pitch: c_int, left: c_int, top: c_int, gray: c_int };
extern fn zid_font_open([*]const u8, usize, c_uint) ?*Handle;
extern fn zid_font_close(*Handle) void;
extern fn zid_font_space(*Handle) f32;
extern fn zid_font_shape(*Handle, [*]const u8, usize) c_int;
extern fn zid_font_count(*Handle) c_uint;
extern fn zid_font_position(*Handle, c_uint) Position;
extern fn zid_font_bitmap(*Handle, c_uint, *Bitmap) c_int;
pub const Face = struct {
    handle: *Handle,
    pub fn init(pixels: u32) !Face {
        return initBytes(assets.mono, pixels);
    }
    pub fn initBytes(data: []const u8, pixels: u32) !Face {
        return .{ .handle = zid_font_open(data.ptr, data.len, pixels) orelse return error.FontInitializationFailed };
    }
    pub fn deinit(self: Face) void {
        zid_font_close(self.handle);
    }
    pub fn space(self: Face) f32 {
        return zid_font_space(self.handle);
    }
    pub fn shape(self: Face, text: []const u8) !void {
        if (zid_font_shape(self.handle, text.ptr, text.len) == 0) return error.ShapeFailed;
    }
    pub fn count(self: Face) u32 {
        return zid_font_count(self.handle);
    }
    pub fn position(self: Face, i: u32) Position {
        return zid_font_position(self.handle, i);
    }
    pub fn bitmap(self: Face, index: u32) ?Bitmap {
        var result: Bitmap = undefined;
        if (zid_font_bitmap(self.handle, index, &result) == 0) return null;
        return result;
    }
};
pub const Font = struct {
    face: Face,
    renderer: sdl.render.Renderer,
    pub fn init(renderer: sdl.render.Renderer, pixels: u32) !Font {
        return .{ .face = try Face.init(pixels), .renderer = renderer };
    }
    pub fn deinit(self: Font) void {
        self.face.deinit();
    }
    pub fn draw(self: Font, value: []const u8, x: f32, baseline: f32, color: [3]u8) !void {
        _ = try self.text(value, x, baseline, color, true);
    }
    pub fn width(self: Font, text_value: []const u8) f32 {
        return self.text(text_value, 0, 0, .{ 0, 0, 0 }, false) catch 0;
    }
    fn text(self: Font, value: []const u8, x: f32, baseline: f32, color: [3]u8, draw_it: bool) !f32 {
        var pen: f32 = 0;
        var off: usize = 0;
        while (off < value.len) {
            if (value[off] == '\t') {
                const tab = self.face.space() * 4;
                pen = (@floor(pen / tab) + 1) * tab;
                off += 1;
                continue;
            }
            const end = off + (std.mem.indexOfScalar(u8, value[off..], '\t') orelse value.len - off);
            try self.face.shape(value[off..end]);
            for (0..self.face.count()) |i| {
                const p = self.face.position(@intCast(i));
                if (draw_it) if (self.face.bitmap(p.index)) |b| {
                    if (b.gray != 0 and b.width > 0 and b.height > 0 and b.width <= 512 and b.height <= 512) {
                        const w: usize = @intCast(b.width);
                        const h: usize = @intCast(b.height);
                        const data = try std.heap.page_allocator.alloc(u8, w * h * 4);
                        defer std.heap.page_allocator.free(data);
                        const src = b.pixels orelse return error.InvalidBitmap;
                        const pitch: usize = @intCast(@abs(b.pitch));
                        for (0..h) |row| for (0..w) |col| {
                            const j = (row * w + col) * 4;
                            @memset(data[j..][0..3], 255);
                            data[j + 3] = src[(if (b.pitch < 0) h - 1 - row else row) * pitch + col];
                        };
                        const texture = try self.renderer.createTexture(.array_rgba_32, .static, w, h);
                        defer texture.deinit();
                        try texture.update(null, data.ptr, w * 4);
                        try texture.setBlendMode(.blend);
                        try texture.setColorMod(color[0], color[1], color[2]);
                        try self.renderer.renderTexture(texture, null, .{ .x = x + pen + @as(f32, @floatFromInt(p.x_offset)) / 64 + @as(f32, @floatFromInt(b.left)), .y = baseline - @as(f32, @floatFromInt(p.y_offset)) / 64 - @as(f32, @floatFromInt(b.top)), .w = @floatFromInt(w), .h = @floatFromInt(h) });
                    }
                };
                pen += @as(f32, @floatFromInt(p.x_advance)) / 64;
            }
            off = end;
        }
        return pen;
    }
};
