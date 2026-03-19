`default_nettype none
// =============================================================================
// fx68k_dtack_cen.sv — DTACK-aware clock enable generator for fx68k
//
// Clean-room implementation of the "stall CPU clock during bus wait" pattern
// used by all production MiSTer 68000 cores. Without this, the CPU's enPhi2
// can fire before DTACK (and therefore before SDRAM data arrives), causing the
// CPU to latch stale data from the previous bus cycle.
//
// Behavior:
//   - Generates enPhi1 / enPhi2 at the target CPU frequency using a fractional
//     accumulator (num/den ratio of clk_sys).
//   - When a bus cycle is active (ASn=0) and DTACK hasn't fired yet (DTACKn=1),
//     the clock enable generation is STALLED. No enPhi1 or enPhi2 pulses are
//     emitted until DTACKn goes low, ensuring the CPU only advances when valid
//     data is on the bus.
//   - After DTACK fires, clock generation resumes normally.
//
// Parameters:
//   NUM, DEN — fractional divider: CPU freq = clk_sys * NUM / DEN / 2
//              (the /2 is because enPhi1 and enPhi2 alternate)
//   Example: 40 MHz clk_sys, NUM=1, DEN=2 → 10 MHz CPU
//            48 MHz clk_sys, NUM=5, DEN=24 → 10 MHz CPU
//
// Ports:
//   enPhi1, enPhi2 — connect directly to fx68k
//   DTACKn, ASn    — directly from fx68k outputs (active-low)
//
// Based on the documented behavior of the jtframe_68kdtack module used in
// jotego cores (GPL-3.0). This is an independent implementation.
// =============================================================================

module fx68k_dtack_cen #(
    parameter NUM = 1,   // fractional numerator
    parameter DEN = 2    // fractional denominator
)(
    input  logic clk,
    input  logic rst,

    // fx68k bus signals (directly from CPU)
    input  logic ASn,
    input  logic DTACKn,

    // Clock enables — connect to fx68k enPhi1 / enPhi2
    output logic enPhi1,
    output logic enPhi2
);

// =============================================================================
// Fractional accumulator
// =============================================================================
// Generates a base "tick" at the rate clk_sys * NUM / DEN.
// Each tick alternates between enPhi1 and enPhi2.

localparam ACCW = $clog2(DEN) + 2;  // accumulator width

logic [ACCW-1:0] acc;
logic tick;
logic phase;   // 0 = next tick is enPhi1, 1 = next tick is enPhi2

// =============================================================================
// Bus stall detection
// =============================================================================
// Stall when AS is asserted (bus cycle active) and DTACK hasn't fired yet.
// Once DTACK fires (DTACKn=0), resume. Also resume when AS deasserts.
logic stall;
assign stall = !ASn && DTACKn;

// =============================================================================
// Accumulator + tick generation
// =============================================================================
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        acc   <= '0;
        phase <= 1'b0;  // first tick after reset = enPhi1
    end else if (!stall) begin
        if (acc + NUM[ACCW-1:0] >= DEN[ACCW-1:0]) begin
            acc   <= acc + NUM[ACCW-1:0] - DEN[ACCW-1:0];
            phase <= ~phase;
        end else begin
            acc   <= acc + NUM[ACCW-1:0];
        end
    end
    // When stalled: acc and phase hold, no ticks generated
end

// Tick fires on the overflow cycle (when acc wraps)
assign tick = !stall && (acc + NUM[ACCW-1:0] >= DEN[ACCW-1:0]);

// =============================================================================
// Output: mutually exclusive enPhi1 / enPhi2
// =============================================================================
// First tick after reset is enPhi1 (phase=0 before toggle).
assign enPhi1 = tick & ~phase;
assign enPhi2 = tick &  phase;

endmodule
