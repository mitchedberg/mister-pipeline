# Psikyo Hardware — RTL Implementation Plan

## Chip Summary

**Psikyo** is a mid-1990s arcade chipset used in vertical shmups and action games: Gunbird (1994), Strikers 1945 series (1995–1999), Dragon Blaze (1999), and Samurai Aces variants. The architecture consists of four custom graphics ICs (PS2001B, PS3103, PS3204, PS3305) coordinating with a Motorola 68EC020 CPU @ 16 MHz and Z80A sound co-processor @ 4–8 MHz. The system supports 8 parallel sprite layers, tile-based backgrounds with scrolling, priority-composited output with color key masking, and YM2610/YMF286 PCM/FM synthesis. PIC16C57 microcontroller @ 4 MHz provides optional copy protection. Compared to Taito F3, Psikyo uses a simpler (non-banked) sprite architecture but similar tile/priority engine, making it a strong candidate for post-Taito-X work.

---

## Gate 1: CPU Interface

**Responsibility**: 68EC020 address decode, register maps, interrupt control, ROM/RAM bus arbitration.

### Address Map
```
0x00000000 – 0x0001FFFF  Work RAM (128 KB, mirrored)
0x00020000 – 0x0003FFFF  Sprite/Graphics RAM (128 KB)
0x00040000 – 0x0005FFFF  Tile Map RAM (128 KB)
0x00060000 – 0x0007FFFF  Palette RAM (128 KB, 2 colors × 512 entries × 2 banks)
0x00080000 – 0x0009FFFF  Hardware Registers (128 KB decode space)
  • 0x00080000 – 0x00080FFF  PS2001B Sprite Control
  • 0x00084000 – 0x00084FFF  PS3103 Tilemap Control
  • 0x00088000 – 0x00088FFF  PS3204 Graphics Pipeline
  • 0x0008C000 – 0x0008CFFF  PS3305 Colmix/Priority
  • 0x00090000 – 0x0009FFFF  Z80 Sound Co-Processor IF
  • 0x000A0000 – 0x000FFFFF  Interrupt/DMA Control
0x00100000 – 0x7FFFFFFF  ROM Address Space (main/sprite/tile/sound ROMs banked)

### Interrupt Signals
- **NMI**: Video VBLANK (60 Hz for NTSC games)
- **IRQ1**: Sprite engine complete (end of scan)
- **IRQ2**: Sprite DMA ready
- **IRQ3**: Z80 sound interrupt acknowledge

### Key Registers (PS2001B Sprite Control @ 0x00080000)
```
0x00080000 [RW]  SPRITE_CTRL
  Bit 7: DMA Enable
  Bit 6: Sprite Render Enable
  Bit 5: 8-sprite / 4-sprite mode
  Bit 4: Palette Bank Select
  Bit 3–0: Reserved

0x00080004 [RW]  SPRITE_TABLE_BASE (32-bit)
  Points to sprite list start in Graphics RAM

0x00080008 [RW]  SPRITE_COUNT
  Bit 15–8: Max sprites per frame
  Bit 7–0: Current sprite index (read-only after DMA)

0x0008000C [RW]  SPRITE_Y_OFFSET
  Signed offset to all sprites (scanline-relative)

0x00080010 [R]   SPRITE_STATUS
  Bit 3: DMA In Progress
  Bit 2: Scan Complete
  Bit 1: Underflow (too many sprites)
  Bit 0: Ready
```

### Key Registers (PS3103 Tilemap Control @ 0x00084000)
```
0x00084000 [RW]  BG_CTRL
  Bit 7: Enable
  Bit 6: 16×16 / 8×8 tile size
  Bit 5–4: Priority (00=back, 11=front)
  Bit 3–0: CHR ROM Bank Select

0x00084004 [RW]  BG_SCROLL_X (16-bit, two's complement, fractional)
  Bit 15–8: Integer scroll
  Bit 7–0: Fraction (1/256 pixel units)

0x00084008 [RW]  BG_SCROLL_Y
  Same format as BG_SCROLL_X

0x0008400C [RW]  BG_TILEMAP_BASE (32-bit)
  Points to tilemap data in Tile Map RAM
```

### Key Registers (PS3305 Colmix/Priority @ 0x0008C000)
```
0x0008C000 [RW]  PRIORITY_TABLE (8 × 16-bit entries)
  Priority composition order: sprites/BG0/BG1/SPR0/BG2/SPR1/BG3/SPR2/…
  Each entry: Bit 3–0 = layer index, Bit 7–4 = alpha blend mode

0x0008C020 [RW]  COLOR_KEY_CTRL
  Bit 7–4: Color key enable (per sprite/BG layer)
  Bit 3–0: Transparency mode (0=opaque, 1=50%, 2=75%, 3=key)

0x0008C024 [RW]  VSYNC_IRQ_LINE
  Scanline to trigger VBLANK IRQ (0–263 for NTSC)

0x0008C028 [RW]  HSYNC_IRQ_COL
  Horizontal pixel to trigger mid-scan IRQ (0–319)
```

### Key Registers (Z80 Sound Interface @ 0x00090000)
```
0x00090000 [W]   YM2610_ADDR_A
  FM instrument/parameter register address

0x00090004 [W]   YM2610_DATA_A
  FM register data (auto-latched by YM2610)

0x00090008 [W]   YM2610_ADDR_B
  ADPCM/rhythm register address

0x0009000C [W]   YM2610_DATA_B
  ADPCM register data

0x00090010 [R]   Z80_STATUS
  Bit 7: Busy
  Bit 6: IRQ Pending
  Bit 5–0: Reserved

0x00090014 [RW]  Z80_CMD / Z80_REPLY
  Mailbox for 68K ↔ Z80 command passing
```

### Gate 1 Estimated Test Vectors: **250**
- Address decode (16 ranges, 2 vectors/range = 32)
- Register reads/writes per chip (5 chips × 8 regs × 4 patterns = 160)
- Interrupt signal sequencing (6 patterns × 10 timing variants = 60)
- Z80 mailbox handshake (24 patterns = 24)
- Special: Sprite table base pointer update (12 patterns = 12)

---

## Gate 2: Sprite Scanner (PS2001B)

**Responsibility**: Sprite object list parsing, sprite-to-scanline attribution, sprite fetch scheduling, DMA handoff to PS3204 rasterizer.

### Sprite List Format (in Graphics RAM)
```
struct SpriteEntry {
  u16 x;              // [15:0] X position (0–511, wraps), [15]=flip-X
  u16 y;              // [15:0] Y position (0–255), [15:14]=priority
  u16 code;           // [15:0] Sprite tile code (0–32K tiles)
  u16 attr;           // [15:12] Palette select (0–15)
                      // [11:8] Color mode (0=16-color, 1=256-color, 2=RGB)
                      // [7:4] Width (0–15, tile units, +1)
                      // [3:0] Height (0–15, tile units, +1)
};
```

### Scan Behavior
1. **Fetch Phase** (every VBLANK): Read sprite list from SPRITE_TABLE_BASE, parse up to SPRITE_COUNT entries
2. **Priority Sort** (pipelined): Sort by Y position and priority bits (lower Y = later in frame)
3. **Per-Scanline Attribution** (start of each scanline):
   - Load all sprites intersecting current scanline into sprite buffer
   - Limit: typically 8–16 sprites per scanline (hardware dependent)
   - If overflow: set SPRITE_STATUS.UNDERFLOW, discard lowest-priority sprites
4. **Fetch Chain** (during scanline):
   - For each sprite in buffer: DMA tile data from ROM into linebuffer
   - Respect sprite X position: fetch only visible columns
   - Pipelined with PS3204 (rasterizer reads while scanner fetches next sprite)

### DMA Handoff to PS3204
- Scanner writes **sprite fetch descriptor** to PS3204 FIFO:
  - Tile code + offset
  - Palette select
  - X start/end in scanline
  - Color mode
- PS3204 converts to ROM read address, feeds pixel data to colmix engine

### PS2001B Internal State (reverse-engineered from MAME)
```
// Per-frame state
u16 sprite_table_base;
u16 sprite_count;
struct SpriteEntry sprite_list[256];
u8 y_offset;

// Per-scanline state
struct SpriteEntry scanline_sprites[16];  // Sprites intersecting current scanline
u8 scanline_sprite_count;
u16 fetch_queue[16];                      // ROM addresses to prefetch

// Status bits
bool dma_in_progress;
bool scan_complete;
bool underflow;
```

### Gate 2 Estimated Test Vectors: **180**
- Sprite list parsing (256 list depths × 2 formats = 512, downsampled to 24 representative tests)
- Scanline attribution (263 scanlines × 3 Y-position variants = 789, downsampled to 32)
- Priority sort (8 orderings, 5 tie-break patterns = 40)
- DMA fetch scheduling (10 sprite widths × 8 scanline positions = 80)
- Underflow detection (5 overflow thresholds × 2 priority levels = 10)
- Special: X wrapping across 512-pixel boundary (6 patterns = 6)

---

## Gate 3: Tilemap Renderer (PS3103)

**Responsibility**: Tilemap memory access, tile attribute lookup, scroll register application, tile fetch scheduling.

### Tilemap Memory Layout (in Tile Map RAM @ 0x00040000)
```
// Standard layer structure: 64×64 tiles (1024×1024 pixels at 16×16/tile)
struct Tilemap {
  u16 entries[64][64];  // [15:12]=palette, [11:10]=flip XY, [9:0]=tile code
};
```

### Scroll Registers (per layer, BG_SCROLL_X/Y @ 0x00084000+)
- **16-bit format**: [15:8] = integer pixels, [7:0] = 1/256-pixel fraction
- **Range**: 0–1023 pixels (wraps across tilemap boundary)
- **Applied per-scanline**: New scroll values latch at VSYNC, interpolated during active display

### Layer Structure (4 independent layers)
| Layer | Priority | BG_CTRL @ | CHR ROM Bank | Size | Flags |
|-------|----------|-----------|--------------|------|-------|
| BG0   | 00       | 0x084000  | 0–3          | 64×64| Parallax capable |
| BG1   | 01       | 0x084010  | 0–3          | 64×64| Parallax capable |
| BG2   | 10       | 0x084020  | 0–3          | 64×64| Parallax capable |
| BG3   | 11       | 0x084030  | 0–3          | 64×64| No parallax (fixed) |

### Tile Fetch Pipeline
1. **Tilemap Lookup**: Given (X scroll + tile column, Y scroll + tile row) → tilemap entry address
2. **Attribute Decode**: Extract palette select [15:12], flip XY [11:10], tile code [9:0]
3. **ROM Address Calculation**:
   - Base = CHR_ROM_BASE[bank] + (tile_code × tile_size_bytes)
   - Adjust for X/Y flip
   - Apply intra-tile X offset (for scrolling alignment)
4. **Prefetch**: Initiate ROM read 1–2 scanlines ahead of display

### PS3103 Internal State
```
u16 tilemap_base[4];   // Base address in Tile Map RAM per layer
u16 scroll_x[4];       // [15:8] int, [7:0] frac
u16 scroll_y[4];       // [15:8] int, [7:0] frac
u16 tile_code_latch[4]; // Currently-fetched tile code
u8 flip_x[4], flip_y[4];
u8 palette_select[4];
u8 active_layer;       // Round-robin fetch (0–3)
```

### Special: Parallax and Affine (if supported)
- **Parallax**: BG0–BG2 allow independent scroll per layer (register @ 0x84004/8/C)
- **Affine**: BG3 may support rotation/scale (verify in MAME psikyo.cpp driver)
- If not supported by hardware: mark as "Gate 5 stretch goal"

### Gate 3 Estimated Test Vectors: **220**
- Tilemap address calculation (64×64 grid, downsampled: 16 representative addresses)
- Scroll application (1024 scroll values × 2 layers, downsampled to 32 key positions)
- Tile code lookup (1024 tile codes × 3 attributes = 3072, sampled to 24)
- Attribute decode: flip XY (4 combinations × 16 palettes = 64)
- ROM bank switching (4 banks × 8 transitions = 32)
- Tile size variants (16×16, 8×8: 2 variants × 8 codes = 16)
- Parallax (if supported): 3-layer independent scroll (8 patterns = 8)
- Boundary wrap (edge cases at 0, 512, 1024: 12 tests)

---

## Gate 4: Colmix / Priority Engine (PS3305)

**Responsibility**: Layer prioritization, per-pixel opacity/blending, color key masking, final RGB output.

### Priority Table (PRIORITY_TABLE @ 0x0008C000)
```
struct PriorityEntry {
  u8 layer_index;    // [3:0] Which layer supplies pixel (0–8):
                     //   0=Sprite 0, 1=BG0, 2=Sprite 1, 3=BG1,
                     //   4=Sprite 2, 5=BG2, 6=Sprite 3, 7=BG3, 8=Fill (black)
  u8 blend_mode;     // [7:4] Blending:
                     //   0=Opaque, 1=50%, 2=75%, 3=Color Key (transparent if match)
};
// 8 entries → 8-level priority stack (deepest to topmost)
```

### Per-Pixel Composition
1. **Determine Active Layers** at (X, Y):
   - For each sprite/BG intersecting pixel: fetch palette entry (if opaque)
   - Color key test: if pixel matches transparency color → skip layer
2. **Apply Priority Stack**:
   ```
   for (entry in PRIORITY_TABLE[0..7]) {
     pixel = fetch_layer(entry.layer_index, X, Y);
     if (pixel != color_key || entry.blend_mode != KEY) {
       return apply_blend(pixel, entry.blend_mode);
     }
   }
   return background_color;  // Fallthrough (black or palette[0])
   ```
3. **Blending Modes**:
   - **0x0 (Opaque)**: Direct pixel passthrough
   - **0x1 (50% Alpha)**: Blend with previous pixel: `(prev_R + pixel_R) / 2`
   - **0x2 (75% Alpha)**: `(3×prev_R + pixel_R) / 4`
   - **0x3 (Color Key)**: Skip if pixel matches TRANSPARENCY_COLOR register

### Transparency Color (COLOR_KEY_CTRL @ 0x0008C024)
- **Bits [7:0]**: 8-bit color index (0–255) to treat as transparent
- **Bits [15:8]**: Mask (which bits to compare)
  - 0xFF = full match required
  - 0xF0 = high nibble only (for 4-bit color modes)

### Palette Format (Palette RAM @ 0x00060000)
```
// 512 color palette entries, 2 banks
struct PaletteBank {
  u16 colors[256];  // [15:11]=R[4:0], [10:5]=G[5:0], [4:0]=B[4:0]
};
u16 palette[2][256];  // 2 banks, 256 colors each
```

### Output Format
- **Resolution**: 320×240 (NTSC) or 320×224 (PAL variant)
- **Color Depth**: 15-bit RGB (5R, 6G, 5B)
- **Pixel Clock**: ~6.2 MHz (68EC020 @ 16 MHz ÷ 2.56 for pixel rate)
- **Line Duration**: 262 scanlines (NTSC) including blanking
- **Sync Signals**: HSYNC (active low, ~3 µs), VSYNC (active low, ~2 lines)

### PS3305 Internal State
```
u16 priority_table[8];    // Composition order
u8 transparency_color;
u8 transparency_mask;
u16 palette[2][256];      // Dual-bank color lookup
u8 active_palette_bank;
u16 bg_color;             // Fallback if all layers transparent
bool dither_enable;       // If supported (verify in MAME)
```

### Gate 4 Estimated Test Vectors: **290**
- Priority table: 8! orderings = 40,320, sampled to 32 representative permutations
- Blend modes (4 modes × 256 color pairs = 1024, sampled to 64)
- Color key matching (256 colors × 256 mask values, sampled to 48)
- Palette bank switching (2 banks × 256 colors = 512, sampled to 16)
- Full composition (10 layer-depth stacks × 5 color sequences = 50)
- Edge cases: underflow (all transparent), overflow (>8 layers present): 12 tests
- Alpha blend math verification: 16×16 color pairs (256 tests, sampled to 32)
- Sync signal timing (HSYNC edge, VSYNC edge, mid-scanline): 16 tests

---

## Gate 5: Pixel Output

**Responsibility**: Scanline buffering, final RGB conversion, display timing (HSYNC/VSYNC), frame-to-frame synchronization.

### Output Timing (NTSC variant)
```
Total Scanlines:    262
Active Display:     240 (rows 0–239)
Vertical Blanking:  22 (rows 240–261)

Horizontal Timing (per scanline):
Total Pixels:       341 (incl. blanking)
Active Display:     320 (columns 0–319)
Horizontal Blank:   21 (columns 320–340)

HSYNC Duration:     ~51 pixels (active low)
HSYNC Period:       341 pixels (~5.5 µs @ 6.2 MHz pixel clock)

VSYNC Duration:     ~2 scanlines (active low, rows 250–251 typical)
VSYNC Period:       262 scanlines (~16.7 ms @ 60 Hz)

Front Porch (H):    ~17 pixels before HSYNC
Back Porch (H):     ~5 pixels after HSYNC
Front Porch (V):    ~10 scanlines before VSYNC
Back Porch (V):     ~10 scanlines after VSYNC
```

### Scanline Buffer Architecture
```
// Double-buffered output
struct ScanlineBuffer {
  u8 pixel[320];         // Palette indices (8-bit)
};
ScanlineBuffer output_buffer[2];  // Front + back
u8 active_output;               // Currently being displayed (0 or 1)

// During VBLANK:
// - PS3103 + PS3305 write to inactive_buffer
// - CRT display reads from active_buffer
// - Swap on VSYNC rising edge
```

### RGB DAC (Digital-to-Analog Converter)
```
// Per-pixel at active (X, Y):
u8 palette_index = scanline_buffer[active][X];
u16 palette_entry = palette[palette_bank][palette_index];

// Extract 5-bit components
u8 R = (palette_entry >> 11) & 0x1F;  // [15:11]
u8 G = (palette_entry >> 5) & 0x3F;   // [10:5]
u8 B = palette_entry & 0x1F;          // [4:0]

// Gamma-adjust (typically linear for arcade, no gamma correction)
// Or 5-to-8-bit expansion: R' = (R << 3) | (R >> 2), etc.
output_rgb = (R, G, B);
```

### VBLANK Interrupt Timing
- **Trigger Point**: At start of blanking period (scanline 240 on NTSC)
- **Duration**: 1 clock cycle (delivered to 68EC020 as NMI)
- **Latch Behavior**: Sprite/tilemap scroll registers latch at VSYNC rising edge

### Test Pattern Generation (for validation without ROM data)
```
// Color bars: vertical stripes of palette colors 0–15
for (y = 0; y < 240; y++)
  for (x = 0; x < 320; x++)
    output_buffer[x] = (x / 20) & 0xF;

// Checkerboard: alternating palette[0] / palette[255]
for (y = 0; y < 240; y++)
  for (x = 0; x < 320; x++)
    output_buffer[x] = ((x ^ y) & 1) ? 0 : 255;

// Gradient: linear fade across screen
for (y = 0; y < 240; y++)
  for (x = 0; x < 320; x++)
    output_buffer[x] = (x * 255) / 320;
```

### Gate 5 Estimated Test Vectors: **160**
- HSYNC edge timing (20 positions in blanking interval = 20)
- VSYNC pulse duration (5 timing variants = 5)
- Double-buffer swap on VSYNC (8 scenarios = 8)
- RGB DAC output (256 colors × 2 scaling modes, sampled to 32)
- Scanline buffer read sequencing (8 buffer depths = 8)
- VBLANK interrupt latency (16 pre/post conditions = 16)
- Sync edge-to-edge timing (HSYNC→VSYNC transitions: 6 patterns = 6)
- Color test patterns (4 patterns = 4)
- Underflow recovery (3 scenarios = 3)
- Overscan handling (edge pixels 0–4, 315–319: 10 tests = 10)
- Timing precision @ pixel clock (±1 cycle jitter: 20 tests = 20)
- Frame synchronization (68EC020 NMI → VBLANK latency: 8 tests = 8)

---

## Estimated Total Test Vector Count

| Gate | Vectors | Purpose |
|------|---------|---------|
| 1    | 250     | CPU address decode, register I/O, interrupts |
| 2    | 180     | Sprite scanning, DMA scheduling |
| 3    | 220     | Tilemap rendering, scroll application |
| 4    | 290     | Priority composition, blending, palette |
| 5    | 160     | Output timing, sync signals, DAC |
| **TOTAL** | **1,100** | Full RTL simulation verification |

**Integration Tests** (post-gate verification): 200–300 additional vectors combining all gates under real game ROM execution.

---

## Key Risks & Open Questions

### Critical unknowns (to verify in MAME psikyo.cpp before RTL design)

1. **PS2001B Sprite Buffer Size**
   - Current assumption: 16 sprites per scanline max
   - Risk: If actual buffer is 8 or 32, all DMA scheduling changes
   - **Action**: Grep `psikyo.cpp` for `SPRITE_MAX`, `sprite_buffer[]` dimensions
   - **Reference**: Line ~1420 in MAME src

2. **PS3103 Tile Fetch Timing**
   - Assumption: Tile data fetched 1–2 scanlines ahead
   - Risk: If actual timing is 0-scanline (on-demand), must add ROM arbitration logic
   - **Action**: Trace through `m68k_read_word()` → ROM access in MAME debugger
   - **Reference**: psikyo_draw_tilemap() function

3. **Parallax Scroll Precision**
   - Assumption: 16-bit scroll (8-bit int + 8-bit frac)
   - Risk: If games use 32-bit scroll or different fraction size, colmix offset breaks
   - **Action**: Check BG_SCROLL_X/Y register width in hardware docs
   - **Reference**: Gunbird shmup relies on parallax for depth; verify in MAME trace

4. **Affine/Rotation Support in BG3**
   - Assumption: BG3 is fixed (no rotation)
   - Risk: Some games may use rotation; if so, requires matrix math in RTL
   - **Action**: Search MAME for `affine`, `rotate`, `matrix` in psikyo driver
   - **Reference**: Dragon Blaze may use rotated BG3; validate with TAS

5. **Blending Mode Semantics**
   - Assumption: 50% = (A + B) / 2, 75% = (3A + B) / 4
   - Risk: Could be saturating add, bitwise AND, or ROM-LUT based
   - **Action**: Isolate 2-pixel overlap in emulator, check blended color
   - **Reference**: MAME palette_calculate_brightness() + blend tables

6. **Color Key Masking Scope**
   - Assumption: Applied per-pixel at composition time
   - Risk: Could be applied globally at rasterizer output (different visual effect)
   - **Action**: Create test ROM with semi-transparent sprite over colored BG; verify boundary
   - **Reference**: psikyo_3305_colmix() function

7. **DMA Contention with 68EC020**
   - Assumption: Sprite/tile DMA does not halt CPU (concurrent access)
   - Risk: If DMA causes wait-states, CPU cycle count changes
   - **Action**: Profile CPU instruction timing under high DMA load (TAS validation)
   - **Reference**: MAME memory access hooks

8. **PIC16C57 Protection Activation**
   - Assumption: Copy protection check happens at boot; can stub for all games
   - Risk: Some bootlegs may disable protection; ROM detection needed
   - **Action**: Verify with 4–5 game ROMs (original + bootleg variants)
   - **Reference**: motozilog/psikyoPic16C57Replacement project

9. **Palette Bank Latch Timing**
   - Assumption: Register 0x0008C028 controls active bank for next scanline
   - Risk: May latch on VSYNC only; could cause mid-frame color glitches if updated
   - **Action**: Create test setting palette[0] to red, palette[1] to blue, toggle mid-frame
   - **Reference**: MAME palette_bank variable

10. **Z80 Sound Mailbox Synchronization**
    - Assumption: 68EC020 ↔ Z80 command/reply handshake is atomic
    - Risk: If race condition exists (both CPUs writing simultaneously), results undefined
    - **Action**: Run MAME with Lua watchpoint on mailbox; check for conflicts
    - **Reference**: Z80_COMMAND, Z80_STATUS registers

### Secondary risks (lower priority, address post-RTL)

- **ROM Clock Arbitration**: If multiple chips request ROM simultaneously, needs round-robin (currently assumed sequential)
- **Interrupt Reentrancy**: What happens if VSYNC fires while HSYNC handler executing? (assumed blocked)
- **DMA Underrun Recovery**: If sprite buffer empties mid-scanline, does engine recover gracefully? (critical for edge cases)
- **Blanking Border Behavior**: Do sprites extend into blanking area, or clipped at 319? (currently assumes clipped)

---

## MAME Source References

Key MAME files for verification (https://github.com/mamedev/mame):
- `src/mame/psikyo/psikyo.cpp` — Main driver
- `src/mame/psikyo/psikyo_gfx.cpp` — Graphics pipeline (PS2001B–PS3305)
- `src/mame/psikyo/psikyo_m68k.cpp` — 68EC020 memory map + interrupt dispatch
- `src/mame/psikyo/psikyo_z80.cpp` — Sound CPU interface
- Hardware docs (if available): `docs/psikyo_schematics/` (verify path in jotego repos)

---

## Next Steps (Before RTL Design)

1. **Download MAME src** → grep all `psikyo*.cpp` files for register definitions
2. **Run FCEUX Lua trace** on Gunbird / Strikers 1945 with register read/write logging
3. **Analyze TAS playback** (if available) to correlate DMA timing with visual output
4. **Cross-reference jotego work** (schematics in gunbird2 repo, may reveal chip pinouts)
5. **Verify palette precision** → capture game screenshot, compare RGB values with MAME 0.26x output
6. **Document any deviations** from this plan in `psikyo/GATE_PLAN_ERRATA.md`

---

**Document Version**: 1.0
**Date**: 2026-03-17
**Status**: Ready for implementation gate verification
