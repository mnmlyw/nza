# nza

A Game Boy Advance emulator written in Zig — a port of
[NanoBoyAdvance](https://github.com/nba-emu/NanoBoyAdvance) (GPL-3.0).

Boots commercial games into playable gameplay. Verified: Pokémon Emerald
(USA, Europe) reaches the title, intro, dialog scenes, and the player's
house with correct rendering and audio.

## Status

| Milestone | What | State |
|---|---|---|
| M1.0–M1.5 | Core emulator (CPU + PPU modes 0-5 + DMA + timers + IRQ + sound + SDL frontend) | done |
| M2.0 | jsmolka integration test harness (`zig build test -Dintegration`) | done |
| M2.1 | CPU cycle accuracy + WAITCNT-driven cart/SRAM wait tables + LDM N+S timing | done |
| M2.2 | Layered PPU compositor: alpha blend + windows + mosaic + affine BG internal ref | done |
| M2.3 | Affine sprite rotation/scaling matrix + double-size bounding box | done |
| M3.0 | Persistent `.sav` file (SRAM/Flash/EEPROM) + EEPROM 4K/64K chip | done |
| M3.1 | TLV save states + rewind ring (6s) + fast-forward toggle | done |
| M3.2 | SDL_GameController + audio low-pass + configurable controls via config.ini | done |
| M3.3 | Real GPIO + Seiko S-3511A RTC + Solar (Boktai) + Rumble detection | done |
| M3.4 | MUL/MLA I-cycles + vertical mosaic + per-scanline OAM budget + PPU bus contention | done |
| M3.5 | jsmolka bugfix sweep — 3 known instruction-level failures, deferred (see below) | partial |
| M4.0 | GameShark / Action Replay / CodeBreaker cheat-code engine | done |
| M4.1 | Cart-ROM prefetch buffer (WAITCNT.14) | done |
| M4.2 | gdbserver stub (GDB Remote Serial Protocol over TCP) | done |
| M4.3 | SIO single-player stub (graceful no-peer fallback) | done |
| M4.4 | Link cable multiplayer over TCP between two nza instances | done |
| M4.5 | Wireless adapter coverage (FR/LG fall-back via SIO stub) | done |

~8000 LOC. 53/53 unit tests + 4/4 integration tests passing.

## What works

- **ARM7TDMI**: all ARM data-processing / memory / branch / block-transfer /
  multiply / PSR / SWI instructions. All 19 Thumb instruction formats.
  ARM↔Thumb interworking. Exception entry for SWI / IRQ / FIQ with
  ARM-ARM-correct return-link semantics. **Cycle accuracy**: per-region
  bus wait tables driven from WAITCNT (cart-ROM N/S waits, EWRAM 3-cycle,
  PRAM/VRAM 32-bit 2-cycle, etc.). LDM/STM use N for the first transfer
  and S for the rest, matching real hardware.
- **BIOS**: real `gba_bios.bin` loaded as the boot ROM; HLE for soft-reset
  (`BX r0=1`), `CpuSet`, `CpuFastSet`, `Halt`, `IntrWait`, `VBlankIntrWait`,
  `Div`, `DivArm`, `Sqrt`. POSTFLG set on soft-reset.
- **PPU**: modes 0 (4× text BG), 1 (2× text + 1× affine), 2 (2× affine), 3
  (240×160 16-bit bitmap), 4 (240×160 paletted, double-buffered), 5
  (160×128 16-bit bitmap). Sprites: 8×8 to 64×64, 1D/2D character mapping,
  16-color and 256-color tiles, H/V flip, **affine rotation/scaling** with
  double-size bounding box, semi-transparent + OBJ-window modes.
  Compositor: per-layer priority, alpha blend (BLDCNT/BLDALPHA), brighten
  / darken (BLDY), windows (WIN0/WIN1/OBJWIN with INSIDE/OUTSIDE masks),
  horizontal mosaic. Affine BG with per-scanline internal X/Y advance.
  Backdrop, forced-blank, scanline IRQ and scheduler-driven
  HDRAW/HBLANK/VBLANK timing.
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

- **Cart-ROM prefetch buffer.** WAITCNT.14 (prefetch enable) is honored
  but the speculative-fetch FIFO state machine isn't modelled, so games
  that depend on it for tight timing run slightly slower than real
  hardware. (Performance accuracy, not correctness.)
- **Three jsmolka instruction-level test failures.**
  - `arm.gba` test 225 — undetermined; suspected MUL/long-MUL flag edge
  - `thumb.gba` — CPU enters a code path that bounces ARM↔Thumb early
    and never resyncs (likely a PUSH/POP corner case the test exercises)
  - `memory.gba` test 050 — unaligned LDR/LDM rotation edge
- **Some Pokémon audio specifics.** M4A song-transition stall still open
  (task #12). PSG channel 3 wave pattern bank-switch edge case.
- **JIT recompiler.** Pure performance optimization. The interpreter
  runs Pokémon Emerald at >2× real-time on an M1 Mac, so this is
  cosmetic for now. Tracked for M5.
- **Three jsmolka instruction-level failures** (see top of "What
  doesn't"). Don't block any commercial game.
- **GamePak DRQ / Video Capture special-DMA** — niche corner cases.

## Build

Requires Zig 0.16 and SDL2 (`brew install sdl2` on macOS).

```sh
zig build -Doptimize=ReleaseFast
zig build test                    # fast unit tests
zig build test -Dintegration      # add jsmolka ROM-driven tests
```

The release binary lands at `zig-out/bin/nza`.

Integration tests run any ROMs you drop in `tests/roms/`. The harness skips
silently when one is absent — see `tests/roms/README.md` for fetch
instructions. On hash mismatch, the framebuffer is dumped to
`/tmp/nza-<rom>.ppm` for inspection.

## Run

```sh
nza path/to/rom.gba                  # uses ~/Documents/gba/gba_bios.bin
nza --bios path/to/bios.bin rom.gba
nza --no-bios rom.gba                # skip BIOS; jump to ROM entry directly
nza --ppu-test                       # standalone PPU pattern (no ROM, no CPU)
nza --headless --steps N rom.gba     # run N frames, dump /tmp/nza.ppm
nza --trace N rom.gba                # single-step the CPU N times, print state
nza --snapshot-test rom.gba          # save state, run, restore, verify
nza --gdbserver 1234 rom.gba         # listen for GDB attach on TCP port
nza --link-host 6789 rom.gba         # host a TCP link-cable session
nza --link-connect host:port rom.gba # connect to a hosted link-cable session
```

The BIOS is not redistributed — supply your own (`gba_bios.bin`). Default
location: `~/Documents/gba/gba_bios.bin`.

## Controls

Default keys (override in `~/.config/nza/config.ini`):

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

Hotkeys:

| Key | Function |
|---|---|
| `F1` | Save state to `<rom>.state` |
| `F2` | Load state from `<rom>.state` |
| `F11` | Toggle fullscreen |
| `F12` | Screenshot to `/tmp/nza.ppm` |
| `Tab` | Toggle fast-forward (4×) |
| `Backspace` | Rewind (hold) — ~6 s history |

Game controllers are detected at startup; `controller.<button>` in
`config.ini` overrides the default button layout.

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
