`default_nettype none
// Section 4b — Memory Templates
// Altsyncram-based dual-port VRAM and palette RAM for MiSTer arcade cores.
// Target: Cyclone V M10K blocks (Intel/Altera DE10-Nano)
//
// Usage:
//   - Include this file or copy the relevant module into your chip directory.
//   - The `ifdef VERILATOR stubs replace altsyncram with simple behavioral models
//     for simulation. Synthesis sees the real altsyncram primitives.
//   - CDC WARNING comments mark clock domain crossings that need synchronization
//     in the instantiating module.
//   - outdata_reg_b("CLOCK1") is required for M10K inference — do not remove.

// ─────────────────────────────────────────────────────────────────────────────
// Module: vram_dp
// Dual-port Video RAM
//   Port A: write port (CPU/DMA clock domain)
//   Port B: read port  (pixel clock domain)
//
// CDC WARNING: wrclock and rdclock may be different frequencies/phases.
//              The instantiating module must NOT read rddata_b combinationally
//              on the same cycle as a write to the same address without
//              accounting for the read latency of at least 2 rdclock cycles.
// ─────────────────────────────────────────────────────────────────────────────
module vram_dp #(
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = 16    // 2^16 = 64K locations
) (
    // Port A — write (CPU clock domain)
    input  logic                  wrclock,
    input  logic [ADDR_WIDTH-1:0] wraddress,
    input  logic [DATA_WIDTH-1:0] data_a,
    input  logic                  wren_a,

    // Port B — read (pixel clock domain)
    // CDC WARNING: rdclock is pixel clock; may differ from wrclock
    input  logic                  rdclock,
    input  logic [ADDR_WIDTH-1:0] rdaddress,
    output logic [DATA_WIDTH-1:0] rddata_b
);

`ifdef VERILATOR
    // ── Behavioral stub for Verilator simulation ──────────────────────────
    // Simple synchronous dual-port model. Does not model M10K read latency
    // accurately for simultaneous read/write to same address, but sufficient
    // for functional gate1 simulation.
    logic [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    always_ff @(posedge wrclock) begin
        if (wren_a) mem[wraddress] <= data_a;
    end

    always_ff @(posedge rdclock) begin
        rddata_b <= mem[rdaddress];
    end

`else
    // ── Altsyncram for synthesis (M10K inference) ─────────────────────────
    // outdata_reg_b("CLOCK1") is mandatory for M10K block inference.
    // Without it, Quartus may infer logic-array RAM instead of M10K.
    altsyncram #(
        .operation_mode             ("DUAL_PORT"),
        .width_a                    (DATA_WIDTH),
        .widthad_a                  (ADDR_WIDTH),
        .width_b                    (DATA_WIDTH),
        .widthad_b                  (ADDR_WIDTH),
        .outdata_reg_b              ("CLOCK1"),      // M10K: register output on rdclock
        .intended_device_family     ("Cyclone V"),
        .lpm_type                   ("altsyncram"),
        .numwords_a                 (1 << ADDR_WIDTH),
        .numwords_b                 (1 << ADDR_WIDTH),
        .rdcontrol_reg_b            ("CLOCK1"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .power_up_uninitialized     ("FALSE"),
        .init_file                  ("UNUSED")
    ) vram_inst (
        // Port A (write)
        .clock0     (wrclock),
        .address_a  (wraddress),
        .data_a     (data_a),
        .wren_a     (wren_a),
        .q_a        (),             // unused write-port readback

        // Port B (read)
        // CDC WARNING: clock1 is pixel clock domain
        .clock1     (rdclock),
        .address_b  (rdaddress),
        .wren_b     (1'b0),
        .data_b     ({DATA_WIDTH{1'b0}}),
        .q_b        (rddata_b),

        // Unused ports
        .aclr0      (1'b0), .aclr1   (1'b0),
        .addressstall_a (1'b0), .addressstall_b (1'b0),
        .byteena_a  (1'b1), .byteena_b (1'b1),
        .clocken0   (1'b1), .clocken1 (1'b1),
        .clocken2   (1'b1), .clocken3 (1'b1),
        .eccstatus  ()
    );
`endif

endmodule


// ─────────────────────────────────────────────────────────────────────────────
// Module: palette_ram
// Single-port palette RAM (256 x 24-bit RGB, or parameterize as needed)
//   Write: CPU bus (sync write)
//   Read:  Pixel pipeline (sync read, M10K registered output)
//
// CDC WARNING: If cpu_clk != pixel_clk, the cpu write address must be stable
//              for at least 2 pixel_clk cycles before the pixel pipeline reads
//              the updated palette entry. Use a write-done flag synchronized
//              to pixel_clk if real-time palette updates are needed mid-frame.
// ─────────────────────────────────────────────────────────────────────────────
module palette_ram #(
    parameter int COLORS     = 256,
    parameter int COLOR_BITS = 24,   // 8R + 8G + 8B
    parameter int ADDR_BITS  = 8     // log2(COLORS)
) (
    // Write port — CPU clock domain
    input  logic                 cpu_clk,
    input  logic [ADDR_BITS-1:0] wr_addr,
    input  logic [COLOR_BITS-1:0] wr_data,
    input  logic                 wr_en,

    // Read port — pixel clock domain
    // CDC WARNING: pixel_clk may differ from cpu_clk
    input  logic                 pixel_clk,
    input  logic [ADDR_BITS-1:0] rd_addr,
    output logic [COLOR_BITS-1:0] rd_data
);

`ifdef VERILATOR
    // ── Behavioral stub ───────────────────────────────────────────────────
    logic [COLOR_BITS-1:0] palette [0:COLORS-1];

    always_ff @(posedge cpu_clk) begin
        if (wr_en) palette[wr_addr] <= wr_data;
    end

    always_ff @(posedge pixel_clk) begin
        rd_data <= palette[rd_addr];
    end

`else
    // ── Altsyncram palette (M10K) ─────────────────────────────────────────
    altsyncram #(
        .operation_mode             ("DUAL_PORT"),
        .width_a                    (COLOR_BITS),
        .widthad_a                  (ADDR_BITS),
        .width_b                    (COLOR_BITS),
        .widthad_b                  (ADDR_BITS),
        .outdata_reg_b              ("CLOCK1"),      // M10K registered output
        .intended_device_family     ("Cyclone V"),
        .lpm_type                   ("altsyncram"),
        .numwords_a                 (COLORS),
        .numwords_b                 (COLORS),
        .rdcontrol_reg_b            ("CLOCK1"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .power_up_uninitialized     ("FALSE")
    ) palette_inst (
        .clock0     (cpu_clk),
        .address_a  (wr_addr),
        .data_a     (wr_data),
        .wren_a     (wr_en),
        .q_a        (),

        // CDC WARNING: clock1 = pixel domain
        .clock1     (pixel_clk),
        .address_b  (rd_addr),
        .wren_b     (1'b0),
        .data_b     ({COLOR_BITS{1'b0}}),
        .q_b        (rd_data),

        .aclr0      (1'b0), .aclr1   (1'b0),
        .addressstall_a (1'b0), .addressstall_b (1'b0),
        .byteena_a  (1'b1), .byteena_b (1'b1),
        .clocken0   (1'b1), .clocken1 (1'b1),
        .clocken2   (1'b1), .clocken3 (1'b1),
        .eccstatus  ()
    );
`endif

endmodule
