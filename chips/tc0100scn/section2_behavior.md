# TC0100SCN — Section 2: Behavioral Description

Human-verified against MAME source `src/mame/taito/tc0100scn.cpp`, `tc0100scn.h`, and `taito_f2.cpp` (rev. master, 2024-03). No jotego reference implementation exists for this chip; sole authoritative reference is MAME.

---

## 1. Overview

The TC0100SCN is a streaming tilemap generator. It manages three independently-scrolling 8×8-pixel-tile layers:

- **BG0**: Background layer 0. Tiles sourced from external ROM. Supports per-row X-scroll (rowscroll).
- **BG1**: Background layer 1. Tiles sourced from external ROM. Supports per-row X-scroll (rowscroll) and per-column Y-scroll (colscroll).
- **FG0**: Foreground text layer. Tiles sourced from CPU-writeable RAM (dynamic characters). No rowscroll or colscroll.

All three layers use 8×8-pixel tiles. Tilemaps are logically 64×64 tiles (standard mode) or 128×64/128×32 tiles (double-width mode). Only the portion of the tilemap visible within the active display window is rendered at any time.

The chip's output is 15 bits of pixel data per clock (SC0–SC14), delivered continuously during the active video period. The 15-bit output encodes both a priority value and a palette index. This output connects directly to the priority mixer (TC0360PRI or TC0110PCR depending on board revision).

**Architectural distinction from CPS1 OBJ:** The TC0100SCN is a streaming generator, not a line-buffer renderer. There is no internal line buffer. Pixels must be produced in raster order, one per pixel clock, continuously during the active scan. This creates hard timing constraints on tile fetch that do not exist in a line-buffer architecture.

---

## 2. Display Timing

From the Ninja Kids PCB layout documented in the F2 driver:

| Parameter             | Value                                      |
|-----------------------|--------------------------------------------|
| Primary oscillator    | 26.686 MHz (video dot clock source)        |
| Pixel clock           | 6.671 MHz (26.686 / 4) — derived          |
| 68000 CPU clock       | 12.000 MHz (from 24 MHz OSC2 / 2)         |
| Vertical sync         | 60 Hz                                      |
| Active display        | 320×240 pixels (typical F2 games)          |

The Taito F2 system uses a 320-wide active display. Tile columns per visible row = 320 / 8 = 40 tiles. At the pixel clock of approximately 6.671 MHz, each pixel period is approximately 150 ns.

### Timing Budget Per Tile

Each 8-pixel tile spans 8 pixel clocks. At 6.671 MHz pixel clock, that is approximately 1.2 microseconds per tile.

For back-to-back streaming output, the chip must complete the fetch of the next tile's pixel row data before the current tile's 8th pixel is output. The fetch pipeline must therefore operate with the following overlap:

- While pixels 0–7 of tile N are shifting out, the fetch of tile N+1 must be in progress.
- The fetch of tile N+1 must be complete no later than the clock edge at which pixel 0 of tile N+1 is required.

This is the "overlap logic" referenced in the pipeline note in `templates/section4c_decoder.sv`. The template uses a serialized decode model (one tile per PIPE_LATENCY slot) and explicitly documents that for streaming output, multiple decoder instances with staggered fetch_start signals or a pixel-shift-register stage must be used. For TC0100SCN, the correct architecture is a **pixel shift register**: the tile fetch pipeline produces 8 pixels at once (one full row of the tile), which are loaded into an 8-pixel shift register and shifted out one per clock. The next tile fetch begins at or before pixel 4 of the current tile (the halfway point), so that its 8 pixels are ready to load before the shift register empties.

See section 4 below for the exact timing constraint analysis.

---

## 3. Layer Architecture

### BG0 and BG1 (ROM-sourced)

BG0 and BG1 are structurally identical. Each is a scrollable tilemap backed by external ROM for tile pixel data and by on-chip SRAM for tile map data. The key distinction in the hardware is the colscroll feature: only BG1 has colscroll capability. The "topmost background" (per the priority register) is the one with colscroll, and MAME's `tilemap_draw_fg()` implements the colscroll path for layer 1.

Both BG layers support:
- Global X and Y scroll (16-bit, wrapping at tilemap boundaries)
- Per-row X-scroll (rowscroll) — one additional X offset per screen scanline
- Full X/Y flip of the entire layer

BG1 additionally supports:
- Per-column Y-scroll (colscroll) — one Y offset per 8-pixel column group

### FG0 (RAM-sourced)

FG0 is the text layer. Tile pixel data comes from a 4KB region of the TC0100SCN's own SRAM (not the tile ROM). The CPU can modify character definitions at any time. FG0 supports global X/Y scroll and flip, but no rowscroll or colscroll.

FG0 uses 2 bits per pixel (4 colors per palette entry) vs. 4 bits per pixel for BG layers.

FG0 is always rendered on top of both BG layers. Its layer-disable bit (ctrl[6] bit 2) can suppress it entirely.

---

## 4. Streaming Timing Analysis

This section documents the timing budget explicitly, as required by the TC-specific critical note.

### Pixel Clock and Tile Slots

Assumed pixel clock: 6.671 MHz (26.686 / 4). One pixel period = 149.9 ns.

One tile (8 pixels) = 8 × 149.9 ns = 1.199 microseconds.

For streaming output, the chip must produce one pixel per pixel clock with no gaps. The tile data for tile N+1 must be fully available in a shift register before the shift register for tile N empties.

### Memory Latency Model (FPGA Implementation)

In the MiSTer FPGA implementation using M10K block RAM:
- VRAM (tilemap) read latency: 2 clocks (address registered → data registered output)
- Pattern ROM read latency: 2 clocks (same M10K model)

The template `section4c_decoder.sv` pipeline is 7 cycles from fetch_start to first pixel_valid:

    Cycle 0: tile_addr presented, fetch_start asserted (IDLE → FETCH_IDX)
    Cycle 1: VRAM address registered (FETCH_IDX → WAIT_IDX)
    Cycle 2: VRAM data valid, tile_index_r latched (WAIT_IDX → FETCH_ROM)
    Cycle 3: ROM address registered (FETCH_ROM → WAIT_ROM)
    Cycle 4: ROM data pipeline stage 1 (WAIT_ROM → WAIT_ROM2)
    Cycle 5: ROM data valid, pixel_row_r latched (WAIT_ROM2 → OUTPUT)
    Cycle 6: pixel_data output registered (OUTPUT → IDLE)

This 7-cycle serialized pipeline does NOT support streaming. For TC0100SCN, the implementation must overlap fetches. The required approach:

1. The fetch for tile N+1 begins at cycle 0 of tile N's output (when the first pixel of tile N shifts out).
2. The 7-cycle pipeline ensures the 8 pixels of tile N+1 are available after 7 clocks.
3. Tile N provides 8 pixels (8 clocks) — so tile N+1's fetch must start no later than cycle 1 of tile N to guarantee data arrives before tile N's shift register empties.

Practically: the pixel-shift-register stage holds 8 pixels. When the shift register is loaded (start of tile N), the fetch for tile N+1 is immediately initiated. The fetch pipeline completes in 7 clocks; the shift register takes 8 clocks to empty. There is exactly 1 clock of margin. This is the minimum feasible overlap; the implementation must ensure there are no additional stall cycles in the pipeline during active scan.

**If the FPGA clock runs faster than the pixel clock** (e.g., at 48 MHz with a 6 MHz pixel clock), there are 8 FPGA clocks per pixel period. The fetch pipeline (7 FPGA clocks) can complete within a single pixel period, allowing sequential fetch rather than overlapped fetch. This is the preferred implementation strategy for MiSTer.

---

## 5. Tilemap Rendering Sequence

Each frame, before active scan begins, the host system calls `tilemap_update()`. This function:

1. Checks the `m_dirty` flag; if set, marks all tilemap cells dirty so they are re-decoded.
2. Applies the global Y-scroll to BG0 and BG1 tilemaps.
3. Iterates over 256 scanlines and applies per-row rowscroll:
   - `tilemap[0].set_scrollx((scanline + bgscrolly) & 0x1FF, bgscrollx - bgscroll_ram[scanline])`
   - Same for BG1 with fgscrolly and fgscroll_ram.

Note: the naming in MAME uses `fgscrollx/y` for the second background layer (BG1), not the text layer (FG0). The text layer's scroll is applied directly to the tilemap engine via `set_scrollx/y` in `ctrl_w`. This naming reflects a historical artifact of MAME's code evolution; in the hardware, the three layers are BG0, BG1, and FG0 (text).

Then `tilemap_draw()` is called three times by the F2 driver, once per layer, in priority order:

1. Call `bottomlayer()` to determine whether BG0 or BG1 is drawn first.
2. Draw the bottom BG layer (layer 0 or 1 per bottomlayer result).
3. Draw the top BG layer (the other of BG0/BG1). For BG1 when it is the top layer, the colscroll-aware `tilemap_draw_fg()` path is used.
4. Draw FG0 (always last = always on top).

### Layer Drawing Logic

`tilemap_draw()` dispatches by layer index:

- **Layer 0 (BG0):** Standard MAME tilemap draw. No colscroll.
- **Layer 1 (BG1):** Uses `tilemap_draw_fg()`, which implements the colscroll path by reading pixel by pixel from the pre-rendered tilemap bitmap and applying per-column Y offsets.
- **Layer 2 (FG0):** Standard MAME tilemap draw. No colscroll.

Each layer checks its disable bit in ctrl[6] before drawing; if set, returns immediately.

---

## 6. Tile Entry Decode Detail

### BG Tile Decode (`get_bg_tile_info`)

For each BG tile at index `tile_index` in the 64×64 map:

    word_addr = 2 * tile_index + Offset  // Offset=0 for BG0, 0x4000/2 for BG1 (word offsets)
    attr = ram[word_addr]
    code = ram[word_addr + 1]
    color = (attr & 0xFF) + colbank
    flip = (attr & 0xC000) >> 14  // TILE_FLIPYX encoding

The optional tile callback (`m_tc0100scn_cb`) fires here if set. This allows per-game banking of the CODE field (used by Mahjong Quest for its unusual ROM banking scheme). No other F2 games use this callback.

### FG Tile Decode (`get_tx_tile_info`)

For each FG tile at index `tile_index` in the 64×64 map:

    word_addr = Offset + tile_index  // Offset=0x2000 (standard) or 0x9000 (double-width), word units
    attr = ram[word_addr]
    code = attr & 0x00FF
    color = ((attr & 0x3F00) >> 8) + tx_colbank
    flip = (attr & 0xC000) >> 14

FG color uses 6 bits (bits 13–8 of the tile word), giving 64 possible palette entries. BG color uses 8 bits (bits 7–0 of the attribute word), giving 256 palette entries.

---

## 7. Priority Mixing

The TC0100SCN does not implement priority arbitration internally. It outputs up to three layers as separate draw calls. Priority ordering is determined externally by the F2 system:

1. The TC0100SCN's `bottomlayer()` function exposes bit 3 of ctrl[6].
2. The external TC0360PRI (priority mixer chip) combines the three TC0100SCN layers with the sprite output.
3. Pixel color index 0 is the transparent pen for all three layers. A pixel with color 0 does not overwrite the layer below it.

The chip outputs 15-bit pixel data (SC0–SC14). From the Operation Thunderbolt schematics cited in the MAME source header, this is 15 parallel lines carrying the pixel's palette index and priority information per-pixel to the priority mixer.

---

## 8. Reset and Initialization

On reset (`device_reset`):
- `m_dblwidth` is cleared to 0 (single-width mode).
- All 8 control registers are cleared to 0.
- All scroll positions default to 0.
- All layers default to enabled (disable bits 0).
- Screen flip is cleared.

Typical F2 game initialization sequence:
1. Write all-zero to ctrl registers.
2. Clear tilemap RAM.
3. Set initial scroll positions.
4. Enable layers selectively via ctrl[6].

---

## 9. Multi-Screen Configuration

Thunder Fox uses two TC0100SCN chips on a single board, one primary and one subsidiary. The subsidiary chip's ctrl[7] bit 5 is set. MAME documents this may cause write-through behavior (writes to the main chip are mirrored to the subsidiary), but this is not emulated — its exact hardware function is unconfirmed.

For multi-screen games (Warriorb, etc.), each screen has its own TC0100SCN running in double-width mode. The chips operate independently; the display driver applies per-chip X offsets to handle the seam between screens. The `m_multiscrn_xoffs` and `m_multiscrn_hack` parameters in MAME account for subtle per-game scroll offset corrections at the screen boundary.

---

## 10. Double-Width Mode Transition

When ctrl[6] bit 4 changes state, `set_layer_ptrs()` is called immediately (within `ctrl_w`). This reinitializes `m_bgscroll_ram`, `m_fgscroll_ram`, and `m_colscroll_ram` pointers to the new addresses appropriate for the new memory layout. The active tilemap instances switch from the `[x][0]` (single-width) to `[x][1]` (double-width) array entries, or vice versa.

Changing double-width mode mid-frame is technically possible but no known game does so. The transition is effectively a mode-set operation performed once at game startup.
