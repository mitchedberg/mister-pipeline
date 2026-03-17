# Kaneko 16-Bit Arcade Hardware Research

## Coverage Status
**VERIFIED UNTOUCHED** — 0 MiSTer/FPGA cores found
- GitHub search `kaneko+mister+fpga`: 0 results
- jotego/jtcores: NO kaneko core (verified in full cores directory listing)
- No SystemVerilog/VHDL implementations found

## Hardware Architecture

### CPUs
- **Main CPU**: Motorola 68000 @ 10-12 MHz
- **Optional MCU**: NEC variants (uPD78322 CALC3, uPD78324 TBSOP01/TBSOP02)
- **Sound CPU**: Z80 / OKI-M6295 configurations vary by board

### Custom Graphics Chips
- **VU-001 046A** (48-pin PQFP) — Sprite/tile controller
- **VU-002 052 151021** (160-pin PQFP) — Main sprite processor
- **VU-003 048 XJ009** (40-pin, ×3 units) — High-color background processing
- **VIEW2-CHIP 23160-509 9047EAI** (144-pin PQFP) — Tilemap generation
- **MUX2-CHIP** (64-pin PQFP) — Multiplexer/control
- **HELP1-CHIP** (64-pin PQFP) — Support logic
- **IU-001 9045KP002** (44-pin PQFP) — I/O interface

### Sound
- **OKI-M6295** (1-2 chips) — ADPCM synthesis
- **YM2149** (0-2 chips, optional)
- **Z80 + YM2151** (alternative configuration)

### Custom Logic
- **Kaneko CALC3** — MCU-based protection/math coprocessor
- **Kaneko HIT** — Collision detection
- **Kaneko SPR** — Sprite management (alternate)
- **Kaneko TMAP** — Tilemap (VIEW2 variant)
- **Kaneko TOYBOX** — Racing game MCU subsystem
- **93C46 EEPROM** — Configuration storage

### Memory
- SRAM (62256, 6116, etc)
- Mask ROMs (code, sprites, tiles, audio)
- Palette/LUT ROMs

## Key Games
- **The Berlin Wall** (1991, action)
- **Brap Boys** (1992, bike racing)
- **Bonk's Adventure** arcade variants
- **Gals Panic** (1990, puzzle)
- **Shogun Warriors** (1992, fighter, CALC3-based)
- **B.C. Story** (1989)
- **Blazing Lazers / Gunhed** (1993)

## Why Buildable
1. **68000-based**: Well-understood CPU architecture
2. **Moderate custom chip complexity**: 7 custom ICs but relatively straightforward blitting/priority
3. **Sound chips solved**: YM2151 and OKI6295 already in jotego cores
4. **Graphics pipeline documented in MAME**: All custom chip behaviors reverse-engineered
5. **No exotic timing**: Unlike Taito with scanline IRQ counters, Kaneko is more straightforward
6. **CALC3/TOYBOX are MCU-based**: Can stub protection or implement if needed

## Difficulty Estimate
**MEDIUM** (~70-100 dev days)
- **Custom graphics pipeline**: More complex than 68K alone, but not as intricate as Taito F3
- **Multi-chip graphics**: VU-series requires pipelining sprite/tile/priority/blending
- **CALC3 protection**: May be optional (many games work with stubbed math ops)
- **Race-condition potential**: Multiple custom chips, may need careful arbitration
- **Sound integration**: Simpler than Taito (no sample wavetable synthesis)

## Notes
- **Moderate game library**: ~12 known titles, good coverage of late 1980s-early 1990s action/racing
- **Active MAME documentation**: Custom chip behaviors well-documented in MAME source
- **No community FPGA work yet**: Clean slate, no existing cores to build from
- **Comparison to Taito B**: Similar era/complexity, but Kaneko's graphics are more straightforward
- **Potential MCU challenges**: CALC3 and TOYBOX are complex MCU subsystems; may require cycle-accurate emulation for some titles
