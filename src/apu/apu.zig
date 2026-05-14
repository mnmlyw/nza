//! Audio Processing Unit — Direct Sound A/B only for now.
//!
//! Real-hardware model:
//!   - DMA1 fills FIFO_A and DMA2 fills FIFO_B with 16 bytes (4 × u32)
//!     each time the corresponding sound timer (Timer 0 or Timer 1,
//!     selected via SOUNDCNT_H bits 10 / 14) overflows AND the FIFO is
//!     below half-full.
//!   - Every overflow of that timer also POPS one 8-bit sample from
//!     the FIFO and latches it as that channel's current output sample.
//!   - Final mix combines the two current samples (scaled per
//!     SOUNDCNT_H volume bits) and the four PSG channels.
//!
//! M1 scope: Direct Sound A/B only, PSG channels left silent.
//!
//! Sample queue: every `MIX_CYCLES` master cycles a scheduler event
//! computes a stereo i16 sample and appends it to `out`. Frontend drains
//! `out` via SDL audio.

const std = @import("std");
const Scheduler = @import("../core/scheduler.zig").Scheduler;
const Io = @import("../core/io.zig").Io;
const psg = @import("psg.zig");

/// Master output sample rate. 16.78 MHz / 512 = 32768 Hz. Picked so the
/// scheduler event period is a power of two and we hit a common audio
/// rate that SDL can resample from.
pub const SAMPLE_RATE: u32 = 32768;
const MIX_CYCLES: u64 = 16_777_216 / SAMPLE_RATE;

const FIFO_SIZE: usize = 32;
pub const TAG_MIX: u32 = 0x3000;

/// 32-byte circular byte FIFO. Stores 8-bit signed PCM samples as written
/// by DMA.
const Fifo = struct {
    buf: [FIFO_SIZE]i8 = [_]i8{0} ** FIFO_SIZE,
    head: u8 = 0,
    tail: u8 = 0,
    count: u8 = 0,

    fn push(self: *Fifo, v: i8) void {
        if (self.count >= FIFO_SIZE) {
            // Real hardware drops the oldest sample on overflow — same here.
            self.head = @intCast((@as(usize, self.head) + 1) % FIFO_SIZE);
            self.count -= 1;
        }
        self.buf[self.tail] = v;
        self.tail = @intCast((@as(usize, self.tail) + 1) % FIFO_SIZE);
        self.count += 1;
    }

    fn pop(self: *Fifo) ?i8 {
        if (self.count == 0) return null;
        const v = self.buf[self.head];
        self.head = @intCast((@as(usize, self.head) + 1) % FIFO_SIZE);
        self.count -= 1;
        return v;
    }

    fn reset(self: *Fifo) void {
        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }

    /// True when DMA should refill (below half full per real hardware).
    pub fn needsRefill(self: *const Fifo) bool {
        return self.count <= FIFO_SIZE / 2;
    }
};

/// APU clock is 4194304 Hz. At our mixer rate this is exactly 128 APU
/// cycles per mixer sample.
const APU_CYCLES_PER_MIX: u32 = 4_194_304 / SAMPLE_RATE;
/// Frame sequencer runs at 512 Hz → one step every 64 mixer samples.
const MIX_PER_FRAME_SEQ_STEP: u16 = SAMPLE_RATE / 512;

pub const Apu = struct {
    sched: *Scheduler,
    io: *Io,

    fifo_a: Fifo = .{},
    fifo_b: Fifo = .{},
    /// Latched output samples (8-bit signed). Updated on the selected
    /// timer's overflow.
    cur_a: i8 = 0,
    cur_b: i8 = 0,

    /// PSG channels.
    ch1: psg.SquareChan = .{},
    ch2: psg.SquareChan = .{},
    ch3: psg.WaveChan = .{},
    ch4: psg.NoiseChan = .{},

    /// Frame sequencer state.
    frame_seq_acc: u16 = 0,
    frame_seq_step: u3 = 0,

    /// Mixed stereo i16 ring. Frontend reads & drains.
    out: [OUT_RING]i16 = [_]i16{0} ** OUT_RING,
    out_head: usize = 0,
    out_tail: usize = 0,

    pub const OUT_RING: usize = 8192;

    pub fn init(self: *Apu) void {
        self.sched.schedule(MIX_CYCLES, onMix, self, TAG_MIX);
    }

    /// Called by the bus when DMA / CPU writes a byte to FIFO_A (0x4000A0..A3).
    pub fn writeFifoA(self: *Apu, value: u8) void {
        self.fifo_a.push(@bitCast(value));
    }
    pub fn writeFifoB(self: *Apu, value: u8) void {
        self.fifo_b.push(@bitCast(value));
    }

    /// Called by Timer 0/1 on overflow. Drains 1 byte from the selected
    /// FIFO and latches it as the current sample.
    pub fn onTimerOverflow(self: *Apu, timer_idx: u2) void {
        const cnt_h = self.io.read(u16, 0x082);
        if (((cnt_h >> 10) & 1) == @as(u16, timer_idx)) {
            if (self.fifo_a.pop()) |v| self.cur_a = v;
        }
        if (((cnt_h >> 14) & 1) == @as(u16, timer_idx)) {
            if (self.fifo_b.pop()) |v| self.cur_b = v;
        }
    }

    /// Game writes to SOUNDCNT_H (0x4000082): bit 11 = reset FIFO A,
    /// bit 15 = reset FIFO B. Reset clears the FIFO AND silences the
    /// current sample so the channel stops outputting DC between songs.
    pub fn onSoundCntHWrite(self: *Apu, new_cnt_h: u16) void {
        if ((new_cnt_h & 0x0800) != 0) {
            self.fifo_a.reset();
            self.cur_a = 0;
        }
        if ((new_cnt_h & 0x8000) != 0) {
            self.fifo_b.reset();
            self.cur_b = 0;
        }
    }

    /// Called when SOUNDCNT_X bit 7 (master enable) goes high→low. Real
    /// hardware silences all sound channels.
    pub fn onSoundDisable(self: *Apu) void {
        self.cur_a = 0;
        self.cur_b = 0;
        self.fifo_a.reset();
        self.fifo_b.reset();
        self.ch1.enabled = false;
        self.ch2.enabled = false;
        self.ch3.enabled = false;
        self.ch4.enabled = false;
    }

    /// PSG register write dispatch. `offset` is the IO offset relative to
    /// 0x04000000 (so e.g. SOUND2CNT_L low byte at 0x68).
    pub fn onPsgWrite(self: *Apu, offset: u32) void {
        const r = &self.io.raw;
        switch (offset) {
            // SOUND1CNT_L (sweep) at 0x60
            0x60 => {
                const v = r[0x60];
                self.ch1.sweep_shift = @intCast(v & 0x7);
                self.ch1.sweep_direction = @intCast((v >> 3) & 1);
                self.ch1.sweep_period = @intCast((v >> 4) & 0x7);
            },
            // SOUND1CNT_H low+high (duty/length/envelope) at 0x62-0x63
            0x62, 0x63 => {
                const lo = r[0x62];
                const hi = r[0x63];
                self.ch1.length = 64 - @as(u8, lo & 0x3F);
                self.ch1.duty = @intCast((lo >> 6) & 0x3);
                self.ch1.env_period = @intCast(hi & 0x7);
                self.ch1.env_direction = @intCast((hi >> 3) & 1);
                self.ch1.env_initial_volume = @intCast((hi >> 4) & 0xF);
            },
            // SOUND1CNT_X at 0x64-0x65 (freq + length-enable + trigger)
            0x64, 0x65 => {
                const lo = r[0x64];
                const hi = r[0x65];
                self.ch1.freq_reg = @intCast(@as(u16, lo) | ((@as(u16, hi) & 0x7) << 8));
                self.ch1.length_enable = (hi & 0x40) != 0;
                if (offset == 0x65 and (hi & 0x80) != 0) {
                    self.ch1.trigger();
                }
            },
            // SOUND2CNT_L at 0x68-0x69 (duty/length/envelope)
            0x68, 0x69 => {
                const lo = r[0x68];
                const hi = r[0x69];
                self.ch2.length = 64 - @as(u8, lo & 0x3F);
                self.ch2.duty = @intCast((lo >> 6) & 0x3);
                self.ch2.env_period = @intCast(hi & 0x7);
                self.ch2.env_direction = @intCast((hi >> 3) & 1);
                self.ch2.env_initial_volume = @intCast((hi >> 4) & 0xF);
            },
            // SOUND2CNT_H at 0x6C-0x6D (freq + length-enable + trigger)
            0x6C, 0x6D => {
                const lo = r[0x6C];
                const hi = r[0x6D];
                self.ch2.freq_reg = @intCast(@as(u16, lo) | ((@as(u16, hi) & 0x7) << 8));
                self.ch2.length_enable = (hi & 0x40) != 0;
                if (offset == 0x6D and (hi & 0x80) != 0) {
                    self.ch2.trigger();
                }
            },
            // SOUND3CNT_L at 0x70-0x71 (DAC/bank)
            0x70, 0x71 => {
                const v = r[0x70];
                self.ch3.dac_on = (v & 0x80) != 0;
                self.ch3.bank = @intCast((v >> 6) & 1);
                self.ch3.two_banks = (v & 0x20) != 0;
                if (!self.ch3.dac_on) self.ch3.enabled = false;
            },
            // SOUND3CNT_H at 0x72-0x73 (length / volume)
            0x72, 0x73 => {
                const lo = r[0x72];
                const hi = r[0x73];
                self.ch3.length = 256 - @as(u9, lo);
                self.ch3.volume_code = @intCast((hi >> 5) & 0x3);
                self.ch3.force_75 = (hi & 0x80) != 0;
            },
            // SOUND3CNT_X at 0x74-0x75
            0x74, 0x75 => {
                const lo = r[0x74];
                const hi = r[0x75];
                self.ch3.freq_reg = @intCast(@as(u16, lo) | ((@as(u16, hi) & 0x7) << 8));
                self.ch3.length_enable = (hi & 0x40) != 0;
                if (offset == 0x75 and (hi & 0x80) != 0) {
                    self.ch3.trigger();
                }
            },
            // SOUND4CNT_L at 0x78-0x79 (length / envelope)
            0x78, 0x79 => {
                const lo = r[0x78];
                const hi = r[0x79];
                self.ch4.length = 64 - @as(u8, lo & 0x3F);
                self.ch4.env_period = @intCast(hi & 0x7);
                self.ch4.env_direction = @intCast((hi >> 3) & 1);
                self.ch4.env_initial_volume = @intCast((hi >> 4) & 0xF);
            },
            // SOUND4CNT_H at 0x7C-0x7D
            0x7C, 0x7D => {
                const lo = r[0x7C];
                const hi = r[0x7D];
                self.ch4.freq_div_code = @intCast(lo & 0x7);
                self.ch4.width_short = (lo & 0x08) != 0;
                self.ch4.freq_shift = @intCast((lo >> 4) & 0xF);
                self.ch4.length_enable = (hi & 0x40) != 0;
                if (offset == 0x7D and (hi & 0x80) != 0) {
                    self.ch4.trigger();
                }
            },
            // Wave RAM at 0x90..0x9F
            0x90...0x9F => {
                const idx: u5 = @intCast(offset - 0x90);
                // Wave RAM banks are swapped — writes go to the bank NOT
                // currently in use.
                const bank_off: usize = if (self.ch3.bank == 0) @as(usize, 16) + idx else idx;
                self.ch3.wave_ram[bank_off] = r[offset];
            },
            else => {},
        }
    }

    /// Returns true if DMA refill should be triggered for this channel.
    pub fn needsRefillA(self: *const Apu) bool {
        return self.fifo_a.needsRefill();
    }
    pub fn needsRefillB(self: *const Apu) bool {
        return self.fifo_b.needsRefill();
    }

    pub fn reset(self: *Apu) void {
        self.fifo_a.reset();
        self.fifo_b.reset();
        self.cur_a = 0;
        self.cur_b = 0;
    }

    fn mixOne(self: *Apu) void {
        // 1. Advance PSG oscillators by one mixer sample's worth of APU clocks.
        self.ch1.step(APU_CYCLES_PER_MIX);
        self.ch2.step(APU_CYCLES_PER_MIX);
        self.ch3.step(APU_CYCLES_PER_MIX);
        self.ch4.step(APU_CYCLES_PER_MIX);

        // 2. Frame sequencer (512 Hz): tick length / envelope / sweep
        //    on the GB-style 8-step cadence.
        self.frame_seq_acc += 1;
        if (self.frame_seq_acc >= MIX_PER_FRAME_SEQ_STEP) {
            self.frame_seq_acc = 0;
            self.frame_seq_step +%= 1;
            const s = self.frame_seq_step;
            const tick_length = (s == 0) or (s == 2) or (s == 4) or (s == 6);
            const tick_sweep = (s == 2) or (s == 6);
            const tick_envelope = (s == 7);
            if (tick_length) {
                self.ch1.lengthTick();
                self.ch2.lengthTick();
                self.ch3.lengthTick();
                self.ch4.lengthTick();
            }
            if (tick_sweep) self.ch1.sweepTick();
            if (tick_envelope) {
                self.ch1.envelopeTick();
                self.ch2.envelopeTick();
                self.ch4.envelopeTick();
            }
        }

        // 3. PSG sample sum, routed by SOUNDCNT_L bits 8..15.
        const cnt_l = self.io.read(u16, 0x080);
        const psg_to_r = [4]bool{
            (cnt_l & 0x0100) != 0,
            (cnt_l & 0x0200) != 0,
            (cnt_l & 0x0400) != 0,
            (cnt_l & 0x0800) != 0,
        };
        const psg_to_l = [4]bool{
            (cnt_l & 0x1000) != 0,
            (cnt_l & 0x2000) != 0,
            (cnt_l & 0x4000) != 0,
            (cnt_l & 0x8000) != 0,
        };
        const psg_samples = [4]i16{
            self.ch1.sample(), self.ch2.sample(), self.ch3.sample(), self.ch4.sample(),
        };
        var psg_l: i32 = 0;
        var psg_r: i32 = 0;
        for (psg_samples, 0..) |s, i| {
            if (psg_to_l[i]) psg_l +%= s;
            if (psg_to_r[i]) psg_r +%= s;
        }
        // Master volume nibbles (3 bits each, 0..7 = 1..8 / 8).
        const vol_r: i32 = @intCast((cnt_l & 0x7) + 1);
        const vol_l: i32 = @intCast(((cnt_l >> 4) & 0x7) + 1);
        // PSG mix uses SOUNDCNT_H bits 0..1 as a global PSG scale.
        const cnt_h = self.io.read(u16, 0x082);
        const psg_scale: i32 = switch (cnt_h & 0x3) {
            0 => 1, // 25%
            1 => 2, // 50%
            2 => 4, // 100%
            else => 4,
        };
        // Each PSG channel contributes ±15. Four channels ±60. Multiply by
        // ~250 to reach i16. Master vol/8 then PSG scale/4.
        psg_l = (psg_l * 200 * vol_l * psg_scale) >> 5;
        psg_r = (psg_r * 200 * vol_r * psg_scale) >> 5;

        // 4. Direct Sound mix.
        const a_vol_full = ((cnt_h >> 2) & 1) != 0;
        const b_vol_full = ((cnt_h >> 3) & 1) != 0;
        const a_to_l = ((cnt_h >> 9) & 1) != 0;
        const a_to_r = ((cnt_h >> 8) & 1) != 0;
        const b_to_l = ((cnt_h >> 13) & 1) != 0;
        const b_to_r = ((cnt_h >> 12) & 1) != 0;
        const a_i16: i16 = @as(i16, self.cur_a) * (if (a_vol_full) @as(i16, 64) else 32);
        const b_i16: i16 = @as(i16, self.cur_b) * (if (b_vol_full) @as(i16, 64) else 32);
        var left: i32 = psg_l;
        var right: i32 = psg_r;
        if (a_to_l) left +%= a_i16;
        if (a_to_r) right +%= a_i16;
        if (b_to_l) left +%= b_i16;
        if (b_to_r) right +%= b_i16;

        const l_clamped: i16 = @intCast(std.math.clamp(left, -32768, 32767));
        const r_clamped: i16 = @intCast(std.math.clamp(right, -32768, 32767));
        self.pushOut(l_clamped);
        self.pushOut(r_clamped);
    }

    fn pushOut(self: *Apu, v: i16) void {
        const next = (self.out_tail + 1) % OUT_RING;
        if (next == self.out_head) {
            // Overflow — drop oldest. (Frontend should drain often.)
            self.out_head = (self.out_head + 1) % OUT_RING;
        }
        self.out[self.out_tail] = v;
        self.out_tail = next;
    }

    /// Frontend drains samples into `dest`. Returns number actually copied.
    pub fn drain(self: *Apu, dest: []i16) usize {
        var n: usize = 0;
        while (n < dest.len and self.out_head != self.out_tail) : (n += 1) {
            dest[n] = self.out[self.out_head];
            self.out_head = (self.out_head + 1) % OUT_RING;
        }
        return n;
    }

    pub fn available(self: *const Apu) usize {
        if (self.out_tail >= self.out_head) {
            return self.out_tail - self.out_head;
        }
        return OUT_RING - self.out_head + self.out_tail;
    }

    pub fn onMix(ctx: *anyopaque, late: u64) void {
        _ = late;
        const self: *Apu = @ptrCast(@alignCast(ctx));
        self.mixOne();
        self.sched.schedule(MIX_CYCLES, onMix, self, TAG_MIX);
    }
};

test "fifo push/pop wrap" {
    var f: Fifo = .{};
    var i: u8 = 0;
    while (i < FIFO_SIZE + 4) : (i += 1) {
        f.push(@bitCast(i));
    }
    // Latest 32 should be present; oldest 4 dropped.
    try std.testing.expectEqual(@as(u8, FIFO_SIZE), f.count);
    try std.testing.expectEqual(@as(i8, 4), f.pop().?);
}
