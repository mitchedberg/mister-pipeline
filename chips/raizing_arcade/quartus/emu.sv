//============================================================================
//  Arcade: Raizing Arcade System (Battle Garegga)
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
// Raizing Arcade display parameters:
//   Primary target:    Battle Garegga (RA9503)
//   Native resolution: 320 × 240 (visible)
//   CPU clock:         16 MHz (MC68000, 96 MHz / 6 with two-phase CEN)
//   Pixel clock:       8 MHz (96 MHz / 12 CE)
//   Z80 clock:         4 MHz (96 MHz / 24 CE)
//   RGB output:        8 bits per channel (24-bit total) from R5G5B5 palette
//   Aspect ratio:      4:3
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — CPU program ROM (68K, SDRAM 0x000000, 1MB)
//   0x01 — GFX ROM (GP9001 tile + sprite data, SDRAM 0x100000, 8MB stub)
//   0x02 — Sound ROM (Z80 audio, BRAM in raizing_arcade, 128KB)
//   0x03 — OKI ADPCM ROM (SDRAM 0x920000 stub)
//   0x04 — Text tilemap ROM (stub)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB):
//   0x000000 – 0x0FFFFF   1MB    CPU program ROM (index 0)
//   0x100000 – 0x8FFFFF   8MB    GFX ROM (GP9001 tiles + sprites, index 1)
//   0x900000 – 0x91FFFF   128KB  Z80 audio ROM (index 2 → BRAM in core, not here)
//   0x920000 – 0xA1FFFF   1MB    OKI ADPCM ROM (index 3)
//   0xA20000 – 0xA27FFF   32KB   Text tilemap ROM (index 4)
//
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

// SDRAM_CLK is driven by the PLL (assign SDRAM_CLK = clk_sdram below).
// All other SDRAM signals are driven by sdram_b instantiated below.

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

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — Battle Garegga is 4:3
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
    "RaizingArcade;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "O[1:0],Lives,2,3,1,5;",
    "O[3:2],Difficulty,Easy,Normal,Hard,Hardest;",
    "-;",
    "T[0],Reset;",
    // Battle Garegga: 2 players, 3 buttons + start + coin
    "J1,Button 1,Button 2,Button 3,Start,Coin;",
    "jn,A,B,C,Start,Select;",
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
// Raizing system clock: 96 MHz (MC68000 @ 16 MHz via /6 CE two-phase).
// Pixel clock: 8 MHz (96 MHz / 12 CE).
// Z80 clock: 4 MHz (96 MHz / 24 CE).
// All dividers are generated inside raizing_arcade.sv.
//////////////////////////////////////////////////////////////////

wire clk_sys;       // 96 MHz — core system clock
wire clk_sdram;     // 133 MHz — SDRAM controller clock (phase-shifted)
wire pll_locked;

pll u_pll
(
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),    // 96 MHz
    .outclk_1 (clk_sdram),  // 133 MHz (phase-shifted for SDRAM setup/hold)
    .locked   (pll_locked)
);

// SDRAM clock pin driven directly from PLL output
assign SDRAM_CLK = clk_sdram;

//////////////////////////////////////////////////////////////////
// Reset
//
// Extend reset for 256 cycles after download completes to allow
// SDRAM to settle.
//////////////////////////////////////////////////////////////////
wire rom_download = ioctl_download;

logic [7:0] rst_extend;

always_ff @(posedge clk_sys) begin
    if (RESET | ~pll_locked | status[0] | buttons[1])
        rst_extend <= 8'hFF;
    else if (rom_download)
        rst_extend <= 8'hFF;
    else if (rst_extend != 8'h00)
        rst_extend <= rst_extend - 8'd1;
end

wire reset_n = (rst_extend == 8'h00);

//////////////////////////////////////////////////////////////////
// DIP switches (loaded by .mra at ioctl_index == 0xFE)
//////////////////////////////////////////////////////////////////
logic [7:0] dsw[4];
always_ff @(posedge clk_sys)
    if (ioctl_wr && (ioctl_index == 8'hFE) && !ioctl_addr[24:2])
        dsw[ioctl_addr[1:0]] <= ioctl_dout;

//////////////////////////////////////////////////////////////////
// Input mapping for Raizing shmup (Battle Garegga)
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1(fire) [5]=B2 [6]=B3 [7]=B4
//   [8]=Start [9]=Coin
//
// raizing_arcade expects joystick_0[9:0]:
//   [9:8]=coin/start, [5:0]=UDLRBA active-high
//////////////////////////////////////////////////////////////////
wire [9:0] joy_p1 = joystick_0[9:0];
wire [9:0] joy_p2 = joystick_1[9:0];

//////////////////////////////////////////////////////////////////
// ROM loading — sdram_b CH0 handles all ioctl writes to SDRAM.
// Index 0 (prog ROM) and others go directly into SDRAM via sdram_b.
// Index 2 (snd ROM) is handled by raizing_arcade internal BRAM;
// we still pass ioctl_wr/addr/dout to raizing_arcade for that path.
// ioctl_dout from hps_io is 8-bit; raizing_arcade expects 16-bit.
//////////////////////////////////////////////////////////////////
wire [15:0] ioctl_dout_16 = {ioctl_dout, ioctl_dout};
wire [24:0] ioctl_addr_25 = ioctl_addr[24:0];

// Video output from core
wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;
wire       core_ce_pixel;

// Audio output from core (signed 16-bit)
wire signed [15:0] snd_left_w, snd_right_w;

//////////////////////////////////////////////////////////////////
// SDRAM controller (sdram_b)
//
// CH0: ioctl ROM download writes (all indexes — sdram_b handles addr routing)
// CH1: CPU program ROM reads (raizing_arcade prog_rom_* toggle-handshake)
// CH2-4: unused stubs (tie req=0)
//////////////////////////////////////////////////////////////////

// prog_rom toggle-handshake wires
wire [26:0] prog_rom_addr_w;
wire        prog_rom_req_w;
wire [15:0] prog_rom_data_w;
wire        prog_rom_ack_w;

sdram_b u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .rst_n      (reset_n),

    // CH0: HPS ROM download write path
    .ioctl_wr   (ioctl_wr & ioctl_download),
    .ioctl_addr (ioctl_addr),
    .ioctl_dout (ioctl_dout),

    // CH1: CPU program ROM reads
    .cpu_addr   (prog_rom_addr_w),
    .cpu_data   (prog_rom_data_w),
    .cpu_req    (prog_rom_req_w),
    .cpu_ack    (prog_rom_ack_w),

    // CH2-4: unused (GFX/ADPCM/Z80 stubs — tie off)
    .gfx_addr   (27'h0),
    .gfx_req    (1'b0),
    .gfx_data   (),
    .gfx_ack    (),

    .adpcm_addr (27'h0),
    .adpcm_req  (1'b0),
    .adpcm_data (),
    .adpcm_ack  (),

    .z80_addr   (27'h0),
    .z80_req    (1'b0),
    .z80_data   (),
    .z80_ack    (),

    // SDRAM chip pins
    .SDRAM_A    (SDRAM_A),
    .SDRAM_BA   (SDRAM_BA),
    .SDRAM_DQ   (SDRAM_DQ),
    .SDRAM_DQM  ({SDRAM_DQMH, SDRAM_DQML}),
    .SDRAM_nCS  (SDRAM_nCS),
    .SDRAM_nCAS (SDRAM_nCAS),
    .SDRAM_nRAS (SDRAM_nRAS),
    .SDRAM_nWE  (SDRAM_nWE),
    .SDRAM_CKE  (SDRAM_CKE)
);

//////////////////////////////////////////////////////////////////
// Raizing Arcade core instantiation
//////////////////////////////////////////////////////////////////

raizing_arcade u_raizing
(
    .clk            (clk_sys),
    .rst_n          (reset_n),

    // ROM loading (ioctl_index 2 = snd ROM → BRAM inside raizing_arcade)
    .ioctl_wr       (ioctl_wr & ioctl_download),
    .ioctl_addr     (ioctl_addr_25),
    .ioctl_dout     (ioctl_dout_16),
    .ioctl_index    (ioctl_index),
    .ioctl_wait     (),            // unused — core never stalls HPS

    // Video output
    .red            (core_rgb_r),
    .green          (core_rgb_g),
    .blue           (core_rgb_b),
    .hsync_n        (core_hsync_n),
    .vsync_n        (core_vsync_n),
    .hblank         (core_hblank),
    .vblank         (core_vblank),
    .ce_pixel       (core_ce_pixel),

    // Audio output
    .audio_l        (snd_left_w),
    .audio_r        (snd_right_w),

    // Cabinet I/O
    .joystick_0     (joy_p1),
    .joystick_1     (joy_p2),
    .dipsw_a        (dsw[0]),
    .dipsw_b        (dsw[1]),

    // Program ROM SDRAM toggle-handshake (→ sdram_b CH1)
    .prog_rom_addr  (prog_rom_addr_w),
    .prog_rom_req   (prog_rom_req_w),
    .prog_rom_data  (prog_rom_data_w),
    .prog_rom_ack   (prog_rom_ack_w)
);

//////////////////////////////////////////////////////////////////
// Audio output
// snd_left/snd_right are signed 16-bit from YM2151 + OKI M6295 mixer.
// MiSTer AUDIO_L/R are unsigned 16-bit; add 0x8000 to flip sign bit.
//////////////////////////////////////////////////////////////////
assign AUDIO_L = snd_left_w  + 16'h8000;
assign AUDIO_R = snd_right_w + 16'h8000;

//////////////////////////////////////////////////////////////////
// Video pipeline
// arcade_video handles: sync-fix, colour expansion, scandoubler, gamma
//
// raizing_arcade outputs hsync_n / vsync_n (active-low).
// arcade_video expects active-high HSync/VSync convention.
// Native resolution: 320 × 240, 24-bit RGB.
//////////////////////////////////////////////////////////////////

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) u_arcade_video
(
    .clk_video  (clk_sys),
    .ce_pix     (core_ce_pixel),

    .RGB_in     ({core_rgb_r, core_rgb_g, core_rgb_b}),
    .HBlank     (core_hblank),
    .VBlank     (core_vblank),
    .HSync      (~core_hsync_n),   // arcade_video expects active-high
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
    dsw[2], dsw[3]
};
/* verilator lint_on UNUSED */

endmodule
