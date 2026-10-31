//! Bounded SDL GPU renderer. Glyphs that do not fit the atlas are skipped.
const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;
const Face = @import("../platform/font.zig").Face;
const assets = @import("assets");
extern fn zid_svg_alpha([*]const u8, usize, c_int, [*]u8) c_int;
const FontStyle = enum(u8) { mono, italic, ui };
const side = 1024;
const max_vertices = 196608;
const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32, color: [4]u8 };
const Glyph = struct { style: FontStyle = .mono, index: u32 = 0, stamp: u32 = 0, valid: bool = false, left: i32 = 0, top: i32 = 0, w: u32 = 0, h: u32 = 0 };
const Icon = struct { hash: u64 = 0, len: usize = 0, size: u8 = 0, stamp: u32 = 0, valid: bool = false };
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: sdl.video.Window,
    device: gpu.Device,
    pipeline: gpu.GraphicsPipeline,
    erase_pipeline: gpu.GraphicsPipeline,
    atlas: gpu.Texture,
    sampler: gpu.Sampler,
    vertices: gpu.Buffer,
    transfer: gpu.TransferBuffer,
    face: Face,
    italic_face: Face,
    ui_face: Face,
    pixels: []u8,
    cpu: []Vertex,
    glyphs: [384]Glyph = @splat(.{}),
    icons: [256]Icon = @splat(.{}),
    radius: f32 = 0,
    count: usize = 0,
    vertex_limit: usize = max_vertices,
    frame: u32 = 0,
    active: bool = false,
    degraded: bool = false,
    clip: ?sdl.rect.IRect = null,
    w: f32 = 0,
    h: f32 = 0,
    pub fn init(a: std.mem.Allocator, window: sdl.video.Window) !Renderer {
        return initSized(a, window, 15);
    }
    pub fn initSized(a: std.mem.Allocator, window: sdl.video.Window, size: u32) !Renderer {
        const pixels = try a.alloc(u8, side * side);
        errdefer a.free(pixels);
        @memset(pixels, 0);
        pixels[0] = 255;
        const cpu = try a.alloc(Vertex, max_vertices);
        errdefer a.free(cpu);
        const face = try Face.init(size);
        errdefer face.deinit();
        const italic_face = try Face.initBytes(if (@hasDecl(assets, "mono_italic")) assets.mono_italic else assets.mono, size);
        errdefer italic_face.deinit();
        const ui_face = try Face.initBytes(if (@hasDecl(assets, "ui")) assets.ui else assets.mono, 16);
        errdefer ui_face.deinit();
        const device = try gpu.Device.init(.{ .spirv = true }, false, "vulkan");
        errdefer device.deinit();
        try device.claimWindow(window);
        errdefer device.releaseWindow(window);
        const vs = try device.createShader(.{ .code = @embedFile("ui.vert.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .vertex });
        defer device.releaseShader(vs);
        const fs = try device.createShader(.{ .code = @embedFile("ui.frag.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .fragment, .num_samplers = 1 });
        defer device.releaseShader(fs);
        const vb = [_]gpu.VertexBufferDescription{.{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = .vertex }};
        const va = [_]gpu.VertexAttribute{ .{ .location = 0, .buffer_slot = 0, .format = .f32x2, .offset = 0 }, .{ .location = 1, .buffer_slot = 0, .format = .f32x2, .offset = 8 }, .{ .location = 2, .buffer_slot = 0, .format = .u8x4_normalized, .offset = 16 } };
        const targets = [_]gpu.ColorTargetDescription{.{ .format = try device.getSwapchainTextureFormat(window), .blend_state = .{ .enable_blend = true, .source_color = .src_alpha, .destination_color = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } }};
        const pipeline = try device.createGraphicsPipeline(.{ .vertex_shader = vs, .fragment_shader = fs, .vertex_input_state = .{ .vertex_buffer_descriptions = &vb, .vertex_attributes = &va }, .target_info = .{ .color_target_descriptions = &targets } });
        errdefer device.releaseGraphicsPipeline(pipeline);
        const erase_vs = try device.createShader(.{ .code = @embedFile("erase.vert.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .vertex });
        defer device.releaseShader(erase_vs);
        const erase_fs = try device.createShader(.{ .code = @embedFile("erase.frag.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .fragment, .num_uniform_buffers = 1 });
        defer device.releaseShader(erase_fs);
        const erase_targets = [_]gpu.ColorTargetDescription{.{ .format = try device.getSwapchainTextureFormat(window), .blend_state = .{ .enable_blend = true, .source_color = .zero, .destination_color = .src_alpha, .source_alpha = .zero, .destination_alpha = .src_alpha } }};
        const erase_pipeline = try device.createGraphicsPipeline(.{ .vertex_shader = erase_vs, .fragment_shader = erase_fs, .target_info = .{ .color_target_descriptions = &erase_targets } });
        errdefer device.releaseGraphicsPipeline(erase_pipeline);
        const atlas = try device.createTexture(.{ .format = .r8_unorm, .usage = .{ .sampler = true }, .width = side, .height = side });
        errdefer device.releaseTexture(atlas);
        const sampler = try device.createSampler(.{ .address_mode_u = .clamp_to_edge, .address_mode_v = .clamp_to_edge });
        errdefer device.releaseSampler(sampler);
        const vertices = try device.createBuffer(.{ .usage = .{ .vertex = true }, .size = max_vertices * @sizeOf(Vertex) });
        errdefer device.releaseBuffer(vertices);
        const transfer = try device.createTransferBuffer(.{ .usage = .upload, .size = side * side + max_vertices * @sizeOf(Vertex) });
        errdefer device.releaseTransferBuffer(transfer);
        return .{ .allocator = a, .window = window, .device = device, .pipeline = pipeline, .erase_pipeline = erase_pipeline, .atlas = atlas, .sampler = sampler, .vertices = vertices, .transfer = transfer, .face = face, .italic_face = italic_face, .ui_face = ui_face, .pixels = pixels, .cpu = cpu };
    }
    pub fn deinit(self: *Renderer) void {
        self.device.waitForIdle() catch {};
        self.device.releaseTransferBuffer(self.transfer);
        self.device.releaseBuffer(self.vertices);
        self.device.releaseSampler(self.sampler);
        self.device.releaseTexture(self.atlas);
        self.device.releaseGraphicsPipeline(self.erase_pipeline);
        self.device.releaseGraphicsPipeline(self.pipeline);
        self.device.releaseWindow(self.window);
        self.device.deinit();
        self.face.deinit();
        self.italic_face.deinit();
        self.ui_face.deinit();
        self.allocator.free(self.pixels);
        self.allocator.free(self.cpu);
        self.* = undefined;
    }
    pub fn begin(self: *Renderer, w: u32, h: u32) !void {
        if (self.active or w == 0 or h == 0) return error.BeginFrameFailed;
        self.w = @floatFromInt(w);
        self.h = @floatFromInt(h);
        self.count = 0;
        self.vertex_limit = max_vertices;
        self.degraded = false;
        self.clip = null;
        self.radius = 0;
        self.active = true;
        self.frame +%= 1;
        if (self.frame == 0) {
            self.frame = 1;
            for (&self.glyphs) |*g| g.stamp = 0;
            for (&self.icons) |*icon_entry| icon_entry.stamp = 0;
        }
    }
    pub fn setClip(self: *Renderer, clip: ?sdl.rect.IRect) void {
        self.clip = clip;
    }
    fn quad(self: *Renderer, x: f32, y: f32, w: f32, h: f32, u: f32, v: f32, uw: f32, vh: f32, color: [4]u8) !void {
        if (!self.active) return error.BeginFrameFailed;
        if (w <= 0 or h <= 0) return;
        if (self.count + 6 > self.vertex_limit) {
            self.degraded = true;
            return;
        }
        var l: f32 = 0;
        var t: f32 = 0;
        var r = self.w;
        var b = self.h;
        if (self.clip) |c| {
            l = @max(l, @as(f32, @floatFromInt(c.x)));
            t = @max(t, @as(f32, @floatFromInt(c.y)));
            r = @min(r, @as(f32, @floatFromInt(c.x)) + @as(f32, @floatFromInt(c.w)));
            b = @min(b, @as(f32, @floatFromInt(c.y)) + @as(f32, @floatFromInt(c.h)));
        }
        const x1 = @max(x, l);
        const y1 = @max(y, t);
        const x2 = @min(x + w, r);
        const y2 = @min(y + h, b);
        if (x2 <= x1 or y2 <= y1) return;
        const xs = [_]f32{ 2 * x1 / self.w - 1, 2 * x2 / self.w - 1 };
        const ys = [_]f32{ 1 - 2 * y1 / self.h, 1 - 2 * y2 / self.h };
        const us = [_]f32{ u + (x1 - x) / w * uw, u + (x2 - x) / w * uw };
        const vs = [_]f32{ v + (y1 - y) / h * vh, v + (y2 - y) / h * vh };
        const ix = [_]usize{ 0, 1, 1, 0, 1, 0 };
        const iy = [_]usize{ 0, 0, 1, 0, 1, 1 };
        for (0..6) |i| self.cpu[self.count + i] = .{ .x = xs[ix[i]], .y = ys[iy[i]], .u = us[ix[i]], .v = vs[iy[i]], .color = color };
        self.count += 6;
    }
    pub fn rect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, color: [4]u8) !void {
        try self.quad(x, y, w, h, 0.5 / 1024.0, 0.5 / 1024.0, 0, 0, color);
    }
    fn glyph(self: *Renderer, style: FontStyle, face: Face, index: u32) ?usize {
        var slot: ?usize = null;
        for (1..self.glyphs.len) |i| {
            const g = &self.glyphs[i];
            if (g.valid and g.index == index and g.style == style) {
                g.stamp = self.frame;
                return i;
            }
            if (slot == null and g.stamp != self.frame) slot = i;
        }
        const i = slot orelse return null;
        const bitmap = face.bitmap(index) orelse return null;
        if (bitmap.width < 0 or bitmap.height < 0 or bitmap.width > 32 or bitmap.height > 64 or (bitmap.width > 0 and bitmap.height > 0 and bitmap.gray == 0)) return null;
        const w: usize = @intCast(bitmap.width);
        const h: usize = @intCast(bitmap.height);
        const sx = (i % 32) * 32;
        const sy = (i / 32) * 64;
        for (0..64) |row| @memset(self.pixels[(sy + row) * side + sx ..][0..32], 0);
        if (w > 0 and h > 0) {
            const src = bitmap.pixels orelse return null;
            const pitch: usize = @intCast(@abs(bitmap.pitch));
            for (0..h) |row| @memcpy(self.pixels[(sy + row) * side + sx ..][0..w], src[(if (bitmap.pitch < 0) h - 1 - row else row) * pitch ..][0..w]);
        }
        self.glyphs[i] = .{ .style = style, .index = index, .stamp = self.frame, .valid = true, .left = bitmap.left, .top = bitmap.top, .w = @intCast(w), .h = @intCast(h) };
        return i;
    }
    fn drawText(self: *Renderer, style: FontStyle, value: []const u8, x: f32, baseline: f32, color: [4]u8, draw: bool) !f32 {
        if (draw and !self.active) return error.BeginFrameFailed;
        const face = switch (style) {
            .mono => self.face,
            .italic => self.italic_face,
            .ui => self.ui_face,
        };
        var pen: f32 = 0;
        var off: usize = 0;
        while (off < value.len) {
            if (value[off] == '\t') {
                const tab = face.space() * 4;
                pen = (@floor(pen / tab) + 1) * tab;
                off += 1;
                continue;
            }
            const segment_end = off + (std.mem.indexOfScalar(u8, value[off..], '\t') orelse value.len - off);
            try face.shape(value[off..segment_end]);
            for (0..face.count()) |i| {
                const p = face.position(@intCast(i));
                if (draw) if (self.glyph(style, face, p.index)) |slot| {
                    const g = self.glyphs[slot];
                    try self.quad(x + pen + @as(f32, @floatFromInt(p.x_offset)) / 64 + @as(f32, @floatFromInt(g.left)), baseline - @as(f32, @floatFromInt(p.y_offset)) / 64 - @as(f32, @floatFromInt(g.top)), @floatFromInt(g.w), @floatFromInt(g.h), @as(f32, @floatFromInt((slot % 32) * 32)) / side, @as(f32, @floatFromInt((slot / 32) * 64)) / side, @as(f32, @floatFromInt(g.w)) / side, @as(f32, @floatFromInt(g.h)) / side, color);
                } else {
                    // A visible replacement preserves the advance and lets the
                    // editing session continue if a font or atlas limit is hit.
                    self.degraded = true;
                    const gx = x + pen + 1;
                    const gh = face.space() * 1.3;
                    const gw = @max(3, @as(f32, @floatFromInt(p.x_advance)) / 64 - 2);
                    try self.rect(gx, baseline - gh, gw, 1, color);
                    try self.rect(gx, baseline - gh, 1, gh, color);
                    try self.rect(gx + gw - 1, baseline - gh, 1, gh, color);
                    try self.rect(gx, baseline - 1, gw, 1, color);
                };
                pen += @as(f32, @floatFromInt(p.x_advance)) / 64;
            }
            off = segment_end;
        }
        return pen;
    }
    pub fn text(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.mono, value, x, baseline, color, true);
    }
    pub fn width(self: *Renderer, value: []const u8) f32 {
        return self.drawText(.mono, value, 0, 0, undefined, false) catch 0;
    }
    pub fn textUi(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.ui, value, x, baseline, color, true);
    }
    pub fn textItalic(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.italic, value, x, baseline, color, true);
    }
    pub fn widthUi(self: *Renderer, value: []const u8) f32 {
        return self.drawText(.ui, value, 0, 0, undefined, false) catch 0;
    }
    /// Set once per frame after begin; pass zero for a maximized window.
    pub fn roundWindow(self: *Renderer, radius: f32) void {
        self.radius = if (std.math.isFinite(radius)) @max(0, radius) else 0;
    }
    /// Monochrome SVG mask, tinted at draw time; raster size is limited to 32px.
    /// Content hashes keep the cache independent of source buffer lifetime.
    pub fn icon(self: *Renderer, svg: []const u8, x: f32, y: f32, size: f32, color: [4]u8) !void {
        if (!self.active) return error.BeginFrameFailed;
        if (!std.math.isFinite(size) or size <= 0 or size > 32) return error.InvalidIconSize;
        const n: u8 = @intFromFloat(@max(1, @round(size)));
        const hash = std.hash.Wyhash.hash(0, svg);
        var slot: ?usize = null;
        var vacant: ?usize = null;
        for (&self.icons, 0..) |*entry, i| {
            if (entry.valid and entry.hash == hash and entry.len == svg.len and entry.size == n) {
                slot = i;
                break;
            }
            if (vacant == null and entry.stamp != self.frame) vacant = i;
        }
        const i = slot orelse vacant orelse {
            self.degraded = true;
            return;
        };
        const sx = (i % 32) * 32;
        const sy = 768 + (i / 32) * 32;
        if (slot == null) {
            var mask: [32 * 32]u8 = undefined;
            if (zid_svg_alpha(svg.ptr, svg.len, n, &mask) == 0) return error.SvgParse;
            for (0..32) |row| @memset(self.pixels[(sy + row) * side + sx ..][0..32], 0);
            for (0..n) |row| @memcpy(self.pixels[(sy + row) * side + sx ..][0..n], mask[row * n ..][0..n]);
            self.icons[i] = .{ .hash = hash, .len = svg.len, .size = n, .valid = true };
        }
        self.icons[i].stamp = self.frame;
        try self.quad(@round(x), @round(y), size, size, @as(f32, @floatFromInt(sx)) / side, @as(f32, @floatFromInt(sy)) / side, @as(f32, @floatFromInt(n)) / side, @as(f32, @floatFromInt(n)) / side, color);
    }
    /// Reserve 4096 quads for status, caret and save/discard overlays. Dense
    /// document content may degrade, but must never consume the modal budget.
    pub fn reserveOverlay(self: *Renderer) void {
        self.vertex_limit = max_vertices - 4096 * 6;
    }
    pub fn drawOverlay(self: *Renderer) void {
        self.vertex_limit = max_vertices;
    }
    pub fn abortFrame(self: *Renderer) void {
        self.active = false;
    }
    pub fn end(self: *Renderer) !void {
        if (!self.active) return error.BeginFrameFailed;
        self.active = false;
        const cmd = try self.device.acquireCommandBuffer();
        errdefer cmd.cancel() catch {};
        const swap = (try cmd.waitAndAcquireSwapchainTexture(self.window))[0] orelse {
            try cmd.submit();
            return;
        };
        const mapped = try self.device.mapTransferBuffer(self.transfer, true);
        @memcpy(mapped[0 .. side * side], self.pixels);
        const bytes = std.mem.sliceAsBytes(self.cpu[0..self.count]);
        @memcpy(mapped[side * side ..][0..bytes.len], bytes);
        self.device.unmapTransferBuffer(self.transfer);
        const copy = cmd.beginCopyPass();
        copy.uploadToTexture(.{ .transfer_buffer = self.transfer, .offset = 0, .pixels_per_row = side, .rows_per_layer = side }, .{ .texture = self.atlas, .width = side, .height = side, .depth = 1 }, true);
        if (self.count > 0) copy.uploadToBuffer(.{ .transfer_buffer = self.transfer, .offset = side * side }, .{ .buffer = self.vertices, .offset = 0, .size = @intCast(bytes.len) }, true);
        copy.end();
        const targets = [_]gpu.ColorTargetInfo{.{ .texture = swap, .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .load = .clear, .store = .store }};
        const pass = cmd.beginRenderPass(&targets, null);
        pass.bindGraphicsPipeline(self.pipeline);
        pass.bindVertexBuffers(0, &.{.{ .buffer = self.vertices, .offset = 0 }});
        pass.bindFragmentSamplers(0, &.{.{ .texture = self.atlas, .sampler = self.sampler }});
        if (self.count > 0) pass.drawPrimitives(@intCast(self.count), 1, 0, 0);
        if (self.radius > 0) {
            const params = [4]f32{ self.w, self.h, self.radius, 0 };
            cmd.pushFragmentUniformData(0, std.mem.asBytes(&params));
            pass.bindGraphicsPipeline(self.erase_pipeline);
            pass.drawPrimitives(3, 1, 0, 0);
        }
        pass.end();
        try cmd.submit();
    }
};
