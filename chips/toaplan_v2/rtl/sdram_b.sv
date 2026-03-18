`default_nettype none
// =============================================================================
// sdram_b.sv — SDRAM controller for Taito B MiSTer core
// =============================================================================
//
// Wraps a 16Mx16 IS42S16320F (32 MB) SDRAM chip at up to 143 MHz.
// Provides four access channels:
//
//   CH0  ioctl write    — HPS ROM download (sequential, byte-wide input)
//   CH1  cpu read       — MC68000 program ROM reads (16-bit, toggle-handshake)
//   CH2  gfx read       — TC0180VCU tile GFX ROM (16-bit, toggle)
//   CH3  adpcm read     — TC0140SYT ADPCM samples (16-bit, toggle)
//
// Arbitration priority: CH0 (write) > CH1 > CH2 > CH3
//
// SDRAM layout (Taito B nastar default, from taito_b.sv comments):
//   0x000000    512KB    MC68000 program ROM
//   0x080000    256KB    Z80 audio program ROM
//   0x0C0000    128KB    (pad to 1MB boundary)
//   0x100000    1MB      TC0180VCU GFX ROM
//   0x200000    512KB    ADPCM-A samples
//   0x280000    512KB    ADPCM-B samples
//   0x300000    ...      (future: additional ROMs per game layout)
//   Total: ~2MB typical
//
// SDRAM timing (IS42S16320F @ 143 MHz, CAS=3):
//   tRCD=2, tRP=2, tRC=7, CAS=3
//   Refresh every 64 ms / 8192 rows = 7.8 µs → every 1115 clocks @ 143 MHz
//
// Notes:
//   - CH1: 16-bit CPU ROM reads (single 16-bit SDRAM word per request)
//   - CH2: 16-bit GFX reads for TC0180VCU (byte-fetches packed into 16-bit reads)
//   - CH3: 16-bit ADPCM ROM reads for TC0140SYT
//   - All read channels use toggle-handshake: req toggles to request;
//     ack mirrors req when data is valid.
// =============================================================================

module sdram_b (
    // System
    input  logic        clk,        // SDRAM clock (143 MHz from PLL)
    input  logic        clk_sys,    // System clock (used for ioctl sync)
    input  logic        reset_n,

    // ── CH0: HPS ROM download (write path) ────────────────────────────────────
    input  logic        ioctl_wr,       // write strobe (one-cycle pulse, clk_sys domain)
    input  logic [26:0] ioctl_addr,     // byte address
    input  logic  [7:0] ioctl_dout,     // byte data from HPS

    // ── CH1: CPU program ROM (16-bit reads) ───────────────────────────────────
    input  logic [26:0] cpu_addr,       // byte address
    output logic [15:0] cpu_data,       // 16-bit read result
    input  logic        cpu_req,        // toggle to request
    output logic        cpu_ack,        // mirrors req when data valid

    // ── CH2: GFX ROM (16-bit reads) ───────────────────────────────────────────
    input  logic [26:0] gfx_addr,       // byte address into SDRAM
    output logic [15:0] gfx_data,
    input  logic        gfx_req,
    output logic        gfx_ack,

    // ── CH3: ADPCM ROM (16-bit reads) ────────────────────────────────────────
    input  logic [26:0] adpcm_addr,     // byte address into SDRAM
    output logic [15:0] adpcm_data,
    input  logic        adpcm_req,
    output logic        adpcm_ack,

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

    // ========================================================================
    // STUB IMPLEMENTATION FOR SIMULATION
    // ========================================================================
    // This is a simplified stub that:
    //   - Accepts toggle-handshake requests
    //   - Returns dummy data with 2-cycle latency
    //   - Mirrors requests as acknowledgments
    //   - Does NOT perform actual SDRAM timing (CAS, tRC, refresh, etc.)
    //
    // For synthesis, replace with full SDRAM controller IP or custom RTL.
    // ========================================================================

    // Simple toggle-handshake read channels with 2-cycle response latency
    logic [15:0] cpu_data_r;
    logic [15:0] gfx_data_r;
    logic [15:0] adpcm_data_r;

    logic        cpu_req_r,  cpu_ack_r;
    logic        gfx_req_r,  gfx_ack_r;
    logic        adpcm_req_r, adpcm_ack_r;

    // ── CH1: CPU reads ────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cpu_req_r  <= 1'b0;
            cpu_ack_r  <= 1'b0;
            cpu_data_r <= 16'h0000;
        end else begin
            cpu_req_r <= cpu_req;
            if (cpu_req != cpu_req_r) begin
                // New request detected; respond after 2 cycles
                cpu_data_r <= {cpu_addr[16:9], cpu_addr[8:1]};  // dummy pattern
                cpu_ack_r  <= ~cpu_ack_r;  // toggle ack
            end
        end
    end
    assign cpu_data = cpu_data_r;
    assign cpu_ack  = cpu_ack_r;

    // ── CH2: GFX reads ────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            gfx_req_r  <= 1'b0;
            gfx_ack_r  <= 1'b0;
            gfx_data_r <= 16'h0000;
        end else begin
            gfx_req_r <= gfx_req;
            if (gfx_req != gfx_req_r) begin
                gfx_data_r <= {gfx_addr[16:9], gfx_addr[8:1]};
                gfx_ack_r  <= ~gfx_ack_r;
            end
        end
    end
    assign gfx_data = gfx_data_r;
    assign gfx_ack  = gfx_ack_r;

    // ── CH3: ADPCM reads ──────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            adpcm_req_r  <= 1'b0;
            adpcm_ack_r  <= 1'b0;
            adpcm_data_r <= 16'h0000;
        end else begin
            adpcm_req_r <= adpcm_req;
            if (adpcm_req != adpcm_req_r) begin
                adpcm_data_r <= {adpcm_addr[16:9], adpcm_addr[8:1]};
                adpcm_ack_r  <= ~adpcm_ack_r;
            end
        end
    end
    assign adpcm_data = adpcm_data_r;
    assign adpcm_ack  = adpcm_ack_r;

    // ── SDRAM outputs (stub) ──────────────────────────────────────────────────
    // For simulation, tie off the SDRAM control pins (all inactive by default).
    // Real synthesis will drive these with actual memory controller logic.
    assign SDRAM_nCS  = 1'b1;   // chip select inactive
    assign SDRAM_nRAS = 1'b1;   // RAS inactive
    assign SDRAM_nCAS = 1'b1;   // CAS inactive
    assign SDRAM_nWE  = 1'b1;   // write enable inactive
    assign SDRAM_CKE  = 1'b0;   // clock enable (keep low for low power)
    assign SDRAM_DQML = 1'b1;   // both data mask bits inactive
    assign SDRAM_DQMH = 1'b1;

    // Address and bank select (don't care in stub)
    assign SDRAM_A  = 13'h0;
    assign SDRAM_BA = 2'b00;

    // Data bus (high-Z in stub; real controller will drive/read)
    assign SDRAM_DQ = 16'hZZZZ;

    // Suppress lint warnings for stub inputs
    logic _unused = &{clk_sys, ioctl_wr, ioctl_addr, ioctl_dout, cpu_addr[26:17], cpu_addr[0],
                       gfx_addr[26:17], gfx_addr[0], adpcm_addr[26:17], adpcm_addr[0], 1'b0};

endmodule
