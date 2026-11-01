//! Ports of the tests in `.ref/zed/crates/rope/src/rope.rs`.
const std = @import("std");
const testing = std.testing;
const rope_mod = @import("rope.zig");
const Rope = rope_mod.Rope;
const Point = rope_mod.Point;
const PointUtf16 = rope_mod.PointUtf16;
const OffsetUtf16 = rope_mod.OffsetUtf16;
const Unclipped = rope_mod.Unclipped;
const TextSummary = rope_mod.TextSummary;
const chunk = rope_mod.chunk;
const gpa = testing.allocator;

fn expectText(rope: *const Rope, expected: []const u8) !void {
    const text = try rope.toOwnedString(gpa);
    defer gpa.free(text);
    try testing.expectEqualStrings(expected, text);
}

fn collect(it: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (it.next()) |text| try out.appendSlice(gpa, text);
    return out.toOwnedSlice(gpa);
}

fn repeat(text: []const u8, count: usize) ![]u8 {
    const out = try gpa.alloc(u8, text.len * count);
    for (0..count) |i| @memcpy(out[i * text.len ..][0..text.len], text);
    return out;
}

test "all 4 byte chars" {
    const text = try repeat("🏀", 256);
    defer gpa.free(text);
    var rope = try Rope.fromStr(gpa, text);
    defer rope.deinit(gpa);
    try expectText(&rope, text);
}

test "chunks peek bytes" {
    const text = try repeat("aи中🧘z", 128);
    defer gpa.free(text);
    var rope = try Rope.fromStr(gpa, text);
    defer rope.deinit(gpa);
    for ([_][2]usize{ .{ 0, text.len }, .{ 1, text.len - 1 }, .{ 0, 2 } }) |range| {
        var chunks = rope.chunksInRange(range[0], range[1]);
        var offset = range[0];
        while (offset < range[1]) : (offset += 1) {
            chunks.seek(offset);
            const bytes = chunks.peekBytes().?;
            try testing.expect(bytes.len > 0);
            try testing.expectEqualSlices(u8, text[offset..][0..bytes.len], bytes);
            try testing.expect(offset + bytes.len <= range[1]);
        }
        chunks.seek(range[1]);
        try testing.expect(chunks.peekBytes() == null);
    }
    for ([_][2]usize{ .{ 0, text.len }, .{ 2, text.len - 1 }, .{ 2, 3 } }) |range| {
        var chunks = rope.reversedChunksInRange(range[0], range[1]);
        var offset = range[0] + 1;
        while (offset <= range[1]) : (offset += 1) {
            chunks.seek(offset);
            const bytes = chunks.peekBytes().?;
            try testing.expect(bytes.len > 0);
            try testing.expectEqualSlices(u8, text[offset - bytes.len .. offset], bytes);
            try testing.expect(offset - bytes.len >= range[0]);
        }
        chunks.seek(range[0]);
        try testing.expect(chunks.peekBytes() == null);
    }
    var empty = try Rope.init(gpa);
    defer empty.deinit(gpa);
    try testing.expect(empty.chunksAll().peekBytes() == null);
}

test "clip" {
    var rope = try Rope.fromStr(gpa, "🧘");
    defer rope.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), rope.clipOffset(1, .left));
    try testing.expectEqual(@as(usize, 4), rope.clipOffset(1, .right));
    try testing.expectEqual(@as(usize, 4), rope.clipOffset(5, .right));
    try testing.expect(rope.clipPoint(.new(0, 1), .left).eql(.new(0, 0)));
    try testing.expect(rope.clipPoint(.new(0, 1), .right).eql(.new(0, 4)));
    try testing.expect(rope.clipPoint(.new(0, 5), .right).eql(.new(0, 4)));
    try testing.expect(rope.clipPointUtf16(.init(.new(0, 1)), .left).eql(.new(0, 0)));
    try testing.expect(rope.clipPointUtf16(.init(.new(0, 1)), .right).eql(.new(0, 2)));
    try testing.expect(rope.clipPointUtf16(.init(.new(0, 3)), .right).eql(.new(0, 2)));
    try testing.expectEqual(@as(usize, 0), rope.clipOffsetUtf16(.new(1), .left).value);
    try testing.expectEqual(@as(usize, 2), rope.clipOffsetUtf16(.new(1), .right).value);
    try testing.expectEqual(@as(usize, 2), rope.clipOffsetUtf16(.new(3), .right).value);
}

fn firstByte(chunks: *const rope_mod.Chunks) ?u8 {
    const text = chunks.peek() orelse return null;
    return text[0];
}

test "prev next line" {
    var rope = try Rope.fromStr(gpa, "abc\ndef\nghi\njkl");
    defer rope.deinit(gpa);
    var chunks = rope.chunksAll();
    try testing.expectEqual(@as(?u8, 'a'), firstByte(&chunks));
    try testing.expect(chunks.nextLine());
    try testing.expectEqual(@as(?u8, 'd'), firstByte(&chunks));
    try testing.expect(chunks.nextLine());
    try testing.expectEqual(@as(?u8, 'g'), firstByte(&chunks));
    try testing.expect(chunks.nextLine());
    try testing.expectEqual(@as(?u8, 'j'), firstByte(&chunks));
    try testing.expect(!chunks.nextLine());
    try testing.expect(chunks.peek() == null);
    try testing.expect(chunks.prevLine());
    try testing.expectEqual(@as(?u8, 'j'), firstByte(&chunks));
    try testing.expect(chunks.prevLine());
    try testing.expectEqual(@as(?u8, 'g'), firstByte(&chunks));
    try testing.expect(chunks.prevLine());
    try testing.expectEqual(@as(?u8, 'd'), firstByte(&chunks));
    try testing.expect(chunks.prevLine());
    try testing.expectEqual(@as(?u8, 'a'), firstByte(&chunks));
    try testing.expect(!chunks.prevLine());
    try testing.expectEqual(@as(?u8, 'a'), firstByte(&chunks));

    // Only return true when the cursor has moved to the start of a line.
    var ranged = rope.chunksInRange(5, 7);
    ranged.seek(6);
    try testing.expect(!ranged.prevLine());
    try testing.expectEqual(@as(?u8, 'e'), firstByte(&ranged));
    try testing.expect(!ranged.nextLine());
    try testing.expect(ranged.peek() == null);
}

fn expectLines(text: []const u8, reversed: bool, expected: []const []const u8) !void {
    var rope = try Rope.fromStr(gpa, text);
    defer rope.deinit(gpa);
    var lines = if (reversed) rope.reversedChunksInRange(0, rope.len()).lines() else rope.chunksAll().lines();
    defer lines.deinit(gpa);
    for (expected) |line| try testing.expectEqualStrings(line, (try lines.next(gpa)).?);
    try testing.expect(try lines.next(gpa) == null);
}

test "lines" {
    try expectLines("abc\ndefg\nhi", false, &.{ "abc", "defg", "hi" });
    try expectLines("abc\ndefg\nhi\n", false, &.{ "abc", "defg", "hi", "" });
    try expectLines("abc\ndefg\nhi", true, &.{ "hi", "defg", "abc" });
    try expectLines("abc\ndefg\nhi\n", true, &.{ "", "hi", "defg", "abc" });
    try expectLines("abc\nlonger line test\nhi", false, &.{ "abc", "longer line test", "hi" });
    try expectLines("abc\nlonger line test\nhi", true, &.{ "hi", "longer line test", "abc" });
}

test "chunks equals str" {
    const text = "This is a multi-chunk\n& multi-line test string!";
    var rope = try Rope.fromStr(gpa, text);
    defer rope.deinit(gpa);
    for (0..text.len) |start| {
        for (start..text.len) |end| {
            const correct = text[start..end];
            var forward = rope.chunksInRange(start, end);
            try testing.expect(forward.equalsStr(correct));
            var backward = rope.reversedChunksInRange(start, end);
            try testing.expect(backward.equalsStr(correct));
            if (end > start + 1) {
                try testing.expect(!forward.equalsStr(text[start .. end - 1]));
                try testing.expect(!backward.equalsStr(text[start + 1 .. end]));
            }
        }
    }
}

test "starts with ends with" {
    var rope = try Rope.fromStr(gpa, "abcd\nefgh\nijkl");
    defer rope.deinit(gpa);
    try testing.expect(rope.startsWith(""));
    try testing.expect(rope.startsWith("abcd\nef"));
    try testing.expect(!rope.startsWith("abd"));
    try testing.expect(!rope.startsWith("abcd\nefgh\nijklm"));
    try testing.expect(rope.endsWith(""));
    try testing.expect(rope.endsWith("gh\nijkl"));
    try testing.expect(!rope.endsWith("ikl"));
    try testing.expect(!rope.endsWith("0abcd\nefgh\nijkl"));
}

test "char boundaries" {
    const text = "aи中🧘z";
    var rope = try Rope.fromStr(gpa, text);
    defer rope.deinit(gpa);
    for (0..text.len + 2) |offset| {
        try testing.expectEqual(chunk.strIsCharBoundary(text, offset), rope.isCharBoundary(offset));
        try testing.expectEqual(chunk.strFloorCharBoundary(text, offset), rope.floorCharBoundary(offset));
        try testing.expectEqual(chunk.strCeilCharBoundary(text, offset), rope.ceilCharBoundary(offset));
    }
}

test "push front" {
    var empty = try Rope.init(gpa);
    defer empty.deinit(gpa);
    try empty.pushFront(gpa, "");
    try testing.expect(empty.isEmpty());

    var rope = try Rope.fromStr(gpa, "hello");
    defer rope.deinit(gpa);
    try rope.pushFront(gpa, "");
    try expectText(&rope, "hello");
    try rope.pushFront(gpa, " ");
    try expectText(&rope, " hello");

    var other = try Rope.init(gpa);
    defer other.deinit(gpa);
    try other.pushFront(gpa, "hello");
    try expectText(&other, "hello");

    for (0..50) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);
        var actual = try Rope.init(gpa);
        defer actual.deinit(gpa);
        for (0..10) |_| {
            const text = try randomText(random, random.uintAtMost(usize, 40));
            defer gpa.free(text);
            try actual.pushFront(gpa, text);
            try expected.insertSlice(gpa, 0, text);
            try expectText(&actual, expected.items);
        }
    }
}

/// Mix of ASCII, newlines, 2/3/4-byte characters (like Zed's `RandomCharIter`).
fn randomText(random: std.Random, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const samples = [_][]const u8{ "a", "b", "z", " ", "\t", "\n", "\n", "и", "中", "🧘", "é", "🏀" };
    for (0..count) |_| {
        const roll = random.uintLessThan(usize, 10);
        if (roll < 5) {
            try out.append(gpa, 'a' + random.uintLessThan(u8, 26));
        } else try out.appendSlice(gpa, samples[random.uintLessThan(usize, samples.len)]);
    }
    return out.toOwnedSlice(gpa);
}

fn randomBoundary(random: std.Random, text: []const u8, max: usize, bias: rope_mod.Bias) usize {
    const offset = random.uintAtMost(usize, max);
    return switch (bias) {
        .left => chunk.strFloorCharBoundary(text, offset),
        .right => chunk.strCeilCharBoundary(text, offset),
    };
}

test "random rope" {
    const operations = 10;
    for (0..100) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);
        var actual = try Rope.init(gpa);
        defer actual.deinit(gpa);

        for (0..operations) |_| {
            const end_ix = randomBoundary(random, expected.items, expected.items.len, .right);
            const start_ix = randomBoundary(random, expected.items, end_ix, .left);
            const new_text = try randomText(random, random.uintAtMost(usize, 64));
            defer gpa.free(new_text);

            var new_actual = try Rope.init(gpa);
            {
                errdefer new_actual.deinit(gpa);
                var cursor = actual.cursor(0);
                try new_actual.append(gpa, try cursor.slice(gpa, start_ix));
                try new_actual.push(gpa, new_text);
                cursor.seekForward(end_ix);
                try new_actual.append(gpa, try cursor.suffix(gpa));
            }
            actual.deinit(gpa);
            actual = new_actual;
            try expected.replaceRange(gpa, start_ix, end_ix - start_ix, new_text);
            const text = expected.items;
            try expectText(&actual, text);

            for (0..5) |_| {
                const range_end = randomBoundary(random, text, text.len, .right);
                const range_start = randomBoundary(random, text, range_end, .left);
                const want = text[range_start..range_end];

                var forward = actual.chunksInRange(range_start, range_end);
                const forward_text = try collect(&forward);
                defer gpa.free(forward_text);
                try testing.expectEqualStrings(want, forward_text);

                var bytes = actual.bytesInRange(range_start, range_end);
                const bytes_text = try collect(&bytes);
                defer gpa.free(bytes_text);
                try testing.expectEqualStrings(want, bytes_text);

                var reversed: std.ArrayList(u8) = .empty;
                defer reversed.deinit(gpa);
                var backward = actual.reversedChunksInRange(range_start, range_end);
                while (backward.next()) |piece| try reversed.insertSlice(gpa, 0, piece);
                try testing.expectEqualStrings(want, reversed.items);

                // next_line visits each line start inside the range.
                var expected_starts: std.ArrayList(usize) = .empty;
                defer expected_starts.deinit(gpa);
                for (want, 0..) |byte, i| if (byte == '\n') try expected_starts.append(gpa, range_start + i + 1);
                var chunks = actual.chunksInRange(range_start, range_end);
                var actual_starts: std.ArrayList(usize) = .empty;
                defer actual_starts.deinit(gpa);
                while (chunks.nextLine()) try actual_starts.append(gpa, chunks.getOffset());
                try testing.expectEqualSlices(usize, expected_starts.items, actual_starts.items);

                if (range_start < range_end and (range_start == 0 or text[range_start - 1] == '\n')) try expected_starts.insert(gpa, 0, range_start);
                if (expected_starts.items.len > 0 and expected_starts.items[expected_starts.items.len - 1] == range_end) _ = expected_starts.pop();
                actual_starts.clearRetainingCapacity();
                while (chunks.prevLine()) try actual_starts.append(gpa, chunks.getOffset());
                std.mem.reverse(usize, actual_starts.items);
                try testing.expectEqualSlices(usize, expected_starts.items, actual_starts.items);

                // next_line / prev_line from random positions.
                var offset = chunk.strFloorCharBoundary(text, range_start + random.uintAtMost(usize, range_end - range_start));
                if (offset < range_start) offset = range_start;
                chunks.seek(offset);
                for (0..5) |_| {
                    if (random.boolean()) {
                        const next_start: ?usize = if (std.mem.indexOfScalar(u8, text[offset..range_end], '\n')) |ix| offset + ix + 1 else null;
                        try testing.expectEqual(next_start != null, chunks.nextLine());
                        try testing.expectEqual(next_start orelse range_end, chunks.getOffset());
                    } else {
                        const search_end = if (offset > 0 and text[offset - 1] == '\n') offset - 1 else offset;
                        var prev_start: ?usize = null;
                        if (std.mem.lastIndexOfScalar(u8, text[0..search_end], '\n')) |ix| {
                            if (ix + 1 >= range_start) prev_start = ix + 1;
                        }
                        if (prev_start == null and offset > 0 and range_start == 0) prev_start = 0;
                        try testing.expectEqual(prev_start != null, chunks.prevLine());
                        try testing.expectEqual(prev_start orelse range_start, chunks.getOffset());
                    }
                    try testing.expect(chunks.getOffset() >= range_start and chunks.getOffset() <= range_end);
                    if (random.boolean()) {
                        offset = chunk.strFloorCharBoundary(text, range_start + random.uintAtMost(usize, range_end - range_start));
                        if (offset < range_start) offset = range_start;
                        chunks.seek(offset);
                    } else {
                        _ = chunks.next();
                        offset = chunks.getOffset();
                        try testing.expect(offset >= range_start and offset <= range_end);
                    }
                }
            }

            // Offset/point conversions at every char boundary.
            var offset_utf16: OffsetUtf16 = .{};
            var point: Point = .{};
            var point_utf16: PointUtf16 = .{};
            var ix: usize = 0;
            while (true) {
                try testing.expect(actual.offsetToPoint(ix).eql(point));
                try testing.expect(actual.offsetToPointUtf16(ix).eql(point_utf16));
                try testing.expectEqual(ix, actual.pointToOffset(point));
                try testing.expectEqual(ix, actual.pointUtf16ToOffset(point_utf16));
                try testing.expectEqual(offset_utf16.value, actual.offsetToOffsetUtf16(ix).value);
                try testing.expectEqual(ix, actual.offsetUtf16ToOffset(offset_utf16));
                if (ix == text.len) break;
                const length = std.unicode.utf8ByteSequenceLength(text[ix]) catch unreachable;
                const c = std.unicode.utf8Decode(text[ix..][0..length]) catch unreachable;
                const units: u32 = if (c >= 0x10000) 2 else 1;
                if (c == '\n') {
                    point = point.add(.new(1, 0));
                    point_utf16 = point_utf16.add(.new(1, 0));
                } else {
                    point.column += @intCast(length);
                    point_utf16.column += units;
                }
                offset_utf16.value += units;
                ix += length;
            }

            // Clipping every UTF-16 unit stays ordered and translatable.
            {
                var unit_offset: OffsetUtf16 = .{};
                var unit_point: PointUtf16 = .{};
                var view = std.unicode.Utf8View.initUnchecked(text);
                var it = view.iterator();
                while (it.nextCodepoint()) |c| {
                    const units: usize = if (c >= 0x10000) 2 else 1;
                    for (0..units) |_| {
                        const left = actual.clipOffsetUtf16(unit_offset, .left);
                        const right = actual.clipOffsetUtf16(unit_offset, .right);
                        try testing.expect(right.value >= left.value);
                        _ = actual.offsetUtf16ToOffset(left);
                        _ = actual.offsetUtf16ToOffset(right);
                        const left_point = actual.clipPointUtf16(.init(unit_point), .left);
                        const right_point = actual.clipPointUtf16(.init(unit_point), .right);
                        try testing.expect(right_point.cmp(&left_point) != .lt);
                        _ = actual.pointUtf16ToOffset(left_point);
                        _ = actual.pointUtf16ToOffset(right_point);
                        unit_offset.value += 1;
                        unit_point = if (c == '\n') unit_point.add(.new(1, 0)) else unit_point.add(.new(0, 1));
                    }
                }
            }

            for (0..5) |_| {
                const range_end = randomBoundary(random, text, text.len, .right);
                const range_start = randomBoundary(random, text, range_end, .left);
                var cursor = actual.cursor(range_start);
                const summary = cursor.summary(TextSummary, range_end);
                try testing.expect(summary.eql(TextSummary.fromStr(text[range_start..range_end])));
            }

            // Line lengths and the longest row.
            var longest_len: isize = -1;
            var longest_rows: std.ArrayList(u32) = .empty;
            defer longest_rows.deinit(gpa);
            var rows = std.mem.splitScalar(u8, text, '\n');
            var row: u32 = 0;
            while (rows.next()) |line| : (row += 1) {
                try testing.expectEqual(@as(u32, @intCast(line.len)), actual.lineLen(row));
                const count: isize = @intCast(std.unicode.utf8CountCodepoints(line) catch unreachable);
                if (count == longest_len) {
                    try longest_rows.append(gpa, row);
                } else if (count > longest_len) {
                    longest_len = count;
                    longest_rows.clearRetainingCapacity();
                    try longest_rows.append(gpa, row);
                }
            }
            try testing.expect(std.mem.indexOfScalar(u32, longest_rows.items, actual.summary().longest_row) != null);
        }
    }
}

test "chunk bitmaps against reference" {
    for (0..200) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var buf: [chunk.max_base]u8 = undefined;
        var len: usize = 0;
        while (true) {
            const sample = try randomText(random, 1);
            defer gpa.free(sample);
            if (len + sample.len > chunk.max_base) break;
            @memcpy(buf[len..][0..sample.len], sample);
            len += sample.len;
        }
        const text = buf[0..len];
        const c = chunk.Chunk.new(text);
        const slice = c.asSlice();
        const summary = slice.textSummary();
        try testing.expect(summary.eql(TextSummary.fromStr(text)));
        for (0..len + 1) |offset| {
            if (!chunk.strIsCharBoundary(text, offset)) continue;
            const expected_point = TextSummary.fromStr(text[0..offset]).lines;
            try testing.expect(slice.offsetToPoint(offset).eql(expected_point));
            try testing.expectEqual(offset, slice.pointToOffset(expected_point));
            const units = TextSummary.fromStr(text[0..offset]).len_utf16;
            try testing.expectEqual(units.value, slice.offsetToOffsetUtf16(offset).value);
            try testing.expectEqual(offset, slice.offsetUtf16ToOffset(units));
        }
    }
}

test "replace and slice rows" {
    var rope = try Rope.fromStr(gpa, "one\ntwo\nthree\nfour");
    defer rope.deinit(gpa);
    try rope.replace(gpa, 4, 7, "TWO!");
    try expectText(&rope, "one\nTWO!\nthree\nfour");
    var rows = try rope.sliceRows(gpa, 1, 3);
    defer rows.deinit(gpa);
    try expectText(&rows, "TWO!\nthree\n");
    var chars = rope.reversedCharsAt(3);
    try testing.expectEqual(@as(?u21, 'e'), chars.next());
    try testing.expectEqual(@as(?u21, 'n'), chars.next());
}
