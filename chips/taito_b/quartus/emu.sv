//============================================================================
//  Arcade: Taito B System
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
// Taito B display parameters:
//   Primary target:    Nastar Warrior (rastsag2) / Rastan Saga II
//   Native resolution: 320 × 240 (visible), arcade timing from TC0180VCU
//   CPU clock:         8 MHz (32 MHz sys_clk / 4 clock-enable)
//   Pixel clock:       ~6.4 MHz (sys_clk / 5 CE, hardware is ~6.75 MHz)
//   RGB output:        8 bits per channel (24-bit total) from RGB444 palette
//   Aspect ratio:      4:3
//
// Key differences from Taito Z:
//   - Single MC68000 (not dual) — 16-bit CPU at 8 MHz
//   - TC0180VCU tilemap (same as Z)
//   - TC0220IOC I/O chip (not TC0510NIO)
//   - TC0140SYT sound comms (same as Z)
//   - TC0260DAR palette DAC (RGB444 mode)
//   - YM2610 audio (stubbed for now — silence)
//   - Simple SDRAM layout (no road ROM, no second CPU)
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — CPU prog ROM, Z80 ROM (sequential, SDRAM base 0)
//   0x01 — GFX ROM (TC0180VCU tile data, SDRAM 0x100000)
//   0x02 — ADPCM sample ROMs (YM2610, SDRAM 0x200000)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB, default nastar):
//   0x000000 – 0x07FFFF   512KB   CPU program ROM
//   0x080000 – 0x0FFFFF   512KB   Z80 audio program + padding
//   0x100000 – 0x1FFFFF     1MB   TC0180VCU GFX ROM
//   0x200000 – 0x27FFFF   512KB   ADPCM-A samples
//   0x280000 – 0x2FFFFF   512KB   ADPCM-B samples
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

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — Taito B is 4:3
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
    "TaitoB;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "O[1:0],Coin A,1C1P,2C1P,1C2P,1C3P;",
    "O[3:2],Lives,1,2,3,5;",
    "O[5:4],Difficulty,Easy,Normal,Hard,Hardest;",
    "-;",
    "T[0],Reset;",
    // Taito B action games: 2 joysticks + 3 buttons + start + coin
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
// Taito B system clock: 32 MHz (2× master, CPU at 8 MHz via /4 CE).
// TC0180VCU pixel clock: ~6.4 MHz (sys_clk / 5 CE).
//   Hardware pixel clock is ~6.75 MHz; /5 = 6.4 MHz (≈5% low, correct 15 kHz sync).
// SDRAM clock: 143 MHz (PLL outclk_1), phase-shifted for setup margin.
//////////////////////////////////////////////////////////////////

wire clk_sys;       // 32 MHz — core system clock
wire clk_sdram;     // 143.0 MHz — SDRAM interface clock
wire pll_locked;

pll u_pll
(
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),    // 32 MHz
    .outclk_1 (clk_sdram),  // 143.0 MHz
    .locked   (pll_locked)
);

// SDRAM clock pin driven from PLL (phase-shifted for setup/hold margin).
assign SDRAM_CLK = clk_sdram;

//////////////////////////////////////////////////////////////////
// Clock enables
//
// ce_cpu: /4 clock enable — 8 MHz effective CPU clock.
//   MC68000 uses ce_cpu when it is 1.
//
// ce_pix: independent /5 clock enable — ~6.4 MHz pixel clock.
//   Hardware TC0180VCU pixel clock is ~6.75 MHz; /5 from 32 MHz = 6.4 MHz.
//////////////////////////////////////////////////////////////////
logic [1:0] ce_cpu_cnt;
logic       ce_cpu;       // high one out of every 4 sys_clk cycles (32 MHz / 4 = 8 MHz)

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_cpu_cnt <= 2'd0;
        ce_cpu     <= 1'b0;
    end else begin
        ce_cpu_cnt <= ce_cpu_cnt + 2'd1;
        ce_cpu     <= (ce_cpu_cnt == 2'd3);
    end
end

// Pixel clock enable: independent /5 divider = ~6.4 MHz.
logic [2:0] ce_pix_cnt;
logic       ce_pix;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_pix_cnt <= 3'd0;
        ce_pix     <= 1'b0;
    end else begin
        if (ce_pix_cnt == 3'd4) begin
            ce_pix_cnt <= 3'd0;
            ce_pix     <= 1'b1;
        end else begin
            ce_pix_cnt <= ce_pix_cnt + 3'd1;
            ce_pix     <= 1'b0;
        end
    end
end

// Sound clock enable: 4 MHz (32 MHz / 8).
// The YM2610 and Z80 both run at 4 MHz on the Taito B hardware.
// We generate a clock-enable pulse every 8th clk_sys cycle.
logic [2:0] ce_snd_cnt;
logic ce_snd;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_snd_cnt <= 3'd0;
        ce_snd     <= 1'b0;
    end else begin
        ce_snd_cnt <= ce_snd_cnt + 3'd1;
        ce_snd     <= (ce_snd_cnt == 3'd7);
    end
end

//////////////////////////////////////////////////////////////////
// Reset
//
// Extend ROM-download reset for 256 cycles to allow SDRAM refresh
// to re-align after the last write.
//////////////////////////////////////////////////////////////////
wire rom_download = ioctl_download;

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
// Input mapping for Taito B action games
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1(Btn1) [5]=B2(Btn2) [6]=B3(Btn3) [7]=B4
//   [8]=Start [9]=Coin
//
// TC0220IOC expects active-low inputs (joystick_p1[7:0]):
//   [3:0] = UP/DOWN/LEFT/RIGHT (active-low directions)
//   [7:4] = BTN3/BTN2/BTN1/START (active-low)
//
// MiSTer CONF_STR "J1,Button 1,Button 2,Button 3,Start,Coin" assigns:
//   B1=[4] B2=[5] B3=[6] Start=[7] Coin=[8]
//   service (unmapped) at [9]
//////////////////////////////////////////////////////////////////
wire [7:0] joy_p1 = ~{ joystick_0[6], joystick_0[5], joystick_0[4], joystick_0[7],
                       joystick_0[3], joystick_0[2], joystick_0[1], joystick_0[0] };
wire [7:0] joy_p2 = ~{ joystick_1[6], joystick_1[5], joystick_1[4], joystick_1[7],
                       joystick_1[3], joystick_1[2], joystick_1[1], joystick_1[0] };

wire [1:0] coin    = ~{ joystick_1[8], joystick_0[8] };   // active-low
wire       service = ~joystick_0[9];                       // active-low

//////////////////////////////////////////////////////////////////
// SDRAM controller
//
// Provides three channels to the taito_b core:
//   cpu_*  — CPU program ROM reads (16-bit)
//   gfx_*  — TC0180VCU tile GFX ROM (16-bit)
//   adpcm_* — TC0140SYT ADPCM ROM (16-bit)
// Plus ioctl write path for ROM download.
//////////////////////////////////////////////////////////////////

wire [26:0] cpu_sdr_addr;
wire [15:0] cpu_sdr_data;
wire        cpu_sdr_req, cpu_sdr_ack;

wire [26:0] gfx_sdr_addr;
wire [15:0] gfx_sdr_data;
wire        gfx_sdr_req, gfx_sdr_ack;

wire [26:0] adpcm_sdr_addr;
wire [15:0] adpcm_sdr_data;
wire        adpcm_sdr_req, adpcm_sdr_ack;

wire [26:0] z80_sdr_addr;
wire [15:0] z80_sdr_data;
wire        z80_sdr_req, z80_sdr_ack;

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
    .cpu_addr   (cpu_sdr_addr),
    .cpu_data   (cpu_sdr_data),
    .cpu_req    (cpu_sdr_req),
    .cpu_ack    (cpu_sdr_ack),

    // CH2: GFX ROM reads
    .gfx_addr   (gfx_sdr_addr),
    .gfx_data   (gfx_sdr_data),
    .gfx_req    (gfx_sdr_req),
    .gfx_ack    (gfx_sdr_ack),

    // CH3: ADPCM ROM reads
    .adpcm_addr (adpcm_sdr_addr),
    .adpcm_data (adpcm_sdr_data),
    .adpcm_req  (adpcm_sdr_req),
    .adpcm_ack  (adpcm_sdr_ack),

    // CH4: Z80 ROM reads (SDRAM base word 0x040000 = byte 0x080000)
    .z80_addr   (z80_sdr_addr),
    .z80_data   (z80_sdr_data),
    .z80_req    (z80_sdr_req),
    .z80_ack    (z80_sdr_ack),

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
// Taito B core
//////////////////////////////////////////////////////////////////

// Video output from core
wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;

// Audio output from core (YM2610 via jt10)
wire signed [15:0] core_snd_left, core_snd_right;
assign AUDIO_L = core_snd_left;
assign AUDIO_R = core_snd_right;

//////////////////////////////////////////////////////////////////
// fx68k_adapter — MC68000 @ 8 MHz
//////////////////////////////////////////////////////////////////

wire [23:1] cpu_addr;
wire [15:0] cpu_din;     // taito_b → CPU (read data from bus)
wire [15:0] cpu_dout;    // CPU → taito_b (write data)
wire        cpu_rw;
wire        cpu_uds_n;
wire        cpu_lds_n;
wire        cpu_as_n;
wire        cpu_dtack_n; // taito_b → CPU
wire [2:0]  cpu_ipl_n;   // taito_b → CPU
wire        cpu_reset_n_out;

fx68k_adapter u_cpu (
    .clk            (clk_sys),
    .cpu_ce         (ce_cpu),
    .reset_n        (reset_n),

    .cpu_addr       (cpu_addr),
    .cpu_din        (cpu_din),
    .cpu_dout       (cpu_dout),
    .cpu_rw         (cpu_rw),
    .cpu_uds_n      (cpu_uds_n),
    .cpu_lds_n      (cpu_lds_n),
    .cpu_as_n       (cpu_as_n),
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),
    .cpu_reset_n_out(cpu_reset_n_out)
);

// Z80 debug bus outputs (all driven internally by T80s inside taito_b)
wire [15:0] z80_addr_dbg;
wire  [7:0] z80_din_dbg, z80_dout_dbg;
wire        z80_rd_n_dbg, z80_wr_n_dbg, z80_mreq_n_dbg, z80_iorq_n_dbg;
wire        z80_int_n_dbg;
wire        z80_rom_cs0_n_dbg, z80_rom_cs1_n_dbg, z80_ram_cs_n_dbg;
wire        z80_rom_a14_dbg, z80_rom_a15_dbg, z80_opx_n_dbg, z80_reset_n_dbg;

taito_b u_taito_b
(
    .clk_sys    (clk_sys),
    .clk_pix    (ce_pix),
    .clk_pix2x  (1'b1),    // dummy: TC0260DAR ce_double (not used in Taito B)
    .reset_n    (reset_n),
    .clk_sound  (ce_snd),   // ~4 MHz clock enable for YM2610 + Z80

    // ── CPU bus ──────────────────────────────────────────────────────────────
    .cpu_addr    (cpu_addr),
    .cpu_din     (cpu_dout),    // CPU write data → taito_b
    .cpu_dout    (cpu_din),     // taito_b read data → CPU
    .cpu_lds_n   (cpu_lds_n),
    .cpu_uds_n   (cpu_uds_n),
    .cpu_rw      (cpu_rw),
    .cpu_as_n    (cpu_as_n),
    .cpu_dtack_n (cpu_dtack_n),
    .cpu_ipl_n   (cpu_ipl_n),

    // ── Z80 Sound CPU (now internal T80s; ports are debug outputs) ────────────
    .z80_addr      (z80_addr_dbg),
    .z80_din       (z80_din_dbg),
    .z80_dout      (z80_dout_dbg),
    .z80_rd_n      (z80_rd_n_dbg),
    .z80_wr_n      (z80_wr_n_dbg),
    .z80_mreq_n    (z80_mreq_n_dbg),
    .z80_iorq_n    (z80_iorq_n_dbg),
    .z80_int_n     (z80_int_n_dbg),
    .z80_rom_cs0_n (z80_rom_cs0_n_dbg),
    .z80_rom_cs1_n (z80_rom_cs1_n_dbg),
    .z80_ram_cs_n  (z80_ram_cs_n_dbg),
    .z80_rom_a14   (z80_rom_a14_dbg),
    .z80_rom_a15   (z80_rom_a15_dbg),
    .z80_opx_n     (z80_opx_n_dbg),
    .z80_reset_n   (z80_reset_n_dbg),

    // ── Audio output (YM2610 via jt10) ───────────────────────────────────────
    .snd_left    (core_snd_left),
    .snd_right   (core_snd_right),

    // ── CPU Program ROM SDRAM (CH1) ───────────────────────────────────────────
    .prog_rom_addr (cpu_sdr_addr),
    .prog_rom_data (cpu_sdr_data),
    .prog_rom_req  (cpu_sdr_req),
    .prog_rom_ack  (cpu_sdr_ack),

    // ── GFX ROM (TC0180VCU) ──────────────────────────────────────────────────
    .gfx_rom_addr (gfx_sdr_addr),
    .gfx_rom_data (gfx_sdr_data),
    .gfx_rom_req  (gfx_sdr_req),
    .gfx_rom_ack  (gfx_sdr_ack),

    // ── SDRAM (TC0140SYT ADPCM) ──────────────────────────────────────────────
    .sdr_addr    (adpcm_sdr_addr),
    .sdr_data    (adpcm_sdr_data),
    .sdr_req     (adpcm_sdr_req),
    .sdr_ack     (adpcm_sdr_ack),

    // ── Z80 ROM SDRAM (CH4) ───────────────────────────────────────────────────
    .z80_rom_addr (z80_sdr_addr),
    .z80_rom_data (z80_sdr_data),
    .z80_rom_req  (z80_sdr_req),
    .z80_rom_ack  (z80_sdr_ack),

    // ── Video output ──────────────────────────────────────────────────────────
    .rgb_r       (core_rgb_r),
    .rgb_g       (core_rgb_g),
    .rgb_b       (core_rgb_b),
    .hsync_n     (core_hsync_n),
    .vsync_n     (core_vsync_n),
    .hblank      (core_hblank),
    .vblank      (core_vblank),

    // ── Video timing (standard 320×240 arcade) ────────────────────────────────
    // Placeholder: real timing generator would drive these
    .hblank_n_in (1'b1),    // no blank
    .vblank_n_in (1'b1),
    .hpos        (9'h000),
    .vpos        (8'h00),
    .hsync_n_in  (1'b1),
    .vsync_n_in  (1'b1),

    // ── Player inputs ─────────────────────────────────────────────────────────
    .joystick_p1 (joy_p1),
    .joystick_p2 (joy_p2),
    .coin        (coin),
    .service     (service),
    .dipsw1      (dsw[0]),
    .dipsw2      (dsw[1])
);

//////////////////////////////////////////////////////////////////
// Video pipeline
// arcade_video handles: sync-fix, colour expansion, scandoubler, gamma
//
// taito_b outputs hsync_n / vsync_n (active-low).
// arcade_video expects active-high HSync/VSync convention.
// Taito B native resolution: 320 × 240, 24-bit RGB from palette BRAM.
//////////////////////////////////////////////////////////////////

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) u_arcade_video
(
    .clk_video  (clk_sys),
    .ce_pix     (ce_pix),

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
    joystick_0[31:10], joystick_1[31:9],
    dsw[2], dsw[3],
    cpu_reset_n_out,       // CPU RESET instruction output (not used at top level)
    // Z80 debug bus outputs (informational only)
    z80_addr_dbg, z80_din_dbg, z80_dout_dbg,
    z80_rd_n_dbg, z80_wr_n_dbg, z80_mreq_n_dbg, z80_iorq_n_dbg, z80_int_n_dbg,
    z80_rom_cs0_n_dbg, z80_rom_cs1_n_dbg, z80_ram_cs_n_dbg,
    z80_rom_a14_dbg, z80_rom_a15_dbg, z80_opx_n_dbg, z80_reset_n_dbg
};
/* verilator lint_on UNUSED */

endmodule
