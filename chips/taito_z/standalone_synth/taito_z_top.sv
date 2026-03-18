// =============================================================================
// Taito Z — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module taito_z_top (
    input  wire clk,
    output wire led
);

// ─────────────────────────────────────────────────────────────────────────
// Output wires from taito_z (to be XORed into led)
// ─────────────────────────────────────────────────────────────────────────

wire [15:0] cpua_dout, cpub_dout;
wire        cpua_dtack_n, cpub_dtack_n;
wire [2:0]  cpua_ipl_n, cpub_ipl_n;
wire        cpub_reset_n;
wire [3:0][22:0] gfx_addr;
wire [3:0]       gfx_req;
wire [22:0] spr_addr;
wire        spr_req;
wire [17:0] stym_addr;
wire        stym_req;
wire [17:0] rod_rom_addr;
wire        rod_rom_req;
wire [26:0] sdr_addr;
wire        sdr_req;
wire [26:0] z80_rom_addr;
wire        z80_rom_req;
wire signed [15:0] snd_left, snd_right;
wire [7:0]  rgb_r, rgb_g, rgb_b;
wire        hsync_n, vsync_n, hblank, vblank;

// ─────────────────────────────────────────────────────────────────────────
// Instantiate taito_z with all inputs tied off, SDRAM ack echoes req
// ─────────────────────────────────────────────────────────────────────────

taito_z dut (
    // Clocks / Reset
    .clk_sys        (clk),
    .clk_pix        (clk),
    .reset_n        (1'b1),

    // CPU A bus (MC68000) — idle
    .cpua_addr      (23'd0),
    .cpua_din       (16'd0),
    .cpua_dout      (cpua_dout),
    .cpua_lds_n     (1'b1),        // no access
    .cpua_uds_n     (1'b1),        // no access
    .cpua_rw        (1'b1),        // read idle
    .cpua_as_n      (1'b1),        // no address strobe
    .cpua_dtack_n   (cpua_dtack_n),
    .cpua_ipl_n     (cpua_ipl_n),

    // CPU B bus (MC68000) — idle
    .cpub_addr      (23'd0),
    .cpub_din       (16'd0),
    .cpub_dout      (cpub_dout),
    .cpub_lds_n     (1'b1),
    .cpub_uds_n     (1'b1),
    .cpub_rw        (1'b1),
    .cpub_as_n      (1'b1),
    .cpub_dtack_n   (cpub_dtack_n),
    .cpub_ipl_n     (cpub_ipl_n),
    .cpub_reset_n   (cpub_reset_n),

    // GFX ROM (TC0480SCP) — echo each req→ack
    .gfx_addr       (gfx_addr),
    .gfx_data       ('{default: 32'd0}),
    .gfx_req        (gfx_req),
    .gfx_ack        (gfx_req),     // echo request → ack for all 4 engines

    // Sprite OBJ ROM (TC0370MSO) — echo req→ack
    .spr_addr       (spr_addr),
    .spr_data       (64'd0),
    .spr_req        (spr_req),
    .spr_ack        (spr_req),

    // Spritemap ROM (TC0370MSO STYM) — echo req→ack
    .stym_addr      (stym_addr),
    .stym_data      (16'd0),
    .stym_req       (stym_req),
    .stym_ack       (stym_req),

    // Road ROM (TC0150ROD) — echo req→ack
    .rod_rom_addr   (rod_rom_addr),
    .rod_rom_data   (16'd0),
    .rod_rom_req    (rod_rom_req),
    .rod_rom_ack    (rod_rom_req),

    // SDRAM (program ROM + ADPCM) — echo req→ack
    .sdr_addr       (sdr_addr),
    .sdr_data       (16'd0),
    .sdr_req        (sdr_req),
    .sdr_ack        (sdr_req),

    // Z80 ROM SDRAM — echo req→ack
    .z80_rom_addr   (z80_rom_addr),
    .z80_rom_data   (16'd0),
    .z80_rom_req    (z80_rom_req),
    .z80_rom_ack    (z80_rom_req),

    // Sound
    .clk_sound      (clk),         // sound clock (tied to main clk for synthesis)
    .snd_left       (snd_left),
    .snd_right      (snd_right),

    // Video
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
    .service        (1'b1),
    .wheel          (8'd0),
    .pedal          (8'd0)
);

// ─────────────────────────────────────────────────────────────────────────
// LED output: XOR all outputs to single bit
// ─────────────────────────────────────────────────────────────────────────

assign led = ^cpua_dout ^ ^cpub_dout ^
             cpua_dtack_n ^ cpub_dtack_n ^
             ^cpua_ipl_n ^ ^cpub_ipl_n ^ cpub_reset_n ^
             ^gfx_addr[0] ^ ^gfx_addr[1] ^ ^gfx_addr[2] ^ ^gfx_addr[3] ^
             gfx_req[0] ^ gfx_req[1] ^ gfx_req[2] ^ gfx_req[3] ^
             ^spr_addr ^ spr_req ^
             ^stym_addr ^ stym_req ^
             ^rod_rom_addr ^ rod_rom_req ^
             ^sdr_addr ^ sdr_req ^
             ^z80_rom_addr ^ z80_rom_req ^
             ^snd_left ^ ^snd_right ^
             ^rgb_r ^ ^rgb_g ^ ^rgb_b ^ hsync_n ^ vsync_n ^ hblank ^ vblank;

endmodule
