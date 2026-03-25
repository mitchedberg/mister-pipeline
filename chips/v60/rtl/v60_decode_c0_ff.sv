// v60_decode_c0_ff.sv — V60 opcode decode sub-module for opcodes 0xC0-0xFF
//
// Pure combinational decode. See v60_decode_pkg.sv for bundle definition.

`default_nettype none
`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHCONCAT */

import v60_decode_pkg::*;

module v60_decode_c0_ff /* synthesis keep_hierarchy on */ (
    input  logic [7:0]  ibuf [0:9],
    input  logic [31:0] reg_file [0:63],
    input  logic        f_z, f_s, f_ov, f_cy,
    output v60_decode_t d
);

    localparam [6:0]
        S_FETCH0        = 7'd1,
        S_EXECUTE       = 7'd22,
        S_TRAP          = 7'd28,
        S_PUSH_SETUP    = 7'd29,
        S_POP_SETUP     = 7'd33,
        S_CALL_PUSH     = 7'd37,
        S_RET_POP       = 7'd41,
        S_PREPARE_PUSH  = 7'd45,
        S_PUSHM_NEXT    = 7'd49,
        S_POPM_NEXT     = 7'd53,
        S_RETIS_PC_LO   = 7'd57;

    localparam [3:0]
        ALU_ADD  = 4'd0,  ALU_SUB  = 4'd1,  ALU_AND  = 4'd2,
        ALU_OR   = 4'd3,  ALU_XOR  = 4'd4,  ALU_NOT  = 4'd5,
        ALU_NEG  = 4'd6,  ALU_PASS = 4'd7,  ALU_SHL  = 4'd8,
        ALU_SHR  = 4'd9,  ALU_SAR  = 4'd10, ALU_CMP  = 4'd11,
        ALU_ROL  = 4'd12, ALU_ROR  = 4'd13;

    // decode_am — identical implementation to v60_core.sv
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
                        5'h1c: begin is_reg=1'b1; am_val={26'd0,rn}; am_bytes=1; end
                        default: begin am_val=32'h0; am_bytes=1; end
                    endcase
                end
            endcase
        end else begin
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
                        5'h1c: begin is_reg=1'b1; am_val={26'd0,rn}; am_bytes=1; end
                        default: begin am_val=32'h0; am_bytes=1; end
                    endcase
                end
            endcase
        end
    endtask

    // -------------------------------------------------------------------------
    // Helper: set all bundle enables to 0 (default — no writes)
    // -------------------------------------------------------------------------
    function automatic v60_decode_t decode_zero();
        v60_decode_t r;
        r = '0;
        return r;
    endfunction

    // -------------------------------------------------------------------------
    // Helper: set the S_EXECUTE control fields and return to S_EXECUTE
    // -------------------------------------------------------------------------
    function automatic v60_decode_t exec2(
        input logic [3:0] alu_op,
        input logic [1:0] sz,
        input logic       has_am2,
        input logic       upd_flags,
        input logic       is_branch,
        input logic       single_am,
        input logic       no_am,
        input logic       is_ext,
        input logic [4:0] ext_op
    );
        v60_decode_t r;
        r = '0;
        r.next_state     = S_EXECUTE;
        r.op_alu_op      = alu_op;
        r.op_size        = sz;
        r.op_has_am2     = has_am2;
        r.op_update_flags = upd_flags;
        r.op_is_branch   = is_branch;
        r.op_is_single_am = single_am;
        r.op_no_am       = no_am;
        r.op_is_ext      = is_ext;
        r.op_ext_op      = ext_op;
        return r;
    endfunction

    // =========================================================================
    // Combinational decode
    // =========================================================================
    always @(*) begin : decode_c0_ff
        logic        am_is_reg, am_is_imm;
        logic [31:0] am_val;
        int          am_len;

        d = decode_zero();

        case (ibuf[0])

            // ==================================================================
            // 0xC0-0xC5 — opUNHANDLED in MAME — two-op NOP stubs
            // ==================================================================
            8'hC0, 8'hC1, 8'hC2, 8'hC3,
            8'hC4, 8'hC5: begin
                d = exec2(ALU_CMP, 2'd2, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 5'd0);
            end

            // ==================================================================
            // 0xC6 — DBxx (decrement-and-branch on condition, 0xC6 set)
            //
            // Format: opcode(1) + ctrl_byte(1) + disp16(2)
            //   ctrl_byte[7:5] = condition code index
            //   ctrl_byte[4:0] = register number Rn
            //
            // Condition codes (s_OpC6Table):
            //   0=DBV  (f_ov)            1=DBL  (f_cy)
            //   2=DBE  (f_z)             3=DBNH (f_cy|f_z)
            //   4=DBN  (f_s)             5=DBR  (always)
            //   6=DBLT (f_s^f_ov)        7=DBLE (f_z|(f_s^f_ov))
            //
            // Action: Rn -= 1; if (cc && Rn!=0) PC += sign_ext16(disp); else PC += 4
            // ==================================================================
            8'hC6: begin
                begin
                    logic [4:0]  db_reg;
                    logic [31:0] db_new;
                    logic        db_cc;
                    db_reg = ibuf[1][4:0];
                    db_new = reg_file[{1'b0, db_reg}] - 32'd1;
                    case (ibuf[1][7:5])
                        3'd0: db_cc = f_ov;
                        3'd1: db_cc = f_cy;
                        3'd2: db_cc = f_z;
                        3'd3: db_cc = f_cy | f_z;
                        3'd4: db_cc = f_s;
                        3'd5: db_cc = 1'b1;
                        3'd6: db_cc = f_s ^ f_ov;
                        3'd7: db_cc = f_z | (f_s ^ f_ov);
                        default: db_cc = 1'b0;
                    endcase
                    // Write decremented register via rw0
                    d.rw0_en  = 1'b1;
                    d.rw0_idx = {1'b0, db_reg};
                    d.rw0_val = db_new;
                    // PC update
                    d.pc_en = 1'b1;
                    if (db_cc && (db_new != 32'd0))
                        d.pc_val = reg_file[32] + {{16{ibuf[3][7]}}, ibuf[3], ibuf[2]};
                    else
                        d.pc_val = reg_file[32] + 32'd4;
                    d.next_state = S_FETCH0;
                end
            end

            // ==================================================================
            // 0xC7 — DBxx / TB (decrement-and-branch, 0xC7 set)
            //
            // Same format as 0xC6 but inverted conditions.
            // Condition code 5 = TB: branch if Rn==0 (no decrement).
            //
            // Condition codes (s_OpC7Table):
            //   0=DBNV (!f_ov)           1=DBNL (!f_cy)
            //   2=DBNE (!f_z)            3=DBH  (!(f_cy|f_z))
            //   4=DBP  (!f_s)            5=TB   (branch if Rn==0, no decrement)
            //   6=DBGE (!(f_s^f_ov))     7=DBGT (!(f_z|(f_s^f_ov)))
            // ==================================================================
            8'hC7: begin
                begin
                    logic [4:0]  db7_reg;
                    logic [31:0] db7_new;
                    logic        db7_cc;
                    logic        db7_tb;
                    db7_reg = ibuf[1][4:0];
                    db7_tb  = (ibuf[1][7:5] == 3'd5);
                    db7_new = reg_file[{1'b0, db7_reg}] - 32'd1;
                    case (ibuf[1][7:5])
                        3'd0: db7_cc = !f_ov;
                        3'd1: db7_cc = !f_cy;
                        3'd2: db7_cc = !f_z;
                        3'd3: db7_cc = !(f_cy | f_z);
                        3'd4: db7_cc = !f_s;
                        3'd5: db7_cc = 1'b1;     // TB: handled below
                        3'd6: db7_cc = !(f_s ^ f_ov);
                        3'd7: db7_cc = !(f_z | (f_s ^ f_ov));
                        default: db7_cc = 1'b0;
                    endcase
                    d.pc_en = 1'b1;
                    if (db7_tb) begin
                        // TB: no decrement; branch if original value == 0
                        if (reg_file[{1'b0, db7_reg}] == 32'd0)
                            d.pc_val = reg_file[32] + {{16{ibuf[3][7]}}, ibuf[3], ibuf[2]};
                        else
                            d.pc_val = reg_file[32] + 32'd4;
                    end else begin
                        // DB* variant: write decremented register
                        d.rw0_en  = 1'b1;
                        d.rw0_idx = {1'b0, db7_reg};
                        d.rw0_val = db7_new;
                        if (db7_cc && (db7_new != 32'd0))
                            d.pc_val = reg_file[32] + {{16{ibuf[3][7]}}, ibuf[3], ibuf[2]};
                        else
                            d.pc_val = reg_file[32] + 32'd4;
                    end
                    d.next_state = S_FETCH0;
                end
            end

            // ==================================================================
            // 0xC8 — BRK — Software Breakpoint (NOP for simulation)
            // 0xC9 — BRKV — Break on Overflow (NOP for simulation)
            // 1-byte instructions; advance PC by 1.
            // ==================================================================
            8'hC8, 8'hC9: begin
                d.pc_en    = 1'b1;
                d.pc_val   = reg_file[32] + 32'd1;
                d.next_state = S_FETCH0;
            end

            // ==================================================================
            // 0xCA — RSR — Return from Subroutine (1-byte, no operand)
            // PC = mem32[SP]; SP += 4
            // Reuse RET_POP machinery with 32-bit size.
            // ==================================================================
            8'hCA: begin
                d.stk_size_en = 1'b1;
                d.stk_size_v  = 2'd2;
                d.next_state  = S_RET_POP;
            end

            // ==================================================================
            // 0xCB — TRAPFL — Trap on Flag (1-byte NOP in simulation)
            // 0xCE, 0xCF — opUNHANDLED (1-byte NOP stubs)
            // ==================================================================
            8'hCB, 8'hCE, 8'hCF: begin
                d.pc_en    = 1'b1;
                d.pc_val   = reg_file[32] + 32'd1;
                d.next_state = S_FETCH0;
            end

            // ==================================================================
            // 0xCC — DISPOSE — Undo PREPARE stack frame
            // SP = FP; FP = mem32[SP]; SP += 4
            // No operand; 1-byte instruction.
            // Sets SP=FP via rw0, then uses POP_SETUP to restore old FP.
            // ==================================================================
            8'hCC: begin
                // SP (reg 31) = FP (reg 30)
                d.rw0_en  = 1'b1;
                d.rw0_idx = 6'd31;
                d.rw0_val = reg_file[30];
                // POP_SETUP will read [new SP] into stk_dst_reg
                d.stk_dst_reg_en = 1'b1;
                d.stk_dst_reg_v  = 6'd30;   // destination = FP (reg 30)
                d.stk_size_en    = 1'b1;
                d.stk_size_v     = 2'd2;    // 32-bit
                // Advance PC
                d.pc_en  = 1'b1;
                d.pc_val = reg_file[32] + 32'd1;
                d.next_state = S_POP_SETUP;
            end

            // ==================================================================
            // 0xCD — NOP — advance PC by 1
            // ==================================================================
            8'hCD: begin
                d.pc_en    = 1'b1;
                d.pc_val   = reg_file[32] + 32'd1;
                d.next_state = S_FETCH0;
            end

            // ==================================================================
            // 0xD0/D1 — DEC.B   0xD2/D3 — DEC.H   0xD4/D5 — DEC.W
            // Single-operand: operand -= 1; flags updated.
            // Format: opcode(1) + AM(1+)
            // ==================================================================
            8'hD0, 8'hD1: begin
                d = exec2(ALU_SUB, 2'd0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end
            8'hD2, 8'hD3: begin
                d = exec2(ALU_SUB, 2'd1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end
            8'hD4, 8'hD5: begin
                d = exec2(ALU_SUB, 2'd2, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end

            // ==================================================================
            // 0xD6/_7 — JMP — indirect jump via AM
            // Single-operand, branch: PC = AM_address
            // op_is_branch=1 tells S_EXECUTE to write result to PC instead of AM.
            // ==================================================================
            8'hD6, 8'hD7: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 5'd0);
            end

            // ==================================================================
            // 0xD8/D9 — INC.B   0xDA/DB — INC.H   0xDC/DD — INC.W
            // Single-operand: operand += 1; flags updated.
            // ==================================================================
            8'hD8, 8'hD9: begin
                d = exec2(ALU_ADD, 2'd0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end
            8'hDA, 8'hDB: begin
                d = exec2(ALU_ADD, 2'd1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end
            8'hDC, 8'hDD: begin
                d = exec2(ALU_ADD, 2'd2, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end

            // ==================================================================
            // 0xDE/DF — PREPARE — allocate stack frame
            // Format: opcode(1) + AM byte(s) (16-bit frame size operand)
            // Step 1: SP -= 4; mem32[SP] = FP
            // Step 2: FP = SP
            // Step 3: SP -= operand
            // Uses S_PREPARE_PUSH states.
            // ==================================================================
            8'hDE, 8'hDF: begin
                begin
                    logic        pr_is_reg, pr_is_imm;
                    logic [31:0] pr_val;
                    int          pr_len;
                    decode_am(1, 2'd1, 1'b0, reg_file[32],
                              pr_is_reg, pr_is_imm, pr_val, pr_len);
                    d.prep_frame_size_en = 1'b1;
                    if (pr_is_reg)
                        d.prep_frame_size_v = {16'd0, reg_file[pr_val[4:0]][15:0]};
                    else if (pr_is_imm)
                        d.prep_frame_size_v = {16'd0, pr_val[15:0]};
                    else
                        d.prep_frame_size_v = 32'd0;
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + pr_len;
                    d.next_state = S_PREPARE_PUSH;
                end
            end

            // ==================================================================
            // 0xE0/E1 — TASI — Test And Set Byte (atomic RMW)
            // Modeled as single-operand TEST only (read byte, set Z from value).
            // Single-operand, byte size.
            // ==================================================================
            8'hE0, 8'hE1: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end

            // ==================================================================
            // 0xE2/E3 — RET — return from subroutine
            // PC = mem32[SP]; SP += 4
            // ==================================================================
            8'hE2, 8'hE3: begin
                d.stk_size_en = 1'b1;
                d.stk_size_v  = 2'd2;
                d.next_state  = S_RET_POP;
            end

            // ==================================================================
            // 0xE4/E5 — POPM — Pop Multiple Registers
            // Format: opcode(1) + AM (32-bit register bitmask)
            // Bit 31 → pop PSW; bits 0-30: bit[b] set → pop into reg[b]
            // Pop order: R0 first (bit 0), then R1..R30; PSW last (bit 31)
            // ==================================================================
            8'hE4, 8'hE5: begin
                begin
                    logic        pm_is_reg_t, pm_is_imm_t;
                    logic [31:0] pm_val_t;
                    int          pm_len_t;
                    decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                              pm_is_reg_t, pm_is_imm_t, pm_val_t, pm_len_t);
                    d.pm_mask_en    = 1'b1;
                    d.pm_mask_v     = pm_val_t;
                    d.pm_idx_en     = 1'b1;
                    d.pm_idx_v      = 6'd0;     // start from bit 0 (R0)
                    d.pm_is_popm_en = 1'b1;
                    d.pm_is_popm_v  = 1'b1;
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + pm_len_t;
                    d.next_state = S_POPM_NEXT;
                end
            end

            // ==================================================================
            // 0xE6/E7 — POP — pop from stack to register or memory
            // 0xE6 = POP.B (modm=0, byte), 0xE7 = POP.W (modm=1, word)
            // Format: opcode(1) + AM(1+)
            // MAME: value = mem[SP]; SP += size; WriteAM(value)
            // ==================================================================
            8'hE6: begin  // POP.B
                begin
                    logic        q_is_reg, q_is_imm;
                    logic [31:0] q_addr;
                    int          q_len;
                    decode_am(1, 2'd0, ibuf[0][0], reg_file[32],
                              q_is_reg, q_is_imm, q_addr, q_len);
                    d.stk_size_en    = 1'b1;
                    d.stk_size_v     = 2'd0;
                    d.stk_dst_reg_en = 1'b1;
                    d.stk_dst_reg_v  = q_addr[5:0];
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + q_len;
                    d.next_state = S_POP_SETUP;
                end
            end

            8'hE7: begin  // POP.W
                begin
                    logic        q_is_reg, q_is_imm;
                    logic [31:0] q_addr;
                    int          q_len;
                    decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                              q_is_reg, q_is_imm, q_addr, q_len);
                    d.stk_size_en    = 1'b1;
                    d.stk_size_v     = 2'd2;
                    d.stk_dst_reg_en = 1'b1;
                    d.stk_dst_reg_v  = q_addr[5:0];
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + q_len;
                    d.next_state = S_POP_SETUP;
                end
            end

            // ==================================================================
            // 0xE8/E9 — JSR — Jump to Subroutine
            // Format: opcode(1) + AM(1+) — no instflags byte
            // MAME: EA = ReadAMAddress(); SP -= 4; mem[SP] = PC+1+amlen; PC = EA
            // modm = opcode bit 0
            // ==================================================================
            8'hE8, 8'hE9: begin
                begin
                    logic        jsr_is_reg, jsr_is_imm;
                    logic [31:0] jsr_addr;
                    int          jsr_len;
                    decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                              jsr_is_reg, jsr_is_imm, jsr_addr, jsr_len);
                    // Return address = PC + 1 (opcode) + jsr_len (AM bytes)
                    d.stk_ret_pc_en      = 1'b1;
                    d.stk_ret_pc_v       = reg_file[32] + 32'd1 + jsr_len;
                    d.stk_jump_target_en = 1'b1;
                    d.stk_jump_target_v  = jsr_addr;
                    d.stk_size_en        = 1'b1;
                    d.stk_size_v         = 2'd2;
                    d.next_state = S_CALL_PUSH;
                end
            end

            // ==================================================================
            // 0xEA/EB — RETIU — Return from Interrupt Unnested
            // Same as RETIS but frame_adj = 0 (no operand).
            // Reuses RETIS states.
            // ==================================================================
            8'hEA, 8'hEB: begin
                d.prep_frame_size_en = 1'b1;
                d.prep_frame_size_v  = 32'd0;
                d.next_state = S_RETIS_PC_LO;
            end

            // ==================================================================
            // 0xEC/ED — PUSHM — Push Multiple Registers
            // Format: opcode(1) + AM (32-bit register bitmask)
            // Bit 31 → push PSW; bits 30-0: bit[30-i] set → push reg[i]
            // Push order: PSW first (bit 31), then R0 (bit 30)..R30 (bit 0)
            // ==================================================================
            8'hEC, 8'hED: begin
                begin
                    logic        pm_is_reg_t, pm_is_imm_t;
                    logic [31:0] pm_val_t;
                    int          pm_len_t;
                    decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                              pm_is_reg_t, pm_is_imm_t, pm_val_t, pm_len_t);
                    d.pm_mask_en    = 1'b1;
                    d.pm_mask_v     = pm_val_t;
                    d.pm_idx_en     = 1'b1;
                    d.pm_idx_v      = 6'd0;     // start from bit 31 (PSW)
                    d.pm_is_popm_en = 1'b1;
                    d.pm_is_popm_v  = 1'b0;
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + pm_len_t;
                    d.next_state = S_PUSHM_NEXT;
                end
            end

            // ==================================================================
            // 0xEE/EF — PUSH — push register or immediate onto stack
            // 0xEE = PUSH.B (byte), 0xEF = PUSH.W (word)
            // Format: opcode(1) + AM(1+)
            // MAME: SP -= size; mem[SP] = value
            // ==================================================================
            8'hEE: begin  // PUSH.B
                begin
                    logic        p_is_reg, p_is_imm;
                    logic [31:0] p_val, p_addr;
                    int          p_len;
                    decode_am(1, 2'd0, ibuf[0][0], reg_file[32],
                              p_is_reg, p_is_imm, p_addr, p_len);
                    if (p_is_reg)
                        p_val = {24'd0, reg_file[p_addr[5:0]][7:0]};
                    else if (p_is_imm)
                        p_val = {24'd0, p_addr[7:0]};
                    else
                        p_val = 32'd0;
                    d.stk_val_en  = 1'b1;
                    d.stk_val_v   = p_val;
                    d.stk_size_en = 1'b1;
                    d.stk_size_v  = 2'd0;
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + p_len;
                    d.next_state = S_PUSH_SETUP;
                end
            end

            8'hEF: begin  // PUSH.W
                begin
                    logic        p_is_reg, p_is_imm;
                    logic [31:0] p_val, p_addr;
                    int          p_len;
                    decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                              p_is_reg, p_is_imm, p_addr, p_len);
                    if (p_is_reg)
                        p_val = reg_file[p_addr[5:0]];
                    else if (p_is_imm)
                        p_val = p_addr;
                    else
                        p_val = 32'd0;
                    d.stk_val_en  = 1'b1;
                    d.stk_val_v   = p_val;
                    d.stk_size_en = 1'b1;
                    d.stk_size_v  = 2'd2;
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + p_len;
                    d.next_state = S_PUSH_SETUP;
                end
            end

            // ==================================================================
            // 0xF0/F1 — TEST.B   0xF2/F3 — TEST.H   0xF4/F5 — TEST.W
            // Single-operand: read, set Z/S/CY/OV flags, no writeback.
            // Format: opcode(1) + AM(1+)
            // ==================================================================
            8'hF0, 8'hF1: begin
                d = exec2(ALU_PASS, 2'd0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end
            8'hF2, 8'hF3: begin
                d = exec2(ALU_PASS, 2'd1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end
            8'hF4, 8'hF5: begin
                d = exec2(ALU_PASS, 2'd2, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 5'd0);
            end

            // ==================================================================
            // 0xF6/F7 — GETPSW — Get PSW into AM destination
            // Single-operand write: writes full PSW to AM destination.
            // If register dest: write PSW to reg[am_val[5:0]] via rw0.
            // Memory write path not modeled (uncommon).
            // ==================================================================
            8'hF6, 8'hF7: begin
                begin
                    logic        gp_is_r, gp_is_i;
                    logic [31:0] gp_a;
                    int          gp_l;
                    logic [31:0] gp_psw;
                    decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                              gp_is_r, gp_is_i, gp_a, gp_l);
                    gp_psw = {reg_file[33][31:4], f_cy, f_ov, f_s, f_z};
                    if (gp_is_r) begin
                        d.rw0_en  = 1'b1;
                        d.rw0_idx = gp_a[5:0];
                        d.rw0_val = gp_psw;
                    end
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + gp_l;
                    d.next_state = S_FETCH0;
                end
            end

            // ==================================================================
            // 0xF8/F9 — TRAP — Software Trap (NOP in simulation)
            // Format: opcode(1) + AM(1+). Advance PC past operand.
            // ==================================================================
            8'hF8, 8'hF9: begin
                begin
                    logic        tr_is_r, tr_is_i;
                    logic [31:0] tr_a;
                    int          tr_l;
                    decode_am(1, 2'd1, ibuf[0][0], reg_file[32],
                              tr_is_r, tr_is_i, tr_a, tr_l);
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + tr_l;
                    d.next_state = S_FETCH0;
                end
            end

            // ==================================================================
            // 0xFA/FB — RETIS — Return from Interrupt Service
            // Format: opcode(1) + AM (16-bit frame_adj operand)
            //   PC  = mem32[SP]; SP += 4
            //   PSW = mem32[SP]; SP += 4
            //   SP  += frame_adj
            // modm from opcode bit 0
            // ==================================================================
            8'hFA, 8'hFB: begin
                begin
                    logic        ri_is_reg, ri_is_imm;
                    logic [31:0] ri_adj;
                    int          ri_len;
                    decode_am(1, 2'd1, ibuf[0][0], reg_file[32],
                              ri_is_reg, ri_is_imm, ri_adj, ri_len);
                    d.prep_frame_size_en = 1'b1;
                    if (ri_is_reg)
                        d.prep_frame_size_v = {16'd0, reg_file[ri_adj[5:0]][15:0]};
                    else if (ri_is_imm)
                        d.prep_frame_size_v = {16'd0, ri_adj[15:0]};
                    else
                        d.prep_frame_size_v = 32'd0;
                    d.next_state = S_RETIS_PC_LO;
                end
            end

            // ==================================================================
            // 0xFC/FD — STTASK — Store Task Register (TR) to AM destination
            // Writes TR = reg_file[42] to AM destination.
            // If register dest: write TR to reg[am_val[5:0]] via rw0.
            // ==================================================================
            8'hFC, 8'hFD: begin
                begin
                    logic        st_is_r, st_is_i;
                    logic [31:0] st_a;
                    int          st_l;
                    decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                              st_is_r, st_is_i, st_a, st_l);
                    if (st_is_r) begin
                        d.rw0_en  = 1'b1;
                        d.rw0_idx = st_a[5:0];
                        d.rw0_val = reg_file[42];   // TR
                    end
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + st_l;
                    d.next_state = S_FETCH0;
                end
            end

            // ==================================================================
            // 0xFE/FF — CLRTLB — Clear TLB Entry (NOP — no TLB in this impl)
            // Format: opcode(1) + AM(1+). Advance PC past operand.
            // ==================================================================
            8'hFE, 8'hFF: begin
                begin
                    logic        ct_is_r, ct_is_i;
                    logic [31:0] ct_a;
                    int          ct_l;
                    decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                              ct_is_r, ct_is_i, ct_a, ct_l);
                    d.pc_en  = 1'b1;
                    d.pc_val = reg_file[32] + 32'd1 + ct_l;
                    d.next_state = S_FETCH0;
                end
            end

            // ==================================================================
            // Default: unimplemented — trap state
            // ==================================================================
            default: begin
                d.next_state = S_TRAP;
            end

        endcase
    end

endmodule : v60_decode_c0_ff
