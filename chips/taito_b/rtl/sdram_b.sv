`default_nettype none
// =============================================================================
// sdram_b.sv — Synthesizable SDRAM controller for MiSTer DE-10 Nano
// =============================================================================
//
// Target SDRAM: IS42S16400J  (4M × 16-bit × 4 banks = 32 MB)
//   Row address : 13 bits   (A[12:0])
//   Column addr :  9 bits   (A[8:0])
//   Banks       :  2 bits   (BA[1:0])
//   Data bus    : 16 bits   (DQ[15:0])
//   CAS latency : 2
//   tRCD        : 2 cycles  (ACTIVATE→READ/WRITE)
//   tRP         : 2 cycles  (PRECHARGE→next command)
//   tRC         : 7 cycles  (row cycle time at 143 MHz)
//   Refresh     : every 7.8 µs → every 1115 cycles @ 143 MHz
//
// Channels
//   CH0  ioctl write     — HPS ROM download (byte-wide, clk_sys domain)
//   CH1  cpu read        — MC68000 program ROM (16-bit, toggle-handshake)
//   CH2  gfx read        — GFX ROM (16-bit, toggle-handshake)
//   CH3  adpcm read      — ADPCM ROM (16-bit, toggle-handshake)
//   CH4  z80 read        — Z80 audio program ROM (16-bit, toggle-handshake)
//
// Priority: CH0 > CH1 > CH2 > CH3 > CH4
// Row-open optimisation: skip PRECHARGE+ACTIVATE when same bank/row is open.
// =============================================================================

module sdram_b (
    // Clock + reset
    input  logic        clk,        // SDRAM clock (143 MHz)
    input  logic        clk_sys,    // System clock (16 MHz)
    input  logic        rst_n,

    // SDRAM physical pins
    output logic [12:0] SDRAM_A,
    output logic  [1:0] SDRAM_BA,
    inout  logic [15:0] SDRAM_DQ,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_nCS,
    output logic  [1:0] SDRAM_DQM,
    output logic        SDRAM_CKE,

    // CH0: ioctl ROM download (write, clk_sys domain, byte writes)
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,

    // CH1: CPU ROM read (toggle handshake, clk_sys domain)
    input  logic [26:0] cpu_addr,
    input  logic        cpu_req,
    output logic [15:0] cpu_data,
    output logic        cpu_ack,

    // CH2: GFX ROM read (toggle handshake, clk_sys domain)
    input  logic [26:0] gfx_addr,
    input  logic        gfx_req,
    output logic [15:0] gfx_data,
    output logic        gfx_ack,

    // CH3: ADPCM ROM read (toggle handshake, clk_sys domain)
    input  logic [26:0] adpcm_addr,
    input  logic        adpcm_req,
    output logic [15:0] adpcm_data,
    output logic        adpcm_ack,

    // CH4: Z80 ROM read (toggle handshake, clk_sys domain)
    input  logic [26:0] z80_addr,
    input  logic        z80_req,
    output logic [15:0] z80_data,
    output logic        z80_ack
);

// =============================================================================
// Parameters
// =============================================================================

// Refresh period: 7.8 µs × 133.333 MHz = 1040 → use 1036 for margin (never exceed 7.8 µs)
localparam REFRESH_CYCLES = 11'd1036;

// Initialisation delay: 200 µs × 133.333 MHz = 26666 → round up to 26700
localparam INIT_DELAY     = 15'd26700;

// Timing counts (in clock cycles, zero-based → subtract 1 for counter terminal)
localparam tRP_CYCLES  = 2'd2;   // PRECHARGE recovery
localparam tRCD_CYCLES = 2'd2;   // ACTIVATE → READ/WRITE
localparam tRC_CYCLES  = 3'd6;   // READ data latency after CAS=2 (CAS=2 → data 2 clocks later)

// =============================================================================
// FSM states
// =============================================================================
typedef enum logic [3:0] {
    S_INIT_WAIT,   // 200 µs power-up wait
    S_INIT_PRE,    // initial PRECHARGE ALL
    S_INIT_PRE_W,  // wait tRP after init precharge
    S_INIT_REF1,   // first auto-refresh
    S_INIT_REF1_W, // wait tRC after first refresh
    S_INIT_REF2,   // second auto-refresh
    S_INIT_REF2_W, // wait tRC after second refresh
    S_INIT_MRS,    // MODE REGISTER SET
    S_INIT_MRS_W,  // wait tMRD (2 cycles)
    S_IDLE,        // idle — arbitrate next command
    S_ACT,         // ACTIVATE row
    S_ACT_W,       // wait tRCD
    S_READ,        // issue READ command
    S_READ_W,      // wait CAS latency + capture data
    S_WRITE,       // issue WRITE command
    S_WRITE_W      // wait tRP before next op
} state_t;

// =============================================================================
// SDRAM command encoding  {nCS, nRAS, nCAS, nWE}
// =============================================================================
localparam CMD_NOP       = 4'b1111;
localparam CMD_ACTIVE    = 4'b0011;
localparam CMD_READ      = 4'b0101;
localparam CMD_WRITE     = 4'b0100;
localparam CMD_PRECHARGE = 4'b0010;
localparam CMD_AUTO_REF  = 4'b0001;
localparam CMD_MRS       = 4'b0000;

// =============================================================================
// Internal registers
// =============================================================================

// FSM
state_t              state;
logic [14:0]         init_cnt;   // power-up delay counter (28700 max)
logic  [2:0]         wait_cnt;   // general wait counter
logic [10:0]         ref_cnt;    // refresh period counter
logic                ref_req;    // refresh needed flag

// Current transaction latched at ACTIVATE
logic [12:0]         row_addr;   // row being activated
logic  [1:0]         bank_sel;   // bank being activated
logic  [8:0]         col_addr;   // column for read/write
logic  [1:0]         dqm_r;      // DQM for current write
logic [15:0]         wr_data;    // 16-bit word to write
logic                doing_write; // 1=write, 0=read
logic  [2:0]         ch_sel;     // active channel (0=ioctl,1=cpu,2=gfx,3=adpcm,4=z80)

// Row-open tracking (one entry per bank)
logic [12:0]         open_row  [0:3];
logic                open_valid[0:3];  // is a row currently open in this bank?

// CH0: ioctl byte-pair buffer (clk_sys domain → clk domain via small FIFO)
logic  [7:0]         ioctl_lo_byte;    // buffered low byte
/* verilator lint_off UNUSEDSIGNAL */
logic                ioctl_lo_valid;   // low byte is waiting (consumed internally)
/* verilator lint_on UNUSEDSIGNAL */

// CH0 FIFO: 4-entry deep, 27-bit address + 16-bit data + 2-bit DQM
localparam FIFO_DEPTH = 4;
localparam FIFO_AW    = 2;
logic [44:0]         wr_fifo [0:FIFO_DEPTH-1]; // {dqm[1:0], data[15:0], addr[26:1]}
logic [FIFO_AW-1:0]  wr_wptr, wr_rptr;
logic                wr_fifo_full, wr_fifo_empty;

// (ioctl_wr is used directly in the clk_sys always block; no CDC needed for this path)

// CDC synchronisers for read channels (req → clk domain)
logic  [1:0]         cpu_req_sync,   gfx_req_sync,   adpcm_req_sync,  z80_req_sync;
logic                cpu_req_clk,    gfx_req_clk,    adpcm_req_clk,   z80_req_clk;
logic                cpu_req_prev,   gfx_req_prev,   adpcm_req_prev,  z80_req_prev;
logic                cpu_req_pend,   gfx_req_pend,   adpcm_req_pend,  z80_req_pend; // pending in clk domain

// Latched addresses (captured when req edge detected)
// Bits [26] and [12:11] are not used by this controller's row/bank/col mapping — suppress lint
/* verilator lint_off UNUSEDSIGNAL */
logic [26:0]         cpu_addr_lat,   gfx_addr_lat,   adpcm_addr_lat,  z80_addr_lat;
/* verilator lint_on UNUSEDSIGNAL */

// Read data registers
logic [15:0]         cpu_data_r,     gfx_data_r,     adpcm_data_r,    z80_data_r;
logic                cpu_ack_r,      gfx_ack_r,       adpcm_ack_r,    z80_ack_r;

// SDRAM DQ tri-state
logic [15:0]         dq_out;
logic                dq_oe;

// Command output register
logic  [3:0]         cmd_r;   // {nCS, nRAS, nCAS, nWE}
logic [12:0]         addr_r;
logic  [1:0]         ba_r;
logic  [1:0]         dqm_out;

// =============================================================================
// SDRAM DQ tri-state
// =============================================================================
assign SDRAM_DQ  = dq_oe ? dq_out : 16'hZZZZ;
assign SDRAM_CKE = 1'b1;

// Drive SDRAM control pins from command register
assign SDRAM_nCS  = cmd_r[3];
assign SDRAM_nRAS = cmd_r[2];
assign SDRAM_nCAS = cmd_r[1];
assign SDRAM_nWE  = cmd_r[0];
assign SDRAM_A    = addr_r;
assign SDRAM_BA   = ba_r;
assign SDRAM_DQM  = dqm_out;

// =============================================================================
// CH0: ioctl byte-pair logic (clk_sys domain)
// Pair bytes: low byte latched on even address, word written on odd address.
// =============================================================================
always_ff @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) begin
        ioctl_lo_byte  <= 8'h00;
        ioctl_lo_valid <= 1'b0;
        wr_wptr        <= '0;
        // low bytes stash; FIFO write from here
    end else begin
        if (ioctl_wr) begin
            if (!ioctl_addr[0]) begin
                // Even byte: just latch low byte
                ioctl_lo_byte  <= ioctl_dout;
                ioctl_lo_valid <= 1'b1;
            end else begin
                // Odd byte: form word and push into FIFO (if space)
                if (!wr_fifo_full) begin
                    // word addr = ioctl_addr[26:1], data = {hi, lo}
                    wr_fifo[wr_wptr] <= {1'b0, 2'b00, ioctl_dout, ioctl_lo_byte, ioctl_addr[26:1]};
                    wr_wptr          <= wr_wptr + 1'b1;
                end
                ioctl_lo_valid <= 1'b0;
            end
        end
    end
end

// FIFO status (cross-domain; conservative: treat single-bit ptrs as gray)
// Since clk >> clk_sys, and FIFO is small, a simple async comparison is fine for
// the full/empty flags that the clk_sys domain checks.
assign wr_fifo_empty = (wr_wptr == wr_rptr);
assign wr_fifo_full  = ((wr_wptr + 1'b1) == wr_rptr);

// =============================================================================
// CDC: synchronise read channel req signals into clk domain
// =============================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_req_sync   <= 2'b00;
        gfx_req_sync   <= 2'b00;
        adpcm_req_sync <= 2'b00;
        z80_req_sync   <= 2'b00;
    end else begin
        cpu_req_sync   <= {cpu_req_sync[0],   cpu_req};
        gfx_req_sync   <= {gfx_req_sync[0],   gfx_req};
        adpcm_req_sync <= {adpcm_req_sync[0],  adpcm_req};
        z80_req_sync   <= {z80_req_sync[0],    z80_req};
    end
end

// Detect toggle edges and latch addresses
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cpu_req_prev  <= 1'b0;  cpu_req_pend  <= 1'b0;  cpu_addr_lat   <= '0;
        gfx_req_prev  <= 1'b0;  gfx_req_pend  <= 1'b0;  gfx_addr_lat   <= '0;
        adpcm_req_prev<= 1'b0;  adpcm_req_pend<= 1'b0;  adpcm_addr_lat <= '0;
        z80_req_prev  <= 1'b0;  z80_req_pend  <= 1'b0;  z80_addr_lat   <= '0;
    end else begin
        cpu_req_clk   <= cpu_req_sync[1];
        gfx_req_clk   <= gfx_req_sync[1];
        adpcm_req_clk <= adpcm_req_sync[1];
        z80_req_clk   <= z80_req_sync[1];

        cpu_req_prev  <= cpu_req_clk;
        gfx_req_prev  <= gfx_req_clk;
        adpcm_req_prev<= adpcm_req_clk;
        z80_req_prev  <= z80_req_clk;

        // Set pending on toggle; clear when arbitrated
        if (cpu_req_clk != cpu_req_prev) begin
            cpu_req_pend  <= 1'b1;
            cpu_addr_lat  <= cpu_addr;
        end else if (state == S_ACT && ch_sel == 3'd1) begin
            cpu_req_pend  <= 1'b0;
        end

        if (gfx_req_clk != gfx_req_prev) begin
            gfx_req_pend  <= 1'b1;
            gfx_addr_lat  <= gfx_addr;
        end else if (state == S_ACT && ch_sel == 3'd2) begin
            gfx_req_pend  <= 1'b0;
        end

        if (adpcm_req_clk != adpcm_req_prev) begin
            adpcm_req_pend  <= 1'b1;
            adpcm_addr_lat  <= adpcm_addr;
        end else if (state == S_ACT && ch_sel == 3'd3) begin
            adpcm_req_pend  <= 1'b0;
        end

        if (z80_req_clk != z80_req_prev) begin
            z80_req_pend  <= 1'b1;
            z80_addr_lat  <= z80_addr;
        end else if (state == S_ACT && ch_sel == 3'd4) begin
            z80_req_pend  <= 1'b0;
        end
    end
end

// =============================================================================
// Refresh counter
// =============================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ref_cnt <= '0;
    end else begin
        if (ref_cnt == REFRESH_CYCLES)
            ref_cnt <= '0;
        else
            ref_cnt <= ref_cnt + 1'b1;
    end
end

// =============================================================================
// Main FSM + SDRAM command issuer
// =============================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= S_INIT_WAIT;
        init_cnt    <= '0;
        wait_cnt    <= '0;
        cmd_r       <= CMD_NOP;
        addr_r      <= '0;
        ba_r        <= '0;
        dqm_out     <= 2'b11;
        dq_oe       <= 1'b0;
        dq_out      <= '0;
        wr_rptr     <= '0;
        ref_req     <= 1'b0;
        doing_write <= 1'b0;
        ch_sel      <= '0;
        row_addr    <= '0;
        bank_sel    <= '0;
        col_addr    <= '0;
        wr_data     <= '0;
        dqm_r       <= 2'b11;
        for (int i = 0; i < 4; i++) begin
            open_row[i]   <= '0;
            open_valid[i] <= 1'b0;
        end
        cpu_data_r  <= '0;  cpu_ack_r  <= 1'b0;
        gfx_data_r  <= '0;  gfx_ack_r  <= 1'b0;
        adpcm_data_r<= '0;  adpcm_ack_r<= 1'b0;
        z80_data_r  <= '0;  z80_ack_r  <= 1'b0;
    end else begin

        // Default: NOP every cycle unless overridden below
        cmd_r   <= CMD_NOP;
        dq_oe   <= 1'b0;
        dqm_out <= 2'b11;

        // Latch refresh request when counter expires
        if (ref_cnt == REFRESH_CYCLES) ref_req <= 1'b1;

        case (state)

            // -----------------------------------------------------------------
            // S_INIT_WAIT: hold CKE high, wait 200 µs before touching SDRAM
            // -----------------------------------------------------------------
            S_INIT_WAIT: begin
                if (init_cnt == INIT_DELAY) begin
                    state    <= S_INIT_PRE;
                    init_cnt <= '0;
                end else begin
                    init_cnt <= init_cnt + 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // S_INIT_PRE: PRECHARGE ALL banks
            // -----------------------------------------------------------------
            S_INIT_PRE: begin
                cmd_r  <= CMD_PRECHARGE;
                addr_r <= 13'b0010000000000; // A10=1 → precharge all
                ba_r   <= 2'b00;
                wait_cnt <= tRP_CYCLES - 1;
                state  <= S_INIT_PRE_W;
            end

            S_INIT_PRE_W: begin
                if (wait_cnt == 0) state <= S_INIT_REF1;
                else wait_cnt <= wait_cnt - 1'b1;
            end

            // -----------------------------------------------------------------
            // S_INIT_REF1/REF2: two AUTO REFRESH cycles
            // -----------------------------------------------------------------
            S_INIT_REF1: begin
                cmd_r    <= CMD_AUTO_REF;
                wait_cnt <= tRC_CYCLES - 1;
                state    <= S_INIT_REF1_W;
            end

            S_INIT_REF1_W: begin
                if (wait_cnt == 0) state <= S_INIT_REF2;
                else wait_cnt <= wait_cnt - 1'b1;
            end

            S_INIT_REF2: begin
                cmd_r    <= CMD_AUTO_REF;
                wait_cnt <= tRC_CYCLES - 1;
                state    <= S_INIT_REF2_W;
            end

            S_INIT_REF2_W: begin
                if (wait_cnt == 0) state <= S_INIT_MRS;
                else wait_cnt <= wait_cnt - 1'b1;
            end

            // -----------------------------------------------------------------
            // S_INIT_MRS: MODE REGISTER SET
            //   Burst length=1, sequential, CAS latency=2
            //   MRS value: BA=00, A12-A10=000, A9=0(WB), A8-A7=00(standard),
            //              A6-A4=010(CL2), A3=0(sequential), A2-A0=000(BL=1)
            //   = 13'b000_0_00_010_0_000 = 0x0020
            // -----------------------------------------------------------------
            S_INIT_MRS: begin
                cmd_r  <= CMD_MRS;
                addr_r <= 13'b000_0_00_010_0_000; // CAS=2, BL=1
                ba_r   <= 2'b00;
                wait_cnt <= 3'd2;
                state  <= S_INIT_MRS_W;
            end

            S_INIT_MRS_W: begin
                if (wait_cnt == 0) state <= S_IDLE;
                else wait_cnt <= wait_cnt - 1'b1;
            end

            // -----------------------------------------------------------------
            // S_IDLE: arbitrate next command
            //   Priority: refresh > CH0 write > CH1 > CH2 > CH3 > CH4
            // -----------------------------------------------------------------
            S_IDLE: begin
                if (ref_req) begin
                    // Issue AUTO REFRESH (PRECHARGE ALL first if any row open)
                    // For simplicity, just issue AUTO_REF (requires all banks idle)
                    // In practice rows are closed after every transaction here.
                    cmd_r    <= CMD_AUTO_REF;
                    ref_req  <= 1'b0;
                    wait_cnt <= tRC_CYCLES - 1;
                    state    <= S_INIT_REF1_W; // reuse wait state → back to S_IDLE
                end
                else if (!wr_fifo_empty) begin
                    // CH0 write
                    begin
                        /* verilator lint_off UNUSEDSIGNAL */
                        automatic logic [44:0] entry = wr_fifo[wr_rptr];
                        automatic logic [25:0] waddr = entry[25:0];  // word address [26:1]
                        /* verilator lint_on UNUSEDSIGNAL */
                        wr_data  <= entry[41:26];                     // data[15:0]
                        dqm_r    <= entry[43:42];                     // dqm[1:0]
                        row_addr <= waddr[25:13];                     // row = addr[25:13]
                        col_addr <= waddr[8:0];                       // col = addr[8:0]
                        bank_sel <= waddr[10:9];                      // bank = addr[10:9] (11:9?)
                        ch_sel   <= 3'd0;
                        doing_write <= 1'b1;
                    end
                    state <= S_ACT;
                end
                else if (cpu_req_pend) begin
                    row_addr    <= cpu_addr_lat[25:13];
                    col_addr    <= cpu_addr_lat[8:0];
                    bank_sel    <= cpu_addr_lat[10:9];
                    ch_sel      <= 3'd1;
                    doing_write <= 1'b0;
                    state       <= S_ACT;
                end
                else if (gfx_req_pend) begin
                    row_addr    <= gfx_addr_lat[25:13];
                    col_addr    <= gfx_addr_lat[8:0];
                    bank_sel    <= gfx_addr_lat[10:9];
                    ch_sel      <= 3'd2;
                    doing_write <= 1'b0;
                    state       <= S_ACT;
                end
                else if (adpcm_req_pend) begin
                    row_addr    <= adpcm_addr_lat[25:13];
                    col_addr    <= adpcm_addr_lat[8:0];
                    bank_sel    <= adpcm_addr_lat[10:9];
                    ch_sel      <= 3'd3;
                    doing_write <= 1'b0;
                    state       <= S_ACT;
                end
                else if (z80_req_pend) begin
                    row_addr    <= z80_addr_lat[25:13];
                    col_addr    <= z80_addr_lat[8:0];
                    bank_sel    <= z80_addr_lat[10:9];
                    ch_sel      <= 3'd4;
                    doing_write <= 1'b0;
                    state       <= S_ACT;
                end
                // else stay in S_IDLE
            end

            // -----------------------------------------------------------------
            // S_ACT: ACTIVATE the target row
            //   If same bank+row already open, skip → go directly to READ/WRITE
            //   Otherwise issue ACTIVATE
            // -----------------------------------------------------------------
            S_ACT: begin
                if (open_valid[bank_sel] && (open_row[bank_sel] == row_addr)) begin
                    // Row already open — skip ACTIVATE+wait
                    if (doing_write) state <= S_WRITE;
                    else             state <= S_READ;
                end else begin
                    // Close any open row in this bank first (auto-precharge via A10)
                    // We always use auto-precharge on READ/WRITE to keep banks idle,
                    // so open_valid is always 0 at this point. Issue ACTIVATE.
                    cmd_r  <= CMD_ACTIVE;
                    addr_r <= row_addr;
                    ba_r   <= bank_sel;
                    open_row[bank_sel]   <= row_addr;
                    open_valid[bank_sel] <= 1'b1;
                    wait_cnt <= tRCD_CYCLES - 1;
                    state <= S_ACT_W;
                end
            end

            S_ACT_W: begin
                if (wait_cnt == 0) begin
                    if (doing_write) state <= S_WRITE;
                    else             state <= S_READ;
                end else begin
                    wait_cnt <= wait_cnt - 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // S_READ: issue READ with auto-precharge (A10=1)
            // -----------------------------------------------------------------
            S_READ: begin
                cmd_r  <= CMD_READ;
                addr_r <= {4'b0010, col_addr}; // A10=1 (auto-precharge), A9=0
                ba_r   <= bank_sel;
                dqm_out<= 2'b00;  // enable both byte lanes for read
                open_valid[bank_sel] <= 1'b0; // auto-precharge closes row
                // CAS latency=2: data valid 2 clocks after READ command
                // wait_cnt=2 → sample on 3rd cycle (READ+1+2)
                wait_cnt <= tRC_CYCLES - 1;
                state    <= S_READ_W;
            end

            S_READ_W: begin
                dqm_out <= 2'b00;
                if (wait_cnt == tRC_CYCLES - 2) begin
                    // Capture SDRAM_DQ at CAS=2 latency (2 clocks after READ command)
                    case (ch_sel)
                        3'd1: begin cpu_data_r  <= SDRAM_DQ; cpu_ack_r  <= cpu_req_clk;  end
                        3'd2: begin gfx_data_r  <= SDRAM_DQ; gfx_ack_r  <= gfx_req_clk;  end
                        3'd3: begin adpcm_data_r<= SDRAM_DQ; adpcm_ack_r<= adpcm_req_clk; end
                        3'd4: begin z80_data_r  <= SDRAM_DQ; z80_ack_r  <= z80_req_clk;  end
                        default: ; // ch0 read shouldn't happen
                    endcase
                end
                if (wait_cnt == 0) state <= S_IDLE;
                else wait_cnt <= wait_cnt - 1'b1;
            end

            // -----------------------------------------------------------------
            // S_WRITE: issue WRITE with auto-precharge (A10=1)
            // -----------------------------------------------------------------
            S_WRITE: begin
                cmd_r   <= CMD_WRITE;
                addr_r  <= {4'b0010, col_addr}; // A10=1 (auto-precharge)
                ba_r    <= bank_sel;
                dq_out  <= wr_data;
                dq_oe   <= 1'b1;
                dqm_out <= dqm_r;
                open_valid[bank_sel] <= 1'b0; // auto-precharge closes row
                wr_rptr <= wr_rptr + 1'b1;   // consume FIFO entry
                wait_cnt <= 3'(tRP_CYCLES);
                state    <= S_WRITE_W;
            end

            S_WRITE_W: begin
                // Hold data one extra cycle, then release bus
                dq_oe <= (wait_cnt == 3'(tRP_CYCLES));
                if (wait_cnt == 0) state <= S_IDLE;
                else wait_cnt <= wait_cnt - 1'b1;
            end

            default: state <= S_IDLE;
        endcase
    end
end

// =============================================================================
// Output registers (clk_sys domain) — ack mirrors req after data captured
// =============================================================================
// cpu_ack_r / gfx_ack_r / adpcm_ack_r are set in S_READ_W in the clk domain.
// They are read by the clk_sys domain; because ack = req (same toggle value)
// the 2-FF synchroniser already applied to req guarantees the consumer sees
// stable data before ack arrives.
assign cpu_data  = cpu_data_r;
assign cpu_ack   = cpu_ack_r;
assign gfx_data  = gfx_data_r;
assign gfx_ack   = gfx_ack_r;
assign adpcm_data = adpcm_data_r;
assign adpcm_ack  = adpcm_ack_r;
assign z80_data  = z80_data_r;
assign z80_ack   = z80_ack_r;

endmodule
