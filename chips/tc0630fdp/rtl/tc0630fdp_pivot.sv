`default_nettype none
// =============================================================================
// TC0630FDP — Pivot (Pixel) Layer Engine  (Phase 2: Serialised writes)
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
// FSM timing (clk_4x = 4× pixel clock ≈ 96 MHz):
//   HBLANK budget: 448 clk_4x cycles.
//   Per tile:
//     QUARTUS path: PV_PREFETCH(1 first tile only) + PV_NEXT(1) + PV_TILE(1) +
//                   PV_PIXEL(8) = effective ~10 cycles/tile.
//     Sim path:     PV_TILE(1) + PV_PIXEL(8) + PV_NEXT(1) = 10 cycles/tile.
//   41 tiles × 10 = 410 clk_4x cycles + 1 PREFETCH = 411 ≤ 448.  OK.
//
// Phase 2 change:
//   PV_TILE now only latches pvt_q (no direct linebuf writes).
//   New PV_PIXEL state writes 1 pixel per clk_4x cycle (px_idx 0..7).
//   This makes the linebuf write-port single-addr/single-data → altsyncram (MLAB).
// =============================================================================

module tc0630fdp_pivot (
    input  logic        clk,
    input  logic        clk_4x,        // 4× pixel clock (≈96 MHz) — used for linebuf fill
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

// =============================================================================
// HBLANK rising edge (clk domain) + synchroniser to clk_4x
// =============================================================================
logic hblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_r <= 1'b0;
    else        hblank_r <= hblank;
end
logic hblank_rise_clk;
assign hblank_rise_clk = hblank & ~hblank_r;

logic [1:0] hrise_sync;
always_ff @(posedge clk_4x) begin
    if (!rst_n) hrise_sync <= 2'b00;
    else        hrise_sync <= {hrise_sync[0], hblank_rise_clk};
end
logic hblank_rise_4x;
assign hblank_rise_4x = hrise_sync[1];

// =============================================================================
// Scroll decode
// =============================================================================
logic [9:0] xscroll_int;
logic [8:0] yscroll_int;
assign xscroll_int = pixel_xscroll[15:6];
assign yscroll_int = pixel_yscroll[15:7];

// Canvas Y for next scanline (8-bit wrap: 256-line canvas)
logic [7:0] canvas_y_c;
assign canvas_y_c = 8'(vpos + 9'd1) + 8'(yscroll_int);

// =============================================================================
// Latched fetch parameters (captured at hblank_rise in clk domain,
// then synchronised into clk_4x via hrise_sync).
// =============================================================================
// clk domain: latched at hblank_rise_clk
logic [2:0] fetch_py_clk;
logic [4:0] fetch_row_clk;
logic [5:0] xscr_tile_clk;
logic [2:0] pix_off_clk;
logic [5:0] bank_off_clk;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        fetch_py_clk  <= 3'b0;
        fetch_row_clk <= 5'b0;
        xscr_tile_clk <= 6'b0;
        pix_off_clk   <= 3'b0;
        bank_off_clk  <= 6'd0;
    end else if (hblank_rise_clk) begin
        fetch_py_clk  <= canvas_y_c[2:0];
        fetch_row_clk <= canvas_y_c[7:3];
        xscr_tile_clk <= 6'(xscroll_int[9:3]);
        pix_off_clk   <= xscroll_int[2:0];
        bank_off_clk  <= ls_pivot_bank ? 6'd32 : 6'd0;
    end
end

// clk_4x domain: captured when hrise_sync[0] (one clk_4x cycle before hblank_rise_4x)
logic [2:0] fetch_py;
logic [4:0] fetch_row;
logic [5:0] xscr_tile;
logic [2:0] pix_off;
logic [5:0] bank_off;

always_ff @(posedge clk_4x) begin
    if (hrise_sync[0]) begin
        fetch_py  <= fetch_py_clk;
        fetch_row <= fetch_row_clk;
        xscr_tile <= xscr_tile_clk;
        pix_off   <= pix_off_clk;
        bank_off  <= bank_off_clk;
    end
end

// =============================================================================
// FSM state
// =============================================================================
typedef enum logic [2:0] {
    PV_IDLE     = 3'd0,
    PV_TILE     = 3'd1,   // latch pvt_q (async read)
    PV_PIXEL    = 3'd2,   // write 1 pixel per clk_4x cycle (px_idx 0..7)
    PV_NEXT     = 3'd3,   // advance tile column
    PV_PREFETCH = 3'd4    // QUARTUS: pre-fetch first tile (registered read latency)
} pv_state_t;

pv_state_t  state;
logic [5:0] tx_col;   // screen tile slot 0..39 (40 tiles)
logic [2:0] px_idx;   // pixel index within tile (0..7)

// Latched tile data (captured in PV_TILE)
logic [31:0] tile_pvt_q_r;

// Charlayout nibble extraction from latched pvt_q
logic [3:0] pvt_nibble [0:7];
always_comb begin
    pvt_nibble[0] = tile_pvt_q_r[23:20];
    pvt_nibble[1] = tile_pvt_q_r[19:16];
    pvt_nibble[2] = tile_pvt_q_r[31:28];
    pvt_nibble[3] = tile_pvt_q_r[27:24];
    pvt_nibble[4] = tile_pvt_q_r[ 7: 4];
    pvt_nibble[5] = tile_pvt_q_r[ 3: 0];
    pvt_nibble[6] = tile_pvt_q_r[15:12];
    pvt_nibble[7] = tile_pvt_q_r[11: 8];
end

// Tile column in pivot map (6-bit, wraps mod 64)
logic [5:0] cur_tile_col;
assign cur_tile_col = (xscr_tile + bank_off + tx_col) & 6'h3F;

// Tile index: column-major col*32 + row = {col[5:0], row[4:0]}
logic [10:0] tile_idx;
assign tile_idx = {cur_tile_col, fetch_row};

`ifdef QUARTUS
// Next tile's column and index (pre-issued in PV_NEXT for registered M10K read)
logic [5:0]  next_cur_tile_col;
logic [10:0] next_tile_idx;
assign next_cur_tile_col = (xscr_tile + bank_off + (tx_col + 6'd1)) & 6'h3F;
assign next_tile_idx     = {next_cur_tile_col, fetch_row};
`endif

// =============================================================================
// Pivot RAM address driver
// =============================================================================
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

// =============================================================================
// Screen column base for current tile slot (signed, may be negative for slot 0)
// =============================================================================
logic signed [10:0] scol_base_s;
always_comb begin
    scol_base_s = $signed({1'b0, tx_col, 3'b000}) - $signed({8'b0, pix_off});
end

// =============================================================================
// Line buffer: 320 × 8-bit {color[3:0], pen[3:0]}
//
// Phase 2: PV_PIXEL writes 1 pixel per clk_4x cycle (serialised).
// Enables altsyncram (MLAB dual-port) under `ifdef QUARTUS`.
//   Port A (write): clk_4x, single addr+data+wen.
//   Port B (read):  UNREGISTERED async, addressed by screen_col_rd.
//
// Simulation: register array, identical pixel output.
// =============================================================================

// Write-port signals
logic [7:0] lb_wdata;
logic [8:0] lb_waddr;
logic       lb_wen;

// Read address
logic [8:0] screen_col_rd;
always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_START + 320))
        screen_col_rd = hpos[8:0] - 9'(H_START);
    else
        screen_col_rd = 9'd0;
end

`ifdef QUARTUS
logic [7:0] lb_rdata;

altsyncram #(
    .width_a            (8),
    .widthad_a          (9),
    .numwords_a         (512),
    .width_b            (8),
    .widthad_b          (9),
    .numwords_b         (512),
    .operation_mode     ("DUAL_PORT"),
    .ram_block_type     ("MLAB"),
    .outdata_reg_a      ("UNREGISTERED"),
    .outdata_reg_b      ("UNREGISTERED"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .intended_device_family ("Cyclone V")
) u_linebuf (
    .clock0    (clk_4x),
    .address_a (lb_waddr),
    .data_a    (lb_wdata),
    .wren_a    (lb_wen),
    .address_b (screen_col_rd),
    .q_b       (lb_rdata),
    // unused ports
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({8{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
    .wren_b(1'b0)
);

always_comb begin
    if (!ls_pivot_en)
        pivot_pixel = 8'b0;
    else
        pivot_pixel = lb_rdata;
end

`else
// Simulation: register array
logic [7:0] linebuf [0:319];

always_ff @(posedge clk_4x) begin
    if (lb_wen) linebuf[lb_waddr] <= lb_wdata;
end

always_comb begin
    if (!ls_pivot_en)
        pivot_pixel = 8'b0;
    else if (screen_col_rd < 9'd320)
        pivot_pixel = linebuf[screen_col_rd];
    else
        pivot_pixel = 8'b0;
end
`endif

// =============================================================================
// Serialised pixel write signals (combinational from PV_PIXEL state)
// =============================================================================
always_comb begin
    logic signed [10:0] scol_sc_s;
    scol_sc_s = scol_base_s + $signed({8'b0, px_idx});

    lb_wdata = {4'b0, pvt_nibble[px_idx]};
    lb_waddr = 9'(scol_sc_s[8:0]);
    lb_wen   = (state == PV_PIXEL) &&
               (scol_sc_s >= $signed(11'd0)) &&
               (scol_sc_s < $signed(11'd320));
end

// =============================================================================
// FSM (clk_4x domain)
// =============================================================================
always_ff @(posedge clk_4x) begin
    if (!rst_n) begin
        state        <= PV_IDLE;
        tx_col       <= 6'b0;
        px_idx       <= 3'b0;
        tile_pvt_q_r <= 32'b0;
    end else begin
        case (state)
            PV_IDLE: begin
                if (hblank_rise_4x) begin
                    tx_col <= 6'b0;
`ifdef QUARTUS
                    state  <= PV_PREFETCH;
`else
                    state  <= PV_TILE;
`endif
                end
            end

            // ─── [QUARTUS only] Pre-fetch first tile ────────────────────────
            // pvt_rd_addr = {tile_idx(tx_col=0), fetch_py} driven combinationally.
            // Registered M10K read fires → pvt_q valid in PV_TILE.
            PV_PREFETCH: begin
                state <= PV_TILE;
            end

            PV_TILE: begin
                // QUARTUS: pvt_q is registered data from PV_PREFETCH/PV_NEXT.
                // Simulation: pvt_q is async (combinational) from pvt_rd_addr.
                // Latch for the 8-cycle PV_PIXEL loop.
                tile_pvt_q_r <= pvt_q;
                px_idx       <= 3'b0;
                state        <= PV_PIXEL;
            end

            PV_PIXEL: begin
                // lb_wen/lb_waddr/lb_wdata driven combinationally above.
                if (px_idx == 3'd7) begin
                    state <= PV_NEXT;
                end else begin
                    px_idx <= px_idx + 3'd1;
                end
            end

            PV_NEXT: begin
                // QUARTUS: pvt_rd_addr = next_tile_idx driven combinationally above.
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

// =============================================================================
// Suppress unused warnings
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused_pvt;
assign _unused_pvt = ^{hblank_r, ls_pivot_blend, canvas_y_c[0], yscroll_int[8],
                       pixel_xscroll[5:0], pixel_yscroll[6:0]};
/* verilator lint_on UNUSED */

endmodule
