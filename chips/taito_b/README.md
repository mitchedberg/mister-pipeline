# Taito B System — MiSTer FPGA Core

**Status:** VALIDATED | CI GREEN | 100% WRAM match (2299/2299 frames)
**Synthesis:** Quartus 17.0, DE-10 Nano (Cyclone V)
**MAME driver:** `taito/taito_b.cpp`

---

## System Description

The Taito B System (1988–1994) is a 68000-based arcade board with a sophisticated tilemap + sprite video pipeline built around the TC0180VCU custom chip. It was used for 15 unique titles including Rastan Saga II, Crime City, and Puzzle Bobble.

| Specification | Value |
|---|---|
| **Main CPU** | MC68000 @ 8–16 MHz (game-dependent) |
| **Sound CPU** | Z80 @ 4 MHz |
| **Display** | 320 × 240 @ 60 Hz |
| **Video Chip** | TC0180VCU (tilemaps + sprites + framebuffer) |
| **Palette Chip** | TC0260DAR (2048-color, 15-bit xRGB) |
| **I/O Chip** | TC0220IOC (joystick, coins, DIP) |
| **Sound Comm** | TC0140SYT (68000↔Z80 + ADPCM ROM arbiter) |
| **Sound** | YM2610 / YM2610B / YM2203 + OKI M6295 (game-dependent) |

---

## Supported Games

| Game | Set Name | Year | MRA |
|---|---|---|---|
| Nastar Warrior (Rastan Saga II) | `nastar` | 1988 | `nastar.mra` |
| Crime City | `crimec` | 1989 | `crimec.mra` |
| Master of Weapon | `masterw` | 1989 | — |
| Rambo III | `rambo3` | 1989 | — |
| Violence Fight | `viofight` | 1989 | — |
| Ashura Blaster | `ashura` | 1990 | — |
| Hit the Ice | `hitice` | 1990 | — |
| Sonic Blast Man | `sbm` | 1990 | — |
| Sel Feena | `selfeena` | 1991 | — |
| Silent Dragon | `silentd` | 1992 | — |
| Ryu Jin | `ryujin` | 1993 | — |
| Quiz Show | `qzshowby` | 1993 | — |
| Puzzle Bobble | `pbobble` | 1994 | `pbobble.mra` |
| Real Puncher | `realpunc` | 1994 | — |
| Space Invaders DX | `spacedx` | 1994 | — |

All games share the same chip set; per-game ROM layout differences are handled by the MRA file.

---

## Validation

- **Match rate:** 100% — 2299/2299 frames WRAM byte-perfect
- **CI run:** GREEN (Quartus exit 0, setup −56.224ns, 11,460/41,910 ALMs 27%)
- **Known issues:** None

---

## Build Instructions

### Requirements

- Quartus Prime Lite 17.0 (Cyclone V support)
- DE-10 Nano (MiSTer hardware)

### Synthesize

```bash
cd chips/taito_b/quartus
quartus_sh --flow compile taito_b.qpf
```

The bitstream `output_files/taito_b.rbf` is the MiSTer core file.

### Deploy to MiSTer

```
/media/fat/
  _Arcade/
    cores/
      taito_b_YYYYMMDD.rbf
    taito_b/
      nastar.mra
      crimec.mra
      pbobble.mra
```

---

## Core Architecture

```
taito_b.sv (top)
  ├── fx68k (MC68000 @ 8–16 MHz)
  ├── T80 (Z80 sound CPU @ 4 MHz)
  ├── tc0180vcu.sv (tilemap + sprite video controller)
  ├── tc0260dar.sv (palette DAC)
  ├── tc0220ioc.sv (I/O controller)
  ├── tc0140syt.sv (sound communication)
  ├── ym2610 / ym2203 (audio, game-dependent)
  ├── okim6295 (ADPCM audio)
  └── sdram_ctrl (ROM + WRAM arbitration)
```

### SDRAM Layout

| Offset | Size | Contents |
|---|---|---|
| 0x000000 | 512 KB | CPU program ROM |
| 0x080000 | 128 KB | Z80 audio program |
| 0x100000 | 1–2 MB | TC0180VCU GFX ROM |
| 0x200000 | 1 MB | ADPCM sample ROMs |

---

## Credits

- **fx68k** — Jorge Cwik (MIT) — https://github.com/ijor/fx68k
- **T80** — Daniel Wallner (LGPL)
- **ym2610/ym2203** — JOTEGO (GPL-2.0)
- **TC0180VCU/TC0260DAR/TC0220IOC** — MAME `taito_b.cpp`, `tc0180vcu.cpp`, community research
- **MiSTer sys/** — MiSTer-devel (GPL-2.0)
- **Hardware reference** — MAME `taito/taito_b.cpp`
