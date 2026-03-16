`default_nettype none
// =============================================================================
// TC0630FDP — Line RAM Parser  (Step 5: rowscroll + enable bits only)
// =============================================================================
// The Line RAM is 64 KB (32768 × 16-bit words) that provides per-scanline
// override of virtually every display parameter.  This module:
//   · Owns the Line RAM BRAM (32K words).
//   · Handles CPU reads and writes.
//   · At every HBLANK falling-edge (hblank_fall), reads the next scanline's
//     rowscroll values (PF1–PF4) and their enable bits, and registers them
//     so that the BG tilemap engines can consume them during the next active
//     scan.
//
// Step 5 implementation: rowscroll + rowscroll-enable + alt-tilemap enable.
// Everything else is parsed but not output (will be added in later steps).
//
// Address layout — chip-relative 16-bit WORD addresses within Line RAM BRAM
// (convert from section1 byte addresses by dividing by 2):
//
//   Enable/latch control (lower half, word addrs 0x0000–0x1FFF):
//     Rowscroll enable base  : byte 0x0C00 → word 0x0600  (256 scanlines)
//     Colscroll/alt-tmap en  : byte 0x0000 → word 0x0000  (256 scanlines)
//
//   Per-scanline data (upper half, word addrs 0x2000–0x7FFF):
//     Colscroll PF1–PF4 base : byte 0x4000 → word 0x2000  (stride 0x100 per PF)
//     Rowscroll PF1–PF4 base : byte 0xA000 → word 0x5000  (stride 0x100 per PF)
//
// section1 §9.1 rowscroll enable:
//   word_addr = 0x0600 + scan,  bits[3:0] = enable per PF (PF1=bit0..PF4=bit3)
//
// section1 §9.1 colscroll/alt-tilemap enable:
//   word_addr = 0x0000 + scan,  bits[7:4] = alt-tmap enable per PF
//
// section1 §9.11 rowscroll data:
//   PFn (n=0..3): word_addr = 0x5000 + n*0x100 + scan
//
// section1 §9.2 colscroll data (bit[9] = alt-tilemap flag):
//   PFn (n=0..3): word_addr = 0x2000 + n*0x100 + scan
// =============================================================================

module tc0630fdp_lineram (
    input  logic        clk,
    input  logic        rst_n,

    // ── CPU Interface ─────────────────────────────────────────────────────────
    input  logic        cpu_cs,         // chip-select (active high)
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic [15:1] cpu_addr,       // 15-bit word address within Line RAM
    input  logic [15:0] cpu_din,        // write data
    input  logic [ 1:0] cpu_be,         // byte enables [1]=upper, [0]=lower
    output logic [15:0] cpu_dout,       // read data

    // ── Video Timing ──────────────────────────────────────────────────────────
    input  logic [ 8:0] vpos,           // current scanline (0..261)
    input  logic        hblank_fall,    // single-cycle pulse at end of active scan

    // ── Per-scanline outputs (registered at hblank_fall, valid for vpos+1) ─────
    // rowscroll[n]: X-scroll addition for PF(n+1) on the next scanline.
    // Zero when rowscroll is disabled for that PF.
    output logic [15:0] ls_rowscroll   [0:3],
    // alt_tilemap[n]: 1 → PF(n+1) reads tile data from +0x1800 offset in PF RAM.
    output logic        ls_alt_tilemap [0:3]
);

// =============================================================================
// Line RAM: 32768 × 16-bit words (64 KB simulation BRAM)
// =============================================================================
logic [15:0] line_ram [0:32767];

// =============================================================================
// CPU write port
// =============================================================================
always_ff @(posedge clk) begin
    if (cpu_cs && !cpu_rw) begin
        if (cpu_be[1]) line_ram[cpu_addr[15:1]][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) line_ram[cpu_addr[15:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

// =============================================================================
// CPU read port (registered, one-cycle latency)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n)
        cpu_dout <= 16'b0;
    else if (cpu_cs && cpu_rw)
        cpu_dout <= line_ram[cpu_addr[15:1]];
end

// =============================================================================
// HBLANK parser
// =============================================================================
// Scanline index for the NEXT visible line (8-bit; sections have 256 entries).
// vpos is 9-bit (0–261); next_scan = (vpos+1)[7:0] wraps mod 256.
// vpos[8] is intentionally unused — sections only have 256 entries.
/* verilator lint_off UNUSEDSIGNAL */
logic [7:0] next_scan;
/* verilator lint_on UNUSEDSIGNAL */
assign next_scan = vpos[7:0] + 8'd1;

// Intermediate wires for enable and data words read from BRAM.
// These are registered combinationally from the BRAM array inside the
// always_ff block; the array reads are effectively asynchronous in simulation.
logic [15:0] en_row_word;    // rowscroll enable word
logic [15:0] en_col_word;    // colscroll/alt-tilemap enable word
logic [15:0] rs_word  [0:3]; // rowscroll data per PF
logic [15:0] cs_word  [0:3]; // colscroll data per PF (for alt-tilemap bit[9])

// Combinational reads from line_ram (one address per wire).
// Address arithmetic: 15-bit = base + {7'b0, next_scan}
assign en_row_word   = line_ram[15'h0600 + {7'b0, next_scan}];
assign en_col_word   = line_ram[15'h0000 + {7'b0, next_scan}];
assign rs_word[0]    = line_ram[15'h5000 + {7'b0, next_scan}];
assign rs_word[1]    = line_ram[15'h5100 + {7'b0, next_scan}];
assign rs_word[2]    = line_ram[15'h5200 + {7'b0, next_scan}];
assign rs_word[3]    = line_ram[15'h5300 + {7'b0, next_scan}];
assign cs_word[0]    = line_ram[15'h2000 + {7'b0, next_scan}];
assign cs_word[1]    = line_ram[15'h2100 + {7'b0, next_scan}];
assign cs_word[2]    = line_ram[15'h2200 + {7'b0, next_scan}];
assign cs_word[3]    = line_ram[15'h2300 + {7'b0, next_scan}];

// Register outputs at hblank_fall
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 4; i++) begin
            ls_rowscroll[i]   <= 16'b0;
            ls_alt_tilemap[i] <= 1'b0;
        end
    end else if (hblank_fall) begin
        for (int n = 0; n < 4; n++) begin
            // Rowscroll: enable bit n of en_row_word[3:0]
            ls_rowscroll[n]   <= en_row_word[n] ? rs_word[n] : 16'b0;
            // Alt-tilemap: enable bit n of en_col_word[7:4], data bit[9] of cs_word
            ls_alt_tilemap[n] <= en_col_word[4+n] ? cs_word[n][9] : 1'b0;
        end
    end
end

// Suppress vpos[8] unused: Line RAM sections have 256 entries, only vpos[7:0] needed.
/* verilator lint_off UNUSEDSIGNAL */
logic _unused_vpos;
assign _unused_vpos = vpos[8];
/* verilator lint_on UNUSEDSIGNAL */

endmodule
