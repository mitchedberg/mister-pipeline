// =============================================================================
// pll.sv — Altera altera_pll megafunction for Taito B on MiSTer DE-10 Nano
// =============================================================================
//
// Target device : Intel Cyclone V 5CSEBA6U23I7 (DE-10 Nano)
// Input         : 50 MHz (CLK_50M)
// Outputs       :
//   outclk_0 = 32 MHz   — clk_sys  (50 * 16 / 25)
//   outclk_1 = 142.857 MHz ≈ 143 MHz — clk_sdram (50 * 20 / 7), phase -2.5 ns
//
// Clock enable relationships in emu.sv:
//   ce_cpu  = clk_sys / 4  → 8 MHz effective MC68000 clock
//   ce_pix  = clk_sys / 5  → 6.4 MHz pixel clock
//   ce_snd  = clk_sys / 8  → 4 MHz YM2610 + Z80 sound clock
//
// This file is synthesisable with Quartus Prime (altera_pll primitive).
// For simulation use the MiSTer sim PLL stub (pll_sim.sv).
// =============================================================================
`timescale 1ns/10ps
`default_nettype none

module pll (
    input  wire refclk,   // 50 MHz
    input  wire rst,
    output wire outclk_0, // sys_clk  — 32.0 MHz
    output wire outclk_1, // sdram_clk — 142.857143 MHz, phase -2500 ps
    output wire locked
);

altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("direct"),
    .number_of_clocks(2),
    .output_clock_frequency0("32.0 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("142.857143 MHz"),
    .phase_shift1("-2500 ps"),
    .duty_cycle1(50),
    .output_clock_frequency2("0 MHz"),
    .phase_shift2("0 ps"),
    .duty_cycle2(50),
    .output_clock_frequency3("0 MHz"),
    .phase_shift3("0 ps"),
    .duty_cycle3(50),
    .output_clock_frequency4("0 MHz"),
    .phase_shift4("0 ps"),
    .duty_cycle4(50),
    .output_clock_frequency5("0 MHz"),
    .phase_shift5("0 ps"),
    .duty_cycle5(50),
    .output_clock_frequency6("0 MHz"),
    .phase_shift6("0 ps"),
    .duty_cycle6(50),
    .output_clock_frequency7("0 MHz"),
    .phase_shift7("0 ps"),
    .duty_cycle7(50),
    .output_clock_frequency8("0 MHz"),
    .phase_shift8("0 ps"),
    .duty_cycle8(50),
    .output_clock_frequency9("0 MHz"),
    .phase_shift9("0 ps"),
    .duty_cycle9(50),
    .output_clock_frequency10("0 MHz"),
    .phase_shift10("0 ps"),
    .duty_cycle10(50),
    .output_clock_frequency11("0 MHz"),
    .phase_shift11("0 ps"),
    .duty_cycle11(50),
    .output_clock_frequency12("0 MHz"),
    .phase_shift12("0 ps"),
    .duty_cycle12(50),
    .output_clock_frequency13("0 MHz"),
    .phase_shift13("0 ps"),
    .duty_cycle13(50),
    .output_clock_frequency14("0 MHz"),
    .phase_shift14("0 ps"),
    .duty_cycle14(50),
    .output_clock_frequency15("0 MHz"),
    .phase_shift15("0 ps"),
    .duty_cycle15(50),
    .output_clock_frequency16("0 MHz"),
    .phase_shift16("0 ps"),
    .duty_cycle16(50),
    .output_clock_frequency17("0 MHz"),
    .phase_shift17("0 ps"),
    .duty_cycle17(50),
    .pll_type("General"),
    .pll_subtype("General")
) altera_pll_i (
    .rst(rst),
    .outclk({outclk_1, outclk_0}),
    .locked(locked),
    .fboutclk(),
    .fbclk(1'b0),
    .refclk(refclk)
);

endmodule
