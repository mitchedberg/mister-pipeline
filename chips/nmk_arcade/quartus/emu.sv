//============================================================================
//  Arcade: NMK16 System
//
//  MiSTer emu top-level wrapper
//  Target: Thunder Dragon (nmk16 hardware)
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

// -------------------------------------------------------------------------
// NMK16 display parameters:
//   Primary target:    Thunder Dragon
//   Native resolution: 256 × 224 (visible), arcade standard timing
//   CPU clock:         10 MHz (MC68000)
//   Pixel clock:       ~5.7 MHz (40 MHz sys_clk / 7 CE, hardware is ~6 MHz)
//   RGB output:        8 bits per channel (24-bit) from RGB555 palette
//   Aspect ratio:      4:3
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — CPU prog ROM (sequential, SDRAM base 0x000000)
//   0x01 — Sprite ROM   (SDRAM 0x0C0000, up to 1MB)
//   0x02 — BG tile ROM  (SDRAM 0x1C0000, up to 128KB — tile_idx is 10-bit)
//   0x03 — ADPCM ROM    (SDRAM 0x200000)   ← OKI M6295 sample ROM
//   0x04 — Z80 sound ROM (SDRAM 0x280000)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB):
//   0x000000 – 0x07FFFF   512KB   CPU program ROM
//   0x0C0000 – 0x1BFFFF     1MB   Sprite ROM   (SPR_ROM_BASE=0x0C0000; 21-bit addr)
//   0x1C0000 – 0x1DFFFF   128KB   BG tile ROM  (BG_ROM_BASE=0x1C0000; 10-bit tile_idx)
//   0x200000 – 0x27FFFF   512KB   ADPCM sample ROM (OKI M6295)
//   0x280000 – 0x28BFFF    48KB   Z80 sound ROM
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
    output        FB_PAL_CLK,
    output  [7:0] FB_PAL_ADDR,
    output [23:0] FB_PAL_DOUT,
    input  [23:0] FB_PAL_DIN,
    output        FB_PAL_WR,
`endif
`endif

    output        LED_USER,  // 1 - ON, 0 - OFF.

    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,

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

// Audio: driven from nmk_arcade (YM2203 + OKI M6295 mix)
// snd_left/snd_right are signed 16-bit; MiSTer AUDIO_L/R expect same format.
// AUDIO_S=1 (set above) declares signed samples to the framework.

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — NMK16 is 4:3
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
    "NMK16;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "O[1:0],Lives,1,2,3,5;",
    "O[3:2],Difficulty,Easy,Normal,Hard,Hardest;",
    "O[4],Demo Sound,Off,On;",
    "-;",
    "T[0],Reset;",
    // NMK16 shoot-em-ups: 2 joysticks + 3 buttons + start + coin
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
// NMK16 CPU: 10 MHz (MC68000).
// Use 40 MHz sys_clk, /4 CE for 10 MHz CPU.
// Pixel clock: ~5.7 MHz (40 MHz / 7 CE, hardware is ~6 MHz).
// SDRAM clock: 143 MHz.
//////////////////////////////////////////////////////////////////

wire clk_sys;       // 40 MHz — core system clock
wire clk_sdram;     // 143.0 MHz — SDRAM interface clock
wire pll_locked;

pll u_pll
(
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),    // 40 MHz
    .outclk_1 (clk_sdram),  // 143.0 MHz
    .locked   (pll_locked)
);

assign SDRAM_CLK = clk_sdram;

//////////////////////////////////////////////////////////////////
// Clock enables
//
// ce_cpu: /4 clock enable — 10 MHz effective CPU clock.
// ce_pix: independent /7 clock enable — ~5.7 MHz pixel clock.
//   NMK16 hardware pixel clock is ~6 MHz; /7 from 40 MHz = 5.71 MHz (≈5% low).
//////////////////////////////////////////////////////////////////
logic [1:0] ce_div;
logic       ce_cpu;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_div <= 2'b00;
        ce_cpu <= 1'b0;
    end else begin
        ce_div <= ce_div + 2'd1;
        ce_cpu <= (ce_div == 2'b11);
    end
end

// Pixel clock enable: independent /7 divider = ~5.7 MHz.
logic [2:0] ce_pix_cnt;
logic       ce_pix;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_pix_cnt <= 3'd0;
        ce_pix     <= 1'b0;
    end else begin
        if (ce_pix_cnt == 3'd6) begin
            ce_pix_cnt <= 3'd0;
            ce_pix     <= 1'b1;
        end else begin
            ce_pix_cnt <= ce_pix_cnt + 3'd1;
            ce_pix     <= 1'b0;
        end
    end
end

//////////////////////////////////////////////////////////////////
// Reset
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
// Input mapping for NMK16 shoot-em-ups
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1 [5]=B2 [6]=B3 [7]=B4
//   [8]=Start [9]=Coin
//
// nmk_arcade expects active-low joystick_p1[7:0]:
//   [7:4] = {BTN3,BTN2,BTN1,START} (active-low)
//   [3:0] = {RIGHT,LEFT,DOWN,UP}   (active-low)
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
// Three channels:
//   prog_*  — CPU program ROM reads (16-bit)
//   spr_*   — Sprite ROM reads (16-bit)
//   bg_*    — BG tile ROM reads (16-bit)
// Plus ioctl write path for ROM download.
//////////////////////////////////////////////////////////////////

wire [26:0] prog_sdr_addr;
wire [15:0] prog_sdr_data;
wire        prog_sdr_req, prog_sdr_ack;

wire [26:0] spr_sdr_addr;
wire [15:0] spr_sdr_data;
wire        spr_sdr_req, spr_sdr_ack;

wire [26:0] bg_sdr_addr;
wire [15:0] bg_sdr_data;
wire        bg_sdr_req, bg_sdr_ack;

// CH4 (snd): shared between ADPCM ROM and Z80 sound ROM
// adpcm_rom_addr from nmk_arcade is 24-bit; zero-extend to 27-bit for sdram_b.
wire [23:0] adpcm_rom_addr_w;
wire        adpcm_sdr_req, adpcm_sdr_ack;
wire [15:0] adpcm_sdr_data;

// Z80 ROM SDRAM signals
wire [15:0] z80_rom_addr_w;
wire        z80_sdr_req, z80_sdr_ack;
wire  [7:0] z80_sdr_byte;
wire [15:0] z80_sdr_data;

// Byte lane select for Z80 ROM (Z80 addr bit 0)
assign z80_sdr_byte = z80_rom_addr_w[0] ? z80_sdr_data[15:8] : z80_sdr_data[7:0];

// CH4 arbiter: ADPCM and Z80 ROM share the snd channel
// ADPCM gets priority when both pending (ADPCM is time-critical for samples).
wire [26:0] ch4_addr;
wire        ch4_req;
wire        ch4_ack;

logic ch4_owner;   // 0=ADPCM, 1=Z80
logic ch4_busy;

wire adpcm_pend = (adpcm_sdr_req != adpcm_sdr_ack);
wire z80_pend   = (z80_sdr_req   != z80_sdr_ack);

logic ch4_req_r;
logic [26:0] ch4_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ch4_req_r  <= 1'b0;
        ch4_addr_r <= 27'b0;
        ch4_owner  <= 1'b0;
        ch4_busy   <= 1'b0;
    end else begin
        if (!ch4_busy) begin
            if (adpcm_pend) begin
                ch4_addr_r <= {3'b0, adpcm_rom_addr_w};
                ch4_req_r  <= ~ch4_req_r;
                ch4_owner  <= 1'b0;
                ch4_busy   <= 1'b1;
            end else if (z80_pend) begin
                // Z80 ROM at SDRAM 0x280000: add base offset to 16-bit address
                ch4_addr_r <= 27'h280000 + {11'b0, z80_rom_addr_w[15:1]};
                ch4_req_r  <= ~ch4_req_r;
                ch4_owner  <= 1'b1;
                ch4_busy   <= 1'b1;
            end
        end else begin
            if (ch4_req_r == ch4_ack)
                ch4_busy <= 1'b0;
        end
    end
end

assign ch4_addr = ch4_addr_r;
assign ch4_req  = ch4_req_r;

// Route ack back to the winning client
assign adpcm_sdr_ack = (ch4_owner == 1'b0) ? ch4_ack : adpcm_sdr_req;
assign z80_sdr_ack   = (ch4_owner == 1'b1) ? ch4_ack : z80_sdr_req;

// ch4_data_w: returned by sdram_b snd port; shared word for both clients
wire [15:0] ch4_data_w;
assign adpcm_sdr_data = ch4_data_w;
assign z80_sdr_data   = ch4_data_w;

// Audio wires from core
wire signed [15:0] snd_left_w, snd_right_w;

// ROM index → SDRAM base address routing (ioctl_addr resets to 0 per index)
reg [26:0] rom_base_addr;
always_comb begin
    case (ioctl_index)
        8'h00: rom_base_addr = 27'h000000; // CPU prog ROM
        8'h01: rom_base_addr = 27'h0C0000; // Sprite ROM
        8'h02: rom_base_addr = 27'h1C0000; // BG tile ROM
        8'h03: rom_base_addr = 27'h200000; // ADPCM ROM
        8'h04: rom_base_addr = 27'h280000; // Z80 sound ROM
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

    // CH1: CPU program ROM reads
    .cpu_addr   (prog_sdr_addr),
    .cpu_data   (prog_sdr_data),
    .cpu_req    (prog_sdr_req),
    .cpu_ack    (prog_sdr_ack),

    // CH2: Sprite ROM reads
    .gfx_addr   (spr_sdr_addr),
    .gfx_data   (spr_sdr_data),
    .gfx_req    (spr_sdr_req),
    .gfx_ack    (spr_sdr_ack),

    // CH3: BG tile ROM reads
    .adpcm_addr (bg_sdr_addr),
    .adpcm_data (bg_sdr_data),
    .adpcm_req  (bg_sdr_req),
    .adpcm_ack  (bg_sdr_ack),

    // CH4: ADPCM + Z80 ROM (arbitrated)
    .snd_addr   (ch4_addr),
    .snd_data   (ch4_data_w),
    .snd_req    (ch4_req),
    .snd_ack    (ch4_ack),

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
// NMK arcade core
//////////////////////////////////////////////////////////////////

wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;

//////////////////////////////////////////////////////////////////
// fx68k_adapter — MC68000 @ 10 MHz
//////////////////////////////////////////////////////////////////

wire [23:1] cpu_addr;
wire [15:0] cpu_din;
wire [15:0] cpu_dout;
wire        cpu_rw;
wire        cpu_uds_n;
wire        cpu_lds_n;
wire        cpu_as_n;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire        cpu_reset_n_out;
wire        cpu_inta_n;     // IACK signal: active-low, FC=111 & ASn=0

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
    .cpu_reset_n_out(cpu_reset_n_out),
    .cpu_inta_n     (cpu_inta_n),
    .cpu_fc         ()         // not needed by nmk_arcade
);

nmk_arcade u_nmk_arcade
(
    .clk_sys    (clk_sys),
    .clk_pix    (ce_pix),
    .reset_n    (reset_n),

    // CPU bus
    .cpu_addr    (cpu_addr),
    .cpu_din     (cpu_dout),    // CPU write data → nmk_arcade
    .cpu_dout    (cpu_din),     // nmk_arcade read data → CPU
    .cpu_lds_n   (cpu_lds_n),
    .cpu_uds_n   (cpu_uds_n),
    .cpu_rw      (cpu_rw),
    .cpu_as_n    (cpu_as_n),
    .cpu_dtack_n (cpu_dtack_n),
    .cpu_ipl_n   (cpu_ipl_n),
    .cpu_inta_n  (cpu_inta_n),  // IACK clear for IPL latch

    // Program ROM
    .prog_rom_addr (prog_sdr_addr),
    .prog_rom_data (prog_sdr_data),
    .prog_rom_req  (prog_sdr_req),
    .prog_rom_ack  (prog_sdr_ack),

    // Sprite ROM
    .spr_rom_sdram_addr (spr_sdr_addr),
    .spr_rom_sdram_data (spr_sdr_data),
    .spr_rom_sdram_req  (spr_sdr_req),
    .spr_rom_sdram_ack  (spr_sdr_ack),

    // BG tile ROM
    .bg_rom_sdram_addr (bg_sdr_addr),
    .bg_rom_sdram_data (bg_sdr_data),
    .bg_rom_sdram_req  (bg_sdr_req),
    .bg_rom_sdram_ack  (bg_sdr_ack),

    // Video output
    .rgb_r       (core_rgb_r),
    .rgb_g       (core_rgb_g),
    .rgb_b       (core_rgb_b),
    .hsync_n     (core_hsync_n),
    .vsync_n     (core_vsync_n),
    .hblank      (core_hblank),
    .vblank      (core_vblank),

    // Video timing (standard 256×224 arcade)
    .hblank_n_in (1'b1),
    .vblank_n_in (1'b1),
    .hpos        (9'h000),
    .vpos        (8'h00),
    .hsync_n_in  (1'b1),
    .vsync_n_in  (1'b1),

    // Player inputs
    .joystick_p1 (joy_p1),
    .joystick_p2 (joy_p2),
    .coin        (coin),
    .service     (service),
    .dipsw1      (dsw[0]),
    .dipsw2      (dsw[1]),

    // Audio outputs
    .snd_left    (snd_left_w),
    .snd_right   (snd_right_w),

    // ADPCM ROM (OKI M6295) SDRAM interface
    .adpcm_rom_addr (adpcm_rom_addr_w),
    .adpcm_rom_req  (adpcm_sdr_req),
    .adpcm_rom_data (adpcm_sdr_data),
    .adpcm_rom_ack  (adpcm_sdr_ack),

    // Z80 sound ROM SDRAM interface
    .z80_rom_addr   (z80_rom_addr_w),
    .z80_rom_req    (z80_sdr_req),
    .z80_rom_data   (z80_sdr_byte),
    .z80_rom_ack    (z80_sdr_ack)
);

// Route core audio to MiSTer audio outputs
assign AUDIO_L = snd_left_w;
assign AUDIO_R = snd_right_w;

//////////////////////////////////////////////////////////////////
// Video pipeline
//////////////////////////////////////////////////////////////////

arcade_video #(.WIDTH(256), .DW(24), .GAMMA(1)) u_arcade_video
(
    .clk_video  (clk_sys),
    .ce_pix     (ce_pix),

    .RGB_in     ({core_rgb_r, core_rgb_g, core_rgb_b}),
    .HBlank     (core_hblank),
    .VBlank     (core_vblank),
    .HSync      (~core_hsync_n),
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
    cpu_reset_n_out
};
/* verilator lint_on UNUSED */

endmodule
