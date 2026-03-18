// =============================================================================
// Taito X System — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module taito_x_top (
    input  wire clk,
    output wire led
);

// ── Internal signal captures ────────────────────────────────────────────────

wire [15:0] cpu_dout;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;

wire [7:0]  z80_dout;
wire        z80_int_n;
wire        z80_reset_n;
wire        z80_rom_cs_n;
wire        z80_ram_cs_n;

wire [17:0] gfx_addr;
wire        gfx_req;

wire [26:0] sdr_addr;
wire        sdr_req;

wire [4:0]  rgb_r;
wire [4:0]  rgb_g;
wire [4:0]  rgb_b;
wire        hsync_n;
wire        vsync_n;
wire        hblank;
wire        vblank;

// ── Instantiate DUT ────────────────────────────────────────────────────────

taito_x dut (
    // Clocks / Reset
    .clk_sys        (clk),
    .clk_pix        (1'b0),         // No pixel strobe
    .reset_n        (1'b1),         // Active-high reset

    // MC68000 CPU Bus — all inputs tied off
    .cpu_addr       (23'd0),
    .cpu_din        (16'd0),
    .cpu_dout       (cpu_dout),
    .cpu_lds_n      (1'b1),
    .cpu_uds_n      (1'b1),
    .cpu_rw         (1'b1),         // Read (idle)
    .cpu_as_n       (1'b1),         // Address strobe inactive
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),

    // Z80 Sound CPU Bus — all inputs tied off
    .z80_addr       (16'd0),
    .z80_din        (8'd0),
    .z80_dout       (z80_dout),
    .z80_rd_n       (1'b1),
    .z80_wr_n       (1'b1),
    .z80_mreq_n     (1'b1),
    .z80_iorq_n     (1'b1),
    .z80_int_n      (z80_int_n),
    .z80_reset_n    (z80_reset_n),
    .z80_rom_cs_n   (z80_rom_cs_n),
    .z80_ram_cs_n   (z80_ram_cs_n),

    // GFX ROM Interface (toggle handshake)
    .gfx_addr       (gfx_addr),
    .gfx_data       (16'd0),
    .gfx_req        (gfx_req),
    .gfx_ack        (gfx_req),      // Echo req→ack

    // SDRAM (program ROM + Z80 audio ROM reads)
    .sdr_addr       (sdr_addr),
    .sdr_data       (16'd0),
    .sdr_req        (sdr_req),
    .sdr_ack        (sdr_req),      // Echo req→ack

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

assign led = ^cpu_dout ^ cpu_dtack_n ^ cpu_ipl_n
           ^ ^z80_dout ^ z80_int_n ^ z80_reset_n ^ z80_rom_cs_n ^ z80_ram_cs_n
           ^ ^gfx_addr ^ gfx_req
           ^ ^sdr_addr ^ sdr_req
           ^ ^rgb_r ^ ^rgb_g ^ ^rgb_b
           ^ hsync_n ^ vsync_n ^ hblank ^ vblank;

endmodule
