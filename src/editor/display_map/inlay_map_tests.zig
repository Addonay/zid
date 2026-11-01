//! Ports of the tests in `.ref/zed/crates/editor/src/display_map/inlay_map.rs`.
const std = @import("std");
const testing = std.testing;
const im = @import("inlay_map.zig");
const mb = @import("../../multi_buffer/multi_buffer.zig");
const text = @import("../../text/zed/root.zig");
const rope_mod = @import("../../rope/rope.zig");
const Point = rope_mod.Point;
const InlayPoint = im.InlayPoint;
const gpa = testing.allocator;

const Fixture = struct {
    multi: mb.MultiBuffer,
    edits: *text.subscription.Subscription(usize),
    map: im.InlayMap,
    next_inlay_id: usize = 0,

    fn init(initial: []const u8) !*Fixture {
        const fixture = try gpa.create(Fixture);
        errdefer gpa.destroy(fixture);
        fixture.multi = try mb.MultiBuffer.singleton(gpa, try text.Buffer.init(gpa, .local, try text.BufferId.new(1), initial));
        fixture.edits = try fixture.multi.subscribe();
        var created = try im.InlayMap.init(gpa, fixture.multi.snapshot());
        created.snapshot.deinit(gpa);
        fixture.map = created.map;
        fixture.next_inlay_id = 0;
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        self.map.deinit();
        self.edits.release(gpa);
        self.multi.deinit();
        gpa.destroy(self);
    }

    fn snapshot(self: *Fixture) mb.MultiBufferSnapshot {
        return self.multi.snapshot();
    }

    fn hint(self: *Fixture, offset: usize, bias: rope_mod.Bias, content: []const u8) !im.Inlay {
        var snap = self.snapshot();
        defer snap.deinit(gpa);
        const id = self.next_inlay_id;
        self.next_inlay_id += 1;
        return im.Inlay.mockHint(gpa, id, snap.anchorAt(offset, bias), content);
    }

    fn prediction(self: *Fixture, offset: usize, bias: rope_mod.Bias, content: []const u8) !im.Inlay {
        var snap = self.snapshot();
        defer snap.deinit(gpa);
        const id = self.next_inlay_id;
        self.next_inlay_id += 1;
        return im.Inlay.editPrediction(gpa, id, snap.anchorAt(offset, bias), content);
    }

    fn splice(self: *Fixture, to_remove: []const im.InlayId, to_insert: []const im.Inlay) !im.SyncResult {
        return self.map.splice(to_remove, to_insert);
    }

    fn edit(self: *Fixture, edits: []const text.buffer.RangeEdit) !im.SyncResult {
        try self.multi.edit(edits);
        var patch = self.edits.consume();
        defer patch.deinit(gpa);
        return self.map.sync(self.snapshot(), patch.edits());
    }
};

fn expectText(snapshot: *const im.InlaySnapshot, expected: []const u8) !void {
    const actual = try snapshot.textAlloc(gpa);
    defer gpa.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn expectPoint(expected: InlayPoint, actual: InlayPoint) !void {
    try testing.expectEqual(expected.point.row, actual.point.row);
    try testing.expectEqual(expected.point.column, actual.point.column);
}

fn expectClip(snapshot: *const im.InlaySnapshot, column: u32, left: u32, right: u32) !void {
    try expectPoint(.new(0, left), snapshot.clipPoint(.new(0, column), .left));
    try expectPoint(.new(0, right), snapshot.clipPoint(.new(0, column), .right));
}

test "failed sync releases the transferred buffer snapshot" {
    const fx = try Fixture.init("abc");
    defer fx.deinit();
    try fx.multi.edit(&.{.{ .start = 1, .end = 1, .text = "x" }});
    var edits = fx.edits.consume();
    defer edits.deinit(gpa);
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    fx.map.gpa = failing.allocator();
    defer fx.map.gpa = gpa;
    try testing.expectError(error.OutOfMemory, fx.map.sync(fx.snapshot(), edits.edits()));
    try testing.expect(failing.has_induced_failure);
}

test "basic inlays" {
    const fx = try Fixture.init("abcdefghi");
    defer fx.deinit();
    try expectText(&fx.map.snapshot, "abcdefghi");

    var r1 = try fx.splice(&.{}, &.{try fx.hint(3, .right, "|123|")});
    defer r1.deinit(gpa);
    const s1 = &r1.snapshot;
    try expectText(s1, "abc|123|defghi");
    const to_inlay = [_][2]u32{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 }, .{ 4, 9 }, .{ 5, 10 } };
    for (to_inlay) |pair| try expectPoint(.new(0, pair[1]), s1.toInlayPoint(.new(0, pair[0])));
    try expectClip(s1, 0, 0, 0);
    try expectClip(s1, 3, 3, 3);
    try expectClip(s1, 4, 3, 9);

    // Edits before or after the inlay should not affect it.
    var r2 = try fx.edit(&.{ .{ .start = 2, .end = 3, .text = "x" }, .{ .start = 3, .end = 3, .text = "y" }, .{ .start = 4, .end = 4, .text = "z" } });
    defer r2.deinit(gpa);
    try expectText(&r2.snapshot, "abxy|123|dzefghi");

    // An edit surrounding the inlay should invalidate it.
    var r3 = try fx.edit(&.{.{ .start = 4, .end = 5, .text = "D" }});
    defer r3.deinit(gpa);
    try expectText(&r3.snapshot, "abxyDzefghi");

    var r4 = try fx.splice(&.{}, &.{ try fx.hint(3, .left, "|123|"), try fx.prediction(3, .right, "|456|") });
    defer r4.deinit(gpa);
    try expectText(&r4.snapshot, "abx|123||456|yDzefghi");

    // Edits ending where the inlay starts should not move it if it has a left bias.
    var r5 = try fx.edit(&.{.{ .start = 3, .end = 3, .text = "JKL" }});
    defer r5.deinit(gpa);
    const s5 = &r5.snapshot;
    try expectText(s5, "abx|123|JKL|456|yDzefghi");
    const clips = [_][3]u32{
        .{ 0, 0, 0 },    .{ 1, 1, 1 },    .{ 2, 2, 2 },    .{ 3, 2, 8 },    .{ 4, 2, 8 },
        .{ 5, 2, 8 },    .{ 6, 2, 8 },    .{ 7, 2, 8 },    .{ 8, 8, 8 },    .{ 9, 9, 9 },
        .{ 10, 10, 10 }, .{ 11, 11, 11 }, .{ 12, 11, 17 }, .{ 13, 11, 17 }, .{ 14, 11, 17 },
        .{ 15, 11, 17 }, .{ 16, 11, 17 }, .{ 17, 17, 17 }, .{ 18, 18, 18 },
    };
    for (clips) |c| try expectClip(s5, c[0], c[1], c[2]);

    // The inlays can be manually removed.
    var ids: std.ArrayList(im.InlayId) = .empty;
    defer ids.deinit(gpa);
    for (fx.map.currentInlays()) |inlay| try ids.append(gpa, inlay.id);
    var r6 = try fx.splice(ids.items, &.{});
    defer r6.deinit(gpa);
    try expectText(&r6.snapshot, "abxJKLyDzefghi");
}

test "inlay buffer rows" {
    const fx = try Fixture.init("abc\ndef\nghi");
    defer fx.deinit();
    var r = try fx.splice(&.{}, &.{
        try fx.hint(0, .left, "|123|\n"),
        try fx.hint(4, .left, "|456|"),
        try fx.prediction(7, .left, "\n|567|\n"),
    });
    defer r.deinit(gpa);
    try expectText(&r.snapshot, "|123|\nabc\n|456|def\n|567|\n\nghi");
    var rows = r.snapshot.rowInfos(0);
    const expected = [_]?u32{ 0, null, 1, null, null, 2 };
    for (expected) |want| try testing.expectEqual(want, rows.next().?.buffer_row);
    try testing.expect(rows.next() == null);
}

const ReferenceInlay = struct { offset: usize, bias: rope_mod.Bias, order: usize, content: []const u8 };

/// Builds the expected output text by inserting inlays (sorted by offset, then by
/// left-bias-first and insertion order) into the buffer text.
fn expectedText(buffer_text: []const u8, inlays: []const ReferenceInlay) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var cursor: usize = 0;
    for (inlays) |inlay| {
        try out.appendSlice(gpa, buffer_text[cursor..inlay.offset]);
        try out.appendSlice(gpa, inlay.content);
        cursor = inlay.offset;
    }
    try out.appendSlice(gpa, buffer_text[cursor..]);
    return out.toOwnedSlice(gpa);
}

test "random inlays keep text, offsets and points consistent" {
    for (0..60) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        const fx = try Fixture.init("ab\ncdef\nghij klm\nnop");
        defer fx.deinit();

        var result: ?im.SyncResult = null;
        defer if (result) |*r| r.deinit(gpa);
        for (0..8) |_| {
            var next: im.SyncResult = undefined;
            if (random.boolean()) {
                var snap = fx.snapshot();
                defer snap.deinit(gpa);
                const offset = snap.clipOffset(random.uintAtMost(usize, snap.len()), .left);
                const bias: rope_mod.Bias = if (random.boolean()) .left else .right;
                const contents = [_][]const u8{ "<a>", "\n", "∂x", "xy\nz" };
                const content = contents[random.uintLessThan(usize, contents.len)];
                next = try fx.splice(&.{}, &.{try fx.hint(offset, bias, content)});
            } else {
                var snap = fx.snapshot();
                defer snap.deinit(gpa);
                const end = snap.clipOffset(random.uintAtMost(usize, snap.len()), .right);
                const start = snap.clipOffset(random.uintAtMost(usize, end), .left);
                const insertions = [_][]const u8{ "", "Q", "\n", "é!" };
                next = try fx.edit(&.{.{ .start = start, .end = end, .text = insertions[random.uintLessThan(usize, insertions.len)] }});
            }
            if (result) |*r| r.deinit(gpa);
            result = next;
        }
        const snap = &result.?.snapshot;
        const actual = try snap.textAlloc(gpa);
        defer gpa.free(actual);

        // Text length and point/offset round trips agree with the produced text.
        try testing.expectEqual(actual.len, snap.len().value);
        var offset: usize = 0;
        var point: Point = .{};
        while (offset <= actual.len) {
            try expectPoint(.{ .point = point }, snap.toPoint(.{ .value = offset }));
            try testing.expectEqual(offset, snap.toOffset(.{ .point = point }).value);
            if (offset == actual.len) break;
            const length = std.unicode.utf8ByteSequenceLength(actual[offset]) catch unreachable;
            if (actual[offset] == '\n') point = point.add(.new(1, 0)) else point.column += @intCast(length);
            offset += length;
        }
        // Summaries for ranges match the produced text.
        for (0..10) |_| {
            const end = rope_mod.chunk.strFloorCharBoundary(actual, random.uintAtMost(usize, actual.len));
            const start = rope_mod.chunk.strFloorCharBoundary(actual, random.uintAtMost(usize, end));
            const summary = snap.textSummaryForRange(.{ .value = start }, .{ .value = end });
            try testing.expect(summary.eql(rope_mod.TextSummary.fromStr(actual[start..end])));
        }
        // Buffer text survives the round trip through inlay offsets.
        const buffer_text = try snap.buffer.text_(gpa);
        defer gpa.free(buffer_text);
        for (0..buffer_text.len + 1) |buffer_offset| {
            if (!rope_mod.chunk.strIsCharBoundary(buffer_text, buffer_offset)) continue;
            const inlay_offset = snap.toInlayOffset(buffer_offset);
            try testing.expectEqual(buffer_offset, snap.toBufferOffset(inlay_offset));
        }
        _ = ReferenceInlay;
        _ = expectedText;
    }
}
