// =============================================================================
// tb_top.sv — Simulation top-level for SETA 1 Arcade (Dragon Unit / drgnunit)
//
// Combines seta_arcade + fx68k (MC68000) so the Verilator testbench gets a
// real MC68000 CPU executing the Dragon Unit program ROM.
//
// Key differences from NMK tb_top.sv:
//   - seta_arcade generates video timing INTERNALLY (no hblank_n_in/hpos/vpos)
//   - No Z80 sound CPU (X1-010 is a blocker — audio not implemented)
//   - GFX ROM uses zero-latency combinational toggle-handshake (X1-001A)
//   - Program ROM SDRAM uses toggle-handshake protocol
//   - bypass_en: C++ testbench can serve CPU data directly (for prog ROM bypass)
//
// Clock enables:
//   enPhi1/enPhi2 — MC68000 phi, driven from C++ testbench (top-level inputs)
//   clk_pix       — pixel clock enable, driven from C++ testbench
//
// Dragon Unit memory map (byte addresses, from MAME seta.cpp drgnunit_map):
//   0x000000-0x0BFFFF  Program ROM  (768KB, 256KB used)
//   0x100000-0x103FFF  X1-010 audio (stub)
//   0x200000-0x200001  Watchdog (nopw, NOT WRAM)
//   0x300000-0x300001  IRQ Ack (nopw - game writes here to clear IPL)
//   0x600000-0x600003  DIP switches
//   0x700000-0x7003FF  Palette RAM  (2KB)
//   0xB00000-0xB00007  Player inputs
//   0xD00000-0xD005FF  Sprite Y RAM (X1-001A)
//   0xD00600-0xD00607  Sprite ctrl regs
//   0xE00000-0xE03FFF  Sprite code RAM (X1-001A)
//   0xFFC000-0xFFFFFF  WORK RAM (16KB — supervisor stack + game state)
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        clk_pix,        // 1-cycle pixel clock enable
    input  logic        reset_n,

    // ── Program ROM SDRAM (68000 program ROM) ─────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM Interface (X1-001A sprites, 18-bit word addr) ─────────────────
    output logic [17:0] gfx_addr,
    input  logic [15:0] gfx_data,
    output logic        gfx_req,
    input  logic        gfx_ack,

    // ── Player Inputs (active-low) ────────────────────────────────────────────
    input  logic [7:0]  joystick_p1,
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,
    input  logic        service,
    input  logic [7:0]  dipsw1,
    input  logic [7:0]  dipsw2,

    // ── Video Outputs (5-bit, expanded to 8-bit in this module) ──────────────
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Debug: CPU bus (for testbench diagnostics only) ──────────────────────
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n,
    output logic [15:0] dbg_cpu_dout,
    output logic  [2:0] dbg_cpu_fc,

    // ── Bus bypass: C++ testbench drives CPU data/DTACK directly ─────────────
    // When bypass_en=1: CPU reads from bypass_data with bypass_dtack_n.
    // This is used to serve program ROM from the C++ SdramModel, bypassing
    // the broken combinational loop in seta_arcade.sv's prog_rom_req path.
    input  logic        bypass_en,
    input  logic [15:0] bypass_data,
    input  logic        bypass_dtack_n,

    // ── Clock enables: driven from C++ testbench ──────────────────────────────
    input  logic        enPhi1,         // MC68000 phi1 clock enable
    input  logic        enPhi2          // MC68000 phi2 clock enable
);

// =============================================================================
// CPU bus wires (between fx68k and seta_arcade)
// =============================================================================
logic [23:1] cpu_addr;
logic [15:0] cpu_din;       // CPU write data → seta_arcade
logic [15:0] cpu_dout;      // seta_arcade read data → CPU
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic [2:0]  cpu_ipl_n;

// =============================================================================
// fx68k — MC68000 CPU
// =============================================================================
logic fx_FC0, fx_FC1, fx_FC2;
logic inta_n;
// VPAn = IACK detection: ~&{FC2,FC1,FC0,~ASn}  (COMMUNITY_PATTERNS Section 1.2)
assign inta_n = ~&{fx_FC2, fx_FC1, fx_FC0, ~cpu_as_n};

logic cpu_halted_n_raw;
logic cpu_reset_n_out;

// =============================================================================
// Bus bypass and IACK handling
//
// bypass_en=1: CPU reads from bypass_data with bypass_dtack_n (ROM served from C++).
// bypass_en=0: CPU reads from seta_arcade's cpu_dout/cpu_dtack_n.
//
// IACK DTACK suppression: during interrupt acknowledge cycles (FC=111, AS#=0),
// force DTACKn HIGH so the CPU uses the autovector path (VPAn → AVEC) instead
// of getting a spurious DTACK from the bus.
// =============================================================================
logic [15:0] cpu_iEdb_mux;
logic        cpu_dtack_mux;

logic iack_cycle;
assign iack_cycle = fx_FC2 & fx_FC1 & fx_FC0 & ~cpu_as_n;

assign cpu_iEdb_mux  = bypass_en ? bypass_data    : cpu_dout;
assign cpu_dtack_mux = bypass_en ? bypass_dtack_n :
                       iack_cycle ? 1'b1           : cpu_dtack_n;

fx68k u_cpu (
    .clk        (clk_sys),
    .HALTn      (1'b1),
    .extReset   (!reset_n),
    .pwrUp      (!reset_n),
    .enPhi1     (enPhi1),
    .enPhi2     (enPhi2),

    // Bus outputs
    .eRWn       (cpu_rw),
    .ASn        (cpu_as_n),
    .LDSn       (cpu_lds_n),
    .UDSn       (cpu_uds_n),
    .E          (),
    .VMAn       (),

    // Function codes — for IACK detection
    .FC0        (fx_FC0),
    .FC1        (fx_FC1),
    .FC2        (fx_FC2),

    // Bus arbitration
    .BGn        (),
    .oRESETn    (cpu_reset_n_out),
    .oHALTEDn   (cpu_halted_n_raw),

    // Bus inputs
    .DTACKn     (cpu_dtack_mux),
    .VPAn       (inta_n),
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),

    // Interrupts
    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),

    // Data buses
    .iEdb       (cpu_iEdb_mux),    // read data: bypass or seta_arcade
    .oEdb       (cpu_din),         // write data from CPU → seta_arcade

    // Address bus
    .eab        (cpu_addr)
);

assign dbg_cpu_halted_n = cpu_halted_n_raw;

// =============================================================================
// seta_arcade — full system (sprite chip, palette, work RAM, I/O)
//
// Dragon Unit (drgnunit) parameters (from seta/seta.cpp):
//   WRAM_BASE  = 23'h100000  (0x200000 byte address / 2)
//   WRAM_ABITS = 15          (32K words = 64KB)
//   PAL1_BASE  = 23'h380000  (0x700000 byte address / 2)
//   Video:     384×240 @ 60 Hz
//   Sprite Y offset: FG_NOFLIP_YOFFS = 16 (from MAME x1_001.cpp set_fg_yoffsets)
// =============================================================================
logic [4:0] sx_rgb_r;
logic [4:0] sx_rgb_g;
logic [4:0] sx_rgb_b;

seta_arcade #(
    // drgnunit WRAM: 0xFFC000-0xFFFFFF (16KB)
    // word_base = 0xFFC000 >> 1 = 0x7FE000
    .WRAM_BASE       (23'h3FF000),  // byte 0xFFC000 / 2 = 0x7FE000; 23-bit: 0x3FF000
    .WRAM_ABITS      (13),          // 2^13 = 8K words = 16KB
    .PAL1_BASE       (23'h380000),  // byte 0x700000 / 2
    .PAL1_ABITS      (11),          // 2K words = 4KB
    // drgnunit sprite Y RAM: 0xD00000 / 2 = 0x680000
    .SRAM_Y_BASE     (23'h680000),  // byte 0xD00000 / 2
    // drgnunit sprite code RAM: 0xE00000 / 2 = 0x700000
    .SRAM_C_BASE     (23'h700000),  // byte 0xE00000 / 2
    .DIP_BASE        (23'h300000),  // byte 0x600000 / 2
    .JOY_BASE        (23'h580000),  // byte 0xB00000 / 2
    .H_VISIBLE       (384),
    .H_TOTAL         (512),
    .V_VISIBLE       (240),
    .V_TOTAL         (262),
    .FG_NOFLIP_YOFFS (16),          // drgnunit: MAME uses 0x10
    .FG_NOFLIP_XOFFS (0),
    .SPRITE_LIMIT    (511)
) u_seta (
    .clk_sys        (clk_sys),
    .clk_pix        (clk_pix),
    .reset_n        (reset_n),

    // 68000 CPU bus
    .cpu_addr       (cpu_addr),
    .cpu_din        (cpu_din),
    .cpu_dout       (cpu_dout),
    .cpu_lds_n      (cpu_lds_n),
    .cpu_uds_n      (cpu_uds_n),
    .cpu_rw         (cpu_rw),
    .cpu_as_n       (cpu_as_n),
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),
    .cpu_fc         ({fx_FC2, fx_FC1, fx_FC0}),

    // Program ROM SDRAM channel
    .prog_rom_addr  (prog_rom_addr),
    .prog_rom_data  (prog_rom_data),
    .prog_rom_req   (prog_rom_req),
    .prog_rom_ack   (prog_rom_ack),

    // GFX ROM (X1-001A sprite data)
    .gfx_addr       (gfx_addr),
    .gfx_data       (gfx_data),
    .gfx_req        (gfx_req),
    .gfx_ack        (gfx_ack),

    // Video output (5-bit)
    .rgb_r          (sx_rgb_r),
    .rgb_g          (sx_rgb_g),
    .rgb_b          (sx_rgb_b),
    .hsync_n        (hsync_n),
    .vsync_n        (vsync_n),
    .hblank         (hblank),
    .vblank         (vblank),

    // Player inputs
    .joystick_p1    (joystick_p1),
    .joystick_p2    (joystick_p2),
    .coin           (coin),
    .service        (service),
    .dipsw1         (dipsw1),
    .dipsw2         (dipsw2)
);

// Expand 5-bit RGB to 8-bit: replicate top 3 bits into low positions
assign rgb_r = {sx_rgb_r, sx_rgb_r[4:2]};
assign rgb_g = {sx_rgb_g, sx_rgb_g[4:2]};
assign rgb_b = {sx_rgb_b, sx_rgb_b[4:2]};

// Debug outputs expose internal CPU bus for testbench diagnostics
assign dbg_cpu_addr    = cpu_addr;
assign dbg_cpu_as_n    = cpu_as_n;
assign dbg_cpu_rw      = cpu_rw;
assign dbg_cpu_din     = cpu_din;
assign dbg_cpu_dtack_n = cpu_dtack_n;
assign dbg_cpu_dout    = cpu_dout;
assign dbg_cpu_fc      = {fx_FC2, fx_FC1, fx_FC0};

endmodule
