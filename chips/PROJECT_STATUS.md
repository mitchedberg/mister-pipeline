# Project Status — Updated Continuously

Last updated: 2026-03-20 00:30 UTC

## Core Status

| Core | Synthesis | CPU Boot | GFX Rendering | Audio | Ship-Ready | Blocker |
|------|-----------|----------|---------------|-------|------------|---------|
<<<<<<< HEAD
| NMK16 | GREEN RBF | YES | BG tiles + palette | Untested | No | Sprites need NMK004 MCU ROM |
| Toaplan V2 | Pending CI | CPU RUNS (200K+ bus cycles) | Addr map fix in progress | Untested | No | V25 sound CPU not implemented; GP9001 addr mismatch |
| Psikyo | SDC fix pushed (was routing issue) | Sim harness built, debugging | Untested | Untested | No | Sim agent still running |
| Kaneko | ifdef fix pushed | Agent 2 building harness | GFX 32-bit fixed | Untested | No | Agent 2 working |
| Taito B | GREEN RBF | Agent 2 building harness | Untested | Untested | No | Agent 2 working |
| Taito X | GREEN RBF | Untested | Untested | Untested | No | Needs sim harness; CPU ROM + Z80 just fixed |
=======
| NMK16 | GREEN RBF | YES (1.38M+ cycles) | BG tiles (91% non-black, 38 colors) | Untested | No | Sprites blocked by missing nmk004.bin MCU ROM |
| Toaplan V2 | GREEN RBF | YES (200K+ cycles) | Untested (CPU hangs at V25 handshake) | Untested | No | Batsugun needs NEC V25 sound CPU, not Z80 |
| Psikyo | GREEN RBF (pre-GFX FSM) | YES | Game graphics rendering (Gunbird) | Untested | No | 2-beat GFX FSM overflows LABs; needs ifdef VERILATOR |
| Kaneko | GREEN RBF (pre-GFX FSM) | YES (100K+ cycles) | Palette writes visible (Berlwall) | Untested | No | Game loop stalled at I/O poll; WRAM writes=0 |
| Taito B | GREEN RBF | YES (82K+ cycles) | Untested | Untested | No | Nastar harness compiles; needs full sim validation |
| Taito X | GREEN RBF | YES (131+ cycles) | Non-black pixels from frame 12 (Gigandes) | Untested | No | Early attract mode; needs 300+ frame run |
>>>>>>> sim-batch2
| Taito F3 | FROZEN | — | — | — | Dead | 461% ALM, won't fit DE-10 Nano |
| Taito Z | FROZEN | — | — | — | Dead | 2x fx68k, won't fit DE-10 Nano |

## Bugs Fixed This Session (2026-03-19)

| Bug | Commit | Impact |
|-----|--------|--------|
| VPAn = 1'b1 across all cores | e6c8c64 | CPU hangs on interrupt acknowledge |
| CPU boot double-fault (Verilator phi race) | 2253262 | No core could sim-boot |
| BG tile ROM stale data (NMK) | 7118ec0 | Black/wrong BG tiles |
| Sprite ROM stale data (NMK) | d329383 | No sprite data |
| taito_b CPU ROM unwired | 5696c7d | CPU couldn't execute code |
| taito_x CPU ROM unwired + Z80 WAIT_n | 64c35a4 | CPU + Z80 couldn't execute |
| toaplan_v2 + kaneko GFX 32-bit | 432591f | Half of tile/sprite bytes zero |
| taito_b cpu_addr[0] synthesis error | 0bd1a86 | Quartus build failure |

## Simulation Results

### NMK16 / Thunder Dragon (3000 frames)
- Frames 0-39: black (init)
- Frames 40-802: copyright screen (55% non-black, 20 colors)
- Frames 803-810: transition
- Frames 812+: NMK warning screen (91% non-black, 25 colors)
- Frames 2400+: screen transition (57% non-black, 30 colors)
- Frames 2900+: new screen (54% non-black, 38 colors)
- Sprite RAM: all zeros through 3000 frames — blocked by missing nmk004.bin MCU ROM

### Toaplan V2 / Batsugun
- CPU boots with ROM_LOAD16_WORD_SWAP, runs 200K+ bus cycles
- Stalls at V25 sound CPU handshake (0x21FC00 shared RAM)
- Game can't progress past sound init without V25 implementation

### Psikyo / Gunbird
- CPU boots, ROM interleaving fixed
- Game graphics rendering confirmed
- 5 frames captured, non-black content visible

### Kaneko / Berlin Wall
- CPU boots (SSP=0x0020DFF0, PC=0x0000055E), 100K+ bus cycles
- 512 palette writes (all zero data)
- WRAM writes = 0 across 120 frames — game init stuck in I/O poll loop
- Frame capture fixed to 320x240

### Taito B / Nastar
- CPU boots, 82K bus cycles
- Sim harness compiles and runs
- Needs full simulation validation (300+ frames)

### Taito X / Gigandes (120 frames)
- CPU boots (SSP=0x00F04000, PC=0x000100)
- Non-black pixels from frame 12: purple sprite pixels visible
- 59 non-black frames in 120-frame run
- Game in early attract mode
- Fixes applied: ROM filenames, WRAM CS decode, vpos overflow, C-Chip stub, GFX interleaving, X1-001A bank latch

## CI Synthesis Status
Check live: `gh run list --limit 10` in the repo.

## Next Priorities
1. NMK sprite investigation — try tdragonb2 bootleg to bypass MCU ROM requirement
2. Psikyo synthesis overflow — ifdef VERILATOR guard on 2-beat GFX FSM
3. Kaneko I/O poll diagnosis — stub input/coin registers for game progress
4. Taito X 300+ frame run — verify full attract mode rendering
5. Taito B full simulation — validate Nastar CPU execution beyond 82K cycles
6. Toaplan V2 — investigate V25 sound CPU stub for game progression
7. Merge sim-batch2 branch to master
8. MAME byte-by-byte RAM comparison for all cores with rendered frames
9. Hardware boot test on DE-10 Nano (any green-RBF core)

### Agent Assignments

| Agent | Branch | Machine | Current Work |
|-------|--------|---------|--------------|
| Agent 1 | master | Mac Mini 3 | NMK sprites, Psikyo overflow fix, Toaplan V2 sound, Taito B stash |
| Agent 2 | sim-batch2 | iMac-Garage | Kaneko I/O debug, Taito X rendering, Taito B validation |
