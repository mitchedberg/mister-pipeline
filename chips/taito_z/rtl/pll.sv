`default_nettype none
// =============================================================================
// pll.sv — Simulation/lint stub for Taito Z PLL
// =============================================================================
//
// Replace with a Quartus Altera PLL megafunction for synthesis.
//
// Target frequencies:
//   outclk_0 = 32.0 MHz  — sys_clk (32 MHz / 2 = 16 MHz per-CPU clock-enable)
//                           TC0480SCP pixel clock derived as clk_sys / 2 (16 MHz)
//   outclk_1 = 143.0 MHz — sdram_clk
//
// Taito Z CPUs run at 16 MHz (32 MHz XTAL / 2). The system clock here is 32 MHz
// so each CPU uses a /2 clock enable. This gives precise 16 MHz effective rate.
// TC0480SCP pixel clock: 16 MHz (sys_clk / 2 CE).
//
// For simulation: both outputs simply pass through the 50 MHz reference.
// Quartus PLL IP wizard will generate the real file from taito_z.qpf.
//
// Port contract matches standard MiSTer sys/pll.v wrapper.
// =============================================================================
module pll (
    input  logic refclk,    // 50 MHz from DE10-Nano CLK_50M
    input  logic rst,       // active-high reset (tie 0 in emu.sv)

    output logic outclk_0,  // 32.0 MHz — sys_clk (CPU /2 CE gives 16 MHz)
    output logic outclk_1,  // 143.0 MHz — sdram_clk

    output logic locked     // 1 when PLL has acquired lock
);

    // Simulation stub: pass through reference clock, report locked immediately.
    // Synthesis: replace this module body with Quartus PLL IP.
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    assign locked   = 1'b1;

endmodule
