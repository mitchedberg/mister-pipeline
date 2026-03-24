// =============================================================================
// tb_top.sv — Simulation top-level for ESD 16-bit Arcade
//
// Combines esd_arcade + fx68k CPU so the Verilator testbench executes the
// real Multi Champ (or Head Panic) program ROM.
//
// Clock enables:
//   enPhi1/enPhi2 are top-level inputs driven from C++ BEFORE eval().
//   This is required by COMMUNITY_PATTERNS.md Section 1.1 and failure_catalog
//   entry "CPU double bus faults after 6 reads" — RTL-generated phi causes
//   delta-cycle scheduling races (Verilator artifact).
//
// All SDRAM channels and video timing are passed through as top-level ports
// so the C++ testbench can drive / capture them directly.
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        clk_pix,
    input  logic        reset_n,

    // ── fx68k Clock Enables (driven from C++ testbench, NOT from RTL) ──────────
    input  logic        enPhi1,   // CPU phi1 enable — set BEFORE posedge eval
    input  logic        enPhi2,   // CPU phi2 enable — set BEFORE posedge eval

    // ── Program ROM SDRAM ────────────────────────────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── Sprite ROM SDRAM ─────────────────────────────────────────────────────────
    output logic [26:0] spr_rom_addr,
    input  logic [15:0] spr_rom_data,
    output logic        spr_rom_req,
    input  logic        spr_rom_ack,

    // ── BG Tile ROM SDRAM ────────────────────────────────────────────────────────
    output logic [26:0] bg_rom_addr,
    input  logic [15:0] bg_rom_data,
    output logic        bg_rom_req,
    input  logic        bg_rom_ack,

    // ── Player Inputs (active low) ───────────────────────────────────────────────
    input  logic  [9:0] joystick_0,
    input  logic  [9:0] joystick_1,
    input  logic [15:0] dip_sw,

    // ── Video Outputs ────────────────────────────────────────────────────────────
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Audio Outputs ────────────────────────────────────────────────────────────
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    // ── Debug: CPU bus (for testbench diagnostics only) ──────────────────────────
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_dout,   // read data from esd_arcade to CPU
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n  // oHALTEDn from fx68k (low = CPU halted)
);

// =============================================================================
// CPU bus wires
// =============================================================================

logic [23:1] cpu_addr;
logic [15:0] cpu_din;    // CPU write data (oEdb from fx68k)
logic [15:0] cpu_dout;   // esd_arcade read data → CPU (iEdb)
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic  [2:0] cpu_ipl_n;
logic  [2:0] cpu_fc;

// =============================================================================
// IACK detection (COMMUNITY_PATTERNS.md Section 1.2)
// VPAn = asserted (low) when FC=111 and ASn=0 (interrupt acknowledge cycle)
// =============================================================================

logic inta_n;
assign inta_n = ~&{cpu_fc[2], cpu_fc[1], cpu_fc[0], ~cpu_as_n};

// =============================================================================
// fx68k — MC68000 CPU (direct instantiation per COMMUNITY_PATTERNS.md 1.8)
// enPhi1/enPhi2 are top-level inputs driven from C++ BEFORE eval().
// =============================================================================

logic cpu_halted_n_raw;

fx68k u_cpu (
    .clk        (clk_sys),
    .HALTn      (1'b1),
    .extReset   (~reset_n),   // active-HIGH reset to fx68k
    .pwrUp      (~reset_n),   // tie to extReset per community pattern
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
    .FC0        (cpu_fc[0]),
    .FC1        (cpu_fc[1]),
    .FC2        (cpu_fc[2]),

    // Bus arbitration
    .BGn        (),
    .oRESETn    (),
    .oHALTEDn   (cpu_halted_n_raw),

    // Bus inputs
    .DTACKn     (cpu_dtack_n),
    .VPAn       (inta_n),      // autovector on IACK — NEVER 1'b1
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),

    // Interrupts (active-low IPL)
    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),

    // Data buses
    .iEdb       (cpu_dout),  // read data: esd_arcade output to CPU
    .oEdb       (cpu_din),   // write data from CPU → esd_arcade

    // Address bus (word address)
    .eab        (cpu_addr)
);

assign dbg_cpu_halted_n = cpu_halted_n_raw;

// =============================================================================
// esd_arcade — full system integration
// =============================================================================

esd_arcade u_esd (
    .clk_sys         (clk_sys),
    .clk_pix         (clk_pix),
    .reset_n         (reset_n),

    // CPU bus
    .cpu_addr        (cpu_addr),
    .cpu_din         (cpu_din),
    .cpu_dout        (cpu_dout),
    .cpu_lds_n       (cpu_lds_n),
    .cpu_uds_n       (cpu_uds_n),
    .cpu_rw          (cpu_rw),
    .cpu_as_n        (cpu_as_n),
    .cpu_fc          (cpu_fc),
    .cpu_dtack_n     (cpu_dtack_n),
    .cpu_ipl_n       (cpu_ipl_n),

    // Program ROM
    .prog_rom_addr   (prog_rom_addr),
    .prog_rom_data   (prog_rom_data),
    .prog_rom_req    (prog_rom_req),
    .prog_rom_ack    (prog_rom_ack),

    // Sprite ROM
    .spr_rom_addr    (spr_rom_addr),
    .spr_rom_data    (spr_rom_data),
    .spr_rom_req     (spr_rom_req),
    .spr_rom_ack     (spr_rom_ack),

    // BG tile ROM
    .bg_rom_addr     (bg_rom_addr),
    .bg_rom_data     (bg_rom_data),
    .bg_rom_req      (bg_rom_req),
    .bg_rom_ack      (bg_rom_ack),

    // Video outputs
    .rgb_r           (rgb_r),
    .rgb_g           (rgb_g),
    .rgb_b           (rgb_b),
    .hsync_n         (hsync_n),
    .vsync_n         (vsync_n),
    .hblank          (hblank),
    .vblank          (vblank),

    // Audio
    .audio_l         (audio_l),
    .audio_r         (audio_r),

    // Player inputs
    .joystick_0      (joystick_0),
    .joystick_1      (joystick_1),
    .dip_sw          (dip_sw),

    // ROM download (unused in sim)
    .ioctl_download  (1'b0),
    .ioctl_addr      (27'h0),
    .ioctl_dout      (16'h0),
    .ioctl_wr        (1'b0),
    .ioctl_index     (8'h0),
    .ioctl_wait      ()
);

// =============================================================================
// Debug output passthrough
// =============================================================================

assign dbg_cpu_addr    = cpu_addr;
assign dbg_cpu_as_n    = cpu_as_n;
assign dbg_cpu_rw      = cpu_rw;
assign dbg_cpu_dout    = cpu_dout;
assign dbg_cpu_dtack_n = cpu_dtack_n;

endmodule
