`default_nettype none
// =============================================================================
// TC0110PCR — Taito Palette RAM Controller
// =============================================================================
// Stores 4096 × 16-bit RGB color entries for Taito F2 arcade hardware.
// Used in early F2 boards (Final Blow, Quiz Torimonochou, Quiz H.Q., Mahjong Quest)
// before TC0260DAR became standard.
//
// CPU Interface (2 registers, word-wide, 68000 bus):
//   A0=0 write: address latch — addr = cpu_data[12:1] (standard mode, STEP_MODE=0)
//                               addr = cpu_data[11:0]  (step-1 mode,  STEP_MODE=1)
//   A0=0/1 read: returns pal_ram[addr] (registered, 1-cycle latency)
//   A0=1 write: pal_ram[addr] = cpu_din[15:0]
//
// Video Interface (color lookup):
//   pxl_in[11:0]  → color_out {B[4:0], G[4:0], R[4:0]} one clock later
//   pxl_valid = 1 latches new color; = 0 holds previous color_reg
//
// Color format: bits[14:10]=B, bits[9:5]=G, bits[4:0]=R, bit[15]=unused
//
// Reset:  section5 synchronizer (async assert, synchronous deassert)
// Memory: 4096×16-bit palette RAM (ifndef QUARTUS: behavioral; else: altsyncram M10K)
// Anti-patterns AP-1 through AP-10 enforced
// =============================================================================

module tc0110pcr #(
    // Address latch mode:
    //   0 = standard (addr = cpu_data[12:1], used by most F2 games)
    //   1 = step-1   (addr = cpu_data[11:0], used by Asuka / Mofflott)
    parameter int STEP_MODE = 0
) (
    input  logic        clk,
    input  logic        async_rst_n,   // active-low async reset

    // CPU bus (68000, word-access)
    input  logic        cpu_cs,        // chip select (active-high)
    input  logic        cpu_we,        // write enable (active-high)
    input  logic        cpu_addr,      // register: 0=addr-latch, 1=data
    input  logic [15:0] cpu_din,       // CPU write data
    output logic [15:0] cpu_dout,      // CPU read data (registered, 1-cycle latency)

    // Video color lookup
    input  logic [11:0] pxl_in,        // 12-bit palette index from compositor
    input  logic        pxl_valid,     // qualify pxl_in; color_out held when 0
    output logic [ 4:0] r_out,         // red   5-bit DAC
    output logic [ 4:0] g_out,         // green 5-bit DAC
    output logic [ 4:0] b_out          // blue  5-bit DAC
);

// =============================================================================
// Reset synchronizer (section5: async assert, synchronous deassert)
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// =============================================================================
// Address latch register
// Set when CPU writes to A0=0 (ADDR_LATCH register)
// =============================================================================
logic [11:0] addr_reg;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        addr_reg <= 12'd0;
    end else if (cpu_cs & cpu_we & ~cpu_addr) begin
        if (STEP_MODE == 0) begin
            addr_reg <= cpu_din[12:1];   // standard: (data >> 1) & 0xFFF
        end else begin
            addr_reg <= cpu_din[11:0];   // step-1: data & 0xFFF
        end
    end
end

// =============================================================================
// Palette RAM: 4096 × 16-bit
// Write port: CPU (synchronous, registered to addr_reg, qualified by cpu_cs & cpu_we & cpu_addr)
// Read port A: CPU read (registered, uses addr_reg)
// Read port B: video pixel lookup (registered, uses pxl_in)
// Single clock domain — no CDC.
// =============================================================================

// Registered read outputs (both ports, 1-cycle latency from address)
logic [15:0] pal_ram_cpu_rd;
/* verilator lint_off UNUSEDSIGNAL */
logic [15:0] pal_ram_pxl_rd;   // bit[15] unused by DAC (stored but not used)
/* verilator lint_on UNUSEDSIGNAL */

`ifndef QUARTUS
    // Behavioral model: used by Verilator (gate1) and Yosys (gate3a)
    // A large single-port RAM with shared write; read ports modelled as registered reads.
    logic [15:0] pal_ram [0:4095];

    // Write port (CPU, synchronous)
    always_ff @(posedge clk) begin
        if (cpu_cs & cpu_we & cpu_addr) begin
            pal_ram[addr_reg] <= cpu_din;
        end
    end

    // Read port A: CPU read (registered, 1-cycle latency)
    always_ff @(posedge clk) begin
        pal_ram_cpu_rd <= pal_ram[addr_reg];
    end

    // Read port B: video pixel lookup (registered, 1-cycle latency)
    always_ff @(posedge clk) begin
        pal_ram_pxl_rd <= pal_ram[pxl_in];
    end

`else
    // Synthesis: Quartus altsyncram M10K (define QUARTUS to enable)
    // Two separate dual-port RAMs sharing the same write port (port A):
    //   pal_pxl_inst: write A (CPU), read B (video pixel lookup)
    //   pal_cpu_inst: write A (CPU), read B (CPU readback)

    logic        pal_we;
    assign pal_we = cpu_cs & cpu_we & cpu_addr;

    // ── Video pixel lookup RAM ────────────────────────────────────────────────
    altsyncram #(
        .operation_mode              ("DUAL_PORT"),
        .width_a                     (16), .widthad_a (12), .numwords_a (4096),
        .width_b                     (16), .widthad_b (12), .numwords_b (4096),
        .outdata_reg_b               ("CLOCK1"),
        .address_reg_b               ("CLOCK1"),
        .clock_enable_input_a        ("BYPASS"),
        .clock_enable_input_b        ("BYPASS"),
        .clock_enable_output_b       ("BYPASS"),
        .intended_device_family      ("Cyclone V"),
        .lpm_type                    ("altsyncram"),
        .power_up_uninitialized      ("FALSE"),
        .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
    ) pal_pxl_inst (
        .clock0         ( clk           ),
        .clock1         ( clk           ),
        .address_a      ( addr_reg      ),
        .data_a         ( cpu_din       ),
        .wren_a         ( pal_we        ),
        .address_b      ( pxl_in        ),
        .q_b            ( pal_ram_pxl_rd),
        .wren_b         ( 1'b0          ),
        .data_b         ( 16'd0         ),
        .q_a            (               ),
        .aclr0          ( 1'b0          ), .aclr1         ( 1'b0  ),
        .addressstall_a ( 1'b0          ), .addressstall_b( 1'b0  ),
        .byteena_a      ( 2'b11         ), .byteena_b     ( 2'b11 ),
        .clocken0       ( 1'b1          ), .clocken1      ( 1'b1  ),
        .clocken2       ( 1'b1          ), .clocken3      ( 1'b1  ),
        .eccstatus      (               ), .rden_a        (       ),
        .rden_b         ( 1'b1          )
    );

    // ── CPU readback RAM ──────────────────────────────────────────────────────
    altsyncram #(
        .operation_mode              ("DUAL_PORT"),
        .width_a                     (16), .widthad_a (12), .numwords_a (4096),
        .width_b                     (16), .widthad_b (12), .numwords_b (4096),
        .outdata_reg_b               ("CLOCK1"),
        .address_reg_b               ("CLOCK1"),
        .clock_enable_input_a        ("BYPASS"),
        .clock_enable_input_b        ("BYPASS"),
        .clock_enable_output_b       ("BYPASS"),
        .intended_device_family      ("Cyclone V"),
        .lpm_type                    ("altsyncram"),
        .power_up_uninitialized      ("FALSE"),
        .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
    ) pal_cpu_inst (
        .clock0         ( clk           ),
        .clock1         ( clk           ),
        .address_a      ( addr_reg      ),
        .data_a         ( cpu_din       ),
        .wren_a         ( pal_we        ),
        .address_b      ( addr_reg      ),
        .q_b            ( pal_ram_cpu_rd),
        .wren_b         ( 1'b0          ),
        .data_b         ( 16'd0         ),
        .q_a            (               ),
        .aclr0          ( 1'b0          ), .aclr1         ( 1'b0  ),
        .addressstall_a ( 1'b0          ), .addressstall_b( 1'b0  ),
        .byteena_a      ( 2'b11         ), .byteena_b     ( 2'b11 ),
        .clocken0       ( 1'b1          ), .clocken1      ( 1'b1  ),
        .clocken2       ( 1'b1          ), .clocken3      ( 1'b1  ),
        .eccstatus      (               ), .rden_a        (       ),
        .rden_b         ( 1'b1          )
    );
`endif

// =============================================================================
// CPU read data output (registered, sources from pal_ram_cpu_rd)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        cpu_dout <= 16'd0;
    end else begin
        cpu_dout <= pal_ram_cpu_rd;
    end
end

// =============================================================================
// Video color lookup output
// pxl_in → registered palette entry (pal_ram_pxl_rd) → split to R/G/B
// Color format: bits[14:10]=B, bits[9:5]=G, bits[4:0]=R
// =============================================================================
logic [14:0] color_reg;   // registered {B[4:0], G[4:0], R[4:0]}

always_ff @(posedge clk) begin
    if (!rst_n) begin
        color_reg <= 15'd0;
    end else if (pxl_valid) begin
        color_reg <= pal_ram_pxl_rd[14:0];
    end
end

assign r_out = color_reg[ 4: 0];
assign g_out = color_reg[ 9: 5];
assign b_out = color_reg[14:10];

endmodule
