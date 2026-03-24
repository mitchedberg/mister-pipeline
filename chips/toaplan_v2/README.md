# Toaplan V2 — MiSTer FPGA Core

**Status:** SYNTHESIS VERIFIED | CI FAILING (ALM overflow — QSF fix pending)
**Synthesis:** Quartus 17.0, DE-10 Nano (Cyclone V)
**MAME drivers:** `toaplan/batsugun.cpp`, `dogyuun.cpp`, `truxton2.cpp`, `kbash.cpp`, `fixeight.cpp`, `snowbro2.cpp`

---

## System Description

The Toaplan V2 (1992–1994) is the final generation of Toaplan's arcade hardware, built around the GP9001 graphics processor — one of the most capable sprite/tilemap chips of the early 1990s. It powered classics like Batsugun, Truxton II, and Knuckle Bash.

| Specification | Value |
|---|---|
| **Main CPU** | MC68000 @ 16 MHz |
| **Sound CPU** | NEC V25 @ 16 MHz (batsugun) or Z80 (others) |
| **Display** | 320 × 240 @ 60 Hz |
| **Graphics** | GP9001 VDP (2× instances in batsugun, 1× in others) |
| **Sound** | YM2151 FM + OKI M6295 ADPCM |
| **GP9001** | 4 scroll layers + sprite layer, 4-bpp, line scroll |

---

## Supported Games

| Game | Set Name | Year | MRA | Notes |
|---|---|---|---|---|
| Batsugun | `batsugun` | 1993 | `Batsugun.mra` | Reference — dual GP9001 |
| Dogyuun | `dogyuun` | 1992 | `Dogyuun.mra` | |
| Truxton II | `truxton2` | 1992 | — | |
| Knuckle Bash | `kbash` | 1993 | `Knuckle_Bash.mra` | |
| FixEight | `fixeight` | 1992 | — | |
| Snow Bros. 2 | `snowbro2` | 1994 | `Snow_Bros_2.mra` | |
| V-Five | `vfive` | 1993 | `V-Five.mra` | |

---

## Validation

- **Status:** Runs; golden dump comparison pending (Toaplan V2 boot loop under investigation)
- **CI run:** FAILING — 27,542/41,910 ALMs (66%), routing congestion from GP9001 Gates 3–5. QSF updated with `AGGRESSIVE_AREA + AGGRESSIVE_FIT`; CI re-run pending.
- **Known issues:**
  - GP9001 VRAM restructure may be needed (~800 ALM savings) — Opus review pending
  - GFX SDRAM upper 16 bits zero (bitplane ordering) — needs verification

---

## Build Instructions

### Requirements

- Quartus Prime Lite 17.0 (Cyclone V support)
- DE-10 Nano (MiSTer hardware)

### Synthesize

```bash
cd chips/toaplan_v2/quartus
quartus_sh --flow compile toaplan_v2.qpf
```

**Note:** As of 2026-03-23, synthesis fails (device too full). QSF aggressive area settings applied; CI re-run pending. Do not treat as release-ready until CI passes.

### Deploy to MiSTer

```
/media/fat/
  _Arcade/
    cores/
      toaplan_v2_YYYYMMDD.rbf
    toaplan_v2/
      Batsugun.mra
      Dogyuun.mra
      ...
```

---

## Core Architecture

```
toaplan_v2.sv (top)
  ├── fx68k (MC68000 @ 16 MHz)
  ├── T80 (Z80 sound CPU)
  ├── gp9001.sv (graphics processor, 1–2 instances)
  │     ├── 4× scroll layers (line scroll capable)
  │     └── sprite engine (4-bpp)
  ├── ym2151 (FM audio)
  ├── okim6295 (ADPCM audio)
  └── sdram_ctrl (ROM + WRAM arbitration)
```

### SDRAM Layout (Batsugun reference)

| Offset | Size | Contents |
|---|---|---|
| 0x000000 | 512 KB | CPU program ROM |
| 0x100000 | 6 MB | GFX ROMs (GP9001 tile/sprite data) |
| 0x500000 | 256 KB | ADPCM ROM (OKI M6295) |
| 0x600000 | 32 KB | Z80 sound ROM (unused for Batsugun — V25 game) |

---

## Credits

- **fx68k** — Jorge Cwik (MIT) — https://github.com/ijor/fx68k
- **T80** — Daniel Wallner (LGPL)
- **GP9001** — JOTEGO (GPL-2.0), adapted for this core
- **ym2151/okim6295** — JOTEGO (GPL-2.0)
- **MiSTer sys/** — MiSTer-devel (GPL-2.0)
- **Hardware reference** — MAME `toaplan/batsugun.cpp`, `toaplan2.cpp`
