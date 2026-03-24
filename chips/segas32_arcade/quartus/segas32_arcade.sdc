# =============================================================================
# segas32_arcade — Timing Constraints (SDC)
# =============================================================================
#
# System clock: 32 MHz (V60 CPU clock-enable = sys_clk / 2 = 16 MHz)
# Pixel clock:  ~6.4 MHz (sys_clk / 5 CE)
# SDRAM clock:  143.0 MHz (PLL output)
# Reference:    50 MHz (FPGA_CLK1_50)
#
# Clock-enable divide ratios (all CEN logic runs on clk_sys = 32 MHz):
#   V60 CPU  : 32 MHz / 2  = 16 MHz  → 2-cycle multicycle
#   Pixel CE : 32 MHz / 5  =  6.4 MHz → 5-cycle multicycle
#
# The V60 is a 16-bit external bus CPU (unlike 68000/fx68k); it does not
# have the phi1/phi2 two-phase constraint.  Standard 2-cycle multicycle
# applies for the /2 clock-enable domain.
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
# All subsystems run on clk_sys (32 MHz) but are gated by a 1-cycle-wide CEN
# pulse. set_multicycle_path relaxes setup/hold to match the actual clock rate.
#
# Formula: setup = divide_ratio, hold = divide_ratio - 1
# =============================================================================

# V60 main CPU — 32 MHz / 2 = 16 MHz (2-cycle multicycle)
# The V60 is clock-enabled at /2; bus signals propagate every other cycle.
# NOTE: No phi1/phi2 two-phase constraint (unlike fx68k) — standard /2 applies.
set_multicycle_path -from [get_registers {*u_v60*}]    -to [get_registers {*u_v60*}]    -setup 2
set_multicycle_path -from [get_registers {*u_v60*}]    -to [get_registers {*u_v60*}]    -hold  1

# V60 ALU internal paths
set_multicycle_path -from [get_registers {*v60_alu*}]  -to [get_registers {*v60_alu*}]  -setup 2
set_multicycle_path -from [get_registers {*v60_alu*}]  -to [get_registers {*v60_alu*}]  -hold  1

# V60 register file (wide, 32x32-bit) — relax to match CPU clock enable
set_multicycle_path -from [get_registers {*v60_core*}] -to [get_registers {*v60_core*}] -setup 2
set_multicycle_path -from [get_registers {*v60_core*}] -to [get_registers {*v60_core*}] -hold  1

# Pixel clock-enable domain — 32 MHz / 5 = 6.4 MHz (5-cycle multicycle)
# Video timing and pixel pipeline only advance on ce_pix pulses.
set_multicycle_path -from [get_registers {*ce_pix*}]   -to [get_registers {*ce_pix*}]   -setup 5
set_multicycle_path -from [get_registers {*ce_pix*}]   -to [get_registers {*ce_pix*}]   -hold  4

# System 32 video hardware — full 32 MHz but pixel pipeline stalls on ce_pix
set_multicycle_path -from [get_registers {*segas32_video*}] -to [get_registers {*segas32_video*}] -setup 2
set_multicycle_path -from [get_registers {*segas32_video*}] -to [get_registers {*segas32_video*}] -hold  1

# GFX fetch FSM — runs at clk_sys, stalls waiting for SDRAM ack
set_multicycle_path -from [get_registers {*gfx_fetch*}] -to [get_registers {*gfx_fetch*}] -setup 2
set_multicycle_path -from [get_registers {*gfx_fetch*}] -to [get_registers {*gfx_fetch*}] -hold  1

# =============================================================================
# I/O TIMING RELAXATION
# =============================================================================

set_input_delay  -clock [get_clocks {FPGA_CLK1_50}] -max 5.0 [get_ports {*}]
set_input_delay  -clock [get_clocks {FPGA_CLK1_50}] -min 0.0 [get_ports {*}]
set_output_delay -clock [get_clocks {FPGA_CLK1_50}] -max 5.0 [get_ports {*}]
set_output_delay -clock [get_clocks {FPGA_CLK1_50}] -min 0.0 [get_ports {*}]

# =============================================================================
# FALSE PATHS — ASYNCHRONOUS RESET RECOVERY
# =============================================================================

set_false_path -from [get_ports {reset}]
set_false_path -from [get_ports {rst}]

# =============================================================================
# END OF TIMING CONSTRAINTS
# =============================================================================
