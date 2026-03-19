// =============================================================================
// tb_top.sv — Simulation top-level for Toaplan V2 (Batsugun)
//
// Combines toaplan_v2 + fx68k CPU so the Verilator testbench gets a real
// MC68000 CPU executing the Batsugun program ROM.
//
// Differences from NMK tb_top.sv:
//   - Instantiates toaplan_v2 instead of nmk_arcade
//   - toaplan_v2 has a single GFX ROM channel (32-bit) instead of
//     separate sprite/BG ROM channels
//   - toaplan_v2 has clk_sound input (Z80/YM2151 clock enable)
//   - Video timing is internal to toaplan_v2 (320×240, driven by clk_pix)
//   - No hpos/vpos/hblank/vblank inputs from testbench
//
// Clock enables:
//   enPhi1/enPhi2: driven from C++ testbench (C++-controlled phi)
//   clk_pix:      pixel clock enable (1-cycle pulse, every 2 sys clocks)
//   clk_sound:    Z80/YM2151 clock enable (~3.5 MHz CE)
//
// All SDRAM channels, video outputs, and audio are passed through as
// top-level ports so the C++ testbench can drive/capture them directly.
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        clk_pix,       // pixel clock enable (1-cycle pulse)
    input  logic        clk_sound,     // Z80/YM2151 CE (~3.5 MHz)
    input  logic        reset_n,

    // ── Program ROM SDRAM (toggle-handshake) ────────────────────────────────
    output logic [19:1] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM SDRAM (32-bit, toggle-handshake) ────────────────────────────
    output logic [21:0] gfx_rom_addr,
    input  logic [31:0] gfx_rom_data,
    output logic        gfx_rom_req,
    input  logic        gfx_rom_ack,

    // ── ADPCM ROM SDRAM ──────────────────────────────────────────────────────
    output logic [23:0] adpcm_rom_addr,
    output logic        adpcm_rom_req,
    input  logic [15:0] adpcm_rom_data,
    input  logic        adpcm_rom_ack,

    // ── Z80 Sound ROM SDRAM ──────────────────────────────────────────────────
    output logic [15:0] z80_rom_addr,
    output logic        z80_rom_req,
    input  logic  [7:0] z80_rom_data,
    input  logic        z80_rom_ack,

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
    output logic signed [15:0] snd_right,

    // ── Player Inputs ────────────────────────────────────────────────────────
    input  logic  [7:0] joystick_p1,
    input  logic  [7:0] joystick_p2,
    input  logic  [1:0] coin,
    input  logic        service,
    input  logic  [7:0] dipsw1,
    input  logic  [7:0] dipsw2,

    // ── Debug: CPU bus (testbench diagnostics only) ──────────────────────────
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n,
    output logic [15:0] dbg_cpu_dout,

    // ── Bus bypass: C++ testbench drives CPU data/DTACK directly ────────────
    input  logic        bypass_en,
    input  logic [15:0] bypass_data,
    input  logic        bypass_dtack_n,

    // ── Clock enables: driven from C++ testbench ─────────────────────────────
    input  logic        enPhi1,
    input  logic        enPhi2
);

// =============================================================================
// CPU bus wires (between fx68k and toaplan_v2)
// =============================================================================
logic [23:1] cpu_addr;
logic [15:0] cpu_din;    // CPU write data → toaplan_v2
logic [15:0] cpu_dout;   // toaplan_v2 read data → CPU
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic [2:0]  cpu_ipl_n;

// =============================================================================
// fx68k — MC68000 CPU (direct instantiation, C++-driven phi enables)
// =============================================================================
// Interrupt acknowledge detection (VPAn for autovector)
logic fx_FC0, fx_FC1, fx_FC2;
logic inta_n;
assign inta_n = ~&{fx_FC2, fx_FC1, fx_FC0, ~cpu_as_n};

logic cpu_halted_n_raw;
logic cpu_reset_n_out;

// =============================================================================
// Bus bypass: C++ testbench can drive iEdb and DTACKn directly.
// When bypass_en=1, CPU reads from bypass_data with bypass_dtack_n.
// When bypass_en=0, CPU reads from toaplan_v2's cpu_dout/cpu_dtack_n.
// =============================================================================
logic [15:0] cpu_iEdb_mux;
logic        cpu_dtack_mux;

assign cpu_iEdb_mux  = bypass_en ? bypass_data    : cpu_dout;
assign cpu_dtack_mux = bypass_en ? bypass_dtack_n : cpu_dtack_n;

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
    .iEdb       (cpu_iEdb_mux), // read data: bypass or toaplan_v2
    .oEdb       (cpu_din),      // write data from CPU → toaplan_v2

    // Address bus
    .eab        (cpu_addr)
);

assign dbg_cpu_halted_n = cpu_halted_n_raw;

// =============================================================================
// toaplan_v2 — full system (GP9001, palette, work RAM, Z80, audio, I/O)
// =============================================================================
toaplan_v2 u_toaplan (
    .clk_sys            (clk_sys),
    .clk_pix            (clk_pix),
    .clk_sound          (clk_sound),
    .reset_n            (reset_n),

    // CPU bus
    .cpu_addr           (cpu_addr),
    .cpu_dout           (cpu_din),      // write data FROM cpu TO toaplan_v2
    .cpu_din            (cpu_dout),     // read data FROM toaplan_v2 TO cpu
    .cpu_rw             (cpu_rw),
    .cpu_as_n           (cpu_as_n),
    .cpu_uds_n          (cpu_uds_n),
    .cpu_lds_n          (cpu_lds_n),
    .cpu_dtack_n        (cpu_dtack_n),
    .cpu_ipl_n          (cpu_ipl_n),

    // Program ROM
    .prog_rom_addr      (prog_rom_addr),
    .prog_rom_data      (prog_rom_data),
    .prog_rom_req       (prog_rom_req),
    .prog_rom_ack       (prog_rom_ack),

    // GFX ROM (32-bit, sprites + BG tiles)
    .gfx_rom_addr       (gfx_rom_addr),
    .gfx_rom_data       (gfx_rom_data),
    .gfx_rom_req        (gfx_rom_req),
    .gfx_rom_ack        (gfx_rom_ack),

    // ADPCM ROM
    .adpcm_rom_addr     (adpcm_rom_addr),
    .adpcm_rom_req      (adpcm_rom_req),
    .adpcm_rom_data     (adpcm_rom_data),
    .adpcm_rom_ack      (adpcm_rom_ack),

    // Z80 ROM
    .z80_rom_addr       (z80_rom_addr),
    .z80_rom_req        (z80_rom_req),
    .z80_rom_data       (z80_rom_data),
    .z80_rom_ack        (z80_rom_ack),

    // Video outputs
    .rgb_r              (rgb_r),
    .rgb_g              (rgb_g),
    .rgb_b              (rgb_b),
    .hsync_n            (hsync_n),
    .vsync_n            (vsync_n),
    .hblank             (hblank),
    .vblank             (vblank),

    // Audio
    .snd_left           (snd_left),
    .snd_right          (snd_right),

    // Player inputs
    .joystick_p1        (joystick_p1),
    .joystick_p2        (joystick_p2),
    .coin               (coin),
    .service            (service),
    .dipsw1             (dipsw1),
    .dipsw2             (dipsw2)
);

// Debug outputs expose internal CPU bus for testbench diagnostics
assign dbg_cpu_addr    = cpu_addr;
assign dbg_cpu_as_n    = cpu_as_n;
assign dbg_cpu_rw      = cpu_rw;
assign dbg_cpu_din     = cpu_din;
assign dbg_cpu_dtack_n = cpu_dtack_n;
assign dbg_cpu_dout    = cpu_dout;

endmodule
