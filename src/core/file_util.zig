//! Small libc-backed file helpers.
//!
//! Zig 0.16 reworked `std.fs` into the new `std.Io` model, which requires
//! passing an `Io` instance around. For a couple of one-shot ROM and BIOS
//! reads at startup that's far more ceremony than the task deserves —
//! we already link libc for SDL2, so we call `fopen`/`fread` directly.

const std = @import("std");

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

// std.c in 0.16 ships fopen/fread/fclose but not fseek/ftell — declare them.
extern fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern fn ftell(stream: *std.c.FILE) c_long;

pub const ReadError = error{
    Open,
    Read,
    FileTooLarge,
} || std.mem.Allocator.Error;

/// Read up to `max_bytes` from `path`. Caller owns the returned slice.
/// Files larger than `max_bytes` fail with `error.FileTooLarge`.
pub fn readAllAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.Open;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const f = std.c.fopen(@ptrCast(&path_buf), "rb") orelse return error.Open;
    defer _ = std.c.fclose(f);

    if (fseek(f, 0, SEEK_END) != 0) return error.Read;
    const size_long = ftell(f);
    if (size_long < 0) return error.Read;
    const size: usize = @intCast(size_long);
    if (size > max_bytes) return error.FileTooLarge;
    if (fseek(f, 0, SEEK_SET) != 0) return error.Read;

    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const got = std.c.fread(buf.ptr, 1, size, f);
    if (got != size) return error.Read;
    return buf;
}
