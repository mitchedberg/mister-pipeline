`default_nettype none
// =============================================================================
// TC0630FDP — Sprite Renderer  (Step 8: simple sprites, no zoom)
// =============================================================================
// Ping-pong line buffer renderer: during HBLANK for scanline N, renders the
// sprite list for scanline N+1 into the back buffer; during active scan N+1,
// pixel output comes from the front buffer.
//
// Sprite list descriptor (64-bit):
//   [63:47] tile_code[16:0]
//   [46:35] sx[11:0]   (signed; screen X of tile left edge)
//   [34:23] sy[11:0]   (signed; screen Y of tile top edge)
//   [22:17] palette[5:0]
//   [16:15] priority[1:0]
//   [14]    flipY
//   [13]    flipX
//   [12:5]  y_zoom[7:0]  (Step 8: 0)
//   [4:0]   x_zoom[4:0]  (Step 8: 0)
//
// Line buffer entry: 12-bit {priority[1:0], palette[5:0], pen[3:0]}
//   pen==0 → transparent (do not overwrite)
//
// GFX ROM (32-bit, nibble-packed 4bpp, §11.3):
//   word addr = tile_code*32 + row*2       (left 8 pixels)
//             = tile_code*32 + row*2 + 1   (right 8 pixels)
//   bits[31:28]=px0, ..., bits[3:0]=px7
//   flipX: reverse nibble order within 8px half
//   flipY: row = 15 - row
//
// BRAM latency: synchronous (addr on cycle N → data on cycle N+1).
//
// Render FSM per sprite (7 cycles):
//   ADDR  : drive slist address
//   LATCH : slist data valid; latch entry fields
//   ISSUE : issue gfx_left addr (now r_tile/r_sy valid)
//   GFX_L : gfx_data = left word; latch it; issue right addr
//   GFX_R : gfx_data = right word; write 16 pixels to linebuf
//   NEXT  : advance slot; loop
// =============================================================================

module tc0630fdp_sprite_render (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        hblank,
    input  logic        hblank_fall,   // hblank rising edge: start rendering
    input  logic [ 8:0] vpos,
    input  logic [ 9:0] hpos,

    output logic [ 7:0] scount_rd_addr,
    input  logic [ 6:0] scount_rd_data,

    output logic [13:0] slist_rd_addr,
    input  logic [63:0] slist_rd_data,

    output logic [21:0] gfx_addr,
    input  logic [31:0] gfx_data,

    output logic [11:0] spr_pixel
);

// ---------------------------------------------------------------------------
localparam int V_START = 24;
localparam int H_START = 46;
localparam int H_END   = 366;

// ---------------------------------------------------------------------------
// Dual ping-pong line buffers
// ---------------------------------------------------------------------------
logic [11:0] lbuf [0:1][0:319];
logic back_buf;
logic front_buf;

// Pre-active edge: fires one cycle before H_START (hpos == H_START-1 = 45).
// Swapping here ensures the new front buffer is valid at the very first active
// pixel (hpos == H_START == 46, screen column 0).
logic hblank_end;
assign hblank_end = (hpos == 10'(H_START - 1));

always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_END))
        spr_pixel = lbuf[front_buf][9'(hpos - 10'(H_START))];
    else
        spr_pixel = 12'd0;
end

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
typedef enum logic [2:0] {
    S_IDLE   = 3'd0,
    S_CNT    = 3'd1,   // wait for scount BRAM (1 cycle after addr)
    S_ADDR   = 3'd2,   // drive slist addr, wait 1 cycle
    S_LATCH  = 3'd3,   // latch slist entry; issue gfx_left addr
    S_GFX_L  = 3'd4,   // latch gfx_left; issue gfx_right addr
    S_GFX_R  = 3'd5,   // gfx_right arrives; write pixels
    S_NEXT   = 3'd6
} state_t;

state_t state;

// ---------------------------------------------------------------------------
logic [ 7:0] render_scan;
logic [ 6:0] spr_count;
logic [ 5:0] spr_slot;

logic [16:0] r_tile;
logic [11:0] r_sx;
logic [11:0] r_sy;
logic [ 5:0] r_palette;
logic [ 1:0] r_prio;
logic        r_flipy, r_flipx;
logic [31:0] gfx_left_r;

// Registered slist address (scan + slot portions stored separately)
logic [ 7:0] addr_scan;
logic [ 5:0] addr_slot;
assign slist_rd_addr = {addr_scan, addr_slot};

// ---------------------------------------------------------------------------
// Tile row (uses r_sy latched in S_LATCH)
// ---------------------------------------------------------------------------
// abs_scan = render_scan + V_START; tile_row = (abs_scan - r_sy) & 0xF
logic [4:0] abs_scan_5;   // lower 5 bits sufficient for row computation
logic [3:0] tile_row;
logic [3:0] fetch_row;
assign abs_scan_5 = {1'b0, render_scan[3:0]} + 5'(V_START & 5'h1F);
assign tile_row   = abs_scan_5[3:0] - r_sy[3:0];
assign fetch_row  = r_flipy ? (4'd15 - tile_row) : tile_row;

logic [21:0] gfx_left_addr;
logic [21:0] gfx_right_addr;
assign gfx_left_addr  = 22'(22'(r_tile) * 22'd32 + {18'd0, fetch_row, 1'b0});
assign gfx_right_addr = gfx_left_addr + 22'd1;

// ---------------------------------------------------------------------------
// Pixel decode function
// ---------------------------------------------------------------------------
function automatic logic [3:0] decode_pen(
    input logic [31:0] word,
    input logic [2:0]  px_idx,
    input logic        flip
);
    logic [2:0] ni;
    logic [4:0] sh;
    ni = flip ? (3'd7 - px_idx) : px_idx;
    sh = 5'd28 - {ni, 2'b00};
    decode_pen = 4'((word >> sh) & 32'hF);
endfunction

// Precomputed pixel info for the write loop
logic signed [12:0] px_scol [0:15];
logic [3:0]         px_pen  [0:15];

always_comb begin
    for (int px = 0; px < 16; px++) begin
        px_scol[px] = $signed({{1{r_sx[11]}}, r_sx}) + 13'(px);
        if (px < 8)
            px_pen[px] = decode_pen(gfx_left_r, 3'(px),     r_flipx);
        else
            px_pen[px] = decode_pen(gfx_data,   3'(px & 7), r_flipx);
    end
end

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        back_buf       <= 1'b0;
        front_buf      <= 1'b1;
        render_scan    <= 8'd0;
        spr_count      <= 7'd0;
        spr_slot       <= 6'd0;
        scount_rd_addr <= 8'd0;
        addr_scan      <= 8'd0;
        addr_slot      <= 6'd0;
        gfx_addr       <= 22'd0;
        r_tile         <= 17'd0;
        r_sx           <= 12'd0;
        r_sy           <= 12'd0;
        r_palette      <= 6'd0;
        r_prio         <= 2'd0;
        r_flipy        <= 1'b0;
        r_flipx        <= 1'b0;
        gfx_left_r     <= 32'd0;
        for (int i = 0; i < 320; i++) begin
            lbuf[0][i] <= 12'd0;
            lbuf[1][i] <= 12'd0;
        end
    end else if (hblank_end) begin
        // End of HBLANK: swap front/back so the just-rendered back becomes
        // the new front, visible during the upcoming active display.
        // New back (old front) is cleared and ready for the next render.
        front_buf <= back_buf;
        back_buf  <= front_buf;
        for (int i = 0; i < 320; i++)
            lbuf[front_buf][i] <= 12'd0;   // clear old front = new back
    end else if (hblank_fall) begin
        // Start of HBLANK: begin rendering sprite list for (vpos+1).
        // Back buffer is currently free (cleared at previous hblank_end).
        // Render scan: (vpos+1) - V_START (index 0..231 into slist/scount).
        render_scan    <= vpos[7:0] - 8'(V_START) + 8'd1;
        scount_rd_addr <= vpos[7:0] - 8'(V_START) + 8'd1;
        state          <= S_CNT;
    end else begin
        unique case (state)

            S_IDLE: begin end

            // 1-cycle wait for scount BRAM
            S_CNT: begin
                spr_count  <= scount_rd_data;
                spr_slot   <= 6'd0;
                if (scount_rd_data == 7'd0) begin
                    state <= S_IDLE;
                end else begin
                    // Drive slist[render_scan][0] address
                    addr_scan <= render_scan;
                    addr_slot <= 6'd0;
                    state     <= S_ADDR;
                end
            end

            // 1-cycle wait for slist BRAM
            S_ADDR: begin
                state <= S_LATCH;
            end

            // Latch slist entry fields
            S_LATCH: begin
                r_tile    <= slist_rd_data[63:47];
                r_sx      <= slist_rd_data[46:35];
                r_sy      <= slist_rd_data[34:23];
                r_palette <= slist_rd_data[22:17];
                r_prio    <= slist_rd_data[16:15];
                r_flipy   <= slist_rd_data[14];
                r_flipx   <= slist_rd_data[13];
                // NOTE: gfx_left_addr uses r_tile/r_sy which update at this edge.
                // Must wait until next cycle before r_tile/r_sy are stable.
                // S_GFX_L will issue the left address using now-valid registers.
                state     <= S_GFX_L;
            end

            // Issue GFX left read (r_tile, r_sy now stable from S_LATCH edge)
            S_GFX_L: begin
                gfx_addr <= gfx_left_addr;
                state    <= S_GFX_R;
            end

            // Issue GFX right read; wait for left data
            // Actually: gfx_left_addr was issued in S_GFX_L, so gfx_data is
            // the LEFT data now. Latch it and issue right.
            // Wait — that means we need an extra state. Let me restructure:
            // S_GFX_L: issue left addr → S_WAIT_L: latch left data, issue right addr
            //          → S_GFX_R: latch right data, write pixels
            // But I only have S_GFX_L and S_GFX_R in the enum. Add a state.
            // For now: use S_GFX_R as the state where left data arrives.
            // In S_GFX_L: issued left addr. S_GFX_R: gfx_data = left data.
            //   Latch left, issue right.
            // Then need one more state for right data → write.
            // Rename: S_GFX_L = issue left addr (1 cycle)
            //         S_GFX_R = latch left, issue right (1 cycle)
            //         S_WRITE  = latch right, write pixels (not in enum yet)
            // Must fix enum. But I want to avoid re-enumerating.
            // Simpler approach: make S_GFX_R both latch left AND issue right.
            // Then we go back to S_NEXT after one more cycle (S_IDLE?) for right.
            // Actually, just rename states logically:
            // (This comment block is getting long; see clean implementation below)
            S_GFX_R: begin
                // gfx_data = left half data (addr issued in S_GFX_L last cycle)
                gfx_left_r <= gfx_data;
                gfx_addr   <= gfx_right_addr;
                state      <= S_NEXT;
            end

            // gfx_data = right half data; write pixels
            S_NEXT: begin
                // Write 16 pixels to back line buffer
                for (int px = 0; px < 16; px++) begin
                    if (px_scol[px] >= 13'sd0 &&
                        px_scol[px] < 13'sd320 &&
                        px_pen[px]  != 4'd0) begin
                        lbuf[back_buf][px_scol[px][8:0]] <=
                            {r_prio, r_palette, px_pen[px]};
                    end
                end
                // Advance
                if (7'(spr_slot) + 7'd1 >= spr_count) begin
                    state <= S_IDLE;
                end else begin
                    spr_slot  <= spr_slot + 6'd1;
                    addr_slot <= spr_slot + 6'd1;
                    state     <= S_ADDR;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{tile_row,
                   hblank,
                   vpos[8],
                   slist_rd_data[12:0],
                   r_sy[11:4],
                   abs_scan_5[4]};
/* verilator lint_on UNUSED */

endmodule
