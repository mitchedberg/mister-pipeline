# TC0480SCP — Section 3: RTL Build Plan

**Source documents:** section1_registers.md (register map, 24 control regs, VRAM layout),
section2_behavior.md (behavioral description, 8-step build order, critical pipeline ordering),
TC0630FDP section3_rtl_plan.md (methodology reference), tc0630fdp_bg.sv + tc0630fdp_lineram.sv
(reuse base, 579 + 519 lines at Step 16 completion)
**Complexity:** Tier-4 (five layers, per-scanline rowscroll on all four BG layers, per-row
zoom on BG2/BG3, per-column scroll on BG2/BG3, double-width mid-frame mode switch, 32-bit
GFX ROM bus, 8-entry dynamic priority LUT)

---

## 1. Module Decomposition

Four top-level modules + one top integrator. Each module maps to one
behavioral cluster from section2_behavior.md §8.

---

### 1.1 `tc0480scp_regs.sv` — Control Register Bank + Scroll/Zoom Decode

**Role:** Owns the 0x18 × 16-bit control register array (words 0–23, byte offsets
0x00–0x2F). Decodes all four per-layer scroll, zoom, DX/DY sub-pixel, and LAYER_CTRL
fields into named output signals consumed by all other modules.

**Ports:**
```
Inputs:
  clk, rst_n
  cpu_cs, cpu_we, cpu_addr[4:0], cpu_din[15:0], cpu_be[1:0]   // 68000 bus
Outputs:
  cpu_dout[15:0]
  bgscrollx[4][15:0]      // BG0–BG3 effective X scroll (stagger applied, sign-adjusted)
  bgscrolly[4][15:0]      // BG0–BG3 Y scroll
  bgzoom[4][15:0]         // BG0–BG3 zoom word (raw — bits[15:8]=xzoom, bits[7:0]=yzoom)
  bg_dx[4][7:0]           // BG0–BG3 sub-pixel X (ctrl[0x10+n] & 0xFF)
  bg_dy[4][7:0]           // BG0–BG3 sub-pixel Y (ctrl[0x14+n] & 0xFF)
  text_scrollx[15:0]      // FG0 X scroll
  text_scrolly[15:0]      // FG0 Y scroll
  dblwidth                // LAYER_CTRL bit[7]: 0=standard 32×32, 1=double 64×32
  flipscreen              // LAYER_CTRL bit[6]
  priority_order[2:0]     // LAYER_CTRL bits[4:2] → index into 8-entry LUT
  rowzoom_en[2]           // LAYER_CTRL bit[0]: BG2 per-row zoom enable
  rowzoom_en[3]           // LAYER_CTRL bit[1]: BG3 per-row zoom enable
  bg_priority[15:0]       // decoded 4-nibble priority word (from 8-entry LUT)
```

**Internal state:** `ctrl[0:23]` — 24 × 16-bit register array (flip-flops, not BRAM).

**Dependencies:** None. Pure register file.

**Key decode logic:**
- `bgscrollx[0]` = `-(ctrl[0])`; BG1 adds 4, BG2 adds 8, BG3 adds 12 (section1 §3.4)
- Stagger signs invert when `flipscreen` is set
- `bgscrolly[n]` = `ctrl[4+n]` (no stagger, sign inverts on flip)
- `bg_priority` LUT: `8'h{0123, 1230, 2301, 3012, 3210, 2103, 1032, 0321}[priority_order]`
  (section1 §3.2 — directly indexed combinational ROM, 8 entries × 16-bit)

---

### 1.2 `tc0480scp_vram.sv` — 64KB Dual-Port VRAM + Address Decoder

**Role:** Owns the full 64KB (0x8000 × 16-bit word) VRAM BRAM. Provides:
- CPU read/write port (word-granular, any address)
- Tile fetch read port (used by `tc0480scp_bg.sv` and `tc0480scp_textlayer.sv`)
- Scroll RAM read port (used by `tc0480scp_bg.sv` during per-scanline setup)

The address decoder exposes named logical sub-regions as separate read ports so that
callers can request "BG2 rowscroll for row 47" without computing the raw VRAM offset.

**Ports:**
```
Inputs:
  clk, rst_n
  // CPU port
  cpu_cs, cpu_we, cpu_addr[15:0], cpu_din[15:0], cpu_be[1:0]
  // Tile-fetch read port (primary — tile map word fetch)
  tf_addr[14:0], tf_rd
  // Scroll/zoom/colscroll read port (secondary — per-scanline RAM reads)
  sc_addr[14:0], sc_rd
Outputs:
  cpu_dout[15:0]
  tf_data[15:0]
  sc_data[15:0]
```

**Internal state:** `vram[0:32767]` — 32K × 16-bit `altsyncram` M10K (~16 M10K on
Cyclone V). True dual-port: port A = CPU r/w, port B = tile/scroll reads (time-shared
between tf and sc via one-cycle arbitration).

**Address decoding (standard layout, section1 §2):**

| Logical region | VRAM word range | Physical byte range |
|---|---|---|
| BG0–BG3 tile maps | 0x0000–0x1FFF (2 words/tile × 32×32 × 4) | 0x0000–0x3FFF |
| BG0–BG3 rowscroll hi | 0x2000–0x27FF | 0x4000–0x4FFF |
| BG0–BG3 rowscroll lo | 0x2800–0x2FFF | 0x5000–0x5FFF |
| BG2/BG3 row zoom | 0x3000–0x33FF | 0x6000–0x67FF |
| BG2/BG3 colscroll | 0x3400–0x37FF | 0x6800–0x6FFF |
| FG0 tile map | 0x6000–0x6FFF | 0xC000–0xDFFF |
| FG0 gfx data | 0x7000–0x7FFF | 0xE000–0xFFFF |

In double-width mode the base addresses for tile maps and all scroll/zoom/colscroll
RAM shift (section1 §2, double-width column). The decoder uses `dblwidth` from
`tc0480scp_regs.sv` to select the correct base. Since Slapshot switches `dblwidth`
mid-frame, this selection must be combinational (no pipeline latency on the decode).

---

### 1.3 `tc0480scp_bg.sv` — BG Layer Tilemap Engine (4 instances, parameterized)

**Role:** One instance per BG layer (BG0–BG3). During each active scanline, produces
one 4-bit pixel + 9-bit color value per pixel clock for the compositing stage. Operates
as a real-time walk: for each output pixel the engine steps the fixed-point X accumulator
and fetches tile/pixel data from VRAM and GFX ROM.

This is the most complex module. It implements both the `bg01_draw` path (BG0/BG1: global
zoom + rowscroll) and the `bg23_draw` path (BG2/BG3: adds colscroll and per-row zoom).
The `LAYER` parameter (0–3) selects which path is active.

**Ports (parameterized by `LAYER` 0–3):**
```
Inputs:
  clk, rst_n
  hpos[9:0], vpos[8:0]         // current pixel position (424-wide, 262-tall)
  pixel_active                 // 1 during visible pixels
  hblank_fall                  // one-cycle pulse at start of HBLANK
  vblank_fall                  // one-cycle pulse at start of VBLANK

  // Register-bank outputs (from tc0480scp_regs.sv)
  bgscrollx[15:0], bgscrolly[15:0]
  bgzoom[15:0]
  bg_dx[7:0], bg_dy[7:0]
  dblwidth, flipscreen
  rowzoom_en                   // BG2/BG3 only; BG0/BG1: tie to 0

  // VRAM tile-fetch port (shared, arbitrated at top level)
  vram_q[15:0]
  vram_addr[14:0]              // driven by this module
  vram_rd

  // Scroll/zoom/colscroll RAM read port (shared, arbitrated at top level)
  scram_q[15:0]
  scram_addr[14:0]
  scram_rd

  // GFX ROM port (from SDRAM tile cache)
  gfx_data[31:0]               // 32-bit read (4 bytes per fetch)
  gfx_addr[20:0]               // tile ROM byte address >> 2 (word-addressed 32-bit)
  gfx_rd

Outputs:
  bg_pixel[3:0]                // 4-bit pen index (0 = transparent)
  bg_color[7:0]                // 8-bit palette bank
  bg_valid                     // pixel output valid (matches pixel_active)
```

**Internal state:**
- `y_index[31:0]` — 32-bit fixed-point Y accumulator (16.16). Reset at frame start.
  Incremented by `zoomy` (decoded from `bgzoom[7:0]`) each scanline.
- `x_index_start[31:0]` — 32-bit X start value for the current scanline. Loaded at
  HBLANK from: `bgscrollx << 16` adjusted for rowscroll hi/lo and DX sub-pixel.
- `x_step[31:0]` — X advance per pixel. For BG0/BG1: `zoomx`. For BG2/BG3: `zoomx`
  minus per-row zoom reduction (loaded with `x_index_start` at HBLANK).
- `x_index[31:0]` — running X accumulator (reset to `x_index_start` at each new line).
- `tile_row_cache[15:0]` — 16 pixels × 4bpp of the current tile row (decoded from
  one 32-bit GFX ROM fetch). Refreshed when `x_index >> 16` crosses a 16-pixel boundary.
- FSM: `BG_IDLE → BG_HBLANK_SETUP → BG_READY` for per-scanline init;
  `BG_TILE_ATTR → BG_TILE_CODE → BG_GFX_FETCH → BG_CACHE_READY` for tile boundary refills.

**HBLANK setup sequence (BG2/BG3 path — section2 §2.2):**

The setup for a scanline must execute the colscroll-before-rowzoom ordering:

```
Step 1: compute src_y_float = y_index >> 16          (integer source row)
Step 2: apply colscroll: col_idx = (vpos - y_offset) & 0x1FF
         (flipscreen: col_idx = 0x1FF - col_idx)
         READ scram[colscroll_base + col_idx]         (one VRAM read)
         src_y = (src_y_float + scram_q) & 0x1FF     ← COLSCROLL APPLIED HERE
Step 3: apply rowzoom: row_idx = src_y (colscroll-adjusted)
         (flipscreen: row_idx = 0x1FF - row_idx)
         if rowzoom_en: READ scram[rowzoom_base + row_idx]  (one VRAM read)
         row_zoom = scram_q & 0xFF
         x_step = zoomx - (row_zoom << 8)
Step 4: apply rowscroll: READ scram[rowscroll_hi_base + row_idx]  (one VRAM read)
                          READ scram[rowscroll_lo_base + row_idx]  (one VRAM read)
         x_index_start = sx_base
                       - (rowscroll_hi << 16)
                       - (rowscroll_lo << 8)
                       - (x_offset - 0x1f + LAYER*4) * (row_zoom << 8)
Step 5: x_index ← x_index_start  (ready for pixel walk)
```

Steps 1–5 execute during HBLANK (at most 4 VRAM reads per layer per scanline).
Steps 2 and 3 are the critical colscroll-before-rowzoom ordering. See §3 below.

**BG0/BG1 HBLANK setup (simpler — no colscroll, no rowzoom):**

```
Step 1: src_y = y_index >> 16
Step 2: row_idx = src_y; (flipscreen: 0x1FF - src_y)
Step 3: READ rowscroll_hi, rowscroll_lo
Step 4: x_index_start = sx_base - (rs_hi << 16) - (rs_lo << 8)
Step 5: x_step = zoomx (global, no per-row override)
```

**Pixel fetch (active display):**
At each pixel clock: output pixel from `tile_row_cache` indexed by `(x_index >> 16) & 0xF`.
When `(x_index >> 16) & ~0xF` != current tile X base: issue GFX ROM fetch for next 16-pixel
tile row. Advance `x_index += x_step`. Advance `y_index += zoomy` at end of each scanline.

**Dependencies:** tc0480scp_regs.sv, tc0480scp_vram.sv (two ports), GFX ROM SDRAM
interface. The top-level arbitrates the shared VRAM ports across all four instances.

---

### 1.4 `tc0480scp_textlayer.sv` — FG0 Text Layer Engine

**Role:** Renders the 64×64 FG0 tile map using 8×8 4bpp tiles uploaded by the CPU into
VRAM 0xE000–0xFFFF. Global scroll only. No zoom, no rowscroll, no colscroll. Always
composited as the topmost layer.

**Ports:**
```
Inputs:
  clk, rst_n
  hpos[9:0], vpos[8:0]
  pixel_active
  text_scrollx[15:0], text_scrolly[15:0]   // from regs
  flipscreen
  vram_q[15:0]              // FG0 tile map word (0xC000–0xDFFF)
  vram_addr[14:0]           // driven by this module
  vram_rd
  // FG0 gfx: CPU-uploaded 8×8 tiles from VRAM 0xE000–0xFFFF
  // Accessed via secondary VRAM port (same BRAM, different address range)
  char_q[15:0]
  char_addr[12:0]           // word offset within gfx region
  char_rd
Outputs:
  text_pixel[3:0]           // 4-bit pen (0 = transparent)
  text_color[5:0]           // 6-bit palette bank from tile attr[13:8]
  text_valid
```

**Internal state:**
- Tile register: `tile_idx[7:0]`, `tile_color[5:0]`, `tile_flipx`, `tile_flipy`
- Pixel row cache: `char_row_data[7:0]` — 8 pixels × 4bpp of current tile row
  (two consecutive 16-bit VRAM reads = 32 bits; format from section1 §4.3)
- Simple column counter: no accumulator needed (1:1 pixel:tile ratio always)

**Dependencies:** tc0480scp_regs.sv (text scroll), tc0480scp_vram.sv.

**Reuse from tc0630fdp:** The FG0 tile format (section1 §4.2) and pixel layout (§4.3)
exactly match the TC0630FDP `tc0630fdp_text.sv` charlayout, with the same non-trivial
bit-offset formula for packed 4bpp pixel data. The `tc0630fdp_text.sv` FSM and pixel
decode block can be copied and adapted: strip Line RAM interface, adjust to 6-bit color
field, change tile map size from 64×64 8-bit entries to 64×64 16-bit entries.
Estimated reuse: 60% of the 200-LOC text engine.

---

### 1.5 `tc0480scp_colmix.sv` — Five-Layer Compositor

**Role:** During active display, for each pixel position combines the five layer outputs
(BG0–BG3 + FG0) into a single 16-bit palette index output. Applies the dynamic priority
order from `bg_priority[15:0]` (4-nibble encoding). Text layer is hardwired topmost.
Transparent pen (0) is skipped for all BG layers.

**Ports:**
```
Inputs:
  clk, rst_n
  hpos[9:0], vpos[8:0], pixel_active
  // Four BG layer pixel streams
  bg_pixel[4][3:0]          // 4-bit pen per layer
  bg_color[4][7:0]          // 8-bit palette bank per layer
  bg_valid[4]
  // Text layer
  text_pixel[3:0]
  text_color[5:0]
  text_valid
  // Priority control
  bg_priority[15:0]         // 4-nibble order from regs (bottom→top in nibbles [15:12]→[3:0])
Outputs:
  pixel_out[15:0]           // 16-bit palette index → TC0360PRI
  pixel_valid_out
```

**Logic:**
```
// Evaluate in priority order, bottom layer first:
for i in 0..3:
    layer = (bg_priority >> (12 - i*4)) & 0xF  // extract nibble i (0=bottom)
    if bg_pixel[layer] != 0:                   // non-transparent
        result = (bg_color[layer] << 4) | bg_pixel[layer]
// Text always last (always topmost):
if text_pixel != 0:
    result = (text_color << 4) | text_pixel
pixel_out = result
```

No alpha blend, no clip planes (TC0480SCP has none). Compositing is 5 non-transparent
checks + 4 priority comparisons per pixel — trivially combinational in one LUT stage.

**Dependencies:** All four `tc0480scp_bg.sv` instances and `tc0480scp_textlayer.sv`.

---

### 1.6 `tc0480scp.sv` — Top-Level Integrator

**Role:** Instantiates all modules, owns VRAM BRAM instances, arbitrates shared VRAM
ports across four BG engines + text layer, routes CPU bus, generates output pixel stream
to TC0360PRI.

**VRAM port arbitration:** Four BG engines + text layer each need VRAM access. The BRAM
has two ports: port A (CPU) and port B (tile/scroll fetch). Port B is time-multiplexed:
- During HBLANK: round-robin among the four BG engines for scroll/zoom/colscroll RAM reads
  (at most 4 reads per layer per scanline = 16 total; HBLANK = 112 px-clocks → fits easily)
- During active display: one VRAM port per pixel for tile boundary refills + text reads
  (interleaved: BG0 → BG1 → BG2 → BG3 → Text, rotating per pixel boundary event)

**GFX ROM arbitration:** Four BG engines share the 32-bit SDRAM GFX ROM port. Round-robin
among those currently requesting a fetch (tile boundary crossed). Text layer uses VRAM
directly (CPU-uploaded gfx, no external ROM needed).

See §6 for the complete external port list.

---

## 2. Step-by-Step Build Plan

13 steps total. Each step builds on the previous, has explicit test cases that must pass
100% before proceeding, and has a corresponding Python model method in `scp_model.py`.
Steps 1–8 map directly to the section2_behavior.md §9 build order with additional
intermediate validation steps inserted for zoom correctness.

---

### Step 1 — Skeleton + Video Timing + Control Register Bank

**New capability:** Pixel-clock domain, H/V timing counters, all 24 control registers
implemented. Output: constant zero pixel stream. No rendering.

**Modules added:** `tc0480scp_regs.sv` (complete), top-level timing skeleton in
`tc0480scp.sv`.

**Test cases:**
1. Write BG0_XSCROLL (word 0) = 0x0010. Read back. Verify `bgscrollx[0]` = -0x0010 (negated per §3.4).
2. Write BG1_XSCROLL = 0x0010. Verify `bgscrollx[1]` = -(0x0010 + 4) = -0x0014 (layer stagger).
3. Write BG2_XSCROLL = 0x0010. Verify `bgscrollx[2]` = -0x0018 (stagger +8).
4. Write BG3_XSCROLL = 0x0010. Verify `bgscrollx[3]` = -0x001C (stagger +12).
5. Write all four Y scroll regs. Verify pass-through (no stagger, no negate).
6. Write LAYER_CTRL = 0x0080. Verify `dblwidth` = 1.
7. Write LAYER_CTRL = 0x0040. Verify `flipscreen` = 1. Verify `bgscrollx` signs invert.
8. Write LAYER_CTRL bits[4:2] = 3'b101. Verify `bg_priority` = 16'h2103 (table index 5).
9. Write LAYER_CTRL bit[0] = 1. Verify `rowzoom_en[2]` = 1, `rowzoom_en[3]` = 0.
10. Drive timing counters through one 424×262 frame. Verify `pixel_active` is high exactly
    320 × 240 = 76,800 cycles (visible area 0–319 × 16–255).
11. Verify `hblank_fall` pulses once per line at hpos=320.

**Python model:** `TC0480SCPModel.__init__`, `write_ctrl()`, `read_ctrl()`. No rendering.

**Expected test count:** 25–35 tests.
**New BRAM:** None (control regs are registers, not BRAM).

---

### Step 2 — VRAM Interface + CPU Read/Write

**New capability:** 64KB dual-port VRAM BRAM. CPU can read and write any address in the
0x10000-byte window. Tile-fetch and scroll-RAM read ports are wired but unused.

**Modules added:** `tc0480scp_vram.sv` (complete).

**Test cases:**
1. Write word at byte offset 0x0000. Read back. Verify round-trip.
2. Write at byte offset 0x4000 (BG0 rowscroll hi base). Read back. Verify.
3. Write at byte offset 0xC000 (FG0 tile map base). Read back. Verify.
4. Write at byte offset 0xE010 (FG0 gfx data). Read back. Verify.
5. Verify byte-enable: write 0xABCD with be=2'b01 (low byte only). Read back.
   Expect low byte = 0xCD, high byte unchanged.
6. Double-width address decode: with `dblwidth`=0, write byte 0x1000 (BG1 tile map).
   With `dblwidth`=1, same address now falls in BG0 map (doubled). Verify `dblwidth`
   switch immediately changes the decode (combinational).
7. Concurrent CPU write + tile-fetch read to the same address. Verify read returns
   old value (write-first vs read-first BRAM behavior: document which mode is used
   and ensure model matches).

**Python model:** `write_ram()`, `read_ram()`. No rendering.

**Expected test count:** 20–30 tests.
**New BRAM:** VRAM 64KB (~16 M10K). Rowscroll RAM, colscroll RAM, zoom RAM are
all sub-regions of this same BRAM — no additional storage needed.

---

### Step 3 — Text Layer (FG0): Fixed Scroll, No Zoom

**New capability:** FG0 text layer renders 64×64 tiles of 8×8 pixels from CPU-uploaded
gfx data. Global scroll from TEXT_XSCROLL / TEXT_YSCROLL. Always topmost. Colmix
stub outputs text only.

**Modules added:** `tc0480scp_textlayer.sv` (complete), `tc0480scp_colmix.sv`
(stub: text pass-through only, no BG layers yet).

**Test cases:**
1. Upload a solid-fill 8×8 tile (pen 5, color 3) to VRAM gfx offset 0 (tile 0).
   Write FG0 tile map: tile_index=0, color=3 at map position (0,0). Verify pixel
   (0,0) outputs palette index = (3 << 4) | 5 = 0x35.
2. Upload a horizontally-striped tile. Write to map position (5, 3). Verify
   stripe pattern appears at screen coords (40, 24).
3. Tile flipX: write tile at (2,0) with flipX=1. Verify pixel row is mirrored.
4. Tile flipY: write tile at (2,1) with flipY=1. Verify column is mirrored.
5. TEXT_XSCROLL = 8: verify tile map shifts left by 1 tile (8 pixels), wraps at 512.
6. TEXT_YSCROLL = 8: verify tile map shifts up by 1 tile.
7. Transparent pen: tile with pen=0 at map position (0,0). Verify colmix outputs
   palette index 0 (background) — text is transparent.
8. CPU writes to FG0 gfx data during active display. Verify the updated tile
   appears correctly on the next full frame (no tearing within frame required).
9. Pixel layout decode: upload a tile with known per-pixel pattern (section1 §4.3
   packed format with column-reversed nibbles). Verify exact pixel-by-pixel output
   matches the expected unpacked sequence.

**Python model:** `write_ram()` (already have), `load_gfx_rom()` (no-op for text —
gfx is from VRAM), `render_scanline(y)` for text layer only.

**Expected test count:** 35–50 tests.
**New BRAM:** None (FG0 tile map + gfx data are already within the VRAM BRAM).

---

### Step 4 — BG0/BG1: Global Scroll, No Zoom

**New capability:** BG0 and BG1 tile layers render from VRAM tile maps using GFX ROM
for 16×16 4bpp tiles. Global X/Y scroll. No rowscroll, no zoom. Colmix extended to
4 layers (BG0, BG1, text stub) with fixed priority.

**Modules added:** `tc0480scp_bg.sv` for BG0 and BG1 instances (zoom path disabled,
rowscroll path disabled, x_step = 0x10000 fixed). `tc0480scp_colmix.sv` extended to
include BG0, BG1, text.

**Test cases:**
1. Write a known 16×16 tile to GFX ROM (solid color, pen 7, color 0x5A). Write BG0
   tile map position (0,0) = tile 0, color 0x5A. Verify output pixels at (0,0)–(15,15)
   = palette index (0x5A << 4) | 7 = 0x5A7.
2. BG0_XSCROLL = 16: verify tile map shifts left 16 pixels, wraps at 512.
3. BG0_YSCROLL = 16: verify tile map shifts up 16 pixels.
4. 16-pixel tile flip: tile with flipX=1 — verify horizontal mirror.
5. Tile with flipY=1 — verify vertical mirror.
6. Tile with flipX and flipY together.
7. Transparent pen: BG0 tile with pen=0 over BG1 solid tile. Verify BG1 shows through.
8. Layer stagger: set BG0_XSCROLL = BG1_XSCROLL = 0. Place distinct tiles at map
   column 0 on each layer. Verify BG1's pixel at hpos=0 comes from BG1's map column 0,
   not column 1 (i.e. stagger is compensated internally, not visible as an offset
   between layers at zero scroll).
9. Double-width mode (`dblwidth`=1): write tiles into BG0 columns 32–63 (only accessible
   in double-width layout). Set BG0_XSCROLL to bring column 33 to screen. Verify
   correct tile appears. Then switch `dblwidth`=0: column 33 now unreachable — verify
   no crash or garbage.
10. GFX ROM 32-bit bus: verify that one 32-bit fetch decodes correctly to 8 pixels
    (two nibbles per byte, LSB first per section1 §8).

**Python model:** `load_gfx_rom()` (packed 32-bit format decode), extend
`render_scanline()` to BG0+BG1 with tile walk, flip, transparency.

**Expected test count:** 50–70 tests.
**New BRAM:** Row/col scroll RAMs are already in VRAM. GFX ROM lives in SDRAM
simulation array (no new on-chip BRAM needed).

---

### Step 5 — BG0/BG1: Rowscroll (No-Zoom Path)

**New capability:** Per-row horizontal scroll from rowscroll RAM (both hi and lo bytes)
applied to BG0 and BG1. This is the no-zoom rendering path (section2 §2.1 — zoom mode
disabled when `zoomx == 0x10000 && zoomy == 0x10000`).

**Modules extended:** `tc0480scp_bg.sv` BG0/BG1 instances add rowscroll RAM reads
during HBLANK. `x_index_start` computed per-scanline instead of being fixed.

**Test cases:**
1. Write BG0 rowscroll hi for row 50 = 32 (pixel units). Verify scanline 50 shifts
   right by 32 pixels while other scanlines remain at global scroll.
2. Write rowscroll lo for row 50 = 0x80 (sub-pixel). Verify sub-pixel offset contributes
   `(0x80 << 8)` to the fixed-point start.
3. Rowscroll on rows 0–239: write a linear ramp (0, 1, 2, ...). Verify visible slant effect.
4. BG1 rowscroll independent from BG0: different values per row on each layer.
5. flipscreen: verify rowscroll row index is reversed (`0x1FF - src_y` per section2 §2.1).
6. Rowscroll with colscroll-disabled BG0 (confirming no cross-contamination from BG2/BG3
   logic when `LAYER` parameter = 0).

**Python model:** Extend `render_scanline()` with rowscroll hi+lo lookup per-row,
matching MAME formula: `effective_x = sx - (rs_hi << 16) - (rs_lo << 8)`.

**Expected test count:** 30–45 tests.
**New BRAM:** None (rowscroll is already in VRAM).

---

### Step 6 — BG0/BG1: Global Zoom

**New capability:** Zoom mode (when `zoomx != 0x10000 || zoomy != 0x10000`) engages
the fixed-point Y accumulator and X accumulator path. Rowscroll is disabled in this
mode (section2 §2.1, section1 §5.1 — "When global zoom is active, rowscroll is disabled").

**Modules extended:** `tc0480scp_bg.sv` BG0/BG1 instances: Y accumulator added
(increments by `zoomy` each scanline, resets at VBLANK). X accumulator initialized
from `sx_base` (DX sub-pixel + scroll + zoom-origin adjustment). `x_step = zoomx`
(global, no per-row override for BG0/BG1).

**Key zoom decode from section1 §3.3:**
```
zoomx = 0x10000 - ((bgzoom[15:8]) << 8)   // X expansion only; 0x0000 zoom byte → zoomx=0x10000 (1:1)
zoomy = 0x10000 - ((bgzoom[7:0] - 0x7F) * 512)  // Y both expand and compress; 0x7F → zoomy=0x10000 (1:1)
```

**Test cases:**
1. Set BG0_ZOOM = 0x007F (yzoom=0x7F, xzoom=0x00): verify 1:1 output (no visible zoom).
2. Set xzoom = 0x40 (expansion): verify tilemap is horizontally stretched. Count that a
   16-pixel-wide tile now spans more than 16 output pixels.
3. Set yzoom = 0x3F (< 0x7F = compression): verify tilemap shrinks vertically.
4. Set yzoom = 0xBF (> 0x7F = expansion): verify vertical stretch.
5. Both axes: xzoom=0x40, yzoom=0xBF together. Verify independent scaling.
6. DX sub-pixel: set BG0_DX low byte = 0x80. Verify half-pixel X offset relative to
   DX=0x00 at 1:1 zoom.
7. Zoom then rowscroll: set zoom != 1:1, then write rowscroll RAM. Verify rowscroll
   is NOT applied (zoom path ignores rowscroll RAM per section1 §5.1).
8. Y accumulator wrap: run for enough scanlines that `y_index >> 16` wraps past 511.
   Verify tilemap wraps cleanly (source row = `(y_index >> 16) & 0x1FF`).
9. Layer stagger in zoom mode: BG1 with same zoom as BG0, same scroll. Verify the
   4-pixel stagger offset is still applied via `x_origin = (x_offset - 15 - LAYER*4) * zoomx`.

**Python model:** Extend `render_scanline()` to switch between zoom path and no-zoom
path based on zoomx/zoomy values.

**Expected test count:** 40–60 tests.
**New BRAM/state:** Y accumulator per layer (32-bit register × 4 = 16 bytes — trivial).

---

### Step 7 — BG2/BG3: Colscroll (Before Rowzoom — Critical Path)

**New capability:** BG2 and BG3 gain per-column vertical scroll. The colscroll-adjusted
source Y is computed BEFORE rowzoom lookup. This is the critical hardware ordering from
section2 §2.2.

**Modules extended:** `tc0480scp_bg.sv` BG2/BG3 instances: add colscroll RAM read
during HBLANK setup. The `src_y` used for all subsequent rowscroll/rowzoom indexing
is the colscroll-adjusted value.

**Critical pipeline ordering (section2 §2.2):**
```
// BG2/BG3 HBLANK setup, MUST execute in this order:
src_y_raw = y_index >> 16                          // 1. global Y accumulator
col_idx   = (vpos - y_offset) & 0x1FF             // 2. which colscroll entry
src_y     = (src_y_raw + colscroll_ram[col_idx]) & 0x1FF   // 3. COLSCROLL APPLIED
// src_y is now the colscroll-adjusted source row
row_idx   = src_y                                  // 4. row_idx uses colscroll-adjusted src_y
// (rowzoom lookup in Step 8 uses this same row_idx)
```

**Test cases:**
1. Write all BG2 colscroll entries to 0. Verify BG2 output identical to
   BG2 with colscroll disabled (regression baseline).
2. Write BG2 colscroll entry 50 = 32 (shifts column 50's source Y by +32 rows).
   Set BG2 scroll to 0. Verify that at output column 50, a tile from a different
   row appears vs columns 49 and 51 (which have colscroll=0).
3. Write a sinusoidal colscroll pattern (entries 0–239). Verify the wavy column
   effect across the screen.
4. BG3 colscroll independent from BG2 (different values, different effect).
5. flipscreen: verify colscroll column index is reversed (`0x1FF - col_idx`).
6. Colscroll with large offset (>511): verify 0x1FF mask wraps correctly.
7. **Colscroll-ordering proof test:** Write BG2 colscroll entry N = 64 (shifts row
   source by 64). Write rowscroll RAM so that the ROW AT POSITION `src_y_raw + 64`
   has a distinct X offset (not present at `src_y_raw`). Verify the rowscroll applied
   to output column N is the one from the COLSCROLL-ADJUSTED row — not from `src_y_raw`.
   This single test case proves the hardware ordering is correct. (See §3 for full
   description of this test.)
8. BG0/BG1 unaffected: verify BG0 and BG1 still produce correct output while BG2/BG3
   colscroll is active.

**Python model:** Extend BG2/BG3 path in `render_scanline()` with colscroll pre-adjustment
of src_y before rowzoom/rowscroll lookup.

**Expected test count:** 30–45 tests.

---

### Step 8 — BG2/BG3: Per-Row Zoom

**New capability:** BG2 and BG3 gain per-row zoom modulation. Row zoom is read from
the rowzoom RAM using the COLSCROLL-ADJUSTED `row_idx` (section2 §2.2). The per-row
zoom reduces `x_step` and adjusts the X origin, enabling road-perspective convergence.
Enable is controlled by `rowzoom_en[2]` and `rowzoom_en[3]` from LAYER_CTRL.

**Modules extended:** `tc0480scp_bg.sv` BG2/BG3 instances: add rowzoom RAM read
in HBLANK setup (after colscroll), compute `x_step = zoomx - (row_zoom_lo << 8)`,
apply x_origin adjustment.

**x_origin adjustment from section2 §2.2:**
```
x_index -= (x_offset - 0x1f + LAYER*4) * ((row_zoom & 0xFF) << 8)
```
Note: MAME documents this formula as "flawed" (approximate). Match MAME's formula
exactly, not hypothetical hardware behavior.

**Test cases:**
1. Set `rowzoom_en[2]` = 0. Write BG2 rowzoom RAM with non-zero values. Verify no
   effect (enable bit off → rowzoom RAM ignored, x_step = global zoomx).
2. Set `rowzoom_en[2]` = 1. Write BG2 rowzoom RAM: uniform value = 0x40 for all rows.
   Verify x_step = zoomx - (0x40 << 8) uniformly. Verify proportional horizontal
   compression (all rows shrink by same amount).
3. Rowzoom ramp: write rowzoom_ram[row] = row * 2 for rows 0–100 (increasing per-row zoom).
   Verify perspective convergence: rows near the horizon (large row_zoom) are compressed
   more than rows near the viewer (small row_zoom).
4. **Colscroll + rowzoom interaction test:** Write colscroll entry 60 = 100 (shifts
   column 60's effective row from row R to row R+100). Write rowzoom RAM such that
   row R has zoom=0 and row R+100 has zoom=0x60. Verify that at output column 60,
   x_step is derived from row R+100 (not row R) — confirming colscroll-before-rowzoom.
5. Row zoom hi byte (UndrFire path): write rowzoom entry with high byte set
   (`entry & 0xFF00` != 0). Verify only low byte `entry & 0xFF` is used for zoom
   (section1 §6 clarifies high byte handling).
6. `rowzoom_en[3]` enable/disable for BG3, independent of BG2.
7. Rowzoom with flipscreen: verify `row_idx = 0x1FF - src_y` reversal.

**Python model:** Add rowzoom to BG2/BG3 path. The colscroll-before-rowzoom ordering
must already be in place from Step 7 — this step only adds the x_step modification.

**Expected test count:** 35–50 tests.

---

### Step 9 — All Four BG Layers Together + GFX ROM Arbitration

**New capability:** All four BG layer instances active simultaneously. GFX ROM read
port arbitrated round-robin across BG0–BG3 during tile refills. VRAM scroll-RAM port
arbitrated round-robin across BG0–BG3 during HBLANK setup.

**Modules extended:** `tc0480scp.sv` top-level adds arbitration logic for GFX ROM
and VRAM ports. Colmix extended to full 4-BG + text compositing with dynamic
`bg_priority` order.

**Test cases:**
1. All four BG layers active, all with different tile patterns. Verify all four render
   simultaneously without pixel corruption (no port collision artifacts).
2. Priority order 0 (default 0x0123): BG3 top, BG0 bottom. Verify stacking.
3. Priority order 4 (0x3210): BG0 top, BG3 bottom. Verify stacking reverses.
4. Priority order 5 (0x2103, Gunbustr attract): verify layer 2 on top of layer 1 on
   top of layer 0 on top of layer 3.
5. Priority order change mid-frame: change LAYER_CTRL bits[4:2] during VBLANK. Verify
   new order applies to the next frame.
6. Text layer over all BG layers in all 8 priority orders. Verify text always wins.
7. GFX ROM bandwidth test: all four layers at 2× zoom (more tile refills per scanline).
   Verify no pixel output gaps or stalls (arbitration holds output until data ready).

**Python model:** Extend `render_scanline()` to composite all 5 layers using dynamic
priority order.

**Expected test count:** 35–50 tests.

---

### Step 10 — Double-Width Mode

**New capability:** LAYER_CTRL bit[7] switches all four BG layers from 32×32 to 64×32
tile maps. VRAM layout changes. `width_mask` changes from 0x1FF to 0x3FF. Slapshot
changes this register during gameplay, so the switch must take effect immediately
(combinational in the VRAM decoder).

**Modules extended:** `tc0480scp_regs.sv` already outputs `dblwidth`. `tc0480scp_vram.sv`
already has combinational decode. `tc0480scp_bg.sv` adds `width_mask` mux based on
`dblwidth`.

**Test cases:**
1. Standard mode (dblwidth=0): fill BG0 tile map positions 0–1023 (32×32 = 1024 entries).
   Verify tile at map position (31, 31) renders correctly.
2. Double-width mode (dblwidth=1): write BG0 tile map positions 0–2047 (64×32 = 2048
   entries, now at a different VRAM base). Verify tile at (33, 0) is accessible.
3. Set `width_mask = 0x3FF` in double-width: set BG0_XSCROLL so that source pixel 520
   is visible. Verify tile from column 32 (position 512/16=32) appears — not wrapped
   to column 0 as in standard mode.
4. In-play switch (Slapshot test): write several tiles in standard-mode layout. Switch
   `dblwidth` to 1. Verify the VRAM decoder immediately uses the new base (no stale
   decode from previous cycle). Verify no garbage output on the cycle of the switch.
5. Switch dblwidth back to 0: verify standard-mode tiles are again accessible.

**Python model:** Add dblwidth flag to tile map address computation.

**Expected test count:** 20–30 tests.

---

### Step 11 — Screen Flip

**New capability:** LAYER_CTRL bit[6] inverts X and Y for all five layers. Scroll signs
invert. Row and column indices reverse. Layer stagger offsets use flip-screen formulas.

**Modules extended:** `tc0480scp_regs.sv` already outputs `flipscreen`. `tc0480scp_bg.sv`
BG engines add flip-conditional sign/index inversions in HBLANK setup and Y accumulator
initialization. `tc0480scp_textlayer.sv` adds flip scroll.

**Test cases:**
1. Set `flipscreen` = 1. Write BG0 with a diagonal pattern. Verify output is
   point-reflected (both X and Y mirrored) vs `flipscreen`=0.
2. Flip + scroll: verify that the same scroll register value produces a visually
   equivalent scene in both flip orientations (the scroll sign inversion compensates).
3. Rowscroll with flip: verify the row index uses `0x1FF - src_y` reversal.
4. Colscroll with flip: verify the column index uses `0x1FF - col_idx` reversal.
5. Text layer flip: verify FG0 mirrors correctly.
6. Flip + double-width: verify combination works.
7. Flip + zoom: verify Y accumulator start formula uses the flip-screen variant
   from section2 §2.1 (`y_index` initializes to scan from bottom instead of top).

**Python model:** Add flipscreen branches to all layer rendering paths.

**Expected test count:** 30–45 tests.

---

### Step 12 — Output Interface + TC0360PRI Connection

**New capability:** `pixel_out[15:0]` finalized with priority tag bits appended for
TC0360PRI. GFX ROM SDRAM interface stubs replaced with proper SDRAM burst-read interface.
`tc0480scp.sv` top-level finalized with Quartus-compatible BRAM instantiation.

**Modules extended:** `tc0480scp_colmix.sv` adds priority tag encoding on pixel_out.
Top-level connects to TC0360PRI input port.

**Test cases:**
1. Verify pixel_out[15:0] format: for a BG3 pixel at color=0x5A, pen=7, priority=top,
   confirm the correct 16-bit value including any priority tag bits fed to TC0360PRI.
2. Transparent pixel output: all five layers transparent at some pixel position.
   Verify `pixel_out` = 0 (or background pen, per TC0360PRI convention).
3. Timing: verify pixel_valid_out is exactly in phase with pixel clock (no extra cycle
   latency vs `pixel_active`).

**Python model:** Add TC0360PRI output encoding to `render_scanline()`.

**Expected test count:** 15–20 tests.

---

### Step 13 — Full Frame Regression

**New capability:** All modules complete. Full frame comparison against MAME frame dumps
for Double Axle and Racing Beat. Verify correct rendering end-to-end.

**Modules:** No new modules. All stubs replaced.

**Test cases:**
1. Double Axle frame 0 (attract screen, standard layout): 320×240 pixel comparison.
   Target: >95% exact palette-index match. Remaining diffs expected to be PPU timing
   artifacts (scroll register latching phase vs MAME).
2. Double Axle frame 1 (first gameplay frame with rowscroll active on road layer).
3. Double Axle frame 2 (row zoom active on road perspective).
4. Racing Beat frame 0 (different game, same chip — verify no game-specific logic leaked
   into the implementation).
5. Colscroll+rowzoom frame: a frame from Gunbuster or Double Axle where BG2 colscroll
   and rowzoom are both active simultaneously. Verify the combined effect matches MAME.
6. Double-width mode frame: a Slapshot or Footchmp frame where dblwidth=1 is active.
7. All-8-priority-orders regression: run frames from Metalb that exercise each of the
   8 priority configurations. Verify each matches MAME output.
8. Full prior-step regression: re-run all tests from steps 1–12. Verify no regressions.

**Python model:** `render_frame()` — full 320×240 output, all layers composited.

**Expected test count:** Full suite from steps 1–12 (~400–600 tests) + 8 frame regressions.

---

## 3. Critical Path: Colscroll-Before-Rowzoom

### 3.1 What the ordering means

Section2 §2.2 states:

> "The column scroll occurs BEFORE the row zoom lookup — the source Y used to index
> the rowscroll/rowzoom RAM is the colscroll-adjusted source Y."

This is the central design constraint that distinguishes `bg23_draw` from `bg01_draw`.
Concretely: for a given output scanline (vpos = V), the pixel column X is being
rendered. The HBLANK setup for that scanline must:

1. Compute the **un-adjusted** source Y row: `src_y_raw = (y_index >> 16) & 0x1FF`
2. Look up colscroll for **output column position**, not source row:
   `col_idx = (V - y_offset) & 0x1FF` — this is derived from the OUTPUT scanline
   number, not from `src_y_raw`
3. Adjust source Y: `src_y = (src_y_raw + colscroll_ram[col_idx]) & 0x1FF`
4. Use `src_y` (not `src_y_raw`) as the index into rowscroll RAM and rowzoom RAM

If rowzoom were applied before colscroll, a different row's zoom value would be used —
the wrong per-row perspective would apply to each column.

### 3.2 RTL implementation

In `tc0480scp_bg.sv` HBLANK setup FSM for BG2/BG3, the state ordering is:

```
BG_HBLANK_S0: issue scram_rd for colscroll_ram[col_idx]
BG_HBLANK_S1: latch colscroll_q; compute src_y = (src_y_raw + colscroll_q) & 0x1FF
BG_HBLANK_S2: issue scram_rd for rowzoom_ram[src_y]        ← uses colscroll-adjusted src_y
BG_HBLANK_S3: latch rowzoom_q; compute x_step
BG_HBLANK_S4: issue scram_rd for rowscroll_hi_ram[src_y]   ← uses colscroll-adjusted src_y
BG_HBLANK_S5: latch rs_hi; issue scram_rd for rowscroll_lo_ram[src_y]
BG_HBLANK_S6: latch rs_lo; compute x_index_start
BG_READY: x_step and x_index_start are valid; begin pixel walk
```

States S2–S6 all use `src_y` (from S1), never `src_y_raw`. This serialization is
enforced by the FSM state machine — `rowzoom_ram` cannot be read until `src_y` is
valid from S1.

Total HBLANK reads per BG2/BG3 layer: 4 (colscroll + rowzoom + rs_hi + rs_lo).
At 112 HBLANK pixel clocks shared among 4 BG layers: 4 × 4 = 16 reads. With the
VRAM scroll port running every 4 cycles (round-robin), 16 reads × 4 cycles = 64
cycles, comfortably within 112.

### 3.3 Proof test (Step 7, Test 7)

The decisive test for correct ordering:

```python
# Setup:
# BG2 global scroll Y = 100 (src_y_raw = 100 for vpos=0 line)
# BG2 colscroll entry for output column 60 = 64
#   → src_y for column 60 = (100 + 64) & 0x1FF = 164
# rowscroll_hi for src_y=100 = 0 (no X shift)
# rowscroll_hi for src_y=164 = 32 (X shift by 32 pixels)
# rowzoom_ram for src_y=164 = 0x20 (moderate zoom)
#
# Expected at output column 60:
#   - x_index_start uses rowscroll from row 164 (= 32px offset)
#   - x_step uses rowzoom from row 164 (= 0x20 reduction)
#
# Wrong ordering (rowzoom before colscroll) would use row 100 for both:
#   - x_index_start uses rowscroll from row 100 (= 0, no offset)
#   - x_step uses rowzoom from row 100 (wrong zoom value)
#
# Test: verify that output column 60 has an X offset consistent with
# row 164's rowscroll (32 pixels) AND row 164's rowzoom.
```

This test requires inspecting per-pixel x_index values, not just final pixel output.
The testbench should expose internal `x_index_start` and `x_step` signals for BG2
at the HBLANK cycle for the scanline under test.

---

## 4. Reuse from TC0630FDP

### 4.1 From `tc0630fdp_bg.sv` → `tc0480scp_bg.sv`

The FDP BG engine (`tc0630fdp_bg.sv`, 579 lines at Step 16 completion) and the SCP BG
engine share the same fundamental structure: a per-scanline 5-state FSM, a 32-bit GFX
ROM fetch, a 320-entry line buffer, and a fractional X accumulator for zoom.

**Direct copy + adapt:**

| FDP pattern | SCP adaptation |
|---|---|
| `BG_IDLE → BG_ATTR → BG_CODE → BG_GFX0 → BG_GFX1 → BG_WRITE` FSM | Same 6 states + add `BG_HBLANK_S0..S6` pre-scanline setup states (new) |
| `zoom_step_fp = 0x100 + ls_zoom_x` X accumulator | Replace with SCP formula: `zoomx = 0x10000 - (bgzoom[15:8] << 8)`; accumulator is 32-bit not 16-bit |
| `canvas_y = (vpos+1 + yscroll_int) & 0x1FF` | Same — replace `ls_zoom_y` Y-scale with SCP Y accumulator (`y_index` increments per scanline) |
| `gfx_tile_base = tile_code * 32` (32 × 32-bit words per tile) | Same formula (section1 §8: 128 bytes/tile = 32 × 32-bit words). |
| `flipx` reverse nibble order in GFX word | Same: `bits[31:28]=px0` with flipX reversal |
| `flipy: fetch_py = flipY ? 15 - py : py` | Same row inversion |
| `linebuf[0:319]` 320 × 13-bit | Same size. Change from `{palette[8:0], pen[3:0]}` to `{color[7:0], pen[3:0]}` |
| `ls_colscroll` tile-column offset after zoom (FDP: shifts tile index) | SCP: colscroll shifts SOURCE ROW (Y), not tile column (X). Different axis — do not reuse directly. |
| `ls_pal_add` palette addition | FDP adds `(ls_pal_add / 16)` to palette. SCP has no palette addition — remove entirely. |
| `ls_rowscroll` per-scanline override from Line RAM | SCP: rowscroll from VRAM scroll RAM, indexed by colscroll-adjusted src_y. Replace Line RAM read with VRAM scram port read. |

**Key structural difference:** FDP Line RAM (`tc0630fdp_lineram.sv`) does all
per-scanline parameter delivery in a dedicated module. SCP has no Line RAM — BG engines
read their scroll/zoom/colscroll values directly from VRAM (the scroll RAM is a
sub-region of the main VRAM BRAM). The HBLANK setup FSM in `tc0480scp_bg.sv` therefore
owns the VRAM reads that would otherwise come from a Line RAM output. This collapses
two modules (lineram + tilemap) into one per SCP layer.

**Also absent in SCP:** No alt-tilemap, no palette addition, no per-scanline blend
mode, no clip planes. These 4 FDP features are ~80 lines each; removing them simplifies
the SCP engine considerably.

**Estimated reuse:** Starting from `tc0630fdp_bg.sv` (579 lines), removing FDP-specific
features saves ~200 lines, rewriting Y accumulator from 8-bit zoom to 32-bit fixed-point
adds ~60 lines, adding the 7-state HBLANK setup FSM (colscroll + rowzoom + rowscroll)
adds ~100 lines, adapting for direct VRAM reads instead of Line RAM outputs adds ~40 lines.
Estimated `tc0480scp_bg.sv` size: ~580 lines. Reuse percentage: **~55%**.

### 4.2 From `tc0630fdp_lineram.sv` → `tc0480scp_vram.sv`

The FDP Line RAM module (`tc0630fdp_lineram.sv`, 519 lines) provides the dual-port BRAM
pattern, CPU r/w port, and read-port arbitration. SCP VRAM has identical plumbing:
dual-port 16-bit BRAM, CPU writes, tile-fetch reads, scroll-RAM reads.

**Direct copy + adapt:**

| FDP pattern | SCP adaptation |
|---|---|
| `altsyncram` M10K 32K×16 dual-port instantiation | Same primitive, same parameters (SCP VRAM is also 32K×16 = 64KB) |
| CPU port A: `cpu_cs/cpu_we/cpu_addr/cpu_din/cpu_be` | Copy verbatim |
| Port B read arbitration: hblank_fall-triggered parser state | Replace parser with simple 2-priority mux: tf_addr (tile fetch) vs sc_addr (scroll read). No complex Line RAM section decoding. |
| `cpu_dout` MUX (registers output when `cpu_cs` + `!cpu_we`) | Copy verbatim |

The Line RAM section parser (the large state machine that reads all 17 sections on each
HBLANK, ~250 lines) has no equivalent in SCP — the BG engines read directly. This reduces
the adapted module from 519 lines to approximately 180 lines. **Reuse: ~35% of lines**,
but the BRAM instantiation pattern (the technically hardest part for Quartus synthesis)
is copied verbatim.

### 4.3 From `tc0630fdp_colmix.sv` → `tc0480scp_colmix.sv`

FDP colmix is complex (clip planes, alpha blend, dual-nibble priority buffer, ~400 lines).
SCP colmix is simple: no clip, no blend, 5-layer priority mux. Reuse is limited to the
priority-mux skeleton and transparent-pen checking.

**Reuse:** Priority mux loop structure (~40 lines), transparent pen check per layer
(~20 lines), pixel_valid timing (~15 lines). All clip, blend, and alpha pipeline logic
is removed. **Estimated SCP colmix: ~80 lines. Reuse: ~20% structurally.**

### 4.4 Summary

| SCP module | Source | Est. lines | Est. reuse % |
|---|---|---|---|
| `tc0480scp_regs.sv` | New (FDP ctrl.sv structure reference) | ~120 | 30% |
| `tc0480scp_vram.sv` | `tc0630fdp_lineram.sv` BRAM section | ~180 | 35% |
| `tc0480scp_bg.sv` | `tc0630fdp_bg.sv` | ~580 | 55% |
| `tc0480scp_textlayer.sv` | `tc0630fdp_text.sv` | ~150 | 60% |
| `tc0480scp_colmix.sv` | `tc0630fdp_colmix.sv` skeleton | ~80 | 20% |
| `tc0480scp.sv` (top) | `tc0630fdp.sv` top-level pattern | ~200 | 40% |
| **Total** | | **~1310 lines** | **~45% overall** |

---

## 5. File Structure

```
chips/tc0480scp/
  section1_registers.md
  section2_behavior.md
  section3_rtl_plan.md     ← this document

  rtl/
    tc0480scp.sv              top-level integrator: CPU bus, BRAM instantiation,
                              port arbitration, TC0360PRI output
    tc0480scp_regs.sv         24 × 16-bit control register bank + scroll/zoom decode
    tc0480scp_vram.sv         64KB dual-port VRAM BRAM + CPU r/w + tile/scroll read ports
    tc0480scp_bg.sv           BG0–BG3 tilemap engine (parameterized LAYER=0..3):
                              y_index accumulator, colscroll, rowzoom, rowscroll,
                              zoom X accumulator, GFX ROM tile cache, line buffer
    tc0480scp_textlayer.sv    FG0 text layer: 64×64 8×8 tiles, CPU gfx, global scroll
    tc0480scp_colmix.sv       5-layer compositor: dynamic priority, transparent pen,
                              TC0360PRI output encoding

  vectors/
    tb_tc0480scp.cpp          Verilator C++ testbench (same pattern as tb_tc0630fdp.cpp)
    scp_model.py              Python behavioral model:
                                TC0480SCPModel.write_ctrl()
                                TC0480SCPModel.write_ram()
                                TC0480SCPModel.read_ram()
                                TC0480SCPModel.load_gfx_rom()
                                TC0480SCPModel.render_scanline(y) → [320 pixels]
                                TC0480SCPModel.render_frame()    → [[pixels]]
    generate_vectors.py       Vector generator script
    Makefile                  Verilator build (same structure as tc0630fdp Makefile)
    games/
      dblaxle_frame0.bin      MAME frame dump for Step 13 regression (Double Axle)
      dblaxle_frame1.bin
      dblaxle_frame2.bin
      racingb_frame0.bin
      gunbstr_frame0.bin      Gunbuster — exercises colscroll+rowzoom simultaneously
      slapshot_frame0.bin     Slapshot — exercises mid-frame dblwidth switch
```

---

## 6. TC0480SCP Port Interface (External-Facing)

Complete port list for `tc0480scp.sv` as seen by the Taito Z system:

```systemverilog
module tc0480scp (
    input  logic        clk,               // pixel clock (6.6715 MHz from 26.686/4)
    input  logic        rst_n,

    // ── 68000 CPU bus (primary CPU A) ─────────────────────────────────────
    // VRAM window: chip-relative 0x0000–0xFFFF (64KB, word-granular)
    input  logic        vram_cs,
    input  logic        vram_we,
    input  logic [15:1] vram_addr,         // word address within 64KB VRAM
    input  logic [15:0] vram_din,
    input  logic [ 1:0] vram_be,           // byte enables
    output logic [15:0] vram_dout,

    // Control register window: chip-relative 0x00–0x2F (0x18 × 16-bit words)
    input  logic        ctrl_cs,
    input  logic        ctrl_we,
    input  logic [ 4:1] ctrl_addr,         // word index 0–23
    input  logic [15:0] ctrl_din,
    input  logic [ 1:0] ctrl_be,
    output logic [15:0] ctrl_dout,

    // ── Video timing (from board timing generator) ─────────────────────────
    input  logic        hsync_n,           // active-low HSYNC
    input  logic        hblank_n,          // active-low HBLANK
    input  logic        vsync_n,           // active-low VSYNC
    input  logic        vblank_n,          // active-low VBLANK
    input  logic [ 9:0] hpos,             // horizontal pixel counter 0–423
    input  logic [ 8:0] vpos,             // vertical line counter 0–261

    // ── GFX ROM (32-bit bus, from SDRAM via MiSTer ROM loader) ────────────
    input  logic [31:0] gfx_data,          // 32-bit ROM read data
    output logic [20:0] gfx_addr,          // byte address >> 2 (word-addressed)
    output logic        gfx_rd,            // read strobe (one-cycle pulse)
    input  logic        gfx_ack,           // SDRAM read-data valid

    // ── Pixel output → TC0360PRI ──────────────────────────────────────────
    output logic [15:0] pixel_out,         // 16-bit palette index + priority tag
    output logic        pixel_valid        // 1 during visible pixel window
);
```

**Notes on port decisions:**

- `hpos`/`vpos` are driven externally by the shared Taito Z timing generator. TC0480SCP
  does not generate its own timing counters — it consumes them. (Same pattern as TC0630FDP.)
- `gfx_addr` is a 21-bit word address (byte address >> 2) matching the CH0–CH20 ROM bus
  from section1 §1. The 21st bit addresses up to 0x1FFFFF × 4 bytes = 8MB ROM.
- `gfx_ack` handles SDRAM latency: the BG engine issues `gfx_rd` and waits for `gfx_ack`
  before consuming `gfx_data` (the tile cache state machine stalls until ack arrives).
- No interrupt outputs: TC0480SCP does not generate CPU interrupts (those come from the
  main 68000 timing logic on the Taito Z board, not from this chip).
- `pixel_out` feeds TC0360PRI directly. The upper bits encode a 2-bit priority tag derived
  from the layer's position in the current priority order (`bg_priority`). Text layer always
  outputs the highest priority tag.

---

## 7. Summary

**Total estimated steps:** 13

**Step to start with:** Step 1 — Skeleton + Control Register Bank. Zero dependencies.
Establishes pixel-clock domain, verifies test infrastructure (Verilator + Python model
API + vector format), and validates the stagger/negate/LUT decode logic for all 24
control registers before any VRAM or rendering logic exists.

**First test case (Step 1, Test 1):**
```python
# scp_model.py
model = TC0480SCPModel()
model.write_ctrl(0, 0x0010)                # BG0_XSCROLL = 0x0010
assert model.bgscrollx[0] == -0x0010      # negated (no stagger on BG0)

# tb_tc0480scp.cpp
dut.ctrl_cs   = 1; dut.ctrl_we = 1;
dut.ctrl_addr = 0;                         // word 0 = BG0_XSCROLL
dut.ctrl_din  = 0x0010;
dut.ctrl_be   = 2'b11;
tick();
dut.ctrl_we = 0;
tick();
assert(dut.bgscrollx[0] == 16'hFFF0);     // -0x0010 in 16-bit 2's complement
```

**Hardest step:** Step 8 — BG2/BG3 Per-Row Zoom. Not because the formula is complex,
but because it requires Step 7 (colscroll) to be correct first, and the HBLANK setup
FSM must correctly sequence colscroll → rowzoom → rowscroll in 7 states within the
VRAM port time-share budget. The x_origin adjustment formula is documented as "flawed"
in MAME — matching MAME's exact approximation (rather than guessing the real hardware
behavior) requires using MAME source as the ground truth. The test at Step 8 Test 4
(colscroll + rowzoom interaction) will require internal signal inspection to verify
the ordering and is the single most diagnostic test in the plan.

**Second hardest step:** Step 10 — Double-Width Mode mid-frame switch. The Slapshot
case (switching `dblwidth` during active display) is a combinational path that cuts
across the VRAM address decoder. Any registered path here causes a one-cycle glitch.

**BRAM budget (all steps complete):**

| Resource | Size | On-chip M10K |
|---|---|---|
| VRAM (all sub-regions) | 64KB = 32K×16 | ~16 M10K |
| Tile row cache (4 BG layers × 2 rows × 64 bits) | ~64 bytes | < 1 M10K (registers) |
| Line buffers (4 BG + 1 text × 320 × 13-bit) | ~1KB total | 1 M10K |
| Control registers | 24 × 16-bit | Registers (no BRAM) |
| **Total on-chip** | | **~18 M10K** |

GFX ROM (1–4 MB) lives in SDRAM. The SCP design is dramatically lighter on-chip than
FDP (which needed ~273 M10K) — TC0480SCP's simplicity (no Line RAM, no sprite engine,
no alpha blend) means the Cyclone V's 397 M10K budget is barely touched.

**GFX ROM bandwidth:** At 320 output pixels per scanline, 1:1 zoom → 20 tiles per
layer per scanline → 20 × 1 GFX fetch = 20 SDRAM reads per layer. With 4 layers
round-robin: 80 SDRAM reads per scanline. At 6.6715 MHz pixel clock, 424 pixel-clocks
per scanline, SDRAM reads every 5 cycles on average — achievable with a standard
MiSTer SDRAM controller burst configuration. At maximum zoom-out (2× compression,
~40 tiles per layer), the budget doubles to ~160 reads per scanline, requiring
every ~2.6 cycles — at the edge of SDRAM bandwidth. Buffer 2 tiles ahead per layer
(prefetch) to prevent stalls.
