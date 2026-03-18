// =============================================================================
// TC0150ROD — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module tc0150rod_top (
    input  wire clk,
    output wire led
);

wire [15:0] cpu_dout;
wire        cpu_dtack_n;
wire [17:0] rom_addr;
wire        rom_req;
wire [14:0] pix_out;
wire        pix_valid, pix_transp;
wire  [7:0] line_priority;
wire        render_done;

tc0150rod dut (
    .clk        (clk),
    .rst_n      (1'b1),

    // CPU B bus interface — idle
    .cpu_cs     (1'b0),
    .cpu_we     (1'b0),
    .cpu_addr   (12'd0),
    .cpu_din    (16'd0),
    .cpu_dout   (cpu_dout),
    .cpu_be     (2'd0),
    .cpu_dtack_n(cpu_dtack_n),

    // GFX ROM interface — return zeros, ack immediately
    .rom_addr   (rom_addr),
    .rom_data   (16'd0),
    .rom_req    (rom_req),
    .rom_ack    (rom_req),    // echo req→ack: single-cycle response

    // Video timing inputs — tied off
    .hblank     (1'b0),
    .vblank     (1'b0),
    .hpos       (9'd0),
    .vpos       (8'd0),

    // Game-specific rendering parameters
    .y_offs     (8'sd0),
    .palette_offs(8'd0),
    .road_type  (2'd0),
    .road_trans (1'b0),
    .low_priority(8'd0),
    .high_priority(8'd0),

    // Scanline pixel output
    .pix_out    (pix_out),
    .pix_valid  (pix_valid),
    .pix_transp (pix_transp),
    .line_priority(line_priority),

    // Testbench status
    .render_done(render_done)
);

// XOR all outputs to prevent optimization
assign led = ^cpu_dout ^ cpu_dtack_n ^ ^rom_addr ^ rom_req ^ ^pix_out ^ pix_valid ^ pix_transp ^ ^line_priority ^ render_done;

endmodule
