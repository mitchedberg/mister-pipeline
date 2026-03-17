`default_nettype none
// =============================================================================
// pll.sv — Simulation/lint stub for Taito X PLL
// =============================================================================
//
// Replace with a Quartus Altera PLL megafunction for synthesis.
//
// Target frequencies:
//   outclk_0 = 32.0 MHz  — clk_sys
//     68000 uses /4 clock-enable  → 8 MHz effective CPU clock
//     Pixel clock uses /4 CE      → 8 MHz pixel clock  (~9.2 MHz HW target)
//     Z80 uses /8 clock-enable    → 4 MHz effective clock
//   outclk_1 = 143.0 MHz — clk_sdram (SDRAM controller)
//
// Hardware clocks (from README.md §Core Specifications):
//   Master crystal: 16 MHz
//   68000: 8 MHz (÷2 from 16 MHz)
//   Z80:   4 MHz (÷4 from 16 MHz)
//   Pixel: ~9.2 MHz (÷ ~1.7, from 16 MHz — approximated as 8 MHz here)
//
// The DE10-Nano PLL is programmed to 32 MHz (2× the 16 MHz master) to allow
// each subsystem to derive its clock via a /N clock-enable in emu.sv.
//
// Port contract matches standard MiSTer sys/pll.v wrapper.
// =============================================================================
module pll (
    input  logic refclk,    // 50 MHz from DE10-Nano CLK_50M
    input  logic rst,       // active-high reset (tie 0 in emu.sv)

    output logic outclk_0,  // 32.0 MHz — clk_sys
    output logic outclk_1,  // 143.0 MHz — clk_sdram

    output logic locked     // 1 when PLL has acquired lock
);

    // Simulation stub: pass through reference clock, report locked immediately.
    // Replace this module body with Quartus PLL IP for synthesis.
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    assign locked   = 1'b1;

endmodule
