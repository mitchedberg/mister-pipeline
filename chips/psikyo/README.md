# Psikyo Arcade Hardware Research

## Coverage Status
**VERIFIED UNTOUCHED** — 0 MiSTer/FPGA cores found
- GitHub search `psikyo+mister`: 0 results
- GitHub search `psikyo+fpga`: 0 results
- jotego/jtcores: NO psikyo core (verified in full cores directory listing)
- No SystemVerilog/VHDL implementations found

## Hardware Architecture

### CPUs
- **Main CPU**: Motorola 68EC020 @ 16 MHz
- **Sound CPU**: Z80A / LZ8420M @ 4-8 MHz
- **Security**: PIC16C57 microcontroller @ 4 MHz (copy protection)

### Sound Chips
- **YM2610** (primary, earlier boards)
- **YMF286-K / YMF278B** (YM2610-compatible, later revisions)
- **OKIM6295** (bootleg versions)

### Custom Graphics Chips
- **PS2001B** (QFP160) — Graphics/sprite controller
- **PS3103** (QFP160) — Video generation
- **PS3204** (QFP100) — Graphics processing
- **PS3305** (QFP100) — Support functions

### Memory
- SRAM (62256, 6264, 6116, LH5168 variants)
- Mask ROMs (sprites, tiles, audio)
- Palette/LUT ROMs

## Key Games
- **Gunbird** (1994, Touhou-era shmup)
- **Gunbird 2** (1998)
- **Strikers 1945** (1995, vertical shmup)
- **Strikers 1945 II** (1997)
- **Strikers 1945 III** (1999)
- **S1945** series (various regional releases)
- **Dragon Blaze** (1999)
- **Samurai Aces** series

## Why Buildable
1. **Well-documented in MAME**: All custom chip behaviors reverse-engineered
2. **68EC020-based**: Simple CPU architecture, well-understood by FPGA community
3. **Moderate graphics complexity**: 4 custom chips but relatively straightforward tile/sprite blitting
4. **No analog/complex timing**: No scanline counters or complex interrupt sequencing
5. **Can leverage Taito F3 experience**: Similar graphics pipeline (tile+sprite+priority)
6. **PIC16C57 optional**: Can stub copy protection, games play without real emulation

## Difficulty Estimate
**MEDIUM-HIGH** (~80-120 dev days)
- Custom chip reverse-engineering required (no existing FPGA work)
- Sprite/tile pipeline similar to Taito F3 but with unique blending/priority rules
- Sound chip (YM2610) already solved in jotego cores
- 68EC020 is standard across multiple arcade systems

## Notes
- Recently active PIC16C57 replacement project (motozilog/psikyoPic16C57Replacement, Feb 2026) indicates community interest in Psikyo preservation
- No FPGA work started yet despite active hardware preservation efforts
- Strong candidate for post-Taito X work — good coverage of 1990s shmup library
