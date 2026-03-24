// =============================================================================
// deco16_arcade — Standalone Synthesis Harness
//
// Minimal wrapper that instantiates deco16_arcade with all inputs tied off.
// Used for Gate 3 standalone synthesis (5-15 min, fits DE-10 Nano).
// No MiSTer framework, no SDRAM controller, no audio codecs.
//
// GUARDRAILS Rule 2: every chip needs a standalone synthesis harness.
// =============================================================================
`default_nettype none

module deco16_arcade_top (
    input  wire clk,
    output wire led
);

// ── Declare all DUT outputs ──────────────────────────────────────────────────
wire [15:0] cpu_dout;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire [26:0] prog_rom_addr;
wire        prog_rom_req;
wire  [7:0] rgb_r;
wire  [7:0] rgb_g;
wire  [7:0] rgb_b;
wire        hsync_n;
wire        vsync_n;
wire        hblank;
wire        vblank;
wire signed [15:0] snd_left;
wire signed [15:0] snd_right;
wire [15:0] snd_rom_addr;
wire        snd_rom_req;

deco16_arcade dut (
    // Clocks / Reset
    .clk_sys        (clk),
    .clk_pix        (1'b0),
    .reset_n        (1'b1),

    // MC68000 CPU Bus — all inputs tied off
    .cpu_addr       (23'd0),
    .cpu_din        (16'd0),
    .cpu_dout       (cpu_dout),
    .cpu_lds_n      (1'b1),
    .cpu_uds_n      (1'b1),
    .cpu_rw         (1'b1),
    .cpu_as_n       (1'b1),
    .cpu_fc         (3'b000),
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),

    // Program ROM SDRAM Interface
    .prog_rom_addr  (prog_rom_addr),
    .prog_rom_data  (16'd0),
    .prog_rom_req   (prog_rom_req),
    .prog_rom_ack   (1'b0),

    // Video Output
    .rgb_r          (rgb_r),
    .rgb_g          (rgb_g),
    .rgb_b          (rgb_b),
    .hsync_n        (hsync_n),
    .vsync_n        (vsync_n),
    .hblank         (hblank),
    .vblank         (vblank),

    // Video Timing Inputs
    .hblank_n_in    (1'b1),
    .vblank_n_in    (1'b1),
    .hpos           (9'd0),
    .vpos           (9'd0),
    .hsync_n_in     (1'b1),
    .vsync_n_in     (1'b1),

    // Player Inputs
    .joystick_p1    (8'hFF),
    .joystick_p2    (8'hFF),
    .coin           (2'b11),
    .service        (1'b1),
    .dipsw1         (8'h00),
    .dipsw2         (8'h00),

    // Audio Output
    .snd_left       (snd_left),
    .snd_right      (snd_right),

    // Sound ROM SDRAM Interface
    .snd_rom_addr   (snd_rom_addr),
    .snd_rom_req    (snd_rom_req),
    .snd_rom_data   (8'd0),
    .snd_rom_ack    (1'b0)
);

// XOR all outputs to prevent optimization
assign led = ^cpu_dout ^ cpu_dtack_n ^ ^cpu_ipl_n ^
             ^prog_rom_addr ^ prog_rom_req ^
             ^rgb_r ^ ^rgb_g ^ ^rgb_b ^
             hsync_n ^ vsync_n ^ hblank ^ vblank ^
             ^snd_left ^ ^snd_right ^
             ^snd_rom_addr ^ snd_rom_req;

endmodule
