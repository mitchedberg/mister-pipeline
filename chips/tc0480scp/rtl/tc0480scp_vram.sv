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
// Quartus synthesis path: four explicit altsyncram DUAL_PORT M10K instances,
// each serving one read client group.  Behavioral `(* ramstyle = "M10K" *)`
// arrays caused quartus_map Error 293007 (OOM, 814MB) during elaboration because
// Quartus 17.0 expands multi-reader array reads into massive mux-tree ASTs before
// tech mapping.  Explicit altsyncram primitives are treated as black-boxes during
// elaboration — no AST expansion, no OOM.  This is the tc0110pcr / tc0180vcu
// proven pattern.
//
//   vram_cpu_inst  — CPU R/W  (port A = CPU write, port B = CPU readback)
//   vram_tf_inst   — BG tile-fetch (port A = CPU write, port B = priority mux)
//   vram_sc_inst   — BG scroll (port A = CPU write, port B = priority mux)
//   vram_tx_inst   — Text layer (port A = CPU write, port B = map/gfx mux)
//
// Estimated M10K usage: 4 × ~52 = ~208 M10K blocks out of 308 on Cyclone V 5CSEBA6.
`ifndef QUARTUS
logic [15:0] vram [0:32767];
`endif

// =============================================================================
// Port A — CPU write
// =============================================================================
`ifdef QUARTUS
// Write enable (shared across all four altsyncram instances)
logic cpu_we_gate;
assign cpu_we_gate = cpu_cs & cpu_we;
`else
always_ff @(posedge clk) begin
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) vram[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) vram[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end
`endif

// =============================================================================
// Port A — CPU read  +  vram_cpu_inst  (QUARTUS: altsyncram CPU readback)
// =============================================================================
`ifdef QUARTUS
logic [15:0] vram_cpu_q;

altsyncram #(
    .operation_mode                ("DUAL_PORT"),
    .width_a                       (16), .widthad_a (15), .numwords_a (32768),
    .width_b                       (16), .widthad_b (15), .numwords_b (32768),
    .outdata_reg_b                 ("CLOCK1"),
    .address_reg_b                 ("CLOCK1"),
    .clock_enable_input_a          ("BYPASS"),
    .clock_enable_input_b          ("BYPASS"),
    .clock_enable_output_b         ("BYPASS"),
    .intended_device_family        ("Cyclone V"),
    .lpm_type                      ("altsyncram"),
    .ram_block_type                ("M10K"),
    .width_byteena_a               (2),
    .power_up_uninitialized        ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) vram_cpu_inst (
    .clock0         ( clk          ),
    .clock1         ( clk          ),
    .address_a      ( cpu_addr     ),
    .data_a         ( cpu_din      ),
    .wren_a         ( cpu_we_gate  ),
    .byteena_a      ( cpu_be       ),
    .address_b      ( cpu_addr     ),
    .q_b            ( vram_cpu_q   ),
    .wren_b         ( 1'b0         ),
    .data_b         ( 16'd0        ),
    .q_a            (              ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0  ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0  ),
    .byteena_b      ( 1'b1         ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1  ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1  ),
    .eccstatus      (      ), .rden_a         (       ),
    .rden_b         ( 1'b1         )
);

// altsyncram q_b is already registered (1-cycle latency) — drive cpu_dout directly
assign cpu_dout = vram_cpu_q;

`else
always_ff @(posedge clk) begin
    if (!rst_n)
        cpu_dout <= 16'h0000;
    else if (cpu_cs && !cpu_we)
        cpu_dout <= vram[cpu_addr];
end
`endif

// =============================================================================
// Port B — BG tile-fetch  +  vram_tf_inst  (4 readers sharing priority mux)
// Priority: BG0 > BG1 > BG2 > BG3.  When reads are staggered (typical), each
// layer sees correct data.  Simultaneous collisions return BG0's data.
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

altsyncram #(
    .operation_mode                ("DUAL_PORT"),
    .width_a                       (16), .widthad_a (15), .numwords_a (32768),
    .width_b                       (16), .widthad_b (15), .numwords_b (32768),
    .outdata_reg_b                 ("CLOCK1"),
    .address_reg_b                 ("CLOCK1"),
    .clock_enable_input_a          ("BYPASS"),
    .clock_enable_input_b          ("BYPASS"),
    .clock_enable_output_b         ("BYPASS"),
    .intended_device_family        ("Cyclone V"),
    .lpm_type                      ("altsyncram"),
    .ram_block_type                ("M10K"),
    .width_byteena_a               (2),
    .power_up_uninitialized        ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) vram_tf_inst (
    .clock0         ( clk             ),
    .clock1         ( clk             ),
    .address_a      ( cpu_addr        ),
    .data_a         ( cpu_din         ),
    .wren_a         ( cpu_we_gate     ),
    .byteena_a      ( cpu_be          ),
    .address_b      ( bg_tf_mux_addr  ),
    .q_b            ( bg_tf_raw       ),
    .wren_b         ( 1'b0            ),
    .data_b         ( 16'd0           ),
    .q_a            (                 ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0  ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0  ),
    .byteena_b      ( 1'b1            ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1  ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1  ),
    .eccstatus      (      ), .rden_a         (       ),
    .rden_b         ( 1'b1            )
);

// Delay rd one cycle to align with registered altsyncram output
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
// Port C — BG scroll  +  vram_sc_inst  (4 readers sharing priority mux)
// Parent guarantees staggered reads so the priority mux is functionally correct.
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

altsyncram #(
    .operation_mode                ("DUAL_PORT"),
    .width_a                       (16), .widthad_a (15), .numwords_a (32768),
    .width_b                       (16), .widthad_b (15), .numwords_b (32768),
    .outdata_reg_b                 ("CLOCK1"),
    .address_reg_b                 ("CLOCK1"),
    .clock_enable_input_a          ("BYPASS"),
    .clock_enable_input_b          ("BYPASS"),
    .clock_enable_output_b         ("BYPASS"),
    .intended_device_family        ("Cyclone V"),
    .lpm_type                      ("altsyncram"),
    .ram_block_type                ("M10K"),
    .width_byteena_a               (2),
    .power_up_uninitialized        ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) vram_sc_inst (
    .clock0         ( clk             ),
    .clock1         ( clk             ),
    .address_a      ( cpu_addr        ),
    .data_a         ( cpu_din         ),
    .wren_a         ( cpu_we_gate     ),
    .byteena_a      ( cpu_be          ),
    .address_b      ( bg_sc_mux_addr  ),
    .q_b            ( bg_sc_raw       ),
    .wren_b         ( 1'b0            ),
    .data_b         ( 16'd0           ),
    .q_a            (                 ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0  ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0  ),
    .byteena_b      ( 1'b1            ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1  ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1  ),
    .eccstatus      (      ), .rden_a         (       ),
    .rden_b         ( 1'b1            )
);

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
// Ports D + E — Text layer  +  vram_tx_inst  (map + gfx reads, staggered mux)
// Map and gfx reads are in different FSM states so they never overlap.
// One M10K copy handles both, saving 52 blocks vs two separate copies.
// =============================================================================
`ifdef QUARTUS
logic [14:0] tx_mux_addr;
assign tx_mux_addr = text_map_rd ? text_map_addr : text_gfx_addr;

logic [15:0] tx_raw;

altsyncram #(
    .operation_mode                ("DUAL_PORT"),
    .width_a                       (16), .widthad_a (15), .numwords_a (32768),
    .width_b                       (16), .widthad_b (15), .numwords_b (32768),
    .outdata_reg_b                 ("CLOCK1"),
    .address_reg_b                 ("CLOCK1"),
    .clock_enable_input_a          ("BYPASS"),
    .clock_enable_input_b          ("BYPASS"),
    .clock_enable_output_b         ("BYPASS"),
    .intended_device_family        ("Cyclone V"),
    .lpm_type                      ("altsyncram"),
    .ram_block_type                ("M10K"),
    .width_byteena_a               (2),
    .power_up_uninitialized        ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) vram_tx_inst (
    .clock0         ( clk          ),
    .clock1         ( clk          ),
    .address_a      ( cpu_addr     ),
    .data_a         ( cpu_din      ),
    .wren_a         ( cpu_we_gate  ),
    .byteena_a      ( cpu_be       ),
    .address_b      ( tx_mux_addr  ),
    .q_b            ( tx_raw       ),
    .wren_b         ( 1'b0         ),
    .data_b         ( 16'd0        ),
    .q_a            (              ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0  ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0  ),
    .byteena_b      ( 1'b1         ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1  ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1  ),
    .eccstatus      (      ), .rden_a         (       ),
    .rden_b         ( 1'b1         )
);

logic text_map_rd_r, text_gfx_rd_r;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        text_map_rd_r <= 1'b0;
        text_gfx_rd_r <= 1'b0;
    end else begin
        text_map_rd_r <= text_map_rd;
        text_gfx_rd_r <= text_gfx_rd;
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
