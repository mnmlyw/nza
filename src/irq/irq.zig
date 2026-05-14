//! Interrupt controller — IE, IF, IME registers and CPU IRQ injection.
//!
//! Bit assignments (per GBATEK):
//!   0  VBlank
//!   1  HBlank
//!   2  VCount match
//!   3..6  Timer 0..3 overflow
//!   7  Serial communication
//!   8..11 DMA 0..3
//!   12 Keypad
//!   13 Game Pak (external IRQ via /GPIO)

const std = @import("std");

pub const Source = enum(u4) {
    vblank = 0,
    hblank = 1,
    vcount = 2,
    timer0 = 3,
    timer1 = 4,
    timer2 = 5,
    timer3 = 6,
    serial = 7,
    dma0 = 8,
    dma1 = 9,
    dma2 = 10,
    dma3 = 11,
    keypad = 12,
    cart = 13,
};

pub const Irq = struct {
    ie: u16 = 0,
    irq_flags: u16 = 0,
    ime: bool = false,

    /// Set when the CPU is halted via SWI 0x02 or HALTCNT and should resume
    /// the next time `pending()` becomes non-zero.
    halted: bool = false,

    /// Raise an interrupt request from a peripheral.
    pub fn raise(self: *Irq, src: Source) void {
        self.irq_flags |= @as(u16, 1) << @intFromEnum(src);
        // Halt clears the moment any flag is set (regardless of IE/IME).
        if (self.halted) self.halted = false;
    }

    /// Acknowledge a flag (writing 1 to IF clears that bit).
    pub fn acknowledge(self: *Irq, bits: u16) void {
        self.irq_flags &= ~bits;
    }

    /// Returns non-zero if an IRQ should be taken.
    pub fn pending(self: *const Irq) u16 {
        return self.ie & self.irq_flags;
    }
};

test "raise and acknowledge" {
    var irq = Irq{};
    irq.ie = 0x0001; // enable VBlank
    irq.ime = true;
    try std.testing.expect(irq.pending() == 0);
    irq.raise(.vblank);
    try std.testing.expect(irq.pending() != 0);
    irq.acknowledge(0x0001);
    try std.testing.expect(irq.pending() == 0);
}

test "halt clears on any raise even with IE=0" {
    var irq = Irq{};
    irq.halted = true;
    irq.raise(.vblank);
    try std.testing.expect(!irq.halted);
}
