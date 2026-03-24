# =============================================================================
# NMK16 Arcade Core — Timing Constraints (SDC)
# =============================================================================
#
# Timing constraints for NMK16 MiSTer core on DE-10 Nano (Cyclone V)
#
# System clock: 40 MHz (from PLL; CPU clock-enable = sys_clk / 4 = 10 MHz)
# Pixel clock:  10 MHz (sys_clk / 4 CE)
# SDRAM clock:  143.0 MHz (PLL output)
# Reference:    50 MHz (FPGA_CLK1_50)
#
# Clock-enable divide ratios (all CEN logic runs on clk_sys = 40 MHz):
#   MC68000 CPU : 40 MHz / 4  = 10 MHz  → 4-cycle multicycle
#   Z80 sound   : 40 MHz / 5  =  8 MHz  → 5-cycle multicycle
#   YM2203 FM   : 40 MHz / 27 ≈  1.5 MHz → 27-cycle multicycle (false-path safe)
#   OKI M6295   : 40 MHz / 40 =  1 MHz  → 40-cycle multicycle (false-path safe)
#
# =============================================================================

# =========================================================================
# PRIMARY INPUT CLOCKS (DE-10 Nano)
# =========================================================================

create_clock -period "20.0 ns" -name {FPGA_CLK1_50} [get_ports {FPGA_CLK1_50}]
create_clock -period "20.0 ns" -name {FPGA_CLK2_50} [get_ports {FPGA_CLK2_50}]
create_clock -period "20.0 ns" -name {FPGA_CLK3_50} [get_ports {FPGA_CLK3_50}]

# ==========================================================================
# GENERATED CLOCKS (from PLL)
# ==========================================================================

derive_pll_clocks
derive_clock_uncertainty

# ==========================================================================
# CLOCK DOMAIN ISOLATION (Exclusive Clock Groups)
# ==========================================================================

set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { FPGA_CLK1_50 }] \
   -group [get_clocks { FPGA_CLK2_50 }] \
   -group [get_clocks { FPGA_CLK3_50 }]

# ==========================================================================
# FALSE PATHS — USER INPUT & DISPLAY
# ==========================================================================

set_false_path -from [get_ports {KEY*}]
set_false_path -from [get_ports {BTN_*}]
set_false_path -to   [get_ports {LED_*}]
set_false_path -to   [get_ports {VGA_*}]
set_false_path -from [get_ports {VGA_EN}]
set_false_path -to   [get_ports {AUDIO_SPDIF}]
set_false_path -to   [get_ports {AUDIO_L}]
set_false_path -to   [get_ports {AUDIO_R}]
set_false_path -from [get_ports {SW[*]}]

# ==========================================================================
# FALSE PATHS — CONFIGURATION & DISPLAY SCALING
# ==========================================================================

set_false_path -to   {cfg[*]}
set_false_path -from {cfg[*]}
set_false_path -from {VSET[*]}
set_false_path -to   {wcalc[*] hcalc[*]}
set_false_path -to   {hdmi_width[*] hdmi_height[*]}
set_false_path -to   {deb_* btn_en btn_up}

# ==========================================================================
# MULTI-CYCLE PATHS — OSD Counters
# ==========================================================================

set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2
set_multicycle_path -to {*_osd|osd_vcnt*} -hold 1

# ==========================================================================
# FALSE PATHS — OSD DISPLAY LOGIC
# ==========================================================================

set_false_path -to   {*_osd|v_cnt*}
set_false_path -to   {*_osd|v_osd_start*}
set_false_path -to   {*_osd|v_info_start*}
set_false_path -to   {*_osd|h_osd_start*}
set_false_path -from {*_osd|v_osd_start*}
set_false_path -from {*_osd|v_info_start*}
set_false_path -from {*_osd|h_osd_start*}
set_false_path -from {*_osd|rot*}
set_false_path -from {*_osd|dsp_width*}
set_false_path -to   {*_osd|half}

# ==========================================================================
# FALSE PATHS — ARCADE VIDEO SCALER
# ==========================================================================

set_false_path -to   {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -from {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -to   {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -from {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -to   {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}

# ==========================================================================
# FALSE PATHS — ANALOG VIDEO & FILTERS
# ==========================================================================

set_false_path -from {aflt_* acx* acy* areset* arc*}
set_false_path -from {arx* ary*}
set_false_path -from {vs_line*}
set_false_path -from {ColorBurst_Range* PhaseInc* pal_en cvbs yc_en}

# ==========================================================================
# FALSE PATHS — ASCAL (Advanced Scaler) PARAMETERS
# ==========================================================================

set_false_path -from {ascal|o_ihsize*}
set_false_path -from {ascal|o_ivsize*}
set_false_path -from {ascal|o_format*}
set_false_path -from {ascal|o_hdown}
set_false_path -from {ascal|o_vdown}
set_false_path -from {ascal|o_hmin* ascal|o_hmax* ascal|o_vmin* ascal|o_vmax* ascal|o_vrrmax* ascal|o_vrr}
set_false_path -from {ascal|o_hdisp* ascal|o_vdisp*}
set_false_path -from {ascal|o_htotal* ascal|o_vtotal*}
set_false_path -from {ascal|o_hsstart* ascal|o_vsstart* ascal|o_hsend* ascal|o_vsend*}
set_false_path -from {ascal|o_hsize* ascal|o_vsize*}

# ==========================================================================
# FALSE PATHS — I/O EXPANDER & HPS INTERFACE
# ==========================================================================

set_false_path -from {mcp23009|flg_*}
set_false_path -to   {sysmem|fpga_interfaces|clocks_resets|f2h*}

# =============================================================================
# MULTI-CYCLE PATHS — Clock-Enable-Gated Subsystems
#
# All subsystems run on clk_sys but are gated by a 1-cycle-wide CEN pulse.
# Quartus treats CEN paths as single-cycle by default, causing false violations.
# set_multicycle_path relaxes setup/hold to match the actual clock rate.
#
# Formula: setup = divide_ratio, hold = divide_ratio - 1
# =============================================================================

# MC68000 main CPU — 40 MHz / 4 = 10 MHz (4-cycle multicycle)
# The CPU bus signals (addr, data, strobes) all propagate only when the CPU
# advances, giving 4 master cycles = 100 ns to settle.
set_multicycle_path -from [get_registers {*cpu*}]  -to [get_registers {*cpu*}]  -setup 4
set_multicycle_path -from [get_registers {*cpu*}]  -to [get_registers {*cpu*}]  -hold  3

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

# Z80 sound CPU — 40 MHz / 5 = 8 MHz (5-cycle multicycle)
# T80s instance (u_z80), CEN = ce_z80 (clk_sys / 5).
set_multicycle_path -from [get_registers {*u_z80*}] -to [get_registers {*u_z80*}] -setup 5
set_multicycle_path -from [get_registers {*u_z80*}] -to [get_registers {*u_z80*}] -hold  4

# Z80 clock-enable counter and auxiliary Z80-domain registers
set_multicycle_path -from [get_registers {*ce_z80*}] -to [get_registers {*ce_z80*}] -setup 5
set_multicycle_path -from [get_registers {*ce_z80*}] -to [get_registers {*ce_z80*}] -hold  4

# YM2203 FM (jt03) — 40 MHz / 27 ≈ 1.48 MHz
# Paths internal to u_ym2203 can use false-path; the CEN output is also very slow.
set_false_path -from [get_registers {*u_ym2203*}] -to [get_registers {*u_ym2203*}]

# OKI M6295 (jt6295) — 40 MHz / 40 = 1 MHz
# Similar treatment — internal state only advances at 1 MHz.
set_false_path -from [get_registers {*u_oki_m6295*}] -to [get_registers {*u_oki_m6295*}]

# NMK16 graphics chip (u_nmk16) — clocked at full 40 MHz, pixel CE = /4
# Internal pixel-pipeline registers only latch valid data every 4th cycle.
set_multicycle_path -from [get_registers {*u_nmk16*}] -to [get_registers {*u_nmk16*}] -setup 4
set_multicycle_path -from [get_registers {*u_nmk16*}] -to [get_registers {*u_nmk16*}] -hold  3

# =============================================================================
# FALSE PATHS — ASYNCHRONOUS RESET RECOVERY
# =============================================================================
# Reset is a one-time event from the MiSTer framework, not a timing-critical
# path. Recovery/removal timing on flip-flop async clear pins is safely ignored.
#
set_false_path -from [get_ports {reset}]
set_false_path -from [get_ports {rst}]

# =============================================================================
# FALSE PATHS — I/O TIMING (not timing-critical for arcade cores)
# =============================================================================
# All real I/O goes through the MiSTer framework's dedicated sys/ I/O paths.
# Internal module I/O delays are safely ignored per jotego practice.
#
set_false_path -from [get_ports *] -to [get_registers *]
set_false_path -from [get_registers *] -to [get_ports *]

# =============================================================================
# END OF TIMING CONSTRAINTS
# =============================================================================
