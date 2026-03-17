`default_nettype none
// =============================================================================
// sdram_f3.sv — SDRAM controller for Taito F3 MiSTer core
// =============================================================================
//
// Wraps a 16Mx16 IS42S16320F (32 MB) SDRAM chip at up to 143 MHz.
// Provides four access channels:
//
//   CH0  ioctl write   — HPS ROM download (sequential, byte-wide input)
//   CH1  sdr read      — 68EC020 program ROM reads (32-bit, toggle-handshake)
//   CH2  gfx_a read    — GFX port A (spr_lo + til_lo, 16-bit toggle-handshake)
//   CH3  gfx_b read    — GFX port B (spr_hi + til_hi, 16-bit toggle-handshake)
//
// Arbitration priority: CH0 (write) > CH1 > CH2 > CH3
//
// SDRAM timing (IS42S16320F @ 143 MHz, CAS=3):
//   tRCD=2, tRP=2, tRC=7, CAS=3
//   Full row cycle: ACTIVATE(1) + READ/WRITE(1) + CAS-latency(3) + PRE(1) = 7 clk
//   Refresh every 64 ms / 8192 rows = 7.8 µs → every 1115 clocks @ 143 MHz
//
// Address mapping (byte addresses into 32 MB = 25-bit byte space):
//   SDRAM is 16Mx16 = 32 MB.  Row[12:0], Bank[1:0], Col[8:0].
//   Byte address [24:1] = word address [23:0].
//   Bank[1:0]  = byte_addr[24:23]
//   Row[12:0]  = byte_addr[22:10]
//   Col[8:0]   = byte_addr[9:1]
//
// Notes:
//   - ioctl_dout is byte-wide; two consecutive bytes pack into one 16-bit word.
//     Byte 0 (even address) → [15:8]; Byte 1 (odd address) → [7:0] then WR.
//   - sdr_data is 32-bit: two 16-bit reads burst back-to-back (addr[1] =0 then =1).
//   - gfx_a/gfx_b data is 16-bit: single read cycle per request.
//   - All read channels use toggle-handshake: req toggles to request; ack mirrors
//     req when data is valid.
//
// Implementation:
//   A simple FSM sequences ACTIVATE → READ/WRITE → PRECHARGE.
//   No open-row optimization (safe, simple, correct).
//   Refresh interleaved when no channel is pending.
// =============================================================================

module sdram_f3 (
    // System
    input  logic        clk,        // SDRAM clock (143 MHz or sdram_clk from PLL)
    input  logic        clk_sys,    // System clock (same or gated — used for ioctl sync)
    input  logic        reset_n,

    // ── CH0: HPS ROM download (write path) ────────────────────────────────────
    input  logic        ioctl_wr,       // write strobe (one cycle pulse in clk_sys domain)
    input  logic [26:0] ioctl_addr,     // byte address (27-bit for up to 128 MB; we use [24:0])
    input  logic  [7:0] ioctl_dout,     // byte data from HPS

    // ── CH1: 68EC020 program ROM (32-bit reads) ────────────────────────────────
    input  logic [26:0] sdr_addr,       // word address (27-bit, [24:0] used)
    output logic [31:0] sdr_data,       // 32-bit read result
    input  logic        sdr_req,        // toggle to request
    output logic        sdr_ack,        // mirrors req when data valid

    // ── CH2: GFX port A (16-bit reads) ────────────────────────────────────────
    input  logic [26:0] gfx_a_addr,     // word address
    output logic [15:0] gfx_a_data,
    input  logic        gfx_a_req,
    output logic        gfx_a_ack,

    // ── CH3: GFX port B (16-bit reads) ────────────────────────────────────────
    input  logic [26:0] gfx_b_addr,     // word address
    output logic [15:0] gfx_b_data,
    input  logic        gfx_b_req,
    output logic        gfx_b_ack,

    // ── SDRAM chip interface ──────────────────────────────────────────────────
    output logic [12:0] SDRAM_A,
    output logic  [1:0] SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);

// =============================================================================
// SDRAM command encoding {nCS, nRAS, nCAS, nWE}
// =============================================================================
localparam [3:0] CMD_NOP        = 4'b0111;
localparam [3:0] CMD_ACTIVE     = 4'b0011;
localparam [3:0] CMD_READ       = 4'b0101;
localparam [3:0] CMD_WRITE      = 4'b0100;
localparam [3:0] CMD_PRECHARGE  = 4'b0010;
localparam [3:0] CMD_AUTO_REF   = 4'b0001;
localparam [3:0] CMD_LOAD_MODE  = 4'b0000;

// =============================================================================
// Init/refresh counters
// =============================================================================
// Init: wait 200 µs after reset (200e-6 * 143e6 ≈ 28600 clocks)
// Refresh interval: 64 ms / 8192 rows = 7.8 µs → 1115 clocks @ 143 MHz
localparam INIT_WAIT     = 15'd28700;
localparam REFRESH_CYCLE = 13'd1115;

logic [14:0] init_ctr;
logic [12:0] ref_ctr;
logic        init_done;
logic        need_refresh;

// =============================================================================
// FSM
// =============================================================================
typedef enum logic [3:0] {
    S_INIT_WAIT,
    S_INIT_PRE,
    S_INIT_REF1,
    S_INIT_REF2,
    S_INIT_MRS,
    S_IDLE,
    S_ACTIVATE,
    S_READ1,
    S_READ2,
    S_WRITE1,
    S_WRITE2,
    S_CAS_WAIT,
    S_PRECHARGE,
    S_REFRESH
} state_t;

state_t state;
logic [3:0] cas_cnt;    // CAS latency countdown (3 cycles)

// =============================================================================
// SDRAM output registers
// =============================================================================
logic [3:0]  cmd_r;
logic [12:0] addr_r;
logic  [1:0] ba_r;
logic [15:0] dq_out;
logic        dq_oe;
logic  [1:0] dqm_r;

assign {SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = cmd_r;
assign SDRAM_A    = addr_r;
assign SDRAM_BA   = ba_r;
assign SDRAM_DQ   = dq_oe ? dq_out : 16'hzzzz;
assign SDRAM_DQML = dqm_r[0];
assign SDRAM_DQMH = dqm_r[1];
assign SDRAM_CKE  = 1'b1;

// =============================================================================
// Byte-packing for ioctl writes
// =============================================================================
// Accumulate two bytes before issuing a 16-bit write.
logic [7:0] ioctl_byte_buf;
logic       ioctl_word_rdy;
logic [24:0] ioctl_word_addr; // word address (byte_addr >> 1)
logic [15:0] ioctl_word_data;

// Cross from clk_sys to clk domain with a 2-FF synchroniser + edge detect.
// For simplicity (clk_sys and clk are the same here — both driven by PLL),
// we treat them as synchronous.
logic ioctl_wr_r;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        ioctl_byte_buf   <= 8'h0;
        ioctl_word_rdy   <= 1'b0;
        ioctl_word_addr  <= 25'h0;
        ioctl_word_data  <= 16'h0;
        ioctl_wr_r       <= 1'b0;
    end else begin
        ioctl_wr_r     <= ioctl_wr;
        ioctl_word_rdy <= 1'b0;

        if (ioctl_wr && !ioctl_wr_r) begin
            if (!ioctl_addr[0]) begin
                // Even byte — buffer it
                ioctl_byte_buf  <= ioctl_dout;
            end else begin
                // Odd byte — form word and signal ready
                ioctl_word_data <= {ioctl_byte_buf, ioctl_dout};
                ioctl_word_addr <= ioctl_addr[25:1];
                ioctl_word_rdy  <= 1'b1;
            end
        end
    end
end

// =============================================================================
// Active channel tracking
// =============================================================================
typedef enum logic [1:0] {
    CH_NONE  = 2'd0,
    CH_WRITE = 2'd1,   // ioctl
    CH_SDR   = 2'd2,   // program ROM
    CH_GFX_A = 2'd3    // gfx_a or gfx_b (distinguished by sub_ch)
} chan_t;

chan_t       active_ch;
logic        active_gfx_b;     // 0=gfx_a active, 1=gfx_b active
logic        sdr_phase2;       // 0=first 16-bit half of 32-bit SDR read, 1=second

// Pending read requests (latch toggle changes in clk domain)
logic sdr_req_r,   sdr_pending;
logic gfx_a_req_r, gfx_a_pending;
logic gfx_b_req_r, gfx_b_pending;

// Saved addresses for in-flight reads
logic [24:0] sdr_addr_r;
logic [24:0] gfx_a_addr_r;
logic [24:0] gfx_b_addr_r;

// CAS read data capture pipeline (CAS=3)
logic [15:0] cas_pipe [0:2];
logic  [2:0] cas_valid;         // shift register: bit 2 = valid after 3 cycles
logic        reading_second_half;  // for SDR 32-bit: latch first half

logic [15:0] sdr_lo_r;          // first 16 bits of 32-bit SDR read

// =============================================================================
// Row/col decomposition helper
// Byte address [24:0]: bank[1:0]=[24:23], row[12:0]=[22:10], col[8:0]=[9:1]
// =============================================================================
function automatic logic [1:0] get_bank(input logic [24:0] waddr);
    return waddr[24:23];
endfunction

function automatic logic [12:0] get_row(input logic [24:0] waddr);
    return waddr[22:10];
endfunction

function automatic logic [8:0] get_col(input logic [24:0] waddr);
    return waddr[9:1];
endfunction

// =============================================================================
// Main FSM
// =============================================================================
always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        state         <= S_INIT_WAIT;
        init_ctr      <= INIT_WAIT;
        ref_ctr       <= REFRESH_CYCLE;
        init_done     <= 1'b0;
        need_refresh  <= 1'b0;
        cmd_r         <= CMD_NOP;
        addr_r        <= 13'b0;
        ba_r          <= 2'b0;
        dq_out        <= 16'h0;
        dq_oe         <= 1'b0;
        dqm_r         <= 2'b11;
        active_ch     <= CH_NONE;
        active_gfx_b  <= 1'b0;
        sdr_phase2    <= 1'b0;
        sdr_req_r     <= 1'b0;
        gfx_a_req_r   <= 1'b0;
        gfx_b_req_r   <= 1'b0;
        sdr_pending   <= 1'b0;
        gfx_a_pending <= 1'b0;
        gfx_b_pending <= 1'b0;
        sdr_addr_r    <= 25'h0;
        gfx_a_addr_r  <= 25'h0;
        gfx_b_addr_r  <= 25'h0;
        sdr_ack       <= 1'b0;
        gfx_a_ack     <= 1'b0;
        gfx_b_ack     <= 1'b0;
        sdr_data      <= 32'h0;
        gfx_a_data    <= 16'h0;
        gfx_b_data    <= 16'h0;
        sdr_lo_r      <= 16'h0;
        cas_valid     <= 3'b0;
        cas_cnt       <= 4'h0;
        reading_second_half <= 1'b0;
        for (int i = 0; i < 3; i++) cas_pipe[i] <= 16'h0;
    end else begin
        // ── Default command ─────────────────────────────────────────
        cmd_r  <= CMD_NOP;
        dq_oe  <= 1'b0;
        dqm_r  <= 2'b11;

        // ── CAS pipeline shift ──────────────────────────────────────
        cas_valid <= {cas_valid[1:0], 1'b0};
        cas_pipe[2] <= cas_pipe[1];
        cas_pipe[1] <= cas_pipe[0];
        cas_pipe[0] <= SDRAM_DQ;

        // ── Pending request detection (toggle-handshake) ────────────
        sdr_req_r   <= sdr_req;
        gfx_a_req_r <= gfx_a_req;
        gfx_b_req_r <= gfx_b_req;

        if (sdr_req != sdr_req_r) begin
            sdr_pending  <= 1'b1;
            sdr_addr_r   <= sdr_addr[24:0];
        end
        if (gfx_a_req != gfx_a_req_r) begin
            gfx_a_pending <= 1'b1;
            gfx_a_addr_r  <= gfx_a_addr[24:0];
        end
        if (gfx_b_req != gfx_b_req_r) begin
            gfx_b_pending <= 1'b1;
            gfx_b_addr_r  <= gfx_b_addr[24:0];
        end

        // ── Refresh counter ─────────────────────────────────────────
        if (init_done) begin
            if (ref_ctr == 13'h0) begin
                need_refresh <= 1'b1;
                ref_ctr      <= REFRESH_CYCLE;
            end else begin
                ref_ctr <= ref_ctr - 13'd1;
            end
        end

        // ── FSM ─────────────────────────────────────────────────────
        case (state)

            // ── Initialisation ──────────────────────────────────────
            S_INIT_WAIT: begin
                if (init_ctr == 15'h0) begin
                    // Issue PRECHARGE ALL
                    cmd_r  <= CMD_PRECHARGE;
                    addr_r <= 13'b010_0000_0000_000; // A10=1 = all banks
                    ba_r   <= 2'b00;
                    state  <= S_INIT_PRE;
                end else begin
                    init_ctr <= init_ctr - 15'd1;
                end
            end

            S_INIT_PRE: begin
                // 2 AUTO REFRESH cycles
                cmd_r  <= CMD_AUTO_REF;
                state  <= S_INIT_REF1;
            end

            S_INIT_REF1: begin
                cmd_r  <= CMD_AUTO_REF;
                cas_cnt <= 4'd6;     // wait tRC
                state  <= S_INIT_REF2;
            end

            S_INIT_REF2: begin
                if (cas_cnt == 4'h0) begin
                    // LOAD MODE REGISTER: CAS=3, burst=1, sequential
                    // MR = 000_0_00_011_0_001 = 0x031
                    cmd_r  <= CMD_LOAD_MODE;
                    addr_r <= 13'b000_0000_0110_001;  // CAS=3, BL=1
                    ba_r   <= 2'b00;
                    state  <= S_INIT_MRS;
                end else begin
                    cas_cnt <= cas_cnt - 4'd1;
                end
            end

            S_INIT_MRS: begin
                // 2 NOP cycles after MRS then IDLE
                init_done <= 1'b1;
                state     <= S_IDLE;
            end

            // ── IDLE — pick next operation ──────────────────────────
            S_IDLE: begin
                // Refresh takes highest priority
                if (need_refresh) begin
                    cmd_r        <= CMD_AUTO_REF;
                    need_refresh <= 1'b0;
                    cas_cnt      <= 4'd6;
                    state        <= S_REFRESH;

                // ioctl write (byte-packed to word) takes next priority
                end else if (ioctl_word_rdy) begin
                    cmd_r  <= CMD_ACTIVE;
                    ba_r   <= get_bank({ioctl_word_addr, 1'b0}); // word→byte addr for bank extract
                    addr_r <= get_row ({ioctl_word_addr, 1'b0});
                    active_ch <= CH_WRITE;
                    state  <= S_ACTIVATE;

                // SDR (program ROM, 32-bit) — two 16-bit reads
                end else if (sdr_pending) begin
                    sdr_pending <= 1'b0;
                    cmd_r   <= CMD_ACTIVE;
                    ba_r    <= get_bank({sdr_addr_r[23:0], 1'b0});
                    addr_r  <= get_row ({sdr_addr_r[23:0], 1'b0});
                    active_ch  <= CH_SDR;
                    sdr_phase2 <= 1'b0;
                    state   <= S_ACTIVATE;

                // GFX port A
                end else if (gfx_a_pending) begin
                    gfx_a_pending <= 1'b0;
                    cmd_r    <= CMD_ACTIVE;
                    ba_r     <= get_bank({gfx_a_addr_r[23:0], 1'b0});
                    addr_r   <= get_row ({gfx_a_addr_r[23:0], 1'b0});
                    active_ch   <= CH_GFX_A;
                    active_gfx_b <= 1'b0;
                    state    <= S_ACTIVATE;

                // GFX port B
                end else if (gfx_b_pending) begin
                    gfx_b_pending <= 1'b0;
                    cmd_r    <= CMD_ACTIVE;
                    ba_r     <= get_bank({gfx_b_addr_r[23:0], 1'b0});
                    addr_r   <= get_row ({gfx_b_addr_r[23:0], 1'b0});
                    active_ch   <= CH_GFX_A;   // reuse slot, distinguished by active_gfx_b
                    active_gfx_b <= 1'b1;
                    state    <= S_ACTIVATE;
                end
            end

            // ── ACTIVATE — tRCD = 2 clocks ──────────────────────────
            S_ACTIVATE: begin
                // 1 NOP after ACTIVE, then READ/WRITE
                case (active_ch)
                    CH_WRITE: state <= S_WRITE1;
                    CH_SDR:   state <= S_READ1;
                    CH_GFX_A: state <= S_READ1;
                    default:  state <= S_IDLE;
                endcase
            end

            // ── WRITE ────────────────────────────────────────────────
            S_WRITE1: begin
                cmd_r  <= CMD_WRITE;
                ba_r   <= get_bank({ioctl_word_addr, 1'b0});
                addr_r <= {4'b0000, get_col({ioctl_word_addr, 1'b0})}; // A10=0 (no auto-precharge)
                dq_out <= ioctl_word_data;
                dq_oe  <= 1'b1;
                dqm_r  <= 2'b00;  // both bytes valid
                state  <= S_WRITE2;
            end

            S_WRITE2: begin
                // Write data presented; precharge after tWR=2
                cmd_r  <= CMD_PRECHARGE;
                ba_r   <= get_bank({ioctl_word_addr, 1'b0});
                addr_r <= 13'b000_0000_0000_000;  // specific bank
                dqm_r  <= 2'b11;
                state  <= S_PRECHARGE;
                cas_cnt <= 4'd1;  // tRP = 2 clocks
            end

            // ── READ ─────────────────────────────────────────────────
            S_READ1: begin
                // Issue READ command
                cmd_r  <= CMD_READ;
                dqm_r  <= 2'b00;
                case (active_ch)
                    CH_SDR: begin
                        ba_r   <= get_bank({sdr_addr_r[23:0], 1'b0});
                        addr_r <= {4'b0000, get_col({sdr_addr_r[23:0], 1'b0})};
                    end
                    default: begin  // CH_GFX_A (both gfx_a and gfx_b)
                        if (!active_gfx_b) begin
                            ba_r   <= get_bank({gfx_a_addr_r[23:0], 1'b0});
                            addr_r <= {4'b0000, get_col({gfx_a_addr_r[23:0], 1'b0})};
                        end else begin
                            ba_r   <= get_bank({gfx_b_addr_r[23:0], 1'b0});
                            addr_r <= {4'b0000, get_col({gfx_b_addr_r[23:0], 1'b0})};
                        end
                    end
                endcase
                // CAS latency = 3; data will be valid 3 cycles later
                cas_cnt   <= 4'd2;  // counts down to 0 over 3 cycles (READ1, +1, +2)
                cas_valid <= 3'b0;
                state     <= S_CAS_WAIT;
            end

            S_READ2: begin
                // Second read for SDR 32-bit (issued 1 cycle after first)
                cmd_r  <= CMD_READ;
                dqm_r  <= 2'b00;
                ba_r   <= get_bank({sdr_addr_r[23:0], 1'b1});   // word+1 (next 16-bit word)
                addr_r <= {4'b0000, get_col({sdr_addr_r[23:0], 1'b1})};
                cas_cnt   <= 4'd2;
                cas_valid <= 3'b0;
                state     <= S_CAS_WAIT;
            end

            // ── CAS wait ─────────────────────────────────────────────
            S_CAS_WAIT: begin
                if (cas_cnt != 4'h0) begin
                    cas_cnt <= cas_cnt - 4'd1;
                end else begin
                    // Data available on SDRAM_DQ this cycle (registered into cas_pipe[0])
                    // cas_pipe[0] is registered at end of this clock, available next
                    // To capture: shift once more, use cas_pipe[1] next cycle.
                    // Actually with CAS=3: READ issued at cycle 0, data valid at cycle 3.
                    // cas_cnt: 2→1→0 = 3 cycles, so data is on DQ this cycle.
                    cas_valid[0] <= 1'b1;

                    // Precharge after read (tRAS satisfied by CAS wait)
                    cmd_r  <= CMD_PRECHARGE;
                    addr_r <= 13'b000_0000_0000_000;
                    dqm_r  <= 2'b11;
                    state  <= S_PRECHARGE;
                    cas_cnt <= 4'd1;

                    // For SDR 32-bit first half: need to issue second read
                    if (active_ch == CH_SDR && !sdr_phase2) begin
                        // Actually: for 32-bit we should read two consecutive words.
                        // But we already issued PRECHARGE — simpler to re-ACTIVATE for second word.
                        // (Penalty: one extra cycle. Acceptable for correctness.)
                        sdr_phase2 <= 1'b1;
                    end
                end
            end

            // ── PRECHARGE ────────────────────────────────────────────
            S_PRECHARGE: begin
                if (cas_cnt != 4'h0) begin
                    cas_cnt <= cas_cnt - 4'd1;
                end else begin
                    // Data from CAS_WAIT is now in cas_pipe[2] (shifted 2 more times)
                    // cas_pipe[0] = captured at CAS_WAIT last cycle
                    // cas_pipe[1] = captured at PRECHARGE entry
                    // cas_pipe[2] = available now (PRECHARGE+1 when cas_cnt==0)
                    // Actually cas_pipe shifts every cycle, so:
                    //   if data was on DQ at CAS_WAIT (cas_cnt reaches 0),
                    //   it enters cas_pipe[0] that cycle,
                    //   cas_pipe[1] next, cas_pipe[2] the cycle after.
                    //   We reach here after cas_cnt 1→0, so 2 cycles after CAS_WAIT→PRECHARGE.
                    //   Data is in cas_pipe[2].
                    case (active_ch)
                        CH_SDR: begin
                            if (!sdr_phase2) begin
                                // First half done; latch lower 16 bits and re-activate for upper
                                sdr_lo_r <= cas_pipe[1];
                                // Re-activate for second word (sdr_addr+1)
                                cmd_r  <= CMD_ACTIVE;
                                ba_r   <= get_bank({sdr_addr_r[24:1], 1'b1, 1'b0}); // word+1
                                addr_r <= get_row ({sdr_addr_r[24:1], 1'b1, 1'b0});
                                state  <= S_ACTIVATE;
                                // Stay in phase2 mode (sdr_phase2 already 1)
                            end else begin
                                // Second half: assemble 32-bit result
                                sdr_data <= {cas_pipe[1], sdr_lo_r};
                                sdr_ack  <= sdr_req;   // mirror req to signal done
                                sdr_phase2 <= 1'b0;
                                state <= S_IDLE;
                            end
                        end
                        CH_GFX_A: begin
                            if (!active_gfx_b) begin
                                gfx_a_data <= cas_pipe[1];
                                gfx_a_ack  <= gfx_a_req;
                            end else begin
                                gfx_b_data <= cas_pipe[1];
                                gfx_b_ack  <= gfx_b_req;
                            end
                            state <= S_IDLE;
                        end
                        CH_WRITE: begin
                            state <= S_IDLE;
                        end
                        default: state <= S_IDLE;
                    endcase
                end
            end

            // ── REFRESH ──────────────────────────────────────────────
            S_REFRESH: begin
                if (cas_cnt != 4'h0)
                    cas_cnt <= cas_cnt - 4'd1;
                else
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;

        endcase
    end
end

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{sdr_addr[26:25], gfx_a_addr[26:25], gfx_b_addr[26:25],
                   ioctl_addr[26:25], cas_valid, cas_pipe[0]};
/* verilator lint_on UNUSED */

endmodule
