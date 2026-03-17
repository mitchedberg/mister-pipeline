`default_nettype none
// =============================================================================
// TC0480SCP — 64KB Dual-Port VRAM  (Step 2)
// =============================================================================
// Owns the full 64KB (0x8000 × 16-bit words) VRAM.
// Port A: CPU read/write (word-granular, byte-enable).
// Port B: tile-fetch / scroll-RAM read port (one address at a time, muxed by
//         the caller — tf_addr has priority when tf_rd is asserted, otherwise
//         sc_addr is used when sc_rd is asserted).
//
// Address conventions (chip-relative byte addresses from section1 §2):
//
//   STANDARD layout (dblwidth=0):
//     BG0–BG3 tilemaps : 0x0000–0x3FFF  (word 0x0000–0x1FFF)
//     BG0–BG3 rowscroll hi : 0x4000–0x4FFF (word 0x2000–0x27FF)
//     BG0–BG3 rowscroll lo : 0x5000–0x5FFF (word 0x2800–0x2FFF)
//     BG2/BG3 rowzoom      : 0x6000–0x67FF (word 0x3000–0x33FF)
//     BG2/BG3 colscroll    : 0x6800–0x6FFF (word 0x3400–0x37FF)
//     FG0 tilemap          : 0xC000–0xDFFF (word 0x6000–0x6FFF)
//     FG0 gfx data         : 0xE000–0xFFFF (word 0x7000–0x7FFF)
//
//   DOUBLE-WIDTH layout (dblwidth=1):
//     BG0–BG3 tilemaps : 0x0000–0x7FFF  (word 0x0000–0x3FFF)
//     BG0–BG3 rowscroll hi : 0x8000–0x8FFF (word 0x4000–0x47FF)
//     BG0–BG3 rowscroll lo : 0x9000–0x9FFF (word 0x4800–0x4FFF)
//     BG2/BG3 rowzoom      : 0xA000–0xA7FF (word 0x5000–0x53FF)
//     BG2/BG3 colscroll    : 0xA800–0xAFFF (word 0x5400–0x57FF)
//     FG0 tilemap          : 0xC000–0xDFFF (word 0x6000–0x6FFF, same)
//     FG0 gfx data         : 0xE000–0xFFFF (word 0x7000–0x7FFF, same)
//
// CPU port (Port A): word-addressed by cpu_addr[14:0].
//   cpu_addr[14:0] = byte_address[15:1]   (the chip's 64KB = 15-bit word address).
//
// The dual-port BRAM is modelled as a simple array in simulation.
// For Quartus synthesis, replace with altsyncram M10K instantiation.
//
// Write-first vs read-first: Port A uses write-first (CPU write visible immediately
// on Port A read the same cycle). Port B is read-only.
// Concurrent Port A write + Port B read to same word: Port B returns the OLD value
// (read-before-write on port B, write-first on port A). This matches altsyncram
// MIXED_PORT_READ_DURING_WRITE = "OLD_DATA" behavior.
//
// BRAM persistence note: In simulation the array is not zeroed on reset — it retains
// whatever was written.  Each test group must explicitly zero addresses it depends on.
// =============================================================================

module tc0480scp_vram (
    input  logic         clk,
    input  logic         rst_n,

    // ── CPU port (port A — read/write) ────────────────────────────────────────
    input  logic         cpu_cs,          // chip select (active high)
    input  logic         cpu_we,          // write enable
    input  logic  [14:0] cpu_addr,        // word address within 64KB VRAM (= byte[15:1])
    input  logic  [15:0] cpu_din,
    input  logic  [ 1:0] cpu_be,          // byte enables: bit1=upper, bit0=lower
    output logic  [15:0] cpu_dout,        // registered read (one-cycle latency)

    // ── Tile-fetch / scroll-RAM read port (port B — read-only) ───────────────
    // tf_rd has priority over sc_rd when both are asserted simultaneously.
    input  logic         tf_rd,           // tile-fetch read request
    input  logic  [14:0] tf_addr,         // tile-fetch word address
    output logic  [15:0] tf_data,         // registered tile-fetch result

    input  logic         sc_rd,           // scroll/zoom/colscroll read request
    input  logic  [14:0] sc_addr,         // scroll-RAM word address
    output logic  [15:0] sc_data          // registered scroll-read result
);

// =============================================================================
// VRAM array: 32768 × 16-bit words = 64KB
// =============================================================================
logic [15:0] vram [0:32767];

// =============================================================================
// Port A — CPU write
// =============================================================================
always_ff @(posedge clk) begin
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) vram[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) vram[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end

// =============================================================================
// Port A — CPU read (registered, one-cycle latency)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n)
        cpu_dout <= 16'h0000;
    else if (cpu_cs && !cpu_we)
        cpu_dout <= vram[cpu_addr];
end

// =============================================================================
// Port B — tile-fetch / scroll read (registered, one-cycle latency)
// tf_rd has priority over sc_rd.
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        tf_data <= 16'h0000;
        sc_data <= 16'h0000;
    end else begin
        if (tf_rd)
            tf_data <= vram[tf_addr];
        if (sc_rd)
            sc_data <= vram[sc_addr];
    end
end

endmodule
