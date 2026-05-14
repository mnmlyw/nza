//! Flash backup emulation (64 KB and 128 KB).
//!
//! GBA Flash chips speak a command protocol identical to ordinary
//! NOR Flash (Atmel/Macronix/Sanyo/SST variants). Game writes a magic
//! sequence to specific addresses, then sends a command byte, then the
//! chip enters a state: chip-ID read, sector erase, byte write, or
//! bank switch (128 KB only).
//!
//! Protocol (per GBATEK):
//!   1) Write 0xAA to 0x0E005555
//!   2) Write 0x55 to 0x0E002AAA
//!   3) Write CMD to 0x0E005555 — selects what happens next
//!
//! Commands implemented:
//!   0x90: enter chip-ID mode (reads return manufacturer/device codes)
//!   0xF0: leave chip-ID mode (return to normal reads)
//!   0x80, 0x10: erase entire chip (after second magic sequence)
//!   0x80, 0x30: erase 4 KB sector (target byte after magic sequence)
//!   0xA0: write single byte (next write is data)
//!   0xB0: bank switch (128 KB; next write picks bank 0 or 1)

const std = @import("std");

pub const Size = enum { kb64, kb128 };

/// Manufacturer/device chip IDs by size — Pokemon Emerald accepts Macronix MX29L1100 IDs.
const CHIP_ID_64K: [2]u8 = .{ 0x32, 0x1B }; // Panasonic MN63F805MNP
const CHIP_ID_128K: [2]u8 = .{ 0x62, 0x13 }; // Macronix MX29L1100

const State = enum {
    idle, // normal read mode
    cmd1, // got 0xAA → 0x5555
    cmd2, // got 0x55 → 0x2AAA, ready for command byte
    chip_id, // 0x90 — reads return chip ID
    erase0, // got 0x80, waiting for second magic 0xAA
    erase1, // got 0xAA after 0x80, waiting for 0x55
    erase2, // ready: 0x10 chip-erase at 0x5555, or 0x30 sector-erase at target
    write_byte, // 0xA0 — next write is data
    bank_select, // 0xB0 — next write picks bank
};

pub const Flash = struct {
    size: Size,
    data: []u8,
    state: State = .idle,
    bank: u1 = 0,

    pub fn init(size: Size, backing: []u8) Flash {
        // 64 KB chip uses 64 KB; 128 KB chip uses 128 KB but the bus window
        // is still 64 KB (the upper 64 KB is bank-switched).
        return .{ .size = size, .data = backing };
    }

    pub fn read(self: *const Flash, addr: u16) u8 {
        if (self.state == .chip_id) {
            const id = if (self.size == .kb128) CHIP_ID_128K else CHIP_ID_64K;
            return if (addr == 0) id[0] else if (addr == 1) id[1] else 0xFF;
        }
        const base: usize = if (self.size == .kb128 and self.bank == 1) 0x10000 else 0;
        return self.data[base + addr];
    }

    pub fn write(self: *Flash, addr: u16, value: u8) void {
        switch (self.state) {
            .idle => {
                if (addr == 0x5555 and value == 0xAA) self.state = .cmd1;
            },
            .cmd1 => {
                if (addr == 0x2AAA and value == 0x55) {
                    self.state = .cmd2;
                } else {
                    self.state = .idle;
                }
            },
            .cmd2 => {
                if (addr != 0x5555) {
                    self.state = .idle;
                    return;
                }
                switch (value) {
                    0x90 => self.state = .chip_id,
                    0xF0 => self.state = .idle,
                    0x80 => self.state = .erase0,
                    0xA0 => self.state = .write_byte,
                    0xB0 => if (self.size == .kb128) {
                        self.state = .bank_select;
                    } else {
                        self.state = .idle;
                    },
                    else => self.state = .idle,
                }
            },
            .chip_id => {
                // Allow the 0xAA/0x55/0xF0 exit sequence.
                if (addr == 0x5555 and value == 0xAA) {
                    self.state = .cmd1;
                } else if (addr == 0x5555 and value == 0xF0) {
                    self.state = .idle;
                }
            },
            .erase0 => {
                self.state = if (addr == 0x5555 and value == 0xAA) .erase1 else .idle;
            },
            .erase1 => {
                self.state = if (addr == 0x2AAA and value == 0x55) .erase2 else .idle;
            },
            .erase2 => {
                if (value == 0x10 and addr == 0x5555) {
                    @memset(self.data, 0xFF);
                } else if (value == 0x30) {
                    const base: usize = if (self.size == .kb128 and self.bank == 1) 0x10000 else 0;
                    const sector_start = base + (@as(usize, addr) & 0xF000);
                    @memset(self.data[sector_start .. sector_start + 0x1000], 0xFF);
                }
                self.state = .idle;
            },
            .write_byte => {
                const base: usize = if (self.size == .kb128 and self.bank == 1) 0x10000 else 0;
                self.data[base + addr] = value;
                self.state = .idle;
            },
            .bank_select => {
                self.bank = @intCast(value & 1);
                self.state = .idle;
            },
        }
    }
};

test "chip-ID read returns Macronix 128k IDs" {
    var data = [_]u8{0xFF} ** 0x20000;
    var flash = Flash.init(.kb128, &data);
    // Magic sequence + 0x90 (chip-ID)
    flash.write(0x5555, 0xAA);
    flash.write(0x2AAA, 0x55);
    flash.write(0x5555, 0x90);
    try std.testing.expectEqual(@as(u8, 0x62), flash.read(0));
    try std.testing.expectEqual(@as(u8, 0x13), flash.read(1));
    // Exit chip-ID and read should return memory contents
    flash.write(0x5555, 0xAA);
    flash.write(0x2AAA, 0x55);
    flash.write(0x5555, 0xF0);
    try std.testing.expectEqual(@as(u8, 0xFF), flash.read(0));
}

test "byte write" {
    var data = [_]u8{0xFF} ** 0x10000;
    var flash = Flash.init(.kb64, &data);
    flash.write(0x5555, 0xAA);
    flash.write(0x2AAA, 0x55);
    flash.write(0x5555, 0xA0);
    flash.write(0x1234, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), flash.read(0x1234));
}

test "sector erase resets 4 KB to 0xFF" {
    var data = [_]u8{0x00} ** 0x10000;
    var flash = Flash.init(.kb64, &data);
    flash.write(0x5555, 0xAA);
    flash.write(0x2AAA, 0x55);
    flash.write(0x5555, 0x80);
    flash.write(0x5555, 0xAA);
    flash.write(0x2AAA, 0x55);
    flash.write(0x2000, 0x30); // erase sector at 0x2000
    try std.testing.expectEqual(@as(u8, 0xFF), flash.read(0x2000));
    try std.testing.expectEqual(@as(u8, 0xFF), flash.read(0x2FFF));
    try std.testing.expectEqual(@as(u8, 0x00), flash.read(0x3000));
}
