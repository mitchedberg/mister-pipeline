# TC0180VCU — Section 1: Register Map & Memory Layout

**Source:** MAME `src/mame/taito/tc0180vcu.cpp` + `tc0180vcu.h` (Nicola Salmoria / Jarek Burczynski)
**System:** Taito B (1988–1994): Ninja Warriors, Crime City, Rastan Saga II, Thunder Fox, Rambo III, etc.
**Status:** Greenfield — zero existing FPGA implementations as of 2026-03.

---

## 1. Chip Overview

The TC0180VCU is Taito B's sole graphics controller. Unlike the Taito F2 system (which has separate TC0100SCN, TC0200OBJ, TC0360PRI chips), TC0180VCU integrates all video functions into one chip:

- Two 16×16 tilemap layers (BG + FG, 64×64 tile maps)
- One 8×8 text layer (TX, 64×32 tile map)
- Sprite engine with zoom and "big sprite" multi-tile groups
- Double-buffered sprite framebuffer (sprites rendered to FB during VBLANK)
- Line-granularity scroll RAM for BG/FG
- All within a 512KB CPU address window

**CPU:** MC68000 @ 12 MHz
**System chips reusable from TaitoF2_MiSTer:** TC0260DAR (DAC), TC0220IOC (I/O), TC0140SYT (sound)

---

## 2. CPU Address Space (chip-relative, 512KB window at 0x400000 on Taito B)

```
Chip-relative  CPU-bus (Nastar)  Size    Contents
0x00000-0x0FFFF  0x400000-0x40FFFF  64KB   VRAM — tile codes + attributes (BG/FG/TX)
0x10000-0x1197F  0x410000-0x41197F  ~6.4KB  Sprite RAM (816×8-byte words = 408 × 16-byte sprites)
0x11980-0x137FF  0x411980-0x4137FF  ~7KB   Unused RAM
0x13800-0x13FFF  0x413800-0x413FFF  2KB    Scroll RAM (BG/FG per-block scroll values)
0x18000-0x1801F  0x418000-0x41801F  32B    Control registers (16 × 16-bit)
0x40000-0x7FFFF  0x440000-0x47FFFF  256KB  Framebuffer (2 × 512×256 pages, 8bpp raw)
```

---

## 3. Control Registers (16 × 16-bit at chip 0x18000, only high byte is used)

| Offset | Name           | High Byte Bits | Description |
|--------|----------------|----------------|-------------|
| 0      | FG_RAMBANK     | [11:8]=bank0, [15:12]=bank1 | FG tile code bank (bank0) and attribute bank (bank1). Each 4-bit value → VRAM word offset = value<<12 |
| 1      | BG_RAMBANK     | [11:8]=bank0, [15:12]=bank1 | BG tile code/attribute banks (same encoding) |
| 2      | FG_SCROLL_CTRL | [15:8]=N       | FG lines per scroll block = 256−N. N=0 → one block covers entire screen |
| 3      | BG_SCROLL_CTRL | [15:8]=N       | BG lines per scroll block |
| 4      | TX_TILEBANK0   | [13:8]=bank    | TX tile bank for tiles with bit[11]=0; effective tile = bank<<11 + tile[10:0] |
| 5      | TX_TILEBANK1   | [13:8]=bank    | TX tile bank for tiles with bit[11]=1 |
| 6      | TX_RAMPAGE     | [11:8]=page    | TX VRAM base: tx_rambank = page<<11 (in 16-bit word units) |
| 7      | VIDEO_CTRL     | [7:0]=flags    | See §3.1 |
| 8–15   | (unused)       | always 0       | |

### 3.1 VIDEO_CTRL Byte (ctrl[7] high byte)

```
Bit 7: Manual FB page enable: 1 = don't auto-flip framebuffer on VBLANK, use bit[6]
Bit 6: FB page select (when bit[7]=1): selects framebuffer_page = ~bit[6]
Bit 5: Global video enable (tentative — Hit the Ice clears this before clearing VRAM)
Bit 4: Screen flip (1 = flip both X and Y for all layers)
Bit 3: Sprite priority mode:
        1 = sprites are ABOVE FG (layer order: BG → FG → OBJ → TX)
        0 = sprites split by color bit[4]:
            OBJ0 (color&0x10=0) between BG and FG
            OBJ1 (color&0x10=1) between FG and TX
Bit 0: Don't erase sprite framebuffer on VBLANK (1 = leave previous frame's pixels)
```

---

## 4. VRAM Layout (64KB, word-indexed)

VRAM is 0x8000 16-bit words. Banks are selected by RAMBANK control registers.

### 4.1 BG / FG Tilemaps

Each layer uses two banks:
- **Bank 0** (tile codes): `vram[bank0 + tile_index]` — tile number
- **Bank 1** (attributes): `vram[bank1 + tile_index]` — color/flip

```
Tile map size: 64×64 = 4096 entries (0x1000 words per bank)
Tile size: 16×16 pixels, 4bpp
Visible area: 320×240 pixels = 20×15 tiles (with scroll)
```

Attribute word encoding:
```
[15]   = flipY
[14]   = flipX
[13:6] = unused (zero)
[5:0]  = color (6-bit palette select → 64 colors × 16 entries)
```

### 4.2 TX Tilemap

```
Tile map size: 64×32 = 2048 entries (0x800 words, word-indexed from tx_rambank)
Tile size: 8×8 pixels, 4bpp
```

TX tile word encoding:
```
[15:12] = color (4-bit → 16 colors × 16 entries)
[11]    = tile bank select (0 → use ctrl[4], 1 → use ctrl[5])
[10:0]  = tile index within bank
```
Full tile GFX index: `(ctrl[4+bit11] >> 8) << 11 | tile[10:0]`

---

## 5. Scroll RAM (2KB, 0x400 16-bit words at chip 0x13800)

```
Word offset 0x000–0x1FF: FG scroll (plane=0)
Word offset 0x200–0x3FF: BG scroll (plane=1)
```

Within each plane's scroll region:
- Lines per block = 256 − ctrl[2+plane][15:8]  (defaults to 256 when ctrl=0, i.e., one global scroll)
- Number of blocks = 256 / lines_per_block
- Block i scroll: `scrollram[plane*0x200 + i*2*lpb]` = scrollX, `+1` = scrollY

**Example:** ctrl[2]=0 → lpb=256, 1 block → single global scroll (scrollram[0], scrollram[1])
**Example:** ctrl[2]=0x01xx → lpb=255, effectively 1 block (truncated)

---

## 6. Sprite RAM (0x1980 bytes = 0x1980/2 = 0xCC0 words, at chip 0x10000)

**408 sprite entries** (0xCC0 / 8 words_per_sprite = 408, but MAME loop: from 0x1980-16 down to 0, step 16 bytes = 408 sprites).

Sprites are drawn in **reverse RAM order** — last sprite in RAM = drawn first (lowest priority). Sprite 0 (RAM offset 0) = highest priority (drawn last, on top).

### 6.1 Sprite Entry Format (16 bytes / 8 words)

```
Word +0 (offs+0): Tile code
    [14:0] = GFX tile number (0x0000–0x7FFF)
    [15]   = unused

Word +1 (offs+1): Attributes
    [5:0]  = color (6-bit → palette index = color * 16)
    [13:6] = unused
    [14]   = flipX (1 = horizontal flip)
    [15]   = flipY (1 = vertical flip)

Word +2 (offs+2): X position
    [9:0]  = X coordinate, 10-bit signed (range: −512..+511)
    [15:10]= don't care (some games fill with sign extension)

Word +3 (offs+3): Y position
    [9:0]  = Y coordinate, 10-bit signed
    [15:10]= don't care

Word +4 (offs+4): Zoom
    [15:8] = xzoom: 0x00=100%, 0x80=50%, 0xC0=25%, 0xFF=0% (invisible)
    [7:0]  = yzoom: same encoding
    Pixel size: zx = (0x100 − xzoom) / 16,  zy = (0x100 − yzoom) / 16
               (gives tile render size in pixels)

Word +5 (offs+5): Big sprite control (0 = single tile or non-first tile of group)
    [15:8] = x_count − 1 (number of horizontal tiles in group, minus 1)
    [7:0]  = y_count − 1 (number of vertical tiles in group, minus 1)
    Non-zero marks the FIRST sprite of a multi-tile big sprite group

Words +6,+7: Unused (zero)
```

### 6.2 Big Sprite Mechanism

When word+5 ≠ 0:
1. This sprite is the **anchor** of a multi-tile group (x_num×y_num tiles)
2. Subsequent sprite entries (lower RAM addresses = processed later) are individual tiles of the group
3. All group tiles share: zoom, origin position, and the group dimensions from the anchor
4. Position for tile (x_no, y_no) in group:
   ```
   x = xlatch + (x_no * (0xFF − zoomx) + 15) / 16
   y = ylatch + (y_no * (0xFF − zoomy) + 15) / 16
   tile_w = x_of_next - x
   tile_h = y_of_next - y
   ```
5. Y advances first (y_no 0→y_num), then X (x_no 0→x_num)

---

## 7. Framebuffer (256KB at chip 0x40000)

- Two pages, each 512×256 pixels, 8bpp (palette index)
- CPU can read/write framebuffer directly (CPU-side access; MAME uses for clearing)
- During VBLANK: if VIDEO_CTRL[0]=0, active page is erased to 0 first, then sprites rendered
- Page auto-flips each VBLANK (unless VIDEO_CTRL[7]=1 for manual control)
- Framebuffer address encoding: `offset = (page*256 + sy) * 256 + sx/2`, pixel pair per 16-bit word

---

## 8. Layer Priority (from VIDEO_CTRL bit 3)

```
Mode 0 (bit3=0): BG → OBJ0 (color&0x10=0) → FG → OBJ1 (color&0x10≠0) → TX
Mode 1 (bit3=1): BG → FG → OBJ (all) → TX
```
TX is always topmost. OBJ color bit 4 (palette entry bit 4) selects the split layer in mode 0.

---

## 9. Interrupts

Two interrupt outputs:
- **INTH** (INT5/pin67): fires at VBLANK start
- **INTL** (INT4/pin66): fires ~8 scanlines after VBLANK start (timer-based in MAME)

Both externally decoded through a PAL. Exact timing not fully characterized.

---

## 10. Reusable Chips for Taito B Core

From TaitoF2_MiSTer (wickerwaka, GPL-2.0):
| Chip | File | Status |
|------|------|--------|
| TC0260DAR | `rtl/tc0260dar.sv` | Direct reuse — DAC/palette |
| TC0220IOC | `rtl/tc0220ioc.sv` | Direct reuse — I/O controller |
| TC0140SYT | `rtl/tc0140syt.sv` | Direct reuse — sound interface |
