# Nichibutsu Arcade Hardware Research

## Coverage Status
**PARTIALLY COVERED** — Console core exists, but arcade hardware untouched
- **My Vision (Console)**: COMPLETE & RELEASED (MiSTer-devel, VHDL, Dec 2025)
  - Nichibutsu console emulation, not arcade hardware
  - Status: Active (2 stars, 6 forks)
- **Nichibutsu Arcade Hardware**: 0 MiSTer/FPGA cores found
  - GitHub search `nichibutsu+mister+arcade`: Only console result
  - GitHub search `bombjack+nichibutsu+fpga`: 0 results
  - jotego/jtcores: NO nichibutsu arcade core

## Hardware Architecture

### Notable Nichibutsu Arcade Systems
(Limited public documentation vs other vendors; MAME source is primary reference)

**Bomb Jack Era** (early 1980s):
- Simple 68000 or Z80 core
- Basic tile/sprite graphics
- Limited color palette

**Later Systems** (late 1980s+):
- 68000 @ 10-12 MHz
- Z80 sound processor
- Custom tile/sprite controllers (varying by board revision)
- YM2203 / OKI6295 audio

### Custom Chips
- Nichibutsu-specific sprite/tile controllers (poorly documented compared to Taito/Capcom)
- Protection/IO chips (design specifics unclear)

### Memory
- Standard SRAM (6116, 6264, 62256)
- Mask ROMs
- Minimal palette storage

## Key Games
- **Bomb Jack** (1984, platformer) — Most famous title
- **Bomb Jack II** (1985)
- **Blast Off** (1984, shooter)
- **Galaxy Wars** (various board types)
- **Mahjong variants** (significant portion of Nichibutsu output)

## Why Buildable
1. **68000/Z80-based**: Standard CPUs
2. **Can leverage existing arcade framework**: All support chips (YM2203, OKI6295) solved
3. **Graphics simpler than custom-heavy vendors**: Nichibutsu used standard approach

## Why LOWER PRIORITY
1. **Limited arcade library**: Small game catalog, mostly Bomb Jack + gambling/mahjong titles
2. **Sparse documentation**: Far less reverse-engineered detail than Taito/Capcom/Psikyo
3. **Console emulation exists but != Arcade**: My Vision core won't transfer to arcade hardware
4. **Protection mysteries**: Limited public info on encryption/anti-piracy
5. **Niche appeal**: Bomb Jack is retro-famous, but modern shmup/action gaming community is elsewhere

## Difficulty Estimate
**UNKNOWN/HIGH RISK** (~80-120 dev days, but HIGH UNCERTAINTY)
- **Sparse MAME documentation**: Custom chip behaviors less well-documented than major vendors
- **Limited arcade titles**: Fewer test cases for validation
- **No existing FPGA work**: Starting from zero with minimal community knowledge
- **Console core won't help**: My Vision is a separate system entirely
- **Deprecation risk**: If only Bomb Jack drives interest, effort may not justify broad use

## Notes
- **NOT RECOMMENDED for post-Taito X work**: Better alternatives (Psikyo, Toaplan V2, NMK) have larger/more cohesive game libraries
- **Future option if interest grows**: Could revisit after clearing high-value targets
- **Bomb Jack cult status**: Game is beloved, but alone doesn't justify hardware implementation vs emulation
- **Comparison to NMK**: NMK is architecturally simpler AND has better game coverage
