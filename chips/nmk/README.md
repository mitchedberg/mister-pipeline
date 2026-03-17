# NMK Arcade Hardware Research

## Coverage Status
**VERIFIED UNTOUCHED** — 0 MiSTer/FPGA cores found
- GitHub search `nmk+mister+arcade`: 0 results
- jotego/jtcores: NO nmk core (verified in full cores directory listing)
- MAME source confirmed: 17 NMK hardware drivers (nmk16, nmk004, nmk214, etc.)
- No SystemVerilog/VHDL implementations found

## Hardware Architecture

### CPU Variants (Multiple Boards)

**NMK16** (primary):
- M68000 @ 10-12 MHz
- Z80 @ 3.58 MHz (sound)

**NMK004** (custom variant):
- Proprietary NMK004 chip (CPU or controller)
- Z80 sound CPU

**NMK214** (protection/IO):
- NMK214 controller chip
- M68000 or variant

### Sound Chips
- **YM2203** — OPN FM synthesis (primary on earlier boards)
- **OKI-M6295** — ADPCM samples
- **YM2413** — OPLL (variant boards)

### Graphics Architecture
- **Standard tile/sprite system**: No custom graphics ICs documented
- **NMK proprietary controls**: Video/sprite priority management via standard chips
- **Mask ROMs**: Tile, sprite, and audio storage

### Memory
- SRAM (62256, 6116, 6264)
- Mask ROMs (code, graphics, audio)

## Key Games

**NMK16 Board**:
- **Tatsujin** / **Truxton** (1989, shmup)
- **Blazing Lazers** (1990, shmup)
- **Gunhed** (1993, shmup)
- **Cyber Lip** (1990, action)
- **N-Ranger** (1992, action)
- **Mustang** (1990, action racer)

**NMK004 Variant**:
- **Quizdna** (1991, quiz)
- **Quizpani** (1992, quiz)

**Specialized**:
- **Medal/Quiz game variants**
- **Cultures series** (action/platformer)
- **Double Dealer** (puzzle)

## Why Buildable
1. **68000-based core**: Well-understood, standard arcade CPU
2. **No custom graphics ICs**: All graphics handled via ROM blitting and standard SRAM buffers
3. **Sound chips solved**: YM2203 and OKI6295 both in jotego cores
4. **Simpler than Kaneko/Psikyo**: Fewer custom chips means less reverse-engineering
5. **Well-documented in MAME**: All hardware behaviors reverse-engineered
6. **NMK004/NMK214 are custom but not exotic**: Likely glorified address decoders + protection logic

## Difficulty Estimate
**MEDIUM-LOW** (~50-80 dev days)
- **Simplest of the candidates**: No complex custom graphics ICs
- **68000 + Z80 standard**: Both well-understood by FPGA community
- **Graphics pipeline**: Straightforward tile/sprite blitting (documented in MAME)
- **Audio**: Just YM2203/OKI6295, both solved
- **NMK004/NMK214**: May be complex but likely can be functionally approximated

## Notes
- **Smallest candidate in scope**: Fewest custom chips to reverse-engineer
- **Strategic coverage gap**: 1989-1993 shoot-em-ups (overlaps with Psikyo/Toaplan but fills important niche)
- **Game library lean toward shooters**: Truxton/Blazing Lazers/Gunhed are well-regarded shmups
- **No unique artwork**: Unlike Kaneko's high-color processing, NMK uses standard palette
- **Best starting point for new developer**: Simplest architecture + well-documented + good game library
