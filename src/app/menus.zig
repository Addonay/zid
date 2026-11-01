//! Menu contents and their actions, transcribed from Zed:
//! - editor right-click: `crates/editor/src/mouse_context_menu.rs`
//! - tab right-click: `crates/workspace/src/pane.rs` (tab context menu)
//! - project panel right-click: `crates/project_panel/src/project_panel.rs` `deploy_context_menu`
//! - application menu: `crates/zed/src/zed/app_menus.rs`, flattened the way
//!   `crates/title_bar/src/application_menu.rs` does on Linux (one submenu level inlined,
//!   system menus dropped, duplicate separators collapsed)
//! - user menu: `crates/title_bar/src/title_bar.rs` `render_user_menu_button`
//!
//! `run` performs an entry: target-specific handlers first (the right-clicked tab or
//! project entry), then Zid's action registry by Zed action name. Actions Zid does not
//! implement yet report that instead of silently doing nothing.
const std = @import("std");
const sdl = @import("sdl3");
const App = @import("app.zig").App;
const cm = @import("views/context_menu.zig");
const commands = @import("input/commands.zig");
const wa = @import("workspace_actions.zig");
const Menu = cm.Menu;
const eql = std.mem.eql;

// ---------------------------------------------------------------- builders

pub fn editor(app: *App, x: f32, y: f32) Menu {
    var m: Menu = .{ .target = .editor, .x = x, .y = y };
    const doc = app.workspace.currentOrNull();
    const has_path = doc != null and doc.?.path != null;
    const has_git = app.title_branch_len > 0;
    m.action("Go to Definition", "editor::GoToDefinition");
    m.action("Go to Declaration", "editor::GoToDeclaration");
    m.action("Go to Type Definition", "editor::GoToTypeDefinition");
    m.action("Go to Implementation", "editor::GoToImplementation");
    m.action("Find All References", "editor::FindAllReferences");
    m.action("Show Incoming Calls", "call_hierarchy::ShowIncomingCalls");
    m.action("Show Outgoing Calls", "call_hierarchy::ShowOutgoingCalls");
    m.separator();
    m.action("Rename Symbol", "editor::Rename");
    m.action("Format Buffer", "editor::Format");
    m.action("Show Code Actions", "editor::ToggleCodeActions");
    m.separator();
    m.action("Cut", "editor::Cut");
    m.action("Copy", "editor::Copy");
    m.action("Copy and Trim", "editor::CopyAndTrim");
    m.action("Paste", "editor::Paste");
    m.separator();
    m.actionDisabledWhen(!has_path, "Reveal in File Manager", "editor::RevealInFileManager");
    if (doc) |d| if (d.path) |p| {
        if (std.mem.endsWith(u8, p, ".md")) m.action("Open Markdown Preview", "markdown::OpenPreview");
        if (std.mem.endsWith(u8, p, ".svg")) m.action("Open SVG Preview", "svg::OpenPreview");
    };
    m.actionDisabledWhen(!has_path, "Open in Terminal", "editor::OpenInTerminal");
    m.actionDisabledWhen(!has_git, "Copy Permalink to Line", "editor::CopyPermalinkToLine");
    m.actionDisabledWhen(!has_git, "View File History", "git::FileHistory");
    return m;
}

pub fn tab(app: *App, index: usize, x: f32, y: f32) Menu {
    var m: Menu = .{ .target = .{ .tab = index }, .x = x, .y = y };
    const count = app.workspace.documents.items.len;
    const doc = &app.workspace.documents.items[index];
    m.action("Close", "pane::CloseActiveItem");
    m.action("Close Others", "pane::CloseOtherItems");
    m.separator();
    m.actionDisabledWhen(index == 0, "Close Left", "pane::CloseItemsToTheLeft");
    m.actionDisabledWhen(index + 1 >= count, "Close Right", "pane::CloseItemsToTheRight");
    m.separator();
    m.action("Close Clean", "pane::CloseCleanItems");
    m.action("Close All", "pane::CloseAllItems");
    m.separator();
    m.action("Make Tab Read-Only", "editor::ToggleReadOnly");
    if (doc.path != null) {
        m.separator();
        m.action("Copy Path", "workspace::CopyPath");
        m.action("Copy Relative Path", "workspace::CopyRelativePath");
        if (app.title_branch_len > 0) {
            m.separator();
            m.action("Open File Permalink", "editor::OpenPermalinkToLine");
            m.action("Copy File Permalink", "editor::CopyPermalinkToLine");
        }
        m.separator();
        m.action("Reveal in File Manager", "editor::RevealInFileManager");
    }
    m.separator();
    m.action("Pin Tab", "pane::TogglePinTab");
    if (doc.path != null) {
        m.action("Reveal In Project Panel", "pane::RevealInProjectPanel");
        m.action("Open in Terminal", "editor::OpenInTerminal");
    }
    return m;
}

pub fn panel(app: *App, row: usize, x: f32, y: f32) Menu {
    var m: Menu = .{ .target = .{ .panel = row }, .x = x, .y = y };
    const is_root = row == 0;
    const entry = panelEntry(app, row);
    const is_dir = is_root or (entry != null and entry.?.directory);
    const name = if (entry) |e| e.name else "";
    m.action("New File", "project_panel::NewFile");
    m.action("New Folder", "project_panel::NewDirectory");
    m.separator();
    m.action("Reveal in File Manager", "project_panel::RevealInFileManager");
    m.action("Open in Default App", "project_panel::OpenWithSystem");
    m.action("Open in Terminal", "project_panel::OpenInTerminal");
    if (std.mem.endsWith(u8, name, ".md")) m.action("Open Markdown Preview", "markdown::OpenPreview");
    if (std.mem.endsWith(u8, name, ".svg")) m.action("Open SVG Preview", "svg::OpenPreview");
    if (is_dir) {
        m.separator();
        m.action("Find in Folder…", "project_panel::NewSearchInDirectory");
    }
    m.separator();
    m.action("Cut", "project_panel::Cut");
    m.action("Copy", "project_panel::Copy");
    m.action("Duplicate", "project_panel::Duplicate");
    m.actionDisabledWhen(app.file_clip_len == 0, "Paste", "project_panel::Paste");
    m.actionDisabledWhen(true, "Undo", "project_panel::Undo");
    m.actionDisabledWhen(true, "Redo", "project_panel::Redo");
    m.separator();
    m.action("Copy Path", "workspace::CopyPath");
    m.action("Copy Relative Path", "workspace::CopyRelativePath");
    if (app.title_branch_len > 0) {
        m.separator();
        m.action("Add to .gitignore", "git::AddToGitignore");
        m.action("Add to .git/info/exclude", "git::AddToGitExclude");
        if (!is_dir) {
            m.action("Open File Permalink", "git::OpenFilePermalink");
            m.action("Copy File Permalink", "git::CopyFilePermalink");
        }
    }
    m.separator();
    m.action("Rename", "project_panel::Rename");
    if (!is_root) {
        m.action("Trash", "project_panel::Trash");
        m.action("Delete", "project_panel::Delete");
    } else {
        m.separator();
        m.action("Add Folders to Project…", "workspace::AddFolderToProject");
        m.action("Remove from Project", "project_panel::RemoveFromProject");
    }
    return m;
}

/// Right-click in empty project-panel space (Zed shows the root's New File/Folder menu).
pub fn panelBlank(app: *App, x: f32, y: f32) Menu {
    _ = app;
    var m: Menu = .{ .target = .panel_blank, .x = x, .y = y };
    m.action("New File", "project_panel::NewFile");
    m.action("New Folder", "project_panel::NewDirectory");
    return m;
}

pub const app_menu_names = [_][]const u8{ "Zed", "File", "Edit", "Selection", "View", "Go", "Run", "Window", "Help" };

pub fn appMenu(app: *App, index: usize, x: f32, y: f32) Menu {
    _ = app;
    var m: Menu = .{ .target = .{ .app_menu = index }, .x = x, .y = y };
    switch (index) {
        0 => {
            m.action("About Zed", "zed::About");
            m.action("Check for Updates", "auto_update::Check");
            m.separator();
            m.action("Open Settings", "zed::OpenSettings");
            m.action("Open Settings File", "zed::OpenSettingsFile");
            m.action("Open Project Settings", "zed::OpenProjectSettings");
            m.action("Open Project Settings File", "zed::OpenProjectSettingsFile");
            m.action("Open Default Settings", "zed::OpenDefaultSettings");
            m.separator();
            m.action("Open Keymap", "zed::OpenKeymap");
            m.action("Open Keymap File", "zed::OpenKeymapFile");
            m.action("Open Default Key Bindings", "zed::OpenDefaultKeymap");
            m.separator();
            m.action("Select Theme...", "theme_selector::Toggle");
            m.action("Select Icon Theme...", "icon_theme_selector::Toggle");
            m.separator();
            m.action("Extensions", "zed::Extensions");
            m.action("Install CLI", "cli::InstallCliBinary");
            m.separator();
            m.action("Quit Zed", "zed::Quit");
        },
        1 => {
            m.action("New", "workspace::NewFile");
            m.action("New Window", "workspace::NewWindow");
            m.separator();
            m.action("Open File...", "workspace::OpenFiles");
            m.action("Open Folder...", "workspace::Open");
            m.action("Open Recent…", "projects::OpenRecent");
            m.action("Open Remote…", "projects::OpenRemote");
            m.separator();
            m.action("Add Folder to Project…", "workspace::AddFolderToProject");
            m.separator();
            m.action("Save", "workspace::Save");
            m.action("Save As…", "workspace::SaveAs");
            m.action("Save All", "workspace::SaveAll");
            m.separator();
            m.action("Close Editor", "pane::CloseActiveItem");
            m.action("Close Project", "workspace::CloseProject");
            m.action("Close Window", "workspace::CloseWindow");
        },
        2 => {
            m.action("Undo", "editor::Undo");
            m.action("Redo", "editor::Redo");
            m.separator();
            m.action("Cut", "editor::Cut");
            m.action("Copy", "editor::Copy");
            m.action("Copy and Trim", "editor::CopyAndTrim");
            m.action("Paste", "editor::Paste");
            m.separator();
            m.action("Find", "buffer_search::Deploy");
            m.action("Find in Project", "pane::DeploySearch");
            m.separator();
            m.action("Toggle Line Comment", "editor::ToggleComments");
        },
        3 => {
            m.action("Select All", "editor::SelectAll");
            m.action("Expand Selection", "editor::SelectLargerSyntaxNode");
            m.action("Shrink Selection", "editor::SelectSmallerSyntaxNode");
            m.action("Select Next Sibling", "editor::SelectNextSyntaxNode");
            m.action("Select Previous Sibling", "editor::SelectPreviousSyntaxNode");
            m.separator();
            m.action("Add Cursor Above", "editor::AddSelectionAbove");
            m.action("Add Cursor Below", "editor::AddSelectionBelow");
            m.action("Select Next Occurrence", "editor::SelectNext");
            m.action("Select Previous Occurrence", "editor::SelectPrevious");
            m.action("Select All Occurrences", "editor::SelectAllMatches");
            m.separator();
            m.action("Move Line Up", "editor::MoveLineUp");
            m.action("Move Line Down", "editor::MoveLineDown");
            m.action("Duplicate Selection", "editor::DuplicateLineDown");
        },
        4 => {
            m.action("Zoom In", "zed::IncreaseBufferFontSize");
            m.action("Zoom Out", "zed::DecreaseBufferFontSize");
            m.action("Reset Zoom", "zed::ResetBufferFontSize");
            m.action("Reset All Zoom", "zed::ResetAllZoom");
            m.separator();
            m.action("Toggle Left Dock", "workspace::ToggleLeftDock");
            m.action("Toggle Right Dock", "workspace::ToggleRightDock");
            m.action("Toggle Bottom Dock", "workspace::ToggleBottomDock");
            m.action("Toggle All Docks", "workspace::ToggleAllDocks");
            m.action("Split Up", "pane::SplitUp");
            m.action("Split Down", "pane::SplitDown");
            m.action("Split Left", "pane::SplitLeft");
            m.action("Split Right", "pane::SplitRight");
            m.separator();
            m.action("Project Panel", "project_panel::ToggleFocus");
            m.action("Outline Panel", "outline_panel::ToggleFocus");
            m.action("Collab Panel", "collab_panel::ToggleFocus");
            m.action("Terminal Panel", "terminal_panel::Toggle");
            m.action("Debugger Panel", "debug_panel::ToggleFocus");
            m.action("Git Panel", "git_panel::ToggleFocus");
            m.separator();
            m.action("Diagnostics", "diagnostics::Deploy");
        },
        5 => {
            m.action("Back", "pane::GoBack");
            m.action("Forward", "pane::GoForward");
            m.separator();
            m.action("Command Palette...", "command_palette::Toggle");
            m.separator();
            m.action("Go to File...", "file_finder::Toggle");
            m.action("Go to Symbol in Editor...", "outline::Toggle");
            m.action("Go to Line/Column...", "go_to_line::Toggle");
            m.separator();
            m.action("Go to Definition", "editor::GoToDefinition");
            m.action("Go to Declaration", "editor::GoToDeclaration");
            m.action("Go to Type Definition", "editor::GoToTypeDefinition");
            m.action("Find All References", "editor::FindAllReferences");
            m.action("Show Incoming Calls", "call_hierarchy::ShowIncomingCalls");
            m.action("Show Outgoing Calls", "call_hierarchy::ShowOutgoingCalls");
            m.separator();
            m.action("Next Problem", "editor::GoToDiagnostic");
            m.action("Previous Problem", "editor::GoToPreviousDiagnostic");
        },
        6 => {
            m.action("Spawn Task", "task::Spawn");
            m.action("Start Debugger", "debugger::Start");
            m.separator();
            m.action("Edit tasks.json…", "zed::OpenProjectTasks");
            m.action("Edit debug.json…", "zed::OpenProjectDebugTasks");
            m.separator();
            m.action("Continue", "debugger::Continue");
            m.action("Step Over", "debugger::StepOver");
            m.action("Step Into", "debugger::StepInto");
            m.action("Step Out", "debugger::StepOut");
            m.separator();
            m.action("Toggle Breakpoint", "editor::ToggleBreakpoint");
            m.action("Edit Breakpoint", "editor::EditLogBreakpoint");
            m.action("Clear All Breakpoints", "debugger::ClearAllBreakpoints");
        },
        7 => {
            m.action("Minimize", "zed::Minimize");
            m.action("Zoom", "zed::Zoom");
        },
        else => {
            m.action("View Release Notes Locally", "auto_update::ViewReleaseNotesLocally");
            m.action("View Telemetry", "zed::OpenTelemetryLog");
            m.action("View Dependency Licenses", "zed::OpenLicenses");
            m.action("Show Welcome", "zed::ShowWelcome");
            m.separator();
            m.entry(.{ .label = "File Bug Report...", .action = "zed::OpenBrowser", .arg = "https://github.com/zed-industries/zed/issues/new?template=10_bug_report.yml" });
            m.entry(.{ .label = "Request Feature...", .action = "zed::OpenBrowser", .arg = "https://github.com/zed-industries/zed/discussions/new/choose" });
            m.entry(.{ .label = "Email Us...", .action = "zed::OpenBrowser", .arg = "mailto:hi@zed.dev" });
            m.separator();
            m.entry(.{ .label = "Documentation", .action = "zed::OpenBrowser", .arg = "https://zed.dev/docs" });
            m.entry(.{ .label = "Zed Repository", .action = "zed::OpenBrowser", .arg = "https://github.com/zed-industries/zed" });
            m.entry(.{ .label = "Zed Twitter", .action = "zed::OpenBrowser", .arg = "https://twitter.com/zeddotdev" });
            m.entry(.{ .label = "Join the Team", .action = "zed::OpenBrowser", .arg = "https://zed.dev/jobs" });
        },
    }
    return m;
}

/// Title-bar user menu, anchored by its top-right corner under the chevron/avatar.
pub fn user(app: *App, right: f32, y: f32) Menu {
    var m: Menu = .{ .target = .user, .x = right, .y = y, .anchor = .top_right };
    if (app.account.user()) |u| {
        m.entry(.{ .label = m.ownText(u.login), .action = "zed::OpenAccount" });
        m.separator();
    }
    m.action("Settings", "zed::OpenSettings");
    m.action("Keymap", "zed::OpenKeymap");
    m.action("Themes…", "theme_selector::Toggle");
    m.action("Icon Themes…", "icon_theme_selector::Toggle");
    m.action("Extensions", "zed::Extensions");
    if (app.account.user() != null) {
        m.separator();
        m.action("Sign Out", "client::SignOut");
    }
    return m;
}

/// Status-bar language-server menu (Zed `LspButton::fill_menu`): each server with its
/// status on the right, then "Restart All Servers" / "Stop All Servers".
pub fn lsp(app: *App, x: f32, bottom: f32) Menu {
    var m: Menu = .{ .target = .lsp, .x = x, .y = bottom, .anchor = .bottom_left };
    if (app.lsp != null) {
        m.entry(.{ .label = "zls", .key = "Running" });
    } else if (app.lsp_attempted) {
        m.entry(.{ .label = "zls", .key = "Stopped" });
    } else {
        m.entry(.{ .label = "No Active Language Servers", .disabled = true, .key = "" });
        return m;
    }
    m.separator();
    m.entry(.{ .label = "Restart All Servers", .action = "zid::RestartLanguageServers", .key = "" });
    if (app.lsp != null) m.entry(.{ .label = "Stop All Servers", .action = "zid::StopLanguageServers", .key = "" });
    return m;
}

// ---------------------------------------------------------------- actions

fn panelEntry(app: *App, row: usize) ?*@import("project.zig").Entry {
    if (row == 0 or row - 1 >= app.visible.items.len) return null;
    return &app.project.entries.items[app.visible.items[row - 1]];
}
/// Absolute path of a panel row (the root for row 0) in `buf`.
fn panelAbsolute(app: *App, row: usize, buf: []u8) ?[]const u8 {
    const entry = panelEntry(app, row) orelse return std.fmt.bufPrint(buf, "{s}", .{app.workspace.root}) catch null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ app.workspace.root, entry.path }) catch null;
}
fn relative(app: *App, absolute: []const u8) []const u8 {
    const root = app.workspace.root;
    if (std.mem.startsWith(u8, absolute, root) and absolute.len > root.len and absolute[root.len] == '/') return absolute[root.len + 1 ..];
    if (eql(u8, absolute, root)) return std.fs.path.basename(root);
    return absolute;
}
fn copyText(app: *App, text: []const u8) !void {
    const z = try app.gpa.dupeSentinel(u8, text, 0);
    defer app.gpa.free(z);
    try sdl.clipboard.setText(z);
}
fn openUrl(app: *App, url: []const u8) void {
    const z = app.gpa.dupeSentinel(u8, url, 0) catch return;
    defer app.gpa.free(z);
    sdl.openURL(z) catch |err| app.notice("Open {s}: {s}", .{ url, @errorName(err) });
}
/// file:// URL with percent-encoding for anything outside the unreserved set.
fn openPath(app: *App, path: []const u8) void {
    var buf: [std.fs.max_path_bytes * 3 + 8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll("file://") catch return;
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-_.~", c) != null) w.writeByte(c) catch return else w.print("%{X:0>2}", .{c}) catch return;
    }
    openUrl(app, w.buffered());
}
/// The file manager shows the containing folder (Zed `reveal_path`).
fn revealInFileManager(app: *App, path: []const u8) void {
    const stat = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch {
        openPath(app, std.fs.path.dirname(path) orelse path);
        return;
    };
    openPath(app, if (stat.kind == .directory) path else std.fs.path.dirname(path) orelse path);
}
fn notImplemented(app: *App, label: []const u8) void {
    app.notice("{s} is not implemented yet", .{label});
}

pub fn run(app: *App, target: cm.Target, e: cm.Entry) !void {
    const a = e.action;
    switch (target) {
        .tab => |index| if (index < app.workspace.documents.items.len) {
            if (try runTab(app, index, e)) return;
        },
        .panel => |row| if (try runPanel(app, row, e)) return,
        .panel_blank => if (try runPanel(app, 0, e)) return,
        else => {},
    }
    if (eql(u8, a, "zed::OpenBrowser")) return openUrl(app, e.arg);
    if (eql(u8, a, "zid::RestartLanguageServers") or eql(u8, a, "zid::StopLanguageServers")) {
        if (app.lsp) |*server| server.deinit();
        app.lsp = null;
        // Restart: the next poll starts ZLS again for open Zig files. Stop: stays down.
        app.lsp_attempted = eql(u8, a, "zid::StopLanguageServers");
        app.lsp_dirty = true;
        return;
    }
    if (target == .lsp) return; // server rows have no action yet (Zed opens a submenu)
    if (eql(u8, a, "client::SignIn")) return app.account.signIn(app);
    if (eql(u8, a, "client::SignOut")) return app.account.signOut(app);
    if (eql(u8, a, "zed::OpenAccount")) return openUrl(app, "https://zed.dev/account");
    if (eql(u8, a, "zed::Minimize")) return app.window.minimize();
    if (eql(u8, a, "zed::Zoom")) return if (app.window.getFlags().maximized) app.window.restore() else app.window.maximize();
    if (eql(u8, a, "workspace::CopyPath") or eql(u8, a, "workspace::CopyRelativePath") or eql(u8, a, "editor::RevealInFileManager")) {
        const doc = app.workspace.currentOrNull() orelse return;
        const path = doc.path orelse return;
        if (eql(u8, a, "editor::RevealInFileManager")) return revealInFileManager(app, path);
        return copyText(app, if (eql(u8, a, "workspace::CopyPath")) path else relative(app, path));
    }
    if (std.meta.stringToEnum(commands.Command, a)) |c| return app.runCommand(c);
    notImplemented(app, e.label);
}

fn runTab(app: *App, index: usize, e: cm.Entry) !bool {
    const a = e.action;
    if (eql(u8, a, "pane::CloseActiveItem")) try wa.closeItem(app, index) else if (eql(u8, a, "pane::CloseOtherItems")) try wa.closeTabs(app, .others, index) else if (eql(u8, a, "pane::CloseItemsToTheLeft")) try wa.closeTabs(app, .left, index) else if (eql(u8, a, "pane::CloseItemsToTheRight")) try wa.closeTabs(app, .right, index) else if (eql(u8, a, "pane::CloseCleanItems")) try wa.closeTabs(app, .clean, index) else if (eql(u8, a, "pane::CloseAllItems")) try wa.closeTabs(app, .all, index) else if (eql(u8, a, "pane::RevealInProjectPanel")) {
        app.workspace.active = index;
        app.panel_open = true;
        try app.revealProjectEntry();
        app.panel_focus = true;
    } else {
        // Path actions act on the right-clicked tab: make it active first, as Zed does.
        app.workspace.active = index;
        return false;
    }
    return true;
}

fn runPanel(app: *App, row: usize, e: cm.Entry) !bool {
    const a = e.action;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = panelAbsolute(app, row, &buf) orelse return false;
    app.panel_row = row;
    if (eql(u8, a, "project_panel::NewFile") or eql(u8, a, "project_panel::NewDirectory")) {
        try app.runCommand(if (eql(u8, a, "project_panel::NewFile")) .@"project_panel::NewFile" else .@"project_panel::NewDirectory");
    } else if (eql(u8, a, "workspace::CopyPath")) {
        try copyText(app, absolute);
    } else if (eql(u8, a, "workspace::CopyRelativePath")) {
        try copyText(app, relative(app, absolute));
    } else if (eql(u8, a, "project_panel::RevealInFileManager")) {
        revealInFileManager(app, absolute);
    } else if (eql(u8, a, "project_panel::OpenWithSystem")) {
        openPath(app, absolute);
    } else if (eql(u8, a, "project_panel::Trash") or eql(u8, a, "project_panel::Delete")) {
        @import("views/prompt.zig").remove(app, absolute, eql(u8, a, "project_panel::Trash"));
    } else if (eql(u8, a, "project_panel::Cut") or eql(u8, a, "project_panel::Copy")) {
        const n = @min(absolute.len, app.file_clip.len);
        @memcpy(app.file_clip[0..n], absolute[0..n]);
        app.file_clip_len = n;
        app.file_clip_cut = eql(u8, a, "project_panel::Cut");
    } else if (eql(u8, a, "project_panel::Paste")) {
        try paste(app, row, absolute);
    } else if (eql(u8, a, "project_panel::Duplicate")) {
        try duplicate(app, absolute);
    } else if (eql(u8, a, "git::AddToGitignore") or eql(u8, a, "git::AddToGitExclude")) {
        try addIgnore(app, absolute, eql(u8, a, "git::AddToGitExclude"));
    } else if (eql(u8, a, "project_panel::Rename")) {
        if (row == 0) {
            app.notice("The project root cannot be renamed here", .{});
        } else try @import("project_edit.zig").startRename(app, row);
    } else return false;
    return true;
}

/// Zed names copies "<stem> copy<ext>", then "<stem> copy 1<ext>", ...
fn copyName(buf: []u8, dir: []const u8, name: []const u8, attempt: usize) ![]const u8 {
    const ext = std.fs.path.extension(name);
    const stem = name[0 .. name.len - ext.len];
    if (attempt == 0) return std.fmt.bufPrint(buf, "{s}/{s} copy{s}", .{ dir, stem, ext });
    return std.fmt.bufPrint(buf, "{s}/{s} copy {d}{s}", .{ dir, stem, attempt, ext });
}
fn exists(app: *App, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(app.io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
fn copyFile(app: *App, from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(app.io, from, .{});
    if (stat.kind == .directory) return error.CopyingFoldersNotSupported;
    try cwd.copyFile(from, cwd, to, app.io, .{});
}
fn duplicate(app: *App, absolute: []const u8) !void {
    const dir = std.fs.path.dirname(absolute) orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const target = try copyName(&buf, dir, std.fs.path.basename(absolute), attempt);
        if (exists(app, target)) continue;
        copyFile(app, absolute, target) catch |err| {
            app.notice("Duplicate: {s}", .{@errorName(err)});
            return;
        };
        try app.refreshProject();
        return;
    }
}
fn paste(app: *App, row: usize, absolute: []const u8) !void {
    if (app.file_clip_len == 0) return;
    const source = app.file_clip[0..app.file_clip_len];
    const entry = panelEntry(app, row);
    // Into a folder when a folder (or the root) was right-clicked, else beside the file.
    const dir = if (row == 0 or (entry != null and entry.?.directory)) absolute else std.fs.path.dirname(absolute) orelse absolute;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var target: []const u8 = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, std.fs.path.basename(source) });
    var attempt: usize = 0;
    while (exists(app, target) and attempt < 100) : (attempt += 1) target = try copyName(&buf, dir, std.fs.path.basename(source), attempt);
    const cwd = std.Io.Dir.cwd();
    if (app.file_clip_cut) {
        cwd.rename(source, cwd, target, app.io) catch |err| {
            app.notice("Paste: {s}", .{@errorName(err)});
            return;
        };
        app.file_clip_len = 0;
    } else copyFile(app, source, target) catch |err| {
        app.notice("Paste: {s}", .{@errorName(err)});
        return;
    };
    try app.refreshProject();
}
/// git `AddToGitignore` / `AddToGitExclude`: append `/<relative path>` (a trailing
/// slash for folders) to the root `.gitignore` or `.git/info/exclude`.
fn addIgnore(app: *App, absolute: []const u8, exclude: bool) !void {
    const rel = relative(app, absolute);
    const file_path = try std.fs.path.join(app.gpa, &.{ app.workspace.root, if (exclude) ".git/info/exclude" else ".gitignore" });
    defer app.gpa.free(file_path);
    const cwd = std.Io.Dir.cwd();
    const existing = cwd.readFileAlloc(app.io, file_path, app.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => try app.gpa.dupe(u8, ""),
        else => return err,
    };
    defer app.gpa.free(existing);
    const is_dir = blk: {
        const stat = cwd.statFile(app.io, absolute, .{}) catch break :blk false;
        break :blk stat.kind == .directory;
    };
    const updated = try std.fmt.allocPrint(app.gpa, "{s}{s}/{s}{s}\n", .{ existing, if (existing.len > 0 and existing[existing.len - 1] != '\n') "\n" else "", rel, if (is_dir) "/" else "" });
    defer app.gpa.free(updated);
    try cwd.writeFile(app.io, .{ .sub_path = file_path, .data = updated });
    try app.refreshProject();
}

// ---------------------------------------------------------------- right click

/// Right mouse button: open the menu for whatever is under the pointer. Like Zed, the
/// right-clicked tab or project entry becomes the selection, and a right-click in the
/// editor outside the selection moves the cursor there first.
pub fn rightClick(app: *App, mx: f32, my: f32) !void {
    if (app.prompt != null or app.dialog != .none) return;
    cm.close(app);
    if (my < 34) return;
    for (app.tab_hits.items) |hit| if (hit.rect.contains(mx, my)) {
        return cm.open(app, tab(app, hit.index, mx, my));
    };
    const panel_rect = try app.layout.rect(app.layout.panel);
    if (app.panel_open and panel_rect.contains(mx, my)) {
        app.panel_focus = true;
        if (@import("views/project_panel.zig").rowAt(app, panel_rect, my)) |row| {
            app.panel_row = row;
            return cm.open(app, panel(app, row, mx, my));
        }
        return cm.open(app, panelBlank(app, mx, my));
    }
    const editor_rect = try app.layout.rect(app.layout.editor);
    if (editor_rect.contains(mx, my) and !app.keymap_editor_open and !@import("views/onboarding.zig").isActive(app)) {
        const doc = app.workspace.currentOrNull() orelse return;
        app.panel_focus = false;
        app.search_focused = false;
        const sel = doc.selection();
        const before = doc.cursor;
        try app.placeCursor(mx, my, false);
        const clicked = doc.cursor;
        if (sel.start != sel.end and clicked >= sel.start and clicked <= sel.end) {
            // Inside the selection: keep it (Zed only moves the cursor outside it).
            doc.setSelection(if (before == sel.start) sel.end else sel.start, before);
        }
        return cm.open(app, editor(app, mx, my));
    }
}
