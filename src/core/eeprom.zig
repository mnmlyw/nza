//! EEPROM 4K/64K backup-chip emulation.
//!
//! EEPROM is fundamentally different from SRAM/Flash:
//!   * Lives in ROM-space (region 0xD), not 0xE.
//!     - For ROMs ≤ 16 MB: bus is 0x0D000000..0x0DFFFFFF (any addr in that
//!       region speaks to EEPROM).
//!     - For ROMs > 16 MB: bus is 0x0DFFFF00..0x0DFFFFFF only.
//!   * Accessed exclusively over DMA3 as a bit-stream — each transfer
//!     reads or writes a single bit (low bit of the u16).
//!
//! Protocol per GBATEK:
//!   Read request:  "11" + 6-bit (4K) or 14-bit (64K) addr + "0"
//!                  → game sends a second DMA of 68 bits: 4 ignored + 64 data MSB-first.
//!   Write request: "10" + addr + 64 data MSB-first + "0"
//!
//! Size detection:
//!   The SDK doesn't tell us 4K vs 64K. We latch from the first DMA3
//!   transfer count: 9 (=2+6+1) → 4K, 17 (=2+14+1) → 64K. Default 64K.
//!   Rows are 64 bits = 8 bytes; 4K → 64 rows, 64K → 1024 rows.

const std = @import("std");

pub const Size = enum { unknown, kb4, kb64 };

pub const State = enum {
    receive_command, // expecting "11" or "10" header
    receive_addr_read,
    receive_addr_write,
    write_data,
    write_finish, // expecting trailing "0"
    read_pad, // returning 4 dummy bits
    read_data, // returning 64 data bits
};

pub const Eeprom = struct {
    size: Size = .unknown,
    state: State = .receive_command,
    /// 4K → 6, 64K → 14
    addr_bits: u8 = 6,
    addr: u16 = 0,
    bit_count: u16 = 0,
    cmd: u8 = 0, // 0 = read, 1 = write (low bit of the 2-bit header)
    /// 64-bit shift register for in-flight read or write.
    shift: u64 = 0,
    data: [0x2000]u8 = [_]u8{0xFF} ** 0x2000, // 8 KB max
    dirty: bool = false,

    /// Inform EEPROM of an upcoming DMA transfer count. First call after
    /// `unknown` size latches 4K vs 64K.
    pub fn announceDmaCount(self: *Eeprom, count: u32) void {
        if (self.size == .unknown) {
            if (count == 9 or count == 73) {
                self.size = .kb4;
                self.addr_bits = 6;
            } else if (count == 17 or count == 81) {
                self.size = .kb64;
                self.addr_bits = 14;
            } else {
                // Heuristic fallback: 64K is more common.
                self.size = .kb64;
                self.addr_bits = 14;
            }
        }
    }

    /// Number of bytes the chip is backed by (after size detect).
    pub fn capacity(self: *const Eeprom) usize {
        return switch (self.size) {
            .kb4 => 512,
            .kb64 => 8192,
            .unknown => 512, // before detect; harmless
        };
    }

    /// Called by the bus on a 16-bit read from the EEPROM window.
    pub fn readBit(self: *Eeprom) u16 {
        switch (self.state) {
            .read_pad => {
                self.bit_count += 1;
                if (self.bit_count >= 4) {
                    self.bit_count = 0;
                    self.state = .read_data;
                    const row = rowOffset(self.addr);
                    self.shift = loadRow(&self.data, row);
                }
                return 0;
            },
            .read_data => {
                const bit: u16 = @intCast((self.shift >> 63) & 1);
                self.shift <<= 1;
                self.bit_count += 1;
                if (self.bit_count >= 64) {
                    self.state = .receive_command;
                    self.bit_count = 0;
                }
                return bit;
            },
            else => return 1, // chip ready / idle returns 1 on real HW
        }
    }

    /// Called by the bus on a 16-bit write to the EEPROM window.
    pub fn writeBit(self: *Eeprom, value: u16) void {
        const bit: u1 = @intCast(value & 1);
        switch (self.state) {
            .receive_command => {
                // Header is 2 bits: "11" = read, "10" = write.
                if (self.bit_count == 0) {
                    if (bit != 1) return; // not a header start; ignore
                    self.bit_count = 1;
                } else {
                    self.cmd = bit; // 0 = write, 1 = read
                    self.bit_count = 0;
                    self.addr = 0;
                    self.state = if (self.cmd == 1) .receive_addr_read else .receive_addr_write;
                }
            },
            .receive_addr_read, .receive_addr_write => {
                self.addr = (self.addr << 1) | bit;
                self.bit_count += 1;
                if (self.bit_count >= self.addr_bits) {
                    self.bit_count = 0;
                    if (self.state == .receive_addr_read) {
                        // After addr there's one trailing "0" bit, then 68
                        // bits of read response. Handle the "0" silently
                        // and jump to read_pad.
                        self.state = .read_pad;
                    } else {
                        self.shift = 0;
                        self.state = .write_data;
                    }
                }
            },
            .write_data => {
                self.shift = (self.shift << 1) | bit;
                self.bit_count += 1;
                if (self.bit_count >= 64) {
                    self.bit_count = 0;
                    self.state = .write_finish;
                }
            },
            .write_finish => {
                const row = rowOffset(self.addr);
                if (row + 8 <= self.data.len) {
                    storeRow(&self.data, row, self.shift);
                    self.dirty = true;
                }
                self.state = .receive_command;
                self.bit_count = 0;
            },
            else => {},
        }
    }

    fn rowOffset(addr: u16) usize {
        return @as(usize, addr) * 8;
    }

    fn loadRow(data: *const [0x2000]u8, off: usize) u64 {
        var v: u64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            v = (v << 8) | data[off + i];
        }
        return v;
    }

    fn storeRow(data: *[0x2000]u8, off: usize, v: u64) void {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            const shift_bits: u6 = @intCast((7 - i) * 8);
            data[off + i] = @truncate(v >> shift_bits);
        }
    }
};

test "EEPROM 64K write/read round trip" {
    var e = Eeprom{};
    e.announceDmaCount(81); // write: 2+14+64+1 = 81 → 64K
    // Issue write: "10" + 14-bit addr=5 + 64 data + "0"
    e.writeBit(1);
    e.writeBit(0); // cmd = write
    // addr 14 bits MSB-first
    var bit: u4 = 13;
    while (true) {
        e.writeBit(@intCast((@as(u16, 5) >> @intCast(bit)) & 1));
        if (bit == 0) break;
        bit -= 1;
    }
    // 64 data bits — pattern 0xCAFEBABE_DEADBEEF MSB-first
    const data: u64 = 0xCAFE_BABE_DEAD_BEEF;
    var b: u8 = 63;
    while (true) {
        e.writeBit(@intCast((data >> @intCast(b)) & 1));
        if (b == 0) break;
        b -= 1;
    }
    e.writeBit(0); // trailing

    // Now read: "11" + 14-bit addr=5 + "0"
    e.writeBit(1);
    e.writeBit(1);
    bit = 13;
    while (true) {
        e.writeBit(@intCast((@as(u16, 5) >> @intCast(bit)) & 1));
        if (bit == 0) break;
        bit -= 1;
    }
    e.writeBit(0);
    // First 4 reads are padding bits.
    _ = e.readBit();
    _ = e.readBit();
    _ = e.readBit();
    _ = e.readBit();
    // Next 64 reads are the data MSB-first.
    var got: u64 = 0;
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        got = (got << 1) | @as(u64, e.readBit() & 1);
    }
    try std.testing.expectEqual(data, got);
}
