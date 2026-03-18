// =============================================================================
// Taito F3 — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module taito_f3_top (
    input  wire clk,
    output wire led
);

// ─────────────────────────────────────────────────────────────────────────
// Output wires from taito_f3 (to be XORed into led)
// ─────────────────────────────────────────────────────────────────────────

wire [7:0]  rgb_r, rgb_g, rgb_b;
wire        hsync_n, vsync_n, hblank, vblank;
wire [15:0] snd_dout;
wire        snd_dtack_n, snd_reset_n;
wire [26:0] gfx_a_addr, gfx_b_addr, sdr_addr;
wire        gfx_a_req, gfx_b_req, sdr_req;

// ─────────────────────────────────────────────────────────────────────────
// Instantiate taito_f3 with all inputs tied off
// ─────────────────────────────────────────────────────────────────────────

taito_f3 dut (
    // Clocks — wire both clk_sys and clk_pix to input clk
    .clk_sys        (clk),
    .clk_pix        (clk),
    .reset_n        (1'b1),

    // Sound CPU bus — idle (no accesses)
    .snd_addr       (16'd0),
    .snd_din        (16'd0),
    .snd_dout       (snd_dout),
    .snd_rw         (1'b1),        // read idle
    .snd_as_n       (1'b1),        // no access
    .snd_dtack_n    (snd_dtack_n),
    .snd_reset_n    (snd_reset_n),

    // GFX ROM ports — echo req→ack
    .gfx_a_addr     (gfx_a_addr),
    .gfx_a_data     (16'd0),
    .gfx_a_req      (gfx_a_req),
    .gfx_a_ack      (gfx_a_req),   // echo request → ack

    .gfx_b_addr     (gfx_b_addr),
    .gfx_b_data     (16'd0),
    .gfx_b_req      (gfx_b_req),
    .gfx_b_ack      (gfx_b_req),   // echo request → ack

    // SDRAM (program ROM + sound ROM)
    .sdr_addr       (sdr_addr),
    .sdr_data       (32'd0),
    .sdr_req        (sdr_req),
    .sdr_ack        (sdr_req),     // echo request → ack

    // Video output
    .rgb_r          (rgb_r),
    .rgb_g          (rgb_g),
    .rgb_b          (rgb_b),
    .hsync_n        (hsync_n),
    .vsync_n        (vsync_n),
    .hblank         (hblank),
    .vblank         (vblank),

    // Player inputs (active-low, tie high = inactive)
    .joystick_p1    (8'd0),
    .joystick_p2    (8'd0),
    .coin           (2'd0),
    .service        (1'b1)
);

// ─────────────────────────────────────────────────────────────────────────
// LED output: XOR all outputs to single bit
// ─────────────────────────────────────────────────────────────────────────

assign led = ^rgb_r ^ ^rgb_g ^ ^rgb_b ^ hsync_n ^ vsync_n ^ hblank ^ vblank ^
             ^snd_dout ^ snd_dtack_n ^ snd_reset_n ^
             ^gfx_a_addr ^ gfx_a_req ^
             ^gfx_b_addr ^ gfx_b_req ^
             ^sdr_addr ^ sdr_req;

endmodule
