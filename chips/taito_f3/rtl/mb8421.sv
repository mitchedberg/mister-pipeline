`default_nettype none
// =============================================================================
// MB8421 — Dual-Port RAM (2KB)
// =============================================================================
// Models the Fujitsu MB8421 true dual-port SRAM as used in Taito F3 for
// main CPU ↔ sound CPU communication.
//
// Physical device: 2KB × 8-bit (byte-wide), but each side accesses full words:
//   Left port  (main 68EC020):  32-bit wide, 512-entry × 4 bytes = 2KB
//   Right port (sound 68000):   16-bit wide, 1024-entry × 2 bytes = 2KB
//
// Address mapping:
//   Main CPU byte range 0xC00000–0xC007FF → left_addr[9:0] = cpu_addr[10:1]
//     (cpu_addr is word address, cpu_addr[10:1] selects 512 longwords × 4B)
//   Sound CPU byte range 0x140000–0x1407FF → right_addr[9:0] = sound_addr[10:1]
//     (right_addr[9:0] selects 1024 words × 2B)
//
// Both ports share the same underlying 2KB BRAM.  On FPGA this maps to one
// M10K block (Intel) or equivalent.  No interrupt logic needed for F3
// (MAME shows polling-only communication via MB8421).
//
// True dual-port semantics: simultaneous reads from both ports are fine.
// Simultaneous write to the same address: last writer wins (implementation-
// dependent; acceptable for F3 because the two CPUs coordinate via polling).
//
// MAME source: taito_en.cpp — maincpu_map 0xC00000, sound CPU 0x140000
// =============================================================================

module mb8421 (
    input  logic        clk,

    // ── Left Port — Main 68EC020 (32-bit bus) ────────────────────────────────
    input  logic        left_cs,        // chip select (active high)
    input  logic        left_we,        // write enable (1=write)
    input  logic [8:0]  left_addr,      // longword address: cpu_addr[9:1] (512 longwords = 2KB)
    input  logic [31:0] left_din,       // write data
    input  logic [3:0]  left_be_n,      // byte enables (active low) {D31:D24..D7:D0}
    output logic [31:0] left_dout,      // read data

    // ── Right Port — Sound 68000 (16-bit bus) ─────────────────────────────────
    input  logic        right_cs,       // chip select (active high)
    input  logic        right_we,       // write enable (1=write)
    input  logic [9:0]  right_addr,     // word address: sound_addr[10:1]
    input  logic [15:0] right_din,      // write data
    input  logic [1:0]  right_be_n,     // byte enables (active low) {D15:D8, D7:D0}
    output logic [15:0] right_dout      // read data
);

// =============================================================================
// Underlying storage: 2KB as 512 × 32-bit locations.
// The right port (16-bit) accesses word-halves of the same array:
//   right_addr[9:1] → selects which longword (256 longwords via bits[9:1])
//   right_addr[0]   → 0 = upper 16 bits [31:16], 1 = lower 16 bits [15:0]
// =============================================================================
logic [31:0] mem [0:511];   // 512 × 32-bit = 2KB

// =============================================================================
// Left port read/write (32-bit, synchronous)
// =============================================================================
always_ff @(posedge clk) begin
    if (left_cs) begin
        if (left_we) begin
            if (!left_be_n[3]) mem[left_addr][31:24] <= left_din[31:24];
            if (!left_be_n[2]) mem[left_addr][23:16] <= left_din[23:16];
            if (!left_be_n[1]) mem[left_addr][15:8]  <= left_din[15:8];
            if (!left_be_n[0]) mem[left_addr][7:0]   <= left_din[7:0];
        end
        left_dout <= mem[left_addr];
    end
end

// =============================================================================
// Right port read/write (16-bit, synchronous)
// right_addr[9:1] → longword index (bits 9:1 = upper 9 bits of 10-bit addr)
// right_addr[0]   → word half: 0 = upper [31:16], 1 = lower [15:0]
// =============================================================================
logic [8:0]  right_lw_idx;   // longword index into mem[]
logic        right_word_sel;  // 0=upper half, 1=lower half

assign right_lw_idx  = right_addr[9:1];
assign right_word_sel = right_addr[0];

always_ff @(posedge clk) begin
    if (right_cs) begin
        if (right_we) begin
            if (right_word_sel == 1'b0) begin
                // Write to upper half [31:16]
                if (!right_be_n[1]) mem[right_lw_idx][31:24] <= right_din[15:8];
                if (!right_be_n[0]) mem[right_lw_idx][23:16] <= right_din[7:0];
            end else begin
                // Write to lower half [15:0]
                if (!right_be_n[1]) mem[right_lw_idx][15:8] <= right_din[15:8];
                if (!right_be_n[0]) mem[right_lw_idx][7:0]  <= right_din[7:0];
            end
        end
        // Read: select appropriate 16-bit half
        right_dout <= right_word_sel ? mem[right_lw_idx][15:0]
                                     : mem[right_lw_idx][31:16];
    end
end

endmodule
