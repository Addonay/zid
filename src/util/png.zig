//! Minimal PNG encoder (RGBA8, stored/uncompressed deflate blocks). Used for
//! `--screenshot` and visual regression captures.
const std = @import("std");

pub fn encode(alloc: std.mem.Allocator, w: u32, h: u32, rgba: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(alloc, &out, "IHDR", &ihdr);

    // Raw scanlines with filter byte 0.
    const stride = w * 4 + 1;
    const raw = try alloc.alloc(u8, stride * h);
    defer alloc.free(raw);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        raw[y * stride] = 0;
        @memcpy(raw[y * stride + 1 ..][0 .. w * 4], rgba[y * w * 4 ..][0 .. w * 4]);
    }

    // zlib stream of stored blocks.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(alloc);
    try z.appendSlice(alloc, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (off < raw.len or off == 0) {
        const n: u16 = @intCast(@min(raw.len - off, 65535));
        const last: u8 = if (off + n >= raw.len) 1 else 0;
        try z.append(alloc, last);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u16, len_buf[0..2], n, .little);
        std.mem.writeInt(u16, len_buf[2..4], ~n, .little);
        try z.appendSlice(alloc, &len_buf);
        try z.appendSlice(alloc, raw[off .. off + n]);
        off += n;
        if (raw.len == 0) break;
    }
    var ad: [4]u8 = undefined;
    std.mem.writeInt(u32, &ad, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(alloc, &ad);
    try chunk(alloc, &out, "IDAT", z.items);
    try chunk(alloc, &out, "IEND", "");
    return out.toOwnedSlice(alloc);
}

fn chunk(alloc: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(alloc, &len);
    try out.appendSlice(alloc, kind);
    try out.appendSlice(alloc, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var cb: [4]u8 = undefined;
    std.mem.writeInt(u32, &cb, crc.final(), .big);
    try out.appendSlice(alloc, &cb);
}
