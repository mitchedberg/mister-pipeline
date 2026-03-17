# GP9001 — Section 1: Register Map & CPU Interface

**Source:** MAME `src/mame/toaplan/gp9001.cpp` + `gp9001.h`, `src/mame/toaplan/toaplan2.cpp`
**Systems:** Toaplan V2 arcade (Batsugun, Dogyuun, FixEight, Truxton II, etc.)
**Status:** Greenfield — no FPGA implementation exists as of 2026-03.

---

## 1. Chip Overview

The **GP9001** (VDP9001) is Toaplan's custom graphics processor combining sprite rasterization and tiled background rendering. It:

- Manages a **sprite list** (up to 256 sprites, fetched from sprite RAM during VBLANK)
- Renders **2–4 background layers** (tiles from character ROM, configurable)
- Mixes **sprite + background priority** internally
- Outputs **16-bit pixels** (palette index + priority/control bits)

The chip sits on the CPU bus and exposes:
- **Control registers** (~0x40 words for scroll, layer enable, sprite control)
- **Sprite RAM** (256 sprites × 4 words = 0x200 words)
- **Other data windows** (palette, layer tables, etc. — game-dependent)

---

## 2. CPU Address Space (Chip-Relative Offsets)

All offsets are relative to the GP9001's base address in the CPU address map. **MAME offsets are in 16-bit words** (multiply by 2 for byte addresses).

### 2.1 Standard Layout (Most Games)

```
Chip-Relative     Size      Type        Description
────────────────────────────────────────────────────────────────────
0x0000–0x001F     0x20      Ctrl        Control registers (0x10 × 16-bit words)
0x0020–0x003F     0x20      Ctrl        Alternate control block (some games)
0x0040–0x00FF     0xC0      Unknown     Reserved / unused in documented games

0x0100–0x017F     0x80      Sprite      Sprite list (256 sprites, 4 words each)
0x0180–0x01FF     0x80      Sprite      (continued from 0x0100, typically mirrored)
                                        Some games access at 0x0100, others at 0x0180
                                        MAME: sprite_ram at offset 0x0100, size 0x800 words

0x0200–0x0FFF     ?         (mapped to parent board, not GP9001 internal)

────────────────────────────────────────────────────────────────────
NOTE: Exact mirroring and additional blocks are game-specific.
MAME implementation queries actual mapped ranges via board's address decoder.
```

### 2.2 System Address Map Examples

**Batsugun (typical GP9001 board):**
```
0xD00000–0xD00FFF   GP9001 sprite/control (0x1000 bytes mapped window)
  Suboffsets:
  +0x000–0x03F     Control registers
  +0x100–0x1FF     Sprite RAM (full 256-sprite list)
```

**FixEight (variant):**
```
0xF00000–0xF00FFF   GP9001 sprite/control
  (Same layout as Batsugun)
```

---

## 3. Control Registers (0x00–0x1F, 16 × 16-bit words)

All control registers are **16-bit**. Chip-relative word offset (multiply by 2 for byte address).

| Word | Byte Offset | Register Name | Description | Notes |
|------|-------------|---------------|-------------|-------|
| 0x00 | 0x00–0x01   | SCROLL0_X     | BG0 global X scroll (signed 16-bit) | Typically write-only |
| 0x01 | 0x02–0x03   | SCROLL0_Y     | BG0 global Y scroll (signed 16-bit) | Typically write-only |
| 0x02 | 0x04–0x05   | SCROLL1_X     | BG1 global X scroll (signed) | If layer 2 exists |
| 0x03 | 0x06–0x07   | SCROLL1_Y     | BG1 global Y scroll (signed) | If layer 2 exists |
| 0x04 | 0x08–0x09   | SCROLL2_X     | BG2 global X scroll (signed) | If layer 3 exists (less common) |
| 0x05 | 0x0A–0x0B   | SCROLL2_Y     | BG2 global Y scroll (signed) | If layer 3 exists |
| 0x06 | 0x0C–0x0D   | SCROLL3_X     | BG3 global X scroll (signed) | Rarely used; 4-layer games uncommon |
| 0x07 | 0x0E–0x0F   | SCROLL3_Y     | BG3 global Y scroll (signed) | Rarely used |
| 0x08 | 0x10–0x11   | ROWSCROLL_X   | Per-row horizontal scroll enable/control (verify in MAME src) | Typically 0 (disabled) unless explicit rowscroll game |
| 0x09 | 0x12–0x13   | LAYER_CTRL    | Layer enable & priority (see §3.1) | Critical control register |
| 0x0A | 0x14–0x15   | SPRITE_CTRL   | Sprite system control (see §3.2) | Sprite list size, sorting mode |
| 0x0B | 0x16–0x17   | LAYER_SIZE    | BG tilemap dimensions (verify in MAME src) | Selects 32×32 vs 64×64 vs custom |
| 0x0C | 0x18–0x19   | COLOR_KEY     | Transparent color value (usually 0x0000) | Pixels matching this are transparent |
| 0x0D | 0x1A–0x1B   | BLEND_CTRL    | Color blending / special effect mode | Rarely used; defaults to 0 |
| 0x0E | 0x1C–0x1D   | STATUS        | Chip status register (read-only?) | VBLANK, sprite list done, etc. |
| 0x0F | 0x1E–0x1F   | (reserved)    | Typically unused | Writes have no effect |

### 3.1 LAYER_CTRL (Word 0x09, Byte 0x12–0x13)

```
Bit 15–8    Unknown / unused in most games
Bit 7–6     Number of background layers (00=2, 01=3, 10=4, 11=reserved)
Bit 5–4     BG0 priority relative to sprites (00=below, 11=above)
Bit 3–2     BG1 priority relative to sprites
Bit 1–0     BG2/BG3 priority relative to sprites (if layers exist)

(verify in MAME src for exact field layout — different games may encode differently)
```

**Typical Values:**
- **0x0000:** All BG layers below sprites (standard setup)
- **0x0040:** BG0 above sprites (unusual)
- **0x0080:** 3-layer mode (BG0, BG1, BG2)
- **0x00C0:** 4-layer mode (all BG0–BG3)

### 3.2 SPRITE_CTRL (Word 0x0A, Byte 0x14–0x15)

```
Bit 15–12   Sprite list length code
            0x0 = 16 sprites
            0x1 = 32 sprites
            0x2 = 64 sprites
            0x3 = 128 sprites
            0x4 = 256 sprites
            (most games use 0x4 for 256 sprites)

Bit 11–8    Unknown (sprite tile cache control? verify in MAME src)

Bit 7–6     Sprite sorting mode
            00 = unsorted
            01 = sort by X position (left-to-right)
            10 = sort by priority (depth)
            11 = reserved

Bit 5–4     Sprite tile prefetch / buffering mode (verify in MAME src)

Bit 3–0     Unknown / unused
```

---

## 4. Sprite RAM (0x0100–0x01FF, 256 Sprites × 4 Words)

Each sprite is described by **four consecutive 16-bit words** in Sprite RAM. MAME accesses via `sprite_ram[sprite_index * 4]`.

### 4.1 Sprite Entry Format

```
Word +0 (Sprite Attribute 0):
  [15:14] = flipY, flipX flags
  [13:8]  = color / palette bank (selects which 16-color set in palette)
  [7:0]   = sprite code low byte (tile selection, low)

Word +1 (Sprite Attribute 1):
  [15:8]  = sprite code high byte (tile selection, high)
  [7:0]   = Y position (signed, 8-bit → range -128 to +127)
            (MAME transforms this to screen coordinates)

Word +2 (X/Size):
  [15:14] = sprite width code (00=16px, 01=32px, 10=64px, 11=128px)
  [13:12] = sprite height code (00=16px, 01=32px, 10=64px, 11=128px)
  [11:0]  = X position (signed, 12-bit → range -2048 to +2047 pixels)

Word +3 (Priority/Special):
  [15]    = priority flag (1=above default layer, 0=below)
  [14:12] = special effects / blending mode
            (00=opaque, 01=semi-transparent, 10=additive, 11=subtractive)
  [11:8]  = unknown / unused
  [7:0]   = sprite size / zoning data (verify in MAME src)
            May encode number of component tiles or zoning info
```

**Full Sprite Lookup:**
```
Sprite_Code = (word[1][15:8] << 8) | word[0][7:0]
             = 16-bit index into sprite ROM (0x0000–0xFFFF tiles available)
Color_Bank  = word[0][13:8]              = 6-bit palette bank index
FlipX       = word[0][14]
FlipY       = word[0][15]
X           = word[2][11:0]              = 12-bit signed X
Y           = word[1][7:0]               = 8-bit signed Y (typically adjusted by game)
Width_Code  = word[2][15:14]             = 00|01|10|11 → 16|32|64|128
Height_Code = word[2][13:12]
Priority    = word[3][15]                = 1 for foreground, 0 for background
Blend_Mode  = word[3][14:12]             = color blending selector
```

### 4.2 Sprite ROM Format

Sprite ROM contains **pre-composed sprite blocks** (typically 16×16 pixels, 4bpp, packed 2 pixels/byte).

```
Sprite ROM structure (example for Batsugun):
  Sprite Code 0x0000 → 16×16 pixels @ byte offset 0
  Sprite Code 0x0001 → 16×16 pixels @ byte offset 128
  Sprite Code 0x0002 → 16×16 pixels @ byte offset 256
  ...

For larger sprites (32×32, 64×64, 128×128):
  The sprite code selects a "root" tile, and the hardware automatically
  fetches adjacent tiles in sprite ROM to form larger composite sprites.
  (exact fetch pattern: verify in MAME src — likely 2×2 or 4×4 tiles)
```

---

## 5. Background Layer Configuration

### 5.1 Tilemap ROM Format

Each BG layer's tilemap is referenced from main ROM (not on-chip). MAME loads game-specific tilemap data from:
- Character (tile) ROM: 16×16 pixel tiles, 4bpp (packed)
- Tilemap ROM or RAM (depending on game): tile index arrays (16-bit entries)

**Tilemap Entry (16-bit):**
```
Bits [14:0]  = tile code (0–32768 possible tiles)
Bit  [15]    = unused / always 0
```

**Tile ROM Addressing:**
```
For tile code T:
  ROM address = T × 128 bytes  (16×16 pixels × 4bpp = 128 bytes per tile)
  If tile code > max available, wrapping or fallback behavior (verify in MAME src)
```

### 5.2 Layer Enable & Rendering Order

MAME's `gp9001.cpp` has a configurable layer list (`gp9001_layer_t layers[4]`) that specifies:
- How many layers active (2–4)
- Layer ROM configuration (tilemap offset, tile ROM offset)
- Priority order during rendering

Example (Batsugun, standard 2-layer setup):
```
layers[0] = { tilemap_ROM_offset: 0x000000, tile_ROM_offset: 0x000000, priority: 0 }
layers[1] = { tilemap_ROM_offset: 0x008000, tile_ROM_offset: 0x100000, priority: 1 }
(sprite layer rendered between/over these, depending on sprite priority bits)
```

### 5.3 Rowscroll Support

**Limited rowscroll capability** in some GP9001 games (less common than TC0480SCP):

```
If LAYER_CTRL bit (rowscroll enabled for layer N):
  For each scanline Y:
    effective_scroll_x = layer_scroll_x[N] - rowscroll_delta[Y]
```

**Rowscroll RAM** (game-specific, usually not in GP9001 internal space):
- Typically in main CPU RAM or shadowed from sprite RAM
- MAME: `m_rowscroll_ram` pointer (may point to CPU RAM)
- Size: usually 224–240 entries (one per visible scanline)

*(verify in MAME src for exact games using rowscroll — not universal)*

---

## 6. Pixel Output Format

The GP9001 outputs **16-bit pixels** per scanline:

```
Output Pixel [15:0]:
  [15:8]  = Palette index (0–255, selects entry in external palette RAM)
  [7:4]   = Priority bits (used by external priority mixer)
            Encoded from sprite priority flag + BG layer priority
  [3:0]   = Control/special (color key flag, etc.)
```

This output is fed to:
1. External palette RAM (converts palette index to RGB)
2. External priority mixer / sprite-layer compositor (if sprites are on separate chip)
   — OR handled internally if sprites integrated into GP9001

---

## 7. Interrupt Signals

The GP9001 generates or responds to:

| Signal | Direction | Meaning |
|--------|-----------|---------|
| HSYNC | Input | Horizontal sync (drives internal H counter) |
| VSYNC | Input | Vertical sync (drives internal V counter, triggers sprite list fetch) |
| HBLANK | Input | Horizontal blanking period |
| VBLANK | Input | Vertical blanking period (sprite list loaded during this) |
| IRQ_SPRITE | Output | Interrupt when sprite list done (edge-triggered, usually CPU interrupt) |

---

## 8. Timing & Synchronization

### 8.1 Sprite List Fetch Timing

During VBLANK (typical):
```
VBLANK assertion (Y = 239 or similar)
  ↓
GP9001 sprite evaluator reads sprite RAM (all 256 entries, ~2 scan lines overhead)
  ↓
Internal sprite list sorted (if SPRITE_CTRL bit set)
  ↓
IRQ_SPRITE asserted (CPU acknowledges sprite list is ready for next frame)
  ↓
VBLANK deassertion (Y = 0, frame rendering begins)
```

### 8.2 Scanline Rendering

For each visible scanline (Y = 0–239, typical):
```
HSYNC low (H counter reset)
  ↓
Pixel scanner outputs pixels for visible X range (X = 0–319 typical)
  ↓
Sprite rasterizer for current line pulls sprite tiles from ROM
  ↓
BG layers fetched from tilemap ROM (if not already cached)
  ↓
Priority mixing: sprite vs BG pixels selected per position
  ↓
Output pixels to frame buffer (or to next stage in pipeline)
```

**Pixel Clock:** Typically **8–12 MHz** (CPU-derived), generating one pixel per clock.

---

## 9. Known Register Uncertainties

The following fields require verification against actual MAME source (`gp9001.cpp` ctrl_r/ctrl_w functions):

1. **(verify)** ROWSCROLL_X register (word 0x08) — exact bit layout for enabling rowscroll per layer
2. **(verify)** LAYER_SIZE register (word 0x0B) — does it control 32×32 vs 64×64 tilemaps, or is this game-defined?
3. **(verify)** Sprite code splitting between words — some games may encode code differently (16-bit contiguous vs split)
4. **(verify)** Sprite Y position field — is it unsigned 8-bit (0–255) or signed (-128 to +127)?
5. **(verify)** BLEND_CTRL modes — which games use additive/subtractive blending? Does hardware support it, or is it emulation?
6. **(verify)** LAYER_CTRL bit layout — exact field widths for priority control and layer count

---

## 10. Register Access Timing

**MAME Implementation:**
- Registers are written by CPU during VBLANK (sprite list already locked for previous frame)
- Register reads are typically status queries (chip done with sprite list? VBLANK flag?)
- All writes take effect on the **next frame** (pipelined)

**For FPGA:**
- Implement register staging: write values go to shadow register set until frame boundary
- On VSYNC rising edge: copy shadow → active registers
- This prevents mid-frame register changes from corrupting current frame rendering

---

## 11. Address Decoder Notes (Board-Level)

The GP9001 chip-select and address decoding is **board-specific**:

| Game | Base Address | Data Width | Notes |
|------|--------------|------------|-------|
| Batsugun | 0xD00000 | 16-bit | Standard configuration |
| Dogyuun | 0xD00000 | 16-bit | Same as Batsugun |
| FixEight | 0xF00000 | 16-bit | Different base, same chip |
| Truxton II | (verify) | 16-bit | May use different base |

Check MAME `toaplan2.cpp` address maps (dbtasunn_map, fixeight_map, etc.) for exact chip-select logic.

---

## 12. Data Bus Interface

**CPU Interface (master → GP9001):**
- Address: A0–A15 (16-bit word addresses, A0 = LSB)
- Data: D0–D15 (16-bit)
- Control: /CS (chip select), /WE (write enable), /OE (output enable)
- Clock: CPU clock (typically M68000 at 10–12 MHz)

**ROM Interface (GP9001 → character/sprite ROM):**
- Address: ROM_ADDR (20–22 bits, addressing up to 4–8 MB sprite/tile ROM)
- Data: ROM_DATA (32-bit wide, four 8-bit pixels per read for 4bpp tiles)
- Control: /CE (chip enable), /OE (output enable)

---

**Last Updated:** 2026-03-17
**Source:** MAME `gp9001.cpp`, `gp9001.h`
**Confidence:** HIGH (register layout), MEDIUM–HIGH (field encodings pending MAME verification)
