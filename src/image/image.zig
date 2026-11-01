//! Pure-Zig raster image decoding (no C libraries): PNG, JPEG (baseline and
//! progressive), GIF (first frame) and BMP into straight-alpha RGBA8, plus the resize
//! used for thumbnails and avatars. Independent of SDL and rendering.
const std = @import("std");
pub const png = @import("png.zig");
pub const jpeg = @import("jpeg.zig");
pub const gif = @import("gif.zig");
pub const bmp = @import("bmp.zig");

/// Decoding refuses images above these bounds (hostile files, memory).
pub const max_dimension = 32768;
pub const max_pixels = 128 * 1024 * 1024;

pub const Format = enum { png, jpeg, gif, bmp };

pub const Image = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    /// Straight (non-premultiplied) RGBA8, row-major.
    pixels: []u8,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Image {
        try checkDimensions(width, height);
        return .{ .gpa = gpa, .width = width, .height = height, .pixels = try gpa.alloc(u8, @as(usize, width) * height * 4) };
    }
    pub fn deinit(self: *Image) void {
        self.gpa.free(self.pixels);
        self.* = undefined;
    }
};

pub fn checkDimensions(width: u32, height: u32) !void {
    if (width == 0 or height == 0) return error.EmptyImage;
    if (width > max_dimension or height > max_dimension or @as(u64, width) * height > max_pixels) return error.ImageTooLarge;
}

pub fn sniff(bytes: []const u8) ?Format {
    if (png.isPng(bytes)) return .png;
    if (jpeg.isJpeg(bytes)) return .jpeg;
    if (gif.isGif(bytes)) return .gif;
    if (bmp.isBmp(bytes)) return .bmp;
    return null;
}

/// Decodes by content, not file extension.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    return switch (sniff(bytes) orelse return error.UnsupportedImageFormat) {
        .png => png.decode(gpa, bytes),
        .jpeg => jpeg.decode(gpa, bytes),
        .gif => gif.decode(gpa, bytes),
        .bmp => bmp.decode(gpa, bytes),
    };
}

/// Area-averaging resize (box filter for downscaling, nearest-ish for upscaling),
/// weighted by alpha so transparent pixels do not darken edges.
pub fn resize(gpa: std.mem.Allocator, src: Image, width: u32, height: u32) !Image {
    var out = try Image.init(gpa, width, height);
    errdefer out.deinit();
    const sx = @as(f64, @floatFromInt(src.width)) / @as(f64, @floatFromInt(width));
    const sy = @as(f64, @floatFromInt(src.height)) / @as(f64, @floatFromInt(height));
    for (0..height) |y| {
        const y0 = @as(f64, @floatFromInt(y)) * sy;
        const y1 = y0 + sy;
        for (0..width) |x| {
            const x0 = @as(f64, @floatFromInt(x)) * sx;
            const x1 = x0 + sx;
            var acc = [4]f64{ 0, 0, 0, 0 };
            var weight_sum: f64 = 0;
            var yy: usize = @intFromFloat(@floor(y0));
            while (@as(f64, @floatFromInt(yy)) < y1 and yy < src.height) : (yy += 1) {
                const wy = @min(y1, @as(f64, @floatFromInt(yy + 1))) - @max(y0, @as(f64, @floatFromInt(yy)));
                var xx: usize = @intFromFloat(@floor(x0));
                while (@as(f64, @floatFromInt(xx)) < x1 and xx < src.width) : (xx += 1) {
                    const wx = @min(x1, @as(f64, @floatFromInt(xx + 1))) - @max(x0, @as(f64, @floatFromInt(xx)));
                    const w = wx * wy;
                    const p = src.pixels[(yy * src.width + xx) * 4 ..][0..4];
                    const a = @as(f64, @floatFromInt(p[3])) / 255;
                    for (0..3) |c| acc[c] += @as(f64, @floatFromInt(p[c])) * a * w;
                    acc[3] += a * w;
                    weight_sum += w;
                }
            }
            const px = out.pixels[(y * width + x) * 4 ..][0..4];
            if (acc[3] > 0) {
                for (0..3) |c| px[c] = @intFromFloat(std.math.clamp(@round(acc[c] / acc[3]), 0, 255));
            } else px[0..3].* = .{ 0, 0, 0 };
            px[3] = @intFromFloat(std.math.clamp(@round(acc[3] / weight_sum * 255), 0, 255));
        }
    }
    return out;
}

// ---------------------------------------------------------------- tests

fn expectMatches(name: []const u8, bytes: []const u8, expected: []const u8, tolerance: struct { mean: f64 = 0, max: u8 = 0 }) !void {
    var img = decode(std.testing.allocator, bytes) catch |err| {
        std.debug.print("{s}: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    defer img.deinit();
    try std.testing.expectEqual(expected.len, img.pixels.len);
    var total: u64 = 0;
    var worst: u8 = 0;
    var i: usize = 0;
    while (i < expected.len) : (i += 4) {
        // Colour under a fully transparent pixel is invisible; decoders differ there.
        const both_clear = img.pixels[i + 3] == 0 and expected[i + 3] == 0;
        for (img.pixels[i..][0..4], expected[i..][0..4], 0..) |a, b, c| {
            if (both_clear and c < 3) continue;
            const d: u8 = if (a > b) a - b else b - a;
            total += d;
            worst = @max(worst, d);
        }
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(expected.len));
    if (mean > tolerance.mean or worst > tolerance.max) {
        std.debug.print("{s}: mean error {d:.3}, max {d}\n", .{ name, mean, worst });
        return error.TestUnexpectedResult;
    }
}

const fixtures = .{
    "png_rgba8",  "png_rgba8_adam7", "png_rgb8",  "png_rgba16", "png_gray8", "png_gray16_adam7", "png_graya8", "png_gray1",
    "png_gray2",  "png_gray4",       "png_pal1",  "png_pal2",   "png_pal4",  "png_pal8_adam7",   "png_rgb8_trns",
};

test "PNG fixtures decode exactly" {
    inline for (fixtures) |name| try expectMatches(name, @embedFile("testdata/" ++ name ++ ".png"), @embedFile("testdata/" ++ name ++ ".rgba"), .{});
}

test "GIF and BMP fixtures decode exactly" {
    inline for (.{ "gif_basic", "gif_interlaced" }) |name| try expectMatches(name, @embedFile("testdata/" ++ name ++ ".gif"), @embedFile("testdata/" ++ name ++ ".rgba"), .{});
    inline for (.{ "bmp_24", "bmp_32", "bmp_8" }) |name| try expectMatches(name, @embedFile("testdata/" ++ name ++ ".bmp"), @embedFile("testdata/" ++ name ++ ".rgba"), .{});
}

test "JPEG fixtures decode within IDCT and upsampling tolerance of libjpeg" {
    // Float IDCT and bilinear chroma vs libjpeg's integer IDCT and fancy upsampling.
    inline for (.{ "jpeg_444", "jpeg_gray", "jpeg_progressive_gray" }) |name| {
        try expectMatches(name, @embedFile("testdata/" ++ name ++ ".jpg"), @embedFile("testdata/" ++ name ++ ".rgba"), .{ .mean = 1.0, .max = 8 });
    }
    inline for (.{ "jpeg_420", "jpeg_422", "jpeg_progressive", "jpeg_restart" }) |name| {
        try expectMatches(name, @embedFile("testdata/" ++ name ++ ".jpg"), @embedFile("testdata/" ++ name ++ ".rgba"), .{ .mean = 2.0, .max = 40 });
    }
}

test "resize averages and keeps alpha-weighted colour" {
    var src = try Image.init(std.testing.allocator, 2, 2);
    defer src.deinit();
    @memcpy(src.pixels, &[_]u8{ 255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 0, 0, 0, 255, 0 });
    var out = try resize(std.testing.allocator, src, 1, 1);
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128 }, out.pixels);
}

test "corrupt input is rejected without crashing" {
    const bad = [_][]const u8{ "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR", "\xff\xd8\xff\xdb\x00\x43", "GIF89a\x01\x00\x01\x00\x00\x00\x00\x2c", "BM\x00\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00" };
    for (bad) |bytes| {
        if (decode(std.testing.allocator, bytes)) |img| {
            var copy = img;
            copy.deinit();
        } else |_| {}
    }
}
