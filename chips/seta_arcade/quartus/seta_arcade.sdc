# SETA 1 — Timing Constraints
# Auto-generated from MAME seta/seta.cpp

derive_pll_clocks
derive_clock_uncertainty

# fx68k multicycle paths (mandatory — see COMMUNITY_PATTERNS.md Section 1.7)
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]          -to [get_keepers {*|microAddr[*]}] 2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]          -to [get_keepers {*|microAddr[*]}] 1
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]          -to [get_keepers {*|nanoAddr[*]}]  2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]          -to [get_keepers {*|nanoAddr[*]}]  1
set_multicycle_path -start -setup -from [get_keepers {*|nanoLatch[*]}]   -to [get_keepers {*|alu|pswCcr[*]}] 2
set_multicycle_path -start -hold  -from [get_keepers {*|nanoLatch[*]}]   -to [get_keepers {*|alu|pswCcr[*]}] 1
set_multicycle_path -start -setup -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}] 2
set_multicycle_path -start -hold  -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}] 1

# T80 Z80 multicycle paths (mandatory)
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -setup 2
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -hold 1
