// =============================================================================
// psikyo_arcade.sv — Psikyo SH201B/SH403 System Board Top-Level Integration
// =============================================================================
//
// Implements the Psikyo arcade board (Gunbird / Strikers 1945 target).
//
// Instantiates and wires:
//   psikyo        — Gate 1 (CPU interface / register file) +
//                   Gate 2 (PS2001B sprite scanner / display list)
//   psikyo_gate3  — Sprite rasterizer (per-scanline scanline-buffer fill)
//   psikyo_gate4  — BG tilemap renderer (PS3103, 2 layers)
//   psikyo_gate5  — Priority mixer / colour compositor
//
// Plus local block RAMs:
//   work_ram      — 64KB at byte 0x000000–0x00FFFF
//   sprite_ram    — 32-bit wide, byte 0x020000–0x027FFF (sprite list)
//   palette_ram   — 256 × 16-bit R5G5B5, byte 0x600000–0x6007FF
//
// Audio:
//   YM2610B (jt10): FM + ADPCM-A + ADPCM-B
//   Z80 @ ~6.4 MHz (T80s core); drives YM2610B via Z80 bus.
//   ADPCM-A/B ROM path exposed as adpcm_rom_* ports → SDRAM CH3.
//
// Hardware reference: MAME src/mame/psikyo/psikyo.cpp (Gunbird, Strikers 1945)
//
// CPU NOTE: The real board uses a MC68EC020 @ 16 MHz. For the initial FPGA
//   port we instantiate a MC68000 (fx68k) @ 16 MHz as a placeholder; the
//   68EC020 is source-compatible for all instructions used by these games.
//   Replace fx68k with a proper 68020 core once available.
//
// Address map (byte addresses, from MAME psikyo.cpp driver):
//   0x000000–0x00FFFF   64 KB   Work RAM
//   0x020000–0x027FFF   32 KB   Sprite list RAM (PS2001B)
//   0x040000–0x05FFFF   128 KB  Tilemap VRAM (2 layers × 64 KB)
//   0x060000–0x067FFF   32 KB   BG VRAM (aliases to tilemap area on some games)
//   0x080000–0x0FFFFF   512 KB  Program ROM bank 0 (from SDRAM)
//   0x100000–0x1FFFFF   1 MB    Program ROM bank 1 (from SDRAM)
//   0x200000–0x3FFFFF   2 MB    Sprite ROM area (mapped through SDRAM)
//   0x600000–0x6007FF   2 KB    Palette RAM (256 × 16-bit)
//   0x800000–0x80000F   16 B    PS2001B sprite control registers
//   0xC00000–0xC0FFFF   64 KB   PS3103 tilemap control + I/O
//
// IRQ assignment (from MAME):
//   Level 4 — VBLANK (ipl_n = ~4 = 3'b011)
//
// SDRAM layout:
//   0x000000–0x1FFFFF   2 MB    Program ROM
//   0x200000–0x5FFFFF   4 MB    Sprite / GFX ROM (spr_rom_addr is direct)
//   0x600000–0x9FFFFF   4 MB    BG tile ROM
//
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module psikyo_arcade #(
    // ── Address decode parameters (WORD addresses = byte_addr >> 1) ────────────
    // Work RAM: byte 0x000000–0x00FFFF → word base 0x000000, 15-bit window
    parameter logic [23:1] WRAM_BASE   = 23'h000000,
    parameter int          WRAM_ABITS  = 15,    // 2^15 = 32K words = 64KB

    // Sprite RAM: byte 0x020000–0x027FFF → word base 0x010000, 14-bit window
    parameter logic [23:1] SPRAM_BASE  = 23'h010000,
    parameter int          SPRAM_ABITS = 14,    // 2^14 = 16K words = 32KB

    // Tilemap VRAM: byte 0x040000–0x05FFFF → word base 0x020000, 16-bit window
    parameter logic [23:1] VRAM_BASE   = 23'h020000,

    // Palette RAM: byte 0x600000–0x6007FF → word base 0x300000, 9-bit window
    parameter logic [23:1] PALRAM_BASE = 23'h300000,

    // PS2001B sprite ctrl regs: byte 0x800000–0x80000F → word 0x400000
    parameter logic [23:1] SPR_REG_BASE = 23'h400000,

    // PS3103 tilemap ctrl + I/O: byte 0xC00000–0xC0FFFF → word 0x600000
    parameter logic [23:1] IO_BASE      = 23'h600000,

    // Program ROM: byte 0x080000–0x1FFFFF → word 0x040000–0x0FFFFF
    parameter logic [23:1] PROM_BASE    = 23'h040000,
    parameter int          PROM_ABITS   = 20,   // 2^20 = 1M words = 2 MB

    // SDRAM base addresses for ROM regions
    parameter logic [26:0] PROM_SDR_BASE  = 27'h000000,  // prog ROM at SDRAM 0x000000
    parameter logic [26:0] SPR_SDR_BASE   = 27'h200000,  // sprite ROM at SDRAM 0x200000
    parameter logic [26:0] BG_SDR_BASE    = 27'h600000,  // BG tile ROM at SDRAM 0x600000
    parameter logic [26:0] ADPCM_SDR_BASE = 27'hA00000,  // ADPCM ROM at SDRAM 0xA00000

    // VBLANK interrupt level (level 4 on Psikyo)
    parameter logic [2:0] VBLANK_LEVEL  = 3'd4
) (
    // ── Clocks / Reset ──────────────────────────────────────────────────────
    input  logic        clk_sys,         // system clock (32 MHz; CPU runs at /2 = 16 MHz)
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
    output logic [2:0]  cpu_ipl_n,       // interrupt priority level (active low)

    // ── Program ROM SDRAM interface ─────────────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── Sprite ROM SDRAM interface (byte-addressed, byte fetch) ────────────
    output logic [26:0] spr_rom_addr,    // byte address into SDRAM
    input  logic [15:0] spr_rom_data16,  // 16-bit SDRAM word
    output logic        spr_rom_req,
    input  logic        spr_rom_ack,

    // ── BG tile ROM SDRAM interface (byte-addressed, byte fetch) ───────────
    output logic [26:0] bg_rom_addr,     // byte address into SDRAM
    input  logic [15:0] bg_rom_data16,   // 16-bit SDRAM word
    output logic        bg_rom_req,
    input  logic        bg_rom_ack,

    // ── Audio Output ─────────────────────────────────────────────────────────
    output logic signed [15:0] snd_left,   // YM2610B left  channel (signed 16-bit)
    output logic signed [15:0] snd_right,  // YM2610B right channel (signed 16-bit)

    // ── ADPCM ROM SDRAM interface ─────────────────────────────────────────
    // ADPCM-A uses adpcma_addr[19:0] + adpcma_bank[3:0] → 24-bit ROM address.
    // ADPCM-B uses adpcmb_addr[23:0] directly.
    // We arbitrate both onto a single 16-bit SDRAM channel.
    output logic [26:0] adpcm_rom_addr,   // byte address into SDRAM (CH3)
    output logic        adpcm_rom_req,    // toggle-handshake request
    input  logic [15:0] adpcm_rom_data,   // 16-bit word from SDRAM
    input  logic        adpcm_rom_ack,    // toggle-handshake acknowledge

    // ── Sound clock ───────────────────────────────────────────────────────
    input  logic        clk_sound,        // 8 MHz clock enable (one pulse per 8 MHz cycle)

    // ── Z80 Sound CPU ROM SDRAM interface ────────────────────────────────────
    // Z80 ROM: 32KB at SDRAM base 0xA00000 + offset.
    output logic [15:0] z80_rom_addr,    // Z80 16-bit address
    output logic        z80_rom_req,     // toggle on new fetch request
    input  logic  [7:0] z80_rom_data,   // byte returned from SDRAM
    input  logic        z80_rom_ack,    // toggle when data is ready

    // ── Video Output ────────────────────────────────────────────────────────
    output logic [7:0]  rgb_r,
    output logic [7:0]  rgb_g,
    output logic [7:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Player Inputs ────────────────────────────────────────────────────────
    // Active-low convention.
    // [7]=BTN3 [6]=BTN2 [5]=BTN1 [4]=START [3]=RIGHT [2]=LEFT [1]=DOWN [0]=UP
    input  logic [7:0]  joystick_p1,
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,            // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service,         // service button (active low)
    input  logic [7:0]  dipsw1,
    input  logic [7:0]  dipsw2
);

// =============================================================================
// Video Timing Generator — 320×240 standard arcade
// =============================================================================
// Horizontal: 320 active, 24 FP, 32 sync, 40 BP = 416 total
// Vertical:   240 active, 12 FP, 4  sync,  8 BP = 264 total
// =============================================================================

localparam int H_ACTIVE = 320;
localparam int H_FP     = 24;
localparam int H_SYNC   = 32;
localparam int H_BP     = 40;
localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 416

localparam int V_ACTIVE = 240;
localparam int V_FP     = 12;
localparam int V_SYNC   = 4;
localparam int V_BP     = 8;
localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 264

logic [8:0] hpos_r;
logic [8:0] vpos_r;
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
        if (hpos_r == 9'(H_TOTAL - 1))
            hpos_r <= 9'h000;
        else
            hpos_r <= hpos_r + 9'd1;

        if (hpos_r == 9'(H_TOTAL - 1)) begin
            if (vpos_r == 9'(V_TOTAL - 1))
                vpos_r <= 9'h000;
            else
                vpos_r <= vpos_r + 9'd1;
        end

        hsync_r  <= ~((hpos_r >= 9'(H_ACTIVE + H_FP)) && (hpos_r < 9'(H_ACTIVE + H_FP + H_SYNC)));
        vsync_r  <= ~((vpos_r >= 9'(V_ACTIVE + V_FP)) && (vpos_r < 9'(V_ACTIVE + V_FP + V_SYNC)));
        hblank_r <= (hpos_r >= 9'(H_ACTIVE));
        vblank_r <= (vpos_r >= 9'(V_ACTIVE));
    end
end

assign hsync_n = hsync_r;
assign vsync_n = vsync_r;
assign hblank  = hblank_r;
assign vblank  = vblank_r;

// Active pixel positions (clamp to visible area)
wire [9:0] pix_hpos = (hpos_r < 9'(H_ACTIVE)) ? {1'b0, hpos_r} : 10'h000;
wire [8:0] pix_vpos = (vpos_r < 9'(V_ACTIVE)) ? vpos_r : 9'h000;

// VBLANK rising edge for IRQ generation
logic vblank_prev;
logic vblank_rising;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) vblank_prev <= 1'b0;
    else          vblank_prev <= vblank_r;
end

assign vblank_rising = vblank_r & ~vblank_prev;

// Scan trigger: falling edge of hblank (start of new active line)
logic hblank_prev;
logic scan_trigger;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) hblank_prev <= 1'b0;
    else          hblank_prev <= hblank_r;
end

assign scan_trigger = hblank_prev & ~hblank_r;

// =============================================================================
// Chip-Select Decode
// All comparisons use cpu_addr[23:1] (word address).
// =============================================================================

// Work RAM: byte 0x000000–0x00FFFF
logic wram_cs;
assign wram_cs = (cpu_addr[23:WRAM_ABITS] == WRAM_BASE[23:WRAM_ABITS]) && !cpu_as_n;

// Sprite RAM: byte 0x020000–0x027FFF
logic spram_cs;
assign spram_cs = (cpu_addr[23:SPRAM_ABITS] == SPRAM_BASE[23:SPRAM_ABITS]) && !cpu_as_n;

// Tilemap VRAM: byte 0x040000–0x05FFFF (16-bit window, 16 bits of word addr)
logic vram_cs;
assign vram_cs = (cpu_addr[23:16] == VRAM_BASE[23:16]) && !cpu_as_n;

// Palette RAM: byte 0x600000–0x6007FF (9-bit window)
logic palram_cs;
assign palram_cs = (cpu_addr[23:9] == PALRAM_BASE[23:9]) && !cpu_as_n;

// PS2001B sprite control registers: byte 0x800000–0x80000F
logic spr_reg_cs_n;
assign spr_reg_cs_n = !((cpu_addr[23:4] == SPR_REG_BASE[23:4]) && !cpu_as_n);

// PS3103 tilemap ctrl + I/O: byte 0xC00000–0xC0FFFF (15-bit window)
logic io_cs;
assign io_cs = (cpu_addr[23:15] == IO_BASE[23:15]) && !cpu_as_n;

// Program ROM: byte 0x080000–0x1FFFFF
//   word base 0x040000, upper bits [23:PROM_ABITS] == PROM_BASE[23:PROM_ABITS]
logic prom_cs;
assign prom_cs = (cpu_addr[23:PROM_ABITS] == PROM_BASE[23:PROM_ABITS]) && !cpu_as_n;

// =============================================================================
// Work RAM — 64KB synchronous block RAM (word-wide)
// =============================================================================
logic [15:0] work_ram [0:(1<<WRAM_ABITS)-1];
logic [15:0] wram_dout_r;

always_ff @(posedge clk_sys) begin
    if (wram_cs && !cpu_rw) begin
        if (!cpu_uds_n) work_ram[cpu_addr[WRAM_ABITS:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) work_ram[cpu_addr[WRAM_ABITS:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (wram_cs) wram_dout_r <= work_ram[cpu_addr[WRAM_ABITS:1]];
end

// =============================================================================
// Sprite RAM — 32KB synchronous block RAM (word-wide, 16-bit access from CPU)
// PS2001B reads 32-bit sprite entries; we keep word-granular access here.
// =============================================================================
logic [15:0] sprite_ram [0:(1<<SPRAM_ABITS)-1];
logic [15:0] spram_dout_r;

// Sprite RAM write: CPU takes priority over Gate 1/2 DMA write-back
always_ff @(posedge clk_sys) begin
    if (spram_cs && !cpu_rw) begin
        if (!cpu_uds_n) sprite_ram[cpu_addr[SPRAM_ABITS:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) sprite_ram[cpu_addr[SPRAM_ABITS:1]][ 7:0] <= cpu_dout[ 7:0];
    end else if (sprite_ram_wr_en_w) begin
        if (sprite_ram_wsel_w[0])
            sprite_ram[sprite_ram_addr_w[SPRAM_ABITS-1:0]][15:0] <= sprite_ram_din_w;
    end
end

always_ff @(posedge clk_sys) begin
    if (spram_cs) spram_dout_r <= sprite_ram[cpu_addr[SPRAM_ABITS:1]];
end

// psikyo Gate 1/2 sprite RAM read port (32-bit, even word is [31:16])
logic [15:0] sp_ram_lo, sp_ram_hi;
logic [31:0] sprite_ram_dout_w;
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] sprite_ram_addr_w;   // [15:14] unused — Gate 1/2 stub always 0 in upper bits
/* verilator lint_on UNUSEDSIGNAL */
logic [15:0] sprite_ram_din_w;
logic [1:0]  sprite_ram_wsel_w;
logic        sprite_ram_wr_en_w;

// Gate 1/2 may write DMA data back; read is 32-bit (two consecutive words)
// sprite_ram has 2^SPRAM_ABITS = 16384 entries; index is 14-bit.
// sprite_ram_addr_w[15:14] are unused (Gate 1/2 stub always drives 0 there).
/* verilator lint_off UNUSEDSIGNAL */
always_ff @(posedge clk_sys) begin
    sp_ram_lo <= sprite_ram[{sprite_ram_addr_w[13:1], 1'b0}];   // even word (14-bit index)
    sp_ram_hi <= sprite_ram[{sprite_ram_addr_w[13:1], 1'b1}];   // odd  word (14-bit index)
end
/* verilator lint_on UNUSEDSIGNAL */

assign sprite_ram_dout_w = {sp_ram_hi, sp_ram_lo};

// =============================================================================
// Tilemap VRAM — 8192 × 16-bit (2 layers × 4096 cells)
// Write port: CPU; read port: psikyo_gate4 (combinational)
// =============================================================================
logic [15:0]  vram_mem [0:8191];
logic [12:0]  vram_wr_addr_w;
logic [15:0]  vram_wr_data_w;
logic         vram_wr_en_w;

// CPU VRAM write: addr[13:1] = 13-bit index into 8192-word space
always_ff @(posedge clk_sys) begin
    if (vram_cs && !cpu_rw) begin
        // gate4 expects {layer[0], cell[11:0]} — layer selects from cpu_addr[14]
        if (!cpu_uds_n) vram_mem[cpu_addr[13:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) vram_mem[cpu_addr[13:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

// Forward VRAM write to gate4 for its internal copy
assign vram_wr_addr_w = cpu_addr[13:1];
assign vram_wr_data_w = cpu_dout;
assign vram_wr_en_w   = vram_cs && !cpu_rw;

logic [15:0] vram_cpu_dout;
always_ff @(posedge clk_sys) begin
    if (vram_cs) vram_cpu_dout <= vram_mem[cpu_addr[13:1]];
end

// =============================================================================
// Palette RAM — 256 × 16-bit R5G5B5
// Format: [15]=unused, [14:10]=R, [9:5]=G, [4:0]=B
// =============================================================================
logic [15:0] palette_ram [0:255];
logic [15:0] palram_cpu_dout;

always_ff @(posedge clk_sys) begin
    if (palram_cs && !cpu_rw) begin
        if (!cpu_uds_n) palette_ram[cpu_addr[8:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) palette_ram[cpu_addr[8:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (palram_cs) palram_cpu_dout <= palette_ram[cpu_addr[8:1]];
end

// Pixel-domain palette lookup: final_color[7:0] → palette entry → R5G5B5 → R8G8B8
logic [15:0] pal_entry_r;
logic [7:0]  final_color_w;
logic        final_valid_w;

always_ff @(posedge clk_sys) begin
    if (clk_pix) pal_entry_r <= palette_ram[final_color_w];
end

// Expand R5G5B5 → R8G8B8 (replicate 3 MSBs into low 3 bits)
assign rgb_r = {pal_entry_r[14:10], pal_entry_r[14:12]};
assign rgb_g = {pal_entry_r[9:5],   pal_entry_r[9:7]};
assign rgb_b = {pal_entry_r[4:0],   pal_entry_r[4:2]};

// =============================================================================
// psikyo — Gate 1 (register file) + Gate 2 (PS2001B sprite scanner)
// =============================================================================
// The psikyo module performs internal address decode relative to its cs_n input.
// We assert cs_n for any register or RAM region that psikyo handles internally.
// Here we give it a unified chip-select covering: sprite ctrl regs, PS3103,
// PS3305, Z80 interface, and the RAM stubs handled in psikyo.sv.
// psikyo.sv decodes addr[23:1] directly, so pass cpu_addr through.
// =============================================================================

// Outputs from Gate 1/2
logic [255:0][9:0]   dl_x;
logic [255:0][9:0]   dl_y;
logic [255:0][15:0]  dl_tile;
logic [255:0][3:0]   dl_palette;
logic [255:0]        dl_flip_x;
logic [255:0]        dl_flip_y;
logic [255:0][1:0]   dl_priority;
logic [255:0][2:0]   dl_size;
logic [255:0]        dl_valid;
logic [7:0]  dl_count;
logic        dl_ready;

logic [3:0][15:0] bg_scroll_x_w;
logic [3:0][15:0] bg_scroll_y_w;

logic [15:0] psikyo_dout;

// Gate 1/2 chip-select: asserted for spr_reg_cs, io_cs
// psikyo.sv does its own internal decode, so assert cs_n only when either region is accessed
logic psikyo_cs_n;
assign psikyo_cs_n = spr_reg_cs_n & !io_cs;

psikyo u_psikyo (
    .clk              (clk_sys),
    .rst_n            (reset_n),

    // CPU interface
    .addr             (cpu_addr),
    .din              (cpu_dout),
    .dout             (psikyo_dout),
    .cs_n             (psikyo_cs_n),
    .rd_n             (cpu_rw  ? 1'b0 : 1'b1),
    .wr_n             (!cpu_rw ? 1'b0 : 1'b1),
    .dsn              ({!cpu_uds_n, !cpu_lds_n}),

    // VBLANK / IRQ
    .vsync_n          (vsync_r),
    /* verilator lint_off PINCONNECTEMPTY */
    .nmi_n            (),
    .irq1_n           (),
    .irq2_n           (),
    .irq3_n           (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Sprite control outputs (not wired to gate3 — gate3 uses display_list directly)
    /* verilator lint_off PINCONNECTEMPTY */
    .spr_dma_enable   (),
    .spr_render_enable(),
    .spr_mode         (),
    .spr_palette_bank (),
    .spr_table_base   (),
    .spr_count        (),
    .spr_y_offset     (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Display list outputs → gate3
    .display_list_x        (dl_x),
    .display_list_y        (dl_y),
    .display_list_tile     (dl_tile),
    .display_list_palette  (dl_palette),
    .display_list_flip_x   (dl_flip_x),
    .display_list_flip_y   (dl_flip_y),
    .display_list_priority (dl_priority),
    .display_list_size     (dl_size),
    .display_list_valid    (dl_valid),
    .display_list_count    (dl_count),
    .display_list_ready    (dl_ready),

    // BG control outputs (bg_scroll_x/y → gate4)
    /* verilator lint_off PINCONNECTEMPTY */
    .bg_enable        (),
    .bg_tile_size     (),
    .bg_priority      (),
    .bg_chr_bank      (),
    /* verilator lint_on PINCONNECTEMPTY */
    .bg_scroll_x      (bg_scroll_x_w),
    .bg_scroll_y      (bg_scroll_y_w),
    /* verilator lint_off PINCONNECTEMPTY */
    .bg_tilemap_base  (),

    // PS3305 outputs
    .priority_table   (),
    .color_key_ctrl   (),
    .color_key_color  (),
    .color_key_mask   (),
    .vsync_irq_line   (),
    .hsync_irq_col    (),

    // Z80 status (no Z80 on Psikyo — all stubs)
    .z80_busy         (),
    .z80_irq_pending  (),
    .z80_cmd_reply    (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Sprite RAM port (32-bit read; write = DMA stub in psikyo.sv)
    .sprite_ram_addr  (sprite_ram_addr_w),
    .sprite_ram_din   (sprite_ram_din_w),
    .sprite_ram_wsel  (sprite_ram_wsel_w),
    .sprite_ram_wr_en (sprite_ram_wr_en_w),
    .sprite_ram_dout  (sprite_ram_dout_w)
);

// =============================================================================
// psikyo_gate3 — Per-scanline Sprite Rasterizer
// =============================================================================

// Sprite ROM fetch signals (byte-addressed, zero-latency model inside gate3)
// We bridge via SDRAM below.
logic [23:0] g3_spr_rom_addr_raw;
logic        g3_spr_rom_rd;
logic [7:0]  g3_spr_rom_data;

logic [9:0]  spr_rd_addr_w;
logic [7:0]  spr_rd_color_w;
logic        spr_rd_valid_w;
logic [1:0]  spr_rd_priority_w;
logic        spr_render_done_w;

psikyo_gate3 u_gate3 (
    .clk                    (clk_sys),
    .rst_n                  (reset_n),

    // Display list from gate1/2
    .display_list_x         (dl_x),
    .display_list_y         (dl_y),
    .display_list_tile      (dl_tile),
    .display_list_palette   (dl_palette),
    .display_list_flip_x    (dl_flip_x),
    .display_list_flip_y    (dl_flip_y),
    .display_list_priority  (dl_priority),
    .display_list_size      (dl_size),
    .display_list_valid     (dl_valid),
    .display_list_count     (dl_count),

    // Rasterizer control
    .scan_trigger           (scan_trigger),
    .current_scanline       (pix_vpos),

    // Sprite ROM
    .spr_rom_addr           (g3_spr_rom_addr_raw),
    .spr_rom_rd             (g3_spr_rom_rd),
    .spr_rom_data           (g3_spr_rom_data),

    // Scanline buffer read-back
    .spr_rd_addr            (spr_rd_addr_w),
    .spr_rd_color           (spr_rd_color_w),
    .spr_rd_valid           (spr_rd_valid_w),
    .spr_rd_priority        (spr_rd_priority_w),

    // Done strobe
    .spr_render_done        (spr_render_done_w)
);

// Feed current pixel X to gate3 scanline buffer read port
assign spr_rd_addr_w = pix_hpos;

// =============================================================================
// psikyo_gate4 — BG Tilemap Renderer
// =============================================================================

// BG ROM fetch signals (byte-addressed, zero-latency model inside gate4)
logic [23:0] g4_bg_rom_addr_raw;
logic        g4_bg_rom_rd;
logic [7:0]  g4_bg_rom_data;
logic [1:0]  g4_bg_layer_sel;

logic [1:0]  bg_pix_valid_w;
logic [1:0][7:0]  bg_pix_color_w;
logic [1:0]  bg_pix_priority_w;

psikyo_gate4 u_gate4 (
    .clk            (clk_sys),
    .rst_n          (reset_n),

    // Pixel position
    .hpos           (pix_hpos),
    .vpos           (pix_vpos),
    .hblank         (hblank_r),
    .vblank         (vblank_r),

    // Scroll registers (layer 0 and 1; layers 2/3 not used on Gunbird/S1945)
    // Gate 4 expects scroll_x/y packed [1:0][15:0]; psikyo.sv outputs bg_scroll_x/y packed [3:0][15:0].
    // Pass layers 0 and 1 explicitly via packed concatenation.
    .scroll_x       ({bg_scroll_x_w[1], bg_scroll_x_w[0]}),
    .scroll_y       ({bg_scroll_y_w[1], bg_scroll_y_w[0]}),

    // VRAM write port
    .vram_wr_addr   (vram_wr_addr_w),
    .vram_wr_data   (vram_wr_data_w),
    .vram_wr_en     (vram_wr_en_w),

    // BG tile ROM
    .bg_rom_addr    (g4_bg_rom_addr_raw),
    .bg_rom_rd      (g4_bg_rom_rd),
    .bg_rom_data    (g4_bg_rom_data),
    .bg_layer_sel   (g4_bg_layer_sel),

    // Pixel outputs
    .bg_pix_valid   (bg_pix_valid_w),
    .bg_pix_color   (bg_pix_color_w),
    .bg_pix_priority(bg_pix_priority_w)
);

// =============================================================================
// psikyo_gate5 — Priority Mixer
// =============================================================================

psikyo_gate5 u_gate5 (
    // Sprite pixel (from gate3 scanline buffer)
    .spr_rd_color    (spr_rd_color_w),
    .spr_rd_valid    (spr_rd_valid_w),
    .spr_rd_priority (spr_rd_priority_w),

    // BG pixels (from gate4)
    // bg_pix_priority: gate4 outputs 1-bit per layer; gate5 port is 2-bit per layer.
    // Expand each 1-bit field to 2-bit by zero-extending (priority[0] = the bit).
    .bg_pix_color    (bg_pix_color_w),
    .bg_pix_valid    (bg_pix_valid_w),
    .bg_pix_priority ({2'(bg_pix_priority_w[1]), 2'(bg_pix_priority_w[0])}),

    // Output → palette lookup
    .final_color     (final_color_w),
    .final_valid     (final_valid_w)
);

// =============================================================================
// Z80 Sound CPU — T80s @ ~6.4 MHz (clk_sys=32 MHz / 5)
// =============================================================================
//
// Z80 address map (Psikyo SH201B):
//   0x0000–0x7FFF   32KB Z80 ROM (SDRAM)
//   0x8000–0x87FF   2KB  Z80 RAM (BRAM, mirrored across 0x8000–0xFFFF)
//   0xC000–0xC003   YM2610B (2-bit addr bus A[1:0])
//   0xF000          Sound command latch (read from M68K)
//
// YM2610B audio — jt10 instantiation.
// ADPCM-A: jt10 drives adpcma_addr[19:0] + adpcma_bank[3:0].
// ADPCM-B: jt10 drives adpcmb_addr[23:0] directly.
//   We arbitrate A and B onto the single adpcm_rom_* SDRAM channel.
//   Priority: ADPCM-B over ADPCM-A.
// =============================================================================

// Z80 clock enable: 32 MHz / 5 = 6.4 MHz (close to real 6.144 MHz)
logic [2:0] ce_z80_cnt;
logic       ce_z80;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_z80_cnt <= 3'd0;
        ce_z80     <= 1'b0;
    end else begin
        if (ce_z80_cnt == 3'd4) begin
            ce_z80_cnt <= 3'd0;
            ce_z80     <= 1'b1;
        end else begin
            ce_z80_cnt <= ce_z80_cnt + 3'd1;
            ce_z80     <= 1'b0;
        end
    end
end

// Sound command latch (M68K → Z80 via psikyo register interface)
logic [7:0] z80_cmd_latch;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) z80_cmd_latch <= 8'h00;
    else          z80_cmd_latch <= psikyo_dout[7:0];  // shadow psikyo Z80 cmd reg
end

// Z80 bus signals
logic        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
logic        z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
logic [15:0] z80_addr;
logic  [7:0] z80_dout_cpu;

// Z80 wait: held low while ROM SDRAM fetch is pending
logic        z80_wait_n;

// Z80 interrupt: YM2610B irq_n → Z80 INT
wire         z80_int_n;

// Z80 2KB internal RAM (0x8000–0x87FF, mirrored)
logic [7:0] z80_ram [0:2047];
logic [7:0] z80_ram_dout_r;

// ── Z80 chip-select decode ───────────────────────────────────────────────────
logic z80_rom_cs;   // 0x0000–0x7FFF
logic z80_ym_cs;    // 0xC000–0xC003 (YM2610B)
logic z80_ram_cs;   // 0x8000–0x87FF (2KB RAM)
logic z80_cmd_cs;   // 0xF000        (sound command latch)

always_comb begin
    z80_rom_cs = (!z80_mreq_n) && (z80_addr[15] == 1'b0);
    z80_ym_cs  = (!z80_mreq_n) && (z80_addr[15:2] == 14'h3000);
    z80_ram_cs = (!z80_mreq_n) && (z80_addr[15:11] == 5'b10000);
    z80_cmd_cs = (!z80_mreq_n) && (z80_addr[15:12] == 4'hF);
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
wire  [7:0] ym_dout_w;   // YM2610B read data

always_comb begin
    if (z80_ym_cs)
        z80_din_mux = ym_dout_w;
    else if (z80_cmd_cs)
        z80_din_mux = z80_cmd_latch;
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
    .INT_n    (z80_int_n),
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

// ── YM2610B chip-select and write enables ────────────────────────────────────
wire        ym_cs_n_w = ~z80_ym_cs;
wire        ym_wr_n_w = z80_wr_n | ~z80_ym_cs;
wire [1:0]  ym_addr_w = z80_addr[1:0];   // A[1:0] → YM2610B address

wire ym_irq_n_w;
assign z80_int_n = ym_irq_n_w;

// jt10 ROM output enable signals (active low)
wire        adpcma_roe_n_w;
wire        adpcmb_roe_n_w;

// jt10 ADPCM address outputs
wire [19:0] adpcma_addr_w;
wire  [3:0] adpcma_bank_w;
wire [23:0] adpcmb_addr_w;

// Byte returned from SDRAM to jt10 (8-bit, lane-selected)
logic [7:0] adpcma_data_r;
logic [7:0] adpcmb_data_r;

// jt10 instance — YM2610B (FM + ADPCM-A + ADPCM-B)
jt10 u_ym2610b (
    .rst            (~reset_n),
    .clk            (clk_sys),
    .cen            (clk_sound),        // 8 MHz clock enable

    // Z80 register bus
    .din            (z80_dout_cpu),
    .addr           (ym_addr_w),
    .cs_n           (ym_cs_n_w),
    .wr_n           (ym_wr_n_w),

    .dout           (ym_dout_w),
    /* verilator lint_off PINCONNECTEMPTY */
    .irq_n          (ym_irq_n_w),
    /* verilator lint_on PINCONNECTEMPTY */

    // ADPCM-A ROM interface
    .adpcma_addr    (adpcma_addr_w),
    .adpcma_bank    (adpcma_bank_w),
    .adpcma_roe_n   (adpcma_roe_n_w),
    .adpcma_data    (adpcma_data_r),

    // ADPCM-B ROM interface
    .adpcmb_addr    (adpcmb_addr_w),
    .adpcmb_roe_n   (adpcmb_roe_n_w),
    .adpcmb_data    (adpcmb_data_r),

    // Separated outputs (PSG not used)
    /* verilator lint_off PINCONNECTEMPTY */
    .psg_A          (),
    .psg_B          (),
    .psg_C          (),
    .psg_snd        (),
    .fm_snd         (),
    .snd_sample     (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Stereo audio output
    .snd_left       (snd_left),
    .snd_right      (snd_right),

    // Enable all 6 ADPCM-A channels
    .ch_enable      (6'b111111)
);

// =============================================================================
// ADPCM ROM SDRAM Bridge
// =============================================================================
// Arbitrates ADPCM-A and ADPCM-B onto the single adpcm_rom_* SDRAM channel.
// ADPCM-B takes priority over ADPCM-A (both are low-rate compared to BG/SPR).
// The bridge sits between jt10 and the SDRAM channel exposed via the port.
// ADPCM-A effective address: {adpcma_bank[3:0], adpcma_addr[19:0]} = 24-bit.
// ADPCM-B effective address: adpcmb_addr[23:0].
// SDRAM word address        = ADPCM_SDR_BASE + {3'b0, byte_addr[23:1]}.
// =============================================================================

typedef enum logic [1:0] {
    ADPCM_IDLE  = 2'd0,
    ADPCM_FETCH_B = 2'd1,
    ADPCM_FETCH_A = 2'd2
} adpcm_state_t;

adpcm_state_t adpcm_state;

logic        adpcm_req_pending;
logic        adpcm_byte_sel;
logic [26:0] adpcm_req_addr_r;

// Edge-detect for ROE_N (active-low fetch request)
logic adpcma_roe_prev, adpcmb_roe_prev;
logic adpcma_req_edge, adpcmb_req_edge;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        adpcma_roe_prev <= 1'b1;
        adpcmb_roe_prev <= 1'b1;
    end else begin
        adpcma_roe_prev <= adpcma_roe_n_w;
        adpcmb_roe_prev <= adpcmb_roe_n_w;
    end
end

assign adpcma_req_edge = adpcma_roe_prev & ~adpcma_roe_n_w;  // falling edge
assign adpcmb_req_edge = adpcmb_roe_prev & ~adpcmb_roe_n_w;  // falling edge

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        adpcm_state       <= ADPCM_IDLE;
        adpcm_rom_req     <= 1'b0;
        adpcm_req_pending <= 1'b0;
        adpcm_byte_sel    <= 1'b0;
        adpcm_req_addr_r  <= 27'b0;
        adpcma_data_r     <= 8'h00;
        adpcmb_data_r     <= 8'h00;
    end else begin
        case (adpcm_state)
            ADPCM_IDLE: begin
                // ADPCM-B priority (higher-quality sample stream)
                if (adpcmb_req_edge) begin
                    adpcm_req_addr_r  <= ADPCM_SDR_BASE + {3'b0, adpcmb_addr_w[23:1]};
                    adpcm_byte_sel    <= adpcmb_addr_w[0];
                    adpcm_rom_req     <= ~adpcm_rom_req;
                    adpcm_req_pending <= 1'b1;
                    adpcm_state       <= ADPCM_FETCH_B;
                end else if (adpcma_req_edge) begin
                    // ADPCM-A: {bank, addr} forms 24-bit address
                    adpcm_req_addr_r  <= ADPCM_SDR_BASE +
                                         {3'b0, adpcma_bank_w[3:0], adpcma_addr_w[19:1]};
                    adpcm_byte_sel    <= adpcma_addr_w[0];
                    adpcm_rom_req     <= ~adpcm_rom_req;
                    adpcm_req_pending <= 1'b1;
                    adpcm_state       <= ADPCM_FETCH_A;
                end
            end

            ADPCM_FETCH_B: begin
                if (adpcm_req_pending && (adpcm_rom_req == adpcm_rom_ack)) begin
                    adpcmb_data_r     <= adpcm_byte_sel ? adpcm_rom_data[15:8]
                                                        : adpcm_rom_data[7:0];
                    adpcm_req_pending <= 1'b0;
                    adpcm_state       <= ADPCM_IDLE;
                end
            end

            ADPCM_FETCH_A: begin
                if (adpcm_req_pending && (adpcm_rom_req == adpcm_rom_ack)) begin
                    adpcma_data_r     <= adpcm_byte_sel ? adpcm_rom_data[15:8]
                                                        : adpcm_rom_data[7:0];
                    adpcm_req_pending <= 1'b0;
                    adpcm_state       <= ADPCM_IDLE;
                end
            end

            default: adpcm_state <= ADPCM_IDLE;
        endcase
    end
end

assign adpcm_rom_addr = adpcm_req_addr_r;

// =============================================================================
// Sprite ROM SDRAM Bridge
// gate3 requests a byte at g3_spr_rom_addr_raw on each g3_spr_rom_rd pulse.
// SDRAM is 16-bit word; byte lane selected by addr[0].
// SDRAM word address = SPR_SDR_BASE + byte_addr[23:1]
// =============================================================================

logic        spr_req_pending;
logic        spr_byte_sel;
logic [26:0] spr_req_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        spr_rom_req      <= 1'b0;
        spr_req_pending  <= 1'b0;
        spr_byte_sel     <= 1'b0;
        spr_req_addr_r   <= 27'b0;
        g3_spr_rom_data  <= 8'h00;
    end else begin
        if (g3_spr_rom_rd && !spr_req_pending) begin
            spr_req_addr_r  <= SPR_SDR_BASE + {3'b0, g3_spr_rom_addr_raw[23:1]};
            spr_byte_sel    <= g3_spr_rom_addr_raw[0];
            spr_req_pending <= 1'b1;
            spr_rom_req     <= ~spr_rom_req;
        end else if (spr_req_pending && (spr_rom_req == spr_rom_ack)) begin
            // Data arrived — latch byte lane
            g3_spr_rom_data <= spr_byte_sel ? spr_rom_data16[15:8] : spr_rom_data16[7:0];
            spr_req_pending <= 1'b0;
        end
    end
end

assign spr_rom_addr = spr_req_addr_r;

// =============================================================================
// BG Tile ROM SDRAM Bridge
// gate4 continuously drives g4_bg_rom_addr_raw; g4_bg_rom_rd is always 1.
// We issue a new SDRAM request each time the address changes.
// =============================================================================

logic        bg_req_pending;
logic        bg_byte_sel;
logic [26:0] bg_req_addr_r;
logic [23:0] bg_last_addr;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        bg_rom_req      <= 1'b0;
        bg_req_pending  <= 1'b0;
        bg_byte_sel     <= 1'b0;
        bg_req_addr_r   <= 27'b0;
        bg_last_addr    <= 24'hFFFFFF;   // invalid — force first fetch
        g4_bg_rom_data  <= 8'h00;
    end else begin
        if (g4_bg_rom_rd && !bg_req_pending &&
                (g4_bg_rom_addr_raw != bg_last_addr)) begin
            bg_last_addr    <= g4_bg_rom_addr_raw;
            bg_req_addr_r   <= BG_SDR_BASE + {3'b0, g4_bg_rom_addr_raw[23:1]};
            bg_byte_sel     <= g4_bg_rom_addr_raw[0];
            bg_req_pending  <= 1'b1;
            bg_rom_req      <= ~bg_rom_req;
        end else if (bg_req_pending && (bg_rom_req == bg_rom_ack)) begin
            g4_bg_rom_data <= bg_byte_sel ? bg_rom_data16[15:8] : bg_rom_data16[7:0];
            bg_req_pending <= 1'b0;
        end
    end
end

assign bg_rom_addr = bg_req_addr_r;

// =============================================================================
// Program ROM SDRAM Bridge
// Toggle-handshake; stall CPU via dtack until data arrives.
// =============================================================================

logic        prog_req_pending;
logic [26:0] prog_req_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        prog_rom_req     <= 1'b0;
        prog_req_pending <= 1'b0;
        prog_req_addr_r  <= 27'b0;
    end else begin
        if (prom_cs && cpu_rw && !prog_req_pending) begin
            // Program ROM is mapped from byte 0x080000; SDRAM base = PROM_SDR_BASE
            // cpu_addr[PROM_ABITS:1] is PROM_ABITS bits wide; pad to 27 bits for SDRAM addr.
            prog_req_addr_r  <= PROM_SDR_BASE + 27'(cpu_addr[PROM_ABITS:1]);
            prog_req_pending <= 1'b1;
            prog_rom_req     <= ~prog_rom_req;
        end else if (prog_req_pending && (prog_rom_req == prog_rom_ack)) begin
            prog_req_pending <= 1'b0;
        end
    end
end

assign prog_rom_addr = prog_req_addr_r;

// =============================================================================
// I/O Registers (PS3103 window covers I/O on Psikyo)
// Byte 0xC00000–0xC0FFFF
//   +0x0000 — Player 1 joystick + buttons (read, active-low)
//   +0x0002 — Player 2 joystick + buttons (read, active-low)
//   +0x0004 — Coins / service (read, active-low)
//   +0x0006 — DIP switch bank 1 (read)
//   +0x0008 — DIP switch bank 2 (read)
// All registers are byte-wide on the lower byte (D[7:0]).
// =============================================================================

logic [7:0] io_dout_byte;

always_comb begin
    io_dout_byte = 8'hFF;
    case (cpu_addr[3:1])
        3'h0: io_dout_byte = joystick_p1;
        3'h1: io_dout_byte = joystick_p2;
        3'h2: io_dout_byte = {2'b11, service, 1'b1, coin[1], coin[0], 2'b11};
        3'h3: io_dout_byte = dipsw1;
        3'h4: io_dout_byte = dipsw2;
        default: io_dout_byte = 8'hFF;
    endcase
end

// =============================================================================
// CPU Data Bus Read Mux
// Priority: psikyo regs > palette RAM > VRAM > sprite RAM > WRAM > prog ROM > I/O > open bus
// =============================================================================

always_comb begin
    if (!psikyo_cs_n)
        cpu_din = psikyo_dout;
    else if (palram_cs)
        cpu_din = palram_cpu_dout;
    else if (vram_cs)
        cpu_din = vram_cpu_dout;
    else if (spram_cs)
        cpu_din = spram_dout_r;
    else if (wram_cs)
        cpu_din = wram_dout_r;
    else if (prom_cs)
        cpu_din = prog_rom_data;
    else if (io_cs)
        cpu_din = {8'hFF, io_dout_byte};
    else
        cpu_din = 16'hFFFF;   // open bus
end

// =============================================================================
// DTACK Generation
// Prog ROM: stall until SDRAM ack.
// All other devices: 1-cycle fast DTACK.
// =============================================================================

logic any_fast_cs;
logic dtack_r;

assign any_fast_cs = !psikyo_cs_n | palram_cs | vram_cs | spram_cs | wram_cs | io_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) dtack_r <= 1'b0;
    else          dtack_r <= any_fast_cs;
end

always_comb begin
    if (cpu_as_n)
        cpu_dtack_n = 1'b1;
    else if (prom_cs)
        cpu_dtack_n = prog_req_pending;   // 0 = ready
    else
        cpu_dtack_n = !dtack_r;
end

// =============================================================================
// Interrupt (IPL) Generation
// VBLANK → level 4 (cpu_ipl_n = ~4 = 3'b011)
// =============================================================================

logic       ipl_vbl_active;
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

always_comb begin
    if (ipl_vbl_active)  cpu_ipl_n = ~VBLANK_LEVEL;
    else                 cpu_ipl_n = 3'b111;   // no interrupt
end

// =============================================================================
// Lint suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = &{
    1'b0,
    dl_ready,
    spr_render_done_w,
    g4_bg_layer_sel,
    final_valid_w,
    pal_entry_r[15],          // R5G5B5 unused bit (transparent flag)
    sprite_ram_din_w,
    sprite_ram_wsel_w,
    // Z80 signals not consumed at top level
    z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n, z80_iorq_n
};
/* verilator lint_on UNUSED */

endmodule
