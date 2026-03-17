# Data East DECO32 Arcade Hardware Research

## Coverage Status
**VERIFIED UNTOUCHED** — 0 MiSTer/FPGA cores found
- GitHub search `deco32+mister`: 0 results
- GitHub search `data+east+deco+fpga`: 0 results
- jotego/jtcores: NO deco32 core (verified in full cores directory listing)
- No SystemVerilog/VHDL implementations found

## Hardware Architecture

### CPUs
- **Main CPU**: ARM processor @ 28 MHz / 4 = 7 MHz effective
- **Sound CPU**: H6280 @ 32.22 MHz / 4 / 3 (or Z80 variant @ 32.22 MHz / 9)

### Custom Chips
**Graphics & Processing**:
- **DE 156** (100-pin PQFP) — Encrypted ARM CPU container
- **DE 141** (160-pin PQFP) — Main graphics processor
- **DE 74** (160-pin PQFP) — Graphics support
- **DE 99** (208-pin PQFP) — General processing
- **DE 52** (128-pin PQFP, multiple units) — Graphics-related
- **DE 153** (144-pin PQFP) — Graphics support

**I/O & Protection**:
- **DE 146** (DECO146PROT) — Protection/IO controller
- **DE 113, 104, 200** — Support/control functions

### Sound Chips
- **YM2151** — Yamaha FM synthesis
- **OKI M6295** — Multiple PCM sample chips per board

### Memory
- Various SRAM configurations
- Mask ROMs (graphics, code, audio)
- Palette/LUT storage

## Key Games
- **Caveman Ninja (Caveman Dino) series**
- **Fighter's History** (1992, fighting game)
- **Wizard Fire** (1992)
- **Demolition Man** (1995, rail shooter-style)
- **Night Slashers** (1993)
- **Games adapted from Deco Cassette system**

## Why Buildable
1. **Well-documented in MAME**: All custom chip reverse-engineered
2. **ARM architecture**: More complex than 68K but well-studied for FPGA
3. **Moderate graphics complexity**: Tile + sprite + blending pipeline
4. **No exotic custom logic**: Main challenge is ARM emulation, not timing-sensitive electronics
5. **Sound (YM2151) already solved**: jotego has jt51 core

## Difficulty Estimate
**HIGH** (~120-180 dev days)
- **ARM CPU emulation required**: More complex than 68K/Z80, instruction decode needed
- **Encrypted CPU wrapper (DE 156)**: May require key extraction or functional simulation
- **Custom chip documentation**: Limited public details on DE 141/74/99 rendering pipeline
- **Graphics blending**: Multiple blending modes across custom chips
- **Protection chip (DE 146)**: Likely complex state machine

## Notes
- ARM encryption on DE 156 may require reverse-engineering from MAME implementation
- H6280 is the Hu6280 from PC Engine — also not yet in jotego cores
- Smallest game library of candidates but strategically important for 1990s fighting/action games
- No active preservation efforts found (unlike Psikyo with recent PIC work)
- Higher risk due to encryption and less community documentation
