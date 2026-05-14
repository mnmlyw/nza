//! PSG (Programmable Sound Generator) channels 1-4.
//!
//! These are the legacy Game Boy sound channels carried into the GBA:
//!   - Channel 1: square wave with sweep
//!   - Channel 2: square wave
//!   - Channel 3: 32-sample wave RAM
//!   - Channel 4: LFSR-based noise
//!
//! The hardware runs a "frame sequencer" at 512 Hz that ticks length
//! (256 Hz), envelopes (64 Hz), and sweep (128 Hz). At our mixer rate
//! of 32768 Hz that's one frame-sequencer step every 64 mixer samples.

const std = @import("std");

/// Duty waveform table — bit 0 plays first, MSB last.
const DUTY_TABLE = [4]u8{ 0b00000001, 0b10000001, 0b10000111, 0b01111110 };

/// 8-bit signed output amplitude clamp. Each PSG channel returns a value
/// in `[-15, 15]` (mapped from the 4-bit envelope volume) which we use to
/// build a PSG mix that fits next to the 8-bit Direct Sound channels.
pub const SquareChan = struct {
    enabled: bool = false,
    duty: u2 = 0,
    duty_pos: u3 = 0,
    freq_reg: u11 = 0,
    cycle_acc: u32 = 0,

    env_initial_volume: u4 = 0,
    env_direction: u1 = 0,
    env_period: u3 = 0,
    env_timer: u8 = 0,
    volume: u4 = 0,

    length: u8 = 0,
    length_enable: bool = false,

    // Channel 1 only — sweep parameters
    sweep_period: u3 = 0,
    sweep_direction: u1 = 0,
    sweep_shift: u3 = 0,
    sweep_timer: u8 = 0,
    sweep_freq_shadow: u11 = 0,
    sweep_enabled: bool = false,

    pub fn sample(self: *const SquareChan) i8 {
        if (!self.enabled) return 0;
        const bit = (DUTY_TABLE[self.duty] >> @as(u3, self.duty_pos)) & 1;
        const v: i8 = @intCast(@as(u8, self.volume));
        return if (bit == 1) v else -v;
    }

    /// Advance the duty-counter by `cycles` APU clocks (4.194 MHz).
    pub fn step(self: *SquareChan, cycles: u32) void {
        if (!self.enabled) return;
        const span: u32 = (@as(u32, 2048) - @as(u32, self.freq_reg)) * 4;
        if (span == 0) return;
        self.cycle_acc += cycles;
        while (self.cycle_acc >= span) {
            self.cycle_acc -= span;
            self.duty_pos +%= 1;
        }
    }

    pub fn lengthTick(self: *SquareChan) void {
        if (self.length_enable and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }

    pub fn envelopeTick(self: *SquareChan) void {
        if (self.env_period == 0) return;
        self.env_timer +%= 1;
        if (self.env_timer >= self.env_period) {
            self.env_timer = 0;
            if (self.env_direction == 1 and self.volume < 15) {
                self.volume += 1;
            } else if (self.env_direction == 0 and self.volume > 0) {
                self.volume -= 1;
            }
        }
    }

    /// Channel 1 sweep tick. Returns true if the channel should disable
    /// (overflow). The caller wires `enabled = false` accordingly.
    pub fn sweepTick(self: *SquareChan) void {
        if (!self.sweep_enabled or self.sweep_period == 0) return;
        self.sweep_timer +%= 1;
        if (self.sweep_timer < self.sweep_period) return;
        self.sweep_timer = 0;
        const shadow: u32 = self.sweep_freq_shadow;
        const delta = shadow >> @as(u3, self.sweep_shift);
        const new_freq: u32 = if (self.sweep_direction == 0) shadow + delta else shadow -% delta;
        if (new_freq > 2047) {
            self.enabled = false;
            self.sweep_enabled = false;
        } else if (self.sweep_shift != 0) {
            self.sweep_freq_shadow = @intCast(new_freq);
            self.freq_reg = @intCast(new_freq);
        }
    }

    pub fn trigger(self: *SquareChan) void {
        self.enabled = self.env_initial_volume != 0 or self.env_direction == 1;
        if (self.length == 0) self.length = 64;
        self.volume = self.env_initial_volume;
        self.env_timer = 0;
        self.cycle_acc = 0;
        self.sweep_freq_shadow = self.freq_reg;
        self.sweep_timer = 0;
        self.sweep_enabled = self.sweep_period != 0 or self.sweep_shift != 0;
    }
};

/// 32-sample 4-bit wave RAM (one or two banks of 16 bytes).
pub const WaveChan = struct {
    enabled: bool = false,
    dac_on: bool = false,
    freq_reg: u11 = 0,
    cycle_acc: u32 = 0,
    pos: u5 = 0, // 0..31 sample index within active bank
    /// 00=mute, 01=100%, 10=50%, 11=25%, plus bit 7 of CNT_H = force 75%
    volume_code: u2 = 0,
    force_75: bool = false,
    bank: u1 = 0,
    two_banks: bool = false,
    length: u9 = 0,
    length_enable: bool = false,
    /// Wave RAM — two banks of 16 bytes (32 samples each, 4-bit per sample).
    wave_ram: [32]u8 = [_]u8{0} ** 32,

    pub fn sample(self: *const WaveChan) i8 {
        if (!self.enabled or !self.dac_on) return 0;
        // 4-bit nibble per sample, packed high-nibble-first in each byte.
        const byte_off: u5 = @intCast(self.pos / 2);
        const banked_off: usize = if (self.bank == 1) @as(usize, 16) + byte_off else byte_off;
        const byte = self.wave_ram[banked_off];
        const nib: u4 = @intCast(if (self.pos & 1 == 0) (byte >> 4) else (byte & 0x0F));
        const v_unsigned: i8 = @intCast(@as(u8, nib)); // 0..15
        // DC-bias around 0: subtract 8.
        const v: i8 = v_unsigned - 8;
        if (self.force_75) return @intCast(@divFloor(@as(i16, v) * 3, 4));
        return switch (self.volume_code) {
            0 => 0,
            1 => v,
            2 => @intCast(v >> 1),
            3 => @intCast(v >> 2),
        };
    }

    pub fn step(self: *WaveChan, cycles: u32) void {
        if (!self.enabled) return;
        const span: u32 = (@as(u32, 2048) - @as(u32, self.freq_reg)) * 2;
        if (span == 0) return;
        self.cycle_acc += cycles;
        while (self.cycle_acc >= span) {
            self.cycle_acc -= span;
            self.pos +%= 1;
            if (self.two_banks and self.pos == 0) self.bank ^= 1;
        }
    }

    pub fn lengthTick(self: *WaveChan) void {
        if (self.length_enable and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }

    pub fn trigger(self: *WaveChan) void {
        self.enabled = self.dac_on;
        if (self.length == 0) self.length = 256;
        self.pos = 0;
        self.cycle_acc = 0;
    }
};

/// Linear-feedback noise channel.
pub const NoiseChan = struct {
    enabled: bool = false,
    lfsr: u15 = 0x7FFF,
    width_short: bool = false,

    freq_div_code: u3 = 0,
    freq_shift: u4 = 0,
    cycle_acc: u32 = 0,

    env_initial_volume: u4 = 0,
    env_direction: u1 = 0,
    env_period: u3 = 0,
    env_timer: u8 = 0,
    volume: u4 = 0,

    length: u8 = 0,
    length_enable: bool = false,

    pub fn sample(self: *const NoiseChan) i8 {
        if (!self.enabled) return 0;
        const bit: u1 = @intCast((self.lfsr ^ 1) & 1);
        const v: i8 = @intCast(@as(u8, self.volume));
        return if (bit == 1) v else -v;
    }

    pub fn step(self: *NoiseChan, cycles: u32) void {
        if (!self.enabled) return;
        const div: u32 = if (self.freq_div_code == 0) 8 else @as(u32, self.freq_div_code) * 16;
        const span: u32 = div << @as(u4, self.freq_shift);
        if (span == 0) return;
        self.cycle_acc += cycles;
        while (self.cycle_acc >= span) {
            self.cycle_acc -= span;
            self.advanceLfsr();
        }
    }

    fn advanceLfsr(self: *NoiseChan) void {
        const b0: u1 = @intCast(self.lfsr & 1);
        const b1: u1 = @intCast((self.lfsr >> 1) & 1);
        const new_bit: u15 = @as(u15, b0 ^ b1) << 14;
        self.lfsr = (self.lfsr >> 1) | new_bit;
        if (self.width_short) {
            // 7-bit LFSR: also write bit 6.
            self.lfsr = (self.lfsr & ~@as(u15, 1 << 6)) | (@as(u15, b0 ^ b1) << 6);
        }
    }

    pub fn lengthTick(self: *NoiseChan) void {
        if (self.length_enable and self.length > 0) {
            self.length -= 1;
            if (self.length == 0) self.enabled = false;
        }
    }

    pub fn envelopeTick(self: *NoiseChan) void {
        if (self.env_period == 0) return;
        self.env_timer +%= 1;
        if (self.env_timer >= self.env_period) {
            self.env_timer = 0;
            if (self.env_direction == 1 and self.volume < 15) {
                self.volume += 1;
            } else if (self.env_direction == 0 and self.volume > 0) {
                self.volume -= 1;
            }
        }
    }

    pub fn trigger(self: *NoiseChan) void {
        self.enabled = self.env_initial_volume != 0 or self.env_direction == 1;
        if (self.length == 0) self.length = 64;
        self.volume = self.env_initial_volume;
        self.env_timer = 0;
        self.lfsr = 0x7FFF;
        self.cycle_acc = 0;
    }
};

test "square channel produces alternating samples" {
    var ch: SquareChan = .{
        .duty = 2, // 50%
        .freq_reg = 0, // span = 8192 APU cycles per duty step
        .env_initial_volume = 8,
        .enabled = true,
        .volume = 8,
    };
    // After half a duty cycle (4 duty steps), output should flip sign.
    const first = ch.sample();
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        ch.step((@as(u32, 2048) - 0) * 4);
    }
    const after = ch.sample();
    try std.testing.expect(first != after);
}
