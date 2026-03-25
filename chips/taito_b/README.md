# Taito B System — MiSTer FPGA Core

**Status:** REVALIDATING | shared TC0180VCU Quartus hardening in progress | hardware pending
**Synthesis:** Quartus 17.0, DE-10 Nano (Cyclone V), fresh full build pending
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

- **Local gate-5:** 99.6666% WRAM match for frames 25–499 (Nastar, 2026-03-25 revalidation run)
- **Early boot variance:** frames 1–24 still diverge from MAME golden; gameplay-range match remains in prior gate-5 class
- **CI run:** full Taito B Quartus rebuild pending for the shared `tc0180vcu` hardening pass
- **Multi-game support:** `game_id` input wire selects address map at runtime. Nastar=0 (default), Crime City=1. Set via MRA ioctl_index=0xFF header byte. Crime City pending full validation.
- **Known issues:** hardware validation still pending on the current shared-TC0180VCU branch

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
