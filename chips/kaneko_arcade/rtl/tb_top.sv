// =============================================================================
// tb_top.sv — Simulation top-level for Kaneko16 Arcade (Berlin Wall)
//
// Combines kaneko_arcade + fx68k so the Verilator testbench gets a real
// MC68000 CPU executing the Berlin Wall program ROM.
//
// Clock: 32 MHz system clock (CPU at 16 MHz via enPhi1/enPhi2 from C++).
// Pixel clock: driven from C++ as clk_pix (1-cycle pulse, /5 of sys = ~6.4 MHz).
// Sound clock enable: driven from C++ as clk_sound_cen (~1 MHz, /32 of sys).
//
// Key differences from nmk_arcade tb_top:
//   - kaneko_arcade generates its own video timing (NO hblank_n_in / vblank_n_in
//     / hpos / vpos / hsync_n_in / vsync_n_in inputs)
//   - cpu_dout = INPUT to kaneko_arcade (data FROM CPU, write path) = fx68k.oEdb
//   - cpu_din  = OUTPUT from kaneko_arcade (data TO CPU, read path) → fx68k.iEdb
//   - GFX ROM: 32-bit wide interface (gfx_rom_addr[21:0], gfx_rom_data[31:0])
//   - prog_rom_addr is [19:1] (1MB program ROM space)
//   - Audio outputs are unsigned [15:0] (not signed)
//   - clk_sound_cen top-level input (no sound CE in tb_top itself)
//
// All SDRAM channels, video outputs, I/O, and audio are passed through as
// top-level ports so the C++ testbench can drive / capture them directly.
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────────
    input  logic        clk_sys,
    input  logic        clk_pix,         // pixel clock enable (~6.4 MHz, /5 of sys)
    input  logic        reset_n,

    // ── Program ROM SDRAM ────────────────────────────────────────────────────────
    // 1MB program ROM; addr is [19:1] word address (byte_addr >> 1)
    output logic [19:1] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM SDRAM (32-bit wide) ──────────────────────────────────────────────
    // Sprites + BG tiles. C++ testbench assembles 32-bit result from two SDRAM reads.
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

    // ── Sound clock enable (from C++, ~1 MHz) ────────────────────────────────────
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

    // ── Debug: CPU bus (for testbench diagnostics only) ──────────────────────────
    output logic [23:1] dbg_cpu_addr,
    output logic        dbg_cpu_as_n,
    output logic        dbg_cpu_rw,
    output logic [15:0] dbg_cpu_din,       // data FROM CPU (write data)
    output logic        dbg_cpu_dtack_n,
    output logic        dbg_cpu_halted_n,  // oHALTEDn from fx68k (low = CPU halted)
    output logic [15:0] dbg_cpu_dout,      // read data FROM kaneko_arcade TO CPU
    output logic [2:0]  dbg_cpu_ipl_n,     // interrupt priority level (for debug)
    output logic        dbg_iack,          // 1 during IACK cycle (FC=111, ASn=0)

    // ── Bus bypass: C++ testbench drives CPU data/DTACK directly ───────────────
    input  logic        bypass_en,
    input  logic [15:0] bypass_data,
    input  logic        bypass_dtack_n,

    // ── Clock enables: driven from C++ testbench ───────────────────────────────
    input  logic        enPhi1,
    input  logic        enPhi2
);

// =============================================================================
// CPU bus wires (between fx68k and kaneko_arcade)
// =============================================================================
logic [23:1] cpu_addr;
logic [15:0] cpu_write_data;  // data FROM cpu (fx68k.oEdb) → kaneko_arcade.cpu_dout
logic [15:0] cpu_read_data;   // data TO cpu from kaneko_arcade.cpu_din
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
logic fx_FC0, fx_FC1, fx_FC2;
logic inta_n;
assign inta_n = ~&{fx_FC2, fx_FC1, fx_FC0, ~cpu_as_n};

logic cpu_halted_n_raw;
logic cpu_reset_n_out;

// =============================================================================
// Bus bypass: C++ testbench can drive iEdb and DTACKn directly for ROM reads.
// When bypass_en=1, CPU reads from bypass_data with bypass_dtack_n.
// When bypass_en=0, CPU reads from kaneko_arcade's cpu_din/cpu_dtack_n.
// =============================================================================
logic [15:0] cpu_iEdb_mux;
logic        cpu_dtack_mux;
logic        iack_cycle;

assign cpu_iEdb_mux  = bypass_en ? bypass_data    : cpu_read_data;

// Suppress kaneko_arcade DTACK during IACK cycles.
// During interrupt acknowledge (FC=111, ASn=0), VPA handles the ack.
// If kaneko_arcade's open-bus DTACK fires on the high IACK address,
// the CPU would incorrectly treat it as a vectored interrupt.
assign iack_cycle    = fx_FC2 & fx_FC1 & fx_FC0 & ~cpu_as_n;
assign cpu_dtack_mux = bypass_en    ? bypass_dtack_n :
                       iack_cycle   ? 1'b1           : cpu_dtack_n;

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
    .iEdb       (cpu_iEdb_mux),    // read data: bypass or kaneko_arcade.cpu_din
    .oEdb       (cpu_write_data),  // write data from CPU → kaneko_arcade.cpu_dout

    // Address bus
    .eab        (cpu_addr)
);

assign dbg_cpu_halted_n = cpu_halted_n_raw;

// =============================================================================
// kaneko_arcade — full system (Kaneko16 GPU, work RAM, Z80, OKI, I/O)
// =============================================================================
kaneko_arcade u_kaneko (
    .clk_sys            (clk_sys),
    .clk_pix            (clk_pix),
    .reset_n            (reset_n),

    // CPU bus — note REVERSED naming vs NMK:
    //   cpu_dout = INPUT (FROM cpu)  = fx68k.oEdb
    //   cpu_din  = OUTPUT (TO cpu)   → fx68k.iEdb (via bypass mux)
    .cpu_addr           (cpu_addr),
    .cpu_dout           (cpu_write_data),
    .cpu_din            (cpu_read_data),
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

    // GFX ROM (32-bit)
    .gfx_rom_addr       (gfx_rom_addr),
    .gfx_rom_data       (gfx_rom_data),
    .gfx_rom_req        (gfx_rom_req),
    .gfx_rom_ack        (gfx_rom_ack),

    // ADPCM ROM
    .adpcm_rom_addr     (adpcm_rom_addr),
    .adpcm_rom_req      (adpcm_rom_req),
    .adpcm_rom_data     (adpcm_rom_data),
    .adpcm_rom_ack      (adpcm_rom_ack),

    // Sound clock enable
    .clk_sound_cen      (clk_sound_cen),

    // Z80 ROM
    .z80_rom_addr       (z80_rom_addr),
    .z80_rom_req        (z80_rom_req),
    .z80_rom_data       (z80_rom_data),
    .z80_rom_ack        (z80_rom_ack),

    // Player inputs
    .joystick_p1        (joystick_p1),
    .joystick_p2        (joystick_p2),
    .coin               (coin),
    .service            (service),
    .dipsw1             (dipsw1),
    .dipsw2             (dipsw2),

    // Video outputs (kaneko_arcade generates its own timing — no inputs needed)
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
assign dbg_cpu_din     = cpu_write_data;  // data FROM CPU (write path)
assign dbg_cpu_dtack_n = cpu_dtack_n;
assign dbg_cpu_dout    = cpu_read_data;   // read data path (kaneko_arcade → CPU)
assign dbg_cpu_ipl_n = cpu_ipl_n;
assign dbg_iack = iack_cycle;
// dbg_cpu_halted_n is wired directly from u_cpu above

endmodule
