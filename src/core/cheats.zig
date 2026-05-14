//! GameShark / Action Replay / CodeBreaker cheat code engine.
//!
//! Supports the most common GBA cheat formats. Codes are parsed from a
//! `<rom>.cheats` text file: each line is a hex pair `AAAAAAAA VVVV`
//! (32-bit address + 16-bit value) or a single 64-bit hex blob.
//! Lines starting with `#`, `;`, or `//` are comments.
//!
//! Each frame, `Cheats.applyAll` walks the patches and writes them
//! straight to the bus (skipping waitstate accounting — this is meta).
//! Conditional codes (D-prefixed) only patch when their predicate
//! holds against the last write target.
//!
//! Supported opcodes:
//!   `00xxxxxx YYYY`  — 8-bit write (value low byte at address)
//!   `02xxxxxx YYYY`  — 16-bit write
//!   `04xxxxxx YYYYYYYY` — 32-bit write (full word)
//!   `08xxxxxx YYYY`  — alternative 16-bit form
//!   `D0xxxxxx YYYY`  — if [u16 at xxxxxx] == YYYY, execute next patch
//!   `D4xxxxxx YYYY`  — if [u16 at xxxxxx] != YYYY, execute next patch
//!
//! Anything unrecognized is logged and skipped.

const std = @import("std");
const Bus = @import("bus.zig").Bus;
const file_util = @import("file_util.zig");

pub const Code = struct {
    op: u8,
    addr: u32,
    value: u32, // 8/16/32-bit payload, stored in low bits

    pub fn fromLine(line: []const u8) ?Code {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return null;
        // Split on whitespace.
        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const first = it.next() orelse return null;
        const second = it.next();
        if (first.len < 8) return null;
        const aaa = std.fmt.parseInt(u32, first, 16) catch return null;
        const op: u8 = @intCast(aaa >> 24);
        const addr = aaa & 0x00FF_FFFF;
        const value: u32 = blk: {
            if (second) |s| {
                break :blk std.fmt.parseInt(u32, s, 16) catch return null;
            } else {
                // 8-byte single token: low 32 bits = value
                if (first.len < 16) return null;
                break :blk std.fmt.parseInt(u32, first[8..], 16) catch return null;
            }
        };
        return .{ .op = op, .addr = addr | 0x0200_0000, .value = value };
    }
};

pub const Cheats = struct {
    codes: std.ArrayList(Code) = .empty,
    enabled: bool = true,

    pub fn deinit(self: *Cheats, allocator: std.mem.Allocator) void {
        self.codes.deinit(allocator);
    }

    /// Load codes from `<rom>.cheats`. Missing file is treated as "no
    /// cheats" (returns true without an error).
    pub fn loadFromFile(self: *Cheats, allocator: std.mem.Allocator, path: []const u8) !void {
        const bytes = file_util.readAllAlloc(allocator, path, 64 * 1024) catch return;
        defer allocator.free(bytes);
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r\n");
            if (t.len == 0 or t[0] == '#' or t[0] == ';' or std.mem.startsWith(u8, t, "//")) continue;
            if (Code.fromLine(t)) |c| try self.codes.append(allocator, c);
        }
    }

    /// Apply every patch to `bus`. Called once per frame.
    pub fn applyAll(self: *const Cheats, bus: *Bus) void {
        if (!self.enabled) return;
        var skip_next = false;
        for (self.codes.items) |c| {
            if (skip_next) {
                skip_next = false;
                continue;
            }
            switch (c.op) {
                0x00 => bus.write(u8, c.addr, @truncate(c.value)),
                0x02, 0x08 => bus.write(u16, c.addr, @truncate(c.value)),
                0x04 => bus.write(u32, c.addr, c.value),
                0xD0 => {
                    const v = bus.read(u16, c.addr);
                    if (v != @as(u16, @truncate(c.value))) skip_next = true;
                },
                0xD4 => {
                    const v = bus.read(u16, c.addr);
                    if (v == @as(u16, @truncate(c.value))) skip_next = true;
                },
                else => {
                    // Unsupported opcode — could be GameShark v3 encrypted.
                    // Silently skip rather than spam logs.
                },
            }
        }
    }
};

test "cheat code parses 16-bit write" {
    const c = Code.fromLine("02123456 7890") orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x02), c.op);
    try std.testing.expectEqual(@as(u32, 0x02123456), c.addr);
    try std.testing.expectEqual(@as(u32, 0x7890), c.value);
}

test "cheat code parses 32-bit write" {
    const c = Code.fromLine("04ABCDEF 12345678") orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x04), c.op);
    try std.testing.expectEqual(@as(u32, 0x02ABCDEF), c.addr);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), c.value);
}

test "cheat code applies 16-bit write" {
    var cheats = Cheats{};
    defer cheats.deinit(std.testing.allocator);
    try cheats.codes.append(std.testing.allocator, .{ .op = 0x02, .addr = 0x0200_0100, .value = 0xBEEF });
    var bus: Bus = .{};
    cheats.applyAll(&bus);
    try std.testing.expectEqual(@as(u16, 0xBEEF), bus.read(u16, 0x0200_0100));
}
