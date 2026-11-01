//! Standalone synthetic text-engine workload; excludes renderer and filesystem.
//! zig build-exe src/bench_text.zig -O ReleaseFast -femit-bin=/tmp/zid-text-bench
const std = @import("std");
const Document = @import("editor/document.zig").Document;
const SearchPlan = @import("editor/search.zig").SearchPlan;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const bytes = try allocator.alloc(u8, 8 * 1024 * 1024);
    for (bytes, 0..) |*b, i| b.* = if (i % 128 == 127) '\n' else 'x';
    const start = std.Io.Clock.awake.now(init.io);
    var document = try Document.initOwned(allocator, bytes, null);
    defer document.deinit();
    const loaded = std.Io.Clock.awake.now(init.io);
    document.move(document.buffer.len() / 2, false);
    for (0..20000) |i| try document.insert(if (i % 8 == 7) " " else "a");
    const typed = std.Io.Clock.awake.now(init.io);
    const typing_entries = document.history.items.len;
    var undo_count: usize = 0;
    while (document.history_index > 0) : (undo_count += 1) try document.undo();
    while (document.history_index < document.history.items.len) try document.redo();
    const restored = std.Io.Clock.awake.now(init.io);
    var random = std.Random.DefaultPrng.init(91823);
    for (0..2000) |_| {
        const at = random.random().uintLessThan(usize, document.buffer.len());
        try document.replaceRange(at, at + 1, "q");
    }
    const finished = std.Io.Clock.awake.now(init.io);
    var absent = try SearchPlan.init(allocator, "not present anywhere", false);
    defer absent.deinit();
    var dense = try SearchPlan.init(allocator, "xx", false);
    defer dense.deinit();
    const range = @import("editor/search.zig").Range{ .start = 0, .end = document.buffer.len() };
    const search_start = std.Io.Clock.awake.now(init.io);
    if (absent.next(&document.buffer, range, 0) != null) return error.UnexpectedMatch;
    const searched = std.Io.Clock.awake.now(init.io);
    var matches: [4096]usize = undefined;
    const batch = dense.enumerate(&document.buffer, range, 0, &matches);
    const enumerated = std.Io.Clock.awake.now(init.io);
    std.debug.print("absent_search_us={d} dense_batch_us={d} batch_matches={d} continuation={?d}\n", .{ search_start.durationTo(searched).toMicroseconds(), searched.durationTo(enumerated).toMicroseconds(), batch.written, batch.cursor });
    std.debug.print("source_bytes={d} init_us={d} typing_20000_us={d} typing_history={d} undo_redo_entries={d} undo_redo_us={d} random_edits_2000_us={d} final_pieces={d} final_bytes={d}\n", .{
        bytes.len,                                      start.durationTo(loaded).toMicroseconds(), loaded.durationTo(typed).toMicroseconds(),
        typing_entries,                                 undo_count,                                typed.durationTo(restored).toMicroseconds(),
        restored.durationTo(finished).toMicroseconds(), document.buffer.pieceCount(),              document.buffer.len(),
    });
}
