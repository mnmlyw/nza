//! Integration test harness — runs external GBA ROMs (jsmolka/gba-tests
//! and similar) headlessly and validates the framebuffer.
//!
//! Each test function loads a ROM from `tests/roms/<name>.gba`, runs it
//! for a bounded number of frames, then checks the framebuffer's FNV-1a
//! hash against a known-good golden value. ROMs missing from disk skip
//! silently (the project doesn't redistribute them).
//!
//! Run with: `zig build test -Dintegration`

const std = @import("std");
const Core = @import("nza").Core;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const FB_WIDTH: usize = 240;
const FB_HEIGHT: usize = 160;
const FB_LEN: usize = FB_WIDTH * FB_HEIGHT;

/// Frame budget for a "completion" check. jsmolka's CPU tests display
/// final results within ~10 seconds of CPU time (≈ 600 frames at 60 Hz).
const DEFAULT_FRAMES: u32 = 600;

const RomResult = struct {
    framebuffer_hash: u64,
    last_pc: u32,
    frames_run: u32,
};

fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Load + run a ROM headlessly for `frames` frames, then return a result
/// the caller can assert against. Returns null if the ROM file is absent
/// — the caller treats that as "skip".
fn runRom(name: []const u8, frames: u32) !?RomResult {
    // build.zig sets NZA_ROM_DIR to an absolute path so tests work
    // regardless of the build-cache cwd.
    const dir = if (getenv("NZA_ROM_DIR")) |p| std.mem.span(p) else "tests/roms";
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });

    var core = try Core.init(std.testing.allocator);
    defer core.deinit();

    core.loadRom(path) catch |err| switch (err) {
        error.Open => {
            std.debug.print("[skip] {s} not present (drop one in to enable)\n", .{name});
            return null;
        },
        else => return err,
    };
    core.skipBios();

    var i: u32 = 0;
    while (i < frames) : (i += 1) core.runFrame();

    const fb_bytes = std.mem.sliceAsBytes(core.ppu.framebuffer[0..FB_LEN]);
    // Dump every run's framebuffer to /tmp/nza-<name>.ppm so a human can
    // verify the in-ROM "PASS/FAIL" display matches the hash.
    var path_dump_buf: [128]u8 = undefined;
    const dump_path = try std.fmt.bufPrintZ(&path_dump_buf, "/tmp/nza-{s}.ppm", .{name});
    dumpFramebufferPpm(dump_path, &core.ppu.framebuffer) catch {};

    return RomResult{
        .framebuffer_hash = fnv1a(fb_bytes),
        .last_pc = core.cpu.r[15],
        .frames_run = frames,
    };
}

fn dumpFramebufferPpm(path: [:0]const u8, fb: *const [FB_LEN]u32) !void {
    const f = std.c.fopen(@ptrCast(path), "wb") orelse return;
    defer _ = std.c.fclose(f);
    const hdr = "P6\n240 160\n255\n";
    _ = std.c.fwrite(hdr.ptr, 1, hdr.len, f);
    var row: usize = 0;
    while (row < 160) : (row += 1) {
        var col: usize = 0;
        while (col < 240) : (col += 1) {
            const px = fb[row * 240 + col];
            const rgb = [3]u8{ @truncate(px >> 16), @truncate(px >> 8), @truncate(px) };
            _ = std.c.fwrite(&rgb, 1, 3, f);
        }
    }
}

// ---- Tests ----
//
// Each ROM gets one test. Until we record golden hashes, we just print
// the hash so a human can establish the baseline.

test "arm.gba" {
    const result = (try runRom("arm.gba", DEFAULT_FRAMES)) orelse return;
    std.debug.print("[run] arm.gba    hash=0x{x:0>16} pc=0x{x:0>8}\n", .{ result.framebuffer_hash, result.last_pc });
    // TODO: once verified pass on real hardware, lock the golden:
    // try std.testing.expectEqual(@as(u64, 0x...), result.framebuffer_hash);
}

test "thumb.gba" {
    const result = (try runRom("thumb.gba", DEFAULT_FRAMES)) orelse return;
    std.debug.print("[run] thumb.gba  hash=0x{x:0>16} pc=0x{x:0>8}\n", .{ result.framebuffer_hash, result.last_pc });
}


test "memory.gba" {
    const result = (try runRom("memory.gba", DEFAULT_FRAMES)) orelse return;
    std.debug.print("[run] memory.gba hash=0x{x:0>16} pc=0x{x:0>8}\n", .{ result.framebuffer_hash, result.last_pc });
}

test "nes.gba" {
    const result = (try runRom("nes.gba", DEFAULT_FRAMES)) orelse return;
    std.debug.print("[run] nes.gba    hash=0x{x:0>16} pc=0x{x:0>8}\n", .{ result.framebuffer_hash, result.last_pc });
}
