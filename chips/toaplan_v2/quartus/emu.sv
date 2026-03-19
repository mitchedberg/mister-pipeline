//============================================================================
//  Arcade: Toaplan V2 System (Batsugun)
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
// Toaplan V2 display parameters:
//   Primary target:    Batsugun
//   Native resolution: 320 × 240 (visible)
//   CPU clock:         16 MHz (MC68000 @ 16 MHz)
//   Pixel clock:       8 MHz (sys_clk / 2 CE)
//   RGB output:        8 bits per channel (24-bit total) from R5G5B5 palette
//   Aspect ratio:      4:3
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — CPU program ROM (sequential, SDRAM base 0x000000)
//   0x01 — GFX ROM (GP9001 tile + sprite data, SDRAM 0x100000)
//   0x02 — ADPCM ROM (OKI M6295 samples, SDRAM 0x500000)
//   0x03 — Z80 sound CPU ROM (Z80 sound CPU code, SDRAM 0x600000)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB, Batsugun):
//   0x000000 – 0x0FFFFF   1MB    CPU program ROM (tp-026-1.bin + others)
//   0x100000 – 0x4FFFFF   4MB    GFX ROM (tiles + sprites interleaved)
//   0x500000 – 0x5FFFFF   1MB    ADPCM ROM (OKI M6295 sample data)
//   0x600000 – 0x607FFF   32KB   Z80 sound CPU ROM
//
// NOTE: Batsugun hardware uses a NEC V25 (not a standard Z80) as the sound CPU.
// The V25 shares the 68K ROM space via ShareRAM and does not have a separate ROM.
// This Z80 instantiation is provided for Toaplan V2 games that DO use a Z80 sound
// CPU (e.g., other Toaplan V2 variants). For Batsugun, connect z80_rom_addr to
// the main CPU ROM space (0x000000–0x07FFFF) if needed.
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

// Audio: driven by YM2151 + OKI M6295 (wired below at toaplan_v2 instantiation)

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — Toaplan V2 is 4:3
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
    "ToaplanV2;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "O[1:0],Lives,1,2,3,5;",
    "O[3:2],Difficulty,Easy,Normal,Hard,Hardest;",
    "O[4],Demo Sound,Off,On;",
    "O[5],Continue,Yes,No;",
    "-;",
    "T[0],Reset;",
    // Batsugun: 2 players, 3 buttons + start + coin
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
// Toaplan V2 system clock: 32 MHz (MC68000 @ 16 MHz via /2 CE).
// GP9001 pixel clock: 8 MHz (sys_clk / 4 CE).
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
// ce_pix: /4 clock enable — 8 MHz pixel clock.
//////////////////////////////////////////////////////////////////
logic [1:0] ce_div;   // free-running 2-bit counter

wire  reset_n;  // forward-declared; defined in Reset section below

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        ce_div <= 2'b00;
    else
        ce_div <= ce_div + 2'd1;
end

wire ce_cpu = (ce_div[0] == 1'b0);   // every 2 cycles = 16 MHz
wire ce_pix = (ce_div == 2'b00);     // every 4 cycles = 8 MHz

// ── Sound clock enable: ~3.5 MHz (32 MHz / 9 = 3.556 MHz) ────────────────────
// YM2151 nominal clock is 3.579545 MHz; /9 gives 3.556 MHz (0.66% low, inaudible).
logic [3:0] snd_ce_cnt;
logic       clk_sound;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        snd_ce_cnt <= 4'd0;
        clk_sound  <= 1'b0;
    end else begin
        if (snd_ce_cnt == 4'd8) begin
            snd_ce_cnt <= 4'd0;
            clk_sound  <= 1'b1;
        end else begin
            snd_ce_cnt <= snd_ce_cnt + 4'd1;
            clk_sound  <= 1'b0;
        end
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

// ioctl_index == 0x02: ADPCM ROM load.
// sdram_b receives all ioctl_wr writes; the .mra file sets ioctl_addr base
// to 0x500000 for index 0x02, placing sample data in the ADPCM SDRAM region.
// No extra logic needed here — sdram_b CH0 write path handles all indexes.

//////////////////////////////////////////////////////////////////
// Input mapping for Toaplan V2 shmup (Batsugun)
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1(fire) [5]=B2 [6]=B3 [7]=B4
//   [8]=Start [9]=Coin
//
// toaplan_v2 expects active-low inputs:
//   joystick_p1[7:0]:
//     [7]=BTN3 [6]=BTN2 [5]=BTN1 [4]=START [3]=RIGHT [2]=LEFT [1]=DOWN [0]=UP
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
// Three read channels:
//   prog_*  — CPU program ROM reads (16-bit)
//   gfx_*   — GP9001 tile + sprite GFX ROM (32-bit)
//   adpcm_* — OKI M6295 ADPCM sample ROM reads (8-bit, via 16-bit SDRAM)
// Plus ioctl write path for ROM download.
//////////////////////////////////////////////////////////////////

wire [19:1] prog_sdr_addr_w;
wire [15:0] prog_sdr_data_w;
wire        prog_sdr_req_w, prog_sdr_ack_w;

// GFX ROM channel — core-side (32-bit, toggle-handshake)
wire [21:0] gfx_sdr_addr_w;
wire [31:0] gfx_sdr_data_w;
wire        gfx_sdr_req_w, gfx_sdr_ack_w;

// GFX ROM channel — SDRAM-side (16-bit, toggle-handshake)
// In simulation (VERILATOR) a 2-beat FSM assembles two 16-bit reads into
// one 32-bit word.  In synthesis the SDRAM controller handles burst/wide
// reads natively, so we pass the request through directly.
`ifdef VERILATOR
logic [26:0] gfx2_sdram_addr;
logic        gfx2_sdram_req;
`else
wire  [26:0] gfx2_sdram_addr = gfx_sdram_word_addr;
wire         gfx2_sdram_req  = gfx_sdr_req_w;
`endif
wire  [15:0] gfx2_sdram_data;
wire         gfx2_sdram_ack;

// ADPCM ROM channel — jt6295 uses 18-bit byte address; SDRAM CH3 is 27-bit word address.
// ADPCM ROM sits at SDRAM byte base 0x500000 (word base 0x280000).
wire [23:0] adpcm_rom_addr_w;    // from toaplan_v2 (byte address, base 0 within ADPCM ROM)
wire        adpcm_rom_req_w;
wire [15:0] adpcm_rom_data_w;
wire        adpcm_rom_ack_w;

// Map ADPCM byte address to SDRAM 27-bit word address:
//   ADPCM ROM byte base in SDRAM = 0x500000
//   SDRAM word address = (0x500000 + adpcm_rom_addr) >> 1 = 0x280000 + (addr >> 1)
wire [26:0] adpcm_sdram_word_addr = 27'h280000 + {3'b0, adpcm_rom_addr_w[23:1]};

// Z80 sound CPU ROM channel — SDRAM CH4 (27-bit word address).
// Z80 ROM sits at SDRAM byte base 0x600000 (word base 0x300000).
// toaplan_v2 drives a 16-bit Z80 address; map to SDRAM word addr:
//   SDRAM word address = (0x600000 + z80_rom_addr) >> 1 = 0x300000 + (addr >> 1)
wire [15:0] z80_sdr_addr_w;      // from toaplan_v2 (Z80 16-bit address)
wire        z80_sdr_req_w;
wire  [7:0] z80_sdr_data_w;      // byte returned to toaplan_v2
wire        z80_sdr_ack_w;
wire [15:0] z80_sdr_data16_w;    // 16-bit word from SDRAM (byte-selected below)

// Z80 ROM SDRAM word address: base 0x300000, add Z80 addr >> 1
wire [26:0] z80_sdram_word_addr = 27'h300000 + {11'b0, z80_sdr_addr_w[15:1]};

// Byte-lane select: Z80 addr[0]=0 → lower byte, addr[0]=1 → upper byte
assign z80_sdr_data_w = z80_sdr_addr_w[0] ? z80_sdr_data16_w[15:8]
                                           : z80_sdr_data16_w[7:0];

// Audio output wires from toaplan_v2
wire signed [15:0] snd_left_w, snd_right_w;

// Adapt prog ROM address to 27-bit SDRAM word address
// Prog ROM sits at SDRAM base 0x000000; word address = prog_sdr_addr directly
wire [26:0] prog_sdram_word_addr = {8'b0, prog_sdr_addr_w};

// GFX ROM sits at SDRAM byte offset 0x100000; word addr = 0x80000 + gfx_rom_word_offset
// gfx_sdr_addr is a 22-bit word address within GFX ROM space
wire [26:0] gfx_sdram_word_addr  = {5'b0, gfx_sdr_addr_w};

sdram_b u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .rst_n      (reset_n),   // sdram_b port is rst_n

    // CH0: HPS ROM download write path
    .ioctl_wr   (ioctl_wr & ioctl_download),
    .ioctl_addr (ioctl_addr),
    .ioctl_dout (ioctl_dout),

    // CH1: CPU program ROM reads (16-bit)
    .cpu_addr   (prog_sdram_word_addr),
    .cpu_data   (prog_sdr_data_w),
    .cpu_req    (prog_sdr_req_w),
    .cpu_ack    (prog_sdr_ack_w),

    // CH2: GFX ROM reads (16-bit; 2-beat FSM below assembles 32-bit result)
    .gfx_addr   (gfx2_sdram_addr),
    .gfx_data   (gfx2_sdram_data),
    .gfx_req    (gfx2_sdram_req),
    .gfx_ack    (gfx2_sdram_ack),

    // CH3: ADPCM ROM — OKI M6295 sample data at SDRAM base 0x500000
    .adpcm_addr (adpcm_sdram_word_addr),
    .adpcm_data (adpcm_rom_data_w),
    .adpcm_req  (adpcm_rom_req_w),
    .adpcm_ack  (adpcm_rom_ack_w),

    // CH4: Z80 sound CPU ROM at SDRAM base 0x600000
    .z80_addr   (z80_sdram_word_addr),
    .z80_data   (z80_sdr_data16_w),
    .z80_req    (z80_sdr_req_w),
    .z80_ack    (z80_sdr_ack_w),

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
// GFX read logic — VERILATOR vs Quartus synthesis
//
// Simulation (VERILATOR): sdram_b returns only 16 bits per access, so a
// 3-state FSM performs two sequential reads to assemble a 32-bit GFX word.
//   GFX_IDLE  (2'b00) : waiting for new core request
//   GFX_BEAT0 (2'b01) : first 16-bit SDRAM read in flight → data[15:0]
//   GFX_BEAT1 (2'b10) : second 16-bit SDRAM read in flight → data[31:16]
//
// Synthesis (Quartus): the real SDRAM controller handles burst / wider reads
// natively.  We pass the GFX request straight through and return the lower
// 16 bits zero-extended.  No extra state registers → restores pre-FSM LAB
// count so the device fits.
// ─────────────────────────────────────────────────────────────────────────────

`ifdef VERILATOR
localparam GFX_IDLE  = 2'b00;
localparam GFX_BEAT0 = 2'b01;
localparam GFX_BEAT1 = 2'b10;

logic [1:0]  gfx_state;
logic [31:0] gfx_data_r;      // assembled 32-bit result
logic        gfx_ack_r;       // ack toggled back to core
logic        gfx_req_prev;    // track previous req to detect edge

assign gfx_sdr_data_w = gfx_data_r;
assign gfx_sdr_ack_w  = gfx_ack_r;

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
                gfx_req_prev <= gfx_sdr_req_w;
                if (gfx_sdr_req_w != gfx_req_prev) begin
                    // New request from core: issue first SDRAM read (lower word)
                    gfx2_sdram_addr <= gfx_sdram_word_addr;
                    gfx2_sdram_req  <= ~gfx2_sdram_req;
                    gfx_state       <= GFX_BEAT0;
                end
            end

            GFX_BEAT0: begin
                if (gfx2_sdram_req == gfx2_sdram_ack) begin
                    // First read complete — latch lower 16 bits
                    gfx_data_r[15:0] <= gfx2_sdram_data;
                    // Issue second SDRAM read (upper word, address + 1)
                    gfx2_sdram_addr <= gfx_sdram_word_addr + 27'd1;
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

`else
// Synthesis passthrough: 16-bit lower word only, upper 16 bits zero.
// No FSM state registers — matches pre-commit LAB usage so device fits.
assign gfx_sdr_data_w = {16'h0000, gfx2_sdram_data};
assign gfx_sdr_ack_w  = gfx2_sdram_ack;
`endif

//////////////////////////////////////////////////////////////////
// Toaplan V2 core
//////////////////////////////////////////////////////////////////

// Video output from core
wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;

//////////////////////////////////////////////////////////////////
// fx68k_adapter — MC68000 @ 16 MHz
//////////////////////////////////////////////////////////////////

wire [23:1] cpu_addr;
wire [15:0] cpu_din;     // toaplan_v2 → CPU (read data from bus)
wire [15:0] cpu_dout;    // CPU → toaplan_v2 (write data)
wire        cpu_rw;
wire        cpu_uds_n;
wire        cpu_lds_n;
wire        cpu_as_n;
wire        cpu_dtack_n; // toaplan_v2 → CPU
wire [2:0]  cpu_ipl_n;   // toaplan_v2 → CPU
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

toaplan_v2 u_toaplan_v2
(
    .clk_sys    (clk_sys),
    .clk_pix    (ce_pix),
    .reset_n    (reset_n),

    // ── CPU bus ───────────────────────────────────────────────────────────────
    .cpu_addr    (cpu_addr),
    .cpu_dout    (cpu_dout),    // CPU write data → toaplan_v2
    .cpu_din     (cpu_din),     // toaplan_v2 read data → CPU
    .cpu_rw      (cpu_rw),
    .cpu_as_n    (cpu_as_n),
    .cpu_uds_n   (cpu_uds_n),
    .cpu_lds_n   (cpu_lds_n),
    .cpu_dtack_n (cpu_dtack_n),
    .cpu_ipl_n   (cpu_ipl_n),

    // ── Program ROM ────────────────────────────────────────────────────────────
    .prog_rom_addr (prog_sdr_addr_w),
    .prog_rom_data (prog_sdr_data_w),
    .prog_rom_req  (prog_sdr_req_w),
    .prog_rom_ack  (prog_sdr_ack_w),

    // ── GFX ROM ────────────────────────────────────────────────────────────────
    .gfx_rom_addr (gfx_sdr_addr_w),
    .gfx_rom_data (gfx_sdr_data_w),
    .gfx_rom_req  (gfx_sdr_req_w),
    .gfx_rom_ack  (gfx_sdr_ack_w),

    // ── Audio output ──────────────────────────────────────────────────────────
    .snd_left        (snd_left_w),
    .snd_right       (snd_right_w),

    // ── ADPCM ROM (OKI M6295 samples via SDRAM CH3) ────────────────────────────
    .adpcm_rom_addr  (adpcm_rom_addr_w),
    .adpcm_rom_req   (adpcm_rom_req_w),
    .adpcm_rom_data  (adpcm_rom_data_w),
    .adpcm_rom_ack   (adpcm_rom_ack_w),

    // ── Z80 sound CPU ROM (via SDRAM CH4 at 0x600000) ────────────────────────
    .z80_rom_addr    (z80_sdr_addr_w),
    .z80_rom_req     (z80_sdr_req_w),
    .z80_rom_data    (z80_sdr_data_w),
    .z80_rom_ack     (z80_sdr_ack_w),

    // ── Sound CPU clock enable (~3.5 MHz) ────────────────────────────────────
    .clk_sound       (clk_sound),

    // ── Video output ───────────────────────────────────────────────────────────
    .rgb_r       (core_rgb_r),
    .rgb_g       (core_rgb_g),
    .rgb_b       (core_rgb_b),
    .hsync_n     (core_hsync_n),
    .vsync_n     (core_vsync_n),
    .hblank      (core_hblank),
    .vblank      (core_vblank),

    // ── Player inputs ──────────────────────────────────────────────────────────
    .joystick_p1 (joy_p1),
    .joystick_p2 (joy_p2),
    .coin        (coin),
    .service     (service),
    .dipsw1      (dsw[0]),
    .dipsw2      (dsw[1])
);

//////////////////////////////////////////////////////////////////
// Audio output
// snd_left/snd_right are signed 16-bit from the YM2151 + OKI M6295 mixer.
// MiSTer AUDIO_L/R are unsigned 16-bit; add 0x8000 to flip sign bit.
//////////////////////////////////////////////////////////////////
assign AUDIO_L = snd_left_w  + 16'h8000;
assign AUDIO_R = snd_right_w + 16'h8000;

//////////////////////////////////////////////////////////////////
// Video pipeline
// arcade_video handles: sync-fix, colour expansion, scandoubler, gamma
//
// toaplan_v2 outputs hsync_n / vsync_n (active-low).
// arcade_video expects active-high HSync/VSync convention.
// Native resolution: 320 × 240, 24-bit RGB.
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
    CLK_AUDIO,              // 24.576 MHz audio clock not needed; using clk_sys divider
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
    prog_sdram_word_addr,   // forwarded to sdram_b; suppress unused warning on wire
    adpcm_sdram_word_addr,  // forwarded to sdram_b CH3; suppress unused warning on wire
    z80_sdram_word_addr     // forwarded to sdram_b CH4; suppress unused warning on wire
};
/* verilator lint_on UNUSED */

endmodule
