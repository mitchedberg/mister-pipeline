`default_nettype none
// =============================================================================
// tc0510nio.sv — TC0510NIO I/O Controller
// =============================================================================
//
// TC0510NIO provides 8 input registers and 4 output registers.
//
// Access pattern: halfword_wordswap
//   - Odd byte addresses (A0=1): data on D[15:8] (upper byte of 16-bit word)
//   - Even byte addresses (A0=0): data on D[7:0]  (lower byte of 16-bit word)
//   The 68000 bus uses word-aligned accesses, so each register access is a
//   16-bit cycle where only one byte is meaningful depending on address[1].
//
//   MAME halfword_wordswap: register index = addr >> 1 (4-bit, 0–15)
//   Read:  odd word addr  → Dout[15:8] = reg data, Dout[7:0] = 0xFF
//          even word addr → Dout[7:0] = reg data, Dout[15:8] = 0xFF
//   Write: same byte-lane mapping for outputs (regs 8–11)
//
// Register map (word address within chip window, cpu_addr[4:1]):
//   0  — P1 joystick + buttons  (input)
//   1  — P2 joystick + buttons  (input)
//   2  — Coin / Service         (input)
//   3  — System inputs          (input)
//   4  — Analog wheel  (P1)     (input)
//   5  — Analog pedal  (P1)     (input)
//   6  — Analog wheel  (P2)     (input, racingb linked-cab; tied 0xFF in dblaxle)
//   7  — Analog pedal  (P2)     (input, tied 0xFF in dblaxle)
//   8  — Output reg 0           (output — coin lockout, etc.)
//   9  — Output reg 1           (output)
//   10 — Output reg 2           (output)
//   11 — Output reg 3           (output)
//
// Mapped at 0xB00000–0xB0001F in dblaxle (32 byte window = 16 word addresses).
//
// Reference: MAME src/mame/taito/taitoio.cpp (tc0510nio_device)
//            src/mame/taito/taito_z.cpp (dblaxle_map)
// =============================================================================

module tc0510nio (
    input  logic        clk,
    input  logic        reset_n,

    // CPU bus interface (word address within chip window, 4-bit)
    input  logic        cs_n,           // chip select (active low)
    input  logic        we,             // write enable (cpu_rw=0 → we=1)
    input  logic [ 3:0] addr,           // word address [4:1] within window
    input  logic [15:0] din,            // CPU write data
    input  logic [ 1:0] be,             // byte enables: [1]=UDS, [0]=LDS
    output logic [15:0] dout,           // CPU read data (register output)

    // Input signals
    input  logic [ 7:0] joystick_p1,    // P1 joystick + buttons (active low)
    input  logic [ 7:0] joystick_p2,    // P2 joystick + buttons (active low)
    input  logic [ 1:0] coin,           // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service,        // service button (active low)
    input  logic [ 7:0] wheel,          // steering wheel analog (P1)
    input  logic [ 7:0] pedal,          // gas pedal analog (P1)

    // Output registers (coin lockout, etc. — drive to mechanical outputs)
    output logic [ 7:0] out_reg [0:3]
);

// Input register array (read-only, directly from input ports)
logic [7:0] in_reg [0:7];

always_comb begin
    in_reg[0] = joystick_p1;
    in_reg[1] = joystick_p2;
    in_reg[2] = {4'hF, 1'b1, service, coin[1], coin[0]};  // {unused, TILT, SVC, COIN2, COIN1}
    in_reg[3] = 8'hFF;                                      // system inputs (tied off)
    in_reg[4] = wheel;
    in_reg[5] = pedal;
    in_reg[6] = 8'hFF;                                      // P2 wheel (not used in dblaxle)
    in_reg[7] = 8'hFF;                                      // P2 pedal (not used in dblaxle)
end

// Output registers (writable by CPU)
always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        for (int i = 0; i < 4; i++)
            out_reg[i] <= 8'hFF;
    end else if (!cs_n && we) begin
        if (addr >= 4'd8 && addr <= 4'd11) begin
            // halfword_wordswap: upper byte active on odd addr, lower on even
            // addr[0]: word addr bit 0 → determines which byte holds data
            if (addr[0]) begin
                // odd word address — data in upper byte D[15:8]
                if (be[1]) out_reg[2'(addr - 4'd8)] <= din[15:8];
            end else begin
                // even word address — data in lower byte D[7:0]
                if (be[0]) out_reg[2'(addr - 4'd8)] <= din[7:0];
            end
        end
    end
end

// Read path: input regs 0–7, output regs 8–11
// halfword_wordswap: odd word addr → data on D[15:8]; even → D[7:0]
always_comb begin
    dout = 16'hFFFF;    // open bus default
    if (!cs_n) begin
        if (addr <= 4'd7) begin
            // Input register read
            if (addr[0])
                dout = {in_reg[3'(addr)], 8'hFF};       // odd: upper byte
            else
                dout = {8'hFF, in_reg[3'(addr)]};       // even: lower byte
        end else if (addr <= 4'd11) begin
            // Output register read-back
            if (addr[0])
                dout = {out_reg[2'(addr - 4'd8)], 8'hFF};
            else
                dout = {8'hFF, out_reg[2'(addr - 4'd8)]};
        end
    end
end

endmodule
