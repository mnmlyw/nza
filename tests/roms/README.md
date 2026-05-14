# Integration test ROMs

The integration harness in `tests/integration.zig` runs the [jsmolka/gba-tests](https://github.com/jsmolka/gba-tests) ROMs to validate CPU, memory, and PPU correctness.

ROMs are **not** checked into this repo — fetch them yourself and drop them here:

```sh
cd tests/roms
curl -L -O https://github.com/jsmolka/gba-tests/raw/master/arm/arm.gba
curl -L -O https://github.com/jsmolka/gba-tests/raw/master/thumb/thumb.gba
curl -L -O https://github.com/jsmolka/gba-tests/raw/master/memory/memory.gba
```

The harness skips silently with `[skip] arm.gba not present` for any ROM that's missing, so you can run a subset.

## Running

```sh
zig build test                # fast: unit tests only
zig build test -Dintegration  # also runs integration ROMs
```

## Pass criterion

Each test ROM writes the magic value `0xC0DEC0DE` to `0x03007FF8` (IWRAM, just below the BIOS-IF-mirror slot) when its self-check passes. The harness polls that address between frames. If it's not seen within a frame budget the test fails and the framebuffer is dumped to `/tmp/nza-<rom>.ppm` for inspection.

## Why not check in the ROMs?

They're external GPL test ROMs. Keeping the repo lean + avoiding any redistribution ambiguity. The harness is the integration; the ROMs are inputs you supply.
