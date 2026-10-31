//! Standalone backend benchmark, deliberately excluding SDL and renderer memory.
//! zig build-exe src/bench_large_file.zig -O ReleaseFast -femit-bin=/tmp/zid-large-bench
//! /usr/bin/time -v /tmp/zid-large-bench /absolute/file [index-byte-budget]
const std = @import("std");
const large = @import("text/large_file.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.ExpectedFileAndOptionalIndexBudget;
    const budget = if (args.len == 3) try std.fmt.parseInt(usize, args[2], 10) else 16 * 1024 * 1024;
    const start = std.Io.Clock.awake.now(init.io);
    var file = try large.LargeFile.open(init.gpa, init.io, std.Io.Dir.cwd(), args[1]);
    defer file.deinit(init.io);
    const opened = std.Io.Clock.awake.now(init.io);
    var bytes: [large.max_window]u8 = undefined;
    var checksum: u64 = 0;
    const first = try file.readWindow(init.io, 0, &bytes);
    for (bytes[0..first]) |b| checksum +%= b;
    const last = try file.readWindow(init.io, file.size() -| large.max_window, &bytes);
    for (bytes[0..last]) |b| checksum +%= b;
    const viewed = std.Io.Clock.awake.now(init.io);
    var indexed: usize = 0;
    while (indexed < budget and !file.complete()) {
        indexed += try file.indexStep(init.io, @min(1024 * 1024, budget - indexed));
    }
    const finished = std.Io.Clock.awake.now(init.io);
    std.debug.print("size_bytes={d} open_us={d} first_and_last_read_us={d} indexed_bytes={d} index_us={d} index_metadata_bytes={d} checksum={d}\n", .{
        file.size(), start.durationTo(opened).toMicroseconds(),    opened.durationTo(viewed).toMicroseconds(),
        indexed,     viewed.durationTo(finished).toMicroseconds(), file.chunks.capacity * @sizeOf(u64),
        checksum,
    });
}
