//============================================================================
//  Arcade: Kaneko16 System (Berlin Wall / Shogun Warriors)
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
// Kaneko16 display parameters:
//   Primary target:    The Berlin Wall (berlwall)
//   Native resolution: 256 × 224 (visible)
//   CPU clock:         16 MHz (32 MHz sys_clk / 2 clock-enable)
//   Pixel clock:       ~6.4 MHz (sys_clk / 5 CE, hardware is ~6 MHz)
//   RGB output:        8 bits per channel (from RGB555 palette, expanded)
//   Aspect ratio:      4:3
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — CPU prog ROM (SDRAM base 0x000000)
//   0x01 — GFX ROM: sprites + BG tiles (SDRAM base 0x100000)
//   0x02 — Z80 sound ROM (SDRAM base 0x300000)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB):
//   0x000000 – 0x0FFFFF   1MB    CPU program ROM (Berlin Wall)
//   0x100000 – 0x2FFFFF   2MB    GFX ROM (sprites + BG tiles)
//   0x300000 – 0x307FFF   32KB   Z80 sound ROM
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

// Audio outputs driven from kaneko_arcade sound mix (wired below)
// AUDIO_S = 1 (signed samples) is already set above.

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — Kaneko16 is 4:3
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
    "Kaneko16;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "O[1:0],Difficulty,Easy,Normal,Hard,Hard;",
    "O[3:2],Lives,1,2,3,3;",
    "-;",
    "T[0],Reset;",
    // Kaneko16 action games: 2 joysticks + 3 buttons + start + coin
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
// Kaneko16 system clock: 32 MHz (CPU at 16 MHz via /2 CE).
// Pixel clock: ~6.4 MHz (sys_clk / 5 CE, hardware is ~6 MHz).
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
// ce_cpu: /2 clock enable — 16 MHz effective CPU clock.
//   MC68000 uses ce_cpu when it is 1 (even phases).
//
// ce_pix: independent /5 clock enable — ~6.4 MHz pixel clock.
//   Kaneko16 hardware pixel clock is ~6 MHz; /5 from 32 MHz = 6.4 MHz (≈7% high).
//////////////////////////////////////////////////////////////////
logic ce_cpu;   // toggle, high every 2nd cycle = 16 MHz

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        ce_cpu <= 1'b0;
    else
        ce_cpu <= ~ce_cpu;
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

//////////////////////////////////////////////////////////////////
// Sound clock enable — ~1 MHz (32 MHz / 32)
//
// OKI M6295 clock input is 1.056 MHz on original Kaneko16 hardware.
// We approximate with 32 MHz / 32 = 1 MHz (0.05% error, imperceptible).
//////////////////////////////////////////////////////////////////
logic [4:0] snd_ce_div;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) snd_ce_div <= 5'd0;
    else          snd_ce_div <= snd_ce_div + 5'd1;
end

wire clk_sound_cen = (snd_ce_div == 5'd0);   // 1 pulse per 32 sys_clk cycles ≈ 1 MHz

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
// Input mapping for Kaneko16 action games
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1(Btn1) [5]=B2(Btn2) [6]=B3(Btn3) [7]=B4
//   [8]=Start [9]=Coin
//
// kaneko_arcade I/O expects active-low inputs:
//   [7]=BTN3 [6]=BTN2 [5]=BTN1 [4]=START [3]=RIGHT [2]=LEFT [1]=DOWN [0]=UP
//
// MiSTer CONF_STR "J1,Button 1,Button 2,Button 3,Start,Coin" assigns:
//   B1=[4] B2=[5] B3=[6] Start=[7] Coin=[8]
//   service (unmapped) at [9]
//////////////////////////////////////////////////////////////////
wire [7:0] joy_p1 = ~{ joystick_0[6], joystick_0[5], joystick_0[4], joystick_0[7],
                       joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3] };
wire [7:0] joy_p2 = ~{ joystick_1[6], joystick_1[5], joystick_1[4], joystick_1[7],
                       joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3] };

wire [1:0] coin    = ~{ joystick_1[8], joystick_0[8] };   // active-low
wire       service = ~joystick_0[9];                       // active-low

//////////////////////////////////////////////////////////////////
// SDRAM controller
//
// Provides three channels to the kaneko_arcade core:
//   cpu_*  — CPU program ROM reads (16-bit)
//   gfx_*  — GFX ROM (sprite + BG tiles, 32-bit)
// Plus ioctl write path for ROM download.
//////////////////////////////////////////////////////////////////

wire [26:0] cpu_sdr_addr;
wire [15:0] cpu_sdr_data;
wire        cpu_sdr_req, cpu_sdr_ack;

// GFX ROM channel — core-side (32-bit, toggle-handshake)
wire [26:0] gfx_sdr_addr;
wire [31:0] gfx_sdr_data;
wire        gfx_sdr_req, gfx_sdr_ack;

// GFX ROM channel — SDRAM-side (16-bit, toggle-handshake; driven by 2-beat FSM below)
logic [26:0] gfx2_sdram_addr;
logic        gfx2_sdram_req;
wire  [15:0] gfx2_sdram_data;
wire         gfx2_sdram_ack;

// ADPCM ROM: kaneko_arcade delivers byte addr;
// SDRAM returns 16-bit word; core takes byte selected by addr[0].
wire [23:0] adpcm_rom_addr_w;
wire        adpcm_rom_req_w, adpcm_rom_ack_w;
wire [15:0] adpcm_sdr_data_w;
wire  [7:0] adpcm_rom_data_w = adpcm_rom_addr_w[0]
                                ? adpcm_sdr_data_w[15:8]
                                : adpcm_sdr_data_w[7:0];

// Z80 ROM wires (share CH3 with ADPCM via arbiter below)
wire [15:0] z80_rom_addr_w;
wire        z80_sdr_req_w, z80_sdr_ack_w;
wire [15:0] z80_sdr_data_w;
wire  [7:0] z80_sdr_byte_w = z80_rom_addr_w[0]
                               ? z80_sdr_data_w[15:8]
                               : z80_sdr_data_w[7:0];

//----------------------------------------------------------------
// CH3 arbiter: ADPCM and Z80 ROM share adpcm channel.
// ADPCM has priority (time-critical for audio samples).
//   owner: 0=ADPCM, 1=Z80
//----------------------------------------------------------------
wire [26:0] ch3_addr;
wire        ch3_req;
wire [15:0] ch3_data_out;
wire        ch3_ack;

logic ch3_owner;
logic ch3_busy;

wire adpcm_pend = (adpcm_rom_req_w != adpcm_rom_ack_w);
wire z80_pend   = (z80_sdr_req_w   != z80_sdr_ack_w);

logic ch3_req_r;
logic [26:0] ch3_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ch3_req_r  <= 1'b0;
        ch3_addr_r <= 27'b0;
        ch3_owner  <= 1'b0;
        ch3_busy   <= 1'b0;
    end else begin
        if (!ch3_busy) begin
            if (adpcm_pend) begin
                ch3_addr_r <= {3'b0, adpcm_rom_addr_w};
                ch3_req_r  <= ~ch3_req_r;
                ch3_owner  <= 1'b0;
                ch3_busy   <= 1'b1;
            end else if (z80_pend) begin
                // Z80 ROM at SDRAM 0x300000
                ch3_addr_r <= 27'h300000 + {11'b0, z80_rom_addr_w[15:1]};
                ch3_req_r  <= ~ch3_req_r;
                ch3_owner  <= 1'b1;
                ch3_busy   <= 1'b1;
            end
        end else begin
            if (ch3_req_r == ch3_ack)
                ch3_busy <= 1'b0;
        end
    end
end

assign ch3_addr = ch3_addr_r;
assign ch3_req  = ch3_req_r;

// Route ack back to winning client
assign adpcm_rom_ack_w = (ch3_owner == 1'b0) ? ch3_ack : adpcm_rom_req_w;
assign z80_sdr_ack_w   = (ch3_owner == 1'b1) ? ch3_ack : z80_sdr_req_w;

assign adpcm_sdr_data_w = ch3_data_out;
assign z80_sdr_data_w   = ch3_data_out;

// ROM index → SDRAM base address routing (ioctl_addr resets to 0 per index)
reg [26:0] rom_base_addr;
always_comb begin
    case (ioctl_index)
        8'h00: rom_base_addr = 27'h000000; // CPU prog ROM
        8'h01: rom_base_addr = 27'h100000; // GFX ROM (sprites + BG tiles)
        8'h02: rom_base_addr = 27'h300000; // Z80 sound ROM
        default: rom_base_addr = 27'h000000;
    endcase
end
wire [26:0] rom_ioctl_addr = rom_base_addr + ioctl_addr;
wire        rom_ioctl_wr   = ioctl_wr & ioctl_download & (ioctl_index != 8'hFE);

sdram_b u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .rst_n      (reset_n),

    // CH0: HPS ROM download write path
    .ioctl_wr   (rom_ioctl_wr),
    .ioctl_addr (rom_ioctl_addr),
    .ioctl_dout (ioctl_dout),

    // CH1: CPU program ROM reads (16-bit)
    .cpu_addr   (cpu_sdr_addr),
    .cpu_data   (cpu_sdr_data),
    .cpu_req    (cpu_sdr_req),
    .cpu_ack    (cpu_sdr_ack),

    // CH2: GFX ROM reads (16-bit; 2-beat FSM below assembles 32-bit result)
    .gfx_addr   (gfx2_sdram_addr),
    .gfx_data   (gfx2_sdram_data),
    .gfx_req    (gfx2_sdram_req),
    .gfx_ack    (gfx2_sdram_ack),

    // CH3: ADPCM + Z80 ROM (arbitrated)
    .adpcm_addr (ch3_addr),
    .adpcm_data (ch3_data_out),
    .adpcm_req  (ch3_req),
    .adpcm_ack  (ch3_ack),

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

// ─────────────────────────────────────────────────────────────────────────────
// GFX 2-beat read state machine
//
// kaneko16 requests 32-bit GFX ROM words via a toggle-handshake.
// sdram_b CH2 returns only 16 bits per access.  This FSM intercepts the
// core-side request, performs TWO sequential 16-bit SDRAM reads at
//   beat 0 : gfx_sdr_addr + 0  → gfx_sdr_data[15:0]
//   beat 1 : gfx_sdr_addr + 1  → gfx_sdr_data[31:16]
// then toggles the ack back to the core.
//
// State encoding:
//   GFX_IDLE  (2'b00) : waiting for new core request
//   GFX_BEAT0 (2'b01) : first SDRAM read in flight
//   GFX_BEAT1 (2'b10) : second SDRAM read in flight
// ─────────────────────────────────────────────────────────────────────────────
localparam GFX_IDLE  = 2'b00;
localparam GFX_BEAT0 = 2'b01;
localparam GFX_BEAT1 = 2'b10;

logic [1:0]  gfx_state;
logic [31:0] gfx_data_r;      // assembled 32-bit result
logic        gfx_ack_r;       // ack toggled back to core
logic        gfx_req_prev;    // track previous req to detect edge

assign gfx_sdr_data = gfx_data_r;
assign gfx_sdr_ack  = gfx_ack_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        gfx_state        <= GFX_IDLE;
        gfx_data_r       <= 32'b0;
        gfx_ack_r        <= 1'b0;
        gfx_req_prev     <= 1'b0;
        gfx2_sdram_req   <= 1'b0;
        gfx2_sdram_addr  <= 27'b0;
    end else begin
        case (gfx_state)
            GFX_IDLE: begin
                gfx_req_prev <= gfx_sdr_req;
                if (gfx_sdr_req != gfx_req_prev) begin
                    // New request from core: issue first SDRAM read (lower word)
                    gfx2_sdram_addr <= gfx_sdr_addr;
                    gfx2_sdram_req  <= ~gfx2_sdram_req;
                    gfx_state       <= GFX_BEAT0;
                end
            end

            GFX_BEAT0: begin
                if (gfx2_sdram_req == gfx2_sdram_ack) begin
                    // First read complete — latch lower 16 bits
                    gfx_data_r[15:0] <= gfx2_sdram_data;
                    // Issue second SDRAM read (upper word, address + 1)
                    gfx2_sdram_addr <= gfx_sdr_addr + 27'd1;
                    gfx2_sdram_req  <= ~gfx2_sdram_req;
                    gfx_state       <= GFX_BEAT1;
                end
            end

            GFX_BEAT1: begin
                if (gfx2_sdram_req == gfx2_sdram_ack) begin
                    // Second read complete — latch upper 16 bits and ack the core
                    gfx_data_r[31:16] <= gfx2_sdram_data;
                    gfx_ack_r         <= ~gfx_ack_r;
                    gfx_state         <= GFX_IDLE;
                end
            end

            default: gfx_state <= GFX_IDLE;
        endcase
    end
end

//////////////////////////////////////////////////////////////////
// Kaneko16 core
//////////////////////////////////////////////////////////////////

// Audio from core
wire [15:0] core_snd_left, core_snd_right;
assign AUDIO_L = core_snd_left;
assign AUDIO_R = core_snd_right;

// Video output from core
wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;

//////////////////////////////////////////////////////////////////
// fx68k_adapter — MC68000 @ 16 MHz
//////////////////////////////////////////////////////////////////

wire [23:1] cpu_addr;
wire [15:0] cpu_din_w;    // kaneko_arcade → CPU (read data from bus)
wire [15:0] cpu_dout_w;   // CPU → kaneko_arcade (write data)
wire        cpu_rw;
wire        cpu_uds_n;
wire        cpu_lds_n;
wire        cpu_as_n;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire        cpu_reset_n_out;
wire [2:0]  cpu_fc;       // function codes — needed by kaneko_arcade for IACK decode
wire        cpu_inta_n;   // IACK strobe from adapter (kaneko_arcade derives its own internally)
wire        cpu_halted_n; // double-bus-fault indicator (diagnostic only)

fx68k_adapter u_cpu (
    .clk            (clk_sys),
    .cpu_ce         (ce_cpu),
    .reset_n        (reset_n),

    .cpu_addr       (cpu_addr),
    .cpu_din        (cpu_din_w),
    .cpu_dout       (cpu_dout_w),
    .cpu_rw         (cpu_rw),
    .cpu_uds_n      (cpu_uds_n),
    .cpu_lds_n      (cpu_lds_n),
    .cpu_as_n       (cpu_as_n),
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_ipl_n      (cpu_ipl_n),
    .cpu_reset_n_out(cpu_reset_n_out),
    .cpu_inta_n     (cpu_inta_n),
    .cpu_fc         (cpu_fc),
    .cpu_halted_n   (cpu_halted_n)
);

// prog_rom_addr from kaneko_arcade core drives SDRAM CH1 address.
// Using a separate wire avoids multi-driver: kaneko_arcade outputs prog_rom_addr (OUTPUT)
// which previously conflicted with a direct assign from cpu_addr.
wire [19:1] prog_rom_addr_w;
assign cpu_sdr_addr = {8'b0, prog_rom_addr_w[19:1]};

kaneko_arcade u_kaneko_arcade
(
    .clk_sys    (clk_sys),
    .clk_pix    (ce_pix),
    .reset_n    (reset_n),

    // ── CPU bus ──────────────────────────────────────────────────────────────
    .cpu_addr    (cpu_addr),
    .cpu_dout    (cpu_dout_w),   // CPU write data → kaneko_arcade
    .cpu_din     (cpu_din_w),    // kaneko_arcade read data → CPU
    .cpu_lds_n   (cpu_lds_n),
    .cpu_uds_n   (cpu_uds_n),
    .cpu_rw      (cpu_rw),
    .cpu_as_n    (cpu_as_n),
    .cpu_dtack_n (cpu_dtack_n),
    .cpu_ipl_n   (cpu_ipl_n),
    .cpu_fc      (cpu_fc),        // function codes for level-specific IACK decode

    // ── Program ROM (SDRAM CH1) ───────────────────────────────────────────────
    .prog_rom_addr (prog_rom_addr_w),
    .prog_rom_data (cpu_sdr_data),
    .prog_rom_req  (cpu_sdr_req),
    .prog_rom_ack  (cpu_sdr_ack),

    // ── GFX ROM (SDRAM CH2) ───────────────────────────────────────────────────
    .gfx_rom_addr (gfx_sdr_addr[21:0]),
    .gfx_rom_data (gfx_sdr_data),
    .gfx_rom_req  (gfx_sdr_req),
    .gfx_rom_ack  (gfx_sdr_ack),

    // ── Video output ──────────────────────────────────────────────────────────
    .rgb_r       (core_rgb_r),
    .rgb_g       (core_rgb_g),
    .rgb_b       (core_rgb_b),
    .hsync_n     (core_hsync_n),
    .vsync_n     (core_vsync_n),
    .hblank      (core_hblank),
    .vblank      (core_vblank),

    // ── Player inputs ─────────────────────────────────────────────────────────
    .joystick_p1 (joy_p1),
    .joystick_p2 (joy_p2),
    .coin        (coin),
    .service     (service),
    .dipsw1      (dsw[0]),
    .dipsw2      (dsw[1]),

    // ── Audio ─────────────────────────────────────────────────────────────────
    .snd_left        (core_snd_left),
    .snd_right       (core_snd_right),

    // ── ADPCM ROM (SDRAM CH3, arbitrated) ────────────────────────────────────
    .adpcm_rom_addr  (adpcm_rom_addr_w),
    .adpcm_rom_req   (adpcm_rom_req_w),
    .adpcm_rom_data  (adpcm_rom_data_w),
    .adpcm_rom_ack   (adpcm_rom_ack_w),

    // ── Sound clock enable ────────────────────────────────────────────────────
    .clk_sound_cen   (clk_sound_cen),

    // ── Z80 sound ROM (SDRAM CH3, arbitrated) ────────────────────────────────
    .z80_rom_addr    (z80_rom_addr_w),
    .z80_rom_req     (z80_sdr_req_w),
    .z80_rom_data    (z80_sdr_byte_w),
    .z80_rom_ack     (z80_sdr_ack_w)
);

//////////////////////////////////////////////////////////////////
// Video pipeline
// arcade_video handles: sync-fix, colour expansion, scandoubler, gamma
//
// kaneko_arcade outputs hsync_n / vsync_n (active-low).
// arcade_video expects active-high HSync/VSync convention.
// Native resolution: 256×224, 24-bit RGB from RGB555 palette (expanded to R8G8B8).
//////////////////////////////////////////////////////////////////

arcade_video #(.WIDTH(256), .DW(24), .GAMMA(1)) u_arcade_video
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
    cpu_reset_n_out,
    gfx_sdr_addr[26:22]   // upper bits not used in 2MB GFX window
};
/* verilator lint_on UNUSED */

endmodule
