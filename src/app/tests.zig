test {
    _ = @import("layout.zig");
    _ = @import("config.zig");
    _ = @import("settings_helpers.zig");
    _ = @import("project.zig");
    _ = @import("text_match.zig");
    _ = @import("keymap.zig");
    _ = @import("fuzzy.zig");
    _ = @import("line_input.zig");
    _ = @import("recent_projects.zig");
    _ = @import("theme_assets");
}

test {
    _ = @import("settings_search.zig");
}
