`default_nettype none
// =============================================================================
// taito_f3_gfx_arbiter.sv — GFX ROM 4-stream → 2-port SDRAM arbiter
// =============================================================================
//
// TC0630FDP issues up to 4 independent GFX ROM read streams:
//   spr_lo  — sprite low  4bpp planes (8MB, SDRAM base SPR_LO_BASE)
//   spr_hi  — sprite high 2bpp planes (4MB, SDRAM base SPR_HI_BASE)
//   til_lo  — tilemap low  4bpp planes (4MB, SDRAM base TILE_LO_BASE)
//   til_hi  — tilemap high 2bpp planes (2MB, SDRAM base TILE_HI_BASE)
//
// The two SDRAM read ports (A and B) use a toggle-handshake protocol:
//   requestor toggles sdram_x_req; controller replies with sdram_x_ack == sdram_x_req
//   when data is valid on sdram_x_data.
//
// Arbitration policy:
//   Port A serves spr_lo (priority 0) and til_lo (priority 1)
//   Port B serves spr_hi (priority 0) and til_hi (priority 1)
//
//   Within each port, the higher-priority stream wins on simultaneous requests;
//   the lower-priority stream is queued and served next.
//   Each port uses a 2-state FSM: IDLE → WAIT_ACK.
//
// SDRAM word addressing:
//   Callers present byte addresses.  SDRAM ports are 16-bit wide (1 word = 2 bytes).
//   Byte address → SDRAM word address: right-shift by 1; byte LSB is dropped here
//   (caller selects byte lane from the returned 16-bit word).
//   The SDRAM base parameter is added in word-address space.
//
// Request protocol (per stream):
//   spr_lo_req  — level-sensitive: hold high for one request
//   spr_lo_ack  — one-cycle pulse when spr_lo_data is valid
//   Caller must deassert req before the next cycle after ack, or issue a new
//   (different) address while holding req to trigger the next edge-detect.
//
// Reference: chips/taito_f3/integration_plan.md §4 (SDRAM layout)
// =============================================================================

module taito_f3_gfx_arbiter #(
    // SDRAM base word-addresses for each ROM region (27-bit word space).
    // Defaults match integration_plan.md §4 layout, converted to word addresses
    // (byte offset / 2):  sprites @ 0x200000 → 0x100000 word, etc.
    parameter logic [26:0] SPR_LO_BASE  = 27'h0100000,   // sprites lo  (byte 0x0200000)
    parameter logic [26:0] SPR_HI_BASE  = 27'h0500000,   // sprites hi  (byte 0x0A00000)
    parameter logic [26:0] TILE_LO_BASE = 27'h0700000,   // tilemap lo  (byte 0x0E00000)
    parameter logic [26:0] TILE_HI_BASE = 27'h0900000    // tilemap hi  (byte 0x1200000)
) (
    input  logic        clk,
    input  logic        reset_n,

    // ── GFX stream ports (from TC0630FDP / top level) ─────────────────────────
    // Byte addresses within each ROM region; level-sensitive req / pulse ack.

    // spr_lo — sprite low 4bpp (up to 8MB → 23-bit byte addr)
    input  logic [22:0] spr_lo_addr,
    input  logic        spr_lo_req,
    output logic [15:0] spr_lo_data,
    output logic        spr_lo_ack,

    // spr_hi — sprite high 2bpp (up to 4MB → 22-bit byte addr)
    input  logic [21:0] spr_hi_addr,
    input  logic        spr_hi_req,
    output logic [15:0] spr_hi_data,
    output logic        spr_hi_ack,

    // til_lo — tilemap low 4bpp (up to 4MB → 22-bit byte addr)
    input  logic [21:0] til_lo_addr,
    input  logic        til_lo_req,
    output logic [15:0] til_lo_data,
    output logic        til_lo_ack,

    // til_hi — tilemap high 2bpp (up to 2MB → 21-bit byte addr)
    input  logic [20:0] til_hi_addr,
    input  logic        til_hi_req,
    output logic [15:0] til_hi_data,
    output logic        til_hi_ack,

    // ── SDRAM Port A (serves spr_lo + til_lo) ────────────────────────────────
    output logic [26:0] sdram_a_addr,
    output logic        sdram_a_req,
    input  logic [15:0] sdram_a_data,
    input  logic        sdram_a_ack,

    // ── SDRAM Port B (serves spr_hi + til_hi) ────────────────────────────────
    output logic [26:0] sdram_b_addr,
    output logic        sdram_b_req,
    input  logic [15:0] sdram_b_data,
    input  logic        sdram_b_ack
);

// =============================================================================
// FSM state encoding (1 bit per port)
// =============================================================================
localparam logic S_IDLE     = 1'b0;
localparam logic S_WAIT_ACK = 1'b1;

// Client token: which stream is active on a port
localparam logic CLIENT_A = 1'b0;   // port A: spr_lo;  port B: spr_hi
localparam logic CLIENT_B = 1'b1;   // port A: til_lo;  port B: til_hi

// =============================================================================
// Port A — spr_lo (high priority) + til_lo (lower priority)
// =============================================================================
logic        pa_state;
logic        pa_client;
logic [15:0] pa_data_r;

// Pending flags: request received but port busy
logic        pa_spr_lo_pend;
logic        pa_til_lo_pend;

// Ack pulses (one clock wide)
logic        pa_spr_lo_ack_r;
logic        pa_til_lo_ack_r;

// Registered request levels for rising-edge detection
logic        spr_lo_req_r;
logic        til_lo_req_r;

// Saved addresses (captured on rising edge of req)
logic [22:0] pa_spr_lo_addr_r;
logic [21:0] pa_til_lo_addr_r;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        pa_state           <= S_IDLE;
        pa_client          <= CLIENT_A;
        pa_data_r          <= 16'h0;
        pa_spr_lo_pend     <= 1'b0;
        pa_til_lo_pend     <= 1'b0;
        pa_spr_lo_ack_r    <= 1'b0;
        pa_til_lo_ack_r    <= 1'b0;
        spr_lo_req_r       <= 1'b0;
        til_lo_req_r       <= 1'b0;
        pa_spr_lo_addr_r   <= 23'b0;
        pa_til_lo_addr_r   <= 22'b0;
        sdram_a_addr       <= 27'b0;
        sdram_a_req        <= 1'b0;
    end else begin
        // Default: acks are one-cycle pulses
        pa_spr_lo_ack_r <= 1'b0;
        pa_til_lo_ack_r <= 1'b0;

        // Rising-edge detection and address capture
        spr_lo_req_r <= spr_lo_req;
        til_lo_req_r <= til_lo_req;

        if (spr_lo_req && !spr_lo_req_r) begin
            pa_spr_lo_pend   <= 1'b1;
            pa_spr_lo_addr_r <= spr_lo_addr;
        end
        if (til_lo_req && !til_lo_req_r) begin
            pa_til_lo_pend   <= 1'b1;
            pa_til_lo_addr_r <= til_lo_addr;
        end

        case (pa_state)

            S_IDLE: begin
                // spr_lo has priority
                if (pa_spr_lo_pend) begin
                    sdram_a_addr   <= SPR_LO_BASE + {4'b0, pa_spr_lo_addr_r[22:1]};
                    sdram_a_req    <= ~sdram_a_req;
                    pa_client      <= CLIENT_A;
                    pa_spr_lo_pend <= 1'b0;
                    pa_state       <= S_WAIT_ACK;
                end else if (pa_til_lo_pend) begin
                    sdram_a_addr   <= TILE_LO_BASE + {5'b0, pa_til_lo_addr_r[21:1]};
                    sdram_a_req    <= ~sdram_a_req;
                    pa_client      <= CLIENT_B;
                    pa_til_lo_pend <= 1'b0;
                    pa_state       <= S_WAIT_ACK;
                end
            end

            S_WAIT_ACK: begin
                if (sdram_a_req == sdram_a_ack) begin
                    pa_data_r <= sdram_a_data;
                    if (pa_client == CLIENT_A)
                        pa_spr_lo_ack_r <= 1'b1;
                    else
                        pa_til_lo_ack_r <= 1'b1;
                    pa_state <= S_IDLE;
                end
            end

            default: pa_state <= S_IDLE;

        endcase
    end
end

// =============================================================================
// Port B — spr_hi (high priority) + til_hi (lower priority)
// =============================================================================
logic        pb_state;
logic        pb_client;
logic [15:0] pb_data_r;

logic        pb_spr_hi_pend;
logic        pb_til_hi_pend;

logic        pb_spr_hi_ack_r;
logic        pb_til_hi_ack_r;

logic        spr_hi_req_r;
logic        til_hi_req_r;

logic [21:0] pb_spr_hi_addr_r;
logic [20:0] pb_til_hi_addr_r;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        pb_state           <= S_IDLE;
        pb_client          <= CLIENT_A;
        pb_data_r          <= 16'h0;
        pb_spr_hi_pend     <= 1'b0;
        pb_til_hi_pend     <= 1'b0;
        pb_spr_hi_ack_r    <= 1'b0;
        pb_til_hi_ack_r    <= 1'b0;
        spr_hi_req_r       <= 1'b0;
        til_hi_req_r       <= 1'b0;
        pb_spr_hi_addr_r   <= 22'b0;
        pb_til_hi_addr_r   <= 21'b0;
        sdram_b_addr       <= 27'b0;
        sdram_b_req        <= 1'b0;
    end else begin
        pb_spr_hi_ack_r <= 1'b0;
        pb_til_hi_ack_r <= 1'b0;

        spr_hi_req_r <= spr_hi_req;
        til_hi_req_r <= til_hi_req;

        if (spr_hi_req && !spr_hi_req_r) begin
            pb_spr_hi_pend   <= 1'b1;
            pb_spr_hi_addr_r <= spr_hi_addr;
        end
        if (til_hi_req && !til_hi_req_r) begin
            pb_til_hi_pend   <= 1'b1;
            pb_til_hi_addr_r <= til_hi_addr;
        end

        case (pb_state)

            S_IDLE: begin
                // spr_hi has priority
                if (pb_spr_hi_pend) begin
                    sdram_b_addr   <= SPR_HI_BASE + {5'b0, pb_spr_hi_addr_r[21:1]};
                    sdram_b_req    <= ~sdram_b_req;
                    pb_client      <= CLIENT_A;
                    pb_spr_hi_pend <= 1'b0;
                    pb_state       <= S_WAIT_ACK;
                end else if (pb_til_hi_pend) begin
                    sdram_b_addr   <= TILE_HI_BASE + {6'b0, pb_til_hi_addr_r[20:1]};
                    sdram_b_req    <= ~sdram_b_req;
                    pb_client      <= CLIENT_B;
                    pb_til_hi_pend <= 1'b0;
                    pb_state       <= S_WAIT_ACK;
                end
            end

            S_WAIT_ACK: begin
                if (sdram_b_req == sdram_b_ack) begin
                    pb_data_r <= sdram_b_data;
                    if (pb_client == CLIENT_A)
                        pb_spr_hi_ack_r <= 1'b1;
                    else
                        pb_til_hi_ack_r <= 1'b1;
                    pb_state <= S_IDLE;
                end
            end

            default: pb_state <= S_IDLE;

        endcase
    end
end

// =============================================================================
// Output data registers (held stable between requests)
// =============================================================================
always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        spr_lo_data <= 16'h0;
        til_lo_data <= 16'h0;
        spr_hi_data <= 16'h0;
        til_hi_data <= 16'h0;
    end else begin
        if (pa_spr_lo_ack_r) spr_lo_data <= pa_data_r;
        if (pa_til_lo_ack_r) til_lo_data <= pa_data_r;
        if (pb_spr_hi_ack_r) spr_hi_data <= pb_data_r;
        if (pb_til_hi_ack_r) til_hi_data <= pb_data_r;
    end
end

// =============================================================================
// Ack outputs
// =============================================================================
assign spr_lo_ack = pa_spr_lo_ack_r;
assign til_lo_ack = pa_til_lo_ack_r;
assign spr_hi_ack = pb_spr_hi_ack_r;
assign til_hi_ack = pb_til_hi_ack_r;

// =============================================================================
// Unused signal suppression
// Byte LSBs of each address are dropped when converting to SDRAM word address
// (address[0] selects the byte lane within the 16-bit word — handled by caller).
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{spr_lo_addr[0],    spr_hi_addr[0],    til_lo_addr[0],    til_hi_addr[0],
                   pa_spr_lo_addr_r[0], pa_til_lo_addr_r[0],
                   pb_spr_hi_addr_r[0], pb_til_hi_addr_r[0]};
/* verilator lint_on UNUSED */

endmodule
