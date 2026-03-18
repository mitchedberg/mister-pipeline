`default_nettype none
// =============================================================================
// TC0480SCP — 64KB VRAM  (Steps 2–8)
// =============================================================================
// Owns the full 64KB (0x8000 × 16-bit words) VRAM.
//
// Port A  : CPU read/write (word-granular, byte-enable).
//
// Port B  : 4 × independent BG tile-fetch ports (one per BG layer, registered
//           1-cycle latency).  Each engine gets its own bg_tf_addr[n] /
//           bg_tf_data[n] so there is NEVER a port-contention issue between
//           layers during the tile-fill scanline loop.
//
// Port C  : 4 × independent BG scroll/colscroll/rowzoom read ports (one per
//           BG layer, registered 1-cycle latency).  Staggered HBLANK timing in
//           the parent ensures only one engine issues a sc read per cycle, but
//           having separate registered outputs avoids any "last-writer-wins"
//           problem.  In practice the stagger guarantees non-overlapping reads
//           so a single shared sc output would also work, but separate outputs
//           are safer and cost negligible in simulation.
//
// Port D  : Text-layer map read (registered 1-cycle latency).
//           The text FSM uses a separate addr/data pair so it never contends
//           with BG tile-fetch or BG scroll reads.
//
// Port E  : Text-layer gfx read (registered 1-cycle latency).
//
// Address conventions — see section1 §2.
//
// BRAM persistence note: In simulation the array is not zeroed on reset — it
// retains whatever was written.  Each test group must explicitly zero the
// addresses it depends on.
// =============================================================================

module tc0480scp_vram (
    input  logic         clk,
    input  logic         rst_n,

    // ── CPU port (port A — read/write) ────────────────────────────────────────
    input  logic         cpu_cs,
    input  logic         cpu_we,
    input  logic  [14:0] cpu_addr,
    input  logic  [15:0] cpu_din,
    input  logic  [ 1:0] cpu_be,
    output logic  [15:0] cpu_dout,

    // ── BG tile-fetch ports (4 × independent, port B) ─────────────────────────
    input  logic  [ 3:0]        bg_tf_rd,
    input  logic  [ 3:0][14:0]  bg_tf_addr,
    output logic  [ 3:0][15:0]  bg_tf_data,

    // ── BG scroll/colscroll/rowzoom ports (4 × independent, port C) ────────────
    input  logic  [ 3:0]        bg_sc_rd,
    input  logic  [ 3:0][14:0]  bg_sc_addr,
    output logic  [ 3:0][15:0]  bg_sc_data,

    // ── Text layer map read port (port D) ─────────────────────────────────────
    input  logic         text_map_rd,
    input  logic  [14:0] text_map_addr,
    output logic  [15:0] text_map_data,

    // ── Text layer gfx read port (port E) ─────────────────────────────────────
    input  logic         text_gfx_rd,
    input  logic  [14:0] text_gfx_addr,
    output logic  [15:0] text_gfx_data
);

// =============================================================================
// VRAM array: 32768 × 16-bit words = 64KB
// =============================================================================
`ifdef QUARTUS
(* ramstyle = "M10K" *) logic [15:0] vram [0:32767];
`else
logic [15:0] vram [0:32767];
`endif

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
// Port B — BG tile-fetch (4 independent registered reads)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int n = 0; n < 4; n++) bg_tf_data[n] <= 16'h0000;
    end else begin
        for (int n = 0; n < 4; n++) begin
            if (bg_tf_rd[n]) begin
                bg_tf_data[n] <= vram[bg_tf_addr[n]];
            end
        end
    end
end

// =============================================================================
// Port C — BG scroll/colscroll/rowzoom (4 independent registered reads)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int n = 0; n < 4; n++) bg_sc_data[n] <= 16'h0000;
    end else begin
        for (int n = 0; n < 4; n++)
            if (bg_sc_rd[n]) bg_sc_data[n] <= vram[bg_sc_addr[n]];
    end
end

// =============================================================================
// Port D — Text layer map read
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n)
        text_map_data <= 16'h0000;
    else if (text_map_rd)
        text_map_data <= vram[text_map_addr];
end

// =============================================================================
// Port E — Text layer gfx read
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n)
        text_gfx_data <= 16'h0000;
    else if (text_gfx_rd)
        text_gfx_data <= vram[text_gfx_addr];
end

endmodule
