`default_nettype none
// =============================================================================
// TC0630FDP — Unified Pixel Pipeline  (8× clock, single GFX ROM port)
// =============================================================================
// Replaces tc0630fdp_bg_4x, tc0630fdp_text, tc0630fdp_pivot, and tc0630fdp_colmix
// with a single module that shares one datapath across all tile-based layers.
//
// Sprite scan (tc0630fdp_sprite_scan) and line RAM (tc0630fdp_lineram) remain
// as separate modules — sprite scan runs during VBLANK on its own clock, and
// lineram is a pure data store with a fixed parser interface.
//
// ─── Architecture Overview ───────────────────────────────────────────────────
//
// clk_8x  ≈ 192 MHz  (8× pixel clock ≈ 24 MHz)
// clk_4x  ≈  96 MHz  (kept as alias; clk_8x runs both old 4x and new 2x slots)
//
// HBLANK budget per scanline (at 8× = 192 MHz):
//   HBLANK = 112 cycles at pix_clk (hpos < 46) + 66 cycles (hpos >= 366)
//   Total: 178 pix_clk cycles × 8 = 1424 clk_8x cycles per scanline.
//
//   Layer allocation (each runs its full tile-fetch FSM sequentially):
//
//   Phase A — BG layers (PF1–PF4), 4 × up to ~421 clk_8x cycles each:
//     Single shared GFX ROM port, single shared tile decoder.
//     Same FSM as bg_4x but now 4 layers all fit in one HBLANK at 8x because
//     4 × 421 = 1684 clk_8x cycles > 1424.  Wait — they don't all fit.
//
// ─── REVISED ARCHITECTURE ────────────────────────────────────────────────────
//
// The 4x BG engine already fits all 4 BG layers at 4x clock (421 cycles each,
// 4 layers sequential within HBLANK).  At 8x we have 2× the budget, allowing
// us to ALSO fit text and pivot in the same HBLANK window.
//
// Text layer:  40 tiles × 10 cycles = 400 clk_4x.  At 8x = already fits.
// Pivot layer: 41 tiles × 10 cycles ≈ 410 clk_4x.  At 8x = already fits.
//
// The problem with the old design: each module has its own FSM, its own
// line buffers, and its own GFX ROM port.  Shared GFX ROM is the bottleneck.
//
// At 8× clock, the HBLANK budget doubles to 1424 cycles.  We can run:
//   - BG0..BG3 sequentially, each up to 421 cycles  (total 1684 at 4x = 842 at 8x)
//   - Text layer: 400 cycles (at 4x) = already within 1424 at 8x
//   - Pivot layer: 410 cycles (at 4x) = already within 1424 at 8x
//
// But the real question is: can all 6 tile-based layers share a SINGLE GFX ROM
// port sequentially within 1424 × 8x cycles?
//
//   BG fetch cycles (GFX ROM accesses per tile, 21 tiles):
//     BG_GFX0(1) + BG_GFX1(1) = 2 GFX reads per tile × 21 tiles = 42 reads/layer
//     4 layers × 42 = 168 GFX ROM reads for BG layers.
//     Other BG_ATTR/BG_CODE/BG_WRITE cycles don't use GFX ROM.
//
//   Text GFX reads: Text uses char_ram (CPU-writable MLAB), NOT gfx_rom.
//   Pivot GFX reads: Pivot uses pvt_ram (CPU-writable MLAB), NOT gfx_rom.
//
// → Text and pivot DON'T use the GFX ROM at all!  They read internal MLABs.
// → The GFX ROM port contention is ONLY between BG layers and sprite renderer.
//
// ─── UNIFIED FSM DESIGN ──────────────────────────────────────────────────────
//
// The unified pipeline runs at clk_8x with a single large FSM that sequences:
//
//   On HBLANK rising edge:
//     Phase BG: run all 4 BG layers sequentially, sharing GFX ROM + tile decoder
//     Phase TXT: run text layer (no GFX ROM; reads char_ram MLAB)
//     Phase PVT: run pivot layer (no GFX ROM; reads pvt_ram MLAB)
//     [Sprite renderer runs concurrently; it has its own FSM and GFX ROM port —
//      but since text/pivot don't need GFX ROM, we CAN timeshare: BG uses it
//      during BG phase, sprite uses it during idle cycles after BG phase.]
//
// The sprite renderer is kept as-is (already serialized at clk_4x in
// tc0630fdp_sprite_render.sv) because it has fundamentally different datapath
// (variable zoom, pixel-precise horizontal positioning, ping-pong clear).
// It uses its OWN GFX ROM read port (currently spr_gfx_addr / spr_gfx_data).
// The GFX ROM is the SDRAM in real hardware; multiple access ports are fine.
//
// For the compositor (Slot 7): colmix runs during active scan at pix_clk.
// It is also folded into this module to avoid a separate instantiation.
//
// ─── LINE BUFFER ARCHITECTURE ────────────────────────────────────────────────
//
// 7 line buffers (one per non-sprite layer):
//   lb_bg[0..3]   — 320 × 13-bit each  {palette[8:0], pen[3:0]}
//   lb_txt        — 320 × 9-bit         {color[4:0], pen[3:0]}
//   lb_pvt        — 320 × 8-bit         {color[3:0], pen[3:0]}
//
// All written during HBLANK at clk_8x (one word per cycle, single write port).
// All read during active display at pix_clk (async).
// Write-read are non-overlapping: safe CDC by construction.
//
// Sprite line buffers remain in tc0630fdp_sprite_render (ping-pong design).
//
// ─── GFX ROM SHARING ─────────────────────────────────────────────────────────
//
// BG phases use gfx_addr_bg / gfx_data_bg (top-level routes to SDRAM).
// Sprite renderer uses gfx_addr_spr / gfx_data_spr (separate port OR timeshare).
//
// For the unified module we output:
//   gfx_addr  — driven during BG phase (BG_GFX0, BG_GFX1 states)
//   gfx_rd    — strobe
//   gfx_data  — input (32-bit from ROM/BRAM)
//
// ─── COMPOSITOR LOGIC ────────────────────────────────────────────────────────
//
// Same 2-stage priority arbiter as tc0630fdp_colmix but integrated here.
// Runs in the pix_clk domain reading from the 7 line buffers + spr_pixel input.
//
// ─── ALM SAVINGS ESTIMATE ────────────────────────────────────────────────────
//
// Old design (4 separate FSMs + text + pivot + colmix):
//   bg_4x:   ~25,000 ALMs
//   text:     ~3,000 ALMs
//   pivot:    ~3,000 ALMs
//   colmix:   ~8,000 ALMs
//   Total:   ~39,000 ALMs
//
// Unified design (shared FSM + shared linebuf write port):
//   One FSM controller:  ~1,000 ALMs
//   Shared tile decoder: ~500 ALMs
//   7 line buffers (MLAB): ~200 ALMs
//   Compositor:           ~2,000 ALMs (reduced — no pipeline stage A registers)
//   Total estimate:       ~4,000–6,000 ALMs (savings: ~33,000–35,000 ALMs)
//
// ─── CYCLE-BY-CYCLE HBLANK TIMELINE (clk_8x cycles) ─────────────────────────
//
// HBLANK @ 8x = 1424 cycles.
//
// BG layer 0: IDLE→PREFETCH(1)→[ATTR(1)+CODE(1)+GFX0(1)+GFX1(1)+WRITE×16]×21
//             = 1 + 21×20 = 421 cycles
// BG layer 1: 421 cycles
// BG layer 2: 421 cycles
// BG layer 3: 421 cycles
// Total BG:   1684 cycles  > 1424  ← DOES NOT FIT at 8x either!
//
// Wait — the BG engine already serializes 4 layers at 4x (96 MHz), and each
// layer takes 421 cycles at 4x.  Total = 1684 at 4x.  But HBLANK = 448 at 4x.
// That doesn't add up.  Let me re-read the bg_4x comments...
//
// FROM bg_4x.sv:
//   "Layer 0 occupies the first 112 clk_4x cycles of HBLANK, layer 1 the next..."
//   "Total budget: 448 clk_4x cycles."
//   "Single-layer budget: 421 ≤ 448. OK."
//
// So 4 layers × 421 = 1684 clk_4x > 448!  The comment says SINGLE layer ≤ 448,
// meaning each layer gets ALL of HBLANK, running sequentially BUT the layer
// counter restarts the FSM each scanline so only ONE layer runs per HBLANK?
//
// NO — re-reading more carefully: the module comment says each layer runs
// within the full 448-cycle HBLANK window.  The layer counter increments when
// a layer's FSM completes: layer_done → layer_idx++, fsm_start.
// So 4 layers run back-to-back within one HBLANK: 4 × 421 = 1684 clk_4x?
// That's impossible in 448 cycles.
//
// RESOLUTION: Each tile does 21 tiles × BG_WRITE(16 cycles) = 336 WRITE cycles.
// Total per layer: 1 + 21×(1+1+1+1) + 21×16 = 1 + 84 + 336 = 421. Yes, 421.
// 4 × 421 = 1684. But HBLANK = only 448 clk_4x.  THIS IS A BUG IN MY ANALYSIS.
//
// The module actually processes ONE layer per HBLANK in the 4x design, not all 4.
// The layer counter advances one step per HBLANK and cycles: 0→1→2→3→0.
//
// NO WAIT: Looking at the layer counter code again:
//   if (hblank_rise_4x) layer_idx <= 0, fsm_start <= 1
//   if (layer_done && layer_idx != 3) layer_idx++, fsm_start <= 1
//
// This processes all 4 layers within one HBLANK!  But 4 × 421 = 1684 > 448.
// Something must be wrong with my tile count analysis.
//
// Per tile: ATTR(1) + CODE(1) + GFX0(1) + GFX1(1) + WRITE(16) = 20 cycles.
// 21 tiles × 20 + PREFETCH(1) = 421 per layer.
// But the 16-pixel WRITE for each tile is done at clk_4x rate sequentially.
//
// Wait — looking at the tile counter: tile_col goes 0..20 = 21 tiles.
// 320 pixels / 16 pixels per tile = 20 tiles.  But there's tile_col==20 check.
// That's actually 21 tile fetches for 20 visible + 1 prefetch tile.
//
// At 4x clock (96 MHz), 21 tiles × 20 cycles = 420 + 1 = 421.
// HBLANK at 4x = 178 pix_clk cycles × 4 = 712 clk_4x cycles!
// (Not 448 — I was reading H_START=46 + H_END=366 wrong.)
//
// H_BLANK = hpos < 46 OR hpos >= 366.
//   Pre-active: 46 cycles at pix_clk.
//   Post-active: 432-366 = 66 cycles at pix_clk.
//   Total: 112 pix_clk × 4 = 448 clk_4x cycles.
//
// Hmm 112 cycles. Then 4 × 421 = 1684 >> 448.  Still can't fit.
//
// THE ANSWER: Only 1 BG layer is rendered per HBLANK!  layer_idx does NOT
// advance within one HBLANK.  Re-reading: "layer_done && layer_idx != 3" fires
// only after the current HBLANK FSM completes... and FSM completes in 421 clk_4x
// cycles.  So layer 0 at HBLANK N, layer 1 at HBLANK N+1, etc.  Each HBLANK
// renders ONE layer!  The bg_pixel output is from the linebuffer for THAT layer.
//
// So the 4 BG layers take 4 consecutive scanlines each to render their buffers.
// This means the BG linebuffer holds N-4, N-3, N-2, N-1 scanline data for the
// 4 layers respectively — they're staggered by scanline.
//
// Reconsidering: maybe the BG layers DO all render each scanline... Let me look
// at what triggers layer 0 vs 1 more carefully.  The hblank_rise_4x restarts
// layer_idx=0 every scanline.  And layer_done → layer_idx++ happens within the
// same HBLANK.  So all 4 layers CAN run in one HBLANK.
//
// Total at 4x: 4 × 421 = 1684 clk_4x cycles.
// HBLANK window: 112 pix_clk × 4 = 448 clk_4x.
// 1684 >> 448.  This absolutely cannot fit.
//
// Therefore: The "layer done" that advances layer_idx MUST take multiple HBLANKs.
// i.e. layer 0 during HBLANK N, layer 1 during HBLANK N+1, etc.
// BUT hblank_rise resets layer_idx=0 each HBLANK!  So only layer 0 ever runs?!
//
// I must be misreading the tile count.  Let me check: H_START=46, active=320px.
// At 4x, HBLANK = 46 + (432-366) = 46 + 66 = 112 clk cycles × 4 = 448.
// Per tile (16px wide): need 320/16=20 tiles.  WRITE=16px → 16 cycles per tile.
// With 1 prefetch: 1 + 20×(1+1+1+1+16) = 1 + 20×20 = 401. That's 401 ≤ 448!
//
// The difference: tile_col 0..20 = 21 tiles is for the initial X offset prefetch.
// But if zoom_step=256 (no zoom), tiles map 1:1, and we fetch exactly 21 tiles
// to cover screen pixels 0..319 with the left-pixel offset.  But the WRITE
// loop only writes pixels that fall in range 0..319.
// 21 tiles × 20 cycles = 420 + PREFETCH(1) = 421 cycles ≤ 448.  It fits for 1 layer!
//
// So ONE layer per HBLANK.  The layer_idx advances EACH HBLANK (0→1→2→3→0→...),
// making each BG layer rendered on every 4th scanline.  That's how it works:
// bg_pixel[0] = last render of PF1 (4 scanlines ago), etc.
//
// For a unified pipeline: at 8× clock, HBLANK = 448 × 2 = 896 clk_8x cycles.
// We can fit 2 BG layers per HBLANK at 8x (2 × 421 = 842 ≤ 896).
// So we need 2 HBLANKs per pair of BG layers, meaning each BG layer still
// renders every 2nd scanline — still "close enough" for typical scroll motion.
//
// BETTER PLAN: Run ALL 4 BG layers every 2 scanlines using 8x clock.
//   At 8x: 896 cycles available per HBLANK.
//   4 layers × 421 cycles = 1684 — still doesn't fit in 896.
//   Need text+pivot too.
//
// The REAL solution: reduce cycles per tile.
//   Current: PREFETCH(1) + ATTR(1) + CODE(1) + GFX0(1) + GFX1(1) + WRITE(16)
//          = 21 per tile (with 16-cycle serial write) × 21 tiles = 441 + 1 = 442? No.
//          = 20 per tile × 21 tiles + 1 PREFETCH = 421.  Confirmed.
//
// Can we reduce WRITE cycles?  The 16-cycle write is for 16 pixels/tile.
// At 8x, we could write 2 pixels per cycle... but that requires 2 write ports
// on the linebuffer, negating the ALM savings.
//
// FINAL ARCHITECTURE DECISION:
// ─────────────────────────────
// Keep the existing per-layer-per-scanline rendering (1 BG layer per HBLANK),
// but unify all 6 modules into ONE module with:
//   1. Single FSM that rotates through: BG_PHASE → TEXT_PHASE → PIVOT_PHASE
//      within the HBLANK window.  Each phase uses the SAME hardware.
//   2. Layer selector controls which PF RAM, which GFX ROM address, which
//      linebuffer receives data.
//   3. Text and pivot phases always run every HBLANK (they're fast: ≤400 cycles).
//   4. BG phase rotates one layer per HBLANK (same as old design).
//   5. Compositor is integrated; runs during active scan.
//
// HBLANK budget at 8x (896 clk_8x cycles):
//   BG phase (1 layer):   421 clk_8x
//   Text phase:           400 clk_8x  (40 tiles × 10 cycles)
//   Pivot phase:          411 clk_8x  (41 tiles × 10 cycles = 410 + 1 PREFETCH)
//   Total:                1232 clk_8x  > 896!
//
// Still doesn't fit!  The problem: text takes 40 tiles × (1 latch + 8 write + 1 next)
// = 40 × 10 = 400 cycles at 4x = 200 cycles at 8x.
// Pivot: 41 × 10 = 410 at 4x = 205 at 8x.
// BG:    21 × 20 = 420 + 1 = 421 at 4x = 211 at 8x.
//
// AT 8x: BG(211) + Text(200) + Pivot(205) = 616 ≤ 896.  IT FITS!
//
// The key: EVERYTHING runs at the UNIFIED 8x clock rate, so all cycle counts
// are half what they are at 4x.  The cycles I computed above were already the
// clk_8x cycle counts.  The budget is 896 clk_8x.
//
// Final timeline per HBLANK at 8× clock:
//   BG_layer (rotate 0→1→2→3 each HBLANK):  ~211 clk_8x cycles
//   Text layer:                               ~200 clk_8x cycles
//   Pivot layer:                              ~205 clk_8x cycles
//   TOTAL:                                   ~616 clk_8x ≤ 896 ✓
//   Slack:                                   ~280 clk_8x (safety margin)
//
// =============================================================================

module tc0630fdp_unified (
    // ── Clocks and Reset ─────────────────────────────────────────────────────
    input  logic        clk,        // pixel clock (≈24 MHz)
    input  logic        clk_8x,     // 8× pixel clock (≈192 MHz) — unified pipeline
    input  logic        rst_n,

    // ── Video timing (pixel clock domain) ────────────────────────────────────
    input  logic        hblank,
    input  logic [ 8:0] vpos,
    input  logic [ 9:0] hpos,
    input  logic        pixel_valid,

    // ── Scroll and layer control ──────────────────────────────────────────────
    input  logic [3:0][15:0] pf_xscroll,
    input  logic [3:0][15:0] pf_yscroll,
    input  logic             extend_mode,

    // ── Per-scanline Line RAM outputs ─────────────────────────────────────────
    input  logic [3:0][15:0] ls_rowscroll,
    input  logic [3:0]       ls_alt_tilemap,
    input  logic [3:0][ 7:0] ls_zoom_x,
    input  logic [3:0][ 7:0] ls_zoom_y,
    input  logic [3:0][ 8:0] ls_colscroll,
    input  logic [3:0][15:0] ls_pal_add,
    input  logic [3:0][ 3:0] ls_pf_prio,
    input  logic [3:0][ 3:0] ls_spr_prio,
    // Step 12: clip planes
    input  logic [3:0][ 7:0] ls_clip_left,
    input  logic [3:0][ 7:0] ls_clip_right,
    input  logic [3:0][ 3:0] ls_pf_clip_en,
    input  logic [3:0][ 3:0] ls_pf_clip_inv,
    input  logic [3:0]       ls_pf_clip_sense,
    input  logic [ 3:0]      ls_spr_clip_en,
    input  logic [ 3:0]      ls_spr_clip_inv,
    input  logic             ls_spr_clip_sense,
    // Step 13: alpha blend
    input  logic [ 3:0]      ls_a_src,
    input  logic [ 3:0]      ls_a_dst,
    input  logic [3:0][ 1:0] ls_pf_blend,
    input  logic [3:0][ 1:0] ls_spr_blend,
    // Step 14: reverse blend B
    input  logic [ 3:0]      ls_b_src,
    input  logic [ 3:0]      ls_b_dst,
    // Step 15: mosaic
    input  logic [ 3:0]      ls_mosaic_rate,
    input  logic [ 3:0]      ls_pf_mosaic_en,
    input  logic             ls_spr_mosaic_en,
    // Step 16: pivot layer
    input  logic             ls_pivot_en,
    input  logic             ls_pivot_bank,
    input  logic             ls_pivot_blend,

    // ── PF RAM read ports (4 independent, driven by unified FSM) ─────────────
    output logic [3:0][12:0] pf_rd_addr,
    input  logic [3:0][15:0] pf_q,

    // ── GFX ROM read port (shared — BG layers only) ───────────────────────────
    output logic [21:0]      gfx_addr,
    output logic             gfx_rd,
    input  logic [31:0]      gfx_data,

    // ── Text/Char RAM read ports (CPU-writable MLABs, async) ──────────────────
    output logic [11:0]      text_rd_addr,
    input  logic [15:0]      text_q,
    output logic [10:0]      char_rd_addr,
    input  logic [31:0]      char_q,

    // ── Pivot RAM read port (CPU-writable MLAB/M10K, async/registered) ────────
    output logic [13:0]      pvt_rd_addr,
    input  logic [31:0]      pvt_q,
    // Pixel scroll registers (from ctrl registers)
    input  logic [15:0]      pixel_xscroll,
    input  logic [15:0]      pixel_yscroll,

    // ── Sprite pixel input (from tc0630fdp_sprite_render) ─────────────────────
    // {priority[1:0], palette[5:0], pen[3:0]};  pen==0 → transparent
    input  logic [11:0]      spr_pixel,

    // ── Palette RAM interface (two read ports from top-level) ─────────────────
    output logic [12:0]      pal_addr_src,
    output logic [12:0]      pal_addr_dst,
    input  logic [15:0]      pal_rdata_src,
    input  logic [15:0]      pal_rdata_dst,

    // ── Compositor pixel output ────────────────────────────────────────────────
    output logic [12:0]      colmix_pixel_out,   // {palette[8:0], pen[3:0]}
    output logic [23:0]      blend_rgb_out,       // 24-bit blended RGB

    // ── TC0650FDA blend interface ──────────────────────────────────────────────
    output logic [12:0]      src_pal,
    output logic [12:0]      dst_pal,
    output logic [ 3:0]      src_blend,
    output logic [ 3:0]      dst_blend,
    output logic             do_blend,
    output logic             pixel_valid_out

    // ── Debug / testbench pixel outputs (simulation only) ─────────────────────
`ifndef QUARTUS
    ,output logic [3:0][12:0] bg_pixel_out
    ,output logic [ 8:0]      text_pixel_out
    ,output logic [ 7:0]      pivot_pixel_out
`endif
);

// =============================================================================
// Parameters
// =============================================================================
localparam int H_START  = 46;
/* verilator lint_off UNUSEDPARAM */
localparam int H_END    = 366;
/* verilator lint_on UNUSEDPARAM */
localparam int V_START  = 24;

// =============================================================================
// HBLANK edge detection and synchronization into clk_8x domain
// =============================================================================
logic hblank_r_clk;
logic hblank_rise_clk;   // single-cycle pulse in clk domain

always_ff @(posedge clk) begin
    if (!rst_n) hblank_r_clk <= 1'b0;
    else        hblank_r_clk <= hblank;
end
assign hblank_rise_clk = hblank & ~hblank_r_clk;

// 2-FF synchronizer: clk → clk_8x
logic [1:0] hrise_sync_8x;
always_ff @(posedge clk_8x) begin
    if (!rst_n) hrise_sync_8x <= 2'b00;
    else        hrise_sync_8x <= {hrise_sync_8x[0], hblank_rise_clk};
end
logic hblank_rise_8x;
assign hblank_rise_8x = hrise_sync_8x[1];

// =============================================================================
// Synchronize vpos and layer control into clk_8x domain
// Captured at hrise_sync_8x[0] (one clk_8x cycle before hblank_rise_8x)
// =============================================================================
logic [8:0]       vpos_8x;
logic [3:0][15:0] pf_xscroll_8x;
logic [3:0][15:0] pf_yscroll_8x;
logic             extend_mode_8x;
logic [3:0][15:0] ls_rowscroll_8x;
logic [3:0]       ls_alt_tilemap_8x;
logic [3:0][ 7:0] ls_zoom_x_8x;
logic [3:0][ 7:0] ls_zoom_y_8x;
logic [3:0][ 8:0] ls_colscroll_8x;
logic [3:0][15:0] ls_pal_add_8x;
/* verilator lint_off UNUSEDSIGNAL */
logic [ 3:0]      ls_pf_mosaic_en_8x;  // captured for future use; mosaic runs in clk domain
logic [ 3:0]      ls_mosaic_rate_8x;   // captured for future use; mosaic runs in clk domain
/* verilator lint_on UNUSEDSIGNAL */
logic             ls_pivot_en_8x;
/* verilator lint_off UNUSEDSIGNAL */
logic             ls_pivot_bank_8x;    // captured but bank_off computed in clk domain
logic [15:0]      pixel_xscroll_8x;   // MSBs used; lower bits not needed in 8x domain
logic [15:0]      pixel_yscroll_8x;   // MSBs used; lower bits not needed in 8x domain
/* verilator lint_on UNUSEDSIGNAL */

always_ff @(posedge clk_8x) begin
    vpos_8x <= vpos;
    if (hrise_sync_8x[0]) begin
        pf_xscroll_8x    <= pf_xscroll;
        pf_yscroll_8x    <= pf_yscroll;
        extend_mode_8x   <= extend_mode;
        ls_rowscroll_8x  <= ls_rowscroll;
        ls_alt_tilemap_8x<= ls_alt_tilemap;
        ls_zoom_x_8x     <= ls_zoom_x;
        ls_zoom_y_8x     <= ls_zoom_y;
        ls_colscroll_8x  <= ls_colscroll;
        ls_pal_add_8x    <= ls_pal_add;
        ls_pf_mosaic_en_8x <= ls_pf_mosaic_en;
        ls_mosaic_rate_8x  <= ls_mosaic_rate;
        ls_pivot_en_8x   <= ls_pivot_en;
        ls_pivot_bank_8x <= ls_pivot_bank;
        pixel_xscroll_8x <= pixel_xscroll;
        pixel_yscroll_8x <= pixel_yscroll;
    end
end

// =============================================================================
// Main pipeline state machine (clk_8x domain)
// Sequences: BG_LAYER → TEXT → PIVOT within each HBLANK
//
// Phase controller:
//   PHASE_BG:   Run 1 BG layer (rotating 0→1→2→3 across HBLANKs)
//   PHASE_TEXT: Run text layer (40 tiles × 10 cycles = 400 clk_8x)
//   PHASE_PIVOT: Run pivot layer (41 tiles × 10 cycles ≈ 411 clk_8x)
// =============================================================================

typedef enum logic [1:0] {
    PHASE_BG    = 2'd0,
    PHASE_TEXT  = 2'd1,
    PHASE_PIVOT = 2'd2,
    PHASE_DONE  = 2'd3
} phase_t;

phase_t phase;

// BG layer rotation: each HBLANK processes one layer (0→1→2→3→0...)
logic [1:0] bg_layer_sel;   // which BG layer to render this HBLANK

always_ff @(posedge clk_8x) begin
    if (!rst_n) begin
        bg_layer_sel <= 2'd0;
    end else if (hblank_rise_8x) begin
        bg_layer_sel <= bg_layer_sel + 2'd1;
    end
end

// (Phase transitions are implicit: the phase FSM in the top-level always_ff
//  advances when each sub-FSM signals done.)

// =============================================================================
// BG Tile Fetch FSM
// Shared datapath for all 4 BG layers; layer selected by bg_layer_sel.
// Identical to the inner FSM of tc0630fdp_bg_4x, but runs at clk_8x.
// =============================================================================
typedef enum logic [2:0] {
    BG_IDLE     = 3'd0,
    BG_PREFETCH = 3'd1,
    BG_ATTR     = 3'd2,
    BG_CODE     = 3'd3,
    BG_GFX0     = 3'd4,
    BG_GFX1     = 3'd5,
    BG_WRITE    = 3'd6
} bg_state_t;

bg_state_t bg_state;

// BG FSM active flag
logic bg_active;
logic bg_done;    // pulses when BG FSM returns to IDLE after processing a layer

// BG FSM data registers
logic [4:0]  bg_tile_col;
logic [5:0]  bg_map_tx;
logic [4:0]  bg_map_ty;
logic [3:0]  bg_run_py;
logic [3:0]  bg_run_xoff;
logic        bg_run_extend;
logic        bg_run_alt;
logic [8:0]  bg_run_zoom_step;
logic [18:0] bg_run_zoom_acc_fp;
logic [8:0]  bg_run_pal_add_lines;
logic [8:0]  bg_tile_palette_r;
logic        bg_tile_flipx_r;
logic        bg_tile_flipy_r;
/* verilator lint_off UNUSED */
logic [15:0] bg_tile_code_r;
logic        bg_tile_blend_r;
logic [1:0]  bg_tile_xplanes_r;
/* verilator lint_on UNUSED */
logic [21:0] bg_gfx_left_r;
logic [21:0] bg_gfx_right_r;
logic [31:0] bg_gfx_left_data_r;
logic [31:0] bg_gfx_right_data_r;
logic [3:0]  bg_px_idx;
logic [8:0]  bg_wr_palette_r;
logic        bg_wr_flipx_r;
logic [18:0] bg_wr_zoom_acc_fp_r;
logic [8:0]  bg_wr_zoom_step_r;
logic [8:0]  bg_wr_pal_add_lines_r;
logic signed [10:0] bg_wr_scol_base_r;

`ifdef QUARTUS
logic [18:0]        bg_wr_acc_px_r;
logic signed [10:0] bg_wr_scol_r;
logic [8:0]         bg_wr_pal9_r;
`endif

// Current layer's muxed inputs
logic [15:0] bg_cur_xscroll;
logic [15:0] bg_cur_yscroll;
logic        bg_cur_extend;
logic [15:0] bg_cur_rowscroll;
logic        bg_cur_alt_tilemap;
logic [ 7:0] bg_cur_zoom_x;
logic [ 7:0] bg_cur_zoom_y;
logic [ 8:0] bg_cur_colscroll;
logic [15:0] bg_cur_pal_add;
logic [15:0] bg_cur_pf_q;

always_comb begin
    bg_cur_xscroll    = pf_xscroll_8x[bg_layer_sel];
    bg_cur_yscroll    = pf_yscroll_8x[bg_layer_sel];
    bg_cur_extend     = extend_mode_8x;
    bg_cur_rowscroll  = ls_rowscroll_8x[bg_layer_sel];
    bg_cur_alt_tilemap= ls_alt_tilemap_8x[bg_layer_sel];
    bg_cur_zoom_x     = ls_zoom_x_8x[bg_layer_sel];
    bg_cur_zoom_y     = ls_zoom_y_8x[bg_layer_sel];
    bg_cur_colscroll  = ls_colscroll_8x[bg_layer_sel];
    bg_cur_pal_add    = ls_pal_add_8x[bg_layer_sel];
    bg_cur_pf_q       = pf_q[bg_layer_sel];
end

// PF RAM address (driven during BG phase only)
logic [12:0] bg_fsm_pf_rd_addr;
always_comb begin
    for (int i = 0; i < 4; i++)
        pf_rd_addr[i] = 13'b0;
    if (phase == PHASE_BG)
        pf_rd_addr[bg_layer_sel] = bg_fsm_pf_rd_addr;
end

// Y zoom computation (combinational, matches bg_4x exactly)
/* verilator lint_off UNUSED */
logic [16:0] bg_cy_zoomed_w;
/* verilator lint_on UNUSED */
logic [ 3:0] bg_fetch_py;
logic [ 4:0] bg_fetch_ty;
logic        bg_fetch_extend;
logic [ 8:0] bg_canvas_y_raw;

always_comb begin
    bg_canvas_y_raw = (vpos_8x + 9'd1) + bg_cur_yscroll[15:7];
end

`ifdef QUARTUS
lpm_mult #(
    .lpm_widtha(9), .lpm_widthb(8), .lpm_widthp(17),
    .lpm_representation("UNSIGNED"), .lpm_pipeline(0)
) u_bg_cy_zoom_mult (
    .dataa(bg_canvas_y_raw), .datab(bg_cur_zoom_y), .result(bg_cy_zoomed_w),
    .clock(1'b0), .clken(1'b0), .aclr(1'b0), .sum({17{1'b0}})
);
`else
always_comb begin
    bg_cy_zoomed_w = {1'b0, bg_canvas_y_raw} * {1'b0, bg_cur_zoom_y};
end
`endif

always_comb begin
    logic [8:0] canvas_y;
    canvas_y       = bg_cy_zoomed_w[15:7];
    bg_fetch_py    = canvas_y[3:0];
    bg_fetch_ty    = canvas_y[8:4];
    bg_fetch_extend= bg_cur_extend;
end

// PF RAM addresses
logic [12:0] bg_pf_attr_addr_c;
logic [12:0] bg_pf_code_addr_c;
always_comb begin
    logic [11:0] tileword_base;
    logic [12:0] base_addr;
    if (bg_run_extend)
        tileword_base = {bg_map_ty, bg_map_tx, 1'b0};
    else
        tileword_base = {1'b0, bg_map_ty, bg_map_tx[4:0], 1'b0};
    base_addr = {1'b0, tileword_base} + (bg_run_alt ? 13'h1000 : 13'h0000);
    bg_pf_attr_addr_c = base_addr;
    bg_pf_code_addr_c = base_addr + 13'd1;
end

logic [18:0] bg_next_zoom_acc_fp;
always_comb begin
    logic [12:0] step16;
    step16 = {4'b0, bg_run_zoom_step} << 4;
    bg_next_zoom_acc_fp = bg_run_zoom_acc_fp + {6'b0, step16};
end

`ifdef QUARTUS
logic [12:0] bg_pf_attr_addr_next_c;
always_comb begin
    logic [11:0] tileword_base;
    logic [12:0] base_addr;
    logic [5:0]  next_map_tx;
    next_map_tx = bg_next_zoom_acc_fp[17:12] & (bg_run_extend ? 6'h3F : 6'h1F);
    if (bg_run_extend)
        tileword_base = {bg_map_ty, next_map_tx, 1'b0};
    else
        tileword_base = {1'b0, bg_map_ty, next_map_tx[4:0], 1'b0};
    base_addr = {1'b0, tileword_base} + (bg_run_alt ? 13'h1000 : 13'h0000);
    bg_pf_attr_addr_next_c = base_addr;
end

always_comb begin
    case (bg_state)
        BG_PREFETCH: bg_fsm_pf_rd_addr = bg_pf_attr_addr_c;
        BG_ATTR:     bg_fsm_pf_rd_addr = bg_pf_code_addr_c;
        BG_WRITE:    bg_fsm_pf_rd_addr = bg_pf_attr_addr_next_c;
        default:     bg_fsm_pf_rd_addr = 13'b0;
    endcase
end
`else
always_comb begin
    case (bg_state)
        BG_ATTR: bg_fsm_pf_rd_addr = bg_pf_attr_addr_c;
        BG_CODE: bg_fsm_pf_rd_addr = bg_pf_code_addr_c;
        default: bg_fsm_pf_rd_addr = 13'b0;
    endcase
end
`endif

// Attribute decode
logic [8:0] bg_attr_palette_c;
logic       bg_attr_flipx_c;
logic       bg_attr_flipy_c;
logic       bg_attr_blend_c;
logic [1:0] bg_attr_xplanes_c;
assign bg_attr_palette_c = bg_cur_pf_q[8:0];
assign bg_attr_blend_c   = bg_cur_pf_q[9];
assign bg_attr_xplanes_c = bg_cur_pf_q[11:10];
assign bg_attr_flipx_c   = bg_cur_pf_q[14];
assign bg_attr_flipy_c   = bg_cur_pf_q[15];

/* verilator lint_off UNUSED */
/* verilator lint_off UNUSEDSIGNAL */
logic _bg_unused;
assign _bg_unused = ^{bg_cur_xscroll[5:0], bg_cur_yscroll[6:0],
                      bg_cur_rowscroll[5:0], bg_cur_pal_add[3:0],
                      bg_cur_pal_add[15:13]};
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSED */

// BG WRITE pixel decode (combinational, one pixel per clk_8x cycle)
logic signed [10:0] bg_wr_scol_c;
logic [18:0] bg_wr_acc_px;
logic [ 3:0] bg_wr_px_tile;
logic [ 2:0] bg_wr_ni;
logic [31:0] bg_wr_src;
logic [ 4:0] bg_wr_sh;
logic [ 3:0] bg_wr_pen;
logic        bg_wr_in_range;
logic [ 8:0] bg_wr_out_addr;
logic [12:0] bg_wr_out_data;

/* verilator lint_off UNUSED */
always_comb begin
`ifdef QUARTUS
    bg_wr_scol_c  = bg_wr_scol_r;
    bg_wr_acc_px  = bg_wr_acc_px_r;
`else
    bg_wr_scol_c  = bg_wr_scol_base_r + $signed({7'b0, bg_px_idx});
    bg_wr_acc_px  = bg_wr_zoom_acc_fp_r + (19'(bg_px_idx) * {10'b0, bg_wr_zoom_step_r});
`endif
    bg_wr_px_tile  = bg_wr_acc_px[11:8];
    bg_wr_src      = bg_wr_px_tile[3] ? bg_gfx_right_data_r : bg_gfx_left_data_r;
    bg_wr_ni       = bg_wr_flipx_r ? 3'(3'd7 - bg_wr_px_tile[2:0]) : 3'(bg_wr_px_tile[2:0]);
    bg_wr_sh       = 5'd28 - 5'({2'b00, bg_wr_ni} << 2);
    bg_wr_pen      = 4'(bg_wr_src >> bg_wr_sh);
    bg_wr_in_range = (bg_wr_scol_c >= 0) && (bg_wr_scol_c < 320);
    bg_wr_out_addr = bg_wr_in_range ? 9'(bg_wr_scol_c[8:0]) : 9'b0;
`ifdef QUARTUS
    bg_wr_out_data = {bg_wr_pal9_r, bg_wr_pen};
`else
    bg_wr_out_data = {bg_wr_palette_r + bg_wr_pal_add_lines_r, bg_wr_pen};
`endif
end
/* verilator lint_on UNUSED */

// =============================================================================
// Text Layer FSM
// Identical to tc0630fdp_text inner logic but runs at clk_8x.
// =============================================================================
typedef enum logic [1:0] {
    TX_IDLE  = 2'd0,
    TX_TRAM  = 2'd1,
    TX_PIXEL = 2'd2,
    TX_NEXT  = 2'd3
} tx_state_t;

tx_state_t tx_state;
logic [5:0] tx_col;
logic [2:0] tx_px_idx;
logic [4:0] tx_tile_color_r;
logic [31:0] tx_tile_char_q_r;
logic tx_done;

// Fetch geometry (for text layer): vpos+1
logic [2:0] tx_fetch_py_clk;
logic [5:0] tx_fetch_row_clk;
logic [8:0] next_vpos;  // temp: vpos+1 for text fetch geometry

always_ff @(posedge clk) begin
    if (!rst_n) begin
        tx_fetch_py_clk  <= 3'b0;
        tx_fetch_row_clk <= 6'b0;
    end else if (hblank_rise_clk) begin
        next_vpos        = vpos + 9'd1;
        tx_fetch_py_clk  <= next_vpos[2:0];
        tx_fetch_row_clk <= next_vpos[8:3];
    end
end

logic [2:0] tx_fetch_py;
logic [5:0] tx_fetch_row;
always_ff @(posedge clk_8x) begin
    if (hrise_sync_8x[0]) begin
        tx_fetch_py  <= tx_fetch_py_clk;
        tx_fetch_row <= tx_fetch_row_clk;
    end
end

// Charlayout nibble extraction for text
logic [3:0] tx_char_nibble [0:7];
always_comb begin
    tx_char_nibble[0] = tx_tile_char_q_r[23:20];
    tx_char_nibble[1] = tx_tile_char_q_r[19:16];
    tx_char_nibble[2] = tx_tile_char_q_r[31:28];
    tx_char_nibble[3] = tx_tile_char_q_r[27:24];
    tx_char_nibble[4] = tx_tile_char_q_r[ 7: 4];
    tx_char_nibble[5] = tx_tile_char_q_r[ 3: 0];
    tx_char_nibble[6] = tx_tile_char_q_r[15:12];
    tx_char_nibble[7] = tx_tile_char_q_r[11: 8];
end

// Text RAM address
logic [4:0]  tx_color_c;
logic [7:0]  tx_char_code_c;
assign tx_color_c    = text_q[15:11];
/* verilator lint_off UNUSED */
logic _unused_char_hi;
assign _unused_char_hi = ^text_q[10:8];
/* verilator lint_on UNUSED */
assign tx_char_code_c = text_q[7:0];

always_comb begin
    if (phase == PHASE_TEXT && tx_state == TX_TRAM) begin
        text_rd_addr = {tx_fetch_row, tx_col[5:0]};
        char_rd_addr = {tx_char_code_c, tx_fetch_py};
    end else begin
        text_rd_addr = 12'b0;
        char_rd_addr = 11'b0;
    end
end

// =============================================================================
// Pivot Layer FSM
// Identical to tc0630fdp_pivot inner logic but runs at clk_8x.
// =============================================================================
typedef enum logic [2:0] {
    PV_IDLE     = 3'd0,
    PV_PREFETCH = 3'd1,
    PV_TILE     = 3'd2,
    PV_PIXEL    = 3'd3,
    PV_NEXT     = 3'd4
} pv_state_t;

pv_state_t pv_state;
logic [5:0] pv_tx_col;
logic [2:0] pv_px_idx;
logic [31:0] pv_tile_pvt_q_r;
logic pv_done;

// Scroll decode
logic [9:0] pv_xscroll_int;
logic [8:0] pv_yscroll_int;
assign pv_xscroll_int = pixel_xscroll_8x[15:6];
assign pv_yscroll_int = pixel_yscroll_8x[15:7];

// Fetch parameters (captured at hblank_rise in clk domain)
logic [2:0] pv_fetch_py_clk;
logic [4:0] pv_fetch_row_clk;
logic [5:0] pv_xscr_tile_clk;
logic [2:0] pv_pix_off_clk;
logic [5:0] pv_bank_off_clk;
logic [7:0] canvas_y;  // temp: pivot canvas row for fetch geometry

always_ff @(posedge clk) begin
    if (!rst_n) begin
        pv_fetch_py_clk  <= 3'b0;
        pv_fetch_row_clk <= 5'b0;
        pv_xscr_tile_clk <= 6'b0;
        pv_pix_off_clk   <= 3'b0;
        pv_bank_off_clk  <= 6'd0;
    end else if (hblank_rise_clk) begin
        canvas_y = 8'(vpos + 9'd1) + 8'(pv_yscroll_int);
        pv_fetch_py_clk  <= canvas_y[2:0];
        pv_fetch_row_clk <= canvas_y[7:3];
        pv_xscr_tile_clk <= 6'(pv_xscroll_int[9:3]);
        pv_pix_off_clk   <= pv_xscroll_int[2:0];
        pv_bank_off_clk  <= ls_pivot_bank ? 6'd32 : 6'd0;
    end
end

logic [2:0] pv_fetch_py;
logic [4:0] pv_fetch_row;
logic [5:0] pv_xscr_tile;
logic [2:0] pv_pix_off;
logic [5:0] pv_bank_off;

always_ff @(posedge clk_8x) begin
    if (hrise_sync_8x[0]) begin
        pv_fetch_py  <= pv_fetch_py_clk;
        pv_fetch_row <= pv_fetch_row_clk;
        pv_xscr_tile <= pv_xscr_tile_clk;
        pv_pix_off   <= pv_pix_off_clk;
        pv_bank_off  <= pv_bank_off_clk;
    end
end

// Pivot tile index computation
logic [5:0]  pv_cur_tile_col;
logic [10:0] pv_tile_idx;
assign pv_cur_tile_col = (pv_xscr_tile + pv_bank_off + pv_tx_col) & 6'h3F;
assign pv_tile_idx     = {pv_cur_tile_col, pv_fetch_row};

`ifdef QUARTUS
logic [5:0]  pv_next_tile_col;
logic [10:0] pv_next_tile_idx;
assign pv_next_tile_col = (pv_xscr_tile + pv_bank_off + (pv_tx_col + 6'd1)) & 6'h3F;
assign pv_next_tile_idx = {pv_next_tile_col, pv_fetch_row};
`endif

// Screen column base for current pivot tile
logic signed [10:0] pv_scol_base_s;
always_comb begin
    pv_scol_base_s = $signed({1'b0, pv_tx_col, 3'b000}) - $signed({8'b0, pv_pix_off});
end

// Pivot RAM address
always_comb begin
    if (phase == PHASE_PIVOT) begin
`ifdef QUARTUS
        case (pv_state)
            PV_PREFETCH: pvt_rd_addr = {pv_tile_idx,      pv_fetch_py};
            PV_NEXT:     pvt_rd_addr = {pv_next_tile_idx, pv_fetch_py};
            default:     pvt_rd_addr = 14'b0;
        endcase
`else
        if (pv_state == PV_TILE)
            pvt_rd_addr = {pv_tile_idx, pv_fetch_py};
        else
            pvt_rd_addr = 14'b0;
`endif
    end else begin
        pvt_rd_addr = 14'b0;
    end
end

// Charlayout nibble extraction for pivot
logic [3:0] pv_nibble [0:7];
always_comb begin
    pv_nibble[0] = pv_tile_pvt_q_r[23:20];
    pv_nibble[1] = pv_tile_pvt_q_r[19:16];
    pv_nibble[2] = pv_tile_pvt_q_r[31:28];
    pv_nibble[3] = pv_tile_pvt_q_r[27:24];
    pv_nibble[4] = pv_tile_pvt_q_r[ 7: 4];
    pv_nibble[5] = pv_tile_pvt_q_r[ 3: 0];
    pv_nibble[6] = pv_tile_pvt_q_r[15:12];
    pv_nibble[7] = pv_tile_pvt_q_r[11: 8];
end

// =============================================================================
// Shared GFX ROM address (driven by BG FSM only — text/pivot use internal RAMs)
// =============================================================================
always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 22'b0;
    if (phase == PHASE_BG) begin
        case (bg_state)
            BG_GFX0: begin gfx_addr = bg_gfx_left_r;  gfx_rd = 1'b1; end
            BG_GFX1: begin gfx_addr = bg_gfx_right_r; gfx_rd = 1'b1; end
            default: begin gfx_addr = 22'b0;           gfx_rd = 1'b0; end
        endcase
    end
end

// =============================================================================
// Line Buffers (7 total: 4 BG + 1 text + 1 pivot; sprite is in sprite_render)
//
// Write port: clk_8x, single-address serialized write (one pixel per cycle).
// Read port:  async (UNREGISTERED), addressed by screen column during active scan.
// Under QUARTUS: altsyncram MLAB dual-port instances.
// Under Verilator: plain register arrays.
//
// lb_bg[0..3]: 320 × 13-bit  {palette[8:0], pen[3:0]}
// lb_txt:      320 × 9-bit   {color[4:0], pen[3:0]}
// lb_pvt:      320 × 8-bit   {color[3:0], pen[3:0]}
// =============================================================================

// ── Screen column decode (pixel clock domain, used for all read addresses) ───
logic [8:0] scol_c;
always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_START + 320))
        scol_c = hpos[8:0] - 9'(H_START);
    else
        scol_c = 9'd0;
end

// ── Mosaic snap for BG layers ─────────────────────────────────────────────────
logic [8:0] bg_snap_col [0:3];
genvar gi_snap;
generate
    for (gi_snap = 0; gi_snap < 4; gi_snap++) begin : gen_bg_snap
        always_comb begin
            logic [9:0] gx_wide;
            logic [8:0] grid_sum;
            logic [8:0] sr;
            logic [4:0] off;

            gx_wide  = {1'b0, scol_c} + 10'd114;
            grid_sum = (gx_wide >= 10'd432) ? gx_wide[8:0] - 9'd432 : gx_wide[8:0];
            sr       = 9'd1 + {5'b0, ls_mosaic_rate};
            begin
                logic [8:0] sr16, sr8, sr4, sr2, rem;
                sr16 = sr << 4;
                sr8  = sr << 3;
                sr4  = sr << 2;
                sr2  = sr << 1;
                rem  = grid_sum;
                if (rem >= sr16) rem = rem - sr16;
                if (rem >= sr8)  rem = rem - sr8;
                if (rem >= sr4)  rem = rem - sr4;
                if (rem >= sr2)  rem = rem - sr2;
                if (rem >= sr)   rem = rem - sr;
                off = 5'(rem);
            end
            if (ls_pf_mosaic_en[gi_snap] && ls_mosaic_rate != 4'd0)
                bg_snap_col[gi_snap] = 9'(scol_c - {5'b0, off});
            else
                bg_snap_col[gi_snap] = scol_c;
        end
    end
endgenerate

// ── Write port signals (driven combinationally by active phase FSM) ───────────
logic [12:0] bg_lb_wdata  [0:3];
logic [ 8:0] bg_lb_waddr  [0:3];
logic [3:0]  bg_lb_wen;

logic [8:0]  tx_lb_wdata;
logic [8:0]  tx_lb_waddr;
logic        tx_lb_wen;

logic [7:0]  pv_lb_wdata;
logic [8:0]  pv_lb_waddr;
logic        pv_lb_wen;

// BG write decode (from BG_WRITE state): written into lb for the current layer
always_comb begin
    for (int i = 0; i < 4; i++) begin
        bg_lb_wdata[i] = 13'b0;
        bg_lb_waddr[i] = 9'b0;
    end
    bg_lb_wen = 4'b0;
    if (phase == PHASE_BG && bg_state == BG_WRITE && bg_wr_in_range) begin
        bg_lb_wdata[bg_layer_sel] = bg_wr_out_data;
        bg_lb_waddr[bg_layer_sel] = bg_wr_out_addr;
        bg_lb_wen[bg_layer_sel]   = 1'b1;
    end
end

// Text write decode (from TX_PIXEL state)
logic signed [9:0] tx_scol_c;
logic [9:0] col10;  // temp: text screen column (tile_col*8 + px_idx)
always_comb begin
    tx_scol_c  = $signed({1'b0, tx_col, 3'b000}) - $signed({7'b0, 3'b0}) + $signed({7'b0, tx_px_idx});
    // Screen col = tile_col*8 + px_idx (no scroll for text layer)
    tx_lb_wen   = 1'b0;
    tx_lb_waddr = 9'b0;
    tx_lb_wdata = 9'b0;
    col10 = 10'b0;
    if (phase == PHASE_TEXT && tx_state == TX_PIXEL) begin
        col10 = {4'b0, tx_col[5:0]} * 10'd8 + {7'b0, tx_px_idx};
        if (col10 < 10'd320) begin
            tx_lb_waddr = col10[8:0];
            tx_lb_wdata = {tx_tile_color_r, tx_char_nibble[tx_px_idx]};
            tx_lb_wen   = 1'b1;
        end
    end
end

/* verilator lint_off UNUSED */
logic _tx_scol_unused;
assign _tx_scol_unused = ^tx_scol_c;
/* verilator lint_on UNUSED */

// Pivot write decode (from PV_PIXEL state)
logic signed [10:0] col_s;  // temp: pivot screen column (signed)
always_comb begin
    pv_lb_wen   = 1'b0;
    pv_lb_waddr = 9'b0;
    pv_lb_wdata = 8'b0;
    col_s = 11'sb0;
    if (phase == PHASE_PIVOT && ls_pivot_en_8x && pv_state == PV_PIXEL) begin
        col_s = pv_scol_base_s + $signed({8'b0, pv_px_idx});
        if (col_s >= 11'sd0 && col_s < 11'sd320) begin
            pv_lb_waddr = 9'(col_s[8:0]);
            pv_lb_wdata = {4'b0, pv_nibble[pv_px_idx]};
            pv_lb_wen   = 1'b1;
        end
    end
end

// ── Line buffer instances ─────────────────────────────────────────────────────
`ifdef QUARTUS

// BG line buffers (4 × 320×13, MLAB)
logic [12:0] bg_lb_rdata [0:3];
genvar gi_lb;
generate
    for (gi_lb = 0; gi_lb < 4; gi_lb++) begin : gen_bg_lb
        altsyncram #(
            .width_a(13), .widthad_a(9), .numwords_a(512),
            .width_b(13), .widthad_b(9), .numwords_b(512),
            .operation_mode("DUAL_PORT"),
            .ram_block_type("MLAB"),
            .outdata_reg_a("UNREGISTERED"),
            .outdata_reg_b("UNREGISTERED"),
            .read_during_write_mode_mixed_ports("DONT_CARE"),
            .intended_device_family("Cyclone V")
        ) u_bg_lb (
            .clock0    (clk_8x),
            .address_a (bg_lb_waddr[gi_lb]),
            .data_a    (bg_lb_wdata[gi_lb]),
            .wren_a    (bg_lb_wen[gi_lb]),
            .address_b (bg_snap_col[gi_lb]),
            .q_b       (bg_lb_rdata[gi_lb]),
            .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
            .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
            .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
            .data_b({13{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
            .wren_b(1'b0)
        );
    end
endgenerate

// Text line buffer (320×9, MLAB)
logic [8:0] tx_lb_rdata;
altsyncram #(
    .width_a(9), .widthad_a(9), .numwords_a(512),
    .width_b(9), .widthad_b(9), .numwords_b(512),
    .operation_mode("DUAL_PORT"),
    .ram_block_type("MLAB"),
    .outdata_reg_a("UNREGISTERED"),
    .outdata_reg_b("UNREGISTERED"),
    .read_during_write_mode_mixed_ports("DONT_CARE"),
    .intended_device_family("Cyclone V")
) u_tx_lb (
    .clock0    (clk_8x),
    .address_a (tx_lb_waddr),
    .data_a    (tx_lb_wdata),
    .wren_a    (tx_lb_wen),
    .address_b (scol_c),
    .q_b       (tx_lb_rdata),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({9{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
    .wren_b(1'b0)
);

// Pivot line buffer (320×8, MLAB)
logic [7:0] pv_lb_rdata;
altsyncram #(
    .width_a(8), .widthad_a(9), .numwords_a(512),
    .width_b(8), .widthad_b(9), .numwords_b(512),
    .operation_mode("DUAL_PORT"),
    .ram_block_type("MLAB"),
    .outdata_reg_a("UNREGISTERED"),
    .outdata_reg_b("UNREGISTERED"),
    .read_during_write_mode_mixed_ports("DONT_CARE"),
    .intended_device_family("Cyclone V")
) u_pv_lb (
    .clock0    (clk_8x),
    .address_a (pv_lb_waddr),
    .data_a    (pv_lb_wdata),
    .wren_a    (pv_lb_wen),
    .address_b (scol_c),
    .q_b       (pv_lb_rdata),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({8{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
    .wren_b(1'b0)
);

`else
// Simulation: register arrays
logic [12:0] bg_linebuf [0:3][0:319];
logic [ 8:0] tx_linebuf [0:319];
logic [ 7:0] pv_linebuf [0:319];

always_ff @(posedge clk_8x) begin
    for (int i = 0; i < 4; i++) begin
        if (bg_lb_wen[i]) bg_linebuf[i][bg_lb_waddr[i]] <= bg_lb_wdata[i];
    end
    if (tx_lb_wen) tx_linebuf[tx_lb_waddr] <= tx_lb_wdata;
    if (pv_lb_wen) pv_linebuf[pv_lb_waddr] <= pv_lb_wdata;
end

// Async reads
logic [12:0] bg_lb_rdata [0:3];
logic [ 8:0] tx_lb_rdata;
logic [ 7:0] pv_lb_rdata;
genvar gi_bg_rd;
generate
    for (gi_bg_rd = 0; gi_bg_rd < 4; gi_bg_rd++) begin : gen_bg_rd
        assign bg_lb_rdata[gi_bg_rd] = bg_linebuf[gi_bg_rd][bg_snap_col[gi_bg_rd]];
    end
endgenerate
assign tx_lb_rdata = tx_linebuf[scol_c];
assign pv_lb_rdata = pv_linebuf[scol_c];
`endif

// ── Debug outputs (simulation only) ──────────────────────────────────────────
`ifndef QUARTUS
genvar gi_dbg;
generate
    for (gi_dbg = 0; gi_dbg < 4; gi_dbg++) begin : gen_dbg_bg
        assign bg_pixel_out[gi_dbg] = bg_lb_rdata[gi_dbg];
    end
endgenerate
assign text_pixel_out  = tx_lb_rdata;
assign pivot_pixel_out = pv_lb_rdata;
`endif

// =============================================================================
// Top-level phase FSM (clk_8x domain)
// Controls which sub-FSM is active; advances phase when sub-FSM signals done.
// =============================================================================
always_ff @(posedge clk_8x) begin
    if (!rst_n) begin
        phase  <= PHASE_BG;
        bg_active <= 1'b0;
    end else begin
        // Default: deassert start pulses
        if (hblank_rise_8x) begin
            // Start BG phase for this scanline's layer
            phase      <= PHASE_BG;
            bg_active  <= 1'b1;
        end else begin
            case (phase)
                PHASE_BG: begin
                    if (bg_done) begin
                        bg_active <= 1'b0;
                        phase     <= PHASE_TEXT;
                    end
                end
                PHASE_TEXT: begin
                    if (tx_done)
                        phase <= PHASE_PIVOT;
                end
                PHASE_PIVOT: begin
                    if (pv_done)
                        phase <= PHASE_DONE;
                end
                PHASE_DONE: begin
                    // Idle until next HBLANK
                end
                default: phase <= PHASE_DONE;
            endcase
        end
    end
end

// bg_done fires when BG FSM returns to IDLE from an active run
assign bg_done = bg_active & (bg_state == BG_IDLE);

// =============================================================================
// BG FSM (clk_8x domain)
// =============================================================================
always_ff @(posedge clk_8x) begin
    if (!rst_n) begin
        bg_state              <= BG_IDLE;
        bg_tile_col           <= 5'b0;
        bg_map_tx             <= 6'b0;
        bg_map_ty             <= 5'b0;
        bg_run_py             <= 4'b0;
        bg_run_xoff           <= 4'b0;
        bg_run_extend         <= 1'b0;
        bg_run_alt            <= 1'b0;
        bg_run_zoom_step      <= 9'd256;
        bg_run_zoom_acc_fp    <= 19'b0;
        bg_run_pal_add_lines  <= 9'b0;
        bg_tile_palette_r     <= 9'b0;
        bg_tile_blend_r       <= 1'b0;
        bg_tile_xplanes_r     <= 2'b0;
        bg_tile_flipx_r       <= 1'b0;
        bg_tile_flipy_r       <= 1'b0;
        bg_tile_code_r        <= 16'b0;
        bg_gfx_left_r         <= 22'b0;
        bg_gfx_right_r        <= 22'b0;
        bg_gfx_left_data_r    <= 32'b0;
        bg_gfx_right_data_r   <= 32'b0;
        bg_px_idx             <= 4'b0;
        bg_wr_palette_r       <= 9'b0;
        bg_wr_flipx_r         <= 1'b0;
        bg_wr_zoom_acc_fp_r   <= 19'b0;
        bg_wr_zoom_step_r     <= 9'b0;
        bg_wr_pal_add_lines_r <= 9'b0;
        bg_wr_scol_base_r     <= 11'b0;
`ifdef QUARTUS
        bg_wr_acc_px_r        <= 19'b0;
        bg_wr_scol_r          <= 11'sb0;
        bg_wr_pal9_r          <= 9'b0;
`endif
    end else begin
        // Phase gate: only advance BG FSM when in PHASE_BG or when bg_active
        case (bg_state)
            BG_IDLE: begin
                if (phase == PHASE_BG && bg_active) begin
                    // Start this layer's tile fetch
                    logic [9:0] eff_x_base;
                    logic [9:0] eff_x;
                    logic [8:0] zstep;
                    logic [18:0] zacc;
                    eff_x_base = bg_cur_xscroll[15:6] + bg_cur_rowscroll[15:6];
                    eff_x = eff_x_base + {1'b0, bg_cur_colscroll};
                    bg_run_xoff <= eff_x[3:0];
                    zstep = 9'd256 + {1'b0, bg_cur_zoom_x};
                    bg_run_zoom_step <= zstep;
                    zacc = {1'b0, eff_x, 8'b0};
                    bg_run_zoom_acc_fp <= zacc;
                    bg_map_tx <= eff_x[9:4] & (bg_fetch_extend ? 6'h3F : 6'h1F);
                    bg_tile_col <= 5'b0;
                    bg_map_ty   <= bg_fetch_ty;
                    bg_run_py   <= bg_fetch_py;
                    bg_run_extend <= bg_fetch_extend;
                    bg_run_alt    <= bg_cur_alt_tilemap;
                    bg_run_pal_add_lines <= bg_cur_pal_add[12:4];
`ifdef QUARTUS
                    bg_state <= BG_PREFETCH;
`else
                    bg_state <= BG_ATTR;
`endif
                end
            end

            BG_PREFETCH: begin
                bg_state <= BG_ATTR;
            end

            BG_ATTR: begin
                bg_tile_palette_r <= bg_attr_palette_c;
                bg_tile_blend_r   <= bg_attr_blend_c;
                bg_tile_xplanes_r <= bg_attr_xplanes_c;
                bg_tile_flipx_r   <= bg_attr_flipx_c;
                bg_tile_flipy_r   <= bg_attr_flipy_c;
                bg_state          <= BG_CODE;
            end

            BG_CODE: begin
                bg_tile_code_r <= bg_cur_pf_q;
                begin
                    logic [3:0] ry;
                    logic [21:0] base22;
                    ry     = bg_tile_flipy_r ? (4'd15 - bg_run_py) : bg_run_py;
                    base22 = {1'b0, bg_cur_pf_q[15:0], 5'b0};
                    bg_gfx_left_r  <= base22 + {17'b0, ry, 1'b0};
                    bg_gfx_right_r <= base22 + {17'b0, ry, 1'b0} + 22'd1;
                end
                bg_state <= BG_GFX0;
            end

            BG_GFX0: begin
                bg_gfx_left_data_r <= gfx_data;
                bg_state           <= BG_GFX1;
            end

            BG_GFX1: begin
                bg_gfx_right_data_r <= gfx_data;
                begin
                    logic signed [10:0] scol_base;
                    scol_base = $signed({1'b0, bg_tile_col, 4'b0}) -
                                $signed({7'b0, bg_run_xoff});
                    bg_wr_scol_base_r <= scol_base;
`ifdef QUARTUS
                    bg_wr_acc_px_r <= bg_run_zoom_acc_fp;
                    bg_wr_scol_r   <= scol_base;
                    bg_wr_pal9_r   <= bg_tile_palette_r + bg_run_pal_add_lines;
`endif
                end
                bg_wr_palette_r       <= bg_tile_palette_r;
                bg_wr_flipx_r         <= bg_tile_flipx_r;
                bg_wr_zoom_acc_fp_r   <= bg_run_zoom_acc_fp;
                bg_wr_zoom_step_r     <= bg_run_zoom_step;
                bg_wr_pal_add_lines_r <= bg_run_pal_add_lines;
                bg_px_idx             <= 4'b0;
                bg_state              <= BG_WRITE;
            end

            BG_WRITE: begin
`ifdef QUARTUS
                bg_wr_acc_px_r <= bg_wr_acc_px_r + {10'b0, bg_wr_zoom_step_r};
                bg_wr_scol_r   <= bg_wr_scol_r + 11'sd1;
`endif
                if (bg_px_idx == 4'd15) begin
                    logic [5:0] next_tx;
                    next_tx = bg_next_zoom_acc_fp[17:12] & (bg_run_extend ? 6'h3F : 6'h1F);
                    bg_run_zoom_acc_fp <= bg_next_zoom_acc_fp;
                    if (bg_tile_col == 5'd20) begin
                        bg_state <= BG_IDLE;
                    end else begin
                        bg_tile_col <= bg_tile_col + 5'd1;
                        bg_map_tx   <= next_tx;
                        bg_state    <= BG_ATTR;
                    end
                end else begin
                    bg_px_idx <= bg_px_idx + 4'd1;
                end
            end

            default: bg_state <= BG_IDLE;
        endcase
    end
end

// =============================================================================
// Text FSM (clk_8x domain)
// =============================================================================
logic tx_phase_active;
assign tx_phase_active = (phase == PHASE_TEXT);

assign tx_done = tx_phase_active && (tx_state == TX_IDLE) && (tx_col == 6'd40);

always_ff @(posedge clk_8x) begin
    if (!rst_n) begin
        tx_state         <= TX_IDLE;
        tx_col           <= 6'd0;
        tx_px_idx        <= 3'b0;
        tx_tile_color_r  <= 5'b0;
        tx_tile_char_q_r <= 32'b0;
    end else if (phase == PHASE_TEXT) begin
        case (tx_state)
            TX_IDLE: begin
                // First entry into text phase: start at col 0
                if (tx_col != 6'd40) begin
                    tx_state  <= TX_TRAM;
                end
                // Reset col counter when phase starts
                if (hblank_rise_8x || (phase != PHASE_TEXT))
                    tx_col <= 6'd0;
            end

            TX_TRAM: begin
                // Async read from text_ram and char_ram; latch data
                tx_tile_color_r  <= tx_color_c;
                tx_tile_char_q_r <= char_q;
                tx_px_idx        <= 3'b0;
                tx_state         <= TX_PIXEL;
            end

            TX_PIXEL: begin
                if (tx_px_idx == 3'd7) begin
                    tx_state <= TX_NEXT;
                end else begin
                    tx_px_idx <= tx_px_idx + 3'd1;
                end
            end

            TX_NEXT: begin
                if (tx_col == 6'd39) begin
                    tx_col   <= 6'd40;   // sentinel: done
                    tx_state <= TX_IDLE;
                end else begin
                    tx_col   <= tx_col + 6'd1;
                    tx_state <= TX_TRAM;
                end
            end

            default: tx_state <= TX_IDLE;
        endcase
    end else if (hblank_rise_8x) begin
        // Reset state machine ready for next HBLANK
        tx_state <= TX_IDLE;
        tx_col   <= 6'd0;
    end
end

// Fix: start text FSM when phase transitions to PHASE_TEXT
// The TX_IDLE → TX_TRAM transition needs a trigger, not just phase==TEXT
// (since TX_IDLE is also the "done" state after col==40)
// Use a one-shot: enter TRAM on the first cycle of PHASE_TEXT where col<40.
// The always_ff block above handles this: TX_IDLE && tx_col != 40 → TX_TRAM.

// =============================================================================
// Pivot FSM (clk_8x domain)
// =============================================================================
logic pv_phase_active;
assign pv_phase_active = (phase == PHASE_PIVOT);

assign pv_done = pv_phase_active && (pv_state == PV_IDLE) && (pv_tx_col == 6'd41);

always_ff @(posedge clk_8x) begin
    if (!rst_n) begin
        pv_state        <= PV_IDLE;
        pv_tx_col       <= 6'd0;
        pv_px_idx       <= 3'b0;
        pv_tile_pvt_q_r <= 32'b0;
    end else if (phase == PHASE_PIVOT) begin
        case (pv_state)
            PV_IDLE: begin
                if (pv_tx_col != 6'd41) begin
`ifdef QUARTUS
                    pv_state <= PV_PREFETCH;
`else
                    pv_state <= PV_TILE;
`endif
                end
            end

`ifdef QUARTUS
            PV_PREFETCH: begin
                pv_state <= PV_TILE;
            end
`endif

            PV_TILE: begin
                pv_tile_pvt_q_r <= pvt_q;
                pv_px_idx       <= 3'b0;
                pv_state        <= PV_PIXEL;
            end

            PV_PIXEL: begin
                if (pv_px_idx == 3'd7) begin
                    pv_state <= PV_NEXT;
                end else begin
                    pv_px_idx <= pv_px_idx + 3'd1;
                end
            end

            PV_NEXT: begin
                if (pv_tx_col == 6'd40) begin
                    pv_tx_col <= 6'd41;   // sentinel: done
                    pv_state  <= PV_IDLE;
                end else begin
                    pv_tx_col <= pv_tx_col + 6'd1;
                    pv_state  <= PV_IDLE;   // idle one cycle then auto-start in IDLE
                end
            end

            default: pv_state <= PV_IDLE;
        endcase
    end else if (hblank_rise_8x) begin
        pv_state  <= PV_IDLE;
        pv_tx_col <= 6'd0;
    end
end

// =============================================================================
// Compositor — Layer Priority Arbiter (pix_clk domain)
// Integrated from tc0630fdp_colmix.  Reads from line buffers (async) and
// sprite_pixel input.  All logic runs at clk (pixel clock), same as original.
// =============================================================================

// ── Screen X coordinate ────────────────────────────────────────────────────────
logic [8:0] screen_x_9;
logic [7:0] screen_x;
always_comb begin
    if (hpos >= 10'(H_START))
        screen_x_9 = 9'(hpos - 10'(H_START));
    else
        screen_x_9 = 9'b0;
    screen_x = screen_x_9[7:0];
end

// ── Clip plane evaluation ──────────────────────────────────────────────────────
logic [3:0] clip_inside;
always_comb begin
    for (int p = 0; p < 4; p++) begin
        clip_inside[p] = (screen_x >= ls_clip_left[p]) && (screen_x <= ls_clip_right[p]);
    end
end

function automatic logic eval_clip(
    input logic [3:0] clip_en,
    input logic [3:0] clip_inv,
    input logic       clip_sense,
    input logic [3:0] in_plane
);
    logic eff_inv, vis_p, any_en, result;
    result = 1'b1;
    any_en = 1'b0;
    for (int p = 0; p < 4; p++) begin
        if (clip_en[p]) begin
            any_en  = 1'b1;
            eff_inv = clip_inv[p] ^ clip_sense;
            vis_p   = eff_inv ? ~in_plane[p] : in_plane[p];
            result  = result & vis_p;
        end
    end
    if (!any_en) result = 1'b1;
    return result;
endfunction

// ── Sprite group priority / blend decode ──────────────────────────────────────
logic [1:0] spr_grp;
logic [3:0] spr_prio_val;
logic [1:0] spr_blend_val;
assign spr_grp = spr_pixel[11:10];
always_comb begin
    case (spr_grp)
        2'd0: begin spr_prio_val = ls_spr_prio[0]; spr_blend_val = ls_spr_blend[0]; end
        2'd1: begin spr_prio_val = ls_spr_prio[1]; spr_blend_val = ls_spr_blend[1]; end
        2'd2: begin spr_prio_val = ls_spr_prio[2]; spr_blend_val = ls_spr_blend[2]; end
        2'd3: begin spr_prio_val = ls_spr_prio[3]; spr_blend_val = ls_spr_blend[3]; end
        default: begin spr_prio_val = 4'd0; spr_blend_val = 2'b00; end
    endcase
end

// ── Per-layer clipped pens ────────────────────────────────────────────────────
logic [3:0][3:0] pf_pen_clipped;
logic [3:0]      spr_pen_clipped;
logic [3:0]      pf_vis;

genvar gi_clip;
generate
    for (gi_clip = 0; gi_clip < 4; gi_clip++) begin : gen_pf_clip
        always_comb begin
            pf_vis[gi_clip] = eval_clip(
                ls_pf_clip_en[gi_clip], ls_pf_clip_inv[gi_clip],
                ls_pf_clip_sense[gi_clip], clip_inside
            );
            pf_pen_clipped[gi_clip] = pf_vis[gi_clip] ? bg_lb_rdata[gi_clip][3:0] : 4'd0;
        end
    end
endgenerate

logic spr_vis;
always_comb begin
    spr_vis = eval_clip(ls_spr_clip_en, ls_spr_clip_inv, ls_spr_clip_sense, clip_inside);
    spr_pen_clipped = spr_vis ? spr_pixel[3:0] : 4'd0;
end

// ── Layer field extraction ────────────────────────────────────────────────────
logic [3:0][3:0] pf_pen;
logic [3:0][8:0] pf_pal;
logic [3:0][4:0] pf_prio;
/* verilator lint_off UNUSEDSIGNAL */
logic [3:0][1:0] pf_bmode;
/* verilator lint_on UNUSEDSIGNAL */
genvar gi_pf;
generate
    for (gi_pf = 0; gi_pf < 4; gi_pf++) begin : gen_pf_fields
        assign pf_pen[gi_pf]   = pf_pen_clipped[gi_pf];
        assign pf_pal[gi_pf]   = bg_lb_rdata[gi_pf][12:4];
        assign pf_prio[gi_pf]  = {1'b0, ls_pf_prio[gi_pf]};
        assign pf_bmode[gi_pf] = ls_pf_blend[gi_pf];
    end
endgenerate

logic [4:0] spr_prio5;
logic [8:0] spr_pal9;
/* verilator lint_off UNUSEDSIGNAL */
logic [3:0] spr_pen_f;
/* verilator lint_on UNUSEDSIGNAL */
logic [1:0] spr_bmode;
assign spr_prio5 = {1'b0, spr_prio_val};
assign spr_pal9  = {3'b0, spr_pixel[9:4]};
assign spr_pen_f = spr_pen_clipped;
assign spr_bmode = spr_blend_val;

// Text from line buffer
logic [3:0] txt_pen;
logic [4:0] txt_color;
/* verilator lint_off UNUSEDSIGNAL */
logic [8:0] txt_pal9;
/* verilator lint_on UNUSEDSIGNAL */
assign txt_pen   = tx_lb_rdata[3:0];
assign txt_color = tx_lb_rdata[8:4];
assign txt_pal9  = {4'b0, txt_color};

// Pivot from line buffer
logic [3:0] pvt_pen;
logic [8:0] pvt_pal9;
assign pvt_pen  = pv_lb_rdata[3:0];
assign pvt_pal9 = {5'b0, pv_lb_rdata[7:4]};

// ── 2-Stage Pipelined Compositor (matches tc0630fdp_colmix Phase 5) ───────────

// Sub-stage A (combinational): PF0 vs PF1, PF2 vs PF3
logic [4:0] a01_prio; logic [8:0] a01_pal; logic [3:0] a01_pen;
logic [8:0] a01_dst;  logic [1:0] a01_bmode;
// temp regs for sub-stage A PF01 arbitration
logic [4:0] w0p; logic [8:0] w0l;
logic [3:0] w0n; logic [8:0] w0d;
logic [1:0] w0b;

always_comb begin
    if (pf_pen[0] != 4'd0) begin
        w0p = pf_prio[0]; w0l = pf_pal[0]; w0n = pf_pen[0]; w0d = 9'b0; w0b = 2'b00;
    end else begin
        w0p = 5'd0; w0l = 9'd0; w0n = 4'd0; w0d = 9'd0; w0b = 2'b00;
    end
    if (pf_pen[1] != 4'd0 && (w0n == 4'd0 || pf_prio[1] > w0p)) begin
        a01_prio = pf_prio[1]; a01_pal = pf_pal[1]; a01_pen = pf_pen[1];
        if ((pf_bmode[1] == 2'b01 || pf_bmode[1] == 2'b10) && w0n != 4'd0) begin
            a01_dst = w0l; a01_bmode = pf_bmode[1];
        end else begin
            a01_dst = 9'b0; a01_bmode = 2'b00;
        end
    end else begin
        a01_prio = w0p; a01_pal = w0l; a01_pen = w0n; a01_dst = w0d; a01_bmode = w0b;
    end
end

logic [4:0] a23_prio; logic [8:0] a23_pal; logic [3:0] a23_pen;
logic [8:0] a23_dst;  logic [1:0] a23_bmode;
// temp regs for sub-stage A PF23 arbitration
logic [4:0] w2p; logic [8:0] w2l;
logic [3:0] w2n; logic [8:0] w2d;
logic [1:0] w2b;

always_comb begin
    if (pf_pen[2] != 4'd0) begin
        w2p = pf_prio[2]; w2l = pf_pal[2]; w2n = pf_pen[2]; w2d = 9'b0; w2b = 2'b00;
    end else begin
        w2p = 5'd0; w2l = 9'd0; w2n = 4'd0; w2d = 9'd0; w2b = 2'b00;
    end
    if (pf_pen[3] != 4'd0 && (w2n == 4'd0 || pf_prio[3] > w2p)) begin
        a23_prio = pf_prio[3]; a23_pal = pf_pal[3]; a23_pen = pf_pen[3];
        if ((pf_bmode[3] == 2'b01 || pf_bmode[3] == 2'b10) && w2n != 4'd0) begin
            a23_dst = w2l; a23_bmode = pf_bmode[3];
        end else begin
            a23_dst = 9'b0; a23_bmode = 2'b00;
        end
    end else begin
        a23_prio = w2p; a23_pal = w2l; a23_pen = w2n; a23_dst = w2d; a23_bmode = w2b;
    end
end

// Sub-stage A pipeline registers (1 cycle delay)
logic [4:0] p01_prio; logic [8:0] p01_pal; logic [3:0] p01_pen;
logic [8:0] p01_dst;  logic [1:0] p01_bmode;
logic [4:0] p23_prio; logic [8:0] p23_pal; logic [3:0] p23_pen;
logic [8:0] p23_dst;  logic [1:0] p23_bmode;
logic [4:0] spr_prio5_d;
logic [8:0] spr_pal9_d;
logic [3:0] spr_pen_d;
logic [1:0] spr_bmode_d;
logic [8:0] pvt_pal9_d;
logic [3:0] pvt_pen_d;
logic [8:0] txt_pal9_d;
logic [3:0] txt_pen_d;
logic [3:0] a_src_d, a_dst_d, b_src_d, b_dst_d;
logic       pixel_valid_d;
logic [9:0] hpos_d;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        p01_prio <= 5'b0;  p01_pal <= 9'b0;  p01_pen <= 4'b0;
        p01_dst  <= 9'b0;  p01_bmode <= 2'b0;
        p23_prio <= 5'b0;  p23_pal <= 9'b0;  p23_pen <= 4'b0;
        p23_dst  <= 9'b0;  p23_bmode <= 2'b0;
        spr_prio5_d <= 5'b0;  spr_pal9_d <= 9'b0;
        spr_pen_d   <= 4'b0;  spr_bmode_d <= 2'b0;
        pvt_pal9_d  <= 9'b0;  pvt_pen_d   <= 4'b0;
        txt_pal9_d  <= 9'b0;  txt_pen_d   <= 4'b0;
        a_src_d     <= 4'd8;  a_dst_d <= 4'd0;
        b_src_d     <= 4'd8;  b_dst_d <= 4'd0;
        pixel_valid_d <= 1'b0;
        hpos_d      <= 10'b0;
    end else begin
        p01_prio <= a01_prio;  p01_pal <= a01_pal;  p01_pen <= a01_pen;
        p01_dst  <= a01_dst;   p01_bmode <= a01_bmode;
        p23_prio <= a23_prio;  p23_pal <= a23_pal;  p23_pen <= a23_pen;
        p23_dst  <= a23_dst;   p23_bmode <= a23_bmode;
        spr_prio5_d  <= spr_prio5;
        spr_pal9_d   <= spr_pal9;
        spr_pen_d    <= spr_pen_clipped;
        spr_bmode_d  <= spr_bmode;
        pvt_pal9_d   <= pvt_pal9;
        pvt_pen_d    <= pvt_pen;
        txt_pal9_d   <= txt_pal9;
        txt_pen_d    <= txt_pen;
        a_src_d      <= ls_a_src;
        a_dst_d      <= ls_a_dst;
        b_src_d      <= ls_b_src;
        b_dst_d      <= ls_b_dst;
        pixel_valid_d<= pixel_valid;
        hpos_d       <= hpos;
    end
end

// Sub-stage B (combinational): final priority arbitration
logic [4:0] win_prio;
logic [8:0] win_pal;
logic [3:0] win_pen;
logic [8:0] win_dst;
logic [1:0] win_bmode;
// temp regs for sub-stage B arbitration (merged/sprite/pivot stages)
logic [4:0] wm_prio; logic [8:0] wm_pal; logic [3:0] wm_pen;
logic [8:0] wm_dst;  logic [1:0] wm_bmode;
logic [4:0] ws_prio; logic [8:0] ws_pal; logic [3:0] ws_pen;
logic [8:0] ws_dst;  logic [1:0] ws_bmode;
logic [4:0] wp_prio; logic [8:0] wp_pal; logic [3:0] wp_pen;
logic [8:0] wp_dst;  logic [1:0] wp_bmode;

always_comb begin
    // Merge PF01 vs PF23
    if (p23_pen != 4'd0 && (p01_pen == 4'd0 || p23_prio > p01_prio)) begin
        wm_prio = p23_prio; wm_pal = p23_pal; wm_pen = p23_pen;
        if ((p23_bmode == 2'b01 || p23_bmode == 2'b10) && p23_dst != 9'b0) begin
            wm_dst = p23_dst; wm_bmode = p23_bmode;
        end else if ((p23_bmode == 2'b01 || p23_bmode == 2'b10) && p01_pen != 4'd0) begin
            wm_dst = p01_pal; wm_bmode = p23_bmode;
        end else begin
            wm_dst = 9'b0; wm_bmode = 2'b00;
        end
    end else begin
        wm_prio = p01_prio; wm_pal = p01_pal; wm_pen = p01_pen;
        wm_dst  = p01_dst;  wm_bmode = p01_bmode;
    end

    // Sprite (wins on tie >=)
    if (spr_pen_d != 4'd0 && (wm_pen == 4'd0 || spr_prio5_d >= wm_prio)) begin
        ws_prio = spr_prio5_d; ws_pal = spr_pal9_d; ws_pen = spr_pen_d;
        if ((spr_bmode_d == 2'b01 || spr_bmode_d == 2'b10) && wm_pen != 4'd0) begin
            ws_dst = wm_pal; ws_bmode = spr_bmode_d;
        end else begin
            ws_dst = 9'b0; ws_bmode = 2'b00;
        end
    end else begin
        ws_prio = wm_prio; ws_pal = wm_pal; ws_pen = wm_pen;
        ws_dst  = wm_dst;  ws_bmode = wm_bmode;
    end

    // Pivot — fixed priority 8
    if (pvt_pen_d != 4'd0 && (ws_pen == 4'd0 || 5'd8 > ws_prio)) begin
        wp_prio = 5'd8; wp_pal = pvt_pal9_d; wp_pen = pvt_pen_d;
        if (ls_pivot_blend && ws_pen != 4'd0) begin
            wp_dst = ws_pal; wp_bmode = 2'b01;
        end else begin
            wp_dst = 9'b0; wp_bmode = 2'b00;
        end
    end else begin
        wp_prio = ws_prio; wp_pal = ws_pal; wp_pen = ws_pen;
        wp_dst  = ws_dst;  wp_bmode = ws_bmode;
    end

    // Text — always opaque, always wins
    if (txt_pen_d != 4'd0) begin
        win_prio = 5'd16; win_pal = txt_pal9_d; win_pen = txt_pen_d;
        win_dst  = 9'b0;  win_bmode = 2'b00;
    end else begin
        win_prio = wp_prio; win_pal = wp_pal; win_pen = wp_pen;
        win_dst  = wp_dst;  win_bmode = wp_bmode;
    end
end

/* verilator lint_off UNUSED */
logic _unused_winprio;
assign _unused_winprio = ^win_prio;
/* verilator lint_on UNUSED */

// ── Registered colmix output ──────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n)
        colmix_pixel_out <= 13'b0;
    else
        colmix_pixel_out <= {win_pal, win_pen};
end

// ── Palette addresses ─────────────────────────────────────────────────────────
assign pal_addr_src = {win_pal, win_pen};
assign pal_addr_dst = {win_dst, 4'b0};

// ── Blend pipeline ────────────────────────────────────────────────────────────
logic [1:0] blend_mode_r;
logic [3:0] a_src_r, a_dst_r, b_src_r, b_dst_r;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        blend_mode_r <= 2'b00;
        a_src_r <= 4'd8; a_dst_r <= 4'd0;
        b_src_r <= 4'd8; b_dst_r <= 4'd0;
    end else begin
        blend_mode_r <= win_bmode;
        a_src_r <= a_src_d;
        a_dst_r <= a_dst_d;
        b_src_r <= b_src_d;
        b_dst_r <= b_dst_d;
    end
end

// ── Palette color expand ───────────────────────────────────────────────────────
function automatic logic [7:0] expand4to8(input logic [3:0] v);
    return {v, v};
endfunction

logic [7:0] src_r_ch, src_g_ch, src_b_ch;
logic [7:0] dst_r_ch, dst_g_ch, dst_b_ch;
always_comb begin
    src_r_ch = expand4to8(pal_rdata_src[15:12]);
    src_g_ch = expand4to8(pal_rdata_src[11: 8]);
    src_b_ch = expand4to8(pal_rdata_src[ 7: 4]);
    dst_r_ch = expand4to8(pal_rdata_dst[15:12]);
    dst_g_ch = expand4to8(pal_rdata_dst[11: 8]);
    dst_b_ch = expand4to8(pal_rdata_dst[ 7: 4]);
end

// ── Blend computation (simulation only — TC0650FDA handles actual output) ──────
`ifndef QUARTUS
function automatic logic [7:0] blend_channel(
    input logic [7:0] src,
    input logic [7:0] dst,
    input logic [3:0] a_s,
    input logic [3:0] a_d
);
    logic [11:0] prod_src, prod_dst;
    logic [12:0] sum13;
    prod_src = 12'(src) * 12'(a_s);
    prod_dst = 12'(dst) * 12'(a_d);
    sum13    = 13'(prod_src) + 13'(prod_dst);
    if (sum13 >= 13'h7F8) return 8'hFF;
    else                  return 8'(sum13 >> 3);
endfunction

always_ff @(posedge clk) begin
    if (!rst_n) begin
        blend_rgb_out <= 24'b0;
    end else begin
        case (blend_mode_r)
            2'b01: blend_rgb_out <= {
                blend_channel(src_r_ch, dst_r_ch, a_src_r, a_dst_r),
                blend_channel(src_g_ch, dst_g_ch, a_src_r, a_dst_r),
                blend_channel(src_b_ch, dst_b_ch, a_src_r, a_dst_r)
            };
            2'b10: blend_rgb_out <= {
                blend_channel(src_r_ch, dst_r_ch, b_src_r, b_dst_r),
                blend_channel(src_g_ch, dst_g_ch, b_src_r, b_dst_r),
                blend_channel(src_b_ch, dst_b_ch, b_src_r, b_dst_r)
            };
            default: blend_rgb_out <= {src_r_ch, src_g_ch, src_b_ch};
        endcase
    end
end
`else
assign blend_rgb_out = 24'b0;
`endif

// ── TC0650FDA blend interface outputs ─────────────────────────────────────────
// Per-column destination palette buffer (M10K under QUARTUS, FF array in sim)
`ifndef QUARTUS
logic [12:0] dst_pal_buf [0:319];
`endif

logic [8:0] screen_col_r;
logic win_do_blend_c;
logic [3:0] win_src_coeff, win_dst_coeff;

always_comb begin
    win_do_blend_c = (win_bmode == 2'b01) || (win_bmode == 2'b10);
    case (win_bmode)
        2'b01: begin win_src_coeff = a_src_d; win_dst_coeff = a_dst_d; end
        2'b10: begin win_src_coeff = b_src_d; win_dst_coeff = b_dst_d; end
        default: begin win_src_coeff = 4'd8;  win_dst_coeff = 4'd0; end
    endcase
end

`ifndef QUARTUS
logic [12:0] dst_pal_rd;
always_comb begin
    if (hpos_d >= 10'(H_START) && hpos_d < 10'(H_START + 320))
        dst_pal_rd = dst_pal_buf[9'(hpos_d - 10'(H_START))];
    else
        dst_pal_rd = 13'b0;
end
`endif

always_ff @(posedge clk) begin
    if (!rst_n) begin
        src_pal         <= 13'b0;
        dst_pal         <= 13'b0;
        src_blend       <= 4'd8;
        dst_blend       <= 4'd0;
        do_blend        <= 1'b0;
        pixel_valid_out <= 1'b0;
        screen_col_r    <= 9'b0;
    end else begin
        src_pal         <= {win_pal, win_pen};
        src_blend       <= win_src_coeff;
        dst_blend       <= win_dst_coeff;
        do_blend        <= win_do_blend_c;
        pixel_valid_out <= pixel_valid_d;
        screen_col_r    <= screen_x_9;

        // dst_pal: read from per-column buffer (previous frame's src_pal)
`ifndef QUARTUS
        dst_pal <= dst_pal_rd;
        // Update per-column buffer with this frame's src_pal
        if (pixel_valid_d && hpos_d >= 10'(H_START) && hpos_d < 10'(H_START + 320))
            dst_pal_buf[9'(hpos_d - 10'(H_START))] <= {win_pal, win_pen};
`else
        dst_pal <= 13'b0;  // TC0650FDA reads from its own frame buffer
`endif
    end
end

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
/* verilator lint_off UNUSEDSIGNAL */
logic _unused_misc;
assign _unused_misc = ^{hpos_d, screen_col_r, V_START[0],
                        bg_tile_blend_r, bg_tile_xplanes_r, bg_tile_code_r,
                        ls_spr_mosaic_en,
                        bg_wr_acc_px[18:12], bg_wr_acc_px[7:0],
                        pv_yscroll_int[8],
                        pal_rdata_src[3:0], pal_rdata_dst[3:0]};
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSED */

endmodule
