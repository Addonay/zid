//! BMP decoder: BITMAPCOREHEADER and BITMAPINFOHEADER (v1-v5), 1/4/8-bit palettes,
//! 16/24/32-bit direct colour, BI_RGB and BI_BITFIELDS (alpha mask honoured), top-down
//! and bottom-up rows. RLE and embedded JPEG/PNG compressions are rejected.
const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;

pub fn isBmp(bytes: []const u8) bool {
    return bytes.len >= 26 and bytes[0] == 'B' and bytes[1] == 'M';
}

fn read(comptime T: type, bytes: []const u8, at: usize) !T {
    if (at + @sizeOf(T) > bytes.len) return error.TruncatedBmp;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

const Mask = struct {
    mask: u32,
    shift: u5,
    bits: u6,
    fn init(mask: u32) Mask {
        if (mask == 0) return .{ .mask = 0, .shift = 0, .bits = 0 };
        return .{ .mask = mask, .shift = @intCast(@ctz(mask)), .bits = @intCast(@popCount(mask)) };
    }
    fn get(m: Mask, v: u32, default: u8) u8 {
        if (m.bits == 0) return default;
        const raw = (v & m.mask) >> m.shift;
        const max = (@as(u64, 1) << m.bits) - 1;
        return @intCast(@as(u64, raw) * 255 / max);
    }
};

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (!isBmp(bytes)) return error.InvalidBmp;
    const data_offset = try read(u32, bytes, 10);
    const header_size = try read(u32, bytes, 14);
    var width: i32 = 0;
    var height: i32 = 0;
    var bpp: u16 = 0;
    var compression: u32 = 0;
    var colors_used: u32 = 0;
    var masks = [4]u32{ 0, 0, 0, 0 };
    var palette_entry: usize = 4;
    if (header_size == 12) {
        width = try read(u16, bytes, 18);
        height = try read(u16, bytes, 20);
        bpp = try read(u16, bytes, 24);
        palette_entry = 3;
    } else if (header_size >= 40) {
        width = try read(i32, bytes, 18);
        height = try read(i32, bytes, 22);
        bpp = try read(u16, bytes, 28);
        compression = try read(u32, bytes, 30);
        colors_used = try read(u32, bytes, 46);
        if (compression == 3 or compression == 6) {
            // Masks follow a 40-byte header, or live inside v2+ headers.
            masks[0] = try read(u32, bytes, 54);
            masks[1] = try read(u32, bytes, 58);
            masks[2] = try read(u32, bytes, 62);
            if (header_size >= 56 or compression == 6) masks[3] = try read(u32, bytes, 66);
        }
    } else return error.UnsupportedBmp;
    if (compression != 0 and compression != 3 and compression != 6) return error.UnsupportedBmp;
    const top_down = height < 0;
    const w: u32 = @intCast(@abs(width));
    const h: u32 = @intCast(@abs(height));
    try image.checkDimensions(w, h);
    if (compression == 0) switch (bpp) {
        16 => masks = .{ 0x7c00, 0x03e0, 0x001f, 0 },
        24, 32 => masks = .{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0 },
        else => {},
    };
    const rm = Mask.init(masks[0]);
    const gm = Mask.init(masks[1]);
    const bm = Mask.init(masks[2]);
    const am = Mask.init(masks[3]);

    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    if (bpp <= 8) {
        const count: usize = if (colors_used > 0) @min(colors_used, 256) else @as(usize, 1) << @intCast(bpp);
        const base = 14 + header_size + (if (compression == 3 and header_size == 40) @as(usize, 12) else 0);
        for (0..count) |i| {
            const at = base + i * palette_entry;
            if (at + 3 > bytes.len) return error.TruncatedBmp;
            palette[i] = .{ bytes[at + 2], bytes[at + 1], bytes[at], 255 };
        }
    }
    const stride = ((@as(usize, w) * bpp + 31) / 32) * 4;
    if (data_offset + stride * h > bytes.len) return error.TruncatedBmp;
    var out = try Image.init(gpa, w, h);
    errdefer out.deinit();
    var any_alpha = false;
    for (0..h) |row| {
        const src_row = if (top_down) row else h - 1 - row;
        const line = bytes[data_offset + src_row * stride ..][0..stride];
        for (0..w) |x| {
            const px = out.pixels[(row * w + x) * 4 ..][0..4];
            switch (bpp) {
                1, 2, 4, 8 => {
                    const bit = x * bpp;
                    const shift: u3 = @intCast(8 - bpp - bit % 8);
                    const index: u8 = @intCast(@as(u16, line[bit / 8] >> shift) & ((@as(u16, 1) << @intCast(bpp)) - 1));
                    px.* = palette[index];
                },
                16 => {
                    const v: u32 = std.mem.readInt(u16, line[x * 2 ..][0..2], .little);
                    px.* = .{ rm.get(v, 0), gm.get(v, 0), bm.get(v, 0), am.get(v, 255) };
                },
                24 => px.* = .{ line[x * 3 + 2], line[x * 3 + 1], line[x * 3], 255 },
                32 => {
                    const v = std.mem.readInt(u32, line[x * 4 ..][0..4], .little);
                    px.* = .{ rm.get(v, 0), gm.get(v, 0), bm.get(v, 0), am.get(v, 255) };
                    if (am.bits > 0 and px[3] != 0) any_alpha = true;
                },
                else => return error.UnsupportedBmp,
            }
        }
    }
    // A 32-bit alpha channel that is entirely zero means "no alpha" in practice.
    if (bpp == 32 and am.bits > 0 and !any_alpha) {
        var i: usize = 3;
        while (i < out.pixels.len) : (i += 4) out.pixels[i] = 255;
    }
    return out;
}
