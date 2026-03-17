`default_nettype none
// =============================================================================
// TC0480SCP — BG Tilemap Layer Engine  (Step 4: global scroll, no zoom)
// =============================================================================
// One instance per BG layer (BG0–BG3). LAYER parameter = 0..3.
//
// FSM pipeline: 4 states/tile, pipelined VRAM reads.
//   BG_IDLE:  Wait for hblank_rise. Combinationally drive first tile's attr addr.
//             Latch fetch geometry. State → BG_CODE.
//   BG_CODE:  vram_q = attr word. Latch attr. Drive code read. State → BG_GFX0.
//   BG_GFX0:  vram_q = code word. Latch code. Compute GFX addrs combinationally.
//             Drive left GFX addr. Latch left GFX data. State → BG_GFX1.
//   BG_GFX1:  Drive right GFX addr. Latch right GFX data. State → BG_WRITE.
//   BG_WRITE: Decode 16 pixels. Write linebuf. Drive next tile's attr addr (pipeline).
//             Advance tile_col/map_tx. State → BG_CODE (or BG_IDLE if done).
//
// Budget: 1 (first IDLE→CODE) + 4×21 tiles = 85 cycles < 104 HBLANK cycles.
//
// VRAM BG tile map layout (standard, section1 §2):
//   BG0: word 0x0000–0x07FF (32×32 tiles × 2 words/tile)
//   BG1: word 0x0800–0x0FFF   Each tile: attr word then code word.
//   BG2: word 0x1000–0x17FF   Word addr (tx,ty,L): L*0x0400 + (ty*32+tx)*2
//   BG3: word 0x1800–0x1FFF   Double-width: L*0x0800 + (ty*64+tx)*2
//
// GFX ROM format (section1 §4.1):
//   32-bit words, word-addressed. Tile t, row r:
//     left  half (px0..7) : word t*32 + r*2
//     right half (px8..15): word t*32 + r*2 + 1
//   bits[31:28]=px0, [27:24]=px1, ..., [3:0]=px7.
//   flipX: reverse nibble order within each 8-px word.
//   flipY: use row (15 - py) instead of py.
//
// Pixel output: {color[7:0], pen[3:0]}; pen==0 → transparent.
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

    // ── Scroll registers ──────────────────────────────────────────────────
    input  logic [15:0] bgscrollx,      // effective X scroll (stagger already applied)
    input  logic [15:0] bgscrolly,      // Y scroll
    input  logic        dblwidth,       // double-width tilemap mode

    // ── VRAM tile map read port (registered 1-cycle latency) ─────────────
    output logic [14:0] vram_addr,
    output logic        vram_rd,
    input  logic [15:0] vram_q,

    // ── GFX ROM async read port (32-bit word-addressed) ───────────────────
    output logic [20:0] gfx_addr,
    input  logic [31:0] gfx_data,
    output logic        gfx_rd,

    // ── Pixel output: {color[7:0], pen[3:0]}; pen==0 → transparent ───────
    output logic [11:0] bg_pixel,
    output logic        bg_valid
);

// =============================================================================
// HBLANK rising-edge detect (1-cycle delay)
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
// Fetch geometry (combinational)
// V_START=16 → subtract 15 so that at vpos=15 (hblank before screen_y=0),
// canvas_y = scroll, tile_row=0, py=0 for the first visible line.
// =============================================================================
logic [8:0] canvas_y_c;
assign canvas_y_c = (vpos[8:0] - 9'd15 + bgscrolly[8:0]) & 9'h1FF;

logic [3:0] fetch_py_c;
logic [4:0] fetch_ty_c;
assign fetch_py_c = canvas_y_c[3:0];
assign fetch_ty_c = canvas_y_c[8:4];

// =============================================================================
// FSM states
// =============================================================================
typedef enum logic [2:0] {
    BG_IDLE  = 3'd0,
    BG_CODE  = 3'd1,   // latch attr result; drive code read
    BG_GFX0  = 3'd2,   // latch code result; compute+drive left GFX; latch left
    BG_GFX1  = 3'd3,   // drive right GFX; latch right
    BG_WRITE = 3'd4    // decode+write; drive next-tile attr; advance
} bg_state_t;

bg_state_t  state;
logic [4:0] tile_col;    // tile slot 0..20 (21 tiles)
logic [5:0] map_tx;      // CURRENT tile column (registered)
logic [4:0] map_ty;      // tile row (latched at FSM start)
logic [5:0] next_map_tx; // NEXT tile column (combinational, used in BG_WRITE)

logic [3:0] run_py;
logic [3:0] run_xoff;
logic       run_extend;

logic [7:0] tile_color_r;
logic       tile_flipx_r;
logic       tile_flipy_r;
/* verilator lint_off UNUSED */
logic [14:0] tile_code_r;
/* verilator lint_on UNUSED */

logic [31:0] gfx_left_data_r;
logic [31:0] gfx_right_data_r;

// =============================================================================
// Next tile column (combinational, wraps modulo map_width)
// =============================================================================
always_comb begin
    next_map_tx = (map_tx + 6'd1) & (run_extend ? 6'h3F : 6'h1F);
end

// =============================================================================
// VRAM tile word address helper (combinational)
// Computes attr word address for (ty, tx) in this layer.
// =============================================================================
function automatic logic [14:0] tile_attr_addr(
    input logic [4:0] ty,
    input logic [5:0] tx,
    input logic       dw
);
    logic [11:0] idx;
    logic [14:0] base;
    if (dw) begin
        idx  = {1'b0, ty, tx};       // 12 bits
        base = 15'(LAYER) << 11;
    end else begin
        idx  = {2'b0, ty, tx[4:0]};  // 12 bits
        base = 15'(LAYER) << 10;
    end
    return base + {2'b0, idx, 1'b0};
endfunction

// =============================================================================
// VRAM address mux (combinational)
// BG_IDLE: pre-issue first tile's attr read (combinational fetch geometry)
// BG_CODE: issue code read for CURRENT tile
// BG_WRITE: issue next tile's attr read (pipeline)
// =============================================================================
logic [14:0] vram_attr_cur_c;   // attr addr for current tile (map_tx/map_ty)
logic [14:0] vram_code_cur_c;   // code addr for current tile
logic [14:0] vram_attr_next_c;  // attr addr for next tile (next_map_tx/map_ty)
logic [14:0] vram_attr_init_c;  // attr addr for first tile (fetch geometry, used in BG_IDLE)

always_comb begin
    vram_attr_cur_c  = tile_attr_addr(map_ty, map_tx, run_extend);
    vram_code_cur_c  = vram_attr_cur_c + 15'd1;
    vram_attr_next_c = tile_attr_addr(map_ty, next_map_tx, run_extend);
    // First tile: use combinational fetch geometry (before registered map_ty/map_tx)
    begin
        logic [5:0] init_tx_c;
        // Use bgscrollx[8:4] for tile column; [3:0] is sub-tile offset (run_xoff, latched separately)
        if (dblwidth)
            init_tx_c = {1'b0, bgscrollx[8:4]} & 6'h3F;
        else
            init_tx_c = {1'b0, bgscrollx[8:4]} & 6'h1F;
        vram_attr_init_c = tile_attr_addr(fetch_ty_c, init_tx_c, dblwidth);
    end
end

always_comb begin
    vram_rd   = 1'b0;
    vram_addr = 15'b0;
    unique case (state)
        BG_IDLE:  if (hblank_rise) begin
                      vram_addr = vram_attr_init_c;  // first tile attr
                      vram_rd   = 1'b1;
                  end
        BG_CODE:  begin vram_addr = vram_code_cur_c;  vram_rd = 1'b1; end  // code for cur tile
        BG_WRITE: begin vram_addr = vram_attr_next_c; vram_rd = 1'b1; end  // attr for next tile
        default:  begin end
    endcase
end

// =============================================================================
// GFX ROM address (combinational)
// In BG_GFX0: compute addr from vram_q (code word, available this cycle).
//             Use direct combinational formula — do NOT use gfx_left_r (not yet latched).
// In BG_GFX1: use gfx_right_r (latched in BG_GFX0 → valid this cycle).
// =============================================================================
logic [20:0] gfx_right_r;   // right-half GFX addr (latched in BG_GFX0)

// Combinational GFX addr for BG_GFX0 (left half, from current vram_q = code word)
logic [20:0] gfx_left_addr_c;
always_comb begin
    logic [3:0]  ry_c;
    logic [20:0] base21_c;
    ry_c     = tile_flipy_r ? (4'd15 - run_py) : run_py;
    base21_c = {1'b0, vram_q[14:0], 5'b0};  // tile_code * 32
    gfx_left_addr_c = base21_c + {16'b0, ry_c, 1'b0};
end

always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 21'b0;
    unique case (state)
        BG_GFX0: begin gfx_addr = gfx_left_addr_c; gfx_rd = 1'b1; end  // left half
        BG_GFX1: begin gfx_addr = gfx_right_r;     gfx_rd = 1'b1; end  // right half
        default: begin end
    endcase
end

// =============================================================================
// Line buffer: 320 × 12-bit {color[7:0], pen[3:0]}
// =============================================================================
logic [11:0] linebuf [0:319];

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
    end else begin
        unique case (state)

            // ── Wait for HBLANK; drive first tile attr addr combinationally ───
            BG_IDLE: begin
                if (hblank_rise) begin
                    begin
                        logic [8:0] eff_x;
                        eff_x      = bgscrollx[8:0];
                        run_xoff   <= eff_x[3:0];
                        run_extend <= dblwidth;
                        if (dblwidth)
                            map_tx <= {1'b0, eff_x[8:4]} & 6'h3F;
                        else
                            map_tx <= {1'b0, eff_x[8:4]} & 6'h1F;
                    end
                    tile_col <= 5'b0;
                    map_ty   <= fetch_ty_c;
                    run_py   <= fetch_py_c;
                    state    <= BG_CODE;
                end
            end

            // ── Latch attr (from prev cycle's attr read); drive code read ─────
            // vram_q = attr word for current tile.
            BG_CODE: begin
                tile_color_r <= vram_q[7:0];
                tile_flipx_r <= vram_q[14];
                tile_flipy_r <= vram_q[15];
                state        <= BG_GFX0;
            end

            // ── Latch code; compute GFX addrs; drive left GFX; latch left ─────
            // vram_q = code word for current tile.
            // gfx_left_addr_c is combinational from vram_q.
            BG_GFX0: begin
                tile_code_r <= vram_q[14:0];
                // Latch right addr for BG_GFX1 (computed combinationally)
                begin
                    logic [3:0]  ry;
                    logic [20:0] base21;
                    ry     = tile_flipy_r ? (4'd15 - run_py) : run_py;
                    base21 = {1'b0, vram_q[14:0], 5'b0};
                    gfx_right_r <= base21 + {16'b0, ry, 1'b0} + 21'd1;
                end
                // GFX ROM is combinational. gfx_left_addr_c is driven this cycle.
                // Latch left data (gfx_data is valid since gfx_addr=gfx_left_addr_c now).
                gfx_left_data_r <= gfx_data;
                state           <= BG_GFX1;
            end

            // ── Latch right GFX data ──────────────────────────────────────────
            // gfx_right_r was latched in BG_GFX0 → gfx_addr = gfx_right_r this cycle.
            BG_GFX1: begin
                gfx_right_data_r <= gfx_data;
                state             <= BG_WRITE;
            end

            // ── Decode 16 pixels; write linebuf; advance; drive next attr ─────
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

                        // flipX: swap left/right halves AND reverse nibble order within each half
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

                // Advance to next tile.
                // next_map_tx is combinational; vram_attr_next_c is driven by vram addr mux.
                if (tile_col == 5'd20) begin
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
// eff_x_c[3:0] used only for xoff (latched in FSM); suppress lint warning here
assign _unused_bg = ^{hblank_r2, bgscrolly[15:9], bgscrollx[15:9],
                      vram_attr_cur_c, bgscrollx[3:0]};
/* verilator lint_on UNUSED */

endmodule
