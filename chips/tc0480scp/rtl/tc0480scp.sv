`default_nettype none
// =============================================================================
// TC0480SCP — Taito Scrolling/Coloring Processor (Step 1: Skeleton + Timing
//             + Control Register Bank)
// =============================================================================
// Target hardware: Taito Z (Double Axle, Racing Beat), Taito F3-era
//   (Gunbuster, Ground Effects, Under Fire, Galastrm, Metalb, Slapshot, etc.)
//
// This step implements:
//   · Video timing generator (424×262 frame, 320×240 visible)
//   · All 24 control registers (tc0480scp_regs submodule)
//   · Decoded scroll/zoom/layer-control outputs
//   · Constant-zero pixel output (rendering added in later steps)
//
// Video timing (pixel-clock domain):
//   Source clock: 26.686 MHz / 4 = 6.6715 MHz (pixel clock)
//   MAME: set_raw(XTAL(26'686'000)/4, 424, 0, 320, 262, 16, 256)
//   H total : 424 pixels per line
//   H active: pixels 0–319   (320 wide)
//   H blank : pixels 320–423 (104 pixels; hblank_fall at hpos==320)
//   V total : 262 lines per frame
//   V active: lines 16–255   (240 lines)
//   V blank : lines 0–15 and 256–261
//   Refresh : 6.6715e6 / (424 × 262) ≈ 59.94 Hz
//
// CPU interface (68000 bus, 16-bit):
//   Control registers: cpu_cs_ctrl  → word addresses 0–23 (byte 0x00–0x2F)
//   VRAM (added Step 2): cpu_cs_vram → byte addresses 0x0000–0xFFFF
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
    // Typically mapped at CPU_base + 0x30000 (e.g. 0xA30000 in Double Axle).
    input  logic        cpu_cs,         // chip select (active high)
    input  logic        cpu_we,         // write enable (active high)
    input  logic [ 4:0] cpu_addr,       // word address within ctrl window (0..23)
    input  logic [15:0] cpu_din,        // write data
    input  logic [ 1:0] cpu_be,         // byte enables: bit1=upper, bit0=lower
    output logic [15:0] cpu_dout,       // read data

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

    // ── Pixel Output (Step 1: constant zero; rendering added later) ────────
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
// MAME: set_raw(XTAL(26'686'000)/4, 424, 0, 320, 262, 16, 256)
//   param order: pixclk, htotal, hbend, hbstart, vtotal, vbend, vbstart
//   hbend=0  → visible starts at hpos=0
//   hbstart=320 → hblank starts at hpos=320
//   vbend=16 → visible starts at vpos=16
//   vbstart=256 → vblank starts at vpos=256
localparam int H_TOTAL  = 424;
localparam int H_END    = 320;   // first hblank pixel
localparam int V_TOTAL  = 262;
localparam int V_START  = 16;    // first active line
localparam int V_END    = 256;   // first vblank line (after active)
localparam int H_SYNC_S = 336;   // hsync start (estimate: ~16px into hblank)
localparam int H_SYNC_E = 368;   // hsync end   (32px wide)
// V_SYNC_S = 0 (vsync starts at line 0; omitted — unsigned vpos >= 0 is trivially true)
localparam int V_SYNC_E = 4;     // vsync end   (4 lines wide)

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

// Combinational timing signals
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
        vsync  <= (vpos < 9'(V_SYNC_E));   // V_SYNC_S=0; unsigned vpos always >= 0
    end
end

// pixel_active: registered, reflects previous-cycle coordinates
// (follows same registration as hblank/vblank above)
always_ff @(posedge clk) begin
    if (!rst_n)
        pixel_active <= 1'b0;
    else
        pixel_active <= !hblank_int && !vblank_int;
end

// One-cycle fall pulses (registered, based on *current* hpos/vpos)
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
        // Rising edge of hblank_int = falling edge of active display
        hblank_fall <= hblank_int && !prev_hblank_int;
        vblank_fall <= vblank_int && !prev_vblank_int;
    end
end

// =============================================================================
// Control Register Bank (tc0480scp_regs)
// =============================================================================
// 24 × 16-bit registers, byte offsets 0x00–0x2F.
// cpu_addr[4:0] is the word index (0–23).
// =============================================================================
logic [15:0] ctrl [0:23];

// Register write
always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < 24; i++)
            ctrl[i] <= 16'h0000;
    end else if (cpu_cs && cpu_we && (cpu_addr <= 5'd23)) begin
        if (cpu_be[1]) ctrl[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) ctrl[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end

// Register read
always_comb begin
    cpu_dout = 16'h0000;
    if (cpu_cs && !cpu_we && (cpu_addr <= 5'd23))
        cpu_dout = ctrl[cpu_addr];
end

// ── LAYER_CTRL (word 15, byte 0x1E) decode ────────────────────────────────
// bit[15/7 in byte]: dblwidth  (MAME uses ctrl[15] as byte → bit 7 = 0x80 of low byte
//   BUT section1 says "Bit 15 (0x80)" which means bit 7 of the *byte*, i.e. bit 15
//   of the 16-bit word when written as a 16-bit register at byte 0x1E–0x1F.
//   MAME writes the byte register at offset 0x0F (byte within the ctrl[] array),
//   so the "bit 7 (0x80)" refers to the *byte* value. In 16-bit register terms this
//   is bits [15:8] of word 15 containing 0x80 → bit 15 of ctrl[15].
//   section1 §3.1 uses "Bit 15 (0x80)" notation meaning the high byte, bit 7.
//   We implement: dblwidth = ctrl[15][7] (low byte bit 7 = 0x80 in the byte the CPU writes).
// ─────────────────────────────────────────────────────────────────────────────
// MAME source note:  m_pri_reg stores the byte written to offset 0x0F.
// In our 16-bit word model, offset 0x0F maps to the *low byte* of word 15
// (byte address 0x1E is the high byte, 0x1F is the low byte; MAME offset 0x0F
// is the low byte).  Re-checking section1: "Bit 15 (0x80)" in the context of
// byte-addressed registers means 0x80 = bit 7 of the byte.  The register is at
// byte offset 0x1E–0x1F; MAME's ctrl[0x0F] accesses the low byte (0x1F).
// Therefore:
//   dblwidth        = ctrl[15][7]  (0x80 in the low byte = bit 7)
//   flipscreen      = ctrl[15][6]  (0x40)
//   bit5_unknown    = ctrl[15][5]  (0x20)
//   priority_order  = ctrl[15][4:2](0x1C → bits [4:2])
//   rowzoom_en[3]   = ctrl[15][1]  (0x02)
//   rowzoom_en[2]   = ctrl[15][0]  (0x01)
assign dblwidth       = ctrl[15][7];
assign flipscreen     = ctrl[15][6];
assign priority_order = ctrl[15][4:2];
assign rowzoom_en[2]  = ctrl[15][0];
assign rowzoom_en[3]  = ctrl[15][1];

// ── Priority LUT ──────────────────────────────────────────────────────────
// 8 entries × 16-bit: tc0480scp_bg_pri_lookup[8] =
//   {0x0123, 0x1230, 0x2301, 0x3012, 0x3210, 0x2103, 0x1032, 0x0321}
// section1 §3.2
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
// X scroll stagger (section1 §3.4):
//   BG0: bgscrollx[0] = -(ctrl[0])
//   BG1: bgscrollx[1] = -(ctrl[1] + 4)
//   BG2: bgscrollx[2] = -(ctrl[2] + 8)
//   BG3: bgscrollx[3] = -(ctrl[3] + 12)
//   Signs invert when flipscreen = 1.
//
// Y scroll (no stagger):
//   bgscrolly[n] = ctrl[4+n]   (non-flip)
//   bgscrolly[n] = -ctrl[4+n]  (flip)
//
// Words 0–3: BG0–BG3 XSCROLL
// Words 4–7: BG0–BG3 YSCROLL

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
        bg_dx[n] = ctrl[16 + n][ 7:0];  // low byte of BG0–BG3_DX (words 16–19)
        bg_dy[n] = ctrl[20 + n][ 7:0];  // low byte of BG0–BG3_DY (words 20–23)
    end
end

// ── Text scroll (words 12–13) ─────────────────────────────────────────────
assign text_scrollx = ctrl[12];
assign text_scrolly = ctrl[13];

// =============================================================================
// Pixel output (Step 1: constant zero — rendering added in later steps)
// =============================================================================
assign pixel_out       = 16'h0000;
assign pixel_valid_out = pixel_active;

endmodule
