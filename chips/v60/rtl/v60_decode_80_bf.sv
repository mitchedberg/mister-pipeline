// v60_decode_80_bf.sv — V60 opcode decode sub-module for opcodes 0x80-0xBF
//
// Pure combinational decode. See v60_decode_pkg.sv for bundle definition.

`default_nettype none
`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHCONCAT */

import v60_decode_pkg::*;

module v60_decode_80_bf (
    input  logic [7:0]  ibuf [0:9],
    input  logic [31:0] reg_file [0:63],
    input  logic        f_z, f_s, f_ov, f_cy,
    output v60_decode_t d
);

    localparam [6:0]
        S_FETCH0   = 7'd1,
        S_EXECUTE  = 7'd22,
        S_TRAP     = 7'd28;

    localparam [3:0]
        ALU_ADD  = 4'd0,  ALU_SUB  = 4'd1,  ALU_AND  = 4'd2,
        ALU_OR   = 4'd3,  ALU_XOR  = 4'd4,  ALU_NOT  = 4'd5,
        ALU_NEG  = 4'd6,  ALU_PASS = 4'd7,  ALU_SHL  = 4'd8,
        ALU_SHR  = 4'd9,  ALU_SAR  = 4'd10, ALU_CMP  = 4'd11,
        ALU_ROL  = 4'd12, ALU_ROR  = 4'd13;

    localparam [4:0]
        EXT_MUL  = 5'd0,  EXT_MULU = 5'd1,  EXT_DIV  = 5'd2,
        EXT_DIVU = 5'd3,  EXT_SHA  = 5'd4,  EXT_SHL  = 5'd5,
        EXT_SETF = 5'd6,  EXT_LDPR = 5'd7,  EXT_STPR = 5'd8,
        EXT_ROT  = 5'd14, EXT_TEST1 = 5'd18;

    // decode_am (same implementation)
    task automatic decode_am(
        input  int           offset,
        input  logic [1:0]   sz,
        input  logic         modm,
        input  logic [31:0]  pc_val,
        output logic         is_reg,
        output logic         is_imm,
        output logic [31:0]  am_val,
        output int           am_bytes
    );
        logic [7:0] mv;  logic [5:0] rn;  logic [2:0] grp;
        logic [7:0] mv2; logic [5:0] rn2;
        mv=ibuf[offset]; grp=mv[7:5]; rn={1'b0,mv[4:0]};
        mv2=(offset+1<=9)?ibuf[offset+1]:8'h00; rn2={1'b0,mv2[4:0]};
        is_reg=1'b0; is_imm=1'b0; am_val=32'h0; am_bytes=1;
        if (!modm) begin
            case (grp)
                3'd0: begin am_val=reg_file[rn]+{{24{ibuf[offset+1][7]}},ibuf[offset+1]}; am_bytes=2; end
                3'd1: begin am_val=reg_file[rn]+{{16{ibuf[offset+2][7]}},ibuf[offset+2],ibuf[offset+1]}; am_bytes=3; end
                3'd2: begin am_val=reg_file[rn]+{ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                3'd3: begin am_val=reg_file[rn]; am_bytes=1; end
                3'd4: begin am_val=reg_file[rn]+{{24{ibuf[offset+1][7]}},ibuf[offset+1]}; am_bytes=2; end
                3'd5: begin am_val=reg_file[rn]+{{16{ibuf[offset+2][7]}},ibuf[offset+2],ibuf[offset+1]}; am_bytes=3; end
                3'd6: begin am_val=reg_file[rn]+{ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                3'd7: begin
                    case (mv[4:0])
                        5'h00,5'h01,5'h02,5'h03,5'h04,5'h05,5'h06,5'h07,
                        5'h08,5'h09,5'h0a,5'h0b,5'h0c,5'h0d,5'h0e,5'h0f:
                            begin is_imm=1'b1; am_val={28'd0,mv[3:0]}; am_bytes=1; end
                        5'h10: begin am_val=pc_val+{{24{ibuf[offset+1][7]}},ibuf[offset+1]}; am_bytes=2; end
                        5'h11: begin am_val=pc_val+{{16{ibuf[offset+2][7]}},ibuf[offset+2],ibuf[offset+1]}; am_bytes=3; end
                        5'h12: begin am_val=pc_val+{ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                        5'h13: begin am_val={ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                        5'h14: begin is_imm=1'b1;
                            case(sz)
                                2'd0: begin am_val={24'd0,ibuf[offset+1]}; am_bytes=2; end
                                2'd1: begin am_val={16'd0,ibuf[offset+2],ibuf[offset+1]}; am_bytes=3; end
                                default: begin am_val={ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                            endcase
                        end
                        5'h18: begin am_val=pc_val+{{24{ibuf[offset+1][7]}},ibuf[offset+1]}; am_bytes=2; end
                        5'h19: begin am_val=pc_val+{{16{ibuf[offset+2][7]}},ibuf[offset+2],ibuf[offset+1]}; am_bytes=3; end
                        5'h1a: begin am_val=pc_val+{ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                        5'h1b: begin am_val={ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                        5'h1c: begin am_val=pc_val+{{24{ibuf[offset+1][7]}},ibuf[offset+1]}; am_bytes=3; end
                        5'h1d: begin am_val=pc_val+{{16{ibuf[offset+2][7]}},ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                        5'h1e: begin am_val=pc_val+{ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=9; end
                        default: begin am_val={ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                    endcase
                end
            endcase
        end else begin
            case (grp)
                3'd0: begin am_val=reg_file[rn]+{{24{ibuf[offset+1][7]}},ibuf[offset+1]}; am_bytes=3; end
                3'd1: begin am_val=reg_file[rn]+{{16{ibuf[offset+2][7]}},ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                3'd2: begin am_val=reg_file[rn]+{ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=9; end
                3'd3: begin is_reg=1'b1; am_val={26'd0,rn}; am_bytes=1; end
                3'd4: begin am_val=reg_file[rn]; am_bytes=1; end
                3'd5: begin case(sz) 2'd0:am_val=reg_file[rn]-32'd1; 2'd1:am_val=reg_file[rn]-32'd2; default:am_val=reg_file[rn]-32'd4; endcase am_bytes=1; end
                3'd6: begin
                    case(mv2[7:5])
                        3'd0: begin case(sz) 2'd0:am_val=reg_file[rn]+{24'd0,ibuf[offset+2]}+reg_file[rn2]; 2'd1:am_val=reg_file[rn]+{24'd0,ibuf[offset+2]}+(reg_file[rn2]<<1); 2'd2:am_val=reg_file[rn]+{24'd0,ibuf[offset+2]}+(reg_file[rn2]<<2); default:am_val=reg_file[rn]+reg_file[rn2]; endcase am_bytes=3; end
                        3'd1: begin case(sz) 2'd0:am_val=reg_file[rn]+{{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]}+reg_file[rn2]; 2'd1:am_val=reg_file[rn]+{{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]}+(reg_file[rn2]<<1); 2'd2:am_val=reg_file[rn]+{{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]}+(reg_file[rn2]<<2); default:am_val=reg_file[rn]+reg_file[rn2]; endcase am_bytes=4; end
                        3'd2: begin case(sz) 2'd0:am_val=reg_file[rn]+{ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]}+reg_file[rn2]; 2'd1:am_val=reg_file[rn]+{ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]}+(reg_file[rn2]<<1); 2'd2:am_val=reg_file[rn]+{ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]}+(reg_file[rn2]<<2); default:am_val=reg_file[rn]+reg_file[rn2]; endcase am_bytes=6; end
                        3'd3: begin case(sz) 2'd0:am_val=reg_file[rn]+reg_file[rn2]; 2'd1:am_val=reg_file[rn]+(reg_file[rn2]<<1); 2'd2:am_val=reg_file[rn]+(reg_file[rn2]<<2); default:am_val=reg_file[rn]+reg_file[rn2]; endcase am_bytes=2; end
                        default: begin am_val=reg_file[rn]+{24'd0,ibuf[offset+2]}+reg_file[rn2]; am_bytes=3; end
                    endcase
                end
                default: begin am_val=32'h0; am_bytes=1; end
            endcase
        end
    endtask

    function automatic v60_decode_t decode_zero();
        decode_zero = '{default: '0};
        decode_zero.next_state = S_TRAP;
    endfunction

    function automatic v60_decode_t exec2(
        input logic [3:0] alu, input logic [1:0] sz,
        input logic upd_flags, input logic is_ext, input logic [4:0] ext
    );
        exec2 = decode_zero();
        exec2.next_state = S_EXECUTE; exec2.op_alu_op = alu; exec2.op_size = sz;
        exec2.op_has_am2 = 1'b1; exec2.op_update_flags = upd_flags;
        exec2.op_is_branch = 1'b0; exec2.op_is_single_am = 1'b0;
        exec2.op_no_am = 1'b0; exec2.op_is_ext = is_ext; exec2.op_ext_op = ext;
    endfunction

    always_comb begin
        d = decode_zero();

        case (ibuf[0])

            // ======================================================
            // 0x80/82/84 — ADD.B/H/W
            // ======================================================
            8'h80: begin d = exec2(ALU_ADD, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'h82: begin d = exec2(ALU_ADD, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'h84: begin d = exec2(ALU_ADD, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0x81/83/85 — MUL.B/H/W
            // ======================================================
            8'h81: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_MUL); end
            8'h83: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_MUL); end
            8'h85: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_MUL); end

            // ======================================================
            // 0x86 — MULX / 0x96 — MULUY
            // ======================================================
            8'h86, 8'h96: begin : blk_mulx
                logic        mx_is_reg1, mx_is_imm1;
                logic        mx_is_reg2, mx_is_imm2;
                logic [31:0] mx_op1, mx_op2;
                int          mx_len1, mx_len2;
                logic [63:0] mx_result;
                logic [31:0] mx_next_pc;

                d = decode_zero();

                if (ibuf[1][7]) begin
                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                              mx_is_reg1, mx_is_imm1, mx_op1, mx_len1);
                    decode_am(2+mx_len1, 2'd2, ibuf[1][5], reg_file[32],
                              mx_is_reg2, mx_is_imm2, mx_op2, mx_len2);
                    mx_next_pc = reg_file[32] + 32'd2 + mx_len1 + mx_len2;
                end else if (ibuf[1][5]) begin
                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                              mx_is_reg1, mx_is_imm1, mx_op1, mx_len1);
                    mx_op2 = {27'd0, ibuf[1][4:0]};
                    mx_is_reg2 = 1'b1; mx_is_imm2 = 1'b0; mx_len2 = 0;
                    mx_next_pc = reg_file[32] + 32'd2 + mx_len1;
                end else begin
                    mx_op1 = reg_file[{1'b0, ibuf[1][4:0]}];
                    mx_is_reg1 = 1'b1; mx_is_imm1 = 1'b0; mx_len1 = 0;
                    decode_am(2, 2'd2, ibuf[1][5], reg_file[32],
                              mx_is_reg2, mx_is_imm2, mx_op2, mx_len2);
                    mx_next_pc = reg_file[32] + 32'd2 + mx_len2;
                end
                if (mx_is_reg1) mx_op1 = reg_file[mx_op1[4:0]];
                if (ibuf[0] == 8'h86)
                    mx_result = $signed(mx_op1) * $signed(
                        mx_is_reg2 ? reg_file[mx_op2[4:0]] : mx_op2);
                else
                    mx_result = {32'd0, mx_op1} * {32'd0,
                        mx_is_reg2 ? reg_file[mx_op2[4:0]] : mx_op2};

                d.next_state = S_FETCH0;
                d.pc_en = 1'b1; d.pc_val = mx_next_pc;
                d.flg_update = 1'b1;
                d.flg_s  = mx_result[63];
                d.flg_z  = (mx_result == 64'd0);
                d.flg_ov = 1'b0;
                d.flg_cy = 1'b0;

                if (mx_is_reg2) begin : inner_mulx_wb
                    logic [4:0] mx_rn;
                    mx_rn = mx_op2[4:0];
                    d.rw0_en  = 1'b1;
                    d.rw0_idx = {1'b0, mx_rn};
                    d.rw0_val = mx_result[31:0];
                    d.rw1_en  = 1'b1;
                    d.rw1_idx = {1'b0, mx_rn} + 6'd1;
                    d.rw1_val = mx_result[63:32];
                end
            end

            // ======================================================
            // 0x87 — TEST1
            // ======================================================
            8'h87: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_TEST1); end

            // ======================================================
            // 0x88/8A/8C — OR.B/H/W
            // ======================================================
            8'h88: begin d = exec2(ALU_OR, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'h8A: begin d = exec2(ALU_OR, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'h8C: begin d = exec2(ALU_OR, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0x89/8B/8D — CMP.B/H/W — no writeback (flags only)
            // ======================================================
            8'h89: begin d = exec2(ALU_CMP, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'h8B: begin d = exec2(ALU_CMP, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'h8D: begin d = exec2(ALU_CMP, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0x90/92/94 — ADDC.B/H/W (stub as ADD)
            // ======================================================
            8'h90: begin d = exec2(ALU_ADD, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'h92: begin d = exec2(ALU_ADD, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'h94: begin d = exec2(ALU_ADD, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0x91/93/95 — MULU.B/H/W
            // ======================================================
            8'h91: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_MULU); end
            8'h93: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_MULU); end
            8'h95: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_MULU); end

            // ======================================================
            // 0x97 — SET1 (stub)
            // ======================================================
            8'h97: begin d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0); end

            // ======================================================
            // 0x98/9A/9C — SUBC.B/H/W (stub as SUB)
            // ======================================================
            8'h98: begin d = exec2(ALU_SUB, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'h9A: begin d = exec2(ALU_SUB, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'h9C: begin d = exec2(ALU_SUB, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0x99/9B/9D — ROTC.B/H/W (stub as ROT)
            // ======================================================
            8'h99: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_ROT); end
            8'h9B: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_ROT); end
            8'h9D: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_ROT); end

            // ======================================================
            // 0x9E/9F — unhandled
            // ======================================================
            8'h9E, 8'h9F: begin d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0); end

            // ======================================================
            // 0xA0/A2/A4 — AND.B/H/W — no writeback (flags only for AND)
            // Note: MAME AND does writeback to op2
            // ======================================================
            8'hA0: begin d = exec2(ALU_AND, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'hA2: begin d = exec2(ALU_AND, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'hA4: begin d = exec2(ALU_AND, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0xA1/A3/A5 — DIV.B/H/W
            // ======================================================
            8'hA1: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_DIV); end
            8'hA3: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_DIV); end
            8'hA5: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_DIV); end

            // ======================================================
            // 0xA6 — DIVX
            // ======================================================
            8'hA6: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_DIV); end

            // ======================================================
            // 0xA7 — CLR1 (stub)
            // ======================================================
            8'hA7: begin d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0); end

            // ======================================================
            // 0xA8/AA/AC — SUB.B/H/W
            // ======================================================
            8'hA8: begin d = exec2(ALU_SUB, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'hAA: begin d = exec2(ALU_SUB, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'hAC: begin d = exec2(ALU_SUB, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0xA9/AB/AD — SHA.B/H/W (arithmetic shift)
            // ======================================================
            8'hA9: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_SHA); end
            8'hAB: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_SHA); end
            8'hAD: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_SHA); end

            // ======================================================
            // 0xAE/AF — unhandled
            // ======================================================
            8'hAE, 8'hAF: begin d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0); end

            // ======================================================
            // 0xB0/B2/B4 — XOR.B/H/W
            // ======================================================
            8'hB0: begin d = exec2(ALU_XOR, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'hB2: begin d = exec2(ALU_XOR, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'hB4: begin d = exec2(ALU_XOR, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0xB1/B3/B5 — DIVU.B/H/W
            // ======================================================
            8'hB1: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_DIVU); end
            8'hB3: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_DIVU); end
            8'hB5: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_DIVU); end

            // ======================================================
            // 0xB6 — DIVUX
            // ======================================================
            8'hB6: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_DIVU); end

            // ======================================================
            // 0xB7 — NOT1 (stub)
            // ======================================================
            8'hB7: begin d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0); end

            // ======================================================
            // 0xB8/BA/BC — CMP.B/H/W
            // ======================================================
            8'hB8: begin d = exec2(ALU_CMP, 2'd0, 1'b1, 1'b0, 5'd0); end
            8'hBA: begin d = exec2(ALU_CMP, 2'd1, 1'b1, 1'b0, 5'd0); end
            8'hBC: begin d = exec2(ALU_CMP, 2'd2, 1'b1, 1'b0, 5'd0); end

            // ======================================================
            // 0xB9/BB/BD — SHL.B/H/W (logical shift)
            // ======================================================
            8'hB9: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_SHL); end
            8'hBB: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_SHL); end
            8'hBD: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_SHL); end

            // ======================================================
            // 0xBE/BF — unhandled
            // ======================================================
            8'hBE, 8'hBF: begin d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0); end

            default: begin
                d = decode_zero();
                d.next_state = S_TRAP;
            end

        endcase
    end

endmodule : v60_decode_80_bf
