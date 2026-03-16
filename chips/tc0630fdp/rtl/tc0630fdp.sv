`default_nettype none
// =============================================================================
// TC0630FDP — Taito F3 Display Processor (Step 1: Skeleton)
// =============================================================================
// Integrates all video functions for Taito F3 arcade hardware (1992–1997):
//   · 4 scrolling tilemap layers (PF1–PF4), 16×16 tiles, 4/5/6bpp
//   · Text layer (64×64 8×8 tiles, CPU-writable characters)
//   · Pivot/pixel layer (64×32 8×8 tiles, column-major, CPU-writable)
//   · Sprite engine: 17-bit tile codes, 8-bit zoom, 4 priority groups, alpha blend
//   · Per-scanline Line RAM: rowscroll, colscroll, zoom, priority, clip, alpha, mosaic
//   · Layer compositor with 4 clip planes and full alpha blending
//
// MAME source: src/mame/taito/taito_f3.cpp + taito_f3_v.cpp
// Games: RayForce, Darius Gaiden, Elevator Action Returns, Bubble Symphony, etc.
//
// CPU Interface (16-bit, 68EC020 bus):
//   0x660000–0x66001F: Display control registers (16 × 16-bit)
//
// Video timing (pixel clock domain):
//   Pixel clock: 26.686 MHz / 4 = 6.6715 MHz
//   H total: 432 pixels, H active: 320 pixels, H start: pixel 46
//   V total: 262 lines,  V active: 232 lines,  V start: line 24
//   Refresh: ~58.97 Hz
//
// Step 1 scope:
//   · Video timing generator (hblank, vblank, hsync, vsync, hpos, vpos)
//   · CPU interface — 16-bit data bus, register read/write with dtack
//   · All 16 display control registers (readable and writable)
//   · All output ports defined, driven to 0 for now
//
// =============================================================================

module tc0630fdp (
    // ── Clocks and Reset ───────────────────────────────────────────────────
    input  logic        clk,            // pixel clock (6.6715 MHz in hardware)
    input  logic        async_rst_n,

    // ── CPU Interface (68EC020 bus, 16-bit) ────────────────────────────────
    // Chip-select window covers display control registers only in Step 1.
    // Full address map (sprite/PF/line/pivot RAM) added in later steps.
    input  logic        cpu_cs,         // chip select (active high)
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic [18:1] cpu_addr,       // word address within chip window
    input  logic [15:0] cpu_din,        // write data
    input  logic        cpu_lds_n,      // lower byte select (active low)
    input  logic        cpu_uds_n,      // upper byte select (active low)
    output logic [15:0] cpu_dout,       // read data
    output logic        cpu_dtack_n,    // data transfer acknowledge (active low)

    // ── Video Timing Outputs ───────────────────────────────────────────────
    output logic        hblank,         // horizontal blank (active high)
    output logic        vblank,         // vertical blank   (active high)
    output logic        hsync,          // horizontal sync  (active high)
    output logic        vsync,          // vertical sync    (active high)
    output logic [ 9:0] hpos,           // pixel counter within H total (0..431)
    output logic [ 8:0] vpos,           // line counter within V total  (0..261)

    // ── Interrupt Outputs ──────────────────────────────────────────────────
    output logic        int_vblank,     // INT2: fires at VBLANK start
    output logic        int_hblank,     // INT3: pseudo-hblank (fires ~10K CPU cycles after INT2)

    // ── GFX ROM Interface (stub — driven 0 until Step 2) ──────────────────
    output logic [24:0] gfx_lo_addr,    // GFX ROM low-plane byte address
    output logic        gfx_lo_rd,      // GFX ROM low-plane read strobe
    input  logic [ 7:0] gfx_lo_data,   // GFX ROM low-plane read data

    output logic [24:0] gfx_hi_addr,    // GFX ROM hi-plane byte address
    output logic        gfx_hi_rd,      // GFX ROM hi-plane read strobe
    input  logic [ 7:0] gfx_hi_data,   // GFX ROM hi-plane read data

    // ── Palette Interface (stub — driven 0 until Step 2) ──────────────────
    output logic [14:0] pal_addr,       // palette RAM address
    output logic        pal_rd,         // palette read strobe
    input  logic [15:0] pal_data,       // palette read data

    // ── Video Output (stub — driven 0 until Step 2) ───────────────────────
    output logic [23:0] rgb_out,        // 24-bit RGB to TC0650FDA DAC
    output logic        pixel_valid     // high during active display
);

// =============================================================================
// Reset synchronizer (2-FF)
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// =============================================================================
// Video Timing Generator
// =============================================================================
// H timing (pixel clock domain):
//   H total:   432 pixels (0..431)
//   H active:  pixels 46..365  (320 pixels)
//   H blank:   pixels 0..45 and 366..431
//   H sync:    pixels 0..31  (within blanking period)
//
// V timing:
//   V total:   262 lines (0..261)
//   V active:  lines 24..255  (232 lines)
//   V blank:   lines 0..23 and 256..261
//   V sync:    lines 0..3  (within blanking period)
//
// Derived from MAME: screen.set_raw(26.686_MHz_XTAL/4, 432, 46, 320+46, 262, 24, 232+24)
//   hstart=46, hend=366, vstart=24, vend=256
// =============================================================================

// Timing parameters
localparam int H_TOTAL   = 432;
localparam int H_START   = 46;
localparam int H_END     = 366;   // H_START + 320
// H_SYNC_S=0: sync starts at pixel 0 (start of blanking); not needed as a
// localparam because the >= 0 comparison is trivially true for unsigned hpos.
localparam int H_SYNC_E  = 32;

localparam int V_TOTAL   = 262;
localparam int V_START   = 24;
localparam int V_END     = 256;   // V_START + 232
// V_SYNC_S=0: sync starts at line 0 (start of blanking); same rationale.
localparam int V_SYNC_E  = 4;

// Horizontal and vertical counters
always_ff @(posedge clk) begin
    if (!rst_n) begin
        hpos <= 10'b0;
        vpos <=  9'b0;
    end else begin
        if (hpos == 10'(H_TOTAL - 1)) begin
            hpos <= 10'b0;
            if (vpos == 9'(V_TOTAL - 1))
                vpos <= 9'b0;
            else
                vpos <= vpos + 9'b1;
        end else begin
            hpos <= hpos + 10'b1;
        end
    end
end

// Timing output signals (combinational from counters)
// H_SYNC_S and V_SYNC_S are both 0, so the >= 0 comparisons are omitted to
// avoid Verilator UNSIGNED warnings (unsigned values are always >= 0).
always_comb begin
    hblank = (hpos < 10'(H_START)) || (hpos >= 10'(H_END));
    vblank = (vpos <  9'(V_START)) || (vpos >=  9'(V_END));
    hsync  = (hpos < 10'(H_SYNC_E));
    vsync  = (vpos <  9'(V_SYNC_E));
end

// Pixel valid: active only when neither blanking
assign pixel_valid = !hblank && !vblank;

// =============================================================================
// Interrupt Generation
// =============================================================================
// INT2 (int_vblank): fires at the start of VBLANK (vpos transitions to V_END).
// INT3 (int_hblank): pseudo-hblank timer, fires ~10000 CPU cycles after INT2.
//   With 68EC020 @ 26.686 MHz and pixel clock @ 6.6715 MHz (4× slower),
//   10000 CPU cycles ≈ 2500 pixel clock cycles.
//   We fire it one full frame scanline (432 cycles) after vblank start as an
//   approximation. Exact timing is per-game initialization (MAME TODO).
// =============================================================================
logic vblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) vblank_r <= 1'b0;
    else        vblank_r <= vblank;
end
logic vblank_rise;
assign vblank_rise = vblank & ~vblank_r;   // rising edge of vblank

// INT3 delay counter: count 2500 pixel clocks after vblank_rise
localparam int INT3_DELAY = 2500;
logic [11:0] int3_cnt;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        int_vblank <= 1'b0;
        int_hblank <= 1'b0;
        int3_cnt   <= 12'b0;
    end else begin
        int_vblank <= 1'b0;
        int_hblank <= 1'b0;
        if (vblank_rise) begin
            int_vblank <= 1'b1;
            int3_cnt   <= 12'(INT3_DELAY);
        end
        if (int3_cnt != 12'b0) begin
            int3_cnt <= int3_cnt - 12'b1;
            if (int3_cnt == 12'd1)
                int_hblank <= 1'b1;
        end
    end
end

// =============================================================================
// Display Control Register Bank (0x660000–0x66001F in CPU space)
// 16 × 16-bit registers, word-addressed [3:0] within the 32-byte window.
//
// CPU bus address decoding:
//   The top-level chip select (cpu_cs) gates all accesses.
//   Within the display control window, cpu_addr[4:1] selects the register (0–15).
//   (cpu_addr is a word address; bits[4:1] index the 16 registers.)
//
// Register map (word index):
//   0  = PF1_XSCROLL   (10.6 fixed-point, inverted frac)
//   1  = PF2_XSCROLL
//   2  = PF3_XSCROLL
//   3  = PF4_XSCROLL
//   4  = PF1_YSCROLL   (9.7 fixed-point)
//   5  = PF2_YSCROLL
//   6  = PF3_YSCROLL
//   7  = PF4_YSCROLL
//   8–11 = unused (always 0, writes ignored)
//   12 = PIXEL_XSCROLL
//   13 = PIXEL_YSCROLL
//   14 = unused
//   15 = EXTEND_MODE   (bit 7: 1=1024×512, 0=512×512)
// =============================================================================
logic [15:0] ctrl [0:15];

// Byte enables from active-low UDS/LDS
logic [1:0] cpu_be;
assign cpu_be = {~cpu_uds_n, ~cpu_lds_n};

// Register select: cpu_addr[4:1] selects word 0–15
logic [3:0] ctrl_idx;
assign ctrl_idx = cpu_addr[4:1];

// Write path
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 16; i++) ctrl[i] <= 16'b0;
    end else if (cpu_cs && !cpu_rw) begin
        // Only write to implemented registers (skip unused 8–11, 14)
        if (ctrl_idx != 4'd8  && ctrl_idx != 4'd9  &&
            ctrl_idx != 4'd10 && ctrl_idx != 4'd11 &&
            ctrl_idx != 4'd14) begin
            if (cpu_be[1]) ctrl[ctrl_idx][15:8] <= cpu_din[15:8];
            if (cpu_be[0]) ctrl[ctrl_idx][ 7:0] <= cpu_din[ 7:0];
        end
    end
end

// Read path (registered, 1-cycle latency — same pattern as tc0180vcu)
always_ff @(posedge clk) begin
    if (!rst_n) begin
        cpu_dout <= 16'b0;
    end else if (cpu_cs && cpu_rw) begin
        cpu_dout <= ctrl[ctrl_idx];
    end
end

// DTACK: assert one cycle after CS (1-cycle registered read)
always_ff @(posedge clk) begin
    if (!rst_n)      cpu_dtack_n <= 1'b1;
    else if (cpu_cs) cpu_dtack_n <= 1'b0;
    else             cpu_dtack_n <= 1'b1;
end

// =============================================================================
// Decoded Control Register Outputs
// These are the named outputs consumed by all other modules.
// =============================================================================

// PF1–PF4 X scroll (raw 10.6 fixed-point, inverted fractional bits)
logic [15:0] pf_xscroll [0:3];
assign pf_xscroll[0] = ctrl[0];
assign pf_xscroll[1] = ctrl[1];
assign pf_xscroll[2] = ctrl[2];
assign pf_xscroll[3] = ctrl[3];

// PF1–PF4 Y scroll (raw 9.7 fixed-point)
logic [15:0] pf_yscroll [0:3];
assign pf_yscroll[0] = ctrl[4];
assign pf_yscroll[1] = ctrl[5];
assign pf_yscroll[2] = ctrl[6];
assign pf_yscroll[3] = ctrl[7];

// Pixel/VRAM layer scroll
logic [15:0] pixel_xscroll;
logic [15:0] pixel_yscroll;
assign pixel_xscroll = ctrl[12];
assign pixel_yscroll = ctrl[13];

// Extend mode: bit 7 of ctrl[15]
logic extend_mode;
assign extend_mode = ctrl[15][7];

// =============================================================================
// Stub outputs — driven to 0 until later steps
// =============================================================================
assign gfx_lo_addr = 25'b0;
assign gfx_lo_rd   = 1'b0;
assign gfx_hi_addr = 25'b0;
assign gfx_hi_rd   = 1'b0;
assign pal_addr    = 15'b0;
assign pal_rd      = 1'b0;
assign rgb_out     = 24'b0;

// =============================================================================
// Suppress unused-signal warnings for stub inputs and decoded outputs
// that are not yet consumed by submodules (Steps 2–13 will use them).
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{gfx_lo_data,
                   gfx_hi_data,
                   pal_data,
                   pf_xscroll[0], pf_xscroll[1], pf_xscroll[2], pf_xscroll[3],
                   pf_yscroll[0], pf_yscroll[1], pf_yscroll[2], pf_yscroll[3],
                   pixel_xscroll, pixel_yscroll,
                   extend_mode,
                   cpu_addr[18:5]};
/* verilator lint_on UNUSED */

endmodule
