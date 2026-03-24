# Sega System 32 — MiSTer FPGA Core

MiSTer FPGA implementation of the Sega System 32 arcade hardware (1990–1994).

## Hardware Overview

The Sega System 32 board uses:

- **CPU**: NEC V60 (uPD70615) @ 16 MHz — 16-bit external data bus, 24-bit address bus
- **Video**: 5 tilemap layers (TEXT 8×8 + NBG0-3 16×16), double-buffered sprites (linked-list), bitmap mode, palette RAM (R5G5B5)
- **Resolution**: 320×224 @ ~60 Hz (standard mode); 416×224 wide mode
- **Audio**: Z80 sound CPU + YM3438 (OPN2C) + 2× RF5C164 PCM (stubbed in this revision)
- **I/O**: 315-5296 custom I/O chip (joystick, coin, DIP, EEPROM)

## Supported Games (24 titles)

| Game | Year | MAME set |
|------|------|----------|
| Rad Mobile | 1990 | radm |
| Rad Rally | 1991 | radr |
| Spiderman: The Videogame | 1991 | spidman |
| Arabian Fight | 1992 | arabfgt |
| Golden Axe: The Revenge of Death Adder | 1992 | ga2 |
| Burning Rival | 1993 | brival |
| Holosseum | 1992 | holosseum |
| Title Fight | 1992 | titlef |
| Jurassic Park | 1994 | jpark |
| Alien 3: The Gun | 1993 | alien3 |
| Dungeon Master | 1993 | darkedge |
| Dark Edge | 1993 | darkedge |
| Hard Dunk | 1994 | harddunk |
| Super Visual Football | 1994 | svf |
| NFL NFL! | 1993 | nfl |
| Stadium Cross | 1992 | f1en |
| F1 Super Lap | 1993 | f1lap |
| OutRunners | 1992 | outrners |
| Rad Mobile (prototype) | 1990 | radmp |
| Rad Rally (Japan) | 1991 | radrj |
| Golden Axe: The Revenge (Japan) | 1992 | ga2j |
| Arabian Fight (Japan) | 1992 | arabfgtj |
| Burning Rival (Japan) | 1993 | brivalj |
| Spiderman (World) | 1991 | spidmanw |

## Current Status

- **Sim verified**: 99.58% MAME RAM match through 500 frames (Rad Mobile)
- **Framework integration**: Complete (emu.sv, QSF, SDC, MRA, CI)
- **Audio**: Stubbed — AUDIO_L/R output silence. YM3438 + RF5C164 not yet implemented.
- **Input**: 315-5296 I/O chip stub in segas32_top; standard joystick mapping wired in emu.sv
- **EEPROM**: 93C46 not emulated — eeprom_do tied to 1'b1

## SDRAM Layout

| Address Range | Size | Content |
|---------------|------|---------|
| 0x000000–0x1FFFFF | 2 MB | CPU program ROM (maincpu) |
| 0x200000–0x9FFFFF | 8 MB | Sprite ROM |
| 0xA00000–0xBFFFFF | 2 MB | GFX tile ROM (gfx1) |

## ROM Loading (MRA ioctl_index)

| Index | Content |
|-------|---------|
| 0x00 | CPU program ROM (V60 maincpu) |
| 0x01 | Sprite ROM (8× 1MB) |
| 0x02 | GFX tile ROM (4× 512KB) |
| 0xFE | DIP switch defaults |

## Building

```bash
cd chips/segas32_arcade/quartus
quartus_sh --flow compile segas32_arcade
```

Or use the GitHub Actions CI workflow (`.github/workflows/segas32_synthesis.yml`).

## References

- MAME source: `src/mame/sega/segas32.cpp`, `segas32_v.cpp`
- NEC V60 CPU: `chips/v60/rtl/v60_core.sv`
- Video hardware: `chips/segas32_arcade/rtl/segas32_video.sv`
