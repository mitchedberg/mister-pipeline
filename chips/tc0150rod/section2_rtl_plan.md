# TC0150ROD — Section 2: RTL Build Plan

**Source documents:** section1_registers.md (RAM format, ROM format, rendering algorithm),
MAME tc0150rod.cpp (reference implementation), Taito Z integration_plan.md (system context)
**Complexity:** Tier-2 (single-chip, pure per-scanline rasterizer, no tilemap, no zoom table,
no external bus arbitration beyond ROM fetch)
**Comparison:** Significantly simpler than TC0480SCP (Tier-4). Comparable to TC0100SCN but with
different architecture (scanline rasterizer vs tile-based). No sprite involvement.

---

## 1. Complexity Assessment

TC0150ROD is one of the simpler chips in the Taito pipeline:

**What it does:**
- Reads 4 words from RAM per scanline (trivial BRAM read)
- Looks up 2bpp pixels from a 512KB GFX ROM (linear address, no tile decode, no plane interleave)
- Produces a 320-pixel-wide 12-bit palette-index scanline with 3-bit priority tags
- Does this twice per scanline (Road A then Road B) and arbitrates

**What it does NOT do:**
- No tile map
- No zoom (the "perspective" effect is purely in the CPU's per-scanline RAM writes — the chip
  just executes what the CPU wrote)
- No sprites
- No color mixing or blending
- No DMA
- No second clock domain

**Estimated RTL size:** ~300–400 lines of SystemVerilog. This is 3–5x simpler than TC0480SCP.

---

## 2. Module Interface

```systemverilog
module tc0150rod (
    input  logic        clk,          // system clock (e.g. 48 MHz)
    input  logic        rst_n,

    // CPU B bus interface (68000 async, chip-select decoded externally)
    input  logic        cpu_cs,       // chip select (active high)
    input  logic        cpu_we,       // write enable (1=write, 0=read)
    input  logic [11:0] cpu_addr,     // word address [12:1] from 68000 → 0x1000 words
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input  logic  [1:0] cpu_be,       // byte enables (UDS=be[1], LDS=be[0])
    output logic        cpu_dtack_n,  // DTACK — 1-cycle fast response

    // Road GFX ROM interface (to SDRAM arbiter)
    output logic [17:0] rom_addr,     // word address into 512KB ROM region (0x40000 words)
    input  logic [15:0] rom_data,     // ROM data returned
    output logic        rom_req,      // toggle-req handshake
    input  logic        rom_ack,      // toggle-ack handshake

    // Video timing inputs
    input  logic        hblank,       // active during horizontal blanking
    input  logic        vblank,       // active during vertical blanking
    input  logic  [8:0] hpos,         // current horizontal pixel position (0..511)
    input  logic  [7:0] vpos,         // current scanline (0..255)

    // Rendering parameters (set once per frame by top-level from game-specific constants)
    input  logic signed [7:0] y_offs,       // scanline offset (−1 for dblaxle/racingb)
    input  logic  [7:0] palette_offs,       // global palette bank (0xc0 for dblaxle/racingb)
    input  logic  [1:0] road_type,          // 0=standard, 1=contcirc, 2=aquajack
    input  logic        road_trans,         // 1=pen0 transparent in road body
    input  logic  [7:0] low_priority,       // priority tag for lines above switch line
    input  logic  [7:0] high_priority,      // priority tag for lines below switch line

    // Scanline output (consumed by priority mixer during active display)
    output logic [14:0] pix_out,      // {priority[2:0], palette_index[11:0]} per pixel
    output logic        pix_valid,    // high for one clock per output pixel
    output logic        pix_transp,   // high when pix_out is transparent (do not write)
    output logic  [7:0] line_priority // priority tag for this scanline (low or high)
);
```

### Notes on the interface

**SDRAM ROM fetch:** The road GFX ROM is 512KB, too large for on-chip BRAM on most FPGAs. It
lives in SDRAM. Access is via the same toggle-req/toggle-ack arbiter used by TC0480SCP. Since
the road renderer needs one ROM word per 8 pixels and the scanline width is 320 pixels, it
needs ~40 ROM words per road component per scanline. With two roads × 3 components each (body,
left edge, right edge) that is up to 240 ROM fetches per scanline. At ~48 MHz system clock and
typical SDRAM latency of 4–8 cycles, prefetching during HBlank is the correct strategy (see
Step 4 below).

**hpos/vpos:** The module drives its output during active display using a pixel counter. The
top-level video timing block provides these signals.

**Rendering parameters:** These are game-specific constants wired at instantiation, not
runtime-changeable registers. For dblaxle/racingb: y_offs=−1, palette_offs=0xc0, road_type=0,
road_trans=0, low_priority=1, high_priority=2.

---

## 3. Internal Block Decomposition

```
tc0150rod
├── road_ram          — 0x1000 × 16-bit dual-port BRAM (CPU port + read port)
├── road_ctrl_decode  — parses ram[0xfff]: bank select + priority_switch_line
├── ram_reader        — fetches 4 words per scanline at start of HBlank for Road A and B
├── rom_fetcher       — pre-fetches required GFX ROM words into line_cache BRAM
│                       driven by the RAM reader's tile_num and x_index range
├── line_renderer_A   — processes Road A: body, left edge, right edge → roada_line[]
├── line_renderer_B   — processes Road B: body, left edge, right edge → roadb_line[]
├── line_arbiter      — per-pixel Road A vs Road B priority arbitration → scanline[]
└── scanline_output   — shifts scanline[] out pixel-by-pixel during active display
```

In practice for a 300-line implementation, `line_renderer_A`, `line_renderer_B`, and
`line_arbiter` can be a single always_ff block that runs sequentially during HBlank.

---

## 4. Build Plan

### Step 1 — RAM + CPU Interface (50 lines)

Implement the 0x1000 × 16-bit road RAM as synchronous dual-port BRAM:
- Port A: CPU B bus (read/write, byte-enable, DTACK in 1 cycle)
- Port B: internal read port (word address, data out, 1-cycle latency)

Road RAM is write16 with byte-enable support (68000 UDS/LDS). The control word at word 0xFFF
is just a regular RAM location — no special decode needed at write time.

Verification: write a pattern from a test bench, read it back via both ports.

### Step 2 — Control Decode + RAM Reader (60 lines)

At the start of each HBlank (or end of active display):

1. Read `road_ctrl = ram[0x0FFF]`
2. Compute `road_A_address` and `road_B_address` from bank-select fields and `y_offs`
3. Read the 4-word Road A entry: words `road_A_address + vpos*4 + 0..3`
4. Read the 4-word Road B entry: words `road_B_address + vpos*4 + 0..3`
5. Compute:
   - `road_center_A = 0x5ff - ((-xoffset_A + 0xa7) & 0x7ff)`
   - `left_edge_A`, `right_edge_A`, `left_edge_B`, `right_edge_B`
   - Priority table `priorities[0..5]` with modifier bits applied
   - `priority_switch_line = (road_ctrl & 0xff) - y_offs`
   - `line_priority_tag = (vpos > priority_switch_line) ? high_priority : low_priority`

These 8 reads (4 for Road A + 4 for Road B) can be done in 8 consecutive cycles using the
internal read port. Add a state machine: IDLE → READ_CTRL → READ_A[0..3] → READ_B[0..3]
→ RENDER.

### Step 3 — Line Renderer + Arbiter (120 lines)

After the 8-word RAM read, compute both road line buffers combinatorially/sequentially.
This is the core of the chip.

**For each road (A then B):**
1. Compute `x_index_start` for body, left edge, right edge sections
2. For each pixel column 0..W-1, determine which section it falls in (body, left edge, right
   edge, or off-road)
3. Look up 2bpp pixel from line_cache (pre-fetched ROM data, see Step 4)
4. Apply palette calculation: `color = ((palette_offs + colbank + pal_xx_offs) << 4) + base`
5. Apply pixel remapping for type=1/2: `pixel = (pixel - 1) & 3`
6. Apply road_trans: if pixel==0 and road_trans, write 0xf000 instead of opaque
7. Apply off-edge background fill when clipl/clipr & 0x8000 is set
8. Write to `roada_line[W-1-x]` or `roadb_line[W-1-x]` (reversed for ROM orientation fix)

**Arbiter:** single pass over both line buffers to produce `scanline[0..W-1]`.

The renderer runs during HBlank (~16 µs at 6 MHz pixel clock). At 48 MHz system clock that
is ~768 system cycles — more than enough to process 320 pixels sequentially.

Implementation note: use a line buffer BRAM (two × 320 × 16-bit) for `roada_line` and
`roadb_line`, and a third for the final `scanline`. Alternatively, process Road A then Road
B then merge in three sequential passes, each taking ~100 cycles.

### Step 4 — ROM Pre-fetcher (80 lines)

The 2bpp pixel lookup `rom[(tile_num << 8) + (x_index >> 3)]` needs one ROM word per 8 pixels.

For each scanline during Step 2/3, compute which ROM words are needed:
- Road A body: tile_A, x_index range `[start_body_x .. end_body_x]`, up to 128 words
- Road A left edge: tile_A, x_index range `[0 .. 511]`, up to 64 words
- Road A right edge: tile_A, x_index range `[512 .. 1023]`, up to 64 words
- Road B: same, for tile_B

In practice the x_index range for one scanline spans at most 320 out of 1024 pixels, meaning
at most 40 consecutive ROM words per section. Total worst case: ~240 ROM words per scanline.

**Strategy:** Pre-fetch into a 256-word × 16-bit line cache (fits in one 4K BRAM). Begin
ROM fetch during the preceding HBlank (or during active display period). The ROM fetcher
issues sequential word requests to the SDRAM arbiter. At 48 MHz with SDRAM latency ~6
cycles, 240 fetches take ~1,440 cycles ≈ 30 µs, which fits within a 60 Hz frame's HBlank +
active period. Alternatively, cache the entire tile (256 words = 512 bytes) for tile_A when
tile_A changes, and similarly for tile_B. Since tile numbers change at most once per
scanline and often repeat across multiple scanlines, a 2-entry cache (one per road) covering
the current tile is efficient.

Simplest correct implementation: during HBlank, issue 256 consecutive ROM reads for
tile_A into cache_A[0..255], then 256 for tile_B into cache_B[0..255]. This takes
512 SDRAM cycles = ~10 µs at 48 MHz. HBlank is ~12 µs (for a 384-wide total line at
6 MHz pixel clock), which is tight but feasible. If tile_A == tile_B only one 256-word
fetch is needed.

**Line cache BRAM:** 2 × 256 × 16-bit = 2 × 4KB. Fits in 2 M4K or EBR blocks.

### Step 5 — Scanline Output (30 lines)

During active display, shift `scanline[hpos]` out pixel by pixel. The output is:
- `pix_out[14:12]` = priority bits 2:0 from stored scanline word bits [14:12]
- `pix_out[11:0]`  = palette index from stored scanline word bits [11:0]
- `pix_transp`     = 1 when scanline word bit 15 is set or word == 0x8000
- `line_priority`  = stored `priority_tag` for this scanline

The priority mixer at the top level reads `pix_out` and `line_priority` each pixel clock
to decide whether the road pixel goes above or below other layers.

---

## 5. BRAM Requirements

| BRAM Block           | Size            | Purpose                          |
|----------------------|-----------------|----------------------------------|
| road_ram             | 4K × 16-bit     | 0x1000 words of road line data   |
| roada_linebuf        | 512 × 16-bit    | Road A scanline pixel buffer     |
| roadb_linebuf        | 512 × 16-bit    | Road B scanline pixel buffer     |
| scanline_buf         | 512 × 16-bit    | Merged output scanline           |
| rom_cache_A          | 256 × 16-bit    | GFX ROM words for current tile A |
| rom_cache_B          | 256 × 16-bit    | GFX ROM words for current tile B |

Total: ~10KB of BRAM. On a Cyclone V (DE10-Nano) this consumes ~3 M10K blocks — trivial.

The 512KB road GFX ROM lives in SDRAM (too large for BRAM). The 256-word tile cache
means each rendering pass needs at most 2 SDRAM bursts (one per tile), not per-pixel access.

---

## 6. Reuse from Other Chips

**None.** TC0150ROD is architecturally self-contained. It does not share logic with:
- TC0480SCP (tilemap engine — completely different architecture)
- TC0200OBJ / sprite scanner (different pipeline)
- TC0180VCU (no overlap)

The SDRAM arbiter interface (toggle-req/toggle-ack) is the same pattern used by TC0480SCP's
GFX ROM fetcher. The same arbiter module can serve both.

---

## 7. Implementation Risk

**Low.** The rendering algorithm is completely documented in MAME and cross-verified in
FBNeo. All field offsets and bit meanings are confirmed. The priority modifier bits have
MAME comments explaining their empirical derivation, and for dblaxle/racingb the modifier
bits are not used (standard priorities apply).

The one uncertainty is ROM pre-fetch timing: whether 256-word SDRAM burst + render fits
within one HBlank period. If it does not fit, the alternative is to render during the
active display period of the *previous* line (standard double-buffering). This is a
timing/pipelining decision, not an algorithmic one.

---

## 8. Comparison with Other Chips in This Pipeline

| Chip       | Tier | Lines est. | Main complexity driver              |
|------------|------|------------|-------------------------------------|
| TC0150ROD  | 2    | ~350       | Per-scanline rasterizer, SDRAM ROM fetch |
| TC0100SCN  | 2    | ~400       | Two-layer tilemap, scroll           |
| TC0180VCU  | 3    | ~700       | Three-layer tilemap + zoom + rotate |
| TC0480SCP  | 4    | ~1200      | Five layers, rowscroll, rowzoom, colscroll |

TC0150ROD is the simplest video chip in the Taito Z system. It should be implementable and
functionally verified in 1–2 sessions once the system framework (CPU B, shared RAM, SDRAM
arbiter) is in place.
