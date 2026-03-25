`default_nettype none
// =============================================================================
// TC0180VCU — BG/FG Tilemap Render Module (Step 4: per-block scroll)
// =============================================================================
// Fills a 512-pixel line buffer during HBLANK for the NEXT scanline.
// BG/FG layers: 64×64 tilemap of 16×16 4bpp tiles → 1024×1024 canvas (wraps).
//
// FSM (10 states per-tile × 22 tiles + 3 scroll-init = 223 cycles per HBLANK):
//   BG_IDLE → (start pulse) → BG_SYRD → BG_INIT →
//             (per tile loop:)
//             BG_CODE → BG_ATTR →
//             BG_GFX0 → BG_GFX1 → BG_GFX2 → BG_GFX3 (left char-block)
//             BG_GFX4 → BG_GFX5 → BG_GFX6 → BG_GFX7 (right char-block; write)
//             → next tile or IDLE
//
// Scroll-init (per-block):
//   lpb  = 256 - lpb_ctrl  (lines per scroll block; lpb_ctrl=0 → lpb=256=global)
//   block = fetch_vpos / lpb
//   scroll_offset = block * 2 * lpb  (word offset within plane's scroll region)
//   BG_IDLE with start: latch scrollX from scroll_q (scroll_rd_addr = SCROLL_BASE + scroll_offset)
//   BG_SYRD: latch scrollY (scroll_rd_addr = SCROLL_BASE + scroll_offset + 1)
//   BG_INIT: compute fetch_py, fetch_ty, first_tile_col from scroll registers
//
// GFX ROM format for 16×16 tile (128 bytes/tile):
//   4 char-blocks 2×2: block0=top-left, block1=top-right,
//                      block2=bottom-left, block3=bottom-right
//   char_base = tile_code*128 + block*32
//   plane0 = gfx[char_base + char_row*2 + 0]
//   plane1 = gfx[char_base + char_row*2 + 1]
//   plane2 = gfx[char_base + 16 + char_row*2 + 0]
//   plane3 = gfx[char_base + 16 + char_row*2 + 1]
//   pixel_idx = {p3[7-lx], p2[7-lx], p1[7-lx], p0[7-lx]}  lx=0..7 left→right
//
// flipX: swap L/R char-blocks AND reverse bit order within each 8-pixel half.
// flipY: py_eff = 15 - fetch_py.
//
// Line buffer: linebuf[0..351] holds 22 tiles of pixels.
//   Write: linebuf[tile_col*16 + 0..15]
//   Read:  layer_pixel = linebuf[(hpos + scrollX_frac) & 511]
//          scrollX_frac = scrollX[3:0]
//
// PLANE parameter: 0=FG, 1=BG (selects scroll RAM word offset).
// =============================================================================

module tc0180vcu_bg #(parameter PLANE = 0) (
    input  logic        clk,
    input  logic        rst_n,

    // Video timing
    input  logic        hblank_n,
    input  logic [ 7:0] vpos,
    input  logic [ 8:0] hpos,

    // Handshake: top-level pulses start to trigger line-buffer fill.
    input  logic        start,

    // VRAM async read port (combinational)
    output logic [14:0] vram_rd_addr,
    input  logic [15:0] vram_q,
    output logic        vram_rd,
    input  logic        vram_ok,

    // Scroll RAM async read port (combinational)
    output logic [ 9:0] scroll_rd_addr,
    // scroll_q[15:10] not used: scroll values are 10-bit pixel offsets
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [15:0] scroll_q,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        scroll_rd,
    input  logic        scroll_ok,

    // Control fields
    // bank[3] not used: VRAM is 32K words (15-bit), max bank offset is bank[2:0]<<12
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [ 3:0] bank0,   // tile-code VRAM bank (base = bank0 << 12)
    input  logic [ 3:0] bank1,   // attr VRAM bank      (base = bank1 << 12)
    /* verilator lint_on UNUSEDSIGNAL */

    // Lines-per-scroll-block control byte (ctrl[2] high byte for FG, ctrl[3] for BG)
    // lpb = 256 - lpb_ctrl;  lpb_ctrl=0 → lpb=256 (one global block, backward compat)
    input  logic [ 7:0] lpb_ctrl,

    // GFX ROM
    output logic [22:0] gfx_addr,
    input  logic [ 7:0] gfx_data,
    output logic        gfx_rd,
    input  logic        gfx_ok,

    // Pixel output (async read from line buffer)
    output logic [ 9:0] layer_pixel
);

// =============================================================================
// FSM states
// =============================================================================
typedef enum logic [3:0] {
    BG_IDLE = 4'd0,
    BG_SX   = 4'd1,   // latch scrollX
    BG_SYRD = 4'd2,   // latch scrollY
    BG_INIT = 4'd3,   // compute fetch geometry
    BG_CODE = 4'd4,   // latch tile code from VRAM
    BG_ATTR = 4'd5,   // latch attr; compute + latch gfx base addresses
    BG_GFX0 = 4'd6,   // latch plane0 left half
    BG_GFX1 = 4'd7,   // latch plane1 left half
    BG_GFX2 = 4'd8,   // latch plane2 left half
    BG_GFX3 = 4'd9,   // plane3 left; decode 8 left pixels into packed register
    BG_GFX4 = 4'd10,  // latch plane0 right half
    BG_GFX5 = 4'd11,  // latch plane1 right half
    BG_GFX6 = 4'd12,  // latch plane2 right half
    BG_GFX7 = 4'd13   // plane3 right; write packed tile word; advance
} bg_state_t;

bg_state_t   state;
logic [4:0]  tile_col;   // tile column counter, 0..21

// =============================================================================
// Scroll RAM base offset for this plane
// PLANE=0 (FG): words 0x000-0x1FF;  PLANE=1 (BG): words 0x200-0x3FF
// =============================================================================
localparam logic [9:0] SCROLL_BASE = (PLANE == 1) ? 10'h200 : 10'h000;

// =============================================================================
// Per-block scroll address computation (combinational)
//
// lpb  = 256 - lpb_ctrl  (9-bit to avoid overflow when lpb_ctrl=0 → result=256)
// fetch_vpos = vpos + 1  (next scanline, matches BG_INIT canvas_y computation)
// block      = fetch_vpos / lpb
// scroll_off = block * 2 * lpb  (word offset within the plane's scroll region)
//
// Division by lpb: synthesizes a divider in Quartus; fine for this chip.
// lpb is guaranteed 1..256, so the 9-bit quotient fits in 8 bits (max=255).
// =============================================================================
logic [8:0] lpb_c;           // lines per block, 9-bit (256 when lpb_ctrl=0)
logic [8:0] fetch_vpos_c;    // vpos+1, 9-bit (max 256 wraps mod 256)
logic [8:0] block_c;         // scroll block index for this scanline
logic [9:0] scroll_off_c;    // word offset from SCROLL_BASE: block * 2 * lpb

always_comb begin
    lpb_c        = 9'(256) - {1'b0, lpb_ctrl};       // 9-bit; 256-0=256, 256-255=1
    fetch_vpos_c = {1'b0, vpos} + 9'd1;               // next scanline, 9-bit
    block_c      = fetch_vpos_c / lpb_c;              // division; result ≤ 255
    scroll_off_c = block_c * {lpb_c, 1'b0};           // block * 2 * lpb, keep width explicit
end

// =============================================================================
// Scroll registers
// =============================================================================
logic [ 3:0] scroll_x_frac_r;  // scrollX[3:0]: pixel offset within first tile
logic [ 5:0] scroll_x_tile_r;  // scrollX[9:4]: first tile column in map (mod 64)
logic [ 9:0] scroll_y_r;       // full scrollY

// =============================================================================
// Fetch geometry (computed in BG_INIT)
// =============================================================================
logic [3:0] fetch_py;           // pixel row within 16-px tile (0..15)
logic [5:0] fetch_ty;           // tile row in 64×64 map (0..63)
logic [5:0] first_tile_col_r;   // first tile column: scrollX[9:4] mod 64

// Current tile column in map (combinational)
logic [5:0] cur_map_col_c;
assign cur_map_col_c = (first_tile_col_r + {1'b0, tile_col}) & 6'h3F;

// =============================================================================
// Tile data registers
// =============================================================================
logic [14:0] tile_code_r;
logic [ 5:0] tile_color_r;
logic        tile_flipx_r;

// GFX char-block base addresses (latched in BG_ATTR)
logic [22:0] gfx_base_l_r;     // char-block base for screen-left 8 pixels
logic [22:0] gfx_base_r_r;     // char-block base for screen-right 8 pixels

// GFX plane bytes
logic [7:0]  gfx_b0_r;         // plane0 left
logic [7:0]  gfx_b1_r;         // plane1 left
logic [7:0]  gfx_b2_r;         // plane2 left
logic [7:0]  gfx_r0_r;         // plane0 right
logic [7:0]  gfx_r1_r;         // plane1 right
logic [7:0]  gfx_r2_r;         // plane2 right

// Left-half decoded pixels packed as 8 × 10-bit entries.
logic [79:0] left_pack_r;

// =============================================================================
// Combinational: attr decode (valid during BG_ATTR state)
// =============================================================================
logic [5:0]  attr_color_c;
logic        attr_flipx_c;
logic        attr_flipy_c;
assign attr_color_c = vram_q[5:0];
assign attr_flipx_c = vram_q[14];
assign attr_flipy_c = vram_q[15];

// =============================================================================
// Combinational: GFX base addresses
// Uses tile_code_r (latched in BG_CODE) and attr_flipy_c (new, from current vram_q).
// These are used in BG_ATTR to latch gfx_base_l/r_r.
// =============================================================================
logic [3:0]  py_eff_c;
logic [2:0]  char_row_c;
logic        tile_row_c;

// py_eff: apply flipY using the NEW attr_flipy_c (not registered tile_flipy_r)
assign py_eff_c   = attr_flipy_c ? (4'd15 - fetch_py) : fetch_py;
assign char_row_c = py_eff_c[2:0];
assign tile_row_c = py_eff_c[3];

// GFX char-block bases (23-bit addresses):
//   tile_code * 128 = {tile_code, 7'b0} (15+7 = 22 bits → need 23: prepend 1'b0)
//   Top-left  block (0): base + char_row*2
//   Top-right block (1): base + 32 + char_row*2
//   Bot-left  block (2): base + 64 + char_row*2
//   Bot-right block (3): base + 96 + char_row*2
logic [22:0] gfx_tile_base_c;    // tile_code * 128 (zero-extended to 23 bits)
logic [22:0] gfx_cb_left_c;      // char-block for this tile row, left column
logic [22:0] gfx_cb_right_c;     // char-block for this tile row, right column
logic [22:0] gfx_screen_left_c;  // screen-left char-block (after flipX swap)
logic [22:0] gfx_screen_right_c; // screen-right char-block

assign gfx_tile_base_c = {1'b0, tile_code_r, 7'b0};           // *128, 23-bit

always_comb begin
    // Select left/right char-blocks based on which row half (top=0, bottom=1)
    // char_row*2 offset within the char-block:
    logic [22:0] top_left_c, top_right_c, bot_left_c, bot_right_c;
    logic [22:0] cr2;
    cr2 = {19'b0, char_row_c, 1'b0};   // char_row * 2, 23-bit zero-extended (19+3+1=23)
    top_left_c  = gfx_tile_base_c + cr2;
    top_right_c = gfx_tile_base_c + 23'd32  + cr2;
    bot_left_c  = gfx_tile_base_c + 23'd64  + cr2;
    bot_right_c = gfx_tile_base_c + 23'd96  + cr2;

    gfx_cb_left_c  = tile_row_c ? bot_left_c  : top_left_c;
    gfx_cb_right_c = tile_row_c ? bot_right_c : top_right_c;

    // flipX: swap left/right char-blocks
    if (attr_flipx_c) begin
        gfx_screen_left_c  = gfx_cb_right_c;
        gfx_screen_right_c = gfx_cb_left_c;
    end else begin
        gfx_screen_left_c  = gfx_cb_left_c;
        gfx_screen_right_c = gfx_cb_right_c;
    end
end

// =============================================================================
// VRAM address (combinational, state-dependent)
// Address = bank << 12 | tile_map_idx  (15-bit: bank[2:0] || tile_map_idx[11:0])
// tile_map_idx = {fetch_ty[5:0], cur_map_col_c[5:0]} (12 bits = ty*64 + tx)
// =============================================================================
logic [11:0] tile_map_idx_c;
assign tile_map_idx_c = {fetch_ty, cur_map_col_c};  // 6+6 = 12 bits

always_comb begin
    case (state)
        BG_CODE: vram_rd_addr = {bank0[2:0], tile_map_idx_c};
        BG_ATTR: vram_rd_addr = {bank1[2:0], tile_map_idx_c};
        default: vram_rd_addr = 15'b0;
    endcase
end

assign vram_rd = (state == BG_CODE) || (state == BG_ATTR);

// =============================================================================
// Scroll RAM address (combinational, state-dependent)
// Uses scroll_off_c (computed from lpb_ctrl and vpos) to select the correct
// scroll block for this scanline.
// =============================================================================
always_comb begin
    case (state)
        BG_SX:   scroll_rd_addr = SCROLL_BASE + scroll_off_c;          // scrollX for this block
        BG_SYRD: scroll_rd_addr = SCROLL_BASE + scroll_off_c + 10'd1;  // scrollY for this block
        default: scroll_rd_addr = 10'b0;
    endcase
end

assign scroll_rd = (state == BG_SX) || (state == BG_SYRD);

// =============================================================================
// GFX ROM address (combinational, state-dependent)
// Within each char-block:
//   byte 0  = plane0 (gfx_base + 0)
//   byte 1  = plane1 (gfx_base + 1)
//   byte 16 = plane2 (gfx_base + 16)
//   byte 17 = plane3 (gfx_base + 17)
// =============================================================================
always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 23'b0;
    case (state)
        BG_GFX0: begin gfx_addr = gfx_base_l_r;          gfx_rd = 1'b1; end
        BG_GFX1: begin gfx_addr = gfx_base_l_r + 23'd1;  gfx_rd = 1'b1; end
        BG_GFX2: begin gfx_addr = gfx_base_l_r + 23'd16; gfx_rd = 1'b1; end
        BG_GFX3: begin gfx_addr = gfx_base_l_r + 23'd17; gfx_rd = 1'b1; end
        BG_GFX4: begin gfx_addr = gfx_base_r_r;          gfx_rd = 1'b1; end
        BG_GFX5: begin gfx_addr = gfx_base_r_r + 23'd1;  gfx_rd = 1'b1; end
        BG_GFX6: begin gfx_addr = gfx_base_r_r + 23'd16; gfx_rd = 1'b1; end
        BG_GFX7: begin gfx_addr = gfx_base_r_r + 23'd17; gfx_rd = 1'b1; end
        default: begin gfx_addr = 23'b0;                 gfx_rd = 1'b0; end
    endcase
end

// =============================================================================
// Tile line buffer: 32 × 160-bit
// One packed 16-pixel word per tile. This keeps writes single-address and lets
// Quartus map the storage into RAM instead of 16 parallel FF write ports.
// =============================================================================
logic [159:0] tilebuf_wdata;
logic [159:0] tilebuf_rdata;
logic [4:0]   tilebuf_raddr;
logic [8:0]   read_idx_c;
logic         tilebuf_we;

assign read_idx_c   = (9'(hpos) + {5'b0, scroll_x_frac_r}) & 9'h1FF;
assign tilebuf_raddr = read_idx_c[8:4];
assign tilebuf_we    = (state == BG_GFX7) && gfx_ok;

always_comb begin
    logic [79:0] right_pack_c;
    right_pack_c = '0;
    for (int px = 0; px < 8; px++) begin
        logic [2:0] b;
        b = tile_flipx_r ? 3'(px) : 3'(7 - px);
        right_pack_c[px*10 +: 10] = {
            tile_color_r,
            gfx_data[b],
            gfx_r2_r[b],
            gfx_r1_r[b],
            gfx_r0_r[b]
        };
    end
    tilebuf_wdata = {right_pack_c, left_pack_r};
end

`ifdef QUARTUS
altsyncram #(
    .width_a            (160),
    .widthad_a          (5),
    .numwords_a         (32),
    .width_b            (160),
    .widthad_b          (5),
    .numwords_b         (32),
    .operation_mode     ("DUAL_PORT"),
    .ram_block_type     ("M10K"),
    .outdata_reg_a      ("UNREGISTERED"),
    .outdata_reg_b      ("UNREGISTERED"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .intended_device_family ("Cyclone V")
) u_tilebuf (
    .clock0    (clk),
    .address_a (tile_col),
    .data_a    (tilebuf_wdata),
    .wren_a    (tilebuf_we),
    .address_b (tilebuf_raddr),
    .q_b       (tilebuf_rdata),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({160{1'b0}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
    .wren_b(1'b0)
);
`else
logic [159:0] tilebuf [0:31];
always_ff @(posedge clk) begin
    if (tilebuf_we) tilebuf[tile_col] <= tilebuf_wdata;
end
assign tilebuf_rdata = tilebuf[tilebuf_raddr];
`endif

always_comb begin
    if (tilebuf_raddr >= 5'd22) begin
        layer_pixel = 10'b0;
    end else begin
        case (read_idx_c[3:0])
            4'd0: layer_pixel = tilebuf_rdata[  9:  0];
            4'd1: layer_pixel = tilebuf_rdata[ 19: 10];
            4'd2: layer_pixel = tilebuf_rdata[ 29: 20];
            4'd3: layer_pixel = tilebuf_rdata[ 39: 30];
            4'd4: layer_pixel = tilebuf_rdata[ 49: 40];
            4'd5: layer_pixel = tilebuf_rdata[ 59: 50];
            4'd6: layer_pixel = tilebuf_rdata[ 69: 60];
            4'd7: layer_pixel = tilebuf_rdata[ 79: 70];
            4'd8: layer_pixel = tilebuf_rdata[ 89: 80];
            4'd9: layer_pixel = tilebuf_rdata[ 99: 90];
            4'd10: layer_pixel = tilebuf_rdata[109:100];
            4'd11: layer_pixel = tilebuf_rdata[119:110];
            4'd12: layer_pixel = tilebuf_rdata[129:120];
            4'd13: layer_pixel = tilebuf_rdata[139:130];
            4'd14: layer_pixel = tilebuf_rdata[149:140];
            default: layer_pixel = tilebuf_rdata[159:150];
        endcase
    end
end

// =============================================================================
// FSM + register updates + line buffer writes
// =============================================================================
// Suppress hblank_n unused — the signal is an input used by the parent for
// sequencing but not consumed directly by this module's FSM (start pulse is used).
/* verilator lint_off UNUSEDSIGNAL */
logic _hblank_unused;
assign _hblank_unused = hblank_n;
/* verilator lint_on UNUSEDSIGNAL */

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state            <= BG_IDLE;
        tile_col         <= 5'b0;
        scroll_x_frac_r  <= 4'b0;
        scroll_x_tile_r  <= 6'b0;
        scroll_y_r       <= 10'b0;
        fetch_py         <= 4'b0;
        fetch_ty         <= 6'b0;
        first_tile_col_r <= 6'b0;
        tile_code_r      <= 15'b0;
        tile_color_r     <= 6'b0;
        tile_flipx_r     <= 1'b0;
        gfx_base_l_r     <= 23'b0;
        gfx_base_r_r     <= 23'b0;
        gfx_b0_r         <= 8'b0;
        gfx_b1_r         <= 8'b0;
        gfx_b2_r         <= 8'b0;
        gfx_r0_r         <= 8'b0;
        gfx_r1_r         <= 8'b0;
        gfx_r2_r         <= 8'b0;
        left_pack_r      <= '0;
    end else begin
        case (state)

            // ── Idle ─────────────────────────────────────────────────────────
            // On start pulse: move to BG_SX and request the first scroll word.
            BG_IDLE: begin
                if (start) begin
                    state <= BG_SX;
                end
            end

            BG_SX: begin
                if (scroll_ok) begin
                    scroll_x_frac_r  <= scroll_q[3:0];
                    scroll_x_tile_r  <= scroll_q[9:4];
                    state            <= BG_SYRD;
                end
            end

            BG_SYRD: begin
                if (scroll_ok) begin
                    scroll_y_r <= scroll_q[9:0];
                    state      <= BG_INIT;
                end
            end

            // ── Compute fetch geometry ────────────────────────────────────────
            BG_INIT: begin
                begin
                    // canvas_y = (vpos+1 + scrollY) & 0x3FF
                    logic [9:0] canvas_y;
                    canvas_y         = (10'(vpos) + 10'd1 + scroll_y_r) & 10'h3FF;
                    fetch_py         <= canvas_y[3:0];
                    fetch_ty         <= canvas_y[9:4] & 6'h3F;
                end
                first_tile_col_r <= scroll_x_tile_r & 6'h3F;
                tile_col         <= 5'b0;
                state            <= BG_CODE;
            end

            // ── Per-tile fetch loop ──────────────────────────────────────────

            BG_CODE: begin
                if (vram_ok) begin
                    tile_code_r <= vram_q[14:0];
                    state       <= BG_ATTR;
                end
            end

            BG_ATTR: begin
                if (vram_ok) begin
                    tile_color_r <= attr_color_c;
                    tile_flipx_r <= attr_flipx_c;
                    // gfx_screen_left/right_c are combinational from tile_code_r
                    // and attr_flipx/y_c (current vram_q).
                    gfx_base_l_r <= gfx_screen_left_c;
                    gfx_base_r_r <= gfx_screen_right_c;
                    state        <= BG_GFX0;
                end
            end

            BG_GFX0: begin
                if (gfx_ok) begin
                    gfx_b0_r <= gfx_data;
                    state    <= BG_GFX1;
                end
            end
            BG_GFX1: begin
                if (gfx_ok) begin
                    gfx_b1_r <= gfx_data;
                    state    <= BG_GFX2;
                end
            end
            BG_GFX2: begin
                if (gfx_ok) begin
                    gfx_b2_r <= gfx_data;
                    state    <= BG_GFX3;
                end
            end

            BG_GFX3: begin
                if (gfx_ok) begin
                    // plane3 left = gfx_data; decode 8 left-half pixels
                    for (int px = 0; px < 8; px++) begin
                        logic [2:0] b;
                        b = tile_flipx_r ? 3'(px) : 3'(7 - px);
                        left_pack_r[px*10 +: 10] <= {
                            tile_color_r,
                            gfx_data[b],
                            gfx_b2_r[b],
                            gfx_b1_r[b],
                            gfx_b0_r[b]
                        };
                    end
                    state <= BG_GFX4;
                end
            end

            BG_GFX4: begin
                if (gfx_ok) begin
                    gfx_r0_r <= gfx_data;
                    state    <= BG_GFX5;
                end
            end
            BG_GFX5: begin
                if (gfx_ok) begin
                    gfx_r1_r <= gfx_data;
                    state    <= BG_GFX6;
                end
            end
            BG_GFX6: begin
                if (gfx_ok) begin
                    gfx_r2_r <= gfx_data;
                    state    <= BG_GFX7;
                end
            end

            BG_GFX7: begin
                if (gfx_ok) begin
                    if (tile_col == 5'd21) begin
                        state <= BG_IDLE;
                    end else begin
                        tile_col <= tile_col + 5'd1;
                        state    <= BG_CODE;
                    end
                end
            end

            default: state <= BG_IDLE;
        endcase
    end
end

endmodule
