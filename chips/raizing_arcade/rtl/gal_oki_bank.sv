`default_nettype none
// =============================================================================
// gal_oki_bank — Raizing/8ing GAL-based OKI M6295 ROM bank controller
// =============================================================================
//
// Background (from MAME src/mame/toaplan/raizing.cpp, line 151):
//   "bgaregga and batrider don't actually have a NMK112, but rather a GAL
//    programmed to bankswitch the sound ROMs in a similar fashion."
//
// The GAL implements the same function as an NMK112: it maintains 8 × 4-bit
// bank registers that select which 64KB page of the OKI ROM is presented in
// each of the 8 × 32KB regions of the OKI M6295's 256KB address window.
//
// Hardware bank register write protocol (from MAME raizing_oki_bankswitch_w):
//   Z80 writes to offsets 0x00, 0x01, 0x02 (Z80 addresses 0xe006, 0xe007, 0xe008).
//   Each write packs two 4-bit bank values:
//     offset 0x00 (0xe006): din[3:0] → bank[0], din[7:4] → bank[1]
//     offset 0x01 (0xe007): din[3:0] → bank[2], din[7:4] → bank[3]
//     offset 0x02 (0xe008): din[3:0] → bank[4..6], din[7:4] → bank[5..7]
//
//   Banks 0-3 are the primary bank table. Banks 4-7 mirror banks 0-3
//   (they receive the same values simultaneously). On real hardware, this
//   means the OKI sees the same bank in both halves of the 256KB window,
//   allowing single-bank ROMs to be used without needing a second set of
//   bank registers.
//
// MAME raizing_oki_bankswitch_w detail:
//   The function is called once per Z80 write. offset = port_address & 0x03.
//   For each call:
//     chip   = (offset & 4) >> 2  (always 0 for bgaregga, 1 chip)
//     slot   = offset & 3
//     bank[slot]   = data[3:0]
//     bank[4+slot] = data[3:0]   (mirror)
//     slot++
//     bank[slot]   = data[7:4]
//     bank[4+slot] = data[7:4]   (mirror)
//
//   So a write to e006 (offset=0) sets: bank[0]=data[3:0], bank[4]=data[3:0],
//                                        bank[1]=data[7:4], bank[5]=data[7:4]
//      a write to e007 (offset=1) sets: bank[1]=data[3:0], bank[5]=data[3:0],
//                                        bank[2]=data[7:4], bank[6]=data[7:4]
//      a write to e008 (offset=2) sets: bank[2]=data[3:0], bank[6]=data[3:0],
//                                        bank[3]=data[7:4], bank[7]=data[7:4]
//
// ROM address extension:
//   The OKI M6295 internally uses an 18-bit address (256KB window).
//   The GAL maps each 32KB region (oki_addr[17:15] = region 0..7) to a
//   64KB page: full_rom_addr = {bank[region], oki_addr[14:0]}, giving a
//   19-bit final address (512KB range per region, 8 regions = up to 4MB).
//   With a 4-bit bank register, ROM window = 16 × 32KB = 512KB per region.
//
// Port descriptions:
//   clk        — system clock (same domain as Z80)
//   rst_n      — active-low reset (clears all banks to 0)
//   z80_wr     — Z80 write strobe (1-cycle pulse, active-high)
//   z80_addr   — Z80 address [1:0] (bits [1:0] of the Z80 address bus, i.e.
//                port offset 0..2 corresponding to e006/e007/e008)
//   z80_din    — Z80 write data [7:0]
//   oki_addr   — OKI M6295 ROM address [17:0] (from chip)
//   rom_addr   — Extended ROM address [21:0] (to SDRAM/ROM)
//   bank_regs  — Debug output: all 8 bank register values
//
// =============================================================================

module gal_oki_bank (
    input  logic        clk,
    input  logic        rst_n,

    // Z80 write interface (active on z80_wr pulse)
    input  logic        z80_wr,          // write strobe (1 cycle)
    input  logic [1:0]  z80_addr,        // port offset: 0=e006, 1=e007, 2=e008
    input  logic [7:0]  z80_din,         // data written by Z80

    // OKI ROM address interface
    input  logic [17:0] oki_addr,        // OKI M6295 ROM address (256KB window)
    output logic [21:0] rom_addr,        // Extended ROM address (22-bit, 4MB max)

    // Debug/visibility output
    output logic [7:0][3:0] bank_regs    // All 8 bank register values
);

    // =========================================================================
    // Bank register file: 8 slots × 4 bits
    // Reset state: all banks = 0 (points to first 32KB page of ROM)
    // =========================================================================

    logic [3:0] bank [0:7];

    integer b;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (b = 0; b < 8; b++) bank[b] <= 4'h0;
        end else if (z80_wr) begin
            // Each write sets two adjacent bank slots from the two nibbles of the
            // data byte, and simultaneously mirrors the values to slots 0-3 vs 4-7.
            //
            // MAME raizing_oki_bankswitch_w maps offset → slots:
            //   offset 0 (e006): data[3:0] → bank[0] & bank[4],  data[7:4] → bank[1] & bank[5]
            //   offset 1 (e007): data[3:0] → bank[1] & bank[5],  data[7:4] → bank[2] & bank[6]
            //   offset 2 (e008): data[3:0] → bank[2] & bank[6],  data[7:4] → bank[3] & bank[7]
            //
            // Primary slot index = z80_addr[1:0] (0, 1, or 2)
            // Secondary slot = primary + 1 (wraps within 0-3 range for lo/hi nibbles)
            // Both primary and primary+4 get the same value (mirror pattern).

            case (z80_addr[1:0])
                2'd0: begin  // Z80 port 0xe006
                    bank[0] <= z80_din[3:0];   // primary lo nibble
                    bank[4] <= z80_din[3:0];   // mirror
                    bank[1] <= z80_din[7:4];   // primary hi nibble
                    bank[5] <= z80_din[7:4];   // mirror
                end
                2'd1: begin  // Z80 port 0xe007
                    bank[1] <= z80_din[3:0];
                    bank[5] <= z80_din[3:0];
                    bank[2] <= z80_din[7:4];
                    bank[6] <= z80_din[7:4];
                end
                2'd2: begin  // Z80 port 0xe008
                    bank[2] <= z80_din[3:0];
                    bank[6] <= z80_din[3:0];
                    bank[3] <= z80_din[7:4];
                    bank[7] <= z80_din[7:4];
                end
                default: ;  // offset 3 not used in bgaregga
            endcase
        end
    end

    // =========================================================================
    // ROM address extension
    //
    // OKI M6295 presents 18-bit address (256KB window).
    // Bits [17:15] = region select (0..7) → maps to one of 8 bank registers.
    // Full ROM address = {bank[region], oki_addr[14:0]}
    //   = 4 + 15 = 19 bits minimum.
    //
    // For Battle Garegga, the OKI ROM is 1MB (0x100000 bytes).
    // With 4-bit bank and 15-bit page offset: max address = 0x3_FFFF (256KB × 16 banks)
    // Extended to 22 bits to allow future ROM sizes.
    // =========================================================================

    logic [2:0] region;
    assign region = oki_addr[17:15];  // 3-bit region index

    logic [3:0] active_bank;
    assign active_bank = bank[region];

    // Final address: {bank[3:0], oki_addr[14:0]} = 19-bit, zero-extended to 22
    assign rom_addr = {3'b000, active_bank, oki_addr[14:0]};

    // =========================================================================
    // Debug output — expose all bank register values
    // =========================================================================

    generate
        genvar i;
        for (i = 0; i < 8; i++) begin : gen_bank_out
            assign bank_regs[i] = bank[i];
        end
    endgenerate

endmodule
