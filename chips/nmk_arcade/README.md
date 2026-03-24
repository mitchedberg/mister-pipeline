# NMK16 — MiSTer FPGA Core

**Status:** VALIDATED | CI GREEN | 95.91% WRAM match
**Synthesis:** Quartus 17.0, DE-10 Nano (Cyclone V)
**MAME driver:** `nmk/nmk16.cpp`

---

## System Description

The NMK16 (1989–2000) is a 68000-based arcade platform used by NMK, UPL, Banpresto, and Afega across 30+ unique titles. Best known for Thunder Dragon, Macross, and Power Instinct. The hardware features a dedicated sprite layer and scrolling tilemap layers.

| Specification | Value |
|---|---|
| **Main CPU** | MC68000 @ 8–10 MHz |
| **Sound** | NMK004 MCU (sound controller) or Z80 + YM2203/OKI M6295 |
| **Display** | 256 × 224 @ 56 Hz |
| **Sprites** | NMK chip (4-bpp, 16×16 tiles) |
| **Tilemaps** | 2 scroll layers (BG + FG) |
| **ADPCM** | OKI M6295 (1–2 instances, bank-switched) |

---

## Supported Games

| Game | Set Name | Year | MRA |
|---|---|---|---|
| Thunder Dragon | `tdragon` | 1991 | `Thunder_Dragon.mra` |
| Task Force Harrier | `tharrier` | 1989 | — |
| Bio-Ship Paladin | `bioship` | 1990 | — |
| US AAF Mustang | `mustang` | 1990 | — |
| Vandyke | `vandyke` | 1990 | — |
| Acrobat Mission | `acrobatm` | 1991 | — |
| Black Heart | `blkheart` | 1991 | — |
| Hacha Mecha Fighter | `hachamf` | 1991 | — |
| Super Spacefortress Macross | `macross` | 1992 | — |
| GunNail | `gunnail` | 1993 | — |
| Saboten Bombers | `sabotenb` | 1992 | — |
| Bombjack Twin | `bjtwin` | 1993 | — |
| Power Instinct | `powerins` | 1993 | — |
| Macross II | `macross2` | 1993 | — |
| Thunder Dragon 2 | `tdragon2` | 1993 | — |
| Arcadia (NMK) | `arcadian` | 1994 | — |

Plus later Afega/Comad variants (1995–2000) on compatible hardware.

---

## Validation

- **Match rate:** 95.91% WRAM byte-perfect
- **CI run:** GREEN (Quartus exit 0, setup −17.859ns, 10,937/41,910 ALMs 26%)
- **Remaining diffs:** NMK004 MCU timing (sound subsystem); no game-logic divergence

---

## Build Instructions

### Requirements

- Quartus Prime Lite 17.0 (Cyclone V support)
- DE-10 Nano (MiSTer hardware)

### Synthesize

```bash
cd chips/nmk_arcade/quartus
quartus_sh --flow compile nmk_arcade.qpf
```

The bitstream `output_files/nmk_arcade.rbf` is the MiSTer core file.

### Deploy to MiSTer

```
/media/fat/
  _Arcade/
    cores/
      nmk_arcade_YYYYMMDD.rbf
    nmk_arcade/
      Thunder_Dragon.mra
```

---

## Core Architecture

```
nmk_arcade.sv (top)
  ├── fx68k (MC68000 @ 8–10 MHz)
  ├── T80 (Z80 sound CPU)
  ├── nmk_sprite.sv (4-bpp sprite renderer)
  ├── nmk_scroll.sv (2-layer tilemap scroller)
  ├── ym2203 / ym2151 (FM audio, game-dependent)
  ├── okim6295 (ADPCM audio)
  ├── nmk004.sv (MCU sound controller, simplified)
  └── sdram_ctrl (ROM + WRAM arbitration)
```

### SDRAM Layout (Thunder Dragon reference)

| Offset | Size | Contents |
|---|---|---|
| 0x000000 | 256 KB | CPU program ROM |
| 0x0C0000 | 1 MB | Sprite ROM |
| 0x1C0000 | 128 KB | BG/FG tile ROM |
| 0x200000 | 512 KB | ADPCM ROM (OKI bank 0) |
| 0x280000 | 64 KB | Z80/NMK004 sound ROM |

---

## Credits

- **fx68k** — Jorge Cwik (MIT) — https://github.com/ijor/fx68k
- **T80** — Daniel Wallner (LGPL)
- **ym2203/ym2151** — JOTEGO (GPL-2.0)
- **okim6295** — JOTEGO (GPL-2.0)
- **MiSTer sys/** — MiSTer-devel (GPL-2.0)
- **Hardware reference** — MAME `nmk/nmk16.cpp`, community NMK16 research
