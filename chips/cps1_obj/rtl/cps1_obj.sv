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
//   - ROM fetch: 20-bit address, 32-bit data (8 pixels × 4bpp), two halves per tile row
//
// Display timing (8 MHz pixel clock):
//   Total width: 512 clocks/line, active: 384px (cols 64-447)
//   Total height: 262 lines, active: 224 (lines 0-239; vblank starts at 240)
//   Sprite rendering target: vrender = vcount + 1 (one line ahead)
//
// Reset: section5 synchronizer (async assert, synchronous deassert)
// Memory: section4b ifdef VERILATOR stub pattern
// Anti-patterns: AP-1 through AP-10 enforced
// =============================================================================

module cps1_obj #(
    parameter int MAX_SPRITES = 256    // sprite table entries (must be <= 256)
) (
    // ── Clock and reset ──────────────────────────────────────────────────────
    input  logic        clk,           // 8 MHz pixel clock
    input  logic        async_rst_n,   // raw async active-low reset

    // ── CPU bus interface (OBJ RAM writes) ───────────────────────────────────
    // Word-addressed. cpu_addr[9:0] selects one of 1024 16-bit words.
    // Assumes CPU writes synchronous to clk (jtframe single-clock model).
    input  logic [9:0]  cpu_addr,
    input  logic [15:0] cpu_data,
    input  logic        cpu_we,

    // ── Timing inputs from video controller ──────────────────────────────────
    input  logic [8:0]  hcount,        // horizontal pixel counter 0–511
    input  logic [8:0]  vcount,        // vertical line counter 0–261
    input  logic        hblank_n,      // active-low horizontal blank
    input  logic        vblank_n,      // active-low vertical blank (asserts at line 240)

    // ── Global video control ─────────────────────────────────────────────────
    input  logic        flip_screen,   // VIDEOCONTROL bit 15

    // ── ROM interface (B-board tile ROM) ─────────────────────────────────────
    output logic [19:0] rom_addr,      // {code[15:0], vsub[3:0]}
    output logic        rom_half,      // 0=left 8px half, 1=right 8px half
    output logic        rom_cs,        // chip-select: fetch active
    input  logic [31:0] rom_data,      // 8 pixels × 4bpp
    input  logic        rom_ok,        // data valid handshake

    // ── Line buffer output (to scene compositor) ─────────────────────────────
    output logic [8:0]  pixel_out,     // {pal[4:0], color[3:0]}; registered
    output logic        pixel_valid    // asserted during active display window
);

// ── Derived parameter ─────────────────────────────────────────────────────────
// Number of entries to scan (MAX_SPRITES capped at 256).
localparam int SPR_ENTRIES = (MAX_SPRITES > 256) ? 256 : MAX_SPRITES;

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
// OBJ RAM — live buffer (CPU-writeable, 1024 words × 16 bits = 2 KB)
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
// OBJ RAM — shadow buffer (sprite engine reads from here)
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

// DMA: copy live → shadow, one word per clock over 1024 clocks
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

// =============================================================================
// Ping-pong line buffers (two banks, each 512 × 9 bits)
// Bit layout: [8:4] = 5-bit palette selector, [3:0] = 4-bit color
// Transparent sentinel: 9'h1FF (all ones, color nibble = 4'hF)
// Back  bank: ~vcount[0]  → written during hblank for line (vcount+1)
// Front bank:  vcount[0]  → read during active display of line vcount
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
        if (lbinit_addr == 9'd511) begin
            lbinit_active <= 1'b0;
        end
        lbinit_addr <= lbinit_addr + 9'd1;
    end
end

// =============================================================================
// Sprite scan state machine
// Runs during hblank to fill the back line buffer for vrender.
//
// Scan order: from last valid entry down to entry 0.
// Lower-index entries write LAST → they are not overwritten → appear on top.
//
// States:
//   IDLE       → wait for hblank start
//   FIND0      → present ATTR address of entry 0 for find-end pass
//   FIND_STEP  → read ATTR; advance or record terminator
//   SCAN_LOAD0 → present word-0 address of current scan entry
//   LOAD_W0    → read word 0 (X)
//   LOAD_W1    → read word 1 (Y); apply flip_screen
//   LOAD_W2    → read word 2 (CODE)
//   LOAD_W3    → read word 3 (ATTR); decode; begin tile loop
//   TILE_VIS   → compute vsub and visibility for current tile
//   ROM_REQ    → assert rom_cs with half-0 address
//   ROM_WAIT0  → wait for rom_ok (half 0)
//   ROM_WR0    → write half-0 pixels; issue half-1
//   ROM_WAIT1  → wait for rom_ok (half 1)
//   ROM_WR1    → write half-1 pixels; advance tile or entry
//   DONE       → wait for hblank end
// =============================================================================

typedef enum logic [3:0] {
    IDLE       = 4'd0,
    FIND0      = 4'd1,
    FIND_STEP  = 4'd2,
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

// ── Sprite entry decoded fields ───────────────────────────────────────────────
logic [8:0]  spr_x;         // effective X (after flip_screen)
logic [8:0]  spr_y;         // effective Y (after flip_screen)
logic [15:0] spr_code;      // tile code
logic [3:0]  spr_ny;        // block height minus 1 (ATTR[15:12])
logic [3:0]  spr_nx;        // block width  minus 1 (ATTR[11:8])
logic        spr_flipy;     // ATTR[6], possibly inverted by flip_screen
logic        spr_flipx;     // ATTR[5], possibly inverted by flip_screen
logic [4:0]  spr_color;     // ATTR[4:0]

// ── Scan / find-end state ─────────────────────────────────────────────────────
logic [7:0]  find_idx;      // entry being examined in find-end pass
logic [7:0]  scan_idx;      // entry currently being rendered (counts down; starts at last valid)

// ── Tile loop state ───────────────────────────────────────────────────────────
logic [3:0]  tile_col;      // current tile column within block
logic [3:0]  tile_row_b;    // current tile row within block
logic        tile_visible;  // current tile covers vrender
logic [3:0]  tile_vsub;     // sub-row within tile (0..15)
logic [15:0] tile_code_r;   // computed tile code
logic [8:0]  tile_px;       // screen X of current tile

// ── ROM pipeline ──────────────────────────────────────────────────────────────
logic [31:0] rom_latch;     // latched ROM data for the current half

// ── Vrender: target scanline for this hblank ─────────────────────────────────
logic [8:0]  vrender;
always_comb begin
    if (vcount == 9'd261)
        vrender = 9'd0;
    else
        vrender = vcount + 9'd1;
end

// ── Shadow RAM combinational read ────────────────────────────────────────────
logic [9:0]  sram_addr;
logic [15:0] sram_rdata;
always_comb begin
    sram_rdata = obj_ram_shadow[sram_addr];
end

// ── hblank edge detector ──────────────────────────────────────────────────────
logic hblank_n_prev;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_n_prev <= 1'b1;
    else        hblank_n_prev <= hblank_n;
end
logic hblank_start;
assign hblank_start = hblank_n_prev & ~hblank_n;  // one-cycle pulse

// ── Tile coordinate helpers (combinational, used inside always_ff) ─────────────
// These are wires computed from current sprite state and tile loop counters.
// They are used only during TILE_VIS state to compute visibility and write
// the registered state for the ROM fetch states.

// effective column index within the block (respecting FLIPX)
logic [3:0] eff_col;
always_comb begin
    if (spr_flipx)
        eff_col = spr_nx - tile_col;
    else
        eff_col = tile_col;
end

// effective row index within the block (respecting FLIPY)
logic [3:0] eff_row;
always_comb begin
    if (spr_flipy)
        eff_row = spr_ny - tile_row_b;
    else
        eff_row = tile_row_b;
end

// screen X of current tile: spr_x + tile_col * 16, mod 512
logic [8:0] cur_tile_x;
always_comb begin
    cur_tile_x = (spr_x + {1'b0, tile_col, 4'b0}) & 9'h1FF;
end

// screen Y of current tile: spr_y + tile_row_b * 16, mod 512
logic [8:0] cur_tile_y;
always_comb begin
    cur_tile_y = (spr_y + {1'b0, tile_row_b, 4'b0}) & 9'h1FF;
end

// vertical visibility check: (vrender - cur_tile_y) mod 512 < 16
logic [8:0] vy_delta;
always_comb begin
    vy_delta = (vrender - cur_tile_y) & 9'h1FF;
end
logic cur_tile_vis;
always_comb begin
    cur_tile_vis = (vy_delta < 9'd16);
end

// vsub: sub-row within tile, possibly flipped
logic [3:0] cur_vsub;
always_comb begin
    if (spr_flipy)
        cur_vsub = vy_delta[3:0] ^ 4'hF;
    else
        cur_vsub = vy_delta[3:0];
end

// tile code computation for current tile in block
// Lower nibble of CODE selects column position; rows offset by 0x10 each
logic [15:0] cur_tile_code;
always_comb begin
    logic [3:0] base_nibble;
    logic [3:0] col_nibble;
    base_nibble  = spr_code[3:0];
    col_nibble   = base_nibble + eff_col;  // 4-bit wrap (eff_col max = spr_nx <= 15)
    cur_tile_code = (spr_code & 16'hFFF0)
                  + {8'd0, eff_row, 4'd0}
                  + {12'd0, col_nibble};
end

// ── Last-tile-in-entry flag ───────────────────────────────────────────────────
logic last_tile;
always_comb begin
    last_tile = (tile_col == spr_nx) && (tile_row_b == spr_ny);
end

// =============================================================================
// Main sprite scan state machine
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        scan_state   <= IDLE;
        sram_addr    <= 10'd0;
        find_idx     <= 8'd0;
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
        // Default: deassert chip-select
        rom_cs <= 1'b0;

        case (scan_state)

            // ── Wait for hblank to begin ──────────────────────────────────
            IDLE: begin
                if (hblank_start) begin
                    // Begin find-end pass: present ATTR word of entry 0
                    find_idx  <= 8'd0;
                    sram_addr  <= 10'd3;  // word 3 of entry 0 = ATTR
                    scan_state <= FIND0;
                end
            end

            // ── Prime the find-end pass (addr presented, wait one cycle) ──
            FIND0: begin
                // Advance to FIND_STEP; data will be valid on FIND_STEP entry
                // because sram_rdata is combinational on sram_addr.
                // We check find_idx=0 here.
                scan_state <= FIND_STEP;
            end

            // ── Walk table finding terminator ─────────────────────────────
            // sram_rdata is ATTR of find_idx (combinational).
            FIND_STEP: begin
                if (sram_rdata[15:8] == 8'hFF) begin
                    // Terminator at find_idx: last valid = find_idx - 1
                    if (find_idx == 8'd0) begin
                        // Terminator at entry 0 → no sprites
                        scan_state <= DONE;
                    end else begin
                        scan_idx   <= find_idx - 8'd1;
                        // Load entry scan_idx = find_idx-1
                        sram_addr  <= {(find_idx - 8'd1), 2'b00};
                        scan_state <= SCAN_LOAD0;
                    end
                end else begin
                    // Valid entry; advance
                    if (find_idx == 8'(SPR_ENTRIES - 1)) begin
                        // Reached end of table, no terminator found
                        scan_idx   <= find_idx;
                        sram_addr  <= {find_idx, 2'b00};
                        scan_state <= SCAN_LOAD0;
                    end else begin
                        find_idx   <= find_idx + 8'd1;
                        sram_addr  <= {(find_idx + 8'd1), 2'b11};  // ATTR of next entry
                        scan_state <= FIND_STEP;
                    end
                end
            end

            // ── Present word-0 address, then pipeline through word reads ──
            SCAN_LOAD0: begin
                sram_addr  <= {scan_idx, 2'b00};
                scan_state <= LOAD_W0;
            end

            // ── Latch X (word 0) ──────────────────────────────────────────
            LOAD_W0: begin
                spr_x      <= sram_rdata[8:0];
                sram_addr  <= {scan_idx, 2'b01};
                scan_state <= LOAD_W1;
            end

            // ── Latch Y (word 1) ──────────────────────────────────────────
            LOAD_W1: begin
                spr_y      <= sram_rdata[8:0];
                sram_addr  <= {scan_idx, 2'b10};
                scan_state <= LOAD_W2;
            end

            // ── Latch CODE (word 2) ───────────────────────────────────────
            LOAD_W2: begin
                spr_code   <= sram_rdata;
                sram_addr  <= {scan_idx, 2'b11};
                scan_state <= LOAD_W3;
            end

            // ── Latch ATTR (word 3), apply flip_screen, init tile loop ────
            LOAD_W3: begin
                begin
                    logic [8:0] ex, ey;
                    // Flip-screen coordinate transform
                    if (flip_screen) begin
                        // 10-bit subtraction: 512 - 16 - x; result is 9 bits
                        ex = 9'(10'd496 - {1'b0, spr_x});
                        ey = 9'(10'd240 - {1'b0, spr_y});
                    end else begin
                        ex = spr_x;
                        ey = spr_y;
                    end
                    spr_x     <= ex;
                    spr_y     <= ey;
                end
                spr_ny    <= sram_rdata[15:12];
                spr_nx    <= sram_rdata[11:8];
                spr_flipy <= flip_screen ? ~sram_rdata[6] : sram_rdata[6];
                spr_flipx <= flip_screen ? ~sram_rdata[5] : sram_rdata[5];
                spr_color <= sram_rdata[4:0];
                tile_col   <= 4'd0;
                tile_row_b <= 4'd0;
                scan_state <= TILE_VIS;
            end

            // ── Compute visibility and tile params for current tile ────────
            TILE_VIS: begin
                tile_visible <= cur_tile_vis;
                tile_vsub    <= cur_vsub;
                tile_code_r  <= cur_tile_code;
                tile_px      <= cur_tile_x;
                scan_state   <= ROM_REQ;
            end

            // ── Issue ROM fetch (half 0) or skip invisible tile ───────────
            ROM_REQ: begin
                if (!tile_visible) begin
                    // Skip this tile; advance counter
                    if (last_tile) begin
                        if (scan_idx == 8'd0) begin
                            scan_state <= DONE;
                        end else begin
                            scan_idx   <= scan_idx - 8'd1;
                            sram_addr  <= {(scan_idx - 8'd1), 2'b00};
                            scan_state <= SCAN_LOAD0;
                        end
                        tile_col   <= 4'd0;
                        tile_row_b <= 4'd0;
                    end else if (tile_col == spr_nx) begin
                        tile_col   <= 4'd0;
                        tile_row_b <= tile_row_b + 4'd1;
                        scan_state <= TILE_VIS;
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

            // ── Wait for half-0 rom_ok ────────────────────────────────────
            ROM_WAIT0: begin
                rom_cs <= 1'b1;
                if (rom_ok) begin
                    rom_latch  <= rom_data;
                    scan_state <= ROM_WR0;
                end
            end

            // ── Write half-0 pixels; issue half-1 fetch ───────────────────
            ROM_WR0: begin
                begin
                    // Write 8 pixels from rom_latch into back line buffer.
                    // pixel[i] = rom_latch[i*4 +: 4], pixel 0 = leftmost in half.
                    //
                    // When flipx=0: half-0 is left half (pixels 0-7 of tile).
                    //   pixel i → screen x = tile_px + i.
                    //
                    // When flipx=1: half-0 is right half (pixels 8-15, fetched first).
                    //   For full-tile horizontal reversal:
                    //   pixel[8+i] (i=0..7) should appear at screen tile_px + (7-i).
                    //   i.e. pixel[8] → tile_px+7, pixel[15] → tile_px+0.
                    logic [8:0] px;
                    logic [3:0] pd;

                    for (int i = 0; i < 8; i++) begin
                        pd = rom_latch[i*4 +: 4];
                        if (spr_flipx) begin
                            // Right half fetched first; pixel 8+i → x = tile_px + 7 - i
                            px = (tile_px + 9'd7 - 9'(i)) & 9'h1FF;
                        end else begin
                            // Left half; pixel i → x = tile_px + i
                            px = (tile_px + 9'(i)) & 9'h1FF;
                        end
                        if (pd != 4'hF) begin
                            linebuf[back_bank][px] <= {spr_color, pd};
                        end
                    end
                end
                // Issue half-1 fetch
                rom_addr   <= {tile_code_r, tile_vsub};
                rom_half   <= spr_flipx ? 1'b0 : 1'b1;
                rom_cs     <= 1'b1;
                scan_state <= ROM_WAIT1;
            end

            // ── Wait for half-1 rom_ok ────────────────────────────────────
            ROM_WAIT1: begin
                rom_cs <= 1'b1;
                if (rom_ok) begin
                    rom_latch  <= rom_data;
                    scan_state <= ROM_WR1;
                end
            end

            // ── Write half-1 pixels; advance tile/entry ───────────────────
            ROM_WR1: begin
                begin
                    logic [8:0] px;
                    logic [3:0] pd;

                    for (int i = 0; i < 8; i++) begin
                        pd = rom_latch[i*4 +: 4];
                        if (spr_flipx) begin
                            // Left half (second fetch, pixels 0-7); pixel i → x = tile_px + 15 - i
                            // i.e. pixel[0] → tile_px+15, pixel[7] → tile_px+8
                            px = (tile_px + 9'd15 - 9'(i)) & 9'h1FF;
                        end else begin
                            // Right half; pixel i → x = tile_px + 8 + i
                            px = (tile_px + 9'd8 + 9'(i)) & 9'h1FF;
                        end
                        if (pd != 4'hF) begin
                            linebuf[back_bank][px] <= {spr_color, pd};
                        end
                    end
                end

                // Advance tile counter
                if (last_tile) begin
                    tile_col   <= 4'd0;
                    tile_row_b <= 4'd0;
                    if (scan_idx == 8'd0) begin
                        scan_state <= DONE;
                    end else begin
                        scan_idx   <= scan_idx - 8'd1;
                        sram_addr  <= {(scan_idx - 8'd1), 2'b00};
                        scan_state <= SCAN_LOAD0;
                    end
                end else if (tile_col == spr_nx) begin
                    tile_col   <= 4'd0;
                    tile_row_b <= tile_row_b + 4'd1;
                    scan_state <= TILE_VIS;
                end else begin
                    tile_col   <= tile_col + 4'd1;
                    scan_state <= TILE_VIS;
                end
            end

            // ── Wait for hblank end, then go idle ─────────────────────────
            DONE: begin
                if (hblank_n) begin
                    scan_state <= IDLE;
                end
            end

            default: begin
                scan_state <= IDLE;
            end

        endcase
    end
end

// =============================================================================
// Line buffer readout: during active display, read front bank and output.
// Each pixel position is self-erased (written to 9'h1FF) after readout.
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
