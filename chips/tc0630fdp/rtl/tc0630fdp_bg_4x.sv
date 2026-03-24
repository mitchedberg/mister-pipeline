`default_nettype none
// =============================================================================
// TC0630FDP — 4× Time-Multiplexed BG Tilemap Engine  (Phase 1 ALM optimisation)
// =============================================================================
// Replaces the 4-instance generate of tc0630fdp_bg with a single instance
// running at 4× pixel clock, processing layers PF1–PF4 sequentially within
// each HBLANK window.
//
// Architecture:
//   · clk_4x = 4× pixel clock (≈96 MHz when pixel clock ≈24 MHz)
//   · clk    = pixel clock domain for all pixel-rate I/O
//   · Layer counter cycles 0→1→2→3 within each HBLANK period.
//     Layer 0 occupies the first 112×4/4 = 112 clk_4x cycles of HBLANK,
//     layer 1 the next 112, etc.  Total budget: 448 clk_4x cycles.
//     Each layer needs ≤106 clk_4x cycles for 21 tiles (5-state FSM).
//   · 4 separate linebuffers (320×13 each), one per layer.
//     Written at clk_4x during HBLANK; read at clk during active display.
//     Cross-domain safety: buffers are written only during HBLANK and read
//     only during active display — non-overlapping, no synchronisation needed.
//   · 4 sets of per-layer input muxes selected by layer_idx.
//   · Single shared GFX ROM interface (one access per state, serialised).
//   · 4 separate PF RAM read ports (one per layer; active on that layer's slot).
//
// Timing (pixel clock = clk, 4× clock = clk_4x):
//   HBLANK active = hpos < H_START (46 cycles at clk = 184 cycles at clk_4x)
//                 + hpos >= H_END  (66 cycles at clk = 264 cycles at clk_4x)
//   Total HBLANK: 448 clk_4x cycles per scanline.
//   Per-layer budget: 112 clk_4x cycles.  FSM uses ≤106 cycles.
//
// Reset / layer sequencing:
//   At the start of HBLANK (hblank_rise in clk domain, sampled into clk_4x),
//   layer_idx resets to 0 and the FSM starts layer 0.  When the FSM completes
//   (returns to BG_IDLE with done_r asserted), layer_idx increments and the
//   FSM restarts with the new layer's inputs.
// =============================================================================

module tc0630fdp_bg_4x (
    // ── Clocks and Reset ─────────────────────────────────────────────────────
    input  logic        clk,            // pixel clock (≈24 MHz)
    input  logic        clk_4x,         // 4× pixel clock (≈96 MHz)
    input  logic        rst_n,          // synchronous reset (active low, clk domain)

    // ── Video timing (pixel clock domain) ────────────────────────────────────
    input  logic        hblank,
    input  logic [ 8:0] vpos,
    input  logic [ 9:0] hpos,

    // ── Scroll registers (one set per layer) ─────────────────────────────────
    input  logic [3:0][15:0] pf_xscroll,
    input  logic [3:0][15:0] pf_yscroll,

    // ── Extend mode ──────────────────────────────────────────────────────────
    input  logic        extend_mode,

    // ── Per-scanline Line RAM outputs (one set per layer) ────────────────────
    input  logic [3:0][15:0] ls_rowscroll,
    input  logic [3:0]       ls_alt_tilemap,
    input  logic [3:0][ 7:0] ls_zoom_x,
    input  logic [3:0][ 7:0] ls_zoom_y,
    input  logic [3:0][ 8:0] ls_colscroll,
    input  logic [3:0][15:0] ls_pal_add,
    input  logic [3:0]       ls_mosaic_en,
    input  logic [ 3:0]      ls_mosaic_rate,

    // ── PF RAM read ports (4 independent ports, one per layer) ───────────────
    output logic [3:0][12:0] pf_rd_addr,
    input  logic [3:0][15:0] pf_q,

    // ── GFX ROM read port (shared, serialised by layer counter) ──────────────
    output logic [21:0] gfx_addr,
    input  logic [31:0] gfx_data,
    output logic        gfx_rd,

    // ── Pixel outputs (one per layer, pixel clock domain) ────────────────────
    // Format: {palette[8:0], pen[3:0]}; pen==0 → transparent
    output logic [3:0][12:0] bg_pixel
);

// =============================================================================
// Constants
// =============================================================================
localparam int H_START = 46;
localparam int H_END   = 366;

// =============================================================================
// Cross-domain: hblank_rise in clk domain → synchronised into clk_4x domain.
// We need a 2-cycle synchroniser since clk and clk_4x are related (4×) but
// separate clock domains in the tool's eyes.
// =============================================================================
logic hblank_r_clk;   // hblank delayed 1 cycle in clk domain
logic hblank_rise_clk; // hblank rising edge in clk domain

always_ff @(posedge clk) begin
    if (!rst_n) hblank_r_clk  <= 1'b0;
    else        hblank_r_clk  <= hblank;
end
assign hblank_rise_clk = hblank & ~hblank_r_clk;

// Synchronise hblank_rise into clk_4x domain (2-FF sync)
logic [1:0] hrise_sync;
always_ff @(posedge clk_4x) begin
    if (!rst_n) hrise_sync <= 2'b00;
    else        hrise_sync <= {hrise_sync[0], hblank_rise_clk};
end
logic hblank_rise_4x;
assign hblank_rise_4x = hrise_sync[1];

// =============================================================================
// Synchronise vpos and current layer's line-ram outputs into clk_4x domain.
// These are stable at HBLANK start and held for the entire HBLANK period.
// A simple registered capture is sufficient (they don't change during HBLANK).
// =============================================================================
logic [ 8:0] vpos_4x;
always_ff @(posedge clk_4x) begin
    if (!rst_n) vpos_4x <= 9'b0;
    else        vpos_4x <= vpos;
end

// All per-layer inputs also captured at hblank_rise into clk_4x domain.
logic [3:0][15:0] pf_xscroll_4x;
logic [3:0][15:0] pf_yscroll_4x;
logic             extend_mode_4x;
logic [3:0][15:0] ls_rowscroll_4x;
logic [3:0]       ls_alt_tilemap_4x;
logic [3:0][ 7:0] ls_zoom_x_4x;
logic [3:0][ 7:0] ls_zoom_y_4x;
logic [3:0][ 8:0] ls_colscroll_4x;
logic [3:0][15:0] ls_pal_add_4x;

always_ff @(posedge clk_4x) begin
    if (hrise_sync[0]) begin   // capture on the cycle before hblank_rise_4x asserts
        pf_xscroll_4x    <= pf_xscroll;
        pf_yscroll_4x    <= pf_yscroll;
        extend_mode_4x   <= extend_mode;
        ls_rowscroll_4x  <= ls_rowscroll;
        ls_alt_tilemap_4x<= ls_alt_tilemap;
        ls_zoom_x_4x     <= ls_zoom_x;
        ls_zoom_y_4x     <= ls_zoom_y;
        ls_colscroll_4x  <= ls_colscroll;
        ls_pal_add_4x    <= ls_pal_add;
    end
end

// =============================================================================
// Layer counter — advances after each layer's FSM completes.
// =============================================================================
logic [1:0] layer_idx;    // current active layer (0–3)
logic       layer_done;   // FSM has returned to BG_IDLE after being active
logic       fsm_start;    // 1-cycle pulse to kick off FSM for current layer_idx
logic       fsm_active;   // 1 from fsm_start until FSM returns to BG_IDLE

// fsm_active: set on fsm_start, clear when FSM returns to BG_IDLE.
// Prevents layer_done from firing before the FSM has been started.
always_ff @(posedge clk_4x) begin
    if (!rst_n) begin
        fsm_active <= 1'b0;
    end else begin
        if (fsm_start)
            fsm_active <= 1'b1;
        else if (state == BG_IDLE)
            fsm_active <= 1'b0;
    end
end

// layer_done: FSM returns to IDLE after being active (not spurious idle at reset)
assign layer_done = fsm_active & (state == BG_IDLE);

always_ff @(posedge clk_4x) begin
    if (!rst_n) begin
        layer_idx <= 2'd0;
        fsm_start <= 1'b0;
    end else begin
        fsm_start <= 1'b0;
        if (hblank_rise_4x) begin
            layer_idx <= 2'd0;
            fsm_start <= 1'b1;
        end else if (layer_done && layer_idx != 2'd3) begin
            layer_idx <= layer_idx + 2'd1;
            fsm_start <= 1'b1;
        end
    end
end

// =============================================================================
// Input mux: select current layer's inputs based on layer_idx.
// =============================================================================
logic [15:0] cur_pf_xscroll;
logic [15:0] cur_pf_yscroll;
logic        cur_extend_mode;
logic [15:0] cur_ls_rowscroll;
logic        cur_ls_alt_tilemap;
logic [ 7:0] cur_ls_zoom_x;
logic [ 7:0] cur_ls_zoom_y;
logic [ 8:0] cur_ls_colscroll;
logic [15:0] cur_ls_pal_add;
logic [15:0] cur_pf_q;

always_comb begin
    cur_pf_xscroll     = pf_xscroll_4x   [layer_idx];
    cur_pf_yscroll     = pf_yscroll_4x   [layer_idx];
    cur_extend_mode    = extend_mode_4x;
    cur_ls_rowscroll   = ls_rowscroll_4x [layer_idx];
    cur_ls_alt_tilemap = ls_alt_tilemap_4x[layer_idx];
    cur_ls_zoom_x      = ls_zoom_x_4x   [layer_idx];
    cur_ls_zoom_y      = ls_zoom_y_4x   [layer_idx];
    cur_ls_colscroll   = ls_colscroll_4x [layer_idx];
    cur_ls_pal_add     = ls_pal_add_4x   [layer_idx];
    cur_pf_q           = pf_q           [layer_idx];
end

// =============================================================================
// PF RAM address: route current layer's pf_rd_addr output.
// Other layers' pf_rd_addr are held 0 (inactive).
// =============================================================================
logic [12:0] fsm_pf_rd_addr;

always_comb begin
    for (int i = 0; i < 4; i++)
        pf_rd_addr[i] = 13'b0;
    pf_rd_addr[layer_idx] = fsm_pf_rd_addr;
end

// =============================================================================
// Per-layer 4 line buffers: 320 × 13-bit.
// MLAB for FPGA synthesis (async read, no power-of-two restriction).
// Written during HBLANK (clk_4x domain), read during display (clk domain).
// Cross-domain safe: write and read phases are mutually exclusive.
// =============================================================================
`ifdef QUARTUS
(* ramstyle = "MLAB" *) logic [12:0] linebuf [0:3][0:319];
`else
logic [12:0] linebuf [0:3][0:319];
`endif

// Linebuf writes happen directly in the FSM always_ff block below.
// (16 parallel writes per BG_WRITE cycle — valid for MLAB/register arrays)

// =============================================================================
// Pixel read (clk domain): mosaic-snapped column → bg_pixel[0..3]
// =============================================================================
logic [8:0] scol_c;
always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_START + 320))
        scol_c = hpos[8:0] - 9'(H_START);
    else
        scol_c = 9'd0;
end

// Mosaic snap (applied uniformly — uses per-layer mosaic inputs)
// For QUARTUS compatibility, generate 4 snap computations:
genvar gi;
generate
    for (gi = 0; gi < 4; gi++) begin : gen_bg_out
        logic [8:0] snap_col;
        always_comb begin
            logic [9:0] gx_wide;
            logic [8:0] grid_sum;
            logic [8:0] sr;
            logic [4:0] off;

            gx_wide  = {1'b0, scol_c} + 10'd114;
            grid_sum = (gx_wide >= 10'd432) ? gx_wide[8:0] - 9'd432 : gx_wide[8:0];
            sr       = 9'd1 + {5'b0, ls_mosaic_rate};
            off      = 5'(grid_sum % sr);

            if (ls_mosaic_en[gi] && ls_mosaic_rate != 4'd0)
                snap_col = 9'(scol_c - {5'b0, off});
            else
                snap_col = scol_c;
        end

        assign bg_pixel[gi] = linebuf[gi][snap_col];
    end
endgenerate

// =============================================================================
// Fetch geometry: Y zoom computation for current layer.
// =============================================================================
/* verilator lint_off UNUSED */
logic [16:0] cy_zoomed_w;
/* verilator lint_on UNUSED */
logic [ 3:0] fetch_py;
logic [ 4:0] fetch_ty;
logic        fetch_extend;

always_comb begin
    logic [8:0] canvas_y_raw;
    canvas_y_raw = (vpos_4x[8:0] + 9'd1) + cur_pf_yscroll[15:7];
    cy_zoomed_w  = {1'b0, canvas_y_raw} * {1'b0, cur_ls_zoom_y};
end

always_comb begin
    logic [8:0] canvas_y;
    canvas_y     = cy_zoomed_w[15:7];
    fetch_py     = canvas_y[3:0];
    fetch_ty     = canvas_y[8:4];
    fetch_extend = cur_extend_mode;
end

// =============================================================================
// FSM state machine — identical logic to tc0630fdp_bg, runs at clk_4x.
// =============================================================================
typedef enum logic [2:0] {
    BG_IDLE     = 3'd0,
    BG_ATTR     = 3'd1,
    BG_CODE     = 3'd2,
    BG_GFX0     = 3'd3,
    BG_GFX1     = 3'd4,
    BG_WRITE    = 3'd5,
    BG_PREFETCH = 3'd6
} bg_state_t;

bg_state_t  state;
logic [4:0] tile_col;
logic [5:0] map_tx;
logic [4:0] map_ty;

logic [3:0] run_py;
logic [3:0] run_xoff;
logic       run_extend;
logic       run_alt;
logic [8:0] run_zoom_step;
logic [18:0] run_zoom_acc_fp;
logic [8:0] run_pal_add_lines;

logic [8:0] tile_palette_r;
logic       tile_flipx_r;
logic       tile_flipy_r;
/* verilator lint_off UNUSED */
logic [15:0] tile_code_r;
logic        tile_blend_r;
logic [1:0]  tile_xplanes_r;
/* verilator lint_on UNUSED */

logic [21:0] gfx_left_r;
logic [21:0] gfx_right_r;
logic [31:0] gfx_left_data_r;
logic [31:0] gfx_right_data_r;

// PF RAM address logic (same as tc0630fdp_bg)
logic [12:0] pf_attr_addr_c;
logic [12:0] pf_code_addr_c;

always_comb begin
    logic [11:0] tileword_base;
    logic [12:0] base_addr;
    if (run_extend)
        tileword_base = {map_ty, map_tx, 1'b0};
    else
        tileword_base = {1'b0, map_ty, map_tx[4:0], 1'b0};
    base_addr = {1'b0, tileword_base} + (run_alt ? 13'h1000 : 13'h0000);
    pf_attr_addr_c = base_addr;
    pf_code_addr_c = base_addr + 13'd1;
end

logic [18:0] next_zoom_acc_fp;
always_comb begin
    logic [12:0] step16;
    step16 = {4'b0, run_zoom_step} << 4;
    next_zoom_acc_fp = run_zoom_acc_fp + {6'b0, step16};
end

`ifdef QUARTUS
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

`ifdef QUARTUS
always_comb begin
    case (state)
        BG_PREFETCH: fsm_pf_rd_addr = pf_attr_addr_c;
        BG_ATTR:     fsm_pf_rd_addr = pf_code_addr_c;
        BG_WRITE:    fsm_pf_rd_addr = pf_attr_addr_next_c;
        default:     fsm_pf_rd_addr = 13'b0;
    endcase
end
`else
always_comb begin
    case (state)
        BG_ATTR:  fsm_pf_rd_addr = pf_attr_addr_c;
        BG_CODE:  fsm_pf_rd_addr = pf_code_addr_c;
        default:  fsm_pf_rd_addr = 13'b0;
    endcase
end
`endif

// Attribute decode
logic [8:0] attr_palette_c;
logic       attr_flipx_c;
logic       attr_flipy_c;
logic       attr_blend_c;
logic [1:0] attr_xplanes_c;
assign attr_palette_c  = cur_pf_q[8:0];
assign attr_blend_c    = cur_pf_q[9];
assign attr_xplanes_c  = cur_pf_q[11:10];
assign attr_flipx_c    = cur_pf_q[14];
assign attr_flipy_c    = cur_pf_q[15];

// GFX ROM address
always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 22'b0;
    case (state)
        BG_GFX0: begin gfx_addr = gfx_left_r;  gfx_rd = 1'b1; end
        BG_GFX1: begin gfx_addr = gfx_right_r; gfx_rd = 1'b1; end
        default: begin gfx_addr = 22'b0;        gfx_rd = 1'b0; end
    endcase
end

// Suppress unused warnings
/* verilator lint_off UNUSED */
logic _unused_scroll;
assign _unused_scroll = ^{cur_pf_xscroll[5:0], cur_pf_yscroll[6:0],
                          cur_ls_rowscroll[5:0], cur_ls_pal_add[3:0],
                          cur_ls_pal_add[15:13]};
/* verilator lint_on UNUSED */

// =============================================================================
// FSM (clk_4x domain)
// =============================================================================
always_ff @(posedge clk_4x) begin
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
            BG_IDLE: begin
                if (fsm_start) begin
                    // Compute effective X scroll
                    logic [9:0]  eff_x_base;
                    logic [9:0]  eff_x;
                    logic [8:0]  zstep;
                    logic [18:0] zacc;
                    eff_x_base = cur_pf_xscroll[15:6] + cur_ls_rowscroll[15:6];
                    eff_x = eff_x_base + {1'b0, cur_ls_colscroll};
                    run_xoff <= eff_x[3:0];
                    zstep = 9'd256 + {1'b0, cur_ls_zoom_x};
                    run_zoom_step <= zstep;
                    zacc = {1'b0, eff_x, 8'b0};
                    run_zoom_acc_fp <= zacc;
                    map_tx <= eff_x[9:4] & (fetch_extend ? 6'h3F : 6'h1F);
                    tile_col          <= 5'b0;
                    map_ty            <= fetch_ty;
                    run_py            <= fetch_py;
                    run_extend        <= fetch_extend;
                    run_alt           <= cur_ls_alt_tilemap;
                    run_pal_add_lines <= cur_ls_pal_add[12:4];
`ifdef QUARTUS
                    state <= BG_PREFETCH;
`else
                    state <= BG_ATTR;
`endif
                end
            end

            BG_PREFETCH: begin
                state <= BG_ATTR;
            end

            BG_ATTR: begin
                tile_palette_r <= attr_palette_c;
                tile_blend_r   <= attr_blend_c;
                tile_xplanes_r <= attr_xplanes_c;
                tile_flipx_r   <= attr_flipx_c;
                tile_flipy_r   <= attr_flipy_c;
                state          <= BG_CODE;
            end

            BG_CODE: begin
                tile_code_r <= cur_pf_q;
                begin
                    logic [3:0]  ry;
                    logic [21:0] base22;
                    ry      = tile_flipy_r ? (4'd15 - run_py) : run_py;
                    base22  = {1'b0, cur_pf_q[15:0], 5'b0};
                    gfx_left_r  <= base22 + {17'b0, ry, 1'b0};
                    gfx_right_r <= base22 + {17'b0, ry, 1'b0} + 22'd1;
                end
                state <= BG_GFX0;
            end

            BG_GFX0: begin
                gfx_left_data_r <= gfx_data;
                state            <= BG_GFX1;
            end

            BG_GFX1: begin
                gfx_right_data_r <= gfx_data;
                state             <= BG_WRITE;
            end

            BG_WRITE: begin
                begin
                    logic signed [10:0] scol_base;
                    scol_base = $signed({1'b0, tile_col, 4'b0}) -
                                $signed({7'b0, run_xoff});

/* verilator lint_off UNUSED */
                    for (int px = 0; px < 16; px++) begin
                        logic signed [10:0] scol;
                        logic [18:0] acc_px;
                        logic [ 3:0] px_tile;
                        logic [ 2:0] ni;
                        logic [31:0] src;
                        logic [ 4:0] sh;
                        logic [ 3:0] pen;

                        scol    = scol_base + $signed(11'(px));
                        acc_px  = run_zoom_acc_fp + 19'(px) * 19'({10'b0, run_zoom_step});
                        px_tile = acc_px[11:8];

                        src = px_tile[3] ? gfx_right_data_r : gfx_left_data_r;
                        ni  = tile_flipx_r ? 3'(7 - px_tile[2:0]) : 3'(px_tile[2:0]);
                        sh  = 5'({2'b00, ni} << 2);
                        sh  = 5'd28 - sh;
                        pen = 4'(src >> sh);

                        if (scol >= 0 && scol < 320) begin
                            // Palette addition: add run_pal_add_lines to tile_palette_r.
                            linebuf[layer_idx][scol[8:0]] <=
                                {tile_palette_r + run_pal_add_lines, pen};
                        end
                    end
/* verilator lint_on UNUSED */
                end

                begin
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
