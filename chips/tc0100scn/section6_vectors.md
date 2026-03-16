# TC0100SCN — Section 6: Vector Generation Notes

---

## 1. Scope

This document describes the test vector strategy specific to the TC0100SCN streaming tilemap generator. It supplements the general vector framework in `gates/run_gates.sh` and the PIPE_LATENCY notes in `templates/section4c_decoder.sv`.

The TC0100SCN is architecturally distinct from the CPS1 OBJ chip (the Track A blind-test subject). CPS1 OBJ is a line-buffer renderer; TC0100SCN is a streaming generator. Vector generation must test streaming correctness, not just pixel value correctness.

---

## 2. Key Behavioral Properties to Test

The following properties derive from the behavioral analysis in `section2_behavior.md` and from MAME's `tc0100scn.cpp`.

### 2.1 Pixel Continuity (No Dead Cycles)

The most critical property: during active scan, the chip must produce exactly one valid pixel per pixel clock with no gaps. Any implementation that produces a "bubble" (invalid pixel) mid-row is incorrect and will produce visible tearing artifacts.

Test approach:
- Apply a known tilemap pattern (e.g., tile 0 for columns 0–19, tile 1 for columns 20–39).
- Assert that `pixel_valid` is high for every clock cycle during the active scan window.
- Any cycle where `pixel_valid` drops low during active scan is a failure.

### 2.2 Rowscroll Per-Line Accuracy

The rowscroll RAM provides a unique X offset for each of 256 scanlines. The effective X for row R is:

    effective_x = global_scrollx - rowscroll_ram[(R + global_scrolly) & 0x1FF]

Test approach:
- Initialize a distinctive tilemap (e.g., alternating column patterns).
- Write a known rowscroll pattern (e.g., a sawtooth: values 0, 1, 2, 4, 8 ...).
- Capture the output pixel stream for lines 0, 1, 2, 3 and verify each line's first pixel corresponds to the expected tile column after applying rowscroll.

### 2.3 Colscroll Per-Column Accuracy

Colscroll is applied per 8-pixel column group. The effective Y for tilemap-space X position `tx_x` is:

    effective_y = src_y - colscroll_ram[(tx_x & 0x3FF) / 8]

Test approach:
- Fill BG1 with a horizontal gradient (row 0 = all color 0, row 1 = all color 1, etc.).
- Write colscroll offsets: entries 0–4 = +2 (shift those columns up 2), entries 5–9 = 0.
- Verify that pixels in columns 0–39 (columns 0–4 × 8 pixels) show values from 2 rows lower in the tilemap than pixels in columns 40–79.

### 2.4 Layer Disable

Test each disable bit independently:
- Write ctrl[6] with only bit 0 set → BG0 produces transparent pixels (color 0 everywhere).
- Write ctrl[6] with only bit 1 set → BG1 produces transparent pixels.
- Write ctrl[6] with only bit 2 set → FG0 produces transparent pixels.
- Write ctrl[6] = 0x07 → all layers disabled → all pixels transparent.

### 2.5 Priority Swap (bottomlayer)

The `bottomlayer()` function reads bit 3 of ctrl[6]:
- ctrl[6] = 0x00 → `bottomlayer()` = 0 → BG0 drawn first (bottom).
- ctrl[6] = 0x08 → `bottomlayer()` = 1 → BG1 drawn first (bottom).

Vector test:
- Place opaque tile in BG0 column 5, row 5. Place opaque (different color) tile in BG1 at same position.
- With ctrl[6] = 0x00, the pixel at that position must be BG1's color (BG1 is on top).
- With ctrl[6] = 0x08, the pixel at that position must be BG0's color (BG0 is on top).

### 2.6 Flip Screen

ctrl[7] bit 0 = 1 → all layers flipped X and Y:
- The tile at logical position (0,0) should appear in the bottom-right of the output.
- The tile at logical position (63,63) should appear in the top-left.
- Pixel at screen (0,0) when flipped should equal pixel at (319,239) of the unflipped image.

### 2.7 Scroll Wrap-Around

Tilemaps are 64×64 tiles = 512×512 pixels. The scroll registers are 16-bit. The effective scroll position wraps at 512:

- Write BG0_SCROLLX = 504 (8 pixels before wrap).
- The tile at tilemap column 63 should appear in screen columns 0–7.
- The tile at tilemap column 0 should appear in screen columns 8–15.
- Verify seamless wrap with no pixel gap or repeat.

### 2.8 Double-Width Mode Switch

- Initialize in single-width mode (ctrl[6] bit 4 = 0). Write data to BG0 at addresses 0x0000–0x3FFF.
- Switch to double-width (write ctrl[6] bit 4 = 1).
- Verify that the RAM pointer switch happened correctly: the tilemap now reads BG0 data from 0x00000–0x07FFF.
- Attempt to access the rowscroll RAM via the double-width addresses (0x10000) and verify they take effect.

### 2.9 FG Character RAM Writability

- Write arbitrary pixel data to FG character RAM (`0x6000–0x6FFF` byte range).
- Write an FG tile entry pointing to character 0 with no flip.
- Verify that the output pixel stream for the FG layer matches the data written to character RAM.
- Overwrite character 0 again with different data.
- Verify that the FG layer output updates immediately on the next frame (no double-buffering on character RAM).

### 2.10 Tile Flip

For each of the four flip combinations (no flip, X-flip, Y-flip, XY-flip):
- Use a distinctive asymmetric tile pattern (e.g., column 0 all-1, column 7 all-15).
- Write that tile at a known screen position with the given flip attribute.
- Capture the pixel output and verify the flip is applied correctly.

---

## 3. Vector File Format

Follow the format established for CPS1 OBJ vectors in `chips/cps1_obj/vectors/`. Each vector file is a tab-separated text file with one row per clock cycle during the test:

    cycle   ram_wr_en   ram_wr_addr   ram_wr_data   ctrl_reg   ctrl_data   expected_pixel   expected_layer

The `expected_pixel` field is a 15-bit value (matching the SC0–SC14 output bus). The `expected_layer` field (0=BG0, 1=BG1, 2=FG0, 3=transparent) is informational for debugging.

Minimum vector set for gate4:
- `vec_scrollx_basic.txt` — basic horizontal scroll, no rowscroll
- `vec_scrolly_basic.txt` — basic vertical scroll
- `vec_rowscroll.txt` — rowscroll per-line variation
- `vec_colscroll.txt` — colscroll per-column variation
- `vec_layer_disable.txt` — all four disable combinations
- `vec_priority_swap.txt` — bottomlayer 0 and 1 comparison
- `vec_flip_screen.txt` — flip screen on/off
- `vec_tile_flip.txt` — all four tile flip modes
- `vec_fg_charram.txt` — FG character RAM write and display
- `vec_pixel_continuity.txt` — streaming continuity check (no gaps during active scan)

---

## 4. MAME Ground Truth Extraction

For gate4 regression, MAME output is the ground truth. To extract reference pixel data from MAME:

1. Use MAME's built-in save-state and `-aviwrite` or video snapshot functionality on a known F2 game (Ninja Kids recommended as it uses TC0100SCN with no additional tilemap chips).
2. Alternatively, instrument `tc0100scn.cpp`'s `tilemap_draw()` to dump pixel output for specific scanlines to a log file.
3. The colscroll behavior is well-exercised by Growl's boat scene and Ninja Kids' flame boss scene — use these as reference cases for colscroll vectors.

The MAME `tilemap_update()` + `tilemap_draw()` sequence is called once per frame (at VBL). The vector timing model should match this: all RAM and control register writes happen during VBL/active scan in a defined sequence, then the full frame output is captured.

---

## 5. Streaming-Specific Vector Considerations

Unlike CPS1 OBJ (which can be tested with frame-end pixel counts), the TC0100SCN streaming requirement must be tested at cycle-level granularity. The `vec_pixel_continuity.txt` vector must:

1. Set up a complete tilemap (all 40 visible columns populated with opaque tiles).
2. Run the active scan sequence.
3. Assert that for every clock cycle where the horizontal counter is in the range [0, 319] and the vertical counter is in the range [0, 239], `pixel_valid` is asserted.

Any missing `pixel_valid` pulse is a gate4 failure indicating the pipeline introduced a bubble.

---

## 6. TC0620SCC Variant Vectors

If the TC0620SCC (6bpp variant) is implemented as a separate target, vectors must additionally cover:
- The 6bpp palette index (bits 5:0 vs bits 3:0 for TC0100SCN).
- The dual-ROM fetch behavior (4 low bits from one ROM bank, 2 high bits from a second ROM bank with separate chip-select).
- The pixel format merge: `(low_4bpp & 0xF) | (hi_2bpp & 0x30)`.

The TC0620SCC is used only in a subset of games (Driftout is the canonical example). Defer these vectors until TC0620SCC is explicitly scoped.
