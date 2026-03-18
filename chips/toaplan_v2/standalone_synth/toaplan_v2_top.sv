// =============================================================================
// Toaplan V2 — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module toaplan_v2_top (
    input  wire clk,
    output wire led
);

// ── Tie off internal outputs ────────────────────────────────────────────────
wire [15:0] cpu_din;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire [19:1] prog_rom_addr;
wire        prog_rom_req;
wire [21:0] gfx_rom_addr;
wire        gfx_rom_req;
wire signed [15:0] snd_left, snd_right;
wire [23:0] adpcm_rom_addr;
wire        adpcm_rom_req;
wire [15:0] z80_rom_addr;
wire        z80_rom_req;
wire [7:0]  rgb_r, rgb_g, rgb_b;
wire        hsync_n, vsync_n, hblank, vblank;

toaplan_v2 dut (
    // Clocks
    .clk_sys        (clk),
    .clk_pix        (1'b0),           // tied off
    .reset_n        (1'b1),

    // CPU bus — idle reads
    .cpu_addr       (23'b0),
    .cpu_dout       (16'b0),
    .cpu_din        (cpu_din),
    .cpu_rw         (1'b1),           // read mode
    .cpu_as_n       (1'b1),           // not selected
    .cpu_uds_n      (1'b1),
    .cpu_lds_n      (1'b1),
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),

    // Program ROM — echo req→ack
    .prog_rom_addr  (prog_rom_addr),
    .prog_rom_data  (16'd0),
    .prog_rom_req   (prog_rom_req),
    .prog_rom_ack   (prog_rom_req),   // echo: single-cycle response

    // GFX ROM — echo req→ack
    .gfx_rom_addr   (gfx_rom_addr),
    .gfx_rom_data   (32'd0),
    .gfx_rom_req    (gfx_rom_req),
    .gfx_rom_ack    (gfx_rom_req),

    // Audio outputs
    .snd_left       (snd_left),
    .snd_right      (snd_right),

    // ADPCM ROM — echo req→ack
    .adpcm_rom_addr (adpcm_rom_addr),
    .adpcm_rom_data (16'd0),
    .adpcm_rom_req  (adpcm_rom_req),
    .adpcm_rom_ack  (adpcm_rom_req),

    // Z80 ROM — echo req→ack
    .z80_rom_addr   (z80_rom_addr),
    .z80_rom_data   (8'd0),
    .z80_rom_req    (z80_rom_req),
    .z80_rom_ack    (z80_rom_req),

    // Sound clock
    .clk_sound      (1'b0),

    // Video outputs
    .rgb_r          (rgb_r),
    .rgb_g          (rgb_g),
    .rgb_b          (rgb_b),
    .hsync_n        (hsync_n),
    .vsync_n        (vsync_n),
    .hblank         (hblank),
    .vblank         (vblank),

    // Player inputs — all inactive (active low)
    .joystick_p1    (8'd0),
    .joystick_p2    (8'd0),
    .coin           (2'd0),
    .service        (1'b0),
    .dipsw1         (8'd0),
    .dipsw2         (8'd0)
);

// ── XOR all outputs into LED ────────────────────────────────────────────────
assign led = ^cpu_din ^ cpu_dtack_n ^ ^cpu_ipl_n ^
             ^prog_rom_addr ^ prog_rom_req ^ ^gfx_rom_addr ^ gfx_rom_req ^
             ^snd_left ^ ^snd_right ^ ^adpcm_rom_addr ^ adpcm_rom_req ^
             ^z80_rom_addr ^ z80_rom_req ^ ^rgb_r ^ ^rgb_g ^ ^rgb_b ^
             hsync_n ^ vsync_n ^ hblank ^ vblank;

endmodule
