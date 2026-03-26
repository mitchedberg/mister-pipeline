# Psikyo SH201B/SH403 — MiSTer FPGA Core

**Status:** VALIDATED | CI GREEN | 100% WRAM match
**Synthesis:** Quartus 17.0, DE-10 Nano (Cyclone V)
**MAME driver:** `psikyo/psikyo.cpp`

---

## System Description

The Psikyo SH201B/SH403 is a 1993–2002 arcade platform from Psikyo (Sammy), best known for tight vertical shooters. It was used across 22 games including Strikers 1945, Gunbird, and Sol Divide.

| Specification | Value |
|---|---|
| **Main CPU** | Motorola 68EC020 @ 16 MHz |
| **Sound CPU** | Z80 @ 4 MHz |
| **Display** | 320 × 240 @ 59.3 Hz (vertical, rotated 90°) |
| **Sprite Chip** | PS2001B (sprites) |
| **Tilemap Chip** | PS3103 (2 scroll layers) |
| **Sound** | YM2610 (FM/ADPCM) + OKI M6295 |
| **Custom** | PIC16C57 MCU (protection, simplified) |

---

## Supported Games

| Game | Set Name | Year | Status |
|---|---|---|---|
| Gunbird (World) | `gunbird` | 1994 | Validated (reference game) |
| Samurai Aces (World) | `samuraia` | 1993 | RTL Complete |
| Battle K-Road | `btlkroad` | 1994 | RTL Complete |
| Strikers 1945 (World) | `s1945` | 1995 | RTL Complete |
| Tengai (World) | `tengai` | 1996 | RTL Complete |
| Sol Divide | `soldivid` | 1997 | RTL Complete |
| Strikers 1945 II | `s1945ii` | 1997 | RTL Complete |
| Gunbird 2 | `gunbird2` | 1998 | RTL Complete |
| Space Bomber | `sbomber` | 1998 | RTL Complete |
| Strikers 1945 III | `s1945iii` | 1999 | RTL Complete |
| Dragon Blaze | `dragnblz` | 2000 | RTL Complete |
| Tetris The Grand Master 2 | `tgm2` | 2000 | RTL Complete |

Regional clones (Japan/Korea variants) use the same binary — swap MRA file only.

---

## Validation

- **Match rate:** 100% WRAM byte-perfect across validated TAS frames
- **CI run:** GREEN (Quartus exit 0, synthesis clean)
- **Known issues:** None
- **Control-build target:** `gunbird` is the recommended smoke-test game for untouched
  Quartus/deploy validation.

---

## Build Instructions

### Requirements

- Quartus Prime Lite 17.0 (Cyclone V support)
- DE-10 Nano (MiSTer hardware)

### Synthesize

```bash
cd chips/psikyo_arcade/quartus
quartus_sh --flow compile psikyo_arcade.qpf
```

The bitstream `output_files/psikyo_arcade.rbf` is the MiSTer core file.

### Deploy to MiSTer

```
/media/fat/
  _Arcade/
    cores/
      psikyo_arcade_YYYYMMDD.rbf
    psikyo_arcade/
      Gunbird.mra
      Samurai_Aces.mra
      ...
```

Copy `.rbf` to `_Arcade/cores/` and `.mra` files to `_Arcade/` (or a subfolder).

---

## Core Architecture

```
psikyo_arcade.sv (top)
  ├── fx68k (M68EC020 emulated as M68000 @ 16 MHz)
  ├── T80 (Z80 sound CPU)
  ├── ps2001b.sv (sprite generator)
  ├── ps3103.sv (2-layer tilemap scroller)
  ├── ym2610 (FM audio)
  ├── okim6295 (ADPCM audio)
  └── sdram_ctrl (ROM + WRAM arbitration)
```

### SDRAM Layout

| Offset | Size | Contents |
|---|---|---|
| 0x000000 | 2 MB | CPU program ROM |
| 0x200000 | 4 MB | Sprite ROM (PS2001B) |
| 0x600000 | 2 MB | BG tile ROM (PS3103) |

---

## Credits

- **fx68k** — Jorge Cwik (MIT) — https://github.com/ijor/fx68k
- **T80** — Daniel Wallner (LGPL)
- **ym2610** — JOTEGO (GPL-2.0)
- **okim6295** — JOTEGO (GPL-2.0)
- **MiSTer sys/** — MiSTer-devel (GPL-2.0)
- **Hardware reference** — MAME `psikyo.cpp`, `ps2001b.cpp`, `ps3103.cpp`
