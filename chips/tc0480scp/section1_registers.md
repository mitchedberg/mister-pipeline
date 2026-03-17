# TC0480SCP — Section 1: Register Map & Memory Layout

**Source:** MAME `src/mame/taito/tc0480scp.cpp` + `tc0480scp.h` (Nicola Salmoria), `src/mame/taito/taito_z.cpp` (David Graves), Gunbustr schematics (cited in MAME source)
**Systems:** Taito Z (Double Axle, Racing Beat), Taito F3 transitional (Gunbuster, Ground Effects, Under Fire, Galastrm)
**Status:** Greenfield — no FPGA implementation exists as of 2026-03.

---

## 1. Chip Overview

The TC0480SCP is Taito's second-generation tilemap generator, superseding the TC0100SCN. It manages **four background BG layers** (16×16 tiles from ROM) and one **foreground text layer** (8×8 tiles from RAM). All four BG layers support global X/Y scroll, global zoom, and per-row horizontal scroll (rowscroll). BG2 and BG3 additionally support per-row zoom and per-column vertical scroll (colscroll). The five layers are priority-mixed internally and output as 16-bit pixel data (palette index + priority tag).

Key facts from the MAME source comment block and Gunbustr schematics:
- CPU address bus: VA1–VA17 (17-bit, byte granularity → 128KB window)
- CPU data bus: VD0–VD15 (16-bit)
- RAM address bus: RA0–RA14 (15-bit → 32K × 16-bit = 64KB RAM)
- ROM address bus: CH0–CH20 (21 bits → addressable up to 0x800000 bytes = 8 Mbit; no known game uses more than 4 Mbit / 0x400000 bytes)
- ROM data bus: RD0–RD31 (32-bit — four bytes per read, matching 32bpp tile fetch)
- Pixel output: SD0–SD15 (16-bit palette index output)
- Video sync inputs: HSYNC, HBLANK, VSYNC, VBLANK

The chip exposes 0x10000 bytes (64KB, 0x8000 16-bit words) of RAM to the CPU. The RAM holds all five tilemaps, rowscroll, rowzoom, colscroll tables, and the text layer gfx data. An additional 0x30 bytes of control registers are in a separate window.

Two layout modes exist selectable per-game:
- **Standard (single-width):** four 32×32 BG tilemaps
- **Double-width:** four 64×32 BG tilemaps (bit 7 of control register 0x0f)

---

## 2. CPU Address Space (chip-relative, 64KB RAM window + 0x30 control window)

```
Chip-relative     Size      Contents
──────────────────────────────────────────────────────────────────────
STANDARD LAYOUT (m_dblwidth = 0):

0x0000–0x0FFF     4KB       BG0 tilemap (32×32 tiles × 2 words = 0x800 words)
0x1000–0x1FFF     4KB       BG1 tilemap
0x2000–0x2FFF     4KB       BG2 tilemap
0x3000–0x3FFF     4KB       BG3 tilemap

0x4000–0x43FF     1KB       BG0 rowscroll (high bytes — main scroll delta per row)
0x4400–0x47FF     1KB       BG1 rowscroll
0x4800–0x4BFF     1KB       BG2 rowscroll
0x4C00–0x4FFF     1KB       BG3 rowscroll

0x5000–0x53FF     1KB       BG0 rowscroll low bytes (sub-pixel precision)
0x5400–0x57FF     1KB       BG1 rowscroll low bytes
0x5800–0x5BFF     1KB       BG2 rowscroll low bytes
0x5C00–0x5FFF     1KB       BG3 rowscroll low bytes

0x6000–0x63FF     1KB       BG2 row zoom
0x6400–0x67FF     1KB       BG3 row zoom
0x6800–0x6BFF     1KB       BG2 source colscroll (Y offset per column)
0x6C00–0x6FFF     1KB       BG3 source colscroll

0x7000–0xBFFF    ~20KB      Unknown / unused
0xC000–0xDFFF     8KB       FG0 tilemap (64×64 tiles × 1 word = 0x1000 words)
0xE000–0xFFFF     8KB       FG0 gfx data (8×8 4bpp tiles uploaded by CPU, 256 tiles × 32 bytes)

──────────────────────────────────────────────────────────────────────
DOUBLE-WIDTH LAYOUT (m_dblwidth = 1):

0x0000–0x1FFF     8KB       BG0 tilemap (64×32 tiles × 2 words = 0x1000 words)
0x2000–0x3FFF     8KB       BG1 tilemap
0x4000–0x5FFF     8KB       BG2 tilemap
0x6000–0x7FFF     8KB       BG3 tilemap

0x8000–0x83FF     1KB       BG0 rowscroll (high bytes)
0x8400–0x87FF     1KB       BG1 rowscroll
0x8800–0x8BFF     1KB       BG2 rowscroll
0x8C00–0x8FFF     1KB       BG3 rowscroll

0x9000–0x93FF     1KB       BG0 rowscroll low bytes
0x9400–0x97FF     1KB       BG1 rowscroll low bytes
0x9800–0x9BFF     1KB       BG2 rowscroll low bytes
0x9C00–0x9FFF     1KB       BG3 rowscroll low bytes

0xA000–0xA3FF     1KB       BG2 row zoom
0xA400–0xA7FF     1KB       BG3 row zoom
0xA800–0xABFF     1KB       BG2 source colscroll
0xAC00–0xAFFF     1KB       BG3 source colscroll

0xB000–0xBFFF     4KB       Unknown (Slapshot / Superchs poke text-format data here)
0xC000–0xDFFF     8KB       FG0 tilemap (64×64 tiles, same in both layouts)
0xE000–0xFFFF     8KB       FG0 gfx data (same in both layouts)

──────────────────────────────────────────────────────────────────────
CONTROL REGISTERS (separate window, 0x30 bytes = 0x18 × 16-bit words):

Typically mapped at CPU_base + 0x30000 (e.g. 0xa30000 in Double Axle).
```

### 2.1 System address map examples

Double Axle (taito_z — dblaxle_map):
```
0x900000–0x90FFFF   TC0480SCP RAM (mirror)
0xA00000–0xA0FFFF   TC0480SCP RAM (primary)
0xA30000–0xA3002F   TC0480SCP control registers
```

Racing Beat (taito_z — racingb_map):
```
0x900000–0x90FFFF   TC0480SCP RAM
0x930000–0x93002F   TC0480SCP control registers
```

---

## 3. Control Registers (0x18 × 16-bit words = 0x30 bytes)

All registers are 16-bit. Chip offset is word index × 2.

| Word | Byte offset | Name           | Description |
|------|-------------|----------------|-------------|
|  0   | 0x00–0x01   | BG0_XSCROLL    | BG0 global X scroll (signed 16-bit) |
|  1   | 0x02–0x03   | BG1_XSCROLL    | BG1 global X scroll |
|  2   | 0x04–0x05   | BG2_XSCROLL    | BG2 global X scroll |
|  3   | 0x06–0x07   | BG3_XSCROLL    | BG3 global X scroll |
|  4   | 0x08–0x09   | BG0_YSCROLL    | BG0 global Y scroll (signed 16-bit) |
|  5   | 0x0A–0x0B   | BG1_YSCROLL    | BG1 global Y scroll |
|  6   | 0x0C–0x0D   | BG2_YSCROLL    | BG2 global Y scroll |
|  7   | 0x0E–0x0F   | BG3_YSCROLL    | BG3 global Y scroll |
|  8   | 0x10–0x11   | BG0_ZOOM       | BG0 global zoom |
|  9   | 0x12–0x13   | BG1_ZOOM       | BG1 global zoom |
| 10   | 0x14–0x15   | BG2_ZOOM       | BG2 global zoom |
| 11   | 0x16–0x17   | BG3_ZOOM       | BG3 global zoom |
| 12   | 0x18–0x19   | TEXT_XSCROLL   | Text layer (FG0) X scroll (signed) |
| 13   | 0x1A–0x1B   | TEXT_YSCROLL   | Text layer (FG0) Y scroll (signed) |
| 14   | 0x1C–0x1D   | (unused)       | Not written by any known game |
| 15   | 0x1E–0x1F   | LAYER_CTRL     | Layer control register — see §3.1 |
| 16   | 0x20–0x21   | BG0_DX         | BG0 sub-pixel X (scroll delta for zoom precision) |
| 17   | 0x22–0x23   | BG1_DX         | BG1 sub-pixel X |
| 18   | 0x24–0x25   | BG2_DX         | BG2 sub-pixel X |
| 19   | 0x26–0x27   | BG3_DX         | BG3 sub-pixel X |
| 20   | 0x28–0x29   | BG0_DY         | BG0 sub-pixel Y |
| 21   | 0x2A–0x2B   | BG1_DY         | BG1 sub-pixel Y |
| 22   | 0x2C–0x2D   | BG2_DY         | BG2 sub-pixel Y |
| 23   | 0x2E–0x2F   | BG3_DY         | BG3 sub-pixel Y |

### 3.1 LAYER_CTRL (word 15, byte 0x1E)

```
Bit 15 (0x80):  Double-width tilemaps
                0 = standard: four 32×32 BG tilemaps (single-width)
                1 = double:   four 64×32 BG tilemaps (RAM layout changes — see §2)
                Slapshot changes this on the fly during gameplay.

Bit 14 (0x40):  Flip screen
                1 = flip all layers X and Y

Bit 13 (0x20):  Unknown function
                Set in Metalb init based on a byte in program ROM $7fffe.
                Metalb later changes it for some layer layouts.
                Footchmp clears it; Hthero sets it.
                Deadconx uses values 0x00, 0x20, 0x40, 0x60 based on $7fffd
                and flip state. Function not fully characterized.

Bits 4–2 (0x1C): BG layer priority order (3-bit index into lookup table)
                See §3.2 for the lookup table.

Bit 1 (0x02):   BG3 row zoom enable
                1 = apply rowzoom_ram[3] per-row zoom to BG3
                0 = ignore row zoom RAM for BG3 (use global zoom only)

Bit 0 (0x01):   BG2 row zoom enable
                1 = apply rowzoom_ram[2] per-row zoom to BG2
                0 = ignore row zoom RAM for BG2 (use global zoom only)
```

Note: The MAME source stores the full LAYER_CTRL byte in `m_pri_reg`. The row zoom enable bits are read as `m_pri_reg & (layer - 1)` for layers 2 and 3 (layer-1 gives 1 for layer=2, 2 for layer=3 → matching bits 0 and 1).

### 3.2 BG Layer Priority Lookup Table

The three bits 4:2 of LAYER_CTRL index this table. The returned 16-bit value encodes the draw order as four nibbles: most-significant nibble = bottom layer, least-significant nibble = top BG layer (text is always above all four).

```
Index  Bits[4:2]  Draw order (bottom→top)   Notes
  0      000      BG0 → BG1 → BG2 → BG3    default
  1      001      BG1 → BG2 → BG3 → BG0    (no evidence of use in any game)
  2      010      BG2 → BG3 → BG0 → BG1    (no evidence)
  3      011      BG3 → BG0 → BG1 → BG2
  4      100      BG3 → BG2 → BG1 → BG0    reverse
  5      101      BG2 → BG1 → BG0 → BG3    used in Gunbustr attract / Metalb copyright screen
  6      110      BG1 → BG0 → BG3 → BG2    (no evidence)
  7      111      BG0 → BG3 → BG2 → BG1

MAME lookup: tc0480scp_bg_pri_lookup[8] = {0x0123, 0x1230, 0x2301, 0x3012, 0x3210, 0x2103, 0x1032, 0x0321}
```

### 3.3 Zoom Register Encoding (words 8–11, BG0–BG3)

```
Bits [15:8]  = X zoom byte  (xzoom)
Bits  [7:0]  = Y zoom byte  (yzoom)

X axis (expansion only):
  xzoom = 0x00 → no zoom (1:1)
  xzoom = 0xFF → maximum expansion
  zoomx factor = 0x10000 - (xzoom << 8)
  (Factor 0x10000 = 1:1; larger = expanded)

Y axis (expansion AND compression):
  yzoom = 0x7F → no zoom (neutral)
  yzoom > 0x7F → expansion
  yzoom < 0x7F → compression (e.g. Footchmp hiscore = 0x1A, shrunk)
  zoomy factor = 0x10000 - ((yzoom - 0x7F) * 512)
  (Factor 0x10000 = 1:1; larger = compressed; smaller = expanded)
```

### 3.4 Scroll Register Processing

The four BG layer x-scroll values are not written directly as the chip applies a fixed 4-pixel stagger between layers. MAME's ctrl_w() shows:

```
BG0: bgscrollx[0] = -(ctrl[0])                     (no stagger)
BG1: bgscrollx[1] = -(ctrl[1] + 4)                 (stagger +4)
BG2: bgscrollx[2] = -(ctrl[2] + 8)                 (stagger +8)
BG3: bgscrollx[3] = -(ctrl[3] + 12)                (stagger +12)

Y scroll (no stagger):
BG0: bgscrolly[0] = ctrl[4]
BG1: bgscrolly[1] = ctrl[5]
BG2: bgscrolly[2] = ctrl[6]
BG3: bgscrolly[3] = ctrl[7]

(Signs flip when flip-screen bit is set)
```

The DX/DY sub-pixel registers (words 16–23) provide extra precision during zoom sequences. The low byte of BG0_DX (ctrl[0x10] & 0xFF) is used as a fractional scroll contribution when computing the per-scanline starting X position during zoom rendering. The equivalent DY byte (ctrl[0x14] & 0xFF) does the same for Y.

---

## 4. VRAM Layout (64KB = 0x8000 × 16-bit words)

### 4.1 BG Tile Map Entry Format

Each BG tile is described by **two consecutive 16-bit words** in VRAM. MAME's `get_bg_tile_info` reads them as:

```
Word +0 (attribute word):
  [15]    = flipY
  [14]    = flipX
  [13:12] = unknown (seen set in Metalb; possibly additional control bits)
  [11:8]  = unknown (MAME comments these as "control bits" — possibly extra color bits)
  [7:0]   = color (8-bit palette bank, selects palette entries color*16)

Word +1 (tile number):
  [14:0]  = tile code (GFX index into tile ROM — 0x0000–0x7FFF = up to 32768 tiles)
  [15]    = unused (always 0)
```

MAME: `code = m_ram[(2*tile_index)+1+Offset] & 0x7fff;  attr = m_ram[(2*tile_index)+Offset];`

### 4.2 FG0 (Text) Tile Map Entry Format

The FG0 tilemap occupies 0xC000–0xDFFF in VRAM (64×64 = 4096 tiles, 1 word each).

```
Word +0 (single attribute+code word):
  [15:14] = flipY, flipX
  [13:8]  = color (6-bit — selects palette bank color*16)
  [7:0]   = tile index (0–255 within the 256-tile RAM gfx set)
```

MAME: `attr = m_ram[0x6000 + tile_index];  tileinfo.set(1, attr & 0xff, (attr & 0x3f00) >> 8, TILE_FLIPYX((attr & 0xc000) >> 14));`

Note: The word offset 0x6000 corresponds to byte address 0xC000 (0x6000 × 2 = 0xC000).

### 4.3 FG0 Gfx Data (0xE000–0xFFFF)

256 tiles × 32 bytes = 8192 bytes of CPU-uploaded 8×8 4bpp character graphics.

Tile layout (from MAME `tc0480scp_charlayout`):
```
8×8 pixels, 4 bits per pixel (packed)
Bit planes: { 0, 1, 2, 3 } (4 bpp interleaved)
Pixel columns (within a row): { 3*4, 2*4, 1*4, 0*4, 7*4, 6*4, 5*4, 4*4 }
  (pixels packed as nibbles, column order reversed within each 4-pixel group)
Rows: { 0*32, 1*32, ..., 7*32 }
32 bytes per tile
```

This is the same pixel format as the TC0100SCN text layer.

---

## 5. Rowscroll RAM Format

Each BG layer has a 1KB (0x200 words) rowscroll region. Two sub-regions exist within each layer's rowscroll block:

```
Offset +0x000 to +0x1FF  (word indices 0–511):
  Word[row] = high-byte scroll delta for that source row
  This is the primary rowscroll value. For row R of the source tilemap,
  the effective X scroll = bgscrollx[layer] - (rowscroll_hi[R] << 16) - (rowscroll_lo[R] << 8)

Offset +0x800 to +0x9FF  (word indices relative to base; i.e., the second 1KB region):
  Word[row] = low-byte scroll delta (sub-pixel precision)
  Used by Superchs for smoothing; most games leave this zeroed.
  Gunbustr verified that only the low byte of this word matters (high byte irrelevant).
```

Addressing in MAME (standard layout):
```
bgscroll_ram[0] = &m_ram[0x2000]   (BG0 primary, byte 0x4000)
bgscroll_ram[1] = &m_ram[0x2200]   (BG1 primary, byte 0x4400)
bgscroll_ram[2] = &m_ram[0x2400]   (BG2 primary, byte 0x4800)
bgscroll_ram[3] = &m_ram[0x2600]   (BG3 primary, byte 0x4C00)
```

The low-byte half is at bgscroll_ram[layer][row_index + 0x800] in MAME's index arithmetic (since the low-byte region starts 0x1000 words later than the high-byte region = 0x800 words offset in the secondary block).

### 5.1 Rowscroll with Zoom

When global zoom is active (zoomx ≠ 0x10000), rowscroll is **disabled** — the chip uses only the global scroll for all rows. When zoom = 1:1, rowscroll is applied per source row:

```
for row in 0..511:
  effective_scrollx[row] = bgscrollx[layer] - (rowscroll_hi[row] << 16) - (rowscroll_lo[row] << 8)
```

This means each row of the source tilemap can have an independent X offset, enabling arbitrary raster-scroll effects.

---

## 6. Row Zoom RAM Format (BG2 and BG3 only)

Row zoom is available only on BG2 and BG3 (not BG0/BG1). It is enabled per-layer by bits 0 and 1 of LAYER_CTRL.

```
rowzoom_ram[2] = &m_ram[0x3000]   (BG2 row zoom, byte 0x6000, standard layout)
rowzoom_ram[3] = &m_ram[0x3200]   (BG3 row zoom, byte 0x6400)
```

Each entry is one 16-bit word per source row (512 entries).

```
Word[row]:
  [15:8]  = high byte — meaning uncertain; Undrfire uses this with mask 0x3F,
            but only the low byte is used in MAME's row-zoom x_step calculation
  [7:0]   = low byte row zoom delta
            Typical range: 0–0x7F
            Gunbustr uses 0x80–0xD0 as well

Effect: reduces the per-pixel X step for that source row:
  x_step = zoomx - (row_zoom_lo * 256)
  (If low byte is 0, no additional per-row zoom — pure global zoom)
```

MAME also applies a per-row X origin adjustment when row zoom is active:
```
x_index -= (x_offset - 0x1f + layer*4) * ((row_zoom & 0xff) << 8)
```
This centers the zoomed row relative to the global zoom origin. The exact formula is described in the MAME source comments as "flawed" — real hardware behavior for the corner cases is uncertain.

---

## 7. Column Scroll RAM Format (BG2 and BG3 only)

Column scroll applies a Y offset to each source column, enabling vertical wavy effects (used in road and water effects).

```
bgcolumn_ram[2] = &m_ram[0x3400]   (BG2 colscroll, byte 0x6800, standard layout)
bgcolumn_ram[3] = &m_ram[0x3600]   (BG3 colscroll, byte 0x6C00)
```

512 entries, one 16-bit word per column of the source tilemap.

```
Word[col] = Y offset to add to this source column when computing src_y_index

Effect (MAME bg23_draw):
  src_y_index = ((y_index >> 16) + bgcolumn_ram[layer][(y - y_offset) & 0x1ff]) & 0x1ff
  (in flipscreen, the column index is reversed: 0x1ff - ...)
```

Column scroll is always active for BG2/BG3 (there is no enable bit — if the colscroll RAM is all zeros, there is no effect).

---

## 8. GFX ROM Format (Background Tiles)

### 8.1 Standard Layout

The default GFX layout (`gfxinfo_default`):
```
GFXDECODE_DEVICE(DEVICE_SELF, 0, gfx_16x16x4_packed_lsb, 0, 256)
```

This is MAME's built-in `gfx_16x16x4_packed_lsb` layout:
```
16×16 tiles, 4 bits per pixel, packed (two pixels per byte), LSB first
Bytes per tile: 16 × 16 × 4 / 8 = 128 bytes
Total for 16384 tiles (0x4000): 16384 × 128 = 2 MB
ROM region: 0x100000 bytes (1MB per 8192 tiles — Double Axle uses two 512KB ROMs = 1MB total)
```

ROM load format in Double Axle:
```
ROM_LOAD32_WORD( "c78-10.12", 0x00000, 0x80000, ... )  /* lower 16 bits */
ROM_LOAD32_WORD( "c78-11.11", 0x00002, 0x80000, ... )  /* upper 16 bits */
```
Two ROMs interleaved 32-bit wide (matching the chip's 32-bit ROM data bus RD0–RD31).

### 8.2 Bootleg Layout

Some bootleg boards use a planar format instead:
```
16×16 tiles, 4 bits per pixel, planar (4 separate bit planes)
Plane offsets: { RGN_FRAC(0,4), RGN_FRAC(1,4), RGN_FRAC(2,4), RGN_FRAC(3,4) }
128 bytes per tile (same size as packed, different arrangement)
```

The FG0 text gfx uses an 8×8 planar layout in bootleg mode; in standard mode the text gfx data is uploaded from CPU to RAM (as described in §4.3).

---

## 9. Sprite System

The TC0480SCP does **not** handle sprites. Sprites on Taito Z systems are managed by separate chips:
- **TC0370MSO** — Motion Sprite Object chip (hardware sprite scanner/renderer)
- **TC0300FLA** — related sprite chip (line buffer / output)
- **TC0170ABT** — another sprite-related chip

The sprite system uses a spritemap ROM (separate from TC0480SCP's tile ROM) to aggregate small 16×8 or 16×16 GFX chunks into large composed sprites (64×64 or 128×128). The TC0360PRI chip handles priority mixing between TC0480SCP layers and the sprite output.

For FPGA purposes: sprites are a completely separate module. TC0480SCP's interface to the priority system is via its SD0–SD15 pixel output + priority tag bits, which feed into TC0360PRI alongside the sprite pixel output.

---

## 10. Layer Priority System

The TC0480SCP outputs a priority tag alongside each pixel. The text layer (FG0) is **always on top** of all four BG layers — this is hardwired. The relative order of BG0–BG3 is selected by the 3-bit priority field in LAYER_CTRL (see §3.2).

MAME's `get_bg_priority()` returns a 16-bit value where:
```
bits [15:12] = index of bottom layer (drawn first / under everything)
bits [11:8]  = second layer
bits [7:4]   = third layer
bits [3:0]   = top BG layer (below text)
```

Example (index 0 = default): 0x0123 → bottom=BG0, then BG1, then BG2, then BG3=top BG.

The games drive this via `tc0480scp->get_bg_priority()` then loop through the four layers in order, drawing each with MAME's priority bitmap system. TC0360PRI then mediates the final sprite-vs-tilemap priority.

---

## 11. Dual-CPU Synchronization

The TC0480SCP sits on the main CPU A's bus. On Double Axle:
- **CPU A** (main @ 16 MHz): handles TC0480SCP reads/writes, palette, sprite RAM, I/O
- **CPU B** (sub @ 16 MHz): handles TC0150ROD (road generator), shared RAM communication

The two CPUs share 0x10000 bytes of RAM at 0x210000 (CPU A) / 0x110000 (CPU B). The TC0480SCP does not directly interact with CPU B — it is a CPU A peripheral only.

MAME notes: `config.set_maximum_quantum(attotime::from_hz(XTAL(32'000'000)/1024))` is required to prevent the road layer from getting stuck on continue. This implies the two CPUs must be tightly interleaved.

---

## 12. Palette

TC0480SCP outputs a 16-bit pixel index (palette address). The TC0260DAR (or in later games, a direct palette RAM) translates this to RGB. On Double Axle, the palette RAM is 0x800 16-bit words (4096 entries) at 0x800000, format xBGR_555.

TC0360PRI (already implemented in this pipeline) sits between TC0480SCP, the sprite system, and the final palette lookup. TC0480SCP's output feeds into TC0360PRI as one of the layer inputs.
