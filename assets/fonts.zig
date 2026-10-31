//! Bundled default families from Zed's pinned source checkout.
pub const mono = @embedFile("fonts/Lilex-Regular.ttf");
pub const mono_italic = @embedFile("fonts/Lilex-Italic.ttf");
pub const ui = @embedFile("fonts/IBMPlexSans-Regular.ttf");
pub const ui_italic = @embedFile("fonts/IBMPlexSans-Italic.ttf");
pub const ui_semibold = @embedFile("fonts/IBMPlexSans-SemiBold.ttf");
pub const ui_semibold_italic = @embedFile("fonts/IBMPlexSans-SemiBoldItalic.ttf");

test "default fonts are embedded as TrueType data" {
    const std = @import("std");
    inline for (.{ mono, mono_italic, ui, ui_italic, ui_semibold, ui_semibold_italic }) |font| {
        try std.testing.expect(font.len > 100_000);
        try std.testing.expectEqualSlices(u8, "\x00\x01\x00\x00", font[0..4]);
    }
}
