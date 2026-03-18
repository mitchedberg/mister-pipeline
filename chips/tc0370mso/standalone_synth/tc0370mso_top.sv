// =============================================================================
// TC0370MSO — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module tc0370mso_top (
    input  wire clk,
    output wire led
);

wire [15:0] spr_dout;
wire        spr_dtack_n;
wire [17:0] stym_addr;
wire        stym_req;
wire [22:0] obj_addr;
wire        obj_req;
wire [11:0] pix_out;
wire        pix_valid, pix_priority;

tc0370mso dut (
    .clk        (clk),
    .rst_n      (1'b1),

    // Sprite RAM — idle
    .spr_cs     (1'b0),
    .spr_we     (1'b0),
    .spr_addr   (13'd0),
    .spr_din    (16'd0),
    .spr_dout   (spr_dout),
    .spr_be     (2'd0),
    .spr_dtack_n(spr_dtack_n),

    // SDRAM ROM ports — return ack immediately, data=0
    .stym_addr  (stym_addr),
    .stym_data  (16'd0),
    .stym_req   (stym_req),
    .stym_ack   (stym_req),   // echo req→ack: single-cycle response

    .obj_addr   (obj_addr),
    .obj_data   (64'd0),
    .obj_req    (obj_req),
    .obj_ack    (obj_req),

    // Video timing — tied off
    .vblank     (1'b0),
    .hblank     (1'b0),
    .hpos       (9'd0),
    .vpos       (8'd0),

    // Game parameters
    .y_offs     (4'sd0),
    .frame_sel  (1'b0),

    // Pixel output
    .pix_out    (pix_out),
    .pix_valid  (pix_valid),
    .pix_priority(pix_priority),

    .flip_screen(1'b0)
);

assign led = ^pix_out ^ pix_valid ^ pix_priority;

endmodule
