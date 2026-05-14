//! Link-cable multiplayer over TCP.
//!
//! Two emulator instances exchange SIO Multi-mode data over a TCP
//! socket: each "transfer" cycle, both sides write their SIOMULTI_SEND
//! value to the peer, and read SIOMULTI0..3 back from the peer.
//!
//! Topology: --link-host opens a listener; --link-connect <host:port>
//! dials. Only 2-player setups are supported (most GBA multiplayer
//! games run fine with 2 GBAs even when the protocol allows 4).
//!
//! Wire format (16 bytes per transfer):
//!   [u16 send_value]
//!   [u16 cnt_lo]
//!   [u32 reserved=0]
//!   [u64 frame_counter]   ; rough sync hint
//!
//! Either side may be host (slot 0) or client (slot 1). We don't model
//! the second-byte handshake of real link cable; the SIO IRQ fires on
//! receipt of the peer's send-value.

const std = @import("std");

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;
const SOL_SOCKET: c_int = 0xFFFF;
const SO_REUSEADDR: c_int = 4;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 4;

const c_in_addr = extern struct { s_addr: u32 };
const c_sockaddr_in = extern struct {
    sin_len: u8,
    sin_family: u8,
    sin_port: u16,
    sin_addr: c_in_addr,
    sin_zero: [8]u8,
};
const c_sockaddr = extern struct { sa_family: u16, sa_data: [14]u8 };

extern fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern fn bind(sockfd: c_int, addr: *const c_sockaddr, addrlen: u32) c_int;
extern fn listen(sockfd: c_int, backlog: c_int) c_int;
extern fn accept(sockfd: c_int, addr: ?*c_sockaddr, addrlen: ?*u32) c_int;
extern fn connect(sockfd: c_int, addr: *const c_sockaddr, addrlen: u32) c_int;
extern fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: u32) c_int;
extern fn close(fd: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
extern fn htons(host: u16) u16;
extern fn inet_addr(cp: [*:0]const u8) u32;

pub const Role = enum { host, client };

pub const Link = struct {
    role: Role,
    listen_fd: c_int = -1,
    conn_fd: c_int = -1,
    /// Peer's most recent send-value, latched into our SIOMULTI<idx>
    /// on the next "transfer" event.
    peer_value: u16 = 0xFFFF,
    /// Most recent local send (raw cache so the host can echo on demand).
    local_value: u16 = 0xFFFF,

    pub fn initHost(port: u16) ?Link {
        const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s < 0) return null;
        var yes: c_int = 1;
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, @sizeOf(c_int));
        var addr = c_sockaddr_in{
            .sin_len = @sizeOf(c_sockaddr_in),
            .sin_family = AF_INET,
            .sin_port = htons(port),
            .sin_addr = .{ .s_addr = 0 },
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
        const fl = fcntl(s, F_GETFL, 0);
        _ = fcntl(s, F_SETFL, fl | O_NONBLOCK);
        std.debug.print("[link] hosting on port {d}\n", .{port});
        return .{ .role = .host, .listen_fd = s };
    }

    pub fn initClient(host: [*:0]const u8, port: u16) ?Link {
        const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s < 0) return null;
        var addr = c_sockaddr_in{
            .sin_len = @sizeOf(c_sockaddr_in),
            .sin_family = AF_INET,
            .sin_port = htons(port),
            .sin_addr = .{ .s_addr = inet_addr(host) },
            .sin_zero = [_]u8{0} ** 8,
        };
        if (connect(s, @ptrCast(&addr), @sizeOf(c_sockaddr_in)) < 0) {
            _ = close(s);
            std.debug.print("[link] connect failed\n", .{});
            return null;
        }
        const fl = fcntl(s, F_GETFL, 0);
        _ = fcntl(s, F_SETFL, fl | O_NONBLOCK);
        std.debug.print("[link] connected as client\n", .{});
        return .{ .role = .client, .conn_fd = s };
    }

    pub fn deinit(self: *Link) void {
        if (self.conn_fd >= 0) _ = close(self.conn_fd);
        if (self.listen_fd >= 0) _ = close(self.listen_fd);
    }

    /// Accept a pending client connection. Host-only.
    pub fn pollAccept(self: *Link) bool {
        if (self.role != .host or self.conn_fd >= 0 or self.listen_fd < 0) return false;
        const fd = accept(self.listen_fd, null, null);
        if (fd < 0) return false;
        const fl = fcntl(fd, F_GETFL, 0);
        _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        self.conn_fd = fd;
        std.debug.print("[link] peer connected\n", .{});
        return true;
    }

    pub fn isConnected(self: *const Link) bool {
        return self.conn_fd >= 0;
    }

    /// Send the local SIO Multi-send value to the peer. Called from
    /// io.zig when SIOCNT bit 15 (start) is set.
    pub fn sendValue(self: *Link, v: u16) void {
        if (self.conn_fd < 0) return;
        self.local_value = v;
        const buf: [2]u8 = .{ @truncate(v), @truncate(v >> 8) };
        _ = write(self.conn_fd, &buf, 2);
    }

    /// Drain a 2-byte value from the peer if one is available. Returns
    /// true if peer_value was updated.
    pub fn poll(self: *Link) bool {
        if (self.conn_fd < 0) return false;
        var buf: [2]u8 = undefined;
        const n = read(self.conn_fd, &buf, 2);
        if (n == 2) {
            self.peer_value = @as(u16, buf[0]) | (@as(u16, buf[1]) << 8);
            return true;
        }
        if (n == 0) {
            _ = close(self.conn_fd);
            self.conn_fd = -1;
            std.debug.print("[link] peer disconnected\n", .{});
        }
        return false;
    }
};
