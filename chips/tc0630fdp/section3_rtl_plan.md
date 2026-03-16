# TC0630FDP — Section 3: RTL Build Plan

**Source documents:** section1_registers.md (register map), section2_behavior.md (behavioral
description, 13-step build order), TC0180VCU section2_behavior.md + rtl/ (methodology template)
**Complexity:** Tier-4 (maximum in this pipeline — 6 layers, per-scanline zoom on 4 PFs,
alpha blend, 4 clip planes, 17-bit sprite tiles, pivot/affine layer)

---

## 1. Module Decomposition

Seven SystemVerilog modules + one top-level integrator. Each module maps to exactly one
behavioral section from section2_behavior.md §6.

---

### 1.1 `tc0630fdp_ctrl.sv` — Display Control Register Bank

**Role:** Holds the 16 × 16-bit display control registers (0x660000–0x66001F) and decodes
them into named outputs consumed by all other modules.

**Ports:**
```
Inputs:
  clk, rst_n
  cpu_cs, cpu_we, cpu_addr[4:0], cpu_din[15:0], cpu_be[1:0]  // 68EC020 bus
Outputs:
  cpu_dout[15:0]
  pf_xscroll[4][15:0]   // PF1–PF4 X scroll (raw 10.6 fixed-point, inverted frac)
  pf_yscroll[4][15:0]   // PF1–PF4 Y scroll (raw 9.7 fixed-point)
  pixel_xscroll[15:0]   // Pixel/VRAM layer X scroll
  pixel_yscroll[15:0]   // Pixel/VRAM layer Y scroll
  extend_mode           // 1 = 64×32 tilemap (1024px wide), 0 = 32×32 (512px)
```

**Internal state:** `ctrl[0:15]` — 16 × 16-bit register array.

**Dependencies:** None. Pure register file; no submodule calls.

**Key decode logic:**
- `pf_xscroll[n]` = `ctrl[n]` (words 0–3 for PF1–PF4)
- `pf_yscroll[n]` = `ctrl[4+n]` (words 4–7)
- `pixel_xscroll` = `ctrl[12]`, `pixel_yscroll` = `ctrl[13]`
- `extend_mode`   = `ctrl[15][7]`

---

### 1.2 `tc0630fdp_lineram.sv` — Line RAM Parser and Per-Scanline Distributor

**Role:** The Line RAM (64KB, twelve sections) is the central per-scanline control store
for the entire chip. This module owns the Line RAM BRAM, handles CPU r/w, and presents
fully-decoded per-scanline structs to every other module one scanline ahead of rendering.

**Ports:**
```
Inputs:
  clk, rst_n
  cpu_cs, cpu_we, cpu_addr[15:0], cpu_din[15:0], cpu_be[1:0]
  vpos[7:0]              // current visible scanline (from timing)
  hblank_fall            // trigger: parse next scanline's data
Outputs:
  cpu_dout[15:0]
  // Per-scanline outputs (registered at hblank_fall, valid for scanline vpos+1):
  ls_rowscroll[4][15:0]  // PF1–PF4 rowscroll (§9.11)
  ls_colscroll[4][8:0]   // PF1–PF4 column scroll offset (§9.2)
  ls_alt_tilemap[4]      // PF3/PF4 alt-tilemap flag (§9.2 bit9)
  ls_zoom_x[4][7:0]      // PF1–PF4 X zoom (§9.9)
  ls_zoom_y[4][7:0]      // PF1–PF4 Y zoom (§9.9, corrected for PF2/PF4 swap)
  ls_pal_add[4][15:0]    // PF1–PF4 palette addition offset (§9.10)
  ls_clip[4][15:0]       // clip plane left/right bounds, 4 planes (§9.3)
  ls_pf_prio[4][3:0]     // PF1–PF4 priority 0–15 (§9.12 bits[3:0])
  ls_pf_blend[4][1:0]    // PF1–PF4 blend mode A/B (§9.12 bits[15:14])
  ls_pf_clip_en[4][3:0]  // PF1–PF4 clip plane enable mask (§9.12 bits[11:8])
  ls_pf_clip_inv[4][3:0] // PF1–PF4 clip invert per plane (§9.12 bits[7:4])
  ls_spr_prio[4][3:0]    // sprite priority groups 0x00/0x40/0x80/0xC0 (§9.8)
  ls_spr_blend[4][1:0]   // sprite blend per priority group (§9.4 bits[7:0])
  ls_alpha_a[3:0]        // A_src, A_dst alpha factors (§9.5)
  ls_alpha_b[3:0]        // B_src, B_dst alpha factors (§9.5)
  ls_mosaic_rate[3:0]    // mosaic X rate (§9.6)
  ls_mosaic_en[5:0]      // mosaic enable per layer (§9.6)
  ls_pivot_en            // pivot layer enable (§9.4 bit5)
  ls_pivot_bank          // pivot bank select (§9.4 bit6)
  ls_pivot_blend         // pivot blend A/B select (§9.4 bit0)
```

**Internal state:**
- `line_ram[0:32767]` — 32K × 16-bit BRAM (64KB). Single write port (CPU), single read
  port (parser FSM). In simulation: flat array. In Quartus: `altsyncram` M10K.
- Parser registers: one register per output field, loaded at `hblank_fall` from
  the parsed scanline index `vpos+1`.

**Dependencies:** Timing signals from top-level. All other modules consume its outputs.

**Critical implementation note — PF2/PF4 zoom swap:**
The hardware physically swaps the Line RAM storage addresses for PF2 and PF4 Y-zoom.
MAME corrects this in the read path. This module must apply the same correction:
when reading Y-zoom for PF2, read from the PF4 address range (0x8600), and vice versa.
See section1_registers.md §9.9: "PF2 and PF4 Y-zoom entries are physically swapped."

**Critical implementation note — enable latch section:**
The upper half of Line RAM (0x0000–0x3FFF) contains enable/latch bitfields that select
which per-scanline sections are active for each playfield. The parser must AND these
enable bits against the data sections before outputting. This determines whether, for
example, rowscroll is active for PF1 on a given scanline (section1 §9.1).

---

### 1.3 `tc0630fdp_tilemap.sv` — PF1–PF4 Tilemap Engines (4 instances)

**Role:** One instance per playfield. Fills a 320-pixel line buffer during HBLANK for
the next scanline, applying rowscroll, zoom, colscroll, palette addition, and alt-tilemap.

**Ports (parameterized by `PF_NUM` 0–3):**
```
Inputs:
  clk, rst_n
  hblank_fall, vpos[7:0], hpos[9:0]
  start                        // pulse from top-level sequencer
  // PF RAM read port (async)
  pf_rd_addr[12:0], pf_q[15:0]
  // GFX ROM read port (byte-wide, async in simulation, SDRAM in synthesis)
  gfx_lo_addr[24:0], gfx_lo_data[7:0], gfx_lo_rd
  gfx_hi_addr[24:0], gfx_hi_data[7:0], gfx_hi_rd   // for 5/6bpp tiles
  // Per-scanline Line RAM outputs from tc0630fdp_lineram
  pf_xscroll[15:0]             // global scroll (from ctrl, adjusted by rowscroll)
  pf_yscroll[15:0]             // global Y scroll
  ls_rowscroll[15:0]           // Line RAM rowscroll override for this PF
  ls_zoom_x[7:0], ls_zoom_y[7:0]
  ls_colscroll[8:0]
  ls_pal_add[15:0]
  ls_alt_tilemap                // select +0x2000 offset in PF RAM (PF3/PF4 only)
  extend_mode                  // 0=32-wide, 1=64-wide map
Outputs:
  // Line buffer async read port (consumed by colmix during active display)
  layer_pixel[15:0]           // {priority[3:0], blend[1:0], palette[8:0], pen[5:0]}
                              // pen==0 => transparent
```

**Internal state:**
- `linebuf[0:319]` — 320 × 20-bit line buffer (ping-pong not needed; filled during HBLANK,
  read during next active scan — single buffer suffices since fill completes before read starts).
- FSM states: `TM_IDLE → TM_INIT → TM_CODE → TM_ATTR → TM_GFX_LO0..3 → TM_GFX_HI0..1 →
  TM_WRITE → next tile / TM_IDLE`
- Tile fetch registers: `tile_code_r[15:0]`, `palette_r[8:0]`, `blend_r`, `extra_planes_r[1:0]`,
  `flipx_r`, `flipy_r`
- Zoom accumulator: `zoom_acc[15:0]` — 16.0 fixed-point accumulator that maps output pixel X
  to source tilemap X. Reset at scanline start. Incremented by `zoom_step` per output pixel
  (computed from `ls_zoom_x`).
- 6bpp decode buffer: 4 bytes lo-plane + 2 bytes hi-plane → 8 pixels per 8-pixel half.

**Dependencies:** tc0630fdp_lineram outputs, tc0630fdp_ctrl for global scroll and extend_mode.

**Key implementation differences from TC0180VCU `tc0180vcu_bg.sv`:**
1. **16×16 tiles** (same as VCU) but 4/5/6bpp instead of always 4bpp. The FSM adds
   `TM_GFX_HI0..1` states for the 2-bit hi-plane ROM when `extra_planes != 0`.
2. **Rowscroll:** effective_x = global_xscroll + ls_rowscroll (per scanline), replacing VCU's
   per-block scroll block computation. The VCU lpb divider logic is not needed.
3. **Horizontal zoom:** A fractional X accumulator replaces the simple tile-column counter.
   At each tile boundary, compute `map_x = zoom_acc >> zoom_shift` to get the source map X.
4. **Alt-tilemap:** When `ls_alt_tilemap` is set (PF3/PF4 only), add 0x1800 (word offset) to
   the PF RAM base address before tile fetch.
5. **Palette OR decode:** `final_color = (palette << 4) | pen | (extra_planes << 4)` — note
   bitwise OR, not add. This is the PR #11788 correction from section1 §4.
6. **Map geometry:** In extend_mode, map width = 64 tiles × 16px = 1024px; otherwise 32 tiles.
   The tile address formula changes: `tile_addr = tile_y * map_width + tile_x`.

---

### 1.4 `tc0630fdp_text.sv` — Text (VRAM) Layer Engine

**Role:** Renders the 64×64 8×8 tile text layer from CPU-writable Character RAM. No global
scroll. Fills a 320-pixel line buffer during HBLANK.

**Ports:**
```
Inputs:
  clk, rst_n
  hblank_fall, vpos[7:0], hpos[9:0]
  start
  // Text RAM read port (64×64 = 4096 tiles, one 16-bit word each)
  text_rd_addr[11:0], text_q[15:0]
  // Character RAM (256 tiles × 32 bytes each = 8KB, directly readable)
  char_rd_addr[12:0], char_q[7:0]
Outputs:
  text_pixel[12:0]   // {color[4:0], pen[3:0], dirty_flag}  pen==0 => transparent
```

**Internal state:**
- `linebuf[0:319]` — 320 × 9-bit (color[4:0] + pen[3:0])
- Dirty tile bitmap: `char_dirty[0:255]` — set when CPU writes Character RAM, cleared after
  line buffer fill that used the tile. In RTL this simplifies to: always re-read Character RAM
  directly (no tile caching needed since Character RAM is on-chip BRAM accessible same cycle
  as a tile fetch cycle).
- FSM: `TX_IDLE → TX_INIT → TX_CODE → (TX_PIX0..TX_PIX3 for left 8px) →
  (TX_PIX4..TX_PIX7 for right 8px) → TX_WRITE → next tile / TX_IDLE`
  Each 8-pixel half of an 8×8 tile requires 4 ROM reads (4 planes × 1 byte each, packed format
  per charlayout §11.1: planes 0–3 interleaved at known bit offsets).

**Dependencies:** No Line RAM (text layer has no per-scanline scroll or effects).

**Reuse from VCU:** The TX tilemap module `tc0180vcu_tx.sv` provides the structural template:
fixed-position tile fetch, 8×8 tile geometry, 4bpp decode. The main additions are the
charlayout bit-unpacking (X/Y offsets per §11.1 are non-trivial: `{20,16,28,24,4,0,12,8}`)
and the wider color field (5 bits vs VCU's 4).

---

### 1.5 `tc0630fdp_pivot.sv` — Pivot (Pixel/Affine) Layer Engine

**Role:** Renders the 64×32 column-major 8×8 tile pivot layer from CPU-writable Pivot RAM.
Per-scanline enable, bank select, and blend mode from Line RAM §9.4. This is the "affine"
layer used for rotating/scaling backgrounds (Darius Gaiden lens, Gekirindan planet).

**Ports:**
```
Inputs:
  clk, rst_n
  hblank_fall, vpos[7:0], hpos[9:0]
  start
  // Pivot RAM read port (64×32 column-major tiles, 32 bytes each)
  pivot_rd_addr[12:0], pivot_q[7:0]
  // Per-scanline Line RAM outputs
  ls_pivot_en, ls_pivot_bank, ls_pivot_blend
  pixel_xscroll[15:0], pixel_yscroll[15:0]  // from ctrl regs
Outputs:
  pivot_pixel[9:0]   // {blend_sel, bank, pen[3:0], color[3:0]}  pen==0 => transparent
```

**Internal state:**
- `linebuf[0:319]` — 320 × 10-bit
- Column-major address conversion: tile at (col, row) in the 64×32 canvas maps to Pivot RAM
  word index `col * 32 + row`. This is the scan order difference vs all other layers
  (section1 §7: TILEMAP_SCAN_COLS).
- No affine transform is implemented by the hardware itself at the tile-fetch level —
  the "pivot" name refers to the layer's role as a rotatable pixel canvas driven by the CPU
  writing rotated pixel data into Pivot RAM. The layer engine simply reads and renders tiles;
  the CPU is responsible for pre-computing the rotation.

**Dependencies:** tc0630fdp_lineram for enable/bank/blend. tc0630fdp_ctrl for scroll.

**Critical note on "pivot/affine":** Despite the name, this module does NOT perform affine
math. It is a standard scanline tile renderer with column-major addressing. The CPU prepares
the rotated content and stores it in Pivot RAM each frame. The FPGA just reads it back.
This dramatically simplifies implementation — no matrix multiply, no fixed-point trig.

---

### 1.6 `tc0630fdp_sprite.sv` — Sprite Scanner and Line Buffer Renderer

Two sub-modules: a VBLANK scanner that builds per-scanline lists, and an HBLANK renderer
that fills line buffers from those lists.

#### 1.6a `tc0630fdp_sprite_scan.sv` — VBLANK Sprite Walker

**Role:** During VBLANK, walks 64KB Sprite RAM (up to 4096 entries × 16 bytes), decodes
all fields including jump, command mode, and multi-tile blocks, and builds a per-scanline
active-sprite list.

**Ports:**
```
Inputs:
  clk, rst_n
  vblank_fall             // trigger to start walk
  spr_rd_addr[12:0], spr_q[15:0]   // sprite RAM async read
Outputs:
  // Per-scanline sprite lists (written during VBLANK, consumed during HBLANK)
  slist_wr, slist_addr[17:0], slist_data[63:0]   // write to per-scanline FIFO BRAM
```

**Internal state:**
- `sprite_idx[11:0]` — current sprite entry (0–4095, walked 0 to end)
- Jump state machine: when Word6[15] set, `sprite_idx` jumps to `Word6[9:0]`
- Block group machine: `in_block`, `block_x_no`, `block_y_no`, `block_anchor_*` latches
  (mirrors TC0180VCU sprite engine's `bs_*` state)
- Per-scanline sprite list BRAM: `slist[232][64]` — up to 64 sprite entries per scanline,
  each entry 64 bits: `{tile_code[16:0], sx[11:0], sy[11:0], x_zoom[7:0], y_zoom[7:0],
  palette[7:0], priority[1:0], flipx, flipy, extra_planes[1:0]}`

**Key difference from TC0180VCU sprite scanner:**
The VCU walks 408 sprites with 8 words each. F3 walks up to 4096 sprites with 8 words each
(Word6 jump + Word3[15] command mode). The jump mechanism means the walk is not linear —
the index can teleport anywhere in the 4096-entry space. The block group mechanism is
structurally identical to VCU `bs_*` state (direct reuse of the `bs_pos_calc` combinational
block, with the zoom formula `(n * (0xFF - zoom) + 15) >> 4`).

#### 1.6b `tc0630fdp_sprite_render.sv` — Per-Scanline Line Buffer Renderer

**Role:** During HBLANK, reads the active-sprite list for scanline `vpos+1` and renders
all active sprites into the dual line buffers using a zoom accumulator.

**Ports:**
```
Inputs:
  clk, rst_n
  hblank_fall, vpos[7:0]
  // Per-scanline sprite list (from sprite_scan BRAM)
  slist_count[5:0]         // number of active sprites for this scanline
  slist_entry[63:0]        // sprite entry from list BRAM
  // GFX ROM (17-bit tile code → up to 128K tiles × 128 bytes = 16MB)
  gfx_lo_addr[24:0], gfx_lo_data[7:0], gfx_lo_rd
  gfx_hi_addr[24:0], gfx_hi_data[7:0], gfx_hi_rd
Outputs:
  // Dual line buffers (ping-pong)
  spr_pixel[hpos: 9:0]  // {priority[1:0], palette[5:0], pen[5:0]}  pen==0 transparent
```

**Internal state:**
- `linebuf_a[0:319]`, `linebuf_b[0:319]` — 320 × 14-bit dual line buffers (ping-pong)
- `render_buf` — which buffer is being written (active back buffer)
- `disp_buf`   — which buffer is being read (front buffer for compositor)
- Zoom row/column accumulators: same src_x/src_y calculation as VCU sprite engine

**Dual line buffer note:** F3 sprite rendering is more demanding than VCU because sprites
are rendered per-scanline (not per-frame into a framebuffer). The ping-pong arrangement
— render scanline N into back buffer during HBLANK N, display front buffer during active
scan N — is the same pattern used in the VCU but applied per-scanline instead of per-frame.

---

### 1.7 `tc0630fdp_colmix.sv` — Layer Compositor: Clip, Priority, Alpha Blend, Output

**Role:** The most complex module. During active display, for each pixel evaluates all 6
layer line buffers, applies 4 clip planes, resolves priority, and applies alpha blending
per the 128-case `dpix_n` dispatch table.

**Ports:**
```
Inputs:
  clk, rst_n
  hpos[9:0], vpos[7:0]
  pixel_valid              // hblank_n & vblank_n
  // Layer pixel streams (one per layer, sampled at hpos)
  pf_pixel[4][19:0]        // {prio[3:0], blend[1:0], palette[8:0], pen[5:0]} × 4 PFs
  text_pixel[8:0]          // {color[4:0], pen[3:0]}
  pivot_pixel[9:0]         // {blend_sel, bank, pen[3:0], color[3:0]}
  spr_pixel[13:0]          // {prio[1:0], palette[5:0], pen[5:0]}
  // Per-scanline Line RAM compositor controls
  ls_clip[4][15:0]         // 4 clip plane left/right bounds
  ls_pf_prio[4][3:0]       // PF priority values 0–15
  ls_pf_blend[4][1:0]      // PF blend mode
  ls_pf_clip_en[4][3:0]    // PF clip plane enables
  ls_pf_clip_inv[4][3:0]   // PF clip invert
  ls_spr_prio[4][3:0]      // sprite priority groups
  ls_spr_blend[4][1:0]     // sprite blend
  ls_alpha_a[7:0]          // A_src[3:0], A_dst[3:0]
  ls_alpha_b[7:0]          // B_src[3:0], B_dst[3:0]
  ls_mosaic_rate[3:0]
  ls_mosaic_en[5:0]
  // Palette RAM read port (color index → RGB lookup)
  pal_addr[14:0], pal_data[15:0]
Outputs:
  pal_rd_addr[14:0]
  rgb_out[23:0]            // 24-bit RGB to TC0650FDA DAC
  pixel_valid_out
```

**Internal state:**
- `pri_buf[0:319]` — 320 × 8-bit priority buffer: upper nibble = src_prio, lower = dst_prio
  (the dual-nibble scheme from section2 §5.2)
- `out_buf[0:319]` — 320 × 15-bit output buffer: palette index per pixel
- `blend_buf[0:319]` — 320 × 2-bit blend mode per pixel (for second-pass alpha accumulation)
- Alpha blend pipeline: 3-stage registered pipeline (saturating multiply-add):
  Stage 1: select coefficients (A_src/A_dst or B_src/B_dst based on blend mode)
  Stage 2: compute `src * coeff / 8` and `dst * coeff / 8` (8-bit × 4-bit = 12-bit products)
  Stage 3: saturating add of two 8-bit values per channel

**Dependencies:** All other modules. This is the final compositing stage.

**Critical: clip plane evaluation per pixel:**
For each pixel at hpos = x, for each layer L:
```
in_window = true
for plane p in 0..3:
    if clip_en[L][p]:
        left  = clip[p].left  (9-bit, from §9.3 + §9.2 high bits)
        right = clip[p].right (9-bit)
        inside = (x >= left) && (x <= right)
        if clip_inv[L][p]: inside = !inside
        in_window = in_window && inside
```
This is 4 comparisons per layer per pixel = 24 comparisons per pixel for 6 layers.
Implement as a 4-wide AND tree, one per layer, clocked one cycle ahead of pixel output.

**Critical: priority resolution:**
Maintain two 4-bit priority tracking values per pixel, updated as each layer is evaluated.
Use the dual-nibble `pri_buf` exactly as described in section2 §5.2.

---

### 1.8 `tc0630fdp.sv` — Top-Level Integrator

**Role:** Instantiates all 7 modules, owns all BRAM instantiations, arbitrates GFX ROM
access, generates timing signals, routes CPU bus, generates interrupt outputs.

**Ports (external-facing chip interface):**
```
Inputs:
  clk, async_rst_n
  // 68EC020 CPU bus (32-bit longword access to 0x600000–0x63FFFF + 0x660000–0x66001F)
  cpu_cs, cpu_we, cpu_addr[18:1], cpu_din[31:0], cpu_be[3:0]
  // Video timing (from external timing generator)
  hblank_n, vblank_n, hpos[9:0], vpos[7:0]
  // GFX ROM (SDRAM)
  gfx_lo_data[7:0], gfx_hi_data[7:0]
  // Palette RAM data (from TC0650FDA read-back, or internal)
  pal_data[15:0]
Outputs:
  cpu_dout[31:0]
  int_vblank, int_hblank     // VBLANK (INT2) and pseudo-hblank (INT3)
  gfx_lo_addr[24:0], gfx_lo_rd
  gfx_hi_addr[24:0], gfx_hi_rd
  pal_addr[14:0], pal_rd
  rgb_out[23:0]
  pixel_valid
```

**HBLANK sequencing (critical — same pattern as TC0180VCU top-level):**
The VCU uses a cycle counter (`hblank_cyc`) to sequence TX → BG → FG renders.
F3 requires sequencing: Text → PF1 → PF2 → PF3 → PF4 → Pivot → Sprite Render.

At 6.6715 MHz pixel clock with 112 blanking pixels per line = 112 clock cycles of HBLANK.
This is far too short to run 6 tilemap FSMs serially if each requires 22 tiles × ~10 states.

**Solution:** Run all 4 PF tilemap engines in parallel (each has its own PF RAM port and
GFX ROM request line), with GFX ROM time-multiplexed via round-robin arbiter. Text and
Pivot share the remaining slots. This matches section2 §6.2's recommendation.

The 112-cycle HBLANK budget:
- 22 tiles × 8 GFX ROM reads per tile (lo + hi for 4 planes) = 176 reads per PF layer
- 4 PFs in parallel, round-robin = 4 × 176 / 4 = 176 arbiter time-slots needed
- 176 > 112: GFX ROM bandwidth is the critical constraint
- Mitigation: Use 32-bit GFX ROM reads (4 bytes per bus cycle) reducing reads by 4×
  → 44 bus cycles per PF layer → 44 total in parallel = fits in 112 cycles
- This is the 32-bit GFX ROM bus advantage noted in section2 §8

**GFX ROM arbitration:**
- 5 requestors: PF1–PF4 tilemap engines + sprite renderer (runs during VBLANK, disjoint)
- Text and Pivot use Character RAM / Pivot RAM (on-chip BRAM, no arbitration needed)
- PF1–PF4 run in parallel: each gets every 4th GFX ROM bus cycle (round-robin 4-slot)
  A 4-port multiplexer selects the active requester; each FSM stalls when not its slot

---

## 2. Step-by-Step Build Plan

17 steps total. Each step adds one new capability, has Verilator tests that must pass 100%
before proceeding, and corresponds to a Python model extension in `vectors/fdp_model.py`.

---

### Step 1 — Skeleton + Video Timing + Display Control Registers

**New capability:** Pixel clock domain, H/V timing counters, display control register bank.
Output: solid background color (palette index 0) for all pixels.

**Modules added:** `tc0630fdp_ctrl.sv` (complete), top-level timing skeleton.

**Test cases:**
1. Write PF1_XSCROLL = 0x0040. Read back. Verify `pf_xscroll[0]` = 0x0040.
2. Write EXTEND_MODE register word. Verify `extend_mode` = correct bit.
3. Drive H/V counters through one full 432×262 frame. Verify `pixel_valid` is high exactly
   320×232 = 74,240 cycles. Verify `hblank_n` and `vblank_n` pulse timing.
4. Verify INT2 fires at VBLANK start (vpos wraps to 0).

**Python model:** `TaitoF3Model.__init__`, `write_ctrl()`, `read_ctrl()` — register read/write
only. No rendering yet.

**Expected test count:** 20–30 tests.
**New BRAM/FIFO:** None (control regs are flip-flops, not BRAM).

---

### Step 2 — PF1 Tilemap: Global Scroll, No Line RAM, 4bpp Only

**New capability:** Single playfield renders 16×16 tiles with global X/Y scroll, 4bpp,
flip, palette decode. Line buffer filled during HBLANK. Colmix stub passes PF1 through.

**Modules added:** `tc0630fdp_tilemap.sv` (PF1 instance), `tc0630fdp_colmix.sv` (stub:
single-layer pass-through, no priority, no blend, no clip).

**Test cases:**
1. Fill PF1 RAM with a checkerboard (alternating tile codes 0 and 1). Write GFX ROM with
   solid-fill tiles. Verify output is a repeating 16×16 grid with correct palette indices.
2. Set PF1_XSCROLL = 16. Verify the checkerboard grid shifts left by 16 pixels, wraps at
   tilemap edge (mod 512).
3. Set PF1_YSCROLL = 16. Verify vertical shift.
4. Write a tile with flipX=1. Verify pixel output is horizontally mirrored.
5. Write a tile with flipY=1. Verify vertical mirror.
6. Write a tile with extra_planes=01 (5bpp) and verify hi-plane bits OR into palette addr.
7. Write a tile with extra_planes=11 (6bpp) and verify 6-bit pen output.
8. Transparency: tile with pen 0 → colmix outputs background (palette index 0).

**Python model:** `write_pf_ram()`, `write_gfx_rom()`, `render_scanline()` for PF1 only —
tile fetch, palette decode, scroll, 4/5/6bpp.

**Expected test count:** 60–80 tests.
**New BRAM:** PF1 RAM (0x1800 words = 3KB — fits in 1 M10K). GFX ROM simulation array.

---

### Step 3 — All 4 Playfields: Global Scroll, Fixed Priority

**New capability:** PF2–PF4 instances added. Colmix applies fixed priority ordering
(PF1 < PF2 < PF3 < PF4) with no blend, no clip. GFX ROM arbitration between 4 PFs.

**Modules added:** Three more `tc0630fdp_tilemap.sv` instances. `tc0630fdp_colmix.sv`
extended to 4-input priority mux.

**Test cases:**
1. Place distinct tile patterns on each PF. Set priority PF4 > PF3 > PF2 > PF1.
   Verify correct layer wins per pixel.
2. Place transparent tile on PF4 over opaque tile on PF3. Verify PF3 shows through.
3. Test all 4 PFs scrolling simultaneously, different scroll values, verify independence.
4. Extend mode (extend_mode=1): 64×32 tilemap. Write tiles in columns 32–63. Verify they
   display in the second 512-pixel X range.

**Python model:** Extend `render_scanline()` to PF1–PF4 with priority mux.

**Expected test count:** 40–60 tests (incremental over step 2).
**New BRAM:** PF2–PF4 RAM (3 × 3KB). GFX ROM arbiter logic.

---

### Step 4 — Text Layer + Character RAM

**New capability:** 64×64 8×8 tile text layer from CPU-writable Character RAM. Text always
draws on top of all PF layers (fixed highest priority).

**Modules added:** `tc0630fdp_text.sv` (complete).

**Test cases:**
1. Write character 'A' pixel data to Character RAM offset 0. Write Text RAM to place
   character 0 at tile (5, 5). Verify correct pixels appear at screen coords (40, 40).
2. Write a second character while the previous is being displayed. Verify the update
   appears on the next frame.
3. Color field: write different color values into Text RAM word bits[15:11]. Verify
   palette index changes in output.
4. Text over PF: place text tile over a PF tile. Verify text wins.
5. Transparency: pen 0 in character data → PF layer shows through.

**Python model:** `write_text_ram()`, `write_char_ram()`, text layer rendering using
the non-trivial charlayout bit-offset formula from §11.1.

**Expected test count:** 30–50 tests.
**New BRAM:** Text RAM (4KB = 1 M10K), Character RAM (8KB = 1 M10K).

---

### Step 5 — Line RAM Parser + Rowscroll

**New capability:** `tc0630fdp_lineram.sv` first version. Parses rowscroll sections (§9.11)
only. Per-scanline X scroll override delivered to all 4 PF engines.

**Modules added:** `tc0630fdp_lineram.sv` (rowscroll + enable bits only initially).

**Test cases:**
1. Write Line RAM rowscroll for PF1, scanlines 50–70, value 32 pixels. Verify those
   scanlines shift right by 32 while others remain at global scroll.
2. Rowscroll on all 4 PFs simultaneously. Verify each PF shifts independently.
3. Enable bit test: set rowscroll value but leave enable bit clear. Verify no shift.
4. Raster wave: write a sine-approximation rowscroll pattern (monotonically increasing
   offsets). Verify the tilemap visually "waves" in the expected direction.
5. PF4 with alt-tilemap enable bit: write enable in §9.1 section, verify the +0x2000
   offset activates in the PF4 tilemap engine.

**Python model:** `write_line_ram()`, extend `render_scanline()` with rowscroll logic.

**Expected test count:** 40–60 tests.
**New BRAM:** Line RAM (64KB = 64 M10K blocks — largest single allocation in the design).

---

### Step 6 — Per-Scanline Zoom (Line RAM §9.9)

**New capability:** Horizontal zoom per scanline for each PF. Fractional X accumulator
in the tilemap engine replaces the simple tile-column counter. PF2/PF4 Y-zoom swap
correction applied in the Line RAM parser.

**Modules extended:** `tc0630fdp_lineram.sv` adds zoom section parsing. `tc0630fdp_tilemap.sv`
adds zoom accumulator.

**Test cases:**
1. Set PF1 X zoom = 0x40 (half width) for scanlines 100–120. Verify those scanlines show
   the tilemap at 2× horizontal density.
2. Set zoom = 0x00 (no zoom / 1:1) — verify no change from unzoomed output.
3. PF2 Y-zoom swap: write PF2 Y-zoom into the PF4 Line RAM address range (0x8600) and
   verify it applies to PF2 (the hardware quirk). Write to PF2 address (0x8400) and verify
   it applies to PF4.
4. Y-zoom on PF1: Set Y scale = 0x40 (zoom out vertically). Verify fewer source tilemap
   rows are sampled per screen height.
5. Simultaneous X and Y zoom on same PF. Verify both axes scale independently.

**Python model:** Add zoom accumulator logic; add PF2/PF4 swap correction.

**Expected test count:** 40–60 tests.
**New BRAM/FIFO:** None (zoom is logic state, not memory).

---

### Step 7 — Colscroll and Palette Addition

**New capability:** Column scroll (PF3/PF4, per-scanline), palette addition offset
(all 4 PFs, per-scanline). These are the final two Line RAM data sections for the
tilemap engines.

**Modules extended:** Line RAM parser adds colscroll (§9.2) and pal_add (§9.10) sections.
Tilemap engine adds palette offset adder.

**Test cases:**
1. PF3 colscroll: set colscroll = 64 for scanlines 10–30. Verify horizontal offset applies
   to PF3 on those scanlines only. Verify PF4 is not affected.
2. PF4 colscroll independence from PF3.
3. PF1 palette addition: set pal_add = 16 for all scanlines. Verify every tile's palette
   index is incremented by 1 (pal_add / 16 = 1 palette line shift).
4. Palette cycling: write a sequence of increasing pal_add values per scanline (0, 16, 32...).
   Verify a color-gradient band effect across the screen.
5. Colscroll + rowscroll simultaneously active on PF3. Verify additive effect.

**Python model:** Add colscroll and palette addition to render_scanline().

**Expected test count:** 30–50 tests.

---

### Step 8 — Simple Sprites: No Zoom, No Block, No Jump

**New capability:** Sprite scanner walks RAM, builds per-scanline sprite list. Sprite
renderer fills line buffer. Single-tile sprites at exact positions, no zoom, flip working.
4 priority groups output to colmix.

**Modules added:** `tc0630fdp_sprite_scan.sv` (walker only, no jump, no block yet),
`tc0630fdp_sprite_render.sv` (no zoom yet). Colmix extended to include sprite line buffer
as a 5th input.

**Test cases:**
1. Place 1 sprite at (100, 80). Write GFX ROM tile. Verify sprite pixels appear at correct
   screen position.
2. flipX on sprite: verify horizontal mirror.
3. flipY on sprite: verify vertical mirror.
4. Transparent pen: pen 0 in GFX ROM → sprite pixel not written → PF layer shows through.
5. Two sprites at overlapping positions. Lower-address sprite wins (drawn last = on top).
   Verify per §8.3 ordering.
6. Priority group: sprite with color[7:6]=01 (group 0x40). Set Line RAM sprite priority
   for that group = 5. Set PF1 priority = 10 > 5. Verify PF1 wins over sprite.
7. Sprite with priority group = 0xC0, priority = 15 (maximum). Verify it draws over all PFs.

**Python model:** `write_sprite_ram()`, sprite scanning logic, line buffer rendering (no zoom).

**Expected test count:** 50–80 tests.
**New BRAM:** Sprite RAM (64KB = 64 M10K). Per-scanline sprite list BRAM (~232 × 64 × 8 bytes
= ~120KB — may need external SDRAM; see §3 below). Sprite dual line buffers (2 × 320 × 14-bit = ~1KB).

---

### Step 9 — Sprite Zoom

**New capability:** Per-sprite zoom using fixed-point accumulator. x_zoom / y_zoom fields
active. Sprites scale horizontally and vertically.

**Modules extended:** `tc0630fdp_sprite_render.sv` adds zoom accumulator (identical
pattern to TC0180VCU `src_x_c / src_y_c` combinational in `tc0180vcu_sprite.sv`).

**Test cases:**
1. x_zoom = 0x80 (half size): 16×16 tile renders as 8×8 on screen. Count actual pixels.
2. x_zoom = 0xFF: sprite invisible (renders 0 pixels).
3. x_zoom = 0x00: full size (same as no zoom baseline).
4. y_zoom = 0x80: half height.
5. Asymmetric zoom: x_zoom = 0x40, y_zoom = 0x80 — verify width and height independently.
6. 5bpp sprite: extra_planes = 01 in command word. Verify hi-ROM bits combine correctly.
7. 6bpp sprite: extra_planes = 11. Verify 6-bit pen lookup.

**Python model:** Add zoom accumulator to sprite rendering.

**Expected test count:** 30–50 tests.

---

### Step 10 — Sprite Block Groups and Jump Mechanism

**New capability:** Multi-tile block sprites (anchor + continuation entries). Jump
mechanism in sprite walker (Word6[15] jump bit + index).

**Modules extended:** `tc0630fdp_sprite_scan.sv` adds block group state machine and
jump support.

**Test cases:**
1. 2×2 block sprite: anchor at (50, 50) with x_num=1, y_num=1. Four continuation entries.
   Verify 4 tiles placed correctly in a 2×2 grid.
2. Block sprite with zoom: x_zoom=0x80 on anchor. Verify all 4 tiles use anchor zoom.
3. Jump: place sprite at index 10 with Word6 jump=1, target=100. Verify entries 11–99
   are skipped. Entry at index 100 is processed.
4. Jump chain: multiple jump entries. Verify correct traversal.
5. Block + jump: anchor at index 5, jump mid-block. Verify block terminates cleanly.
6. Lock bit (Word4[11]): sprite with lock=1 inherits position from previous block anchor.

**Python model:** Add block group machine and jump to sprite scanner.

**Expected test count:** 40–70 tests.

---

### Step 11 — Priority Resolution and Basic Compositing

**New capability:** Full 6-layer priority mux in colmix using per-scanline priority values
from Line RAM. Priority buffer (dual-nibble src_prio / dst_prio). No alpha blend yet.

**Modules extended:** `tc0630fdp_colmix.sv` adds full priority buffer and 6-layer
arbitration loop. Text and sprite layers added to priority ordering.

**Test cases:**
1. All 6 layers active at same pixel. Verify highest-priority layer wins.
2. Priority sweep: change PF1 priority from 0 to 15 across scanlines. Verify it transitions
   from below all layers to above all layers.
3. Sprite priority group 0x00 at priority 3, PF2 at priority 4: verify PF2 wins.
4. Sprite priority group 0xC0 at priority 14, PF4 at priority 15: verify PF4 wins.
5. Text layer: fixed priority (always top). Verify text beats priority-15 sprite.
6. Priority 0 sprite: verify it is below even priority-1 playfield.
7. Opaque tile on PF4 (priority 8), transparent tile on PF3 (priority 10): verify PF4
   shows through the transparent PF3 pixel.

**Python model:** Add priority buffer and layer arbitration.

**Expected test count:** 50–80 tests.

---

### Step 12 — Clip Planes

**New capability:** 4 clip planes evaluated per pixel per layer. Normal clip (intersection)
and invert mode (complement). Per-layer clip enable mask.

**Modules extended:** `tc0630fdp_colmix.sv` adds clip evaluation tree.

**Test cases:**
1. Enable clip plane 0 for PF1, left=50, right=200. Verify PF1 visible only in x∈[50,200].
2. Two clip planes both enabled for PF2. Verify intersection: only pixels inside BOTH
   windows are visible.
3. Invert mode on one plane: verify pixels inside window are blanked, outside visible.
4. PF3 with clip, PF4 without clip: verify clip does not affect PF4.
5. Clip with layer = priority 15 sprite: verify sprite is also clipped by its clip planes.
6. Alt-clip: test pbobble4 / commandw inversion sense bit (clip_invert sense reversal).
7. Clip boundary edge: pixel at exactly left boundary. Verify included (left is inclusive).

**Python model:** Add 4-plane clip evaluation to `render_scanline()`.

**Expected test count:** 50–80 tests.

---

### Step 13 — Alpha Blend (Normal Mode A)

**New capability:** Blend mode 01 (normal blend) using A_src and A_dst coefficients from
Line RAM §9.5. Formula: `out = clamp(src * A_src/8 + dst * A_dst/8, 0, 255)`.

**Modules extended:** `tc0630fdp_colmix.sv` adds 3-stage alpha blend pipeline. Priority
buffer dst_prio nibble tracking activated.

**Test cases:**
1. Single layer, blend mode 01, A_src=4, A_dst=4 (50/50 blend). Verify output is average
   of src and dst RGB values (within ±1 for integer rounding).
2. A_src=8, A_dst=0: fully opaque source. Verify output = src.
3. A_src=0, A_dst=8: fully transparent source. Verify output = dst (background).
4. A_src=8, A_dst=8: saturates. Verify output = min(2×src_channel, 255).
5. Darius Gaiden blend conflict: two layers at same priority both requesting blend.
   Verify the hardware-specific behavior (src_prio / dst_prio tracking).
6. PF layer blend + sprite opaque on top: sprite should override blend result (opaque wins).

**Python model:** Add alpha formula with saturating add.

**Expected test count:** 40–60 tests.

---

### Step 14 — Alpha Blend Reverse Mode B

**New capability:** Blend mode 10 (reverse blend) using B_src and B_dst coefficients.
This is the second alpha channel pair from Line RAM §9.5.

**Test cases:**
1. Set B_src=6, B_dst=2, blend mode=10. Verify different coefficients from mode 01.
2. Same pixel, different priority layers requesting mode 01 vs mode 10. Verify each layer
   uses its own coefficient pair.
3. Mode 11 (opaque layer): verify it behaves identically to mode 00 (no blend) —
   pixel replaces destination with no blending.

**Python model:** Add reverse blend coefficients. Complete all 4 blend mode cases.

**Expected test count:** 20–30 tests.

---

### Step 15 — Mosaic Effect

**New capability:** Per-scanline mosaic X-sample from Line RAM §9.6. Pixel coordinate
snapped to lower-resolution grid before tile/pixel fetch.

**Modules extended:** Tilemap engine gains mosaic pre-snap of hpos before fetch address
computation. Sprite line buffer gains mosaic snap at read time.

**Test cases:**
1. Enable mosaic rate=3 for PF1 (sample every 4 pixels). Verify 4-pixel-wide blocks.
2. Rate=0: no mosaic (each pixel independent). Verify no change.
3. Mosaic on sprite: enable sprite mosaic, verify sprite pixels blocked.
4. Independent mosaic: PF1 with rate=3, PF2 with rate=7. Verify different block widths.
5. Mosaic boundary: verify the `(x - H_START + 114) % 432 % sample_rate` formula produces
   correct alignment at x=0 and at horizontal borders.

**Python model:** Add mosaic snap formula.

**Expected test count:** 20–30 tests.

---

### Step 16 — Pivot Layer

**New capability:** `tc0630fdp_pivot.sv` complete. Per-scanline enable/bank/blend from
Line RAM §9.4. Column-major tile addressing. Composite with correct priority.

**Modules added:** `tc0630fdp_pivot.sv` (complete). Colmix extended to accept pivot pixel.

**Test cases:**
1. Enable pivot layer, fill Pivot RAM with known pattern. Verify pixels appear at
   expected screen positions.
2. Pivot bank select: write two different patterns at bank 0 and bank 1 addresses.
   Toggle `ls_pivot_bank` mid-frame. Verify correct bank displayed per scanline.
3. Column-major addressing verification: write tile at Pivot RAM offset 0 (column 0,
   row 0) and offset 1 (column 0, row 1). Verify they appear at correct screen positions.
4. Pivot blend: enable blend mode for pivot, verify alpha formula applies.
5. Pivot disabled (ls_pivot_en=0): verify no pivot pixels output.
6. Pivot over PF: verify pivot at priority N beats PF at priority N-1.

**Python model:** Add pivot layer rendering with column-major tile index computation.

**Expected test count:** 30–50 tests.

---

### Step 17 — Full Integration + Frame Regression

**New capability:** All 17 sections of Line RAM parsed. All 7 modules active simultaneously.
Full 5-frame regression against MAME frame dumps for RayForce and Elevator Action Returns.

**Modules:** No new modules. All prior stubs replaced with complete implementations.
`tc0630fdp.sv` top-level finalized with Quartus BRAM instances and SDRAM port stubs.

**Test cases:**
1. RayForce frame 0 (title screen): 320×232 pixel comparison. Target: >90% exact match
   on palette indices. Remaining diffs expected to be PPU timing artifacts.
2. RayForce frame 1 (first gameplay frame with scroll + sprites).
3. Elevator Action Returns frame 0 (uses alpha blend heavily — Tier-4 test).
4. Elevator Action Returns frame 1 (per-scanline priority transitions).
5. Darius Gaiden frame 0 (uses pivot layer + sprite trails effect).
6. Regression after each integration: run all prior step tests. Verify no regressions.

**Python model:** `render_frame()` — full 320×232 output from all layers.

**Expected test count:** Full suite from steps 1–16 (~600–900 tests) + 6 frame-level regressions.
**Goal gate-4 first-pass rate:** section2 §8 estimates 25–35%. With the step-by-step
validation approach, the integration regression is the true metric — individual step
tests should all pass 100% before reaching step 17.

---

## 3. Critical Path Analysis

### 3.1 Line RAM Zoom + Rowscroll Interaction

**The problem:** Each scanline, the tilemap engine needs both: (1) an effective global X
coordinate (global scroll + rowscroll override), and (2) a zoom factor that changes how
fast the X coordinate advances through the source tilemap. These interact: zoomed rowscroll
must apply the same zoom step as unzoomed rowscroll, but from a potentially different
starting X.

**When does each apply?**
- Rowscroll: replaces the global X scroll for that scanline. Effective starting X =
  `global_xscroll + rowscroll_value` (with inverted fractional bits). The Line RAM enable
  section (§9.1) bitfield determines whether rowscroll is active for each PF on each line.
- Zoom: changes the per-pixel X step through the source tilemap. `zoom_step = (1 + zoom_x / 256)`
  in 16.16 fixed-point. When zoom=0x00, step=1.0 (1:1). When zoom=0x80, step≈1.5 (zoom in).
- They compose: the zoom accumulator starts at `effective_x` (after rowscroll) and advances
  by `zoom_step` per pixel.

**Implementation approach:** The rowscroll-adjusted X is computed at the start of HBLANK
(from Line RAM output). The zoom accumulator is then initialized to that X value. No
special-casing needed — rowscroll just sets the accumulator's initial value.

**Colscroll interaction:** Colscroll (PF3/PF4 only, §9.2) adds a per-column offset after
the zoom accumulator determines which tilemap column is being fetched. It modifies the
tile address, not the pixel fetch address within the tile. Applied after zoom — the
zoomed tile address is computed first, then colscroll offsets that tile index by ±511.

---

### 3.2 Pivot Layer — Affine Math Without Floating Point

**The problem:** Section2 §4.2 and MAME describe this as an "affine" layer, suggesting
matrix transforms. However, investigation of the hardware behavior reveals that the FPGA
module itself does NOT perform affine math.

**Resolution:** The pivot layer is a standard 8×8 tile map with column-major scan order.
The CPU writes pre-rotated pixel data into Pivot RAM each frame (e.g., during VBLANK using
the INT3 hblank timer to stream rotated scanlines). The chip reads it back and displays it.
This is the same approach used in Taito F2's TC0100SCN with its "FG0" text layer — the CPU
does the math, the chip just renders tiles.

**Implication for RTL:** No matrix multiply, no fixed-point trig, no cordic. The `tc0630fdp_pivot.sv`
module is simpler than `tc0630fdp_tilemap.sv` — it just decodes column-major tile addresses
and renders 8×8 4bpp tiles. The "pivot" and "rotation" effects players see come entirely from
the CPU-driven pixel updates, not from hardware transform.

**FPGA implementation:** Implement as a standard scanline tile renderer identical to the
text layer, but with column-major addressing and the pixel_xscroll / pixel_yscroll applied
from the display control registers.

---

### 3.3 Alpha Blend Priority System — How Many Comparisons Per Pixel

**The problem:** MAME uses a `dpix_n[8][16]` function table with 128 dispatch cases.
Implementing 128 branches per pixel in RTL would generate enormous logic.

**How many priority comparisons per pixel in the worst case:**
For each of the 6 layer pixels at position x:
1. Evaluate clip plane windows: 4 comparisons per layer = 24 total
2. Check transparency: 6 comparisons (pen == 0 for each layer)
3. Compare layer priority vs current `src_prio[x]` in priority buffer: 6 comparisons
4. Blend mode dispatch: 1 of 4 modes per layer = 4 possible code paths per layer

**Reduction strategy:** The 128 MAME dispatch cases map to 4 blend modes × 2 alpha
coefficient sets × 16 priority sub-modes. In RTL this collapses to:

```
// For each non-transparent, in-window pixel, in priority order:
case (blend_mode[layer]):
  2'b00, 2'b11:   // Opaque — direct write
    if (layer_prio > src_prio[x]):
        output[x]   = layer_color
        src_prio[x] = layer_prio
  2'b01:          // Normal blend A
    if (layer_prio > src_prio[x]):
        output[x]   = clamp(layer_rgb * A_src/8 + output[x] * A_dst/8)
        src_prio[x] = layer_prio
        dst_prio[x] = layer_prio   // this layer becomes the blend destination
  2'b10:          // Reverse blend B
    if (layer_prio > dst_prio[x]):   // key difference: checks dst_prio
        output[x]   = clamp(layer_rgb * B_src/8 + output[x] * B_dst/8)
endcase
```

Total comparisons per pixel: 24 (clip) + 6 (transparency) + 6 (priority) = 36 comparisons.
All are ≤ 4-bit comparisons. This is well within a single LUT stage on Cyclone V.

**Pipeline depth:** The blend multiply-add needs 2 multipliers (8-bit × 4-bit = 12-bit) and
one saturating adder. Registered as a 3-stage pipeline. The per-scanline Line RAM coefficients
(`A_src`, `A_dst`, `B_src`, `B_dst`) are 4-bit values loaded at HBLANK — they are constants
during the entire active scan period.

**Darius Gaiden blend conflict:** When two layers at the same priority both request blend
mode, the hardware resolves this by applying the first layer's blend normally and discarding
the second layer's blend contribution. The `src_prio / dst_prio` dual-nibble scheme handles
this: the second layer sees `src_prio[x]` already equal to its own priority, so the
`> src_prio[x]` comparison fails and it skips.

---

## 4. Suggested File Structure

```
chips/tc0630fdp/
  section1_registers.md
  section2_behavior.md
  section3_rtl_plan.md     ← this document

  rtl/
    tc0630fdp.sv              top-level integrator, CPU bus, timing, BRAM instantiation
    tc0630fdp_ctrl.sv         display control register bank (16 × 16-bit)
    tc0630fdp_lineram.sv      Line RAM 64KB BRAM + per-scanline parser/distributor
    tc0630fdp_tilemap.sv      PF1–PF4 tilemap engine (parameterized, 4 instances)
    tc0630fdp_text.sv         text layer (64×64 8×8 tiles, CPU-writable chars)
    tc0630fdp_pivot.sv        pivot layer (64×32 8×8 tiles, column-major, CPU-writable)
    tc0630fdp_sprite_scan.sv  VBLANK sprite walker (jump + block group state machine)
    tc0630fdp_sprite_render.sv per-scanline line buffer renderer (zoom + dual buffer)
    tc0630fdp_sprite.sv       sprite sub-system wrapper (instantiates scan + render)
    tc0630fdp_colmix.sv       compositor (6 layers, 4 clip planes, priority, alpha blend)

  vectors/
    tb_tc0630fdp.cpp          Verilator C++ testbench (same pattern as tb_tc0180vcu.cpp)
    fdp_model.py              Python behavioral model (same API pattern as vcu_model.py)
    generate_vectors.py       Vector generator script
    games/
      rayforce_frame0.bin     MAME frame dump for step 17 regression
      rayforce_frame1.bin
      elevact_frame0.bin
      elevact_frame1.bin
      dariusg_frame0.bin
```

---

## 5. Reuse from TC0180VCU

The following specific patterns from the TC0180VCU RTL translate directly to TC0630FDP.
Code can be copied and adapted rather than written from scratch.

### 5.1 From `tc0180vcu_bg.sv` → `tc0630fdp_tilemap.sv`

**Direct reuse (copy + adapt):**

| VCU pattern | FDP adaptation |
|------------|----------------|
| 13-state FSM: `BG_IDLE → BG_SYRD → BG_INIT → BG_CODE → BG_ATTR → BG_GFX0..7` | Rename `BG_` to `TM_`; remove `BG_SYRD` (scroll now from Line RAM struct, not scroll RAM); add `TM_GFX_HI0..TM_GFX_HI1` states for hi-plane bytes |
| `lpb` scroll block division → `scroll_x_frac_r`, `scroll_x_tile_r`, `scroll_y_r` | Replace with direct Line RAM struct inputs: `ls_rowscroll`, `ls_zoom_x/y`. No division needed. |
| `gfx_tile_base_c = {1'b0, tile_code_r, 7'b0}` (tile_code × 128) | Same formula; extend to 17-bit tile_code: `gfx_tile_base_c = {1'b0, tile_code_r[16:0], 7'b0}` |
| 4-plane decode: `{p3[b], p2[b], p1[b], p0[b]}` in `BG_GFX3` / `BG_GFX7` | Same bit-extract pattern; add OR of hi_plane bits for 5/6bpp: `pen = {hi_r[b], hi_l[b], lo3[b], lo2[b], lo1[b], lo0[b]}` |
| `linebuf[0:511]` 512-entry line buffer, written per tile | Resize to 320 entries (visible width only); change write to `linebuf[tile_x * 16 + 0..15]` clamped to 319 |
| `cur_map_col_c = (first_tile_col_r + tile_col) & 6'h3F` | Add extend_mode mux: `& (extend_mode ? 6'h3F : 5'h1F)` for 64- vs 32-wide map |
| `attr_flipx_c = vram_q[14]`, `attr_flipy_c = vram_q[15]` | Same bit positions in FDP tilemap word (section1 §4) |

**The VCU `tc0180vcu_bg.sv` module is structurally ~70% identical to `tc0630fdp_tilemap.sv`.**
Start with a copy of `tc0180vcu_bg.sv`, remove the lpb scroll block logic, add zoom
accumulator, add hi-plane fetch states, extend tile_code to 17 bits, add palette addition.
Estimated new LOC from the VCU base: ~150 lines added to ~440 VCU lines = ~590 lines total.

### 5.2 From `tc0180vcu_sprite.sv` → `tc0630fdp_sprite_scan.sv` + `tc0630fdp_sprite_render.sv`

**Direct reuse (copy + adapt):**

| VCU pattern | FDP adaptation |
|------------|----------------|
| `bs_pos_calc` always_comb block (big sprite tile position formula) | Copy verbatim. Same formula: `xoff(n) = (n * (0xFF - zoom) + 15) >> 4`. Rename `bs_` prefix to `blk_`. |
| `SP_LOAD0..SP_LOAD5` states (load 6 sprite RAM words) | Extend to `SP_LOAD0..SP_LOAD7` (8 words for FDP vs 6 for VCU) |
| `src_x_c / src_y_c` zoom source coordinate computation | Copy verbatim. `src_x = sx_idx * 16 / zx_r` — identical zoom algorithm |
| GFX ROM fetch states `SP_ROWL0..3`, `SP_ROWR0..3` | Copy verbatim. Same 4-plane 16×16 tile fetch pattern |
| `cur_px_data_c` pixel decode (bit extract from 4 plane bytes) | Extend for 5/6bpp: same bit-extract but with extra plane bytes feeding bits [4:5] |
| `in_big_sprite = (bs_tiles_rem_r != 0)` combinational derivation | Copy verbatim — same Verilator NBA-scheduling fix applies |
| `vblank_fall` edge detection | Copy verbatim. Rename to match FDP signal names. |
| Case A/B/C (group tile / anchor / single tile) in `SP_CHECK` | Copy verbatim. Add Case D for command mode (Word3[15]=1): parse bank_sel, trails, extra_planes, flipscreen. |

**The `tc0180vcu_sprite.sv` is ~80% reusable for `tc0630fdp_sprite_scan.sv`.**
Primary additions: jump mechanism (Word6[15] branch), command mode parsing (Word3[15]),
17-bit tile code (Word0 + Word5[0]), and output to per-scanline list BRAM instead of
direct framebuffer writes. Estimated new LOC from VCU base: ~200 lines added to ~660 VCU
lines = ~860 lines total across scan + render split.

### 5.3 From `tc0180vcu.sv` → `tc0630fdp.sv`

**Direct reuse:**
- Reset synchronizer (2-flop pipeline): copy verbatim.
- VBLANK edge detect (`vblank_n_prev`, `vblank_fall`): copy verbatim.
- HBLANK cycle sequencer (`hblank_cyc` counter, `bg_start` / `fg_start` pulse logic):
  copy the counter; change the timing constants (FDP has shorter HBLANK = 112 cycles
  vs VCU's ~432 cycles; adjust sequencing to parallel execution).
- `altsyncram` M10K instantiation pattern for BRAM regions: copy for Line RAM, Sprite RAM,
  Pivot RAM, Text RAM, Char RAM with updated width/depth parameters.
- CPU read mux pattern: copy and extend for FDP's larger address map.
- GFX ROM arbitration priority mux (TX > BG > FG > Sprite): copy and extend to 7 requestors
  (Text, PF1, PF2, PF3, PF4, Pivot, Sprite) with a round-robin arbiter replacing the
  fixed-priority chain (needed because PF1–PF4 run in parallel, not sequentially).

---

## 6. Summary

**Total estimated steps:** 17

**Step to start with:** Step 1 — Skeleton + Video Timing + Display Control Registers.
This is the only step with zero dependencies, establishes the pixel clock domain,
and verifies the basic test infrastructure (Verilator build + Python model + vector format)
before any rendering logic is written.

**First test case (Step 1, Test 1):**
```python
# fdp_model.py
model = TaitoF3Model()
model.write_ctrl(0, 0x0040)           # PF1_XSCROLL = 0x0040
assert model.read_ctrl(0) == 0x0040  # verify register

# tb_tc0630fdp.cpp
dut.cpu_cs  = 1; dut.cpu_we = 1;
dut.cpu_addr = 0;           // word offset 0 = PF1_XSCROLL
dut.cpu_din  = 0x0040;
dut.cpu_be   = 0x3;
tick();
dut.cpu_we = 0;
tick();
assert(dut.pf_xscroll[0] == 0x0040);

// Vector file (tb_tc0630fdp.cpp):
// WRITE CTRL 00 0040
// EXPECT CTRL 00 0040
```

**Step with highest risk:** Step 13 (Alpha Blend). The dual-nibble priority buffer
and the interaction between src_prio and dst_prio tracking across 6 layers is the
most novel logic in the design (no VCU equivalent). Budget extra iteration time here.
The Darius Gaiden blend conflict test (Step 13, Test 5) will be the hardest single test
to pass — it requires exact replication of the hardware priority collision behavior.

**BRAM budget (all steps complete):**
- Line RAM: 64 M10K
- Sprite RAM: 64 M10K
- Playfield RAM: 48 M10K (across 4 PFs)
- Text RAM + Char RAM: 8 + 8 = 16 M10K
- Pivot RAM: 64 M10K
- Per-scanline sprite list: ~15 M10K (232 lines × 64 sprites × 8 bytes = ~120KB)
- Sprite line buffers: 1 M10K
- Priority buffer: 1 M10K
- **Total: ~273 M10K** — fits on DE10-Nano (397 M10K available) with 124 to spare for logic.

**GFX ROM note:** At 6.6715 MHz pixel clock, the 32-bit GFX ROM bus is essential. The
4-byte-per-cycle fetch reduces the per-tile GFX ROM access time from 8 cycles (8-bit bus)
to 2 cycles (32-bit bus), making parallel PF1–PF4 rendering feasible within the 112-cycle
HBLANK budget. The GFX ROM bus width parameter should be set to 32-bit in the SDRAM
controller from day one — retrofitting it after step 2 would require replumbing all
tilemap FSMs.
