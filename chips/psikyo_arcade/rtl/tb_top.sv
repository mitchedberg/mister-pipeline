// =============================================================================
// tb_top.sv — Simulation top-level for Psikyo Arcade
//
// Thin wrapper around psikyo_arcade.sv with all CPU bus signals exposed as
// top-level ports.  The MC68EC020 CPU is emulated in the C++ testbench
// (tb_system.cpp) using Musashi, which drives the CPU bus directly.
//
// This approach avoids the need to synthesize the TG68K VHDL core (which
// requires GHDL) and instead uses a well-tested software CPU model for sim.
//
// Clock scheme:
//   clk_sys  : 32 MHz system clock
//   clk_pix  : pixel clock enable (~6.4 MHz, /5 of 32 MHz)
//   clk_sound: sound clock enable (8 MHz, /4 of 32 MHz)
//
// SDRAM layout (byte addresses, from psikyo_arcade.sv / Gunbird.mra):
//   0x000000 — CPU program ROM (2 MB)
//   0x200000 — Sprite ROM (PS2001B / Gate 3)
//   0x600000 — BG tile ROM (PS3103 / Gate 4)
//   0xA00000 — ADPCM ROM (YM2610B)
//   0xA80000 — Z80 sound ROM (32 KB, per emu.sv)
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        reset_n,

    // ── Clock enables ────────────────────────────────────────────────────────
    input  logic        clk_pix,      // pixel clock enable (~6.4 MHz, /5 of 32 MHz)
    input  logic        clk_sound,    // sound clock enable (8 MHz, /4 of 32 MHz)

    // ── CPU Bus (driven by C++ testbench Musashi model) ──────────────────────
    input  logic [23:1] cpu_addr,     // word address
    input  logic [15:0] cpu_dout,     // CPU write data
    output logic [15:0] cpu_din,      // CPU read data
    input  logic        cpu_rw,       // 1=read, 0=write
    input  logic        cpu_as_n,     // address strobe (active low)
    input  logic        cpu_uds_n,    // upper data strobe (active low)
    input  logic        cpu_lds_n,    // lower data strobe (active low)
    output logic        cpu_dtack_n,  // data transfer acknowledge (active low)
    output logic [2:0]  cpu_ipl_n,    // interrupt priority level (active low)
    input  logic        cpu_inta_n,   // interrupt acknowledge (active low, FC=111 & ASn=0)

    // ── Program ROM SDRAM ────────────────────────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── Sprite ROM SDRAM ─────────────────────────────────────────────────────
    output logic [26:0] spr_rom_addr,
    input  logic [15:0] spr_rom_data,
    output logic        spr_rom_req,
    input  logic        spr_rom_ack,

    // ── BG Tile ROM SDRAM ────────────────────────────────────────────────────
    output logic [26:0] bg_rom_addr,
    input  logic [15:0] bg_rom_data,
    output logic        bg_rom_req,
    input  logic        bg_rom_ack,

    // ── ADPCM ROM SDRAM ──────────────────────────────────────────────────────
    output logic [26:0] adpcm_rom_addr,
    output logic        adpcm_rom_req,
    input  logic [15:0] adpcm_rom_data,
    input  logic        adpcm_rom_ack,

    // ── Z80 Sound ROM SDRAM ──────────────────────────────────────────────────
    output logic [15:0] z80_rom_addr,
    output logic        z80_rom_req,
    input  logic  [7:0] z80_rom_data,
    input  logic        z80_rom_ack,

    // ── Player Inputs ────────────────────────────────────────────────────────
    input  logic  [7:0] joystick_p1,
    input  logic  [7:0] joystick_p2,
    input  logic  [1:0] coin,
    input  logic        service,
    input  logic  [7:0] dipsw1,
    input  logic  [7:0] dipsw2,

    // ── Video Outputs ────────────────────────────────────────────────────────
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Audio Outputs ────────────────────────────────────────────────────────
    output logic signed [15:0] snd_left,
    output logic signed [15:0] snd_right
);

// =============================================================================
// psikyo_arcade — full Psikyo system (GPU, audio, I/O, SDRAM bridges)
// =============================================================================
psikyo_arcade u_psikyo (
    .clk_sys         (clk_sys),
    .clk_pix         (clk_pix),
    .clk_sound       (clk_sound),
    .reset_n         (reset_n),

    // CPU bus (driven externally by Musashi C++ model)
    .cpu_addr        (cpu_addr),
    .cpu_dout        (cpu_dout),
    .cpu_din         (cpu_din),
    .cpu_rw          (cpu_rw),
    .cpu_as_n        (cpu_as_n),
    .cpu_uds_n       (cpu_uds_n),
    .cpu_lds_n       (cpu_lds_n),
    .cpu_dtack_n     (cpu_dtack_n),
    .cpu_ipl_n       (cpu_ipl_n),
    .cpu_inta_n      (cpu_inta_n),

    // Program ROM
    .prog_rom_addr   (prog_rom_addr),
    .prog_rom_data   (prog_rom_data),
    .prog_rom_req    (prog_rom_req),
    .prog_rom_ack    (prog_rom_ack),

    // Sprite ROM
    .spr_rom_addr    (spr_rom_addr),
    .spr_rom_data16  (spr_rom_data),
    .spr_rom_req     (spr_rom_req),
    .spr_rom_ack     (spr_rom_ack),

    // BG tile ROM
    .bg_rom_addr     (bg_rom_addr),
    .bg_rom_data16   (bg_rom_data),
    .bg_rom_req      (bg_rom_req),
    .bg_rom_ack      (bg_rom_ack),

    // ADPCM ROM
    .adpcm_rom_addr  (adpcm_rom_addr),
    .adpcm_rom_req   (adpcm_rom_req),
    .adpcm_rom_data  (adpcm_rom_data),
    .adpcm_rom_ack   (adpcm_rom_ack),

    // Z80 sound ROM
    .z80_rom_addr    (z80_rom_addr),
    .z80_rom_req     (z80_rom_req),
    .z80_rom_data    (z80_rom_data),
    .z80_rom_ack     (z80_rom_ack),

    // Video outputs
    .rgb_r           (rgb_r),
    .rgb_g           (rgb_g),
    .rgb_b           (rgb_b),
    .hsync_n         (hsync_n),
    .vsync_n         (vsync_n),
    .hblank          (hblank),
    .vblank          (vblank),

    // Audio outputs
    .snd_left        (snd_left),
    .snd_right       (snd_right),

    // Player inputs
    .joystick_p1     (joystick_p1),
    .joystick_p2     (joystick_p2),
    .coin            (coin),
    .service         (service),
    .dipsw1          (dipsw1),
    .dipsw2          (dipsw2)
);

endmodule
