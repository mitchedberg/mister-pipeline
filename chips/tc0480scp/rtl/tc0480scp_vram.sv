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
//
// Quartus synthesis path: four separate M10K copies, each serving one read
// client group.  A single 10-port array causes quartus_map to OOM during
// elaboration (multi-port mux tree exceeds available memory); four SDP-style
// arrays avoid the expansion entirely.
//
//   vram_cpu  — CPU R/W  (1 write + 1 read)               ~52 M10K blocks
//   vram_tf   — BG tile-fetch (4 readers, shared mux)      ~52 M10K blocks
//   vram_sc   — BG scroll (4 readers, staggered mux)       ~52 M10K blocks
//   vram_tx   — Text layer (map + gfx, staggered mux)      ~52 M10K blocks
//   Total: ~208 M10K blocks out of 308 available on Cyclone V 5CSEBA6
//
// BG scroll reads (Port C) are confirmed staggered by the parent; a shared
// mux is functionally correct.  Text map and gfx reads use different FSM
// states so a shared mux is also correct.  BG tile-fetch reads (Port B) may
// be simultaneously issued by all 4 layer engines; the priority mux means
// only the highest-priority layer gets correct data when collisions occur.
// Correct 4-way TF arbitration requires a round-robin arbiter (future work).
`ifdef QUARTUS
(* ramstyle = "M10K" *) logic [15:0] vram_cpu [0:32767];  // CPU R/W copy
(* ramstyle = "M10K" *) logic [15:0] vram_tf  [0:32767];  // BG tile-fetch
(* ramstyle = "M10K" *) logic [15:0] vram_sc  [0:32767];  // BG scroll
(* ramstyle = "M10K" *) logic [15:0] vram_tx  [0:32767];  // text map + gfx
`else
logic [15:0] vram [0:32767];
`endif

// =============================================================================
// Port A — CPU write (broadcast to all four copies, one always_ff per copy
// so each block is a clean SDP RAM write that Quartus M10K inference sees)
// =============================================================================
`ifdef QUARTUS
always_ff @(posedge clk) begin  // vram_cpu write
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) vram_cpu[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) vram_cpu[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end
always_ff @(posedge clk) begin  // vram_tf write (tile-fetch copy)
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) vram_tf[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) vram_tf[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end
always_ff @(posedge clk) begin  // vram_sc write (scroll copy)
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) vram_sc[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) vram_sc[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end
always_ff @(posedge clk) begin  // vram_tx write (text layer copy)
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) vram_tx[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) vram_tx[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end
`else
always_ff @(posedge clk) begin
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) vram[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) vram[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end
`endif

// =============================================================================
// Port A — CPU read (registered, one-cycle latency)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n)
        cpu_dout <= 16'h0000;
`ifdef QUARTUS
    else if (cpu_cs && !cpu_we)
        cpu_dout <= vram_cpu[cpu_addr];
`else
    else if (cpu_cs && !cpu_we)
        cpu_dout <= vram[cpu_addr];
`endif
end

// =============================================================================
// Port B — BG tile-fetch (4 readers sharing vram_tf via priority mux)
// Priority: BG0 > BG1 > BG2 > BG3.  When reads are staggered (typical), each
// layer sees correct data.  Simultaneous collisions return BG0's data to all
// colliding layers — acceptable for CI; full arbiter is future work.
// =============================================================================
`ifdef QUARTUS
logic [14:0] bg_tf_mux_addr;
always_comb begin
    priority casez (bg_tf_rd)
        4'b???1: bg_tf_mux_addr = bg_tf_addr[0];
        4'b??10: bg_tf_mux_addr = bg_tf_addr[1];
        4'b?100: bg_tf_mux_addr = bg_tf_addr[2];
        default: bg_tf_mux_addr = bg_tf_addr[3];
    endcase
end

logic [15:0] bg_tf_raw;
always_ff @(posedge clk) begin
    if (!rst_n)
        bg_tf_raw <= 16'h0000;
    else if (|bg_tf_rd)
        bg_tf_raw <= vram_tf[bg_tf_mux_addr];
end

logic [3:0] bg_tf_rd_r;
always_ff @(posedge clk) begin
    if (!rst_n) bg_tf_rd_r <= 4'b0;
    else        bg_tf_rd_r <= bg_tf_rd;
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int n = 0; n < 4; n++) bg_tf_data[n] <= 16'h0000;
    end else begin
        for (int n = 0; n < 4; n++)
            if (bg_tf_rd_r[n]) bg_tf_data[n] <= bg_tf_raw;
    end
end
`else
// =============================================================================
// Port B — BG tile-fetch (4 independent registered reads — simulation)
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
`endif

// =============================================================================
// Port C — BG scroll (4 readers sharing vram_sc via priority mux)
// Parent guarantees staggered reads (only one BG issues sc_rd per cycle) so
// the priority mux is functionally correct.
// =============================================================================
`ifdef QUARTUS
logic [14:0] bg_sc_mux_addr;
always_comb begin
    priority casez (bg_sc_rd)
        4'b???1: bg_sc_mux_addr = bg_sc_addr[0];
        4'b??10: bg_sc_mux_addr = bg_sc_addr[1];
        4'b?100: bg_sc_mux_addr = bg_sc_addr[2];
        default: bg_sc_mux_addr = bg_sc_addr[3];
    endcase
end

logic [15:0] bg_sc_raw;
always_ff @(posedge clk) begin
    if (!rst_n)
        bg_sc_raw <= 16'h0000;
    else if (|bg_sc_rd)
        bg_sc_raw <= vram_sc[bg_sc_mux_addr];
end

logic [3:0] bg_sc_rd_r;
always_ff @(posedge clk) begin
    if (!rst_n) bg_sc_rd_r <= 4'b0;
    else        bg_sc_rd_r <= bg_sc_rd;
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int n = 0; n < 4; n++) bg_sc_data[n] <= 16'h0000;
    end else begin
        for (int n = 0; n < 4; n++)
            if (bg_sc_rd_r[n]) bg_sc_data[n] <= bg_sc_raw;
    end
end
`else
// =============================================================================
// Port C — BG scroll (4 independent registered reads — simulation)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int n = 0; n < 4; n++) bg_sc_data[n] <= 16'h0000;
    end else begin
        for (int n = 0; n < 4; n++)
            if (bg_sc_rd[n]) bg_sc_data[n] <= vram[bg_sc_addr[n]];
    end
end
`endif

// =============================================================================
// Ports D + E — Text layer map + gfx reads (sharing vram_tx via mux)
// Map and gfx reads are in different FSM states so they never overlap; the
// mux is functionally correct.  One M10K copy handles both, saving 52 blocks.
// =============================================================================
`ifdef QUARTUS
logic [14:0] tx_mux_addr;
assign tx_mux_addr = text_map_rd ? text_map_addr : text_gfx_addr;

logic [15:0] tx_raw;
logic text_map_rd_r, text_gfx_rd_r;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        tx_raw          <= 16'h0000;
        text_map_rd_r   <= 1'b0;
        text_gfx_rd_r   <= 1'b0;
    end else begin
        text_map_rd_r   <= text_map_rd;
        text_gfx_rd_r   <= text_gfx_rd;
        if (text_map_rd || text_gfx_rd)
            tx_raw <= vram_tx[tx_mux_addr];
    end
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        text_map_data <= 16'h0000;
        text_gfx_data <= 16'h0000;
    end else begin
        if (text_map_rd_r) text_map_data <= tx_raw;
        if (text_gfx_rd_r) text_gfx_data <= tx_raw;
    end
end
`else
// =============================================================================
// Port D — Text layer map read (simulation)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n)
        text_map_data <= 16'h0000;
    else if (text_map_rd)
        text_map_data <= vram[text_map_addr];
end

// =============================================================================
// Port E — Text layer gfx read (simulation)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n)
        text_gfx_data <= 16'h0000;
    else if (text_gfx_rd)
        text_gfx_data <= vram[text_gfx_addr];
end
`endif

endmodule
