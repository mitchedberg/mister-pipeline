// =============================================================================
// kaneko_arcade.sv — Kaneko16 System Board Top-Level Integration
// =============================================================================
//
// Implements the Kaneko16 arcade board (Berlin Wall / Shogun Warriors).
//
// Instantiates and wires:
//   kaneko16   — custom graphics chip (VU-001 + VU-002 + VIEW2-CHIP, all 5 gates)
//   Work RAM   — 64KB at 0x100000–0x10FFFF
//   Palette RAM — 512 × 16-bit at 0x600000–0x6003FF (RGB555 format)
//   I/O regs   — joysticks, coins, DIP switches at 0x700000–0x70000F
//
// Sound hardware:
//   Z80 sound CPU         — T80s core @ 8 MHz (clk_sys=32 MHz / 4)
//   OKI M6295 (ADPCM)    — instantiated via jt6295; ADPCM ROM via SDRAM CH3
//   YM2149 (AY-3-8910)   — stub comment (jt49 not yet available in jtcores)
//
// Address map (byte addresses, from MAME kaneko16.cpp):
//   0x000000–0x0FFFFF   1MB     Program ROM (from SDRAM)
//   0x100000–0x10FFFF   64KB    Work RAM
//   0x200000–0x20FFFF   64KB    Kaneko16 chip registers
//   0x400000–0x400FFF   4KB     Kaneko16 Sprite RAM
//   0x500000–0x507FFF   32KB    Kaneko16 Tilemap VRAM (4 layers × 8KB)
//   0x600000–0x6003FF   1KB     Palette RAM (512 × 16-bit, RGB555)
//   0x700000–0x70000F   16B     I/O registers
//
// VBLANK IRQ: level 4 (IPL = 3'b011)
//
// Reference: MAME src/mame/kaneko/kaneko16.cpp, berlwall / shogwarr drivers
//            chips/kaneko/rtl/kaneko16.sv
//            chips/toaplan_v2/rtl/toaplan_v2.sv (pattern reference)
//
// NOT instantiated here (provided by the MiSTer HPS top-level wrapper):
//   MC68000 CPU, SDRAM controller
//
// =============================================================================
`default_nettype none

// ============================================================================
// Typedef: Kaneko16 Sprite Descriptor
// ============================================================================
typedef struct packed {
    logic [8:0]  y;
    logic [15:0] tile_num;
    logic [8:0]  x;
    logic [3:0]  palette;
    logic        flip_x;
    logic        flip_y;
    logic [3:0]  prio;
    logic [3:0]  size;
    logic        valid;
} kaneko16_sprite_t;

/* verilator lint_off SYNCASYNCNET */
module kaneko_arcade #(
    // ── Address decode parameters (WORD addresses = byte_addr >> 1) ────────
    // Kaneko16 chip: 0x200000–0x20FFFF byte → word base 0x100000
    parameter logic [23:1] K16_BASE    = 23'h100000,   // byte 0x200000 >> 1
    // Sprite RAM: 0x400000–0x400FFF byte → word base 0x200000
    parameter logic [23:1] SPR_BASE    = 23'h200000,   // byte 0x400000 >> 1
    // Tilemap VRAM: 0x500000–0x507FFF byte → word base 0x280000
    parameter logic [23:1] VRAM_BASE   = 23'h280000,   // byte 0x500000 >> 1
    // Palette RAM: 0x600000–0x6003FF byte → word base 0x300000
    parameter logic [23:1] PALRAM_BASE = 23'h300000,   // byte 0x600000 >> 1
    // I/O: 0x700000–0x70000F byte → word base 0x380000
    parameter logic [23:1] IO_BASE     = 23'h380000,   // byte 0x700000 >> 1
    // Work RAM: 0x100000–0x10FFFF byte → word base 0x080000 (15-bit, 32K words)
    parameter logic [23:1] WRAM_BASE   = 23'h080000,   // byte 0x100000 >> 1
    parameter int WRAM_WORDS = 32768,                   // 64KB / 2 = 32K words

    // ── SDRAM base addresses ────────────────────────────────────────────────
    // GFX ROM (sprites + tiles) at SDRAM offset 0x100000
    parameter logic [26:0] GFX_ROM_BASE  = 27'h100000
) (
    // ── Clocks / Reset ──────────────────────────────────────────────────────
    input  logic        clk_sys,         // master system clock (32 MHz)
    input  logic        clk_pix,         // pixel clock enable (1-cycle pulse, sys-domain)
    input  logic        reset_n,         // active-low async reset

    // ── MC68000 CPU Bus ─────────────────────────────────────────────────────
    input  logic [23:1] cpu_addr,
    input  logic [15:0] cpu_dout,        // data FROM cpu (write path)
    output logic [15:0] cpu_din,         // data TO cpu (read path mux)
    input  logic        cpu_rw,          // 1=read, 0=write
    input  logic        cpu_as_n,        // address strobe (active low)
    input  logic        cpu_uds_n,       // upper data strobe (active low)
    input  logic        cpu_lds_n,       // lower data strobe (active low)
    output logic        cpu_dtack_n,     // data transfer acknowledge (active low)
    output logic [2:0]  cpu_ipl_n,       // interrupt priority level (active low encoded)

    // ── Program ROM (from SDRAM) ───────────────────────────────────────────
    output logic [19:1] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM (sprite + BG tiles, from SDRAM) ───────────────────────────
    // 32-bit wide for tile fetch efficiency (Kaneko16 4bpp packed tiles).
    output logic [21:0] gfx_rom_addr,
    input  logic [31:0] gfx_rom_data,
    output logic        gfx_rom_req,
    input  logic        gfx_rom_ack,

    // ── Video Output ────────────────────────────────────────────────────────
    output logic [7:0]  rgb_r,
    output logic [7:0]  rgb_g,
    output logic [7:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Player Inputs ───────────────────────────────────────────────────────
    // Active-low convention.
    // [7]=BTN3 [6]=BTN2 [5]=BTN1 [4]=START [3]=RIGHT [2]=LEFT [1]=DOWN [0]=UP
    input  logic [7:0]  joystick_p1,
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,            // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service,         // service button (active low)
    input  logic [7:0]  dipsw1,          // DIP switch bank 1
    input  logic [7:0]  dipsw2,          // DIP switch bank 2

    // ── Audio Output ────────────────────────────────────────────────────────
    output logic [15:0] snd_left,        // signed 16-bit mixed audio
    output logic [15:0] snd_right,

    // ── ADPCM ROM (OKI M6295, from SDRAM CH3) ───────────────────────────────
    output logic [23:0] adpcm_rom_addr,  // byte address (18-bit OKI → 24-bit SDRAM)
    output logic        adpcm_rom_req,   // toggle handshake
    input  logic  [7:0] adpcm_rom_data,  // byte returned (low byte of 16-bit word)
    input  logic        adpcm_rom_ack,   // toggle ack

    // ── Sound clock enable ───────────────────────────────────────────────────
    // 1 MHz clock enable (derived from clk_sys by emu.sv divider)
    input  logic        clk_sound_cen,   // 1-cycle pulse at ~1 MHz in clk_sys domain

    // ── Z80 Sound CPU ROM SDRAM interface ────────────────────────────────────────
    // Z80 ROM: 32KB at SDRAM base; 16-bit address output, byte data returned.
    output logic [15:0] z80_rom_addr,    // Z80 16-bit address
    output logic        z80_rom_req,     // toggle on new fetch request
    input  logic  [7:0] z80_rom_data,   // byte returned from SDRAM
    input  logic        z80_rom_ack     // toggle when data is ready
);

// =============================================================================
// Local parameters
// =============================================================================

localparam int WRAM_ABITS = $clog2(WRAM_WORDS);   // 15

// =============================================================================
// Video Timing Generator — 320×240 standard arcade
// =============================================================================
//
// Horizontal: 320 active, 24 front porch, 32 sync, 40 back porch = 416 total
// Vertical:   240 active, 12 front porch,  4 sync,  8 back porch = 264 total
//
// Pixel clock enable (clk_pix) drives hpos/vpos advancement.

localparam int H_ACTIVE = 320;
localparam int H_FP     = 24;
localparam int H_SYNC   = 32;
localparam int H_BP     = 40;
localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 416

localparam int V_ACTIVE = 240;
localparam int V_FP     = 12;
localparam int V_SYNC   = 4;
localparam int V_BP     = 8;
localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;    // 264

logic [8:0] hpos_r;    // 0..415
logic [8:0] vpos_r;    // 0..263
logic       hsync_r, vsync_r, hblank_r, vblank_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        hpos_r   <= 9'h000;
        vpos_r   <= 9'h000;
        hsync_r  <= 1'b1;
        vsync_r  <= 1'b1;
        hblank_r <= 1'b0;
        vblank_r <= 1'b0;
    end else if (clk_pix) begin
        // Horizontal counter
        if (hpos_r == 9'(H_TOTAL - 1))
            hpos_r <= 9'h000;
        else
            hpos_r <= hpos_r + 9'd1;

        // Vertical counter (increment at end of each line)
        if (hpos_r == 9'(H_TOTAL - 1)) begin
            if (vpos_r == 9'(V_TOTAL - 1))
                vpos_r <= 9'h000;
            else
                vpos_r <= vpos_r + 9'd1;
        end

        // HSync: active during sync pulse
        hsync_r <= ~((hpos_r >= 9'(H_ACTIVE + H_FP)) && (hpos_r < 9'(H_ACTIVE + H_FP + H_SYNC)));
        // VSync: active during sync pulse
        vsync_r <= ~((vpos_r >= 9'(V_ACTIVE + V_FP)) && (vpos_r < 9'(V_ACTIVE + V_FP + V_SYNC)));
        // HBlank: asserted during horizontal blanking
        hblank_r <= (hpos_r >= 9'(H_ACTIVE));
        // VBlank: asserted during vertical blanking
        vblank_r <= (vpos_r >= 9'(V_ACTIVE));
    end
end

assign hsync_n = hsync_r;
assign vsync_n = vsync_r;
assign hblank  = hblank_r;
assign vblank  = vblank_r;

// Active pixel positions fed to kaneko16 (within visible area only)
wire [8:0] pix_hpos = (hpos_r < 9'(H_ACTIVE)) ? hpos_r : 9'h000;
wire [8:0] pix_vpos = (vpos_r < 9'(V_ACTIVE)) ? vpos_r : 9'h000;

// VBLANK edge detection for VBLANK IRQ trigger
logic vblank_prev;
logic vblank_rising;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) vblank_prev <= 1'b0;
    else          vblank_prev <= vblank_r;
end

assign vblank_rising = vblank_r & ~vblank_prev;

// Scan trigger: pulse at hblank falling edge during active display
// (used by Gate 3 sprite rasterizer: start each scanline render)
logic hblank_prev;
logic scan_trigger_w;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) hblank_prev <= 1'b0;
    else          hblank_prev <= hblank_r;
end

// Falling edge of hblank (display→active transition) triggers scanline render
assign scan_trigger_w = hblank_prev & ~hblank_r;

// =============================================================================
// Chip-Select Decode
// =============================================================================
// All comparisons use cpu_addr[23:1] (word address).

// Program ROM: 0x000000–0x0FFFFF (byte), word 0x000000–0x07FFFF (20-bit)
logic prog_rom_cs;
assign prog_rom_cs = (cpu_addr[23:20] == 4'b0000) && !cpu_as_n;

// Work RAM: 0x100000–0x10FFFF byte → word 0x080000–0x087FFF (15-bit window)
logic wram_cs;
assign wram_cs = (cpu_addr[23:WRAM_ABITS] == WRAM_BASE[23:WRAM_ABITS]) && !cpu_as_n;

// Kaneko16 chip registers: 0x200000–0x20FFFF byte → word 0x100000–0x1007FF
//   16-bit word window (cpu_addr[15:1] chip-relative)
logic k16_cs_n;
assign k16_cs_n = !((cpu_addr[23:16] == K16_BASE[23:16]) && !cpu_as_n);

// Kaneko16 Sprite RAM: 0x400000–0x400FFF byte → word 0x200000–0x2007FF (11-bit)
logic spr_cs_n;
assign spr_cs_n = !((cpu_addr[23:11] == SPR_BASE[23:11]) && !cpu_as_n);

// Kaneko16 Tilemap VRAM: 0x500000–0x507FFF byte → word 0x280000–0x283FFF (14-bit)
logic vram_cs_n;
assign vram_cs_n = !((cpu_addr[23:14] == VRAM_BASE[23:14]) && !cpu_as_n);

// Palette RAM: 0x600000–0x6003FF byte → word 0x300000–0x3001FF (9-bit window)
logic palram_cs;
assign palram_cs = (cpu_addr[23:9] == PALRAM_BASE[23:9]) && !cpu_as_n;

// I/O: 0x700000–0x70000F byte → word 0x380000–0x380007 (3-bit window)
logic io_cs;
assign io_cs = (cpu_addr[23:4] == IO_BASE[23:4]) && !cpu_as_n;

// =============================================================================
// kaneko16 — Graphics Chip (Gates 1–5)
// =============================================================================

logic [15:0] k16_dout;

// Gate 1 register outputs
logic [15:0] k16_scroll_x_0, k16_scroll_y_0;
logic [15:0] k16_scroll_x_1, k16_scroll_y_1;
logic [15:0] k16_scroll_x_2, k16_scroll_y_2;
logic [15:0] k16_scroll_x_3, k16_scroll_y_3;
logic [7:0]  k16_layer_ctrl_0, k16_layer_ctrl_1;
logic [7:0]  k16_layer_ctrl_2, k16_layer_ctrl_3;
logic [7:0]  k16_sprite_ctrl;
logic [3:0]  k16_map_base_sel;
logic [6:0]  k16_gfx_bank_sel;
logic [7:0]  k16_video_int_ctrl;
logic        k16_vblank_irq, k16_hblank_irq;
logic        k16_watchdog_reset;
logic [7:0]  k16_watchdog_counter;

// Gate 2 display list (used internally by Gate 3; not read at integration level)
/* verilator lint_off UNUSEDSIGNAL */
kaneko16_sprite_t k16_display_list [0:255];
/* verilator lint_on UNUSEDSIGNAL */
logic [7:0]  k16_display_list_count;
logic        k16_display_list_ready;
logic        k16_irq_vblank;

// Gate 3 sprite rasterizer ROM interface
logic [20:0] k16_spr_rom_addr;
logic        k16_spr_rom_rd;
logic [31:0] k16_spr_rom_data_r;

// Gate 3 scanline pixel buffer read-back
logic [8:0]  k16_spr_rd_addr;
logic [7:0]  k16_spr_rd_color;
logic        k16_spr_rd_valid;
logic [3:0]  k16_spr_rd_priority;
logic        k16_spr_render_done;

// Gate 4 BG tilemap renderer — VRAM CPU write path
logic [1:0]  k16_bg_layer_sel;
logic [4:0]  k16_bg_row_sel;
logic [4:0]  k16_bg_col_sel;
logic [15:0] k16_bg_vram_din;
logic        k16_bg_vram_wr;

// Gate 4 BG tile ROM interface
logic [20:0] k16_bg_tile_rom_addr;
logic [7:0]  k16_bg_tile_rom_data_r;

// Gate 4 pixel outputs
logic [3:0]  k16_bg_pix_valid;
logic [3:0][7:0]  k16_bg_pix_color;
logic [3:0]  k16_bg_pix_priority;

// Gate 5 compositor output
logic [7:0]  k16_final_color;
logic        k16_final_valid;

// Decode VRAM CPU write path from cpu_addr when vram is selected:
//   addr[14:1] = {layer[1:0], row[4:0], col[4:0], word_sel}
//   (VRAM word address within 0x500000 window)
assign k16_bg_layer_sel = cpu_addr[14:13];
assign k16_bg_row_sel   = cpu_addr[12:8];
assign k16_bg_col_sel   = cpu_addr[7:3];
assign k16_bg_vram_din  = cpu_dout;
assign k16_bg_vram_wr   = !vram_cs_n && !cpu_rw && !cpu_as_n;

// Gate 4 pixel pipeline: feed current pixel position and query all 4 layers per cycle.
// Cycle through layers 0–3 using a 2-bit rotating counter driven by clk_pix.
logic [1:0] bg_layer_query;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) bg_layer_query <= 2'b00;
    else if (clk_pix) bg_layer_query <= bg_layer_query + 2'd1;
end

// Feed sprite scanline buffer read address = current pixel X
assign k16_spr_rd_addr = pix_hpos;

// Joystick inputs go into kaneko16 as direct register values
// kaneko16.sv Gate 1 exposes joystick_1/joystick_2 as output ports (CPU-readable shadows).
// For this integration, we inject live joystick state via the I/O register block below.
// The kaneko16 joystick outputs are wired to local signals to suppress lint.
logic [15:0] k16_joystick_1_out, k16_joystick_2_out;
logic [15:0] k16_coin_in_out, k16_dip_switches_out;
logic [7:0]  k16_mcu_status, k16_mcu_command;
logic [7:0]  k16_mcu_param1, k16_mcu_param2;

kaneko16 u_kaneko16 (
    .clk            (clk_sys),
    .rst_n          (reset_n),

    // CPU bus — chip-relative 21-bit byte address
    // kaneko16.sv cpu_addr is 21-bit (A[20:0]); map from 23-bit word addr:
    //   chip offset byte addr = {5'b0, cpu_addr[15:1], 1'b0}
    // For the default K16_BASE = 0x100000 (word), chip byte addr = cpu_addr[16:0]<<1
    // kaneko16 module takes cpu_addr[20:0] as its byte address input
    .cpu_addr       ({5'b0, cpu_addr[15:1], 1'b0}),   // 21-bit chip-relative byte addr
    .cpu_din        (cpu_dout),                  // CPU write data
    .cpu_dout       (k16_dout),
    .cpu_cs_n       (k16_cs_n & spr_cs_n & vram_cs_n),  // any chip select
    .cpu_rd_n       ( cpu_rw ? 1'b0 : 1'b1),   // active low read
    .cpu_wr_n       (!cpu_rw ? 1'b0 : 1'b1),   // active low write
    .cpu_lds_n      (cpu_lds_n),
    .cpu_uds_n      (cpu_uds_n),

    // Video sync (active low)
    .vsync_n        (vsync_r),
    .hsync_n        (hsync_r),

    // Gate 1 register outputs
    .scroll_x_0     (k16_scroll_x_0),
    .scroll_y_0     (k16_scroll_y_0),
    .scroll_x_1     (k16_scroll_x_1),
    .scroll_y_1     (k16_scroll_y_1),
    .scroll_x_2     (k16_scroll_x_2),
    .scroll_y_2     (k16_scroll_y_2),
    .scroll_x_3     (k16_scroll_x_3),
    .scroll_y_3     (k16_scroll_y_3),
    .layer_ctrl_0   (k16_layer_ctrl_0),
    .layer_ctrl_1   (k16_layer_ctrl_1),
    .layer_ctrl_2   (k16_layer_ctrl_2),
    .layer_ctrl_3   (k16_layer_ctrl_3),
    .sprite_ctrl    (k16_sprite_ctrl),
    .map_base_sel   (k16_map_base_sel),
    .joystick_1     (k16_joystick_1_out),
    .joystick_2     (k16_joystick_2_out),
    .coin_in        (k16_coin_in_out),
    .dip_switches   (k16_dip_switches_out),
    .watchdog_counter (k16_watchdog_counter),
    .watchdog_reset (k16_watchdog_reset),
    .video_int_ctrl (k16_video_int_ctrl),
    .vblank_irq     (k16_vblank_irq),
    .hblank_irq     (k16_hblank_irq),
    .gfx_bank_sel   (k16_gfx_bank_sel),
    .mcu_status     (k16_mcu_status),
    .mcu_command    (k16_mcu_command),
    .mcu_param1     (k16_mcu_param1),
    .mcu_param2     (k16_mcu_param2),

    // Gate 2: Display list
    .display_list       (k16_display_list),
    .display_list_count (k16_display_list_count),
    .display_list_ready (k16_display_list_ready),
    .irq_vblank         (k16_irq_vblank),

    // Gate 4: BG tilemap VRAM CPU write port
    .bg_layer_sel   (k16_bg_layer_sel),
    .bg_row_sel     (k16_bg_row_sel),
    .bg_col_sel     (k16_bg_col_sel),
    .bg_vram_din    (k16_bg_vram_din),
    .bg_vram_wr     (k16_bg_vram_wr),

    // Gate 4: pixel pipeline
    .bg_hpos            (pix_hpos),
    .bg_vpos            (pix_vpos),
    .bg_layer_query     (bg_layer_query),
    .bg_tile_rom_addr   (k16_bg_tile_rom_addr),
    .bg_tile_rom_data   (k16_bg_tile_rom_data_r),
    .bg_pix_valid       (k16_bg_pix_valid),
    .bg_pix_color       (k16_bg_pix_color),
    .bg_pix_priority    (k16_bg_pix_priority),

    // Gate 3: sprite rasterizer
    .scan_trigger       (scan_trigger_w),
    .current_scanline   (pix_vpos),
    .spr_rom_addr       (k16_spr_rom_addr),
    .spr_rom_rd         (k16_spr_rom_rd),
    .spr_rom_data       (k16_spr_rom_data_r),
    .spr_rd_addr        (k16_spr_rd_addr),
    .spr_rd_color       (k16_spr_rd_color),
    .spr_rd_valid       (k16_spr_rd_valid),
    .spr_rd_priority    (k16_spr_rd_priority),
    .spr_render_done    (k16_spr_render_done),

    // Gate 5: priority mixer
    .layer_ctrl         ({8'h00, k16_layer_ctrl_0}),   // use BG0 ctrl for layer-count select
    .final_color        (k16_final_color),
    .final_valid        (k16_final_valid)
);

// =============================================================================
// GFX ROM SDRAM Bridge — time-multiplexed BG tile + Sprite tile access
// =============================================================================
//
// kaneko16 Gate 3 (sprite tiles) and Gate 4 (BG tiles) each produce byte
// addresses into the GFX ROM.
//
// Sprite ROM: 21-bit byte address, 32-bit wide read.
//   spr_rom_addr[20:2] = 32-bit word address into GFX ROM
//
// BG tile ROM: 21-bit byte address, 8-bit result.
//   bg_tile_rom_addr[20:2] = 32-bit word address; byte lane = [1:0]
//
// Arbitration: sprite wins when spr_rom_rd is asserted; BG otherwise.
// gfx_rom_addr is a WORD address (byte_addr >> 1, for 32-bit-wide SDRAM port).
//
// SDRAM base: GFX_ROM_BASE added to chip-relative address.

logic        gfx_pending;
logic [21:0] gfx_pending_addr;
logic [1:0]  gfx_pending_byte_sel;
logic        gfx_is_sprite;   // 1=sprite request, 0=BG request

// Byte-lane mux (combinational)
logic [7:0] gfx_byte_out;
always_comb begin
    case (gfx_pending_byte_sel)
        2'b00: gfx_byte_out = gfx_rom_data[7:0];
        2'b01: gfx_byte_out = gfx_rom_data[15:8];
        2'b10: gfx_byte_out = gfx_rom_data[23:16];
        2'b11: gfx_byte_out = gfx_rom_data[31:24];
    endcase
end

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        gfx_rom_req          <= 1'b0;
        gfx_pending          <= 1'b0;
        gfx_pending_addr     <= 22'b0;
        gfx_pending_byte_sel <= 2'b0;
        gfx_is_sprite        <= 1'b0;
        k16_spr_rom_data_r   <= 32'h0;
        k16_bg_tile_rom_data_r <= 8'h0;
    end else begin
        if (!gfx_pending) begin
            if (k16_spr_rom_rd) begin
                // Sprite tile request — higher priority; 32-bit wide
                gfx_pending_addr     <= GFX_ROM_BASE[21:0] + {1'b0, k16_spr_rom_addr[20:0]};
                gfx_pending_byte_sel <= k16_spr_rom_addr[1:0];   // not used for sprite (32b)
                gfx_is_sprite        <= 1'b1;
                gfx_pending          <= 1'b1;
                gfx_rom_req          <= ~gfx_rom_req;
            end else begin
                // BG tile request — byte result
                gfx_pending_addr     <= GFX_ROM_BASE[21:0] + {1'b0, k16_bg_tile_rom_addr[20:0]};
                gfx_pending_byte_sel <= k16_bg_tile_rom_addr[1:0];
                gfx_is_sprite        <= 1'b0;
                gfx_pending          <= 1'b1;
                gfx_rom_req          <= ~gfx_rom_req;
            end
        end else if (gfx_rom_req == gfx_rom_ack) begin
            // SDRAM returned data
            if (gfx_is_sprite)
                k16_spr_rom_data_r   <= gfx_rom_data;          // full 32-bit sprite word
            else
                k16_bg_tile_rom_data_r <= gfx_byte_out;         // selected byte for BG
            gfx_pending <= 1'b0;
        end
    end
end

assign gfx_rom_addr = gfx_pending_addr;

// =============================================================================
// Work RAM — 64KB synchronous block RAM
// =============================================================================

logic [15:0] wram_dout_r;

`ifdef QUARTUS
altsyncram #(
    .operation_mode         ("SINGLE_PORT"),
    .width_a                (16),
    .widthad_a              (WRAM_ABITS),
    .numwords_a             (WRAM_WORDS),
    .outdata_reg_a          ("CLOCK0"),
    .clock_enable_input_a   ("BYPASS"),
    .clock_enable_output_a  ("BYPASS"),
    .intended_device_family ("Cyclone V"),
    .lpm_type               ("altsyncram"),
    .ram_block_type         ("M10K"),
    .width_byteena_a        (2),
    .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ")
) work_ram_inst (
    .clock0     (clk_sys),
    .address_a  (cpu_addr[WRAM_ABITS:1]),
    .data_a     (cpu_dout),
    .wren_a     (wram_cs && !cpu_rw),
    .byteena_a  ({~cpu_uds_n, ~cpu_lds_n}),
    .q_a        (wram_dout_r),
    .aclr0(1'b0), .addressstall_a(1'b0), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1)
);
`else
logic [15:0] work_ram [0:WRAM_WORDS-1];
always_ff @(posedge clk_sys) begin
    if (wram_cs && !cpu_rw) begin
        if (!cpu_uds_n) work_ram[cpu_addr[WRAM_ABITS:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) work_ram[cpu_addr[WRAM_ABITS:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end
`endif
`ifndef QUARTUS
always_ff @(posedge clk_sys) begin
    if (wram_cs) wram_dout_r <= work_ram[cpu_addr[WRAM_ABITS:1]];
end
`endif

// =============================================================================
// Palette RAM — 512 × 16-bit synchronous block RAM
// =============================================================================
// Format: 0bRRRRRGGGGGBBBBB (RGB555, standard Kaneko16 format)
// CPU accesses palette at byte 0x600000–0x6003FF.
// During active display, final_color from Gate 5 (8-bit palette index)
// indexes into this RAM to produce RGB output.

logic [15:0] palram_cpu_dout;

`ifdef QUARTUS
logic [15:0] palram_cpu_raw, palram_pix_raw;
altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (16), .widthad_a (9), .numwords_a (512),
    .width_b                   (16), .widthad_b (9), .numwords_b (512),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (2), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) palram_cpu_inst (
    .clock0(clk_sys), .clock1(clk_sys),
    .address_a(cpu_addr[9:1]),  .data_a(cpu_dout),
    .wren_a(palram_cs && !cpu_rw), .byteena_a({~cpu_uds_n, ~cpu_lds_n}),
    .address_b(cpu_addr[9:1]),  .q_b(palram_cpu_raw),
    .wren_b(1'b0), .data_b(16'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);
altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (16), .widthad_a (9), .numwords_a (512),
    .width_b                   (16), .widthad_b (9), .numwords_b (512),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (2), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) palram_pix_inst (
    .clock0(clk_sys), .clock1(clk_sys),
    .address_a(cpu_addr[9:1]),           .data_a(cpu_dout),
    .wren_a(palram_cs && !cpu_rw), .byteena_a({~cpu_uds_n, ~cpu_lds_n}),
    .address_b({1'b0, k16_final_color}), .q_b(palram_pix_raw),
    .wren_b(1'b0), .data_b(16'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);
always_ff @(posedge clk_sys) begin
    if (palram_cs) palram_cpu_dout <= palram_cpu_raw;
end
logic [15:0] pal_entry_r;
always_ff @(posedge clk_sys) begin
    if (clk_pix) pal_entry_r <= palram_pix_raw;
end
`else
logic [15:0] palette_ram [0:511];
always_ff @(posedge clk_sys) begin
    if (palram_cs && !cpu_rw) begin
        if (!cpu_uds_n) palette_ram[cpu_addr[9:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) palette_ram[cpu_addr[9:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end
always_ff @(posedge clk_sys) begin
    if (palram_cs) palram_cpu_dout <= palette_ram[cpu_addr[9:1]];
end
logic [15:0] pal_entry_r;
always_ff @(posedge clk_sys) begin
    if (clk_pix) pal_entry_r <= palette_ram[{1'b0, k16_final_color}];
end
`endif

// Expand R5G5B5 → R8G8B8 (replicate 3 MSBs into low 3 bits for linear scaling)
assign rgb_r = {pal_entry_r[14:10], pal_entry_r[14:12]};
assign rgb_g = {pal_entry_r[9:5],   pal_entry_r[9:7]};
assign rgb_b = {pal_entry_r[4:0],   pal_entry_r[4:2]};

// =============================================================================
// I/O Registers
// =============================================================================
// Kaneko16 I/O map (byte addresses within 0x700000 window):
//   0x700000 — Player 1 joystick + buttons (read)
//   0x700002 — Player 2 joystick + buttons (read)
//   0x700004 — Coins + service (read)
//   0x700006 — DIP switch bank 1 (read)
//   0x700008 — DIP switch bank 2 (read)
//   0x70000C — Z80 sound command (write — stub, ignored)
//
// Registers are byte-wide on lower byte (D[7:0]).

logic [7:0] io_dout_byte;

always_comb begin
    io_dout_byte = 8'hFF;   // default: open bus
    case (cpu_addr[3:1])    // A[3:1] selects register
        3'h0: io_dout_byte = joystick_p1;
        3'h1: io_dout_byte = joystick_p2;
        3'h2: io_dout_byte = {2'b11, service, 1'b1, coin[1], coin[0], 2'b11};
        3'h3: io_dout_byte = dipsw1;
        3'h4: io_dout_byte = dipsw2;
        default: io_dout_byte = 8'hFF;
    endcase
end

// =============================================================================
// Sound Command Latch — M68000 → Z80 via I/O offset 0x70000C (word[7:0])
// =============================================================================
// The M68000 writes a command byte to 0x70000C; the Z80 sound CPU reads it.
// Z80 is stubbed here, so we only latch the byte for completeness.

logic [7:0] sound_cmd_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        sound_cmd_r <= 8'h00;
    else if (io_cs && !cpu_rw && !cpu_as_n && (cpu_addr[3:1] == 3'h6))
        sound_cmd_r <= cpu_dout[7:0];   // 0x70000C write
end

// =============================================================================
// Z80 Sound CPU — T80s @ 8 MHz (clk_sys=32 MHz / 4)
// =============================================================================
//
// Z80 address map (Kaneko16 / Berlin Wall hardware):
//   0x0000–0x7FFF   32KB Z80 ROM (SDRAM)
//   0x8000–0x87FF   2KB  Z80 RAM (BRAM, mirrored)
//   0xA000          Sound command latch (read from M68K)
//   0xE000          OKI M6295
//
// =============================================================================

// Z80 clock enable: 32 MHz / 4 = 8 MHz (matches clk_sound_cen rate × 8)
logic [1:0] ce_z80_cnt;
logic       ce_z80;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_z80_cnt <= 2'd0;
        ce_z80     <= 1'b0;
    end else begin
        if (ce_z80_cnt == 2'd3) begin
            ce_z80_cnt <= 2'd0;
            ce_z80     <= 1'b1;
        end else begin
            ce_z80_cnt <= ce_z80_cnt + 2'd1;
            ce_z80     <= 1'b0;
        end
    end
end

// Z80 bus signals
logic        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
logic        z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
logic [15:0] z80_addr;
logic  [7:0] z80_dout_cpu;

// Z80 wait: held low while ROM SDRAM fetch is pending
logic        z80_wait_n;

// Z80 2KB internal RAM (0x8000–0x87FF, mirrored)
logic [7:0] z80_ram [0:2047];
logic [7:0] z80_ram_dout_r;

// OKI read data (returned to Z80)
wire  [7:0] oki_dout_w;

// ── Z80 chip-select decode ───────────────────────────────────────────────────
logic z80_rom_cs;   // 0x0000–0x7FFF
logic z80_oki_cs;   // 0xE000        (OKI M6295)
logic z80_ram_cs;   // 0x8000–0x87FF (2KB RAM)
logic z80_cmd_cs;   // 0xA000        (sound command latch)

always_comb begin
    z80_rom_cs = (!z80_mreq_n) && (z80_addr[15] == 1'b0);
    z80_oki_cs = (!z80_mreq_n) && (z80_addr[15:12] == 4'hE);
    z80_ram_cs = (!z80_mreq_n) && (z80_addr[15:11] == 5'b10000);
    z80_cmd_cs = (!z80_mreq_n) && (z80_addr[15:12] == 4'hA);
end

// ── Z80 ROM SDRAM bridge ─────────────────────────────────────────────────────
logic z80_rom_pending;
logic z80_rom_req_r;
logic [7:0] z80_rom_latch;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        z80_rom_req_r   <= 1'b0;
        z80_rom_pending <= 1'b0;
        z80_rom_latch   <= 8'hFF;
        z80_wait_n      <= 1'b1;
    end else begin
        if (z80_rom_cs && !z80_rd_n && !z80_rom_pending) begin
            z80_rom_req_r   <= ~z80_rom_req_r;
            z80_rom_pending <= 1'b1;
            z80_wait_n      <= 1'b0;
        end else if (z80_rom_pending && (z80_rom_req_r == z80_rom_ack)) begin
            z80_rom_latch   <= z80_rom_data;
            z80_rom_pending <= 1'b0;
            z80_wait_n      <= 1'b1;
        end
    end
end

assign z80_rom_req  = z80_rom_req_r;
assign z80_rom_addr = z80_addr;

// ── Z80 RAM ──────────────────────────────────────────────────────────────────
always_ff @(posedge clk_sys) begin
    if (z80_ram_cs && !z80_wr_n)
        z80_ram[z80_addr[10:0]] <= z80_dout_cpu;
end

always_ff @(posedge clk_sys) begin
    if (z80_ram_cs) z80_ram_dout_r <= z80_ram[z80_addr[10:0]];
end

// ── Z80 data bus read mux ────────────────────────────────────────────────────
logic [7:0] z80_din_mux;

always_comb begin
    if (z80_oki_cs)
        z80_din_mux = oki_dout_w;
    else if (z80_cmd_cs)
        z80_din_mux = sound_cmd_r;
    else if (z80_ram_cs)
        z80_din_mux = z80_ram_dout_r;
    else if (z80_rom_cs)
        z80_din_mux = z80_rom_latch;
    else
        z80_din_mux = 8'hFF;
end

T80s u_z80 (
    .RESET_n  (reset_n),
    .CLK      (clk_sys),
    .CEN      (ce_z80),
    .WAIT_n   (z80_wait_n),
    .INT_n    (1'b1),   // no FM interrupt on Kaneko16 (OKI-only)
    .NMI_n    (1'b1),
    .BUSRQ_n  (1'b1),
    .OUT0     (1'b0),
    .DI       (z80_din_mux),
    .M1_n     (z80_m1_n),
    .MREQ_n   (z80_mreq_n),
    .IORQ_n   (z80_iorq_n),
    .RD_n     (z80_rd_n),
    .WR_n     (z80_wr_n),
    .RFSH_n   (z80_rfsh_n),
    .HALT_n   (z80_halt_n),
    .BUSAK_n  (z80_busak_n),
    .A        (z80_addr),
    .DOUT     (z80_dout_cpu)
);

// =============================================================================
// OKI M6295 — ADPCM Sound
// =============================================================================
//
// jt6295 interface:
//   clk/cen  — master clk + 1 MHz enable
//   wrn      — active-low write (now driven by Z80 bus)
//   din      — data bus from Z80
//   rom_addr — 18-bit byte address into ADPCM sample ROM
//   rom_data — byte returned by SDRAM bridge
//   rom_ok   — data valid (ack toggle matches req toggle)
//   sound    — signed 14-bit output
//
// ADPCM ROM SDRAM bridge:
//   jt6295 outputs a toggle on rom_addr change (we generate rom_ok = ack==req).
//   We map jt6295 18-bit byte addr → SDRAM CH3 27-bit byte addr (base 0x200000).

logic [17:0] oki_rom_addr_w;
logic  [7:0] oki_rom_data_w;
logic        oki_rom_ok_w;
logic signed [13:0] oki_sound_w;
logic        oki_sample_w;

// ADPCM ROM SDRAM bridge — byte read, toggle handshake
logic [17:0] adpcm_prev_addr;
logic        adpcm_req_r;
logic  [7:0] adpcm_byte_r;
logic        adpcm_ack_prev;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        adpcm_prev_addr <= 18'hx;
        adpcm_req_r     <= 1'b0;
        adpcm_byte_r    <= 8'hFF;
        adpcm_ack_prev  <= 1'b0;
    end else begin
        if (oki_rom_addr_w != adpcm_prev_addr) begin
            adpcm_prev_addr <= oki_rom_addr_w;
            adpcm_req_r     <= ~adpcm_req_r;
        end
        if (adpcm_rom_ack != adpcm_ack_prev) begin
            adpcm_ack_prev <= adpcm_rom_ack;
            adpcm_byte_r   <= adpcm_rom_data;
        end
    end
end

assign adpcm_rom_addr = {6'b000010, oki_rom_addr_w};
assign adpcm_rom_req  = adpcm_req_r;
assign oki_rom_data_w = adpcm_byte_r;
assign oki_rom_ok_w   = (adpcm_rom_req == adpcm_rom_ack);

// OKI write enable: Z80 writes when z80_oki_cs and wr_n low
wire oki_wrn_w = z80_wr_n | ~z80_oki_cs;

jt6295 #(.INTERPOL(0)) u_oki (
    .rst        (~reset_n),
    .clk        (clk_sys),
    .cen        (clk_sound_cen),   // ~1 MHz enable
    .ss         (1'b1),            // ss=1 → 8 kHz sample rate (standard M6295 mode)
    // CPU interface — driven by Z80
    .wrn        (oki_wrn_w),
    .din        (z80_dout_cpu),
    .dout       (oki_dout_w),
    // ROM interface
    .rom_addr   (oki_rom_addr_w),
    .rom_data   (oki_rom_data_w),
    .rom_ok     (oki_rom_ok_w),
    // Audio
    .sound      (oki_sound_w),
    .sample     (oki_sample_w)
);

// =============================================================================
// YM2149 (AY-3-8910) PSG — Stub
// =============================================================================
// jt49 (YM2149 core) is not yet available in the jtcores modules tree.
// Instantiate when jt49.v is added under jtcores/modules/jt49/hdl/.
// For now, PSG output is silent.
//
// Planned interface:
//   jt49 u_ym2149 (
//       .rst_n(reset_n), .clk(clk_sys), .clk_en(clk_sound_cen),
//       .cs_n(1'b1), .wr_n(1'b1), .a9(1'b0), .din(8'hFF),
//       .sound(ym_sound_w), ...
//   );
logic signed [9:0] ym_sound_w;
assign ym_sound_w = 10'sd0;   // silence until jt49 integrated

// =============================================================================
// Audio Mix — OKI M6295 + YM2149 → snd_left / snd_right
// =============================================================================
// Scale OKI 14-bit signed → 16-bit by left-shifting 2, clip to 16-bit range.
// YM2149 stub is 0; add here when jt49 is wired.

// Sign-extend OKI 14-bit → 16-bit (arithmetic left shift 2) combinationally
logic signed [15:0] oki_16;
assign oki_16 = {oki_sound_w, 2'b00};   // sign-extend: MSB stays, 2 LSBs appended

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        snd_left  <= 16'h0000;
        snd_right <= 16'h0000;
    end else begin
        // OKI is mono; route to both channels.
        snd_left  <= oki_16;
        snd_right <= oki_16;
    end
end

// =============================================================================
// Program ROM Request Bridge
// =============================================================================
// Toggle-handshake to SDRAM. CPU stalls via cpu_dtack_n.

logic prog_req_pending;
logic [19:1] prog_req_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        prog_rom_req     <= 1'b0;
        prog_req_pending <= 1'b0;
        prog_req_addr_r  <= 19'b0;
    end else begin
        if (prog_rom_cs && cpu_rw && !prog_req_pending) begin
            prog_req_addr_r  <= cpu_addr[19:1];
            prog_req_pending <= 1'b1;
            prog_rom_req     <= ~prog_rom_req;
        end else if (prog_req_pending && (prog_rom_req == prog_rom_ack)) begin
            prog_req_pending <= 1'b0;
        end
    end
end

assign prog_rom_addr = prog_req_addr_r;

// =============================================================================
// CPU Data Bus Read Mux
// =============================================================================
// Priority: kaneko16 > palette RAM > I/O > WRAM > prog ROM > open bus

always_comb begin
    if (!k16_cs_n || !spr_cs_n || !vram_cs_n)
        cpu_din = k16_dout;
    else if (palram_cs)
        cpu_din = palram_cpu_dout;
    else if (io_cs)
        cpu_din = {8'hFF, io_dout_byte};
    else if (wram_cs)
        cpu_din = wram_dout_r;
    else if (prog_rom_cs)
        cpu_din = prog_rom_data;
    else
        cpu_din = 16'hFFFF;   // open bus
end

// =============================================================================
// DTACK Generation
// =============================================================================
// Prog ROM: stall until SDRAM ack (prog_req_pending goes low).
// All other devices: 1-cycle DTACK (registered any_fast_cs).

logic any_fast_cs;
logic dtack_r;

assign any_fast_cs = !k16_cs_n | !spr_cs_n | !vram_cs_n | palram_cs | io_cs | wram_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) dtack_r <= 1'b0;
    else          dtack_r <= any_fast_cs;
end

always_comb begin
    if (cpu_as_n)
        cpu_dtack_n = 1'b1;
    else if (prog_rom_cs)
        cpu_dtack_n = prog_req_pending;   // 0 when SDRAM returns data
    else
        cpu_dtack_n = !dtack_r;
end

// =============================================================================
// Interrupt (IPL) Generation
// =============================================================================
// Kaneko16 Berlin Wall: VBLANK IRQ at level 4 (IPL = 3'b011, active-low ~4)

logic ipl_vbl_active;
logic [15:0] ipl_vbl_timer;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl_vbl_active <= 1'b0;
        ipl_vbl_timer  <= 16'b0;
    end else begin
        if (vblank_rising) begin
            ipl_vbl_active <= 1'b1;
            ipl_vbl_timer  <= 16'hFFFF;
        end else if (ipl_vbl_active) begin
            if (ipl_vbl_timer == 16'b0)
                ipl_vbl_active <= 1'b0;
            else
                ipl_vbl_timer <= ipl_vbl_timer - 16'd1;
        end
    end
end

// VBLANK → IRQ level 4: cpu_ipl_n = ~4 = 3'b011
always_comb begin
    if (ipl_vbl_active) cpu_ipl_n = 3'b011;   // level 4 VBLANK
    else                cpu_ipl_n = 3'b111;    // no interrupt
end

// =============================================================================
// Lint suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = &{
    1'b0,
    // Sound signals not consumed externally
    oki_sample_w,
    ym_sound_w,
    // Z80 signals not consumed at top level
    z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n, z80_iorq_n,
    // Kaneko16 outputs not consumed at integration level
    k16_scroll_x_0, k16_scroll_y_0,
    k16_scroll_x_1, k16_scroll_y_1,
    k16_scroll_x_2, k16_scroll_y_2,
    k16_scroll_x_3, k16_scroll_y_3,
    k16_layer_ctrl_1, k16_layer_ctrl_2, k16_layer_ctrl_3,
    k16_sprite_ctrl, k16_map_base_sel, k16_gfx_bank_sel,
    k16_video_int_ctrl,
    k16_vblank_irq, k16_hblank_irq,
    k16_watchdog_reset, k16_watchdog_counter,
    k16_mcu_status, k16_mcu_command, k16_mcu_param1, k16_mcu_param2,
    k16_joystick_1_out, k16_joystick_2_out,
    k16_coin_in_out, k16_dip_switches_out,
    k16_display_list_count, k16_display_list_ready,
    k16_irq_vblank,
    k16_bg_pix_valid,
    k16_bg_pix_color[0], k16_bg_pix_color[1],
    k16_bg_pix_color[2], k16_bg_pix_color[3],
    k16_bg_pix_priority,
    k16_spr_rd_color, k16_spr_rd_valid,
    k16_spr_rd_priority, k16_spr_render_done, k16_spr_rom_rd,
    k16_final_valid,
    pal_entry_r[15],           // unused transparent/MSB bit
    gfx_byte_out               // used only in gfx_is_sprite==0 path
};
/* verilator lint_on UNUSED */

endmodule
