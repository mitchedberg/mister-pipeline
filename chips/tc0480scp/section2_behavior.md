# TC0480SCP — Section 2: Behavioral Description & FPGA Implementation Plan

**Source:** MAME `src/mame/taito/tc0480scp.cpp` (Nicola Salmoria), `src/mame/taito/taito_z.cpp` (David Graves), Gunbustr schematics

---

## 1. Video Timing

**Resolution:** 320×240 visible (active area within 424×262 total frame)
**Pixel clock:** 26.686 MHz / 4 = 6.6715 MHz
**H-total:** 424 pixels per line
**V-total:** 262 lines per frame
**Visible X:** 0–319 (320 pixels)
**Visible Y (TC0480SCP games):** 16–255 = 240 lines (from `screen_config(config, 16, 256)` call)
**Refresh rate:** 6.6715 MHz / (424 × 262) ≈ 59.94 Hz

Derived from MAME: `m_screen->set_raw(XTAL(26'686'000)/4, 424, 0, 320, 262, 16, 256)`

The TC0480SCP chip itself is driven by the video board pixel clock (26.686 MHz source / 4). The chip generates its own internal counters synchronized to HSYNC and VSYNC inputs. This matches standard Taito Z/F3-era video timing.

---

## 2. Tilemap Layer Rendering Pipeline

The TC0480SCP handles five layers. There are two distinct rendering paths in MAME, reflecting two different hardware rendering behaviors:

- **bg01_draw**: Used for BG0 and BG1. Global zoom + rowscroll. No column scroll, no per-row zoom.
- **bg23_draw**: Used for BG2 and BG3. Global zoom + rowscroll + per-row zoom + column scroll.

Both paths render scanline-by-scanline using a fixed-point stepping algorithm.

### 2.1 BG0/BG1 Rendering Algorithm (bg01_draw — verbatim from MAME)

```
zoomx = 0x10000 - (ctrl[8+layer] & 0xff00)
zoomy = 0x10000 - (((ctrl[8+layer] & 0xff) - 0x7f) * 512)

if zoomx == 0x10000 and zoomy == 0x10000:
    // no zoom: use tilemap engine with per-row scrollx set from rowscroll RAM
    for row in 0..511:
        if not flipscreen:
            tilemap[layer].set_scrollx(row, bgscrollx[layer] - rowscroll_ram[row])
        else:
            tilemap[layer].set_scrollx(row, bgscrollx[layer] + rowscroll_ram[row])
    tilemap[layer].draw()
else:
    // zoom mode: manual scanline walk
    // starting X accumulator (24.8 fixed point, stored in 32-bit int):
    if not flipscreen:
        sx = ((bgscrollx[layer] + 15 + layer*4) << 16)
           + ((255 - (ctrl[0x10+layer] & 0xff)) << 8)   // DX sub-pixel
           + (x_offset - 15 - layer*4) * zoomx           // zoom origin adjustment

        y_index = (bgscrolly[layer] << 16)
                + ((ctrl[0x14+layer] & 0xff) << 8)       // DY sub-pixel
                - (y_offset - min_y) * zoomy              // zoom origin adjustment
    else:
        // flip screen: negate scroll, apply flip offsets
        ...

    for y in min_y..max_y:
        src_y = (y_index >> 16) & 0x1ff   // source row in tilemap (512 rows)

        // row_index for reading rowscroll RAM (reversed in flipscreen)
        row_index = src_y
        if flipscreen: row_index = 0x1ff - row_index

        x_index = sx - (rowscroll_hi[row_index] << 16) - (rowscroll_lo[row_index] << 8)

        // walk source pixels for this scanline
        for i in 0..screen_width:
            src_x = (x_index >> 16) & width_mask   // width_mask = 0x1ff (sw) or 0x3ff (dw)
            output_pixel[y][i] = tilemap_pixmap[src_y][src_x]
            x_index += zoomx  // advance by zoom step

        y_index += zoomy  // advance Y position by zoom step
```

Key details:
- `width_mask`: 0x1FF in standard mode (512 pixels wide tilemap), 0x3FF in double-width mode (1024 pixels wide)
- `screen_width`: fixed at 512 pixels in MAME (not 320) — the chip renders a full 512-wide source line and clips to the visible area
- Layer stagger: BG1 adds 4 to scrollx, BG2 adds 8, BG3 adds 12. This is a hardware constant that offsets the layers slightly to create parallax depth on the road surface.

### 2.2 BG2/BG3 Rendering Algorithm (bg23_draw — adds colscroll and per-row zoom)

Same as bg01_draw plus:

```
    for y in min_y..max_y:
        // Column scroll: look up Y offset for this column and add to src_y
        col_idx = (y - y_offset) & 0x1ff
        if flipscreen: col_idx = 0x1ff - col_idx
        src_y_index = ((y_index >> 16) + bgcolumn_ram[layer][col_idx]) & 0x1ff

        // Row zoom: fetch per-row zoom for this source row
        row_index = src_y_index
        if flipscreen: row_index = 0x1ff - row_index

        if layer_ctrl & row_zoom_enable[layer]:
            row_zoom = rowzoom_ram[layer][row_index]
        else:
            row_zoom = 0

        // Per-row X origin adjustment for row zoom
        x_index = sx
                - (rowscroll_hi[row_index] << 16)
                - (rowscroll_lo[row_index] << 8)
                - (x_offset - 0x1f + layer*4) * ((row_zoom & 0xff) << 8)

        // Per-row X step = global zoom minus per-row zoom reduction
        x_step = zoomx
        if row_zoom != 0:
            if not (row_zoom & 0xff00):
                x_step -= (row_zoom * 256) & 0xffff
            else:
                // UndrFire uses high byte: unclear why, treated same as low byte
                x_step -= ((row_zoom & 0xff) * 256) & 0xffff

        // walk source pixels as in bg01_draw, but using x_step instead of zoomx
        ...
```

The column scroll occurs BEFORE the row zoom lookup — the source Y used to index the rowscroll/rowzoom RAM is the **colscroll-adjusted** source Y. This means: column scroll shifts which row's rowscroll/rowzoom values apply.

### 2.3 Text Layer (FG0) Rendering

The text layer is a simple scrolling tilemap with no zoom and no rowscroll. It uses MAME's standard tilemap engine with a single global scrollx/scrolly. The text layer is always drawn on top of all BG layers.

```
tilemap[4].set_scrollx(0, -(ctrl[0x0c] - text_xoffs))
tilemap[4].set_scrolly(0, -(ctrl[0x0d] - text_yoffs))
// text_xoffs and text_yoffs are per-game calibration offsets
```

Tile map: 64×64 = 4096 tiles, 8×8 pixels each → 512×512 pixel space.

---

## 3. FPGA Rendering Strategy

MAME's algorithm walks source pixels for each output scanline. For FPGA, the equivalent is:

### 3.1 Per-Scanline Tile Fetch Architecture

For each layer, during the active line for output scanline Y:

1. Compute `src_y_index` using the fixed-point Y accumulator (global zoom + colscroll for BG2/3)
2. Compute `row_zoom` from rowzoom RAM (for BG2/3, if enabled)
3. Compute `x_step` = global zoomx - row_zoom reduction
4. For each output pixel X (0–319), compute `src_x_index` using fixed-point X accumulator
5. Fetch tile and pixel data from VRAM/ROM
6. Output pixel with color and priority

The key state per layer per scanline is:
- `y_index`: 32-bit fixed-point Y accumulator (advances by `zoomy` each scanline)
- `x_index_start`: 32-bit starting X value for the scanline (derived from scroll + rowscroll)
- `x_step`: 32-bit X step per pixel (= zoomx - row_zoom)

All five layers need their `y_index` accumulated in parallel. The tile fetch can be pipelined: fetch tile entry from VRAM (1 cycle), then pixel data from ROM (1–2 cycles depending on ROM width), then output.

### 3.2 Memory Access Pattern

For 320 output pixels per scanline, per layer:
- Each 16×16 tile covers 16 output pixels at 1:1 zoom → 20 tile fetches per row per layer
- At zoom 2:1 expansion: 10 tile fetches per row
- With zoom out / compression: up to ~40 tile fetches

ROM access: the TC0480SCP has a 32-bit ROM data bus (RD0–RD31). Each 32-bit word contains two 16-pixel rows worth of 4bpp data for one tile (at 16 pixels × 4bpp = 64 bits per row, so one 32-bit fetch = half a tile row). For FPGA, tiles should be pre-decoded from the packed format into indexed pixel arrays, stored in tile cache BRAMs.

### 3.3 Tile Cache Design

Rather than fetching each pixel from GFX ROM on the fly, use a tile row cache:
- Cache the current tile's pixel row (16 pixels × 4bpp = 64 bits = 8 bytes)
- When `src_x` crosses a tile boundary, fetch the next tile from VRAM + ROM
- This works at all zoom levels since the X accumulator always increases monotonically

For FPGA tile ROM access: GFX ROM is loaded into DDR3/SDRAM as part of the MiSTer ROM loader. The tile cache can be a small BRAM (e.g., 4 tiles × 2 rows × 64 bits = 512 bits) that prefetches ahead.

---

## 4. Double-Width Mode

When LAYER_CTRL bit 15 (0x80) is set, all four BG tilemaps switch from 32×32 to 64×32. The VRAM layout changes completely (see §2 of section1). This also doubles the tilemap width in pixels: 64×16 = 1024 pixels wide instead of 512.

MAME notes: `width_mask = 0x3ff` in double-width mode vs `0x1ff` in standard.
Slapshot changes this bit on the fly during gameplay, requiring FPGA to re-compute layer pointers immediately when the register is written.

In FPGA: the double-width flag must be latched at VBLANK (or applied immediately) and used to select the correct VRAM base address for each BG layer's tile fetch. A mid-frame change (as in Slapshot) requires immediate effect — the hardware clearly supports it.

---

## 5. Screen Flip

When LAYER_CTRL bit 14 (0x40) is set:
- All five tilemaps get `TILEMAP_FLIPX | TILEMAP_FLIPY` applied
- X scroll signs invert for BG layers (bgscrollx = +data instead of -data)
- Y scroll signs invert for BG layers (bgscrolly = -data instead of +data)
- Text layer scroll also inverts, with per-game text_xoffs/text_yoffs adjustments
- In bg01/bg23_draw, the Y accumulator start, rowscroll row index, and colscroll column index all have flip-specific formulas (see MAME source)
- Row areas are the same in flip and non-flip — only the row index is read in reverse

FPGA note: Screen flip requires inverting the output scanline direction (draw from bottom to top) and the output pixel direction (right to left), OR alternatively computing the flipped source coordinates. The MAME approach computes flipped source coordinates per pixel, which is the cleaner FPGA approach.

---

## 6. Layer Compositing

TC0480SCP compositing is straightforward: four BG layers in programmer-defined order, text always on top. Transparent pen is 0 for all layers. The chip outputs the top non-transparent pixel as a 16-bit value (palette index).

```
priority_order = get_bg_priority()  // from LAYER_CTRL bits [4:2]
layer[0] = (priority_order >> 12) & 0xf  // bottom
layer[1] = (priority_order >>  8) & 0xf
layer[2] = (priority_order >>  4) & 0xf
layer[3] = (priority_order >>  0) & 0xf  // top BG

// Draw order:
draw BG layer[0] opaque
draw BG layer[1] transparent over layer[0]
draw BG layer[2] transparent over result
draw BG layer[3] transparent over result
draw FG (text) transparent over result  // always topmost
```

This compositing happens before TC0360PRI, which then mixes the TC0480SCP output with the sprite engine output based on per-sprite priority bits.

---

## 7. CPU Interface Requirements

The TC0480SCP's RAM is directly CPU-readable and writable at word granularity. Key requirements for the FPGA interface:

1. **Write during active display**: The CPU writes to tilemap VRAM and scroll RAM at any time (including mid-frame). FPGA must handle concurrent CPU writes and tile-fetch reads. Use a dual-port BRAM for VRAM.

2. **Control register writes take effect immediately**: LAYER_CTRL changes (flip, double-width, priority order) take effect at the next frame in MAME. In hardware, some changes (like flip) likely take effect at the next VBLANK. Priority order and zoom changes are applied per-frame in MAME.

3. **Rowscroll and colscroll updates**: Games update rowscroll RAM during VBLANK or early in the frame. The FPGA must complete the row-scroll read before that scanline is rendered. Standard approach: latch row scroll for scanline N during the HBLANK preceding scanline N.

4. **Tilemap dirty tracking**: MAME marks tiles dirty when VRAM is written. FPGA doesn't need this — it always reads fresh tile data for each scanline.

5. **No DMA**: The TC0480SCP has no DMA capability. All transfers are CPU-driven word writes.

---

## 8. FPGA Module Decomposition

```
tc0480scp.sv  (top-level module)
├── tc0480scp_regs.sv
│     - 0x18 × 16-bit control register bank
│     - Scroll, zoom, layer control decode
│     - Double-width/flip flag outputs
│     - Priority order decode (8-entry LUT → 4-nibble output)
│
├── tc0480scp_vram.sv
│     - 64KB dual-port BRAM (CPU r/w port + tile-fetch read port)
│     - Byte-enable writes (16-bit word granularity)
│     - Pointer decode: maps VRAM offset to layer/rowscroll/colscroll/zoom/text
│
├── tc0480scp_tilefetch.sv  (one instance per BG layer, 4 total)
│     - Per-layer: y_index accumulator, colscroll lookup (BG2/BG3 only)
│     - Per-scanline: x_index start computation (scroll + rowscroll hi+lo)
│     - Per-pixel: x_index advance, tile boundary detect, VRAM tile read
│     - ROM tile data fetch (from tc0480scp_gfxrom_cache.sv)
│     - Output: 4-bit pixel + color index per clock
│     - Sub-modules:
│         tc0480scp_rowzoom.sv  (BG2/BG3: row zoom fetch + x_step modify)
│         tc0480scp_colscroll.sv  (BG2/BG3: per-column Y offset lookup)
│
├── tc0480scp_textlayer.sv
│     - 64×64 FG0 tilemap, 8×8 tiles
│     - Tile data from VRAM (e000–ffff)
│     - Global scroll only (no zoom, no rowscroll)
│     - Output: 4-bit pixel + 6-bit color per clock
│
├── tc0480scp_gfxrom_cache.sv
│     - GFX ROM interface (from SDRAM or ROM loader BRAM)
│     - Tile row cache: caches one or two rows per active tile per layer
│     - Prefetch logic: when x_index approaches tile boundary, fetch next tile row
│
└── tc0480scp_colmix.sv
      - 5-layer compositor: BG0–BG3 in priority order + text always top
      - Transparent pixel masking (pen 0 = transparent for all layers)
      - Output: 16-bit pixel to TC0360PRI (or direct to palette RAM)
```

### 8.1 Memory Requirements

| Resource          | Size     | Storage       |
|-------------------|----------|---------------|
| VRAM (tile maps)  | 64KB     | On-chip BRAM (~16 M10K on Cyclone V) |
| GFX ROM           | 1–4 MB   | SDRAM (loaded by HPS/ROM loader) |
| Text gfx (RAM)    | 8KB (part of VRAM) | Covered by VRAM BRAM |
| Y accumulator     | 32-bit × 4 layers | Registers |
| Row scroll cache  | 512 × 16-bit × 4 | On-chip BRAM (~4KB × 4 = 16KB) |
| Row zoom cache    | 512 × 16-bit × 2 | On-chip BRAM (~4KB × 2 = 8KB) |
| Col scroll cache  | 512 × 16-bit × 2 | On-chip BRAM (~4KB × 2 = 8KB) |
| Line buffers      | 320 × 4-bit × 5  | ~200 bytes × 2 banks (ping-pong) |

BRAM total (on-chip): ~48KB — fits comfortably in Cyclone V (5.6 Mb total BRAM).
GFX ROM must go in SDRAM. The tile row cache (≈ 8 tile rows × 5 layers × 64 bits = 320 bytes) lives on-chip.

---

## 9. Incremental Build Order

**Step 1: Register bank + VRAM interface**
- Implement tc0480scp_regs.sv: full register decode, scroll/zoom output signals
- Implement tc0480scp_vram.sv: dual-port BRAM, CPU r/w, tile fetch read port
- Test: write known pattern to VRAM, read back via CPU port

**Step 2: Text layer (FG0)**
- Implement tc0480scp_textlayer.sv
- 64×64 tile map, 8×8 tiles, global scroll, no zoom
- Text gfx from VRAM 0xE000–0xFFFF
- Test: write known tile pattern, verify pixel output

**Step 3: BG0/BG1 — global scroll only (no zoom)**
- Implement tc0480scp_tilefetch.sv for BG0 and BG1
- No zoom path: rowscroll RAM drives per-row scrollx, MAME tilemap engine equivalent
- Test: solid-color tiles, verify scroll wrapping and rowscroll delta

**Step 4: BG0/BG1 — global zoom**
- Add zoom path to tc0480scp_tilefetch.sv
- Y accumulator, X accumulator, zoom step
- Test: zoom in/out on known tile pattern, verify no staggering artifacts

**Step 5: BG2/BG3 — column scroll**
- Add tc0480scp_colscroll.sv
- Column scroll Y offset added to src_y before row fetch
- Test: with all-zero colscroll (no effect), then with known sinusoidal pattern

**Step 6: BG2/BG3 — per-row zoom**
- Add tc0480scp_rowzoom.sv
- Row zoom enables (LAYER_CTRL bits 0/1), rowzoom RAM, x_step reduction + x_origin adjustment
- Test: uniform row zoom = verify proportional compression, per-row variation = verify road perspective

**Step 7: Double-width mode**
- LAYER_CTRL bit 15 changes tile map dimensions and VRAM layout
- width_mask changes from 0x1FF to 0x3FF
- VRAM pointer decode switches between standard and double-width regions
- Test: write tiles in double-width layout, verify correct tile is fetched at each position

**Step 8: Screen flip + priority compositing**
- Implement tc0480scp_colmix.sv with 5-layer priority mux
- Add flip logic to all layers (negate accumulators, reverse row/col indices)
- Test: flip register, verify layer stacking in all 8 priority orders

---

## 10. Gate 4 Test Strategy

The Python behavioral model (`tc0480scp_model.py`) should implement:

1. `write_ctrl(word_offset, data)` — control register bank
2. `write_ram(byte_offset, data, mask)` — VRAM (tile maps, scroll RAM, etc.)
3. `read_ram(byte_offset)` — VRAM read
4. `load_gfx_rom(data)` — load packed tile ROM
5. `render_scanline(y) → [320 pixels]` — full composited scanline output
6. `render_frame() → [[pixels]]` — full frame (240 scanlines)

Gate 4 test vectors should cover:
- VRAM write + scroll register → correct tile at correct position (all 5 layers)
- Rowscroll RAM write → per-row horizontal offset applied on BG0
- BG zoom: X-only, Y-only, XY together; verify pixel positions
- BG2 row zoom: uniform value (proportional horizontal scale), ramp (perspective convergence)
- BG2 column scroll: sinusoidal → wavy vertical effect
- Double-width mode: tile at map position (33, 0) visible when scroll puts it on screen
- Priority order: all 8 LAYER_CTRL combinations, with one layer transparent at a known position
- Screen flip: verify all layers mirror correctly, scroll registers produce same visual result
- Text layer: CPU-uploaded gfx, verify pixel data, verify scroll, verify always-on-top

---

## 11. Complexity Assessment and Tier Rating

**TC0480SCP is a Tier-4 chip** (highest complexity encountered in this pipeline):

Complexity factors:
- Five independent layers requiring simultaneous per-scanline rendering
- Three-level zoom system: global zoom (all 4 BG) × per-row zoom (BG2/3) × global scroll
- Column scroll adds a second-order indirection: the colscroll-adjusted Y selects which row's rowscroll/rowzoom to use
- Double-width mode changes VRAM layout mid-game (Slapshot does this in-play)
- Layer priority is dynamic (8 possible orders, used actively in Metalb and Gunbustr)
- GFX ROM must be in SDRAM; tile cache design is non-trivial with variable zoom
- 32-bit ROM bus requires DDR/burst SDRAM access pattern

**Estimated Gate 4 first-pass rate: 30–40%**

The primary risk areas are:
- Zoom accumulator precision (MAME notes historical jaggedness in zoom sequences)
- Row zoom x_origin adjustment formula (MAME notes it as "flawed" / approximate)
- Double-width mode mid-frame switch
- Screen flip corner cases (row/col indices, stagger offsets)

These issues were not fully solved even in MAME — the MAME comments explicitly call out imperfect zoom in Gunbustr's Taito logo and jaggedness in Under Fire's road. The FPGA implementation should aim for MAME-equivalent accuracy (not necessarily perfect hardware accuracy on these edge cases).

---

## 12. Reusable Components (Already in Pipeline)

| Chip | Location | Reuse |
|------|----------|-------|
| TC0360PRI | `rtl/tc0360pri.sv` | Direct — handles sprite/tilemap priority mixing |
| TC0260DAR | `rtl/tc0260dar.sv` | Direct — palette DAC (some TC0480SCP games use raw palette RAM instead) |
| TC0150ROD | MAME reference | Road generator (separate chip, separate module) |

TC0480SCP connects to TC0360PRI as a layer input. TC0260DAR or raw palette RAM connects to TC0360PRI's output. For Double Axle specifically, the palette format is `xBGR_555` (5-bit BGR), handled by TC0260DAR or equivalent.

---

## 13. Games Across Systems Using TC0480SCP

The TC0480SCP appears in both late Taito Z and early Taito F3-era boards:

| Game | System | Notes |
|------|--------|-------|
| Double Axle (Power Wheels) | Taito Z | Standard layout |
| Racing Beat | Taito Z | Standard layout |
| Gunbuster | Taito F3-era | Uses TC0480SCP + Ensoniq sound |
| Ground Effects (Super Chase) | Taito F3-era | Uses 68020, Ensoniq |
| Under Fire | Taito F3-era | Uses row zoom priority hack |
| Galastrm | Taito F3-era | |
| Footchamp / Hat Trick Hero | Taito F2-era | Uses double-width mode |
| Metalb | Taito F3-era | Uses all 8 priority orders |
| Deadconx | Taito F3-era | Uses bit 5 of LAYER_CTRL |
| Slapshot | Taito F3-era | Changes double-width on the fly |

The taito_z Taito Z games (Double Axle, Racing Beat) are the primary targets for the Taito Z MiSTer core. The other games share the same TC0480SCP module but require their own CPU/sprite modules.
