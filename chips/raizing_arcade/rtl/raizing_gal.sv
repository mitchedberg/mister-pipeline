`default_nettype none
// =============================================================================
// raizing_gal — Raizing/8ing GAL Bank Controller Top-Level Integration
// =============================================================================
//
// This module integrates the two GAL bank controller sub-modules used by
// Raizing arcade boards (RA9503 Battle Garegga, RA9704 Armed Police Batrider,
// RA9903 Battle Bakraid):
//
//   1. gal_oki_bank  — OKI M6295 ADPCM ROM bank switching
//      Implements the NMK112-compatible function performed by GAL16V8 chips
//      on the Raizing boards.  Z80 writes to 0xe006/e007/e008 set 8 × 4-bit
//      bank registers that extend the OKI 18-bit address to 22 bits.
//
//   2. gal_gp9001_tile_bank — GP9001 tile ROM SDRAM address adapter
//      Battle Garegga (OBJECTBANK_EN=0): passes GP9001 tile addresses directly
//      to SDRAM with a base offset. No banking needed.
//      Batrider/Bakraid (OBJECTBANK_EN=1): decodes 68K writes at 0x500000-
//      0x50000F and produces gp9001 obj_bank_wr pulses to program the GP9001's
//      internal 8-slot tile bank extension table.
//
// Reference: MAME src/mame/toaplan/raizing.cpp, psomashekar/Raizing_FPGA
//
// Parameters (select variant):
//   OBJECTBANK_EN — 0 for bgaregga, 1 for batrider/bbakraid
//   BG_ROM_BASE   — SDRAM byte offset of GP9001 tile ROM (game-specific)
//   SPR_ROM_BASE  — SDRAM byte offset of GP9001 sprite ROM (usually = BG_ROM_BASE)
//   BG_ADDR_W     — BG SDRAM address bus width (default 24, 16MB addressable)
//   SPR_ADDR_W    — Sprite SDRAM address bus width (default 25, 32MB addressable)
//
// Port descriptions:
//
//   clk, rst_n           — system clock and active-low async reset
//
//   ── OKI bank (Z80 → GAL → OKI ROM address) ────────────────────────────────
//   z80_oki_wr           — Z80 write strobe for OKI bank register port
//   z80_oki_addr [1:0]   — port offset: 0=0xe006, 1=0xe007, 2=0xe008
//   z80_oki_din  [7:0]   — Z80 write data
//   oki_rom_addr [17:0]  — OKI M6295 ROM address (from chip)
//   oki_sdram_addr[21:0] — Extended SDRAM address for OKI ADPCM data
//   oki_bank_regs[7:0][3:0] — All 8 bank register values (for debug/visibility)
//
//   ── GP9001 tile bank (68K → GAL → GP9001 obj_bank) ────────────────────────
//   m68k_gfxbank_wr      — 68K write strobe for tile bank registers
//                          (active only when OBJECTBANK_EN=1, batrider/bbakraid)
//   m68k_gfxbank_addr[3:0] — 68K byte address [3:0] at 0x500000
//   m68k_gfxbank_din [7:0] — 68K write data byte
//   gp9001_obj_bank_wr   — GP9001 obj_bank_wr output (1-cycle pulse)
//   gp9001_obj_bank_slot[2:0] — GP9001 obj_bank_slot (0..7)
//   gp9001_obj_bank_val [3:0] — GP9001 obj_bank_val (4-bit bank value)
//
//   ── GP9001 tile ROM address mapping ────────────────────────────────────────
//   gp9001_bg_rom_addr  [19:0] — BG tile ROM address from GP9001 (byte address)
//   gp9001_spr_rom_addr [24:0] — Sprite tile ROM address from GP9001
//   bg_sdram_addr  [BG_ADDR_W-1:0]  — Absolute SDRAM byte address for BG tile
//   spr_sdram_addr [SPR_ADDR_W-1:0] — Absolute SDRAM byte address for sprite
//
// =============================================================================

module raizing_gal #(
    // Variant select
    // 0 = Battle Garegga (RA9503) — direct tile addressing, OKI banking only
    // 1 = Batrider (RA9704) / Battle Bakraid (RA9903) — 8-slot GP9001 tile bank
    parameter bit          OBJECTBANK_EN = 0,

    // SDRAM base address for GP9001 tile ROM pool (byte address)
    // bgaregga:  GFX loaded at SDRAM 0x100000 → 27'h100000
    // batrider:  GFX loaded at SDRAM 0x200000 → 27'h200000
    parameter logic [26:0] BG_ROM_BASE   = 27'h100000,
    parameter logic [26:0] SPR_ROM_BASE  = 27'h100000,

    // SDRAM tile address bus widths
    parameter int          BG_ADDR_W     = 24,
    parameter int          SPR_ADDR_W    = 25
) (
    input  logic        clk,
    input  logic        rst_n,

    // ── OKI M6295 bank registers (Z80 writes 0xe006/e007/e008) ────────────────
    input  logic        z80_oki_wr,          // Z80 write strobe
    input  logic [1:0]  z80_oki_addr,        // port offset (0/1/2)
    input  logic [7:0]  z80_oki_din,         // Z80 data byte
    input  logic [17:0] oki_rom_addr,        // OKI M6295 ROM address
    output logic [21:0] oki_sdram_addr,      // banked ROM address (22-bit)
    output logic [7:0][3:0] oki_bank_regs,   // bank register visibility

    // ── GP9001 tile bank registers (68K writes 0x500000-0x50000F) ─────────────
    // (only used when OBJECTBANK_EN=1; tie to 0 for bgaregga)
    input  logic        m68k_gfxbank_wr,     // 68K write strobe
    input  logic [3:0]  m68k_gfxbank_addr,   // 68K byte address [3:0]
    input  logic [7:0]  m68k_gfxbank_din,    // 68K data byte

    // GP9001 obj_bank programming outputs (to gp9001.sv)
    output logic        gp9001_obj_bank_wr,
    output logic [2:0]  gp9001_obj_bank_slot,
    output logic [3:0]  gp9001_obj_bank_val,

    // ── GP9001 tile ROM address mapping ────────────────────────────────────────
    input  logic [19:0] gp9001_bg_rom_addr,   // from GP9001
    input  logic [24:0] gp9001_spr_rom_addr,  // from GP9001

    output logic [BG_ADDR_W-1:0]  bg_sdram_addr,   // to SDRAM BG channel
    output logic [SPR_ADDR_W-1:0] spr_sdram_addr   // to SDRAM sprite channel
);

    // =========================================================================
    // Sub-module instantiations
    // =========================================================================

    // ── OKI M6295 GAL bank controller ─────────────────────────────────────────
    gal_oki_bank u_gal_oki_bank (
        .clk       (clk),
        .rst_n     (rst_n),
        .z80_wr    (z80_oki_wr),
        .z80_addr  (z80_oki_addr),
        .z80_din   (z80_oki_din),
        .oki_addr  (oki_rom_addr),
        .rom_addr  (oki_sdram_addr),
        .bank_regs (oki_bank_regs)
    );

    // ── GP9001 tile ROM bank / address adapter ─────────────────────────────────
    gal_gp9001_tile_bank #(
        .OBJECTBANK_EN (OBJECTBANK_EN),
        .BG_ROM_BASE   (BG_ROM_BASE),
        .SPR_ROM_BASE  (SPR_ROM_BASE),
        .BG_ADDR_W     (BG_ADDR_W),
        .SPR_ADDR_W    (SPR_ADDR_W)
    ) u_gal_gp9001_tile_bank (
        .clk             (clk),
        .rst_n           (rst_n),
        .m68k_wr         (m68k_gfxbank_wr),
        .m68k_addr       (m68k_gfxbank_addr),
        .m68k_din        (m68k_gfxbank_din),
        .obj_bank_wr     (gp9001_obj_bank_wr),
        .obj_bank_slot   (gp9001_obj_bank_slot),
        .obj_bank_val    (gp9001_obj_bank_val),
        .bg_rom_addr_in  (gp9001_bg_rom_addr),
        .spr_rom_addr_in (gp9001_spr_rom_addr),
        .bg_sdram_addr   (bg_sdram_addr),
        .spr_sdram_addr  (spr_sdram_addr)
    );

endmodule
