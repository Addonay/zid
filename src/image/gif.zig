//! GIF decoder (87a/89a): the first frame composited on a transparent logical screen,
//! global/local colour tables, the graphic-control transparency index and interlaced
//! rows. Animation (later frames, delays, disposal) is not decoded.
const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;

pub fn isGif(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a");
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    fn byte(r: *Reader) !u8 {
        if (r.pos >= r.data.len) return error.TruncatedGif;
        defer r.pos += 1;
        return r.data[r.pos];
    }
    fn u16le(r: *Reader) !u16 {
        const lo = try r.byte();
        const hi = try r.byte();
        return @as(u16, hi) << 8 | lo;
    }
    fn take(r: *Reader, n: usize) ![]const u8 {
        if (r.pos + n > r.data.len) return error.TruncatedGif;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }
    fn skipBlocks(r: *Reader) !void {
        while (true) {
            const n = try r.byte();
            if (n == 0) return;
            _ = try r.take(n);
        }
    }
};

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (!isGif(bytes)) return error.InvalidGif;
    var r: Reader = .{ .data = bytes, .pos = 6 };
    const width = try r.u16le();
    const height = try r.u16le();
    try image.checkDimensions(width, height);
    const flags = try r.byte();
    _ = try r.byte(); // background index (the canvas starts transparent, as browsers do)
    _ = try r.byte(); // aspect
    var global: [256][3]u8 = undefined;
    var global_len: usize = 0;
    if (flags & 0x80 != 0) {
        global_len = @as(usize, 2) << @intCast(flags & 7);
        const table = try r.take(global_len * 3);
        for (0..global_len) |i| global[i] = table[i * 3 ..][0..3].*;
    }
    var transparent: ?u8 = null;
    var out = try Image.init(gpa, width, height);
    errdefer out.deinit();
    @memset(out.pixels, 0);
    while (true) {
        switch (try r.byte()) {
            0x21 => {
                const label = try r.byte();
                if (label == 0xf9) {
                    const n = try r.byte();
                    const block = try r.take(n);
                    if (n >= 4 and block[0] & 1 != 0) transparent = block[3];
                }
                try r.skipBlocks();
            },
            0x2c => {
                const left = try r.u16le();
                const top = try r.u16le();
                const w = try r.u16le();
                const h = try r.u16le();
                const local_flags = try r.byte();
                var palette = global;
                var palette_len = global_len;
                if (local_flags & 0x80 != 0) {
                    palette_len = @as(usize, 2) << @intCast(local_flags & 7);
                    const table = try r.take(palette_len * 3);
                    for (0..palette_len) |i| palette[i] = table[i * 3 ..][0..3].*;
                }
                if (palette_len == 0) return error.InvalidGif;
                const min_code = try r.byte();
                if (min_code < 2 or min_code > 11) return error.InvalidGif;
                // Gather the sub-blocks into one LZW stream.
                var stream: std.ArrayList(u8) = .empty;
                defer stream.deinit(gpa);
                while (true) {
                    const n = try r.byte();
                    if (n == 0) break;
                    try stream.appendSlice(gpa, try r.take(n));
                }
                const indices = try gpa.alloc(u8, @as(usize, w) * h);
                defer gpa.free(indices);
                try lzw(stream.items, min_code, indices);
                const interlaced = local_flags & 0x40 != 0;
                for (0..h) |row| {
                    const y = top + (if (interlaced) interlacedRow(row, h) else row);
                    if (y >= height) continue;
                    for (0..w) |col| {
                        const x = left + col;
                        if (x >= width) continue;
                        const idx = indices[row * w + col];
                        if (transparent != null and idx == transparent.?) continue;
                        if (idx >= palette_len) continue;
                        const c = palette[idx];
                        out.pixels[(y * width + x) * 4 ..][0..4].* = .{ c[0], c[1], c[2], 255 };
                    }
                }
                return out; // first frame only
            },
            0x3b => return out,
            else => return error.InvalidGif,
        }
    }
}

/// Maps the n-th stored row of an interlaced image to its display row.
fn interlacedRow(n: usize, height: usize) usize {
    const passes = [4][2]usize{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };
    var remaining = n;
    for (passes) |p| {
        const count = if (height > p[0]) (height - p[0] + p[1] - 1) / p[1] else 0;
        if (remaining < count) return p[0] + remaining * p[1];
        remaining -= count;
    }
    return 0;
}

fn lzw(data: []const u8, min_code: u8, out: []u8) !void {
    const clear: u16 = @as(u16, 1) << @intCast(min_code);
    const end = clear + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var first: [4096]u8 = undefined;
    var length: [4096]u16 = undefined;
    for (0..clear) |i| {
        suffix[i] = @intCast(i);
        first[i] = @intCast(i);
        length[i] = 1;
    }
    var next: u16 = end + 1;
    var size: u5 = @intCast(min_code + 1);
    var previous: ?u16 = null;
    var bits: u32 = 0;
    var count: u5 = 0;
    var pos: usize = 0;
    var written: usize = 0;
    while (written < out.len) {
        while (count < size) {
            if (pos >= data.len) return; // short streams leave the rest transparent
            bits |= @as(u32, data[pos]) << count;
            pos += 1;
            count += 8;
        }
        const code: u16 = @intCast(bits & ((@as(u32, 1) << size) - 1));
        bits >>= size;
        count -= size;
        if (code == clear) {
            next = end + 1;
            size = @intCast(min_code + 1);
            previous = null;
            continue;
        }
        if (code == end) return;
        var entry = code;
        if (previous) |prev| {
            // A known code adds prev + first(code); the KwKwK case (code == next) adds
            // prev + first(prev) and emits that new entry.
            if (code > next or (code == next and next == 4096)) return error.InvalidGifData;
            const first_char = if (code == next) first[prev] else first[code];
            if (next < 4096) {
                prefix[next] = prev;
                suffix[next] = first_char;
                first[next] = first[prev];
                length[next] = length[prev] + 1;
                entry = code;
                next += 1;
                if (next == (@as(u16, 1) << @intCast(size)) and size < 12) size += 1;
            }
        } else if (code >= clear) return error.InvalidGifData;
        // Emit the string for `entry` backwards.
        const n = length[entry];
        if (written + n > out.len) return;
        var c = entry;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            out[written + i] = suffix[c];
            if (i > 0) c = prefix[c];
        }
        written += n;
        previous = code;
    }
}
