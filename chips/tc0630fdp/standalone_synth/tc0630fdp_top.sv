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
//
// Phase 7 note: all debug/testbench ports (bg_pixel_out, text_pixel_out,
// spr_pixel_out, colmix_pixel_out, blend_rgb_out, *_wr_* ports) are excluded
// from tc0630fdp when `QUARTUS is defined — no connections needed here.
// =============================================================================
`default_nettype none

module tc0630fdp_top (
    input  wire clk,          // pixel clock reference (e.g. 24 MHz)
    input  wire clk_4x,       // 4× pixel clock for time-multiplexed BG engine (≈96 MHz)
    output wire led           // keeps Quartus from optimising everything away
);

// All chip I/O is tied-off so the design is self-contained.
// Quartus will see all logic reachable from clk → retain it.

// ── Video / pixel outputs ────────────────────────────────────────────────────
wire [23:0] rgb_out;
wire        pixel_valid;

// ── CPU interface (tied idle — no reads or writes) ───────────────────────────
wire [15:0] cpu_dout;
wire        cpu_dtack_n;

// ── Timing outputs ───────────────────────────────────────────────────────────
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

// ── FDA video outputs ─────────────────────────────────────────────────────────
wire [7:0] fda_r, fda_g, fda_b;
wire [2:0] fda_pixel_valid_d;

// ─────────────────────────────────────────────────────────────────────────────
// DUT
// ─────────────────────────────────────────────────────────────────────────────
tc0630fdp dut (
    .clk            (clk),
    .clk_4x         (clk_4x),
    .pix_cen        (1'b1),       // run at full clock rate for resource measurement
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

    // Main video output
    .rgb_out        (rgb_out),
    .pixel_valid    (pixel_valid),

    // TC0650FDA CPU interface — idle
    .fda_cpu_cs     (1'b0),
    .fda_cpu_we     (1'b0),
    .fda_cpu_addr   (13'd0),
    .fda_cpu_din    (32'd0),
    .fda_cpu_be     (4'd0),
    .fda_mode_12bit (1'b0),

    // TC0650FDA video outputs
    .fda_video_r    (fda_r),
    .fda_video_g    (fda_g),
    .fda_video_b    (fda_b),
    .fda_pixel_valid_d (fda_pixel_valid_d)
    // Note: debug/testbench ports (bg_pixel_out, spr_pixel_out, *_wr_*, etc.)
    // are excluded from the port list when `QUARTUS is defined.
);

// Fold all live outputs into the LED pin so the optimizer retains all logic.
assign led = ^rgb_out ^ pixel_valid ^ vblank ^ ^fda_r ^ ^fda_b;

endmodule
