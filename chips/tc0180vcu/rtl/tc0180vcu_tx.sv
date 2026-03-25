`default_nettype none
// =============================================================================
// TC0180VCU — TX Tilemap Render Module
// =============================================================================
// Fills a 512-pixel line buffer during HBLANK for the NEXT scanline.
// TX layer: 64 columns × 32 rows of 8×8 4bpp tiles → 512×256 canvas.
//
// FSM (5 states × 64 tiles = 320 cycles per HBLANK):
//   TX_IDLE → (hblank_fall) → TX_VRAM → TX_P0 → TX_P1 → TX_P2 → (next tile)
//
// GFX ROM format (8×8 tile, 4bpp, 32 bytes/tile):
//   gfx_base = gfx_code * 32 + fetch_py * 2
//   Planes 0,1: bytes [gfx_base+0,  gfx_base+1]
//   Planes 2,3: bytes [gfx_base+16, gfx_base+17]
//   Pixel px (0=leftmost): bit (7−px) of each plane byte
//
// Pre-fetch: fills line buffer for NEXT scanline during current HBLANK.
// =============================================================================

module tc0180vcu_tx (
    input  logic        clk,
    input  logic        rst_n,

    // Video timing
    input  logic        hblank_n,       // active-low HBLANK
    input  logic [ 7:0] vpos,           // current scanline
    input  logic [ 8:0] hpos,           // horizontal pixel position (0..511)

    // VRAM async read port (combinational: vram_q valid same cycle as vram_rd_addr)
    output logic [14:0] vram_rd_addr,
    input  logic [15:0] vram_q,
    output logic        vram_rd,
    input  logic        vram_ok,

    // Control register fields (from parent)
    input  logic [ 5:0] tx_tilebank0,   // GFX bank when tile word bit[11]=0
    input  logic [ 5:0] tx_tilebank1,   // GFX bank when tile word bit[11]=1
    input  logic [ 3:0] tx_rampage,     // TX VRAM page (4-bit)

    // GFX ROM interface
    output logic [22:0] gfx_addr,
    input  logic [ 7:0] gfx_data,
    output logic        gfx_rd,
    input  logic        gfx_ok,

    // Pixel output (async read from line buffer, indexed by hpos)
    // Format: {color[3:0], pixel_index[3:0]}
    output logic [ 7:0] tx_pixel
);

// =============================================================================
// Pre-fetch target: NEXT scanline
// =============================================================================
logic [7:0] fetch_vpos;
logic [2:0] fetch_py;
logic [4:0] fetch_row;
assign fetch_vpos = vpos + 8'd1;
assign fetch_py   = fetch_vpos[2:0];   // pixel row within 8×8 tile
assign fetch_row  = fetch_vpos[7:3];   // tile row index (0..31)

// =============================================================================
// HBLANK falling-edge detect (start of HBLANK — trigger line buffer fill)
// =============================================================================
logic hblank_n_r;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_n_r <= 1'b1;
    else        hblank_n_r <= hblank_n;
end
logic hblank_fall;
assign hblank_fall = ~hblank_n & hblank_n_r;

// =============================================================================
// FSM
// =============================================================================
typedef enum logic [2:0] {
    TX_IDLE = 3'd0,
    TX_VRAM = 3'd1,   // async VRAM read; latch tile_word + plane0
    TX_P0   = 3'd2,   // latch plane1
    TX_P1   = 3'd3,   // latch plane2
    TX_P2   = 3'd4    // latch plane3; decode 8 pixels → line buffer
} tx_state_t;

tx_state_t   state;
logic [ 5:0] tx_col;        // current tile column (0..63)

// Registered tile fields
logic [ 3:0] tx_color_r;    // tile color attribute [15:12] of VRAM word
logic [21:0] gfx_base_r;    // tile GFX ROM base byte address (gfx_code*32 + py*2)
logic [ 7:0] gfx_b0_r;      // plane 0 byte
logic [ 7:0] gfx_b1_r;      // plane 1 byte
logic [ 7:0] gfx_b2_r;      // plane 2 byte

// =============================================================================
// Combinational decode from VRAM word (valid while in TX_VRAM state)
// =============================================================================
logic [10:0] tile_idx_c;
logic        bank_sel_c;
logic [ 3:0] color_c;
logic [16:0] gfx_code_c;
logic [21:0] gfx_base_c;

assign color_c    = vram_q[15:12];
assign bank_sel_c = vram_q[11];
assign tile_idx_c = vram_q[10:0];
// gfx_code: 6-bit bank || 11-bit tile index = 17 bits
assign gfx_code_c = bank_sel_c ? {tx_tilebank1, tile_idx_c}
                                : {tx_tilebank0, tile_idx_c};
// gfx_base = gfx_code*32 + fetch_py*2  (22 bits, no overflow)
assign gfx_base_c = {gfx_code_c, 5'b00000} + {18'b0, fetch_py, 1'b0};

// =============================================================================
// VRAM address (combinational — valid only during TX_VRAM state)
// =============================================================================
always_comb begin
    if (state == TX_VRAM)
        vram_rd_addr = {tx_rampage, fetch_row, tx_col};  // 4+5+6 = 15 bits
    else
        vram_rd_addr = 15'b0;
end

assign vram_rd = (state == TX_VRAM);

// =============================================================================
// GFX ROM address (combinational, state-dependent)
// =============================================================================
always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 23'b0;
    case (state)
        TX_VRAM: begin
            gfx_addr = {1'b0, gfx_base_c};                   // plane 0
            gfx_rd   = 1'b1;
        end
        TX_P0: begin
            gfx_addr = {1'b0, gfx_base_r} + 23'd1;           // plane 1
            gfx_rd   = 1'b1;
        end
        TX_P1: begin
            gfx_addr = {1'b0, gfx_base_r} + 23'd16;          // plane 2
            gfx_rd   = 1'b1;
        end
        TX_P2: begin
            gfx_addr = {1'b0, gfx_base_r} + 23'd17;          // plane 3
            gfx_rd   = 1'b1;
        end
        default: begin
            gfx_addr = 23'b0;
            gfx_rd   = 1'b0;
        end
    endcase
end

// =============================================================================
// Tile line buffer: 64 × 64-bit
// One packed 8-pixel word per tile column. This keeps the write-side at one
// address per cycle so Quartus infers real RAM instead of a large bank of FFs.
// =============================================================================
logic [63:0] tilebuf_wdata;
logic [63:0] tilebuf_rdata;
logic [5:0]  tilebuf_raddr;
logic        tilebuf_we;

assign tilebuf_raddr = hpos[8:3];
assign tilebuf_we    = (state == TX_P2) && gfx_ok;

always_comb begin
    for (int px = 0; px < 8; px++) begin
        tilebuf_wdata[px*8 +: 8] = {
            tx_color_r,
            gfx_data[7-px],
            gfx_b2_r[7-px],
            gfx_b1_r[7-px],
            gfx_b0_r[7-px]
        };
    end
end

`ifdef QUARTUS
altsyncram #(
    .width_a            (64),
    .widthad_a          (6),
    .numwords_a         (64),
    .width_b            (64),
    .widthad_b          (6),
    .numwords_b         (64),
    .operation_mode     ("DUAL_PORT"),
    .ram_block_type     ("M10K"),
    .outdata_reg_a      ("UNREGISTERED"),
    .outdata_reg_b      ("UNREGISTERED"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .intended_device_family ("Cyclone V")
) u_tilebuf (
    .clock0    (clk),
    .address_a (tx_col),
    .data_a    (tilebuf_wdata),
    .wren_a    (tilebuf_we),
    .address_b (tilebuf_raddr),
    .q_b       (tilebuf_rdata),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({64{1'b0}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
    .wren_b(1'b0)
);
`else
logic [63:0] tilebuf [0:63];
always_ff @(posedge clk) begin
    if (tilebuf_we) tilebuf[tx_col] <= tilebuf_wdata;
end
assign tilebuf_rdata = tilebuf[tilebuf_raddr];
`endif

always_comb begin
    case (hpos[2:0])
        3'd0: tx_pixel = tilebuf_rdata[ 7: 0];
        3'd1: tx_pixel = tilebuf_rdata[15: 8];
        3'd2: tx_pixel = tilebuf_rdata[23:16];
        3'd3: tx_pixel = tilebuf_rdata[31:24];
        3'd4: tx_pixel = tilebuf_rdata[39:32];
        3'd5: tx_pixel = tilebuf_rdata[47:40];
        3'd6: tx_pixel = tilebuf_rdata[55:48];
        default: tx_pixel = tilebuf_rdata[63:56];
    endcase
end

// =============================================================================
// FSM, register updates, and line buffer writes
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state      <= TX_IDLE;
        tx_col     <= 6'b0;
        tx_color_r <= 4'b0;
        gfx_base_r <= 22'b0;
        gfx_b0_r   <= 8'b0;
        gfx_b1_r   <= 8'b0;
        gfx_b2_r   <= 8'b0;
    end else begin
        case (state)
            TX_IDLE: begin
                if (hblank_fall) begin
                    tx_col <= 6'b0;
                    state  <= TX_VRAM;
                end
            end

            TX_VRAM: begin
                if (vram_ok && gfx_ok) begin
                    tx_color_r <= color_c;
                    gfx_base_r <= gfx_base_c;
                    gfx_b0_r   <= gfx_data;   // plane 0
                    state      <= TX_P0;
                end
            end

            TX_P0: begin
                if (gfx_ok) begin
                    gfx_b1_r <= gfx_data;     // plane 1
                    state    <= TX_P1;
                end
            end

            TX_P1: begin
                if (gfx_ok) begin
                    gfx_b2_r <= gfx_data;     // plane 2
                    state    <= TX_P2;
                end
            end

            TX_P2: begin
                if (gfx_ok) begin
                    if (tx_col == 6'd63) begin
                        state <= TX_IDLE;      // all 64 tiles done
                    end else begin
                        tx_col <= tx_col + 6'd1;
                        state  <= TX_VRAM;
                    end
                end
            end

            default: state <= TX_IDLE;
        endcase
    end
end

endmodule
