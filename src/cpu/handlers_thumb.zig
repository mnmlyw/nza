//! Thumb-mode instruction handlers.
//!
//! M1.2 coverage (post-fill-in):
//!   * Format 1: Move shifted register (LSL, LSR, ASR — Rd = Rs op imm5)
//!   * Format 2: Add/subtract (register and 3-bit immediate)
//!   * Format 3: Mov/Cmp/Add/Sub immediate (Rd = imm8 or Rd op= imm8)
//!   * Format 4: ALU operations (16 opcodes)
//!   * Format 5: Hi register operations / BX
//!   * Format 6: PC-relative load
//!   * Format 7: Load/store with register offset (LDR/STR/LDRB/STRB)
//!   * Format 8: Load/store sign-extended (LDSB/LDSH/STRH/LDRH reg offset)
//!   * Format 9: Load/store with immediate offset (LDR/STR/LDRB/STRB)
//!   * Format 10: Load/store halfword
//!   * Format 11: SP-relative load/store
//!   * Format 12: Load address (PC/SP-relative ADD)
//!   * Format 13: Add offset to SP
//!   * Format 14: Push/pop
//!   * Format 15: Multiple load/store
//!   * Format 16: Conditional branch
//!   * Format 17: SWI (panics until exception entry lands in M1.3)
//!   * Format 18: Unconditional branch
//!   * Format 19: Long branch with link

const std = @import("std");
const cpu_mod = @import("arm7tdmi.zig");
const Cpu = cpu_mod.Cpu;
const decode = @import("decode.zig");

inline fn setNZ(cpu: *Cpu, result: u32) void {
    cpu.cpsr.negative = (result & 0x8000_0000) != 0;
    cpu.cpsr.zero = result == 0;
}

inline fn setAddFlags(cpu: *Cpu, a: u32, b: u32, result: u32) void {
    setNZ(cpu, result);
    cpu.cpsr.carry = @as(u64, a) + @as(u64, b) > 0xFFFF_FFFF;
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    cpu.cpsr.overflow = ((sa < 0) == (sb < 0)) and ((sa < 0) != (@as(i32, @bitCast(result)) < 0));
}

inline fn setAdcFlags(cpu: *Cpu, a: u32, b: u32, c: u32, result: u32) void {
    setNZ(cpu, result);
    cpu.cpsr.carry = @as(u64, a) + @as(u64, b) + @as(u64, c) > 0xFFFF_FFFF;
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    cpu.cpsr.overflow = ((sa < 0) == (sb < 0)) and ((sa < 0) != (@as(i32, @bitCast(result)) < 0));
}

inline fn setSubFlags(cpu: *Cpu, a: u32, b: u32, result: u32) void {
    setNZ(cpu, result);
    cpu.cpsr.carry = a >= b;
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    cpu.cpsr.overflow = ((sa < 0) != (sb < 0)) and ((sa < 0) != (@as(i32, @bitCast(result)) < 0));
}

inline fn setSbcFlags(cpu: *Cpu, a: u32, b: u32, borrow: u32, result: u32) void {
    setNZ(cpu, result);
    cpu.cpsr.carry = @as(u64, a) >= @as(u64, b) + @as(u64, borrow);
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    cpu.cpsr.overflow = ((sa < 0) != (sb < 0)) and ((sa < 0) != (@as(i32, @bitCast(result)) < 0));
}

// =====================================================================
// Format 1: Move shifted register
// =====================================================================

pub fn moveShiftedRegHandler(comptime op: u2) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const offset: u32 = (instr >> 6) & 0x1F;
            const rs: u3 = @intCast((instr >> 3) & 7);
            const rd: u3 = @intCast(instr & 7);
            const value = cpu.r[rs];
            var result: u32 = undefined;
            var carry: bool = cpu.cpsr.carry;
            switch (op) {
                0 => { // LSL
                    if (offset == 0) {
                        result = value;
                    } else {
                        result = value << @intCast(offset);
                        carry = (value >> @intCast(32 - offset)) & 1 == 1;
                    }
                },
                1 => { // LSR
                    if (offset == 0) {
                        result = 0;
                        carry = (value >> 31) & 1 == 1;
                    } else {
                        result = value >> @intCast(offset);
                        carry = (value >> @intCast(offset - 1)) & 1 == 1;
                    }
                },
                2 => { // ASR
                    if (offset == 0) {
                        const sign = value & 0x8000_0000 != 0;
                        result = if (sign) 0xFFFF_FFFF else 0;
                        carry = sign;
                    } else {
                        result = @as(u32, @bitCast(@as(i32, @bitCast(value)) >> @intCast(offset)));
                        carry = (value >> @intCast(offset - 1)) & 1 == 1;
                    }
                },
                3 => unreachable, // Format 1 is op in {0,1,2}; 3 belongs to Format 2.
            }
            cpu.r[rd] = result;
            setNZ(cpu, result);
            cpu.cpsr.carry = carry;
        }
    }.handler;
}

// =====================================================================
// Format 2: Add/subtract (register or 3-bit immediate)
// =====================================================================

pub fn addSubHandler(comptime is_sub: bool, comptime is_imm: bool) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const operand_field: u32 = (instr >> 6) & 7;
            const rs: u3 = @intCast((instr >> 3) & 7);
            const rd: u3 = @intCast(instr & 7);
            const a = cpu.r[rs];
            const b: u32 = if (is_imm) operand_field else cpu.r[@as(u3, @intCast(operand_field))];
            const result = if (is_sub) a -% b else a +% b;
            cpu.r[rd] = result;
            if (is_sub) setSubFlags(cpu, a, b, result) else setAddFlags(cpu, a, b, result);
        }
    }.handler;
}

// =====================================================================
// Format 3: Move/compare/add/subtract immediate
// =====================================================================

pub fn movCmpAddSubImmHandler(comptime op: u2) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const rd: u3 = @intCast((instr >> 8) & 7);
            const imm: u32 = instr & 0xFF;
            const a = cpu.r[rd];
            switch (op) {
                0 => { // MOV imm
                    cpu.r[rd] = imm;
                    setNZ(cpu, imm);
                },
                1 => { // CMP imm
                    const result = a -% imm;
                    setSubFlags(cpu, a, imm, result);
                },
                2 => { // ADD imm
                    const result = a +% imm;
                    cpu.r[rd] = result;
                    setAddFlags(cpu, a, imm, result);
                },
                3 => { // SUB imm
                    const result = a -% imm;
                    cpu.r[rd] = result;
                    setSubFlags(cpu, a, imm, result);
                },
            }
        }
    }.handler;
}

// =====================================================================
// Format 4: ALU operations
// =====================================================================

pub fn aluHandler(cpu: *Cpu, instr: u16) void {
    const op: u4 = @intCast((instr >> 6) & 0xF);
    const rs: u3 = @intCast((instr >> 3) & 7);
    const rd: u3 = @intCast(instr & 7);
    const a = cpu.r[rd];
    const b = cpu.r[rs];
    switch (op) {
        0x0 => { // AND
            const r = a & b;
            cpu.r[rd] = r;
            setNZ(cpu, r);
        },
        0x1 => { // EOR
            const r = a ^ b;
            cpu.r[rd] = r;
            setNZ(cpu, r);
        },
        0x2 => { // LSL Rd, Rs
            const amt = b & 0xFF;
            if (amt == 0) {
                setNZ(cpu, a);
            } else if (amt < 32) {
                const sh: u5 = @intCast(amt);
                cpu.cpsr.carry = (a >> @intCast(32 - @as(u32, sh))) & 1 == 1;
                cpu.r[rd] = a << sh;
                setNZ(cpu, cpu.r[rd]);
            } else if (amt == 32) {
                cpu.cpsr.carry = (a & 1) != 0;
                cpu.r[rd] = 0;
                setNZ(cpu, 0);
            } else {
                cpu.cpsr.carry = false;
                cpu.r[rd] = 0;
                setNZ(cpu, 0);
            }
        },
        0x3 => { // LSR Rd, Rs
            const amt = b & 0xFF;
            if (amt == 0) {
                setNZ(cpu, a);
            } else if (amt < 32) {
                const sh: u5 = @intCast(amt);
                cpu.cpsr.carry = (a >> @intCast(@as(u32, sh) - 1)) & 1 == 1;
                cpu.r[rd] = a >> sh;
                setNZ(cpu, cpu.r[rd]);
            } else if (amt == 32) {
                cpu.cpsr.carry = (a >> 31) & 1 == 1;
                cpu.r[rd] = 0;
                setNZ(cpu, 0);
            } else {
                cpu.cpsr.carry = false;
                cpu.r[rd] = 0;
                setNZ(cpu, 0);
            }
        },
        0x4 => { // ASR Rd, Rs
            const amt = b & 0xFF;
            if (amt == 0) {
                setNZ(cpu, a);
            } else if (amt < 32) {
                const sh: u5 = @intCast(amt);
                cpu.cpsr.carry = (a >> @intCast(@as(u32, sh) - 1)) & 1 == 1;
                cpu.r[rd] = @as(u32, @bitCast(@as(i32, @bitCast(a)) >> sh));
                setNZ(cpu, cpu.r[rd]);
            } else {
                const sign = a & 0x8000_0000 != 0;
                cpu.cpsr.carry = sign;
                cpu.r[rd] = if (sign) 0xFFFF_FFFF else 0;
                setNZ(cpu, cpu.r[rd]);
            }
        },
        0x5 => { // ADC
            const c: u32 = @intFromBool(cpu.cpsr.carry);
            const r = a +% b +% c;
            cpu.r[rd] = r;
            setAdcFlags(cpu, a, b, c, r);
        },
        0x6 => { // SBC
            const borrow: u32 = @intFromBool(!cpu.cpsr.carry);
            const r = a -% b -% borrow;
            cpu.r[rd] = r;
            setSbcFlags(cpu, a, b, borrow, r);
        },
        0x7 => { // ROR Rd, Rs
            const amt = b & 0xFF;
            if (amt == 0) {
                setNZ(cpu, a);
            } else if ((amt & 31) == 0) {
                cpu.cpsr.carry = (a >> 31) & 1 == 1;
                setNZ(cpu, a);
            } else {
                const sh: u5 = @intCast(amt & 31);
                const r = std.math.rotr(u32, a, sh);
                cpu.r[rd] = r;
                cpu.cpsr.carry = (r >> 31) & 1 == 1;
                setNZ(cpu, r);
            }
        },
        0x8 => { // TST
            setNZ(cpu, a & b);
        },
        0x9 => { // NEG Rd, Rs  (Rd = 0 - Rs)
            const r = 0 -% b;
            cpu.r[rd] = r;
            setSubFlags(cpu, 0, b, r);
        },
        0xA => { // CMP
            const r = a -% b;
            setSubFlags(cpu, a, b, r);
        },
        0xB => { // CMN
            const r = a +% b;
            setAddFlags(cpu, a, b, r);
        },
        0xC => { // ORR
            const r = a | b;
            cpu.r[rd] = r;
            setNZ(cpu, r);
        },
        0xD => { // MUL
            const r = a *% b;
            cpu.r[rd] = r;
            setNZ(cpu, r);
            // C is UNPREDICTABLE; leave alone.
        },
        0xE => { // BIC
            const r = a & ~b;
            cpu.r[rd] = r;
            setNZ(cpu, r);
        },
        0xF => { // MVN
            const r = ~b;
            cpu.r[rd] = r;
            setNZ(cpu, r);
        },
    }
}

// =====================================================================
// Format 5: Hi register operations / branch exchange
// =====================================================================

pub fn hiRegHandler(cpu: *Cpu, instr: u16) void {
    const op: u2 = @intCast((instr >> 8) & 3);
    const h1: u1 = @intCast((instr >> 7) & 1);
    const h2: u1 = @intCast((instr >> 6) & 1);
    const rd: u4 = @as(u4, @intCast(instr & 7)) | (@as(u4, h1) << 3);
    const rs: u4 = @as(u4, @intCast((instr >> 3) & 7)) | (@as(u4, h2) << 3);
    const a = cpu.r[rd];
    const b = cpu.r[rs];
    switch (op) {
        0 => { // ADD (no flags)
            cpu.r[rd] = a +% b;
            if (rd == 15) {
                cpu.r[15] &= ~@as(u32, 1);
                cpu.reloadPipeline();
            }
        },
        1 => { // CMP (always sets flags)
            const r = a -% b;
            setSubFlags(cpu, a, b, r);
        },
        2 => { // MOV (no flags)
            cpu.r[rd] = b;
            if (rd == 15) {
                cpu.r[15] &= ~@as(u32, 1);
                cpu.reloadPipeline();
            }
        },
        3 => { // BX
            // BX 1 = soft-reset trampoline (see ARM handlers_arm.bx).
            if (b == 1) {
                @import("handlers_arm.zig").softResetExternal(cpu);
                return;
            }
            cpu.cpsr.thumb = (b & 1) != 0;
            cpu.r[15] = b & ~@as(u32, if (cpu.cpsr.thumb) 1 else 3);
            cpu.reloadPipeline();
        },
    }
}

// =====================================================================
// Format 6: PC-relative load
// =====================================================================

pub fn pcRelLoad(cpu: *Cpu, instr: u16) void {
    const rd: u3 = @intCast((instr >> 8) & 7);
    const offset: u32 = (@as(u32, instr) & 0xFF) << 2;
    // r[15] at execute = instr_addr + 4 (ARM ARM Thumb PC). Word-align for the load.
    const base = cpu.r[15] & ~@as(u32, 3);
    cpu.r[rd] = cpu.bus.read(u32, base +% offset);
}

// =====================================================================
// Format 7: Load/store with register offset
// =====================================================================

pub fn loadStoreRegHandler(comptime op: u2) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const ro: u3 = @intCast((instr >> 6) & 7);
            const rb: u3 = @intCast((instr >> 3) & 7);
            const rd: u3 = @intCast(instr & 7);
            const addr = cpu.r[rb] +% cpu.r[ro];
            switch (op) {
                0 => cpu.bus.write(u32, addr & ~@as(u32, 3), cpu.r[rd]), // STR
                1 => cpu.bus.write(u8, addr, @truncate(cpu.r[rd])), // STRB
                2 => { // LDR
                    const aligned = addr & ~@as(u32, 3);
                    const raw = cpu.bus.read(u32, aligned);
                    const rot: u5 = @intCast((addr & 3) * 8);
                    cpu.r[rd] = std.math.rotr(u32, raw, rot);
                },
                3 => cpu.r[rd] = cpu.bus.read(u8, addr), // LDRB
            }
        }
    }.handler;
}

// =====================================================================
// Format 8: Load/store sign-extended byte/halfword (reg offset)
// =====================================================================

pub fn loadStoreSignExtHandler(comptime op: u2) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const ro: u3 = @intCast((instr >> 6) & 7);
            const rb: u3 = @intCast((instr >> 3) & 7);
            const rd: u3 = @intCast(instr & 7);
            const addr = cpu.r[rb] +% cpu.r[ro];
            switch (op) {
                0 => cpu.bus.write(u16, addr & ~@as(u32, 1), @truncate(cpu.r[rd])), // STRH
                1 => { // LDSB
                    const b = cpu.bus.read(u8, addr);
                    cpu.r[rd] = @bitCast(@as(i32, @as(i8, @bitCast(b))));
                },
                2 => { // LDRH
                    const aligned = addr & ~@as(u32, 1);
                    const raw = cpu.bus.read(u16, aligned);
                    if ((addr & 1) != 0) {
                        // Unaligned LDRH rotates by 8 (ARM7TDMI quirk).
                        cpu.r[rd] = std.math.rotr(u32, @as(u32, raw), 8);
                    } else cpu.r[rd] = raw;
                },
                3 => { // LDSH
                    if ((addr & 1) != 0) {
                        // Unaligned LDSH on ARM7TDMI behaves like LDSB on the misaligned byte.
                        const b = cpu.bus.read(u8, addr);
                        cpu.r[rd] = @bitCast(@as(i32, @as(i8, @bitCast(b))));
                    } else {
                        const h = cpu.bus.read(u16, addr);
                        cpu.r[rd] = @bitCast(@as(i32, @as(i16, @bitCast(h))));
                    }
                },
            }
        }
    }.handler;
}

// =====================================================================
// Format 9: Load/store with immediate offset (word/byte)
// =====================================================================

pub fn loadStoreImmHandler(comptime op: u2) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const offset5: u32 = (instr >> 6) & 0x1F;
            const rb: u3 = @intCast((instr >> 3) & 7);
            const rd: u3 = @intCast(instr & 7);
            // Word ops scale offset by 4, byte ops by 1.
            const offset: u32 = switch (op) {
                0, 1 => offset5 << 2,
                2, 3 => offset5,
            };
            const addr = cpu.r[rb] +% offset;
            switch (op) {
                0 => cpu.bus.write(u32, addr & ~@as(u32, 3), cpu.r[rd]), // STR
                1 => { // LDR
                    const aligned = addr & ~@as(u32, 3);
                    const raw = cpu.bus.read(u32, aligned);
                    const rot: u5 = @intCast((addr & 3) * 8);
                    cpu.r[rd] = std.math.rotr(u32, raw, rot);
                },
                2 => cpu.bus.write(u8, addr, @truncate(cpu.r[rd])), // STRB
                3 => cpu.r[rd] = cpu.bus.read(u8, addr), // LDRB
            }
        }
    }.handler;
}

// =====================================================================
// Format 10: Load/store halfword (imm offset)
// =====================================================================

pub fn loadStoreHalfHandler(comptime is_load: bool) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const offset: u32 = ((instr >> 6) & 0x1F) << 1;
            const rb: u3 = @intCast((instr >> 3) & 7);
            const rd: u3 = @intCast(instr & 7);
            const addr = cpu.r[rb] +% offset;
            if (is_load) {
                const aligned = addr & ~@as(u32, 1);
                const raw = cpu.bus.read(u16, aligned);
                if ((addr & 1) != 0) {
                    cpu.r[rd] = std.math.rotr(u32, @as(u32, raw), 8);
                } else cpu.r[rd] = raw;
            } else {
                cpu.bus.write(u16, addr & ~@as(u32, 1), @truncate(cpu.r[rd]));
            }
        }
    }.handler;
}

// =====================================================================
// Format 11: SP-relative load/store
// =====================================================================

pub fn spRelHandler(comptime is_load: bool) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const rd: u3 = @intCast((instr >> 8) & 7);
            const offset: u32 = (@as(u32, instr) & 0xFF) << 2;
            const addr = cpu.r[13] +% offset;
            if (is_load) {
                const aligned = addr & ~@as(u32, 3);
                const raw = cpu.bus.read(u32, aligned);
                const rot: u5 = @intCast((addr & 3) * 8);
                cpu.r[rd] = std.math.rotr(u32, raw, rot);
            } else {
                cpu.bus.write(u32, addr & ~@as(u32, 3), cpu.r[rd]);
            }
        }
    }.handler;
}

// =====================================================================
// Format 12: Load address (ADD Rd, PC/SP, #imm)
// =====================================================================

pub fn loadAddressHandler(comptime is_sp: bool) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const rd: u3 = @intCast((instr >> 8) & 7);
            const offset: u32 = (@as(u32, instr) & 0xFF) << 2;
            const base: u32 = if (is_sp) cpu.r[13] else cpu.r[15] & ~@as(u32, 3);
            cpu.r[rd] = base +% offset;
        }
    }.handler;
}

// =====================================================================
// Format 13: Add offset to SP (signed)
// =====================================================================

pub fn addToSp(cpu: *Cpu, instr: u16) void {
    const offset: u32 = (@as(u32, instr) & 0x7F) << 2;
    if ((instr & 0x80) != 0) {
        cpu.r[13] -%= offset;
    } else {
        cpu.r[13] +%= offset;
    }
}

// =====================================================================
// Format 14: Push / Pop registers (with optional LR/PC)
// =====================================================================

pub fn pushPopHandler(comptime is_pop: bool, comptime has_lr_pc: bool) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const rlist: u8 = @truncate(instr);
            var count: u32 = @popCount(rlist);
            if (has_lr_pc) count += 1;
            if (!is_pop) {
                // PUSH: pre-decrement SP, store from lowest reg upward.
                cpu.r[13] -%= count * 4;
                var sp = cpu.r[13];
                var i: u4 = 0;
                while (i < 8) : (i += 1) {
                    if (((rlist >> @intCast(i)) & 1) != 0) {
                        cpu.bus.write(u32, sp, cpu.r[i]);
                        sp +%= 4;
                    }
                }
                if (has_lr_pc) cpu.bus.write(u32, sp, cpu.r[14]); // store LR
            } else {
                // POP: load from lowest reg upward, post-increment SP.
                var sp = cpu.r[13];
                var i: u4 = 0;
                while (i < 8) : (i += 1) {
                    if (((rlist >> @intCast(i)) & 1) != 0) {
                        cpu.r[i] = cpu.bus.read(u32, sp);
                        sp +%= 4;
                    }
                }
                if (has_lr_pc) {
                    const new_pc = cpu.bus.read(u32, sp);
                    sp +%= 4;
                    cpu.cpsr.thumb = (new_pc & 1) != 0;
                    cpu.r[15] = new_pc & ~@as(u32, if (cpu.cpsr.thumb) 1 else 3);
                    cpu.reloadPipeline();
                }
                cpu.r[13] = sp;
            }
        }
    }.handler;
}

// =====================================================================
// Format 15: Multiple load/store
// =====================================================================

pub fn multipleLoadStoreHandler(comptime is_load: bool) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const rb: u3 = @intCast((instr >> 8) & 7);
            const rlist: u8 = @truncate(instr);
            var addr = cpu.r[rb];
            // Empty list edge case: ARM7TDMI loads/stores R15 and bumps rb by 0x40.
            if (rlist == 0) {
                if (is_load) {
                    cpu.r[15] = cpu.bus.read(u32, addr);
                    cpu.reloadPipeline();
                } else {
                    cpu.bus.write(u32, addr, cpu.r[15] +% 2);
                }
                cpu.r[rb] +%= 0x40;
                return;
            }
            var i: u4 = 0;
            while (i < 8) : (i += 1) {
                if (((rlist >> @intCast(i)) & 1) == 0) continue;
                if (is_load) {
                    cpu.r[i] = cpu.bus.read(u32, addr);
                } else {
                    cpu.bus.write(u32, addr, cpu.r[i]);
                }
                addr +%= 4;
            }
            // Writeback unless LDM with rb in list (loaded value wins).
            const rb_in_list = ((rlist >> @intCast(rb)) & 1) != 0;
            if (!(is_load and rb_in_list)) cpu.r[rb] = addr;
        }
    }.handler;
}

// =====================================================================
// Format 16: Conditional branch
// =====================================================================

pub fn conditionalBranchHandler(comptime cond: u4) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            if (!cpu_mod.checkCondition(cpu.cpsr, cond)) return;
            // target = PC + offset, where r[15] at execute = instr_addr + 4.
            const offset_8: i8 = @bitCast(@as(u8, @truncate(instr)));
            const offset = @as(i32, offset_8) << 1;
            const base: i32 = @bitCast(cpu.r[15]);
            cpu.r[15] = @as(u32, @bitCast(base +% offset));
            cpu.reloadPipeline();
        }
    }.handler;
}

// =====================================================================
// Format 17: SWI (panics until M1.3 wires up exception entry)
// =====================================================================

pub fn thumbSwi(cpu: *Cpu, instr: u16) void {
    const arm = @import("handlers_arm.zig");
    const swi_num: u8 = @truncate(instr & 0xFF);
    // Always HLE CpuSet/CpuFastSet (see ARM swi() for rationale).
    if (swi_num == 0x0B or swi_num == 0x0C) {
        _ = arm.hleSwiForThumb(cpu, swi_num);
        return;
    }
    if (cpu.hle_swi and arm.hleSwiForThumb(cpu, swi_num)) return;
    // Thumb SWI: LR_svc = next Thumb instruction = current + 2.
    arm.enterException(cpu, .svc, 0x08, 2);
}

// =====================================================================
// Format 18: Unconditional branch
// =====================================================================

pub fn unconditionalBranch(cpu: *Cpu, instr: u16) void {
    const raw: i32 = @as(i32, @bitCast(@as(u32, instr & 0x7FF) << 21)) >> 20;
    const base: i32 = @bitCast(cpu.r[15]);
    cpu.r[15] = @as(u32, @bitCast(base +% raw));
    cpu.reloadPipeline();
}

// =====================================================================
// Format 19: Long branch with link
// =====================================================================

pub fn longBranchHandler(comptime is_high: bool) decode.ThumbFn {
    return struct {
        fn handler(cpu: *Cpu, instr: u16) void {
            const offset11: u32 = instr & 0x7FF;
            if (!is_high) {
                // First half: LR = PC + (sign_ext(offset11) << 12).
                const signed: i32 = @as(i32, @bitCast(offset11 << 21)) >> 9;
                cpu.r[14] = @as(u32, @bitCast(@as(i32, @bitCast(cpu.r[15])) +% signed));
            } else {
                // Second half: PC = LR + (offset11 << 1).
                // New LR = address of next instr | 1 = (r[15] - 2) | 1.
                const next_pc = cpu.r[14] +% (offset11 << 1);
                cpu.r[14] = (cpu.r[15] -% 2) | 1;
                cpu.r[15] = next_pc;
                cpu.reloadPipeline();
            }
        }
    }.handler;
}

// ---- tests ----

const Bus = @import("../core/bus.zig").Bus;

test "Thumb LSL immediate" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[1] = 1;
    const handler = comptime moveShiftedRegHandler(0);
    handler(&cpu, 0x0108);
    try std.testing.expectEqual(@as(u32, 16), cpu.r[0]);
    try std.testing.expect(!cpu.cpsr.zero);
}

test "Thumb MOV imm8 sets Z when zero" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    const handler = comptime movCmpAddSubImmHandler(0);
    handler(&cpu, 0x2000);
    try std.testing.expect(cpu.cpsr.zero);
    handler(&cpu, 0x2042);
    try std.testing.expectEqual(@as(u32, 0x42), cpu.r[0]);
    try std.testing.expect(!cpu.cpsr.zero);
}

test "Thumb ADD imm3" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[1] = 10;
    const handler = comptime addSubHandler(false, true);
    handler(&cpu, 0x1D48);
    try std.testing.expectEqual(@as(u32, 15), cpu.r[0]);
}

test "Thumb ALU AND" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[0] = 0xFF00;
    cpu.r[1] = 0x0F0F;
    // AND r0, r1 → 0x0F00. opcode 0x4000 = 010000_0000_001_000
    aluHandler(&cpu, 0x4008);
    try std.testing.expectEqual(@as(u32, 0x0F00), cpu.r[0]);
}

test "Thumb hi-reg MOV" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[14] = 0xDEAD_BEEF;
    // MOV r0, r14 — 010001_10_0_1_110_000 = 0x4670
    hiRegHandler(&cpu, 0x4670);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.r[0]);
}

test "Thumb push/pop round-trip" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[13] = 0x0300_7F00;
    cpu.r[0] = 0xAAAA;
    cpu.r[1] = 0xBBBB;
    cpu.r[14] = 0xCCCC_DDDD;
    // PUSH {r0, r1, lr} — 1011010_1_00000011 = 0xB503
    const push = comptime pushPopHandler(false, true);
    push(&cpu, 0xB503);
    try std.testing.expectEqual(@as(u32, 0x0300_7F00 - 12), cpu.r[13]);
    // Clobber regs, then POP {r0, r1, pc}.
    cpu.r[0] = 0;
    cpu.r[1] = 0;
    const pop = comptime pushPopHandler(true, true);
    pop(&cpu, 0xBD03);
    try std.testing.expectEqual(@as(u32, 0xAAAA), cpu.r[0]);
    try std.testing.expectEqual(@as(u32, 0xBBBB), cpu.r[1]);
    // SP back to its pre-push value.
    try std.testing.expectEqual(@as(u32, 0x0300_7F00), cpu.r[13]);
}

test "Thumb load/store imm word" {
    var bus: Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[0] = 0xCAFE_BABE;
    cpu.r[1] = 0x0300_0100;
    // STR r0, [r1, #0] — 011_00_00000_001_000 = 0x6008
    const str = comptime loadStoreImmHandler(0);
    str(&cpu, 0x6008);
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), bus.read(u32, 0x0300_0100));
    cpu.r[0] = 0;
    const ldr = comptime loadStoreImmHandler(1);
    ldr(&cpu, 0x6808); // LDR r0, [r1, #0]
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), cpu.r[0]);
}
