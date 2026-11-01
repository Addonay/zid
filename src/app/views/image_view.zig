//! Image viewer for image documents, after Zed's `crates/image_viewer`.
//!
//! The image opens fitted to the pane (`compute_fit_to_view_zoom`: never above 100%),
//! centred over a 32px checkerboard of `panel.background` with a 1px `border` frame.
//! Ctrl+wheel zooms around the pointer (10%–2000%), the wheel pans, and the status bar
//! shows Zed's `ImageInfo`: "W×H • size • FORMAT". Decoding runs on a worker thread
//! (pure-Zig decoders in `src/image`); the result is uploaded as a GPU texture.
const std = @import("std");
const zid = @import("zid");
const App = @import("../app.zig").App;
const Rect = @import("../layout.zig").Rect;
const ImageId = @import("../../gfx/renderer.zig").ImageId;

const min_zoom: f32 = 0.1;
const max_zoom: f32 = 20.0;
const square: f32 = 32;
/// GPU texture limit used for uploads; larger images are downscaled to fit.
const max_texture: u32 = 8192;

const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    done: std.atomic.Value(bool) = .init(false),
    result: ?zid.image.Image = null,
    err: ?anyerror = null,
    format: ?zid.image.Format = null,
    file_size: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,

    fn run(job: *Job) void {
        defer job.done.store(true, .release);
        const bytes = std.Io.Dir.cwd().readFileAlloc(job.io, job.path, job.gpa, .limited(512 * 1024 * 1024)) catch |err| {
            job.err = err;
            return;
        };
        defer job.gpa.free(bytes);
        job.file_size = bytes.len;
        job.format = zid.image.sniff(bytes);
        var img = zid.image.decode(job.gpa, bytes) catch |err| {
            job.err = err;
            return;
        };
        job.width = img.width;
        job.height = img.height;
        if (img.width > max_texture or img.height > max_texture) {
            const scale = @min(@as(f64, max_texture) / @as(f64, @floatFromInt(img.width)), @as(f64, max_texture) / @as(f64, @floatFromInt(img.height)));
            const w: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(img.width)) * scale)));
            const h: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(img.height)) * scale)));
            const small = zid.image.resize(job.gpa, img, w, h) catch |err| {
                img.deinit();
                job.err = err;
                return;
            };
            img.deinit();
            img = small;
        }
        job.result = img;
    }
};

pub const View = struct {
    instance: u64,
    job: ?*Job = null,
    thread: ?std.Thread = null,
    texture: ?ImageId = null,
    /// Original pixel size (before any GPU downscale).
    width: u32 = 0,
    height: u32 = 0,
    file_size: u64 = 0,
    format: ?zid.image.Format = null,
    failure: ?anyerror = null,
    /// null until the first layout, then fit-to-view; user zoom afterwards.
    zoom: ?f32 = null,
    pan_x: f32 = 0,
    pan_y: f32 = 0,
};

pub const State = struct {
    views: std.ArrayList(View) = .empty,

    pub fn deinit(self: *State, app: *App) void {
        for (self.views.items) |*v| release(app, v);
        self.views.deinit(app.gpa);
    }
};

fn release(app: *App, v: *View) void {
    if (v.thread) |t| t.join();
    if (v.job) |job| {
        if (job.result) |*img| img.deinit();
        app.gpa.free(job.path);
        app.gpa.destroy(job);
    }
    if (v.texture) |id| app.renderer.destroyImage(id);
    v.* = .{ .instance = v.instance };
}

fn viewFor(app: *App, doc: *zid.Document) !*View {
    for (app.image_views.views.items) |*v| if (v.instance == doc.instance_id) return v;
    try app.image_views.views.append(app.gpa, .{ .instance = doc.instance_id });
    const v = &app.image_views.views.items[app.image_views.views.items.len - 1];
    const job = try app.gpa.create(Job);
    errdefer app.gpa.destroy(job);
    job.* = .{ .gpa = app.gpa, .io = app.io, .path = try app.gpa.dupe(u8, doc.path orelse "") };
    v.job = job;
    v.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    return v;
}

/// UI thread: upload finished decodes and drop views of closed documents.
pub fn poll(app: *App) bool {
    var changed = false;
    var i: usize = 0;
    while (i < app.image_views.views.items.len) {
        const v = &app.image_views.views.items[i];
        var open = false;
        for (app.workspace.documents.items) |*d| if (d.instance_id == v.instance) {
            open = true;
        };
        if (!open) {
            if (v.job == null or v.job.?.done.load(.acquire)) {
                release(app, v);
                _ = app.image_views.views.swapRemove(i);
                continue;
            }
        } else if (v.job) |job| if (job.done.load(.acquire)) {
            if (v.thread) |t| t.join();
            v.thread = null;
            v.file_size = job.file_size;
            v.format = job.format;
            if (job.result) |*img| {
                v.texture = app.renderer.createImage(img.pixels, img.width, img.height) catch |err| blk: {
                    v.failure = err;
                    break :blk null;
                };
                // The original size; an oversized image is uploaded downscaled.
                v.width = job.width;
                v.height = job.height;
                img.deinit();
                job.result = null;
            } else v.failure = job.err;
            app.gpa.free(job.path);
            app.gpa.destroy(job);
            v.job = null;
            changed = true;
        };
        i += 1;
    }
    return changed;
}

pub fn decoding(app: *const App) bool {
    for (app.image_views.views.items) |v| if (v.job != null) return true;
    return false;
}

fn fitZoom(area: Rect, w: u32, h: u32) f32 {
    const sx = area.w / @as(f32, @floatFromInt(w));
    const sy = area.h / @as(f32, @floatFromInt(h));
    return @min(@min(sx, sy), 1.0);
}

fn imageRect(area: Rect, v: *const View) Rect {
    const zoom = v.zoom orelse fitZoom(area, v.width, v.height);
    const w = @as(f32, @floatFromInt(v.width)) * zoom;
    const h = @as(f32, @floatFromInt(v.height)) * zoom;
    return .{ .x = @round(area.x + (area.w - w) / 2 + v.pan_x), .y = @round(area.y + (area.h - h) / 2 + v.pan_y), .w = w, .h = h };
}

pub fn draw(app: *App, doc: *zid.Document) !void {
    const t = app.settings.theme;
    const area = try app.layout.rect(app.layout.editor);
    try app.fill(area, t.editor);
    const v = try viewFor(app, doc);
    app.clip(area);
    defer app.renderer.setClip(null);
    if (v.failure) |err| {
        const text = try std.fmt.allocPrint(app.frame_arena.allocator(), "Could not open image: {s}", .{@errorName(err)});
        try app.renderer.textUi(text, area.x + (area.w - app.renderer.widthUi(text)) / 2, area.y + area.h / 2, t.muted);
        return;
    }
    const id = v.texture orelse return; // still decoding
    const r = imageRect(area, v);
    const zoom = v.zoom orelse fitZoom(area, v.width, v.height);
    // Checkerboard: `panel.background` squares on the editor background.
    app.clip(.{ .x = @max(area.x, r.x), .y = @max(area.y, r.y), .w = @max(0, @min(area.x + area.w, r.x + r.w) - @max(area.x, r.x)), .h = @max(0, @min(area.y + area.h, r.y + r.h) - @max(area.y, r.y)) });
    const s = square * zoom;
    const first_col = @max(0, @floor((area.x - r.x) / s));
    const first_row = @max(0, @floor((area.y - r.y) / s));
    var row = first_row;
    while (r.y + row * s < @min(r.y + r.h, area.y + area.h)) : (row += 1) {
        var col = first_col;
        while (r.x + col * s < @min(r.x + r.w, area.x + area.w)) : (col += 1) {
            if (@mod(row + col, 2) == 0) try app.renderer.rect(r.x + col * s, r.y + row * s, s, s, t.panel);
        }
    }
    try app.renderer.drawImage(id, r.x, r.y, r.w, r.h, 255);
    app.clip(area);
    // 1px frame around the image.
    try app.renderer.rect(r.x - 1, r.y - 1, r.w + 2, 1, t.border);
    try app.renderer.rect(r.x - 1, r.y + r.h, r.w + 2, 1, t.border);
    try app.renderer.rect(r.x - 1, r.y, 1, r.h, t.border);
    try app.renderer.rect(r.x + r.w, r.y, 1, r.h, t.border);
}

/// Mouse wheel over an image: ctrl zooms around the pointer, otherwise pans.
pub fn scroll(app: *App, doc: *zid.Document, dx: f32, dy: f32, mx: f32, my: f32, zoom_modifier: bool) !void {
    const v = try viewFor(app, doc);
    if (v.texture == null) return;
    const area = try app.layout.rect(app.layout.editor);
    if (zoom_modifier) {
        const old = v.zoom orelse fitZoom(area, v.width, v.height);
        const delta = dy * 20; // SCROLL_LINE_MULTIPLIER
        const factor = if (delta > 0) 1 + @abs(delta) * 0.01 else 1 / (1 + @abs(delta) * 0.01);
        const new = std.math.clamp(old * factor, min_zoom, max_zoom);
        // Keep the point under the pointer fixed (Zed `set_zoom` with a centre).
        const r = imageRect(area, v);
        const ox = mx - (r.x + r.w / 2);
        const oy = my - (r.y + r.h / 2);
        const ratio = new / old;
        v.pan_x += ox * (1 - ratio);
        v.pan_y += oy * (1 - ratio);
        v.zoom = new;
    } else {
        v.pan_x += dx * 20;
        v.pan_y += dy * 20;
    }
}

/// Zed `ImageInfo` text for the status bar.
pub fn info(app: *App, doc: *zid.Document, buf: []u8) ?[]const u8 {
    for (app.image_views.views.items) |v| if (v.instance == doc.instance_id) {
        if (v.texture == null) return null;
        const size = v.file_size;
        var size_buf: [32]u8 = undefined;
        const size_text = if (size >= 1024 * 1024)
            std.fmt.bufPrint(&size_buf, "{d:.1} MiB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024)}) catch ""
        else if (size >= 1024)
            std.fmt.bufPrint(&size_buf, "{d:.1} KiB", .{@as(f64, @floatFromInt(size)) / 1024}) catch ""
        else
            std.fmt.bufPrint(&size_buf, "{d} B", .{size}) catch "";
        const format: []const u8 = if (v.format) |f| switch (f) {
            .png => "PNG",
            .jpeg => "JPEG",
            .gif => "GIF",
            .bmp => "BMP",
        } else "Unknown";
        return std.fmt.bufPrint(buf, "{d}x{d} • {s} • {s}", .{ v.width, v.height, size_text, format }) catch null;
    };
    return null;
}
