# TC0200OBJ — Section 1: Chip Target & Register Map

## Chip Identification

```
Target chip:       TC0200OBJ (Taito Custom) + TC0210FBC (companion pixel output chip)
Arcade system:     Taito F2 (standard boards after TC0110PCR became standard)
Chip function:     Sprite/Object rendering engine — 16-colour 16×16 tiles, zoom, multi-tile groups
Clock frequency:   ~27 MHz master (MiSTer)
MAME source file:  src/mame/taito/taito_f2_v.cpp (draw_sprites function)
Games using it:    Chase H.Q., Night Striker, Rainbow Islands Extra, Crime City,
                   Gun Front, Koshien, Ninja Kids, Thunderfox, Pulirula, Dino Rex,
                   Growl, Liquid Kids, Final Blow, and ~30 more Taito F2 titles
```

Known signals:
```
  - CLK (in, 1-bit): master clock
  - /RST (in, 1-bit): active-low async reset
  - CS (in, 1-bit): CPU chip select
  - WR (in, 1-bit): CPU write strobe
  - A[15:1] (in, 15-bit): CPU address (word-wide access into 64 KB sprite RAM space)
  - D[15:0] (inout, 16-bit): CPU data bus
  - HBLANK (in, 1-bit): horizontal blanking — triggers line render
  - VBLANK (in, 1-bit): vertical blanking — triggers sprite list parse
  - HCOUNT[8:0] (in, 9-bit): horizontal pixel counter (0..511)
  - VCOUNT[8:0] (in, 9-bit): vertical scanline counter (0..261)
  - FLIP (in, 1-bit): screen flip
  - ROMADDR[19:0] (out, 20-bit): tile GFX ROM address
  - ROMDATA[31:0] (in, 32-bit): 4 bytes of tile pixel data from ROM
  - ROMREQ (out, 1-bit): ROM request strobe
  - ROMACK (in, 1-bit): ROM data ready
  - PIXEL[8:0] (out, 9-bit): sprite pixel output — {color[7:0], pixel_nibble[3:0]}
                              pixel_nibble=0 → transparent
```

## Sprite RAM

- **Size:** 0x8000 words (64 KB) in two 32 KB banks
- **CPU access:** word-wide, direct memory-mapped (68000 at 0x900000–0x90FFFF)
- **Active bank:** selected by control entry in sprite RAM (bit 0 of word 5 at special entries)
- **Per-bank capacity:** 0x4000 bytes = 1024 sprite entries × 16 bytes each

## Sprite Entry Format (16 bytes = 8 words per sprite)

```
Offset  Size  Field           Description
──────────────────────────────────────────────────────────────────────
+0x00   word  TILE_CODE       ---xxxxxxxxxxxxx  tile index (0x0000–0x1FFF, 13 bits)
                               bits[12:10] = sprite bank select (0–7)
                               bits[9:0]  = offset within bank (0–1023)

+0x02   word  ZOOM            xxxxxxxx--------  y-zoom (8 bits)
                               --------xxxxxxxx  x-zoom (8 bits)
                               0x00 = 100% (no scale)
                               0x80 = 50%
                               0xC0 = 25%
                               0xE0 = 12.5%
                               0xFF = 0 pixels (invisible)

+0x04   word  X_POS           ----xxxxxxxxxxxx  x-coordinate (signed 12-bit, -0x800..+0x7FF)
                               bit 12: latch extra scroll from this entry's x/y
                               bit 13: latch master scroll from this entry's x/y
                               bit 14: ignore extra scroll (use master scroll only)
                               bit 15: absolute screen coordinates (ignore all scroll)
                               Note: 0xA___ = set master scroll; 0x5___ = set extra scroll

+0x06   word  Y_POS           ----xxxxxxxxxxxx  y-coordinate (signed 12-bit, -0x800..+0x7FF)
                               bit 15: SPECIAL COMMAND entry (not a display sprite)
                               When bit15=1, this is a control entry; bits used differently:
                               bit 0: sprite RAM bank select
                               bit 12: disable following sprites
                               bit 13: flip screen

+0x08   word  ATTR            --------xxxxxxxx  color (palette index, 0x00–0xFF)
                               -------x--------  flipx (horizontal flip)
                               ------x---------  flipy (vertical flip)
                               -----x----------  color_latch: if set, use latched color
                               ----x-----------  continuation: if set, this tile is part of BigSprite group
                               ---x------------  y_use_current: if clear, use latched y; if set, use current y
                               --x-------------  y_plus_16: if set, add 16 to y (advance row in BigSprite)
                               -x--------------  x_use_current: if clear, use latched x; if set, use current x
                               x---------------  x_plus_16: if set, add 16 to x (advance column in BigSprite)

+0x0A   word  CTRL2           Only valid when SPECIAL COMMAND bit (Y_POS bit 15) is set.
                               bit 0: sprite RAM bank select (primary bank switch source)
                               bit 3: unknown toggle (some games use before sprite RAM update)
                               bit 12: disable sprites (until another control entry clears it)
                               bit 13: flip screen

+0x0C   word  (unused)
+0x0E   word  (unused)
```

## ATTR Word Naming (spritecont = ATTR[15:8])

```
spritecont[0] = flipx
spritecont[1] = flipy
spritecont[2] = color_latch (1 = use latched color, 0 = use & latch current)
spritecont[3] = continuation (1 = BigSprite tile, 0 = standalone sprite)
spritecont[4] = y_use_current (0 = use ylatch, 1 = use y accumulated from y_plus_16)
spritecont[5] = y_plus_16 (1 = increment y by 16 for this tile)
spritecont[6] = x_use_current (0 = use xlatch, 1 = use x accumulated from x_plus_16)
spritecont[7] = x_plus_16 (1 = increment x by 16 for this tile)
```

## Zoom Calculation

For a standalone sprite (non-BigSprite):
```
zoomx = ZOOM[7:0]
zoomy = ZOOM[15:8]
sprite_width_pixels  = (0x100 - zoomx) / 16   [0..16]
sprite_height_pixels = (0x100 - zoomy) / 16   [0..16]
```
Each sprite tile is 16×16 source pixels rendered into `sprite_width_pixels × sprite_height_pixels`.

For a BigSprite (multi-tile group), zoom applies to the group as a whole:
```
x_pos_of_tile[x_no] = xlatch + (x_no * (0xFF - zoomx) + 15) / 16
y_pos_of_tile[y_no] = ylatch + (y_no * (0xFF - zoomy) + 15) / 16
tile_width  = x_pos_of_tile[x_no+1] - x_pos_of_tile[x_no]
tile_height = y_pos_of_tile[y_no+1] - y_pos_of_tile[y_no]
```

## Sprite ROM Access

- **Tile size:** 16×16 pixels, 4 bits per pixel = 128 bytes per tile
- **ROM addressing:** tile_code (after bank remapping) × 128 bytes + y_row × 8 bytes + x_col/2
- **ROM word:** 32 bits wide, contains 8 pixels (4 bits each)
- **Pixel extraction:** bits[3:0] = leftmost pixel, bits[7:4] = next, etc.
  (or reversed if flipx — hardware unpacks right-to-left for flipped sprites)

## Sprite Priority

Sprites processed front-to-back (entry 0 = highest priority, entry 1023 = lowest).
The color field bits [7:6] determine priority category for TC0360PRI priority mixing.

## Timing

```
VBLANK:  ~22 scanlines × 512 clks = ~11264 clks for sprite list parse
HBLANK:  ~96 clocks per scanline for line buffer render
Active:  read from line buffer → pixel output
```

## Control Entry Processing (SPECIAL COMMAND, Y_POS bit 15 = 1)

Control entries interrupt normal sprite processing:
1. **Bank switch:** area = 0x8000 × (CTRL2 bit 0) — jumps processing to bank 1 if set
2. **Enable/Disable:** bit 12 of CTRL2 disables all following sprite entries until next control entry
3. **Flip screen:** bit 13 of CTRL2 inverts x/y for all following sprites
4. **Master scroll latch:** X_POS[11:0] + Y_POS[11:0] when X_POS[15:12]=0xA
5. **Extra scroll latch:** X_POS[11:0] + Y_POS[11:0] when X_POS[15:12]=0x5
