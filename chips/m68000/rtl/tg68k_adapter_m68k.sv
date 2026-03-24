`default_nettype none
// =============================================================================
// tg68k_adapter_m68k.sv — TG68K MC68000 bus adapter (drop-in for fx68k_adapter)
// =============================================================================
//
// Wraps one TG68KdotC_Kernel instance configured as a plain MC68000 (CPU=2'b00)
// and presents the IDENTICAL bus interface as fx68k_adapter.sv so that emu.sv
// can swap one for the other with zero wiring changes.
//
// Why: fx68k uses ~5,100 ALMs per instance (two-phase internal microcode ROM).
//      TG68K in 68000 mode uses ~2,800 ALMs per instance.  With two CPUs the
//      swap saves ~4,600 ALMs total, resolving Quartus "Cannot convert all sets
//      of registers into RAM megafunctions" on Taito Z.
//
// Interface contract (matches fx68k_adapter exactly):
//   clk        — system clock (any frequency; cpu_ce divides it)
//   cpu_ce     — 1-cycle-wide enable, one pulse per 2 sys clocks = CPU clock
//   reset_n    — active-low async reset
//   cpu_addr   — word address A23:A1 (output)
//   cpu_din    — 16-bit read data from system bus (input)
//   cpu_dout   — 16-bit write data to system bus (output)
//   cpu_rw     — 1=read, 0=write (output)
//   cpu_uds_n  — upper data strobe active-low (output)
//   cpu_lds_n  — lower data strobe active-low (output)
//   cpu_as_n   — address strobe active-low (output)
//   cpu_dtack_n — data transfer ack active-low (input from system)
//   cpu_ipl_n  — interrupt priority level active-low [2:0] (input)
//   cpu_reset_n_out — CPU RESET instruction output (output)
//   cpu_halted_n — always 1'b1; TG68K does not expose a halted output (output)
//   cpu_inta_n   — active-low IACK: 0 when FC=111 and AS=0 (output)
//
// TG68K interface notes:
//   - No enPhi1/enPhi2 needed: TG68K uses a single clkena_in clock-enable.
//   - busstate[1:0]: 2'b01 = idle (no bus cycle); any other value = active.
//     AS_N is derived as: (busstate == 2'b01) — high when idle, low when active.
//   - DTACK is fed as clkena_in when TG68K is in an active bus state:
//       clkena_in = 1'b1   when busstate==01 (idle — always advance)
//       clkena_in = !cpu_dtack_n when in active state (wait for DTACK)
//     Additionally, clkena_in is gated by cpu_ce so the CPU only advances on
//     enabled clock edges.
//   - IPL_autovector tied to 1'b1: TG68K handles autovectored interrupts
//     internally when IPL_autovector is asserted.  This is equivalent to
//     fx68k's VPAn assertion during IACK cycles.
//   - FC[2:0] is available directly from TG68K; exposed via cpu_inta_n.
//   - TG68K does not output a "halted" signal; cpu_halted_n is hardwired to 1.
//
// DTACK + clkena_in handshake:
//   TG68K treats clkena_in as "the bus is ready and the CPU may advance one
//   state."  For a synchronous system:
//     - When idle (busstate=01): always pass clkena_in=1 (gated by cpu_ce).
//     - When active:             pass clkena_in = cpu_ce & !cpu_dtack_n.
//   This ensures the CPU waits until both the clock-enable fires AND the bus
//   has acknowledged the access.
//
// Reset:
//   TG68K nReset is active-low.  It is driven from the synchronised rst_n
//   (two-FF synchroniser, async assert, sync deassert) derived from reset_n.
//
// Reference:
//   TG68K source: chips/m68020/hdl/tg68k/TG68KdotC_Kernel_synth.v
//   fx68k adapter: chips/m68000/rtl/fx68k_adapter.sv
//   Taito F3 adapter: chips/m68020/rtl/tg68k_adapter.sv
//
// =============================================================================

module tg68k_adapter_m68k (
    // ── Clock / Reset ─────────────────────────────────────────────────────────
    input  logic        clk,        // system clock
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
    output logic        cpu_reset_n_out,

    // ── CPU halted output ─────────────────────────────────────────────────────
    // TG68K does not expose a halted pin; hardwired to 1 (never halted).
    output logic        cpu_halted_n,

    // ── Interrupt acknowledge output ──────────────────────────────────────────
    // Active-low: 0 when CPU is executing an interrupt acknowledge cycle
    // (FC[2:0] = 111 and AS_N = 0).
    output logic        cpu_inta_n,

    // ── Function code output ──────────────────────────────────────────────────
    // FC[2:0] — useful for IACK detection in the system (taito_z cpua_fc port).
    // Not present on fx68k_adapter; additive extension.
    output logic [2:0]  cpu_fc
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

// =============================================================================
// TG68K output signals
// =============================================================================
logic [31:0] tg_addr;         // byte address (addr_out)
logic [15:0] tg_data_write;   // write data
logic        tg_nWr;          // 1=read, 0=write (nWr port, same polarity as rw)
logic        tg_uds_n;        // upper data strobe (active-low)
logic        tg_lds_n;        // lower data strobe (active-low)
logic [1:0]  tg_busstate;     // bus state: 00=fetch,10=rd,11=wr,01=idle
logic        tg_nResetOut;    // CPU RESET instruction output (active-low)
logic [2:0]  tg_fc;           // function codes FC[2:0]
logic        tg_clr_berr;     // bus error clear (unused)
logic        tg_skipFetch;    // skip fetch hint (unused)
logic        tg_longword;     // longword access indicator (unused)
logic [31:0] tg_regin_out;    // debug register output (unused)
logic [3:0]  tg_cacr_out;     // cache control (unused in 68000 mode)
logic [31:0] tg_vbr_out;      // VBR (unused in 68000 mode)

// =============================================================================
// AS_N derivation
// =============================================================================
// TG68K busstate == 2'b01 → idle (no bus cycle in progress).
// All other states (00=opcode fetch, 10=read, 11=write) → AS active (low).
logic tg_as_n;
assign tg_as_n = (tg_busstate == 2'b01);

// =============================================================================
// clkena_in: gate CPU advancement
// =============================================================================
// - When idle (busstate == 01): the CPU is free to advance; gate only by cpu_ce.
// - When active: the CPU must wait for DTACK; gate by cpu_ce AND !cpu_dtack_n.
logic tg_clkena;
assign tg_clkena = cpu_ce & ((tg_busstate == 2'b01) ? 1'b1 : !cpu_dtack_n);

// =============================================================================
// TG68KdotC_Kernel instantiation — MC68000 mode (CPU = 2'b00)
// =============================================================================
//
// Port mapping vs TG68K port list:
//   clk            → clk
//   nReset         → rst_n           (sync'd active-low reset)
//   clkena_in      → tg_clkena       (DTACK-gated clock enable)
//   data_in        → cpu_din         (16-bit read data from system bus)
//   IPL            → cpu_ipl_n       (active-low IPL; TG68K IPL input is active-low)
//   IPL_autovector → 1'b1            (enable autovectored interrupts during IACK)
//   berr           → 1'b0            (no bus error injection)
//   CPU            → 2'b00           (MC68000 mode)
//   addr_out       → tg_addr         (32-bit byte address; upper 8 bits unused)
//   data_write     → tg_data_write   (16-bit write data)
//   nWr            → tg_nWr          (1=read, 0=write)
//   nUDS           → tg_uds_n        (upper data strobe active-low)
//   nLDS           → tg_lds_n        (lower data strobe active-low)
//   busstate       → tg_busstate     (bus state; used for AS_N derivation)
//   longword       → tg_longword     (unused)
//   nResetOut      → tg_nResetOut    (CPU RESET instruction output)
//   FC             → tg_fc           (function codes for IACK detection)
//   clr_berr       → tg_clr_berr    (ignored)
//   skipFetch      → tg_skipFetch   (ignored)
//   regin_out      → tg_regin_out   (unused)
//   CACR_out       → tg_cacr_out    (unused in 68000 mode)
//   VBR_out        → tg_vbr_out     (unused in 68000 mode)
//
TG68KdotC_Kernel u_tg68k (
    .clk           (clk),
    .nReset        (rst_n),
    .clkena_in     (tg_clkena),
    .data_in       (cpu_din),
    .IPL           (cpu_ipl_n),
    .IPL_autovector(1'b1),          // autovector on IACK (equiv. to VPAn assertion)
    .berr          (1'b0),
    .CPU           (2'b00),         // MC68000 mode
    .addr_out      (tg_addr),
    .data_write    (tg_data_write),
    .nWr           (tg_nWr),
    .nUDS          (tg_uds_n),
    .nLDS          (tg_lds_n),
    .busstate      (tg_busstate),
    .longword      (tg_longword),
    .nResetOut     (tg_nResetOut),
    .FC            (tg_fc),
    .clr_berr      (tg_clr_berr),
    .skipFetch     (tg_skipFetch),
    .regin_out     (tg_regin_out),
    .CACR_out      (tg_cacr_out),
    .VBR_out       (tg_vbr_out)
);

// =============================================================================
// Connect TG68K outputs to taito_z bus interface
// =============================================================================

// Word address A23:A1 — tg_addr is a byte address; extract [23:1]
assign cpu_addr      = tg_addr[23:1];

assign cpu_dout      = tg_data_write;
assign cpu_rw        = tg_nWr;       // TG68K nWr: 1=read, 0=write — same convention
assign cpu_uds_n     = tg_uds_n;
assign cpu_lds_n     = tg_lds_n;
assign cpu_as_n      = tg_as_n;

// CPU RESET instruction output
assign cpu_reset_n_out = tg_nResetOut;

// TG68K does not expose a halted output — tie to 1 (not halted)
assign cpu_halted_n  = 1'b1;

// =============================================================================
// Interrupt acknowledge detection
// =============================================================================
// IACK when FC[2:0] = 3'b111 AND AS_N is low (same logic as fx68k_adapter).
logic inta_n;
assign inta_n     = ~&{tg_fc[2], tg_fc[1], tg_fc[0], ~tg_as_n};
assign cpu_inta_n = inta_n;

// Expose FC[2:0] for system-level IACK detection (taito_z cpua_fc / cpub_fc).
assign cpu_fc     = tg_fc;

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{tg_longword, tg_clr_berr, tg_skipFetch,
                   tg_regin_out, tg_cacr_out, tg_vbr_out,
                   tg_addr[31:24]};
/* verilator lint_on UNUSED */

endmodule
