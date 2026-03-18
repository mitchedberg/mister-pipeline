// =============================================================================
// Psikyo Arcade — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module psikyo_arcade_top (
    input  wire clk,
    output wire led
);

// ── Internal signal captures ────────────────────────────────────────────────

wire [15:0] cpu_din;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;

wire [26:0] prog_rom_addr;
wire        prog_rom_req;

wire [26:0] spr_rom_addr;
wire        spr_rom_req;

wire [26:0] bg_rom_addr;
wire        bg_rom_req;

wire signed [15:0] snd_left;
wire signed [15:0] snd_right;

wire [26:0] adpcm_rom_addr;
wire        adpcm_rom_req;

wire [15:0] z80_rom_addr;
wire        z80_rom_req;

wire [7:0]  rgb_r;
wire [7:0]  rgb_g;
wire [7:0]  rgb_b;
wire        hsync_n;
wire        vsync_n;
wire        hblank;
wire        vblank;

// ── Instantiate DUT ────────────────────────────────────────────────────────

psikyo_arcade dut (
    // Clocks / Reset
    .clk_sys        (clk),
    .clk_pix        (1'b0),         // No pixel strobe
    .reset_n        (1'b1),         // Active-high reset

    // MC68000 CPU Bus — all inputs tied off
    .cpu_addr       (23'd0),
    .cpu_dout       (16'd0),
    .cpu_din        (cpu_din),
    .cpu_rw         (1'b1),         // Read (idle)
    .cpu_as_n       (1'b1),         // Address strobe inactive
    .cpu_uds_n      (1'b1),         // Upper data strobe inactive
    .cpu_lds_n      (1'b1),         // Lower data strobe inactive
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),

    // Program ROM SDRAM interface
    .prog_rom_addr  (prog_rom_addr),
    .prog_rom_data  (16'd0),
    .prog_rom_req   (prog_rom_req),
    .prog_rom_ack   (prog_rom_req),  // Echo req→ack

    // Sprite ROM SDRAM interface
    .spr_rom_addr   (spr_rom_addr),
    .spr_rom_data16 (16'd0),
    .spr_rom_req    (spr_rom_req),
    .spr_rom_ack    (spr_rom_req),

    // BG tile ROM SDRAM interface
    .bg_rom_addr    (bg_rom_addr),
    .bg_rom_data16  (16'd0),
    .bg_rom_req     (bg_rom_req),
    .bg_rom_ack     (bg_rom_req),

    // Audio Output
    .snd_left       (snd_left),
    .snd_right      (snd_right),

    // ADPCM ROM SDRAM interface
    .adpcm_rom_addr (adpcm_rom_addr),
    .adpcm_rom_req  (adpcm_rom_req),
    .adpcm_rom_data (16'd0),
    .adpcm_rom_ack  (adpcm_rom_req),

    // Sound clock
    .clk_sound      (1'b0),

    // Z80 Sound CPU ROM SDRAM interface
    .z80_rom_addr   (z80_rom_addr),
    .z80_rom_req    (z80_rom_req),
    .z80_rom_data   (8'd0),
    .z80_rom_ack    (z80_rom_req),

    // Z80 Sound CPU Bus — all inputs tied off
    .z80_addr       (16'd0),
    .z80_din        (8'd0),
    .z80_dout       (/* unused */),
    .z80_rd_n       (1'b1),
    .z80_wr_n       (1'b1),
    .z80_mreq_n     (1'b1),
    .z80_iorq_n     (1'b1),
    .z80_int_n      (/* unused */),
    .z80_reset_n    (/* unused */),
    .z80_rom_cs_n   (/* unused */),
    .z80_ram_cs_n   (/* unused */),

    // Video Output
    .rgb_r          (rgb_r),
    .rgb_g          (rgb_g),
    .rgb_b          (rgb_b),
    .hsync_n        (hsync_n),
    .vsync_n        (vsync_n),
    .hblank         (hblank),
    .vblank         (vblank),

    // Player Inputs — all active-low, tied idle
    .joystick_p1    (8'hFF),
    .joystick_p2    (8'hFF),
    .coin           (2'b11),
    .service        (1'b1),
    .dipsw1         (8'h00),
    .dipsw2         (8'h00)
);

// ── XOR all outputs into LED ───────────────────────────────────────────────
// This prevents optimization from removing all logic.

assign led = ^cpu_din ^ cpu_dtack_n ^ cpu_ipl_n
           ^ ^prog_rom_addr ^ prog_rom_req
           ^ ^spr_rom_addr ^ spr_rom_req
           ^ ^bg_rom_addr ^ bg_rom_req
           ^ ^snd_left ^ ^snd_right
           ^ ^adpcm_rom_addr ^ adpcm_rom_req
           ^ ^z80_rom_addr ^ z80_rom_req
           ^ ^rgb_r ^ ^rgb_g ^ ^rgb_b
           ^ hsync_n ^ vsync_n ^ hblank ^ vblank;

endmodule
