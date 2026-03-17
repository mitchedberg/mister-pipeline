`default_nettype none
// =============================================================================
// fx68k_adapter.sv — fx68k MC68000 bus adapter for Taito Z
// =============================================================================
//
// Wraps one fx68k instance and presents the bus interface that taito_z.sv
// expects for its cpua_* / cpub_* ports.
//
// fx68k uses a two-phase clock-enable scheme (enPhi1 / enPhi2) to implement
// the 68000's internal 4-state bus cycle (S0–S7) while running on a single
// synchronous clock edge.  For a 32 MHz system clock with 16 MHz CPU:
//
//   enPhi1 pulses on odd  clock cycles (1, 3, 5, …)
//   enPhi2 pulses on even clock cycles (2, 4, 6, …)
//
// The caller (emu.sv) supplies cpu_ce as a 1-cycle-wide enable that fires
// every 2 system clocks.  The adapter derives enPhi1 / enPhi2 internally
// by alternating on each cpu_ce assertion.
//
// Reset semantics:
//   extReset — held high while system reset is active.  fx68k samples this
//              synchronously; it must remain asserted for at least 4 clock
//              enables (2 full CPU cycles) after deassertion of the power-on
//              condition.
//   pwrUp    — asserted simultaneously with extReset on cold-start to
//              initialise all registers (including PC) to zero.  Tie to
//              extReset here; a separate power-up pin is not exposed.
//
// 6800-peripheral signals (E, VMAn):
//   Not required by Taito Z.  E output is left open and VPAn is tied high
//   (no 6800-compatible peripherals on the bus).
//
// Bus arbitration (BR/BG/BGACK):
//   Taito Z does not implement DMA bus arbitration.
//   BRn = 1'b1, BGACKn = 1'b1 (no request, no grant accepted).
//
// Bus error:
//   BERRn = 1'b1 (no bus error injection).
//
// fx68k HDL source: chips/m68000/hdl/fx68k/fx68k.sv
// Reference: https://github.com/ijor/fx68k
//
// Port interface of fx68k (top-level module):
//   input  clk, HALTn, extReset, pwrUp, enPhi1, enPhi2
//   output eRWn, ASn, LDSn, UDSn, E, VMAn
//   output FC0, FC1, FC2, BGn, oRESETn, oHALTEDn
//   input  DTACKn, VPAn, BERRn, BRn, BGACKn
//   input  IPL0n, IPL1n, IPL2n
//   input  [15:0] iEdb       — read data
//   output [15:0] oEdb       — write data
//   output [23:1] eab        — word address (A23:A1)
//
// =============================================================================

module fx68k_adapter (
    // ── Clock / Reset ─────────────────────────────────────────────────────────
    input  logic        clk,        // system clock (32 MHz for Taito Z)
    input  logic        cpu_ce,     // clock enable — 1 pulse per 2 sys clocks = 16 MHz
    input  logic        reset_n,    // active-low system reset

    // ── Taito Z CPU bus interface ─────────────────────────────────────────────
    // Port naming matches taito_z.sv cpua_* / cpub_* convention exactly.
    output logic [23:1] cpu_addr,   // word address A23:A1
    input  logic [15:0] cpu_din,    // read data (from taito_z to CPU)
    output logic [15:0] cpu_dout,   // write data (from CPU to taito_z)
    output logic        cpu_rw,     // 1=read, 0=write
    output logic        cpu_uds_n,  // upper data strobe (active-low)
    output logic        cpu_lds_n,  // lower data strobe (active-low)
    output logic        cpu_as_n,   // address strobe (active-low)
    input  logic        cpu_dtack_n,// data transfer ack (active-low, from taito_z)
    input  logic [2:0]  cpu_ipl_n,  // interrupt priority level (active-low)
                                    // cpu_ipl_n[2:0] = {IPL2n, IPL1n, IPL0n}

    // ── CPU reset output ─────────────────────────────────────────────────────
    // oRESETn from fx68k — can drive other CPU's reset_n input (CPU A drives CPU B
    // reset via a register in taito_z; this output is available but optional).
    output logic        cpu_reset_n_out
);

// =============================================================================
// Reset synchronizer (async assert, synchronous deassert — mandatory pattern)
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) rst_pipe <= 2'b00;
    else          rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// extReset and pwrUp for fx68k: active-high.
// Hold extReset asserted while rst_n is deasserted (active-low).
// pwrUp is tied to extReset — asserted during every reset, not just cold-start.
// Taito Z has no separate cold-start condition; tying them together is safe
// because the register file initialises to 0 on every reset, which matches
// the hardware power-on state.
logic fx_reset;
logic fx_pwrup;
assign fx_reset = !rst_n;   // 1 while system is in reset
assign fx_pwrup = !rst_n;   // 1 during reset = re-initialise registers

// =============================================================================
// Two-phase clock enable generation
// =============================================================================
// fx68k models the 68000's internal clock phases:
//   enPhi1 corresponds to the rising edge of CLK in standard 68000 timing.
//   enPhi2 corresponds to the falling edge (second half-cycle).
//
// The adapter generates enPhi1 and enPhi2 from a single cpu_ce enable:
//   - On every cpu_ce pulse, toggle a phase flip-flop.
//   - enPhi1 fires on even cpu_ce pulses (phi_toggle == 0 before toggle)
//   - enPhi2 fires on odd  cpu_ce pulses (phi_toggle == 1 before toggle)
//
// Note: fx68k documentation (fx68k.txt) states that enPhi1 and enPhi2 must
// alternate every cycle; the first enable after reset must be enPhi1.
// phi_toggle initialises to 0 so the first cpu_ce pulse gives enPhi1=1,
// enPhi2=0, which satisfies this requirement.
logic phi_toggle;
always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) phi_toggle <= 1'b0;
    else if (cpu_ce) phi_toggle <= ~phi_toggle;
end

logic enPhi1, enPhi2;
assign enPhi1 = cpu_ce &  ~phi_toggle;   // even cpu_ce pulses
assign enPhi2 = cpu_ce &   phi_toggle;   // odd  cpu_ce pulses

// =============================================================================
// fx68k instantiation
// =============================================================================

// Outputs from fx68k (raw)
logic        fx_eRWn;     // 1=read, 0=write
logic        fx_ASn;      // address strobe (active-low)
logic        fx_LDSn;     // lower data strobe (active-low)
logic        fx_UDSn;     // upper data strobe (active-low)
logic        fx_E;        // 6800 E clock (not used)
logic        fx_VMAn;     // valid memory address (not used)
logic        fx_FC0, fx_FC1, fx_FC2;  // function codes (not used at integration level)
logic        fx_BGn;      // bus grant (not used — no DMA)
logic        fx_oRESETn;  // CPU reset instruction output
logic        fx_oHALTEDn; // CPU halted output (not used)
logic [15:0] fx_oEdb;     // write data bus
logic [23:1] fx_eab;      // word address

fx68k u_fx68k (
    .clk        (clk),
    .HALTn      (1'b1),         // no single-step; force high
    .extReset   (fx_reset),     // active-high sync reset
    .pwrUp      (fx_pwrup),     // active-high power-up (tied to reset)
    .enPhi1     (enPhi1),
    .enPhi2     (enPhi2),

    // Bus outputs
    .eRWn       (fx_eRWn),
    .ASn        (fx_ASn),
    .LDSn       (fx_LDSn),
    .UDSn       (fx_UDSn),
    .E          (fx_E),
    .VMAn       (fx_VMAn),

    // Function codes (not used at integration level)
    .FC0        (fx_FC0),
    .FC1        (fx_FC1),
    .FC2        (fx_FC2),

    // Bus arbitration outputs
    .BGn        (fx_BGn),

    // Reset / halt outputs
    .oRESETn    (fx_oRESETn),
    .oHALTEDn   (fx_oHALTEDn),

    // Bus inputs
    .DTACKn     (cpu_dtack_n),  // from taito_z decode logic
    .VPAn       (1'b1),         // no 6800-compatible peripherals
    .BERRn      (1'b1),         // no bus error injection
    .BRn        (1'b1),         // no external DMA requests
    .BGACKn     (1'b1),         // no bus grant acknowledge

    // Interrupt inputs (active-low; cpu_ipl_n[2]=IPL2n, [1]=IPL1n, [0]=IPL0n)
    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),

    // Data buses
    .iEdb       (cpu_din),      // read data from system bus
    .oEdb       (fx_oEdb),      // write data to system bus

    // Address bus (word-granular A23:A1)
    .eab        (fx_eab)
);

// =============================================================================
// Connect fx68k outputs to taito_z bus interface
// =============================================================================

assign cpu_addr      = fx_eab;
assign cpu_dout      = fx_oEdb;
assign cpu_rw        = fx_eRWn;   // fx68k: 1=read, 0=write — matches taito_z convention
assign cpu_uds_n     = fx_UDSn;
assign cpu_lds_n     = fx_LDSn;
assign cpu_as_n      = fx_ASn;
assign cpu_reset_n_out = fx_oRESETn;

// =============================================================================
// Unused signal suppression (prevent lint warnings)
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{fx_E, fx_VMAn, fx_FC0, fx_FC1, fx_FC2, fx_BGn, fx_oHALTEDn};
/* verilator lint_on UNUSED */

endmodule
