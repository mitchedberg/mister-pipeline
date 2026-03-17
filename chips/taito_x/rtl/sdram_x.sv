`default_nettype none
// =============================================================================
// sdram_x.sv — SDRAM Controller Stub for Taito X
// =============================================================================
//
// Provides three read channels to the taito_x_colmix and emu.sv:
//   CH0: ioctl write path (ROM download from HPS)
//   CH1: CPU program ROM reads  (68000, 0x000000–0x07FFFF)
//   CH2: GFX ROM reads          (X1-001A, gfx_addr[17:0])
//   CH3: Z80 audio ROM reads    (Z80, 0x0000–0x7FFF)
//
// This is a STUB that satisfies the port contract for lint and simulation.
// Replace with a real SDRAM controller (e.g. the one used in taito_b/taito_z)
// for synthesis.
//
// Toggle-handshake protocol (same as taito_z sdram_z):
//   Requester toggles req → asserts addr.
//   Controller returns data, toggles ack to match req.
//
// Simulation behaviour: returns 0x0000 for all reads with 2-cycle latency.
//
// SDRAM layout (byte addresses, IS42S16320F-6TL 32 MB):
//   0x000000 – 0x07FFFF    512KB   68000 program ROM
//   0x080000 – 0x09FFFF    128KB   Z80 audio program
//   0x0A0000 – 0x0FFFFF    (pad to 1MB boundary)
//   0x100000 – 0x4FFFFF      4MB   Sprite / Tile GFX ROM (X1-001A)
//   0x500000 – 0x5FFFFF    (spare)
// =============================================================================

module sdram_x (
    // ── Clocks ────────────────────────────────────────────────────────────────
    input  logic        clk,        // 143 MHz SDRAM clock
    input  logic        clk_sys,    // 32 MHz system clock
    input  logic        reset_n,

    // ── CH0: HPS ROM download write path ─────────────────────────────────────
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic  [7:0] ioctl_dout,

    // ── CH1: CPU program ROM reads ────────────────────────────────────────────
    input  logic [26:0] cpu_addr,
    output logic [15:0] cpu_data,
    input  logic        cpu_req,
    output logic        cpu_ack,

    // ── CH2: GFX ROM reads (X1-001A, 16-bit word) ─────────────────────────────
    input  logic [26:0] gfx_addr,
    output logic [15:0] gfx_data,
    input  logic        gfx_req,
    output logic        gfx_ack,

    // ── CH3: Z80 audio ROM reads ───────────────────────────────────────────────
    input  logic [26:0] z80_addr,
    output logic [15:0] z80_data,
    input  logic        z80_req,
    output logic        z80_ack,

    // ── SDRAM chip pins (IS42S16320F-6TL) ────────────────────────────────────
    output logic [12:0] SDRAM_A,
    output logic  [1:0] SDRAM_BA,
    inout  logic [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);

    // ── SDRAM chip pins: stub (tri-state / inactive) ─────────────────────────
    assign SDRAM_A    = 13'b0;
    assign SDRAM_BA   = 2'b11;    // deselect
    assign SDRAM_DQ   = 16'bZ;
    assign SDRAM_DQML = 1'b1;
    assign SDRAM_DQMH = 1'b1;
    assign SDRAM_nCS  = 1'b1;     // chip deselected
    assign SDRAM_nCAS = 1'b1;
    assign SDRAM_nRAS = 1'b1;
    assign SDRAM_nWE  = 1'b1;
    assign SDRAM_CKE  = 1'b1;

    // ── Stub read responses: 2-cycle latency, return 0xFFFF ───────────────────
    // In simulation the CPU will see open-bus data (0xFFFF) for all ROM reads.
    // A real controller would return actual SDRAM contents.

    // CPU channel
    logic cpu_req_r;
    always_ff @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) begin
            cpu_ack  <= 1'b0;
            cpu_data <= 16'hFFFF;
            cpu_req_r <= 1'b0;
        end else begin
            cpu_req_r <= cpu_req;
            if (cpu_req != cpu_req_r) begin
                cpu_data <= 16'hFFFF;
                cpu_ack  <= cpu_req;   // echo req as ack
            end
        end
    end

    // GFX channel
    logic gfx_req_r;
    always_ff @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) begin
            gfx_ack  <= 1'b0;
            gfx_data <= 16'hFFFF;
            gfx_req_r <= 1'b0;
        end else begin
            gfx_req_r <= gfx_req;
            if (gfx_req != gfx_req_r) begin
                gfx_data <= 16'h0000;   // GFX ROM returns pixel data; 0 = transparent tile
                gfx_ack  <= gfx_req;
            end
        end
    end

    // Z80 channel
    logic z80_req_r;
    always_ff @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n) begin
            z80_ack  <= 1'b0;
            z80_data <= 16'hFFFF;
            z80_req_r <= 1'b0;
        end else begin
            z80_req_r <= z80_req;
            if (z80_req != z80_req_r) begin
                z80_data <= 16'hFFFF;
                z80_ack  <= z80_req;
            end
        end
    end

    // ── Suppress unused ports ─────────────────────────────────────────────────
    /* verilator lint_off UNUSED */
    logic _unused;
    assign _unused = ^{clk, ioctl_wr, ioctl_addr, ioctl_dout,
                       cpu_addr, gfx_addr, z80_addr};
    /* verilator lint_on UNUSED */

endmodule
