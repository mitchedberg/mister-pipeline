`default_nettype none
// =============================================================================
// CPS1 OBJ Sprite Engine
// =============================================================================
// Implements the sprite rendering subsystem of the Capcom CPS-A custom chip.
// Renders up to MAX_SPRITES independently-positioned 16x16 sprite tiles per frame,
// with multi-tile block support (up to 16x16 tiles per entry).
//
// Architecture:
//   - OBJ RAM double-buffering: CPU writes to live RAM, latched at VBLANK
//   - Ping-pong line buffer: "back" filled during hblank, "front" read during display
//   - Sprite scan: table scanned from last valid entry to 0 (lower index = higher priority)
//   - ROM fetch: 20-bit address, 32-bit data (8 pixels x 4bpp), two halves per tile row
//
// Display timing (8 MHz pixel clock):
//   Total width: 512 clocks/line, active: 384px (cols 64-447)
//   Total height: 262 lines, active: 224 (lines 0-239; vblank starts at 240)
//   Sprite rendering target: vrender = vcount + 1 (one line ahead)
//
// Fixes applied in this revision:
//   Bug 1: Find-end table scan moved from per-hblank to per-VBLANK (FES machine).
//   Bug 2: Per-sprite row-jump optimization: jump directly to visible tile row
//          instead of iterating through all rows to find visible ones.
//          Also adds hblank_end overflow guard.
//   Bug 3: vrender >= 240 guard prevents line buffer writes during vblank.
//
// Reset: section5 synchronizer (async assert, synchronous deassert)
// Memory: section4b ifdef VERILATOR stub pattern
// Anti-patterns: AP-1 through AP-10 enforced
// =============================================================================

module cps1_obj #(
    parameter int MAX_SPRITES = 256    // sprite table entries (must be <= 256)
) (
    // -- Clock and reset -------------------------------------------------------
    input  logic        clk,           // 8 MHz pixel clock
    input  logic        async_rst_n,   // raw async active-low reset

    // -- CPU bus interface (OBJ RAM writes) ------------------------------------
    input  logic [9:0]  cpu_addr,
    input  logic [15:0] cpu_data,
    input  logic        cpu_we,

    // -- Timing inputs from video controller -----------------------------------
    input  logic [8:0]  hcount,        // horizontal pixel counter 0-511
    input  logic [8:0]  vcount,        // vertical line counter 0-261
    input  logic        hblank_n,      // active-low horizontal blank
    input  logic        vblank_n,      // active-low vertical blank (asserts at line 240)

    // -- Global video control -------------------------------------------------
    input  logic        flip_screen,   // VIDEOCONTROL bit 15

    // -- ROM interface (B-board tile ROM) -------------------------------------
    output logic [19:0] rom_addr,      // {code[15:0], vsub[3:0]}
    output logic        rom_half,      // 0=left 8px half, 1=right 8px half
    output logic        rom_cs,        // chip-select: fetch active
    input  logic [31:0] rom_data,      // 8 pixels x 4bpp
    input  logic        rom_ok,        // data valid handshake

    // -- Line buffer output (to scene compositor) -----------------------------
    output logic [8:0]  pixel_out,     // {pal[4:0], color[3:0]}; registered
    output logic        pixel_valid    // asserted during active display window
);

// -- Derived parameter -------------------------------------------------------
localparam int SPR_ENTRIES = (MAX_SPRITES > 256) ? 256 : MAX_SPRITES;

// vrender must be < VRENDER_MAX to write pixels to the line buffer.
// vrender >= 240 is in vblank/overscan territory.
localparam logic [8:0] VRENDER_MAX = 9'd240;

// =============================================================================
// Reset synchronizer: async assert, synchronous deassert (section5 pattern).
// ONLY acceptable use of negedge async_rst_n in a sensitivity list.
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// =============================================================================
// OBJ RAM -- live buffer (CPU-writeable, 1024 words x 16 bits = 2 KB)
// =============================================================================
`ifdef VERILATOR
    logic [15:0] obj_ram_live [0:1023];
    always_ff @(posedge clk) begin
        if (cpu_we) obj_ram_live[cpu_addr] <= cpu_data;
    end
`else
    logic [15:0] obj_ram_live [0:1023];
    always_ff @(posedge clk) begin
        if (cpu_we) obj_ram_live[cpu_addr] <= cpu_data;
    end
`endif

// =============================================================================
// OBJ RAM -- shadow buffer (sprite engine reads from here)
// Latched from live buffer word-by-word over a 1024-cycle DMA at VBLANK.
// =============================================================================
logic [15:0] obj_ram_shadow [0:1023];

// VBLANK falling-edge detector (vblank_n goes low = VBLANK asserts)
logic vblank_n_prev;
always_ff @(posedge clk) begin
    if (!rst_n) vblank_n_prev <= 1'b1;
    else        vblank_n_prev <= vblank_n;
end
logic vblank_rise;
assign vblank_rise = vblank_n_prev & ~vblank_n;  // one-cycle pulse at VBLANK start

// DMA: copy live -> shadow, one word per clock over 1024 clocks
logic       dma_active;
logic [9:0] dma_addr;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        dma_active <= 1'b0;
        dma_addr   <= 10'd0;
    end else if (vblank_rise && !dma_active) begin
        dma_active <= 1'b1;
        dma_addr   <= 10'd0;
    end else if (dma_active) begin
        obj_ram_shadow[dma_addr] <= obj_ram_live[dma_addr];
        if (dma_addr == 10'd1023) begin
            dma_active <= 1'b0;
        end
        dma_addr <= dma_addr + 10'd1;
    end
end

// DMA-done one-shot pulse: fires one cycle after DMA finishes (dma_active 1->0)
logic dma_active_prev;
always_ff @(posedge clk) begin
    if (!rst_n) dma_active_prev <= 1'b0;
    else        dma_active_prev <= dma_active;
end
logic dma_done_pulse;
assign dma_done_pulse = dma_active_prev & ~dma_active;

// =============================================================================
// VBLANK find-end scan (FES): runs once per frame after DMA completes.
//
// BUG 1 FIX: The original code re-scanned the sprite table for the end marker
// at every hblank (O(N) cycles per scanline), overflowing the 64-cycle budget
// for large tables. The scan is now done ONCE per frame during VBLANK, after
// the 1024-cycle DMA completes.
//
// frame_last_sprite: index of last valid sprite entry.
// frame_empty_table: asserted when entry 0 is a terminator (no sprites).
// =============================================================================

typedef enum logic [1:0] {
    FES_IDLE = 2'd0,
    FES_SCAN = 2'd1,
    FES_DONE = 2'd2
} fes_state_t;

fes_state_t  fes_state;
logic [7:0]  fes_idx;
logic [7:0]  frame_last_sprite;
logic        frame_empty_table;

// Combinational ATTR high-byte read for FES (independent address from main FSM)
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] fes_attr;
/* verilator lint_on UNUSEDSIGNAL */
always_comb begin
    fes_attr = obj_ram_shadow[{fes_idx, 2'b11}];  // ATTR word of fes_idx
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        fes_state         <= FES_IDLE;
        fes_idx           <= 8'd0;
        frame_last_sprite <= 8'd0;
        frame_empty_table <= 1'b0;
    end else begin
        case (fes_state)
            FES_IDLE: begin
                if (dma_done_pulse) begin
                    fes_idx   <= 8'd0;
                    fes_state <= FES_SCAN;
                end
            end

            FES_SCAN: begin
                if (fes_attr[15:8] == 8'hFF) begin
                    if (fes_idx == 8'd0) begin
                        frame_last_sprite <= 8'd0;
                        frame_empty_table <= 1'b1;
                    end else begin
                        frame_last_sprite <= fes_idx - 8'd1;
                        frame_empty_table <= 1'b0;
                    end
                    fes_state <= FES_DONE;
                end else if (fes_idx == 8'(SPR_ENTRIES - 1)) begin
                    frame_last_sprite <= fes_idx;
                    frame_empty_table <= 1'b0;
                    fes_state         <= FES_DONE;
                end else begin
                    fes_idx <= fes_idx + 8'd1;
                end
            end

            FES_DONE: begin
                // Hold frame_last_sprite and frame_empty_table until next frame's scan.
                // They are updated in FES_SCAN and persist until the next VBLANK.
                if (vblank_n) begin
                    fes_state <= FES_IDLE;
                end
            end

            default: fes_state <= FES_IDLE;
        endcase
    end
end

// =============================================================================
// Ping-pong line buffers (two banks, each 512 x 9 bits)
// Transparent sentinel: 9'h1FF
// Back  bank: ~vcount[0]  -> written during hblank for line (vcount+1)
// Front bank:  vcount[0]  -> read during active display of line vcount
// =============================================================================
logic [8:0] linebuf [0:1][0:511];
logic back_bank;
logic front_bank;
assign back_bank  = ~vcount[0];
assign front_bank =  vcount[0];

// Startup clear: initialize both banks to transparent on reset
logic       lbinit_active;
logic [8:0] lbinit_addr;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        lbinit_active <= 1'b1;
        lbinit_addr   <= 9'd0;
    end else if (lbinit_active) begin
        linebuf[0][lbinit_addr] <= 9'h1FF;
        linebuf[1][lbinit_addr] <= 9'h1FF;
        if (lbinit_addr == 9'd511) lbinit_active <= 1'b0;
        lbinit_addr <= lbinit_addr + 9'd1;
    end
end

// =============================================================================
// Sprite scan state machine
//
// BUG 1 FIX: Uses frame_last_sprite (pre-computed at VBLANK) directly.
//
// BUG 2 FIX (Row-jump optimization):
//   Instead of iterating through ALL tile rows to find the visible one, the
//   FSM now computes which tile row covers vrender at sprite-load time (LOAD_W3)
//   and jumps directly to it. This reduces the hblank cycle budget for a full
//   8x8 block from ~166 cycles to ~54 cycles, fitting within the 64-cycle window.
//   Combined with an hblank_end overflow guard as a safety net.
//
// BUG 3 FIX: vrender >= VRENDER_MAX check in IDLE prevents writes during vblank.
//
// States:
//   IDLE       -> wait for hblank start
//   SCAN_LOAD0 -> present word-0 address of current scan entry
//   LOAD_W0    -> read word 0 (X)
//   LOAD_W1    -> read word 1 (Y)
//   LOAD_W2    -> read word 2 (CODE)
//   LOAD_W3    -> read word 3 (ATTR); compute visible tile row; begin tile loop
//   TILE_VIS   -> set tile parameters (tile_row_b already points to visible row)
//   ROM_REQ    -> assert rom_cs or skip invisible column
//   ROM_WAIT0  -> wait for rom_ok (half 0)
//   ROM_WR0    -> write half-0 pixels; issue half-1
//   ROM_WAIT1  -> wait for rom_ok (half 1)
//   ROM_WR1    -> write half-1 pixels; advance column or next entry
//   DONE       -> wait for hblank end
// =============================================================================

typedef enum logic [3:0] {
    IDLE       = 4'd0,
    SCAN_LOAD0 = 4'd3,
    LOAD_W0    = 4'd4,
    LOAD_W1    = 4'd5,
    LOAD_W2    = 4'd6,
    LOAD_W3    = 4'd7,
    TILE_VIS   = 4'd8,
    ROM_REQ    = 4'd9,
    ROM_WAIT0  = 4'd10,
    ROM_WR0    = 4'd11,
    ROM_WAIT1  = 4'd12,
    ROM_WR1    = 4'd13,
    DONE       = 4'd14
} scan_state_t;

scan_state_t scan_state;

// -- Sprite entry decoded fields ----------------------------------------------
logic [8:0]  spr_x;
logic [8:0]  spr_y;
logic [15:0] spr_code;
logic [3:0]  spr_ny;
logic [3:0]  spr_nx;
logic        spr_flipy;
logic        spr_flipx;
logic [4:0]  spr_color;

// -- Scan state ---------------------------------------------------------------
logic [7:0]  scan_idx;

// -- Tile loop state ----------------------------------------------------------
// tile_row_b is pre-set to the visible tile row (row-jump optimization).
// tile_col iterates 0..spr_nx for that row only.
logic [3:0]  tile_col;
logic [3:0]  tile_row_b;
logic        tile_visible;
logic [3:0]  tile_vsub;
logic [15:0] tile_code_r;
logic [8:0]  tile_px;

// -- ROM pipeline -------------------------------------------------------------
logic [31:0] rom_latch;

// -- Vrender: target scanline for this hblank ---------------------------------
logic [8:0]  vrender;
always_comb begin
    if (vcount == 9'd261)
        vrender = 9'd0;
    else
        vrender = vcount + 9'd1;
end

// -- Shadow RAM combinational read --------------------------------------------
logic [9:0]  sram_addr;
logic [15:0] sram_rdata;
always_comb begin
    sram_rdata = obj_ram_shadow[sram_addr];
end

// -- hblank edge detector -----------------------------------------------------
logic hblank_n_prev;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_n_prev <= 1'b1;
    else        hblank_n_prev <= hblank_n;
end
logic hblank_start;
assign hblank_start = hblank_n_prev & ~hblank_n;

// hblank_end: safety guard — if asserted while rendering, stop immediately.
logic hblank_end;
assign hblank_end = hblank_n;

// -- Tile coordinate helpers (combinational) ----------------------------------

logic [3:0] eff_col;
always_comb begin
    if (spr_flipx) eff_col = spr_nx - tile_col;
    else           eff_col = tile_col;
end

logic [3:0] eff_row;
always_comb begin
    if (spr_flipy) eff_row = spr_ny - tile_row_b;
    else           eff_row = tile_row_b;
end

logic [8:0] cur_tile_x;
always_comb begin
    cur_tile_x = (spr_x + {1'b0, tile_col, 4'b0}) & 9'h1FF;
end

logic [8:0] cur_tile_y;
always_comb begin
    cur_tile_y = (spr_y + {1'b0, tile_row_b, 4'b0}) & 9'h1FF;
end

logic [8:0] vy_delta;
always_comb begin
    vy_delta = (vrender - cur_tile_y) & 9'h1FF;
end

logic cur_tile_vis;
always_comb begin
    cur_tile_vis = (vy_delta < 9'd16);
end

logic [3:0] cur_vsub;
always_comb begin
    if (spr_flipy) cur_vsub = vy_delta[3:0] ^ 4'hF;
    else           cur_vsub = vy_delta[3:0];
end

logic [15:0] cur_tile_code;
always_comb begin
    logic [3:0] base_nibble;
    logic [3:0] col_nibble;
    base_nibble   = spr_code[3:0];
    col_nibble    = base_nibble + eff_col;
    cur_tile_code = (spr_code & 16'hFFF0)
                  + {8'd0, eff_row, 4'd0}
                  + {12'd0, col_nibble};
end

// Last-column-in-row flag (used after row-jump: we only render one row)
logic last_col;
always_comb begin
    last_col = (tile_col == spr_nx);
end

// =============================================================================
// Main sprite scan state machine
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        scan_state   <= IDLE;
        sram_addr    <= 10'd0;
        scan_idx     <= 8'd0;
        spr_x        <= 9'd0;
        spr_y        <= 9'd0;
        spr_code     <= 16'd0;
        spr_ny       <= 4'd0;
        spr_nx       <= 4'd0;
        spr_flipy    <= 1'b0;
        spr_flipx    <= 1'b0;
        spr_color    <= 5'd0;
        tile_col     <= 4'd0;
        tile_row_b   <= 4'd0;
        tile_visible <= 1'b0;
        tile_vsub    <= 4'd0;
        tile_code_r  <= 16'd0;
        tile_px      <= 9'd0;
        rom_cs       <= 1'b0;
        rom_addr     <= 20'd0;
        rom_half     <= 1'b0;
        rom_latch    <= 32'd0;
    end else begin
        rom_cs <= 1'b0;

        case (scan_state)

            // ----------------------------------------------------------------
            // IDLE: Wait for hblank to begin.
            // BUG 3 FIX: Skip rendering when vrender >= VRENDER_MAX.
            // BUG 1 FIX: Use pre-computed frame_last_sprite from VBLANK FES.
            // ----------------------------------------------------------------
            IDLE: begin
                if (hblank_start) begin
                    if (vrender >= VRENDER_MAX) begin
                        // Vrender in vblank/overscan (240-261): skip rendering.
                        // Writing here would corrupt the wrong bank and leak
                        // pixels onto scanline 0.
                        scan_state <= DONE;
                    end else if (frame_empty_table) begin
                        // No valid sprites in table (entry 0 is terminator).
                        scan_state <= DONE;
                    end else begin
                        scan_idx   <= frame_last_sprite;
                        sram_addr  <= {frame_last_sprite, 2'b00};
                        scan_state <= SCAN_LOAD0;
                    end
                end
            end

            // Present word-0 address, pipeline through word reads
            SCAN_LOAD0: begin
                sram_addr  <= {scan_idx, 2'b00};
                scan_state <= LOAD_W0;
            end

            // Latch X (word 0)
            LOAD_W0: begin
                spr_x      <= sram_rdata[8:0];
                sram_addr  <= {scan_idx, 2'b01};
                scan_state <= LOAD_W1;
            end

            // Latch Y (word 1)
            LOAD_W1: begin
                spr_y      <= sram_rdata[8:0];
                sram_addr  <= {scan_idx, 2'b10};
                scan_state <= LOAD_W2;
            end

            // Latch CODE (word 2)
            LOAD_W2: begin
                spr_code   <= sram_rdata;
                sram_addr  <= {scan_idx, 2'b11};
                scan_state <= LOAD_W3;
            end

            // ----------------------------------------------------------------
            // Latch ATTR (word 3), apply flip_screen, decode block dimensions.
            // BUG 2 FIX (Row-jump optimization):
            //   Compute block_vy_delta = (vrender - eff_y) mod 512.
            //   If >= (ny+1)*16: no tile row covers vrender -> skip sprite.
            //   Otherwise: vis_row = block_vy_delta >> 4. Set tile_row_b to
            //   vis_row, bypassing iteration through invisible rows.
            // ----------------------------------------------------------------
            LOAD_W3: begin
                begin
                    logic [8:0]  ex, ey;
                    logic [8:0]  block_vy;
                    logic [7:0]  block_height;  // (ny+1)*16, max 256
                    logic [3:0]  vis_row;
                    logic        spr_has_vis;
                    logic [3:0]  attr_ny;
                    logic [3:0]  attr_nx;
                    logic        attr_fy, attr_fx;
                    logic [4:0]  attr_col;

                    // Decode ATTR fields
                    attr_ny  = sram_rdata[15:12];
                    attr_nx  = sram_rdata[11:8];
                    attr_fy  = flip_screen ? ~sram_rdata[6] : sram_rdata[6];
                    attr_fx  = flip_screen ? ~sram_rdata[5] : sram_rdata[5];
                    attr_col = sram_rdata[4:0];

                    // Apply flip_screen coordinate transform
                    if (flip_screen) begin
                        ex = 9'(10'd496 - {1'b0, spr_x});
                        ey = 9'(10'd240 - {1'b0, spr_y});
                    end else begin
                        ex = spr_x;
                        ey = spr_y;
                    end

                    // Row-jump: compute which tile row covers vrender
                    block_vy     = (vrender - ey) & 9'h1FF;
                    block_height = {4'd0, attr_ny} + 8'd1;  // (ny+1) in tiles
                    // block_height in pixels = block_height * 16, max 256
                    // block_vy < block_height*16 iff tile_row visible
                    // block_height*16 fits in 8 bits (max 256), block_vy is 9 bits.
                    // Compare block_vy[8:4] (tile count) against block_height:
                    //   if block_vy >= 256 or block_vy[7:4] >= block_height -> invisible
                    spr_has_vis  = ({3'b0, block_vy} < {block_height, 4'b0000});
                    vis_row      = block_vy[7:4];   // tile row index (0..15)

                    // Store decoded fields
                    spr_x        <= ex;
                    spr_y        <= ey;
                    spr_ny       <= attr_ny;
                    spr_nx       <= attr_nx;
                    spr_flipy    <= attr_fy;
                    spr_flipx    <= attr_fx;
                    spr_color    <= attr_col;
                    tile_col     <= 4'd0;
                    tile_row_b   <= vis_row;    // jump directly to visible row

                    if (spr_has_vis) begin
                        scan_state <= TILE_VIS;
                    end else begin
                        // No visible tile row for this sprite; skip to next entry
                        if (scan_idx == 8'd0) begin
                            scan_state <= DONE;
                        end else begin
                            scan_idx   <= scan_idx - 8'd1;
                            sram_addr  <= {(scan_idx - 8'd1), 2'b00};
                            scan_state <= SCAN_LOAD0;
                        end
                    end
                end
            end

            // ----------------------------------------------------------------
            // TILE_VIS: Compute tile parameters.
            // tile_row_b already points to the visible row.
            // BUG 2 FIX: hblank_end guard.
            // ----------------------------------------------------------------
            TILE_VIS: begin
                if (hblank_end) begin
                    scan_state <= DONE;
                end else begin
                    tile_visible <= cur_tile_vis;
                    tile_vsub    <= cur_vsub;
                    tile_code_r  <= cur_tile_code;
                    tile_px      <= cur_tile_x;
                    scan_state   <= ROM_REQ;
                end
            end

            // ROM_REQ: Issue ROM fetch or skip invisible tile
            ROM_REQ: begin
                if (hblank_end) begin
                    scan_state <= DONE;
                end else if (!tile_visible) begin
                    // This column is not visible (can happen at block edges).
                    // Advance to next column.
                    if (last_col) begin
                        // Done with this sprite's visible row
                        if (scan_idx == 8'd0) begin
                            scan_state <= DONE;
                        end else begin
                            scan_idx   <= scan_idx - 8'd1;
                            sram_addr  <= {(scan_idx - 8'd1), 2'b00};
                            scan_state <= SCAN_LOAD0;
                        end
                        tile_col <= 4'd0;
                    end else begin
                        tile_col   <= tile_col + 4'd1;
                        scan_state <= TILE_VIS;
                    end
                end else begin
                    // Issue half-0 fetch
                    rom_addr   <= {tile_code_r, tile_vsub};
                    rom_half   <= spr_flipx ? 1'b1 : 1'b0;
                    rom_cs     <= 1'b1;
                    scan_state <= ROM_WAIT0;
                end
            end

            // Wait for half-0 rom_ok
            ROM_WAIT0: begin
                rom_cs <= 1'b1;
                if (rom_ok) begin
                    rom_latch  <= rom_data;
                    scan_state <= ROM_WR0;
                end
            end

            // Write half-0 pixels; issue half-1 fetch
            ROM_WR0: begin
                begin
                    logic [8:0] px;
                    logic [3:0] pd;
                    for (int i = 0; i < 8; i++) begin
                        pd = rom_latch[i*4 +: 4];
                        if (spr_flipx)
                            px = (tile_px + 9'd7 - 9'(i)) & 9'h1FF;
                        else
                            px = (tile_px + 9'(i)) & 9'h1FF;
                        if (pd != 4'hF)
                            linebuf[back_bank][px] <= {spr_color, pd};
                    end
                end
                rom_addr   <= {tile_code_r, tile_vsub};
                rom_half   <= spr_flipx ? 1'b0 : 1'b1;
                rom_cs     <= 1'b1;
                scan_state <= ROM_WAIT1;
            end

            // Wait for half-1 rom_ok
            ROM_WAIT1: begin
                rom_cs <= 1'b1;
                if (rom_ok) begin
                    rom_latch  <= rom_data;
                    scan_state <= ROM_WR1;
                end
            end

            // ----------------------------------------------------------------
            // Write half-1 pixels; advance to next column or next entry.
            // BUG 2 FIX: hblank_end overflow guard.
            // Row-jump: after last_col, always go to next entry (not next row)
            // because there is only one visible row per sprite per hblank.
            // ----------------------------------------------------------------
            ROM_WR1: begin
                begin
                    logic [8:0] px;
                    logic [3:0] pd;
                    for (int i = 0; i < 8; i++) begin
                        pd = rom_latch[i*4 +: 4];
                        if (spr_flipx)
                            px = (tile_px + 9'd15 - 9'(i)) & 9'h1FF;
                        else
                            px = (tile_px + 9'd8 + 9'(i)) & 9'h1FF;
                        if (pd != 4'hF)
                            linebuf[back_bank][px] <= {spr_color, pd};
                    end
                end

                if (hblank_end) begin
                    scan_state <= DONE;
                end else if (last_col) begin
                    // Finished all columns of the visible tile row; next entry.
                    tile_col <= 4'd0;
                    if (scan_idx == 8'd0) begin
                        scan_state <= DONE;
                    end else begin
                        scan_idx   <= scan_idx - 8'd1;
                        sram_addr  <= {(scan_idx - 8'd1), 2'b00};
                        scan_state <= SCAN_LOAD0;
                    end
                end else begin
                    tile_col   <= tile_col + 4'd1;
                    scan_state <= TILE_VIS;
                end
            end

            // Wait for hblank end, then go idle
            DONE: begin
                if (hblank_n) begin
                    scan_state <= IDLE;
                end
            end

            default: scan_state <= IDLE;

        endcase
    end
end

// =============================================================================
// Line buffer readout: during active display, read front bank and output.
// Self-erasing: each position is cleared after readout.
// Active window: hblank_n=1, vblank_n=1, hcount in [64..447].
// =============================================================================
logic active_display;
always_comb begin
    active_display = hblank_n & vblank_n &
                     (hcount >= 9'd64) & (hcount <= 9'd447);
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        pixel_out   <= 9'h1FF;
        pixel_valid <= 1'b0;
    end else begin
        pixel_valid <= active_display;
        if (active_display) begin
            pixel_out               <= linebuf[front_bank][hcount];
            linebuf[front_bank][hcount] <= 9'h1FF;  // self-erase
        end else begin
            pixel_out <= 9'h1FF;
        end
    end
end

endmodule
