//! Persistent `.sav` file helpers — read/write raw backup bytes next to
//! the ROM. Format is identical to mGBA / VBA / NBA: just the chip's
//! contents, size = chip size. The save type is inferred from the file's
//! length when loading, so users can swap saves between emulators.

const std = @import("std");

const SEEK_SET: c_int = 0;
extern fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;

/// Build `<rom_path>.sav` (heap-allocated; caller owns).
pub fn savePathFor(allocator: std.mem.Allocator, rom_path: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, rom_path.len + 4);
    @memcpy(buf[0..rom_path.len], rom_path);
    @memcpy(buf[rom_path.len..], ".sav");
    return buf;
}

/// Load `path` into `dest`. If the file doesn't exist or its length doesn't
/// match `dest.len`, dest is filled with `fill` and `false` is returned.
pub fn loadInto(path: []const u8, dest: []u8, fill: u8) bool {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        @memset(dest, fill);
        return false;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_buf), "rb") orelse {
        @memset(dest, fill);
        return false;
    };
    defer _ = std.c.fclose(f);

    const got = std.c.fread(dest.ptr, 1, dest.len, f);
    if (got != dest.len) {
        @memset(dest, fill);
        return false;
    }
    return true;
}

/// Write `bytes` to `path` atomically via `<path>.tmp` + rename.
pub fn flush(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const tmp = try allocator.alloc(u8, path.len + 5);
    defer allocator.free(tmp);
    @memcpy(tmp[0..path.len], path);
    @memcpy(tmp[path.len..], ".tmp\x00");

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const f = std.c.fopen(@ptrCast(tmp.ptr), "wb") orelse return error.Open;
    {
        defer _ = std.c.fclose(f);
        const wrote = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
        if (wrote != bytes.len) return error.Write;
    }
    if (rename(@ptrCast(tmp.ptr), @ptrCast(&path_buf)) != 0) return error.Rename;
}
