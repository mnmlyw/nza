# nza

A Game Boy Advance emulator written in Zig — a port of
[NanoBoyAdvance](https://github.com/nba-emu/NanoBoyAdvance) (GPL-3.0).

Boots commercial games. Verified: Pokémon Emerald (USA, Europe) reaches its
title screen.

## Status

| Milestone | What | State |
|---|---|---|
| M1.0 | SDL2 window + framebuffer scaffold | done |
| M1.1 | Scheduler + bus + IO skeleton | done |
| M1.2 | ARM7TDMI CPU (all ARM + Thumb formats, exception entry) | done |
| M1.3 | IRQ + halt + PPU scanline timing + keypad | done |
| M1.4 | PPU rendering (modes 0/1/2/3/4/5) + DMA + timers + SDL | done |
| M1.5 | Docs, sound DMA, backup chips, polish | done |

~4700 LOC. 42/42 unit tests passing.

## What works

- **ARM7TDMI**: all ARM data-processing / memory / branch / block-transfer /
  multiply / PSR / SWI instructions. All 19 Thumb instruction formats.
  ARM↔Thumb interworking. Exception entry for SWI / IRQ / FIQ with
  ARM-ARM-correct return-link semantics.
- **BIOS**: real `gba_bios.bin` loaded as the boot ROM; HLE for soft-reset
  (`BX r0=1`), `CpuSet`, `CpuFastSet`, `Halt`, `IntrWait`, `VBlankIntrWait`,
  `Div`, `DivArm`, `Sqrt`. POSTFLG set on soft-reset.
- **PPU**: modes 0 (4× text BG), 1 (2× text + 1× affine), 2 (2× affine), 3
  (240×160 16-bit bitmap), 4 (240×160 paletted, double-buffered), 5
  (160×128 16-bit bitmap). Sprites: 8×8 to 64×64, 1D/2D character mapping,
  16-color and 256-color tiles, H/V flip. Backdrop, forced-blank, scanline
  IRQ and scheduler-driven HDRAW/HBLANK/VBLANK timing.
- **DMA**: 4 channels, all start-timings — immediate, VBlank, HBlank, and
  Special (sound FIFO driven by timer 0/1 overflow). 16/32-bit transfers,
  source/dest control modes, repeat, IRQ-on-done.
- **Timers**: 4 × 16-bit with prescaler 1/64/256/1024, cascade, overflow IRQ.
- **IRQ**: full IE/IF/IME, halt + IntrWait via SWI.
- **Keypad**: KEYINPUT mapped from SDL events.
- **Backup**: Flash 64KB / Flash 128KB with chip-ID, sector/chip erase,
  byte-write, bank switch. SRAM fallback.
- **Cart GPIO**: stubbed (writes to `0x080000C8` toggle a gate; reads return 0).

## What doesn't (yet)

- **Audio output.** Sound MMIO writes and sound-DMA pacing are wired but
  there is no SDL audio backend; the game runs silently.
- **Some PPU effects:** alpha blend (`BLDCNT`/`BLDALPHA`/`BLDY`), windows
  (`WIN0`/`WIN1`/`OBJWIN`), mosaic, affine sprites. Sprite priority is
  approximate (sprites currently always overlay BGs in OAM order).
- **Memory-region waitstate cycles.** Every instruction is currently
  costed as 1 cycle; `WAITCNT` is stored as a register but doesn't yet
  modulate access timing.
- **RTC chip.** Cart GPIO is gated but no RTC logic — Pokémon Emerald's
  berry / Mirage Island features will be inert, but boot is unaffected.
- **Save-state and rewind.**

## Build

Requires Zig 0.16 and SDL2 (`brew install sdl2` on macOS).

```sh
zig build -Doptimize=ReleaseFast
zig build test
```

The release binary lands at `zig-out/bin/nza`.

## Run

```sh
nza path/to/rom.gba                  # uses ~/Documents/gba/gba_bios.bin
nza --bios path/to/bios.bin rom.gba
nza --no-bios rom.gba                # skip BIOS; jump to ROM entry directly
nza --ppu-test                       # standalone PPU pattern (no ROM, no CPU)
nza --headless --steps N rom.gba     # run N frames, dump /tmp/nza.ppm
nza --trace N rom.gba                # single-step the CPU N times, print state
```

The BIOS is not redistributed — supply your own (`gba_bios.bin`). Default
location: `~/Documents/gba/gba_bios.bin`.

## Controls

| GBA button | Key |
|---|---|
| A | `Z` |
| B | `X` |
| L | `A` |
| R | `S` |
| Start | `Enter` |
| Select | `Shift` (left or right) |
| D-pad | Arrow keys |
| Quit | `Esc` |

## Layout

```
src/
  core/      scheduler, bus, io, cart, flash, bios, file_util
  cpu/       arm7tdmi, decode (comptime LUTs), handlers_arm, handlers_thumb
  ppu/       scanline renderer, sprite/affine
  dma/       4-channel DMA controller
  timer/     4 × 16-bit timers
  irq/       IE/IF/IME + halt
  keypad/    KEYINPUT
  frontend/  SDL2 window + texture + event pump
  main.zig   arg parsing, top loop, headless dump
```

## License

GPL-3.0-or-later, matching NanoBoyAdvance. See `LICENSE` and `NOTICE`.
GBA hardware behavior cross-referenced against
[GBATEK](https://problemkaputt.de/gbatek.htm) by Martin Korth.
