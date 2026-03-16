`default_nettype none
// =============================================================================
// cps1_obj_adapter.sv — Drop-in replacement for jtcps1_obj.v
// =============================================================================
// Wraps cps1_obj.sv (AI-generated RTL) to match the jtcps1_obj.v interface
// used by jotego's jtcores CPS1 core (modules/jtframe, cores/cps1).
//
// Usage: in cores/cps1/hdl/jtcps1_video.v, replace the jtcps1_obj instantiation
// with cps1_obj_adapter. The port names are identical.
//
// Requires jtcps1_gfx_mappers.v (cores/cps1/hdl/) to be in the same build.
// Requires cps1_obj.sv (this repo) to be in the same build.
//
// =============================================================================
// INTERFACE TRANSLATION
// =============================================================================
//
// frame_addr / frame_data
//   jotego: chip reads OBJ cache via frame_addr (output) / frame_data (input).
//   us: chip takes CPU OBJ RAM writes (cpu_addr, cpu_data, cpu_we).
//   Adapter: during VBLANK, read all 1024 words from frame cache and write
//   them to our chip's live OBJ RAM. Then assert vblank_n=0 to our chip.
//
// start / vrender / vdump / hdump
//   jotego: per-line rendering trigger + 9-bit video counters.
//   us: hcount[8:0], vcount[8:0], hblank_n, vblank_n.
//   Adapter: hcount=hdump, vcount=vdump; derive hblank_n/vblank_n from hdump/vdump.
//
// game / bank_offset / bank_mask
//   jotego: game-specific ROM address banking via jtcps1_gfx_mappers.
//   us: raw 20-bit rom_addr = {code[15:0], vsub[3:0]}.
//   Adapter: apply jtcps1_gfx_mappers to remap tile code upper 4 bits.
//   Mapping: mapped_addr[19:16] = (raw_addr[19:16] & mask) | offset
//
// pxl[8:0]
//   jotego: {pal[4:0], color[3:0]}, 9'h1FF = transparent.
//   us: pixel_out[8:0] same format. Direct passthrough.
//
// pxl_cen (pixel clock enable)
//   jotego: 8 MHz enable on 48 MHz master clock.
//   us: chip runs at full clk rate; pxl_cen is not used for clocking.
//   Effect: our internal state machines run at 48 MHz (6x faster than 8 MHz)
//   but all timing budgets are satisfied — VBLANK gives 6x more cycles for
//   DMA+FES+SIB, and hblank gives 6x more ROM fetch cycles. Pixel output
//   repeats 6x per pixel but colmix only samples on pxl_cen.
//
// =============================================================================
// VBLANK TIMING
// =============================================================================
// jotego active display: hdump 64..447, vdump 16..237 (but conservative: use
//   vdump 14..237 per timing module shVB computation).
// jotego VBLANK: vdump 0..13 and 238..261 (~38 lines × 512 = 19,456 clk cycles)
//
// OBJ RAM load: 1 + 1024 + 1 = 1026 cycles (frame_addr drive + data latency)
// Chip internal (at 48 MHz):
//   DMA: 1024 cycles, FES: ≤256 cycles, SIB: ≤10,240 cycles worst case
//   Total: ≤11,520 cycles (much less than 19,456 - 1026 = 18,430 remaining)
//
// =============================================================================

module cps1_obj_adapter (
    input  logic        rst,           // active-high reset (jotego convention)
    input  logic        clk,           // 48 MHz master clock
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        pxl_cen,       // 8 MHz pixel clock enable (not used for clocking)
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        flip,          // global video flip

    // Frame cache (OBJ RAM copy, managed by DMA in jtcps1_dma.v)
    output logic [ 9:0] frame_addr,    // read address driven by this module
    input  logic [15:0] frame_data,    // data available 1 cycle after frame_addr

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        start,         // line_start from jtcps1_timing (not used)
    input  logic [ 8:0] vrender,       // vdump + 1 (not used; vdump used directly)
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [ 8:0] vdump,         // vertical counter 0..261
    input  logic [ 8:0] hdump,         // horizontal counter 0..511

    // ROM banks
    input  logic [ 5:0] game,          // game ID for jtcps1_gfx_mappers
    input  logic [15:0] bank_offset,
    input  logic [15:0] bank_mask,

    // ROM interface (pass-through to SDRAM)
    output logic [19:0] rom_addr,
    output logic        rom_half,
    output logic        rom_cs,
    input  logic [31:0] rom_data,
    input  logic        rom_ok,

    // Pixel output to colour mixer
    output logic [ 8:0] pxl
);

// ─────────────────────────────────────────────────────────────────────────────
// Reset: convert jotego active-high rst → our active-low async_rst_n
// ─────────────────────────────────────────────────────────────────────────────
logic async_rst_n;
assign async_rst_n = ~rst;

// ─────────────────────────────────────────────────────────────────────────────
// Internal chip signals
// ─────────────────────────────────────────────────────────────────────────────
// CPU bus (used by adapter to load OBJ RAM from frame cache)
logic [ 9:0] cpu_addr;
logic [15:0] cpu_data;
logic        cpu_we;

// Timing to chip
logic        hblank_n_int;
logic        vblank_n_int;

// Chip outputs
logic [19:0] rom_addr_raw;
logic        rom_half_raw;
logic        rom_cs_raw;
logic [ 8:0] pixel_out;
/* verilator lint_off UNUSEDSIGNAL */
logic        pixel_valid;
/* verilator lint_on UNUSEDSIGNAL */

// ─────────────────────────────────────────────────────────────────────────────
// Timing derivation
// hblank_n: active display is hdump 64..447 (matches jotego's 384-pixel window)
// vblank_n: controlled by load state machine (below)
// hcount = hdump, vcount = vdump
// ─────────────────────────────────────────────────────────────────────────────
always_comb begin
    hblank_n_int = (hdump >= 9'd64) & (hdump < 9'd448);
end

// ─────────────────────────────────────────────────────────────────────────────
// VBLANK detection
// jotego active lines: vdump 14..237
// VB is active when vdump < 14 or vdump > 237
// ─────────────────────────────────────────────────────────────────────────────
logic vb_active;
assign vb_active = (vdump < 9'd14) | (vdump > 9'd237);

logic vb_prev;
always_ff @(posedge clk or posedge rst) begin
    if (rst) vb_prev <= 1'b0;
    else     vb_prev <= vb_active;
end

logic vb_rise;
assign vb_rise = vb_active & ~vb_prev;  // one-cycle pulse at VBLANK start

// ─────────────────────────────────────────────────────────────────────────────
// OBJ RAM Load State Machine
// ─────────────────────────────────────────────────────────────────────────────
// Reads all 1024 words from the jotego frame cache (frame_addr/frame_data)
// and writes them to our chip's live OBJ RAM via the cpu bus interface.
// Then asserts vblank_n_int = 0 to trigger the chip's internal VBLANK DMA.
//
// Protocol:
//   cycle 0:    frame_addr = 0 (request word 0); no write
//   cycle N+1:  frame_data = word[N]; write cpu_addr=N, cpu_data=word[N]
//   cycle 1025: last word written; transition to ST_VB_HOLD
//   ST_VB_HOLD: vblank_n_int = 0 for remainder of jotego VBLANK
// ─────────────────────────────────────────────────────────────────────────────

typedef enum logic [1:0] {
    ST_ACTIVE  = 2'd0,    // active display; chip rendering normally
    ST_LOAD    = 2'd1,    // loading OBJ RAM from frame cache (1026 cycles)
    ST_VB_HOLD = 2'd2     // chip VBLANK active; waiting for display to resume
} load_state_t;

load_state_t load_state;
logic [10:0] load_cnt;    // 0..1026

always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        load_state <= ST_ACTIVE;
        load_cnt   <= 11'd0;
    end else begin
        case (load_state)
            ST_ACTIVE: begin
                if (vb_rise) begin
                    load_cnt   <= 11'd0;
                    load_state <= ST_LOAD;
                end
            end

            ST_LOAD: begin
                load_cnt <= load_cnt + 11'd1;
                // After 1026 cycles: 1 initial + 1024 data + 1 flush = done
                if (load_cnt == 11'd1025) begin
                    load_state <= ST_VB_HOLD;
                end
            end

            ST_VB_HOLD: begin
                // Hold vblank_n=0 until jotego VBLANK ends
                if (!vb_active) begin
                    load_state <= ST_ACTIVE;
                end
            end

            default: load_state <= ST_ACTIVE;
        endcase
    end
end

// Frame cache read: drive frame_addr during ST_LOAD
// frame_addr = load_cnt[9:0] (requesting words 0..1023)
always_comb begin
    case (load_state)
        ST_LOAD:    frame_addr = load_cnt[9:0];
        default:    frame_addr = 10'd0;
    endcase
end

// CPU write: one cycle after frame_addr, frame_data is valid
// Write window: load_cnt = 1..1024 → cpu_addr = 0..1023
// load_cnt[9:0] - 1 gives 0..1023 (with 10-bit underflow at cnt[9:0]=0 when cnt=1024
//   giving 1023, which is correct: 1024 & 0x3FF = 0, 0-1 = 0x3FF = 1023)
always_comb begin
    cpu_we   = (load_state == ST_LOAD) &
               (load_cnt >= 11'd1) & (load_cnt <= 11'd1024);
    cpu_addr = load_cnt[9:0] - 10'd1;
    cpu_data = frame_data;
end

// vblank_n to chip: 0 only during ST_VB_HOLD
assign vblank_n_int = (load_state != ST_VB_HOLD);

// ─────────────────────────────────────────────────────────────────────────────
// ROM address banking via jtcps1_gfx_mappers
// ─────────────────────────────────────────────────────────────────────────────
// Our chip outputs rom_addr_raw[19:0] = {tile_code[15:0], vsub[3:0]}
// Mapper input: cin[9:0] = tile_code[15:6] = rom_addr_raw[19:10]
// Mapper output: offset[3:0], mask[3:0]
// Mapped: rom_addr[19:16] = (rom_addr_raw[19:16] & mask) | offset
//         rom_addr[15:0]  = rom_addr_raw[15:0]
// ─────────────────────────────────────────────────────────────────────────────
logic [ 3:0] map_offset;
logic [ 3:0] map_mask;
logic        map_unmapped;

// Mapper is registered (1 cycle latency). rom_addr lags rom_addr_raw by 1 cycle.
// This is consistent with jotego's own mapper usage in jtcps1_obj_line_table.v.
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off EOFNEWLINE */
jtcps1_gfx_mappers u_mapper (
    .clk         ( clk                    ),
    .rst         ( rst                    ),
    .game        ( game                   ),
    .bank_offset ( bank_offset            ),
    .bank_mask   ( bank_mask              ),
    .layer       ( 3'b000                 ),   // OBJ layer = 0
    .cin         ( rom_addr_raw[19:10]    ),   // tile_code[15:6]
    .offset      ( map_offset             ),
    .mask        ( map_mask               ),
    .unmapped    ( map_unmapped           )
);
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on EOFNEWLINE */

// Apply mapping (registered, 1 cycle after raw)
logic [19:0] rom_addr_mapped;
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        rom_addr_mapped <= 20'd0;
        rom_half        <= 1'b0;
        rom_cs          <= 1'b0;
    end else begin
        // Apply bank mapping to upper 4 bits of rom_addr
        rom_addr_mapped[19:16] <= map_unmapped ? rom_addr_raw[19:16]
                                               : (rom_addr_raw[19:16] & map_mask)
                                                 | map_offset;
        rom_addr_mapped[15:0]  <= rom_addr_raw[15:0];
        rom_half               <= rom_half_raw;
        rom_cs                 <= rom_cs_raw;
    end
end

assign rom_addr = rom_addr_mapped;

// ─────────────────────────────────────────────────────────────────────────────
// Pixel output
// Our pixel_out[8:0] = {pal[4:0], color[3:0]} — same format as jotego's pxl
// 9'h1FF = transparent (both systems)
// ─────────────────────────────────────────────────────────────────────────────
assign pxl = pixel_out;

// ─────────────────────────────────────────────────────────────────────────────
// cps1_obj instantiation
// ─────────────────────────────────────────────────────────────────────────────
cps1_obj #(
    .MAX_SPRITES ( 256 )
) u_cps1_obj (
    .clk         ( clk             ),
    .async_rst_n ( async_rst_n     ),

    // CPU OBJ RAM writes (from adapter load state machine)
    .cpu_addr    ( cpu_addr        ),
    .cpu_data    ( cpu_data        ),
    .cpu_we      ( cpu_we          ),

    // Video timing (derived from jotego hdump/vdump)
    .hcount      ( hdump           ),
    .vcount      ( vdump           ),
    .hblank_n    ( hblank_n_int    ),
    .vblank_n    ( vblank_n_int    ),

    // Global video control
    .flip_screen ( flip            ),

    // ROM interface (raw, pre-mapping)
    .rom_addr    ( rom_addr_raw    ),
    .rom_half    ( rom_half_raw    ),
    .rom_cs      ( rom_cs_raw      ),
    .rom_data    ( rom_data        ),
    .rom_ok      ( rom_ok          ),

    // Pixel output
    .pixel_out   ( pixel_out       ),
    .pixel_valid ( pixel_valid     )
);

endmodule
