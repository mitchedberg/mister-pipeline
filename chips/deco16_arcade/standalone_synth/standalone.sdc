# =============================================================================
# deco16_arcade — Standalone Synthesis SDC
# Timing constraints for DE-10 Nano standalone synthesis
# =============================================================================

derive_pll_clocks
derive_clock_uncertainty

# Master clock: 40 MHz sys clock
create_clock -name {clk} -period 25.000 [get_ports {clk}]

# All design logic runs from clk_sys (no other clocks in standalone)
# No multicycle paths needed for this stub — fx68k is not included here
