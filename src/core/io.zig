//! GBA MMIO register region (0x04000000 – 0x040003FE).
//!
//! Holds a flat 1 KB byte store as the default register backing and
//! delegates specific registers that have side effects (IRQ acknowledge,
//! halt, keypad, DISPSTAT etc.) to their owning subsystems.

const std = @import("std");
const Irq = @import("../irq/irq.zig").Irq;
const Keypad = @import("../keypad/keypad.zig").Keypad;
const Dma = @import("../dma/dma.zig").Dma;
const Timers = @import("../timer/timer.zig").Timers;
const Apu = @import("../apu/apu.zig").Apu;
const link_mod = @import("link.zig");

pub const SIZE: u32 = 0x400;

// Register offsets that need custom handling.
pub const REG_DISPCNT: u32 = 0x000;
pub const REG_DISPSTAT: u32 = 0x004;
pub const REG_VCOUNT: u32 = 0x006;
pub const REG_KEYINPUT: u32 = 0x130;
pub const REG_IE: u32 = 0x200;
pub const REG_IF: u32 = 0x202;
pub const REG_IME: u32 = 0x208;
pub const REG_HALTCNT: u32 = 0x301;
pub const REG_SIOCNT: u32 = 0x128;
pub const REG_SIOMULTI0: u32 = 0x120;

/// DMA CNT_H byte offsets (low byte). High byte = +1.
const DMA_CNT_H_OFFSETS: [4]u32 = .{ 0x0BA, 0x0C6, 0x0D2, 0x0DE };

/// Timer CNT_H low-byte offsets.
const TIMER_CNT_H_OFFSETS: [4]u32 = .{ 0x102, 0x106, 0x10A, 0x10E };

/// Timer CNT_L offsets (16-bit counter). Reads need to go through Timers
/// for the live counter; raw IO bytes only hold the latched reload value.
const TIMER_CNT_L_OFFSETS: [4]u32 = .{ 0x100, 0x104, 0x108, 0x10C };

pub const Io = struct {
    raw: [SIZE]u8 = std.mem.zeroes([SIZE]u8),

    // Cross-subsystem refs. Set up by `Core.init`.
    irq: ?*Irq = null,
    keypad: ?*Keypad = null,
    dma: ?*Dma = null,
    timers: ?*Timers = null,
    apu: ?*Apu = null,
    link: ?*link_mod.Link = null,

    /// DISPSTAT bits: 0=VBlank flag, 1=HBlank flag, 2=VCount match,
    /// 3=VBlank IRQ enable, 4=HBlank IRQ enable, 5=VCount IRQ enable,
    /// 8..15=VCount setting (line to fire VCount IRQ on).
    dispstat: u16 = 0,
    vcount: u16 = 0,

    pub fn read(self: *const Io, comptime T: type, offset: u32) T {
        comptime checkType(T);
        return switch (T) {
            u8 => self.read8(offset),
            u16 => @as(u16, self.read8(offset)) | (@as(u16, self.read8(offset + 1)) << 8),
            u32 => @as(u32, self.read8(offset)) |
                (@as(u32, self.read8(offset + 1)) << 8) |
                (@as(u32, self.read8(offset + 2)) << 16) |
                (@as(u32, self.read8(offset + 3)) << 24),
            else => unreachable,
        };
    }

    pub fn write(self: *Io, comptime T: type, offset: u32, value: T) void {
        comptime checkType(T);
        switch (T) {
            u8 => self.write8(offset, value),
            u16 => {
                self.write8(offset, @truncate(value));
                self.write8(offset + 1, @truncate(value >> 8));
            },
            u32 => {
                self.write8(offset, @truncate(value));
                self.write8(offset + 1, @truncate(value >> 8));
                self.write8(offset + 2, @truncate(value >> 16));
                self.write8(offset + 3, @truncate(value >> 24));
            },
            else => unreachable,
        }
    }

    fn read8(self: *const Io, offset_in: u32) u8 {
        const offset = offset_in & (SIZE - 1);
        return switch (offset) {
            REG_DISPSTAT => @truncate(self.dispstat),
            REG_DISPSTAT + 1 => @truncate(self.dispstat >> 8),
            REG_VCOUNT => @truncate(self.vcount),
            REG_VCOUNT + 1 => @truncate(self.vcount >> 8),
            REG_KEYINPUT => if (self.keypad) |k| @as(u8, @truncate(k.keyinput)) else 0xFF,
            REG_KEYINPUT + 1 => if (self.keypad) |k| @as(u8, @truncate(k.keyinput >> 8)) else 0x03,
            REG_IE => if (self.irq) |x| @as(u8, @truncate(x.ie)) else 0,
            REG_IE + 1 => if (self.irq) |x| @as(u8, @truncate(x.ie >> 8)) else 0,
            REG_IF => if (self.irq) |x| @as(u8, @truncate(x.irq_flags)) else 0,
            REG_IF + 1 => if (self.irq) |x| @as(u8, @truncate(x.irq_flags >> 8)) else 0,
            REG_IME => if (self.irq) |x| (if (x.ime) @as(u8, 1) else 0) else 0,
            else => blk: {
                // Timer counter live reads — return the running counter, not
                // the latched reload value sitting in raw bytes.
                if (self.timers) |t| {
                    inline for (TIMER_CNT_L_OFFSETS, 0..) |cnt_l, ch_idx| {
                        if (offset == cnt_l) {
                            const v = t.read(@intCast(ch_idx));
                            break :blk @as(u8, @truncate(v));
                        }
                        if (offset == cnt_l + 1) {
                            const v = t.read(@intCast(ch_idx));
                            break :blk @as(u8, @truncate(v >> 8));
                        }
                    }
                }
                break :blk self.raw[offset];
            },
        };
    }

    fn write8(self: *Io, offset_in: u32, value: u8) void {
        const offset = offset_in & (SIZE - 1);
        switch (offset) {
            REG_DISPSTAT => {
                // Lower byte: bits 0..2 are read-only PPU flags; only 3..7 writable.
                self.dispstat = (self.dispstat & 0xFF07) | (@as(u16, value & 0xF8));
            },
            REG_DISPSTAT + 1 => {
                self.dispstat = (self.dispstat & 0x00FF) | (@as(u16, value) << 8);
            },
            REG_VCOUNT, REG_VCOUNT + 1 => {}, // read-only
            REG_KEYINPUT, REG_KEYINPUT + 1 => {}, // read-only
            REG_IE => if (self.irq) |x| {
                x.ie = (x.ie & 0xFF00) | value;
            },
            REG_IE + 1 => if (self.irq) |x| {
                x.ie = (x.ie & 0x00FF) | (@as(u16, value) << 8);
            },
            REG_IF => if (self.irq) |x| {
                // Write 1 to clear.
                x.irq_flags &= ~@as(u16, value);
            },
            REG_IF + 1 => if (self.irq) |x| {
                x.irq_flags &= ~(@as(u16, value) << 8);
            },
            REG_IME => if (self.irq) |x| {
                x.ime = (value & 1) != 0;
            },
            REG_HALTCNT => if (self.irq) |x| {
                if ((value & 0x80) == 0) x.halted = true; // stop-mode bit cleared = HALT
            },
            else => {
                self.raw[offset] = value;
                // SIO single-player stub: on SIOCNT high-byte (0x129) write,
                // if the start bit (bit 15) is set, simulate immediate
                // transfer completion. Multi-mode reads of SIOMULTI0..3
                // return 0xFFFF (no link partner). Raise SIO IRQ if enabled.
                //
                // This also covers GBA Wireless Adapter detection (used by
                // Pokémon FireRed/LeafGreen and Mario Tennis): the game
                // sends Normal-32 packets and reads SIODATA32 (= bytes at
                // 0x120-0x123). Our default-fill of 0xFFFF means the game
                // sees 0xFFFFFFFF, treats that as "no adapter present,"
                // and falls back to single-player.
                if (offset == REG_SIOCNT + 1) {
                    if ((value & 0x80) != 0) {
                        // Clear start bit; transfer "done".
                        self.raw[REG_SIOCNT + 1] = value & 0x7F;
                        // Default SIOMULTI0..3 to 0xFFFF (absent peers).
                        for (0..8) |i| self.raw[REG_SIOMULTI0 + i] = 0xFF;
                        if (self.link) |lk| if (lk.isConnected()) {
                            // Exchange Multi-mode value with the peer.
                            const my_value: u16 = @as(u16, self.raw[REG_SIOMULTI0 + 8]) | (@as(u16, self.raw[REG_SIOMULTI0 + 9]) << 8);
                            lk.sendValue(my_value);
                            _ = lk.poll();
                            // Host = slot 0, client = slot 1.
                            const my_slot: u32 = if (lk.role == .host) 0 else 1;
                            const peer_slot: u32 = 1 - my_slot;
                            self.raw[REG_SIOMULTI0 + my_slot * 2] = @truncate(my_value);
                            self.raw[REG_SIOMULTI0 + my_slot * 2 + 1] = @truncate(my_value >> 8);
                            self.raw[REG_SIOMULTI0 + peer_slot * 2] = @truncate(lk.peer_value);
                            self.raw[REG_SIOMULTI0 + peer_slot * 2 + 1] = @truncate(lk.peer_value >> 8);
                        };
                        // IRQ on completion if SIOCNT bit 14 is set.
                        if ((value & 0x40) != 0) {
                            if (self.irq) |x| x.raise(.serial);
                        }
                    }
                }
                // FIFO_A (0x0A0..0x0A3) and FIFO_B (0x0A4..0x0A7) push
                // 8-bit signed samples into the APU FIFOs.
                if (self.apu) |apu| {
                    if (offset >= 0x0A0 and offset <= 0x0A3) {
                        apu.writeFifoA(value);
                    } else if (offset >= 0x0A4 and offset <= 0x0A7) {
                        apu.writeFifoB(value);
                    } else if (offset == 0x082 or offset == 0x083) {
                        const new_cnt_h: u16 = @as(u16, self.raw[0x082]) | (@as(u16, self.raw[0x083]) << 8);
                        apu.onSoundCntHWrite(new_cnt_h);
                    } else if (offset == 0x084) {
                        if ((value & 0x80) == 0) apu.onSoundDisable();
                    } else if ((offset >= 0x060 and offset <= 0x07F) or
                        (offset >= 0x090 and offset <= 0x09F))
                    {
                        apu.onPsgWrite(offset);
                    }
                }
                // DMA CNT_H high-byte writes are what start the transfer (the
                // enable bit lives there). React after the byte is stored.
                if (self.dma) |d| {
                    inline for (DMA_CNT_H_OFFSETS, 0..) |cnt_h_lo, ch_idx| {
                        if (offset == cnt_h_lo + 1) {
                            const cnt_h: u16 = @as(u16, self.raw[cnt_h_lo]) | (@as(u16, value) << 8);
                            d.onCntWrite(@intCast(ch_idx), cnt_h);
                        }
                    }
                }
                // Timer CNT_H low-byte writes hold the enable bit.
                if (self.timers) |t| {
                    inline for (TIMER_CNT_H_OFFSETS, 0..) |cnt_h_lo, ch_idx| {
                        if (offset == cnt_h_lo) {
                            t.onCntWrite(@intCast(ch_idx), value);
                        }
                    }
                }
            },
        }
    }
};

fn checkType(comptime T: type) void {
    const bits = @typeInfo(T).int.bits;
    if (bits != 8 and bits != 16 and bits != 32) {
        @compileError("Io read/write requires u8, u16, or u32");
    }
}

test "io round-trip 8/16/32 in raw region" {
    var io: Io = .{};
    io.write(u16, 0x100, 0xBEEF); // non-special offset
    try std.testing.expectEqual(@as(u16, 0xBEEF), io.read(u16, 0x100));
}

test "IF write-1-to-clear via io path" {
    var irq_state = Irq{};
    irq_state.irq_flags = 0xFF;
    var io: Io = .{ .irq = &irq_state };
    io.write(u16, REG_IF, 0x0005);
    try std.testing.expectEqual(@as(u16, 0xFA), irq_state.irq_flags);
}

test "KEYINPUT read reflects keypad" {
    var kp: Keypad = .{};
    var io: Io = .{ .keypad = &kp };
    try std.testing.expectEqual(@as(u16, 0x3FF), io.read(u16, REG_KEYINPUT));
    kp.press(.start);
    try std.testing.expectEqual(@as(u16, 0x3FF & ~@as(u16, 1 << 3)), io.read(u16, REG_KEYINPUT));
}
