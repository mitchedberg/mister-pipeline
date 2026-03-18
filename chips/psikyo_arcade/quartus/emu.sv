//============================================================================
//  Arcade: Psikyo SH201B/SH403 System
//
//  MiSTer emu top-level wrapper
//  Target games: Gunbird, Strikers 1945
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

// -------------------------------------------------------------------------
// Psikyo display parameters:
//   Primary target:    Gunbird (gunbird), Strikers 1945 (s1945)
//   Native resolution: 320 × 240 (visible), standard arcade timing
//   CPU clock:         16 MHz (32 MHz sys_clk / 2 clock-enable)
//   Pixel clock:       16 MHz (sys_clk / 2 CE)
//   RGB output:        8 bits per channel (24-bit total) from R5G5B5 palette
//   Aspect ratio:      3:4 (vertical shooter — rotated display)
//
// CPU NOTE: Real hardware uses MC68EC020 @ 16 MHz. We use MC68000 (fx68k)
//   as a placeholder until a verified 68020 core is available.
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — Program ROM (2 MB, SDRAM base 0)
//   0x01 — Sprite / GFX ROM (to SDRAM 0x200000)
//   0x02 — BG tile ROM (to SDRAM 0x600000)
//   0x03 — Z80 sound ROM (to SDRAM 0xA80000)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB):
//   0x000000 – 0x1FFFFF   2 MB    CPU program ROM
//   0x200000 – 0x5FFFFF   4 MB    Sprite ROM (PS2001B / Gate 3)
//   0x600000 – 0x9FFFFF   4 MB    BG tile ROM (PS3103 / Gate 4)
//   0xA80000 – 0xA87FFF   32KB    Z80 sound ROM
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

    //Video aspect ratio for HDMI.
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

    // I/O board button press simulation (active high)
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
    //Secondary SDRAM
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

// Audio: wired to YM2610B (jt10) in psikyo_arcade — see below

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio
// Psikyo vertical shooters: 3:4 (rotated portrait display)
// status[122:121]: 00=original 3:4, 01=fullscreen, 10=ARC1, 11=ARC2
//////////////////////////////////////////////////////////////////
wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 13'd3 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 13'd4 : 13'd0;

//////////////////////////////////////////////////////////////////
// OSD / HPS configuration string
//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
    "PsikyoArcade;;",
    "-;",
    "O[122:121],Aspect ratio,Original 3:4,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "R[0],Reset;",
    // Psikyo vertical shooters: 2 joysticks + 3 buttons + start + coin
    "J1,Shot,Bomb,Btn3,Start,Coin;",
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
// Psikyo system clock: 32 MHz (CPU at 16 MHz via /2 CE).
// Pixel clock: 16 MHz (sys_clk / 2 CE).
// SDRAM clock: 143 MHz (PLL outclk_1), phase-shifted.
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
//   Pixel clock (clk_pix) uses ce_pix = ce_cpu.
//////////////////////////////////////////////////////////////////
logic ce_cpu;       // high one out of every 2 sys_clk cycles (32 MHz / 2 = 16 MHz)

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        ce_cpu <= 1'b0;
    else
        ce_cpu <= ~ce_cpu;
end

// Pixel clock enable: same rate as CPU clock (16 MHz).
wire ce_pix = ce_cpu;

//////////////////////////////////////////////////////////////////
// Sound clock enable — 8 MHz (clk_sys / 4)
//
// clk_sys = 32 MHz, target = 8 MHz → fire every 4th cycle.
// YM2610B hardware clock is 8 MHz (32 MHz / 4 ≈ 8 MHz).
//////////////////////////////////////////////////////////////////
logic [1:0] snd_clk_div;
logic       clk_sound;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        snd_clk_div <= 2'd0;
        clk_sound   <= 1'b0;
    end else begin
        if (snd_clk_div == 2'd3) begin
            snd_clk_div <= 2'd0;
            clk_sound   <= 1'b1;
        end else begin
            snd_clk_div <= snd_clk_div + 2'd1;
            clk_sound   <= 1'b0;
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
// Input mapping for Psikyo vertical shooters
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1(Shot) [5]=B2(Bomb) [6]=B3 [7]=B4
//   [8]=Start [9]=Coin
//
// psikyo_arcade expects active-low inputs.
// joystick_p1[7:0]: [3:0]=UDLR, [7:4]=Btn3/Bomb/Shot/START (active-low)
//
// MiSTer CONF_STR "J1,Shot,Bomb,Btn3,Start,Coin" assigns:
//   Shot=[4] Bomb=[5] Btn3=[6] Start=[7] Coin=[8]
//   service (unmapped) at [9]
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
// Provides four channels to psikyo_arcade:
//   prog_*  — CPU program ROM reads (16-bit)
//   spr_*   — Sprite ROM reads (16-bit, byte-selected)
//   bg_*    — BG tile ROM reads (16-bit, byte-selected)
//   adpcm_* — ADPCM ROM reads for YM2610B (16-bit, byte-selected)
// Plus ioctl write path for ROM download.
//
// SDRAM CH3 is shared between BG tile ROM and ADPCM ROM via a simple
// priority arbiter.  BG takes priority over ADPCM (scanline-critical).
// ADPCM ROM data goes to psikyo_arcade which routes it to jt10.
//////////////////////////////////////////////////////////////////

wire [26:0] prog_sdr_addr;
wire [15:0] prog_sdr_data;
wire        prog_sdr_req, prog_sdr_ack;

wire [26:0] spr_sdr_addr;
wire [15:0] spr_sdr_data;
wire        spr_sdr_req, spr_sdr_ack;

// BG tile ROM — connected to CH3 via arbiter
wire [26:0] bg_sdr_addr;
wire [15:0] bg_sdr_data;
wire        bg_sdr_req, bg_sdr_ack;

// ADPCM ROM — connected to CH3 via arbiter (from psikyo_arcade)
wire [26:0] adpcm_sdr_addr;
wire [15:0] adpcm_sdr_data;
wire        adpcm_sdr_req, adpcm_sdr_ack;

//----------------------------------------------------------------
// CH3 arbiter: BG, ADPCM, and Z80 ROM share the single adpcm port on sdram_b.
// Priority: BG (scanline-critical) > ADPCM > Z80 ROM (background fetch).
//   owner: 0=BG, 1=ADPCM, 2=Z80 ROM
//----------------------------------------------------------------
wire [26:0] ch3_addr;
wire        ch3_req;
wire [15:0] ch3_data_out;
wire        ch3_ack;

// Z80 ROM wires
wire [15:0] z80_rom_addr_w;
wire        z80_sdr_req, z80_sdr_ack;
wire  [7:0] z80_sdr_byte;

// Byte lane select for Z80 ROM (addr bit 0)
assign z80_sdr_byte = z80_rom_addr_w[0] ? ch3_data_out[15:8] : ch3_data_out[7:0];

logic [1:0] ch3_owner;   // 0=BG, 1=ADPCM, 2=Z80
logic ch3_busy;

wire bg_pend    = (bg_sdr_req    != bg_sdr_ack);
wire adpcm_pend = (adpcm_sdr_req != adpcm_sdr_ack);
wire z80_pend   = (z80_sdr_req   != z80_sdr_ack);

logic ch3_req_r;
logic [26:0] ch3_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ch3_req_r  <= 1'b0;
        ch3_addr_r <= 27'b0;
        ch3_owner  <= 2'd0;
        ch3_busy   <= 1'b0;
    end else begin
        if (!ch3_busy) begin
            if (bg_pend) begin
                ch3_addr_r <= bg_sdr_addr;
                ch3_req_r  <= ~ch3_req_r;
                ch3_owner  <= 2'd0;
                ch3_busy   <= 1'b1;
            end else if (adpcm_pend) begin
                ch3_addr_r <= adpcm_sdr_addr;
                ch3_req_r  <= ~ch3_req_r;
                ch3_owner  <= 2'd1;
                ch3_busy   <= 1'b1;
            end else if (z80_pend) begin
                // Z80 ROM at SDRAM 0xA80000; z80_rom_addr_w is 16-bit byte addr
                ch3_addr_r <= 27'hA80000 + {11'b0, z80_rom_addr_w[15:1]};
                ch3_req_r  <= ~ch3_req_r;
                ch3_owner  <= 2'd2;
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

// Route ack back to the winning client
assign bg_sdr_ack    = (ch3_owner == 2'd0) ? ch3_ack : bg_sdr_req;
assign adpcm_sdr_ack = (ch3_owner == 2'd1) ? ch3_ack : adpcm_sdr_req;
assign z80_sdr_ack   = (ch3_owner == 2'd2) ? ch3_ack : z80_sdr_req;

// Route read data back to the winning client (all see the same 16-bit word;
// byte-lane selection for Z80 is done above via z80_sdr_byte)
assign bg_sdr_data    = ch3_data_out;
assign adpcm_sdr_data = ch3_data_out;

sdram_b u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .reset_n    (reset_n),

    // CH0: HPS ROM download write path
    .ioctl_wr   (ioctl_wr & ioctl_download),
    .ioctl_addr (ioctl_addr),
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

    // CH3: BG / ADPCM ROM reads (arbitrated above)
    .adpcm_addr (ch3_addr),
    .adpcm_data (ch3_data_out),
    .adpcm_req  (ch3_req),
    .adpcm_ack  (ch3_ack),

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
// psikyo_arcade core
//////////////////////////////////////////////////////////////////

wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;

//////////////////////////////////////////////////////////////////
// fx68k_adapter — MC68000 @ 16 MHz (placeholder for MC68EC020)
//////////////////////////////////////////////////////////////////

wire [23:1] cpu_addr;
wire [15:0] cpu_din;      // psikyo_arcade → CPU (read data)
wire [15:0] cpu_dout;     // CPU → psikyo_arcade (write data)
wire        cpu_rw;
wire        cpu_uds_n;
wire        cpu_lds_n;
wire        cpu_as_n;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire        cpu_reset_n_out;

fx68k_adapter u_cpu (
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
    .cpu_reset_n_out (cpu_reset_n_out)
);

wire signed [15:0] core_snd_left, core_snd_right;

psikyo_arcade u_psikyo_arcade
(
    .clk_sys         (clk_sys),
    .clk_pix         (ce_pix),
    .clk_sound       (clk_sound),
    .reset_n         (reset_n),

    // CPU bus
    .cpu_addr        (cpu_addr),
    .cpu_dout        (cpu_dout),    // CPU write data → core
    .cpu_din         (cpu_din),     // core read data → CPU
    .cpu_rw          (cpu_rw),
    .cpu_as_n        (cpu_as_n),
    .cpu_uds_n       (cpu_uds_n),
    .cpu_lds_n       (cpu_lds_n),
    .cpu_dtack_n     (cpu_dtack_n),
    .cpu_ipl_n       (cpu_ipl_n),

    // Program ROM
    .prog_rom_addr   (prog_sdr_addr),
    .prog_rom_data   (prog_sdr_data),
    .prog_rom_req    (prog_sdr_req),
    .prog_rom_ack    (prog_sdr_ack),

    // Sprite ROM
    .spr_rom_addr    (spr_sdr_addr),
    .spr_rom_data16  (spr_sdr_data),
    .spr_rom_req     (spr_sdr_req),
    .spr_rom_ack     (spr_sdr_ack),

    // BG tile ROM
    .bg_rom_addr     (bg_sdr_addr),
    .bg_rom_data16   (bg_sdr_data),
    .bg_rom_req      (bg_sdr_req),
    .bg_rom_ack      (bg_sdr_ack),

    // ADPCM ROM (YM2610B, shared CH3 via arbiter above)
    .adpcm_rom_addr  (adpcm_sdr_addr),
    .adpcm_rom_data  (adpcm_sdr_data),
    .adpcm_rom_req   (adpcm_sdr_req),
    .adpcm_rom_ack   (adpcm_sdr_ack),

    // Audio output
    .snd_left        (core_snd_left),
    .snd_right       (core_snd_right),

    // Video output
    .rgb_r           (core_rgb_r),
    .rgb_g           (core_rgb_g),
    .rgb_b           (core_rgb_b),
    .hsync_n         (core_hsync_n),
    .vsync_n         (core_vsync_n),
    .hblank          (core_hblank),
    .vblank          (core_vblank),

    // Player inputs
    .joystick_p1     (joy_p1),
    .joystick_p2     (joy_p2),
    .coin            (coin),
    .service         (service),
    .dipsw1          (dsw[0]),
    .dipsw2          (dsw[1]),

    // Z80 sound ROM (shared CH3 via arbiter)
    .z80_rom_addr    (z80_rom_addr_w),
    .z80_rom_req     (z80_sdr_req),
    .z80_rom_data    (z80_sdr_byte),
    .z80_rom_ack     (z80_sdr_ack)
);

// Route YM2610B audio to MiSTer AUDIO_L/R
assign AUDIO_L = core_snd_left;
assign AUDIO_R = core_snd_right;

//////////////////////////////////////////////////////////////////
// Video pipeline
//////////////////////////////////////////////////////////////////

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) u_arcade_video
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
