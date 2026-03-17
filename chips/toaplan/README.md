# Toaplan Arcade Hardware Research

## Coverage Status
**PARTIALLY COVERED** — 2 existing MiSTer cores, but major gaps remain
- **Toaplan V1 (via zerowing)**: COMPLETE & RELEASED (va7deo, 174 commits, 47 stars)
  - Games: Tatsujin, Hellfire, Zero Wing, OutZone
  - Status: Marked "Implemented" with "Released: Yes"
  - Last updated: October 2025
- **Toaplan Vimana (via vimana)**: BETA (va7deo, active development)
  - Games: Vimana, Fire Shark, Same! Same! Same!
  - Status: Known issues (OPL2 audio, IRQ timing, HD647180X unimplemented)
  - Last updated: October 2025
- **Toaplan V2**: NOT COVERED (0 results found)
  - Major titles missing: Batsugun, Truxton II, Dogyuun, FixEight, Twin Cobra
  - No FPGA implementation exists

## Hardware Architecture

### Toaplan V1
**CPUs**:
- M68000 @ 10 MHz
- Z80 @ 3.58 MHz (sound)

**Custom Graphics Chips**:
- GFXROM controller
- Sprite/tile blitting engines
- Priority/blending units

**Sound**:
- YM2610 / YM2151

### Toaplan V2 (Not Yet FPGA'd)
**CPUs**:
- M68000 @ 10-12 MHz
- HD647180X (or Z80 substitute) @ variable
- Possible 32-bit co-processor on later versions

**Custom Graphics Chips**:
- Enhanced tile/sprite system vs V1
- Multiple blending/palette modes
- Likely more complex interrupt/timing handling

### Memory
- SRAM (6116, 6264, 62256 variants)
- Mask ROMs (code, sprites, tiles, audio)
- Palette ROMs

## Key Games (Covered vs Uncovered)

### Already FPGA'd (V1 only)
- Tatsujin / Truxton (1989)
- Hellfire (1990)
- Zero Wing (1989, "All Your Base" fame)
- OutZone (1990)

### NOT YET FPGA'd (V2 — Major Gap)
- **Batsugun** (1993, bullet-hell shmup)
- **FixEight** (1992)
- **Dogyuun** (1992)
- **Truxton II / Tatsujin Oh** (1992)
- **Twin Cobra** (1987, V1 variant?)
- **Vimana** (in vimana core, but with known issues)

## Why Buildable
1. **V1 is proven FPGA-capable**: zerowing core shows exact architecture
2. **Can fork existing work**: Use va7deo's V1 as reference for V2 extension
3. **68000-based**: Well-understood by FPGA community
4. **Moderate graphics complexity**: Similar pipeline to Taito F3/Psikyo
5. **Sound chips (YM2610/YM2151)**: Already solved in jotego cores
6. **Strong community interest**: Active development as of Oct 2025

## Difficulty Estimate

### Toaplan V1 (Complete)
**DONE** — Use existing zerowing core (GPL-2.0)

### Toaplan V2 (Untouched)
**MEDIUM** (~60-90 dev days to extend from V1)
- Architectural changes from V1 are likely incremental
- HD647180X co-processor may add complexity (but can substitute Z80 as vimana does)
- Graphics blending/palette modes probably evolved, not revolutionary
- Batsugun's advanced bullet patterns don't require new hardware — just logic

## Notes
- **Strategic win**: V2 covers critical 1990s bullet-hell shmup library
- **Build order**: Complete vimana fixes first (fix OPL2, IRQ timing), then extend to V2
- **HD647180X**: vimana currently uses Z80 substitute; consider whether full emulation needed
- **Community expertise**: va7deo (zerowing/vimana author) could advise on V2 extension
- **Architecture evolution**: V1→V2 likely similar progression as Taito B→F3
