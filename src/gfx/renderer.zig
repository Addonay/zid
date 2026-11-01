//! Bounded SDL GPU renderer. Glyphs that do not fit the atlas are skipped.
const std = @import("std");
const sdl = @import("sdl3");
const gpu = sdl.gpu;
const Face = @import("../platform/font.zig").Face;
const assets = @import("assets");
extern fn zid_svg_alpha([*]const u8, usize, c_int, [*]u8) c_int;
extern fn zid_svg_rgba([*]const u8, usize, c_int, [*]u8) c_int;
const FontStyle = enum(u8) { mono, italic, ui, ui_small, ui_small_italic, headline, headline_medium, ui_xsmall, mono_xsmall };
/// Fixed-size faces beyond the editor and primary UI faces (Zed `LabelSize` /
/// `HeadlineSize` steps). Indexed by `@intFromEnum(style) - first_extra`.
const ExtraFace = struct { style: FontStyle, px: u32, italic: bool = false, mono: bool = false };
const extra_faces = [_]ExtraFace{
    .{ .style = .ui_small_italic, .px = 12, .italic = true }, // LabelSize::Small italic
    .{ .style = .headline, .px = 16 }, // HeadlineSize::Small
    .{ .style = .headline_medium, .px = 18 }, // HeadlineSize::Medium (Headline default)
    .{ .style = .ui_xsmall, .px = 10 }, // LabelSize::XSmall
    .{ .style = .mono_xsmall, .px = 10, .mono = true }, // LabelSize::XSmall with buffer_font
};
const first_extra = @intFromEnum(FontStyle.ui_small_italic);
comptime {
    for (extra_faces, 0..) |entry, i| if (@intFromEnum(entry.style) != first_extra + i) @compileError("extra_faces order must follow FontStyle");
}
fn extraBytes(entry: ExtraFace) []const u8 {
    if (entry.mono) return assets.mono;
    if (entry.italic) return if (@hasDecl(assets, "ui_italic")) assets.ui_italic else assets.mono;
    return if (@hasDecl(assets, "ui")) assets.ui else assets.mono;
}
fn initExtras(scale_px: anytype, ctx: anytype) ![extra_faces.len]Face {
    var faces: [extra_faces.len]Face = undefined;
    var made: usize = 0;
    errdefer for (faces[0..made]) |f| f.deinit();
    for (extra_faces, 0..) |entry, i| {
        faces[i] = try Face.initBytes(extraBytes(entry), scale_px(ctx, entry.px));
        made += 1;
    }
    return faces;
}
const side = 1024;
const max_vertices = 196608;
/// Colored (multi-color icon theme) atlas: 16x16 cells of 32px RGBA.
const color_side = 512;
const color_bytes = color_side * color_side * 4;
/// Zed's default UI label size (`LabelSize::Default`, 14px) and `LabelSize::Small` (12px).
pub const ui_font_px = 14;
pub const ui_small_font_px = 12;
/// Zed `HeadlineSize::Small` (`rems(1.0)` = 16px).
const Vertex = extern struct { x: f32, y: f32, u: f32, v: f32, color: [4]u8 };
pub const ImageId = u32;
const GpuImage = struct { texture: ?gpu.Texture, width: u32, height: u32 };
const PendingUpload = struct { id: ImageId, transfer: gpu.TransferBuffer };
const Batch = struct { start: u32, image: ?ImageId };
const Glyph = struct { style: FontStyle = .mono, index: u32 = 0, stamp: u32 = 0, valid: bool = false, left: i32 = 0, top: i32 = 0, w: u32 = 0, h: u32 = 0 };
const Icon = struct { hash: u64 = 0, len: usize = 0, size: u8 = 0, stamp: u32 = 0, valid: bool = false };
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    window: sdl.video.Window,
    device: gpu.Device,
    format: gpu.TextureFormat = .b8g8r8a8_unorm,
    target: ?gpu.Texture = null,
    target_w: u32 = 0,
    target_h: u32 = 0,
    pipeline: gpu.GraphicsPipeline,
    erase_pipeline: gpu.GraphicsPipeline,
    atlas: gpu.Texture,
    sampler: gpu.Sampler,
    /// Linear sampler for images (scaled photos, avatars).
    image_sampler: gpu.Sampler,
    /// 1x1 texture bound to the image slot when no image is drawn.
    no_image: gpu.Texture,
    images: std.ArrayList(GpuImage) = .empty,
    pending_uploads: std.ArrayList(PendingUpload) = .empty,
    /// Vertex ranges that share one bound image (split only when the image changes).
    batches: std.ArrayList(Batch) = .empty,
    vertices: gpu.Buffer,
    transfer: gpu.TransferBuffer,
    face: Face,
    italic_face: Face,
    ui_face: Face,
    ui_small_face: Face,
    extra: [extra_faces.len]Face,
    pixels: []u8,
    cpu: []Vertex,
    glyphs: [384]Glyph = @splat(.{}),
    icons: [256]Icon = @splat(.{}),
    color_atlas: gpu.Texture,
    color_pixels: []u8,
    color_icons: [256]Icon = @splat(.{}),
    color_dirty: bool = true,
    radius: f32 = 0,
    count: usize = 0,
    vertex_limit: usize = max_vertices,
    frame: u32 = 0,
    active: bool = false,
    degraded: bool = false,
    clip: ?sdl.rect.IRect = null,
    /// Logical frame size; layout and input use logical units.
    w: f32 = 0,
    h: f32 = 0,
    /// Device pixels per logical unit. Glyphs and icons are rasterized at this density and
    /// snapped to the device grid, so text stays crisp on HiDPI and fractional scales.
    scale: f32 = 1,
    mono_size: u32 = 15,
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
        const ui_face = try Face.initBytes(if (@hasDecl(assets, "ui")) assets.ui else assets.mono, ui_font_px);
        errdefer ui_face.deinit();
        const ui_small_face = try Face.initBytes(if (@hasDecl(assets, "ui")) assets.ui else assets.mono, ui_small_font_px);
        errdefer ui_small_face.deinit();
        const extra = try initExtras(struct {
            fn f(_: void, logical: u32) u32 {
                return logical;
            }
        }.f, {});
        errdefer for (extra) |f| f.deinit();
        const device = try gpu.Device.init(.{ .spirv = true }, false, "vulkan");
        errdefer device.deinit();
        try device.claimWindow(window);
        errdefer device.releaseWindow(window);
        const vs = try device.createShader(.{ .code = @embedFile("ui.vert.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .vertex });
        defer device.releaseShader(vs);
        const fs = try device.createShader(.{ .code = @embedFile("ui.frag.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .fragment, .num_samplers = 3 });
        defer device.releaseShader(fs);
        const vb = [_]gpu.VertexBufferDescription{.{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = .vertex }};
        const va = [_]gpu.VertexAttribute{ .{ .location = 0, .buffer_slot = 0, .format = .f32x2, .offset = 0 }, .{ .location = 1, .buffer_slot = 0, .format = .f32x2, .offset = 8 }, .{ .location = 2, .buffer_slot = 0, .format = .u8x4_normalized, .offset = 16 } };
        const swap_format = try device.getSwapchainTextureFormat(window);
        const targets = [_]gpu.ColorTargetDescription{.{ .format = swap_format, .blend_state = .{ .enable_blend = true, .source_color = .src_alpha, .destination_color = .one_minus_src_alpha, .source_alpha = .one, .destination_alpha = .one_minus_src_alpha } }};
        const pipeline = try device.createGraphicsPipeline(.{ .vertex_shader = vs, .fragment_shader = fs, .vertex_input_state = .{ .vertex_buffer_descriptions = &vb, .vertex_attributes = &va }, .target_info = .{ .color_target_descriptions = &targets } });
        errdefer device.releaseGraphicsPipeline(pipeline);
        const erase_vs = try device.createShader(.{ .code = @embedFile("erase.vert.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .vertex });
        defer device.releaseShader(erase_vs);
        const erase_fs = try device.createShader(.{ .code = @embedFile("erase.frag.spv"), .entry_point = "main", .format = .{ .spirv = true }, .stage = .fragment, .num_uniform_buffers = 1 });
        defer device.releaseShader(erase_fs);
        const erase_targets = [_]gpu.ColorTargetDescription{.{ .format = swap_format, .blend_state = .{ .enable_blend = true, .source_color = .zero, .destination_color = .src_alpha, .source_alpha = .zero, .destination_alpha = .src_alpha } }};
        const erase_pipeline = try device.createGraphicsPipeline(.{ .vertex_shader = erase_vs, .fragment_shader = erase_fs, .target_info = .{ .color_target_descriptions = &erase_targets } });
        errdefer device.releaseGraphicsPipeline(erase_pipeline);
        const atlas = try device.createTexture(.{ .format = .r8_unorm, .usage = .{ .sampler = true }, .width = side, .height = side });
        errdefer device.releaseTexture(atlas);
        const color_atlas = try device.createTexture(.{ .format = .r8g8b8a8_unorm, .usage = .{ .sampler = true }, .width = color_side, .height = color_side });
        errdefer device.releaseTexture(color_atlas);
        const color_pixels = try a.alloc(u8, color_bytes);
        errdefer a.free(color_pixels);
        @memset(color_pixels, 0);
        const sampler = try device.createSampler(.{ .address_mode_u = .clamp_to_edge, .address_mode_v = .clamp_to_edge });
        errdefer device.releaseSampler(sampler);
        const image_sampler = try device.createSampler(.{ .address_mode_u = .clamp_to_edge, .address_mode_v = .clamp_to_edge, .min_filter = .linear, .mag_filter = .linear });
        errdefer device.releaseSampler(image_sampler);
        const no_image = try device.createTexture(.{ .format = .r8g8b8a8_unorm, .usage = .{ .sampler = true }, .width = 1, .height = 1 });
        errdefer device.releaseTexture(no_image);
        const vertices = try device.createBuffer(.{ .usage = .{ .vertex = true }, .size = max_vertices * @sizeOf(Vertex) });
        errdefer device.releaseBuffer(vertices);
        const transfer = try device.createTransferBuffer(.{ .usage = .upload, .size = side * side + color_bytes + max_vertices * @sizeOf(Vertex) });
        errdefer device.releaseTransferBuffer(transfer);
        return .{ .allocator = a, .window = window, .device = device, .format = swap_format, .pipeline = pipeline, .erase_pipeline = erase_pipeline, .atlas = atlas, .color_atlas = color_atlas, .color_pixels = color_pixels, .sampler = sampler, .image_sampler = image_sampler, .no_image = no_image, .vertices = vertices, .transfer = transfer, .face = face, .italic_face = italic_face, .ui_face = ui_face, .ui_small_face = ui_small_face, .extra = extra, .pixels = pixels, .cpu = cpu, .mono_size = size };
    }
    fn px(self: *const Renderer, logical: u32) u32 {
        return @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * self.scale))));
    }
    /// Replace the buffer (mono/italic) faces at a new logical size.
    pub fn setMonoSize(self: *Renderer, size: u32) !void {
        const face = try Face.init(self.px(size));
        errdefer face.deinit();
        const italic_face = try Face.initBytes(if (@hasDecl(assets, "mono_italic")) assets.mono_italic else assets.mono, self.px(size));
        self.face.deinit();
        self.italic_face.deinit();
        self.face = face;
        self.italic_face = italic_face;
        self.mono_size = size;
        for (&self.glyphs) |*g| if (g.style == .mono or g.style == .italic) {
            g.valid = false;
        };
    }
    /// Re-rasterize every face for a new device pixel density (window moved or scale changed).
    pub fn setScale(self: *Renderer, scale: f32) !void {
        if (!std.math.isFinite(scale) or scale <= 0 or scale == self.scale) return;
        const old = self.scale;
        self.scale = scale;
        errdefer self.scale = old;
        const ui_bytes = if (@hasDecl(assets, "ui")) assets.ui else assets.mono;
        const ui_face = try Face.initBytes(ui_bytes, self.px(ui_font_px));
        errdefer ui_face.deinit();
        const ui_small_face = try Face.initBytes(ui_bytes, self.px(ui_small_font_px));
        errdefer ui_small_face.deinit();
        const extra = try initExtras(struct {
            fn f(r: *Renderer, logical: u32) u32 {
                return r.px(logical);
            }
        }.f, self);
        errdefer for (extra) |f| f.deinit();
        try self.setMonoSize(self.mono_size);
        self.ui_face.deinit();
        self.ui_small_face.deinit();
        for (self.extra) |f| f.deinit();
        self.ui_face = ui_face;
        self.ui_small_face = ui_small_face;
        self.extra = extra;
        for (&self.glyphs) |*g| g.valid = false;
    }
    pub fn deinit(self: *Renderer) void {
        self.device.waitForIdle() catch {};
        if (self.target) |t| self.device.releaseTexture(t);
        self.device.releaseTransferBuffer(self.transfer);
        self.device.releaseBuffer(self.vertices);
        self.device.releaseSampler(self.sampler);
        self.device.releaseSampler(self.image_sampler);
        self.device.releaseTexture(self.no_image);
        for (self.images.items) |img| if (img.texture) |tex| self.device.releaseTexture(tex);
        for (self.pending_uploads.items) |u| self.device.releaseTransferBuffer(u.transfer);
        self.images.deinit(self.allocator);
        self.pending_uploads.deinit(self.allocator);
        self.batches.deinit(self.allocator);
        self.device.releaseTexture(self.atlas);
        self.device.releaseTexture(self.color_atlas);
        self.allocator.free(self.color_pixels);
        self.device.releaseGraphicsPipeline(self.erase_pipeline);
        self.device.releaseGraphicsPipeline(self.pipeline);
        self.device.releaseWindow(self.window);
        self.device.deinit();
        self.face.deinit();
        self.italic_face.deinit();
        self.ui_face.deinit();
        self.ui_small_face.deinit();
        for (self.extra) |f| f.deinit();
        self.allocator.free(self.pixels);
        self.allocator.free(self.cpu);
        self.* = undefined;
    }
    /// Starts a frame of `w`×`h` logical units rendered at `scale` device pixels per unit.
    pub fn begin(self: *Renderer, w: u32, h: u32, scale: f32) !void {
        if (self.active or w == 0 or h == 0) return error.BeginFrameFailed;
        try self.setScale(scale);
        self.w = @floatFromInt(w);
        self.h = @floatFromInt(h);
        self.count = 0;
        self.batches.clearRetainingCapacity();
        self.batches.append(self.allocator, .{ .start = 0, .image = null }) catch {};
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
            for (&self.color_icons) |*icon_entry| icon_entry.stamp = 0;
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
    /// Solid rectangle with edges snapped to device pixels; a non-empty side never
    /// collapses below one device pixel, so hairlines stay crisp at fractional scales.
    pub fn rect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, color: [4]u8) !void {
        if (w <= 0 or h <= 0) return;
        const s = self.scale;
        const x0 = @round(x * s);
        const y0 = @round(y * s);
        const x1 = @max(x0 + 1, @round((x + w) * s));
        const y1 = @max(y0 + 1, @round((y + h) * s));
        try self.quad(x0 / s, y0 / s, (x1 - x0) / s, (y1 - y0) / s, 0.5 / 1024.0, 0.5 / 1024.0, 0, 0, color);
    }
    /// Filled rounded rectangle; corners are built from anti-aliased device-pixel scanlines.
    pub fn roundRect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, radius: f32, color: [4]u8) !void {
        const s = self.scale;
        const r = @floor(@max(0, @min(radius, @min(w, h) / 2)) * s);
        if (r < 1) return self.rect(x, y, w, h, color);
        const px_w = w * s;
        const px_h = h * s;
        try self.rect(x, y + r / s, w, (px_h - 2 * r) / s, color);
        var i: f32 = 0;
        while (i < r) : (i += 1) {
            const dy = r - (i + 0.5);
            const inset = r - @sqrt(r * r - dy * dy);
            const full = @ceil(inset);
            var edge = color;
            edge[3] = @intFromFloat(@as(f32, @floatFromInt(color[3])) * (full - inset));
            for ([_]f32{ i, px_h - 1 - i }) |row| {
                const ry = y + row / s;
                try self.rect(x + full / s, ry, (px_w - 2 * full) / s, 1 / s, color);
                if (full > 0 and edge[3] > 0) {
                    try self.rect(x + (full - 1) / s, ry, 1 / s, 1 / s, edge);
                    try self.rect(x + (px_w - full) / s, ry, 1 / s, 1 / s, edge);
                }
            }
        }
    }
    /// Rounded rectangle with a one-pixel border.
    pub fn roundBox(self: *Renderer, x: f32, y: f32, w: f32, h: f32, radius: f32, fill: [4]u8, border: [4]u8) !void {
        try self.roundRect(x, y, w, h, radius, border);
        try self.roundRect(x + 1, y + 1, w - 2, h - 2, @max(0, radius - 1), fill);
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
            .ui_small => self.ui_small_face,
            else => self.extra[@intFromEnum(style) - first_extra],
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
                    // Metrics are device pixels; snap the bitmap origin to the device grid so
                    // nearest sampling maps texels 1:1 (no dropped or doubled columns).
                    const s = self.scale;
                    const gx = @round(x * s + pen + @as(f32, @floatFromInt(p.x_offset)) / 64 + @as(f32, @floatFromInt(g.left))) / s;
                    const gy = @round(baseline * s - @as(f32, @floatFromInt(p.y_offset)) / 64 - @as(f32, @floatFromInt(g.top))) / s;
                    try self.quad(gx, gy, @as(f32, @floatFromInt(g.w)) / s, @as(f32, @floatFromInt(g.h)) / s, @as(f32, @floatFromInt((slot % 32) * 32)) / side, @as(f32, @floatFromInt((slot / 32) * 64)) / side, @as(f32, @floatFromInt(g.w)) / side, @as(f32, @floatFromInt(g.h)) / side, color);
                } else {
                    // A visible replacement preserves the advance and lets the
                    // editing session continue if a font or atlas limit is hit.
                    self.degraded = true;
                    const gx = x + pen / self.scale + 1;
                    const gh = face.space() / self.scale * 1.3;
                    const gw = @max(3, @as(f32, @floatFromInt(p.x_advance)) / 64 / self.scale - 2);
                    try self.rect(gx, baseline - gh, gw, 1, color);
                    try self.rect(gx, baseline - gh, 1, gh, color);
                    try self.rect(gx + gw - 1, baseline - gh, 1, gh, color);
                    try self.rect(gx, baseline - 1, gw, 1, color);
                };
                pen += @as(f32, @floatFromInt(p.x_advance)) / 64;
            }
            off = segment_end;
        }
        return pen / self.scale;
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
    /// Zed `LabelSize::Small` (12px) UI label.
    pub fn textSmall(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.ui_small, value, x, baseline, color, true);
    }
    pub fn widthSmall(self: *Renderer, value: []const u8) f32 {
        return self.drawText(.ui_small, value, 0, 0, undefined, false) catch 0;
    }
    /// Zed `LabelSize::Small` italic label (12px IBM Plex Sans Italic).
    pub fn textSmallItalic(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.ui_small_italic, value, x, baseline, color, true);
    }
    /// Zed `Headline` at `HeadlineSize::Small` (16px).
    pub fn textHeadline(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.headline, value, x, baseline, color, true);
    }
    /// Zed `Headline` default (`HeadlineSize::Medium`, 18px).
    pub fn textHeadlineMedium(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.headline_medium, value, x, baseline, color, true);
    }
    pub fn widthHeadlineMedium(self: *Renderer, value: []const u8) f32 {
        return self.drawText(.headline_medium, value, 0, 0, undefined, false) catch 0;
    }
    /// Zed `LabelSize::XSmall` (10px) UI label.
    pub fn textXSmall(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.ui_xsmall, value, x, baseline, color, true);
    }
    pub fn widthXSmall(self: *Renderer, value: []const u8) f32 {
        return self.drawText(.ui_xsmall, value, 0, 0, undefined, false) catch 0;
    }
    /// Zed `LabelSize::XSmall` label drawn with `buffer_font` (10px Lilex).
    pub fn textMonoXSmall(self: *Renderer, value: []const u8, x: f32, baseline: f32, color: [4]u8) !void {
        _ = try self.drawText(.mono_xsmall, value, x, baseline, color, true);
    }
    pub fn widthMonoXSmall(self: *Renderer, value: []const u8) f32 {
        return self.drawText(.mono_xsmall, value, 0, 0, undefined, false) catch 0;
    }
    pub fn widthHeadline(self: *Renderer, value: []const u8) f32 {
        return self.drawText(.headline, value, 0, 0, undefined, false) catch 0;
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
        // Rasterize at device density (capped by the 32px atlas cell).
        const n: u8 = @intFromFloat(@min(32, @max(1, @round(size * self.scale))));
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
        try self.quad(@round(x * self.scale) / self.scale, @round(y * self.scale) / self.scale, size, size, @as(f32, @floatFromInt(sx)) / side, @as(f32, @floatFromInt(sy)) / side, @as(f32, @floatFromInt(n)) / side, @as(f32, @floatFromInt(n)) / side, color);
    }
    /// Uploads a straight-alpha RGBA8 image to its own GPU texture (sent with the next
    /// frame). Images wider or taller than 8192px must be resized by the caller.
    pub fn createImage(self: *Renderer, rgba: []const u8, image_w: u32, image_h: u32) !ImageId {
        if (image_w == 0 or image_h == 0 or image_w > 8192 or image_h > 8192 or rgba.len != @as(usize, image_w) * image_h * 4) return error.InvalidImage;
        const texture = try self.device.createTexture(.{ .format = .r8g8b8a8_unorm, .usage = .{ .sampler = true }, .width = image_w, .height = image_h });
        errdefer self.device.releaseTexture(texture);
        const transfer = try self.device.createTransferBuffer(.{ .usage = .upload, .size = @intCast(rgba.len) });
        errdefer self.device.releaseTransferBuffer(transfer);
        const mapped = try self.device.mapTransferBuffer(transfer, false);
        @memcpy(mapped[0..rgba.len], rgba);
        self.device.unmapTransferBuffer(transfer);
        // Reuse a released slot when there is one.
        var id: ImageId = @intCast(self.images.items.len);
        for (self.images.items, 0..) |img, i| if (img.texture == null) {
            id = @intCast(i);
            break;
        };
        const entry: GpuImage = .{ .texture = texture, .width = image_w, .height = image_h };
        if (id == self.images.items.len) try self.images.append(self.allocator, entry) else self.images.items[id] = entry;
        try self.pending_uploads.append(self.allocator, .{ .id = id, .transfer = transfer });
        return id;
    }
    pub fn destroyImage(self: *Renderer, id: ImageId) void {
        if (id >= self.images.items.len) return;
        // Uploads still queued for this slot are dropped with it.
        var i: usize = 0;
        while (i < self.pending_uploads.items.len) {
            if (self.pending_uploads.items[i].id == id) {
                self.device.releaseTransferBuffer(self.pending_uploads.swapRemove(i).transfer);
            } else i += 1;
        }
        if (self.images.items[id].texture) |tex| self.device.releaseTexture(tex);
        self.images.items[id].texture = null;
    }
    /// Draws image `id` scaled into (x, y, w, h); `alpha` scales opacity.
    pub fn drawImage(self: *Renderer, id: ImageId, x: f32, y: f32, w: f32, h: f32, alpha: u8) !void {
        if (id >= self.images.items.len or self.images.items[id].texture == null) return;
        const last = &self.batches.items[self.batches.items.len - 1];
        if (last.image != id) {
            if (last.image == null or last.start == self.count) {
                // An image-free (or empty) batch can adopt this image.
                last.image = id;
            } else try self.batches.append(self.allocator, .{ .start = @intCast(self.count), .image = id });
        }
        try self.quad(x, y, w, h, 4, 0, 1, 1, .{ 255, 255, 255, alpha });
    }

    /// Monochrome SVG larger than an icon cell (up to 64px, e.g. the onboarding logo).
    /// The mask is rasterized once at device density and stored as four 32px tiles in
    /// ordinary icon slots, so allocation and eviction are shared with `icon`.
    pub fn largeIcon(self: *Renderer, svg: []const u8, x: f32, y: f32, size: f32, color: [4]u8) !void {
        if (!self.active) return error.BeginFrameFailed;
        if (!std.math.isFinite(size) or size <= 0 or size > 64) return error.InvalidIconSize;
        if (size <= 32 and @round(size * self.scale) <= 32) return self.icon(svg, x, y, size, color);
        const n: u8 = @intFromFloat(@min(64, @max(2, @round(size * self.scale / 2) * 2)));
        const half = n / 2;
        var slots: [4]?usize = .{ null, null, null, null };
        var missing = false;
        for (0..4) |q| {
            const hash = std.hash.Wyhash.hash(q + 1, svg);
            for (&self.icons, 0..) |*entry, i| if (entry.valid and entry.hash == hash and entry.len == svg.len and entry.size == n) {
                slots[q] = i;
                break;
            };
            if (slots[q] == null) missing = true;
        }
        if (missing) {
            var mask: [64 * 64]u8 = undefined;
            if (zid_svg_alpha(svg.ptr, svg.len, n, &mask) == 0) return error.SvgParse;
            for (0..4) |q| {
                if (slots[q] != null) continue;
                var vacant: ?usize = null;
                for (&self.icons, 0..) |*entry, i| {
                    var taken = false;
                    for (slots) |s| if (s == i) {
                        taken = true;
                    };
                    if (!taken and entry.stamp != self.frame) {
                        vacant = i;
                        break;
                    }
                }
                const i = vacant orelse {
                    self.degraded = true;
                    return;
                };
                const sx = (i % 32) * 32;
                const sy = 768 + (i / 32) * 32;
                const ox = (q % 2) * half;
                const oy = (q / 2) * half;
                for (0..32) |row| @memset(self.pixels[(sy + row) * side + sx ..][0..32], 0);
                for (0..half) |row| @memcpy(self.pixels[(sy + row) * side + sx ..][0..half], mask[(oy + row) * n + ox ..][0..half]);
                self.icons[i] = .{ .hash = std.hash.Wyhash.hash(q + 1, svg), .len = svg.len, .size = n, .valid = true, .stamp = self.frame };
                slots[q] = i;
            }
        }
        const left = @round(x * self.scale) / self.scale;
        const top = @round(y * self.scale) / self.scale;
        const tile = @as(f32, @floatFromInt(half)) / self.scale;
        for (slots, 0..) |slot, q| {
            const i = slot.?;
            self.icons[i].stamp = self.frame;
            const sx = (i % 32) * 32;
            const sy = 768 + (i / 32) * 32;
            const dx: f32 = @floatFromInt(q % 2);
            const dy: f32 = @floatFromInt(q / 2);
            try self.quad(left + dx * tile, top + dy * tile, tile, tile, @as(f32, @floatFromInt(sx)) / side, @as(f32, @floatFromInt(sy)) / side, @as(f32, @floatFromInt(half)) / side, @as(f32, @floatFromInt(half)) / side, color);
        }
    }
    /// Multi-color SVG icon (icon themes such as Catppuccin), drawn with its own colors;
    /// `alpha` scales opacity. Rasterized at device density into the RGBA atlas.
    pub fn colorIcon(self: *Renderer, svg: []const u8, x: f32, y: f32, size: f32, alpha: u8) !void {
        if (!self.active) return error.BeginFrameFailed;
        if (!std.math.isFinite(size) or size <= 0 or size > 32) return error.InvalidIconSize;
        const n: u8 = @intFromFloat(@min(32, @max(1, @round(size * self.scale))));
        const hash = std.hash.Wyhash.hash(1, svg);
        var slot: ?usize = null;
        var vacant: ?usize = null;
        for (&self.color_icons, 0..) |*entry, i| {
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
        const cells = color_side / 32;
        const sx = (i % cells) * 32;
        const sy = (i / cells) * 32;
        if (slot == null) {
            var rgba: [32 * 32 * 4]u8 = undefined;
            if (zid_svg_rgba(svg.ptr, svg.len, n, &rgba) == 0) return error.SvgParse;
            for (0..32) |row| @memset(self.color_pixels[((sy + row) * color_side + sx) * 4 ..][0 .. 32 * 4], 0);
            for (0..n) |row| @memcpy(self.color_pixels[((sy + row) * color_side + sx) * 4 ..][0 .. @as(usize, n) * 4], rgba[row * @as(usize, n) * 4 ..][0 .. @as(usize, n) * 4]);
            self.color_icons[i] = .{ .hash = hash, .len = svg.len, .size = n, .valid = true };
            self.color_dirty = true;
        }
        self.color_icons[i].stamp = self.frame;
        // u >= 2 selects the color atlas in ui.frag.
        const cs: f32 = @floatFromInt(color_side);
        try self.quad(@round(x * self.scale) / self.scale, @round(y * self.scale) / self.scale, size, size, 2 + @as(f32, @floatFromInt(sx)) / cs, @as(f32, @floatFromInt(sy)) / cs, @as(f32, @floatFromInt(n)) / cs, @as(f32, @floatFromInt(n)) / cs, .{ 255, 255, 255, alpha });
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
        const mapped = try self.device.mapTransferBuffer(self.transfer, true);
        // Transfer layout: [mask atlas][color atlas][vertices]. The color atlas is only
        // copied and uploaded when an icon was rasterized into it.
        const vertex_offset = side * side + color_bytes;
        @memcpy(mapped[0 .. side * side], self.pixels);
        const upload_color = self.color_dirty;
        if (upload_color) @memcpy(mapped[side * side ..][0..color_bytes], self.color_pixels);
        const bytes = std.mem.sliceAsBytes(self.cpu[0..self.count]);
        @memcpy(mapped[vertex_offset..][0..bytes.len], bytes);
        self.device.unmapTransferBuffer(self.transfer);
        const copy = cmd.beginCopyPass();
        copy.uploadToTexture(.{ .transfer_buffer = self.transfer, .offset = 0, .pixels_per_row = side, .rows_per_layer = side }, .{ .texture = self.atlas, .width = side, .height = side, .depth = 1 }, true);
        if (upload_color) {
            copy.uploadToTexture(.{ .transfer_buffer = self.transfer, .offset = side * side, .pixels_per_row = color_side, .rows_per_layer = color_side }, .{ .texture = self.color_atlas, .width = color_side, .height = color_side, .depth = 1 }, false);
            self.color_dirty = false;
        }
        if (self.count > 0) copy.uploadToBuffer(.{ .transfer_buffer = self.transfer, .offset = vertex_offset }, .{ .buffer = self.vertices, .offset = 0, .size = @intCast(bytes.len) }, true);
        for (self.pending_uploads.items) |u| {
            const img = self.images.items[u.id];
            if (img.texture) |tex| copy.uploadToTexture(.{ .transfer_buffer = u.transfer, .offset = 0, .pixels_per_row = img.width, .rows_per_layer = img.height }, .{ .texture = tex, .width = img.width, .height = img.height, .depth = 1 }, false);
            self.device.releaseTransferBuffer(u.transfer);
        }
        self.pending_uploads.clearRetainingCapacity();
        copy.end();

        const uw: u32 = @intFromFloat(@round(self.w * self.scale));
        const uh: u32 = @intFromFloat(@round(self.h * self.scale));
        if (self.target == null or self.target_w != uw or self.target_h != uh) {
            if (self.target) |old| self.device.releaseTexture(old);
            self.target = try self.device.createTexture(.{
                .format = self.format,
                .usage = .{ .color_target = true, .sampler = true },
                .width = uw,
                .height = uh,
            });
            self.target_w = uw;
            self.target_h = uh;
        }

        const targets = [_]gpu.ColorTargetInfo{.{ .texture = self.target.?, .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .load = .clear, .store = .store }};
        const pass = cmd.beginRenderPass(&targets, null);
        pass.bindGraphicsPipeline(self.pipeline);
        pass.bindVertexBuffers(0, &.{.{ .buffer = self.vertices, .offset = 0 }});
        for (self.batches.items, 0..) |batch, i| {
            const end_vertex: u32 = if (i + 1 < self.batches.items.len) self.batches.items[i + 1].start else @intCast(self.count);
            if (end_vertex <= batch.start) continue;
            const image_tex = if (batch.image) |id| (self.images.items[id].texture orelse self.no_image) else self.no_image;
            pass.bindFragmentSamplers(0, &.{ .{ .texture = self.atlas, .sampler = self.sampler }, .{ .texture = self.color_atlas, .sampler = self.sampler }, .{ .texture = image_tex, .sampler = self.image_sampler } });
            pass.drawPrimitives(end_vertex - batch.start, 1, batch.start, 0);
        }
        if (self.radius > 0) {
            const params = [4]f32{ @floatFromInt(uw), @floatFromInt(uh), self.radius * self.scale, 0 };
            cmd.pushFragmentUniformData(0, std.mem.asBytes(&params));
            pass.bindGraphicsPipeline(self.erase_pipeline);
            pass.drawPrimitives(3, 1, 0, 0);
        }
        pass.end();

        // Blit to window swapchain if available (hidden windows or minimized displays may return null)
        const swap_res = cmd.waitAndAcquireSwapchainTexture(self.window) catch null;
        if (swap_res) |res| {
            if (res[0]) |swap_tex| {
                cmd.blitTexture(.{
                    .source = .{ .texture = self.target.?, .mip_level = 0, .layer_or_depth_plane = 0, .region = .{ .x = 0, .y = 0, .w = uw, .h = uh } },
                    .destination = .{ .texture = swap_tex, .mip_level = 0, .layer_or_depth_plane = 0, .region = .{ .x = 0, .y = 0, .w = res[1], .h = res[2] } },
                    .load_op = .do_not_care,
                    .clear_color = .{},
                    .flip_mode = .{},
                    .filter = .nearest,
                    .cycle = false,
                });
            }
        }

        try cmd.submit();
    }
    pub fn readPixels(self: *Renderer, alloc: std.mem.Allocator) !struct { w: u32, h: u32, data: []u8 } {
        if (self.target == null) return error.NoRenderTarget;
        const w = self.target_w;
        const h = self.target_h;
        const bytes = w * h * 4;
        const transfer = try self.device.createTransferBuffer(.{ .usage = .download, .size = bytes });
        defer self.device.releaseTransferBuffer(transfer);
        const cmd = try self.device.acquireCommandBuffer();
        const copy = cmd.beginCopyPass();
        copy.downloadFromTexture(
            .{ .texture = self.target.?, .width = w, .height = h, .depth = 1 },
            .{ .transfer_buffer = transfer, .offset = 0 },
        );
        copy.end();
        const fence = try cmd.submitAndAcquireFence();
        defer self.device.releaseFence(fence);
        try self.device.waitForFences(true, &.{fence});
        const mapped = try self.device.mapTransferBuffer(transfer, false);
        const data = try alloc.alloc(u8, bytes);
        errdefer alloc.free(data);
        if (self.format == .b8g8r8a8_unorm) {
            var i: usize = 0;
            while (i < bytes) : (i += 4) {
                data[i] = mapped[i + 2]; // R
                data[i + 1] = mapped[i + 1]; // G
                data[i + 2] = mapped[i]; // B
                data[i + 3] = mapped[i + 3]; // A
            }
        } else {
            @memcpy(data, mapped[0..bytes]);
        }
        self.device.unmapTransferBuffer(transfer);
        return .{ .w = w, .h = h, .data = data };
    }
};
