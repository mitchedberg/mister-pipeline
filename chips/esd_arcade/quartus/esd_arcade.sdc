# =============================================================================
# ESD 16-bit Arcade Core — Timing Constraints (SDC)
# =============================================================================
#
# System clock: 48 MHz (from PLL; CPU clock-enable = sys_clk / 3 = 16 MHz)
# Pixel clock:  8 MHz (sys_clk / 6 CE, for 320x264 @ 60Hz)
# SDRAM clock:  96 MHz (PLL output, separate domain)
# Reference:    50 MHz (FPGA_CLK1_50)
#
# CPU clock-enable ratios:
#   MC68000 : 48 MHz / 3 = 16 MHz → 3-cycle multicycle
#   Z80     : 48 MHz / 12 = 4 MHz → 12-cycle multicycle
#   YM3812  : 48 MHz / 12 = 4 MHz → false-path
#   M6295   : 48 MHz / 48 = 1 MHz → false-path
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
# CLOCK DOMAIN ISOLATION
# ==========================================================================

set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { FPGA_CLK1_50 }] \
   -group [get_clocks { FPGA_CLK2_50 }] \
   -group [get_clocks { FPGA_CLK3_50 }]

# ==========================================================================
# FALSE PATHS — I/O & USER INTERFACE
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
# FALSE PATHS — OSD DISPLAY LOGIC
# ==========================================================================

set_multicycle_path -to {*_osd|osd_vcnt*} -setup 2
set_multicycle_path -to {*_osd|osd_vcnt*} -hold 1
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
# FALSE PATHS — ARCADE VIDEO SCALER & PARAMETERS
# ==========================================================================

set_false_path -to   {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -from {WIDTH[*] HFP[*] HS[*] HBP[*] HEIGHT[*] VFP[*] VS[*] VBP[*]}
set_false_path -to   {FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -from {FB_BASE[*] FB_WIDTH[*] FB_HEIGHT[*] LFB_HMIN[*] LFB_HMAX[*] LFB_VMIN[*] LFB_VMAX[*]}
set_false_path -to   {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {vol_att[*] scaler_flt[*] led_overtake[*] led_state[*]}
set_false_path -from {aflt_* acx* acy* areset* arc* arx* ary*}
set_false_path -from {vs_line* ColorBurst_Range* PhaseInc* pal_en cvbs yc_en}

# ==========================================================================
# FALSE PATHS — ASCAL PARAMETERS
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
# FALSE PATHS — I/O EXPANDER & HPS
# ==========================================================================

set_false_path -from {mcp23009|flg_*}
set_false_path -to   {sysmem|fpga_interfaces|clocks_resets|f2h*}

# =============================================================================
# MULTI-CYCLE PATHS — Clock-Enable-Gated Subsystems
# =============================================================================

# MC68000 main CPU — 48 MHz / 3 = 16 MHz (3-cycle multicycle)
set_multicycle_path -from [get_registers {*cpu*}] -to [get_registers {*cpu*}] -setup 3
set_multicycle_path -from [get_registers {*cpu*}] -to [get_registers {*cpu*}] -hold  2

# fx68k internal paths — MANDATORY (COMMUNITY_PATTERNS.md Section 1.7)
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|microAddr[*]}]      2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|microAddr[*]}]      1
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|nanoAddr[*]}]       2
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|nanoAddr[*]}]       1
set_multicycle_path -start -setup -from [get_keepers {*|nanoLatch[*]}]        -to [get_keepers {*|alu|pswCcr[*]}]     2
set_multicycle_path -start -hold  -from [get_keepers {*|nanoLatch[*]}]        -to [get_keepers {*|alu|pswCcr[*]}]     1
set_multicycle_path -start -setup -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}]     2
set_multicycle_path -start -hold  -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}]     1

# T80 Z80 — MANDATORY (COMMUNITY_PATTERNS.md Section 1.7)
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -setup 2
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -hold 1

# Z80 sound CPU — 48 MHz / 12 = 4 MHz (12-cycle multicycle)
set_multicycle_path -from [get_registers {*u_z80*}] -to [get_registers {*u_z80*}] -setup 12
set_multicycle_path -from [get_registers {*u_z80*}] -to [get_registers {*u_z80*}] -hold  11

# YM3812 — very slow, use false-path
set_false_path -from [get_registers {*u_ym3812*}] -to [get_registers {*u_ym3812*}]

# OKI M6295 — 1 MHz, use false-path
set_false_path -from [get_registers {*u_oki*}] -to [get_registers {*u_oki*}]

# ESD video subsystem — pixel clock domain
set_multicycle_path -from [get_registers {*u_video*}] -to [get_registers {*u_video*}] -setup 6
set_multicycle_path -from [get_registers {*u_video*}] -to [get_registers {*u_video*}] -hold  5

# =============================================================================
# FALSE PATHS — ASYNCHRONOUS RESET
# =============================================================================

set_false_path -from [get_ports {reset}]
set_false_path -from [get_ports {rst}]

# =============================================================================
# FALSE PATHS — I/O TIMING
# =============================================================================

set_false_path -from [get_ports *] -to [get_registers *]
set_false_path -from [get_registers *] -to [get_ports *]

# =============================================================================
# SDRAM DATA RETURN PATH
# =============================================================================

set_multicycle_path -setup -end -from [get_keepers {SDRAM_DQ[*]}] \
    -to [get_keepers {*|dq_ff[*]}] 2
set_multicycle_path -hold -end -from [get_keepers {SDRAM_DQ[*]}] \
    -to [get_keepers {*|dq_ff[*]}] 2

# =============================================================================
# END OF TIMING CONSTRAINTS
# =============================================================================
