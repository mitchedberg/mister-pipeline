# TC0630FDP — Section 1: Register Map, Memory Layout & Hardware Formats

**Source:** MAME `src/mame/taito/taito_f3.cpp` + `taito_f3_v.cpp` + `taito_f3.h`
(Primary authors: Brian A. Troha, Nicola Salmoria, Bryan McPhail, David Graves, y-ack)
**System:** Taito F3 Package System (1992–1997): RayForce, Darius Gaiden, Elevator Action Returns,
Bubble Symphony, Bubble Memories, Cleopatra Fortune, Kaiser Knuckle, Arabian Magic, etc.
**Status:** Greenfield — zero existing FPGA implementations as of 2026-03.

---

## 1. Chip Overview

The TC0630FDP is Taito's custom display processor for the F3 system — a Toshiba channel-less gate
array (>10K gates) that integrates all video logic for the system. It drives:

- 4 scrolling tilemap layers (playfields PF1–PF4), 512×512 or 1024×512, 4/5/6 bpp
- 1 VRAM text layer (64×64 8×8 tiles, CPU-writable characters)
- 1 pixel/pivot layer (64×32 8×8 tiles, CPU-writable pixels, used for backgrounds and effects)
- Sprite engine: 17-bit tile codes, 8-bit zoom, 4 priority groups, alpha blend
- Per-scanline line RAM: rowscroll, colscroll, zoom, priority, clipping, palette addition, alpha blend
- Layer compositing with 4 clip planes and full alpha blending

Four Sanyo LC321664AM-80 (1M×16 DRAM) chips are physically adjacent to the TC0630FDP on the
motherboard, providing its working RAM (sprite RAM, playfield RAM, line RAM, pivot RAM).

**CPU:** MC68EC020 @ 26.686 MHz (not 16 MHz as sometimes stated; pixel clock XTAL/4 = 6.6715 MHz)
**Reusable chips:** TC0260DAR (palette/DAC from Taito F2) is **not** used — F3 uses TC0650FDA
instead (a newer Taito DAC). TC0640FIO handles I/O. TC0660FCM is the control/comm module.

---

## 2. CPU Address Map

All addresses are 68EC020 byte addresses, big-endian. The TC0630FDP maps its internal registers
and RAM into this space. All regions are 16-bit word-addressed internally.

```
Address Range      Size      Contents
---------------------------------------------------------------------------
0x000000-0x1FFFFF  2MB       Program ROM (main CPU; cartridge)
0x300000-0x30007F  128B      Sound bankswitch (write only, some games)
0x400000-0x41FFFF  128KB     Main RAM (mirrored at +0x20000: 0x420000-0x43FFFF)
0x440000-0x447FFF  32KB      Palette RAM (0x2000 × 32-bit entries; 24-bit RGB)
0x4A0000-0x4A001F  32B       TC0640FIO — I/O controller (inputs, EEPROM, watchdog)
0x4C0000-0x4C0003  4B        Timer control (pseudo-hblank; mostly game-specific init)
0x600000-0x60FFFF  64KB      Sprite RAM
0x610000-0x61BFFF  48KB      Playfield RAM (PF1–PF4, 0xC000 bytes)
0x61C000-0x61DFFF  8KB       Text RAM (VRAM character layer)
0x61E000-0x61FFFF  8KB       Character RAM (CPU-writable tile GFX for text layer)
0x620000-0x62FFFF  64KB      Line RAM (per-scanline control for all layers)
0x630000-0x63FFFF  64KB      Pivot RAM (CPU-writable pixel/background layer data)
0x660000-0x66001F  32B       Display control registers (playfield scroll, mode)
0xC00000-0xC007FF  2KB       Audio dual-port RAM (68EC020 ↔ sound 68000)
0xC80000-0xC80003  4B        Sound CPU reset line 0
0xC80100-0xC80103  4B        Sound CPU reset line 1
```

---

## 3. Display Control Registers (0x660000–0x66001F)

16 × 16-bit registers at 0x660000. Written by CPU in 32-bit longwords; upper 16 bits of each
longword are the active value. All values big-endian.

```
Word offset  CPU address  Name              Description
---------------------------------------------------------------------------
0            0x660000     PF1_XSCROLL       PF1 X scroll (10.6 fixed-point, inverted frac)
1            0x660002     PF2_XSCROLL       PF2 X scroll
2            0x660004     PF3_XSCROLL       PF3 X scroll
3            0x660006     PF4_XSCROLL       PF4 X scroll
4            0x660008     PF1_YSCROLL       PF1 Y scroll (9.7 fixed-point)
5            0x66000A     PF2_YSCROLL       PF2 Y scroll
6            0x66000C     PF3_YSCROLL       PF3 Y scroll
7            0x66000E     PF4_YSCROLL       PF4 Y scroll
8-11         0x660010-17  (unused)          Always zero
12           0x660018     PIXEL_XSCROLL     Pixel/VRAM layer X scroll
13           0x66001A     PIXEL_YSCROLL     Pixel/VRAM layer Y scroll
14           (unused)     —                 —
15           0x66001E     EXTEND_MODE       Bit 7: 1 = 1024×512 tilemap mode; 0 = 512×512
```

### 3.1 Scroll Encoding

**X scroll** (PF1–PF4): 16-bit value in 10.6 fixed-point format. The fractional 6 bits are
stored **inverted** (bit-flipped): effective_x = -(raw_value >> 6) in pixel units, with
sub-pixel precision from the inverted low 6 bits.

**Y scroll** (PF1–PF4): 16-bit value in 9.7 fixed-point format. Effective Y = raw >> 7.

Both scroll values are overridden per-scanline by Line RAM rowscroll and zoom registers.

---

## 4. Playfield RAM (0x610000–0x61BFFF, 48KB = 0xC000 bytes)

Four playfield layers, each consuming 0x3000 bytes = 0x1800 16-bit words.

```
PF1: 0x610000–0x612FFF   (0x1800 words)
PF2: 0x613000–0x615FFF   (0x1800 words)
PF3: 0x616000–0x618FFF   (0x1800 words)
PF4: 0x619000–0x61BFFF   (0x1800 words)
```

Each playfield is organized as two interleaved 16-bit words per tile:

```
Word 0 (tilep[0]) — Control/Attribute:
  Bits [8:0]  (9 bits): Palette index (0–511; selects 16-color palette line)
  Bit  [9]    (1 bit):  Blend select (0 = use blend mode A, 1 = use blend mode B)
  Bits [11:10](2 bits): Extra color planes:
                          00 = 4bpp (16 colors per palette line)
                          01 = 5bpp (32 colors per palette line)
                          11 = 6bpp (64 colors per palette line)
  Bits [13:12](2 bits): (unused / game-specific)
  Bits [15:14](2 bits): Tile flip: bit14=flipX, bit15=flipY

Word 1 (tilep[1]) — Tile code:
  Bits [15:0]: GFX tile number (0–65535 for base tile index into sprite/tile ROM)
```

**Palette+plane interaction (hardware OR, not ADD):** The extra_planes field's 2-bit value
is **bitwise OR'd** into the lowest bits of the palette color address (not added). This was
a MAME accuracy bug fixed in PR #11788. The final pen address in the palette RAM is:
`pal_addr = (palette_index << 4) | pen | (extra_planes << 4)`
where `extra_planes` contributes bits into the high-pen region.

**Tilemap geometry:**
- Standard mode (EXTEND=0): 32×32 tiles × 16×16px = 512×512 pixel scrolling canvas
- Extended mode (EXTEND=1): 64×32 tiles × 16×16px = 1024×512 pixel scrolling canvas
- Map is scanned in row-major order (TILEMAP_SCAN_ROWS)

---

## 5. Text RAM (0x61C000–0x61DFFF, 8KB)

CPU-addressable text layer using CPU-writable character graphics (from Character RAM).

```
Text layer geometry: 64×64 tiles × 8×8px = 512×512 pixel canvas
Map scan order: TILEMAP_SCAN_ROWS
GFX object: index 0 (charlayout — see §11)
```

Text tile word format (one 16-bit word per tile):
```
Bits [10:0]: Character code (0–2047; indexes into Character RAM tiles)
Bits [15:11]: Color / palette select
```

The character RAM (§6) holds the actual pixel data for these tiles. When the CPU writes to
Character RAM, MAME marks the corresponding tile as dirty for re-decode on next render.

---

## 6. Character RAM (0x61E000–0x61FFFF, 8KB)

CPU-writable pixel data for the text layer. Organized as 8×8 4bpp tiles in planar format
(same layout as charlayout, see §11.1). Up to 256 tiles (8192 bytes / 32 bytes per tile).

This RAM can be written during gameplay to update text characters dynamically.

---

## 7. Pivot RAM (0x630000–0x63FFFF, 64KB)

CPU-writable pixel layer. Rendered as a 64×32 tile layer of 8×8 4bpp tiles, scanned in
**column-major order** (TILEMAP_SCAN_COLS), giving a 512×256 pixel canvas.

```
Pivot layer geometry: 64×32 tiles × 8×8px = 512×256 pixels
Map scan order: TILEMAP_SCAN_COLS
GFX object: index 1 (pivotlayout — see §11.2)
```

The pivot layer is used for rotating/scaled pixel backgrounds in games like Darius Gaiden
(the "lens" effect) and Gekirindan. The MAME code labels this `m_pixel_layer` alongside
the register-controlled pivot tile info callback.

Dirty tracking: writes to pivot_ram mark `m_pixel_layer->mark_tile_dirty(offset >> 4)`.

---

## 8. Sprite RAM (0x600000–0x60FFFF, 64KB)

Dual-banked sprite RAM. The active bank is selected by per-game configuration (game_config->sprite_lag
determines how many frames of delay between CPU write and sprite render: 0, 1, or 2).

**Maximum sprites:** 64KB / 16 bytes = 4096 sprite entries. In practice, hardware likely
processes until a sentinel or end-of-list condition, but MAME processes the full 64KB range.

### 8.1 Sprite Entry Format (8 × 16-bit words = 16 bytes per sprite)

```
Word 0: [tttt tttt tttt tttt]
  bits[15:0] = Tile number lower 16 bits

Word 1: [yyyy yyyy xxxx xxxx]
  bits[15:8] = Y zoom byte (y_zoom): scale = (0x100 - y_zoom) / 256 ≈ vertical shrink
  bits[7:0]  = X zoom byte (x_zoom): scale = (0x100 - x_zoom) / 256 ≈ horizontal shrink
  0x00 = no zoom (full size, 16×16px rendered)
  0xFF = zero-size (invisible)
  0x80 = half size

Word 2: [iiss xxxx xxxx xxxx]
  bits[15:14] = Scroll ignore/set mode (i: ignore global scroll, s: set-scroll)
  bits[11:0]  = X screen position (signed 12-bit: -2048..+2047; visible range ~0..319)

Word 3: [c... yyyy yyyy yyyy]
  bit [15]    = Command bit (1 = word 5 contains command data, not tile MSB)
  bits[11:0]  = Y screen position (signed 12-bit)

Word 4: [bbbb mlyx cccc cccc]
  bits[15:12] = Block control:
                  [15:13] = x_num (columns - 1 for multi-tile block, up to 8)
                  [12]    = y_num high bit (combined with other bits for row count)
  bit [11]    = Lock (inherit position/zoom from previous block anchor)
  bit [10]    = flipY (1 = vertical flip)
  bit [9]     = flipX (1 = horizontal flip)
  bits[7:0]   = Color palette index (8-bit; palette line = color * 16 colors)

Word 5 (normal mode, Word3[15]=0):
  bit [0]     = Tile number bit 16 (MSB; combined: final_tile = Word0 | (bit16 << 16))

Word 5 (command mode, Word3[15]=1):
  bit [0]     = Sprite bank select (b): selects which half of sprite ROM bank
  bit [1]     = Sprite trails (t): 1 = don't clear sprite framebuffer (Darius Gaiden effect)
  bits[9:8]   = Extra planes (pp): 00=4bpp, 01=5bpp, 11=6bpp (overrides per-tile depth)
  bit [13]    = Flipscreen enable (f)
  bit [14]    = Unknown (A) — seen in ridingf

Word 6: [j... ..ii iiii iiii]
  bit [15]    = Jump bit: 1 = skip to sprite at index bits[9:0] in sprite RAM
  bits[9:0]   = Jump target index (0–1023)

Word 7: [.... .... .... ....]
  Unused (zero)
```

### 8.2 Multi-Tile (Block) Sprites

When Word4[15:12] (block control) is non-zero, the sprite is the **anchor** of a multi-tile
block. Subsequent sprite entries in descending RAM order contribute individual tiles to the
block. The anchor stores the overall x_num × y_num tile dimensions; subsequent entries
inherit zoom from the anchor and are positioned automatically in a grid.

**Tile traversal order:** Y advances first (y_no 0→y_num), then X (x_no 0→x_num), matching
a standard left-to-right, top-to-bottom raster order.

### 8.3 Sprite Rendering Order

Sprites are processed from **end of RAM toward start** (descending address). The sprite with
the lowest RAM address is drawn last (highest priority — on top). This is the same convention
as most Taito sprite engines.

### 8.4 Priority Groups

Sprites belong to one of 4 priority groups (0x00, 0x40, 0x80, 0xC0) determined by the
color field bits[7:6]. Each group can have an independent alpha blend mode and priority
relative to tilemap layers, set per-scanline via Line RAM (§9.7).

---

## 9. Line RAM (0x620000–0x62FFFF, 64KB)

The Line RAM is the most complex register structure on the system. It provides **per-scanline**
override of virtually every display parameter. There are 256 scanline entries per section
(one 16-bit word per scanline per section, with sections spaced 0x200 bytes apart).

All Line RAM addresses are chip-relative (add 0x620000 for CPU address).

**Overall structure:** The 64KB is divided into two halves:
- `0x0000–0x3FFF`: Enable/latch control bitfields (which sections are active)
- `0x4000–0xFFFF`: Per-scanline data values

### 9.1 Enable/Latch Control (0x0000–0x3FFF)

```
0x0000–0x01FF: Enable bits for column scroll / alt-tilemap (PF3/PF4)
0x0200–0x03FF: Enable bits for clip planes 0–1
0x0400–0x05FF: Enable bits for blend control / mosaic
0x0600–0x07FF: Enable bits for pivot/sprite layer mixing
0x0800–0x09FF: Enable bits for playfield zoom
0x0A00–0x0BFF: Enable bits for palette addition
0x0C00–0x0DFF: Enable bits for playfield rowscroll
0x0E00–0x0FFF: Enable bits for playfield mix/priority info
```

Each entry: bits[3:0] = enable per playfield (PF1–PF4), bits[7:4] = alternate subsection
select (used by Bubble Memories for double-buffered line data).

### 9.2 Column Scroll & Alt-Tilemap (0x4000–0x41FF per-PF, step 0x200)

```
PF1: 0x4000–0x41FE
PF2: 0x4200–0x43FE
PF3: 0x4400–0x45FE
PF4: 0x4600–0x47FE
```

Format (16-bit word, one per scanline):
```
Bits [8:0]  = Column scroll offset (0–511 pixels; applied as column X shift)
Bit  [9]    = Alt-tilemap flag: 1 = use secondary tilemap (+0x2000 offset in playfield RAM)
Bits [13:12] = Clip plane 0: left boundary high bits (combined with clip data section)
Bits [15:14] = Clip plane 1: left boundary high bits
```

### 9.3 Clip Plane Data (0x5000–0x57FF)

Four clip planes, each with 256 per-scanline left/right boundary pairs.

```
Plane 0: 0x5000–0x51FE
Plane 1: 0x5200–0x53FE
Plane 2: 0x5400–0x55FE
Plane 3: 0x5600–0x57FE
```

Format per word:
```
Bits [15:8] = Right boundary (0–255 pixel coordinate)
Bits [7:0]  = Left boundary  (0–255 pixel coordinate)
High bits from column scroll section (§9.2) extend these to 9-bit values.
```

Clip behavior: Each playfield independently selects which planes to use (via mix info §9.8).
- **Normal mode:** Active region = intersection of enabled windows (max of left edges,
  min of right edges).
- **Invert mode (clip_invert bit set):** Active region = union of windows (min of left
  edges, max of right edges), effectively showing content *outside* the clipping window.

Two games (pbobble4, commandw) show reversed inversion logic, suggesting a hardware
revision or undocumented inversion-sense control bit.

### 9.4 Pivot/Sprite Blend Control (0x6000–0x61FF)

Per-scanline blend and enable configuration for the pivot and sprite layers.

Format (16-bit word):
```
Bits [15:8] = Pixel/VRAM layer control byte:
  bit [0]   = Alpha blend select (A=0 or B=1)
  bit [5]   = Pixel layer enable
  bit [6]   = Pixel bank select (which page of pivot RAM to display)

Bits [7:0]  = Sprite alpha mode per priority group:
  bits [7:6] = Mode for priority group 0xC0
  bits [5:4] = Mode for priority group 0x80
  bits [3:2] = Mode for priority group 0x40
  bits [1:0] = Mode for priority group 0x00
  Mode encoding: 00=opaque, 01=normal blend, 10=reverse blend, 11=opaque (layer)
```

### 9.5 Alpha Blend Values (0x6200–0x63FF)

Per-scanline alpha factor pairs. Two 4-bit values per blend channel.

```
Format (16-bit word):
  Bits [15:12] = B_src: source contribution in reverse-blend mode (0=none, 8=full)
  Bits [11:8]  = A_src: source contribution in normal-blend mode
  Bits [7:4]   = B_dst: destination contribution in reverse-blend mode
  Bits [3:0]   = A_dst: destination contribution in normal-blend mode

Alpha formula: out = saturate(src * (A_src/8) + dst * (A_dst/8))
Range: 0 (transparent) to 8 (opaque). Value 8 = full contribution.
```

### 9.6 Mosaic / X-Sample (0x6400–0x65FF)

Per-scanline mosaic (pixel-block) effect control.

```
Bits [11:8] = X mosaic rate: sample every N+1 pixels (0=no mosaic/1px, F=every 16px)
Bits [3:0]  = Mosaic enable per layer:
  bit [0]  = PF1 enable
  bit [1]  = PF2 enable
  bit [2]  = PF3 enable
  bit [3]  = PF4 enable
Bit  [8]   = Sprite mosaic enable
Bit  [9]   = Pivot layer mosaic enable
Bits [15:12] = Palette depth (unimplemented in MAME)
```

Mosaic implementation: `effective_x = x - ((x - H_START + 114) % 432 % sample_rate)` where
sample_rate = mosaic_rate + 1.

### 9.7 Sprite Mix and Priority (0x7400–0x75FF)

Per-scanline sprite layer blend and clip configuration.

```
Bits [15:12] = Alpha blend select per priority group (4 groups × 1 bit each)
Bit  [1]     = Enable
Bit  [0]     = Clip inversion flag
Bits [11:8]  = Clip enable (one bit per clip plane, 4 planes)
Bits [7:4]   = Clip inverse mode (per clip plane)
```

### 9.8 Sprite Priority Groups (0x7600–0x77FF)

Per-scanline priority encoding for the 4 sprite priority groups.

```
Bits [15:12] = Priority for group 0xC0 (0–15)
Bits [11:8]  = Priority for group 0x80 (0–15)
Bits [7:4]   = Priority for group 0x40 (0–15)
Bits [3:0]   = Priority for group 0x00 (0–15)
```

### 9.9 Playfield Zoom (0x8000–0x89FF, one entry per PF per scanline)

Per-scanline zoom factors for each playfield. 4 layers × 256 lines × 2 bytes.

```
PF1: 0x8000–0x81FF
PF2: 0x8400–0x85FF   (note: PF2 and PF4 Y-zoom values are SWAPPED in hardware)
PF3: 0x8200–0x83FF
PF4: 0x8600–0x87FF   (PF2/PF4 interleave: hardware stores PF2 where PF4 expected)
```

Format per word:
```
Bits [15:8] = Y scale: 0x80 = no scale (1:1), >0x80 = zoom in, <0x80 = zoom out
              (0xC0 = half height of 0x80 mode)
Bits [7:0]  = X scale: 0x00 = no scale, >0x00 = zoom in
              16.16 fixed-point accumulator used for sub-pixel accuracy
```

Note: PF2 and PF4 Y-zoom entries are physically swapped in the Line RAM — MAME corrects
for this in the zoom read logic.

### 9.10 Palette Addition (0x9000–0x99FF)

Per-scanline palette offset added to each tile's palette index.

```
PF1: 0x9000–0x91FF
PF2: 0x9200–0x93FF
PF3: 0x9400–0x95FF
PF4: 0x9600–0x97FF
```

Format: 16-bit value = palette_offset × 16 (added to tile palette index before lookup).
Used for color-cycling effects and palette bank switching on a per-scanline basis.

### 9.11 Rowscroll (0xA000–0xA9FF)

Per-scanline horizontal scroll override for each playfield.

```
PF1: 0xA000–0xA1FF
PF2: 0xA200–0xA3FF
PF3: 0xA400–0xA5FF
PF4: 0xA600–0xA7FF
```

Format: 16-bit signed fixed-point (fractional bits inverted). Overrides global X scroll
for that scanline. At 16.16 fixed-point precision with sub-pixel accumulation.

### 9.12 Playfield Mix / Priority (0xB000–0xB9FF)

Per-scanline layer priority and blend control for each playfield.

```
PF1: 0xB000–0xB1FF
PF2: 0xB200–0xB3FF
PF3: 0xB400–0xB5FF
PF4: 0xB600–0xB7FF
```

Format (16-bit word):
```
Bits [3:0]  = Priority value (0–15; higher number = drawn on top)
Bits [7:4]  = Clip invert flags (per clip plane)
Bits [11:8] = Clip enable flags (per clip plane, 4 bits)
Bit  [12]   = Inversion sense: 1 = invert the clip invert interpretation
Bit  [13]   = Line enable: 1 = this scanline row is active for this layer
Bit  [14]   = Alpha mode A (normal blend enable)
Bit  [15]   = Alpha mode B (reverse blend enable)
```

---

## 10. Palette RAM (0x440000–0x447FFF, 32KB)

0x2000 entries × 16 bits = 32KB. Palette is 24-bit RGB, stored in a Taito-specific packed
format in two consecutive 16-bit words (32-bit longword access).

**Standard palette format:**
```
Longword at 0x440000 + (index * 4):
  Bits [23:20] = Red   (4 bits, expanded to 8-bit as R×17)
  Bits [19:16] = Green (4 bits, expanded to 8-bit as G×17)
  Bits [15:12] = Blue  (4 bits, expanded to 8-bit as B×17)
  Bits [11:0]  = (unused / zero)
```

Some games (ringrage, ridingf, arabianm) use a slightly different packed encoding where
R/G/B each occupy bits [15:12], [11:8], [7:4] of a single 16-bit word (upper bits only).
The exact per-game variant is identified by game_config and handled in the palette_write
callback. MAME uses `palette_24bit_w` for the handler at 0x440000.

**Palette capacity:** 0x2000 × 16-color lines = 32,768 palette entries × 16 colors each
= up to 524,288 addressable colors (though only 32,768 distinct RGB values are stored).

**TC0650FDA interface:** The TC0650FDA DAC chip reads from this palette RAM and outputs
analog RGB signals. The TC0630FDP supplies the palette index stream; TC0650FDA performs
the DAC conversion. (TC0260DAR from Taito F2 is **not** present in F3 — TC0650FDA is the
F3-specific replacement and performs the same function.)

---

## 11. GFX ROM Format

The F3 ROM set consists of multiple ROM regions loaded at specific GFX decode offsets.
All tiles are big-endian, 16×16 pixels for sprites/playfields, 8×8 for text/pivot.

### 11.1 charlayout (8×8, 4bpp — text and pivot layers)

```
Tile size: 8×8 pixels, 4bpp = 32 bytes per tile
GFX decode:
  Plane count: 4
  Planes: {0, 1, 2, 3}  (4 planes, bits 0–3 of each byte)
  X offsets: {20, 16, 28, 24, 4, 0, 12, 8}
  Y offsets: STEP8(0, 4*8)   = {0, 32, 64, 96, 128, 160, 192, 224}
  Char increment: 32*8 = 256 bits per tile
Source: Character RAM (dynamic, CPU-writable) for text layer;
        Pivot RAM for pivot layer
```

### 11.2 pivotlayout (8×8, 4bpp — pivot RAM tiles)

Identical bit geometry to charlayout but references up to 2048 characters (the full
64×32 = 2048-tile pivot layer). Sourced from pivot_ram (dynamic).

### 11.3 Sprite/Tilemap Low-4bpp Layout (16×16, 4bpp base)

Used by GFX decoder indices 2/3. Provides the low 4 bits of each pixel for 4/5/6bpp tiles.

```
Tile size: 16×16 pixels, packed 4bpp
Standard packing: 2 pixels per byte (nibble-packed)
ROM region: "gfx1" or "gfx_lo" — packed_lsb format
Each tile: 128 bytes (16×16 × 4bpp / 2 pixels per byte)
```

### 11.4 Hi-Plane Layout for Sprites (layout_6bpp_sprite_hi)

The upper 2 bits of each pixel (for 6bpp tiles) are stored in a separate ROM region.

```
Planes: {0, 1, 0, 0, 0, 0} (bits contributing to color planes 4 and 5)
X offsets: STEP4(3*2, -2) repeated for 4 groups of 4 = {6,4,2,0, 22,20,18,16, ...}
Y offsets: STEP16(0, 16*2) = {0, 32, 64, ..., 480}
Char increment: 16*16*2 bits = 512 bits per tile
ROM region: "gfx_hi_spr" or equivalent
```

### 11.5 Hi-Plane Layout for Tiles (layout_6bpp_tile_hi)

```
Planes: {8, 0, 0, 0, 0, 0} (contributing planes 4 and 5)
X offsets: STEP8(7, -1) for left half + STEP8(8*2+7, -1) for right half
Y offsets: STEP16(0, 8*2*2) = {0, 32, 64, ..., 480}
Char increment: 16*16*2*... bits per tile
ROM region: "gfx_hi_tile" or equivalent
```

### 11.6 6bpp Composite Decoding

For a 6bpp pixel, MAME combines two GFX objects:
- Object at gfx(2): low 4 bits from packed_lsb layout
- Object at gfx(3): high 2 bits from hi layout

The final 6-bit pen index is `(hi_2bits << 4) | lo_4bits`, accessing up to 64 colors per
palette line. The **bitwise OR** combination with palette bits means the extra plane bits
alias into the low palette address lines (not a simple pen extension).

### 11.7 bubsympb (Bubble Bobble 2) Variant

Bubble Bobble 2 uses a different sprite ROM layout (5bpp planar, not packed+hi):

```
Sprite layout: 16×16, 5bpp fully planar (5 separate bit planes)
Tile layout: 16×16, 4bpp packed lsb (standard for tilemaps)
Total sprite ROM: 5 planes × (16×16 bits) = 5 separate ROM layers
GFXDECODE entries: bubsympb_sprite_layout + standard gfx_16x16x4_packed_lsb
```

---

## 12. Layer Priority System

The compositing system uses a **per-pixel 8-bit priority buffer** (`pri_alp_bitmap`). During
scanline assembly, each layer writes its priority value into this buffer; the compositing
logic tests whether a candidate pixel's priority exceeds the current buffer value before
committing the pixel to the output.

Priority values 0–15 are assigned per-scanline via Line RAM (§9.8 for sprites, §9.12 for
playfields). Higher numeric values = drawn on top.

### 12.1 Priority Modes

The compositing engine tracks two priority channels per pixel: `src_prio` (source priority
= who can draw here) and `dst_prio` (destination priority = minimum priority to contribute
to blended destination). This allows the system to implement:

- **Simple layering:** Higher priority overwrites lower, no blend
- **Alpha blending between layers:** A lower-priority layer bleeds through a higher-priority
  transparent layer when blend modes are active
- **Sprite-to-playfield blending:** Sprites at a given priority group can be blended with
  playfields at the same or adjacent priority level

### 12.2 Blend Modes

Four blend mode combinations from the playfield mix word [15:14] and sprite mix:

```
Mode 00: Opaque — sprite/layer replaces destination fully
Mode 01: Normal blend — out = src*(A_src/8) + dst*(A_dst/8), values from §9.5
Mode 10: Reverse blend — use B coefficients (B_src/8, B_dst/8) instead
Mode 11: Opaque layer — same as 00 but tracked separately for compositor
```

Alpha values 0–8 represent 0.0–1.0 in fixed-point 3.0 format (0 = fully transparent,
8 = fully opaque). The blend formula uses **saturating addition** (clamp to 255).

The `dpix_n[8][16]` function table in MAME dispatches to one of 8 blend function variants
based on the active alpha mode, with 16 priority sub-modes each.

### 12.3 Clip Planes

4 clip planes are evaluated per scanline. Each plane defines a window [left, right].
Playfields and sprites independently select which clip planes apply via the enable bits
in their respective mix registers (§9.7, §9.12).

After clip plane application, the final compositing window for each layer is:
- **Normal:** intersection of all enabled clip windows
- **Inverted:** complement of the intersection (show outside the window)

### 12.4 Known Hardware Quirks

1. **Darius Gaiden blending conflict:** The hardware has a specific blending priority conflict
   when the same pixel is simultaneously targeted by two blending layers. MAME PR #11811
   added emulation of this artifact.
2. **Sprite trails (unblit disable):** Word5 bit[1] prevents the sprite framebuffer from
   being cleared between frames, creating motion-trail effects (used in Darius Gaiden).
3. **Bubble Memories alternate line data:** Uses Line RAM alternate subsection switching
   (bits[7:4] of the enable section) for double-buffered per-scanline effect tables.
4. **Palette OR vs ADD:** High GFX planes are bitwise-OR'd into palette address, not added.
   This causes color "overlap" at palette boundaries (corrected in MAME PR #11788).

---

## 13. Screen Flip

No dedicated screen-flip register has been identified in the control register set. Screen
flip is implemented via Sprite word5 command mode bit[13] (f = flipscreen enable), applied
globally. When active, all coordinates are mirrored about the screen center.

---

## 14. Interrupts

```
INT2 (68EC020 autovector 2): VBLANK — fires at start of vertical blank
INT3 (68EC020 autovector 3): Pseudo-hblank timer — fires ~10,000 CPU cycles after INT2
```

INT3 is used for mid-frame register updates (palette changes, scroll updates). The exact
timing of INT3 varies per game and is configured during POST initialization. The MAME
comment notes this as "TODO" for precise cycle counting.

---

## 15. Reusable Chips for Taito F3 Core

| Chip | Function | Status for F3 FPGA |
|------|----------|-------------------|
| TC0260DAR | Palette/DAC (Taito F2) | **NOT present** in F3 — use TC0650FDA |
| TC0650FDA | Palette DAC (F3-specific) | **Must implement** — functionally similar to TC0260DAR |
| TC0640FIO | I/O controller | Functionally analogous to TC0220IOC (F2) — partial reuse possible |
| TC0660FCM | Control/comm module | Unknown — likely simple glue logic |
| TC0400YSC | Sound interface (F3 older games) | May reuse TC0140SYT pattern |

The TC0650FDA is the closest analog to TC0260DAR. If TaitoF2_MiSTer's `tc0260dar.sv` is
available, it provides an architectural template — the F3 DAC uses the same palette-index-in,
RGB-out principle but with the F3-specific 24-bit palette format.
