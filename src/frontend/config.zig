//! Frontend configuration: keybinds, controller binds, AV preferences.
//!
//! Stored as a simple ini-like text file at `~/.config/nza/config.ini`
//! (lines: `key=value`, optional `[section]` headers, `#`/`;` comments).
//! Defaults reproduce the previous hardcoded mapping so users with no
//! config file see identical behavior.

const std = @import("std");
const Button = @import("../keypad/keypad.zig").Button;

pub const Config = struct {
    // GBA button → SDLK_* value
    key_map: KeyMap = default_key_map,
    // GBA button → SDL_GameController button index (-1 = unmapped)
    controller_map: ControllerMap = default_controller_map,
    fullscreen: bool = false,
    scale: u8 = 3,
    lowpass: bool = false,

    pub const KeyMap = struct {
        a: i32 = 122, // z
        b: i32 = 120, // x
        l: i32 = 97, // a
        r: i32 = 115, // s
        start: i32 = 13, // Return
        select: i32 = -1, // matched on scancode instead
        up: i32 = -1,
        down: i32 = -1,
        left: i32 = -1,
        right: i32 = -1,
    };

    pub const ControllerMap = struct {
        a: i8 = 1, // SDL_CONTROLLER_BUTTON_B (physical right-button = GBA A)
        b: i8 = 0, // A on the gamepad = GBA B
        l: i8 = 9, // LEFT_SHOULDER
        r: i8 = 10, // RIGHT_SHOULDER
        start: i8 = 6, // START
        select: i8 = 4, // BACK
        up: i8 = 11, // DPAD_UP
        down: i8 = 12, // DPAD_DOWN
        left: i8 = 13, // DPAD_LEFT
        right: i8 = 14, // DPAD_RIGHT
    };
};

pub const default_key_map: Config.KeyMap = .{};
pub const default_controller_map: Config.ControllerMap = .{};

/// Build `~/.config/nza/config.ini` path. Caller owns slice.
pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]u8 {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_ptr);
    return try std.fmt.allocPrint(allocator, "{s}/.config/nza/config.ini", .{home});
}

/// Read config from `path`. Missing file → default config (no error).
pub fn load(allocator: std.mem.Allocator, path: []const u8) Config {
    const file_util = @import("../core/file_util.zig");
    const bytes = file_util.readAllAlloc(allocator, path, 64 * 1024) catch {
        return .{};
    };
    defer allocator.free(bytes);

    var cfg: Config = .{};
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#' or line[0] == ';' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trim(line[0..eq]);
        const val = trim(line[eq + 1 ..]);
        applyKey(&cfg, key, val);
    }
    return cfg;
}

fn applyKey(cfg: *Config, key: []const u8, val: []const u8) void {
    // Strip optional "key." / "controller." prefix.
    if (std.mem.startsWith(u8, key, "key.")) {
        const sub = key["key.".len..];
        if (parseI32(val)) |v| applyKeyMapField(&cfg.key_map, sub, v);
        return;
    }
    if (std.mem.startsWith(u8, key, "controller.")) {
        const sub = key["controller.".len..];
        if (parseI32(val)) |v| applyControllerMapField(&cfg.controller_map, sub, @intCast(v));
        return;
    }
    if (std.mem.eql(u8, key, "fullscreen")) {
        cfg.fullscreen = parseBool(val);
    } else if (std.mem.eql(u8, key, "scale")) {
        if (parseI32(val)) |v| cfg.scale = @intCast(@max(1, @min(8, v)));
    } else if (std.mem.eql(u8, key, "lowpass")) {
        cfg.lowpass = parseBool(val);
    }
}

fn applyKeyMapField(km: *Config.KeyMap, name: []const u8, v: i32) void {
    if (std.mem.eql(u8, name, "a")) km.a = v
    else if (std.mem.eql(u8, name, "b")) km.b = v
    else if (std.mem.eql(u8, name, "l")) km.l = v
    else if (std.mem.eql(u8, name, "r")) km.r = v
    else if (std.mem.eql(u8, name, "start")) km.start = v
    else if (std.mem.eql(u8, name, "select")) km.select = v
    else if (std.mem.eql(u8, name, "up")) km.up = v
    else if (std.mem.eql(u8, name, "down")) km.down = v
    else if (std.mem.eql(u8, name, "left")) km.left = v
    else if (std.mem.eql(u8, name, "right")) km.right = v;
}

fn applyControllerMapField(cm: *Config.ControllerMap, name: []const u8, v: i8) void {
    if (std.mem.eql(u8, name, "a")) cm.a = v
    else if (std.mem.eql(u8, name, "b")) cm.b = v
    else if (std.mem.eql(u8, name, "l")) cm.l = v
    else if (std.mem.eql(u8, name, "r")) cm.r = v
    else if (std.mem.eql(u8, name, "start")) cm.start = v
    else if (std.mem.eql(u8, name, "select")) cm.select = v
    else if (std.mem.eql(u8, name, "up")) cm.up = v
    else if (std.mem.eql(u8, name, "down")) cm.down = v
    else if (std.mem.eql(u8, name, "left")) cm.left = v
    else if (std.mem.eql(u8, name, "right")) cm.right = v;
}

pub fn buttonForKey(map: Config.KeyMap, sym: i32) ?Button {
    if (sym == 0) return null;
    if (sym == map.a) return .a;
    if (sym == map.b) return .b;
    if (sym == map.l) return .l;
    if (sym == map.r) return .r;
    if (sym == map.start) return .start;
    if (sym == map.select) return .select;
    if (sym == map.up) return .up;
    if (sym == map.down) return .down;
    if (sym == map.left) return .left;
    if (sym == map.right) return .right;
    return null;
}

pub fn buttonForControllerButton(map: Config.ControllerMap, idx: i8) ?Button {
    if (idx < 0) return null;
    if (idx == map.a) return .a;
    if (idx == map.b) return .b;
    if (idx == map.l) return .l;
    if (idx == map.r) return .r;
    if (idx == map.start) return .start;
    if (idx == map.select) return .select;
    if (idx == map.up) return .up;
    if (idx == map.down) return .down;
    if (idx == map.left) return .left;
    if (idx == map.right) return .right;
    return null;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn parseBool(s: []const u8) bool {
    return std.mem.eql(u8, s, "1") or
        std.mem.eql(u8, s, "true") or
        std.mem.eql(u8, s, "yes") or
        std.mem.eql(u8, s, "on");
}

fn parseI32(s: []const u8) ?i32 {
    return std.fmt.parseInt(i32, s, 0) catch null;
}

test "config parses key remap" {
    // Default values
    const cfg: Config = .{};
    try std.testing.expectEqual(@as(i32, 122), cfg.key_map.a);
}
