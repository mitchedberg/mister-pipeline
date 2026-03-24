# =============================================================================
# Raizing Arcade — Timing Constraints (SDC)
# Revision: 2026-03-24
# =============================================================================
#
# Timing constraints for Raizing Arcade MiSTer core on DE-10 Nano (Cyclone V)
#
# Target: Battle Garegga (RA9503)
# System clock: 96 MHz (from PLL)
#   MC68000 @ 16 MHz (96 MHz / 6 — two-phase enPhi1/enPhi2)
#   Z80     @  4 MHz (96 MHz / 24)
#   Pixel   @  8 MHz (96 MHz / 12)
# Reference:   50 MHz (FPGA_CLK1_50)
#
# =============================================================================

# =========================================================================
# PRIMARY INPUT CLOCKS (DE-10 Nano)
# =========================================================================

# Main FPGA reference clock (50 MHz) — used by PLL
create_clock -period "20.0 ns" -name {FPGA_CLK1_50} [get_ports {FPGA_CLK1_50}]

# Secondary reference clocks (defined for completeness)
create_clock -period "20.0 ns" -name {FPGA_CLK2_50} [get_ports {FPGA_CLK2_50}]
create_clock -period "20.0 ns" -name {FPGA_CLK3_50} [get_ports {FPGA_CLK3_50}]

# ==========================================================================
# GENERATED CLOCKS (from PLL)
# ==========================================================================

# Automatically derive all PLL-generated clocks from sys.tcl/sys.qip
# These include sys_clk (96 MHz), clk_sdram (133 MHz), HDMI clocks, audio clocks.
derive_pll_clocks

# Apply timing margin for setup/hold across process corners
derive_clock_uncertainty

# SDRAM chip clock (output pin, driven by PLL outclk_1 at 133 MHz)
create_generated_clock -name {SDRAM_CLK} \
    -source [get_pins {u_pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
    [get_ports {SDRAM_CLK}]

# ==========================================================================
# CLOCK DOMAIN ISOLATION (Exclusive Clock Groups)
# ==========================================================================
#
# Raizing operates in multiple asynchronous clock domains:
#   — sys_clk (96 MHz): CPU, GP9001, palette RAM, work RAM, audio
#   — HDMI clocks: Video output
#   — Audio clocks: I2S output
#

set_clock_groups -exclusive \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
   -group [get_clocks { SDRAM_CLK }] \
   -group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks { FPGA_CLK1_50 }] \
   -group [get_clocks { FPGA_CLK2_50 }] \
   -group [get_clocks { FPGA_CLK3_50 }]

# ==========================================================================
# SDRAM I/O TIMING
# ==========================================================================

# SDRAM data bus I/O (setup/hold relative to SDRAM_CLK)
set_input_delay  -clock {SDRAM_CLK} -max 5.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock {SDRAM_CLK} -min 2.7 [get_ports {SDRAM_DQ[*]}]
set_output_delay -clock {SDRAM_CLK} -max 1.6 [get_ports {SDRAM_DQ[*]}]
set_output_delay -clock {SDRAM_CLK} -min -0.9 [get_ports {SDRAM_DQ[*]}]

# SDRAM command outputs (setup/hold relative to SDRAM_CLK)
set_output_delay -clock {SDRAM_CLK} -max 1.6 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE SDRAM_DQML SDRAM_DQMH}]
set_output_delay -clock {SDRAM_CLK} -min -0.9 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE SDRAM_DQML SDRAM_DQMH}]

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
# MULTI-CYCLE PATHS — Clock-Enable-Gated Subsystems
#
# Raizing system clock: 96 MHz
#   MC68000 CPU : 96 MHz / 6 = 16 MHz  → 6-cycle multicycle
#   Z80 sound   : 96 MHz / 24 =  4 MHz → 24-cycle multicycle (use false path)
#   YM2151 FM   : very slow → false path
#   OKI M6295   : very slow → false path
#   GP9001      : 96 MHz / 12 CE → 12-cycle (use false path)
# =============================================================================

# MC68000 CPU — 96 MHz / 6 = 16 MHz (6-cycle multicycle)
set_multicycle_path -from [get_registers {*u_fx68k*}] -to [get_registers {*u_fx68k*}] -setup 6
set_multicycle_path -from [get_registers {*u_fx68k*}] -to [get_registers {*u_fx68k*}] -hold  5

# fx68k internal paths — span two phi phases (MANDATORY — COMMUNITY_PATTERNS.md Section 1.7)
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|microAddr[*]}]      6
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|microAddr[*]}]      5
set_multicycle_path -start -setup -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|nanoAddr[*]}]       6
set_multicycle_path -start -hold  -from [get_keepers {*|Ir[*]}]               -to [get_keepers {*|nanoAddr[*]}]       5
set_multicycle_path -start -setup -from [get_keepers {*|nanoLatch[*]}]        -to [get_keepers {*|alu|pswCcr[*]}]     6
set_multicycle_path -start -hold  -from [get_keepers {*|nanoLatch[*]}]        -to [get_keepers {*|alu|pswCcr[*]}]     5
set_multicycle_path -start -setup -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}]     6
set_multicycle_path -start -hold  -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|alu|pswCcr[*]}]     5

# T80 Z80 — required or synthesis fails timing
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -setup 24
set_multicycle_path -from [get_keepers {*|Z80CPU|*}] -hold 23

# Z80 sound CPU — 96 MHz / 24 = 4 MHz (false path — very slow)
set_false_path -from [get_registers {*u_z80*}] -to [get_registers {*u_z80*}]

# YM2151 FM (jt51) — very slow clock → false path
set_false_path -from [get_registers {*u_jt51*}] -to [get_registers {*u_jt51*}]

# OKI M6295 (jt6295) — very slow clock → false path
set_false_path -from [get_registers {*u_jt6295*}] -to [get_registers {*u_jt6295*}]

# GP9001 graphics chip — 96 MHz / 12 pixel CE
set_false_path -from [get_registers {*u_gp9001*}] -to [get_registers {*u_gp9001*}]

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
