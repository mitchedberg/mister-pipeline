`default_nettype none
// =============================================================================
// TC0180VCU — Sprite Engine (Step 6: zoomed + unzoomed, non-big-sprite)
// =============================================================================
// Renders all 408 sprite entries into the framebuffer during VBLANK.
// Processes sprites in REVERSE RAM order (sprite 407 first → lowest priority,
// sprite 0 last → highest priority, drawn on top).
//
// Sprite RAM format (8 words per sprite):
//   Word +0: tile_code[14:0]
//   Word +1: [5:0]=color, [14]=flipX, [15]=flipY
//   Word +2: x[9:0] signed
//   Word +3: y[9:0] signed
//   Word +4: zoom [15:8]=xzoom, [7:0]=yzoom  (0x00 = unzoomed, 0xFF = invisible)
//   Word +5: big sprite [15:8]=x_count-1, [7:0]=y_count-1  (0 = single tile)
//
// Zoom encoding:
//   zx = (0x100 - zoomx) / 16   (rendered tile width  0..16 screen pixels)
//   zy = (0x100 - zoomy) / 16   (rendered tile height 0..16 screen pixels)
//   When zx==0 or zy==0: sprite invisible (skip)
//   When zx==16, zy==16: full size (same as unzoomed)
//
// Nearest-neighbor zoom: for output pixel (sx, sy):
//   src_x = sx * 16 / zx,  src_y = sy * 16 / zy
//
// GFX ROM format for 16×16 sprite tiles (128 bytes/tile):
//   4 char-blocks 2×2:  block0=top-left, block1=top-right,
//                       block2=bot-left, block3=bot-right
//   char_base = tile_code*128 + block*32
//   plane0 = gfx[char_base + row*2 + 0], plane1 = gfx[char_base + row*2 + 1]
//   plane2 = gfx[char_base + 16  + row*2 + 0]
//   plane3 = gfx[char_base + 16  + row*2 + 1]
//   pixel_idx = {p3[7-lx], p2[7-lx], p1[7-lx], p0[7-lx]}
//
// Framebuffer pixel encoding (MAME draw_sprites reference):
//   fb_pixel = color<<2 | (pixel_idx & 3)   (only lower 2 bits of 4-bit index)
//   pixel_idx==0 → transparent (skip write)
//
// NOTE: FPGA synthesis will need SDRAM burst fetching for GFX ROM to meet
// VBLANK timing at 13.333 MHz (408 sprites × ~400 cycles >> ~9500 VBLANK cycles).
// For Verilator simulation the testbench drives vblank_n=0 for enough cycles.
// =============================================================================

module tc0180vcu_sprite (
    input  logic        clk,
    input  logic        rst_n,

    // Timing — sprite rendering runs while vblank_n=0
    input  logic        vblank_n,

    // Sprite RAM read port (async word-addressed, 0..3263 = 408 sprites × 8 words)
    output logic [11:0] spr_rd_addr,
    input  logic [15:0] spr_q,

    // GFX ROM
    output logic [22:0] gfx_addr,
    input  logic [ 7:0] gfx_data,
    output logic        gfx_rd,

    // Framebuffer write port
    output logic        fb_wr,
    output logic [ 8:0] fb_wx,
    output logic [ 7:0] fb_wy,
    output logic [ 7:0] fb_wdata,

    // Framebuffer erase: pulse for one cycle to request full-page clear
    output logic        fb_erase,

    // Control
    input  logic        no_erase,  // VIDEO_CTRL[0]: 1 = skip erase
    input  logic [ 7:0] video_ctrl // for future use
);

// =============================================================================
// FSM states
// =============================================================================
typedef enum logic [4:0] {
    SP_IDLE   = 5'd0,
    SP_ERASE  = 5'd1,   // pulse fb_erase for one cycle
    SP_LOAD0  = 5'd2,   // read word+0 (tile_code)
    SP_LOAD1  = 5'd3,   // read word+1 (attr)
    SP_LOAD2  = 5'd4,   // read word+2 (x)
    SP_LOAD3  = 5'd5,   // read word+3 (y)
    SP_LOAD4  = 5'd6,   // read word+4 (zoom)
    SP_LOAD5  = 5'd7,   // read word+5 (big)
    SP_CHECK  = 5'd8,   // skip big sprites; skip invisible (zx=0 or zy=0)
    SP_ROWL0  = 5'd9,   // fetch plane0 left half for src_y row
    SP_ROWL1  = 5'd10,  // fetch plane1 left half
    SP_ROWL2  = 5'd11,  // fetch plane2 left half
    SP_ROWL3  = 5'd12,  // fetch plane3 left; latch row base coords
    SP_ROWR0  = 5'd13,  // fetch plane0 right half
    SP_ROWR1  = 5'd14,  // fetch plane1 right half
    SP_ROWR2  = 5'd15,  // fetch plane2 right half
    SP_ROWR3  = 5'd16,  // fetch plane3 right
    SP_WRTZ   = 5'd17,  // write output pixels sx=0..zx-1 (one per cycle)
    SP_NEXTROW= 5'd19,  // advance to next output row or next sprite
    SP_DONE   = 5'd20   // idle until next VBLANK
} sp_state_t;

sp_state_t state;

// =============================================================================
// VBLANK edge detect
// =============================================================================
logic vblank_n_prev;
always_ff @(posedge clk) begin
    if (!rst_n) vblank_n_prev <= 1'b1;
    else        vblank_n_prev <= vblank_n;
end
logic vblank_fall;
assign vblank_fall = ~vblank_n & vblank_n_prev;

// =============================================================================
// Sprite counters
//   sprite_idx : 0..407 (we process 407 down to 0)
//   sy_idx     : output row 0..zy-1  (≤15)
//   sx_idx     : output column counter 0..zx-1 (≤15, used in SP_WRTZ)
// =============================================================================
logic [8:0]  sprite_idx;
logic [3:0]  sy_idx;     // output row index, 0..zy-1
logic [3:0]  sx_idx;     // output col index, 0..zx-1

// =============================================================================
// Latched sprite fields
// =============================================================================
logic [14:0] tile_code_r;
logic [ 5:0] color_r;
logic        flipx_r;
logic        flipy_r;
/* verilator lint_off UNUSEDSIGNAL */
logic [ 9:0] x_r;           // signed 10-bit position
logic [ 9:0] y_r;
/* verilator lint_on UNUSEDSIGNAL */
logic [ 7:0] zoomx_r;
logic [ 7:0] zoomy_r;
logic [15:0] big_r;

// Computed tile render dimensions (registered on SP_CHECK → SP_ROWL0)
// zx = (256 - zoomx) / 16,  zy = (256 - zoomy) / 16
logic [4:0] zx_r;   // 0..16
logic [4:0] zy_r;   // 0..16

// =============================================================================
// Zoom dimension computation (combinational)
// (9'(256) - {1'b0, zoomx}) >> 4 = (9'd256 - {1'b0,zoomx}) / 16
// Result fits in 5 bits: max = (256-0)/16 = 16.
// =============================================================================
logic [4:0] zx_c;
logic [4:0] zy_c;
always_comb begin
    zx_c = 5'((9'd256 - {1'b0, zoomx_r}) >> 4);
    zy_c = 5'((9'd256 - {1'b0, zoomy_r}) >> 4);
end

// =============================================================================
// Source pixel coordinates for the current output pixel (combinational)
// src_y = sy_idx * 16 / zy_r  → 4-bit (0..15)
// src_x = sx_idx * 16 / zx_r  → 4-bit (0..15)
// For the full-size degenerate case (zx=16, zy=16):
//   src_y = sy_idx, src_x = sx_idx  (identity mapping)
// Division is safe in simulation (Verilator); for synthesis these become LUTs.
// =============================================================================
logic [3:0] src_y_c;
logic [3:0] src_x_c;
always_comb begin : src_coord_gen
    // Guard against divide-by-zero (SP_CHECK ensures zy_r,zx_r != 0 before use)
    // Use 9-bit intermediate to prevent truncation of sy_idx*16 or sx_idx*16.
    // Max value: 15*16 = 240 < 256, fits in 8 bits, 9 used for safety.
    logic [8:0] sy_scaled;
    logic [8:0] sx_scaled;
    sy_scaled = {5'b0, sy_idx} * 9'd16;
    sx_scaled = {5'b0, sx_idx} * 9'd16;
    if (zy_r == 5'd0) src_y_c = 4'd0;
    else              src_y_c = 4'(sy_scaled / {4'b0, zy_r});
    if (zx_r == 5'd0) src_x_c = 4'd0;
    else              src_x_c = 4'(sx_scaled / {4'b0, zx_r});
end

// =============================================================================
// GFX ROM address computation (combinational, based on src_y)
// =============================================================================
logic [ 2:0] char_row_c;    // row within 8-px char block (0..7), from src_y
logic        tile_row_c;    // 0=top half, 1=bottom half, from src_y
logic [22:0] gfx_tile_base_c;
logic [22:0] gfx_cb_tl_c;  // top-left char block base
logic [22:0] gfx_cb_tr_c;  // top-right
logic [22:0] gfx_cb_bl_c;  // bot-left
logic [22:0] gfx_cb_br_c;  // bot-right
logic [22:0] gfx_cb_l_c;   // left screen half char block base  (after flipX)
logic [22:0] gfx_cb_r_c;   // right screen half char block base (after flipX)

always_comb begin
    logic [3:0] py_eff;
    py_eff          = flipy_r ? (4'd15 - src_y_c) : src_y_c;
    char_row_c      = py_eff[2:0];
    tile_row_c      = py_eff[3];
    gfx_tile_base_c = {1'b0, tile_code_r, 7'b0};  // tile_code * 128

    begin
        logic [22:0] cr2;
        cr2 = {19'b0, char_row_c, 1'b0};  // char_row * 2
        gfx_cb_tl_c = gfx_tile_base_c + cr2;
        gfx_cb_tr_c = gfx_tile_base_c + 23'd32  + cr2;
        gfx_cb_bl_c = gfx_tile_base_c + 23'd64  + cr2;
        gfx_cb_br_c = gfx_tile_base_c + 23'd96  + cr2;
    end

    if (tile_row_c) begin
        gfx_cb_l_c = flipx_r ? gfx_cb_br_c : gfx_cb_bl_c;
        gfx_cb_r_c = flipx_r ? gfx_cb_bl_c : gfx_cb_br_c;
    end else begin
        gfx_cb_l_c = flipx_r ? gfx_cb_tr_c : gfx_cb_tl_c;
        gfx_cb_r_c = flipx_r ? gfx_cb_tl_c : gfx_cb_tr_c;
    end
end

// =============================================================================
// Sprite RAM word address
// =============================================================================
logic [11:0] spr_base_c;
logic [ 2:0] spr_word_offset_c;

always_comb begin
    spr_base_c = (12'd407 - {3'b0, sprite_idx}) << 3;
    unique case (state)
        SP_LOAD0: spr_word_offset_c = 3'd0;
        SP_LOAD1: spr_word_offset_c = 3'd1;
        SP_LOAD2: spr_word_offset_c = 3'd2;
        SP_LOAD3: spr_word_offset_c = 3'd3;
        SP_LOAD4: spr_word_offset_c = 3'd4;
        SP_LOAD5: spr_word_offset_c = 3'd5;
        default:  spr_word_offset_c = 3'd0;
    endcase
end

assign spr_rd_addr = spr_base_c + {9'b0, spr_word_offset_c};

// =============================================================================
// GFX ROM address and read-enable (combinational, state-dependent)
// =============================================================================
always_comb begin
    gfx_rd   = 1'b0;
    gfx_addr = 23'b0;
    unique case (state)
        SP_ROWL0: begin gfx_addr = gfx_cb_l_c;          gfx_rd = 1'b1; end
        SP_ROWL1: begin gfx_addr = gfx_cb_l_c + 23'd1;  gfx_rd = 1'b1; end
        SP_ROWL2: begin gfx_addr = gfx_cb_l_c + 23'd16; gfx_rd = 1'b1; end
        SP_ROWL3: begin gfx_addr = gfx_cb_l_c + 23'd17; gfx_rd = 1'b1; end
        SP_ROWR0: begin gfx_addr = gfx_cb_r_c;          gfx_rd = 1'b1; end
        SP_ROWR1: begin gfx_addr = gfx_cb_r_c + 23'd1;  gfx_rd = 1'b1; end
        SP_ROWR2: begin gfx_addr = gfx_cb_r_c + 23'd16; gfx_rd = 1'b1; end
        SP_ROWR3: begin gfx_addr = gfx_cb_r_c + 23'd17; gfx_rd = 1'b1; end
        default:  begin gfx_addr = 23'b0; gfx_rd = 1'b0; end
    endcase
end

// =============================================================================
// GFX decode registers — 8 bytes covering both halves of the src_y row
//   l0..l3 = left  char-block planes 0..3
//   r0..r3 = right char-block planes 0..3
// =============================================================================
logic [7:0] gfx_l0_r;
logic [7:0] gfx_l1_r;
logic [7:0] gfx_l2_r;
// gfx_l3 is captured in SP_ROWL3 directly from gfx_data
logic [7:0] gfx_l3_r;
logic [7:0] gfx_r0_r;
logic [7:0] gfx_r1_r;
logic [7:0] gfx_r2_r;
// gfx_r3 is captured in SP_ROWR3 directly from gfx_data
logic [7:0] gfx_r3_r;

// =============================================================================
// Pixel decode for the current output column (combinational)
// src_x selects which half (left: <8, right: >=8) and which bit within that half.
//
// Within the left half (src_x in 0..7):
//   local_x = src_x[2:0]
//   bit_pos = flipx ? local_x : (7 - local_x)
//   pixel from gfx_l3_r..gfx_l0_r
//
// Within the right half (src_x in 8..15):
//   local_x = src_x[2:0]
//   bit_pos = flipx ? local_x : (7 - local_x)
//   pixel from gfx_r3_r..gfx_r0_r
// =============================================================================
logic [7:0] cur_px_data_c;
always_comb begin
    logic [2:0] local_x;
    logic [2:0] bit_pos;
    logic [3:0] pidx;
    local_x = src_x_c[2:0];
    bit_pos = flipx_r ? local_x : (3'(7) - local_x);
    if (!src_x_c[3]) begin
        // Left half
        pidx = {gfx_l3_r[bit_pos], gfx_l2_r[bit_pos], gfx_l1_r[bit_pos], gfx_l0_r[bit_pos]};
    end else begin
        // Right half
        pidx = {gfx_r3_r[bit_pos], gfx_r2_r[bit_pos], gfx_r1_r[bit_pos], gfx_r0_r[bit_pos]};
    end
    if (pidx == 4'b0) cur_px_data_c = 8'b0;  // transparent
    else              cur_px_data_c = {color_r, pidx[1:0]};
end

// =============================================================================
// Framebuffer write port
//   fb_wx: 9-bit (sprite_x + sx_idx), wraps in 512-wide FB
//   fb_wy: 8-bit (sprite_y + sy_idx), wraps in 256-high FB
// Both base coords latched at SP_ROWL0.
// =============================================================================
logic [8:0] row_x_base_r;   // x_r[8:0] latched at row start
logic [7:0] row_y_r;        // y_r[7:0] + sy_idx latched at row start

assign fb_wr    = (state == SP_WRTZ && cur_px_data_c != 8'b0);
assign fb_wx    = row_x_base_r + {5'b0, sx_idx};
assign fb_wy    = row_y_r;
assign fb_wdata = cur_px_data_c;
assign fb_erase = (state == SP_ERASE);

// =============================================================================
// FSM
// =============================================================================
/* verilator lint_off UNUSEDSIGNAL */
logic _video_ctrl_unused;
assign _video_ctrl_unused = ^video_ctrl;
/* verilator lint_on UNUSEDSIGNAL */

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state        <= SP_IDLE;
        sprite_idx   <= 9'b0;
        sy_idx       <= 4'b0;
        sx_idx       <= 4'b0;
        tile_code_r  <= 15'b0;
        color_r      <= 6'b0;
        flipx_r      <= 1'b0;
        flipy_r      <= 1'b0;
        x_r          <= 10'b0;
        y_r          <= 10'b0;
        zoomx_r      <= 8'b0;
        zoomy_r      <= 8'b0;
        zx_r         <= 5'b0;
        zy_r         <= 5'b0;
        big_r        <= 16'b0;
        gfx_l0_r     <= 8'b0;
        gfx_l1_r     <= 8'b0;
        gfx_l2_r     <= 8'b0;
        gfx_l3_r     <= 8'b0;
        gfx_r0_r     <= 8'b0;
        gfx_r1_r     <= 8'b0;
        gfx_r2_r     <= 8'b0;
        gfx_r3_r     <= 8'b0;
        row_x_base_r <= 9'b0;
        row_y_r      <= 8'b0;
    end else begin
        unique case (state)

            // ── Idle: wait for VBLANK ────────────────────────────────────────
            SP_IDLE: begin
                if (vblank_fall) begin
                    sprite_idx <= 9'b0;
                    if (!no_erase) state <= SP_ERASE;
                    else           state <= SP_LOAD0;
                end
            end

            // ── Erase pulse ─────────────────────────────────────────────────
            SP_ERASE: begin
                state <= SP_LOAD0;
            end

            // ── Load sprite words ────────────────────────────────────────────
            SP_LOAD0: begin
                tile_code_r <= spr_q[14:0];
                state       <= SP_LOAD1;
            end

            SP_LOAD1: begin
                color_r <= spr_q[5:0];
                flipx_r <= spr_q[14];
                flipy_r <= spr_q[15];
                state   <= SP_LOAD2;
            end

            SP_LOAD2: begin
                x_r   <= spr_q[9:0];
                state <= SP_LOAD3;
            end

            SP_LOAD3: begin
                y_r   <= spr_q[9:0];
                state <= SP_LOAD4;
            end

            SP_LOAD4: begin
                zoomx_r <= spr_q[15:8];
                zoomy_r <= spr_q[ 7:0];
                state   <= SP_LOAD5;
            end

            SP_LOAD5: begin
                big_r <= spr_q;
                state <= SP_CHECK;
            end

            // ── Check: skip big sprites and invisible (zx=0 or zy=0) ────────
            SP_CHECK: begin
                // Compute and register tile dimensions
                zx_r <= zx_c;
                zy_r <= zy_c;

                if (big_r != 16'b0 || zx_c == 5'd0 || zy_c == 5'd0) begin
                    // Skip this sprite
                    if (sprite_idx == 9'd407) state <= SP_DONE;
                    else begin
                        sprite_idx <= sprite_idx + 9'd1;
                        state      <= SP_LOAD0;
                    end
                end else begin
                    sy_idx <= 4'b0;
                    state  <= SP_ROWL0;
                end
            end

            // ── Row render: latch base coords + fetch GFX bytes ──────────────
            // SP_ROWL0: latch row X/Y base, start GFX fetch (plane0 left)
            SP_ROWL0: begin
                // Latch row base coordinates at start of each output row.
                // fb_wy = y_r[7:0] + sy_idx (wrap at 256).
                row_x_base_r <= x_r[8:0];
                row_y_r      <= y_r[7:0] + {4'b0, sy_idx};
                gfx_l0_r     <= gfx_data;
                state        <= SP_ROWL1;
            end

            SP_ROWL1: begin gfx_l1_r <= gfx_data; state <= SP_ROWL2; end
            SP_ROWL2: begin gfx_l2_r <= gfx_data; state <= SP_ROWL3; end
            SP_ROWL3: begin gfx_l3_r <= gfx_data; state <= SP_ROWR0; end

            SP_ROWR0: begin gfx_r0_r <= gfx_data; state <= SP_ROWR1; end
            SP_ROWR1: begin gfx_r1_r <= gfx_data; state <= SP_ROWR2; end
            SP_ROWR2: begin gfx_r2_r <= gfx_data; state <= SP_ROWR3; end

            SP_ROWR3: begin
                gfx_r3_r <= gfx_data;
                sx_idx   <= 4'b0;
                state    <= SP_WRTZ;
            end

            // ── Write output pixels: sx=0..zx-1, one per cycle ───────────────
            // fb_wx = row_x_base_r + sx_idx  (9-bit, wraps in 512-wide FB)
            // fb_wy = row_y_r                (8-bit, already set at row start)
            // fb_wr fires when cur_px_data_c != 0 (non-transparent)
            SP_WRTZ: begin
                if (sx_idx == zx_r[3:0] - 4'd1) begin
                    // Last output column of this row → go to next row
                    state <= SP_NEXTROW;
                end else begin
                    sx_idx <= sx_idx + 4'd1;
                end
            end

            // ── Advance to next row or next sprite ───────────────────────────
            SP_NEXTROW: begin
                if (sy_idx == zy_r[3:0] - 4'd1) begin
                    // Done with this sprite
                    if (sprite_idx == 9'd407) begin
                        state <= SP_DONE;
                    end else begin
                        sprite_idx <= sprite_idx + 9'd1;
                        state      <= SP_LOAD0;
                    end
                end else begin
                    sy_idx <= sy_idx + 4'd1;
                    state  <= SP_ROWL0;
                end
            end

            // ── Done: stay idle until VBLANK ends ────────────────────────────
            SP_DONE: begin
                if (vblank_n) state <= SP_IDLE;
            end

            default: state <= SP_IDLE;
        endcase
    end
end

endmodule
