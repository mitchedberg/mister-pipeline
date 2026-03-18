// =============================================================================
// TC0630FDP — Standalone Synthesis Harness
// =============================================================================
// Minimal wrapper for per-chip Quartus synthesis validation.
// No MiSTer sys/ framework — pure chip logic + one clock input.
//
// Purpose: verify the chip itself fits in 5CSEBA6U23I7 and report ALM usage
//          before integrating into the full arcade system.
//
// Usage:
//   quartus_sh --flow compile standalone.qsf
//   Look at output_files/tc0630fdp_top.fit.rpt for resource summary.
//
// Clock: 53.333 MHz input (FPGA pin) — closest achievable to the chip's
//        ~6.67 MHz pixel clock from a 50 MHz reference without a PLL.
//        Timing results will be faster than real system; resource count
//        is accurate.
// =============================================================================
`default_nettype none

module tc0630fdp_top (
    input  wire clk,          // 50 MHz FPGA oscillator (or any reference)
    output wire led           // keeps Quartus from optimising everything away
);

// All chip I/O is tied-off so the design is self-contained.
// Quartus will see all logic reachable from clk → retain it.

// ── Video / pixel outputs (use as led source) ────────────────────────────────
wire [23:0] rgb_out;
wire        pixel_valid;
wire  [8:0] text_pixel_out;
wire [3:0][12:0] bg_pixel_out;

// ── CPU interface (tied idle — no reads or writes) ───────────────────────────
wire [15:0] cpu_dout;
wire        cpu_dtack_n;

// ── Timing outputs (unused in harness) ──────────────────────────────────────
wire hblank, vblank, hsync, vsync;
wire [9:0] hpos;
wire [8:0] vpos;
wire int_vblank, int_hblank;

// ── GFX ROM interface (return 0) ─────────────────────────────────────────────
wire [24:0] gfx_lo_addr, gfx_hi_addr;
wire        gfx_lo_rd,   gfx_hi_rd;

// ── Palette interface (return 0) ─────────────────────────────────────────────
wire [14:0] pal_addr;
wire        pal_rd;

// ─────────────────────────────────────────────────────────────────────────────
// DUT
// ─────────────────────────────────────────────────────────────────────────────
tc0630fdp dut (
    .clk            (clk),
    .async_rst_n    (1'b1),

    // CPU — idle (no CS)
    .cpu_cs         (1'b0),
    .cpu_rw         (1'b1),
    .cpu_addr       (18'd0),
    .cpu_din        (16'd0),
    .cpu_lds_n      (1'b1),
    .cpu_uds_n      (1'b1),
    .cpu_dout       (cpu_dout),
    .cpu_dtack_n    (cpu_dtack_n),

    // Timing outputs
    .hblank         (hblank),
    .vblank         (vblank),
    .hsync          (hsync),
    .vsync          (vsync),
    .hpos           (hpos),
    .vpos           (vpos),
    .int_vblank     (int_vblank),
    .int_hblank     (int_hblank),

    // GFX ROM — return 0
    .gfx_lo_addr    (gfx_lo_addr),
    .gfx_lo_rd      (gfx_lo_rd),
    .gfx_lo_data    (8'd0),
    .gfx_hi_addr    (gfx_hi_addr),
    .gfx_hi_rd      (gfx_hi_rd),
    .gfx_hi_data    (8'd0),

    // Palette — return 0
    .pal_addr       (pal_addr),
    .pal_rd         (pal_rd),
    .pal_data       (16'd0),

    // Pixel outputs
    .rgb_out        (rgb_out),
    .pixel_valid    (pixel_valid),
    .text_pixel_out (text_pixel_out),
    .bg_pixel_out   (bg_pixel_out),

    // Testbench write ports — tied off
    .gfx_wr_addr    (22'd0),
    .gfx_wr_data    (32'd0),
    .gfx_wr_en      (1'b0),
    .spr_wr_addr    (15'd0),
    .spr_wr_data    (16'd0),
    .spr_wr_en      (1'b0)
);

// Fold all outputs into the LED pin so the optimizer cannot remove logic.
assign led = ^rgb_out ^ pixel_valid ^ vblank ^ ^bg_pixel_out[0] ^ ^bg_pixel_out[3];

endmodule
