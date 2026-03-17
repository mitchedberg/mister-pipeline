// KANEKO 16 Gate 1: CPU Interface & Register File
// SystemVerilog RTL implementation
// Handles 68000 bus, address decode, register staging (shadow/active), sprite descriptor RAM

/* verilator lint_off UNUSEDPARAM */
`default_nettype none

// Sprite descriptor struct definition
typedef struct packed {
    logic [8:0]  y;
    logic [15:0] tile_num;
    logic [8:0]  x;
    logic [3:0]  palette;
    logic        flip_x;
    logic        flip_y;
    logic [3:0]  prio;
    logic [3:0]  size;
    logic        valid;
} kaneko16_sprite_t;

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
    output logic [7:0]                  mcu_param2,     // MCU parameter 2

    // Gate 2: Sprite scanner outputs
    output kaneko16_sprite_t            display_list [0:255],
    output logic [7:0]                  display_list_count,
    output logic                        display_list_ready,
    output logic                        irq_vblank,

    // ======== GATE 3: Per-scanline sprite rasterizer ========
    //
    // On scan_trigger pulse, iterates display_list[0..display_list_count-1].
    // For each valid sprite that intersects current_scanline:
    //   - Computes row_in_sprite = current_scanline - sprite.y
    //   - Applies flip_y to row_in_sprite
    //   - Iterates tile columns (tiles_wide = 1 << size[1:0], square sprites)
    //   - For each tile column, fetches 2 × 32-bit words (= 8 pixels each) from sprite ROM:
    //       addr = tile_code * 128 + row_in_tile * 8 + word_in_row * 4  (byte-aligned)
    //   - Unpacks 4bpp quads (low→high nibble order), applies flip_x,
    //     writes opaque pixels to 320-pixel scanline buffer
    //
    // VU-001/VU-002 sprite ROM tile format:
    //   16×16 px tile, 4bpp, 128 bytes (16 rows × 8 bytes/row, 2 pixels/byte)
    //   ROM is 32-bit wide: each 32-bit read = 4 bytes = 8 pixels
    //   Nibble packing per byte: lo nibble [3:0] = left pixel, hi nibble [7:4] = right pixel
    //
    // Sprite size encoding (size[1:0] from display_list entry):
    //   size=0: 1×1 tiles  = 16×16 px
    //   size=1: 2×2 tiles  = 32×32 px
    //   size=2: 4×4 tiles  = 64×64 px
    //   size=3: 8×8 tiles  = 128×128 px
    //
    // ROM 32-bit word address (byte address >> 2):
    //   full_tile = tile_code + tile_row * tiles_wide + tile_col
    //   byte_addr = full_tile * 128 + row_in_tile * 8 + word_idx * 4
    //   spr_rom_addr = byte_addr  (byte-addressed, 32-bit wide port)
    //
    // State machine:
    //   G3_IDLE  → wait for scan_trigger, clear pixel buffer
    //   G3_CHECK → test if sprite[spr_idx] intersects current_scanline
    //   G3_FETCH → read one 32-bit ROM word per cycle, unpack 8 pixels
    //   (done: pulse spr_render_done in G3_CHECK when all sprites exhausted)

    // Gate 3 control
    input  logic        scan_trigger,       // 1-cycle pulse: start scanline render
    input  logic [8:0]  current_scanline,   // scanline to render (0..239)

    // Sprite ROM interface (4bpp packed, 32-bit wide, byte-addressed)
    // One 16×16 tile = 128 bytes; 32-bit read at addr fetches bytes [addr+3:addr]
    output logic [20:0] spr_rom_addr,       // sprite ROM byte address
    output logic        spr_rom_rd,         // ROM read strobe (informational)
    input  logic [31:0] spr_rom_data,       // ROM data returned (combinational zero-latency)

    // Scanline pixel buffer read-back (combinational, valid after spr_render_done)
    input  logic [8:0]  spr_rd_addr,        // pixel X address to read (0..319)
    output logic [7:0]  spr_rd_color,       // {palette[3:0], nybble[3:0]}
    output logic        spr_rd_valid,       // 1 = opaque sprite pixel at this X

    // Done strobe
    output logic        spr_render_done     // 1-cycle pulse when scanline render complete
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
            // Initialize sprite RAM to sentinel (0x01FF means inactive)
            for (int i = 0; i < 8192; i++) begin
                sprite_ram_mem[i] <= 16'h01FF;
            end
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
    // Gate 2: Sprite Scanner FSM (VU-001/VU-002)
    // ========================================================================

    // Sprite scanner state machine
    typedef enum logic [1:0] {
        SPRITE_IDLE = 2'b00,
        SPRITE_SCAN = 2'b01,
        SPRITE_DONE = 2'b10
    } sprite_fsm_state_t;

    sprite_fsm_state_t sprite_state, sprite_state_next;
    logic [7:0] sprite_index;
    logic [7:0] display_list_ptr;
    logic [8:0] scan_counter;  // Counts 0-256 for detecting end of scan
    kaneko16_sprite_t display_list_shadow [0:255];
    logic [7:0] display_list_count_shadow;
    logic display_list_ready_shadow;

    // Extract sprite descriptor fields from RAM words
    // Each sprite: 8 words (16 bytes), stored as 16-bit words in sprite_ram
    // Word 0: Y position [8:0]
    // Word 1: tile number [15:0]
    // Word 2: X position [8:0]
    // Word 3: attributes (palette [3:0], flip_x, flip_y, priority [3:0], size [3:0])
    // Words 4-7: reserved

    wire [12:0] sprite_addr_base = {2'b00, sprite_index, 3'b000};
    wire [8:0] sprite_y = sprite_ram_mem[sprite_addr_base][8:0];
    wire [15:0] sprite_tile = sprite_ram_mem[sprite_addr_base + 13'b1][15:0];
    wire [8:0] sprite_x = sprite_ram_mem[sprite_addr_base + 13'b10][8:0];
    wire [3:0] sprite_palette = sprite_ram_mem[sprite_addr_base + 13'b11][3:0];
    wire sprite_flip_x = sprite_ram_mem[sprite_addr_base + 13'b11][4];
    wire sprite_flip_y = sprite_ram_mem[sprite_addr_base + 13'b11][5];
    wire [3:0] sprite_priority = sprite_ram_mem[sprite_addr_base + 13'b11][9:6];
    wire [3:0] sprite_size = sprite_ram_mem[sprite_addr_base + 13'b11][13:10];

    // Detect VBlank rising edge
    logic vsync_n_prev, vblank_rising;
    assign vblank_rising = ~vsync_n && vsync_n_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_n_prev <= 1'b1;
        end else begin
            vsync_n_prev <= vsync_n;
        end
    end

    // Sprite scanner FSM
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sprite_state <= SPRITE_IDLE;
            sprite_index <= 8'h00;
            display_list_ptr <= 8'h00;
            display_list_count_shadow <= 8'h00;
            display_list_ready_shadow <= 1'b0;
            for (int i = 0; i < 256; i++) begin
                display_list_shadow[i].y <= 9'h1FF;
                display_list_shadow[i].tile_num <= 16'h0000;
                display_list_shadow[i].x <= 9'h000;
                display_list_shadow[i].palette <= 4'h0;
                display_list_shadow[i].flip_x <= 1'b0;
                display_list_shadow[i].flip_y <= 1'b0;
                display_list_shadow[i].prio <= 4'h0;
                display_list_shadow[i].size <= 4'h0;
                display_list_shadow[i].valid <= 1'b0;
            end
        end else begin
            case (sprite_state_next)
                SPRITE_IDLE: begin
                    // Nothing to do
                end

                SPRITE_SCAN: begin
                    if (sprite_state == SPRITE_IDLE) begin
                        // Just entering SCAN state - initialize
                        sprite_index <= 8'h00;
                        display_list_ptr <= 8'h00;
                        display_list_count_shadow <= 8'h00;
                        display_list_ready_shadow <= 1'b0;
                        scan_counter <= 9'h000;
                    end else begin
                        // In SCAN state - process one sprite
                        if (sprite_y != 9'h1FF) begin
                            display_list_shadow[display_list_ptr[7:0]].y <= sprite_y;
                            display_list_shadow[display_list_ptr[7:0]].tile_num <= sprite_tile;
                            display_list_shadow[display_list_ptr[7:0]].x <= sprite_x;
                            display_list_shadow[display_list_ptr[7:0]].palette <= sprite_palette;
                            display_list_shadow[display_list_ptr[7:0]].flip_x <= sprite_flip_x;
                            display_list_shadow[display_list_ptr[7:0]].flip_y <= sprite_flip_y;
                            display_list_shadow[display_list_ptr[7:0]].prio <= sprite_priority;
                            display_list_shadow[display_list_ptr[7:0]].size <= sprite_size;
                            display_list_shadow[display_list_ptr[7:0]].valid <= 1'b1;
                            display_list_ptr <= display_list_ptr + 1'b1;
                        end
                        sprite_index <= sprite_index + 1'b1;
                        scan_counter <= scan_counter + 1'b1;
                    end
                end

                SPRITE_DONE: begin
                    display_list_count_shadow <= display_list_ptr;
                    display_list_ready_shadow <= 1'b1;
                end

                default: begin
                    // No operation
                end
            endcase

            sprite_state <= sprite_state_next;
        end
    end

    // FSM state transition logic
    always_comb begin
        sprite_state_next = sprite_state;

        case (sprite_state)
            SPRITE_IDLE: begin
                if (vblank_rising) begin
                    sprite_state_next = SPRITE_SCAN;
                end
            end

            SPRITE_SCAN: begin
                // Transition to DONE after scanning all 256 sprites
                if (scan_counter == 9'd256) begin
                    sprite_state_next = SPRITE_DONE;
                end
            end

            SPRITE_DONE: begin
                sprite_state_next = SPRITE_IDLE;
            end

            default: begin
                sprite_state_next = SPRITE_IDLE;
            end
        endcase
    end

    // Output assignments
    assign display_list = display_list_shadow;
    assign display_list_count = display_list_count_shadow;
    assign display_list_ready = display_list_ready_shadow;
    assign irq_vblank = vblank_rising;

    // =========================================================================
    // Gate 3: Per-scanline sprite rasterizer
    // =========================================================================

    // ── FSM state encoding ────────────────────────────────────────────────────
    typedef enum logic [1:0] {
        G3_IDLE  = 2'd0,
        G3_CHECK = 2'd1,
        G3_FETCH = 2'd2,
        G3_DONE  = 2'd3
    } g3_state_t;

    g3_state_t g3_state;

    // ── Working registers ─────────────────────────────────────────────────────
    logic [7:0]  g3_spr_idx;      // current display_list index (0..255)
    logic [3:0]  g3_tile_col;     // current tile column within sprite (0..tiles_wide-1)
    logic [1:0]  g3_word_idx;     // 32-bit word within tile row (0..1, each = 4 bytes = 8 px)

    // Saved fields from current display_list entry
    logic [8:0]  g3_spr_x;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [8:0]  g3_spr_y;
    logic        g3_flip_y_saved;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] g3_tile_base;    // sprite.tile_num (16-bit)
    logic        g3_flip_x;
    logic [3:0]  g3_palette;
    logic [1:0]  g3_size;         // effective size[1:0]: 0=16px, 1=32px, 2=64px, 3=128px

    // Derived geometry (combinational)
    logic [3:0]  g3_tiles_wide;   // 1 << g3_size
    logic [8:0]  g3_px_width;     // tiles_wide * 16
    logic [7:0]  g3_row_in_spr;   // row within sprite after flip_y
    logic [3:0]  g3_tile_row;     // g3_row_in_spr[7:4]
    logic [3:0]  g3_rit;          // row in tile = g3_row_in_spr[3:0]
    logic [19:0] g3_full_tile;    // tile_base + tile_row*tiles_wide + tile_col (20-bit max)

    // ── Scanline pixel buffer (320 pixels) ───────────────────────────────────
    logic [7:0]  spr_pix_color [0:319];
    logic        spr_pix_valid [0:319];

    // ── Read-back port (combinational) ───────────────────────────────────────
    always_comb begin
        spr_rd_color = spr_pix_color[spr_rd_addr];
        spr_rd_valid = spr_pix_valid[spr_rd_addr];
    end

    // ── ROM address drive (combinational) ────────────────────────────────────
    // Each 32-bit word covers 4 bytes = 8 pixels (word_idx 0 or 1 per tile row half)
    always_comb begin
        g3_tiles_wide = 4'(1 << g3_size);
        g3_px_width   = 9'(g3_tiles_wide) * 9'd16;
        g3_rit        = g3_row_in_spr[3:0];
        g3_tile_row   = g3_row_in_spr[7:4];
        g3_full_tile  = 20'(g3_tile_base)
                      + 20'(g3_tile_row) * 20'(g3_tiles_wide)
                      + 20'(g3_tile_col);
        // byte_addr = full_tile * 128 + rit * 8 + word_idx * 4
        spr_rom_addr  = 21'(g3_full_tile) * 21'd128
                      + 21'(g3_rit)       * 21'd8
                      + 21'(g3_word_idx)  * 21'd4;
        spr_rom_rd    = (g3_state == G3_FETCH);
    end

    // ── FSM ───────────────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g3_state        <= G3_IDLE;
            g3_spr_idx      <= 8'h00;
            g3_tile_col     <= 4'h0;
            g3_word_idx     <= 2'h0;
            g3_spr_x        <= 9'h000;
            g3_spr_y        <= 9'h000;
            g3_tile_base    <= 16'h0000;
            g3_flip_x       <= 1'b0;
            g3_flip_y_saved <= 1'b0;
            g3_palette      <= 4'h0;
            g3_size         <= 2'h0;
            g3_row_in_spr   <= 8'h00;
            spr_render_done <= 1'b0;
            for (int i = 0; i < 320; i++) begin
                spr_pix_color[i] <= 8'h00;
                spr_pix_valid[i] <= 1'b0;
            end
        end else begin
            spr_render_done <= 1'b0;  // default: not done

            case (g3_state)

                // ── IDLE: wait for trigger, clear pixel buffer ──────────────
                G3_IDLE: begin
                    if (scan_trigger) begin
                        for (int i = 0; i < 320; i++) begin
                            spr_pix_color[i] <= 8'h00;
                            spr_pix_valid[i] <= 1'b0;
                        end
                        g3_spr_idx <= 8'h00;
                        g3_state   <= G3_CHECK;
                    end
                end

                // ── CHECK: test if display_list[spr_idx] intersects scanline ─
                G3_CHECK: begin
                    if (g3_spr_idx >= display_list_count) begin
                        // All sprites processed — done
                        spr_render_done <= 1'b1;
                        g3_state        <= G3_IDLE;
                    end else begin
                        begin
                            /* verilator lint_off UNUSEDSIGNAL */
                            automatic kaneko16_sprite_t e = display_list_shadow[g3_spr_idx];
                            /* verilator lint_on UNUSEDSIGNAL */

                            if (e.valid) begin
                                // Effective size: use lower 2 bits of 4-bit size field
                                automatic logic [1:0]  e_size2   = e.size[1:0];
                                automatic logic [8:0]  spr_h     = 9'(4'(1 << e_size2)) * 9'd16;

                                if (current_scanline >= e.y &&
                                    current_scanline < (e.y + spr_h)) begin
                                    // Intersects — save fields, start fetch
                                    g3_spr_x        <= e.x;
                                    g3_spr_y        <= e.y;
                                    g3_tile_base    <= e.tile_num;
                                    g3_flip_x       <= e.flip_x;
                                    g3_flip_y_saved <= e.flip_y;
                                    g3_palette      <= e.palette;
                                    g3_size         <= e_size2;

                                    // Row within sprite (with flip_y)
                                    begin
                                        automatic logic [7:0] raw_row =
                                            8'(current_scanline - e.y);
                                        automatic logic [8:0] spr_h2 = spr_h;
                                        if (e.flip_y)
                                            g3_row_in_spr <= 8'(spr_h2 - 9'd1) - raw_row;
                                        else
                                            g3_row_in_spr <= raw_row;
                                    end

                                    g3_tile_col <= 4'h0;
                                    g3_word_idx <= 2'h0;
                                    g3_state    <= G3_FETCH;
                                end else begin
                                    // No intersection — advance
                                    g3_spr_idx <= g3_spr_idx + 8'h01;
                                end
                            end else begin
                                // Invalid entry — advance
                                g3_spr_idx <= g3_spr_idx + 8'h01;
                            end
                        end
                    end
                end

                // ── FETCH: read one 32-bit ROM word, unpack 8 pixels ────────
                // Each word holds 4 bytes.  Byte layout within word (little-endian):
                //   spr_rom_data[7:0]   = byte 0  → px 0 (lo nibble), px 1 (hi nibble)
                //   spr_rom_data[15:8]  = byte 1  → px 2, px 3
                //   spr_rom_data[23:16] = byte 2  → px 4, px 5
                //   spr_rom_data[31:24] = byte 3  → px 6, px 7
                // Pixel base offset within sprite: tile_col*16 + word_idx*8
                G3_FETCH: begin
                    begin
                        automatic logic [9:0] base_pix_in_spr =
                            10'(g3_tile_col) * 10'd16 + 10'(g3_word_idx) * 10'd8;

                        // Unpack all 8 pixels from the 32-bit word
                        for (int b = 0; b < 4; b++) begin
                            automatic logic [3:0] nib_lo = spr_rom_data[b*8 +: 4];      // left pixel
                            automatic logic [3:0] nib_hi = spr_rom_data[b*8+4 +: 4];    // right pixel
                            automatic logic [9:0] px_lo_in_spr = base_pix_in_spr + 10'(b * 2);
                            automatic logic [9:0] px_hi_in_spr = base_pix_in_spr + 10'(b * 2 + 1);

                            automatic logic [9:0] px_lo_x, px_hi_x;
                            automatic logic [3:0] eff_nib_lo, eff_nib_hi;

                            if (g3_flip_x) begin
                                // flip_x: sprite pixel P → screen X = spr_x + (px_width-1-P)
                                px_lo_x    = 10'(g3_spr_x) + 10'(g3_px_width) - 10'd1
                                           - 10'(px_lo_in_spr);
                                px_hi_x    = 10'(g3_spr_x) + 10'(g3_px_width) - 10'd1
                                           - 10'(px_hi_in_spr);
                                eff_nib_lo = nib_lo;
                                eff_nib_hi = nib_hi;
                            end else begin
                                px_lo_x    = 10'(g3_spr_x) + 10'(px_lo_in_spr);
                                px_hi_x    = 10'(g3_spr_x) + 10'(px_hi_in_spr);
                                eff_nib_lo = nib_lo;
                                eff_nib_hi = nib_hi;
                            end

                            /* verilator lint_off WIDTHTRUNC */
                            if (px_lo_x < 10'd320 && eff_nib_lo != 4'h0) begin
                                spr_pix_color[px_lo_x[8:0]] <= {g3_palette, eff_nib_lo};
                                spr_pix_valid[px_lo_x[8:0]] <= 1'b1;
                            end
                            if (px_hi_x < 10'd320 && eff_nib_hi != 4'h0) begin
                                spr_pix_color[px_hi_x[8:0]] <= {g3_palette, eff_nib_hi};
                                spr_pix_valid[px_hi_x[8:0]] <= 1'b1;
                            end
                            /* verilator lint_on WIDTHTRUNC */
                        end
                    end

                    // Advance word counter (2 words per tile row = 8 bytes = 16 pixels)
                    if (g3_word_idx == 2'd1) begin
                        g3_word_idx <= 2'd0;
                        if (g3_tile_col == (4'(g3_tiles_wide) - 4'd1)) begin
                            g3_tile_col <= 4'd0;
                            // Move to next sprite
                            g3_spr_idx <= g3_spr_idx + 8'd1;
                            g3_state   <= G3_CHECK;
                        end else begin
                            g3_tile_col <= g3_tile_col + 4'd1;
                        end
                    end else begin
                        g3_word_idx <= g3_word_idx + 2'd1;
                    end
                end

                G3_DONE: begin
                    // Unused state — included to avoid Verilator warning
                    g3_state <= G3_IDLE;
                end

                default: g3_state <= G3_IDLE;
            endcase
        end
    end

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
