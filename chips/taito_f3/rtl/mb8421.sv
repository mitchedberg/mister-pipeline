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

logic [8:0]  right_lw_idx;    // longword index into mem[]
logic        right_word_sel;   // 0=upper half, 1=lower half
assign right_lw_idx  = right_addr[9:1];
assign right_word_sel = right_addr[0];

`ifdef QUARTUS
// Two DUAL_PORT altsyncram instances sharing port A (write).  M10K TDP with
// mixed port widths is not supported; we use 32-bit wide on all ports and
// reconstruct the 16-bit right-port value from the 32-bit read output.
//
// Write priority: left (32-bit) has priority over right (16-bit).
// Right write is converted to 32-bit with 4-bit byteena:
//   word_sel=0 (upper half [31:16]): data_a={right_din, 16'b0}, byteena={~be_n,2'b00}
//   word_sel=1 (lower half [15:0]): data_a={16'b0, right_din}, byteena={2'b00,~be_n}
logic        mb_we_left;
logic        mb_we_right;
logic        mb_we;
logic [8:0]  mb_wr_addr;
logic [31:0] mb_wr_data;
logic  [3:0] mb_be;
assign mb_we_left  = left_cs  & left_we;
assign mb_we_right = right_cs & right_we & ~mb_we_left;
assign mb_we       = mb_we_left | mb_we_right;
assign mb_wr_addr  = mb_we_left ? left_addr : right_lw_idx;
assign mb_wr_data  = mb_we_left ? left_din :
                     right_word_sel ? {16'b0, right_din} : {right_din, 16'b0};
assign mb_be       = mb_we_left ? ~left_be_n :
                     right_word_sel ? {2'b00, ~right_be_n} : {~right_be_n, 2'b00};

// Left read port (32-bit)
altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (32), .widthad_a (9), .numwords_a (512),
    .width_b                   (32), .widthad_b (9), .numwords_b (512),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (4), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) mb_left_inst (
    .clock0(clk), .clock1(clk),
    .address_a(mb_wr_addr), .data_a(mb_wr_data),
    .wren_a(mb_we),          .byteena_a(mb_be),
    .address_b(left_addr),   .q_b(left_dout),
    .wren_b(1'b0), .data_b(32'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(4'hF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// Right read port (32-bit raw; select 16-bit half post-register)
logic [31:0] right_rddata;
logic        right_word_sel_r;  // 1-cycle delayed word_sel to match altsyncram latency
always_ff @(posedge clk) right_word_sel_r <= right_word_sel;
assign right_dout = right_word_sel_r ? right_rddata[15:0] : right_rddata[31:16];

altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (32), .widthad_a (9), .numwords_a (512),
    .width_b                   (32), .widthad_b (9), .numwords_b (512),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (4), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) mb_right_inst (
    .clock0(clk), .clock1(clk),
    .address_a(mb_wr_addr),  .data_a(mb_wr_data),
    .wren_a(mb_we),           .byteena_a(mb_be),
    .address_b(right_lw_idx), .q_b(right_rddata),
    .wren_b(1'b0), .data_b(32'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(4'hF), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);
`else
logic [31:0] mem [0:511];   // 512 × 32-bit = 2KB

// Left port read/write (32-bit, synchronous)
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

// Right port read/write (16-bit, synchronous)
always_ff @(posedge clk) begin
    if (right_cs) begin
        if (right_we) begin
            if (right_word_sel == 1'b0) begin
                if (!right_be_n[1]) mem[right_lw_idx][31:24] <= right_din[15:8];
                if (!right_be_n[0]) mem[right_lw_idx][23:16] <= right_din[7:0];
            end else begin
                if (!right_be_n[1]) mem[right_lw_idx][15:8] <= right_din[15:8];
                if (!right_be_n[0]) mem[right_lw_idx][7:0]  <= right_din[7:0];
            end
        end
        right_dout <= right_word_sel ? mem[right_lw_idx][15:0]
                                     : mem[right_lw_idx][31:16];
    end
end
`endif

endmodule
