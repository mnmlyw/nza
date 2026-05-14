//! Comptime-generated ARM7TDMI instruction dispatch tables.
//!
//! Mirrors NanoBoyAdvance's `tablegen.cc` approach: each entry in the LUT is
//! a function pointer specialized for the corresponding decode hash. The
//! dispatch hash for ARM is a 12-bit value pulled from bits 27..20 and 7..4
//! of the instruction; for Thumb it's just bits 15..6.

const std = @import("std");
const cpu_mod = @import("arm7tdmi.zig");
const Cpu = cpu_mod.Cpu;

const arm_handlers = @import("handlers_arm.zig");
const thumb_handlers = @import("handlers_thumb.zig");

pub const ArmFn = *const fn (cpu: *Cpu, instr: u32) void;
pub const ThumbFn = *const fn (cpu: *Cpu, instr: u16) void;

/// Counter so we don't flood stderr if the CPU runs off the rails.
var unhandled_printed: u32 = 0;
const UNHANDLED_PRINT_LIMIT: u32 = 8;

fn unhandledArm(cpu: *Cpu, instr: u32) void {
    if (unhandled_printed < UNHANDLED_PRINT_LIMIT) {
        std.debug.print("unhandled ARM instr 0x{x:0>8} at PC=0x{x:0>8}\n", .{ instr, cpu.r[15] -% 8 });
        unhandled_printed += 1;
    }
}

fn unhandledThumb(cpu: *Cpu, instr: u16) void {
    if (unhandled_printed < UNHANDLED_PRINT_LIMIT) {
        std.debug.print("unhandled Thumb instr 0x{x:0>4} at PC=0x{x:0>8}\n", .{ instr, cpu.r[15] -% 4 });
        unhandled_printed += 1;
    }
}

/// Resolve a 12-bit ARM hash to the appropriate handler. Run at comptime.
/// Hash layout: bits[11:4] = instr[27:20], bits[3:0] = instr[7:4].
fn resolveArm(comptime hash: u12) ArmFn {
    const top: u8 = @intCast(hash >> 4);
    const low: u4 = @intCast(hash & 0xF);

    // ----- 0b101x_xxxx — Branch / Branch with Link -----
    if ((top & 0b1110_0000) == 0b1010_0000) {
        const link = (top & 0b0001_0000) != 0;
        return comptime arm_handlers.branchHandler(link);
    }

    // ----- 0b1111_xxxx — Software Interrupt -----
    if ((top & 0b1111_0000) == 0b1111_0000) {
        return arm_handlers.swi;
    }

    // ----- 0b100x_xxxx — Block Data Transfer (LDM/STM) -----
    if ((top & 0b1110_0000) == 0b1000_0000) {
        return comptime arm_handlers.blockTransferHandler(top);
    }

    // ----- 0b01xx_xxxx — Single Data Transfer -----
    if ((top & 0b1100_0000) == 0b0100_0000) {
        const reg_offset = (top & 0b0010_0000) != 0;
        if (reg_offset and (low & 0b0001) != 0) return unhandledArm;
        return comptime arm_handlers.singleDataTransferHandler(top, low);
    }

    // ----- 0b00xx_xxxx — Data Processing, Multiply, PSR transfer, etc. -----
    if ((top & 0b1100_0000) == 0b0000_0000) {
        const imm_operand = (top & 0b0010_0000) != 0;

        // BX Rn — exactly top=0x12, low=0x1.
        if (top == 0x12 and low == 0x1) {
            return arm_handlers.bx;
        }

        if (!imm_operand) {
            // Misc instruction space: bit 4 = 1 AND bit 7 = 1.
            // Low nibble pattern: 1xx1.
            if ((low & 0b1001) == 0b1001) {
                // Multiply or multiply-long: low == 0b1001 and top[7..3] == 00000 or 00001.
                if (low == 0b1001) {
                    if ((top & 0b1111_1100) == 0b0000_0000) {
                        // MUL/MLA (32x32 → 32). top = 0000_00_AS.
                        return comptime arm_handlers.mulHandler(@as(u4, @intCast(top & 0b0011)));
                    }
                    if ((top & 0b1111_1000) == 0b0000_1000) {
                        // Multiply long (UMULL/UMLAL/SMULL/SMLAL). top = 0000_1_UAS.
                        return comptime arm_handlers.mulLongHandler(@as(u3, @intCast(top & 0b0111)));
                    }
                    // SWP / SWPB: top = 0001_0000 (word) / 0001_0100 (byte).
                    if (top == 0b0001_0000) return comptime arm_handlers.swpHandler(false);
                    if (top == 0b0001_0100) return comptime arm_handlers.swpHandler(true);
                    return unhandledArm;
                }
                // Halfword/signed transfer: low ∈ {1011, 1101, 1111}.
                // SH = bits 6..5 of instruction = low[2..1].
                const sh: u2 = @intCast((low >> 1) & 0b11);
                if (sh == 0) return unhandledArm; // SWP already routed above
                return comptime arm_handlers.halfwordTransferHandler(top, sh);
            }
            // PSR transfer (MRS/MSR register) sits in the "data proc with
            // opcode TST/TEQ/CMP/CMN and S=0" coding hole. Patterns:
            //   MRS:        00010_P_00, low = 0000 (top in {0x10, 0x14})
            //   MSR (reg):  00010_P_10, low = 0000 (top in {0x12, 0x16})
            // Mask out both the P bit (bit 2) and the MSR/MRS flag (bit 1).
            if (low == 0 and (top & 0b1111_1001) == 0b0001_0000) {
                const is_msr = (top & 0b0000_0010) != 0;
                const use_spsr = (top & 0b0000_0100) != 0;
                return comptime arm_handlers.psrTransferHandler(is_msr, use_spsr, false);
            }
        } else {
            // I=1 branch — MSR-immediate also lives here.
            //   MSR (imm): 00110_PR_10, low = anything.
            if ((top & 0b1111_1011) == 0b0011_0010) {
                const use_spsr = (top & 0b0000_0100) != 0;
                return comptime arm_handlers.psrTransferHandler(true, use_spsr, true);
            }
        }

        return comptime arm_handlers.dataProcHandler(top, low);
    }

    return unhandledArm;
}

/// Resolve a 10-bit Thumb index (instr[15:6]) to a handler.
fn resolveThumb(comptime idx: u10) ThumbFn {
    const top6: u6 = @intCast(idx >> 4);
    const top5: u5 = @intCast(idx >> 5);

    // ----- 19: Long branch with link (1111_x_x) -----
    if ((top5 & 0b11110) == 0b11110) {
        const is_high = (top5 & 0b00001) != 0;
        return comptime thumb_handlers.longBranchHandler(is_high);
    }
    // ----- 18: Unconditional branch (11100x) -----
    if ((top5 & 0b11111) == 0b11100) {
        return thumb_handlers.unconditionalBranch;
    }
    // ----- 17: SWI (instr[15..8] = 11011111) -----
    if (top6 == 0b110111 and ((idx >> 2) & 0b11) == 0b11) {
        return thumb_handlers.thumbSwi;
    }
    // ----- 16: Conditional branch (1101_cccc with cccc != 1111) -----
    if ((top6 & 0b111100) == 0b110100) {
        const cond: u4 = @intCast((idx >> 2) & 0xF);
        return comptime thumb_handlers.conditionalBranchHandler(cond);
    }
    // ----- 15: Multiple load/store (1100_L) -----
    if ((top6 & 0b111100) == 0b110000) {
        const is_load = (top6 & 0b000010) != 0;
        return comptime thumb_handlers.multipleLoadStoreHandler(is_load);
    }
    // ----- 13/14: SP-related (1011_xxxx) -----
    if ((top6 & 0b111100) == 0b101100) {
        // Format 13: 10110000_S (top6 = 0x2C, idx[3..2] = 00)
        if (top6 == 0b101100 and ((idx >> 2) & 0b11) == 0b00) {
            return thumb_handlers.addToSp;
        }
        // Format 14: 1011_L_10_R (top6[0] = 1, idx[3] = 0)
        if ((top6 & 0b000001) == 0b000001 and (idx & (1 << 3)) == 0) {
            const is_pop = (top6 & 0b000010) != 0;
            const has_lr_pc = (idx & (1 << 2)) != 0;
            return comptime thumb_handlers.pushPopHandler(is_pop, has_lr_pc);
        }
        return unhandledThumb;
    }
    // ----- 12: Load address (1010_SP_x) -----
    if ((top6 & 0b111100) == 0b101000) {
        const is_sp = (top6 & 0b000010) != 0;
        return comptime thumb_handlers.loadAddressHandler(is_sp);
    }
    // ----- 11: SP-relative load/store (1001_L_x) -----
    if ((top6 & 0b111100) == 0b100100) {
        const is_load = (top6 & 0b000010) != 0;
        return comptime thumb_handlers.spRelHandler(is_load);
    }
    // ----- 10: Load/store halfword (1000_L_x) -----
    if ((top6 & 0b111100) == 0b100000) {
        const is_load = (top6 & 0b000010) != 0;
        return comptime thumb_handlers.loadStoreHalfHandler(is_load);
    }
    // ----- 9: Load/store imm offset (011_BL_x) -----
    if ((top6 & 0b111000) == 0b011000) {
        const op: u2 = @intCast((top6 >> 1) & 0b11);
        return comptime thumb_handlers.loadStoreImmHandler(op);
    }
    // ----- 7/8: Load/store reg offset / sign-ext (0101_xx) -----
    if ((top6 & 0b111100) == 0b010100) {
        // op bits = instr[11:10] = top6[1:0] (L is bit 11 / MSB of op).
        const op: u2 = @intCast(top6 & 0b11);
        if ((idx & (1 << 3)) != 0) {
            return comptime thumb_handlers.loadStoreSignExtHandler(op);
        }
        return comptime thumb_handlers.loadStoreRegHandler(op);
    }
    // ----- 6: PC-relative load (01001_x) -----
    if ((top6 & 0b111110) == 0b010010) {
        return thumb_handlers.pcRelLoad;
    }
    // ----- 5: Hi register / BX (010001) -----
    if (top6 == 0b010001) {
        return thumb_handlers.hiRegHandler;
    }
    // ----- 4: ALU operations (010000) -----
    if (top6 == 0b010000) {
        return thumb_handlers.aluHandler;
    }
    // ----- 3: MOV/CMP/ADD/SUB imm (001_oo_x) -----
    if ((top6 & 0b111000) == 0b001000) {
        const op: u2 = @intCast((top6 >> 1) & 0b11);
        return comptime thumb_handlers.movCmpAddSubImmHandler(op);
    }
    // ----- 1/2: 000_xx_x -----
    if ((top6 & 0b111000) == 0b000000) {
        const sub_op: u2 = @intCast((top6 >> 1) & 0b11);
        if (sub_op != 0b11) {
            return comptime thumb_handlers.moveShiftedRegHandler(sub_op);
        }
        // Format 2: ADD/SUB. is_imm = bit 10 (= top6[0]), is_sub = bit 9 (= idx[3]).
        const is_imm = (top6 & 0b000001) != 0;
        const is_sub = (idx & (1 << 3)) != 0;
        return comptime thumb_handlers.addSubHandler(is_sub, is_imm);
    }

    return unhandledThumb;
}

pub const arm_lut: [4096]ArmFn = blk: {
    @setEvalBranchQuota(4_000_000);
    var table: [4096]ArmFn = undefined;
    var i: usize = 0;
    while (i < 4096) : (i += 1) {
        table[i] = resolveArm(@as(u12, @intCast(i)));
    }
    break :blk table;
};

pub const thumb_lut: [1024]ThumbFn = blk: {
    @setEvalBranchQuota(4_000_000);
    var table: [1024]ThumbFn = undefined;
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        table[i] = resolveThumb(@as(u10, @intCast(i)));
    }
    break :blk table;
};

test "arm_lut and thumb_lut compile" {
    try std.testing.expect(arm_lut.len == 4096);
    try std.testing.expect(thumb_lut.len == 1024);
}
