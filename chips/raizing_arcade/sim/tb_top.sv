// =============================================================================
// tb_top.sv — Simulation top-level for Raizing Arcade (Battle Garegga)
//
// Wraps raizing_arcade.sv for Verilator simulation.
//
// The raizing_arcade module is currently a SCAFFOLD (all outputs tied to
// safe defaults, no CPU or memory system implemented). This harness verifies:
//   - RTL compiles cleanly under Verilator
//   - Module hierarchy is correct
//   - SDRAM inout is handled via Verilator split (output sdram_din)
//
// Architecture note:
//   raizing_arcade.sv uses the full MiSTer SDRAM bus (inout sdram_dq) and
//   ioctl ROM loading — NOT the toggle-handshake channels used by toaplan_v2.
//   When the scaffold is replaced with real logic, this tb_top must be
//   updated to drive sdram_dq correctly.
//
// Inout workaround: the C++ driver provides sdram_dq_in and reads sdram_dq_out.
// In the scaffold, sdram_dq output is 0 (cs_n=1, module not driving bus).
//
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module tb_top (
    // ── Clocks / Reset ──────────────────────────────────────────────────────
    input  logic        clk,
    input  logic        rst_n,

    // ── Video outputs (pass-through from raizing_arcade) ─────────────────────
    output logic [7:0]  rgb_r,
    output logic [7:0]  rgb_g,
    output logic [7:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,
    output logic        ce_pixel,

    // ── Audio outputs ────────────────────────────────────────────────────────
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    // ── Cabinet I/O inputs ────────────────────────────────────────────────────
    input  logic [9:0]  joystick_0,
    input  logic [9:0]  joystick_1,
    input  logic [7:0]  dipsw_a,
    input  logic [7:0]  dipsw_b,

    // ── ROM loading (ioctl, for ROM preload into SDRAM) ──────────────────────
    input  logic        ioctl_wr,
    input  logic [24:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    input  logic [7:0]  ioctl_index,
    output logic        ioctl_wait,

    // ── SDRAM bus (split inout for Verilator) ──────────────────────────────
    output logic [12:0] sdram_a,
    output logic [1:0]  sdram_ba,
    input  logic [15:0] sdram_dq_in,    // data from SDRAM model to core
    output logic [15:0] sdram_dq_out,   // data from core to SDRAM model
    output logic        sdram_dq_oe,    // output enable (1 = core driving bus)
    output logic        sdram_cas_n,
    output logic        sdram_ras_n,
    output logic        sdram_we_n,
    output logic        sdram_cs_n,
    output logic [1:0]  sdram_dqm,
    output logic        sdram_cke
);

// =============================================================================
// SDRAM inout split
// The raizing_arcade module has an inout sdram_dq[15:0].
// In Verilator sim, we split it: core drives sdram_dq_out when sdram_cs_n=0.
// Since the scaffold never asserts cs_n (it's tied high), the bus stays idle.
// =============================================================================
logic [15:0] sdram_dq_wire;

// Scaffold: cs_n=1, so the core is never driving. sdram_dq_wire = sdram_dq_in.
// When real logic is added: sdram_dq_wire = sdram_we_n ? sdram_dq_in : sdram_dq_out_core
assign sdram_dq_wire = sdram_dq_in;  // always read from SDRAM model in sim

// sdram_dq_oe: true when core is writing to SDRAM
assign sdram_dq_oe = ~sdram_we_n & ~sdram_cs_n;

// The SDRAM data we drive out comes from the core's write data.
// The scaffold has no write path (cs_n=1 always), so this is always 0.
assign sdram_dq_out = 16'h0000;

// =============================================================================
// Instantiate raizing_arcade (scaffold)
// =============================================================================
raizing_arcade u_raizing (
    .clk         (clk),
    .rst_n       (rst_n),

    // ROM loading
    .ioctl_wr    (ioctl_wr),
    .ioctl_addr  (ioctl_addr),
    .ioctl_dout  (ioctl_dout),
    .ioctl_index (ioctl_index),
    .ioctl_wait  (ioctl_wait),

    // Video
    .red         (rgb_r),
    .green       (rgb_g),
    .blue        (rgb_b),
    .hsync_n     (hsync_n),
    .vsync_n     (vsync_n),
    .hblank      (hblank),
    .vblank      (vblank),
    .ce_pixel    (ce_pixel),

    // Audio
    .audio_l     (audio_l),
    .audio_r     (audio_r),

    // I/O
    .joystick_0  (joystick_0),
    .joystick_1  (joystick_1),
    .dipsw_a     (dipsw_a),
    .dipsw_b     (dipsw_b),

    // SDRAM (inout handled via wire)
    .sdram_a     (sdram_a),
    .sdram_ba    (sdram_ba),
    .sdram_dq    (sdram_dq_wire),
    .sdram_cas_n (sdram_cas_n),
    .sdram_ras_n (sdram_ras_n),
    .sdram_we_n  (sdram_we_n),
    .sdram_cs_n  (sdram_cs_n),
    .sdram_dqm   (sdram_dqm),
    .sdram_cke   (sdram_cke)
);

endmodule
