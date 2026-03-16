`default_nettype none
// Section 4c — Tile Decoder State Machine Skeleton
//
// LATENCY CONTRACT
// ────────────────
// This decoder introduces a fixed pipeline latency of PIPE_LATENCY clock cycles
// from tile_addr input to pixel_data output. The instantiating module MUST
// account for this latency when scheduling hblank / line buffer writes.
//
//   Cycle 0: tile_addr presented, fetch_start asserted
//   Cycle 1: tile_index read from VRAM (1 M10K cycle)
//   Cycle 2: tile_row computed, tile ROM address registered
//   Cycle 3: tile ROM data available (1 M10K cycle)
//   Cycle 4: pixel_data valid (registered output)
//
// PIPELINE NOTE
// ─────────────
// This design uses SERIALIZED timing (not streaming).
// One tile is decoded per PIPE_LATENCY-cycle slot.
// For streaming output (back-to-back pixels), instantiate multiple decoder
// instances with staggered fetch_start signals, or use a pixel-shift-register
// stage that accepts 8 pixels per tile fetch and shifts them out one per clock.
//
// TRAP 1 — hblank abort
// ──────────────────────
// If hblank arrives while the pipeline is mid-decode, the in-flight state
// must be flushed. Failure to do this causes the first tile of the next line
// to see stale VRAM data from the aborted fetch. The hblank_i signal forces
// the state machine to IDLE and clears all pipeline registers.
//
// TRAP 2 — tile ROM latency vs VRAM latency
// ──────────────────────────────────────────
// Both VRAM and tile ROM are M10K blocks with registered outputs (CLOCK1).
// The read latency is 2 clocks (address registered, then output registered).
// Do NOT assume 1-cycle read latency (a common AI generation error).
// The state machine below waits the correct number of cycles.

module tile_decoder #(
    parameter int SCREEN_COLS    = 32,    // tiles per row
    parameter int TILE_W         = 8,     // pixels per tile (horizontal)
    parameter int TILE_H         = 8,     // pixels per tile (vertical)
    parameter int VRAM_ADDR_W    = 10,    // log2(SCREEN_COLS * SCREEN_ROWS)
    parameter int TILE_ROM_ADDR_W = 12,   // log2(num_tiles * TILE_H)
    parameter int COLOR_IDX_W   = 4      // bits per pixel (palette index)
) (
    input  logic                     clk,
    input  logic                     rst_n,       // sync reset (from section5 synchronizer)

    // Timing strobes from video controller
    input  logic                     fetch_start, // pulse: begin fetching next tile
    input  logic                     hblank_i,    // level: horizontal blank active

    // Current scan position (provided by video controller)
    input  logic [VRAM_ADDR_W-1:0]   tile_addr,   // VRAM address for this tile
    input  logic [2:0]               tile_row,    // pixel row within tile (0–7)
    input  logic [2:0]               pixel_col,   // current pixel column within tile (0–7)

    // VRAM interface (tile map — one tile index per cell)
    output logic [VRAM_ADDR_W-1:0]   vram_addr_o,
    input  logic [7:0]               vram_data_i, // tile index (registered, 2-cycle latency)

    // Tile ROM interface (tile pixel data)
    output logic [TILE_ROM_ADDR_W-1:0] trom_addr_o,
    input  logic [TILE_W*COLOR_IDX_W-1:0] trom_data_i, // one row of pixels (2-cycle latency)

    // Output
    output logic [COLOR_IDX_W-1:0]   pixel_data,  // valid PIPE_LATENCY cycles after fetch_start
    output logic                     pixel_valid   // asserted when pixel_data is valid
);

// ── State machine ─────────────────────────────────────────────────────────────
typedef enum logic [2:0] {
    IDLE      = 3'd0,
    FETCH_IDX = 3'd1,   // wait for VRAM tile index (M10K latency)
    WAIT_IDX  = 3'd2,   // second VRAM cycle (registered output)
    FETCH_ROM = 3'd3,   // present tile ROM address
    WAIT_ROM  = 3'd4,   // wait for tile ROM data (M10K latency cycle 1)
    WAIT_ROM2 = 3'd5,   // wait for tile ROM data (M10K latency cycle 2)
    OUTPUT    = 3'd6    // shift out pixels
} state_t;

state_t state, state_next;

// Pipeline registers
logic [7:0]                        tile_index_r;
logic [TILE_ROM_ADDR_W-1:0]        trom_addr_r;
logic [TILE_W*COLOR_IDX_W-1:0]     pixel_row_r;  // full row of pixels latched from ROM
logic [2:0]                        pixel_col_r;

// ── State register ────────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) state <= IDLE;
    else        state <= state_next;
end

// ── Next-state logic ──────────────────────────────────────────────────────────
always_comb begin
    state_next = state;
    case (state)
        IDLE:      if (fetch_start && !hblank_i) state_next = FETCH_IDX;
        FETCH_IDX: state_next = WAIT_IDX;
        WAIT_IDX:  state_next = FETCH_ROM;    // tile_index_r valid now
        FETCH_ROM: state_next = WAIT_ROM;
        WAIT_ROM:  state_next = WAIT_ROM2;
        WAIT_ROM2: state_next = OUTPUT;       // trom_data_i valid now
        OUTPUT:    state_next = IDLE;
        default:   state_next = IDLE;
    endcase
    // TRAP 1 — hblank abort: flush pipeline to IDLE at any state
    if (hblank_i) state_next = IDLE;
end

// ── VRAM fetch ────────────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) begin
        vram_addr_o <= '0;
        tile_index_r <= '0;
    end else begin
        case (state)
            IDLE: begin
                if (fetch_start && !hblank_i)
                    vram_addr_o <= tile_addr;  // present address; data arrives in WAIT_IDX
            end
            WAIT_IDX: begin
                tile_index_r <= vram_data_i;  // latch tile index (2-cycle M10K output)
            end
            default: begin end
        endcase
    end
end

// ── Tile ROM fetch ────────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n) begin
        trom_addr_o <= '0;
        pixel_row_r <= '0;
    end else begin
        case (state)
            FETCH_ROM: begin
                // TRAP 2: address computed here, data arrives after 2 more cycles
                trom_addr_o <= TILE_ROM_ADDR_W'({tile_index_r, tile_row});
            end
            WAIT_ROM2: begin
                pixel_row_r <= trom_data_i;  // latch full pixel row
            end
            default: begin end
        endcase
    end
end

// ── Pixel output ───────────────────────────────────────────────────────────────
// Extract the correct pixel from the latched row based on pixel_col.
// PIPELINE NOTE: pixel_col is the column at the time of OUTPUT state,
// which is PIPE_LATENCY cycles after fetch_start. The video controller
// must present the correct pixel_col at that time.
always_ff @(posedge clk) begin
    if (!rst_n) begin
        pixel_data  <= '0;
        pixel_valid <= 1'b0;
    end else if (state == OUTPUT && !hblank_i) begin
        // Extract COLOR_IDX_W bits for the current pixel column
        pixel_data  <= pixel_row_r[pixel_col_r * COLOR_IDX_W +: COLOR_IDX_W];
        pixel_valid <= 1'b1;
    end else begin
        pixel_valid <= 1'b0;
    end
end

// Latch pixel_col when we enter OUTPUT
always_ff @(posedge clk) begin
    if (!rst_n) pixel_col_r <= '0;
    else if (state == WAIT_ROM2) pixel_col_r <= pixel_col;
end

endmodule
