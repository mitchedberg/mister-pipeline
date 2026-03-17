// NMK16 Graphics Subsystem — Gate 1: CPU Interface & Register File
// 68000-compatible CPU bus interface with control registers and sprite RAM
// Date: 2026-03-17

module nmk16 #(
    parameter ADDR_WIDTH = 21,     // 21-bit addresses ($000000–$1FFFFF)
    parameter DATA_WIDTH = 16       // 16-bit data bus
) (
    // Clock and reset
    input  logic                    clk,
    input  logic                    rst_n,

    // 68000 CPU Interface
    input  logic [ADDR_WIDTH-1:1]   addr,           // Word-aligned address (addr[0] ignored)
    input  logic [DATA_WIDTH-1:0]   din,            // CPU -> FPGA
    output logic [DATA_WIDTH-1:0]   dout,           // FPGA -> CPU
    input  logic                    cs_n,           // Chip select (active low)
    input  logic                    rd_n,           // Read strobe (active low)
    input  logic                    wr_n,           // Write strobe (active low)
    input  logic                    lds_n,          // Lower data strobe (active low)
    input  logic                    uds_n,          // Upper data strobe (active low)

    // Video timing synchronization
    input  logic                    vsync_n,        // Vertical sync (active low)
    input  logic                    vsync_n_r,      // Delayed by 1 cycle for edge detection

    // ======== SHADOW REGISTERS (CPU-writable, latched to active on VBLANK) ========

    // Background scroll registers
    output logic [15:0]             scroll0_x_active,
    output logic [15:0]             scroll0_y_active,
    output logic [15:0]             scroll1_x_active,
    output logic [15:0]             scroll1_y_active,

    // Background control register
    output logic [15:0]             bg_ctrl_active,

    // Sprite control register
    output logic [15:0]             sprite_ctrl_active,

    // ======== SPRITE RAM INTERFACE ========

    // Sprite RAM write port (from CPU)
    output logic                    sprite_wr,      // Sprite RAM write enable
    output logic [9:0]              sprite_addr_wr, // Sprite address (256 sprites × 4 words = 1024 words)
    output logic [15:0]             sprite_data_wr, // Sprite data to write

    // Sprite RAM read port (from CPU or rendering)
    output logic                    sprite_rd,      // Sprite RAM read enable (stub for external BRAM)
    output logic [9:0]              sprite_addr_rd, // Sprite read address (stub for external BRAM)
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [15:0]             sprite_data_rd, // Sprite data from RAM (unused; internal BRAM used)
    /* verilator lint_on UNUSEDSIGNAL */

    // ======== STATUS REGISTER ========

    // Video status inputs
    input  logic                    vblank_irq,     // VBLANK interrupt flag
    input  logic                    sprite_done_irq, // Sprite list done flag

    // ======== GATE 2: SPRITE SCANNER OUTPUT ========

    // Display list output
    output logic [8:0]              display_list_x [0:255],     // X position [8:0]
    output logic [8:0]              display_list_y [0:255],     // Y position [8:0]
    output logic [11:0]             display_list_tile [0:255],  // Tile code [11:0]
    output logic                    display_list_flip_x [0:255],
    output logic                    display_list_flip_y [0:255],
    output logic [1:0]              display_list_size [0:255],
    output logic [3:0]              display_list_palette [0:255],
    output logic                    display_list_valid [0:255],
    output logic [7:0]              display_list_count,         // Number of visible sprites
    output logic                    display_list_ready,         // 1-cycle pulse when scan done
    output logic                    irq_vblank_pulse            // 1-cycle pulse at scan end
);

    // ========== ADDRESS DECODE ==========

    logic is_gpu;       // $120000–$12FFFF (graphics control)
    logic is_sprite;    // $130000–$13FFFF (sprite RAM)
    logic is_palette;   // $140000–$14FFFF (palette RAM)

    always_comb begin
        is_gpu      = (addr[20:16] == 5'b10010);                          // $120000–$12FFFF
        is_sprite   = (addr[20:16] == 5'b10011);                          // $130000–$13FFFF
        is_palette  = (addr[20:16] == 5'b10100);                          // $140000–$14FFFF
    end

    // ========== CONTROL REGISTER FILE ==========
    // All registers use shadow/active pattern: CPU writes to shadow,
    // VBLANK rising edge copies shadow -> active

    logic [15:0] scroll0_x_shadow;
    logic [15:0] scroll0_y_shadow;
    logic [15:0] scroll1_x_shadow;
    logic [15:0] scroll1_y_shadow;
    logic [15:0] bg_ctrl_shadow;
    logic [15:0] sprite_ctrl_shadow;

    // ========== STATUS REGISTER COMPOSITION ==========

    logic [15:0] status_reg;
    always_comb begin
        status_reg = 16'h0000;
        status_reg[7] = vblank_irq;
        status_reg[6] = sprite_done_irq;
        // [5:0] reserved
    end

    // ========== VBLANK EDGE DETECTION ==========

    logic vsync_falling_edge;
    always_comb begin
        vsync_falling_edge = vsync_n_r & ~vsync_n;  // Transition from high to low
    end

    // ========== SHADOW REGISTER STAGING ==========

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            scroll0_x_shadow <= 16'h0000;
            scroll0_y_shadow <= 16'h0000;
            scroll1_x_shadow <= 16'h0000;
            scroll1_y_shadow <= 16'h0000;
            bg_ctrl_shadow   <= 16'h0000;
            sprite_ctrl_shadow <= 16'h0000;
        end else if (~cs_n & ~wr_n & is_gpu) begin
            // CPU write to graphics control register
            // Only respond to addresses $120000-$12000A
            if (addr[4:3] == 2'b00) begin
                case (addr[3:1])
                    3'b000: scroll0_x_shadow <= din;  // $120000
                    3'b001: scroll0_y_shadow <= din;  // $120002
                    3'b010: scroll1_x_shadow <= din;  // $120004
                    3'b011: scroll1_y_shadow <= din;  // $120006
                    3'b100: bg_ctrl_shadow   <= din;  // $120008
                    3'b101: sprite_ctrl_shadow <= din; // $12000A
                    default: begin end
                endcase
            end
            // Writes to $12000C+ are ignored
        end
    end

    // ========== ACTIVE REGISTER LATCH (VBLANK SYNCHRONIZATION) ==========

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            scroll0_x_active   <= 16'h0000;
            scroll0_y_active   <= 16'h0000;
            scroll1_x_active   <= 16'h0000;
            scroll1_y_active   <= 16'h0000;
            bg_ctrl_active     <= 16'h0000;
            sprite_ctrl_active <= 16'h0000;
        end else if (vsync_falling_edge) begin
            // Copy shadow -> active on VBLANK falling edge
            scroll0_x_active   <= scroll0_x_shadow;
            scroll0_y_active   <= scroll0_y_shadow;
            scroll1_x_active   <= scroll1_x_shadow;
            scroll1_y_active   <= scroll1_y_shadow;
            bg_ctrl_active     <= bg_ctrl_shadow;
            sprite_ctrl_active <= sprite_ctrl_shadow;
        end
    end

    // ========== DATA OUTPUT MULTIPLEXER (CPU READS) ==========

    always_comb begin
        dout = 16'h0000;

        if (~cs_n & ~rd_n) begin
            if (is_gpu) begin
                // Graphics control register read
                // Only respond to addresses $120000-$12000E (3-bit offset within word)
                if (addr[4:3] == 2'b00) begin
                    case (addr[3:1])
                        3'b000: dout = scroll0_x_shadow;    // $120000
                        3'b001: dout = scroll0_y_shadow;    // $120002
                        3'b010: dout = scroll1_x_shadow;    // $120004
                        3'b011: dout = scroll1_y_shadow;    // $120006
                        3'b100: dout = bg_ctrl_shadow;      // $120008
                        3'b101: dout = sprite_ctrl_shadow;  // $12000A
                        3'b110: dout = 16'h0000;            // $12000C (reserved)
                        3'b111: dout = 16'h0000;            // $12000E (reserved)
                        default: dout = 16'h0000;
                    endcase
                end else begin
                    dout = 16'h0000;  // All other GPU addresses are reserved/mirrored
                end
            end else if (is_sprite) begin
                // Sprite RAM read (from internal or external BRAM)
                dout = sprite_data_rd_muxed;
            end else if (is_palette) begin
                // Palette RAM read (stub for now; actual palette in Gate 5)
                dout = 16'h0000;
            end
            // ROM/WRAM/IO reads handled externally
        end
    end

    // ========== SPRITE RAM STORAGE (Internal Dual-Port BRAM) ==========

    logic [15:0] sprite_ram_storage [0:1023];  // 256 sprites × 4 words
    logic [15:0] sprite_data_rd_muxed;

    // Write port (from CPU)
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            for (int i = 0; i < 1024; i++) begin
                sprite_ram_storage[i] <= 16'h01FF;
            end
        end else if (~cs_n & ~wr_n & is_sprite) begin
            sprite_ram_storage[addr[10:1]] <= din;
        end
    end

    // Read port (shared between CPU and Scanner via multiplexing)
    always_comb begin
        sprite_data_rd_muxed = sprite_ram_storage[sprite_addr_rd];
    end

    // ========== SPRITE RAM WRITE/READ INTERFACE (GATE 1) - Stubbed (internal BRAM used) ==========

    always_comb begin
        sprite_wr = 1'b0;  // Stub - writes handled by internal BRAM
        sprite_addr_wr = 10'h000;
        sprite_data_wr = 16'h0000;
        // Note: sprite_data_rd is an input port; in a real design, it would come from external BRAM
        // For testing, we internally generate it via sprite_data_rd_muxed
    end

    // ========== SPRITE RAM READ INTERFACE (GATE 1 + GATE 2 MULTIPLEXED) ==========
    // NOTE: Gate 2 sprite scanner has priority during SCAN state; CPU reads are stalled
    // (A real implementation would use dual-port BRAM to avoid conflicts)


    // ========== GATE 2: SPRITE SCANNER FSM ==========

    // FSM states
    typedef enum logic [1:0] {
        IDLE  = 2'b00,  // Waiting for VBLANK
        SCAN  = 2'b01,  // Scanning sprites
        DONE  = 2'b10   // Scan complete, ready for next frame
    } scanner_state_t;

    scanner_state_t scanner_state, scanner_next_state;
    logic [9:0] sprite_scan_idx;      // Current sprite index (0-255 × 4 words)
    logic [7:0] display_list_idx;     // Write index into display list

    // Display list arrays (internal)
    logic [8:0]  _display_list_x [0:255];
    logic [8:0]  _display_list_y [0:255];
    logic [11:0] _display_list_tile [0:255];
    logic        _display_list_flip_x [0:255];
    logic        _display_list_flip_y [0:255];
    logic [1:0]  _display_list_size [0:255];
    logic [3:0]  _display_list_palette [0:255];
    logic        _display_list_valid [0:255];

    // Temporary sprite read data (will be replaced by buffered capture)
    logic [8:0]  sprite_y_pos, sprite_x_pos;
    logic        sprite_is_visible;

    // ========== VBLANK EDGE DETECTION ==========

    logic vsync_falling_edge_scanner;
    always_comb begin
        vsync_falling_edge_scanner = vsync_n_r & ~vsync_n;  // 1 -> 0 transition
    end

    // ========== SPRITE SCANNER FSM ==========

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            scanner_state <= IDLE;
            sprite_scan_idx <= 10'h000;
            display_list_idx <= 8'h00;
        end else begin
            scanner_state <= scanner_next_state;

            case (scanner_state)
                IDLE: begin
                    // Hold display list from previous scan
                    sprite_scan_idx <= 10'h000;
                    // Reset display_list_idx when about to enter SCAN (VBLANK rising edge)
                    if (scanner_next_state == SCAN) begin
                        display_list_idx <= 8'h00;
                    end
                end

                SCAN: begin
                    // Advance sprite scan index each cycle
                    // sprite_scan_idx[9:2] = sprite number (0-255)
                    // sprite_scan_idx[1:0] = word offset within sprite (0-3)
                    // After processing word 3 (attributes), latch display list entry
                    if (sprite_scan_idx[1:0] == 2'b11) begin
                        if (sprite_is_visible) begin
                            display_list_idx <= display_list_idx + 1'b1;
                        end
                    end
                    // Always increment sprite_scan_idx, even on the last sprite
                    sprite_scan_idx <= sprite_scan_idx + 1'b1;
                end

                DONE: begin
                    sprite_scan_idx <= 10'h000;
                    // Hold display_list_idx (don't change it)
                end

                default: begin
                    sprite_scan_idx <= 10'h000;
                    display_list_idx <= 8'h00;
                end
            endcase
        end
    end

    // ========== SPRITE SCANNER STATE MACHINE TRANSITIONS ==========

    always_comb begin
        scanner_next_state = scanner_state;

        case (scanner_state)
            IDLE: begin
                if (vsync_falling_edge_scanner) begin
                    scanner_next_state = SCAN;
                end
            end

            SCAN: begin
                // Transition to DONE when all 256 sprites have been scanned
                // sprite_scan_idx increments from 0-1023, then wraps to 0
                // We transition when we've just processed the last sprite's word 3
                if (sprite_scan_idx == 10'h3FF) begin  // About to overflow on next increment
                    scanner_next_state = DONE;
                end
            end

            DONE: begin
                // Return to IDLE when VBLANK ends (vsync_n rises to 1)
                if (vsync_n) begin
                    scanner_next_state = IDLE;
                end
            end

            default: begin
                scanner_next_state = IDLE;
            end
        endcase
    end

    // ========== SPRITE RAM READ ARBITRATION (GATE 1 + GATE 2) ==========

    // Scanner has priority during SCAN state; CPU reads are stalled
    always_comb begin
        if (scanner_state == SCAN) begin
            // Scanner reads sprite RAM during VBLANK
            sprite_rd = 1'b1;
            sprite_addr_rd = sprite_scan_idx[9:0];
        end else begin
            // CPU reads sprite RAM (from Gate 1 CPU interface)
            sprite_rd = 1'b0;
            sprite_addr_rd = 10'h000;

            if (~cs_n & ~rd_n & is_sprite) begin
                sprite_rd = 1'b1;
                sprite_addr_rd = addr[10:1];  // 256 sprites × 4 words = 1024 addresses
            end
        end
    end

    // ========== SPRITE DATA CAPTURE (BUFFERED FOR TIMING) ==========

    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] sprite_word_y, sprite_word_x, sprite_word_tile, sprite_word_attr;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [8:0]  sprite_y_cached;  // Cache Y position when word 0 is read
    logic        sprite_visible_cached;

    localparam INACTIVE_Y = 9'h1FF;  // Y position sentinel for hidden sprites

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            sprite_word_y <= 16'h0000;
            sprite_word_x <= 16'h0000;
            sprite_word_tile <= 16'h0000;
            sprite_word_attr <= 16'h0000;
            sprite_y_cached <= 9'h000;
            sprite_visible_cached <= 1'b0;
        end else if (scanner_state == SCAN) begin
            // Capture sprite RAM data based on which word we're reading
            case (sprite_scan_idx[1:0])
                2'b00: begin
                    sprite_word_y <= sprite_data_rd_muxed;      // Word 0: Y
                    sprite_y_cached <= sprite_data_rd_muxed[8:0];  // Cache for visibility check
                    sprite_visible_cached <= (sprite_data_rd_muxed[8:0] != INACTIVE_Y);
                end
                2'b01: sprite_word_x <= sprite_data_rd_muxed;      // Word 1: X
                2'b10: sprite_word_tile <= sprite_data_rd_muxed;   // Word 2: Tile
                2'b11: sprite_word_attr <= sprite_data_rd_muxed;   // Word 3: Attributes
            endcase
        end
    end

    // ========== SPRITE VISIBILITY CHECK & EXTRACTION ==========

    always_comb begin
        sprite_y_pos = sprite_y_cached;
        sprite_x_pos = sprite_word_x[8:0];
        sprite_is_visible = sprite_visible_cached && (scanner_state == SCAN);
    end

    // ========== DISPLAY LIST WRITE ==========

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            for (int i = 0; i < 256; i = i + 1) begin
                _display_list_x[i] <= 9'h000;
                _display_list_y[i] <= 9'h000;
                _display_list_tile[i] <= 12'h000;
                _display_list_flip_x[i] <= 1'b0;
                _display_list_flip_y[i] <= 1'b0;
                _display_list_size[i] <= 2'b00;
                _display_list_palette[i] <= 4'h0;
                _display_list_valid[i] <= 1'b0;
            end
        end else if (scanner_state == SCAN && sprite_scan_idx[1:0] == 2'b11 && sprite_is_visible) begin
            // When word 3 (attributes) is captured and sprite is visible, write to display list
            _display_list_y[display_list_idx]       <= sprite_y_pos;
            _display_list_x[display_list_idx]       <= sprite_x_pos;
            _display_list_tile[display_list_idx]    <= sprite_word_tile[11:0];
            _display_list_flip_x[display_list_idx]  <= sprite_word_attr[10];
            _display_list_flip_y[display_list_idx]  <= sprite_word_attr[9];
            _display_list_size[display_list_idx]    <= sprite_word_attr[15:14];
            _display_list_palette[display_list_idx] <= sprite_word_attr[7:4];
            _display_list_valid[display_list_idx]   <= 1'b1;
        end
    end

    // ========== OUTPUT ASSIGNMENT (DISPLAY LIST) ==========

    always_comb begin
        for (int i = 0; i < 256; i = i + 1) begin
            display_list_x[i] = _display_list_x[i];
            display_list_y[i] = _display_list_y[i];
            display_list_tile[i] = _display_list_tile[i];
            display_list_flip_x[i] = _display_list_flip_x[i];
            display_list_flip_y[i] = _display_list_flip_y[i];
            display_list_size[i] = _display_list_size[i];
            display_list_palette[i] = _display_list_palette[i];
            display_list_valid[i] = _display_list_valid[i];
        end

        display_list_count = display_list_idx;
    end

    // ========== PULSE GENERATION ==========

    logic display_list_ready_r, irq_vblank_pulse_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            display_list_ready_r <= 1'b0;
            irq_vblank_pulse_r <= 1'b0;
        end else begin
            // Pulse when transitioning from SCAN to DONE
            display_list_ready_r <= (scanner_state == SCAN && scanner_next_state == DONE) ? 1'b1 : 1'b0;
            irq_vblank_pulse_r <= (scanner_state == SCAN && scanner_next_state == DONE) ? 1'b1 : 1'b0;
        end
    end

    assign display_list_ready = display_list_ready_r;
    assign irq_vblank_pulse = irq_vblank_pulse_r;

    // ========== LINT SUPPRESSION ==========

    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused = &{lds_n, uds_n, addr[20:11], status_reg,
                      sprite_word_y[15:9], sprite_word_x[15:9],
                      sprite_word_tile[15:12], sprite_word_attr[13:11], sprite_word_attr[8:0],
                      1'b0};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
