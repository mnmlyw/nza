//! DMA controller — 4 channels, used by ROMs to bulk-copy data into VRAM,
//! palette RAM, OAM, sound FIFOs, etc.
//!
//! Coverage in M1.4:
//!   - Immediate transfer (DMACNT_H start-timing = 00) — fired the moment the
//!     enable bit goes 0→1
//!   - VBlank and HBlank transfers — fired by the PPU at the right scanline
//!   - 16-bit and 32-bit word size
//!   - Source/dest increment / decrement / fixed
//!   - Repeat flag re-arming on VBlank/HBlank events
//!   - IRQ on completion (DMA0..3 sources)
//!
//! Deferred: Special timing (Sound FIFO + Video Capture), GamePak DRQ.

const std = @import("std");
const Bus = @import("../core/bus.zig").Bus;
const Io = @import("../core/io.zig").Io;
const Irq = @import("../irq/irq.zig").Irq;

pub const Timing = enum(u2) {
    immediate = 0,
    vblank = 1,
    hblank = 2,
    special = 3,
};

pub const Channel = struct {
    sad: u32 = 0, // internal latched source
    dad: u32 = 0, // internal latched dest
    count: u32 = 0, // internal latched word count
    cnt_h: u16 = 0, // control
    // Originals from the IO register set, captured on enable so repeat reloads.
    sad_latch: u32 = 0,
    dad_latch: u32 = 0,
    count_latch: u32 = 0,
    // Special-timing (sound FIFO) book-keeping: total words pulled since
    // last (re)load. Used to wrap SAD when repeat is set and the ring
    // buffer is exhausted.
    special_words_transferred: u32 = 0,
};

pub const Dma = struct {
    ch: [4]Channel = [_]Channel{.{}} ** 4,
    bus: *Bus,
    io: *Io,
    irq: *Irq,

    /// Called when DMAxCNT_H is written. Latches state if the enable bit
    /// transitioned 0→1, and immediately runs the transfer if timing=00.
    pub fn onCntWrite(self: *Dma, idx: u2, new_cnt: u16) void {
        const ch = &self.ch[idx];
        const was_enabled = (ch.cnt_h & 0x8000) != 0;
        const now_enabled = (new_cnt & 0x8000) != 0;
        ch.cnt_h = new_cnt;
        if (!was_enabled and now_enabled) {
            // Latch SAD/DAD/CNT from their IO bytes.
            const base = ioBase(idx);
            ch.sad_latch = readIo32(self.io, base);
            ch.dad_latch = readIo32(self.io, base + 4);
            const cnt_l: u16 = self.io.read(u16, base + 8);
            ch.sad = ch.sad_latch & sadMask(idx);
            ch.dad = ch.dad_latch & dadMask(idx);
            ch.count = countOf(idx, cnt_l);
            ch.count_latch = ch.count;
            ch.special_words_transferred = 0;
            if (timingOf(new_cnt) == .immediate) self.run(idx);
        }
    }

    /// Called by PPU at start of VBlank / HBlank to fire matching channels.
    pub fn onEvent(self: *Dma, ev: Timing) void {
        for ([_]u2{ 0, 1, 2, 3 }) |i| {
            const ch = &self.ch[i];
            if ((ch.cnt_h & 0x8000) == 0) continue;
            if (timingOf(ch.cnt_h) != ev) continue;
            self.run(i);
        }
    }

    /// Sound FIFO DMA: DMA1 → FIFO_A, DMA2 → FIFO_B. Called by Timer 0/1
    /// overflow when the FIFO needs a refill. Transfers 4 × u32 (16 bytes).
    /// Pokemon-style M4A: source is incremented through the mixer buffer
    /// and re-latched on each fresh enable (which Pokemon does every frame).
    pub fn onSoundFifo(self: *Dma, timer_idx: u2) void {
        _ = timer_idx;
        for ([_]u2{ 1, 2 }) |i| {
            const ch = &self.ch[i];
            if ((ch.cnt_h & 0x8000) == 0) continue;
            if (timingOf(ch.cnt_h) != .special) continue;
            var n: u32 = 0;
            while (n < 4) : (n += 1) {
                const v = self.bus.read(u32, ch.sad);
                self.bus.write(u32, ch.dad, v);
                ch.sad +%= 4;
            }
        }
    }

    fn run(self: *Dma, idx: u2) void {
        const ch = &self.ch[idx];
        const word32 = (ch.cnt_h & 0x0400) != 0;
        const word_size: u32 = if (word32) 4 else 2;
        const dst_ctrl: u2 = @intCast((ch.cnt_h >> 5) & 0x3);
        const src_ctrl: u2 = @intCast((ch.cnt_h >> 7) & 0x3);
        const repeat = (ch.cnt_h & 0x0200) != 0;
        const irq_on_done = (ch.cnt_h & 0x4000) != 0;

        var i: u32 = 0;
        while (i < ch.count) : (i += 1) {
            if (word32) {
                const v = self.bus.read(u32, ch.sad);
                self.bus.write(u32, ch.dad, v);
            } else {
                const v = self.bus.read(u16, ch.sad);
                self.bus.write(u16, ch.dad, v);
            }
            ch.sad = stepAddr(ch.sad, src_ctrl, word_size);
            ch.dad = stepAddr(ch.dad, dst_ctrl, word_size);
        }

        if (irq_on_done) self.irq.raise(switch (idx) {
            0 => .dma0,
            1 => .dma1,
            2 => .dma2,
            3 => .dma3,
        });

        // Reload for repeat, or disable.
        if (repeat and timingOf(ch.cnt_h) != .immediate) {
            ch.count = ch.count_latch;
            if (dst_ctrl == 3) ch.dad = ch.dad_latch & dadMask(idx);
        } else {
            ch.cnt_h &= ~@as(u16, 0x8000);
            // Also clear the visible bit so subsequent reads see 0 in bit 15.
            self.io.raw[ioBase(idx) + 10 + 1] &= 0x7F;
        }
    }
};

fn stepAddr(addr: u32, ctrl: u2, word_size: u32) u32 {
    return switch (ctrl) {
        0 => addr +% word_size, // increment
        1 => addr -% word_size, // decrement
        2 => addr, // fixed
        3 => addr +% word_size, // increment with reload (steps the same as 0)
    };
}

fn timingOf(cnt_h: u16) Timing {
    return @enumFromInt((cnt_h >> 12) & 0x3);
}

fn ioBase(idx: u2) u32 {
    return 0x0B0 + @as(u32, idx) * 12;
}

fn readIo32(io: *const Io, off: u32) u32 {
    return io.read(u32, off);
}

fn sadMask(idx: u2) u32 {
    // DMA0 source must be in internal memory (no GamePak); others 28 bits.
    return if (idx == 0) 0x07FF_FFFF else 0x0FFF_FFFF;
}

fn dadMask(idx: u2) u32 {
    // Only DMA3 can write to GamePak ROM (rare); others 27-bit dest.
    return if (idx == 3) 0x0FFF_FFFF else 0x07FF_FFFF;
}

fn countOf(idx: u2, cnt_l: u16) u32 {
    const default_max: u32 = if (idx == 3) 0x1_0000 else 0x4000;
    const n: u32 = cnt_l;
    return if (n == 0) default_max else (n & (default_max - 1));
}

test "DMA immediate 32-bit copy" {
    var bus: Bus = .{};
    var irq: Irq = .{};
    // Put a u32 in WRAM and DMA it to PRAM at offset 0.
    bus.write(u32, 0x0200_0100, 0xDEADBEEF);
    var dma = Dma{ .bus = &bus, .io = &bus.io, .irq = &irq };

    // Channel 3 (most permissive). Set SAD/DAD/COUNT via IO.
    bus.io.write(u32, 0x0D4, 0x0200_0100); // SAD3
    bus.io.write(u32, 0x0D8, 0x0500_0000); // DAD3 (palette RAM)
    bus.io.write(u16, 0x0DC, 1); // 1 word

    // CNT_H: type=word(0x0400), enable(0x8000), timing=immediate(00)
    dma.onCntWrite(3, 0x8400);

    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), bus.read(u32, 0x0500_0000));
}
