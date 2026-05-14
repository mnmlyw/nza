//! ARM7TDMI CPU core.
//!
//! Pipeline: classic 3-stage (fetch, decode, execute). ARM7TDMI exposes the
//! pipeline by making PC read as `actual + 8` in ARM mode and `actual + 4`
//! in Thumb mode. We model this by maintaining a two-slot prefetch buffer:
//! `pipeline[0]` is the instruction we're about to execute, `pipeline[1]` is
//! the next prefetched word.
//!
//! Mode banking: ARM7TDMI has seven processor modes that bank different
//! register subsets (FIQ banks r8–r14, IRQ/SVC/ABT/UND bank r13–r14, plus a
//! per-mode SPSR). We store the *active* register set in `r[]` and copy
//! to/from `banked` on mode switches.
//!
//! Ported from `nba/src/arm/arm7tdmi.hh` + `state.hh`.

const std = @import("std");
const Bus = @import("../core/bus.zig").Bus;
const decode = @import("decode.zig");

pub const Mode = enum(u5) {
    user = 0x10,
    fiq = 0x11,
    irq = 0x12,
    svc = 0x13,
    abt = 0x17,
    und = 0x1B,
    sys = 0x1F,
};

/// Index into the banked register tables. User and System share banks.
pub const BankIdx = enum(u3) {
    none = 0, // user/system
    fiq = 1,
    irq = 2,
    svc = 3,
    abt = 4,
    und = 5,
};

pub const Cpsr = packed struct(u32) {
    mode: u5 = @intFromEnum(Mode.svc),
    thumb: bool = false,
    fiq_disable: bool = true,
    irq_disable: bool = true,
    _reserved: u20 = 0,
    overflow: bool = false,
    carry: bool = false,
    zero: bool = false,
    negative: bool = false,
};

/// Mapping from `Mode` to the bank index used for r13/r14 and SPSR.
fn bankFor(mode: Mode) BankIdx {
    return switch (mode) {
        .user, .sys => .none,
        .fiq => .fiq,
        .irq => .irq,
        .svc => .svc,
        .abt => .abt,
        .und => .und,
    };
}

pub const Cpu = struct {
    /// Active general-purpose registers.
    r: [16]u32 = [_]u32{0} ** 16,
    cpsr: Cpsr = .{},

    /// SPSR per banked mode (none/user is not used; placeholder kept for indexing).
    spsr: [6]Cpsr = [_]Cpsr{.{}} ** 6,

    /// Banked r13 (SP) and r14 (LR) per mode.
    bank_sp: [6]u32 = [_]u32{0} ** 6,
    bank_lr: [6]u32 = [_]u32{0} ** 6,

    /// FIQ-only banked r8..r12. Indexed 0..5 (r8..r12), only used when in/leaving FIQ mode.
    fiq_r8_12: [5]u32 = [_]u32{0} ** 5,
    /// Saved r8..r12 from non-FIQ modes (so we can restore them when leaving FIQ).
    user_r8_12: [5]u32 = [_]u32{0} ** 5,

    /// 2-instruction prefetch buffer. `pipeline[0]` = next to execute,
    /// `pipeline[1]` = freshly fetched.
    pipeline: [2]u32 = .{ 0, 0 },

    bus: *Bus,

    /// Cycles consumed by the most recently executed instruction. The host
    /// loop reads this after every `step()` and forwards to the scheduler.
    cycles: u32 = 0,

    /// Set by `reloadPipeline` (i.e. by every branch / mode change / exception
    /// entry). `step()` consults this to decide whether to advance r[15] past
    /// the executed instruction, since checking r[15] for change is fragile —
    /// a branch can coincidentally land on the same value as pre-execute PC.
    branched: bool = false,

    /// Set when running without the real BIOS — turns on our HLE SWI table.
    /// With BIOS loaded, SWIs go through the BIOS's own handlers (which are
    /// more complete than our HLE).
    hle_swi: bool = false,

    pub fn init(bus: *Bus) Cpu {
        var cpu = Cpu{ .bus = bus };
        // Real GBA boots at 0x00000000 (BIOS reset vector) in ARM mode, SVC,
        // IRQ+FIQ disabled. We mirror that here. Pipeline prefill happens on
        // the first call to `reload`.
        cpu.cpsr = .{
            .mode = @intFromEnum(Mode.svc),
            .thumb = false,
            .fiq_disable = true,
            .irq_disable = true,
        };
        cpu.r[15] = 0;
        cpu.reloadPipeline();
        return cpu;
    }

    /// Flush and refill the prefetch buffer. Called after any non-sequential
    /// PC change (branch, mode switch, exception entry). Also marks
    /// `self.branched = true` so `step()` skips its sequential PC advance.
    pub fn reloadPipeline(self: *Cpu) void {
        if (self.cpsr.thumb) {
            self.r[15] &= ~@as(u32, 1);
            self.pipeline[0] = self.bus.read(u16, self.r[15]);
            self.r[15] +%= 2;
            self.pipeline[1] = self.bus.read(u16, self.r[15]);
            self.r[15] +%= 2;
        } else {
            self.r[15] &= ~@as(u32, 3);
            self.pipeline[0] = self.bus.read(u32, self.r[15]);
            self.r[15] +%= 4;
            self.pipeline[1] = self.bus.read(u32, self.r[15]);
            self.r[15] +%= 4;
        }
        self.branched = true;
    }

    /// Execute one instruction. Returns approximate cycle count via `self.cycles`.
    ///
    /// Pipeline ordering: fetch pipe[1] from current r[15], then execute, then
    /// advance r[15] by one instruction width — but only if the handler didn't
    /// branch (i.e. didn't change r[15] itself). With this ordering, r[15]
    /// during execute equals `instr_addr + 8` in ARM mode and `instr_addr + 4`
    /// in Thumb mode, matching the ARM ARM PC value. Reads of PC by ordinary
    /// instructions (ADD Rd, PC, #imm etc.) "just work" without compensation.
    pub fn step(self: *Cpu) void {
        self.cycles = 1;
        self.branched = false;
        if (self.cpsr.thumb) {
            const instr: u16 = @truncate(self.pipeline[0]);
            self.pipeline[0] = self.pipeline[1];
            self.pipeline[1] = self.bus.read(u16, self.r[15]);
            self.bus.last_code_fetch = @as(u32, self.pipeline[1]) | (@as(u32, self.pipeline[1]) << 16);
            const idx: u10 = @intCast((instr >> 6) & 0x3FF);
            decode.thumb_lut[idx](self, instr);
            if (!self.branched) self.r[15] +%= 2;
        } else {
            const instr = self.pipeline[0];
            self.pipeline[0] = self.pipeline[1];
            self.pipeline[1] = self.bus.read(u32, self.r[15]);
            self.bus.last_code_fetch = self.pipeline[1];

            const cond: u4 = @intCast(instr >> 28);
            if (!checkCondition(self.cpsr, cond)) {
                self.r[15] +%= 4;
                return;
            }

            const hash: u12 = @intCast(((instr >> 16) & 0xFF0) | ((instr >> 4) & 0x00F));
            decode.arm_lut[hash](self, instr);
            if (!self.branched) self.r[15] +%= 4;
        }
    }

    /// Change processor mode, saving/restoring the appropriate banked regs.
    pub fn switchMode(self: *Cpu, new_mode: Mode) void {
        const old_bank = bankFor(@enumFromInt(self.cpsr.mode));
        const new_bank = bankFor(new_mode);
        if (old_bank == new_bank) {
            self.cpsr.mode = @intFromEnum(new_mode);
            return;
        }

        // Save current r13/r14 into the old bank.
        self.bank_sp[@intFromEnum(old_bank)] = self.r[13];
        self.bank_lr[@intFromEnum(old_bank)] = self.r[14];
        // Load new bank's r13/r14 into active regs.
        self.r[13] = self.bank_sp[@intFromEnum(new_bank)];
        self.r[14] = self.bank_lr[@intFromEnum(new_bank)];

        // FIQ banks r8..r12 separately from every other mode.
        const old_is_fiq = old_bank == .fiq;
        const new_is_fiq = new_bank == .fiq;
        if (old_is_fiq != new_is_fiq) {
            if (old_is_fiq) {
                // Save FIQ regs, restore user regs.
                @memcpy(&self.fiq_r8_12, self.r[8..13]);
                @memcpy(self.r[8..13], &self.user_r8_12);
            } else {
                // Save user regs, restore FIQ regs.
                @memcpy(&self.user_r8_12, self.r[8..13]);
                @memcpy(self.r[8..13], &self.fiq_r8_12);
            }
        }

        self.cpsr.mode = @intFromEnum(new_mode);
    }
};

pub fn checkCondition(cpsr: Cpsr, cond: u4) bool {
    return switch (cond) {
        0x0 => cpsr.zero, // EQ
        0x1 => !cpsr.zero, // NE
        0x2 => cpsr.carry, // CS/HS
        0x3 => !cpsr.carry, // CC/LO
        0x4 => cpsr.negative, // MI
        0x5 => !cpsr.negative, // PL
        0x6 => cpsr.overflow, // VS
        0x7 => !cpsr.overflow, // VC
        0x8 => cpsr.carry and !cpsr.zero, // HI
        0x9 => !cpsr.carry or cpsr.zero, // LS
        0xA => cpsr.negative == cpsr.overflow, // GE
        0xB => cpsr.negative != cpsr.overflow, // LT
        0xC => !cpsr.zero and (cpsr.negative == cpsr.overflow), // GT
        0xD => cpsr.zero or (cpsr.negative != cpsr.overflow), // LE
        0xE => true, // AL
        0xF => false, // NV (undefined on ARMv4, used to be coprocessor)
    };
}

// ---- tests ----

test "condition codes" {
    var cpsr: Cpsr = .{};
    try std.testing.expect(checkCondition(cpsr, 0xE)); // AL
    try std.testing.expect(!checkCondition(cpsr, 0xF)); // NV

    cpsr.zero = true;
    try std.testing.expect(checkCondition(cpsr, 0x0)); // EQ
    try std.testing.expect(!checkCondition(cpsr, 0x1)); // NE
}

test "mode switch banks r13/r14" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[13] = 0x0300_7F00; // SVC SP
    cpu.r[14] = 0xDEAD_BEEF;
    cpu.switchMode(.irq);
    cpu.r[13] = 0x0300_7FA0; // IRQ SP
    cpu.r[14] = 0xCAFE_F00D;
    cpu.switchMode(.svc);
    try std.testing.expectEqual(@as(u32, 0x0300_7F00), cpu.r[13]);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.r[14]);
    cpu.switchMode(.irq);
    try std.testing.expectEqual(@as(u32, 0x0300_7FA0), cpu.r[13]);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.r[14]);
}

test "FIQ banks r8..r12" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[8] = 0x11;
    cpu.r[12] = 0x22;
    cpu.switchMode(.fiq);
    try std.testing.expectEqual(@as(u32, 0), cpu.r[8]);
    cpu.r[8] = 0x99;
    cpu.r[12] = 0xAA;
    cpu.switchMode(.sys);
    try std.testing.expectEqual(@as(u32, 0x11), cpu.r[8]);
    try std.testing.expectEqual(@as(u32, 0x22), cpu.r[12]);
}
