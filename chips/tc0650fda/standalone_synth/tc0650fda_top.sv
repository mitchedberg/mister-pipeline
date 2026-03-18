// =============================================================================
// TC0650FDA — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module tc0650fda_top (
    input  wire clk,
    output wire led
);

wire [31:0] cpu_rd_raw;
wire        cpu_dtack_n;
wire  [7:0] video_r, video_g, video_b;
wire  [2:0] pixel_valid_d;

tc0650fda dut (
    .clk        (clk),
    .ce_pixel   (1'b1),    // Always enable pixel pipeline
    .rst_n      (1'b1),

    // CPU Interface — idle
    .cpu_cs     (1'b0),
    .cpu_we     (1'b0),
    .cpu_addr   (13'd0),
    .cpu_din    (32'd0),
    .cpu_be     (4'd0),
    .cpu_dtack_n(cpu_dtack_n),
    .cpu_rd_raw (cpu_rd_raw),

    // Video Input — tied off
    .pixel_valid(1'b0),
    .src_pal    (13'd0),
    .dst_pal    (13'd0),
    .src_blend  (4'd0),
    .dst_blend  (4'd0),
    .do_blend   (1'b0),

    // Mode Control
    .mode_12bit (1'b0),

    // Video Output
    .video_r    (video_r),
    .video_g    (video_g),
    .video_b    (video_b),
    .pixel_valid_d(pixel_valid_d)
);

// XOR all outputs to prevent optimization
assign led = ^cpu_rd_raw ^ cpu_dtack_n ^ ^video_r ^ ^video_g ^ ^video_b ^ ^pixel_valid_d;

endmodule
