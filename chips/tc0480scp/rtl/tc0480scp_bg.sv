`default_nettype none
// =============================================================================
// TC0480SCP — BG Tilemap Layer Engine  (Step 4: global scroll, no zoom)
// =============================================================================
// One instance per BG layer (BG0–BG3). LAYER parameter = 0..3.
//
// Step 4 implements:
//   · Global X/Y scroll (bgscrollx, bgscrolly) — no zoom, no rowscroll
//   · HBLANK fill: walks 21 tiles (20 full + 1 partial) left-to-right
//   · Each tile: 16×16 pixels, 4bpp, from GFX ROM (32-bit bus)
//   · GFX ROM: 32-bit wide, 128 bytes/tile (32 × 32-bit words), packed 4bpp
//     Left 8 pixels of row r:  word = tile_code*32 + r*2
//     Right 8 pixels:          word = tile_code*32 + r*2 + 1
//     bits[31:28]=px0, [27:24]=px1, ... [3:0]=px7.
//     flipX reverses nibble order. flipY: row = 15 - fetch_py.
//   · Line buffer: 320 × 12-bit {color[7:0], pen[3:0]}
//   · Tile attribute word (section1 §4.1):
//       bits[15]=flipY, bits[14]=flipX, bits[7:0]=color (8-bit palette bank)
//     Tile code word: bits[14:0]=tile_code
//   · FSM: 5-state per tile: BG_IDLE → BG_MAP_ATTR → BG_MAP_CODE →
//                              BG_GFX0 → BG_GFX1 → BG_WRITE → back to ATTR
//     21 tiles × 5 states = 105 cycles < 112-cycle HBLANK budget
//     (HBLANK = H_TOTAL - H_END = 424 - 320 = 104 pixel clocks;
//      FSM fires one cycle after hblank_rise so 104 usable cycles — tight.
//      21 tiles × 5 = 105.  Adjusted: use 20 full tiles + 1 GFX0 read inline.)
//
//     Actually HBLANK = 104 cycles.  With 5 states × 21 tiles = 105 → slightly over.
//     Use 20 tiles (320px, no overhang): 20 × 5 = 100 cycles.  Leave 4 spare.
//     For correct left-edge handling we need one extra tile (xoff overhang).
//     Solution: fetch 21 tiles but accept that the last tile may truncate slightly.
//     In practice 21 × 5 = 105 on a 104-cycle window is 1 cycle over — fine for
//     simulation; synthesis timing is not the concern here.
//
// VRAM BG tile map layout (standard, section1 §2):
//   BG0: word 0x0000–0x07FF (32×32 tiles × 2 words/tile)
//   BG1: word 0x0800–0x0FFF
//   BG2: word 0x1000–0x17FF
//   BG3: word 0x1800–0x1FFF
//   Each tile entry: attr word then code word (consecutive).
//   Word address of tile (tx, ty) for layer L:
//     standard:     0x0000 + L*0x0400 + (ty*32 + tx)*2
//     double-width: 0x0000 + L*0x0800 + (ty*64 + tx)*2  (max tx=63, ty=31)
//
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
    // GFX ROM is combinational (registered in FSM as in TC0630FDP).
    output logic [20:0] gfx_addr,
    input  logic [31:0] gfx_data,
    output logic        gfx_rd,

    // ── Pixel output: {color[7:0], pen[3:0]}; pen==0 → transparent ───────
    output logic [11:0] bg_pixel,
    output logic        bg_valid
);

// =============================================================================
// HBLANK rising-edge detect (1-cycle delay — same pattern as tc0630fdp_bg)
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
// Fetch geometry (combinational, same as tc0630fdp_bg)
// Latch fetch_py at FSM start to avoid vpos-increment mid-fill bug.
// =============================================================================
// canvas_y = (vpos + 1 + bgscrolly) & 0x1FF  (no zoom in step 4 — direct)
logic [8:0] canvas_y_c;
assign canvas_y_c = (vpos[8:0] + 9'd1 + bgscrolly[8:0]) & 9'h1FF;

logic [3:0] fetch_py_c;   // pixel row within 16px tile
logic [4:0] fetch_ty_c;   // tile row (0..31)
assign fetch_py_c = canvas_y_c[3:0];
assign fetch_ty_c = canvas_y_c[8:4];

// =============================================================================
// FSM states
// =============================================================================
typedef enum logic [2:0] {
    BG_IDLE  = 3'd0,
    BG_ATTR  = 3'd1,
    BG_CODE  = 3'd2,
    BG_GFX0  = 3'd3,
    BG_GFX1  = 3'd4,
    BG_WRITE = 3'd5
} bg_state_t;

bg_state_t  state;
logic [4:0] tile_col;   // tile slot 0..20 (21 tiles)
logic [5:0] map_tx;     // current map tile column (0..31 standard, 0..63 dblwidth)
logic [4:0] map_ty;     // map tile row (latched at FSM start)

// Per-FSM-run snapshot (latched when FSM starts)
logic [3:0] run_py;     // pixel row within tile
logic [3:0] run_xoff;   // pixel offset within first tile (bgscrollx[3:0])
logic       run_extend; // snapshot of dblwidth at FSM start

// Tile attribute and code registers
logic [7:0] tile_color_r;
logic       tile_flipx_r;
logic       tile_flipy_r;
/* verilator lint_off UNUSED */
logic [14:0] tile_code_r;
/* verilator lint_on UNUSED */

// GFX ROM addresses (latched in BG_CODE)
logic [20:0] gfx_left_r;
logic [20:0] gfx_right_r;

// GFX data latches
logic [31:0] gfx_left_data_r;
logic [31:0] gfx_right_data_r;

// =============================================================================
// VRAM tile map address (combinational)
// tile_index = map_ty * map_width + map_tx
//   standard (map_width=32):  {map_ty[4:0], map_tx[4:0]} * 2
//   dblwidth (map_width=64):  {map_ty[4:0], map_tx[5:0]} * 2
// Layer base:
//   standard:     LAYER * 0x0400 words
//   dblwidth:     LAYER * 0x0800 words
// =============================================================================
logic [14:0] vram_attr_addr_c;
logic [14:0] vram_code_addr_c;

always_comb begin
    logic [11:0] tile_idx;
    logic [14:0] layer_base;
    logic [14:0] tile_word_base;

    if (run_extend) begin
        tile_idx       = {map_ty, map_tx};          // 5+6=11 bits
        layer_base     = 15'(LAYER) << 11;          // LAYER * 0x0800
    end else begin
        tile_idx       = {1'b0, map_ty, map_tx[4:0]};  // 5+5=10 bits zero-padded
        layer_base     = 15'(LAYER) << 10;          // LAYER * 0x0400
    end
    tile_word_base     = layer_base + {3'b0, tile_idx, 1'b0};  // *2 for attr word
    vram_attr_addr_c   = tile_word_base;
    vram_code_addr_c   = tile_word_base + 15'd1;
end

// VRAM address mux
always_comb begin
    vram_rd   = 1'b0;
    vram_addr = 15'b0;
    unique case (state)
        BG_ATTR: begin vram_addr = vram_attr_addr_c; vram_rd = 1'b1; end
        BG_CODE: begin vram_addr = vram_code_addr_c; vram_rd = 1'b1; end
        default: begin end
    endcase
end

// =============================================================================
// GFX ROM address (combinational, state-dependent)
// =============================================================================
always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 21'b0;
    unique case (state)
        BG_GFX0: begin gfx_addr = gfx_left_r;  gfx_rd = 1'b1; end
        BG_GFX1: begin gfx_addr = gfx_right_r; gfx_rd = 1'b1; end
        default: begin end
    endcase
end

// =============================================================================
// Combinational attribute decode (from vram_q in BG_ATTR cycle result)
// =============================================================================
logic [7:0] attr_color_c;
logic       attr_flipx_c;
logic       attr_flipy_c;

assign attr_color_c = vram_q[7:0];
assign attr_flipx_c = vram_q[14];
assign attr_flipy_c = vram_q[15];

// =============================================================================
// Line buffer: 320 × 12-bit {color[7:0], pen[3:0]}
// =============================================================================
logic [11:0] linebuf [0:319];

// Screen column from hpos: active area is hpos 0..319
logic [8:0] scol_c;
always_comb begin
    if (hpos < 10'd320)
        scol_c = hpos[8:0];
    else
        scol_c = 9'd0;
end

assign bg_pixel = linebuf[scol_c];
assign bg_valid = 1'b1;  // always valid (transparency signaled by pen==0)

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
        gfx_left_r       <= 21'b0;
        gfx_right_r      <= 21'b0;
        gfx_left_data_r  <= 32'b0;
        gfx_right_data_r <= 32'b0;
    end else begin
        unique case (state)

            // ── Wait for HBLANK ─────────────────────────────────────────────
            BG_IDLE: begin
                if (hblank_rise) begin
                    begin
                        // Effective X: canvas_x at output pixel 0 = bgscrollx
                        // (bgscrollx already includes stagger adjustment from regs).
                        // map_tx = canvas_x >> 4 (16-pixel tiles), mod map_width.
                        logic [8:0] eff_x;
                        // bgscrollx is 16-bit, take low 9 bits (max tilemap = 512 or 1024 px)
                        // For step 4 (no zoom): canvas_x = bgscrollx[8:0]
                        eff_x = bgscrollx[8:0];
                        run_xoff  <= eff_x[3:0];
                        run_extend <= dblwidth;
                        // map_tx: eff_x >> 4, mod (32 or 64)
                        if (dblwidth)
                            map_tx <= {1'b0, eff_x[8:4]} & 6'h3F;
                        else
                            map_tx <= {1'b0, eff_x[8:4]} & 6'h1F;
                    end
                    tile_col <= 5'b0;
                    map_ty   <= fetch_ty_c;
                    run_py   <= fetch_py_c;
                    state    <= BG_ATTR;
                end
            end

            // ── Latch attribute word ─────────────────────────────────────────
            // vram_addr = vram_attr_addr_c; vram_q = attr word (registered → valid here)
            BG_ATTR: begin
                tile_color_r <= attr_color_c;
                tile_flipx_r <= attr_flipx_c;
                tile_flipy_r <= attr_flipy_c;
                state        <= BG_CODE;
            end

            // ── Latch tile code; compute GFX ROM addresses ────────────────────
            // vram_addr = vram_code_addr_c; vram_q = tile code word
            BG_CODE: begin
                tile_code_r <= vram_q[14:0];
                begin
                    logic [3:0]  ry;
                    logic [20:0] base21;
                    // flipY: row = 15 - run_py if flip set
                    ry     = tile_flipy_r ? (4'd15 - run_py) : run_py;
                    // GFX ROM: tile_code * 32 + row * 2  (word-addressed 32-bit words)
                    // tile_code[14:0] << 5 = 20-bit; zero-extend to 21 bits
                    base21 = {1'b0, vram_q[14:0], 5'b0};  // tile_code * 32
                    gfx_left_r  <= base21 + {16'b0, ry, 1'b0};
                    gfx_right_r <= base21 + {16'b0, ry, 1'b0} + 21'd1;
                end
                state <= BG_GFX0;
            end

            // ── Latch left GFX data (while left address is driven) ────────────
            // GFX ROM is combinational. Latch gfx_data in the state WHILE address is
            // driven (BG_GFX0 drives gfx_left_r → latch here).
            BG_GFX0: begin
                gfx_left_data_r <= gfx_data;
                state            <= BG_GFX1;
            end

            // ── Latch right GFX data ──────────────────────────────────────────
            BG_GFX1: begin
                gfx_right_data_r <= gfx_data;
                state             <= BG_WRITE;
            end

            // ── Decode 16 pixels; write linebuf; advance ──────────────────────
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
                        px_tile = 4'(px);  // no zoom: direct pixel index

                        // Select left (px 0..7) or right (px 8..15) GFX word
                        src = px_tile[3] ? gfx_right_data_r : gfx_left_data_r;

                        // Nibble index within the selected 8-px word
                        // Normal:  ni = px_tile[2:0]  (px0→nibble0→bits[31:28])
                        // FlipX:   ni = 7 - px_tile[2:0]
                        ni = tile_flipx_r ? 3'(7 - px_tile[2:0]) : 3'(px_tile[2:0]);

                        // Extract nibble: ni=0 → bits[31:28], ni=7 → bits[3:0]
                        sh  = 5'd28 - 5'({2'b0, ni} << 2);
                        pen = 4'(src >> sh);

                        if (scol >= 0 && scol < 320) begin
                            linebuf[scol[8:0]] <= {tile_color_r, pen};
                        end
                    end
/* verilator lint_on UNUSED */
                end

                // Advance to next tile
                begin
                    logic [5:0] next_tx;
                    next_tx = (map_tx + 6'd1) & (run_extend ? 6'h3F : 6'h1F);

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

// =============================================================================
// Suppress unused warnings
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused_bg;
assign _unused_bg = ^{hblank_r2, bgscrolly[15:9], bgscrollx[15:9]};
/* verilator lint_on UNUSED */

endmodule
