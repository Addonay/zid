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
const onboarding_view = @import("views/onboarding.zig");
const context_menu = @import("views/context_menu.zig");
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
    database: @import("database.zig").State = .{},
    lsp: ?@import("lsp.zig").Controller = null,
    lsp_root: ?[]u8 = null,
    lsp_dirty: bool = false,
    lsp_attempted: bool = false,
    hover_scroll: usize = 0,
    hover_rect: Rect = .{},
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
    search_open: bool = false,
    search_focused: bool = false,
    search_input: LineInput = .{},
    replace_input: LineInput = .{},
    replace_open: bool = false,
    replace_focused: bool = false,
    search_case_sensitive: bool = true,
    search_doc: usize = std.math.maxInt(usize),
    search_revision: u64 = std.math.maxInt(u64),
    search_count: usize = 0,
    search_capped: bool = false,
    keymap_editor_open: bool = false,
    /// Onboarding workspace item (`zed::OpenOnboarding`); null when closed.
    onboarding: ?@import("views/onboarding.zig").State = null,
    onboarding_tab: Rect = .{},
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
    project_edit: ?@import("project_edit.zig").State = null,
    panel_scroll: usize = 0,
    panel_row: usize = 0,
    panel_resizing: bool = false,
    panel_document: u64 = 0,
    tabs_first: usize = 0,
    tab_hits: std.ArrayList(struct { rect: Rect, index: usize }) = .empty,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    message_until: u64 = 0,
    dialog: enum { none, open, save, close, quit, settings } = .none,
    project_collapsed: bool = false,
    title_branch: [128]u8 = undefined,
    title_branch_len: usize = 0,
    /// Settings dialog state: page index, focused item among visible items, content scroll (px),
    /// search query, and whether the focused item's dropdown is expanded.
    settings_category: usize = 0,
    settings_row: usize = 0,
    settings_scroll: f32 = 0,
    settings_query: [64]u8 = undefined,
    settings_query_len: usize = 0,
    settings_dropdown: bool = false,
    settings_focus: enum { search, nav, controls } = .search,
    /// Focused visible navbar entry when `settings_focus == .nav`.
    settings_nav_index: usize = 0,
    /// Per-settings-page navbar expansion bitmask (one bit per Page tag).
    settings_expanded: u32 = 0,
    /// Item index whose settings link was last copied (check feedback).
    settings_copied: ?usize = null,
    /// settings.json failed to parse; the dialog shows Zed's warning banner.
    settings_document_error: bool = false,
    settings_editing_number: bool = false,
    settings_number: [4096]u8 = undefined,
    settings_document: ?@import("settings_document.zig").Document = null,
    settings_nav_scroll: f32 = 0,
    settings_editing_json: bool = false,
    settings_replace_input: bool = false,
    settings_number_len: usize = 0,
    settings_option: usize = 0,
    /// Screenshot/testing override for the device pixel density.
    forced_scale: ?f32 = null,
    path_input: std.ArrayList(u8) = .empty,
    dragging: bool = false,
    close_after_save: bool = false,
    /// Open context menu (right-click menus, title-bar menus).
    context_menu: ?@import("views/context_menu.zig").Menu = null,
    /// Open in-window prompt (unsaved changes, removal confirmations).
    prompt: ?@import("views/prompt.zig").Prompt = null,
    /// System path picker in flight (`use_system_path_prompts`).
    path_prompt: @import("workspace_actions.zig").PathPrompt = .{},
    /// Set while `zed::Quit` is working through dirty documents.
    quitting: bool = false,
    /// Background work finished (a decoded image); draw on the next loop pass.
    redraw_requested: bool = false,
    /// Image viewers for image documents (decoded textures, zoom, pan).
    image_views: @import("views/image_view.zig").State = .{},
    /// Project-relative paths of recently active files, most recent first (file finder
    /// history). Owned strings.
    file_history: std.ArrayList([]u8) = .empty,
    /// File finder preview pane (Zed `picker::TogglePreview`).
    picker_preview: bool = true,
    /// Cached preview text for the file-finder selection.
    preview_file: ?usize = null,
    preview_bytes: []u8 = &.{},
    tooltip: @import("views/tooltip.zig").State = .{},
    /// Last account status drawn; a change redraws the title bar.
    account_seen: @import("account.zig").Status = .signed_out,
    /// Documents (instance ids) a multi-close is closing once its prompt is answered.
    close_ids: [256]u64 = undefined,
    close_count: usize = 0,
    /// Project-panel file clipboard (Cut/Copy then Paste).
    file_clip: [std.fs.max_path_bytes]u8 = undefined,
    file_clip_len: usize = 0,
    file_clip_cut: bool = false,
    /// Zed account (sign in through zed.dev).
    account: @import("account.zig").Account = .{},
    env_home: ?[]const u8 = null,
    env_data_home: ?[]const u8 = null,
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
    ts_layer: ?*syntax.ts.Layer = null,
    ts_lang: syntax.Language = .plain,
    line: [max_line_bytes]u8 = undefined,
    expanded: [max_line_bytes * 4]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, workspace: *zid.Workspace, env: *const std.process.Environ.Map) !App {
        return initWithOptions(gpa, io, workspace, env, 1200, 800, false);
    }
    pub fn initWithOptions(gpa: std.mem.Allocator, io: std.Io, workspace: *zid.Workspace, env: *const std.process.Environ.Map, win_w: usize, win_h: usize, hidden: bool) !App {
        const home = env.get("HOME") orelse ".";
        const root = if (env.get("XDG_CONFIG_HOME")) |p| try std.fs.path.join(gpa, &.{ p, "zid" }) else try std.fs.path.join(gpa, &.{ home, ".config", "zid" });
        errdefer gpa.free(root);
        log.info("configuration directory: {s}", .{root});
        try sdl.init(.{ .video = true });
        config.system_appearance = systemAppearanceFromSdl();
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
        var project = try Project.initWithOptions(gpa, workspace.files.items, .{ .directories = workspace.directories.items, .auto_fold_dirs = initial_settings.auto_fold_dirs, .sort_mode = initial_settings.panel_sort_mode });
        errdefer project.deinit();
        for (project.entries.items) |*entry| if (entry.directory) {
            entry.collapsed = true;
        };
        const controls = WindowControls.init(gpa, io, home);
        const data_dir = try recent_projects.defaultDir(gpa, env);
        errdefer gpa.free(data_dir);
        var self: App = .{ .gpa = gpa, .io = io, .workspace = workspace, .window = window, .renderer = renderer, .layout = layout, .project = project, .config_root = root, .settings = initial_settings, .controls = controls, .keymap = keymap.Keymap.init(gpa), .frame_arena = .init(gpa), .recent = recent_projects.RecentProjects.init(gpa), .data_dir = data_dir, .saved_font_size = initial_settings.font_size };
        self.env_home = env.get("HOME");
        self.env_data_home = env.get("XDG_DATA_HOME");
        self.panel_open = initial_settings.panel_starts_open;
        self.title_branch_len = (@import("title_info.zig").branch(gpa, io, workspace.root, &self.title_branch) catch @as([]const u8, "")).len;
        self.reloadConfig() catch |err| self.notice("Settings: {s}", .{@errorName(err)});
        self.recent.load(io, data_dir) catch |err| log.warn("recent projects: {s}", .{@errorName(err)});
        // Headless (screenshot) runs must not rewrite the user's recent projects.
        self.persist_recent = !hidden;
        if (!hidden) {
            self.lsp_root = gpa.dupe(u8, workspace.root) catch null;
        }
        self.touchRecent(workspace.root) catch |err| log.warn("recent projects: {s}", .{@errorName(err)});
        sdl.keyboard.startTextInput(window) catch {};
        log.info("window ready: SDL_GPU Vulkan, project={s}, files={d}", .{ workspace.root, workspace.files.items.len });
        return self;
    }
    pub fn systemAppearanceFromSdl() config.Appearance {
        const theme = sdl.video.getSystemTheme() orelse return .dark;
        return if (theme == .light) .light else .dark;
    }
    /// Moves the active document's file to the front of the file-finder history.
    fn recordHistory(self: *App) void {
        const doc = self.workspace.currentOrNull() orelse return;
        const path = doc.path orelse return;
        const rel = @import("input/pickers.zig").relativeToRoot(self.workspace.root, path) orelse return;
        if (self.file_history.items.len > 0 and std.mem.eql(u8, self.file_history.items[0], rel)) return;
        for (self.file_history.items, 0..) |existing, i| if (std.mem.eql(u8, existing, rel)) {
            const owned = self.file_history.orderedRemove(i);
            self.file_history.insert(self.gpa, 0, owned) catch self.gpa.free(owned);
            return;
        };
        const owned = self.gpa.dupe(u8, rel) catch return;
        self.file_history.insert(self.gpa, 0, owned) catch return self.gpa.free(owned);
        if (self.file_history.items.len > 64) self.gpa.free(self.file_history.pop().?);
    }
    pub fn deinit(self: *App) void {
        self.image_views.deinit(self);
        for (self.file_history.items) |p| self.gpa.free(p);
        self.file_history.deinit(self.gpa);
        self.gpa.free(self.preview_bytes);
        self.account.deinit();
        @import("project_edit.zig").cancel(self);
        if (self.settings_document) |*document| document.deinit();
        if (self.lsp) |*lsp| lsp.deinit();
        if (self.lsp_root) |root| self.gpa.free(root);
        self.database.deinit(self.io);
        self.keymap.deinit();
        self.closeModal();
        self.keymap_view.deinit(self.gpa);
        self.frame_arena.deinit();
        self.recent.deinit();
        self.gpa.free(self.data_dir);
        self.checkpoints.deinit(self.gpa);
        if (self.ts_layer) |layer| layer.deinit();
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
        if (y < 34 and userdata != null and @as(f32, @floatFromInt(x)) >= @as(f32, @floatFromInt(w)) - title_bar.controlsInset(userdata.?) - 38) return .normal;
        if (y < 34) if (userdata) |self| {
            if (title_bar.segmentAt(self, @floatFromInt(x), @floatFromInt(y)) != null) return .normal;
        };
        if (y < 34 and x > 40 and @as(f32, @floatFromInt(x)) < @as(f32, @floatFromInt(w)) - (if (userdata) |self| title_bar.controlsInset(self) else 126)) return .draggable;
        return .normal;
    }
    pub fn notice(self: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..0];
        self.message_len = text.len;
        self.message_until = sdl.timer.getMillisecondsSinceInit() +| 5000;
        log.info("{s}", .{text});
    }
    pub fn currentDiagnostics(self: *const App) ?zid.lsp.protocol.Diagnostics {
        const doc = self.workspace.currentOrNull() orelse return null;
        const path = doc.path orelse return null;
        const lsp = if (self.lsp) |*controller| controller else return null;
        return lsp.diagnosticsFor(path, doc.instance_id, doc.revision);
    }
    pub fn requestHover(self: *App) void {
        if (self.workspace.currentOrNull() == null) return;
        if (self.lsp) |*lsp| {
            self.hover_scroll = 0;
            lsp.requestHover(self.workspace.current()) catch |err| self.notice("Hover: {s}", .{@errorName(err)});
        } else self.notice("ZLS is not available for this document", .{});
    }
    pub fn requestDefinition(self: *App) void {
        if (self.workspace.currentOrNull() == null) return;
        if (self.lsp) |*lsp| {
            lsp.requestDefinition(self.workspace.current()) catch |err| self.notice("Definition: {s}", .{@errorName(err)});
        } else self.notice("ZLS is not available for this document", .{});
    }
    /// Opens a local target and maps the negotiated LSP column to a byte offset.
    fn navigateDefinition(self: *App, target: @import("lsp.zig").Definition) !void {
        const previous = self.workspace.active;
        errdefer self.workspace.active = previous;
        try self.workspace.open(target.path);
        const doc = self.workspace.currentOrNull() orelse return;
        if (doc.large != null or doc.preview_only or doc.buffer.len() > @import("lsp.zig").max_document_bytes) return error.TargetTooLarge;
        const text = try doc.buffer.toOwnedSlice(self.gpa);
        defer self.gpa.free(text);
        const offset = try zid.lsp.position.toOffset(text, target.position, target.encoding);
        doc.move(offset, false);
        self.panel_focus = false;
        self.keymap_editor_open = false;
        try self.revealCursor();
    }
    pub fn dismissHover(self: *App) bool {
        if (self.workspace.currentOrNull() == null) return false;
        if (self.lsp) |*lsp| {
            if (lsp.definition_pending) {
                lsp.clearDefinition();
                lsp.clearHover();
                self.hover_rect = .{};
                return true;
            }
            if (lsp.hover_pending or lsp.hoverFor(self.workspace.current()) != null) {
                lsp.clearHover();
                self.hover_rect = .{};
                return true;
            }
        }
        return false;
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
        const keymaps = @import("keymap_assets");
        if (s.base_keymap != .None) {
            try next.load(keymaps.platform_default, .default);
            if (keymaps.base(s.base_keymap)) |bytes| try next.load(bytes, .base);
            if (s.vim_mode or s.helix_mode) try next.load(keymaps.vim, .vim);
            try next.load(keymaps.specific_overrides, .default);
        }
        if (std.Io.Dir.cwd().readFileAlloc(self.io, key_path, self.gpa, .limited(4 * 1024 * 1024))) |bytes| {
            defer self.gpa.free(bytes);
            next.load(bytes, .user) catch |err| self.notice("keymap.json: {s}; using Zed defaults", .{@errorName(err)});
        } else |err| if (err != error.FileNotFound) return err;
        self.keymap.deinit();
        self.keymap = next;
        self.pending = .{};
        self.saved_font_size = s.font_size;
        self.settings = s;
        if (self.settings_document != null) {
            const document = try @import("settings_document.zig").Document.load(self.gpa, self.io, self.config_root);
            if (self.settings_document) |*old| old.deinit();
            self.settings_document = document;
        }
        self.caret_visible = self.focused;
        self.last_blink = sdl.timer.getMillisecondsSinceInit();
    }
    fn cancelInactiveCopies(self: *App) void {
        for (self.workspace.documents.items, 0..) |*doc, i| {
            if (i != self.workspace.active) if (doc.large) |*large| large.cancelCopy();
        }
    }

    fn pollLargeCopy(self: *App) void {
        const doc = self.workspace.currentOrNull() orelse return;
        const large = if (doc.large) |*l| l else return;
        const result = large.worker.takeCopy() orelse return;
        defer if (result.bytes) |bytes| self.gpa.free(bytes);
        if (large.expected_copy == null or large.expected_copy.? != result.generation) return;
        large.expected_copy = null;
        if (result.failure) |err| {
            self.notice("Copy: {s}", .{@errorName(err)});
        } else if (result.bytes) |bytes| {
            sdl.clipboard.setText(bytes) catch |err| {
                self.notice("Copy: {s}", .{@errorName(err)});
                return;
            };
            self.clipboard_whole_line = false;
        }
    }

    /// Memory-only completion pump shared by the interactive loop and scripted
    /// offscreen frames. File operations remain on each document's worker.
    pub fn pollAsync(self: *App) void {
        self.database.poll(self.io);
        @import("workspace_actions.zig").poll(self) catch |err| self.notice("{s}", .{@errorName(err)});
        if (@import("views/image_view.zig").poll(self)) self.redraw_requested = true;
        self.account.poll(self);
        if (self.lsp_root) |root| {
            if (!std.mem.eql(u8, root, self.workspace.root)) {
                if (self.lsp) |*lsp| lsp.deinit();
                self.lsp = null;
                self.gpa.free(root);
                self.lsp_root = self.gpa.dupe(u8, self.workspace.root) catch null;
                self.lsp_attempted = false;
                self.lsp_dirty = true;
            }
        }
        if (self.lsp_root != null and !self.lsp_attempted) {
            for (self.workspace.documents.items) |*doc| {
                const path = doc.path orelse continue;
                if (doc.large != null or doc.preview_only or doc.buffer.len() > @import("lsp.zig").max_document_bytes or !std.mem.endsWith(u8, path, ".zig")) continue;
                self.lsp_attempted = true;
                self.lsp = @import("lsp.zig").Controller.start(self.gpa, self.io, self.workspace.root, &.{"zls"}) catch |err| blk: {
                    self.notice("ZLS unavailable: {s}", .{@errorName(err)});
                    break :blk null;
                };
                break;
            }
        }
        if (self.lsp) |*lsp| {
            const generation = lsp.generation;
            lsp.poll(self.workspace) catch |err| {
                self.notice("ZLS stopped: {s}", .{@errorName(err)});
                lsp.deinit();
                self.lsp = null;
                self.lsp_dirty = true;
                return;
            };
            if (generation != lsp.generation) self.lsp_dirty = true;
            if (self.workspace.currentOrNull()) |active_doc| if (lsp.takeDefinition(active_doc)) |target_value| {
                var target = target_value;
                defer target.deinit(self.gpa);
                self.navigateDefinition(target) catch |err| self.notice("Definition: {s}", .{@errorName(err)});
                self.lsp_dirty = true;
            };
        }
        self.cancelInactiveCopies();
        self.pollLargeCopy();
        if (self.workspace.currentOrNull()) |doc| if (doc.large) |*large| {
            _ = large.poll(&.{});
        };
    }

    pub fn run(self: *App) !void {
        self.window.setHitTest(App, hitTest, self) catch {};
        try self.draw();
        self.last_blink = sdl.timer.getMillisecondsSinceInit();
        self.config_stamp = self.configurationStamp();
        while (self.running) {
            const now = sdl.timer.getMillisecondsSinceInit();
            const active_doc = self.workspace.currentOrNull();
            const blink = (active_doc != null and active_doc.?.large == null or self.modal != .none) and self.focused and self.settings.cursor_blink and self.dialog == .none and !self.panel_focus;
            const indexing = if (if (active_doc) |doc| if (doc.large) |*l| l else null else null) |l| blk: {
                const state = l.poll(&.{});
                break :blk l.expected_copy != null or l.needs_redraw or ((state.loading or !state.complete) and l.failure == null);
            } else false;
            var wait: u31 = if (indexing or self.database.job != null) 16 else if (self.lsp != null) 100 else if (blink) @intCast(500 - @min(500, now - self.last_blink)) else 1000;
            // Animations and delayed UI: the pulsing "Signing in…" label and tooltips.
            if (self.account.signingIn()) wait = @min(wait, 33);
            if (@import("views/image_view.zig").decoding(self)) wait = @min(wait, 16);
            if (@import("views/tooltip.zig").pendingMs(self)) |ms| wait = @min(wait, @as(u31, @intCast(@min(ms + 1, 1000))));
            var dirty = false;
            if (sdl.events.waitAndPopTimeout(wait)) |pending_event| {
                self.event(pending_event) catch |err| self.notice("{s}", .{@errorName(err)});
                self.cancelInactiveCopies();
                dirty = true;
                var budget: usize = 0;
                while (budget < 128) : (budget += 1) {
                    const next = sdl.events.poll() orelse break;
                    self.event(next) catch |err| self.notice("{s}", .{@errorName(err)});
                    self.cancelInactiveCopies();
                }
            }
            self.pollAsync();
            if (self.message_len > 0 and sdl.timer.getMillisecondsSinceInit() >= self.message_until) {
                self.message_len = 0;
                dirty = true;
            }
            if (self.lsp_dirty) {
                dirty = true;
                self.lsp_dirty = false;
            }
            if (self.redraw_requested) {
                self.redraw_requested = false;
                dirty = true;
            }
            const account_status = self.account.status.load(.acquire);
            if (account_status != self.account_seen or account_status == .signing_in) {
                self.account_seen = account_status;
                dirty = true;
            }
            if (@import("views/tooltip.zig").pendingMs(self)) |ms| if (ms == 0) {
                dirty = true;
            };
            if (self.database.open) dirty = true;
            if (self.workspace.currentOrNull()) |doc| if (doc.large) |*large| {
                _ = large.poll(&.{});
                if (indexing) dirty = true;
            };
            if (sdl.timer.getMillisecondsSinceInit() - self.last_config_poll >= 1000) {
                self.last_config_poll = sdl.timer.getMillisecondsSinceInit();
                const old_branch = self.title_branch;
                const old_branch_len = self.title_branch_len;
                self.title_branch_len = (@import("title_info.zig").branch(self.gpa, self.io, self.workspace.root, &self.title_branch) catch @as([]const u8, "")).len;
                if (old_branch_len != self.title_branch_len or !std.mem.eql(u8, old_branch[0..old_branch_len], self.title_branch[0..self.title_branch_len])) dirty = true;
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
            const initial = if (std.mem.eql(u8, name, "keymap.json")) @import("keymap_assets").initial else @import("settings_assets").initial_user_settings;
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
        onboarding_view.deactivate(self);
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
        const doc = self.workspace.currentOrNull() orelse return;
        self.modal = .{ .go_to_line = .{ .restore_cursor = doc.cursor, .restore_anchor = doc.anchor, .restore_scroll = doc.scroll_line, .restore_large_offset = if (doc.large) |l| l.offset else 0, .restore_large_anchor = if (doc.large) |l| l.anchor else 0 } };
    }
    /// Called after a modal's or view's line input changed.
    pub fn lineInputChanged(self: *App) !void {
        switch (self.modal) {
            .picker => |*p| try pickers.refilter(self, p),
            .go_to_line => |g| {
                const doc = self.workspace.currentOrNull() orelse return;
                if (doc.large) |*large| {
                    const input = std.mem.trim(u8, g.input.text(), " ");
                    if (std.mem.endsWith(u8, input, "%")) {
                        const percent = std.fmt.parseInt(u64, input[0 .. input.len - 1], 10) catch return;
                        if (percent <= 100) doc.largeNavigate((large.size / 100) * percent + (large.size % 100) * percent / 100);
                    } else if (std.mem.startsWith(u8, input, "b")) {
                        const offset = std.fmt.parseInt(u64, input[1..], 10) catch return;
                        doc.largeNavigate(offset);
                    } else {
                        const line = std.fmt.parseInt(u64, input, 10) catch return;
                        large.requestLine(line -| 1);
                    }
                    return;
                }
                if (pickers.goToLineTarget(doc, g.input.text())) |offset| {
                    doc.move(offset, false);
                    try self.revealCursor();
                }
            },
            .none => if (self.keymap_editor_open) {
                try modals.refilterKeymap(self);
            } else if (self.search_open and self.search_focused and !self.replace_focused) {
                try self.updateSearch(true);
            },
        }
    }
    pub fn menuCommand(self: *App, c: commands.Command) !void {
        if (self.prompt != null) return @import("views/prompt.zig").command(self, @tagName(c));
        if (self.context_menu) |m| {
            // Left/right step through the application menu bar (Zed ApplicationMenu).
            if (m.target == .app_menu and (c == .@"menu::SelectChild" or c == .@"menu::SelectParent")) {
                const count = @import("menus.zig").app_menu_names.len;
                const i = m.target.app_menu;
                title_bar.openAppMenu(self, if (c == .@"menu::SelectChild") (i + 1) % count else (i + count - 1) % count);
                return;
            }
            return context_menu.command(self, @tagName(c));
        }
        switch (self.modal) {
            .picker => |*p| {
                const count = p.entries.items.len;
                p.follow = true;
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
                const doc = self.workspace.currentOrNull() orelse return;
                if (c == .@"menu::Cancel") {
                    doc.setSelection(g.restore_anchor, g.restore_cursor);
                    doc.scroll_line = g.restore_scroll;
                    if (doc.large) |*large| large.restoreSelection(g.restore_large_anchor, g.restore_large_offset);
                } else if (pickers.goToLineTarget(doc, g.input.text())) |offset| {
                    doc.move(offset, false);
                    try self.revealCursor();
                }
                self.closeModal();
                return;
            },
            .none => {},
        }
        if (self.project_edit != null) {
            if (c == .@"menu::Cancel") @import("project_edit.zig").cancel(self) else if (c == .@"menu::Confirm") try @import("project_edit.zig").confirm(self);
            return;
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
        for (self.workspace.documents.items) |*doc| if (doc.dirty()) return error.UnsavedChanges;
        try self.workspace.setRoot(path);
        @import("project_edit.zig").cancel(self);
        while (self.workspace.documents.items.len > 0) try self.workspace.closeActive();
        self.project.deinit();
        self.project = .{ .allocator = self.gpa };
        self.search_open = false;
        self.search_focused = false;
        self.keymap_editor_open = false;
        self.project_collapsed = false;
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
        return if (self.workspace.currentOrNull()) |doc| doc.preview_only else false;
    }
    pub fn editorRect(self: *App) !Rect {
        var rect = try self.layout.rect(self.layout.editor);
        if (self.search_open and !self.keymap_editor_open and self.workspace.currentOrNull() != null) {
            const height: f32 = if (self.replace_open) 76 else 40;
            rect.y += height;
            rect.h = @max(0, rect.h - height);
        }
        return rect;
    }
    pub fn updateSearch(self: *App, select: bool) !void {
        self.search_count = 0;
        self.search_capped = false;
        const doc = self.workspace.currentOrNull() orelse return;
        self.search_doc = self.workspace.active;
        self.search_revision = doc.revision;
        if (doc.large != null or doc.buffer.len() > 32 * 1024 * 1024 or self.search_input.text().len == 0) return;
        var plan = try zid.search.SearchPlan.init(self.gpa, self.search_input.text(), !self.search_case_sensitive);
        defer plan.deinit();
        if (select) {
            const start = doc.selection().start;
            doc.setSelection(start, start);
            _ = try zid.find.selectMatch(doc, &plan, .next, true);
            try self.revealCursor();
        }
        var scan = zid.find.Scan.init(doc);
        while (!scan.done) {
            if (!scan.step(doc, &plan)) break;
        }
        self.search_count = scan.count;
        self.search_capped = scan.capped;
    }
    pub fn searchSelect(self: *App, direction: zid.find.Direction) !void {
        const doc = self.workspace.currentOrNull() orelse return;
        if (doc.large != null or doc.buffer.len() > 32 * 1024 * 1024 or self.search_input.text().len == 0) return;
        var plan = try zid.search.SearchPlan.init(self.gpa, self.search_input.text(), !self.search_case_sensitive);
        defer plan.deinit();
        _ = try zid.find.selectMatch(doc, &plan, direction, true);
        try self.revealCursor();
        try self.updateSearch(false);
    }
    pub fn searchReplace(self: *App) !void {
        const doc = self.workspace.currentOrNull() orelse return;
        if (doc.preview_only or doc.large != null or doc.buffer.len() > 32 * 1024 * 1024 or self.search_input.text().len == 0) return;
        var plan = try zid.search.SearchPlan.init(self.gpa, self.search_input.text(), !self.search_case_sensitive);
        defer plan.deinit();
        if (try zid.find.replaceCurrent(doc, &plan, self.replace_input.text())) {
            _ = try zid.find.selectMatch(doc, &plan, .next, true);
            try self.revealCursor();
        } else {
            _ = try zid.find.selectMatch(doc, &plan, .next, true);
            try self.revealCursor();
        }
        try self.updateSearch(false);
    }
    pub fn pageLines(self: *App) usize {
        const editor = self.editorRect() catch return 20;
        return @max(1, @as(usize, @intFromFloat(@max(0, editor.h - 16) / @as(f32, @floatFromInt(self.settings.line_height)))));
    }
    pub fn keepPanelVisible(self: *App) void {
        const panel = self.layout.rect(self.layout.panel) catch return;
        const fit = @max(1, project_panel.visibleRowsFor(self, panel.h));
        if (self.panel_row < self.panel_scroll) self.panel_scroll = self.panel_row;
        if (self.panel_row >= self.panel_scroll + fit) self.panel_scroll = self.panel_row - fit + 1;
    }
    /// Largest useful panel scroll offset: the last row sits at the bottom edge.
    pub fn maxPanelScroll(self: *App) usize {
        const panel = self.layout.rect(self.layout.panel) catch return 0;
        return project_panel.totalRows(self) -| project_panel.visibleRowsFor(self, panel.h);
    }
    pub fn refreshProject(self: *App) !void {
        try self.workspace.scan();
        const updated = try Project.initWithOptions(self.gpa, self.workspace.files.items, .{ .directories = self.workspace.directories.items, .auto_fold_dirs = self.settings.auto_fold_dirs, .sort_mode = self.settings.panel_sort_mode });
        for (updated.entries.items) |*entry| {
            if (!entry.directory) continue;
            entry.collapsed = true;
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
    pub fn revealProjectEntry(self: *App) !void {
        const doc = self.workspace.currentOrNull() orelse return;
        const absolute = doc.path orelse return;
        const path = if (std.mem.startsWith(u8, absolute, self.workspace.root) and absolute.len > self.workspace.root.len and absolute[self.workspace.root.len] == '/') absolute[self.workspace.root.len + 1 ..] else absolute;
        var found = false;
        for (self.project.entries.items) |*entry| {
            if (std.mem.eql(u8, path, entry.path)) found = true;
            if (entry.directory and path.len > entry.path.len and std.mem.startsWith(u8, path, entry.path) and path[entry.path.len] == '/') entry.collapsed = false;
        }
        if (!found) return;
        self.project_collapsed = false;
        try self.project.visible(self.gpa, &self.visible);
        for (self.visible.items, 0..) |index, row| if (std.mem.eql(u8, self.project.entries.items[index].path, path)) {
            self.panel_row = row + 1;
            self.keepPanelVisible();
            break;
        };
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
            // Zed's project_panel::Open opens a preview without focusing it
            // (`focus_opened_item = !enable_preview_from_project_panel`); the editor
            // stays read-only until it is clicked or focused.
            try self.workspace.open(entry.path);
            onboarding_view.deactivate(self);
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
        if (self.settings_document) |*document| document.deinit();
        self.settings_document = try @import("settings_document.zig").Document.load(self.gpa, self.io, self.config_root);
    }
    /// Tree-sitter syntax layer for `doc`: (re)created when the language
    /// changes and reparsed when the doc/revision markers are stale. The
    /// caller updates those markers right after calling this, so the layer
    /// stays in step with the lexer's invalidation cadence.
    pub fn treeSitterLayer(self: *App, doc: *zid.Document, lang: syntax.Language) ?*syntax.ts.Layer {
        if (!syntax.ts.supported(lang)) return null;
        if (self.ts_lang != lang) {
            if (self.ts_layer) |old| old.deinit();
            self.ts_layer = null;
            self.ts_lang = lang;
        }
        if (self.ts_layer == null) {
            self.ts_layer = syntax.ts.Layer.init(self.gpa, lang) catch return null;
        }
        const layer = self.ts_layer.?;
        if (self.syntax_doc != self.workspace.active or self.syntax_revision != doc.revision or layer.tree == null) {
            var source = syntax.ts.Source{
                .ctx = &doc.buffer,
                .len = @intCast(@min(doc.buffer.len(), std.math.maxInt(u32))),
                .read = bufferRead,
            };
            layer.update(&source) catch return null;
        }
        return layer;
    }

    fn bufferRead(ctx: *const anyopaque, offset: usize, dst: []u8) usize {
        const buffer: *const zid.TextBuffer = @ptrCast(@alignCast(ctx));
        const n = @min(dst.len, buffer.len() -| offset);
        buffer.copy(offset, dst[0..n]);
        return n;
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
        const doc = self.workspace.currentOrNull() orelse return;
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
        const doc = self.workspace.currentOrNull() orelse return;
        if (doc.large != null) return;
        const e = try self.editorRect();
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
        if (self.prompt != null) return @import("views/prompt.zig").click(self, mx, my);
        // An open menu sees the click first; outside clicks close it and fall through.
        const open_target: ?context_menu.Target = if (self.context_menu) |m| m.target else null;
        if (try context_menu.click(self, mx, my)) return;
        if (try modals.clickModal(self, mx, my)) return;
        if (my < 34 and mx >= self.layout.width - title_bar.controlsInset(self) - 36 and mx < self.layout.width - title_bar.controlsInset(self)) {
            if (self.database.open) self.database.cancel(self.io);
            self.database.open = !self.database.open;
            return;
        }
        const status = try self.layout.rect(self.layout.status);
        if (!self.database.open) if (@import("views/status_bar.zig").itemAt(self, status, mx, my)) |item| {
            try @import("views/status_bar.zig").click(self, item);
            return;
        };
        if (my < 34) {
            if (title_bar.controlAt(self, mx, my)) |i| switch (i) {
                0 => try self.window.minimize(),
                1 => if (self.window.getFlags().maximized) {
                    try self.window.restore();
                } else {
                    try self.window.maximize();
                },
                else => try self.runCommand(.@"zed::Quit"),
            } else if (open_target != null and open_target.? == .app_menu and title_bar.menuNameAt(self, mx, my) != null) {
                // Clicking the open menu's name closes the bar; another name switches.
                const index = title_bar.menuNameAt(self, mx, my).?;
                if (index != open_target.?.app_menu) title_bar.openAppMenu(self, index);
            } else if (mx < 36 and (open_target == null or open_target.? != .app_menu)) {
                title_bar.openAppMenu(self, 0);
            } else if (title_bar.segmentAt(self, mx, my)) |segment| switch (segment) {
                .project => try self.runCommand(.@"projects::OpenRecent"),
                .worktree => self.notice("Worktree picker is not implemented yet", .{}),
                .branch => self.notice("Branch picker is not implemented yet", .{}),
                .sign_in => try self.account.signIn(self),
                .user_menu => if (open_target == null or open_target.? != .user) {
                    var buf: [5]title_bar.Hit = undefined;
                    for (title_bar.segments(self, &buf)) |hit| if (hit.segment == .user_menu) {
                        context_menu.open(self, @import("menus.zig").user(self, hit.x + hit.w, 33));
                    };
                },
            };
            return;
        }
        if (self.database.open) {
            @import("database_view.zig").click(self, mx, my);
            return;
        }
        if (self.keymap_editor_open and self.keymap_tab.contains(mx, my)) {
            if (mx > self.keymap_tab.x + self.keymap_tab.w - 24) self.keymap_editor_open = false;
            return;
        }
        if (try @import("views/tabs.zig").buttonAt(self, mx, my)) |button| {
            try @import("views/tabs.zig").clickButton(self, button);
            return;
        }
        if (self.onboarding != null and self.onboarding_tab.contains(mx, my)) {
            onboarding_view.activateItem(self);
            if (@import("views/tabs.zig").closeHit(self.onboarding_tab, mx, my)) onboarding_view.close(self);
            return;
        }
        for (self.tab_hits.items) |hit| if (hit.rect.contains(mx, my)) {
            self.workspace.active = hit.index;
            self.panel_focus = false;
            self.keymap_editor_open = false;
            onboarding_view.deactivate(self);
            if (@import("views/tabs.zig").closeHit(hit.rect, mx, my)) try self.runCommand(.@"pane::CloseActiveItem");
            return;
        };
        const panel = try self.layout.rect(self.layout.panel);
        const panel_edge = if (self.settings.panel_right) panel.x else panel.x + panel.w;
        if (self.panel_open and my >= panel.y and my < panel.y + panel.h and @abs(mx - panel_edge) <= 4) {
            self.panel_resizing = true;
            return;
        }
        if (panel.contains(mx, my)) {
            self.panel_focus = true;
            if (project_panel.rowAt(self, panel, my)) |row| {
                self.panel_row = row;
                try self.activateProject();
                self.panel_focus = clicks < 2;
                self.keymap_editor_open = false;
            }
            return;
        }
        if (self.keymap_editor_open and modals.clickKeymap(self, mx, my)) {
            self.panel_focus = false;
            return;
        }
        const editor = try self.layout.rect(self.layout.editor);
        if (onboarding_view.isActive(self) and editor.contains(mx, my)) {
            self.panel_focus = false;
            try onboarding_view.click(self, mx, my);
            return;
        }
        if (editor.contains(mx, my)) {
            if (self.search_open and my < editor.y + (if (self.replace_open) @as(f32, 76) else 40)) {
                try @import("views/buffer_search.zig").click(self, editor, mx, my);
                return;
            }
            self.search_focused = false;
            self.panel_focus = false;
            try self.placeCursor(mx, my, shiftHeld());
            if (clicks >= 2) {
                const doc = self.workspace.currentOrNull() orelse return;
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
        try self.layout.configure(self.settings.panel_right, self.settings.status_visible);
        try self.layout.resize(@floatFromInt(width), @floatFromInt(height), if (self.panel_open) @min(@as(f32, @floatFromInt(self.settings.panel_width)), @as(f32, @floatFromInt(width)) * 0.45) else 0);
        const current_instance = if (self.workspace.currentOrNull()) |doc| doc.instance_id else 0;
        if (self.settings.panel_auto_reveal and self.panel_document != current_instance) {
            self.panel_document = current_instance;
            try self.revealProjectEntry();
        }
        try self.project.visible(self.gpa, &self.visible);
        self.panel_scroll = @min(self.panel_scroll, self.maxPanelScroll());
        const pixel_w, _ = self.window.getSizeInPixels() catch .{ width, height };
        const scale = self.forced_scale orelse @as(f32, @floatFromInt(pixel_w)) / @as(f32, @floatFromInt(width));
        try self.renderer.begin(@intCast(width), @intCast(height), scale);
        errdefer self.renderer.abortFrame();
        const t = self.settings.theme;
        try self.fill(.{ .w = @floatFromInt(width), .h = @floatFromInt(height) }, t.background);
        const project_name = std.fs.path.basename(self.workspace.root);
        self.renderer.roundWindow(if (self.window.getFlags().maximized or self.window.getFlags().fullscreen) 0 else 10);
        onboarding_view.sync(self);
        self.recordHistory();
        @import("views/tooltip.zig").beginFrame(self);
        try title_bar.draw(self);
        self.renderer.reserveOverlay();
        try self.drawPanel();
        try self.drawTabs();
        const item_view = self.keymap_editor_open or onboarding_view.isActive(self) or (if (self.workspace.currentOrNull()) |d| d.image else false);
        const image_doc: ?*zid.Document = if (self.workspace.currentOrNull()) |d| (if (d.image) d else null) else null;
        if (self.keymap_editor_open) try modals.drawKeymapEditor(self) else if (onboarding_view.isActive(self)) try onboarding_view.draw(self) else if (image_doc) |d| try @import("views/image_view.zig").draw(self, d) else try self.drawEditor();
        if (self.search_open and !item_view and self.workspace.currentOrNull() != null) {
            if (self.search_doc != self.workspace.active or self.search_revision != self.workspace.current().revision) try self.updateSearch(false);
            try @import("views/buffer_search.zig").draw(self);
        }
        self.renderer.drawOverlay();
        if (!item_view) try @import("views/editor.zig").drawCaret(self);
        self.hover_rect = .{};
        if (!item_view and self.modal == .none and self.dialog == .none and !self.database.open and self.workspace.currentOrNull() != null) {
            if (self.lsp) |*lsp| if (lsp.hoverFor(self.workspace.current())) |hover| try @import("views/hover.zig").draw(self, hover);
        }
        try @import("views/status_bar.zig").draw(self);
        if (self.database.open) try @import("database_view.zig").draw(self);
        try modals.drawModal(self);
        try context_menu.draw(self);
        try @import("views/prompt.zig").draw(self);
        try @import("views/tooltip.zig").finishFrame(self);
        if (self.dialog != .none) try self.drawDialog();
        try self.renderer.end();
        var title_buffer: [1024]u8 = undefined;
        const doc = self.workspace.currentOrNull();
        const name = if (if (doc) |d| d.path else null) |path| std.fs.path.basename(path) else "untitled";
        const window_title = if (doc == null) std.fmt.bufPrintSentinel(&title_buffer, "{s} — Zid", .{project_name}, 0) catch "Zid" else std.fmt.bufPrintSentinel(&title_buffer, "{s}{s} — {s} — Zid", .{ if (doc.?.dirty()) @as([]const u8, "● ") else "", name, project_name }, 0) catch "Zid";
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
