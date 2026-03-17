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
    output logic                    sprite_rd,      // Sprite RAM read enable
    output logic [9:0]              sprite_addr_rd, // Sprite read address
    input  logic [15:0]             sprite_data_rd, // Sprite data from RAM

    // ======== STATUS REGISTER ========

    // Video status inputs
    input  logic                    vblank_irq,     // VBLANK interrupt flag
    input  logic                    sprite_done_irq // Sprite list done flag
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
                // Sprite RAM read (dual-port BRAM)
                dout = sprite_data_rd;
            end else if (is_palette) begin
                // Palette RAM read (stub for now; actual palette in Gate 5)
                dout = 16'h0000;
            end
            // ROM/WRAM/IO reads handled externally
        end
    end

    // ========== SPRITE RAM WRITE INTERFACE ==========

    always_comb begin
        sprite_wr = 1'b0;
        sprite_addr_wr = 10'h000;
        sprite_data_wr = 16'h0000;

        if (~cs_n & ~wr_n & is_sprite) begin
            sprite_wr = 1'b1;
            sprite_addr_wr = addr[10:1];  // 256 sprites × 4 words = 1024 addresses (word address)
            sprite_data_wr = din;
        end
    end

    // ========== SPRITE RAM READ INTERFACE ==========

    always_comb begin
        sprite_rd = 1'b0;
        sprite_addr_rd = 10'h000;

        if (~cs_n & ~rd_n & is_sprite) begin
            sprite_rd = 1'b1;
            sprite_addr_rd = addr[10:1];  // 256 sprites × 4 words = 1024 addresses (word address)
        end
    end

    // ========== LINT SUPPRESSION ==========

    logic _unused = &{lds_n, uds_n, addr[20:11], status_reg, 1'b0};

endmodule
