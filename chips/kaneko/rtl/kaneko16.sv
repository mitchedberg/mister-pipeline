// KANEKO 16 Gate 1: CPU Interface & Register File
// SystemVerilog RTL implementation
// Handles 68000 bus, address decode, register staging (shadow/active), sprite descriptor RAM

/* verilator lint_off UNUSEDPARAM */
`default_nettype none

module kaneko16 #(
    // ROM/RAM address space configuration
    parameter ADDR_WIDTH = 21,           // 24-bit address bus from 68000 (A[23:1] due to 16-bit word alignment)
    parameter DATA_WIDTH = 16,
    parameter SPRITE_RAM_SIZE = 16384,  // 64 KB sprite descriptor RAM
    parameter SPRITE_ENTRIES = 1024      // 64 KB / 64 bytes per entry (typical)
) (
    // System
    input  logic                        clk,
    input  logic                        rst_n,

    // 68000 CPU Bus Interface
    input  logic [20:0]                 cpu_addr,       // A[20:0] from 68000 (byte addressing)
    input  logic [DATA_WIDTH-1:0]       cpu_din,        // Data from CPU
    output logic [DATA_WIDTH-1:0]       cpu_dout,       // Data to CPU
    input  logic                        cpu_cs_n,       // Chip select (active low)
    input  logic                        cpu_rd_n,       // Read strobe (active low)
    input  logic                        cpu_wr_n,       // Write strobe (active low)
    input  logic                        cpu_lds_n,      // Lower data strobe (active low, byte 0)
    input  logic                        cpu_uds_n,      // Upper data strobe (active low, byte 1)

    // Video Sync
    input  logic                        vsync_n,        // Vertical sync (active low)
    input  logic                        hsync_n,        // Horizontal sync (active low)

    // Control Signals Generated

    // Decoded Register Outputs (Shadow Registers - updated by CPU writes)
    output logic [15:0]                 scroll_x_0,     // BG0 scroll X
    output logic [15:0]                 scroll_y_0,     // BG0 scroll Y
    output logic [15:0]                 scroll_x_1,     // BG1 scroll X
    output logic [15:0]                 scroll_y_1,     // BG1 scroll Y
    output logic [15:0]                 scroll_x_2,     // BG2 scroll X
    output logic [15:0]                 scroll_y_2,     // BG2 scroll Y
    output logic [15:0]                 scroll_x_3,     // BG3 scroll X
    output logic [15:0]                 scroll_y_3,     // BG3 scroll Y

    output logic [7:0]                  layer_ctrl_0,   // BG0 control flags (enable, width, height, palette)
    output logic [7:0]                  layer_ctrl_1,   // BG1 control flags
    output logic [7:0]                  layer_ctrl_2,   // BG2 control flags
    output logic [7:0]                  layer_ctrl_3,   // BG3 control flags

    output logic [7:0]                  sprite_ctrl,    // Sprite control (enable, ring-buffer mode, etc.)
    output logic [3:0]                  map_base_sel,   // Tilemap base bank select

    output logic [15:0]                 joystick_1,     // Joystick 1 input
    output logic [15:0]                 joystick_2,     // Joystick 2 input
    output logic [15:0]                 coin_in,        // Coin / counter feedback
    output logic [15:0]                 dip_switches,   // DIP switches

    output logic [7:0]                  watchdog_counter,
    output logic                        watchdog_reset, // Watchdog timeout trigger

    output logic [7:0]                  video_int_ctrl, // VBlank/HBlank interrupt control
    output logic                        vblank_irq,     // VBlank interrupt request
    output logic                        hblank_irq,     // HBlank interrupt request

    // GFX ROM Bankswitching
    output logic [6:0]                  gfx_bank_sel,   // GFX ROM bank select (7 bits = 128 × 64 KB)

    // CALC3/MCU Interface (if supported)
    output logic [7:0]                  mcu_status,     // MCU status byte
    output logic [7:0]                  mcu_command,    // MCU command
    output logic [7:0]                  mcu_param1,     // MCU parameter 1
    output logic [7:0]                  mcu_param2      // MCU parameter 2
);

    // ========================================================================
    // Address Decode
    // ========================================================================

    logic is_sprite_ram;
    logic is_gfx_window;

    always_comb begin
        // Variant A layout (from GATE_PLAN.md):
        // 0x000000–0x0FFFFF  Program ROM           [20:16] = 0–7
        // 0x100000–0x11FFFF  Work RAM              [20:16] = 8–9
        // 0x120000–0x12FFFF  Sprite RAM (64 KB)    [20:16] = 18 (0x12)
        // 0x130000–0x13FFFF  Tilemap RAM / Layer   [20:16] = 19 (0x13)
        // 0x140000–0x14FFFF  Palette RAM (64 KB)   [20:16] = 20 (0x14)
        // 0x150000–0x15FFFF  Frame buffer          [20:16] = 21 (0x15)
        // 0x160000–0x16FFFF  MUX2-CHIP registers   [20:16] = 22 (0x16)
        // 0x170000–0x17FFFF  HELP1-CHIP registers  [20:16] = 23 (0x17)
        // 0x180000–0x18FFFF  IU-001 I/O            [20:16] = 24 (0x18)
        // 0x190000–0x19FFFF  Sound CPU mailbox     [20:16] = 25 (0x19)
        // 0x1A0000–0x1A0003  CALC3 MCU interface   [20:16] = 26 (0x1A)
        // 0x1B0000–0x1BFFFF  GFX ROM window        [20:16] = 27 (0x1B)

        is_sprite_ram = (cpu_addr[20:16] == 5'd18);    // 0x120000
        is_gfx_window = (cpu_addr[20:16] == 5'd27);    // 0x1B0000
    end

    // ========================================================================
    // Register File: Shadow (written by CPU) and Active (latched at VBlank)
    // ========================================================================

    // BG0 Scroll Registers (at 0x130000)
    logic [15:0] shadow_scroll_x_0, active_scroll_x_0;
    logic [15:0] shadow_scroll_y_0, active_scroll_y_0;

    // BG1 Scroll Registers (at 0x130100)
    logic [15:0] shadow_scroll_x_1, active_scroll_x_1;
    logic [15:0] shadow_scroll_y_1, active_scroll_y_1;

    // BG2 Scroll Registers (at 0x130200)
    logic [15:0] shadow_scroll_x_2, active_scroll_x_2;
    logic [15:0] shadow_scroll_y_2, active_scroll_y_2;

    // BG3 Scroll Registers (at 0x130300)
    logic [15:0] shadow_scroll_x_3, active_scroll_x_3;
    logic [15:0] shadow_scroll_y_3, active_scroll_y_3;

    // Layer Control Registers
    logic [7:0] shadow_layer_ctrl[0:3];
    logic [7:0] active_layer_ctrl[0:3];

    // Sprite Control
    logic [7:0] shadow_sprite_ctrl, active_sprite_ctrl;

    // Tilemap Base Select
    logic [3:0] shadow_map_base, active_map_base;

    // I/O Registers (read-only from CPU perspective, inputs from hardware)
    logic [15:0] shadow_joystick_1, shadow_joystick_2;
    logic [15:0] shadow_coin_in;
    logic [15:0] shadow_dip_switches;

    // Interrupt Control
    logic [7:0] shadow_video_int_ctrl, active_video_int_ctrl;

    // GFX Bank Select
    logic [6:0] shadow_gfx_bank, active_gfx_bank;

    // MCU Interface
    logic [7:0] shadow_mcu_status;
    logic [7:0] shadow_mcu_command;
    logic [7:0] shadow_mcu_param1;
    logic [7:0] shadow_mcu_param2;

    // Watchdog
    logic [7:0] shadow_watchdog_counter;
    logic       watchdog_active;

    // ========================================================================
    // CPU Write Logic (Updates Shadow Registers)
    // ========================================================================

    logic write_strobe;

    assign write_strobe = ~cpu_wr_n & ~cpu_cs_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all shadow registers
            shadow_scroll_x_0 <= 16'h0000;
            shadow_scroll_y_0 <= 16'h0000;
            shadow_scroll_x_1 <= 16'h0000;
            shadow_scroll_y_1 <= 16'h0000;
            shadow_scroll_x_2 <= 16'h0000;
            shadow_scroll_y_2 <= 16'h0000;
            shadow_scroll_x_3 <= 16'h0000;
            shadow_scroll_y_3 <= 16'h0000;

            shadow_layer_ctrl[0] <= 8'h00;
            shadow_layer_ctrl[1] <= 8'h00;
            shadow_layer_ctrl[2] <= 8'h00;
            shadow_layer_ctrl[3] <= 8'h00;

            shadow_sprite_ctrl <= 8'h00;
            shadow_map_base <= 4'h0;
            shadow_gfx_bank <= 7'h00;

            shadow_video_int_ctrl <= 8'h00;
            shadow_watchdog_counter <= 8'h00;

            shadow_joystick_1 <= 16'h0000;
            shadow_joystick_2 <= 16'h0000;
            shadow_coin_in <= 16'h0000;
            shadow_dip_switches <= 16'h0000;

            shadow_mcu_status <= 8'h00;
            shadow_mcu_command <= 8'h00;
            shadow_mcu_param1 <= 8'h00;
            shadow_mcu_param2 <= 8'h00;
        end else if (write_strobe && !is_sprite_ram && !is_gfx_window) begin
            // Decode register writes (VRAM and I/O ranges)
            case (cpu_addr[15:0])
                // BG0 Scroll (0x130000 base)
                16'h0000: begin
                    if (~cpu_lds_n) shadow_scroll_x_0[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_scroll_x_0[15:8] <= cpu_din[15:8];
                end
                16'h0002: begin
                    if (~cpu_lds_n) shadow_scroll_y_0[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_scroll_y_0[15:8] <= cpu_din[15:8];
                end

                // BG1 Scroll (0x130100 base)
                16'h0100: begin
                    if (~cpu_lds_n) shadow_scroll_x_1[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_scroll_x_1[15:8] <= cpu_din[15:8];
                end
                16'h0102: begin
                    if (~cpu_lds_n) shadow_scroll_y_1[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_scroll_y_1[15:8] <= cpu_din[15:8];
                end

                // BG2 Scroll (0x130200 base)
                16'h0200: begin
                    if (~cpu_lds_n) shadow_scroll_x_2[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_scroll_x_2[15:8] <= cpu_din[15:8];
                end
                16'h0202: begin
                    if (~cpu_lds_n) shadow_scroll_y_2[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_scroll_y_2[15:8] <= cpu_din[15:8];
                end

                // BG3 Scroll (0x130300 base)
                16'h0300: begin
                    if (~cpu_lds_n) shadow_scroll_x_3[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_scroll_x_3[15:8] <= cpu_din[15:8];
                end
                16'h0302: begin
                    if (~cpu_lds_n) shadow_scroll_y_3[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_scroll_y_3[15:8] <= cpu_din[15:8];
                end

                // Layer Control (0x130004, 0x130104, 0x130204, 0x130304)
                16'h0004: if (~cpu_lds_n) shadow_layer_ctrl[0] <= cpu_din[7:0];
                16'h0104: if (~cpu_lds_n) shadow_layer_ctrl[1] <= cpu_din[7:0];
                16'h0204: if (~cpu_lds_n) shadow_layer_ctrl[2] <= cpu_din[7:0];
                16'h0304: if (~cpu_lds_n) shadow_layer_ctrl[3] <= cpu_din[7:0];

                // Sprite Control (0x130400)
                16'h0400: if (~cpu_lds_n) shadow_sprite_ctrl <= cpu_din[7:0];

                // Tilemap Base Select (0x130010)
                16'h0010: if (~cpu_lds_n) shadow_map_base <= cpu_din[3:0];

                // GFX Bank Select (0x130020)
                16'h0020: if (~cpu_lds_n) shadow_gfx_bank <= cpu_din[6:0];

                // I/O: Joystick 1 (0x180000)
                16'h8000: begin
                    if (~cpu_lds_n) shadow_joystick_1[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_joystick_1[15:8] <= cpu_din[15:8];
                end

                // I/O: Joystick 2 (0x180002)
                16'h8002: begin
                    if (~cpu_lds_n) shadow_joystick_2[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_joystick_2[15:8] <= cpu_din[15:8];
                end

                // I/O: Coin (0x180004)
                16'h8004: begin
                    if (~cpu_lds_n) shadow_coin_in[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_coin_in[15:8] <= cpu_din[15:8];
                end

                // I/O: DIP Switches (0x180006)
                16'h8006: begin
                    if (~cpu_lds_n) shadow_dip_switches[7:0] <= cpu_din[7:0];
                    if (~cpu_uds_n) shadow_dip_switches[15:8] <= cpu_din[15:8];
                end

                // I/O: Watchdog kick (0x180008)
                16'h8008: begin
                    shadow_watchdog_counter <= 8'h00;
                end

                // I/O: Video Interrupt Control (0x18000E)
                16'h800E: if (~cpu_lds_n) shadow_video_int_ctrl <= cpu_din[7:0];

                // MCU Interface (0x1A0000–0x1A0003)
                16'hA000: if (~cpu_lds_n) shadow_mcu_status <= cpu_din[7:0];
                16'hA001: if (~cpu_lds_n) shadow_mcu_command <= cpu_din[7:0];
                16'hA002: if (~cpu_lds_n) shadow_mcu_param1 <= cpu_din[7:0];
                16'hA003: if (~cpu_lds_n) shadow_mcu_param2 <= cpu_din[7:0];

                default: begin
                    // No write
                end
            endcase
        end
    end

    // ========================================================================
    // CPU Read Logic
    // ========================================================================

    logic read_strobe;
    assign read_strobe = ~cpu_rd_n & ~cpu_cs_n;

    always_comb begin
        cpu_dout = 16'h0000;  // Default value, overridden by case statement

        if (read_strobe && !is_sprite_ram && !is_gfx_window) begin
            case (cpu_addr[15:0])
                // Read shadow registers back (for verification)
                16'h0000: cpu_dout = shadow_scroll_x_0;
                16'h0002: cpu_dout = shadow_scroll_y_0;
                16'h0100: cpu_dout = shadow_scroll_x_1;
                16'h0102: cpu_dout = shadow_scroll_y_1;
                16'h0200: cpu_dout = shadow_scroll_x_2;
                16'h0202: cpu_dout = shadow_scroll_y_2;
                16'h0300: cpu_dout = shadow_scroll_x_3;
                16'h0302: cpu_dout = shadow_scroll_y_3;

                16'h0004: cpu_dout = {8'h00, shadow_layer_ctrl[0]};
                16'h0104: cpu_dout = {8'h00, shadow_layer_ctrl[1]};
                16'h0204: cpu_dout = {8'h00, shadow_layer_ctrl[2]};
                16'h0304: cpu_dout = {8'h00, shadow_layer_ctrl[3]};

                16'h0400: cpu_dout = {8'h00, shadow_sprite_ctrl};
                16'h0010: cpu_dout = {12'h000, shadow_map_base};
                16'h0020: cpu_dout = {9'h000, shadow_gfx_bank};

                // I/O reads
                16'h8000: cpu_dout = shadow_joystick_1;
                16'h8002: cpu_dout = shadow_joystick_2;
                16'h8004: cpu_dout = shadow_coin_in;
                16'h8006: cpu_dout = shadow_dip_switches;

                16'h800E: cpu_dout = {8'h00, shadow_video_int_ctrl};

                // MCU reads
                16'hA000: cpu_dout = {8'h00, shadow_mcu_status};
                16'hA001: cpu_dout = {8'h00, shadow_mcu_command};
                16'hA002: cpu_dout = {8'h00, shadow_mcu_param1};
                16'hA003: cpu_dout = {8'h00, shadow_mcu_param2};

                // Sprite RAM reads
                default: begin
                    if (is_sprite_ram) begin
                        cpu_dout = sprite_ram_dout_r;
                    end
                end
            endcase
        end else if (read_strobe && is_sprite_ram) begin
            cpu_dout = sprite_ram_dout_r;
        end
    end

    // ========================================================================
    // Internal Sprite RAM (for simulation/testing)
    // ========================================================================

    logic [DATA_WIDTH-1:0] sprite_ram_mem[0:8191];  // 64 KB = 32K words
    logic [DATA_WIDTH-1:0] sprite_ram_dout_r;

    // Write to sprite RAM on write strobe
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize memory to zero
        end else begin
            if (write_strobe && is_sprite_ram) begin
                sprite_ram_mem[cpu_addr[12:0]] <= cpu_din;
            end
        end
    end

    // Read from sprite RAM (combinational for immediate result)
    always_comb begin
        sprite_ram_dout_r = sprite_ram_mem[cpu_addr[12:0]];
    end

    // ========================================================================
    // GFX ROM Window Decode
    // ========================================================================

    // GFX window at 0x1B0000–0x1BFFFF: addressed as upper 16 bits, lower bits are window offset
    // This gate doesn't implement the actual ROM access; that's handled by memory controller.
    // But we output the bank selection.

    // ========================================================================
    // VBlank Synchronization: Latch shadow → active on vsync_n rising edge
    // ========================================================================

    logic vsync_n_r, vsync_rising;
    assign vsync_rising = vsync_n_r && !vsync_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_n_r <= 1'b1;
        end else begin
            vsync_n_r <= vsync_n;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_scroll_x_0 <= 16'h0000;
            active_scroll_y_0 <= 16'h0000;
            active_scroll_x_1 <= 16'h0000;
            active_scroll_y_1 <= 16'h0000;
            active_scroll_x_2 <= 16'h0000;
            active_scroll_y_2 <= 16'h0000;
            active_scroll_x_3 <= 16'h0000;
            active_scroll_y_3 <= 16'h0000;

            active_layer_ctrl[0] <= 8'h00;
            active_layer_ctrl[1] <= 8'h00;
            active_layer_ctrl[2] <= 8'h00;
            active_layer_ctrl[3] <= 8'h00;

            active_sprite_ctrl <= 8'h00;
            active_map_base <= 4'h0;
            active_gfx_bank <= 7'h00;
            active_video_int_ctrl <= 8'h00;
        end else if (vsync_rising) begin
            // Latch shadow → active at VBlank
            active_scroll_x_0 <= shadow_scroll_x_0;
            active_scroll_y_0 <= shadow_scroll_y_0;
            active_scroll_x_1 <= shadow_scroll_x_1;
            active_scroll_y_1 <= shadow_scroll_y_1;
            active_scroll_x_2 <= shadow_scroll_x_2;
            active_scroll_y_2 <= shadow_scroll_y_2;
            active_scroll_x_3 <= shadow_scroll_x_3;
            active_scroll_y_3 <= shadow_scroll_y_3;

            active_layer_ctrl[0] <= shadow_layer_ctrl[0];
            active_layer_ctrl[1] <= shadow_layer_ctrl[1];
            active_layer_ctrl[2] <= shadow_layer_ctrl[2];
            active_layer_ctrl[3] <= shadow_layer_ctrl[3];

            active_sprite_ctrl <= shadow_sprite_ctrl;
            active_map_base <= shadow_map_base;
            active_gfx_bank <= shadow_gfx_bank;
            active_video_int_ctrl <= shadow_video_int_ctrl;
        end
    end

    // ========================================================================
    // Output Register Assignments (Active Register Values)
    // ========================================================================

    assign scroll_x_0 = active_scroll_x_0;
    assign scroll_y_0 = active_scroll_y_0;
    assign scroll_x_1 = active_scroll_x_1;
    assign scroll_y_1 = active_scroll_y_1;
    assign scroll_x_2 = active_scroll_x_2;
    assign scroll_y_2 = active_scroll_y_2;
    assign scroll_x_3 = active_scroll_x_3;
    assign scroll_y_3 = active_scroll_y_3;

    assign layer_ctrl_0 = active_layer_ctrl[0];
    assign layer_ctrl_1 = active_layer_ctrl[1];
    assign layer_ctrl_2 = active_layer_ctrl[2];
    assign layer_ctrl_3 = active_layer_ctrl[3];

    assign sprite_ctrl = active_sprite_ctrl;
    assign map_base_sel = active_map_base;
    assign gfx_bank_sel = active_gfx_bank;
    assign video_int_ctrl = active_video_int_ctrl;

    // I/O Outputs
    assign joystick_1 = shadow_joystick_1;
    assign joystick_2 = shadow_joystick_2;
    assign coin_in = shadow_coin_in;
    assign dip_switches = shadow_dip_switches;

    // MCU Outputs
    assign mcu_status = shadow_mcu_status;
    assign mcu_command = shadow_mcu_command;
    assign mcu_param1 = shadow_mcu_param1;
    assign mcu_param2 = shadow_mcu_param2;

    // ========================================================================
    // Watchdog Timer
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow_watchdog_counter <= 8'h00;
            watchdog_active <= 1'b0;
        end else begin
            if (shadow_watchdog_counter == 8'hFF) begin
                // Watchdog timeout (60 ms at typical arcade frequencies)
                watchdog_active <= 1'b1;
            end else begin
                shadow_watchdog_counter <= shadow_watchdog_counter + 1'b1;
            end
        end
    end

    assign watchdog_counter = shadow_watchdog_counter;
    assign watchdog_reset = watchdog_active;

    // ========================================================================
    // VBlank/HBlank Interrupt Generation
    // ========================================================================

    // VBlank interrupt fires at scanline 240 (top of VBlank)
    // HBlank interrupt fires at pixel 320 (end of active display)
    // These would be driven by a video timing module; for Gate 1, we stub them.

    assign vblank_irq = 1'b0;  // Would be driven by video timing
    assign hblank_irq = 1'b0;  // Would be driven by video timing

    // ========================================================================
    // Unused Signal Lint Suppression
    // ========================================================================

    /* verilator lint_off UNUSEDPARAM */
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused = &{hsync_n, 1'b0};
    /* verilator lint_on UNUSEDPARAM */
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
/* verilator lint_on UNUSEDPARAM */

`default_nettype wire
