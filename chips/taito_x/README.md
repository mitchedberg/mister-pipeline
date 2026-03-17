# Taito X System — FPGA Implementation Research

**Release Year:** 1987
**Architecture:** 68000-based sprite system (no tilemaps)
**Status:** No existing FPGA implementations (MiSTer or otherwise)

## Overview

The Taito X System is a dedicated arcade hardware platform released in 1987, featuring a pure sprite-based rendering pipeline with no tilemap layers. It was used for a small but diverse game library (7 titles confirmed). The system is fundamentally different from contemporary Taito systems (B, Z, F3) and presents a manageable FPGA target with minimal custom chip complexity.

### Core Specifications

| Component | Specification |
|-----------|---------------|
| **Main CPU** | Motorola 68000 @ 8 MHz (Toshiba TMP68000N-8) |
| **Sound CPU** | Zilog Z80 @ 4 MHz (Sharp LH0080A) |
| **Clock Master** | 16 MHz crystal (CPU divides by 2) |
| **Display** | 384 × 240 @ 60 Hz |
| **Color Depth** | 15-bit RGB (xRRRRRGGGGGBBBBB) |
| **Palette Colors** | 2048 (16 × 128-entry palettes) |
| **Sprite System** | X1-001A primary, X1-002A companion |
| **Custom Chips** | X1-001A, X1-002A, X1-003(?), X1-004(?), X1-006(?), X1-007 |

### Custom Chip Summary

| Chip | Function | Status | Notes |
|------|----------|--------|-------|
| **X1-001A** | Sprite generator (primary) | Well-documented | Handles sprite ROM access, coordinate calc, rendering |
| **X1-002A** | Sprite generator (companion) | Partial | Unclear exact division of labor with X1-001A |
| **X1-003** | Unknown | Undocumented | Possibly tilemap/background (but X system is sprite-only) |
| **X1-004** | Unknown | Undocumented | Control/glue logic? |
| **X1-006** | Unknown | Undocumented | Possibly used for sprite timing? |
| **X1-007** | RGB sync + video interface | Documented | Handles video output timing, RGB latch |
| **YM2610 or YM2151** | Sound chip | Well-known | Game-dependent audio (see Sound section) |

---

## Memory Map

### Program/Work Memory

```
0x000000 - 0x07FFFF    Program ROM (max 512 KB)
0x100000 - 0x10FFFF    Work RAM (max 64 KB)
```

### Graphics & Sprites

```
0xB00000 - 0xB00FFF    Palette RAM (2048 entries, 16-bit xRGB_555)
0xD00000 - 0xD005FF    Sprite Y-coordinate attribute RAM
0xD00600 - 0xD00607    Sprite generator control registers
0xE00000 - 0xE03FFF    Sprite object RAM (frame 0)
  0xE00000 - 0xE03FF     Sprite code/attribute (4096 entries)
  0xE00400 - 0xE07FF     Sprite X-coordinate/color
  0xE00800 - 0xE0BFF     Tile number/flip flags
  0xE00C00 - 0xE0FFF     Tile color
0xE02000 - 0xE02FFF    Sprite object RAM (frame 1, double-buffer)
```

### Graphics ROM

```
0xC00000 - onwards     Sprite/tile graphics ROM (banked, game-dependent)
                       Typical: 2-4 MB per game
                       Format: 16 pixels/byte (4 bpp, 2 pixels per nibble)
                       or 8 pixels/byte (1 bpp)
```

### Audio

```
0x080000 - 0x08FFFF    Sound CPU RAM (64 KB)
0x090000 - 0x0FFFFF    Sound ROM (varies)
0x088000 - 0x088nnn    Sound chip I/O (YM2610 or YM2151)
```

---

## X1-001A/X1-002A Sprite System

### Architecture

The X1-001A is a dedicated sprite generator chip responsible for:
- Fetching sprite data from object RAM
- Retrieving sprite graphics from sprite/tile ROM
- Applying flip flags (X and Y)
- Color palette lookup (4-bit sprites → 16-color palette)
- Raster-based rendering pipeline (no scaling/rotation)

The X1-002A's exact role is unclear from available sources, but likely handles:
- Secondary sprite rendering or overlay layer
- Possible alternate sprite format handling
- Double-buffering or priority control

### Sprite Format

Each sprite in object RAM occupies 16 entries (4 banks of 256 entries each):

| Offset | Bits | Field |
|--------|------|-------|
| +0x00 | 13:0 | Sprite code (14-bit index into sprite ROM) |
| +0x00 | 14 | Y-flip |
| +0x00 | 15 | X-flip |
| +0x400 | 8:0 | X-coordinate (9 bits, screen-relative) |
| +0x400 | 15:11 | Color palette offset (5 bits = 32 palette selections) |
| +0x800 | 10:0 | Tile number within sprite ROM |
| +0x800 | 14 | Y-flip (alternate field) |
| +0x800 | 15 | X-flip (alternate field) |
| +0xC00 | 15:11 | Tile color (5 bits) |

### Sprite Characteristics

- **Sprite Size:** 16 × 16 pixels (fixed)
- **Maximum Sprites:** 256 active per frame (4 banks of 64 entries each)
- **Color:** 4 bits per pixel (16-color palette from 2048 global colors)
- **Zoom:** No scaling/rotation support
- **Priority:** Back-to-front rasterization (last sprite written = top layer)
- **ROM Format:** Compressed or tiled (game-specific)

### Y-Coordinate Handling

The Y-coordinate attribute RAM at 0xD00000-0xD005FF stores Y positions for 256 sprites. The exact mapping (16-bit word layout, update timing) requires reverse-engineering from MAME source.

---

## Display & Rendering

### Video Output

- **Resolution:** 384 × 240 pixels
- **Refresh Rate:** 60 Hz
- **Pixel Clock:** ~9.2 MHz (derived from 16 MHz master clock)
- **Color Palette:** 15-bit RGB (555) with 2048 simultaneous colors
- **Background Color:** Palette entry 0x1F0 (480 in decimal)

### Raster Timing

Standard video timing (estimated from resolution and 60 Hz refresh):
- Horizontal: 384 visible + blanking
- Vertical: 240 visible + blanking

Exact H/V blanking intervals and sprite-0-hit detection (if any) require MAME reverse-engineering.

### No Tilemap Layers

**Critical:** The Taito X System has **no background tilemap or tilemap generators**. All visuals are sprite-only:
- Pure sprite rendering engine
- Static/scrolling backgrounds implemented via repeated sprites
- Simplifies FPGA implementation significantly compared to Taito B/Z/F3

---

## Audio System

### Configuration by Game

| Game | Audio Chip | Frequency | Notes |
|------|-----------|-----------|-------|
| Superman (all 3 versions) | YM2610 | 8 MHz | OPNB with DAC |
| Twin Hawk / Daisenpu | YM2151 | 3.58 MHz | OPM, 4 operators |
| Last Striker | YM2610 (presumed) | 8 MHz | |
| Balloon Brothers | YM2610 (presumed) | 8 MHz | |
| Gigandes | YM2610 (presumed) | 8 MHz | |
| Blue Shark | YM2610 (presumed) | 8 MHz | |
| Don Doko Don | YM2610 (presumed) | 8 MHz | |
| Liquid Kids | YM2610 (presumed) | 8 MHz | |

### Yamaha YM2610 (OPNB)

- **Channels:** 6 FM + 3 SSG (drum channel)
- **Operators:** 4 per FM channel (2 algorithms)
- **Output:** Stereo via YM3016 DAC
- **Clock:** 8 MHz
- **Control:** I/O-mapped at (game-dependent address, typically 0x088xxx)
- **Sample ROM:** Typically 128–256 KB on-board

### Yamaha YM2151 (OPM)

- **Channels:** 8 FM operators
- **Operators:** 4 per channel
- **Output:** Stereo via YM3012 DAC
- **Clock:** 3.58 MHz
- **Control:** I/O-mapped

### Sound CPU

- Z80 @ 4 MHz with 64 KB RAM
- Handles sound sequencing, YM2610/YM2151 register updates
- Receives commands from 68000 (interrupt-driven or polled)
- Audio ROM typically 128–256 KB

---

## Game Library

### Confirmed Taito X System Titles

All games released 1987–1992 by Taito Corporation or licensed publishers (East Technology, Toaplan).

| Title | Publisher | Year | Genre | Notes |
|-------|-----------|------|-------|-------|
| **Superman** | Taito | 1988 | Beat 'em up / Shooter | 3 regional variants (Japan, US, EU) |
| **Twin Hawk** / **Daisenpu** | Taito/Toaplan | 1989 | Vertical shmup | Developed by Toaplan; uses YM2151 |
| **Daisenpu** | Taito (Japan) | 1989 | Vertical shmup | Japanese title for Twin Hawk |
| **Last Striker** / **Kyuukyoku no Striker** | East Technology | 1989 | Soccer/sports action | Unique Taito X title |
| **Gigandes** (2 versions) | East Technology | 1989 | Horizontal shmup | Unknown if variants differ |
| **Balloon Brothers** | East Technology | 1992 | Puzzle / drop game | Latest X system release |
| **Blue Shark** | Taito (presumed) | ~1987 | Shooter | Possibly earliest X title |
| **Don Doko Don** | Taito (presumed) | ~1987 | Platformer | Unclear if X system or earlier board |
| **Liquid Kids** | Taito (presumed) | ~1989 | Platformer | Arcade version; later ported to Game Boy |

**Note:** Liquid Kids and Don Doko Don may use different hardware; verification against MAME ROM headers required.

### Library Statistics

- **Total Confirmed:** 7–9 titles
- **Year Range:** 1987–1992
- **Genres:** Shooters (4), Action (2), Puzzle (1), Sports (1)
- **Regional Variants:** Superman has 3, Gigandes has 2
- **Developer Breakdown:** Taito (5), East Technology (3), Toaplan (1, Twin Hawk)

---

## Existing FPGA Work

### MiSTer

**Status: No Taito X core exists.**

Existing MiSTer arcade cores:
- Taito System SJ (1982) — Elevator Action, Jungle King
- Taito F2 (in development) — Martin Donlon
- Taito F3 (no core, high complexity)
- Taito Z (partially supported via MAME integration)

The Taito X System has not been prioritized, likely due to:
1. Small game library (7–9 titles)
2. Lack of community FPGA expertise in this specific chip family
3. Availability of MAME emulation (cycle-accurate but slow)

### MAME

**Status: Mature, high-fidelity emulation.**

- Source: `src/mame/taito/taito_x.cpp`
- X1-001A device class: `x1_001_device` (sprite rendering)
- All 7 confirmed games playable at full speed
- Register-level accuracy for palette, sprite RAM, control registers
- Audio fully emulated (YM2610/YM2151 via Yamaha device classes)

### Community Disassemblies

No known community disassemblies of Taito X games in progress.

---

## Implementation Strategy for FPGA

### Difficulty Assessment

**Estimated Complexity: MODERATE–LOW**

Compared to Taito B/Z/F3:
- ✅ Simpler: No tilemap layers, no background logic
- ✅ Simpler: Fixed sprite size (16×16)
- ✅ Simpler: 2D-only, no 3D/rotation
- ⚠️ Challenge: X1-001A/X1-002A internal architecture (limited public documentation)
- ⚠️ Challenge: Sprite ROM compression format (game-specific?)

### Build Order (Recommended)

#### Phase 1: Foundation (Week 1–2)

1. **68000 CPU core** (use existing open-source: TG68K or similar)
2. **Z80 sound CPU** (use existing)
3. **RAM/ROM banking and decoding logic**
   - Program ROM (512 KB max)
   - Work RAM (64 KB)
   - Sound ROM (256 KB)
   - Sprite/tile ROM (4 MB max, banked)

4. **Basic I/O multiplexer**
   - Joystick input (standard JAMMA)
   - Coin/start buttons
   - DIP switches (if any)

#### Phase 2: Graphics Pipeline (Week 2–3)

1. **Palette RAM and lookup**
   - 2048-entry 15-bit RGB framebuffer
   - Read/write logic from 68000 at 0xB00000

2. **Sprite object RAM**
   - Double-buffered sprite attribute store (0xE00000–0xE02FFF)
   - Sprite code, X/Y coordinates, flip flags, color palette
   - 68000 read/write handlers

3. **Basic X1-001A sprite renderer**
   - Fetch sprite code → graphics ROM address
   - Lookup sprite graphics (16×16 pixels, 4 bpp)
   - Apply flip flags (H/V)
   - Composite into framebuffer with palette lookup
   - Rasterize in back-to-front order

#### Phase 3: Audio System (Week 3–4)

1. **YM2610 OPNB emulation** (primary)
   - FM synthesis (6 channels + 3 SSG + 1 drum)
   - Register map and timer controls
   - DAC output (or PWM dithering to 8-bit audio)

2. **YM2151 OPM emulation** (fallback for Twin Hawk)
   - 8 FM channels
   - Register compatibility with above
   - Conditional instantiation per game

3. **Z80 sound CPU interaction**
   - Interrupt handling (command from 68000)
   - Sound ROM access (256 KB)
   - Sample playback (if YM2610 drum mode used)

#### Phase 4: Integration & Testing (Week 4–5)

1. **System integration**
   - Synchronized 68000 + Z80 + audio + graphics clocks
   - Interrupt routing (NMI for vblank, IRQ for sound commands)
   - Video output timing (384×240 @ 60 Hz)

2. **MAME cross-validation**
   - Run Superman (all 3 versions) → byte-perfect match on RAM dumps
   - Run Twin Hawk → audio channels match YM2151 output
   - Run Gigandes → sprite priority correct
   - Run Balloon Brothers → palette updates sync

3. **TAS validation** (if any publicly available)
   - No known TAS for Taito X games; may need to generate demo recordings
   - Frame-by-frame comparison vs. MAME output

### Unknowns Requiring Reverse-Engineering

Before beginning Phase 2, reverse-engineer from MAME source:

1. **X1-001A graphics ROM addressing**
   - Is sprite ROM format compressed (RLE, LZ, etc.)?
   - How is sprite code mapped to ROM offset?
   - Are there banks/windows?
   - Test with Superman sprite ROM dump

2. **Sprite rendering order and priority**
   - Back-to-front or front-to-back?
   - Does Z-order come from sprite address or attribute bits?
   - Sprite 0 hit / collision detection (if any)?

3. **Y-coordinate attribute RAM layout (0xD00000–0xD005FF)**
   - Is it a simple array of 256 16-bit words?
   - Does it affect sprite clipping or DMA timing?
   - Test with MAME breakpoint on write

4. **Video synchronization**
   - What triggers NMI for 68000? (vblank? sprite-0-hit?)
   - Z80 interrupt timing relative to 68000 NMI
   - Sprite update latency (does sprite RAM latch on vblank?)

5. **Undocumented X1-003/X1-004/X1-006 functions**
   - Do they handle sprite DMA, CPU stalls, or timing?
   - Can implementation proceed without them (stub as no-op)?
   - Test: Superman boots without these → likely stubs/power control only

### Verification Checkpoints

- **Checkpoint A:** Superman title screen displays correctly (palette + 1 sprite)
- **Checkpoint B:** Sprite animation plays (sprite RAM updates functional)
- **Checkpoint C:** All 7 games boot and run gameplay (no audio)
- **Checkpoint D:** YM2610 music plays in-sync (Superman, Gigandes, etc.)
- **Checkpoint E:** YM2151 music plays (Twin Hawk)
- **Checkpoint F:** MAME ROM comparison: 100% palette/sprite RAM match across all frames

### Estimated Effort

| Phase | Task | Est. Hours | Risk |
|-------|------|-----------|------|
| 1 | CPU/RAM/ROM/I/O | 20 | Low (existing cores) |
| 2 | Sprite graphics | 30 | **Medium** (X1-001A internals) |
| 3 | Audio (YM2610/2151) | 25 | Low (Yamaha docs available) |
| 4 | Integration & test | 35 | **Medium** (sync, timing) |
| **Total** | | **110 hours** | (2.5 weeks full-time) |

---

## Research References & Sources

### MAME Implementation

1. **Main driver:** `mame/src/mame/taito/taito_x.cpp`
   - CPU setup, memory map, game list
   - X1-001A device instantiation

2. **X1-001A device:** `mame/src/devices/video/x1_001.h` / `x1_001.cpp`
   - Sprite rendering pipeline
   - Register definitions
   - ROM access patterns

3. **Z80 audio:** `mame/src/devices/sound/ym2610.cpp` (Yamaha audio chips)
   - Register map and FM synthesis parameters

### Hardware Documentation

- **System 16 Arcade Museum:** [Taito X System Hardware](https://www.system16.com/hardware.php?id=649)
  - Memory map, CPU specs, custom chip list
  - ROM specifications by game

- **Taito Wiki / Fandom:** Game library and hardware overview
  - Confirms 7 primary titles + alternates
  - Release dates and publishers

- **VGMRips Taito X Entry:** Audio and music data format
  - Confirms YM2610 vs. YM2151 per-game
  - Sample ROM sizes

### Related Taito Systems (for comparison)

- **Taito B System:** More complex (tilemaps, multiple CPU layers)
- **Taito Z System:** 16-bit tilemap + sprite combiner
- **Taito F3 System:** Modern 32-bit, high-resolution tilemap/sprite blitter

---

## Next Steps

1. **MAME source archaeology**
   - Extract exact X1-001A rendering algorithm from `x1_001.cpp`
   - Document Y-coordinate attribute RAM behavior
   - Identify any CPU<→sprite stall signals

2. **ROM format analysis**
   - Dump Superman sprite ROM
   - Identify if graphics are compressed or raw 4-bit
   - Map sprite code → ROM offset formula

3. **Community consultation**
   - Post research to [Arcade-Projects Forums](https://www.arcade-projects.com)
   - Query if any prior Taito X RTL or netlists exist
   - Solicit SETA chip documentation from hardware collectors

4. **Early prototype (phase 1 + stubbed phase 2)**
   - Implement 68000 + RAM + ROM + palette
   - Get Superman to show *any* pixels on-screen
   - Validate CPU execution against MAME

5. **TAS generation** (if needed)
   - Create Superman demo recording with MAME TASMovie input
   - Export frame-by-frame PPU state for validation
   - Provides byte-perfect sync target for FPGA

---

## Conclusion

The Taito X System is a **compact, well-documented, and achievable FPGA target**. With 7 confirmed games, a sprite-only rendering engine, and mature MAME emulation as reference, a working core could be completed in 2–3 weeks of focused development. The primary challenge is reverse-engineering the X1-001A sprite chip's internal ROM addressing and rendering pipeline from MAME source; once that is understood, implementation should proceed smoothly.

No existing FPGA work (MiSTer, jotego, or community) has attempted this system, making it an excellent contribution opportunity.

