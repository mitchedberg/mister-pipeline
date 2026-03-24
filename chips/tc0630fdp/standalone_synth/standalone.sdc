# =============================================================================
# TC0630FDP — Standalone Synthesis SDC
# =============================================================================
# Single clock domain: the 'clk' input in tc0630fdp_top.
# Constrain at 53.333 MHz (same as the Taito F3 system clock) — tighter
# than the ~6.67 MHz real pixel clock, so timing results are conservative.
# =============================================================================

create_clock -name {clk} -period 18.750 [get_ports {clk}]
derive_clock_uncertainty

# All I/O is internal (tied-off); mark ports as false paths.
set_false_path -from [get_ports {clk}]
set_false_path -to   [get_ports {led}]

# fx68k internal paths — span two phi phases (MANDATORY — COMMUNITY_PATTERNS.md Section 1.7)
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|microAddr[*]}]      2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|microAddr[*]}]      1
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|nanoAddr[*]}]       2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|nanoAddr[*]}]       1
set_multicycle_path -start -setup -from [get_keepers {*|nanoLatch[*]}]        -to [get_keepers {*|alu|pswCcr[*]}]     2
set_multicycle_path -start -hold  -from [get_keepers {*|nanoLatch[*]}]        -to [get_keepers {*|alu|pswCcr[*]}]     1
set_multicycle_path -start -setup -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}]     2
set_multicycle_path -start -hold  -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}]     1

# T80 Z80 — required or synthesis fails timing
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -setup 2
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -hold 1
