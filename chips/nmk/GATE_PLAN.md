# NMK16 — FPGA Implementation Gate Plan

**Date**: March 17, 2026
**Status**: PLANNING
**Target Games**: Truxton, Blazing Lazers, Gunhed, Cyber Lip, N-Ranger, Mustang
**MAME Reference**: `nmk16.cpp`, `nmk004.cpp`, `nmk214.cpp`
**Est. Development Time**: 50–80 days
**Difficulty**: MEDIUM-LOW

---

## Executive Summary

The NMK16 is a straightforward arcade graphics subsystem used in early-1990s action games and shoot-em-ups. Unlike competitors (Psikyo's 4 custom chips, Kaneko's 7 custom ICs), NMK16 uses **no proprietary graphics ICs** — all rendering is handled through standard ROM-based tile and sprite blitting to SRAM buffers, similar to classic arcade designs. The system pairs a **Motorola 68000 @ 10–12 MHz** CPU with a **Z80 @ 3.58 MHz** sound processor. Video output is standard **320×224 pixels with palette-based coloring**. Key games include **Truxton** (legendary vertical shmup), **Blazing Lazers**, and **Gunhed**, making NMK16 a high-quality arcade target with minimal custom silicon complexity.

---

## Gate 1 Spec: CPU Interface

### 1.1 Memory Map (68000 Perspective)

```
$000000–$03FFFF   Program ROM (256 KB)
$040000–$07FFFF   [Expansion / Banked ROM per game]
$080000–$0FFFFF   [Unused / Reserved]

$100000–$10FFFF   Work RAM (64 KB, 6264 or 62256 SRAM)
$110000–$11FFFF   [Unused / Mirrored or I/O]

$120000–$12FFFF   Graphics Control / Tile Attributes
$130000–$13FFFF   Sprite RAM (256 sprites × 4 words = 1 KB used, 4 KB allocated)
$140000–$14FFFF   Palette RAM (512 colors × 2 bytes = 1 KB, mirrored)
$150000–$15FFFF   [I/O Control / NMK214 Protection / Dip Switches / Coin Counters]

$160000–$1FFFFF   [Unused / Reserved]

[Cartridge variants may map sound ROM, CHR ROM addresses; verify per game]
```

**CRITICAL**: NMK004 and NMK214 boards may have custom chip addressing; consult MAME driver for exact variant.

### 1.2 Register Map (Graphics Control @ $120000–$12FFFF)

All registers are **16-bit word-aligned**. Byte accesses should be trapped or handled with duplication.

| Address | Name | Bits | Function | R/W |
|---------|------|------|----------|-----|
| $120000 | SCROLL0_X | [15:0] | Background layer 0 horizontal scroll | RW |
| $120002 | SCROLL0_Y | [15:0] | Background layer 0 vertical scroll | RW |
| $120004 | SCROLL1_X | [15:0] | Background layer 1 horizontal scroll (if enabled) | RW |
| $120006 | SCROLL1_Y | [15:0] | Background layer 1 vertical scroll (if enabled) | RW |
| $120008 | BG_CTRL | [15:0] | Background layer enable / priority | RW |
| $12000A | SPRITE_CTRL | [15:0] | Sprite enable, priority mode, flip flags | RW |
| $12000C | [Reserved] | — | — | — |
| $12000E | [Reserved] | — | — | — |
| $120010 | STATUS | [15:0] | Video interrupt status / acknowledge | RO |
| $120012 | [Reserved] | — | — | — |
| ... | [Repeats / Mirrored] | — | — | — |

### 1.3 Bit Field Definitions

#### BG_CTRL ($120008)
```
[15:12]  Layer 1 Mode (if applicable)
[11:8]   Layer 0 Mode (0=off, 1=256px, 2=512px, 3=1024px, etc.)
[7:4]    Sprite priority (vs BG layer 0/1)
[3:0]    Layer enable flags (bit 0=BG0, bit 1=BG1, etc.)
```

#### SPRITE_CTRL ($12000A)
```
[15:14]  Sprite size (0=8px, 1=16px, 2=32px, 3=variable per entry)
[13:12]  Reserved
[11:8]   Sprite priority mode (0=always under BG, 1=pen-based, 2=always over, 3=mixed)
[7:4]    Sprite flip flags (bit 7=flip X, bit 6=flip Y, bits 5–4=rotate)
[3:0]    Sprite enable / count (0=off, 1–15=number of active sprites)
```

#### STATUS ($120010)
```
[7]      VBLANK interrupt flag
[6]      Sprite list done flag
[5:0]    Reserved / Debug
```

### 1.4 CPU Interface Timing

- **68000 Clock**: 10–12 MHz (game-dependent; Truxton is 10 MHz, Gunhed is 12 MHz)
- **Bus Width**: 16-bit data, 24-bit address (32-bit capable address space)
- **ROM Access**: 2–3 wait states (ROM is slow mask ROM; CPU may have wait-state insertion)
- **Register Write**: Immediate; registers staged for next frame render
- **Register Read**: Synchronous; may return previous state during rendering

### 1.5 Test Vector Counts (Gate 1)

| Test | Vectors | Purpose |
|------|---------|---------|
| Address decode (RAM/ROM/IO) | 256 | Verify all address ranges route correctly |
| Register read/write | 64 | Test all 16 control registers for access |
| Byte vs. word access | 32 | Verify word-aligned access; trap byte access if required |
| Chip select timing | 16 | Validate CS_n assertion/deassertion |
| Wait-state insertion | 8 | Verify ROM access delays (if applicable) |
| **Total Gate 1** | **~400 vectors** | CPU interface validation |

---

## Gate 2 Spec: Sprite Scanner

### 2.1 Sprite RAM Layout

Each sprite entry occupies **4 words (8 bytes)** in Sprite RAM @ $130000–$130FFF:

```
Offset  Field                           Bits    Notes
────────────────────────────────────────────────────────
+0      X_POS                           [15:0]  X coordinate (16-bit signed, or 9-bit with 7-bit subpixel)
+2      Y_POS                           [15:0]  Y coordinate (16-bit signed, or 9-bit with 7-bit subpixel)
+4      TILE_INFO                       [15:0]  Tile index / ROM offset
+6      ATTR                            [15:0]  Flags, palette, priority, size

TILE_INFO ($130004 offset):
  [15:11] Bank select (if > 1 ROM bank)
  [10:0]  Tile index within bank (0–2047 per bank)

ATTR ($130006 offset):
  [15:14] Size override (0=8px, 1=16px, 2=32px, 3=variable)
  [13:12] Rotation/flip (00=none, 01=flipX, 10=flipY, 11=flipXY)
  [11:8]  Priority (0–15, lower = rendered first / under BGs)
  [7:4]   Palette selector (0–15, 16 palettes × 16 colors)
  [3:0]   Color key / transparency mode (0=opaque, 1–15=color key index)
```

### 2.2 Sprite Scanning Behavior

#### VBLANK Scanning (CPU idle, PPU active)
1. **VBLANK assertion** (line 224, falling edge of VSYNC)
2. **Sprite list parse** — hardware reads all 256 sprite entries from Sprite RAM
3. **Active sprite detection** — for each scanline (0–223):
   - Sprite Y_POS compared against current scanline ± sprite height
   - If match, sprite queued for **rasterizer** on that scanline
   - Max sprites per scanline: **16** (or higher; verify MAME `nmk16.cpp`)
4. **Rasterizer processes active sprites** during active video window
5. **Sprite list done IRQ** fired at end of VBLANK (optional; some games may ignore)

#### Active Video Rendering (scanlines 0–223)
- Sprite scanner **continues operation** during active video
- Sprite state cached in flip-flops; no mid-line updates
- Changes to Sprite RAM take effect **next frame** (shadowed registers)

### 2.3 Sprite Priority & Depth

Sprites are **sorted by priority field** (ATTR[11:8]):
- **Priority 0** = closest to viewer (rendered last, on top)
- **Priority 15** = farthest (rendered first, under backgrounds)
- **Ties**: Sprite list order (lower sprite ID = rendered first)

### 2.4 Test Vector Counts (Gate 2)

| Test | Vectors | Purpose |
|------|---------|---------|
| Sprite list parsing | 256 | Read all 256 sprites, verify data integrity |
| Y-coordinate matching | 64 | Match sprites to scanlines; test boundary conditions |
| Priority sorting | 32 | Verify sprites sorted by priority[11:8] |
| Multi-sprite per scanline | 16 | Test 16 sprites on one scanline; verify clipping |
| Sprite attribute updates | 32 | Shadowing; verify VBLANK synchronization |
| Edge cases (off-screen, negative coords) | 16 | Validate boundary clipping |
| **Total Gate 2** | **~500 vectors** | Sprite scanner validation |

---

## Gate 3 Spec: Tilemap Renderer

### 3.1 Tilemap Architecture

NMK16 typically supports **2 background layers** (Layer 0 = far, Layer 1 = near):

```
Layer 0 (Background):
  - 512×512 pixel tilemap (32×32 tiles, 16 px/tile)
  - Stored in **external ROM** (CHR ROM)
  - Tile indices in **Tilemap RAM** @ $120000 area (game-dependent)
  - Scroll registers: SCROLL0_X, SCROLL0_Y

Layer 1 (Foreground, optional):
  - 512×512 or 256×256 pixel tilemap
  - Tile indices in separate Tilemap RAM block
  - Scroll registers: SCROLL1_X, SCROLL1_Y
  - May be disabled per game (BG_CTRL[1])
```

### 3.2 Tile Structure

Each tile = **16×16 pixels** (standard for NMK16):

```
ROM Layout (per tile):
  ┌─────────────────────┐
  │ 16×16 pixels        │
  │ 2–4 bits per pixel  │
  │ (256–512 bytes)     │
  └─────────────────────┘

Tile index = offset into CHR ROM:
  ROM_addr = BASE_CHR + (tile_index * 512)
    (assuming 16×16 @ 4-bit, 512 bytes per tile)
```

### 3.3 Tilemap RAM Layout

```
Base Address (varies by game; consult MAME):
  Typical: $110000–$11FFFF (Work RAM region, or dedicated tilemap SRAM)

Layout:
  [Tilemap 0]: 32×32 × 16-bit indices = 2 KB
  [Tilemap 1]: 32×32 × 16-bit indices = 2 KB (if Layer 1 enabled)

Per-tile word:
  [15:12]  Palette selector (0–15)
  [11:10]  Flip (00=none, 01=flipX, 10=flipY, 11=both)
  [9:0]    Tile index (0–1023, or higher depending on CHR ROM size)
```

### 3.4 Scrolling Behavior

Scroll registers define **viewport offset** into tilemap:

```
SCROLL0_X ($120000):
  Pixel offset left edge of viewport within 512×512 tilemap
  Range: 0–511 (wraps)
  Updates apply next frame (shadowed)

SCROLL0_Y ($120002):
  Pixel offset top edge of viewport within 512×512 tilemap
  Range: 0–511 (wraps)
```

**Rendering**: For scanline Y (0–223):
```
Tilemap Y = (Y + SCROLL0_Y) % 512
Tile Y = (Tilemap Y / 16) % 32
Pixel in tile = Tilemap Y % 16
```

### 3.5 Per-Scanline Walker

Hardware **pipeline** for each scanline:
1. Determine tilemap Y based on SCROLL0_Y + line counter
2. Prefetch tile indices for entire scanline (X = 0..319)
3. For each pixel X (0–319):
   - Tilemap X = (X + SCROLL0_X) % 512
   - Tile X = (Tilemap X / 16) % 32
   - Fetch tile from CHR ROM
   - Extract pixel from tile at (X % 16, Y % 16)
   - Apply palette
   - Output to colmix stage

### 3.6 Test Vector Counts (Gate 3)

| Test | Vectors | Purpose |
|------|---------|---------|
| Tilemap address decoding | 64 | Access all 32×32 tile entries |
| Tile fetch pipeline | 128 | Verify ROM fetch timing (1–2 cycles per tile) |
| Scroll register update | 32 | Test SCROLL0_X/Y updates, wraparound |
| Tile flip logic | 16 | Verify flipX/Y/XY flags |
| Palette selection (per-tile) | 32 | Test 16 palette variants |
| Boundary wrapping (512px tilemap) | 16 | Verify wraparound at edges |
| Multi-layer rendering | 16 | Layer 0 + Layer 1 composition |
| **Total Gate 3** | **~350 vectors** | Tilemap renderer validation |

---

## Gate 4 Spec: Colmix & Priority

### 4.1 Compositing Pipeline

For each pixel (X, Y), the hardware **blends** layers in priority order:

```
┌──────────────────────────────────────┐
│ Pixel (X, Y)                         │
├──────────────────────────────────────┤
│ 1. Sample BG Layer 0 (far)           │
│    → tile_index, tile_pixel, palette │
├──────────────────────────────────────┤
│ 2. Sample BG Layer 1 (near, if enabled)
│    → tile_index, tile_pixel, palette │
├──────────────────────────────────────┤
│ 3. Sample Sprites (by priority)      │
│    → Merge all active sprites on line│
├──────────────────────────────────────┤
│ 4. Priority Mux                      │
│    → Determine winner (BG0 vs BG1    │
│       vs Sprite), apply transparency │
├──────────────────────────────────────┤
│ 5. Output: [Palette Index] + [Flags] │
└──────────────────────────────────────┘
```

### 4.2 Priority Logic

The **SPRITE_CTRL** register defines sprite vs. background priority:

```
SPRITE_CTRL[11:8] = priority_mode:

  0 = Sprites always under BG0/BG1
      Output = (BG1 opaque) ? BG1 : (BG0 opaque) ? BG0 : Sprite

  1 = Sprite priority per pen (color):
      For each sprite color, check if it has high bit set
      If high bit set → sprite on top; else → sprite under BG
      Output = (Sprite_high_bit) ? Sprite : BG_sample

  2 = Sprites always over BG0/BG1
      Output = (Sprite opaque) ? Sprite : BG_sample

  3 = Mixed (typical for shmups):
      Sprite ATTR[11:8] (priority) vs. BG priority field
      Compare and blend accordingly
```

### 4.3 Color Key / Transparency

Each layer can define a **transparent color**:

- **Sprite Transparency**: ATTR[3:0] = color key index (0–15)
  - If pixel matches color key → transparent, blend with layer below
- **BG Tile Transparency**: Per-tile ATTR[9:0] may include transparency bit
  - Consult MAME `nmk16.cpp` for exact encoding

### 4.4 Output Pixel Format

After colmix, the pixel data **fed to Gate 5 (RGB output)**:

```
Output (16 bits):
  [15:13]  Priority (0–7, for debug / overscan detection)
  [12:8]   Reserved (high bits for future extensions)
  [7:0]    Palette index (0–255, 256-color palette)
```

### 4.5 Test Vector Counts (Gate 4)

| Test | Vectors | Purpose |
|------|---------|---------|
| Layer priority (BG0 vs BG1 vs Sprite) | 64 | Test all priority modes (0–3) |
| Color key transparency | 32 | Verify transparent color masking |
| Opaque vs. transparent pixels | 16 | Blend logic correctness |
| Sprite vs. BG priority sorting | 32 | Verify 16 sprite priorities against BG |
| Multi-layer edge cases | 16 | Overlapping opaque/transparent pixels |
| Palette index output | 32 | Verify 8-bit palette indices correct |
| **Total Gate 4** | **~200 vectors** | Colmix validation |

---

## Gate 5 Spec: Pixel Output & Palette

### 5.1 Palette Format

NMK16 uses a **standard 256-color palette**:

```
Palette RAM: $140000–$14FFFF (mirrored, 1 KB used)

Per-color entry (16 bits):
  [15:11]  Red (5 bits, 0–31 → 0–255 on output)
  [10:6]   Green (5 bits)
  [5:1]    Blue (5 bits)
  [0]      Unused / Reserved

Or (game-dependent, may vary):
  RGB555 or XRGB1555 format (verify MAME)
```

### 5.2 RGB Output

The final **RGB555** or **RGB888** output (game-dependent; FPGA may upscale):

```
Output Bus (24 bits typical):
  [23:16]  Red (8 bits, 0–255)
  [15:8]   Green (8 bits)
  [7:0]    Blue (8 bits)

Timing:
  - 320 pixels per scanline
  - 224 scanlines per frame
  - Horizontal blanking: ~65 pixels (25% overhead)
  - Vertical blanking: ~29 lines (12% overhead)
  - Pixel clock: 6.144 MHz (or game-dependent; verify MAME)
```

### 5.3 Pixel Output Sequencing

```
Line 0–223:   Active video output (320 pixels each)
Line 224–239: Vertical blanking (224 + 16 = 240 lines total)
Line 0–319:   Horizontal pixels per line
Line 320–383: Horizontal blanking (320 + 64 = 384 pixels per line, typical)
```

### 5.4 Test Vector Counts (Gate 5)

| Test | Vectors | Purpose |
|------|---------|---------|
| Palette lookup (256 entries) | 256 | Read all colors; verify RGB format |
| RGB555 expansion (5-bit to 8-bit) | 32 | Verify bit expansion (e.g., 5-bit R → 8-bit via duplication) |
| Pixel timing (H/V sync, blanking) | 64 | Validate H/V sync pulse timing |
| Frame composition (320×224) | 32 | Full-frame pixel sequencing |
| Palette write timing (CPU → FPGA) | 16 | Verify palette updates between frames |
| **Total Gate 5** | **~450 vectors** | Pixel output validation |

---

## Estimated Test Vector Counts (All Gates)

| Gate | Subsystem | Vectors | Confidence |
|------|-----------|---------|------------|
| 1 | CPU Interface | ~400 | HIGH |
| 2 | Sprite Scanner | ~500 | HIGH |
| 3 | Tilemap Renderer | ~350 | MEDIUM |
| 4 | Colmix & Priority | ~200 | MEDIUM |
| 5 | Pixel Output | ~450 | HIGH |
| **TOTAL** | **All Subsystems** | **~1,900 vectors** | **MEDIUM-HIGH** |

**Rationale**: NMK16 is simpler than Psikyo (4 custom chips) or Kaneko (7 custom chips), but requires careful attention to:
- Sprite RAM scanning (timing-critical)
- Tilemap offset / scroll wrapping
- Priority muxing logic (often subtle bugs)

---

## Key Risks & Open Questions

### Risk 1: Sprite Scanning Timing (CRITICAL)

**Question**: What is the exact **sprite-per-scanline limit** and **rasterizer pipeline depth**?

**Why**: Truxton and Blazing Lazers have dense bullet patterns (100+ sprites per frame). If the scanner overflows, visuals degrade.

**Mitigation**:
1. Extract max sprite count from MAME `nmk16.cpp` sprite_eval() function
2. Trace scanline 100–150 during boss fight in TAS data
3. Compare MAME emulation vs. real hardware if sprites drop

**Verification**: Run TAS validation on Truxton (frame 2000–2500) and measure sprite coverage.

### Risk 2: Scroll Register Shadowing (MEDIUM)

**Question**: Do SCROLL0_X/Y updates **latch at VBLANK** or **immediately apply mid-frame**?

**Why**: Some games (Cyber Lip) may use mid-frame scroll changes for parallax effects. If timing is wrong, layers misalign.

**Mitigation**:
1. Check MAME driver for `screen_update()` vs. `video_update()` calls
2. Inspect game code (if disassembly available) for scroll register writes
3. Compare FPGA output frame-by-frame with MAME during high-speed scrolling scenes

**Verification**: Test with Cyber Lip level 1 (fast horizontal scroll).

### Risk 3: Palette Format Ambiguity (MEDIUM)

**Question**: Is palette **RGB555** or **XRGB1555**? Do 5-bit RGB values **scale or shift** to 8-bit output?

**Why**: Color accuracy affects visual comparison; mismatches will appear as subtle shade differences.

**Mitigation**:
1. Dump palette RAM from FCEUX emulator (debug panel) for known game frame
2. Extract RGB values and verify bit layout
3. Compare MAME palette output vs. FPGA output (color accuracy test)

**Verification**: Load Truxton title screen, sample a few pixels (red logo, blue background).

### Risk 4: NMK004 / NMK214 Custom Chip (MEDIUM-HIGH)

**Question**: What do **NMK004** (CPU variant) and **NMK214** (protection/IO) actually do?

**Why**: Some games (Quizdna, Quizpani) use these chips. If they include copy protection or custom I/O routing, workarounds needed.

**Mitigation**:
1. Audit MAME `nmk004.cpp` and `nmk214.cpp` for CPU-like behavior
2. If purely protection, implement as ROM decryption lookup table or hardcoded bypass
3. If custom I/O (coin counter, dip switch), integrate into CPU memory map as registers

**Verification**: Check if Truxton/Blazing Lazers (NMK16 only) boot without NMK004/NMK214 support.

### Risk 5: Tile Size Variations (MEDIUM)

**Question**: Are all tiles **always 16×16**, or do some games support variable sizes (8×8, 32×32)?

**Why**: If variable, rendering pipeline becomes more complex; prefetch/cache logic needs overhaul.

**Mitigation**:
1. Audit game ROM headers / MAME game configs for tile size info
2. Start with assumption: all 16×16; add variable size support later if needed
3. Test with Truxton (simplest shmup) first

**Verification**: Inspect Truxton background scrolling; confirm no 8×8 or 32×32 tiles visible.

### Risk 6: Sprite ROM Bank Switching (MEDIUM)

**Question**: If TILE_INFO[15:11] selects sprite ROM bank, is bank switching **dynamic per-sprite** or **static per-frame**?

**Why**: If dynamic, rendering stalls on bank switches; if static, pre-load all banks.

**Mitigation**:
1. Check MAME sprite fetcher for bank switch logic
2. Measure average fetch time per sprite
3. Design ROM arbitrator with bank cache (1–2 KB)

**Verification**: Monitor ROM access traces during sprite-heavy frame (Gunhed level 1, boss phase).

### Risk 7: Video Timing (PIXEL CLOCK, HSYNC/VSYNC) (MEDIUM)

**Question**: Exact **pixel clock frequency** and **sync pulse widths** for each game variant?

**Why**: FPGA timing synchronization; clock derivation from master oscillator.

**Mitigation**:
1. Extract video timing from MAME video_update_params (pixel clock, H/V blank counts)
2. Hardcode per-game timing, or derive from ROM header
3. Test with external display / scope to verify sync signal timing

**Verification**: Connect MiSTer FPGA to real arcade monitor; check sync pulse widths.

---

## Implementation Prerequisites (Before RTL Coding)

### 1. MAME Source Audit Checklist

- [ ] Read `nmk16.cpp` entirely; extract sprite/tile/colmix logic
- [ ] Identify all unique game variants (NMK16 vs. NMK004 vs. NMK214)
- [ ] Extract video timing (pixel clock, H/V counts) for each variant
- [ ] Document palette format (RGB555 vs. XRGB1555)
- [ ] Map all control register addresses and bit fields
- [ ] Trace sprite scanning and priority logic
- [ ] Note any undocumented behaviors or quirks

### 2. ROM Preparation

- [ ] Extract CHR ROM (background tiles) and map byte layout
- [ ] Extract OBJ ROM (sprite graphics) and verify 16×16 tile structure
- [ ] Create test ROM segments for validation (256×256 px test pattern, known sprites)

### 3. TAS Validation Framework

- [ ] Set up frame-by-frame comparison (Truxton 1-frame TAS vs. FPGA)
- [ ] Dump emulator RAM at each frame boundary (for cross-validation)
- [ ] Build sprite/tile overlay visualization (debug output)

### 4. Hardware Verification

- [ ] If access to real arcade cabinet: dump palette RAM, compare with FPGA
- [ ] Measure pixel clock and sync timings with oscilloscope
- [ ] Capture video output, compare to MAME at 1:1 pixel level

---

## Success Criteria

| Criterion | Gate(s) | Metric |
|-----------|---------|--------|
| CPU addresses route correctly | Gate 1 | All 256 test vectors pass |
| Sprite RAM parsed without corruption | Gate 2 | 256 sprites read, data integrity 100% |
| Tilemaps scroll smoothly, no artifacts | Gate 3 | Truxton level 1 background scrolls with <1-pixel jitter |
| Sprite-BG priority correct | Gate 4 | Truxton bullets layer correctly over background |
| Final RGB output matches MAME | Gate 5 | Pixel-level comparison: 99%+ match (excluding PPU timing artifacts) |
| Full game runs (TAS validation) | All | Truxton 1-frame TAS runs; sprite coverage >95% of emulator |

---

## Recommended Game Priority

1. **Truxton** (1989) — Best TAS data, simplest shmup logic, known good reference
2. **Blazing Lazers** (1990) — Variant of Truxton, validates robustness
3. **Gunhed** (1993) — More complex sprite patterns, validates performance ceiling
4. **Cyber Lip** (1990) — Action game (not shmup); tests non-shoot mechanics

---

## References & Resources

**MAME Source**:
- `nmk16.cpp` — Main driver (sprite scanning, priority, tilemap logic)
- `nmk004.cpp` — Custom CPU variant (if needed)
- `nmk214.cpp` — Protection/IO chip (reverse-engineering notes)

**Community Disassemblies**:
- Truxton ROM disassembly (if available on Data Crystal or GitHub)
- Sound driver extraction (Z80 code, YM2203/OKI6295 setup)

**MiSTer References**:
- `jotego/jtcores` — YM2203 and OKI6295 module implementations (reusable)
- `zerowing` (Toaplan V1) — Similar 68000 + tile/sprite architecture (reference)

**Test Data**:
- Truxton TAS (full game, 1-frame input) — `/Volumes/2TB_20260220/Projects/ROMs_Claude/everdrive_n8/.../truxton.fm2` (or similar)
- FCEUX save states at key frames (level transitions, boss phases)

---

## Next Phase

Once this gate plan is validated against MAME source:

1. **Gate 1 RTL**: Implement address decoder, register staging (2 days)
2. **Gate 2 RTL**: Sprite scanner + RAM interface (5 days)
3. **Gate 3 RTL**: Tilemap renderer + scroll logic (6 days)
4. **Gate 4 RTL**: Colmix + priority muxing (3 days)
5. **Gate 5 RTL**: Palette + RGB output (2 days)
6. **Integration & Validation**: 20–30 days (TAS testing, debug harness, performance tuning)

**Total**: ~50–80 days for full NMK16 FPGA core.

---

**Plan Status**: READY FOR RTL IMPLEMENTATION
**Last Updated**: 2026-03-17
**Author**: MiSTer Pipeline Research
