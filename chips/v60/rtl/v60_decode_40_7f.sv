// v60_decode_40_7f.sv — V60 opcode decode sub-module for opcodes 0x40-0x7F
//
// Pure combinational decode. See v60_decode_pkg.sv for bundle definition.

`default_nettype none
`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHCONCAT */

import v60_decode_pkg::*;

module v60_decode_40_7f /* synthesis keep_hierarchy on */ (
    input  logic [7:0]  ibuf [0:9],
    input  logic [31:0] reg_file [0:63],
    input  logic        f_z, f_s, f_ov, f_cy,
    output v60_decode_t d
);

    localparam [6:0]
        S_FETCH0       = 7'd1,
        S_EXECUTE      = 7'd22,
        S_TRAP         = 7'd28,
        S_PUSH_SETUP   = 7'd29,
        S_CALL_PUSH    = 7'd37,
        S_RET_POP      = 7'd41,
        S_MOVCUH_RD    = 7'd77;

    localparam [3:0]
        ALU_ADD  = 4'd0,  ALU_SUB  = 4'd1,  ALU_AND  = 4'd2,
        ALU_OR   = 4'd3,  ALU_XOR  = 4'd4,  ALU_NOT  = 4'd5,
        ALU_NEG  = 4'd6,  ALU_PASS = 4'd7,  ALU_SHL  = 4'd8,
        ALU_SHR  = 4'd9,  ALU_SAR  = 4'd10, ALU_CMP  = 4'd11,
        ALU_ROL  = 4'd12, ALU_ROR  = 4'd13;

    localparam [4:0]
        EXT_MUL    = 5'd0,  EXT_MULU   = 5'd1,  EXT_DIV    = 5'd2,
        EXT_DIVU   = 5'd3,  EXT_SHA    = 5'd4,  EXT_SHL    = 5'd5,
        EXT_SETF   = 5'd6;

    // decode_am — identical implementation
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
        logic [7:0] mv;
        logic [5:0] rn;
        logic [2:0] grp;
        logic [7:0] mv2;
        logic [5:0] rn2;

        mv   = ibuf[offset];
        grp  = mv[7:5];
        rn   = {1'b0, mv[4:0]};
        mv2  = (offset + 1 <= 9) ? ibuf[offset + 1] : 8'h00;
        rn2  = {1'b0, mv2[4:0]};

        is_reg   = 1'b0;
        is_imm   = 1'b0;
        am_val   = 32'h0;
        am_bytes = 1;

        if (!modm) begin
            case (grp)
                3'd0: begin am_val = reg_file[rn] + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]}; am_bytes = 2; end
                3'd1: begin am_val = reg_file[rn] + {{16{ibuf[offset+2][7]}}, ibuf[offset+2], ibuf[offset+1]}; am_bytes = 3; end
                3'd2: begin am_val = reg_file[rn] + {ibuf[offset+4], ibuf[offset+3], ibuf[offset+2], ibuf[offset+1]}; am_bytes = 5; end
                3'd3: begin am_val = reg_file[rn]; am_bytes = 1; end
                3'd4: begin am_val = reg_file[rn] + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]}; am_bytes = 2; end
                3'd5: begin am_val = reg_file[rn] + {{16{ibuf[offset+2][7]}}, ibuf[offset+2], ibuf[offset+1]}; am_bytes = 3; end
                3'd6: begin am_val = reg_file[rn] + {ibuf[offset+4], ibuf[offset+3], ibuf[offset+2], ibuf[offset+1]}; am_bytes = 5; end
                3'd7: begin
                    is_reg = 1'b0;
                    case (mv[4:0])
                        5'h00, 5'h01, 5'h02, 5'h03, 5'h04, 5'h05, 5'h06, 5'h07,
                        5'h08, 5'h09, 5'h0a, 5'h0b, 5'h0c, 5'h0d, 5'h0e, 5'h0f:
                            begin is_imm=1'b1; am_val={28'd0,mv[3:0]}; am_bytes=1; end
                        5'h10: begin am_val=pc_val+{{24{ibuf[offset+1][7]}},ibuf[offset+1]}; am_bytes=2; end
                        5'h11: begin am_val=pc_val+{{16{ibuf[offset+2][7]}},ibuf[offset+2],ibuf[offset+1]}; am_bytes=3; end
                        5'h12: begin am_val=pc_val+{ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                        5'h13: begin am_val={ibuf[offset+4],ibuf[offset+3],ibuf[offset+2],ibuf[offset+1]}; am_bytes=5; end
                        5'h14: begin
                            is_imm=1'b1;
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
                3'd5: begin
                    case(sz)
                        2'd0: am_val=reg_file[rn]-32'd1;
                        2'd1: am_val=reg_file[rn]-32'd2;
                        2'd2: am_val=reg_file[rn]-32'd4;
                        default: am_val=reg_file[rn]-32'd4;
                    endcase
                    am_bytes=1;
                end
                3'd6: begin
                    case(mv2[7:5])
                        3'd0: begin
                            case(sz)
                                2'd0: am_val=reg_file[rn]+{24'd0,ibuf[offset+2]}+reg_file[rn2];
                                2'd1: am_val=reg_file[rn]+{24'd0,ibuf[offset+2]}+(reg_file[rn2]<<1);
                                2'd2: am_val=reg_file[rn]+{24'd0,ibuf[offset+2]}+(reg_file[rn2]<<2);
                                default: am_val=reg_file[rn]+reg_file[rn2];
                            endcase
                            am_bytes=3;
                        end
                        3'd1: begin
                            case(sz)
                                2'd0: am_val=reg_file[rn]+{{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]}+reg_file[rn2];
                                2'd1: am_val=reg_file[rn]+{{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]}+(reg_file[rn2]<<1);
                                2'd2: am_val=reg_file[rn]+{{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]}+(reg_file[rn2]<<2);
                                default: am_val=reg_file[rn]+reg_file[rn2];
                            endcase
                            am_bytes=4;
                        end
                        3'd2: begin
                            case(sz)
                                2'd0: am_val=reg_file[rn]+{ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]}+reg_file[rn2];
                                2'd1: am_val=reg_file[rn]+{ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]}+(reg_file[rn2]<<1);
                                2'd2: am_val=reg_file[rn]+{ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]}+(reg_file[rn2]<<2);
                                default: am_val=reg_file[rn]+reg_file[rn2];
                            endcase
                            am_bytes=6;
                        end
                        3'd3: begin
                            case(sz)
                                2'd0: am_val=reg_file[rn]+reg_file[rn2];
                                2'd1: am_val=reg_file[rn]+(reg_file[rn2]<<1);
                                2'd2: am_val=reg_file[rn]+(reg_file[rn2]<<2);
                                default: am_val=reg_file[rn]+reg_file[rn2];
                            endcase
                            am_bytes=2;
                        end
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
        exec2.next_state      = S_EXECUTE;
        exec2.op_alu_op       = alu;
        exec2.op_size         = sz;
        exec2.op_has_am2      = 1'b1;
        exec2.op_update_flags = upd_flags;
        exec2.op_is_branch    = 1'b0;
        exec2.op_is_single_am = 1'b0;
        exec2.op_no_am        = 1'b0;
        exec2.op_is_ext       = is_ext;
        exec2.op_ext_op       = ext;
    endfunction

    // Helper: build a branch8 decode (opcode(1)+disp8(1) = 2 bytes total)
    // taken_cond = whether to take the branch
    function automatic v60_decode_t branch8(input logic taken, input logic [31:0] pc);
        branch8 = decode_zero();
        branch8.next_state = S_FETCH0;
        branch8.pc_en = 1'b1;
        if (taken)
            branch8.pc_val = pc + {{24{ibuf[1][7]}}, ibuf[1]};
        else
            branch8.pc_val = pc + 32'd2;
    endfunction

    // Helper: build a branch16 decode (opcode(1)+disp16(2) = 3 bytes total)
    function automatic v60_decode_t branch16(input logic taken, input logic [31:0] pc);
        branch16 = decode_zero();
        branch16.next_state = S_FETCH0;
        branch16.pc_en = 1'b1;
        if (taken)
            branch16.pc_val = pc + {{16{ibuf[2][7]}}, ibuf[2], ibuf[1]};
        else
            branch16.pc_val = pc + 32'd3;
    endfunction

    always @(*) begin
        d = decode_zero();

        case (ibuf[0])

            // ======================================================
            // 0x40/42/44 — MOVEA.B/H/W — load effective address
            // ======================================================
            8'h40, 8'h42, 8'h44: begin : blk_movea
                logic [1:0]  mea_sz;
                logic        mea_m1, mea_m2;
                logic        mea_is_reg1, mea_is_imm1;
                logic        mea_is_reg2, mea_is_imm2;
                logic [31:0] mea_ea;
                logic [31:0] mea_dst;
                int          mea_len1, mea_len2;
                logic [31:0] mea_next_pc;

                // Defaults to prevent latch inference in always_comb
                mea_sz = 2'd0; mea_m1 = 1'b0; mea_m2 = 1'b0;
                mea_is_reg1 = 1'b0; mea_is_imm1 = 1'b0;
                mea_is_reg2 = 1'b0; mea_is_imm2 = 1'b0;
                mea_ea = '0; mea_dst = '0;
                mea_len1 = 0; mea_len2 = 0; mea_next_pc = '0;

                d = decode_zero();
                mea_sz = (ibuf[0] == 8'h40) ? 2'd0 :
                         (ibuf[0] == 8'h42) ? 2'd1 : 2'd2;
                mea_m1 = ibuf[1][6];
                mea_m2 = ibuf[1][5];

                if (ibuf[1][7]) begin
                    decode_am(2, mea_sz, mea_m1, reg_file[32],
                              mea_is_reg1, mea_is_imm1, mea_ea, mea_len1);
                    decode_am(2 + mea_len1, 2'd2, mea_m2, reg_file[32],
                              mea_is_reg2, mea_is_imm2, mea_dst, mea_len2);
                    mea_next_pc = reg_file[32] + 32'd2 + mea_len1 + mea_len2;
                    if (mea_is_reg2) begin
                        d.next_state = S_FETCH0;
                        d.rw0_en    = 1'b1;
                        d.rw0_idx   = mea_dst[5:0];
                        d.rw0_val   = mea_ea;
                        d.pc_en     = 1'b1;
                        d.pc_val    = mea_next_pc;
                    end else begin
                        // Memory or autodecrement destination: use PUSH machinery
                        d.next_state         = S_PUSH_SETUP;
                        d.stk_val_en         = 1'b1;
                        d.stk_val_v          = mea_ea;
                        d.stk_size_en        = 1'b1;
                        d.stk_size_v         = 2'd2;
                        d.pc_en              = 1'b1;
                        d.pc_val             = mea_next_pc;
                    end
                end else if (ibuf[1][5]) begin
                    decode_am(2, mea_sz, mea_m1, reg_file[32],
                              mea_is_reg1, mea_is_imm1, mea_ea, mea_len1);
                    d.next_state = S_FETCH0;
                    d.rw0_en    = 1'b1;
                    d.rw0_idx   = {1'b0, ibuf[1][4:0]};
                    d.rw0_val   = mea_ea;
                    d.pc_en     = 1'b1;
                    d.pc_val    = reg_file[32] + 32'd2 + mea_len1;
                end else begin
                    decode_am(2, 2'd2, mea_m2, reg_file[32],
                              mea_is_reg2, mea_is_imm2, mea_dst, mea_len2);
                    d.next_state = S_FETCH0;
                    if (mea_is_reg2) begin
                        d.rw0_en  = 1'b1;
                        d.rw0_idx = mea_dst[5:0];
                        d.rw0_val = reg_file[{1'b0, ibuf[1][4:0]}];
                    end
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd2 + mea_len2;
                end
            end

            // ======================================================
            // 0x41/43/45 — XCH.B/H/W
            // ======================================================
            8'h41: begin d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b0, 5'd0); end
            8'h43: begin d = exec2(ALU_PASS, 2'd1, 1'b0, 1'b0, 5'd0); end
            8'h45: begin d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b0, 5'd0); end

            // ======================================================
            // 0x48 — BSR — branch to subroutine (PC-relative)
            // ======================================================
            8'h48: begin
                d = decode_zero();
                d.next_state           = S_CALL_PUSH;
                d.stk_ret_pc_en        = 1'b1;
                d.stk_ret_pc_v         = reg_file[32] + 32'd3;
                d.stk_jump_target_en   = 1'b1;
                d.stk_jump_target_v    = reg_file[32] +
                                         {{16{ibuf[2][7]}}, ibuf[2], ibuf[1]};
                d.stk_size_en          = 1'b1;
                d.stk_size_v           = 2'd2;
            end

            // ======================================================
            // 0x49 — CALL via AM
            // ======================================================
            8'h49: begin : blk_call
                logic        ca_is_reg, ca_is_imm;
                logic [31:0] ca_addr;
                int          ca_len;
                decode_am(1, 2'd2, 1'b0, reg_file[32],
                          ca_is_reg, ca_is_imm, ca_addr, ca_len);
                d = decode_zero();
                d.next_state           = S_CALL_PUSH;
                d.stk_ret_pc_en        = 1'b1;
                d.stk_ret_pc_v         = reg_file[32] + 32'd1 + ca_len;
                d.stk_jump_target_en   = 1'b1;
                d.stk_jump_target_v    = ca_addr;
                d.stk_size_en          = 1'b1;
                d.stk_size_v           = 2'd2;
            end

            // ======================================================
            // 0x4A — UPDPSWH — Update PSW halfword
            // ======================================================
            8'h4A: begin : blk_updpswh
                logic        u2_is_r1, u2_is_i1, u2_is_r2, u2_is_i2;
                logic [31:0] u2_v1, u2_v2;
                int          u2_l1, u2_l2;
                logic [31:0] u2_np, u2_cp;
                logic [31:0] u2_npc;

                // Defaults to prevent latch inference in always_comb
                u2_is_r1 = 1'b0; u2_is_i1 = 1'b0;
                u2_is_r2 = 1'b0; u2_is_i2 = 1'b0;
                u2_v1 = '0; u2_v2 = '0;
                u2_l1 = 0; u2_l2 = 0;
                u2_np = '0; u2_cp = '0; u2_npc = '0;

                d = decode_zero();

                if (ibuf[1][7]) begin
                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                              u2_is_r1, u2_is_i1, u2_v1, u2_l1);
                    decode_am(2+u2_l1, 2'd2, ibuf[1][5], reg_file[32],
                              u2_is_r2, u2_is_i2, u2_v2, u2_l2);
                    u2_npc = reg_file[32] + 32'd2 + u2_l1 + u2_l2;
                end else if (ibuf[1][5]) begin
                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                              u2_is_r1, u2_is_i1, u2_v1, u2_l1);
                    u2_v2  = reg_file[{1'b0, ibuf[1][4:0]}];
                    u2_l2  = 0;
                    u2_npc = reg_file[32] + 32'd2 + u2_l1;
                end else begin
                    u2_v1     = reg_file[{1'b0, ibuf[1][4:0]}];
                    u2_l1     = 0; u2_is_r1 = 1'b1; u2_is_i1 = 1'b0;
                    decode_am(2, 2'd2, ibuf[1][5], reg_file[32],
                              u2_is_r2, u2_is_i2, u2_v2, u2_l2);
                    u2_npc = reg_file[32] + 32'd2 + u2_l2;
                end
                if (u2_is_r1) u2_v1 = reg_file[u2_v1[5:0]];
                if (ibuf[1][7] && u2_is_r2) u2_v2 = reg_file[u2_v2[5:0]];
                u2_cp = {reg_file[33][31:4], f_cy, f_ov, f_s, f_z};
                u2_np = (u2_cp & ~(u2_v2 & 32'h0000FFFF)) |
                        (u2_v1  &  u2_v2 & 32'h0000FFFF);

                d.next_state  = S_FETCH0;
                d.flg_update  = 1'b1;
                d.flg_z       = u2_np[0]; d.flg_s = u2_np[1];
                d.flg_ov      = u2_np[2]; d.flg_cy = u2_np[3];
                d.psw_reg_en  = 1'b1;
                d.psw_reg_val = u2_np;
                d.pc_en       = 1'b1;
                d.pc_val      = u2_npc;
            end

            // ======================================================
            // 0x4B-0x4F — unhandled stubs
            // ======================================================
            8'h4B, 8'h4C, 8'h4D, 8'h4E, 8'h4F: begin
                d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x50/52/54 — REM.B/H/W  (stub as DIV)
            // 0x51/53/55 — REMU.B/H/W (stub as DIVU)
            // ======================================================
            8'h50: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_DIV);  end
            8'h52: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_DIV);  end
            8'h54: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_DIV);  end
            8'h51: begin d = exec2(ALU_PASS, 2'd0, 1'b1, 1'b1, EXT_DIVU); end
            8'h53: begin d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b1, EXT_DIVU); end
            8'h55: begin d = exec2(ALU_PASS, 2'd2, 1'b1, 1'b1, EXT_DIVU); end

            // ======================================================
            // 0x5A/5B — MOVCUH
            // ======================================================
            8'h5A, 8'h5B: begin : blk_movcuh
                logic [3:0]  f7a_am1_len, f7a_am2_len;
                logic [4:0]  f7a_total;
                logic [7:0]  f7a_len1_byte, f7a_len2_byte;
                logic [31:0] f7a_src_addr, f7a_dst_addr;
                logic [31:0] f7a_lenop1, f7a_lenop2, f7a_cnt;
                logic        f7a_src_is_reg, f7a_src_is_imm;
                logic        f7a_dst_is_reg, f7a_dst_is_imm;
                int          f7a_src_am_bytes, f7a_dst_am_bytes;

                d = decode_zero();

                case (ibuf[2][7:5])
                    3'b000: f7a_am1_len = 4'd2;
                    3'b001: f7a_am1_len = 4'd3;
                    3'b010: f7a_am1_len = 4'd5;
                    3'b011: f7a_am1_len = 4'd1;
                    3'b100: f7a_am1_len = 4'd2;
                    3'b101: f7a_am1_len = 4'd3;
                    3'b110: f7a_am1_len = 4'd5;
                    default: f7a_am1_len = 4'd5;
                endcase
                f7a_len1_byte = ibuf[2 + f7a_am1_len];
                case (ibuf[2 + f7a_am1_len + 1][7:5])
                    3'b000: f7a_am2_len = 4'd2;
                    3'b001: f7a_am2_len = 4'd3;
                    3'b010: f7a_am2_len = 4'd5;
                    3'b011: f7a_am2_len = 4'd1;
                    3'b100: f7a_am2_len = 4'd2;
                    3'b101: f7a_am2_len = 4'd3;
                    3'b110: f7a_am2_len = 4'd5;
                    default: f7a_am2_len = 4'd5;
                endcase
                f7a_len2_byte = ibuf[2 + f7a_am1_len + 1 + f7a_am2_len];
                f7a_total = 5'd4 + {1'b0, f7a_am1_len} + {1'b0, f7a_am2_len};

                decode_am(2, 2'd2, 1'b0, reg_file[32],
                          f7a_src_is_reg, f7a_src_is_imm, f7a_src_addr, f7a_src_am_bytes);
                decode_am(2 + f7a_am1_len + 1, 2'd2, 1'b0, reg_file[32],
                          f7a_dst_is_reg, f7a_dst_is_imm, f7a_dst_addr, f7a_dst_am_bytes);

                f7a_lenop1 = f7a_len1_byte[7] ?
                             reg_file[{1'b0, f7a_len1_byte[4:0]}] :
                             {25'd0, f7a_len1_byte[6:0]};
                f7a_lenop2 = f7a_len2_byte[7] ?
                             reg_file[{1'b0, f7a_len2_byte[4:0]}] :
                             {25'd0, f7a_len2_byte[6:0]};
                f7a_cnt = (f7a_lenop1 < f7a_lenop2) ? f7a_lenop1 : f7a_lenop2;

                d.movcuh_en    = 1'b1;
                d.movcuh_src_v = f7a_src_addr;
                d.movcuh_dst_v = f7a_dst_addr;
                d.movcuh_cnt_v = f7a_cnt;
                d.pc_en  = 1'b1;
                d.pc_val = reg_file[32] + {27'd0, f7a_total};

                if (f7a_cnt == 32'd0) begin
                    d.next_state = S_FETCH0;
                    d.rw0_en  = 1'b1;  d.rw0_idx = 6'd28; d.rw0_val = f7a_src_addr;
                    d.rw1_en  = 1'b1;  d.rw1_idx = 6'd27; d.rw1_val = f7a_dst_addr;
                end else begin
                    d.next_state = S_MOVCUH_RD;
                end
            end

            // ======================================================
            // 0x58/59 — MOVCB stub (skip)
            // ======================================================
            8'h58, 8'h59: begin : blk_movcb
                logic [3:0] f7b_l1, f7b_l2;
                logic [4:0] f7b_tot;
                d = decode_zero();
                case (ibuf[2][7:5])
                    3'b000, 3'b001, 3'b010, 3'b011: f7b_l1 = 4'd1;
                    3'b100: f7b_l1 = 4'd2;
                    3'b101: f7b_l1 = 4'd3;
                    3'b110: f7b_l1 = 4'd5;
                    default: f7b_l1 = 4'd5;
                endcase
                case (ibuf[3 + f7b_l1][7:5])
                    3'b000, 3'b001, 3'b010, 3'b011: f7b_l2 = 4'd1;
                    3'b100: f7b_l2 = 4'd2;
                    3'b101: f7b_l2 = 4'd3;
                    3'b110: f7b_l2 = 4'd5;
                    default: f7b_l2 = 4'd5;
                endcase
                f7b_tot = 5'd4 + {1'b0, f7b_l1} + {1'b0, f7b_l2};
                d.next_state = S_FETCH0;
                d.pc_en = 1'b1;
                d.pc_val = reg_file[32] + {27'd0, f7b_tot};
            end

            // ======================================================
            // 0x5C/5D — MOVCFH stub (skip)
            // ======================================================
            8'h5C, 8'h5D: begin : blk_movcfh
                logic [3:0] f7c_l1, f7c_l2;
                logic [4:0] f7c_tot;
                d = decode_zero();
                case (ibuf[2][7:5])
                    3'b000, 3'b001, 3'b010, 3'b011: f7c_l1 = 4'd1;
                    3'b100: f7c_l1 = 4'd2;
                    3'b101: f7c_l1 = 4'd3;
                    3'b110: f7c_l1 = 4'd5;
                    default: f7c_l1 = 4'd5;
                endcase
                case (ibuf[3 + f7c_l1][7:5])
                    3'b000, 3'b001, 3'b010, 3'b011: f7c_l2 = 4'd1;
                    3'b100: f7c_l2 = 4'd2;
                    3'b101: f7c_l2 = 4'd3;
                    3'b110: f7c_l2 = 4'd5;
                    default: f7c_l2 = 4'd5;
                endcase
                f7c_tot = 5'd4 + {1'b0, f7c_l1} + {1'b0, f7c_l2};
                d.next_state = S_FETCH0;
                d.pc_en = 1'b1;
                d.pc_val = reg_file[32] + {27'd0, f7c_tot};
            end

            // ======================================================
            // 0x5F — op5F string stub
            // ======================================================
            8'h5F: begin : blk_op5f
                logic [3:0] f5f_l1, f5f_l2;
                logic [4:0] f5f_tot;
                d = decode_zero();
                case (ibuf[2][7:5])
                    3'b000, 3'b001, 3'b010, 3'b011: f5f_l1 = 4'd1;
                    3'b100: f5f_l1 = 4'd2;
                    3'b101: f5f_l1 = 4'd3;
                    3'b110: f5f_l1 = 4'd5;
                    default: f5f_l1 = 4'd5;
                endcase
                case (ibuf[3 + f5f_l1][7:5])
                    3'b000, 3'b001, 3'b010, 3'b011: f5f_l2 = 4'd1;
                    3'b100: f5f_l2 = 4'd2;
                    3'b101: f5f_l2 = 4'd3;
                    3'b110: f5f_l2 = 4'd5;
                    default: f5f_l2 = 4'd5;
                endcase
                f5f_tot = 5'd4 + {1'b0, f5f_l1} + {1'b0, f5f_l2};
                d.next_state = S_FETCH0;
                d.pc_en = 1'b1;
                d.pc_val = reg_file[32] + {27'd0, f5f_tot};
            end

            // ======================================================
            // Branch8 — 0x60-0x6F, 0x7A (unconditional BR8)
            // ======================================================
            8'h60: begin d = branch8(f_ov,           reg_file[32]); end  // BV8
            8'h61: begin d = branch8(!f_ov,          reg_file[32]); end  // BNV8
            8'h62: begin d = branch8(f_cy,           reg_file[32]); end  // BL8
            8'h63: begin d = branch8(!f_cy,          reg_file[32]); end  // BNL8
            8'h64: begin d = branch8(f_z,            reg_file[32]); end  // BE8
            8'h65: begin d = branch8(!f_z,           reg_file[32]); end  // BNE8
            8'h66: begin d = branch8(f_cy|f_z,       reg_file[32]); end  // BNH8
            8'h67: begin d = branch8(!(f_cy|f_z),    reg_file[32]); end  // BH8
            8'h68: begin d = branch8(f_s,            reg_file[32]); end  // BN8
            8'h69: begin d = branch8(!f_s,           reg_file[32]); end  // BP8
            8'h6A: begin  // BR8 always
                d = decode_zero();
                d.next_state = S_FETCH0;
                d.pc_en  = 1'b1;
                d.pc_val = reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
            end
            8'h6B: begin  // unhandled — skip 2
                d = decode_zero();
                d.next_state = S_FETCH0;
                d.pc_en  = 1'b1;
                d.pc_val = reg_file[32] + 32'd2;
            end
            8'h6C: begin d = branch8(!(f_s^f_ov),          reg_file[32]); end  // BGE8
            8'h6D: begin d = branch8(f_s^f_ov,             reg_file[32]); end  // BLT8
            8'h6E: begin d = branch8((f_s^f_ov)|f_z,       reg_file[32]); end  // BLE8
            8'h6F: begin d = branch8(!((f_s^f_ov)|f_z),    reg_file[32]); end  // BGT8

            // ======================================================
            // Branch16 — 0x70-0x7F
            // ======================================================
            8'h70: begin d = branch16(f_ov,             reg_file[32]); end  // BV16
            8'h71: begin d = branch16(!f_ov,            reg_file[32]); end  // BNV16
            8'h72: begin d = branch16(f_cy,             reg_file[32]); end  // BL16
            8'h73: begin d = branch16(!f_cy,            reg_file[32]); end  // BNL16
            8'h74: begin d = branch16(f_z,              reg_file[32]); end  // BE16
            8'h75: begin d = branch16(!f_z,             reg_file[32]); end  // BNE16
            8'h76: begin d = branch16(f_cy|f_z,         reg_file[32]); end  // BNH16
            8'h77: begin d = branch16(!(f_cy|f_z),      reg_file[32]); end  // BH16
            8'h78: begin d = branch16(f_s,              reg_file[32]); end  // BN16
            8'h79: begin d = branch16(!f_s,             reg_file[32]); end  // BP16
            8'h7A: begin  // BR16 always
                d = decode_zero();
                d.next_state = S_FETCH0;
                d.pc_en  = 1'b1;
                d.pc_val = reg_file[32] + {{16{ibuf[2][7]}}, ibuf[2], ibuf[1]};
            end
            8'h7B: begin  // unhandled — skip 3
                d = decode_zero();
                d.next_state = S_FETCH0;
                d.pc_en  = 1'b1;
                d.pc_val = reg_file[32] + 32'd3;
            end
            8'h7C: begin d = branch16(f_s^f_ov,              reg_file[32]); end  // BLT16
            8'h7D: begin d = branch16(!(f_s^f_ov),           reg_file[32]); end  // BGE16
            8'h7E: begin d = branch16((f_s^f_ov)|f_z,        reg_file[32]); end  // BLE16
            8'h7F: begin d = branch16(!((f_s^f_ov)|f_z),     reg_file[32]); end  // BGT16

            default: begin
                d = decode_zero();
                d.next_state = S_TRAP;
            end

        endcase
    end

endmodule : v60_decode_40_7f
