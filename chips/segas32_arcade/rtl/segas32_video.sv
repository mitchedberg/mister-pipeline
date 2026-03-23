`default_nettype none
`timescale 1ns/1ps
// =============================================================================
// segas32_video.sv — Sega System 32 Video Hardware
// =============================================================================
//
// Implements the video subsystem of the Sega System 32 arcade board.
// Reference: MAME src/mame/sega/segas32_v.cpp, src/mame/sega/segas32.cpp
//
// ── Architecture Overview ────────────────────────────────────────────────────
//
//   System 32 uses five rendering sources composed by a mixer:
//
//     Layer       Type           Tile Size   Notes
//     ─────       ────           ─────────   ─────
//     TEXT        8×8  tilemap   8×8 4bpp    Global scroll only, no zoom
//     NBG0        16×16 tilemap  16×16 4/8bpp  Zoom + offset
//     NBG1        16×16 tilemap  16×16 4/8bpp  Zoom + offset
//     NBG2        16×16 tilemap  16×16 4/8bpp  Rowscroll/rowselect
//     NBG3        16×16 tilemap  16×16 4/8bpp  Rowscroll/rowselect
//     BITMAP      320/416×224    4/8bpp      Direct bitmap from VRAM
//     SPRITES     linked-list    4/8bpp      Double-buffered, zoomed
//     BACKGROUND  solid fill     —           Single palette entry
//
//   This initial implementation covers:
//     Step 1 : Video register file (CPU write path, $1FF00–$1FF8E)
//     Step 2 : Video timing generator (320×224 @ 60 Hz baseline)
//     Step 3 : TEXT layer engine (8×8 tiles, global scroll, HBLANK fill)
//     Step 4 : Palette RAM (16-bit RGB555, 0x4000 entries)
//     Step 5 : Stub layer outputs for NBG0-3 / sprite / bitmap
//     Step 6 : Pixel mixer (priority sort, palette lookup, RGB output)
//
// ── Memory Map (CPU side) ────────────────────────────────────────────────────
//   $300000–$31FFFF  : Video RAM (128 KB)  — tilemaps, gfx, rowscroll tables
//   $400000–$41FFFF  : Sprite RAM (128 KB) — sprite linked-list commands
//   $500000–$50000F  : Sprite control registers (8-bit)
//   $600000–$60FFFF  : Palette RAM (64 KB, 16-bit words)
//   $610000–$61007F  : Mixer control registers
//   $31FF00–$31FF8E  : Video control registers (in VRAM address space)
//
//   All offsets relative to $300000 base (VRAM base) unless noted.
//   MAME segas32.cpp: videoram_r/w at $300000, spriteram at $400000,
//                     paletteram at $600000, mixer at $610000
//
// ── Video Control Registers ($31FF00–$31FF8E, i.e. VRAM offset $1FF00) ───────
//   The V60 CPU writes these as 16-bit words through the normal VRAM interface.
//   They are decoded here from the CPU register write port.
//
//   $1FF00  [CTRL]       bit15=wide(416px), bit9=flip_global, bits3:0=layer_flip
//   $1FF02  [LAYER_EN]   bit-per-layer disable; per-layer clip mode
//   $1FF04  [ROWSCRL]    rowscroll/rowselect enables for NBG2/NBG3
//   $1FF06  [CLIP_SEL]   per-layer clip rectangle select (4 bits each)
//   $1FF12  [NBG0_XSCRL] NBG0 X scroll
//   $1FF16  [NBG0_YSCRL] NBG0 Y scroll
//   $1FF1A  [NBG1_XSCRL] NBG1 X scroll
//   $1FF1E  [NBG1_YSCRL] NBG1 Y scroll
//   $1FF22  [NBG2_XSCRL] NBG2 X scroll
//   $1FF26  [NBG2_YSCRL] NBG2 Y scroll
//   $1FF2A  [NBG3_XSCRL] NBG3 X scroll
//   $1FF2E  [NBG3_YSCRL] NBG3 Y scroll
//   $1FF30  [NBG0_XOF]   NBG0 X center offset (zoom center)
//   $1FF32  [NBG0_YOF]   NBG0 Y center offset
//   $1FF34  [NBG1_XOF]   NBG1 X center offset
//   $1FF36  [NBG1_YOF]   NBG1 Y center offset
//   $1FF40  [NBG0_PAGE]  NBG0 page select (4 quadrants × 7 bits)
//   $1FF42  [NBG1_PAGE]  NBG1 page select
//   $1FF44  [NBG2_PAGE]  NBG2 page select
//   $1FF46  [NBG3_PAGE]  NBG3 page select
//   $1FF50  [NBG0_ZOOM]  NBG0 zoom step X (0x200 = 1.0x)
//   $1FF52  [NBG0_ZOMY]  NBG0 zoom step Y
//   $1FF54  [NBG1_ZOOM]  NBG1 zoom step X
//   $1FF56  [NBG1_ZOMY]  NBG1 zoom step Y
//   $1FF5C  [TEXT_CFG]   text layer page/bank config; bits2:0=tile_bank
//   $1FF5E  [BG_CFG]     background color register; palette offset in CRAM
//   $1FF60–$1FF7E  [CLIP0-3]  4 clip rectangles × (left,top,right,bottom) = 16 words
//   $1FF88  [BMP_XSCRL]  bitmap X scroll (9 bits)
//   $1FF8A  [BMP_YSCRL]  bitmap Y scroll
//   $1FF8C  [BMP_PAL]    bitmap palette base (bits9:3)
//   $1FF8E  [OUT_CTRL]   layer output disable bits
//
// ── Mixer Control Registers ($610000–$61007F) ────────────────────────────────
//   $00–$0F  sprite group priorities (16 groups × 4-bit priority)
//   $20–$2F  layer priorities & palette bases (TEXT, NBG0-3, BACKGROUND)
//   $30–$3F  blend masks per layer
//   $40–$4A  color offset (RGB matrix)
//   $4C      sprite grouping control (shift/mask/OR, shadow mask)
//   $4E      blend enable and blend factor
//   $5E      background palette selector
//
// ── Tilemap FORMAT ───────────────────────────────────────────────────────────
//   NBG0-3 tile entry (16-bit):
//     bit15    : Y flip
//     bit14    : X flip
//     bits13:4 : color palette index (10 bits)
//     bits12:0 : tile index (13 bits)
//   (bit13 is shared — effectively bits[12:0] for 8K tiles, palette [9:4] elsewhere)
//
//   TEXT tile entry (16-bit):
//     bits15:9 : color (7-bit palette bank)
//     bits8:0  : tile index (9 bits, 512 tiles max)
//
// ── Sprite COMMAND Format ────────────────────────────────────────────────────
//   8 × 16-bit words per entry:
//     +0  command/flags  (bits15:14=type: 00=draw, 11=EOL; bit9=8bpp; bit7=flipY; bit6=flipX)
//     +1  src height[15:8], src width[7:0]
//     +2  dst height[9:0]
//     +3  dst width[9:0]
//     +4  Y position (signed 12-bit)
//     +5  X position (signed 12-bit)
//     +6  ROM address / offset
//     +7  palette[15:4], priority[3:0]
//
// ── Palette RAM Format ───────────────────────────────────────────────────────
//   16-bit RGB555:  bit15=reserved(shadow), bits14:10=B, bits9:5=G, bits4:0=R
//
// ── Pixel Clock and Timing ───────────────────────────────────────────────────
//   System 32: 320×224 (normal) or 416×224 (wide) @ 60 Hz
//   MAME screen: MCFG_SCREEN_SIZE(416, 262), VISIBLE(0,319, 0,223) for narrow mode
//   H total: 528 (320 mode) or 528 (to maintain 60 Hz with PLL)
//   V total: 262 lines per frame
//   V active: lines 0–223 (224 lines)
//   H active: 320 pixels (narrow) or 416 pixels (wide)
//   Pixel clock ≈ 320×262×60 = ~5.02 MHz (narrow); use 6.144 MHz or system PLL
//
//   This RTL uses parametric H/V totals for flexibility.
//   Default parameters match the 320-pixel narrow mode used by Rad Mobile.
//
// =============================================================================

module segas32_video #(
    // ── Timing parameters ────────────────────────────────────────────────────
    parameter int H_TOTAL   = 528,      // total pixels per line
    parameter int H_ACTIVE  = 320,      // visible pixels
    parameter int H_SYNC_S  = 336,      // hsync start
    parameter int H_SYNC_E  = 392,      // hsync end
    parameter int V_TOTAL   = 262,      // total lines per frame
    parameter int V_ACTIVE  = 224,      // visible lines
    parameter int V_SYNC_S  = 234,      // vsync start
    parameter int V_SYNC_E  = 238,      // vsync end

    // ── VRAM geometry ────────────────────────────────────────────────────────
    parameter int VRAM_AW   = 16,       // VRAM word address bits (64K words = 128KB)
    parameter int SPR_AW    = 16        // Sprite RAM word address bits (64K words)
) (
    // ── Clocks and Reset ─────────────────────────────────────────────────────
    input  logic        clk,            // pixel clock (~6.14 MHz for 320-mode)
    input  logic        clk_sys,        // system clock (same or faster)
    input  logic        rst_n,

    // ── CPU Interface — VRAM (tilemaps, gfx, rowscroll) ─────────────────────
    // CPU writes 16-bit words; address is word offset from $300000 base.
    input  logic                cpu_vram_cs,
    input  logic                cpu_vram_we,
    input  logic [VRAM_AW-1:0]  cpu_vram_addr,     // word address 0..(64K-1)
    input  logic [15:0]         cpu_vram_din,
    input  logic [ 1:0]         cpu_vram_be,        // byte enables
    output logic [15:0]         cpu_vram_dout,

    // ── CPU Interface — Sprite RAM ($400000–$41FFFF) ─────────────────────────
    input  logic                cpu_spr_cs,
    input  logic                cpu_spr_we,
    input  logic [SPR_AW-1:0]   cpu_spr_addr,
    input  logic [15:0]         cpu_spr_din,
    input  logic [ 1:0]         cpu_spr_be,
    output logic [15:0]         cpu_spr_dout,

    // ── CPU Interface — Sprite Control ($500000–$50000F) ─────────────────────
    input  logic                cpu_sprctl_cs,
    input  logic                cpu_sprctl_we,
    input  logic [ 3:0]         cpu_sprctl_addr,    // byte address 0..15
    input  logic [ 7:0]         cpu_sprctl_din,
    output logic [ 7:0]         cpu_sprctl_dout,

    // ── CPU Interface — Palette RAM ($600000–$60FFFF) ────────────────────────
    input  logic                cpu_pal_cs,
    input  logic                cpu_pal_we,
    input  logic [13:0]         cpu_pal_addr,       // word address 0..(16K-1)
    input  logic [15:0]         cpu_pal_din,
    input  logic [ 1:0]         cpu_pal_be,
    output logic [15:0]         cpu_pal_dout,

    // ── CPU Interface — Mixer Control ($610000–$61007F) ──────────────────────
    input  logic                cpu_mix_cs,
    input  logic                cpu_mix_we,
    input  logic [ 5:0]         cpu_mix_addr,       // word address 0..63
    input  logic [15:0]         cpu_mix_din,
    input  logic [ 1:0]         cpu_mix_be,
    output logic [15:0]         cpu_mix_dout,

    // ── GFX ROM interface — tilemap tiles (16×16 4bpp from ROM) ─────────────
    // Byte-addressed; text layer tiles are 8×8 in VRAM, BG tiles from ROM.
    output logic [21:0]         gfx_addr,           // byte address into GFX ROM
    input  logic [31:0]         gfx_data,           // 4 bytes / 8 pixels of tile data
    output logic                gfx_rd,

    // ── Video timing outputs ─────────────────────────────────────────────────
    output logic                hsync,
    output logic                vsync,
    output logic                hblank,
    output logic                vblank,
    output logic [ 9:0]         hpos,               // 0..H_TOTAL-1
    output logic [ 8:0]         vpos,               // 0..V_TOTAL-1
    output logic                pixel_active,

    // ── RGB pixel output (24-bit) ────────────────────────────────────────────
    output logic [ 7:0]         pixel_r,
    output logic [ 7:0]         pixel_g,
    output logic [ 7:0]         pixel_b,
    output logic                pixel_de            // display enable
);

// =============================================================================
// SECTION 1: Video Timing Generator
// =============================================================================
// Generates hpos/vpos counters, hsync/vsync, hblank/vblank, pixel_active.
// Follows System 32 320×224@60Hz parameters (narrow mode / Rad Mobile).
// =============================================================================

logic hblank_fall, vblank_fall, hblank_rise;
logic [9:0] hpos_next;
logic [8:0] vpos_next;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hpos       <= '0;
        vpos       <= '0;
        hsync      <= 1'b0;
        vsync      <= 1'b0;
        hblank     <= 1'b0;
        vblank     <= 1'b0;
        pixel_active <= 1'b0;
    end else begin
        // Advance hpos
        if (hpos == 10'(H_TOTAL - 1)) begin
            hpos <= '0;
            if (vpos == 9'(V_TOTAL - 1))
                vpos <= '0;
            else
                vpos <= vpos + 9'd1;
        end else begin
            hpos <= hpos + 10'd1;
        end

        // Hsync
        hsync <= (hpos >= H_SYNC_S[9:0] && hpos < H_SYNC_E[9:0]);

        // Vsync
        vsync <= (vpos >= V_SYNC_S[8:0] && vpos < V_SYNC_E[8:0]);

        // Blanking
        hblank       <= (hpos >= H_ACTIVE[9:0]);
        vblank       <= (vpos >= V_ACTIVE[8:0]);
        pixel_active <= (hpos < H_ACTIVE[9:0]) && (vpos < V_ACTIVE[8:0]);
    end
end

// Combinational next-cycle position (used by tile engines to prefetch)
assign hpos_next = (hpos == 10'(H_TOTAL - 1)) ? '0 : hpos + 10'd1;
assign vpos_next = (hpos == 10'(H_TOTAL - 1)) ?
                   ((vpos == 9'(V_TOTAL - 1)) ? '0 : vpos + 9'd1) : vpos;

// Next SCAN LINE — always vpos+1 (wraps). Used by HBLANK prefetch FSMs:
// at HBLANK of line N, fill line buffer for line N+1 (which will be displayed next).
logic [8:0] vline_next;
assign vline_next = (vpos == 9'(V_TOTAL - 1)) ? '0 : vpos + 9'd1;

// Detect hblank rising edge (pixel clock domain) — fires start of HBLANK
logic hblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_r <= 1'b0;
    else        hblank_r <= hblank;
end
assign hblank_rise = ~hblank_r &  hblank;
assign hblank_fall =  hblank_r & ~hblank;

// Detect vblank falling edge — fires start of active display (top of frame)
logic vblank_r;
always_ff @(posedge clk) begin
    if (!rst_n) vblank_r <= 1'b0;
    else        vblank_r <= vblank;
end
assign vblank_fall = vblank_r & ~vblank;

// =============================================================================
// SECTION 2: VRAM — Dual-port (CPU + video read)
// =============================================================================
// 64K × 16-bit VRAM (128 KB).
// Port A: CPU read/write (synchronous, byte-enable).
// Port B: Video logic read (synchronous, 1-cycle latency).
//
// VRAM address map (word addresses within $300000–$31FFFF):
//   $0000–$7FFF  : NBG0 tilemap pages (each 32×16 tile page = 512 words)
//   $8000–$BFFF  : NBG1 tilemap pages
//   $C000–$CFFF  : NBG2 tilemap
//   $D000–$DFFF  : NBG3 tilemap
//   $E000–$EFFF  : TEXT tilemap (64 cols × 32 rows of 8×8 tiles = 2048 entries)
//   $F000–$F7FF  : TEXT gfx data (512 tiles × 8 rows × 2 words/row = 8192 words)
//   $F800–$FBFF  : rowscroll/rowselect tables
//   $FC00–$FFFF  : reserved / bitmap data
//   $1FF00–$1FF8E: Video control registers (decoded separately below)
//
// =============================================================================

/* (* ram_style = "block" *) — removed for sim compatibility; re-add for synthesis */
logic [15:0] vram [0:65535];

// Port A: CPU
always_ff @(posedge clk) begin
    if (cpu_vram_cs) begin
        if (cpu_vram_we) begin
            if (cpu_vram_be[0]) vram[cpu_vram_addr][ 7:0] <= cpu_vram_din[ 7:0];
            if (cpu_vram_be[1]) vram[cpu_vram_addr][15:8] <= cpu_vram_din[15:8];
        end
        cpu_vram_dout <= vram[cpu_vram_addr];
    end
end

// Port B: Video read — four combinational sub-ports for tile engines.
// Combinational read avoids the 2-cycle latency issue with Verilator's NBA scheduling.
// In synthesis, each port maps to a separate BRAM read port (or time-multiplexed).
//
//   vram_tf : TEXT layer map reads (driven by TEXT FSM)
//   vram_sc : TEXT layer gfx reads (driven by TEXT FSM)
//   vram_n0 : NBG0 tile map reads   (driven by NBG0 FSM)
//   vram_n1 : NBG1 tile map reads   (driven by NBG1 FSM)
logic [15:0] vram_tf_q, vram_sc_q, vram_n0_q, vram_n1_q;
logic [15:0] vram_tf_addr, vram_sc_addr, vram_n0_addr, vram_n1_addr;
logic        vram_tf_rd,   vram_sc_rd;

assign vram_tf_q = vram[vram_tf_addr];
assign vram_sc_q = vram[vram_sc_addr];
assign vram_n0_q = vram[vram_n0_addr];
assign vram_n1_q = vram[vram_n1_addr];

// =============================================================================
// SECTION 3: Sprite RAM — Dual-port (CPU + sprite engine)
// =============================================================================
// 64K × 16-bit sprite RAM (128 KB, double-buffered by sprite engine).
// Sprite entries: 8 × 16-bit words, linked-list commands.
// =============================================================================

(* ram_style = "block" *)
logic [15:0] spriteram [0:65535];

always_ff @(posedge clk) begin
    if (cpu_spr_cs) begin
        if (cpu_spr_we) begin
            if (cpu_spr_be[0]) spriteram[cpu_spr_addr][ 7:0] <= cpu_spr_din[ 7:0];
            if (cpu_spr_be[1]) spriteram[cpu_spr_addr][15:8] <= cpu_spr_din[15:8];
        end
        cpu_spr_dout <= spriteram[cpu_spr_addr];
    end
end

// =============================================================================
// SECTION 4: Sprite Control Registers ($500000–$50000F)
// =============================================================================
// 8-bit registers. MAME: sprite_control_r/w().
//   Offset 0: sprite control (bit0 = active buffer select)
//   Offset 1: sprite status (bit1 = rendering, bit2 = overdraw)
// =============================================================================

logic [7:0] spr_ctrl [0:15];

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < 16; i++) spr_ctrl[i] <= 8'h00;
    end else begin
        if (cpu_sprctl_cs && cpu_sprctl_we)
            spr_ctrl[cpu_sprctl_addr] <= cpu_sprctl_din;
    end
end
assign cpu_sprctl_dout = spr_ctrl[cpu_sprctl_addr];

// =============================================================================
// SECTION 5: Palette RAM ($600000–$60FFFF)
// =============================================================================
// 16K × 16-bit entries. RGB555 format: {1'b0, B[4:0], G[4:0], R[4:0]}
// (MAME segas32.cpp lower-half format: xBBBBBGGGGGRRRRR)
// =============================================================================

(* ram_style = "block" *)
logic [15:0] palette [0:16383];

always_ff @(posedge clk) begin
    if (cpu_pal_cs) begin
        if (cpu_pal_we) begin
            if (cpu_pal_be[0]) palette[cpu_pal_addr][ 7:0] <= cpu_pal_din[ 7:0];
            if (cpu_pal_be[1]) palette[cpu_pal_addr][15:8] <= cpu_pal_din[15:8];
        end
        cpu_pal_dout <= palette[cpu_pal_addr];
    end
end

// Video-side palette read (1-cycle latency)
logic [13:0] pal_rd_addr;
logic [15:0] pal_rd_q;
logic        pal_rd;

always_ff @(posedge clk) begin
    if (pal_rd) pal_rd_q <= palette[pal_rd_addr];
end

// =============================================================================
// SECTION 6: Mixer Control Registers ($610000–$61007F)
// =============================================================================
// 64 × 16-bit words. MAME segas32.cpp mixer_r/w at $610000.
//   Word 0x00–0x07: sprite group priorities (16 nibbles packed)
//   Word 0x10–0x17: layer priorities + palette base (TEXT, NBG0-3, BG)
//   Word 0x18–0x1F: blend masks per layer
//   Word 0x20–0x25: color offset matrix (RGB)
//   Word 0x26:      sprite grouping (shift, mask, OR, shadow)
//   Word 0x27:      blend enable and factor
//   Word 0x2F:      background palette selector
//
// MAME mixer reg byte offsets × 2 → word index:
//   $00/$01 → word[0x00]: spr group prio 0/1
//   $20/$21 → word[0x10]: TEXT priority/palette base
//   $22/$23 → word[0x11]: NBG0 priority/palette base
//   $4C/$4D → word[0x26]: sprite grouping control
//   $4E/$4F → word[0x27]: blend enable/factor
//   $5E/$5F → word[0x2F]: background palette
// =============================================================================

logic [15:0] mix_regs [0:63];

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < 64; i++) mix_regs[i] <= 16'h0000;
    end else begin
        if (cpu_mix_cs && cpu_mix_we) begin
            if (cpu_mix_be[0]) mix_regs[cpu_mix_addr][ 7:0] <= cpu_mix_din[ 7:0];
            if (cpu_mix_be[1]) mix_regs[cpu_mix_addr][15:8] <= cpu_mix_din[15:8];
        end
    end
end
assign cpu_mix_dout = mix_regs[cpu_mix_addr];

// Decode commonly-used mixer fields
// MAME: layer priority stored in bits[7:4] of each mixer word, palette base in bits[3:0] × 256
// Word 0x10 → TEXT;  0x11 → NBG0;  0x12 → NBG1;  0x13 → NBG2;  0x14 → NBG3;  0x15 → BG
logic [3:0] mix_prio_text, mix_prio_nbg0, mix_prio_nbg1, mix_prio_nbg2, mix_prio_nbg3;
logic [3:0] mix_palbase_text, mix_palbase_nbg0;

assign mix_prio_text    = mix_regs[6'h10][7:4];
assign mix_prio_nbg0    = mix_regs[6'h11][7:4];
assign mix_prio_nbg1    = mix_regs[6'h12][7:4];
assign mix_prio_nbg2    = mix_regs[6'h13][7:4];
assign mix_prio_nbg3    = mix_regs[6'h14][7:4];
assign mix_palbase_text = mix_regs[6'h10][3:0];
assign mix_palbase_nbg0 = mix_regs[6'h11][3:0];

// Blend control: word 0x27 bits[10,8:8]=enable, bits[2:0]=factor
logic       blend_en;
logic [2:0] blend_factor;
assign blend_en     = mix_regs[6'h27][10];
assign blend_factor = mix_regs[6'h27][2:0];

// =============================================================================
// SECTION 7: Video Control Registers (decoded from VRAM writes at $1FF00–$1FF8E)
// =============================================================================
// The CPU writes these into VRAM just like tilemap data.
// We intercept writes to word addresses $1FF00>>1 .. $1FF8E>>1 = $FF80..$FFC7
// and shadow them in a dedicated register file.
//
// MAME segas32_v.cpp: these are read by update_background(), update_tilemap_*(),
//                     draw_sprites() at the start of each frame render.
// =============================================================================

// Decoded video control registers
logic        reg_wide;          // $1FF00 bit15: 1=416px, 0=320px
logic        reg_global_flip;   // $1FF00 bit9: global flip enable
logic [3:0]  reg_layer_flip;    // $1FF00 bits3:0: per-layer flip (TEXT,NBG0-3)
logic [15:0] reg_layer_en;      // $1FF02: layer enable (0=on, 1=off per bit)
logic [15:0] reg_rowscrl_ctrl;  // $1FF04: rowscroll/rowselect control
logic [15:0] reg_clip_sel;      // $1FF06: clip rectangle selection per layer

logic [15:0] reg_nbg0_xscrl;    // $1FF12
logic [15:0] reg_nbg0_yscrl;    // $1FF16
logic [15:0] reg_nbg1_xscrl;    // $1FF1A
logic [15:0] reg_nbg1_yscrl;    // $1FF1E
logic [15:0] reg_nbg2_xscrl;    // $1FF22
logic [15:0] reg_nbg2_yscrl;    // $1FF26
logic [15:0] reg_nbg3_xscrl;    // $1FF2A
logic [15:0] reg_nbg3_yscrl;    // $1FF2E

logic [15:0] reg_nbg0_xof;      // $1FF30: NBG0 zoom center X
logic [15:0] reg_nbg0_yof;      // $1FF32: NBG0 zoom center Y
logic [15:0] reg_nbg1_xof;      // $1FF34
logic [15:0] reg_nbg1_yof;      // $1FF36

logic [15:0] reg_nbg0_page;     // $1FF40: NBG0 page select (4 quadrants)
logic [15:0] reg_nbg1_page;     // $1FF42
logic [15:0] reg_nbg2_page;     // $1FF44
logic [15:0] reg_nbg3_page;     // $1FF46

logic [15:0] reg_nbg0_zoomx;    // $1FF50: NBG0 X zoom step (0x200 = 1:1)
logic [15:0] reg_nbg0_zoomy;    // $1FF52: NBG0 Y zoom step
logic [15:0] reg_nbg1_zoomx;    // $1FF54
logic [15:0] reg_nbg1_zoomy;    // $1FF56

logic [15:0] reg_text_cfg;      // $1FF5C: text page select; bits2:0=tile_bank
logic [15:0] reg_bg_cfg;        // $1FF5E: background color/palette offset

logic [15:0] reg_clip [0:3];    // $1FF60–$1FF6E: 4 clip rects, each [left,top,right,bottom]
                                 // stored as: clip[n] = {top[7:0], left[7:0]} then {bot,right}
// We store each clip rect as 4 words: [0]=left, [1]=top, [2]=right, [3]=bottom
logic [15:0] clip_rect [0:3][0:3];

logic [15:0] reg_bmp_xscrl;     // $1FF88
logic [15:0] reg_bmp_yscrl;     // $1FF8A
logic [15:0] reg_bmp_pal;       // $1FF8C
logic [15:0] reg_out_ctrl;      // $1FF8E

// Intercept VRAM writes to $1FF00–$1FF8E (word addresses $FF80–$FFC7)
// Byte address $1FF00 → word address $FF80 (= 0xFF80)
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        reg_wide         <= 1'b0;
        reg_global_flip  <= 1'b0;
        reg_layer_flip   <= 4'h0;
        reg_layer_en     <= 16'h0000;
        reg_rowscrl_ctrl <= 16'h0000;
        reg_clip_sel     <= 16'h0000;
        reg_nbg0_xscrl   <= 16'h0000;
        reg_nbg0_yscrl   <= 16'h0000;
        reg_nbg1_xscrl   <= 16'h0000;
        reg_nbg1_yscrl   <= 16'h0000;
        reg_nbg2_xscrl   <= 16'h0000;
        reg_nbg2_yscrl   <= 16'h0000;
        reg_nbg3_xscrl   <= 16'h0000;
        reg_nbg3_yscrl   <= 16'h0000;
        reg_nbg0_xof     <= 16'h0000;
        reg_nbg0_yof     <= 16'h0000;
        reg_nbg1_xof     <= 16'h0000;
        reg_nbg1_yof     <= 16'h0000;
        reg_nbg0_page    <= 16'h0000;
        reg_nbg1_page    <= 16'h0000;
        reg_nbg2_page    <= 16'h0000;
        reg_nbg3_page    <= 16'h0000;
        reg_nbg0_zoomx   <= 16'h0200;  // 1:1 scale default
        reg_nbg0_zoomy   <= 16'h0200;
        reg_nbg1_zoomx   <= 16'h0200;
        reg_nbg1_zoomy   <= 16'h0200;
        reg_text_cfg     <= 16'h0000;
        reg_bg_cfg       <= 16'h0000;
        reg_bmp_xscrl    <= 16'h0000;
        reg_bmp_yscrl    <= 16'h0000;
        reg_bmp_pal      <= 16'h0000;
        reg_out_ctrl     <= 16'h0000;
        for (int i = 0; i < 4; i++)
            for (int j = 0; j < 4; j++)
                clip_rect[i][j] <= 16'h0000;
    end else if (cpu_vram_cs && cpu_vram_we && cpu_vram_addr[15:7] == 9'h1FF) begin
        // Word address $FF80+ corresponds to byte $1FF00+
        // cpu_vram_addr[6:0] selects which word within the reg block
        case (cpu_vram_addr[6:0])
            7'h00: begin // $1FF00 — CTRL
                if (cpu_vram_be[1]) begin
                    reg_wide        <= cpu_vram_din[15];
                    reg_global_flip <= cpu_vram_din[9];
                end
                if (cpu_vram_be[0]) reg_layer_flip <= cpu_vram_din[3:0];
            end
            7'h01: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF02 — LAYER_EN
                reg_layer_en <= cpu_vram_din;
            7'h02: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF04 — ROWSCRL
                reg_rowscrl_ctrl <= cpu_vram_din;
            7'h03: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF06 — CLIP_SEL
                reg_clip_sel <= cpu_vram_din;
            7'h09: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF12 — NBG0_XSCRL
                reg_nbg0_xscrl <= cpu_vram_din;
            7'h0B: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF16 — NBG0_YSCRL
                reg_nbg0_yscrl <= cpu_vram_din;
            7'h0D: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF1A — NBG1_XSCRL
                reg_nbg1_xscrl <= cpu_vram_din;
            7'h0F: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF1E — NBG1_YSCRL
                reg_nbg1_yscrl <= cpu_vram_din;
            7'h11: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF22 — NBG2_XSCRL
                reg_nbg2_xscrl <= cpu_vram_din;
            7'h13: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF26 — NBG2_YSCRL
                reg_nbg2_yscrl <= cpu_vram_din;
            7'h15: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF2A — NBG3_XSCRL
                reg_nbg3_xscrl <= cpu_vram_din;
            7'h17: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF2E — NBG3_YSCRL
                reg_nbg3_yscrl <= cpu_vram_din;
            7'h18: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF30 — NBG0_XOF
                reg_nbg0_xof <= cpu_vram_din;
            7'h19: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF32 — NBG0_YOF
                reg_nbg0_yof <= cpu_vram_din;
            7'h1A: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF34 — NBG1_XOF
                reg_nbg1_xof <= cpu_vram_din;
            7'h1B: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF36 — NBG1_YOF
                reg_nbg1_yof <= cpu_vram_din;
            7'h20: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF40 — NBG0_PAGE
                reg_nbg0_page <= cpu_vram_din;
            7'h21: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF42 — NBG1_PAGE
                reg_nbg1_page <= cpu_vram_din;
            7'h22: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF44 — NBG2_PAGE
                reg_nbg2_page <= cpu_vram_din;
            7'h23: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF46 — NBG3_PAGE
                reg_nbg3_page <= cpu_vram_din;
            7'h28: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF50 — NBG0_ZOOMX
                reg_nbg0_zoomx <= cpu_vram_din;
            7'h29: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF52 — NBG0_ZOOMY
                reg_nbg0_zoomy <= cpu_vram_din;
            7'h2A: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF54 — NBG1_ZOOMX
                reg_nbg1_zoomx <= cpu_vram_din;
            7'h2B: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF56 — NBG1_ZOOMY
                reg_nbg1_zoomy <= cpu_vram_din;
            7'h2E: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF5C — TEXT_CFG
                reg_text_cfg <= cpu_vram_din;
            7'h2F: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF5E — BG_CFG
                reg_bg_cfg <= cpu_vram_din;
            // Clip rectangles $1FF60–$1FF7E: words $30..$3F
            // Layout: 4 rects × [left word, right word] where each word = {top[7:0],bottom[7:0]}?
            // MAME segas32_v.cpp compute_clipping_extents() reads:
            //   left  = vregs[0x60/2 + n*4 + 0]
            //   top   = vregs[0x60/2 + n*4 + 1]
            //   right = vregs[0x60/2 + n*4 + 2]
            //   bot   = vregs[0x60/2 + n*4 + 3]
            // So 4 words per rect: left(7:0), top(7:0), right(7:0), bottom(7:0)
            7'h30: clip_rect[0][0] <= cpu_vram_din;  // rect0 left   $1FF60
            7'h31: clip_rect[0][1] <= cpu_vram_din;  // rect0 top    $1FF62
            7'h32: clip_rect[0][2] <= cpu_vram_din;  // rect0 right  $1FF64
            7'h33: clip_rect[0][3] <= cpu_vram_din;  // rect0 bottom $1FF66
            7'h34: clip_rect[1][0] <= cpu_vram_din;  // rect1 left   $1FF68
            7'h35: clip_rect[1][1] <= cpu_vram_din;  // rect1 top
            7'h36: clip_rect[1][2] <= cpu_vram_din;  // rect1 right
            7'h37: clip_rect[1][3] <= cpu_vram_din;  // rect1 bottom
            7'h38: clip_rect[2][0] <= cpu_vram_din;  // rect2 left   $1FF70
            7'h39: clip_rect[2][1] <= cpu_vram_din;  // rect2 top
            7'h3A: clip_rect[2][2] <= cpu_vram_din;  // rect2 right
            7'h3B: clip_rect[2][3] <= cpu_vram_din;  // rect2 bottom
            7'h3C: clip_rect[3][0] <= cpu_vram_din;  // rect3 left   $1FF78
            7'h3D: clip_rect[3][1] <= cpu_vram_din;  // rect3 top
            7'h3E: clip_rect[3][2] <= cpu_vram_din;  // rect3 right
            7'h3F: clip_rect[3][3] <= cpu_vram_din;  // rect3 bottom
            7'h44: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF88 — BMP_XSCRL
                reg_bmp_xscrl <= cpu_vram_din;
            7'h45: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF8A — BMP_YSCRL
                reg_bmp_yscrl <= cpu_vram_din;
            7'h46: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF8C — BMP_PAL
                reg_bmp_pal <= cpu_vram_din;
            7'h47: if (cpu_vram_be[1] || cpu_vram_be[0])  // $1FF8E — OUT_CTRL
                reg_out_ctrl <= cpu_vram_din;
            default: ; // Normal VRAM write; handled by Section 2 above
        endcase
    end
end

// =============================================================================
// SECTION 8: TEXT Layer Engine
// =============================================================================
// 8×8 4bpp tiles. Map in VRAM at word base $E000 (= byte $1C000 relative to $300000).
// GFX data in VRAM at word base $F000 (= byte $1E000 relative to $300000).
//
// TEXT tile entry (16-bit word):
//   bits[15:9] : color (7-bit palette bank → palette base = color × 16)
//   bits[8:0]  : tile index (0..511)
//
// Map layout: 64 cols × 32 rows = 2048 entries.
//   Word address = map_base + row * 64 + col
//   where map_base = $E000 + (reg_text_cfg[8:4] × 0x80) for page select
//   Default (page=0): map_base = $E000
//
// GFX data layout: 512 tiles × 8 rows × 2 words/row = 8192 words starting at $F000.
//   tile_base_word = $F000 + tile_idx * 16 + py * 2
//   Each row = 2 × 16-bit words = 32 bits total for 8 pixels × 4bpp.
//   Pixel packing (same as Sega S32 TEXT hardware):
//     word0[15:12]=px3, [11:8]=px2, [7:4]=px1, [3:0]=px0
//     word1[15:12]=px7, [11:8]=px6, [7:4]=px5, [3:0]=px4
//   With flipX: px order reversed within tile.
//   With flipY: use row (7 - py) instead of py.
//   Note: TEXT tiles have NO flipX/flipY in System 32 — text is fixed orientation.
//
// HBLANK FSM: Fill a 320-wide line buffer each HBLANK.
//   Need ceil(320/8)+1 = 41 tiles, each requiring 3 VRAM reads (1 map + 2 gfx).
//   Total: 41 × 3 = 123 cycles; HBLANK is 208 cycles → fits easily.
//
// Output: text_pix[12:0] = {color[6:0], pen[3:0]}; pen==0 → transparent (color 0).
//         text_valid: asserted for valid (non-transparent) pixels.
//
// VRAM port: Uses vram_tf for map reads, vram_sc for gfx reads.
//   Both ports have 1-cycle registered latency.
//
// Implementation note on tile bank:
//   reg_text_cfg[2:0] = tile_bank → adds bank×0x200 to tile gfx base address.
//   reg_text_cfg[8:4] = page select → adds page×0x80 to map base.
// =============================================================================

// Text layer line buffer: 416 pixels wide (max width), each pixel is 11 bits
// {color[6:0], pen[3:0]}
localparam int TEXT_BUF_W = 416;
logic [10:0] text_linebuf [0:TEXT_BUF_W-1];

// FSM states — 4-stage pipelined BRAM fetch
// BRAM latency: addr set at end of state N → data available at start of state N+1.
// Pipelined so each tile takes exactly 4 cycles after initial 2-cycle startup:
//
//   IDLE  : (hblank_rise) set map_addr[col=0] → S_MAP
//   S_MAP : (map data arrives) latch color+tile; set gfx_w0_addr → S_W0
//   S_W0  : (gfx_w0 data arrives) latch w0; set gfx_w1_addr; set NEXT map_addr → S_W1
//   S_W1  : (gfx_w1 data arrives) write 8 pixels; → S_MAP (data for col+1 already fetching)
//           (also: next tile's map address was pre-fetched in S_W0; S_MAP sees it)
//
// Two ports used:
//   vram_tf port: map address (tile map entries)
//   vram_sc port: gfx address (tile pixel data, word0 and word1)
//
// S_W0 issues BOTH gfx_w1_addr (to vram_sc) AND NEXT tile's map_addr (to vram_tf)
// simultaneously. This is valid since they use different ports.
//
// Cycle budget: 2 startup + 41 tiles × 4 = 166 cycles < 208-cycle HBLANK. ✓
typedef enum logic [2:0] {
    TXT_IDLE = 3'd0,
    TXT_MAP  = 3'd1,   // vram_tf_q = map[col]; latch color+tile; set vram_sc_addr = gfx_w0
    TXT_W0   = 3'd2,   // vram_sc_q = gfx_w0; latch w0; set sc_addr=gfx_w1, tf_addr=map[col+1]
    TXT_W1   = 3'd3    // vram_sc_q = gfx_w1; write pixels; → TXT_MAP (next tile map ready)
} txt_state_t;

txt_state_t txt_state;

// Latched tile decode
logic [6:0]  txt_color;     // color bank from map word
logic [8:0]  txt_tile_idx;  // tile index from map word
logic [15:0] txt_gfx_w0;    // pixel row word 0
logic [15:0] txt_gfx_w1;    // pixel row word 1

// Fetch geometry (computed at hblank_rise, valid throughout HBLANK)
logic [9:0]  txt_canvas_y;  // Y position in tile map space
logic [5:0]  txt_tile_row;  // which tile row (0..31)
logic [2:0]  txt_py;        // pixel row within tile (0..7)
logic [6:0]  txt_fetch_col; // current tile column being fetched (0..63)
logic [9:0]  txt_write_x;   // current write position in line buffer

// Map base word address: $E000 + page_select × $80
// Page select = reg_text_cfg[8:4]
logic [15:0] txt_map_base;
assign txt_map_base = 16'hE000 + {9'h0, reg_text_cfg[8:4], 2'b00};

// Tile gfx base: $F000 + tile_bank × $0200
// Each bank = $0200 words = 32 tiles
logic [15:0] txt_gfx_bank_offset;
assign txt_gfx_bank_offset = {7'h0, reg_text_cfg[2:0], 6'h00};

// latch fetch geometry at HBLANK rising edge
logic [9:0] txt_canvas_y_comb;
assign txt_canvas_y_comb = vpos[8:0] + reg_text_cfg[8:0]; // rough: use scrollY if needed

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        txt_canvas_y  <= '0;
        txt_tile_row  <= '0;
        txt_py        <= '0;
        txt_fetch_col <= '0;
        txt_write_x   <= '0;
        txt_state     <= TXT_IDLE;
        txt_color     <= '0;
        txt_tile_idx  <= '0;
        txt_gfx_w0    <= '0;
        txt_gfx_w1    <= '0;
        vram_tf_rd    <= 1'b0;
        vram_sc_rd    <= 1'b0;
    end else begin
        vram_tf_rd <= 1'b0;
        vram_sc_rd <= 1'b0;

        case (txt_state)
            // ─── IDLE ─────────────────────────────────────────────────────────
            // Waiting for hblank_rise. When detected, capture scanline geometry
            // and issue the FIRST tile's map address to BRAM.
            // BRAM will return map[col=0] in the NEXT cycle (TXT_MAP state).
            TXT_IDLE: begin
                if (hblank_rise) begin
                    txt_tile_row  <= {1'b0, vline_next[7:3]};  // tile row for next line
                    txt_py        <= vline_next[2:0];           // pixel row within tile
                    txt_fetch_col <= '0;
                    txt_write_x   <= '0;
                    // Issue map address for col=0 NOW so data arrives in TXT_MAP
                    vram_tf_addr  <= txt_map_base
                                     + 16'({4'h0, vline_next[7:3], 6'h0})  // row × 64
                                     + 16'({9'h0, 7'h0});                   // col = 0
                    txt_state     <= TXT_MAP;
                end
            end

            // ─── TXT_MAP ──────────────────────────────────────────────────────
            // BRAM output vram_tf_q = map[fetch_col] (address issued in IDLE or TXT_W1).
            // Latch color + tile index.
            // Issue gfx_w0 address to vram_sc port.
            TXT_MAP: begin
                // Latch map data (vram_tf_q is combinational = vram[vram_tf_addr])
                txt_color    <= vram_tf_q[15:9];   // color bank (7 bits)
                txt_tile_idx <= vram_tf_q[8:0];    // tile index (9 bits)
                // Issue gfx word0 address: $F000 + bank_offset + tile_idx*16 + py*2
                // Use vram_tf_q[8:0] directly (same cycle; NBA hasn't updated tile_idx yet)
                vram_sc_addr <= 16'hF000 + txt_gfx_bank_offset
                                + 16'({3'h0, vram_tf_q[8:0], 4'h0})   // tile×16
                                + 16'({12'h0, txt_py, 1'b0});          // py×2
                txt_state    <= TXT_W0;
            end

            // ─── TXT_W0 ───────────────────────────────────────────────────────
            // BRAM output vram_sc_q = gfx_w0 (address issued in TXT_MAP).
            // Latch word0.
            // Issue gfx_w1 address to vram_sc port.
            // ALSO pre-fetch next tile's map address to vram_tf port (parallel).
            TXT_W0: begin
                // Latch gfx word0
                txt_gfx_w0   <= vram_sc_q;
                // Issue gfx word1 address (same tile, next word)
                vram_sc_addr <= 16'hF000 + txt_gfx_bank_offset
                                + 16'({3'h0, txt_tile_idx, 4'h0})      // tile×16
                                + 16'({12'h0, txt_py, 1'b0}) + 16'd1;  // py×2+1
                // Pre-fetch NEXT tile's map address (pipelining: addr issued now,
                // data arrives in TXT_MAP after TXT_W1)
                vram_tf_addr <= txt_map_base
                                + 16'({4'h0, txt_tile_row[4:0], 6'h0})      // row × 64
                                + 16'({9'h0, txt_fetch_col}) + 16'd1;       // col+1
                txt_state    <= TXT_W1;
            end

            // ─── TXT_W1 ───────────────────────────────────────────────────────
            // BRAM output vram_sc_q = gfx_w1 (address issued in TXT_W0).
            // Write 8 pixels to line buffer.
            // Advance column counter.
            // Loop to TXT_MAP (which will see vram_tf_q = next tile's map, fetched in TXT_W0).
            TXT_W1: begin
                // Write pixels 0-7 to line buffer
                // Pixel decode: ascending nibble order per word
                //   px0=w0[3:0], px1=w0[7:4], px2=w0[11:8], px3=w0[15:12]
                //   px4=w1[3:0], px5=w1[7:4], px6=w1[11:8], px7=w1[15:12]
                if (txt_write_x < TEXT_BUF_W[9:0]) begin
                    text_linebuf[9'(txt_write_x + 10'd0)] <= {txt_color, txt_gfx_w0[ 3: 0]};
                    text_linebuf[9'(txt_write_x + 10'd1)] <= {txt_color, txt_gfx_w0[ 7: 4]};
                    text_linebuf[9'(txt_write_x + 10'd2)] <= {txt_color, txt_gfx_w0[11: 8]};
                    text_linebuf[9'(txt_write_x + 10'd3)] <= {txt_color, txt_gfx_w0[15:12]};
                    text_linebuf[9'(txt_write_x + 10'd4)] <= {txt_color, vram_sc_q[ 3: 0]};
                    text_linebuf[9'(txt_write_x + 10'd5)] <= {txt_color, vram_sc_q[ 7: 4]};
                    text_linebuf[9'(txt_write_x + 10'd6)] <= {txt_color, vram_sc_q[11: 8]};
                    text_linebuf[9'(txt_write_x + 10'd7)] <= {txt_color, vram_sc_q[15:12]};
                end
                txt_write_x   <= txt_write_x + 10'd8;
                txt_fetch_col <= txt_fetch_col + 7'd1;

                // Done when active width filled
                if (txt_write_x >= 10'(TEXT_BUF_W) - 10'd8) begin
                    txt_state <= TXT_IDLE;
                end else begin
                    // Loop to MAP: next tile's map data (pre-fetched in W0) is now in vram_tf_q
                    txt_state <= TXT_MAP;
                end
            end

            default: txt_state <= TXT_IDLE;
        endcase
    end
end

// =============================================================================
// SECTION 9: NBG0 Layer — 16×16 tilemap with scroll and page select
// =============================================================================
//
// Architecture:
//   - Tilemap is arranged as four pages in a 2×2 grid (UL/UR/LL/LR).
//   - Each page = 32 columns × 16 rows of 16×16 tiles = 512 entries.
//   - Page VRAM base address (word) = page_num × 512.
//   - Tile entry (16-bit):
//       bit15    = flipY
//       bit14    = flipX
//       bits[13:4] = color (10-bit palette field; bits overlap with tile code)
//       bits[12:0] = tile code (13 bits)
//   - Tile GFX in ROM: 16×16×4bpp = 128 bytes per tile.
//       Byte address = tile_code × 128 + row_within_tile × 8 + word_within_row × 4
//       Each 32-bit gfx_data read = 8 pixels (pixel k = bits[4k+3 : 4k]).
//       Row has 2 × 32-bit reads: word0 = pixels 0-7, word1 = pixels 8-15.
//   - Scroll: reg_nbg0_xscrl[9:0] = X scroll (pixel units, wraps in 512-wide tilespace).
//             reg_nbg0_yscrl[8:0] = Y scroll (pixel units, wraps in 256-high tilespace).
//   - Page layout:
//       src_x_bit9 (x[9]) selects UL/LL vs UR/LR column.
//       src_y_bit8 (y[8]) selects UL/UR vs LL/LR row.
//       Page = {src_y_bit8, src_x_bit9} → 0=UL, 1=UR, 2=LL, 3=LR.
//       UL page = reg_nbg0_page[ 6: 0]
//       UR page = reg_nbg0_page[14: 8]
//       LL page = reg_nbg1_page[ 6: 0]  (NBG0 second word at $1FF44 offset... see note)
//       LR page = reg_nbg1_page[14: 8]
//   NOTE on page register layout (MAME get_tilemaps):
//       vram[0x1ff40/2 + 2*bgnum + 0]: bits[6:0]=UL page, bits[14:8]=UR page
//       vram[0x1ff40/2 + 2*bgnum + 1]: bits[6:0]=LL page, bits[14:8]=LR page
//       For bgnum=0: word 0 = $1FF40 = reg_nbg0_page; word 1 = $1FF42 = reg_nbg1_page
//       For bgnum=1: word 0 = $1FF42 = reg_nbg1_page; word 1 = $1FF44 = reg_nbg2_page
//   So for NBG0: UL/UR from reg_nbg0_page[14:0], LL/LR from reg_nbg1_page[14:0].
//   We reuse the already-decoded reg_nbg1_page for NBG0's lower half pages.
//
// HBLANK FSM (same pattern as TEXT layer):
//   During HBLANK, prefetch tiles for the next scanline into nbg0_linebuf[].
//   Each tile needs 3 GFX ROM reads (1 map + 2 gfx words): 21 tiles × 3 = 63 cycles.
//   GFX ROM shares the single gfx_addr/gfx_data port; NBG0 drives it during HBLANK,
//   NBG1 drives it during the second half of HBLANK after NBG0 finishes.
//   HBLANK is 208 cycles; NBG0 uses ~84 cycles (21 tiles × 4 FSM states), NBG1 the rest.
//
// Output:
//   nbg0_pixel[11:0] = {color[7:0], pen[3:0]}: pen==0 → transparent.
//   nbg0_valid: asserted when pixel is opaque.
// =============================================================================

// NBG0 line buffer: 320 pixels wide (narrow mode), each pixel 12 bits {color[7:0], pen[3:0]}
localparam int NBG_BUF_W = 320;
logic [11:0] nbg0_linebuf [0:NBG_BUF_W-1];
logic [11:0] nbg1_linebuf [0:NBG_BUF_W-1];

// ── NBG page address helpers ─────────────────────────────────────────────────
// Given src_x (10-bit) and src_y (9-bit), compute the VRAM word address of the
// tile map entry for NBG0.
//
//   page_quad = {src_y[8], src_x[9]}  (2 bits → selects one of 4 pages)
//   page_num  = one of [UL, UR, LL, LR]
//   tx_in_page = src_x[8:4]   (5 bits → 0..31, tile X within page)
//   ty_in_page = src_y[7:4]   (4 bits → 0..15, tile Y within page)
//   tile_map_word = page_num × 512 + ty_in_page × 32 + tx_in_page

// ── NBG0 FSM ────────────────────────────────────────────────────────────────
// States:
//   NBG_IDLE   : wait for hblank_rise
//   NBG_MAP    : vram_tf_q = tile map entry; latch color+tile+flip; issue GFX addr word0
//   NBG_GFX0   : gfx_data (registered) = word0 pixels 0-7; issue GFX addr word1; pre-fetch next map
//   NBG_GFX1   : gfx_data (registered) = word1 pixels 8-15; write 16 pixels; advance column

typedef enum logic [1:0] {
    NBG_IDLE = 2'd0,
    NBG_MAP  = 2'd1,
    NBG_GFX0 = 2'd2,
    NBG_GFX1 = 2'd3
} nbg_state_t;

// ── GFX ROM port arbitration ─────────────────────────────────────────────────
// NBG0 and NBG1 time-multiplex the single GFX ROM port.
// NBG0 runs first (states: NBG_IDLE→NBG_GFX1 cycles), NBG1 follows.
// A 1-bit arbiter tracks which layer owns the port.
// Both FSMs latch gfx_data into their own registered sample at the right state.

logic [21:0] nbg0_gfx_addr, nbg1_gfx_addr;
logic        nbg0_gfx_rd,   nbg1_gfx_rd;
logic        nbg_arb;           // 0=NBG0 owns gfx port, 1=NBG1 owns gfx port
logic [31:0] gfx_data_r;        // registered sample of gfx_data (1-cycle latency model)

// GFX port mux
assign gfx_addr = nbg_arb ? nbg1_gfx_addr : nbg0_gfx_addr;
assign gfx_rd   = nbg_arb ? nbg1_gfx_rd   : nbg0_gfx_rd;

// GFX data register — capture gfx_data on every clock (1-cycle ROM latency)
always_ff @(posedge clk) gfx_data_r <= gfx_data;

// ── NBG0 tile-fetch state ────────────────────────────────────────────────────
nbg_state_t nbg0_state;
logic [ 9:0] nbg0_src_x;        // source X coordinate (xscrl + pixel offset), wraps mod 512
logic [ 8:0] nbg0_src_y;        // source Y coordinate (yscrl + vline_next),   wraps mod 256
logic [ 9:0] nbg0_col;          // current tile column being fetched (0..20)
logic [ 9:0] nbg0_write_x;      // write position in linebuf (0..319)
logic [ 7:0] nbg0_color;        // latched color field bits[13:6] from tile entry (8 bits = palette index high byte)
logic [12:0] nbg0_tile_code;    // latched tile code [12:0]
logic        nbg0_flipx;        // latched flipX
logic        nbg0_flipy;        // latched flipY
logic [31:0] nbg0_gfx_w0;       // latched GFX word0 (pixels 0-7)
logic [ 3:0] nbg0_py;           // pixel row within tile (0..15)
logic [ 3:0] nbg0_px_start;     // first pixel offset within tile (due to scroll)

// Page number selection for NBG0
// UL=reg_nbg0_page[6:0], UR=reg_nbg0_page[14:8], LL=reg_nbg1_page[6:0], LR=reg_nbg1_page[14:8]
function automatic logic [6:0] nbg0_page_sel(input logic src_y_b8, input logic src_x_b9);
    case ({src_y_b8, src_x_b9})
        2'b00: return reg_nbg0_page[ 6: 0];  // UL
        2'b01: return reg_nbg0_page[14: 8];  // UR
        2'b10: return reg_nbg1_page[ 6: 0];  // LL
        2'b11: return reg_nbg1_page[14: 8];  // LR
    endcase
endfunction

// VRAM word address for NBG0 tile map entry at (src_x, src_y)
// page_base = page_num * 512; tile_offset = ty*32 + tx
function automatic logic [15:0] nbg0_tmap_word(input logic [9:0] sx, input logic [8:0] sy);
    logic [6:0]  pg;
    logic [4:0]  tx;
    logic [3:0]  ty;
    logic [15:0] base, off;
    pg   = nbg0_page_sel(sy[8], sx[9]);
    tx   = sx[8:4];
    ty   = sy[7:4];
    base = {pg, 9'b0};                             // pg * 512
    off  = {7'b0, ty, 5'b0} + {11'b0, tx};        // ty*32 + tx
    return base + off;
endfunction

// GFX ROM byte address for an NBG0/NBG1 tile pixel row:
//   byte_addr = tile_code * 128 + row * 8 + widx * 4
//   gfx_addr is 22-bit byte address; module expects byte address.
function automatic logic [21:0] nbg0_gfx_byte(
    input logic [12:0] tc, input logic [3:0] row, input logic widx);
    logic [21:0] base22, row22, widx22;
    base22 = {tc, 9'b0};                           // tc * 128  (13+9=22)
    row22  = {15'b0, row, 3'b0};                   // row * 8   (15+4+3=22)
    widx22 = {19'b0, widx, 2'b0};                  // widx * 4  (19+1+2=22)
    return base22 + row22 + widx22;
endfunction

// ── NBG0 FSM ─────────────────────────────────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        nbg0_state     <= NBG_IDLE;
        nbg0_src_x     <= '0;
        nbg0_src_y     <= '0;
        nbg0_col       <= '0;
        nbg0_write_x   <= '0;
        nbg0_color     <= '0;
        nbg0_tile_code <= '0;
        nbg0_flipx     <= 1'b0;
        nbg0_flipy     <= 1'b0;
        nbg0_gfx_w0    <= '0;
        nbg0_py        <= '0;
        nbg0_px_start  <= '0;
        nbg0_gfx_addr  <= '0;
        nbg0_gfx_rd    <= 1'b0;
        nbg_arb        <= 1'b0;
        vram_n0_addr   <= '0;
        for (int i = 0; i < NBG_BUF_W; i++) nbg0_linebuf[i] <= 12'h000;
    end else begin
        nbg0_gfx_rd <= 1'b0;

        case (nbg0_state)
            // ─── IDLE ───────────────────────────────────────────────────────
            // Wait for hblank_rise. Capture scroll geometry; issue first map read.
            NBG_IDLE: begin
                nbg_arb <= 1'b0;  // NBG0 owns GFX port during its fetch
                if (hblank_rise) begin
                    // Source Y for the line we're about to fill (next display line)
                    nbg0_src_y   <= 9'(vline_next[7:0]) + reg_nbg0_yscrl[8:0];
                    nbg0_py      <= 4'(vline_next[3:0]) + reg_nbg0_yscrl[3:0];
                    // Source X start: xscrl gives the pixel at screen X=0
                    nbg0_src_x   <= 10'(reg_nbg0_xscrl[9:0]);
                    nbg0_px_start <= reg_nbg0_xscrl[3:0];  // pixel offset within first tile
                    nbg0_col     <= '0;
                    nbg0_write_x <= '0;
                    // Issue first map read immediately (uses dedicated NBG0 VRAM port)
                    vram_n0_addr  <= nbg0_tmap_word(reg_nbg0_xscrl[9:0],
                                                     9'(vline_next[7:0]) + reg_nbg0_yscrl[8:0]);
                    nbg0_state   <= NBG_MAP;
                end
            end

            // ─── MAP ────────────────────────────────────────────────────────
            // vram_n0_q = tile map entry. Latch color+tile+flip.
            // Issue GFX ROM address for pixel row word 0.
            NBG_MAP: begin
                // Latch tile attributes from map word (vram_n0_q is combinational)
                nbg0_flipy     <= vram_n0_q[15];
                nbg0_flipx     <= vram_n0_q[14];
                nbg0_color     <= vram_n0_q[13:6];   // 8-bit palette select field
                nbg0_tile_code <= vram_n0_q[12:0];
                // Issue GFX word0 read: pixel row adjusted for flipY
                begin
                    logic [3:0] eff_py;
                    eff_py = vram_n0_q[15] ? (4'd15 - nbg0_py) : nbg0_py;
                    nbg0_gfx_addr <= nbg0_gfx_byte(vram_n0_q[12:0], eff_py, 1'b0);
                    nbg0_gfx_rd   <= 1'b1;
                end
                nbg0_state <= NBG_GFX0;
            end

            // ─── GFX0 ───────────────────────────────────────────────────────
            // gfx_data_r = word0 (pixels 0-7). Latch it.
            // Issue GFX word1 address.
            // Pre-fetch next tile's map address.
            NBG_GFX0: begin
                nbg0_gfx_w0 <= gfx_data_r;  // pixels 0-7 of this tile row
                // Issue word1 address
                begin
                    logic [3:0] eff_py;
                    eff_py = nbg0_flipy ? (4'd15 - nbg0_py) : nbg0_py;
                    nbg0_gfx_addr <= nbg0_gfx_byte(nbg0_tile_code, eff_py, 1'b1);
                    nbg0_gfx_rd   <= 1'b1;
                end
                // Pre-fetch next tile map address (pipeline, NBG0 dedicated port)
                begin
                    logic [9:0] next_sx;
                    next_sx = nbg0_src_x + 10'd16;
                    vram_n0_addr <= nbg0_tmap_word(next_sx, nbg0_src_y);
                end
                nbg0_state <= NBG_GFX1;
            end

            // ─── GFX1 ───────────────────────────────────────────────────────
            // gfx_data_r = word1 (pixels 8-15). Write 16 pixels to linebuf.
            // Advance column; loop to MAP or back to IDLE.
            NBG_GFX1: begin
                // Write 16 pixels: handle flipX and px_start clipping
                // w0 = pixels 0-7, gfx_data_r = pixels 8-15
                // Each pixel = 4 bits in 32-bit word: pixel k = bits[4k+3:4k]
                // flipX reverses pixel order within the 16-pixel tile.
                begin
                    logic [3:0] px [0:15];
                    int wx, src_k, pstart;
                    pstart = int'(nbg0_px_start);
                    // Extract 16 pixels (not yet flipped)
                    for (int k = 0; k < 8; k++) begin
                        px[k]   = nbg0_gfx_w0[k*4 +: 4];
                        px[k+8] = gfx_data_r[k*4 +: 4];
                    end
                    // Write pixels to linebuf, applying flipX and px_start
                    for (int k = 0; k < 16; k++) begin
                        wx = int'(nbg0_write_x) + k - pstart;
                        if (wx >= 0 && wx < NBG_BUF_W) begin
                            src_k = nbg0_flipx ? (15 - k) : k;
                            nbg0_linebuf[wx] <= {nbg0_color, px[src_k]};
                        end
                    end
                end
                nbg0_write_x <= nbg0_write_x + 10'd16 - {6'b0, nbg0_px_start};
                nbg0_src_x   <= nbg0_src_x + 10'd16;
                nbg0_col     <= nbg0_col + 10'd1;
                nbg0_px_start <= 4'd0;  // only first tile has a fractional start

                // Done when we've filled the line buffer
                if (int'(nbg0_write_x) + 16 - int'(nbg0_px_start) >= NBG_BUF_W) begin
                    nbg_arb    <= 1'b1;  // hand GFX port to NBG1
                    nbg0_state <= NBG_IDLE;
                end else begin
                    nbg0_state <= NBG_MAP;
                end
            end

            default: nbg0_state <= NBG_IDLE;
        endcase
    end
end

// Read from NBG0 line buffer during active display
logic [11:0] nbg0_px_now;
assign nbg0_px_now = nbg0_linebuf[hpos[8:0]];

logic [11:0] nbg0_pixel;
logic        nbg0_valid;
assign nbg0_pixel = nbg0_px_now;
assign nbg0_valid = (nbg0_px_now[3:0] != 4'h0);   // pen==0 → transparent

// =============================================================================
// SECTION 10: NBG1 Layer — 16×16 tilemap with scroll and page select
// =============================================================================
//
// Same architecture as NBG0. Registers:
//   reg_nbg1_page    ($1FF42): UL[6:0], UR[14:8] — NBG1's UL/UR
//   reg_nbg2_page    ($1FF44): LL[6:0], LR[14:8] — NBG1's LL/LR (bgnum=1 → word1)
//   reg_nbg1_xscrl   ($1FF1A), reg_nbg1_yscrl ($1FF1E)
//
// NBG1 runs its HBLANK FSM AFTER NBG0 completes (nbg_arb==1).
// =============================================================================

// NBG1 tile-fetch state
nbg_state_t nbg1_state;
logic [ 9:0] nbg1_src_x;
logic [ 8:0] nbg1_src_y;
logic [ 9:0] nbg1_col;
logic [ 9:0] nbg1_write_x;
logic [ 7:0] nbg1_color;        // latched color field bits[13:6]
logic [12:0] nbg1_tile_code;
logic        nbg1_flipx;
logic        nbg1_flipy;
logic [31:0] nbg1_gfx_w0;
logic [ 3:0] nbg1_py;
logic [ 3:0] nbg1_px_start;

// NBG1 page selection: UL/UR from reg_nbg1_page, LL/LR from reg_nbg2_page
function automatic logic [6:0] nbg1_page_sel(input logic src_y_b8, input logic src_x_b9);
    case ({src_y_b8, src_x_b9})
        2'b00: return reg_nbg1_page[ 6: 0];
        2'b01: return reg_nbg1_page[14: 8];
        2'b10: return reg_nbg2_page[ 6: 0];
        2'b11: return reg_nbg2_page[14: 8];
    endcase
endfunction

function automatic logic [15:0] nbg1_tmap_word(input logic [9:0] sx, input logic [8:0] sy);
    logic [6:0]  pg;
    logic [4:0]  tx;
    logic [3:0]  ty;
    logic [15:0] base, off;
    pg   = nbg1_page_sel(sy[8], sx[9]);
    tx   = sx[8:4];
    ty   = sy[7:4];
    base = {pg, 9'b0};
    off  = {7'b0, ty, 5'b0} + {11'b0, tx};
    return base + off;
endfunction

function automatic logic [21:0] nbg1_gfx_byte(
    input logic [12:0] tc, input logic [3:0] row, input logic widx);
    logic [21:0] base22, row22, widx22;
    base22 = {tc, 9'b0};
    row22  = {15'b0, row, 3'b0};
    widx22 = {19'b0, widx, 2'b0};
    return base22 + row22 + widx22;
endfunction

// NBG1 uses dedicated vram_n1 port for map reads
// The vram_sc port is shared with TEXT gfx. NBG1 map reads happen during HBLANK
// after TEXT has finished (NBG1 only fetches map, GFX comes from ROM).
// vram_sc_addr is driven: TEXT uses it in states TXT_MAP/TXT_W0/TXT_W1.
// NBG1 uses it only during NBG_MAP/NBG_GFX0 states when TEXT is in TXT_IDLE.
// In practice TEXT finishes well before NBG1 starts.

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        nbg1_state     <= NBG_IDLE;
        nbg1_src_x     <= '0;
        nbg1_src_y     <= '0;
        nbg1_col       <= '0;
        nbg1_write_x   <= '0;
        nbg1_color     <= '0;
        nbg1_tile_code <= '0;
        nbg1_flipx     <= 1'b0;
        nbg1_flipy     <= 1'b0;
        nbg1_gfx_w0    <= '0;
        nbg1_py        <= '0;
        nbg1_px_start  <= '0;
        nbg1_gfx_addr  <= '0;
        nbg1_gfx_rd    <= 1'b0;
        vram_n1_addr   <= '0;
        for (int i = 0; i < NBG_BUF_W; i++) nbg1_linebuf[i] <= 12'h000;
    end else begin
        nbg1_gfx_rd <= 1'b0;

        case (nbg1_state)
            NBG_IDLE: begin
                // Start NBG1 fetch when NBG0 has handed off the GFX port (nbg_arb==1)
                // and we're still in HBLANK.
                if (nbg_arb && hblank) begin
                    nbg1_src_y   <= 9'(vline_next[7:0]) + reg_nbg1_yscrl[8:0];
                    nbg1_py      <= 4'(vline_next[3:0]) + reg_nbg1_yscrl[3:0];
                    nbg1_src_x   <= 10'(reg_nbg1_xscrl[9:0]);
                    nbg1_px_start <= reg_nbg1_xscrl[3:0];
                    nbg1_col     <= '0;
                    nbg1_write_x <= '0;
                    // Issue first map read via dedicated NBG1 VRAM port
                    vram_n1_addr <= nbg1_tmap_word(reg_nbg1_xscrl[9:0],
                                                    9'(vline_next[7:0]) + reg_nbg1_yscrl[8:0]);
                    nbg1_state   <= NBG_MAP;
                end
            end

            NBG_MAP: begin
                nbg1_flipy     <= vram_n1_q[15];
                nbg1_flipx     <= vram_n1_q[14];
                nbg1_color     <= vram_n1_q[13:6];   // 8-bit palette select field
                nbg1_tile_code <= vram_n1_q[12:0];
                begin
                    logic [3:0] eff_py;
                    eff_py = vram_n1_q[15] ? (4'd15 - nbg1_py) : nbg1_py;
                    nbg1_gfx_addr <= nbg1_gfx_byte(vram_n1_q[12:0], eff_py, 1'b0);
                    nbg1_gfx_rd   <= 1'b1;
                end
                nbg1_state <= NBG_GFX0;
            end

            NBG_GFX0: begin
                nbg1_gfx_w0 <= gfx_data_r;
                begin
                    logic [3:0] eff_py;
                    eff_py = nbg1_flipy ? (4'd15 - nbg1_py) : nbg1_py;
                    nbg1_gfx_addr <= nbg1_gfx_byte(nbg1_tile_code, eff_py, 1'b1);
                    nbg1_gfx_rd   <= 1'b1;
                end
                // Pre-fetch next tile map via dedicated NBG1 VRAM port
                begin
                    logic [9:0] next_sx;
                    next_sx = nbg1_src_x + 10'd16;
                    vram_n1_addr <= nbg1_tmap_word(next_sx, nbg1_src_y);
                end
                nbg1_state <= NBG_GFX1;
            end

            NBG_GFX1: begin
                begin
                    logic [3:0] px [0:15];
                    int wx, src_k, pstart;
                    pstart = int'(nbg1_px_start);
                    for (int k = 0; k < 8; k++) begin
                        px[k]   = nbg1_gfx_w0[k*4 +: 4];
                        px[k+8] = gfx_data_r[k*4 +: 4];
                    end
                    for (int k = 0; k < 16; k++) begin
                        wx = int'(nbg1_write_x) + k - pstart;
                        if (wx >= 0 && wx < NBG_BUF_W) begin
                            src_k = nbg1_flipx ? (15 - k) : k;
                            nbg1_linebuf[wx] <= {nbg1_color, px[src_k]};
                        end
                    end
                end
                nbg1_write_x <= nbg1_write_x + 10'd16 - {6'b0, nbg1_px_start};
                nbg1_src_x   <= nbg1_src_x + 10'd16;
                nbg1_col     <= nbg1_col + 10'd1;
                nbg1_px_start <= 4'd0;

                if (int'(nbg1_write_x) + 16 - int'(nbg1_px_start) >= NBG_BUF_W) begin
                    nbg_arb    <= 1'b0;  // return GFX port to NBG0 for next line
                    nbg1_state <= NBG_IDLE;
                end else begin
                    nbg1_state <= NBG_MAP;
                end
            end

            default: nbg1_state <= NBG_IDLE;
        endcase
    end
end

// Read from NBG1 line buffer during active display
logic [11:0] nbg1_px_now;
assign nbg1_px_now = nbg1_linebuf[hpos[8:0]];

logic [11:0] nbg1_pixel;
logic        nbg1_valid;
assign nbg1_pixel = nbg1_px_now;
assign nbg1_valid = (nbg1_px_now[3:0] != 4'h0);

// =============================================================================
// SECTION 11: NBG2 Layer (stub — rowscroll)
// =============================================================================
// MAME segas32_v.cpp update_tilemap_rowscroll(): rowscroll table in VRAM.
// Table page: reg_rowscrl_ctrl bits[15:12] (NBG2) and [11:8] (NBG3).
// rowselect mode replaces Y per scanline from table.
// =============================================================================
logic [11:0] nbg2_pixel;
logic        nbg2_valid;
assign nbg2_pixel = 12'h000;
assign nbg2_valid = 1'b0;

// =============================================================================
// SECTION 12: NBG3 Layer (stub — rowscroll)
// =============================================================================
logic [11:0] nbg3_pixel;
logic        nbg3_valid;
assign nbg3_pixel = 12'h000;
assign nbg3_valid = 1'b0;

// =============================================================================
// SECTION 13: Sprite Engine
// =============================================================================
//
// Architecture Overview:
//   System 32 sprites are stored in double-buffered sprite RAM ($400000).
//   CPU writes into one buffer while the video engine reads the other.
//   Each sprite entry is 8 × 16-bit words (16 bytes):
//
//     +0  cmd/flags:  bits[15:14]=type (00=draw,01=clip,10=jump,11=end)
//                     bit[9]=8bpp, bit[7]=flipY, bit[6]=flipX
//                     bits[5:4]=Y-align, bits[3:2]=X-align (00=center,10=start,01=end)
//     +1  src_h[15:8], src_w[7:0]    (source tile dimensions in pixels)
//     +2  dst_h[9:0]                 (onscreen height after zoom)
//     +3  dst_w[9:0]                 (onscreen width  after zoom)
//     +4  Y position (signed 12-bit)
//     +5  X position (signed 12-bit)
//     +6  GFX offset (word address of pixel data within sprite RAM)
//     +7  palette[15:4], priority[3:0]
//
// Sprite pixel data lives in sprite RAM at the word offset given by word[6].
// Format: 4bpp, packed as 4 pixels per 16-bit word:
//   px0=bits[3:0], px1=bits[7:4], px2=bits[11:8], px3=bits[15:12]
//   Row r, group g: word address = gfx_offset + r * words_per_row + g
//   where words_per_row = ceil(src_w / 4).
//
// Line buffer format: spr_linebuf[x] = {prio[3:0], color[7:0], pen[3:0]} = 16 bits
//   color = palette[15:8] (top 8 bits of the 12-bit palette field from word 7)
//   pen   = 4-bit nibble from GFX data (0 = transparent)
//   prio  = priority group [3:0] from sprite entry word 7
//
// Rendering pipeline:
//
//   Phase 1 — VBLANK scan (VSCAN FSM):
//     Runs during vblank. Scans up to SPR_MAX entries in sprite RAM.
//     For each draw-type sprite that intersects active scanlines, records
//     (entry_index, dy_within_sprite) into a per-line sprite table.
//     Table: spr_table[line][slot] = {entry_idx[7:0], sdy[7:0]}, 16 bits.
//     spr_table_cnt[line] = number of filled slots.
//
//   Phase 2 — HBLANK render (SRR FSM):
//     Runs each HBLANK. Reads sprite attributes from sprite RAM,
//     fetches GFX words, and writes pixels into spr_linebuf[].
//
//   Phase 3 — Active display readout:
//     Combinational: spr_pixel = spr_linebuf[hpos][11:0],
//                    spr_prio  = spr_linebuf[hpos][15:12].
//     Rolling clear: spr_linebuf[hpos] ← 0 during active display
//                    (clears each location right after it has been read,
//                     preparing it for the next scanline's render).
//
// Cycle budgets:
//   VBLANK = 38 lines × 528 px = 20,064 cycles.
//   VSCAN:  224 clear + 128 sprites × 10 states = 1,504 cycles. ✓
//   HBLANK = 208 cycles.
//   SRR:    8 sprites × (6 attr reads + 4 gfx reads) = 80 cycles. ✓
//
// =============================================================================

// ── Sprite engine parameters ─────────────────────────────────────────────────
localparam int SPR_MAX      = 128;      // max sprites scanned per frame
localparam int SPR_PER_LINE = 8;        // max sprites rendered per scanline
localparam int SPR_LINES    = 224;      // active display lines
localparam int SPR_BUF_W    = 416;      // sprite line buffer width (max)

// ── Sprite line buffer ────────────────────────────────────────────────────────
// {prio[3:0], color[7:0], pen[3:0]} = 16 bits per pixel
// pen==0 → transparent.
logic [15:0] spr_linebuf [0:SPR_BUF_W-1];

// ── Per-line sprite table ─────────────────────────────────────────────────────
// spr_table[line][slot] = {entry_idx[7:0], sdy[7:0]}
// entry_idx: sprite entry number (0..SPR_MAX-1)
// sdy:       pixel row within sprite (0 = top row)
logic [15:0] spr_table [0:SPR_LINES-1][0:SPR_PER_LINE-1];
logic [ 3:0] spr_table_cnt [0:SPR_LINES-1];

// ── Sprite RAM video-read port ────────────────────────────────────────────────
// Combinational read — no latency, same as VRAM combinational ports.
// vscan_addr: driven by VSCAN FSM (active during vblank)
// srr_addr:   driven by SRR FSM (active during active-display HBLANKs)
// sprvid_addr: muxed combinationally based on vblank state
logic [15:0] vscan_addr;
logic [15:0] srr_addr;
logic [15:0] sprvid_addr;
logic [15:0] sprvid_q;
assign sprvid_addr = vblank ? vscan_addr : srr_addr;
assign sprvid_q    = spriteram[sprvid_addr];

// ── Buffer select ─────────────────────────────────────────────────────────────
// spr_ctrl[0][0]: 0=buffer A (word base 0x0000), 1=buffer B (word base 0x2000)
// Each sprite entry = 8 words; entry n starts at word (base + n*8).
logic        spr_buf_sel;
logic [15:0] spr_list_base;
assign spr_buf_sel  = spr_ctrl[0][0];
assign spr_list_base = spr_buf_sel ? 16'h2000 : 16'h0000;

// ── Phase 1 FSM: VBLANK sprite scanner ───────────────────────────────────────

typedef enum logic [3:0] {
    VSCAN_IDLE  = 4'd0,
    VSCAN_CLEAR = 4'd1,
    VSCAN_LOAD0 = 4'd2,
    VSCAN_LOAD1 = 4'd3,
    VSCAN_LOAD2 = 4'd4,
    VSCAN_LOAD3 = 4'd5,
    VSCAN_LOAD4 = 4'd6,
    VSCAN_LOAD5 = 4'd7,
    VSCAN_LOAD6 = 4'd8,
    VSCAN_LOAD7 = 4'd9,
    VSCAN_PROC  = 4'd10,
    VSCAN_NEXT  = 4'd11
} vscan_state_t;

vscan_state_t vscan_state;

// Latched sprite attributes during VSCAN
logic [15:0] vs_cmd;
logic [ 7:0] vs_srch;
logic [ 7:0] vs_srcw;
logic [ 9:0] vs_dsth;
logic [ 9:0] vs_dstw;
logic [15:0] vs_ypos_raw;
logic [15:0] vs_xpos_raw;
logic [15:0] vs_gfxoff;
logic [15:0] vs_palp;
logic [ 7:0] vscan_entry;
logic [ 7:0] vscan_clear;

// Vblank rise detection for VSCAN trigger
logic vblank_rise_r;
logic vscan_vblank_rise;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) vblank_rise_r <= 1'b0;
    else        vblank_rise_r <= vblank;
end
assign vscan_vblank_rise = ~vblank_rise_r & vblank;

// VSCAN FSM
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        vscan_state  <= VSCAN_IDLE;
        vscan_entry  <= 8'd0;
        vscan_clear  <= 8'd0;
        vs_cmd       <= 16'h0000;
        vs_srch      <= 8'd0;
        vs_srcw      <= 8'd0;
        vs_dsth      <= 10'd0;
        vs_dstw      <= 10'd0;
        vs_ypos_raw  <= 16'h0000;
        vs_xpos_raw  <= 16'h0000;
        vs_gfxoff    <= 16'h0000;
        vs_palp      <= 16'h0000;
        vscan_addr   <= 16'h0000;
        for (int l = 0; l < SPR_LINES; l++) begin
            spr_table_cnt[l] <= 4'd0;
            for (int s = 0; s < SPR_PER_LINE; s++)
                spr_table[l][s] <= 16'd0;
        end
    end else begin
        case (vscan_state)

            VSCAN_IDLE: begin
                if (vscan_vblank_rise) begin
                    vscan_clear <= 8'd0;
                    vscan_state <= VSCAN_CLEAR;
                end
            end

            // Clear spr_table_cnt[0..223], one per cycle
            VSCAN_CLEAR: begin
                spr_table_cnt[vscan_clear] <= 4'd0;
                if (vscan_clear == 8'(SPR_LINES - 1)) begin
                    vscan_entry <= 8'd0;
                    vscan_addr <= spr_list_base;   // word 0 of entry 0
                    vscan_state <= VSCAN_LOAD0;
                end else begin
                    vscan_clear <= vscan_clear + 8'd1;
                end
            end

            // Read sprite words sequentially (combinational SPRAM, no latency):
            // Each state issues the NEXT address and latches the CURRENT sprvid_q.
            VSCAN_LOAD0: begin
                vs_cmd      <= sprvid_q;
                vscan_addr <= spr_list_base | 16'({vscan_entry, 3'b001});
                vscan_state <= VSCAN_LOAD1;
            end

            VSCAN_LOAD1: begin
                vs_srch     <= sprvid_q[15:8];
                vs_srcw     <= sprvid_q[7:0];
                vscan_addr <= spr_list_base | 16'({vscan_entry, 3'b010});
                vscan_state <= VSCAN_LOAD2;
            end

            VSCAN_LOAD2: begin
                vs_dsth     <= sprvid_q[9:0];
                vscan_addr <= spr_list_base | 16'({vscan_entry, 3'b011});
                vscan_state <= VSCAN_LOAD3;
            end

            VSCAN_LOAD3: begin
                vs_dstw     <= sprvid_q[9:0];
                vscan_addr <= spr_list_base | 16'({vscan_entry, 3'b100});
                vscan_state <= VSCAN_LOAD4;
            end

            VSCAN_LOAD4: begin
                vs_ypos_raw <= sprvid_q;
                vscan_addr <= spr_list_base | 16'({vscan_entry, 3'b101});
                vscan_state <= VSCAN_LOAD5;
            end

            VSCAN_LOAD5: begin
                vs_xpos_raw <= sprvid_q;
                vscan_addr <= spr_list_base | 16'({vscan_entry, 3'b110});
                vscan_state <= VSCAN_LOAD6;
            end

            VSCAN_LOAD6: begin
                vs_gfxoff   <= sprvid_q;
                vscan_addr <= spr_list_base | 16'({vscan_entry, 3'b111});
                vscan_state <= VSCAN_LOAD7;
            end

            VSCAN_LOAD7: begin
                vs_palp     <= sprvid_q;
                vscan_state <= VSCAN_PROC;
            end

            // Process sprite: if draw-type, populate per-line table
            VSCAN_PROC: begin
                if (vs_cmd[15:14] == 2'b11) begin
                    // END of list
                    vscan_state <= VSCAN_IDLE;
                end else if (vs_cmd[15:14] == 2'b00) begin
                    // DRAW sprite
                    begin
                        logic signed [11:0] sy;
                        logic [9:0]  eff_h;
                        int          y_top, y_bot;

                        sy    = vs_ypos_raw[11:0];
                        eff_h = (vs_dsth == 10'd0) ? 10'd16 : vs_dsth;

                        // Y alignment (bits[5:4])
                        case (vs_cmd[5:4])
                            2'b00: y_top = int'($signed(sy)) - int'(eff_h) / 2;
                            2'b01: y_top = int'($signed(sy)) - int'(eff_h) + 1;
                            default: y_top = int'($signed(sy));
                        endcase

                        y_bot = y_top + int'(eff_h) - 1;

                        // Clamp to active display
                        if (y_top < 0)          y_top = 0;
                        if (y_bot >= SPR_LINES)  y_bot = SPR_LINES - 1;

                        // Insert into per-line table
                        for (int l = 0; l < SPR_LINES; l++) begin
                            if (l >= y_top && l <= y_bot) begin
                                int sdy_top;
                                case (vs_cmd[5:4])
                                    2'b00: sdy_top = int'($signed(sy)) - int'(eff_h)/2;
                                    2'b01: sdy_top = int'($signed(sy)) - int'(eff_h)+1;
                                    default: sdy_top = int'($signed(sy));
                                endcase
                                begin
                                    int sdy_v;
                                    sdy_v = l - sdy_top;
                                    if (sdy_v < 0) sdy_v = 0;
                                    if (spr_table_cnt[l] < 4'(SPR_PER_LINE)) begin
                                        spr_table[l][3'(spr_table_cnt[l])] <=
                                            {vscan_entry, 8'(sdy_v)};
                                        spr_table_cnt[l] <=
                                            spr_table_cnt[l] + 4'd1;
                                    end
                                end
                            end
                        end
                    end
                    vscan_state <= VSCAN_NEXT;
                end else begin
                    // CLIP or JUMP — skip
                    vscan_state <= VSCAN_NEXT;
                end
            end

            VSCAN_NEXT: begin
                if (vscan_entry == 8'(SPR_MAX - 1)) begin
                    vscan_state <= VSCAN_IDLE;
                end else begin
                    vscan_entry <= vscan_entry + 8'd1;
                    vscan_addr <= spr_list_base |
                                   16'({(vscan_entry + 8'd1), 3'b000});
                    vscan_state <= VSCAN_LOAD0;
                end
            end

            default: vscan_state <= VSCAN_IDLE;
        endcase
    end
end

// ── Phase 2 FSM: HBLANK sprite renderer ──────────────────────────────────────
//
// HBLANK = 208 cycles. We process up to SPR_PER_LINE sprites per line.
// Each sprite: 6 attribute reads + N GFX word reads (N = ceil(dstw/4) ≤ 4 for 16px).
// Total: 8 × (6 + 4) = 80 cycles comfortably fits.
//
// VSCAN and SRR both use sprvid_addr/sprvid_q. They don't overlap:
//   VSCAN runs during vblank (vpos >= 224).
//   SRR   runs during hblank of active lines (vpos < 224).
// So the two FSMs are mutually exclusive in time.
//
// Line buffer management:
//   The sprite line buffer must be cleared before each line's render.
//   We run a parallel clear counter (spr_clr_ctr) during every HBLANK that
//   increments once per cycle, clearing spr_linebuf[0..H_ACTIVE-1].
//   Sprite pixel writes take priority over clear writes in the same cycle.
//   Both the clear counter and sprite pixel writes are in a single always_ff
//   block, so no multi-drive issues.

typedef enum logic [3:0] {
    SRR_IDLE  = 4'd0,
    SRR_ATTR0 = 4'd1,    // sprvid_q = word 0 (cmd/flags) — already issued by IDLE/NEXT
    SRR_ATTR1 = 4'd2,    // sprvid_q = word 1 (src_h, src_w); latch cmd
    SRR_ATTR2 = 4'd3,    // sprvid_q = word 3 (dst_w); latch src
    SRR_ATTR3 = 4'd4,    // sprvid_q = word 5 (X pos); latch dst_w
    SRR_ATTR4 = 4'd5,    // sprvid_q = word 6 (gfx off); latch X
    SRR_ATTR5 = 4'd6,    // sprvid_q = word 7 (pal/prio); latch gfx; issue 1st GFX read
    SRR_PIXRD = 4'd7,    // sprvid_q = GFX word; write 4 pixels; loop or advance
    SRR_NEXT  = 4'd8,    // advance to next slot
    SRR_VCLR  = 4'd9     // VBLANK clear: zero spr_linebuf[0..H_ACTIVE-1]
} srr_state_t;

// Clear counter for SRR_VCLR state
logic [9:0] spr_clr_ctr;

srr_state_t srr_state;

// Latched sprite render attributes
logic [15:0] sr_cmd;
logic [ 7:0] sr_srcw;
logic [ 9:0] sr_dstw;
logic [11:0] sr_xpos;       // signed 12-bit
logic [15:0] sr_gfxoff;
logic [ 7:0] sr_color;      // palette[15:8] from word 7
logic [ 3:0] sr_prio;
logic [ 7:0] sr_sdy;        // pixel row within sprite for this scanline

// Render progress counters
logic [ 3:0] srr_slot;
logic [ 8:0] srr_px;        // pixel group index (advances by 4 per GFX word)
logic [ 8:0] srr_eff_dstw;  // effective dst width
logic [ 8:0] srr_wpr;       // words per GFX row = ceil(src_w / 4)
logic [ 7:0] srr_cur_line;  // scanline being rendered

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        srr_state    <= SRR_IDLE;
        srr_slot     <= 4'd0;
        srr_px       <= 9'd0;
        srr_eff_dstw <= 9'd16;
        srr_wpr      <= 9'd4;
        srr_cur_line <= 8'd0;
        sr_cmd       <= 16'h0000;
        sr_srcw      <= 8'd16;
        sr_dstw      <= 10'd0;
        sr_xpos      <= 12'd0;
        sr_gfxoff    <= 16'h0000;
        sr_color     <= 8'd0;
        sr_prio      <= 4'h0;
        sr_sdy       <= 8'd0;
        spr_clr_ctr  <= 10'd0;
        srr_addr     <= 16'h0000;
        for (int i = 0; i < SPR_BUF_W; i++) spr_linebuf[i] <= 16'h0000;
    end else begin

        // ── SRR FSM ────────────────────────────────────────────────────────
        case (srr_state)

            SRR_IDLE: begin
                // Trigger VBLANK clear at start of vblank
                if (vscan_vblank_rise) begin
                    spr_clr_ctr <= 10'd0;
                    srr_state   <= SRR_VCLR;
                end else if (hblank_rise && (vline_next < 9'(V_ACTIVE))) begin
                    srr_cur_line <= vline_next[7:0];
                    srr_slot     <= 4'd0;
                    if (spr_table_cnt[vline_next[7:0]] > 4'd0) begin
                        // Issue word 0 read for slot 0
                        begin
                            logic [7:0] eidx;
                            eidx = spr_table[vline_next[7:0]][0][15:8];
                            sr_sdy      <= spr_table[vline_next[7:0]][0][7:0];
                            srr_addr <= spr_list_base | 16'({eidx, 3'b000});
                        end
                        srr_state <= SRR_ATTR0;
                    end
                end
            end

            // Clear linebuf[0..H_ACTIVE-1] during VBLANK (one entry per cycle)
            SRR_VCLR: begin
                spr_linebuf[9'(spr_clr_ctr)] <= 16'h0000;
                if (spr_clr_ctr == 10'(H_ACTIVE - 1)) begin
                    srr_state <= SRR_IDLE;
                end else begin
                    spr_clr_ctr <= spr_clr_ctr + 10'd1;
                end
            end

            // sprvid_q = word 0; latch cmd; issue word 1
            SRR_ATTR0: begin
                sr_cmd      <= sprvid_q;
                srr_addr <= spr_list_base |
                               16'({spr_table[srr_cur_line][3'(srr_slot)][15:8], 3'b001});
                srr_state   <= SRR_ATTR1;
            end

            // sprvid_q = word 1 (src_h[15:8], src_w[7:0]); latch; issue word 3
            SRR_ATTR1: begin
                sr_srcw     <= sprvid_q[7:0];
                srr_addr <= spr_list_base |
                               16'({spr_table[srr_cur_line][3'(srr_slot)][15:8], 3'b011});
                srr_state   <= SRR_ATTR2;
            end

            // sprvid_q = word 3 (dst_w); latch; issue word 5
            SRR_ATTR2: begin
                sr_dstw     <= sprvid_q[9:0];
                srr_addr <= spr_list_base |
                               16'({spr_table[srr_cur_line][3'(srr_slot)][15:8], 3'b101});
                srr_state   <= SRR_ATTR3;
            end

            // sprvid_q = word 5 (X pos); latch; issue word 6
            SRR_ATTR3: begin
                sr_xpos     <= sprvid_q[11:0];
                srr_addr <= spr_list_base |
                               16'({spr_table[srr_cur_line][3'(srr_slot)][15:8], 3'b110});
                srr_state   <= SRR_ATTR4;
            end

            // sprvid_q = word 6 (gfx offset); latch; issue word 7
            SRR_ATTR4: begin
                sr_gfxoff   <= sprvid_q;
                srr_addr <= spr_list_base |
                               16'({spr_table[srr_cur_line][3'(srr_slot)][15:8], 3'b111});
                srr_state   <= SRR_ATTR5;
            end

            // sprvid_q = word 7 (palette/prio); latch; compute dims; issue 1st GFX word
            SRR_ATTR5: begin
                sr_color    <= sprvid_q[15:8];  // top 8 bits of palette field
                sr_prio     <= sprvid_q[3:0];

                begin
                    logic [8:0] ew;
                    logic [7:0] sw;
                    logic [8:0] wpr;
                    logic [15:0] gfx0;

                    ew  = (sr_dstw == 10'd0) ? 9'd16 : 9'(sr_dstw);
                    sw  = (sr_srcw == 8'd0)  ? 8'd16 : sr_srcw;
                    wpr = 9'({1'b0, sw[7:2]} + (sw[1:0] != 2'b00 ? 9'd1 : 9'd0));

                    srr_eff_dstw <= ew;
                    srr_wpr      <= wpr;
                    srr_px       <= 9'd0;

                    // GFX word 0 address = gfx_offset + sdy * wpr
                    // Note: sr_gfxoff is still the old value at NBA time;
                    // use sprvid_q directly for the gfx offset (latched this cycle)
                    gfx0 = sprvid_q + 16'(sr_sdy) * 16'(wpr[7:0]);
                    srr_addr <= gfx0;
                end
                srr_state <= SRR_PIXRD;
            end

            // sprvid_q = current GFX word; write up to 4 pixels; loop or advance
            SRR_PIXRD: begin
                begin
                    logic [3:0] pen [0:3];
                    logic       flipx;
                    int         x_left;

                    flipx  = sr_cmd[6];
                    pen[0] = sprvid_q[ 3: 0];
                    pen[1] = sprvid_q[ 7: 4];
                    pen[2] = sprvid_q[11: 8];
                    pen[3] = sprvid_q[15:12];

                    // X alignment (bits[3:2] of sr_cmd, not bits[1:0])
                    // MAME uses bits[3:2] for Y-align, bits[1:0] for X-align
                    case (sr_cmd[1:0])
                        2'b00: x_left = int'($signed(sr_xpos)) - int'(srr_eff_dstw) / 2;
                        2'b01: x_left = int'($signed(sr_xpos)) - int'(srr_eff_dstw) + 1;
                        default: x_left = int'($signed(sr_xpos));
                    endcase

                    for (int p = 0; p < 4; p++) begin
                        int src_px, screen_x;
                        src_px = int'(srr_px) + p;
                        if (src_px < int'(srr_eff_dstw)) begin
                            if (flipx)
                                screen_x = x_left + int'(srr_eff_dstw) - 1 - src_px;
                            else
                                screen_x = x_left + src_px;

                            if (screen_x >= 0 && screen_x < H_ACTIVE &&
                                pen[p] != 4'h0) begin
                                // First-come wins: lower-indexed slots have priority
                                if (spr_linebuf[screen_x][3:0] == 4'h0) begin
                                    spr_linebuf[screen_x] <=
                                        {sr_prio, sr_color, pen[p]};
                                end
                            end
                        end
                    end
                end

                srr_px <= srr_px + 9'd4;

                if ((srr_px + 9'd4) >= {1'b0, srr_eff_dstw[7:0]}) begin
                    // Done with this sprite
                    srr_state <= SRR_NEXT;
                end else begin
                    // Issue next GFX word in this sprite's row
                    begin
                        logic [15:0] next_gfx;
                        logic [8:0]  nxt_px;
                        nxt_px   = srr_px + 9'd4;
                        next_gfx = sr_gfxoff +
                                   16'(sr_sdy) * 16'(srr_wpr[7:0]) +
                                   16'(nxt_px[8:2]);
                        srr_addr <= next_gfx;
                    end
                    srr_state <= SRR_PIXRD;
                end
            end

            SRR_NEXT: begin
                if (srr_slot + 4'd1 >= spr_table_cnt[srr_cur_line]) begin
                    srr_state <= SRR_IDLE;
                end else begin
                    srr_slot <= srr_slot + 4'd1;
                    begin
                        logic [3:0] ns;
                        logic [7:0] eidx;
                        ns   = srr_slot + 4'd1;
                        eidx = spr_table[srr_cur_line][3'(ns)][15:8];
                        sr_sdy      <= spr_table[srr_cur_line][3'(ns)][7:0];
                        srr_addr <= spr_list_base | 16'({eidx, 3'b000});
                    end
                    srr_state <= SRR_ATTR0;
                end
            end

            default: srr_state <= SRR_IDLE;
        endcase
    end
end

// ── Phase 3: Sprite line buffer readout ──────────────────────────────────────
// Combinational read during active display.
// spr_linebuf[x] = {prio[3:0], color[7:0], pen[3:0]}

logic [15:0] spr_buf_now;
assign spr_buf_now = spr_linebuf[hpos[8:0]];

logic [11:0] spr_pixel;
logic        spr_valid;
logic [ 3:0] spr_prio;

assign spr_pixel = spr_buf_now[11:0];   // {color[7:0], pen[3:0]}
assign spr_valid = (spr_buf_now[3:0] != 4'h0);
assign spr_prio  = spr_buf_now[15:12];  // priority group

// =============================================================================
// SECTION 14: Background / Solid Layer
// =============================================================================
// Always outputs one color: the background palette entry from reg_bg_cfg.
// MAME segas32_v.cpp update_background(): single CRAM entry.
// reg_bg_cfg[9:0] = palette index offset into CRAM.
// =============================================================================
logic [13:0] bg_pal_idx;
assign bg_pal_idx = {4'h0, reg_bg_cfg[9:0]};

// =============================================================================
// SECTION 15: Pixel Mixer
// =============================================================================
// Composites all layers each pixel clock cycle during active display.
//
// Priority scheme (MAME segas32_v.cpp mix_all_layers()):
//   Each layer has a 4-bit priority from mix_regs.
//   Effective priority = {layer_prio[3:0], layer_enum[2:0]}
//   where layer_enum: SPRITE=6, TEXT=5, NBG0=4, NBG1=3, NBG2=2, NBG3=1, BG=0
//   Higher effective priority wins.
//
// Palette lookup:
//   Each layer pixel = {color[N:0], pen[3:0]}
//   Palette address = (mix_palbase << 8) | (color << 4) | pen
//   (simplified; actual lookup uses mixshift for 8bpp modes)
//
// Blend: if blend_en, mix winning pixel with second-highest opaque pixel
//   Output = (win × (8-factor) + sec × factor) >> 3
//
// Shadow: if sprite shadow bit set, AND pixel RGB with $7FFF (right-shift)
//
// This implementation: fully-combinational 6-layer tournament each pixel cycle.
// Palette lookup adds 1-cycle latency → pixel output is 1 cycle behind hpos.
// =============================================================================

// Layer enables from reg_layer_en and reg_out_ctrl
// reg_layer_en bit mapping (MAME): bit0=TEXT, bit1=NBG0, bit2=NBG1, bit3=NBG2,
//                                   bit4=NBG3, bit5=BITMAP, bit6=SPRITES
logic en_text, en_nbg0, en_nbg1, en_nbg2, en_nbg3, en_spr;
assign en_text = ~reg_layer_en[0] & ~reg_out_ctrl[0];
assign en_nbg0 = ~reg_layer_en[1] & ~reg_out_ctrl[1];
assign en_nbg1 = ~reg_layer_en[2] & ~reg_out_ctrl[2];
assign en_nbg2 = ~reg_layer_en[3] & ~reg_out_ctrl[3];
assign en_nbg3 = ~reg_layer_en[4] & ~reg_out_ctrl[4];
assign en_spr  = ~reg_layer_en[6] & ~reg_out_ctrl[6];

// Read from TEXT line buffer during active display
logic [10:0] text_px_now;
assign text_px_now = text_linebuf[hpos[8:0]];   // {color[6:0], pen[3:0]}

logic text_opaque;
assign text_opaque = en_text & (text_px_now[3:0] != 4'h0);

// Priority comparator: find winning opaque layer
// Each layer entry: {4-bit prio, 3-bit layer_enum, 10-bit pixel, valid}
// We compare 6 layers in a simple tree

// Layer struct encoding for comparator: {effpri[6:0], pixel[11:0]}
// effpri = {mix_prio[3:0], layer_enum[2:0]}
// layer_enum: TEXT=5, NBG0=4, NBG1=3, NBG2=2, NBG3=1, BG=0, SPR=6
localparam logic [2:0] ENUM_SPR  = 3'd6;
localparam logic [2:0] ENUM_TEXT = 3'd5;
localparam logic [2:0] ENUM_NBG0 = 3'd4;
localparam logic [2:0] ENUM_NBG1 = 3'd3;
localparam logic [2:0] ENUM_NBG2 = 3'd2;
localparam logic [2:0] ENUM_NBG3 = 3'd1;
localparam logic [2:0] ENUM_BG   = 3'd0;

// Build 7-bit effective priority per layer
// Sprites: each pixel carries its own 4-bit priority group (spr_prio from the
// line buffer). MAME maps sprite group 0..15 to mix_regs[0x00..0x07] (2 nibbles
// per word). We extract the 4-bit priority for the current sprite group:
//   group = spr_prio[3:0]; word = mix_regs[group >> 1]; nibble = group[0]
logic [3:0] spr_grp_prio;
always_comb begin
    logic [15:0] spr_grp_word;
    spr_grp_word = mix_regs[{3'b000, spr_prio[3:1]}];
    spr_grp_prio = spr_prio[0] ? spr_grp_word[15:12] : spr_grp_word[3:0];
end

logic [6:0] epri_spr, epri_text, epri_nbg0, epri_nbg1, epri_nbg2, epri_nbg3;
assign epri_spr  = {spr_grp_prio,  ENUM_SPR};
assign epri_text = {mix_prio_text,  ENUM_TEXT};
assign epri_nbg0 = {mix_prio_nbg0, ENUM_NBG0};
assign epri_nbg1 = {mix_prio_nbg1, ENUM_NBG1};
assign epri_nbg2 = {mix_prio_nbg2, ENUM_NBG2};
assign epri_nbg3 = {mix_prio_nbg3, ENUM_NBG3};

// 7-layer tournament: find highest-priority opaque pixel
// Layer pixel widths (bits): sprite/BG=12, text=11 (no hi pal bit)
// Unify to 13-bit: {valid, color_hi[2:0], pen[3:0], ...} — use palette index directly

// For each layer: compute {valid, effpri[6:0], pal_idx[13:0]}
// pal_idx = (palbase << 8) | (color_in_entry << 4) | pen
// TEXT:  pal_idx = (mix_palbase_text << 8) | (text_color_field << 4) | pen
//        text_px_now = {color[6:0], pen[3:0]}: color=bits[10:4], pen=bits[3:0]
// NBG0–NBG3: pal_idx = (palbase << 8) | pixel[11:0] (color is bits[11:4], pen is bits[3:0])
// BG:   pal_idx = bg_pal_idx
// All palette indices are 13-bit (max 16K entries)

// TEXT palette address: (palbase << 11) | (color_bank[6:0] << 4) | pen[3:0]
// 14-bit address: palbase occupies bits[13:11], color[6:0] at bits[10:4], pen at bits[3:0]
logic [13:0] text_pal_idx;
assign text_pal_idx = {mix_palbase_text[2:0], text_px_now[10:4], text_px_now[3:0]};
// {3-bit palbase, 7-bit color, 4-bit pen} = 14 bits exactly
// MAME: pal_idx = (palette_base << 8) | (color << 4) | pen
// With palbase occupying 3 bits: palette_base × 2048 + color × 16 + pen

// Winning pixel logic — combinational 7-way comparator
// Input: {valid, epri[6:0], pal_idx[13:0]}
// Output: winning pal_idx, or BG pal_idx if no layer is opaque

logic [21:0] cand_spr, cand_text, cand_nbg0, cand_nbg1, cand_nbg2, cand_nbg3, cand_bg;
// Format: {valid, epri[6:0], pal_idx[13:0]} = 22 bits

// spr_pixel = 12 bits, palette = {color[7:0]=bits[11:4], pen=bits[3:0]}
// pal_idx for sprite: {palbase(2), color(8), pen(4)} → but our 14-bit field:
//   use spr_pixel[11:0] directly as low 12 bits, palbase from mixer = 2 bits
assign cand_spr  = {(en_spr  & spr_valid),  epri_spr,  2'h0, spr_pixel[11:0]};
assign cand_text = {(text_opaque),           epri_text, text_pal_idx};
// NBG0: palbase 4-bit × 256 + pixel[11:0] → 14-bit: {palbase[1:0], pixel[11:0]} = 14 bits
assign cand_nbg0 = {(en_nbg0 & nbg0_valid), epri_nbg0, mix_palbase_nbg0[1:0], nbg0_pixel[11:0]};
assign cand_nbg1 = {(en_nbg1 & nbg1_valid), epri_nbg1, mix_palbase_nbg0[1:0], nbg1_pixel[11:0]};
assign cand_nbg2 = {(en_nbg2 & nbg2_valid), epri_nbg2, 14'h0000};
assign cand_nbg3 = {(en_nbg3 & nbg3_valid), epri_nbg3, 14'h0000};
assign cand_bg   = {1'b1,                   7'h00,     bg_pal_idx};

// 7-way max: highest [21] (valid) then highest [20:14] (epri)
function automatic logic [21:0] layer_max(
    input logic [21:0] a, b
);
    if (a[21] && b[21])
        return (a[20:14] >= b[20:14]) ? a : b;
    else if (a[21]) return a;
    else if (b[21]) return b;
    else return 22'h000000;  // neither valid
endfunction

logic [21:0] win01, win23, win45, win012, win2345, winner;
always_comb begin
    win01   = layer_max(cand_spr,  cand_text);
    win23   = layer_max(cand_nbg0, cand_nbg1);
    win45   = layer_max(cand_nbg2, cand_nbg3);
    win012  = layer_max(win01, cand_bg);
    win2345 = layer_max(win23, win45);
    winner  = layer_max(win012, win2345);
end

// Palette lookup (1-cycle registered)
logic [13:0] mix_pal_addr;
logic [15:0] mix_pal_q;
logic        mix_pal_valid;
logic        mix_pixel_active_d;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mix_pal_addr      <= '0;
        mix_pixel_active_d <= 1'b0;
    end else begin
        mix_pal_addr      <= winner[13:0];
        mix_pixel_active_d <= pixel_active;
    end
end
assign pal_rd_addr = mix_pal_addr;
assign pal_rd      = mix_pixel_active_d;
assign mix_pal_q   = pal_rd_q;

// RGB output from palette entry: {rsvd, B[4:0], G[4:0], R[4:0]}
// Expand 5-bit channels to 8-bit (replicate upper bits into lower)
logic [4:0] out_r5, out_g5, out_b5;
assign out_r5 = mix_pal_q[ 4: 0];
assign out_g5 = mix_pal_q[ 9: 5];
assign out_b5 = mix_pal_q[14:10];

// 5→8 expansion: {r5, r5[4:2]} for good linearity
assign pixel_r = {out_r5, out_r5[4:2]};
assign pixel_g = {out_g5, out_g5[4:2]};
assign pixel_b = {out_b5, out_b5[4:2]};
assign pixel_de = mix_pixel_active_d;

// GFX ROM port: driven by NBG0/NBG1 engines via mux above (gfx_addr/gfx_rd assigned there)

endmodule
