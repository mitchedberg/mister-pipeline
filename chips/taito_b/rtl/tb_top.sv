// =============================================================================
// tb_top.sv — Simulation top-level for Taito B (Nastar Warrior)
//
// Combines taito_b + fx68k CPU so the Verilator testbench gets a real MC68000
// executing the Nastar Warrior program ROM.
//
// Key differences from NMK tb_top:
//   - taito_b has the Z80 instantiated internally (T80s). The Z80 debug ports
//     are outputs only — do NOT instantiate T80s here.
//   - 4 SDRAM channels: prog (16-bit toggle), gfx (16-bit toggle), sdr/adpcm
//     (16-bit toggle), z80 (16-bit toggle — taito_b selects correct byte).
//   - clk_sound input (4 MHz clock enable, every 8 sys clocks)
//   - clk_pix2x input (tied to 1'b1 in testbench — TC0260DAR ce_double stub)
//
// Clock enables:
//   enPhi1/enPhi2: C++-driven top-level inputs (Rule 13)
//
// VPAn: IACK detection (~&{FC2,FC1,FC0,~ASn}) — never 1'b1 (Rule critical)
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        reset_n,

    // ── Program ROM SDRAM ────────────────────────────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM SDRAM ────────────────────────────────────────────────────────────
    output logic [26:0] gfx_rom_addr,
    input  logic [15:0] gfx_rom_data,
    output logic        gfx_rom_req,
    input  logic        gfx_rom_ack,

    // ── ADPCM / SDR ROM SDRAM ────────────────────────────────────────────────────
    output logic [26:0] sdr_addr,
    input  logic [15:0] sdr_data,
    output logic        sdr_req,
    input  logic        sdr_ack,

    // ── Z80 ROM SDRAM ────────────────────────────────────────────────────────────
    output logic [26:0] z80_rom_addr,
    input  logic [15:0] z80_rom_data,
    output logic        z80_rom_req,
    input  logic        z80_rom_ack,

    // ── Video Timing Inputs ──────────────────────────────────────────────────────
    input  logic        hblank_n_in,
    input  logic        vblank_n_in,
    input  logic  [8:0] hpos,
    input  logic  [7:0] vpos,
    input  logic        hsync_n_in,
    input  logic        vsync_n_in,

    // ── Sound / Pixel Clock Enables ─────────────────────────────────────────────
    input  logic        clk_sound,       // 4 MHz CE (1 pulse every 8 sys clocks)
    input  logic        clk_pix,         // pixel clock enable (~6.4 MHz, /5 of 32 MHz)
    input  logic        clk_pix2x,       // 2× pixel CE (tie to 1'b1 or pulse every 2-3 clocks)

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
    output logic [15:0] dbg_cpu_dout,       // read data FROM taito_b TO CPU (iEdb)

    // ── Bus bypass: C++ testbench drives CPU data/DTACK directly ───────────────
    input  logic        bypass_en,
    input  logic [15:0] bypass_data,
    input  logic        bypass_dtack_n,

    // ── Clock enables: driven from C++ testbench ───────────────────────────────
    input  logic        enPhi1,
    input  logic        enPhi2
);

// =============================================================================
// CPU bus wires (between fx68k and taito_b)
// =============================================================================
logic [23:1] cpu_addr;
logic [15:0] cpu_din;    // CPU write data → taito_b
logic [15:0] cpu_dout;   // taito_b read data → CPU
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic [2:0]  cpu_ipl_n;

// enPhi1/enPhi2 driven from C++ testbench (top-level inputs above)
// This is required because RTL-generated phi causes Verilator scheduling issues.

// =============================================================================
// fx68k — MC68000 CPU
// =============================================================================
// Interrupt acknowledge detection (VPAn for autovector)
// Rule: VPAn = IACK detection (~&{FC2,FC1,FC0,~ASn}), NEVER 1'b1
logic fx_FC0, fx_FC1, fx_FC2;
logic inta_n;
assign inta_n = ~&{fx_FC2, fx_FC1, fx_FC0, ~cpu_as_n};

logic cpu_halted_n_raw;
logic cpu_reset_n_out;

// =============================================================================
// Bus bypass: C++ testbench can drive iEdb and DTACKn directly for ROM reads.
// When bypass_en=1, CPU reads from bypass_data with bypass_dtack_n.
// When bypass_en=0, CPU reads from taito_b's cpu_dout/cpu_dtack_n.
// =============================================================================
logic [15:0] cpu_iEdb_mux;
logic        cpu_dtack_mux;
<<<<<<< HEAD

assign cpu_iEdb_mux  = bypass_en ? bypass_data    : cpu_dout;
assign cpu_dtack_mux = bypass_en ? bypass_dtack_n : cpu_dtack_n;
=======
logic        iack_cycle;

assign cpu_iEdb_mux  = bypass_en ? bypass_data    : cpu_dout;

// Suppress taito_b DTACK during IACK cycles.
// During interrupt acknowledge (FC=111, ASn=0), VPA handles the ack.
// If taito_b's open-bus DTACK fires on the high IACK address,
// the CPU would incorrectly treat it as a vectored interrupt.
assign iack_cycle    = fx_FC2 & fx_FC1 & fx_FC0 & ~cpu_as_n;
assign cpu_dtack_mux = bypass_en  ? bypass_dtack_n :
                       iack_cycle ? 1'b1           : cpu_dtack_n;
>>>>>>> sim-batch2

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
    .iEdb       (cpu_iEdb_mux), // read data: bypass or taito_b
    .oEdb       (cpu_din),      // write data from CPU → taito_b

    // Address bus
    .eab        (cpu_addr)
);

assign dbg_cpu_halted_n = cpu_halted_n_raw;

// =============================================================================
// taito_b — full system (TC0180VCU, TC0260DAR, TC0220IOC, TC0140SYT, Z80, YM2610)
// =============================================================================
// Z80 debug outputs (informational only, not connected to testbench ports)
logic [15:0] z80_addr_dbg;
logic  [7:0] z80_din_dbg, z80_dout_dbg;
logic        z80_rd_n_dbg, z80_wr_n_dbg, z80_mreq_n_dbg, z80_iorq_n_dbg;
logic        z80_int_n_dbg;
logic        z80_rom_cs0_n_dbg, z80_rom_cs1_n_dbg, z80_ram_cs_n_dbg;
logic        z80_rom_a14_dbg, z80_rom_a15_dbg, z80_opx_n_dbg, z80_reset_n_dbg;

/* verilator lint_off UNUSED */
wire _unused_z80 = &{
    z80_addr_dbg, z80_din_dbg, z80_dout_dbg,
    z80_rd_n_dbg, z80_wr_n_dbg, z80_mreq_n_dbg, z80_iorq_n_dbg, z80_int_n_dbg,
    z80_rom_cs0_n_dbg, z80_rom_cs1_n_dbg, z80_ram_cs_n_dbg,
    z80_rom_a14_dbg, z80_rom_a15_dbg, z80_opx_n_dbg, z80_reset_n_dbg,
    cpu_reset_n_out
};
/* verilator lint_on UNUSED */

taito_b u_taito_b (
    .clk_sys            (clk_sys),
    .clk_pix            (clk_pix),
    .clk_pix2x          (clk_pix2x),
    .reset_n            (reset_n),
    .clk_sound          (clk_sound),

    // CPU bus
    .cpu_addr           (cpu_addr),
    .cpu_din            (cpu_din),      // CPU write data → taito_b
    .cpu_dout           (cpu_dout),     // taito_b read data → CPU
    .cpu_lds_n          (cpu_lds_n),
    .cpu_uds_n          (cpu_uds_n),
    .cpu_rw             (cpu_rw),
    .cpu_as_n           (cpu_as_n),
    .cpu_dtack_n        (cpu_dtack_n),
    .cpu_ipl_n          (cpu_ipl_n),
<<<<<<< HEAD
=======
    .iack_cycle         (iack_cycle),
>>>>>>> sim-batch2

    // Z80 debug outputs (internal to taito_b — exposed for probing only)
    .z80_addr           (z80_addr_dbg),
    .z80_din            (z80_din_dbg),
    .z80_dout           (z80_dout_dbg),
    .z80_rd_n           (z80_rd_n_dbg),
    .z80_wr_n           (z80_wr_n_dbg),
    .z80_mreq_n         (z80_mreq_n_dbg),
    .z80_iorq_n         (z80_iorq_n_dbg),
    .z80_int_n          (z80_int_n_dbg),
    .z80_rom_cs0_n      (z80_rom_cs0_n_dbg),
    .z80_rom_cs1_n      (z80_rom_cs1_n_dbg),
    .z80_ram_cs_n       (z80_ram_cs_n_dbg),
    .z80_rom_a14        (z80_rom_a14_dbg),
    .z80_rom_a15        (z80_rom_a15_dbg),
    .z80_opx_n          (z80_opx_n_dbg),
    .z80_reset_n        (z80_reset_n_dbg),

    // Program ROM SDRAM
    .prog_rom_addr      (prog_rom_addr),
    .prog_rom_data      (prog_rom_data),
    .prog_rom_req       (prog_rom_req),
    .prog_rom_ack       (prog_rom_ack),

    // GFX ROM SDRAM
    .gfx_rom_addr       (gfx_rom_addr),
    .gfx_rom_data       (gfx_rom_data),
    .gfx_rom_req        (gfx_rom_req),
    .gfx_rom_ack        (gfx_rom_ack),

    // ADPCM SDRAM
    .sdr_addr           (sdr_addr),
    .sdr_data           (sdr_data),
    .sdr_req            (sdr_req),
    .sdr_ack            (sdr_ack),

    // Z80 ROM SDRAM
    .z80_rom_addr       (z80_rom_addr),
    .z80_rom_data       (z80_rom_data),
    .z80_rom_req        (z80_rom_req),
    .z80_rom_ack        (z80_rom_ack),

    // Video timing inputs
    .hblank_n_in        (hblank_n_in),
    .vblank_n_in        (vblank_n_in),
    .hpos               (hpos),
    .vpos               (vpos),
    .hsync_n_in         (hsync_n_in),
    .vsync_n_in         (vsync_n_in),

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
assign dbg_cpu_dout    = cpu_dout;   // read data path (taito_b → CPU)
// dbg_cpu_halted_n is wired directly from u_cpu above

endmodule
