`default_nettype none
// =============================================================================
// TC0180VCU — Taito B Video Controller Unit
// =============================================================================
// Integrates all video functions for Taito B arcade hardware (1988–1994):
//   · Two 64×64 scrolling tilemap layers (BG + FG), 16×16 tiles, 4bpp
//   · One 64×32 text layer (TX), 8×8 tiles, 4bpp
//   · Sprite engine with zoom + multi-tile "big sprite" groups (up to 408 sprites)
//   · Double-buffered sprite framebuffer (sprites rendered during VBLANK)
//   · Per-block (down to per-line) scroll RAM for BG/FG
//   · Layer compositor: two priority modes (VIDEO_CTRL[3])
//
// MAME source: src/mame/taito/tc0180vcu.cpp (Nicola Salmoria / Jarek Burczynski)
// Games: Ninja Warriors, Crime City, Rastan Saga II, Rambo III, Thunder Fox, etc.
//
// CPU Interface (16-bit, 512KB address window):
//   0x00000–0x0FFFF: VRAM        (32K × 16-bit words — tile codes + attributes)
//   0x10000–0x1197F: Sprite RAM  (3072 × 16-bit words = 408 sprites × 8 words)
//   0x13800–0x13FFF: Scroll RAM  (1024 × 16-bit words — BG/FG per-block scroll)
//   0x18000–0x1801F: Ctrl regs   (16 × 16-bit, high byte significant)
//   0x40000–0x7FFFF: Framebuffer (CPU r/w access to sprite pixel framebuffer)
//
// Video output: 13-bit palette index per pixel (320×240 active)
//   Palette lookup handled externally by TC0260DAR
//
// =============================================================================

module tc0180vcu (
    input  logic        clk,
    input  logic        async_rst_n,

    // ── CPU Interface ──────────────────────────────────────────────────────
    // 19-bit address → 512KB window; 16-bit data; byte-lane enables
    input  logic        cpu_cs,          // chip select (active high)
    input  logic        cpu_we,          // write enable (1=write, 0=read)
    input  logic [18:0] cpu_addr,        // word address within 512KB window
    input  logic [15:0] cpu_din,         // write data
    input  logic [ 1:0] cpu_be,          // byte enables [1]=high, [0]=low
    output logic [15:0] cpu_dout,        // read data

    // ── Interrupts ─────────────────────────────────────────────────────────
    output logic        int_h,           // INTH: fires at VBLANK start
    output logic        int_l,           // INTL: fires ~8 lines after VBLANK

    // ── Video Timing (input) ───────────────────────────────────────────────
    input  logic        hblank_n,        // horizontal blank (active low)
    input  logic        vblank_n,        // vertical blank   (active low)
    input  logic [ 8:0] hpos,            // horizontal pixel position (0..511)
    input  logic [ 7:0] vpos,            // vertical scanline (0..255)

    // ── GFX ROM Interface ──────────────────────────────────────────────────
    // Tile/sprite pixel data fetched from external ROM (SDRAM in MiSTer)
    // Address: [22:0] = tile_code[14:0] + plane + pixel coordinates
    output logic [22:0] gfx_addr,        // GFX ROM byte address
    input  logic [ 7:0] gfx_data,        // GFX ROM read data
    output logic        gfx_rd,          // read strobe
    input  logic        gfx_ok,          // read data valid for current request

    // ── Video Output ───────────────────────────────────────────────────────
    output logic [12:0] pixel_out,       // palette index (0 = transparent/black)
    output logic        pixel_valid      // high during active display
);

// =============================================================================
// Reset synchronizer (section5 pattern)
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// =============================================================================
// Control Register Bank (16 × 16-bit, addresses 0x18000–0x1801F)
// Only high byte [15:8] is significant per MAME implementation.
// =============================================================================
logic [15:0] ctrl [0:15];

// Decoded control fields
logic [ 3:0] fg_bank0, fg_bank1;   // FG tile code / attribute bank (in 4K-word units)
logic [ 3:0] bg_bank0, bg_bank1;   // BG tile code / attribute bank
logic [ 7:0] fg_lpb_ctrl;          // FG lines-per-scroll-block control byte
logic [ 7:0] bg_lpb_ctrl;          // BG lines-per-scroll-block control byte
logic [ 5:0] tx_tilebank0;         // TX tile bank 0 (6-bit)
logic [ 5:0] tx_tilebank1;         // TX tile bank 1
logic [ 3:0] tx_rampage;           // TX VRAM page
logic [ 7:0] video_ctrl;           // video control byte

assign fg_bank0     = ctrl[0][11:8];
assign fg_bank1     = ctrl[0][15:12];
assign bg_bank0     = ctrl[1][11:8];
assign bg_bank1     = ctrl[1][15:12];
assign fg_lpb_ctrl  = ctrl[2][15:8];
assign bg_lpb_ctrl  = ctrl[3][15:8];
assign tx_tilebank0 = ctrl[4][13:8];
assign tx_tilebank1 = ctrl[5][13:8];
assign tx_rampage   = ctrl[6][11:8];
assign video_ctrl   = ctrl[7][15:8];

// Derived video control bits
logic screen_flip, sprite_priority, fb_manual, fb_page_sel, fb_no_erase;
assign screen_flip     = video_ctrl[4];
assign sprite_priority = video_ctrl[3];   // 1 = sprites above FG
assign fb_manual       = video_ctrl[7];   // 1 = manual page select
assign fb_page_sel     = video_ctrl[6];   // manual page (when fb_manual=1)
assign fb_no_erase     = video_ctrl[0];   // 1 = don't erase FB each vblank

// =============================================================================
// Memory regions — decoded from CPU address
// Region select (cpu_addr[18:15]):
//   0x0xxxx (addr[18:15]=0b0000x): VRAM        (addr[18:15]<2 → addr<0x10000)
//   0x10000..0x1197F:               Sprite RAM   (addr[18:15]=0b0001x, addr<0x11980)
//   0x13800..0x13FFF:               Scroll RAM   (addr[18:15]=0b0001x, addr>=0x13800)
//   0x18000..0x1801F:               Ctrl regs    (addr[18:15]=0b0001x, addr>=0x18000)
//   0x40000..0x7FFFF:               Framebuffer  (addr[18]=1)
// =============================================================================
logic sel_vram, sel_sprite, sel_scroll, sel_ctrl, sel_fb;
always_comb begin
    sel_vram   = cpu_cs && (cpu_addr[18:15] == 4'b0000);      // 0x00000–0x0FFFF
    sel_sprite = cpu_cs && (cpu_addr[18:13] == 6'b000100) &&  // 0x10000–0x1197F
                           (cpu_addr[12:0] <= 13'h0CBF);
    // 0x09C00–0x09FFF: addr[18:11]=0b00010011, addr[10]=1 (constant in range)
    // RAM index = addr[9:0] (0x000–0x3FF = 1024 entries)
    sel_scroll = cpu_cs && (cpu_addr[18:11] == 8'b00010011) &&
                           (cpu_addr[10] == 1'b1);
    sel_ctrl   = cpu_cs && (cpu_addr[18:5]  == 14'h0600);     // 0x0C000–0x0C01F (word addr)
    sel_fb     = cpu_cs && (cpu_addr[18]    == 1'b1);         // 0x40000–0x7FFFF
end

// =============================================================================
// VRAM: 32K × 16-bit = 64KB
// Holds tile codes + attributes for BG/FG/TX layers.
// `ifndef QUARTUS: flat array (Verilator/Yosys)
// `else: inferred M10K via altsyncram (Quartus)
// =============================================================================
`ifndef QUARTUS

logic [15:0] vram [0:32767];

always_ff @(posedge clk) begin
    if (sel_vram && cpu_we) begin
        if (cpu_be[1]) vram[cpu_addr[14:0]][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) vram[cpu_addr[14:0]][ 7:0] <= cpu_din[ 7:0];
    end
end
// No intermediate vram_dout register — cpu_dout reads directly from array (1-cycle latency)

// TX video read port: async combinational read (second port, no clock)
logic [14:0] tx_vram_rd_addr;
logic [15:0] tx_vram_q;
logic        tx_vram_rd;
logic        tx_vram_ok;
assign tx_vram_q = vram[tx_vram_rd_addr];
assign tx_vram_ok = tx_vram_rd;

// BG/FG video read ports: async combinational reads (third + fourth ports)
logic [14:0] bg_vram_rd_addr;
logic [15:0] bg_vram_q;
logic        bg_vram_rd;
logic        bg_vram_ok;
assign bg_vram_q = vram[bg_vram_rd_addr];
assign bg_vram_ok = bg_vram_rd;

logic [14:0] fg_vram_rd_addr;
logic [15:0] fg_vram_q;
logic        fg_vram_rd;
logic        fg_vram_ok;
assign fg_vram_q = vram[fg_vram_rd_addr];
assign fg_vram_ok = fg_vram_rd;

`else

// Quartus: two DUAL_PORT M10K instances (tc0110pcr pattern):
//   vram_pxl_inst: port A = CPU write, port B = TX/BG/FG video read
//   vram_cpu_inst: port A = CPU write, port B = CPU readback
// Both clocks tied to clk; port B on CLOCK1 to satisfy Quartus 17.0
// clock-domain consistency check. All optional ports explicitly connected.
logic [15:0] vram_dout;
logic [14:0] tx_vram_rd_addr;
logic [15:0] tx_vram_q;
logic        tx_vram_rd;
logic        tx_vram_ok;
logic [14:0] bg_vram_rd_addr;
logic [15:0] bg_vram_q;
logic        bg_vram_rd;
logic        bg_vram_ok;
logic [14:0] fg_vram_rd_addr;
logic [15:0] fg_vram_q;
logic        fg_vram_rd;
logic        fg_vram_ok;
logic [14:0] vram_pxl_addr_b;
logic [15:0] vram_pxl_q;
logic [1:0]  vram_pxl_sel_c;
logic [1:0]  vram_pxl_sel_r;
logic        vram_pxl_busy_r;

always_comb begin
    if (vram_pxl_busy_r) begin
        case (vram_pxl_sel_r)
            2'd1: begin
                vram_pxl_addr_b = tx_vram_rd_addr;
                vram_pxl_sel_c  = 2'd1;
            end
            2'd2: begin
                vram_pxl_addr_b = bg_vram_rd_addr;
                vram_pxl_sel_c  = 2'd2;
            end
            2'd3: begin
                vram_pxl_addr_b = fg_vram_rd_addr;
                vram_pxl_sel_c  = 2'd3;
            end
            default: begin
                vram_pxl_addr_b = 15'b0;
                vram_pxl_sel_c  = 2'd0;
            end
        endcase
    end else if (tx_vram_rd) begin
        vram_pxl_addr_b = tx_vram_rd_addr;
        vram_pxl_sel_c  = 2'd1;
    end else if (bg_vram_rd) begin
        vram_pxl_addr_b = bg_vram_rd_addr;
        vram_pxl_sel_c  = 2'd2;
    end else if (fg_vram_rd) begin
        vram_pxl_addr_b = fg_vram_rd_addr;
        vram_pxl_sel_c  = 2'd3;
    end else begin
        vram_pxl_addr_b = 15'b0;
        vram_pxl_sel_c  = 2'd0;
    end
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        vram_pxl_sel_r  <= 2'd0;
        vram_pxl_busy_r <= 1'b0;
    end else begin
        if (!vram_pxl_busy_r) begin
            if (vram_pxl_sel_c != 2'd0) begin
                vram_pxl_sel_r  <= vram_pxl_sel_c;
                vram_pxl_busy_r <= 1'b1;
            end
        end else begin
            vram_pxl_busy_r <= 1'b0;
        end
    end
end

assign tx_vram_q  = vram_pxl_q;
assign bg_vram_q  = vram_pxl_q;
assign fg_vram_q  = vram_pxl_q;
assign tx_vram_ok = vram_pxl_busy_r && (vram_pxl_sel_r == 2'd1);
assign bg_vram_ok = vram_pxl_busy_r && (vram_pxl_sel_r == 2'd2);
assign fg_vram_ok = vram_pxl_busy_r && (vram_pxl_sel_r == 2'd3);

// ── TX/BG/FG pixel read RAM ───────────────────────────────────────────────
altsyncram #(
    .operation_mode              ("DUAL_PORT"),
    .width_a                     (16), .widthad_a (15), .numwords_a (32768),
    .width_b                     (16), .widthad_b (15), .numwords_b (32768),
    .outdata_reg_b               ("CLOCK1"),
    .rdcontrol_reg_b             ("CLOCK1"),
    .clock_enable_input_a        ("BYPASS"),
    .clock_enable_input_b        ("BYPASS"),
    .clock_enable_output_b       ("BYPASS"),
    .intended_device_family      ("Cyclone V"),
    .lpm_type                    ("altsyncram"),
    .ram_block_type              ("M10K"),
    .width_byteena_a             (2),
    .power_up_uninitialized      ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) vram_pxl_inst (
    .clock0         ( clk                    ),
    .clock1         ( clk                    ),
    .address_a      ( cpu_addr[14:0]         ),
    .data_a         ( cpu_din                ),
    .wren_a         ( sel_vram && cpu_we     ),
    .byteena_a      ( cpu_be                 ),
    .address_b      ( vram_pxl_addr_b        ),
    .q_b            ( vram_pxl_q             ),
    .wren_b         ( 1'b0                   ),
    .data_b         ( 16'd0                  ),
    .q_a            (                        ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0  ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0  ),
    .byteena_b      ( 1'b1                   ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1  ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1  ),
    .eccstatus      (      ), .rden_a         (       ),
    .rden_b         ( 1'b1                   )
);

// ── CPU readback RAM ──────────────────────────────────────────────────────
altsyncram #(
    .operation_mode              ("DUAL_PORT"),
    .width_a                     (16), .widthad_a (15), .numwords_a (32768),
    .width_b                     (16), .widthad_b (15), .numwords_b (32768),
    .outdata_reg_b               ("CLOCK1"),
    .address_reg_b               ("CLOCK1"),
    .clock_enable_input_a        ("BYPASS"),
    .clock_enable_input_b        ("BYPASS"),
    .clock_enable_output_b       ("BYPASS"),
    .intended_device_family      ("Cyclone V"),
    .lpm_type                    ("altsyncram"),
    .ram_block_type              ("M10K"),
    .width_byteena_a             (2),
    .power_up_uninitialized      ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) vram_cpu_inst (
    .clock0         ( clk                    ),
    .clock1         ( clk                    ),
    .address_a      ( cpu_addr[14:0]         ),
    .data_a         ( cpu_din                ),
    .wren_a         ( sel_vram && cpu_we     ),
    .byteena_a      ( cpu_be                 ),
    .address_b      ( cpu_addr[14:0]         ),
    .q_b            ( vram_dout              ),
    .wren_b         ( 1'b0                   ),
    .data_b         ( 16'd0                  ),
    .q_a            (                        ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0  ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0  ),
    .byteena_b      ( 1'b1                   ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1  ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1  ),
    .eccstatus      (      ), .rden_a         (       ),
    .rden_b         ( 1'b1                   )
);

`endif

// =============================================================================
// Sprite RAM: 3264 × 16-bit (0x1980 bytes = 6528 bytes from 0x10000)
// 408 sprite entries × 8 words/entry
// =============================================================================
`ifndef QUARTUS

logic [15:0] sprite_ram [0:3263];

always_ff @(posedge clk) begin
    if (sel_sprite && cpu_we) begin
        if (cpu_be[1]) sprite_ram[cpu_addr[11:0]][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) sprite_ram[cpu_addr[11:0]][ 7:0] <= cpu_din[ 7:0];
    end
end
// Direct array read in cpu_dout block (1-cycle latency, no intermediate register)

// Sprite engine async read port
logic [11:0] spr_eng_rd_addr;
logic [15:0] spr_eng_q;
assign spr_eng_q = sprite_ram[spr_eng_rd_addr];

`else

logic [15:0] sprite_dout;
logic [11:0] spr_eng_rd_addr;
logic [15:0] spr_eng_q;
altsyncram #(
    .operation_mode         ("DUAL_PORT"),
    .width_a                (16),
    .widthad_a              (12),
    .width_b                (16),
    .widthad_b              (12),
    .intended_device_family ("Cyclone V"),
    .lpm_type               ("altsyncram"),
    .ram_block_type         ("M10K"),
    .outdata_reg_a          ("UNREGISTERED"),
    .outdata_reg_b          ("UNREGISTERED"),
    .numwords_a             (4096),
    .numwords_b             (4096),
    .width_byteena_a        (2),
    .read_during_write_mode_mixed_ports ("DONT_CARE")
) sprite_eng_inst (
    .clock0    (clk),
    .clock1    (clk),
    .address_a (cpu_addr[11:0]),
    .data_a    (cpu_din),
    .wren_a    (sel_sprite && cpu_we),
    .byteena_a (cpu_be),
    .q_a       (),
    .address_b (spr_eng_rd_addr),
    .q_b       (spr_eng_q),
    .wren_b    (1'b0),
    .data_b    (16'd0),
    .aclr0     (1'b0),
    .aclr1     (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .byteena_b (1'b1),
    .clocken0  (1'b1),
    .clocken1  (1'b1),
    .clocken2  (1'b1),
    .clocken3  (1'b1),
    .eccstatus (),
    .rden_a    (1'b1),
    .rden_b    (1'b1)
);

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
    .ram_block_type              ("M10K"),
    .width_byteena_a             (2),
    .power_up_uninitialized      ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) sprite_cpu_inst (
    .clock0         ( clk                    ),
    .clock1         ( clk                    ),
    .address_a      ( cpu_addr[11:0]         ),
    .data_a         ( cpu_din                ),
    .wren_a         ( sel_sprite && cpu_we   ),
    .byteena_a      ( cpu_be                 ),
    .address_b      ( cpu_addr[11:0]         ),
    .q_b            ( sprite_dout            ),
    .wren_b         ( 1'b0                   ),
    .data_b         ( 16'd0                  ),
    .q_a            (                        ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0  ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0  ),
    .byteena_b      ( 1'b1                   ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1  ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1  ),
    .eccstatus      (      ), .rden_a         (       ),
    .rden_b         ( 1'b1                   )
);

`endif

// =============================================================================
// Scroll RAM: 1024 × 16-bit (0x800 bytes from 0x13800)
// Word [9:0] within the scroll region (cpu_addr[9:0])
// Layout: [0x000–0x1FF] = FG (plane 0), [0x200–0x3FF] = BG (plane 1)
// Each scroll block i: scrollX = scrollram[plane*0x200 + i*2*lpb],
//                      scrollY = scrollram[plane*0x200 + i*2*lpb + 1]
// =============================================================================
`ifndef QUARTUS

logic [15:0] scroll_ram [0:1023];

always_ff @(posedge clk) begin
    if (sel_scroll && cpu_we) begin
        if (cpu_be[1]) scroll_ram[cpu_addr[9:0]][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) scroll_ram[cpu_addr[9:0]][ 7:0] <= cpu_din[ 7:0];
    end
end
// Direct array read in cpu_dout block (1-cycle latency)

// Async read ports for FG and BG submodules
logic [ 9:0] fg_scroll_rd_addr;
logic [15:0] fg_scroll_q;
logic        fg_scroll_rd;
logic        fg_scroll_ok;
assign fg_scroll_q = scroll_ram[fg_scroll_rd_addr];
assign fg_scroll_ok = fg_scroll_rd;

logic [ 9:0] bg_scroll_rd_addr;
logic [15:0] bg_scroll_q;
logic        bg_scroll_rd;
logic        bg_scroll_ok;
assign bg_scroll_q = scroll_ram[bg_scroll_rd_addr];
assign bg_scroll_ok = bg_scroll_rd;

`else

logic [15:0] scroll_dout;
logic [ 9:0] fg_scroll_rd_addr;
logic [15:0] fg_scroll_q;
logic        fg_scroll_rd;
logic        fg_scroll_ok;
logic [ 9:0] bg_scroll_rd_addr;
logic [15:0] bg_scroll_q;
logic        bg_scroll_rd;
logic        bg_scroll_ok;
logic [ 9:0] scroll_addr_b;
logic [15:0] scroll_q_b;
logic [1:0]  scroll_sel_c;
logic [1:0]  scroll_sel_r;
logic        scroll_busy_r;

always_comb begin
    if (scroll_busy_r) begin
        case (scroll_sel_r)
            2'd1: begin
                scroll_addr_b = bg_scroll_rd_addr;
                scroll_sel_c  = 2'd1;
            end
            2'd2: begin
                scroll_addr_b = fg_scroll_rd_addr;
                scroll_sel_c  = 2'd2;
            end
            default: begin
                scroll_addr_b = 10'b0;
                scroll_sel_c  = 2'd0;
            end
        endcase
    end else if (bg_scroll_rd) begin
        scroll_addr_b = bg_scroll_rd_addr;
        scroll_sel_c  = 2'd1;
    end else if (fg_scroll_rd) begin
        scroll_addr_b = fg_scroll_rd_addr;
        scroll_sel_c  = 2'd2;
    end else begin
        scroll_addr_b = 10'b0;
        scroll_sel_c  = 2'd0;
    end
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        scroll_sel_r <= 2'd0;
        scroll_busy_r <= 1'b0;
    end else begin
        if (!scroll_busy_r) begin
            if (scroll_sel_c != 2'd0) begin
                scroll_sel_r <= scroll_sel_c;
                scroll_busy_r <= 1'b1;
            end
        end else begin
            scroll_busy_r <= 1'b0;
        end
    end
end

assign bg_scroll_q  = scroll_q_b;
assign fg_scroll_q  = scroll_q_b;
assign bg_scroll_ok = scroll_busy_r && (scroll_sel_r == 2'd1);
assign fg_scroll_ok = scroll_busy_r && (scroll_sel_r == 2'd2);

altsyncram #(
    .operation_mode         ("DUAL_PORT"),
    .width_a                (16),
    .widthad_a              (10),
    .width_b                (16),
    .widthad_b              (10),
    .intended_device_family ("Cyclone V"),
    .lpm_type               ("altsyncram"),
    .ram_block_type         ("M10K"),
    .outdata_reg_a          ("UNREGISTERED"),
    .outdata_reg_b          ("CLOCK1"),
    .rdcontrol_reg_b        ("CLOCK1"),
    .numwords_a             (1024),
    .numwords_b             (1024),
    .width_byteena_a        (2),
    .read_during_write_mode_mixed_ports ("DONT_CARE")
) scroll_pxl_inst (
    .clock0    (clk),
    .clock1    (clk),
    .address_a (cpu_addr[9:0]),
    .data_a    (cpu_din),
    .wren_a    (sel_scroll && cpu_we),
    .byteena_a (cpu_be),
    .q_a       (),
    .address_b (scroll_addr_b),
    .q_b       (scroll_q_b),
    .wren_b    (1'b0),
    .data_b    (16'd0),
    .aclr0     (1'b0),
    .aclr1     (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .byteena_b (1'b1),
    .clocken0  (1'b1),
    .clocken1  (1'b1),
    .clocken2  (1'b1),
    .clocken3  (1'b1),
    .eccstatus (),
    .rden_a    (1'b1),
    .rden_b    (1'b1)
);

altsyncram #(
    .operation_mode              ("DUAL_PORT"),
    .width_a                     (16), .widthad_a (10), .numwords_a (1024),
    .width_b                     (16), .widthad_b (10), .numwords_b (1024),
    .outdata_reg_b               ("CLOCK1"),
    .address_reg_b               ("CLOCK1"),
    .clock_enable_input_a        ("BYPASS"),
    .clock_enable_input_b        ("BYPASS"),
    .clock_enable_output_b       ("BYPASS"),
    .intended_device_family      ("Cyclone V"),
    .lpm_type                    ("altsyncram"),
    .ram_block_type              ("M10K"),
    .width_byteena_a             (2),
    .power_up_uninitialized      ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) scroll_cpu_inst (
    .clock0         ( clk                    ),
    .clock1         ( clk                    ),
    .address_a      ( cpu_addr[9:0]          ),
    .data_a         ( cpu_din                ),
    .wren_a         ( sel_scroll && cpu_we   ),
    .byteena_a      ( cpu_be                 ),
    .address_b      ( cpu_addr[9:0]          ),
    .q_b            ( scroll_dout            ),
    .wren_b         ( 1'b0                   ),
    .data_b         ( 16'd0                  ),
    .q_a            (                        ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0  ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0  ),
    .byteena_b      ( 1'b1                   ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1  ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1  ),
    .eccstatus      (      ), .rden_a         (       ),
    .rden_b         ( 1'b1                   )
);

`endif

// =============================================================================
// Control Register Writes
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 16; i++) ctrl[i] <= 16'b0;
    end else if (sel_ctrl && cpu_we) begin
        if (cpu_be[1]) ctrl[cpu_addr[3:0]][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) ctrl[cpu_addr[3:0]][ 7:0] <= cpu_din[ 7:0];
    end
end

// =============================================================================
// Framebuffer: two 512×256 pages, 8bpp (65536 pixels per page)
// CPU-accessible at chip 0x40000–0x7FFFF.
// For Verilator/Yosys: flat BRAM. Quartus: external SDRAM (stub here).
// CPU address decoding for framebuffer:
//   cpu_addr[17:0] within the 256KB window (cpu_addr[18]=1)
//   word = cpu_addr[17:0]; pixel pair: high byte = left pixel, low byte = right
//   page: bit[17:16] selects page (2 pages × 128K words = 256KB)
// MAME layout: offset = (page*256 + sy)*256 + sx/2
//   → addr[17:16]=page[1:0] (only bit16 used for 2 pages), addr[15:9]=sy, addr[8:0]=sx_pair
// =============================================================================
logic       fb_page_reg;                // framebuffer active write page

// Page flip at VBLANK: toggle unless manual mode
logic vblank_n_prev;
always_ff @(posedge clk) vblank_n_prev <= vblank_n;
logic vblank_rise, vblank_fall;
assign vblank_fall = ~vblank_n & vblank_n_prev;  // start of VBLANK
assign vblank_rise =  vblank_n & ~vblank_n_prev; // end of VBLANK

always_ff @(posedge clk) begin
    if (!rst_n) begin
        fb_page_reg <= 1'b0;
    end else if (vblank_fall) begin
        if (fb_manual) fb_page_reg <= ~fb_page_sel;  // manual: use ctrl bit
        else           fb_page_reg <= ~fb_page_reg;  // auto: toggle
    end
end

// Display page = opposite of write page
logic display_page;
assign display_page = ~fb_page_reg;

`ifndef QUARTUS

// On-chip framebuffer (may be too large for on-chip BRAM in real Cyclone V:
// 512×256×2 pages = 262144 bytes, but Cyclone V 5CSEMA5 has ~4Mb on-chip.
// For Gate 1-3 testing this is acceptable. Gate 3b (Quartus) will flag overflow.
// In a real MiSTer core, framebuffer lives in SDRAM.
logic [7:0] framebuffer [0:1][0:255][0:511];  // [page][y][x]

// CPU framebuffer access
// Address: cpu_addr[18]=1, so within chip 0x40000-0x7FFFF
// Two pages of 512×256×8bpp = 0x10000 16-bit words per page.
// Layout: page = cpu_addr[16], sy[7:0] = cpu_addr[15:8], sx_pair[7:0] = cpu_addr[7:0]
// (cpu_addr[17] always 0 within 256KB FB window from base)
logic [16:0] fb_waddr;
logic [ 7:0] fb_sy;
logic [ 7:0] fb_sx_pair;
logic        fb_cpu_page;
assign fb_waddr    = cpu_addr[16:0];
assign fb_cpu_page = fb_waddr[16];
assign fb_sy       = fb_waddr[15:8];
assign fb_sx_pair  = fb_waddr[7:0];

// Sprite engine framebuffer write signals
logic        spr_fb_wr;
logic [ 8:0] spr_fb_wx;
logic [ 7:0] spr_fb_wy;
logic [ 7:0] spr_fb_wdata;
logic        spr_fb_erase;   // pulse: clear active write page

// ── Bulk erase FSM ─────────────────────────────────────────────────────────
// Counter-based clear of the entire active write page (512×256 pixels).
// Triggered by spr_fb_erase pulse from the sprite engine at VBLANK start.
// Runs during VBLANK; clears one pixel per cycle (131072 cycles total).
logic        erase_active;
// Flat 17-bit counter: counts 0..131071 (512×256 pixels).
// erase_y_c = cnt[16:9] (divides by 512), erase_x_c = cnt[8:0] (mod 512).
logic [16:0] erase_cnt;
logic [ 7:0] erase_y_c;
logic [ 8:0] erase_x_c;
assign erase_y_c = erase_cnt[16:9];   // erase_cnt / 512
assign erase_x_c = erase_cnt[ 8:0];   // erase_cnt % 512

always_ff @(posedge clk) begin
    if (!rst_n) begin
        erase_active <= 1'b0;
        erase_cnt    <= 17'b0;
    end else if (spr_fb_erase && !erase_active) begin
        erase_active <= 1'b1;
        erase_cnt    <= 17'b0;
    end else if (erase_active) begin
        if (erase_cnt == 17'd131071) begin
            erase_active <= 1'b0;
        end else begin
            erase_cnt <= erase_cnt + 17'd1;
        end
    end
end

// ── Per-line HBLANK erase FSM ───────────────────────────────────────────────
// During active display (vblank_n=1), erases one row of the write bank each
// HBLANK.  This mirrors the TC0180VCU hardware behaviour: the write bank is
// cleared line-by-line during HBLANK so that it is ready for the next frame's
// sprite render without a visible pop.  Only runs when fb_no_erase=0.
//
// Triggered by hblank_fall while vblank_n=1 and !fb_no_erase.
// Clears 512 pixels of row vpos in the write bank.
// Uses a 9-bit pixel counter; takes 512 cycles (fits well within HBLANK slack
// that the testbench provides).
logic        line_erase_active;
logic [ 8:0] line_erase_x;
logic [ 7:0] line_erase_row;   // vpos captured at hblank_fall

always_ff @(posedge clk) begin
    if (!rst_n) begin
        line_erase_active <= 1'b0;
        line_erase_x      <= 9'b0;
        line_erase_row    <= 8'b0;
    end else if (hblank_fall && vblank_n && !fb_no_erase && !line_erase_active) begin
        // Capture current scanline and start erasing
        line_erase_active <= 1'b1;
        line_erase_x      <= 9'b0;
        line_erase_row    <= vpos;
    end else if (line_erase_active) begin
        if (line_erase_x == 9'd511) begin
            line_erase_active <= 1'b0;
        end else begin
            line_erase_x <= line_erase_x + 9'd1;
        end
    end
end

always_ff @(posedge clk) begin
    // CPU writes (highest priority for correctness)
    if (sel_fb && cpu_we) begin
        if (cpu_be[1]) framebuffer[fb_cpu_page][fb_sy][{fb_sx_pair, 1'b0}] <= cpu_din[15:8];
        if (cpu_be[0]) framebuffer[fb_cpu_page][fb_sy][{fb_sx_pair, 1'b1}] <= cpu_din[ 7:0];
    end else if (erase_active) begin
        // Bulk erase: clear write page pixel-by-pixel during VBLANK
        framebuffer[fb_page_reg][erase_y_c][erase_x_c] <= 8'b0;
    end else if (line_erase_active) begin
        // Per-line HBLANK erase: clear one row of write bank during active display
        framebuffer[fb_page_reg][line_erase_row][line_erase_x] <= 8'b0;
    end else if (spr_fb_wr) begin
        // Sprite pixel write to active write page
        framebuffer[fb_page_reg][spr_fb_wy][spr_fb_wx] <= spr_fb_wdata;
    end
end

logic [15:0] fb_dout;
always_ff @(posedge clk) begin
    fb_dout[15:8] <= framebuffer[fb_cpu_page][fb_sy][{fb_sx_pair, 1'b0}];
    fb_dout[ 7:0] <= framebuffer[fb_cpu_page][fb_sy][{fb_sx_pair, 1'b1}];
end

`else

// Quartus: framebuffer in external SDRAM (stub — driven externally in top-level)
logic        spr_fb_wr;
logic [ 8:0] spr_fb_wx;
logic [ 7:0] spr_fb_wy;
logic [ 7:0] spr_fb_wdata;
logic        spr_fb_erase;
logic [15:0] fb_dout;
assign fb_dout = 16'b0;

`endif

// =============================================================================
// CPU Read Mux — 1-cycle latency (read registered into cpu_dout on clock edge)
// For `ifndef QUARTUS: reads directly from flat arrays (async read, 1 reg stage).
// For `else (Quartus): vram_dout/sprite_dout/scroll_dout come from altsyncram
//   with UNREGISTERED output → effectively async → same 1-cycle total latency.
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        cpu_dout <= 16'b0;
    end else if (cpu_cs && !cpu_we) begin
`ifndef QUARTUS
        if      (sel_vram)   cpu_dout <= vram[cpu_addr[14:0]];
        else if (sel_sprite) cpu_dout <= sprite_ram[cpu_addr[11:0]];
        else if (sel_scroll) cpu_dout <= scroll_ram[cpu_addr[9:0]];
`else
        if      (sel_vram)   cpu_dout <= vram_dout;
        else if (sel_sprite) cpu_dout <= sprite_dout;
        else if (sel_scroll) cpu_dout <= scroll_dout;
`endif
        else if (sel_ctrl)   cpu_dout <= ctrl[cpu_addr[3:0]];
        else if (sel_fb)     cpu_dout <= fb_dout;
        else                 cpu_dout <= 16'b0;
    end
end

// =============================================================================
// Interrupt Generation
// INTH fires at VBLANK start; INTL fires ~8 lines later.
// Both are pulse outputs — the external PAL latches and decodes them.
//
// intl_delay counts SCANLINES (hblank_fall events) not clock cycles.
// MAME: intl fires at screen.time_until_pos(vpos + 8) = 8 scanlines.
// =============================================================================
logic [ 3:0] intl_delay;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        int_h      <= 1'b0;
        int_l      <= 1'b0;
        intl_delay <= 4'b0;
    end else begin
        int_h <= 1'b0;
        int_l <= 1'b0;
        if (vblank_fall) begin
            int_h      <= 1'b1;
            intl_delay <= 4'd8;
        end
        // Count down only on hblank_fall (once per scanline) so the delay
        // is in scanlines, matching MAME's time_until_pos(vpos + 8).
        if (intl_delay != 4'b0 && hblank_fall) begin
            intl_delay <= intl_delay - 4'd1;
            if (intl_delay == 4'd1) int_l <= 1'b1;
        end
    end
end

// =============================================================================
// TX Tilemap Render Module
// =============================================================================
logic [ 7:0] tx_pixel_w;
logic [22:0] tx_gfx_addr;
logic        tx_gfx_rd;
logic        tx_gfx_ok;

tc0180vcu_tx u_tx (
    .clk          (clk),
    .rst_n        (rst_n),
    .hblank_n     (hblank_n),
    .vpos         (vpos),
    .hpos         (hpos),
    .vram_rd_addr (tx_vram_rd_addr),
    .vram_q       (tx_vram_q),
    .vram_rd      (tx_vram_rd),
    .vram_ok      (tx_vram_ok),
    .tx_tilebank0 (tx_tilebank0),
    .tx_tilebank1 (tx_tilebank1),
    .tx_rampage   (tx_rampage),
    .gfx_addr     (tx_gfx_addr),
    .gfx_data     (gfx_data),
    .gfx_rd       (tx_gfx_rd),
    .gfx_ok       (tx_gfx_ok),
    .tx_pixel     (tx_pixel_w),
    .busy         ()
);

// =============================================================================
// BG/FG Tilemap Render Modules
// =============================================================================
// Start sequencing: TX runs first (320 cycles), then BG, then FG.
// We detect TX going idle and pulse bg_start; detect BG idle and pulse fg_start.
//
// TX FSM is in TX_IDLE (3'd0) when not running.
// We use a registered "tx_was_busy" flag: set when TX leaves IDLE, clear when
// TX returns to IDLE (after 320 cycles). BG_start = falling edge of tx_was_busy.
//
// Since we cannot read TX's internal state directly, we track via hblank_fall
// and a cycle counter: TX takes 320 cycles (64 tiles × 5 states); BG takes
// up to 220 cycles (22 tiles × 10 states + 3 scroll-init = 223 cycles);
// FG takes same.
//
// Approach: pulse bg_start 321 cycles after hblank_fall; pulse fg_start 321+224
// cycles after hblank_fall. A 10-bit counter is sufficient.
// =============================================================================

// HBLANK falling edge detect (also used in TX, but we need it here for sequencing)
logic hblank_n_r;
always_ff @(posedge clk) begin
    if (!rst_n) hblank_n_r <= 1'b1;
    else        hblank_n_r <= hblank_n;
end
logic hblank_fall;
assign hblank_fall = ~hblank_n & hblank_n_r;

// Sequencing counter: counts cycles since hblank_fall
// Stops at 700 (well past all three layer completions)
logic [9:0] hblank_cyc;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        hblank_cyc <= 10'b0;
    end else if (hblank_fall) begin
        hblank_cyc <= 10'd1;
    end else if (hblank_cyc != 10'b0 && hblank_cyc < 10'd700) begin
        hblank_cyc <= hblank_cyc + 10'd1;
    end else if (hblank_n) begin
        hblank_cyc <= 10'b0;
    end
end

// TX finishes at cycle 320 (64 tiles × 5 states).
// Pulse bg_start at cycle 321.
// BG finishes at cycle 321+223 = 544.
// Pulse fg_start at cycle 545.
logic bg_start;
logic fg_start;
assign bg_start = (hblank_cyc == 10'd321);
assign fg_start = (hblank_cyc == 10'd545);

// BG instance (PLANE=1)
logic [22:0] bg_gfx_addr;
logic        bg_gfx_rd;
logic        bg_gfx_ok;
logic [ 9:0] bg_pixel_w;

tc0180vcu_bg #(.PLANE(1)) u_bg (
    .clk           (clk),
    .rst_n         (rst_n),
    .hblank_n      (hblank_n),
    .vpos          (vpos),
    .hpos          (hpos),
    .start         (bg_start),
    .vram_rd_addr  (bg_vram_rd_addr),
    .vram_q        (bg_vram_q),
    .vram_rd       (bg_vram_rd),
    .vram_ok       (bg_vram_ok),
    .scroll_rd_addr(bg_scroll_rd_addr),
    .scroll_q      (bg_scroll_q),
    .scroll_rd     (bg_scroll_rd),
    .scroll_ok     (bg_scroll_ok),
    .bank0         (bg_bank0),
    .bank1         (bg_bank1),
    .lpb_ctrl      (bg_lpb_ctrl),
    .gfx_addr      (bg_gfx_addr),
    .gfx_data      (gfx_data),
    .gfx_rd        (bg_gfx_rd),
    .gfx_ok        (bg_gfx_ok),
    .layer_pixel   (bg_pixel_w),
    .busy          ()
);

// FG instance (PLANE=0)
logic [22:0] fg_gfx_addr;
logic        fg_gfx_rd;
logic        fg_gfx_ok;
logic [ 9:0] fg_pixel_w;

tc0180vcu_bg #(.PLANE(0)) u_fg (
    .clk           (clk),
    .rst_n         (rst_n),
    .hblank_n      (hblank_n),
    .vpos          (vpos),
    .hpos          (hpos),
    .start         (fg_start),
    .vram_rd_addr  (fg_vram_rd_addr),
    .vram_q        (fg_vram_q),
    .vram_rd       (fg_vram_rd),
    .vram_ok       (fg_vram_ok),
    .scroll_rd_addr(fg_scroll_rd_addr),
    .scroll_q      (fg_scroll_q),
    .scroll_rd     (fg_scroll_rd),
    .scroll_ok     (fg_scroll_ok),
    .bank0         (fg_bank0),
    .bank1         (fg_bank1),
    .lpb_ctrl      (fg_lpb_ctrl),
    .gfx_addr      (fg_gfx_addr),
    .gfx_data      (gfx_data),
    .gfx_rd        (fg_gfx_rd),
    .gfx_ok        (fg_gfx_ok),
    .layer_pixel   (fg_pixel_w),
    .busy          ()
);

// =============================================================================
// Sprite Engine
// =============================================================================
logic [22:0] spr_gfx_addr;
logic        spr_gfx_rd;
logic        spr_gfx_ok;

typedef enum logic [1:0] {
    GFX_OWN_TX  = 2'd0,
    GFX_OWN_BG  = 2'd1,
    GFX_OWN_FG  = 2'd2,
    GFX_OWN_SPR = 2'd3
} gfx_owner_t;

gfx_owner_t gfx_owner_r;
logic       gfx_busy_r;

tc0180vcu_sprite u_sprite (
    .clk        (clk),
    .rst_n      (rst_n),
    .vblank_n   (vblank_n),
    .spr_rd_addr(spr_eng_rd_addr),
    .spr_q      (spr_eng_q),
    .gfx_addr   (spr_gfx_addr),
    .gfx_data   (gfx_data),
    .gfx_rd     (spr_gfx_rd),
    .gfx_ok     (spr_gfx_ok),
    .fb_wr      (spr_fb_wr),
    .fb_wx      (spr_fb_wx),
    .fb_wy      (spr_fb_wy),
    .fb_wdata   (spr_fb_wdata),
    .fb_erase   (spr_fb_erase),
    .no_erase   (fb_no_erase),
    .video_ctrl (video_ctrl)
);

// =============================================================================
// GFX ROM Arbitration
// TX/BG/FG run during HBLANK; sprite engine runs during VBLANK.
// They are time-disjoint, but use a priority mux to be safe:
//   TX > BG > FG > Sprite
// =============================================================================
assign tx_gfx_ok  = gfx_ok && gfx_busy_r && (gfx_owner_r == GFX_OWN_TX);
assign bg_gfx_ok  = gfx_ok && gfx_busy_r && (gfx_owner_r == GFX_OWN_BG);
assign fg_gfx_ok  = gfx_ok && gfx_busy_r && (gfx_owner_r == GFX_OWN_FG);
assign spr_gfx_ok = gfx_ok && gfx_busy_r && (gfx_owner_r == GFX_OWN_SPR);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        gfx_owner_r <= GFX_OWN_TX;
        gfx_busy_r  <= 1'b0;
    end else begin
        if (!gfx_busy_r) begin
            if (tx_gfx_rd) begin
                gfx_owner_r <= GFX_OWN_TX;
                gfx_busy_r  <= 1'b1;
            end else if (bg_gfx_rd) begin
                gfx_owner_r <= GFX_OWN_BG;
                gfx_busy_r  <= 1'b1;
            end else if (fg_gfx_rd) begin
                gfx_owner_r <= GFX_OWN_FG;
                gfx_busy_r  <= 1'b1;
            end else if (spr_gfx_rd) begin
                gfx_owner_r <= GFX_OWN_SPR;
                gfx_busy_r  <= 1'b1;
            end
        end else if (gfx_ok) begin
            gfx_busy_r <= 1'b0;
        end
    end
end

always_comb begin
    if (gfx_busy_r) begin
        case (gfx_owner_r)
            GFX_OWN_TX: begin
                gfx_addr = tx_gfx_addr;
                gfx_rd   = tx_gfx_rd;
            end
            GFX_OWN_BG: begin
                gfx_addr = bg_gfx_addr;
                gfx_rd   = bg_gfx_rd;
            end
            GFX_OWN_FG: begin
                gfx_addr = fg_gfx_addr;
                gfx_rd   = fg_gfx_rd;
            end
            default: begin
                gfx_addr = spr_gfx_addr;
                gfx_rd   = spr_gfx_rd;
            end
        endcase
    end else if (tx_gfx_rd) begin
        gfx_addr = tx_gfx_addr;
        gfx_rd   = 1'b1;
    end else if (bg_gfx_rd) begin
        gfx_addr = bg_gfx_addr;
        gfx_rd   = 1'b1;
    end else if (fg_gfx_rd) begin
        gfx_addr = fg_gfx_addr;
        gfx_rd   = 1'b1;
    end else if (spr_gfx_rd) begin
        gfx_addr = spr_gfx_addr;
        gfx_rd   = 1'b1;
    end else begin
        gfx_addr = 23'b0;
        gfx_rd   = 1'b0;
    end
end

// =============================================================================
// Pixel Output — Layer Compositor
// Priority mode 1 (sprite_priority=1): BG → FG → SP → TX
// Priority mode 0 (sprite_priority=0): BG → OBJ0 (sp[4]=0) → FG → OBJ1 (sp[4]≠0) → TX
//
// SP pixel comes from the DISPLAY page (opposite of write page) of the framebuffer.
// sp_pix[7:0] = {color[5:0], pix_idx[1:0]}; sp_pix==0 → transparent.
//
// pixel_out[12:0]:
//   TX:    {5'b0, color[3:0], pixel_idx[3:0]}  (8-bit from tx_pixel_w)
//   FG/BG: {3'b0, color[5:0], pixel_idx[3:0]}  (10-bit from fg/bg_pixel_w)
//   SP:    {5'b0, sp_pix[7:0]}                  (8-bit from framebuffer)
//
// Mode 0 is noted for step 8; step 5 implements mode 1 only.
// =============================================================================
logic [3:0]  tx_pix_idx;
logic [3:0]  fg_pix_idx;
logic [3:0]  bg_pix_idx;
logic [7:0]  sp_pix;
assign tx_pix_idx = tx_pixel_w[3:0];
assign fg_pix_idx = fg_pixel_w[3:0];
assign bg_pix_idx = bg_pixel_w[3:0];

`ifndef QUARTUS
assign sp_pix = framebuffer[display_page][vpos][hpos[8:0]];
`else
assign sp_pix = 8'b0;  // Quartus stub
`endif

always_comb begin
    if (tx_pix_idx != 4'b0) begin
        // TX always top
        pixel_out = {5'b0, tx_pixel_w};
    end else if (sprite_priority) begin
        // Mode 1: SP above FG
        if (sp_pix != 8'b0) begin
            pixel_out = {5'b0, sp_pix};
        end else if (fg_pix_idx != 4'b0) begin
            pixel_out = {3'b0, fg_pixel_w};
        end else if (bg_pix_idx != 4'b0) begin
            pixel_out = {3'b0, bg_pixel_w};
        end else begin
            pixel_out = 13'b0;
        end
    end else begin
        // Mode 0: OBJ0 below FG, OBJ1 above FG (step 8 full impl; for now same as mode 1)
        if (sp_pix != 8'b0 && sp_pix[4]) begin
            // OBJ1 (color bit 2 = sp_pix[4]) above FG
            pixel_out = {5'b0, sp_pix};
        end else if (fg_pix_idx != 4'b0) begin
            pixel_out = {3'b0, fg_pixel_w};
        end else if (sp_pix != 8'b0 && !sp_pix[4]) begin
            // OBJ0 below FG
            pixel_out = {5'b0, sp_pix};
        end else if (bg_pix_idx != 4'b0) begin
            pixel_out = {3'b0, bg_pixel_w};
        end else begin
            pixel_out = 13'b0;
        end
    end
end

assign pixel_valid = hblank_n & vblank_n;

// Suppress unused warnings for signals pending later steps
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{screen_flip,
                   vblank_rise,
                   video_ctrl[5], video_ctrl[2:1]};
/* verilator lint_on UNUSED */

endmodule
