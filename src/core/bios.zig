//! GBA BIOS loader.
//!
//! The official GBA BIOS is 16 KB. Common dump path on this machine is
//! `~/Documents/gba/gba_bios.bin`. We don't ship a BIOS — the user must
//! supply one (it's copyrighted by Nintendo). Open BIOS replacements exist
//! (Cult-Of-GBA) but are deferred past M1.

const std = @import("std");
const file_util = @import("file_util.zig");

pub const BIOS_SIZE: usize = 0x4000;

pub fn loadInto(path: []const u8, dest: *[BIOS_SIZE]u8) !void {
    const bytes = try file_util.readAllAlloc(std.heap.c_allocator, path, BIOS_SIZE * 2);
    defer std.heap.c_allocator.free(bytes);
    if (bytes.len != BIOS_SIZE) return error.BiosWrongSize;
    @memcpy(dest[0..], bytes);
}
