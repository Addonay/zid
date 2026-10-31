const token = @import("token.zig");
pub const Kind = token.Kind;
pub const Span = token.Span;
pub const Sink = token.Sink;
pub const Language = token.Language;
pub fn lexLine(language: Language, state: u32, line: []const u8, sink: *Sink) u32 {
    return switch (language) {
        .plain => 0,
        .zig => @import("zig.zig").lexLine(state, line, sink),
        .c => @import("c.zig").lexLineC(state, line, sink),
        .cpp => @import("c.zig").lexLineCpp(state, line, sink),
        .python => @import("python.zig").lexLine(state, line, sink),
        .sql => @import("sql.zig").lexLine(state, line, sink),
        .json => @import("json.zig").lexLine(state, line, sink),
        .markdown => @import("markdown.zig").lexLine(state, line, sink),
    };
}
test {
    _ = token;
    _ = @import("zig.zig");
    _ = @import("c.zig");
    _ = @import("python.zig");
    _ = @import("sql.zig");
    _ = @import("json.zig");
    _ = @import("markdown.zig");
}
