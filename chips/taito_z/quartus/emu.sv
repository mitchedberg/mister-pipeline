//============================================================================
//  Arcade: Taito Z System
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
// Taito Z display parameters:
//   Primary target:    Double Axle (dblaxle); Racing Beat (racingb) variant
//   Native resolution: 320 × 240 (visible), arcade timing from TC0480SCP
//   CPU A clock:      16 MHz (32 MHz sys_clk / 2 clock-enable)
//   CPU B clock:      16 MHz (32 MHz sys_clk / 2 clock-enable, opposite phase)
//   Pixel clock:      16 MHz (sys_clk / 2 CE)
//   RGB output:       8 bits per channel (24-bit total) from xBGR_555 palette
//   Aspect ratio:     4:3
//
// Key differences from Taito F3:
//   - Dual MC68000 (not 68EC020) — two 16-bit CPUs at 16 MHz each
//   - TC0480SCP tilemap (not TC0630FDP)
//   - TC0150ROD road chip on CPU B bus
//   - TC0370MSO sprite scanner + TC0300FLA line buffer
//   - TC0140SYT sound comms (not MB8421)
//   - TC0510NIO I/O chip (not TC0640FIO)
//   - Simple xBGR_555 BRAM palette (not TC0650FDA with alpha blend)
//   - Audio: YM2610 (stubbed for now — silence)
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — CPU A prog ROM, CPU B prog ROM, Z80 ROM (sequential, SDRAM base 0)
//   0x01 — SCR GFX ROM (TC0480SCP tile data, SDRAM 0x100000)
//   0x02 — Sprite OBJ GFX ROM (TC0370MSO, SDRAM 0x200000)
//   0x03 — Road ROM (TC0150ROD, SDRAM 0x600000)
//   0x04 — STY spritemap ROM (TC0370MSO, SDRAM 0x680000)
//   0x05 — ADPCM sample ROMs (YM2610, SDRAM 0x700000)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F-6TL, 32 MB):
//   0x000000 – 0x07FFFF   512KB   CPU A program ROM
//   0x080000 – 0x0BFFFF   256KB   CPU B program ROM
//   0x0C0000 – 0x0DFFFF   128KB   Z80 audio program
//   0x0E0000 – 0x0FFFFF   128KB   (pad to 1MB boundary)
//   0x100000 – 0x1FFFFF     1MB   TC0480SCP SCR GFX ROM
//   0x200000 – 0x5FFFFF     4MB   Sprite OBJ GFX ROM
//   0x600000 – 0x67FFFF   512KB   TC0150ROD road data
//   0x680000 – 0x6FFFFF   512KB   STY spritemap ROM
//   0x700000 – 0x87FFFF   1.5MB   ADPCM-A samples
//   0x880000 – 0x8FFFFF   512KB   ADPCM-B samples
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

// Audio: wired to YM2610 (jt10) snd_left/snd_right below

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio — Taito Z is 4:3
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
    "TaitoZ;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "R[0],Reset;",
    // Taito Z racing games: wheel/pedal + 2 buttons + start + coin
    "J1,Brake,Gear,Start,Coin;",
    "jn,A,B,Start,Select;",
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

// hps_io provides analog axes: joystick_l_analog_0[7:0]=X, [15:8]=Y
wire [15:0] joystick_l_analog_0;

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
    .joystick_1     (joystick_1),

    .joystick_l_analog_0 (joystick_l_analog_0)
);

//////////////////////////////////////////////////////////////////
// Clocks
//
// Taito Z system clock: 32 MHz (double 16 MHz CPU rate).
// Each CPU uses a /2 clock enable for precise 16 MHz operation.
// TC0480SCP pixel clock: same /2 clock enable = 16 MHz pixel clock.
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
//   CPU A uses ce_cpu when it is 1 (even phases).
//   CPU B uses ce_cpu_b (odd phases) for tight interleave.
//   TC0480SCP pixel clock (clk_pix) uses ce_pix = ce_cpu.
//////////////////////////////////////////////////////////////////
logic ce_cpu;       // high one out of every 2 sys_clk cycles (even)
logic ce_cpu_b;     // high one out of every 2 sys_clk cycles (odd)

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_cpu   <= 1'b0;
        ce_cpu_b <= 1'b1;
    end else begin
        ce_cpu   <= ~ce_cpu;
        ce_cpu_b <= ~ce_cpu_b;
    end
end

// Pixel clock enable: same rate as CPU clock (16 MHz).
wire ce_pix = ce_cpu;

// Sound clock enable: 4 MHz (32 MHz / 8).
// The YM2610 and Z80 both run at ~4 MHz on the Taito Z hardware.
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
// Input mapping for Taito Z racing games
//
// MiSTer CONF_STR "J1,Brake,Gear,Start,Coin" assigns:
//   Brake=[4] Gear=[5] Start=[6] Coin=[7]
//   service (unmapped) at [8]
//
// TC0510NIO expects active-low inputs (joystick_p1[7:0]):
//   [3:0] = UP/DOWN/LEFT/RIGHT (active-low directions)
//   [7:4] = BTN3/BTN2/Gear/Start  (active-low)
//   (Brake/gas handled via pedal_in analog/digital path below)
//
// Steering wheel: mapped from analog axis (joystick_l_analog_0[7:0])
//   or synthesized from digital left/right for gamepads.
// Gas pedal: mapped from analog axis (joystick_l_analog_0[15:8])
//   or Brake button [4] for digital-only.
//////////////////////////////////////////////////////////////////
// joy_p1[7:4] = B3(unused)/B2(unused)/Gear/Start  [7:4]=active-low
// joy_p1[3:0] = RLDU  (Brake/gas routed via pedal_in)
wire [7:0] joy_p1 = ~{ 1'b0, 1'b0, joystick_0[5], joystick_0[6],
                       joystick_0[3], joystick_0[2], joystick_0[1], joystick_0[0] };
wire [7:0] joy_p2 = ~{ 1'b0, 1'b0, joystick_1[5], joystick_1[6],
                       joystick_1[3], joystick_1[2], joystick_1[1], joystick_1[0] };

wire [1:0] coin    = ~{ joystick_1[7], joystick_0[7] };   // active-low
wire       service = ~joystick_0[8];                       // active-low

// Steering wheel: use analog X axis if connected, else synthesize from d-pad
// joystick_l_analog_0[7:0] = X axis (-128..+127, signed); remap to 0..255
wire [7:0] wheel_analog = joystick_l_analog_0[7:0] + 8'h80;

// Synthesized wheel from digital pad: center=0x80, full left=0x00, full right=0xFF
wire [7:0] wheel_digital = joystick_0[1] ? 8'h00 :   // left
                           joystick_0[0] ? 8'hFF :   // right
                                           8'h80;    // center

// Use analog if any axis movement detected (non-center), else digital
wire analog_present = (joystick_l_analog_0[7:0] != 8'h00);
wire [7:0] wheel_in = analog_present ? wheel_analog : wheel_digital;

// Gas pedal: analog Y axis (joystick_l_analog_0[15:8]) or Brake button [4]
wire [7:0] pedal_analog  = joystick_l_analog_0[15:8] + 8'h80;
wire [7:0] pedal_digital = joystick_0[4] ? 8'hFF : 8'h00;  // Brake = full gas
wire [7:0] pedal_in      = analog_present ? pedal_analog : pedal_digital;

//////////////////////////////////////////////////////////////////
// SDRAM controller
//
// Provides four channels to the taito_z core:
//   cpu_*  — CPU A/B program ROM reads (16-bit)
//   gfx_*  — TC0480SCP tile GFX + STY spritemap (16-bit arbiter below)
//   obj_*  — Sprite OBJ GFX + TC0150ROD road ROM (16-bit arbiter below)
// Plus ioctl write path for ROM download.
//
// The taito_z core's multi-port ROM interfaces (4×32-bit gfx, 64-bit spr)
// are handled by thin arbiters in this file that pack/unpack from the
// single 16-bit SDRAM read channels.
//////////////////////////////////////////////////////////////////

// ── CH1: CPU A/B program ROM (single 16-bit port, arbitrated here) ──────────
// taito_z's sdr_* port carries the ADPCM ROM arbiter (from TC0140SYT).
// CPU A and CPU B fetch program ROMs at startup through separate addresses.
// We present a single 16-bit read port. CPU A/B DTACK handling inside
// taito_z drives the SDRAM req. The SDRAM arbiter inside sdram_z grants
// one read per request.
wire [26:0] cpu_sdr_addr;
wire [15:0] cpu_sdr_data;
wire        cpu_sdr_req, cpu_sdr_ack;

// ── CH2: Tile GFX arbiter ────────────────────────────────────────────────────
// TC0480SCP has 4 independent 32-bit ROM ports (gfx_addr[3:0], gfx_data[3:0]).
// Each 32-bit fetch = 2 × 16-bit SDRAM reads.
// The arbiter below serialises these 8 half-word reads into the single CH2 port.
// For now: round-robin across ports [3:0], 2 sub-reads per 32-bit request.
//
// GFX base in SDRAM: 0x100000 (byte address). Each port address is a 21-bit
// byte offset within the 1MB GFX ROM window; add 0x100000 to get SDRAM byte addr.
//
wire [26:0] gfx_sdr_addr;
wire [15:0] gfx_sdr_data;
wire        gfx_sdr_req, gfx_sdr_ack;

// 4 × 32-bit GFX ports from taito_z core (TC0480SCP)
wire [3:0][22:0] gfx_addr_core;
wire [3:0][31:0] gfx_data_core;
wire [3:0]       gfx_req_core;
wire [3:0]       gfx_ack_core;

// GFX arbiter: 4-port toggle-req → single CH2 16-bit SDRAM read
// Two consecutive 16-bit reads assemble each 32-bit result.
// State machine: port_sel (0-3) selects current port; sub (0/1) selects low/high word.
logic [1:0]  garb_port;         // current port being served (0-3)
logic        garb_sub;          // 0 = reading low 16 bits, 1 = reading high 16 bits
logic [15:0] garb_lo;           // low 16 bits captured from first sub-read
logic        garb_busy;

// Snapshot the pending req toggles
logic [3:0] garb_req_r;         // previous req state for edge detection
logic [3:0] garb_pending;       // ports with pending requests
logic [3:0][24:0] garb_addr_r;  // latched word addresses per port
logic [3:0] garb_req_sent;      // track sent req (to mirror back as ack)

assign gfx_ack_core = garb_req_sent;  // ack mirrors the req we sent

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        garb_port     <= 2'd0;
        garb_sub      <= 1'b0;
        garb_busy     <= 1'b0;
        garb_lo       <= 16'h0;
        gfx_sdr_req   <= 1'b0;
        garb_req_r    <= 4'b0;
        garb_pending  <= 4'b0;
        garb_req_sent <= 4'b0;
        for (int i = 0; i < 4; i++) garb_addr_r[i] <= 25'h0;
    end else begin
        // Detect new requests on each port (toggle-edge)
        for (int i = 0; i < 4; i++) begin
            garb_req_r[i] <= gfx_req_core[i];
            if (gfx_req_core[i] != garb_req_r[i]) begin
                garb_pending[i] <= 1'b1;
                // GFX base = 0x100000 (byte). gfx_addr_core is 23-bit byte offset.
                // SDRAM word address = (0x100000 + gfx_addr_core[i]) >> 1
                garb_addr_r[i] <= 25'h0 + {2'b0, gfx_addr_core[i][22:1]};  // stub: add base offset
            end
        end

        if (!garb_busy) begin
            // Find next pending port (round-robin from garb_port+1)
            logic found;
            found = 1'b0;
            for (int k = 0; k < 4 && !found; k++) begin
                logic [1:0] p;
                p = garb_port + 2'(k + 1);
                if (garb_pending[p]) begin
                    garb_port    <= p;
                    garb_sub     <= 1'b0;
                    garb_busy    <= 1'b1;
                    garb_pending[p] <= 1'b0;
                    // Issue first (low) SDRAM read: word addr = garb_addr_r[p] + 0
                    gfx_sdr_addr <= {2'b0, garb_addr_r[p]};
                    gfx_sdr_req  <= ~gfx_sdr_req;
                    found = 1'b1;
                end
            end
        end else begin
            // Waiting for SDRAM ack
            if (gfx_sdr_ack == gfx_sdr_req) begin
                if (!garb_sub) begin
                    // Low word returned; issue high word read
                    garb_lo     <= gfx_sdr_data;
                    garb_sub    <= 1'b1;
                    gfx_sdr_addr <= {2'b0, garb_addr_r[garb_port] + 25'd1};
                    gfx_sdr_req  <= ~gfx_sdr_req;
                end else begin
                    // High word returned; assemble 32-bit result and ack the port
                    gfx_data_core[garb_port] <= {gfx_sdr_data, garb_lo};
                    garb_req_sent[garb_port] <= gfx_req_core[garb_port];  // mirror req → ack
                    garb_busy <= 1'b0;
                end
            end
        end
    end
end

// ── CH3: OBJ GFX + road ROM arbiter ─────────────────────────────────────────
// TC0370MSO requests 64-bit OBJ GFX data (spr_addr[22:0], 4 × 16-bit reads).
// TC0150ROD requests 16-bit road ROM data (rod_rom_addr[17:0] = word address).
// Arbitrate: road ROM (higher priority, simpler) vs OBJ GFX (4-sub-read burst).

wire [26:0] obj_sdr_addr;
wire [15:0] obj_sdr_data;
wire        obj_sdr_req, obj_sdr_ack;

// OBJ GFX from taito_z core
wire [22:0] spr_addr_core;
wire [63:0] spr_data_core;
wire        spr_req_core, spr_ack_core;

// Road ROM from taito_z core
wire [17:0] rod_rom_addr_core;
wire [15:0] rod_rom_data_core;
wire        rod_rom_req_core, rod_rom_ack_core;

// STY spritemap from taito_z core
wire [17:0] stym_addr_core;
wire [15:0] stym_data_core;
wire        stym_req_core, stym_ack_core;

// OBJ arbiter: 64-bit fetch = 4 × 16-bit reads
// OBJ GFX base in SDRAM: 0x200000 (byte). spr_addr_core is a 23-bit byte address
// within the 4MB OBJ region. SDRAM byte addr = 0x200000 + spr_addr_core.
logic [2:0]  oarb_sub;          // 0..3 = which 16-bit word of 64-bit burst
logic [15:0] oarb_buf [0:2];    // accumulate first 3 words
logic        oarb_busy;
logic        oarb_road_pending; // road ROM request pending
logic        oarb_stym_pending; // STY spritemap request pending
logic        oarb_spr_pending;  // OBJ sprite request pending
logic [24:0] oarb_spr_addr_r;
logic [17:0] oarb_rod_addr_r;
logic [17:0] oarb_stym_addr_r;
logic        oarb_spr_req_r;
logic        oarb_rod_req_r;
logic        oarb_stym_req_r;
logic        oarb_serving_road; // 1=serving road, 0=serving obj or stym
logic        oarb_serving_stym; // 1=serving stym

assign spr_ack_core     = oarb_spr_req_r;   // ack = mirror of accepted req
assign rod_rom_ack_core = oarb_rod_req_r;
assign stym_ack_core    = oarb_stym_req_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        oarb_sub          <= 3'h0;
        oarb_busy         <= 1'b0;
        oarb_road_pending <= 1'b0;
        oarb_stym_pending <= 1'b0;
        oarb_spr_pending  <= 1'b0;
        obj_sdr_req       <= 1'b0;
        oarb_spr_req_r    <= 1'b0;
        oarb_rod_req_r    <= 1'b0;
        oarb_stym_req_r   <= 1'b0;
        oarb_serving_road <= 1'b0;
        oarb_serving_stym <= 1'b0;
        for (int i = 0; i < 3; i++) oarb_buf[i] <= 16'h0;
        spr_data_core     <= 64'h0;
        rod_rom_data_core <= 16'h0;
        stym_data_core    <= 16'h0;
        oarb_spr_addr_r   <= 25'h0;
        oarb_rod_addr_r   <= 18'h0;
        oarb_stym_addr_r  <= 18'h0;
    end else begin
        // Detect new requests (toggle-edge)
        if (spr_req_core != oarb_spr_req_r && !oarb_spr_pending) begin
            oarb_spr_pending <= 1'b1;
            // OBJ base = 0x200000 byte → 0x100000 word. spr_addr_core is byte address.
            oarb_spr_addr_r <= 25'h100000 + {2'b0, spr_addr_core[22:1]};
        end
        if (rod_rom_req_core != oarb_rod_req_r && !oarb_road_pending) begin
            oarb_road_pending <= 1'b1;
            // Road base = 0x600000 byte → 0x300000 word.
            oarb_rod_addr_r  <= rod_rom_addr_core;
        end
        if (stym_req_core != oarb_stym_req_r && !oarb_stym_pending) begin
            oarb_stym_pending <= 1'b1;
            // STYM base = 0x680000 byte → 0x340000 word.
            oarb_stym_addr_r <= stym_addr_core;
        end

        if (!oarb_busy) begin
            // Priority: road > stym > obj sprite
            if (oarb_road_pending) begin
                oarb_road_pending <= 1'b0;
                oarb_busy         <= 1'b1;
                oarb_serving_road <= 1'b1;
                oarb_serving_stym <= 1'b0;
                oarb_sub          <= 3'h0;
                obj_sdr_addr <= {7'h30, oarb_rod_addr_r};  // 0x300000 + word offset
                obj_sdr_req  <= ~obj_sdr_req;
            end else if (oarb_stym_pending) begin
                oarb_stym_pending <= 1'b0;
                oarb_busy         <= 1'b1;
                oarb_serving_road <= 1'b0;
                oarb_serving_stym <= 1'b1;
                oarb_sub          <= 3'h0;
                obj_sdr_addr <= {7'h34, oarb_stym_addr_r};  // 0x340000 + word offset
                obj_sdr_req  <= ~obj_sdr_req;
            end else if (oarb_spr_pending) begin
                oarb_spr_pending  <= 1'b0;
                oarb_busy         <= 1'b1;
                oarb_serving_road <= 1'b0;
                oarb_serving_stym <= 1'b0;
                oarb_sub          <= 3'h0;
                obj_sdr_addr <= {2'b0, oarb_spr_addr_r};
                obj_sdr_req  <= ~obj_sdr_req;
            end
        end else begin
            // Waiting for SDRAM ack on CH3
            if (obj_sdr_ack == obj_sdr_req) begin
                if (oarb_serving_road || oarb_serving_stym) begin
                    // Single 16-bit read done
                    if (oarb_serving_road) begin
                        rod_rom_data_core <= obj_sdr_data;
                        oarb_rod_req_r    <= rod_rom_req_core;  // mirror → ack
                    end else begin
                        stym_data_core  <= obj_sdr_data;
                        oarb_stym_req_r <= stym_req_core;
                    end
                    oarb_busy <= 1'b0;
                end else begin
                    // OBJ sprite: 4-sub-read burst
                    case (oarb_sub)
                        3'd0: begin
                            oarb_buf[0] <= obj_sdr_data;
                            oarb_sub    <= 3'd1;
                            obj_sdr_addr <= {2'b0, oarb_spr_addr_r + 25'd1};
                            obj_sdr_req  <= ~obj_sdr_req;
                        end
                        3'd1: begin
                            oarb_buf[1] <= obj_sdr_data;
                            oarb_sub    <= 3'd2;
                            obj_sdr_addr <= {2'b0, oarb_spr_addr_r + 25'd2};
                            obj_sdr_req  <= ~obj_sdr_req;
                        end
                        3'd2: begin
                            oarb_buf[2] <= obj_sdr_data;
                            oarb_sub    <= 3'd3;
                            obj_sdr_addr <= {2'b0, oarb_spr_addr_r + 25'd3};
                            obj_sdr_req  <= ~obj_sdr_req;
                        end
                        3'd3: begin
                            // All 4 × 16-bit words received; assemble 64-bit result
                            spr_data_core <= {obj_sdr_data, oarb_buf[2],
                                              oarb_buf[1],  oarb_buf[0]};
                            oarb_spr_req_r <= spr_req_core;
                            oarb_busy      <= 1'b0;
                            oarb_sub       <= 3'h0;
                        end
                        default: oarb_busy <= 1'b0;
                    endcase
                end
            end
        end
    end
end

// ── CH4: Z80 ROM SDRAM channel ────────────────────────────────────────────────
// Z80 audio ROM is at SDRAM byte 0x0C0000 (word 0x060000).
// taito_z.sv drives z80_rom_addr as a 27-bit word address.
wire [26:0] z80_sdr_addr;
wire [15:0] z80_sdr_data;
wire        z80_sdr_req, z80_sdr_ack;

// ── SDRAM controller instantiation ──────────────────────────────────────────
sdram_z u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .reset_n    (reset_n),

    // CH0: HPS ROM download write path
    .ioctl_wr   (ioctl_wr & ioctl_download),
    .ioctl_addr (ioctl_addr),
    .ioctl_dout (ioctl_dout),

    // CH1: CPU program ROM reads
    .cpu_addr   (cpu_sdr_addr),
    .cpu_data   (cpu_sdr_data),
    .cpu_req    (cpu_sdr_req),
    .cpu_ack    (cpu_sdr_ack),

    // CH2: Tile GFX + STY spritemap reads
    .gfx_addr   (gfx_sdr_addr),
    .gfx_data   (gfx_sdr_data),
    .gfx_req    (gfx_sdr_req),
    .gfx_ack    (gfx_sdr_ack),

    // CH3: OBJ GFX + road ROM reads
    .obj_addr   (obj_sdr_addr),
    .obj_data   (obj_sdr_data),
    .obj_req    (obj_sdr_req),
    .obj_ack    (obj_sdr_ack),

    // CH4: Z80 audio program ROM reads
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
// Taito Z core
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
// fx68k_adapter — CPU A (MC68000 @ 16 MHz)
//////////////////////////////////////////////////////////////////

wire [23:1] cpua_addr;
wire [15:0] cpua_din;     // taito_z → CPU A (read data from bus)
wire [15:0] cpua_dout;    // CPU A → taito_z (write data)
wire        cpua_rw;
wire        cpua_uds_n;
wire        cpua_lds_n;
wire        cpua_as_n;
wire        cpua_dtack_n; // taito_z → CPU A
wire [2:0]  cpua_ipl_n;   // taito_z → CPU A
wire        cpua_reset_n_out;

fx68k_adapter u_cpu_a (
    .clk            (clk_sys),
    .cpu_ce         (ce_cpu),
    .reset_n        (reset_n),

    .cpu_addr       (cpua_addr),
    .cpu_din        (cpua_din),
    .cpu_dout       (cpua_dout),
    .cpu_rw         (cpua_rw),
    .cpu_uds_n      (cpua_uds_n),
    .cpu_lds_n      (cpua_lds_n),
    .cpu_as_n       (cpua_as_n),
    .cpu_dtack_n    (cpua_dtack_n),
    .cpu_ipl_n      (cpua_ipl_n),
    .cpu_reset_n_out(cpua_reset_n_out)
);

//////////////////////////////////////////////////////////////////
// fx68k_adapter — CPU B (MC68000 @ 16 MHz, opposite phase)
//////////////////////////////////////////////////////////////////

wire [23:1] cpub_addr;
wire [15:0] cpub_din;     // taito_z → CPU B (read data from bus)
wire [15:0] cpub_dout;    // CPU B → taito_z (write data)
wire        cpub_rw;
wire        cpub_uds_n;
wire        cpub_lds_n;
wire        cpub_as_n;
wire        cpub_dtack_n; // taito_z → CPU B
wire [2:0]  cpub_ipl_n;   // taito_z → CPU B
wire        cpub_reset_n; // taito_z → CPU B (CPU A can hold CPU B in reset)
wire        cpub_reset_n_out;

fx68k_adapter u_cpu_b (
    .clk            (clk_sys),
    .cpu_ce         (ce_cpu_b),         // opposite phase to CPU A
    .reset_n        (reset_n & cpub_reset_n),  // held in reset by CPU A control register
    .cpu_addr       (cpub_addr),
    .cpu_din        (cpub_din),
    .cpu_dout       (cpub_dout),
    .cpu_rw         (cpub_rw),
    .cpu_uds_n      (cpub_uds_n),
    .cpu_lds_n      (cpub_lds_n),
    .cpu_as_n       (cpub_as_n),
    .cpu_dtack_n    (cpub_dtack_n),
    .cpu_ipl_n      (cpub_ipl_n),
    .cpu_reset_n_out(cpub_reset_n_out)
);

taito_z u_taito_z
(
    .clk_sys    (clk_sys),
    .clk_pix    (ce_pix),
    .reset_n    (reset_n),

    // ── CPU A bus — driven by fx68k_adapter u_cpu_a ──────────────────────────
    .cpua_addr   (cpua_addr),
    .cpua_din    (cpua_dout),   // CPU A write data → taito_z
    .cpua_dout   (cpua_din),    // taito_z read data → CPU A
    .cpua_lds_n  (cpua_lds_n),
    .cpua_uds_n  (cpua_uds_n),
    .cpua_rw     (cpua_rw),
    .cpua_as_n   (cpua_as_n),
    .cpua_dtack_n(cpua_dtack_n),
    .cpua_ipl_n  (cpua_ipl_n),

    // ── CPU B bus — driven by fx68k_adapter u_cpu_b ──────────────────────────
    .cpub_addr   (cpub_addr),
    .cpub_din    (cpub_dout),   // CPU B write data → taito_z
    .cpub_dout   (cpub_din),    // taito_z read data → CPU B
    .cpub_lds_n  (cpub_lds_n),
    .cpub_uds_n  (cpub_uds_n),
    .cpub_rw     (cpub_rw),
    .cpub_as_n   (cpub_as_n),
    .cpub_dtack_n(cpub_dtack_n),
    .cpub_ipl_n  (cpub_ipl_n),
    .cpub_reset_n(cpub_reset_n),

    // ── GFX ROM (TC0480SCP, 4 × 32-bit toggle-handshake) ─────────────────────
    .gfx_addr    (gfx_addr_core),
    .gfx_data    (gfx_data_core),
    .gfx_req     (gfx_req_core),
    .gfx_ack     (gfx_ack_core),

    // ── Sprite OBJ ROM (TC0370MSO, 64-bit) ───────────────────────────────────
    .spr_addr    (spr_addr_core),
    .spr_data    (spr_data_core),
    .spr_req     (spr_req_core),
    .spr_ack     (spr_ack_core),

    // ── STY Spritemap ROM (TC0370MSO, 16-bit) ────────────────────────────────
    .stym_addr   (stym_addr_core),
    .stym_data   (stym_data_core),
    .stym_req    (stym_req_core),
    .stym_ack    (stym_ack_core),

    // ── Road ROM (TC0150ROD, 16-bit) ──────────────────────────────────────────
    .rod_rom_addr (rod_rom_addr_core),
    .rod_rom_data (rod_rom_data_core),
    .rod_rom_req  (rod_rom_req_core),
    .rod_rom_ack  (rod_rom_ack_core),

    // ── SDRAM (ADPCM ROM via TC0140SYT) ──────────────────────────────────────
    // TC0140SYT owns this SDRAM port for ADPCM-A and ADPCM-B ROM access.
    // CPU program ROM accesses are handled by cpu_sdr_* (CH1) above.
    .sdr_addr    (cpu_sdr_addr),
    .sdr_data    (cpu_sdr_data),
    .sdr_req     (cpu_sdr_req),
    .sdr_ack     (cpu_sdr_ack),

    // ── Z80 ROM SDRAM (CH4) ───────────────────────────────────────────────────
    .z80_rom_addr (z80_sdr_addr),
    .z80_rom_data (z80_sdr_data),
    .z80_rom_req  (z80_sdr_req),
    .z80_rom_ack  (z80_sdr_ack),

    // ── Sound clock and audio output ──────────────────────────────────────────
    .clk_sound   (ce_snd),
    .snd_left    (core_snd_left),
    .snd_right   (core_snd_right),

    // ── Video output ──────────────────────────────────────────────────────────
    .rgb_r       (core_rgb_r),
    .rgb_g       (core_rgb_g),
    .rgb_b       (core_rgb_b),
    .hsync_n     (core_hsync_n),
    .vsync_n     (core_vsync_n),
    .hblank      (core_hblank),
    .vblank      (core_vblank),

    // ── Player inputs (active-low, TC0510NIO) ────────────────────────────────
    .joystick_p1 (joy_p1),
    .joystick_p2 (joy_p2),
    .coin        (coin),
    .service     (service),
    .wheel       (wheel_in),
    .pedal       (pedal_in)
);

//////////////////////////////////////////////////////////////////
// Video pipeline
// arcade_video handles: sync-fix, colour expansion, scandoubler, gamma
//
// taito_z outputs hsync_n / vsync_n (active-low).
// arcade_video expects active-high HSync/VSync convention.
// Taito Z native resolution: 320 × 240, 24-bit RGB from palette BRAM.
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
    joystick_0[31:9], joystick_1[31:8],
    dsw[0], dsw[1], dsw[2], dsw[3],
    cpua_reset_n_out,   // CPU A RESET instruction output (not used at top level)
    cpub_reset_n_out    // CPU B RESET instruction output (not used at top level)
};
/* verilator lint_on UNUSED */

endmodule
