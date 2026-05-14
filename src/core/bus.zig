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
const eeprom_mod = @import("eeprom.zig");
const gpio_mod = @import("gpio.zig");

pub const BIOS_SIZE: u32 = 0x4000;
pub const WRAM_SIZE: u32 = 0x40000;
pub const IRAM_SIZE: u32 = 0x8000;
pub const PRAM_SIZE: u32 = 0x400;
pub const VRAM_SIZE: u32 = 0x18000;
pub const OAM_SIZE: u32 = 0x400;
pub const SRAM_SIZE: u32 = 0x10000;
pub const FLASH128_SIZE: u32 = 0x20000;
pub const ROM_MAX_SIZE: u32 = 0x02000000; // 32 MB per bank, three banks total

/// NBA-style prefetch buffer state. The cart bus speculatively
/// pre-fetches sequential opcodes into a small FIFO while the CPU
/// is busy on non-ROM work. A code fetch that hits the FIFO costs
/// 1 cycle instead of the full S-cycle.
pub const Prefetch = struct {
    enabled: bool = false,
    active: bool = false,
    count: u8 = 0,
    capacity: u8 = 8, // 8 for Thumb, 4 for ARM
    /// Cycles before next prefetched word arrives.
    countdown: i32 = 0,
    /// S-cycle cost per opcode at the active region.
    duty: u8 = 2,
    /// Thumb mode at last refill.
    thumb: bool = false,
    /// 2 for Thumb, 4 for ARM.
    opcode_width: u8 = 2,
    /// Next address the prefetch unit will pull from cart-ROM.
    last_address: u32 = 0,
    /// Address of the first opcode currently in the buffer (the
    /// next one the CPU would consume on a hit).
    head_address: u32 = 0,
};

pub const Bus = struct {
    bios: [BIOS_SIZE]u8 = std.mem.zeroes([BIOS_SIZE]u8),
    wram: [WRAM_SIZE]u8 = std.mem.zeroes([WRAM_SIZE]u8),
    iram: [IRAM_SIZE]u8 = std.mem.zeroes([IRAM_SIZE]u8),
    pram: [PRAM_SIZE]u8 = std.mem.zeroes([PRAM_SIZE]u8),
    vram: [VRAM_SIZE]u8 = std.mem.zeroes([VRAM_SIZE]u8),
    oam: [OAM_SIZE]u8 = std.mem.zeroes([OAM_SIZE]u8),
    sram: [SRAM_SIZE]u8 = [_]u8{0xFF} ** SRAM_SIZE,
    flash_data: [FLASH128_SIZE]u8 = [_]u8{0xFF} ** FLASH128_SIZE,
    flash: ?flash_mod.Flash = null,
    eeprom: ?*eeprom_mod.Eeprom = null,
    /// True when the cart uses EEPROM and its bus window is the narrow
    /// 0x0DFFFF00..0x0DFFFFFF range (= ROM > 16 MB). Otherwise EEPROM
    /// occupies all of region 0xD.
    eeprom_narrow_window: bool = false,
    rom: []const u8 = &.{},
    gpio_enabled: bool = false,
    gpio: ?*gpio_mod.Gpio = null,
    save_dirty: bool = false,

    /// Set by PPU at H-draw entry, cleared at H-blank. CPU accesses to
    /// PRAM/VRAM/OAM during H-draw stall an additional cycle because PPU
    /// is contending for the same bus.
    ppu_in_hdraw: bool = false,

    /// Cart-ROM prefetch buffer state. Enabled via WAITCNT.14. While
    /// the CPU does non-ROM work, the cart bus speculatively prefetches
    /// sequential ROM words; a subsequent code fetch hits the buffer at
    /// 1-cycle cost instead of the full S-cycle.
    prefetch: Prefetch = .{},

    io: io_mod.Io = .{},

    /// Last code fetch, used as the open-bus value once the CPU pipeline is
    /// in. Today it's just zero.
    last_code_fetch: u32 = 0,

    /// Cycles spent on bus accesses since the CPU last cleared this.
    wait_cycles_accum: u32 = 0,

    /// Per-region 16-bit access cycle counts: [region][N=0, S=1].
    /// Index 0 = nonseq, index 1 = seq (and code, which is a sequential
    /// instruction fetch). Recomputed when WAITCNT (0x4000204) is written.
    wait16: [16][2]u8 = default_wait16,
    /// Same for 32-bit access.
    wait32: [16][2]u8 = default_wait32,

    /// Bus access type. Real ARM7TDMI signals N (nonseq) / S (seq) / I
    /// (internal) on every bus transaction; cart waitstates differ for each.
    pub const Access = enum(u2) { nonseq, seq, code };

    pub fn read(self: *Bus, comptime T: type, addr: u32) T {
        return self.readTimed(T, addr, .nonseq);
    }

    pub fn write(self: *Bus, comptime T: type, addr: u32, value: T) void {
        self.writeTimed(T, addr, .nonseq, value);
    }

    pub fn readTimed(self: *Bus, comptime T: type, addr: u32, access: Access) T {
        comptime checkType(T);
        const region = (addr >> 24) & 0xF;
        self.billCycles(T, region, access);
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
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.readRomRegion(T, addr, region),
            0xE, 0xF => self.readBackup(T, addr & (SRAM_SIZE - 1)),
            else => openBus(T, self.last_code_fetch, addr),
        };
    }

    pub fn writeTimed(self: *Bus, comptime T: type, addr: u32, access: Access, value: T) void {
        comptime checkType(T);
        const region = (addr >> 24) & 0xF;
        self.billCycles(T, region, access);
        switch (region) {
            0x0 => {}, // BIOS is read-only
            0x2 => writeSlice(T, self.wram[0..], addr & (WRAM_SIZE - 1), value),
            0x3 => writeSlice(T, self.iram[0..], addr & (IRAM_SIZE - 1), value),
            0x4 => {
                self.io.write(T, addr & 0x3FF, value);
                // WAITCNT (0x04000204) touches our wait tables.
                const io_off = addr & 0x3FF;
                if (io_off <= 0x205 and io_off + (@typeInfo(T).int.bits / 8) > 0x204) {
                    self.applyWaitCnt();
                }
            },
            0x5 => {
                // PRAM: byte writes replicate as halfword (real HW: 16-bit bus).
                if (@typeInfo(T).int.bits == 8) {
                    const b: u8 = @intCast(value);
                    const ho: u32 = (addr & (PRAM_SIZE - 1)) & ~@as(u32, 1);
                    self.pram[ho] = b;
                    self.pram[ho + 1] = b;
                } else {
                    writeSlice(T, self.pram[0..], addr & (PRAM_SIZE - 1), value);
                }
            },
            0x6 => {
                // VRAM byte writes: ignored in tile-data areas (BG modes 0/1/2
                // upper region, and OBJ tile area regardless of mode); mirrored
                // as halfword in bitmap-data areas (BG2 bitmap for modes 3/4/5).
                if (@typeInfo(T).int.bits == 8) {
                    const v_off = vramAddr(addr);
                    const dispcnt_mode: u3 = @intCast(self.io.read(u16, 0x000) & 0x7);
                    const obj_start: u32 = if (dispcnt_mode >= 3) 0x14000 else 0x10000;
                    if (v_off >= obj_start) return; // OBJ tile area — ignore
                    const b: u8 = @intCast(value);
                    const ho: u32 = v_off & ~@as(u32, 1);
                    self.vram[ho] = b;
                    self.vram[ho + 1] = b;
                } else {
                    writeSlice(T, self.vram[0..], vramAddr(addr), value);
                }
            },
            0x7 => {
                // OAM byte writes are dropped on real hardware.
                if (@typeInfo(T).int.bits != 8) {
                    writeSlice(T, self.oam[0..], addr & (OAM_SIZE - 1), value);
                }
            },
            0x8, 0x9, 0xA, 0xB, 0xC, 0xD => self.writeRomRegion(T, addr, region, value),
            0xE, 0xF => self.writeBackup(T, addr & (SRAM_SIZE - 1), value),
            else => {},
        }
    }

    fn readRomRegion(self: *Bus, comptime T: type, addr: u32, region: u32) T {
        // EEPROM window in region 0xD (or 0x0DFFFF00..0xDFFFFFFF when ROM > 16 MB).
        if (self.eeprom) |e| {
            if (region == 0xD and self.eepromHits(addr)) {
                const bit: T = @intCast(e.readBit() & 1);
                return bit;
            }
        }
        return self.readRom(T, addr & 0x01FF_FFFF);
    }

    fn writeRomRegion(self: *Bus, comptime T: type, addr: u32, region: u32, value: T) void {
        // EEPROM bit-stream writes via DMA3.
        if (self.eeprom) |e| {
            if (region == 0xD and self.eepromHits(addr)) {
                e.writeBit(@intCast(value & 1));
                self.save_dirty = true;
                return;
            }
        }
        const rom_addr = addr & 0x01FF_FFFF;
        // Cart GPIO at 0x080000C4..0xC8.
        if (rom_addr >= 0xC4 and rom_addr <= 0xC9) {
            if (self.gpio) |g| {
                const bits = @typeInfo(T).int.bits;
                if (bits == 16) {
                    g.write(rom_addr & 0xFE, @intCast(value));
                } else if (bits == 8) {
                    // Update only the byte in question by reading current.
                    const reg_off = rom_addr & 0xFE;
                    var cur = g.read(reg_off);
                    if ((rom_addr & 1) == 0) {
                        cur = (cur & 0xFF00) | @as(u16, @intCast(value));
                    } else {
                        cur = (cur & 0x00FF) | (@as(u16, @intCast(value)) << 8);
                    }
                    g.write(reg_off, cur);
                } else if (bits == 32) {
                    g.write(rom_addr & 0xFE, @truncate(value));
                    g.write((rom_addr & 0xFE) + 2, @truncate(value >> 16));
                }
                if (rom_addr == 0xC8 or rom_addr == 0xC9) {
                    self.gpio_enabled = (g.control & 1) != 0;
                }
                return;
            }
            // No GPIO chip configured: keep legacy gating bit so old saves still boot.
            if (rom_addr == 0xC8) {
                self.gpio_enabled = (@as(u32, @intCast(value)) & 1) != 0;
            }
        }
    }

    inline fn eepromHits(self: *const Bus, addr: u32) bool {
        if (self.eeprom_narrow_window) {
            return (addr & 0x01FF_FF00) == 0x01FF_FF00;
        }
        return true;
    }

    fn readRom(self: *Bus, comptime T: type, rom_addr: u32) T {
        // Cart GPIO (RTC etc.) sits in ROM-space at 0x080000C4..0xC9. When
        // enabled, reads here return GPIO data. With no GPIO chip wired,
        // return 0 (older behavior).
        if (rom_addr >= 0xC4 and rom_addr <= 0xC9) {
            if (self.gpio) |g| {
                if ((g.control & 1) != 0) {
                    const v: u16 = g.read(rom_addr & 0xFE);
                    return switch (@typeInfo(T).int.bits) {
                        8 => @intCast(v & 0xFF),
                        16 => @intCast(v),
                        32 => @intCast(@as(u32, v)),
                        else => unreachable,
                    };
                }
            } else if (self.gpio_enabled) {
                return 0;
            }
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
        self.save_dirty = true;
    }

    inline fn billCycles(self: *Bus, comptime T: type, region: u32, access: Access) void {
        const idx: usize = if (access == .nonseq) 0 else 1;
        const raw_cost: u8 = if (@typeInfo(T).int.bits == 32)
            self.wait32[region][idx]
        else
            self.wait16[region][idx];

        const is_rom = region >= 0x8 and region <= 0xD;
        var cost: u8 = raw_cost;

        // Prefetch buffer fast path: sequential code fetch from cart ROM
        // can be served from the FIFO at 1 cycle cost.
        if (self.prefetch.enabled and is_rom and access == .seq and self.prefetch.count > 0) {
            cost = 1;
            self.prefetch.count -= 1;
        } else if (self.prefetch.enabled and is_rom) {
            // ROM data access or pipeline-refill nonseq: flush buffer.
            self.prefetch.count = 0;
            self.prefetch.countdown = self.prefetch.duty;
        } else if (self.prefetch.enabled and !is_rom) {
            // Non-ROM access: step prefetch forward by this access's cost.
            self.prefetch.countdown -= @as(i32, raw_cost);
            while (self.prefetch.countdown <= 0 and self.prefetch.count < self.prefetch.capacity) {
                self.prefetch.count += 1;
                self.prefetch.countdown += @as(i32, self.prefetch.duty);
            }
        }

        self.wait_cycles_accum +%= cost;
        // PPU bus contention: CPU touching PRAM/VRAM/OAM during H-draw
        // stalls 1 cycle (2 for 32-bit access to PRAM/VRAM).
        if (self.ppu_in_hdraw and (region == 0x5 or region == 0x6 or region == 0x7)) {
            self.wait_cycles_accum +%= if (@typeInfo(T).int.bits == 32 and region != 0x7) 2 else 1;
        }
    }

    /// Recompute the cart-ROM and SRAM wait tables from WAITCNT (read from
    /// `io.raw[0x204..0x205]`). Called by `io.zig` on writes to that
    /// register.
    pub fn applyWaitCnt(self: *Bus) void {
        const lo = self.io.raw[0x204];
        const hi = self.io.raw[0x205];
        const w: u16 = @as(u16, lo) | (@as(u16, hi) << 8);

        // SRAM cycles (bits 0-1): table {4,3,2,8}
        const sram_n: u8 = sram_table[w & 0x3];
        // WS0 N (bits 2-3): same table; S (bit 4): 0=2, 1=1
        const ws0_n: u8 = sram_table[(w >> 2) & 0x3];
        const ws0_s: u8 = if ((w & 0x10) != 0) 1 else 2;
        // WS1 N (bits 5-6); S (bit 7): 0=4, 1=1
        const ws1_n: u8 = sram_table[(w >> 5) & 0x3];
        const ws1_s: u8 = if ((w & 0x80) != 0) 1 else 4;
        // WS2 N (bits 8-9); S (bit 10): 0=8, 1=1
        const ws2_n: u8 = sram_table[(w >> 8) & 0x3];
        const ws2_s: u8 = if ((w & 0x400) != 0) 1 else 8;

        // Bus access also takes 1 internal cycle on top of waitstates.
        self.wait16[0x8][0] = 1 + ws0_n;
        self.wait16[0x8][1] = 1 + ws0_s;
        self.wait16[0x9] = self.wait16[0x8];
        self.wait16[0xA][0] = 1 + ws1_n;
        self.wait16[0xA][1] = 1 + ws1_s;
        self.wait16[0xB] = self.wait16[0xA];
        self.wait16[0xC][0] = 1 + ws2_n;
        self.wait16[0xC][1] = 1 + ws2_s;
        self.wait16[0xD] = self.wait16[0xC];

        // 32-bit cart access = N + S (two 16-bit fetches).
        self.wait32[0x8][0] = 1 + ws0_n + ws0_s;
        self.wait32[0x8][1] = 1 + 2 * ws0_s;
        self.wait32[0x9] = self.wait32[0x8];
        self.wait32[0xA][0] = 1 + ws1_n + ws1_s;
        self.wait32[0xA][1] = 1 + 2 * ws1_s;
        self.wait32[0xB] = self.wait32[0xA];
        self.wait32[0xC][0] = 1 + ws2_n + ws2_s;
        self.wait32[0xC][1] = 1 + 2 * ws2_s;
        self.wait32[0xD] = self.wait32[0xC];

        // SRAM region (8-bit only on real hardware; we still bill the
        // 16/32-bit access as if it were one byte access — close enough).
        self.wait16[0xE][0] = 1 + sram_n;
        self.wait16[0xE][1] = 1 + sram_n;
        self.wait16[0xF] = self.wait16[0xE];
        self.wait32[0xE] = self.wait16[0xE];
        self.wait32[0xF] = self.wait16[0xE];

        // Prefetch buffer enable (WAITCNT.14). Use WS0 S-cycle as the
        // representative refill rate — most games execute from WS0.
        const prefetch_on = (w & (1 << 14)) != 0;
        if (prefetch_on != self.prefetch.enabled) {
            self.prefetch.enabled = prefetch_on;
            self.prefetch.count = 0;
        }
        self.prefetch.duty = ws0_s;
    }
};

const sram_table = [4]u8{ 4, 3, 2, 8 };

/// Default wait tables — non-cart regions have fixed cycle costs per
/// GBATEK. Cart regions (0x8-0xD) start at WAITCNT=0 defaults (= ws table
/// index 0 → 4-cycle N, max-latency S). `applyWaitCnt()` updates them.
const default_wait16: [16][2]u8 = blk: {
    var t: [16][2]u8 = [_][2]u8{[2]u8{ 1, 1 }} ** 16;
    // EWRAM: 3 cycles for any access.
    t[0x2] = [2]u8{ 3, 3 };
    // Cart ROM (WAITCNT=0 default): N=4, S=2, +1 internal.
    const cart16 = [2]u8{ 5, 3 };
    t[0x8] = cart16;
    t[0x9] = cart16;
    t[0xA] = cart16;
    t[0xB] = cart16;
    t[0xC] = cart16;
    t[0xD] = cart16;
    // SRAM: N=4, +1 internal.
    t[0xE] = [2]u8{ 5, 5 };
    t[0xF] = [2]u8{ 5, 5 };
    break :blk t;
};

const default_wait32: [16][2]u8 = blk: {
    var t: [16][2]u8 = [_][2]u8{[2]u8{ 1, 1 }} ** 16;
    // EWRAM 32-bit: 6 cycles (two 16-bit halves).
    t[0x2] = [2]u8{ 6, 6 };
    // PRAM 32-bit: 2 cycles.
    t[0x5] = [2]u8{ 2, 2 };
    // VRAM 32-bit: 2 cycles.
    t[0x6] = [2]u8{ 2, 2 };
    // Cart ROM 32-bit at WAITCNT=0: N=4+2+1, S=2+2+1.
    const cart32 = [2]u8{ 7, 5 };
    t[0x8] = cart32;
    t[0x9] = cart32;
    t[0xA] = cart32;
    t[0xB] = cart32;
    t[0xC] = cart32;
    t[0xD] = cart32;
    t[0xE] = [2]u8{ 5, 5 };
    t[0xF] = [2]u8{ 5, 5 };
    break :blk t;
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
