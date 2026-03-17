`default_nettype none
// =============================================================================
// taito_x.sv — Taito X System Board Top-Level Integration
// =============================================================================
//
// Primary target: Superman (superman / supermanu / supermane), 1988.
// Other games: Twin Hawk (twinhawk/daisenpu), Gigandes, Balloon Brothers, etc.
//
// Instantiated blocks:
//   x1_001a        — Sprite generator (X1-001A), FG sprites + BG tilemap
//   taito_x_colmix — Priority compositor + xRGB_555 palette BRAM
//   work_ram       — 64KB general-purpose BRAM (68000)
//   video_timing   — 384×240 @ 60 Hz timing generator (internal)
//
// NOT instantiated here (provided by the emu.sv MiSTer wrapper):
//   MC68000 CPU (fx68k), Z80 sound CPU, YM2610/YM2151, SDRAM controller
//
// 68000 Memory Map (byte addresses):
//   0x000000 – 0x07FFFF    Program ROM     (512KB, SDRAM via sdr_*)
//   0x100000 – 0x10FFFF    Work RAM        (64KB)
//   0xB00000 – 0xB00FFF    Palette RAM     (2048 × 16-bit xRGB_555)
//   0xC00000 – 0xCFFFFF    GFX ROM window  (1MB, read-only, SDRAM via gfx_*)
//   0xD00000 – 0xD005FF    Sprite Y RAM    (X1-001A spriteylow)
//   0xD00600 – 0xD00607    Sprite ctrl regs (X1-001A spritectrl)
//   0xE00000 – 0xE03FFF    Sprite code RAM (X1-001A spritecode, 16KB)
//
// I/O (approximated from MAME taito_x.cpp):
//   0x500000 – 0x50000F    X1-004 input ports (joystick, coins, DIP) [read-only]
//   0x600000 – 0x600001    X1-005 watchdog / reset (stub)
//   0x780000 – 0x780001    Sound command to Z80 (write)
//   0x7A0000 – 0x7A0001    Sound command acknowledge (read)
//
// Z80 Sound Memory Map (byte addresses):
//   0x0000 – 0x7FFF    Z80 sound ROM (32KB)
//   0xC000 – 0xDFFF    Z80 work RAM (8KB)
//   0xE000 – 0xE001    YM2610/YM2151 register write (I/O mapped at 0x00/0x01)
//
// Interrupt routing:
//   68000 IPL2 (level 5, active-low ~5 = 3'b010): VBlank from video timing.
//   Z80 /INT: from 68000 sound command write (X1-004 NMI-like mechanism).
//
// Parameterised for per-game differences:
//   COLOR_BASE   — palette color base offset (set 0 for superman)
//   FG_NOFLIP_YOFFS — sprite Y offset in normal orientation (superman = -18)
//   FG_NOFLIP_XOFFS — sprite X offset (superman = 0)
//   SPRITE_LIMIT — max sprite index scanned (511 for superman)
//
// Deferred / out of scope for this integration layer:
//   YM2610 / YM2151 FM synthesis (audio chip instantiated in emu.sv)
//   GFX ROM banking via X1-006 (gfxbank_cb) — pass-through to gfx_* SDRAM port
//   X1-003 / X1-007 exact chip functions (stubbed as identity / no-op)
//   Cycle-accurate 68000 bus timing (DTACK is 1-cycle registered for local RAMs)
//   SDRAM prog ROM wait states (DTACK from SDRAM arbiter in emu.sv)
//
// Reference:
//   chips/taito_x/section2_x1001a_detail.md — X1-001A register layout
//   chips/taito_x/ARCHITECTURE.md           — system memory map + interrupt routing
//   chips/taito_x/README.md                 — hardware overview
//   MAME src/mame/taito/taito_x.cpp         — per-game driver
//   MAME src/devices/video/x1_001.cpp       — X1-001A rendering
// =============================================================================

/* verilator lint_off SYNCASYNCNET */
module taito_x #(
    // ── Address decode parameters (word addresses = byte_addr >> 1) ──────────
    // Defaults match superman.
    parameter logic [23:1] WRAM_BASE  = 23'h080000,   // 0x100000 byte / 2
    parameter int unsigned WRAM_ABITS = 15,             // 2^15 = 32K words = 64KB
    parameter logic [23:1] PAL_BASE   = 23'h580000,    // 0xB00000 byte / 2
    parameter logic [23:1] YRAM_BASE  = 23'h680000,    // 0xD00000 byte / 2
    parameter logic [23:1] CTRL_BASE  = 23'h680300,    // 0xD00600 byte / 2
    parameter logic [23:1] CRAM_BASE  = 23'h700000,    // 0xE00000 byte / 2
    parameter logic [23:1] IO_BASE    = 23'h280000,    // 0x500000 byte / 2
    parameter logic [23:1] SND_BASE   = 23'h3C0000,    // 0x780000 byte / 2

    // ── Sprite chip configuration (game-specific) ────────────────────────────
    parameter int signed   FG_NOFLIP_YOFFS = -18,      // superman: -0x12
    parameter int signed   FG_NOFLIP_XOFFS = 0,
    parameter int unsigned SPRITE_LIMIT    = 511,

    // ── Color base for palette lookup (MAME colorbase value) ─────────────────
    parameter int unsigned COLOR_BASE = 0
) (
    // ── Clocks / Reset ────────────────────────────────────────────────────────
    input  logic        clk_sys,        // system clock (e.g. 32 MHz)
    input  logic        clk_pix,        // pixel clock enable (1-cycle strobe, sys-domain)
    input  logic        reset_n,        // active-low async reset

    // ── MC68000 CPU Bus ───────────────────────────────────────────────────────
    // cpu_addr is the 68000 word address (A[23:1]).
    input  logic [23:1] cpu_addr,
    input  logic [15:0] cpu_din,        // data FROM cpu (write path)
    output logic [15:0] cpu_dout,       // data TO cpu (read mux)
    input  logic        cpu_lds_n,
    input  logic        cpu_uds_n,
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic        cpu_as_n,       // address strobe (active low)
    output logic        cpu_dtack_n,    // data acknowledge (active low)
    output logic [2:0]  cpu_ipl_n,      // interrupt level (active-low encoded)

    // ── Z80 Sound CPU Bus ─────────────────────────────────────────────────────
    input  logic [15:0] z80_addr,
    input  logic  [7:0] z80_din,        // data from Z80 (write)
    output logic  [7:0] z80_dout,       // data to Z80 (read)
    input  logic        z80_rd_n,
    input  logic        z80_wr_n,
    input  logic        z80_mreq_n,
    input  logic        z80_iorq_n,
    output logic        z80_int_n,      // Z80 /INT from sound command latch
    output logic        z80_reset_n,    // Z80 reset (mirrors system reset_n)
    output logic        z80_rom_cs_n,   // Z80 ROM chip-select (A<0x8000)
    output logic        z80_ram_cs_n,   // Z80 RAM chip-select (0xC000–0xDFFF)

    // ── GFX ROM Interface (toggle handshake, byte-addressed) ─────────────────
    // X1-001A GFX ROM: 18-bit word address (4 × 16-bit words per 16×16 tile row).
    // The SDRAM arbiter in emu.sv translates this to a physical SDRAM address.
    output logic [17:0] gfx_addr,
    input  logic [15:0] gfx_data,
    output logic        gfx_req,
    input  logic        gfx_ack,

    // ── SDRAM (program ROM + Z80 audio ROM reads) ─────────────────────────────
    // Used by emu.sv SDRAM arbiter for CPU program ROM reads and Z80 sound ROM.
    output logic [26:0] sdr_addr,
    input  logic [15:0] sdr_data,
    output logic        sdr_req,
    input  logic        sdr_ack,

    // ── Video Output ─────────────────────────────────────────────────────────
    output logic [4:0]  rgb_r,
    output logic [4:0]  rgb_g,
    output logic [4:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Player Inputs (active-low) ────────────────────────────────────────────
    input  logic [7:0]  joystick_p1,    // [3:0]=UDLR, [7:4]=buttons (active-low)
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,           // [0]=COIN1, [1]=COIN2 (active-low)
    input  logic        service,        // SERVICE button (active-low)
    input  logic [7:0]  dipsw1,
    input  logic [7:0]  dipsw2
);

// =============================================================================
// Video Timing Generator — 384×240 @ 60 Hz
// =============================================================================
//
// From ARCHITECTURE.md §Video Timing (384×240 @ 60 Hz):
//   Horizontal: 384 visible + 464 total (~50 µs line at 9.2 MHz pixel clock)
//   Vertical:   240 visible + 274 total lines @ 60 Hz
//
// With clk_pix (pixel clock enable at ~8 MHz derived from clk_sys), we count
// pixel clock enables for timing. At 32 MHz sys_clk with clk_pix=1 every
// 4 cycles the effective pixel rate is 8 MHz, which is close to the 9.2 MHz
// hardware pixel clock. Using integer-friendly counts that produce ~60 Hz:
//
//   H total = 512 clk_pix (visible: 384, blank: 128)
//   V total = 262 lines   (visible: 240, blank: 22)
//   Frame rate = 8 MHz / (512 * 262) = 59.9 Hz ≈ 60 Hz
//
// HSYNC and VSYNC timing:
//   HSync: assert during hpos 400..431 (32-pixel window in HBlank)
//   VSync: assert during vpos 244..246 (2-line window in VBlank)
//
// Interrupt: VBlank rising edge → 68000 IPL5 (active-low ~5 = 3'b010)
// =============================================================================

localparam int H_VISIBLE  = 384;
localparam int H_TOTAL    = 512;
localparam int V_VISIBLE  = 240;
localparam int V_TOTAL    = 262;
localparam int HS_START   = 400;
localparam int HS_END     = 432;
localparam int VS_START   = 244;
localparam int VS_END     = 247;

logic [8:0] hpos;   // 0..511
logic [7:0] vpos;   // 0..261
logic        vblank_r;
logic        vblank_rise;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        hpos <= 9'd0;
        vpos <= 8'd0;
    end else if (clk_pix) begin
        if (hpos == 9'(H_TOTAL - 1)) begin
            hpos <= 9'd0;
            if (vpos == 8'(V_TOTAL - 1))
                vpos <= 8'd0;
            else
                vpos <= vpos + 8'd1;
        end else begin
            hpos <= hpos + 9'd1;
        end
    end
end

assign hblank  = (hpos >= 9'(H_VISIBLE));
assign vblank  = (vpos >= 8'(V_VISIBLE));
assign hsync_n = ~((hpos >= 9'(HS_START)) && (hpos < 9'(HS_END)));
assign vsync_n = ~((vpos >= 8'(VS_START)) && (vpos < 8'(VS_END)));

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) vblank_r <= 1'b0;
    else          vblank_r <= vblank;
end
assign vblank_rise = vblank & ~vblank_r;

// =============================================================================
// Chip-Select Decode (all comparisons on cpu_addr[23:1], qualified by !cpu_as_n)
// =============================================================================

// Work RAM: 0x100000–0x10FFFF  (64KB = 32K words, 15-bit index)
//   word base 0x080000; top 8 bits from [23:15] == 8'h10
logic wram_cs;
assign wram_cs = (cpu_addr[23:15] == 8'h10) && !cpu_as_n;

// Palette RAM: 0xB00000–0xB00FFF  (4KB = 2048 × 16-bit, 11-bit index)
//   word base 0x580000; top 12 bits from [23:11] == 12'hB00
logic pal_cs;
assign pal_cs  = (cpu_addr[23:11] == 12'hB00) && !cpu_as_n;

// Sprite Y RAM: 0xD00000–0xD005FF  (768 bytes = 384 × 16-bit, 9-bit index)
//   word base 0x680000; top 14 bits from [23:9] == 14'h3400, then sub-range check
logic yram_cs;
assign yram_cs = (cpu_addr[23:9] == 14'h3400) && !cpu_as_n
                 && (cpu_addr[8:0] < 9'h180);  // 0x180 word entries (0x300 bytes / 2)

// Sprite ctrl: 0xD00600–0xD00607  (4 × 16-bit registers, 2-bit index)
//   word base 0x680300; [23:2] = 22 bits == 22'h1A00C0
logic ctrl_cs;
assign ctrl_cs = (cpu_addr[23:2] == 22'h1A00C0) && !cpu_as_n;

// Sprite code RAM: 0xE00000–0xE03FFF  (16KB = 8K words, 13-bit index)
//   word base 0x700000; top 10 bits from [23:13] == 10'h380
logic cram_cs;
assign cram_cs = (cpu_addr[23:13] == 10'h380) && !cpu_as_n;

// I/O ports: 0x500000–0x50000F  (8 × 16-bit words, 3-bit index)
//   word base 0x280000; [23:3] = 21 bits == 21'h50000
logic io_cs;
assign io_cs   = (cpu_addr[23:3] == 21'h50000) && !cpu_as_n;

// Sound command: 0x780000–0x780001  (1 × 16-bit, write-only from 68000)
logic snd_cmd_cs;
assign snd_cmd_cs = (cpu_addr[23:1] == SND_BASE) && !cpu_as_n;

// Sound ACK: 0x7A0000–0x7A0001  (read-only, Z80 response latch)
logic snd_ack_cs;
assign snd_ack_cs = (cpu_addr[23:1] == 23'h3D0000) && !cpu_as_n;

// =============================================================================
// X1-001A Sprite Generator
// =============================================================================

logic [15:0] yram_dout_raw;
logic [15:0] cram_dout_raw;
logic [15:0] ctrl_dout_raw;

logic        spr_pix_valid;
logic [8:0]  spr_pix_x;
logic [4:0]  spr_pix_color;
logic [8:0]  spr_pix_pal_index;
/* verilator lint_off UNUSED */
logic        spr_scan_active;
/* verilator lint_on UNUSED */

// Sprite chip decoded outputs (from spritectrl registers)
/* verilator lint_off UNUSED */
logic        spr_flip_screen;
logic [1:0]  spr_bg_startcol;
logic [3:0]  spr_bg_numcol;
logic        spr_frame_bank;
logic [15:0] spr_col_upper_mask;
/* verilator lint_on UNUSED */

// X1-001A reads GFX ROM one 16-bit word at a time (4 words per tile row).
// The GFX ROM interface is the toggle-handshake gfx_req/gfx_ack pair.
// x1_001a outputs pix_valid/pix_color per-pixel during active display;
// the colmix uses these directly.
//
// NOTE: pix_x from X1-001A reflects hpos at pixel output time. The colmix
// selects between sprite and tile pixels based on pix_valid alone.
//
// X1-001A exports the full 9-bit palette index via pix_pal_index[8:0]:
//   [8:4] = spr_color[4:0]  (5-bit palette selector from x_pointer[15:11])
//   [3:0] = pen[3:0]        (4-bit GFX ROM nibble, 0 = transparent)
// pix_valid is asserted when pen != 0 (transparent pixels are suppressed).
// spr_pix_pal_index is passed directly to colmix for the palette lookup.

x1_001a #(
    .FG_NOFLIP_YOFFS (FG_NOFLIP_YOFFS),
    .FG_NOFLIP_XOFFS (FG_NOFLIP_XOFFS),
    .SCREEN_H        (V_VISIBLE),
    .SCREEN_W        (H_VISIBLE),
    .SPRITE_LIMIT    (SPRITE_LIMIT)
) u_x1001a (
    .clk             (clk_sys),
    .rst_n           (reset_n),

    // Video timing
    .vblank          (vblank),
    .hblank          (hblank),
    .hpos            (hpos),
    .vpos            (vpos),

    // Y coordinate RAM (CPU access)
    .yram_cs         (yram_cs),
    .yram_we         (!cpu_rw),
    .yram_addr       (cpu_addr[9:1]),    // 9-bit word address within Y RAM
    .yram_din        (cpu_din),
    .yram_dout       (yram_dout_raw),
    .yram_be         ({!cpu_uds_n, !cpu_lds_n}),

    // Sprite code / attribute RAM (CPU access)
    .cram_cs         (cram_cs),
    .cram_we         (!cpu_rw),
    .cram_addr       (cpu_addr[13:1]),   // 13-bit word address within 16KB
    .cram_din        (cpu_din),
    .cram_dout       (cram_dout_raw),
    .cram_be         ({!cpu_uds_n, !cpu_lds_n}),

    // Control registers (CPU access)
    .ctrl_cs         (ctrl_cs),
    .ctrl_we         (!cpu_rw),
    .ctrl_addr       (cpu_addr[2:1]),    // 2-bit register select (4 words)
    .ctrl_din        (cpu_din),
    .ctrl_dout       (ctrl_dout_raw),
    .ctrl_be         ({!cpu_uds_n, !cpu_lds_n}),

    // External scanner read ports (not used from top level; tie off)
    .scan_yram_addr  (9'd0),
    /* verilator lint_off PINCONNECTEMPTY */
    .scan_yram_data  (),
    /* verilator lint_on PINCONNECTEMPTY */
    .scan_cram_addr  (13'd0),
    /* verilator lint_off PINCONNECTEMPTY */
    .scan_cram_data  (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Decoded control outputs
    .flip_screen     (spr_flip_screen),
    .bg_startcol     (spr_bg_startcol),
    .bg_numcol       (spr_bg_numcol),
    .frame_bank      (spr_frame_bank),
    .col_upper_mask  (spr_col_upper_mask),

    // GFX ROM toggle handshake
    .gfx_addr        (gfx_addr),
    .gfx_req         (gfx_req),
    .gfx_data        (gfx_data),
    .gfx_ack         (gfx_ack),

    // Pixel output (to colmix)
    .pix_valid       (spr_pix_valid),
    .pix_x           (spr_pix_x),
    .pix_color       (spr_pix_color),
    .pix_pal_index   (spr_pix_pal_index),

    .scan_active     (spr_scan_active)
);

// =============================================================================
// Background Tilemap
// =============================================================================
//
// The Taito X BG tilemap is rendered by the same X1-001A chip using the
// spritecode RAM at offsets 0x0400–0x07FF (tile code) and 0x0600–0x07FF
// (tile color). The BG render path inside x1_001a handles this as
// draw_background() when bg_numcol > 0.
//
// x1_001a does not currently expose a separate tile pixel output; the BG layer
// is composited internally by the line buffer (BG tiles are drawn first, FG
// sprites on top). Therefore tile_pix_* inputs to colmix are tied off here
// and colmix receives all pixel data through the sprite output.
//
// When x1_001a is extended to implement draw_background() with a separate
// tile pixel output port, those signals should be wired here.
//
// Colmix tie-off: tile_pix_valid=0 (sprite output only, BG inside x1_001a).

// =============================================================================
// Color Mixer / Palette Lookup
// =============================================================================

logic [15:0] pal_cpu_dout;

taito_x_colmix #(
    .COLOR_BASE (COLOR_BASE)
) u_colmix (
    .clk            (clk_sys),
    .rst_n          (reset_n),

    // Active-display / blanking
    .hblank         (hblank),
    .vblank         (vblank),

    // Sprite pixel from X1-001A
    .spr_pix_valid     (spr_pix_valid),
    .spr_pix_pal_index (spr_pix_pal_index),

    // BG tile pixel — tied off (BG composited inside X1-001A line buffer)
    .tile_pix_valid (1'b0),
    .tile_pix_color (5'd0),
    .tile_pix_pen   (4'd0),

    // CPU palette RAM access
    .cpu_pal_cs     (pal_cs),
    .cpu_pal_we     (!cpu_rw),
    .cpu_pal_addr   (cpu_addr[11:1]),
    .cpu_pal_din    (cpu_din),
    .cpu_pal_dout   (pal_cpu_dout),
    .cpu_pal_be     ({!cpu_uds_n, !cpu_lds_n}),

    // RGB output
    .rgb_r          (rgb_r),
    .rgb_g          (rgb_g),
    .rgb_b          (rgb_b)
);

// =============================================================================
// Work RAM — 64KB BRAM (68000 general purpose, 0x100000–0x10FFFF)
// =============================================================================

logic [15:0] work_ram [0:(1<<WRAM_ABITS)-1];
logic [15:0] wram_dout_r;

always_ff @(posedge clk_sys) begin
    if (wram_cs && !cpu_rw) begin
        if (!cpu_uds_n) work_ram[cpu_addr[WRAM_ABITS:1]][15:8] <= cpu_din[15:8];
        if (!cpu_lds_n) work_ram[cpu_addr[WRAM_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (wram_cs) wram_dout_r <= work_ram[cpu_addr[WRAM_ABITS:1]];
end

// =============================================================================
// Sound Command Latch (68000 → Z80 communication)
// =============================================================================
//
// 68000 writes a command byte to 0x780000; X1-004 signals Z80 /INT.
// Z80 reads the command from its I/O port, processes, and writes ACK.
// 68000 reads ACK from 0x7A0000.

logic [7:0] snd_cmd_reg;   // command from 68000 to Z80
logic [7:0] snd_ack_reg;   // acknowledgement from Z80 to 68000
logic        snd_int_pend;  // Z80 /INT pending

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        snd_cmd_reg  <= 8'h00;
        snd_ack_reg  <= 8'h00;
        snd_int_pend <= 1'b0;
    end else begin
        // 68000 writes sound command
        if (snd_cmd_cs && !cpu_rw && !cpu_lds_n) begin
            snd_cmd_reg  <= cpu_din[7:0];
            snd_int_pend <= 1'b1;
        end

        // Z80 acknowledges by writing to I/O port 0x00 (IORQ=0, A[7:0]=0x00)
        if (!z80_iorq_n && !z80_wr_n && (z80_addr[7:0] == 8'h00)) begin
            snd_ack_reg  <= z80_din;
            snd_int_pend <= 1'b0;   // clear interrupt when Z80 writes back
        end
    end
end

// Z80 reads sound command from I/O port 0x00
assign z80_dout    = (!z80_iorq_n && !z80_rd_n && (z80_addr[7:0] == 8'h00))
                     ? snd_cmd_reg : 8'hFF;

// Z80 /INT (active-low): assert when command is pending
assign z80_int_n   = ~snd_int_pend;

// Z80 reset follows system reset
assign z80_reset_n = reset_n;

// Z80 chip selects: ROM at A<0x8000, RAM at A[15:13]=3'b110 (0xC000–0xDFFF)
assign z80_rom_cs_n = ~(!z80_mreq_n && (z80_addr[15] == 1'b0));
assign z80_ram_cs_n = ~(!z80_mreq_n && (z80_addr[15:13] == 3'b110));

// =============================================================================
// I/O Registers (X1-004 input ports, read-only from 68000)
// =============================================================================
//
// From MAME taito_x.cpp: I/O at 0x500000–0x50000F.
// Typical layout (game-specific byte positions):
//   0x500000: joystick P1 [7:0]
//   0x500002: joystick P2 [7:0]
//   0x500004: coin / service / start [7:0]
//   0x500006: DIP switch bank 1
//   0x500008: DIP switch bank 2

logic [15:0] io_dout;
always_comb begin
    io_dout = 16'hFFFF;
    if (io_cs) begin
        case (cpu_addr[3:1])
            3'd0: io_dout = {8'hFF, joystick_p1};
            3'd1: io_dout = {8'hFF, joystick_p2};
            3'd2: io_dout = {8'hFF, {2'b11, 1'b1 /*TILT*/, service,
                                     coin[1], coin[0], 1'b1 /*START2*/, 1'b1}};
            3'd3: io_dout = {8'hFF, dipsw1};
            3'd4: io_dout = {8'hFF, dipsw2};
            default: io_dout = 16'hFFFF;
        endcase
    end
end

// =============================================================================
// CPU Data Bus Read Mux
// Priority: CRAM > YRAM > CTRL > PAL > WRAM > IO > SND_ACK > open-bus
// =============================================================================

always_comb begin
    if (cram_cs)
        cpu_dout = cram_dout_raw;
    else if (yram_cs)
        cpu_dout = yram_dout_raw;
    else if (ctrl_cs)
        cpu_dout = ctrl_dout_raw;
    else if (pal_cs)
        cpu_dout = pal_cpu_dout;
    else if (wram_cs)
        cpu_dout = wram_dout_r;
    else if (io_cs)
        cpu_dout = io_dout;
    else if (snd_ack_cs)
        cpu_dout = {8'hFF, snd_ack_reg};
    else
        cpu_dout = 16'hFFFF;   // open bus
end

// =============================================================================
// DTACK Generation
// =============================================================================
//
// Local BRAM regions: 1-cycle registered DTACK.
// SDRAM-backed regions (prog ROM 0x000000–0x07FFFF): DTACK from emu.sv
// SDRAM arbiter (falls through to open-bus here, no local CS).

logic any_local_cs;
logic dtack_r;

assign any_local_cs = wram_cs | pal_cs | yram_cs | ctrl_cs | cram_cs
                    | io_cs | snd_cmd_cs | snd_ack_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) dtack_r <= 1'b0;
    else          dtack_r <= any_local_cs;
end

assign cpu_dtack_n = cpu_as_n ? 1'b1 : !dtack_r;

// =============================================================================
// Interrupt Controller
// =============================================================================
//
// VBlank → 68000 IPL5 (level 5, active-low ~5 = 3'b010).
// HOLD_LINE: latch and hold for 16-bit timer window (~65K sys_clk cycles).
// This is sufficient time for the 68000 to IACK the interrupt.

logic        ipl_active;
logic [15:0] ipl_timer;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl_active <= 1'b0;
        ipl_timer  <= 16'b0;
    end else begin
        if (vblank_rise) begin
            ipl_active <= 1'b1;
            ipl_timer  <= 16'hFFFF;
        end else if (ipl_active) begin
            if (ipl_timer == 16'b0) ipl_active <= 1'b0;
            else                    ipl_timer  <= ipl_timer - 16'd1;
        end
    end
end

// IPL5: active-low encoded = ~3'd5 = 3'b010
assign cpu_ipl_n = ipl_active ? ~3'd5 : 3'b111;

// =============================================================================
// SDRAM stub (prog ROM pass-through)
// =============================================================================
//
// The emu.sv wrapper drives sdr_req/sdr_addr for CPU program ROM reads.
// This module simply exposes those ports upward. The SDRAM arbiter in emu.sv
// handles the actual SDRAM interface.
//
// When a CPU access targets 0x000000–0x07FFFF (program ROM window), the
// emu.sv wrapper must intercept the bus cycle, issue an SDRAM read, and
// provide DTACK + data externally. This module does not generate DTACK for
// program ROM accesses (no local CS for that range).
//
// Tie off sdr_* (emu.sv drives them through the cpu_sdr_* wires).
assign sdr_addr = 27'b0;
assign sdr_req  = 1'b0;

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{spr_pix_x,      // pix_x not needed (colmix reads from timing)
                   spr_pix_color,  // 5-bit selector; full index via spr_pix_pal_index
                   sdr_data};
/* verilator lint_on UNUSED */

endmodule
