//! Minimal gdbserver stub speaking the GDB Remote Serial Protocol.
//!
//! Listens on a TCP port; once a client connects, packets are processed
//! one per frame from the main loop. Implements the subset needed for
//! `gdb-multiarch arm-none-eabi-gdb` to attach to a running ROM and
//! step/break/inspect:
//!
//!   `$?#XX`              — stop reason
//!   `$g#XX`              — read all 16 + CPSR (17 × u32 hex)
//!   `$G<hex>#XX`         — write all
//!   `$m<addr>,<len>#XX`  — read memory
//!   `$M<addr>,<len>:<hex>#XX` — write memory
//!   `$c#XX`              — continue
//!   `$s#XX`              — single-step
//!   `$Z0,<addr>,<kind>#` — set sw breakpoint
//!   `$z0,<addr>,<kind>#` — clear sw breakpoint
//!   `$qSupported#XX`     — report capabilities
//!   `$qC#XX`             — current thread (return T1)
//!   `$H<op><tid>#XX`     — set thread (ignored; always OK)
//!
//! Connection management uses non-blocking libc sockets. One client at
//! a time; second-connection attempts are rejected.

const std = @import("std");
const Core = @import("core.zig").Core;

// --- libc networking
const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;
const SOL_SOCKET: c_int = 0xFFFF; // macOS
const SO_REUSEADDR: c_int = 4;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 4;

const c_in_addr = extern struct { s_addr: u32 };
const c_sockaddr_in = extern struct {
    sin_len: u8,
    sin_family: u8,
    sin_port: u16, // network byte order
    sin_addr: c_in_addr,
    sin_zero: [8]u8,
};
const c_sockaddr = extern struct { sa_family: u16, sa_data: [14]u8 };

extern fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern fn bind(sockfd: c_int, addr: *const c_sockaddr, addrlen: u32) c_int;
extern fn listen(sockfd: c_int, backlog: c_int) c_int;
extern fn accept(sockfd: c_int, addr: ?*c_sockaddr, addrlen: ?*u32) c_int;
extern fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
extern fn htons(host: u16) u16;

pub const GdbServer = struct {
    listen_fd: c_int = -1,
    conn_fd: c_int = -1,
    rx_buf: [4096]u8 = undefined,
    rx_len: usize = 0,
    breakpoints: [16]u32 = [_]u32{0} ** 16,
    bp_count: u8 = 0,
    stop_requested: bool = false,
    stepping: bool = false,

    pub fn init(port: u16) ?GdbServer {
        const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s < 0) return null;

        var yes: c_int = 1;
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, @sizeOf(c_int));

        var addr = c_sockaddr_in{
            .sin_len = @sizeOf(c_sockaddr_in),
            .sin_family = AF_INET,
            .sin_port = htons(port),
            .sin_addr = .{ .s_addr = 0 }, // INADDR_ANY
            .sin_zero = [_]u8{0} ** 8,
        };
        if (bind(s, @ptrCast(&addr), @sizeOf(c_sockaddr_in)) < 0) {
            _ = close(s);
            return null;
        }
        if (listen(s, 1) < 0) {
            _ = close(s);
            return null;
        }
        // Non-blocking
        const fl = fcntl(s, F_GETFL, 0);
        _ = fcntl(s, F_SETFL, fl | O_NONBLOCK);

        std.debug.print("[gdb] listening on port {d}\n", .{port});
        return .{ .listen_fd = s };
    }

    pub fn deinit(self: *GdbServer) void {
        if (self.conn_fd >= 0) _ = close(self.conn_fd);
        if (self.listen_fd >= 0) _ = close(self.listen_fd);
    }

    /// Try to accept a new client (non-blocking). Returns true if one
    /// just connected.
    pub fn pollAccept(self: *GdbServer) bool {
        if (self.conn_fd >= 0 or self.listen_fd < 0) return false;
        const fd = accept(self.listen_fd, null, null);
        if (fd < 0) return false;
        const fl = fcntl(fd, F_GETFL, 0);
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        self.conn_fd = fd;
        self.stop_requested = true; // pause until first 'c'
        std.debug.print("[gdb] client connected\n", .{});
        return true;
    }

    /// Drain pending packets, dispatch them, write replies. Returns true
    /// when the emulator should run (gdb said 'c'), false to pause.
    pub fn pump(self: *GdbServer, core: *Core) bool {
        _ = self.pollAccept();
        if (self.conn_fd < 0) return true; // no client => run free

        var buf: [1024]u8 = undefined;
        const n = read(self.conn_fd, &buf, buf.len);
        if (n > 0) {
            const incoming = buf[0..@intCast(n)];
            for (incoming) |b| {
                if (self.rx_len < self.rx_buf.len) {
                    self.rx_buf[self.rx_len] = b;
                    self.rx_len += 1;
                }
                if (b == '#') {
                    // Wait for 2 more checksum bytes.
                }
            }
            // Process complete packets
            while (self.consumePacket(core)) {}
        } else if (n == 0) {
            // Peer closed.
            _ = close(self.conn_fd);
            self.conn_fd = -1;
            self.rx_len = 0;
            self.stop_requested = false;
            std.debug.print("[gdb] client disconnected\n", .{});
            return true;
        }

        // Check breakpoint after stepping
        if (self.bp_count > 0) {
            const pc = core.cpu.r[15];
            const exec_addr = if (core.cpu.cpsr.thumb) pc -% 4 else pc -% 8;
            for (self.breakpoints[0..self.bp_count]) |bp| {
                if (bp == exec_addr) {
                    self.stop_requested = true;
                    self.sendStop("05");
                    break;
                }
            }
        }

        return !self.stop_requested;
    }

    fn consumePacket(self: *GdbServer, core: *Core) bool {
        // Find $...#XX in buffer.
        const start = std.mem.indexOfScalar(u8, self.rx_buf[0..self.rx_len], '$') orelse {
            self.rx_len = 0;
            return false;
        };
        const hash = std.mem.indexOfScalar(u8, self.rx_buf[start..self.rx_len], '#') orelse return false;
        if (start + hash + 3 > self.rx_len) return false;
        const payload = self.rx_buf[start + 1 .. start + hash];
        // Ack
        _ = write(self.conn_fd, "+", 1);
        // Dispatch
        self.handle(core, payload);
        // Slide buffer
        const consumed = start + hash + 3;
        if (consumed >= self.rx_len) {
            self.rx_len = 0;
        } else {
            std.mem.copyForwards(u8, self.rx_buf[0..], self.rx_buf[consumed..self.rx_len]);
            self.rx_len -= consumed;
        }
        return self.rx_len > 0;
    }

    fn handle(self: *GdbServer, core: *Core, payload: []const u8) void {
        if (payload.len == 0) {
            self.sendEmpty();
            return;
        }
        switch (payload[0]) {
            '?' => self.sendStop("05"),
            'g' => self.sendRegs(core),
            'G' => {
                self.recvRegs(core, payload[1..]);
                self.sendOk();
            },
            'm' => self.cmdReadMem(core, payload[1..]),
            'M' => self.cmdWriteMem(core, payload[1..]),
            'c' => {
                self.stop_requested = false;
                self.stepping = false;
            },
            's' => {
                self.stepping = true;
                self.stop_requested = false;
            },
            'Z' => self.cmdSetBp(payload[1..]),
            'z' => self.cmdClearBp(payload[1..]),
            'H' => self.sendOk(),
            'q' => self.cmdQuery(payload[1..]),
            else => self.sendEmpty(),
        }
    }

    fn sendStop(self: *GdbServer, signal: []const u8) void {
        var buf: [16]u8 = undefined;
        const reply = std.fmt.bufPrint(&buf, "S{s}", .{signal}) catch return;
        self.sendPacket(reply);
    }

    fn sendOk(self: *GdbServer) void {
        self.sendPacket("OK");
    }

    fn sendEmpty(self: *GdbServer) void {
        self.sendPacket("");
    }

    fn sendRegs(self: *GdbServer, core: *Core) void {
        // 16 general regs + CPSR, each 8 hex chars little-endian.
        var buf: [17 * 8 + 1]u8 = undefined;
        var w_idx: usize = 0;
        for (core.cpu.r) |r| {
            w_idx += fmtU32Le(buf[w_idx..], r);
        }
        const cpsr_u32: u32 = @bitCast(core.cpu.cpsr);
        w_idx += fmtU32Le(buf[w_idx..], cpsr_u32);
        self.sendPacket(buf[0..w_idx]);
    }

    fn recvRegs(self: *GdbServer, core: *Core, hex: []const u8) void {
        _ = self;
        var i: usize = 0;
        for (&core.cpu.r) |*r| {
            if (i + 8 > hex.len) return;
            r.* = parseU32Le(hex[i .. i + 8]) orelse return;
            i += 8;
        }
        if (i + 8 <= hex.len) {
            const v = parseU32Le(hex[i .. i + 8]) orelse return;
            core.cpu.cpsr = @bitCast(v);
        }
    }

    fn cmdReadMem(self: *GdbServer, core: *Core, args: []const u8) void {
        const comma = std.mem.indexOfScalar(u8, args, ',') orelse return self.sendEmpty();
        const addr = std.fmt.parseInt(u32, args[0..comma], 16) catch return self.sendEmpty();
        const len = std.fmt.parseInt(u32, args[comma + 1 ..], 16) catch return self.sendEmpty();
        var out: [512]u8 = undefined;
        var oi: usize = 0;
        var i: u32 = 0;
        while (i < len and oi + 2 <= out.len) : (i += 1) {
            const b = core.bus.read(u8, addr + i);
            _ = std.fmt.bufPrint(out[oi .. oi + 2], "{x:0>2}", .{b}) catch break;
            oi += 2;
        }
        self.sendPacket(out[0..oi]);
    }

    fn cmdWriteMem(self: *GdbServer, core: *Core, args: []const u8) void {
        const colon = std.mem.indexOfScalar(u8, args, ':') orelse return self.sendEmpty();
        const head = args[0..colon];
        const data = args[colon + 1 ..];
        const comma = std.mem.indexOfScalar(u8, head, ',') orelse return self.sendEmpty();
        const addr = std.fmt.parseInt(u32, head[0..comma], 16) catch return self.sendEmpty();
        const len = std.fmt.parseInt(u32, head[comma + 1 ..], 16) catch return self.sendEmpty();
        var i: u32 = 0;
        while (i < len and i * 2 + 2 <= data.len) : (i += 1) {
            const b = std.fmt.parseInt(u8, data[i * 2 .. i * 2 + 2], 16) catch return self.sendEmpty();
            core.bus.write(u8, addr + i, b);
        }
        self.sendOk();
    }

    fn cmdSetBp(self: *GdbServer, args: []const u8) void {
        if (args.len < 4 or args[0] != '0') return self.sendEmpty();
        const c1 = std.mem.indexOfScalar(u8, args[2..], ',') orelse return self.sendEmpty();
        const addr = std.fmt.parseInt(u32, args[2 .. 2 + c1], 16) catch return self.sendEmpty();
        if (self.bp_count < self.breakpoints.len) {
            self.breakpoints[self.bp_count] = addr;
            self.bp_count += 1;
        }
        self.sendOk();
    }

    fn cmdClearBp(self: *GdbServer, args: []const u8) void {
        if (args.len < 4 or args[0] != '0') return self.sendEmpty();
        const c1 = std.mem.indexOfScalar(u8, args[2..], ',') orelse return self.sendEmpty();
        const addr = std.fmt.parseInt(u32, args[2 .. 2 + c1], 16) catch return self.sendEmpty();
        var i: u8 = 0;
        while (i < self.bp_count) : (i += 1) {
            if (self.breakpoints[i] == addr) {
                self.breakpoints[i] = self.breakpoints[self.bp_count - 1];
                self.bp_count -= 1;
                break;
            }
        }
        self.sendOk();
    }

    fn cmdQuery(self: *GdbServer, args: []const u8) void {
        if (std.mem.startsWith(u8, args, "Supported")) {
            self.sendPacket("PacketSize=4000");
        } else if (std.mem.startsWith(u8, args, "C")) {
            self.sendPacket("QC1");
        } else if (std.mem.startsWith(u8, args, "Attached")) {
            self.sendPacket("1");
        } else {
            self.sendEmpty();
        }
    }

    fn sendPacket(self: *GdbServer, payload: []const u8) void {
        var buf: [4096]u8 = undefined;
        if (payload.len + 4 > buf.len) return;
        buf[0] = '$';
        @memcpy(buf[1..][0..payload.len], payload);
        var ck: u8 = 0;
        for (payload) |b| ck +%= b;
        const sfx = std.fmt.bufPrint(buf[1 + payload.len ..], "#{x:0>2}", .{ck}) catch return;
        const total = 1 + payload.len + sfx.len;
        _ = write(self.conn_fd, buf[0..total].ptr, total);
    }

    /// Called after each emulated instruction in step mode.
    pub fn afterStep(self: *GdbServer) void {
        if (self.stepping) {
            self.stepping = false;
            self.stop_requested = true;
            self.sendStop("05");
        }
    }
};

fn fmtU32Le(buf: []u8, v: u32) usize {
    // Little-endian hex: byte 0, byte 1, byte 2, byte 3.
    var i: usize = 0;
    var x = v;
    while (i < 4) : (i += 1) {
        const b: u8 = @truncate(x);
        _ = std.fmt.bufPrint(buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{b}) catch return i * 2;
        x >>= 8;
    }
    return 8;
}

fn parseU32Le(hex: []const u8) ?u32 {
    if (hex.len < 8) return null;
    var v: u32 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const b = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return null;
        v |= @as(u32, b) << @intCast(i * 8);
    }
    return v;
}

test "fmtU32Le emits little-endian bytes" {
    var buf: [8]u8 = undefined;
    _ = fmtU32Le(&buf, 0xDEAD_BEEF);
    try std.testing.expectEqualStrings("efbeadde", &buf);
}

test "parseU32Le reads little-endian bytes" {
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), parseU32Le("efbeadde").?);
}
