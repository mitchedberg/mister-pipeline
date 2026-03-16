# CPS1 OBJ Chip — Section 1: Register Map and Sprite Table Format

Human-verified against MAME source `src/mame/capcom/cps1_v.cpp` (rev. master, 2024).

---

## 1. System Memory Map (CPU-visible)

The CPS1 CPU is a Motorola 68000. All addresses are 24-bit bus addresses.

| Address Range       | Width  | Description                              |
|---------------------|--------|------------------------------------------|
| `0x800100–0x80013F` | 16-bit | CPS-A registers (write only, 32 words)   |
| `0x800140–0x80017F` | 16-bit | CPS-B registers (read/write, 32 words)   |
| `0x900000–0x92FFFF` | 16-bit | GFX RAM (192 KB, shared video RAM)       |

GFX RAM is the single unified video RAM. All video subsystems (OBJ, scroll layers, palette) share this space. The CPS-A registers establish base pointers that select which sub-window of GFX RAM each subsystem uses.

---

## 2. CPS-A Control Registers (at 0x800100)

The CPS-A block is a single custom chip on the A-board. Registers are 16-bit, word-aligned, written by the 68000. All offsets are relative to the base at `0x800100`.

| Byte Offset | Word Index | Name                  | Description                                                                                       |
|-------------|------------|-----------------------|---------------------------------------------------------------------------------------------------|
| `0x00`      | `[0x00/2]` | `OBJ_BASE`            | OBJ RAM base pointer. Value is multiplied by 256 to get the byte address within GFX RAM. The hardware masks to the nearest `0x0800`-byte boundary (OBJ RAM size). |
| `0x02`      | `[0x02/2]` | `SCROLL1_BASE`        | Scroll 1 (8×8 tile layer) base pointer. Multiplied by 256; aligned to `0x4000` bytes.            |
| `0x04`      | `[0x04/2]` | `SCROLL2_BASE`        | Scroll 2 (16×16 tile layer) base pointer. Multiplied by 256; aligned to `0x4000` bytes.          |
| `0x06`      | `[0x06/2]` | `SCROLL3_BASE`        | Scroll 3 (32×32 tile layer) base pointer. Multiplied by 256; aligned to `0x4000` bytes.          |
| `0x08`      | `[0x08/2]` | `OTHER_BASE`          | Row-scroll / "other" RAM base pointer. Multiplied by 256; aligned to `0x0800` bytes.             |
| `0x0A`      | `[0x0A/2]` | `PALETTE_BASE`        | Palette base pointer. Writing this register triggers an immediate DMA copy of palette data from GFX RAM to the dedicated palette RAM. Value × 256 = byte address in GFX RAM. Minimum alignment is `0x0400` bytes (one palette page = 512 colors × 2 bytes). |
| `0x0C`      | `[0x0C/2]` | `SCROLL1_SCROLLX`     | Horizontal scroll offset for Scroll 1 layer.                                                      |
| `0x0E`      | `[0x0E/2]` | `SCROLL1_SCROLLY`     | Vertical scroll offset for Scroll 1 layer.                                                        |
| `0x10`      | `[0x10/2]` | `SCROLL2_SCROLLX`     | Horizontal scroll offset for Scroll 2 layer.                                                      |
| `0x12`      | `[0x12/2]` | `SCROLL2_SCROLLY`     | Vertical scroll offset for Scroll 2 layer.                                                        |
| `0x14`      | `[0x14/2]` | `SCROLL3_SCROLLX`     | Horizontal scroll offset for Scroll 3 layer.                                                      |
| `0x16`      | `[0x16/2]` | `SCROLL3_SCROLLY`     | Vertical scroll offset for Scroll 3 layer.                                                        |
| `0x18`      | `[0x18/2]` | `STARS1_SCROLLX`      | Starfield layer 1 horizontal scroll.                                                              |
| `0x1A`      | `[0x1A/2]` | `STARS1_SCROLLY`      | Starfield layer 1 vertical scroll.                                                                |
| `0x1C`      | `[0x1C/2]` | `STARS2_SCROLLX`      | Starfield layer 2 horizontal scroll.                                                              |
| `0x1E`      | `[0x1E/2]` | `STARS2_SCROLLY`      | Starfield layer 2 vertical scroll.                                                                |
| `0x20`      | `[0x20/2]` | `ROWSCROLL_OFFS`      | Start offset within the "other" RAM for the row-scroll matrix.                                   |
| `0x22`      | `[0x22/2]` | `VIDEOCONTROL`        | Video control register. See bit fields below.                                                     |

### VIDEOCONTROL Register Bit Fields (offset 0x22)

| Bit   | Description                                                                 |
|-------|-----------------------------------------------------------------------------|
| 15    | Flip screen. When set, the entire display is flipped horizontally and vertically. |
| 14    | Purpose unknown. Set by Ghouls'n Ghosts in service mode; no visible effect observed. |
| 3     | Scroll 3 layer enable modifier (used together with CPS-B layer control register). |
| 2     | Scroll 2 layer enable modifier.                                             |
| 1     | Scroll 1 enable modifier (effect unclear from hardware tests).              |
| 0     | Row-scroll enable for Scroll 2 layer.                                       |

Most games set VIDEOCONTROL to `0x000E` (bits 3:1 set). Flip-screen is the only bit with clearly verified OBJ impact.

---

## 3. CPS-B Control Registers (at 0x800140)

Unlike CPS-A registers, the CPS-B register addresses are **not fixed**. Their offsets vary per game because the CPS-B chip is a programmable PAL/custom that moves register positions depending on the board revision. The offset table for each game is embedded in the MAME game configuration table.

The canonical default (Street Fighter II / CPS-B-17 configuration, offsets relative to 0x800140):

| Byte Offset | Name              | Description                                                                 |
|-------------|-------------------|-----------------------------------------------------------------------------|
| Game-vary   | `LAYER_CONTROL`   | Layer draw order and enable. See bit fields below.                          |
| Game-vary   | `PRIORITY[0]`     | Priority mask for tilemap layer priority level 0.                           |
| Game-vary   | `PRIORITY[1]`     | Priority mask for tilemap layer priority level 1.                           |
| Game-vary   | `PRIORITY[2]`     | Priority mask for tilemap layer priority level 2.                           |
| Game-vary   | `PRIORITY[3]`     | Priority mask for tilemap layer priority level 3.                           |
| Game-vary   | `PALETTE_CTRL`    | Palette page copy enable. See bit fields below.                             |

### LAYER_CONTROL Bit Fields

| Bits  | Description                                                                                   |
|-------|-----------------------------------------------------------------------------------------------|
| 15–14 | Unused (some games set these; no observed hardware effect).                                   |
| 13–12 | Layer 3 draw order selector: 2-bit index selecting which video plane occupies position 3.     |
| 11–10 | Layer 2 draw order selector.                                                                  |
| 9–8   | Layer 1 draw order selector.                                                                  |
| 7–6   | Layer 0 draw order selector. Layers 0–3 use values 0–3 to select among sprites (0) and tilemaps (1–3). |
| 5–1   | Layer enable bits: one bit per subsystem (scroll1, scroll2, scroll3, stars1, stars2). The exact bit-to-layer mapping changes per game. |
| 0     | Row-scroll activity flag (purpose unclear; unrelated to actual row-scroll enable).            |

### PALETTE_CTRL Bit Fields

| Bit | Description                                                                              |
|-----|------------------------------------------------------------------------------------------|
| 5   | Copy palette page 5 (starfield 2).                                                       |
| 4   | Copy palette page 4 (starfield 1).                                                       |
| 3   | Copy palette page 3 (scroll 3).                                                          |
| 2   | Copy palette page 2 (scroll 2).                                                          |
| 1   | Copy palette page 1 (scroll 1).                                                          |
| 0   | Copy palette page 0 (sprites / OBJ).                                                     |

When a bit is clear, the corresponding palette page in GFX RAM is skipped during copy. Verified on hardware for bits 0–3.

---

## 4. OBJ RAM

### Location and Size

OBJ RAM is a window within GFX RAM. Its location is set by `OBJ_BASE` (CPS-A register at offset `0x00`).

- `OBJ_BASE` register value × 256 = byte address of OBJ RAM start within GFX RAM.
- OBJ RAM size: **0x0800 bytes** (2048 bytes = 1024 16-bit words).
- The hardware aligns the base to the nearest 0x0800-byte boundary.
- Default value set at video_start: `OBJ_BASE = 0x9200`, meaning OBJ RAM starts at byte address `0x9200 × 256 = 0x920000` within CPU space, i.e., at byte offset `0x20000` within the GFX RAM window (GFX RAM starts at `0x900000`).

At the default base of `0x9200`:
- CPU address range: `0x920000–0x9207FF`
- GFX RAM offset: `0x20000–0x207FF`

### Sprite Table Entry Format

Each sprite entry occupies **8 bytes (4 × 16-bit words)**. The table is scanned in order from offset 0.

| Word Offset | Byte Offset | Name       | Description                              |
|-------------|-------------|------------|------------------------------------------|
| `+0`        | `+0`        | `X`        | Horizontal position (9 bits used: bits 8:0). Screen X coordinate of the sprite's top-left corner. 9-bit value allows positions 0–511. |
| `+1`        | `+2`        | `Y`        | Vertical position. 9 bits used (bits 8:0). Screen Y coordinate of the sprite's top-left corner. |
| `+2`        | `+4`        | `CODE`     | Tile code / sprite number. 16-bit index into the sprite section of the graphics ROM. Passed through the B-board PAL bank mapper to produce the final ROM address. |
| `+3`        | `+6`        | `ATTR`     | Attribute word. See bit field table below. |

### ATTR Word Bit Fields (Word +3, byte offset +6)

| Bits  | Name        | Description                                                                               |
|-------|-------------|-------------------------------------------------------------------------------------------|
| 15–12 | `NY`        | Y block size minus 1. Number of 16-pixel tile rows in a multi-tile sprite, minus 1. Value 0 = 1 row (single tile), value 1 = 2 rows, ..., value 15 = 16 rows. |
| 11–8  | `NX`        | X block size minus 1. Number of 16-pixel tile columns in a multi-tile sprite, minus 1. Value 0 = 1 column (single tile), value 1 = 2 columns, ..., value 15 = 16 columns. |
| 7     | Unused / reserved. Used only in Marvel vs. Capcom (CPS2) for X/Y offset toggle; not active in CPS1. |
| 6     | `FLIPY`     | Vertical flip. When set, the sprite (or sprite block) is rendered flipped top-to-bottom.  |
| 5     | `FLIPX`     | Horizontal flip. When set, the sprite (or sprite block) is rendered flipped left-to-right. |
| 4–0   | `COLOR`     | Palette/color index. Selects one of 32 color entries from sprite palette page 0. The 5-bit value selects a 16-color palette from the 512-color sprite palette page. |

### End-of-Table Marker

The sprite table is terminated by a sentinel value. Standard CPS1:

- If the high byte of the ATTR word (`ATTR & 0xFF00`) equals `0xFF00`, this entry is the last valid sprite. Scanning stops at the entry before this marker.
- The hardware scans the full table (up to 0x0800 bytes / 256 entries) if no marker is found.

### Maximum Sprite Count

- OBJ RAM: 2048 bytes / 8 bytes per entry = **256 sprite entries maximum**.
- With multi-tile blocks (NX × NY), a single entry can occupy up to 16×16 = 256 tile positions.

---

## 5. Multi-Tile Sprite Block Rendering

When `NX > 0` or `NY > 0` (bits 11:8 or 15:12 of ATTR are non-zero), the single sprite entry describes a rectangular block of 16×16-pixel tiles.

- Block width in tiles: `NX + 1` (1 to 16 tiles).
- Block height in tiles: `NY + 1` (1 to 16 tiles).
- Total tiles drawn per entry: `(NX+1) × (NY+1)`.

Tile code sequencing within a block:

- The base tile code is from the CODE word.
- Tile codes for individual tiles within the block are computed by adding an offset to the base code.
- The offset pattern: the lower 4 bits of CODE select the column within a 16-tile row; rows are offset by 0x10 per row.
- With FLIPX: column order within each row is reversed. The rightmost column starts at `(base & ~0xF) + (base + NX) & 0xF` and decrements.
- With FLIPY: row order is reversed. The bottom row starts at offset `NY × 0x10` and decrements toward 0.
- Combined FLIPX + FLIPY: both axes reversed simultaneously.

Screen position of each tile within a block:

- Tile at column `nxs`, row `nys`: screen X = `(entry_X + nxs × 16) & 0x1FF`, screen Y = `(entry_Y + nys × 16) & 0x1FF`.
- X and Y positions wrap modulo 512 (9-bit).

---

## 6. ROM Address Encoding for Sprites

The 23-bit address presented to the B-board for a sprite tile fetch is structured as:

```
sprite: 000ccccccccccccccccyyyy
```

Where:
- Bits 22–20: `000` (sprite type selector; distinguishes from scroll/stars).
- Bits 19–4: tile code (16 bits, `c`).
- Bits 3–0: vertical sub-pixel row within the 16×16 tile (`y`, 0–15).

The B-board PAL validates the tile code against its programmed range table. If the code is out of range, no ROM is read; pull-up resistors force data to all 1s (transparent).

Each 16×16 sprite tile contains 256 pixels, 4 bits per pixel = 128 bytes. The ROM data bus is 64 bits (16 pixels) wide; fetches return two groups of 8 pixels (the "half" selection signal picks which group).

---

## 7. Palette Structure

The sprite palette is palette page 0. It contains 512 colors (512 × 16-bit entries).

The 32 COLOR palettes (selected by ATTR bits 4:0) each contain 16 colors, using 4-bit pixel data from the tile ROM. Color index 15 (`0xF`) is the transparent color.

Palette entry format (16 bits):

| Bits  | Description                            |
|-------|----------------------------------------|
| 15–12 | Brightness (4 bits). Value 0 reduces brightness to approximately 1/3 of full. |
| 11–8  | Red component (4 bits).                |
| 7–4   | Green component (4 bits).              |
| 3–0   | Blue component (4 bits).               |

Final RGB is computed as: `channel = nibble × 0x11 × (0x0F + brightness × 2) / 0x2D`.

---

## 8. DMA / Latching Mechanism

The OBJ RAM contents are **double-buffered**. The hardware latches OBJ RAM into a shadow buffer at the start of vertical blank. The sprite engine reads from the shadow buffer during the following frame, not from the live OBJ RAM.

Sequence:
1. CPU writes sprite data to OBJ RAM within GFX RAM at any time during the frame.
2. At VBLANK start: the entire OBJ RAM (`0x0800` bytes) is copied to the shadow buffer.
3. The sprite renderer reads the shadow buffer during screen rendering.

This means sprite updates written during frame N are displayed in frame N+1. Games must write sprite data before VBLANK to ensure it takes effect on the next frame.

The OBJ_BASE register is also re-read at VBLANK to allow the game to dynamically relocate the OBJ RAM within GFX RAM.

---

## 9. Initialization Defaults

At video_start (power-on / reset), the following default values are applied:

| Register     | Default Value | Effective Base Address          |
|--------------|---------------|---------------------------------|
| `OBJ_BASE`   | `0x9200`      | CPU `0x920000`, GFX offset `0x20000` |
| `SCROLL1_BASE` | `0x9000`    | GFX offset `0x00000`            |
| `SCROLL2_BASE` | `0x9040`    | GFX offset `0x04000`            |
| `SCROLL3_BASE` | `0x9080`    | GFX offset `0x08000`            |
| `OTHER_BASE`   | `0x9100`    | GFX offset `0x10000`            |

Note: some bootleg games force `OBJ_BASE = 0x9100` as a kludge, overlapping the OTHER region.
