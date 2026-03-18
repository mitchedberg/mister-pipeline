// =============================================================================
// pll.sv — Altera ALTPLL megafunction for Taito X on MiSTer DE-10 Nano
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
//   ce_z80  = clk_sys / 8  → 4 MHz effective Z80 sound clock
//   ce_pix  = ce_cpu        → 8 MHz pixel clock (tied to CPU CE)
//
// This file is synthesisable with Quartus Prime (ALTPLL primitive).
// =============================================================================
`default_nettype none

module pll (
    input  wire refclk,    // 50 MHz from DE10-Nano CLK_50M
    input  wire rst,       // active-high async reset

    output wire outclk_0,  // 32 MHz — clk_sys
    output wire outclk_1,  // ~143 MHz — clk_sdram (phase-shifted -2.5 ns)

    output wire locked     // asserts when PLL has acquired lock
);

altpll #(
    .bandwidth_type                 ("AUTO"),
    .clk0_divide_by                 (25),
    .clk0_duty_cycle                (50),
    .clk0_multiply_by               (16),
    .clk0_phase_shift               ("0"),
    .clk1_divide_by                 (7),
    .clk1_duty_cycle                (50),
    .clk1_multiply_by               (20),
    .clk1_phase_shift               ("-2500"),
    .compensate_clock               ("CLK0"),
    .inclk0_input_frequency         (20000),
    .intended_device_family         ("Cyclone V"),
    .lpm_hint                       ("CBX_MODULE_PREFIX=pll"),
    .lpm_type                       ("altpll"),
    .operation_mode                 ("NORMAL"),
    .pll_type                       ("AUTO"),
    .port_activeclock               ("PORT_UNUSED"),
    .port_areset                    ("PORT_USED"),
    .port_clkbad0                   ("PORT_UNUSED"),
    .port_clkbad1                   ("PORT_UNUSED"),
    .port_clkloss                   ("PORT_UNUSED"),
    .port_clkswitch                 ("PORT_UNUSED"),
    .port_configupdate              ("PORT_UNUSED"),
    .port_fbin                      ("PORT_UNUSED"),
    .port_inclk0                    ("PORT_USED"),
    .port_inclk1                    ("PORT_UNUSED"),
    .port_locked                    ("PORT_USED"),
    .port_pfdena                    ("PORT_UNUSED"),
    .port_phasecounterselect        ("PORT_UNUSED"),
    .port_phasedone                 ("PORT_UNUSED"),
    .port_phasestep                 ("PORT_UNUSED"),
    .port_phaseupdown               ("PORT_UNUSED"),
    .port_pllena                    ("PORT_UNUSED"),
    .port_scanaclr                  ("PORT_UNUSED"),
    .port_scanclk                   ("PORT_UNUSED"),
    .port_scanclkena                ("PORT_UNUSED"),
    .port_scandata                  ("PORT_UNUSED"),
    .port_scandataout               ("PORT_UNUSED"),
    .port_scandone                  ("PORT_UNUSED"),
    .port_scanread                  ("PORT_UNUSED"),
    .port_scanwrite                 ("PORT_UNUSED"),
    .port_clk0                      ("PORT_USED"),
    .port_clk1                      ("PORT_USED"),
    .port_clk2                      ("PORT_UNUSED"),
    .port_clk3                      ("PORT_UNUSED"),
    .port_clk4                      ("PORT_UNUSED"),
    .port_clk5                      ("PORT_UNUSED"),
    .using_fbmux_clk                ("FALSE")
) altpll_component (
    .areset                         (rst),
    .inclk                          ({1'b0, refclk}),
    .clk                            ({5'b00000, outclk_1, outclk_0}),
    .locked                         (locked),
    .activeclock                    (),
    .clkbad                         (),
    .clkena                         ({6{1'b1}}),
    .clkloss                        (),
    .clkswitch                      (1'b0),
    .configupdate                   (1'b0),
    .enable0                        (),
    .enable1                        (),
    .extclk                         (),
    .extclkena                      ({4{1'b1}}),
    .fbin                           (1'b1),
    .fbmimicbidir                   (),
    .fbout                          (),
    .fref                           (),
    .icdrclk                        (),
    .pfdena                         (1'b1),
    .phasecounterselect             ({4{1'b1}}),
    .phasedone                      (),
    .phasestep                      (1'b1),
    .phaseupdown                    (1'b1),
    .pllena                         (1'b1),
    .scanaclr                       (1'b0),
    .scanclk                        (1'b0),
    .scanclkena                     (1'b1),
    .scandata                       (1'b0),
    .scandataout                    (),
    .scandone                       (),
    .scanread                       (1'b0),
    .scanwrite                      (1'b0),
    .sclkout0                       (),
    .sclkout1                       (),
    .vcooverrange                   (),
    .vcounderrange                  ()
);

endmodule
