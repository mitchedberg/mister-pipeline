`default_nettype none
// =============================================================================
// gal_gp9001_tile_bank — GP9001 Tile ROM Bank Address Adapter
// =============================================================================
//
// Background (from MAME src/mame/toaplan/raizing.cpp):
//
//   Battle Garegga (RA9503):
//     - Single GP9001, OBJECTBANK_EN=0 (no tile bank extension)
//     - BG tile ROM: 8MB (4 × 2MB), 20-bit address space, directly mapped
//       bg_rom_addr is a 20-bit byte address into the 8MB tile ROM region.
//     - Sprite tile ROM: same 8MB ROM pool, 25-bit address (tile*128 + row*8 + byte)
//       With no banking, only the lower 23 bits are active (8MB = 2^23).
//     - No GAL logic needed for GP9001 tile address — direct SDRAM passthrough.
//
//   Armed Police Batrider (RA9704) / Battle Bakraid (RA9903):
//     - Single GP9001, OBJECTBANK_EN=1 (8-slot object bank table)
//     - BG tile ROM: 12-14MB (6-7 × 2MB), same structure as bgaregga but larger
//     - Sprite tile ROM: 12-14MB. GP9001 generates 25-bit spr_rom_addr, of which
//       the upper 4 bits come from the bank table: {bank[3:0], tile_10bit, ...}
//     - CPU at 0x500000–0x50000F programs 8 × 4-bit bank registers via 68K:
//         address[3:1] = slot index (0..7, word-addressed)
//         data[3:0]    = bank value (replaces upper 4 bits of tile code)
//         data[7:4]    = next slot's bank value (packed 2-per-write)
//       The 68K driver uses byte-wide writes to 0x500000 step 2:
//         write to 0x500000: data[3:0]→bank[0], data[7:4]→bank[1]
//         write to 0x500002: data[3:0]→bank[2], data[7:4]→bank[3]
//         write to 0x500004: data[3:0]→bank[4], data[7:4]→bank[5]
//         write to 0x500006: data[3:0]→bank[6], data[7:4]→bank[7]
//       This matches the GP9001 obj_bank_wr / obj_bank_slot / obj_bank_val
//       interface on gp9001.sv.  This module converts the 68K write interface
//       to those three signals.
//
// This module has two functions:
//
//  1. Decode 68K writes to 0x500000-0x50000F into GP9001 obj_bank_wr pulses
//     (Batrider/Bakraid only — gate-disabled for bgaregga via OBJECTBANK_EN=0)
//
//  2. Map the GP9001's 20-bit bg_rom_addr and 25-bit spr_rom_addr to the
//     correct SDRAM address for the system's tile ROM region.
//     Both variants offset the ROM base by the SDRAM layout (system parameter).
//
// Port descriptions:
//
//   clk            — system clock
//   rst_n          — active-low reset
//
//   -- 68K object bank register write interface (Batrider/Bakraid only) --------
//   m68k_wr        — 68K write strobe (1-cycle pulse, active-high)
//   m68k_addr      — byte address [3:0] (bits 3:0 of 68K address bus)
//                    valid range: 0x00..0x0F (maps to bank slots 0..7 in pairs)
//   m68k_din       — 68K write data [7:0] (lo nibble = even slot, hi nibble = odd)
//
//   -- GP9001 obj_bank register interface (to gp9001.sv) ----------------------
//   obj_bank_wr    — write strobe to GP9001 (1-cycle)
//   obj_bank_slot  — slot index [2:0] (0..7)
//   obj_bank_val   — 4-bit bank value to write
//
//   -- GP9001 tile ROM address interface ---------------------------------------
//   bg_rom_addr_in   — 20-bit BG tile ROM address from GP9001
//   spr_rom_addr_in  — 25-bit sprite tile ROM address from GP9001
//
//   -- SDRAM tile ROM address output ------------------------------------------
//   bg_sdram_addr    — SDRAM byte address for BG tile data  [BG_ADDR_W-1:0]
//   spr_sdram_addr   — SDRAM byte address for sprite data   [SPR_ADDR_W-1:0]
//
//   -- Parameters -------------------------------------------------------------
//   OBJECTBANK_EN    — 0=bgaregga (direct addr), 1=batrider/bakraid (bank table)
//   BG_ROM_BASE      — SDRAM byte offset where BG tile ROM begins
//   SPR_ROM_BASE     — SDRAM byte offset where sprite tile ROM begins
//                      (For bgaregga/batrider, BG and SPR share the same ROM pool)
//
// =============================================================================

module gal_gp9001_tile_bank #(
    // 0 = Battle Garegga (no object bank), 1 = Batrider/Bakraid (8-slot bank)
    parameter bit         OBJECTBANK_EN  = 0,

    // SDRAM base addresses for tile ROMs (byte addresses)
    // Battle Garegga layout:  GFX at SDRAM 0x100000 (ROM index 1)
    // Batrider layout:        GFX at SDRAM 0x200000 (ROM index 1)
    parameter logic [26:0] BG_ROM_BASE   = 27'h100000,
    parameter logic [26:0] SPR_ROM_BASE  = 27'h100000,

    // Address widths for SDRAM outputs (must fit BG_ROM_BASE + tile ROM size)
    parameter int          BG_ADDR_W     = 24,  // 16MB SDRAM addressable
    parameter int          SPR_ADDR_W    = 25   // 32MB SDRAM addressable
) (
    input  logic        clk,
    input  logic        rst_n,

    // ── 68K object bank write interface (active when OBJECTBANK_EN=1) ──────────
    input  logic        m68k_wr,           // 68K write strobe (1 cycle, active-high)
    input  logic [3:0]  m68k_addr,         // 68K byte address [3:0] (0x0, 0x2, 0x4, 0x6)
    input  logic [7:0]  m68k_din,          // 68K data byte

    // ── GP9001 obj_bank register drive outputs ─────────────────────────────────
    output logic        obj_bank_wr,       // GP9001 obj_bank_wr (1-cycle pulse)
    output logic [2:0]  obj_bank_slot,     // GP9001 obj_bank_slot (0..7)
    output logic [3:0]  obj_bank_val,      // GP9001 obj_bank_val (4-bit bank)

    // ── GP9001 tile ROM addresses (inputs from GP9001) ─────────────────────────
    input  logic [19:0] bg_rom_addr_in,    // 20-bit BG tile ROM byte address
    input  logic [24:0] spr_rom_addr_in,   // 25-bit sprite tile ROM byte address

    // ── SDRAM tile ROM address outputs ─────────────────────────────────────────
    output logic [BG_ADDR_W-1:0]  bg_sdram_addr,   // absolute SDRAM byte address for BG tile
    output logic [SPR_ADDR_W-1:0] spr_sdram_addr   // absolute SDRAM byte address for sprite tile
);

    // =========================================================================
    // 68K Object Bank Decoder (Batrider/Bakraid, OBJECTBANK_EN=1)
    //
    // The 68K at address 0x500000–0x50000F writes packed bank register pairs.
    // m68k_addr[3:1] = word offset (0..7); each write encodes two slots:
    //   word 0 (addr byte 0x0): lo nibble→slot0, hi nibble→slot1
    //   word 1 (addr byte 0x2): lo nibble→slot2, hi nibble→slot3
    //   word 2 (addr byte 0x4): lo nibble→slot4, hi nibble→slot5
    //   word 3 (addr byte 0x6): lo nibble→slot6, hi nibble→slot7
    //
    // Each 68K write produces TWO consecutive GP9001 obj_bank_wr pulses
    // to program both slots. A small 2-state FSM handles this.
    // =========================================================================

    // Pending secondary pulse state
    logic        pending_wr;       // 1 = need to emit second slot write
    logic [2:0]  pending_slot;     // slot index for second write
    logic [3:0]  pending_val;      // bank value for second write

    // Primary slot index from m68k_addr[3:1]: {1'b0, m68k_addr[3:2], 1'b0}
    // word offset * 2 = first of two consecutive slots
    // e.g., addr=0x0 → word=0 → slots 0,1; addr=0x2 → word=1 → slots 2,3
    logic [2:0] first_slot;
    always_comb first_slot = {m68k_addr[3:2], 1'b0};  // word_offset * 2

    generate
        if (OBJECTBANK_EN) begin : gen_obj_bank_decode

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    obj_bank_wr   <= 1'b0;
                    obj_bank_slot <= 3'b0;
                    obj_bank_val  <= 4'b0;
                    pending_wr    <= 1'b0;
                    pending_slot  <= 3'b0;
                    pending_val   <= 4'b0;
                end else begin
                    obj_bank_wr <= 1'b0;  // default: no write

                    if (m68k_wr) begin
                        // Emit first slot write immediately
                        obj_bank_wr   <= 1'b1;
                        obj_bank_slot <= first_slot;
                        obj_bank_val  <= m68k_din[3:0];
                        // Latch second slot for next cycle
                        pending_wr    <= 1'b1;
                        pending_slot  <= first_slot + 3'd1;
                        pending_val   <= m68k_din[7:4];
                    end else if (pending_wr) begin
                        // Emit second slot write
                        obj_bank_wr   <= 1'b1;
                        obj_bank_slot <= pending_slot;
                        obj_bank_val  <= pending_val;
                        pending_wr    <= 1'b0;
                    end
                end
            end

        end else begin : gen_obj_bank_tie
            // Battle Garegga: no object bank, tie outputs to 0
            always_comb begin
                obj_bank_wr   = 1'b0;
                obj_bank_slot = 3'b0;
                obj_bank_val  = 4'b0;
                pending_wr    = 1'b0;  // unused in this branch; silences latch warning
                pending_slot  = 3'b0;
                pending_val   = 4'b0;
            end
        end
    endgenerate

    // =========================================================================
    // Tile ROM Address Mapping
    //
    // The GP9001 outputs raw tile ROM byte addresses.  These need to be offset
    // by the SDRAM base address where the tile ROM was loaded during ioctl_download.
    //
    // BG tile address:
    //   bg_sdram_addr = BG_ROM_BASE + bg_rom_addr_in
    //   Battle Garegga: base=0x100000, addr range 0..0x7FFFFF → SDRAM 0x100000..0x8FFFFF
    //   Batrider:       base=0x200000, addr range 0..0xBFFFFF → SDRAM 0x200000..0xDFFFFF
    //
    // Sprite tile address:
    //   spr_sdram_addr = SPR_ROM_BASE + spr_rom_addr_in
    //   For bgaregga/batrider, BG and sprite tile ROMs share the same ROM pool,
    //   so BG_ROM_BASE == SPR_ROM_BASE.
    //   The GP9001 already accounts for the bank extension in spr_rom_addr_in when
    //   OBJECTBANK_EN=1 (full 25-bit address). This module does not re-bank here.
    //
    // Note: bg_rom_addr_in and spr_rom_addr_in are combinational outputs from GP9001.
    // These address outputs are registered one cycle at the system level (SDRAM
    // request latency).  No additional pipelining is done here.
    // =========================================================================

    assign bg_sdram_addr  = BG_ADDR_W'(BG_ROM_BASE)  + BG_ADDR_W'(bg_rom_addr_in);
    assign spr_sdram_addr = SPR_ADDR_W'(SPR_ROM_BASE) + SPR_ADDR_W'(spr_rom_addr_in);

    // =========================================================================
    // Lint suppression — m68k_wr/addr/din are unused when OBJECTBANK_EN=0
    // =========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = &{1'b0,
        m68k_wr, m68k_addr, m68k_din,  // tied off when OBJECTBANK_EN=0
        first_slot                       // combinational decode of m68k_addr
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
