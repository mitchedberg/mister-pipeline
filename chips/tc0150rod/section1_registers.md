# TC0150ROD — Section 1: Register Map, RAM Format & Rendering Algorithm

**Source:** MAME `src/mame/taito/tc0150rod.cpp` + `tc0150rod.h` (Nicola Salmoria), FBNeo
`src/burn/drv/taito/tc0150rod.cpp`, Taito Z integration plan `chips/taito_z/integration_plan.md`
**Systems:** All Taito Z games: Contcirc, Enforce, ChaseHQ, Nightstriker, Aquajack, Bshark, SCI,
Spacegun, Double Axle, Racing Beat
**Status:** Research complete — no FPGA implementation exists as of 2026-03.

---

## 1. Chip Overview

The TC0150ROD is Taito's dedicated road-rendering chip. It is used on all Taito Z games. Its
job is to produce a per-scanline pixel stream representing one or two perspective-scaled road
strips, including road body, road edges, and background fill. The output is priority-tagged
and composited into the final display behind sprites but over some BG layers.

Key facts:
- CPU interface: pure RAM window (no control registers other than the control word at 0x1ffe)
- RAM size: 0x2000 bytes (8KB, exposed as 0x1000 × 16-bit words)
- ROM: road GFX ROM, 512KB (0x80000 bytes = 0x40000 × 16-bit words)
- Two road layers: Road A (bottom) and Road B (top overlay for road forks/intersections)
- Each road line is described by 4 × 16-bit words in RAM
- Output: palette index per pixel (12-bit) with 3-bit internal priority tag, fed to final mixer

In Double Axle and Racing Beat, the chip sits on CPU B's bus exclusively:
- dblaxle: CPU B 0x300000–0x301FFF
- racingb:  CPU B 0xA00000–0xA01FFF

CPU A has no direct access to TC0150ROD.

---

## 2. RAM Address Map (chip-relative, 0x2000 bytes = 0x1000 words)

```
Word offset     Byte offset    Contents
─────────────────────────────────────────────────────────────────────────
0x0000–0x07FF   0x0000–0x0FFF  Road A, bank 0   [256 scanlines × 4 words]
0x0800–0x0FFF   0x1000–0x1FFF  Road A, bank 1   [256 scanlines × 4 words]
0x1000–0x17FF   0x2000–0x2FFF  Road B, bank 0   [256 scanlines × 4 words]
0x1800–0x1FFF   0x3000–0x3FFF  Road B, bank 1   [256 scanlines × 4 words]

0x0FFF          0x1FFE–0x1FFF  Control word (road_ctrl)  [last word of Road A bank 1]
```

Road A and Road B each have two banks (double-buffering). The control word at offset 0xFFF
(last word of the RAM) selects which bank is active for each road:

---

## 3. Control Word (RAM offset 0x0FFF, word 0xFFF)

```
Bits [15:12]  Not used (always 0 in known games)
Bits [11:10]  Road B RAM page select: bank offset added to Road B base address
              00 → Road B from 0x1000 (bank 0)
              01 → Road B from 0x1200 (bank 0 + offset)
              10 → Road B from 0x1400 ...
              11 → Road B from 0x1600 ...
              Formula: road_B_address = y_offs*4 + ((road_ctrl & 0x0c00) << 0)
Bits  [9:8]   Road A RAM page select: bank offset added to Road A base address
              Formula: road_A_address = y_offs*4 + ((road_ctrl & 0x0300) << 2)
Bits  [7:0]   Priority switch line: screen scanline where the output switches from
              low_priority to high_priority (passed from screen_update to the mixer)
              Formula: priority_switch_line = (road_ctrl & 0x00ff) - y_offs
```

The bank select fields allow the CPU to write the next frame's road data into the inactive
bank while the active bank is being rendered, implementing double buffering in software.

Road B rendering is additionally gated by `road_ctrl & 0x800` — if this bit is clear and
`type != 2`, Road B is not drawn at all even if its RAM contains valid data.

---

## 4. Road RAM Entry Format (4 words per scanline)

Each scanline consumes 4 consecutive 16-bit words. For scanline Y:
- Road A entry: `ram[road_A_address + Y*4 + 0..3]`
- Road B entry: `ram[road_B_address + Y*4 + 0..3]`

### Word +0: ClipR (right clip / right edge control)

```
Bit  15      Draw background behind right road edge (1 = fill background color to right of road)
Bit  14      (unused / game-specific priority modifier)
Bit  13      Priority modifier: raises/lowers right-edge priority relative to other road
Bit  12      Right edge/background palette offset (0 or 2; contributes 2 to palroffs)
Bits 11:10   (unused)
Bits  9:0    Right edge width in pixels from road center (0x3FF mask)
```

`palroffs = (clipr & 0x1000) >> 11`  → 0 or 2

### Word +1: ClipL (left clip / left edge control)

```
Bit  15      Draw background behind left road edge (1 = fill background color to left of road)
Bit  14      (unused / game-specific priority modifier)
Bit  13      Priority modifier: raises/lowers left-edge priority relative to other road
Bit  12      Left edge/background palette offset (0 or 2; contributes 2 to palloffs)
Bits 11:10   (unused)
Bits  9:0    Left edge width in pixels from road center (0x3FF mask)
```

`palloffs = (clipl & 0x1000) >> 11`  → 0 or 2

### Word +2: BodyCtrl (road body / center control)

```
Bit  15      Draw background behind road body (set → background_only mode)
Bit  14      (reserved)
Bit  13      Priority modifier for road body (raises body priority by 2 or 1 relative to edges)
Bits 12:11   Body/background palette entry offset → paloffs = (bodyctrl & 0x1800) >> 11  (0,2,4,6)
Bits 10:0    X offset (inverted): xoffset = bodyctrl & 0x7ff
             road_center = 0x5FF - ((-xoffset + 0xa7) & 0x7ff)
             0xa7 is the fixed horizontal centering bias (confirmed in MAME + FBNeo)
```

### Word +3: GFX selector

```
Bits 15:12   Color bank (ColBank): selects which group of 4-color palette entries
             colbank = (ram[+3] & 0xf000) >> 10   → 0, 4, 8 ... 60 (in units of palette entries)
Bits 11:10   Not used by any known game (top 2 bits of tile number field, always 0)
Bits  9:0    Road GFX tile number (road_gfx_tilenum): indexes into the road ROM
             tile number 0 means "no road body, draw edges only" (special case in rendering)
```

---

## 5. Road ROM Format

### Size and layout

Total ROM size: 512KB (0x80000 bytes = 0x40000 × 16-bit words).

One GFX tile = 0x200 bytes = 0x100 words = 256 words.

Each tile contains **two** horizontal road lines of 1024 pixels each, stored 2 bits per pixel:

```
Tile word offset 0x000–0x07F  (128 words = 1024 pixels):  Edge line
Tile word offset 0x080–0x0FF  (128 words = 1024 pixels):  Body line
```

Pixel addressing within a tile:
```
word_index = (tile_num << 8) + (x_index >> 3)
gfx_word   = rom[word_index]

// Each 16-bit word holds 8 pixels, 2bpp, interleaved:
// High byte = bit-1 of pixels 7..0
// Low byte  = bit-0 of pixels 7..0
//
// For pixel at column x_index (0..1023):
bit1 = (gfx_word >> (7 - (x_index % 8) + 8)) & 1    // from high byte
bit0 = (gfx_word >> (7 - (x_index % 8)))     & 1    // from low byte
pixel_value = bit1 * 2 + bit0                         // 0..3
```

Pixels are stored right-to-left within the word (bit 7 of low byte = leftmost pixel of the
group of 8). This is why the renderer fills the scanline buffer in reverse (right to left),
which restores the correct left-to-right screen orientation.

### Edge line vs body line

- **Edge line** (x_index 0–511, first half of tile): stored with both edges touching at center.
  - Left edge: x_index 0x1FF down to 0x000 (center to left)
  - Right edge: x_index 0x200 up to 0x3FF (center to right)
- **Body line** (x_index 512–1023 = 0x200–0x3FF, second half of tile): full 1024-pixel road body.

For Road B body rendering: the body line is accessed only when `x_index > 0x3ff` — the
renderer checks this condition before drawing Road B's body section.

### ROM access formula

```
rom_word_addr = (road_gfx_tilenum << 8) + (x_index >> 3)
```

With `road_gfx_tilenum` up to 0x3FF, maximum ROM word address = (0x3FF << 8) + 0x7F = 0x3FFFF.
This maps to 0x80000 bytes (512KB) — exactly the ROM size. No bank switching needed.

---

## 6. Palette Index Calculation

The final palette index for a pixel is a 12-bit value:

```
palette_index = base_color + pixel_value

where:
  base_color = ((palette_offs + colbank + pal_edge_offs) << 4) + base_entry

  palette_offs  = caller-supplied global offset (0xc0 for dblaxle/racingb = palette bank 12)
  colbank       = (ram[+3] & 0xf000) >> 10     (0..60, step 4)
  pal_edge_offs = palloffs or palroffs          (0 or 2 from word +1/+0 bit 12)
                  or paloffs from bodyctrl      (0,2,4,6 from word +2 bits 12:11)

  base_entry:
    type=0 (standard, used by dblaxle/racingb):
      body pixels:  base = 4   → palette entries 4..7 (pixel_value 0..3 → +4..+7)
      edge pixels:  base = 4   → palette entries 4..7
      background:   base = 0   → palette entry 0 (pixel_value 0 → color 0 = background)
    type=1 (contcirc/enforce): base = 1, pixel remapped: pixel = (pixel - 1) & 3
    type=2 (aquajack):         base = 1, pixel remapped: pixel = (pixel - 1) & 3

  pixel_value = 0..3 (from 2bpp ROM lookup, or 0 for background fill)
```

In standard games (dblaxle, racingb, bshark, chasehq, sci): `type=0`, `palette_offs=0xc0`.
The 64 palette entries from 0xC00 to 0xC3F (= 0xc0<<4 to 0xc0<<4+0x3F) are the road palette
block. `colbank` and edge offsets subdivide this into groups of 16 or 4.

---

## 7. Priority System

### Internal pixel priority encoding

The final scanline pixel word is 16 bits, packed:

```
Bit  15     Transparency flag (1 = transparent, do not write to output)
Bits 14:12  Internal priority tag (0–7, encoded as 3 bits)
Bits 11:0   Palette index (12 bits)
```

This is stored in the per-pixel scanline buffer (values 0x8000 = fully transparent sentinel,
0xf000 = high-priority transparent, 0x0xxx = opaque with priority bits 14:12).

### Priority levels (default, type=0)

Six sub-components with default priority assignments:

```
priorities[0] = 1   Road A left edge
priorities[1] = 1   Road A right edge
priorities[2] = 2   Road A body
priorities[3] = 3   Road B left edge
priorities[4] = 3   Road B right edge
priorities[5] = 4   Road B body  (note: FBNeo uses 1 here but MAME uses 4)
```

These defaults are then modified by priority modifier bits in the per-line RAM words:

```
if (roada_bodyctrl & 0x2000)  priorities[2] += 2   // Road A body raised
if (roadb_bodyctrl & 0x2000)  priorities[2] += 1   // Road A body raised less
if (roada_clipl    & 0x2000)  priorities[3] -= 1   // Road B left edge lowered
if (roadb_clipl    & 0x2000)  priorities[3] -= 2   // Road B left edge lowered more
if (roada_clipr    & 0x2000)  priorities[4] -= 1   // Road B right edge lowered
if (roadb_clipr    & 0x2000)  priorities[4] -= 2   // Road B right edge lowered more
if (priorities[4] == 0)       priorities[4] = 1    // Floor at 1 (Aquajack LH edge fix)
```

Priority levels map to output priority bits [14:12] = `priority << 12`.

### Road A vs Road B arbitration

After both road lines are rendered to `roada_line[]` and `roadb_line[]` buffers:

```
for each pixel i:
  if roada_line[i] == 0x8000:   output = roadb_line[i] & 0x8FFF  (A transparent, use B)
  elif roadb_line[i] == 0x8000: output = roada_line[i] & 0x8FFF  (B transparent, use A)
  else:  // both opaque — compare priority tags
    if (roadb_line[i] & 0x7000) > (roada_line[i] & 0x7000):
      output = roadb_line[i] & 0x8FFF   // B wins
    else:
      output = roada_line[i] & 0x8FFF   // A wins (A wins ties)
```

The final combined scanline is then written to the priority bitmap with either `low_priority`
or `high_priority` tag depending on whether the current scanline Y is above or below
`priority_switch_line`.

### System-level priority (compositing with BG layers and sprites)

In dblaxle/racingb the `draw()` call passes:
```cpp
m_tc0150rod->draw(bitmap, cliprect, -1, 0xc0, 0, 0, priority_bitmap, 1, 2);
//   y_offs=-1, palette_offs=0xc0, type=0, road_trans=0
//   low_priority=1, high_priority=2
```

Priority tag 1 = below sprites (priority bit 0), above BG layers 0–1.
Priority tag 2 = above most BG layers but still below sprites with `primask & 0xfc`.

The road layer sits between the BG tilemap layers and the sprite layer in the Taito Z
priority stack.

---

## 8. Rendering Algorithm (per frame)

```
draw(y_offs, palette_offs, type, road_trans, low_priority, high_priority):

  road_ctrl = ram[0x0FFF]
  road_A_address = y_offs*4 + ((road_ctrl & 0x0300) << 2)
  road_B_address = y_offs*4 + ((road_ctrl & 0x0c00) << 0)
  priority_switch_line = (road_ctrl & 0x00ff) - y_offs

  for each scanline y from min_y to max_y:

    // 1. Clear both line buffers to transparent
    roada_line[0..W-1] = 0x8000
    roadb_line[0..W-1] = 0x8000

    // 2. Read Road A RAM entry for this scanline
    idx_A = road_A_address + y*4
    roada_clipr    = ram[idx_A + 0]
    roada_clipl    = ram[idx_A + 1]
    roada_bodyctrl = ram[idx_A + 2]
    colbank_A      = (ram[idx_A + 3] & 0xf000) >> 10
    tile_A         = ram[idx_A + 3] & 0x3ff

    // 3. Read Road B RAM entry for this scanline
    idx_B = road_B_address + y*4
    roadb_clipr    = ram[idx_B + 0]
    roadb_clipl    = ram[idx_B + 1]
    roadb_bodyctrl = ram[idx_B + 2]
    colbank_B      = (ram[idx_B + 3] & 0xf000) >> 10
    tile_B         = ram[idx_B + 3] & 0x3ff

    // 4. Compute per-line priority adjustments
    priorities[0..5] = {1, 1, 2, 3, 3, 4}   (default)
    apply priority modifier bits from clipl/clipr/bodyctrl words (see §7)

    // 5. Render Road A body (center section, between left_edge and right_edge)
    xoffset = roada_bodyctrl & 0x7ff
    road_center = 0x5ff - ((-xoffset + 0xa7) & 0x7ff)
    left_edge  = road_center - (roada_clipl & 0x3ff)
    right_edge = road_center + 1 + (roada_clipr & 0x3ff)

    for x = left_edge+1 to right_edge-1:
      x_index = (-xoffset + 0xa7 + x) & 0x7ff    // body line x index (0..1023)
      pixel = lookup_2bpp(tile_A, x_index)
      if pixel != 0 or !road_trans:
        roada_line[W-1-x] = (palette_color(palette_offs, colbank_A, paloffs, pixel, type))
                             | (priorities[2] << 12)
      else:
        roada_line[W-1-x] = 0xf000    // high-priority transparent

    // 6. Render Road A left edge (from road center leftward to screen left)
    x_index starts at (512 - 1 - left_over) & 0x7ff, decrements
    for x = left_edge down to 0:
      pixel = lookup_2bpp(tile_A, x_index)
      roada_line[W-1-x] = pixel==0 and !clipl_bg_fill ? skip : (color | pixpri)

    // 7. Render Road A right edge (from road center rightward to screen right)
    x_index starts at (512 + right_over) & 0x7ff, increments
    for x = right_edge to W-1:
      pixel = lookup_2bpp(tile_A, x_index)
      roada_line[W-1-x] = pixel==0 and !clipr_bg_fill ? skip : (color | pixpri)

    // 8. Conditionally render Road B (only if road_ctrl & 0x800 or type==2)
    Repeat steps 5–7 for Road B into roadb_line[], using tile_B, colbank_B, etc.
    Road B body: only rendered when x_index > 0x3ff (second half of tile = body line)

    // 9. Arbitrate Road A vs Road B per pixel (§7 priority rules)
    merge roada_line[] and roadb_line[] into scanline[]

    // 10. Write scanline to output bitmap with priority tag
    priority_tag = (y > priority_switch_line) ? high_priority : low_priority
    write_scanline_with_priority(y, scanline, priority_bitmap, priority_tag)
```

### Note on the buffer fill direction

The pixel buffers are filled right-to-left (`roada_line[W-1-x]`). This reverses the
backward pixel ordering in the ROM (which stores pixels right-to-left), restoring correct
left-to-right screen output.

---

## 9. Call-site Parameters (dblaxle and racingb)

```
// Double Axle (DblaxleDraw):
TC0150RODDraw(-1, 0xc0, 0, 0, 1, 2)
  y_offs=−1, palette_offs=0xc0, type=0, road_trans=0, low_pri=1, high_pri=2

// Racing Beat (RacingbDraw):
TC0150RODDraw(-1, 0xc0, 0, 0, 1, 2)
  identical parameters
```

`y_offs = -1` shifts the road RAM lookup one line early (the first drawn scanline uses
`road_A_address = -1*4 + bank_offset = -4 + bank_offset`). Combined with the `yOffs += 16`
correction in FBNeo (adjusting for the 16-pixel top border), this aligns the road strip
with the active display area.

---

## 10. Games Using TC0150ROD

| Game | type | palette_offs | y_offs | road_trans | Notes |
|------|------|-------------|--------|------------|-------|
| Contcirc | 1 | `TaitoRoadPalBank<<6` | -3+8 | 0 | Uses TC0110PCR palette |
| Enforce | 1 | 0xc0 | -3+8 | 0 | |
| ChaseHQ | 0 | 0xc0 | -1 | 0 | xFlip=0 |
| Nightstr | 0 | 0xc0 | -1 | 0 | Complex priority (tunnel split) |
| Aquajack | 2 | 0 | -1 | 1 | type=2, road_trans=1 |
| Bshark | 0 | 0xc0 | -1 | 1 | road_trans=1 (pen0 transparent) |
| SCI | 0 | 0xc0 | -1 | 0 | Uses TC0360PRI priority map |
| Spacegun | 0 | 0xc0 | -1 | 0 | |
| Double Axle | 0 | 0xc0 | -1 | 0 | TC0480SCP tilemap chip |
| Racing Beat | 0 | 0xc0 | -1 | 0 | TC0480SCP tilemap chip |
