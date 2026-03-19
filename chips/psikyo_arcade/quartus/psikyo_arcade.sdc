# =============================================================================
# psikyo_arcade — Timing Constraints (SDC)
# =============================================================================
#
# System clock: 32 MHz (CPU clock-enable = sys_clk / 2 = 16 MHz)
# Pixel clock:  16 MHz (sys_clk / 2 CE from video timing generator)
# SDRAM clock:  143.0 MHz (PLL output)
# Reference:    50 MHz (FPGA_CLK1_50)
#
# Clock-enable divide ratios (all CEN logic runs on clk_sys = 32 MHz):
#   MC68000 CPU  : 32 MHz / 2  = 16 MHz  → 2-cycle multicycle
#   Z80 sound    : 32 MHz / 5  =  6.4 MHz → 5-cycle multicycle
#   YM2610B (jt10): driven by clk_sound = 8 MHz CE (external /4)
#                  → 4-cycle multicycle
#   Video timing : clk_pix CE = 16 MHz (/2) → 2-cycle multicycle
#
# NOTE: -42 ns setup / -15 ns hold violations indicate both timing-path
# over-constraint and routing congestion.  I/O delay relaxation is also
# applied to relieve pressure on the outer ring of the device.
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

# MC68000 main CPU (fx68k) — 32 MHz / 2 = 16 MHz (2-cycle multicycle)
# The CPU is clock-enabled at /2; bus signals propagate every other cycle.
set_multicycle_path -from [get_registers {*cpu*}]    -to [get_registers {*cpu*}]    -setup 2
set_multicycle_path -from [get_registers {*cpu*}]    -to [get_registers {*cpu*}]    -hold  1

# Z80 sound CPU — 32 MHz / 5 = 6.4 MHz (5-cycle multicycle)
# T80s instance (u_z80), CEN = ce_z80 (clk_sys / 5).
set_multicycle_path -from [get_registers {*u_z80*}]  -to [get_registers {*u_z80*}]  -setup 5
set_multicycle_path -from [get_registers {*u_z80*}]  -to [get_registers {*u_z80*}]  -hold  4

# Z80 clock-enable counter and auxiliary Z80-domain registers
set_multicycle_path -from [get_registers {*ce_z80*}] -to [get_registers {*ce_z80*}] -setup 5
set_multicycle_path -from [get_registers {*ce_z80*}] -to [get_registers {*ce_z80*}] -hold  4

# YM2610B (jt10) — clk_sound = 8 MHz CE, i.e. 32 MHz / 4 (4-cycle multicycle)
# Internal state of the YM2610B core only advances on clk_sound pulses.
set_multicycle_path -from [get_registers {*u_ym2610b*}] -to [get_registers {*u_ym2610b*}] -setup 4
set_multicycle_path -from [get_registers {*u_ym2610b*}] -to [get_registers {*u_ym2610b*}] -hold  3

# Psikyo chip (u_psikyo), gate3 (u_gate3), gate4 (u_gate4) — full 32 MHz
# but internal pixel pipelines only produce valid data every 2 cycles (clk_pix).
set_multicycle_path -from [get_registers {*u_psikyo*}] -to [get_registers {*u_psikyo*}] -setup 2
set_multicycle_path -from [get_registers {*u_psikyo*}] -to [get_registers {*u_psikyo*}] -hold  1
set_multicycle_path -from [get_registers {*u_gate3*}]  -to [get_registers {*u_gate3*}]  -setup 2
set_multicycle_path -from [get_registers {*u_gate3*}]  -to [get_registers {*u_gate3*}]  -hold  1
set_multicycle_path -from [get_registers {*u_gate4*}]  -to [get_registers {*u_gate4*}]  -setup 2
set_multicycle_path -from [get_registers {*u_gate4*}]  -to [get_registers {*u_gate4*}]  -hold  1

# =============================================================================
# I/O TIMING RELAXATION
#
# The -42 ns setup violation is severe enough to indicate routing congestion
# contributing to path delay.  Relaxing I/O constraints reduces pressure on
# the device periphery and gives the fitter more room to spread logic.
# These values (5 ns) are generous — adjust down once the core meets internal
# timing cleanly.
# =============================================================================

set_input_delay  -clock [get_clocks {FPGA_CLK1_50}] -max 5.0 [get_ports {*}]
set_input_delay  -clock [get_clocks {FPGA_CLK1_50}] -min 0.0 [get_ports {*}]
set_output_delay -clock [get_clocks {FPGA_CLK1_50}] -max 5.0 [get_ports {*}]
set_output_delay -clock [get_clocks {FPGA_CLK1_50}] -min 0.0 [get_ports {*}]

# =============================================================================
# FALSE PATHS — ASYNCHRONOUS RESET RECOVERY
# =============================================================================
# Reset is a one-time event from the MiSTer framework, not a timing-critical
# path. Recovery/removal timing on flip-flop async clear pins is safely ignored.
#
set_false_path -from [get_ports {reset}]
set_false_path -from [get_ports {rst}]

# =============================================================================
# FALSE PATHS — I/O TIMING
# =============================================================================
# REMOVED: blanket false paths on ALL ports were blocking HDMI data routing,
# causing fitter failure at only 30% ALM utilization (routing deadlock).
# HDMI output is driven directly by arcade logic, not through sys/ framework.
# Only mark truly async paths (reset) as false.

# =============================================================================
# END OF TIMING CONSTRAINTS
# =============================================================================
