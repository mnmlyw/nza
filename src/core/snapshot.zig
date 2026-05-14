//! Save-state serialization.
//!
//! Format: magic "NZA1" + version u32 + a sequence of TLV records.
//! Each record is `[u32 tag][u32 length][bytes]`. Readers may skip
//! unrecognized tags for forward compatibility. The current writer
//! emits every required tag in a fixed order.
//!
//! Tags map to subsystems. ROM and BIOS are NOT in the snapshot — they
//! come from the user's filesystem and must be loaded before restore.

const std = @import("std");

pub const MAGIC: [4]u8 = .{ 'N', 'Z', 'A', '1' };
pub const VERSION: u32 = 1;

pub const Tag = enum(u32) {
    bus = 0x42555300, // "BUS\0"
    cpu = 0x43505500,
    irq = 0x49525100,
    io = 0x494f0000,
    ppu = 0x50505500,
    apu = 0x41505500,
    dma = 0x444d4100,
    tmr = 0x544d5200,
    fla = 0x464c4100,
    eep = 0x45455000,
    sch = 0x53434800,
    end = 0x454e4400,
};

fn tagFromInt(v: u32) ?Tag {
    inline for (std.meta.fields(Tag)) |f| {
        if (f.value == v) return @enumFromInt(f.value);
    }
    return null;
}

pub const Writer = struct {
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Writer {
        _ = allocator;
        return .{ .buf = .empty };
    }

    pub fn deinit(self: *Writer, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    pub fn beginRecord(self: *Writer, allocator: std.mem.Allocator, tag: Tag) !usize {
        try self.writeU32(allocator, @intFromEnum(tag));
        const len_off = self.buf.items.len;
        try self.writeU32(allocator, 0); // patched in `endRecord`
        return len_off;
    }

    pub fn endRecord(self: *Writer, len_off: usize) void {
        const payload_len: u32 = @intCast(self.buf.items.len - (len_off + 4));
        std.mem.writeInt(u32, self.buf.items[len_off..][0..4], payload_len, .little);
    }

    pub fn writeU8(self: *Writer, allocator: std.mem.Allocator, v: u8) !void {
        try self.buf.append(allocator, v);
    }
    pub fn writeU16(self: *Writer, allocator: std.mem.Allocator, v: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, v, .little);
        try self.buf.appendSlice(allocator, &bytes);
    }
    pub fn writeU32(self: *Writer, allocator: std.mem.Allocator, v: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, v, .little);
        try self.buf.appendSlice(allocator, &bytes);
    }
    pub fn writeU64(self: *Writer, allocator: std.mem.Allocator, v: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, v, .little);
        try self.buf.appendSlice(allocator, &bytes);
    }
    pub fn writeI8(self: *Writer, allocator: std.mem.Allocator, v: i8) !void {
        try self.writeU8(allocator, @bitCast(v));
    }
    pub fn writeI32(self: *Writer, allocator: std.mem.Allocator, v: i32) !void {
        try self.writeU32(allocator, @bitCast(v));
    }
    pub fn writeBool(self: *Writer, allocator: std.mem.Allocator, v: bool) !void {
        try self.writeU8(allocator, if (v) 1 else 0);
    }
    pub fn writeBytes(self: *Writer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        try self.buf.appendSlice(allocator, bytes);
    }
};

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn readU8(self: *Reader) !u8 {
        if (self.pos + 1 > self.bytes.len) return error.Eof;
        const v = self.bytes[self.pos];
        self.pos += 1;
        return v;
    }
    pub fn readU16(self: *Reader) !u16 {
        if (self.pos + 2 > self.bytes.len) return error.Eof;
        const v = std.mem.readInt(u16, self.bytes[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    pub fn readU32(self: *Reader) !u32 {
        if (self.pos + 4 > self.bytes.len) return error.Eof;
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    pub fn readU64(self: *Reader) !u64 {
        if (self.pos + 8 > self.bytes.len) return error.Eof;
        const v = std.mem.readInt(u64, self.bytes[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }
    pub fn readI8(self: *Reader) !i8 {
        return @bitCast(try self.readU8());
    }
    pub fn readI32(self: *Reader) !i32 {
        return @bitCast(try self.readU32());
    }
    pub fn readBool(self: *Reader) !bool {
        return (try self.readU8()) != 0;
    }
    pub fn readBytes(self: *Reader, dest: []u8) !void {
        if (self.pos + dest.len > self.bytes.len) return error.Eof;
        @memcpy(dest, self.bytes[self.pos..][0..dest.len]);
        self.pos += dest.len;
    }
    pub fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.bytes.len) return error.Eof;
        self.pos += n;
    }
};

// ----------------------------------------------------------------------
// Core save / restore
// ----------------------------------------------------------------------

const Core = @import("core.zig").Core;
const flash_mod = @import("flash.zig");
const eeprom_mod = @import("eeprom.zig");
const Cpsr = @import("../cpu/arm7tdmi.zig").Cpsr;

/// Serialize `core` to a freshly-allocated byte slice. Caller owns.
pub fn save(allocator: std.mem.Allocator, core: *Core) ![]u8 {
    var w = Writer.init(allocator);
    errdefer w.deinit(allocator);

    try w.writeBytes(allocator, &MAGIC);
    try w.writeU32(allocator, VERSION);

    // BUS — physical memory + cart state
    {
        const len_off = try w.beginRecord(allocator, .bus);
        const b = &core.bus;
        try w.writeBytes(allocator, &b.bios);
        try w.writeBytes(allocator, &b.wram);
        try w.writeBytes(allocator, &b.iram);
        try w.writeBytes(allocator, &b.pram);
        try w.writeBytes(allocator, &b.vram);
        try w.writeBytes(allocator, &b.oam);
        try w.writeBytes(allocator, &b.sram);
        try w.writeBytes(allocator, &b.flash_data);
        try w.writeBool(allocator, b.gpio_enabled);
        try w.writeBool(allocator, b.save_dirty);
        try w.writeBool(allocator, b.eeprom_narrow_window);
        try w.writeU32(allocator, b.last_code_fetch);
        try w.writeU32(allocator, b.wait_cycles_accum);
        try w.writeBytes(allocator, std.mem.asBytes(&b.wait16));
        try w.writeBytes(allocator, std.mem.asBytes(&b.wait32));
        w.endRecord(len_off);
    }

    // FLASH — chip state (data itself is in BUS)
    {
        const len_off = try w.beginRecord(allocator, .fla);
        try w.writeBool(allocator, core.bus.flash != null);
        if (core.bus.flash) |f| {
            try w.writeU8(allocator, @intFromEnum(f.size));
            try w.writeU8(allocator, @intFromEnum(f.state));
            try w.writeU8(allocator, @as(u8, f.bank));
        }
        w.endRecord(len_off);
    }

    // EEPROM — full state
    {
        const len_off = try w.beginRecord(allocator, .eep);
        try w.writeBool(allocator, core.eeprom != null);
        if (core.eeprom) |*e| {
            try w.writeU8(allocator, @intFromEnum(e.size));
            try w.writeU8(allocator, @intFromEnum(e.state));
            try w.writeU8(allocator, e.addr_bits);
            try w.writeU16(allocator, e.addr);
            try w.writeU16(allocator, e.bit_count);
            try w.writeU8(allocator, e.cmd);
            try w.writeU64(allocator, e.shift);
            try w.writeBool(allocator, e.dirty);
            try w.writeBytes(allocator, &e.data);
        }
        w.endRecord(len_off);
    }

    // CPU
    {
        const len_off = try w.beginRecord(allocator, .cpu);
        const c = &core.cpu;
        try w.writeBytes(allocator, std.mem.asBytes(&c.r));
        try w.writeU32(allocator, @bitCast(c.cpsr));
        for (c.spsr) |s| try w.writeU32(allocator, @bitCast(s));
        try w.writeBytes(allocator, std.mem.asBytes(&c.bank_sp));
        try w.writeBytes(allocator, std.mem.asBytes(&c.bank_lr));
        try w.writeBytes(allocator, std.mem.asBytes(&c.fiq_r8_12));
        try w.writeBytes(allocator, std.mem.asBytes(&c.user_r8_12));
        try w.writeBytes(allocator, std.mem.asBytes(&c.pipeline));
        try w.writeU32(allocator, c.cycles);
        try w.writeBool(allocator, c.branched);
        try w.writeBool(allocator, c.hle_swi);
        w.endRecord(len_off);
    }

    // IRQ
    {
        const len_off = try w.beginRecord(allocator, .irq);
        try w.writeU16(allocator, core.irq.ie);
        try w.writeU16(allocator, core.irq.irq_flags);
        try w.writeBool(allocator, core.irq.ime);
        try w.writeBool(allocator, core.irq.halted);
        w.endRecord(len_off);
    }

    // IO — raw bytes + dispstat/vcount
    {
        const len_off = try w.beginRecord(allocator, .io);
        try w.writeBytes(allocator, &core.bus.io.raw);
        try w.writeU16(allocator, core.bus.io.dispstat);
        try w.writeU16(allocator, core.bus.io.vcount);
        w.endRecord(len_off);
    }

    // PPU
    {
        const len_off = try w.beginRecord(allocator, .ppu);
        const p = &core.ppu;
        try w.writeBytes(allocator, std.mem.sliceAsBytes(p.framebuffer[0..]));
        try w.writeBytes(allocator, std.mem.asBytes(&p.bg_line));
        try w.writeBytes(allocator, std.mem.asBytes(&p.obj_line));
        try w.writeBytes(allocator, std.mem.asBytes(&p.obj_win));
        try w.writeBytes(allocator, std.mem.asBytes(&p.affine_x));
        try w.writeBytes(allocator, std.mem.asBytes(&p.affine_y));
        w.endRecord(len_off);
    }

    // APU — FIFOs, PSG channels, ring buffer
    {
        const len_off = try w.beginRecord(allocator, .apu);
        const a = &core.apu;
        try w.writeBytes(allocator, std.mem.asBytes(&a.fifo_a));
        try w.writeBytes(allocator, std.mem.asBytes(&a.fifo_b));
        try w.writeI8(allocator, a.cur_a);
        try w.writeI8(allocator, a.cur_b);
        try w.writeBytes(allocator, std.mem.asBytes(&a.ch1));
        try w.writeBytes(allocator, std.mem.asBytes(&a.ch2));
        try w.writeBytes(allocator, std.mem.asBytes(&a.ch3));
        try w.writeBytes(allocator, std.mem.asBytes(&a.ch4));
        try w.writeU16(allocator, a.frame_seq_acc);
        try w.writeU8(allocator, @as(u8, a.frame_seq_step));
        // out ring intentionally skipped — slight audio glitch on restore acceptable
        w.endRecord(len_off);
    }

    // DMA
    {
        const len_off = try w.beginRecord(allocator, .dma);
        for (core.dma.ch) |ch| {
            try w.writeU32(allocator, ch.sad);
            try w.writeU32(allocator, ch.dad);
            try w.writeU32(allocator, ch.count);
            try w.writeU16(allocator, ch.cnt_h);
            try w.writeU32(allocator, ch.sad_latch);
            try w.writeU32(allocator, ch.dad_latch);
            try w.writeU32(allocator, ch.count_latch);
            try w.writeU32(allocator, ch.special_words_transferred);
        }
        w.endRecord(len_off);
    }

    // TIMERS
    {
        const len_off = try w.beginRecord(allocator, .tmr);
        for (core.timers.t) |t| {
            try w.writeU16(allocator, t.reload);
            try w.writeU16(allocator, t.counter);
            try w.writeU8(allocator, t.cnt);
            try w.writeU64(allocator, t.start_time);
            try w.writeBool(allocator, t.enabled);
        }
        w.endRecord(len_off);
    }

    // SCHEDULER — timestamp + pending events as (tag, delta)
    {
        const len_off = try w.beginRecord(allocator, .sch);
        try w.writeU64(allocator, core.scheduler.timestamp);
        var count: u32 = 0;
        var i: usize = 0;
        while (i < core.scheduler.len) : (i += 1) {
            if (!core.scheduler.events[i].cancelled) count += 1;
        }
        try w.writeU32(allocator, count);
        i = 0;
        while (i < core.scheduler.len) : (i += 1) {
            const e = core.scheduler.events[i];
            if (e.cancelled) continue;
            try w.writeU32(allocator, e.tag);
            const delta = if (e.timestamp > core.scheduler.timestamp)
                e.timestamp - core.scheduler.timestamp
            else
                0;
            try w.writeU64(allocator, delta);
        }
        w.endRecord(len_off);
    }

    // META — frame counter, irq counter
    {
        const len_off = try w.beginRecord(allocator, .end);
        try w.writeU64(allocator, core.frames_run);
        try w.writeU64(allocator, core.irq_entry_count);
        w.endRecord(len_off);
    }

    return try w.buf.toOwnedSlice(allocator);
}

/// Restore `core` in place from `bytes`. ROM and BIOS must already be
/// loaded (we don't re-load them — they're invariant for a given session).
pub fn restore(core: *Core, bytes: []const u8) !void {
    var r = Reader.init(bytes);
    var magic: [4]u8 = undefined;
    try r.readBytes(&magic);
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.BadMagic;
    const ver = try r.readU32();
    if (ver != VERSION) return error.UnsupportedVersion;

    // Cancel every scheduled event before reloading.
    core.scheduler.len = 0;

    while (r.pos < r.bytes.len) {
        const tag_v = try r.readU32();
        const len = try r.readU32();
        const start = r.pos;
        const tag = tagFromInt(tag_v) orelse {
            try r.skip(len);
            continue;
        };
        switch (tag) {
            .bus => try restoreBus(core, &r),
            .fla => try restoreFlash(core, &r),
            .eep => try restoreEeprom(core, &r),
            .cpu => try restoreCpu(core, &r),
            .irq => try restoreIrq(core, &r),
            .io => try restoreIo(core, &r),
            .ppu => try restorePpu(core, &r),
            .apu => try restoreApu(core, &r),
            .dma => try restoreDma(core, &r),
            .tmr => try restoreTimers(core, &r),
            .sch => try restoreScheduler(core, &r),
            .end => {
                core.frames_run = try r.readU64();
                core.irq_entry_count = try r.readU64();
            },
        }
        // If a restore function didn't consume the whole record, skip the rest.
        const consumed = r.pos - start;
        if (consumed < len) try r.skip(len - consumed);
    }
}

fn restoreBus(core: *Core, r: *Reader) !void {
    const b = &core.bus;
    try r.readBytes(&b.bios);
    try r.readBytes(&b.wram);
    try r.readBytes(&b.iram);
    try r.readBytes(&b.pram);
    try r.readBytes(&b.vram);
    try r.readBytes(&b.oam);
    try r.readBytes(&b.sram);
    try r.readBytes(&b.flash_data);
    b.gpio_enabled = try r.readBool();
    b.save_dirty = try r.readBool();
    b.eeprom_narrow_window = try r.readBool();
    b.last_code_fetch = try r.readU32();
    b.wait_cycles_accum = try r.readU32();
    try r.readBytes(std.mem.asBytes(&b.wait16));
    try r.readBytes(std.mem.asBytes(&b.wait32));
}

fn restoreFlash(core: *Core, r: *Reader) !void {
    const present = try r.readBool();
    if (!present) {
        core.bus.flash = null;
        return;
    }
    const size: flash_mod.Size = @enumFromInt(try r.readU8());
    const state_val = try r.readU8();
    const bank: u1 = @intCast(try r.readU8());
    const backing: []u8 = if (size == .kb128)
        core.bus.flash_data[0..]
    else
        core.bus.flash_data[0..0x10000];
    var f = flash_mod.Flash.init(size, backing);
    f.state = @enumFromInt(state_val);
    f.bank = bank;
    core.bus.flash = f;
}

fn restoreEeprom(core: *Core, r: *Reader) !void {
    const present = try r.readBool();
    if (!present) {
        core.eeprom = null;
        core.bus.eeprom = null;
        return;
    }
    if (core.eeprom == null) core.eeprom = .{};
    const e = &core.eeprom.?;
    e.size = @enumFromInt(try r.readU8());
    e.state = @enumFromInt(try r.readU8());
    e.addr_bits = try r.readU8();
    e.addr = try r.readU16();
    e.bit_count = try r.readU16();
    e.cmd = try r.readU8();
    e.shift = try r.readU64();
    e.dirty = try r.readBool();
    try r.readBytes(&e.data);
    core.bus.eeprom = e;
}

fn restoreCpu(core: *Core, r: *Reader) !void {
    const c = &core.cpu;
    try r.readBytes(std.mem.asBytes(&c.r));
    c.cpsr = @bitCast(try r.readU32());
    for (&c.spsr) |*s| s.* = @bitCast(try r.readU32());
    try r.readBytes(std.mem.asBytes(&c.bank_sp));
    try r.readBytes(std.mem.asBytes(&c.bank_lr));
    try r.readBytes(std.mem.asBytes(&c.fiq_r8_12));
    try r.readBytes(std.mem.asBytes(&c.user_r8_12));
    try r.readBytes(std.mem.asBytes(&c.pipeline));
    c.cycles = try r.readU32();
    c.branched = try r.readBool();
    c.hle_swi = try r.readBool();
}

fn restoreIrq(core: *Core, r: *Reader) !void {
    core.irq.ie = try r.readU16();
    core.irq.irq_flags = try r.readU16();
    core.irq.ime = try r.readBool();
    core.irq.halted = try r.readBool();
}

fn restoreIo(core: *Core, r: *Reader) !void {
    try r.readBytes(&core.bus.io.raw);
    core.bus.io.dispstat = try r.readU16();
    core.bus.io.vcount = try r.readU16();
}

fn restorePpu(core: *Core, r: *Reader) !void {
    const p = &core.ppu;
    try r.readBytes(std.mem.sliceAsBytes(p.framebuffer[0..]));
    try r.readBytes(std.mem.asBytes(&p.bg_line));
    try r.readBytes(std.mem.asBytes(&p.obj_line));
    try r.readBytes(std.mem.asBytes(&p.obj_win));
    try r.readBytes(std.mem.asBytes(&p.affine_x));
    try r.readBytes(std.mem.asBytes(&p.affine_y));
}

fn restoreApu(core: *Core, r: *Reader) !void {
    const a = &core.apu;
    try r.readBytes(std.mem.asBytes(&a.fifo_a));
    try r.readBytes(std.mem.asBytes(&a.fifo_b));
    a.cur_a = try r.readI8();
    a.cur_b = try r.readI8();
    try r.readBytes(std.mem.asBytes(&a.ch1));
    try r.readBytes(std.mem.asBytes(&a.ch2));
    try r.readBytes(std.mem.asBytes(&a.ch3));
    try r.readBytes(std.mem.asBytes(&a.ch4));
    a.frame_seq_acc = try r.readU16();
    const step = try r.readU8();
    a.frame_seq_step = @intCast(step & 0x7);
}

fn restoreDma(core: *Core, r: *Reader) !void {
    for (&core.dma.ch) |*ch| {
        ch.sad = try r.readU32();
        ch.dad = try r.readU32();
        ch.count = try r.readU32();
        ch.cnt_h = try r.readU16();
        ch.sad_latch = try r.readU32();
        ch.dad_latch = try r.readU32();
        ch.count_latch = try r.readU32();
        ch.special_words_transferred = try r.readU32();
    }
}

fn restoreTimers(core: *Core, r: *Reader) !void {
    for (&core.timers.t) |*t| {
        t.reload = try r.readU16();
        t.counter = try r.readU16();
        t.cnt = try r.readU8();
        t.start_time = try r.readU64();
        t.enabled = try r.readBool();
    }
}

fn restoreScheduler(core: *Core, r: *Reader) !void {
    core.scheduler.timestamp = try r.readU64();
    const n = try r.readU32();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const tag = try r.readU32();
        const delta = try r.readU64();
        core.bindSchedulerEvent(tag, delta);
    }
}

test "snapshot writer/reader round trip" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit(allocator);
    const off = try w.beginRecord(allocator, .cpu);
    try w.writeU32(allocator, 0xCAFEBABE);
    try w.writeU64(allocator, 0xDEADBEEFCAFE_BABE);
    w.endRecord(off);

    var r = Reader.init(w.buf.items);
    try std.testing.expectEqual(@as(u32, @intFromEnum(Tag.cpu)), try r.readU32());
    try std.testing.expectEqual(@as(u32, 12), try r.readU32());
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), try r.readU32());
    try std.testing.expectEqual(@as(u64, 0xDEADBEEFCAFE_BABE), try r.readU64());
}
