# =============================================================================
# Taito X — Timing Constraints (SDC)
# =============================================================================
#
# Timing constraints for Taito X MiSTer core on DE-10 Nano (Cyclone V)
#
# System clock: 32 MHz (from PLL; CPU clock-enable = sys_clk / 4 = 8 MHz)
# Pixel clock:  8 MHz (sys_clk / 4 CE)
# SDRAM clock:  143.0 MHz (PLL output)
# Reference:    50 MHz (CLK_50M)
#
# =============================================================================

# =========================================================================
# PRIMARY INPUT CLOCKS (DE-10 Nano)
# =========================================================================

# Main FPGA reference clock (50 MHz) — used by PLL
create_clock -period "20.0 ns" -name {CLK_50M} [get_ports {CLK_50M}]

# ==========================================================================
# GENERATED CLOCKS (from PLL)
# ==========================================================================

# Automatically derive all PLL-generated clocks from sys.tcl/sys.qip
# These include sys_clk (32 MHz), sdram_clk (143 MHz), HDMI clocks, audio clocks.
derive_pll_clocks

# Apply timing margin for setup/hold across process corners
derive_clock_uncertainty

# ==========================================================================
# CLOCK DOMAIN ISOLATION (Exclusive Clock Groups)
# ==========================================================================
#
# Taito X operates in multiple asynchronous clock domains:
#   — sys_clk (32 MHz): CPU, X1-001A, palette, color mix
#   — sdram_clk (143 MHz): SDRAM controller
#   — HDMI clocks: Video output
#   — Audio clocks: I2S output
#

set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { CLK_50M }]

# ==========================================================================
# FALSE PATHS — USER INPUT & DISPLAY
# ==========================================================================

# Button inputs (asynchronous to system clock)
set_false_path -from [get_ports {KEY*}]
set_false_path -from [get_ports {BTN_*}]

# LED outputs (low timing criticality)
set_false_path -to   [get_ports {LED_*}]

# VGA/HDMI outputs (timing handled by arcade_video scaler)
set_false_path -to   [get_ports {VGA_*}]
set_false_path -from [get_ports {VGA_EN}]

# Audio outputs (I2S clock-domain crossing)
set_false_path -to   [get_ports {AUDIO_SPDIF}]
set_false_path -to   [get_ports {AUDIO_L}]
set_false_path -to   [get_ports {AUDIO_R}]

# DIP switches (async, sampled by core)
set_false_path -from [get_ports {SW[*]}]

# ==========================================================================
# FALSE PATHS — CONFIGURATION & DISPLAY SCALING
# ==========================================================================

# OSD/scaler configuration (changed infrequently)
set_false_path -to   {cfg[*]}
set_false_path -from {cfg[*]}
set_false_path -from {VSET[*]}

# Display resolution calculator
set_false_path -to   {wcalc[*] hcalc[*]}

# HDMI resolution configuration
set_false_path -to   {hdmi_width[*] hdmi_height[*]}

# Debounce & button enable (slow control path)
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

# Framebuffer configuration
set_false_path -to   {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -from {FB_BASE[*] FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}

# Scaler control signals
set_false_path -to   {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}

# ==========================================================================
# FALSE PATHS — ANALOG VIDEO & FILTERS
# ==========================================================================

set_false_path -from {aflt_* acx* acy* areset* arc*}
set_false_path -from {arx* ary*}
set_false_path -from {vs_line*}

# Color burst & PAL/NTSC configuration
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
# CLOCK DOMAIN ISOLATION
# =============================================================================

set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { CLK_50M }]

# =============================================================================
# MULTI-CYCLE PATHS — Clock-Enable-Gated Subsystems
#
# Taito X system clock: 32 MHz
#   MC68000 CPU : 32 MHz / 4 =  8 MHz  → 4-cycle multicycle
#   Z80 sound   : 32 MHz / 5 =  6.4 MHz → 5-cycle multicycle
#   YM2610 FM   : very slow (clk_sys / 144+) → false path
#   X1-001A     : 32 MHz / 2 CE → 2-cycle multicycle
# =============================================================================

# MC68000 CPU — 32 MHz / 4 = 8 MHz (4-cycle multicycle)
set_multicycle_path -from [get_registers {*u_cpu*}]  -to [get_registers {*u_cpu*}]  -setup 4
set_multicycle_path -from [get_registers {*u_cpu*}]  -to [get_registers {*u_cpu*}]  -hold  3
set_multicycle_path -from [get_registers {*fx68k*}]  -to [get_registers {*fx68k*}]  -setup 4
set_multicycle_path -from [get_registers {*fx68k*}]  -to [get_registers {*fx68k*}]  -hold  3

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

# Z80 sound CPU — 32 MHz / 5 = 6.4 MHz (5-cycle multicycle)
set_multicycle_path -from [get_registers {*u_z80*}] -to [get_registers {*u_z80*}] -setup 5
set_multicycle_path -from [get_registers {*u_z80*}] -to [get_registers {*u_z80*}] -hold  4

# YM2610 FM (jt10/jt12) — very slow clock → false path
set_false_path -from [get_registers {*u_ym2610*}] -to [get_registers {*u_ym2610*}]

# X1-001A sprite engine — 32 MHz / 2 CE
set_multicycle_path -from [get_registers {*u_x1001a*}] -to [get_registers {*u_x1001a*}] -setup 2
set_multicycle_path -from [get_registers {*u_x1001a*}] -to [get_registers {*u_x1001a*}] -hold  1

# =============================================================================
# FALSE PATHS — ASYNCHRONOUS RESET RECOVERY
# =============================================================================

set_false_path -from [get_ports {reset}]
set_false_path -from [get_ports {rst}]

# =============================================================================
# FALSE PATHS — I/O TIMING (not timing-critical for arcade cores)
# =============================================================================

set_false_path -from [get_ports *] -to [get_registers *]
set_false_path -from [get_registers *] -to [get_ports *]

# =============================================================================
# END OF TIMING CONSTRAINTS
# =============================================================================
