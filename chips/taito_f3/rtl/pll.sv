`default_nettype none
// =============================================================================
// pll.sv — Simulation/lint stub for Taito F3 PLL
// =============================================================================
//
// Replace with a Quartus Altera PLL megafunction for synthesis.
//
// Target frequencies (from MAME taito_f3.cpp / hardware measurements):
//   outclk_0 = 53.372 MHz  — sys_clk (CPU + all logic; pixel clock = sys_clk / 2)
//   outclk_1 = 143.0  MHz  — sdram_clk
//
// For simulation: both outputs simply pass through the 50 MHz reference.
// Quartus PLL IP wizard will generate the real file from taito_f3.qpf.
//
// Port contract matches standard MiSTer sys/pll.v wrapper.
// =============================================================================
module pll (
    input  logic refclk,    // 50 MHz from DE10-Nano CLK_50M
    input  logic rst,       // active-high reset (tie 0 in emu.sv)

    output logic outclk_0,  // 53.372 MHz — sys_clk
    output logic outclk_1,  // 143.0  MHz — sdram_clk

    output logic locked     // 1 when PLL has acquired lock
);

    // Simulation stub: pass through reference clock, report locked immediately.
    // Synthesis: replace this module body with Quartus PLL IP.
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    assign locked   = 1'b1;

endmodule
