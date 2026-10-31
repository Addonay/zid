//! Small pure string matching helpers shared by UI search fields.
const std = @import("std");

/// ASCII case-insensitive substring test; an empty needle always matches.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    return false;
}

test containsIgnoreCase {
    try std.testing.expect(containsIgnoreCase("Font Size", "SIZE"));
    try std.testing.expect(containsIgnoreCase("abc", ""));
    try std.testing.expect(!containsIgnoreCase("ab", "abc"));
    try std.testing.expect(!containsIgnoreCase("Cursor Blink", "font"));
}
