`default_nettype none
// =============================================================================
// TC0630FDP — Text (VRAM) Layer Engine  (Phase 2: Serialised writes)
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
//   Charlayout nibble assignment from 32-bit char_q:
//     px0 → char_q[23:20]   px1 → char_q[19:16]
//     px2 → char_q[31:28]   px3 → char_q[27:24]
//     px4 → char_q[ 7: 4]   px5 → char_q[ 3: 0]
//     px6 → char_q[15:12]   px7 → char_q[11: 8]
//
// No FlipX / FlipY — text tile word has no flip bits (section1 §5).
//
// FSM timing (clk_4x = 4× pixel clock ≈ 96 MHz):
//   HBLANK budget: 448 clk_4x cycles.
//   Per tile: TX_TRAM(1) + TX_PIXEL(8) + TX_NEXT(1) = 10 clk_4x cycles.
//   40 tiles × 10 = 400 clk_4x cycles < 448 budget.  OK.
//
//   TX_IDLE → (hblank_rise_4x) → TX_TRAM → TX_PIXEL(×8) → TX_NEXT → TX_TRAM → ...
//
//   TX_TRAM (1 clk_4x): present text_rd_addr and char_rd_addr (async read);
//                       latch text_q fields; latch char_q; reset px_idx.
//   TX_PIXEL (8 clk_4x): write one pixel per cycle using latched char data.
//   TX_NEXT (1 clk_4x):  advance tx_col; loop back to TX_TRAM or go TX_IDLE.
//
// Phase 2 change: TX_TRAM now only latches data (no direct linebuf write).
//   TX_PIXEL state (new) writes 1 pixel per clk_4x cycle from latched char_q.
//   This makes the linebuf a single-write-per-cycle port → altsyncram (MLAB).
//
// Output: text_pixel[8:0] = {color[4:0], pen[3:0]}.  pen==0 → transparent.
// Line buffer is 320 entries indexed by (hpos − H_START).
// =============================================================================

module tc0630fdp_text (
    input  logic        clk,
    input  logic        clk_4x,        // 4× pixel clock (≈96 MHz) — used for linebuf fill
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
// HBLANK rising-edge detect (clk domain)
// =============================================================================
logic hblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_r <= 1'b0;
    else        hblank_r <= hblank;
end
logic hblank_rise_clk;
assign hblank_rise_clk = hblank & ~hblank_r;

// Synchronise hblank_rise into clk_4x domain (2-FF sync)
logic [1:0] hrise_sync;
always_ff @(posedge clk_4x) begin
    if (!rst_n) hrise_sync <= 2'b00;
    else        hrise_sync <= {hrise_sync[0], hblank_rise_clk};
end
logic hblank_rise_4x;
assign hblank_rise_4x = hrise_sync[1];

// =============================================================================
// Pre-fetch geometry: NEXT scanline
// Latched from clk domain at hblank_rise_clk, then captured into clk_4x domain.
// =============================================================================
logic [8:0] fetch_vpos_c;   // combinational: vpos + 1
assign fetch_vpos_c = vpos + 9'd1;

// Capture in clk domain
logic [2:0] fetch_py_clk;   // pixel row within tile (0..7)
logic [5:0] fetch_row_clk;  // tile row in map (0..63)

always_ff @(posedge clk) begin
    if (!rst_n) begin
        fetch_py_clk  <= 3'b0;
        fetch_row_clk <= 6'b0;
    end else if (hblank_rise_clk) begin
        fetch_py_clk  <= fetch_vpos_c[2:0];
        fetch_row_clk <= fetch_vpos_c[8:3];
    end
end

// Capture into clk_4x domain (stable after hblank_rise_clk)
logic [2:0] fetch_py;
logic [5:0] fetch_row;
always_ff @(posedge clk_4x) begin
    if (hrise_sync[0]) begin
        fetch_py  <= fetch_py_clk;
        fetch_row <= fetch_row_clk;
    end
end

// =============================================================================
// FSM
// =============================================================================
typedef enum logic [1:0] {
    TX_IDLE  = 2'd0,
    TX_TRAM  = 2'd1,   // present addresses; latch text+char data; px_idx=0
    TX_PIXEL = 2'd2,   // write one pixel per clk_4x cycle (px_idx 0..7)
    TX_NEXT  = 2'd3    // advance column; loop or finish
} tx_state_t;

tx_state_t  state;
logic [5:0] tx_col;       // current tile column (0..39)
logic [2:0] px_idx;       // pixel within tile (0..7)

// Latched tile data (captured in TX_TRAM)
logic [4:0]  tile_color_r;
logic [31:0] tile_char_q_r;

// =============================================================================
// Charlayout pixel nibble extraction (from latched char_q)
// The 8 pixel nibbles in charlayout order:
//   px0 → [23:20], px1 → [19:16], px2 → [31:28], px3 → [27:24]
//   px4 → [7:4],   px5 → [3:0],   px6 → [15:12], px7 → [11:8]
// =============================================================================
logic [3:0] char_nibble [0:7];
always_comb begin
    char_nibble[0] = tile_char_q_r[23:20];
    char_nibble[1] = tile_char_q_r[19:16];
    char_nibble[2] = tile_char_q_r[31:28];
    char_nibble[3] = tile_char_q_r[27:24];
    char_nibble[4] = tile_char_q_r[ 7: 4];
    char_nibble[5] = tile_char_q_r[ 3: 0];
    char_nibble[6] = tile_char_q_r[15:12];
    char_nibble[7] = tile_char_q_r[11: 8];
end

// =============================================================================
// Combinational decode from Text RAM word (valid in TX_TRAM)
// =============================================================================
logic [4:0] color_c;
logic [7:0] char_code_c;

assign color_c     = text_q[15:11];
/* verilator lint_off UNUSED */
logic _unused_char_hi;
assign _unused_char_hi = ^text_q[10:8];
/* verilator lint_on UNUSED */
assign char_code_c = text_q[7:0];

// =============================================================================
// Text RAM address (combinational)
// =============================================================================
always_comb begin
    if (state == TX_TRAM)
        text_rd_addr = {fetch_row, tx_col[5:0]};
    else
        text_rd_addr = 12'b0;
end

// =============================================================================
// Character RAM address (combinational)
// In TX_TRAM: async read — data valid same cycle.
// =============================================================================
always_comb begin
    if (state == TX_TRAM)
        char_rd_addr = {char_code_c, fetch_py};
    else
        char_rd_addr = 11'b0;
end

// =============================================================================
// Line buffer: 320 × 9-bit {color[4:0], pen[3:0]}
//
// Phase 2: TX_PIXEL writes 1 pixel per clk_4x cycle (serialised).
// This enables altsyncram (MLAB dual-port) under `ifdef QUARTUS.
//   Port A (write): clk_4x, single addr+data+wen.
//   Port B (read):  UNREGISTERED async, addressed by screen_col.
//
// Simulation: register array, identical pixel output.
// =============================================================================

// Write-port signals
logic [8:0] lb_wdata;   // {color, pen}
logic [8:0] lb_waddr;   // pixel address [0..319]
logic       lb_wen;

// Read address: screen column (from hpos)
logic [8:0] screen_col;
always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_START + 320))
        screen_col = hpos[8:0] - 9'(H_START);
    else
        screen_col = 9'd0;
end

`ifdef QUARTUS
logic [8:0] lb_rdata;

altsyncram #(
    .width_a            (9),
    .widthad_a          (9),
    .numwords_a         (512),
    .width_b            (9),
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
    .address_b (screen_col),
    .q_b       (lb_rdata),
    // unused ports
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({9{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
    .wren_b(1'b0)
);

assign text_pixel = lb_rdata;

`else
// Simulation: register array
logic [8:0] linebuf [0:319];

always_ff @(posedge clk_4x) begin
    if (lb_wen) linebuf[lb_waddr] <= lb_wdata;
end

assign text_pixel = linebuf[screen_col <= 9'd319 ? screen_col : 9'd0];
`endif

// =============================================================================
// Serialised pixel write signals (combinational from TX_PIXEL state)
// =============================================================================
always_comb begin
    // Screen column for current pixel: tx_col*8 + px_idx
    logic [8:0] scol;
    scol = 9'({tx_col[5:0], 3'b000}) + 9'({6'b0, px_idx});

    lb_wdata = {tile_color_r, char_nibble[px_idx]};
    lb_waddr = scol;
    lb_wen   = (state == TX_PIXEL) && (scol < 9'd320);
end

// =============================================================================
// FSM + line buffer writes (clk_4x domain)
// =============================================================================
always_ff @(posedge clk_4x) begin
    if (!rst_n) begin
        state         <= TX_IDLE;
        tx_col        <= 6'b0;
        px_idx        <= 3'b0;
        tile_color_r  <= 5'b0;
        tile_char_q_r <= 32'b0;
    end else begin
        case (state)

            TX_IDLE: begin
                if (hblank_rise_4x) begin
                    tx_col <= 6'b0;
                    state  <= TX_TRAM;
                end
            end

            TX_TRAM: begin
                // Async reads: text_q and char_q are combinationally valid.
                // Latch tile data for the 8-cycle TX_PIXEL loop.
                tile_color_r  <= color_c;
                tile_char_q_r <= char_q;
                px_idx        <= 3'b0;
                state         <= TX_PIXEL;
            end

            TX_PIXEL: begin
                // lb_wen/lb_waddr/lb_wdata driven combinationally above.
                // Serialised write: one pixel per clk_4x cycle.
                if (px_idx == 3'd7) begin
                    state <= TX_NEXT;
                end else begin
                    px_idx <= px_idx + 3'd1;
                end
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
// Suppress unused-signal warnings
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused_text;
assign _unused_text = ^{fetch_vpos_c[0], hblank_r};
/* verilator lint_on UNUSED */

endmodule
