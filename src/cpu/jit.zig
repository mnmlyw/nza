//! Block-cached recompiler infrastructure.
//!
//! Walks ARM/Thumb code in basic-block chunks (instructions up to and
//! including the first branch, jump, return, or mode-switch), caches
//! pre-decoded handler pointers, and dispatches them in a tight loop
//! that bypasses the LUT lookup on every instruction.
//!
//! This is *not* a true native-code JIT — handlers still run as
//! function pointers from the interpreter. But it captures the JIT
//! architecture (basic-block scanning, code cache, invalidation on
//! ROM/RAM writes) and is the foundation for a future native emitter.
//!
//! Cache is keyed by entry-PC and CPU mode (ARM vs Thumb). On a hit,
//! the cached block executes a vector of pre-resolved handlers. On a
//! miss, the recompiler scans forward to the first control-flow
//! instruction and stores the block.

const std = @import("std");
const Cpu = @import("arm7tdmi.zig").Cpu;
const decode = @import("decode.zig");

/// Maximum instructions per basic block. Branches/jumps end the block
/// earlier than this; the cap just bounds worst-case linear scans.
const MAX_BLOCK_LEN: usize = 64;

/// Cached block: a sequence of (instruction, handler) pairs plus the
/// fall-through PC for blocks that don't end in a branch.
pub const Block = struct {
    arm_mode: bool,
    len: u8,
    /// Raw instruction words (ARM = u32, Thumb fits in low 16 bits).
    instrs: [MAX_BLOCK_LEN]u32 = [_]u32{0} ** MAX_BLOCK_LEN,
    arm_handlers: [MAX_BLOCK_LEN]decode.ArmFn = undefined,
    thumb_handlers: [MAX_BLOCK_LEN]decode.ThumbFn = undefined,
};

/// Open-addressing hash map (power-of-two slots).
pub const Cache = struct {
    slots: []Slot,
    allocator: std.mem.Allocator,
    enabled: bool = false,

    const CAPACITY = 1024;

    const Slot = struct {
        key: u64 = 0,  // (pc << 1) | thumb_mode
        block: Block = undefined,
        used: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) !Cache {
        const slots = try allocator.alloc(Slot, CAPACITY);
        for (slots) |*s| s.* = .{};
        return .{ .slots = slots, .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.slots);
    }

    pub fn invalidate(self: *Cache) void {
        for (self.slots) |*s| s.used = false;
    }

    pub fn lookup(self: *Cache, pc: u32, thumb: bool) ?*Block {
        const key = (@as(u64, pc) << 1) | (if (thumb) @as(u64, 1) else 0);
        const idx = std.hash.uint32(pc) & (CAPACITY - 1);
        var probe: usize = 0;
        while (probe < 8) : (probe += 1) {
            const i = (idx + probe) & (CAPACITY - 1);
            if (!self.slots[i].used) return null;
            if (self.slots[i].key == key) return &self.slots[i].block;
        }
        return null;
    }

    /// Insert (or replace) a block at the bucket for `pc`.
    pub fn insert(self: *Cache, pc: u32, thumb: bool, block: Block) void {
        const key = (@as(u64, pc) << 1) | (if (thumb) @as(u64, 1) else 0);
        const idx = std.hash.uint32(pc) & (CAPACITY - 1);
        var probe: usize = 0;
        while (probe < 8) : (probe += 1) {
            const i = (idx + probe) & (CAPACITY - 1);
            if (!self.slots[i].used or self.slots[i].key == key) {
                self.slots[i] = .{ .key = key, .block = block, .used = true };
                return;
            }
        }
        // Eviction: stomp on the bucket.
        self.slots[idx] = .{ .key = key, .block = block, .used = true };
    }
};

/// Compile a basic block by linear scanning until the first control-flow
/// instruction. Caller passes the CPU's reader callback so we can pull
/// instruction words from the bus without coupling to it here.
pub fn compile(
    arm_mode: bool,
    start_pc: u32,
    read_u32: *const fn (addr: u32) u32,
    read_u16: *const fn (addr: u32) u16,
) Block {
    var block: Block = .{ .arm_mode = arm_mode, .len = 0 };
    var pc = start_pc;
    var i: u8 = 0;
    while (i < MAX_BLOCK_LEN) : (i += 1) {
        if (arm_mode) {
            const instr = read_u32(pc);
            block.instrs[i] = instr;
            const hash: u12 = @intCast(((instr >> 16) & 0xFF0) | ((instr >> 4) & 0x00F));
            block.arm_handlers[i] = decode.arm_lut[hash];
            // Control-flow detection: B/BL (bits 27-25=101), BX (cond100100*),
            // LDR PC, LDM with PC in list, MOV pc/r15.
            if (isArmControlFlow(instr)) {
                block.len = i + 1;
                return block;
            }
            pc +%= 4;
        } else {
            const instr16 = read_u16(pc);
            block.instrs[i] = instr16;
            const idx: u10 = @intCast((instr16 >> 6) & 0x3FF);
            block.thumb_handlers[i] = decode.thumb_lut[idx];
            if (isThumbControlFlow(instr16)) {
                block.len = i + 1;
                return block;
            }
            pc +%= 2;
        }
    }
    block.len = MAX_BLOCK_LEN;
    return block;
}

fn isArmControlFlow(instr: u32) bool {
    const top: u3 = @intCast((instr >> 25) & 0x7);
    // 101 = B/BL.
    if (top == 0b101) return true;
    // BX = 0001_0010_xxxx_xxxx_xxxx_0001_xxxx (bits 27-4 = ?).
    if ((instr & 0x0FFFFFF0) == 0x012FFF10) return true;
    // LDR with PC dest.
    if (((instr >> 25) & 0x7) == 0b010 and ((instr >> 12) & 0xF) == 0xF and ((instr >> 20) & 1) == 1) return true;
    // LDM with PC in list.
    if (((instr >> 25) & 0x7) == 0b100 and ((instr >> 20) & 1) == 1 and (instr & 0x8000) != 0) return true;
    // Data-proc with Rd = pc and S=1 (mode change).
    if (top == 0b000 and ((instr >> 12) & 0xF) == 0xF) return true;
    return false;
}

fn isThumbControlFlow(instr: u16) bool {
    const top4: u4 = @intCast(instr >> 12);
    // Format 16 (cond branch) = 1101, Format 17 (SWI) = 1101 1111, Format 18 (uncond) = 11100, Format 19 (BL) = 1111
    if (top4 == 0xD or top4 == 0xF or top4 == 0xE) return true;
    // POP {pc} (Format 14): 1011_1101_xxxx_xxxx with bit 8 set (R bit).
    if ((instr & 0xFF00) == 0xBD00) return true;
    // BX (Format 5): 0100_0111_xxxx_xxxx.
    if ((instr & 0xFF00) == 0x4700) return true;
    return false;
}

test "compile detects ARM B as end-of-block" {
    // 0xEA000000 = B PC+8 (unconditional branch)
    try std.testing.expect(isArmControlFlow(0xEA000000));
    try std.testing.expect(!isArmControlFlow(0xE3A00001)); // MOV r0, #1 — not control flow
}

test "compile detects Thumb POP pc" {
    try std.testing.expect(isThumbControlFlow(0xBD00));
    try std.testing.expect(!isThumbControlFlow(0xB500)); // PUSH, not POP-pc
}
