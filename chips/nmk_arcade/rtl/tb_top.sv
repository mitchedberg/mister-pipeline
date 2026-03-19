// =============================================================================
// tb_top.sv — Simulation top-level for NMK Arcade
//
// Combines nmk_arcade + fx68k_adapter so the Verilator testbench gets a real
// MC68000 CPU executing the Thunder Dragon program ROM.
//
// Clock enables:
//   cpu_ce: generated internally as divide-by-4 of clk_sys → 10 MHz from 40 MHz
//
// All SDRAM channels, video timing, I/O, and audio are passed through as
// top-level ports so the C++ testbench can drive / capture them directly.
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        clk_pix,
    input  logic        reset_n,

    // ── Program ROM SDRAM ────────────────────────────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── Sprite ROM SDRAM ─────────────────────────────────────────────────────────
    output logic [26:0] spr_rom_sdram_addr,
    input  logic [15:0] spr_rom_sdram_data,
    output logic        spr_rom_sdram_req,
    input  logic        spr_rom_sdram_ack,

    // ── BG Tile ROM SDRAM ────────────────────────────────────────────────────────
    output logic [26:0] bg_rom_sdram_addr,
    input  logic [15:0] bg_rom_sdram_data,
    output logic        bg_rom_sdram_req,
    input  logic        bg_rom_sdram_ack,

    // ── ADPCM ROM SDRAM ──────────────────────────────────────────────────────────
    output logic [23:0] adpcm_rom_addr,
    output logic        adpcm_rom_req,
    input  logic [15:0] adpcm_rom_data,
    input  logic        adpcm_rom_ack,

    // ── Z80 Sound ROM SDRAM ──────────────────────────────────────────────────────
    output logic [15:0] z80_rom_addr,
    output logic        z80_rom_req,
    input  logic  [7:0] z80_rom_data,
    input  logic        z80_rom_ack,

    // ── Video Timing Inputs ──────────────────────────────────────────────────────
    input  logic        hblank_n_in,
    input  logic        vblank_n_in,
    input  logic  [8:0] hpos,
    input  logic  [7:0] vpos,
    input  logic        hsync_n_in,
    input  logic        vsync_n_in,

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
    output logic signed [15:0] snd_left,
    output logic signed [15:0] snd_right,

    // ── Debug: CPU bus (for testbench diagnostics only) ──────────────────────────
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_din,
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n,   // oHALTEDn from fx68k (low = CPU halted)
    output logic [15:0] dbg_cpu_dout,       // read data FROM nmk_arcade TO CPU (iEdb)

    // ── Bus bypass: C++ testbench drives CPU data/DTACK directly ───────────────
    input  logic        bypass_en,
    input  logic [15:0] bypass_data,
    input  logic        bypass_dtack_n,

    // ── Clock enables: driven from C++ testbench ───────────────────────────────
    input  logic        enPhi1,
    input  logic        enPhi2
);

// =============================================================================
// CPU bus wires (between fx68k and nmk_arcade)
// =============================================================================
logic [23:1] cpu_addr;
logic [15:0] cpu_din;    // CPU write data → nmk_arcade
logic [15:0] cpu_dout;   // nmk_arcade read data → CPU
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic [2:0]  cpu_ipl_n;

// enPhi1/enPhi2 driven from C++ testbench (top-level inputs above)
// This is required because RTL-generated phi causes Verilator scheduling issues.

// =============================================================================
// fx68k — MC68000 CPU (direct instantiation, bypassing fx68k_adapter for
// tighter control over clock enables via fx68k_dtack_cen)
// =============================================================================
// Interrupt acknowledge detection (VPAn for autovector)
logic fx_FC0, fx_FC1, fx_FC2;
logic inta_n;
assign inta_n = ~&{fx_FC2, fx_FC1, fx_FC0, ~cpu_as_n};

logic cpu_halted_n_raw;
logic cpu_reset_n_out;

// =============================================================================
// Bus bypass: C++ testbench can drive iEdb and DTACKn directly for ROM reads.
// When bypass_en=1, CPU reads from bypass_data with bypass_dtack_n.
// When bypass_en=0, CPU reads from nmk_arcade's cpu_dout/cpu_dtack_n.
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
    .iEdb       (cpu_iEdb_mux), // read data: bypass or nmk_arcade
    .oEdb       (cpu_din),      // write data from CPU → nmk_arcade

    // Address bus
    .eab        (cpu_addr)
);

assign dbg_cpu_halted_n = cpu_halted_n_raw;

// =============================================================================
// nmk_arcade — full system (GPU, palette, work RAM, Z80, audio, I/O)
// =============================================================================
nmk_arcade u_nmk (
    .clk_sys            (clk_sys),
    .clk_pix            (clk_pix),
    .reset_n            (reset_n),

    // CPU bus
    .cpu_addr           (cpu_addr),
    .cpu_din            (cpu_din),
    .cpu_dout           (cpu_dout),
    .cpu_lds_n          (cpu_lds_n),
    .cpu_uds_n          (cpu_uds_n),
    .cpu_rw             (cpu_rw),
    .cpu_as_n           (cpu_as_n),
    .cpu_dtack_n        (cpu_dtack_n),
    .cpu_ipl_n          (cpu_ipl_n),

    // Program ROM
    .prog_rom_addr      (prog_rom_addr),
    .prog_rom_data      (prog_rom_data),
    .prog_rom_req       (prog_rom_req),
    .prog_rom_ack       (prog_rom_ack),

    // Sprite ROM
    .spr_rom_sdram_addr (spr_rom_sdram_addr),
    .spr_rom_sdram_data (spr_rom_sdram_data),
    .spr_rom_sdram_req  (spr_rom_sdram_req),
    .spr_rom_sdram_ack  (spr_rom_sdram_ack),

    // BG tile ROM
    .bg_rom_sdram_addr  (bg_rom_sdram_addr),
    .bg_rom_sdram_data  (bg_rom_sdram_data),
    .bg_rom_sdram_req   (bg_rom_sdram_req),
    .bg_rom_sdram_ack   (bg_rom_sdram_ack),

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

    // Video timing inputs
    .hblank_n_in        (hblank_n_in),
    .vblank_n_in        (vblank_n_in),
    .hpos               (hpos),
    .vpos               (vpos),
    .hsync_n_in         (hsync_n_in),
    .vsync_n_in         (vsync_n_in),

    // Player inputs
    .joystick_p1        (joystick_p1),
    .joystick_p2        (joystick_p2),
    .coin               (coin),
    .service            (service),
    .dipsw1             (dipsw1),
    .dipsw2             (dipsw2),

    // Video outputs
    .rgb_r              (rgb_r),
    .rgb_g              (rgb_g),
    .rgb_b              (rgb_b),
    .hsync_n            (hsync_n),
    .vsync_n            (vsync_n),
    .hblank             (hblank),
    .vblank             (vblank),

    // Audio outputs
    .snd_left           (snd_left),
    .snd_right          (snd_right)
);

// Debug outputs expose internal CPU bus for testbench diagnostics
assign dbg_cpu_addr    = cpu_addr;
assign dbg_cpu_as_n    = cpu_as_n;
assign dbg_cpu_rw      = cpu_rw;
assign dbg_cpu_din     = cpu_din;
assign dbg_cpu_dtack_n = cpu_dtack_n;
assign dbg_cpu_dout    = cpu_dout;   // read data path (nmk_arcade → CPU)
// dbg_cpu_halted_n is wired directly from u_cpu.cpu_halted_n above

endmodule
