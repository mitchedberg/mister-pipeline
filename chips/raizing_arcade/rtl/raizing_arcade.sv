`default_nettype none
// =============================================================================
// raizing_arcade — Battle Garegga (RA9503) System Top Level
// =============================================================================
//
// MAME driver: src/mame/toaplan/raizing.cpp  (bgaregga_state)
// Board:       RA9503 (Raizing/8ing, 1996)
//
// Hardware:
//   MC68000 @ 16 MHz (32 MHz / 2 — 32 MHz XTAL)
//   Z80     @  4 MHz (32 MHz / 8 — for audio)
//   GP9001 VDP (single chip, Toaplan/Raizing tile + sprite processor)
//   YM2151 + OKI M6295 (audio)
//   GAL16V8 × 5 (bank switching PALs — see gal_oki_bank.sv)
//   Text tilemap (separate from GP9001)
//
// Memory map (68000) — from MAME bgaregga_68k_mem:
//   0x000000 - 0x0FFFFF   1MB    Program ROM (direct BRAM in sim)
//   0x100000 - 0x10FFFF  64KB    Work RAM
//   0x218000 - 0x21BFFF  16KB    Z80 shared RAM (byte-wide, even bytes)
//   0x21C020 - 0x21C021         IN1 (joystick 1)
//   0x21C024 - 0x21C025         IN2 (joystick 2)
//   0x21C028 - 0x21C029         SYS (coin, start, service)
//   0x21C02C - 0x21C02D         DSWA
//   0x21C030 - 0x21C031         DSWB
//   0x21C034 - 0x21C035         JMPR (jumper/region)
//   0x21C03C - 0x21C03D         GP9001 scanline counter (vdpcount_r)
//   0x21C01D                    Coin counter write
//   0x300000 - 0x30000D         GP9001 VDP registers (read/write)
//   0x400000 - 0x400FFF  4KB    Palette RAM
//   0x500000 - 0x501FFF  8KB    Text tilemap VRAM
//   0x502000 - 0x502FFF  4KB    Text line select RAM
//   0x503000 - 0x5031FF  512B   Text line scroll RAM
//   0x503200 - 0x503FFF         RAM (unused palette area)
//   0x600001                    Sound latch write (byte, to Z80)
//
// Memory map (Z80 sound CPU):
//   0x0000 - 0x7FFF   32KB   Sound ROM (fixed)
//   0x8000 - 0xBFFF   16KB   Sound ROM (banked via z80_audiobank, 4-bit, 8 × 16KB pages)
//   0xC000 - 0xDFFF    8KB   Shared RAM (with 68K at 0x218000)
//   0xE000 - 0xE001          YM2151 (read/write)
//   0xE004                   OKI M6295 (read/write)
//   0xE006 - 0xE008          GAL OKI bank registers (write-only, see gal_oki_bank.sv)
//   0xE00A                   Z80 ROM bank register (write, 4-bit, selects 16KB audio ROM page)
//   0xE00C                   Sound latch acknowledge (write)
//   0xE01C                   Sound latch read (read from 68K)
//   0xE01D                   bgaregga_E01D_r (IRQ pending status)
//
// SDRAM layout (for MiSTer ioctl ROM loading):
//   ROM index 0 (CPU):  0x000000 - 0x0FFFFF  1MB   68K program ROM
//   ROM index 1 (GFX):  0x100000 - 0x8FFFFF  8MB   GP9001 tile ROM (4 × 2MB)
//   ROM index 2 (SND):  0x900000 - 0x91FFFF  128KB  Z80 audio ROM
//   ROM index 3 (OKI):  0x920000 - 0xA1FFFF  1MB   OKI ADPCM samples
//   ROM index 4 (TXT):  0xA20000 - 0xA27FFF  32KB  Text tilemap ROM
//
// =============================================================================

// ============================================================================
// Typedef: GP9001 Sprite Display List Entry
// Guard against redefinition when compiled alongside gp9001.sv
// ============================================================================
`ifndef SPRITE_ENTRY_T_DEFINED
`define SPRITE_ENTRY_T_DEFINED
typedef struct packed {
    logic [8:0]  x;
    logic [8:0]  y;
    logic [9:0]  tile_num;
    logic        flip_x;
    logic        flip_y;
    logic        prio;
    logic [3:0]  palette;
    logic [1:0]  size;
    logic        valid;
} sprite_entry_t;
`endif

/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off SYNCASYNCNET */
module raizing_arcade #(
    // Clock input is 96 MHz system clock; all enables generated internally
    parameter int CLK_FREQ_HZ = 96_000_000
) (
    input  logic        clk,            // 96 MHz system clock
    input  logic        rst_n,          // active-low reset

    // ── MiSTer HPS I/O ────────────────────────────────────────────────────────
    input  logic        ioctl_wr,       // ROM loading write strobe
    input  logic [24:0] ioctl_addr,     // ROM loading address
    input  logic [15:0] ioctl_dout,     // ROM loading data (16-bit)
    input  logic [7:0]  ioctl_index,    // ROM region index (0=CPU, 1=GFX, 2=SND, 3=OKI, 4=TXT)
    output logic        ioctl_wait,     // Stall HPS while SDRAM busy

    // ── Video output ─────────────────────────────────────────────────────────
    output logic [7:0]  red,
    output logic [7:0]  green,
    output logic [7:0]  blue,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,
    output logic        ce_pixel,

    // ── Audio output ─────────────────────────────────────────────────────────
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    // ── Cabinet I/O ──────────────────────────────────────────────────────────
    input  logic [9:0]  joystick_0,     // P1: [9:8]=coin/start, [5:0]=UDLRBA
    input  logic [9:0]  joystick_1,     // P2
    input  logic [7:0]  dipsw_a,        // DIP switch A
    input  logic [7:0]  dipsw_b,        // DIP switch B

    // ── SDRAM interface ───────────────────────────────────────────────────────
    output logic [12:0] sdram_a,
    output logic [1:0]  sdram_ba,
    inout  logic [15:0] sdram_dq,
    output logic        sdram_cas_n,
    output logic        sdram_ras_n,
    output logic        sdram_we_n,
    output logic        sdram_cs_n,
    output logic [1:0]  sdram_dqm,
    output logic        sdram_cke
);

// =============================================================================
// SDRAM — tied off (sim uses internal BRAM for program ROM)
// =============================================================================

assign sdram_a     = 13'h0;
assign sdram_ba    = 2'b00;
assign sdram_cas_n = 1'b1;
assign sdram_ras_n = 1'b1;
assign sdram_we_n  = 1'b1;
assign sdram_cs_n  = 1'b1;
assign sdram_dqm   = 2'b11;
assign sdram_cke   = 1'b1;
assign ioctl_wait  = 1'b0;

// =============================================================================
// Clock Enable Generation
// 96 MHz → 68000 @ 16 MHz (÷6, two alternating enables enPhi1/enPhi2)
//        → Z80   @  4 MHz (÷24)
//        → pixel clock @ 8 MHz (÷12)
// =============================================================================

// ── 68000 clock enables ──────────────────────────────────────────────────────
// Each cpu_cen fires every 6 sys clocks.  phi_toggle alternates so that:
//   cpu_cen & ~phi_toggle → enPhi1 (rising-edge phase)
//   cpu_cen &  phi_toggle → enPhi2 (falling-edge phase)

logic [2:0] cpu_div;
logic       cpu_cen;      // master 16 MHz enable pulse (one per 6 clk)
logic       phi_toggle;   // alternates 0/1 each cpu_cen

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_div    <= 3'd0;
        cpu_cen    <= 1'b0;
        phi_toggle <= 1'b0;
    end else begin
        cpu_cen <= 1'b0;
        if (cpu_div == 3'd5) begin
            cpu_div    <= 3'd0;
            cpu_cen    <= 1'b1;
            phi_toggle <= ~phi_toggle;
        end else begin
            cpu_div <= cpu_div + 3'd1;
        end
    end
end

logic enPhi1, enPhi2;
assign enPhi1 = cpu_cen & ~phi_toggle;   // first pulse after reset
assign enPhi2 = cpu_cen &  phi_toggle;

// ── Z80 clock enable (4 MHz = ÷24) ──────────────────────────────────────────

logic [4:0] z80_div;
logic       z80_cen;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        z80_div <= 5'd0;
        z80_cen <= 1'b0;
    end else begin
        z80_cen <= 1'b0;
        if (z80_div == 5'd23) begin
            z80_div <= 5'd0;
            z80_cen <= 1'b1;
        end else begin
            z80_div <= z80_div + 5'd1;
        end
    end
end

// ── Pixel clock enable (8 MHz = ÷12) ────────────────────────────────────────

logic [3:0] pix_div;
logic       pix_cen;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pix_div <= 4'd0;
        pix_cen <= 1'b0;
    end else begin
        pix_cen <= 1'b0;
        if (pix_div == 4'd11) begin
            pix_div <= 4'd0;
            pix_cen <= 1'b1;
        end else begin
            pix_div <= pix_div + 4'd1;
        end
    end
end

assign ce_pixel = pix_cen;

// =============================================================================
// Video Timing — 320×240, GP9001 standard (same as Toaplan V2 / Batsugun)
// Horizontal: 320 active + 24 FP + 32 sync + 40 BP = 416 total
// Vertical:   240 active + 12 FP +  4 sync +  8 BP = 264 total
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

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hpos_r   <= 9'h000;
        vpos_r   <= 9'h000;
        hsync_r  <= 1'b1;
        vsync_r  <= 1'b1;
        hblank_r <= 1'b0;
        vblank_r <= 1'b0;
    end else if (pix_cen) begin
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

wire [8:0] pix_hpos = (hpos_r < 9'(H_ACTIVE)) ? hpos_r : 9'h000;
wire [8:0] pix_vpos = (vpos_r < 9'(V_ACTIVE)) ? vpos_r : 9'h000;

// VBLANK rising-edge detection
logic vblank_prev;
logic vblank_rising;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) vblank_prev <= 1'b0;
    else        vblank_prev <= vblank_r;
end

assign vblank_rising = vblank_r & ~vblank_prev;

// =============================================================================
// Program ROM — 1MB internal BRAM (for sim; real hardware uses SDRAM)
// Loaded via ioctl when ioctl_index == 8'h00.
// 512K words × 16-bit = 1MB.
// =============================================================================

localparam int PROG_WORDS  = 512 * 1024;   // 512K words = 1MB
localparam int PROG_ABITS  = 19;           // $clog2(PROG_WORDS)

logic [15:0] prog_rom [0:PROG_WORDS-1];
logic [15:0] prog_rom_dout;

// ROM load: ioctl_index 0, word-addressed (ioctl_addr[24:1])
// ioctl_dout is 16-bit; ioctl_addr is byte address.
always_ff @(posedge clk) begin
    if (ioctl_wr && (ioctl_index == 8'h00))
        prog_rom[ioctl_addr[19:1]] <= ioctl_dout;
end

// ROM read (1-cycle registered)
always_ff @(posedge clk) begin
    prog_rom_dout <= prog_rom[cpu_addr[19:1]];
end

// =============================================================================
// Work RAM — 64KB synchronous block RAM at 0x100000–0x10FFFF
// =============================================================================

localparam int WRAM_WORDS = 32 * 1024;   // 32K words = 64KB
localparam int WRAM_ABITS = 15;          // $clog2(WRAM_WORDS)

logic [15:0] work_ram [0:WRAM_WORDS-1];
logic [15:0] wram_dout_r;

always_ff @(posedge clk) begin
    if (wram_cs && !cpu_rw) begin
        if (!cpu_uds_n) work_ram[cpu_addr[WRAM_ABITS:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) work_ram[cpu_addr[WRAM_ABITS:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

always_ff @(posedge clk) begin
    if (wram_cs) wram_dout_r <= work_ram[cpu_addr[WRAM_ABITS:1]];
end

// =============================================================================
// Z80 Shared RAM — 8KB (16KB byte space, byte-wide, 68K sees word interface)
// 68K at 0x218000–0x21BFFF (16KB byte range), Z80 at 0xC000–0xDFFF (8KB byte range)
// Both CPUs share the same 8KB data.  68K word-wide, byte-enables for odd/even.
// =============================================================================

localparam int SRAM_WORDS = 4 * 1024;    // 4K words = 8KB
localparam int SRAM_ABITS = 12;          // $clog2(SRAM_WORDS)

logic [15:0] shared_ram [0:SRAM_WORDS-1];
logic [15:0] sram_m68k_dout;
logic [7:0]  sram_z80_dout;

// 68K port: word-wide, byte-enable
always_ff @(posedge clk) begin
    if (sram_cs && !cpu_rw) begin
        if (!cpu_uds_n) shared_ram[cpu_addr[SRAM_ABITS:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) shared_ram[cpu_addr[SRAM_ABITS:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

always_ff @(posedge clk) begin
    if (sram_cs) sram_m68k_dout <= shared_ram[cpu_addr[SRAM_ABITS:1]];
end

// Z80 port: byte-wide at 0xC000–0xDFFF
// Z80 addr [12:0] → shared_ram word address [12:1], byte select [0]
always_ff @(posedge clk) begin
    if (z80_sram_cs && !z80_wr_n)
        shared_ram[z80_addr[12:1]] <= z80_addr[0] ?
            {z80_dout_cpu, shared_ram[z80_addr[12:1]][7:0]} :
            {shared_ram[z80_addr[12:1]][15:8], z80_dout_cpu};
end

always_ff @(posedge clk) begin
    if (z80_sram_cs)
        sram_z80_dout <= z80_addr[0] ?
            shared_ram[z80_addr[12:1]][15:8] :
            shared_ram[z80_addr[12:1]][7:0];
end

// =============================================================================
// Palette RAM — 2048 × 16-bit (4KB at 0x400000–0x400FFF)
// Format: XRRRRRGGGGGGBBBBB (R5G6B5 or similar; expand 5:5:5 to 8:8:8)
// =============================================================================

localparam int PALRAM_WORDS = 2048;
localparam int PALRAM_ABITS = 11;

logic [15:0] palette_ram [0:PALRAM_WORDS-1];
logic [15:0] palram_cpu_dout;
logic [15:0] pal_entry_r;

always_ff @(posedge clk) begin
    if (palram_cs && !cpu_rw) begin
        if (!cpu_uds_n) palette_ram[cpu_addr[PALRAM_ABITS:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) palette_ram[cpu_addr[PALRAM_ABITS:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

always_ff @(posedge clk) begin
    if (palram_cs) palram_cpu_dout <= palette_ram[cpu_addr[PALRAM_ABITS:1]];
end

// Pixel-domain palette lookup (GP9001 Gate 5 output = 8-bit palette index)
always_ff @(posedge clk) begin
    if (pix_cen) pal_entry_r <= palette_ram[{1'b0, final_color_w}];
end

// Expand R5G5B5 → R8G8B8 (replicate 3 MSBs into low 3 bits)
assign red   = {pal_entry_r[14:10], pal_entry_r[14:12]};
assign green = {pal_entry_r[9:5],   pal_entry_r[9:7]};
assign blue  = {pal_entry_r[4:0],   pal_entry_r[4:2]};

// =============================================================================
// Address Decode
// =============================================================================
//
// All addresses are word-addressed (cpu_addr = byte_addr >> 1).
//
//   Program ROM : byte 0x000000–0x0FFFFF → word 0x000000–0x07FFFF (addr[23:19]==5'b0)
//   Work RAM    : byte 0x100000–0x10FFFF → word 0x080000–0x087FFF (addr[23:15]==9'b000100000)
//   Shared RAM  : byte 0x218000–0x21BFFF → word 0x10C000–0x10DFFF (addr[23:12]==12'h10C or 10D)
//   I/O         : byte 0x21C000–0x21FFFF → word 0x10E000–0x10FFFF (addr[23:12]==12'h10E or 10F)
//   GP9001      : byte 0x300000–0x30000F → word 0x180000–0x180007 (addr[23:11]==13'h300>>1)
//   Palette RAM : byte 0x400000–0x400FFF → word 0x200000–0x2007FF (addr[23:11]==13'h200)
//   Sound latch : byte 0x600000–0x600001 → word 0x300000          (addr[23:1]==23'h300000)
//
// Note: Text VRAM (0x500000–0x503FFF) stubbed — returns 0xFFFF; writes ignored.

logic prog_cs;     // Program ROM
logic wram_cs;     // Work RAM
logic sram_cs;     // Z80/68K shared RAM
logic io_cs;       // I/O registers (IN1/IN2/SYS/DIP/JMPR)
logic gp9001_cs_n; // GP9001 VDP (active-low, matching gp9001 module convention)
logic palram_cs;   // Palette RAM
logic txtvram_cs;  // Text VRAM (stub)
logic sndlatch_cs; // Sound latch write (0x600000)

// Program ROM: byte 0x000000–0x0FFFFF → addr[23:19] == 5'b00000
assign prog_cs     = (cpu_addr[23:19] == 5'b00000) && !cpu_as_n;

// Work RAM: byte 0x100000–0x10FFFF → addr[23:15] == 9'b000100000
assign wram_cs     = (cpu_addr[23:15] == 9'b000100000) && !cpu_as_n;

// Shared RAM: byte 0x218000–0x21BFFF → addr[23:13] covers 0x10C000–0x10DFFF
// 0x218000>>1 = 0x10C000; 0x21BFFF>>1 = 0x10DFFF → addr[23:13] == 11'h86 (0x10C>>1=0x086)
// Simpler: addr[23:14] == 10'h086 (covers 0x218000–0x21BFFF)
assign sram_cs     = (cpu_addr[23:14] == 10'h086) && !cpu_as_n;

// I/O block: byte 0x21C000–0x21FFFF → addr[23:15] == 9'b000100001 (bit14=1)
// 0x21C000>>1=0x10E000; addr[23:14] = 10'h087
assign io_cs       = (cpu_addr[23:14] == 10'h087) && !cpu_as_n;

// GP9001: byte 0x300000–0x30000F → addr[23:11] == 13'h180 (0x300000>>1>>11 = 0x180)
assign gp9001_cs_n = !((cpu_addr[23:11] == 13'h180) && !cpu_as_n);

// Palette RAM: byte 0x400000–0x400FFF → addr[23:11] == 13'h200
assign palram_cs   = (cpu_addr[23:11] == 13'h200) && !cpu_as_n;

// Text VRAM: byte 0x500000–0x503FFF (stub only)
assign txtvram_cs  = (cpu_addr[23:14] == 10'h140) && !cpu_as_n;

// Sound latch: byte 0x600001 (write byte, lower byte to Z80)
assign sndlatch_cs = (cpu_addr[23:1] == 23'h300000) && !cpu_as_n;

// =============================================================================
// I/O Registers
// =============================================================================
// Inside the 0x21C000 window, individual registers are at:
//   0x21C020/1  IN1   addr[6:1]=5'h10
//   0x21C024/5  IN2   addr[6:1]=5'h12
//   0x21C028/9  SYS   addr[6:1]=5'h14
//   0x21C02C/D  DSWA  addr[6:1]=5'h16
//   0x21C030/1  DSWB  addr[6:1]=5'h18
//   0x21C034/5  JMPR  addr[6:1]=5'h1A
//   0x21C03C/D  VDP scanline counter addr[6:1]=5'h1E
//   0x21C01D    coin counter write (byte, ignored in stub)
//
// All return in low byte D[7:0]; upper byte D[15:8] = 0xFF (open bus).

// Joystick format: active-low
// joystick_0[5:0] = {B,A,R,L,D,U}, joystick_0[9:8] = {start,coin}
// Returns: [7]=1 [6]=1 [5]=B [4]=A [3]=R [2]=L [1]=D [0]=U
// SYS: [7]=1 [6]=service [5]=1 [4]=coin2 [3]=coin1 [2:0]=1

logic [7:0] io_dout_byte;
logic [5:0] scan_ctr;    // scanline counter for vdpcount_r

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) scan_ctr <= 6'd0;
    else if (pix_cen && (hpos_r == 9'd0)) begin
        if (vpos_r < 9'(V_ACTIVE))
            scan_ctr <= vpos_r[5:0];
        else
            scan_ctr <= 6'd0;
    end
end

always_comb begin
    io_dout_byte = 8'hFF;
    case (cpu_addr[6:1])
        // IN1: 0x21C020 — Player 1 {1,1,B,A,R,L,D,U} active-low
        6'h10: io_dout_byte = {2'b11, ~joystick_0[5], ~joystick_0[4],
                               ~joystick_0[3], ~joystick_0[2],
                               ~joystick_0[1], ~joystick_0[0]};
        // IN2: 0x21C024 — Player 2
        6'h12: io_dout_byte = {2'b11, ~joystick_1[5], ~joystick_1[4],
                               ~joystick_1[3], ~joystick_1[2],
                               ~joystick_1[1], ~joystick_1[0]};
        // SYS: 0x21C028 — coins/start/service
        6'h14: io_dout_byte = {1'b1, 1'b1,                     // bit7=1, bit6=service
                               ~joystick_0[9], ~joystick_1[9],  // start1, start2
                               ~joystick_0[8], ~joystick_1[8],  // coin1, coin2
                               2'b11};
        // DSWA: 0x21C02C
        6'h16: io_dout_byte = dipsw_a;
        // DSWB: 0x21C030
        6'h18: io_dout_byte = dipsw_b;
        // JMPR: 0x21C034 — jumper/region (stub: return all-1)
        6'h1A: io_dout_byte = 8'hFF;
        // VDP scanline counter: 0x21C03C
        6'h1E: io_dout_byte = {2'b00, scan_ctr};
        default: io_dout_byte = 8'hFF;
    endcase
end

// =============================================================================
// Sound Command Latch (68K → Z80)
// =============================================================================

logic [7:0] sound_cmd;
logic       sound_cmd_pending;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sound_cmd         <= 8'h00;
        sound_cmd_pending <= 1'b0;
    end else begin
        if (sndlatch_cs && !cpu_rw && !cpu_lds_n) begin
            sound_cmd         <= cpu_dout[7:0];
            sound_cmd_pending <= 1'b1;
        end else if (z80_soundlatch_ack) begin
            sound_cmd_pending <= 1'b0;
        end
    end
end

// =============================================================================
// GP9001 — Graphics Processor
// =============================================================================

// GP9001 outputs
logic [15:0] gp9001_dout;
logic        gp9001_irq_sprite;

// Gate 3 (BG tile) signals
logic [19:0] bg_rom_addr_raw;
logic [7:0]  bg_rom_data_r;
logic [3:0]  bg_layer_sel;

// Gate 4 (sprite) signals
logic [24:0] spr_rom_addr_raw;
logic        spr_rom_rd;
logic [7:0]  spr_rom_data_r;
logic [8:0]  spr_rd_addr_w;
logic [7:0]  spr_rd_color_w;
logic        spr_rd_valid_w;
logic        spr_rd_priority_w;
logic        spr_render_done_w;

// Gate 5 pixel output
logic [7:0]  final_color_w;
logic        final_valid_w;

/* verilator lint_off UNUSED */
// Gate 2 display list (not consumed at integration level)
logic [7:0]  display_list_count_w;
logic        display_list_ready_w;
logic [15:0] vram_dout_w;

// GP9001 register outputs (not consumed at integration level)
logic [7:0][15:0] scroll_w;
logic [15:0] scroll0_x_w, scroll0_y_w, scroll1_x_w, scroll1_y_w;
logic [15:0] scroll2_x_w, scroll2_y_w, scroll3_x_w, scroll3_y_w;
logic [15:0] rowscroll_ctrl_w, layer_ctrl_w, sprite_ctrl_w;
logic [15:0] layer_size_w, color_key_w, blend_ctrl_w;
logic [1:0]  num_layers_active_w, bg0_priority_w, bg1_priority_w, bg23_priority_w;
logic [3:0]  sprite_list_len_code_w;
logic [1:0]  sprite_sort_mode_w, sprite_prefetch_mode_w;
logic        sprite_en_w;
/* verilator lint_on UNUSED */

// Hblank falling edge → scan trigger for sprite rasterizer
logic hblank_prev;
logic scan_trigger_w;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) hblank_prev <= 1'b0;
    else        hblank_prev <= hblank_r;
end
assign scan_trigger_w = hblank_prev & ~hblank_r;

// Sprite RAM scan port (debug) — tied off
logic [9:0]  scan_addr_w;
logic [15:0] scan_dout_w;
assign scan_addr_w = 10'h000;

/* verilator lint_off UNUSED */
sprite_entry_t display_list_w [0:255];
/* verilator lint_on UNUSED */

assign spr_rd_addr_w = pix_hpos;

/* verilator lint_off MODMISSING */
gp9001 #(
    .NUM_LAYERS    (2),
    .OBJECTBANK_EN (0)   // Battle Garegga: no object bank
) u_gp9001 (
    .clk        (clk),
    .rst_n      (rst_n),

    // CPU interface (chip-relative 11-bit word address)
    .addr       (cpu_addr[11:1]),
    .din        (cpu_dout),
    .dout       (gp9001_dout),
    .cs_n       (gp9001_cs_n),
    .rd_n       ( cpu_rw ? 1'b0 : 1'b1),   // active-low read
    .wr_n       (!cpu_rw ? 1'b0 : 1'b1),   // active-low write

    // Video timing
    .vsync      (~vsync_r),    // active-high for GP9001
    .vblank     (vblank_r),

    // Interrupt output
    .irq_sprite (gp9001_irq_sprite),

    // Register outputs
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

    // Object bank switching (disabled for Battle Garegga)
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

    // Gate 5: Priority mixer output
    .final_color    (final_color_w),
    .final_valid    (final_valid_w)
);
/* verilator lint_on MODMISSING */

// Silence Gate 3/4 outputs not used at integration level
/* verilator lint_off UNUSED */
logic [3:0]       bg_pix_valid_w;
logic [3:0][7:0]  bg_pix_color_w;
logic [3:0]       bg_pix_priority_w;
/* verilator lint_on UNUSED */

// =============================================================================
// GFX ROM Bridge (stub — returns 0; real implementation uses SDRAM channel)
// =============================================================================
// In a full implementation, bg_rom_addr_raw and spr_rom_addr_raw drive SDRAM
// fetch requests and bg_rom_data_r / spr_rom_data_r carry the returned bytes.
// For now, return all zeros — GP9001 will render blank tiles.

assign bg_rom_data_r  = 8'h00;
assign spr_rom_data_r = 8'h00;

/* verilator lint_off UNUSED */
logic _gfx_unused;
assign _gfx_unused = &{1'b0, bg_rom_addr_raw, spr_rom_addr_raw, spr_rom_rd,
                        bg_layer_sel, vram_dout_w,
                        spr_rd_color_w, spr_rd_valid_w, spr_rd_priority_w,
                        spr_render_done_w, scan_dout_w,
                        display_list_count_w, display_list_ready_w,
                        final_valid_w,
                        scroll_w[0], scroll_w[1], scroll_w[2], scroll_w[3],
                        scroll_w[4], scroll_w[5], scroll_w[6], scroll_w[7],
                        scroll0_x_w, scroll0_y_w, scroll1_x_w, scroll1_y_w,
                        scroll2_x_w, scroll2_y_w, scroll3_x_w, scroll3_y_w,
                        rowscroll_ctrl_w, layer_ctrl_w, sprite_ctrl_w,
                        layer_size_w, color_key_w, blend_ctrl_w,
                        num_layers_active_w, bg0_priority_w, bg1_priority_w, bg23_priority_w,
                        sprite_list_len_code_w, sprite_sort_mode_w, sprite_prefetch_mode_w,
                        sprite_en_w,
                        bg_pix_valid_w,
                        bg_pix_color_w[0], bg_pix_color_w[1],
                        bg_pix_color_w[2], bg_pix_color_w[3],
                        bg_pix_priority_w,
                        pal_entry_r[15]};
/* verilator lint_on UNUSED */

// =============================================================================
// CPU Data Bus Read Mux
// =============================================================================
// Priority (highest → lowest):
//   GP9001 > Palette RAM > Shared RAM > I/O > Prog ROM > Work RAM > open bus

logic [15:0] cpu_din;

always_comb begin
    if (!gp9001_cs_n)
        cpu_din = gp9001_dout;
    else if (palram_cs)
        cpu_din = palram_cpu_dout;
    else if (sram_cs)
        cpu_din = sram_m68k_dout;
    else if (io_cs)
        cpu_din = {8'hFF, io_dout_byte};
    else if (txtvram_cs)
        cpu_din = 16'hFFFF;    // text VRAM stub
    else if (wram_cs)
        cpu_din = wram_dout_r;
    else if (prog_cs)
        cpu_din = prog_rom_dout;
    else
        cpu_din = 16'hFFFF;    // open bus
end

// =============================================================================
// DTACK Generation
// =============================================================================
// Fast devices (GP9001, palette, shared RAM, I/O, WRAM): 1-cycle DTACK
// Prog ROM (BRAM, 1-cycle): same
// Open bus: 2-cycle fallback

logic any_fast_cs;
logic dtack_r;
logic dtack_fallback_r;

assign any_fast_cs = !gp9001_cs_n | palram_cs | sram_cs | io_cs
                   | txtvram_cs | wram_cs | prog_cs | sndlatch_cs;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dtack_r          <= 1'b0;
        dtack_fallback_r <= 1'b0;
    end else begin
        dtack_r          <= any_fast_cs;
        dtack_fallback_r <= !cpu_as_n;
    end
end

logic cpu_dtack_n;
always_comb begin
    if (cpu_as_n)
        cpu_dtack_n = 1'b1;
    else if (any_fast_cs)
        cpu_dtack_n = !dtack_r;
    else
        cpu_dtack_n = !dtack_fallback_r;
end

// =============================================================================
// Interrupt (IPL) Generation — IACK pattern
// =============================================================================
// IRQ2 (VBLANK) → IPL 3'b101  (level 2, ~2 = 3'b101 active-low)
// IRQ1 (GP9001 sprite scan done) → IPL 3'b110  (level 1)
//
// Community pattern: SET on edge, CLEAR on IACK only. Never use a timer.
// IACK detection: FC[2:0] == 3'b111 AND !ASn

logic ipl_vbl_active;
logic ipl_spr_active;

// IACK signal derived from FC codes (driven by fx68k)
logic cpu_fc0, cpu_fc1, cpu_fc2;
logic cpu_inta_n;
assign cpu_inta_n = ~&{cpu_fc2, cpu_fc1, cpu_fc0, ~cpu_as_n_r};

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ipl_vbl_active <= 1'b0;
        ipl_spr_active <= 1'b0;
    end else begin
        // Clear on IACK (CPU acknowledges interrupt)
        if (!cpu_inta_n) begin
            ipl_vbl_active <= 1'b0;
            ipl_spr_active <= 1'b0;
        end

        // VBLANK rising edge → assert IRQ2
        if (vblank_rising)
            ipl_vbl_active <= 1'b1;

        // GP9001 sprite scan complete → assert IRQ1
        if (gp9001_irq_sprite)
            ipl_spr_active <= 1'b1;
    end
end

// IPL encoding (active-low):
//   Both active: VBLANK takes priority (higher level)
//   3'b101 = ~2 = level 2 (VBLANK)
//   3'b110 = ~1 = level 1 (sprite scan)
//   3'b111 = no interrupt
logic [2:0] ipl_n;
always_ff @(posedge clk) begin
    if (ipl_vbl_active)
        ipl_n <= 3'b101;
    else if (ipl_spr_active)
        ipl_n <= 3'b110;
    else
        ipl_n <= 3'b111;
end

// Registered cpu_as_n for IACK detection (avoid combinational loop through fx68k)
logic cpu_as_n_r;
always_ff @(posedge clk) cpu_as_n_r <= cpu_as_n;

// =============================================================================
// VPAn for autovectored interrupts
// =============================================================================
// During IACK (FC=111 & !ASn), VPAn must go low to autovector the interrupt.
// Without this, fx68k hangs waiting for DTACKn or VPAn during IACK.

logic cpu_vpan;
assign cpu_vpan = cpu_inta_n;   // VPAn = 0 during IACK = autovector

// =============================================================================
// fx68k — MC68000 CPU
// =============================================================================

logic        cpu_as_n;    // address strobe (active-low)
logic        cpu_uds_n;   // upper data strobe (active-low)
logic        cpu_lds_n;   // lower data strobe (active-low)
logic        cpu_rw;      // 1=read, 0=write
logic [23:1] cpu_addr;    // word address A23:A1
logic [15:0] cpu_dout;    // CPU → bus (write data)
logic        cpu_ohalted_n;
logic        cpu_oreset_n;
logic        cpu_bg_n;
logic        fx_E, fx_VMAn;   // 6800 signals (not used)

// Reset: extReset/pwrUp are active-high for fx68k
logic fx_reset, fx_pwrup;
assign fx_reset = !rst_n;
assign fx_pwrup = !rst_n;

/* verilator lint_off MODMISSING */
fx68k u_fx68k (
    .clk        (clk),
    .HALTn      (1'b1),
    .extReset   (fx_reset),
    .pwrUp      (fx_pwrup),
    .enPhi1     (enPhi1),
    .enPhi2     (enPhi2),

    // Bus outputs
    .eRWn       (cpu_rw),
    .ASn        (cpu_as_n),
    .LDSn       (cpu_lds_n),
    .UDSn       (cpu_uds_n),
    .E          (fx_E),
    .VMAn       (fx_VMAn),

    // Function codes (for IACK detection)
    .FC0        (cpu_fc0),
    .FC1        (cpu_fc1),
    .FC2        (cpu_fc2),

    // Bus arbitration
    .BGn        (cpu_bg_n),

    // Reset / halt outputs
    .oRESETn    (cpu_oreset_n),
    .oHALTEDn   (cpu_ohalted_n),

    // Bus inputs
    .DTACKn     (cpu_dtack_n),
    .VPAn       (cpu_vpan),        // autovector on IACK
    .BERRn      (1'b1),
    .BRn        (1'b1),
    .BGACKn     (1'b1),

    // Interrupt inputs (active-low)
    .IPL0n      (ipl_n[0]),
    .IPL1n      (ipl_n[1]),
    .IPL2n      (ipl_n[2]),

    // Data bus
    .iEdb       (cpu_din),
    .oEdb       (cpu_dout),

    // Address bus (word-granular)
    .eab        (cpu_addr)
);
/* verilator lint_on MODMISSING */

// =============================================================================
// Z80 Sound CPU — T80s
// =============================================================================
//
// Address map:
//   0x0000–0x7FFF   32KB fixed ROM (lower half of audio ROM)
//   0x8000–0xBFFF   16KB banked ROM (upper half, z80_audio_bank selects page)
//   0xC000–0xDFFF    8KB shared RAM (with 68K at 0x218000)
//   0xE000–0xE001       YM2151
//   0xE004              OKI M6295
//   0xE006–0xE008       GAL OKI bank registers
//   0xE00A              Audio ROM bank select
//   0xE00C              Sound latch acknowledge
//   0xE01C              Sound latch read
//   0xE01D              IRQ status (bgaregga_E01D_r)

// Z80 internal RAM (64-byte scratchpad — for E1xx addresses; stub)
logic [7:0]  z80_ram [0:255];
logic [7:0]  z80_ram_dout;

// Z80 audio ROM — 128KB in BRAM
localparam int SND_WORDS = 64 * 1024;
logic [7:0] snd_rom [0:SND_WORDS-1];

// Load sound ROM via ioctl_index == 8'h02
always_ff @(posedge clk) begin
    if (ioctl_wr && (ioctl_index == 8'h02)) begin
        snd_rom[{ioctl_addr[15:1], 1'b0}] <= ioctl_dout[7:0];
        snd_rom[{ioctl_addr[15:1], 1'b1}] <= ioctl_dout[15:8];
    end
end

logic [7:0] snd_rom_dout;

// Z80 control signals
logic        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
logic        z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
logic [15:0] z80_addr;
logic [7:0]  z80_dout_cpu;
logic        z80_wait_n;
logic        z80_int_n;    // driven by YM2151 irq_n

// Z80 chip selects (all MREQ-based)
logic z80_rom_cs;     // 0x0000–0xBFFF (fixed + banked)
logic z80_sram_cs;    // 0xC000–0xDFFF (shared RAM)
logic z80_ym_cs;      // 0xE000–0xE001 (YM2151)
logic z80_oki_cs;     // 0xE004        (OKI M6295)
logic z80_okibank_cs; // 0xE006–0xE008 (GAL OKI bank)
logic z80_audbank_cs; // 0xE00A        (audio ROM bank select)
logic z80_slatch_ack; // 0xE00C        (sound latch ack)
logic z80_slatch_rd;  // 0xE01C        (sound latch read)
logic z80_irqstat_cs; // 0xE01D        (IRQ status)
logic z80_soundlatch_ack;

always_comb begin
    z80_ym_cs      = (!z80_mreq_n) && (z80_addr[15:1] == 15'h7000);  // 0xE000-0xE001
    z80_oki_cs     = (!z80_mreq_n) && (z80_addr == 16'hE004);
    z80_okibank_cs = (!z80_mreq_n) && (z80_addr >= 16'hE006) && (z80_addr <= 16'hE008);
    z80_audbank_cs = (!z80_mreq_n) && (z80_addr == 16'hE00A);
    z80_slatch_ack = (!z80_mreq_n) && (z80_addr == 16'hE00C);
    z80_slatch_rd  = (!z80_mreq_n) && (z80_addr == 16'hE01C);
    z80_irqstat_cs = (!z80_mreq_n) && (z80_addr == 16'hE01D);
    z80_sram_cs    = (!z80_mreq_n) && (z80_addr[15:13] == 3'b110);   // 0xC000-0xDFFF
    z80_rom_cs     = (!z80_mreq_n) && (z80_addr[15] == 1'b0)         // 0x0000-0x7FFF fixed
                   || (!z80_mreq_n) && (z80_addr[15:14] == 2'b10);   // 0x8000-0xBFFF banked
end

assign z80_soundlatch_ack = z80_cen & z80_slatch_ack & !z80_wr_n;

// Z80 audio bank register
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        z80_audio_bank   <= 4'd0;
        z80_oki_bank_wr  <= 1'b0;
        z80_oki_bank_din <= 8'h00;
        z80_oki_bank_addr <= 2'd0;
    end else if (z80_cen) begin
        z80_oki_bank_wr <= 1'b0;
        if (z80_audbank_cs && !z80_wr_n)
            z80_audio_bank <= z80_dout_cpu[3:0];
        if (z80_okibank_cs && !z80_wr_n) begin
            z80_oki_bank_wr   <= 1'b1;
            z80_oki_bank_din  <= z80_dout_cpu;
            z80_oki_bank_addr <= z80_addr[1:0];  // 0=e006, 1=e007, 2=e008
        end
    end
end

// Z80 internal RAM (E page: 0xE000–0xE0FF, simple scratchpad for regs not decoded above)
always_ff @(posedge clk) begin
    if (!z80_mreq_n && (z80_addr[15:8] == 8'hE0) && !z80_wr_n)
        z80_ram[z80_addr[7:0]] <= z80_dout_cpu;
end
always_ff @(posedge clk) begin
    if (!z80_mreq_n && (z80_addr[15:8] == 8'hE0))
        z80_ram_dout <= z80_ram[z80_addr[7:0]];
end

// ROM read (banked: lower 32KB fixed, upper 16KB = audio_bank × 16KB)
// z80_addr[15:0]: 0x0000-0x7FFF → snd_rom[addr]
//                 0x8000-0xBFFF → snd_rom[{z80_audio_bank, addr[13:0]} + 0x8000 base]
// snd_rom is 128KB = 0x20000 bytes; 4-bit bank selects 16KB page in upper 96KB
// Layout: first 32KB = fixed; next 96KB = 6 pages of 16KB (bank 0..5 → 0x8000-0x9FFF, etc.)
logic [16:0] z80_rom_effective_addr;
always_comb begin
    if (z80_addr[15])
        // Banked: 0x8000-0xBFFF → bank selects which 16KB page starting at ROM offset 0x8000
        z80_rom_effective_addr = {1'b0, z80_audio_bank, z80_addr[12:0]} + 17'h8000;
    else
        z80_rom_effective_addr = {1'b0, z80_addr};
end

always_ff @(posedge clk) begin
    snd_rom_dout <= snd_rom[z80_rom_effective_addr[15:0]];
end

// Z80 bus WAIT — always ready in this stub (ROM is 1-cycle BRAM)
assign z80_wait_n = 1'b1;

// Z80 data bus mux
logic [7:0] z80_din_mux;

always_comb begin
    if (z80_ym_cs && !z80_rd_n)
        z80_din_mux = ym_dout;
    else if (z80_oki_cs && !z80_rd_n)
        z80_din_mux = m6295_dout;
    else if (z80_slatch_rd && !z80_rd_n)
        z80_din_mux = sound_cmd;
    else if (z80_irqstat_cs && !z80_rd_n)
        z80_din_mux = {7'h00, sound_cmd_pending};  // bit0 = latch pending
    else if (z80_sram_cs && !z80_rd_n)
        z80_din_mux = sram_z80_dout;
    else if (z80_rom_cs && !z80_rd_n)
        z80_din_mux = snd_rom_dout;
    else
        z80_din_mux = 8'hFF;
end

// Z80 interrupt: YM2151 irq_n drives Z80 INT
assign z80_int_n = ym_irq_n;

/* verilator lint_off MODMISSING */
T80s u_z80 (
    .RESET_n  (rst_n),
    .CLK      (clk),
    .CEN      (z80_cen),
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
/* verilator lint_on MODMISSING */

// =============================================================================
// YM2151 (jt51) — driven by Z80
// =============================================================================

wire        ym_cs_n  = ~z80_ym_cs;
wire        ym_wr_n  = z80_wr_n | ~z80_ym_cs;
wire        ym_a0    = z80_addr[0];
wire [7:0]  ym_din   = z80_dout_cpu;
wire [7:0]  ym_dout;
wire        ym_irq_n;

// YM2151 half-rate clock enable
logic ym_cen_p1_r;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)      ym_cen_p1_r <= 1'b0;
    else if (z80_cen) ym_cen_p1_r <= ~ym_cen_p1_r;
end
wire ym_cen_p1 = z80_cen & ym_cen_p1_r;

wire signed [15:0] ym_left_raw, ym_right_raw;
wire               ym_sample;

/* verilator lint_off MODMISSING */
jt51 u_jt51 (
    .rst        (~rst_n),
    .clk        (clk),
    .cen        (z80_cen),
    .cen_p1     (ym_cen_p1),
    .cs_n       (ym_cs_n),
    .wr_n       (ym_wr_n),
    .a0         (ym_a0),
    .din        (ym_din),
    .dout       (ym_dout),
    .ct1        (),
    .ct2        (),
    .irq_n      (ym_irq_n),
    .sample     (ym_sample),
    .left       (ym_left_raw),
    .right      (ym_right_raw),
    .xleft      (),
    .xright     ()
);
/* verilator lint_on MODMISSING */

// =============================================================================
// OKI M6295 (jt6295) — driven by Z80
// =============================================================================

wire        m6295_wrn  = z80_wr_n | ~z80_oki_cs;
wire [7:0]  m6295_din  = z80_dout_cpu;
wire [7:0]  m6295_dout;

// M6295 clock enable ~1 MHz (96 MHz ÷ 96 = 1 MHz)
logic [6:0] m6295_ce_cnt;
logic       m6295_cen;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        m6295_ce_cnt <= 7'd0;
        m6295_cen    <= 1'b0;
    end else begin
        if (m6295_ce_cnt == 7'd95) begin
            m6295_ce_cnt <= 7'd0;
            m6295_cen    <= 1'b1;
        end else begin
            m6295_ce_cnt <= m6295_ce_cnt + 7'd1;
            m6295_cen    <= 1'b0;
        end
    end
end

// ADPCM ROM address from jt6295 extended via GAL bank
wire [17:0]  m6295_rom_addr_raw;
wire [7:0]   m6295_rom_data_w;
wire         m6295_rom_ok_in;
wire signed [13:0] m6295_sound;
wire               m6295_sample;

assign oki_rom_addr_in = m6295_rom_addr_raw;

// OKI ROM data stub — returns 0 (real hardware reads from SDRAM)
assign m6295_rom_data_w = 8'h00;
assign m6295_rom_ok_in  = 1'b0;

/* verilator lint_off MODMISSING */
jt6295 u_jt6295 (
    .rst        (~rst_n),
    .clk        (clk),
    .cen        (m6295_cen),
    .ss         (1'b1),         // 8 kHz sample rate
    .wrn        (m6295_wrn),
    .din        (m6295_din),
    .dout       (m6295_dout),
    .rom_addr   (m6295_rom_addr_raw),
    .rom_data   (m6295_rom_data_w),
    .rom_ok     (m6295_rom_ok_in),
    .sound      (m6295_sound),
    .sample     (m6295_sample)
);
/* verilator lint_on MODMISSING */

// Audio mix: FM (16-bit) + ADPCM (14-bit sign-extended → 16-bit), half amplitude each
wire signed [15:0] adpcm_16 = {{2{m6295_sound[13]}}, m6295_sound};
assign audio_l = ($signed(ym_left_raw)  >> 1) + ($signed(adpcm_16) >> 1);
assign audio_r = ($signed(ym_right_raw) >> 1) + ($signed(adpcm_16) >> 1);

// =============================================================================
// GAL OKI Bank Switching
// =============================================================================

logic       z80_oki_bank_wr;
logic [1:0] z80_oki_bank_addr;
logic [7:0] z80_oki_bank_din;
logic [17:0] oki_rom_addr_in;
logic [21:0] oki_rom_addr_out;
logic [7:0][3:0] oki_bank_regs;
logic [3:0] z80_audio_bank;

/* verilator lint_off MODMISSING */
gal_oki_bank u_gal_oki_bank (
    .clk         (clk),
    .rst_n       (rst_n),
    .z80_wr      (z80_oki_bank_wr),
    .z80_addr    (z80_oki_bank_addr),
    .z80_din     (z80_oki_bank_din),
    .oki_addr    (oki_rom_addr_in),
    .rom_addr    (oki_rom_addr_out),
    .bank_regs   (oki_bank_regs)
);
/* verilator lint_on MODMISSING */

// =============================================================================
// Lint suppression for unused signals
// =============================================================================

/* verilator lint_off UNUSED */
logic _misc_unused;
assign _misc_unused = &{1'b0,
    cpu_bg_n, cpu_oreset_n, cpu_ohalted_n,
    fx_E, fx_VMAn,
    z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n, z80_iorq_n,
    ym_sample,
    m6295_sample,
    oki_rom_addr_out,
    oki_bank_regs,
    z80_ram_dout,
    gp9001_irq_sprite,
    cpu_inta_n,
    scan_ctr
};
/* verilator lint_on UNUSED */

endmodule
