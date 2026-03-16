# TC0630FDP — Section 2: Behavioral Description & FPGA Implementation Plan

**Source:** MAME `src/mame/taito/taito_f3_v.cpp`, `taito_f3.cpp`, `taito_f3.h`
**Reference PRs:** #10920 (line clip fixes), #11788 (palette OR fix), #11811 (major rewrite)

---

## 1. Video Timing

```
Pixel clock source: 26.686 MHz XTAL / 4 = 6.6715 MHz
H total:            432 pixels
H visible:          320 pixels
H start (active):   pixel 46
H blank period:     432 - 320 = 112 pixels (blanking + sync)

V total:            262 lines
V visible:          232 lines (most games)
V start (active):   line 24
V blank period:     262 - 232 = 30 lines

Refresh rate:       6,671,500 / (432 × 262) = ~58.97 Hz

MAME screen.set_raw() call:
  screen.set_raw(26.686_MHz_XTAL / 4, 432, 46, 320+46, 262, 24, 232+24)
```

**Visible area variants:** Some games use Line RAM clipping to reduce the effective displayed
area to 224 lines (standard JAMMA) or fewer. The hardware itself always generates 232 active
lines; the narrower display is achieved by blanking top/bottom rows via clip planes.

**Pixel clock note:** The 68EC020 main CPU runs at 26.686 MHz (not divided), making the CPU
clock 4× the pixel clock. This is unusual — most Taito systems run CPU at 2× pixel clock.

---

## 2. Tilemap Layer Behavior

### 2.1 Layer Configuration

The TC0630FDP implements 6 layers total:

| Layer | Type | Tile Size | Map Geometry | Scroll | Depth |
|-------|------|-----------|--------------|--------|-------|
| PF1 | Playfield | 16×16 | 32×32 (512px) or 64×32 (1024px) | Yes | 4/5/6bpp |
| PF2 | Playfield | 16×16 | 32×32 or 64×32 | Yes | 4/5/6bpp |
| PF3 | Playfield | 16×16 | 32×32 or 64×32 | Yes | 4/5/6bpp |
| PF4 | Playfield | 16×16 | 32×32 or 64×32 | Yes | 4/5/6bpp |
| TEXT | VRAM character | 8×8 | 64×64 (512px) | No global scroll | 4bpp |
| PIXEL | Pivot/CPU pixel | 8×8 | 64×32 (512×256) | Via pivot control | 4bpp |

### 2.2 Playfield Scroll Pipeline

For each scanline Y:

```
1. Read global scroll: ctrl_xscroll[pf], ctrl_yscroll[pf]
2. If Line RAM rowscroll enabled for this scanline:
   effective_x = ctrl_xscroll[pf] + lineRAM_rowscroll[pf][Y]
   (rowscroll is fixed-point with inverted fractional bits)
3. If Line RAM zoom enabled for this scanline:
   x_scale = lineRAM_zoom_x[pf][Y]   (0x00 = 1:1)
   y_scale = lineRAM_zoom_y[pf][Y]   (0x80 = 1:1)
   Apply horizontal stretch/shrink to tile X coordinate computation
4. If column scroll enabled:
   Per-tile X position further offset by lineRAM_colscroll[pf][Y]
   (PF3/PF4 only; 9-bit range 0–511)
5. Palette addition:
   effective_palette = tile_palette + lineRAM_pal_add[pf][Y]
```

### 2.3 Tile Fetch Sequence (per visible tile)

```
tile_x = (screen_x + effective_x) / 16  mod map_width
tile_y = (Y + effective_y) / 16         mod 32

tile_index = tile_x + tile_y * map_width   (row-major)
offset_in_pf_ram = tile_index * 2           (2 words per tile entry)

attr_word = pf_ram[pf_base + offset_in_pf_ram]     // tilep[0]
code_word = pf_ram[pf_base + offset_in_pf_ram + 1] // tilep[1]

palette_index = attr_word[8:0]            // 9 bits
blend_select  = attr_word[9]              // 1 bit
extra_planes  = attr_word[11:10]          // 2 bits: 00=4bpp, 01=5bpp, 11=6bpp
flipX         = attr_word[14]
flipY         = attr_word[15]
tile_code     = code_word[15:0]

// Apply palette addition from Line RAM:
final_palette = palette_index + lineRAM_pal_add[pf][Y] / 16
```

### 2.4 GFX ROM Access (per tile pixel)

For a 4bpp tile pixel at position (px, py) within a 16×16 tile:
```
byte_offset = (tile_code * 128) + (py * 8) + (px / 2)
nibble = (px & 1) ? lo_nibble : hi_nibble
pen = nibble  // 4-bit index into the 16-color palette line
```

For 6bpp tiles, a second ROM region provides the upper 2 bits:
```
hi_bits = hi_rom[(tile_code * 64) + ...]   // 2bpp from hi ROM
pen = (hi_bits << 4) | lo_nibble           // 6-bit pen (0–63)
final_color_addr = (final_palette * 16) | pen  (with OR, not ADD, for hi-plane bits)
```

### 2.5 Alt-Tilemap Feature

PF3 and PF4 support an alternate tilemap: when bit[9] of the column-scroll Line RAM entry
is set for a scanline, those playfields read tile data from +0x2000 offset within their
playfield RAM region. This allows double-buffered or layered tilemap effects.

---

## 3. Sprite Pipeline

### 3.1 MAME Model

MAME renders sprites by:
1. **`get_sprite_info()`** — called at VBLANK, walks sprite RAM and builds a sorted list
   of `tempsprite` structs with all fields pre-decoded
2. **`draw_sprites()`** — called during `screen_update()`, iterates the tempsprite list
   and renders each sprite to a pixel buffer using `f3_drawgfxzoom()`

The sprite_lag configuration (0, 1, or 2) selects which bank of sprite RAM is used for
rendering vs the current CPU write bank, providing N-frame sprite delay for games that
write sprites during active display.

### 3.2 Sprite Walk Algorithm

```
// Walk sprite RAM from start to end; jump logic may skip entries
bank = select_bank(game_config->sprite_lag)
for offs = 0 to (sprite_ram_size / 16 - 1):
    spr = &sprite_ram[bank + offs * 8]  // 8 words of 16 bits each

    // Jump handling (word 6)
    if spr[6][15]:                     // jump bit set
        offs = spr[6][9:0]             // jump to target index
        continue

    tile_lo   = spr[0]                 // lower 16 bits of tile number
    y_zoom    = spr[1] >> 8
    x_zoom    = spr[1] & 0xFF
    scroll_mode = spr[2] >> 12
    sx        = sign_extend_12(spr[2] & 0xFFF)
    is_cmd    = spr[3][15]
    sy        = sign_extend_12(spr[3] & 0xFFF)
    block_ctrl = spr[4] >> 8
    color     = spr[4] & 0xFF

    if not is_cmd:
        tile_hi = spr[5][0]            // bit 16 of tile number
    else:
        sprite_bank = spr[5][0]
        trails_flag = spr[5][1]
        extra_planes = spr[5][9:8]
        flipscreen  = spr[5][13]

    tile_code = tile_lo | (tile_hi << 16)  // 17-bit tile number
    priority  = color >> 6                  // bits[7:6] → group 0x00/0x40/0x80/0xC0
    palette   = color & 0x3F               // lower 6 bits

    // Block (multi-tile) sprite handling
    if block_ctrl != 0 and not in_block:
        x_num = block_ctrl >> 4           // columns - 1
        y_num = block_ctrl & 0xF          // rows - 1
        anchor_x = sx, anchor_y = sy
        anchor_zoom_x = x_zoom, anchor_zoom_y = y_zoom
        x_no = 0, y_no = 0
        in_block = true

    if in_block:
        // Override position and zoom from block anchor
        x_zoom = anchor_zoom_x
        y_zoom = anchor_zoom_y
        scale = (0x100 - x_zoom)
        sx = anchor_x + (x_no * scale * 16) >> 8
        sy = anchor_y + (y_no * scale * 16) >> 8
        // ... etc. (fixed-point tile grid positioning)
        y_no++
        if y_no > y_num: y_no = 0; x_no++
        if x_no > x_num: in_block = false

    emit tempsprite(tile_code, palette, flipX, flipY, sx, sy, x_zoom, y_zoom, priority)
```

### 3.3 Sprite Rendering (f3_drawgfxzoom)

Each sprite tile is 16×16 pixels, rendered with zoom via a fixed-point accumulator:

```
for dst_y in range(render_height):
    src_y = (dst_y * (0x100 - y_zoom)) >> 8   // source row
    for dst_x in range(render_width):
        src_x = (dst_x * (0x100 - x_zoom)) >> 8  // source column
        pen = gfx_rom[(tile_code * bytes_per_tile) + src_y * 16 + src_x]
        if pen != 0:  // transparent pen = 0
            output_pixel(dst_x, dst_y, palette * 16 + pen, priority)
```

Flip is applied by inverting src_x / src_y before ROM lookup.

### 3.4 FPGA Sprite Engine Strategy

The MAME sprite model uses a CPU-side pixel framebuffer. For FPGA, two strategies:

**Option A: True sprite framebuffer in SDRAM (accurate)**
- Allocate 320×256 × 8bpp = ~80KB of SDRAM for sprite buffer
- During VBLANK: walk sprite RAM, render all sprites into SDRAM buffer
- During active scan: read sprite pixels from SDRAM, composite with tilemaps
- Supports sprite trails feature (don't-clear flag) accurately
- Requires SDRAM bandwidth for both write (render) and read (scan) phases

**Option B: Scanline sprite engine (practical, common in FPGA cores)**
- During VBLANK: build per-scanline sprite lists (sprite scanner)
- During HBLANK (or next line's HBLANK): render active sprites into a pair of line buffers
- During active scan: read current line buffer, composite with tilemaps
- Loses sprite trails (unblit disable feature) — acceptable for most games
- Loses CPU access to sprite pixel data (not used by any known F3 game)

Option B is strongly recommended. The sprite trails effect in Darius Gaiden can be
approximated by retaining the previous line buffer rather than clearing it.

### 3.5 Sprite Depth

F3 sprites support 4, 5, or 6bpp per-sprite color depth via the extra_planes field in
command word 5. Priority groups and blend modes apply per-group (not per-tile).

---

## 4. Text and Pivot Layers

### 4.1 Text (VRAM) Layer

- 64×64 tile map of 8×8 4bpp CPU-writable characters
- Characters stored in Character RAM (0x61E000–0x61FFFF)
- Tile word encodes character code [10:0] and color [15:11]
- No scroll (position is fixed relative to screen)
- Typically used for overlay text, scores, credits
- Dirty tile tracking: only re-decoded tiles are updated per frame

### 4.2 Pivot (Pixel) Layer

- 64×32 tile map of 8×8 4bpp CPU-writable pixels, COLUMN-major scan order
- Data in Pivot RAM (0x630000–0x63FFFF)
- Controlled per-scanline via Line RAM §9.4 (enable, bank select, blend)
- Used for rotating/scaling backgrounds (Darius Gaiden lens, Gekirindan planet, etc.)
- Column-major scan means tile[0] = column 0, rows 0–31; tile[1] = column 0, rows 32–63
  (wraps to form a 512×256 continuous pixel canvas when rendered)
- Dirty tile tracking: mark_tile_dirty(offset >> 4) on any pivot_ram write

---

## 5. Scanline Compositing Pipeline

MAME's `scanline_draw()` processes groups of consecutive scanlines with identical priority/
alpha state. The hardware performs this in a single pass during active display.

### 5.1 Per-Pixel Compositing Order

For each pixel at (x, y), the pipeline evaluates all layers in priority order:

```
1. Collect priority values for this scanline from Line RAM:
   pf_prio[0..3], sprite_prio[0..3], pivot_prio
   blend modes, clip windows

2. For each layer in ascending priority order:
   a. Check clip planes: is pixel (x, y) within the active clip window for this layer?
      If outside: skip this layer for this pixel
   b. Fetch pixel from layer's line buffer or tilemap
   c. If pen == 0: transparent, skip
   d. Check priority: if this layer's priority > current dst_prio[x]: submit pixel
   e. If blend enabled: blend with current output using alpha formula
   f. Update src_prio[x], dst_prio[x] in priority buffer

3. Final output: the topmost committed non-transparent pixel
   (or background palette entry 0 if all layers transparent)
```

### 5.2 Priority Buffer

The 8-bit per-pixel `pri_alp_bitmap` tracks two nibbles:
- Upper nibble: `src_prio[x]` — priority of the most recently committed opaque pixel
- Lower nibble: `dst_prio[x]` — minimum priority to write into the blended destination

This double-nibble scheme allows the compositor to simultaneously track the "winning"
layer and the "background" layer for blending purposes.

### 5.3 Alpha Blend Formula

```
// Given alpha values A_src, A_dst (0–8) from Line RAM §9.5:
src_contribution = src_pixel[channel] * A_src / 8
dst_contribution = dst_pixel[channel] * A_dst / 8
output[channel] = min(255, src_contribution + dst_contribution)
```

The MAME dpix_n function table has 8 blend modes × 16 priority sub-variants = 128 total
dispatch cases, allowing the compositor to avoid per-pixel branching.

### 5.4 Mosaic Effect

When mosaic is enabled for a layer, the horizontal pixel coordinate is snapped to a
lower-resolution grid before tile/pixel fetch:

```
grid_x = H_START + ((screen_x - H_START + 114) % 432)
snapped_x = screen_x - (grid_x % sample_rate)
// sample_rate = lineRAM_mosaic_rate[y] + 1
```

This produces a blocky "pixelate" effect. The +114 offset and modulo-432 wrapping
account for the total scanline width and horizontal blanking offset.

---

## 6. FPGA Module Decomposition

Recommended SystemVerilog module breakdown:

```
tc0630fdp.sv          (top-level, instantiates all below)
├── tc0630fdp_ctrl.sv       — Display control register bank (0x660000)
│   - 16 × 16-bit registers: PF scroll X/Y, pixel scroll, extend mode
│   - Decoded outputs: pf_xscroll[4], pf_yscroll[4], extend_mode
│
├── tc0630fdp_lineram.sv    — Line RAM parser and per-scanline register distributor
│   - Input: 64KB Line RAM (CPU r/w port)
│   - Output: per-scanline structs fed to all layer engines
│   - Sections: rowscroll, colscroll, zoom, pal_add, clip, blend, priority, mosaic
│   - Critical path: must present scanline N's data before scanline N begins rendering
│
├── tc0630fdp_tilemap.sv    — PF1–PF4 tilemap engines (4 instances)
│   - Inputs: PF RAM read port, GFX ROM (16×16 tiles), line_inf struct
│   - Outputs: per-pixel {pen, palette, priority, blend_mode} stream
│   - Features: rowscroll, colscroll, zoom, pal_add, alt-tilemap, per-tile flip
│   - Uses a 2-cycle fetch pipeline: tile descriptor fetch → pixel output
│
├── tc0630fdp_text.sv       — Text (VRAM) layer engine
│   - Inputs: Text RAM, Character RAM (8×8 dynamic tiles)
│   - Outputs: per-pixel {pen, color} stream
│   - No scroll; dirty-tile mechanism needed for character decode cache
│
├── tc0630fdp_pivot.sv      — Pivot (pixel) layer engine
│   - Inputs: Pivot RAM (64×32, column-major), line_inf struct
│   - Outputs: per-pixel {pen, color, blend_mode, enable} stream
│   - Dirty-tile mechanism for pivot_ram decode cache
│
├── tc0630fdp_sprite.sv     — Sprite scanner and line buffer renderer
│   - Sub-modules:
│     tc0630fdp_sprite_scan.sv  — VBLANK sprite walker + tempsprite list builder
│     tc0630fdp_sprite_render.sv — Per-scanline line buffer renderer (HBLANK)
│   - Inputs: Sprite RAM (64KB), GFX ROM (16×16 tiles, 17-bit codes)
│   - Outputs: 320-pixel line buffer {pen, palette, priority}
│   - Features: 17-bit tile codes, zoom, multi-tile blocks, jump, 4 priority groups
│   - Dual line buffers (ping-pong): render into back buffer during HBLANK N,
│     read front buffer during active scan N+1
│
└── tc0630fdp_colmix.sv     — Layer compositor: clip, priority, alpha blend, output
    - Inputs: pixel streams from all 6 layer engines + priority line buffer
    - Inputs: per-scanline clip planes, blend coefficients, priority map
    - Output: 9-bit palette index stream → TC0650FDA DAC
    - Features: 4 clip planes, 4 blend modes, saturating alpha math
    - Critical: must handle all 128 dpix dispatch cases (8 blend × 16 priority)
```

### 6.1 Memory Requirements (FPGA on-chip BRAM)

| Memory Region | Size | BRAM Cost (Intel M10K @ 10Kb) |
|---------------|------|-------------------------------|
| Sprite RAM | 64KB | 64 M10K blocks |
| Playfield RAM | 48KB | 48 M10K blocks |
| Text RAM | 8KB | 8 M10K blocks |
| Character RAM | 8KB | 8 M10K blocks |
| Line RAM | 64KB | 64 M10K blocks |
| Pivot RAM | 64KB | 64 M10K blocks |
| Sprite line buffers (×2) | 2 × 320×(8+4+4) bits = ~2KB | 2 M10K blocks |
| Priority buffer | 320 × 8 bits = 320 bytes | 1 M10K block |
| **Total** | ~258KB | **~259 M10K blocks** |

The Cyclone V (DE10-Nano: 397 M10K) can fit all RAM on-chip with ~138 M10K to spare for
logic. Sprite RAM alone (64KB) consumes the most — it may be feasible to map sprite RAM
to SDRAM if on-chip budget is tight, accepting one extra SDRAM port.

**GFX ROMs** must live in SDRAM. F3 games typically have 8–32MB of sprite/tile ROM.

### 6.2 Critical Timing Challenges

1. **Line RAM parsing latency:** Line RAM data for scanline N must be fully decoded and
   distributed to all layer engines by the time scanline N's first pixel begins. With
   232 visible lines × ~65μs each and a 6.67 MHz pixel clock, there are 432 pixel clocks
   per scanline. The Line RAM parser has one full scanline (432 clocks) to prepare the
   next scanline's data — this is tight if SDRAM latency is involved.

2. **Sprite rendering bandwidth:** At 4096 possible sprites × 16×16 pixels × potential zoom
   = potentially millions of pixel operations per frame. A scanline-based approach limits
   this to "sprites touching this scanline" but zoom and large sprites can still stress
   the pipeline. Realistic F3 games use ~200–500 visible sprites per frame.

3. **Tilemap zoom per scanline:** Horizontal zoom changes the effective sample rate through
   the source tilemap, requiring a fractional X accumulator that resets per scanline. This
   is straightforward in RTL but must be implemented correctly for each of 4 layers.

4. **GFX ROM arbitration:** Multiple layers (4 playfields + sprite renderer + text + pivot)
   all need GFX ROM access. A round-robin arbiter with proper priority is needed, or
   separate ROM ports if the SDRAM controller supports multiple channels.

---

## 7. Gate 4 Test Strategy

The gate 4 test should use MAME as ground truth. Build a Python behavioral model
(`f3_model.py`) that mirrors MAME's rendering logic exactly, then generate test vectors
from known ROM states.

### 7.1 Behavioral Model API

```python
class TaitoF3Model:
    def write_ctrl(self, offset, data)          # display control regs
    def write_pf_ram(self, pf, offset, data)    # playfield RAM write
    def write_text_ram(self, offset, data)      # text RAM write
    def write_char_ram(self, offset, data)      # character RAM write (dirty flag)
    def write_line_ram(self, offset, data)      # line RAM write
    def write_pivot_ram(self, offset, data)     # pivot RAM write (dirty flag)
    def write_sprite_ram(self, offset, data)    # sprite RAM write
    def render_scanline(self, y) -> [320 ints]  # composited 9-bit palette indices
    def render_frame(self) -> [[int]]           # full 320×232 frame
```

### 7.2 Test Vector Progression

**Phase 1 — Control registers only:**
- Write PF scroll values, verify display control register decode
- No GFX ROM needed; test with solid-color tiles

**Phase 2 — Single tilemap layer:**
- Load a simple tile pattern into PF1 RAM + fake GFX ROM
- Verify tile decode, correct screen mapping, no scroll
- Expected pass rate: 95%+ (register decode is simple)

**Phase 3 — Global scroll:**
- Apply PF1_XSCROLL / PF1_YSCROLL, verify tile grid shifts correctly
- Test wrap-around at tilemap boundary (mod 512 / 1024)

**Phase 4 — Rowscroll:**
- Set Line RAM rowscroll for PF1, verify per-scanline X shift
- Use a vertical-stripe test pattern to make errors visible
- This tests the Line RAM parser pipeline timing

**Phase 5 — Per-scanline zoom:**
- Set Line RAM zoom to a non-unity value for a range of scanlines
- Verify tilemap horizontal stretch/shrink
- Test PF2/PF4 Y-zoom swap (the hardware-specific inversion)

**Phase 6 — Simple sprites (no zoom, no block):**
- Place 1 sprite at known position, verify pixel output
- Test flipX / flipY
- Test transparent pen 0 passthrough

**Phase 7 — Sprite zoom:**
- Apply x_zoom=0x80 (half size), verify output dimensions
- Test boundary conditions (zoom=0xFF → invisible, zoom=0x00 → full)

**Phase 8 — Multi-tile block sprites:**
- Configure a 2×2 block sprite, verify anchor + continuation tiles
- Test jump mechanism (word 6 jump bit + index)

**Phase 9 — Priority and compositing:**
- Load 2 layers at different priorities, verify top layer wins
- Test transparent pixel fallthrough
- Test priority=0 (lowest) vs priority=15 (highest)

**Phase 10 — Alpha blend:**
- Set blend mode 01 (normal), verify A_src/A_dst formula
- Compare pixel output to Python reference computation
- Test saturating add (output ≤ 255)

**Phase 11 — Clip planes:**
- Enable clip plane 0 for PF1, set left/right bounds
- Verify pixels outside window are blanked
- Test invert mode (clip complement)

**Phase 12 — Full frame regression:**
- Run 5 known game startup frames from RayForce and Elevator Action Returns
- Compare all 320×232 pixels to MAME frame dump
- These games use nearly all F3 features and serve as integration tests

### 7.3 Vector Format

```
# Control register write:
WRITE CTRL <offset_hex> <data_hex>

# Playfield RAM write:
WRITE PFRAM <pf_num> <offset_hex> <data_hex>

# Line RAM write:
WRITE LINERAM <offset_hex> <data_hex>

# Sprite RAM write:
WRITE SPRRAM <offset_hex> <data_hex>

# Expected scanline output:
EXPECT SCANLINE <y> <320 hex bytes space-separated>

# Expected frame output (binary pixel dump):
EXPECT FRAME <filename.bin>
```

---

## 8. Complexity Assessment

**TC0630FDP is Tier-4 (maximum complexity in this pipeline):**

| Feature | Complexity Driver |
|---------|------------------|
| 4 scrolling playfields | 4× all tilemap logic |
| Per-scanline zoom on all 4 PFs | Fractional accumulator, PF2/PF4 swap |
| Per-scanline rowscroll | Standard, but × 4 layers |
| Per-scanline colscroll (PF3/PF4 only) | Non-uniform layer feature |
| Per-scanline palette addition | Simple add, low complexity |
| 4/5/6 bpp tile depth + OR palette | Non-trivial GFX decode, PR #11788 quirk |
| 6 total layers | 6× compositor input channels |
| 4 clip planes | Per-pixel clip evaluation × 4 |
| Full alpha blend (4 modes) | 128-case dpix dispatch |
| 17-bit sprite tile codes | Large ROM space (128K+ tiles) |
| Sprite jump mechanism | Non-linear RAM walk |
| Multi-tile block sprites | Group state machine |
| Sprite trails (unblit) | Frame-persistent buffer |
| Mosaic / X-sample effect | Pixel coordinate snap |
| Alt-tilemap switching | Dual-bank PF3/PF4 |
| Bubble Memories alt line data | Double-buffered line RAM |
| Line RAM parser overhead | All 12 sections × 256 lines |

**Estimated Gate 4 first-pass rate:** 25–35% (matches pipeline baseline for complex chips).
The highest-risk areas are: priority/blend compositing (most logic), sprite block/jump
state machine, and the PF2/PF4 zoom swap.

---

## 9. Recommended Build Order

Build and validate each step against MAME before proceeding to the next.

```
Step 1: Skeleton + display control registers
  - tc0630fdp_ctrl.sv: 16-register bank
  - Stub output: solid color, verifies timing module only
  - Gate 4: verify pixel clock, H/V timing = 432×262, active area 320×232

Step 2: Single playfield (PF1) — global scroll only
  - tc0630fdp_tilemap.sv for PF1
  - tc0630fdp_colmix.sv stub (single-layer passthrough)
  - Gate 4: verify tile decode, scroll wrap, flip, 4bpp decode

Step 3: All 4 playfields — global scroll, no Line RAM
  - Replicate tc0630fdp_tilemap.sv × 4
  - tc0630fdp_colmix.sv: basic priority mux (no blend, no clip)
  - Gate 4: verify layer ordering with fixed priority values

Step 4: Text layer + Character RAM
  - tc0630fdp_text.sv
  - Dynamic character decode (dirty tile mechanism)
  - Gate 4: verify text overlay on top of PF

Step 5: Line RAM rowscroll
  - tc0630fdp_lineram.sv (rowscroll sections only)
  - Distribute per-scanline X offsets to PF tilemap engines
  - Gate 4: verify per-scanline scroll (use Bubble Symphony raster effect)

Step 6: Line RAM per-scanline zoom
  - Add zoom sections to tc0630fdp_lineram.sv
  - Fractional X accumulator in tilemap engine
  - Implement PF2/PF4 Y-zoom entry swap
  - Gate 4: verify horizontal zoom on a single playfield

Step 7: Colscroll and palette addition
  - Add colscroll to tc0630fdp_lineram.sv (PF3/PF4)
  - Palette offset adder in tilemap engine
  - Gate 4: verify per-tile palette cycling

Step 8: Simple sprites (no zoom, no block)
  - tc0630fdp_sprite_scan.sv: VBLANK sprite walker
  - tc0630fdp_sprite_render.sv: line buffer renderer
  - 4 priority groups → compositor
  - Gate 4: single-sprite position, flip, palette (RayForce player ship)

Step 9: Sprite zoom + block sprites + jump
  - Add zoom accumulator to sprite renderer
  - Block sprite group state machine
  - Jump mechanism in sprite scanner
  - Gate 4: verify with Kaiser Knuckle (large zoomed sprites)

Step 10: Clip planes
  - 4-plane clip evaluator in colmix
  - Normal and invert modes
  - Gate 4: verify Cleopatra Fortune gemstone clipping windows

Step 11: Alpha blend
  - 128-case dpix dispatch table in colmix
  - Per-scanline blend coefficients from Line RAM
  - Gate 4: verify Darius Gaiden weapon glow effect

Step 12: Pivot layer + mosaic
  - tc0630fdp_pivot.sv (column-major tile map, dynamic pixels)
  - Mosaic X-sample in colmix
  - Gate 4: Gekirindan planet background, Darius Gaiden lens

Step 13: Full integration
  - All layers active simultaneously
  - Full line RAM all sections parsed
  - Gate 4: 5-frame regression on RayForce + Elevator Action Returns
```

---

## 10. Known MAME Accuracy Issues

| Issue | Status | FPGA Impact |
|-------|--------|-------------|
| Per-line brightness alpha (0x6200 register) | Partially unemulated (MAME issue #10033) | Implement as documented, will match MAME's partial behavior |
| Darius Gaiden blend conflict | Emulated in PR #11811 | Implement: two-layer priority collision handling |
| Palette OR vs ADD (issue #11788) | Fixed | Implement as OR — critical for correct colors |
| Sprite trails (unblit) | Emulated in PR #11811 | Implement with line buffer retention flag |
| Bubble Memories alt line data | Emulated in PR #11811 | Implement alternate line RAM subsection |
| pbobble4/commandw clip inversion | Emulated, hardware quirk | Two-mode clip inversion support |
| PF2/PF4 zoom swap | Emulated | Must implement the swap in lineram parser |
| Timer INT3 exact timing | Per-game initialization only | Not critical for video accuracy |

---

## 11. Reuse from Other Taito Cores

| Component | Source | Reuse Type |
|-----------|--------|------------|
| TC0260DAR (palette/DAC) | TaitoF2_MiSTer rtl/tc0260dar.sv | Template only — F3 uses TC0650FDA |
| Screen timing module | Any Taito core | Direct reuse (same timing framework) |
| 68EC020 CPU | Generic or Motorola-family core | Needed — 68EC020 has 32-bit ALU + 020 instructions |
| ES5505 audio | Apple IIGS MiSTer core | Potential reuse — Apple IIGS uses ES5503 (close relative); ES5506 is used in some F3 games; availability unclear |
| TC0100SCN tilemaps | TaitoF2_MiSTer | Architecture reference only — F3 tilemap engine is larger |

**68EC020 note:** The 68EC020 is a subset of the 68020 (no memory management unit, 24-bit
external address bus). Any 68020 FPGA core that supports 32-bit data bus will work.
The extra instructions vs 68000 (CALLM, RTM, CHK2, CMP2, BFXXX bit-field ops, pack/unpack)
are used by F3 games and must be supported.

**ES5505 / ES5506 note:** Taito F3 uses the ES5506 in most games (the ES5505 is the
older variant). The Apple IIGS MiSTer core targets ES5503 (OTI format). An ES5506 FPGA
implementation would be valuable but is a separate engineering effort. Community effort
should be checked before reimplementing from scratch.
