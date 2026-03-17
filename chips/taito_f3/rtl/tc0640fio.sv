`default_nettype none
// =============================================================================
// TC0640FIO — Taito F3 I/O Controller
// =============================================================================
// Implements the TC0640FIO function as a simple register file.
//
// Register map (byte offsets 0x00–0x1F → 4-bit word offset addr[3:0]):
//
//   Read registers (cpu_rw=1):
//     addr 0x0: IN.0 — P1+P2 buttons, test/service, EEPROM DOUT
//     addr 0x1: IN.1 — P1+P2 joystick (active-low 8-way)
//     addr 0x2: IN.2 — analog channel 1 (tie 0 for digital-only games)
//     addr 0x3: IN.3 — analog channel 2
//     addr 0x4: IN.4 — P3+P4 buttons (4-player games; tie 0)
//     addr 0x5: IN.5 — P3+P4 joystick (4-player games; tie 0)
//
//   Write registers (cpu_rw=0):
//     addr 0x0: Watchdog reset (write any value)
//     addr 0x1: Coin lockout/counters P1/P2
//     addr 0x4: EEPROM control (bits: DI, CLK, CS)
//     addr 0x5: Coin lockout/counters P3/P4
//
// MAME source: taito_f3.cpp — f3_control_r / f3_control_w
// Data bus: The 68EC020 does 32-bit accesses. Input data appears on
//           the upper word (bits[31:16]) of the 32-bit read data per
//           MAME's address_map UINT32 access conventions; supply on [31:0].
// =============================================================================

module tc0640fio (
    input  logic        clk,
    input  logic        rst_n,

    // ── CPU Interface (68EC020, 32-bit) ──────────────────────────────────────
    input  logic        cs_n,           // chip select (active low)
    input  logic        we,             // write enable (1=write)
    input  logic [3:0]  addr,           // register select: cpu_addr[4:1]
    input  logic [31:0] din,            // CPU write data
    output logic [31:0] dout,           // CPU read data

    // ── Input Ports ──────────────────────────────────────────────────────────
    // All inputs are active-low per F3 hardware convention.
    // in0: {EEPROM_DOUT, test, service, P2_btn[3:0], P1_btn[3:0]} — tied externally
    // in1: {P2_joy[3:0]=UP/DN/L/R, P1_joy[3:0]=UP/DN/L/R} in bits [7:0]
    input  logic [31:0] in0,            // buttons + test/service
    input  logic [31:0] in1,            // joystick directions
    input  logic [31:0] in2,            // analog 1 (tie 32'hFFFFFFFF if unused)
    input  logic [31:0] in3,            // analog 2 (tie 32'hFFFFFFFF if unused)
    input  logic [31:0] in4,            // P3+P4 buttons (tie 32'hFFFFFFFF if unused)
    input  logic [31:0] in5,            // P3+P4 joystick (tie 32'hFFFFFFFF if unused)

    // ── EEPROM Serial Interface ───────────────────────────────────────────────
    // 93C46-compatible 3-wire serial interface.
    // Bit positions within write register at addr 0x4 (from MAME f3_control_w):
    //   bit[20] = EEPROM DI  (data to EEPROM)
    //   bit[24] = EEPROM CLK (serial clock)
    //   bit[28] = EEPROM CS  (chip select)
    input  logic        eeprom_do,      // serial data from EEPROM
    output logic        eeprom_di,      // serial data to EEPROM
    output logic        eeprom_clk,     // serial clock
    output logic        eeprom_cs,      // chip select

    // ── Coin / Lock Outputs (unused in MiSTer; expose for completeness) ──────
    output logic [1:0]  coin_lock,      // coin lockout solenoids [P2,P1]
    output logic [1:0]  coin_ctr        // coin counters [P2,P1]
);

// =============================================================================
// Write-side registers
// =============================================================================
// EEPROM control register (addr 0x4):
//   bit[28] = CS, bit[24] = CLK, bit[20] = DI
logic [31:0] eeprom_ctrl_r;

// Coin/lock registers (addr 0x1, addr 0x5):
//   bits[3:0]  = coin lockout P1/P2
//   bits[27:24] = coin counters (in MAME's implementation)
logic [31:0] coin_ctrl_r;   // P1/P2 (addr 0x1)

always_ff @(posedge clk) begin
    if (!rst_n) begin
        eeprom_ctrl_r <= 32'h0;
        coin_ctrl_r   <= 32'h0;
    end else if (!cs_n && we) begin
        case (addr)
            4'd0: ;                          // watchdog — write strobe only, no state
            4'd1: coin_ctrl_r   <= din;
            4'd4: eeprom_ctrl_r <= din;
            4'd5: ;                          // P3/P4 coin control (mirror, not stored)
            default: ;
        endcase
    end
end

// =============================================================================
// EEPROM output decode
// =============================================================================
// EEPROM DI/CLK/CS extracted from write register at addr 0x4.
// EEPROM DOUT (eeprom_do) is ORed into IN.0 bit[23] for CPU readback.
assign eeprom_cs  = eeprom_ctrl_r[28];
assign eeprom_clk = eeprom_ctrl_r[24];
assign eeprom_di  = eeprom_ctrl_r[20];

// =============================================================================
// Coin lock / counter outputs
// =============================================================================
assign coin_lock = coin_ctrl_r[1:0];
assign coin_ctr  = coin_ctrl_r[3:2];

// =============================================================================
// Read mux
// =============================================================================
// The F3 68EC020 reads these registers as 32-bit longwords.
// IN.0 bit[23] = EEPROM DOUT (eeprom_do, active high, injected here).
// All other input bits come from the in[0..5] ports.

always_comb begin
    dout = 32'hFFFF_FFFF;   // open-bus default (active-low inputs → all high = no input)
    if (!cs_n && !we) begin
        case (addr)
            4'd0: dout = {in0[31:24], eeprom_do, in0[22:0]};  // inject EEPROM DOUT at bit[23]
            4'd1: dout = in1;
            4'd2: dout = in2;
            4'd3: dout = in3;
            4'd4: dout = in4;
            4'd5: dout = in5;
            default: dout = 32'hFFFF_FFFF;
        endcase
    end
end

// =============================================================================
// Unused register bits suppression
// =============================================================================
// eeprom_ctrl_r: only bits 28, 24, 20 are used (CS, CLK, DI).
// coin_ctrl_r: only bits 3:0 are used (lock[1:0] + ctr[1:0]).
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{eeprom_ctrl_r[31:29], eeprom_ctrl_r[27:25],
                   eeprom_ctrl_r[23:21], eeprom_ctrl_r[19:0],
                   coin_ctrl_r[31:4], in0[23]};   // in0[23] intentionally replaced by eeprom_do
/* verilator lint_on UNUSED */

endmodule
