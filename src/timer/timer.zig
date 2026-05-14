//! Timer controller — 4 × 16-bit timers with prescalers and cascade.
//!
//! M1.4 coverage:
//!   - Standalone (prescaler) and cascade modes
//!   - IRQ on overflow
//!   - Schedule-driven: overflow time is computed when the timer starts or
//!     reloads, then a single scheduler event fires it
//!
//! Deferred: precise mid-frame reads (we recompute on read, which is good
//! enough for IRQ-driven games).

const std = @import("std");
const scheduler_mod = @import("../core/scheduler.zig");
const Scheduler = scheduler_mod.Scheduler;
const Io = @import("../core/io.zig").Io;
const Irq = @import("../irq/irq.zig").Irq;
const Dma = @import("../dma/dma.zig").Dma;
const Apu = @import("../apu/apu.zig").Apu;

const PRESCALER_SHIFTS: [4]u6 = .{ 0, 6, 8, 10 }; // /1, /64, /256, /1024

pub const TAG_BASE: u32 = 0x2000;

pub const Timer = struct {
    reload: u16 = 0,
    counter: u16 = 0,
    cnt: u8 = 0,
    start_time: u64 = 0,
    enabled: bool = false,
};

pub const Timers = struct {
    t: [4]Timer = [_]Timer{.{}} ** 4,
    sched: *Scheduler,
    io: *Io,
    irq: *Irq,
    dma: ?*Dma = null,
    apu: ?*Apu = null,

    pub fn onCntWrite(self: *Timers, idx: u2, new_cnt: u8) void {
        const t = &self.t[idx];
        const was_enabled = (t.cnt & 0x80) != 0;
        const now_enabled = (new_cnt & 0x80) != 0;
        t.cnt = new_cnt;

        if (!was_enabled and now_enabled) {
            t.reload = reloadRaw(self.io, idx);
            t.counter = t.reload;
            t.start_time = self.sched.now();
            t.enabled = true;
            self.scheduleOverflow(idx);
        } else if (was_enabled and !now_enabled) {
            self.sched.cancel(TAG_BASE + idx);
            t.enabled = false;
        }
    }

    pub fn read(self: *Timers, idx: u2) u16 {
        const t = &self.t[idx];
        if (!t.enabled) return t.counter;
        if (isCascade(t, idx)) return t.counter;
        const shift = PRESCALER_SHIFTS[t.cnt & 0x03];
        const elapsed = self.sched.now() - t.start_time;
        const ticks = elapsed >> shift;
        const span: u32 = @as(u32, 0x10000) - @as(u32, t.reload);
        if (ticks < span) {
            return @intCast(@as(u32, t.reload) + @as(u32, @intCast(ticks)));
        }
        return t.reload;
    }

    fn scheduleOverflow(self: *Timers, idx: u2) void {
        const t = &self.t[idx];
        if (isCascade(t, idx)) return; // ticks only from the previous timer.
        // Re-read the reload value: games (e.g. Pokemon Emerald) sometimes
        // write CNT_H enable *before* CNT_L reload, so a stale latched
        // reload would yield the wrong overflow period. Read from raw IO
        // bytes — io.read(0x100) is intercepted to return the live counter.
        t.reload = reloadRaw(self.io, idx);
        const shift = PRESCALER_SHIFTS[t.cnt & 0x03];
        const span: u64 = (@as(u64, 0x10000) - @as(u64, t.reload)) << shift;
        const handler: scheduler_mod.EventHandler = switch (idx) {
            0 => onOverflow0,
            1 => onOverflow1,
            2 => onOverflow2,
            3 => onOverflow3,
        };
        self.sched.schedule(span, handler, self, TAG_BASE + idx);
    }

    fn fireOverflow(self: *Timers, idx: u2) void {
        const t = &self.t[idx];
        // Counter wraps to reload value.
        t.counter = t.reload;
        t.start_time = self.sched.now();

        if ((t.cnt & 0x40) != 0) self.irq.raise(switch (idx) {
            0 => .timer0,
            1 => .timer1,
            2 => .timer2,
            3 => .timer3,
        });

        // Timer 0/1 overflow drives sound FIFO: APU consumes one sample
        // from the matching FIFO; DMA refills the FIFO when it's drained
        // below half.
        if (idx <= 1) {
            if (self.apu) |a| a.onTimerOverflow(idx);
            if (self.apu) |a| {
                if (self.dma) |d| {
                    if (a.needsRefillA() or a.needsRefillB()) d.onSoundFifo(idx);
                }
            } else if (self.dma) |d| d.onSoundFifo(idx);
        }

        // Cascade the next timer (if it's enabled and in cascade mode).
        if (idx < 3) {
            const next: u2 = @intCast(@as(u3, idx) + 1);
            const nt = &self.t[next];
            if (nt.enabled and isCascade(nt, next)) {
                if (nt.counter == 0xFFFF) {
                    self.fireOverflow(next);
                } else {
                    nt.counter += 1;
                }
            }
        }

        // Reschedule self.
        self.scheduleOverflow(idx);
    }

    pub fn onOverflow0(ctx: *anyopaque, late: u64) void {
        _ = late;
        const self: *Timers = @ptrCast(@alignCast(ctx));
        self.fireOverflow(0);
    }
    pub fn onOverflow1(ctx: *anyopaque, late: u64) void {
        _ = late;
        const self: *Timers = @ptrCast(@alignCast(ctx));
        self.fireOverflow(1);
    }
    pub fn onOverflow2(ctx: *anyopaque, late: u64) void {
        _ = late;
        const self: *Timers = @ptrCast(@alignCast(ctx));
        self.fireOverflow(2);
    }
    pub fn onOverflow3(ctx: *anyopaque, late: u64) void {
        _ = late;
        const self: *Timers = @ptrCast(@alignCast(ctx));
        self.fireOverflow(3);
    }
};

inline fn isCascade(t: *const Timer, idx: u2) bool {
    return idx > 0 and (t.cnt & 0x04) != 0;
}

fn ioBase(idx: u2) u32 {
    return 0x100 + @as(u32, idx) * 4;
}

/// Read the *latched* reload value (TMxCNT_L low+high bytes) directly
/// from raw IO bytes, bypassing `io.read` which is intercepted to return
/// the live counter for these offsets.
fn reloadRaw(io: *const Io, idx: u2) u16 {
    const off = ioBase(idx);
    return @as(u16, io.raw[off]) | (@as(u16, io.raw[off + 1]) << 8);
}

test "timer overflow at /1 prescaler" {
    var sched: Scheduler = .{};
    var io: Io = .{};
    var irq: Irq = .{};
    var tmrs = Timers{ .sched = &sched, .io = &io, .irq = &irq };

    // Set reload = 0xFFFE, IRQ on overflow, enable, /1 prescaler.
    io.write(u16, 0x100, 0xFFFE);
    tmrs.onCntWrite(0, 0xC0); // bit7 enable, bit6 IRQ enable

    // 0xFFFF → 0x10000 → overflow takes 2 cycles at /1 prescaler.
    sched.addCycles(2);
    try std.testing.expect((irq.irq_flags & (1 << 3)) != 0); // Timer0 IRQ bit
}
