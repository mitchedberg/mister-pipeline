// =============================================================================
// emu.sv — ESD 16-bit Arcade MiSTer Top-Level Integration
// =============================================================================
//
// Hardware reference: MAME src/mame/misc/esd16.cpp
//
// Supported games:
//   Multi Champ (multchmp)           — multchmp_map  @ 16 MHz MC68000
//   Multi Champ Deluxe (mchampdx)    — mchampdx_map  @ 16 MHz MC68000
//   Head Panic (hedpanic)            — hedpanic_map   @ 16 MHz MC68000
//   Deluxe 5 (deluxe5)              — tangtang_map   @ 16 MHz MC68000
//   Tang Tang (tangtang)             — tangtang_map   @ 16 MHz MC68000
//   Jumping Pop (jumppop)            — jumppop_map    @ 16 MHz MC68000
//
// Clock plan (48 MHz sys_clk):
//   MC68000  : 48 MHz / 3 = 16 MHz (ce_cpu every 3rd posedge)
//   Pixel    : 48 MHz / 6 = 8 MHz  (ce_pix every 6th posedge)
//   SDRAM    : 96 MHz (PLL output)
//
// SDRAM layout (byte addresses):
//   0x000000 — Program ROM (512KB, MC68000)
//   0x080000 — Sprite ROM  (up to 1.25MB, 5-plane 16x16x5bpp)
//   0x280000 — BG Tile ROM (up to 512KB, 8bpp)
//
// ROM loading (ioctl_index from .mra):
//   0x00 — Program ROM merged at SDRAM 0x000000
//   0x01 — Sprite ROM  at SDRAM 0x080000
//   0x02 — BG Tile ROM at SDRAM 0x280000
//   0xFE — DIP switches
//
// Video: 320x224 @ 60 Hz, 4:3 aspect ratio
//   Htotal = 384 (320 active + 64 blank)
//   Vtotal = 264 (224 active + 40 blank)
// =============================================================================

module emu
(
    // Master input clock
    input         CLK_50M,

    // Async reset from top-level module
    input         RESET,

    // Must be passed to hps_io module
    inout  [48:0] HPS_BUS,

    // Base video clock — equals CLK_SYS
    output        CLK_VIDEO,

    // Pixel clock enable (based on CLK_VIDEO)
    output        CE_PIXEL,

    // Video aspect ratio for HDMI
    output [12:0] VIDEO_ARX,
    output [12:0] VIDEO_ARY,

    output  [7:0] VGA_R,
    output  [7:0] VGA_G,
    output  [7:0] VGA_B,
    output        VGA_HS,
    output        VGA_VS,
    output        VGA_DE,
    output        VGA_F1,
    output  [1:0] VGA_SL,
    output        VGA_SCALER,
    output        VGA_DISABLE,

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

    output        LED_USER,
    output  [1:0] LED_POWER,
    output  [1:0] LED_DISK,
    output  [1:0] BUTTONS,

    input         CLK_AUDIO,
    output [15:0] AUDIO_L,
    output [15:0] AUDIO_R,
    output        AUDIO_S,
    output  [1:0] AUDIO_MIX,

    inout   [3:0] ADC_BUS,

    output        SD_SCK,
    output        SD_MOSI,
    input         SD_MISO,
    output        SD_CS,
    input         SD_CD,

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

// =============================================================================
// Tie off unused framework ports
// =============================================================================

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

assign AUDIO_S   = 1'b1;
assign AUDIO_MIX = 2'd0;

assign LED_DISK  = 2'd0;
assign LED_POWER = 2'd0;
assign BUTTONS   = 2'd0;
assign LED_USER  = ioctl_download;

// =============================================================================
// Aspect ratio — ESD16 is 4:3 (320x224 @ 60 Hz)
// =============================================================================

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 13'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 13'd3 : 13'd0;

// =============================================================================
// OSD configuration string
// =============================================================================

`include "build_id.v"
localparam CONF_STR = {
    "ESD16;;",
    "-;",
    "O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
    "O[5:3],Scandoubler FX,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
    "-;",
    "DIP;",
    "-;",
    "T[0],Reset;",
    "J1,Button 1,Button 2,Button 3,Start,Coin;",
    "jn,A,B,C,Start,Select;",
    "V,v",`BUILD_DATE
};

// =============================================================================
// HPS I/O
// =============================================================================

wire        forced_scandoubler;
wire  [1:0] buttons_hps;
wire [127:0] status;
wire  [21:0] gamma_bus;
wire         direct_video;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;
wire        ioctl_wait;

wire [31:0] joystick_0, joystick_1;

hps_io #(.CONF_STR(CONF_STR)) u_hps_io
(
    .clk_sys            (clk_sys),
    .HPS_BUS            (HPS_BUS),

    .buttons            (buttons_hps),
    .status             (status),
    .forced_scandoubler (forced_scandoubler),
    .gamma_bus          (gamma_bus),
    .direct_video       (direct_video),
    .video_rotated      (1'b0),

    .ioctl_download     (ioctl_download),
    .ioctl_wr           (ioctl_wr),
    .ioctl_addr         (ioctl_addr),
    .ioctl_dout         (ioctl_dout),
    .ioctl_index        (ioctl_index),
    .ioctl_wait         (ioctl_wait),

    .joystick_0         (joystick_0),
    .joystick_1         (joystick_1)
);

// =============================================================================
// PLL — 48 MHz system clock, 96 MHz SDRAM clock
// =============================================================================

wire clk_sys;
wire clk_sdram;
wire pll_locked;

pll u_pll
(
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),    // 48 MHz
    .outclk_1 (clk_sdram),  // 96 MHz
    .locked   (pll_locked)
);

assign SDRAM_CLK  = clk_sdram;
assign CLK_VIDEO  = clk_sys;

// =============================================================================
// Reset
// =============================================================================

logic [7:0] rst_extend;
logic       reset_n;

always_ff @(posedge clk_sys) begin
    if (RESET | ~pll_locked | status[0] | buttons_hps[1] | ioctl_download)
        rst_extend <= 8'hFF;
    else if (rst_extend != 8'h00)
        rst_extend <= rst_extend - 8'd1;
end

assign reset_n = (rst_extend == 8'h00);

// =============================================================================
// Clock enables
//
// MC68000 @ 16 MHz = 48 MHz / 3
// Pixel clock @ 8 MHz = 48 MHz / 6
// =============================================================================

logic [1:0] ce_cpu_cnt;
logic       ce_cpu;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_cpu_cnt <= 2'd0;
        ce_cpu     <= 1'b0;
    end else begin
        if (ce_cpu_cnt == 2'd2) begin
            ce_cpu_cnt <= 2'd0;
            ce_cpu     <= 1'b1;
        end else begin
            ce_cpu_cnt <= ce_cpu_cnt + 2'd1;
            ce_cpu     <= 1'b0;
        end
    end
end

logic [2:0] ce_pix_cnt;
logic       ce_pix;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_pix_cnt <= 3'd0;
        ce_pix     <= 1'b0;
    end else begin
        if (ce_pix_cnt == 3'd5) begin
            ce_pix_cnt <= 3'd0;
            ce_pix     <= 1'b1;
        end else begin
            ce_pix_cnt <= ce_pix_cnt + 3'd1;
            ce_pix     <= 1'b0;
        end
    end
end

assign CE_PIXEL = ce_pix;

// =============================================================================
// DIP switches (loaded from .mra at ioctl_index == 0xFE)
// =============================================================================

logic [7:0] dsw[4];
always_ff @(posedge clk_sys)
    if (ioctl_wr && (ioctl_index == 8'hFE) && !ioctl_addr[24:2])
        dsw[ioctl_addr[1:0]] <= ioctl_dout;

// =============================================================================
// Input mapping
//
// MiSTer joystick standard: [0]=Right [1]=Left [2]=Down [3]=Up
//                            [4]=B1 [5]=B2 [6]=B3 [8]=Start [9]=Coin
//
// esd_arcade joystick_0 port: [5:0]=UDLRBA (active-low), [7]=Start, [8]=Coin
//   Bit 5=Up, 4=Down, 3=Left, 2=Right, 1=B2(Button2), 0=B1(Button1)
//   The exact active-low encoding: 0=pressed, 1=released
// =============================================================================

wire [9:0] joy_p1 = ~{
    joystick_0[9],           // [9]=Coin (bit 8 of esd_arcade.joystick_0)
    joystick_0[8],           // [8]=Start (bit 7 of esd_arcade.joystick_0)
    2'b11,                   // [7:6]=unused (pull-up idle)
    joystick_0[5],           // [5]=B2
    joystick_0[4],           // [4]=B1
    joystick_0[1],           // [3]=Left (MAME: bit 2 = left)
    joystick_0[0],           // [2]=Right
    joystick_0[2],           // [1]=Down
    joystick_0[3]            // [0]=Up
};

wire [9:0] joy_p2 = ~{
    joystick_1[9],
    joystick_1[8],
    2'b11,
    joystick_1[5],
    joystick_1[4],
    joystick_1[1],
    joystick_1[0],
    joystick_1[2],
    joystick_1[3]
};

// =============================================================================
// fx68k — MC68000 CPU (direct instantiation)
//
// Two-phase clock enables generated from ce_cpu toggle flip-flop.
// enPhi1/enPhi2 alternated on each ce_cpu pulse per COMMUNITY_PATTERNS.md 1.1.
// IACK detection (VPAn) via FC=111 and !ASn per COMMUNITY_PATTERNS.md 1.2.
// =============================================================================

logic        phi_toggle;
logic        enPhi1, enPhi2;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) phi_toggle <= 1'b0;
    else if (ce_cpu) phi_toggle <= ~phi_toggle;
end

assign enPhi1 = ce_cpu & ~phi_toggle;
assign enPhi2 = ce_cpu &  phi_toggle;

// CPU bus wires
logic [23:1] cpu_addr;
logic [15:0] cpu_din;   // esd_arcade → CPU (read data)
logic [15:0] cpu_dout;  // CPU → esd_arcade (write data)
logic        cpu_rw;
logic        cpu_uds_n;
logic        cpu_lds_n;
logic        cpu_as_n;
logic        cpu_dtack_n;
logic  [2:0] cpu_ipl_n;
logic  [2:0] cpu_fc;

// IACK detect (COMMUNITY_PATTERNS.md 1.2) — drives VPAn for autovector
wire inta_n = ~&{cpu_fc[2], cpu_fc[1], cpu_fc[0], ~cpu_as_n};

fx68k u_cpu (
    .clk        (clk_sys),
    .HALTn      (1'b1),
    .extReset   (~reset_n),
    .pwrUp      (~reset_n),
    .enPhi1     (enPhi1),
    .enPhi2     (enPhi2),

    .eRWn       (cpu_rw),
    .ASn        (cpu_as_n),
    .LDSn       (cpu_lds_n),
    .UDSn       (cpu_uds_n),
    .E          (),
    .VMAn       (),

    .FC0        (cpu_fc[0]),
    .FC1        (cpu_fc[1]),
    .FC2        (cpu_fc[2]),

    .BGn        (),
    .oRESETn    (),
    .oHALTEDn   (),

    .DTACKn     (cpu_dtack_n),
    .VPAn       (inta_n),
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),

    .IPL0n      (cpu_ipl_n[0]),
    .IPL1n      (cpu_ipl_n[1]),
    .IPL2n      (cpu_ipl_n[2]),

    .iEdb       (cpu_din),
    .oEdb       (cpu_dout),
    .eab        (cpu_addr)
);

// =============================================================================
// SDRAM — 3-channel ROM read + download write path
// =============================================================================

wire [26:0] prog_sdr_addr;
wire [15:0] prog_sdr_data;
wire        prog_sdr_req, prog_sdr_ack;

wire [26:0] spr_sdr_addr;
wire [15:0] spr_sdr_data;
wire        spr_sdr_req, spr_sdr_ack;

wire [26:0] bg_sdr_addr;
wire [15:0] bg_sdr_data;
wire        bg_sdr_req, bg_sdr_ack;

wire sdram_write_req = ioctl_wr & ioctl_download & (ioctl_index != 8'hFE);

sdram_b u_sdram
(
    .clk        (clk_sdram),
    .clk_sys    (clk_sys),
    .rst_n      (reset_n),

    // ROM download (write path)
    .ioctl_wr   (sdram_write_req),
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

    // CH3: BG tile ROM reads
    .adpcm_addr (bg_sdr_addr),
    .adpcm_data (bg_sdr_data),
    .adpcm_req  (bg_sdr_req),
    .adpcm_ack  (bg_sdr_ack),

    // CH4: unused
    .snd_addr   (27'h0),
    .snd_data   (),
    .snd_req    (1'b0),
    .snd_ack    (),

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

// =============================================================================
// ESD Arcade Core
// =============================================================================

wire [7:0] core_rgb_r, core_rgb_g, core_rgb_b;
wire       core_hsync_n, core_vsync_n;
wire       core_hblank, core_vblank;
wire [15:0] core_audio_l, core_audio_r;
wire        core_ioctl_wait;

esd_arcade u_esd (
    .clk_sys         (clk_sys),
    .clk_pix         (ce_pix),
    .reset_n         (reset_n),

    // CPU bus
    .cpu_addr        (cpu_addr),
    .cpu_din         (cpu_dout),  // CPU write data → core
    .cpu_dout        (cpu_din),   // core read data → CPU
    .cpu_lds_n       (cpu_lds_n),
    .cpu_uds_n       (cpu_uds_n),
    .cpu_rw          (cpu_rw),
    .cpu_as_n        (cpu_as_n),
    .cpu_fc          (cpu_fc),
    .cpu_dtack_n     (cpu_dtack_n),
    .cpu_ipl_n       (cpu_ipl_n),

    // Program ROM
    .prog_rom_addr   (prog_sdr_addr),
    .prog_rom_data   (prog_sdr_data),
    .prog_rom_req    (prog_sdr_req),
    .prog_rom_ack    (prog_sdr_ack),

    // Sprite ROM
    .spr_rom_addr    (spr_sdr_addr),
    .spr_rom_data    (spr_sdr_data),
    .spr_rom_req     (spr_sdr_req),
    .spr_rom_ack     (spr_sdr_ack),

    // BG tile ROM
    .bg_rom_addr     (bg_sdr_addr),
    .bg_rom_data     (bg_sdr_data),
    .bg_rom_req      (bg_sdr_req),
    .bg_rom_ack      (bg_sdr_ack),

    // Video outputs
    .rgb_r           (core_rgb_r),
    .rgb_g           (core_rgb_g),
    .rgb_b           (core_rgb_b),
    .hsync_n         (core_hsync_n),
    .vsync_n         (core_vsync_n),
    .hblank          (core_hblank),
    .vblank          (core_vblank),

    // Audio (silence stub)
    .audio_l         (core_audio_l),
    .audio_r         (core_audio_r),

    // Player inputs (active-low)
    .joystick_0      (joy_p1),
    .joystick_1      (joy_p2),
    .dip_sw          ({dsw[1], dsw[0]}),

    // ROM download (unused at runtime — SDRAM handles writes)
    .ioctl_download  (1'b0),
    .ioctl_addr      (27'h0),
    .ioctl_dout      (16'h0),
    .ioctl_wr        (1'b0),
    .ioctl_index     (8'h0),
    .ioctl_wait      (core_ioctl_wait)
);

// ioctl_wait: hold HPS downloads when SDRAM is busy
// (core's ioctl path is unused here, so this is always 0)
assign ioctl_wait = 1'b0;

// =============================================================================
// Video output
// =============================================================================

assign VGA_R  = core_rgb_r;
assign VGA_G  = core_rgb_g;
assign VGA_B  = core_rgb_b;
assign VGA_HS = core_hsync_n;
assign VGA_VS = core_vsync_n;
assign VGA_DE = ~(core_hblank | core_vblank);
assign VGA_SL = 2'b00;

// =============================================================================
// Audio output
// =============================================================================

assign AUDIO_L = core_audio_l;
assign AUDIO_R = core_audio_r;

endmodule
