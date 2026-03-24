# DECO 16-bit Arcade System

**MAME driver:** `dataeast/dec0.cpp` (Data East 16-bit CPU arcade platform)
**Phase:** 4 (directory scaffolding, pre-RTL)
**Status:** SCAFFOLDED — ready for Phase 5 (RTL implementation)

## System Overview

Data East's primary 16-bit arcade platform supporting 9 unique game titles across 39 ROM variants (1987–1990).
Single CPU (M68000 @ 10 MHz) + sound subsystem (Z80, YM2203, YM3812, OKI6295, MSM5205).
Two tile generators (BAC06), sprite engine, and MCU co-processor (Intel 8751).

## Supported Games

| Title | Year | ROM | Status |
|-------|------|-----|--------|
| Hamburger Battle | 1987 | `hbarrel` | RTL — Ready |
| Bad Dudes vs. DragonNinja | 1988 | `baddudes` | RTL — Ready |
| Bird Try | 1988 | `birdtry` | RTL — Ready |
| RoboCop | 1988 | `robocop` | RTL — Ready |
| Bandit | 1989 | `bandit` | RTL — Ready |
| Hippodrome | 1989 | `hippodrm` | RTL — Ready |
| Secret Agent | 1989 | `secretag` | RTL — Ready |
| Midnight Resistance | 1989 | `midres` | RTL — Ready |
| Boulder Dash | 1990 | `bouldash` | RTL — Ready |

## Directory Structure

```
deco16_arcade/
├── rtl/                     # Core RTL modules
│   ├── deco16_arcade.sv     # Top-level system (m68000 + BAC06 + IO)
│   ├── tb_top.sv            # Verilator testbench (CPU sim + MAME comparison)
│   └── ...                  # Address decoder, memory map, I/O logic
│
├── quartus/                 # Full synthesis project
│   ├── deco16_arcade.qsf    # Quartus 17.0 project settings (DE-10 Nano)
│   ├── emu.sv               # Top-level wrapper for MiSTer target
│   ├── deco16_arcade.sdc    # SDC timing constraints (m68000 multicycle, I/O)
│   └── ...                  # Pin assignments, IP descriptors
│
├── standalone_synth/        # Minimal synthesis target (5–15 min compile)
│   ├── deco16_arcade_top.sv # Minimal harness (no MiSTer framework)
│   ├── standalone.qsf       # Quartus project
│   └── standalone.sdc       # Timing constraints
│
├── sim/                     # Verilator simulation
│   ├── tb_system.cpp        # C++ testbench (MAME comparison, PPM dump)
│   ├── Makefile             # Build RTL + testbench → sim binary
│   ├── mame_scripts/        # MAME Lua scripts (golden frame dumps)
│   │   ├── dump_robocop.lua
│   │   ├── dump_baddudes.lua
│   │   └── ...
│   └── golden/              # MAME golden reference dumps (per-frame RAM)
│
├── mra/                     # MiSTer ROM descriptors
│   ├── Robocop.mra
│   ├── Bad Dudes vs DragonNinja.mra
│   └── ...
│
├── HARDWARE.md              # Auto-generated BOM: CPUs, chips, memory map
├── README.md                # This file
└── .gitignore               # Ignore sim artifacts (*.o, *.vcd, sim binary)
```

## Build Pipeline

### Gate 1: Verilator Behavioral Simulation
```bash
cd sim
make clean
make
./obj_dir/sim_deco16_arcade
```
**Expected:** CPU boots from ROM, executes game code, frame dumps to `/tmp/deco16_arcade_sim/`

### Gate 2: Static RTL Lint
```bash
bash ../../check_rtl.sh deco16_arcade
```
**Expected:** 0 warnings from lint + naming convention checks

### Gate 3: Standalone Synthesis (5–15 min)
```bash
cd standalone_synth
quartus_sh --flow compile deco16_arcade.qsf 2>&1 | tee build.log
```
**Expected:** <41,910 ALMs (fits DE-10 Nano with margin), 0 errors

### Gate 4: Full System Synthesis (30–90 min)
```bash
cd quartus
quartus_sh --flow compile deco16_arcade.qsf 2>&1 | tee build.log
```
**Expected:** RBF bitstream for MiSTer FPGA deployment

### Gate 5: MAME Golden Comparison
Sim runs 500 frames, compares RAM byte-by-byte to golden dumps.
```bash
python3 ../../compare_ram_dumps.py sim/tdragon_sim_500.bin golden/tdragon_golden.bin
```
**Expected:** >95% match or fully identified timing offsets

### Gate 6: Opus RTL Review
Cross-reference RTL against MAME `dec0.cpp`:
- Address decoder matches memory map
- Interrupt routing correct (VBlank latch)
- Sprite/tile DMA timing correct
- I/O port mapping correct

### Gate 7: Hardware Validation
Deploy to real DE-10 Nano, run games, visual inspection.

## Key Implementation Notes

**MCU:** Intel 8751 co-processor per-game. Requires Lua dump scripts for MAME comparison.
**Sound:** Z80 @ 4 MHz + 5x sound chips (FM/ADPCM). Use jt10, jt6295 if available.
**Video:** Dual BAC06 tile engines, X1-001A sprite engine (see community patterns).
**Timing:** DECO games have strict CPU-to-I/O timing windows — SDC multicycle paths required.

## See Also

- `HARDWARE.md` — Full BOM, chip inventory, memory map
- `../COMMUNITY_PATTERNS.md` — m68000 integration, BAC06 tile patterns
- `../GUARDRAILS.md` — Synthesis + simulation rules (MANDATORY READ)
- MAME source: [`mamedev/mame/src/mame/dataeast/dec0.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/dataeast/dec0.cpp)
