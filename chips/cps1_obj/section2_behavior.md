# CPS1 OBJ Chip — Section 2: Behavioral Description

Human-verified against MAME `src/mame/capcom/cps1_v.cpp` and `cps1.h`, cross-checked against jotego jtcores reference implementation.

---

## 1. Overview

The CPS1 OBJ chip is the sprite engine on the CPS-A custom chip (A-board). It is responsible for rendering up to 256 independently-positioned 16×16-pixel sprite tiles per frame. Sprites are defined as entries in a table stored in a region of shared GFX RAM called OBJ RAM. The chip reads the table, fetches tile data from graphics ROM, and writes pixel data into a line buffer, which is then output to the display during the active scan period.

The chip shares GFX RAM with the three tilemap scroll layers, the row-scroll RAM, and the palette. All subsystems read from and write to this unified RAM through a time-division multiplexed bus.

---

## 2. Display Timing

Pixel clock: 8 MHz (derived from 16 MHz XTAL divided by 2).

| Parameter             | Value                    |
|-----------------------|--------------------------|
| Total clocks per line | 512                      |
| Horizontal blank start | pixel 448               |
| Horizontal blank end  | pixel 64                 |
| Active display width  | 384 pixels               |
| Total scanlines       | 262                      |
| Vertical blank start  | scanline 240             |
| Vertical blank end    | scanline 16              |
| Active display height | 224 lines                |
| Refresh rate          | ~59.63 Hz                |

The active display area is 384×224 pixels. The hardware uses a 512-wide virtual coordinate space (9-bit X). Sprite X positions in the range 64 to 447 (decimal) are visible.

---

## 3. OBJ RAM Double-Buffering (Frame Latch)

The OBJ chip does not read directly from the CPU-writeable GFX RAM during rendering. Instead, OBJ RAM is double-buffered:

- The CPU writes sprite data to the live OBJ RAM region of GFX RAM at any time.
- At the rising edge of VBLANK (scanline 240), the full OBJ RAM (0x0800 bytes, 256 entries) is atomically copied into a shadow buffer internal to the OBJ system.
- The OBJ chip reads the shadow buffer during rendering of the subsequent frame.

Consequence: sprite data written by the CPU during frame N becomes visible in frame N+1. There is a one-frame latency inherent to the hardware design. Games compensate by writing sprite data before VBLANK so it is captured at the next VBLANK transition.

At the same VBLANK transition, the OBJ_BASE register is re-read so the game can dynamically relocate the OBJ RAM window within GFX RAM between frames.

---

## 4. Sprite Scan and Table Processing

The OBJ chip scans the shadow OBJ RAM table from entry 0 forward, in address order. The table is scanned once per frame. Scanning stops at the first entry whose ATTR word has its high byte equal to `0xFF` (i.e., `ATTR & 0xFF00 == 0xFF00`), or at the last entry in the 256-entry table if no terminator is found.

Each entry consists of four 16-bit words:
- Word 0: X position (9-bit, bits 8:0 used)
- Word 1: Y position (9-bit, bits 8:0 used)
- Word 2: tile CODE
- Word 3: ATTR (palette, flip flags, block dimensions)

**Priority**: The OBJ chip renders sprites in reverse table order relative to screen priority. Entries earlier in the table (lower addresses) are drawn on top of entries later in the table. Specifically, the renderer iterates from the last valid entry toward entry 0, writing to the line buffer in that order. Because later writes to the same line buffer position overwrite earlier writes, entries at lower indices end up on top.

---

## 5. Multi-Tile Block Expansion

A single sprite entry may describe a rectangular block of multiple 16×16 tiles. The ATTR word encodes the block dimensions:
- `NX` (ATTR bits 11:8): number of extra tile columns. Total columns = NX + 1.
- `NY` (ATTR bits 15:12): number of extra tile rows. Total rows = NY + 1.

For a block of dimensions `(NX+1) × (NY+1)` tiles:
- The entry's X and Y coordinates are the top-left corner of the block.
- Each individual tile within the block is drawn at screen position `(X + col × 16, Y + row × 16)`, with both coordinates wrapped modulo 512.
- The tile code for the tile at column `col`, row `row` is computed from the base CODE using the formula described in Section 1.
- Flip flags (FLIPX, FLIPY) apply to the entire block. With FLIPX, the column order is reversed; with FLIPY, the row order is reversed.

The chip internally iterates over all tiles in a block before moving to the next table entry.

---

## 6. Line Buffer Architecture

The OBJ chip uses a **ping-pong line buffer** architecture with two independently addressable buffers.

- The line buffer pair has two banks, each 512 entries wide, each entry 9 bits wide (5-bit palette index + 4-bit pixel color).
- During the rendering of scanline N+1 (one scanline ahead of current display), the OBJ chip writes sprite pixels into the "back" buffer bank.
- During active display of scanline N, pixels are read from the "front" buffer bank in pixel-clock synchrony.
- The front/back roles swap at each scanline boundary (the LSB of the scanline counter selects which bank is front and which is back).
- After each pixel is read during display, the line buffer position is immediately erased (written with all-ones / transparent value). This self-erasing behavior means the buffer is always clean for the next write cycle.

The line buffer stores a 9-bit value per position:
- Bits 8:4 = 5-bit palette selector (COLOR field from ATTR).
- Bits 3:0 = 4-bit pixel color from tile ROM.
- A value of `0xF` in bits 3:0 indicates a transparent pixel (not written to line buffer).

---

## 7. Sprite Fetch Timing

The OBJ chip begins its per-scanline sprite scan one scanline ahead of the displayed line (operating on `vrender = vdump + 1`). This is made possible by the double-buffered line architecture.

Within each horizontal blank period, the chip:
1. Scans the sprite table to find all entries whose Y range covers the next scanline.
2. For each matching entry (and each tile within multi-tile blocks), issues a ROM tile fetch.
3. Writes the fetched 8 horizontal pixels per ROM word into the back line buffer at the appropriate X offset.

The chip processes one 16-pixel tile column at a time. Each tile fetch retrieves 32 bits of ROM data (8 pixels per half-word read), with two halves (left 8 pixels, right 8 pixels) fetched sequentially. The two halves are distinguished by the `rom_half` signal.

ROM data is 4 bits per pixel, 32 bits per fetch = 8 pixels per fetch. Two fetches per 16-pixel tile column.

Blank (all-ones) tile data is detected: if all 32 bits from ROM are `0xFFFFFFFF`, the 8-pixel group is skipped without writing to the line buffer, saving time.

---

## 8. Vertical Visibility Check

Before fetching a tile, the chip checks whether the sprite entry's Y range covers the target scanline. The check:

- Sprite is visible if: `Y <= vrender < Y + (NY+1) × 16`
- Y coordinates are 9-bit values in a 512-line virtual space. Sprites near the top of the coordinate space (Y > 0xF0 approximately) that wrap across the Y=0 boundary are handled: an entry whose Y + block_height crosses 0x100 is visible near scanline 0.
- The vertical sub-position within the tile (`vsub`, bits 3:0) is computed as `(vrender - Y) mod 16`, optionally XOR'd with 0xF if FLIPY is set.

---

## 9. Horizontal Clipping

Sprite pixels are written to the line buffer only for X positions within the valid screen window. The active display occupies X = 64 to X = 447 (hblank is outside these bounds). Pixels at X positions outside this range are not written. The chip internally suppresses rendering if the computed sprite start position falls outside the visible range.

X positions are 9-bit (0–511). The visible window is pixel columns 64–447 of the 512-wide virtual coordinate space.

---

## 10. Priority and Color Mixing

The CPS1 OBJ chip has a fixed sprite-to-sprite priority model: sprite entries earlier in the OBJ table (lower address offset) are higher priority and are not overwritten by later entries.

In the overall scene compositor, sprites interact with the three tilemap layers. The draw order is controlled by the CPS-B LAYER_CONTROL register, which specifies which of four positions (0–3) in the back-to-front rendering stack is occupied by sprites (layer index 0) and the three tilemaps (layer indices 1, 2, 3).

Priority masking: tiles in the scroll layer rendered immediately below sprites can have per-pixel priority flags that allow them to appear in front of sprites. This is controlled by the four CPS-B PRIORITY mask registers. These priority masks specify which palette-color combinations in the sub-sprite tilemap layer have priority over sprites. The OBJ chip marks its pixels in the priority buffer (bit 1 of the priority bitmap) as it writes them; the compositor checks this bit to determine whether a tilemap tile can overwrite a sprite pixel.

There are no OBJ-vs-OBJ priority levels beyond table order. There is no per-sprite priority field. The five-bit COLOR index (ATTR bits 4:0) is purely a palette selector and carries no hardware priority weight.

---

## 11. Flip Screen

When the VIDEOCONTROL register bit 15 (flip screen) is set:
- All sprite X positions are mirrored: effective_X = 512 - 16 - sprite_X.
- All sprite Y positions are mirrored: effective_Y = 256 - 16 - sprite_Y.
- Flip flags (FLIPX, FLIPY) are inverted: FLIPX becomes !FLIPX, FLIPY becomes !FLIPY.

---

## 12. Sprite Coordinate Wrapping

Both X and Y coordinates are 9-bit and wrap modulo 512. A sprite with X = 500 and width 32 (two tiles) will have its left portion at X=500 and right portion wrapped to X = (500+16) mod 512 = 4. The hardware treats each tile column independently, computing the wrapped position for each.

Sprites with Y positions near the top (e.g., Y = 0xF0 to 0xFF = 240–255 in a 240-line display) that extend into the visible area from the top are handled by the vertical wrap logic. The visibility check accounts for entries whose `Y + block_height` crosses the 0x100 boundary.

---

## 13. Output Signals

The OBJ chip presents the following logical outputs to the scene compositor per pixel clock:

| Signal       | Width  | Description                                                                 |
|--------------|--------|-----------------------------------------------------------------------------|
| `pixel_data` | 9 bits | {5-bit palette index, 4-bit color}. All-ones on transparent pixels.        |
| Valid implied | —     | Transparency is encoded in pixel_data: 4-bit color = 0xF means transparent.|

The chip does not output a separate priority signal in the OBJ-only sense; the priority buffer (set during sprite rendering) is managed by the composite video system external to the OBJ chip proper.

---

## 14. GFX ROM Interface

The OBJ chip outputs a 20-bit ROM address and a 1-bit half-select to the B-board:

| Signal       | Width  | Description                                                                 |
|--------------|--------|-----------------------------------------------------------------------------|
| `rom_addr`   | 20 bits | Tile address: `{code[15:0], vsub[3:0]}`. Selects the specific 16-pixel row within the tile. |
| `rom_half`   | 1 bit  | Selects which 8-pixel half of the 16-pixel tile row to fetch. Also indicates FLIPX direction for left/right fetch ordering. |
| `rom_cs`     | 1 bit  | ROM chip-select (active when fetch in progress).                            |
| `rom_data`   | 32 bits | Returned pixel data, 4 bits per pixel, 8 pixels.                           |
| `rom_ok`     | 1 bit  | Input; indicates ROM data is valid (handshake).                             |

The B-board PAL maps the upper bits of `rom_addr` through its bank mapper to select the physical ROM chip and validate the address range. Out-of-range tile codes produce a transparent result (all-ones data).
