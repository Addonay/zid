const std = @import("std");
const zid = @import("zid");
const sdl = @import("sdl3");
const Renderer = @import("../gfx/renderer.zig").Renderer;
const layout_mod = @import("layout.zig");
const Rect = layout_mod.Rect;
const config = @import("config.zig");
const Project = @import("project.zig").Project;
const syntax = zid.syntax;
const log = std.log.scoped(.app);
const WindowControls = @import("../platform/window_controls.zig").WindowControls;
const title_bar = @import("views/title_bar.zig");
const max_line_bytes = 64 * 1024;

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    workspace: *zid.Workspace,
    window: sdl.video.Window,
    renderer: Renderer,
    controls: WindowControls,
    mouse_x: f32 = -1,
    mouse_y: f32 = -1,
    pointer_down: bool = false,
    layout: layout_mod.Layout,
    project: Project,
    visible: std.ArrayList(usize) = .empty,
    settings: config.Settings = .{},
    bindings: ?std.json.Parsed([]config.Binding) = null,
    config_root: []u8,
    panel_open: bool = true,
    panel_focus: bool = false,
    panel_scroll: usize = 0,
    panel_row: usize = 0,
    tabs_first: usize = 0,
    tab_hits: std.ArrayList(struct { rect: Rect, index: usize }) = .empty,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    dialog: enum { none, open, save, close, quit } = .none,
    path_input: std.ArrayList(u8) = .empty,
    dragging: bool = false,
    close_after_save: bool = false,
    suppress_choice_text: bool = false,
    focused: bool = true,
    config_stamp: u64 = 0,
    last_config_poll: u64 = 0,
    running: bool = true,
    caret_visible: bool = true,
    last_blink: u64 = 0,
    syntax_doc: usize = std.math.maxInt(usize),
    syntax_revision: u64 = std.math.maxInt(u64),
    checkpoints: std.ArrayList(u32) = .empty,
    line: [max_line_bytes]u8 = undefined,
    expanded: [max_line_bytes * 4]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, workspace: *zid.Workspace, env: *const std.process.Environ.Map) !App {
        const home = env.get("HOME") orelse ".";
        const root = if (env.get("XDG_CONFIG_HOME")) |p| try std.fs.path.join(gpa, &.{ p, "zid" }) else try std.fs.path.join(gpa, &.{ home, ".config", "zid" });
        errdefer gpa.free(root);
        try sdl.init(.{ .video = true });
        errdefer sdl.shutdown();
        const window = try sdl.video.Window.init("Zid", 1200, 800, .{ .resizable = true, .borderless = true, .transparent = true });
        errdefer window.deinit();
        try window.setMinimumSize(480, 300);
        const initial_settings = config.loadSettings(gpa, io, root) catch |err| blk: {
            log.warn("Settings: {s}", .{@errorName(err)});
            break :blk config.Settings{};
        };
        var renderer = try Renderer.initSized(gpa, window, initial_settings.font_size);
        errdefer renderer.deinit();
        var layout = try layout_mod.Layout.init(gpa);
        errdefer layout.deinit();
        var project = try Project.init(gpa, workspace.files.items);
        errdefer project.deinit();
        const controls = WindowControls.init(gpa, io, home);
        var self: App = .{ .gpa = gpa, .io = io, .workspace = workspace, .window = window, .renderer = renderer, .layout = layout, .project = project, .config_root = root, .settings = initial_settings, .controls = controls };
        self.reloadConfig() catch |err| self.notice("Settings: {s}", .{@errorName(err)});
        sdl.keyboard.startTextInput(window) catch {};
        log.info("window ready: SDL_GPU Vulkan, project={s}, files={d}", .{ workspace.root, workspace.files.items.len });
        return self;
    }
    pub fn deinit(self: *App) void {
        if (self.bindings) |*p| p.deinit();
        self.checkpoints.deinit(self.gpa);
        self.path_input.deinit(self.gpa);
        self.tab_hits.deinit(self.gpa);
        self.visible.deinit(self.gpa);
        self.project.deinit();
        self.layout.deinit();
        self.controls.deinit();
        self.renderer.deinit();
        self.gpa.free(self.config_root);
        self.window.deinit();
        sdl.shutdown();
    }
    pub fn hitTest(window: sdl.video.Window, point: sdl.rect.IPoint, userdata: ?*App) sdl.video.HitTestResult {
        const w_usize, const h_usize = window.getSize() catch return .normal;
        const w: i32 = @intCast(w_usize);
        const h: i32 = @intCast(h_usize);
        const x = point.x;
        const y = point.y;
        if (y < 5) {
            if (x < 8) return .resize_top_left;
            if (x > w - 8) return .resize_top_right;
            return .resize_top;
        }
        if (y > h - 5) {
            if (x < 8) return .resize_bottom_left;
            if (x > w - 8) return .resize_bottom_right;
            return .resize_bottom;
        }
        if (x < 5) return .resize_left;
        if (x > w - 5) return .resize_right;
        if (y < 34 and x > 40 and @as(f32, @floatFromInt(x)) < @as(f32, @floatFromInt(w)) - (if (userdata) |self| title_bar.controlsInset(self) else 126)) return .draggable;
        return .normal;
    }
    pub fn notice(self: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..0];
        self.message_len = text.len;
        log.info("{s}", .{text});
    }
    pub fn configurationStamp(self: *App) u64 {
        var hash = std.hash.Wyhash.init(0);
        for ([_][]const u8{ "settings.json", "keymap.json" }) |name| {
            const path = std.fs.path.join(self.gpa, &.{ self.config_root, name }) catch continue;
            defer self.gpa.free(path);
            const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch continue;
            const mtime: i128 = stat.mtime.nanoseconds;
            hash.update(std.mem.asBytes(&mtime));
            hash.update(std.mem.asBytes(&stat.size));
        }
        return hash.final();
    }
    pub fn reloadConfig(self: *App) !void {
        var s = try config.loadSettings(self.gpa, self.io, self.config_root);
        if (s.font_size != self.settings.font_size) {
            self.notice("Font size changes take effect after restart", .{});
            s.font_size = self.settings.font_size;
        }
        const key_path = try std.fs.path.join(self.gpa, &.{ self.config_root, "keymap.json" });
        defer self.gpa.free(key_path);
        const keys = config.load([]config.Binding, self.gpa, self.io, key_path) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            break :blk null;
        };
        if (self.bindings) |*old| old.deinit();
        self.bindings = keys;
        self.settings = s;
        self.caret_visible = self.focused;
        self.last_blink = sdl.timer.getMillisecondsSinceInit();
    }
    pub fn run(self: *App) !void {
        self.window.setHitTest(App, hitTest, self) catch {};
        try self.draw();
        self.last_blink = sdl.timer.getMillisecondsSinceInit();
        self.config_stamp = self.configurationStamp();
        while (self.running) {
            const now = sdl.timer.getMillisecondsSinceInit();
            const blink = self.focused and self.settings.cursor_blink and self.dialog == .none and !self.panel_focus;
            const wait: u31 = if (blink) @intCast(500 - @min(500, now - self.last_blink)) else 1000;
            var dirty = false;
            if (sdl.events.waitAndPopTimeout(wait)) |pending_event| {
                self.event(pending_event) catch |err| self.notice("{s}", .{@errorName(err)});
                dirty = true;
                var budget: usize = 0;
                while (budget < 128) : (budget += 1) {
                    const next = sdl.events.poll() orelse break;
                    self.event(next) catch |err| self.notice("{s}", .{@errorName(err)});
                }
            }
            if (sdl.timer.getMillisecondsSinceInit() - self.last_config_poll >= 1000) {
                self.last_config_poll = sdl.timer.getMillisecondsSinceInit();
                const stamp = self.configurationStamp();
                if (stamp != self.config_stamp) {
                    self.config_stamp = stamp;
                    self.reloadConfig() catch |err| self.notice("Configuration: {s}; last valid settings retained", .{@errorName(err)});
                    dirty = true;
                }
            }
            if (blink and sdl.timer.getMillisecondsSinceInit() - self.last_blink >= 500) {
                self.last_blink = sdl.timer.getMillisecondsSinceInit();
                self.caret_visible = !self.caret_visible;
                dirty = true;
            }
            if (dirty and self.running) self.draw() catch |err| self.notice("Frame failed: {s}; edits are retained", .{@errorName(err)});
        }
    }
    pub fn ctrlHeld() bool {
        return @import("input/events.zig").ctrlHeld();
    }
    pub fn shiftHeld() bool {
        return @import("input/events.zig").shiftHeld();
    }
    pub fn bindingMatches(binding: config.Binding, key: ?sdl.keycode.Keycode, mods: sdl.keycode.KeyModifier) bool {
        return @import("input/events.zig").bindingMatches(binding, key, mods);
    }
    pub fn event(self: *App, e: sdl.events.Event) !void {
        return @import("input/events.zig").event(self, e);
    }
    pub fn action(self: *App, action_value: config.Action) !void {
        return @import("input/actions.zig").action(self, action_value);
    }
    pub fn pathDialog(self: *App, kind: @FieldType(App, "dialog")) !void {
        return @import("input/actions.zig").pathDialog(self, kind);
    }
    pub fn dialogKey(self: *App, key: sdl.keycode.Keycode) !void {
        return @import("input/actions.zig").dialogKey(self, key);
    }
    pub fn docPreview(self: *App) bool {
        return self.workspace.current().preview_only;
    }
    pub fn pageLines(self: *App) usize {
        const editor = self.layout.rect(self.layout.editor) catch return 20;
        return @max(1, @as(usize, @intFromFloat(@max(0, editor.h - 16) / @as(f32, @floatFromInt(self.settings.line_height)))));
    }
    pub fn keepPanelVisible(self: *App) void {
        if (self.panel_row < self.panel_scroll) self.panel_scroll = self.panel_row;
        if (self.panel_row >= self.panel_scroll + self.pageLines()) self.panel_scroll = self.panel_row - self.pageLines() + 1;
    }
    pub fn refreshProject(self: *App) !void {
        try self.workspace.scan();
        const updated = try Project.init(self.gpa, self.workspace.files.items);
        for (updated.entries.items) |*entry| {
            if (!entry.directory) continue;
            for (self.project.entries.items) |old| {
                if (old.directory and std.mem.eql(u8, old.path, entry.path)) {
                    entry.collapsed = old.collapsed;
                    break;
                }
            }
        }
        self.project.deinit();
        self.project = updated;
        try self.project.visible(self.gpa, &self.visible);
        self.panel_row = @min(self.panel_row, self.visible.items.len -| 1);
    }
    pub fn activateProject(self: *App) !void {
        if (self.visible.items.len == 0) return;
        const entry = &self.project.entries.items[self.visible.items[@min(self.panel_row, self.visible.items.len - 1)]];
        if (entry.directory) {
            entry.collapsed = !entry.collapsed;
            try self.project.visible(self.gpa, &self.visible);
        } else {
            try self.workspace.open(entry.path);
            self.panel_focus = false;
            self.message_len = 0;
        }
    }
    pub fn lineBytes(self: *App, doc: *zid.Document, row: usize) []const u8 {
        const start = doc.lines.items[row];
        var n = @min(max_line_bytes, doc.lineEnd(row) - start);
        while (n > 0 and start + n < doc.buffer.len() and doc.buffer.byteAt(start + n) & 0xc0 == 0x80) n -= 1;
        doc.buffer.copy(start, self.line[0..n]);
        return self.line[0..n];
    }
    /// Measure tabs as configurable tab stops and shape each UTF-8 run with HB.
    pub fn expand(self: *App, bytes: []const u8) []const u8 {
        return self.expandAt(bytes, 0);
    }
    pub fn expandAt(self: *App, bytes: []const u8, initial_column: usize) []const u8 {
        var n: usize = 0;
        var column: usize = initial_column;
        var i: usize = 0;
        while (i < bytes.len) {
            const b = bytes[i];
            if (b == '\t') {
                const count = self.settings.tab_size - column % self.settings.tab_size;
                if (n + count > self.expanded.len) break;
                @memset(self.expanded[n..][0..count], ' ');
                n += count;
                column += count;
                i += 1;
            } else {
                const count = std.unicode.utf8ByteSequenceLength(b) catch 1;
                if (i + count > bytes.len or n + count > self.expanded.len) break;
                @memcpy(self.expanded[n..][0..count], bytes[i..][0..count]);
                n += count;
                i += count;
                column += 1;
            }
        }
        return self.expanded[0..n];
    }
    pub fn textWidth(self: *App, bytes: []const u8) f32 {
        return self.renderer.width(self.expand(bytes));
    }
    pub fn revealCursor(self: *App) !void {
        const doc = self.workspace.current();
        const row = doc.lineOf(doc.cursor);
        if (row < doc.scroll_line) doc.scroll_line = row;
        if (row >= doc.scroll_line + self.pageLines()) doc.scroll_line = row - self.pageLines() + 1;
        const line = self.lineBytes(doc, row);
        const offset = @min(line.len, doc.cursor - doc.lines.items[row]);
        const x = self.textWidth(line[0..offset]);
        const editor = try self.layout.rect(self.layout.editor);
        const view = @max(20, editor.w - 90);
        if (x < doc.scroll_x) doc.scroll_x = x;
        if (x > doc.scroll_x + view) doc.scroll_x = x - view;
    }
    pub fn placeCursor(self: *App, mx: f32, my: f32, extend: bool) !void {
        const doc = self.workspace.current();
        const e = try self.layout.rect(self.layout.editor);
        const row = @min(doc.lines.items.len - 1, doc.scroll_line + @as(usize, @intFromFloat(@max(0, my - e.y - 8) / @as(f32, @floatFromInt(self.settings.line_height)))));
        const line = self.lineBytes(doc, row);
        const target = mx - (e.x + 64) + doc.scroll_x;
        // Width search is bounded to the displayed line window. UTF-8 boundaries
        // are found after binary searching, avoiding quadratic shaping per click.
        var lo: usize = 0;
        var hi = line.len;
        while (lo < hi) {
            var mid = lo + (hi - lo) / 2;
            while (mid > lo and mid < line.len and line[mid] & 0xc0 == 0x80) mid -= 1;
            var next = mid + 1;
            while (next < line.len and line[next] & 0xc0 == 0x80) next += 1;
            if (self.textWidth(line[0..next]) < target) lo = next else hi = mid;
        }
        var offset = lo;
        if (offset < line.len) {
            var next = offset + 1;
            while (next < line.len and line[next] & 0xc0 == 0x80) next += 1;
            if (target > (self.textWidth(line[0..offset]) + self.textWidth(line[0..next])) / 2) offset = next;
        }
        doc.move(doc.lines.items[row] + offset, extend);
        self.caret_visible = true;
        self.last_blink = sdl.timer.getMillisecondsSinceInit();
    }
    pub fn click(self: *App, mx: f32, my: f32, clicks: u8) !void {
        if (self.dialog != .none) return;
        const status = try self.layout.rect(self.layout.status);
        if (status.contains(mx, my) and mx < 42) {
            try self.action(.toggle_panel);
            return;
        }
        if (my < 34) {
            if (title_bar.controlAt(self, mx, my)) |i| switch (i) {
                0 => try self.window.minimize(),
                1 => if (self.window.getFlags().maximized) {
                    try self.window.restore();
                } else {
                    try self.window.maximize();
                },
                else => try self.action(.quit),
            } else if (mx < 36) try self.action(.toggle_panel);
            return;
        }
        for (self.tab_hits.items) |hit| if (hit.rect.contains(mx, my)) {
            self.workspace.active = hit.index;
            self.panel_focus = false;
            if (mx > hit.rect.x + hit.rect.w - 24) try self.action(.close);
            return;
        };
        const panel = try self.layout.rect(self.layout.panel);
        if (panel.contains(mx, my)) {
            self.panel_focus = true;
            if (my < panel.y + 35) return;
            self.panel_row = @min(self.visible.items.len -| 1, self.panel_scroll + @as(usize, @intFromFloat((my - panel.y - 35) / 25)));
            try self.activateProject();
            return;
        }
        const editor = try self.layout.rect(self.layout.editor);
        if (editor.contains(mx, my)) {
            self.panel_focus = false;
            try self.placeCursor(mx, my, shiftHeld());
            if (clicks >= 2) {
                const doc = self.workspace.current();
                var start = doc.cursor;
                var end = doc.cursor;
                while (start > 0 and isWord(doc.buffer.byteAt(start - 1))) start -= 1;
                while (end < doc.buffer.len() and isWord(doc.buffer.byteAt(end))) end += 1;
                doc.move(start, false);
                doc.move(end, true);
            }
            self.dragging = true;
            sdl.mouse.capture(true) catch {};
        }
    }
    pub fn isWord(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_' or b >= 128;
    }
    pub fn fill(self: *App, r: Rect, color: [4]u8) !void {
        try self.renderer.rect(r.x, r.y, r.w, r.h, color);
    }
    pub fn clip(self: *App, r: Rect) void {
        self.renderer.setClip(.{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .w = @intFromFloat(@max(0, r.w)), .h = @intFromFloat(@max(0, r.h)) });
    }
    pub fn draw(self: *App) !void {
        const width, const height = try self.window.getSize();
        if (width <= 0 or height <= 0) return;
        try self.layout.resize(@floatFromInt(width), @floatFromInt(height), if (self.panel_open) @min(@as(f32, @floatFromInt(self.settings.panel_width)), @as(f32, @floatFromInt(width)) * 0.45) else 0);
        try self.project.visible(self.gpa, &self.visible);
        try self.renderer.begin(@intCast(width), @intCast(height));
        errdefer self.renderer.abortFrame();
        const t = self.settings.theme;
        try self.fill(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) }, t.background);
        const project_name = std.fs.path.basename(self.workspace.root);
        self.renderer.roundWindow(if (self.window.getFlags().maximized or self.window.getFlags().fullscreen) 0 else 10);
        try title_bar.draw(self);
        self.renderer.reserveOverlay();
        try self.drawPanel();
        try self.drawTabs();
        try self.drawEditor();
        self.renderer.drawOverlay();
        try @import("views/editor.zig").drawCaret(self);
        const status = try self.layout.rect(self.layout.status);
        try self.fill(status, t.status);
        try self.renderer.rect(0, status.y, status.w, 1, t.border);
        try self.renderer.icon(@import("icons").svg("panel_left"), 12, status.y + 5, 16, t.muted);
        if (docPreview(self)) {
            try self.renderer.textUi("Read-only preview: line exceeds 64 KiB", 52, status.y + 18, t.error_text);
        } else if (self.renderer.degraded) {
            try self.renderer.textUi("Some glyphs replaced: font/atlas limit", 52, status.y + 18, t.error_text);
        } else if (self.message_len > 0) {
            self.clip(.{ .x = 52, .y = status.y, .w = @max(0, status.w - 480), .h = status.h });
            try self.renderer.textUi(self.message[0..self.message_len], 52, status.y + 18, t.text);
            self.renderer.setClip(null);
        }
        const doc = self.workspace.current();
        const lang = syntax.Language.fromPath(doc.path orelse "");
        var info: [256]u8 = undefined;
        const row = doc.lineOf(doc.cursor);
        const text = try std.fmt.bufPrint(&info, "{d}:{d}    {s}    UTF-8    {s}    Spaces: {d}", .{ row + 1, doc.cursor - doc.lines.items[row] + 1, if (doc.crlf) @as([]const u8, "CRLF") else "LF", lang.displayName(), self.settings.tab_size });
        try self.renderer.textUi(text, @max(52, status.w - self.renderer.widthUi(text) - 16), status.y + 18, t.text);
        if (self.dialog != .none) try self.drawDialog();
        try self.renderer.end();
        var title_buffer: [1024]u8 = undefined;
        const name = if (doc.path) |path| std.fs.path.basename(path) else "untitled";
        const window_title = std.fmt.bufPrintSentinel(&title_buffer, "{s}{s} — {s} — Zid", .{ if (doc.dirty()) @as([]const u8, "● ") else "", name, project_name }, 0) catch "Zid";
        try self.window.setTitle(window_title);
    }
    pub fn drawPanel(self: *App) !void {
        return @import("views/project_panel.zig").drawPanel(self);
    }
    pub fn drawTabs(self: *App) !void {
        return @import("views/tabs.zig").drawTabs(self);
    }
    pub fn tabWidth(self: *App, doc: *const zid.Document) f32 {
        return @import("views/tabs.zig").tabWidth(self, doc);
    }
    pub fn drawEditor(self: *App) !void {
        return @import("views/editor.zig").drawEditor(self);
    }
    pub fn drawRun(self: *App, bytes: []const u8, start: usize, end: usize, x: f32, baseline: f32, color: [4]u8, e: Rect, italic: bool) !void {
        return @import("views/editor.zig").drawRun(self, bytes, start, end, x, baseline, color, e, italic);
    }
    pub fn drawDialog(self: *App) !void {
        return @import("views/dialogs.zig").drawDialog(self);
    }
};
