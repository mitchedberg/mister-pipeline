// v60_alu.sv — NEC V60 ALU
// Parameterized by WIDTH (8, 16, 32).
// Flags: Z (zero), S (sign), OV (overflow), CY (carry)
//
// MAME reference: v60.cpp macros ADDB/ADDW/ADDL, SUBB/SUBW/SUBL,
//   ORB/ORW/ORL, ANDB/ANDW/ANDL, XORB/XORW/XORL, SetSZPF_*, SetOF*
//
// All arithmetic is combinational; the calling FSM registers results.

`default_nettype none
`timescale 1ns/1ps

module v60_alu #(
    parameter WIDTH = 32
) (
    // Operation select
    input  logic [3:0]         op,          // see ALU_OP_* below
    // Operands
    input  logic [WIDTH-1:0]   a,           // source operand (op1)
    input  logic [WIDTH-1:0]   b,           // dest operand (op2, modified in place)
    input  logic               carry_in,    // for ADC/SBC
    // Results
    output logic [WIDTH-1:0]   result,
    output logic               flag_z,      // zero
    output logic               flag_s,      // sign (MSB of result)
    output logic               flag_ov,     // overflow (signed)
    output logic               flag_cy      // carry/borrow (unsigned)
);

    // ALU operation codes
    localparam ALU_ADD  = 4'd0;   // result = b + a + carry_in
    localparam ALU_SUB  = 4'd1;   // result = b - a - carry_in
    localparam ALU_AND  = 4'd2;   // result = b & a
    localparam ALU_OR   = 4'd3;   // result = b | a
    localparam ALU_XOR  = 4'd4;   // result = b ^ a
    localparam ALU_NOT  = 4'd5;   // result = ~b
    localparam ALU_NEG  = 4'd6;   // result = -b (two's complement)
    localparam ALU_PASS = 4'd7;   // result = a (pass-through for MOV)
    localparam ALU_SHL  = 4'd8;   // result = b << a[4:0]
    localparam ALU_SHR  = 4'd9;   // result = b >> a[4:0] (logical)
    localparam ALU_SAR  = 4'd10;  // result = b >>> a[4:0] (arithmetic)
    localparam ALU_CMP  = 4'd11;  // flags from b - a, no write
    localparam ALU_ROL  = 4'd12;  // rotate left
    localparam ALU_ROR  = 4'd13;  // rotate right

    // Extended width for carry detection
    logic [WIDTH:0]   add_ext;
    logic [WIDTH:0]   sub_ext;
    logic [WIDTH-1:0] shift_result;
    logic [$clog2(WIDTH)-1:0] shamt;

    assign shamt = a[$clog2(WIDTH)-1:0];

    always_comb begin
        result   = '0;
        flag_z   = 1'b0;
        flag_s   = 1'b0;
        flag_ov  = 1'b0;
        flag_cy  = 1'b0;

        // Extend for carry arithmetic
        add_ext = {1'b0, b} + {1'b0, a} + {{WIDTH{1'b0}}, carry_in};
        sub_ext = {1'b0, b} - {1'b0, a} - {{WIDTH{1'b0}}, carry_in};

        case (op)
            // -------------------------------------------------------
            // ADD: result = b + a + carry_in
            // MAME: ADDB(dst,src,c) / ADDW / ADDL
            //   SetCFB(res): CY = res[8]
            //   SetOFB_Add(res,src,dst): OV = ((res^src)&(res^dst)&0x80) != 0
            ALU_ADD: begin
                result  = add_ext[WIDTH-1:0];
                flag_cy = add_ext[WIDTH];
                // Overflow: both operands same sign, result different sign
                flag_ov = (b[WIDTH-1] == a[WIDTH-1]) && (result[WIDTH-1] != a[WIDTH-1]);
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // SUB: result = b - a - carry_in
            // MAME: SUBB(dst,src,c) / SUBW / SUBL
            //   SetOFB_Sub(res,src,dst): OV = ((src^dst)&(src^res)&msb) != 0
            //   Translated: overflow when signs differ and result sign differs from dst
            ALU_SUB,
            ALU_CMP: begin
                result  = sub_ext[WIDTH-1:0];
                flag_cy = sub_ext[WIDTH];   // borrow
                // Overflow: operands different sign, result sign differs from b
                flag_ov = (b[WIDTH-1] != a[WIDTH-1]) && (result[WIDTH-1] != b[WIDTH-1]);
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
                // For CMP, result is discarded by caller (no writeback)
            end

            // -------------------------------------------------------
            // AND: result = b & a
            // MAME: ANDB(dst,src) — OV=0, SetSZPF_Byte(dst)
            ALU_AND: begin
                result  = b & a;
                flag_ov = 1'b0;
                flag_cy = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // OR: result = b | a
            // MAME: ORB(dst,src) — OV=0, SetSZPF_Byte(dst)
            ALU_OR: begin
                result  = b | a;
                flag_ov = 1'b0;
                flag_cy = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // XOR: result = b ^ a
            // MAME: XORB(dst,src) — OV=0, SetSZPF_Byte(dst)
            ALU_XOR: begin
                result  = b ^ a;
                flag_ov = 1'b0;
                flag_cy = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // NOT: result = ~b  (MAME: opNOTB/H/W)
            ALU_NOT: begin
                result  = ~b;
                flag_ov = 1'b0;
                flag_cy = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // NEG: result = 0 - b  (MAME: opNEGB/H/W — uses SUB)
            ALU_NEG: begin
                result  = (~b) + {{WIDTH-1{1'b0}}, 1'b1};
                flag_cy = (b != '0);   // CY=1 unless b==0
                flag_ov = (b[WIDTH-1] == 1'b1) && (result[WIDTH-1] == 1'b1);
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // PASS (MOV): result = a, no flags updated
            ALU_PASS: begin
                result  = a;
                // MOV does not update flags in V60
                flag_ov = 1'b0;
                flag_cy = 1'b0;
                flag_s  = 1'b0;
                flag_z  = 1'b0;
            end

            // -------------------------------------------------------
            // SHL: logical left shift
            // MAME: opSHLB/H/W — uses SHA (arithmetic) for left shifts
            ALU_SHL: begin
                result  = b << shamt;
                flag_cy = (shamt != 0) ? b[WIDTH - shamt] : 1'b0;
                flag_ov = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // SHR: logical right shift
            ALU_SHR: begin
                result  = b >> shamt;
                flag_cy = (shamt != 0) ? b[shamt-1] : 1'b0;
                flag_ov = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // SAR: arithmetic right shift (sign-extended)
            ALU_SAR: begin
                result  = WIDTH'($signed(b) >> shamt);
                flag_cy = (shamt != 0) ? b[shamt-1] : 1'b0;
                flag_ov = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // ROL: rotate left through WIDTH bits
            ALU_ROL: begin
                result  = (b << shamt) | (b >> (WIDTH - shamt));
                flag_cy = result[0];
                flag_ov = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            // -------------------------------------------------------
            // ROR: rotate right through WIDTH bits
            ALU_ROR: begin
                result  = (b >> shamt) | (b << (WIDTH - shamt));
                flag_cy = result[WIDTH-1];
                flag_ov = 1'b0;
                flag_s  = result[WIDTH-1];
                flag_z  = (result == '0);
            end

            default: begin
                result  = '0;
                flag_ov = 1'b0;
                flag_cy = 1'b0;
                flag_s  = 1'b0;
                flag_z  = 1'b0;
            end
        endcase
    end

    // Expose the op constants as parameters for callers
    // (they can also just use the numeric values)

endmodule : v60_alu

`default_nettype wire
