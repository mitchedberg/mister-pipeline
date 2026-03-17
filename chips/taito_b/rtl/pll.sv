`default_nettype none
// =============================================================================
// pll.sv — Simulation/lint stub for Taito B PLL
// =============================================================================
//
// Replace with a Quartus Altera PLL megafunction for synthesis.
//
// Target frequencies:
//   outclk_0 = 16.0 MHz  — sys_clk (pixel clock / TC0180VCU)
//   outclk_1 = 143.0 MHz — sdram_clk (SDRAM interface)
//
// Taito B system uses a simpler single-clock architecture than Taito Z:
// - Single MC68000 @ 8 MHz (derived from 16 MHz sys_clk via /2 CE)
// - TC0180VCU pixel clock: 8 MHz (pixel clock derived from sys_clk /2)
// - YM2610 audio: 8 MHz
//
// For simulation: both outputs simply pass through the 50 MHz reference.
// Quartus PLL IP wizard will generate the real file from taito_b.qpf.
//
// Port contract matches standard MiSTer sys/pll.v wrapper.
// =============================================================================
module pll (
    input  logic refclk,    // 50 MHz from DE10-Nano CLK_50M
    input  logic rst,       // active-high reset (tie 0 in emu.sv)

    output logic outclk_0,  // 16.0 MHz — sys_clk (8 MHz pixel CE = sys/2)
    output logic outclk_1,  // 143.0 MHz — sdram_clk

    output logic locked     // 1 when PLL has acquired lock
);

    // Simulation stub: pass through reference clock, report locked immediately.
    // Synthesis: replace this module body with Quartus PLL IP.
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    assign locked   = 1'b1;

    // Suppress lint warnings for stub inputs
    logic _unused = &{rst, 1'b0};

endmodule
