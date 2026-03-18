// =============================================================================
// Taito B — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module taito_b_top (
    input  wire clk,
    output wire led
);

// ── Tie off internal outputs ────────────────────────────────────────────────
wire [15:0] cpu_dout;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire [15:0] z80_addr;
wire [7:0]  z80_din, z80_dout;
wire        z80_rd_n, z80_wr_n, z80_mreq_n, z80_iorq_n, z80_int_n;
wire        z80_rom_cs0_n, z80_rom_cs1_n, z80_ram_cs_n;
wire        z80_rom_a14, z80_rom_a15, z80_opx_n, z80_reset_n;
wire [26:0] gfx_rom_addr;
wire        gfx_rom_req;
wire [26:0] sdr_addr;
wire        sdr_req;
wire [26:0] z80_rom_addr;
wire        z80_rom_req;
wire [7:0]  rgb_r, rgb_g, rgb_b;
wire        hsync_n, vsync_n, hblank, vblank;
wire signed [15:0] snd_left, snd_right;

taito_b dut (
    // Clocks
    .clk_sys        (clk),
    .clk_pix        (1'b0),           // tied off
    .clk_pix2x      (1'b0),           // tied off
    .reset_n        (1'b1),

    // CPU bus — idle reads
    .cpu_addr       (23'b0),
    .cpu_din        (16'b0),
    .cpu_dout       (cpu_dout),
    .cpu_lds_n      (1'b1),
    .cpu_uds_n      (1'b1),
    .cpu_rw         (1'b1),           // read mode
    .cpu_as_n       (1'b1),           // not selected
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),

    // Z80 debug ports
    .z80_addr       (z80_addr),
    .z80_din        (z80_din),
    .z80_dout       (z80_dout),
    .z80_rd_n       (z80_rd_n),
    .z80_wr_n       (z80_wr_n),
    .z80_mreq_n     (z80_mreq_n),
    .z80_iorq_n     (z80_iorq_n),
    .z80_int_n      (z80_int_n),

    // Z80 decoded chip selects
    .z80_rom_cs0_n  (z80_rom_cs0_n),
    .z80_rom_cs1_n  (z80_rom_cs1_n),
    .z80_ram_cs_n   (z80_ram_cs_n),
    .z80_rom_a14    (z80_rom_a14),
    .z80_rom_a15    (z80_rom_a15),
    .z80_opx_n      (z80_opx_n),
    .z80_reset_n    (z80_reset_n),

    // GFX ROM — echo req→ack
    .gfx_rom_addr   (gfx_rom_addr),
    .gfx_rom_data   (16'd0),
    .gfx_rom_req    (gfx_rom_req),
    .gfx_rom_ack    (gfx_rom_req),    // echo: single-cycle response

    // SDRAM — echo req→ack for ADPCM
    .sdr_addr       (sdr_addr),
    .sdr_data       (16'd0),
    .sdr_req        (sdr_req),
    .sdr_ack        (sdr_req),        // echo: single-cycle response

    // Z80 ROM — echo req→ack
    .z80_rom_addr   (z80_rom_addr),
    .z80_rom_data   (16'd0),
    .z80_rom_req    (z80_rom_req),
    .z80_rom_ack    (z80_rom_req),    // echo: single-cycle response

    // Video outputs
    .rgb_r          (rgb_r),
    .rgb_g          (rgb_g),
    .rgb_b          (rgb_b),
    .hsync_n        (hsync_n),
    .vsync_n        (vsync_n),
    .hblank         (hblank),
    .vblank         (vblank),

    // Video timing inputs — tied off
    .hblank_n_in    (1'b1),
    .vblank_n_in    (1'b1),
    .hpos           (9'd0),
    .vpos           (8'd0),
    .hsync_n_in     (1'b1),
    .vsync_n_in     (1'b1),

    // Sound clock
    .clk_sound      (1'b0),

    // Audio outputs
    .snd_left       (snd_left),
    .snd_right      (snd_right),

    // Player inputs — all inactive (active low)
    .joystick_p1    (8'd0),
    .joystick_p2    (8'd0),
    .coin           (2'd0),
    .service        (1'b0),
    .dipsw1         (8'd0),
    .dipsw2         (8'd0)
);

// ── XOR all outputs into LED ────────────────────────────────────────────────
assign led = ^cpu_dout ^ cpu_dtack_n ^ ^cpu_ipl_n ^
             ^z80_addr ^ ^z80_din ^ ^z80_dout ^
             z80_rd_n ^ z80_wr_n ^ z80_mreq_n ^ z80_iorq_n ^ z80_int_n ^
             z80_rom_cs0_n ^ z80_rom_cs1_n ^ z80_ram_cs_n ^
             z80_rom_a14 ^ z80_rom_a15 ^ z80_opx_n ^ z80_reset_n ^
             ^gfx_rom_addr ^ gfx_rom_req ^ ^sdr_addr ^ sdr_req ^
             ^z80_rom_addr ^ z80_rom_req ^ ^rgb_r ^ ^rgb_g ^ ^rgb_b ^
             hsync_n ^ vsync_n ^ hblank ^ vblank ^ ^snd_left ^ ^snd_right;

endmodule
