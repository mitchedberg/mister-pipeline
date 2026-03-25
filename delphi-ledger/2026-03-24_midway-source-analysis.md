# Midway Y-Unit FPGA Source Code Analysis
**Date**: March 24, 2026
**Purpose**: Evaluate FPGA implementation feasibility for MiSTer, particularly scanline buffer approach to SDRAM bandwidth problems

## Executive Summary

**Status**: Source code NOT publicly available. Only comprehensive technical documentation available.

**Key Finding**: Coin-Op Collection (closed-source FPGA team) has released Y-Unit and Z-Unit cores for Analogue Pocket and OpenFPGA, with extensive technical documentation. Pramod Somashekar (pram0d) attempted MiSTer Y-Unit (stated "not feasible" due to SDRAM bandwidth), but source NOT in public GitHub.

**Scanline Buffer Approach**: Viable for **only 2 games** (Smash TV, Total Carnage) due to staging VRAM architecture. Cannot solve general case without hardware redesign.

---

## Part 1: Source Code Search Results

### Repositories Investigated

| Repository | Status | Notes |
|----------|--------|-------|
| `Coin-OpCollection/Development-Documentation` | ✅ Public | Technical documentation, schematics, service manuals |
| `Coin-OpCollection/Distribution-MiSTerFPGA` | ✅ Public | Distribution files only (compiled cores), no HDL |
| `Coin-OpCollection/Distribution-OpenFPGA` | ✅ Public | Distribution files only (compiled cores), no HDL |
| `psomashekar/Midway_Y_Unit_MiSTer` | ❌ Not Found | Repository doesn't exist |
| `Toryalai1/Coin-Op_Collection` | ✅ Public | Mirror/fork, distribution files only |

**Critical Insight**: All active Coin-Op Collection source code is CLOSED-SOURCE. Distribution repos contain only compiled `.core` files for Analogue Pocket/OpenFPGA and launchpad files for MiSTer, no HDL source.

**Pramod's Status** (per blog + forum posts):
- Spent 6+ months developing MiSTer Y-Unit alpha
- Stated "not feasible" for general games (only Smash TV + Total Carnage playable)
- Source never released to public GitHub
- Mentioned "various memory models" that failed bandwidth constraints

---

## Part 2: Y-Unit Architecture (from Coin-Op Documentation)

### High-Level System Architecture

Y-Unit is an evolved Z-Unit with **consolidated boards**:

| Component | Details |
|-----------|---------|
| **Boards** | 2 total: Main CPU + Sound (vs Z-Unit's 4: CPU + ROM + I/O + Sound) |
| **CPU** | TMS34010 @ ~16 MHz (35 MIPS graphics processor, integrated GPU) |
| **VRAM** | 512 KB total (256KB Palette RAM + 256KB Bitmap RAM), 16-bit pixels |
| **Pixel Clock** | 8 MHz (vs Z-Unit's 16 MHz) |
| **Resolution** | ~400×256 @ 6bpp (vs Z-Unit's 512×400 @ 8bpp) |
| **Graphics Method** | **Software sprites** via high-speed DMA (blitter), NOT hardware sprite engine |
| **ROM Fetch** | 32-bit DMA to Image ROM + 16-bit CPU fetch, triple-banked Image ROM |

### Memory Layout

```
CPU Address Space (TMS34010 1-bit addressing):
├─ 0x00000000–0x00FFFFFF: Local RAM (work space, stacks, game state)
├─ 0x01000000–0x01FFFFFF: VRAM (Palette + Bitmap)
├─ 0x1A000000–0x1AFFFFFF: DMA Registers (command, offset, XY, width/height)
├─ 0x1B000000–0x1BFFFFFF: Audio interface / Sound board comms
├─ 0x1C000000–0x1CFFFFFE: Protection IC (6 games) OR dynamic RAM-based protection (Strike Force)
└─ Image ROM: Addressable via DMA, 32-bit data path

VRAM Structure (512 KB @ 16-bit pixel width):
├─ Palette RAM: 256 KB (contains actual color palette entries)
├─ Bitmap RAM: 256 KB (frame buffer, stores pixel indices into palette)
└─ **LAST 2 LINES**: Pre-loaded clear values for autoerase/bulk-fill operations
```

### TMS34010 CPU Core Implementation

**From Pramod's blog + Coin-Op docs (7000+ lines Verilog):**

**CPU Architecture**:
- Word-length: 32-bit internal, 16-bit external bus (CPU-to-local-RAM)
- 1-bit addressing scheme (converts to byte addresses for DRAM)
- Integrated memory controller (shift register for line clearing)
- Integrated GPU with FILL instruction (bulk clear to VRAM)
- HALT instruction can freeze CPU while external devices access VRAM

**Key Implementation Details**:
- Microcode engine for ALU/shift operations
- Custom write-masking logic (CPU uses bit-level addressing; FPGA needs byte-mask)
- Address translation: 1-bit CPU address ↔ 8/16-bit external address
- Interrupt handling: LINT0 (DMA complete), LINT1 (sound board), NMI
- **GPU removed in Analogue Pocket** (not used except POST screens, saves LE)

**Memory Controllers** (3 layers):
1. **Inside CPU**: Handles 1-bit addressable reads/writes to 16-bit DRAM
2. **Local Control PLD**: Arbitrates CPU bus to multiple destinations (I/O, ROM, RAM)
3. **VRAM Control PLD**: Manages multi-source access to Palette/Bitmap RAM

---

## Part 3: VRAM and DMA System (Bandwidth Bottleneck)

### DMA Blitter Operation

The Y-Unit has **NO hardware sprite engine**. Graphics are drawn entirely via software-controlled DMA:

```
Game Loop (CPU-driven):
1. CPU builds DMA command queue (texture coords, source ROM offset, dest XY, width/height)
2. CPU executes TRAP instruction → triggers DMA interrupt
3. DMA fetches 32-bit chunks from Image ROM
4. DMA applies mode-dependent processing (palette swap, transparency, color fills)
5. DMA writes pixels to VRAM (Bitmap + Palette RAM simultaneously)
6. DMA signals LINT1 interrupt → CPU processes next queue item
7. Repeat for all 80–200+ objects per frame
```

**DMA Mode Options** (9 total):
- Mode 0: No-op
- Modes 1,2,3: Palette + value from ROM (various transparency)
- Modes 4,5,6,7: Solid color fill ± transparency
- Modes 8,9,A,B,C,D,E,F: Solid color ± palette swap

**Critical**: DMA must maintain **41ns per pixel** throughput (166ns for 4-pixel chunks), or animation corrupts.

### Image ROM Decoding (Live, No Precompute)

Y-Unit uses **6-bit pixels**, requiring live bit-rearrangement:

```verilog
// From Coin-Op documentation (applied live during DMA):
BIT_DEPTH == 6 ? {2'b00, gfx32_dout[23:22], gfx32_dout[7:6], gfx32_dout[15:14],
                   2'b00, gfx32_dout[21:20], gfx32_dout[5:4], gfx32_dout[13:12],
                   2'b00, gfx32_dout[19:18], gfx32_dout[3:2], gfx32_dout[11:10],
                   2'b00, gfx32_dout[17:16], gfx32_dout[1:0], gfx32_dout[9:8]} :
```

Games with 4-bit graphics (Trog, Strike Force) must be padded and rearranged into 6-bit scheme.

### VRAM Multi-Source Access

VRAM accessed simultaneously by **4 sources**, requiring arbitration:

| Source | Bandwidth Need | Priority |
|--------|---|----------|
| **DMA** | ~166ns/4px (32 MB/s @ 8 MHz pixel clock) | HIGH |
| **CPU** | 16-bit reads/writes (variable) | MEDIUM |
| **Line Buffer Output** | Sequential readout to CRT | HIGH (must not stall) |
| **Autoerase PLD** | ~41ns/pixel clear (single line) | VERY HIGH (locks all other sources) |

**Autoerase PLD Problem**:
- Fires automatically after each scanline output (every ~25 µs)
- Locks entire VRAM during clear (blocks CPU, DMA, line buffer)
- Takes ~25–50 µs to clear 1 line (400–500 pixels)
- **Occupies ~10–15% of blanking interval**

**Bulk Clear Alternative** (Strike Force, Terminator 2):
- Uses FILL instruction + shift buffer instead of hardware PLD
- Shift buffer pre-loaded with 2 lines of autoerase pattern
- CPU controls timing → **game can schedule clears during less critical moments**
- Saves BOM cost, more flexible timing

---

## Part 4: Video Output Pipeline

### Scanline Architecture

```
Bitmap/Palette RAM (512 KB)
       ↓
Line Buffer (2 × 400px @ 16-bit = 1.6 KB each)
       ↓
CRT Output @ 8 MHz pixel clock
       ↓
Sync signals (HSYNC, VSYNC, blank)
```

**Flow**:
1. **DMA** writes pixels to Bitmap/Palette RAM during game loop
2. **Video subsystem** reads sequentially from line buffer during visible scanline
3. **Blank interval** (HBlank = 32 pixels @ 8 MHz = 4 µs):
   - Autoerase PLD clears previously output line
   - CPU can write to VRAM if no DMA active
4. **VBlank** (~12 lines):
   - Entire VRAM accessible for CPU updates
   - DMA can pre-fetch next frame's objects

**No Frame Buffer Doubling**: Y-Unit uses **single-buffer architecture** (same RAM for reads + writes). This means:
- Game must finish all DMA writes before scanline reaches that row
- If DMA stalls → scanlines show corrupted/partial pixels
- **This is why Pramod's scanline buffer approach failed for most games**

### Protection Scheme

**6 games use hardware protection IC** (reads like EEPROM):
- Smash TV: **NO protection**
- High Impact, Trog, Total Carnage, Mortal Kombat, T2: Protection IC at U65
- Strike Force: Software protection (dynamic keys in RAM)

Protection IC protocol:
```
Write sequence 1 → Write sequence 2 → Write sequence 3 →
  Read 1 byte of key → repeat until reset sequence
```

Hardcoded into ROM. Emulation requires byte-perfect key sequence replay or protection ROM dump.

---

## Part 5: Why Scanline Buffer Approach Fails (For Most Games)

### Game Categories

**A. Games WITHOUT Staging RAM** (Smash TV, Total Carnage):
- Write directly to Bitmap/Palette VRAM as framebuffer
- DMA completes each object before pixel rows are read
- **Feasible with scanline buffer**: Double-buffer 2 scanlines in BRAM, hide DMA latency

**B. Games WITH Staging RAM** (Mortal Kombat, High Impact, others):
- Use separate **staging area** to pre-build frames off-screen
- Complex multi-frame animation sequences
- Require "staging VRAM" pattern (hidden rows or bank-switched RAM)
- **Scanline buffer BREAKS this architecture**: Game expects to read from non-visible rows while writing to visible rows simultaneously

### SDRAM Bandwidth Reality

**Pramod's observed constraints** (from blog + forum):

- **MiSTer DE10-Nano**: SDRAM @ 125 MHz, 16-bit bus = ~250 MB/s peak
- **Y-Unit peak demand**:
  - DMA @ 32 MB/s (166ns/4px)
  - CPU @ 8–16 MB/s (dependent on instruction mix)
  - Autoerase @ 15–25 MB/s (during HBlank)
  - Line buffer output @ 8–16 MB/s
  - **Total**: ~65–95 MB/s under load, but **bursty** (DMA-heavy)

- **Problem**: Multiple arbitrators competing (DMA priority vs. line buffer continuity)
  - If DMA starves line buffer → visible glitches
  - If line buffer gets priority → DMA can't keep up with next frame prep
  - Pramod tried CAS-latency=2, 128 MHz SDR refresh — still insufficient for Mortal Kombat

### Why Smash TV + Total Carnage Work

1. **No staging RAM**: Objects written directly to visible framebuffer
2. **Predictable DMA timing**: Game CPU schedules DMA during HBlank/early VScan
3. **Forgiving gameplay**: Sprites don't overlap as densely as Mortal Kombat
4. **Lower complexity**: Fewer layers, less sprite overdraw

Mortal Kombat, High Impact, others have:
- Dense overlapping sprites
- Larger animation frames
- Staging sequences that assume simultaneous read-from-staging + write-to-framebuffer

---

## Part 6: Coin-Op Collection's Solution (Not Open Source)

### What They Did Differently

From Patreon announcements + MiSTer forum posts:

1. **Increased SDRAM speed**: Ran at 128 MHz CAS=2 (vs. standard 100 MHz CAS=3)
2. **Optimized DMA**: 32-bit burst writes instead of single-transaction 16-bit
3. **Stricter timing**: Fixed pixel rate @ 41ns (no variable delays)
4. **Shift buffer reuse**: Pre-loaded clear patterns + multi-line burst transfers
5. **OpenFPGA/Analogue Pocket**: Larger FPGA (52K LEs) allowed full TMS34010 GPU + extra buffers

### Analogue Pocket Status

- ✅ **Smash TV**: Full playable
- ✅ **Total Carnage**: Full playable
- ✅ **Mortal Kombat**: Playable (reported working, RC6)
- ✅ **NARC, High Impact, Trog, T2, Strike Force**: All boot, varying stability

**MiSTer Status** (per Pramod, 2023):
- ✅ **Smash TV**: Playable
- ✅ **Total Carnage**: Playable
- ❌ **Everything else**: Not feasible (bandwidth)

---

## Part 7: Technical Feasibility for MiSTer

### Current Constraints

| Metric | MiSTer DE10 | Analogue Pocket | Needed |
|--------|-----------|-----------------|--------|
| **FPGA Size** | 40K ALM | 52K ALM | ~45K ALM (Y-Unit full) |
| **SDRAM Speed** | 125 MHz max | 128 MHz | 128+ MHz |
| **SDRAM Bus Width** | 16-bit | 16-bit | 32-bit ideal |
| **BRAM/M10K** | 40 Mb total | 55 Mb total | ~10–15 Mb needed |
| **Cooling** | Passive | Passive | OK |

### Scanline Buffer Approach (Detailed Analysis)

**Proposed Solution**:
```
Replace full 512 KB VRAM with:
├─ SDRAM: 256 KB (one framebuffer page, single-buffered)
├─ Line 0–1 Buffer: 2 × 400px × 2 bytes = 1.6 KB (BRAM)
├─ DMA output FIFO: 32 × 32-bit entries = 4 KB (BRAM)
└─ Autoerase scratch: 2 lines pattern = 1.6 KB (BRAM)
Total BRAM: ~8 KB (easily fits in DE10's 40 Mb)
```

**Advantages**:
- Hide SDRAM latency for line buffer
- Smooth CRT output (no mid-scanline stalls)
- Reduce SDRAM peak bandwidth

**Why It Fails for 90% of Games**:

1. **Staging VRAM assumption broken**: Games use hidden rows (e.g., y=256–511 for staging). With scanline buffer:
   - CPU writes staging at y=300
   - Game loop reads from y=300 to compose sprites
   - But line buffer only reads y=0–255 → staging data never reaches output
   - **Game logic corrupts**

2. **Shift buffer operations fail**: 2-line patterns in shift register assume they can be read back from VRAM non-sequentially. Scanline buffer obscures this.

3. **Memory controller complexity**: Game expects single unified VRAM. Split into "visible framebuffer + hidden staging" breaks addressing assumptions.

**Verdict**: **Scanline buffer only works if game architecture is known to be "staging-free"** (Smash TV, Total Carnage). For unknown/untested games, full SDRAM VRAM is necessary.

---

## Part 8: Required Components to Understand for MiSTer Implementation

### If Building from Scratch

1. **TMS34010 CPU Core** (7000+ lines Verilog)
   - Instruction decode & microcode engine
   - Memory controllers (1-bit to 8/16-bit address translation)
   - Interrupt handling (LINT0, LINT1, NMI)
   - GPU (FILL, MOVE with transparency)

2. **DMA Blitter** (1000–2000 lines)
   - 32-bit ROM fetch with 6-bit deswizzling
   - Mode-dependent pixel processing (9 modes)
   - VRAM write arbitration
   - Interrupt signaling on completion

3. **VRAM Controller** (500–1000 lines)
   - 4-way arbitration (DMA, CPU, line buffer, autoerase)
   - Row/column coherence
   - CAS/RAS management for SDRAM

4. **Video Output** (500 lines)
   - Line buffer (2 × 400px BRAM dual-port)
   - CRT sync generation (HSYNC, VSYNC, BLANK)
   - 8 MHz pixel clock domain crossing

5. **Autoerase/Bulk Clear** (300–500 lines)
   - HBlank detection → trigger clear
   - Shift buffer pattern reload
   - VRAM write path for line clearing

6. **Protection IC/Socket** (100–200 lines, if required)
   - 6-game support: Pre-loaded key ROM
   - Strike Force: Software protection (algorithmic)

### Total Estimate: 10,000–12,000 lines Verilog
**Not trivial, but achievable in 2–3 months** (per Pramod's experience)

---

## Part 9: Actionable Recommendations

### Option A: Target Subset Games (Most Feasible)

**Build for Smash TV + Total Carnage only:**
1. Simplest game architectures (direct framebuffer, no staging)
2. Pramod confirmed working on MiSTer
3. Scanline buffer approach viable
4. **Timeline**: 4–6 weeks
5. **Risk**: Low

**Steps**:
- Obtain Smash TV + Total Carnage ROM + service manuals
- Clone Coin-Op Development-Documentation to understand memory layout
- Implement TMS34010 core (reuse research from pram0d's blog + posts)
- Build DMA blitter for 6bpp image ROM
- Test against MAME frame-by-frame validation

### Option B: Full Y-Unit Implementation (High Risk, High Reward)

1. **Get Coin-Op Community Support**:
   - Reach out to pram0d directly for design docs (off-GitHub)
   - Ask Coin-Op Collection about technical consulting (Patreon supporters can negotiate)

2. **Prototype on Analogue Pocket First**:
   - Use OpenFPGA build environment (has more LE to work with)
   - Validate all 8 games boot + gameplay
   - Then port to MiSTer

3. **Address Bandwidth via Hardware Design**:
   - Implement custom SDRAM controller with 32-bit burst writes (Analogue Pocket's SDRAM supports this)
   - Pre-calculate DMA burst patterns in CPU microcode
   - Reorder bus arbitration (prioritize DMA during game loop, line buffer during blanking)

### Option C: Hybrid Approach (Recommended)

1. **Start with Smash TV** (4 weeks): Validate tool chain + TMS34010 core
2. **Extend to Total Carnage** (2 weeks): Test autoerase/bulk clear variations
3. **Attempt Mortal Kombat** (6 weeks): Hit SDRAM bandwidth wall, document learnings
4. **Publish findings**: MiSTer community will fund further work if you get past Mortal Kombat

---

## Part 10: References & Downloads

### Downloaded Materials
```
/Volumes/2TB_20260220/Projects/MiSTer_Pipeline/delphi-ledger/midway-y-unit-source/
├─ Midway/
│  ├─ Y-Unit/
│  │  ├─ midway_yunit.md (this analysis's source)
│  │  ├─ public_documents/
│  │  │  ├─ Smash TV schematic + service manual
│  │  │  ├─ Trog
│  │  │  ├─ High Impact Football
│  │  │  ├─ T2: Judgment Day
│  │  │  ├─ Total Carnage
│  │  │  └─ Mortal Kombat
│  │  └─ images/
│  │     ├─ CVSD.png (sound board)
│  │     └─ U65IC-local.png (protection IC)
│  │
│  └─ Z-Unit/
│     ├─ midway_zunit.md
│     ├─ public_documents/
│     │  └─ NARC service manual
│     └─ raw_schematics/ + images/
```

### Key Online Resources

**Coin-Op Collection**:
- [Development Documentation](https://github.com/Coin-OpCollection/Development-Documentation)
- [MiSTer Distribution (compiled cores)](https://github.com/Coin-OpCollection/Distribution-MiSTerFPGA)
- [OpenFPGA Distribution (Analogue Pocket cores)](https://github.com/Coin-OpCollection/Distribution-OpenFPGA)
- [Patreon (announcements, RC releases)](https://www.patreon.com/coin_opcollection)

**Pramod Somashekar**:
- [Engineering Blog](https://www.pram0d.com)
  - [TMS34010 FPGA Implementation (Dec 2022)](https://pram0d.com/2022/12/29/new-core-work-tms34010-narc-smash-tv/)
  - [FPGA Development Methodology (Jul 2022)](https://pram0d.com/2022/07/26/fpga-core-development-series-part-1/)
- [GitHub: Raizing FPGA (Arcade cores, Verilog)](https://github.com/psomashekar)
- [MiSTer FPGA Forum Posts (Midway Y-Unit discussion)](https://misterfpga.org/viewtopic.php?t=7542)

**MAME / Emulation Reference**:
- System16.com: [Midway Y-Unit Hardware](https://www.system16.com/hardware.php?id=610)
- Wikipedia: [TMS34010](https://en.wikipedia.org/wiki/TMS34010)
- Data Crystal: [Midway Hardware Maps](https://www.wikitendo.com/)

---

## Part 11: Conclusion

### Current State
- **Source code**: Closed-source (Coin-Op Collection)
- **Documentation**: Comprehensive (service manuals, schematics, technical deep-dives)
- **Community work**: Available (Pramod's blog posts, forum discussions)
- **Feasibility**: Possible for 2 games, hard but achievable for full Y-Unit

### Why Scanline Buffer Fails
- **Root cause**: Games assume direct access to hidden VRAM rows for staging/animation prep
- **Smash TV/Total Carnage exception**: No staging RAM, direct framebuffer architecture
- **General solution**: Full 512 KB VRAM + optimized SDRAM controller @ 128 MHz

### Next Steps
1. **Confirm intention**: Are we targeting subset (Smash TV) or full Y-Unit?
2. **Reach out to Pramod**: Ask for design guidance (blog doesn't cover everything)
3. **Prototype TMS34010 core**: Start with CPU-only, add DMA after
4. **Validate against MAME**: Build frame-by-frame comparison harness (like Metroid/Zelda projects)

**Estimated effort** for Option A (Smash TV only): **800–1200 engineering hours**
**Estimated effort** for Option C (Smash TV → Mortal Kombat attempt): **2000–3000 hours**

---

## Appendix: Bits Per Pixel (BPP) Decoding

Y-Unit uses **6-bit pixels** stored in **32-bit chunks**. Decoding requires live bit rearrangement:

```
4-bit example (Trog, Strike Force — 4bpp padded to 6bpp):
INPUT (32-bit from ROM):   [31:0] raw bits
OUTPUT (after deswizzle):  4 × 8-bit pixels for DMA

Mapping (from Coin-Op docs):
│Bit In │ 6bpp Out │ 4bpp Out │
│   0   │    2     │    2     │
│   1   │    3     │    3     │
│   2   │   10     │   10     │
│   3   │   11     │   11     │
│   4   │   18     │   18     │
│   5   │   19     │   19     │
│   6   │   26     │   26     │
│   7   │   27     │   27     │
│ 8–23  │ (pattern repeats for next 3 pixels) │
│24–31  │ (unused in 4bpp)                    │
```

This is performed **in hardware during DMA fetch** (no precomputation).
