//============================================================================
//  Arcade: Taito F3
//
//  MiSTer emu top-level wrapper
//  Copyright (C) 2024
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

// -------------------------------------------------------------------------
// Taito F3 display parameters:
//   Native resolution: 320 × 232 (visible), ~512 × 262 pixel clock grid
//   System XTAL:      ~53.372 MHz (PLL outclk_0)
//   Pixel clock:      ~26.686 MHz (sys_clk / 2, generated as CE_PIXEL)
//   Refresh:          ~59.94 Hz
//   RGB output:       8 bits per channel (24-bit total) from TC0650FDA
//   Aspect ratio:     4:3
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — 68EC020 program ROM (interleaved, loaded to SDRAM 0x000000)
//   0x01 — GFX ROMs (sprite+tile data, packed per MRA, loaded to SDRAM 0x200000+)
//   0x02 — Sound CPU + Ensoniq sample ROMs (loaded to SDRAM 0x1400000+)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB):
//   0x0000000 – 0x01FFFFF  2 MB   68EC020 prog ROM
//   0x0200000 – 0x09FFFFF  8 MB   Sprite GFX lo (spr_lo)
//   0x0A00000 – 0x0DFFFFF  4 MB   Sprite GFX hi (spr_hi)
//   0x0E00000 – 0x11FFFFF  4 MB   Tilemap GFX lo (til_lo)
//   0x1200000 – 0x13FFFFF  2 MB   Tilemap GFX hi (til_hi)
//   0x1400000 – 0x157FFFF  1.5MB  Sound CPU prog ROM
//   0x1600000 – 0x1DFFFFF  8 MB   Ensoniq sample ROMs
// -------------------------------------------------------------------------

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

//////////////////////////////////////////////////////////////////
// Tie off unused ports
//////////////////////////////////////////////////////////////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = '0;
assign {SD_SCK, SD_MOSI, SD_CS}       = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1         = 1'b0;
assign VGA_SCALER     = 1'b0;
assign VGA_DISABLE    = 1'b0;
assign HDMI_FREEZE    = 1'b0;
assign HDMI_BLACKOUT  = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;

assign AUDIO_S   = 1'b1;    // signed samples
assign AUDIO_MIX = 2'd0;    // no mix

assign LED_DISK  = 2'd0;
assign LED_POWER = 2'd0;
assign BUTTONS   = 2'd0;

// Audio: silence until Taito EN sound module is implemented
assign AUDIO_L = 16'h0;
assign AUDIO_R = 16'h0;

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — Taito F3 is 4:3
// status[122:121]: 00=original 4:3, 01=fullscreen, 10=ARC1, 11=ARC2
//////////////////////////////////////////////////////////////////
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 13'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 13'd3 : 13'd0;

//////////////////////////////////////////////////////////////////
// OSD / HPS configuration string
//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"TaitoF3;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"DIP;",
	"R[0],Reset;",
	"J1,Button1,Button2,Button3,Button4,Button5,Button6,Start,Coin;",
	"jn,A,B,X,Y,L,R,Start,Select;",
	"V,v",`BUILD_DATE
};

//////////////////////////////////////////////////////////////////
// HPS I/O
//////////////////////////////////////////////////////////////////

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire  [21:0] gamma_bus;
wire         direct_video;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;

wire [31:0] joystick_0, joystick_1;

hps_io #(.CONF_STR(CONF_STR)) u_hps_io
(
	.clk_sys        (clk_sys),
	.HPS_BUS        (HPS_BUS),

	.buttons        (buttons),
	.status         (status),
	.forced_scandoubler (forced_scandoubler),
	.gamma_bus      (gamma_bus),
	.direct_video   (direct_video),
	.video_rotated  (1'b0),

	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_index    (ioctl_index),

	.joystick_0     (joystick_0),
	.joystick_1     (joystick_1)
);

//////////////////////////////////////////////////////////////////
// Clocks
//
// Taito F3 system clock: 53.372 MHz (2× pixel clock of 26.686 MHz).
// pll.sv generates clk_sys from CLK_50M.
// SDRAM clock is deliberately offset from clk_sys (via PLL phase shift
// of ~180°) so that SDRAM output data is stable when sampled on clk_sys.
// In simulation the stub PLL uses the same clock for both — acceptable.
//////////////////////////////////////////////////////////////////

wire clk_sys;       // 53.372 MHz — core system clock
wire clk_sdram;     // 143.0 MHz  — SDRAM interface clock (from PLL outclk_1)
wire pll_locked;

pll u_pll
(
	.refclk   (CLK_50M),
	.rst      (1'b0),
	.outclk_0 (clk_sys),    // 53.372 MHz
	.outclk_1 (clk_sdram),  // 143.0  MHz
	.locked   (pll_locked)
);

// SDRAM clock pin: driven from PLL (phase-shifted for setup/hold margin).
// Using clk_sdram here; in real Quartus, add SDC constraint SDRAM_CLK offset.
assign SDRAM_CLK = clk_sdram;

//////////////////////////////////////////////////////////////////
// Pixel clock enable: clk_sys ÷ 2 = ~26.686 MHz
// Taito F3 internal pixel clock = sys_clk / 2.
// The taito_f3 module receives clk_pix as a clock-enable (1-cycle pulse).
//////////////////////////////////////////////////////////////////
logic ce_pix;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        ce_pix <= 1'b0;
    else
        ce_pix <= ~ce_pix;
end

//////////////////////////////////////////////////////////////////
// Reset
//
// Extend ROM-download reset for 256 cycles to allow SDRAM refresh
// to re-align after the last write.
//////////////////////////////////////////////////////////////////
wire rom_download = ioctl_download && (ioctl_index == 8'h00);

logic [7:0] rst_extend;
wire  reset_n;

always_ff @(posedge clk_sys) begin
    if (RESET | ~pll_locked | status[0] | buttons[1])
        rst_extend <= 8'hFF;
    else if (rom_download)
        rst_extend <= 8'hFF;
    else if (rst_extend != 8'h00)
        rst_extend <= rst_extend - 8'd1;
end

assign reset_n = (rst_extend == 8'h00);

//////////////////////////////////////////////////////////////////
// DIP switches (loaded by .mra at ioctl_index == 0xFE)
//////////////////////////////////////////////////////////////////
logic [7:0] dsw[4];
always_ff @(posedge clk_sys)
    if (ioctl_wr && (ioctl_index == 8'hFE) && !ioctl_addr[24:2])
        dsw[ioctl_addr[1:0]] <= ioctl_dout;

//////////////////////////////////////////////////////////////////
// Input mapping
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1 [5]=B2 [6]=B3 [7]=B4 [8]=B5 [9]=B6
//   [8]=Start [9]=Coin  (for arcade cores — depends on .mra J1 mapping)
// taito_f3.sv expects active-low inputs.
//
// joystick_p1[7:0] layout for TC0640FIO:
//   [3:0] = UP/DOWN/LEFT/RIGHT (active-low directions)
//   [7:4] = buttons [3:0]      (active-low)
//////////////////////////////////////////////////////////////////
wire [7:0] joy_p1 = ~{ joystick_0[7], joystick_0[6], joystick_0[5], joystick_0[4],
                       joystick_0[3], joystick_0[2], joystick_0[1], joystick_0[0] };
wire [7:0] joy_p2 = ~{ joystick_1[7], joystick_1[6], joystick_1[5], joystick_1[4],
                       joystick_1[3], joystick_1[2], joystick_1[1], joystick_1[0] };

wire [1:0] coin    = ~{ joystick_1[9], joystick_0[9] };   // active-low
wire       service = ~joystick_0[10];                      // active-low

//////////////////////////////////////////////////////////////////
// SDRAM controller
//
// Instantiated in emu.sv so it controls the physical SDRAM pins.
// Provides three channels to taito_f3 core:
//   sdr_*  — 32-bit program ROM reads
//   gfx_a_* — 16-bit GFX port A (spr_lo + til_lo)
//   gfx_b_* — 16-bit GFX port B (spr_hi + til_hi)
// Plus write port for ioctl ROM loading.
//////////////////////////////////////////////////////////////////

// SDRAM read channels (to taito_f3)
wire [26:0] sdr_addr;
wire [31:0] sdr_data;
wire        sdr_req, sdr_ack;

wire [26:0] gfx_a_addr;
wire [15:0] gfx_a_data;
wire        gfx_a_req, gfx_a_ack;

wire [26:0] gfx_b_addr;
wire [15:0] gfx_b_data;
wire        gfx_b_req, gfx_b_ack;

sdram_f3 u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .reset_n    (reset_n),

    // CH0: HPS ROM download write path
    .ioctl_wr   (ioctl_wr & ioctl_download),
    .ioctl_addr (ioctl_addr),
    .ioctl_dout (ioctl_dout),

    // CH1: 68EC020 program ROM reads
    .sdr_addr   (sdr_addr),
    .sdr_data   (sdr_data),
    .sdr_req    (sdr_req),
    .sdr_ack    (sdr_ack),

    // CH2: GFX port A
    .gfx_a_addr (gfx_a_addr),
    .gfx_a_data (gfx_a_data),
    .gfx_a_req  (gfx_a_req),
    .gfx_a_ack  (gfx_a_ack),

    // CH3: GFX port B
    .gfx_b_addr (gfx_b_addr),
    .gfx_b_data (gfx_b_data),
    .gfx_b_req  (gfx_b_req),
    .gfx_b_ack  (gfx_b_ack),

    // SDRAM chip pins
    .SDRAM_A    (SDRAM_A),
    .SDRAM_BA   (SDRAM_BA),
    .SDRAM_DQ   (SDRAM_DQ),
    .SDRAM_DQML (SDRAM_DQML),
    .SDRAM_DQMH (SDRAM_DQMH),
    .SDRAM_nCS  (SDRAM_nCS),
    .SDRAM_nCAS (SDRAM_nCAS),
    .SDRAM_nRAS (SDRAM_nRAS),
    .SDRAM_nWE  (SDRAM_nWE),
    .SDRAM_CKE  (SDRAM_CKE)
);

//////////////////////////////////////////////////////////////////
// Taito F3 core
//////////////////////////////////////////////////////////////////

// Video output from core
wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;

// Sound CPU stub — tie off, silence
// These ports are required by taito_f3 but the Taito EN sound module
// is not yet implemented.  Drive benign defaults so the core compiles.
wire [15:0] snd_addr_stub  = 16'h0;
wire [15:0] snd_din_stub   = 16'h0;
wire        snd_rw_stub    = 1'b1;    // read (no writes from stub)
wire        snd_as_n_stub  = 1'b1;   // always deasserted
wire [15:0] snd_dout_stub;            // read back (ignored)
wire        snd_dtack_n_stub;
wire        snd_reset_n_stub;

/* verilator lint_off UNUSED */
wire [15:0] _snd_dout    = snd_dout_stub;
wire        _snd_dtack_n = snd_dtack_n_stub;
wire        _snd_reset_n = snd_reset_n_stub;
/* verilator lint_on UNUSED */

taito_f3 u_taito_f3
(
    .clk_sys    (clk_sys),
    .clk_pix    (ce_pix),
    .reset_n    (reset_n),

    // Sound CPU bus (stub)
    .snd_addr   (snd_addr_stub),
    .snd_din    (snd_din_stub),
    .snd_dout   (snd_dout_stub),
    .snd_rw     (snd_rw_stub),
    .snd_as_n   (snd_as_n_stub),
    .snd_dtack_n(snd_dtack_n_stub),
    .snd_reset_n(snd_reset_n_stub),

    // GFX ROM port A (spr_lo + til_lo via arbiter)
    .gfx_a_addr (gfx_a_addr),
    .gfx_a_data (gfx_a_data),
    .gfx_a_req  (gfx_a_req),
    .gfx_a_ack  (gfx_a_ack),

    // GFX ROM port B (spr_hi + til_hi via arbiter)
    .gfx_b_addr (gfx_b_addr),
    .gfx_b_data (gfx_b_data),
    .gfx_b_req  (gfx_b_req),
    .gfx_b_ack  (gfx_b_ack),

    // Program ROM (68EC020)
    .sdr_addr   (sdr_addr),
    .sdr_data   (sdr_data),
    .sdr_req    (sdr_req),
    .sdr_ack    (sdr_ack),

    // Video
    .rgb_r      (core_rgb_r),
    .rgb_g      (core_rgb_g),
    .rgb_b      (core_rgb_b),
    .hsync_n    (core_hsync_n),
    .vsync_n    (core_vsync_n),
    .hblank     (core_hblank),
    .vblank     (core_vblank),

    // Player inputs (active-low, bit layout per TC0640FIO)
    .joystick_p1 (joy_p1),
    .joystick_p2 (joy_p2),
    .coin        (coin),
    .service     (service)
);

//////////////////////////////////////////////////////////////////
// Video pipeline
// arcade_video handles: sync-fix, colour expansion, scandoubler, gamma
//
// taito_f3 outputs hsync_n / vsync_n (active-low).
// arcade_video expects HSync/VSync with the same polarity convention
// as the core; the sync_fix inside arcade_video normalises them.
//////////////////////////////////////////////////////////////////

arcade_video #(.WIDTH(320), .HEIGHT(232), .DW(24), .GAMMA(1)) u_arcade_video
(
    .clk_video  (clk_sys),
    .ce_pix     (ce_pix),

    .RGB_in     ({core_rgb_r, core_rgb_g, core_rgb_b}),
    .HBlank     (core_hblank),
    .VBlank     (core_vblank),
    .HSync      (~core_hsync_n),   // arcade_video expects active-high convention
    .VSync      (~core_vsync_n),

    .CLK_VIDEO  (CLK_VIDEO),
    .CE_PIXEL   (CE_PIXEL),
    .VGA_R      (VGA_R),
    .VGA_G      (VGA_G),
    .VGA_B      (VGA_B),
    .VGA_HS     (VGA_HS),
    .VGA_VS     (VGA_VS),
    .VGA_DE     (VGA_DE),
    .VGA_SL     (VGA_SL),

    .fx                 (status[5:3]),
    .forced_scandoubler (forced_scandoubler),
    .gamma_bus          (gamma_bus)
);

//////////////////////////////////////////////////////////////////
// Unused input suppression
//////////////////////////////////////////////////////////////////
/* verilator lint_off UNUSED */
wire _unused = &{
    1'b0,
    CLK_AUDIO,
    HDMI_WIDTH, HDMI_HEIGHT,
    SD_MISO, SD_CD,
    DDRAM_BUSY, DDRAM_DOUT, DDRAM_DOUT_READY,
    UART_CTS, UART_RXD, UART_DSR,
    USER_IN,
    OSD_STATUS,
    direct_video,
    joystick_0[31:10], joystick_1[31:10],
    dsw[0], dsw[1], dsw[2], dsw[3]
};
/* verilator lint_on UNUSED */

endmodule
