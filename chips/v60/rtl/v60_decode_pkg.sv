// v60_decode_pkg.sv — Shared decode bundle for V60 opcode decode sub-modules
//
// Splitting the 202-entry opcode decode case into 4 sub-modules (one per
// opcode[7:6] range) reduces Quartus peak memory during synthesis.  Each
// sub-module produces a v60_decode_t bundle; v60_core muxes the result.
//
// Register write ports:
//   rw0 / rw1 / rw2  — up to 3 simultaneous register file writes.
//     (Most instructions need 1; MULX needs 2+PC; LDTASK/branches need PC only.)
//   PC update always goes through rw_pc.
//   PSW flag update: use flg_* outputs with flg_update enable.
//
// Bus port: only LDTASK drives the bus directly from S_DECODE; all other
// states handle their own bus transactions.

package v60_decode_pkg;

    // State type must match the typedef in v60_core.sv.
    // We forward-declare as logic[6:0] here; v60_core casts as needed.
    // (Cannot import enum from another package easily without include guards.)

    typedef struct packed {
        // ---- Next FSM state ----
        logic [6:0]  next_state;    // encoded state_t value

        // ---- S_EXECUTE control signals (valid when next_state == S_EXECUTE) ----
        logic [3:0]  op_alu_op;
        logic [1:0]  op_size;
        logic        op_has_am2;
        logic        op_update_flags;
        logic        op_is_branch;
        logic        op_is_single_am;
        logic        op_no_am;
        logic        op_is_ext;
        logic [4:0]  op_ext_op;

        // ---- Register file write port 0 (general purpose) ----
        logic        rw0_en;
        logic [5:0]  rw0_idx;
        logic [31:0] rw0_val;

        // ---- Register file write port 1 (second write, e.g. MULX hi-word) ----
        logic        rw1_en;
        logic [5:0]  rw1_idx;
        logic [31:0] rw1_val;

        // ---- PC update ----
        logic        pc_en;
        logic [31:0] pc_val;

        // ---- PSW flags update ----
        logic        flg_update;
        logic        flg_z;
        logic        flg_s;
        logic        flg_ov;
        logic        flg_cy;
        // Also need to write reg_file[33] on some paths
        logic        psw_reg_en;
        logic [31:0] psw_reg_val;

        // ---- Stack/call helper registers ----
        logic        stk_val_en;
        logic [31:0] stk_val_v;
        logic        stk_size_en;
        logic [1:0]  stk_size_v;
        logic        stk_ret_pc_en;
        logic [31:0] stk_ret_pc_v;
        logic        stk_jump_target_en;
        logic [31:0] stk_jump_target_v;
        logic        stk_dst_reg_en;
        logic [5:0]  stk_dst_reg_v;

        // ---- PREPARE/DISPOSE frame size ----
        logic        prep_frame_size_en;
        logic [31:0] prep_frame_size_v;

        // ---- PUSHM/POPM ----
        logic        pm_mask_en;
        logic [31:0] pm_mask_v;
        logic        pm_idx_en;
        logic [5:0]  pm_idx_v;
        logic        pm_is_popm_en;
        logic        pm_is_popm_v;

        // ---- MOVCUH scratch ----
        logic        movcuh_en;
        logic [31:0] movcuh_src_v;
        logic [31:0] movcuh_dst_v;
        logic [31:0] movcuh_cnt_v;

        // ---- LDTASK scratch ----
        logic        ldtask_ptr_en;
        logic [31:0] ldtask_ptr_v;

        // ---- Bus control (LDTASK only) ----
        logic        bus_en;
        logic [23:0] bus_addr_v;
        logic        bus_as_v;
        logic        bus_rw_v;
        logic [1:0]  bus_ds_v;

    } v60_decode_t;

endpackage : v60_decode_pkg
