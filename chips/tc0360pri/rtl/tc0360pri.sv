`default_nettype none
// =============================================================================
// TC0360PRI — Taito Priority Manager
// =============================================================================
// 3-input priority mixer for Taito F2 arcade hardware.
//
// Accepts three 15-bit color inputs, each tagged with a 2-bit priority selector
// in bits [14:13]. Looks up the selector in per-input priority tables stored in
// an 8-register bank (offsets 4..9). Outputs the color from the highest-priority
// non-transparent input (palette index 0 = transparent).
//
// CPU Interface: 16 × 8-bit registers (byte-wide, offset 0x00..0x0F)
//   Reg 0x00: bits[7:6] = blend mode (0b11=mode1, 0b10=mode2, else=none)
//   Reg 0x04: {in0_pri1[3:0], in0_pri0[3:0]}  — Input 0 priority table low
//   Reg 0x05: {in0_pri3[3:0], in0_pri2[3:0]}  — Input 0 priority table high
//   Reg 0x06: {in1_pri1[3:0], in1_pri0[3:0]}  — Input 1 priority table low
//   Reg 0x07: {in1_pri3[3:0], in1_pri2[3:0]}  — Input 1 priority table high
//   Reg 0x08: {in2_pri1[3:0], in2_pri0[3:0]}  — Input 2 priority table low
//   Reg 0x09: {in2_pri3[3:0], in2_pri2[3:0]}  — Input 2 priority table high
//   Regs 0x01..0x03, 0x0A..0x0F: auxiliary / unused
//
// Color input encoding: color_inN = {sel[1:0], palette_idx[12:0]}
//   sel = priority level selector (0..3) for this pixel
//   palette_idx = 0 → transparent; non-zero → opaque
//
// Priority resolution:
//   1. For each input, read 4-bit priority value from table using sel
//   2. Transparent pixels (palette_idx==0) get effective priority 0
//   3. Among non-transparent inputs, output the highest-priority one
//   4. Tie-break: input 0 beats input 1 beats input 2
//
// Blend modes (reg[0][7:6]): partial palette mixing — future work.
//   Currently implemented as simple priority pass-through.
//
// MAME source: src/mame/taito/tc0360pri.cpp  (Nicola Salmoria)
// Games: all Taito F2 boards with 3-layer video (Chase H.Q., Growl, etc.)
// =============================================================================

module tc0360pri (
    input  logic        clk,
    input  logic        async_rst_n,

    // CPU interface (byte-wide, 4-bit address → 16 registers)
    input  logic        cpu_cs,
    input  logic        cpu_we,
    input  logic [ 3:0] cpu_addr,
    input  logic [ 7:0] cpu_din,
    output logic [ 7:0] cpu_dout,

    // Three 15-bit color inputs: {sel[1:0], palette_idx[12:0]}
    //   Input 0: tilemap layers (from TC0100SCN or similar)
    //   Input 1: sprites        (from TC0200OBJ or similar)
    //   Input 2: ROZ/other      (from TC0480SCP, TC0430GRW, or background)
    input  logic [14:0] color_in0,
    input  logic [14:0] color_in1,
    input  logic [14:0] color_in2,

    // Priority-resolved output (13-bit palette index)
    output logic [12:0] color_out
);

// =============================================================================
// Reset synchronizer (section5 pattern)
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// =============================================================================
// Register bank: 16 × 8-bit
// =============================================================================
logic [7:0] regs [0:15];

always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 16; i++) regs[i] <= 8'b0;
    end else if (cpu_cs & cpu_we) begin
        regs[cpu_addr] <= cpu_din;
    end
end

always_ff @(posedge clk) begin
    cpu_dout <= cpu_cs ? regs[cpu_addr] : 8'b0;
end

// =============================================================================
// Priority lookup combinational logic
// =============================================================================
// Extract 2-bit priority selectors from color inputs
logic [1:0] sel0, sel1, sel2;
assign sel0 = color_in0[14:13];
assign sel1 = color_in1[14:13];
assign sel2 = color_in2[14:13];

// Transparency: palette_idx == 0 → transparent
logic t0, t1, t2;
assign t0 = (color_in0[12:0] == 13'b0);
assign t1 = (color_in1[12:0] == 13'b0);
assign t2 = (color_in2[12:0] == 13'b0);

// Priority table lookup (inlined for Yosys compatibility):
//   Input 0 uses regs[4] (levels 0,1) and regs[5] (levels 2,3)
//   Input 1 uses regs[6] and regs[7]
//   Input 2 uses regs[8] and regs[9]
logic [3:0] raw_pri0, raw_pri1, raw_pri2;

always_comb begin
    case (sel0)
        2'd0: raw_pri0 = regs[4][3:0];
        2'd1: raw_pri0 = regs[4][7:4];
        2'd2: raw_pri0 = regs[5][3:0];
        2'd3: raw_pri0 = regs[5][7:4];
        default: raw_pri0 = 4'b0;
    endcase
end

always_comb begin
    case (sel1)
        2'd0: raw_pri1 = regs[6][3:0];
        2'd1: raw_pri1 = regs[6][7:4];
        2'd2: raw_pri1 = regs[7][3:0];
        2'd3: raw_pri1 = regs[7][7:4];
        default: raw_pri1 = 4'b0;
    endcase
end

always_comb begin
    case (sel2)
        2'd0: raw_pri2 = regs[8][3:0];
        2'd1: raw_pri2 = regs[8][7:4];
        2'd2: raw_pri2 = regs[9][3:0];
        2'd3: raw_pri2 = regs[9][7:4];
        default: raw_pri2 = 4'b0;
    endcase
end

// Effective priority: 0 for transparent pixels
logic [3:0] epri0, epri1, epri2;
assign epri0 = t0 ? 4'b0 : raw_pri0;
assign epri1 = t1 ? 4'b0 : raw_pri1;
assign epri2 = t2 ? 4'b0 : raw_pri2;

// =============================================================================
// Priority resolution: highest epri wins; ties broken by input order (0 > 1 > 2)
// =============================================================================
always_comb begin
    // Input 0 wins if it has the highest (or tied-highest) non-zero priority
    if (epri0 >= epri1 && epri0 >= epri2 && epri0 != 4'b0)
        color_out = color_in0[12:0];
    // Input 1 wins if it beats or ties input 2 (input 0 already lost above)
    else if (epri1 >= epri2 && epri1 != 4'b0)
        color_out = color_in1[12:0];
    // Input 2 wins if it has any non-zero priority
    else if (epri2 != 4'b0)
        color_out = color_in2[12:0];
    // All transparent → background (color 0)
    else
        color_out = 13'b0;
end

endmodule
