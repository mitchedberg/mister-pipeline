# TC0200OBJ — Section 2: Behavioral Specification

## Source Reference

- MAME: `src/mame/taito/taito_f2_v.cpp` (draw_sprites function, David Graves, Bryan McPhail et al.)
- MAME: `src/mame/taito/taito_f2.h` (taitof2_state, f2_tempsprite struct)

## Core Function

The TC0200OBJ is a sprite rendering engine for Taito F2. It reads a list of sprite entries from
sprite RAM (written by the 68000 CPU), renders each sprite into a line buffer using tile data
from GFX ROM, and outputs 9-bit pixel data per clock during active display.

Key capabilities:
- 1024 sprites per frame (at 16 bytes each = 16 KB sprite RAM)
- Per-sprite zoom (0%–100% of 16×16 tile size, in 1/256 steps)
- BigSprite groups (arbitrary multi-tile sprites via chained entries)
- Color latching (adjacent sprites share a color code)
- Master scroll + extra scroll (sprite-relative coordinate offsets stored in sprite RAM)
- Double-buffered sprite RAM (CPU writes inactive bank; chip renders active bank)
- Screen flip

## Pipeline Phases

### Phase 1: VBLANK — Sprite List Parse (SIB Build)

During VBLANK, the chip processes all 1024 sprite entries:
1. Walk entries from index 0 to 1023 (offset 0 to 0x3FF0 in bytes, 16-byte stride)
2. For each entry, determine:
   - Is this a SPECIAL COMMAND entry? (Y_POS bit 15 = 1) → process control command, skip render
   - Is it a scroll-latch entry? (X_POS[15:12]=0xA or 0x5) → update master/extra scroll, skip render
   - Is it disabled? (sprites_disabled flag = 1) → skip
   - Is this the START of a BigSprite group? (continuation bit = 1, big_sprite was false)
   - Is this a continuation tile of a BigSprite group? (continuation bit = 1, big_sprite already true)
   - Is this a standalone sprite? (continuation bit = 0, not in a BigSprite group)
3. Compute screen-space position (with scroll offsets applied) and effective tile dimensions (with zoom)
4. For each sprite, record in SIB (Scanline Index Block):
   - Which scanlines it covers: [y_start, y_end)
   - Sprite index (for Phase 2 to look up tile code, color, flip, zoom)

### Phase 2: HBLANK — Line Buffer Render

For each scanline, during HBLANK, render all sprites covering that line:
- Process sprites back-to-front (lowest priority index first, highest last) to respect priority
- For each sprite:
  - Determine source y row: `src_y = ((scanline - y_start) * 16) / sprite_height`
  - Fetch tile row from GFX ROM at: `rom_addr = tile_code * 128 + src_y * 8 + col/2`
  - For each output x pixel (x_start to x_start + sprite_width - 1):
    - Source x: `src_x = (x_relative * 16) / sprite_width` (zoom decompressor)
    - If flipx: `src_x = 15 - src_x`
    - Extract 4-bit nibble from ROM data
    - If nibble ≠ 0: write {color[7:0], nibble[3:0]} to line buffer at output x
    - (Transparent if nibble = 0)

### Phase 3: Active Scan — Pixel Output

During active display (HBLANK = 0, pixel valid):
- Output line buffer[hcount - hstart] → pixel_out[8:0]
- Clear line buffer entries as they are read (for next frame)

## Sprite Entry Processing Detail

### Standalone Sprite (spritecont[3] = 0, not in BigSprite group)

```
zoomx = ZOOM[7:0]
zoomy = ZOOM[15:8]
sprite_w = (0x100 - zoomx) / 16   // 0..16, width in output pixels
sprite_h = (0x100 - zoomy) / 16   // 0..16, height in output lines

x = sign_extend(X_POS[11:0], 12) + scrollx  // 12-bit signed
y = sign_extend(Y_POS[11:0], 12) + scrolly  // 12-bit signed

if spritecont[2] == 0:   // color latch mode
    color = ATTR[7:0]    // use and latch this color
    color_latch = color
else:
    color = color_latch  // reuse previous color

flipx = spritecont[0]
flipy = spritecont[1]

code = tile_code_after_bank_remap(TILE_CODE)
```

### BigSprite Start (spritecont[3] = 1, previously not in group)

The first tile in a multi-tile group:
```
xlatch = X_POS[11:0]       // latch starting x for group
ylatch = Y_POS[11:0]       // latch starting y for group
x_no = 0, y_no = 0
zoomxlatch = ZOOM[7:0]
zoomylatch = ZOOM[15:8]
big_sprite = true
```

### BigSprite Continuation (spritecont[3] = 1, already in group)

Subsequent tiles in the group:
```
if spritecont[4] == 0: use ylatch (y coordinate comes from latch)
elif spritecont[5] == 1: y += 16; y_no++    // next row in group

if spritecont[6] == 0: use xlatch (x coordinate comes from latch)
elif spritecont[7] == 1: x += 16; y_no = 0; x_no++  // next column in group

// Zoomed position of this tile within the group:
x = xlatch + (x_no * (0xFF - zoomxlatch) + 15) / 16
y = ylatch + (y_no * (0xFF - zoomylatch) + 15) / 16
tile_w = x_pos[x_no+1] - x_pos[x_no]     // zoomed width of this tile
tile_h = y_pos[y_no+1] - y_pos[y_no]     // zoomed height of this tile
```

### BigSprite End

The last tile in a group has spritecont[3] = 0 (continuation bit clear). On this last tile:
- big_sprite remains true for the render of THIS tile
- big_sprite cleared AFTER rendering

### Control Entry (Y_POS bit 15 = 1)

```
if CTRL2[0] == 1:
    area = 0x8000   // switch active area to second bank

disabled = CTRL2[12]
flip_screen = CTRL2[13]
```

### Scroll Latch Entry (X_POS[15:12] == 0xA)

```
master_scrollx = sign_extend(X_POS[11:0], 12)
master_scrolly = sign_extend(Y_POS[11:0], 12)
(entry is consumed, sprite not rendered)
```

### Scroll Latch Entry (X_POS[15:12] == 0x5)

```
extra_scrollx = sign_extend(X_POS[11:0], 12)
extra_scrolly = sign_extend(Y_POS[11:0], 12)
(entry is consumed, sprite not rendered)
```

### Screen-Space X Offset (scrollx applied per sprite)

```
if X_POS[15] == 1:   // absolute
    scrollx = -x_offset - 0x60   // no scroll applied
elif X_POS[14] == 1:  // ignore extra scroll
    scrollx = master_scrollx - x_offset - 0x60
else:   // all scrolls
    scrollx = extra_scrollx + master_scrollx - x_offset - 0x60

scrolly = 0                  (if absolute)
scrolly = master_scrolly     (if ignore extra)
scrolly = extra_scrolly + master_scrolly  (if all scrolls)

x = sign_extend((X_POS[11:0] + scrollx), 12)
y = sign_extend((Y_POS[11:0] + scrolly), 12)
```

Note: x_offset = hide_pixels (game-specific: 0, 1, or 3). For FPGA, use 0 or expose as parameter.

## Tile ROM Access

Each 16×16 tile is stored as 128 bytes (2 bytes per row × 8 pixels/2 = 8 bytes, 16 rows):
```
row_addr = tile_code_banked * 128 + src_y_row * 8
// Each 32-bit ROM word contains 8 pixels (4 bits each):
// word[31:28]=px0, word[27:24]=px1, ..., word[3:0]=px7
// For flipx: reverse pixel order within each word
```

Tile bank remapping (sprite type 0, used by most games):
```
bank_index = tile_code[12:10]   // 3-bit bank selector (0-7)
within_bank = tile_code[9:0]    // 10-bit offset (0-1023)
banked_code = sprite_bank[bank_index] + within_bank
rom_addr = banked_code * 128 + src_y * 8
```

## Screen Resolution and Timing

```
Active display:    320 × 224 (hcount 64..383 × vcount 14..237)
Total frame:       512 × 262
VBLANK region:     vcount 0..13 and 238..261 (38 lines total)
HBLANK region:     hcount 0..63 and 384..511
```

## Reset Behavior

On reset:
- sprite RAM contents: indeterminate (CPU must initialize)
- sprites_disabled = 1 (safe default: no sprites displayed)
- master_scrollx, master_scrolly = 0
- extra_scrollx, extra_scrolly = 0
- flip_screen = 0
- big_sprite = 0
- color_latch = 0
- line buffer: cleared to transparent

## Interaction with Adjacent Chips

```
CPU (68000) --[A[15:1], WR, D[15:0]]--> TC0200OBJ sprite RAM
TC0200OBJ --[tile_addr[19:0]]--> GFX ROM
TC0200OBJ --[pixel[8:0]]--> TC0360PRI (priority mixer)
TC0360PRI --[composited pixel]--> TC0110PCR (palette lookup) --[R,G,B]--> DAC
TC0100SCN --[tilemap pixel]--> TC0360PRI
```

## Sprite Bank Remapping Table

8 banks, each pointing to a 1024-entry (0x400) window in the ROM address space:
```
spritebank[0..7] = starting GFX tile index for each bank
banked_code = spritebank[bank_index] + within_bank
```
Spritebank register at CPU address (game-specific, written via control registers):
```
bank pair 0&1:  spritebank[0] = value << 11, spritebank[1] = spritebank[0] + 0x400
bank pair 2&3:  spritebank[2] = value << 11, spritebank[3] = spritebank[2] + 0x400
banks 4..7:     individually: spritebank[i] = value << 10
```

## Known MAME Notes

- "The sprite system is still partly a mystery, and not an accurate emulation" — MAME source
- BigSprite zoom is approximate in MAME (16 effective zoom levels vs hardware's 256)
- Gunfront flame screen has noted zoom inaccuracy
- Some games leave sprites_disabled=1 forever (driftout) — previous frame enable state must be preserved
- Master scroll must persist from previous frame (driftout)
- Thunderfox has "tied-up" little sprites with spritecont=0x20 that are not actual BigSprites

## Implementation Notes for RTL

1. **Sprite RAM:** Two altsyncram M10K instances (dual-port), each 16KB.
   CPU writes one bank; sprite engine reads the other. Banks swap at VBLANK.

2. **SIB (Scanline Index Block):** During VBLANK, parse all 1024 sprite entries.
   Build a per-scanline list of up to MAX_SPRITES_PER_LINE entries each containing:
   {sprite_idx[9:0], y_start[8:0], sprite_h[4:0]} for the line renderer.

3. **Zoom rendering:** For each output pixel at x_out in [0, sprite_w):
   src_x = (x_out * 16) / sprite_w. Implement with 8-bit fixed-point accumulator.

4. **Line buffer:** Two line buffers (double-buffered); 320 entries × 9 bits.
   Render n-1 into buffer A while buffer B is being displayed, swap each line.

5. **ROM arbiter:** Sprite parser and line renderer share GFX ROM bus.
   Parser has priority during VBLANK. Renderer has priority during HBLANK.

6. **Sprite bank registers:** 8 × 16-bit registers, written by CPU at separate
   address range (game-specific base addresses, not inside sprite RAM).
