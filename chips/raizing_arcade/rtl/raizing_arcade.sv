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
// Memory map (68000) — from MAME common_mem + bgaregga_68k_mem:
//   0x000000 - 0x0FFFFF   1MB    Program ROM (SDRAM bank 0)
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
// GAL banking (KEY DIFFERENCE from batsugun/Toaplan2):
//   The GP9001 tile ROMs are directly mapped (8MB, no banking needed).
//   The GAL chips implement OKI ADPCM ROM banking only (not tile ROM banking).
//   See gal_oki_bank.sv for full implementation details.
//
//   Compared to sstriker/mahoudai (which have a simple 1-bit OKI bank):
//     - bgaregga uses 3 GAL bank registers controlling 8 × 4-bit banks
//     - This allows addressing up to 8 × 16 × 32KB = 4MB of ADPCM samples
//     - The actual bgaregga ROM is 1MB (0x100000 bytes)
//
//   Compared to batrider/bbakraid (which have an NMK112):
//     - bgaregga uses a GAL that mimics the NMK112 behavior
//     - The register interface is identical (same Z80 addresses, same data format)
//     - The FPGA implementation is therefore the same gal_oki_bank.sv module
//
// GP9001 variant:
//   Battle Garegga uses a single GP9001 with standard (non-OBJECTBANK) tile addressing.
//   The GP9001 tile ROM is 8MB (4 × 2MB ROMs loaded at 0x000000, 0x200000, 0x400000, 0x600000).
//   No object bank switching is needed (OBJECTBANK_EN=0).
//   This is in contrast to Batrider/Bakraid which have OBJECTBANK_EN=1 for 8-slot tile banks.
//
// SDRAM layout (for MiSTer ioctl ROM loading):
//   ROM index 0 (CPU):  0x000000 - 0x0FFFFF  1MB   68K program ROM
//   ROM index 1 (GFX):  0x100000 - 0x8FFFFF  8MB   GP9001 tile ROM (4 × 2MB)
//   ROM index 2 (SND):  0x900000 - 0x91FFFF  128KB  Z80 audio ROM (bgaregga snd.bin)
//   ROM index 3 (OKI):  0x920000 - 0xA1FFFF  1MB   OKI ADPCM samples
//   ROM index 4 (TXT):  0xA20000 - 0xA27FFF  32KB  Text tilemap ROM
//
// =============================================================================

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

    // =========================================================================
    // Clock enable generation
    // 96 MHz base → CPU 16 MHz (div 6) → 6-cycle enable
    //            → Z80  4 MHz (div 24) → 24-cycle enable
    //            → VDP 27/4 MHz pixel clock (fractional)
    // =========================================================================

    // 16 MHz enable for 68000: one pulse every 6 clk cycles
    logic [2:0] cpu_div;
    logic       cpu_cen;   // rising edge enable (enPhi1)
    logic       cpu_cenb;  // falling edge enable (enPhi2, one cycle after cpu_cen)
    logic       cpu_phi;   // toggles at 8 MHz

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_div  <= 3'd0;
            cpu_phi  <= 1'b0;
            cpu_cen  <= 1'b0;
            cpu_cenb <= 1'b0;
        end else begin
            cpu_cen  <= 1'b0;
            cpu_cenb <= 1'b0;
            if (cpu_div == 3'd5) begin
                cpu_div  <= 3'd0;
                cpu_phi  <= ~cpu_phi;
                if (!cpu_phi) cpu_cen  <= 1'b1;  // falling phi → enPhi1 rising
                else          cpu_cenb <= 1'b1;  // rising phi  → enPhi2 falling
            end else begin
                cpu_div <= cpu_div + 3'd1;
            end
        end
    end

    // 4 MHz enable for Z80: one pulse every 24 clk cycles
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

    // =========================================================================
    // GAL OKI bank switching
    //
    // The Z80 writes to Z80 addresses 0xe006, 0xe007, 0xe008 to set bank
    // registers that extend the OKI M6295 ROM address. This module implements
    // the behavior of the GAL chips on the RA9503 board.
    //
    // Instantiated here in the system top so it sits between the Z80 address
    // decoder and the OKI ROM SDRAM channel.
    // =========================================================================

    // Z80 OKI bank write strobes (generated by Z80 address decoder)
    logic       z80_oki_bank_wr;      // write strobe for gal_oki_bank
    logic [1:0] z80_oki_bank_addr;   // port offset: 0=e006, 1=e007, 2=e008
    logic [7:0] z80_oki_bank_din;    // Z80 data bus

    // OKI ROM address extension
    logic [17:0] oki_rom_addr_in;    // from OKI M6295 chip
    logic [21:0] oki_rom_addr_out;   // extended (banked) address to SDRAM

    // Debug: all 8 bank register values (4 bits each)
    logic [7:0][3:0] oki_bank_regs;

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

    // =========================================================================
    // Z80 audio bank register (separate from OKI bank)
    // Z80 writes to 0xE00A to select 16KB page of audio ROM (4-bit, 8 pages)
    // =========================================================================

    logic [3:0] z80_audio_bank;  // selects 16KB bank from 128KB Z80 audio ROM

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            z80_audio_bank <= 4'd0;
        end else if (z80_cen) begin
            // Z80 address decoder sets z80_audiobank_wr when Z80 writes to 0xE00A
            // (wired from Z80 address decoder instantiated in a full implementation)
            // Placeholder: bank register held at reset value until Z80 decoder added
        end
    end

    // =========================================================================
    // Lint suppression — ports not yet connected in this scaffold
    // These will be connected when CPU/video/audio subsystems are instantiated.
    // =========================================================================

    // Tie outputs to safe defaults for scaffold stage
    assign ioctl_wait = 1'b0;
    assign red        = 8'h00;
    assign green      = 8'h00;
    assign blue       = 8'h00;
    assign hsync_n    = 1'b1;
    assign vsync_n    = 1'b1;
    assign hblank     = 1'b0;
    assign vblank     = 1'b0;
    assign ce_pixel   = 1'b0;
    assign audio_l    = 16'h0000;
    assign audio_r    = 16'h0000;
    assign sdram_a    = 13'h0;
    assign sdram_ba   = 2'b00;
    assign sdram_cas_n = 1'b1;
    assign sdram_ras_n = 1'b1;
    assign sdram_we_n  = 1'b1;
    assign sdram_cs_n  = 1'b1;
    assign sdram_dqm   = 2'b11;
    assign sdram_cke   = 1'b1;

    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = &{1'b0,
        ioctl_wr, ioctl_addr, ioctl_dout, ioctl_index,
        joystick_0, joystick_1, dipsw_a, dipsw_b,
        cpu_cen, cpu_cenb, z80_cen,
        z80_oki_bank_wr, z80_oki_bank_addr, z80_oki_bank_din,
        oki_rom_addr_in,
        oki_bank_regs,
        z80_audio_bank,
        oki_rom_addr_out
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
