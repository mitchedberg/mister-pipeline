//============================================================================
//  Arcade: Sega System 32
//
//  MiSTer emu top-level wrapper
//  Target game: Rad Mobile (radm)
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

// -------------------------------------------------------------------------
// Sega System 32 display parameters:
//   Primary target:    Rad Mobile (radm), 1990
//   Native resolution: 320 × 224 (visible), standard horizontal arcade timing
//   CPU clock:         16 MHz (32 MHz sys_clk / 2 clock-enable)
//   Pixel clock:       ~6.14 MHz (pixel period = ~163 ns)
//   RGB output:        8 bits per channel (24-bit total) from R5G5B5 palette
//   Aspect ratio:      4:3 (horizontal)
//
// CPU NOTE: Real hardware uses NEC V60 (uPD70615) @ 16 MHz.
//   16-bit external data bus, 24-bit address bus.
//
// Audio NOTE: System 32 uses Z80 sound CPU + YM3438 (OPN2C) + 2x RF5C164 PCM.
//   Audio is stubbed in this initial framework integration.
//   Audio outputs are silenced (zero).
//
// ROM loading (ioctl_index values, set in .mra file):
//   0x00 — Program ROM (CPU maincpu, 2 MB, SDRAM bank 0 base 0)
//   0x01 — Sprite ROM  (sprites, up to 8 MB, SDRAM bank 0 offset 0x200000)
//   0x02 — GFX ROM     (gfx1 tiles, 2 MB, SDRAM bank 1 base 0)
//   0xFE — DIP switch / NVRAM init data
//
// SDRAM layout (IS42S16320F, 32 MB, single chip — no dual SDRAM needed):
//   Bank 0:
//     0x000000 – 0x1FFFFF   2 MB    CPU program ROM  (maincpu)
//     0x200000 – 0x9FFFFF   8 MB    Sprite ROM       (sprites, 8x 1MB)
//   Bank 1:
//     0x000000 – 0x1FFFFF   2 MB    GFX tile ROM     (gfx1, 4x 512KB)
//
// BRAM allocation:
//   Work RAM:    64 KB   (internal to segas32_top)
//   VRAM:       128 KB   (internal to segas32_video)
//   Sprite RAM: 128 KB   (internal to segas32_video)
//   Palette RAM: 64 KB   (internal to segas32_video)
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
// Audio stubbed — System 32 audio (YM3438 + RF5C164 x2) not yet implemented
assign AUDIO_L   = 16'd0;
assign AUDIO_R   = 16'd0;

assign LED_DISK  = 2'd0;
assign LED_POWER = 2'd0;
assign BUTTONS   = 2'd0;

// LED: blink during ROM download
assign LED_USER = ioctl_download;

//////////////////////////////////////////////////////////////////
// Aspect ratio
// System 32 horizontal: 4:3
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
    "SegaSystem32;;",
    "-;",
    "O[122:121],Aspect ratio,Original 4:3,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "O[1:0],Lives,3,2,1,5;",
    "O[3:2],Difficulty,Easy,Normal,Hard,Hardest;",
    "O[4],Demo Sound,Off,On;",
    "-;",
    "T[0],Reset;",
    // System 32: 2 joysticks + 3 buttons + start + coin
    "J1,Btn1,Btn2,Btn3,Start,Coin;",
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
// System 32 system clock: 32 MHz (V60 CPU at 16 MHz via /2 CE).
// Pixel clock: ~6.14 MHz (320-mode: htotal=512, vtotal=262, refresh=59.9 Hz).
//   sys_clk / 5 CE = 6.4 MHz ≈ close enough for display sync.
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
// ce_cpu: /2 clock enable — 16 MHz effective V60 CPU clock.
//
// ce_pix: /5 clock enable — ~6.4 MHz pixel clock.
//   System 32 pixel clock is ~6.14 MHz in 320-mode; /5 from 32 MHz = 6.4 MHz.
//////////////////////////////////////////////////////////////////
logic ce_cpu;       // high one out of every 2 sys_clk cycles (32 MHz / 2 = 16 MHz)

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        ce_cpu <= 1'b0;
    else
        ce_cpu <= ~ce_cpu;
end

// Pixel clock enable: /5 divider = ~6.4 MHz.
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
// Input mapping for System 32
//
// MiSTer joystick_0 bit layout (standard):
//   [0]=Right [1]=Left [2]=Down [3]=Up
//   [4]=B1 [5]=B2 [6]=B3 [7]=B4
//   [8]=Start [9]=Coin
//
// System 32 315-5296 I/O chip expects active-low inputs.
// joy_p1[7:0]: [3:0]=UDLR, [6:4]=Btn3/B2/B1, [7]=Start (active-low)
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
// Provides three channels to segas32_top:
//   prog_*  — CPU program ROM reads (16-bit, bank 0, 0x000000–0x1FFFFF)
//   spr_*   — Sprite ROM reads (32-bit fetch via two 16-bit reads, bank 0, 0x200000+)
//   gfx_*   — GFX tile ROM reads (32-bit fetch via two 16-bit reads, bank 1, 0x000000+)
// Plus ioctl write path for ROM download.
//
// Program ROM (index 0x00): loaded sequentially to SDRAM offset 0x000000.
// Sprite ROM  (index 0x01): loaded sequentially to SDRAM offset 0x200000.
// GFX ROM     (index 0x02): loaded sequentially to SDRAM offset 0xA00000
//   (reusing the single SDRAM chip; sprites are ≤8MB so gfx starts at 0xA00000).
//
// NOTE: segas32_top has synchronous ROM reads — program ROM requests use
// a simple req/ack toggle handshake via the sdram_b controller.
// GFX ROM is 32-bit wide; we pair two consecutive 16-bit SDRAM reads.
//////////////////////////////////////////////////////////////////

wire [26:0] prog_sdr_addr;
wire [15:0] prog_sdr_data;
wire        prog_sdr_req, prog_sdr_ack;

wire [26:0] gfx_sdr_addr;
wire [15:0] gfx_sdr_data;
wire        gfx_sdr_req, gfx_sdr_ack;

// Sprite ROM shares the SDRAM channel with GFX ROM via a simple arbiter.
// Sprites reside at 0x200000–0x9FFFFF in SDRAM bank 0.
wire [26:0] spr_sdr_addr;
wire [15:0] spr_sdr_data;
wire        spr_sdr_req, spr_sdr_ack;

//----------------------------------------------------------------
// CH3 arbiter: GFX ROM (tile renderer) and Sprite ROM share one SDRAM channel.
// Priority: GFX (scanline-critical) > Sprite (pre-fetch buffer can stall)
//   owner: 0=GFX, 1=SPR
//----------------------------------------------------------------
wire [26:0] ch3_addr;
wire        ch3_req;
wire [15:0] ch3_data_out;
wire        ch3_ack;

logic       ch3_owner;   // 0=GFX, 1=SPR
logic       ch3_busy;

wire gfx_pend = (gfx_sdr_req != gfx_sdr_ack);
wire spr_pend = (spr_sdr_req != spr_sdr_ack);

logic       ch3_req_r;
logic [26:0] ch3_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ch3_req_r  <= 1'b0;
        ch3_addr_r <= 27'b0;
        ch3_owner  <= 1'b0;
        ch3_busy   <= 1'b0;
    end else begin
        if (!ch3_busy) begin
            if (gfx_pend) begin
                // GFX ROM at SDRAM 0xA00000 (bank 0 base + 0xA00000)
                ch3_addr_r <= 27'hA00000 + {5'b0, gfx_sdr_addr[21:0]};
                ch3_req_r  <= ~ch3_req_r;
                ch3_owner  <= 1'b0;
                ch3_busy   <= 1'b1;
            end else if (spr_pend) begin
                // Sprite ROM at SDRAM 0x200000
                ch3_addr_r <= 27'h200000 + {5'b0, spr_sdr_addr[21:0]};
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

// Route ack back to winner
assign gfx_sdr_ack = (~ch3_owner) ? ch3_ack : gfx_sdr_req;
assign spr_sdr_ack = (ch3_owner)  ? ch3_ack : spr_sdr_req;

// Both clients see the same 16-bit read data
assign gfx_sdr_data = ch3_data_out;
assign spr_sdr_data = ch3_data_out;

sdram_b u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .rst_n      (reset_n),

    // CH0: HPS ROM download write path
    .ioctl_wr   (ioctl_wr & ioctl_download),
    .ioctl_addr (ioctl_addr),
    .ioctl_dout (ioctl_dout),

    // CH1: CPU program ROM reads (16-bit)
    .cpu_addr   (prog_sdr_addr),
    .cpu_data   (prog_sdr_data),
    .cpu_req    (prog_sdr_req),
    .cpu_ack    (prog_sdr_ack),

    // CH2: unused (tied off)
    .gfx_addr   (27'b0),
    .gfx_data   (),
    .gfx_req    (1'b0),
    .gfx_ack    (),

    // CH3: GFX / Sprite ROM (arbitrated above)
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

//////////////////////////////////////////////////////////////////
// GFX ROM: 32-bit fetch via two consecutive 16-bit SDRAM reads
//
// segas32_top drives gfx_addr[21:0] (22-bit byte address) and gfx_rd.
// segas32_video expects gfx_data[31:0] in one cycle.
// We use a 2-beat fetch FSM: first fetch low word, then high word.
//
// GFX ROM address mapping:
//   gfx_addr[21:0] → SDRAM word addr = gfx_addr[21:1]
//   Low  16-bit word: SDRAM[{gfx_addr[21:2], 1'b0}]
//   High 16-bit word: SDRAM[{gfx_addr[21:2], 1'b1}]
//////////////////////////////////////////////////////////////////

// segas32_top ports
wire [21:0] core_gfx_addr;
wire        core_gfx_rd;
wire [31:0] core_gfx_data;

// GFX fetch FSM
logic [1:0] gfx_fetch_state;
logic [15:0] gfx_word_lo;
logic [31:0] gfx_data_buf;

localparam GFX_IDLE   = 2'd0;
localparam GFX_FETCH0 = 2'd1;   // request low word
localparam GFX_FETCH1 = 2'd2;   // request high word
localparam GFX_DONE   = 2'd3;   // data ready

logic gfx_req_toggle;
logic gfx_ack_seen;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        gfx_fetch_state <= GFX_IDLE;
        gfx_sdr_req     <= 1'b0;
        gfx_word_lo     <= 16'b0;
        gfx_data_buf    <= 32'b0;
    end else begin
        case (gfx_fetch_state)
            GFX_IDLE: begin
                if (core_gfx_rd) begin
                    // Request low 16-bit word: byte addr = {gfx_addr[21:2], 2'b00}
                    gfx_sdr_addr    <= {5'b0, core_gfx_addr[21:2], 1'b0};
                    gfx_sdr_req     <= ~gfx_sdr_req;
                    gfx_fetch_state <= GFX_FETCH0;
                end
            end
            GFX_FETCH0: begin
                if (gfx_sdr_req == gfx_sdr_ack) begin
                    gfx_word_lo     <= gfx_sdr_data;
                    // Request high 16-bit word: byte addr = {gfx_addr[21:2], 2'b10}
                    gfx_sdr_addr    <= {5'b0, core_gfx_addr[21:2], 1'b1};
                    gfx_sdr_req     <= ~gfx_sdr_req;
                    gfx_fetch_state <= GFX_FETCH1;
                end
            end
            GFX_FETCH1: begin
                if (gfx_sdr_req == gfx_sdr_ack) begin
                    gfx_data_buf    <= {gfx_sdr_data, gfx_word_lo};
                    gfx_fetch_state <= GFX_DONE;
                end
            end
            GFX_DONE: begin
                // Latch for one cycle; return to idle
                gfx_fetch_state <= GFX_IDLE;
            end
        endcase
    end
end

assign core_gfx_data = gfx_data_buf;

//////////////////////////////////////////////////////////////////
// Program ROM: req/ack handshake to sdram_b CH1
//
// segas32_top drives rom_addr[23:0] and rom_rd.
// V60 bus stalls (dtack_n held high) until data returns.
// We use a simple toggle req/ack: on rom_rd, toggle prog_sdr_req;
// segas32_top samples prog_sdr_data when prog_sdr_req == prog_sdr_ack.
//
// For this emu wrapper we provide the connection and let segas32_top
// poll for ack; dtack_n is managed inside segas32_top.
//////////////////////////////////////////////////////////////////

wire [23:0] core_rom_addr;
wire        core_rom_rd;
wire [15:0] core_rom_data;

logic prog_req_r;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        prog_req_r <= 1'b0;
    end else begin
        if (core_rom_rd && (prog_req_r == prog_sdr_ack))
            prog_req_r <= ~prog_req_r;
    end
end

assign prog_sdr_addr = {3'b0, core_rom_addr};
assign prog_sdr_req  = prog_req_r;
assign core_rom_data = prog_sdr_data;

//////////////////////////////////////////////////////////////////
// segas32_top core
//////////////////////////////////////////////////////////////////

wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync, core_vsync;
wire       core_hblank, core_vblank;

// Debug / unused tie-offs
wire [31:0] dbg_pc_w, dbg_psw_w, dbg_sp_w;
wire        dbg_halted_w, dbg_trapped_w;
wire [7:0]  dbg_opcode_w;
wire [23:0] dbg_cpu_addr_w;
wire [15:0] dbg_cpu_data_o_w, dbg_cpu_data_i_w;
wire        dbg_cpu_as_n_w, dbg_cpu_rw_w;
wire [7:0]  io_portd_w;

segas32_top u_segas32_top
(
    .clk_cpu         (clk_sys),
    .clk_pix         (ce_pix),
    .rst_n           (reset_n),

    // Program ROM
    .rom_addr        (core_rom_addr),
    .rom_data        (core_rom_data),
    .rom_rd          (core_rom_rd),

    // GFX ROM (tile / sprite pixel data)
    .gfx_data        (core_gfx_data),
    .gfx_addr        (core_gfx_addr),
    .gfx_rd          (core_gfx_rd),

    // Video outputs
    .hsync           (core_hsync),
    .vsync           (core_vsync),
    .hblank          (core_hblank),
    .vblank          (core_vblank),
    .hpos            (),
    .vpos            (),
    .pixel_active    (),
    .pixel_r         (core_rgb_r),
    .pixel_g         (core_rgb_g),
    .pixel_b         (core_rgb_b),
    .pixel_de        (),

    // NMI — tied inactive
    .nmi_n           (1'b1),

    // Debug (unused in synthesis)
    .dbg_pc          (dbg_pc_w),
    .dbg_psw         (dbg_psw_w),
    .dbg_sp          (dbg_sp_w),
    .dbg_halted      (dbg_halted_w),
    .dbg_trapped     (dbg_trapped_w),
    .dbg_opcode      (dbg_opcode_w),
    .dbg_cpu_addr    (dbg_cpu_addr_w),
    .dbg_cpu_data_o  (dbg_cpu_data_o_w),
    .dbg_cpu_data_i  (dbg_cpu_data_i_w),
    .dbg_cpu_as_n    (dbg_cpu_as_n_w),
    .dbg_cpu_rw      (dbg_cpu_rw_w),
    .io_portd        (io_portd_w),
    .eeprom_do       (1'b1)     // EEPROM not connected — always reads '1'
);

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
    .HSync      (core_hsync),
    .VSync      (core_vsync),

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
    dsw[0], dsw[1], dsw[2], dsw[3],
    joy_p1, joy_p2, coin, service,
    dbg_pc_w, dbg_psw_w, dbg_sp_w,
    dbg_halted_w, dbg_trapped_w, dbg_opcode_w,
    dbg_cpu_addr_w, dbg_cpu_data_o_w, dbg_cpu_data_i_w,
    dbg_cpu_as_n_w, dbg_cpu_rw_w, io_portd_w
};
/* verilator lint_on UNUSED */

endmodule
