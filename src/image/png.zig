//! PNG decoder (ISO/IEC 15948): all colour types and bit depths, PLTE, tRNS, the five
//! scanline filters and Adam7 interlacing. Output is straight-alpha RGBA8; 16-bit
//! samples keep their high byte. Ancillary chunks other than tRNS are ignored.
const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;

const signature = "\x89PNG\r\n\x1a\n";

pub fn isPng(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, signature);
}

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: u8,
    interlace: bool,

    fn channels(h: Header) u8 {
        return switch (h.color) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => 0,
        };
    }
    fn bitsPerPixel(h: Header) usize {
        return @as(usize, h.channels()) * h.depth;
    }
    fn rowBytes(h: Header, width: usize) usize {
        return (@as(usize, width) * h.bitsPerPixel() + 7) / 8;
    }
};

const adam7 = [7][4]u8{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (!isPng(bytes)) return error.InvalidPng;
    var pos: usize = signature.len;
    var header: ?Header = null;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var palette_len: usize = 0;
    var key: ?[3]u16 = null; // tRNS colour key for gray/RGB
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (len > bytes.len - pos - 12) return error.TruncatedPng;
        const kind = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[pos + 4 .. pos + 8 + len]) != crc) return error.PngChecksum;
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.InvalidPng;
            const h: Header = .{
                .width = std.mem.readInt(u32, data[0..4], .big),
                .height = std.mem.readInt(u32, data[4..8], .big),
                .depth = data[8],
                .color = data[9],
                .interlace = data[12] == 1,
            };
            if (h.channels() == 0 or data[10] != 0 or data[11] != 0 or data[12] > 1) return error.UnsupportedPng;
            const valid_depth = switch (h.color) {
                0 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8 or h.depth == 16,
                3 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8,
                else => h.depth == 8 or h.depth == 16,
            };
            if (!valid_depth) return error.UnsupportedPng;
            try image.checkDimensions(h.width, h.height);
            header = h;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len / 3 > 256) return error.InvalidPng;
            palette_len = len / 3;
            for (0..palette_len) |i| palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            const h = header orelse return error.InvalidPng;
            switch (h.color) {
                3 => for (data[0..@min(len, 256)], 0..) |a, i| {
                    palette[i][3] = a;
                },
                0 => if (len >= 2) {
                    const v = std.mem.readInt(u16, data[0..2], .big);
                    key = .{ v, v, v };
                },
                2 => if (len >= 6) {
                    key = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try compressed.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        } else if (kind[0] & 0x20 == 0) {
            return error.UnsupportedPng; // unknown critical chunk
        }
    }
    const h = header orelse return error.InvalidPng;
    if (h.color == 3 and palette_len == 0) return error.InvalidPng;

    // Expected inflated size: one filter byte per scanline of every (sub-)image.
    var raw_len: usize = 0;
    if (h.interlace) {
        for (adam7) |p| {
            const pw = passSize(h.width, p[0], p[2]);
            const ph = passSize(h.height, p[1], p[3]);
            if (pw > 0 and ph > 0) raw_len += ph * (1 + h.rowBytes(pw));
        }
    } else raw_len = @as(usize, h.height) * (1 + h.rowBytes(h.width));
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    {
        var in: std.Io.Reader = .fixed(compressed.items);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var inflate: std.compress.flate.Decompress = .init(&in, .zlib, &window);
        inflate.reader.readSliceAll(raw) catch return error.InvalidPngData;
    }

    var out = try Image.init(gpa, h.width, h.height);
    errdefer out.deinit();
    const bpp = @max(1, h.bitsPerPixel() / 8);
    if (h.interlace) {
        var offset: usize = 0;
        for (adam7) |p| {
            const pw = passSize(h.width, p[0], p[2]);
            const ph = passSize(h.height, p[1], p[3]);
            if (pw == 0 or ph == 0) continue;
            const stride = 1 + h.rowBytes(pw);
            const pass = raw[offset..][0 .. ph * stride];
            offset += pass.len;
            try unfilter(pass, stride, bpp);
            for (0..ph) |y| {
                const row = pass[y * stride + 1 ..][0 .. stride - 1];
                for (0..pw) |x| {
                    const px = p[0] + x * p[2];
                    const py = p[1] + y * p[3];
                    out.pixels[(py * h.width + px) * 4 ..][0..4].* = pixel(h, row, x, &palette, key);
                }
            }
        }
    } else {
        const stride = 1 + h.rowBytes(h.width);
        try unfilter(raw, stride, bpp);
        for (0..h.height) |y| {
            const row = raw[y * stride + 1 ..][0 .. stride - 1];
            for (0..h.width) |x| out.pixels[(y * h.width + x) * 4 ..][0..4].* = pixel(h, row, x, &palette, key);
        }
    }
    return out;
}

fn passSize(full: u32, start: u8, step: u8) usize {
    if (full <= start) return 0;
    return (full - start + step - 1) / step;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    return if (pb <= pc) b else c;
}

/// Reverses the per-scanline filters in place; `rows` includes the filter bytes.
fn unfilter(rows: []u8, stride: usize, bpp: usize) !void {
    const height = rows.len / stride;
    for (0..height) |y| {
        const filter = rows[y * stride];
        const cur = rows[y * stride + 1 ..][0 .. stride - 1];
        const prev: ?[]const u8 = if (y > 0) rows[(y - 1) * stride + 1 ..][0 .. stride - 1] else null;
        switch (filter) {
            0 => {},
            1 => for (bpp..cur.len) |i| {
                cur[i] +%= cur[i - bpp];
            },
            2 => if (prev) |p| for (cur, p) |*c, b| {
                c.* +%= b;
            },
            3 => for (cur, 0..) |*c, i| {
                const a: u16 = if (i >= bpp) cur[i - bpp] else 0;
                const b: u16 = if (prev) |p| p[i] else 0;
                c.* +%= @intCast((a + b) / 2);
            },
            4 => for (cur, 0..) |*c, i| {
                const a = if (i >= bpp) cur[i - bpp] else 0;
                const b = if (prev) |p| p[i] else 0;
                const cc = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                c.* +%= paeth(a, b, cc);
            },
            else => return error.InvalidPngFilter,
        }
    }
}

fn sample(h: Header, row: []const u8, index: usize) u16 {
    return switch (h.depth) {
        16 => std.mem.readInt(u16, row[index * 2 ..][0..2], .big),
        8 => row[index],
        else => blk: {
            const bit = index * h.depth;
            const shift: u3 = @intCast(8 - h.depth - bit % 8);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(h.depth)) - 1);
            break :blk (row[bit / 8] >> shift) & mask;
        },
    };
}
fn to8(h: Header, v: u16) u8 {
    return switch (h.depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(h.depth)) - 1)),
    };
}

fn pixel(h: Header, row: []const u8, x: usize, palette: *const [256][4]u8, key: ?[3]u16) [4]u8 {
    const c = h.channels();
    switch (h.color) {
        3 => return palette[sample(h, row, x)],
        0 => {
            const v = sample(h, row, x);
            const g = to8(h, v);
            const a: u8 = if (key != null and key.?[0] == v) 0 else 255;
            return .{ g, g, g, a };
        },
        4 => {
            const g = to8(h, sample(h, row, x * 2));
            return .{ g, g, g, to8(h, sample(h, row, x * 2 + 1)) };
        },
        2 => {
            const r = sample(h, row, x * 3);
            const g = sample(h, row, x * 3 + 1);
            const b = sample(h, row, x * 3 + 2);
            const a: u8 = if (key) |k| (if (k[0] == r and k[1] == g and k[2] == b) 0 else 255) else 255;
            return .{ to8(h, r), to8(h, g), to8(h, b), a };
        },
        else => {
            _ = c;
            return .{ to8(h, sample(h, row, x * 4)), to8(h, sample(h, row, x * 4 + 1)), to8(h, sample(h, row, x * 4 + 2)), to8(h, sample(h, row, x * 4 + 3)) };
        },
    }
}
