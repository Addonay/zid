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
const project_panel = @import("views/project_panel.zig");
const keymap = @import("keymap.zig");
pub const icon_theme = @import("icon_theme.zig");
const LineInput = @import("line_input.zig").LineInput;
pub const commands = @import("input/commands.zig");
pub const pickers = @import("input/pickers.zig");
const max_line_bytes = 64 * 1024;

/// Type-check view modules that are developed ahead of their integration.
fn analyzeAll(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |name| _ = &@field(T, name);
}
comptime {
    analyzeAll(@import("views/picker_view.zig"));
    analyzeAll(@import("views/keymap_editor.zig"));
}

const modals = @import("views/modals.zig");
const recent_projects = @import("recent_projects.zig");

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
    /// Bundled Zed default keymap plus the user's Zed-format keymap.json.
    keymap: keymap.Keymap,
    /// Keystrokes of a partially typed chord (e.g. after `ctrl-k`).
    pending: keymap.Chord = .{},
    focus_pairs: [2][2][]const u8 = undefined,
    modal: union(enum) { none, picker: pickers.Picker, go_to_line: pickers.GoToLine } = .none,
    keymap_editor_open: bool = false,
    keymap_tab: Rect = .{},
    keymap_view: @import("views/keymap_editor.zig").State = .{},
    /// Per-frame scratch memory (picker labels, chord text), reset at the start of each draw.
    frame_arena: std.heap.ArenaAllocator,
    /// Zed's recent projects, persisted in $XDG_DATA_HOME/zid/recent_projects.json.
    recent: recent_projects.RecentProjects,
    data_dir: []u8,
    persist_recent: bool = true,
    clipboard_whole_line: bool = false,
    /// Font size from settings.json; ResetBufferFontSize returns here.
    saved_font_size: u32 = 15,
    config_root: []u8,
    panel_open: bool = true,
    panel_focus: bool = false,
    panel_scroll: usize = 0,
    panel_row: usize = 0,
    tabs_first: usize = 0,
    tab_hits: std.ArrayList(struct { rect: Rect, index: usize }) = .empty,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    dialog: enum { none, open, save, close, quit, settings } = .none,
    project_collapsed: bool = false,
    /// Settings dialog state: page index, focused item among visible items, content scroll (px),
    /// search query, and whether the focused item's dropdown is expanded.
    settings_category: usize = 0,
    settings_row: usize = 0,
    settings_scroll: f32 = 0,
    settings_query: [64]u8 = undefined,
    settings_query_len: usize = 0,
    settings_dropdown: bool = false,
    /// Screenshot/testing override for the device pixel density.
    forced_scale: ?f32 = null,
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
        return initWithOptions(gpa, io, workspace, env, 1200, 800, false);
    }
    pub fn initWithOptions(gpa: std.mem.Allocator, io: std.Io, workspace: *zid.Workspace, env: *const std.process.Environ.Map, win_w: usize, win_h: usize, hidden: bool) !App {
        const home = env.get("HOME") orelse ".";
        const root = if (env.get("XDG_CONFIG_HOME")) |p| try std.fs.path.join(gpa, &.{ p, "zid" }) else try std.fs.path.join(gpa, &.{ home, ".config", "zid" });
        errdefer gpa.free(root);
        try sdl.init(.{ .video = true });
        errdefer sdl.shutdown();
        const window = try sdl.video.Window.init("Zid", win_w, win_h, .{ .resizable = true, .borderless = true, .transparent = true, .hidden = hidden, .high_pixel_density = true });
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
        const data_dir = try recent_projects.defaultDir(gpa, env);
        errdefer gpa.free(data_dir);
        var self: App = .{ .gpa = gpa, .io = io, .workspace = workspace, .window = window, .renderer = renderer, .layout = layout, .project = project, .config_root = root, .settings = initial_settings, .controls = controls, .keymap = keymap.Keymap.init(gpa), .frame_arena = .init(gpa), .recent = recent_projects.RecentProjects.init(gpa), .data_dir = data_dir, .saved_font_size = initial_settings.font_size };
        self.reloadConfig() catch |err| self.notice("Settings: {s}", .{@errorName(err)});
        self.recent.load(io, data_dir) catch |err| log.warn("recent projects: {s}", .{@errorName(err)});
        // Headless (screenshot) runs must not rewrite the user's recent projects.
        self.persist_recent = !hidden;
        self.touchRecent(workspace.root) catch |err| log.warn("recent projects: {s}", .{@errorName(err)});
        sdl.keyboard.startTextInput(window) catch {};
        log.info("window ready: SDL_GPU Vulkan, project={s}, files={d}", .{ workspace.root, workspace.files.items.len });
        return self;
    }
    pub fn deinit(self: *App) void {
        self.keymap.deinit();
        self.closeModal();
        self.keymap_view.deinit(self.gpa);
        self.frame_arena.deinit();
        self.recent.deinit();
        self.gpa.free(self.data_dir);
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
        if (s.font_size != self.settings.font_size) self.renderer.setMonoSize(s.font_size) catch |err| {
            self.notice("Font size {d} unavailable: {s}", .{ s.font_size, @errorName(err) });
            s.font_size = self.settings.font_size;
        };
        const key_path = try std.fs.path.join(self.gpa, &.{ self.config_root, "keymap.json" });
        defer self.gpa.free(key_path);
        // Build the new keymap fully before replacing the current one.
        var next = keymap.Keymap.init(self.gpa);
        errdefer next.deinit();
        try next.load(@import("keymap_assets").zed_default_linux, .default);
        if (std.Io.Dir.cwd().readFileAlloc(self.io, key_path, self.gpa, .limited(4 * 1024 * 1024))) |bytes| {
            defer self.gpa.free(bytes);
            next.load(bytes, .user) catch |err| self.notice("keymap.json: {s}; using Zed defaults", .{@errorName(err)});
        } else |err| if (err != error.FileNotFound) return err;
        self.keymap.deinit();
        self.keymap = next;
        self.pending = .{};
        self.saved_font_size = s.font_size;
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
    pub fn event(self: *App, e: sdl.events.Event) !void {
        return @import("input/events.zig").event(self, e);
    }
    pub fn runCommand(self: *App, c: commands.Command) !void {
        return commands.run(self, c, null);
    }
    /// Opens a file from the config directory (creating an empty JSON array/object if missing).
    pub fn openConfigFile(self: *App, name: []const u8) !void {
        const path = try std.fs.path.join(self.gpa, &.{ self.config_root, name });
        defer self.gpa.free(path);
        std.Io.Dir.cwd().createDirPath(self.io, self.config_root) catch {};
        if (std.Io.Dir.cwd().statFile(self.io, path, .{})) |_| {} else |err| {
            if (err != error.FileNotFound) return err;
            const initial = if (std.mem.eql(u8, name, "keymap.json")) "// Zed-format keymap: [{ \"context\": \"Editor\", \"bindings\": { \"ctrl-shift-k\": \"editor::DeleteLine\" } }]\n[]\n" else "{}\n";
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = initial });
        }
        try self.workspace.open(path);
        self.closeModal();
        self.dialog = .none;
        self.keymap_editor_open = false;
        self.panel_focus = false;
    }
    pub fn openKeymapEditor(self: *App) !void {
        self.closeModal();
        self.keymap_editor_open = true;
        self.panel_focus = false;
        try self.lineInputChanged();
    }
    pub fn closeModal(self: *App) void {
        switch (self.modal) {
            .picker => |*p| p.deinit(self.gpa),
            else => {},
        }
        self.modal = .none;
    }
    pub fn togglePicker(self: *App, kind: pickers.Kind) !void {
        if (self.modal == .picker and self.modal.picker.kind == kind) {
            self.closeModal();
            return;
        }
        self.closeModal();
        self.dialog = .none;
        self.modal = .{ .picker = .{ .kind = kind } };
        try pickers.refilter(self, &self.modal.picker);
    }
    pub fn toggleGoToLine(self: *App) void {
        if (self.modal == .go_to_line) {
            self.closeModal();
            return;
        }
        self.closeModal();
        const doc = self.workspace.current();
        self.modal = .{ .go_to_line = .{ .restore_cursor = doc.cursor, .restore_anchor = doc.anchor, .restore_scroll = doc.scroll_line } };
    }
    /// Called after a modal's or view's line input changed.
    pub fn lineInputChanged(self: *App) !void {
        switch (self.modal) {
            .picker => |*p| try pickers.refilter(self, p),
            .go_to_line => |g| {
                const doc = self.workspace.current();
                if (pickers.goToLineTarget(doc, g.input.text())) |offset| {
                    doc.move(offset, false);
                    try self.revealCursor();
                }
            },
            .none => if (self.keymap_editor_open) try modals.refilterKeymap(self),
        }
    }
    pub fn menuCommand(self: *App, c: commands.Command) !void {
        switch (self.modal) {
            .picker => |*p| {
                const count = p.entries.items.len;
                switch (c) {
                    .@"menu::SelectNext" => if (count > 0) {
                        p.selected = (p.selected + 1) % count;
                    },
                    .@"menu::SelectPrevious" => if (count > 0) {
                        p.selected = (p.selected + count - 1) % count;
                    },
                    .@"menu::SelectFirst" => p.selected = 0,
                    .@"menu::SelectLast" => p.selected = count -| 1,
                    .@"menu::Cancel" => self.closeModal(),
                    .@"menu::Confirm", .@"menu::SecondaryConfirm" => try self.confirmPicker(),
                    else => {},
                }
                return;
            },
            .go_to_line => |g| {
                const doc = self.workspace.current();
                if (c == .@"menu::Cancel") {
                    doc.setSelection(g.restore_anchor, g.restore_cursor);
                    doc.scroll_line = g.restore_scroll;
                } else if (pickers.goToLineTarget(doc, g.input.text())) |offset| {
                    doc.move(offset, false);
                    try self.revealCursor();
                }
                self.closeModal();
                return;
            },
            .none => {},
        }
        if (self.panel_focus) {
            const total = project_panel.totalRows(self);
            switch (c) {
                .@"menu::SelectNext" => self.panel_row = @min(self.panel_row + 1, total - 1),
                .@"menu::SelectPrevious" => self.panel_row -|= 1,
                .@"menu::SelectFirst" => self.panel_row = 0,
                .@"menu::SelectLast" => self.panel_row = total - 1,
                .@"menu::Confirm" => try self.activateProject(),
                .@"menu::Cancel" => self.panel_focus = false,
                else => {},
            }
            self.keepPanelVisible();
            return;
        }
        if (self.keymap_editor_open) modals.keymapMenu(self, c);
    }
    fn confirmPicker(self: *App) !void {
        const p = &self.modal.picker;
        if (p.entries.items.len == 0) return;
        const index = p.entries.items[@min(p.selected, p.entries.items.len - 1)].index;
        const kind = p.kind;
        self.closeModal();
        switch (kind) {
            .file_finder => {
                const rel = self.workspace.files.items[index];
                try self.workspace.open(rel);
                self.keymap_editor_open = false;
                self.panel_focus = false;
            },
            .command_palette => try commands.run(self, commands.all()[index], null),
            .recent_projects => {
                const path = try self.gpa.dupe(u8, self.recentPath(index));
                defer self.gpa.free(path);
                try self.openProject(path);
            },
            .tab_switcher => {
                self.workspace.active = pickers.tabOrder(self, index);
                self.keymap_editor_open = false;
            },
        }
        self.syntax_doc = std.math.maxInt(usize);
    }
    /// Switches the workspace root to another project (Zed's recent projects).
    pub fn openProject(self: *App, path: []const u8) !void {
        try self.workspace.setRoot(path);
        try self.refreshProject();
        self.panel_row = 0;
        self.panel_scroll = 0;
        try self.touchRecent(path);
        self.notice("Opened project {s}", .{path});
    }
    pub fn touchRecent(self: *App, path: []const u8) !void {
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        try self.recent.touch(path, now);
        if (self.persist_recent) self.recent.save(self.io, self.data_dir) catch |err| log.warn("recent projects: {s}", .{@errorName(err)});
    }
    pub fn recentCount(self: *App) usize {
        return self.recent.entries.items.len;
    }
    pub fn recentPath(self: *App, index: usize) []const u8 {
        return self.recent.entries.items[index].path;
    }
    pub fn isCurrentProject(self: *App, index: usize) bool {
        return std.mem.eql(u8, self.recent.entries.items[index].path, self.workspace.root);
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
        const panel = self.layout.rect(self.layout.panel) catch return;
        const fit = @max(1, project_panel.visibleRows(panel.h));
        if (self.panel_row < self.panel_scroll) self.panel_scroll = self.panel_row;
        if (self.panel_row >= self.panel_scroll + fit) self.panel_scroll = self.panel_row - fit + 1;
    }
    /// Largest useful panel scroll offset: the last row sits at the bottom edge.
    pub fn maxPanelScroll(self: *App) usize {
        const panel = self.layout.rect(self.layout.panel) catch return 0;
        return project_panel.totalRows(self) -| project_panel.visibleRows(panel.h);
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
        self.panel_row = @min(self.panel_row, project_panel.totalRows(self) - 1);
    }
    pub fn activateProject(self: *App) !void {
        if (self.panel_row == 0) {
            self.project_collapsed = !self.project_collapsed;
            return;
        }
        if (self.project_collapsed or self.visible.items.len == 0) return;
        const vis_idx = self.panel_row - 1;
        if (vis_idx >= self.visible.items.len) return;
        const entry = &self.project.entries.items[self.visible.items[vis_idx]];
        if (entry.directory) {
            entry.collapsed = !entry.collapsed;
            try self.project.visible(self.gpa, &self.visible);
        } else {
            try self.workspace.open(entry.path);
            self.panel_focus = false;
            self.message_len = 0;
        }
    }
    pub fn expandOrEnterProject(self: *App) !void {
        if (self.panel_row == 0) {
            if (self.project_collapsed) {
                self.project_collapsed = false;
            } else if (self.visible.items.len > 0) {
                self.panel_row = 1;
            }
            return;
        }
        if (self.project_collapsed or self.visible.items.len == 0) return;
        const vis_idx = self.panel_row - 1;
        if (vis_idx >= self.visible.items.len) return;
        const entry = &self.project.entries.items[self.visible.items[vis_idx]];
        if (entry.directory) {
            if (entry.collapsed) {
                entry.collapsed = false;
                try self.project.visible(self.gpa, &self.visible);
            } else if (self.panel_row < self.visible.items.len) {
                self.panel_row += 1;
            }
        }
    }
    pub fn collapseOrParentProject(self: *App) !void {
        if (self.panel_row == 0) {
            self.project_collapsed = true;
            return;
        }
        if (self.project_collapsed or self.visible.items.len == 0) return;
        const vis_idx = self.panel_row - 1;
        if (vis_idx >= self.visible.items.len) return;
        const entry = &self.project.entries.items[self.visible.items[vis_idx]];
        if (entry.directory and !entry.collapsed) {
            entry.collapsed = true;
            try self.project.visible(self.gpa, &self.visible);
            return;
        }
        if (entry.depth == 0) {
            self.panel_row = 0;
            return;
        }
        var r = vis_idx;
        while (r > 0) {
            r -= 1;
            const prev = self.project.entries.items[self.visible.items[r]];
            if (prev.directory and prev.depth < entry.depth) {
                self.panel_row = r + 1;
                return;
            }
        }
        self.panel_row = 0;
    }
    /// Persist the in-memory settings; the config watcher then sees our own write as current.
    pub fn saveAndApplySettings(self: *App) !void {
        config.saveSettings(self.gpa, self.io, self.config_root, self.settings) catch |err| {
            self.notice("Could not save settings: {s}", .{@errorName(err)});
            return;
        };
        self.config_stamp = self.configurationStamp();
    }
    pub fn lineBytes(self: *App, doc: *zid.Document, row: usize) []const u8 {
        const start = doc.lineStart(row);
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
        const offset = @min(line.len, doc.cursor - doc.lineStart(row));
        const x = self.textWidth(line[0..offset]);
        const editor = try self.layout.rect(self.layout.editor);
        const view = @max(20, editor.w - 90);
        if (x < doc.scroll_x) doc.scroll_x = x;
        if (x > doc.scroll_x + view) doc.scroll_x = x - view;
    }
    pub fn placeCursor(self: *App, mx: f32, my: f32, extend: bool) !void {
        const doc = self.workspace.current();
        const e = try self.layout.rect(self.layout.editor);
        const row = @min(doc.lineCount() - 1, doc.scroll_line + @as(usize, @intFromFloat(@max(0, my - e.y - 8) / @as(f32, @floatFromInt(self.settings.line_height)))));
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
        doc.move(doc.lineStart(row) + offset, extend);
        self.caret_visible = true;
        self.last_blink = sdl.timer.getMillisecondsSinceInit();
    }
    pub fn click(self: *App, mx: f32, my: f32, clicks: u8) !void {
        if (self.dialog == .settings) {
            try @import("views/settings_dialog.zig").handleClick(self, mx, my);
            return;
        }
        if (self.dialog != .none) return;
        if (try modals.clickModal(self, mx, my)) return;
        const status = try self.layout.rect(self.layout.status);
        if (status.contains(mx, my)) {
            if (mx < 42) {
                try self.runCommand(.@"workspace::ToggleLeftDock");
                return;
            }
            if (mx >= status.w - 36) {
                try self.runCommand(.@"zed::OpenSettings");
                return;
            }
        }
        if (my < 34) {
            if (title_bar.controlAt(self, mx, my)) |i| switch (i) {
                0 => try self.window.minimize(),
                1 => if (self.window.getFlags().maximized) {
                    try self.window.restore();
                } else {
                    try self.window.maximize();
                },
                else => try self.runCommand(.@"zed::Quit"),
            } else if (mx < 36) try self.runCommand(.@"workspace::ToggleLeftDock");
            return;
        }
        if (self.keymap_editor_open and self.keymap_tab.contains(mx, my)) {
            if (mx > self.keymap_tab.x + self.keymap_tab.w - 24) self.keymap_editor_open = false;
            return;
        }
        for (self.tab_hits.items) |hit| if (hit.rect.contains(mx, my)) {
            self.workspace.active = hit.index;
            self.panel_focus = false;
            self.keymap_editor_open = false;
            if (mx > hit.rect.x + hit.rect.w - 24) try self.runCommand(.@"pane::CloseActiveItem");
            return;
        };
        const panel = try self.layout.rect(self.layout.panel);
        if (panel.contains(mx, my)) {
            self.panel_focus = true;
            if (project_panel.rowAt(self, panel, my)) |row| {
                self.panel_row = row;
                try self.activateProject();
            }
            return;
        }
        if (self.keymap_editor_open and modals.clickKeymap(self, mx, my)) {
            self.panel_focus = false;
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
    /// Draws an icon from the active icon theme (colored icons keep their colors).
    pub fn drawIcon(self: *App, icon: icon_theme.Icon, x: f32, y: f32, size: f32, tint: [4]u8) !void {
        if (icon.colored) return self.renderer.colorIcon(icon.svg, x, y, size, 255);
        return self.renderer.icon(icon.svg, x, y, size, tint);
    }
    pub fn fileIcon(self: *App, path: []const u8) icon_theme.Icon {
        return icon_theme.file(self.settings.icon_theme, path);
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
        _ = self.frame_arena.reset(.retain_capacity);
        try self.layout.resize(@floatFromInt(width), @floatFromInt(height), if (self.panel_open) @min(@as(f32, @floatFromInt(self.settings.panel_width)), @as(f32, @floatFromInt(width)) * 0.45) else 0);
        try self.project.visible(self.gpa, &self.visible);
        const pixel_w, _ = self.window.getSizeInPixels() catch .{ width, height };
        const scale = self.forced_scale orelse @as(f32, @floatFromInt(pixel_w)) / @as(f32, @floatFromInt(width));
        try self.renderer.begin(@intCast(width), @intCast(height), scale);
        errdefer self.renderer.abortFrame();
        const t = self.settings.theme;
        try self.fill(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) }, t.background);
        const project_name = std.fs.path.basename(self.workspace.root);
        self.renderer.roundWindow(if (self.window.getFlags().maximized or self.window.getFlags().fullscreen) 0 else 10);
        try title_bar.draw(self);
        self.renderer.reserveOverlay();
        try self.drawPanel();
        try self.drawTabs();
        if (self.keymap_editor_open) try modals.drawKeymapEditor(self) else try self.drawEditor();
        self.renderer.drawOverlay();
        if (!self.keymap_editor_open) try @import("views/editor.zig").drawCaret(self);
        const status = try self.layout.rect(self.layout.status);
        try self.fill(status, t.status);
        try self.renderer.rect(0, status.y, status.w, 1, t.border);
        try self.renderer.icon(@import("icons").svg("panel_left"), 12, status.y + 5, 16, t.muted);
        try self.renderer.icon(@import("icons").svg("ui:settings"), status.w - 26, status.y + 5, 16, t.muted);
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
        const text = try std.fmt.bufPrint(&info, "{d}:{d}    {s}    UTF-8    {s}    Spaces: {d}", .{ row + 1, doc.cursor - doc.lineStart(row) + 1, if (doc.crlf) @as([]const u8, "CRLF") else "LF", lang.displayName(), self.settings.tab_size });
        try self.renderer.textUi(text, @max(52, status.w - self.renderer.widthUi(text) - 40), status.y + 18, t.text);
        try modals.drawModal(self);
        if (self.dialog != .none) try self.drawDialog();
        try self.renderer.end();
        var title_buffer: [1024]u8 = undefined;
        const name = if (doc.path) |path| std.fs.path.basename(path) else "untitled";
        const window_title = std.fmt.bufPrintSentinel(&title_buffer, "{s}{s} — {s} — Zid", .{ if (doc.dirty()) @as([]const u8, "● ") else "", name, project_name }, 0) catch "Zid";
        try self.window.setTitle(window_title);
    }
    pub fn drawPanel(self: *App) !void {
        return project_panel.drawPanel(self);
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
