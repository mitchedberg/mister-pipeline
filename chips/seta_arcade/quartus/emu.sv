//============================================================================
//  Arcade: SETA 1 System
//
//  MiSTer emu top-level wrapper
//  Target: Dragon Unit, Thunder & Lightning, Blandia, Rezon, + 62 more
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

// -------------------------------------------------------------------------
// SETA 1 display parameters:
//   Primary targets:   Dragon Unit (drgnunit), Thunder & Lightning (thunderl),
//                      Blandia (blandia), Rezon (rezon), + 62 others
//   Native resolution: 384 × 240 (visible), 512 × 262 total (60 Hz)
//   Main CPU:          MC68000 @ 16 MHz (32 MHz sys_clk / 2 clock-enable)
//   Sound:             X1-010 (stub — not implemented; audio is silent)
//   Pixel clock:       8 MHz (32 MHz sys_clk / 4 CE)
//   RGB output:        5 bits per channel (15-bit total) from xRGB_555 palette
//   Aspect ratio:      4:3
//
// Hardware clock relationships:
//   16 MHz crystal → 68000 @ 16 MHz, pixel clock varies by game
//   PLL generates 32 MHz for FPGA (2× master), SDRAM at 143 MHz
//   Clock enables: /2 = 16 MHz CPU, /4 = 8 MHz pixel
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — 68000 program ROM (sequential, SDRAM base 0x000000)
//   0x01 — Sprite/GFX ROM (X1-001A tile data, SDRAM base 0x200000)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB, byte addresses):
//   0x000000 – 0x1FFFFF    2MB   68000 program ROM (largest game: Blandia 2MB)
//   0x200000 – 0x5FFFFF    4MB   Sprite / Tile GFX ROM (X1-001A)
//
// Per-game WRAM/sprite address variants:
//   Default (drgnunit, thunderl): WRAM=0xFFC000 16KB, SprY=0xD00000, SprC=0xE00000
//   Blandia: WRAM=0x200000+0x210000 64KB×2, SprY+SprC at 0x800000
//   Parameters are set via the CONF_STR "DIP" game-select mechanism or
//   fixed to Dragon Unit defaults for initial MiSTer core release.
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

// X1-010 audio not implemented — output silence
assign AUDIO_L   = 16'd0;
assign AUDIO_R   = 16'd0;
assign AUDIO_S   = 1'b1;    // signed samples
assign AUDIO_MIX = 2'd0;    // no mix

assign LED_DISK  = 2'd0;
assign LED_POWER = 2'd0;
assign BUTTONS   = 2'd0;

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — SETA 1 is 4:3
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
    "Seta1;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "O[1:0],Coin,1C1P,1C2P,2C1P,3C1P;",
    "O[3:2],Lives,1,2,3,5;",
    "O[5:4],Difficulty,Easy,Normal,Hard,Hardest;",
    "-;",
    "T[0],Reset;",
    "J1,Button1,Button2,Button3,Start,Coin;",
    "jn,A,B,X,Start,Select;",
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
// SETA 1 hardware clock: 16 MHz (master crystal).
// FPGA: PLL generates 32 MHz (2× master) to allow /N clock-enables.
//   68000: /2 → 16 MHz effective
//   Pixel: /4 → 8 MHz
// SDRAM: 143 MHz from PLL outclk_1.
//////////////////////////////////////////////////////////////////

wire clk_sys;       // 32 MHz
wire clk_sdram;     // 143.0 MHz
wire pll_locked;

pll u_pll
(
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),
    .outclk_1 (clk_sdram),
    .locked   (pll_locked)
);

assign SDRAM_CLK = clk_sdram;

//////////////////////////////////////////////////////////////////
// Clock enables
//
// ce_cpu: 1 of every 2 sys_clk cycles → 16 MHz for 68000
// ce_pix: 1 of every 4 sys_clk cycles → 8 MHz pixel clock
//////////////////////////////////////////////////////////////////

logic [1:0] ce_cnt;
wire  reset_n;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) ce_cnt <= 2'd0;
    else          ce_cnt <= ce_cnt + 2'd1;
end

wire ce_cpu = (ce_cnt[0] == 1'b0);    // every 2 cycles = 16 MHz
wire ce_pix = (ce_cnt == 2'b00);       // every 4 cycles = 8 MHz

//////////////////////////////////////////////////////////////////
// Reset
//
// Hold reset for 256 cycles after ROM download completes.
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

//////////////////////////////////////////////////////////////////
// Input mapping
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1 [5]=B2 [6]=B3 [7]=B4
//   [8]=Start [9]=Coin
//
// SETA 1 expects active-low inputs.
// CONF_STR "J1,Button1,Button2,Button3,Start,Coin" assigns:
//   B1=[4] B2=[5] B3=[6] Start=[7] Coin=[8]
//////////////////////////////////////////////////////////////////

wire [7:0] joy_p1 = ~{ joystick_0[6], joystick_0[5], joystick_0[4], joystick_0[7],
                       joystick_0[3], joystick_0[2], joystick_0[1], joystick_0[0] };
wire [7:0] joy_p2 = ~{ joystick_1[6], joystick_1[5], joystick_1[4], joystick_1[7],
                       joystick_1[3], joystick_1[2], joystick_1[1], joystick_1[0] };

wire [1:0] coin    = ~{ joystick_1[8], joystick_0[8] };
wire       service = ~joystick_0[9];

//////////////////////////////////////////////////////////////////
// SDRAM controller
//
// Reuses sdram_x from taito_x (same 3-channel topology):
//   CH0: HPS ROM download write path
//   CH1: 68000 program ROM reads (toggle-handshake)
//   CH2: X1-001A GFX ROM reads   (toggle-handshake)
//   CH3: unused (tied off; was Z80 ROM in taito_x)
//
// SDRAM layout:
//   CH0 write: ioctl_index=0x00 → base 0x000000 (program ROM)
//              ioctl_index=0x01 → base 0x200000 (GFX ROM)
//   CH1 read:  seta_arcade prog_rom_addr (word-aligned)
//   CH2 read:  x1_001a gfx_addr (18-bit word addr → base 0x200000)
//////////////////////////////////////////////////////////////////

// CH1: 68000 program ROM
wire  [26:0] cpu_sdr_addr;
wire  [15:0] cpu_sdr_data;
wire         cpu_sdr_req, cpu_sdr_ack;

// CH2: GFX ROM (X1-001A)
wire  [26:0] gfx_sdr_addr;
wire  [15:0] gfx_sdr_data;
wire         gfx_sdr_req, gfx_sdr_ack;

// GFX ROM bridge: x1_001a 18-bit word addr → SDRAM byte-address 0x200000+
// SDRAM word address = (0x200000 >> 1) + gfx_addr_core = 0x100000 + gfx_addr_core
localparam logic [26:0] GFX_ROM_BASE = 27'h100000;  // byte 0x200000 / 2 = 0x100000 word

wire [17:0] gfx_addr_core;
wire [15:0] gfx_data_core;
wire        gfx_req_core, gfx_ack_core;

assign gfx_sdr_addr  = GFX_ROM_BASE + {9'b0, gfx_addr_core};
assign gfx_data_core = gfx_sdr_data;
assign gfx_sdr_req   = gfx_req_core;
assign gfx_ack_core  = gfx_sdr_ack;

// CH3: unused (Z80 stub — tied off)
logic [26:0] z80_sdr_addr = 27'b0;
logic        z80_sdr_req  = 1'b0;
wire  [15:0] z80_sdr_data;
wire         z80_sdr_ack;

sdram_x u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .reset_n    (reset_n),

    // CH0: HPS ROM download
    // ioctl_index 0x00: program ROM → SDRAM base 0x000000 (up to 2MB)
    // ioctl_index 0x01: GFX ROM    → SDRAM base 0x200000 (up to 4MB)
    // ioctl_index 0x02: tile ROM   → SDRAM base 0x600000 (stub, unused by RTL)
    // ioctl_index 0x03: sound ROM  → SDRAM base 0x800000 (X1-010 stub, unused)
    // ioctl_index 0xFE: DIP switches (handled by dsw[] registers, not SDRAM)
    .ioctl_wr   (ioctl_wr & ioctl_download & (ioctl_index != 8'hFE)),
    .ioctl_addr (ioctl_index == 8'h00 ? ioctl_addr :
                 ioctl_index == 8'h01 ? (ioctl_addr + 27'h200000) :
                 ioctl_index == 8'h02 ? (ioctl_addr + 27'h600000) :
                 ioctl_index == 8'h03 ? (ioctl_addr + 27'h800000) :
                                         ioctl_addr),
    .ioctl_dout (ioctl_dout),

    // CH1: 68000 program ROM
    .cpu_addr   (cpu_sdr_addr),
    .cpu_data   (cpu_sdr_data),
    .cpu_req    (cpu_sdr_req),
    .cpu_ack    (cpu_sdr_ack),

    // CH2: GFX ROM (X1-001A)
    .gfx_addr   (gfx_sdr_addr),
    .gfx_data   (gfx_sdr_data),
    .gfx_req    (gfx_sdr_req),
    .gfx_ack    (gfx_sdr_ack),

    // CH3: Z80 ROM (stub — tied off; seta_arcade has no Z80)
    .z80_addr   (z80_sdr_addr),
    .z80_data   (z80_sdr_data),
    .z80_req    (z80_sdr_req),
    .z80_ack    (z80_sdr_ack),

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
// MC68000 CPU (fx68k_adapter)
//////////////////////////////////////////////////////////////////

wire [23:1] cpu_addr;
wire [15:0] cpu_din;      // seta_arcade → CPU (read data from bus mux)
wire [15:0] cpu_dout;     // CPU → seta_arcade (write data)
wire        cpu_rw;
wire        cpu_uds_n;
wire        cpu_lds_n;
wire        cpu_as_n;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire [2:0]  cpu_fc;
wire        cpu_reset_n_out;
wire        cpu_inta_n;

fx68k_adapter u_cpu
(
    .clk             (clk_sys),
    .cpu_ce          (ce_cpu),
    .reset_n         (reset_n),

    .cpu_addr        (cpu_addr),
    .cpu_din         (cpu_din),
    .cpu_dout        (cpu_dout),
    .cpu_rw          (cpu_rw),
    .cpu_uds_n       (cpu_uds_n),
    .cpu_lds_n       (cpu_lds_n),
    .cpu_as_n        (cpu_as_n),
    .cpu_dtack_n     (cpu_dtack_n),
    .cpu_ipl_n       (cpu_ipl_n),
    .cpu_fc          (cpu_fc),
    .cpu_inta_n      (cpu_inta_n),
    .cpu_reset_n_out (cpu_reset_n_out)
);

//////////////////////////////////////////////////////////////////
// SETA 1 Core (Dragon Unit default parameters)
//
// Default wiring matches Dragon Unit (drgnunit):
//   WRAM at 0xFFC000–0xFFFFFF (16KB)
//   Sprite Y RAM at 0xD00000–0xD005FF
//   Sprite Code RAM at 0xE00000–0xE03FFF
//   Palette at 0x700000–0x7003FF
//
// To support other games (Blandia, Rezon, etc.) a game-select register
// or compile-time parameter override would be needed. For the initial
// core release, Dragon Unit defaults are used — games with compatible
// memory maps will work; Blandia needs tb_top-style param changes.
//////////////////////////////////////////////////////////////////

wire [4:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;

seta_arcade #(
    // Dragon Unit (drgnunit) parameters
    .WRAM_BASE       (23'h3FF000),  // 0xFFC000 / 2
    .WRAM_ABITS      (13),          // 16KB
    .PAL1_BASE       (23'h380000),  // 0x700000 / 2
    .PAL1_ABITS      (11),          // 4KB palette
    .SRAM_Y_BASE     (23'h680000),  // 0xD00000 / 2
    .SRAM_C_BASE     (23'h700000),  // 0xE00000 / 2
    .DIP_BASE        (23'h300000),  // 0x600000 / 2
    .JOY_BASE        (23'h580000),  // 0xB00000 / 2
    .H_VISIBLE       (384),
    .H_TOTAL         (512),
    .V_VISIBLE       (240),
    .V_TOTAL         (262),
    .FG_NOFLIP_YOFFS (16),          // drgnunit: 0x10
    .FG_NOFLIP_XOFFS (0),
    .SPRITE_LIMIT    (511)
) u_seta
(
    .clk_sys         (clk_sys),
    .clk_pix         (ce_pix),
    .reset_n         (reset_n),

    // 68000 CPU bus
    .cpu_addr        (cpu_addr),
    .cpu_din         (cpu_dout),    // CPU write data → seta_arcade
    .cpu_dout        (cpu_din),     // seta_arcade read data → CPU
    .cpu_lds_n       (cpu_lds_n),
    .cpu_uds_n       (cpu_uds_n),
    .cpu_rw          (cpu_rw),
    .cpu_as_n        (cpu_as_n),
    .cpu_dtack_n     (cpu_dtack_n),
    .cpu_ipl_n       (cpu_ipl_n),
    .cpu_fc          (cpu_fc),

    // Program ROM SDRAM channel (CH1)
    .prog_rom_addr   (cpu_sdr_addr),
    .prog_rom_data   (cpu_sdr_data),
    .prog_rom_req    (cpu_sdr_req),
    .prog_rom_ack    (cpu_sdr_ack),

    // GFX ROM (X1-001A, CH2)
    .gfx_addr        (gfx_addr_core),
    .gfx_data        (gfx_data_core),
    .gfx_req         (gfx_req_core),
    .gfx_ack         (gfx_ack_core),

    // Video output (5-bit RGB)
    .rgb_r           (core_rgb_r),
    .rgb_g           (core_rgb_g),
    .rgb_b           (core_rgb_b),
    .hsync_n         (core_hsync_n),
    .vsync_n         (core_vsync_n),
    .hblank          (core_hblank),
    .vblank          (core_vblank),

    // Player inputs (active-low)
    .joystick_p1     (joy_p1),
    .joystick_p2     (joy_p2),
    .coin            (coin),
    .service         (service),
    .dipsw1          (dsw[0]),
    .dipsw2          (dsw[1])
);

//////////////////////////////////////////////////////////////////
// Video pipeline
// arcade_video: sync-fix, colour expansion, scandoubler, gamma
//
// SETA 1 outputs 5-bit per channel (15-bit RGB).
// arcade_video expects 8-bit per channel; expand {r5, r5[4:2]}.
// SETA 1 native resolution: 384×240.
// hsync_n/vsync_n are active-low; arcade_video expects active-high.
//////////////////////////////////////////////////////////////////

wire [7:0] vga_r_exp = {core_rgb_r, core_rgb_r[4:2]};
wire [7:0] vga_g_exp = {core_rgb_g, core_rgb_g[4:2]};
wire [7:0] vga_b_exp = {core_rgb_b, core_rgb_b[4:2]};

arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) u_arcade_video
(
    .clk_video  (clk_sys),
    .ce_pix     (ce_pix),

    .RGB_in     ({vga_r_exp, vga_g_exp, vga_b_exp}),
    .HBlank     (core_hblank),
    .VBlank     (core_vblank),
    .HSync      (~core_hsync_n),    // arcade_video expects active-high
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
    cpu_inta_n,
    z80_sdr_data,
    z80_sdr_ack
};
/* verilator lint_on UNUSED */

endmodule
