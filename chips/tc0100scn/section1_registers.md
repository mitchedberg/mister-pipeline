# TC0100SCN — Section 1: Register Map and RAM Layout

Human-verified against MAME source `src/mame/taito/tc0100scn.cpp` and `tc0100scn.h` (rev. master, 2024-03), cross-checked against `src/mame/taito/taito_f2.cpp` game address maps. No jotego jtcores TC0100SCN implementation exists as of 2026-03.

---

## 1. CPU Bus Interface

The TC0100SCN presents two distinct address windows to the 68000 CPU:

| Window     | Size    | Purpose                         |
|------------|---------|---------------------------------|
| RAM window | 0x10000 bytes (standard) or 0x14000 bytes (double-width) | Tilemap data, scroll tables, FG character graphics |
| Control register window | 0x10 bytes | 8 × 16-bit control registers |

Both windows are mapped as 16-bit (word-width) regions on the 68000 bus. Byte enables (UDS/LDS) are honored; the chip supports byte-wide and word-wide accesses.

The RAM window base address and the control register window base address are determined by the system board and vary by game (see typical game maps in `notes_hardware.md`). The control registers are almost always mapped at RAM_base + 0x20000 in practice.

---

## 2. Standard RAM Layout (single-width, 64×64 tilemaps)

Total RAM: 0x10000 bytes (64 KB), provided by two external 32K×8 SRAMs (SCE0 chip-select). The optional SCE1-connected RAM for double-width is not populated on single-screen boards.

All word offsets below are byte addresses. Data bus is 16 bits wide; each word is two bytes.

| Byte Range       | Size     | Contents                                      |
|------------------|----------|-----------------------------------------------|
| `0x0000–0x3FFF`  | 16 KB    | BG0 tilemap — 64×64 tiles × 2 words per tile = 0x2000 words (4 bytes/tile) |
| `0x4000–0x5FFF`  | 8 KB     | BG1 tilemap — 64×64 tiles × 2 words per tile |
| `0x6000–0x6FFF`  | 4 KB     | FG0 character graphic data (2bpp packed, 256 chars × 8×8 pixels) |
| `0x7000–0x7FFF`  | 4 KB     | Unused (probably)                             |
| `0x8000–0x9FFF`  | 8 KB     | FG0 tilemap — 64×64 tiles × 1 word per tile  |
| `0xA000–0xBFFF`  | 8 KB     | Unused (probably)                             |
| `0xC000–0xC3FF`  | 1 KB     | BG0 rowscroll RAM — 512 words (first 256 used) |
| `0xC400–0xC7FF`  | 1 KB     | BG1 rowscroll RAM — 512 words (first 256 used) |
| `0xC800–0xDFFF`  | 6 KB     | Unused (probably)                             |
| `0xE000–0xE0FF`  | 256 B    | BG1 colscroll RAM — 128 words                 |
| `0xE100–0xFFFF`  | ~8 KB    | Unused (probably)                             |

**Note on "second half unused" rowscroll:** MAME source comment states games init the entire 512-word rowscroll region as "linescroll", suggesting Taito may have intended optional double-height support. In practice, only the first 256 words (one per visible scanline) are used.

### BG Tilemap Entry Format (2 words per tile, 4 bytes total)

Each BG tile cell occupies two consecutive 16-bit words in RAM. For tile at position (col, row) in a 64×64 map:

    word_offset = (row * 64 + col) * 2

| Word | Bits  | Field    | Description                                        |
|------|-------|----------|----------------------------------------------------|
| 0    | 15–14 | FLIP     | `00` = no flip, `01` = X flip, `10` = Y flip, `11` = XY flip |
| 0    | 13–8  | (unused) | Not decoded by chip                                |
| 0    | 7–0   | COLOR    | Palette index (0–255). Added to per-layer colbank. |
| 1    | 15–0  | CODE     | Tile index into ROM (0–0xFFFF, 16-bit, 65536 tiles max) |

FLIP is decoded from `attr & 0xC000` >> 14 as a TILE_FLIPYX value (MAME convention matches hardware).

The colbank offset for each BG layer is added to COLOR before palette lookup. Default colbank for both BG layers is 0; some games (WGP) set non-zero colbanks.

### FG Tilemap Entry Format (1 word per tile)

Each FG cell occupies one 16-bit word:

| Bits  | Field    | Description                                               |
|-------|----------|-----------------------------------------------------------|
| 15–14 | FLIP     | `00` = no flip, `01` = X flip, `10` = Y flip, `11` = XY flip |
| 13–8  | COLOR    | 6-bit palette index (0–63), added to FG colbank           |
| 7–0   | CODE     | Character index into FG character RAM (0–255, 256 chars)  |

FG tile data is sourced from the internal character RAM at `0x6000–0x6FFF`, not from the external tile ROM. The character ROM is CPU-writeable, enabling dynamic character generation.

---

## 3. Double-Width RAM Layout (128×64 BG tilemaps)

Enabled by control register bit `ctrl[6] & 0x10`. Requires optional external RAM (SCE1). Total RAM: 0x14000 bytes (80 KB).

| Byte Range          | Size     | Contents                                           |
|---------------------|----------|----------------------------------------------------|
| `0x00000–0x07FFF`   | 32 KB    | BG0 tilemap — 128×64 tiles × 2 words per tile      |
| `0x08000–0x0FFFF`   | 32 KB    | BG1 tilemap — 128×64 tiles × 2 words per tile      |
| `0x10000–0x103FF`   | 1 KB     | BG0 rowscroll RAM — 512 words                      |
| `0x10400–0x107FF`   | 1 KB     | BG1 rowscroll RAM — 512 words                      |
| `0x10800–0x108FF`   | 256 B    | BG1 colscroll RAM — 128 words                      |
| `0x10900–0x10FFF`   | ~3.5 KB  | Unused                                             |
| `0x11000–0x11FFF`   | 4 KB     | FG0 character graphic data (double-width layout)   |
| `0x12000–0x13FFF`   | 8 KB     | FG0 tilemap — 128×32 tiles × 1 word per tile       |

The double-width layout is used by Cameltry and all multi-screen games (Warriorb, etc.).

---

## 4. Rowscroll RAM Format

BG0 and BG1 each have a dedicated rowscroll RAM. Both are organized identically.

The rowscroll RAM holds one signed 16-bit offset per tilemap row of 8 pixels. Because the visible display is 256 scanlines tall and tiles are 8 pixels high, 256 entries are used (32 rows × 8 lines/row = 256, but the ram is indexed by scanline, not tile row).

Entry N gives the additional X-scroll offset applied to tilemap row N (where N is counted in pixel scanlines 0–255 relative to the top of the tilemap after global Y-scroll). The per-row X offset is added to the global scroll X for that row.

During `tilemap_update()`, MAME applies rowscroll as:

    tilemap.set_scrollx((scanline + global_scrolly) & 0x1FF, global_scrollx - rowscroll_ram[scanline])

The `& 0x1FF` wraps at 512, matching the 512-entry scroll row limit set on the tilemap engine.

---

## 5. Colscroll RAM Format

Only BG1 has colscroll (the topmost priority background layer by default). The colscroll RAM holds 128 signed 16-bit words.

Entry N gives the Y-scroll offset applied to column-group N. Each entry covers 8 pixels of horizontal screen width (one tile column). With the standard 320-pixel display width, 40 entries cover the full visible area.

Colscroll is applied at pixel render time in `tilemap_draw_fg()`. For each pixel at tilemap-space X position `src_x`, the effective Y is:

    effective_y = (src_y - colscroll_ram[(src_x & 0x3FF) / 8]) & height_mask

The colscroll RAM address is indexed by tilemap-space X divided by 8, not screen-space X. This means the colscroll effect tracks with horizontal scroll, not screen position.

---

## 6. Control Registers

The control register window is 0x10 bytes wide (8 × 16-bit registers). CPU offset is in words; byte address = ctrl_base + (offset × 2).

| Word Offset | Byte Offset | Name        | Direction | Description                                |
|-------------|-------------|-------------|-----------|-------------------------------------------|
| `0x00`      | `0x00–0x01` | BG0_SCROLLX | W         | BG0 global horizontal scroll (16-bit signed, negated internally) |
| `0x01`      | `0x02–0x03` | BG1_SCROLLX | W         | BG1 global horizontal scroll              |
| `0x02`      | `0x04–0x05` | FG0_SCROLLX | W         | FG0 horizontal scroll                     |
| `0x03`      | `0x06–0x07` | BG0_SCROLLY | W         | BG0 global vertical scroll (16-bit signed, negated internally) |
| `0x04`      | `0x08–0x09` | BG1_SCROLLY | W         | BG1 global vertical scroll                |
| `0x05`      | `0x0A–0x0B` | FG0_SCROLLY | W         | FG0 vertical scroll                       |
| `0x06`      | `0x0C–0x0D` | LAYER_CTRL  | R/W       | Layer enable, priority, width mode. See bit fields. |
| `0x07`      | `0x0E–0x0F` | FLIP_CTRL   | R/W       | Screen flip and subsidiary chip flags. See bit fields. |

All registers are read/write (ctrl_r and ctrl_w both implemented). The chip restores state from ctrl[] on save-state load via `restore_scroll()`.

### LAYER_CTRL Bit Fields (ctrl[6])

| Bit | Description                                                                                         |
|-----|-----------------------------------------------------------------------------------------------------|
| 0   | BG0 disable. When set, layer 0 (BG0) is not drawn.                                                 |
| 1   | BG1 disable. When set, layer 1 (BG1) is not drawn.                                                 |
| 2   | FG0 disable. When set, layer 2 (FG0) is not drawn.                                                 |
| 3   | Priority swap. `0` = BG0 below BG1 (BG0 is bottom, BG1 on top). `1` = BG1 below BG0 (BG1 is bottom, BG0 on top). FG0 is always topmost. |
| 4   | Double-width enable. `0` = standard 64×64 tilemaps; `1` = 128×64 BG tilemaps + double-width memory map. Changing this bit causes the chip to reinitialize its RAM pointer set (bgscroll_ram, fgscroll_ram, colscroll_ram). |
| 5   | Unknown. Set in most TaitoZ games and in Cadash. No confirmed function.                             |
| 6   | (reserved)                                                                                          |
| 7   | (reserved)                                                                                          |

The `disable` mask used in `tilemap_draw()` is `ctrl[6] & 0xF7` — bit 3 is excluded from the disable mask, confirming it is the priority-swap bit, not a disable bit.

The `bottomlayer()` function returns `(ctrl[6] & 0x08) >> 3`: 0 means BG0 is drawn first (bottom), 1 means BG1 is drawn first (bottom). The F2 system driver uses this to determine which layer to draw first and which second.

### FLIP_CTRL Bit Fields (ctrl[7])

| Bit  | Description                                                                                         |
|------|-----------------------------------------------------------------------------------------------------|
| 0    | Flip screen. When set, all three tilemap layers are flipped both X and Y simultaneously (TILEMAP_FLIPX | TILEMAP_FLIPY). |
| 5    | Subsidiary chip flag. Set in multi-screen configurations on the non-primary TC0100SCN. Possibly causes the chip to mirror writes made to the primary chip ("write-through"). Not confirmed from hardware; no MAME emulation code for this bit exists beyond documentation. |
| 13   | Unknown. Observed set in Thunderfox. No confirmed function.                                         |

---

## 7. Scroll Arithmetic

The chip stores scroll values with inversion. When `ctrl_w` is called for offsets 0–5:

    internal_scroll = -data

This means a scroll register value of `0x0005` moves the tilemap 5 pixels to the left (positive values scroll left, negative values scroll right) as seen from the CPU. The MAME tilemap engine then applies `set_scrollx(row, internal_scroll - rowscroll_ram[row])`, producing the final per-row scroll position.

For rowscroll, the row index wraps via `(scanline + bgscrolly) & 0x1FF`. This correctly handles the case where the tilemap Y-scroll has shifted which physical tilemap row is currently at screen top.

---

## 8. GFX Formats

### BG Layer Tiles (ROM-sourced)
- Default: 8×8 pixels, 4 bits per pixel, packed MSB-first in 16-bit words
- Format: `gfx_8x8x4_packed_msb` — two pixels per byte, high nibble first
- Each tile is 32 bytes (8 rows × 4 bytes/row)
- Up to 65536 tiles addressable (16-bit CODE field)
- ROM bus: 16-bit wide (AD0–AD19), 20-bit address = 1 Mword = 2 MB max

### FG Layer Characters (RAM-sourced)
- 8×8 pixels, 2 bits per pixel
- Format: packed, 8 pixels per 2 bytes, row-major
- Each character is 16 bytes (8 rows × 2 bytes/row)
- 256 characters total (8-bit CODE field)
- Source: internal SRAM region (byte address `0x6000–0x6FFF` standard, `0x11000–0x11FFF` double-width)

### TC0620SCC Variant
- BG layer tiles: 6 bits per pixel (4 low bits + 2 high bits from separate ROM region)
- Requires dual ROM banks with separate chip-select
- 64 palette entries per tile instead of 16
- FG layer and control registers: same as TC0100SCN
