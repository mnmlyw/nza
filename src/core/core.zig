//! Top-level emulator core. Owns the scheduler, bus, CPU, and every
//! peripheral. Frontend code talks to this struct only.

const std = @import("std");

const Bus = @import("bus.zig").Bus;
const Scheduler = @import("scheduler.zig").Scheduler;
const Cpu = @import("../cpu/arm7tdmi.zig").Cpu;
const cart = @import("cart.zig");
const bios = @import("bios.zig");
const flash_mod = @import("flash.zig");
const eeprom_mod = @import("eeprom.zig");
const gpio_mod = @import("gpio.zig");
const cheats_mod = @import("cheats.zig");
const save_file = @import("save_file.zig");
const snapshot = @import("snapshot.zig");
const ppu_mod = @import("../ppu/ppu.zig");
const apu_mod = @import("../apu/apu.zig");
const timer_mod = @import("../timer/timer.zig");
const Irq = @import("../irq/irq.zig").Irq;
const Keypad = @import("../keypad/keypad.zig").Keypad;
const Ppu = @import("../ppu/ppu.zig").Ppu;
const Dma = @import("../dma/dma.zig").Dma;
const Timers = @import("../timer/timer.zig").Timers;
const Apu = @import("../apu/apu.zig").Apu;
const arm_handlers = @import("../cpu/handlers_arm.zig");

/// 16.78 MHz / 59.7275 Hz, matching NanoBoyAdvance's `kCyclesPerFrame`.
pub const CYCLES_PER_FRAME: u64 = 280_896;

pub const Core = struct {
    allocator: std.mem.Allocator,
    bus: Bus,
    scheduler: Scheduler = .{},
    cpu: Cpu,
    irq: Irq = .{},
    keypad: Keypad = .{},
    ppu: Ppu,
    dma: Dma,
    timers: Timers,
    apu: Apu,
    cart: ?cart.Cartridge = null,
    eeprom: ?eeprom_mod.Eeprom = null,
    gpio: ?gpio_mod.Gpio = null,
    cheats: cheats_mod.Cheats = .{},
    irq_entry_count: u64 = 0,
    frames_run: u64 = 0,

    /// 1 = real-time. Higher values skip audio queue and run multiple
    /// frames per host iteration (fast-forward).
    run_speed_mul: u8 = 1,

    /// Rewind ring buffer of recent snapshots. Allocated on demand.
    rewind_ring: [REWIND_SLOTS]?[]u8 = [_]?[]u8{null} ** REWIND_SLOTS,
    rewind_head: usize = 0,
    rewind_count: usize = 0,
    rewind_frame_skip: u8 = 0,
    rewind_enabled: bool = false,

    pub const REWIND_SLOTS: usize = 30; // ~6 s at 12-frame snapshot cadence
    pub const REWIND_FRAME_INTERVAL: u8 = 12;

    pub fn init(allocator: std.mem.Allocator) !*Core {
        const self = try allocator.create(Core);
        self.* = .{
            .allocator = allocator,
            .bus = .{},
            .scheduler = .{},
            .cpu = undefined,
            .ppu = undefined,
            .dma = undefined,
            .timers = undefined,
            .apu = undefined,
        };
        self.cpu = Cpu.init(&self.bus);
        // Wire IO register dispatcher peripherals.
        self.bus.io.irq = &self.irq;
        self.bus.io.keypad = &self.keypad;
        self.dma = .{ .bus = &self.bus, .io = &self.bus.io, .irq = &self.irq };
        self.bus.io.dma = &self.dma;
        self.apu = .{ .sched = &self.scheduler, .io = &self.bus.io };
        self.bus.io.apu = &self.apu;
        self.apu.init();
        self.timers = .{ .sched = &self.scheduler, .io = &self.bus.io, .irq = &self.irq, .dma = &self.dma, .apu = &self.apu };
        self.bus.io.timers = &self.timers;
        // Init the PPU (must come after IO has its pointers).
        self.ppu = .{
            .sched = &self.scheduler,
            .io = &self.bus.io,
            .irq = &self.irq,
            .bus = &self.bus,
            .dma = &self.dma,
        };
        self.ppu.init();
        return self;
    }

    pub fn deinit(self: *Core) void {
        self.flushSaveIfDirty();
        if (self.cart) |*c| c.deinit(self.allocator);
        self.cheats.deinit(self.allocator);
        for (&self.rewind_ring) |*slot| {
            if (slot.*) |s| self.allocator.free(s);
            slot.* = null;
        }
        self.allocator.destroy(self);
    }

    /// Allocate a fresh snapshot of the entire core state. Caller owns.
    pub fn saveState(self: *Core) ![]u8 {
        return snapshot.save(self.allocator, self);
    }

    /// Restore from a snapshot blob. ROM/BIOS must already be loaded.
    pub fn loadState(self: *Core, bytes: []const u8) !void {
        try snapshot.restore(self, bytes);
    }

    /// Write a snapshot to `<rom_path>.state`.
    pub fn saveStateToFile(self: *Core) !void {
        const c = self.cart orelse return error.NoCart;
        const rom_path = c.save_path orelse return error.NoPath;
        // rom_path ends with ".sav"; swap to ".state".
        const slen = rom_path.len - 4;
        var p = try self.allocator.alloc(u8, slen + 6);
        defer self.allocator.free(p);
        @memcpy(p[0..slen], rom_path[0..slen]);
        @memcpy(p[slen..], ".state");
        const bytes = try self.saveState();
        defer self.allocator.free(bytes);
        try save_file.flush(self.allocator, p, bytes);
    }

    /// Read `<rom_path>.state` and restore.
    pub fn loadStateFromFile(self: *Core) !void {
        const c = self.cart orelse return error.NoCart;
        const rom_path = c.save_path orelse return error.NoPath;
        const slen = rom_path.len - 4;
        var p = try self.allocator.alloc(u8, slen + 6);
        defer self.allocator.free(p);
        @memcpy(p[0..slen], rom_path[0..slen]);
        @memcpy(p[slen..], ".state");
        const file_util = @import("file_util.zig");
        const bytes = try file_util.readAllAlloc(self.allocator, p, 8 * 1024 * 1024);
        defer self.allocator.free(bytes);
        try self.loadState(bytes);
    }

    /// Reschedule one event by its tag. Called by snapshot restore.
    pub fn bindSchedulerEvent(self: *Core, tag: u32, delta: u64) void {
        if (tag == ppu_mod.TAG_HDRAW_END) {
            self.scheduler.schedule(delta, ppu_mod.Ppu.onHdrawEnd, &self.ppu, tag);
        } else if (tag == ppu_mod.TAG_HBLANK_END) {
            self.scheduler.schedule(delta, ppu_mod.Ppu.onHblankEnd, &self.ppu, tag);
        } else if (tag == apu_mod.TAG_MIX) {
            self.scheduler.schedule(delta, apu_mod.Apu.onMix, &self.apu, tag);
        } else if (tag >= timer_mod.TAG_BASE and tag < timer_mod.TAG_BASE + 4) {
            const idx: u2 = @intCast(tag - timer_mod.TAG_BASE);
            const handler: *const fn (ctx: *anyopaque, late: u64) void = switch (idx) {
                0 => &timer_mod.Timers.onOverflow0,
                1 => &timer_mod.Timers.onOverflow1,
                2 => &timer_mod.Timers.onOverflow2,
                3 => &timer_mod.Timers.onOverflow3,
            };
            self.scheduler.schedule(delta, handler, &self.timers, tag);
        }
        // Unknown tag: silently drop (forward-compat).
    }

    pub fn setRewindEnabled(self: *Core, on: bool) void {
        self.rewind_enabled = on;
        if (!on) {
            for (&self.rewind_ring) |*slot| {
                if (slot.*) |s| self.allocator.free(s);
                slot.* = null;
            }
            self.rewind_head = 0;
            self.rewind_count = 0;
        }
    }

    fn pushRewindSlot(self: *Core) void {
        if (!self.rewind_enabled) return;
        const bytes = self.saveState() catch return;
        const slot_idx = self.rewind_head;
        if (self.rewind_ring[slot_idx]) |old| self.allocator.free(old);
        self.rewind_ring[slot_idx] = bytes;
        self.rewind_head = (self.rewind_head + 1) % REWIND_SLOTS;
        if (self.rewind_count < REWIND_SLOTS) self.rewind_count += 1;
    }

    pub fn rewindStep(self: *Core) bool {
        if (self.rewind_count == 0) return false;
        const newest = (self.rewind_head + REWIND_SLOTS - 1) % REWIND_SLOTS;
        if (self.rewind_ring[newest]) |bytes| {
            self.loadState(bytes) catch return false;
            self.allocator.free(bytes);
            self.rewind_ring[newest] = null;
            self.rewind_head = newest;
            self.rewind_count -= 1;
            return true;
        }
        return false;
    }

    pub fn loadBios(self: *Core, path: []const u8) !void {
        try bios.loadInto(path, &self.bus.bios);
        // CPU was initialized before BIOS bytes were in memory, so reset
        // the pipeline now that the reset vector contains real instructions.
        self.cpu.r[15] = 0;
        self.cpu.reloadPipeline();
    }

    pub fn loadRom(self: *Core, path: []const u8) !void {
        if (self.cart) |*c| c.deinit(self.allocator);
        self.cart = try cart.Cartridge.loadFile(self.allocator, path);
        self.bus.rom = self.cart.?.rom;
        // Set up backup-chip emulation based on detected save type.
        self.bus.flash = switch (self.cart.?.save_type) {
            .flash_64k => flash_mod.Flash.init(.kb64, self.bus.flash_data[0..0x10000]),
            .flash_128k => flash_mod.Flash.init(.kb128, self.bus.flash_data[0..]),
            else => null,
        };
        // EEPROM lives in ROM-space; allocate the state machine when the
        // ROM scan said so. Window narrows on ROMs > 16 MB.
        if (self.cart.?.save_type == .eeprom) {
            self.eeprom = .{};
            self.bus.eeprom = &self.eeprom.?;
            self.bus.eeprom_narrow_window = self.bus.rom.len > 0x0100_0000;
        } else {
            self.bus.eeprom = null;
        }
        // Detect cart GPIO device (RTC / solar / rumble) by gamecode.
        const dev = gpio_mod.detect(self.cart.?.game_code);
        if (dev != .none) {
            self.gpio = .{ .device = dev };
            self.bus.gpio = &self.gpio.?;
        } else {
            self.gpio = null;
            self.bus.gpio = null;
        }
        // Load any persisted .sav file. mGBA/VBA/NBA-compatible format:
        // raw chip contents, no header. Size disambiguates type.
        if (self.cart.?.save_path) |p| {
            switch (self.cart.?.save_type) {
                .sram => _ = save_file.loadInto(p, self.bus.sram[0..], 0xFF),
                .flash_64k => _ = save_file.loadInto(p, self.bus.flash_data[0..0x10000], 0xFF),
                .flash_128k => _ = save_file.loadInto(p, self.bus.flash_data[0..], 0xFF),
                .eeprom => {
                    // We don't yet know 4K vs 64K. Load the largest file we
                    // can; the EEPROM state machine reads from the same
                    // backing buffer regardless of size.
                    _ = save_file.loadInto(p, self.eeprom.?.data[0..], 0xFF);
                },
                .none => {},
            }
        }
        self.bus.save_dirty = false;
        // Try to load `<rom>.cheats` next to the ROM.
        if (self.cart.?.save_path) |p| {
            const slen = p.len - 4;
            var cheats_path = self.allocator.alloc(u8, slen + 7) catch return;
            defer self.allocator.free(cheats_path);
            @memcpy(cheats_path[0..slen], p[0..slen]);
            @memcpy(cheats_path[slen..], ".cheats");
            self.cheats.loadFromFile(self.allocator, cheats_path) catch {};
            if (self.cheats.codes.items.len > 0) {
                std.debug.print("[cheats] loaded {d} codes from {s}\n", .{ self.cheats.codes.items.len, cheats_path });
            }
        }
    }

    /// Flush dirty backup chip bytes to `<rom>.sav`. Called at frame end
    /// (when dirty) and on `deinit`.
    pub fn flushSaveIfDirty(self: *Core) void {
        if (!self.bus.save_dirty) return;
        if (self.cart == null) return;
        const c = &self.cart.?;
        const p = c.save_path orelse return;
        const eep_dirty = if (self.eeprom) |*e| e.dirty else false;
        const slice: ?[]const u8 = switch (c.save_type) {
            .sram => self.bus.sram[0..],
            .flash_64k => self.bus.flash_data[0..0x10000],
            .flash_128k => self.bus.flash_data[0..],
            .eeprom => if (self.eeprom) |*e| e.data[0..e.capacity()] else null,
            .none => null,
        };
        if (slice) |bytes| {
            save_file.flush(self.allocator, p, bytes) catch |err| {
                std.debug.print("[save] flush failed: {s}\n", .{@errorName(err)});
            };
        }
        self.bus.save_dirty = false;
        if (eep_dirty) {
            if (self.eeprom) |*e| e.dirty = false;
        }
    }

    /// Skip the BIOS boot sequence and jump straight to the cartridge entry
    /// point (0x08000000). Sets up the stacks and CPSR the way a real BIOS
    /// would after a successful boot. Also installs an HLE IRQ trampoline
    /// at the BIOS IRQ vector (0x18) so user-mode IRQ handlers registered
    /// via `0x03007FFC` actually get called.
    pub fn skipBios(self: *Core) void {
        const Mode = @import("../cpu/arm7tdmi.zig").Mode;

        // --- HLE SWI stub at BIOS 0x08. Real BIOS handles SWI-by-number
        // here; ours just returns immediately (after restoring CPSR from
        // SPSR_svc via the S-bit on data-proc). Most ROMs only use SWIs
        // for things like VBlankIntrWait — which behave as no-ops at this
        // fidelity since IRQs already fire on schedule.
        writeWord(&self.bus.bios, 0x08, 0xE25E_F000); // SUBS PC, LR, #0

        // --- HLE IRQ trampoline at BIOS 0x18.
        // Matches the original BIOS's IRQ entry: save volatile regs, fetch
        // user handler from 0x03FFFFFC (= mirror of 0x03007FFC), call it,
        // restore, return via SUBS PC, LR, #4.
        const trampoline = [_]u32{
            0xE92D_500F, // STMDB SP!, {R0-R3, R12, LR}
            0xE3A0_0301, // MOV R0, #0x04000000
            0xE28F_E000, // ADD LR, PC, #0     ; LR = 0x28 (returns here after handler)
            0xE510_F004, // LDR PC, [R0, #-4]  ; PC = *(0x03FFFFFC) = user handler
            0xE8BD_500F, // LDMIA SP!, {R0-R3, R12, LR}
            0xE25E_F004, // SUBS PC, LR, #4
        };
        for (trampoline, 0..) |w, i| {
            writeWord(&self.bus.bios, 0x18 + i * 4, w);
        }

        // --- Stack pointers per mode, then settle in System mode.
        self.cpu.cpsr = .{
            .mode = @intFromEnum(Mode.svc),
            .thumb = false,
            .fiq_disable = true,
            .irq_disable = true,
        };
        self.cpu.r[13] = 0x0300_7FE0; // SVC stack
        self.cpu.switchMode(.irq);
        self.cpu.r[13] = 0x0300_7FA0; // IRQ stack
        self.cpu.switchMode(.sys);
        self.cpu.r[13] = 0x0300_7F00; // user/system stack
        self.cpu.cpsr.irq_disable = true;
        self.cpu.cpsr.fiq_disable = true;
        self.cpu.hle_swi = true; // BIOS not loaded — use HLE for SWIs.
        self.cpu.r[15] = 0x0800_0000;
        self.cpu.reloadPipeline();
    }

    /// Advance the scheduler clock by one frame without running the CPU.
    /// Used by `--ppu-test` (PPU runs, but CPU is held still).
    pub fn runFrameNoCpu(self: *Core) void {
        self.scheduler.addCycles(CYCLES_PER_FRAME);
    }

    fn writeWord(buf: anytype, offset: usize, w: u32) void {
        buf[offset + 0] = @truncate(w);
        buf[offset + 1] = @truncate(w >> 8);
        buf[offset + 2] = @truncate(w >> 16);
        buf[offset + 3] = @truncate(w >> 24);
    }

    /// Run the emulator for roughly one display frame's worth of cycles.
    pub fn runFrame(self: *Core) void {
        const target = self.scheduler.now() + CYCLES_PER_FRAME;
        while (self.scheduler.now() < target) {
            // Service pending IRQ. NBA-style: use the latched IRQ-disable
            // bit from the previous instruction boundary, not the live one
            // — so an MSR that disables IRQ doesn't take effect until the
            // *next* instruction. Tests like jsmolka's irq.gba expect this.
            if (self.irq.pending() != 0 and self.irq.ime and !self.cpu.latch_irq_disable) {
                arm_handlers.enterException(&self.cpu, .irq, 0x18, 4);
                self.irq_entry_count += 1;
            }

            if (self.irq.halted) {
                // Skip ahead to the next scheduled event so we don't spin.
                if (self.scheduler.len > 0) {
                    const next = self.scheduler.events[0].timestamp;
                    if (next > self.scheduler.now()) {
                        self.scheduler.addCycles(next - self.scheduler.now());
                    } else {
                        self.scheduler.addCycles(1);
                    }
                } else {
                    // No events scheduled — bail out to avoid infinite loop.
                    break;
                }
                continue;
            }

            self.cpu.step();
            self.scheduler.addCycles(self.cpu.cycles);
        }
        self.frames_run += 1;
        if (self.cheats.codes.items.len > 0) self.cheats.applyAll(&self.bus);
        if (self.frames_run % 60 == 0 and self.bus.save_dirty) {
            self.flushSaveIfDirty();
        }
        if (self.rewind_enabled) {
            self.rewind_frame_skip = (self.rewind_frame_skip + 1) % REWIND_FRAME_INTERVAL;
            if (self.rewind_frame_skip == 0) self.pushRewindSlot();
        }
    }
};
