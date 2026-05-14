//! AArch64 native-code emitter for the JIT block cache.
//!
//! Translates a subset of ARM7TDMI instructions into AArch64 machine
//! code that operates on the `Cpu` struct passed in `x0`. Unsupported
//! instructions fall through to the interpreter handler embedded in
//! the block.
//!
//! Supported translations (initial):
//!   - ARM `MOV Rd, #imm8` (no rotate, no S-bit, cond=AL)
//!     → AArch64: STR W1, [X0, #r_offset]  (with W1 holding the imm)
//!   - Block exit (RET)
//!
//! Allocation: uses mmap with MAP_JIT on Darwin (works under hardened
//! runtime when running unsigned-dev binaries). Code pages are flipped
//! between writable and executable via `pthread_jit_write_protect_np`.
//! Instruction cache is flushed via `sys_icache_invalidate` before
//! invoking the compiled block.

const std = @import("std");
const builtin = @import("builtin");
const Cpu = @import("arm7tdmi.zig").Cpu;
const decode = @import("decode.zig");

// ----------------------------------------------------------------------
// Darwin / Linux JIT page management
// ----------------------------------------------------------------------

const PROT_NONE: c_int = 0;
const PROT_READ: c_int = 1;
const PROT_WRITE: c_int = 2;
const PROT_EXEC: c_int = 4;
const MAP_PRIVATE: c_int = 0x0002;
const MAP_ANON: c_int = 0x1000;
const MAP_FAILED: usize = std.math.maxInt(usize);
// Darwin-only flag for JIT pages under hardened runtime.
const MAP_JIT: c_int = 0x0800;

extern fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: c_long) ?*anyopaque;
extern fn munmap(addr: *anyopaque, len: usize) c_int;
extern fn mprotect(addr: *anyopaque, len: usize, prot: c_int) c_int;
extern fn sys_icache_invalidate(start: *anyopaque, len: usize) void;
extern fn pthread_jit_write_protect_np(enabled: c_int) void;

const PAGE_SIZE: usize = 16384; // Apple Silicon uses 16 KB pages.

pub const NativeFn = *const fn (cpu: *Cpu) callconv(.c) void;

/// One JIT page, with a bump pointer for new blocks.
pub const CodePage = struct {
    mem: [*]u8,
    len: usize,
    used: usize = 0,

    pub fn alloc() ?CodePage {
        const flags: c_int = MAP_PRIVATE | MAP_ANON | (if (builtin.os.tag == .macos) MAP_JIT else 0);
        const p = mmap(null, PAGE_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC, flags, -1, 0) orelse return null;
        const as_usize = @intFromPtr(p);
        if (as_usize == MAP_FAILED) return null;
        return .{ .mem = @ptrCast(p), .len = PAGE_SIZE };
    }

    pub fn free(self: *CodePage) void {
        _ = munmap(self.mem, self.len);
    }
};

/// Emitter writes 32-bit AArch64 instructions to a buffer.
pub const Emitter = struct {
    buf: [*]u8,
    cap: usize,
    pos: usize = 0,

    pub fn write(self: *Emitter, instr: u32) void {
        if (self.pos + 4 > self.cap) return;
        const bytes: [4]u8 = .{
            @truncate(instr),
            @truncate(instr >> 8),
            @truncate(instr >> 16),
            @truncate(instr >> 24),
        };
        @memcpy(self.buf[self.pos..][0..4], &bytes);
        self.pos += 4;
    }

    /// MOVZ Wd, #imm16 (zero other halves of the destination).
    /// Encoding: `0x52800000 | (imm16 << 5) | Wd`.
    pub fn movzW(self: *Emitter, wd: u5, imm16: u16) void {
        self.write(0x52800000 | (@as(u32, imm16) << 5) | @as(u32, wd));
    }

    /// MOVK Wd, #imm16, LSL #shift — keep other halves intact.
    /// Encoding: `0x72800000 | (hw << 21) | (imm16 << 5) | Wd`, where
    /// hw = shift / 16 (0 or 1 for 32-bit).
    pub fn movkW(self: *Emitter, wd: u5, imm16: u16, shift: u5) void {
        const hw: u32 = shift / 16;
        self.write(0x72800000 | (hw << 21) | (@as(u32, imm16) << 5) | @as(u32, wd));
    }

    /// STR Wt, [Xn, #imm12*4] — unsigned-offset store of a 32-bit value.
    /// Encoding: `0xB9000000 | ((imm12) << 10) | (Xn << 5) | Wt`.
    pub fn strWImmU(self: *Emitter, wt: u5, xn: u5, byte_off: u14) void {
        const imm12: u32 = @intCast(byte_off >> 2);
        self.write(0xB9000000 | (imm12 << 10) | (@as(u32, xn) << 5) | @as(u32, wt));
    }

    /// RET — branch to address in X30 (LR).
    pub fn ret(self: *Emitter) void {
        self.write(0xD65F03C0);
    }

    /// MOVZ Xd, #imm16, LSL #shift — 64-bit version.
    pub fn movzX(self: *Emitter, xd: u5, imm16: u16, shift: u6) void {
        const hw: u32 = shift / 16;
        self.write(0xD2800000 | (hw << 21) | (@as(u32, imm16) << 5) | @as(u32, xd));
    }

    /// MOVK Xd, #imm16, LSL #shift — 64-bit keep.
    pub fn movkX(self: *Emitter, xd: u5, imm16: u16, shift: u6) void {
        const hw: u32 = shift / 16;
        self.write(0xF2800000 | (hw << 21) | (@as(u32, imm16) << 5) | @as(u32, xd));
    }

    /// Load a 64-bit immediate into Xd in up to four halfword moves.
    pub fn loadX(self: *Emitter, xd: u5, value: u64) void {
        self.movzX(xd, @truncate(value), 0);
        if ((value >> 16) & 0xFFFF != 0) self.movkX(xd, @truncate(value >> 16), 16);
        if ((value >> 32) & 0xFFFF != 0) self.movkX(xd, @truncate(value >> 32), 32);
        if ((value >> 48) & 0xFFFF != 0) self.movkX(xd, @truncate(value >> 48), 48);
    }

    /// BLR Xn — call function at the address in Xn.
    pub fn blr(self: *Emitter, xn: u5) void {
        self.write(0xD63F0000 | (@as(u32, xn) << 5));
    }

    /// MOV Xd, Xm — alias of ORR Xd, XZR, Xm.
    pub fn movXX(self: *Emitter, xd: u5, xm: u5) void {
        self.write(0xAA0003E0 | (@as(u32, xm) << 16) | @as(u32, xd));
    }

    /// SUB SP, SP, #imm12.
    pub fn subSpImm(self: *Emitter, imm12: u12) void {
        self.write(0xD10003FF | (@as(u32, imm12) << 10));
    }

    /// ADD SP, SP, #imm12.
    pub fn addSpImm(self: *Emitter, imm12: u12) void {
        self.write(0x910003FF | (@as(u32, imm12) << 10));
    }

    /// STR Xt, [SP, #imm12*8] — 64-bit store, unsigned offset.
    pub fn strXImmU(self: *Emitter, xt: u5, byte_off: u15) void {
        const imm12: u32 = @intCast(byte_off >> 3);
        self.write(0xF90003E0 | (imm12 << 10) | @as(u32, xt));
    }

    /// LDR Xt, [SP, #imm12*8].
    pub fn ldrXImmU(self: *Emitter, xt: u5, byte_off: u15) void {
        const imm12: u32 = @intCast(byte_off >> 3);
        self.write(0xF94003E0 | (imm12 << 10) | @as(u32, xt));
    }
};

/// Translate a single ARM instruction. Returns true if translation
/// emitted; false means the caller should fall back to the interpreter.
pub fn translateArm(em: *Emitter, instr: u32) bool {
    // Condition = AL (always). Bits 31-28 = 0xE.
    if ((instr >> 28) != 0xE) return false;

    // Data-processing immediate: bits 27-25 = 001.
    if (((instr >> 25) & 0x7) == 0b001) {
        const opcode: u4 = @intCast((instr >> 21) & 0xF);
        const set_flags = ((instr >> 20) & 1) != 0;
        const rd: u4 = @intCast((instr >> 12) & 0xF);
        const rotate: u4 = @intCast((instr >> 8) & 0xF);
        const imm_field: u32 = instr & 0xFF;
        // We only handle: no flags, no rotate, Rd != PC, imm fits u16.
        if (set_flags or rotate != 0 or rd == 15 or imm_field > 0xFFFF) return false;

        const r_base: u14 = comptime @intCast(@offsetOf(Cpu, "r"));
        const off: u14 = r_base + @as(u14, rd) * 4;

        switch (opcode) {
            0b1101 => { // MOV Rd, #imm
                em.movzW(1, @intCast(imm_field));
                em.strWImmU(1, 0, off);
                return true;
            },
            0b1111 => { // MVN Rd, #imm  (Rd = ~imm)
                em.movzW(1, @intCast(imm_field ^ 0xFFFF)); // low 16 bits inverted
                em.movkW(1, 0xFFFF, 16); // upper 16 bits all-ones
                em.strWImmU(1, 0, off);
                return true;
            },
            else => return false,
        }
    }
    return false;
}

/// C-ABI trampoline so the JIT-emitted call site can use AAPCS64
/// register passing (X0=cpu, X1=instr) regardless of how Zig chooses
/// to pass args to its `.auto`-convention handlers.
pub fn callArmHandler(cpu: *Cpu, instr: u32) callconv(.c) void {
    const hash: u12 = @intCast(((instr >> 16) & 0xFF0) | ((instr >> 4) & 0x00F));
    decode.arm_lut[hash](cpu, instr);
}

/// Compile a sequence of ARM instructions into a function-pointer that
/// executes the whole block. Recognized instructions emit native code;
/// unrecognized ones emit a call to the interpreter handler — making
/// instruction coverage *complete*, just with varying speedup.
///
/// Function shape:
///   fn(cpu: *Cpu) void
/// Body shape (per instruction):
///   if native: emit translation
///   else:      emit MOV X0, X19 / MOVZ X1, instr / loadX X16, &handler / BLR X16
pub fn compileBlock(page: *CodePage, instrs: []const u32) ?NativeFn {
    if (page.used + 64 + instrs.len * 32 > page.len) return null;
    if (builtin.os.tag == .macos) pthread_jit_write_protect_np(0);
    defer if (builtin.os.tag == .macos) pthread_jit_write_protect_np(1);

    var em = Emitter{ .buf = page.mem + page.used, .cap = page.len - page.used };
    const start = page.mem + page.used;

    // Prologue: stash X19 + LR, then keep CPU pointer in X19.
    em.subSpImm(16);
    em.strXImmU(19, 0);
    em.strXImmU(30, 8);
    em.movXX(19, 0);

    for (instrs) |instr| {
        if (translateArm(&em, instr)) {
            // Native translation done.
        } else {
            // Fall back to interpreter via the C-ABI trampoline.
            em.movXX(0, 19); // X0 = cpu pointer
            em.movzX(1, @truncate(instr & 0xFFFF), 0);
            if ((instr >> 16) & 0xFFFF != 0) em.movkX(1, @truncate(instr >> 16), 16);
            em.loadX(16, @intFromPtr(&callArmHandler));
            em.blr(16);
        }
    }

    // Epilogue.
    em.ldrXImmU(19, 0);
    em.ldrXImmU(30, 8);
    em.addSpImm(16);
    em.ret();

    page.used += em.pos;
    sys_icache_invalidate(start, em.pos);
    return @ptrCast(@alignCast(start));
}

/// Compile one ARM instruction into a callable function pointer. Used
/// by tests and as a building block for full-block JIT.
pub fn compileSingle(page: *CodePage, instr: u32) ?NativeFn {
    if (page.used + 16 > page.len) return null;
    // Enter write mode (Apple Silicon hardened JIT requires this).
    if (builtin.os.tag == .macos) pthread_jit_write_protect_np(0);
    var em = Emitter{ .buf = page.mem + page.used, .cap = page.len - page.used };
    if (!translateArm(&em, instr)) {
        if (builtin.os.tag == .macos) pthread_jit_write_protect_np(1);
        return null;
    }
    em.ret();
    const start = page.mem + page.used;
    const len = em.pos;
    page.used += len;
    if (builtin.os.tag == .macos) pthread_jit_write_protect_np(1);
    sys_icache_invalidate(start, len);
    return @ptrCast(@alignCast(start));
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

test "JIT compiles ARM MOV r5, #42 and executes" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var page = CodePage.alloc() orelse return;
    defer page.free();

    // ARM: MOV r5, #42 → cond=E, op=001, opcode=1101, S=0, Rn=0, Rd=5, rot=0, imm=42
    // Encoding: 0xE3A0_502A = 1110_0011_1010_0000_0101_0000_0010_1010
    const fn_ptr = compileSingle(&page, 0xE3A0_502A) orelse return error.JitNotSupported;

    var bus: @import("../core/bus.zig").Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[5] = 0xCAFE; // pre-set to a sentinel
    fn_ptr(&cpu);
    try std.testing.expectEqual(@as(u32, 42), cpu.r[5]);
}

test "JIT refuses unsupported instructions" {
    var page = CodePage.alloc() orelse return;
    defer page.free();
    // ARM: SUB r0, r1, r2 (data-proc register, not immediate)
    const fn_ptr = compileSingle(&page, 0xE041_0002);
    try std.testing.expect(fn_ptr == null);
}

test "JIT block: native MOV + interpreter-fallback ADD" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var page = CodePage.alloc() orelse return;
    defer page.free();

    // Instr 1: ARM MOV r5, #42 — native translation.
    // Instr 2: ARM ADD r6, r5, #8 — falls back to interpreter handler.
    //   Encoding: cond=E, op=001, opcode=0100=ADD, S=0, Rn=5, Rd=6, rot=0, imm=8
    //   = 1110_0010_1000_0101_0110_0000_0000_1000 = 0xE285_6008
    const block = [_]u32{ 0xE3A0_502A, 0xE285_6008 };
    const fn_ptr = compileBlock(&page, &block) orelse return error.JitNotSupported;

    var bus: @import("../core/bus.zig").Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[5] = 0;
    cpu.r[6] = 0;
    fn_ptr(&cpu);
    try std.testing.expectEqual(@as(u32, 42), cpu.r[5]);
    try std.testing.expectEqual(@as(u32, 50), cpu.r[6]);
}

test "JIT compiles ARM MVN r3, #0 and executes" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    var page = CodePage.alloc() orelse return;
    defer page.free();

    // ARM: MVN r3, #0 → cond=E, op=001, opcode=1111, S=0, Rd=3, rot=0, imm=0
    // Should set r[3] = ~0 = 0xFFFFFFFF.
    // Encoding: 1110_0011_1110_0000_0011_0000_0000_0000 = 0xE3E0_3000
    const fn_ptr = compileSingle(&page, 0xE3E0_3000) orelse return error.JitNotSupported;
    var bus: @import("../core/bus.zig").Bus = .{};
    var cpu = Cpu.init(&bus);
    cpu.r[3] = 0x1234;
    fn_ptr(&cpu);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), cpu.r[3]);
}
