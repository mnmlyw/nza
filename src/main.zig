const std = @import("std");
const sdl = @import("frontend/sdl.zig");
const core_mod = @import("core/core.zig");

extern fn usleep(usec: u32) c_int;

const DEFAULT_BIOS_PATH = "~/Documents/gba/gba_bios.bin"; // tilde-expanded below

const Args = struct {
    bios_path: ?[]const u8 = null,
    rom_path: ?[]const u8 = null,
    headless: bool = false,
    steps: ?u64 = null,
    trace: ?u64 = null,
    no_bios: bool = false,
    ppu_test: bool = false,
    /// `--press start@N` schedules a 3-frame press of `start` at frame N
    /// during the headless --steps run. Used to drive past the title.
    /// Multiple inputs comma-separated: e.g. `start@8500,a@9200`.
    press_script: ?[]const u8 = null,
    snapshot_test: bool = false,
};

fn parseArgs(init: std.process.Init.Minimal) !Args {
    var args = Args{};
    var it = init.args.iterate();
    _ = it.next(); // skip program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bios")) {
            args.bios_path = it.next() orelse return error.MissingBiosValue;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            args.headless = true;
        } else if (std.mem.eql(u8, arg, "--steps")) {
            const v = it.next() orelse return error.MissingStepsValue;
            args.steps = std.fmt.parseInt(u64, v, 10) catch return error.BadStepsValue;
        } else if (std.mem.eql(u8, arg, "--no-bios")) {
            args.no_bios = true;
        } else if (std.mem.eql(u8, arg, "--ppu-test")) {
            args.ppu_test = true;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            const v = it.next() orelse return error.MissingTraceValue;
            args.trace = std.fmt.parseInt(u64, v, 10) catch return error.BadTraceValue;
        } else if (std.mem.eql(u8, arg, "--press")) {
            args.press_script = it.next() orelse return error.MissingPressValue;
        } else if (std.mem.eql(u8, arg, "--snapshot-test")) {
            args.snapshot_test = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        } else {
            args.rom_path = arg;
        }
    }
    return args;
}

fn resolveBiosPath(allocator: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |p| return try allocator.dupe(u8, p);
    // libc is linked for SDL2, so just call getenv directly.
    const home_ptr = std.c.getenv("HOME") orelse return error.HomeNotSet;
    const home = std.mem.span(home_ptr);
    return try std.fmt.allocPrint(allocator, "{s}/Documents/gba/gba_bios.bin", .{home});
}

pub fn main(init: std.process.Init.Minimal) !void {
    // We link libc for SDL2 anyway — just use the C allocator instead of
    // pulling in DebugAllocator's bookkeeping overhead.
    const allocator = std.heap.c_allocator;

    const args = try parseArgs(init);

    var core = try core_mod.Core.init(allocator);
    defer core.deinit();

    if (!args.no_bios) {
        const bios_path = try resolveBiosPath(allocator, args.bios_path);
        defer allocator.free(bios_path);
        core.loadBios(bios_path) catch |err| {
            std.debug.print("failed to load BIOS at {s}: {s}\n", .{ bios_path, @errorName(err) });
            return err;
        };
    }

    if (args.rom_path) |rom| {
        core.loadRom(rom) catch |err| {
            std.debug.print("failed to load ROM at {s}: {s}\n", .{ rom, @errorName(err) });
            return err;
        };
        if (core.cart) |c| {
            std.debug.print("loaded ROM: title=\"{s}\" save_type={s}\n", .{
                std.mem.sliceTo(&c.title, 0),
                @tagName(c.save_type),
            });
        }
    } else {
        std.debug.print("no ROM specified — running test pattern only\n", .{});
    }

    if (args.no_bios) {
        core.skipBios();
        std.debug.print("BIOS skipped — jumping straight to 0x08000000\n", .{});
    }

    if (args.ppu_test) {
        setupPpuTestPattern(core);
        std.debug.print("PPU test pattern loaded (mode 3 color bars + diagonal).\n", .{});
    }

    if (args.trace) |n| {
        if (args.steps == null) {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                const pc_pre = core.cpu.r[15];
                const thumb = core.cpu.cpsr.thumb;
                core.cpu.step();
                const pc_post = core.cpu.r[15];
                const instr_addr = if (thumb) pc_pre -% 4 else pc_pre -% 8;
                std.debug.print("[{d:>6}] instr@0x{x:0>8} thumb_pre={} PC_pre=0x{x:0>8} → PC_post=0x{x:0>8} | r0=0x{x:0>8} r1=0x{x:0>8} r13=0x{x:0>8} r14=0x{x:0>8}\n", .{
                    i, instr_addr, thumb, pc_pre, pc_post,
                    core.cpu.r[0], core.cpu.r[1], core.cpu.r[13], core.cpu.r[14],
                });
            }
            return;
        }
    }

    if (args.steps) |n| {
        std.debug.print("running CPU for {d} frames from PC=0x{x:0>8} thumb={}\n", .{
            n, core.cpu.r[15], core.cpu.cpsr.thumb,
        });
        // Open audio file in headless mode for inspection.
        var audio_file: ?*std.c.FILE = null;
        if (args.headless) {
            var path: [32]u8 = undefined;
            @memcpy(path[0..15], "/tmp/nza.audio\x00");
            audio_file = std.c.fopen(@ptrCast(&path), "wb");
        }
        defer {
            if (audio_file) |f| _ = std.c.fclose(f);
        }

        var audio_drain_buf: [4096]i16 = undefined;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            if (args.press_script) |script| applyPressScript(&core.keypad, script, i);
            core.runFrame();
            if (audio_file) |f| {
                const got = core.apu.drain(&audio_drain_buf);
                if (got > 0) _ = std.c.fwrite(@as([*]const u8, @ptrCast(&audio_drain_buf)), 1, got * @sizeOf(i16), f);
            }
        }
        std.debug.print("after {d} frames: PC=0x{x:0>8} thumb={} mode=0x{x} DISPCNT=0x{x:0>4} IF=0x{x:0>4} IE=0x{x:0>4} irqs={d}\n", .{
            n, core.cpu.r[15], core.cpu.cpsr.thumb, core.cpu.cpsr.mode,
            core.bus.io.read(u16, 0), core.irq.irq_flags, core.irq.ie,
            core.irq_entry_count,
        });
    }

    if (args.snapshot_test) {
        // 1) Run 60 frames as warm-up.
        var i: u64 = 0;
        while (i < 60) : (i += 1) core.runFrame();
        // 2) Snapshot.
        const bytes = try core.saveState();
        defer allocator.free(bytes);
        std.debug.print("snapshot size: {d} bytes\n", .{bytes.len});
        // 3) Run 60 more frames, compute hash A.
        var ia: u64 = 0;
        while (ia < 60) : (ia += 1) core.runFrame();
        const hash_a = framebufferHash(&core.ppu.framebuffer);
        const pc_a = core.cpu.r[15];
        // 4) Restore, run 60 again, recompute.
        try core.loadState(bytes);
        var ib: u64 = 0;
        while (ib < 60) : (ib += 1) core.runFrame();
        const hash_b = framebufferHash(&core.ppu.framebuffer);
        const pc_b = core.cpu.r[15];
        std.debug.print("snapshot-test: hash_a=0x{x:0>16} hash_b=0x{x:0>16} pc_a=0x{x:0>8} pc_b=0x{x:0>8} match={}\n",
            .{ hash_a, hash_b, pc_a, pc_b, hash_a == hash_b });
        return;
    }

    if (args.headless) {
        // Dump current framebuffer to /tmp/nza.ppm so we can see what was
        // rendered headlessly. Audio was streamed during --steps.
        dumpFramebufferPpm(&core.ppu.framebuffer) catch {};
        return;
    }

    var fe = try sdl.Frontend.init();
    defer fe.deinit();

    // Rewind is enabled by default; it's cheap and lets Backspace rewind.
    core.setRewindEnabled(true);

    var hotkeys: std.ArrayList(sdl.HotKeyEvent) = .empty;
    defer hotkeys.deinit(allocator);
    var fast_forward: bool = false;
    var rewind_held: bool = false;

    // Main loop: pump SDL events, run one frame of emulation, present.
    // SDL's PRESENTVSYNC paces the loop near 60 Hz. Audio is queued each
    // frame; if the queue grows too large we drop the excess to keep
    // latency bounded.
    while (fe.pollEvents(&core.keypad, &hotkeys, allocator)) {
        for (hotkeys.items) |hk| switch (hk) {
            .save_state => core.saveStateToFile() catch |e|
                std.debug.print("save-state failed: {s}\n", .{@errorName(e)}),
            .load_state => core.loadStateFromFile() catch |e|
                std.debug.print("load-state failed: {s}\n", .{@errorName(e)}),
            .fast_forward_toggle => fast_forward = !fast_forward,
            .rewind_press => rewind_held = true,
            .rewind_release => rewind_held = false,
            .fullscreen_toggle => fe.toggleFullscreen(),
            .screenshot => dumpFramebufferPpm(&core.ppu.framebuffer) catch {},
            .none => {},
        };
        hotkeys.clearRetainingCapacity();

        if (rewind_held) {
            _ = core.rewindStep();
        } else if (args.ppu_test) {
            core.runFrameNoCpu();
        } else {
            const frames: u8 = if (fast_forward) 4 else 1;
            var k: u8 = 0;
            while (k < frames) : (k += 1) core.runFrame();
        }
        fe.present(&core.ppu.framebuffer);
        if (!fast_forward) _ = fe.pushAudio(&core.apu);
    }
}

/// Parse a "name@N" event and press the button for 3 frames starting at frame N.
/// `frame` is the current frame index. Released automatically at N+3.
fn applyPressScript(kp: anytype, script: []const u8, frame: u64) void {
    const Button = @import("keypad/keypad.zig").Button;
    var it = std.mem.splitScalar(u8, script, ',');
    while (it.next()) |item| {
        const at = std.mem.indexOfScalar(u8, item, '@') orelse continue;
        const name = item[0..at];
        const start = std.fmt.parseInt(u64, item[at + 1 ..], 10) catch continue;
        const btn: Button = if (std.mem.eql(u8, name, "a")) .a
            else if (std.mem.eql(u8, name, "b")) .b
            else if (std.mem.eql(u8, name, "select")) .select
            else if (std.mem.eql(u8, name, "start")) .start
            else if (std.mem.eql(u8, name, "right")) .right
            else if (std.mem.eql(u8, name, "left")) .left
            else if (std.mem.eql(u8, name, "up")) .up
            else if (std.mem.eql(u8, name, "down")) .down
            else if (std.mem.eql(u8, name, "r")) .r
            else if (std.mem.eql(u8, name, "l")) .l
            else continue;
        if (frame == start) kp.press(btn);
        if (frame == start + 3) kp.release(btn);
    }
}

fn framebufferHash(fb: *const [@as(usize, @intCast(sdl.WIDTH * sdl.HEIGHT))]u32) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(std.mem.sliceAsBytes(fb[0..]));
    return h.final();
}

fn dumpFramebufferPpm(fb: *const [@as(usize, @intCast(sdl.WIDTH * sdl.HEIGHT))]u32) !void {
    var pathbuf: [128]u8 = undefined;
    @memcpy(pathbuf[0..14], "/tmp/nza.ppm\x00\x00");
    pathbuf[12] = 0;
    const f = std.c.fopen(@ptrCast(&pathbuf), "wb") orelse return;
    defer _ = std.c.fclose(f);
    var hdr_buf: [32]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "P6\n240 160\n255\n", .{});
    _ = std.c.fwrite(hdr.ptr, 1, hdr.len, f);
    var row: usize = 0;
    while (row < 160) : (row += 1) {
        var col: usize = 0;
        while (col < 240) : (col += 1) {
            const px = fb[row * 240 + col];
            const rgb = [3]u8{
                @truncate(px >> 16),
                @truncate(px >> 8),
                @truncate(px),
            };
            _ = std.c.fwrite(&rgb, 1, 3, f);
        }
    }
    std.debug.print("framebuffer dumped to /tmp/nza.ppm\n", .{});
}

/// Initialize VRAM + DISPCNT for mode 3 with a recognizable color pattern.
/// Lets us verify the PPU rendering pipeline end-to-end without needing the
/// CPU to execute any cartridge code.
fn setupPpuTestPattern(core: *core_mod.Core) void {
    // DISPCNT = mode 3, BG2 enabled.
    core.bus.io.write(u16, 0x000, 0x0003 | 0x0400);

    const bars = [_]u16{
        0x7C00, // blue (BGR555: B=31)
        0x03E0, // green
        0x001F, // red
        0x7FE0, // cyan
        0x7C1F, // magenta
        0x03FF, // yellow
        0x7FFF, // white
        0x0000, // black
    };
    var y: u32 = 0;
    while (y < 160) : (y += 1) {
        var x: u32 = 0;
        while (x < 240) : (x += 1) {
            const bar = (x * bars.len) / 240;
            const col = if (x == y or 239 - x == y) @as(u16, 0x7FFF) else bars[bar];
            const off = (y * 240 + x) * 2;
            core.bus.vram[off] = @truncate(col);
            core.bus.vram[off + 1] = @truncate(col >> 8);
        }
    }
}

/// SMPTE-ish vertical color bars (no longer used in the main loop; kept for
/// the standalone framebuffer-sizing test).
fn drawTestPattern(fb: *[@as(usize, @intCast(sdl.WIDTH * sdl.HEIGHT))]u32) void {
    const bars = [_]u32{
        0xFFC0C0C0, // grey
        0xFFC0C000, // yellow
        0xFF00C0C0, // cyan
        0xFF00C000, // green
        0xFFC000C0, // magenta
        0xFFC00000, // red
        0xFF0000C0, // blue
        0xFF000000, // black
    };
    const w: usize = @intCast(sdl.WIDTH);
    const h: usize = @intCast(sdl.HEIGHT);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const bar = (x * bars.len) / w;
            fb[y * w + x] = bars[bar];
        }
    }
}

test "framebuffer sized correctly" {
    const fb = std.mem.zeroes([@as(usize, @intCast(sdl.WIDTH * sdl.HEIGHT))]u32);
    try std.testing.expectEqual(@as(usize, 240 * 160), fb.len);
}

test {
    // Pull every emulator-core module into the test binary so `zig build test`
    // discovers their inline test blocks.
    _ = @import("core/scheduler.zig");
    _ = @import("core/bus.zig");
    _ = @import("core/io.zig");
    _ = @import("core/cart.zig");
    _ = @import("core/core.zig");
    _ = @import("core/flash.zig");
    _ = @import("core/eeprom.zig");
    _ = @import("core/snapshot.zig");
    _ = @import("apu/apu.zig");
    _ = @import("apu/psg.zig");
    _ = @import("cpu/arm7tdmi.zig");
    _ = @import("cpu/decode.zig");
    _ = @import("cpu/handlers_arm.zig");
    _ = @import("cpu/handlers_thumb.zig");
    _ = @import("irq/irq.zig");
    _ = @import("ppu/ppu.zig");
    _ = @import("dma/dma.zig");
    _ = @import("timer/timer.zig");
}
