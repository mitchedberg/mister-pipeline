`default_nettype none
// =============================================================================
// TC0480SCP — BG Tilemap Layer Engine  (Steps 4–8)
// =============================================================================
// One instance per BG layer (BG0–BG3). LAYER parameter = 0..3.
//
// ── Two rendering paths ──────────────────────────────────────────────────────
//
// NO-ZOOM PATH (zoomx==0x10000 && zoomy==0x10000):
//   Per-scanline rowscroll hi/lo applied.
//   BG0/BG1 HBLANK setup: read rs_hi, rs_lo (2 VRAM reads)
//   BG2/BG3 HBLANK setup: read colscroll, [rowzoom,] rs_hi, rs_lo (3–4 VRAM reads)
//   Pixel walk: x_index advances by 0x10000 (1 pixel per output pixel).
//
// ZOOM PATH (zoomx!=0x10000 || zoomy!=0x10000):
//   Y accumulator (y_index, 32-bit 16.16) starts at vblank and increments by
//   zoomy per scanline.
//   X accumulator (x_index_start, 32-bit) computed from sx_base at each scanline.
//   Rowscroll disabled in zoom mode (MAME bg01/bg23_draw spec).
//   BG2/BG3 still apply colscroll and per-row zoom.
//
// ── HBLANK FSM (BG0/BG1 no-zoom path — 4 states) ────────────────────────────
//
//   S0 → S1: issue rs_hi read
//   S1 → S2: latch rs_hi; issue rs_lo read
//   S2 → S3: latch rs_lo; compute x_index_start
//   S3:      start tile fill (BG_CODE)
//
// ── HBLANK FSM (BG2/BG3 full path — 6 states) ───────────────────────────────
//
//   S0: issue colscroll_ram[col_idx] read
//   S1: latch colscroll; compute src_y (colscroll-adjusted)
//       issue rowzoom_ram[src_y] (if rowzoom_en) else rs_hi[src_y] read
//   S2: latch rowzoom (or rs_hi); compute x_step
//       if rowzoom_en: issue rs_hi[src_y] read
//       else: issue rs_lo[src_y] read
//   S3: latch rs_hi (or rs_lo); issue rs_lo (or compute) read
//   S4: latch rs_lo; compute x_index_start; start tile fill
//
// ── Critical ordering: colscroll BEFORE rowzoom ──────────────────────────────
//   src_y = (y_index>>16 + colscroll[col_idx]) & 0x1FF
//   rowzoom and rowscroll are then indexed by this colscroll-adjusted src_y.
//
// ── GFX ROM format (section1 §8.1) ───────────────────────────────────────────
//   32-bit words, word-addressed. Tile t, row r:
//     left  half (px0..7) : word t*32 + r*2
//     right half (px8..15): word t*32 + r*2 + 1
//   bits[31:28]=px0, [27:24]=px1, ..., [3:0]=px7
//   flipX: reverse nibble order within each half AND swap left/right halves.
//   flipY: use row (15 - py) instead of py.
// =============================================================================

/* verilator lint_off UNUSEDPARAM */
module tc0480scp_bg #(
    parameter int LAYER = 0
) (
/* verilator lint_on UNUSEDPARAM */
    input  logic        clk,
    input  logic        rst_n,

    // ── Video timing ──────────────────────────────────────────────────────
    input  logic        hblank,
    input  logic [ 9:0] hpos,
    input  logic [ 8:0] vpos,

    // ── Scroll / zoom / layer control ─────────────────────────────────────
    input  logic [15:0] bgscrollx,   // effective X scroll (stagger applied by regs)
    input  logic [15:0] bgscrolly,   // Y scroll
    input  logic [15:0] bgzoom,      // [15:8]=xzoom, [7:0]=yzoom
    input  logic [ 7:0] bg_dx,       // DX sub-pixel (low byte of ctrl[16+n])
    input  logic [ 7:0] bg_dy,       // DY sub-pixel
    input  logic        dblwidth,
    input  logic        flipscreen,  // reserved; flip logic added in Step 11
    input  logic        rowzoom_en,  // BG2/BG3 per-row zoom enable; tie 0 for BG0/BG1

    // ── VRAM tile map port (registered 1-cycle latency) ───────────────────
    output logic [14:0] vram_addr,
    output logic        vram_rd,
    input  logic [15:0] vram_q,

    // ── VRAM scroll/zoom/colscroll port (registered 1-cycle latency) ──────
    output logic [14:0] scram_addr,
    output logic        scram_rd,
    input  logic [15:0] scram_q,

    // ── GFX ROM async port (32-bit word-addressed) ────────────────────────
    output logic [20:0] gfx_addr,
    input  logic [31:0] gfx_data,
    output logic        gfx_rd,

    // ── Pixel output: {color[7:0], pen[3:0]}; pen==0 → transparent ───────
    output logic [11:0] bg_pixel,
    output logic        bg_valid
);

// =============================================================================
// Zoom decode (section1 §3.3)
//   zoomx = 0x10000 - (xzoom << 8)
//   zoomy = 0x10000 - ((yzoom - 0x7F) * 512)
// =============================================================================
logic [31:0] zoomx_c;
logic [31:0] zoomy_c;
always_comb begin
    logic [7:0]        xzoom;
    logic [8:0]        ydiff9;
    logic signed [9:0] ydiff;
    xzoom   = bgzoom[15:8];
    ydiff9  = {1'b0, bgzoom[7:0]} - 9'd127;  // yzoom - 0x7F (unsigned arithmetic, wrap ok)
    // Sign-extend 9-bit ydiff9 (bit8 = sign) to 10-bit signed ydiff.
    // $signed(ydiff9) treats the 9-bit value as two's complement.
    /* verilator lint_off WIDTHEXPAND */
    ydiff   = $signed(ydiff9);               // sign-extend 9→10 bits (bit8 is sign bit)
    /* verilator lint_on WIDTHEXPAND */
    // zoomx = 0x10000 - (xzoom << 8); range 0x0100..0x10000
    zoomx_c = 32'h00010000 - {16'd0, xzoom, 8'd0};
    // zoomy = 0x10000 - ydiff*512; range varies
    zoomy_c = 32'h00010000 - 32'($signed(32'd0) + $signed({ydiff, 9'd0}));
end

// 1:1 no-zoom condition
logic nozoom_c;
assign nozoom_c = (zoomx_c == 32'h00010000) && (zoomy_c == 32'h00010000);

// =============================================================================
// HBLANK edge detect (2-FF)
// =============================================================================
logic hblank_r, hblank_r2;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        hblank_r  <= 1'b0;
        hblank_r2 <= 1'b0;
    end else begin
        hblank_r  <= hblank;
        hblank_r2 <= hblank_r;
    end
end
logic hblank_rise;
assign hblank_rise = hblank_r & ~hblank_r2;

// =============================================================================
// VBLANK detect (y_index reset)
// =============================================================================
logic vblank_c;
logic prev_vblank_r;
assign vblank_c = (vpos < 9'd16) || (vpos >= 9'd256);
always_ff @(posedge clk) begin
    if (!rst_n) prev_vblank_r <= 1'b0;
    else        prev_vblank_r <= vblank_c;
end
logic vblank_rise;
assign vblank_rise = vblank_c && !prev_vblank_r;

// =============================================================================
// No-zoom fetch geometry (combinational)
// At vpos=15 (hblank before first active line), canvas_y = bgscrolly.
// =============================================================================
logic [8:0] canvas_y_c;
assign canvas_y_c = (vpos - 9'd15 + bgscrolly[8:0]) & 9'h1FF;

// Column-scroll index for BG2/BG3 (output scanline position)
// col_idx = (vpos - 15) & 0x1FF  matches MAME: (y - y_offset) where y_offset=0 for vpos=16..
// With V_START=16 and vpos=16 being first active line, at hblank before line 0: vpos=15.
// col_idx at the hblank moment = (15 - 15) & 0x1FF = 0.
// For hblank before line Y: vpos = 15 + Y → col_idx = Y & 0x1FF. Correct.
logic [8:0] col_idx_c;
assign col_idx_c = (vpos - 9'd15) & 9'h1FF;

// =============================================================================
// VRAM address helper functions
// =============================================================================

// Tilemap word address for tile (ty, tx) in this layer
function automatic logic [14:0] tile_attr_addr(
    input logic [4:0] ty,
    input logic [5:0] tx,
    input logic       dw
);
    logic [11:0] idx;
    logic [14:0] base;
    if (dw) begin
        idx  = {1'b0, ty, tx};         // ty=5b, tx=6b → 12 bits
        base = 15'(LAYER) << 11;
    end else begin
        idx  = {2'b0, ty, tx[4:0]};    // ty=5b, tx=5b → 12 bits
        base = 15'(LAYER) << 10;
    end
    return base + {2'b0, idx, 1'b0};
endfunction

// Rowscroll-hi word address for source row R
function automatic logic [14:0] rs_hi_addr(input logic [8:0] row, input logic dw);
    return (dw ? 15'h4000 : 15'h2000) + 15'(LAYER) * 15'h200 + {6'b0, row};
endfunction

// Rowscroll-lo word address for source row R
function automatic logic [14:0] rs_lo_addr(input logic [8:0] row, input logic dw);
    return (dw ? 15'h4800 : 15'h2800) + 15'(LAYER) * 15'h200 + {6'b0, row};
endfunction

// Row-zoom word address for source row R (BG2/BG3 only)
function automatic logic [14:0] rz_addr(input logic [8:0] row, input logic dw);
    logic [14:0] layer_off;
    layer_off = (15'(LAYER) - 15'd2) * 15'h200;
    return (dw ? 15'h5000 : 15'h3000) + layer_off + {6'b0, row};
endfunction

// Colscroll word address for column C (BG2/BG3 only)
function automatic logic [14:0] cs_addr(input logic [8:0] col, input logic dw);
    logic [14:0] layer_off;
    layer_off = (15'(LAYER) - 15'd2) * 15'h200;
    return (dw ? 15'h5400 : 15'h3400) + layer_off + {6'b0, col};
endfunction

// =============================================================================
// FSM state encoding
// =============================================================================
typedef enum logic [3:0] {
    BG_IDLE     = 4'd0,   // wait for hblank_rise
    BG_CODE     = 4'd1,   // latch attr; drive code read
    BG_GFX0     = 4'd2,   // latch code; drive left GFX; latch left
    BG_GFX1     = 4'd3,   // latch right GFX
    BG_WRITE    = 4'd4,   // decode+write linebuf; advance
    BG_S0       = 4'd5,   // issue first scram read
    BG_S1       = 4'd6,   // latch first result; issue second scram read
    BG_S2       = 4'd7,   // latch second result; issue third scram read (BG2/3) or compute
    BG_S3       = 4'd8,   // latch third (BG2/3); issue fourth scram read (BG2/3) or start fill
    BG_S4       = 4'd9,   // latch fourth (BG2/3); compute x_index_start; start fill
    BG_PRE_CODE = 4'd10   // drive correct first-tile attr read (now map_tx/map_ty are set)
} bg_state_t;

bg_state_t  state;

// Tile fill control
logic [4:0] tile_col;
logic [5:0] map_tx;
logic [4:0] map_ty;
logic [5:0] next_map_tx;
logic [3:0] run_py;
logic [3:0] run_xoff;
logic       run_extend;

// Tile attribute latches
logic [ 7:0] tile_color_r;
logic        tile_flipx_r;
logic        tile_flipy_r;
/* verilator lint_off UNUSED */
logic [14:0] tile_code_r;
/* verilator lint_on UNUSED */
logic [31:0] gfx_left_data_r;
logic [31:0] gfx_right_data_r;
logic [20:0] gfx_right_r;

// Per-scanline state
logic [ 8:0] src_y_raw_r;     // source Y before colscroll adjustment
logic [ 8:0] src_y_r;         // colscroll-adjusted source Y (BG2/3 only)
logic [31:0] x_step_r;        // per-pixel X advance
logic [31:0] x_index_start_r; // X accumulator start for this scanline
logic [31:0] y_index_r;       // Y accumulator (zoom path, 16.16)
logic [31:0] sx_base_r;       // zoom-mode sx base (computed at vblank)

// Scram intermediate latches
logic [15:0] colscroll_r;     // latched colscroll entry (BG2/3)
logic [15:0] rowzoom_r;       // latched rowzoom entry (BG2/3, when en=1)
logic [15:0] rs_hi_r;         // latched rowscroll-hi

// =============================================================================
// Next tile column (combinational, wraps per map_width)
// =============================================================================
always_comb begin
    next_map_tx = (map_tx + 6'd1) & (run_extend ? 6'h3F : 6'h1F);
end

// =============================================================================
// VRAM tile-map address mux (combinational)
// =============================================================================
logic [14:0] vram_attr_cur_c;
logic [14:0] vram_code_cur_c;
logic [14:0] vram_attr_next_c;
logic [14:0] vram_attr_init_c;

always_comb begin
    vram_attr_cur_c  = tile_attr_addr(map_ty, map_tx, run_extend);
    vram_code_cur_c  = vram_attr_cur_c + 15'd1;
    vram_attr_next_c = tile_attr_addr(map_ty, next_map_tx, run_extend);
    begin
        logic [5:0] init_tx_c;
        if (dblwidth)
            init_tx_c = {1'b0, bgscrollx[8:4]} & 6'h3F;
        else
            init_tx_c = {1'b0, bgscrollx[8:4]} & 6'h1F;
        vram_attr_init_c = tile_attr_addr(canvas_y_c[8:4], init_tx_c, dblwidth);
    end
end

always_comb begin
    vram_rd   = 1'b0;
    vram_addr = 15'b0;
    case (state)
        BG_IDLE:     begin end   // no attr prefetch; BG_PRE_CODE issues correct attr read
        BG_PRE_CODE: begin vram_addr = vram_attr_cur_c; vram_rd = 1'b1; end
        BG_CODE:     begin vram_addr = vram_code_cur_c; vram_rd = 1'b1; end
        BG_WRITE:    begin vram_addr = vram_attr_next_c; vram_rd = 1'b1; end
        default:     begin end
    endcase
end

// =============================================================================
// SCRAM address mux (combinational)
//
// BG0/BG1 sequence (no colscroll/rowzoom):
//   S0: issue rs_hi_addr(src_y_raw)
//   S1: issue rs_lo_addr(src_y_raw)
//   (S2: latch rs_lo, compute x_index_start, go to BG_S3 which starts fill)
//
// BG2/BG3 sequence (with colscroll and optional rowzoom):
//   S0: issue cs_addr(col_idx)
//   S1: latch colscroll → src_y; issue rz_addr(src_y) [or rs_hi if !rowzoom_en]
//   S2: latch rowzoom [or rs_hi]; if rowzoom_en issue rs_hi_addr(src_y) else issue rs_lo
//   S3: latch rs_hi [only if rowzoom_en]; issue rs_lo_addr(src_y)
//       [if !rowzoom_en: latch rs_lo, compute, start fill → BG_WRITE via BG_S4]
//   S4: latch rs_lo; compute x_index_start; start fill
//
// To keep the code simple we use a unified state machine where:
//   BG0/BG1 steps: S0(rs_hi) S1(rs_lo) S2(latch,compute) S3(start fill)
//   BG2/BG3 steps: S0(cs)   S1(rz/rs_hi) S2(rs_hi/rs_lo) S3(rs_lo/fill) S4(fill)
// =============================================================================

always_comb begin
    scram_rd   = 1'b0;
    scram_addr = 15'b0;
    case (state)
        BG_S0: begin
            scram_rd = 1'b1;
            if (LAYER >= 2)
                scram_addr = cs_addr(col_idx_c, dblwidth);
            else
                scram_addr = rs_hi_addr(src_y_raw_r, dblwidth);
        end
        BG_S1: begin
            scram_rd = 1'b1;
            if (LAYER >= 2) begin
                // At state==S1, scram_q holds the colscroll from S0 read (1-cycle registered latency).
                // adj_y_s1_c = (src_y_raw + colscroll_from_scram_q) & 0x1FF — computed at module level.
                // Issue rowzoom or rs_hi read using this colscroll-adjusted source row.
                if (rowzoom_en)
                    scram_addr = rz_addr(adj_y_s1_c, dblwidth);
                else
                    scram_addr = rs_hi_addr(adj_y_s1_c, dblwidth);
            end else begin
                scram_addr = rs_lo_addr(src_y_raw_r, dblwidth);
            end
        end
        BG_S2: begin
            if (LAYER >= 2) begin
                // rowzoom or rs_hi was latched. Now issue rs_hi (if rowzoom_en) or rs_lo.
                scram_rd = 1'b1;
                if (rowzoom_en)
                    scram_addr = rs_hi_addr(src_y_r, dblwidth);
                else
                    scram_addr = rs_lo_addr(src_y_r, dblwidth);
            end
            // BG0/1: no scram read in S2 (compute only)
        end
        BG_S3: begin
            if (LAYER >= 2 && rowzoom_en) begin
                // Issue rs_lo read
                scram_rd   = 1'b1;
                scram_addr = rs_lo_addr(src_y_r, dblwidth);
            end
            // If !rowzoom_en: BG2/3 already has rs_lo from S2; S3 latch + compute + start fill
        end
        default: begin end
    endcase
end

// =============================================================================
// Combinational adj_y for BG2/3 in S1 state (uses scram_q directly, not colscroll_r)
// Declared at module scope to avoid latch inference from within case branch.
// At state==S1, scram_q holds the colscroll result from the S0 read (1-cycle registered latency).
// =============================================================================
logic [8:0] adj_y_s1_c;
assign adj_y_s1_c = (src_y_raw_r + scram_q[8:0]) & 9'h1FF;

// =============================================================================
// Zoom sx_base computation (combinational, from MAME bg01_draw)
// MAME (non-flip):
//   sx = ((bgscrollx + 15 + layer*4) << 16)
//        + ((255 - bg_dx) << 8)
//        + (x_offset - 15 - layer*4) * zoomx
// With x_offset = 0:
//   sx = ((bgscrollx + 15 + layer*4) << 16)
//        + ((255 - bg_dx) << 8)
//        + (-15 - layer*4) * zoomx
// =============================================================================
logic [31:0] sx_zoom_c;
always_comb begin
    logic signed [31:0] term_scroll;
    logic signed [31:0] term_dx;
    logic signed [31:0] term_origin;
    logic signed [31:0] scroll_adj;
    logic signed [31:0] neg_origin;
    // MAME bg01_draw: sx uses raw ctrl register: scroll_adj = ctrl_raw + 15 + LAYER*4
    // bgscrollx = -(ctrl_raw + LAYER*4) for non-flip, so ctrl_raw = -bgscrollx - LAYER*4
    // scroll_adj = -bgscrollx - LAYER*4 + 15 + LAYER*4 = -bgscrollx + 15 (non-flip)
    // For flip: bgscrollx = ctrl_raw + LAYER*4, scroll_adj = +bgscrollx + 15
    scroll_adj  = (flipscreen ? $signed({{16{bgscrollx[15]}}, bgscrollx})
                               : -$signed({{16{bgscrollx[15]}}, bgscrollx})) + 32'sd15;
    term_scroll = scroll_adj << 16;
    // (255 - bg_dx) << 8
    term_dx     = $signed({24'd0, ~bg_dx}) << 8;   // ~bg_dx = 255 - bg_dx (for 8-bit)
    // (-15 - LAYER*4) * zoomx
    neg_origin  = -32'sd15 - $signed(32'(LAYER) * 32'sd4);
    term_origin = neg_origin * $signed({1'b0, zoomx_c[30:0]});
    sx_zoom_c   = 32'($signed(term_scroll + term_dx + term_origin));
end

// =============================================================================
// GFX ROM address
// =============================================================================
logic [20:0] gfx_left_addr_c;
always_comb begin
    logic [3:0]  ry_c;
    logic [20:0] base21_c;
    ry_c          = tile_flipy_r ? (4'd15 - run_py) : run_py;
    base21_c      = {1'b0, vram_q[14:0], 5'b0};
    gfx_left_addr_c = base21_c + {16'b0, ry_c, 1'b0};
end

always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 21'b0;
    case (state)
        BG_GFX0: begin gfx_addr = gfx_left_addr_c; gfx_rd = 1'b1; end
        BG_GFX1: begin gfx_addr = gfx_right_r;     gfx_rd = 1'b1; end
        default: begin end
    endcase
end

// =============================================================================
// Line buffer: 320 × 12-bit {color[7:0], pen[3:0]}
// =============================================================================
`ifdef QUARTUS
(* ramstyle = "MLAB" *) logic [11:0] linebuf [0:319];
`else
logic [11:0] linebuf [0:319];
`endif

logic [8:0] scol_c;
always_comb begin
    if (hpos < 10'd320)
        scol_c = hpos[8:0];
    else
        scol_c = 9'd0;
end

assign bg_pixel = linebuf[scol_c];
assign bg_valid = 1'b1;

// =============================================================================
// Start-tile helper (shared between BG_S3 / BG_S4)
// Called after x_index_start_r is ready.
// =============================================================================
// This logic is inlined in the FSM transitions below.

// =============================================================================
// FSM
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state            <= BG_IDLE;
        tile_col         <= 5'b0;
        map_tx           <= 6'b0;
        map_ty           <= 5'b0;
        run_py           <= 4'b0;
        run_xoff         <= 4'b0;
        run_extend       <= 1'b0;
        tile_color_r     <= 8'b0;
        tile_flipx_r     <= 1'b0;
        tile_flipy_r     <= 1'b0;
        tile_code_r      <= 15'b0;
        gfx_right_r      <= 21'b0;
        gfx_left_data_r  <= 32'b0;
        gfx_right_data_r <= 32'b0;
        src_y_raw_r      <= 9'b0;
        src_y_r          <= 9'b0;
        x_step_r         <= 32'h00010000;
        x_index_start_r  <= 32'b0;
        y_index_r        <= 32'b0;
        sx_base_r        <= 32'b0;
        colscroll_r      <= 16'b0;
        rowzoom_r        <= 16'b0;
        rs_hi_r          <= 16'b0;
    end else begin

        // ── VBLANK: reset Y accumulator and snapshot sx_base ─────────────
        if (vblank_rise && !nozoom_c) begin
            // MAME bg01_draw (non-flip):
            //   y_index = (bgscrolly << 16) + (bg_dy << 8)
            //   (y_offset - min_y = 0 → no extra term)
            y_index_r <= {bgscrolly, 16'd0} + {16'd0, bg_dy, 8'd0};
            sx_base_r <= sx_zoom_c;
        end

        case (state)

            // ── BG_IDLE: wait for hblank_rise ────────────────────────────
            BG_IDLE: begin
                if (hblank_rise) begin
                    // Latch raw source Y for this scanline
                    if (nozoom_c)
                        src_y_raw_r <= canvas_y_c;
                    else
                        src_y_raw_r <= y_index_r[24:16];
                    state <= BG_S0;
                end
            end

            // ── BG_S0: scram read issued combinationally; advance state ──
            BG_S0: begin
                state <= BG_S1;
            end

            // ── BG_S1: latch S0 result; issue next read ───────────────────
            BG_S1: begin
                if (LAYER >= 2) begin
                    // Latch colscroll result
                    colscroll_r <= scram_q;
                    // Compute colscroll-adjusted src_y
                    src_y_r <= (src_y_raw_r + scram_q[8:0]) & 9'h1FF;
                    // scram_addr already drives rz or rs_hi (combinational from scram_q)
                end else begin
                    // Latch rs_hi
                    rs_hi_r <= scram_q;
                end
                state <= BG_S2;
            end

            // ── BG_S2: latch S1 result; issue/compute next ────────────────
            BG_S2: begin
                if (LAYER >= 2) begin
                    // Latch rowzoom (or rs_hi if !rowzoom_en)
                    if (rowzoom_en)
                        rowzoom_r <= scram_q;
                    else
                        rs_hi_r   <= scram_q;
                    // Compute x_step using rowzoom_lo
                    begin
                        logic [7:0]  rz_lo;
                        logic [31:0] rz_sub;
                        rz_lo  = rowzoom_en ? scram_q[7:0] : 8'h00;
                        rz_sub = {16'd0, rz_lo, 8'd0};      // rz_lo << 8
                        x_step_r <= zoomx_c - rz_sub;
                    end
                    // scram_addr drives next read (rs_hi or rs_lo) combinationally
                    state <= BG_S3;
                end else begin
                    // BG0/1: scram_q holds rs_lo; compute x_index_start
                    // Store in x_index_start_r for reference; x_step_r for zoom path.
                    begin
                        logic [31:0] rs_hi32;
                        logic [31:0] rs_lo32;
                        rs_hi32 = {rs_hi_r, 16'd0};
                        rs_lo32 = {16'd0, scram_q[7:0], 8'd0};  // rs_lo << 8
                        if (nozoom_c) begin
                            x_index_start_r <= {bgscrollx, 16'd0} - rs_hi32 - rs_lo32;
                            x_step_r        <= 32'h00010000;
                        end else begin
                            x_index_start_r <= sx_base_r;
                            x_step_r        <= zoomx_c;
                        end
                    end
                    state <= BG_S3;
                end
            end

            // ── BG_S3: BG0/1 start fill; BG2/3 latch rs_hi or rs_lo ──────
            BG_S3: begin
                if (LAYER >= 2) begin
                    if (rowzoom_en) begin
                        // Latch rs_hi (result of rs_hi read issued in S2)
                        rs_hi_r <= scram_q;
                        state   <= BG_S4;
                    end else begin
                        // scram_q holds rs_lo (from S2 read). Compute x_index_start and
                        // start fill in the SAME cycle using local temp to avoid stale read.
                        begin
                            logic [31:0] rs_hi32;
                            logic [31:0] rs_lo32;
                            logic [31:0] xis;
                            rs_hi32 = {rs_hi_r, 16'd0};
                            rs_lo32 = {16'd0, scram_q[7:0], 8'd0};
                            // rz_origin = 0 (rowzoom_en=0)
                            xis = nozoom_c ? ({bgscrollx, 16'd0} - rs_hi32 - rs_lo32) : sx_base_r;
                            x_index_start_r <= xis;
                            x_step_r        <= nozoom_c ? 32'h00010000 : zoomx_c;
                            // Start fill from xis directly (not from stale x_index_start_r)
                            run_xoff   <= xis[19:16];
                            run_extend <= dblwidth;
                            if (dblwidth)
                                map_tx <= {1'b0, xis[24:20]} & 6'h3F;
                            else
                                map_tx <= {1'b0, xis[24:20]} & 6'h1F;
                            // BG2/3: src_y_r is colscroll-adjusted source Y (latched in S1)
                            map_ty <= src_y_r[8:4];
                            run_py <= src_y_r[3:0];
                        end
                        tile_col <= 5'b0;
                        state    <= BG_PRE_CODE;
                    end
                end else begin
                    // BG0/1: x_index_start_r was written in S2; reads here are correct.
                    run_xoff   <= x_index_start_r[19:16];
                    run_extend <= dblwidth;
                    if (dblwidth)
                        map_tx <= {1'b0, x_index_start_r[24:20]} & 6'h3F;
                    else
                        map_tx <= {1'b0, x_index_start_r[24:20]} & 6'h1F;
                    // src_y_raw_r latched in IDLE: canvas_y_c (no-zoom) or y_index_r[24:16] (zoom)
                    map_ty   <= src_y_raw_r[8:4];
                    run_py   <= src_y_raw_r[3:0];
                    tile_col <= 5'b0;
                    state    <= BG_PRE_CODE;
                end
            end

            // ── BG_S4: BG2/3 with rowzoom: latch rs_lo; compute; start ───
            // scram_q holds rs_lo (from S3 read). rowzoom_r was latched in S2.
            // Compute x_index_start and start fill using local temp (no stale read).
            BG_S4: begin
                if (LAYER >= 2) begin
                    begin
                        logic [31:0] rs_hi32;
                        logic [31:0] rs_lo32;
                        logic [31:0] rz_origin;
                        logic [7:0]  rz_lo;
                        logic signed [31:0] factor;
                        logic [31:0] xis;
                        rs_hi32    = {rs_hi_r, 16'd0};
                        rs_lo32    = {16'd0, scram_q[7:0], 8'd0};
                        rz_lo      = rowzoom_en ? rowzoom_r[7:0] : 8'h00;
                        // x_origin adjustment: x_index -= (LAYER*4 - 0x1f) * (rz_lo << 8)
                        // factor = LAYER*4 - 0x1f  (signed)
                        factor     = $signed(32'(LAYER) * 32'sd4 - 32'sd31);
                        rz_origin  = 32'($signed(factor * $signed({24'd0, rz_lo, 8'd0})));
                        xis        = nozoom_c ? ({bgscrollx, 16'd0} - rs_hi32 - rs_lo32 - rz_origin)
                                              : (sx_base_r - rz_origin);
                        x_index_start_r <= xis;
                        x_step_r        <= nozoom_c ? 32'h00010000 : zoomx_c;
                        // Start fill directly from xis (no stale read of x_index_start_r)
                        run_xoff   <= xis[19:16];
                        run_extend <= dblwidth;
                        if (dblwidth)
                            map_tx <= {1'b0, xis[24:20]} & 6'h3F;
                        else
                            map_tx <= {1'b0, xis[24:20]} & 6'h1F;
                        // BG2/3: src_y_r is colscroll-adjusted source Y (latched in S1)
                        map_ty <= src_y_r[8:4];
                        run_py <= src_y_r[3:0];
                    end
                    tile_col <= 5'b0;
                    state    <= BG_PRE_CODE;
                end
            end

            // ── BG_PRE_CODE: issue first-tile attr read ───────────────────
            // map_tx/map_ty/run_extend were set in BG_S3/BG_S4 (previous cycle).
            // BG_PRE_CODE drives vram_addr=vram_attr_cur_c (the correct first tile attr).
            // BG_CODE will latch vram_q = VRAM[vram_attr_cur_c].
            BG_PRE_CODE: begin
                state <= BG_CODE;
            end

            // ── BG_CODE: latch attr; drive code read ─────────────────────
            BG_CODE: begin
                tile_color_r <= vram_q[7:0];
                tile_flipx_r <= vram_q[14];
                tile_flipy_r <= vram_q[15];
                state        <= BG_GFX0;
            end

            // ── BG_GFX0: latch code; drive left GFX; latch left ──────────
            BG_GFX0: begin
                tile_code_r <= vram_q[14:0];
                begin
                    logic [3:0]  ry;
                    logic [20:0] base21;
                    ry     = tile_flipy_r ? (4'd15 - run_py) : run_py;
                    base21 = {1'b0, vram_q[14:0], 5'b0};
                    gfx_right_r <= base21 + {16'b0, ry, 1'b0} + 21'd1;
                end
                gfx_left_data_r <= gfx_data;
                state           <= BG_GFX1;
            end

            // ── BG_GFX1: latch right GFX data ────────────────────────────
            BG_GFX1: begin
                gfx_right_data_r <= gfx_data;
                state             <= BG_WRITE;
            end

            // ── BG_WRITE: decode 16 pixels; write linebuf; advance ────────
            BG_WRITE: begin
                begin
                    logic signed [10:0] scol_base;
                    scol_base = $signed({1'b0, tile_col, 4'b0}) -
                                $signed({7'b0, run_xoff});
/* verilator lint_off UNUSED */
                    for (int px = 0; px < 16; px++) begin
                        automatic logic signed [10:0] scol;
                        automatic logic [ 3:0] px_tile;
                        automatic logic [ 2:0] ni;
                        automatic logic [31:0] src;
                        automatic logic [ 4:0] sh;
                        automatic logic [ 3:0] pen;

                        scol    = scol_base + $signed(11'(px));
                        px_tile = 4'(px);

                        // flipX: swap left/right halves AND reverse nibble order
                        if (tile_flipx_r)
                            src = px_tile[3] ? gfx_left_data_r : gfx_right_data_r;
                        else
                            src = px_tile[3] ? gfx_right_data_r : gfx_left_data_r;
                        ni  = tile_flipx_r ? 3'(7 - px_tile[2:0]) : 3'(px_tile[2:0]);
                        sh  = 5'd28 - 5'({2'b0, ni} << 2);
                        pen = 4'(src >> sh);

                        if (scol >= 0 && scol < 320) begin
                            linebuf[scol[8:0]] <= {tile_color_r, pen};
                        end
                    end
/* verilator lint_on UNUSED */
                end

                if (tile_col == 5'd20) begin
                    // Scanline fill complete: advance Y accumulator (zoom path).
                    // Only advance when this hblank fills an active-display scanline
                    // (vpos 15..254 = the hblank before screen_y 0..239).
                    // Blocks advances during vblank scanlines (vpos 255, 0..14, 256+).
                    if (!nozoom_c && vpos >= 9'd15 && vpos < 9'd255)
                        y_index_r <= y_index_r + zoomy_c;
                    state <= BG_IDLE;
                end else begin
                    tile_col <= tile_col + 5'd1;
                    map_tx   <= next_map_tx;
                    state    <= BG_CODE;
                end
            end

            default: state <= BG_IDLE;
        endcase
    end
end

// =============================================================================
// Suppress unused warnings
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused_bg;
assign _unused_bg = ^{hblank_r2, bgscrolly[15:9], bgscrollx[15:9],
                      vram_attr_init_c, bgscrollx[3:0],
                      flipscreen, colscroll_r,
                      rowzoom_r[15:8], scram_q[15:9],
                      x_step_r, x_index_start_r[31:25], x_index_start_r[15:0]};
/* verilator lint_on UNUSED */

endmodule
