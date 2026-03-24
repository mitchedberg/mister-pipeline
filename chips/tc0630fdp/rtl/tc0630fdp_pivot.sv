`default_nettype none
// =============================================================================
// TC0630FDP — Pivot (Pixel) Layer Engine  (Step 16)
// =============================================================================
// Implements the pivot/pixel layer: 64×32 column-major tile map, 8×8 4bpp tiles,
// pixel data sourced from Pivot RAM (32K × 16-bit words).
//
// Canvas geometry:
//   64 tile columns × 32 tile rows × 8×8 pixels = 512×256 pixel canvas.
//   TILEMAP_SCAN_COLS (column-major): tile_idx(col, row) = col * 32 + row
//
// Pivot RAM tile format (charlayout, section1 §11.2):
//   8×8 tile, 4bpp, 32 bytes/tile = 16 words of 16-bit = 8 words of 32-bit.
//   pvt_rd_addr = {tile_idx[10:0], fetch_py[2:0]}  (14-bit 32-bit word address)
//   pvt_q = {b3, b2, b1, b0} — four bytes of the selected row.
//   Pixel decode (charlayout):
//     px0 → pvt_q[23:20],  px1 → pvt_q[19:16]
//     px2 → pvt_q[31:28],  px3 → pvt_q[27:24]
//     px4 → pvt_q[ 7: 4],  px5 → pvt_q[ 3: 0]
//     px6 → pvt_q[15:12],  px7 → pvt_q[11: 8]
//
// Color: always 4'b0 (MAME pivot_tile_info always returns color=0).
// Output: {color[3:0], pen[3:0]}.  pen==0 → transparent.
//
// Per-scanline control (from §9.4 sb_word upper byte):
//   ls_pivot_en   — 1=layer enabled (else all pixels → 0)
//   ls_pivot_bank — 0=bank0, 1=bank1 (adds 32 to tile column index)
//   ls_pivot_blend— blend select: 0=opaque, 1=blend A (forwarded to colmix)
//
// Scroll: pixel_xscroll[15:6]=xscroll_int(10b), pixel_yscroll[15:7]=yscroll_int(9b)
//   canvas_y = (vpos+1 + yscroll_int) & 0xFF  (8-bit, 256-line wrap)
//   canvas_x for screen col c = c + xscroll_int (mod 512)
//
// FSM: 2 cycles/tile × 41 tiles = 82 cycles (< 112-cycle HBLANK budget)
// =============================================================================

module tc0630fdp_pivot (
    input  logic        clk,
    input  logic        rst_n,

    // Video timing
    input  logic        hblank,
    input  logic [ 8:0] vpos,

    // Per-scanline control
    input  logic        ls_pivot_en,
    input  logic        ls_pivot_bank,
    input  logic        ls_pivot_blend,

    // Pixel layer scroll
    input  logic [15:0] pixel_xscroll,
    input  logic [15:0] pixel_yscroll,

    // Pivot RAM 32-bit async read port
    // pvt_rd_addr[13:0] = {tile_idx[10:0], fetch_py[2:0]}
    output logic [13:0] pvt_rd_addr,
    input  logic [31:0] pvt_q,

    // Pixel output
    input  logic [ 9:0] hpos,
    output logic [ 7:0] pivot_pixel
);

localparam int H_START = 46;

// HBLANK rising edge
logic hblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_r <= 1'b0;
    else        hblank_r <= hblank;
end
logic hblank_rise;
assign hblank_rise = hblank & ~hblank_r;

// Scroll decode
logic [9:0] xscroll_int;
logic [8:0] yscroll_int;
assign xscroll_int = pixel_xscroll[15:6];
assign yscroll_int = pixel_yscroll[15:7];

// Canvas Y for next scanline (8-bit wrap: 256-line canvas)
logic [7:0] canvas_y_c;
assign canvas_y_c = 8'(vpos + 9'd1) + 8'(yscroll_int);

// Latched fetch parameters (captured at hblank_rise)
logic [2:0] fetch_py;          // pixel row within tile (0..7)
logic [4:0] fetch_row;         // tile row in map (0..31)
logic [5:0] xscr_tile;         // xscroll integer part >> 3 (tile units, 6-bit wraps mod 64)
logic [2:0] pix_off;           // xscroll pixel offset within first tile (bits[2:0])
logic [5:0] bank_off;          // bank offset: 0 or 32

always_ff @(posedge clk) begin
    if (!rst_n) begin
        fetch_py  <= 3'b0;
        fetch_row <= 5'b0;
        xscr_tile <= 6'b0;
        pix_off   <= 3'b0;
        bank_off  <= 6'd0;
    end else if (hblank_rise) begin
        fetch_py  <= canvas_y_c[2:0];
        fetch_row <= canvas_y_c[7:3];
        xscr_tile <= 6'(xscroll_int[9:3]);
        pix_off   <= xscroll_int[2:0];
        bank_off  <= ls_pivot_bank ? 6'd32 : 6'd0;
    end
end

// FSM state
typedef enum logic [2:0] {
    PV_IDLE     = 3'd0,
    PV_TILE     = 3'd1,
    PV_NEXT     = 3'd2,
    PV_PREFETCH = 3'd3   // QUARTUS: registered-read pre-fetch cycle before first PV_TILE
} pv_state_t;

pv_state_t  state;
logic [5:0] tx_col;   // screen tile slot 0..39 (40 tiles)

// Tile column in pivot map (6-bit, wraps mod 64)
logic [5:0] cur_tile_col;
assign cur_tile_col = (xscr_tile + bank_off + tx_col) & 6'h3F;

// Tile index: column-major col*32 + row = {col[5:0], row[4:0]}
logic [10:0] tile_idx;
assign tile_idx = {cur_tile_col, fetch_row};

`ifdef QUARTUS
// Next tile's column and index (used in PV_NEXT to pre-issue the address for tx_col+1).
// tx_col is about to be incremented; compute combinationally with tx_col+1 so the
// registered M10K read has data ready when we enter PV_TILE.
logic [5:0]  next_cur_tile_col;
logic [10:0] next_tile_idx;
assign next_cur_tile_col = (xscr_tile + bank_off + (tx_col + 6'd1)) & 6'h3F;
assign next_tile_idx     = {next_cur_tile_col, fetch_row};
`endif

// Pivot RAM address driver:
// Simulation: combinational from PV_TILE state (async read, 0-cycle latency).
// QUARTUS: pre-issued one cycle before PV_TILE (registered M10K read, 1-cycle latency).
//   PV_PREFETCH: drives tile 0 address  → data ready for first PV_TILE
//   PV_NEXT:     drives tx_col+1 addr   → data ready for subsequent PV_TILE entries
`ifdef QUARTUS
always_comb begin
    case (state)
        PV_PREFETCH: pvt_rd_addr = {tile_idx,      fetch_py};  // pre-fetch tile 0
        PV_NEXT:     pvt_rd_addr = {next_tile_idx, fetch_py};  // pre-fetch tile tx_col+1
        default:     pvt_rd_addr = 14'b0;
    endcase
end
`else
always_comb begin
    if (state == PV_TILE)
        pvt_rd_addr = {tile_idx, fetch_py};
    else
        pvt_rd_addr = 14'b0;
end
`endif

// Line buffer 320 × 8-bit
// NOTE: PV_TILE writes 8 addresses per clock cycle (unrolled pixel decode).
// This prevents altsyncram replacement (only 1 write port available).
// (* ramstyle = "MLAB" *) hint is kept but ignored by Quartus 17.0 Lite;
// 320×8=2560 FFs will map to ALMs until pixel-write serialisation refactor.
`ifdef QUARTUS
(* ramstyle = "MLAB" *) logic [7:0] linebuf [0:319];
`else
logic [7:0] linebuf [0:319];
`endif

// Screen column read-out
logic [9:0] screen_col_rd;
assign screen_col_rd = (hpos >= 10'(H_START)) ? (hpos - 10'(H_START)) : 10'd0;

always_comb begin
    if (!ls_pivot_en)
        pivot_pixel = 8'b0;
    else if (screen_col_rd < 10'd320)
        pivot_pixel = linebuf[screen_col_rd[8:0]];
    else
        pivot_pixel = 8'b0;
end

// Compute per-pixel screen columns for current tile slot.
// scol_base = tx_col*8 - pix_off  (signed, may be negative for slot 0)
// Use 10-bit signed arithmetic; clamp each pixel to [0,319].

// Intermediate screen column computations (combinational)
logic [9:0] scol_px [0:7];
logic       scol_ok [0:7];

// Signed intermediates for screen column computation (module-level for Verilator)
logic signed [10:0] scol_base_s;
logic signed [10:0] scol_sc_s;

always_comb begin
    // Base screen column (signed 10-bit)
    scol_base_s = $signed({1'b0, tx_col, 3'b000}) - $signed({8'b0, pix_off});
    for (int px = 0; px < 8; px++) begin
        scol_sc_s = scol_base_s + $signed(11'(px));
        if (scol_sc_s >= $signed(11'd0) && scol_sc_s < $signed(11'd320)) begin
            scol_px[px] = 10'(scol_sc_s[9:0]);
            scol_ok[px] = 1'b1;
        end else begin
            scol_px[px] = 10'd0;
            scol_ok[px] = 1'b0;
        end
    end
end

// FSM + line buffer writes
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state  <= PV_IDLE;
        tx_col <= 6'b0;
    end else begin
        case (state)
            PV_IDLE: begin
                if (hblank_rise) begin
                    tx_col <= 6'b0;
`ifdef QUARTUS
                    state  <= PV_PREFETCH;  // registered read: pre-fetch tile 0 before PV_TILE
`else
                    state  <= PV_TILE;
`endif
                end
            end

            // ─── [QUARTUS only] Pre-fetch first tile ────────────────────────
            // pvt_rd_addr = {tile_idx(tx_col=0), fetch_py} driven combinationally above.
            // Registered M10K read fires at this clock edge → pvt_q valid in PV_TILE.
            // Simulation: this state is never entered (PV_IDLE goes directly to PV_TILE).
            PV_PREFETCH: begin
                state <= PV_TILE;
            end

            PV_TILE: begin
                // QUARTUS: pvt_q is registered data from previous cycle (PV_PREFETCH or PV_NEXT).
                // Simulation: pvt_q is async (combinational) from pvt_rd_addr set in this state.
                // Charlayout nibble decode: pvt_q = {b3,b2,b1,b0}
                //   px0=pvt_q[23:20]  px1=pvt_q[19:16]
                //   px2=pvt_q[31:28]  px3=pvt_q[27:24]
                //   px4=pvt_q[ 7: 4]  px5=pvt_q[ 3: 0]
                //   px6=pvt_q[15:12]  px7=pvt_q[11: 8]
                // color is always 4'b0
                if (scol_ok[0]) linebuf[scol_px[0][8:0]] <= {4'b0, pvt_q[23:20]};
                if (scol_ok[1]) linebuf[scol_px[1][8:0]] <= {4'b0, pvt_q[19:16]};
                if (scol_ok[2]) linebuf[scol_px[2][8:0]] <= {4'b0, pvt_q[31:28]};
                if (scol_ok[3]) linebuf[scol_px[3][8:0]] <= {4'b0, pvt_q[27:24]};
                if (scol_ok[4]) linebuf[scol_px[4][8:0]] <= {4'b0, pvt_q[ 7: 4]};
                if (scol_ok[5]) linebuf[scol_px[5][8:0]] <= {4'b0, pvt_q[ 3: 0]};
                if (scol_ok[6]) linebuf[scol_px[6][8:0]] <= {4'b0, pvt_q[15:12]};
                if (scol_ok[7]) linebuf[scol_px[7][8:0]] <= {4'b0, pvt_q[11: 8]};
                state <= PV_NEXT;
            end
            PV_NEXT: begin
                // QUARTUS: pvt_rd_addr = next_tile_idx (pre-fetch for tx_col+1),
                // driven combinationally from PV_NEXT above.
                if (tx_col == 6'd39)
                    state <= PV_IDLE;
                else begin
                    tx_col <= tx_col + 6'd1;
                    state  <= PV_TILE;
                end
            end
            default: state <= PV_IDLE;
        endcase
    end
end

// Suppress unused warnings
/* verilator lint_off UNUSED */
logic _unused_pvt;
assign _unused_pvt = ^{hblank_r, ls_pivot_blend, canvas_y_c[0], yscroll_int[8],
                       pixel_xscroll[5:0], pixel_yscroll[6:0]};
/* verilator lint_on UNUSED */

endmodule
