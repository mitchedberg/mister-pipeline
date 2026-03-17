# TC0370MSO + TC0300FLA — Section 1: Sprite RAM Format, GFX Decode, and Rendering Algorithm

**Source:** MAME `src/mame/taito/taito_z.cpp` + `taito_z_v.cpp` (Nicola Salmoria),
Taito Z integration plan `chips/taito_z/integration_plan.md`
**Systems:** All Taito Z games using TC0370MSO: Bshark, SCI, Double Axle, Racing Beat
(earlier games use TC0050VDZ or TC0170ABT alone)
**Status:** Research complete — no FPGA implementation exists as of 2026-03.

---

## 1. Chip Overview

The TC0370MSO ("Motion Objects") and TC0300FLA are the sprite scanner and line buffer chips
on the Taito Z video PCB. Together they implement a per-frame sprite renderer that:

1. Scans sprite RAM (CPU-written, 4 words per entry) each VBlank
2. For each active sprite, reads 32 chunk codes from the spritemap ROM
3. For each 16×8 chunk, fetches pixels from the OBJ GFX ROM
4. Renders chunks to a line buffer with zoom and flip, masking by priority level
5. Outputs a priority-tagged pixel stream composited with TC0480SCP and TC0150ROD

From CPU A's perspective there are no chip registers — only sprite RAM (plain R/W RAM at
`0xC00000–0xC03FFF` in dblaxle). The chips scan sprite RAM autonomously every frame.

### Chip Roles

| Chip       | PCB     | Role                                                                  |
|------------|---------|-----------------------------------------------------------------------|
| TC0170ABT  | CPU PCB | Motion Object Generator — present on CPU PCB (between 68000 and TC0140SYT). Role appears to be sprite address transformation / bank routing. Not register-visible to CPU A. |
| TC0370MSO  | Video PCB | Motion Objects scanner — reads sprite RAM + spritemap ROM, drives pixel pipeline |
| TC0300FLA  | Video PCB | Line buffer / pixel output stage — paired with TC0370MSO, stores scanline pixels |

**TC0170ABT assessment:** From the address map, CPU A has no window into TC0170ABT —
it is passive from the CPU's perspective, similar to address routing glue. For FPGA
purposes it can be omitted; the sprite scanner behavior is fully captured by the
sprite RAM format and MAME rendering functions.

---

## 2. Sprite RAM Format (4 words = 8 bytes per entry)

Sprite RAM: `0xC00000–0xC03FFF` (dblaxle), `0xB00000–0xB03FFF` (racingb).
Total size: 16KB = 0x4000 bytes = 0x2000 words = 0x800 sprite entries maximum.

Note: the MAME comment says "mostly unused" for dblaxle — only a fraction of the 0x800
entries are active each frame. The iterator in `bshark_draw_sprites_16x8` scans all
`m_spriteram.bytes() / 2 - 4` = `0x2000 - 4` words, stepping back by 4 (one entry) at
a time. Entries with `tilenum == 0` are skipped.

### Word +0: Y Position + ZoomY

```
Bits [15:9]   ZoomY (7 bits, 0–63 effective after +1 correction)
              Raw value 0–62 → effective zoom 1–63
              Zoom = 0 (raw) → effective 1 = maximum shrink (~1 pixel tall)
              Zoom = 62 (raw) → effective 63 = ~64 pixels tall (near full height)
              Zoom = 63 (raw) → effective 64 = nominal 64 pixels tall (no shrink)
Bit  [8]      Y position bit 8 (sign/overflow bit)
Bits [7:0]    Y position bits 7:0
              Combined: y = data & 0x01ff  (9-bit, range 0–511)
              Sign extension: if y > 0x140 → y -= 0x200  (signed −0xC0..+0x140)
```

### Word +1: Priority + Color + ZoomX

```
Bit  [15]     Priority: 0 = above road (primask 0xf0), 1 = below road (primask 0xfc)
Bits [14:7]   Color palette bank (8 bits, 0–255)
              Used directly as the color argument to prio_zoom_transpen()
              Selects 16-color palette block: palette_base = color * 16
Bit  [6]      (unused — bit 6 of word +1 is masked out of color and zoomx)
Bits [5:0]    ZoomX (6 bits, 0–63 effective after +1 correction)
              Same encoding as ZoomY: raw + 1 = effective zoom
```

### Word +2: Flip + X Position

```
Bit  [15]     FlipY: 1 = flip sprite vertically
Bit  [14]     FlipX: 1 = flip sprite horizontally
Bits [13:9]   (unused)
Bit  [8]      X position bit 8
Bits [7:0]    X position bits 7:0
              Combined: x = data & 0x01ff  (9-bit, range 0–511)
              Sign extension: if x > 0x140 → x -= 0x200  (signed −0xC0..+0x140)
```

### Word +3: Tile Number (STY spritemap index)

```
Bits [15:13]  (unused, masked out)
Bits [12:0]   Tile number (13 bits, 0–8191)
              0 = skip this sprite (no draw)
              Non-zero → spritemap ROM address = tilenum << 5 (× 32 entries)
```

### Full entry layout summary

```
Offset  Field           Bits     Range    Notes
+0      ZoomY           [15:9]   0–63     raw; effective = raw + 1
+0      Y position      [8:0]    0..511   signed if > 0x140
+1      Priority        [15]     0–1      0=above road, 1=below road
+1      Color bank      [14:7]   0–255    palette block selector
+1      ZoomX           [5:0]    0–63     raw; effective = raw + 1
+2      FlipY           [15]     0–1
+2      FlipX           [14]     0–1
+2      X position      [8:0]    0..511   signed if > 0x140
+3      Tile number     [12:0]   0–8191   0 = inactive entry
```

---

## 3. Spritemap ROM Format (STY ROM)

**Size:** 512KB (0x80000 bytes = 0x40000 16-bit words)
**CPU A bus:** not directly accessible — ROM is read by TC0370MSO chip
**SDRAM offset (proposed):** 0x680000 (from integration plan §7.4)

The spritemap ROM is a lookup table that maps a logical sprite number to 32 tile codes.
Each tile code is a 16-bit word indexing the OBJ GFX ROM.

### Access pattern

```
map_offset = tilenum << 5     // tile number × 32 words = start of this sprite's chunk table
code[chunk] = spritemap[map_offset + chunk_index]
```

where `chunk_index` = `px + (py << 2)` (0..31, for a 4×8 arrangement).

### Chunk table layout (32 entries × 16-bit = 64 bytes per sprite)

```
Entry index  = px + (py * 4)  where px ∈ {0,1,2,3}, py ∈ {0,1,2,3,4,5,6,7}
                                     (4 columns wide × 8 rows tall = 32 chunks)

0x0000..0xFFFE  = valid GFX ROM tile code
0xFFFF          = invalid/blank chunk (skip rendering this chunk)
```

With flip:
```
px = flipx ? (3 - k) : k        // k = chunk column index 0..3
py = flipy ? (7 - j) : j        // j = chunk row index 0..7
```

### Addressing arithmetic

Maximum tile number: 0x1FFF (13 bits).
Maximum spritemap address: 0x1FFF << 5 = 0x3FFE0, i.e., word 0x3FFE0–0x3FFFF.
This fits within the 512KB ROM (0x40000 words). No bank switching needed.

---

## 4. OBJ GFX ROM Format (64-bit Interleave)

**Size:** 4MB (0x400000 bytes) — four 1MB ROMs interleaved
**ROM load macro:** `ROM_LOAD64_WORD_SWAP`
**Tile format:** 16×8 pixels, 4 bits per pixel (4bpp)

### ROM loading (dblaxle, from MAME ROM declarations)

```cpp
ROM_LOAD64_WORD_SWAP( "c78-08.25", 0x000000, 0x100000 )  // bits [15: 0] of 64-bit word
ROM_LOAD64_WORD_SWAP( "c78-07.33", 0x000002, 0x100000 )  // bits [31:16]
ROM_LOAD64_WORD_SWAP( "c78-06.23", 0x000004, 0x100000 )  // bits [47:32]
ROM_LOAD64_WORD_SWAP( "c78-05.31", 0x000006, 0x100000 )  // bits [63:48]
```

This produces a 4MB region where every 8 bytes = one 64-bit word assembled from four 16-bit
ROM contributions.

### gfx_layout (from MAME `tile16x8_layout`)

```c
static const gfx_layout tile16x8_layout = {
    16, 8,              // 16 pixels wide, 8 pixels tall
    RGN_FRAC(1,1),      // total tiles = region_size / bytes_per_tile
    4,                  // 4 bits per pixel
    { STEP4(0,16) },    // plane offsets: bits 0,16,32,48 (one plane per 16-bit ROM word)
    { STEP16(0,1) },    // x offsets: bits 0,1,2,...,15 within a row (16 pixels from 16 bits)
    { STEP8(0,16*4) },  // y offsets: rows start at byte 0, 8, 16, ..., 56 (8 rows)
    64 * 8              // bytes per tile: 64 bytes
};
```

### Decoding a 16×8 tile

One tile = 64 bytes = 512 bits.

The 4 planes are each 16 bits wide × 8 rows = 16 bytes per plane.
Plane layout in the 64-byte tile:

```
Bytes  0–15:   plane 0 (bits [15:0] of each 64-bit word row)
Bytes 16–31:   plane 1 (bits [31:16])
Bytes 32–47:   plane 2 (bits [47:32])
Bytes 48–63:   plane 3 (bits [63:48])
```

Within each plane row (2 bytes = 16 bits), pixel x=0 is at bit 0 (LSB), pixel x=15 at bit 15.

To reconstruct the 4-bit pixel at position (x, y) within a tile:

```
byte_base = tile_code * 64
row_base  = byte_base + y * 8    // 8 bytes per row (2 bytes × 4 planes)
// But STEP layout: y offset = y * (16*4) bits = y * 64 bits = y * 8 bytes from bit 0

For pixel (x, y):
  plane_bit_addr = y * (16*4) + x   // in bits from tile start
  plane 0 pixel bit: plane_bit_addr + 0*16  = y*64 + x
  plane 1 pixel bit: plane_bit_addr + 1*16  = y*64 + x + 16
  plane 2 pixel bit: plane_bit_addr + 2*16  = y*64 + x + 32
  plane 3 pixel bit: plane_bit_addr + 3*16  = y*64 + x + 48

  pixel_value = { plane3_bit, plane2_bit, plane1_bit, plane0_bit }  (4 bits)
  pixel_value == 0 → transparent (pen 0)
  pixel_value 1–15 → opaque, palette_index = color_bank * 16 + pixel_value
```

### FPGA ROM fetch granularity

In FPGA, the OBJ ROM is in SDRAM (4MB). The sprite scanner fetches one row of a tile at a
time. One tile row = 16 pixels at 4bpp = 8 bytes = one 64-bit fetch. The SDRAM arbiter
should support 64-bit (2-cycle 32-bit) reads for this chip.

Tile address in ROM bytes:

```
byte_addr = tile_code * 64 + y_row * 8
```

Maximum tile_code from spritemap is bounded by the 4MB ROM: 4MB / 64 bytes = 65536 tiles.
The tile_code field in the spritemap is 16 bits — all values representable.

---

## 5. Sprite Dimensions and Rendering Geometry

Each logical sprite (one 4-word RAM entry) consists of **32 chunks** arranged in a **4×8 grid**.

```
Sprite = 4 columns × 8 rows of 16×8 chunks
       = 64 pixels wide × 64 pixels tall (before zoom)
```

### Zoom scaling

The zoom fields scale the rendered size from the nominal 64×64.

```
zoomx_eff = zoomx_raw + 1    // 1–64
zoomy_eff = zoomy_raw + 1    // 1–64

// Y center adjustment: full-height sprite (zoomy_eff=64) has y offset = 0.
// Smaller sprites are shifted down: y += (64 - zoomy_eff)
y += (64 - zoomy_eff)

// Per-chunk screen position (k = col 0..3, j = row 0..7):
curx = x + ((k * zoomx_eff) / 4)
cury = y + ((j * zoomy_eff) / 8)

// Per-chunk rendered size (zoom for prio_zoom_transpen):
tile_width_pixels  = x + (((k+1) * zoomx_eff) / 4) - curx
tile_height_pixels = y + (((j+1) * zoomy_eff) / 8) - cury

// MAME zoom arguments (16.16 fixed point in prio_zoom_transpen):
zx_arg = tile_width_pixels  << 12   // scales 16-pixel source to tile_width_pixels
zy_arg = tile_height_pixels << 13   // scales 8-pixel source to tile_height_pixels
                                     // (note: zy << 13 not << 12 due to 8px source height)
```

At nominal zoom (zoomx_eff = zoomy_eff = 64):
- Each column: width = 64/4 = 16 pixels (exact 1:1)
- Each row: height = 64/8 = 8 pixels (exact 1:1)
- Total sprite: 64×64 pixels

At half zoom (32):
- Column width ≈ 8 pixels, Row height ≈ 4 pixels
- Total sprite: 32×32 pixels

---

## 6. Rendering Algorithm

### Scan order

Sprites are scanned **back-to-front** (reverse order, from last entry to first).
Entry with highest array index is drawn first (lowest visual priority / furthest back).
Entry at index 0 is drawn last (highest visual priority / frontmost).

```cpp
for (int offs = m_spriteram.bytes() / 2 - 4; offs >= 0; offs -= 4) {
    // ... process sprite at offs
}
```

This matches standard reverse-scan sprite rendering: later entries in RAM = lower priority.

### Per-sprite algorithm

```
for each sprite entry (scanned back-to-front):

  1. Read 4 words from sprite RAM
  2. Extract: zoomy, y, priority, color, zoomx, flipy, flipx, x, tilenum

  3. if tilenum == 0: skip (inactive entry)

  4. map_offset = tilenum << 5
  5. zoomx_eff = zoomx + 1;  zoomy_eff = zoomy + 1
  6. y += y_offs;  y += (64 - zoomy_eff)
  7. if x > 0x140: x -= 0x200    (sign extend)
  8. if y > 0x140: y -= 0x200    (sign extend)

  9. for sprite_chunk = 0 to 31:
       k = sprite_chunk % 4    (column 0..3)
       j = sprite_chunk / 4    (row 0..7)

       px = flipx ? (3-k) : k  (chunk column with flip)
       py = flipy ? (7-j) : j  (chunk row with flip)

       code = spritemap[map_offset + px + (py << 2)]
       if code == 0xffff: skip this chunk

       curx = x + ((k * zoomx_eff) / 4)
       cury = y + ((j * zoomy_eff) / 8)
       zx   = x + (((k+1) * zoomx_eff) / 4) - curx
       zy   = y + (((j+1) * zoomy_eff) / 8) - cury

       render_tile(code, color, flipx, flipy, curx, cury,
                   zx<<12, zy<<13, primask=primasks[priority], pen0=transparent)

  10. (If any 0xffff chunk codes were encountered, log a warning.)
```

### racingb double-buffer variant (`sci_draw_sprites_16x8`)

racingb uses a sprite RAM double-buffer:

```cpp
int start_offs = (m_sci_spriteframe & 1) * 0x800;
start_offs = 0x800 - start_offs;
// iterates: offs from (start_offs + 0x800 - 4) down to start_offs
```

This selects which 0x800-word (2KB) half of sprite RAM is the "display" frame.
The CPU writes to the inactive half while the chip renders the active half.
In dblaxle, the frame toggle register at 0xC08000 is commented out and unused.

---

## 7. Priority System

### primasks

```c
static const u32 primasks[2] = { 0xf0, 0xfc };
// priority == 0 (sprite word+1 bit15 = 0): primask = 0xf0 → above road layer
// priority == 1 (sprite word+1 bit15 = 1): primask = 0xfc → below road layer
```

MAME uses a 2-bit priority bitmap per pixel. Sprites compare their primask against the
current value of the priority bitmap pixel to decide whether to draw or be occluded.

- `primask = 0xf0`: draws over pixels with priority 0 or 1 (BG layers 0–2), blocked by
  priority 4 (BG layer 3 / text). Road is at priority 1 or 2. Sprite draws over road.
- `primask = 0xfc`: draws over pixels with priority 0 only. Both road (priority 1 or 2)
  and higher BG layers occlude this sprite.

### Layer priority stack (Double Axle)

From `screen_update_dblaxle`:

```
Priority 0: BG layer[0]  (TILEMAP_DRAW_OPAQUE, prio=0)
Priority 0: BG layer[1]  (prio=0)
Priority 1: BG layer[2]  (prio=1)
             TC0150ROD road  (low_priority=1, high_priority=2)
             Sprites    (above road: primask=0xf0; below road: primask=0xfc)
Priority 4: BG layer[3]  (prio=4) ← drawn after sprites, covers them
Priority 0: BG layer 4 (FG/text, prio=0 but drawn last)
```

`y_offs = 7` is passed to `bshark_draw_sprites_16x8` in dblaxle — shifts all sprites
7 pixels upward to align with the active display area.

### Layer priority stack (Racing Beat)

From `screen_update_racingb`:

```
Priority 0: BG layer[0]  (TILEMAP_DRAW_OPAQUE, prio=0)
Priority 0: BG layer[1]  (prio=0)
Priority 2: BG layer[2]  (prio=2)
Priority 2: BG layer[3]  (prio=2)
             TC0150ROD road  (low_priority=1, high_priority=2)
             Sprites (same primask behavior)
Priority 4: BG layer 4  (FG/text, prio=4, drawn after sprites)
```

---

## 8. TC0170ABT — Role Assessment

The TC0170ABT ("Motion Object Generator") appears on the **CPU PCB** of Taito Z hardware.
PCB schematics show it positioned between CPU A's bus and the video PCB connector.

**From MAME:** TC0170ABT has no register window in the CPU A address map for dblaxle or
racingb. It is not instantiated as a MAME device with its own R/W handlers.

**Probable function:** Address routing / transformation for sprite RAM access. Possible
roles include: sprite RAM buffer management, address decode assist, or chip enable logic
for TC0370MSO on the video PCB side.

**FPGA conclusion:** TC0170ABT is not register-visible and has no documented software
interface. For FPGA implementation, it can be treated as transparent wiring. The sprite
scanner behavior is fully determined by:
1. Sprite RAM contents (CPU A writes)
2. Spritemap ROM contents
3. OBJ GFX ROM contents
4. The rendering algorithm in `bshark_draw_sprites_16x8`

No TC0170ABT model is needed for the FPGA core.

---

## 9. Chip Comparison: TC0370MSO vs TC0150ROD vs TC0200OBJ

| Aspect                  | TC0370MSO (this chip)        | TC0150ROD              | TC0200OBJ (F2)        |
|-------------------------|------------------------------|------------------------|-----------------------|
| Sprite RAM size         | 0x4000 bytes (16KB)          | N/A (road data)        | 0x8000 bytes (64KB)   |
| Entry size              | 4 words (8 bytes)            | 4 words per scanline   | 8 words (16 bytes)    |
| Max sprite entries      | 0x800 (2048), most inactive  | 256 scanlines          | 1024 per bank         |
| Spritemap ROM           | Yes, 512KB (32 codes/sprite) | No                     | No (direct tile codes)|
| GFX tile size           | 16×8 pixels, 4bpp            | 2bpp road pixels       | 16×16 pixels, 4bpp   |
| GFX ROM width           | 64-bit interleave            | 16-bit                 | 32-bit                |
| Zoom                    | 6-bit per axis, per-sprite   | None (CPU per-scanline)| 8-bit per axis        |
| Priority levels         | 2 (above/below road)         | 6 internal levels      | 4 (via TC0360PRI)     |
| Scan order              | Back-to-front                | N/A                    | Front-to-back         |
| Complexity tier         | 3                            | 2                      | 3 (existing impl.)    |

---

## 10. Sprite Count and Active Frame Budget

**Sprite RAM capacity:** 0x2000 words ÷ 4 words per entry = **0x800 entries** (2048 max).

In practice, active sprites per frame are far fewer. The scanner skips entries with
`tilenum == 0`, so empty slots are zero-cost beyond the scan overhead.

Each active sprite requires 32 spritemap ROM reads + up to 32 GFX ROM tile renders.
At a nominal 320×240 display and typical 60–100 active sprites per frame in dblaxle,
the line buffer must handle ~3200 tile renders per frame maximum (100 sprites × 32 tiles).

**Line buffer capacity:** TC0300FLA provides the line buffer. Each line holds up to
320 pixels per scanline. Sprites can overlap and overwrite each other (last-write wins
within the back-to-front scan order, which makes front entries appear on top).

---

## 11. Sprite RAM Access During Display (double-buffer note)

**dblaxle:** Single-buffer. CPU A writes sprite RAM at 0xC00000–0xC03FFF during the frame.
The MAME driver comment says "Double Axle seems to keep only 1 sprite frame in sprite RAM,
which is probably wrong." This implies the hardware may support double buffering but the
game software does not use it.

**racingb:** Double-buffer via `sci_spriteframe_r/w` at 0xB08000. CPU A alternates which
0x800-word half of sprite RAM is the "current display frame" by writing the frame toggle
register at each IRQ6 (every other VBL). The scanner reads from the inactive half while
CPU writes to the active half.

For FPGA (dblaxle target): single-buffer is sufficient. The sprite scanner reads the full
0x2000-word sprite RAM once per VBlank. No double-buffer logic needed.
