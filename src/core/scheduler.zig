//! Event-driven scheduler — the heartbeat of cycle-accurate emulation.
//!
//! Subsystems register a callback with a future timestamp. The CPU loop calls
//! `addCycles(n)` after every instruction batch; that advances the master
//! clock and fires every event whose timestamp has passed (in order, ties
//! broken by insertion).
//!
//! Design ported from NanoBoyAdvance's `nba/include/nba/scheduler.hh`. Two
//! deliberate simplifications vs. NBA for milestone 1:
//!   * No event-class enum / save-state serialization. Events identify
//!     themselves by an opaque `tag: u32` for cancellation.
//!   * Cancellation is lazy: `cancel(tag)` marks the event; it's skipped when
//!     popped. Avoids re-heapifying.

const std = @import("std");

pub const CAPACITY = 256;

pub const EventHandler = *const fn (ctx: *anyopaque, late_cycles: u64) void;

pub const Event = struct {
    timestamp: u64,
    handler: EventHandler,
    context: *anyopaque,
    tag: u32,
    cancelled: bool,
};

pub const Scheduler = struct {
    timestamp: u64 = 0,
    events: [CAPACITY]Event = undefined,
    len: usize = 0,

    pub fn now(self: *const Scheduler) u64 {
        return self.timestamp;
    }

    pub fn schedule(
        self: *Scheduler,
        delta_cycles: u64,
        handler: EventHandler,
        context: *anyopaque,
        tag: u32,
    ) void {
        std.debug.assert(self.len < CAPACITY);
        self.events[self.len] = .{
            .timestamp = self.timestamp + delta_cycles,
            .handler = handler,
            .context = context,
            .tag = tag,
            .cancelled = false,
        };
        self.len += 1;
        self.siftUp(self.len - 1);
    }

    /// Remove every event with the matching tag from the heap. This is an
    /// O(n) scan with re-heapify per removal — fine for n=256 and games
    /// that churn timer enable/disable each frame would otherwise leak
    /// "lazy-cancelled" slots until the original timestamp passed.
    pub fn cancel(self: *Scheduler, tag: u32) void {
        var i: usize = 0;
        while (i < self.len) {
            if (self.events[i].tag != tag) {
                i += 1;
                continue;
            }
            self.len -= 1;
            if (i == self.len) break;
            self.events[i] = self.events[self.len];
            // The moved event might violate heap order in either direction.
            if (i > 0 and self.events[(i - 1) / 2].timestamp > self.events[i].timestamp) {
                self.siftUp(i);
            } else {
                self.siftDown(i);
            }
            // Re-check slot i (now holds a different event).
        }
    }

    /// Advance the master clock by `cycles` and fire every event whose
    /// timestamp is now in the past.
    pub fn addCycles(self: *Scheduler, cycles: u64) void {
        self.timestamp += cycles;
        while (self.len > 0 and self.events[0].timestamp <= self.timestamp) {
            const e = self.popMin();
            if (e.cancelled) continue;
            const late = self.timestamp - e.timestamp;
            e.handler(e.context, late);
        }
    }

    fn popMin(self: *Scheduler) Event {
        const top = self.events[0];
        self.len -= 1;
        if (self.len > 0) {
            self.events[0] = self.events[self.len];
            self.siftDown(0);
        }
        return top;
    }

    fn siftUp(self: *Scheduler, start: usize) void {
        var i = start;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (self.events[parent].timestamp <= self.events[i].timestamp) break;
            std.mem.swap(Event, &self.events[parent], &self.events[i]);
            i = parent;
        }
    }

    fn siftDown(self: *Scheduler, start: usize) void {
        var i = start;
        while (true) {
            const left = 2 * i + 1;
            const right = 2 * i + 2;
            var smallest = i;
            if (left < self.len and
                self.events[left].timestamp < self.events[smallest].timestamp) smallest = left;
            if (right < self.len and
                self.events[right].timestamp < self.events[smallest].timestamp) smallest = right;
            if (smallest == i) break;
            std.mem.swap(Event, &self.events[i], &self.events[smallest]);
            i = smallest;
        }
    }
};

// ---- tests ----

const Tagged = struct {
    out: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
    tag: u32,

    fn handler(ctx: *anyopaque, late: u64) void {
        _ = late;
        const self: *Tagged = @ptrCast(@alignCast(ctx));
        self.out.append(self.allocator, self.tag) catch unreachable;
    }
};

test "scheduler fires events in timestamp order" {
    var sched = Scheduler{};
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);

    var a = Tagged{ .out = &out, .allocator = std.testing.allocator, .tag = 10 };
    var b = Tagged{ .out = &out, .allocator = std.testing.allocator, .tag = 20 };
    var c = Tagged{ .out = &out, .allocator = std.testing.allocator, .tag = 30 };

    // Schedule out of order: 30 @ t=5, 10 @ t=1, 20 @ t=3
    sched.schedule(5, Tagged.handler, &c, c.tag);
    sched.schedule(1, Tagged.handler, &a, a.tag);
    sched.schedule(3, Tagged.handler, &b, b.tag);

    sched.addCycles(10);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, out.items);
    try std.testing.expectEqual(@as(u64, 10), sched.now());
}

test "scheduler only fires events with timestamp <= now" {
    var sched = Scheduler{};
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);

    var a = Tagged{ .out = &out, .allocator = std.testing.allocator, .tag = 1 };
    var b = Tagged{ .out = &out, .allocator = std.testing.allocator, .tag = 2 };

    sched.schedule(5, Tagged.handler, &a, a.tag);
    sched.schedule(20, Tagged.handler, &b, b.tag);

    sched.addCycles(10);
    try std.testing.expectEqualSlices(u32, &.{1}, out.items);
    sched.addCycles(15);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, out.items);
}

test "scheduler cancel skips matching events" {
    var sched = Scheduler{};
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);

    var a = Tagged{ .out = &out, .allocator = std.testing.allocator, .tag = 7 };
    var b = Tagged{ .out = &out, .allocator = std.testing.allocator, .tag = 9 };

    sched.schedule(2, Tagged.handler, &a, a.tag);
    sched.schedule(4, Tagged.handler, &b, b.tag);
    sched.cancel(7);

    sched.addCycles(10);
    try std.testing.expectEqualSlices(u32, &.{9}, out.items);
}
