`default_nettype none
// =============================================================================
// TC0480SCP — Taito Scrolling/Coloring Processor
// =============================================================================
// Step 1: Video timing + control register bank.
// Step 2: 64KB dual-port VRAM (tc0480scp_vram) wired in.
//
// Video timing (pixel-clock domain):
//   Source clock: 26.686 MHz / 4 = 6.6715 MHz (pixel clock)
//   MAME: set_raw(XTAL(26'686'000)/4, 424, 0, 320, 262, 16, 256)
//   H total : 424 pixels per line
//   H active: pixels 0–319   (320 wide)
//   H blank : pixels 320–423 (hblank_fall at hpos==320)
//   V total : 262 lines per frame
//   V active: lines 16–255   (240 lines)
//   V blank : lines 0–15 and 256–261
//
// CPU interface (68000 bus, 16-bit):
//   Control registers: cpu_cs_ctrl  → word addresses 0–23 (byte 0x00–0x2F)
//   VRAM (Step 2):     cpu_cs_vram  → word addresses 0x0000–0x7FFF (byte 0x0000–0xFFFF)
//
// MAME source: src/mame/taito/tc0480scp.cpp (Nicola Salmoria)
//              src/mame/taito/taito_z.cpp (David Graves)
// =============================================================================

module tc0480scp (
    // ── Clocks and Reset ───────────────────────────────────────────────────
    input  logic        clk,            // pixel clock (6.6715 MHz in hardware)
    input  logic        async_rst_n,

    // ── CPU Interface — Control Registers ─────────────────────────────────
    // 0x30 byte window, word addresses 0–23.
    input  logic        cpu_cs,         // chip select (active high)
    input  logic        cpu_we,         // write enable (active high)
    input  logic [ 4:0] cpu_addr,       // word address within ctrl window (0..23)
    input  logic [15:0] cpu_din,        // write data
    input  logic [ 1:0] cpu_be,         // byte enables: bit1=upper, bit0=lower
    output logic [15:0] cpu_dout,       // read data

    // ── CPU Interface — VRAM (Step 2) ─────────────────────────────────────
    // 64KB window (byte 0x0000–0xFFFF = word 0x0000–0x7FFF).
    // vram_addr[14:0] is the 16-bit word address (= byte_addr >> 1).
    input  logic         vram_cs,
    input  logic         vram_we,
    input  logic  [14:0] vram_addr,
    input  logic  [15:0] vram_din,
    input  logic  [ 1:0] vram_be,
    output logic  [15:0] vram_dout,

    // ── Video Timing Outputs ───────────────────────────────────────────────
    output logic        hblank,         // horizontal blank (active high)
    output logic        vblank,         // vertical blank   (active high)
    output logic        hsync,          // horizontal sync  (active high)
    output logic        vsync,          // vertical sync    (active high)
    output logic [ 9:0] hpos,           // pixel counter 0..423
    output logic [ 8:0] vpos,           // line counter  0..261
    output logic        pixel_active,   // high during visible area (0–319, 16–255)
    output logic        hblank_fall,    // one-cycle pulse at start of HBLANK (hpos==320)
    output logic        vblank_fall,    // one-cycle pulse at start of VBLANK (vpos==256)

    // ── Decoded Register Outputs (for submodules added in later steps) ─────
    output logic [15:0] bgscrollx [0:3],    // BG0–BG3 effective X scroll
    output logic [15:0] bgscrolly [0:3],    // BG0–BG3 Y scroll
    output logic [15:0] bgzoom    [0:3],    // BG0–BG3 zoom word (raw)
    output logic [ 7:0] bg_dx     [0:3],    // BG0–BG3 sub-pixel X
    output logic [ 7:0] bg_dy     [0:3],    // BG0–BG3 sub-pixel Y
    output logic [15:0] text_scrollx,       // FG0 X scroll
    output logic [15:0] text_scrolly,       // FG0 Y scroll
    output logic        dblwidth,           // LAYER_CTRL bit[7]: double-width tilemap
    output logic        flipscreen,         // LAYER_CTRL bit[6]: screen flip
    output logic [ 2:0] priority_order,     // LAYER_CTRL bits[4:2]
    output logic        rowzoom_en  [2:3],  // LAYER_CTRL bit[0]=BG2, bit[1]=BG3
    output logic [15:0] bg_priority,        // decoded 4-nibble priority word

    // ── GFX ROM interface (Steps 4+; shared by all BG engines) ───────────
    // GFX ROM is combinational. Testbench drives gfx_data based on gfx_addr.
    output logic [20:0] gfx_addr,          // 21-bit word address into GFX ROM
    input  logic [31:0] gfx_data,          // 32-bit GFX ROM data
    output logic        gfx_rd,            // read strobe (for SDRAM interface)

    // ── Pixel Output (rendering added in later steps) ─────────────────────
    output logic [15:0] pixel_out,          // 16-bit palette index → TC0360PRI
    output logic        pixel_valid_out     // asserted during active display
);

// =============================================================================
// Reset synchronizer (2-FF)
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
logic rst_n;
assign rst_n = rst_pipe[1];

// =============================================================================
// Video Timing Generator
// =============================================================================
localparam int H_TOTAL  = 424;
localparam int H_END    = 320;
localparam int V_TOTAL  = 262;
localparam int V_START  = 16;
localparam int V_END    = 256;
localparam int H_SYNC_S = 336;
localparam int H_SYNC_E = 368;
localparam int V_SYNC_E = 4;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        hpos <= 10'b0;
        vpos <=  9'b0;
    end else begin
        if (hpos == 10'(H_TOTAL - 1)) begin
            hpos <= 10'b0;
            if (vpos == 9'(V_TOTAL - 1))
                vpos <= 9'b0;
            else
                vpos <= vpos + 9'b1;
        end else begin
            hpos <= hpos + 10'b1;
        end
    end
end

logic hblank_int;
logic vblank_int;
assign hblank_int = (hpos >= H_END[9:0]);
assign vblank_int = (vpos < V_START[8:0]) || (vpos >= V_END[8:0]);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        hblank <= 1'b0;
        vblank <= 1'b0;
        hsync  <= 1'b0;
        vsync  <= 1'b0;
    end else begin
        hblank <= hblank_int;
        vblank <= vblank_int;
        hsync  <= (hpos >= H_SYNC_S[9:0]) && (hpos < H_SYNC_E[9:0]);
        vsync  <= (vpos < 9'(V_SYNC_E));
    end
end

always_ff @(posedge clk) begin
    if (!rst_n)
        pixel_active <= 1'b0;
    else
        pixel_active <= !hblank_int && !vblank_int;
end

logic prev_hblank_int;
logic prev_vblank_int;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        prev_hblank_int <= 1'b0;
        prev_vblank_int <= 1'b0;
        hblank_fall     <= 1'b0;
        vblank_fall     <= 1'b0;
    end else begin
        prev_hblank_int <= hblank_int;
        prev_vblank_int <= vblank_int;
        hblank_fall <= hblank_int && !prev_hblank_int;
        vblank_fall <= vblank_int && !prev_vblank_int;
    end
end

// =============================================================================
// Control Register Bank
// =============================================================================
logic [15:0] ctrl [0:23];

always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 24; i++)
            ctrl[i] <= 16'h0000;
    end else if (cpu_cs && cpu_we && (cpu_addr <= 5'd23)) begin
        if (cpu_be[1]) ctrl[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) ctrl[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end

always_comb begin
    cpu_dout = 16'h0000;
    if (cpu_cs && !cpu_we && (cpu_addr <= 5'd23))
        cpu_dout = ctrl[cpu_addr];
end

// ── LAYER_CTRL (word 15) decode ───────────────────────────────────────────
assign dblwidth       = ctrl[15][7];
assign flipscreen     = ctrl[15][6];
assign priority_order = ctrl[15][4:2];
assign rowzoom_en[2]  = ctrl[15][0];
assign rowzoom_en[3]  = ctrl[15][1];

// ── Priority LUT ─────────────────────────────────────────────────────────
logic [15:0] PRI_LUT [0:7];
assign PRI_LUT[0] = 16'h0123;
assign PRI_LUT[1] = 16'h1230;
assign PRI_LUT[2] = 16'h2301;
assign PRI_LUT[3] = 16'h3012;
assign PRI_LUT[4] = 16'h3210;
assign PRI_LUT[5] = 16'h2103;
assign PRI_LUT[6] = 16'h1032;
assign PRI_LUT[7] = 16'h0321;
assign bg_priority = PRI_LUT[priority_order];

// ── Scroll decode ─────────────────────────────────────────────────────────
localparam logic [15:0] STAGGER [0:3] = '{16'd0, 16'd4, 16'd8, 16'd12};

always_comb begin
    for (int n = 0; n < 4; n++) begin
        if (!flipscreen) begin
            bgscrollx[n] = -(ctrl[n] + STAGGER[n]);
            bgscrolly[n] =   ctrl[4 + n];
        end else begin
            bgscrollx[n] =  (ctrl[n] + STAGGER[n]);
            bgscrolly[n] = -ctrl[4 + n];
        end
    end
end

// ── Zoom (words 8–11) ─────────────────────────────────────────────────────
always_comb begin
    for (int n = 0; n < 4; n++)
        bgzoom[n] = ctrl[8 + n];
end

// ── DX/DY sub-pixel (words 16–23) ─────────────────────────────────────────
always_comb begin
    for (int n = 0; n < 4; n++) begin
        bg_dx[n] = ctrl[16 + n][ 7:0];
        bg_dy[n] = ctrl[20 + n][ 7:0];
    end
end

// ── Text scroll (words 12–13) ─────────────────────────────────────────────
assign text_scrollx = ctrl[12];
assign text_scrolly = ctrl[13];

// =============================================================================
// VRAM (Step 2) — tc0480scp_vram instance
// =============================================================================
// Tile-fetch and scroll-read ports are tied off (no BG/text engines yet).
// They will be connected in Steps 3 and 4.

/* verilator lint_off UNUSED */
logic [15:0] vram_tf_data_nc;
logic [15:0] vram_sc_data_nc;
/* verilator lint_on UNUSED */

tc0480scp_vram u_vram (
    .clk      (clk),
    .rst_n    (rst_n),

    // CPU port
    .cpu_cs   (vram_cs),
    .cpu_we   (vram_we),
    .cpu_addr (vram_addr),
    .cpu_din  (vram_din),
    .cpu_be   (vram_be),
    .cpu_dout (vram_dout),

    // Tile-fetch port (unused this step)
    .tf_rd    (1'b0),
    .tf_addr  (15'b0),
    .tf_data  (vram_tf_data_nc),

    // Scroll-read port (unused this step)
    .sc_rd    (1'b0),
    .sc_addr  (15'b0),
    .sc_data  (vram_sc_data_nc)
);

// =============================================================================
// GFX ROM (tied off — wired to BG engines in Step 4)
// =============================================================================
assign gfx_addr = 21'b0;
assign gfx_rd   = 1'b0;

/* verilator lint_off UNUSED */
logic _unused_gfx;
assign _unused_gfx = ^gfx_data;
/* verilator lint_on UNUSED */

// =============================================================================
// Pixel output (rendering added in later steps)
// =============================================================================
assign pixel_out       = 16'h0000;
assign pixel_valid_out = pixel_active;

endmodule
