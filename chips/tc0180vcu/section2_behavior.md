# TC0180VCU — Section 2: Behavioral Description & FPGA Implementation Plan

**Source:** MAME `src/mame/taito/tc0180vcu.cpp` (Nicola Salmoria / Jarek Burczynski)

---

## 1. Video Timing

**Resolution:** 320×240 visible, generated from a 512×256 framebuffer canvas
**Tilemap space:** 64×64 × 16px = 1024×1024 pixel scrolling canvas (wraps)
**TX space:** 64×32 × 8px = 512×256

Standard Taito video timing (from taito_b.cpp screen config):
- Pixel clock: 13.333 MHz (approximate)
- H-total: ~432 pixels, V-total: ~262 lines
- Active: 320×240

MAME comment: interrupts fire at VBLANK start (INTH) and ~8 lines later (INTL). Both are encoded externally through a PAL.

---

## 2. Sprite Rendering Pipeline

MAME implements sprite rendering as a software rasterizer that draws into a pixel framebuffer during VBLANK. For FPGA, this maps naturally to a scanline-sprite-engine pattern.

### 2.1 MAME Algorithm (verbatim reference)

```
vblank_update() called at VBLANK:
  1. If VIDEO_CTRL[0]=0: erase active framebuffer page to 0
  2. If VIDEO_CTRL[7]=0: flip framebuffer_page ^= 1
  3. Call draw_sprites() into framebuffer[active_page]

draw_sprites():
  Loop: offs from 0xCC0-8 down to 0, step 8 (16-bit word index, 8 words per sprite)
  → i.e., sprite 407 drawn first, sprite 0 drawn last (sprite 0 = highest priority)

  For each sprite:
    code  = spriteram[offs]
    color = spriteram[offs+1] & 0x3F (lower 6 bits)
    flipx = spriteram[offs+1][14]
    flipy = spriteram[offs+1][15]
    x     = sign_extend_10(spriteram[offs+2] & 0x3FF)
    y     = sign_extend_10(spriteram[offs+3] & 0x3FF)
    data  = spriteram[offs+5]  // big sprite word

    if data != 0 and not currently in big_sprite:
      // Start of a new big sprite group
      x_num = (data >> 8) & 0xFF  // columns - 1
      y_num = (data >> 0) & 0xFF  // rows - 1
      xlatch = x, ylatch = y
      zoomxlatch = spriteram[offs+4] >> 8
      zoomylatch = spriteram[offs+4] & 0xFF
      x_no = 0, y_no = 0
      big_sprite = true

    zoomx = spriteram[offs+4] >> 8
    zoomy = spriteram[offs+4] & 0xFF
    zx = (0x100 - zoomx) / 16  // tile pixel width
    zy = (0x100 - zoomy) / 16  // tile pixel height

    if big_sprite:
      // Override zoom and position from group anchor
      zoomx = zoomxlatch; zoomy = zoomylatch
      x = xlatch + (x_no * (0xFF - zoomx) + 15) / 16
      y = ylatch + (y_no * (0xFF - zoomy) + 15) / 16
      zx = xlatch + ((x_no+1) * (0xFF - zoomx) + 15) / 16 - x
      zy = ylatch + ((y_no+1) * (0xFF - zoomy) + 15) / 16 - y
      y_no++
      if y_no > y_num: y_no = 0; x_no++
      if x_no > x_num: big_sprite = false

    if zoomx != 0 or zoomy != 0:
      draw 16×16 tile with zoom, transparent pen 0, color palette = color*16
    else:
      draw 16×16 tile unscaled (zx=zy=1 at hardware pixel level), transparent pen 0
```

### 2.2 FPGA Sprite Engine Strategy

Unlike MAME's software rasterizer, an FPGA implementation should:

1. **During VBLANK:** Walk sprite RAM, build per-scanline sprite lists
2. **During HBLANK:** Render active sprites for the next scanline into a line buffer
3. **During active display:** Output line buffer pixels mixed with tilemap

This avoids the need for a large framebuffer in SDRAM. However, TC0180VCU's MAME model uses a true pixel framebuffer (accessible by CPU), so for accuracy the FPGA needs either:
- **Option A:** True framebuffer in SDRAM (accurate, CPU-accessible, ~128KB)
- **Option B:** Line buffer approximation (simpler, loses CPU framebuffer writes)

For Taito B games, the CPU framebuffer access is used only for Hit the Ice (clear on startup). Option B is sufficient for most games.

---

## 3. Tilemap Layer Behavior

### 3.1 BG / FG Scroll

```
Lines per scroll block (lpb) = 256 - ctrl[2+plane][15:8]
  (plane 0 = FG, plane 1 = BG)
Number of blocks = 256 / lpb

For scanline Y, scroll block = Y / lpb
scrollX = scrollram[plane*0x200 + block*2*lpb]
scrollY = scrollram[plane*0x200 + block*2*lpb + 1]
```

When lpb=256 (ctrl=0): one global scroll for entire screen.
When lpb=1 (ctrl=0xFF): per-scanline scroll (raster effects).

### 3.2 Tile Fetch

For each tile at map position (tx, ty):
```
tile_index = tx + ty * 64  (linear 64-wide map)
tile_code  = vram[bg_rambank[0] + tile_index]   (word)
attr_word  = vram[bg_rambank[1] + tile_index]   (word)
color      = attr_word[5:0]
flipX      = attr_word[14]
flipY      = attr_word[15]
```

### 3.3 TX Tilemap

```
tile_index = tx + ty * 64  (64×32 map)
tile_word  = vram[tx_rambank + tile_index]
color      = tile_word[15:12]
bank_sel   = tile_word[11]
tile_idx   = tile_word[10:0]
gfx_code   = (ctrl[4 + bank_sel] >> 8) << 11 | tile_idx
```

TX does not scroll (no scroll RAM entries). May be toggled by ctrl[6] page bit.

---

## 4. GFX ROM Format

Two GFX objects (from `gfxinfo`):
```
Object 0: charlayout (8×8, 4bpp planar)
  Bit planes: { 0, 8, RGN_FRAC(1,2), RGN_FRAC(1,2)+8 }
  → 4 planes interleaved as pairs within two ROM halves
  → 16 bytes per tile

Object 1: tilelayout (16×16, 4bpp planar, same plane layout but tiled 2×2 from charlayout)
  64 bytes per tile (4 × 16-byte char-blocks arranged 2×2)
```

Both BG/FG tiles and sprite tiles use tilelayout (16×16).
TX tiles use charlayout (8×8).

---

## 5. Layer Compositing

Composition happens per-pixel during active display:
```
// Collect pixel from each layer at current (x, y):
bg_pix = tilemap_pixel(BG, x + scrollX_BG, y + scrollY_BG)   // 0 = transparent
fg_pix = tilemap_pixel(FG, x + scrollX_FG, y + scrollY_FG)   // 0 = transparent
tx_pix = tilemap_pixel(TX, x, y)                              // 0 = transparent
sp_pix = framebuffer[page][x][y]                              // 0 = transparent

// Priority (VIDEO_CTRL[3]=1 mode, simplest):
// BG → FG → SP → TX
if tx_pix != 0: output tx_pix
elif sp_pix != 0: output sp_pix
elif fg_pix != 0: output fg_pix
elif bg_pix != 0: output bg_pix
else: output 0 (background color)

// Priority (VIDEO_CTRL[3]=0 mode, split sprites):
// BG → OBJ0 (sp_pix&0x10=0) → FG → OBJ1 (sp_pix&0x10≠0) → TX
if tx_pix != 0: output tx_pix
elif sp_pix != 0 and (sp_pix & 0x10) != 0: output sp_pix  // OBJ1 above FG
elif fg_pix != 0: output fg_pix
elif sp_pix != 0 and (sp_pix & 0x10) == 0: output sp_pix  // OBJ0 below FG
elif bg_pix != 0: output bg_pix
else: output 0
```

---

## 6. FPGA Design Decomposition

Recommended module breakdown for RTL:

```
tc0180vcu.sv  (top-level, instantiates all below)
├── tc0180vcu_regs.sv      — 16×16-bit control register bank + VRAM write decode
├── tc0180vcu_tilemap.sv   — BG/FG/TX tile fetch, scroll, pixel output
│     (per-scanline, uses VRAM read port)
├── tc0180vcu_sprite.sv    — Sprite scanner + line buffer renderer
│     (VBLANK scan → HBLANK render → line buffer read)
├── tc0180vcu_fb.sv        — Framebuffer: CPU r/w + sprite write + compositor read
│     (SDRAM or BRAM depending on available resources)
└── tc0180vcu_colmix.sv    — Layer compositor: priority mux + palette index output
```

**Memory requirements (on-chip BRAM vs SDRAM):**
- VRAM: 64KB (32K × 16-bit) → ~16 M10K blocks (Cyclone V: 5.6 Mb/block → fits)
- Sprite RAM: 6.4KB → ~3 M10K blocks
- Scroll RAM: 2KB → 1 M10K block
- Framebuffer: 128KB × 2 pages = 256KB → needs SDRAM (too large for on-chip BRAM)
- Line buffer: 320 × 8-bit × 2 banks = 640 bytes → on-chip

---

## 7. Gate 4 Test Strategy

The Python behavioral model (`vcu_model.py`) should implement:
1. `write_ctrl(offset, data)` — control register
2. `write_vram(offset, data)` — VRAM
3. `write_spriteram(offset, data)` — sprite RAM
4. `write_scrollram(offset, data)` — scroll RAM
5. `render_scanline(y) → [320 pixels]` — full composited scanline
6. `render_frame() → [[pixels]]` — full frame

Gate 4 vectors should cover:
- Register writes with VRAM content → verify tile decode
- Scroll offset application
- Single sprite placement, zoom=0
- Big sprite group assembly
- Priority modes (VIDEO_CTRL bit 3)
- Screen flip

---

## 8. Complexity Assessment

**TC0180VCU is a Tier-3 chip** (highest complexity in this pipeline so far):
- Multiple memory types (VRAM + sprite RAM + scroll RAM + framebuffer)
- Per-scanline scroll with variable block size
- Zoom sprite engine with big sprite groups
- Dual-layer priority with framebuffer
- Requires SDRAM for framebuffer (or line-buffer approximation)

**Recommended implementation order:**
1. Register bank + VRAM interface (Gate 1-3 on stub)
2. TX tilemap (simplest layer, no scroll)
3. BG/FG tilemap with global scroll
4. BG/FG per-line scroll
5. Simple sprite (no zoom, no big sprite)
6. Zoom sprite engine
7. Big sprite groups
8. Framebuffer double-buffer + CPU access

**Estimated Gate 4 pass rate:** 40–50% first pass (complex chip).
