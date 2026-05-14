//! GBA memory bus.
//!
//! Maps the 32-bit address space to physical memory regions per GBATEK:
//!
//!   0x00000000 – 0x00003FFF   BIOS ROM           (16 KB)
//!   0x02000000 – 0x0203FFFF   EWRAM              (256 KB, mirrored within 0x02)
//!   0x03000000 – 0x03007FFF   IWRAM              (32 KB, mirrored within 0x03)
//!   0x04000000 – 0x040003FE   I/O registers
//!   0x05000000 – 0x050003FF   Palette RAM        (1 KB, mirrored)
//!   0x06000000 – 0x06017FFF   VRAM               (96 KB, weird mirror)
//!   0x07000000 – 0x070003FF   OAM                (1 KB, mirrored)
//!   0x08000000 – 0x09FFFFFF   Game Pak ROM #0    (waitstate 0)
//!   0x0A000000 – 0x0BFFFFFF   Game Pak ROM #1    (waitstate 1)
//!   0x0C000000 – 0x0DFFFFFF   Game Pak ROM #2    (waitstate 2)
//!   0x0E000000 – 0x0E00FFFF   Game Pak SRAM      (64 KB)
//!
//! M1.1 status:
//!   * All read/write paths dispatch by region.
//!   * Waitstates are not yet applied (CPU lands in M1.2; we'll plug them in).
//!   * Unaligned reads do NOT yet rotate (GBA bus rotates 16-bit and 32-bit
//!     reads by `(addr & mask) * 8` bits); we assume aligned access from the
//!     CPU. The PPU and DMA only emit aligned accesses, so this is safe for
//!     the skeleton.
//!   * Open-bus returns zero. NBA returns the last code fetch + variant on
//!     bus type; we'll add that when the CPU pipeline lands.

const std = @import("std");
const io_mod = @import("io.zig");
const flash_mod = @import("flash.zig");

pub const BIOS_SIZE: u32 = 0x4000;
pub const WRAM_SIZE: u32 = 0x40000;
pub const IRAM_SIZE: u32 = 0x8000;
pub const PRAM_SIZE: u32 = 0x400;
pub const VRAM_SIZE: u32 = 0x18000;
pub const OAM_SIZE: u32 = 0x400;
pub const SRAM_SIZE: u32 = 0x10000;
pub const FLASH128_SIZE: u32 = 0x20000;
pub const ROM_MAX_SIZE: u32 = 0x02000000; // 32 MB per bank, three banks total

pub const Bus = struct {
    bios: [BIOS_SIZE]u8 = std.mem.zeroes([BIOS_SIZE]u8),
    wram: [WRAM_SIZE]u8 = std.mem.zeroes([WRAM_SIZE]u8),
    iram: [IRAM_SIZE]u8 = std.mem.zeroes([IRAM_SIZE]u8),
    pram: [PRAM_SIZE]u8 = std.mem.zeroes([PRAM_SIZE]u8),
    vram: [VRAM_SIZE]u8 = std.mem.zeroes([VRAM_SIZE]u8),
    oam: [OAM_SIZE]u8 = std.mem.zeroes([OAM_SIZE]u8),
    sram: [SRAM_SIZE]u8 = std.mem.zeroes([SRAM_SIZE]u8),
    flash_data: [FLASH128_SIZE]u8 = [_]u8{0xFF} ** FLASH128_SIZE,
    flash: ?flash_mod.Flash = null,
    rom: []const u8 = &.{},
    gpio_enabled: bool = false,

    io: io_mod.Io = .{},

    /// Last code fetch, used as the open-bus value once the CPU pipeline is
    /// in. Today it's just zero.
    last_code_fetch: u32 = 0,

    pub fn read(self: *Bus, comptime T: type, addr: u32) T {
        comptime checkType(T);
        const region = (addr >> 24) & 0xF;
        return switch (region) {
            0x0 => if ((addr & 0xFFFF_FFFF) < 0x4000)
                readSlice(T, self.bios[0..], addr & 0x3FFF)
            else
                openBus(T, self.last_code_fetch, addr),
            0x1 => openBus(T, self.last_code_fetch, addr),
            0x2 => readSlice(T, self.wram[0..], addr & (WRAM_SIZE - 1)),
            0x3 => readSlice(T, self.iram[0..], addr & (IRAM_SIZE - 1)),
            0x4 => self.io.read(T, addr & 0x3FF),
            0x5 => readSlice(T, self.pram[0..], addr & (PRAM_SIZE - 1)),
            0x6 => readSlice(T, self.vram[0..], vramAddr(addr)),
            0x7 => readSlice(T, self.oam[0..], addr & (OAM_SIZE - 1)),
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.readRom(T, addr & 0x01FF_FFFF),
            0xE, 0xF => self.readBackup(T, addr & (SRAM_SIZE - 1)),
            else => openBus(T, self.last_code_fetch, addr),
        };
    }

    pub fn write(self: *Bus, comptime T: type, addr: u32, value: T) void {
        comptime checkType(T);
        const region = (addr >> 24) & 0xF;
        switch (region) {
            0x0 => {}, // BIOS is read-only
            0x2 => writeSlice(T, self.wram[0..], addr & (WRAM_SIZE - 1), value),
            0x3 => writeSlice(T, self.iram[0..], addr & (IRAM_SIZE - 1), value),
            0x4 => self.io.write(T, addr & 0x3FF, value),
            0x5 => writeSlice(T, self.pram[0..], addr & (PRAM_SIZE - 1), value),
            0x6 => writeSlice(T, self.vram[0..], vramAddr(addr), value),
            0x7 => writeSlice(T, self.oam[0..], addr & (OAM_SIZE - 1), value),
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => {
                // Cart GPIO control: bit 0 of byte at 0x080000C8 toggles
                // GPIO read-back mode. Pokemon Emerald enables this to read
                // its RTC chip; we don't model RTC, just enable the gating.
                const rom_addr = addr & 0x01FF_FFFF;
                if (rom_addr == 0xC8) {
                    self.gpio_enabled = (@as(u32, @intCast(value)) & 1) != 0;
                }
            },
            0xE, 0xF => self.writeBackup(T, addr & (SRAM_SIZE - 1), value),
            else => {},
        }
    }

    fn readRom(self: *Bus, comptime T: type, rom_addr: u32) T {
        // Cart GPIO (RTC etc.) sits in ROM-space at 0x080000C4..0xC9. When
        // a game enables GPIO read mode by writing to 0x080000C8 control,
        // reads here return GPIO data; otherwise they pass through to ROM.
        // We don't model GPIO/RTC: return 0 for the data port so Pokemon
        // Emerald sees "RTC stuck low" and falls back to no-RTC handling
        // rather than reading garbage ROM bytes.
        if (self.gpio_enabled and rom_addr >= 0xC4 and rom_addr <= 0xC9) {
            return 0;
        }
        if (rom_addr + (@typeInfo(T).int.bits / 8) <= self.rom.len) {
            return readSlice(T, self.rom, rom_addr);
        }
        return openBus(T, self.last_code_fetch, rom_addr);
    }

    /// Open-bus pattern: real GBA returns the last code fetch on the
    /// system bus. Used for invalid/unmapped reads.
    fn openBus(comptime T: type, last_fetch: u32, addr: u32) T {
        _ = addr;
        return switch (@typeInfo(T).int.bits) {
            8 => @truncate(last_fetch),
            16 => @truncate(last_fetch),
            32 => last_fetch,
            else => unreachable,
        };
    }

    fn readBackup(self: *Bus, comptime T: type, sram_addr: u32) T {
        // Backup region is 8-bit only. 16/32-bit reads replicate the byte.
        const b: u8 = if (self.flash) |*f| f.read(@intCast(sram_addr)) else self.sram[sram_addr];
        return switch (@typeInfo(T).int.bits) {
            8 => @as(T, b),
            16 => @as(T, b) | (@as(T, b) << 8),
            32 => blk: {
                const w16: u32 = @as(u32, b) | (@as(u32, b) << 8);
                break :blk @intCast(w16 | (w16 << 16));
            },
            else => unreachable,
        };
    }

    fn writeBackup(self: *Bus, comptime T: type, sram_addr: u32, value: T) void {
        const b: u8 = @truncate(value);
        if (self.flash) |*f| {
            f.write(@intCast(sram_addr), b);
        } else {
            self.sram[sram_addr] = b;
        }
    }
};

/// VRAM mirror behavior: address space repeats every 128 KB, but each 128 KB
/// block is `[0x00000..0x18000] + [0x10000..0x18000]` — i.e. the top 32 KB
/// of the second half mirrors the second OBJ-tile bank.
fn vramAddr(addr: u32) u32 {
    var offset = addr & 0x1_FFFF; // 128 KB mod
    if (offset >= 0x18000) offset -= 0x8000;
    return offset;
}

fn checkType(comptime T: type) void {
    const bits = @typeInfo(T).int.bits;
    if (bits != 8 and bits != 16 and bits != 32) {
        @compileError("Bus read/write requires u8, u16, or u32");
    }
}

fn readSlice(comptime T: type, mem: []const u8, offset: u32) T {
    const bytes = @typeInfo(T).int.bits / 8;
    var value: T = 0;
    inline for (0..bytes) |i| {
        value |= @as(T, mem[offset + i]) << @intCast(i * 8);
    }
    return value;
}

fn writeSlice(comptime T: type, mem: []u8, offset: u32, value: T) void {
    const bytes = @typeInfo(T).int.bits / 8;
    inline for (0..bytes) |i| {
        mem[offset + i] = @truncate(value >> @intCast(i * 8));
    }
}

// ---- tests ----

test "WRAM round-trip and mirror" {
    var bus: Bus = .{};
    bus.write(u32, 0x0200_0000, 0xCAFEBABE);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), bus.read(u32, 0x0200_0000));
    // Mirror inside 0x02 region: WRAM is 256 KB, mirrors every 256 KB.
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), bus.read(u32, 0x0204_0000));
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), bus.read(u32, 0x02C0_0000));
}

test "IRAM round-trip 16-bit" {
    var bus: Bus = .{};
    bus.write(u16, 0x0300_0010, 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), bus.read(u16, 0x0300_0010));
    try std.testing.expectEqual(@as(u8, 0x34), bus.read(u8, 0x0300_0010));
    try std.testing.expectEqual(@as(u8, 0x12), bus.read(u8, 0x0300_0011));
}

test "VRAM 128KB mirror with split" {
    var bus: Bus = .{};
    bus.write(u32, 0x0600_0000, 0x11223344);
    bus.write(u32, 0x0601_0000, 0xAABBCCDD);
    // 0x18000 maps to 0x10000 (the 32 KB OBJ-tile mirror)
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), bus.read(u32, 0x0601_8000));
    // 0x20000 wraps back to 0x00000
    try std.testing.expectEqual(@as(u32, 0x11223344), bus.read(u32, 0x0602_0000));
}

test "BIOS is read-only" {
    var bus: Bus = .{};
    bus.bios[0] = 0xAB;
    bus.write(u8, 0x0000_0000, 0x55);
    try std.testing.expectEqual(@as(u8, 0xAB), bus.read(u8, 0x0000_0000));
}

test "ROM read past end returns 0" {
    var bus: Bus = .{};
    const rom = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    bus.rom = rom[0..];
    try std.testing.expectEqual(@as(u32, 0x44332211), bus.read(u32, 0x0800_0000));
    try std.testing.expectEqual(@as(u32, 0), bus.read(u32, 0x0800_0010));
}

test "SRAM byte-only with replication" {
    var bus: Bus = .{};
    bus.write(u8, 0x0E00_0000, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), bus.read(u8, 0x0E00_0000));
    try std.testing.expectEqual(@as(u16, 0xABAB), bus.read(u16, 0x0E00_0000));
    try std.testing.expectEqual(@as(u32, 0xABABABAB), bus.read(u32, 0x0E00_0000));
}

test "IO routed through io.zig" {
    var bus: Bus = .{};
    bus.write(u16, 0x0400_0000, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), bus.read(u16, 0x0400_0000));
}
