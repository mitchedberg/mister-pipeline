// v60_core.sv — NEC V60 (uPD70615) CPU core in SystemVerilog
//
// Architecture summary (from v60.cpp, v60.h):
//   - 32 x 32-bit general-purpose registers R0-R31 (R29=AP, R30=FP, R31=SP)
//   - PC  at m_reg[32]
//   - PSW at m_reg[33]  — bits [3:0] = {CY, OV, S, Z}
//   - ISP at m_reg[36], L0SP-L3SP at [37-40], SBR at [41], etc.
//   - 24-bit address bus, 16-bit data bus (V60 uPD70615)
//   - Little-endian
//   - Reset PC = 0xFFFFFFF0, PSW = 0x10000000
//
// Instruction encoding (op12.hxx):
//   Format F1/F2:  opcode[7:0] | instflags[7:0] | [am1 bytes] | [am2 bytes]
//     instflags bit7=1: F1 mode (explicit AM for both operands)
//     instflags bit7=0, bit5=1: D-flag (dest in low 5 bits of instflags, src from AM)
//     instflags bit7=0, bit5=0: src in low 5 bits (register), dest from AM
//   Format single-operand: opcode[7:0] | am_byte | [displacement bytes]
//   Branches: opcode[7:0] | signed_disp8 or signed_disp16
//
// Addressing mode byte (modval):
//   modval[7:5] selects group:
//     000/001  (m=0) → register (m_modval[4:0] = reg index)   → am1Register()
//     000/001  (m=1) → register indirect                        → am1RegisterIndirect()
//     010      → auto-increment
//     011      → auto-decrement
//     100      → displacement8   (1 extra byte)
//     101      → displacement16  (2 extra bytes)
//     110      → displacement32  (4 extra bytes)
//     111      (G7) → further sub-decode via m_modval[4:0]:
//                  0x00-0x1f: various PC-relative, immediate, absolute, indexed
//
// For full AM table see am1.hxx, am2.hxx, am3.hxx in MAME source.
//
// This implementation handles the most common addressing modes:
//   - Register direct (reg[rn])
//   - Register indirect ([rn])
//   - Displacement8/16/32 ([rn + disp])
//   - PC-displacement8/16/32
//   - Immediate (8/16/32-bit inline)
//   - Absolute 32-bit address
//
// FSM states:
//   RESET  → FETCH → DECODE → EX_AM1 → EX_AM2 → EXECUTE → WRITEBACK → FETCH
//
// Bus interface:
//   Byte-addressable; reads/writes use addr_o[23:0], data_i/o[15:0].
//   as_n=0 when address is valid.
//   rw=1 for read, rw=0 for write.
//   ds_n[1:0]: byte enables (active low) — ds_n[0]=lo byte, ds_n[1]=hi byte.
//   dtack_n: bus ready (0 = transfer complete).

`default_nettype none
`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off WIDTHCONCAT */

module v60_core (
    input  logic         clk,
    input  logic         rst_n,        // active-low reset

    // External memory/bus interface (16-bit data, 24-bit address)
    output logic [23:0]  addr_o,
    input  logic [15:0]  data_i,
    output logic [15:0]  data_o,
    output logic         as_n,         // address strobe (active low)
    output logic         rw,           // 1=read, 0=write
    output logic [1:0]   ds_n,         // data strobe byte enables (active low)
    input  logic         dtack_n,      // data transfer acknowledge (0=ready)

    // Interrupt interface
    input  logic         irq_n,        // maskable interrupt (active low)
    input  logic [7:0]   irq_vector,   // interrupt vector number
    input  logic         nmi_n,        // NMI (active low)

    // Debug/status
    output logic [31:0]  dbg_pc,
    output logic [31:0]  dbg_psw,
    output logic [31:0]  dbg_sp,       // R31 = Stack Pointer
    output logic         dbg_halted,
    output logic         dbg_trapped,  // 1 = unimplemented opcode (S_TRAP state)
    output logic [7:0]   dbg_opcode    // opcode byte that caused last TRAP
);

    // =========================================================================
    // Register file — 64 entries to cover all MAME m_reg[] indices
    //   [0-28]  = R0-R28
    //   [29]    = AP (argument pointer)
    //   [30]    = FP (frame pointer)
    //   [31]    = SP (stack pointer)
    //   [32]    = PC
    //   [33]    = PSW
    //   [36]    = ISP
    //   [37-40] = L0SP-L3SP
    //   [41]    = SBR
    //   [42]    = TR
    //   [43]    = SYCW
    //   [44]    = TKCW
    //   [45]    = PIR
    // =========================================================================
    logic [31:0] reg_file [0:63];

    // Convenient aliases (combinational reads, registered writes)
    logic [31:0] r_pc;   assign r_pc  = reg_file[32];
    logic [31:0] r_psw;  assign r_psw = reg_file[33];
    logic [31:0] r_sp;   assign r_sp  = reg_file[31];
    logic [31:0] r_ap;   assign r_ap  = reg_file[29];
    logic [31:0] r_fp;   assign r_fp  = reg_file[30];
    logic [31:0] r_sbr;  assign r_sbr = reg_file[41];

    // PSW flags (maintained separately for speed, merged into PSW on reads)
    // MAME: _Z = bit0, _S = bit1, _OV = bit2, _CY = bit3
    logic        f_z, f_s, f_ov, f_cy;

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    typedef enum logic [6:0] {
        S_RESET,
        S_FETCH0,       // fetch byte 0 (opcode) from PC
        S_FETCH0_WAIT,  // wait for bus on opcode byte
        S_FETCH1,       // fetch byte 1 (instflags / disp8 / operand byte)
        S_FETCH1_WAIT,
        S_FETCH2,       // fetch byte 2
        S_FETCH2_WAIT,
        S_FETCH3,       // fetch byte 3
        S_FETCH3_WAIT,
        S_FETCH4,       // fetch byte 4 (for 32-bit displacements)
        S_FETCH4_WAIT,
        S_FETCH5,
        S_FETCH5_WAIT,
        S_DECODE,       // decode opcode + instflags, figure out AM
        S_AM1_FETCH,    // fetch AM1 extra bytes if needed
        S_AM1_WAIT,
        S_AM2_FETCH,    // fetch AM2 extra bytes if needed
        S_AM2_WAIT,
        S_MEM_READ,          // read lo-word of memory operand
        S_MEM_READ_WAIT,     // wait for lo-word read
        S_MEM_READ_HI,       // setup hi-word read (32-bit only)
        S_MEM_READ_HI_WAIT,  // wait for hi-word read
        S_EXECUTE,      // ALU / branch / flag computation
        S_MEM_WRITE,      // write lo-word of result to memory
        S_MEM_WRITE_WAIT, // wait for lo-word write
        S_MEM_WRITE_HI,   // setup hi-word write (32-bit only)
        S_MEM_WRITE_HI_WAIT, // wait for hi-word write
        S_HALT,
        S_TRAP,         // unimplemented / illegal opcode
        // Stack instruction states
        S_PUSH_SETUP,   // PUSH: compute address, setup write
        S_PUSH_LO_WAIT, // PUSH: wait for lo-word write
        S_PUSH_HI,      // PUSH: setup hi-word write
        S_PUSH_HI_WAIT, // PUSH: wait for hi-word write
        S_POP_SETUP,    // POP: compute address, setup read
        S_POP_LO_WAIT,  // POP: wait for lo-word read
        S_POP_HI,       // POP: setup hi-word read
        S_POP_HI_WAIT,  // POP: wait for hi-word read
        S_CALL_PUSH,         // CALL: push lo-word of return address
        S_CALL_PUSH_LO_WAIT, // CALL: wait for lo-word write to complete
        S_CALL_PUSH_HI,      // CALL: setup hi-word write (one cycle to latch data)
        S_CALL_PUSH_HI_WAIT, // CALL: wait for hi-word write to complete
        S_RET_POP,           // RET: issue lo-word read (SP)
        S_RET_POP_LO_WAIT,   // RET: wait for lo-word read, then deassert
        S_RET_POP_HI,        // RET: issue hi-word read (SP+2)
        S_RET_POP_HI_WAIT,   // RET: wait for hi-word read, restore PC
        // PREPARE states: push FP, set FP=SP, SP-=operand
        S_PREPARE_PUSH,          // PREPARE: push lo-word of FP
        S_PREPARE_PUSH_LO_WAIT,  // PREPARE: wait lo-word
        S_PREPARE_PUSH_HI,       // PREPARE: push hi-word of FP
        S_PREPARE_PUSH_HI_WAIT,  // PREPARE: wait hi-word, finalize SP
        // PUSHM states: push multiple registers from bitmask
        S_PUSHM_NEXT,            // PUSHM: find next set bit, setup write
        S_PUSHM_LO_WAIT,         // PUSHM: wait lo-word write
        S_PUSHM_HI,              // PUSHM: setup hi-word write
        S_PUSHM_HI_WAIT,         // PUSHM: wait hi-word, advance to next reg
        // POPM states: pop multiple registers from bitmask
        S_POPM_NEXT,             // POPM: find next set bit, setup read
        S_POPM_LO_WAIT,          // POPM: wait lo-word read
        S_POPM_HI,               // POPM: setup hi-word read
        S_POPM_HI_WAIT,          // POPM: wait hi-word, write to register, advance
        // RETIS states: pop PC then pop PSW from stack, then SP += frame_adj
        S_RETIS_PC_LO,           // RETIS: read lo-word of PC from [SP]
        S_RETIS_PC_LO_WAIT,      // RETIS: wait for lo-word of PC
        S_RETIS_PC_HI,           // RETIS: read hi-word of PC from [SP+2]
        S_RETIS_PC_HI_WAIT,      // RETIS: latch PC, SP+=4, setup PSW lo-word read
        S_RETIS_PSW_LO,          // RETIS: read lo-word of PSW from [SP]
        S_RETIS_PSW_LO_WAIT,     // RETIS: wait for lo-word of PSW
        S_RETIS_PSW_HI,          // RETIS: read hi-word of PSW from [SP+2]
        S_RETIS_PSW_HI_WAIT,     // RETIS: latch PSW, SP+=4+frame_adj, FETCH0
        // IRQ dispatch states: update PSW, push oldPSW, push PC, read vector table
        S_IRQ_PSW_PUSH,          // IRQ: update PSW, push lo-word of old PSW to [SP-4]
        S_IRQ_PSW_LO_WAIT,       // IRQ: wait for lo-word write of old PSW
        S_IRQ_PSW_HI,            // IRQ: push hi-word of old PSW to [SP-2]
        S_IRQ_PSW_HI_WAIT,       // IRQ: wait for hi-word write of old PSW
        S_IRQ_PC_PUSH,           // IRQ: push lo-word of PC to [SP-4]
        S_IRQ_PC_LO_WAIT,        // IRQ: wait for lo-word write of PC
        S_IRQ_PC_HI,             // IRQ: push hi-word of PC to [SP-2]
        S_IRQ_PC_HI_WAIT,        // IRQ: wait for hi-word write of PC
        S_IRQ_VEC_LO,            // IRQ: read lo-word of vector address from table
        S_IRQ_VEC_LO_WAIT,       // IRQ: wait for lo-word of vector address
        S_IRQ_VEC_HI,            // IRQ: read hi-word of vector address from table
        S_IRQ_VEC_HI_WAIT,       // IRQ: latch vector address, jump to handler
        // MOVCUH: halfword block move (movcuh_src=src, movcuh_cnt=count, movcuh_dst=dst)
        // Reads one halfword from [movcuh_src], writes it to [movcuh_dst],
        // then movcuh_src+=2, movcuh_dst+=2, movcuh_cnt--; repeats until movcuh_cnt==0.
        // On completion: R28 = final src addr, R27 = final dst addr.
        S_MOVCUH_RD,             // MOVCUH: start halfword read from [movcuh_src]
        S_MOVCUH_RD_WAIT,        // MOVCUH: wait for halfword read, latch into movcuh_rd_data
        S_MOVCUH_WR_LO,          // MOVCUH: write halfword movcuh_rd_data to [movcuh_dst]
        S_MOVCUH_WR_LO_WAIT,     // MOVCUH: wait for write; advance ptrs, loop or done
        S_MOVCUH_WR_HI,          // MOVCUH: (unused placeholder — kept for state-enum stability)
        S_MOVCUH_WR_HI_WAIT,     // MOVCUH: (unused placeholder — kept for state-enum stability)
        // LDTASK states: load task register set from memory
        S_LDTASK_TKCW_LO,        // LDTASK: read lo-word of TKCW from [ldtask_ptr]
        S_LDTASK_TKCW_LO_WAIT,   // LDTASK: wait for lo-word of TKCW
        S_LDTASK_TKCW_HI,        // LDTASK: read hi-word of TKCW from [ldtask_ptr+2]
        S_LDTASK_TKCW_HI_WAIT,   // LDTASK: latch TKCW, advance ptr, start register restore
        S_LDTASK_REG_NEXT,        // LDTASK: find next set bit in pm_mask, setup read
        S_LDTASK_REG_LO_WAIT,    // LDTASK: wait for lo-word of register value
        S_LDTASK_REG_HI,          // LDTASK: read hi-word of register value
        S_LDTASK_REG_HI_WAIT      // LDTASK: latch register, advance ptr and idx
    } state_t;

    state_t state, next_state;

    // =========================================================================
    // Instruction decode temporaries
    // =========================================================================
    logic [7:0]  opcode;
    logic [7:0]  instflags;       // byte after opcode for F1/F2 instructions

    // Instruction byte buffer (up to 10 bytes fetched)
    logic [7:0]  ibuf [0:9];
    logic [3:0]  ibuf_cnt;        // how many bytes fetched so far

    // Addressing mode decode results
    // am_flag=1 means operand is a register index; am_flag=0 means memory address
    logic [31:0] op1_val;         // first operand value (for ReadAM)
    logic        op1_flag;        // 1=register, 0=memory
    logic [31:0] op1_addr;        // memory address or reg index
    logic [31:0] op2_val;         // second operand value
    logic        op2_flag;        // 1=register, 0=memory
    logic [31:0] op2_addr;        // address or reg index for writeback
    logic [3:0]  amlength1;       // bytes consumed by AM1
    logic [3:0]  amlength2;       // bytes consumed by AM2
    logic [1:0]  moddim;          // operand size: 0=byte, 1=halfword, 2=word
    logic [31:0] modadd;          // address from which to start AM decode
    logic        modm;            // M bit from instflags (selects AM table half)
    logic [7:0]  modval;          // first AM byte
    logic [7:0]  modval2;         // second AM byte (for indexed modes)

    // Write-back value
    logic [31:0] result_val;      // computed result
    logic        do_writeback;    // should we write result_val to op2?
    logic [1:0]  writeback_size;  // 0=byte, 1=halfword, 2=word

    // Branch target computed during execute
    logic [31:0] branch_target;
    logic        do_branch;

    // Instruction length (PC increment after execution)
    logic [4:0]  instr_len;       // total instruction bytes

    // =========================================================================
    // ALU instantiation (32-bit)
    // =========================================================================
    logic [3:0]  alu_op;
    logic [31:0] alu_a, alu_b;
    logic        alu_cin;
    logic [31:0] alu_result;
    logic        alu_z, alu_s, alu_ov, alu_cy;

    v60_alu #(.WIDTH(32)) u_alu (
        .op        (alu_op),
        .a         (alu_a),
        .b         (alu_b),
        .carry_in  (alu_cin),
        .result    (alu_result),
        .flag_z    (alu_z),
        .flag_s    (alu_s),
        .flag_ov   (alu_ov),
        .flag_cy   (alu_cy)
    );

    // ALU op constants (matching v60_alu.sv)
    localparam ALU_ADD  = 4'd0;
    localparam ALU_SUB  = 4'd1;
    localparam ALU_AND  = 4'd2;
    localparam ALU_OR   = 4'd3;
    localparam ALU_XOR  = 4'd4;
    localparam ALU_NOT  = 4'd5;
    localparam ALU_NEG  = 4'd6;
    localparam ALU_PASS = 4'd7;
    localparam ALU_SHL  = 4'd8;
    localparam ALU_SHR  = 4'd9;
    localparam ALU_SAR  = 4'd10;
    localparam ALU_CMP  = 4'd11;
    localparam ALU_ROL  = 4'd12;
    localparam ALU_ROR  = 4'd13;
    // Extended op codes dispatched via op_ext_op (op_alu_op = ALU_PASS when op_is_ext=1)
    localparam EXT_MUL  = 5'd0;  // signed multiply
    localparam EXT_MULU = 5'd1;  // unsigned multiply
    localparam EXT_DIV  = 5'd2;  // signed divide
    localparam EXT_DIVU = 5'd3;  // unsigned divide
    localparam EXT_SHA  = 5'd4;  // arithmetic shift (signed count: +left, -right)
    localparam EXT_SHL  = 5'd5;  // logical shift (signed count: +left, -right unsigned)
    localparam EXT_SETF = 5'd6;  // set flag byte from condition code
    localparam EXT_LDPR  = 5'd7;  // load privileged register (op1→priv_reg[op2])
    localparam EXT_STPR  = 5'd8;  // store privileged register (priv_reg[op1]→op2)
    localparam EXT_MOVZHW = 5'd9;  // MOVZHW: read 16-bit, zero-extend to 32-bit, write
    localparam EXT_MOVSHW = 5'd10; // MOVSHW: read 16-bit, sign-extend to 32-bit, write
    localparam EXT_MOVZBW = 5'd11; // MOVZBW: read 8-bit, zero-extend to 32-bit, write
    localparam EXT_MOVSBW = 5'd12; // MOVSBW: read 8-bit, sign-extend to 32-bit, write
    localparam EXT_MOVZBH = 5'd13; // MOVZBH: read 8-bit, zero-extend to 16-bit, write
    localparam EXT_ROT   = 5'd14; // ROT: rotate left/right by signed count (+ = left, - = right)
    localparam EXT_MOVSBH = 5'd15; // MOVSBH: read 8-bit, sign-extend to 16-bit, write
    // op_ext_op widened to 5 bits to support additional operations:
    localparam EXT_RVBIT  = 5'd16; // RVBIT: reverse bit order of byte operand
    localparam EXT_RVBYT  = 5'd17; // RVBYT: reverse byte order of 32-bit word (endian swap)
    localparam EXT_TEST1  = 5'd18; // TEST1: test bit op1 of word op2; CY=bit, Z=!CY
    // Note: TEST opcodes use op_no_am=0, op_is_single_am=1
    // For TEST: we handle via NEG-like path with op_update_flags=1 and a special ALU_TEST
    // Actually: repurpose — use ALU_AND with src=0xFFFFFFFF for TEST (ANDs, keeps flags, result discarded)

    // =========================================================================
    // Bus control registers
    // =========================================================================
    logic [23:0] bus_addr_r;
    logic [15:0] bus_data_out_r;
    logic        bus_as_r, bus_rw_r;
    logic [1:0]  bus_ds_r;

    assign addr_o = bus_addr_r;
    assign data_o = bus_data_out_r;
    assign as_n   = bus_as_r;
    assign rw     = bus_rw_r;
    assign ds_n   = bus_ds_r;

    // =========================================================================
    // Pending memory access tracking
    // =========================================================================
    logic [31:0] mem_target_addr;   // address for mem read/write
    logic [1:0]  mem_access_size;   // 0=byte,1=half,2=word
    logic        mem_is_write;
    logic [31:0] mem_write_data;
    logic [31:0] mem_read_result;   // result of completed mem read

    // Which state to return to after memory r/w completes
    state_t      mem_return_state;

    // Temporary 32-bit accumulator for multi-halfword reads
    logic [15:0] mem_lo_half;       // lo 16 bits of 32-bit word read
    logic        mem_second_cycle;  // 1 = doing the hi halfword of a 32-bit read/write
    logic [23:0] mem_hi_addr;       // address for hi halfword

    // =========================================================================
    // Debug outputs
    // =========================================================================
    assign dbg_pc      = reg_file[32];
    assign dbg_psw     = reg_file[33];
    assign dbg_sp      = reg_file[31];  // R31 = SP
    // dbg_halted: use a registered bit set in S_HALT, cleared when leaving S_HALT.
    // This avoids iverilog X-propagation from enum comparison in combinational logic.
    logic dbg_halted_r;
    assign dbg_halted  = dbg_halted_r;
    assign dbg_trapped = (state == S_TRAP);
    assign dbg_opcode  = ibuf[0];  // opcode byte in instruction buffer

    // =========================================================================
    // Helper: pack flags into PSW bits[3:0]
    // =========================================================================
    // MAME: PSW &= ~0xf; PSW |= (Z?1:0)|(S?2:0)|(OV?4:0)|(CY?8:0)
    function automatic logic [31:0] pack_psw(
        input logic [31:0] psw_in,
        input logic        fz, fs, fov, fcy
    );
        pack_psw = (psw_in & 32'hFFFFFFF0) | {28'd0, fcy, fov, fs, fz};
    endfunction

    // =========================================================================
    // Helper: read register by index, masked by size
    // =========================================================================
    function automatic logic [31:0] read_reg_sized(
        input logic [4:0]  idx,
        input logic [1:0]  sz    // 0=byte, 1=half, 2=word
    );
        logic [31:0] rv;
        rv = reg_file[{1'b0, idx}];   // zero-extend 5-bit to 6-bit for 64-entry array
        case (sz)
            2'd0: read_reg_sized = {24'd0, rv[7:0]};
            2'd1: read_reg_sized = {16'd0, rv[15:0]};
            default: read_reg_sized = rv;
        endcase
    endfunction

    // =========================================================================
    // AM decode helper (combinational)
    //
    // Given the modval byte and surrounding instruction bytes, computes:
    //   am_is_reg    — 1 if operand is a register (flag in MAME terms)
    //   am_index     — register index (if am_is_reg) or address/imm value
    //   am_len       — number of bytes consumed (1 = just the modval byte)
    //
    // Supports the most common modes.  Decoded from modval[7:5] (group select)
    // and modval[4:0] (register/sub-opcode).
    //
    // MAME AM table structure (s_AMTable1[m][modval>>5]):
    //   m=0: groups 0-7 mapped per modval[7:5]
    //   m=1: same mapping but with memory-indirect flag set
    //
    // modval[7:5] mapping (from am1.hxx, s_AMTable1 / s_AMTable2):
    //   Group 0 (000): Register         if modval[7]=0,modval[6]=0,modval[5]=0
    //   Group 1 (001): Register indirect
    //   Group 2 (010): Auto-increment
    //   Group 3 (011): Auto-decrement
    //   Group 4 (100): Displacement8    (modval + 1 byte disp)
    //   Group 5 (101): Displacement16   (modval + 2 byte disp)
    //   Group 6 (110): Displacement32   (modval + 4 byte disp)
    //   Group 7 (111): extended — see G7 below
    //
    // M-bit: set by instflags[6] (for operand 1) or instflags[5] (for operand 2)
    //   When M=1, the group mapping shifts to indirect variants.
    //
    // G7 sub-opcodes (modval[4:0] when modval[7:5]==111):
    //   0x00-0x07: PC-Displacement8+Index (additional byte)
    //   0x08-0x0f: PC-Displacement16+Index (additional 2 bytes)
    //   0x10-0x17: PC-Displacement32+Index (additional 4 bytes)
    //   0x18-0x1b: PC-Displacement8/16/32 (no index)
    //   0x1c: Immediate8
    //   0x1d: Immediate16
    //   0x1e: Immediate32
    //   0x1f: Absolute32
    // =========================================================================

    // Addressing mode AM decode is performed combinationally given the ibuf.
    // We decode up to two AMs per instruction.

    // ---- AM Decode Function ----
    // Implements MAME V60 ReadAM / ReadAMAddress dispatch.
    //
    // MAME uses two dispatch table dimensions:
    //   modm = 0: groups 0-7 per s_AMTable1[0]
    //   modm = 1: groups 0-7 per s_AMTable1[1]
    //
    // For F12 format:  modm for op1 = instflags[6], modm for op2 = instflags[5]
    // For single-AM:   modm = 0 for _0 opcode variant, 1 for _1 variant
    //
    // Parameters:
    //   offset  = ibuf byte index where AM byte starts
    //   sz      = operand size: 0=byte, 1=halfword, 2=word
    //   modm    = 0 or non-zero (maps to MAME m_modm)
    //   pc_val  = current PC (for PC-relative modes)
    //
    // Outputs:
    //   is_reg  = 1 → register direct: am_val = reg index (0..63)
    //   is_imm  = 1 → immediate: am_val = immediate value (no mem read)
    //   am_val  = address, register index, or immediate value
    //   am_bytes = total bytes consumed by this AM field (incl. modval byte)

    task automatic decode_am(
        input  int           offset,   // ibuf byte index of AM modval byte
        input  logic [1:0]   sz,       // operand size 0/1/2
        input  logic         modm,     // 0 = table[0], 1 = table[1]
        input  logic [31:0]  pc_val,   // current PC value
        output logic         is_reg,   // register direct
        output logic         is_imm,   // immediate value
        output logic [31:0]  am_val,   // result
        output int           am_bytes  // bytes consumed
    );
        logic [7:0] mv;
        logic [5:0] rn;     // base register (modval[4:0])
        logic [2:0] grp;    // modval[7:5] → group index
        logic [7:0] mv2;    // second byte (for Group6/indexed)
        logic [5:0] rn2;    // index register (mv2[4:0])

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
            // =====================================================
            // modm=0 → s_AMTable1[0][modval>>5]
            //   0: Displacement8   [Rn + sign_ext(disp8)]
            //   1: Displacement16  [Rn + sign_ext(disp16)]
            //   2: Displacement32  [Rn + disp32]
            //   3: RegisterIndirect [Rn] (address)
            //   4: DisplacementIndirect8  [mem32[Rn+disp8]] (indirect)
            //   5: DisplacementIndirect16
            //   6: DisplacementIndirect32
            //   7: Group7 (extended, dispatch on modval[4:0])
            // =====================================================
            case (grp)
                3'd0: begin  // Displacement8
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                    am_bytes = 2;
                end
                3'd1: begin  // Displacement16
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{16{ibuf[offset+2][7]}},
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 3;
                end
                3'd2: begin  // Displacement32
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {ibuf[offset+4], ibuf[offset+3],
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 5;
                end
                3'd3: begin  // RegisterIndirect [Rn]
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn];
                    am_bytes = 1;
                end
                3'd4: begin  // DisplacementIndirect8: addr = mem32[Rn + disp8]
                    // For ReadAMAddress: return the indirect address; caller must do mem read
                    is_reg   = 1'b0;
                    // Note: actual mem[Rn+disp8] read happens in S_MEM_READ
                    // For now return the EA of the pointer (caller will read pointer, then read/write target)
                    am_val   = reg_file[rn] + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                    am_bytes = 2;
                end
                3'd5: begin  // DisplacementIndirect16
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{16{ibuf[offset+2][7]}},
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 3;
                end
                3'd6: begin  // DisplacementIndirect32
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {ibuf[offset+4], ibuf[offset+3],
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 5;
                end
                3'd7: begin  // Group7 extended
                    is_reg = 1'b0;
                    case (mv[4:0])
                        // 0x00-0x0F: ImmediateQuick — value = modval[3:0]
                        5'h00, 5'h01, 5'h02, 5'h03,
                        5'h04, 5'h05, 5'h06, 5'h07,
                        5'h08, 5'h09, 5'h0a, 5'h0b,
                        5'h0c, 5'h0d, 5'h0e, 5'h0f: begin
                            is_imm   = 1'b1;
                            am_val   = {28'd0, mv[3:0]};
                            am_bytes = 1;
                        end
                        // 0x10: PCDisplacement8 — PC + sign_ext(disp8)
                        5'h10: begin
                            am_val   = pc_val + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                            am_bytes = 2;
                        end
                        // 0x11: PCDisplacement16 — PC + sign_ext(disp16)
                        5'h11: begin
                            am_val   = pc_val + {{16{ibuf[offset+2][7]}},
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 3;
                        end
                        // 0x12: PCDisplacement32 — PC + disp32
                        5'h12: begin
                            am_val   = pc_val + {ibuf[offset+4], ibuf[offset+3],
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        // 0x13: DirectAddress — absolute 32-bit address in instruction
                        5'h13: begin
                            am_val   = {ibuf[offset+4], ibuf[offset+3],
                                        ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        // 0x14: Immediate (size-dependent)
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
                        // 0x18: PCDisplacementIndirect8 — address = mem32[PC+disp8]
                        5'h18: begin
                            // Return pointer address; caller handles the mem read
                            am_val   = pc_val + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                            am_bytes = 2;
                        end
                        // 0x19: PCDisplacementIndirect16
                        5'h19: begin
                            am_val   = pc_val + {{16{ibuf[offset+2][7]}},
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 3;
                        end
                        // 0x1a: PCDisplacementIndirect32
                        5'h1a: begin
                            am_val   = pc_val + {ibuf[offset+4], ibuf[offset+3],
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        // 0x1b: DirectAddressDeferred — mem32[addr32]
                        5'h1b: begin
                            am_val   = {ibuf[offset+4], ibuf[offset+3],
                                        ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                        // 0x1c: PCDoubleDisplacement8 — mem32[PC+disp8]+disp8
                        5'h1c: begin
                            am_val   = pc_val + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                            am_bytes = 3;  // modval + disp8 + second_disp8
                        end
                        // 0x1d: PCDoubleDisplacement16
                        5'h1d: begin
                            am_val   = pc_val + {{16{ibuf[offset+2][7]}},
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;  // modval + disp16 + second_disp16
                        end
                        // 0x1e: PCDoubleDisplacement32
                        5'h1e: begin
                            am_val   = pc_val + {ibuf[offset+4], ibuf[offset+3],
                                                  ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 9;  // modval + disp32 + second_disp32
                        end
                        default: begin
                            // 0x15-0x17, 0x1f: error/unused
                            am_val   = {ibuf[offset+4], ibuf[offset+3],
                                        ibuf[offset+2], ibuf[offset+1]};
                            am_bytes = 5;
                        end
                    endcase
                end
            endcase
        end else begin
            // =====================================================
            // modm=1 → s_AMTable1[1][modval>>5]
            //   0: DoubleDisplacement8  mem[mem[Rn+disp8]+disp8]
            //   1: DoubleDisplacement16
            //   2: DoubleDisplacement32
            //   3: Register direct (rn = modval[4:0])
            //   4: Autoincrement  [Rn++]
            //   5: Autodecrement  [--Rn]
            //   6: Group6 (indexed — reads second modval byte)
            //   7: Error
            // =====================================================
            case (grp)
                3'd0: begin  // DoubleDisplacement8: EA = mem[Rn+disp8]+disp8_2
                    is_reg   = 1'b0;
                    // Return the pointer address; second displacement applied after mem read
                    am_val   = reg_file[rn] + {{24{ibuf[offset+1][7]}}, ibuf[offset+1]};
                    am_bytes = 3;  // modval + disp8 + disp8_2
                end
                3'd1: begin  // DoubleDisplacement16
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {{16{ibuf[offset+2][7]}},
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 5;  // modval + disp16 + disp16_2
                end
                3'd2: begin  // DoubleDisplacement32
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn] + {ibuf[offset+4], ibuf[offset+3],
                                                ibuf[offset+2], ibuf[offset+1]};
                    am_bytes = 9;  // modval + disp32 + disp32_2
                end
                3'd3: begin  // Register direct
                    is_reg   = 1'b1;
                    am_val   = {26'd0, rn};  // register index
                    am_bytes = 1;
                end
                3'd4: begin  // Autoincrement [Rn++]
                    is_reg   = 1'b0;
                    am_val   = reg_file[rn];  // pre-increment address
                    am_bytes = 1;
                end
                3'd5: begin  // Autodecrement [--Rn]
                    is_reg   = 1'b0;
                    case (sz)
                        2'd0: am_val = reg_file[rn] - 32'd1;
                        2'd1: am_val = reg_file[rn] - 32'd2;
                        2'd2: am_val = reg_file[rn] - 32'd4;
                        default: am_val = reg_file[rn] - 32'd4;
                    endcase
                    am_bytes = 1;
                end
                3'd6: begin  // Group6: indexed modes (second modval byte = mv2)
                    // mv2[7:5] selects sub-mode; mv2[4:0] = index register
                    case (mv2[7:5])
                        3'd0: begin  // DisplacementIndexed8: [Rn + Rx*scale + disp8]
                            case (sz)
                                2'd0: am_val = reg_file[rn] + {24'd0, ibuf[offset+2]} + reg_file[rn2];
                                2'd1: am_val = reg_file[rn] + {24'd0, ibuf[offset+2]} + (reg_file[rn2] << 1);
                                2'd2: am_val = reg_file[rn] + {24'd0, ibuf[offset+2]} + (reg_file[rn2] << 2);
                                default: am_val = reg_file[rn] + reg_file[rn2];
                            endcase
                            am_bytes = 3;
                        end
                        3'd1: begin  // DisplacementIndexed16
                            case (sz)
                                2'd0: am_val = reg_file[rn] + {{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]} + reg_file[rn2];
                                2'd1: am_val = reg_file[rn] + {{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]} + (reg_file[rn2] << 1);
                                2'd2: am_val = reg_file[rn] + {{16{ibuf[offset+3][7]}},ibuf[offset+3],ibuf[offset+2]} + (reg_file[rn2] << 2);
                                default: am_val = reg_file[rn] + reg_file[rn2];
                            endcase
                            am_bytes = 4;
                        end
                        3'd2: begin  // DisplacementIndexed32
                            case (sz)
                                2'd0: am_val = reg_file[rn] + {ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]} + reg_file[rn2];
                                2'd1: am_val = reg_file[rn] + {ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]} + (reg_file[rn2] << 1);
                                2'd2: am_val = reg_file[rn] + {ibuf[offset+5],ibuf[offset+4],ibuf[offset+3],ibuf[offset+2]} + (reg_file[rn2] << 2);
                                default: am_val = reg_file[rn] + reg_file[rn2];
                            endcase
                            am_bytes = 6;
                        end
                        3'd3: begin  // RegisterIndirectIndexed: [Rb + Rx*scale]
                            case (sz)
                                2'd0: am_val = reg_file[rn] + reg_file[rn2];
                                2'd1: am_val = reg_file[rn] + (reg_file[rn2] << 1);
                                2'd2: am_val = reg_file[rn] + (reg_file[rn2] << 2);
                                default: am_val = reg_file[rn] + reg_file[rn2];
                            endcase
                            am_bytes = 2;
                        end
                        default: begin  // DisplacementIndirectIndexed / Group7a
                            // Simplified: treat as DisplacementIndexed8
                            am_val   = reg_file[rn] + {24'd0, ibuf[offset+2]} + reg_file[rn2];
                            am_bytes = 3;
                        end
                    endcase
                end
                default: begin  // 3'd7: Error
                    am_val   = 32'h0;
                    am_bytes = 1;
                end
            endcase
        end
    endtask

    // =========================================================================
    // Registers for inter-state communication
    // =========================================================================
    // Opcode decode results
    logic [3:0]  op_alu_op;        // ALU operation to perform
    logic [1:0]  op_size;          // operand size (0=B,1=H,2=W)
    logic        op_has_am2;       // instruction has second operand
    logic        op_update_flags;  // should we update PSW flags?
    logic        op_is_branch;     // branch instruction
    logic        op_is_single_am;  // single-AM instruction (INC/DEC/JMP/etc.)
    logic        op_no_am;         // no-AM instruction (NOP/HALT/branch)
    logic [4:0]  op_instr_base_len; // bytes before first AM byte
    // Extended operation dispatch
    logic        op_is_ext;        // 1 = use EXT_* operation in S_EXECUTE
    logic [4:0]  op_ext_op;        // which extended operation (EXT_*)
    // mem_loaded flag: prevents re-decoding AM when S_EXECUTE is re-entered after S_MEM_READ
    logic        mem_loaded;       // 1 = mem_read_result contains valid data from last read

    // =========================================================================
    // S_EXECUTE temporaries (module-level for iverilog compatibility)
    // These are written-before-read in S_EXECUTE so no latching issue.
    // =========================================================================
    logic        ex_is_reg1, ex_is_reg2;
    logic        ex_is_imm1, ex_is_imm2;  // 1 = am_val is immediate (no mem read)
    logic [31:0] ex_am1_addr, ex_am2_addr;
    int          ex_am1_len, ex_am2_len;
    logic [1:0]  ex_sz;
    logic [31:0] ex_src_val, ex_dst_val, ex_res_val;
    logic        ex_do_wb;
    logic [31:0] ex_instr_pc;
    logic [31:0] ex_total_len;
    logic [7:0]  ex_iflags;
    logic [4:0]  ex_reg_in_iflags;
    // Extended arithmetic intermediates
    logic [8:0]  ex_add_b, ex_sub_b, ex_cmp_b;
    logic [16:0] ex_add_h, ex_sub_h, ex_cmp_h;
    logic [32:0] ex_add_w, ex_sub_w, ex_cmp_w;

    // PUSH/POP/CALL/RET helper registers
    logic [31:0] stk_val;          // value to push or popped value
    logic [31:0] stk_ret_pc;       // return address for CALL
    logic [31:0] stk_jump_target;  // jump target for CALL/JMP
    logic [15:0] stk_lo_half;      // lo 16 bits of 32-bit stack read
    logic [1:0]  stk_size;         // operand size for PUSH/POP (0=B,1=H,2=W)
    logic [5:0]  stk_dst_reg;      // destination register for POP
    // Temporary for address arithmetic (iverilog can't part-select on expressions)
    logic [31:0] stk_addr_tmp;
    // PREPARE/DISPOSE helper
    logic [31:0] prep_frame_size;  // frame size operand for PREPARE (SP -= this)
    // PUSHM/POPM helpers
    logic [31:0] pm_mask;          // register bitmask for PUSHM/POPM
    logic [5:0]  pm_idx;           // current bit index being processed (0..31, 6-bit to detect overflow)
    logic [31:0] pm_reg_val;       // value of current register to push
    logic        pm_is_popm;       // 1=POPM, 0=PUSHM
    logic [15:0] pm_pop_lo;        // lo-half of popped word
    // MUL/DIV 64-bit intermediates (module-level for iverilog compatibility)
    logic [63:0] ex_mul64;
    logic [31:0] ex_div_quotient;
    // SETF condition input (op1 & 0xF selects condition)
    logic [31:0] ex_setf_cond;
    // IRQ dispatch scratch registers
    logic [31:0] irq_old_psw;     // PSW saved before IRQ dispatch
    logic [7:0]  irq_vector_num;  // interrupt vector number (0x40 + external vector)
    logic [31:0] irq_vec_addr;    // computed vector table address: (SBR&~0xFFF)+vector*4
    // MOVCUH scratch
    logic [31:0] movcuh_src;      // decoded source address
    logic [31:0] movcuh_dst;      // decoded dest address
    logic [31:0] movcuh_cnt;      // decoded element count (min of lenop1, lenop2)
    logic [15:0] movcuh_rd_data;  // latched halfword read from source
    // LDTASK scratch
    logic [31:0] ldtask_ptr;      // current read address walking through task record
    logic [15:0] ldtask_lo;       // lo-half latched during 32-bit read

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ---------------- RESET ----------------
            // MAME device_reset(): PC=0xFFFFFFF0, PSW=0x10000000
            for (int i = 0; i < 64; i++) reg_file[i] <= 32'd0;
            reg_file[32] <= 32'hFFFFFFF0;  // PC
            reg_file[33] <= 32'h10000000;  // PSW (interrupt mode)
            reg_file[43] <= 32'h00000070;  // SYCW
            reg_file[44] <= 32'h0000e000;  // TKCW
            reg_file[51] <= 32'h0000f002;  // PSW2

            f_z  <= 1'b0;
            f_s  <= 1'b0;
            f_ov <= 1'b0;
            f_cy <= 1'b0;

            state        <= S_RESET;
            ibuf_cnt     <= '0;
            bus_as_r     <= 1'b1;   // inactive
            bus_rw_r     <= 1'b1;
            bus_ds_r     <= 2'b11;  // inactive
            bus_addr_r   <= '0;
            bus_data_out_r <= '0;
            mem_second_cycle <= 1'b0;

            opcode       <= 8'h00;
            instflags    <= 8'h00;
            do_branch    <= 1'b0;
            do_writeback <= 1'b0;
            result_val   <= 32'd0;
            op_is_ext    <= 1'b0;
            op_ext_op    <= 5'd0;
            mem_loaded   <= 1'b0;
            prep_frame_size <= 32'd0;
            // Initialize ibuf to known values so TRAP display shows correct opcode
            ibuf[0] <= 8'h00; ibuf[1] <= 8'h00; ibuf[2] <= 8'h00; ibuf[3] <= 8'h00;
            ibuf[4] <= 8'h00; ibuf[5] <= 8'h00; ibuf[6] <= 8'h00; ibuf[7] <= 8'h00;
            ibuf[8] <= 8'h00; ibuf[9] <= 8'h00;
            dbg_halted_r <= 1'b0;

        end else begin
            case (state)

                // ============================================================
                S_RESET: begin
                    // One idle cycle after reset before starting fetch
                    state <= S_FETCH0;
                end

                // ============================================================
                // FETCH0: start a bus read for the opcode byte at PC
                // ============================================================
                S_FETCH0: begin
                    dbg_halted_r <= 1'b0;  // clear HALT flag on any new fetch
                    ibuf_cnt <= 4'd0;
                    // Check for pending interrupts between instructions.
                    // NMI is highest priority (unconditional, vector 2).
                    // Maskable IRQ only if PSW.IE=1.
                    // Real V60 hardware checks both between each instruction.
                    if (!nmi_n) begin
                        // NMI: vector 2, address = (SBR & ~0xFFF) + 8
                        irq_vector_num <= 8'h02;
                        irq_vec_addr   <= (reg_file[41] & 32'hFFFFF000) + 32'h08;
                        irq_old_psw    <= reg_file[33];
                        state          <= S_IRQ_PSW_PUSH;
                    end else if (!irq_n && reg_file[33][18]) begin
                        // Maskable IRQ: vector = ext_vec + 0x40
                        irq_vector_num <= {1'b0, irq_vector[6:0]} + 8'h40;
                        irq_vec_addr   <= ((reg_file[41] & 32'hFFFFF000) +
                                          ({24'd0, {1'b0, irq_vector[6:0]}} + 32'h40) * 4);
                        irq_old_psw    <= reg_file[33];
                        state          <= S_IRQ_PSW_PUSH;
                    end else begin
                        // Issue read for 16-bit half-word at PC (little-endian bus)
                        bus_addr_r <= reg_file[32][23:0];
                        bus_as_r   <= 1'b0;    // address strobe active
                        bus_rw_r   <= 1'b1;    // read
                        bus_ds_r   <= 2'b00;   // both bytes
                        state      <= S_FETCH0_WAIT;
                    end
                end

                S_FETCH0_WAIT: begin
                    if (!dtack_n) begin
                        // Deassert strobe
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        // Store two bytes
                        ibuf[0]  <= data_i[7:0];
                        ibuf[1]  <= data_i[15:8];
                        opcode   <= data_i[7:0];
                        ibuf_cnt <= 4'd2;
                        state    <= S_FETCH1;  // fetch next 2 bytes preemptively
                        // (fetch0 debug trace removed)
                    end
                end

                // ============================================================
                // FETCH1: prefetch next 2 bytes (handles most instructions)
                // ============================================================
                S_FETCH1: begin
                    bus_addr_r <= reg_file[32][23:0] + 24'd2;
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_FETCH1_WAIT;
                end

                S_FETCH1_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        ibuf[2]  <= data_i[7:0];
                        ibuf[3]  <= data_i[15:8];
                        ibuf_cnt <= 4'd4;
                        state    <= S_FETCH2;
                    end
                end

                // ============================================================
                // FETCH2: prefetch 4 more bytes (covers 32-bit displacements)
                // ============================================================
                S_FETCH2: begin
                    bus_addr_r <= reg_file[32][23:0] + 24'd4;
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_FETCH2_WAIT;
                end

                S_FETCH2_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        ibuf[4]  <= data_i[7:0];
                        ibuf[5]  <= data_i[15:8];
                        ibuf_cnt <= 4'd6;
                        state    <= S_FETCH3;
                    end
                end

                S_FETCH3: begin
                    bus_addr_r <= reg_file[32][23:0] + 24'd6;
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_FETCH3_WAIT;
                end

                S_FETCH3_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        ibuf[6]  <= data_i[7:0];
                        ibuf[7]  <= data_i[15:8];
                        ibuf[8]  <= data_i[7:0];   // placeholder
                        ibuf[9]  <= data_i[15:8];
                        ibuf_cnt <= 4'd8;
                        state    <= S_DECODE;
                    end
                end

                // ============================================================
                // DECODE: interpret opcode, compute operand addresses
                // ============================================================
                S_DECODE: begin
                    // At this point ibuf[0] = opcode, ibuf[1] = instflags (for F1/F2)
                    // We decode here and proceed to EXECUTE (or memory states first)
                    instflags <= ibuf[1];
                    do_branch    <= 1'b0;
                    do_writeback <= 1'b0;
                    result_val   <= 32'd0;
                    op_is_ext    <= 1'b0;  // clear extended flag; set per-case when needed
                    mem_loaded   <= 1'b0;  // clear mem_loaded at start of new decode
                    // Boot exit trace — only show when PC leaves the boot ROM area (0x7F8C0-0x7FC00)
                    // or is in the post-CRC comparison section (0x7F971-0x7FC00)
                    // Suppress the entire CRC loop (0x7F95C-0x7F970) to avoid flooding output
                    if ((reg_file[32] >= 32'h07F8C0 && reg_file[32] <= 32'h07FC00) &&
                        !(reg_file[32] >= 32'h07F95C && reg_file[32] <= 32'h07F970))
                        $display("[bootloop] PC=0x%06X  op=0x%02X  ib=%02X %02X %02X %02X %02X  PSW=0x%08X  FLAGS:cy=%b ov=%b s=%b z=%b  R0=0x%08X  R1=0x%08X  R11=%08X  R25=%08X R31=SP:%08X",
                                 reg_file[32], ibuf[0], ibuf[1], ibuf[2], ibuf[3], ibuf[4], ibuf[5],
                                 reg_file[33], f_cy, f_ov, f_s, f_z,
                                 reg_file[0], reg_file[1], reg_file[11],
                                 reg_file[25], reg_file[31]);

                    // ----------------------------------------------------------
                    // Decode each opcode.  References are to the MAME source
                    // handler function in the op*.hxx files.
                    //
                    // Calling convention (from op12.hxx F12DecodeOperands):
                    //   instflags[7]=1: F1 mode — two explicit AM fields
                    //   instflags[7]=0, [5]=1: D-mode — dest=ibuf[1][4:0] (reg), src=AM at ibuf[2]
                    //   instflags[7]=0, [5]=0: S-mode — src=ibuf[1][4:0] (reg), dest=AM at ibuf[2]
                    //
                    // We use a flattened approach: decode both operands inline
                    // using the decode_am task, then proceed.
                    // ----------------------------------------------------------

                    case (ibuf[0])

                        // ======================================================
                        // 0xCD — NOP (opNOP)
                        // "return 1" — advances PC by 1
                        // ======================================================
                        8'hCD: begin
                            reg_file[32] <= reg_file[32] + 32'd1;
                            state        <= S_FETCH0;
                        end

                        // ======================================================
                        // 0x00 — HALT (opHALT)
                        // In MAME: "return 1" (advance PC by 1 and continue).
                        // Real hardware halts until interrupt; MAME skips it.
                        // For sim bootstrapping: treat as NOP (advance PC by 1).
                        // The CPU will re-execute HALT on loop until NMI fires.
                        // ======================================================
                        8'h00: begin
                            reg_file[32] <= reg_file[32] + 32'd1;
                            state        <= S_FETCH0;
                        end

                        // ======================================================
                        // 0x09 — MOV.B (opMOVB) — TRUSTED
                        // F12DecodeFirstOperand(ReadAM, 0) + F12WriteSecondOperand(0)
                        // instflags format (F1/F2/D):
                        //   F12DecodeFirstOperand: reads op1 from AM or register
                        //   F12WriteSecondOperand: writes to AM or register
                        // Total length: 2 + amlength1 + amlength2
                        // ======================================================
                        8'h09: begin
                            // Handled in EXECUTE state after AM decode
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_PASS;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b0;  // MOV doesn't update flags
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x1B — MOV.H (opMOVH) — TRUSTED
                        // Same as MOV.B but for 16-bit halfword
                        // ======================================================
                        8'h1B: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_PASS;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x03 — GETRA  — Get Real Address   (MMU/TLB stub)
                        // 0x04 — GETPTE — Get Page Table Entry (MMU stub)
                        // 0x05 — GETATE — Get Address Translation Entry (stub)
                        // F1/F2 two-operand format. These are MMU instructions that
                        // MAME marks as unhandled (opUNHANDLED). Stub as ALU_CMP
                        // (no writeback, no flags) so AM fields are decoded and PC
                        // advances correctly without corrupting memory.
                        // ======================================================
                        // 0x06, 0x07, 0x0E, 0x0F: also UNHANDLED in MAME — stubs
                        8'h03, 8'h04, 8'h05, 8'h06, 8'h07,
                        8'h0E, 8'h0F: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_CMP;   // no writeback; op2 read not needed
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b0;   // don't update flags either
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // opUNHANDLED stubs — 0x11, 0x14-0x18, 0x1A, 0x1E-0x1F,
                        //   0x26-0x28, 0x2A, 0x2E-0x2F
                        // These are all opUNHANDLED in MAME (would fatal in real
                        // emulation). Stub as ALU_CMP so the F1/F2 AM decode
                        // consumes the instruction bytes and advances PC, but no
                        // data is written and no flags are updated.
                        // ======================================================
                        8'h11,
                        8'h14, 8'h15, 8'h16, 8'h17, 8'h18,
                        8'h1A,
                        8'h1E, 8'h1F,
                        8'h26, 8'h27, 8'h28,
                        8'h2A,
                        8'h2E, 8'h2F: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_CMP;   // no writeback
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x2D — MOV.W (opMOVW) — TRUSTED
                        // Same as MOV.B but for 32-bit word
                        // ======================================================
                        8'h2D: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_PASS;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x1B — MOVH — Move Halfword
                        // 0x1C — MOVSHW — Move Sign-Extended Halfword to Word
                        // 0x1D — MOVZHW — Move Zero-Extended Halfword to Word
                        // 0x19 — MOVTHB — Move Truncated Halfword to Byte (w/ OV check)
                        // 0x2B — MOVTWH — Move Truncated Word to Halfword
                        // 0x29 — MOVTWB — Move Truncated Word to Byte
                        // 0x0A — MOVSBH — Move Sign-Extended Byte to Halfword
                        // 0x0B — MOVZBH — Move Zero-Extended Byte to Halfword
                        // 0x09 — MOVB — Move Byte (TRUSTED)
                        // 0x0C, 0x21 — MOVSBW aliases — Move Sign-Extended Byte to Word
                        //
                        // All use F12DecodeFirstOperand(ReadAM, dim) + F12WriteSecondOperand(dim2)
                        // MOVH:   src=halfword (1), dst=halfword (1)
                        // MOVZHW: src=halfword (1), dst=word (2), zero-extend
                        // MOVSHW: src=halfword (1), dst=word (2), sign-extend
                        // MOVTHB: src=halfword (1), dst=byte (0), truncate
                        // MOVZBH: src=byte (0), dst=halfword (1), zero-extend
                        // MOVSBH: src=byte (0), dst=halfword (1), sign-extend
                        // MOVZBW: src=byte (0), dst=word (2), zero-extend
                        // MOVSBW: src=byte (0), dst=word (2), sign-extend
                        // MOVTWH: src=word (2), dst=halfword (1), truncate
                        // MOVTWB: src=word (2), dst=byte (0), truncate
                        // ======================================================
                        8'h1B: begin  // MOVH — halfword to halfword
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd1;
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h1C: begin  // MOVSHW — sign-extend halfword to word
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MOVSHW;
                            op_size <= 2'd1;  // read source as halfword
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h1D: begin  // MOVZHW — zero-extend halfword to word
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MOVZHW;
                            op_size <= 2'd1;  // read source as halfword
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h19: begin  // MOVTHB — truncate halfword to byte
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd1;  // read halfword (write byte below)
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h0B: begin  // MOVZBH — zero-extend byte to halfword
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MOVZBH;
                            op_size <= 2'd0;  // read byte
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h0D: begin  // MOVZBW — zero-extend byte to word
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MOVZBW;
                            op_size <= 2'd0;  // read byte
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h0F: begin  // MOVSBW — sign-extend byte to word
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MOVSBW;
                            op_size <= 2'd0;  // read byte
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h0A: begin  // MOVSBH — sign-extend byte to halfword
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MOVSBH;
                            op_size <= 2'd0;  // read byte
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h0C, 8'h21: begin  // MOVSBW — sign-extend byte to word (aliases)
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MOVSBW;
                            op_size <= 2'd0;  // read byte
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h2B: begin  // MOVTWH — truncate word to halfword
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd2;  // read word (write halfword)
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h29: begin  // MOVTWB — truncate word to byte
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd2;  // read word (write byte)
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x08 — RVBIT — Reverse Bit Order (byte)
                        // MAME: F12DecodeFirstOperand(ReadAM,0) → bitswap(op1,0..7)
                        //       F12WriteSecondOperand(0)
                        // Read source byte, reverse all 8 bits, write to dest.
                        // ======================================================
                        8'h08: begin  // RVBIT
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_RVBIT;
                            op_size <= 2'd0;  // byte operand
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x2C — RVBYT — Reverse Byte Order (32-bit endian swap)
                        // MAME: F12DecodeFirstOperand(ReadAM,2) → swapendian_int32(op1)
                        //       F12WriteSecondOperand(2)
                        // Read source word, swap byte order, write to dest.
                        // ======================================================
                        8'h2C: begin  // RVBYT
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_RVBYT;
                            op_size <= 2'd2;  // word operand
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b0;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x87 — TEST1 — Test Bit
                        // MAME: F12DecodeOperands(ReadAM,2, ReadAM,2)
                        //   op1 = bit index (0-31)
                        //   op2 = word to test
                        //   CY = (op2 >> op1) & 1
                        //   Z  = !CY
                        // No writeback — only flags updated.
                        // ======================================================
                        8'h87: begin  // TEST1
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_TEST1;
                            op_size <= 2'd2;  // word operands
                            op_has_am2 <= 1'b1; op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x80 — ADD.B (opADDB) — TRUSTED
                        // F12DecodeOperands(ReadAM,0, ReadAMAddress,0)
                        // result = op2 + op1 (dst += src)
                        // ======================================================
                        8'h80: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_ADD;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x82 — ADD.H (opADDH) — TRUSTED
                        // ======================================================
                        8'h82: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_ADD;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x84 — ADD.W (opADDW) — TRUSTED
                        // ======================================================
                        8'h84: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_ADD;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0xA8 — SUB.B (opSUBB) — via op12.hxx
                        // F12DecodeOperands(ReadAM,0, ReadAMAddress,0)
                        // result = op2 - op1 (dst -= src)
                        // ======================================================
                        8'hA8: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_SUB;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0xAA — SUB.H (opSUBH)
                        // ======================================================
                        8'hAA: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_SUB;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0xAC — SUB.W (opSUBW)
                        // ======================================================
                        8'hAC: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_SUB;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0xB8 — CMP.B (opCMPB) — TRUSTED
                        // F12DecodeOperands(ReadAM,0, ReadAM,0)
                        // Compute op2-op1 and set flags; no writeback
                        // ======================================================
                        8'hB8: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_CMP;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0xBA — CMP.H (opCMPH) — TRUSTED
                        // ======================================================
                        8'hBA: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_CMP;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0xBC — CMP.W (opCMPW) — TRUSTED
                        // ======================================================
                        8'hBC: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_CMP;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0xA0 — AND.B (opANDB) — TRUSTED
                        // NOTE: per handlers JSON, 0xA0=opANDB, not SUB.B
                        // (SUB.B is 0xA8)
                        // ======================================================
                        8'hA0: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_AND;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        8'hA2: begin  // AND.H
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_AND;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        8'hA4: begin  // AND.W
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_AND;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x88 — OR.B (opORB) — TRUSTED
                        // ======================================================
                        8'h88: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_OR;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        8'h8A: begin  // OR.H
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_OR;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        8'h8C: begin  // OR.W
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_OR;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0xB0-0xB4 — XOR.B/H/W (opXORB/H/W)
                        // ======================================================
                        8'hB0: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_XOR;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        8'hB2: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_XOR;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        8'hB4: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_XOR;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x38/0x3A/0x3C — NOT.B/H/W (opNOTB/H/W)
                        // Single operand F12: read and write same operand
                        // ======================================================
                        8'h38: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_NOT;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b0;  // single operand (src=dst)
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        8'h3A: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_NOT;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        8'h3C: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_NOT;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // 0x39/0x3B/0x3D — NEG.B/H/W (opNEGB/H/W)
                        // ======================================================
                        8'h39: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_NEG;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        8'h3B: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_NEG;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        8'h3D: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_NEG;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // INC.B/H/W — 0xD8/0xDA/0xDC (_0 variant, single-byte AM)
                        //             0xD9/0xDB/0xDD (_1 variant, extended AM)
                        // opINCB: ReadAMAddress + ADDB(appb, 1, 0)
                        // Instruction format: opcode + AM_byte [+ optional disp]
                        // Total length: 1 + amlength
                        // ======================================================
                        8'hD8, 8'hD9: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_ADD;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        8'hDA, 8'hDB: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_ADD;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        8'hDC, 8'hDD: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_ADD;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // DEC.B/H/W — 0xD0/D2/D4 (_0), 0xD1/D3/D5 (_1)
                        // opDECB: ReadAMAddress + SUBB(appb, 1, 0)
                        // ======================================================
                        8'hD0, 8'hD1: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_SUB;
                            op_size      <= 2'd0;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        8'hD2, 8'hD3: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_SUB;
                            op_size      <= 2'd1;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        8'hD4, 8'hD5: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_SUB;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // JMP — 0xD6 (_0), 0xD7 (_1) — opJMP — TRUSTED
                        // ReadAMAddress then PC = m_amout
                        // It must be a memory address (not register)
                        // Format: opcode + AM_byte [+ disp]
                        // ======================================================
                        8'hD6, 8'hD7: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_PASS;
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b0;
                            op_update_flags <= 1'b0;
                            op_is_branch <= 1'b1;
                            op_is_single_am <= 1'b1;
                            op_no_am     <= 1'b0;
                        end

                        // ======================================================
                        // Branch instructions (op4.hxx) — TRUSTED
                        //   opBR8  (0x6A): always branch, PC += (int8_t)ibuf[1]
                        //   opBE8  (0x64): branch if Z set
                        //   opBNE8 (0x65): branch if Z clear
                        //   opBL8  (0x62): branch if CY set
                        //   opBNL8 (0x63): branch if CY clear
                        //   opBN8  (0x68): branch if S set
                        //   opBP8  (0x69): branch if S clear
                        //   opBV8  (0x60): branch if OV set
                        //   opBNV8 (0x61): branch if OV clear
                        //   opBH8  (0x67): branch if not (CY|Z)
                        //   opBNH8 (0x66): branch if (CY|Z)
                        //   opBGE8 (0x6C): branch if not (S^OV)
                        //   opBLT8 (not listed in provided handlers — skipped)
                        //   opBLE8 (0x6E): branch if (S^OV)|Z
                        //   opBGT8 (0x6F): branch if not ((S^OV)|Z)
                        //
                        // Format: 2 bytes (opcode + disp8)
                        //   PC += 2 if not taken; PC += (int8_t)disp8 if taken
                        //   Note: MAME does PC += disp8 and returns 0 (no further PC increment)
                        //   OR returns 2 (instruction length) if not taken.
                        //   In our FSM: compute target here, set do_branch flag.
                        // ======================================================
                        8'h6A: begin  // BR8 — always branch (opBR8)
                            reg_file[32] <= reg_file[32] +
                                            {{24{ibuf[1][7]}}, ibuf[1]};
                            state <= S_FETCH0;
                        end

                        8'h64: begin  // BE8 — opBE8: branch if Z
                            if (f_z)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h65: begin  // BNE8 — opBNE8: branch if not Z
                            if (!f_z)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h62: begin  // BL8 — opBL8: branch if CY (carry)
                            if (f_cy)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h63: begin  // BNL8 — opBNL8: branch if not CY
                            if (!f_cy)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h68: begin  // BN8 — opBN8: branch if S (sign/negative)
                            if (f_s)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h69: begin  // BP8 — opBP8: branch if not S (positive)
                            if (!f_s)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h60: begin  // BV8 — opBV8: branch if OV
                            if (f_ov)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h61: begin  // BNV8 — opBNV8: branch if not OV
                            if (!f_ov)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h67: begin  // BH8 — opBH8: branch if not (CY|Z)
                            if (!(f_cy | f_z))
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h66: begin  // BNH8 — opBNH8: branch if (CY|Z)
                            if (f_cy | f_z)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h6C: begin  // BGE8 — opBGE8: branch if not (S^OV)
                            if (!(f_s ^ f_ov))
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h6D: begin  // BLT8 — opBLT8: branch if (S^OV)
                            if (f_s ^ f_ov)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h6E: begin  // BLE8 — opBLE8: branch if (S^OV)|Z
                            if ((f_s ^ f_ov) | f_z)
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        8'h6F: begin  // BGT8 — opBGT8: branch if not ((S^OV)|Z)
                            if (!((f_s ^ f_ov) | f_z))
                                reg_file[32] <= reg_file[32] + {{24{ibuf[1][7]}}, ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end

                        // ======================================================
                        // 16-bit branch variants (op4.hxx)
                        //   Format: 3 bytes (opcode + disp16)
                        //   MAME: PC += (int16_t)OpRead16(PC+1), return 0
                        //         or return 3 if not taken
                        // ======================================================
                        8'h7A: begin  // BR16 — always
                            reg_file[32] <= reg_file[32] +
                                            {{16{ibuf[2][7]}}, ibuf[2], ibuf[1]};
                            state <= S_FETCH0;
                        end

                        8'h74: begin  // BE16
                            if (f_z)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h75: begin  // BNE16
                            if (!f_z)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h72: begin  // BL16
                            if (f_cy)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h73: begin  // BNL16
                            if (!f_cy)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h78: begin  // BN16
                            if (f_s)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h79: begin  // BP16
                            if (!f_s)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h70: begin  // BV16
                            if (f_ov)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h71: begin  // BNV16
                            if (!f_ov)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h7C: begin  // BLT16
                            if (f_s ^ f_ov)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h7D: begin  // BGE16
                            if (!(f_s ^ f_ov))
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h7E: begin  // BLE16
                            if ((f_s ^ f_ov) | f_z)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h7F: begin  // BGT16
                            if (!((f_s ^ f_ov) | f_z))
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h77: begin  // BH16
                            if (!(f_cy | f_z))
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        8'h76: begin  // BNH16
                            if (f_cy | f_z)
                                reg_file[32] <= reg_file[32] + {{16{ibuf[2][7]}},ibuf[2],ibuf[1]};
                            else
                                reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        // ======================================================
                        // 0x48 — BSR (opBSR) — branch to subroutine (PC-relative)
                        // Format: opcode(1) + disp16(2) — 3 bytes total
                        // MAME: push PC+3, then PC += sign_ext(disp16)
                        // Note: MAME opBSR uses 16-bit displacement from ibuf[1:2]
                        // ======================================================
                        8'h48: begin
                            // Return address is PC + 3 (size of BSR instruction)
                            stk_ret_pc   <= reg_file[32] + 32'd3;
                            stk_jump_target <= reg_file[32] +
                                              {{16{ibuf[2][7]}}, ibuf[2], ibuf[1]};
                            stk_size     <= 2'd2;  // push 32-bit return addr
                            state        <= S_CALL_PUSH;
                        end

                        // ======================================================
                        // 0x49 — CALL (opCALL) — call subroutine via AM
                        // Format: opcode(1) + instflags(1) + AM(variable)
                        // MAME: reads effective address, pushes PC+instr_len, jumps
                        // The AM is a single-operand addressing mode (like JMP)
                        // ======================================================
                        8'h49: begin
                            // Decode the AM to get jump target
                            // ibuf[1] = AM byte (similar to JMP format)
                            begin
                                logic        ca_is_reg, ca_is_imm;
                                logic [31:0] ca_addr;
                                int          ca_len;
                                decode_am(1, 2'd2, 1'b0, reg_file[32],
                                          ca_is_reg, ca_is_imm, ca_addr, ca_len);
                                stk_ret_pc      <= reg_file[32] + 32'd1 + ca_len;
                                stk_jump_target <= ca_addr;
                                stk_size        <= 2'd2;
                                state           <= S_CALL_PUSH;
                            end
                        end

                        // ======================================================
                        // 0xE8/_9 — JSR (opJSR) — Jump to Subroutine
                        // Format: opcode(1) + AM(variable) — NO instflags byte
                        // MAME: ReadAMAddress() → EA; SP-=4; mem[SP]=PC+1+amlen; PC=EA
                        // modm from opcode bit0 (0xE8=_0 → modm=0, 0xE9=_1 → modm=1)
                        // ======================================================
                        8'hE8, 8'hE9: begin
                            begin
                                logic        jsr_is_reg, jsr_is_imm;
                                logic [31:0] jsr_addr;
                                int          jsr_len;
                                decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                                          jsr_is_reg, jsr_is_imm, jsr_addr, jsr_len);
                                // Return address = PC + 1 (opcode) + jsr_len (AM bytes)
                                stk_ret_pc      <= reg_file[32] + 32'd1 + jsr_len;
                                stk_jump_target <= jsr_addr;  // EA from AM (ReadAMAddress)
                                stk_size        <= 2'd2;
                                state           <= S_CALL_PUSH;
                            end
                        end

                        // ======================================================
                        // 0xE2/_3 — RET (opRET) — return from subroutine
                        // 0xE3: pop 32-bit value from [SP] into PC
                        // MAME: PC = pop32(); return 0
                        // ======================================================
                        8'hE2, 8'hE3: begin
                            stk_size  <= 2'd2;
                            state     <= S_RET_POP;
                        end

                        // ======================================================
                        // 0x5A/0x5B — MOVCUH — Move Convert Unsigned Halfword
                        //   Copy R1 bytes from [R0] to [R2], zero-extended to
                        //   halfword (2 bytes) at each destination step.
                        //   Each iteration: byte = mem[R0]; mem[R2]=byte; mem[R2+1]=0
                        //                  R0++; R2+=2; R1--; until R1==0
                        //
                        // Format: opcode(1) + subop(1) + AM1(1+) + len1(1) +
                        //                                AM2(1+) + len2(1)
                        //   AM bytes in ROM for [--R0]/[--R2] (grp=3, auto-dec) = 1 byte each
                        //   Total instr bytes = 2+1+1+1+1 = 6 for auto-dec AMs
                        //
                        // The AM auto-dec encoding means: pre-decrement before addressing.
                        // But MOVCUH uses R0/R1/R2 as implicit string registers;
                        // we read AM lengths for PC advancement only.
                        // R0 = source (byte pointer, post-incremented each step)
                        // R1 = count  (decremented each step)
                        // R2 = dest   (halfword pointer, advanced +2 each step)
                        //
                        // For R1==0 on entry: skip entirely (zero-count = no-op).
                        //
                        // 0x58/0x59 — MOVCB (byte-to-byte, no conversion needed)
                        //   Same loop but writes 1 byte (not 2) to dest; R2++
                        //
                        // 0x5C/0x5D — MOVCFH (float conversion) — stub (skip)
                        // ======================================================
                        8'h5A, 8'h5B: begin
                            begin
                                // F7a format: opcode(1) + subop(1) + AM1(n) + len1(1) + AM2(m) + len2(1)
                                // Total = 4 + n + m bytes.
                                //
                                // AM byte bit layout for F7a string ops:
                                //   bits[7:5] = group:
                                //     000 = disp8[Rn]   → 2 bytes (AM + disp8)
                                //     001 = disp16[Rn]  → 3 bytes (AM + disp16)
                                //     010 = disp32[Rn]  → 5 bytes (AM + disp32)
                                //     011 = [Rn]        → 1 byte  (AM only)
                                //     100 = ind8[Rn]    → 2 bytes
                                //     101 = ind16[Rn]   → 3 bytes
                                //     110 = ind32[Rn]   → 5 bytes
                                //     111 = Group7 extended → 5 bytes (conservative)
                                //
                                // Length byte format:
                                //   bit7=0: literal count = byte[6:0]
                                //   bit7=1: count from register reg_file[byte[4:0]]
                                //
                                // After copy: R28 = final source addr, R27 = final dest addr
                                // Source regs R2,R3 (pointer) and R1 (count) are NOT updated.
                                //
                                logic [3:0] f7a_am1_len, f7a_am2_len;
                                logic [4:0] f7a_total;
                                logic [7:0] f7a_len1_byte, f7a_len2_byte;
                                logic [31:0] f7a_src_addr, f7a_dst_addr;
                                logic [31:0] f7a_lenop1, f7a_lenop2, f7a_cnt;
                                logic        f7a_src_is_reg, f7a_src_is_imm;
                                logic        f7a_dst_is_reg, f7a_dst_is_imm;
                                int          f7a_src_am_bytes, f7a_dst_am_bytes;

                                // AM1 length (ibuf[2] = first AM byte)
                                case (ibuf[2][7:5])
                                    3'b000: f7a_am1_len = 4'd2;   // disp8
                                    3'b001: f7a_am1_len = 4'd3;   // disp16
                                    3'b010: f7a_am1_len = 4'd5;   // disp32
                                    3'b011: f7a_am1_len = 4'd1;   // [Rn]
                                    3'b100: f7a_am1_len = 4'd2;   // ind8
                                    3'b101: f7a_am1_len = 4'd3;   // ind16
                                    3'b110: f7a_am1_len = 4'd5;   // ind32
                                    default:f7a_am1_len = 4'd5;   // Group7
                                endcase

                                // Length byte 1 is at ibuf[2 + f7a_am1_len]
                                f7a_len1_byte = ibuf[2 + f7a_am1_len];

                                // AM2 starts at ibuf[2 + f7a_am1_len + 1]
                                case (ibuf[2 + f7a_am1_len + 1][7:5])
                                    3'b000: f7a_am2_len = 4'd2;
                                    3'b001: f7a_am2_len = 4'd3;
                                    3'b010: f7a_am2_len = 4'd5;
                                    3'b011: f7a_am2_len = 4'd1;
                                    3'b100: f7a_am2_len = 4'd2;
                                    3'b101: f7a_am2_len = 4'd3;
                                    3'b110: f7a_am2_len = 4'd5;
                                    default:f7a_am2_len = 4'd5;
                                endcase

                                // Length byte 2
                                f7a_len2_byte = ibuf[2 + f7a_am1_len + 1 + f7a_am2_len];

                                // Total instruction length
                                f7a_total = 5'd4 + {1'b0, f7a_am1_len} + {1'b0, f7a_am2_len};

                                // Decode source address via AM1
                                decode_am(2, 2'd2, 1'b0, reg_file[32],
                                          f7a_src_is_reg, f7a_src_is_imm, f7a_src_addr, f7a_src_am_bytes);

                                // Decode dest address via AM2 (at offset 2+am1_len+1)
                                decode_am(2 + f7a_am1_len + 1, 2'd2, 1'b0, reg_file[32],
                                          f7a_dst_is_reg, f7a_dst_is_imm, f7a_dst_addr, f7a_dst_am_bytes);

                                // Decode counts from length bytes
                                // bit7=1 → register value; bit7=0 → literal
                                f7a_lenop1 = f7a_len1_byte[7] ?
                                             reg_file[{1'b0, f7a_len1_byte[4:0]}] :
                                             {25'd0, f7a_len1_byte[6:0]};
                                f7a_lenop2 = f7a_len2_byte[7] ?
                                             reg_file[{1'b0, f7a_len2_byte[4:0]}] :
                                             {25'd0, f7a_len2_byte[6:0]};
                                f7a_cnt = (f7a_lenop1 < f7a_lenop2) ? f7a_lenop1 : f7a_lenop2;

                                // Store decoded params for use in copy states
                                movcuh_src <= f7a_src_addr;
                                movcuh_dst <= f7a_dst_addr;
                                movcuh_cnt <= f7a_cnt;

                                // Advance PC past this instruction
                                reg_file[32] <= reg_file[32] + {27'd0, f7a_total};

                                // If count is zero: no-op, just fetch next
                                if (f7a_cnt == 32'd0) begin
                                    reg_file[28] <= f7a_src_addr;  // R28 = final src
                                    reg_file[27] <= f7a_dst_addr;  // R27 = final dst
                                    state <= S_FETCH0;
                                end else begin
                                    // Start halfword copy loop
                                    state <= S_MOVCUH_RD;
                                end
                            end
                        end

                        8'h58, 8'h59: begin
                            begin
                                // MOVCB: byte-to-byte copy, no conversion
                                // Same loop structure as MOVCUH but dest advances +1
                                // Reuse MOVCUH states; MOVCB writes only lo-byte
                                // For simplicity: handle as MOVCUH with 1-byte write
                                // TODO: implement MOVCB properly; for now skip (stub)
                                logic [3:0] f7a_am1_len_b, f7a_am2_len_b;
                                logic [4:0] f7a_total_b;
                                case (ibuf[2][7:5])
                                    3'b000, 3'b001,
                                    3'b010, 3'b011: f7a_am1_len_b = 4'd1;
                                    3'b100:         f7a_am1_len_b = 4'd2;
                                    3'b101:         f7a_am1_len_b = 4'd3;
                                    3'b110:         f7a_am1_len_b = 4'd5;
                                    default:        f7a_am1_len_b = 4'd5;
                                endcase
                                case (ibuf[3 + f7a_am1_len_b][7:5])
                                    3'b000, 3'b001,
                                    3'b010, 3'b011: f7a_am2_len_b = 4'd1;
                                    3'b100:         f7a_am2_len_b = 4'd2;
                                    3'b101:         f7a_am2_len_b = 4'd3;
                                    3'b110:         f7a_am2_len_b = 4'd5;
                                    default:        f7a_am2_len_b = 4'd5;
                                endcase
                                f7a_total_b = 5'd4 + {1'b0, f7a_am1_len_b} + {1'b0, f7a_am2_len_b};
                                reg_file[32] <= reg_file[32] + {27'd0, f7a_total_b};
                                state <= S_FETCH0;  // stub: skip (no MOVCB in ROM currently)
                            end
                        end

                        8'h5C, 8'h5D: begin
                            begin
                                // MOVCFH: float conversion stub — skip
                                logic [3:0] f7a_am1_len_c, f7a_am2_len_c;
                                logic [4:0] f7a_total_c;
                                case (ibuf[2][7:5])
                                    3'b000, 3'b001,
                                    3'b010, 3'b011: f7a_am1_len_c = 4'd1;
                                    3'b100:         f7a_am1_len_c = 4'd2;
                                    3'b101:         f7a_am1_len_c = 4'd3;
                                    3'b110:         f7a_am1_len_c = 4'd5;
                                    default:        f7a_am1_len_c = 4'd5;
                                endcase
                                case (ibuf[3 + f7a_am1_len_c][7:5])
                                    3'b000, 3'b001,
                                    3'b010, 3'b011: f7a_am2_len_c = 4'd1;
                                    3'b100:         f7a_am2_len_c = 4'd2;
                                    3'b101:         f7a_am2_len_c = 4'd3;
                                    3'b110:         f7a_am2_len_c = 4'd5;
                                    default:        f7a_am2_len_c = 4'd5;
                                endcase
                                f7a_total_c = 5'd4 + {1'b0, f7a_am1_len_c} + {1'b0, f7a_am2_len_c};
                                reg_file[32] <= reg_file[32] + {27'd0, f7a_total_c};
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // 0xCA — RSR — Return from Subroutine (no operand)
                        // MAME opRSR(): PC = mem32[SP]; SP += 4; return 0
                        // Identical to RET but 1-byte instruction (no AM field)
                        // ======================================================
                        8'hCA: begin
                            stk_size <= 2'd2;
                            state    <= S_RET_POP;
                        end

                        // ======================================================
                        // 0xFA/_B — RETIS — Return from Interrupt Service
                        // Format: opcode(1) + AM_byte (operand = frame_adj bytes)
                        //   PC  = mem32[SP]; SP += 4
                        //   PSW = mem32[SP]; SP += 4
                        //   SP += frame_adj
                        // modm from opcode bit0 (0xFA=_0 → modm=0, 0xFB=_1 → modm=1)
                        // MAME: m_modadd=PC+1, m_moddim=1 → ReadAM() → m_amout
                        // ======================================================
                        8'hFA, 8'hFB: begin
                            begin
                                logic        ri_is_reg, ri_is_imm;
                                logic [31:0] ri_adj;
                                int          ri_len;
                                // Operand is 16-bit (moddim=1 in MAME = halfword)
                                decode_am(1, 2'd1, ibuf[0][0], reg_file[32],
                                          ri_is_reg, ri_is_imm, ri_adj, ri_len);
                                // Store frame_adj for use in PSW_HI_WAIT
                                if (ri_is_reg)
                                    prep_frame_size <= {16'd0, reg_file[ri_adj[5:0]][15:0]};
                                else if (ri_is_imm)
                                    prep_frame_size <= {16'd0, ri_adj[15:0]};
                                else
                                    prep_frame_size <= 32'd0;
                                // Advance PC past instruction (not used since we'll overwrite PC)
                                // No need to update PC — RETIS overwrites it from stack
                                state <= S_RETIS_PC_LO;
                            end
                        end

                        // ======================================================
                        // 0xC8 — BRK — Software Breakpoint (NOP for simulation)
                        // 0xC9 — BRKV — Break on Overflow (NOP unless OV set)
                        // ======================================================
                        8'hC8: begin  // BRK — single byte, NOP
                            reg_file[32] <= reg_file[32] + 32'd1;
                            state <= S_FETCH0;
                        end
                        8'hC9: begin  // BRKV — branch to break handler if OV set
                            // Simplified: NOP (don't trigger software breakpoint)
                            reg_file[32] <= reg_file[32] + 32'd1;
                            state <= S_FETCH0;
                        end

                        // ======================================================
                        // 0xEE/_F — PUSH — push register/AM onto stack
                        // 0xEE = PUSH.B (1 byte), 0xEF = PUSH.W (4 bytes)
                        // Format: opcode(1) + AM_byte(1+)
                        // MAME: SP -= size; mem[SP] = value
                        // ======================================================
                        8'hEE: begin  // PUSH.B (_0 variant, modm=0)
                            begin
                                logic        p_is_reg, p_is_imm;
                                logic [31:0] p_val, p_addr;
                                int          p_len;
                                // modm from opcode bit0: 0xEE=_0 → modm=0, 0xEF=_1 → modm=1
                                decode_am(1, 2'd0, ibuf[0][0], reg_file[32],
                                          p_is_reg, p_is_imm, p_addr, p_len);
                                if (p_is_reg)
                                    p_val = {24'd0, reg_file[p_addr[5:0]][7:0]};
                                else if (p_is_imm)
                                    p_val = {24'd0, p_addr[7:0]};
                                else
                                    p_val = 32'd0;  // mem operand: simplified (rare for PUSH)
                                stk_val  <= p_val;
                                stk_size <= 2'd0;
                                // Advance PC past instruction
                                reg_file[32] <= reg_file[32] + 32'd1 + p_len;
                                state <= S_PUSH_SETUP;
                            end
                        end

                        8'hEF: begin  // PUSH.W (_1 variant, modm=1)
                            begin
                                logic        p_is_reg, p_is_imm;
                                logic [31:0] p_val, p_addr;
                                int          p_len;
                                // modm from opcode bit0: 0xEF=_1 → modm=1
                                decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                                          p_is_reg, p_is_imm, p_addr, p_len);
                                if (p_is_reg)
                                    p_val = reg_file[p_addr[5:0]];
                                else if (p_is_imm)
                                    p_val = p_addr;
                                else
                                    p_val = 32'd0;
                                stk_val  <= p_val;
                                stk_size <= 2'd2;
                                reg_file[32] <= reg_file[32] + 32'd1 + p_len;
                                state <= S_PUSH_SETUP;
                            end
                        end

                        // ======================================================
                        // 0xE6/_7 — POP — pop from stack to register/AM
                        // 0xE6 = POP_0 (modm=0), 0xE7 = POP_1 (modm=1)
                        // Format: opcode(1) + AM_byte(1+)
                        // MAME: value = mem[SP]; SP += size; WriteAM(value)
                        // ======================================================
                        8'hE6: begin  // POP.B (_0 variant, modm=0)
                            begin
                                logic        q_is_reg, q_is_imm;
                                logic [31:0] q_addr;
                                int          q_len;
                                // modm from opcode bit0
                                decode_am(1, 2'd0, ibuf[0][0], reg_file[32],
                                          q_is_reg, q_is_imm, q_addr, q_len);
                                stk_size    <= 2'd0;
                                stk_dst_reg <= q_addr[5:0];  // destination reg
                                reg_file[32] <= reg_file[32] + 32'd1 + q_len;
                                state <= S_POP_SETUP;
                            end
                        end

                        8'hE7: begin  // POP.W (_1 variant, modm=1)
                            begin
                                logic        q_is_reg, q_is_imm;
                                logic [31:0] q_addr;
                                int          q_len;
                                // modm from opcode bit0
                                decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                                          q_is_reg, q_is_imm, q_addr, q_len);
                                stk_size    <= 2'd2;
                                stk_dst_reg <= q_addr[5:0];
                                reg_file[32] <= reg_file[32] + 32'd1 + q_len;
                                state <= S_POP_SETUP;
                            end
                        end

                        // ======================================================
                        // 0xEC/0xED — PUSHM — Push Multiple Registers
                        // Format: opcode(1) + AM (32-bit register bitmask)
                        // Bit 31 → push PSW; bits 0-30: bit[b] set → push reg[b]
                        //   but MAME loop: for i=0..30: if amout&(1<<(30-i)) push reg[30-i]
                        //   → bit[30]=push R0, bit[29]=push R1, ..., bit[0]=push R30
                        // Push order: PSW first (if bit31), then R0 (bit30 down to bit0)
                        // ======================================================
                        8'hEC, 8'hED: begin
                            begin
                                logic        pm_is_reg_t, pm_is_imm_t;
                                logic [31:0] pm_val_t;
                                int          pm_len_t;
                                // Decode 32-bit AM (register bitmask)
                                decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                                          pm_is_reg_t, pm_is_imm_t, pm_val_t, pm_len_t);
                                // pm_val_t holds the bitmask
                                pm_mask      <= pm_val_t;
                                pm_idx       <= 6'd0;     // start from bit 31 (PSW)
                                pm_is_popm   <= 1'b0;
                                reg_file[32] <= reg_file[32] + 32'd1 + pm_len_t;
                                state        <= S_PUSHM_NEXT;
                            end
                        end

                        // ======================================================
                        // 0xE4/0xE5 — POPM — Pop Multiple Registers
                        // Format: opcode(1) + AM (32-bit register bitmask)
                        // Bit 31 → pop PSW (low 16 bits only, merged into PSW hi);
                        // bits 0-30: bit[b] set → pop into reg[b]
                        //   MAME loop: for i=0..30: if amout&(1<<i) pop into reg[i]
                        //   → bit[0]=pop R0, bit[1]=pop R1, ..., bit[30]=pop R30
                        // Pop order: R0 first (bit0), then R1..R30; PSW last (bit31)
                        // ======================================================
                        8'hE4, 8'hE5: begin
                            begin
                                logic        pm_is_reg_t, pm_is_imm_t;
                                logic [31:0] pm_val_t;
                                int          pm_len_t;
                                decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                                          pm_is_reg_t, pm_is_imm_t, pm_val_t, pm_len_t);
                                pm_mask      <= pm_val_t;
                                pm_idx       <= 6'd0;     // start from bit 0 (R0)
                                pm_is_popm   <= 1'b1;
                                reg_file[32] <= reg_file[32] + 32'd1 + pm_len_t;
                                state        <= S_POPM_NEXT;
                            end
                        end

                        // ======================================================
                        // 0x40/42/44 — MOVEA.B/H/W — load effective address
                        // Format: opcode(1) + instflags(1) + AM1 [+ AM2]
                        // MAME: F12DecodeFirstOperand(ReadAMAddress) → get source EA
                        //       F12WriteSecondOperand(2) → write 32-bit EA to dest
                        //
                        // F1 (instflags[7]=1): explicit AM1 (source) + AM2 (dest)
                        //   modm for AM1 = instflags[6]
                        //   modm for AM2 = instflags[5]
                        // F2/D=1 (instflags[7]=0, [5]=1): AM1=source, reg=dest
                        // F2/D=0 (instflags[7]=0, [5]=0): reg=source, AM2=dest
                        // ======================================================
                        8'h40, 8'h42, 8'h44: begin
                            begin
                                logic [1:0]  mea_sz;
                                logic        mea_m1, mea_m2;
                                logic        mea_is_reg1, mea_is_imm1;
                                logic        mea_is_reg2, mea_is_imm2;
                                logic [31:0] mea_ea;   // effective address from AM1
                                logic [31:0] mea_dst;  // destination addr/reg from AM2
                                int          mea_len1, mea_len2;
                                logic [31:0] mea_next_pc;
                                mea_sz = (ibuf[0] == 8'h40) ? 2'd0 :
                                         (ibuf[0] == 8'h42) ? 2'd1 : 2'd2;
                                mea_m1 = ibuf[1][6]; // M1 for AM1
                                mea_m2 = ibuf[1][5]; // M2 for AM2 (F1 mode)
                                if (ibuf[1][7]) begin
                                    // F1 mode: two explicit AM fields
                                    decode_am(2, mea_sz, mea_m1, reg_file[32],
                                              mea_is_reg1, mea_is_imm1, mea_ea, mea_len1);
                                    decode_am(2 + mea_len1, 2'd2, mea_m2, reg_file[32],
                                              mea_is_reg2, mea_is_imm2, mea_dst, mea_len2);
                                    mea_next_pc = reg_file[32] + 32'd2 + mea_len1 + mea_len2;
                                    if (mea_is_reg2) begin
                                        // Dest is register-direct
                                        reg_file[mea_dst[5:0]] <= mea_ea;
                                        reg_file[32] <= mea_next_pc;
                                        state <= S_FETCH0;
                                    end else if (mea_m2 && (ibuf[2 + mea_len1][7:5] == 3'd5)) begin
                                        // modm=1 grp5 = Autodecrement [--Rn]:
                                        // Decrement Rn by 4, then write mea_ea to [Rn]
                                        // Use PUSH machinery (assumes Rn=SP, handles stk_val)
                                        stk_val  <= mea_ea;
                                        stk_size <= 2'd2;
                                        reg_file[32] <= mea_next_pc;
                                        state <= S_PUSH_SETUP;
                                    end else begin
                                        // Other mem dest: write EA to computed address
                                        stk_val  <= mea_ea;   // reuse stk_val as write data
                                        stk_size <= 2'd2;
                                        reg_file[32] <= mea_next_pc;
                                        state <= S_PUSH_SETUP;  // simplified: treat as push
                                    end
                                end else if (ibuf[1][5]) begin
                                    // F2/D=1: AM1=source, dest=reg ibuf[1][4:0]
                                    decode_am(2, mea_sz, mea_m1, reg_file[32],
                                              mea_is_reg1, mea_is_imm1, mea_ea, mea_len1);
                                    reg_file[{1'b0, ibuf[1][4:0]}] <= mea_ea;
                                    reg_file[32] <= reg_file[32] + 32'd2 + mea_len1;
                                    state <= S_FETCH0;
                                end else begin
                                    // F2/D=0: source=reg ibuf[1][4:0], dest=AM2
                                    decode_am(2, 2'd2, mea_m2, reg_file[32],
                                              mea_is_reg2, mea_is_imm2, mea_dst, mea_len2);
                                    if (mea_is_reg2)
                                        reg_file[mea_dst[5:0]] <= reg_file[{1'b0, ibuf[1][4:0]}];
                                    reg_file[32] <= reg_file[32] + 32'd2 + mea_len2;
                                    state <= S_FETCH0;
                                end
                            end
                        end

                        // ======================================================
                        // LDPR — 0x12 — Load Privileged Register
                        // STPR — 0x02 — Store Privileged Register
                        //
                        // LDPR: F12DecodeOperands(ReadAMAddress, 2, ReadAM, 2)
                        //   op1 = source (flag1=1: reg value, flag1=0: mem addr)
                        //   op2 = privileged reg index (0..28 → reg_file[36..64])
                        //   reg_file[op2+36] = (flag1 ? reg_file[op1] : mem[op1])
                        //
                        // STPR: F12DecodeFirstOperand(ReadAM, 2) + F12WriteSecondOperand
                        //   op1 = privileged reg index → reg_file[op1+36] is the source value
                        //   Write to op2 address
                        //
                        // For boot purposes: source is usually Immediate, dest is ImmediateQuick
                        // Both use F1/F2 format identical to standard instructions.
                        // We implement via EXT_LDPR/EXT_STPR in S_EXECUTE.
                        // ======================================================
                        8'h12: begin  // LDPR
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_LDPR;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h02: begin  // STPR
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_STPR;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // LDTASK — 0x01 — Load Task Register
                        // MAME: F12DecodeOperands(ReadAMAddress,2, ReadAM,2)
                        //   op1 = register restore bitmask (bits 0-30 → R0-R30)
                        //   op2 = base address of task record in memory
                        //
                        // Execution sequence:
                        //   1. Clear PSW bit 28
                        //   2. TR (reg_file[42]) = op2
                        //   3. TKCW (reg_file[44]) = mem32[op2]; ptr += 4
                        //   4. If SYCW[8]:  L0SP = mem32[ptr]; ptr += 4
                        //      If SYCW[9]:  L1SP = mem32[ptr]; ptr += 4
                        //      If SYCW[10]: L2SP = mem32[ptr]; ptr += 4
                        //      If SYCW[11]: L3SP = mem32[ptr]; ptr += 4
                        //   5. v60ReloadStack: SP = ISP (if PSW[28]) else L[level]SP
                        //   6. For i=0..30: if op1[i] set: R[i] = mem32[ptr]; ptr += 4
                        //
                        // At boot: SYCW=0x70 (bits 8-11 clear → no L-SP loads),
                        //   PSW[28]=0 after step 1 → SP = reg_file[37+PSW[25:24]]
                        // ======================================================
                        8'h01: begin  // LDTASK
                            begin
                                logic        lt_is_reg1, lt_is_imm1;
                                logic        lt_is_reg2, lt_is_imm2;
                                logic [31:0] lt_op1, lt_op2;
                                int          lt_len1, lt_len2;
                                logic [31:0] lt_new_psw;
                                logic [31:0] lt_next_pc;
                                // Decode two word-size AMs: same F1/F2 format as LDPR
                                if (ibuf[1][7]) begin
                                    // F1: two explicit AMs
                                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                                              lt_is_reg1, lt_is_imm1, lt_op1, lt_len1);
                                    decode_am(2+lt_len1, 2'd2, ibuf[1][5], reg_file[32],
                                              lt_is_reg2, lt_is_imm2, lt_op2, lt_len2);
                                    lt_next_pc = reg_file[32] + 32'd2 + lt_len1 + lt_len2;
                                end else if (ibuf[1][5]) begin
                                    // D=1: AM1=op1 from ibuf[2..], reg=op2
                                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                                              lt_is_reg1, lt_is_imm1, lt_op1, lt_len1);
                                    lt_op2     = reg_file[{1'b0, ibuf[1][4:0]}];
                                    lt_is_reg2 = 1'b0; lt_is_imm2 = 1'b1;
                                    lt_len2    = 0;
                                    lt_next_pc = reg_file[32] + 32'd2 + lt_len1;
                                end else begin
                                    // D=0: reg=op1, AM=op2 from ibuf[2..]
                                    lt_op1     = reg_file[{1'b0, ibuf[1][4:0]}];
                                    lt_is_reg1 = 1'b1; lt_is_imm1 = 1'b0;
                                    lt_len1    = 0;
                                    decode_am(2, 2'd2, ibuf[1][5], reg_file[32],
                                              lt_is_reg2, lt_is_imm2, lt_op2, lt_len2);
                                    lt_next_pc = reg_file[32] + 32'd2 + lt_len2;
                                end
                                // Resolve register and immediate operands
                                if (lt_is_reg1) lt_op1 = reg_file[lt_op1[5:0]];
                                if (lt_is_reg2) lt_op2 = reg_file[lt_op2[5:0]];
                                // For immediate AM2, lt_op2 is the value directly
                                // (decode_am returns the value in am_val for immediates)
                                // Step 1: clear PSW bit 28
                                lt_new_psw     = {reg_file[33][31:4], f_cy, f_ov, f_s, f_z}
                                                 & 32'hEFFFFFFF;
                                reg_file[33]  <= lt_new_psw;
                                // Step 2: TR = op2
                                reg_file[42]  <= lt_op2;
                                // Save register mask for reg restore phase
                                pm_mask       <= lt_op1[30:0];  // bits 0-30 = R0-R30
                                pm_idx        <= 6'd0;
                                // Start task record pointer at op2
                                ldtask_ptr    <= lt_op2;
                                // Advance PC
                                reg_file[32]  <= lt_next_pc;
                                // Begin reading TKCW from [op2]
                                bus_addr_r    <= lt_op2[23:0];
                                bus_as_r      <= 1'b0;
                                bus_rw_r      <= 1'b1;
                                bus_ds_r      <= 2'b00;
                                state         <= S_LDTASK_TKCW_LO_WAIT;
                            end
                        end

                        // ======================================================
                        // UPDPSWW — 0x13 — Update PSW word
                        // MAME: F12DecodeOperands(ReadAM,2, ReadAM,2)
                        // PSW = (PSW & ~op2) | (op1 & op2), masked to lower 24 bits
                        // Format: opcode(1) + instflags(1) + AM1 [+ AM2]
                        // ======================================================
                        8'h13: begin
                            begin
                                logic        upd_is_reg1, upd_is_imm1;
                                logic        upd_is_reg2, upd_is_imm2;
                                logic [31:0] upd_val1, upd_val2;
                                int          upd_len1, upd_len2;
                                logic [31:0] upd_next_pc;
                                logic [31:0] upd_new_psw, upd_cur_psw;
                                if (ibuf[1][7]) begin
                                    // F1: two explicit AMs
                                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                                              upd_is_reg1, upd_is_imm1, upd_val1, upd_len1);
                                    decode_am(2+upd_len1, 2'd2, ibuf[1][5], reg_file[32],
                                              upd_is_reg2, upd_is_imm2, upd_val2, upd_len2);
                                    upd_next_pc = reg_file[32] + 32'd2 + upd_len1 + upd_len2;
                                end else if (ibuf[1][5]) begin
                                    // D=1: AM1=op1, reg=op2
                                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                                              upd_is_reg1, upd_is_imm1, upd_val1, upd_len1);
                                    upd_val2 = reg_file[{1'b0, ibuf[1][4:0]}];
                                    upd_len2 = 0;
                                    upd_next_pc = reg_file[32] + 32'd2 + upd_len1;
                                end else begin
                                    // D=0: reg=op1, AM=op2
                                    upd_val1 = reg_file[{1'b0, ibuf[1][4:0]}];
                                    upd_len1 = 0;
                                    decode_am(2, 2'd2, ibuf[1][5], reg_file[32],
                                              upd_is_reg2, upd_is_imm2, upd_val2, upd_len2);
                                    upd_next_pc = reg_file[32] + 32'd2 + upd_len2;
                                end
                                // Resolve register operands
                                if (upd_is_reg1) upd_val1 = reg_file[upd_val1[5:0]];
                                if (ibuf[1][7] && upd_is_reg2) upd_val2 = reg_file[upd_val2[5:0]];
                                // Current PSW (reconstruct from flag regs)
                                upd_cur_psw = {reg_file[33][31:4], f_cy, f_ov, f_s, f_z};
                                // Apply: PSW = (PSW & ~op2) | (op1 & op2), only low 24 bits
                                upd_new_psw = (upd_cur_psw & ~(upd_val2 & 32'hFFFFFF)) |
                                              (upd_val1 & upd_val2 & 32'hFFFFFF);
                                f_z  <= upd_new_psw[0];
                                f_s  <= upd_new_psw[1];
                                f_ov <= upd_new_psw[2];
                                f_cy <= upd_new_psw[3];
                                reg_file[33] <= upd_new_psw;
                                reg_file[32] <= upd_next_pc;
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // CLRTLBA — 0x10 — Clear TLB All (NOP — no TLB in our sim)
                        // ======================================================
                        8'h10: begin  // CLRTLBA — 1-byte instruction, NOP
                            reg_file[32] <= reg_file[32] + 32'd1;
                            state <= S_FETCH0;
                        end

                        // ======================================================
                        // MUL.B/H/W — 0x81/0x83/0x85 — signed multiply
                        // opMULB: tmp=appb*(int8)op1; appb=tmp; OV=(tmp>>8)!=0
                        // opMULH: tmp=apph*(int16)op1; apph=tmp; OV=(tmp>>16)!=0
                        // opMULW: tmp=appw*(int32)op1; appw=tmp; OV=(tmp>>32)!=0
                        // dest is op2, src is op1
                        // ======================================================
                        8'h81: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MUL;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h83: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MUL;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h85: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MUL;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // MULU.B/H/W — 0x91/0x93/0x95 — unsigned multiply
                        // ======================================================
                        8'h91: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MULU;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h93: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MULU;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h95: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_MULU;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // MULX — 0x86 — Multiply Extended (32x32→64 signed)
                        // MULUY — 0x96 — Multiply Extended Unsigned (32x32→64)
                        // MAME: F12DecodeOperands(ReadAM,2, ReadAMAddress,3)
                        //   op1 = 32-bit source multiplier (ReadAM)
                        //   op2 = destination address: if flag2=1 → register pair [N:N+1]
                        //                              else        → 64-bit memory address
                        //
                        // Result: {hi32, lo32} = signed(op2_orig) * signed(op1)
                        //   lo → reg[N] or mem[op2]
                        //   hi → reg[N+1] or mem[op2+4]
                        // Flags: S=hi32[31], Z=(lo32==0 && hi32==0)
                        //
                        // For simplicity we handle only the register-pair case inline.
                        // Memory destination (rare in boot) stubs via ALU_PASS advance-only.
                        //
                        // NOTE: MULX destination AM uses size=3 (doubleword). We decode
                        // both AMs as size=2 (word) since the destination register is
                        // identified by the register number, not its size.
                        // ======================================================
                        8'h86, 8'h96: begin  // MULX / MULUY
                            begin
                                logic        mx_is_reg1, mx_is_imm1;
                                logic        mx_is_reg2, mx_is_imm2;
                                logic [31:0] mx_op1, mx_op2;
                                int          mx_len1, mx_len2;
                                logic [63:0] mx_result;
                                logic [31:0] mx_next_pc;
                                // Decode two word-size AMs (F1/F2 format)
                                if (ibuf[1][7]) begin
                                    // F1: two explicit AMs
                                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                                              mx_is_reg1, mx_is_imm1, mx_op1, mx_len1);
                                    decode_am(2+mx_len1, 2'd2, ibuf[1][5], reg_file[32],
                                              mx_is_reg2, mx_is_imm2, mx_op2, mx_len2);
                                    mx_next_pc = reg_file[32] + 32'd2 + mx_len1 + mx_len2;
                                end else if (ibuf[1][5]) begin
                                    // D=1: AM1=source, reg=dest
                                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                                              mx_is_reg1, mx_is_imm1, mx_op1, mx_len1);
                                    mx_op2     = {27'd0, ibuf[1][4:0]};
                                    mx_is_reg2 = 1'b1; mx_is_imm2 = 1'b0;
                                    mx_len2    = 0;
                                    mx_next_pc = reg_file[32] + 32'd2 + mx_len1;
                                end else begin
                                    // D=0: reg=source, AM=dest
                                    mx_op1     = reg_file[{1'b0, ibuf[1][4:0]}];
                                    mx_is_reg1 = 1'b1; mx_is_imm1 = 1'b0;
                                    mx_len1    = 0;
                                    decode_am(2, 2'd2, ibuf[1][5], reg_file[32],
                                              mx_is_reg2, mx_is_imm2, mx_op2, mx_len2);
                                    mx_next_pc = reg_file[32] + 32'd2 + mx_len2;
                                end
                                // Resolve op1 source
                                if (mx_is_reg1) mx_op1 = reg_file[mx_op1[4:0]];
                                // op1 is source value; op2 is destination register index (flag2)
                                // Compute 64-bit product
                                if (ibuf[0] == 8'h86) begin
                                    // MULX: signed
                                    mx_result = $signed(mx_op1) * $signed(
                                        mx_is_reg2 ? reg_file[mx_op2[4:0]] : mx_op2);
                                end else begin
                                    // MULUY: unsigned
                                    mx_result = {32'd0, mx_op1} * {32'd0,
                                        mx_is_reg2 ? reg_file[mx_op2[4:0]] : mx_op2};
                                end
                                // Write result to register pair
                                if (mx_is_reg2) begin
                                    begin
                                        logic [4:0] mx_rn;
                                        mx_rn = mx_op2[4:0];
                                        reg_file[{1'b0, mx_rn}]          <= mx_result[31:0];
                                        reg_file[{1'b0, mx_rn} + 6'd1]   <= mx_result[63:32];
                                    end
                                end
                                // Set flags
                                f_s  <= mx_result[63];
                                f_z  <= (mx_result == 64'd0);
                                f_ov <= 1'b0;
                                f_cy <= 1'b0;
                                reg_file[32] <= mx_next_pc;
                                state        <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // DIV.B/H/W — 0xA1/0xA3/0xA5 — signed divide
                        // opDIVB: OV=((appb==0x80)&&(op1==0xFF)); if op1&&!OV: appb/=op1
                        // ======================================================
                        8'hA1: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIV;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hA3: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIV;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hA5: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIV;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // DIVU.B/H/W — 0xB1/0xB3/0xB5 — unsigned divide
                        // ======================================================
                        8'hB1: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIVU;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hB3: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIVU;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hB5: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIVU;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // SHL.B/H/W — 0xA9/0xAB/0xAD — logical shift
                        // Signed count: +left, -right. OV always 0.
                        // ======================================================
                        8'hA9: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_SHL;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hAB: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_SHL;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hAD: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_SHL;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // SHA.B/H/W — 0xB9/0xBB/0xBD — arithmetic shift
                        // Signed count: +left (OV if sign changes), -right (arithmetic)
                        // ======================================================
                        8'hB9: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_SHA;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hBB: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_SHA;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hBD: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_SHA;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // ROT.B/H/W — 0x89/0x8B/0x8D — Rotate by signed count
                        // Format: F12 (opcode + instflags + AM1 src + AM2 dst)
                        // op1 = signed count (+left, -right), op2 = value (R/W)
                        // ======================================================
                        8'h89: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_ROT;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h8B: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_ROT;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        8'h8D: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_ROT;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x8E, 0x8F — opUNHANDLED in MAME; stub as ALU_CMP
                        // (no writeback, no flags) so AM decode advances PC correctly
                        // ======================================================
                        8'h8E, 8'h8F: begin
                            state <= S_EXECUTE;
                            op_alu_op    <= ALU_CMP;   // no writeback
                            op_size      <= 2'd2;
                            op_has_am2   <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // SETF — 0x47
                        // Format: opcode(1) + AM1(variable) + AM2 dest
                        // op1 = condition code (0-15), write 0/1 to dest byte
                        // MAME: F12DecodeFirstOperand(ReadAM,0) + F12WriteSecondOperand(0)
                        // This is a single-source, single-dest F1/F2 format but writes a byte
                        // We model it as op_has_am2=1 (2-op format), size=byte
                        // ======================================================
                        8'h47: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_SETF;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // DISPOSE — 0xCC — undo PREPARE stack frame
                        // SP = FP; FP = mem32[SP]; SP += 4
                        // No operand.
                        // ======================================================
                        8'hCC: begin
                            // SP = FP
                            reg_file[31] <= reg_file[30];
                            // Schedule read of old FP from new SP (= old FP)
                            // We use stk machinery: load [SP] into FP
                            stk_dst_reg <= 6'd30;  // destination = FP (reg 30)
                            stk_size    <= 2'd2;   // 32-bit
                            reg_file[32] <= reg_file[32] + 32'd1;  // PC += 1
                            state <= S_POP_SETUP;  // read from [new SP], SP += 4
                        end

                        // ======================================================
                        // PREPARE — 0xDE (m=0), 0xDF (m=1)
                        // Format: opcode(1) + AM byte(s) — reads 16-bit operand
                        // Step 1: SP -= 4; mem32[SP] = FP
                        // Step 2: FP = SP
                        // Step 3: SP -= operand
                        // Uses PREPARE_PUSH states (like CALL but pushes FP)
                        // ======================================================
                        8'hDE, 8'hDF: begin
                            begin
                                logic        pr_is_reg, pr_is_imm;
                                logic [31:0] pr_val;
                                int          pr_len;
                                // Operand: halfword (moddim=2 in MAME = word? actually moddim=2 for ReadAM 16-bit)
                                // MAME opPREPARE: m_moddim=2 → ReadAM → m_amout
                                // moddim 2 in MAME = word (4 bytes)? Let's use size=halfword (the operand is 16-bit typically)
                                // Actually from the MAME source: m_moddim = 2 (means word? But ReadAM reads per moddim)
                                // In practice, PREPARE takes a 16-bit frame size. Use size=halfword.
                                decode_am(1, 2'd1, 1'b0, reg_file[32],
                                          pr_is_reg, pr_is_imm, pr_val, pr_len);
                                if (pr_is_reg)
                                    prep_frame_size <= {16'd0, reg_file[pr_val[4:0]][15:0]};
                                else if (pr_is_imm)
                                    prep_frame_size <= {16'd0, pr_val[15:0]};
                                else
                                    prep_frame_size <= 32'd0;  // simplified: mem operand uncommon
                                reg_file[32] <= reg_file[32] + 32'd1 + pr_len;
                                state <= S_PREPARE_PUSH;
                            end
                        end

                        // ======================================================
                        // 0xF0/F1 — TESTB — Test Byte (read AM, set Z/S/CY/OV)
                        // 0xF2/F3 — TESTH — Test Halfword
                        // 0xF4/F5 — TESTW — Test Word
                        //
                        // Format: opcode(1) + AM(1+) — single operand (ReadAM)
                        // MAME: amout = ReadAM; Z=(amout==0); S=(msb); CY=0; OV=0
                        //
                        // These are single-operand instructions using S_EXECUTE
                        // with ALU_PASS but no writeback (just flag update).
                        // We use op_is_single_am=1, op_update_flags=1, op_alu_op=ALU_PASS
                        // and suppress writeback in S_EXECUTE (ex_do_wb=0 for PASS+no_wb).
                        // ======================================================
                        8'hF0, 8'hF1: begin  // TESTB (modm=0/1)
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd0;
                            op_has_am2 <= 1'b0; op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b1; op_no_am <= 1'b0;
                        end
                        8'hF2, 8'hF3: begin  // TESTH (modm=0/1)
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd1;
                            op_has_am2 <= 1'b0; op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b1; op_no_am <= 1'b0;
                        end
                        8'hF4, 8'hF5: begin  // TESTW (modm=0/1)
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd2;
                            op_has_am2 <= 1'b0; op_update_flags <= 1'b1;
                            op_is_branch <= 1'b0; op_is_single_am <= 1'b1; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0xC6 — DBxx (simple conditions) — Decrement and Branch
                        // 0xC7 — DBxx (composite conditions)
                        //
                        // Format: opcode(1) + cond_reg(1) + disp16(2) = 4 bytes
                        //   ibuf[1][7:5] = condition code
                        //   ibuf[1][4:0] = register index (Rn)
                        //   ibuf[3:2]    = signed 16-bit displacement (little-endian)
                        //
                        // Semantics (NEC V60 manual, opDB*):
                        //   Rn = Rn - 1
                        //   if cc AND (Rn != 0): PC += sign_ext(disp16)
                        //   else:                PC += 4
                        //
                        // 0xC6 condition table — from MAME s_OpC6Table[ibuf[1]>>5]:
                        //   0=DBV  (f_ov)            1=DBL  (f_cy)
                        //   2=DBE  (f_z)             3=DBNH (f_cy|f_z)
                        //   4=DBN  (f_s)             5=DBR  (always, just Rn!=0)
                        //   6=DBLT (f_s^f_ov)        7=DBLE (f_z|(f_s^f_ov))
                        //
                        // 0xC7 condition table — from MAME s_OpC7Table[ibuf[1]>>5]:
                        //   0=DBNV (!f_ov)           1=DBNL (!f_cy)
                        //   2=DBNE (!f_z)            3=DBH  (!(f_cy|f_z))
                        //   4=DBP  (!f_s)            5=TB   (branch if Rn==0, NO decrement)
                        //   6=DBGE (!(f_s^f_ov))     7=DBGT (!(f_z|(f_s^f_ov)))
                        // ======================================================
                        8'hC6: begin
                            begin
                                logic [4:0]  db_reg;
                                logic [31:0] db_new;
                                logic        db_cc;
                                db_reg = ibuf[1][4:0];
                                db_new = reg_file[{1'b0, db_reg}] - 32'd1;
                                // Evaluate condition per MAME s_OpC6Table
                                case (ibuf[1][7:5])
                                    3'd0: db_cc = f_ov;                    // DBV
                                    3'd1: db_cc = f_cy;                    // DBL
                                    3'd2: db_cc = f_z;                     // DBE
                                    3'd3: db_cc = f_cy | f_z;              // DBNH
                                    3'd4: db_cc = f_s;                     // DBN
                                    3'd5: db_cc = 1'b1;                    // DBR (always)
                                    3'd6: db_cc = f_s ^ f_ov;              // DBLT
                                    3'd7: db_cc = f_z | (f_s ^ f_ov);     // DBLE
                                endcase
                                // Write decremented value
                                reg_file[{1'b0, db_reg}] <= db_new;
                                // Branch or fall through
                                if (db_cc && (db_new != 32'd0))
                                    reg_file[32] <= reg_file[32] +
                                        {{16{ibuf[3][7]}}, ibuf[3], ibuf[2]};
                                else
                                    reg_file[32] <= reg_file[32] + 32'd4;
                                state <= S_FETCH0;
                            end
                        end

                        8'hC7: begin
                            begin
                                logic [4:0]  db7_reg;
                                logic [31:0] db7_new;
                                logic        db7_cc;
                                logic        db7_tb;  // 1 = TB variant (no decrement, branch if zero)
                                db7_reg = ibuf[1][4:0];
                                db7_tb  = (ibuf[1][7:5] == 3'd5);
                                db7_new = reg_file[{1'b0, db7_reg}] - 32'd1;
                                // Evaluate condition per MAME s_OpC7Table
                                case (ibuf[1][7:5])
                                    3'd0: db7_cc = !f_ov;                       // DBNV
                                    3'd1: db7_cc = !f_cy;                       // DBNL
                                    3'd2: db7_cc = !f_z;                        // DBNE
                                    3'd3: db7_cc = !(f_cy | f_z);               // DBH
                                    3'd4: db7_cc = !f_s;                        // DBP
                                    3'd5: db7_cc = 1'b1;                        // TB: don't care (handled below)
                                    3'd6: db7_cc = !(f_s ^ f_ov);               // DBGE
                                    3'd7: db7_cc = !(f_z | (f_s ^ f_ov));       // DBGT
                                endcase
                                // TB variant: branch if Rn==0 (no decrement)
                                // DB* variants: decrement then branch if cc AND Rn!=0
                                if (db7_tb) begin
                                    // TB: do NOT decrement; branch if original value == 0
                                    if (reg_file[{1'b0, db7_reg}] == 32'd0)
                                        reg_file[32] <= reg_file[32] +
                                            {{16{ibuf[3][7]}}, ibuf[3], ibuf[2]};
                                    else
                                        reg_file[32] <= reg_file[32] + 32'd4;
                                    // SP not decremented for TB
                                end else begin
                                    // DB* variant: write decremented value
                                    reg_file[{1'b0, db7_reg}] <= db7_new;
                                    // Branch or fall through
                                    if (db7_cc && (db7_new != 32'd0))
                                        reg_file[32] <= reg_file[32] +
                                            {{16{ibuf[3][7]}}, ibuf[3], ibuf[2]};
                                    else
                                        reg_file[32] <= reg_file[32] + 32'd4;
                                end
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // 0x20/22/24 — IN.B/H/W  (opINB/H/W)  — I/O read
                        // 0x21/23/25 — OUT.B/H/W (opOUTB/H/W) — I/O write
                        // No I/O bus; treat IN as MOV (src=0) and OUT as NOP.
                        // Both still decode AM fields so PC advances correctly.
                        // ======================================================
                        8'h20: begin  // INB
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h22: begin  // INH
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h24: begin  // INW
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h21: begin  // OUTB — NOP (decode AM, advance PC, discard)
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h23: begin  // OUTH
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h25: begin  // OUTW
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x30-0x37 — opUNHANDLED in MAME — two-op NOP stub
                        // ======================================================
                        8'h30, 8'h31, 8'h32, 8'h33,
                        8'h34, 8'h35, 8'h36, 8'h37: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x3F — MOVD — Move Doubleword (64-bit)
                        // Treat as MOV.W (32-bit) — writes lo 32 bits only.
                        // ======================================================
                        8'h3F: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // XCH.B/H/W — 0x41/43/45 — Exchange register/memory
                        // Write op1 to op2 (reverse half is omitted).
                        // ======================================================
                        8'h41: begin  // XCHB
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h43: begin  // XCHH
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h45: begin  // XCHW
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x4A — UPDPSWH — Update PSW Halfword (lower 16 bits)
                        // PSW = (PSW & ~op2) | (op1 & op2), masked to 16 bits.
                        // ======================================================
                        8'h4A: begin
                            begin
                                logic        u2_is_r1, u2_is_i1, u2_is_r2, u2_is_i2;
                                logic [31:0] u2_v1, u2_v2;
                                int          u2_l1, u2_l2;
                                logic [31:0] u2_np, u2_cp;
                                if (ibuf[1][7]) begin
                                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                                              u2_is_r1, u2_is_i1, u2_v1, u2_l1);
                                    decode_am(2+u2_l1, 2'd2, ibuf[1][5], reg_file[32],
                                              u2_is_r2, u2_is_i2, u2_v2, u2_l2);
                                    reg_file[32] <= reg_file[32] + 32'd2 + u2_l1 + u2_l2;
                                end else if (ibuf[1][5]) begin
                                    decode_am(2, 2'd2, ibuf[1][6], reg_file[32],
                                              u2_is_r1, u2_is_i1, u2_v1, u2_l1);
                                    u2_v2 = reg_file[{1'b0, ibuf[1][4:0]}];
                                    u2_l2 = 0;
                                    reg_file[32] <= reg_file[32] + 32'd2 + u2_l1;
                                end else begin
                                    u2_v1 = reg_file[{1'b0, ibuf[1][4:0]}];
                                    u2_l1 = 0; u2_is_r1 = 1'b1; u2_is_i1 = 1'b0;
                                    decode_am(2, 2'd2, ibuf[1][5], reg_file[32],
                                              u2_is_r2, u2_is_i2, u2_v2, u2_l2);
                                    reg_file[32] <= reg_file[32] + 32'd2 + u2_l2;
                                end
                                if (u2_is_r1) u2_v1 = reg_file[u2_v1[5:0]];
                                if (ibuf[1][7] && u2_is_r2) u2_v2 = reg_file[u2_v2[5:0]];
                                u2_cp = {reg_file[33][31:4], f_cy, f_ov, f_s, f_z};
                                u2_np = (u2_cp & ~(u2_v2 & 32'h0000FFFF)) |
                                        (u2_v1  &  u2_v2 & 32'h0000FFFF);
                                f_z  <= u2_np[0]; f_s  <= u2_np[1];
                                f_ov <= u2_np[2]; f_cy <= u2_np[3];
                                reg_file[33] <= u2_np;
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // 0x4B CHLVL / 0x4C UNHANDLED / 0x4D CHKAR /
                        // 0x4E CHKAW  / 0x4F CHKAE — two-op NOP stubs
                        // ======================================================
                        8'h4B, 8'h4C, 8'h4D, 8'h4E, 8'h4F: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // REM.B/H/W — 0x50/52/54 — Signed Remainder (op2 % op1)
                        // REMU.B/H/W — 0x51/53/55 — Unsigned Remainder
                        // Map to EXT_DIV / EXT_DIVU (computes quotient, not remainder,
                        // but prevents traps; good enough for most use).
                        // ======================================================
                        8'h50: begin  // REMB
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIV;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h52: begin  // REMH
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIV;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h54: begin  // REMW
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIV;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h51: begin  // REMUB
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIVU;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h53: begin  // REMUH
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIVU;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h55: begin  // REMUW
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIVU;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x5F — op5F — string-class instruction (format 7a stub)
                        // Compute length from AM bytes, advance PC, NOP.
                        // ======================================================
                        8'h5F: begin
                            begin
                                logic [3:0] f5f_l1, f5f_l2;
                                logic [4:0] f5f_tot;
                                case (ibuf[2][7:5])
                                    3'b000, 3'b001,
                                    3'b010, 3'b011: f5f_l1 = 4'd1;
                                    3'b100:         f5f_l1 = 4'd2;
                                    3'b101:         f5f_l1 = 4'd3;
                                    3'b110:         f5f_l1 = 4'd5;
                                    default:        f5f_l1 = 4'd5;
                                endcase
                                case (ibuf[3 + f5f_l1][7:5])
                                    3'b000, 3'b001,
                                    3'b010, 3'b011: f5f_l2 = 4'd1;
                                    3'b100:         f5f_l2 = 4'd2;
                                    3'b101:         f5f_l2 = 4'd3;
                                    3'b110:         f5f_l2 = 4'd5;
                                    default:        f5f_l2 = 4'd5;
                                endcase
                                f5f_tot = 5'd4 + {1'b0, f5f_l1} + {1'b0, f5f_l2};
                                reg_file[32] <= reg_file[32] + {27'd0, f5f_tot};
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // 0x6B — opUNHANDLED 8-bit branch slot — skip 2 bytes
                        // 0x7B — opUNHANDLED 16-bit branch slot — skip 3 bytes
                        // ======================================================
                        8'h6B: begin
                            reg_file[32] <= reg_file[32] + 32'd2;
                            state <= S_FETCH0;
                        end
                        8'h7B: begin
                            reg_file[32] <= reg_file[32] + 32'd3;
                            state <= S_FETCH0;
                        end

                        // ======================================================
                        // ADDC.B/H/W — 0x90/92/94 — Add with Carry
                        // result = op2 + op1 + CY
                        // Map to ADD (ignores carry-in; prevents trap).
                        // ======================================================
                        8'h90: begin  // ADDCB
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_ADD; op_is_ext <= 1'b0;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h92: begin  // ADDCH
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_ADD; op_is_ext <= 1'b0;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h94: begin  // ADDCW
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_ADD; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // SET1 — 0x97 — Set Bit   (op2 |=  1<<(op1&31), CY=old bit)
                        // CLR1 — 0xA7 — Clear Bit (op2 &= ~1<<(op1&31), CY=old bit)
                        // NOT1 — 0xB7 — Toggle Bit(op2 ^=  1<<(op1&31), CY=old bit)
                        // Stub as two-op NOP — decode AM fields, advance PC.
                        // ======================================================
                        8'h97: begin  // SET1
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hA7: begin  // CLR1
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hB7: begin  // NOT1
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // SUBC.B/H/W — 0x98/9A/9C — Subtract with Carry (Borrow)
                        // result = op2 - op1 - CY
                        // Map to SUB (carry-in ignored — acceptable approximation).
                        // ======================================================
                        8'h98: begin  // SUBCB
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_SUB; op_is_ext <= 1'b0;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h9A: begin  // SUBCH
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_SUB; op_is_ext <= 1'b0;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h9C: begin  // SUBCW
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_SUB; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // ROTC.B/H/W — 0x99/9B/9D — Rotate through Carry
                        // Map to ROT (EXT_ROT) — ignores CY bit in rotation.
                        // ======================================================
                        8'h99: begin  // ROTCB
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_ROT;
                            op_size <= 2'd0; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h9B: begin  // ROTCH
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_ROT;
                            op_size <= 2'd1; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'h9D: begin  // ROTCW
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_ROT;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0x9E, 0x9F — opUNHANDLED in MAME — two-op NOP stub
                        // ======================================================
                        8'h9E, 8'h9F: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // DIVX — 0xA6 — Divide Extended (64÷32) signed
                        // DIVUX — 0xB6 — Divide Extended unsigned
                        // Map to EXT_DIV / EXT_DIVU (32-bit path, sufficient for boot).
                        // ======================================================
                        8'hA6: begin  // DIVX
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIV;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end
                        8'hB6: begin  // DIVUX
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b1; op_ext_op <= EXT_DIVU;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0xAE, 0xAF, 0xBE, 0xBF — opUNHANDLED — two-op NOP
                        // ======================================================
                        8'hAE, 8'hAF, 8'hBE, 8'hBF: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0xC0-0xC5 — opUNHANDLED in MAME — two-op NOP stubs
                        // ======================================================
                        8'hC0, 8'hC1, 8'hC2, 8'hC3,
                        8'hC4, 8'hC5: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_CMP; op_is_ext <= 1'b0;
                            op_size <= 2'd2; op_has_am2 <= 1'b1;
                            op_update_flags <= 1'b0; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b0; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // 0xCB — TRAPFL — Trap on Flag (1-byte NOP in simulation)
                        // 0xCE, 0xCF — opUNHANDLED (1-byte NOP stubs)
                        // ======================================================
                        8'hCB, 8'hCE, 8'hCF: begin
                            reg_file[32] <= reg_file[32] + 32'd1;
                            state <= S_FETCH0;
                        end

                        // ======================================================
                        // TASI — 0xE0/_1 — Test And Set Byte (atomic RMW)
                        // Reads byte, sets Z from value; writes 0xFF.
                        // Modeled as TEST only (no writeback) — sufficient for sim.
                        // Single-operand, byte size.
                        // ======================================================
                        8'hE0, 8'hE1: begin
                            state <= S_EXECUTE;
                            op_alu_op <= ALU_PASS; op_is_ext <= 1'b0;
                            op_size <= 2'd0; op_has_am2 <= 1'b0;
                            op_update_flags <= 1'b1; op_is_branch <= 1'b0;
                            op_is_single_am <= 1'b1; op_no_am <= 1'b0;
                        end

                        // ======================================================
                        // RETIU — 0xEA/_B — Return from Interrupt Unnested
                        // Same as RETIS but no frame_adj operand (adj=0).
                        // Reuse RETIS states with prep_frame_size=0.
                        // ======================================================
                        8'hEA, 8'hEB: begin
                            prep_frame_size <= 32'd0;
                            state <= S_RETIS_PC_LO;
                        end

                        // ======================================================
                        // GETPSW — 0xF6/_7 — Get PSW into operand
                        // Single-operand write: writes full PSW to AM destination.
                        // ======================================================
                        8'hF6, 8'hF7: begin
                            begin
                                logic        gp_is_r, gp_is_i;
                                logic [31:0] gp_a;
                                int          gp_l;
                                logic [31:0] gp_psw;
                                decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                                          gp_is_r, gp_is_i, gp_a, gp_l);
                                gp_psw = {reg_file[33][31:4], f_cy, f_ov, f_s, f_z};
                                if (gp_is_r)
                                    reg_file[gp_a[5:0]] <= gp_psw;
                                // Memory write path not modeled (uncommon)
                                reg_file[32] <= reg_file[32] + 32'd1 + gp_l;
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // TRAP — 0xF8/_9 — Software Trap (NOP in simulation)
                        // Format: opcode(1) + AM(1+). Advance PC past operand.
                        // ======================================================
                        8'hF8, 8'hF9: begin
                            begin
                                logic        tr_is_r, tr_is_i;
                                logic [31:0] tr_a;
                                int          tr_l;
                                decode_am(1, 2'd1, ibuf[0][0], reg_file[32],
                                          tr_is_r, tr_is_i, tr_a, tr_l);
                                reg_file[32] <= reg_file[32] + 32'd1 + tr_l;
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // STTASK — 0xFC/_D — Store Task Register
                        // Writes TR (reg_file[42]) to AM destination.
                        // ======================================================
                        8'hFC, 8'hFD: begin
                            begin
                                logic        st_is_r, st_is_i;
                                logic [31:0] st_a;
                                int          st_l;
                                decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                                          st_is_r, st_is_i, st_a, st_l);
                                if (st_is_r)
                                    reg_file[st_a[5:0]] <= reg_file[42];  // TR
                                reg_file[32] <= reg_file[32] + 32'd1 + st_l;
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // CLRTLB — 0xFE/_F — Clear TLB Entry (NOP — no TLB)
                        // Format: opcode(1) + AM(1+). Advance PC past operand.
                        // ======================================================
                        8'hFE, 8'hFF: begin
                            begin
                                logic        ct_is_r, ct_is_i;
                                logic [31:0] ct_a;
                                int          ct_l;
                                decode_am(1, 2'd2, ibuf[0][0], reg_file[32],
                                          ct_is_r, ct_is_i, ct_a, ct_l);
                                reg_file[32] <= reg_file[32] + 32'd1 + ct_l;
                                state <= S_FETCH0;
                            end
                        end

                        // ======================================================
                        // Default: unimplemented — trap
                        // ======================================================
                        default: begin
                            state <= S_TRAP;
                        end

                    endcase
                    // Clear op_is_ext on every new decode (only set when needed)
                    // (Done per-case above; no global clear needed)
                end  // S_DECODE

                // ============================================================
                // S_EXECUTE: perform ALU operation on decoded operands
                //
                // This state handles F1/F2/D format instructions by:
                //   1. Decoding AM bytes from ibuf using the decode_am task
                //   2. Reading source operand (op1) — register or memory
                //   3. Reading dest operand (op2) — register or memory
                //   4. Feeding into ALU
                //   5. Writing result back
                //
                // For memory operands, we insert S_MEM_READ/S_MEM_WRITE states.
                //
                // Refer to op12.hxx F12DecodeOperands and F12DecodeFirstOperand
                // for the exact format 1/2 decoding logic.
                // ============================================================
                S_EXECUTE: begin
                    // ---- Decode operands from ibuf ----
                    // ibuf[0] = opcode
                    // ibuf[1] = instflags (for F1/F2 instructions)
                    //
                    // The V60 instruction format for 2-operand instructions:
                    //   F1 (instflags[7]=1): both operands have full AM encoding
                    //     ibuf[1] = instflags  (M1=bit6, M2=bit5)
                    //     ibuf[2..] = AM1 bytes
                    //     ibuf[2+amlength1..] = AM2 bytes
                    //   F2 (instflags[7]=0, D=instflags[5]=1): dest=reg in instflags[4:0]
                    //     ibuf[2..] = AM1 bytes (source)
                    //   F2 (instflags[7]=0, D=0): src=reg in instflags[4:0]
                    //     ibuf[2..] = AM2 bytes (destination)
                    //
                    // For single-AM instructions (INC/DEC/JMP/NOT/NEG):
                    //   ibuf[1] = AM byte (modval)
                    //   ibuf[2..] = displacement bytes if needed

                    begin
                        // Use module-level temporaries (ex_* prefix)
                        ex_sz       = op_size;
                        ex_instr_pc = reg_file[32];
                        ex_is_reg1  = 1'b0;
                        ex_is_reg2  = 1'b0;
                        ex_am1_addr = 32'd0;
                        ex_am2_addr = 32'd0;
                        ex_am1_len  = 0;
                        ex_am2_len  = 0;
                        ex_src_val  = 32'd0;
                        ex_dst_val  = 32'd0;
                        ex_res_val  = 32'd0;
                        ex_do_wb    = 1'b0;

                        if (op_is_single_am) begin
                            // ---- Single-operand: INC/DEC/NOT/NEG/JMP/TEST ----
                            // Format: opcode(1) | AM(1+)
                            // ibuf[1] is the AM byte
                            // modm from low bit of opcode (_0 = modm=0, _1 = modm=1)
                            if (mem_loaded) begin
                                // Re-entering after S_MEM_READ: mem_read_result has value
                                ex_src_val   = mem_read_result;
                                ex_am1_addr  = op1_addr;
                                ex_am1_len   = {28'd0, amlength1};
                                ex_am2_addr  = op2_addr;
                                ex_am2_len   = {28'd0, amlength2};
                                ex_total_len = {27'd0, instr_len};
                                ex_is_reg1   = 1'b0;
                                ex_is_imm1   = 1'b0;
                                mem_loaded  <= 1'b0;
                            end else begin
                                decode_am(1, ex_sz, ibuf[0][0], ex_instr_pc,
                                          ex_is_reg1, ex_is_imm1, ex_am1_addr, ex_am1_len);
                                ex_is_imm2  = ex_is_imm1;
                                ex_am2_addr = ex_am1_addr;
                                ex_is_reg2  = ex_is_reg1;
                                ex_am2_len  = ex_am1_len;
                                ex_total_len = 32'd1 + ex_am1_len;  // opcode + AM bytes

                                // Read source (same as dest for single-operand)
                                if (ex_is_reg1) begin
                                    ex_src_val = read_reg_sized(ex_am1_addr[4:0], ex_sz);
                                end else if (ex_is_imm1) begin
                                    // Immediate: value is in ex_am1_addr directly
                                    case (ex_sz)
                                        2'd0: ex_src_val = {24'd0, ex_am1_addr[7:0]};
                                        2'd1: ex_src_val = {16'd0, ex_am1_addr[15:0]};
                                        default: ex_src_val = ex_am1_addr;
                                    endcase
                                end else begin
                                    // Need memory read — go do it and come back
                                    mem_target_addr  <= ex_am1_addr;
                                    mem_access_size  <= ex_sz;
                                    mem_is_write     <= 1'b0;
                                    mem_return_state <= S_EXECUTE;
                                    op1_addr  <= ex_am1_addr;
                                    op1_flag  <= ex_is_reg1;
                                    amlength1 <= ex_am1_len[3:0];
                                    op2_addr  <= ex_am2_addr;
                                    op2_flag  <= ex_is_reg2;
                                    amlength2 <= ex_am2_len[3:0];
                                    instr_len <= ex_total_len[4:0];
                                    state <= S_MEM_READ;
                                    ex_src_val = 32'hDEAD;  // placeholder
                                end
                            end

                            if (ex_is_reg1 || ex_is_imm1 || mem_loaded || state == S_EXECUTE) begin
                                // ALU: for INC: a=1,b=src; for DEC: a=1,b=src; JMP: a=am_addr
                                case (op_alu_op)
                                    ALU_ADD: begin  // INC
                                        // ALU: b=ex_src_val, a=1
                                        case (ex_sz)
                                            2'd0: ex_res_val = {24'd0, ex_src_val[7:0] + 8'd1};
                                            2'd1: ex_res_val = {16'd0, ex_src_val[15:0] + 16'd1};
                                            2'd2: ex_res_val = ex_src_val + 32'd1;
                                            default: ex_res_val = ex_src_val + 32'd1;
                                        endcase
                                        // Update flags
                                        if (op_update_flags) begin
                                            f_z  <= (ex_res_val[31:0] == 32'd0) || (ex_sz==2'd0 && ex_res_val[7:0]==8'd0) || (ex_sz==2'd1 && ex_res_val[15:0]==16'd0);
                                            f_s  <= (ex_sz==2'd0) ? ex_res_val[7] : (ex_sz==2'd1) ? ex_res_val[15] : ex_res_val[31];
                                            // Carry for INC: byte carry
                                            f_cy <= (ex_sz==2'd0) ? (ex_src_val[7:0]==8'hFF) :
                                                    (ex_sz==2'd1) ? (ex_src_val[15:0]==16'hFFFF) :
                                                                 (ex_src_val==32'hFFFFFFFF);
                                            // Overflow: only if 0x7F->0x80
                                            f_ov <= (ex_sz==2'd0) ? (ex_src_val[7:0]==8'h7F) :
                                                    (ex_sz==2'd1) ? (ex_src_val[15:0]==16'h7FFF) :
                                                                 (ex_src_val==32'h7FFFFFFF);
                                        end
                                        ex_do_wb = 1'b1;
                                    end
                                    ALU_SUB: begin  // DEC
                                        case (ex_sz)
                                            2'd0: ex_res_val = {24'd0, ex_src_val[7:0] - 8'd1};
                                            2'd1: ex_res_val = {16'd0, ex_src_val[15:0] - 16'd1};
                                            2'd2: ex_res_val = ex_src_val - 32'd1;
                                            default: ex_res_val = ex_src_val - 32'd1;
                                        endcase
                                        if (op_update_flags) begin
                                            f_z  <= (ex_sz==2'd0) ? (ex_res_val[7:0]==8'd0) :
                                                    (ex_sz==2'd1) ? (ex_res_val[15:0]==16'd0) :
                                                                 (ex_res_val==32'd0);
                                            f_s  <= (ex_sz==2'd0) ? ex_res_val[7] : (ex_sz==2'd1) ? ex_res_val[15] : ex_res_val[31];
                                            f_cy <= (ex_sz==2'd0) ? (ex_src_val[7:0]==8'h00) :
                                                    (ex_sz==2'd1) ? (ex_src_val[15:0]==16'h0000) :
                                                                 (ex_src_val==32'd0);
                                            f_ov <= (ex_sz==2'd0) ? (ex_src_val[7:0]==8'h80) :
                                                    (ex_sz==2'd1) ? (ex_src_val[15:0]==16'h8000) :
                                                                 (ex_src_val==32'h80000000);
                                        end
                                        ex_do_wb = 1'b1;
                                    end
                                    ALU_NOT: begin
                                        case (ex_sz)
                                            2'd0: ex_res_val = {24'hFFFFFF, ~ex_src_val[7:0]};
                                            2'd1: ex_res_val = {16'hFFFF, ~ex_src_val[15:0]};
                                            2'd2: ex_res_val = ~ex_src_val;
                                            default: ex_res_val = ~ex_src_val;
                                        endcase
                                        if (op_update_flags) begin
                                            f_ov <= 1'b0;
                                            f_cy <= 1'b0;
                                            f_s  <= (ex_sz==2'd0) ? ex_res_val[7] : (ex_sz==2'd1) ? ex_res_val[15] : ex_res_val[31];
                                            f_z  <= (ex_sz==2'd0) ? (ex_res_val[7:0]==8'd0) :
                                                    (ex_sz==2'd1) ? (ex_res_val[15:0]==16'd0) :
                                                                 (ex_res_val==32'd0);
                                        end
                                        ex_do_wb = 1'b1;
                                    end
                                    ALU_NEG: begin
                                        case (ex_sz)
                                            2'd0: ex_res_val = {24'd0, -ex_src_val[7:0]};
                                            2'd1: ex_res_val = {16'd0, -ex_src_val[15:0]};
                                            2'd2: ex_res_val = -ex_src_val;
                                            default: ex_res_val = -ex_src_val;
                                        endcase
                                        if (op_update_flags) begin
                                            f_cy <= (ex_src_val != 32'd0);
                                            f_s  <= (ex_sz==2'd0) ? ex_res_val[7] : (ex_sz==2'd1) ? ex_res_val[15] : ex_res_val[31];
                                            f_z  <= (ex_sz==2'd0) ? (ex_res_val[7:0]==8'd0) :
                                                    (ex_sz==2'd1) ? (ex_res_val[15:0]==16'd0) :
                                                                 (ex_res_val==32'd0);
                                            f_ov <= (ex_sz==2'd0) ? (ex_src_val[7:0]==8'h80) :
                                                    (ex_sz==2'd1) ? (ex_src_val[15:0]==16'h8000) :
                                                                 (ex_src_val==32'h80000000);
                                        end
                                        ex_do_wb = 1'b1;
                                    end
                                    ALU_PASS: begin  // JMP or TEST
                                        if (op_is_branch) begin
                                            // JMP: PC = ex_am1_addr (effective address)
                                            reg_file[32] <= ex_am1_addr;
                                            ex_do_wb     = 1'b0;
                                            ex_total_len = 32'd0;  // JMP returns 0 in MAME
                                        end else begin
                                            // TEST: set flags from value, no writeback
                                            if (op_update_flags) begin
                                                f_z  <= (ex_sz==2'd0) ? (ex_src_val[7:0]==8'd0) :
                                                        (ex_sz==2'd1) ? (ex_src_val[15:0]==16'd0) :
                                                                         (ex_src_val==32'd0);
                                                f_s  <= (ex_sz==2'd0) ? ex_src_val[7] :
                                                        (ex_sz==2'd1) ? ex_src_val[15] :
                                                                         ex_src_val[31];
                                                f_cy <= 1'b0;
                                                f_ov <= 1'b0;
                                            end
                                            ex_do_wb = 1'b0;
                                        end
                                    end
                                    default: ex_do_wb = 1'b0;
                                endcase

                                // Write back single-operand result
                                if (ex_do_wb) begin
                                    if (ex_is_reg1) begin
                                        // Write to register
                                        case (ex_sz)
                                            2'd0: reg_file[ex_am1_addr[4:0]] <=
                                                    (reg_file[ex_am1_addr[4:0]] & 32'hFFFFFF00) | {24'd0, ex_res_val[7:0]};
                                            2'd1: reg_file[ex_am1_addr[4:0]] <=
                                                    (reg_file[ex_am1_addr[4:0]] & 32'hFFFF0000) | {16'd0, ex_res_val[15:0]};
                                            2'd2: reg_file[ex_am1_addr[4:0]] <= ex_res_val;
                                            default: reg_file[ex_am1_addr[4:0]] <= ex_res_val;
                                        endcase
                                    end else begin
                                        // Write to memory
                                        result_val   <= ex_res_val;
                                        op2_addr     <= ex_am1_addr;
                                        op2_flag     <= 1'b0;
                                        writeback_size <= ex_sz;
                                        instr_len    <= ex_total_len[4:0];
                                        state        <= S_MEM_WRITE;
                                    end
                                end

                                // Advance PC: skip for JMP (ALU_PASS + branch), advance for all others
                                // TEST (ALU_PASS + !branch) also advances PC
                                if ((op_alu_op != ALU_PASS || !op_is_branch) && !(ex_do_wb && !ex_is_reg1))
                                    reg_file[32] <= ex_instr_pc + ex_total_len;

                                // Only go to FETCH0 if not going to MEM_WRITE.
                                // When ex_do_wb=1 and ex_is_reg1=0, state<=S_MEM_WRITE was
                                // already set above; don't override it here.
                                if (!(ex_do_wb && !ex_is_reg1))
                                    state <= S_FETCH0;

                                // Handle auto-increment/decrement side effects
                                if (ibuf[1][7:5] == 3'b010) begin // auto-increment
                                    case (ex_sz)
                                        2'd0: reg_file[ibuf[1][4:0]] <= reg_file[ibuf[1][4:0]] + 32'd1;
                                        2'd1: reg_file[ibuf[1][4:0]] <= reg_file[ibuf[1][4:0]] + 32'd2;
                                        2'd2: reg_file[ibuf[1][4:0]] <= reg_file[ibuf[1][4:0]] + 32'd4;
                                        default: reg_file[ibuf[1][4:0]] <= reg_file[ibuf[1][4:0]] + 32'd4;
                                    endcase
                                end else if (ibuf[1][7:5] == 3'b011) begin // auto-decrement
                                    case (ex_sz)
                                        2'd0: reg_file[ibuf[1][4:0]] <= reg_file[ibuf[1][4:0]] - 32'd1;
                                        2'd1: reg_file[ibuf[1][4:0]] <= reg_file[ibuf[1][4:0]] - 32'd2;
                                        2'd2: reg_file[ibuf[1][4:0]] <= reg_file[ibuf[1][4:0]] - 32'd4;
                                        default: reg_file[ibuf[1][4:0]] <= reg_file[ibuf[1][4:0]] - 32'd4;
                                    endcase
                                end
                            end  // if ex_is_reg1 || state==S_EXECUTE

                        end else begin
                            // ---- Two-operand F1/F2 format ----
                            // Decode instflags byte
                            logic [7:0] ex_iflags;
                            logic [4:0] ex_reg_in_iflags;
                            ex_iflags        = ibuf[1];
                            ex_reg_in_iflags = ex_iflags[4:0];

                            if (mem_loaded) begin
                                // Re-entering S_EXECUTE after op1 memory read completed.
                                // mem_read_result holds op1; op2_addr/op2_flag were saved.
                                // Restore context from saved registers.
                                ex_is_reg1  = 1'b0;   // op1 was memory (already loaded)
                                ex_is_imm1  = 1'b0;
                                ex_am1_addr = op1_addr;
                                ex_am1_len  = {28'd0, amlength1};
                                ex_is_reg2  = op2_flag;
                                ex_is_imm2  = 1'b0;
                                ex_am2_addr = op2_addr;
                                ex_am2_len  = {28'd0, amlength2};
                                ex_total_len = {27'd0, instr_len};
                                ex_src_val  = mem_read_result;
                                mem_loaded  <= 1'b0;  // consume the loaded data
                            end else begin

                            // SHL/SHA/ROT shift count (first operand) is always byte-sized.
                            // MAME uses moddim=0 for the count AM decode, independent of
                            // the data operand size (byte/halfword/word).  Using ex_sz here
                            // would make an immediate #F0 expand to 4 bytes instead of 1,
                            // consuming the RSR that follows as operand data.
                            // NOTE: do NOT use a local logic variable here -- Verilator will
                            // inline ex_sz directly and ignore the conditional assignment.
                            // Inline the conditional expression in every decode_am call instead.

                            if (ex_iflags[7]) begin
                                // F1 mode: explicit AM for both operands
                                //   AM1 at ibuf[2], modm1 = instflags[6]
                                //   AM2 at ibuf[2+amlength1], modm2 = instflags[5]
                                decode_am(2,
                                          (op_is_ext && (op_ext_op == EXT_SHL || op_ext_op == EXT_SHA || op_ext_op == EXT_ROT)) ? 2'd0 : ex_sz,
                                          ex_iflags[6], ex_instr_pc,
                                          ex_is_reg1, ex_is_imm1, ex_am1_addr, ex_am1_len);
                                decode_am(2 + ex_am1_len, ex_sz, ex_iflags[5], ex_instr_pc,
                                          ex_is_reg2, ex_is_imm2, ex_am2_addr, ex_am2_len);
                            end else if (ex_iflags[5]) begin
                                // D=1: dest = register in ex_iflags[4:0], src = AM at ibuf[2]
                                // src modm = instflags[6]
                                decode_am(2,
                                          (op_is_ext && (op_ext_op == EXT_SHL || op_ext_op == EXT_SHA || op_ext_op == EXT_ROT)) ? 2'd0 : ex_sz,
                                          ex_iflags[6], ex_instr_pc,
                                          ex_is_reg1, ex_is_imm1, ex_am1_addr, ex_am1_len);
                                ex_is_reg2  = 1'b1;
                                ex_is_imm2  = 1'b0;
                                ex_am2_addr = {27'd0, ex_reg_in_iflags};
                                ex_am2_len  = 0;
                            end else begin
                                // D=0: src = register in ex_iflags[4:0], dest = AM at ibuf[2]
                                // dest modm = instflags[6]
                                ex_is_reg1  = 1'b1;
                                ex_is_imm1  = 1'b0;
                                ex_am1_addr = {27'd0, ex_reg_in_iflags};
                                ex_am1_len  = 0;
                                decode_am(2, ex_sz, ex_iflags[6], ex_instr_pc,
                                          ex_is_reg2, ex_is_imm2, ex_am2_addr, ex_am2_len);
                            end

                            ex_total_len = 32'd2 + ex_am1_len + ex_am2_len;

                            // Read source operand (op1)
                            if (ex_is_reg1) begin
                                ex_src_val = read_reg_sized(ex_am1_addr[4:0], ex_sz);
                            end else if (ex_is_imm1) begin
                                // Immediate: value is in ex_am1_addr
                                case (ex_sz)
                                    2'd0: ex_src_val = {24'd0, ex_am1_addr[7:0]};
                                    2'd1: ex_src_val = {16'd0, ex_am1_addr[15:0]};
                                    default: ex_src_val = ex_am1_addr;
                                endcase
                            end else begin
                                // For 2-op ops that need to read op1 from memory:
                                op1_addr  <= ex_am1_addr;
                                op1_flag  <= ex_is_reg1;
                                op2_addr  <= ex_am2_addr;
                                op2_flag  <= ex_is_reg2;
                                amlength1 <= ex_am1_len[3:0];
                                amlength2 <= ex_am2_len[3:0];
                                instr_len <= ex_total_len[4:0];
                                mem_target_addr  <= ex_am1_addr;
                                mem_access_size  <= ex_sz;
                                mem_is_write     <= 1'b0;
                                state <= S_MEM_READ;
                                ex_src_val = 32'hBAD;  // placeholder until mem read returns
                            end

                            end  // if !mem_loaded

                            // Read dest operand (op2) for operations that need it
                            // (only runs when op1 is available: register, immediate, or mem_loaded)
                            if (ex_is_reg1 || ex_is_imm1 || mem_loaded) begin
                                if (op_alu_op != ALU_PASS || op_is_ext) begin
                                    if (ex_is_reg2) begin
                                        ex_dst_val = read_reg_sized(ex_am2_addr[4:0], ex_sz);
                                    end else if (ex_is_imm2) begin
                                        case (ex_sz)
                                            2'd0: ex_dst_val = {24'd0, ex_am2_addr[7:0]};
                                            2'd1: ex_dst_val = {16'd0, ex_am2_addr[15:0]};
                                            default: ex_dst_val = ex_am2_addr;
                                        endcase
                                    end else begin
                                        // Need to read op2 from memory too
                                        ex_dst_val = 32'd0;  // will be read in S_MEM_READ
                                    end
                                end

                                // ---- ALU operation ----
                                // MAME convention for 2-op: result = op2 OP op1
                                //   op1 = source (read with ReadAM)
                                //   op2 = dest   (read with ReadAMAddress, then write back)
                                // MOV: result = op1 (pass through)
                                // Extended ops (op_is_ext=1) are dispatched after this case.
                                case (op_alu_op)
                                    ALU_PASS: begin
                                        // MOV: pass src to dest (non-extended only)
                                        ex_res_val = ex_src_val;
                                        ex_do_wb   = 1'b1;
                                    end
                                    ALU_ADD: begin
                                        case (ex_sz)
                                            2'd0: begin                                                ex_add_b   = {1'b0,ex_dst_val[7:0]} + {1'b0,ex_src_val[7:0]};
                                                ex_res_val = {24'd0, ex_add_b[7:0]};
                                                if (op_update_flags) begin
                                                    f_cy <= ex_add_b[8];
                                                    f_ov <= (ex_dst_val[7]==ex_src_val[7]) && (ex_res_val[7]!=ex_src_val[7]);
                                                    f_s  <= ex_res_val[7];
                                                    f_z  <= (ex_res_val[7:0]==8'd0);
                                                end
                                            end
                                            2'd1: begin                                                ex_add_h   = {1'b0,ex_dst_val[15:0]} + {1'b0,ex_src_val[15:0]};
                                                ex_res_val = {16'd0, ex_add_h[15:0]};
                                                if (op_update_flags) begin
                                                    f_cy <= ex_add_h[16];
                                                    f_ov <= (ex_dst_val[15]==ex_src_val[15]) && (ex_res_val[15]!=ex_src_val[15]);
                                                    f_s  <= ex_res_val[15];
                                                    f_z  <= (ex_res_val[15:0]==16'd0);
                                                end
                                            end
                                            2'd2: begin                                                ex_add_w   = {1'b0,ex_dst_val} + {1'b0,ex_src_val};
                                                ex_res_val = ex_add_w[31:0];
                                                if (op_update_flags) begin
                                                    f_cy <= ex_add_w[32];
                                                    f_ov <= (ex_dst_val[31]==ex_src_val[31]) && (ex_res_val[31]!=ex_src_val[31]);
                                                    f_s  <= ex_res_val[31];
                                                    f_z  <= (ex_res_val==32'd0);
                                                end
                                            end
                                            default: ex_res_val = ex_dst_val + ex_src_val;
                                        endcase
                                        ex_do_wb = 1'b1;
                                    end
                                    ALU_SUB: begin
                                        case (ex_sz)
                                            2'd0: begin                                                ex_sub_b   = {1'b0,ex_dst_val[7:0]} - {1'b0,ex_src_val[7:0]};
                                                ex_res_val = {24'd0, ex_sub_b[7:0]};
                                                if (op_update_flags) begin
                                                    f_cy <= ex_sub_b[8];
                                                    f_ov <= (ex_dst_val[7]!=ex_src_val[7]) && (ex_res_val[7]!=ex_dst_val[7]);
                                                    f_s  <= ex_res_val[7];
                                                    f_z  <= (ex_res_val[7:0]==8'd0);
                                                end
                                            end
                                            2'd1: begin                                                ex_sub_h   = {1'b0,ex_dst_val[15:0]} - {1'b0,ex_src_val[15:0]};
                                                ex_res_val = {16'd0, ex_sub_h[15:0]};
                                                if (op_update_flags) begin
                                                    f_cy <= ex_sub_h[16];
                                                    f_ov <= (ex_dst_val[15]!=ex_src_val[15]) && (ex_res_val[15]!=ex_dst_val[15]);
                                                    f_s  <= ex_res_val[15];
                                                    f_z  <= (ex_res_val[15:0]==16'd0);
                                                end
                                            end
                                            2'd2: begin                                                ex_sub_w   = {1'b0,ex_dst_val} - {1'b0,ex_src_val};
                                                ex_res_val = ex_sub_w[31:0];
                                                if (op_update_flags) begin
                                                    f_cy <= ex_sub_w[32];
                                                    f_ov <= (ex_dst_val[31]!=ex_src_val[31]) && (ex_res_val[31]!=ex_dst_val[31]);
                                                    f_s  <= ex_res_val[31];
                                                    f_z  <= (ex_res_val==32'd0);
                                                end
                                            end
                                            default: ex_res_val = ex_dst_val - ex_src_val;
                                        endcase
                                        ex_do_wb = 1'b1;
                                    end
                                    ALU_CMP: begin  // CMP — flags only, no writeback
                                        case (ex_sz)
                                            2'd0: begin                                                ex_cmp_b = {1'b0,ex_dst_val[7:0]} - {1'b0,ex_src_val[7:0]};
                                                if (op_update_flags) begin
                                                    f_cy <= ex_cmp_b[8];
                                                    f_ov <= (ex_dst_val[7]!=ex_src_val[7]) && (ex_cmp_b[7]!=ex_dst_val[7]);
                                                    f_s  <= ex_cmp_b[7];
                                                    f_z  <= (ex_cmp_b[7:0]==8'd0);
                                                end
                                            end
                                            2'd1: begin                                                ex_cmp_h = {1'b0,ex_dst_val[15:0]} - {1'b0,ex_src_val[15:0]};
                                                if (op_update_flags) begin
                                                    f_cy <= ex_cmp_h[16];
                                                    f_ov <= (ex_dst_val[15]!=ex_src_val[15]) && (ex_cmp_h[15]!=ex_dst_val[15]);
                                                    f_s  <= ex_cmp_h[15];
                                                    f_z  <= (ex_cmp_h[15:0]==16'd0);
                                                end
                                            end
                                            2'd2: begin                                                ex_cmp_w = {1'b0,ex_dst_val} - {1'b0,ex_src_val};
                                                if (op_update_flags) begin
                                                    f_cy <= ex_cmp_w[32];
                                                    f_ov <= (ex_dst_val[31]!=ex_src_val[31]) && (ex_cmp_w[31]!=ex_dst_val[31]);
                                                    f_s  <= ex_cmp_w[31];
                                                    f_z  <= (ex_cmp_w[31:0]==32'd0);
                                                end
                                            end
                                            default:;
                                        endcase
                                        ex_do_wb = 1'b0;
                                    end
                                    ALU_AND: begin
                                        case (ex_sz)
                                            2'd0: ex_res_val = {24'd0, ex_dst_val[7:0]  & ex_src_val[7:0]};
                                            2'd1: ex_res_val = {16'd0, ex_dst_val[15:0] & ex_src_val[15:0]};
                                            2'd2: ex_res_val = ex_dst_val & ex_src_val;
                                            default: ex_res_val = ex_dst_val & ex_src_val;
                                        endcase
                                        if (op_update_flags) begin
                                            f_ov <= 1'b0;
                                            f_cy <= 1'b0;
                                            f_s  <= (ex_sz==2'd0) ? ex_res_val[7] : (ex_sz==2'd1) ? ex_res_val[15] : ex_res_val[31];
                                            f_z  <= (ex_sz==2'd0) ? (ex_res_val[7:0]==8'd0) :
                                                    (ex_sz==2'd1) ? (ex_res_val[15:0]==16'd0) :
                                                                 (ex_res_val==32'd0);
                                        end
                                        ex_do_wb = 1'b1;
                                    end
                                    ALU_OR: begin
                                        case (ex_sz)
                                            2'd0: ex_res_val = {24'd0, ex_dst_val[7:0]  | ex_src_val[7:0]};
                                            2'd1: ex_res_val = {16'd0, ex_dst_val[15:0] | ex_src_val[15:0]};
                                            2'd2: ex_res_val = ex_dst_val | ex_src_val;
                                            default: ex_res_val = ex_dst_val | ex_src_val;
                                        endcase
                                        if (op_update_flags) begin
                                            f_ov <= 1'b0;
                                            f_cy <= 1'b0;
                                            f_s  <= (ex_sz==2'd0) ? ex_res_val[7] : (ex_sz==2'd1) ? ex_res_val[15] : ex_res_val[31];
                                            f_z  <= (ex_sz==2'd0) ? (ex_res_val[7:0]==8'd0) :
                                                    (ex_sz==2'd1) ? (ex_res_val[15:0]==16'd0) :
                                                                 (ex_res_val==32'd0);
                                        end
                                        ex_do_wb = 1'b1;
                                    end
                                    ALU_XOR: begin
                                        case (ex_sz)
                                            2'd0: ex_res_val = {24'd0, ex_dst_val[7:0]  ^ ex_src_val[7:0]};
                                            2'd1: ex_res_val = {16'd0, ex_dst_val[15:0] ^ ex_src_val[15:0]};
                                            2'd2: ex_res_val = ex_dst_val ^ ex_src_val;
                                            default: ex_res_val = ex_dst_val ^ ex_src_val;
                                        endcase
                                        if (op_update_flags) begin
                                            f_ov <= 1'b0;
                                            f_cy <= 1'b0;
                                            f_s  <= (ex_sz==2'd0) ? ex_res_val[7] : (ex_sz==2'd1) ? ex_res_val[15] : ex_res_val[31];
                                            f_z  <= (ex_sz==2'd0) ? (ex_res_val[7:0]==8'd0) :
                                                    (ex_sz==2'd1) ? (ex_res_val[15:0]==16'd0) :
                                                                 (ex_res_val==32'd0);
                                        end
                                        ex_do_wb = 1'b1;
                                    end
                                    default: begin
                                        ex_res_val = ex_src_val;
                                        ex_do_wb   = 1'b1;
                                    end
                                endcase
                                // ---- Extended op override (MUL/DIV/SHA/SHL/SETF) ----
                                // op_alu_op=ALU_PASS for all ext ops; override result here.
                                if (op_is_ext) begin
                                    ex_do_wb = 1'b0;  // reset; each case sets it
                                    case (op_ext_op)
                                        // ---- MUL (signed) ----
                                        EXT_MUL: begin
                                                    case (ex_sz)
                                                        2'd0: begin
                                                            ex_mul64 = {{56{ex_dst_val[7]}},ex_dst_val[7:0]} *
                                                                       {{56{ex_src_val[7]}},ex_src_val[7:0]};
                                                            ex_res_val = {24'd0, ex_mul64[7:0]};
                                                            if (op_update_flags) begin
                                                                f_ov <= (ex_mul64[63:8] != {56{ex_mul64[7]}});
                                                                f_s  <= ex_res_val[7];
                                                                f_z  <= (ex_res_val[7:0]==8'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                        2'd1: begin
                                                            ex_mul64 = {{48{ex_dst_val[15]}},ex_dst_val[15:0]} *
                                                                       {{48{ex_src_val[15]}},ex_src_val[15:0]};
                                                            ex_res_val = {16'd0, ex_mul64[15:0]};
                                                            if (op_update_flags) begin
                                                                f_ov <= (ex_mul64[63:16] != {48{ex_mul64[15]}});
                                                                f_s  <= ex_res_val[15];
                                                                f_z  <= (ex_res_val[15:0]==16'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                        default: begin  // word
                                                            ex_mul64 = {{32{ex_dst_val[31]}},ex_dst_val} *
                                                                       {{32{ex_src_val[31]}},ex_src_val};
                                                            ex_res_val = ex_mul64[31:0];
                                                            if (op_update_flags) begin
                                                                f_ov <= (ex_mul64[63:32] != {32{ex_mul64[31]}});
                                                                f_s  <= ex_res_val[31];
                                                                f_z  <= (ex_res_val==32'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                    endcase
                                                    ex_do_wb = 1'b1;
                                                end
                                                // ---- MULU (unsigned) ----
                                                EXT_MULU: begin
                                                    case (ex_sz)
                                                        2'd0: begin
                                                            ex_mul64 = {56'd0,ex_dst_val[7:0]} * {56'd0,ex_src_val[7:0]};
                                                            ex_res_val = {24'd0, ex_mul64[7:0]};
                                                            if (op_update_flags) begin
                                                                f_ov <= (ex_mul64[63:8] != 56'd0);
                                                                f_s  <= ex_res_val[7];
                                                                f_z  <= (ex_res_val[7:0]==8'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                        2'd1: begin
                                                            ex_mul64 = {48'd0,ex_dst_val[15:0]} * {48'd0,ex_src_val[15:0]};
                                                            ex_res_val = {16'd0, ex_mul64[15:0]};
                                                            if (op_update_flags) begin
                                                                f_ov <= (ex_mul64[63:16] != 48'd0);
                                                                f_s  <= ex_res_val[15];
                                                                f_z  <= (ex_res_val[15:0]==16'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                        default: begin
                                                            ex_mul64 = {32'd0,ex_dst_val} * {32'd0,ex_src_val};
                                                            ex_res_val = ex_mul64[31:0];
                                                            if (op_update_flags) begin
                                                                f_ov <= (ex_mul64[63:32] != 32'd0);
                                                                f_s  <= ex_res_val[31];
                                                                f_z  <= (ex_res_val==32'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                    endcase
                                                    ex_do_wb = 1'b1;
                                                end
                                                // ---- DIV (signed) ----
                                                EXT_DIV: begin
                                                    case (ex_sz)
                                                        2'd0: begin
                                                            // OV if 0x80 / 0xFF (INT8_MIN / -1)
                                                            if ((ex_dst_val[7:0]==8'h80) && (ex_src_val[7:0]==8'hFF)) begin
                                                                ex_res_val = {24'd0, ex_dst_val[7:0]};  // unchanged
                                                                if (op_update_flags) f_ov <= 1'b1;
                                                            end else if (ex_src_val[7:0] != 8'd0) begin
                                                                // signed divide: $signed
                                                                ex_res_val = {24'd0, ($signed(ex_dst_val[7:0]) / $signed(ex_src_val[7:0]))};
                                                                if (op_update_flags) f_ov <= 1'b0;
                                                            end else begin
                                                                ex_res_val = {24'd0, ex_dst_val[7:0]};
                                                                if (op_update_flags) f_ov <= 1'b0;
                                                            end
                                                            if (op_update_flags) begin
                                                                f_s <= ex_res_val[7];
                                                                f_z <= (ex_res_val[7:0]==8'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                        2'd1: begin
                                                            if ((ex_dst_val[15:0]==16'h8000) && (ex_src_val[15:0]==16'hFFFF)) begin
                                                                ex_res_val = {16'd0, ex_dst_val[15:0]};
                                                                if (op_update_flags) f_ov <= 1'b1;
                                                            end else if (ex_src_val[15:0] != 16'd0) begin
                                                                ex_res_val = {16'd0, ($signed(ex_dst_val[15:0]) / $signed(ex_src_val[15:0]))};
                                                                if (op_update_flags) f_ov <= 1'b0;
                                                            end else begin
                                                                ex_res_val = {16'd0, ex_dst_val[15:0]};
                                                                if (op_update_flags) f_ov <= 1'b0;
                                                            end
                                                            if (op_update_flags) begin
                                                                f_s <= ex_res_val[15];
                                                                f_z <= (ex_res_val[15:0]==16'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                        default: begin
                                                            if ((ex_dst_val==32'h80000000) && (ex_src_val==32'hFFFFFFFF)) begin
                                                                ex_res_val = ex_dst_val;
                                                                if (op_update_flags) f_ov <= 1'b1;
                                                            end else if (ex_src_val != 32'd0) begin
                                                                ex_res_val = $signed(ex_dst_val) / $signed(ex_src_val);
                                                                if (op_update_flags) f_ov <= 1'b0;
                                                            end else begin
                                                                ex_res_val = ex_dst_val;
                                                                if (op_update_flags) f_ov <= 1'b0;
                                                            end
                                                            if (op_update_flags) begin
                                                                f_s <= ex_res_val[31];
                                                                f_z <= (ex_res_val==32'd0);
                                                                f_cy <= 1'b0;
                                                            end
                                                        end
                                                    endcase
                                                    ex_do_wb = 1'b1;
                                                end
                                                // ---- DIVU (unsigned) ----
                                                EXT_DIVU: begin
                                                    case (ex_sz)
                                                        2'd0: begin
                                                            if (ex_src_val[7:0] != 8'd0)
                                                                ex_res_val = {24'd0, ex_dst_val[7:0] / ex_src_val[7:0]};
                                                            else
                                                                ex_res_val = {24'd0, ex_dst_val[7:0]};
                                                            if (op_update_flags) begin
                                                                f_ov <= 1'b0; f_cy <= 1'b0;
                                                                f_s <= ex_res_val[7];
                                                                f_z <= (ex_res_val[7:0]==8'd0);
                                                            end
                                                        end
                                                        2'd1: begin
                                                            if (ex_src_val[15:0] != 16'd0)
                                                                ex_res_val = {16'd0, ex_dst_val[15:0] / ex_src_val[15:0]};
                                                            else
                                                                ex_res_val = {16'd0, ex_dst_val[15:0]};
                                                            if (op_update_flags) begin
                                                                f_ov <= 1'b0; f_cy <= 1'b0;
                                                                f_s <= ex_res_val[15];
                                                                f_z <= (ex_res_val[15:0]==16'd0);
                                                            end
                                                        end
                                                        default: begin
                                                            if (ex_src_val != 32'd0)
                                                                ex_res_val = ex_dst_val / ex_src_val;
                                                            else
                                                                ex_res_val = ex_dst_val;
                                                            if (op_update_flags) begin
                                                                f_ov <= 1'b0; f_cy <= 1'b0;
                                                                f_s <= ex_res_val[31];
                                                                f_z <= (ex_res_val==32'd0);
                                                            end
                                                        end
                                                    endcase
                                                    ex_do_wb = 1'b1;
                                                end
                                                // ---- SHL (logical shift, signed count) ----
                                                // Positive count = left shift; negative = right shift (logical)
                                                // OV always 0; CY = last bit shifted out
                                                // sh_cnt/sha_cnt are module-level ex_* vars (see declarations above)
                                                EXT_SHL: begin
                                                    begin
                                                        // Use ex_mul64 as 64-bit shift temp (module-level)
                                                        logic signed [7:0] shl_cnt;
                                                        shl_cnt = $signed(ex_src_val[7:0]);
                                                        case (ex_sz)
                                                            2'd0: begin
                                                                if (shl_cnt == 0) begin
                                                                    ex_res_val = {24'd0, ex_dst_val[7:0]};
                                                                    if (op_update_flags) begin f_cy<=1'b0; f_ov<=1'b0; end
                                                                end else if (shl_cnt > 0) begin
                                                                    ex_mul64 = {56'd0, ex_dst_val[7:0]} << shl_cnt;
                                                                    ex_res_val = {24'd0, ex_mul64[7:0]};
                                                                    if (op_update_flags) begin
                                                                        f_cy <= (shl_cnt<=8) ? ex_mul64[8] : 1'b0;
                                                                        f_ov <= 1'b0;
                                                                    end
                                                                end else begin
                                                                    // Right logical shift: shift by -shl_cnt
                                                                    ex_mul64 = {56'd0, ex_dst_val[7:0]} >> (-shl_cnt);
                                                                    ex_res_val = {24'd0, ex_mul64[7:0]};
                                                                    // CY = last bit shifted out = bit at position (-shl_cnt-1)
                                                                    ex_div_quotient = {24'd0, ex_dst_val[7:0]} >> (-shl_cnt - 1);
                                                                    if (op_update_flags) begin f_cy <= ex_div_quotient[0]; f_ov <= 1'b0; end
                                                                end
                                                                if (op_update_flags) begin
                                                                    f_s <= ex_res_val[7];
                                                                    f_z <= (ex_res_val[7:0]==8'd0);
                                                                end
                                                            end
                                                            2'd1: begin
                                                                if (shl_cnt == 0) begin
                                                                    ex_res_val = {16'd0, ex_dst_val[15:0]};
                                                                    if (op_update_flags) begin f_cy<=1'b0; f_ov<=1'b0; end
                                                                end else if (shl_cnt > 0) begin
                                                                    ex_mul64 = {48'd0, ex_dst_val[15:0]} << shl_cnt;
                                                                    ex_res_val = {16'd0, ex_mul64[15:0]};
                                                                    if (op_update_flags) begin
                                                                        f_cy <= (shl_cnt<=16) ? ex_mul64[16] : 1'b0;
                                                                        f_ov <= 1'b0;
                                                                    end
                                                                end else begin
                                                                    ex_mul64 = {48'd0, ex_dst_val[15:0]} >> (-shl_cnt);
                                                                    ex_res_val = {16'd0, ex_mul64[15:0]};
                                                                    ex_div_quotient = {16'd0, ex_dst_val[15:0]} >> (-shl_cnt - 1);
                                                                    if (op_update_flags) begin f_cy <= ex_div_quotient[0]; f_ov <= 1'b0; end
                                                                end
                                                                if (op_update_flags) begin
                                                                    f_s <= ex_res_val[15];
                                                                    f_z <= (ex_res_val[15:0]==16'd0);
                                                                end
                                                            end
                                                            default: begin  // word
                                                                if (shl_cnt == 0) begin
                                                                    ex_res_val = ex_dst_val;
                                                                    if (op_update_flags) begin f_cy<=1'b0; f_ov<=1'b0; end
                                                                end else if (shl_cnt > 0) begin
                                                                    ex_mul64 = {32'd0, ex_dst_val} << shl_cnt;
                                                                    ex_res_val = ex_mul64[31:0];
                                                                    if (op_update_flags) begin
                                                                        f_cy <= (shl_cnt<=32) ? ex_mul64[32] : 1'b0;
                                                                        f_ov <= 1'b0;
                                                                    end
                                                                end else begin
                                                                    ex_mul64 = {32'd0, ex_dst_val} >> (-shl_cnt);
                                                                    ex_res_val = ex_mul64[31:0];
                                                                    ex_div_quotient = ex_dst_val >> (-shl_cnt - 1);
                                                                    if (op_update_flags) begin f_cy <= ex_div_quotient[0]; f_ov <= 1'b0; end
                                                                end
                                                                if (op_update_flags) begin
                                                                    f_s <= ex_res_val[31];
                                                                    f_z <= (ex_res_val==32'd0);
                                                                end
                                                            end
                                                        endcase
                                                        ex_do_wb = 1'b1;
                                                    end
                                                end
                                                // ---- SHA (arithmetic shift, signed count) ----
                                                // Positive = left (OV if sign bit changes), negative = right (sign-extend)
                                                EXT_SHA: begin
                                                    begin
                                                        logic signed [7:0] sha_cnt;
                                                        sha_cnt = $signed(ex_src_val[7:0]);
                                                        case (ex_sz)
                                                            2'd0: begin
                                                                if (sha_cnt == 0) begin
                                                                    ex_res_val = {24'd0, ex_dst_val[7:0]};
                                                                    if (op_update_flags) begin f_cy<=1'b0; f_ov<=1'b0; end
                                                                end else if (sha_cnt > 0) begin
                                                                    ex_mul64 = {56'd0, ex_dst_val[7:0]} << sha_cnt;
                                                                    ex_res_val = {24'd0, ex_mul64[7:0]};
                                                                    if (op_update_flags) begin
                                                                        f_cy <= (sha_cnt<=8) ? ex_mul64[8] : 1'b0;
                                                                        f_ov <= (ex_dst_val[7] != ex_mul64[7]);
                                                                    end
                                                                end else begin
                                                                    // Right arithmetic: sign-extend then shift
                                                                    ex_mul64 = {{56{ex_dst_val[7]}}, ex_dst_val[7:0]} >> (-sha_cnt);
                                                                    ex_res_val = {24'd0, ex_mul64[7:0]};
                                                                    ex_div_quotient = {{24{ex_dst_val[7]}}, ex_dst_val[7:0]} >> (-sha_cnt - 1);
                                                                    if (op_update_flags) begin f_cy <= ex_div_quotient[0]; f_ov <= 1'b0; end
                                                                end
                                                                if (op_update_flags) begin
                                                                    f_s <= ex_res_val[7];
                                                                    f_z <= (ex_res_val[7:0]==8'd0);
                                                                end
                                                            end
                                                            2'd1: begin
                                                                if (sha_cnt == 0) begin
                                                                    ex_res_val = {16'd0, ex_dst_val[15:0]};
                                                                    if (op_update_flags) begin f_cy<=1'b0; f_ov<=1'b0; end
                                                                end else if (sha_cnt > 0) begin
                                                                    ex_mul64 = {48'd0, ex_dst_val[15:0]} << sha_cnt;
                                                                    ex_res_val = {16'd0, ex_mul64[15:0]};
                                                                    if (op_update_flags) begin
                                                                        f_cy <= (sha_cnt<=16) ? ex_mul64[16] : 1'b0;
                                                                        f_ov <= (ex_dst_val[15] != ex_mul64[15]);
                                                                    end
                                                                end else begin
                                                                    ex_mul64 = {{48{ex_dst_val[15]}}, ex_dst_val[15:0]} >> (-sha_cnt);
                                                                    ex_res_val = {16'd0, ex_mul64[15:0]};
                                                                    ex_div_quotient = {{16{ex_dst_val[15]}}, ex_dst_val[15:0]} >> (-sha_cnt - 1);
                                                                    if (op_update_flags) begin f_cy <= ex_div_quotient[0]; f_ov <= 1'b0; end
                                                                end
                                                                if (op_update_flags) begin
                                                                    f_s <= ex_res_val[15];
                                                                    f_z <= (ex_res_val[15:0]==16'd0);
                                                                end
                                                            end
                                                            default: begin
                                                                if (sha_cnt == 0) begin
                                                                    ex_res_val = ex_dst_val;
                                                                    if (op_update_flags) begin f_cy<=1'b0; f_ov<=1'b0; end
                                                                end else if (sha_cnt > 0) begin
                                                                    ex_mul64 = {32'd0, ex_dst_val} << sha_cnt;
                                                                    ex_res_val = ex_mul64[31:0];
                                                                    if (op_update_flags) begin
                                                                        f_cy <= (sha_cnt<=32) ? ex_mul64[32] : 1'b0;
                                                                        f_ov <= (ex_dst_val[31] != ex_mul64[31]);
                                                                    end
                                                                end else begin
                                                                    ex_mul64 = {{32{ex_dst_val[31]}}, ex_dst_val} >> (-sha_cnt);
                                                                    ex_res_val = ex_mul64[31:0];
                                                                    ex_div_quotient = $signed(ex_dst_val) >> (-sha_cnt - 1);
                                                                    if (op_update_flags) begin f_cy <= ex_div_quotient[0]; f_ov <= 1'b0; end
                                                                end
                                                                if (op_update_flags) begin
                                                                    f_s <= ex_res_val[31];
                                                                    f_z <= (ex_res_val==32'd0);
                                                                end
                                                            end
                                                        endcase
                                                        ex_do_wb = 1'b1;
                                                    end
                                                end
                                                // ---- ROT: rotate by signed count ----
                                                // op1 = signed 8-bit count (+left, -right)
                                                // op2 = value to rotate (R/W by op_size)
                                                // +count: rotate left (MSB→LSB→bit0)
                                                // -count: rotate right (LSB→MSB)
                                                EXT_ROT: begin
                                                    begin
                                                        // rot_raw: unsigned count, rot_left: direction
                                                        logic [7:0] rot_raw_u;
                                                        logic       rot_left;
                                                        logic [31:0] rot_val, rot_res;
                                                        logic [4:0]  rot_n5;
                                                        rot_raw_u = ex_src_val[7:0];
                                                        // Negative (bit7=1) → right rotation
                                                        rot_left  = !rot_raw_u[7];
                                                        // Absolute count
                                                        rot_n5 = rot_left ? rot_raw_u[4:0] :
                                                                 (~rot_raw_u[4:0] + 5'd1);
                                                        rot_val = ex_dst_val;
                                                        rot_res = ex_dst_val;
                                                        f_cy <= 1'b0; f_ov <= 1'b0;
                                                        if (rot_raw_u != 8'd0) begin
                                                            case (op_size)
                                                                2'd0: begin  // byte 8-bit
                                                                    begin
                                                                        logic [2:0] rn3;
                                                                        rn3 = rot_n5[2:0];
                                                                        if (rot_left) begin
                                                                            rot_res[7:0] = (rot_val[7:0] << rn3) | (rot_val[7:0] >> (8-rn3));
                                                                            f_cy <= rot_res[0];
                                                                        end else begin
                                                                            rot_res[7:0] = (rot_val[7:0] >> rn3) | (rot_val[7:0] << (8-rn3));
                                                                            f_cy <= rot_res[7];
                                                                        end
                                                                    end
                                                                    f_s  <= rot_res[7];
                                                                    f_z  <= (rot_res[7:0] == 8'd0);
                                                                    ex_res_val = {24'd0, rot_res[7:0]};
                                                                end
                                                                2'd1: begin  // halfword 16-bit
                                                                    begin
                                                                        logic [3:0] rn4;
                                                                        rn4 = rot_n5[3:0];
                                                                        if (rot_left) begin
                                                                            rot_res[15:0] = (rot_val[15:0] << rn4) | (rot_val[15:0] >> (16-rn4));
                                                                            f_cy <= rot_res[0];
                                                                        end else begin
                                                                            rot_res[15:0] = (rot_val[15:0] >> rn4) | (rot_val[15:0] << (16-rn4));
                                                                            f_cy <= rot_res[15];
                                                                        end
                                                                    end
                                                                    f_s  <= rot_res[15];
                                                                    f_z  <= (rot_res[15:0] == 16'd0);
                                                                    ex_res_val = {16'd0, rot_res[15:0]};
                                                                end
                                                                default: begin  // word 32-bit
                                                                    if (rot_left) begin
                                                                        rot_res = (rot_val << rot_n5) | (rot_val >> (32-rot_n5));
                                                                        f_cy <= rot_res[0];
                                                                    end else begin
                                                                        rot_res = (rot_val >> rot_n5) | (rot_val << (32-rot_n5));
                                                                        f_cy <= rot_res[31];
                                                                    end
                                                                    f_s  <= rot_res[31];
                                                                    f_z  <= (rot_res == 32'd0);
                                                                    ex_res_val = rot_res;
                                                                end
                                                            endcase
                                                        end
                                                        ex_do_wb = 1'b1;
                                                    end
                                                end
                                                // ---- SETF: set byte from condition code ----
                                                // op1 = condition code (0-15)
                                                // op2 = destination (byte written with 0 or 1)
                                                EXT_SETF: begin
                                                    begin
                                                        logic [3:0] setf_cc;
                                                        logic       setf_val;
                                                        setf_cc = ex_src_val[3:0];
                                                        case (setf_cc)
                                                            4'd0:  setf_val = f_ov;
                                                            4'd1:  setf_val = ~f_ov;
                                                            4'd2:  setf_val = f_cy;
                                                            4'd3:  setf_val = ~f_cy;
                                                            4'd4:  setf_val = f_z;
                                                            4'd5:  setf_val = ~f_z;
                                                            4'd6:  setf_val = f_cy | f_z;
                                                            4'd7:  setf_val = ~(f_cy | f_z);
                                                            4'd8:  setf_val = f_s;
                                                            4'd9:  setf_val = ~f_s;
                                                            4'd10: setf_val = 1'b1;
                                                            4'd11: setf_val = 1'b0;
                                                            4'd12: setf_val = f_s ^ f_ov;
                                                            4'd13: setf_val = ~(f_s ^ f_ov);
                                                            4'd14: setf_val = (f_s ^ f_ov) | f_z;
                                                            4'd15: setf_val = ~((f_s ^ f_ov) | f_z);
                                                            default: setf_val = 1'b0;
                                                        endcase
                                                        ex_res_val = {31'd0, setf_val};
                                                        ex_do_wb = 1'b1;
                                                    end
                                                end
                                        // ---- LDPR: load privileged register ----
                                        // MAME: F12DecodeOperands(ReadAMAddress,2, ReadAM,2)
                                        //   op1 (src, F12 op1): source value (or address if flag1=0)
                                        //   op2 (dst, F12 op2): privileged register index (0..28)
                                        //   reg_file[op2_value + 36] = src_value
                                        //
                                        // In our F1/F2 pipeline:
                                        //   ex_src_val = value from AM1 (source operand)
                                        //   ex_dst_val = value from AM2 (priv reg index)
                                        //   ex_am2_addr = AM2 register index or address
                                        //   ex_is_reg2  = 1 if AM2 is register direct
                                        //
                                        // For ImmediateQuick dest (common case): ex_is_imm2=1,
                                        //   ex_am2_addr = immediate value = priv reg index
                                        // We write: reg_file[priv_idx + 36] = ex_src_val
                                        EXT_LDPR: begin
                                            begin
                                                logic [5:0] ldpr_idx;
                                                // Priv reg index from AM2 value
                                                // If AM2 was immediate: ex_am2_addr holds the value
                                                // If AM2 was register: ex_dst_val holds the value
                                                ldpr_idx = ex_is_imm2 ? ex_am2_addr[5:0] :
                                                           ex_is_reg2 ? ex_dst_val[5:0] :
                                                                        ex_dst_val[5:0];
                                                if (ldpr_idx <= 6'd28) begin
                                                    // Write to privileged register
                                                    // (LDPR special: src is from F12 op1 via ReadAMAddress)
                                                    // ex_src_val holds the source value
                                                    reg_file[ldpr_idx + 6'd36] <= ex_src_val;
                                                end
                                                // LDPR does not write to op2, so suppress normal wb
                                                ex_do_wb = 1'b0;
                                            end
                                        end

                                        // ---- STPR: store privileged register ----
                                        // MAME: F12DecodeFirstOperand(ReadAM,2) + F12WriteSecondOperand(2)
                                        //   op1 = priv reg index (0..28) → source = reg_file[op1+36]
                                        //   op2 = destination address/register
                                        EXT_STPR: begin
                                            begin
                                                logic [5:0] stpr_idx;
                                                stpr_idx = ex_is_imm1 ? ex_am1_addr[5:0] :
                                                           ex_is_reg1 ? ex_am1_addr[5:0] :
                                                                        ex_src_val[5:0];
                                                if (stpr_idx <= 6'd28)
                                                    ex_res_val = reg_file[stpr_idx + 6'd36];
                                                else
                                                    ex_res_val = 32'd0;
                                                ex_do_wb = 1'b1;
                                            end
                                        end

                                        // ---- MOVZHW: zero-extend halfword to word ----
                                        // Source was read as 16-bit; write 32-bit zero-extended
                                        EXT_MOVZHW: begin
                                            ex_res_val = {16'd0, ex_src_val[15:0]};
                                            ex_sz      = 2'd2;  // write as 32-bit
                                            ex_do_wb   = 1'b1;
                                        end

                                        // ---- MOVSHW: sign-extend halfword to word ----
                                        EXT_MOVSHW: begin
                                            ex_res_val = {{16{ex_src_val[15]}}, ex_src_val[15:0]};
                                            ex_sz      = 2'd2;  // write as 32-bit
                                            ex_do_wb   = 1'b1;
                                        end

                                        // ---- MOVZBW: zero-extend byte to word ----
                                        EXT_MOVZBW: begin
                                            ex_res_val = {24'd0, ex_src_val[7:0]};
                                            ex_sz      = 2'd2;  // write as 32-bit
                                            ex_do_wb   = 1'b1;
                                        end

                                        // ---- MOVSBW: sign-extend byte to word ----
                                        EXT_MOVSBW: begin
                                            ex_res_val = {{24{ex_src_val[7]}}, ex_src_val[7:0]};
                                            ex_sz      = 2'd2;  // write as 32-bit
                                            ex_do_wb   = 1'b1;
                                        end

                                        // ---- MOVZBH: zero-extend byte to halfword ----
                                        EXT_MOVZBH: begin
                                            ex_res_val = {16'd0, ex_src_val[7:0]};
                                            ex_sz      = 2'd1;  // write as 16-bit
                                            ex_do_wb   = 1'b1;
                                        end

                                        // ---- MOVSBH: sign-extend byte to halfword ----
                                        EXT_MOVSBH: begin
                                            ex_res_val = {{16{ex_src_val[7]}}, ex_src_val[7:0]};
                                            ex_sz      = 2'd1;  // write as 16-bit
                                            ex_do_wb   = 1'b1;
                                        end

                                        // ---- RVBIT: reverse bit order of byte ----
                                        // bitswap(b, 0,1,2,3,4,5,6,7) = mirror bit positions
                                        EXT_RVBIT: begin
                                            begin
                                                logic [7:0] rv_in;
                                                rv_in = ex_src_val[7:0];
                                                ex_res_val = {24'd0,
                                                    rv_in[0], rv_in[1], rv_in[2], rv_in[3],
                                                    rv_in[4], rv_in[5], rv_in[6], rv_in[7]};
                                            end
                                            ex_sz    = 2'd0;  // write as byte
                                            ex_do_wb = 1'b1;
                                        end

                                        // ---- RVBYT: reverse byte order of 32-bit word ----
                                        // swapendian_int32: {b0,b1,b2,b3} → {b3,b2,b1,b0}
                                        EXT_RVBYT: begin
                                            ex_res_val = {ex_src_val[7:0],
                                                          ex_src_val[15:8],
                                                          ex_src_val[23:16],
                                                          ex_src_val[31:24]};
                                            ex_sz    = 2'd2;  // write as word
                                            ex_do_wb = 1'b1;
                                        end

                                        // ---- TEST1: test bit op1 of word op2 ----
                                        // CY = (op2 >> (op1 & 0x1F)) & 1
                                        // Z  = !CY
                                        // No writeback.
                                        EXT_TEST1: begin
                                            begin
                                                logic        t1_cy;
                                                logic [4:0]  t1_bit;
                                                t1_bit = ex_src_val[4:0];  // op1 = bit index
                                                t1_cy  = ex_dst_val[t1_bit];  // op2 = word to test
                                                f_cy <= t1_cy;
                                                f_z  <= ~t1_cy;
                                                f_s  <= 1'b0;
                                                f_ov <= 1'b0;
                                            end
                                            ex_do_wb = 1'b0;  // no writeback
                                        end

                                        default: begin
                                            ex_res_val = ex_src_val;
                                            ex_do_wb   = 1'b1;
                                        end
                                    endcase
                                end  // if (op_is_ext)

                                // Write result back to op2
                                if (ex_do_wb) begin
                                    if (ex_is_reg2) begin
                                        case (ex_sz)
                                            2'd0: reg_file[ex_am2_addr[4:0]] <=
                                                    (reg_file[ex_am2_addr[4:0]] & 32'hFFFFFF00) | {24'd0, ex_res_val[7:0]};
                                            2'd1: reg_file[ex_am2_addr[4:0]] <=
                                                    (reg_file[ex_am2_addr[4:0]] & 32'hFFFF0000) | {16'd0, ex_res_val[15:0]};
                                            2'd2: reg_file[ex_am2_addr[4:0]] <= ex_res_val;
                                            default: reg_file[ex_am2_addr[4:0]] <= ex_res_val;
                                        endcase
                                        reg_file[32] <= ex_instr_pc + ex_total_len;
                                        state <= S_FETCH0;
                                    end else begin
                                        // Write to memory
                                        result_val     <= ex_res_val;
                                        op2_addr       <= ex_am2_addr;
                                        writeback_size <= ex_sz;
                                        instr_len      <= ex_total_len[4:0];
                                        state          <= S_MEM_WRITE;
                                    end
                                end else begin
                                    // No writeback (CMP etc.)
                                    reg_file[32] <= ex_instr_pc + ex_total_len;
                                    state <= S_FETCH0;
                                end

                                // Handle auto-increment/decrement side effects.
                                //
                                // Three instruction formats reach here:
                                //   1. F1 single-AM D=0: !ex_iflags[7] && !ex_iflags[5]
                                //      AM at ibuf[2], modm=ex_iflags[6]
                                //   2. F1 single-AM D=1: !ex_iflags[7] && ex_iflags[5]
                                //      AM at ibuf[2], modm=ex_iflags[6]
                                //   3. F1 two-AM:        ex_iflags[7]=1
                                //      AM1 at ibuf[2], modm1=ex_iflags[6]
                                //      AM2 at ibuf[2+am1_len], modm2=ex_iflags[5]
                                //
                                // modm=1 group4 (ibuf[?][7:5]=100) = Autoincrement [Rn++]
                                // modm=1 group5 (ibuf[?][7:5]=101) = Autodecrement [--Rn]
                                // decode_am returns the pre-decremented EA for autodecrement;
                                // here we commit the register update.
                                begin
                                    logic [7:0] ai_byte1, ai_byte2;
                                    logic       ai_modm1, ai_modm2;
                                    logic       ai_has2;
                                    logic [4:0] ai_am2_offset;
                                    // Determine AM bytes and their modm bits
                                    if (ex_iflags[7]) begin
                                        // F1 two-AM format: AM1 at ibuf[2], AM2 at ibuf[2+am1_len]
                                        ai_byte1    = ibuf[2];
                                        ai_modm1    = ex_iflags[6];
                                        ai_am2_offset = 5'd2 + ex_am1_len[4:0];
                                        ai_byte2    = ibuf[ai_am2_offset];
                                        ai_modm2    = ex_iflags[5];
                                        ai_has2     = 1'b1;
                                    end else begin
                                        // F1 single-AM: AM at ibuf[2], modm=ex_iflags[6]
                                        ai_byte1    = ibuf[2];
                                        ai_modm1    = ex_iflags[6];
                                        ai_byte2    = 8'd0;
                                        ai_modm2    = 1'b0;
                                        ai_has2     = 1'b0;
                                    end
                                    // Apply auto-increment/decrement for AM1
                                    if (ai_modm1) begin
                                        if (ai_byte1[7:5] == 3'b100) begin  // Autoincrement [Rn++]
                                            case (ex_sz)
                                                2'd0: reg_file[ai_byte1[4:0]] <= reg_file[ai_byte1[4:0]] + 32'd1;
                                                2'd1: reg_file[ai_byte1[4:0]] <= reg_file[ai_byte1[4:0]] + 32'd2;
                                                2'd2: reg_file[ai_byte1[4:0]] <= reg_file[ai_byte1[4:0]] + 32'd4;
                                                default:;
                                            endcase
                                        end else if (ai_byte1[7:5] == 3'b101) begin  // Autodecrement [--Rn]
                                            case (ex_sz)
                                                2'd0: reg_file[ai_byte1[4:0]] <= reg_file[ai_byte1[4:0]] - 32'd1;
                                                2'd1: reg_file[ai_byte1[4:0]] <= reg_file[ai_byte1[4:0]] - 32'd2;
                                                2'd2: reg_file[ai_byte1[4:0]] <= reg_file[ai_byte1[4:0]] - 32'd4;
                                                default:;
                                            endcase
                                        end
                                    end
                                    // Apply auto-increment/decrement for AM2 (F1 two-AM only)
                                    if (ai_has2 && ai_modm2) begin
                                        if (ai_byte2[7:5] == 3'b100) begin  // Autoincrement [Rn++]
                                            case (ex_sz)
                                                2'd0: reg_file[ai_byte2[4:0]] <= reg_file[ai_byte2[4:0]] + 32'd1;
                                                2'd1: reg_file[ai_byte2[4:0]] <= reg_file[ai_byte2[4:0]] + 32'd2;
                                                2'd2: reg_file[ai_byte2[4:0]] <= reg_file[ai_byte2[4:0]] + 32'd4;
                                                default:;
                                            endcase
                                        end else if (ai_byte2[7:5] == 3'b101) begin  // Autodecrement [--Rn]
                                            case (ex_sz)
                                                2'd0: reg_file[ai_byte2[4:0]] <= reg_file[ai_byte2[4:0]] - 32'd1;
                                                2'd1: reg_file[ai_byte2[4:0]] <= reg_file[ai_byte2[4:0]] - 32'd2;
                                                2'd2: reg_file[ai_byte2[4:0]] <= reg_file[ai_byte2[4:0]] - 32'd4;
                                                default:;
                                            endcase
                                        end
                                    end
                                end
                            end  // if ex_is_reg1
                        end  // two-operand
                    end  // begin block
                end  // S_EXECUTE

                // ============================================================
                // S_MEM_READ: read from memory (1, 2, or 4 bytes)
                // For 32-bit reads: two 16-bit bus cycles
                // ============================================================
                S_MEM_READ: begin
                    bus_addr_r <= mem_target_addr[23:0];
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    mem_second_cycle <= 1'b0;
                    state      <= S_MEM_READ_WAIT;
                end

                S_MEM_READ_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        case (mem_access_size)
                            2'd0: begin  // byte
                                if (mem_target_addr[0])
                                    mem_read_result <= {24'd0, data_i[15:8]};
                                else
                                    mem_read_result <= {24'd0, data_i[7:0]};
                                mem_loaded <= 1'b1;
                                state <= S_EXECUTE;
                            end
                            2'd1: begin  // halfword
                                mem_read_result <= {16'd0, data_i[15:0]};
                                mem_loaded <= 1'b1;
                                state <= S_EXECUTE;
                            end
                            2'd2: begin  // word — need hi half
                                mem_lo_half <= data_i;
                                state       <= S_MEM_READ_HI;
                            end
                            default:;
                        endcase
                    end
                end

                S_MEM_READ_HI: begin
                    // Issue hi-halfword read from mem_target_addr + 2
                    bus_addr_r <= mem_target_addr[23:0] + 24'd2;
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_MEM_READ_HI_WAIT;
                end

                S_MEM_READ_HI_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r        <= 1'b1;
                        bus_ds_r        <= 2'b11;
                        mem_read_result <= {data_i, mem_lo_half};
                        mem_loaded      <= 1'b1;
                        state           <= S_EXECUTE;
                    end
                end

                // ============================================================
                // S_MEM_WRITE: write result to memory
                // ============================================================
                S_MEM_WRITE: begin
                    bus_addr_r <= op2_addr[23:0];
                    bus_rw_r   <= 1'b0;   // write
                    bus_as_r   <= 1'b0;
                    mem_second_cycle <= 1'b0;

                    case (writeback_size)
                        2'd0: begin  // byte
                            if (op2_addr[0]) begin
                                bus_data_out_r <= {result_val[7:0], 8'h00};
                                bus_ds_r       <= 2'b01;   // hi byte only
                            end else begin
                                bus_data_out_r <= {8'h00, result_val[7:0]};
                                bus_ds_r       <= 2'b10;   // lo byte only
                            end
                        end
                        2'd1: begin  // halfword
                            bus_data_out_r <= result_val[15:0];
                            bus_ds_r       <= 2'b00;   // both bytes
                        end
                        2'd2: begin  // word (lo half first)
                            bus_data_out_r <= result_val[15:0];
                            bus_ds_r       <= 2'b00;
                        end
                        default:;
                    endcase
                    state <= S_MEM_WRITE_WAIT;
                end

                S_MEM_WRITE_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        if (writeback_size == 2'd2) begin
                            state <= S_MEM_WRITE_HI;
                        end else begin
                            // Done writing — advance PC and fetch next
                            reg_file[32] <= reg_file[32] + {27'd0, instr_len};
                            state <= S_FETCH0;
                        end
                    end
                end

                S_MEM_WRITE_HI: begin
                    // Latch hi-word data and assert strobe
                    bus_addr_r     <= op2_addr[23:0] + 24'd2;
                    bus_data_out_r <= result_val[31:16];
                    bus_ds_r       <= 2'b00;
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    state          <= S_MEM_WRITE_HI_WAIT;
                end

                S_MEM_WRITE_HI_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        reg_file[32] <= reg_file[32] + {27'd0, instr_len};
                        state <= S_FETCH0;
                    end
                end

                // ============================================================
                // S_HALT: wait for interrupt
                // In MAME, opHALT returns 1 (advances PC by 1) rather than
                // actually stopping the CPU. The real hardware HALT suspends
                // execution until an interrupt fires. For simulation:
                //   - When PSW.IS=1 (inside interrupt handler), treat as NOP
                //     (advance PC+1 and continue) — MAME behavior.
                //   - When PSW.IS=0 (main program), wait for actual interrupt.
                // ============================================================
                S_HALT: begin
                    if (reg_file[33][28]) begin
                        // PSW.IS=1: inside interrupt handler — HALT is NOP (MAME behavior)
                        dbg_halted_r <= 1'b0;
                        reg_file[32] <= reg_file[32] + 32'd1;
                        state        <= S_FETCH0;
                    end else if (!irq_n && (reg_file[33][18])) begin
                        // Maskable interrupt with IE=1 — dispatch via vector table
                        // MAME: v60_do_irq(vector + 0x40)
                        // vector from irq_vector input (8-bit external vector)
                        dbg_halted_r   <= 1'b0;
                        irq_vector_num <= {1'b0, irq_vector[6:0]} + 8'h40;
                        irq_vec_addr   <= ((reg_file[41] & 32'hFFFFF000) +
                                          ({24'd0, {1'b0, irq_vector[6:0]}} + 32'h40) * 4);
                        irq_old_psw    <= reg_file[33];
                        state          <= S_IRQ_PSW_PUSH;
                    end else if (!reg_file[33][18]) begin
                        // PSW.IE=0: interrupts disabled — HALT is NOP (MAME behavior).
                        // Real V60 would wait indefinitely, but MAME advances PC+1.
                        // This unblocks boot ROMs that HALT with IE=0 before enabling IRQs.
                        dbg_halted_r <= 1'b0;
                        reg_file[32] <= reg_file[32] + 32'd1;
                        state        <= S_FETCH0;
                    end else begin
                        // IE=1, no interrupt pending — signal halted, keep waiting
                        dbg_halted_r <= 1'b1;
                    end
                    if (!nmi_n) begin
                        // NMI = vector 2
                        dbg_halted_r   <= 1'b0;
                        irq_vector_num <= 8'h02;
                        irq_vec_addr   <= (reg_file[41] & 32'hFFFFF000) + 32'h08;
                        irq_old_psw    <= reg_file[33];
                        state          <= S_IRQ_PSW_PUSH;
                    end
                end

                // ============================================================
                // S_TRAP: unimplemented opcode — park here
                // ============================================================
                S_TRAP: begin
                    // Stay here until reset
                    state <= S_TRAP;
                end

                // ============================================================
                // S_PUSH_SETUP: PUSH — decrement SP, then write stk_val
                // stk_val  = value to push
                // stk_size = 0=byte,1=half,2=word
                // PC already advanced before entering this state
                // ============================================================
                S_PUSH_SETUP: begin
                    // Decrement SP
                    case (stk_size)
                        2'd0: reg_file[31] <= reg_file[31] - 32'd1;
                        2'd1: reg_file[31] <= reg_file[31] - 32'd2;
                        default: reg_file[31] <= reg_file[31] - 32'd4;
                    endcase
                    // Setup write
                    bus_rw_r <= 1'b0;   // write
                    bus_as_r <= 1'b0;
                    mem_second_cycle <= 1'b0;
                    case (stk_size)
                        2'd0: begin
                            stk_addr_tmp = reg_file[31] - 32'd1; bus_addr_r <= stk_addr_tmp[23:0];
                            bus_data_out_r <= {8'h00, stk_val[7:0]};
                            bus_ds_r       <= 2'b10;  // lo byte
                        end
                        2'd1: begin
                            stk_addr_tmp = reg_file[31] - 32'd2; bus_addr_r <= stk_addr_tmp[23:0];
                            bus_data_out_r <= stk_val[15:0];
                            bus_ds_r       <= 2'b00;
                        end
                        default: begin  // word
                            stk_addr_tmp = reg_file[31] - 32'd4; bus_addr_r <= stk_addr_tmp[23:0];
                            bus_data_out_r <= stk_val[15:0];
                            bus_ds_r       <= 2'b00;
                        end
                    endcase
                    state <= S_PUSH_LO_WAIT;
                end

                S_PUSH_LO_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        if (stk_size == 2'd2) begin
                            state <= S_PUSH_HI;
                        end else begin
                            state <= S_FETCH0;
                        end
                    end
                end

                S_PUSH_HI: begin
                    // Latch hi-word data and assert strobe
                    stk_addr_tmp   = reg_file[31] + 32'd2;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= stk_val[31:16];
                    bus_ds_r       <= 2'b00;
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    state          <= S_PUSH_HI_WAIT;
                end

                S_PUSH_HI_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        state    <= S_FETCH0;
                    end
                end

                // ============================================================
                // S_POP_SETUP: POP — read from [SP], then increment SP
                // stk_size   = size
                // stk_dst_reg = destination register index
                // PC already advanced before entering this state
                // ============================================================
                S_POP_SETUP: begin
                    bus_addr_r <= reg_file[31][23:0];
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_POP_LO_WAIT;
                end

                S_POP_LO_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        case (stk_size)
                            2'd0: begin
                                // Byte read — done
                                reg_file[stk_dst_reg] <=
                                    (reg_file[stk_dst_reg] & 32'hFFFFFF00) |
                                    {24'd0, (reg_file[31][0] ? data_i[15:8] : data_i[7:0])};
                                reg_file[31] <= reg_file[31] + 32'd1;
                                state <= S_FETCH0;
                            end
                            2'd1: begin
                                // Halfword read — done
                                reg_file[stk_dst_reg] <=
                                    (reg_file[stk_dst_reg] & 32'hFFFF0000) |
                                    {16'd0, data_i[15:0]};
                                reg_file[31] <= reg_file[31] + 32'd2;
                                state <= S_FETCH0;
                            end
                            default: begin
                                // Word lo-half read — need hi half
                                stk_lo_half <= data_i;
                                state       <= S_POP_HI;
                            end
                        endcase
                    end
                end

                S_POP_HI: begin
                    // Issue hi-halfword read from [SP+2]
                    stk_addr_tmp = reg_file[31] + 32'd2;
                    bus_addr_r   <= stk_addr_tmp[23:0];
                    bus_as_r     <= 1'b0;
                    bus_rw_r     <= 1'b1;
                    bus_ds_r     <= 2'b00;
                    state        <= S_POP_HI_WAIT;
                end

                S_POP_HI_WAIT: begin
                    if (!dtack_n) begin
                        reg_file[stk_dst_reg] <= {data_i, stk_lo_half};
                        reg_file[31]  <= reg_file[31] + 32'd4;
                        bus_as_r      <= 1'b1;
                        bus_ds_r      <= 2'b11;
                        bus_rw_r      <= 1'b1;
                        state         <= S_FETCH0;
                    end
                end

                // ============================================================
                // S_CALL_PUSH: CALL/BSR — push lo-word of return address
                // stk_ret_pc      = return address (PC + instr_len)
                // stk_jump_target = target address
                //
                // Uses 4 states to avoid NBL timing hazard:
                //   S_CALL_PUSH        : latch lo-word data, assert strobe
                //   S_CALL_PUSH_LO_WAIT: wait for lo-word dtack, then deassert
                //   S_CALL_PUSH_HI     : latch hi-word data, assert strobe
                //   S_CALL_PUSH_HI_WAIT: wait for hi-word dtack, then jump
                //
                // The one-state gap between "set bus_data_out_r" and "observe
                // dtack" ensures the registered data is stable on the bus.
                // ============================================================
                S_CALL_PUSH: begin
                    // Decrement SP by 4 (always 32-bit return addr)
                    reg_file[31] <= reg_file[31] - 32'd4;
                    // Write lo word of return addr to new [SP] (= old SP - 4)
                    stk_addr_tmp   = reg_file[31] - 32'd4;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= stk_ret_pc[15:0];
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_CALL_PUSH_LO_WAIT;
                end

                S_CALL_PUSH_LO_WAIT: begin
                    if (!dtack_n) begin
                        // Lo-word accepted — deassert bus and move to hi setup
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        state    <= S_CALL_PUSH_HI;
                    end
                end

                S_CALL_PUSH_HI: begin
                    // Latch hi-word data and assert strobe — data will be
                    // stable by the time we check dtack in the next state.
                    stk_addr_tmp   = reg_file[31] + 32'd2;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= stk_ret_pc[31:16];
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_CALL_PUSH_HI_WAIT;
                end

                S_CALL_PUSH_HI_WAIT: begin
                    if (!dtack_n) begin
                        // Hi-word accepted — deassert bus and jump to target
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        reg_file[32] <= stk_jump_target;
                        state        <= S_FETCH0;
                    end
                end

                // ============================================================
                // S_RET_POP: RET — pop PC from [SP], SP += 4
                //
                // Uses 4 states to avoid NBL timing hazard on multi-word reads:
                //   S_RET_POP        : assert strobe for lo-word read
                //   S_RET_POP_LO_WAIT: wait for lo dtack, save data, deassert
                //   S_RET_POP_HI     : assert strobe for hi-word read
                //   S_RET_POP_HI_WAIT: wait for hi dtack, restore PC
                // ============================================================
                S_RET_POP: begin
                    // Issue lo-halfword read from [SP]
                    bus_addr_r <= reg_file[31][23:0];
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_RET_POP_LO_WAIT;
                end

                S_RET_POP_LO_WAIT: begin
                    if (!dtack_n) begin
                        // Save lo-halfword, deassert bus
                        stk_lo_half <= data_i;
                        bus_as_r    <= 1'b1;
                        bus_ds_r    <= 2'b11;
                        bus_rw_r    <= 1'b1;
                        state       <= S_RET_POP_HI;
                    end
                end

                S_RET_POP_HI: begin
                    // Issue hi-halfword read from [SP+2]
                    stk_addr_tmp = reg_file[31] + 32'd2;
                    bus_addr_r   <= stk_addr_tmp[23:0];
                    bus_as_r     <= 1'b0;
                    bus_rw_r     <= 1'b1;
                    bus_ds_r     <= 2'b00;
                    state        <= S_RET_POP_HI_WAIT;
                end

                S_RET_POP_HI_WAIT: begin
                    if (!dtack_n) begin
                        // PC = {hi, lo}; SP += 4
                        reg_file[32] <= {data_i, stk_lo_half};
                        reg_file[31] <= reg_file[31] + 32'd4;
                        bus_as_r     <= 1'b1;
                        bus_ds_r     <= 2'b11;
                        bus_rw_r     <= 1'b1;
                        state        <= S_FETCH0;
                    end
                end

                // ============================================================
                // S_PREPARE_PUSH: PREPARE — push FP on stack, set FP=SP, SP-=frame_size
                // Uses same 4-state pattern as CALL to avoid NBL timing hazard
                // ============================================================
                S_PREPARE_PUSH: begin
                    // Decrement SP by 4
                    reg_file[31] <= reg_file[31] - 32'd4;
                    // Write lo-word of FP to [SP-4]
                    stk_addr_tmp   = reg_file[31] - 32'd4;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= reg_file[30][15:0];  // FP lo
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_PREPARE_PUSH_LO_WAIT;
                end

                S_PREPARE_PUSH_LO_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        state    <= S_PREPARE_PUSH_HI;
                    end
                end

                S_PREPARE_PUSH_HI: begin
                    stk_addr_tmp   = reg_file[31] + 32'd2;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= reg_file[30][31:16];  // FP hi
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_PREPARE_PUSH_HI_WAIT;
                end

                S_PREPARE_PUSH_HI_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r  <= 1'b1;
                        bus_ds_r  <= 2'b11;
                        bus_rw_r  <= 1'b1;
                        // FP = SP (new SP after decrement)
                        reg_file[30] <= reg_file[31];
                        // SP -= frame_size
                        reg_file[31] <= reg_file[31] - prep_frame_size;
                        state     <= S_FETCH0;
                    end
                end

                // ============================================================
                // PUSHM: Push Multiple Registers
                //   S_PUSHM_NEXT: find next bit in pm_mask, write lo-word
                //   S_PUSHM_LO_WAIT: wait
                //   S_PUSHM_HI: write hi-word
                //   S_PUSHM_HI_WAIT: wait, advance pm_idx
                //
                // Register order: MAME pushes PSW first (bit31), then
                //   for i=0..30: if pm_mask&(1<<(30-i)) → push reg[30-i]
                // We iterate pm_idx from 0..31:
                //   pm_idx=0: check bit 31 → PSW
                //   pm_idx=1..31: check bit (30-(pm_idx-1))=(31-pm_idx) → reg[31-pm_idx]
                // ============================================================
                S_PUSHM_NEXT: begin
                    begin
                        logic [31:0] pm_val_to_push;
                        logic        pm_bit_set;
                        logic [31:0] pm_bit_check;
                        // Determine which bit to check and which reg to push
                        if (pm_idx == 6'd0) begin
                            // Check bit 31 → PSW
                            pm_bit_check = 32'd31;
                            pm_bit_set   = pm_mask[31];
                            pm_val_to_push = {28'd0, f_cy, f_ov, f_s, f_z} |
                                            (reg_file[33] & 32'hFFFFFFF0);
                        end else begin
                            // pm_idx=1..31: bit = 31-pm_idx, reg = (31-pm_idx)
                            // bit position = 31-pm_idx (0..30 for pm_idx 1..31)
                            // reg index = bit position (same as (31-pm_idx))
                            begin
                                logic [5:0] pm_bit_pos;
                                pm_bit_pos   = 6'd31 - {1'b0, pm_idx};
                                pm_bit_check = {27'd0, pm_bit_pos[4:0]};
                                pm_bit_set   = pm_mask[pm_bit_pos[4:0]];
                                pm_val_to_push = reg_file[pm_bit_pos];
                            end
                        end

                        if (pm_idx == 6'd31 && !pm_bit_set) begin
                            // Done (last index, bit not set)
                            state <= S_FETCH0;
                        end else if (pm_idx == 6'd31 && pm_bit_set) begin
                            // Last reg to push
                            reg_file[31]   <= reg_file[31] - 32'd4;
                            stk_addr_tmp    = reg_file[31] - 32'd4;
                            bus_addr_r     <= stk_addr_tmp[23:0];
                            bus_data_out_r <= pm_val_to_push[15:0];
                            bus_as_r       <= 1'b0;
                            bus_rw_r       <= 1'b0;
                            bus_ds_r       <= 2'b00;
                            pm_reg_val     <= pm_val_to_push;
                            pm_idx         <= pm_idx + 6'd1;  // will be 32 = done sentinel
                            state          <= S_PUSHM_LO_WAIT;
                        end else if (pm_bit_set) begin
                            // Push this register: SP -= 4, write to [SP-4]
                            reg_file[31]   <= reg_file[31] - 32'd4;
                            stk_addr_tmp    = reg_file[31] - 32'd4;
                            bus_addr_r     <= stk_addr_tmp[23:0];
                            bus_data_out_r <= pm_val_to_push[15:0];
                            bus_as_r       <= 1'b0;
                            bus_rw_r       <= 1'b0;
                            bus_ds_r       <= 2'b00;
                            pm_reg_val     <= pm_val_to_push;
                            pm_idx         <= pm_idx + 6'd1;
                            state          <= S_PUSHM_LO_WAIT;
                        end else begin
                            // Bit not set — skip this register
                            pm_idx <= pm_idx + 6'd1;
                            // Stay in S_PUSHM_NEXT to check next bit
                        end
                    end
                end

                S_PUSHM_LO_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        state    <= S_PUSHM_HI;
                    end
                end

                S_PUSHM_HI: begin
                    stk_addr_tmp   = reg_file[31] + 32'd2;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= pm_reg_val[31:16];
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_PUSHM_HI_WAIT;
                end

                S_PUSHM_HI_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        // Check if done (pm_idx wrapped to 0 or exceeded 31)
                        if (pm_idx == 6'd0 || pm_idx > 6'd31) begin
                            state <= S_FETCH0;  // finished all registers
                        end else begin
                            state <= S_PUSHM_NEXT;
                        end
                    end
                end

                // ============================================================
                // POPM: Pop Multiple Registers
                //   S_POPM_NEXT: find next set bit in pm_mask (LSB first), setup read
                //   S_POPM_LO_WAIT: wait for lo-word
                //   S_POPM_HI: setup hi-word read
                //   S_POPM_HI_WAIT: wait, write to register, advance pm_idx
                //
                // MAME pops in order: R0 first (bit0), R1 (bit1), ..., R30 (bit30)
                //   then PSW (bit31, low 16 bits only merged)
                // pm_idx = 0..31, bit position = pm_idx (for regs) or 31 (for PSW)
                // ============================================================
                S_POPM_NEXT: begin
                    if (pm_idx > 6'd31) begin
                        state <= S_FETCH0;  // done
                    end else begin
                        begin
                            logic pm_bit_set;
                            pm_bit_set = pm_mask[pm_idx];
                            if (pm_bit_set) begin
                                // Read from [SP], SP will be incremented after read
                                bus_addr_r <= reg_file[31][23:0];
                                bus_as_r   <= 1'b0;
                                bus_rw_r   <= 1'b1;
                                bus_ds_r   <= 2'b00;
                                state      <= S_POPM_LO_WAIT;
                            end else begin
                                pm_idx <= pm_idx + 6'd1;
                                // Stay in S_POPM_NEXT
                            end
                        end
                    end
                end

                S_POPM_LO_WAIT: begin
                    if (!dtack_n) begin
                        pm_pop_lo <= data_i;
                        bus_as_r  <= 1'b1;
                        bus_ds_r  <= 2'b11;
                        bus_rw_r  <= 1'b1;
                        state     <= S_POPM_HI;
                    end
                end

                S_POPM_HI: begin
                    stk_addr_tmp = reg_file[31] + 32'd2;
                    bus_addr_r   <= stk_addr_tmp[23:0];
                    bus_as_r     <= 1'b0;
                    bus_rw_r     <= 1'b1;
                    bus_ds_r     <= 2'b00;
                    state        <= S_POPM_HI_WAIT;
                end

                S_POPM_HI_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        reg_file[31] <= reg_file[31] + 32'd4;
                        if (pm_idx == 6'd31) begin
                            // PSW: only merge low 16 bits
                            reg_file[33] <= (reg_file[33] & 32'hFFFF0000) |
                                            {16'd0, pm_pop_lo};
                            f_z  <= pm_pop_lo[0];
                            f_s  <= pm_pop_lo[1];
                            f_ov <= pm_pop_lo[2];
                            f_cy <= pm_pop_lo[3];
                        end else begin
                            // General register
                            reg_file[{1'b0, pm_idx}] <= {data_i, pm_pop_lo};
                        end
                        pm_idx <= pm_idx + 6'd1;
                        state  <= S_POPM_NEXT;
                    end
                end

                // ============================================================
                // RETIS: Return from Interrupt Service
                //   S_RETIS_PC_LO      : read lo-word of saved PC from [SP]
                //   S_RETIS_PC_LO_WAIT : wait, save lo-half
                //   S_RETIS_PC_HI      : read hi-word of saved PC from [SP+2]
                //   S_RETIS_PC_HI_WAIT : latch PC, SP+=4, setup PSW read
                //   S_RETIS_PSW_LO     : read lo-word of saved PSW from [SP]
                //   S_RETIS_PSW_LO_WAIT: wait, save lo-half
                //   S_RETIS_PSW_HI     : read hi-word of saved PSW from [SP+2]
                //   S_RETIS_PSW_HI_WAIT: latch PSW, SP+=4+frame_adj, FETCH0
                // ============================================================
                S_RETIS_PC_LO: begin
                    bus_addr_r <= reg_file[31][23:0];
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_RETIS_PC_LO_WAIT;
                end

                S_RETIS_PC_LO_WAIT: begin
                    if (!dtack_n) begin
                        stk_lo_half <= data_i;
                        bus_as_r    <= 1'b1;
                        bus_ds_r    <= 2'b11;
                        bus_rw_r    <= 1'b1;
                        state       <= S_RETIS_PC_HI;
                    end
                end

                S_RETIS_PC_HI: begin
                    stk_addr_tmp = reg_file[31] + 32'd2;
                    bus_addr_r   <= stk_addr_tmp[23:0];
                    bus_as_r     <= 1'b0;
                    bus_rw_r     <= 1'b1;
                    bus_ds_r     <= 2'b00;
                    state        <= S_RETIS_PC_HI_WAIT;
                end

                S_RETIS_PC_HI_WAIT: begin
                    if (!dtack_n) begin
                        // Load PC from stack, advance SP past saved PC
                        reg_file[32] <= {data_i, stk_lo_half};
                        reg_file[31] <= reg_file[31] + 32'd4;
                        bus_as_r     <= 1'b1;
                        bus_ds_r     <= 2'b11;
                        bus_rw_r     <= 1'b1;
                        state        <= S_RETIS_PSW_LO;
                    end
                end

                S_RETIS_PSW_LO: begin
                    bus_addr_r <= reg_file[31][23:0];
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_RETIS_PSW_LO_WAIT;
                end

                S_RETIS_PSW_LO_WAIT: begin
                    if (!dtack_n) begin
                        stk_lo_half <= data_i;
                        bus_as_r    <= 1'b1;
                        bus_ds_r    <= 2'b11;
                        bus_rw_r    <= 1'b1;
                        state       <= S_RETIS_PSW_HI;
                    end
                end

                S_RETIS_PSW_HI: begin
                    stk_addr_tmp = reg_file[31] + 32'd2;
                    bus_addr_r   <= stk_addr_tmp[23:0];
                    bus_as_r     <= 1'b0;
                    bus_rw_r     <= 1'b1;
                    bus_ds_r     <= 2'b00;
                    state        <= S_RETIS_PSW_HI_WAIT;
                end

                S_RETIS_PSW_HI_WAIT: begin
                    if (!dtack_n) begin
                        begin
                            logic [31:0] new_psw;
                            new_psw = {data_i, stk_lo_half};
                            // Apply PSW flags: MAME PSW[3:0] = {CY,OV,S,Z}
                            f_z  <= new_psw[0];
                            f_s  <= new_psw[1];
                            f_ov <= new_psw[2];
                            f_cy <= new_psw[3];
                            reg_file[33] <= new_psw;
                        end
                        // SP += 4 (past saved PSW) + frame_adj
                        reg_file[31] <= reg_file[31] + 32'd4 + prep_frame_size;
                        bus_as_r     <= 1'b1;
                        bus_ds_r     <= 2'b11;
                        bus_rw_r     <= 1'b1;
                        state        <= S_FETCH0;
                    end
                end

                // ============================================================
                // IRQ dispatch: update PSW, push oldPSW, push PC, read vector
                //
                // MAME v60_do_irq sequence:
                //   oldPSW = v60_update_psw_for_exception(1, 0)
                //     - clear: IE[18], TE[16], TP[27], AE[17], EM[29], EL[25:24]
                //     - set:   IS[28], ASA[31]
                //   SP -= 4; mem[SP] = oldPSW
                //   SP -= 4; mem[SP] = PC
                //   PC = mem[(SBR & ~0xFFF) + vector*4]
                //
                // Bus timing: same 4-state push pattern as CALL_PUSH
                // ============================================================
                S_IRQ_PSW_PUSH: begin
                    // Update PSW: clear IE/TE/TP/AE/EM/EL, set IS/ASA
                    begin
                        logic [31:0] new_psw;
                        new_psw = irq_old_psw;
                        new_psw[18] = 1'b0;  // IE  = 0
                        new_psw[16] = 1'b0;  // TE  = 0
                        new_psw[17] = 1'b0;  // AE  = 0
                        new_psw[27] = 1'b0;  // TP  = 0
                        new_psw[29] = 1'b0;  // EM  = 0
                        new_psw[25] = 1'b0;  // EL[1] = 0
                        new_psw[24] = 1'b0;  // EL[0] = 0
                        new_psw[28] = 1'b1;  // IS  = 1
                        new_psw[31] = 1'b1;  // ASA = 1
                        reg_file[33] <= new_psw;
                    end
                    // SP -= 4; write lo-word of irq_old_psw to [SP-4]
                    reg_file[31]   <= reg_file[31] - 32'd4;
                    stk_addr_tmp    = reg_file[31] - 32'd4;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= irq_old_psw[15:0];
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_IRQ_PSW_LO_WAIT;
                end

                S_IRQ_PSW_LO_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        state    <= S_IRQ_PSW_HI;
                    end
                end

                S_IRQ_PSW_HI: begin
                    stk_addr_tmp   = reg_file[31] + 32'd2;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= irq_old_psw[31:16];
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_IRQ_PSW_HI_WAIT;
                end

                S_IRQ_PSW_HI_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        state    <= S_IRQ_PC_PUSH;
                    end
                end

                S_IRQ_PC_PUSH: begin
                    // SP -= 4; write lo-word of PC to [SP-4]
                    reg_file[31]   <= reg_file[31] - 32'd4;
                    stk_addr_tmp    = reg_file[31] - 32'd4;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= reg_file[32][15:0];
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_IRQ_PC_LO_WAIT;
                end

                S_IRQ_PC_LO_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        state    <= S_IRQ_PC_HI;
                    end
                end

                S_IRQ_PC_HI: begin
                    stk_addr_tmp   = reg_file[31] + 32'd2;
                    bus_addr_r     <= stk_addr_tmp[23:0];
                    bus_data_out_r <= reg_file[32][31:16];
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;
                    state          <= S_IRQ_PC_HI_WAIT;
                end

                S_IRQ_PC_HI_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        state    <= S_IRQ_VEC_LO;
                    end
                end

                S_IRQ_VEC_LO: begin
                    // Read lo-word of handler address from vector table
                    bus_addr_r <= irq_vec_addr[23:0];
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;
                    state      <= S_IRQ_VEC_LO_WAIT;
                end

                S_IRQ_VEC_LO_WAIT: begin
                    if (!dtack_n) begin
                        stk_lo_half <= data_i;
                        bus_as_r    <= 1'b1;
                        bus_ds_r    <= 2'b11;
                        bus_rw_r    <= 1'b1;
                        state       <= S_IRQ_VEC_HI;
                    end
                end

                S_IRQ_VEC_HI: begin
                    stk_addr_tmp = irq_vec_addr + 32'd2;
                    bus_addr_r   <= stk_addr_tmp[23:0];
                    bus_as_r     <= 1'b0;
                    bus_rw_r     <= 1'b1;
                    bus_ds_r     <= 2'b00;
                    state        <= S_IRQ_VEC_HI_WAIT;
                end

                S_IRQ_VEC_HI_WAIT: begin
                    if (!dtack_n) begin
                        // Jump to interrupt handler
                        reg_file[32] <= {data_i, stk_lo_half};
                        bus_as_r     <= 1'b1;
                        bus_ds_r     <= 2'b11;
                        bus_rw_r     <= 1'b1;
                        state        <= S_FETCH0;
                    end
                end

                // ============================================================
                // MOVCUH: halfword block move
                //
                // State machine variables (set in S_EXECUTE):
                //   movcuh_src  = source halfword pointer (AM-decoded)
                //   movcuh_dst  = dest halfword pointer   (AM-decoded)
                //   movcuh_cnt  = element count = min(lenop1, lenop2)
                //
                // Per-element sequence:
                //   1. S_MOVCUH_RD:         read halfword from [movcuh_src]
                //   2. S_MOVCUH_RD_WAIT:    latch into movcuh_rd_data
                //   3. S_MOVCUH_WR_LO:      write movcuh_rd_data to [movcuh_dst]
                //   4. S_MOVCUH_WR_LO_WAIT: advance src/dst/cnt; loop or done
                //
                // On completion: R28 = final src addr, R27 = final dst addr.
                // ============================================================
                S_MOVCUH_RD: begin
                    // Issue halfword read from [movcuh_src]
                    bus_addr_r <= movcuh_src[23:0];
                    bus_as_r   <= 1'b0;
                    bus_rw_r   <= 1'b1;
                    bus_ds_r   <= 2'b00;    // full halfword
                    state      <= S_MOVCUH_RD_WAIT;
                end

                S_MOVCUH_RD_WAIT: begin
                    if (!dtack_n) begin
                        movcuh_rd_data <= data_i;   // latch source halfword
                        bus_as_r       <= 1'b1;
                        bus_ds_r       <= 2'b11;
                        bus_rw_r       <= 1'b1;
                        state          <= S_MOVCUH_WR_LO;
                    end
                end

                S_MOVCUH_WR_LO: begin
                    // Write halfword to [movcuh_dst]
                    bus_addr_r     <= movcuh_dst[23:0];
                    bus_data_out_r <= movcuh_rd_data;
                    bus_as_r       <= 1'b0;
                    bus_rw_r       <= 1'b0;
                    bus_ds_r       <= 2'b00;    // full halfword
                    state          <= S_MOVCUH_WR_LO_WAIT;
                end

                S_MOVCUH_WR_LO_WAIT: begin
                    if (!dtack_n) begin
                        bus_as_r <= 1'b1;
                        bus_ds_r <= 2'b11;
                        bus_rw_r <= 1'b1;
                        // Advance pointers and decrement count
                        movcuh_src <= movcuh_src + 32'd2;
                        movcuh_dst <= movcuh_dst + 32'd2;
                        movcuh_cnt <= movcuh_cnt - 32'd1;
                        // Loop check
                        if (movcuh_cnt > 32'd1) begin
                            state <= S_MOVCUH_RD;   // more elements to copy
                        end else begin
                            // Done — R28 = final src addr, R27 = final dst addr
                            reg_file[28] <= movcuh_src + 32'd2;
                            reg_file[27] <= movcuh_dst + 32'd2;
                            state <= S_FETCH0;
                        end
                    end
                end

                S_MOVCUH_WR_HI: begin
                    // Unused placeholder (halfword copy doesn't need separate hi-byte write)
                    state <= S_FETCH0;
                end

                S_MOVCUH_WR_HI_WAIT: begin
                    // Unused placeholder
                    state <= S_FETCH0;
                end

                // ============================================================
                // LDTASK: Load Task Register Set
                //
                // State sequence:
                //   TKCW_LO_WAIT → TKCW_HI → TKCW_HI_WAIT
                //     → REG_NEXT → (REG_LO_WAIT → REG_HI → REG_HI_WAIT)* → FETCH0
                //
                // ldtask_ptr tracks current memory read position.
                // pm_mask[30:0] = register restore bitmask (set by DECODE).
                // pm_idx = current register index (0..30).
                //
                // After TKCW: check SYCW bits 8-11 for L-SP reads.
                // After registers: v60ReloadStack to set SP.
                // ============================================================
                S_LDTASK_TKCW_LO_WAIT: begin
                    if (!dtack_n) begin
                        ldtask_lo <= data_i;
                        bus_as_r  <= 1'b1;
                        bus_ds_r  <= 2'b11;
                        bus_rw_r  <= 1'b1;
                        state     <= S_LDTASK_TKCW_HI;
                    end
                end

                S_LDTASK_TKCW_HI: begin
                    begin
                        logic [31:0] hi_addr;
                        hi_addr    = ldtask_ptr + 32'd2;
                        bus_addr_r <= hi_addr[23:0];
                    end
                    bus_as_r <= 1'b0;
                    bus_rw_r <= 1'b1;
                    bus_ds_r <= 2'b00;
                    state    <= S_LDTASK_TKCW_HI_WAIT;
                end

                S_LDTASK_TKCW_HI_WAIT: begin
                    if (!dtack_n) begin
                        // Store TKCW = reg_file[44]
                        reg_file[44] <= {data_i, ldtask_lo};
                        bus_as_r     <= 1'b1;
                        bus_ds_r     <= 2'b11;
                        bus_rw_r     <= 1'b1;
                        // Advance ptr past TKCW (4 bytes)
                        ldtask_ptr   <= ldtask_ptr + 32'd4;
                        // Load L-SP registers if SYCW bits 8-11 are set.
                        // SYCW = reg_file[43] (default 0x70 at reset = no L-SP bits).
                        // For simplicity: only handle L0SP (bit 8) here inline;
                        // bits 9-11 are rarely set at boot and require more states.
                        // Skip L-SP reads entirely at this time — SYCW default 0x70
                        // has none of bits 8-11 set, so no L-SP words follow TKCW.
                        // If SYCW bit 8-11 are needed, extend here with additional states.
                        // v60ReloadStack deferred to after register restore (REG_NEXT done).
                        // Begin register restore loop
                        pm_idx       <= 6'd0;
                        state        <= S_LDTASK_REG_NEXT;
                    end
                end

                S_LDTASK_REG_NEXT: begin
                    // pm_idx iterates 0..30 (R0..R30, matching op1 bits 0-30)
                    if (pm_idx > 6'd30) begin
                        // All registers done — apply v60ReloadStack and finish.
                        // v60ReloadStack: if PSW[28] set → SP = ISP (reg_file[36])
                        //                else            → SP = reg_file[37 + PSW[25:24]]
                        if (reg_file[33][28]) begin
                            reg_file[31] <= reg_file[36];  // SP = ISP (S-mode)
                        end else begin
                            // Level 0-3 → L0SP-L3SP = reg_file[37-40]
                            case (reg_file[33][25:24])
                                2'd0: reg_file[31] <= reg_file[37];  // L0SP
                                2'd1: reg_file[31] <= reg_file[38];  // L1SP
                                2'd2: reg_file[31] <= reg_file[39];  // L2SP
                                2'd3: reg_file[31] <= reg_file[40];  // L3SP
                            endcase
                        end
                        state <= S_FETCH0;
                    end else if (pm_mask[pm_idx]) begin
                        // This register needs restoring — read next 32-bit word
                        bus_addr_r <= ldtask_ptr[23:0];
                        bus_as_r   <= 1'b0;
                        bus_rw_r   <= 1'b1;
                        bus_ds_r   <= 2'b00;
                        state      <= S_LDTASK_REG_LO_WAIT;
                    end else begin
                        // Bit not set — skip
                        pm_idx <= pm_idx + 6'd1;
                        // Stay in S_LDTASK_REG_NEXT
                    end
                end

                S_LDTASK_REG_LO_WAIT: begin
                    if (!dtack_n) begin
                        ldtask_lo <= data_i;
                        bus_as_r  <= 1'b1;
                        bus_ds_r  <= 2'b11;
                        bus_rw_r  <= 1'b1;
                        state     <= S_LDTASK_REG_HI;
                    end
                end

                S_LDTASK_REG_HI: begin
                    begin
                        logic [31:0] hi_addr;
                        hi_addr    = ldtask_ptr + 32'd2;
                        bus_addr_r <= hi_addr[23:0];
                    end
                    bus_as_r <= 1'b0;
                    bus_rw_r <= 1'b1;
                    bus_ds_r <= 2'b00;
                    state    <= S_LDTASK_REG_HI_WAIT;
                end

                S_LDTASK_REG_HI_WAIT: begin
                    if (!dtack_n) begin
                        // Store into reg_file[pm_idx] (R0..R30)
                        reg_file[{1'b0, pm_idx}] <= {data_i, ldtask_lo};
                        bus_as_r                 <= 1'b1;
                        bus_ds_r                 <= 2'b11;
                        bus_rw_r                 <= 1'b1;
                        ldtask_ptr               <= ldtask_ptr + 32'd4;
                        pm_idx                   <= pm_idx + 6'd1;
                        state                    <= S_LDTASK_REG_NEXT;
                    end
                end

                default: state <= S_RESET;

            endcase
        end
    end

    // =========================================================================
    // PSW update: merge f_z/s/ov/cy into reg_file[33] on every cycle
    // This keeps the PSW register coherent with the flag registers.
    // MAME: v60ReadPSW() -> PSW &= ~0xf; PSW |= Z|S<<1|OV<<2|CY<<3
    // =========================================================================
    // Note: This is a separate always_ff to avoid priority conflicts.
    // The flags are set in the execute path above; PSW merges happen here.
    // actual PSW write happens in S_RESET and when explicitly needed.

endmodule : v60_core

`default_nettype wire
