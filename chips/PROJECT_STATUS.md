# Project Status — Updated Continuously

Last updated: 2026-03-19 07:30 UTC

## Core Status

| Core | Synthesis | CPU Boot | GFX Rendering | Audio | Ship-Ready | Blocker |
|------|-----------|----------|---------------|-------|------------|---------|
| NMK16 | GREEN RBF | YES | BG tiles + palette | Untested | No | Sprites need NMK004 MCU ROM |
| Toaplan V2 | Pending CI | CPU RUNS (200K+ bus cycles) | Addr map fix in progress | Untested | No | V25 sound CPU not implemented; GP9001 addr mismatch |
| Psikyo | SDC fix pushed (was routing issue) | Sim harness built, debugging | Untested | Untested | No | Sim agent still running |
| Kaneko | ifdef fix pushed | Agent 2 building harness | GFX 32-bit fixed | Untested | No | Agent 2 working |
| Taito B | GREEN RBF | Agent 2 building harness | Untested | Untested | No | Agent 2 working |
| Taito X | GREEN RBF | Untested | Untested | Untested | No | Needs sim harness; CPU ROM + Z80 just fixed |
| Taito F3 | FROZEN | — | — | — | Dead | 461% ALM, won't fit DE-10 Nano |
| Taito Z | FROZEN | — | — | — | Dead | 2x fx68k, won't fit |

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

### Other Cores
No sim results yet — harnesses being built.

## CI Synthesis Status
Check live: `gh run list --limit 10` in the repo.

## Next Priorities
1. Complete sim harnesses for Toaplan V2 + Psikyo (in progress)
2. Build sim harnesses for Kaneko + Taito B + Taito X
3. NMK sprite investigation (NMK004 MCU ROM or bootleg ROM set)
4. MAME byte-by-byte comparison (once ROMs available)
5. Hardware boot test on DE-10 Nano
