//! Minimal direct SDL2 bindings.
//!
//! We deliberately avoid `@cImport(SDL.h)` because Zig 0.16's bundled clang
//! headers cannot parse Apple's ARM Neon intrinsics on Apple Silicon. The
//! emulator only needs ~12 SDL functions, so binding by hand is cleaner than
//! fighting libclang.

const std = @import("std");
const Keypad = @import("../keypad/keypad.zig").Keypad;
const Button = @import("../keypad/keypad.zig").Button;

pub const WIDTH: c_int = 240;
pub const HEIGHT: c_int = 160;
pub const SCALE: c_int = 3;
const FB_LEN: usize = @intCast(WIDTH * HEIGHT);

const SDL_Window = opaque {};
const SDL_Renderer = opaque {};
const SDL_Texture = opaque {};

const SDL_Keysym = extern struct {
    scancode: c_int,
    sym: i32,
    mod: u16,
    _unused: u32,
};

const SDL_KeyboardEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    state: u8,
    repeat: u8,
    _pad2: u8,
    _pad3: u8,
    keysym: SDL_Keysym,
};

const SDL_Event = extern union {
    type: u32,
    key: SDL_KeyboardEvent,
    _pad: [56]u8,
};

extern fn SDL_Init(flags: u32) c_int;
extern fn SDL_Quit() void;
extern fn SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) ?*SDL_Window;
extern fn SDL_DestroyWindow(window: *SDL_Window) void;
extern fn SDL_CreateRenderer(window: *SDL_Window, index: c_int, flags: u32) ?*SDL_Renderer;
extern fn SDL_DestroyRenderer(renderer: *SDL_Renderer) void;
extern fn SDL_CreateTexture(renderer: *SDL_Renderer, format: u32, access: c_int, w: c_int, h: c_int) ?*SDL_Texture;
extern fn SDL_DestroyTexture(texture: *SDL_Texture) void;
extern fn SDL_UpdateTexture(texture: *SDL_Texture, rect: ?*const anyopaque, pixels: *const anyopaque, pitch: c_int) c_int;
extern fn SDL_RenderClear(renderer: *SDL_Renderer) c_int;
extern fn SDL_RenderCopy(renderer: *SDL_Renderer, texture: *SDL_Texture, src: ?*const anyopaque, dst: ?*const anyopaque) c_int;
extern fn SDL_RenderPresent(renderer: *SDL_Renderer) void;
extern fn SDL_PollEvent(event: *SDL_Event) c_int;
extern fn SDL_GetError() [*:0]const u8;

// --- Audio ---
const SDL_AudioSpec = extern struct {
    freq: c_int,
    format: u16,
    channels: u8,
    silence: u8,
    samples: u16,
    _pad: u16,
    size: u32,
    callback: ?*const fn (?*anyopaque, [*]u8, c_int) callconv(.c) void,
    userdata: ?*anyopaque,
};
extern fn SDL_OpenAudio(desired: *SDL_AudioSpec, obtained: ?*SDL_AudioSpec) c_int;
extern fn SDL_CloseAudio() void;
extern fn SDL_PauseAudio(pause_on: c_int) void;
extern fn SDL_QueueAudio(dev: u32, data: *const anyopaque, len: u32) c_int;
extern fn SDL_GetQueuedAudioSize(dev: u32) u32;
extern fn SDL_ClearQueuedAudio(dev: u32) void;
extern fn SDL_OpenAudioDevice(device: ?[*:0]const u8, iscapture: c_int, desired: *const SDL_AudioSpec, obtained: ?*SDL_AudioSpec, allowed_changes: c_int) u32;
extern fn SDL_PauseAudioDevice(dev: u32, pause_on: c_int) void;

const AUDIO_S16LSB: u16 = 0x8010;
const SDL_INIT_VIDEO: u32 = 0x20;
const SDL_INIT_AUDIO: u32 = 0x10;
const SDL_WINDOWPOS_UNDEFINED: c_int = 0x1FFF_0000;
const SDL_WINDOW_SHOWN: u32 = 0x4;
const SDL_RENDERER_ACCELERATED: u32 = 0x2;
const SDL_RENDERER_PRESENTVSYNC: u32 = 0x4;
const SDL_PIXELFORMAT_ARGB8888: u32 = 0x16362004;
const SDL_TEXTUREACCESS_STREAMING: c_int = 1;
const SDL_QUIT: u32 = 0x100;
const SDL_KEYDOWN: u32 = 0x300;
const SDL_KEYUP: u32 = 0x301;

// SDLK values for the keys we care about.
const SDLK_ESCAPE: i32 = 27;
const SDLK_RETURN: i32 = 13;
const SDLK_SPACE: i32 = 32;
const SDLK_TAB: i32 = 9;
const SDLK_BACKSPACE: i32 = 8;
const SDLK_a: i32 = 97;
const SDLK_s: i32 = 115;
const SDLK_x: i32 = 120;
const SDLK_z: i32 = 122;
// SDLK function keys: F1..F12 = 0x4000003A..0x40000045.
const SDLK_F1: i32 = 0x4000003A;
const SDLK_F2: i32 = 0x4000003B;
const SDLK_F11: i32 = 0x40000044;
const SDLK_F12: i32 = 0x40000045;
// Arrows and shift use scancodes shifted into the upper range — easier to
// match on the scancode directly.
const SDL_SCANCODE_RIGHT: c_int = 79;
const SDL_SCANCODE_LEFT: c_int = 80;
const SDL_SCANCODE_DOWN: c_int = 81;
const SDL_SCANCODE_UP: c_int = 82;
const SDL_SCANCODE_RSHIFT: c_int = 229;
const SDL_SCANCODE_LSHIFT: c_int = 225;

pub const Error = error{
    SdlInit,
    SdlWindow,
    SdlRenderer,
    SdlTexture,
};

/// Non-gameplay key events surfaced to the main loop.
pub const HotKeyEvent = enum {
    none,
    save_state,
    load_state,
    fast_forward_toggle,
    rewind_press,
    rewind_release,
    fullscreen_toggle,
    screenshot,
};

pub const Frontend = struct {
    window: *SDL_Window,
    renderer: *SDL_Renderer,
    texture: *SDL_Texture,
    audio_dev: u32 = 0,
    audio_buf: [4096]i16 = [_]i16{0} ** 4096,
    fullscreen: bool = false,

    pub fn init() Error!Frontend {
        if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) != 0) return error.SdlInit;
        errdefer SDL_Quit();

        const window = SDL_CreateWindow(
            "nza",
            SDL_WINDOWPOS_UNDEFINED,
            SDL_WINDOWPOS_UNDEFINED,
            WIDTH * SCALE,
            HEIGHT * SCALE,
            SDL_WINDOW_SHOWN,
        ) orelse return error.SdlWindow;
        errdefer SDL_DestroyWindow(window);

        const renderer = SDL_CreateRenderer(
            window,
            -1,
            SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC,
        ) orelse return error.SdlRenderer;
        errdefer SDL_DestroyRenderer(renderer);

        const texture = SDL_CreateTexture(
            renderer,
            SDL_PIXELFORMAT_ARGB8888,
            SDL_TEXTUREACCESS_STREAMING,
            WIDTH,
            HEIGHT,
        ) orelse return error.SdlTexture;

        // Audio: stereo i16 at the APU sample rate.
        var desired: SDL_AudioSpec = .{
            .freq = 32768,
            .format = AUDIO_S16LSB,
            .channels = 2,
            .silence = 0,
            .samples = 1024,
            ._pad = 0,
            .size = 0,
            .callback = null, // queue-driven
            .userdata = null,
        };
        const dev = SDL_OpenAudioDevice(null, 0, &desired, null, 0);
        if (dev != 0) {
            SDL_PauseAudioDevice(dev, 0); // start playing
        }

        return .{
            .window = window,
            .renderer = renderer,
            .texture = texture,
            .audio_dev = dev,
        };
    }

    pub fn deinit(self: *Frontend) void {
        if (self.audio_dev != 0) SDL_PauseAudioDevice(self.audio_dev, 1);
        SDL_DestroyTexture(self.texture);
        SDL_DestroyRenderer(self.renderer);
        SDL_DestroyWindow(self.window);
        SDL_Quit();
    }

    /// Drain `apu.out` and queue the samples to SDL. Returns SDL's queued-byte
    /// count so the main loop can throttle.
    pub fn pushAudio(self: *Frontend, apu: anytype) u32 {
        if (self.audio_dev == 0) return 0;
        const n = apu.drain(&self.audio_buf);
        if (n > 0) {
            _ = SDL_QueueAudio(self.audio_dev, &self.audio_buf, @intCast(n * @sizeOf(i16)));
        }
        return SDL_GetQueuedAudioSize(self.audio_dev);
    }

    /// Upload an ARGB8888 240×160 framebuffer and present it scaled to the window.
    pub fn present(self: *Frontend, framebuffer: *const [FB_LEN]u32) void {
        _ = SDL_UpdateTexture(self.texture, null, framebuffer, WIDTH * @sizeOf(u32));
        _ = SDL_RenderClear(self.renderer);
        _ = SDL_RenderCopy(self.renderer, self.texture, null, null);
        SDL_RenderPresent(self.renderer);
    }

    /// Pump SDL events; update `keypad` for any GBA buttons that are pressed
    /// or released. `out_hotkeys` receives non-gameplay key events (F1/F2/Tab
    /// etc.) for the main loop to dispatch. Returns false when the user
    /// requests quit.
    pub fn pollEvents(self: *Frontend, keypad: *Keypad, out_hotkeys: *std.ArrayList(HotKeyEvent), allocator: std.mem.Allocator) bool {
        _ = self;
        var ev: SDL_Event = undefined;
        while (SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                SDL_QUIT => return false,
                SDL_KEYDOWN, SDL_KEYUP => {
                    const down = ev.type == SDL_KEYDOWN;
                    if (down and ev.key.keysym.sym == SDLK_ESCAPE) return false;
                    if (mapHotKey(ev.key.keysym.sym, down)) |hk| {
                        out_hotkeys.append(allocator, hk) catch {};
                        continue;
                    }
                    if (mapKey(ev.key.keysym.sym, ev.key.keysym.scancode)) |b| {
                        if (down) keypad.press(b) else keypad.release(b);
                    }
                },
                else => {},
            }
        }
        return true;
    }

    pub fn toggleFullscreen(self: *Frontend) void {
        self.fullscreen = !self.fullscreen;
        const flag: u32 = if (self.fullscreen) 0x1001 else 0; // SDL_WINDOW_FULLSCREEN_DESKTOP
        _ = SDL_SetWindowFullscreen(self.window, flag);
    }
};

extern fn SDL_SetWindowFullscreen(window: *SDL_Window, flags: u32) c_int;

fn mapHotKey(sym: i32, down: bool) ?HotKeyEvent {
    return switch (sym) {
        SDLK_F1 => if (down) HotKeyEvent.save_state else null,
        SDLK_F2 => if (down) HotKeyEvent.load_state else null,
        SDLK_F11 => if (down) HotKeyEvent.fullscreen_toggle else null,
        SDLK_F12 => if (down) HotKeyEvent.screenshot else null,
        SDLK_TAB => if (down) HotKeyEvent.fast_forward_toggle else null,
        SDLK_BACKSPACE => if (down) HotKeyEvent.rewind_press else HotKeyEvent.rewind_release,
        else => null,
    };
}

fn mapKey(sym: i32, scancode: c_int) ?Button {
    // Keysym mapping for ASCII letters; scancode for arrows + modifiers.
    switch (sym) {
        SDLK_z => return .a,
        SDLK_x => return .b,
        SDLK_a => return .l,
        SDLK_s => return .r,
        SDLK_RETURN => return .start,
        else => {},
    }
    switch (scancode) {
        SDL_SCANCODE_LEFT => return .left,
        SDL_SCANCODE_RIGHT => return .right,
        SDL_SCANCODE_UP => return .up,
        SDL_SCANCODE_DOWN => return .down,
        SDL_SCANCODE_RSHIFT, SDL_SCANCODE_LSHIFT => return .select,
        else => return null,
    }
}
