//! Cart GPIO + the chips wired to it (RTC, Solar, Rumble).
//!
//! Cart MMIO surface at 0x080000C4..0x080000C8 (each 16-bit register):
//!   0xC4  data        — 4-bit pin state (read by chip implementations)
//!   0xC6  direction   — bit per pin: 1 = output (GBA → chip), 0 = input
//!   0xC8  control     — bit 0: 1 = enable GPIO read-back (otherwise reads 0)
//!
//! Device selection is by ROM gamecode (see `detect`). Once selected,
//! the chip's `step(data, dir)` runs on every CPU write to GPIO data.

const std = @import("std");

extern fn time(t: ?*c_long) c_long;
extern fn localtime(t: *const c_long) *Tm;

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int, // 0-11
    tm_year: c_int, // years since 1900
    tm_wday: c_int, // 0=Sunday
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

pub const Device = enum { none, rtc, rtc_solar, rumble };

pub fn detect(game_code: [4]u8) Device {
    const code = std.mem.readInt(u32, &game_code, .little);
    // Pokemon R/S/FR/LG/Emerald (US/EU/JP)
    const rtc_codes = [_]u32{
        codeOf("AXVE"), codeOf("AXPE"), codeOf("AXVJ"), codeOf("AXPJ"),
        codeOf("AXRE"), codeOf("AXSE"), codeOf("AXRJ"), codeOf("AXSJ"),
        codeOf("BPRE"), codeOf("BPGE"), codeOf("BPRJ"), codeOf("BPGJ"),
        codeOf("BPEE"), codeOf("BPEJ"),
    };
    const solar_codes = [_]u32{
        codeOf("U3IE"), codeOf("U3IJ"),
        codeOf("U32E"), codeOf("U32J"), codeOf("U32P"),
        codeOf("U33J"),
    };
    const rumble_codes = [_]u32{
        codeOf("KHPE"), codeOf("V49E"), codeOf("AGSE"), codeOf("AGSP"),
    };
    for (rtc_codes) |c| if (code == c) return .rtc;
    for (solar_codes) |c| if (code == c) return .rtc_solar;
    for (rumble_codes) |c| if (code == c) return .rumble;
    return .none;
}

inline fn codeOf(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

pub const Gpio = struct {
    device: Device = .none,
    data: u16 = 0, // bits 0-3
    direction: u16 = 0,
    control: u16 = 0,
    rtc: Rtc = .{},
    solar: Solar = .{},
    rumble: Rumble = .{},

    /// Bus reads from 0x080000C4 / 0xC6 / 0xC8 land here. Returns 0 when
    /// GPIO read-back is disabled (control bit 0 = 0).
    pub fn read(self: *Gpio, rom_addr: u32) u16 {
        if ((self.control & 1) == 0) return 0;
        return switch (rom_addr) {
            0xC4 => self.dataPins() & 0x0F,
            0xC6 => self.direction & 0x0F,
            0xC8 => self.control & 0x01,
            else => 0,
        };
    }

    pub fn write(self: *Gpio, rom_addr: u32, value: u16) void {
        switch (rom_addr) {
            0xC4 => {
                // Update only bits flagged as output in `direction`.
                self.data = (self.data & ~self.direction) | (value & self.direction & 0x0F);
                self.step();
            },
            0xC6 => self.direction = value & 0x0F,
            0xC8 => self.control = value & 0x0001,
            else => {},
        }
    }

    /// Real chips drive the input bits — let them update data after the
    /// last write.
    fn dataPins(self: *Gpio) u16 {
        // Mask off output pins (chip can't drive them).
        const input_mask = ~self.direction & 0x0F;
        var d = self.data & self.direction & 0x0F;
        if (self.device == .rtc or self.device == .rtc_solar) {
            d |= self.rtc.outputBits() & input_mask;
        }
        return d;
    }

    fn step(self: *Gpio) void {
        switch (self.device) {
            .rtc, .rtc_solar => self.rtc.step(&self.data, self.direction),
            .rumble => self.rumble.step(self.data),
            .none => {},
        }
    }
};

// ====================================================================
// Seiko S-3511A RTC chip
// ====================================================================
//
// Connected to GPIO pins 0 (SCK), 1 (SIO), 2 (CS). Bit-banged over
// rising/falling SCK edges; CS goes high at the start of a command and
// stays high through both the 8-bit command byte and any payload bytes.
//
// Commands (high nibble = 0x6; low nibble = direction/op):
//   0x60   reset       (no data)
//   0x62   status R    (1 byte:  bit6=24h mode, bit1=power-off)
//   0x63   status W    (1 byte)
//   0x64   date+time W (7 BCD bytes)
//   0x65   date+time R (7 BCD bytes: YY MM DD WDAY HH MM SS)
//   0x66   time-only W (3 BCD bytes)
//   0x67   time-only R (3 BCD bytes: HH MM SS)

const RtcState = enum { idle, cmd, response };

pub const Rtc = struct {
    state: RtcState = .idle,
    cmd: u8 = 0,
    bit_idx: u8 = 0,
    byte_idx: u8 = 0,
    response: [7]u8 = [_]u8{0} ** 7,
    response_len: u8 = 0,
    sck_last: u1 = 0,
    cs_last: u1 = 0,
    status: u8 = 0x40, // bit6 set = 24h mode

    pub fn outputBits(self: *const Rtc) u16 {
        // SIO pin 1 drives bit 1 of the data nibble when chip is responding.
        if (self.state == .response) {
            const byte = self.response[self.byte_idx];
            const bit: u16 = (@as(u16, byte) >> @intCast(self.bit_idx)) & 1;
            return bit << 1;
        }
        return 0;
    }

    pub fn step(self: *Rtc, data: *u16, direction: u16) void {
        const sck: u1 = @intCast(data.* & 1);
        const sio: u1 = @intCast((data.* >> 1) & 1);
        const cs: u1 = @intCast((data.* >> 2) & 1);
        _ = direction;

        // CS rising edge: reset to idle, start receiving command.
        if (cs == 1 and self.cs_last == 0) {
            self.state = .cmd;
            self.cmd = 0;
            self.bit_idx = 0;
            self.byte_idx = 0;
        }
        if (cs == 0 and self.cs_last == 1) {
            self.state = .idle;
        }
        self.cs_last = cs;

        // SCK rising edge during command receipt: latch one SIO bit.
        if (cs == 1 and sck == 1 and self.sck_last == 0) {
            switch (self.state) {
                .cmd => {
                    self.cmd = (self.cmd << 1) | @as(u8, sio);
                    self.bit_idx += 1;
                    if (self.bit_idx >= 8) {
                        self.bit_idx = 0;
                        self.dispatch();
                    }
                },
                .response => {
                    self.bit_idx += 1;
                    if (self.bit_idx >= 8) {
                        self.bit_idx = 0;
                        self.byte_idx += 1;
                        if (self.byte_idx >= self.response_len) {
                            self.state = .idle;
                        }
                    }
                },
                else => {},
            }
        }
        self.sck_last = sck;
    }

    fn dispatch(self: *Rtc) void {
        switch (self.cmd) {
            0x60 => self.state = .idle, // reset
            0x62 => {
                self.response[0] = self.status;
                self.response_len = 1;
                self.byte_idx = 0;
                self.state = .response;
            },
            0x65 => {
                self.fillDateTime();
                self.response_len = 7;
                self.byte_idx = 0;
                self.state = .response;
            },
            0x67 => {
                self.fillTimeOnly();
                self.response_len = 3;
                self.byte_idx = 0;
                self.state = .response;
            },
            else => self.state = .idle,
        }
    }

    fn fillDateTime(self: *Rtc) void {
        const now = time(null);
        const lt = localtime(&now);
        self.response[0] = bcd(@intCast(@mod(lt.tm_year, 100))); // years since 1900 → 2-digit
        self.response[1] = bcd(@intCast(lt.tm_mon + 1));
        self.response[2] = bcd(@intCast(lt.tm_mday));
        self.response[3] = bcd(@intCast(lt.tm_wday));
        self.response[4] = bcd(@intCast(lt.tm_hour));
        self.response[5] = bcd(@intCast(lt.tm_min));
        self.response[6] = bcd(@intCast(lt.tm_sec));
    }

    fn fillTimeOnly(self: *Rtc) void {
        const now = time(null);
        const lt = localtime(&now);
        self.response[0] = bcd(@intCast(lt.tm_hour));
        self.response[1] = bcd(@intCast(lt.tm_min));
        self.response[2] = bcd(@intCast(lt.tm_sec));
    }

    fn bcd(v: u8) u8 {
        return ((v / 10) << 4) | (v % 10);
    }
};

// ====================================================================
// Solar sensor (Boktai)
// ====================================================================

pub const Solar = struct {
    /// 0 = brightest, 255 = darkest (counterintuitive; matches real HW).
    value: u8 = 0xE8,
    counter: u8 = 0,

    pub fn read(self: *Solar) u8 {
        self.counter +%= 1;
        return if (self.counter <= self.value) 0 else 1;
    }
};

// ====================================================================
// Rumble pak (Drill Dozer / WarioWare Twisted)
// ====================================================================

pub const Rumble = struct {
    on: bool = false,

    pub fn step(self: *Rumble, data: u16) void {
        const new_on = (data & 0x08) != 0; // pin 3
        if (new_on != self.on) {
            self.on = new_on;
            std.debug.print("[rumble] {s}\n", .{if (new_on) "on" else "off"});
        }
    }
};

test "GPIO RTC dispatch returns BCD time-only" {
    var g = Gpio{ .device = .rtc, .control = 1 };
    // Simulate a tiny CS+SCK clock for 0x67 (time-only read) command.
    g.write(0xC6, 0x0F); // all outputs for setup
    g.write(0xC4, 0); // CS=0
    g.write(0xC4, 0x04); // CS=1
    // Now clock 8 bits of 0x67 = 0b01100111 (MSB first)
    const bits = [_]u1{ 0, 1, 1, 0, 0, 1, 1, 1 };
    for (bits) |b| {
        g.write(0xC4, 0x04 | (@as(u16, b) << 1) | 0); // SCK=0
        g.write(0xC4, 0x04 | (@as(u16, b) << 1) | 1); // SCK=1
    }
    // Chip should now be in .response state with time-only filled.
    try std.testing.expectEqual(RtcState.response, g.rtc.state);
    try std.testing.expectEqual(@as(u8, 3), g.rtc.response_len);
}
