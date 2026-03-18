`default_nettype none
// =============================================================================
// TC0630FDP — BG Tilemap Layer Engine  (Step 15: +mosaic X-snap)
// =============================================================================
// One instance per playfield (PF1–PF4). PLANE parameter = 0..3.
//
// Playfield geometry (section1 §4):
//   Standard mode: 32×32 tiles × 16×16px = 512×512 px canvas
//   Extended mode: 64×32 tiles × 16×16px = 1024×512 px canvas
//
// Tile entry: two consecutive 16-bit PF RAM words per tile.
//   Word 0 (attr): bits[8:0]=palette, bit[9]=blend, bits[11:10]=extra_planes,
//                  bit[14]=flipX, bit[15]=flipY.
//   Word 1 (code): bits[15:0]=tile_code.
//
// GFX ROM: 32-bit wide, nibble-packed 4bpp (section1 §11.3).
//   128 bytes (32 × 32-bit words) per 16×16 tile.
//   Left 8 pixels of row r: word_addr = tile_code*32 + r*2
//   Right 8 pixels:         word_addr = tile_code*32 + r*2 + 1
//   Within word: bits[31:28]=px0, [27:24]=px1, ..., [3:0]=px7.
//   flipX: reverse nibble order. flipY: row = 15 - fetch_py.
//
// Scroll (global + per-scanline rowscroll, Step 5; section1 §3.1 + §9.11):
//   X: effective_x = pf_xscroll[15:6] + ls_rowscroll_int  (both in pixel units)
//      ls_rowscroll_int = ls_rowscroll[15:6]  (same fixed-point format as global)
//   Y: pf_yscroll[15:7] = integer pixel offset. canvas_y = (vpos+1+yscroll)&0x1FF.
//
// Alt-tilemap (Step 5; section1 §9.2 bit[9]):
//   When ls_alt_tilemap=1, tile addresses in PF RAM are offset by +0x1800 words.
//
// Zoom (Step 6; section1 §9.9):
//   X zoom (ls_zoom_x): 0x00 = 1:1 (no zoom), >0x00 = zoom in.
//     Fractional X accumulator:
//       zoom_step_fp = 0x100 + ls_zoom_x (9-bit, base 256 = 1.0 step per pixel)
//       acc[fp] starts at effective_x * 256 (16.8 fixed-point).
//       At each output pixel: canvas_x = acc >> 8; acc += zoom_step_fp.
//   Y zoom (ls_zoom_y): 0x80 = 1:1 (no zoom).
//     Effective Y row = (canvas_y_raw * ls_zoom_y) >> 7  (scaled by yscale/128).
//     canvas_y_raw = (vpos + 1 + yscroll_int) & 0x1FF.
//
// Colscroll (Step 7; section1 §9.2 bits[8:0]):
//   ls_colscroll is a 9-bit offset added to the tile's map_tx (tile column index)
//   AFTER the zoom accumulator has determined map_tx.  This shifts the tile
//   address within the row by a per-scanline constant column offset.
//   map_tx_final = (map_tx + colscroll) & wrap_mask
//
// Palette addition (Step 7; section1 §9.10):
//   ls_pal_add is the raw 16-bit value from Line RAM.  The BG engine adds
//   (ls_pal_add / 16) to the tile's palette index (9-bit wrap).
//   This shifts all tiles on the scanline to a different palette band.
//
// FSM: 5 states × 21 tiles + 1 IDLE = 106 cycles < 112-cycle HBLANK budget.
//   BG_IDLE → (hblank_rise) → [per-tile:] BG_ATTR → BG_CODE → BG_GFX0 →
//             BG_GFX1 → BG_WRITE → (next tile or BG_IDLE)
//
//   BG_ATTR : pf_rd_addr = attr addr; latch attr fields.
//   BG_CODE : pf_rd_addr = code addr; latch tile_code; compute + latch GFX addrs.
//   BG_GFX0 : gfx_addr = gfx_left_r; wait for gfx_data.
//   BG_GFX1 : gfx_addr = gfx_right_r; latch left gfx_data.
//   BG_WRITE: latch right gfx_data; decode 16 pixels → linebuf; advance.
//
// Line buffer: 320 × 13-bit {palette[8:0], pen[3:0]}.
//   Filled during HBLANK, read during active display of next scanline.
//   bg_pixel output: pen==0 → transparent.
// =============================================================================

/* verilator lint_off UNUSEDPARAM */
module tc0630fdp_bg #(
    parameter int PLANE = 0
) (
/* verilator lint_on UNUSEDPARAM */
    input  logic        clk,
    input  logic        rst_n,

    // ── Video timing ──────────────────────────────────────────────────────
    input  logic        hblank,
    input  logic [ 8:0] vpos,
    input  logic [ 9:0] hpos,

    // ── Scroll registers ──────────────────────────────────────────────────
    input  logic [15:0] pf_xscroll,     // 10.6 fixed-point; integer = [15:6]
    input  logic [15:0] pf_yscroll,     //  9.7 fixed-point; integer = [15:7]

    // ── Extend mode ───────────────────────────────────────────────────────
    input  logic        extend_mode,

    // ── Per-scanline Line RAM outputs (Step 5) ───────────────────────────────────
    // ls_rowscroll: per-scanline X-scroll addition (same 10.6 fp as pf_xscroll).
    // 0 when rowscroll is disabled for this PF on this scanline.
    input  logic [15:0] ls_rowscroll,
    // ls_alt_tilemap: when 1, PF RAM tile address += 0x1800 words.
    input  logic        ls_alt_tilemap,

    // ── Per-scanline zoom (Step 6) ───────────────────────────────────────────
    // ls_zoom_x: X zoom factor. 0x00 = 1:1 (no zoom), >0x00 = zoom in.
    input  logic [ 7:0] ls_zoom_x,
    // ls_zoom_y: Y zoom factor. 0x80 = 1:1 (no zoom).
    input  logic [ 7:0] ls_zoom_y,

    // ── Per-scanline colscroll + palette addition (Step 7) ───────────────────
    // ls_colscroll: 9-bit column scroll offset added to map_tx after zoom.
    // 0 = no colscroll.
    input  logic [ 8:0] ls_colscroll,
    // ls_pal_add: raw 16-bit palette addition word (§9.10).
    // Palette-line offset = ls_pal_add / 16 (divides raw value by 16).
    // 0 = no palette addition.
    input  logic [15:0] ls_pal_add,

    // ── Per-scanline mosaic (Step 15) ──────────────────────────────────────
    // ls_mosaic_en: 1 when mosaic is enabled for this PF plane.
    // ls_mosaic_rate: 4-bit rate; sample_rate = rate + 1.
    //   When enabled, read linebuf at snapped column instead of hpos column.
    input  logic        ls_mosaic_en,
    input  logic [ 3:0] ls_mosaic_rate,

    // ── PF RAM async read port (0x1800 words per PF) ─────────────────────
    output logic [12:0] pf_rd_addr,
    input  logic [15:0] pf_q,

    // ── GFX ROM async read port (32-bit word-addressed) ──────────────────
    output logic [21:0] gfx_addr,
    input  logic [31:0] gfx_data,
    output logic        gfx_rd,

    // ── Pixel output: {palette[8:0], pen[3:0]}; pen==0 → transparent ─────
    output logic [12:0] bg_pixel
);

// =============================================================================
// Timing
// =============================================================================
localparam int H_START = 46;

// =============================================================================
// HBLANK rising-edge detect (delayed by 1 cycle)
// Fire FSM one cycle AFTER hblank first goes high, ensuring that the
// tc0630fdp_lineram has already registered the new per-scanline values
// (ls_rowscroll, ls_alt_tilemap) into their output registers.
// Without this 1-cycle delay, the BG FSM would latch the PREVIOUS scanline's
// rowscroll because both the lineram and BG FSM act on the same posedge.
// =============================================================================
logic hblank_r;
logic hblank_r2;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        hblank_r  <= 1'b0;
        hblank_r2 <= 1'b0;
    end else begin
        hblank_r  <= hblank;
        hblank_r2 <= hblank_r;
    end
end
// hblank_rise fires one cycle after hblank first asserts:
// At this cycle, lineram has already registered new ls_rowscroll / ls_alt_tilemap.
logic hblank_rise;
assign hblank_rise = hblank_r & ~hblank_r2;

// =============================================================================
// Fetch geometry (combinational — computed from live inputs each cycle)
// This ensures the FSM reads correct values on the same clock edge as
// hblank_rise, rather than getting the previous scanline's stale latched values.
// =============================================================================
logic [3:0] fetch_py;           // pixel row within 16px tile (zoomed): canvas_y_z[3:0]
logic [4:0] fetch_ty;           // tile row (0..31) (zoomed):            canvas_y_z[8:4]
logic       fetch_extend;       // extend_mode passthrough

// Suppress unused sub-field warnings for scroll registers and zoom
/* verilator lint_off UNUSED */
logic _unused_scroll;
assign _unused_scroll = ^{pf_xscroll[5:0], pf_yscroll[6:0], ls_rowscroll[5:0],
                          ls_pal_add[3:0], ls_pal_add[15:13]};  // fractional bits and overflow bits
/* verilator lint_on UNUSED */

// Y-zoom product intermediate (outside always_comb to control lint suppression).
// canvas_y_raw (9-bit) * ls_zoom_y (8-bit) = 17-bit; we use bits [15:7] = 9 bits.
/* verilator lint_off UNUSED */
logic [16:0] cy_zoomed_w;
/* verilator lint_on UNUSED */
always_comb begin
    logic [8:0] canvas_y_raw;
    canvas_y_raw    = (vpos[8:0] + 9'd1) + pf_yscroll[15:7];
    cy_zoomed_w     = {1'b0, canvas_y_raw} * {1'b0, ls_zoom_y};
end

always_comb begin
    logic [8:0] canvas_y;
    canvas_y        = cy_zoomed_w[15:7];
    fetch_py        = canvas_y[3:0];
    fetch_ty        = canvas_y[8:4];
    fetch_extend    = extend_mode;
end

// =============================================================================
// FSM states
// =============================================================================
typedef enum logic [2:0] {
    BG_IDLE     = 3'd0,
    BG_ATTR     = 3'd1,
    BG_CODE     = 3'd2,
    BG_GFX0     = 3'd3,
    BG_GFX1     = 3'd4,
    BG_WRITE    = 3'd5,
    BG_PREFETCH = 3'd6   // QUARTUS: registered-read pre-fetch cycle before BG_ATTR
} bg_state_t;

bg_state_t  state;
logic [4:0] tile_col;    // tile slot 0..20 (21 tiles = 336px, covers 320 + 15px overhang)
logic [5:0] map_tx;      // current map tile column
logic [4:0] map_ty;      // current map tile row (= fetch_ty, fixed per scanline)

// Per-FSM-run snapshot of fetch geometry — latched when FSM starts (BG_IDLE→BG_ATTR)
// fetch_py and fetch_xoff are needed throughout the tile fetch loop; latch them once
// so they don't change mid-fetch if vpos wraps.
logic [3:0] run_py;              // snapshot of fetch_py at FSM start (zoomed Y row)
logic [3:0] run_xoff;            // snapshot of fetch_xoff at FSM start (pixel offset in first tile)
logic       run_extend;          // snapshot of fetch_extend at FSM start
logic       run_alt;             // snapshot of ls_alt_tilemap at FSM start
// Zoom state latched at FSM start (Step 6)
logic [8:0] run_zoom_step;       // zoom step per output pixel (0x100 = 1.0, no zoom)
// 19-bit zoom accumulator (8 fractional bits):
//   bits[18:8] = integer canvas_x, bits[7:0] = fractional
// Initialized to run_eff_x << 8 at FSM start.
// Advanced by 16 * run_zoom_step after each 16-pixel tile slot.
logic [18:0] run_zoom_acc_fp;
// Palette addition latched at FSM start (Step 7)
logic [8:0] run_pal_add_lines;   // palette-line offset = ls_pal_add / 16 (9-bit)

// =============================================================================
// Tile attribute and code registers
// =============================================================================
logic [8:0] tile_palette_r;
logic       tile_flipx_r;
logic       tile_flipy_r;
/* verilator lint_off UNUSED */
logic [15:0] tile_code_r;   // latched for future steps (zoom, rowscroll)
logic        tile_blend_r;
logic [1:0]  tile_xplanes_r;
/* verilator lint_on UNUSED */

// GFX ROM addresses (latched in BG_CODE)
logic [21:0] gfx_left_r;
logic [21:0] gfx_right_r;

// GFX data latches (left and right halves, captured during GFX0/GFX1 states)
logic [31:0] gfx_left_data_r;
logic [31:0] gfx_right_data_r;

// =============================================================================
// Combinational: PF RAM address
// map_tx is now updated in BG_IDLE and after each tile slot in BG_WRITE
// using the zoom accumulator.
// tile_index = map_ty * map_width + map_tx
//   standard (map_width=32): {map_ty[4:0], map_tx[4:0]} → 10 bits
//   extended (map_width=64): {map_ty[4:0], map_tx[5:0]} → 11 bits
// word_offset = tile_index * 2 + (0=attr, 1=code) → 13 bits max
// =============================================================================
logic [12:0] pf_attr_addr_c;
logic [12:0] pf_code_addr_c;

always_comb begin
    logic [11:0] tileword_base;   // tile_index * 2 (12-bit)
    logic [12:0] base_addr;       // tile pair base (with optional alt-tilemap offset)
    if (run_extend)
        // tile_idx = {map_ty, map_tx} = 11 bits; ×2 → 12 bits
        tileword_base = {map_ty, map_tx, 1'b0};
    else
        // tile_idx = {map_ty, map_tx[4:0]} = 10 bits; ×2 → 11 bits; zero-extend
        tileword_base = {1'b0, map_ty, map_tx[4:0], 1'b0};
    // Alt-tilemap: add 0x1000 words (=+0x2000 bytes) to PF RAM base (section2 §2.5 + §9.2 bit[9])
    base_addr = {1'b0, tileword_base} + (run_alt ? 13'h1000 : 13'h0000);
    pf_attr_addr_c = base_addr;         // attr word (offset 0)
    pf_code_addr_c = base_addr + 13'd1; // code word (offset 1)
end

// =============================================================================
// Combinational: next zoom accumulator after a tile slot of 16 output pixels.
// Used in BG_WRITE to compute next map_tx.
// next_zoom_acc = run_zoom_acc_fp + 16 * run_zoom_step (capped at 19 bits)
// =============================================================================
logic [18:0] next_zoom_acc_fp;
always_comb begin
    // 16 * zoom_step: zoom_step is 9-bit (max 511), 16*511=8176 < 8192=13-bit.
    // Use 13-bit for step16, zero-extend to 19 bits for addition.
    logic [12:0] step16;
    step16 = {4'b0, run_zoom_step} << 4;   // 16 * zoom_step (fits in 13 bits)
    next_zoom_acc_fp = run_zoom_acc_fp + {6'b0, step16};
end

`ifdef QUARTUS
// Next tile's attr address: computed from next_zoom_acc_fp during BG_WRITE.
// Pre-issued from BG_WRITE so that the registered M10K read has attr data
// ready when BG_ATTR begins (tiles 2–21).
logic [12:0] pf_attr_addr_next_c;
always_comb begin
    logic [11:0] tileword_base;
    logic [12:0] base_addr;
    logic [5:0]  next_map_tx;
    next_map_tx   = next_zoom_acc_fp[17:12] & (run_extend ? 6'h3F : 6'h1F);
    if (run_extend)
        tileword_base = {map_ty, next_map_tx, 1'b0};
    else
        tileword_base = {1'b0, map_ty, next_map_tx[4:0], 1'b0};
    base_addr = {1'b0, tileword_base} + (run_alt ? 13'h1000 : 13'h0000);
    pf_attr_addr_next_c = base_addr;
end
`endif

// pf_rd_addr mux:
// Simulation (async pf_q):  address driven in the state that CONSUMES the data.
// QUARTUS (registered pf_q): address pre-issued one cycle before the consuming state.
//   BG_PREFETCH → BG_ATTR : BG_PREFETCH drives pf_attr_addr_c    → BG_ATTR reads pf_q
//   BG_ATTR     → BG_CODE : BG_ATTR drives pf_code_addr_c         → BG_CODE reads pf_q
//   BG_WRITE    → BG_ATTR : BG_WRITE drives pf_attr_addr_next_c   → BG_ATTR reads pf_q
`ifdef QUARTUS
always_comb begin
    case (state)
        BG_PREFETCH: pf_rd_addr = pf_attr_addr_c;       // pre-fetch attr (first tile)
        BG_ATTR:     pf_rd_addr = pf_code_addr_c;       // pre-fetch code while latching attr
        BG_WRITE:    pf_rd_addr = pf_attr_addr_next_c;  // pre-fetch attr for next tile
        default:     pf_rd_addr = 13'b0;
    endcase
end
`else
always_comb begin
    case (state)
        BG_ATTR:  pf_rd_addr = pf_attr_addr_c;
        BG_CODE:  pf_rd_addr = pf_code_addr_c;
        default:  pf_rd_addr = 13'b0;
    endcase
end
`endif

// =============================================================================
// Combinational: attribute decode (from pf_q in BG_ATTR)
// =============================================================================
logic [8:0] attr_palette_c;
logic       attr_flipx_c;
logic       attr_flipy_c;
logic       attr_blend_c;
logic [1:0] attr_xplanes_c;

assign attr_palette_c  = pf_q[8:0];
assign attr_blend_c    = pf_q[9];
assign attr_xplanes_c  = pf_q[11:10];
assign attr_flipx_c    = pf_q[14];
assign attr_flipy_c    = pf_q[15];

// =============================================================================
// GFX ROM address (combinational, state-dependent)
// =============================================================================
always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 22'b0;
    case (state)
        BG_GFX0: begin gfx_addr = gfx_left_r;  gfx_rd = 1'b1; end
        BG_GFX1: begin gfx_addr = gfx_right_r; gfx_rd = 1'b1; end
        default: begin gfx_addr = 22'b0;        gfx_rd = 1'b0; end
    endcase
end

// =============================================================================
// Line buffer: 320 × 13-bit
// =============================================================================
logic [12:0] linebuf [0:319];

// Screen column from hpos (unsnapped)
logic [8:0] scol_c;
always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_START + 320))
        scol_c = hpos[8:0] - 9'(H_START);
    else
        scol_c = 9'd0;
end

// Step 15: Mosaic X-snap
// Formula (section2 §5.4):
//   snapped_x = screen_x - ((screen_x - H_START + 114) % 432 % sample_rate)
//   In column terms: scol_c = hpos - H_START, so:
//   scol_snap = scol_c - ((scol_c + 114) % 432 % sample_rate)
//
// Implementation: compute (scol_c + 114) % 432, then mod sample_rate.
// sample_rate = ls_mosaic_rate + 1 (range 1..16).
logic [8:0] scol_snap;  // mosaic-snapped column (or scol_c when disabled)

always_comb begin
    automatic logic [9:0] gx_wide;
    automatic logic [8:0] grid_sum;
    automatic logic [8:0] sr;
    automatic logic [4:0] off;

    // grid_sum = (scol_c + 114) % 432 (unsigned 9-bit result; scol_c in 0..319 so max sum = 433 → 1 subtract)
    gx_wide  = {1'b0, scol_c} + 10'd114;
    grid_sum = (gx_wide >= 10'd432) ? gx_wide[8:0] - 9'd432 : gx_wide[8:0];

    // sample_rate = ls_mosaic_rate + 1 (range 1..16, fits in 5-bit)
    sr = 9'd1 + {5'b0, ls_mosaic_rate};

    // offset = grid_sum % sample_rate (4-bit result, max 15 for rate=16)
    off = 5'(grid_sum % sr);

    // Apply mosaic snap when enabled and rate > 0 (rate=0 → sample_rate=1 → no snap)
    if (ls_mosaic_en && ls_mosaic_rate != 4'd0)
        scol_snap = 9'(scol_c - {5'b0, off});
    else
        scol_snap = scol_c;
end

assign bg_pixel = linebuf[scol_snap];

// =============================================================================
// FSM
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state              <= BG_IDLE;
        tile_col           <= 5'b0;
        map_tx             <= 6'b0;
        map_ty             <= 5'b0;
        run_py             <= 4'b0;
        run_xoff           <= 4'b0;
        run_extend         <= 1'b0;
        run_alt            <= 1'b0;
        run_zoom_step      <= 9'd256;
        run_zoom_acc_fp    <= 19'b0;
        run_pal_add_lines  <= 9'b0;
        tile_palette_r     <= 9'b0;
        tile_blend_r       <= 1'b0;
        tile_xplanes_r     <= 2'b0;
        tile_flipx_r       <= 1'b0;
        tile_flipy_r       <= 1'b0;
        tile_code_r        <= 16'b0;
        gfx_left_r         <= 22'b0;
        gfx_right_r        <= 22'b0;
        gfx_left_data_r    <= 32'b0;
        gfx_right_data_r   <= 32'b0;
    end else begin
        case (state)

            // ─── Wait for HBLANK ────────────────────────────────────────────
            // Geometry is combinational — fetch_ty/fetch_first_tx are valid NOW.
            BG_IDLE: begin
                if (hblank_rise) begin
                    begin
                        // Compute effective_x = pf_xscroll[15:6] + ls_rowscroll[15:6]
                        //   + ls_colscroll (9-bit pixel offset, section1 §9.2, Step 7)
                        // Colscroll is a 9-bit pixel value added to canvas X.
                        // It is added in pixel units (not fixed-point), so no shift needed.
                        logic [9:0]  eff_x_base;  // scroll + rowscroll (10-bit)
                        logic [9:0]  eff_x;
                        logic [8:0]  zstep;
                        logic [18:0] zacc;
                        eff_x_base = pf_xscroll[15:6] + ls_rowscroll[15:6];
                        // Add 9-bit colscroll (pixel offset) to 10-bit eff_x, wrap to 10-bit canvas.
                        // The 11-bit sum truncated to 10 bits gives mod-1024 wrap naturally.
                        eff_x = eff_x_base + {1'b0, ls_colscroll};
                        run_xoff  <= eff_x[3:0];
                        // Zoom step: 0x100 + zoom_x. 0x100 = 1.0 (no zoom).
                        zstep = 9'd256 + {1'b0, ls_zoom_x};
                        run_zoom_step <= zstep;
                        // Zoom accumulator: start at eff_x * 256 (8 fractional bits).
                        zacc = {1'b0, eff_x, 8'b0};
                        run_zoom_acc_fp <= zacc;
                        // map_tx for tile_col=0: integer canvas_x at output pixel 0.
                        // canvas_x = zacc >> 8 = eff_x. Tile = eff_x >> 4.
                        map_tx <= eff_x[9:4] & (fetch_extend ? 6'h3F : 6'h1F);
                    end
                    tile_col           <= 5'b0;
                    map_ty             <= fetch_ty;
                    run_py             <= fetch_py;
                    run_extend         <= fetch_extend;
                    run_alt            <= ls_alt_tilemap;
                    // Latch palette addition: section1 §9.10 raw value = palette_offset * 16,
                    // so palette_offset = raw >> 4. Take low 9 bits for 9-bit palette wrap.
                    run_pal_add_lines <= ls_pal_add[12:4];  // bits[12:4] = (raw/16) & 0x1FF
`ifdef QUARTUS
                    state              <= BG_PREFETCH;  // registered read: pre-fetch before BG_ATTR
`else
                    state              <= BG_ATTR;
`endif
                end
            end

            // ─── [QUARTUS only] Pre-fetch attr data for first tile ────────────
            // pf_rd_addr = pf_attr_addr_c is driven combinationally above.
            // Registered M10K read fires at this clock edge → attr data available in BG_ATTR.
            // Simulation: this state is never entered (BG_IDLE goes directly to BG_ATTR).
            BG_PREFETCH: begin
                state <= BG_ATTR;
            end

            // ─── Latch attribute word ────────────────────────────────────────
            // QUARTUS: pf_q = registered attr data from previous cycle (BG_PREFETCH or BG_WRITE).
            // Simulation: pf_rd_addr = pf_attr_addr_c (async) → pf_q = attr word this cycle.
            BG_ATTR: begin
                tile_palette_r  <= attr_palette_c;
                tile_blend_r    <= attr_blend_c;
                tile_xplanes_r  <= attr_xplanes_c;
                tile_flipx_r    <= attr_flipx_c;
                tile_flipy_r    <= attr_flipy_c;
                state           <= BG_CODE;
            end

            // ─── Latch tile code; compute GFX ROM addresses ──────────────────
            // QUARTUS: pf_q = registered code data (address pre-issued in BG_ATTR).
            // Simulation: pf_rd_addr = pf_code_addr_c (async) → pf_q = code word.
            // tile_flipy_r is freshly latched in BG_ATTR, stable here.
            // Compute GFX addresses from pf_q (raw tile code) since tile_code_r
            // won't hold pf_q until after this clock edge.
            BG_CODE: begin
                tile_code_r <= pf_q;
                begin
                    logic [3:0]  ry;
                    logic [21:0] base22;
                    // flipY: row = 15 - run_py if flipy set
                    ry      = tile_flipy_r ? (4'd15 - run_py) : run_py;
                    // base22 = pf_q * 32 (tile_code * 32 words/tile)
                    // pf_q[15:0] << 5: 21-bit result, zero-extend to 22 bits
                    base22  = {1'b0, pf_q[15:0], 5'b0};
                    // left word:  base + row*2    (row*2 is 5-bit at most: 15*2+1=31)
                    // right word: base + row*2 + 1
                    gfx_left_r  <= base22 + {17'b0, ry, 1'b0};
                    gfx_right_r <= base22 + {17'b0, ry, 1'b0} + 22'd1;
                end
                state <= BG_GFX0;
            end

            // ─── Latch left data; present right address ──────────────────────
            // state=BG_GFX0 → gfx_addr=gfx_left_r → gfx_data=gfx_rom[gfx_left_r].
            // Latch left data here; combinational block will switch to gfx_right_r
            // next cycle when state becomes BG_GFX1.
            BG_GFX0: begin
                gfx_left_data_r <= gfx_data;
                state            <= BG_GFX1;
            end

            // ─── Latch right data ────────────────────────────────────────────
            // state=BG_GFX1 → gfx_addr=gfx_right_r → gfx_data=gfx_rom[gfx_right_r].
            BG_GFX1: begin
                gfx_right_data_r <= gfx_data;
                state             <= BG_WRITE;
            end

            // ─── Decode 16 pixels; write linebuf; advance ────────────────────
            // Both gfx_left_data_r and gfx_right_data_r are valid.
            //
            // With X zoom: each output pixel p in 0..15 maps to source canvas_x
            // computed from the zoom accumulator:
            //   canvas_x_fp = run_zoom_acc_fp + p * run_zoom_step
            //   canvas_x    = canvas_x_fp >> 8   (integer part)
            //   px_in_tile  = canvas_x & 0xF     (pixel column within this 16-px tile)
            //
            // The tile fetched (map_tx) corresponds to run_zoom_acc_fp's tile column,
            // which is the canvas tile at the start of this 16-output-pixel slot.
            // Pixels whose canvas_x falls outside this tile (mod 16 wraps) are handled
            // by the px_in_tile extraction, which gives correct nibble select.
            //
            // Screen column: scol = tile_col * 16 - run_xoff + p  (unchanged from Step 5).
            BG_WRITE: begin
                begin
                    logic signed [10:0] scol_base;
                    scol_base = $signed({1'b0, tile_col, 4'b0}) -
                                $signed({7'b0, run_xoff});

/* verilator lint_off UNUSED */
                    for (int px = 0; px < 16; px++) begin
                        automatic logic signed [10:0] scol;
                        // acc_px: per-pixel zoom accumulator (19-bit).
                        // canvas_x[3:0] = acc_px[11:8] (bits above fractional 8 bits,
                        // below tile-column bits). Only [11:8] are used; others suppressed.
                        automatic logic [18:0] acc_px;
                        automatic logic [ 3:0] px_tile; // pixel within 16-px tile
                        automatic logic [ 2:0] ni;      // nibble index within 8-px half
                        automatic logic [31:0] src;     // 8-pixel source word
                        automatic logic [ 4:0] sh;      // nibble shift amount
                        automatic logic [ 3:0] pen;

                        scol    = scol_base + $signed(11'(px));
                        acc_px  = run_zoom_acc_fp + 19'(px) * 19'({10'b0, run_zoom_step});
                        px_tile = acc_px[11:8];   // canvas_x[3:0]

                        // Select left (0..7) or right (8..15) fetch word based on
                        // canvas pixel position (px_tile[3]). Zoom does not change
                        // which half is selected — that is determined by the source
                        // canvas pixel's half-tile position.
                        src = px_tile[3] ? gfx_right_data_r : gfx_left_data_r;

                        // Nibble index within the selected 8-px word.
                        // Normal:  ni = px_tile[2:0] (pixel 0 of the half → nibble 0 → bits[31:28])
                        // FlipX:   ni = 7 - px_tile[2:0] (reverse nibble order within the half)
                        ni  = tile_flipx_r ? 3'(7 - px_tile[2:0]) : 3'(px_tile[2:0]);

                        // Extract nibble: ni=0 → bits[31:28], ni=7 → bits[3:0]
                        sh  = 5'({2'b00, ni} << 2);    // ni * 4
                        sh  = 5'd28 - sh;               // 28 - ni*4
                        pen = 4'(src >> sh);

                        if (scol >= 0 && scol < 320) begin
                            // Palette addition (Step 7): add run_pal_add_lines to tile_palette_r.
                            // Both are 9-bit; wrap mod 512 naturally.
                            linebuf[scol[8:0]] <= {tile_palette_r + run_pal_add_lines, pen};
                        end
                    end
                end

                begin
                    // Advance zoom accumulator by 16 output pixels.
                    // next_zoom_acc_fp was computed combinationally above.
                    // Derive next map_tx from the new accumulator.
                    // next_canvas_x tile column = next_zoom_acc_fp[17:12] (canvas_x[9:4])
                    logic [5:0] next_tx;
                    next_tx = next_zoom_acc_fp[17:12] & (run_extend ? 6'h3F : 6'h1F);

                    run_zoom_acc_fp <= next_zoom_acc_fp;

                    if (tile_col == 5'd20) begin
                        state <= BG_IDLE;
                    end else begin
                        tile_col <= tile_col + 5'd1;
                        map_tx   <= next_tx;
                        state    <= BG_ATTR;
                    end
                end
            end

            default: state <= BG_IDLE;
        endcase
    end
end

endmodule
