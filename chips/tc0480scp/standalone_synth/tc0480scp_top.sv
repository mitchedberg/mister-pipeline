// =============================================================================
// TC0480SCP — Standalone Synthesis Harness
// =============================================================================
`default_nettype none

module tc0480scp_top (
    input  wire clk,
    output wire led
);

wire [15:0] cpu_dout;
wire [15:0] vram_dout;
wire hblank, vblank, hsync, vsync;
wire [9:0]  hpos;
wire [8:0]  vpos;
wire pixel_active, hblank_fall, vblank_fall;
wire [3:0][15:0] bgscrollx, bgscrolly, bgzoom;
wire [3:0][ 7:0] bg_dx, bg_dy;
wire [15:0] text_scrollx, text_scrolly;
wire dblwidth, flipscreen;
wire [2:0] priority_order;
wire rowzoom_en [2:3];
wire [15:0] bg_priority;
wire [3:0][31:0] gfx_addr;
wire [3:0] gfx_rd;
wire [15:0] pixel_out;
wire pixel_valid_out;

tc0480scp dut (
    .clk            (clk),
    .async_rst_n    (1'b1),

    // CPU control regs — idle
    .cpu_cs         (1'b0),
    .cpu_we         (1'b0),
    .cpu_addr       (5'd0),
    .cpu_din        (16'd0),
    .cpu_be         (2'd0),
    .cpu_dout       (cpu_dout),

    // VRAM — idle
    .vram_cs        (1'b0),
    .vram_we        (1'b0),
    .vram_addr      (15'd0),
    .vram_din       (16'd0),
    .vram_be        (2'd0),
    .vram_dout      (vram_dout),

    // Timing
    .hblank         (hblank),
    .vblank         (vblank),
    .hsync          (hsync),
    .vsync          (vsync),
    .hpos           (hpos),
    .vpos           (vpos),
    .pixel_active   (pixel_active),
    .hblank_fall    (hblank_fall),
    .vblank_fall    (vblank_fall),

    // Register outputs
    .bgscrollx      (bgscrollx),
    .bgscrolly      (bgscrolly),
    .bgzoom         (bgzoom),
    .bg_dx          (bg_dx),
    .bg_dy          (bg_dy),
    .text_scrollx   (text_scrollx),
    .text_scrolly   (text_scrolly),
    .dblwidth       (dblwidth),
    .flipscreen     (flipscreen),
    .priority_order (priority_order),
    .rowzoom_en     (rowzoom_en),
    .bg_priority    (bg_priority),

    // GFX ROM — return 0
    .gfx_addr       (gfx_addr),
    .gfx_data       ('0),
    .gfx_rd         (gfx_rd),

    // Pixel
    .pixel_out      (pixel_out),
    .pixel_valid_out(pixel_valid_out)
);

assign led = ^pixel_out ^ pixel_valid_out ^ vblank ^ flipscreen;

endmodule
