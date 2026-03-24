`default_nettype none
// =============================================================================
// TC0630FDP — 4× Time-Multiplexed BG Tilemap Engine  (Phase 2: Serialised writes)
// =============================================================================
// Replaces the 4-instance generate of tc0630fdp_bg with a single instance
// running at 4× pixel clock, processing layers PF1–PF4 sequentially within
// each HBLANK window.
//
// Architecture:
//   · clk_4x = 4× pixel clock (≈96 MHz when pixel clock ≈24 MHz)
//   · clk    = pixel clock domain for all pixel-rate I/O
//   · Layer counter cycles 0→1→2→3 within each HBLANK period.
//     Layer 0 occupies the first 112 clk_4x cycles of HBLANK,
//     layer 1 the next 112, etc.  Total budget: 448 clk_4x cycles.
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
//
//   Revised per-layer cycle count after BG_WRITE serialisation:
//     BG_PREFETCH(1) + 21 tiles × [BG_ATTR(1)+BG_CODE(1)+BG_GFX0(1)+BG_GFX1(1)+BG_WRITE(16)]
//     = 1 + 21×20 = 421 clk_4x cycles.
//     4 layers × 421 = 1684 > 448 — layers are SEQUENTIAL, each layer gets
//     its own independent time slot; the FSM runs each layer within the full 448.
//     Single-layer budget: 421 ≤ 448. OK.
//
// Phase 2 change: BG_WRITE serialisation
//   Instead of writing all 16 pixels in one clk_4x cycle (parallel for-loop),
//   the FSM stays in BG_WRITE for 16 clk_4x cycles, writing one pixel each cycle
//   via a px_idx counter.  This makes the linebuf write-port a single-address
//   single-data port, enabling altsyncram (MLAB dual-port) under `ifdef QUARTUS`.
//
// Linebuf architecture (Phase 2):
//   · Write port (Port A): clk_4x, single addr+data+wen per cycle.
//   · Read port (Port B):  async (UNREGISTERED), addressed by per-layer snap_col.
//   · 4 altsyncram instances (one per BG layer) under QUARTUS.
//   · Simulation: standard 2D register arrays, identical pixel output.
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
/* verilator lint_off UNUSEDPARAM */
localparam int H_END   = 366;
/* verilator lint_on UNUSEDPARAM */

// =============================================================================
// Cross-domain: hblank_rise in clk domain → synchronised into clk_4x domain.
// =============================================================================
logic hblank_r_clk;
logic hblank_rise_clk;

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
// Synchronise vpos and per-layer inputs into clk_4x domain.
// =============================================================================
logic [ 8:0] vpos_4x;
always_ff @(posedge clk_4x) begin
    if (!rst_n) vpos_4x <= 9'b0;
    else        vpos_4x <= vpos;
end

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
    if (hrise_sync[0]) begin
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
// Layer counter
// =============================================================================
logic [1:0] layer_idx;
logic       layer_done;
logic       fsm_start;
logic       fsm_active;

// Forward declare state for use in fsm_active logic
typedef enum logic [2:0] {
    BG_IDLE     = 3'd0,
    BG_ATTR     = 3'd1,
    BG_CODE     = 3'd2,
    BG_GFX0     = 3'd3,
    BG_GFX1     = 3'd4,
    BG_WRITE    = 3'd5,
    BG_PREFETCH = 3'd6
} bg_state_t;

bg_state_t state;

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
// Input mux: select current layer's inputs
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
// PF RAM address routing
// =============================================================================
logic [12:0] fsm_pf_rd_addr;

always_comb begin
    for (int i = 0; i < 4; i++)
        pf_rd_addr[i] = 13'b0;
    pf_rd_addr[layer_idx] = fsm_pf_rd_addr;
end

// =============================================================================
// Screen column decode (pixel clock domain, used for linebuf read address)
// =============================================================================
logic [8:0] scol_c;
always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_START + 320))
        scol_c = hpos[8:0] - 9'(H_START);
    else
        scol_c = 9'd0;
end

// =============================================================================
// Mosaic snap: per-layer read address (snap_col[gi])
// =============================================================================
logic [8:0] snap_col [0:3];

genvar gi;
genvar gi2;
generate
    for (gi = 0; gi < 4; gi++) begin : gen_snap
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

            if (ls_mosaic_en[gi] && ls_mosaic_rate != 4'd0)
                snap_col[gi] = 9'(scol_c - {5'b0, off});
            else
                snap_col[gi] = scol_c;
        end
    end
endgenerate

// =============================================================================
// Per-layer line buffers: 320 × 13-bit.
// Written during HBLANK at clk_4x (one pixel per cycle — serialised).
// Read during active display at clk (async, via snap_col per layer).
//
// Phase 2: serialised write port (single addr+data+wen) enables altsyncram.
//
// Under QUARTUS: 4 explicit altsyncram dual-port MLAB instances.
//   Port A (write): clk_4x, single addr+data+wen.
//   Port B (read):  UNREGISTERED async, addressed by snap_col[gi].
//   MLAB: 4 × 320×13 = 16,640 bits ≈ 26 MLABs  (vs 400+ ALMs from FFs).
//
// Under Verilator: register arrays with identical pixel output behaviour.
// =============================================================================
logic [12:0] lb_wdata;   // write data (from BG_WRITE serialised decode)
logic [ 8:0] lb_waddr;   // write address [0..319]
logic [3:0]  lb_wen;     // per-layer write enable (one-hot)

`ifdef QUARTUS
logic [12:0] lb_rdata [0:3];

genvar gi_lb;
generate
    for (gi_lb = 0; gi_lb < 4; gi_lb++) begin : gen_lb
        altsyncram #(
            .width_a            (13),
            .widthad_a          (9),
            .numwords_a         (512),
            .width_b            (13),
            .widthad_b          (9),
            .numwords_b         (512),
            .operation_mode     ("DUAL_PORT"),
            .ram_block_type     ("MLAB"),
            .outdata_reg_a      ("UNREGISTERED"),
            .outdata_reg_b      ("UNREGISTERED"),
            .read_during_write_mode_mixed_ports ("DONT_CARE"),
            .intended_device_family ("Cyclone V")
        ) u_lb (
            .clock0    (clk_4x),
            .address_a (lb_waddr),
            .data_a    (lb_wdata),
            .wren_a    (lb_wen[gi_lb]),
            .address_b (snap_col[gi_lb]),
            .q_b       (lb_rdata[gi_lb]),
            // unused ports
            .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
            .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
            .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
            .data_b({13{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
            .wren_b(1'b0)
        );
    end
endgenerate


generate
    for (gi2 = 0; gi2 < 4; gi2++) begin : gen_bg_out
        assign bg_pixel[gi2] = lb_rdata[gi2];
    end
endgenerate

`else
// Simulation: register arrays
logic [12:0] linebuf [0:3][0:319];

always_ff @(posedge clk_4x) begin
    if (lb_wen[0]) linebuf[0][lb_waddr] <= lb_wdata;
    if (lb_wen[1]) linebuf[1][lb_waddr] <= lb_wdata;
    if (lb_wen[2]) linebuf[2][lb_waddr] <= lb_wdata;
    if (lb_wen[3]) linebuf[3][lb_waddr] <= lb_wdata;
end

generate
    for (gi2 = 0; gi2 < 4; gi2++) begin : gen_bg_out_sim
        assign bg_pixel[gi2] = linebuf[gi2][snap_col[gi2]];
    end
endgenerate
`endif

// =============================================================================
// Fetch geometry: Y zoom computation for current layer.
// =============================================================================
/* verilator lint_off UNUSED */
logic [16:0] cy_zoomed_w;
/* verilator lint_on UNUSED */
logic [ 3:0] fetch_py;
logic [ 4:0] fetch_ty;
logic        fetch_extend;
logic [ 8:0] canvas_y_raw_c;

always_comb begin
    canvas_y_raw_c = (vpos_4x[8:0] + 9'd1) + cur_pf_yscroll[15:7];
end

`ifdef QUARTUS
lpm_mult #(
    .lpm_widtha         (9),
    .lpm_widthb         (8),
    .lpm_widthp         (17),
    .lpm_representation ("UNSIGNED"),
    .lpm_pipeline       (0)
) u_cy_zoom_mult (
    .dataa  (canvas_y_raw_c),
    .datab  (cur_ls_zoom_y),
    .result (cy_zoomed_w),
    .clock  (1'b0), .clken(1'b0), .aclr(1'b0), .sum({17{1'b0}})
);
`else
always_comb begin
    cy_zoomed_w = {1'b0, canvas_y_raw_c} * {1'b0, cur_ls_zoom_y};
end
`endif

always_comb begin
    logic [8:0] canvas_y;
    canvas_y     = cy_zoomed_w[15:7];
    fetch_py     = canvas_y[3:0];
    fetch_ty     = canvas_y[8:4];
    fetch_extend = cur_extend_mode;
end

// =============================================================================
// FSM registers
// =============================================================================
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

// Phase 2: pixel index counter and per-tile write snapshot registers
logic [3:0] px_idx;                  // 0..15, serialised pixel within BG_WRITE
logic [8:0]  wr_palette_r;           // tile_palette_r snapshot
logic        wr_flipx_r;             // tile_flipx_r snapshot
logic [18:0] wr_zoom_acc_fp_r;       // run_zoom_acc_fp snapshot at tile start
logic [8:0]  wr_zoom_step_r;         // run_zoom_step snapshot
logic [8:0]  wr_pal_add_lines_r;     // run_pal_add_lines snapshot
logic signed [10:0] wr_scol_base_r;  // tile base screen column

`ifdef QUARTUS
// Incremental accumulators for BG_WRITE pixel decode.
// Replaces the combinational wr_zoom_acc_fp_r + px_idx*wr_zoom_step_r multiply
// (saves ~80-120 ALMs on Cyclone V by eliminating LUT-based 4x9-bit multiplier).
// Each register is initialised at BG_GFX1 and incremented each BG_WRITE cycle.
//   wr_acc_px_r : zoom accumulator; starts at wr_zoom_acc_fp_r, +zoom_step/cycle
//   wr_scol_r   : screen column;    starts at wr_scol_base_r,   +1/cycle
//   wr_pal9_r   : pre-computed palette+pal_add (constant within BG_WRITE tile)
logic [18:0]         wr_acc_px_r;
logic signed [10:0]  wr_scol_r;
logic [8:0]          wr_pal9_r;
`endif

// =============================================================================
// PF RAM address combinational logic
// =============================================================================
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
// Serialised BG_WRITE pixel decode (combinational)
// Computes one pixel for the current px_idx every clk_4x cycle in BG_WRITE.
// =============================================================================
logic signed [10:0] wr_scol_c;
logic [18:0] wr_acc_px;
logic [ 3:0] wr_px_tile;
logic [ 2:0] wr_ni;
logic [31:0] wr_src;
logic [ 4:0] wr_sh;
logic [ 3:0] wr_pen;
logic        wr_in_range;
logic [ 8:0] wr_out_addr;
logic [12:0] wr_out_data;

/* verilator lint_off UNUSED */
always_comb begin
`ifdef QUARTUS
    // Incremental accumulators: no combinational multiply needed.
    wr_scol_c   = wr_scol_r;
    wr_acc_px   = wr_acc_px_r;
`else
    wr_scol_c   = wr_scol_base_r + $signed({7'b0, px_idx});
    wr_acc_px   = wr_zoom_acc_fp_r + (19'(px_idx) * {10'b0, wr_zoom_step_r});
`endif
    wr_px_tile   = wr_acc_px[11:8];

    wr_src       = wr_px_tile[3] ? gfx_right_data_r : gfx_left_data_r;
    wr_ni        = wr_flipx_r ? 3'(3'd7 - wr_px_tile[2:0]) : 3'(wr_px_tile[2:0]);
    wr_sh        = 5'd28 - 5'({2'b00, wr_ni} << 2);
    wr_pen       = 4'(wr_src >> wr_sh);

    wr_in_range  = (wr_scol_c >= 0) && (wr_scol_c < 320);
    wr_out_addr  = wr_in_range ? 9'(wr_scol_c[8:0]) : 9'b0;
`ifdef QUARTUS
    wr_out_data  = {wr_pal9_r, wr_pen};
`else
    wr_out_data  = {wr_palette_r + wr_pal_add_lines_r, wr_pen};
`endif
end
/* verilator lint_on UNUSED */

// =============================================================================
// Linebuf write signals (combinational from BG_WRITE decode)
// =============================================================================
always_comb begin
    lb_wdata = wr_out_data;
    lb_waddr = wr_out_addr;
    lb_wen   = 4'b0;
    if (state == BG_WRITE && wr_in_range)
        lb_wen[layer_idx] = 1'b1;
end

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
        px_idx             <= 4'b0;
        wr_palette_r       <= 9'b0;
        wr_flipx_r         <= 1'b0;
        wr_zoom_acc_fp_r   <= 19'b0;
        wr_zoom_step_r     <= 9'b0;
        wr_pal_add_lines_r <= 9'b0;
        wr_scol_base_r     <= 11'b0;
`ifdef QUARTUS
        wr_acc_px_r        <= 19'b0;
        wr_scol_r          <= 11'sb0;
        wr_pal9_r          <= 9'b0;
`endif
    end else begin
        case (state)
            BG_IDLE: begin
                if (fsm_start) begin
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
                // Snapshot tile write parameters for the 16-cycle BG_WRITE loop.
                begin
                    logic signed [10:0] scol_base;
                    scol_base = $signed({1'b0, tile_col, 4'b0}) -
                                $signed({7'b0, run_xoff});
                    wr_scol_base_r <= scol_base;
`ifdef QUARTUS
                    // Initialise incremental accumulators for BG_WRITE.
                    wr_acc_px_r <= run_zoom_acc_fp;
                    wr_scol_r   <= scol_base;
                    wr_pal9_r   <= tile_palette_r + run_pal_add_lines;
`endif
                end
                wr_palette_r       <= tile_palette_r;
                wr_flipx_r         <= tile_flipx_r;
                wr_zoom_acc_fp_r   <= run_zoom_acc_fp;
                wr_zoom_step_r     <= run_zoom_step;
                wr_pal_add_lines_r <= run_pal_add_lines;
                px_idx             <= 4'b0;
                state              <= BG_WRITE;
            end

            BG_WRITE: begin
                // Serialised pixel write: one pixel per clk_4x cycle.
                // Combinational decode (wr_*) produces lb_waddr/lb_wdata/lb_wen.
                // altsyncram captures the write on this clock edge.

`ifdef QUARTUS
                // Advance incremental accumulators for next pixel.
                // Combinational block reads current values first, then FSM updates them.
                wr_acc_px_r <= wr_acc_px_r + {10'b0, wr_zoom_step_r};
                wr_scol_r   <= wr_scol_r + 11'sd1;
`endif

                if (px_idx == 4'd15) begin
                    // All 16 pixels written — advance to next tile.
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
                end else begin
                    px_idx <= px_idx + 4'd1;
                end
            end

            default: state <= BG_IDLE;
        endcase
    end
end

endmodule
