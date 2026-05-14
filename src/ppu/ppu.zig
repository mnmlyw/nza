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
        }

        // Enter H-blank.
        self.io.dispstat |= 0x0002;
        if ((self.io.dispstat & 0x0010) != 0) self.irq.raise(.hblank);
        // HBlank DMA fires only during visible scanlines (not during VBlank).
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
            // gating on DISPSTAT.VBI_enable. NBA/mGBA do the same: the
            // hardware fires the IRQ pin only when DISPSTAT.3 is set, but
            // the IF flag itself is set on every VBlank entry. Pokemon
            // Emerald assumes this behaviour.
            self.irq.raise(.vblank);
            self.dma.onEvent(.vblank);
        } else if (self.io.vcount == 0) {
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

    const mode: u3 = @intCast(dispcnt & 7);
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    const backdrop = bgr555ToArgb(pramBgColor(self.bus, 0));
    for (0..SCREEN_WIDTH) |x| self.framebuffer[base_fb + x] = backdrop;

    switch (mode) {
        0 => renderMode0(self, y, dispcnt),
        1 => renderMode1(self, y, dispcnt),
        2 => renderMode2(self, y, dispcnt),
        3 => renderMode3(self, y),
        4 => renderMode4(self, y, dispcnt),
        5 => renderMode5(self, y, dispcnt),
        else => {},
    }

    // Sprite layer overlays the chosen BG mode.
    if ((dispcnt & 0x1000) != 0) renderSprites(self, y, dispcnt);
}

// =====================================================================
// Mode 1: BG0 + BG1 text, BG2 affine
// =====================================================================
fn renderMode1(self: *Ppu, y: u16, dispcnt: u16) void {
    if ((dispcnt & (1 << 8)) != 0) renderTextBgDirect(self, y, 0);
    if ((dispcnt & (1 << 9)) != 0) renderTextBgDirect(self, y, 1);
    if ((dispcnt & (1 << 10)) != 0) renderAffineBg(self, y, 2);
}

// =====================================================================
// Mode 2: BG2 + BG3 affine
// =====================================================================
fn renderMode2(self: *Ppu, y: u16, dispcnt: u16) void {
    if ((dispcnt & (1 << 10)) != 0) renderAffineBg(self, y, 2);
    if ((dispcnt & (1 << 11)) != 0) renderAffineBg(self, y, 3);
}

/// Render an affine (rotation/scaling) BG scanline applying the matrix
/// (PA/PB/PC/PD) and the X/Y reference points. 28-bit signed fixed-point
/// (8 fractional bits). Display-area overflow bit (BGCNT bit 13) selects
/// wraparound vs transparent-outside-map.
///
/// M1.5 simplification: we use the user-written BGxX/BGxY as the origin
/// for the whole scanline rather than maintaining a per-scanline internal
/// reference that PPU increments by PB/PD. That's correct for static or
/// per-frame-set BGs (e.g. the Pokemon Emerald boot splash).
fn renderAffineBg(self: *Ppu, y: u16, bg: u2) void {
    const cnt_offset: u32 = 0x008 + @as(u32, bg) * 2;
    const bgcnt = self.io.read(u16, cnt_offset);
    const char_block: u32 = (@as(u32, bgcnt) >> 2) & 0x3;
    const screen_block: u32 = (@as(u32, bgcnt) >> 8) & 0x1F;
    const overflow_wrap = (bgcnt & 0x2000) != 0;
    const size: u2 = @intCast((bgcnt >> 14) & 0x3);
    const map_tiles: u32 = @as(u32, 16) << @intCast(size);
    const map_pixels: i32 = @intCast(map_tiles * 8);
    const char_base = char_block * 0x4000;
    const screen_base = screen_block * 0x800;

    // BG2 / BG3 affine registers live at 0x20+ / 0x30+ respectively.
    const ref_base: u32 = if (bg == 2) 0x20 else 0x30;
    const pa = @as(i32, @as(i16, @bitCast(self.io.read(u16, ref_base + 0))));
    const pb = @as(i32, @as(i16, @bitCast(self.io.read(u16, ref_base + 2))));
    const pc = @as(i32, @as(i16, @bitCast(self.io.read(u16, ref_base + 4))));
    const pd = @as(i32, @as(i16, @bitCast(self.io.read(u16, ref_base + 6))));
    const x_ref = signExtend28(self.io.read(u32, ref_base + 8));
    const y_ref = signExtend28(self.io.read(u32, ref_base + 12));

    const yi: i32 = @intCast(y);
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    var x: i32 = 0;
    while (x < @as(i32, @intCast(SCREEN_WIDTH))) : (x += 1) {
        // Affine transform: src = (PA*x + PB*y + X_ref, PC*x + PD*y + Y_ref) >> 8.
        const sx = (pa * x + pb * yi + x_ref) >> 8;
        const sy = (pc * x + pd * yi + y_ref) >> 8;

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
        self.framebuffer[base_fb + @as(usize, @intCast(x))] = bgr555ToArgb(pramBgColor(self.bus, pixel));
    }
}

/// Sign-extend a 28-bit value (stored in the low bits of u32) to i32.
inline fn signExtend28(v: u32) i32 {
    return @as(i32, @bitCast(v << 4)) >> 4;
}

/// Variant for Mode 1: render a text BG directly into the framebuffer
/// without the priority-merging buffer (since Mode 1 only has 2 text BGs).
fn renderTextBgDirect(self: *Ppu, y: u16, bg: u2) void {
    var line: [SCREEN_WIDTH]u32 = undefined;
    var line_prio: [SCREEN_WIDTH]u8 = [_]u8{0xFF} ** SCREEN_WIDTH;
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    @memcpy(&line, self.framebuffer[base_fb .. base_fb + SCREEN_WIDTH]);
    renderTextBg(self, y, bg, &line, &line_prio);
    for (0..SCREEN_WIDTH) |x| {
        if (line_prio[x] != 0xFF) self.framebuffer[base_fb + x] = line[x];
    }
}

// =====================================================================
// Mode 3: direct 16-bit 240×160 framebuffer
// =====================================================================

fn renderMode3(self: *Ppu, y: u16) void {
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    const base_vram = @as(u32, y) * SCREEN_WIDTH * 2;
    for (0..SCREEN_WIDTH) |x| {
        const c = vramReadU16(self.bus, base_vram + @as(u32, @intCast(x)) * 2);
        self.framebuffer[base_fb + x] = bgr555ToArgb(c);
    }
}

// =====================================================================
// Mode 4: 8-bit palette indices, 240×160, double-buffered
// =====================================================================

fn renderMode4(self: *Ppu, y: u16, dispcnt: u16) void {
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    const page_offset: u32 = if ((dispcnt & 0x10) != 0) 0xA000 else 0; // DISPCNT bit 4 = page
    const base_vram = page_offset + @as(u32, y) * SCREEN_WIDTH;
    for (0..SCREEN_WIDTH) |x| {
        const idx = self.bus.vram[base_vram + @as(u32, @intCast(x))];
        const c = pramBgColor(self.bus, idx);
        self.framebuffer[base_fb + x] = bgr555ToArgb(c);
    }
}

// =====================================================================
// Mode 5: 16-bit 160×128 framebuffer (smaller bitmap, centered)
// =====================================================================

fn renderMode5(self: *Ppu, y: u16, dispcnt: u16) void {
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    // Mode 5 displays only 160×128 centered; outside is the backdrop color.
    const backdrop = bgr555ToArgb(pramBgColor(self.bus, 0));
    if (y < 16 or y >= 144) {
        for (0..SCREEN_WIDTH) |x| self.framebuffer[base_fb + x] = backdrop;
        return;
    }
    const page_offset: u32 = if ((dispcnt & 0x10) != 0) 0xA000 else 0;
    const base_vram = page_offset + (@as(u32, y) - 16) * 160 * 2;
    for (0..SCREEN_WIDTH) |x| {
        if (x < 40 or x >= 200) {
            self.framebuffer[base_fb + x] = backdrop;
            continue;
        }
        const c = vramReadU16(self.bus, base_vram + (@as(u32, @intCast(x)) - 40) * 2);
        self.framebuffer[base_fb + x] = bgr555ToArgb(c);
    }
}

// =====================================================================
// Mode 0: text BG (up to 4 BG layers, no affine)
// =====================================================================

/// Render one scanline by compositing BG3 → BG0 with priority order, then
/// filling with the backdrop (palette index 0) where nothing wrote.
fn renderMode0(self: *Ppu, y: u16, dispcnt: u16) void {
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    const backdrop_color = bgr555ToArgb(pramBgColor(self.bus, 0));

    // Per-pixel layer state: best priority found so far + whether it's set.
    // We track (priority, color) and pick the lowest-priority hit.
    var line: [SCREEN_WIDTH]u32 = [_]u32{backdrop_color} ** SCREEN_WIDTH;
    var line_prio: [SCREEN_WIDTH]u8 = [_]u8{0xFF} ** SCREEN_WIDTH;

    // Render BG3 first, then BG2, BG1, BG0 — lower BG index wins on equal priority.
    var bg_idx: i32 = 3;
    while (bg_idx >= 0) : (bg_idx -= 1) {
        const bg: u2 = @intCast(bg_idx);
        const enable_bit_pos: u4 = 8 + @as(u4, bg);
        if ((dispcnt & (@as(u16, 1) << enable_bit_pos)) == 0) continue;
        renderTextBg(self, y, bg, &line, &line_prio);
    }

    for (0..SCREEN_WIDTH) |x| self.framebuffer[base_fb + x] = line[x];
}

/// Render one text-BG scanline into the line buffer, respecting priority.
fn renderTextBg(
    self: *Ppu,
    y: u16,
    bg: u2,
    line: *[SCREEN_WIDTH]u32,
    line_prio: *[SCREEN_WIDTH]u8,
) void {
    const cnt_offset: u32 = 0x008 + @as(u32, bg) * 2;
    const bgcnt = self.io.read(u16, cnt_offset);
    const priority: u8 = @intCast(bgcnt & 0x3);
    const char_block: u32 = (@as(u32, bgcnt) >> 2) & 0x3;
    const palette_256 = (bgcnt & 0x0080) != 0; // 1 = 8bpp, 0 = 4bpp
    const screen_block: u32 = (@as(u32, bgcnt) >> 8) & 0x1F;
    const size: u2 = @intCast((bgcnt >> 14) & 0x3);

    // BG scroll: 9-bit signed values typically, but we just modulo into the map.
    const hofs = self.io.read(u16, 0x010 + @as(u32, bg) * 4) & 0x1FF;
    const vofs = self.io.read(u16, 0x012 + @as(u32, bg) * 4) & 0x1FF;

    // Map size in pixels.
    const map_w: u32 = if ((size & 1) != 0) 512 else 256;
    const map_h: u32 = if ((size & 2) != 0) 512 else 256;

    const char_base = char_block * 0x4000;
    const screen_base = screen_block * 0x800;

    const py_global = (@as(u32, y) + @as(u32, vofs)) & (map_h - 1);
    const tile_y = py_global / 8;
    const py_in_tile = py_global & 7;

    var x: u32 = 0;
    while (x < SCREEN_WIDTH) : (x += 1) {
        if (line_prio[x] <= priority) continue;

        const px_global = (x + @as(u32, hofs)) & (map_w - 1);
        const tile_x = px_global / 8;
        const px_in_tile = px_global & 7;

        // Pick correct screen block for 512-wide / 512-tall layouts.
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
        var pixel: u8 = undefined;
        if (palette_256) {
            const tile_addr = char_base + tile_num * tile_size + ty_in * 8 + tx_in;
            if (tile_addr >= 0x1_0000) continue; // tiles must live in BG VRAM
            pixel = self.bus.vram[tile_addr];
            if (pixel == 0) continue; // transparent
            line[x] = bgr555ToArgb(pramBgColor(self.bus, pixel));
        } else {
            const tile_addr = char_base + tile_num * tile_size + ty_in * 4 + (tx_in / 2);
            if (tile_addr >= 0x1_0000) continue;
            const nib = self.bus.vram[tile_addr];
            const half: u8 = if ((tx_in & 1) != 0) (nib >> 4) else (nib & 0xF);
            if (half == 0) continue;
            const color_idx: u8 = @intCast(pal_bank * 16 + @as(u32, half));
            line[x] = bgr555ToArgb(pramBgColor(self.bus, color_idx));
        }
        line_prio[x] = priority;
    }
}

// =====================================================================
// Sprite (OBJ) layer
// =====================================================================

fn renderSprites(self: *Ppu, y: u16, dispcnt: u16) void {
    const base_fb = @as(usize, y) * SCREEN_WIDTH;
    const obj_one_d = (dispcnt & 0x40) != 0;

    var entry: u32 = 0;
    while (entry < 128) : (entry += 1) {
        const oam_addr = entry * 8;
        const attr0 = @as(u16, self.bus.oam[oam_addr]) | (@as(u16, self.bus.oam[oam_addr + 1]) << 8);
        const attr1 = @as(u16, self.bus.oam[oam_addr + 2]) | (@as(u16, self.bus.oam[oam_addr + 3]) << 8);
        const attr2 = @as(u16, self.bus.oam[oam_addr + 4]) | (@as(u16, self.bus.oam[oam_addr + 5]) << 8);

        // Disable bit (only meaningful when affine off — bit 9 of attr0).
        const affine = (attr0 & 0x0100) != 0;
        if (!affine and (attr0 & 0x0200) != 0) continue;

        const shape: u2 = @intCast((attr0 >> 14) & 0x3);
        const size: u2 = @intCast((attr1 >> 14) & 0x3);
        const dims = spriteDims(shape, size);
        const w = dims[0];
        const h = dims[1];

        const sy_raw: u8 = @intCast(attr0 & 0xFF);
        var sy: i32 = sy_raw;
        if (sy >= 160) sy -= 256;

        if (@as(i32, y) < sy or @as(i32, y) >= sy + @as(i32, @intCast(h))) continue;

        const sx_raw: u32 = attr1 & 0x1FF;
        var sx: i32 = @intCast(sx_raw);
        if (sx >= 240) sx -= 512;

        const palette_256 = (attr0 & 0x2000) != 0;
        const priority: u8 = @intCast((attr2 >> 10) & 0x3);
        const tile_num: u32 = attr2 & 0x3FF;
        const pal_bank: u32 = (@as(u32, attr2) >> 12) & 0xF;

        const flip_h = !affine and (attr1 & 0x1000) != 0;
        const flip_v = !affine and (attr1 & 0x2000) != 0;

        const py_in_sprite_raw: u32 = @intCast(@as(i32, y) - sy);
        const py_in = if (flip_v) (h - 1 - py_in_sprite_raw) else py_in_sprite_raw;

        var px: u32 = 0;
        while (px < w) : (px += 1) {
            const sx_pixel = sx + @as(i32, @intCast(px));
            if (sx_pixel < 0 or sx_pixel >= 240) continue;
            const px_in = if (flip_h) (w - 1 - px) else px;

            // Tile lookup: OBJ tiles always start at VRAM 0x10000. `tile_num`
            // from OAM is in 32-byte ("tile name") units regardless of color
            // depth; a 256-color tile occupies two adjacent names.
            //   1D mapping: tiles laid out sequentially → row stride = (w/8) names per row,
            //               × 2 names per tile in 256-color.
            //   2D mapping: 32×32 grid of names. Row stride = 32 names regardless of
            //               color depth; horizontal tile step is 1 (16-color) or 2 (256-color).
            const tile_x = px_in / 8;
            const tile_y = py_in / 8;
            const tile_px = px_in & 7;
            const tile_py = py_in & 7;

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

            var pixel: u8 = undefined;
            if (palette_256) {
                pixel = self.bus.vram[tile_addr];
                if (pixel == 0) continue;
                const dst_x: usize = @intCast(sx_pixel);
                self.framebuffer[base_fb + dst_x] = bgr555ToArgb(pramObjColor(self.bus, pixel));
            } else {
                const nib = self.bus.vram[tile_addr];
                const half: u8 = if ((tile_px & 1) != 0) (nib >> 4) else (nib & 0xF);
                if (half == 0) continue;
                const color_idx: u8 = @intCast(pal_bank * 16 + @as(u32, half));
                const dst_x: usize = @intCast(sx_pixel);
                self.framebuffer[base_fb + dst_x] = bgr555ToArgb(pramObjColor(self.bus, color_idx));
            }
            _ = priority; // M1.4: sprites always on top. BG/sprite priority lands later.
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
