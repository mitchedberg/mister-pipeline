// v60_decode_00_3f.sv — V60 opcode decode sub-module for opcodes 0x00-0x3F
//
// Pure combinational decode: takes CPU state, produces v60_decode_t bundle.
// Instantiated by v60_core.sv; result is muxed by opcode[7:6] and registered.
//
// Quartus synthesizes each sub-module independently, reducing peak memory
// vs. the single 202-entry case statement in one always_ff block.

`default_nettype none
`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHCONCAT */

import v60_decode_pkg::*;

module v60_decode_00_3f (
    // Instruction buffer (10 bytes fetched)
    input  logic [7:0]  ibuf [0:9],
    // Register file (read-only)
    input  logic [31:0] reg_file [0:63],
    // PSW flags
    input  logic        f_z, f_s, f_ov, f_cy,
    // Output decode bundle
    output v60_decode_t d
);

    // =========================================================================
    // State encoding constants (must match state_t in v60_core.sv)
    // =========================================================================
    localparam [6:0]
        S_FETCH0      = 7'd1,
        S_EXECUTE     = 7'd22,
        S_TRAP        = 7'd28,
        S_PUSH_SETUP  = 7'd29,
        S_POP_SETUP   = 7'd33,
        S_CALL_PUSH   = 7'd37,
        S_RET_POP     = 7'd41,
        S_PREPARE_PUSH = 7'd45,
        S_PUSHM_NEXT  = 7'd49,
        S_POPM_NEXT   = 7'd53,
        S_RETIS_PC_LO = 7'd57,
        S_MOVCUH_RD   = 7'd77,
        S_LDTASK_TKCW_LO_WAIT = 7'd84;

    // =========================================================================
    // ALU op constants (must match v60_alu.sv)
    // =========================================================================
    localparam [3:0]
        ALU_ADD  = 4'd0,  ALU_SUB  = 4'd1,  ALU_AND  = 4'd2,
        ALU_OR   = 4'd3,  ALU_XOR  = 4'd4,  ALU_NOT  = 4'd5,
        ALU_NEG  = 4'd6,  ALU_PASS = 4'd7,  ALU_SHL  = 4'd8,
        ALU_SHR  = 4'd9,  ALU_SAR  = 4'd10, ALU_CMP  = 4'd11,
        ALU_ROL  = 4'd12, ALU_ROR  = 4'd13;

    // Extended op constants
    localparam [4:0]
        EXT_MUL    = 5'd0,  EXT_MULU   = 5'd1,  EXT_DIV    = 5'd2,
        EXT_DIVU   = 5'd3,  EXT_SHA    = 5'd4,  EXT_SHL    = 5'd5,
        EXT_SETF   = 5'd6,  EXT_LDPR   = 5'd7,  EXT_STPR   = 5'd8,
        EXT_MOVZHW = 5'd9,  EXT_MOVSHW = 5'd10, EXT_MOVZBW = 5'd11,
        EXT_MOVSBW = 5'd12, EXT_MOVZBH = 5'd13, EXT_ROT    = 5'd14,
        EXT_MOVSBH = 5'd15, EXT_RVBIT  = 5'd16, EXT_RVBYT  = 5'd17,
        EXT_TEST1  = 5'd18;

    // =========================================================================
    // decode_am task — identical to v60_core.sv implementation
    // =========================================================================
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
                3'd0: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                    am_bytes = 2;
                end
                3'd1: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{16{ibuf[offset+2][7]}},
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 3;
                end
                3'd2: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {ibuf[offset+4], ibuf[offset+3],
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 5;
                end
                3'd3: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn];
                    am_bytes = 1;
                end
                3'd4: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                    am_bytes = 2;
                end
                3'd5: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{16{ibuf[offset+2][7]}},
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 3;
                end
                3'd6: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {ibuf[offset+4], ibuf[offset+3],
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 5;
                end
                3'd7: begin
                    is_reg = 1'b0;
                    case (mv[4:0])
                        5'h00, 5'h01, 5'h02, 5'h03,
                        5'h04, 5'h05, 5'h06, 5'h07,
                        5'h08, 5'h09, 5'h0a, 5'h0b,
                        5'h0c, 5'h0d, 5'h0e, 5'h0f: begin
                            is_imm   = 1'b1;
                            am_val   = {28'd0, mv[3:0]};
                            am_bytes = 1;
                        end
                        5'h10: begin
                            am_val   = pc_val + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                            am_bytes = 2;
                        end
                        5'h11: begin
                            am_val   = pc_val + {{16{ibuf[offset+2][7]}},
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 3;
                        end
                        5'h12: begin
                            am_val   = pc_val + {ibuf[offset+4], ibuf[offset+3],
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        5'h13: begin
                            am_val   = {ibuf[offset+4], ibuf[offset+3],
                                        ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        5'h14: begin
                            is_imm   = 1'b1;
                            case (sz)
                                2'd0: begin
                                    am_val   = {24'd0, ibuf[offset+1]};
                                    am_bytes = 2;
                                end
                                2'd1: begin
                                    am_val   = {16'd0, ibuf[offset+2], ibuf[offset+1]};
                                    am_bytes = 3;
                                end
                                default: begin
                                    am_val   = {ibuf[offset+4], ibuf[offset+3],
                                                ibuf[offset+2], ibuf[offset+1]};
                                    am_bytes = 5;
                                end
                            endcase
                        end
                        5'h18: begin
                            am_val   = pc_val + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                            am_bytes = 2;
                        end
                        5'h19: begin
                            am_val   = pc_val + {{16{ibuf[offset+2][7]}},
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 3;
                        end
                        5'h1a: begin
                            am_val   = pc_val + {ibuf[offset+4], ibuf[offset+3],
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        5'h1b: begin
                            am_val   = {ibuf[offset+4], ibuf[offset+3],
                                        ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        5'h1c: begin
                            am_val   = pc_val + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                            am_bytes = 3;
                        end
                        5'h1d: begin
                            am_val   = pc_val + {{16{ibuf[offset+2][7]}},
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        5'h1e: begin
                            am_val   = pc_val + {ibuf[offset+4], ibuf[offset+3],
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 9;
                        end
                        default: begin
                            am_val   = {ibuf[offset+4], ibuf[offset+3],
                                        ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                    endcase
                end
            endcase
        end else begin
            case (grp)
                3'd0: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                    am_bytes = 3;
                end
                3'd1: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{16{ibuf[offset+2][7]}},
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 5;
                end
                3'd2: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {ibuf[offset+4], ibuf[offset+3],
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 9;
                end
                3'd3: begin
                    is_reg   = 1'b1;
                    am_val   = {26'd0, rn};
                    am_bytes = 1;
                end
                3'd4: begin
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn];
                    am_bytes = 1;
                end
                3'd5: begin
                    is_reg   = 1'b0;
                    case (sz)
                        2'd0: am_val = reg_file[rn] - 32'd1;
                        2'd1: am_val = reg_file[rn] - 32'd2;
                        2'd2: am_val = reg_file[rn] - 32'd4;
                        default: am_val = reg_file[rn] - 32'd4;
                    endcase
                    am_bytes = 1;
                end
                3'd6: begin
                    case (mv2[7:5])
                        3'd0: begin
                            case (sz)
                                2'd0: am_val = reg_file[rn] + {24'd0, ibuf[offset+2]} + reg_file[rn2];
                                2'd1: am_val = reg_file[rn] + {24'd0, ibuf[offset+2]} + (reg_file[rn2] << 1);
                                2'd2: am_val = reg_file[rn] + {24'd0, ibuf[offset+2]} + (reg_file[rn2] << 2);
                                default: am_val = reg_file[rn] + reg_file[rn2];
                            endcase
                            am_bytes = 3;
                        end
                        3'd1: begin
                            case (sz)
                                2'd0: am_val = reg_file[rn] + {{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]} + reg_file[rn2];
                                2'd1: am_val = reg_file[rn] + {{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]} + (reg_file[rn2] << 1);
                                2'd2: am_val = reg_file[rn] + {{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]} + (reg_file[rn2] << 2);
                                default: am_val = reg_file[rn] + reg_file[rn2];
                            endcase
                            am_bytes = 4;
                        end
                        3'd2: begin
                            case (sz)
                                2'd0: am_val = reg_file[rn] + {ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]} + reg_file[rn2];
                                2'd1: am_val = reg_file[rn] + {ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]} + (reg_file[rn2] << 1);
                                2'd2: am_val = reg_file[rn] + {ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]} + (reg_file[rn2] << 2);
                                default: am_val = reg_file[rn] + reg_file[rn2];
                            endcase
                            am_bytes = 6;
                        end
                        3'd3: begin
                            case (sz)
                                2'd0: am_val = reg_file[rn] + reg_file[rn2];
                                2'd1: am_val = reg_file[rn] + (reg_file[rn2] << 1);
                                2'd2: am_val = reg_file[rn] + (reg_file[rn2] << 2);
                                default: am_val = reg_file[rn] + reg_file[rn2];
                            endcase
                            am_bytes = 2;
                        end
                        default: begin
                            am_val   = reg_file[rn] + {24'd0, ibuf[offset+2]} + reg_file[rn2];
                            am_bytes = 3;
                        end
                    endcase
                end
                default: begin
                    am_val   = 32'h0;
                    am_bytes = 1;
                end
            endcase
        end
    endtask

    // =========================================================================
    // Helper: zero-initialise decode bundle
    // =========================================================================
    function automatic v60_decode_t decode_zero();
        decode_zero = '{default: '0};
        decode_zero.next_state = S_TRAP;
    endfunction

    // =========================================================================
    // Helper: set up a two-operand S_EXECUTE dispatch
    // =========================================================================
    function automatic v60_decode_t exec2(
        input logic [3:0] alu, input logic [1:0] sz,
        input logic upd_flags, input logic is_ext, input logic [4:0] ext
    );
        exec2 = decode_zero();
        exec2.next_state    = S_EXECUTE;
        exec2.op_alu_op     = alu;
        exec2.op_size       = sz;
        exec2.op_has_am2    = 1'b1;
        exec2.op_update_flags = upd_flags;
        exec2.op_is_branch  = 1'b0;
        exec2.op_is_single_am = 1'b0;
        exec2.op_no_am      = 1'b0;
        exec2.op_is_ext     = is_ext;
        exec2.op_ext_op     = ext;
    endfunction

    // =========================================================================
    // Combinational decode logic
    // =========================================================================
    always_comb begin
        // Default: trap on unknown opcode
        d = decode_zero();

        case (ibuf[0])

            // ======================================================
            // 0x00 — HALT — treat as NOP (advance PC by 1)
            // ======================================================
            8'h00: begin
                d = decode_zero();
                d.next_state = S_FETCH0;
                d.pc_en  = 1'b1;
                d.pc_val = reg_file[32] + 32'd1;
            end

            // ======================================================
            // 0x01 — LDTASK
            // ======================================================
            8'h01: begin : blk_ldtask
                logic        lt_is_reg1, lt_is_imm1;
                logic        lt_is_reg2, lt_is_imm2;
                logic [31:0] lt_op1, lt_op2;
                int          lt_len1, lt_len2;
                logic [31:0] lt_new_psw;
                logic [31:0] lt_next_pc;

                d = decode_zero();

                if (ibuf[1][7]) begin
                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                              lt_is_reg1, lt_is_imm1, lt_op1, lt_len1);
                    decode_am(2+lt_len1, 2'd2, ibuf[1][5], reg_file[32],
                              lt_is_reg2, lt_is_imm2, lt_op2, lt_len2);
                    lt_next_pc = reg_file[32] + 32'd2 + lt_len1 + lt_len2;
                end else if (ibuf[1][5]) begin
                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                              lt_is_reg1, lt_is_imm1, lt_op1, lt_len1);
                    lt_op2     = reg_file[{1'b0, ibuf[1][4:0]}];
                    lt_is_reg2 = 1'b0; lt_is_imm2 = 1'b1;
                    lt_len2    = 0;
                    lt_next_pc = reg_file[32] + 32'd2 + lt_len1;
                end else begin
                    lt_op1     = reg_file[{1'b0, ibuf[1][4:0]}];
                    lt_is_reg1 = 1'b1; lt_is_imm1 = 1'b0;
                    lt_len1    = 0;
                    decode_am(2, 2'd2, ibuf[1][5], reg_file[32],
                              lt_is_reg2, lt_is_imm2, lt_op2, lt_len2);
                    lt_next_pc = reg_file[32] + 32'd2 + lt_len2;
                end
                if (lt_is_reg1) lt_op1 = reg_file[lt_op1[5:0]];
                if (lt_is_reg2) lt_op2 = reg_file[lt_op2[5:0]];

                lt_new_psw = {reg_file[33][31:4], f_cy, f_ov, f_s, f_z}
                             & 32'hEFFFFFFF;

                d.next_state   = S_LDTASK_TKCW_LO_WAIT;
                // PSW write
                d.psw_reg_en   = 1'b1;
                d.psw_reg_val  = lt_new_psw;
                // TR = op2 (reg 42)
                d.rw0_en  = 1'b1;
                d.rw0_idx = 6'd42;
                d.rw0_val = lt_op2;
                // PC
                d.pc_en   = 1'b1;
                d.pc_val  = lt_next_pc;
                // PUSHM mask / idx / ldtask_ptr
                d.pm_mask_en  = 1'b1;
                d.pm_mask_v   = {1'b0, lt_op1[30:0]};
                d.pm_idx_en   = 1'b1;
                d.pm_idx_v    = 6'd0;
                d.ldtask_ptr_en = 1'b1;
                d.ldtask_ptr_v  = lt_op2;
                // Bus: start reading TKCW from [op2]
                d.bus_en    = 1'b1;
                d.bus_addr_v = lt_op2[23:0];
                d.bus_as_v  = 1'b0;
                d.bus_rw_v  = 1'b1;
                d.bus_ds_v  = 2'b00;
            end

            // ======================================================
            // 0x02 — STPR
            // ======================================================
            8'h02: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b1, EXT_STPR);
            end

            // ======================================================
            // 0x03/04/05/06/07 — GETRA/GETPTE/GETATE/unhandled stubs
            // ======================================================
            8'h03, 8'h04, 8'h05, 8'h06, 8'h07: begin
                d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x08 — RVBIT
            // ======================================================
            8'h08: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b1, EXT_RVBIT);
            end

            // ======================================================
            // 0x09 — MOV.B
            // ======================================================
            8'h09: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x0A — MOVSBH
            // ======================================================
            8'h0A: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b1, EXT_MOVSBH);
            end

            // ======================================================
            // 0x0B — MOVZBH
            // ======================================================
            8'h0B: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b1, EXT_MOVZBH);
            end

            // ======================================================
            // 0x0C — MOVSBW alias
            // ======================================================
            8'h0C: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b1, EXT_MOVSBW);
            end

            // ======================================================
            // 0x0D — MOVZBW
            // ======================================================
            8'h0D: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b1, EXT_MOVZBW);
            end

            // ======================================================
            // 0x0E, 0x0F — unhandled stubs
            // ======================================================
            8'h0E, 8'h0F: begin
                d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x10 — CLRTLBA — 1-byte NOP
            // ======================================================
            8'h10: begin
                d = decode_zero();
                d.next_state = S_FETCH0;
                d.pc_en  = 1'b1;
                d.pc_val = reg_file[32] + 32'd1;
            end

            // ======================================================
            // 0x11 — unhandled stub
            // ======================================================
            8'h11: begin
                d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x12 — LDPR
            // ======================================================
            8'h12: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b1, EXT_LDPR);
            end

            // ======================================================
            // 0x13 — UPDPSWW — Update PSW word
            // ======================================================
            8'h13: begin : blk_updpsww
                logic        upd_is_reg1, upd_is_imm1;
                logic        upd_is_reg2, upd_is_imm2;
                logic [31:0] upd_val1, upd_val2;
                int          upd_len1, upd_len2;
                logic [31:0] upd_next_pc;
                logic [31:0] upd_new_psw, upd_cur_psw;

                d = decode_zero();

                if (ibuf[1][7]) begin
                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                              upd_is_reg1, upd_is_imm1, upd_val1, upd_len1);
                    decode_am(2+upd_len1, 2'd2, ibuf[1][5], reg_file[32],
                              upd_is_reg2, upd_is_imm2, upd_val2, upd_len2);
                    upd_next_pc = reg_file[32] + 32'd2 + upd_len1 + upd_len2;
                end else if (ibuf[1][5]) begin
                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                              upd_is_reg1, upd_is_imm1, upd_val1, upd_len1);
                    upd_val2 = reg_file[{1'b0, ibuf[1][4:0]}];
                    upd_len2 = 0;
                    upd_next_pc = reg_file[32] + 32'd2 + upd_len1;
                end else begin
                    upd_val1 = reg_file[{1'b0, ibuf[1][4:0]}];
                    upd_len1 = 0;
                    decode_am(2, 2'd2, ibuf[1][5], reg_file[32],
                              upd_is_reg2, upd_is_imm2, upd_val2, upd_len2);
                    upd_next_pc = reg_file[32] + 32'd2 + upd_len2;
                end
                if (upd_is_reg1) upd_val1 = reg_file[upd_val1[5:0]];
                if (ibuf[1][7] && upd_is_reg2) upd_val2 = reg_file[upd_val2[5:0]];
                upd_cur_psw = {reg_file[33][31:4], f_cy, f_ov, f_s, f_z};
                upd_new_psw = (upd_cur_psw & ~(upd_val2 & 32'hFFFFFF)) |
                              (upd_val1 & upd_val2 & 32'hFFFFFF);

                d.next_state   = S_FETCH0;
                d.flg_update   = 1'b1;
                d.flg_z        = upd_new_psw[0];
                d.flg_s        = upd_new_psw[1];
                d.flg_ov       = upd_new_psw[2];
                d.flg_cy       = upd_new_psw[3];
                d.psw_reg_en   = 1'b1;
                d.psw_reg_val  = upd_new_psw;
                d.pc_en        = 1'b1;
                d.pc_val       = upd_next_pc;
            end

            // ======================================================
            // 0x14-0x18, 0x1A, 0x1E-0x1F — unhandled stubs
            // ======================================================
            8'h14, 8'h15, 8'h16, 8'h17, 8'h18,
            8'h1A,
            8'h1E, 8'h1F: begin
                d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x19 — MOVTHB — truncate halfword to byte
            // ======================================================
            8'h19: begin
                d = exec2(ALU_PASS, 2'd1, 1'b1, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x1B — MOV.H
            // ======================================================
            8'h1B: begin
                d = exec2(ALU_PASS, 2'd1, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x1C — MOVSHW
            // ======================================================
            8'h1C: begin
                d = exec2(ALU_PASS, 2'd1, 1'b0, 1'b1, EXT_MOVSHW);
            end

            // ======================================================
            // 0x1D — MOVZHW
            // ======================================================
            8'h1D: begin
                d = exec2(ALU_PASS, 2'd1, 1'b0, 1'b1, EXT_MOVZHW);
            end

            // ======================================================
            // 0x20 — INB
            // ======================================================
            8'h20: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x21 — OUTB (NOP) / MOVSBW alias
            // Note: MAME 0x21=OUTB stub; some paths use as MOVSBW alias
            // Keep as CMP stub (NOP) consistent with original
            // ======================================================
            8'h21: begin
                d = exec2(ALU_CMP, 2'd0, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x22 — INH
            // ======================================================
            8'h22: begin
                d = exec2(ALU_PASS, 2'd1, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x23 — OUTH
            // ======================================================
            8'h23: begin
                d = exec2(ALU_CMP, 2'd1, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x24 — INW
            // ======================================================
            8'h24: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x25 — OUTW
            // ======================================================
            8'h25: begin
                d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x26-0x28, 0x2A, 0x2E-0x2F — unhandled stubs
            // ======================================================
            8'h26, 8'h27, 8'h28,
            8'h2A,
            8'h2E, 8'h2F: begin
                d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x29 — MOVTWB — truncate word to byte
            // ======================================================
            8'h29: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x2B — MOVTWH — truncate word to halfword
            // ======================================================
            8'h2B: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x2C — RVBYT
            // ======================================================
            8'h2C: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b1, EXT_RVBYT);
            end

            // ======================================================
            // 0x2D — MOV.W
            // ======================================================
            8'h2D: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x30-0x37 — unhandled stubs
            // ======================================================
            8'h30, 8'h31, 8'h32, 8'h33,
            8'h34, 8'h35, 8'h36, 8'h37: begin
                d = exec2(ALU_CMP, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            // ======================================================
            // 0x38/3A/3C — NOT.B/H/W
            // ======================================================
            8'h38: begin
                d = decode_zero();
                d.next_state     = S_EXECUTE;
                d.op_alu_op      = ALU_NOT;   d.op_size        = 2'd0;
                d.op_has_am2     = 1'b0;      d.op_update_flags = 1'b1;
                d.op_is_branch   = 1'b0;      d.op_is_single_am = 1'b1;
                d.op_no_am       = 1'b0;      d.op_is_ext       = 1'b0;
            end
            8'h3A: begin
                d = decode_zero();
                d.next_state     = S_EXECUTE;
                d.op_alu_op      = ALU_NOT;   d.op_size        = 2'd1;
                d.op_has_am2     = 1'b0;      d.op_update_flags = 1'b1;
                d.op_is_branch   = 1'b0;      d.op_is_single_am = 1'b1;
                d.op_no_am       = 1'b0;      d.op_is_ext       = 1'b0;
            end
            8'h3C: begin
                d = decode_zero();
                d.next_state     = S_EXECUTE;
                d.op_alu_op      = ALU_NOT;   d.op_size        = 2'd2;
                d.op_has_am2     = 1'b0;      d.op_update_flags = 1'b1;
                d.op_is_branch   = 1'b0;      d.op_is_single_am = 1'b1;
                d.op_no_am       = 1'b0;      d.op_is_ext       = 1'b0;
            end

            // ======================================================
            // 0x39/3B/3D — NEG.B/H/W
            // ======================================================
            8'h39: begin
                d = decode_zero();
                d.next_state     = S_EXECUTE;
                d.op_alu_op      = ALU_NEG;   d.op_size        = 2'd0;
                d.op_has_am2     = 1'b0;      d.op_update_flags = 1'b1;
                d.op_is_branch   = 1'b0;      d.op_is_single_am = 1'b1;
                d.op_no_am       = 1'b0;      d.op_is_ext       = 1'b0;
            end
            8'h3B: begin
                d = decode_zero();
                d.next_state     = S_EXECUTE;
                d.op_alu_op      = ALU_NEG;   d.op_size        = 2'd1;
                d.op_has_am2     = 1'b0;      d.op_update_flags = 1'b1;
                d.op_is_branch   = 1'b0;      d.op_is_single_am = 1'b1;
                d.op_no_am       = 1'b0;      d.op_is_ext       = 1'b0;
            end
            8'h3D: begin
                d = decode_zero();
                d.next_state     = S_EXECUTE;
                d.op_alu_op      = ALU_NEG;   d.op_size        = 2'd2;
                d.op_has_am2     = 1'b0;      d.op_update_flags = 1'b1;
                d.op_is_branch   = 1'b0;      d.op_is_single_am = 1'b1;
                d.op_no_am       = 1'b0;      d.op_is_ext       = 1'b0;
            end

            // ======================================================
            // 0x3F — MOVD (treat as MOV.W)
            // ======================================================
            8'h3F: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b0, 5'd0);
            end

            default: begin
                d = decode_zero();
                d.next_state = S_TRAP;
            end

        endcase
    end

endmodule : v60_decode_00_3f
