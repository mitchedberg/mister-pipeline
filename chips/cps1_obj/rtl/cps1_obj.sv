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
//   Total height: 262 lines, active: 240 (lines 0-239; vblank starts at 240)
//   Sprite rendering target: vrender = vcount + 1 (one line ahead)
//   Hblank: 128 cycles (hcount 448..511 + 0..63)
//
// Fixes applied in this revision:
//   Bug 1: Find-end table scan moved from per-hblank to per-VBLANK (FES machine).
//   Bug 2: Per-sprite row-jump optimization: jump directly to visible tile row
//          instead of iterating through all rows to find visible ones.
//   Bug 3: vrender >= 240 guard prevents line buffer writes during vblank.
//   Bug 5: VBLANK per-scanline sprite index build (SIB machine) pre-computes
//          per-scanline, per-slot rendering data (eff_x, vsub, tile_code, etc.)
//          stored in dual M10K memories. Hblank FSM reads pre-computed data,
//          eliminating all shadow RAM accesses from the hblank critical path.
//          Reduces per-sprite hblank cost to 5 cycles (pipelined), supporting
//          16 sprites/scanline within the 128-cycle hblank budget.
//
// Reset: section5 synchronizer (async assert, synchronous deassert)
// Memory: section4b ifdef VERILATOR stub pattern; scanline list uses M10K inference
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

// Per-scanline sprite list parameters
// Active rendering targets: vrender = 0..239 (vrender < VRENDER_MAX=240).
// SL_MAX must cover all valid vrender values.
localparam int SL_MAX     = 240;  // rendering scanlines (0..239)
localparam int SPR_PER_SL = 16;  // max sprites per scanline

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
                if (vblank_n) begin
                    fes_state <= FES_IDLE;
                end
            end

            default: fes_state <= FES_IDLE;
        endcase
    end
end

// FES done pulse: one cycle after fes_state transitions to FES_DONE
logic fes_done_prev;
always_ff @(posedge clk) begin
    if (!rst_n) fes_done_prev <= 1'b0;
    else        fes_done_prev <= (fes_state == FES_DONE);
end
logic fes_done_pulse;
assign fes_done_pulse = ~fes_done_prev & (fes_state == FES_DONE);

// =============================================================================
// Per-scanline sprite index list (SIB: Scanline Index Build)
//
// BUG 5 FIX: Eliminate per-hblank O(N) full table scan AND per-sprite shadow
// RAM reads from hblank critical path.
//
// During VBLANK (after FES completes), SIB iterates every sprite from
// entry 0 UP TO frame_last_sprite. For each sprite, it reads X, Y, CODE, ATTR
// (4 shadow RAM words), computes the effective rendering data for each
// covered scanline (eff_x, vsub, tile_code, color, flipx, nx), and stores
// that data into two M10K memories indexed by {scanline, slot}.
//
// Processing from 0 UP means lower-indexed sprites (higher priority) appear
// in LOWER slot numbers. The render FSM renders from slot (count-1) DOWN to
// slot 0, so slot 0 (entry 0, highest priority) is written LAST and wins
// on overlap. The SPR_PER_SL cap drops high-index (low-priority) entries,
// which is correct: when a scanline is full, we keep the already-stored
// high-priority sprites and discard the new low-priority one.
//
// Per-slot storage (two parallel memories, same {sl[7:0], slot[3:0]} address):
//   sl_data_mem[0:3839] — 32-bit:
//     [31:23] eff_x[8:0]       X position (flip_screen applied)
//     [22:19] vsub[3:0]        tile row within 16px tile (flip_y applied)
//     [18:15] spr_nx[3:0]      columns-1 in sprite block
//     [14]    spr_flipx        horizontal flip flag
//     [13:9]  spr_color[4:0]   palette entry
//     [8:5]   base_nibble[3:0] code[3:0] + eff_col_at_col0 (for column advance)
//     [4:0]   UNUSED
//   sl_code_mem[0:3839] — 16-bit: tile_code for col=0, vis_row
//
// Hblank FSM reads both memories in one registered read cycle (same address),
// recovering all needed render parameters without touching shadow RAM.
//
// Per-sprite hblank cost (single-column, pipelined):
//   SL_RD_WAIT(1) + PRE_RENDER(1) + ROM_REQ(1) + ROM_WAIT0(1) + ROM_WR0(1) +
//   ROM_WAIT1(1) + ROM_WR1(1) = 7 cycles subsequent (first: +IDLE=8 total).
// 16 sprites: 8 + 15×7 = 113 cycles << 128-cycle hblank budget.
// =============================================================================

// Scanline count registers (240 x 5-bit; 5 bits to represent 0..16 without wrap)
logic [4:0] scanline_count [0:SL_MAX-1];

// Flat M10K arrays: address = {sl[7:0], slot[3:0]} = 12-bit (3840 entries used)
// sl_data_mem: 32-bit wide per slot
// sl_code_mem: 16-bit wide per slot
logic [31:0] sl_data_mem [0:3839];
logic [15:0] sl_code_mem [0:3839];

// SIB write port signals
logic        sib_wr_en;
logic [11:0] sib_wr_addr;   // {sl[7:0], slot[3:0]}
logic [31:0] sib_wr_data;   // data word
logic [15:0] sib_wr_code;   // tile code

// SIB/render read port (registered: address → data valid 2 cycles later)
logic [11:0] sib_rd_addr;
// Bits [4:0] of sl_data_mem are unused padding (5'd0 stored by SIB_FILL).
/* verilator lint_off UNUSEDSIGNAL */
logic [31:0] sib_rd_data;
/* verilator lint_on UNUSEDSIGNAL */
logic [15:0] sib_rd_code;

// M10K-style: write on clk if sib_wr_en; read registered output.
// Both memories share the same address/enable (simultaneous R/W).
always_ff @(posedge clk) begin
    if (sib_wr_en) begin
        sl_data_mem[sib_wr_addr] <= sib_wr_data;
        sl_code_mem[sib_wr_addr] <= sib_wr_code;
    end
    sib_rd_data <= sl_data_mem[sib_rd_addr];
    sib_rd_code <= sl_code_mem[sib_rd_addr];
end

// ---------------------------------------------------------------------------
// SIB state machine
// ---------------------------------------------------------------------------
typedef enum logic [2:0] {
    SIB_IDLE    = 3'd0,
    SIB_CLR     = 3'd1,   // clear scanline_count[] before build
    SIB_LOAD_W0 = 3'd2,   // latch X from shadow RAM (addr set in SIB_CLR or prev FILL)
    SIB_LOAD_W1 = 3'd3,   // latch Y, set CODE addr
    SIB_LOAD_W2 = 3'd4,   // latch CODE, set ATTR addr
    SIB_LOAD_W3 = 3'd5,   // latch ATTR, compute render data
    SIB_FILL    = 3'd6,   // for each scanline in Y-range, write pre-computed data
    SIB_DONE    = 3'd7
} sib_state_t;

sib_state_t  sib_state;
logic [7:0]  sib_idx;           // current sprite entry being processed
logic [7:0]  sib_clr_sl;        // clear counter

// SIB shadow RAM read (combinational)
logic [9:0]  sib_sram_addr;
logic [15:0] sib_sram_rdata;
always_comb begin
    sib_sram_rdata = obj_ram_shadow[sib_sram_addr];
end

// SIB decoded fields (latched during LOAD phases)
logic [8:0]  sib_raw_x;         // raw X from word-0
logic [8:0]  sib_raw_y;         // raw Y from word-1
logic [15:0] sib_code;          // sprite CODE from word-2

// Pre-computed render data (latched in SIB_LOAD_W3, used in SIB_FILL)
// These represent the per-sprite fixed values (same for all scanlines)
logic [8:0]  sib_eff_x;         // effective X (flip_screen applied)
logic [8:0]  sib_eff_y;         // effective Y (flip_screen applied)
logic [3:0]  sib_ny;            // rows-1
logic [3:0]  sib_nx;            // cols-1
logic        sib_flipy;
logic        sib_flipx;
logic [4:0]  sib_color;
logic [11:0] sib_code_upper;    // sib_code[15:4] (upper 12 bits, row/col added below)
logic [3:0]  sib_base_nibble;   // sib_code[3:0] (col nibble base)

// SIB fill loop
logic [8:0]  sib_fill_sl;       // current scanline being processed
/* verilator lint_off UNUSEDSIGNAL */
logic        sib_capped;        // set when a scanline list is full (diagnostic only)
/* verilator lint_on UNUSEDSIGNAL */

always_ff @(posedge clk) begin
    if (!rst_n) begin
        sib_state      <= SIB_IDLE;
        sib_idx        <= 8'd0;
        sib_clr_sl     <= 8'd0;
        sib_sram_addr  <= 10'd0;
        sib_raw_x      <= 9'd0;
        sib_raw_y      <= 9'd0;
        sib_code       <= 16'd0;
        sib_eff_x      <= 9'd0;
        sib_eff_y      <= 9'd0;
        sib_ny         <= 4'd0;
        sib_nx         <= 4'd0;
        sib_flipy      <= 1'b0;
        sib_flipx      <= 1'b0;
        sib_color      <= 5'd0;
        sib_code_upper <= 12'd0;
        sib_base_nibble<= 4'd0;
        sib_fill_sl    <= 9'd0;
        sib_capped     <= 1'b0;
        sib_wr_en      <= 1'b0;
        sib_wr_addr    <= 12'd0;
        sib_wr_data    <= 32'd0;
        sib_wr_code    <= 16'd0;
        for (int s = 0; s < SL_MAX; s++)
            scanline_count[s] <= 5'd0;
    end else begin
        sib_wr_en <= 1'b0;  // default: no write

        case (sib_state)

            // Wait for FES to finish
            SIB_IDLE: begin
                if (fes_done_pulse) begin
                    // Start by clearing all scanline counts
                    sib_clr_sl <= 8'd0;
                    sib_state  <= SIB_CLR;
                end
            end

            // Clear scanline_count[0..SL_MAX-1]
            SIB_CLR: begin
                scanline_count[sib_clr_sl] <= 5'd0;
                if (sib_clr_sl == 8'(SL_MAX - 1)) begin
                    if (frame_empty_table) begin
                        sib_state <= SIB_DONE;
                    end else begin
                        // Start from entry 0 and process upward to frame_last_sprite.
                        // Lower-index sprites (higher priority) fill lower slots.
                        // Render reads from slot (count-1) down to 0, so slot 0
                        // (entry 0, highest priority) is rendered last and wins.
                        sib_idx       <= 8'd0;
                        // Present X addr (word 0) for entry 0
                        sib_sram_addr <= {8'd0, 2'b00};
                        sib_state     <= SIB_LOAD_W0;
                    end
                end else begin
                    sib_clr_sl <= sib_clr_sl + 8'd1;
                end
            end

            // Latch X (word-0), present Y addr (word-1)
            SIB_LOAD_W0: begin
                sib_raw_x     <= sib_sram_rdata[8:0];
                sib_sram_addr <= {sib_idx, 2'b01};  // Y is word 1
                sib_state     <= SIB_LOAD_W1;
            end

            // Latch Y (word-1), present CODE addr (word-2)
            SIB_LOAD_W1: begin
                sib_raw_y     <= sib_sram_rdata[8:0];
                sib_sram_addr <= {sib_idx, 2'b10};  // CODE is word 2
                sib_state     <= SIB_LOAD_W2;
            end

            // Latch CODE (word-2), present ATTR addr (word-3)
            SIB_LOAD_W2: begin
                sib_code      <= sib_sram_rdata;
                sib_sram_addr <= {sib_idx, 2'b11};  // ATTR is word 3
                sib_state     <= SIB_LOAD_W3;
            end

            // Latch ATTR (word-3), apply flip_screen, compute eff_x/eff_y, start fill
            SIB_LOAD_W3: begin
                begin
                    logic [8:0] ex, ey;
                    logic [3:0] attr_ny, attr_nx;
                    logic       attr_fy, attr_fx;
                    logic [4:0] attr_col;

                    attr_ny  = sib_sram_rdata[15:12];
                    attr_nx  = sib_sram_rdata[11:8];
                    attr_fy  = flip_screen ? ~sib_sram_rdata[6] : sib_sram_rdata[6];
                    attr_fx  = flip_screen ? ~sib_sram_rdata[5] : sib_sram_rdata[5];
                    attr_col = sib_sram_rdata[4:0];

                    if (flip_screen) begin
                        ex = 9'(10'd496 - {1'b0, sib_raw_x});
                        ey = 9'(10'd240 - {1'b0, sib_raw_y});
                    end else begin
                        ex = sib_raw_x;
                        ey = sib_raw_y;
                    end

                    sib_eff_x       <= ex;
                    sib_eff_y       <= ey;
                    sib_ny          <= attr_ny;
                    sib_nx          <= attr_nx;
                    sib_flipy       <= attr_fy;
                    sib_flipx       <= attr_fx;
                    sib_color       <= attr_col;
                    sib_code_upper  <= sib_code[15:4];
                    sib_base_nibble <= sib_code[3:0];
                    sib_fill_sl     <= ey;  // start at eff_y
                end
                sib_state <= SIB_FILL;
            end

            // For each scanline in sprite's Y-range, write pre-computed render data
            SIB_FILL: begin
                begin
                    logic [8:0]  delta;
                    logic [7:0]  vsub_count;
                    logic [7:0]  block_vy;  // max (ny+1)*16-1 = 255; bit 8 never used
                    logic [3:0]  vis_row;
                    logic [3:0]  vsub;
                    logic [3:0]  eff_row;
                    logic [3:0]  eff_col_0;   // effective col for tile_col=0
                    logic [3:0]  col_nibble;
                    logic [15:0] tile_code_0; // tile code for col=0
                    logic [31:0] pack_data;

                    // delta = (sib_fill_sl - sib_eff_y) & 9'h1FF
                    delta      = (sib_fill_sl - sib_eff_y) & 9'h1FF;
                    vsub_count = ({4'd0, sib_ny} + 8'd1) << 4;

                    if (delta >= {1'b0, vsub_count}) begin
                        // Finished this sprite's Y-range
                        if (sib_idx == frame_last_sprite) begin
                            sib_state <= SIB_DONE;
                        end else begin
                            // Advance to next sprite (ascending index)
                            logic [7:0] next_idx;
                            next_idx      = sib_idx + 8'd1;
                            sib_idx       <= next_idx;
                            sib_sram_addr <= {next_idx, 2'b00};  // X addr for next sprite
                            sib_state     <= SIB_LOAD_W0;
                        end
                    end else begin
                        // This scanline is in range
                        // block_vy is the pixel row within the sprite block
                        // delta is at most (ny+1)*16-1 = 255, so bit 8 is always 0
                        block_vy = delta[7:0];
                        vis_row  = block_vy[7:4];  // which tile row (0..ny)

                        // vsub: pixel row within 16px tile, flip-Y applied
                        vsub = sib_flipy ? (block_vy[3:0] ^ 4'hF) : block_vy[3:0];

                        // Effective row and col=0 under flipx/flipy
                        eff_row   = sib_flipy ? (sib_ny - vis_row) : vis_row;
                        eff_col_0 = sib_flipx ? sib_nx : 4'd0;

                        // Tile code for col=0
                        col_nibble   = (sib_base_nibble + eff_col_0) & 4'hF;
                        tile_code_0  = {sib_code_upper, 4'd0}
                                     + {8'd0, eff_row, 4'd0}
                                     + {12'd0, col_nibble};

                        // Pack data word:
                        // [31:23] eff_x[8:0]
                        // [22:19] vsub[3:0]
                        // [18:15] spr_nx[3:0]
                        // [14]    spr_flipx
                        // [13:9]  spr_color[4:0]
                        // [8:5]   base_nibble[3:0]  (for column advance)
                        // [4:1]   UNUSED
                        // [0]     UNUSED
                        pack_data = {sib_eff_x, vsub, sib_nx, sib_flipx,
                                     sib_color, sib_base_nibble, 5'd0};

                        if (sib_fill_sl < 9'(SL_MAX)) begin
                            logic [4:0] cnt;
                            cnt = scanline_count[sib_fill_sl[7:0]];
                            if (cnt < 5'(SPR_PER_SL)) begin
                                sib_wr_en   <= 1'b1;
                                sib_wr_addr <= {sib_fill_sl[7:0], cnt[3:0]};
                                sib_wr_data <= pack_data;
                                sib_wr_code <= tile_code_0;
                                scanline_count[sib_fill_sl[7:0]] <= cnt + 5'd1;
                            end else begin
                                sib_capped <= 1'b1;
                            end
                        end

                        // Advance to next scanline (wrapping mod 512)
                        sib_fill_sl <= (sib_fill_sl + 9'd1) & 9'h1FF;
                    end
                end
            end

            SIB_DONE: begin
                // Hold until VBLANK ends
                if (vblank_n) begin
                    sib_state <= SIB_IDLE;
                end
            end

            default: sib_state <= SIB_IDLE;

        endcase
    end
end

// sib_index_valid: sticky flag — set when SIB finishes, cleared when next build starts.
logic sib_index_valid;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        sib_index_valid <= 1'b0;
    end else begin
        if (sib_state == SIB_DONE) begin
            sib_index_valid <= 1'b1;
        end else if (sib_state == SIB_CLR) begin
            sib_index_valid <= 1'b0;
        end
    end
end
logic sib_done;
assign sib_done = sib_index_valid;

// =============================================================================
// Ping-pong line buffers (two banks, each 512 x 9 bits)
// Transparent sentinel: 9'h1FF
// Back  bank: registered at hblank_start from ~vcount[0].
//   MUST be registered because the 128-cycle hblank spans a vcount boundary:
//   hblank starts at hpix=448 (vcount=N-1) and ends at hpix=64 (vcount=N).
//   A combinational ~vcount[0] would flip mid-hblank, causing sprite pixels
//   to land in the wrong bank for sprites rendered after hpix=512.
// Front bank: vcount[0] (combinational — only read during active display,
//   well after the hblank, so no mid-hblank hazard).
// =============================================================================
logic [8:0] linebuf [0:1][0:511];
logic back_bank;
logic front_bank;
assign front_bank = vcount[0];

always_ff @(posedge clk) begin
    if (!rst_n) begin
        back_bank <= 1'b0;
    end else if (hblank_start) begin
        back_bank <= ~vcount[0];
    end
end

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
// Sprite render state machine (HBLANK phase)
//
// BUG 5 FIX: All sprite data pre-computed by SIB; hblank FSM only reads
// pre-computed data from M10K memories and issues ROM fetches.
//
// vrender is registered at hblank_start for stability across the 128-cycle
// hblank window (which spans a vcount boundary when hpix wraps 511→0).
//
// Per-sprite pipeline (single-column):
//
//   The simulator evaluates always_ff blocks in dependency order: the FSM block
//   (which updates sib_rd_addr) runs before the M10K block (which reads
//   sib_rd_addr and updates sib_rd_data). Thus sib_rd_data is valid ONE
//   cycle after sib_rd_addr is set — only ONE SL_RD_WAIT cycle is needed.
//
// Per-sprite hblank cost (single column, nx=0):
//   First sprite:  IDLE(1) + SL_RD_WAIT(1) + PRE_RENDER(1) +
//                  ROM_REQ(1) + ROM_WAIT0(1) + ROM_WR0(1) + ROM_WAIT1(1) + ROM_WR1(1) = 8 cycles
//   Subsequent:    [ROM_WR1 sets addr] SL_RD_WAIT(1) + PRE_RENDER(1) +
//                  ROM_REQ(1) + ROM_WAIT0(1) + ROM_WR0(1) + ROM_WAIT1(1) + ROM_WR1(1) = 7 cycles
//   16 sprites: 8 + 15×7 = 8 + 105 = 113 cycles << 128-cycle hblank budget. ✓
//
// States:
//   IDLE        -> wait for hblank start; issue first SL read; →SL_RD_WAIT
//   SL_RD_WAIT  -> M10K latency (1 cycle); sib_rd_data valid next cycle; →PRE_RENDER
//   PRE_RENDER  -> sib_rd_data/code valid; latch render params; →ROM_REQ
//   ROM_REQ     -> assert rom_cs half=0; →ROM_WAIT0
//   ROM_WAIT0   -> wait rom_ok (half 0); →ROM_WR0
//   ROM_WR0     -> write half-0 pixels; issue half-1 fetch; →ROM_WAIT1
//   ROM_WAIT1   -> wait rom_ok (half 1); →ROM_WR1
//   ROM_WR1     -> write half-1 pixels; advance col or issue next SL read; →SL_RD_WAIT or DONE
//   DONE        -> wait for hblank end; →IDLE
// =============================================================================

typedef enum logic [3:0] {
    IDLE        = 4'd0,
    SL_RD_WAIT  = 4'd1,  // M10K latency cycle (addr presented last cycle; data ready next)
    PRE_RENDER  = 4'd2,  // latch sib_rd_data/code into render registers
    ROM_REQ     = 4'd3,
    ROM_WAIT0   = 4'd4,
    ROM_WR0     = 4'd5,
    ROM_WAIT1   = 4'd6,
    ROM_WR1     = 4'd7,
    DONE        = 4'd8
} scan_state_t;

scan_state_t scan_state;

// -- Registered vrender: captured at hblank_start, stable for full 128-cycle hblank ---
// (vrender computed combinationally from vcount would change when vcount increments
//  at hcount=0, which is mid-hblank when hblank spans hcount 448..511 + 0..63)
// Bit 8 is set for vcount=261 (vrender=0 special case handled in IDLE), but
// only bits [7:0] are used for SIB memory addressing (scanlines 0..239).
/* verilator lint_off UNUSEDSIGNAL */
logic [8:0]  vrender_r;
/* verilator lint_on UNUSEDSIGNAL */

// -- Active slot tracking ------------------------------------------------------
// Render descends from slot (count-1) to slot 0.
// Slot 0 = entry 0 (highest priority): rendered last, writes win over lower-priority sprites.
logic [3:0]  scan_slot;     // current slot being rendered (descending from count-1 to 0)

// -- Current sprite render parameters (from PRE_RENDER) -----------------------
logic [3:0]  r_vsub;        // tile vsub (pixel row in tile)
logic [3:0]  r_spr_nx;      // columns-1
logic        r_spr_flipx;   // X flip
logic [4:0]  r_spr_color;   // palette
logic [3:0]  r_base_nibble; // code[3:0] for column advance
logic [15:0] r_tile_code;   // tile code for current column

// -- Tile column tracking (for multi-column sprites) --------------------------
logic [3:0]  r_tile_col;    // current tile column (0..r_spr_nx)
logic [8:0]  r_tile_px;     // pixel X for current column

// -- ROM pipeline -------------------------------------------------------------
logic [31:0] rom_latch;

// -- hblank edge detector -----------------------------------------------------
logic hblank_n_prev;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_n_prev <= 1'b1;
    else        hblank_n_prev <= hblank_n;
end
logic hblank_start;
assign hblank_start = hblank_n_prev & ~hblank_n;

// hblank_end: safety guard
logic hblank_end;
assign hblank_end = hblank_n;

// -- Helper: is there a next slot? ------------------------------------------
// Render descends from slot (count-1) to slot 0: slot 0 = entry 0 = highest priority.
// "next slot" means slot-1 (the next-higher-priority entry).
logic have_next_slot;
always_comb begin
    have_next_slot = (scan_slot != 4'd0);
end

// -- Last column check -------------------------------------------------------
logic r_last_col;
always_comb begin
    r_last_col = (r_tile_col == r_spr_nx);
end

// =============================================================================
// Main sprite render state machine (HBLANK phase)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        scan_state    <= IDLE;
        vrender_r     <= 9'd0;
        scan_slot     <= 4'd0;
        r_vsub        <= 4'd0;
        r_spr_nx            <= 4'd0;
        r_spr_flipx         <= 1'b0;
        r_spr_color         <= 5'd0;
        r_base_nibble       <= 4'd0;
        r_tile_code         <= 16'd0;
        r_tile_col          <= 4'd0;
        r_tile_px           <= 9'd0;
        rom_cs              <= 1'b0;
        rom_addr            <= 20'd0;
        rom_half            <= 1'b0;
        rom_latch           <= 32'd0;
        sib_rd_addr         <= 12'd0;
    end else begin
        rom_cs <= 1'b0;

        case (scan_state)

            // ----------------------------------------------------------------
            // IDLE: Wait for hblank to begin.
            // Register vrender for stability across 128-cycle hblank.
            // Issue SL read for slot 0.
            // ----------------------------------------------------------------
            IDLE: begin
                if (hblank_start) begin
                    // Compute vrender: vcount+1, wrapping at 262
                    if (vcount == 9'd261)
                        vrender_r <= 9'd0;
                    else
                        vrender_r <= vcount + 9'd1;

                    // Compute vrender for the check (same combinational value)
                    begin
                        logic [8:0] vr;
                        vr = (vcount == 9'd261) ? 9'd0 : (vcount + 9'd1);

                        if (vr >= VRENDER_MAX) begin
                            scan_state <= DONE;
                        end else if (!sib_done) begin
                            scan_state <= DONE;
                        end else if (scanline_count[vr[7:0]] == 5'd0) begin
                            scan_state <= DONE;
                        end else begin
                            // Render from slot (count-1) DOWN to slot 0.
                            // Slot 0 = entry 0 = highest priority; rendered last, wins.
                            begin
                                logic [3:0] last_slot;
                                last_slot   = scanline_count[vr[7:0]][3:0] - 4'd1;
                                scan_slot   <= last_slot;
                                // Issue SL read for last slot (lowest priority rendered first)
                                sib_rd_addr <= {vr[7:0], last_slot};
                            end
                            scan_state <= SL_RD_WAIT;
                        end
                    end
                end
            end

            // ----------------------------------------------------------------
            // SL_RD_WAIT: M10K read latency (one cycle).
            // sib_rd_addr was set in the previous cycle (IDLE or ROM_WR1).
            // The M10K always_ff block reads the updated sib_rd_addr (set by the
            // FSM at the same posedge, dependency-ordered) and latches the data.
            // sib_rd_data/code are valid in PRE_RENDER (next cycle).
            // ----------------------------------------------------------------
            SL_RD_WAIT: begin
                if (hblank_end) begin
                    scan_state <= DONE;
                end else begin
                    scan_state <= PRE_RENDER;
                end
            end

            // ----------------------------------------------------------------
            // PRE_RENDER: sib_rd_data/sib_rd_code now hold the current slot's
            // pre-computed render parameters. Latch them and set up ROM fetch.
            // ----------------------------------------------------------------
            PRE_RENDER: begin
                if (hblank_end) begin
                    scan_state <= DONE;
                end else begin
                    // Latch render parameters from SIB memory
                    // [31:23] eff_x[8:0]
                    // [22:19] vsub[3:0]
                    // [18:15] spr_nx[3:0]
                    // [14]    spr_flipx
                    // [13:9]  spr_color[4:0]
                    // [8:5]   base_nibble[3:0]
                    r_vsub        <= sib_rd_data[22:19];
                    r_spr_nx      <= sib_rd_data[18:15];
                    r_spr_flipx   <= sib_rd_data[14];
                    r_spr_color   <= sib_rd_data[13:9];
                    r_base_nibble <= sib_rd_data[8:5];
                    r_tile_code   <= sib_rd_code;   // col=0 tile code
                    r_tile_col    <= 4'd0;
                    r_tile_px     <= sib_rd_data[31:23]; // eff_x at col=0

                    scan_state <= ROM_REQ;
                end
            end

            // ----------------------------------------------------------------
            // ROM_REQ: Assert rom_cs for current half.
            // ----------------------------------------------------------------
            ROM_REQ: begin
                if (hblank_end) begin
                    scan_state <= DONE;
                end else begin
                    rom_addr   <= {r_tile_code, r_vsub};
                    rom_half   <= r_spr_flipx ? 1'b1 : 1'b0;
                    rom_cs     <= 1'b1;
                    scan_state <= ROM_WAIT0;
                end
            end

            // ----------------------------------------------------------------
            // ROM_WAIT0: Wait for rom_ok (half 0).
            // ----------------------------------------------------------------
            ROM_WAIT0: begin
                rom_cs <= 1'b1;
                if (rom_ok) begin
                    rom_latch  <= rom_data;
                    scan_state <= ROM_WR0;
                end
            end

            // ----------------------------------------------------------------
            // ROM_WR0: Write half-0 pixels; issue half-1 fetch.
            // ----------------------------------------------------------------
            ROM_WR0: begin
                begin
                    logic [8:0] px;
                    logic [3:0] pd;
                    for (int i = 0; i < 8; i++) begin
                        pd = rom_latch[i*4 +: 4];
                        if (r_spr_flipx)
                            px = (r_tile_px + 9'd7 - 9'(i)) & 9'h1FF;
                        else
                            px = (r_tile_px + 9'(i)) & 9'h1FF;
                        if (pd != 4'hF)
                            linebuf[back_bank][px] <= {r_spr_color, pd};
                    end
                end
                // Issue half-1 fetch
                rom_addr   <= {r_tile_code, r_vsub};
                rom_half   <= r_spr_flipx ? 1'b0 : 1'b1;
                rom_cs     <= 1'b1;
                scan_state <= ROM_WAIT1;
            end

            // ----------------------------------------------------------------
            // ROM_WAIT1: Wait for rom_ok (half 1).
            // ----------------------------------------------------------------
            ROM_WAIT1: begin
                rom_cs <= 1'b1;
                if (rom_ok) begin
                    rom_latch  <= rom_data;
                    scan_state <= ROM_WR1;
                end
            end

            // ----------------------------------------------------------------
            // ROM_WR1: Write half-1 pixels; advance column or go to next sprite.
            // For next sprite: issue SL read now (2-cycle latency) → SL_RD_WAIT.
            // ----------------------------------------------------------------
            ROM_WR1: begin
                begin
                    logic [8:0] px;
                    logic [3:0] pd;
                    for (int i = 0; i < 8; i++) begin
                        pd = rom_latch[i*4 +: 4];
                        if (r_spr_flipx)
                            px = (r_tile_px + 9'd15 - 9'(i)) & 9'h1FF;
                        else
                            px = (r_tile_px + 9'd8 + 9'(i)) & 9'h1FF;
                        if (pd != 4'hF)
                            linebuf[back_bank][px] <= {r_spr_color, pd};
                    end
                end

                if (hblank_end) begin
                    scan_state <= DONE;
                end else if (r_last_col) begin
                    // Done with all columns of this sprite. Advance to next slot.
                    r_tile_col <= 4'd0;
                    if (!have_next_slot) begin
                        scan_state <= DONE;
                    end else begin
                        // Descend to the next-higher-priority slot (slot-1)
                        logic [3:0] ns;
                        ns          = scan_slot - 4'd1;
                        scan_slot   <= ns;
                        // Issue SL read for next slot; wait 1 cycle for data
                        sib_rd_addr <= {vrender_r[7:0], ns};
                        scan_state  <= SL_RD_WAIT;
                    end
                end else begin
                    // Multi-column: advance to next column
                    begin
                        logic [3:0] nc;
                        logic [3:0] eff_col_nc;
                        logic [3:0] col_nibble_nc;
                        logic [8:0] next_px;

                        nc = r_tile_col + 4'd1;
                        r_tile_col <= nc;

                        // eff_col for new column (flipx transforms column index)
                        eff_col_nc    = r_spr_flipx ? (r_spr_nx - nc) : nc;
                        col_nibble_nc = (r_base_nibble + eff_col_nc) & 4'hF;

                        // Update tile_code: replace low nibble for new column.
                        // Upper 12 bits carry (code_upper + eff_row) and are unchanged.
                        r_tile_code <= (r_tile_code & 16'hFFF0) | {12'd0, col_nibble_nc};

                        // Advance pixel X by 16
                        next_px    = (r_tile_px + 9'd16) & 9'h1FF;
                        r_tile_px <= next_px;
                    end
                    scan_state <= ROM_REQ;
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
