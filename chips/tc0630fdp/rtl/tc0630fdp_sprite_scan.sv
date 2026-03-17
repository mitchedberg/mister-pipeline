`default_nettype none
// =============================================================================
// TC0630FDP — Sprite Scanner  (Step 9: +zoom pass-through)
// =============================================================================
// Runs during VBLANK.  Walks sprite entries 0..SPR_COUNT-1, decodes each
// 8-word entry, and appends it to the per-scanline active-sprite lists.
//
// Sprite RAM format (section1 §8.1):
//   Word 0: tile_lo[15:0]
//   Word 1: y_zoom[15:8], x_zoom[7:0]  ← Step 9: latched and passed through
//   Word 2: scroll_mode[15:14], sx[11:0] (signed)
//   Word 3: is_cmd[15],         sy[11:0] (signed)
//   Word 4: block_ctrl[15:12], lock[11], flipY[10], flipX[9], color[7:0]
//   Word 5: tile_hi[0]
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
//   [12:5]  x_zoom[7:0]   ← Step 9: was 5-bit (unused zeros), now full 8 bits
//   [4:0]   (unused, zero)
// =============================================================================

module tc0630fdp_sprite_scan (
    input  logic        clk,
    input  logic        rst_n,

    // ── Trigger ───────────────────────────────────────────────────────────
    input  logic        vblank_rise,

    // ── Sprite RAM read port (registered BRAM: addr→data in next cycle) ──
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
localparam int SPR_COUNT = 256;    // Step 9: first 256 entries only
localparam int MAX_SLOT  = 63;
localparam int NSCANS    = V_END - V_START;  // 232

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
typedef enum logic [3:0] {
    S_IDLE   = 4'd0,
    S_CLEAR  = 4'd1,
    S_LAT_W0 = 4'd2,
    S_LAT_W1 = 4'd3,   // Step 9: latch word 1 (zoom bytes)
    S_LAT_W2 = 4'd4,
    S_LAT_W3 = 4'd5,
    S_LAT_W4 = 4'd6,
    S_LAT_W5 = 4'd7,
    S_EMIT   = 4'd8,
    S_NEXT   = 4'd9
} state_t;

state_t state;

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------
logic  [7:0] clear_cnt;
logic  [7:0] spr_idx;

logic [15:0] w0_r, w1_r, w2_r, w3_r, w4_r, w5_r;

// Emit loop
logic  [8:0] emit_v;        // current scanline (absolute, V_START..V_END)
logic  [8:0] emit_v_end;    // inclusive end scanline

// Local slot counters (shadow of scount BRAM — avoids read-latency issues)
// 232 entries × 7 bits — synthesizes to 232×7 flip-flops
logic  [6:0] scan_slot [0:NSCANS-1];

// ---------------------------------------------------------------------------
// Combinational decode
// ---------------------------------------------------------------------------
logic [16:0] tile_code_d;
logic [11:0] sx_d, sy_d;
logic        flipy_d, flipx_d;
logic [ 5:0] palette_d;
logic [ 1:0] prio_d;
logic [ 7:0] y_zoom_d, x_zoom_d;

always_comb begin
    tile_code_d = {w5_r[0], w0_r};
    sx_d        = w2_r[11:0];
    sy_d        = w3_r[11:0];
    flipy_d     = w4_r[10];
    flipx_d     = w4_r[9];
    palette_d   = w4_r[5:0];
    prio_d      = w4_r[7:6];
    y_zoom_d    = w1_r[15:8];   // Step 9: y_zoom from word 1 [15:8]
    x_zoom_d    = w1_r[7:0];    // Step 9: x_zoom from word 1 [7:0]
    // 72-bit descriptor:
    // [71:55]=tile_code, [54:43]=sx, [42:31]=sy,
    // [30:25]=palette, [24:23]=prio, [22]=flipY, [21]=flipX,
    // [20:13]=y_zoom, [12:5]=x_zoom, [4:0]=0
    slist_data  = {tile_code_d, sx_d, sy_d,
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

assign sy_s     = {{1{w3_r[11]}}, w3_r[11:0]};
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
integer ci;  // loop variable for scan_slot reset

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        spr_idx        <= 8'd0;
        clear_cnt      <= 8'd0;
        spr_rd_addr    <= 15'd0;
        slist_wr       <= 1'b0;
        slist_addr     <= 14'd0;
        scount_wr      <= 1'b0;
        scount_wr_addr <= 8'd0;
        scount_wr_data <= 7'd0;
        w0_r <= 16'd0; w1_r <= 16'd0; w2_r <= 16'd0; w3_r <= 16'd0;
        w4_r <= 16'd0; w5_r <= 16'd0;
        emit_v         <= 9'd0;
        emit_v_end     <= 9'd0;
        for (ci = 0; ci < NSCANS; ci = ci + 1)
            scan_slot[ci] <= 7'd0;
    end else begin
        slist_wr  <= 1'b0;
        scount_wr <= 1'b0;

        unique case (state)

            // ─ Idle: wait for VBLANK ─────────────────────────────────────
            S_IDLE: begin
                if (vblank_rise) begin
                    for (ci = 0; ci < NSCANS; ci = ci + 1)
                        scan_slot[ci] <= 7'd0;
                    clear_cnt      <= 8'd0;
                    scount_wr      <= 1'b1;
                    scount_wr_addr <= 8'd0;
                    scount_wr_data <= 7'd0;
                    state          <= S_CLEAR;
                end
            end

            // ─ Clear scount BRAM (one entry per cycle) ───────────────────
            S_CLEAR: begin
                if (clear_cnt == 8'(NSCANS - 2)) begin
                    // Write entry NSCANS-1, then done
                    scount_wr      <= 1'b1;
                    scount_wr_addr <= 8'(NSCANS - 1);
                    scount_wr_data <= 7'd0;
                    // Start walk — issue address for word 0 of sprite 0
                    spr_idx        <= 8'd0;
                    spr_rd_addr    <= 15'd0;  // sprite 0, word 0
                    state          <= S_LAT_W0;
                end else begin
                    clear_cnt      <= clear_cnt + 8'd1;
                    scount_wr      <= 1'b1;
                    scount_wr_addr <= clear_cnt + 8'd1;
                    scount_wr_data <= 7'd0;
                end
            end

            // ─ Latch sprite words (1-cycle BRAM latency) ─────────────────
            S_LAT_W0: begin
                w0_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx, 3'd1});  // issue word 1 address
                state       <= S_LAT_W1;
            end

            S_LAT_W1: begin
                w1_r        <= spr_rd_data;            // latch word 1 (zoom)
                spr_rd_addr <= 15'({spr_idx, 3'd2});  // issue word 2 address
                state       <= S_LAT_W2;
            end

            S_LAT_W2: begin
                w2_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx, 3'd3});
                state       <= S_LAT_W3;
            end

            S_LAT_W3: begin
                w3_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx, 3'd4});
                state       <= S_LAT_W4;
            end

            S_LAT_W4: begin
                w4_r        <= spr_rd_data;
                spr_rd_addr <= 15'({spr_idx, 3'd5});
                state       <= S_LAT_W5;
            end

            S_LAT_W5: begin
                w5_r       <= spr_rd_data;
                // w3_r (sy) already latched; compute emit range
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
                    // cur_slot is combinational from scan_slot[emit_scan]
                    // cur_slot is 7-bit; reject when it reaches MAX_SLOT+1=64
                    if (cur_slot <= 7'(MAX_SLOT)) begin
                        slist_wr   <= 1'b1;
                        slist_addr <= {emit_scan, cur_slot[5:0]};
                        // slist_data: combinational from latched w* regs

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
                if (spr_idx == 8'(SPR_COUNT - 1)) begin
                    state <= S_IDLE;
                end else begin
                    spr_idx     <= spr_idx + 8'd1;
                    spr_rd_addr <= 15'({(spr_idx + 8'd1), 3'd0});
                    state       <= S_LAT_W0;
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
                   w4_r[15:11], w4_r[8],
                   w5_r[15:1]};
/* verilator lint_on UNUSED */

endmodule
