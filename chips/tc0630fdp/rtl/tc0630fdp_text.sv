`default_nettype none
// =============================================================================
// TC0630FDP — Text (VRAM) Layer Engine  (Step 2)
// =============================================================================
// Fills a 320-pixel line buffer during HBLANK for the NEXT scanline.
//
// Text layer: 64×64 tile map of 8×8 4bpp CPU-writable characters.
//   · No global scroll — position is fixed relative to screen.
//   · Tile map: Text RAM — 4096 tiles × 1 word each (64 cols × 64 rows).
//   · Pixel data: Character RAM — 256 tiles × 32 bytes = 8KB, 4bpp.
//   · Screen width = 320 pixels → 40 visible tile columns (40 × 8 = 320).
//
// Tile word format (section1 §5):
//   bits[10:0]  = character code (0–2047; lower 8 bits index 256-tile char RAM)
//   bits[15:11] = color / palette (5 bits)
//
// Character RAM GFX decode (charlayout, section1 §11.1):
//   Tile: 8×8 pixels, 4bpp, 32 bytes/tile.
//   Each pixel row = 4 consecutive bytes at row_base = char_code*32 + fetch_py*4.
//   X-offsets {20,16,28,24,4,0,12,8} are bit offsets into the 32-bit row word.
//   All offsets are nibble-aligned → each pixel = one nibble of the row word.
//
//   32-bit row word = [b3 b2 b1 b0] where char_q[7:0]=b0, [15:8]=b1, [23:16]=b2, [31:24]=b3:
//     px0 → x_off=20 → b2[7:4] = char_q[23:20]
//     px1 → x_off=16 → b2[3:0] = char_q[19:16]
//     px2 → x_off=28 → b3[7:4] = char_q[31:28]
//     px3 → x_off=24 → b3[3:0] = char_q[27:24]
//     px4 → x_off= 4 → b0[7:4] = char_q[ 7: 4]
//     px5 → x_off= 0 → b0[3:0] = char_q[ 3: 0]
//     px6 → x_off=12 → b1[7:4] = char_q[15:12]
//     px7 → x_off= 8 → b1[3:0] = char_q[11: 8]
//
// No FlipX / FlipY — text tile word has no flip bits (section1 §5).
//
// FSM: 2 clocks per tile × 40 tiles = 80 cycles < 112-cycle HBLANK budget.
//   TX_IDLE → (hblank_rise) → TX_TRAM → TX_NEXT → TX_TRAM → ... → TX_IDLE
//
//   TX_TRAM (1 clk): present text_rd_addr and char_rd_addr (both async);
//                    latch text_q fields; decode char_q → write 8 pixels.
//   TX_NEXT (1 clk): advance tx_col; loop back to TX_TRAM or go TX_IDLE.
//
// Both RAM ports are modelled as async (combinational read): address is driven
// combinationally, data appears same cycle.
//
// Character RAM port: 32-bit word-addressed.
//   char_rd_addr[10:0] = {char_code[7:0], fetch_py[2:0]} (256×8 = 2048 words)
//   char_q[31:0] = {b3, b2, b1, b0} for the selected row.
//
// Output: text_pixel[8:0] = {color[4:0], pen[3:0]}.  pen==0 → transparent.
// Line buffer is 320 entries indexed by (hpos − H_START).
// =============================================================================

module tc0630fdp_text (
    input  logic        clk,
    input  logic        rst_n,

    // ── Video timing ──────────────────────────────────────────────────────
    input  logic        hblank,         // active-high HBLANK
    input  logic [ 8:0] vpos,           // current line counter (0..261)

    // ── Text RAM async read port ──────────────────────────────────────────
    // 4096 × 16-bit; addr[11:0] = {row[5:0], col[5:0]}
    output logic [11:0] text_rd_addr,
    input  logic [15:0] text_q,

    // ── Character RAM async read port (32-bit, word-addressed) ───────────
    // 2048 words × 32 bits = 8192 bytes (256 tiles × 8 rows × 4 bytes/row).
    // addr[10:0] = {char_code[7:0], fetch_py[2:0]}
    output logic [10:0] char_rd_addr,
    input  logic [31:0] char_q,

    // ── Pixel output (async from line buffer, indexed by screen column) ──
    // Format: {color[4:0], pen[3:0]}; pen==0 → transparent.
    input  logic [ 9:0] hpos,           // horizontal counter 0..431
    output logic [ 8:0] text_pixel
);

// =============================================================================
// Video timing constant
// =============================================================================
localparam int H_START = 46;   // first active pixel column

// =============================================================================
// HBLANK rising-edge detect
// =============================================================================
logic hblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_r <= 1'b0;
    else        hblank_r <= hblank;
end
logic hblank_rise;
assign hblank_rise = hblank & ~hblank_r;

// =============================================================================
// Pre-fetch geometry: NEXT scanline
// Latched at hblank_rise so the correct vpos is used for the entire fill,
// even if vpos increments mid-fill when hpos wraps around during HBLANK.
// =============================================================================
logic [8:0] fetch_vpos_c;   // combinational: vpos + 1
logic [2:0] fetch_py;       // pixel row within tile (0..7) — latched
logic [5:0] fetch_row;      // tile row in map (0..63) — latched

assign fetch_vpos_c = vpos + 9'd1;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        fetch_py  <= 3'b0;
        fetch_row <= 6'b0;
    end else if (hblank_rise) begin
        fetch_py  <= fetch_vpos_c[2:0];
        fetch_row <= fetch_vpos_c[8:3];
    end
end

// =============================================================================
// FSM
// =============================================================================
typedef enum logic [1:0] {
    TX_IDLE = 2'd0,
    TX_TRAM = 2'd1,   // present addresses; decode tile; write 8 pixels
    TX_NEXT = 2'd2    // advance column; loop or finish
} tx_state_t;

tx_state_t  state;
logic [5:0] tx_col;       // current tile column (0..39)

// =============================================================================
// Combinational decode from Text RAM word
// =============================================================================
logic [4:0] color_c;
logic [7:0] char_code_c;

assign color_c     = text_q[15:11];
// Character RAM holds 256 tiles (8KB / 32 bytes per tile).
// Tile word bits[10:0] encode up to 2047, but only lower 8 bits index char RAM
// (wraps mod 256 — section1 §6).  Bits[10:8] are not used for char RAM access.
/* verilator lint_off UNUSED */
logic _unused_char_hi;
assign _unused_char_hi = ^text_q[10:8];
/* verilator lint_on UNUSED */
assign char_code_c = text_q[7:0];     // lower 8 bits → 256-tile char RAM

// =============================================================================
// Text RAM address (combinational)
// =============================================================================
always_comb begin
    if (state == TX_TRAM)
        text_rd_addr = {fetch_row, tx_col};
    else
        text_rd_addr = 12'b0;
end

// =============================================================================
// Character RAM address (combinational)
// In TX_TRAM: use char_code_c (from combinational text_q).
// =============================================================================
always_comb begin
    if (state == TX_TRAM)
        char_rd_addr = {char_code_c, fetch_py};
    else
        char_rd_addr = 11'b0;
end

// =============================================================================
// Line buffer: 320 × 9-bit {color[4:0], pen[3:0]}
// =============================================================================
logic [8:0] linebuf [0:319];

// Screen-column index, clamped to [0..319]
logic [9:0] screen_col;
assign screen_col = (hpos >= 10'(H_START)) ? (hpos - 10'(H_START)) : 10'd0;

assign text_pixel = linebuf[screen_col <= 10'd319 ? screen_col[8:0] : 9'd0];

// =============================================================================
// FSM + line buffer writes
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state  <= TX_IDLE;
        tx_col <= 6'b0;
    end else begin
        case (state)

            TX_IDLE: begin
                if (hblank_rise) begin
                    tx_col <= 6'b0;
                    state  <= TX_TRAM;
                end
            end

            TX_TRAM: begin
                // Both Text RAM and Character RAM are async → text_q and char_q
                // are combinationally valid this cycle.
                // Decode charlayout nibbles from 32-bit char_q row word:
                //   char_q[7:0]=b0, [15:8]=b1, [23:16]=b2, [31:24]=b3
                //   px0: b2[7:4]=char_q[23:20]  px1: b2[3:0]=char_q[19:16]
                //   px2: b3[7:4]=char_q[31:28]  px3: b3[3:0]=char_q[27:24]
                //   px4: b0[7:4]=char_q[ 7: 4]  px5: b0[3:0]=char_q[ 3: 0]
                //   px6: b1[7:4]=char_q[15:12]  px7: b1[3:0]=char_q[11: 8]
                // Fully unrolled, no begin/end sub-blocks, no variable-index NBA.
                linebuf[int'(tx_col)*8+0] <= {color_c, char_q[23:20]};
                linebuf[int'(tx_col)*8+1] <= {color_c, char_q[19:16]};
                linebuf[int'(tx_col)*8+2] <= {color_c, char_q[31:28]};
                linebuf[int'(tx_col)*8+3] <= {color_c, char_q[27:24]};
                linebuf[int'(tx_col)*8+4] <= {color_c, char_q[ 7: 4]};
                linebuf[int'(tx_col)*8+5] <= {color_c, char_q[ 3: 0]};
                linebuf[int'(tx_col)*8+6] <= {color_c, char_q[15:12]};
                linebuf[int'(tx_col)*8+7] <= {color_c, char_q[11: 8]};
                state <= TX_NEXT;
            end

            TX_NEXT: begin
                if (tx_col == 6'd39)
                    state <= TX_IDLE;
                else begin
                    tx_col <= tx_col + 6'd1;
                    state  <= TX_TRAM;
                end
            end

            default: state <= TX_IDLE;
        endcase
    end
end

// =============================================================================
// Suppress unused-signal warnings for signals consumed only in subexpressions
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused_text;
assign _unused_text = ^{fetch_vpos_c[0], hblank_r};
/* verilator lint_on UNUSED */

endmodule
