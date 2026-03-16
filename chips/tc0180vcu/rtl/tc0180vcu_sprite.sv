`default_nettype none
// =============================================================================
// TC0180VCU — Sprite Engine (Step 5: unzoomed, non-big-sprite)
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
//   Word +4: zoom [15:8]=xzoom, [7:0]=yzoom  (0x00 = unzoomed)
//   Word +5: big sprite [15:8]=x_count-1, [7:0]=y_count-1  (0 = single tile)
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
    SP_CHECK  = 5'd8,   // skip if zoomed or big
    SP_ROWL0  = 5'd9,   // fetch plane0 left half
    SP_ROWL1  = 5'd10,  // fetch plane1 left half
    SP_ROWL2  = 5'd11,  // fetch plane2 left half
    SP_ROWL3  = 5'd12,  // fetch plane3 left; decode left 8 pixels
    SP_ROWR0  = 5'd13,  // fetch plane0 right half
    SP_ROWR1  = 5'd14,  // fetch plane1 right half
    SP_ROWR2  = 5'd15,  // fetch plane2 right half
    SP_ROWR3  = 5'd16,  // fetch plane3 right; decode + write right 8 pixels
    SP_WRTL   = 5'd17,  // write left 8 pixels to framebuffer (sub-counter)
    SP_WRTR   = 5'd18,  // write right 8 pixels to framebuffer (sub-counter)
    SP_NEXTROW= 5'd19,  // advance to next row or next sprite
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
// sprite_idx: 0..407 (we process 407 down to 0)
// row_idx:    0..15  (pixel row within 16×16 tile)
// px_idx:     0..7   (pixel within write-out sub-state)
// =============================================================================
logic [8:0]  sprite_idx;     // 0..407 (counts UP but represents 407-down-to-0)
logic [3:0]  row_idx;        // pixel row 0..15 within tile
logic [2:0]  px_idx;         // write-out sub-counter 0..7

// =============================================================================
// Latched sprite fields
// =============================================================================
logic [14:0] tile_code_r;
logic [ 5:0] color_r;
logic        flipx_r;
logic        flipy_r;
// x_r[9] and y_r[9:8] are the sign/upper bits used for clipping (future step).
// For step 5 only lower bits are used for FB addressing; suppress the warning.
/* verilator lint_off UNUSEDSIGNAL */
logic [ 9:0] x_r;           // signed 10-bit position
logic [ 9:0] y_r;
/* verilator lint_on UNUSEDSIGNAL */
logic [ 7:0] zoomx_r;
logic [ 7:0] zoomy_r;
logic [15:0] big_r;

// =============================================================================
// GFX decode registers
// =============================================================================
logic [7:0] gfx_l0_r;  // plane0 left half
logic [7:0] gfx_l1_r;
logic [7:0] gfx_l2_r;
logic [7:0] gfx_r0_r;  // plane0 right half
logic [7:0] gfx_r1_r;
logic [7:0] gfx_r2_r;

// Decoded left/right pixel arrays (8 pixels each, 8-bit fb encoding)
// 0 = transparent, non-zero = {color[5:0], pix_idx[1:0]}
logic [7:0] left_px  [0:7];
logic [7:0] right_px [0:7];

// =============================================================================
// GFX ROM address computation (combinational)
// char_base = tile_code * 128 + char_block * 32
// Within char_block: plane0 = +row*2, plane1 = +row*2+1,
//                   plane2 = +16+row*2, plane3 = +16+row*2+1
// =============================================================================
logic [ 3:0] py_eff_c;      // effective pixel row (apply flipY)
logic [ 2:0] char_row_c;    // row within 8-px char block (0..7)
logic        tile_row_c;    // 0=top, 1=bottom half
logic [22:0] gfx_tile_base_c;
logic [22:0] gfx_cb_tl_c;  // top-left char block base
logic [22:0] gfx_cb_tr_c;  // top-right
logic [22:0] gfx_cb_bl_c;  // bot-left
logic [22:0] gfx_cb_br_c;  // bot-right
logic [22:0] gfx_cb_l_c;   // left screen half char block base
logic [22:0] gfx_cb_r_c;   // right screen half char block base

always_comb begin
    py_eff_c        = flipy_r ? (4'd15 - row_idx) : row_idx;
    char_row_c      = py_eff_c[2:0];
    tile_row_c      = py_eff_c[3];
    gfx_tile_base_c = {1'b0, tile_code_r, 7'b0};  // tile_code * 128

    begin
        logic [22:0] cr2;
        cr2 = {19'b0, char_row_c, 1'b0};   // char_row * 2
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
// Current sprite RAM word address:
//   sprite (407 - sprite_idx) * 8 + word_offset
// We process sprite_idx=0 → sprite 407, sprite_idx=407 → sprite 0.
// =============================================================================
logic [11:0] spr_base_c;
logic [ 2:0] spr_word_offset_c;

always_comb begin
    // sprite_idx counts 0..407; RAM sprite = 407 - sprite_idx
    // base word = (407 - sprite_idx) * 8
    // Use 12-bit arithmetic throughout to avoid width warnings.
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
        default: begin gfx_addr = 23'b0; gfx_rd = 1'b0; end
    endcase
end

// =============================================================================
// Pixel decode helper: compute fb_pixel for one pixel position
// bit_sel: bit index into plane byte (flipX determines direction)
// =============================================================================
function automatic logic [7:0] decode_pixel(
    input logic [5:0] color,
    input logic [7:0] p3, p2, p1, p0,
    input logic [2:0] bit_sel
);
    logic [3:0] pidx;
    pidx = {p3[bit_sel], p2[bit_sel], p1[bit_sel], p0[bit_sel]};
    if (pidx == 4'b0) return 8'b0;   // transparent
    return {color, pidx[1:0]};
endfunction

// =============================================================================
// Framebuffer write
// =============================================================================
// For write-out, compute FB coordinates per pixel (SP_WRTL / SP_WRTR).
// Screen x = row_x_base + px_offset (wraps at 9 bits within 512-wide FB).
// Screen y = row_y_r (latched at row start, already [7:0]).
// fb_wx = [8:0], fb_wy = [7:0].
logic        writing_right;   // 0 = writing left half, 1 = writing right half

// Latched at start of each row
logic [ 8:0] row_x_base_r;   // x_r[8:0] (9-bit, wraps in 512-wide FB)
logic [ 7:0] row_y_r;        // y_r[7:0] + row_idx (wraps in 256-high FB)

// Screen x for the current pixel (9-bit; overflows wrap naturally)
logic [8:0] px_screen_x_c;
always_comb begin
    if (writing_right)
        px_screen_x_c = row_x_base_r + {5'b0, 1'b1, px_idx};  // base + 8 + px_idx
    else
        px_screen_x_c = row_x_base_r + {6'b0, px_idx};         // base + px_idx
end

// Current pixel data from array
logic [7:0] cur_px_data_c;
always_comb begin
    if (writing_right) cur_px_data_c = right_px[px_idx];
    else               cur_px_data_c = left_px[px_idx];
end

assign fb_wr    = ((state == SP_WRTL || state == SP_WRTR) && cur_px_data_c != 8'b0);
assign fb_wx    = px_screen_x_c;
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
        row_idx      <= 4'b0;
        px_idx       <= 3'b0;
        writing_right<= 1'b0;
        tile_code_r  <= 15'b0;
        color_r      <= 6'b0;
        flipx_r      <= 1'b0;
        flipy_r      <= 1'b0;
        x_r          <= 10'b0;
        y_r          <= 10'b0;
        zoomx_r      <= 8'b0;
        zoomy_r      <= 8'b0;
        big_r        <= 16'b0;
        gfx_l0_r     <= 8'b0;
        gfx_l1_r     <= 8'b0;
        gfx_l2_r     <= 8'b0;
        gfx_r0_r     <= 8'b0;
        gfx_r1_r     <= 8'b0;
        gfx_r2_r     <= 8'b0;
        row_x_base_r <= 9'b0;
        row_y_r      <= 8'b0;
        for (int i = 0; i < 8; i++) begin
            left_px[i]  <= 8'b0;
            right_px[i] <= 8'b0;
        end
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
            // In each LOAD state the spr_rd_addr is combinationally driven
            // by state + sprite_idx → spr_q is available the same cycle
            // (async BRAM read in tc0180vcu.sv).
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

            // ── Check: skip zoomed or big sprites ───────────────────────────
            SP_CHECK: begin
                if (zoomx_r != 8'b0 || zoomy_r != 8'b0 || big_r != 16'b0) begin
                    // Skip this sprite
                    if (sprite_idx == 9'd407) state <= SP_DONE;
                    else begin
                        sprite_idx <= sprite_idx + 9'd1;
                        state      <= SP_LOAD0;
                    end
                end else begin
                    row_idx <= 4'b0;
                    state   <= SP_ROWL0;
                end
            end

            // ── Row render loop ──────────────────────────────────────────────
            // On entry to SP_ROWL0: latch row base coordinates
            SP_ROWL0: begin
                // Latch row base X and Y at the start of each row.
                // x_r/y_r are 10-bit signed; use lower bits for FB address wrap.
                // row_x_base_r: 9-bit (wraps in 512-wide FB).
                // row_y_r:      8-bit (wraps in 256-high FB) = y_r[7:0] + row_idx.
                row_x_base_r <= x_r[8:0];
                row_y_r      <= y_r[7:0] + {4'b0, row_idx};
                gfx_l0_r     <= gfx_data;
                state        <= SP_ROWL1;
            end

            SP_ROWL1: begin gfx_l1_r <= gfx_data; state <= SP_ROWL2; end
            SP_ROWL2: begin gfx_l2_r <= gfx_data; state <= SP_ROWL3; end

            SP_ROWL3: begin
                // plane3 left = gfx_data; decode 8 left pixels
                for (int px = 0; px < 8; px++) begin
                    automatic logic [2:0] b;
                    b = flipx_r ? 3'(px) : 3'(7 - px);
                    left_px[px] <= decode_pixel(color_r, gfx_data, gfx_l2_r,
                                                gfx_l1_r, gfx_l0_r, b);
                end
                state <= SP_ROWR0;
            end

            SP_ROWR0: begin gfx_r0_r <= gfx_data; state <= SP_ROWR1; end
            SP_ROWR1: begin gfx_r1_r <= gfx_data; state <= SP_ROWR2; end
            SP_ROWR2: begin gfx_r2_r <= gfx_data; state <= SP_ROWR3; end

            SP_ROWR3: begin
                // plane3 right = gfx_data; decode 8 right pixels
                for (int px = 0; px < 8; px++) begin
                    automatic logic [2:0] b;
                    b = flipx_r ? 3'(px) : 3'(7 - px);
                    right_px[px] <= decode_pixel(color_r, gfx_data, gfx_r2_r,
                                                 gfx_r1_r, gfx_r0_r, b);
                end
                px_idx        <= 3'b0;
                writing_right <= 1'b0;
                state         <= SP_WRTL;
            end

            // ── Write left 8 pixels ──────────────────────────────────────────
            SP_WRTL: begin
                if (px_idx == 3'd7) begin
                    px_idx        <= 3'b0;
                    writing_right <= 1'b1;
                    state         <= SP_WRTR;
                end else begin
                    px_idx <= px_idx + 3'd1;
                end
            end

            // ── Write right 8 pixels ─────────────────────────────────────────
            SP_WRTR: begin
                if (px_idx == 3'd7) begin
                    state <= SP_NEXTROW;
                end else begin
                    px_idx <= px_idx + 3'd1;
                end
            end

            // ── Advance to next row or next sprite ───────────────────────────
            SP_NEXTROW: begin
                if (row_idx == 4'd15) begin
                    // Done with this sprite
                    if (sprite_idx == 9'd407) begin
                        state <= SP_DONE;
                    end else begin
                        sprite_idx <= sprite_idx + 9'd1;
                        state      <= SP_LOAD0;
                    end
                end else begin
                    row_idx <= row_idx + 4'd1;
                    state   <= SP_ROWL0;
                end
            end

            // ── Done: stay idle until VBLANK ends ────────────────────────────
            SP_DONE: begin
                // Wait here until VBLANK goes away; next VBLANK will restart
                if (vblank_n) state <= SP_IDLE;
            end

            default: state <= SP_IDLE;
        endcase
    end
end

endmodule
