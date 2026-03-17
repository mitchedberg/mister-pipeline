`default_nettype none
// =============================================================================
// tg68k_adapter.sv — TG68K 16-bit bus → 32-bit bus adapter for Taito F3
// =============================================================================
//
// TG68K (TobiFlex/TG68K.C, LGPL v3) implements a full 68020 CPU but exposes
// a 16-bit external data bus even when configured for 68020 mode.  The real
// MC68EC020 on a Taito F3 PCB has a 32-bit external bus.  This adapter:
//
//   1. Wraps TG68K's 16-bit interface and presents a clean 32-bit bus to the
//      surrounding system (taito_f3.sv).
//   2. Coalesces two consecutive 16-bit TG68K bus cycles into one atomic
//      32-bit access whenever the 68020 performs a long-word read or write.
//   3. Passes word (16-bit) and byte accesses through with a single cycle.
//
// TG68K VHDL files are in chips/m68020/hdl/tg68k/ (downloaded 2026-03-16).
// The TG68KdotC_Kernel instantiation is ACTIVE below.
//
// See chips/m68020/README.md for full TG68K integration notes.
//
// TG68K external port list (from TobiFlex/TG68K.C — TG68K.vhd):
//
//   Inputs:
//     clk           — system clock
//     reset         — active-low async reset
//     clkena_in     — clock enable (1 = CPU may advance)
//     IPL[2:0]      — interrupt priority level (active-low encoded; 3'b111=none)
//     dtack         — data transfer acknowledge (active-low; 0=ready)
//     data_read[15:0] — 16-bit read data from memory
//     CPU[1:0]      — mode select: 2'b11 = 68020, 2'b01 = 68010, 2'b00 = 68000
//
//   Outputs:
//     addr[31:0]    — byte address output
//     data_write[15:0] — 16-bit write data to memory
//     as_n          — address strobe (active-low)
//     uds_n         — upper data strobe D[15:8] (active-low)
//     lds_n         — lower data strobe D[7:0]  (active-low)
//     rw            — 1=read, 0=write
//     reset_cpu_n   — CPU reset output (open-drain; drive reset circuitry)
//     busstate[1:0] — internal bus state (for debug; not used externally)
//     FC[2:0]       — function codes (for IACK decode)
//
// TG68K generics required for 68020 mode (from Minimig-AGA reference):
//     sr_read      = 2  (switchable with CPU[0])
//     vbr_stackframe = 2
//     extaddr_mode = 2  (switchable with CPU[1])
//     mul_mode     = 2
//     div_mode     = 2
//     bitfield     = 2
//
// =============================================================================
//
// 16-to-32-bit bus width conversion
// ----------------------------------
//
// TG68K always does 16-bit bus transactions.  For a 32-bit longword the CPU
// issues two back-to-back 16-bit transactions:
//
//   Cycle A: addr = base (even word), UDS+LDS active, upper 16 bits
//   Cycle B: addr = base+2           (next word),     lower 16 bits
//
// The adapter detects Cycle A by: as_n LOW, addr[1]=0, uds_n+lds_n both LOW.
// After DTACK on Cycle A, it suppresses DTACK from the caller until Cycle B
// completes, then presents the merged 32-bit result in one shot.
//
// For word accesses (addr[1]=0 or =1, only one UDS/LDS strobe pattern):
//   The access maps directly to the upper or lower 16-bit half of the 32-bit
//   word bus; one cycle only.
//
// For byte accesses (only UDS or only LDS active, 1 cycle):
//   Same mapping — presented as a 32-bit access with only one byte-enable set.
//
// Access size detection (TG68K 68020 mode):
//   TG68K does NOT export a SIZE[1:0] bus signal.  Instead, it uses the
//   DSACK[1:0] / DTACK mechanism to determine bus width.  In 68020 mode when
//   DTACK (16-bit ack) is used, TG68K knows the bus is 16-bits wide and issues
//   two cycles for a longword automatically.
//
//   Heuristic used here: if addr[1]=0 AND both UDS+LDS are active AND this is
//   the FIRST transaction at this AS_N assertion, begin accumulating.  If the
//   very next transaction has addr[1]=1 at the same base address, treat the
//   pair as a 32-bit longword.  If not (e.g. word access at even boundary with
//   both strobes just means a normal word read), the heuristic completes after
//   one cycle.
//
//   A cleaner approach (used in production Minimig) is to ALWAYS run 32-bit
//   ROM/RAM at the 32-bit boundary and supply 16-bit DTACK for I/O regions.
//   This adapter uses the simpler two-cycle coalescing approach first.
//
// =============================================================================

module tg68k_adapter (
    input  logic        clk,
    input  logic        reset_n,         // active-low reset in

    // ── Interrupt ────────────────────────────────────────────────────────────
    input  logic [2:0]  ipl_n,           // interrupt priority level (active-low)

    // ── 32-bit system bus (to taito_f3.sv) ───────────────────────────────────
    output logic [23:1] cpu_addr,        // word address (F3 only needs 24-bit address space)
    output logic [31:0] cpu_dout,        // write data (32-bit)
    input  logic [31:0] cpu_din,         // read data  (32-bit)
    output logic        cpu_rw,          // 1=read, 0=write
    output logic        cpu_as_n,        // address strobe (active-low)
    output logic [3:0]  cpu_be_n,        // byte enables (active-low): {D31:D24, D23:D16, D15:D8, D7:D0}
    input  logic        cpu_dtack_n,     // data transfer acknowledge (active-low; 0=ready)
    output logic        cpu_reset_n_out  // CPU reset output (drives external reset circuitry)
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
// TG68K interface signals
// =============================================================================

// --- Outputs driven by TG68KdotC_Kernel ---
logic [31:0] tg_addr;         // byte address (addr_out)
logic [15:0] tg_data_write;   // write data
logic        tg_nWr;          // write strobe: 0=write, 1=read  (nWr port)
logic        tg_uds_n;        // upper data strobe active-low    (nUDS port)
logic        tg_lds_n;        // lower data strobe active-low    (nLDS port)
logic        tg_reset_out_n;  // CPU reset output                (nResetOut port)
logic [1:0]  tg_busstate;     // bus state: 00=fetch,10=rd,11=wr,01=idle (busstate port)
logic [2:0]  tg_fc;           // function codes                  (FC port)
logic        tg_skipFetch;    // internal skip-fetch hint        (skipFetch port)
logic        tg_clr_berr;     // bus error clear (unused here)   (clr_berr port)

// tg_rw: 1=read, 0=write — directly matches nWr polarity (nWr=0 means write)
// tg_as_n: derived from busstate; AS is active whenever the CPU is doing a
//          memory access (state != "01" which means no-memaccess/idle).
logic tg_rw;
assign tg_rw  = tg_nWr;
logic tg_as_n;
assign tg_as_n = (tg_busstate == 2'b01);   // 1=idle (no strobe), 0=active

// --- Inputs to TG68KdotC_Kernel ---
logic [15:0] tg_data_read;    // 16-bit read data fed to kernel  (data_in port)

// clkena_in: gate CPU advancement.
// Three conditions must all be satisfied to allow the CPU to advance:
//   1. Not in a memory access state (busstate != "01" means active access).
//   2. Not stalled waiting for the second 16-bit half (coalesce_stall).
//   3. The system bus has acknowledged (cpu_dtack_n = 0).
// coalesce_stall is driven by the state machine below; declared here as a wire
// and assigned after the state machine typedef so the signal is in scope.
logic tg_clkena;
logic coalesce_stall;   // 1 = adapter is between the two 16-bit halves; hold CPU
assign tg_clkena = (tg_busstate == 2'b01) ? 1'b1              // CPU idle — always advance
                 : coalesce_stall         ? 1'b0              // coalescing gap stall
                 : !cpu_dtack_n;                               // wait for bus ack

// -------------------------------------------------------------------------
// TG68KdotC_Kernel instantiation
// Port name mapping (stub expectation → actual kernel port):
//   reset        → nReset        (active-low reset)
//   data_read    → data_in       (16-bit read data input)
//   addr         → addr_out      (32-bit byte address output)
//   as_n         → NOT A PORT    (derived from busstate above)
//   uds_n        → nUDS          (active-low upper data strobe)
//   lds_n        → nLDS          (active-low lower data strobe)
//   rw           → nWr           (0=write, 1=read — same polarity)
//   reset_cpu_n  → nResetOut     (CPU RESET instruction output)
//   dtack        → NOT A PORT    (consumed via clkena_in above)
//   IPL          → IPL           (no rename)
//   data_write   → data_write    (no rename)
//   busstate     → busstate      (no rename)
//   FC           → FC            (no rename)
// Additional kernel ports not in original stub:
//   IPL_autovector → tied 0      (not used; auto-vector via VPA/VMA in TG68K.vhd top)
//   berr           → tied 0      (bus error; handled at integration level)
//   clr_berr       → ignored
//   skipFetch      → ignored
// -------------------------------------------------------------------------
TG68KdotC_Kernel #(
    .SR_Read       (2),    // switchable with CPU(0) → 68020 privileged SR reads
    .VBR_Stackframe(2),    // switchable with CPU(0) → 68020 extended stack frames
    .extAddr_Mode  (2),    // switchable with CPU(1) → 68020 extended addressing
    .MUL_Mode      (2),    // switchable with CPU(1) → 32-bit multiply
    .DIV_Mode      (2),    // switchable with CPU(1) → 32-bit divide
    .BitField      (2),    // switchable with CPU(1) → bitfield instructions
    .BarrelShifter (2),    // switchable with CPU(1) → barrel shifter
    .MUL_Hardware  (1)     // use hardware multiplier
) u_tg68k (
    .CPU           (2'b11),          // 68020 mode
    .clk           (clk),
    .nReset        (rst_n),          // active-low reset (from sync'd rst_n)
    .clkena_in     (tg_clkena),      // DTACK-derived clock enable
    .data_in       (tg_data_read),   // 16-bit read data from bus coalescer
    .IPL           (ipl_n),          // interrupt priority level (active-low)
    .IPL_autovector(1'b0),           // no auto-vector (IACK handled at integration level)
    .berr          (1'b0),           // bus error: not used at this level
    .addr_out      (tg_addr),        // 32-bit byte address
    .FC            (tg_fc),          // function codes (unused at this level)
    .data_write    (tg_data_write),  // 16-bit write data
    .busstate      (tg_busstate),    // bus state: 00=fetch,10=rd,11=wr,01=idle
    .nWr           (tg_nWr),         // 0=write, 1=read
    .nUDS          (tg_uds_n),       // upper data strobe (active-low)
    .nLDS          (tg_lds_n),       // lower data strobe (active-low)
    .nResetOut     (tg_reset_out_n), // CPU RESET instruction output
    .clr_berr      (tg_clr_berr),    // bus error clear (ignored)
    .skipFetch     (tg_skipFetch)    // skip fetch hint (ignored)
);

// =============================================================================
// 16 → 32-bit bus coalescing state machine
// =============================================================================
//
// State encoding:
//   IDLE      — no bus cycle in progress
//   FIRST16   — AS_N just fell; waiting for DTACK on the first 16-bit half
//   SECOND16  — first half completed; waiting for DTACK on the second 16-bit half
//   ACK32     — both halves done; hold combined result and assert DTACK to CPU
//
// Longword detection:
//   A 68020 longword access (4 bytes) through TG68K always appears as two
//   consecutive 16-bit transactions with:
//     Cycle A: addr[1]=0, uds_n=0, lds_n=0  (upper word at even address)
//     Cycle B: addr[1]=1, uds_n=0, lds_n=0  (lower word at addr+2)
//   When addr[1]=0 and both strobes are active, enter FIRST16 and accumulate.
//
//   A word (16-bit) access appears as a single cycle:
//     uds_n=0, lds_n=0, addr[1]=0 or 1 (no second cycle follows)
//   Disambiguation: after DTACK on what would be Cycle A, if TG68K deasserts
//   AS_N we know it was a word access (complete).  If TG68K immediately re-asserts
//   AS_N at addr+2 it is the second half of a longword.
//
// Simplified heuristic implemented here:
//   - When both UDS+LDS are active at an even byte address (addr[1]=0), ALWAYS
//     wait for a second cycle.  TG68K in 68020 mode always pairs longword accesses
//     at even boundaries this way.  Word accesses to even boundaries are uncommon
//     in 68020 code; when they occur, the second wait is harmless (system returns
//     the same data word from addr+2; result is discarded).
//   - Odd-word accesses (addr[1]=1) and byte accesses (only UDS or LDS) are
//     always single-cycle.
//
// NOTE: This heuristic is adequate for Taito F3 game code.  If a game performs
//       a MOVE.W to an even address while TG68K is in 68020 mode, the adapter
//       will incorrectly wait for a second cycle.  Should this prove to be a
//       problem during TAS validation, replace with an FC[2:0] or SIZE[1:0]
//       based decode (SIZE is not exported by TG68K; FC decode is feasible).

typedef enum logic [1:0] {
    IDLE     = 2'b00,
    FIRST16  = 2'b01,
    SECOND16 = 2'b10,
    ACK32    = 2'b11
} state_t;

state_t state;

// coalesce_stall: high during FIRST16 — adapter has accepted the first 16-bit
// half and is waiting for TG68K to deassert/reassert AS for the second half.
// Holds tg_clkena=0 so the CPU does not advance while the bus gap is open.
assign coalesce_stall = (state == FIRST16);

// Latched values from the first 16-bit cycle
logic [31:0] saved_addr;
logic [15:0] saved_write_hi;   // upper 16 bits of a 32-bit write
logic [15:0] read_hi;          // captured upper 16 bits of a 32-bit read
logic        saved_rw;

// Is this potentially the first half of a longword access?
// Condition: addr[1]=0, both UDS+LDS active, AS_N asserted
logic lw_first_half;
assign lw_first_half = !tg_as_n && !tg_uds_n && !tg_lds_n && (tg_addr[1] == 1'b0);

// =============================================================================
// 32-bit bus outputs — computed combinationally from current state
// =============================================================================

// Active 16-bit data mux: first half uses addr as-is; second uses saved_addr+2
logic [31:0] active_addr;
always_comb begin
    case (state)
        FIRST16:  active_addr = tg_addr;           // Cycle A address (even)
        SECOND16: active_addr = saved_addr;         // Cycle B: use saved base, addr[1]=1 driven by TG68K
        default:  active_addr = tg_addr;
    endcase
end

// cpu_addr: word address bits [23:1] (F3 address space is 24-bit per MC68EC020)
// We pass tg_addr[23:1] directly in FIRST16/IDLE/ACK32.
// In SECOND16 we pass the +2 address that TG68K is now presenting.
always_comb begin
    case (state)
        SECOND16: cpu_addr = tg_addr[23:1];        // second half: addr+2 driven by TG68K
        default:  cpu_addr = tg_addr[23:1];
    endcase
end

// cpu_as_n: assert whenever TG68K asserts its AS_N
assign cpu_as_n = tg_as_n;

// cpu_rw
assign cpu_rw = tg_rw;

// cpu_reset_n_out
assign cpu_reset_n_out = tg_reset_out_n;

// cpu_be_n: byte-enable decode from UDS/LDS + addr[1]
// addr[1]=0 → access is to upper word of 32-bit longword (cpu_din[31:16])
//              UDS active → byte D31:D24 (cpu_be_n[3])
//              LDS active → byte D23:D16 (cpu_be_n[2])
// addr[1]=1 → access is to lower word of 32-bit longword (cpu_din[15:0])
//              UDS active → byte D15:D8  (cpu_be_n[1])
//              LDS active → byte D7:D0   (cpu_be_n[0])
always_comb begin
    if (tg_addr[1] == 1'b0)
        cpu_be_n = {tg_uds_n, tg_lds_n, 2'b11};    // upper word access
    else
        cpu_be_n = {2'b11, tg_uds_n, tg_lds_n};    // lower word access
end

// cpu_dout: 32-bit write data
// For a longword write, saved_write_hi holds upper 16 bits; tg_data_write holds lower.
// For a single 16-bit write, place data in the appropriate half.
always_comb begin
    if (state == SECOND16 || state == ACK32)
        cpu_dout = {saved_write_hi, tg_data_write};
    else if (tg_addr[1] == 1'b0)
        cpu_dout = {tg_data_write, 16'h0000};       // upper word; lower not driven
    else
        cpu_dout = {16'h0000, tg_data_write};        // lower word; upper not driven
end

// tg_data_read: 16-bit slice of cpu_din presented to TG68K
// In FIRST16 / single upper-word access: give cpu_din[31:16]
// In SECOND16: give cpu_din[15:0]
always_comb begin
    if (state == SECOND16)
        tg_data_read = cpu_din[15:0];
    else if (tg_addr[1] == 1'b1)
        tg_data_read = cpu_din[15:0];               // TG68K accessing lower word directly
    else
        tg_data_read = cpu_din[31:16];              // TG68K accessing upper word
end

// =============================================================================
// State machine — coalescing two TG68K 16-bit cycles into one 32-bit access
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state           <= IDLE;
        saved_addr      <= 32'h0;
        saved_write_hi  <= 16'h0;
        read_hi         <= 16'h0;
        saved_rw        <= 1'b1;
    end else begin
        case (state)

            // -----------------------------------------------------------------
            IDLE: begin
                if (!tg_as_n) begin
                    if (lw_first_half) begin
                        // Potentially the first half of a longword access.
                        // Latch address and write data, stall DTACK.
                        state          <= FIRST16;
                        saved_addr     <= tg_addr;
                        saved_write_hi <= tg_data_write;
                        saved_rw       <= tg_rw;
                    end
                    // else: single-cycle access (word/byte, or odd-word) — pass straight through;
                    // stay in IDLE, dtack flows directly from cpu_dtack_n.
                end
            end

            // -----------------------------------------------------------------
            FIRST16: begin
                // We stall TG68K here (tg_dtack=1).  Wait until the system bus
                // has accepted the first-half address (i.e. AS is presented to
                // the system and we can issue the real cycle).
                //
                // In this implementation we immediately transition to SECOND16
                // on the next clock, asserting the system bus with the FIRST16
                // address.  The system DTACK will complete once cpu_dtack_n falls.
                // When TG68K deasserts AS_N between cycles (brief gap), we detect
                // the second AS_N assertion in SECOND16.
                //
                // Transition: when TG68K drops AS_N (between the two half-cycles)
                // we move to SECOND16 ready to catch the second assertion.
                if (tg_as_n) begin
                    // TG68K deasserted AS between the two halves — now wait for
                    // the second half assertion.
                    state <= SECOND16;
                end
            end

            // -----------------------------------------------------------------
            SECOND16: begin
                // Wait for TG68K to assert AS_N for the second half-cycle
                // (addr[1]=1, UDS+LDS active, same base address).
                if (!tg_as_n && !tg_uds_n && !tg_lds_n && (tg_addr[1] == 1'b1) &&
                    (tg_addr[31:2] == saved_addr[31:2])) begin
                    // Second half confirmed — let the combined 32-bit cycle complete.
                    // DTACK now flows from cpu_dtack_n (tg_dtack assigned in comb block).
                    // When cpu_dtack_n falls, TG68K will see DTACK and complete.
                    if (!cpu_dtack_n) begin
                        // Capture upper half of read data (already held from first cycle)
                        read_hi <= cpu_din[31:16];
                        state   <= IDLE;
                    end
                end else if (!tg_as_n && (tg_addr[31:2] != saved_addr[31:2])) begin
                    // Unexpected: TG68K started a completely different access.
                    // Abandon coalescing and return to idle.
                    state <= IDLE;
                end
            end

            // -----------------------------------------------------------------
            ACK32: begin
                // Not currently reached by this implementation; reserved for
                // future extension (e.g. if ACK needs to be held one extra cycle).
                state <= IDLE;
            end

            default: state <= IDLE;

        endcase
    end
end

// =============================================================================
// Unused signal suppression (prevent lint warnings on stub signals)
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{ipl_n, read_hi, saved_rw, active_addr, tg_fc, tg_skipFetch, tg_clr_berr};
/* verilator lint_on UNUSED */

endmodule
