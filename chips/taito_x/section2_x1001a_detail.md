# X1-001A / X1-002A Sprite Chip — Detailed Architecture

Source: MAME `src/devices/video/x1_001.cpp` and `src/devices/video/x1_001.h`
Driver: MAME `src/mame/taito/taito_x.cpp`

---

## 1. Sprite RAM Layout (CPU-visible)

The X1-001A exposes two CPU-addressable RAM blocks:

### 1a. Sprite Y-Coordinate RAM  (`spriteylow`)

**Address range (68000 bus):** `0xD00000 – 0xD005FF`
**Size:** 0x300 bytes (768 bytes)

Layout:
```
[0x000 – 0x1FF]  Y low-byte for foreground sprites 0–511 (one byte per sprite)
[0x200 – 0x2FF]  Background tilemap scroll RAM (16 columns × 0x10 bytes each)
```

Each foreground sprite Y entry: **1 byte** = low 8 bits of Y screen coordinate.
Background scroll RAM: `scrollram[col * 0x10 + 0]` = scrollY for column `col`,
`scrollram[col * 0x10 + 4]` = scrollX for column `col`.

### 1b. Sprite Code / Attribute RAM  (`spritecode`)

**Address range (68000 bus):** `0xE00000 – 0xE03FFF`
**Size:** 0x2000 × 16-bit words (16 KB)

Word-map for the foreground sprite layer:
```
Words [0x0000 – 0x01FF]   char_pointer (base bank A):  per-sprite tile code + flip
Words [0x0200 – 0x03FF]   x_pointer   (base bank A):  per-sprite X + color
```
With double-buffering (bank B = bank A + bank_size where bank_size = 0x1000):
```
Words [0x1000 – 0x11FF]   char_pointer (bank B)
Words [0x1200 – 0x13FF]   x_pointer   (bank B)
```

Background tilemap uses:
```
Words [0x0400 – 0x05FF + bank]   Tile code + flip (16 columns × 32 rows)
Words [0x0600 – 0x07FF + bank]   Tile color       (16 columns × 32 rows)
```

---

## 2. Foreground Sprite Entry Format

Each foreground sprite is described by **two 16-bit words** in two separate arrays,
plus **one byte** in spriteylow:

| Source              | Bits   | Field                         | Notes                         |
|---------------------|--------|-------------------------------|-------------------------------|
| `char_pointer[i]`   | [15]   | FlipX                         | 1 = flip horizontally         |
| `char_pointer[i]`   | [14]   | FlipY                         | 1 = flip vertically           |
| `char_pointer[i]`   | [13:0] | Tile code (14-bit)            | Index into gfx ROM            |
| `x_pointer[i]`      | [15:11]| Color palette index (5 bits)  | Selects 1-of-32 palettes      |
| `x_pointer[i]`      | [10:9] | (unused / game-specific)      |                               |
| `x_pointer[i]`      | [8]    | X sign bit (bit 8 of 9-bit X) | Subtracted from X[7:0] below  |
| `x_pointer[i]`      | [7:0]  | X position low byte           |                               |
| `spriteylow[i]`     | [7:0]  | Y position (8-bit)            |                               |

**X coordinate reconstruction:**
```
sx = (x_pointer[i] & 0x00FF) - (x_pointer[i] & 0x0100)
```
This is sign-extension: if bit 8 is set, subtract 256, giving range −256..+255.

**Y coordinate:**
```
sy = spriteylow[i] & 0xFF
```
Screen Y is then: `max_y - ((sy + yoffs) & 0xFF)`
where `max_y = screen.height()` (240 for Taito X) and `yoffs` is a game-specific
tuning constant set by `set_fg_yoffsets()`.

---

## 3. Background Tilemap Entry Format

Background uses the same `spritecode` RAM at higher offsets.
Each cell: **two 16-bit words** (code + color):

| Word                        | Bits   | Field              |
|-----------------------------|--------|--------------------|
| `spritecode[i+0x400+bank]`  | [15]   | FlipX              |
| `spritecode[i+0x400+bank]`  | [14]   | FlipY              |
| `spritecode[i+0x400+bank]`  | [13:0] | Tile code          |
| `spritecode[i+0x600+bank]`  | [15:11]| Color index        |

Tile position (col × row):
```
i = ((col + startcol) & 0xF) * 32 + offs       // offs = 0..31 (16 cols × 2 rows)
sx = scrollx + xoffs + (offs & 1) * 16
sy = -(scrolly + yoffs) + (offs / 2) * 16
```

---

## 4. Control Registers  (`spritectrl`)

**Address range:** `0xD00600 – 0xD00607` (4 × 16-bit read/write)

The `m_spritectrl[4]` array stores 4 bytes:

| Register     | Bit(s) | Field              | Notes                                      |
|--------------|--------|--------------------|--------------------------------------------|
| `ctrl[0]`    | [6]    | Screen flip        | Inverts X/Y and swaps flip flags           |
| `ctrl[0]`    | [1:0]  | Start column offset| Added to BG column index                  |
| `ctrl[1]`    | [6]    | Frame bank select  | Double-buffer toggle (XOR with `~ctrl[1]<<1` and 0x40) |
| `ctrl[1]`    | [5]    | Buffer copy enable | Secondary bank copy control               |
| `ctrl[1]`    | [3:0]  | Num BG columns     | 0=disabled, 1=16 columns active           |
| `ctrl[2]`    | [7:0]  | Upper column mask (low byte)  | 16-bit value with ctrl[3]    |
| `ctrl[3]`    | [7:0]  | Upper column mask (high byte) | Bit N=1 → subtract 256 from column N scrollX |

**Bank selection formula:**
```
bank = (((ctrl2 ^ (~ctrl2 << 1)) & 0x40) ? bank_size : 0)
```
Where `bank_size = 0x1000` (set by driver via `draw_sprites(screen, bitmap, cliprect, 0x1000)`).

---

## 5. Rendering Algorithm

### 5a. Foreground Sprite Rendering (`draw_foreground`)

```
screenflip = ctrl[0] bit 6
xoffs      = (screenflip ? fg_flipxoffs : fg_noflipxoffs)   // game-specific
yoffs      = (screenflip ? fg_flipyoffs : fg_noflipyoffs)   // game-specific

if (bank_toggle):
    char_pointer += bank_size   // 0x1000
    x_pointer    += bank_size

for i = spritelimit downto 0:              // spritelimit is game-specific (e.g. 511)
    code  = char_pointer[i] & 0x3FFF       // 14-bit tile code
    color = (x_pointer[i] & 0xF800) >> 11 // 5-bit palette
    sx    = (x_pointer[i] & 0x00FF) - (x_pointer[i] & 0x0100)  // signed X
    sy    = spriteylow[i] & 0xFF           // unsigned Y
    flipx = char_pointer[i] & 0x8000
    flipy = char_pointer[i] & 0x4000

    if gfxbank_cb set:
        code = gfxbank_cb(code, x_pointer[i] >> 8)   // upper bits for bank select

    color = color % total_color_codes + colorbase

    if screenflip:
        sy    = max_y - sy + (height - visible_max_y - 1)
        flipx = !flipx
        flipy = !flipy

    // Draw with 4 calls to handle screen wrapping:
    draw_tile(code, color, flipx, flipy,
              (sx + xoffs) & 0x1FF,        max_y - ((sy + yoffs) & 0xFF))
    draw_tile(code, color, flipx, flipy,
              (sx + xoffs) & 0x1FF - 512,  max_y - ((sy + yoffs) & 0xFF))
    draw_tile(code, color, flipx, flipy,
              (sx + xoffs) & 0x1FF,        max_y - ((sy + yoffs) & 0xFF) - 256)
    draw_tile(code, color, flipx, flipy,
              (sx + xoffs) & 0x1FF - 512,  max_y - ((sy + yoffs) & 0xFF) - 256)
```

**Scan order: highest index first → index 0 last = index 0 has highest priority.**
(Lower indices overwrite higher indices because they draw later.)

### 5b. Background Tilemap Rendering (`draw_background`)

```
for col = 0 to numcol-1:
    scrollx = scrollram[col * 0x10 + 4]
    scrolly = scrollram[col * 0x10 + 0]
    for offs = 0 to 31:
        i = ((col + startcol) & 0xF) * 32 + offs
        code  = spritecode[i + 0x400 + bank] & 0x3FFF
        color = (spritecode[i + 0x600 + bank] >> 11) % total_color_codes
        flipx = spritecode[i + 0x400 + bank] & 0x8000
        flipy = spritecode[i + 0x400 + bank] & 0x4000
        sx    = scrollx + xoffs + (offs & 1) * 16
        sy    = -(scrolly + yoffs) + (offs / 2) * 16
        if upper & (1 << col): sx -= 256
        // Draw with 4-way wrap (same as foreground)
```

Background drawn first; foreground sprites drawn on top.

---

## 6. Sprite/Tile Dimensions and ROM Format

- **Tile size:** 16 × 16 pixels (fixed, no zoom)
- **Bits per pixel:** 4 bpp (16 colors per palette)
- **ROM format:** Standard MAME `gfx(0)` layout — game-specific, configured via `GFXDECODE`

For Superman (typical Taito X):
```
ROM_offset = tile_code * 128    // 16 rows × 8 bytes/row = 128 bytes per tile
Row format: high nibble = left pixel, low nibble = right pixel
Pixel 0 = transparent (color index 0 in palette)
```

The `gfxbank_cb` callback allows games to remap tile codes to different ROM banks:
- Called as `code = gfxbank_cb(code, x_pointer[i] >> 8)`
- `x_pointer[i] >> 8` passes bits [15:8] (includes color and sign bit) as bank hints
- Games without multi-bank sprite ROMs leave the callback empty

---

## 7. Palette / Color System

- **Palette size:** 2048 entries (0xB00000–0xB00FFF, 16-bit xRGB_555)
- **Per-sprite color:** 5-bit field selects palette 0–31 (each palette = 64 colors in MAME)
- **Palette index:** `color % total_color_codes + colorbase`
  - `colorbase` = game-specific base (set via `set_colorbase()`)
  - `total_color_codes` = number of palettes in gfx descriptor
- **Transparency:** Pen 0 in any palette is transparent (`m_transpen = 0`)

---

## 8. Double-Buffering

The system supports double-buffered sprite RAM:

- **Bank A:** char_pointer at `spritecode[0x0000]`, x_pointer at `spritecode[0x0200]`
- **Bank B:** char_pointer at `spritecode[0x1000]`, x_pointer at `spritecode[0x1200]`

CPU writes to the inactive bank while the sprite chip reads from the active bank.
Bank is selected by `ctrl[1]` bits using:
```
active_bank = (((ctrl2 ^ (~ctrl2 << 1)) & 0x40) != 0) ? bank_size : 0
```

MAME functions `setac_eof()` and `tnzs_eof()` manage end-of-frame bank swap.

---

## 9. Screen Flip

When `ctrl[0] bit 6 = 1`:
- X and Y coordinates are mirrored
- FlipX and FlipY bits are inverted for every sprite
- Separate flip/noflip offset constants are applied (game-specific calibration)

---

## 10. ROM Addressing Summary

```
spriteylow RAM:     0xD00000 – 0xD005FF   (CPU 68000 bus)
spritectrl regs:    0xD00600 – 0xD00607   (CPU 68000 bus)
spritecode RAM:     0xE00000 – 0xE03FFF   (CPU 68000 bus)
Sprite GFX ROM:     0xC00000+             (banked, X1-001A internal bus)
Palette RAM:        0xB00000 – 0xB00FFF   (CPU 68000 bus)
```

---

## 11. MAME Function Cross-Reference

| MAME Function                    | RTL Equivalent              | Notes                                  |
|----------------------------------|-----------------------------|----------------------------------------|
| `x1_001_device::device_start()`  | Reset + BRAM initialization | Allocates spriteylow[0x300], spritecode[0x2000] |
| `spriteylow_w16()`               | CPU write port to Y RAM     | Byte-addressed, 16-bit bus             |
| `spritecode_w16()`               | CPU write port to code RAM  | Word-addressed                         |
| `spritectrl_w16()`               | Control register write      | 4 bytes at 0xD00600–0xD00607           |
| `draw_sprites(bmp, clip, 0x1000)`| Render pipeline             | bank_size=0x1000 for all Taito X games |
| `draw_foreground()`              | FG sprite scan loop         | Scan from spritelimit down to 0        |
| `draw_background()`              | BG tilemap scan loop        | Up to 16 columns × 32 cells            |
| `setac_eof()` / `tnzs_eof()`     | VBlank end-of-frame handler | Swap double-buffer bank                |
| `set_fg_yoffsets(-0x12, 0x0E)`   | y_offs config input         | Game-specific (Superman values shown)  |
| `set_bg_yoffsets(0x1, -0x1)`     | bg_y_offs config input      | Game-specific                          |

---

## 12. Key Differences from TC0370MSO (Taito Z)

| Feature          | X1-001A (Taito X)     | TC0370MSO (Taito Z)                |
|------------------|-----------------------|------------------------------------|
| Tile size        | 16×16 (fixed)         | 16×8 chunks composited             |
| Zoom             | None                  | Per-sprite X and Y zoom            |
| Priority bits    | None (order only)     | 1-bit per sprite                   |
| Sprite count     | 512 (spritelimit)     | 512 entries per half-frame         |
| Double buffer    | Yes (ctrl[1] bit 6)   | Yes (frame_sel)                    |
| Background layer | Yes (BG tilemap)      | No (sprite-only)                   |
| ROM bank CB      | Yes (gfxbank_cb)      | Yes (gfxbank_cb)                   |
