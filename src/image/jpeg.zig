//! JPEG decoder (ITU T.81): baseline and extended sequential (SOF0/SOF1) and progressive
//! (SOF2) Huffman, any sampling factors, restart intervals, 8/16-bit quantisation
//! tables, JFIF YCbCr, grayscale, Adobe RGB and Adobe CMYK/YCCK. Arithmetic coding and
//! lossless/hierarchical modes are rejected.
//!
//! All scans decode into per-component coefficient planes, so progressive and
//! sequential images share one dequantise + float IDCT pass. Chroma is upsampled with a
//! centred bilinear filter, which is what libjpeg's "fancy upsampling" approximates.
const std = @import("std");
const image = @import("image.zig");
const Image = image.Image;

pub fn isJpeg(bytes: []const u8) bool {
    return bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff;
}

const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

const fast_bits = 9;
const Huffman = struct {
    /// Fast lookup: (length << 8 | symbol) for codes up to `fast_bits`, 0 if longer.
    fast: [1 << fast_bits]u16 = @splat(0),
    /// Canonical decoding: largest code of each length (-1 when none) and the index of
    /// its first symbol.
    maxcode: [18]i32 = @splat(-1),
    valptr: [17]i32 = @splat(0),
    mincode: [17]i32 = @splat(0),
    symbols: [256]u8 = undefined,
    present: bool = false,

    fn build(counts: [16]u8, symbols: []const u8) !Huffman {
        var h: Huffman = .{ .present = true };
        @memcpy(h.symbols[0..symbols.len], symbols);
        var code: i32 = 0;
        var k: i32 = 0;
        for (1..17) |len| {
            const n: i32 = counts[len - 1];
            h.valptr[len] = k;
            h.mincode[len] = code;
            if (n > 0) {
                var i: i32 = 0;
                while (i < n) : (i += 1) {
                    if (len <= fast_bits) {
                        const shift: u4 = @intCast(fast_bits - len);
                        const base: usize = @intCast(code << shift);
                        const fill: usize = @as(usize, 1) << shift;
                        for (h.fast[base..][0..fill]) |*f| f.* = @intCast((len << 8) | symbols[@intCast(k)]);
                    }
                    code += 1;
                    k += 1;
                }
                h.maxcode[len] = code - 1;
            }
            if (code > (@as(i32, 1) << @intCast(len))) return error.InvalidHuffmanTable;
            code <<= 1;
        }
        h.maxcode[17] = std.math.maxInt(i32);
        return h;
    }
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    td: u8 = 0,
    ta: u8 = 0,
    blocks_per_line: usize = 0,
    blocks_per_column: usize = 0,
    coefs: []i16 = &.{},
    dc_pred: i32 = 0,
    /// Plane of decoded samples, `blocks_per_line * 8` wide.
    plane: []u8 = &.{},
};

const BitReader = struct {
    data: []const u8,
    pos: usize,
    buffer: u32 = 0,
    count: u6 = 0,
    marker_hit: bool = false,

    fn fill(r: *BitReader) void {
        while (r.count <= 24) {
            var byte: u32 = 0;
            if (!r.marker_hit and r.pos < r.data.len) {
                byte = r.data[r.pos];
                if (byte == 0xff) {
                    const next = if (r.pos + 1 < r.data.len) r.data[r.pos + 1] else 0;
                    if (next == 0) {
                        r.pos += 2;
                    } else {
                        // A marker ends the entropy segment; feed zeros past it.
                        r.marker_hit = true;
                        byte = 0;
                    }
                } else r.pos += 1;
            }
            r.buffer |= byte << @intCast(24 - r.count);
            r.count += 8;
        }
    }
    fn bits(r: *BitReader, n: u5) u32 {
        if (n == 0) return 0;
        if (r.count < n) r.fill();
        const v = r.buffer >> @intCast(32 - @as(u6, n));
        r.buffer <<= n;
        r.count -= n;
        return v;
    }
    fn bit(r: *BitReader) u32 {
        return r.bits(1);
    }
    fn decode(r: *BitReader, h: *const Huffman) !u8 {
        if (r.count < 16) r.fill();
        const peek = r.buffer >> (32 - fast_bits);
        const f = h.fast[peek];
        if (f != 0) {
            const len: u5 = @intCast(f >> 8);
            r.buffer <<= len;
            r.count -= len;
            return @intCast(f & 0xff);
        }
        var code: i32 = 0;
        var len: usize = 1;
        while (len <= 16) : (len += 1) {
            code = (code << 1) | @as(i32, @intCast(r.bit()));
            if (code <= h.maxcode[len]) return h.symbols[@intCast(h.valptr[len] + code - h.mincode[len])];
        }
        return error.InvalidHuffmanCode;
    }
    fn receiveExtend(r: *BitReader, s: u5) i32 {
        if (s == 0) return 0;
        const v: i32 = @intCast(r.bits(s));
        return if (v < (@as(i32, 1) << (s - 1))) v - (@as(i32, 1) << s) + 1 else v;
    }
    /// Skip to just past the next RSTn marker and reset the bit buffer.
    fn restart(r: *BitReader) !void {
        r.buffer = 0;
        r.count = 0;
        r.marker_hit = false;
        while (r.pos + 1 < r.data.len) : (r.pos += 1) {
            if (r.data[r.pos] == 0xff and r.data[r.pos + 1] >= 0xd0 and r.data[r.pos + 1] <= 0xd7) {
                r.pos += 2;
                return;
            }
        }
        return error.MissingRestartMarker;
    }
};

const Decoder = struct {
    gpa: std.mem.Allocator,
    width: u32 = 0,
    height: u32 = 0,
    progressive: bool = false,
    components: [4]Component = undefined,
    ncomp: usize = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcus_x: usize = 0,
    mcus_y: usize = 0,
    quant: [4][64]u16 = @splat(@splat(1)),
    dc: [4]Huffman = @splat(.{}),
    ac: [4]Huffman = @splat(.{}),
    restart_interval: u16 = 0,
    adobe_transform: ?u8 = null,
    jfif: bool = false,
    eobrun: u32 = 0,

    fn deinit(d: *Decoder) void {
        for (d.components[0..d.ncomp]) |c| {
            d.gpa.free(c.coefs);
            d.gpa.free(c.plane);
        }
    }

    fn frame(d: *Decoder, data: []const u8) !void {
        if (data.len < 6) return error.InvalidJpeg;
        if (data[0] != 8) return error.UnsupportedJpegPrecision;
        d.height = std.mem.readInt(u16, data[1..3], .big);
        d.width = std.mem.readInt(u16, data[3..5], .big);
        d.ncomp = data[5];
        if (d.width == 0 or d.height == 0) return error.UnsupportedJpeg; // DNL not supported
        try image.checkDimensions(d.width, d.height);
        if (d.ncomp == 0 or d.ncomp > 4 or data.len < 6 + d.ncomp * 3) return error.InvalidJpeg;
        for (0..d.ncomp) |i| {
            const c = data[6 + i * 3 ..][0..3];
            const h = c[1] >> 4;
            const v = c[1] & 15;
            if (h == 0 or h > 4 or v == 0 or v > 4 or c[2] > 3) return error.InvalidJpeg;
            d.components[i] = .{ .id = c[0], .h = h, .v = v, .tq = c[2] };
            d.hmax = @max(d.hmax, h);
            d.vmax = @max(d.vmax, v);
        }
        d.mcus_x = (d.width + 8 * @as(usize, d.hmax) - 1) / (8 * @as(usize, d.hmax));
        d.mcus_y = (d.height + 8 * @as(usize, d.vmax) - 1) / (8 * @as(usize, d.vmax));
        for (d.components[0..d.ncomp]) |*c| {
            c.blocks_per_line = d.mcus_x * c.h;
            c.blocks_per_column = d.mcus_y * c.v;
            c.coefs = try d.gpa.alloc(i16, c.blocks_per_line * c.blocks_per_column * 64);
            @memset(c.coefs, 0);
        }
    }

    fn block(c: *Component, row: usize, col: usize) *[64]i16 {
        return c.coefs[(row * c.blocks_per_line + col) * 64 ..][0..64];
    }

    fn decodeBlock(d: *Decoder, r: *BitReader, c: *Component, b: *[64]i16, ss: u8, se: u8, ah: u8, al: u5) !void {
        if (!d.progressive) {
            const t = try r.decode(&d.dc[c.td]);
            c.dc_pred += r.receiveExtend(@intCast(t & 15));
            b[0] = @truncate(c.dc_pred);
            var k: usize = 1;
            while (k < 64) {
                const rs = try r.decode(&d.ac[c.ta]);
                const run = rs >> 4;
                const s: u5 = @intCast(rs & 15);
                if (s == 0) {
                    if (run != 15) break;
                    k += 16;
                    continue;
                }
                k += run;
                if (k > 63) return error.InvalidJpegData;
                b[zigzag[k]] = @truncate(r.receiveExtend(s));
                k += 1;
            }
            return;
        }
        if (ss == 0) {
            // Progressive DC (spectral selection is DC only).
            if (ah == 0) {
                const t = try r.decode(&d.dc[c.td]);
                c.dc_pred += r.receiveExtend(@intCast(t & 15));
                b[0] = @truncate(c.dc_pred * (@as(i32, 1) << al));
            } else if (r.bit() != 0) b[0] |= @as(i16, 1) << @intCast(al);
            return;
        }
        if (ah == 0) return d.acFirst(r, c, b, ss, se, al);
        return d.acRefine(r, c, b, ss, se, al);
    }

    fn acFirst(d: *Decoder, r: *BitReader, c: *Component, b: *[64]i16, ss: u8, se: u8, al: u5) !void {
        if (d.eobrun > 0) {
            d.eobrun -= 1;
            return;
        }
        var k: usize = ss;
        while (k <= se) {
            const rs = try r.decode(&d.ac[c.ta]);
            const run = rs >> 4;
            const s: u5 = @intCast(rs & 15);
            if (s == 0) {
                if (run < 15) {
                    d.eobrun = (@as(u32, 1) << @intCast(run)) - 1;
                    if (run > 0) d.eobrun += r.bits(@intCast(run));
                    break;
                }
                k += 16;
                continue;
            }
            k += run;
            if (k > 63) return error.InvalidJpegData;
            b[zigzag[k]] = @truncate(r.receiveExtend(s) * (@as(i32, 1) << al));
            k += 1;
        }
    }

    /// Successive-approximation AC refinement (libjpeg `decode_mcu_AC_refine`).
    fn acRefine(d: *Decoder, r: *BitReader, c: *Component, b: *[64]i16, ss: u8, se: u8, al: u5) !void {
        const p1: i16 = @as(i16, 1) << @intCast(al);
        const m1: i16 = -p1;
        var k: usize = ss;
        if (d.eobrun == 0) {
            while (k <= se) : (k += 1) {
                const rs = try r.decode(&d.ac[c.ta]);
                var run: i32 = rs >> 4;
                const s_bits = rs & 15;
                var s: i16 = 0;
                if (s_bits != 0) {
                    if (s_bits != 1) return error.InvalidJpegData;
                    s = if (r.bit() != 0) p1 else m1;
                } else if (run != 15) {
                    d.eobrun = @as(u32, 1) << @intCast(run);
                    if (run > 0) d.eobrun += r.bits(@intCast(run));
                    break;
                }
                while (k <= se) : (k += 1) {
                    const z = zigzag[k];
                    if (b[z] != 0) {
                        if (r.bit() != 0 and (b[z] & p1) == 0) b[z] += if (b[z] >= 0) p1 else m1;
                    } else {
                        run -= 1;
                        if (run < 0) break;
                    }
                }
                if (s != 0 and k <= se) b[zigzag[k]] = s;
            }
        }
        if (d.eobrun > 0) {
            while (k <= se) : (k += 1) {
                const z = zigzag[k];
                if (b[z] != 0 and r.bit() != 0 and (b[z] & p1) == 0) b[z] += if (b[z] >= 0) p1 else m1;
            }
            d.eobrun -= 1;
        }
    }

    /// Decodes one scan; returns the position after its entropy-coded data.
    fn scan(d: *Decoder, bytes: []const u8, header: []const u8, start: usize) !usize {
        const n = header[0];
        if (n == 0 or n > 4 or header.len < 1 + @as(usize, n) * 2 + 3) return error.InvalidJpeg;
        var comps: [4]*Component = undefined;
        for (0..n) |i| {
            const id = header[1 + i * 2];
            const tables = header[2 + i * 2];
            comps[i] = for (d.components[0..d.ncomp]) |*c| {
                if (c.id == id) break c;
            } else return error.InvalidJpeg;
            comps[i].td = tables >> 4;
            comps[i].ta = tables & 15;
            if (comps[i].td > 3 or comps[i].ta > 3) return error.InvalidJpeg;
        }
        const tail = header[1 + @as(usize, n) * 2 ..];
        const ss = tail[0];
        const se = tail[1];
        const ah = tail[2] >> 4;
        const al: u5 = @intCast(tail[2] & 15);
        if (se > 63 or ss > se) return error.InvalidJpeg;
        // Sequential scans need both tables; progressive DC-first needs DC, AC scans AC.
        const need_dc = !d.progressive or (ss == 0 and ah == 0);
        const need_ac = !d.progressive or ss > 0;
        for (comps[0..n]) |c| {
            c.dc_pred = 0;
            if ((need_dc and !d.dc[c.td].present) or (need_ac and !d.ac[c.ta].present)) return error.MissingHuffmanTable;
        }
        d.eobrun = 0;
        var r: BitReader = .{ .data = bytes, .pos = start };
        const interval: usize = d.restart_interval;
        var mcu: usize = 0;
        if (n == 1) {
            // Non-interleaved: walk the component's own block grid.
            const c = comps[0];
            const w = (((@as(usize, d.width) * c.h + d.hmax - 1) / d.hmax) + 7) / 8;
            const h = (((@as(usize, d.height) * c.v + d.vmax - 1) / d.vmax) + 7) / 8;
            for (0..h) |row| for (0..w) |col| {
                if (interval > 0 and mcu > 0 and mcu % interval == 0) try d.resync(&r, comps[0..n]);
                try d.decodeBlock(&r, c, block(c, row, col), ss, se, ah, al);
                mcu += 1;
            };
        } else {
            for (0..d.mcus_y) |my| for (0..d.mcus_x) |mx| {
                if (interval > 0 and mcu > 0 and mcu % interval == 0) try d.resync(&r, comps[0..n]);
                for (comps[0..n]) |c| {
                    for (0..c.v) |by| for (0..c.h) |bx| {
                        try d.decodeBlock(&r, c, block(c, my * c.v + by, mx * c.h + bx), ss, se, ah, al);
                    };
                }
                mcu += 1;
            };
        }
        // Find the marker that ends the scan.
        var pos = r.pos;
        while (pos + 1 < bytes.len) : (pos += 1) {
            if (bytes[pos] == 0xff and bytes[pos + 1] != 0 and !(bytes[pos + 1] >= 0xd0 and bytes[pos + 1] <= 0xd7)) return pos;
        }
        return bytes.len;
    }
    fn resync(d: *Decoder, r: *BitReader, comps: []*Component) !void {
        try r.restart();
        for (comps) |c| c.dc_pred = 0;
        d.eobrun = 0;
    }

    /// Dequantise and inverse-DCT every block into the component planes.
    fn reconstruct(d: *Decoder) !void {
        var table: [8][8]f32 = undefined;
        for (0..8) |x| for (0..8) |u| {
            const cu: f32 = if (u == 0) std.math.sqrt1_2 else 1;
            table[x][u] = cu / 2 * @cos(@as(f32, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16);
        };
        for (d.components[0..d.ncomp]) |*c| {
            const stride = c.blocks_per_line * 8;
            c.plane = try d.gpa.alloc(u8, stride * c.blocks_per_column * 8);
            const q = &d.quant[c.tq];
            for (0..c.blocks_per_column) |row| for (0..c.blocks_per_line) |col| {
                const coefs = block(c, row, col);
                const out_base = (row * 8) * stride + col * 8;
                // Most blocks carry only a DC term: fill instead of transforming.
                var ac_zero = true;
                for (coefs[1..]) |v| if (v != 0) {
                    ac_zero = false;
                    break;
                };
                if (ac_zero) {
                    const dc = @as(f32, @floatFromInt(coefs[0])) * @as(f32, @floatFromInt(q[0])) / 8;
                    const value: u8 = @intFromFloat(std.math.clamp(@round(dc + 128), 0, 255));
                    for (0..8) |y| @memset(c.plane[out_base + y * stride ..][0..8], value);
                    continue;
                }
                var f: [64]f32 = undefined;
                for (0..64) |i| f[zigzag[i]] = @as(f32, @floatFromInt(coefs[zigzag[i]])) * @as(f32, @floatFromInt(q[i]));
                // Rows then columns; rows without AC terms are constant.
                var tmp: [64]f32 = undefined;
                for (0..8) |y| {
                    const r = f[y * 8 ..][0..8];
                    var row_ac_zero = true;
                    for (r[1..]) |v| if (v != 0) {
                        row_ac_zero = false;
                    };
                    if (row_ac_zero) {
                        @memset(tmp[y * 8 ..][0..8], r[0] * table[0][0]);
                        continue;
                    }
                    for (0..8) |x| {
                        var sum: f32 = 0;
                        for (0..8) |u| sum += table[x][u] * r[u];
                        tmp[y * 8 + x] = sum;
                    }
                }
                for (0..8) |x| for (0..8) |y| {
                    var s: f32 = 0;
                    for (0..8) |v| s += table[y][v] * tmp[v * 8 + x];
                    const value = std.math.clamp(@round(s + 128), 0, 255);
                    c.plane[out_base + y * stride + x] = @intFromFloat(value);
                };
            };
        }
    }

    /// Centred bilinear sampling positions for one axis of a subsampled component.
    const Axis = struct {
        i0: []u32,
        i1: []u32,
        t: []f32,
        fn init(gpa: std.mem.Allocator, out_len: usize, factor: u8, max: u8) !Axis {
            const comp_len = (out_len * factor + max - 1) / max;
            var axis: Axis = .{ .i0 = try gpa.alloc(u32, out_len), .i1 = try gpa.alloc(u32, out_len), .t = try gpa.alloc(f32, out_len) };
            for (0..out_len) |i| {
                const pos = (@as(f32, @floatFromInt(i)) + 0.5) * @as(f32, @floatFromInt(factor)) / @as(f32, @floatFromInt(max)) - 0.5;
                const clamped = std.math.clamp(pos, 0, @as(f32, @floatFromInt(comp_len - 1)));
                const lo: usize = @intFromFloat(@floor(clamped));
                axis.i0[i] = @intCast(lo);
                axis.i1[i] = @intCast(@min(lo + 1, comp_len - 1));
                axis.t[i] = clamped - @as(f32, @floatFromInt(lo));
            }
            return axis;
        }
        fn deinit(axis: Axis, gpa: std.mem.Allocator) void {
            gpa.free(axis.i0);
            gpa.free(axis.i1);
            gpa.free(axis.t);
        }
    };

    /// Upsamples every component to full resolution (one byte per pixel).
    fn fullPlanes(d: *Decoder) ![4][]u8 {
        var planes: [4][]u8 = .{ &.{}, &.{}, &.{}, &.{} };
        errdefer for (planes) |p| d.gpa.free(p);
        const w: usize = d.width;
        const h: usize = d.height;
        for (d.components[0..d.ncomp], 0..) |*c, ci| {
            const plane = try d.gpa.alloc(u8, w * h);
            planes[ci] = plane;
            const stride = c.blocks_per_line * 8;
            if (c.h == d.hmax and c.v == d.vmax) {
                for (0..h) |y| @memcpy(plane[y * w ..][0..w], c.plane[y * stride ..][0..w]);
                continue;
            }
            const xs = try Axis.init(d.gpa, w, c.h, d.hmax);
            defer xs.deinit(d.gpa);
            const ys = try Axis.init(d.gpa, h, c.v, d.vmax);
            defer ys.deinit(d.gpa);
            for (0..h) |y| {
                const r0 = c.plane[ys.i0[y] * stride ..];
                const r1 = c.plane[ys.i1[y] * stride ..];
                const ty = ys.t[y];
                for (0..w) |x| {
                    const tx = xs.t[x];
                    const top = @as(f32, @floatFromInt(r0[xs.i0[x]])) * (1 - tx) + @as(f32, @floatFromInt(r0[xs.i1[x]])) * tx;
                    const bottom = @as(f32, @floatFromInt(r1[xs.i0[x]])) * (1 - tx) + @as(f32, @floatFromInt(r1[xs.i1[x]])) * tx;
                    plane[y * w + x] = @intFromFloat(@round(top * (1 - ty) + bottom * ty));
                }
            }
        }
        return planes;
    }

    fn output(d: *Decoder) !Image {
        var out = try Image.init(d.gpa, d.width, d.height);
        errdefer out.deinit();
        // Adobe transform 0 = RGB/CMYK as stored; 1 = YCbCr; 2 = YCCK. Without Adobe,
        // three components are YCbCr (JFIF) unless their ids spell "RGB".
        const rgb_ids = d.ncomp == 3 and d.components[0].id == 'R' and d.components[1].id == 'G' and d.components[2].id == 'B';
        const transform: u8 = d.adobe_transform orelse if (d.ncomp == 3 and !rgb_ids) 1 else if (d.ncomp == 4) 0 else 0;
        const clamp = struct {
            fn f(v: f32) u8 {
                return @intFromFloat(std.math.clamp(@round(v), 0, 255));
            }
        }.f;
        const planes = try d.fullPlanes();
        defer for (planes) |p| d.gpa.free(p);
        for (0..@as(usize, d.height) * d.width) |i| {
            const px = out.pixels[i * 4 ..][0..4];
            switch (d.ncomp) {
                1 => {
                    const g = clamp(@as(f32, @floatFromInt(planes[0][i])));
                    px.* = .{ g, g, g, 255 };
                },
                3 => {
                    const a = @as(f32, @floatFromInt(planes[0][i]));
                    const b = @as(f32, @floatFromInt(planes[1][i]));
                    const c = @as(f32, @floatFromInt(planes[2][i]));
                    px.* = if (transform == 0) .{ clamp(a), clamp(b), clamp(c), 255 } else .{
                        clamp(a + 1.402 * (c - 128)),
                        clamp(a - 0.344136 * (b - 128) - 0.714136 * (c - 128)),
                        clamp(a + 1.772 * (b - 128)),
                        255,
                    };
                },
                4 => {
                    var cc = @as(f32, @floatFromInt(planes[0][i]));
                    var mm = @as(f32, @floatFromInt(planes[1][i]));
                    var yy = @as(f32, @floatFromInt(planes[2][i]));
                    const k = @as(f32, @floatFromInt(planes[3][i]));
                    if (transform == 2) {
                        const r = cc + 1.402 * (yy - 128);
                        const g = cc - 0.344136 * (mm - 128) - 0.714136 * (yy - 128);
                        const b = cc + 1.772 * (mm - 128);
                        cc = 255 - r;
                        mm = 255 - g;
                        yy = 255 - b;
                    }
                    // Adobe stores inverted CMYK.
                    px.* = .{ clamp(cc * k / 255), clamp(mm * k / 255), clamp(yy * k / 255), 255 };
                },
                else => return error.UnsupportedJpeg,
            }
        }
        return out;
    }
};

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (!isJpeg(bytes)) return error.InvalidJpeg;
    var d: Decoder = .{ .gpa = gpa };
    defer d.deinit();
    var pos: usize = 2;
    var have_frame = false;
    while (pos + 4 <= bytes.len) {
        if (bytes[pos] != 0xff) {
            pos += 1;
            continue;
        }
        const marker = bytes[pos + 1];
        if (marker == 0xff) {
            pos += 1;
            continue;
        }
        if (marker == 0xd9) break; // EOI
        if (marker >= 0xd0 and marker <= 0xd7) {
            pos += 2;
            continue;
        }
        const len = std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .big);
        if (len < 2 or pos + 2 + len > bytes.len) return error.TruncatedJpeg;
        const data = bytes[pos + 4 .. pos + 2 + len];
        const next = pos + 2 + len;
        switch (marker) {
            0xc0, 0xc1, 0xc2 => {
                if (have_frame) return error.InvalidJpeg;
                d.progressive = marker == 0xc2;
                try d.frame(data);
                have_frame = true;
            },
            0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => return error.UnsupportedJpeg,
            0xc4 => {
                var p: usize = 0;
                while (p + 17 <= data.len) {
                    const class = data[p] >> 4;
                    const id = data[p] & 15;
                    if (id > 3 or class > 1) return error.InvalidJpeg;
                    const counts = data[p + 1 ..][0..16].*;
                    var total: usize = 0;
                    for (counts) |c| total += c;
                    if (total > 256 or p + 17 + total > data.len) return error.InvalidJpeg;
                    const table = try Huffman.build(counts, data[p + 17 ..][0..total]);
                    if (class == 0) d.dc[id] = table else d.ac[id] = table;
                    p += 17 + total;
                }
            },
            0xdb => {
                var p: usize = 0;
                while (p < data.len) {
                    const precision = data[p] >> 4;
                    const id = data[p] & 15;
                    if (id > 3) return error.InvalidJpeg;
                    p += 1;
                    for (0..64) |i| {
                        if (precision == 0) {
                            if (p >= data.len) return error.InvalidJpeg;
                            d.quant[id][i] = data[p];
                            p += 1;
                        } else {
                            if (p + 2 > data.len) return error.InvalidJpeg;
                            d.quant[id][i] = std.mem.readInt(u16, data[p..][0..2], .big);
                            p += 2;
                        }
                    }
                }
            },
            0xdd => {
                if (data.len < 2) return error.InvalidJpeg;
                d.restart_interval = std.mem.readInt(u16, data[0..2], .big);
            },
            0xda => {
                if (!have_frame) return error.InvalidJpeg;
                pos = try d.scan(bytes, data, next);
                continue;
            },
            0xee => if (data.len >= 12 and std.mem.eql(u8, data[0..5], "Adobe")) {
                d.adobe_transform = data[11];
            },
            0xe0 => if (data.len >= 5 and std.mem.eql(u8, data[0..5], "JFIF\x00")) {
                d.jfif = true;
            },
            else => {},
        }
        pos = next;
    }
    if (!have_frame) return error.InvalidJpeg;
    try d.reconstruct();
    return d.output();
}
