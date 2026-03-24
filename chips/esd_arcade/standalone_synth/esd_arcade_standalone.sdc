# =============================================================================
# esd_arcade_standalone.sdc — Standalone synthesis timing constraints
#
# Minimal SDC for gate3 synthesis. See chips/esd_arcade/quartus/esd_arcade.sdc
# for the full production constraint file.
# =============================================================================

# ── Primary clock ─────────────────────────────────────────────────────────────
# 48 MHz system clock (20.83 ns period)
create_clock -period "20.83 ns" -name {clk_sys} [get_ports {clk_sys}]

# ── fx68k internal multicycle paths (MANDATORY per COMMUNITY_PATTERNS.md 1.7) ──
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|microAddr[*]}]      2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|microAddr[*]}]      1
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|nanoAddr[*]}]       2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|nanoAddr[*]}]       1
set_multicycle_path -start -setup -from [get_keepers {*|nanoLatch[*]}]        -to [get_keepers {*|alu|pswCcr[*]}]     2
set_multicycle_path -start -hold  -from [get_keepers {*|nanoLatch[*]}]        -to [get_keepers {*|alu|pswCcr[*]}]     1
set_multicycle_path -start -setup -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}]     2
set_multicycle_path -start -hold  -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}]     1

# ── T80 Z80 — required or synthesis fails timing ──────────────────────────────
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -setup 2
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -hold 1

# ── MC68000 clock-enable domain (48 MHz / 3 = 16 MHz) ────────────────────────
set_multicycle_path -from [get_registers {*u_esd*}] -to [get_registers {*u_esd*}] -setup 3
set_multicycle_path -from [get_registers {*u_esd*}] -to [get_registers {*u_esd*}] -hold  2

# ── False paths — I/O ports ───────────────────────────────────────────────────
set_false_path -from [get_ports *] -to [get_registers *]
set_false_path -from [get_registers *] -to [get_ports *]
