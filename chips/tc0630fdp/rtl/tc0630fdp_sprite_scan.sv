`default_nettype none
// =============================================================================
// TC0630FDP — Sprite Scanner  (Step 10: +block groups +jump)
// =============================================================================
// Runs during VBLANK.  Walks sprite entries 0..SPR_COUNT-1, decodes each
// 8-word entry, and appends it to the per-scanline active-sprite lists.
//
// Sprite RAM format (section1 §8.1, 8 words per entry):
//   Word 0: tile_lo[15:0]
//   Word 1: y_zoom[15:8], x_zoom[7:0]
//   Word 2: scroll_mode[15:14], sx[11:0] (signed)
//   Word 3: is_cmd[15],         sy[11:0] (signed)
//   Word 4: block_ctrl[15:8], lock[11], flipY[10], flipX[9], color[7:0]
//           block_ctrl = w4[15:8]: x_num=block_ctrl[7:4], y_num=block_ctrl[3:0]
//   Word 5: tile_hi[0]
//   Word 6: jump[15], target[9:0]   ← Step 10: jump mechanism
//
// Block sprites (Step 10, section1 §8.2, section2 §3.2):
//   When block_ctrl != 0 AND not already in_block:
//     anchor: records sx, sy, x_zoom, y_zoom, x_num, y_num; sets in_block=true.
//   When in_block (anchor + continuation entries):
//     Override sx, sy, x_zoom, y_zoom from anchor.
//     Position formula (Y advances first, then X):
//       scale = 0x100 - anchor_x_zoom
//       sx = anchor_sx + ((x_no * scale * 16) >> 8)
//       sy = anchor_sy + ((y_no * scale * 16) >> 8)
//     y_no increments each entry; when y_no > y_num: y_no = 0, x_no++.
//     When x_no > x_num: in_block = false.
//
// Jump (Step 10, section1 §8.1 word 6):
//   When w6[15] == 1: set spr_idx = w6[9:0]; skip entries between old and new idx.
//
// Lock bit (Word4[11]):
//   When a continuation entry (in_block == true AND its own w4 block_ctrl == 0)
//   has lock == 1, it inherits position from the anchor unchanged (no grid advance).
//   This test case is covered by Step 10 test 6.
//
// 72-bit sprite list descriptor (shared with sprite_render):
//   [71:55] tile_code[16:0]
//   [54:43] sx[11:0]
//   [42:31] sy[11:0]
//   [30:25] palette[5:0]
//   [24:23] priority[1:0]
//   [22]    flipY
//   [21]    flipX
//   [20:13] y_zoom[7:0]
//   [12:5]  x_zoom[7:0]
//   [4:0]   (unused, zero)
// =============================================================================

module tc0630fdp_sprite_scan (
    input  logic        clk,
    input  logic        rst_n,

    // ── Trigger ───────────────────────────────────────────────────────────
    input  logic        vblank_rise,

    // ── Sprite RAM read port (combinational: addr→data same cycle) ────────
    output logic [14:0] spr_rd_addr,
    input  logic [15:0] spr_rd_data,

    // ── Per-scanline sprite list write port ──────────────────────────────
    output logic        slist_wr,
    output logic [13:0] slist_addr,    // {screen_scan[7:0], slot[5:0]}
    output logic [71:0] slist_data,

    // ── Sprite count BRAM write port ─────────────────────────────────────
    output logic        scount_wr,
    output logic [ 7:0] scount_wr_addr,
    output logic [ 6:0] scount_wr_data,

    // ── Sprite count BRAM read port (not used by scanner; for render) ─────
    output logic [ 7:0] scount_rd_addr,
    input  logic [ 6:0] scount_rd_data
);

// ---------------------------------------------------------------------------
localparam int V_START   = 24;
localparam int V_END     = 256;
localparam int SPR_COUNT = 256;    // walk first 256 entries (before any jump)
localparam int MAX_SLOT  = 63;
localparam int NSCANS    = V_END - V_START;  // 232

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
typedef enum logic [3:0] {
    S_IDLE   = 4'd0,
    S_CLEAR  = 4'd1,
    S_LAT_W0 = 4'd2,
    S_LAT_W1 = 4'd3,
    S_LAT_W2 = 4'd4,
    S_LAT_W3 = 4'd5,
    S_LAT_W4 = 4'd6,
    S_LAT_W5 = 4'd7,
    S_LAT_W6 = 4'd8,   // Step 10: latch word 6 (jump)
    S_EMIT   = 4'd9,
    S_NEXT   = 4'd10
} state_t;

state_t state;

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------
logic  [7:0] clear_cnt;
logic  [9:0] spr_idx;          // Step 10: 10-bit to support jump target up to 1023

logic [15:0] w0_r, w1_r, w2_r, w3_r, w4_r, w5_r, w6_r;

// Emit loop
logic  [8:0] emit_v;        // current scanline (absolute, V_START..V_END)
logic  [8:0] emit_v_end;    // inclusive end scanline

// Local slot counters (shadow of scount BRAM — avoids read-latency issues)
// 232 entries × 7 bits — uses MLAB for ALM savings (async read, sync write)
`ifdef QUARTUS
(* ramstyle = "MLAB" *) logic [6:0] scan_slot [0:255];  // rounded to 256 for MLAB efficiency
`else
logic  [6:0] scan_slot [0:NSCANS-1];
`endif

// ---------------------------------------------------------------------------
// Block group state (Step 10)
// ---------------------------------------------------------------------------
logic        in_block;         // currently processing a multi-tile block
logic  [3:0] block_x_num;      // anchor x_num (columns - 1)
logic  [3:0] block_y_num;      // anchor y_num (rows - 1)
logic  [3:0] block_x_no;       // current column index
logic  [3:0] block_y_no;       // current row index
logic [11:0] anchor_sx;        // anchor screen X
logic [11:0] anchor_sy;        // anchor screen Y
logic  [7:0] anchor_x_zoom;    // anchor x_zoom
logic  [7:0] anchor_y_zoom;    // anchor y_zoom

// ---------------------------------------------------------------------------
// Combinational decode helpers
// ---------------------------------------------------------------------------
logic [7:0]  blk_ctrl_d;    // block_ctrl = w4[15:8]
logic [3:0]  blk_x_num_d;   // x_num = upper nibble
logic [3:0]  blk_y_num_d;   // y_num = lower nibble
logic        is_anchor_d;   // block_ctrl != 0 and not already in_block

always_comb begin
    blk_ctrl_d   = w4_r[15:8];
    blk_x_num_d  = w4_r[15:12];    // upper nibble of block_ctrl (bits[15:12])
    blk_y_num_d  = w4_r[11:8];     // lower nibble of block_ctrl (bits[11:8])
    is_anchor_d  = (blk_ctrl_d != 8'd0) && !in_block;
end

// Block grid position computation (combinational, used in emit phase)
// sx = anchor_sx + ((x_no * scale * 16) >> 8)
// sy = anchor_sy + ((y_no * scale * 16) >> 8)
// scale = 0x100 - anchor_x_zoom  (9-bit)
// x_no * scale * 16: x_no is 4-bit (0..15), scale 9-bit, *16=shift left 4 → 17-bit product
// >> 8 gives 9-bit integer result
// Use sx_offset = (x_no * (9'h100 - anchor_x_zoom) * 16) >> 8
//              = x_no * (9'h100 - anchor_x_zoom) >> 4   (same as * 16 / 256)
logic  [8:0] blk_scale;
`ifdef QUARTUS
(* multstyle = "dsp" *) logic [12:0] blk_sx_offset;
(* multstyle = "dsp" *) logic [12:0] blk_sy_offset;
`else
logic [12:0] blk_sx_offset, blk_sy_offset;
`endif
logic [11:0] blk_sx, blk_sy;

always_comb begin
    blk_scale     = 9'h100 - {1'b0, anchor_x_zoom};
    // x_no * scale * 16 >> 8  =  x_no * scale >> 4
    blk_sx_offset = 13'(13'(block_x_no) * 13'(blk_scale)) >> 4;
    blk_sy_offset = 13'(13'(block_y_no) * 13'(blk_scale)) >> 4;
    blk_sx = 12'(12'(anchor_sx) + blk_sx_offset[11:0]);
    blk_sy = 12'(12'(anchor_sy) + blk_sy_offset[11:0]);
end

// ---------------------------------------------------------------------------
// Final decoded sprite fields (after block override)
// ---------------------------------------------------------------------------
logic [16:0] tile_code_d;
logic [11:0] sx_d, sy_d;
logic        flipy_d, flipx_d;
logic [ 5:0] palette_d;
logic [ 1:0] prio_d;
logic [ 7:0] y_zoom_d, x_zoom_d;

always_comb begin
    tile_code_d = {w5_r[0], w0_r};
    flipy_d     = w4_r[10];
    flipx_d     = w4_r[9];
    palette_d   = w4_r[5:0];
    prio_d      = w4_r[7:6];

    if (in_block) begin
        // Block continuation: override position and zoom from anchor
        sx_d     = blk_sx;
        sy_d     = blk_sy;
        y_zoom_d = anchor_y_zoom;
        x_zoom_d = anchor_x_zoom;
    end else begin
        sx_d     = w2_r[11:0];
        sy_d     = w3_r[11:0];
        y_zoom_d = w1_r[15:8];
        x_zoom_d = w1_r[7:0];
    end

    // 72-bit descriptor:
    // [71:55]=tile_code, [54:43]=sx, [42:31]=sy,
    // [30:25]=palette, [24:23]=prio, [22]=flipY, [21]=flipX,
    // [20:13]=y_zoom, [12:5]=x_zoom, [4:0]=0
    slist_data = {tile_code_d, sx_d, sy_d,
                  palette_d, prio_d, flipy_d, flipx_d,
                  y_zoom_d, x_zoom_d, 5'h00};
end

// ---------------------------------------------------------------------------
// Zoom-aware sy range clamping
// When y_zoom != 0x00 the rendered height = (16 * (0x100 - y_zoom)) >> 8.
// For the scanner, we use the un-zoomed height (16 rows) for the scanline
// range — the renderer will skip rows outside the zoomed tile.
// This is conservative (may add sprite to scanlines where it renders nothing)
// but is correct: a sprite's visible rows are always a subset of [sy, sy+15].
// ---------------------------------------------------------------------------
logic signed [12:0] sy_s;
logic signed [12:0] sy_end_s;
logic [8:0] sy_top_c, sy_bot_c;

assign sy_s     = {{1{sy_d[11]}}, sy_d};
assign sy_end_s = sy_s + 13'sd15;

always_comb begin
    if (sy_s < $signed(13'(V_START)))
        sy_top_c = 9'(V_START);
    else if (sy_s >= $signed(13'(V_END)))
        sy_top_c = 9'(V_END);
    else
        sy_top_c = 9'(sy_s);

    if (sy_end_s < $signed(13'(V_START)))
        sy_bot_c = 9'(V_START - 1);
    else if (sy_end_s >= $signed(13'(V_END)))
        sy_bot_c = 9'(V_END - 1);
    else
        sy_bot_c = 9'(sy_end_s);
end

// Screen-relative index for emit_v
logic [7:0] emit_scan;
assign emit_scan = emit_v[7:0] - 8'(V_START);

// Current slot for emit_scan (from local shadow)
logic [6:0] cur_slot;
assign cur_slot = scan_slot[emit_scan];

// scount read: scanner doesn't read scount itself; drive to 0
assign scount_rd_addr = 8'd0;

// ---------------------------------------------------------------------------
// FSM (single always_ff)
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        spr_idx        <= 10'd0;
        clear_cnt      <= 8'd0;
        spr_rd_addr    <= 15'd0;
        slist_wr       <= 1'b0;
        slist_addr     <= 14'd0;
        scount_wr      <= 1'b0;
        scount_wr_addr <= 8'd0;
        scount_wr_data <= 7'd0;
        w0_r <= 16'd0; w1_r <= 16'd0; w2_r <= 16'd0; w3_r <= 16'd0;
        w4_r <= 16'd0; w5_r <= 16'd0; w6_r <= 16'd0;
        emit_v         <= 9'd0;
        emit_v_end     <= 9'd0;
        in_block       <= 1'b0;
        block_x_num    <= 4'd0;
        block_y_num    <= 4'd0;
        block_x_no     <= 4'd0;
        block_y_no     <= 4'd0;
        anchor_sx      <= 12'd0;
        anchor_sy      <= 12'd0;
        anchor_x_zoom  <= 8'd0;
        anchor_y_zoom  <= 8'd0;
        // scan_slot FFs power up to 0 on Cyclone V — no reset loop needed.
    end else begin
        slist_wr  <= 1'b0;
        scount_wr <= 1'b0;

        case (state)

            // ─ Idle: wait for VBLANK ─────────────────────────────────────
            S_IDLE: begin
                if (vblank_rise) begin
                    // scan_slot[0] cleared here; [1..NSCANS-1] cleared in S_CLEAR.
                    // (Distributes 232-entry clear across S_CLEAR cycles — avoids
                    //  Quartus 17 Error 10028 from the 232-iteration for-loop.)
                    scan_slot[8'd0] <= 7'd0;
                    clear_cnt      <= 8'd0;
                    scount_wr      <= 1'b1;
                    scount_wr_addr <= 8'd0;
                    scount_wr_data <= 7'd0;
                    in_block       <= 1'b0;
                    block_x_no     <= 4'd0;
                    block_y_no     <= 4'd0;
                    state          <= S_CLEAR;
                end
            end

            // ─ Clear scount BRAM + scan_slot (one entry per cycle) ───────
            S_CLEAR: begin
                if (clear_cnt == 8'(NSCANS - 2)) begin
                    // Write entry NSCANS-1, then done
                    scount_wr      <= 1'b1;
                    scount_wr_addr <= 8'(NSCANS - 1);
                    scount_wr_data <= 7'd0;
                    scan_slot[8'(NSCANS - 1)] <= 7'd0;  // last scan_slot entry
                    // Start walk — issue address for word 0 of sprite 0
                    spr_idx        <= 10'd0;
                    spr_rd_addr    <= 15'd0;  // sprite 0, word 0
                    state          <= S_LAT_W0;
                end else begin
                    clear_cnt      <= clear_cnt + 8'd1;
                    scount_wr      <= 1'b1;
                    scount_wr_addr <= clear_cnt + 8'd1;
                    scount_wr_data <= 7'd0;
                    scan_slot[clear_cnt + 8'd1] <= 7'd0;  // parallel scan_slot clear
                end
            end

            // ─ Latch sprite words (1-cycle BRAM latency) ─────────────────
            S_LAT_W0: begin
                w0_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx[7:0], 3'd1});  // issue word 1 address
                state       <= S_LAT_W1;
            end

            S_LAT_W1: begin
                w1_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx[7:0], 3'd2});
                state       <= S_LAT_W2;
            end

            S_LAT_W2: begin
                w2_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx[7:0], 3'd3});
                state       <= S_LAT_W3;
            end

            S_LAT_W3: begin
                w3_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx[7:0], 3'd4});
                state       <= S_LAT_W4;
            end

            S_LAT_W4: begin
                w4_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx[7:0], 3'd5});
                state       <= S_LAT_W5;
            end

            S_LAT_W5: begin
                w5_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx[7:0], 3'd6});  // issue word 6 address
                state       <= S_LAT_W6;
            end

            // ─ Latch word 6 (jump) + begin block detection ────────────────
            S_LAT_W6: begin
                w6_r <= spr_rd_data;

                // Block anchor detection (combinational is_anchor_d from w4_r + in_block).
                // Lock bit = w4[11] is part of blk_y_num_d[3]; when in_block and lock=1
                // the grid still advances (handled in emit using blk_sx/blk_sy).
                if (is_anchor_d) begin
                    in_block      <= 1'b1;
                    block_x_num   <= blk_x_num_d;
                    block_y_num   <= blk_y_num_d;
                    block_x_no    <= 4'd0;
                    block_y_no    <= 4'd0;
                    anchor_sx     <= w2_r[11:0];
                    anchor_sy     <= w3_r[11:0];
                    anchor_x_zoom <= w1_r[7:0];
                    anchor_y_zoom <= w1_r[15:8];
                end

                // Compute emit range using sy_d (combinational from latched regs).
                // Note: in_block is still 0 for the anchor at this point (registered
                // update takes effect next cycle), so sy_top_c uses raw sy from w3_r
                // for the anchor entry.  For continuations, in_block is already 1,
                // so sy_top_c uses blk_sy (the grid-computed sy).
                emit_v     <= sy_top_c;
                emit_v_end <= sy_bot_c;
                state      <= S_EMIT;
            end

            // ─ Emit: write sprite to per-scanline list ────────────────────
            // One scanline per cycle; uses local scan_slot[] shadow
            S_EMIT: begin
                if (emit_v >= 9'(V_END) || emit_v > emit_v_end) begin
                    state <= S_NEXT;
                end else begin
                    if (cur_slot <= 7'(MAX_SLOT)) begin
                        slist_wr   <= 1'b1;
                        slist_addr <= {emit_scan, cur_slot[5:0]};
                        // slist_data: combinational from decoded fields

                        // Update scount BRAM
                        scount_wr      <= 1'b1;
                        scount_wr_addr <= emit_scan;
                        scount_wr_data <= cur_slot + 7'd1;

                        // Update local shadow
                        scan_slot[emit_scan] <= cur_slot + 7'd1;
                    end

                    emit_v <= emit_v + 9'd1;
                    if (emit_v + 9'd1 > emit_v_end ||
                        emit_v + 9'd1 >= 9'(V_END)) begin
                        state <= S_NEXT;
                    end
                end
            end

            // ─ Next sprite ────────────────────────────────────────────────
            S_NEXT: begin
                // ── Jump: w6[15]=1 → jump to w6[9:0] ──────────────────────
                if (w6_r[15]) begin
                    // Jump skips to the target index.
                    // Cancel any in-progress block (block terminates on jump).
                    in_block   <= 1'b0;
                    spr_idx    <= w6_r[9:0];
                    // Only continue if target < SPR_COUNT
                    if (w6_r[9:0] < 10'(SPR_COUNT)) begin
                        spr_rd_addr <= 15'({w6_r[7:0], 3'd0});
                        state       <= S_LAT_W0;
                    end else begin
                        state <= S_IDLE;
                    end
                end else begin
                    // ── Block group state advance ───────────────────────────
                    if (in_block) begin
                        // Advance y_no; when y_no > y_num → advance x_no
                        if (block_y_no >= block_y_num) begin
                            block_y_no <= 4'd0;
                            if (block_x_no >= block_x_num) begin
                                // Block complete
                                in_block   <= 1'b0;
                                block_x_no <= 4'd0;
                            end else begin
                                block_x_no <= block_x_no + 4'd1;
                            end
                        end else begin
                            block_y_no <= block_y_no + 4'd1;
                        end
                    end

                    // ── Normal advance or end of list ──────────────────────
                    if (spr_idx == 10'(SPR_COUNT - 1)) begin
                        state <= S_IDLE;
                    end else begin
                        spr_idx     <= spr_idx + 10'd1;
                        spr_rd_addr <= 15'({(spr_idx[7:0] + 8'd1), 3'd0});
                        state       <= S_LAT_W0;
                    end
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{scount_rd_data,
                   w2_r[15:12],
                   w3_r[15:12],
                   w5_r[15:1],
                   w6_r[14:10],
                   blk_sx_offset[12],
                   blk_sy_offset[12],
                   spr_idx[9:8]};
/* verilator lint_on UNUSED */

endmodule
