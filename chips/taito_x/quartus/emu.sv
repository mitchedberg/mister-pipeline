//============================================================================
//  Arcade: Taito X System
//
//  MiSTer emu top-level wrapper
//  Copyright (C) 2026
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
// Taito X display parameters:
//   Primary targets:   Superman (superman), Twin Hawk (twinhawk/daisenpu),
//                      Gigandes, Balloon Brothers, Last Striker, Liquid Kids
//   Native resolution: 384 × 240 (visible), arcade timing from video_timing module
//   Main CPU:         MC68000 @ 8 MHz (32 MHz sys_clk / 4 clock-enable)
//   Sound CPU:        Z80 @ 4 MHz (32 MHz sys_clk / 8 clock-enable)
//   Pixel clock:      8 MHz (sys_clk / 4 CE)
//   Audio chip:       YM2610 OPNB (most games) or YM2151 OPM (Twin Hawk)
//   RGB output:       5 bits per channel (15-bit total) from xRGB_555 palette
//   Aspect ratio:     4:3 (384×240 at 1:1 pixels)
//
// Hardware clock relationships:
//   16 MHz crystal → 68000 @ 8 MHz (÷2), Z80 @ 4 MHz (÷4)
//   PLL generates 32 MHz for FPGA (2× master), SDRAM at 143 MHz
//   Clock enables derived from 32 MHz: /4 = 8 MHz CPU/pix, /8 = 4 MHz Z80
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — 68000 program ROM + Z80 audio ROM (sequential, SDRAM base 0)
//   0x01 — Sprite/GFX ROM (X1-001A tile data, SDRAM 0x100000)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F-6TL, 32 MB, byte addresses):
//   0x000000 – 0x07FFFF    512KB   68000 program ROM
//   0x080000 – 0x09FFFF    128KB   Z80 audio program
//   0x0A0000 – 0x0FFFFF    (pad to 1MB boundary)
//   0x100000 – 0x4FFFFF      4MB   Sprite / Tile GFX ROM (X1-001A)
//   0x500000 – 0x5FFFFF    (spare)
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

// Audio: silence until YM2610/YM2151 module is implemented
assign AUDIO_L = 16'h0;
assign AUDIO_R = 16'h0;

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — Taito X is 4:3
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
    "TaitoX;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "R[0],Reset;",
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
// Taito X hardware clock: 16 MHz (master crystal).
// FPGA: PLL generates 32 MHz (2× master) to allow /N clock-enables.
//   68000: /4 → 8 MHz effective
//   Z80:   /8 → 4 MHz effective
//   Pixel: /4 → 8 MHz  (~9.2 MHz hardware; close enough for NTSC timing)
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
// ce_cpu:   1 of every 4 sys_clk cycles → 8 MHz for 68000
// ce_z80:   1 of every 8 sys_clk cycles → 4 MHz for Z80
// ce_pix:   same rate as ce_cpu → 8 MHz pixel clock
//////////////////////////////////////////////////////////////////

logic [2:0] ce_cnt;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) ce_cnt <= 3'd0;
    else          ce_cnt <= ce_cnt + 3'd1;
end

wire ce_cpu = (ce_cnt[1:0] == 2'b00);   // every 4 cycles = 8 MHz
wire ce_z80 = (ce_cnt == 3'd0);          // every 8 cycles = 4 MHz
wire ce_pix = ce_cpu;                    // pixel clock = 8 MHz (tied to CPU CE)

//////////////////////////////////////////////////////////////////
// Reset
//
// Hold reset for 256 cycles after ROM download completes to allow
// SDRAM refresh to re-align.
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
// Input mapping
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1 [5]=B2 [6]=B3 [7]=B4
//   [8]=Start [9]=Coin
//
// Taito X expects active-low inputs.
// joystick_p1[7:0]: [3:0]=UDLR, [7:4]=B4..B1 (active-low)
//////////////////////////////////////////////////////////////////

wire [7:0] joy_p1 = ~{ joystick_0[7], joystick_0[6], joystick_0[5], joystick_0[4],
                       joystick_0[3], joystick_0[2], joystick_0[1], joystick_0[0] };
wire [7:0] joy_p2 = ~{ joystick_1[7], joystick_1[6], joystick_1[5], joystick_1[4],
                       joystick_1[3], joystick_1[2], joystick_1[1], joystick_1[0] };

wire [1:0] coin    = ~{ joystick_1[9], joystick_0[9] };
wire       service = ~joystick_0[10];

//////////////////////////////////////////////////////////////////
// SDRAM controller
//
// CH0: HPS ROM download write path
// CH1: 68000 program ROM reads
// CH2: X1-001A GFX ROM reads
// CH3: Z80 audio ROM reads
//////////////////////////////////////////////////////////////////

// cpu_sdr_* are driven by taito_x.sdr_addr/sdr_req; taito_x drives them as assign 0.
// emu.sv will extend taito_x to properly proxy CPU ROM reads (future work).
wire  [26:0] cpu_sdr_addr;
wire  [15:0] cpu_sdr_data;
wire         cpu_sdr_req, cpu_sdr_ack;

// gfx_sdr_* combinationally computed from gfx_addr_core
wire  [26:0] gfx_sdr_addr;
wire  [15:0] gfx_sdr_data;
wire         gfx_sdr_req, gfx_sdr_ack;

// z80_sdr_* driven by always_ff (registered request)
logic [26:0] z80_sdr_addr;
wire  [15:0] z80_sdr_data;
logic        z80_sdr_req;
wire         z80_sdr_ack;

// GFX ROM request bridge: taito_x core exports 18-bit word address from x1_001a.
// SDRAM byte address = GFX_BASE + (gfx_addr_core[17:0] * 2)
// GFX ROM SDRAM base: 0x100000 (byte address)
localparam logic [26:0] GFX_ROM_BASE = 27'h100000;

wire [17:0] gfx_addr_core;
wire [15:0] gfx_data_core;
wire        gfx_req_core, gfx_ack_core;

// Bridge: 18-bit word address from x1_001a → 27-bit SDRAM word address
// (one word = 2 bytes; SDRAM is 16-bit wide)
assign gfx_sdr_addr = GFX_ROM_BASE + {9'b0, gfx_addr_core};
assign gfx_data_core = gfx_sdr_data;
// Pass toggle-req through directly (same polarity)
assign gfx_sdr_req = gfx_req_core;
assign gfx_ack_core = gfx_sdr_ack;

sdram_x u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .reset_n    (reset_n),

    // CH0: HPS ROM download
    .ioctl_wr   (ioctl_wr & ioctl_download),
    .ioctl_addr (ioctl_addr),
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

    // CH3: Z80 audio ROM
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
wire [15:0] cpu_din;      // taito_x → CPU (read data from bus mux)
wire [15:0] cpu_dout;     // CPU → taito_x (write data)
wire        cpu_rw;
wire        cpu_uds_n;
wire        cpu_lds_n;
wire        cpu_as_n;
wire        cpu_dtack_n;
wire [2:0]  cpu_ipl_n;
wire        cpu_reset_n_out;

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
    .cpu_reset_n_out (cpu_reset_n_out)
);

//////////////////////////////////////////////////////////////////
// Z80 Sound CPU (T80pa_wrapper)
//
// The T80pa (T80 with pre-fetch) is the standard MiSTer Z80 soft-core.
// It is instantiated with a simple clock-enable interface.
// Source: sys/T80pa.v (from MiSTer framework)
//
// The Z80 has two memory spaces managed externally:
//   ROM: SDRAM CH3 (0x000000+z80_addr, max 32KB)
//   RAM: local BRAM 8KB (0xC000–0xDFFF)
//
// I/O: Sound command latch at port 0x00 (read command from 68000,
//      write ACK back). YM chip at I/O port 0x01/0x03 (wired to
//      YM2610/YM2151 instantiated externally or stubbed below).
//
// Z80 ROM/RAM chip-selects: driven by taito_x module.
//////////////////////////////////////////////////////////////////

wire [15:0] z80_addr;
wire  [7:0] z80_din;   // taito_x → Z80 (mux of ROM, RAM, I/O read data)
wire  [7:0] z80_dout;  // Z80 → taito_x (write data)
wire        z80_rd_n;
wire        z80_wr_n;
wire        z80_mreq_n;
wire        z80_iorq_n;
wire        z80_int_n;
wire        z80_reset_n;
wire        z80_rom_cs_n;
wire        z80_ram_cs_n;

// Z80 work RAM (8KB = 4096 × 16-bit internally stored as bytes, accessed as 8-bit bus)
logic [7:0] z80_ram [0:8191];
logic [7:0] z80_ram_dout;

always_ff @(posedge clk_sys) begin
    if (!z80_ram_cs_n && !z80_wr_n)
        z80_ram[z80_addr[12:0]] <= z80_dout;
end
always_ff @(posedge clk_sys)
    z80_ram_dout <= z80_ram[z80_addr[12:0]];

// Z80 ROM: fetch from SDRAM CH3
// Z80 ROM address = SDRAM 0x080000 + z80_addr (byte address → SDRAM word)
// Toggle-req handshake: assert when Z80 does a ROM read cycle
logic z80_rom_req_r;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        z80_sdr_req    <= 1'b0;
        z80_rom_req_r  <= 1'b0;
    end else begin
        // Issue SDRAM request on falling edge of z80_rom_cs_n (ROM active)
        if (!z80_rom_cs_n && !z80_rd_n && !z80_mreq_n && !z80_rom_req_r) begin
            // SDRAM byte address for Z80 ROM (base 0x080000, word-addressed)
            z80_sdr_addr  <= 27'h040000 + {12'b0, z80_addr[15:1]};
            z80_sdr_req   <= ~z80_sdr_req;
            z80_rom_req_r <= 1'b1;
        end else if (z80_rom_cs_n) begin
            z80_rom_req_r <= 1'b0;
        end
    end
end

// Z80 data mux: select ROM, RAM, or I/O
wire [7:0] z80_rom_byte = z80_addr[0] ? z80_sdr_data[7:0] : z80_sdr_data[15:8];
wire [7:0] z80_core_din;

// z80_din comes from taito_x core (which handles I/O decoding)
// but RAM and ROM must be muxed here before feeding into core
wire [7:0] z80_io_dout;   // from taito_x I/O decoder (sound command)

// z80_din fed to Z80 core: priority ROM > RAM > I/O
assign z80_core_din = !z80_rom_cs_n ? z80_rom_byte
                    : !z80_ram_cs_n  ? z80_ram_dout
                    :                  z80_io_dout;

// T80pa: standard MiSTer Z80 soft-core (T80 with pipeline)
// Source: sys/T80pa.v in MiSTer framework
T80pa u_z80
(
    .RESET_n (z80_reset_n),
    .CLK     (clk_sys),
    .CEN_p   (ce_z80),
    .CEN_n   (1'b0),           // negative edge CE not used (CEN_p drives all)

    .WAIT_n  (1'b1),           // no WAIT state
    .INT_n   (z80_int_n),
    .NMI_n   (1'b1),           // no NMI
    .BUSRQ_n (1'b1),           // no bus request

    .M1_n    (),
    .MREQ_n  (z80_mreq_n),
    .IORQ_n  (z80_iorq_n),
    .RD_n    (z80_rd_n),
    .WR_n    (z80_wr_n),
    .RFSH_n  (),
    .HALT_n  (),
    .BUSAK_n (),

    .A       (z80_addr),
    .DI      (z80_core_din),
    .DO      (z80_dout)
);

//////////////////////////////////////////////////////////////////
// Taito X Core
//////////////////////////////////////////////////////////////////

wire [4:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;

taito_x #(
    // Superman (default) parameters
    .FG_NOFLIP_YOFFS (-18),
    .FG_NOFLIP_XOFFS (0),
    .SPRITE_LIMIT    (511),
    .COLOR_BASE      (0)
) u_taito_x
(
    .clk_sys         (clk_sys),
    .clk_pix         (ce_pix),
    .reset_n         (reset_n),

    // 68000 bus
    .cpu_addr        (cpu_addr),
    .cpu_din         (cpu_dout),   // CPU write data → taito_x
    .cpu_dout        (cpu_din),    // taito_x read data → CPU
    .cpu_lds_n       (cpu_lds_n),
    .cpu_uds_n       (cpu_uds_n),
    .cpu_rw          (cpu_rw),
    .cpu_as_n        (cpu_as_n),
    .cpu_dtack_n     (cpu_dtack_n),
    .cpu_ipl_n       (cpu_ipl_n),

    // Z80 sound bus
    .z80_addr        (z80_addr),
    .z80_din         (z80_dout),   // Z80 write data → taito_x sound latch
    .z80_dout        (z80_io_dout),
    .z80_rd_n        (z80_rd_n),
    .z80_wr_n        (z80_wr_n),
    .z80_mreq_n      (z80_mreq_n),
    .z80_iorq_n      (z80_iorq_n),
    .z80_int_n       (z80_int_n),
    .z80_reset_n     (z80_reset_n),
    .z80_rom_cs_n    (z80_rom_cs_n),
    .z80_ram_cs_n    (z80_ram_cs_n),

    // GFX ROM (X1-001A toggle handshake)
    .gfx_addr        (gfx_addr_core),
    .gfx_data        (gfx_data_core),
    .gfx_req         (gfx_req_core),
    .gfx_ack         (gfx_ack_core),

    // SDRAM (program ROM — via cpu_sdr_* pass-through, not used inside core)
    .sdr_addr        (cpu_sdr_addr),
    .sdr_data        (cpu_sdr_data),
    .sdr_req         (cpu_sdr_req),
    .sdr_ack         (cpu_sdr_ack),

    // Video output
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
// Taito X outputs 5-bit per channel (15-bit RGB).
// arcade_video expects 8-bit per channel; expand {r5, r5[4:2]} (top 3 bits).
// Taito X native resolution: 384×240.
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
    joystick_0[31:10], joystick_1[31:10],
    dsw[2], dsw[3],
    cpu_reset_n_out
};
/* verilator lint_on UNUSED */

endmodule
