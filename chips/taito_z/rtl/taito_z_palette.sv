`default_nettype none
// =============================================================================
// taito_z_palette.sv — Inline Palette RAM for Taito Z (dblaxle / racingb)
// =============================================================================
//
// Plain 4096-entry × 16-bit synchronous BRAM.
// No TC0260DAR — palette RAM is directly CPU-accessible (no busy stall logic).
//
// Pixel format: xBGR_555
//   bit [15]    = unused (x)
//   bits[14:10] = R[4:0]
//   bits[ 9: 5] = G[4:0]
//   bits[ 4: 0] = B[4:0]
//
// 5→8 bit expansion: {r5, r5[4:2]} — replicates top 3 bits into low 3 bits.
// This matches MAME's palette_device::xBGR_555 expansion.
//
// CPU access: 0xA00000–0xA01FFF in dblaxle (4KB = 4096 × 16-bit words)
//   cpu_addr[12:1] = 12-bit palette index within window
//
// Pixel lookup: 12-bit index → 1-cycle registered read → 8-bit R, G, B out.
//   One-cycle latency means pixel_out is valid one clk_sys after pix_index.
//
// Reference: MAME taito_z.cpp, palette_device::xBGR_555
// =============================================================================

module taito_z_palette (
    input  logic        clk,
    input  logic        reset_n,

    // CPU write port (from CPU A bus)
    input  logic        cpu_cs,         // chip select
    input  logic        cpu_we,         // write enable (cpu_rw=0 → we=1)
    input  logic [11:0] cpu_addr,       // 12-bit word address within 4KB window
    input  logic [15:0] cpu_din,        // CPU write data
    input  logic [ 1:0] cpu_be,         // byte enables: [1]=UDS, [0]=LDS
    output logic [15:0] cpu_dout,       // CPU read data

    // Pixel lookup port (from compositor / TC0480SCP pixel output)
    input  logic [11:0] pix_index,      // 12-bit palette index
    input  logic        pix_valid,      // pixel valid strobe (register output on this cycle)

    // Expanded RGB output (registered, 1-cycle latency from pix_index)
    output logic [ 7:0] rgb_r,
    output logic [ 7:0] rgb_g,
    output logic [ 7:0] rgb_b
);

// 4096 × 16-bit palette BRAM
logic [15:0] pal_ram [0:4095];

// CPU write
always_ff @(posedge clk) begin
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) pal_ram[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) pal_ram[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end

// CPU read (registered, 1-cycle)
always_ff @(posedge clk) begin
    if (cpu_cs && !cpu_we)
        cpu_dout <= pal_ram[cpu_addr];
    else
        cpu_dout <= 16'hFFFF;
end

// Pixel lookup: registered on clk; expands xBGR_555 → 8-bit RGB
// xBGR_555: [14:10]=R, [9:5]=G, [4:0]=B
// 5→8 expansion: {r5, r5[4:2]}  (top 3 bits replicated into bit positions [2:0])
always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        rgb_r <= 8'h00;
        rgb_g <= 8'h00;
        rgb_b <= 8'h00;
    end else begin
        if (pix_valid) begin
            // xBGR_555: [15]=unused, [14:10]=R, [9:5]=G, [4:0]=B
            /* verilator lint_off UNUSED */
            logic [15:0] color;
            /* verilator lint_on UNUSED */
            color = pal_ram[pix_index];
            rgb_r <= {color[14:10], color[14:12]};
            rgb_g <= {color[ 9: 5], color[ 9: 7]};
            rgb_b <= {color[ 4: 0], color[ 4: 2]};
        end
    end
end

endmodule
