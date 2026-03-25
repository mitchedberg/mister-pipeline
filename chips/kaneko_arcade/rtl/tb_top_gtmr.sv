// =============================================================================
// tb_top_gtmr.sv — Simulation top-level for Kaneko16 Arcade (GTMR)
//
// GTMR memory map (byte addresses):
//   0x000000–0x07FFFF   512KB   Program ROM  (PROG_ROM_ABITS=19 → 512KB window)
//   0x100000–0x10FFFF   64KB    Work RAM      (WRAM_BASE = 23'h080000)
//   0x200000–0x20FFFF   64KB    Kaneko16 chip regs
//   0x400000–0x400FFF   4KB     Sprite RAM
//   0x500000–0x507FFF   32KB    Tilemap VRAM
//   0x600000–0x6003FF   1KB     Palette RAM   (PALRAM_BASE = 23'h300000)
//   0x700000–0x70000F   16B     I/O regs
//
// Key differences from berlwall tb_top.sv:
//   - WRAM_BASE = 23'h080000  (byte 0x100000 >> 1, not 0x200000)
//   - PROG_ROM_ABITS = 19     (512KB ROM window, avoids conflict with WRAM)
//   - PALRAM_BASE = 23'h300000 (byte 0x600000 >> 1)
//   - K16_BASE   = 23'h100000 (byte 0x200000 >> 1)
//
// Module is named tb_top so tb_system.cpp works without modification.
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        clk_pix,
    input  logic        reset_n,

    // ── Program ROM SDRAM ────────────────────────────────────────────────────────
    output logic [19:1] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM SDRAM (32-bit wide) ──────────────────────────────────────────────
    output logic [21:0] gfx_rom_addr,
    input  logic [31:0] gfx_rom_data,
    output logic        gfx_rom_req,
    input  logic        gfx_rom_ack,

    // ── ADPCM ROM SDRAM ──────────────────────────────────────────────────────────
    output logic [23:0] adpcm_rom_addr,
    output logic        adpcm_rom_req,
    input  logic  [7:0] adpcm_rom_data,
    input  logic        adpcm_rom_ack,

    // ── Z80 Sound ROM SDRAM ──────────────────────────────────────────────────────
    output logic [15:0] z80_rom_addr,
    output logic        z80_rom_req,
    input  logic  [7:0] z80_rom_data,
    input  logic        z80_rom_ack,

    // ── Sound clock enable ───────────────────────────────────────────────────────
    input  logic        clk_sound_cen,

    // ── Player Inputs ────────────────────────────────────────────────────────────
    input  logic  [7:0] joystick_p1,
    input  logic  [7:0] joystick_p2,
    input  logic  [1:0] coin,
    input  logic        service,
    input  logic  [7:0] dipsw1,
    input  logic  [7:0] dipsw2,

    // ── Video Outputs ────────────────────────────────────────────────────────────
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Audio Outputs ────────────────────────────────────────────────────────────
    output logic [15:0] snd_left,
    output logic [15:0] snd_right,

    // ── Debug ────────────────────────────────────────────────────────────────────
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n,
    output logic [15:0] dbg_cpu_dout,
    output logic [2:0]  dbg_cpu_ipl_n,
    output logic        dbg_iack,

    // ── Bus bypass ───────────────────────────────────────────────────────────────
    input  logic        bypass_en,
    input  logic [15:0] bypass_data,
    input  logic        bypass_dtack_n,

    // ── Clock enables ────────────────────────────────────────────────────────────
    input  logic        enPhi1,
    input  logic        enPhi2
);

// CPU bus wires
logic [23:1] cpu_addr;
logic [15:0] cpu_write_data;
logic [15:0] cpu_read_data;
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic [2:0]  cpu_ipl_n;

logic fx_FC0, fx_FC1, fx_FC2;
logic inta_n;
assign inta_n = ~&{fx_FC2, fx_FC1, fx_FC0, ~cpu_as_n};

logic cpu_halted_n_raw;
logic cpu_reset_n_out;

logic [15:0] cpu_iEdb_mux;
logic        cpu_dtack_mux;
logic        iack_cycle;

assign cpu_iEdb_mux  = bypass_en ? bypass_data : cpu_read_data;
assign iack_cycle    = fx_FC2 & fx_FC1 & fx_FC0 & ~cpu_as_n;
assign cpu_dtack_mux = bypass_en  ? bypass_dtack_n :
                       iack_cycle ? 1'b1           : cpu_dtack_n;

fx68k u_cpu (
    .clk        (clk_sys),
    .HALTn      (1'b1),
    .extReset   (!reset_n),
    .pwrUp      (!reset_n),
    .enPhi1     (enPhi1),
    .enPhi2     (enPhi2),
    .eRWn       (cpu_rw),
    .ASn        (cpu_as_n),
    .LDSn       (cpu_lds_n),
    .UDSn       (cpu_uds_n),
    .E          (),
    .VMAn       (),
    .FC0        (fx_FC0),
    .FC1        (fx_FC1),
    .FC2        (fx_FC2),
    .BGn        (),
    .oRESETn    (cpu_reset_n_out),
    .oHALTEDn   (cpu_halted_n_raw),
    .DTACKn     (cpu_dtack_mux),
    .VPAn       (inta_n),
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),
    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),
    .iEdb       (cpu_iEdb_mux),
    .oEdb       (cpu_write_data),
    .eab        (cpu_addr)
);

assign dbg_cpu_halted_n = cpu_halted_n_raw;

// =============================================================================
// kaneko_arcade — GTMR address map
//
// GTMR memory map (byte → word):
//   ROM:      0x000000-0x07FFFF → PROG_ROM_ABITS=19 (512KB CS window)
//   Work RAM: 0x100000-0x10FFFF → WRAM_BASE=23'h080000
//   K16 regs: 0x200000-0x20FFFF → K16_BASE=23'h100000
//   Spr RAM:  0x400000-0x400FFF → SPR_BASE=23'h200000
//   VRAM:     0x500000-0x507FFF → VRAM_BASE=23'h280000
//   Palette:  0x600000-0x6003FF → PALRAM_BASE=23'h300000
//   I/O:      0x700000-0x70000F → IO_BASE=23'h380000
//   Layer:    0xD00000-...      → LAYER_BASE=23'h680000 (unchanged)
// =============================================================================
kaneko_arcade #(
    .PROG_ROM_ABITS (19),          // 512KB ROM window → word 0x000000-0x03FFFF
    .WRAM_BASE      (23'h080000),  // byte 0x100000 >> 1
    .K16_BASE       (23'h100000),  // byte 0x200000 >> 1
    .SPR_BASE       (23'h200000),  // byte 0x400000 >> 1
    .VRAM_BASE      (23'h280000),  // byte 0x500000 >> 1
    .PALRAM_BASE    (23'h300000),  // byte 0x600000 >> 1
    .IO_BASE        (23'h380000),  // byte 0x700000 >> 1 (unchanged)
    .LAYER_BASE     (23'h680000)   // byte 0xD00000 >> 1 (unchanged)
) u_kaneko (
    .clk_sys            (clk_sys),
    .clk_pix            (clk_pix),
    .reset_n            (reset_n),

    .cpu_addr           (cpu_addr),
    .cpu_dout           (cpu_write_data),
    .cpu_din            (cpu_read_data),
    .cpu_lds_n          (cpu_lds_n),
    .cpu_uds_n          (cpu_uds_n),
    .cpu_rw             (cpu_rw),
    .cpu_as_n           (cpu_as_n),
    .cpu_dtack_n        (cpu_dtack_n),
    .cpu_ipl_n          (cpu_ipl_n),
    .cpu_fc             ({fx_FC2, fx_FC1, fx_FC0}),

    .prog_rom_addr      (prog_rom_addr),
    .prog_rom_data      (prog_rom_data),
    .prog_rom_req       (prog_rom_req),
    .prog_rom_ack       (prog_rom_ack),

    .gfx_rom_addr       (gfx_rom_addr),
    .gfx_rom_data       (gfx_rom_data),
    .gfx_rom_req        (gfx_rom_req),
    .gfx_rom_ack        (gfx_rom_ack),

    .adpcm_rom_addr     (adpcm_rom_addr),
    .adpcm_rom_req      (adpcm_rom_req),
    .adpcm_rom_data     (adpcm_rom_data),
    .adpcm_rom_ack      (adpcm_rom_ack),

    .clk_sound_cen      (clk_sound_cen),

    .z80_rom_addr       (z80_rom_addr),
    .z80_rom_req        (z80_rom_req),
    .z80_rom_data       (z80_rom_data),
    .z80_rom_ack        (z80_rom_ack),

    .joystick_p1        (joystick_p1),
    .joystick_p2        (joystick_p2),
    .coin               (coin),
    .service            (service),
    .dipsw1             (dipsw1),
    .dipsw2             (dipsw2),

    .rgb_r              (rgb_r),
    .rgb_g              (rgb_g),
    .rgb_b              (rgb_b),
    .hsync_n            (hsync_n),
    .vsync_n            (vsync_n),
    .hblank             (hblank),
    .vblank             (vblank),

    .snd_left           (snd_left),
    .snd_right          (snd_right)
);

assign dbg_cpu_addr    = cpu_addr;
assign dbg_cpu_as_n    = cpu_as_n;
assign dbg_cpu_rw      = cpu_rw;
assign dbg_cpu_din     = cpu_write_data;
assign dbg_cpu_dtack_n = cpu_dtack_n;
assign dbg_cpu_dout    = cpu_read_data;
assign dbg_cpu_ipl_n   = cpu_ipl_n;
assign dbg_iack        = iack_cycle;

endmodule
