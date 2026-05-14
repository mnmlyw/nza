//! PPU — scanline state machine + framebuffer rendering.
//!
//! Timing (per GBATEK):
//!   - 240 H-draw cycles + 68 H-blank cycles = 308 dots per scanline
//!   - Real GBA: 4 cycles/dot → 1232 cycles per scanline
//!   - 160 visible scanlines + 68 V-blank scanlines = 228 total
//!   - Frame: 228 * 1232 = 280_896 cycles
//!
//! Rendering happens once per scanline, at the H-draw → H-blank transition.
//! We render the entire visible line into `framebuffer[y*240 .. y*240+240]`
//! using the current DISPCNT mode. Frontend uploads this to its texture once
//! per frame (after V-blank starts).

const std = @import("std");
const Scheduler = @import("../core/scheduler.zig").Scheduler;
const Io = @import("../core/io.zig").Io;
const Irq = @import("../irq/irq.zig").Irq;
const Bus = @import("../core/bus.zig").Bus;
const Dma = @import("../dma/dma.zig").Dma;

pub const SCREEN_WIDTH: u32 = 240;
pub const SCREEN_HEIGHT: u32 = 160;
const FB_LEN: usize = SCREEN_WIDTH * SCREEN_HEIGHT;

pub const CYCLES_PER_HDRAW: u64 = 240 * 4;
pub const CYCLES_PER_HBLANK: u64 = 68 * 4;
pub const CYCLES_PER_SCANLINE: u64 = CYCLES_PER_HDRAW + CYCLES_PER_HBLANK;
pub const VBLANK_FIRST_LINE: u16 = 160;
pub const TOTAL_LINES: u16 = 228;

const TAG_HDRAW_END: u32 = 0x1000;
const TAG_HBLANK_END: u32 = 0x1001;

/// Per-pixel layer state. Each BG renderer writes one of these to its
/// layer buffer; the compositor reads them at end of scanline.
pub const LayerPixel = packed struct(u32) {
    /// Raw BGR555 color from PRAM (or the actual u16 for direct-color modes).
    color: u16 = 0,
    /// BG priority 0..3 (0=topmost). For sprites, this is the OBJ priority.
    priority: u8 = 4,
    /// bit 0 = pixel is opaque
    /// bit 1 = obj-window source pixel
    /// bit 2 = sprite is "semi-transparent" (overrides BLDCNT 1st-target)
    flags: u8 = 0,
};
pub const FLAG_OPAQUE: u8 = 0b001;
pub const FLAG_OBJ_WINDOW: u8 = 0b010;
pub const FLAG_OBJ_BLEND: u8 = 0b100;

pub const Ppu = struct {
    sched: *Scheduler,
    io: *Io,
    irq: *Irq,
    bus: *Bus,
    dma: *Dma,

    /// 32-bit ARGB8888 framebuffer (matches SDL_PIXELFORMAT_ARGB8888).
    framebuffer: [FB_LEN]u32 = [_]u32{0} ** FB_LEN,

    /// Per-layer line buffers (per-scanline scratch). bg_line[0..3] are
    /// BG0..BG3; obj_line is the merged OBJ result; obj_win is set by
    /// "OBJ window" sprites.
    bg_line: [4][SCREEN_WIDTH]LayerPixel = [_][SCREEN_WIDTH]LayerPixel{[_]LayerPixel{.{}} ** SCREEN_WIDTH} ** 4,
    obj_line: [SCREEN_WIDTH]LayerPixel = [_]LayerPixel{.{}} ** SCREEN_WIDTH,
    obj_win: [SCREEN_WIDTH]bool = [_]bool{false} ** SCREEN_WIDTH,

    /// Affine BG internal X/Y reference. Reloaded from BGxX/BGxY MMIO at
    /// VBlank start; incremented by PB/PD after every rendered scanline.
    /// Index 0 = BG2, Index 1 = BG3.
    affine_x: [2]i32 = [_]i32{ 0, 0 },
    affine_y: [2]i32 = [_]i32{ 0, 0 },

    pub fn init(self: *Ppu) void {
        self.io.vcount = 0;
        self.io.dispstat &= 0xFF07;
        self.sched.schedule(CYCLES_PER_HDRAW, onHdrawEnd, self, TAG_HDRAW_END);
    }

    fn onHdrawEnd(ctx: *anyopaque, late: u64) void {
        _ = late;
        const self: *Ppu = @ptrCast(@alignCast(ctx));

        // Render the line we just finished drawing.
        if (self.io.vcount < @as(u16, @intCast(SCREEN_HEIGHT))) {
            renderScanline(self, self.io.vcount);
            // Advance affine BG internal ref by PB/PD for the next scanline.
            const pb_bg2 = @as(i32, @as(i16, @bitCast(self.io.read(u16, 0x22))));
            const pd_bg2 = @as(i32, @as(i16, @bitCast(self.io.read(u16, 0x26))));
            const pb_bg3 = @as(i32, @as(i16, @bitCast(self.io.read(u16, 0x32))));
            const pd_bg3 = @as(i32, @as(i16, @bitCast(self.io.read(u16, 0x36))));
            self.affine_x[0] +%= pb_bg2;
            self.affine_y[0] +%= pd_bg2;
            self.affine_x[1] +%= pb_bg3;
            self.affine_y[1] +%= pd_bg3;
        }

        // Enter H-blank.
        self.io.dispstat |= 0x0002;
        if ((self.io.dispstat & 0x0010) != 0) self.irq.raise(.hblank);
        if (self.io.vcount < @as(u16, @intCast(SCREEN_HEIGHT))) {
            self.dma.onEvent(.hblank);
        }
        self.sched.schedule(CYCLES_PER_HBLANK, onHblankEnd, self, TAG_HBLANK_END);
    }

    fn onHblankEnd(ctx: *anyopaque, late: u64) void {
        _ = late;
        const self: *Ppu = @ptrCast(@alignCast(ctx));

        self.io.dispstat &= ~@as(u16, 0x0002);
        self.io.vcount += 1;
        if (self.io.vcount >= TOTAL_LINES) self.io.vcount = 0;

        if (self.io.vcount == VBLANK_FIRST_LINE) {
            self.io.dispstat |= 0x0001;
            // We raise the VBlank flag in IF unconditionally rather than
            // gating on DISPSTAT.VBI_enable. NBA/mGBA do the same.
            self.irq.raise(.vblank);
            self.dma.onEvent(.vblank);
        } else if (self.io.vcount == 0) {
            // Top of frame: reload internal affine refs from MMIO. Real
            // hardware does this at VBlank start (which is end of line 159
            // → vcount=160 above), but reloading at vcount=0 — the start
            // of the visible frame — is functionally equivalent because
            // the affine BG isn't rendered during VBlank anyway.
            self.affine_x[0] = signExtend28(self.io.read(u32, 0x28));
            self.affine_y[0] = signExtend28(self.io.read(u32, 0x2C));
            self.affine_x[1] = signExtend28(self.io.read(u32, 0x38));
            self.affine_y[1] = signExtend28(self.io.read(u32, 0x3C));
            self.io.dispstat &= ~@as(u16, 0x0001);
        }

        const vcount_setting: u16 = self.io.dispstat >> 8;
        if (self.io.vcount == vcount_setting) {
            self.io.dispstat |= 0x0004;
            if ((self.io.dispstat & 0x0020) != 0) self.irq.raise(.vcount);
        } else {
            self.io.dispstat &= ~@as(u16, 0x0004);
        }

        self.sched.schedule(CYCLES_PER_HDRAW, onHdrawEnd, self, TAG_HDRAW_END);
    }
};

// =====================================================================
// Color conversion
// =====================================================================

/// GBA 15-bit BGR555 → SDL ARGB8888.
inline fn bgr555ToArgb(c: u16) u32 {
    const r5: u32 = c & 0x1F;
    const g5: u32 = (c >> 5) & 0x1F;
    const b5: u32 = (c >> 10) & 0x1F;
    // 5-bit → 8-bit: replicate the top three bits into the low three.
    const r = (r5 << 3) | (r5 >> 2);
    const g = (g5 << 3) | (g5 >> 2);
    const b = (b5 << 3) | (b5 >> 2);
    return 0xFF00_0000 | (r << 16) | (g << 8) | b;
}

inline fn vramReadU16(bus: *const Bus, vram_addr: u32) u16 {
    return @as(u16, bus.vram[vram_addr]) | (@as(u16, bus.vram[vram_addr + 1]) << 8);
}

inline fn pramBgColor(bus: *const Bus, idx: u8) u16 {
    const a: u32 = @as(u32, idx) * 2;
    return @as(u16, bus.pram[a]) | (@as(u16, bus.pram[a + 1]) << 8);
}

inline fn pramObjColor(bus: *const Bus, idx: u8) u16 {
    const a: u32 = 0x200 + @as(u32, idx) * 2;
    return @as(u16, bus.pram[a]) | (@as(u16, bus.pram[a + 1]) << 8);
}

// =====================================================================
// Scanline rendering dispatcher
// =====================================================================

fn renderScanline(self: *Ppu, y: u16) void {
    const dispcnt = self.io.read(u16, 0x000);

    // Forced blank — display white.
    if ((dispcnt & 0x0080) != 0) {
        const base = @as(usize, y) * SCREEN_WIDTH;
        for (0..SCREEN_WIDTH) |x| self.framebuffer[base + x] = 0xFFFF_FFFF;
        return;
    }

    // Clear per-layer line buffers (M2.2). Default LayerPixel has
    // priority=4 + flags=0 (transparent) — sentinels that the
    // compositor treats as "skip".
    for (&self.bg_line) |*bg_buf| @memset(bg_buf, .{});
    @memset(&self.obj_line, .{});
    @memset(&self.obj_win, false);

    const mode: u3 = @intCast(dispcnt & 7);
    switch (mode) {
        0 => {
            // All four text BGs.
            for (0..4) |i| {
                const bg: u2 = @intCast(i);
                const enable_bit: u4 = 8 + @as(u4, bg);
                if ((dispcnt & (@as(u16, 1) << enable_bit)) != 0) {
                    renderTextBg(self, y, bg);
                }
            }
        },
        1 => {
            if ((dispcnt & (1 << 8)) != 0) renderTextBg(self, y, 0);
            if ((dispcnt & (1 << 9)) != 0) renderTextBg(self, y, 1);
            if ((dispcnt & (1 << 10)) != 0) renderAffineBg(self, y, 2);
        },
        2 => {
            if ((dispcnt & (1 << 10)) != 0) renderAffineBg(self, y, 2);
            if ((dispcnt & (1 << 11)) != 0) renderAffineBg(self, y, 3);
        },
        3 => renderBitmapBg(self, y, 3, dispcnt),
        4 => renderBitmapBg(self, y, 4, dispcnt),
        5 => renderBitmapBg(self, y, 5, dispcnt),
        else => {},
    }

    if ((dispcnt & 0x1000) != 0) renderSprites(self, y, dispcnt);

    applyMosaic(self);

    compositeScanline(self, y, dispcnt);
}

/// Apply MOSAIC horizontal stair-stepping to any BG that has BGCNT.6 set
/// and to OBJ pixels flagged with mosaic (attr0 bit 12 — TODO: we don't
/// track that per-OBJ yet; we apply OBJ mosaic universally if the OBJ-H
/// nibble is non-zero, which matches most games). Vertical mosaic is
/// deferred (would require per-row caching).
fn applyMosaic(self: *Ppu) void {
    const mosaic = self.io.read(u16, 0x04C);
    const bg_h: u8 = @intCast(mosaic & 0xF);
    const obj_h: u8 = @intCast((mosaic >> 8) & 0xF);

    if (bg_h != 0) {
        const step: usize = @as(usize, bg_h) + 1;
        var bi: usize = 0;
        while (bi < 4) : (bi += 1) {
            const bgcnt = self.io.read(u16, 0x008 + @as(u32, @intCast(bi)) * 2);
            if ((bgcnt & 0x40) == 0) continue;
            const buf = &self.bg_line[bi];
            var x: usize = 0;
            while (x < SCREEN_WIDTH) : (x += step) {
                const group_color = buf[x];
                var k: usize = 1;
                while (k < step and x + k < SCREEN_WIDTH) : (k += 1) {
                    buf[x + k] = group_color;
                }
            }
        }
    }

    if (obj_h != 0) {
        const step: usize = @as(usize, obj_h) + 1;
        var x: usize = 0;
        while (x < SCREEN_WIDTH) : (x += step) {
            const group_color = self.obj_line[x];
            var k: usize = 1;
            while (k < step and x + k < SCREEN_WIDTH) : (k += 1) {
                self.obj_line[x + k] = group_color;
            }
        }
    }
}

// =====================================================================
// Compositor — per-pixel layer ordering + alpha/brightness/windows
// =====================================================================

const LAYER_OBJ: u8 = 4;
const LAYER_BD: u8 = 5;

fn compositeScanline(self: *Ppu, y: u16, dispcnt: u16) void {
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    const backdrop_color = pramBgColor(self.bus, 0);
    const obj_enabled = (dispcnt & 0x1000) != 0;
    const bg_enabled = [4]bool{
        (dispcnt & (1 << 8)) != 0,
        (dispcnt & (1 << 9)) != 0,
        (dispcnt & (1 << 10)) != 0,
        (dispcnt & (1 << 11)) != 0,
    };

    const bldcnt = self.io.read(u16, 0x050);
    const blend_mode: u2 = @intCast((bldcnt >> 6) & 0x3);
    const tgt1: u8 = @intCast(bldcnt & 0x3F);
    const tgt2: u8 = @intCast((bldcnt >> 8) & 0x3F);

    const bldalpha = self.io.read(u16, 0x052);
    const eva: u8 = @min(@as(u8, @intCast(bldalpha & 0x1F)), 16);
    const evb: u8 = @min(@as(u8, @intCast((bldalpha >> 8) & 0x1F)), 16);
    const bldy = self.io.read(u16, 0x054);
    const evy: u8 = @min(@as(u8, @intCast(bldy & 0x1F)), 16);

    // Windowing — build a per-pixel "layer enable" mask + a per-pixel
    // "blend enable" flag, both 6-bit (one bit per BG0..BG3 + OBJ + BLD).
    var win_mask: [SCREEN_WIDTH]u8 = undefined;
    const any_window = (dispcnt & 0xE000) != 0;
    if (any_window) {
        buildWindowMask(self, y, dispcnt, &win_mask);
    } else {
        @memset(&win_mask, 0x3F); // everything enabled
    }

    var x: usize = 0;
    while (x < SCREEN_WIDTH) : (x += 1) {
        const win_layers = win_mask[x]; // bits 0..4 = BG0..3,OBJ enable; bit 5 = blend enable
        // Find the two topmost opaque layers (top + bot). Layer order
        // rule: lower priority wins; on tie, OBJ beats BG; among BGs at
        // tie, lower index wins.
        var top_color: u16 = backdrop_color;
        var top_priority: u8 = 5; // worse than any BG/OBJ
        var top_layer: u8 = LAYER_BD;
        var top_is_obj_blend: bool = false;
        var bot_color: u16 = backdrop_color;
        var bot_layer: u8 = LAYER_BD;

        // OBJ candidate.
        const obj_lp = self.obj_line[x];
        if (obj_enabled and (obj_lp.flags & FLAG_OPAQUE) != 0 and (win_layers & 0x10) != 0) {
            top_color = obj_lp.color;
            top_priority = obj_lp.priority;
            top_layer = LAYER_OBJ;
            top_is_obj_blend = (obj_lp.flags & FLAG_OBJ_BLEND) != 0;
        }

        var bi: u8 = 0;
        while (bi < 4) : (bi += 1) {
            if (!bg_enabled[bi]) continue;
            if ((win_layers & (@as(u8, 1) << @intCast(bi))) == 0) continue;
            const lp = self.bg_line[bi][x];
            if ((lp.flags & FLAG_OPAQUE) == 0) continue;
            const better = lp.priority < top_priority or
                (lp.priority == top_priority and top_layer != LAYER_OBJ and bi < top_layer);
            if (better) {
                bot_color = top_color;
                bot_layer = top_layer;
                top_color = lp.color;
                top_priority = lp.priority;
                top_layer = bi;
                top_is_obj_blend = false;
            } else {
                const beat_bot = (bot_layer == LAYER_BD) or
                    lp.priority < bot_priorityOf(self, x, bot_layer, bg_enabled, obj_enabled, top_layer) or
                    (lp.priority == bot_priorityOf(self, x, bot_layer, bg_enabled, obj_enabled, top_layer) and bi < bot_layer);
                if (beat_bot) {
                    bot_color = lp.color;
                    bot_layer = bi;
                }
            }
        }

        // Window may suppress blending at this pixel (bit 5 of win_layers).
        const win_blend_ok = (win_layers & 0x20) != 0;
        const top_is_t1 = layerMask(top_layer) & tgt1 != 0;
        const bot_is_t2 = layerMask(bot_layer) & tgt2 != 0;
        const effective_mode: u2 = if (top_is_obj_blend and bot_is_t2 and win_blend_ok) 1 else if (win_blend_ok) blend_mode else 0;

        var final_color: u16 = top_color;
        switch (effective_mode) {
            0 => {},
            1 => if (top_is_t1 and bot_is_t2) {
                final_color = blendAlpha(top_color, bot_color, eva, evb);
            },
            2 => if (top_is_t1) {
                final_color = blendBrightness(top_color, evy, true);
            },
            3 => if (top_is_t1) {
                final_color = blendBrightness(top_color, evy, false);
            },
        }

        self.framebuffer[base_fb + x] = bgr555ToArgb(final_color);
    }
}

/// Build a 6-bit per-pixel window mask given the current scanline + DISPCNT.
/// Bits 0-4 enable BG0..BG3 + OBJ; bit 5 enables blending.
/// Priority: WIN0 > WIN1 > OBJ_WIN > outside (WINOUT).
fn buildWindowMask(self: *Ppu, y: u16, dispcnt: u16, mask_out: *[SCREEN_WIDTH]u8) void {
    const w0_en = (dispcnt & 0x2000) != 0;
    const w1_en = (dispcnt & 0x4000) != 0;
    const objwin_en = (dispcnt & 0x8000) != 0;

    const win0h = self.io.read(u16, 0x040);
    const win1h = self.io.read(u16, 0x042);
    const win0v = self.io.read(u16, 0x044);
    const win1v = self.io.read(u16, 0x046);
    const winin = self.io.read(u16, 0x048);
    const winout = self.io.read(u16, 0x04A);

    const w0_in: u8 = @intCast(winin & 0x3F);
    const w1_in: u8 = @intCast((winin >> 8) & 0x3F);
    const outside: u8 = @intCast(winout & 0x3F);
    const obj_in: u8 = @intCast((winout >> 8) & 0x3F);

    const w0_x0: u32 = (win0h >> 8) & 0xFF;
    const w0_x1: u32 = win0h & 0xFF;
    const w0_y0: u32 = (win0v >> 8) & 0xFF;
    const w0_y1: u32 = win0v & 0xFF;
    const w1_x0: u32 = (win1h >> 8) & 0xFF;
    const w1_x1: u32 = win1h & 0xFF;
    const w1_y0: u32 = (win1v >> 8) & 0xFF;
    const w1_y1: u32 = win1v & 0xFF;

    const in_w0_y = w0_en and inWindowRange(y, w0_y0, w0_y1);
    const in_w1_y = w1_en and inWindowRange(y, w1_y0, w1_y1);

    var x: usize = 0;
    while (x < SCREEN_WIDTH) : (x += 1) {
        if (in_w0_y and inWindowRange(@intCast(x), w0_x0, w0_x1)) {
            mask_out[x] = w0_in;
        } else if (in_w1_y and inWindowRange(@intCast(x), w1_x0, w1_x1)) {
            mask_out[x] = w1_in;
        } else if (objwin_en and self.obj_win[x]) {
            mask_out[x] = obj_in;
        } else {
            mask_out[x] = outside;
        }
    }
}

/// Real hardware "wrap" window semantics: if start > end, the window
/// covers [start..max] U [0..end]; otherwise plain [start..end). Edge
/// case: if either coord >= 256 it's treated as ≥ display dimension.
fn inWindowRange(value: u32, start: u32, end: u32) bool {
    if (start <= end) return value >= start and value < end;
    return value >= start or value < end;
}

fn layerMask(layer: u8) u8 {
    return @as(u8, 1) << @intCast(layer);
}

/// Helper used inside compositeScanline to read a layer's priority at x
/// for second-target ordering decisions.
fn bot_priorityOf(self: *const Ppu, x: usize, layer: u8, bg_enabled: [4]bool, obj_enabled: bool, top_layer: u8) u8 {
    _ = top_layer;
    if (layer == LAYER_BD) return 5;
    if (layer == LAYER_OBJ) {
        if (!obj_enabled) return 5;
        return self.obj_line[x].priority;
    }
    if (layer < 4 and bg_enabled[layer]) return self.bg_line[layer][x].priority;
    return 5;
}

fn blendAlpha(top: u16, bot: u16, eva: u8, evb: u8) u16 {
    const r_t: u32 = top & 0x1F;
    const g_t: u32 = (top >> 5) & 0x1F;
    const b_t: u32 = (top >> 10) & 0x1F;
    const r_b: u32 = bot & 0x1F;
    const g_b: u32 = (bot >> 5) & 0x1F;
    const b_b: u32 = (bot >> 10) & 0x1F;
    const r: u32 = @min((r_t * eva + r_b * evb) >> 4, 31);
    const g: u32 = @min((g_t * eva + g_b * evb) >> 4, 31);
    const b: u32 = @min((b_t * eva + b_b * evb) >> 4, 31);
    return @intCast(r | (g << 5) | (b << 10));
}

fn blendBrightness(top: u16, evy: u8, brighten: bool) u16 {
    var r: u32 = top & 0x1F;
    var g: u32 = (top >> 5) & 0x1F;
    var b: u32 = (top >> 10) & 0x1F;
    if (brighten) {
        r = r + (((31 - r) * evy) >> 4);
        g = g + (((31 - g) * evy) >> 4);
        b = b + (((31 - b) * evy) >> 4);
    } else {
        r = r - ((r * evy) >> 4);
        g = g - ((g * evy) >> 4);
        b = b - ((b * evy) >> 4);
    }
    return @intCast(r | (g << 5) | (b << 10));
}

/// Sign-extend a 28-bit value (stored in the low bits of u32) to i32.
inline fn signExtend28(v: u32) i32 {
    return @as(i32, @bitCast(v << 4)) >> 4;
}

/// Render an affine (rotation/scaling) BG scanline applying the matrix
/// (PA/PB/PC/PD) and the X/Y reference points. Writes opaque pixels into
/// `self.bg_line[bg]`.
fn renderAffineBg(self: *Ppu, y: u16, bg: u2) void {
    const cnt_offset: u32 = 0x008 + @as(u32, bg) * 2;
    const bgcnt = self.io.read(u16, cnt_offset);
    const priority: u8 = @intCast(bgcnt & 0x3);
    const char_block: u32 = (@as(u32, bgcnt) >> 2) & 0x3;
    const screen_block: u32 = (@as(u32, bgcnt) >> 8) & 0x1F;
    const overflow_wrap = (bgcnt & 0x2000) != 0;
    const size: u2 = @intCast((bgcnt >> 14) & 0x3);
    const map_tiles: u32 = @as(u32, 16) << @intCast(size);
    const map_pixels: i32 = @intCast(map_tiles * 8);
    const char_base = char_block * 0x4000;
    const screen_base = screen_block * 0x800;

    const ref_base: u32 = if (bg == 2) 0x20 else 0x30;
    const pa = @as(i32, @as(i16, @bitCast(self.io.read(u16, ref_base + 0))));
    const pc = @as(i32, @as(i16, @bitCast(self.io.read(u16, ref_base + 4))));

    const affine_idx: usize = bg - 2;
    const x_ref = self.affine_x[affine_idx];
    const y_ref = self.affine_y[affine_idx];
    _ = y;

    const out = &self.bg_line[bg];
    var x: i32 = 0;
    while (x < @as(i32, @intCast(SCREEN_WIDTH))) : (x += 1) {
        const sx = (pa * x + x_ref) >> 8;
        const sy = (pc * x + y_ref) >> 8;

        var px = sx;
        var py = sy;
        if (overflow_wrap) {
            px = @mod(px, map_pixels);
            py = @mod(py, map_pixels);
        } else if (px < 0 or py < 0 or px >= map_pixels or py >= map_pixels) {
            continue;
        }

        const tile_x: u32 = @intCast(@divTrunc(px, 8));
        const tile_y: u32 = @intCast(@divTrunc(py, 8));
        const px_in_tile: u32 = @intCast(@mod(px, 8));
        const py_in_tile: u32 = @intCast(@mod(py, 8));

        const map_addr = screen_base + (tile_y * map_tiles + tile_x);
        if (map_addr >= 0x1_0000) continue;
        const tile_num: u32 = self.bus.vram[map_addr];
        const tile_addr = char_base + tile_num * 64 + py_in_tile * 8 + px_in_tile;
        if (tile_addr >= 0x1_0000) continue;
        const pixel = self.bus.vram[tile_addr];
        if (pixel == 0) continue;
        out[@intCast(x)] = .{
            .color = pramBgColor(self.bus, pixel),
            .priority = priority,
            .flags = FLAG_OPAQUE,
        };
    }
}

// =====================================================================
// Bitmap modes 3/4/5 — written to BG2 line buffer
// =====================================================================

fn renderBitmapBg(self: *Ppu, y: u16, mode: u3, dispcnt: u16) void {
    if ((dispcnt & (1 << 10)) == 0) return; // BG2 must be enabled
    const bgcnt = self.io.read(u16, 0x00C); // BG2CNT
    const priority: u8 = @intCast(bgcnt & 0x3);
    const out = &self.bg_line[2];
    const page_offset: u32 = if ((dispcnt & 0x10) != 0) 0xA000 else 0;
    switch (mode) {
        3 => {
            const base_vram = @as(u32, y) * SCREEN_WIDTH * 2;
            var x: usize = 0;
            while (x < SCREEN_WIDTH) : (x += 1) {
                const c = vramReadU16(self.bus, base_vram + @as(u32, @intCast(x)) * 2);
                out[x] = .{ .color = c, .priority = priority, .flags = FLAG_OPAQUE };
            }
        },
        4 => {
            const base_vram = page_offset + @as(u32, y) * SCREEN_WIDTH;
            var x: usize = 0;
            while (x < SCREEN_WIDTH) : (x += 1) {
                const idx = self.bus.vram[base_vram + @as(u32, @intCast(x))];
                if (idx == 0) continue;
                out[x] = .{
                    .color = pramBgColor(self.bus, idx),
                    .priority = priority,
                    .flags = FLAG_OPAQUE,
                };
            }
        },
        5 => {
            if (y < 16 or y >= 144) return;
            const base_vram = page_offset + (@as(u32, y) - 16) * 160 * 2;
            var x: usize = 40;
            while (x < 200) : (x += 1) {
                const c = vramReadU16(self.bus, base_vram + (@as(u32, @intCast(x)) - 40) * 2);
                out[x] = .{ .color = c, .priority = priority, .flags = FLAG_OPAQUE };
            }
        },
        else => {},
    }
}

/// Render one text-BG scanline into `self.bg_line[bg]`.
fn renderTextBg(self: *Ppu, y: u16, bg: u2) void {
    const cnt_offset: u32 = 0x008 + @as(u32, bg) * 2;
    const bgcnt = self.io.read(u16, cnt_offset);
    const priority: u8 = @intCast(bgcnt & 0x3);
    const char_block: u32 = (@as(u32, bgcnt) >> 2) & 0x3;
    const palette_256 = (bgcnt & 0x0080) != 0;
    const screen_block: u32 = (@as(u32, bgcnt) >> 8) & 0x1F;
    const size: u2 = @intCast((bgcnt >> 14) & 0x3);

    const hofs = self.io.read(u16, 0x010 + @as(u32, bg) * 4) & 0x1FF;
    const vofs = self.io.read(u16, 0x012 + @as(u32, bg) * 4) & 0x1FF;

    const map_w: u32 = if ((size & 1) != 0) 512 else 256;
    const map_h: u32 = if ((size & 2) != 0) 512 else 256;

    const char_base = char_block * 0x4000;
    const screen_base = screen_block * 0x800;

    const py_global = (@as(u32, y) + @as(u32, vofs)) & (map_h - 1);
    const tile_y = py_global / 8;
    const py_in_tile = py_global & 7;

    const out = &self.bg_line[bg];

    var x: u32 = 0;
    while (x < SCREEN_WIDTH) : (x += 1) {
        const px_global = (x + @as(u32, hofs)) & (map_w - 1);
        const tile_x = px_global / 8;
        const px_in_tile = px_global & 7;

        var sb = screen_base;
        if (map_w == 512 and tile_x >= 32) sb += 0x800;
        if (map_h == 512 and tile_y >= 32) sb += if (map_w == 512) @as(u32, 0x1000) else 0x800;
        const local_tx = tile_x & 31;
        const local_ty = tile_y & 31;

        const map_addr = sb + (local_ty * 32 + local_tx) * 2;
        const map_entry = vramReadU16(self.bus, map_addr);
        const tile_num: u32 = map_entry & 0x3FF;
        const flip_h = (map_entry & 0x0400) != 0;
        const flip_v = (map_entry & 0x0800) != 0;
        const pal_bank: u32 = (@as(u32, map_entry) >> 12) & 0xF;

        const tx_in = if (flip_h) (7 - px_in_tile) else px_in_tile;
        const ty_in = if (flip_v) (7 - py_in_tile) else py_in_tile;

        const tile_size: u32 = if (palette_256) 64 else 32;
        if (palette_256) {
            const tile_addr = char_base + tile_num * tile_size + ty_in * 8 + tx_in;
            if (tile_addr >= 0x1_0000) continue;
            const pixel = self.bus.vram[tile_addr];
            if (pixel == 0) continue;
            out[x] = .{
                .color = pramBgColor(self.bus, pixel),
                .priority = priority,
                .flags = FLAG_OPAQUE,
            };
        } else {
            const tile_addr = char_base + tile_num * tile_size + ty_in * 4 + (tx_in / 2);
            if (tile_addr >= 0x1_0000) continue;
            const nib = self.bus.vram[tile_addr];
            const half: u8 = if ((tx_in & 1) != 0) (nib >> 4) else (nib & 0xF);
            if (half == 0) continue;
            const color_idx: u8 = @intCast(pal_bank * 16 + @as(u32, half));
            out[x] = .{
                .color = pramBgColor(self.bus, color_idx),
                .priority = priority,
                .flags = FLAG_OPAQUE,
            };
        }
    }
}

// =====================================================================
// Sprite (OBJ) layer
// =====================================================================

fn renderSprites(self: *Ppu, y: u16, dispcnt: u16) void {
    const obj_one_d = (dispcnt & 0x40) != 0;

    var entry: u32 = 0;
    while (entry < 128) : (entry += 1) {
        const oam_addr = entry * 8;
        const attr0 = @as(u16, self.bus.oam[oam_addr]) | (@as(u16, self.bus.oam[oam_addr + 1]) << 8);
        const attr1 = @as(u16, self.bus.oam[oam_addr + 2]) | (@as(u16, self.bus.oam[oam_addr + 3]) << 8);
        const attr2 = @as(u16, self.bus.oam[oam_addr + 4]) | (@as(u16, self.bus.oam[oam_addr + 5]) << 8);

        const affine = (attr0 & 0x0100) != 0;
        // Bit 9 means "disable" for non-affine, "double-size area" for affine.
        if (!affine and (attr0 & 0x0200) != 0) continue;
        const double_size = affine and (attr0 & 0x0200) != 0;

        const obj_mode: u2 = @intCast((attr0 >> 10) & 0x3);
        if (obj_mode == 3) continue; // forbidden

        const shape: u2 = @intCast((attr0 >> 14) & 0x3);
        const size: u2 = @intCast((attr1 >> 14) & 0x3);
        const dims = spriteDims(shape, size);
        const w = dims[0];
        const h = dims[1];

        // Bounding box (the rendering area) — 2× sprite size if double_size.
        const bbox_w: u32 = if (double_size) w * 2 else w;
        const bbox_h: u32 = if (double_size) h * 2 else h;

        const sy_raw: u8 = @intCast(attr0 & 0xFF);
        var sy: i32 = sy_raw;
        if (sy >= 160) sy -= 256;

        if (@as(i32, y) < sy or @as(i32, y) >= sy + @as(i32, @intCast(bbox_h))) continue;

        const sx_raw: u32 = attr1 & 0x1FF;
        var sx: i32 = @intCast(sx_raw);
        if (sx >= 240) sx -= 512;

        const palette_256 = (attr0 & 0x2000) != 0;
        const priority: u8 = @intCast((attr2 >> 10) & 0x3);
        const tile_num: u32 = attr2 & 0x3FF;
        const pal_bank: u32 = (@as(u32, attr2) >> 12) & 0xF;

        // Affine matrix from OAM rotation/scaling group (attr1 bits 13-9).
        // Each group is 32 bytes apart; PA at +0x06, PB +0x0E, PC +0x16,
        // PD +0x1E (relative to group base).
        const affine_group: u32 = @intCast((attr1 >> 9) & 0x1F);
        const aff_base = affine_group * 0x20;
        const pa: i32 = if (affine) @as(i32, @as(i16, @bitCast(@as(u16, self.bus.oam[aff_base + 0x06]) | (@as(u16, self.bus.oam[aff_base + 0x07]) << 8)))) else 0x100;
        const pb: i32 = if (affine) @as(i32, @as(i16, @bitCast(@as(u16, self.bus.oam[aff_base + 0x0E]) | (@as(u16, self.bus.oam[aff_base + 0x0F]) << 8)))) else 0;
        const pc: i32 = if (affine) @as(i32, @as(i16, @bitCast(@as(u16, self.bus.oam[aff_base + 0x16]) | (@as(u16, self.bus.oam[aff_base + 0x17]) << 8)))) else 0;
        const pd: i32 = if (affine) @as(i32, @as(i16, @bitCast(@as(u16, self.bus.oam[aff_base + 0x1E]) | (@as(u16, self.bus.oam[aff_base + 0x1F]) << 8)))) else 0x100;

        const flip_h = !affine and (attr1 & 0x1000) != 0;
        const flip_v = !affine and (attr1 & 0x2000) != 0;

        // dy = y offset from sprite-top within the rendering bbox.
        const dy_raw: i32 = @as(i32, y) - sy;
        // For non-affine, compute py_in directly. For affine, use the
        // PC/PD matrix per pixel below.
        const py_in_sprite_raw: u32 = @intCast(dy_raw);

        var px: u32 = 0;
        while (px < bbox_w) : (px += 1) {
            const sx_pixel = sx + @as(i32, @intCast(px));
            if (sx_pixel < 0 or sx_pixel >= 240) continue;
            const dst_x: usize = @intCast(sx_pixel);

            // Resolve the source-sprite pixel (tx, ty) in [0,w) × [0,h).
            var tx: i32 = undefined;
            var ty: i32 = undefined;
            if (affine) {
                // Texel center is (W/2, H/2) within source space; the
                // bbox center is (bbox_w/2, bbox_h/2). Distance from
                // bbox-center, transformed by the matrix, plus W/2 / H/2.
                const dx_centered: i32 = @as(i32, @intCast(px)) - @as(i32, @intCast(bbox_w >> 1));
                const dy_centered: i32 = dy_raw - @as(i32, @intCast(bbox_h >> 1));
                tx = ((pa * dx_centered + pb * dy_centered) >> 8) + @as(i32, @intCast(w >> 1));
                ty = ((pc * dx_centered + pd * dy_centered) >> 8) + @as(i32, @intCast(h >> 1));
                if (tx < 0 or ty < 0 or tx >= @as(i32, @intCast(w)) or ty >= @as(i32, @intCast(h))) continue;
            } else {
                const px_in = if (flip_h) (w - 1 - px) else px;
                const py_in = if (flip_v) (h - 1 - py_in_sprite_raw) else py_in_sprite_raw;
                tx = @intCast(px_in);
                ty = @intCast(py_in);
            }

            const tile_x: u32 = @intCast(@divTrunc(tx, 8));
            const tile_y: u32 = @intCast(@divTrunc(ty, 8));
            const tile_px: u32 = @intCast(@mod(tx, 8));
            const tile_py: u32 = @intCast(@mod(ty, 8));

            const tile_step_x: u32 = if (palette_256) 2 else 1;
            const tile_stride_y: u32 = if (obj_one_d)
                ((w / 8) * tile_step_x)
            else
                32;
            const this_tile = tile_num + tile_y * tile_stride_y + tile_x * tile_step_x;
            const within_tile: u32 = if (palette_256)
                tile_py * 8 + tile_px
            else
                tile_py * 4 + tile_px / 2;
            const tile_addr = 0x10000 + this_tile * 32 + within_tile;

            if (tile_addr >= 0x18000) continue;

            // Resolve the pixel value (palette index).
            var color_idx: u8 = 0;
            if (palette_256) {
                color_idx = self.bus.vram[tile_addr];
                if (color_idx == 0) continue;
            } else {
                const nib = self.bus.vram[tile_addr];
                const half: u8 = if ((tile_px & 1) != 0) (nib >> 4) else (nib & 0xF);
                if (half == 0) continue;
                color_idx = @intCast(pal_bank * 16 + @as(u32, half));
            }

            // OBJ-window sprites set the window mask and don't draw a pixel.
            if (obj_mode == 2) {
                self.obj_win[dst_x] = true;
                continue;
            }

            // Keep only the highest-priority opaque OBJ pixel per x.
            const cur = self.obj_line[dst_x];
            if ((cur.flags & FLAG_OPAQUE) != 0 and cur.priority <= priority) continue;
            self.obj_line[dst_x] = .{
                .color = pramObjColor(self.bus, color_idx),
                .priority = priority,
                .flags = FLAG_OPAQUE | (if (obj_mode == 1) FLAG_OBJ_BLEND else @as(u8, 0)),
            };
        }
    }
}

/// (width, height) in pixels per (shape, size).
fn spriteDims(shape: u2, size: u2) [2]u32 {
    return switch (shape) {
        0 => switch (size) { // square
            0 => .{ 8, 8 },
            1 => .{ 16, 16 },
            2 => .{ 32, 32 },
            3 => .{ 64, 64 },
        },
        1 => switch (size) { // horizontal
            0 => .{ 16, 8 },
            1 => .{ 32, 8 },
            2 => .{ 32, 16 },
            3 => .{ 64, 32 },
        },
        2 => switch (size) { // vertical
            0 => .{ 8, 16 },
            1 => .{ 8, 32 },
            2 => .{ 16, 32 },
            3 => .{ 32, 64 },
        },
        3 => .{ 0, 0 }, // forbidden
    };
}

// =====================================================================
// Tests
// =====================================================================

const Scheduler_ = Scheduler;

test "bgr555ToArgb expansion" {
    try std.testing.expectEqual(@as(u32, 0xFF00_0000), bgr555ToArgb(0)); // black
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), bgr555ToArgb(0x7FFF)); // white
    // pure red (5-bit max) → 0xFF
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), bgr555ToArgb(0x001F));
}
