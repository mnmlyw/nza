//! ARM-mode instruction handlers.
//!
//! Each public `*Handler` function takes the comptime-decoded portions of the
//! dispatch hash and returns a function pointer. Pure-runtime details (e.g.
//! the exact register indices) are decoded inside the handler from `instr`.
//!
//! M1.2 coverage:
//!   * Branch (B, BL) and BX
//!   * Data processing (all 16 opcodes, immediate + register operand,
//!     shift-by-imm + shift-by-reg)
//!   * Single data transfer (LDR, STR, LDRB, STRB) with imm + reg offsets,
//!     pre/post index, writeback, up/down
//!   * MUL / MLA (32x32 → 32)
//!   * Block transfer (LDM / STM) — basic forms, no S bit / user-bank
//!   * SWI as a panic stub (proper exception entry lands in M1.3)
//!
//! Deferred: multiply long, halfword/signed transfers, PSR transfer (MRS /
//! MSR), the S-bit corner of LDM/STM, and the coprocessor space.

const std = @import("std");
const cpu_mod = @import("arm7tdmi.zig");
const Cpu = cpu_mod.Cpu;
const decode = @import("decode.zig");

// =====================================================================
// Branches
// =====================================================================

pub fn branchHandler(comptime link: bool) decode.ArmFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            // r[15] at execute = instr_addr + 8 (ARM ARM PC value).
            // Target = PC + sign_ext(imm24) * 4 = r[15] + offset.
            const offset_24: i32 = @as(i32, @bitCast(instr << 8)) >> 6;
            if (link) cpu.r[14] = (cpu.r[15] -% 4) & ~@as(u32, 3);
            const base: i32 = @bitCast(cpu.r[15]);
            cpu.r[15] = @as(u32, @bitCast(base +% offset_24));
            cpu.reloadPipeline();
        }
    }.handler;
}

/// BX Rn — branches to Rn, switching to Thumb mode if bit 0 set.
pub fn bx(cpu: *Cpu, instr: u32) void {
    const rn: u4 = @intCast(instr & 0xF);
    const target = cpu.r[rn];
    // BX 1 (= Thumb at 0): Pokemon Emerald (and several Game Freak titles)
    // use this as a soft-reset trampoline, expecting BIOS reset behaviour.
    // We HLE it as a hard restart: jump to cartridge entry in ARM mode.
    if (target == 1) {
        softReset(cpu);
        return;
    }
    cpu.cpsr.thumb = (target & 1) != 0;
    cpu.r[15] = target & ~@as(u32, if (cpu.cpsr.thumb) 1 else 3);
    cpu.reloadPipeline();
}

pub fn softResetExternal(cpu: *Cpu) void {
    softReset(cpu);
}

fn softReset(cpu: *Cpu) void {
    const Mode = cpu_mod.Mode;
    // POSTFLG (0x04000300 bit 0) lets the game distinguish a soft reset
    // from cold boot; the real BIOS sets it on power-on too.
    cpu.bus.io.raw[0x300] |= 1;
    cpu.cpsr = .{
        .mode = @intFromEnum(Mode.svc),
        .thumb = false,
        .fiq_disable = true,
        .irq_disable = true,
    };
    cpu.r[13] = 0x0300_7FE0; // SVC stack
    cpu.switchMode(.irq);
    cpu.r[13] = 0x0300_7FA0; // IRQ stack
    cpu.switchMode(.sys);
    cpu.r[13] = 0x0300_7F00; // System/user stack
    cpu.r[14] = 0x0800_0000;
    cpu.r[15] = 0x0800_0000;
    cpu.reloadPipeline();
}

// =====================================================================
// Data Processing
// =====================================================================

inline fn applyShift(value: u32, shift_type: u2, shift_amt: u32, carry_in: bool) struct { u32, bool } {
    // Special-case: zero shift amount has different meaning per type.
    if (shift_amt == 0) {
        return switch (shift_type) {
            0 => .{ value, carry_in }, // LSL #0: no shift
            1 => .{ 0, (value >> 31) & 1 == 1 }, // LSR #0 == LSR #32
            2 => blk: { // ASR #0 == ASR #32
                const sign = value & 0x8000_0000 != 0;
                break :blk .{ if (sign) 0xFFFF_FFFF else 0, sign };
            },
            3 => blk: { // ROR #0 == RRX (rotate right with extend)
                const new = (value >> 1) | (@as(u32, @intFromBool(carry_in)) << 31);
                break :blk .{ new, (value & 1) != 0 };
            },
        };
    }

    if (shift_amt >= 32) {
        return switch (shift_type) {
            0 => blk: { // LSL
                if (shift_amt == 32) break :blk .{ 0, (value & 1) != 0 };
                break :blk .{ 0, false };
            },
            1 => blk: { // LSR
                if (shift_amt == 32) break :blk .{ 0, (value >> 31) & 1 == 1 };
                break :blk .{ 0, false };
            },
            2 => blk: { // ASR
                const sign = value & 0x8000_0000 != 0;
                break :blk .{ if (sign) 0xFFFF_FFFF else 0, sign };
            },
            3 => blk: { // ROR — uses (shift_amt & 31), and 0 mod 32 means no shift but carry from bit 31
                const amt: u5 = @intCast(shift_amt & 31);
                if (amt == 0) {
                    break :blk .{ value, (value >> 31) & 1 == 1 };
                }
                const new = std.math.rotr(u32, value, amt);
                break :blk .{ new, (new >> 31) & 1 == 1 };
            },
        };
    }

    const amt: u5 = @intCast(shift_amt);
    return switch (shift_type) {
        0 => .{ value << amt, (value >> @intCast(32 - @as(u32, amt))) & 1 == 1 },
        1 => .{ value >> amt, (value >> @intCast(@as(u32, amt) - 1)) & 1 == 1 },
        2 => .{
            @as(u32, @bitCast(@as(i32, @bitCast(value)) >> amt)),
            (value >> @intCast(@as(u32, amt) - 1)) & 1 == 1,
        },
        3 => .{ std.math.rotr(u32, value, amt), (std.math.rotr(u32, value, amt) >> 31) & 1 == 1 },
    };
}

inline fn setLogicalFlags(cpu: *Cpu, result: u32, carry_out: bool) void {
    cpu.cpsr.negative = (result & 0x8000_0000) != 0;
    cpu.cpsr.zero = result == 0;
    cpu.cpsr.carry = carry_out;
    // V unaffected
}

inline fn setArithFlags(cpu: *Cpu, a: u32, b: u32, result: u32, is_sub: bool) void {
    cpu.cpsr.negative = (result & 0x8000_0000) != 0;
    cpu.cpsr.zero = result == 0;
    if (is_sub) {
        cpu.cpsr.carry = a >= b;
        const sa: i32 = @bitCast(a);
        const sb: i32 = @bitCast(b);
        cpu.cpsr.overflow = ((sa < 0) != (sb < 0)) and ((sa < 0) != (@as(i32, @bitCast(result)) < 0));
    } else {
        cpu.cpsr.carry = @as(u64, a) + @as(u64, b) > 0xFFFF_FFFF;
        const sa: i32 = @bitCast(a);
        const sb: i32 = @bitCast(b);
        cpu.cpsr.overflow = ((sa < 0) == (sb < 0)) and ((sa < 0) != (@as(i32, @bitCast(result)) < 0));
    }
}

/// ADC carry: (a + b + cin) overflowed 32-bit unsigned.
/// SBC carry: (a) >= (b + (1 - cin)) — i.e. did NOT borrow.
inline fn setAdcFlags(cpu: *Cpu, a: u32, b: u32, cin: u32, result: u32) void {
    cpu.cpsr.negative = (result & 0x8000_0000) != 0;
    cpu.cpsr.zero = result == 0;
    cpu.cpsr.carry = @as(u64, a) + @as(u64, b) + @as(u64, cin) > 0xFFFF_FFFF;
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    cpu.cpsr.overflow = ((sa < 0) == (sb < 0)) and ((sa < 0) != (@as(i32, @bitCast(result)) < 0));
}

inline fn setSbcFlags(cpu: *Cpu, a: u32, b: u32, borrow_in: u32, result: u32) void {
    cpu.cpsr.negative = (result & 0x8000_0000) != 0;
    cpu.cpsr.zero = result == 0;
    cpu.cpsr.carry = @as(u64, a) >= @as(u64, b) + @as(u64, borrow_in);
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    cpu.cpsr.overflow = ((sa < 0) != (sb < 0)) and ((sa < 0) != (@as(i32, @bitCast(result)) < 0));
}

pub fn dataProcHandler(comptime top: u8, comptime low: u4) decode.ArmFn {
    _ = low;
    const I = (top & 0b0010_0000) != 0;
    const opcode: u4 = @intCast((top >> 1) & 0xF);
    const set_flags = (top & 1) != 0;
    // For shift-by-register data-proc, the ARM7TDMI spends one extra
    // internal cycle and reads PC as PC+12 (instead of PC+8). NBA models
    // this by bumping `state.r15 += 4` BEFORE reading op1/op2 and
    // suppressing the auto-advance at the end of the handler. We mirror
    // that exactly: bump cpu.r[15] in the handler, set `branched=true`
    // so `step()` won't add another +4.
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            const rn: u4 = @intCast((instr >> 16) & 0xF);
            const rd: u4 = @intCast((instr >> 12) & 0xF);

            var op1: u32 = undefined;
            var op2: u32 = undefined;
            var carry: bool = cpu.cpsr.carry;

            if (I) {
                // Immediate operand2: NBA leaves pipe.access = Seq.
                cpu.pipe_access = .seq;
                const value: u32 = instr & 0xFF;
                const shift: u32 = ((instr >> 8) & 0xF) * 2;
                if (shift != 0) {
                    carry = ((value >> @intCast(shift - 1)) & 1) != 0;
                    op2 = std.math.rotr(u32, value, @as(u5, @intCast(shift)));
                } else {
                    op2 = value;
                }
                op1 = cpu.r[rn];
            } else {
                const shift_imm = ((instr >> 4) & 1) == 0;
                var shift: u32 = undefined;
                if (shift_imm) {
                    // Shift-by-imm: pipe.access = Seq (same as immediate path).
                    cpu.pipe_access = .seq;
                    shift = (instr >> 7) & 0x1F;
                } else {
                    // NBA's DoShift takes u8 — implicitly masks the register
                    // value's low byte. Match that here.
                    shift = cpu.r[@as(u4, @intCast((instr >> 8) & 0xF))] & 0xFF;
                    // NBA: state.r15 += 4; bus.Idle(); pipe.access = NSeq;
                    cpu.r[15] +%= 4;
                    cpu.bus.wait_cycles_accum +%= 1; // I-cycle
                    cpu.branched = true; // suppress step()'s post-handler +4
                    // pipe_access stays as the step() default (Nonseq).
                }
                op1 = cpu.r[rn];
                op2 = cpu.r[@as(u4, @intCast(instr & 0xF))];
                const shift_type: u2 = @intCast((instr >> 5) & 3);
                const r = doShift(op2, shift_type, shift, carry, shift_imm);
                op2 = r[0];
                carry = r[1];
            }

            var result: u32 = 0;
            var write_back = true;
            const c_in: u32 = @intFromBool(cpu.cpsr.carry);
            const borrow_in: u32 = @intFromBool(!cpu.cpsr.carry);

            switch (opcode) {
                0x0 => result = op1 & op2, // AND
                0x1 => result = op1 ^ op2, // EOR
                0x2 => result = op1 -% op2, // SUB
                0x3 => result = op2 -% op1, // RSB
                0x4 => result = op1 +% op2, // ADD
                0x5 => result = op1 +% op2 +% c_in, // ADC
                0x6 => result = op1 -% op2 -% borrow_in, // SBC
                0x7 => result = op2 -% op1 -% borrow_in, // RSC
                0x8 => { // TST
                    result = op1 & op2;
                    write_back = false;
                },
                0x9 => { // TEQ
                    result = op1 ^ op2;
                    write_back = false;
                },
                0xA => { // CMP
                    result = op1 -% op2;
                    write_back = false;
                },
                0xB => { // CMN
                    result = op1 +% op2;
                    write_back = false;
                },
                0xC => result = op1 | op2, // ORR
                0xD => result = op2, // MOV
                0xE => result = op1 & ~op2, // BIC
                0xF => result = ~op2, // MVN
            }

            // Flag computation: for TST/TEQ/CMP/CMN this is the primary
            // effect (write_back=false). For others, only if S-bit set
            // AND rd != 15 (the rd=15 case goes through CPSR-restore).
            if (!write_back or (set_flags and rd != 15)) {
                switch (opcode) {
                    0x0, 0x1, 0x8, 0x9, 0xC, 0xD, 0xE, 0xF => setLogicalFlags(cpu, result, carry),
                    0x2, 0xA => setArithFlags(cpu, op1, op2, result, true),
                    0x3 => setArithFlags(cpu, op2, op1, result, true),
                    0x4, 0xB => setArithFlags(cpu, op1, op2, result, false),
                    0x5 => setAdcFlags(cpu, op1, op2, c_in, result),
                    0x6 => setSbcFlags(cpu, op1, op2, borrow_in, result),
                    0x7 => setSbcFlags(cpu, op2, op1, borrow_in, result),
                }
            }

            if (write_back) {
                cpu.r[rd] = result;
                if (rd == 15) {
                    if (set_flags) restoreCpsrFromSpsr(cpu);
                    cpu.reloadPipeline();
                }
            } else if (rd == 15 and set_flags) {
                // CMP/TST/TEQ/CMN with Rd=15 and S=1 is the legacy
                // P-variant: restore CPSR from SPSR (no pipeline reload).
                restoreCpsrFromSpsr(cpu);
            }
        }
    }.handler;
}

/// Port of NBA's `DoShift`. Applies one of LSL/LSR/ASR/ROR/RRX to
/// `value`, in place, and updates the carry-out flag. `immediate`
/// signals whether the shift amount came from an immediate (in which
/// case ASR/LSR/ROR have special-case semantics for shift=0).
fn doShift(value: u32, shift_type: u2, amount: u32, carry_in: bool, immediate: bool) struct { u32, bool } {
    var v = value;
    var c = carry_in;
    switch (shift_type) {
        0 => { // LSL
            if (amount == 0) return .{ v, c };
            if (amount >= 32) {
                c = if (amount == 32) (v & 1) != 0 else false;
                return .{ 0, c };
            }
            const sh: u5 = @intCast(amount);
            c = ((v >> @intCast(32 - amount)) & 1) != 0;
            v = v << sh;
            return .{ v, c };
        },
        1 => { // LSR
            if (amount == 0) {
                if (immediate) {
                    // LSR #0 means LSR #32.
                    c = (v >> 31) & 1 == 1;
                    return .{ 0, c };
                }
                return .{ v, c };
            }
            if (amount >= 32) {
                c = if (amount == 32) ((v >> 31) & 1) != 0 else false;
                return .{ 0, c };
            }
            const sh: u5 = @intCast(amount);
            c = ((v >> @intCast(amount - 1)) & 1) != 0;
            v = v >> sh;
            return .{ v, c };
        },
        2 => { // ASR
            if (amount == 0 or amount >= 32) {
                if (immediate or amount >= 32) {
                    const sign = (v & 0x8000_0000) != 0;
                    c = sign;
                    v = if (sign) 0xFFFF_FFFF else 0;
                    return .{ v, c };
                }
                return .{ v, c };
            }
            const sh: u5 = @intCast(amount);
            c = ((v >> @intCast(amount - 1)) & 1) != 0;
            v = @bitCast(@as(i32, @bitCast(v)) >> sh);
            return .{ v, c };
        },
        3 => { // ROR / RRX
            if (amount == 0) {
                if (immediate) {
                    // RRX (ROR #0 immediate): rotate right by 1 through carry.
                    const new_c = (v & 1) != 0;
                    v = (v >> 1) | (@as(u32, @intFromBool(c)) << 31);
                    return .{ v, new_c };
                }
                return .{ v, c };
            }
            // ROR by amount mod 32 (when amount>0); when amount % 32 == 0
            // and amount != 0, carry = bit 31 of v, value unchanged.
            const m: u32 = amount & 31;
            if (m == 0) {
                c = (v >> 31) & 1 == 1;
                return .{ v, c };
            }
            const sh: u5 = @intCast(m);
            v = std.math.rotr(u32, v, sh);
            c = (v >> 31) & 1 == 1;
            return .{ v, c };
        },
    }
}

/// Exception-return CPSR restore.
fn restoreCpsrFromSpsr(cpu: *Cpu) void {
    const bank = currentSpsrBank(cpu);
    if (bank == 0) return;
    const saved = cpu.spsr[bank];
    if (saved.mode != cpu.cpsr.mode) {
        if (validMode(saved.mode)) {
            cpu.switchMode(@enumFromInt(saved.mode));
        } else return;
    }
    cpu.cpsr = saved;
}

fn validMode(m: u5) bool {
    return switch (m) {
        @intFromEnum(cpu_mod.Mode.user),
        @intFromEnum(cpu_mod.Mode.fiq),
        @intFromEnum(cpu_mod.Mode.irq),
        @intFromEnum(cpu_mod.Mode.svc),
        @intFromEnum(cpu_mod.Mode.abt),
        @intFromEnum(cpu_mod.Mode.und),
        @intFromEnum(cpu_mod.Mode.sys),
        => true,
        else => false,
    };
}

// =====================================================================
// Single Data Transfer (LDR, STR, LDRB, STRB)
// =====================================================================

pub fn singleDataTransferHandler(comptime top: u8, comptime low: u4) decode.ArmFn {
    _ = low;
    const I = (top & 0b0010_0000) != 0; // 1 = register offset, 0 = immediate
    const P = (top & 0b0001_0000) != 0; // pre-index
    const U = (top & 0b0000_1000) != 0; // up
    const B = (top & 0b0000_0100) != 0; // byte
    const W = (top & 0b0000_0010) != 0; // writeback
    const L = (top & 0b0000_0001) != 0; // load
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            const rn: u4 = @intCast((instr >> 16) & 0xF);
            const rd: u4 = @intCast((instr >> 12) & 0xF);

            const offset: u32 = if (I) blk: {
                const rm: u4 = @intCast(instr & 0xF);
                const shift_type: u2 = @intCast((instr >> 5) & 3);
                const shift_amt: u32 = (instr >> 7) & 0x1F;
                const r = applyShift(cpu.r[rm], shift_type, shift_amt, cpu.cpsr.carry);
                break :blk r[0];
            } else instr & 0xFFF;

            cpu.pipe_access = .nonseq; // NBA: pipe.access = NSeq

            const base = cpu.r[rn];
            const offset_addr = if (U) base +% offset else base -% offset;
            const addr = if (P) offset_addr else base;

            if (L) {
                const value: u32 = if (B) cpu.bus.read(u8, addr) else blk: {
                    // Word load: ARM rotates by (addr & 3)*8 bits.
                    const aligned = addr & ~@as(u32, 3);
                    const raw = cpu.bus.read(u32, aligned);
                    const rot: u5 = @intCast((addr & 3) * 8);
                    break :blk std.math.rotr(u32, raw, rot);
                };
                // NBA: bus.Idle() after every LDR load (1 I-cycle).
                cpu.bus.wait_cycles_accum +%= 1;
                cpu.r[rd] = value;
                if (rd == 15) cpu.reloadPipeline();
            } else {
                const value = cpu.r[rd] +% (if (rd == 15) @as(u32, 4) else 0);
                if (B) {
                    cpu.bus.write(u8, addr, @truncate(value));
                } else {
                    cpu.bus.write(u32, addr & ~@as(u32, 3), value);
                }
            }

            // Writeback: post-index always writes back; pre-index writes back if W set.
            // Don't write back if base == rd on a load (loaded value wins).
            const should_writeback = (!P) or W;
            if (should_writeback and !(L and rn == rd)) {
                cpu.r[rn] = offset_addr;
                if (rn == 15) cpu.reloadPipeline();
            }
        }
    }.handler;
}

// =====================================================================
// Multiply (MUL, MLA — 32x32 → 32)
// =====================================================================

pub fn mulHandler(comptime opcode: u4) decode.ArmFn {
    const accumulate = (opcode & 0b0010) != 0;
    const set_flags = (opcode & 0b0001) != 0;
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            const dst: u4 = @intCast((instr >> 16) & 0xF);
            const op3: u4 = @intCast((instr >> 12) & 0xF); // accumulator for MLA
            const op2: u4 = @intCast((instr >> 8) & 0xF);
            const op1: u4 = @intCast(instr & 0xF);
            // NBA: state.r15 += 4; pipe.access = NSeq; bus.Idle()×N
            cpu.r[15] +%= 4;
            cpu.branched = true;
            cpu.pipe_access = .nonseq;
            const lhs = cpu.r[op1];
            const rhs = cpu.r[op2];
            var result: u32 = lhs *% rhs;
            _ = tickMultiply(cpu, true, rhs);
            if (accumulate) {
                result +%= cpu.r[op3];
                cpu.bus.wait_cycles_accum +%= 1; // bus.Idle()
            }
            if (set_flags) {
                cpu.cpsr.negative = (result & 0x8000_0000) != 0;
                cpu.cpsr.zero = result == 0;
                // C flag for MUL is UNPREDICTABLE per ARM spec; leave alone.
            }
            cpu.r[dst] = result;
            if (dst == 15) cpu.reloadPipeline();
        }
    }.handler;
}

/// Convenience: tickMultiply for callers that don't care about signedness.
pub fn tickMultiplyPub(cpu: *Cpu, multiplier: u32) bool {
    return tickMultiply(cpu, true, multiplier);
}

/// Port of NBA's TickMultiply: simulate ARM7TDMI's Booth multiplier
/// early-termination on byte-zero/byte-all-ones detect. Returns true
/// when all 4 bytes were processed.
fn tickMultiply(cpu: *Cpu, is_signed: bool, multiplier_in: u32) bool {
    var multiplier = multiplier_in;
    var mask: u32 = 0xFFFF_FF00;
    cpu.bus.wait_cycles_accum +%= 1; // initial bus.Idle()
    while (true) {
        multiplier &= mask;
        if (multiplier == 0) break;
        if (is_signed and multiplier == mask) break;
        mask <<= 8;
        if (mask == 0) break;
        cpu.bus.wait_cycles_accum +%= 1;
    }
    return mask == 0;
}

// =====================================================================
// Block Data Transfer (LDM, STM) — basic forms
// =====================================================================

pub fn blockTransferHandler(comptime top: u8) decode.ArmFn {
    const P = (top & 0b0001_0000) != 0; // pre-index
    const U = (top & 0b0000_1000) != 0; // up
    const S = (top & 0b0000_0100) != 0; // PSR-transfer / force-user
    const W = (top & 0b0000_0010) != 0; // writeback
    const L = (top & 0b0000_0001) != 0; // load
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            const rn: u4 = @intCast((instr >> 16) & 0xF);
            const list: u16 = @truncate(instr);
            const transfer_pc = (list & 0x8000) != 0;
            const count: u32 = if (list == 0) 16 else @popCount(list);
            // Empty list edge case: NBA loads/stores R15 only and bumps base by 64.
            const effective_list: u16 = if (list == 0) 0x8000 else list;

            const addr = cpu.r[rn];
            const start_addr = if (U) addr else addr -% (count * 4);
            const end_addr = if (U) addr +% (count * 4) else addr -% (count * 4);

            var cur: u32 = start_addr;
            if (P == U) cur +%= 4;

            cpu.pipe_access = .nonseq; // NBA: pipe.access = NSeq

            // NBA's user-mode LDM/STM (the `^` form): when S is set and
            // PC is NOT in the list (or it's a STM), temporarily switch
            // to user-mode banked regs for the transfer.
            const mode_save = cpu.cpsr.mode;
            const switch_mode = S and (!L or !transfer_pc) and
                mode_save != @intFromEnum(cpu_mod.Mode.user) and
                mode_save != @intFromEnum(cpu_mod.Mode.sys);
            if (switch_mode) cpu.switchMode(.user);

            const base_new = if (list == 0) addr +% (if (U) @as(u32, 0x40) else @as(u32, 0) -% 0x40) else end_addr;

            var first = true;
            var i: u5 = 0;
            while (i < 16) : (i += 1) {
                if ((effective_list >> @intCast(i)) & 1 == 0) continue;
                const reg: u4 = @intCast(i);
                const access: @TypeOf(cpu.bus.*).Access = if (first) .nonseq else .seq;
                const aligned_cur = cur & ~@as(u32, 3);
                if (L) {
                    const value = cpu.bus.readTimed(u32, aligned_cur, access);
                    // NBA: writeback to base register on the FIRST iteration,
                    // BEFORE loading the destination. So if base is in the
                    // list AND base == reg, the load wins (writeback gets
                    // overwritten).
                    if (W and first) {
                        cpu.r[rn] = base_new;
                        if (rn == 15) cpu.reloadPipeline();
                    }
                    cpu.r[reg] = value;
                    if (reg == 15) {
                        if (S) restoreCpsrFromSpsr(cpu);
                        cpu.reloadPipeline();
                    }
                } else {
                    var v = cpu.r[reg];
                    if (reg == 15) v +%= 4;
                    cpu.bus.writeTimed(u32, aligned_cur, access, v);
                    if (W and first) {
                        cpu.r[rn] = base_new;
                        if (rn == 15) cpu.reloadPipeline();
                    }
                }
                first = false;
                cur +%= 4;
            }

            // Restore mode if we switched to user.
            if (switch_mode) cpu.switchMode(@enumFromInt(mode_save));

            if (L) cpu.bus.wait_cycles_accum +%= 1;
        }
    }.handler;
}

// =====================================================================
// Multiply Long (UMULL, UMLAL, SMULL, SMLAL — 32x32 → 64)
// =====================================================================

pub fn mulLongHandler(comptime uas: u3) decode.ArmFn {
    // NBA mapping: bit 22 = sign_extend (set → signed multiply).
    // Our `uas` packs bits 22..20 = U/A/S. Bit 22 (uas bit 2) IS the
    // sign-extend flag, NOT an "unsigned" flag despite the GBATEK
    // naming convention some references use.
    const sign_extend = (uas & 0b100) != 0;
    const accumulate = (uas & 0b010) != 0;
    const set_flags = (uas & 0b001) != 0;
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            const rd_hi: u4 = @intCast((instr >> 16) & 0xF);
            const rd_lo: u4 = @intCast((instr >> 12) & 0xF);
            const rs: u4 = @intCast((instr >> 8) & 0xF);
            const rm: u4 = @intCast(instr & 0xF);

            // NBA: state.r15 += 4; pipe.access = NSeq
            cpu.r[15] +%= 4;
            cpu.branched = true;
            cpu.pipe_access = .nonseq;

            const lhs = cpu.r[rm];
            const rhs = cpu.r[rs];
            const product: u64 = if (sign_extend) blk: {
                const a: i64 = @as(i32, @bitCast(lhs));
                const b: i64 = @as(i32, @bitCast(rhs));
                break :blk @bitCast(a *% b);
            } else
                @as(u64, lhs) *% @as(u64, rhs);

            _ = tickMultiply(cpu, sign_extend, rhs);
            cpu.bus.wait_cycles_accum +%= 1; // unconditional bus.Idle() after mul

            var result: u64 = product;
            if (accumulate) {
                const acc: u64 = (@as(u64, cpu.r[rd_hi]) << 32) | @as(u64, cpu.r[rd_lo]);
                result +%= acc;
                cpu.bus.wait_cycles_accum +%= 1; // bus.Idle() for accumulate
            }

            cpu.r[rd_lo] = @truncate(result);
            cpu.r[rd_hi] = @truncate(result >> 32);

            if (set_flags) {
                cpu.cpsr.negative = (result & 0x8000_0000_0000_0000) != 0;
                cpu.cpsr.zero = result == 0;
                // C is UNPREDICTABLE on ARM7TDMI long-mul; leave alone.
            }

            if (rd_lo == 15 or rd_hi == 15) cpu.reloadPipeline();
        }
    }.handler;
}

// =====================================================================
// Single Data Swap (SWP, SWPB)
// =====================================================================

pub fn swpHandler(comptime byte: bool) decode.ArmFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            const src: u4 = @intCast(instr & 0xF);
            const dst: u4 = @intCast((instr >> 12) & 0xF);
            const base: u4 = @intCast((instr >> 16) & 0xF);
            // NBA: state.r15 += 4 prologue.
            cpu.r[15] +%= 4;
            cpu.branched = true;
            cpu.pipe_access = .nonseq;
            const addr = cpu.r[base];
            const tmp: u32 = if (byte)
                @as(u32, cpu.bus.read(u8, addr))
            else blk: {
                const aligned = addr & ~@as(u32, 3);
                const raw = cpu.bus.read(u32, aligned);
                const rot: u5 = @intCast((addr & 3) * 8);
                break :blk std.math.rotr(u32, raw, rot);
            };
            if (byte) {
                cpu.bus.write(u8, addr, @truncate(cpu.r[src]));
            } else {
                cpu.bus.write(u32, addr & ~@as(u32, 3), cpu.r[src]);
            }
            cpu.bus.wait_cycles_accum +%= 1; // bus.Idle()
            cpu.r[dst] = tmp;
            if (dst == 15) cpu.reloadPipeline();
        }
    }.handler;
}

// =====================================================================
// Halfword & signed transfer (LDRH, STRH, LDRSB, LDRSH)
// =====================================================================

pub fn halfwordTransferHandler(comptime top: u8, comptime sh: u2) decode.ArmFn {
    const P = (top & 0b0001_0000) != 0;
    const U = (top & 0b0000_1000) != 0;
    const I = (top & 0b0000_0100) != 0;
    const W = (top & 0b0000_0010) != 0;
    const L = (top & 0b0000_0001) != 0;
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            const rn: u4 = @intCast((instr >> 16) & 0xF);
            const rd: u4 = @intCast((instr >> 12) & 0xF);

            const offset: u32 = if (I) blk: {
                const hi: u32 = (instr >> 8) & 0xF;
                const lo: u32 = instr & 0xF;
                break :blk (hi << 4) | lo;
            } else cpu.r[@as(u4, @intCast(instr & 0xF))];

            cpu.pipe_access = .nonseq; // NBA: pipe.access = NSeq

            const base = cpu.r[rn];
            const offset_addr = if (U) base +% offset else base -% offset;
            const addr = if (P) offset_addr else base;

            if (L) {
                cpu.r[rd] = switch (sh) {
                    1 => blk: { // LDRH
                        const aligned = addr & ~@as(u32, 1);
                        const raw = cpu.bus.read(u16, aligned);
                        if ((addr & 1) != 0) break :blk std.math.rotr(u32, @as(u32, raw), 8);
                        break :blk @as(u32, raw);
                    },
                    2 => blk: { // LDRSB
                        const b = cpu.bus.read(u8, addr);
                        break :blk @bitCast(@as(i32, @as(i8, @bitCast(b))));
                    },
                    3 => blk: { // LDRSH — unaligned address falls back to LDRSB (ARM7TDMI quirk)
                        if ((addr & 1) != 0) {
                            const b = cpu.bus.read(u8, addr);
                            break :blk @bitCast(@as(i32, @as(i8, @bitCast(b))));
                        }
                        const h = cpu.bus.read(u16, addr);
                        break :blk @bitCast(@as(i32, @as(i16, @bitCast(h))));
                    },
                    else => unreachable, // sh=0 is SWP (handled elsewhere)
                };
                // NBA: bus.Idle() after every halfword/signed load.
                cpu.bus.wait_cycles_accum +%= 1;
                if (rd == 15) cpu.reloadPipeline();
            } else if (sh == 1) {
                // STRH only. sh=2,3 store forms are not used by ARM7TDMI / GBA.
                const val = cpu.r[rd] +% (if (rd == 15) @as(u32, 4) else 0);
                cpu.bus.write(u16, addr & ~@as(u32, 1), @truncate(val));
            }

            const writeback = (!P) or W;
            if (writeback and !(L and rn == rd)) {
                cpu.r[rn] = offset_addr;
                if (rn == 15) cpu.reloadPipeline();
            }
        }
    }.handler;
}

// =====================================================================
// PSR Transfer (MRS, MSR)
// =====================================================================

fn currentSpsrBank(cpu: *const Cpu) usize {
    return switch (@as(cpu_mod.Mode, @enumFromInt(cpu.cpsr.mode))) {
        .user, .sys => 0,
        .fiq => 1,
        .irq => 2,
        .svc => 3,
        .abt => 4,
        .und => 5,
    };
}

pub fn psrTransferHandler(
    comptime is_msr: bool,
    comptime use_spsr: bool,
    comptime is_imm: bool,
) decode.ArmFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u32) void {
            cpu.pipe_access = .seq; // NBA: MSR/MRS sets pipe.access = Seq
            if (!is_msr) {
                // MRS Rd, PSR
                const rd: u4 = @intCast((instr >> 12) & 0xF);
                if (use_spsr) {
                    const bank = currentSpsrBank(cpu);
                    cpu.r[rd] = if (bank == 0)
                        @bitCast(cpu.cpsr)
                    else
                        @bitCast(cpu.spsr[bank]);
                } else {
                    cpu.r[rd] = @bitCast(cpu.cpsr);
                }
                return;
            }

            // MSR PSR, operand
            const operand: u32 = if (is_imm) blk: {
                const imm: u32 = instr & 0xFF;
                const rot: u32 = ((instr >> 8) & 0xF) * 2;
                break :blk if (rot == 0) imm else std.math.rotr(u32, imm, @as(u5, @intCast(rot)));
            } else cpu.r[@as(u4, @intCast(instr & 0xF))];

            const field_mask: u4 = @intCast((instr >> 16) & 0xF);
            var mask: u32 = 0;
            if ((field_mask & 0b0001) != 0) mask |= 0x0000_00FF; // c
            if ((field_mask & 0b0010) != 0) mask |= 0x0000_FF00; // x
            if ((field_mask & 0b0100) != 0) mask |= 0x00FF_0000; // s
            if ((field_mask & 0b1000) != 0) mask |= 0xFF00_0000; // f

            // User mode can only modify flag bits of CPSR.
            if (!use_spsr and cpu.cpsr.mode == @intFromEnum(cpu_mod.Mode.user)) {
                mask &= 0xFF00_0000;
            }

            if (use_spsr) {
                const bank = currentSpsrBank(cpu);
                if (bank == 0) return;
                const old: u32 = @bitCast(cpu.spsr[bank]);
                cpu.spsr[bank] = @bitCast((old & ~mask) | (operand & mask));
                return;
            }

            const old_cpsr: u32 = @bitCast(cpu.cpsr);
            const new_val = (old_cpsr & ~mask) | (operand & mask);
            const new_cpsr: cpu_mod.Cpsr = @bitCast(new_val);

            // Mode change must go through switchMode so banked regs follow.
            if ((mask & 0xFF) != 0 and new_cpsr.mode != cpu.cpsr.mode) {
                cpu.switchMode(@enumFromInt(new_cpsr.mode));
            }
            cpu.cpsr = new_cpsr;
        }
    }.handler;
}

// =====================================================================
// Exception entry — used by SWI and (later) IRQ.
// =====================================================================

/// Enter `mode` at `vector` (BIOS ROM offset). `lr_offset` is added to the
/// *current instruction address* (the address of the instruction the CPU was
/// about to execute, or just finished for SWI) before being stored in the
/// new mode's LR.
///
/// ARM ARM exception return values:
///   - SWI Thumb: LR = current_swi_addr + 2  (return to next Thumb instr)
///   - SWI ARM:   LR = current_swi_addr + 4  (return to next ARM instr)
///   - IRQ/FIQ:   LR = interrupted_addr + 4  (SUBS PC, LR, #4 returns to interrupted)
///
/// "current instruction address" = `r[15] - 4` (Thumb pipeline) or `r[15] - 8` (ARM).
pub fn enterException(cpu: *Cpu, mode: cpu_mod.Mode, vector: u32, lr_offset: u32) void {
    const old_cpsr = cpu.cpsr;
    const current_instr_addr: u32 = if (old_cpsr.thumb)
        cpu.r[15] -% 4
    else
        cpu.r[15] -% 8;
    cpu.switchMode(mode);
    cpu.spsr[currentSpsrBank(cpu)] = old_cpsr;
    cpu.r[14] = current_instr_addr +% lr_offset;
    cpu.cpsr.thumb = false;
    cpu.cpsr.irq_disable = true;
    cpu.r[15] = vector;
    cpu.reloadPipeline();
}

pub fn swi(cpu: *Cpu, instr: u32) void {
    const swi_num: u8 = @truncate((instr >> 16) & 0xFF);
    // CpuSet and CpuFastSet are heavy memory loops; HLE them unconditionally
    // since the BIOS implementations have subtle quirks not worth chasing.
    if (swi_num == 0x0B or swi_num == 0x0C) {
        _ = hleSwi(cpu, swi_num);
        return;
    }
    if (cpu.hle_swi and hleSwi(cpu, swi_num)) return;
    // ARM SWI: LR_svc = next ARM instruction = current + 4.
    enterException(cpu, .svc, 0x08, 4);
}

/// Shared HLE entry point for Thumb SWIs (the dispatcher lives in this file
/// to share state with ARM SWI).
pub fn hleSwiForThumb(cpu: *Cpu, swi_num: u8) bool {
    return hleSwi(cpu, swi_num);
}

/// HLE for the most common BIOS SWIs. Returns `true` if the SWI was
/// handled natively (caller should NOT enter the exception path).
fn hleSwi(cpu: *Cpu, swi_num: u8) bool {
    switch (swi_num) {
        0x02 => { // Halt
            if (cpu.bus.io.irq) |irq| irq.halted = true;
            return true;
        },
        0x04, 0x05 => { // IntrWait / VBlankIntrWait
            // Both halt the CPU until the next matching IRQ fires.
            // 0x05 implicitly waits for VBlank with r0=1 (clear-old). We
            // don't model the "discard prior flags" behavior precisely;
            // most games tolerate that.
            if (cpu.bus.io.irq) |irq| {
                irq.halted = true;
                // Force IME=1 so the IRQ actually gets delivered.
                irq.ime = true;
            }
            // Unmask IRQs at CPU level too.
            cpu.cpsr.irq_disable = false;
            return true;
        },
        0x06 => { // Div: r0 / r1 → r0=quot, r1=rem, r3=|quot|
            const num: i32 = @bitCast(cpu.r[0]);
            const den: i32 = @bitCast(cpu.r[1]);
            if (den == 0) return true; // undefined; skip
            const q = @divTrunc(num, den);
            const r = @rem(num, den);
            cpu.r[0] = @bitCast(q);
            cpu.r[1] = @bitCast(r);
            cpu.r[3] = if (q < 0) @bitCast(-q) else @bitCast(q);
            return true;
        },
        0x07 => { // DivArm: r0 = r1 / r0
            const num: i32 = @bitCast(cpu.r[1]);
            const den: i32 = @bitCast(cpu.r[0]);
            if (den == 0) return true;
            cpu.r[0] = @bitCast(@divTrunc(num, den));
            cpu.r[1] = @bitCast(@rem(num, den));
            return true;
        },
        0x08 => { // Sqrt: r0 = floor(sqrt(r0))
            const v: f64 = @floatFromInt(cpu.r[0]);
            cpu.r[0] = @intFromFloat(@floor(@sqrt(v)));
            return true;
        },
        0x0B => { // CpuSet: r0=src, r1=dst, r2=flags (count + word/fixed)
            cpuSet(cpu, false);
            return true;
        },
        0x0C => { // CpuFastSet — same but 32 words per chunk; we treat same as CpuSet.
            cpuSet(cpu, true);
            return true;
        },
        else => return false,
    }
}

fn cpuSet(cpu: *Cpu, comptime fast: bool) void {
    var src = cpu.r[0];
    var dst = cpu.r[1];
    const flags = cpu.r[2];
    const count: u32 = if (fast) flags & 0x1F_FFFF else flags & 0x1F_FFFF;
    const fill = (flags & 0x0100_0000) != 0;
    const word_size: u32 = if (fast or (flags & 0x0400_0000) != 0) 4 else 2;

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (word_size == 4) {
            const v = cpu.bus.read(u32, src);
            cpu.bus.write(u32, dst, v);
        } else {
            const v = cpu.bus.read(u16, src);
            cpu.bus.write(u16, dst, v);
        }
        if (!fill) src +%= word_size;
        dst +%= word_size;
    }
}

// ---- tests ----

const Bus = @import("../core/bus.zig").Bus;

test "MOV immediate" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    // MOV r0, #0x12 — encoding: E3A00012
    // top byte = 0x3A → I=1, opcode=1101 (MOV), S=0
    const top: u8 = 0x3A;
    const handler = comptime dataProcHandler(top, 0);
    handler(&cpu, 0xE3A0_0012);
    try std.testing.expectEqual(@as(u32, 0x12), cpu.r[0]);
}

test "ADD register" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[1] = 100;
    cpu.r[2] = 50;
    // ADD r0, r1, r2 — encoding E0810002 (top=0x08, opcode=0100 ADD, no shift)
    const top: u8 = 0x08;
    const handler = comptime dataProcHandler(top, 0);
    handler(&cpu, 0xE081_0002);
    try std.testing.expectEqual(@as(u32, 150), cpu.r[0]);
}

test "branch forward by 4 bytes" {
    var bus: Bus = .{};
    // B encoding 0xEA000001: branch +4 bytes from PC=instr_addr+8 = instr_addr+12.
    bus.iram[0] = 0x01;
    bus.iram[1] = 0x00;
    bus.iram[2] = 0x00;
    bus.iram[3] = 0xEA;
    var cpu = Cpu.init(&bus);
    cpu.r[15] = 0x0300_0000;
    cpu.reloadPipeline();
    cpu.step();
    // Target = instr_addr + 8 + 4 = 0x0300_000C. After reload, r[15] = target + 8.
    try std.testing.expectEqual(@as(u32, 0x0300_0014), cpu.r[15]);
}

test "SUBS PC, LR, #0 restores CPSR from SPSR (exception return)" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    // User-mode Thumb saved in SPSR_svc, currently in SVC mode.
    cpu.spsr[3] = .{
        .mode = @intFromEnum(cpu_mod.Mode.user),
        .thumb = true,
        .fiq_disable = false,
        .irq_disable = false,
    };
    cpu.cpsr.mode = @intFromEnum(cpu_mod.Mode.svc);
    cpu.r[14] = 0x0300_0100;
    // Encoding of SUBS PC, LR, #0 = 0xE25EF000. Top byte = 0x25.
    const handler = comptime dataProcHandler(0x25, 0);
    handler(&cpu, 0xE25E_F000);
    try std.testing.expectEqual(@as(u5, @intFromEnum(cpu_mod.Mode.user)), cpu.cpsr.mode);
    try std.testing.expect(cpu.cpsr.thumb);
}

test "SMULL r2, r3, r0, r1 with -1 × -1" {
    // bit 22 = 1 = SIGNED multiplication (per NBA's gen_arm.hh).
    // SMULL of (-1) * (-1) signed = 1. Low: 1, High: 0.
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[0] = 0xFFFF_FFFF;
    cpu.r[1] = 0xFFFF_FFFF;
    // SMULL r2, r3, r0, r1: cond=AL, 0001_110_S, uas=0b110 → SMULL no-flags
    // Actually that's signed-mlal. SMULL with no accumulate = uas=0b100 (bit 22).
    // Encoding 0xE0C32190 has bit 22 = 1 = SIGNED.
    const handler = comptime mulLongHandler(0b100);
    handler(&cpu, 0xE0C3_2190);
    try std.testing.expectEqual(@as(u32, 0x0000_0001), cpu.r[2]);
    try std.testing.expectEqual(@as(u32, 0x0000_0000), cpu.r[3]);
}

test "UMULL r2, r3, r0, r1 with 0xFFFFFFFF × 0xFFFFFFFF" {
    // bit 22 = 0 = UNSIGNED. UMULL of large values.
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[0] = 0xFFFF_FFFF;
    cpu.r[1] = 0xFFFF_FFFF;
    // UMULL: uas = 0b000 (bit 22 clear)
    // Encoding pattern (bits 23-20 = 1000): 0xE0832190
    const handler = comptime mulLongHandler(0b000);
    handler(&cpu, 0xE083_2190);
    try std.testing.expectEqual(@as(u32, 0x0000_0001), cpu.r[2]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFE), cpu.r[3]);
}

test "CMN r3, #2 with r3 = 0xFFFFFFFE sets Z=1" {
    // This is the encoding the test runner uses for `cmp r3, -2`.
    // CMN: opcode=0xB, S=1. With imm: I=1, top = 0011_0111 = 0x37 (I=1, op=0xB, S=1).
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[3] = 0xFFFF_FFFE;
    const handler = comptime dataProcHandler(0x37, 0);
    handler(&cpu, 0xE373_0002);
    try std.testing.expect(cpu.cpsr.zero);
}

test "STR/LDR word round-trip" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[0] = 0xDEAD_BEEF;
    cpu.r[1] = 0x0300_0100;
    // STR r0, [r1] — E5810000 (top=0x58: I=0, P=1, U=1, B=0, W=0, L=0)
    const str = comptime singleDataTransferHandler(0x58, 0);
    str(&cpu, 0xE581_0000);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), bus.read(u32, 0x0300_0100));
    cpu.r[0] = 0;
    // LDR r0, [r1] — E5910000 (top=0x59 same but L=1)
    const ldr = comptime singleDataTransferHandler(0x59, 0);
    ldr(&cpu, 0xE591_0000);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.r[0]);
}
