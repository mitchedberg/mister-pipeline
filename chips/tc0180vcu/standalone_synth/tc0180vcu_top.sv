// =============================================================================
// TC0180VCU — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module tc0180vcu_top (
    input  wire clk,
    output wire led
);

wire [15:0] cpu_dout;
wire        int_h, int_l;
wire [22:0] gfx_addr;
wire        gfx_rd;
wire [12:0] pixel_out;
wire        pixel_valid;

tc0180vcu dut (
    .clk        (clk),
    .async_rst_n(1'b1),

    // CPU Interface — idle
    .cpu_cs     (1'b0),
    .cpu_we     (1'b0),
    .cpu_addr   (19'd0),
    .cpu_din    (16'd0),
    .cpu_be     (2'd0),
    .cpu_dout   (cpu_dout),

    // Interrupts
    .int_h      (int_h),
    .int_l      (int_l),

    // Video Timing — tied off
    .hblank_n   (1'b1),
    .vblank_n   (1'b1),
    .hpos       (9'd0),
    .vpos       (8'd0),

    // GFX ROM Interface — return zeros, ack immediately
    .gfx_addr   (gfx_addr),
    .gfx_data   (8'd0),
    .gfx_rd     (gfx_rd),

    // Video Output
    .pixel_out  (pixel_out),
    .pixel_valid(pixel_valid)
);

// XOR all outputs to prevent optimization
assign led = ^cpu_dout ^ int_h ^ int_l ^ ^gfx_addr ^ gfx_rd ^ ^pixel_out ^ pixel_valid;

endmodule
