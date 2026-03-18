// =============================================================================
// kaneko_arcade — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module kaneko_arcade_top (
    input  wire clk,
    output wire led
);

// Declare all outputs from kaneko_arcade
wire [15:0] cpu_din;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire [19:1] prog_rom_addr;
wire        prog_rom_req;
wire [21:0] gfx_rom_addr;
wire        gfx_rom_req;
wire [7:0]  rgb_r;
wire [7:0]  rgb_g;
wire [7:0]  rgb_b;
wire        hsync_n;
wire        vsync_n;
wire        hblank;
wire        vblank;
wire [15:0] snd_left;
wire [15:0] snd_right;
wire [23:0] adpcm_rom_addr;
wire        adpcm_rom_req;
wire [15:0] z80_rom_addr;
wire        z80_rom_req;

kaneko_arcade dut (
    // Clocks / Reset
    .clk_sys          (clk),
    .clk_pix          (1'b0),
    .reset_n          (1'b1),

    // MC68000 CPU Bus
    .cpu_addr         (23'd0),
    .cpu_dout         (16'd0),
    .cpu_din          (cpu_din),
    .cpu_rw           (1'b1),
    .cpu_as_n         (1'b1),
    .cpu_uds_n        (1'b1),
    .cpu_lds_n        (1'b1),
    .cpu_dtack_n      (cpu_dtack_n),
    .cpu_ipl_n        (cpu_ipl_n),

    // Program ROM SDRAM Interface
    .prog_rom_addr    (prog_rom_addr),
    .prog_rom_data    (16'd0),
    .prog_rom_req     (prog_rom_req),
    .prog_rom_ack     (1'b0),

    // GFX ROM SDRAM Interface
    .gfx_rom_addr     (gfx_rom_addr),
    .gfx_rom_data     (32'd0),
    .gfx_rom_req      (gfx_rom_req),
    .gfx_rom_ack      (1'b0),

    // Video Output
    .rgb_r            (rgb_r),
    .rgb_g            (rgb_g),
    .rgb_b            (rgb_b),
    .hsync_n          (hsync_n),
    .vsync_n          (vsync_n),
    .hblank           (hblank),
    .vblank           (vblank),

    // Player Inputs
    .joystick_p1      (8'hFF),
    .joystick_p2      (8'hFF),
    .coin             (2'b11),
    .service          (1'b1),
    .dipsw1           (8'h00),
    .dipsw2           (8'h00),

    // Audio Output
    .snd_left         (snd_left),
    .snd_right        (snd_right),

    // ADPCM ROM SDRAM Interface
    .adpcm_rom_addr   (adpcm_rom_addr),
    .adpcm_rom_req    (adpcm_rom_req),
    .adpcm_rom_data   (8'd0),
    .adpcm_rom_ack    (1'b0),

    // Sound clock enable
    .clk_sound_cen    (1'b0),

    // Z80 Sound CPU ROM SDRAM Interface
    .z80_rom_addr     (z80_rom_addr),
    .z80_rom_req      (z80_rom_req),
    .z80_rom_data     (8'd0),
    .z80_rom_ack      (1'b0)
);

// XOR all outputs together into led
assign led = ^cpu_din ^ cpu_dtack_n ^ ^cpu_ipl_n ^
             ^prog_rom_addr ^ prog_rom_req ^
             ^gfx_rom_addr ^ gfx_rom_req ^
             ^rgb_r ^ ^rgb_g ^ ^rgb_b ^
             hsync_n ^ vsync_n ^ hblank ^ vblank ^
             ^snd_left ^ ^snd_right ^
             ^adpcm_rom_addr ^ adpcm_rom_req ^
             ^z80_rom_addr ^ z80_rom_req;

endmodule
