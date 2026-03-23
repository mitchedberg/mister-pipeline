# Sega System 32 — Hardware Reference

Extracted from MAME `src/mame/sega/segas32_v.cpp` and `src/mame/sega/segas32.cpp`.
Source commit: mamedev/mame master (fetched 2026-03-23).

---

## Overview

System 32 is a 1992–1996 Sega arcade board using a NEC V60 (16/32-bit) CPU.
Games: Rad Mobile, Rad Rally, Golden Axe: The Revenge of Death Adder,
       Alien³: The Gun, Spider-Man: The Video Game, Outrunners, etc.

Custom video ICs:
- **315-5385** (QFP128) — tilemap/scroll processor
- **315-5386A** (QFP184) — sprite processor
- **315-5387** (QFP160) — mixer/priority/palette
- **315-5388** (QFP160) — mixer/priority/palette (second display for Multi 32)

---

## Memory Map (V60 CPU)

| Address Range       | Size  | Name              | Notes                         |
|---------------------|-------|-------------------|-------------------------------|
| `$300000–$31FFFF`   | 128KB | Video RAM (VRAM)  | Tilemaps, gfx, scroll tables  |
| `$400000–$41FFFF`   | 128KB | Sprite RAM        | Linked-list sprite commands   |
| `$500000–$50000F`   | 16B   | Sprite Control    | 8-bit registers               |
| `$600000–$60FFFF`   | 64KB  | Palette RAM       | 16-bit RGB555 words           |
| `$610000–$61007F`   | 128B  | Mixer Control     | Per-layer priorities, blend   |
| `$680000–$68FFFF`   | 64KB  | Palette RAM #2    | Multi 32 second display only  |

VRAM is mirrored every `0x20000` bytes. Sprite RAM every `0x20000`. Palette every `0x10000`.

### Video Control Registers (within VRAM, $1FF00–$1FF8E)

The V60 writes these as 16-bit words through the normal VRAM interface at CPU addresses
`$31FF00–$31FF8E`. The video hardware latches them each frame.

| VRAM Byte Offset | Word Address | Register    | Bit Fields                                        |
|------------------|--------------|-------------|---------------------------------------------------|
| `$1FF00`         | `$FF80`      | CTRL        | [15]=wide(416px), [9]=global_flip, [3:0]=layer_flip |
| `$1FF02`         | `$FF81`      | LAYER_EN    | bit-per-layer disable; per-layer clip mode        |
| `$1FF04`         | `$FF82`      | ROWSCRL     | rowscroll/rowselect enables NBG2/NBG3             |
| `$1FF06`         | `$FF83`      | CLIP_SEL    | 4 bits per layer: which clip rect to use          |
| `$1FF12`         | `$FF89`      | NBG0_XSCRL  | NBG0 X scroll (signed 12.4 fixed-point)           |
| `$1FF16`         | `$FF8B`      | NBG0_YSCRL  | NBG0 Y scroll                                     |
| `$1FF1A`         | `$FF8D`      | NBG1_XSCRL  | NBG1 X scroll                                     |
| `$1FF1E`         | `$FF8F`      | NBG1_YSCRL  | NBG1 Y scroll                                     |
| `$1FF22`         | `$FF91`      | NBG2_XSCRL  | NBG2 X scroll                                     |
| `$1FF26`         | `$FF93`      | NBG2_YSCRL  | NBG2 Y scroll                                     |
| `$1FF2A`         | `$FF95`      | NBG3_XSCRL  | NBG3 X scroll                                     |
| `$1FF2E`         | `$FF97`      | NBG3_YSCRL  | NBG3 Y scroll                                     |
| `$1FF30`         | `$FF98`      | NBG0_XOF    | NBG0 zoom center X (for zoom pivot)               |
| `$1FF32`         | `$FF99`      | NBG0_YOF    | NBG0 zoom center Y                                |
| `$1FF34`         | `$FF9A`      | NBG1_XOF    | NBG1 zoom center X                                |
| `$1FF36`         | `$FF9B`      | NBG1_YOF    | NBG1 zoom center Y                                |
| `$1FF40`         | `$FFA0`      | NBG0_PAGE   | Page select: 4 quadrants × 7 bits each            |
| `$1FF42`         | `$FFA1`      | NBG1_PAGE   |                                                   |
| `$1FF44`         | `$FFA2`      | NBG2_PAGE   |                                                   |
| `$1FF46`         | `$FFA3`      | NBG3_PAGE   |                                                   |
| `$1FF50`         | `$FFA8`      | NBG0_ZOOMX  | NBG0 X zoom step (0x200 = 1.0x scale)             |
| `$1FF52`         | `$FFA9`      | NBG0_ZOOMY  | NBG0 Y zoom step                                  |
| `$1FF54`         | `$FFAA`      | NBG1_ZOOMX  | NBG1 X zoom step                                  |
| `$1FF56`         | `$FFAB`      | NBG1_ZOOMY  | NBG1 Y zoom step                                  |
| `$1FF5C`         | `$FFAE`      | TEXT_CFG    | [8:4]=map_page, [2:0]=tile_bank                   |
| `$1FF5E`         | `$FFAF`      | BG_CFG      | [9:0]=background palette index                    |
| `$1FF60–$1FF6E`  | `$FFB0–$FFB7`| CLIP_RECT_0 | left, top, right, bottom (4 × 16-bit words)       |
| `$1FF68–$1FF6E`  | `$FFB4–$FFB7`| CLIP_RECT_1 |                                                   |
| `$1FF70–$1FF76`  | `$FFB8–$FFBB`| CLIP_RECT_2 |                                                   |
| `$1FF78–$1FF7E`  | `$FFBC–$FFBF`| CLIP_RECT_3 |                                                   |
| `$1FF88`         | `$FFC4`      | BMP_XSCRL   | Bitmap X scroll (9 bits)                          |
| `$1FF8A`         | `$FFC5`      | BMP_YSCRL   | Bitmap Y scroll                                   |
| `$1FF8C`         | `$FFC6`      | BMP_PAL     | Bitmap palette base [9:3]                         |
| `$1FF8E`         | `$FFC7`      | OUT_CTRL    | Per-layer output disable (6 bits)                 |

---

## Tilemap Architecture

### Layer Summary

| Layer   | Tile Size | GFX Depth | Scroll Type     | Map Location (VRAM word addr)       |
|---------|-----------|-----------|-----------------|-------------------------------------|
| TEXT    | 8×8       | 4bpp      | Global scroll   | `$E000` + page×`$80` (64×32 tiles) |
| NBG0    | 16×16     | 4 or 8bpp | Zoom + offset   | Selected by NBG0_PAGE register      |
| NBG1    | 16×16     | 4 or 8bpp | Zoom + offset   | Selected by NBG1_PAGE register      |
| NBG2    | 16×16     | 4 or 8bpp | Rowscroll       | Selected by NBG2_PAGE register      |
| NBG3    | 16×16     | 4 or 8bpp | Rowscroll       | Selected by NBG3_PAGE register      |
| BITMAP  | —         | 4 or 8bpp | X/Y scroll      | `$FC00`+ in VRAM                    |

### NBG0/NBG1/NBG2/NBG3 Tile Map Entry (16-bit word)

```
bit 15    : Y flip
bit 14    : X flip
bits 13:4 : color palette index (10 bits → selects 16-entry palette row)
bits 12:0 : tile index (13 bits → up to 8192 tiles)
```

Note: bits[13:4] share overlap; effective tile = bits[12:0], palette = bits[13:4].

### TEXT Tile Map Entry (16-bit word)

```
bits 15:9 : color bank (7 bits → multiplied by 16 for palette address)
bits  8:0 : tile index (9 bits → 0..511)
```

TEXT tiles have **no flip bits** and always use 4bpp from tile bank in VRAM.

### GFX Data Layout — TEXT (8×8 tiles, 4bpp, stored in VRAM)

VRAM word base: `$F000 + tile_bank × $0200` (tile_bank from TEXT_CFG[2:0]).
Each tile: 8 rows × 2 words/row = 16 words.

```
tile_word_base = $F000 + (tile_bank × 0x200) + (tile_idx × 16) + (py × 2)
word0 = vram[tile_word_base + 0]:   px0=bits[3:0], px1=bits[7:4], px2=bits[11:8], px3=bits[15:12]
word1 = vram[tile_word_base + 1]:   px4=bits[3:0], px5=bits[7:4], px6=bits[11:8], px7=bits[15:12]
```

Palette index: `(color_bank × 16) + pen`

### GFX Data Layout — NBG0/NBG1/NBG2/NBG3 (16×16 tiles, 4bpp, from ROM)

Each tile: 16 rows × 8 bytes/row = 128 bytes = 256 nibbles.
Packed 2 pixels/byte (nibble-packed), low nibble first.

ROM byte address: `tile_idx × 128 + py × 8 + (px >> 1)`
Pixel nibble: even px → bits[3:0]; odd px → bits[7:4]

---

## Sprite Engine

### Sprite RAM Organization

- Total: 128 KB (`$400000–$41FFFF`)
- Entry size: 8 × 16-bit words (16 bytes)
- Double-buffered: sprite control register selects active buffer half
- Sprite engine walks the linked list during VBLANK

### Linked List Command Format (word +0, bits[15:14])

| Value | Command     |
|-------|-------------|
| `00`  | Draw sprite |
| `01`  | Set clip rectangle (apply clipping to subsequent sprites) |
| `02`  | Jump / offset adjustment |
| `03`  | End of list (stop processing) |

### Sprite Entry Attribute Format

```
+0  [15:14]=cmd, [13]=indirect_pal, [12]=inline_indirect, [11]=shadow,
    [10]=gfx_from_vram, [9]=8bpp, [8]=opaque, [7]=flipY, [6]=flipX,
    [5]=apply_y_offset, [4]=apply_x_offset, [3:2]=y_align, [1:0]=x_align
+1  [15:8]=src_height, [7:0]=src_width
+2  [9:0]=dst_height  (destination height in pixels, 1-based)
+3  [9:0]=dst_width   (destination width)
+4  [11:0]=Y_pos      (signed, screen Y position)
+5  [11:0]=X_pos      (signed, screen X position)
+6  ROM address / VRAM offset for this sprite's gfx data
+7  [15:4]=palette_select, [3:0]=priority_group
```

### Zoom

- Horizontal zoom: `hzoom = (src_width << 16) / dst_width` (16.16 FP)
- Vertical zoom: `vzoom = (src_height << 16) / dst_height`
- Accumulator advances by zoom step per output pixel

---

## Mixer / Priority System

### Layer Priority

Effective priority: `effpri = {layer_priority[3:0], layer_enum[2:0]}`

| Layer   | layer_enum |
|---------|-----------|
| SPRITE  | 6         |
| TEXT    | 5         |
| NBG0    | 4         |
| NBG1    | 3         |
| NBG2    | 2         |
| NBG3    | 1         |
| BG      | 0         |

Higher effective priority wins. `layer_priority` comes from mixer control registers.

### Mixer Control Registers ($610000–$61007F)

| Word Addr | Byte Offset | Name              | Contents                                      |
|-----------|-------------|-------------------|-----------------------------------------------|
| `$10`     | `$20`       | TEXT pri/pal      | [7:4]=priority, [3:0]=palette_base            |
| `$11`     | `$22`       | NBG0 pri/pal      | [7:4]=priority, [3:0]=palette_base            |
| `$12`     | `$24`       | NBG1 pri/pal      |                                               |
| `$13`     | `$26`       | NBG2 pri/pal      |                                               |
| `$14`     | `$28`       | NBG3 pri/pal      |                                               |
| `$15`     | `$2A`       | BG pri/pal        | [7:4]=priority (should be lowest)             |
| `$00–$07` | `$00–$0E`   | Sprite group prio | 16 nibbles: sprite priority per group 0–15    |
| `$18–$1F` | `$30–$3E`   | Blend masks       | Per-layer blend enable masks                  |
| `$27`     | `$4E`       | Blend ctrl        | [10]=enable, [2:0]=blend_factor (0–7)         |
| `$2F`     | `$5E`       | BG palette        | Background solid color palette index          |

### Palette Lookup Formula

```
pal_addr = (palette_base << 8) | (color_field << 4) | pen
```

For 8bpp layers, `mixshift` adjusts how many bits of the color value are preserved.
Default (4bpp): `mixshift = 0`, no shift applied.

---

## Palette RAM

- **Size**: 16,384 entries × 16-bit (System 32); 32,768 entries (Multi 32)
- **Format**: `{0, B[4:0], G[4:0], R[4:0]}` — RGB555, little-endian
- **Shadow**: bit 15 of the palette entry controls shadow mode (darken effect)
- **Address**: `$600000–$60FFFF` (CPU byte address)

### RGB Expansion (5→8 bit)

```
R8 = {R5, R5[4:2]}
G8 = {G5, G5[4:2]}
B8 = {B5, B5[4:2]}
```

---

## Interrupt / VBLANK Routing

MAME `segas32.cpp` interrupt routing:

| Source           | Vector | Name           | Description                          |
|------------------|--------|----------------|--------------------------------------|
| VBLANK start     | 0      | MAIN_IRQ_VBSTART | Fires at line 224 (start of VBLANK) |
| VBLANK end       | 1      | MAIN_IRQ_VBSTOP  | Fires after VBLANK period ends       |

IRQ control registers at CPU `$D00000–$D0000F`:
- Offset 0–4: vector assignments
- Offset 6: IRQ mask (write to update)
- Offset 7: IRQ acknowledge

Sprite buffer swap occurs ~50µs after VBLANK start (deferred timer callback in MAME).

---

## Screen Timing

### Narrow Mode (320×224, used by Rad Mobile)

| Parameter   | Value     |
|-------------|-----------|
| H active    | 320 px    |
| H total     | 528 clocks |
| H sync start| 336       |
| H sync end  | 392       |
| V active    | 224 lines |
| V total     | 262 lines |
| V sync start| 234       |
| V sync end  | 238       |
| Refresh     | ≈60 Hz    |
| Pixel clock | ≈6.14 MHz (= 528 × 262 × 60.05) |

### Wide Mode (416×224, bit15 of $1FF00 set)

| Parameter   | Value     |
|-------------|-----------|
| H active    | 416 px    |
| H total     | 528 clocks (same — wider pixel clock assumed) |
| V geometry  | Same as narrow |

MAME `MCFG_SCREEN_SIZE(416, 262)` with visible area `(0, 319, 0, 223)` for narrow mode.

---

## VRAM Layout (Word Addresses)

```
$0000–$7FFF  : NBG0 tilemap pages (each 32×16 tiles = 512 words/page, 64 pages max)
$8000–$BFFF  : NBG1 tilemap pages
$C000–$CFFF  : NBG2 tilemap
$D000–$DFFF  : NBG3 tilemap
$E000–$E7FF  : TEXT tilemap (page 0; 64 cols × 32 rows = 2048 words)
               + additional pages at $E000 + page×$80 (via TEXT_CFG[8:4])
$F000–$F7FF  : TEXT gfx data (tile bank 0; 512 tiles × 16 words)
               additional banks at $F000 + bank×$0200
$F800–$FBFF  : Rowscroll tables (NBG2/NBG3 per-line X offsets or Y replacements)
$FC00–$FEFF  : Bitmap data
$FF00–$FFFF  : Reserved / sprite control shadow
$1FF00–$1FF8E: Video control registers (intercepted at VRAM base + offset)
```

---

## RTL Implementation Status

| Component              | Status    | File                           |
|------------------------|-----------|--------------------------------|
| Video timing generator | Done      | `rtl/segas32_video.sv` §1      |
| VRAM (dual-port)       | Done      | `rtl/segas32_video.sv` §2      |
| Sprite RAM             | Done      | `rtl/segas32_video.sv` §3      |
| Sprite control regs    | Done      | `rtl/segas32_video.sv` §4      |
| Palette RAM            | Done      | `rtl/segas32_video.sv` §5      |
| Mixer control regs     | Done      | `rtl/segas32_video.sv` §6      |
| Video ctrl reg decode  | Done      | `rtl/segas32_video.sv` §7      |
| TEXT layer engine      | Done      | `rtl/segas32_video.sv` §8      |
| NBG0 tilemap + zoom    | Stub      | `rtl/segas32_video.sv` §9      |
| NBG1 tilemap + zoom    | Stub      | `rtl/segas32_video.sv` §10     |
| NBG2 tilemap + rowscrl | Stub      | `rtl/segas32_video.sv` §11     |
| NBG3 tilemap + rowscrl | Stub      | `rtl/segas32_video.sv` §12     |
| Sprite engine          | Stub      | `rtl/segas32_video.sv` §13     |
| Background layer       | Done      | `rtl/segas32_video.sv` §14     |
| Pixel mixer            | Done      | `rtl/segas32_video.sv` §15     |
| Testbench              | Done      | `rtl/segas32_video_tb.sv`      |

### Next Steps (priority order)

1. **NBG0/NBG1 tilemap engine** — add VRAM map reader + GFX ROM tile fetch + zoom accumulator
2. **NBG2/NBG3 rowscroll** — add rowscroll table reader, per-scanline X/Y adjust
3. **Sprite engine** — linked-list walker + zoom + double-buffer swap
4. **TEXT scroll** — wire text_scrollx/y from scroll registers (currently uses vpos directly)
5. **Clip rectangles** — implement per-layer clipping in mixer
6. **Blend** — implement alpha blend in mixer when blend_en is set
7. **Wide mode** — wire reg_wide to H_ACTIVE multiplexer

---

## Reference Sources

- `src/mame/sega/segas32_v.cpp` — Full video hardware emulation
- `src/mame/sega/segas32.cpp` — V60 driver, memory map, interrupt routing
- MAME functions of interest:
  - `update_tilemap_zoom()` — NBG0/NBG1 zoom rendering
  - `update_tilemap_rowscroll()` — NBG2/NBG3 rowscroll rendering
  - `draw_one_sprite()` — single sprite with zoom
  - `mix_all_layers()` — priority compositor
  - `compute_clipping_extents()` — clip rect merge algorithm
