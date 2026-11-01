//! Ports of `.ref/zed/crates/text/src/tests.rs` (local editing subset).
const std = @import("std");
const testing = std.testing;
const b = @import("buffer.zig");
const Buffer = b.Buffer;
const Point = b.Point;
const TextSummary = b.TextSummary;
const gpa = testing.allocator;
const ms = std.time.ns_per_ms;

fn rep(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    return comptime blk: {
        var out: [text.len * count]u8 = undefined;
        for (0..count) |i| @memcpy(out[i * text.len ..][0..text.len], text);
        const final = out;
        break :blk &final;
    };
}

fn newBuffer(text: []const u8) !Buffer {
    return Buffer.init(gpa, .local, try b.BufferId.new(1), text);
}

fn expectText(buffer: *const Buffer, expected: []const u8) !void {
    const text = try buffer.snapshot.text(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings(expected, text);
}

fn edit1(buffer: *Buffer, start: usize, end: usize, text: []const u8) !void {
    _ = try buffer.edit(&.{.{ .start = start, .end = end, .text = text }});
}

/// `Buffer::check_invariants`.
fn checkInvariants(buffer: *const Buffer) !void {
    const snap = &buffer.snapshot;
    var prev_id = b.Locator.min;
    var it = snap.fragments.iter();
    while (it.next()) |fragment| {
        try testing.expect(fragment.id.cmp(&prev_id) == .gt);
        prev_id = fragment.id;
        const insertion = snap.insertions.get(.{ .timestamp = fragment.timestamp, .split_offset = fragment.insertion_offset }, {}).?;
        try testing.expect(insertion.fragment_id.eql(fragment.id));
    }
    var c = snap.fragments.cursor(b.FragmentIdDim, null);
    var insertions = snap.insertions.iter();
    while (insertions.next()) |insertion| {
        _ = c.seek(b.FragmentIdDim{ .id = insertion.fragment_id }, .left);
        const fragment = c.item().?;
        try testing.expect(insertion.fragment_id.eql(fragment.id));
        try testing.expectEqual(insertion.split_offset, fragment.insertion_offset);
    }
    try testing.expectEqual(snap.visible_text.len(), snap.fragments.summary().text.visible);
    try testing.expectEqual(snap.deleted_text.len(), snap.fragments.summary().text.deleted);
    const text = try snap.text(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\r\n") == null);
}

test "edit" {
    var buffer = try newBuffer("abc");
    defer buffer.deinit();
    try expectText(&buffer, "abc");
    try edit1(&buffer, 3, 3, "def");
    try expectText(&buffer, "abcdef");
    try edit1(&buffer, 0, 0, "ghi");
    try expectText(&buffer, "ghiabcdef");
    try edit1(&buffer, 5, 5, "jkl");
    try expectText(&buffer, "ghiabjklcdef");
    try edit1(&buffer, 6, 7, "");
    try expectText(&buffer, "ghiabjlcdef");
    try edit1(&buffer, 4, 9, "mno");
    try expectText(&buffer, "ghiamnoef");
    try checkInvariants(&buffer);
}

test "line endings" {
    var buffer = try newBuffer("one\r\ntwo\rthree");
    defer buffer.deinit();
    try expectText(&buffer, "one\ntwo\nthree");
    try testing.expectEqual(b.LineEnding.windows, buffer.snapshot.line_ending);
    try checkInvariants(&buffer);
    const len = buffer.snapshot.len();
    try edit1(&buffer, len, len, "\r\nfour");
    try edit1(&buffer, 0, 0, "zero\r\n");
    try expectText(&buffer, "zero\none\ntwo\nthree\nfour");
    try testing.expectEqual(b.LineEnding.windows, buffer.snapshot.line_ending);
    try checkInvariants(&buffer);
}

test "line len" {
    var buffer = try newBuffer("");
    defer buffer.deinit();
    try edit1(&buffer, 0, 0, "abcd\nefg\nhij");
    try edit1(&buffer, 12, 12, "kl\nmno");
    try edit1(&buffer, 18, 18, "\npqrs\n");
    try edit1(&buffer, 18, 21, "\nPQ");
    const expected = [_]u32{ 4, 3, 5, 3, 4, 0 };
    for (expected, 0..) |want, row| try testing.expectEqual(want, buffer.snapshot.lineLen(@intCast(row)));
}

test "text summary for range" {
    var buffer = try newBuffer("ab\nefg\nhklm\nnopqrs\ntuvwxyz");
    defer buffer.deinit();
    const snap = &buffer.snapshot;
    const text = "ab\nefg\nhklm\nnopqrs\ntuvwxyz";
    for ([_][2]usize{ .{ 0, 2 }, .{ 1, 3 }, .{ 1, 12 }, .{ 0, 20 }, .{ 7, 26 } }) |range| {
        try testing.expect(snap.textSummaryForRange(TextSummary, range[0], range[1]).eql(TextSummary.fromStr(text[range[0]..range[1]])));
    }
}

test "anchors" {
    var buffer = try newBuffer("");
    defer buffer.deinit();
    try edit1(&buffer, 0, 0, "abc");
    const left = buffer.snapshot.anchorBefore(@as(usize, 2));
    const right = buffer.snapshot.anchorAfter(@as(usize, 2));

    try edit1(&buffer, 1, 1, "def\n");
    try expectText(&buffer, "adef\nbc");
    try testing.expectEqual(@as(usize, 6), buffer.snapshot.toOffset(left));
    try testing.expectEqual(@as(usize, 6), buffer.snapshot.toOffset(right));
    try testing.expect(buffer.snapshot.toPoint(left).eql(.new(1, 1)));
    try testing.expect(buffer.snapshot.toPoint(right).eql(.new(1, 1)));

    try edit1(&buffer, 2, 3, "");
    try expectText(&buffer, "adf\nbc");
    try testing.expectEqual(@as(usize, 5), buffer.snapshot.toOffset(left));
    try testing.expectEqual(@as(usize, 5), buffer.snapshot.toOffset(right));

    try edit1(&buffer, 5, 5, "ghi\n");
    try expectText(&buffer, "adf\nbghi\nc");
    try testing.expectEqual(@as(usize, 5), buffer.snapshot.toOffset(left));
    try testing.expectEqual(@as(usize, 9), buffer.snapshot.toOffset(right));
    try testing.expect(buffer.snapshot.toPoint(right).eql(.new(2, 0)));

    try edit1(&buffer, 7, 9, "");
    try expectText(&buffer, "adf\nbghc");
    try testing.expectEqual(@as(usize, 5), buffer.snapshot.toOffset(left));
    try testing.expectEqual(@as(usize, 7), buffer.snapshot.toOffset(right));
    try testing.expect(buffer.snapshot.toPoint(right).eql(.new(1, 3)));

    // Anchoring to a point is equivalent to anchoring to an offset.
    const points = [_]Point{ .new(0, 0), .new(0, 1), .new(0, 2), .new(0, 3), .new(1, 0), .new(1, 1), .new(1, 2), .new(1, 3), .new(1, 4) };
    for (points, 0..) |p, offset| try testing.expect(buffer.snapshot.anchorBefore(p).eql(buffer.snapshot.anchorBefore(offset)));

    const a0 = buffer.snapshot.anchorBefore(@as(usize, 0));
    const a1 = buffer.snapshot.anchorBefore(@as(usize, 1));
    const a2 = buffer.snapshot.anchorBefore(@as(usize, 2));
    const snap = &buffer.snapshot;
    try testing.expectEqual(std.math.Order.eq, a0.cmp(a0, snap));
    try testing.expectEqual(std.math.Order.eq, a1.cmp(a1, snap));
    try testing.expectEqual(std.math.Order.lt, a0.cmp(a1, snap));
    try testing.expectEqual(std.math.Order.lt, a1.cmp(a2, snap));
    try testing.expectEqual(std.math.Order.lt, a0.cmp(a2, snap));
    try testing.expectEqual(std.math.Order.gt, a1.cmp(a0, snap));
    try testing.expectEqual(std.math.Order.gt, a2.cmp(a1, snap));
    try testing.expectEqual(std.math.Order.gt, a2.cmp(a0, snap));
}

test "anchors at start and end" {
    var buffer = try newBuffer("");
    defer buffer.deinit();
    const before_start = buffer.snapshot.anchorBefore(@as(usize, 0));
    const after_end = buffer.snapshot.anchorAfter(@as(usize, 0));
    try edit1(&buffer, 0, 0, "abc");
    try expectText(&buffer, "abc");
    try testing.expectEqual(@as(usize, 0), buffer.snapshot.toOffset(before_start));
    try testing.expectEqual(@as(usize, 3), buffer.snapshot.toOffset(after_end));
    const after_start = buffer.snapshot.anchorAfter(@as(usize, 0));
    const before_end = buffer.snapshot.anchorBefore(@as(usize, 3));
    try edit1(&buffer, 3, 3, "def");
    try edit1(&buffer, 0, 0, "ghi");
    try expectText(&buffer, "ghiabcdef");
    try testing.expectEqual(@as(usize, 0), buffer.snapshot.toOffset(before_start));
    try testing.expectEqual(@as(usize, 3), buffer.snapshot.toOffset(after_start));
    try testing.expectEqual(@as(usize, 6), buffer.snapshot.toOffset(before_end));
    try testing.expectEqual(@as(usize, 9), buffer.snapshot.toOffset(after_end));
}

test "undo redo" {
    var buffer = try newBuffer("1234");
    defer buffer.deinit();
    buffer.setGroupInterval(0);
    try edit1(&buffer, 1, 1, "abx");
    try edit1(&buffer, 3, 4, "yzef");
    try edit1(&buffer, 3, 5, "cd");
    try expectText(&buffer, "1abcdef234");
    const entries = buffer.history.undo_stack.items;
    try testing.expectEqual(@as(usize, 3), entries.len);
    var t: [3]b.Transaction = undefined;
    for (&t, entries) |*slot, *entry| slot.* = try entry.transaction.clone(gpa);
    defer for (&t) |*slot| slot.deinit(gpa);

    const steps = [_]struct { usize, []const u8 }{
        .{ 0, "1cdef234" },   .{ 0, "1abcdef234" }, .{ 1, "1abcdx234" },
        .{ 2, "1abx234" },    .{ 1, "1abyzef234" }, .{ 2, "1abcdef234" },
        .{ 2, "1abyzef234" }, .{ 0, "1yzef234" },   .{ 1, "1234" },
    };
    for (steps) |step| {
        _ = try buffer.undoOrRedo(&t[step[0]]);
        try expectText(&buffer, step[1]);
    }
    try checkInvariants(&buffer);
}

test "history" {
    var now: b.Instant = 1_000_000_000;
    var buffer = try newBuffer("123456");
    defer buffer.deinit();
    buffer.setGroupInterval(300 * ms);

    const transaction_1 = (try buffer.startTransactionAt(now)).?;
    try edit1(&buffer, 2, 4, "cd");
    _ = try buffer.endTransactionAt(now);
    try expectText(&buffer, "12cd56");

    _ = try buffer.startTransactionAt(now);
    try edit1(&buffer, 4, 5, "e");
    try testing.expect(try buffer.endTransactionAt(now) != null);
    try expectText(&buffer, "12cde6");

    now += buffer.transactionGroupInterval() + ms;
    _ = try buffer.startTransactionAt(now);
    try edit1(&buffer, 0, 1, "a");
    try edit1(&buffer, 1, 1, "b");
    try testing.expect(try buffer.endTransactionAt(now) != null);
    try expectText(&buffer, "ab2cde6");

    _ = try buffer.undo();
    try expectText(&buffer, "12cde6");
    _ = try buffer.undo();
    try expectText(&buffer, "123456");
    _ = try buffer.redo();
    try expectText(&buffer, "12cde6");
    _ = try buffer.redo();
    try expectText(&buffer, "ab2cde6");

    _ = try buffer.startTransactionAt(now);
    try testing.expect(try buffer.endTransactionAt(now) == null);
    _ = try buffer.undo();
    try expectText(&buffer, "12cde6");

    // Redo stack gets cleared after performing an edit.
    _ = try buffer.startTransactionAt(now);
    try edit1(&buffer, 0, 0, "X");
    _ = try buffer.endTransactionAt(now);
    try expectText(&buffer, "X12cde6");
    _ = try buffer.redo();
    try expectText(&buffer, "X12cde6");
    _ = try buffer.undo();
    try expectText(&buffer, "12cde6");
    _ = try buffer.undo();
    try expectText(&buffer, "123456");

    // Transactions can be grouped manually.
    _ = try buffer.redo();
    _ = try buffer.redo();
    try expectText(&buffer, "X12cde6");
    try buffer.groupUntilTransaction(transaction_1);
    _ = try buffer.undo();
    try expectText(&buffer, "123456");
    _ = try buffer.redo();
    try expectText(&buffer, "X12cde6");
}

test "finalize last transaction" {
    const now: b.Instant = 1_000_000_000;
    var buffer = try newBuffer("123456");
    defer buffer.deinit();
    buffer.setGroupInterval(1 * ms);

    _ = try buffer.startTransactionAt(now);
    try edit1(&buffer, 2, 4, "cd");
    _ = try buffer.endTransactionAt(now);
    try expectText(&buffer, "12cd56");

    _ = buffer.finalizeLastTransaction();
    _ = try buffer.startTransactionAt(now);
    try edit1(&buffer, 4, 5, "e");
    _ = try buffer.endTransactionAt(now);
    try expectText(&buffer, "12cde6");

    _ = try buffer.startTransactionAt(now);
    try edit1(&buffer, 0, 1, "a");
    try edit1(&buffer, 1, 1, "b");
    _ = try buffer.endTransactionAt(now);
    try expectText(&buffer, "ab2cde6");

    _ = try buffer.undo();
    try expectText(&buffer, "12cd56");
    _ = try buffer.undo();
    try expectText(&buffer, "123456");
    _ = try buffer.redo();
    try expectText(&buffer, "12cd56");
    _ = try buffer.redo();
    try expectText(&buffer, "ab2cde6");
}

test "edit splits large insertions" {
    var buffer = try newBuffer("abcdefghij");
    defer buffer.deinit();
    const large = comptime rep("X", 100);
    try edit1(&buffer, 3, 7, large);
    const expected = "abc" ++ large ++ "hij";
    try expectText(&buffer, expected);
    try checkInvariants(&buffer);
    for ([_]usize{ 0, 3, 50, 103, expected.len }) |offset| {
        const anchor = buffer.snapshot.anchorBefore(offset);
        try testing.expectEqual(offset, buffer.snapshot.toOffset(anchor));
    }

    var multi = try newBuffer("abcdefghij");
    defer multi.deinit();
    const emoji = comptime rep("😀", 30);
    try edit1(&multi, 5, 5, emoji);
    try expectText(&multi, "abcde" ++ emoji ++ "fghij");
    try checkInvariants(&multi);

    var several = try newBuffer("ABCDEFGHIJ");
    defer several.deinit();
    const xs = comptime rep("x", 60);
    _ = try several.edit(&.{ .{ .start = 1, .end = 2, .text = "y" }, .{ .start = 4, .end = 6, .text = xs }, .{ .start = 9, .end = 9, .text = "z" } });
    try expectText(&several, "AyCD" ++ xs ++ "GHIzJ");
    try checkInvariants(&several);

    var two = try newBuffer("ABCDE");
    defer two.deinit();
    _ = try two.edit(&.{ .{ .start = 1, .end = 2, .text = comptime rep("a", 40) }, .{ .start = 3, .end = 4, .text = comptime rep("b", 40) } });
    try expectText(&two, "A" ++ rep("a", 40) ++ "C" ++ rep("b", 40) ++ "E");
    try checkInvariants(&two);
}

test "edit undo after split" {
    var buffer = try newBuffer("hello world");
    defer buffer.deinit();
    buffer.setGroupInterval(0);
    try edit1(&buffer, 5, 6, comptime rep("Z", 50));
    try checkInvariants(&buffer);
    _ = try buffer.undo();
    try expectText(&buffer, "hello world");
    try checkInvariants(&buffer);
}

fn randomText(random: std.Random, out: *std.ArrayList(u8), count: usize) !void {
    const samples = [_][]const u8{ "a", "b", " ", "\n", "\n", "и", "中", "🧘", "é" };
    for (0..count) |_| {
        if (random.uintLessThan(usize, 10) < 5) {
            try out.append(gpa, 'a' + random.uintLessThan(u8, 26));
        } else try out.appendSlice(gpa, samples[random.uintLessThan(usize, samples.len)]);
    }
}

fn randomByteRange(snap: *const b.BufferSnapshot, random: std.Random, start_offset: usize) [2]usize {
    const end = snap.clipOffset(start_offset + random.uintAtMost(usize, snap.len() - start_offset), .right);
    const start = snap.clipOffset(start_offset + random.uintAtMost(usize, end - start_offset), .right);
    return .{ start, end };
}

fn expectRopeText(rope: *const b.Rope, expected: []const u8) !void {
    const text = try rope.toOwnedString(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "random edits" {
    const operations = 10;
    for (0..100) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var reference: std.ArrayList(u8) = .empty;
        defer reference.deinit(gpa);
        try randomText(random, &reference, random.uintLessThan(usize, 3));
        var buffer = try newBuffer(reference.items);
        defer buffer.deinit();
        buffer.setGroupInterval(@intCast(random.uintAtMost(u64, 200) * ms));

        const Version = struct { snapshot: b.BufferSnapshot, subscription: *b.Subscription };
        var versions: std.ArrayList(Version) = .empty;
        defer {
            for (versions.items) |*v| {
                v.snapshot.deinit(gpa);
                v.subscription.release(gpa);
            }
            versions.deinit(gpa);
        }

        for (0..operations) |_| {
            // `randomly_edit` with up to 5 sorted, disjoint edits.
            var texts: [5]std.ArrayList(u8) = @splat(.empty);
            defer for (&texts) |*t| t.deinit(gpa);
            var edits: [5]b.RangeEdit = undefined;
            var count: usize = 0;
            var last_end: ?usize = null;
            for (0..5) |_| {
                if (last_end) |end| if (end >= buffer.snapshot.len()) break;
                const new_start = if (last_end) |end| end + 1 else 0;
                const range = randomByteRange(&buffer.snapshot, random, new_start);
                last_end = range[1];
                try randomText(random, &texts[count], random.uintLessThan(usize, 10));
                edits[count] = .{ .start = range[0], .end = range[1], .text = texts[count].items };
                count += 1;
            }
            _ = try buffer.edit(edits[0..count]);
            var i = count;
            while (i > 0) {
                i -= 1;
                try reference.replaceRange(gpa, edits[i].start, edits[i].end - edits[i].start, edits[i].text);
            }
            try expectText(&buffer, reference.items);

            if (random.float(f64) < 0.25) {
                // `randomly_undo_redo`.
                for (0..1 + random.uintLessThan(usize, 5)) |_| {
                    const stack = buffer.history.undo_stack.items;
                    if (stack.len == 0) break;
                    var transaction = try stack[random.uintLessThan(usize, stack.len)].transaction.clone(gpa);
                    defer transaction.deinit(gpa);
                    _ = try buffer.undoOrRedo(&transaction);
                }
                reference.clearRetainingCapacity();
                const text = try buffer.snapshot.text(gpa);
                defer gpa.free(text);
                try reference.appendSlice(gpa, text);
            }

            const range = randomByteRange(&buffer.snapshot, random, 0);
            try testing.expect(buffer.snapshot.textSummaryForRange(TextSummary, range[0], range[1]).eql(TextSummary.fromStr(reference.items[range[0]..range[1]])));
            try checkInvariants(&buffer);

            if (random.float(f64) < 0.3) {
                try versions.append(gpa, .{ .snapshot = buffer.cloneSnapshot(), .subscription = try buffer.subscribe() });
            }
        }

        const current = try buffer.snapshot.text(gpa);
        defer gpa.free(current);
        for (versions.items) |*version| {
            const old = &version.snapshot;
            // Replaying `edits_since` turns the old text into the new text.
            {
                var text = old.visible_text.clone();
                defer text.deinit(gpa);
                var edits = buffer.snapshot.editsSince(usize, &old.version);
                while (edits.next()) |e| {
                    const new_text = try buffer.snapshot.textForRange(gpa, e.new.start, e.new.end);
                    defer gpa.free(new_text);
                    try text.replace(gpa, e.new.start, e.new.start + (e.old.end - e.old.start), new_text);
                }
                try expectRopeText(&text, current);
            }

            for (0..5) |_| {
                const end_ix = old.clipOffset(random.uintAtMost(usize, old.len()), .right);
                const start_ix = old.clipOffset(random.uintAtMost(usize, end_ix), .left);
                const anchor_range: b.AnchorRange = .{ .start = old.anchorBefore(start_ix), .end = old.anchorAfter(end_ix) };
                const old_start = old.toOffset(anchor_range.start);
                const old_end = old.toOffset(anchor_range.end);
                var old_text: std.ArrayList(u8) = .empty;
                defer old_text.deinit(gpa);
                {
                    const slice = try old.textForRange(gpa, old_start, old_end);
                    defer gpa.free(slice);
                    try old_text.appendSlice(gpa, slice);
                }
                const new_start = buffer.snapshot.toOffset(anchor_range.start);
                const new_end = buffer.snapshot.toOffset(anchor_range.end);
                const new_text = try buffer.snapshot.textForRange(gpa, new_start, new_end);
                defer gpa.free(new_text);
                var edits = buffer.snapshot.editsSinceInRange(usize, &old.version, anchor_range);
                while (edits.next()) |e| {
                    try old_text.replaceRange(gpa, e.new.start, e.old.end - e.old.start, new_text[e.new.start..e.new.end]);
                }
                try testing.expectEqualStrings(new_text, old_text.items);
            }

            var any = buffer.snapshot.editsSince(usize, &old.version);
            try testing.expectEqual(buffer.snapshot.hasEditsSince(&old.version), any.next() != null);

            // Subscriptions accumulate the same edits.
            var patch = version.subscription.consume();
            defer patch.deinit(gpa);
            var text = old.visible_text.clone();
            defer text.deinit(gpa);
            for (patch.edits()) |e| {
                const new_text = try buffer.snapshot.textForRange(gpa, e.new.start, e.new.end);
                defer gpa.free(new_text);
                try text.replace(gpa, e.new.start, e.new.start + (e.old.end - e.old.start), new_text);
            }
            try expectRopeText(&text, current);
        }
    }
}
