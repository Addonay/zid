//! Port of Zed's `text::{Topic, Subscription}` (`.ref/zed/crates/text/src/subscription.rs`).
//! Each subscription accumulates the composition of every published patch until it is
//! consumed. Subscriptions are reference counted between the topic and the subscriber.
const std = @import("std");
const Allocator = std.mem.Allocator;
const patch_mod = @import("patch.zig");

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

pub fn Subscription(comptime T: type) type {
    return struct {
        const Self = @This();
        const P = patch_mod.Patch(T);

        ref_count: std.atomic.Value(u32) = .init(2),
        /// Guards `patch`; held only while composing or taking it.
        mutex: std.atomic.Mutex = .unlocked,
        patch: P = .empty,

        /// Takes the accumulated patch; the caller owns it.
        pub fn consume(self: *Self) P {
            lock(&self.mutex);
            defer self.mutex.unlock();
            const result = self.patch;
            self.patch = .empty;
            return result;
        }

        /// Drops the subscriber's reference (Zed drops the `Arc`).
        pub fn release(self: *Self, gpa: Allocator) void {
            if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
                self.patch.deinit(gpa);
                gpa.destroy(self);
            }
        }
    };
}

pub fn Topic(comptime T: type) type {
    return struct {
        const Self = @This();
        const Sub = Subscription(T);

        subscriptions: std.ArrayList(*Sub) = .empty,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.subscriptions.items) |subscription| subscription.release(gpa);
            self.subscriptions.deinit(gpa);
        }

        pub fn subscribe(self: *Self, gpa: Allocator) Allocator.Error!*Sub {
            const subscription = try gpa.create(Sub);
            subscription.* = .{};
            self.subscriptions.append(gpa, subscription) catch |err| {
                gpa.destroy(subscription);
                return err;
            };
            return subscription;
        }

        /// Composes `edits` into every live subscription, dropping released ones.
        pub fn publish(self: *Self, gpa: Allocator, edits: []const patch_mod.Edit(T)) Allocator.Error!void {
            var write: usize = 0;
            for (self.subscriptions.items) |subscription| {
                if (subscription.ref_count.load(.acquire) == 1) {
                    subscription.release(gpa);
                    continue;
                }
                lock(&subscription.mutex);
                defer subscription.mutex.unlock();
                const composed = try subscription.patch.compose(gpa, edits);
                subscription.patch.deinit(gpa);
                subscription.patch = composed;
                self.subscriptions.items[write] = subscription;
                write += 1;
            }
            self.subscriptions.items.len = write;
        }
    };
}

const testing = std.testing;

test "topic publishes composed patches" {
    const gpa = testing.allocator;
    var topic: Topic(usize) = .{};
    defer topic.deinit(gpa);
    const first = try topic.subscribe(gpa);
    try topic.publish(gpa, &.{.{ .old = .{ .start = 1, .end = 3 }, .new = .{ .start = 1, .end = 4 } }});
    const second = try topic.subscribe(gpa);
    try topic.publish(gpa, &.{.{ .old = .{ .start = 0, .end = 0 }, .new = .{ .start = 0, .end = 4 } }});

    var a = first.consume();
    defer a.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), a.edits().len);
    var b = second.consume();
    defer b.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), b.edits().len);

    first.release(gpa);
    try topic.publish(gpa, &.{.{ .old = .{ .start = 0, .end = 1 }, .new = .{ .start = 0, .end = 0 } }});
    try testing.expectEqual(@as(usize, 1), topic.subscriptions.items.len);
    second.release(gpa);
}
