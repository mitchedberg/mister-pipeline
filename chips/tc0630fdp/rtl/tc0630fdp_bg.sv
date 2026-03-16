`default_nettype none
// =============================================================================
// TC0630FDP — BG Tilemap Layer Engine  (Step 5: global scroll + rowscroll)
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
logic [3:0] fetch_py;           // pixel row within 16px tile: canvas_y[3:0]
logic [4:0] fetch_ty;           // tile row (0..31):            canvas_y[8:4]
logic [5:0] fetch_first_tx;     // first visible map tile column
logic [3:0] fetch_xoff;         // pixel offset within first tile (0..15)
logic       fetch_extend;       // extend_mode passthrough

// Suppress unused sub-field warnings for scroll registers
/* verilator lint_off UNUSED */
logic _unused_scroll;
assign _unused_scroll = ^{pf_xscroll[5:0], pf_yscroll[6:0], ls_rowscroll[5:0]};
/* verilator lint_on UNUSED */

always_comb begin
    logic [8:0] canvas_y;
    logic [9:0] cx0;
    // Y: canvas_y = (vpos + 1 + yscroll_int) & 0x1FF
    // vpos+1 is 9-bit (max 262, wraps fine)
    canvas_y        = (vpos[8:0] + 9'd1) + pf_yscroll[15:7];
    fetch_py        = canvas_y[3:0];
    fetch_ty        = canvas_y[8:4];
    // X: effective_x = pf_xscroll[15:6] + ls_rowscroll[15:6]
    //    Both values are 10.6 fixed-point; integer part = [15:6] (10-bit).
    //    Adding the integer parts gives the effective canvas X at screen col 0.
    cx0             = pf_xscroll[15:6] + ls_rowscroll[15:6];
    fetch_first_tx  = cx0[9:4] & 6'h3F;   // tile col (mod 64)
    fetch_xoff      = cx0[3:0];            // pixel offset within tile
    fetch_extend    = extend_mode;
end

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
logic [4:0] tile_col;    // tile slot 0..20 (21 tiles = 336px, covers 320 + 15px overhang)
logic [5:0] map_tx;      // current map tile column
logic [4:0] map_ty;      // current map tile row (= fetch_ty, fixed per scanline)

// Per-FSM-run snapshot of fetch geometry — latched when FSM starts (BG_IDLE→BG_ATTR)
// fetch_py and fetch_xoff are needed throughout the tile fetch loop; latch them once
// so they don't change mid-fetch if vpos wraps.
logic [3:0] run_py;       // snapshot of fetch_py at FSM start
logic [3:0] run_xoff;     // snapshot of fetch_xoff at FSM start
logic       run_extend;   // snapshot of fetch_extend at FSM start
logic       run_alt;      // snapshot of ls_alt_tilemap at FSM start

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

always_comb begin
    unique case (state)
        BG_ATTR:  pf_rd_addr = pf_attr_addr_c;
        BG_CODE:  pf_rd_addr = pf_code_addr_c;
        default:  pf_rd_addr = 13'b0;
    endcase
end

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
    unique case (state)
        BG_GFX0: begin gfx_addr = gfx_left_r;  gfx_rd = 1'b1; end
        BG_GFX1: begin gfx_addr = gfx_right_r; gfx_rd = 1'b1; end
        default: begin gfx_addr = 22'b0;        gfx_rd = 1'b0; end
    endcase
end

// =============================================================================
// Line buffer: 320 × 13-bit
// =============================================================================
logic [12:0] linebuf [0:319];

// Screen column from hpos
logic [8:0] scol_c;
always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_START + 320))
        scol_c = hpos[8:0] - 9'(H_START);
    else
        scol_c = 9'd0;
end

assign bg_pixel = linebuf[scol_c];

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
        run_alt          <= 1'b0;
        tile_palette_r   <= 9'b0;
        tile_blend_r     <= 1'b0;
        tile_xplanes_r   <= 2'b0;
        tile_flipx_r     <= 1'b0;
        tile_flipy_r     <= 1'b0;
        tile_code_r      <= 16'b0;
        gfx_left_r       <= 22'b0;
        gfx_right_r      <= 22'b0;
        gfx_left_data_r  <= 32'b0;
        gfx_right_data_r <= 32'b0;
    end else begin
        unique case (state)

            // ─── Wait for HBLANK ────────────────────────────────────────────
            // Geometry is combinational — fetch_ty/fetch_first_tx are valid NOW.
            BG_IDLE: begin
                if (hblank_rise) begin
                    tile_col   <= 5'b0;
                    map_ty     <= fetch_ty;
                    map_tx     <= fetch_first_tx;
                    run_py     <= fetch_py;
                    run_xoff   <= fetch_xoff;
                    run_extend <= fetch_extend;
                    run_alt    <= ls_alt_tilemap;
                    state      <= BG_ATTR;
                end
            end

            // ─── Latch attribute word ────────────────────────────────────────
            // pf_rd_addr = pf_attr_addr_c (combinational → pf_q = attr word).
            BG_ATTR: begin
                tile_palette_r  <= attr_palette_c;
                tile_blend_r    <= attr_blend_c;
                tile_xplanes_r  <= attr_xplanes_c;
                tile_flipx_r    <= attr_flipx_c;
                tile_flipy_r    <= attr_flipy_c;
                state           <= BG_CODE;
            end

            // ─── Latch tile code; compute GFX ROM addresses ──────────────────
            // pf_rd_addr = pf_code_addr_c → pf_q = tile code word.
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
            BG_WRITE: begin
                begin
                    // scol_base = tile_col * 16 - run_xoff  (signed 11-bit)
                    logic signed [10:0] scol_base;
                    scol_base = $signed({1'b0, tile_col, 4'b0}) -
                                $signed({7'b0, run_xoff});

                    for (int px = 0; px < 16; px++) begin
                        automatic logic signed [10:0] scol;
                        automatic logic [2:0]  ni;         // nibble index 0..7
                        automatic logic [3:0]  pen;
                        automatic logic [31:0] src;
                        automatic logic [4:0]  sh;

                        scol = scol_base + $signed(11'(px));

                        // Nibble index within 8-px fetch word
                        // Normal:  ni = px & 7  (px0→ni=0→bits[31:28])
                        // FlipX:   ni = 7 - (px & 7)
                        ni = tile_flipx_r ? 3'(7 - (px & 7)) : 3'(px & 7);

                        // Select left or right 32-bit word
                        src = (px < 8) ? gfx_left_data_r : gfx_right_data_r;

                        // Extract nibble: nibble at ni → bits[(7-ni)*4+3:(7-ni)*4]
                        // shift = (7 - ni) * 4 = 28 - ni*4
                        // Use 5-bit arithmetic: all values 0..28 fit in 5 bits
                        sh  = 5'({2'b00, ni} << 2);         // ni * 4, 5-bit
                        sh  = 5'd28 - sh;                    // 28 - ni*4, fits 5-bit
                        pen = 4'(src >> sh);

                        if (scol >= 0 && scol < 320) begin
                            linebuf[scol[8:0]] <= {tile_palette_r, pen};
                        end
                    end
                end

                begin
                    // Advance map_tx (wrap mod 32 or 64)
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

endmodule
