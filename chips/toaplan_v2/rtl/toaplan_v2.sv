// =============================================================================
// toaplan_v2.sv — Toaplan V2 System Board Top-Level Integration
// =============================================================================
//
// Implements the Toaplan V2 arcade board (Batsugun target).
//
// Instantiates and wires:
//   GP9001    — graphics processor (tilemaps + sprites + priority mixer)
//   Work RAM  — 64KB at 0x100000–0x10FFFF
//   Palette RAM — 512 × 16-bit at 0x500000–0x5003FF (RGB555 format)
//   I/O regs  — joysticks, coins, DIP switches at 0x700000–0x700FFF
//
// Stubs (silence output, no logic):
//   Z80 sound CPU
//   YM2151 + OKI M6295 audio
//
// Address map (byte addresses, from MAME toaplan2.cpp):
//   0x000000–0x0FFFFF   1MB     Program ROM (from SDRAM)
//   0x100000–0x10FFFF   64KB    Work RAM
//   0x400000–0x40FFFF   64KB    GP9001 (registers + sprite RAM + VRAM)
//   0x500000–0x5003FF   1KB     Palette RAM (512 × 16-bit, R5G5B5)
//   0x700000–0x700FFF   4KB     I/O registers
//
// IRQ assignment (from MAME):
//   IRQ2 (IPL = 3'b101) — VBLANK
//   IRQ1 (IPL = 3'b110) — GP9001 sprite scan complete
//
// Video timing: 320×240, standard arcade horizontal/vertical rates.
// Palette format: 0xRRRRRGGGGGBBBBB (standard GP9001 5-5-5 RGB).
//
// Reference: MAME src/mame/toaplan/toaplan2.cpp, batsugun driver
//            chips/gp9001/rtl/gp9001.sv
//            chips/toaplan/README.md
//
// =============================================================================
`default_nettype none

// ============================================================================
// Typedef: GP9001 Sprite Display List Entry
// Guard against redefinition when compiled alongside gp9001.sv
// (Verilator sees both files in a single compilation unit).
// ============================================================================
`ifndef SPRITE_ENTRY_T_DEFINED
`define SPRITE_ENTRY_T_DEFINED
typedef struct packed {
    logic [8:0]  x;         // X position (9-bit)
    logic [8:0]  y;         // Y position (9-bit)
    logic [9:0]  tile_num;  // tile index
    logic        flip_x;
    logic        flip_y;
    logic        prio;      // 0 = below BG, 1 = above BG
    logic [3:0]  palette;
    logic [1:0]  size;      // 0=8×8, 1=16×16, 2=32×32, 3=64×64
    logic        valid;
} sprite_entry_t;
`endif

/* verilator lint_off SYNCASYNCNET */
module toaplan_v2 #(
    // ── Address decode parameters (WORD addresses = byte_addr >> 1) ────────────
    //
    // Two pre-defined address map configurations are documented below.
    // Select by setting the DUAL_VDP parameter and passing the appropriate BASE
    // constants when instantiating:
    //
    // CONFIG A — Truxton II (single GP9001, default):
    //   GP9001 #0:  byte 0x400000–0x40FFFF → GP9001_BASE = 23'h200000
    //   Palette:    byte 0x500000–0x5003FF → PALRAM_BASE = 23'h280000
    //   I/O:        byte 0x700000–0x700FFF → IO_BASE     = 23'h380000
    //   Work RAM:   byte 0x100000–0x10FFFF → WRAM_BASE   = 23'h080000
    //   YM2151:     byte 0x600000–0x600001 (hardcoded decode, not a parameter)
    //
    // CONFIG B — Batsugun / Dogyuun / V-Five / Knuckle Bash / Snow Bros 2 (dual GP9001):
    //   GP9001 #0:  byte 0x300000–0x30000D → GP9001_BASE  = 23'h180000  (word 0x300000>>1)
    //   Palette:    byte 0x400000–0x400FFF → PALRAM_BASE  = 23'h200000  (word 0x400000>>1)
    //   GP9001 #1:  byte 0x500000–0x50000D → GP9001_1_BASE= 23'h280000  (word 0x500000>>1)
    //   I/O:        byte 0x200010–0x200019 → IO_BASE      = 23'h100008  (word 0x200010>>1)
    //   Work RAM:   byte 0x100000–0x10FFFF → WRAM_BASE    = 23'h080000  (unchanged)
    //   V25 shared: byte 0x210000–0x21FFFF → SHARED_BASE  = 23'h108000  (word 0x210000>>1)
    //   Enable:     DUAL_VDP = 1
    //
    // NOTE: ALM budget concern (documented in .shared/findings.md TASK-202):
    //   Single GP9001 ≈ 12K ALMs.  Dual GP9001 ≈ 24K ALMs.
    //   toaplan_v2 already at 66% (≈27K of 41K ALMs) in CI run #23267780482.
    //   Dual-VDP configuration will overflow the DE-10 Nano without optimization.
    //   Options (see findings.md for full analysis):
    //     A) Dedicated batsugun_arcade/ system with trimmed, shared-pipeline GP9001
    //     B) Time-multiplexed single GP9001 with dual register banks (~50% ALM saving)
    //     C) Larger FPGA target (not DE-10 Nano compatible)
    //   This parameter + address decoder is the GROUNDWORK for option A or B.
    //   It is synthesizable and correct but will not fit a single DE-10 Nano as-is.

    // Select dual-VDP mode: 0 = Truxton II single VDP, 1 = Batsugun dual VDP
    parameter bit          DUAL_VDP    = 0,

    // GP9001 #0 chip select: see CONFIG A/B above
    parameter logic [23:1] GP9001_BASE  = 23'h200000,  // CONFIG A default: byte 0x400000 >> 1
    // GP9001 #1 chip select (only used when DUAL_VDP=1)
    parameter logic [23:1] GP9001_1_BASE = 23'h280000, // CONFIG B: byte 0x500000 >> 1
    // Palette RAM: see CONFIG A/B above
    parameter logic [23:1] PALRAM_BASE  = 23'h280000,  // CONFIG A default: byte 0x500000 >> 1
    // I/O: see CONFIG A/B above
    parameter logic [23:1] IO_BASE      = 23'h380000,  // CONFIG A default: byte 0x700000 >> 1
    // Work RAM: byte 0x100000–0x10FFFF → word base 0x080000 (same in both configs)
    parameter logic [23:1] WRAM_BASE    = 23'h080000,  // byte 0x100000 >> 1
    parameter int          WRAM_WORDS   = 32768,        // 64KB / 2 = 32K words
    // V25 shared RAM (CONFIG B only; ignored when DUAL_VDP=0)
    // byte 0x210000–0x21FFFF → word base 0x108000, 15-bit window
    parameter logic [23:1] SHARED_BASE  = 23'h108000,  // byte 0x210000 >> 1
    parameter int          SHARED_WORDS = 32768         // 64KB / 2 = 32K words

) (
    input  logic        clk_sys,
    input  logic        clk_pix,         // pixel clock enable (1-cycle pulse, sys-domain)
    input  logic        reset_n,

    // ── CPU bus (from fx68k_adapter) ───────────────────────────────────────────
    input  logic [23:1] cpu_addr,
    input  logic [15:0] cpu_dout,        // data FROM cpu (write path)
    output logic [15:0] cpu_din,         // data TO cpu (read path mux)
    input  logic        cpu_rw,          // 1=read, 0=write
    input  logic        cpu_as_n,        // address strobe (active low)
    input  logic        cpu_uds_n,       // upper data strobe (active low)
    input  logic        cpu_lds_n,       // lower data strobe (active low)
    output logic        cpu_dtack_n,     // data transfer acknowledge (active low)
    output logic [2:0]  cpu_ipl_n,       // interrupt priority level (active low encoded)
    input  logic        cpu_inta_n,      // interrupt acknowledge (active low, FC=111 & ASn=0)

    // ── Program ROM (from SDRAM) ───────────────────────────────────────────────
    // prog_rom_addr is a WORD address (byte_addr[19:1]).
    output logic [19:1] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM (sprite + BG tiles, from SDRAM) ────────────────────────────────
    // 32-bit wide for tile fetch efficiency (GP9001 reads 4bpp packed bytes).
    // gfx_rom_addr is a WORD address (byte_addr >> 1).
    output logic [21:0] gfx_rom_addr,
    input  logic [31:0] gfx_rom_data,
    output logic        gfx_rom_req,
    input  logic        gfx_rom_ack,

    // ── Audio output ───────────────────────────────────────────────────────────
    output logic signed [15:0] snd_left,    // mixed FM + ADPCM (signed)
    output logic signed [15:0] snd_right,

    // ── ADPCM ROM (OKI M6295 samples, from SDRAM CH3) ─────────────────────────
    output logic [23:0] adpcm_rom_addr,
    output logic        adpcm_rom_req,
    input  logic [15:0] adpcm_rom_data,
    input  logic        adpcm_rom_ack,

    // ── Z80 Sound CPU ROM (from SDRAM — shared CH1 time-multiplexed) ──────────
    // Z80 ROM sits at SDRAM byte offset 0x600000 (ioctl_index 0x03).
    // Toggle-req/ack handshake; Z80 stalls via WAIT_n until ack returns.
    output logic [15:0] z80_rom_addr,       // Z80 16-bit address
    output logic        z80_rom_req,        // toggle on new request
    input  logic  [7:0] z80_rom_data,       // byte returned from SDRAM
    input  logic        z80_rom_ack,        // toggle when data is ready

    // ── Sound CPU clock enable (3.5 MHz) ───────────────────────────────────────
    input  logic        clk_sound,          // 3.5 MHz CE pulse in clk_sys domain

    // ── Video output ───────────────────────────────────────────────────────────
    output logic [7:0]  rgb_r,
    output logic [7:0]  rgb_g,
    output logic [7:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Player inputs ──────────────────────────────────────────────────────────
    // Active-low convention.
    // [7]=BTN3 [6]=BTN2 [5]=BTN1 [4]=START [3]=RIGHT [2]=LEFT [1]=DOWN [0]=UP
    input  logic [7:0]  joystick_p1,
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,            // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service,         // service button (active low)
    input  logic [7:0]  dipsw1,          // DIP switch bank 1
    input  logic [7:0]  dipsw2           // DIP switch bank 2
);

// =============================================================================
// Local parameters
// =============================================================================

localparam int WRAM_ABITS = $clog2(WRAM_WORDS);   // 15

// =============================================================================
// Video Timing Generator — 320×240 standard arcade
// =============================================================================
//
// From MAME toaplan2.cpp / truxton2.cpp:
//   m_screen->set_raw(27_MHz_XTAL/4, 432, 0, 320, 262, 0, 240);
//   Pixel clock: 27 MHz / 4 = 6.75 MHz
//   HTOTAL = 432 (320 active + 112 blanking)
//   VTOTAL = 262 (240 active + 22 blanking)
//
// Blanking breakdown (standard arcade timings summing to MAME totals):
//   Horizontal: 320 active, 8 front porch, 32 sync, 72 back porch = 432 total
//   Vertical:   240 active, 8 front porch, 4  sync, 10 back porch = 262 total
//
// NOTE: The sim drives clk_pix using a fractional accumulator (27/128 per sys_clk)
// to generate 6.75 MHz pixel clock from 32 MHz sys_clk.  See tb_system.cpp.
//
localparam int H_ACTIVE = 320;
localparam int H_FP     = 8;
localparam int H_SYNC   = 32;
localparam int H_BP     = 72;
localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 432

localparam int V_ACTIVE = 240;
localparam int V_FP     = 8;
localparam int V_SYNC   = 4;
localparam int V_BP     = 10;
localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;    // 262

logic [8:0] hpos_r;    // 0..431
logic [8:0] vpos_r;    // 0..261
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

        // HSync: asserted during sync pulse
        hsync_r <= ~((hpos_r >= 9'(H_ACTIVE + H_FP)) && (hpos_r < 9'(H_ACTIVE + H_FP + H_SYNC)));
        // VSync: asserted during sync pulse
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

// Active pixel positions fed to GP9001 (within visible area only)
wire [8:0] pix_hpos = (hpos_r < 9'(H_ACTIVE)) ? hpos_r : 9'h000;
wire [8:0] pix_vpos = (vpos_r < 9'(V_ACTIVE)) ? vpos_r : 9'h000;

// VBLANK edge detection for sprite scanner trigger
logic vblank_prev;
logic vblank_rising;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) vblank_prev <= 1'b0;
    else          vblank_prev <= vblank_r;
end

assign vblank_rising = vblank_r & ~vblank_prev;

// =============================================================================
// Chip-Select Decode
// =============================================================================

// Program ROM: 0x000000–0x0FFFFF (byte), word 0x000000–0x07FFFF
//   19-bit window: word addr bits [23:19] must all be zero (1MB / 2 = 512K words)
logic prog_rom_cs;
assign prog_rom_cs = (cpu_addr[23:19] == 5'b00000) && !cpu_as_n;

// Work RAM: byte 0x100000–0x10FFFF → word 0x080000–0x087FFF (15-bit)
logic wram_cs;
assign wram_cs = (cpu_addr[23:WRAM_ABITS+1] == WRAM_BASE[23:WRAM_ABITS+1]) && !cpu_as_n;

// GP9001 #0: chip-relative 11-bit window (addr[10:0] passed to gp9001 .addr port)
logic gp9001_cs_n;
assign gp9001_cs_n = !((cpu_addr[23:11] == GP9001_BASE[23:11]) && !cpu_as_n);

// GP9001 #1 (CONFIG B — Batsugun dual-VDP only):
//   byte 0x500000–0x50000D → word 0x280000.  Only 7 word addresses used
//   (the GP9001 INDIRECT access protocol uses offsets 0..6 within the window).
//   Decode: addr[23:11] == GP9001_1_BASE[23:11]
logic gp9001_1_cs_n;
generate
    if (DUAL_VDP) begin : gen_vdp1_cs
        assign gp9001_1_cs_n = !((cpu_addr[23:11] == GP9001_1_BASE[23:11]) && !cpu_as_n);
    end else begin : gen_vdp1_cs_tie
        assign gp9001_1_cs_n = 1'b1;  // deasserted — no second VDP
    end
endgenerate

// Palette RAM (window size differs between configs):
//   CONFIG A: byte 0x500000–0x5003FF → word 0x280000, 9-bit (512 words = 1KB)
//   CONFIG B: byte 0x400000–0x400FFF → word 0x200000, 11-bit (4096 words = 8KB)
// Both configs use addr[23:9] comparison — adequate for CONFIG A; CONFIG B palette
// is the full 0x400000 block (11-bit), but for chip select detection addr[23:9]
// still uniquely identifies the range provided GP9001_1 and GP9001_0 differ at [23:11].
logic palram_cs;
assign palram_cs = (cpu_addr[23:9] == PALRAM_BASE[23:9]) && !cpu_as_n;

// I/O:
//   CONFIG A: byte 0x700000–0x700FFF → word 0x380000, 11-bit
//   CONFIG B: byte 0x200010–0x200019 → word 0x100008, only 5 word addresses
//             addr[23:11] comparison gives byte 0x200000–0x2007FF window;
//             individual register decode uses addr[4:1] inside the window.
logic io_cs;
assign io_cs = (cpu_addr[23:11] == IO_BASE[23:11]) && !cpu_as_n;

// V25 shared RAM (CONFIG B only): byte 0x210000–0x21FFFF → word 0x108000, 15-bit
// Only instantiated/decoded when DUAL_VDP=1.  Stub returns open bus when DUAL_VDP=0.
localparam int SHARED_ABITS = $clog2(SHARED_WORDS);  // 15
logic shared_cs;
generate
    if (DUAL_VDP) begin : gen_shared_cs
        assign shared_cs = (cpu_addr[23:SHARED_ABITS+1] == SHARED_BASE[23:SHARED_ABITS+1]) && !cpu_as_n;
    end else begin : gen_shared_cs_tie
        assign shared_cs = 1'b0;
    end
endgenerate

// DEBUG: trace io_cs and address decode
`ifndef SYNTHESIS
// Use a registered wire to hold the byte addr so we can log without 'automatic'
logic [23:0] io_dbg_byte_addr;
assign io_dbg_byte_addr = {cpu_addr, 1'b0};
always_ff @(posedge clk_sys) begin
    if (!cpu_as_n && io_dbg_byte_addr[23:20] == 4'h7)
        $display("[IO_ACCESS] cpu_addr=%06x cpu_addr[23:11]=%04x IO_BASE[23:11]=0e00 match=%b io_cs=%b cpu_din=%04x dtack=%b",
                 io_dbg_byte_addr, io_dbg_byte_addr,
                 (cpu_addr[23:11] == IO_BASE[23:11]),
                 io_cs, cpu_din, cpu_dtack_n);
end
`endif

// YM2151 (68K-direct): byte 0x600000–0x600001 → word 0x300000
//   Truxton II drives YM2151 directly from the 68K (no Z80 sound CPU).
//   Poll loop patterns observed in firmware:
//     Loop A: BTST #8; BEQ loop — exits when bit 8 = 1 (wait-for-NOT-busy)
//     Loop B: BTST #8; BNE loop — exits when bit 8 = 0 (wait-for-busy)
//     Loop C: MOVE.W; BMI; MOVE.W; ADDQ+CMPI.B #0xF1; BCS — exits when byte ≥ 0xF1
//     Loop D: MOVE.W; BMI; CMPI.B #0xEF; BCC — exits when byte ≥ 0xEF
//
//   Stub: fixed low byte = 0xF0 (so +1 = 0xF1 → BCS/BCC exits in 1 pass).
//   Bit 8 toggles every 256 clocks for BTST#8 BEQ/BNE loops.
//   The Z80-side jt51 instance is separate and used only for audio output.
logic ym_cpu_cs;
assign ym_cpu_cs = (cpu_addr[23:1] == 23'h300000) && !cpu_as_n;

// Free-running counter: increments every system clock.
// CPU reads see a cycling byte that covers all wait loop types:
//
//   Loop A/B (BTST #8; BEQ/BNE): bit 8 toggles every 256 clocks → exits ≤256 reads
//   Loop C   (MOVE.W; BMI; MOVE.W; ADDQ #1; CMPI.B #$F1; BCS):
//              byte cycles 0→255 every 256 clocks; exits when byte >= 0xF0 (+1=0xF1)
//              consecutive reads ~6 clocks apart → at most ~40 iterations to exit
//   Loop D   (MOVE.W; BMI; MOVE.W; CMPI.B #0xEF; BCC):
//              exits when byte < 0xEF; cycles 0→255 → exits in at most ~40 iterations
//
//   Loop C and D have CONTRADICTORY requirements for a fixed byte (C needs ≥0xF0,
//   D needs <0xEF), so the byte MUST cycle. With ctr[7:0] advancing ~6/read, each
//   inner loop exits within ~40 iterations → total init time ≈ few frames vs. 57+.
//
// Returned word layout:
//   bit 15   = 0           → BMI never taken (not busy)
//   bits 14:9 = 0
//   bit 8    = ctr[8]      → toggles every 256 clocks for BTST#8 loops
//   bits 7:0 = ctr[7:0]    → cycles 0→255 every 256 clocks for CMPI loops
logic [8:0] ym_free_ctr;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) ym_free_ctr <= '0;
    else          ym_free_ctr <= ym_free_ctr + 1'b1;
end

wire [15:0] ym_cpu_dout = {7'b0, ym_free_ctr[8], ym_free_ctr[7:0]};

// =============================================================================
// GP9001 — Graphics Processor
// =============================================================================

logic [15:0] gp9001_dout;
logic        gp9001_irq_sprite;

// GP9001 GFX ROM bridge signals
logic [19:0] bg_rom_addr_raw;    // from GP9001 Gate 3
logic [7:0]  bg_rom_data_r;      // fed back to GP9001
logic [3:0]  bg_layer_sel;       // one-hot layer select from GP9001

logic [24:0] spr_rom_addr_raw;   // from GP9001 Gate 4 (25-bit byte address, bank-extended)
logic        spr_rom_rd;         // GP9001 read strobe
logic [7:0]  spr_rom_data_r;     // fed back to GP9001

// Gate 3/4 BG and sprite outputs (unused in stub — silence)
logic [3:0]  bg_pix_valid_w;
logic [3:0][7:0]  bg_pix_color_w;
logic [3:0]  bg_pix_priority_w;
logic [15:0] vram_dout_w;

// Gate 4 sprite outputs
logic [8:0]  spr_rd_addr_w;
logic [7:0]  spr_rd_color_w;
logic        spr_rd_valid_w;
logic        spr_rd_priority_w;
logic        spr_render_done_w;

// Gate 5 pixel output
logic [7:0]  final_color_w;
logic        final_valid_w;

// Scan trigger: pulse at hblank falling edge during active display
logic hblank_prev;
logic scan_trigger_w;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) hblank_prev <= 1'b0;
    else          hblank_prev <= hblank_r;
end

// Falling edge of hblank (transition active→display) triggers scanline render
assign scan_trigger_w = hblank_prev & ~hblank_r;

// GP9001 display-list outputs (not used in system integration yet)
/* verilator lint_off UNUSED */
sprite_entry_t display_list_w [0:255];
logic [7:0]    display_list_count_w;
logic          display_list_ready_w;
/* verilator lint_on UNUSED */

// GP9001 register outputs (not needed at integration level)
logic [7:0][15:0] scroll_w;
logic [15:0] scroll0_x_w, scroll0_y_w, scroll1_x_w, scroll1_y_w;
logic [15:0] scroll2_x_w, scroll2_y_w, scroll3_x_w, scroll3_y_w;
logic [15:0] rowscroll_ctrl_w, layer_ctrl_w, sprite_ctrl_w;
logic [15:0] layer_size_w, color_key_w, blend_ctrl_w;
logic [1:0]  num_layers_active_w, bg0_priority_w, bg1_priority_w, bg23_priority_w;
logic [3:0]  sprite_list_len_code_w;
logic [1:0]  sprite_sort_mode_w, sprite_prefetch_mode_w;
logic        sprite_en_w;
logic [9:0]  scan_addr_w;
logic [15:0] scan_dout_w;

assign scan_addr_w = 10'h000;   // tie off debug port

gp9001 #(
    .NUM_LAYERS    (2), // Batsugun: 2 active BG layers (BG0 + BG1)
    .OBJECTBANK_EN (0)  // Batsugun does NOT use object bank switching (Batrider/Bakraid only)
) u_gp9001 (
    .clk        (clk_sys),
    .rst_n      (reset_n),

    // CPU interface — chip-relative 11-bit word address: cpu_addr[11:1]
    .addr       (cpu_addr[11:1]),
    .din        (cpu_dout),
    .dout       (gp9001_dout),
    .cs_n       (gp9001_cs_n),
    .rd_n       (cpu_rw  ? 1'b0 : 1'b1),   // rd_n active low when cpu reads
    .wr_n       (!cpu_rw ? 1'b0 : 1'b1),   // wr_n active low when cpu writes

    // Video timing
    .vsync      (~vsync_r),     // active-high for GP9001 (vsync_r is active-low)
    .vblank     (vblank_r),

    // Interrupt output
    .irq_sprite (gp9001_irq_sprite),

    // Register outputs (tie to local wires; unused at integration level)
    .scroll             (scroll_w),
    .scroll0_x          (scroll0_x_w),
    .scroll0_y          (scroll0_y_w),
    .scroll1_x          (scroll1_x_w),
    .scroll1_y          (scroll1_y_w),
    .scroll2_x          (scroll2_x_w),
    .scroll2_y          (scroll2_y_w),
    .scroll3_x          (scroll3_x_w),
    .scroll3_y          (scroll3_y_w),
    .rowscroll_ctrl     (rowscroll_ctrl_w),
    .layer_ctrl         (layer_ctrl_w),
    .num_layers_active  (num_layers_active_w),
    .bg0_priority       (bg0_priority_w),
    .bg1_priority       (bg1_priority_w),
    .bg23_priority      (bg23_priority_w),
    .sprite_ctrl        (sprite_ctrl_w),
    .sprite_list_len_code (sprite_list_len_code_w),
    .sprite_sort_mode   (sprite_sort_mode_w),
    .sprite_prefetch_mode (sprite_prefetch_mode_w),
    .layer_size         (layer_size_w),
    .color_key          (color_key_w),
    .blend_ctrl         (blend_ctrl_w),
    .sprite_en          (sprite_en_w),

    // Sprite RAM debug scan port
    .scan_addr  (scan_addr_w),
    .scan_dout  (scan_dout_w),

    // Gate 2: Display list
    .display_list       (display_list_w),
    .display_list_count (display_list_count_w),
    .display_list_ready (display_list_ready_w),

    // Gate 3: Tilemap pixel pipeline
    .hpos           (pix_hpos),
    .vpos           (pix_vpos),
    .hblank         (hblank_r),
    .vblank_in      (vblank_r),
    .bg_pix_valid   (bg_pix_valid_w),
    .bg_pix_color   (bg_pix_color_w),
    .bg_pix_priority (bg_pix_priority_w),
    .bg_rom_addr    (bg_rom_addr_raw),
    .bg_rom_data    (bg_rom_data_r),
    .bg_layer_sel   (bg_layer_sel),
    .vram_dout      (vram_dout_w),

    // Object bank switching (disabled for Batsugun; OBJECTBANK_EN=0 above)
    .obj_bank_wr   (1'b0),
    .obj_bank_slot (3'h0),
    .obj_bank_val  (4'h0),

    // Gate 4: Sprite rasterizer
    .scan_trigger      (scan_trigger_w),
    .current_scanline  (pix_vpos),
    .spr_rom_addr      (spr_rom_addr_raw),
    .spr_rom_rd        (spr_rom_rd),
    .spr_rom_data      (spr_rom_data_r),
    .spr_rd_addr       (spr_rd_addr_w),
    .spr_rd_color      (spr_rd_color_w),
    .spr_rd_valid      (spr_rd_valid_w),
    .spr_rd_priority   (spr_rd_priority_w),
    .spr_render_done   (spr_render_done_w),

    // Gate 5: Priority mixer outputs
    .final_color    (final_color_w),
    .final_valid    (final_valid_w)
);

// Feed current pixel X back to Gate 4 scanline buffer read port
assign spr_rd_addr_w = pix_hpos;

// =============================================================================
// GP9001 #1 — Second VDP (Batsugun / Dogyuun / dual-VDP games, DUAL_VDP=1 only)
// =============================================================================
//
// ALM budget warning: see parameter comment block at top of module.
// This block is entirely inside generate DUAL_VDP so it synthesises away when
// DUAL_VDP=0, preserving 100% compatibility with the Truxton II configuration.
//
// VDP#1 uses the same GFX ROM SDRAM channel as VDP#0 (time-multiplexed in the
// GFX ROM SDRAM bridge below).  The arbitration priority is:
//   spr_rom_rd (VDP#0) > spr_rom_rd (VDP#1) > bg_rom (VDP#0) > bg_rom (VDP#1)
// This avoids a dedicated second SDRAM channel at the cost of reduced fill rate
// for VDP#1 tiles when VDP#0 sprite ROM is busy.  For Batsugun's GFX ROM layout
// this is acceptable — the two VDPs share the same tile ROM data.
//
// VDP#1 data-bus output is ORed into cpu_din via the read mux below.

// VDP#1 signal wires — declared in generate scope for Verilator compatibility
logic [15:0] gp9001_1_dout;
logic        gp9001_1_irq_sprite;

// Gate 3/4/5 outputs from VDP#1
logic [3:0]       bg_pix_valid_1_w;
logic [3:0][7:0]  bg_pix_color_1_w;
logic [3:0]       bg_pix_priority_1_w;
logic [19:0]      bg_rom_addr_1_raw;
logic [7:0]       bg_rom_data_1_r;
logic [3:0]       bg_layer_sel_1;
logic [15:0]      vram_dout_1_w;
logic [24:0]      spr_rom_addr_1_raw;
logic             spr_rom_rd_1;
logic [7:0]       spr_rom_data_1_r;
logic [8:0]       spr_rd_addr_1_w;
logic [7:0]       spr_rd_color_1_w;
logic             spr_rd_valid_1_w;
logic             spr_rd_priority_1_w;
logic             spr_render_done_1_w;
logic [7:0]       final_color_1_w;
logic             final_valid_1_w;

/* verilator lint_off UNUSED */
// VDP#1 register outputs (not consumed at integration level)
sprite_entry_t    display_list_1_w [0:255];
logic [7:0]       display_list_count_1_w;
logic             display_list_ready_1_w;
logic [7:0][15:0] scroll_1_w;
logic [15:0]      scroll0_x_1_w, scroll0_y_1_w, scroll1_x_1_w, scroll1_y_1_w;
logic [15:0]      scroll2_x_1_w, scroll2_y_1_w, scroll3_x_1_w, scroll3_y_1_w;
logic [15:0]      rowscroll_ctrl_1_w, layer_ctrl_1_w, sprite_ctrl_1_w;
logic [15:0]      layer_size_1_w, color_key_1_w, blend_ctrl_1_w;
logic [1:0]       num_layers_active_1_w, bg0_priority_1_w, bg1_priority_1_w, bg23_priority_1_w;
logic [3:0]       sprite_list_len_code_1_w;
logic [1:0]       sprite_sort_mode_1_w, sprite_prefetch_mode_1_w;
logic             sprite_en_1_w;
logic [9:0]       scan_addr_1_w;
logic [15:0]      scan_dout_1_w;
/* verilator lint_on UNUSED */
assign scan_addr_1_w = 10'h000;
assign spr_rd_addr_1_w = pix_hpos;

generate
    if (DUAL_VDP) begin : gen_vdp1

        gp9001 #(
            .NUM_LAYERS    (2), // Batsugun VDP#1: 2 active BG layers
            .OBJECTBANK_EN (0)
        ) u_gp9001_1 (
            .clk        (clk_sys),
            .rst_n      (reset_n),

            // CPU interface — chip-relative 11-bit word address
            .addr       (cpu_addr[11:1]),
            .din        (cpu_dout),
            .dout       (gp9001_1_dout),
            .cs_n       (gp9001_1_cs_n),
            .rd_n       (cpu_rw  ? 1'b0 : 1'b1),
            .wr_n       (!cpu_rw ? 1'b0 : 1'b1),

            // Video timing — shared with VDP#0
            .vsync      (~vsync_r),
            .vblank     (vblank_r),

            // Interrupt (VDP#1 sprite IRQ wired same as VDP#0 — both contribute to level-1)
            .irq_sprite (gp9001_1_irq_sprite),

            // Register outputs
            .scroll             (scroll_1_w),
            .scroll0_x          (scroll0_x_1_w),
            .scroll0_y          (scroll0_y_1_w),
            .scroll1_x          (scroll1_x_1_w),
            .scroll1_y          (scroll1_y_1_w),
            .scroll2_x          (scroll2_x_1_w),
            .scroll2_y          (scroll2_y_1_w),
            .scroll3_x          (scroll3_x_1_w),
            .scroll3_y          (scroll3_y_1_w),
            .rowscroll_ctrl     (rowscroll_ctrl_1_w),
            .layer_ctrl         (layer_ctrl_1_w),
            .num_layers_active  (num_layers_active_1_w),
            .bg0_priority       (bg0_priority_1_w),
            .bg1_priority       (bg1_priority_1_w),
            .bg23_priority      (bg23_priority_1_w),
            .sprite_ctrl        (sprite_ctrl_1_w),
            .sprite_list_len_code (sprite_list_len_code_1_w),
            .sprite_sort_mode   (sprite_sort_mode_1_w),
            .sprite_prefetch_mode (sprite_prefetch_mode_1_w),
            .layer_size         (layer_size_1_w),
            .color_key          (color_key_1_w),
            .blend_ctrl         (blend_ctrl_1_w),
            .sprite_en          (sprite_en_1_w),
            .scan_addr          (scan_addr_1_w),
            .scan_dout          (scan_dout_1_w),

            // Gate 2: Display list
            .display_list       (display_list_1_w),
            .display_list_count (display_list_count_1_w),
            .display_list_ready (display_list_ready_1_w),

            // Gate 3: Tilemap pixel pipeline
            .hpos           (pix_hpos),
            .vpos           (pix_vpos),
            .hblank         (hblank_r),
            .vblank_in      (vblank_r),
            .bg_pix_valid   (bg_pix_valid_1_w),
            .bg_pix_color   (bg_pix_color_1_w),
            .bg_pix_priority (bg_pix_priority_1_w),
            .bg_rom_addr    (bg_rom_addr_1_raw),
            .bg_rom_data    (bg_rom_data_1_r),
            .bg_layer_sel   (bg_layer_sel_1),
            .vram_dout      (vram_dout_1_w),

            // Object bank switching (disabled for Batsugun)
            .obj_bank_wr   (1'b0),
            .obj_bank_slot (3'h0),
            .obj_bank_val  (4'h0),

            // Gate 4: Sprite rasterizer
            .scan_trigger      (scan_trigger_w),
            .current_scanline  (pix_vpos),
            .spr_rom_addr      (spr_rom_addr_1_raw),
            .spr_rom_rd        (spr_rom_rd_1),
            .spr_rom_data      (spr_rom_data_1_r),
            .spr_rd_addr       (spr_rd_addr_1_w),
            .spr_rd_color      (spr_rd_color_1_w),
            .spr_rd_valid      (spr_rd_valid_1_w),
            .spr_rd_priority   (spr_rd_priority_1_w),
            .spr_render_done   (spr_render_done_1_w),

            // Gate 5: VDP#1 internal priority mixer output
            .final_color    (final_color_1_w),
            .final_valid    (final_valid_1_w)
        );

    end else begin : gen_vdp1_stub
        // Tie off all VDP#1 output signals when DUAL_VDP=0
        assign gp9001_1_dout        = 16'hFFFF;
        assign gp9001_1_irq_sprite  = 1'b0;
        assign bg_pix_valid_1_w     = 4'b0000;
        assign bg_pix_color_1_w     = '0;
        assign bg_pix_priority_1_w  = 4'b0000;
        assign bg_rom_addr_1_raw    = 20'b0;
        assign bg_layer_sel_1       = 4'b0000;
        assign vram_dout_1_w        = 16'hFFFF;
        assign spr_rom_addr_1_raw   = 25'b0;
        assign spr_rom_rd_1         = 1'b0;
        assign spr_rd_color_1_w     = 8'h00;
        assign spr_rd_valid_1_w     = 1'b0;
        assign spr_rd_priority_1_w  = 1'b0;
        assign spr_render_done_1_w  = 1'b0;
        assign final_color_1_w      = 8'h00;
        assign final_valid_1_w      = 1'b0;
    end
endgenerate

// =============================================================================
// Inter-VDP Priority Mixer (gp9001_priority_mix)
// =============================================================================
//
// When DUAL_VDP=0: pass-through — VDP#0 final_color/final_valid used directly.
// When DUAL_VDP=1: gp9001_priority_mix arbitrates the 10-layer (5+5) competition.
//
// The mixed_final_color / mixed_final_valid signals feed the palette RAM lookup
// (replacing the direct use of final_color_w / final_valid_w below).

logic [7:0] mixed_final_color;
logic       mixed_final_valid;

generate
    if (DUAL_VDP) begin : gen_prio_mix
        gp9001_priority_mix u_prio_mix (
            // VDP#0 inputs
            .vdp0_bg_valid  (bg_pix_valid_w),
            .vdp0_bg_color  (bg_pix_color_w),
            .vdp0_bg_prio   (bg_pix_priority_w),
            .vdp0_spr_valid (spr_rd_valid_w),
            .vdp0_spr_color (spr_rd_color_w),
            .vdp0_spr_prio  (spr_rd_priority_w),
            // VDP#1 inputs
            .vdp1_bg_valid  (bg_pix_valid_1_w),
            .vdp1_bg_color  (bg_pix_color_1_w),
            .vdp1_bg_prio   (bg_pix_priority_1_w),
            .vdp1_spr_valid (spr_rd_valid_1_w),
            .vdp1_spr_color (spr_rd_color_1_w),
            .vdp1_spr_prio  (spr_rd_priority_1_w),
            // Output
            .final_color    (mixed_final_color),
            .final_valid    (mixed_final_valid)
        );
    end else begin : gen_prio_pass
        // Single-VDP: use GP9001 Gate-5 output directly
        assign mixed_final_color = final_color_w;
        assign mixed_final_valid = final_valid_w;
    end
endgenerate

// =============================================================================
// V25 Shared RAM (DUAL_VDP=1 only) — 64KB BRAM at SHARED_BASE
// =============================================================================
//
// The NEC V25 sound CPU communicates with the M68000 via a shared 64KB RAM.
// In Batsugun, the V25 is not emulated (stub).  The shared RAM allows the
// main CPU to write sound commands and read status without a response hang.
// Reads return 0xFFFF (open-bus behavior) in the stub.
//
// When DUAL_VDP=0 shared_cs is always 0 so this block adds zero area.

logic [15:0] shared_ram_dout;

generate
    if (DUAL_VDP) begin : gen_shared_ram
        `ifndef QUARTUS
        logic [15:0] shared_ram [0:SHARED_WORDS-1];
        always_ff @(posedge clk_sys) begin
            if (shared_cs && !cpu_rw) begin
                if (!cpu_uds_n) shared_ram[cpu_addr[SHARED_ABITS:1]][15:8] <= cpu_dout[15:8];
                if (!cpu_lds_n) shared_ram[cpu_addr[SHARED_ABITS:1]][ 7:0] <= cpu_dout[ 7:0];
            end
        end
        always_ff @(posedge clk_sys) begin
            if (shared_cs) shared_ram_dout <= shared_ram[cpu_addr[SHARED_ABITS:1]];
        end
        `else
        // Synthesis: altsyncram SINGLE_PORT 64KB M10K
        logic [15:0] shared_dout_raw;
        altsyncram #(
            .operation_mode         ("SINGLE_PORT"),
            .width_a                (16),
            .widthad_a              (SHARED_ABITS),
            .numwords_a             (SHARED_WORDS),
            .outdata_reg_a          ("CLOCK0"),
            .clock_enable_input_a   ("BYPASS"),
            .clock_enable_output_a  ("BYPASS"),
            .intended_device_family ("Cyclone V"),
            .lpm_type               ("altsyncram"),
            .ram_block_type         ("M10K"),
            .width_byteena_a        (2),
            .power_up_uninitialized ("FALSE"),
            .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ")
        ) shared_ram_inst (
            .clock0     (clk_sys),
            .address_a  (cpu_addr[SHARED_ABITS:1]),
            .data_a     (cpu_dout),
            .wren_a     (shared_cs && !cpu_rw),
            .byteena_a  ({~cpu_uds_n, ~cpu_lds_n}),
            .q_a        (shared_dout_raw),
            .aclr0(1'b0), .addressstall_a(1'b0), .clocken0(1'b1), .clocken1(1'b1),
            .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1)
        );
        always_ff @(posedge clk_sys) begin
            if (shared_cs) shared_ram_dout <= shared_dout_raw;
        end
        `endif
    end else begin : gen_shared_stub
        assign shared_ram_dout = 16'hFFFF;
    end
endgenerate

// =============================================================================
// GFX ROM SDRAM Bridge — time-multiplexed BG tile + Sprite tile access
// =============================================================================
//
// GP9001 Gate 3 (BG tiles) and Gate 4 (sprite tiles) each produce byte
// addresses into the GFX ROM.  For now, a simple arbitration: bg_rom
// has lower priority, spr_rom wins when spr_rom_rd is asserted.
//
// gfx_rom_addr is a WORD address (byte_addr[21:1]).
// gfx_rom_data is 32-bit; we select the correct byte lane from bit[1:0]
// of the original byte address.
//
// SDRAM base layout for Batsugun GFX ROM:
//   - BG tiles start at SDRAM offset 0x000000 (gfx_rom_addr is direct)
//   - Sprite tiles are appended after BG tiles; offset added externally
//     via emu.sv (caller passes the correct SDRAM base in the ROM loader).
//
// Arbitration priority (highest first):
//   1. VDP#0 sprite ROM (spr_rom_rd)
//   2. VDP#1 sprite ROM (spr_rom_rd_1, DUAL_VDP only)
//   3. VDP#0 BG ROM (always requesting)
//   4. VDP#1 BG ROM (bg_rom_addr_1_raw, DUAL_VDP only)
//
// Pending channel encoding (gfx_chan[1:0]):
//   2'b00 = VDP#0 BG,  2'b01 = VDP#0 sprite
//   2'b10 = VDP#1 BG,  2'b11 = VDP#1 sprite

logic        gfx_pending;
logic [21:0] gfx_pending_addr;
logic [1:0]  gfx_pending_byte_sel;
logic [1:0]  gfx_chan;   // which channel is in-flight

// Byte-lane mux (combinational, outside always_ff to avoid Verilator complaints)
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
        gfx_chan             <= 2'b00;
        bg_rom_data_r        <= 8'h00;
        spr_rom_data_r       <= 8'h00;
        bg_rom_data_1_r      <= 8'h00;
        spr_rom_data_1_r     <= 8'h00;
    end else begin
        if (!gfx_pending) begin
            if (spr_rom_rd) begin
                // VDP#0 sprite — highest priority
                gfx_pending_addr     <= {1'b0, spr_rom_addr_raw[20:0]};
                gfx_pending_byte_sel <= spr_rom_addr_raw[1:0];
                gfx_chan             <= 2'b01;
                gfx_pending          <= 1'b1;
                gfx_rom_req          <= ~gfx_rom_req;
            end else if (DUAL_VDP && spr_rom_rd_1) begin
                // VDP#1 sprite
                gfx_pending_addr     <= {1'b0, spr_rom_addr_1_raw[20:0]};
                gfx_pending_byte_sel <= spr_rom_addr_1_raw[1:0];
                gfx_chan             <= 2'b11;
                gfx_pending          <= 1'b1;
                gfx_rom_req          <= ~gfx_rom_req;
            end else if (DUAL_VDP) begin
                // VDP#0 and VDP#1 BG — round-robin between them; simple even/odd by hpos LSB
                if (!pix_hpos[0]) begin
                    gfx_pending_addr     <= {2'b0, bg_rom_addr_raw};
                    gfx_pending_byte_sel <= bg_rom_addr_raw[1:0];
                    gfx_chan             <= 2'b00;
                end else begin
                    gfx_pending_addr     <= {2'b0, bg_rom_addr_1_raw};
                    gfx_pending_byte_sel <= bg_rom_addr_1_raw[1:0];
                    gfx_chan             <= 2'b10;
                end
                gfx_pending <= 1'b1;
                gfx_rom_req <= ~gfx_rom_req;
            end else begin
                // Single-VDP: VDP#0 BG only
                gfx_pending_addr     <= {2'b0, bg_rom_addr_raw};
                gfx_pending_byte_sel <= bg_rom_addr_raw[1:0];
                gfx_chan             <= 2'b00;
                gfx_pending          <= 1'b1;
                gfx_rom_req          <= ~gfx_rom_req;
            end
        end else if (gfx_rom_req == gfx_rom_ack) begin
            // SDRAM has returned data; route byte to correct destination
            case (gfx_chan)
                2'b00: bg_rom_data_r    <= gfx_byte_out;   // VDP#0 BG
                2'b01: spr_rom_data_r   <= gfx_byte_out;   // VDP#0 sprite
                2'b10: bg_rom_data_1_r  <= gfx_byte_out;   // VDP#1 BG
                2'b11: spr_rom_data_1_r <= gfx_byte_out;   // VDP#1 sprite
            endcase
            gfx_pending <= 1'b0;
        end
    end
end

assign gfx_rom_addr = gfx_pending_addr;

// =============================================================================
// Work RAM — 64KB synchronous block RAM
// =============================================================================

`ifdef QUARTUS
// altsyncram SINGLE_PORT with byteena_a=2.
// The M10K hint + conditional byte-slice writes causes MAP OOM in Quartus 17.0.
logic [15:0] wram_dout_r;
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
logic [15:0] wram_dout_r;
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
// Format: 0bRRRRRGGGGGBBBBB (bit 15 unused / transparent flag)
// CPU accesses palette at byte 0x500000–0x5003FF.
// During active display, final_color from GP9001 Gate 5 (8-bit palette index)
// indexes into this RAM to produce RGB output.

logic [15:0] palram_cpu_dout;

`ifdef QUARTUS
// Two DUAL_PORT altsyncram instances sharing write port A (byteena_a=2).
// Port B of cpu instance = CPU read; port B of pix instance = pixel lookup.
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
    .address_a(cpu_addr[9:1]), .data_a(cpu_dout),
    .wren_a(palram_cs && !cpu_rw), .byteena_a({~cpu_uds_n, ~cpu_lds_n}),
    .address_b(cpu_addr[9:1]), .q_b(palram_cpu_raw),
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
    .address_a(cpu_addr[9:1]),         .data_a(cpu_dout),
    .wren_a(palram_cs && !cpu_rw), .byteena_a({~cpu_uds_n, ~cpu_lds_n}),
    .address_b({1'b0, mixed_final_color}), .q_b(palram_pix_raw),
    .wren_b(1'b0), .data_b(16'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

always_ff @(posedge clk_sys) begin
    if (palram_cs) palram_cpu_dout <= palram_cpu_raw;
end

// Pixel lookup: altsyncram output is already registered (1-cycle latency).
// Apply clk_pix enable after altsyncram to stay aligned with pixel stream.
logic [15:0] pal_entry_r;
always_ff @(posedge clk_sys) begin
    if (clk_pix) pal_entry_r <= palram_pix_raw;
end

`else
// Simulation path
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
// Pixel-domain palette lookup
logic [15:0] pal_entry_r;
always_ff @(posedge clk_sys) begin
    if (clk_pix) pal_entry_r <= palette_ram[{1'b0, mixed_final_color}];
end
`endif

// Expand R5G5B5 → R8G8B8 (replicate 3 MSBs into low 3 bits).
// Bit [15] of palette entry is unused (transparent flag, not needed here).
assign rgb_r = {pal_entry_r[14:10], pal_entry_r[14:12]};
assign rgb_g = {pal_entry_r[9:5],   pal_entry_r[9:7]};
assign rgb_b = {pal_entry_r[4:0],   pal_entry_r[4:2]};

// =============================================================================
// Sound Command Latch
// =============================================================================
// M68000 writes sound commands to 0x70000E (word address 0x380007 = A[3:1]=3'h7).
// Z80 reads this latch on its bus.  We capture it here in the M68K domain.

logic [7:0] sound_cmd;   // latched command byte for Z80

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        sound_cmd <= 8'h00;
    else if (io_cs && !cpu_rw && (cpu_addr[3:1] == 3'h7) && !cpu_lds_n)
        sound_cmd <= cpu_dout[7:0];   // latch lower byte on 68K write to 0x70000E
end

// =============================================================================
// I/O Registers
// =============================================================================
// I/O register decode (byte addresses within 0x700000 window):
//   0x700000/1 — Player 1 joystick + buttons (read)    cpu_addr[4:1]=0x00
//   0x700002/3 — Player 2 joystick + buttons (read)    cpu_addr[4:1]=0x01
//   0x700004/5 — Coins + service (read)                 cpu_addr[4:1]=0x02
//   0x700006/7 — DIP switch bank 1 (read)              cpu_addr[4:1]=0x03
//   0x700008/9 — DIP switch bank 2 (read)              cpu_addr[4:1]=0x04
//   0x70000E/F — Z80 sound command (write only)        cpu_addr[4:1]=0x07
//
// Truxton II: EEPROM strobe at 0x700016/17.
//   cpu_addr[4:1] = 0xB  (bit[4]=1, bits[3:1]=3)
//   Firmware polls bit 7 of byte at 0x700017, loops while bit 7=1.
//   Return 0x00 (bit 7=0) immediately so the game can proceed.
//   NOTE: 0x700006 (DIP SW 1) and 0x700016 (strobe) both have
//   cpu_addr[3:1]=3; they are distinguished by cpu_addr[4].
//
// All registers are byte-wide on the lower byte (D[7:0]).
// Word reads return the active byte in [7:0], [15:8] = 0xFF.

logic [7:0] io_dout_byte;

always_comb begin
    io_dout_byte = 8'hFF;   // default: open bus
    // Use cpu_addr[4:1] (4 bits) to distinguish registers that alias on [3:1].
    // 0x700016/17 (cpu_addr[4:1]=4'hB) must return 0x00 (not dipsw1).
    case (cpu_addr[4:1])
        4'h0: io_dout_byte = joystick_p1;                          // 0x700000/1
        4'h1: io_dout_byte = joystick_p2;                          // 0x700002/3
        4'h2: io_dout_byte = {2'b11, service, 1'b1, coin[1], coin[0], 2'b11}; // 0x700004/5
        4'h3: io_dout_byte = dipsw1;                               // 0x700006/7
        4'h4: io_dout_byte = dipsw2;                               // 0x700008/9
        4'hB: io_dout_byte = 8'h00;  // 0x700016/17: EEPROM strobe — bit7=0 exits poll
        default: io_dout_byte = 8'hFF;
    endcase
end

// =============================================================================
// Program ROM Request Bridge
// =============================================================================
// Simple toggle-handshake to SDRAM.
// CPU stalls via cpu_dtack_n until prog_rom_ack toggles back.

logic prog_req_pending;
logic [19:1] prog_req_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        prog_rom_req      <= 1'b0;
        prog_req_pending  <= 1'b0;
        prog_req_addr_r   <= 19'b0;
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
// Priority (highest first):
//   GP9001 #0  > GP9001 #1 (DUAL_VDP only) > palette RAM >
//   shared RAM (DUAL_VDP only) > I/O > YM2151 > WRAM > prog ROM > open bus

always_comb begin
    if (!gp9001_cs_n)
        cpu_din = gp9001_dout;
    else if (!gp9001_1_cs_n)
        cpu_din = gp9001_1_dout;                        // VDP#1 (FFFF when DUAL_VDP=0)
    else if (palram_cs)
        cpu_din = palram_cpu_dout;
    else if (shared_cs)
        cpu_din = shared_ram_dout;                      // V25 shared RAM (FFFF when DUAL_VDP=0)
    else if (io_cs)
        cpu_din = {8'hFF, io_dout_byte};
    else if (ym_cpu_cs)
        cpu_din = ym_cpu_dout;   // YM2151 stub: toggle bit 8 to unblock poll loops
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
// Prog ROM: stall until SDRAM ack (prog_req_pending goes low)
// Known fast devices (GP9001, palette, I/O, WRAM): 1-cycle DTACK
// Open bus (unrecognized address): 2-cycle fallback DTACK
//   Without this, unmapped writes (e.g. to 0xFFFFFE from 68K bus error
//   handler or Z80 sound bus) would stall the CPU indefinitely.

logic any_fast_cs;
logic dtack_r;
// Fallback: 2-cycle counter for open-bus cycles
logic dtack_fallback_r;

// Include VDP#1 and shared RAM in fast-CS set; both deassert when DUAL_VDP=0
assign any_fast_cs = !gp9001_cs_n | !gp9001_1_cs_n | palram_cs | shared_cs
                   | io_cs | ym_cpu_cs | wram_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        dtack_r          <= 1'b0;
        dtack_fallback_r <= 1'b0;
    end else begin
        dtack_r          <= any_fast_cs;
        dtack_fallback_r <= !cpu_as_n;   // 1 cycle after AS goes low
    end
end

always_comb begin
    if (cpu_as_n)
        cpu_dtack_n = 1'b1;
    else if (prog_rom_cs)
        cpu_dtack_n = prog_req_pending;   // 0 when SDRAM returns data
    else if (any_fast_cs)
        cpu_dtack_n = !dtack_r;           // fast device: 1-cycle DTACK
    else
        cpu_dtack_n = !dtack_fallback_r;  // open bus: 2-cycle fallback DTACK
end

// =============================================================================
// Interrupt (IPL) Generation
// =============================================================================
// IRQ2 = VBLANK   → IPL 3'b101 (level 2, active-low encoded: ~2 = 3'b101)
// IRQ1 = irq_sprite (sprite scan complete from GP9001) → IPL 3'b110 (level 1)
//
// NOTE: For Truxton II, only VBlank IRQ (level 2) is wired to the CPU.
// The sprite scan IRQ fires every frame and has a dummy handler (STOP #$2700)
// which halts the CPU. Keep ipl_spr_active disabled until a game needs it.
//
// Community pattern (jotego, Cave, NeoGeo, va7deo, atrac17):
//   SET IPL on edge, CLEAR on IACK only. NEVER use a timer.
//   Timer-based clear races with pswI mask — interrupt expires before
//   the CPU enables interrupts, so the game never takes the interrupt.

logic ipl_vbl_active;
// ipl_spr_active: sprite scan IRQ (IRQ1) — disabled for Truxton II
// (MAME confirms only VBLANK IRQ is connected to CPU in truxton2 memory map)
// logic ipl_spr_active;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl_vbl_active <= 1'b0;
    end else begin
        // IACK cycle: CPU acknowledged the interrupt — clear highest-priority active
        if (!cpu_inta_n) begin
            ipl_vbl_active <= 1'b0;
        end

        // VBLANK rising edge → assert IRQ2
        if (vblank_rising)   ipl_vbl_active <= 1'b1;

        // Sprite scan complete IRQ1 disabled — Truxton II uses STOP #$2700 for level 1
        // if (gp9001_irq_sprite) ipl_spr_active <= 1'b1;
    end
end

// Encode IPL: only VBlank (level 2) active; sprite IRQ disabled
reg [2:0] ipl_sync;
always_ff @(posedge clk_sys) begin
    if (ipl_vbl_active) ipl_sync <= 3'b101;   // ~2 = level 2 VBLANK
    else                ipl_sync <= 3'b111;   // no interrupt
end
assign cpu_ipl_n = ipl_sync;

// =============================================================================
// Audio Subsystem — Z80 (T80s) + YM2151 (jt51) + OKI M6295 (jt6295)
// =============================================================================
//
// Sound CPU: Z80 @ 3.5 MHz (T80s core from jtframe).
//   - Receives sound commands from M68000 via sound_cmd latch (0x70000E).
//   - Z80 address map:
//       0x0000–0x7FFF   32KB   Z80 ROM (from SDRAM, ioctl_index 0x03)
//       0x8000–0x87FF   2KB    Z80 RAM (internal BRAM, mirrored to 0xFFFF)
//       0x4000–0x4001          YM2151 (via MREQ: A15:1 == 0x2000)
//       0x5000                 OKI M6295 (via MREQ: A15:12 == 0x5)
//       0x6000                 Sound command read port (from M68K latch)
//
// YM2151 clock: 3.579545 MHz (clk_sound CE in clk_sys domain).
// OKI M6295 clock: ~1 MHz (clk_sys / 32 ≈ 1 MHz; exact rate set by ss pin).

// =============================================================================
// Z80 Sound CPU — T80s
// =============================================================================

// Z80 control signals
logic        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
logic        z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
logic [15:0] z80_addr;
logic  [7:0] z80_dout_cpu;   // data output from Z80 core

// Z80 wait: asserted while waiting for ROM SDRAM fetch
logic        z80_wait_n;

// Z80 interrupt: YM2151 irq_n drives Z80 INT
wire         z80_int_n;   // driven by YM2151 irq_n output

// Z80 2KB internal RAM (0x8000–0x87FF, mirrored across upper half)
logic [7:0]  z80_ram [0:2047];
logic [7:0]  z80_ram_dout_r;

// Z80 chip-select decode (combinational, on Z80 clock domain via CEN gating)
// All decodes are MREQ-based (memory-mapped I/O, per Toaplan V2 hardware).
logic z80_rom_cs;    // 0x0000–0x7FFF
logic z80_ram_cs;    // 0x8000–0xFFFF (2KB BRAM mirrored)
logic z80_ym_cs;     // 0x4000–0x4001 (YM2151)
logic z80_oki_cs;    // 0x5000        (OKI M6295)
logic z80_cmd_cs;    // 0x6000        (sound command latch)

always_comb begin
    // YM2151: 0x4000–0x4001 (A15:1 == 15'h2000)
    z80_ym_cs  = (!z80_mreq_n) && (z80_addr[15:1] == 15'h2000);
    // OKI M6295: 0x5000–0x5FFF (A15:12 == 4'h5)
    z80_oki_cs = (!z80_mreq_n) && (z80_addr[15:12] == 4'h5);
    // Sound command read: 0x6000–0x6FFF (A15:12 == 4'h6)
    z80_cmd_cs = (!z80_mreq_n) && (z80_addr[15:12] == 4'h6);
    // ROM: 0x0000–0x7FFF excluding peripheral windows
    z80_rom_cs = (!z80_mreq_n) && (z80_addr[15] == 1'b0)
                 && !z80_ym_cs && !z80_oki_cs && !z80_cmd_cs;
    // RAM: 0x8000–0xFFFF
    z80_ram_cs = (!z80_mreq_n) && (z80_addr[15] == 1'b1);
end

// ── Z80 ROM SDRAM bridge ─────────────────────────────────────────────────────
// Toggle-req/ack handshake.  z80_wait_n is deasserted (0) while fetch is pending.
// We detect a new read request when z80_rom_cs asserts and rd_n is low and
// no fetch is already in flight.

logic z80_rom_pending;
logic z80_rom_req_r;
logic [7:0] z80_rom_latch;   // last returned byte

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        z80_rom_req_r   <= 1'b0;
        z80_rom_pending <= 1'b0;
        z80_rom_latch   <= 8'hFF;
        z80_wait_n      <= 1'b1;
    end else begin
        if (z80_rom_cs && !z80_rd_n && !z80_rom_pending) begin
            // New ROM read — issue SDRAM request
            z80_rom_req_r   <= ~z80_rom_req_r;
            z80_rom_pending <= 1'b1;
            z80_wait_n      <= 1'b0;   // stall Z80
        end else if (z80_rom_pending && (z80_rom_req_r == z80_rom_ack)) begin
            // SDRAM returned data
            z80_rom_latch   <= z80_rom_data;
            z80_rom_pending <= 1'b0;
            z80_wait_n      <= 1'b1;   // release Z80
        end
    end
end

assign z80_rom_req  = z80_rom_req_r;
assign z80_rom_addr = z80_addr;

// ── Z80 RAM ──────────────────────────────────────────────────────────────────
// 2KB at 0x8000–0x87FF, mirrored to fill 0x8000–0xFFFF (mask to 11 bits).

always_ff @(posedge clk_sys) begin
    if (z80_ram_cs && !z80_wr_n)
        z80_ram[z80_addr[10:0]] <= z80_dout_cpu;
end

always_ff @(posedge clk_sys) begin
    if (z80_ram_cs) z80_ram_dout_r <= z80_ram[z80_addr[10:0]];
end

// ── Z80 data bus read mux ────────────────────────────────────────────────────
// Priority: I/O peripherals > RAM > ROM (peripherals at 0x4000-0x7FFF overlap ROM space)
logic [7:0] z80_din_mux;

always_comb begin
    if (z80_ym_cs)
        z80_din_mux = ym_dout;
    else if (z80_oki_cs)
        z80_din_mux = m6295_dout;
    else if (z80_cmd_cs)
        z80_din_mux = sound_cmd;
    else if (z80_ram_cs)
        z80_din_mux = z80_ram_dout_r;
    else if (z80_rom_cs)
        z80_din_mux = z80_rom_latch;
    else
        z80_din_mux = 8'hFF;   // open bus
end

T80s u_z80 (
    .RESET_n  (reset_n),
    .CLK      (clk_sys),
    .CEN      (clk_sound),      // 3.5 MHz clock enable
    .WAIT_n   (z80_wait_n),
    .INT_n    (z80_int_n),
    .NMI_n    (1'b1),
    .BUSRQ_n  (1'b1),
    .OUT0     (1'b0),           // not used (M1/IORQ output0 mode disabled)
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

// ── YM2151 control signals (wired to Z80) ────────────────────────────────────
// Z80 writes: MREQ low, WR low, z80_ym_cs asserted.
// A0 (= z80_addr[0]) selects register (0) vs data (1).
wire        ym_cs_n = ~z80_ym_cs;
wire        ym_wr_n = z80_wr_n | ~z80_ym_cs;
wire        ym_a0   = z80_addr[0];
wire  [7:0] ym_din  = z80_dout_cpu;
wire  [7:0] ym_dout;               // returned to Z80 on reads
wire        ym_irq_n;              // drives Z80 INT
assign      z80_int_n = ym_irq_n;

// YM2151 clock enable halved (jt51 needs cen and cen_p1 at half-speed)
// cen_p1 toggles on alternate cen edges; since clk_sound is already a CE
// pulse (1 cycle every ~9 cycles at 32 MHz), generate a divided version.
logic ym_cen_p1_r;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)  ym_cen_p1_r <= 1'b0;
    else if (clk_sound) ym_cen_p1_r <= ~ym_cen_p1_r;
end
wire ym_cen_p1 = clk_sound & ym_cen_p1_r;   // half-rate of clk_sound

// YM2151 raw output (signed 16-bit per channel)
wire signed [15:0] ym_left_raw, ym_right_raw;
wire               ym_sample;

jt51 u_jt51 (
    .rst        (~reset_n),
    .clk        (clk_sys),
    .cen        (clk_sound),    // 3.5 MHz CE
    .cen_p1     (ym_cen_p1),    // 1.75 MHz CE
    .cs_n       (ym_cs_n),
    .wr_n       (ym_wr_n),
    .a0         (ym_a0),
    .din        (ym_din),
    .dout       (ym_dout),
    // peripheral control
    .ct1        (),
    .ct2        (),
    .irq_n      (ym_irq_n),     // drives Z80 INT
    // audio outputs — use standard-resolution left/right
    .sample     (ym_sample),
    .left       (ym_left_raw),
    .right      (ym_right_raw),
    .xleft      (),
    .xright     ()
);

// ── OKI M6295 control signals (wired to Z80) ─────────────────────────────────
// Z80 writes to 0x5000: MREQ low, WR low, z80_oki_cs asserted.
// ss=1 → 8000 Hz sample rate with 1 MHz cen; ss=0 → 6000 Hz.
wire        m6295_wrn = z80_wr_n | ~z80_oki_cs;
wire [7:0]  m6295_din = z80_dout_cpu;
wire [7:0]  m6295_dout;   // returned to Z80 on status reads

// M6295 clock enable: ~1 MHz from clk_sys / 32
// At clk_sys=32 MHz: 32/32 = 1 MHz exactly.
logic [4:0] m6295_ce_cnt;
logic       m6295_cen;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        m6295_ce_cnt <= 5'd0;
        m6295_cen    <= 1'b0;
    end else begin
        if (m6295_ce_cnt == 5'd31) begin
            m6295_ce_cnt <= 5'd0;
            m6295_cen    <= 1'b1;
        end else begin
            m6295_ce_cnt <= m6295_ce_cnt + 5'd1;
            m6295_cen    <= 1'b0;
        end
    end
end

// ADPCM ROM interface: jt6295 outputs rom_addr[17:0] and takes rom_data[7:0] + rom_ok.
// rom_ok is an INPUT to jt6295: high when the ROM has returned valid data for the
// current rom_addr.  We bridge to the SDRAM toggle-req/ack protocol:
//   - jt6295 drives rom_addr whenever it needs new data.
//   - We latch a new SDRAM request (toggle adpcm_req_r) on each new jt6295 rom_addr.
//   - When adpcm_rom_ack matches adpcm_rom_req, SDRAM data is valid; assert rom_ok.
//
// We detect address changes to trigger new SDRAM fetches.
wire [17:0] m6295_rom_addr_w;   // from jt6295
wire  [7:0] m6295_rom_data_w;   // to jt6295
wire        m6295_rom_ok_in;    // to jt6295: data is valid
wire signed [13:0] m6295_sound;
wire               m6295_sample;

// Map jt6295 18-bit byte address onto adpcm_rom_addr (24-bit, SDRAM byte offset).
// ADPCM ROM sits at SDRAM byte offset 0x500000 (loaded at ioctl_index 0x02 in emu.sv).
// emu.sv adds the 0x500000 base via adpcm_sdram_word_addr calculation.
assign adpcm_rom_addr = {6'b0, m6295_rom_addr_w};

// SDRAM toggle-req bridge for ADPCM:
// Detect address changes from jt6295 and toggle adpcm_rom_req to initiate fetches.
logic [17:0] adpcm_addr_prev;
logic        adpcm_req_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        adpcm_addr_prev <= 18'b0;
        adpcm_req_r     <= 1'b0;
    end else begin
        adpcm_addr_prev <= m6295_rom_addr_w;
        // New address from jt6295 → toggle req to kick SDRAM fetch
        if (m6295_rom_addr_w != adpcm_addr_prev)
            adpcm_req_r <= ~adpcm_req_r;
    end
end
assign adpcm_rom_req = adpcm_req_r;

// Data back to jt6295: lower byte of 16-bit SDRAM word
assign m6295_rom_data_w = adpcm_rom_data[7:0];

// rom_ok to jt6295: asserted one cycle after SDRAM ack matches req
logic adpcm_data_ok_r;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) adpcm_data_ok_r <= 1'b0;
    else          adpcm_data_ok_r <= (adpcm_req_r == adpcm_rom_ack);
end
assign m6295_rom_ok_in = adpcm_data_ok_r;

jt6295 u_jt6295 (
    .rst        (~reset_n),
    .clk        (clk_sys),
    .cen        (m6295_cen),        // ~1 MHz CE
    .ss         (1'b1),             // ss=1 → 8 kHz sample rate
    .wrn        (m6295_wrn),
    .din        (m6295_din),
    .dout       (m6295_dout),
    .rom_addr   (m6295_rom_addr_w),
    .rom_data   (m6295_rom_data_w),
    .rom_ok     (m6295_rom_ok_in),  // data-valid from SDRAM bridge
    .sound      (m6295_sound),
    .sample     (m6295_sample)
);

// ── Audio mixer: FM (16-bit) + ADPCM (14-bit sign-extended → 16-bit) ─────────
// Sign-extend 14-bit ADPCM to 16-bit by replicating the sign bit into the top 2 bits.
// Then sum FM and ADPCM with halved amplitudes to prevent overflow.
wire signed [15:0] adpcm_16 = {{2{m6295_sound[13]}}, m6295_sound};   // 14→16 sign-extend
assign snd_left  = ($signed(ym_left_raw)  >> 1) + ($signed(adpcm_16) >> 1);
assign snd_right = ($signed(ym_right_raw) >> 1) + ($signed(adpcm_16) >> 1);

// =============================================================================
// Lint suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = &{
    1'b0,
    // GP9001 register outputs not used at integration level
    scroll_w[0], scroll_w[1], scroll_w[2], scroll_w[3],
    scroll_w[4], scroll_w[5], scroll_w[6], scroll_w[7],
    scroll0_x_w, scroll0_y_w, scroll1_x_w, scroll1_y_w,
    scroll2_x_w, scroll2_y_w, scroll3_x_w, scroll3_y_w,
    rowscroll_ctrl_w, layer_ctrl_w, sprite_ctrl_w,
    layer_size_w, color_key_w, blend_ctrl_w,
    num_layers_active_w, bg0_priority_w, bg1_priority_w, bg23_priority_w,
    sprite_list_len_code_w, sprite_sort_mode_w, sprite_prefetch_mode_w,
    sprite_en_w, scan_dout_w,
    display_list_count_w, display_list_ready_w,
    bg_pix_valid_w,
    bg_pix_color_w[0], bg_pix_color_w[1], bg_pix_color_w[2], bg_pix_color_w[3],
    bg_pix_priority_w[0], bg_pix_priority_w[1],
    bg_pix_priority_w[2], bg_pix_priority_w[3],
    vram_dout_w,
    bg_layer_sel,
    spr_rd_color_w, spr_rd_valid_w, spr_rd_priority_w,
    spr_render_done_w, spr_rom_rd,
    final_valid_w,
    pal_entry_r[15],        // transparent/unused bit in R5G5B5 palette entry
    // Audio — jt51/jt6295 sample strobes not consumed by system mixer
    ym_sample,
    m6295_sample,
    // Z80 outputs not used at integration level
    z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n, z80_iorq_n,
    // ADPCM upper byte — jt6295 only needs lower 8 bits
    adpcm_rom_data[15:8]
};
/* verilator lint_on UNUSED */

endmodule
