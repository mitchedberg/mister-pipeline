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
# END OF TIMING CONSTRAINTS
# =============================================================================
