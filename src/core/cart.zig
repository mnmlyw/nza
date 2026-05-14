//! Cartridge (Game Pak) loading.
//!
//! M1.3 status:
//!   * Reads the entire ROM file into a heap-allocated `[]u8`.
//!   * Returns an error on >32 MB (the GBA's max addressable ROM size).
//!   * Save-type detection is stubbed: returns `.sram` if the ROM contains
//!     the `SRAM_V` signature anywhere; otherwise `.none`. EEPROM and Flash
//!     detection lands later.
//!
//! Header layout (GBATEK):
//!   0x000  4   ARM branch to entry point
//!   0x004  156 Nintendo logo (validated by real hardware)
//!   0x0A0  12  Game title (ASCII)
//!   0x0AC  4   Game code (e.g. "AGBE" for North American release)
//!   ...

const std = @import("std");
const file_util = @import("file_util.zig");

pub const MAX_ROM_SIZE: usize = 0x0200_0000; // 32 MB
pub const MIN_ROM_SIZE: usize = 0xC0; // need at least the header

pub const SaveType = enum { none, sram, flash_64k, flash_128k, eeprom };

pub const Cartridge = struct {
    rom: []u8,
    save_type: SaveType,
    title: [12]u8,

    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !Cartridge {
        const rom = try file_util.readAllAlloc(allocator, path, MAX_ROM_SIZE);
        errdefer allocator.free(rom);
        if (rom.len < MIN_ROM_SIZE) return error.RomTooSmall;

        var title: [12]u8 = undefined;
        @memcpy(&title, rom[0xA0..0xAC]);

        return .{
            .rom = rom,
            .save_type = detectSaveType(rom),
            .title = title,
        };
    }

    pub fn deinit(self: *Cartridge, allocator: std.mem.Allocator) void {
        allocator.free(self.rom);
        self.rom = &.{};
    }
};

fn detectSaveType(rom: []const u8) SaveType {
    // Scan for save-type signatures embedded in the ROM by the SDK.
    // (NBA does this in `src/nba/src/hw/rom/backup/backup_detector.cc`.)
    const SRAM_SIG = "SRAM_V";
    const FLASH64_SIG = "FLASH_V";
    const FLASH128_SIG = "FLASH512_V"; // Yes, 512 = 64KB; "FLASH1M_V" is 128KB
    const FLASH1M_SIG = "FLASH1M_V";
    const EEPROM_SIG = "EEPROM_V";

    if (std.mem.indexOf(u8, rom, FLASH1M_SIG) != null) return .flash_128k;
    if (std.mem.indexOf(u8, rom, FLASH128_SIG) != null) return .flash_64k;
    if (std.mem.indexOf(u8, rom, FLASH64_SIG) != null) return .flash_64k;
    if (std.mem.indexOf(u8, rom, EEPROM_SIG) != null) return .eeprom;
    if (std.mem.indexOf(u8, rom, SRAM_SIG) != null) return .sram;
    return .none;
}

test "detect SRAM signature" {
    var rom = [_]u8{0} ** 0x200;
    @memcpy(rom[0x100..0x106], "SRAM_V");
    try std.testing.expectEqual(SaveType.sram, detectSaveType(&rom));
}

test "detect FLASH1M_V as 128k" {
    var rom = [_]u8{0} ** 0x200;
    @memcpy(rom[0x100..0x109], "FLASH1M_V");
    try std.testing.expectEqual(SaveType.flash_128k, detectSaveType(&rom));
}

test "no signature returns none" {
    const rom = [_]u8{0} ** 0x200;
    try std.testing.expectEqual(SaveType.none, detectSaveType(&rom));
}
