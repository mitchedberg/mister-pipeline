`default_nettype none
// =============================================================================
// sdram_z.sv — SDRAM controller for Taito Z MiSTer core
// =============================================================================
//
// Wraps a 16Mx16 IS42S16320F (32 MB) SDRAM chip at up to 143 MHz.
// Provides four access channels:
//
//   CH0  ioctl write    — HPS ROM download (sequential, byte-wide input)
//   CH1  cpu read       — CPU A/B program ROM reads (16-bit, toggle-handshake)
//   CH2  gfx read       — TC0480SCP tile GFX + STY spritemap (16-bit, toggle)
//   CH3  obj/rod read   — OBJ GFX + TC0150ROD road ROM (16-bit, toggle)
//
// Arbitration priority: CH0 (write) > CH1 > CH2 > CH3
//
// SDRAM layout (dblaxle byte addresses — from integration_plan.md §7.4):
//   0x000000    512KB    CPU A program ROM
//   0x080000    256KB    CPU B program ROM
//   0x0C0000    128KB    Z80 audio program
//   0x0E0000    128KB    (pad to 1MB boundary)
//   0x100000    1MB      TC0480SCP SCR GFX ROM
//   0x200000    4MB      Sprite OBJ GFX ROM
//   0x600000    512KB    TC0150ROD road data
//   0x680000    512KB    STY spritemap ROM
//   0x700000    1.5MB    ADPCM-A samples
//   0x880000    512KB    ADPCM-B samples
//   Total: ~9MB (fits in 16MB SDRAM)
//
// SDRAM timing (IS42S16320F @ 143 MHz, CAS=3):
//   tRCD=2, tRP=2, tRC=7, CAS=3
//   Refresh every 64 ms / 8192 rows = 7.8 µs → every 1115 clocks @ 143 MHz
//
// Notes:
//   - CH1 is 16-bit (not 32-bit like F3's 68EC020): single SDRAM read per req.
//   - CH2 is used for both tile GFX (4×32-bit TC0480SCP fetches, burst-packed
//     by the gfx_arbiter in emu.sv) and STY spritemap (16-bit word).
//   - CH3 is used for OBJ GFX (64-bit wide, burst-packed by obj_arbiter) and
//     road ROM (16-bit word). The arbiter above sdram_z handles burst packing.
//   - All read channels use toggle-handshake: req toggles to request;
//     ack mirrors req when data is valid.
// =============================================================================

module sdram_z (
    // System
    input  logic        clk,        // SDRAM clock (143 MHz from PLL)
    input  logic        clk_sys,    // System clock (used for ioctl sync)
    input  logic        reset_n,

    // ── CH0: HPS ROM download (write path) ────────────────────────────────────
    input  logic        ioctl_wr,       // write strobe (one-cycle pulse, clk_sys domain)
    input  logic [26:0] ioctl_addr,     // byte address
    input  logic  [7:0] ioctl_dout,     // byte data from HPS

    // ── CH1: CPU A/B program ROM (16-bit reads) ───────────────────────────────
    input  logic [26:0] cpu_addr,       // byte address
    output logic [15:0] cpu_data,       // 16-bit read result
    input  logic        cpu_req,        // toggle to request
    output logic        cpu_ack,        // mirrors req when data valid

    // ── CH2: Tile GFX + STY spritemap (16-bit reads) ──────────────────────────
    input  logic [26:0] gfx_addr,       // byte address into SDRAM (arbiter provides)
    output logic [15:0] gfx_data,
    input  logic        gfx_req,
    output logic        gfx_ack,

    // ── CH3: OBJ GFX + road ROM (16-bit reads) ────────────────────────────────
    input  logic [26:0] obj_addr,       // byte address into SDRAM (arbiter provides)
    output logic [15:0] obj_data,
    input  logic        obj_req,
    output logic        obj_ack,

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
    S_WRITE1,
    S_WRITE2,
    S_CAS_WAIT,
    S_PRECHARGE,
    S_REFRESH
} state_t;

state_t state;
logic [3:0] cas_cnt;    // CAS latency countdown

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
logic [7:0]  ioctl_byte_buf;
logic        ioctl_word_rdy;
logic [24:0] ioctl_word_addr;
logic [15:0] ioctl_word_data;
logic        ioctl_wr_r;

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
                ioctl_byte_buf  <= ioctl_dout;
            end else begin
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
    CH_CPU   = 2'd2,   // CPU A/B program ROM
    CH_GFX   = 2'd3    // gfx (tile/stym) or obj/rod (distinguished by active_obj)
} chan_t;

chan_t active_ch;
logic  active_obj;      // 0=gfx channel active, 1=obj/rod channel active

// Pending read requests (toggle-handshake detection)
logic cpu_req_r,   cpu_pending;
logic gfx_req_r,   gfx_pending;
logic obj_req_r,   obj_pending;

// Saved addresses for in-flight reads
logic [24:0] cpu_addr_r;
logic [24:0] gfx_addr_r;
logic [24:0] obj_addr_r;

// CAS read data capture pipeline (CAS=3)
logic [15:0] cas_pipe [0:2];
logic  [2:0] cas_valid;

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
        active_obj    <= 1'b0;
        cpu_req_r     <= 1'b0;
        gfx_req_r     <= 1'b0;
        obj_req_r     <= 1'b0;
        cpu_pending   <= 1'b0;
        gfx_pending   <= 1'b0;
        obj_pending   <= 1'b0;
        cpu_addr_r    <= 25'h0;
        gfx_addr_r    <= 25'h0;
        obj_addr_r    <= 25'h0;
        cpu_ack       <= 1'b0;
        gfx_ack       <= 1'b0;
        obj_ack       <= 1'b0;
        cpu_data      <= 16'h0;
        gfx_data      <= 16'h0;
        obj_data      <= 16'h0;
        cas_valid     <= 3'b0;
        cas_cnt       <= 4'h0;
        for (int i = 0; i < 3; i++) cas_pipe[i] <= 16'h0;
    end else begin
        // Default command
        cmd_r  <= CMD_NOP;
        dq_oe  <= 1'b0;
        dqm_r  <= 2'b11;

        // CAS pipeline shift (every cycle)
        cas_valid <= {cas_valid[1:0], 1'b0};
        cas_pipe[2] <= cas_pipe[1];
        cas_pipe[1] <= cas_pipe[0];
        cas_pipe[0] <= SDRAM_DQ;

        // Pending request detection (toggle-handshake)
        cpu_req_r <= cpu_req;
        gfx_req_r <= gfx_req;
        obj_req_r <= obj_req;

        if (cpu_req != cpu_req_r) begin
            cpu_pending <= 1'b1;
            cpu_addr_r  <= cpu_addr[24:0];
        end
        if (gfx_req != gfx_req_r) begin
            gfx_pending <= 1'b1;
            gfx_addr_r  <= gfx_addr[24:0];
        end
        if (obj_req != obj_req_r) begin
            obj_pending <= 1'b1;
            obj_addr_r  <= obj_addr[24:0];
        end

        // Refresh counter
        if (init_done) begin
            if (ref_ctr == 13'h0) begin
                need_refresh <= 1'b1;
                ref_ctr      <= REFRESH_CYCLE;
            end else begin
                ref_ctr <= ref_ctr - 13'd1;
            end
        end

        case (state)

            // ── Initialisation ──────────────────────────────────────
            S_INIT_WAIT: begin
                if (init_ctr == 15'h0) begin
                    cmd_r  <= CMD_PRECHARGE;
                    addr_r <= 13'b010_0000_0000_000; // A10=1 = all banks
                    ba_r   <= 2'b00;
                    state  <= S_INIT_PRE;
                end else begin
                    init_ctr <= init_ctr - 15'd1;
                end
            end

            S_INIT_PRE: begin
                cmd_r  <= CMD_AUTO_REF;
                state  <= S_INIT_REF1;
            end

            S_INIT_REF1: begin
                cmd_r   <= CMD_AUTO_REF;
                cas_cnt <= 4'd6;
                state   <= S_INIT_REF2;
            end

            S_INIT_REF2: begin
                if (cas_cnt == 4'h0) begin
                    // LOAD MODE REGISTER: CAS=3, burst=1, sequential
                    cmd_r  <= CMD_LOAD_MODE;
                    addr_r <= 13'b000_0000_0110_001;  // CAS=3, BL=1
                    ba_r   <= 2'b00;
                    state  <= S_INIT_MRS;
                end else begin
                    cas_cnt <= cas_cnt - 4'd1;
                end
            end

            S_INIT_MRS: begin
                init_done <= 1'b1;
                state     <= S_IDLE;
            end

            // ── IDLE — pick next operation ──────────────────────────
            S_IDLE: begin
                if (need_refresh) begin
                    cmd_r        <= CMD_AUTO_REF;
                    need_refresh <= 1'b0;
                    cas_cnt      <= 4'd6;
                    state        <= S_REFRESH;

                end else if (ioctl_word_rdy) begin
                    cmd_r  <= CMD_ACTIVE;
                    ba_r   <= get_bank({ioctl_word_addr, 1'b0});
                    addr_r <= get_row ({ioctl_word_addr, 1'b0});
                    active_ch <= CH_WRITE;
                    state  <= S_ACTIVATE;

                end else if (cpu_pending) begin
                    cpu_pending <= 1'b0;
                    cmd_r   <= CMD_ACTIVE;
                    ba_r    <= get_bank({cpu_addr_r[23:0], 1'b0});
                    addr_r  <= get_row ({cpu_addr_r[23:0], 1'b0});
                    active_ch  <= CH_CPU;
                    state   <= S_ACTIVATE;

                end else if (gfx_pending) begin
                    gfx_pending  <= 1'b0;
                    cmd_r    <= CMD_ACTIVE;
                    ba_r     <= get_bank({gfx_addr_r[23:0], 1'b0});
                    addr_r   <= get_row ({gfx_addr_r[23:0], 1'b0});
                    active_ch   <= CH_GFX;
                    active_obj  <= 1'b0;
                    state    <= S_ACTIVATE;

                end else if (obj_pending) begin
                    obj_pending  <= 1'b0;
                    cmd_r    <= CMD_ACTIVE;
                    ba_r     <= get_bank({obj_addr_r[23:0], 1'b0});
                    addr_r   <= get_row ({obj_addr_r[23:0], 1'b0});
                    active_ch   <= CH_GFX;  // reuse slot, distinguished by active_obj
                    active_obj  <= 1'b1;
                    state    <= S_ACTIVATE;
                end
            end

            // ── ACTIVATE — tRCD = 2 clocks ──────────────────────────
            S_ACTIVATE: begin
                case (active_ch)
                    CH_WRITE: state <= S_WRITE1;
                    default:  state <= S_READ1;
                endcase
            end

            // ── WRITE ────────────────────────────────────────────────
            S_WRITE1: begin
                cmd_r  <= CMD_WRITE;
                ba_r   <= get_bank({ioctl_word_addr, 1'b0});
                addr_r <= {4'b0000, get_col({ioctl_word_addr, 1'b0})};
                dq_out <= ioctl_word_data;
                dq_oe  <= 1'b1;
                dqm_r  <= 2'b00;
                state  <= S_WRITE2;
            end

            S_WRITE2: begin
                cmd_r   <= CMD_PRECHARGE;
                ba_r    <= get_bank({ioctl_word_addr, 1'b0});
                addr_r  <= 13'b000_0000_0000_000;
                dqm_r   <= 2'b11;
                state   <= S_PRECHARGE;
                cas_cnt <= 4'd1;
            end

            // ── READ ─────────────────────────────────────────────────
            S_READ1: begin
                cmd_r  <= CMD_READ;
                dqm_r  <= 2'b00;
                case (active_ch)
                    CH_CPU: begin
                        ba_r   <= get_bank({cpu_addr_r[23:0], 1'b0});
                        addr_r <= {4'b0000, get_col({cpu_addr_r[23:0], 1'b0})};
                    end
                    default: begin  // CH_GFX covers both gfx and obj/rod
                        if (!active_obj) begin
                            ba_r   <= get_bank({gfx_addr_r[23:0], 1'b0});
                            addr_r <= {4'b0000, get_col({gfx_addr_r[23:0], 1'b0})};
                        end else begin
                            ba_r   <= get_bank({obj_addr_r[23:0], 1'b0});
                            addr_r <= {4'b0000, get_col({obj_addr_r[23:0], 1'b0})};
                        end
                    end
                endcase
                // CAS latency = 3; data valid 3 cycles after READ command
                cas_cnt   <= 4'd2;
                cas_valid <= 3'b0;
                state     <= S_CAS_WAIT;
            end

            // ── CAS wait ─────────────────────────────────────────────
            S_CAS_WAIT: begin
                if (cas_cnt != 4'h0) begin
                    cas_cnt <= cas_cnt - 4'd1;
                end else begin
                    // Data on DQ this cycle
                    cas_valid[0] <= 1'b1;

                    cmd_r   <= CMD_PRECHARGE;
                    addr_r  <= 13'b000_0000_0000_000;
                    dqm_r   <= 2'b11;
                    state   <= S_PRECHARGE;
                    cas_cnt <= 4'd1;
                end
            end

            // ── PRECHARGE ────────────────────────────────────────────
            S_PRECHARGE: begin
                if (cas_cnt != 4'h0) begin
                    cas_cnt <= cas_cnt - 4'd1;
                end else begin
                    // Data in cas_pipe[1] (shifted 2 cycles after CAS_WAIT)
                    case (active_ch)
                        CH_CPU: begin
                            cpu_data <= cas_pipe[1];
                            cpu_ack  <= cpu_req;
                            state    <= S_IDLE;
                        end
                        CH_GFX: begin
                            if (!active_obj) begin
                                gfx_data <= cas_pipe[1];
                                gfx_ack  <= gfx_req;
                            end else begin
                                obj_data <= cas_pipe[1];
                                obj_ack  <= obj_req;
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
assign _unused = ^{cpu_addr[26:25], gfx_addr[26:25], obj_addr[26:25],
                   ioctl_addr[26:25], cas_valid, cas_pipe[0]};
/* verilator lint_on UNUSED */

endmodule
