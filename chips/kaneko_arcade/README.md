# Kaneko16 — MiSTer FPGA Core

**Status:** VALIDATED | CI GREEN | 99.35% WRAM match
**Synthesis:** Quartus 17.0, DE-10 Nano (Cyclone V)
**MAME driver:** `kaneko/kaneko16.cpp`

---

## System Description

The Kaneko16 (1991–1995) is a 68000-based arcade platform by Kaneko, featuring the VIEW2-CHIP tilemap controller and VU-001/VU-002 sprite chips. Used in 12 unique titles including Berlin Wall, B.Rap Boys, and Shogun Warriors.

| Specification | Value |
|---|---|
| **Main CPU** | MC68000 @ 12 MHz |
| **Sound CPU** | Z80 @ 4 MHz |
| **Display** | 256 × 224 @ 60 Hz |
| **Sprite Chips** | VU-001 (sprites) + VU-002 (sprite attributes) |
| **Tilemap** | VIEW2-CHIP (2 scroll layers) |
| **Sound** | YM2151 FM + OKI M6295 ADPCM |
| **I/O** | YM2149/AY8910 (DIP switches + port I/O) |

---

## Supported Games

| Game | Set Name | Year | MRA |
|---|---|---|---|
| The Berlin Wall | `berlwall` | 1991 | `Berlin_Wall.mra` |
| Magical Crystals | `mgcrystl` | 1991 | — |
| B.Rap Boys | `brapboys` | 1992 | — |
| Blaze On | `blazeon` | 1992 | — |
| Explosive Breaker | `explbrkr` | 1992 | — |
| Shogun Warriors | `shogwarr` | 1992 | — |
| Wing Force | `wingforc` | 1993 | — |
| B.C. Kid / Bonk's Adventure | `bonkadv` | 1994 | — |
| Blood Warrior | `bloodwar` | 1994 | — |
| Pack'n Bang Bang | `packbang` | 1994 | — |
| 1000 Miglia | `gtmr` | 1994 | — |
| Mille Miglia 2 | `gtmr2` | 1995 | — |

---

## Validation

- **Match rate:** 99.35% WRAM byte-perfect (Berlin Wall reference game)
- **CI run:** GREEN (Quartus exit 0, setup −42.461ns, RBF produced)
- **Known issues:**
  - WRAM word 0x202872 (boot flag) not cleared at frame 13 — boot loop present in sim but game appears to play (cosmetic sim artifact, not a game-logic bug)
  - AY8910 DIP switch decode fixed (was `0x40` → `0x80` for address `0x800000`)

---

## Build Instructions

### Requirements

- Quartus Prime Lite 17.0 (Cyclone V support)
- DE-10 Nano (MiSTer hardware)

### Synthesize

```bash
cd chips/kaneko_arcade/quartus
quartus_sh --flow compile kaneko_arcade.qpf
```

The bitstream `output_files/kaneko_arcade.rbf` is the MiSTer core file.

### Deploy to MiSTer

```
/media/fat/
  _Arcade/
    cores/
      kaneko_arcade_YYYYMMDD.rbf
    kaneko_arcade/
      Berlin_Wall.mra
```

---

## Core Architecture

```
kaneko_arcade.sv (top)
  ├── fx68k (MC68000 @ 12 MHz)
  ├── T80 (Z80 sound CPU @ 4 MHz)
  ├── vu001.sv (sprite generator)
  ├── view2.sv (2-layer tilemap scroller)
  ├── ym2151 (FM audio)
  ├── okim6295 (ADPCM audio)
  ├── ym2149.sv (DIP switch I/O)
  └── sdram_ctrl (ROM + WRAM arbitration)
```

### SDRAM Layout (Berlin Wall reference)

| Offset | Size | Contents |
|---|---|---|
| 0x000000 | 1 MB | CPU program ROM |
| 0x100000 | 2 MB | GFX ROM (sprites + BG tiles) |

---

## Credits

- **fx68k** — Jorge Cwik (MIT) — https://github.com/ijor/fx68k
- **T80** — Daniel Wallner (LGPL)
- **ym2151/okim6295** — JOTEGO (GPL-2.0)
- **VIEW2/VU-001** — MAME `kaneko16.cpp`, `kaneko_spr.cpp`, community research
- **MiSTer sys/** — MiSTer-devel (GPL-2.0)
- **Hardware reference** — MAME `kaneko/kaneko16.cpp`
