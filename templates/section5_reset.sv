`default_nettype none
// Section 5 — Required Reset Synchronizer Pattern
//
// Purpose: Convert an asynchronous external reset input into a reset signal
// that is safe to use as a synchronous reset throughout the FPGA fabric.
//
// Strategy: Async ASSERT, Synchronous DEASSERT
//   - ASSERT  (rst_n_in goes low):  rst_n_out goes low IMMEDIATELY.
//             This is safe — asserting reset at any time is always correct.
//   - DEASSERT (rst_n_in goes high): rst_n_out goes high only after two
//             clean clock edges. This eliminates metastability at the
//             reset release boundary.
//
// Usage:
//   1. Instantiate ONE reset_sync per clock domain.
//   2. Connect the FPGA's active-low reset button / HPS reset to async_rst_n_i.
//   3. Use rst_n_o as the synchronous reset for all always_ff in that domain.
//   4. Never use async_rst_n_i directly in any always_ff sensitivity list
//      other than this synchronizer.
//
// This is the ONLY approved place for an async reset in the sensitivity list.

module reset_sync (
    input  logic clk,
    input  logic async_rst_n_i,  // raw async active-low reset (from button/HPS)
    output logic rst_n_o         // synchronized active-low reset (safe to use everywhere)
);

logic [1:0] rst_pipe;

// Async assert: when async_rst_n_i goes low, rst_pipe clears immediately.
// Sync deassert: when async_rst_n_i returns high, rst_pipe shifts in 1'b1
//               over two clock cycles before rst_n_o deasserts.
always_ff @(posedge clk or negedge async_rst_n_i) begin
    if (!async_rst_n_i) rst_pipe <= 2'b00;
    else                rst_pipe <= {rst_pipe[0], 1'b1};
end

assign rst_n_o = rst_pipe[1];

endmodule


// ─────────────────────────────────────────────────────────────────────────────
// Inline pattern (for modules that don't instantiate reset_sync separately)
//
// Copy this block into any module that needs a local reset synchronizer.
// Replace 'async_rst_n' with your actual input port name.
//
//   logic [1:0] rst_pipe;
//   always_ff @(posedge clk or negedge async_rst_n)
//       if (!async_rst_n) rst_pipe <= 2'b00;
//       else              rst_pipe <= {rst_pipe[0], 1'b1};
//   logic rst_n;
//   assign rst_n = rst_pipe[1];
//
// Then use 'rst_n' (not 'async_rst_n') in all subsequent always_ff blocks:
//
//   always_ff @(posedge clk) begin
//       if (!rst_n) my_signal <= '0;
//       else        my_signal <= next_value;
//   end
// ─────────────────────────────────────────────────────────────────────────────
