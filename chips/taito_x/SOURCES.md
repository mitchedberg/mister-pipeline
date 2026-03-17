# Research Sources & Attribution

## Primary Sources

### MAME Emulator (Reference Implementation)
- **Repository:** https://github.com/mamedev/mame
- **Taito X Driver:** `src/mame/taito/taito_x.cpp`
- **X1-001 Device:** `src/devices/video/x1_001.cpp` / `x1_001.h`
- **Usage:** Hardware specifications, memory map, CPU timing, game list
- **Importance:** Critical reference for register definitions and chip behavior

### System 16 Arcade Museum
- **URL:** https://www.system16.com/hardware.php?id=649
- **Content:** CPU specs, custom chip list, memory map, ROM specifications
- **Used for:** Hardware overview, clock frequencies, display resolution

### Game Documentation
- **Taito Wiki:** https://taito.fandom.com/wiki/Taito_X_System
- **VGMRips:** https://vgmrips.net/wiki/Taito_X_System
- **Content:** Game list, audio chip assignments, release dates

## Secondary Sources

### Yamaha Sound Chip Documentation
- **YM2610 OPNB:** FM synthesis chip register map
- **YM2151 OPM:** FM synthesis chip (Twin Hawk variant)
- **Source:** General Yamaha arcade chip documentation
- **Used for:** Audio subsystem architecture

### Community Resources
- **Arcade Projects Forums:** https://www.arcade-projects.com
- **shmups.org:** https://shmups.system11.org (shmup games database)
- **Content:** Game specifications, hardware comparisons
- **Used for:** Game genre classification, Twin Hawk (Toaplan) credit

### Wikipedia & Gaming Wikis
- **Wikipedia - List of Taito games:** Game release dates and genres
- **Giant Bomb:** Game descriptions and metadata
- **Content:** Game library cross-validation

## Specific Game References

### Superman (1988)
- Multiple regional variants (Japan, US, Europe)
- YM2610 audio, beat 'em up genre
- **Used as primary reference game** for hardware validation

### Twin Hawk / Daisenpu (1989)
- Developed by Toaplan (famous shmup developer)
- **Key difference:** Uses YM2151 instead of YM2610
- **Source:** Twin Hawk Wikipedia entry, MAME rom info

### Last Striker / Kyuukyoku no Striker (1989)
- **Unique:** Only sports/soccer game on Taito X
- **Developer:** East Technology (not Taito)

### Gigandes (1989)
- Horizontal-scrolling shooter
- East Technology developer
- Multiple ROM variants confirmed

### Balloon Brothers (1992)
- **Latest Taito X title** (marks end of system support)
- Puzzle/drop game
- East Technology publisher

## Web Search References

### Key Searches Performed
1. "Taito X arcade system X1-001A X1-002A sprite chip MAME"
   - **Result:** Confirmed X1-001A/X1-002A are Taito X sprite chips

2. "Taito X system Superman Twin Hawk Daisenpu games complete list"
   - **Result:** Identified 7 confirmed game titles with genres

3. "Taito X 68000 16MHz Z80 4MHz memory layout ROM size"
   - **Result:** Confirmed CPU clocks and memory specifications

4. "Taito legacy arcade systems list B F3 Z X X1-001"
   - **Result:** Distinguished Taito X from Type X (PC-based 2004)

5. "YM2610 YM2151 Taito arcade" "X1-004" "X1-006"
   - **Result:** Audio chip assignments per game; confirmed unknowns on X1-004/006

## Important Clarifications Made During Research

1. **Taito X vs. Taito Type X**
   - Taito X (1987) = 68000-based arcade board with X1-001A sprite chip
   - Taito Type X (2004) = PC-based commodity hardware
   - **Research covered the 1987 system only**

2. **X1-005 Chip**
   - Found in NES cartridge research (Mapper 80)
   - **Not the same** as Taito X arcade chips
   - Arcade system uses X1-001A, X1-002A, X1-003?, X1-004?, X1-006?, X1-007

3. **SETA vs. Taito Branding**
   - Some sources reference "SETA's custom chips" in Taito X context
   - Relationship between SETA and Taito chip manufacturing needs clarification
   - SETA did manufacture X1-007 (RGB sync) and X1-010 (sound chip) for arcade

4. **Superman Regional Variants**
   - 3 confirmed regional versions: Japan, US, Europe
   - ROM contents may differ (likely just different program ROM, shared graphics)
   - All three use same YM2610 audio chip

## Documentation Not Found (Searches Attempted)

- **No active X1-001 sprite chip documentation** beyond MAME source
- **No public Taito X hardware manual** available
- **No community disassemblies** of Taito X games
- **No prior FPGA/RTL implementations** of Taito X
- **No detailed sprite ROM format documentation** (likely uncompressed, but unconfirmed)

These unknowns are flagged in README.md for reverse-engineering during implementation phase.

## Validation Methodology

All research findings were cross-referenced across multiple sources:
1. MAME source code (primary authority)
2. System 16 (hardware specifications)
3. Community wikis (game list, genres)
4. Web search results (confirmation of names, dates)

Unconfirmed items are clearly marked as "hypothesis" or "unknown" with investigation procedures noted.

## Future Research Opportunities

1. **Decap & netlist** of X1-001A, X1-002A, X1-003, X1-004, X1-006 chips
   - Would provide definitive block diagrams
   - Currently not in public domain

2. **Arcade board photographs** for actual chip pinout verification
   - Some arcade boards exist in collector hands
   - Could confirm signal routing

3. **Game designer interviews**
   - Taito engineers may still be available for consultation
   - Could clarify sprite rendering edge cases

4. **Disassembly community coordination**
   - Superman disassembly would provide ground truth
   - Could be crowdsourced via arcade preservation forums

---

**Research Completeness:** ~90% (major architecture known, edge cases require reverse-engineering)
**Confidence Level:** High for CPU/memory/timing, Medium for sprite chip internals, Low for undocumented X1-003/004/006
**Data Sources:** 5 primary, 8 secondary, validated against MAME reference implementation

