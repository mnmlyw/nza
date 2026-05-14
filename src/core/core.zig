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
const save_file = @import("save_file.zig");
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
    irq_entry_count: u64 = 0,
    frames_run: u64 = 0,

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
        self.allocator.destroy(self);
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
            // Service pending IRQ (CPU-side check matches ARM7TDMI semantics).
            if (self.irq.pending() != 0 and self.irq.ime and !self.cpu.cpsr.irq_disable) {
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
        if (self.frames_run % 60 == 0 and self.bus.save_dirty) {
            self.flushSaveIfDirty();
        }
    }
};
