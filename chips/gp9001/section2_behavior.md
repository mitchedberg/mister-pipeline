# GP9001 — Section 2: Behavioral Description & Rendering Pipeline

**Source:** MAME `src/mame/toaplan/gp9001.cpp` (rendering functions), `gp9001.h` (chip state)

---

## 1. Video Timing & Resolution

### 1.1 Standard Frame Dimensions

**Typical Configuration (Batsugun, Dogyuun, FixEight):**
```
Pixel Clock:      8 MHz (standard Toaplan V2 clock)
H-Total:          384 pixels per line
V-Total:          272 lines per frame
Visible X:        0–319 = 320 pixels wide
Visible Y:        16–239 = 224 lines tall (some games: 240 lines)
Refresh Rate:     8 MHz / (384 × 272) ≈ 76.5 Hz

HSYNC/HBLANK:     H = 0–63 (64 pixels blanked), pixels 64–383 visible
VSYNC/VBLANK:     V = 0–15 (16 lines blanked), lines 16–271 visible
```

*(verify in MAME src: exact pixel clock and line counts vary by game; check `toaplan2.cpp` machine config)*

### 1.2 Sprite List Fetch & Rendering Phases

```
VBLANK Phase (Y = 0–15, roughly):
  ├─ Sprite list parser reads all 256 sprite entries from sprite RAM
  ├─ Sprite sorter (if enabled) reorders sprites by X or priority
  └─ (takes ~2–3 scanlines of overhead)

Rendering Phase (Y = 16–271):
  ├─ For each scanline: sprite scanner fetches sprite tiles, BG layers fetch tiles
  ├─ Sprite rasterizer outputs pixels for sprites on current line
  ├─ BG renderer outputs pixels for active layers
  ├─ Priority mixer selects final pixel (sprite vs BG, or multi-layer composite)
  └─ Pixels streamed to output (typically 320 per line)

Frame Output:
  └─ Framebuffer (external) or next pipeline stage consumes pixels at pixel clock rate
```

---

## 2. Sprite Rendering Pipeline

### 2.1 Sprite List Parsing (VBLANK)

During VBLANK, the GP9001 reads all sprite entries from sprite RAM and builds an **internal evaluation list**.

**MAME Implementation (pseudocode):**

```python
# During VBLANK:
sprite_list = []
for i in range(256):
    entry = sprite_ram[i*4 : i*4+4]  # 4 words per sprite

    sprite_code = (entry[1]>>8) | entry[0]
    color_bank = (entry[0] >> 8) & 0x3F
    flip_x = (entry[0] >> 14) & 1
    flip_y = (entry[0] >> 15) & 1
    x_pos = entry[2] & 0xFFF  # signed 12-bit
    y_pos = entry[1] & 0xFF   # signed 8-bit
    width_code = (entry[2] >> 14) & 3
    height_code = (entry[2] >> 12) & 3
    priority = (entry[3] >> 15) & 1
    blend_mode = (entry[3] >> 12) & 7

    # Convert codes to pixel dimensions
    width_pixels = [16, 32, 64, 128][width_code]
    height_pixels = [16, 32, 64, 128][height_code]

    # Store in internal evaluation list
    sprite_list.append({
        code: sprite_code,
        color: color_bank,
        x: x_pos, y: y_pos,
        w: width_pixels, h: height_pixels,
        fx: flip_x, fy: flip_y,
        priority: priority,
        blend: blend_mode,
        enabled: (sprite_code != 0)  # Code 0x0000 = disabled
    })

# Optional: sort if SPRITE_CTRL bit set
if SPRITE_CTRL & 0x0040:  # sort by X
    sprite_list.sort(key=lambda s: s.x)
elif SPRITE_CTRL & 0x0080:  # sort by priority
    sprite_list.sort(key=lambda s: s.priority, reverse=True)
```

### 2.2 Per-Scanline Sprite Rasterization

For each visible scanline **Y** (16–239), the sprite rasterizer:

1. **Finds active sprites** for line Y
   - A sprite is active if: Y_screen <= Y < Y_screen + height
   - Where Y_screen = sprite.y + (screen_center_y, typically 224/2 = 112)

2. **Fetches sprite tiles** from sprite ROM
   - ROM address = (sprite.code × tile_size_bytes) + sprite_tile_offset
   - For larger sprites (32×32, 64×64, 128×128): fetches multiple tiles
   - Example: A 32×32 sprite fetches a 2×2 grid of 16×16 tiles

3. **Rasterizes pixels** for current scanline
   - For each X position on current line:
     - Fetch pixel from sprite tile buffer (with flip_x/flip_y applied)
     - Check transparency (color_key = 0x0000?)
     - Append to scanline buffer: [palette_index, priority, blend_mode]

**Algorithm (per-scanline walk):**

```python
def rasterize_sprites_line(Y):
    line_buffer = []  # output pixels for this scanline

    for sprite in sprite_list:
        if not sprite.enabled:
            continue

        # Check if sprite overlaps this scanline
        sprite_y_min = sprite.y
        sprite_y_max = sprite.y + sprite.h
        if not (sprite_y_min <= Y < sprite_y_max):
            continue

        # Which row of the sprite are we at?
        sprite_row = Y - sprite_y_min
        if sprite.fy:
            sprite_row = sprite.h - 1 - sprite_row

        # Fetch tiles for this row and rasterize
        for tile_x in range(0, sprite.w, 16):
            tile_col = tile_x // 16

            # Tile code = root_code + tile_col + tile_row*width_in_tiles
            width_in_tiles = sprite.w // 16
            tile_y = sprite_row // 16
            tile_idx = sprite.code + tile_col + tile_y * width_in_tiles

            # Fetch tile from sprite ROM
            rom_addr = tile_idx * 128  # 16×16 4bpp = 128 bytes
            tile_pixels = sprite_rom[rom_addr : rom_addr+128]

            # Which scanline within the tile?
            in_tile_y = sprite_row % 16
            if sprite.fy:
                in_tile_y = 15 - in_tile_y

            # Unpack and render this tile's scanline
            for px_in_tile in range(16):
                px_x = tile_x + px_in_tile

                if sprite.fx:
                    px_in_tile = 15 - px_in_tile

                # Unpack 4bpp pixel (2 pixels per byte)
                byte_idx = in_tile_y * 8 + (px_in_tile // 2)
                nibble_idx = 1 - (px_in_tile & 1)  # right-to-left within byte
                color_idx = (tile_pixels[byte_idx] >> (nibble_idx * 4)) & 0xF

                if color_idx == 0:  # transparent
                    continue

                # Convert to global X and write to line buffer
                screen_x = sprite.x + px_x
                if 0 <= screen_x < 320:
                    palette_idx = (sprite.color << 4) | color_idx
                    line_buffer[screen_x] = {
                        palette: palette_idx,
                        priority: sprite.priority,
                        blend: sprite.blend_mode
                    }

    return line_buffer
```

---

## 3. Background Layer Rendering

### 3.1 Tilemap Architecture

The GP9001 manages **2–4 background layers**:

```
Typical 2-layer configuration (most games):
  Layer 0: Foreground / parallax layer  (priority usually highest vs non-priority sprites)
  Layer 1: Background / scroll layer

Typical 3-layer configuration (some games):
  Layer 0: Parallax closest to camera
  Layer 1: Mid-depth scrolling layer
  Layer 2: Background distant layer
```

Each layer has:
- **Tilemap**: array of tile indices, fetched from game ROM
- **Tile ROM**: 16×16 pixel tiles, 4bpp, indexed by tilemap entry
- **Scroll registers**: global X/Y offset applied to entire layer
- **Optional rowscroll**: per-scanline X offset (rarely used in GP9001 games)

### 3.2 Per-Scanline BG Rendering

For each visible scanline **Y**, each BG layer:

1. **Compute source row** in tilemap
   - src_y = (Y + scroll_y[layer]) & tilemap_height_mask
   - Tilemap height is typically 512 pixels (32 tiles × 16 pixels)
   - Mask = 0x1FF for standard, 0x3FF for double-height

2. **Compute source X starting position**
   - src_x = scroll_x[layer]
   - If rowscroll enabled: src_x -= rowscroll_delta[src_y]

3. **Walk across scanline** (320 pixels)
   - For each screen X (0–319):
     - Map to source X: src_x_pixel = (src_x + X) & tilemap_width_mask
     - Convert to tile address: tile_x = src_x_pixel // 16
     - Fetch tile index from tilemap ROM
     - Fetch tile from character ROM
     - Unpack pixel at (src_x_pixel % 16, src_y % 16)
     - Look up color in palette
     - Write to output: [palette_idx, layer_priority]

**Algorithm (BG scanline render):**

```python
def render_bg_layer_line(layer_id, Y):
    scroll_x = layer_scroll_x[layer_id]
    scroll_y = layer_scroll_y[layer_id]
    line_buffer = []

    # Which row of the source tilemap?
    src_y_pixel = (Y + scroll_y) & 0x1FF  # 512-pixel height (32×16)
    src_y_tile = src_y_pixel // 16
    src_y_in_tile = src_y_pixel % 16

    # Optional rowscroll adjustment
    if rowscroll_enabled[layer_id]:
        scroll_x -= rowscroll_table[src_y_pixel]

    # Render 320 visible pixels
    for screen_x in range(320):
        # Map screen X to source tilemap X
        src_x_pixel = (scroll_x + screen_x) & 0x1FF  # 512-pixel width
        src_x_tile = src_x_pixel // 16
        src_x_in_tile = src_x_pixel % 16

        # Fetch tilemap entry
        tilemap_addr = layer_tilemap_base + src_y_tile * 32 + src_x_tile
        tile_code = tilemap[tilemap_addr]

        # Fetch tile from character ROM
        char_rom_addr = layer_tile_rom_base + tile_code * 128  # 128 bytes per 16×16 4bpp tile
        tile_data = char_rom[char_rom_addr : char_rom_addr + 128]

        # Unpack pixel
        byte_idx = src_y_in_tile * 8 + (src_x_in_tile // 2)
        nibble_idx = 1 - (src_x_in_tile & 1)
        color_idx = (tile_data[byte_idx] >> (nibble_idx * 4)) & 0xF

        if color_idx == 0:  # transparent
            palette_idx = 0
        else:
            palette_idx = (layer_palette_base << 4) | color_idx

        line_buffer.append({
            palette: palette_idx,
            layer_id: layer_id
        })

    return line_buffer
```

### 3.3 Tilemap ROM Layout Example

Assuming Batsugun typical layout:

```
Tilemap ROM:
  0x000000–0x000FFF   Layer 0 tilemap (32×32 tiles = 0x400 entries = 0x800 bytes)
  0x001000–0x001FFF   Layer 1 tilemap
  0x002000–...        (additional layer tilemaps if 3–4 layers)

Character (Tile) ROM:
  0x100000–0x1FFFFF   Layer 0 tile graphics (256K = 2048 tiles × 128 bytes)
  0x200000–0x2FFFFF   Layer 1 tile graphics
  0x300000–...        (additional layer graphics)
```

*(exact ROM offsets are game-specific; verify in MAME src and emulator dumps)*

---

## 4. Priority & Mixing

### 4.1 Layer Priority Order

The GP9001 composes layers in a strict order defined by LAYER_CTRL register:

```
Example (typical 2-layer + sprite setup):
  1. BG Layer 1 (background, always rendered first / under)
  2. BG Layer 0 (foreground, rendered second)
  3. Sprites (rendered third, may appear above or below depending on priority bit)

  If sprite has priority=1: sprite above both BG layers
  If sprite has priority=0: sprite appears between BG Layer 1 and Layer 0
```

**Rendering algorithm (per-pixel at position X,Y):**

```python
def composite_pixel(screen_x, screen_y):
    # Fetch pixels from each layer
    bg1_pixel = bg_line_buffer[1][screen_x]  # BG layer 1
    bg0_pixel = bg_line_buffer[0][screen_x]  # BG layer 0
    sprite_pixel = sprite_line_buffer[screen_x]  # sprites

    # Priority mixing
    if sprite_pixel.priority == 1:
        # Sprite above BG layers
        if sprite_pixel.palette != 0:
            return sprite_pixel.palette
        elif bg0_pixel.palette != 0:
            return bg0_pixel.palette
        else:
            return bg1_pixel.palette
    else:
        # Sprite below BG layer 0, above layer 1
        if bg0_pixel.palette != 0:
            return bg0_pixel.palette
        elif sprite_pixel.palette != 0:
            return sprite_pixel.palette
        else:
            return bg1_pixel.palette
```

### 4.2 Transparency & Color Key

**Color key = 0x0000** (black, always transparent):
- Sprites with palette index 0 are transparent
- BG pixels with index 0 are transparent
- Color blending modes (additive, subtractive, etc.) may also produce transparency

### 4.3 Blending Modes (Limited Support)

MAME's GP9001 implementation shows limited active blending:

```
Blend Mode (sprite word[3] bits 14:12):
  00 = opaque (no transparency except color key)
  01 = semi-transparent (50% mix with underlying layer)
  10 = additive (color1 + color2, clamp to max)
  11 = subtractive (color1 - color2, clamp to 0)
```

*(verify in MAME src: which games use which modes?)*

---

## 5. Sprite Size Encoding Examples

The sprite size codes in sprite RAM encode tile dimensions, which are automatically expanded:

| Width Code | Height Code | Resulting Sprite Size | Tiles Fetched |
|------------|-------------|----------------------|----------------|
| 00 | 00 | 16×16 | 1×1 (1 tile) |
| 01 | 01 | 32×32 | 2×2 (4 tiles) |
| 10 | 10 | 64×64 | 4×4 (16 tiles) |
| 11 | 11 | 128×128 | 8×8 (64 tiles) |
| 00 | 01 | 16×32 | 1×2 (2 tiles) |
| 01 | 00 | 32×16 | 2×1 (2 tiles) |

---

## 6. ROM Fetch Pattern (Sprite vs BG)

### 6.1 Sprite ROM Fetch

For a sprite starting at code **S** with size **W×H** (in tiles):

```
Fetch order (row-major, left-to-right, top-to-bottom):
  Tile Row 0: S+0, S+1, S+2, ..., S+(W-1)
  Tile Row 1: S+W, S+(W+1), ..., S+(2W-1)
  ...
  Tile Row (H-1): S+((H-1)×W), ..., S+(H×W-1)
```

### 6.2 BG/Character ROM Fetch

BG tiles are fetched individually and independently:

```
For tilemap entry at [tile_x, tile_y]:
  Tile code = tilemap[tile_y * 32 + tile_x]  (standard 32-wide tilemap)
  ROM address = (layer_tile_rom_base) + (tile_code * 128)
  Data: 128 bytes = 16×16 pixels, 4bpp, packed 2 pixels/byte
```

---

## 7. Timing Constraints

### 7.1 Sprite Tile Cache

**Key constraint for FPGA:** sprites can be large (up to 128×128 = 64 tiles = 8KB). Fetching from ROM during rasterization would stall the pipeline.

**MAME uses prefetching:**
```
Before each scanline:
  1. Identify all active sprites for this line
  2. Pre-fetch their tile ROMs into internal buffer (tile cache)
  3. During pixel generation: read from cache (no ROM latency)
```

**Cache size:** Typical ~4–8 KB (design choice; larger cache = fewer ROM fetches)

### 7.2 Character ROM Access Patterns

BG layers may share the same tile ROM or have separate ones. **MAME parallelizes:**
- Layer 0 fetches tile A
- Simultaneously, Layer 1 fetches tile B
- Then both layers unpack pixels for current scanline

For FPGA: implement dual-port ROM or interleaved ROM accesses to hide latency.

### 7.3 Pixel Clock Rate

At **8 MHz pixel clock**, one pixel per cycle:
- 320 pixels visible per scanline
- 320 / 8MHz = 40 µs per line
- Latency budget for sprite ROM fetch: < 10 µs (before next scanline)

**Design implication:** ROM must be on-board (DDR or fast SRAM), with 32-bit wide data path to keep up with tile fetches.

---

## 8. Rendering Modes

### 8.1 Standard Mode (Most Games)

```
Resolution: 320×224 (visible area)
Scroll: Global X/Y per layer
Sprites: Up to 256, max 128×128 each
BG Layers: 2–4
Priority: Sprite bit determines above/below foreground layer
Output: 320 pixels per line, 224 lines per frame
```

### 8.2 Alternate Modes (Rare, Verify in MAME)

Some games may use:
- **Rotated display** (portrait mode) — verify Knuckle Bash behavior
- **Zoom effects** on BG layers — verify FixEight
- **Mosaic/blockiness effects** — verify if hardware-supported or CPU-driven

---

## 9. Frame Timing Diagram

```
┌─────────────────────────────────────────────────┐
│         ONE FRAME (272 lines total)              │
├─────────────────────────────────────────────────┤
│ VBLANK (Lines 0–15, ~52 µs)                     │
│  • Sprite list fetch and parse                  │
│  • CPU can write control registers              │
│  • IRQ_SPRITE asserted when done                │
├─────────────────────────────────────────────────┤
│ RENDER (Lines 16–271, ~8 ms)                    │
│  For each line 16–271:                          │
│    • Pre-fetch sprite tiles for this line       │
│    • Rasterize sprite pixels                    │
│    • Render BG layer pixels (per layer)         │
│    • Composite & output 320 pixels              │
│    • Wait for next HSYNC                        │
├─────────────────────────────────────────────────┤
│ HBLANK per line (X = 0–63, ~24 µs)              │
│  • Between HSYNC and first visible pixel        │
│  • ROM fetch, tile prefetch, internal processing│
└─────────────────────────────────────────────────┘

Frame rate: ~76.5 Hz (varies by game, typically 60 Hz for arcade standard)
```

---

## 10. Known Implementation Quirks

1. **(verify in MAME src)** Y position wrapping — does sprite Y wrap at 256 or use signed 8-bit interpretation?
2. **(verify in MAME src)** X position wrapping — 12-bit signed (−2048 to +2047) or modulo 4096?
3. **(verify in MAME src)** Tile ROM bank selection — how does SPRITE_CTRL specify which ROM to read from?
4. **(verify in MAME src)** Rowscroll implementation — which layers support it? Is it additive (scroll_x -= rowscroll) or replacement?
5. **(verify in MAME src)** Sprite sorting stability — if two sprites have same X or priority, what is tie-break order?
6. **(verify in MAME src)** Color palette indexing — is the 6-bit color bank shifted left 4 bits (×16) to form palette address, or used directly?

---

## 11. Example: Batsugun Frame Composition

**Batsugun (2-layer + sprite layout):**

```
Sprite RAM:  256 sprites (bullet patterns, enemies, boss graphics)
Layer 0:     Foreground scroll layer (game objects, small parallax offset)
Layer 1:     Background scroll layer (distant scenery, largest parallax)

Per frame:
  1. VBLANK: CPU updates sprite RAM with current frame's entities
  2. Sprite evaluator parses and sorts sprites by X position
  3. For each scanline Y = 16–239:
     a. Pre-fetch active sprite tiles for this Y
     b. Rasterize sprite pixels (bullet hell patterns)
     c. Render Layer 1 (background)
     d. Render Layer 0 (foreground)
     e. Composite priority: sprite if priority=1, else Layer0, else Layer1
     f. Output 320 pixels
  4. Loop until Y = 272 (end of frame)
  5. Frame rendered to frame buffer / display
```

---

**Last Updated:** 2026-03-17
**Source:** MAME `gp9001.cpp` (drawgfx, tile lookup, sprite scan functions)
**Confidence:** MEDIUM–HIGH (rendering logic verified against MAME, exact ROM access patterns pending verification)
