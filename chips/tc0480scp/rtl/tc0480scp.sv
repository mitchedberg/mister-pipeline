`default_nettype none
// =============================================================================
// TC0480SCP — Taito Scrolling/Coloring Processor
// =============================================================================
// Step 1: Video timing + control register bank.
// Step 2: 64KB dual-port VRAM (tc0480scp_vram) wired in.
// Step 3: FG0 text layer (tc0480scp_textlayer) + compositor stub
//         (tc0480scp_colmix) wired in. pixel_out = text layer only.
// Step 4: BG0+BG1 tile engines (tc0480scp_bg) wired in, global scroll.
// Step 5: BG0+BG1 rowscroll (no-zoom path), BG2+BG3 wired in.
// Step 6: Global zoom (Y accumulator, X accumulator) for all BG layers.
// Step 7: BG2+BG3 colscroll (colscroll-before-rowzoom critical ordering).
// Step 8: BG2+BG3 per-row zoom (rowzoom RAM, x_step reduction, x_origin adj).
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
// VRAM port arbitration:
//   Port A: CPU read/write.
//   Port B (tf port): BG0–BG3 tile attribute/code reads (round-robin stagger).
//   Port C (sc port): text layer map/gfx reads + BG0–BG3 scroll/colscroll reads.
//                     BG scroll reads happen during HBLANK; text reads during active.
//                     Since text reads are all in HBLANK too (fill FSM), these
//                     are interleaved by time-stagger across layers.
//
// MAME source: src/mame/taito/tc0480scp.cpp (Nicola Salmoria)
//              src/mame/taito/taito_z.cpp (David Graves)
// =============================================================================

module tc0480scp (
    // ── Clocks and Reset ───────────────────────────────────────────────────
    input  logic        clk,            // pixel clock (6.6715 MHz in hardware)
    input  logic        async_rst_n,

    // ── CPU Interface — Control Registers ─────────────────────────────────
    input  logic        cpu_cs,
    input  logic        cpu_we,
    input  logic [ 4:0] cpu_addr,       // word address 0–23
    input  logic [15:0] cpu_din,
    input  logic [ 1:0] cpu_be,
    output logic [15:0] cpu_dout,

    // ── CPU Interface — VRAM (Step 2) ─────────────────────────────────────
    input  logic         vram_cs,
    input  logic         vram_we,
    input  logic  [14:0] vram_addr,
    input  logic  [15:0] vram_din,
    input  logic  [ 1:0] vram_be,
    output logic  [15:0] vram_dout,

    // ── Video Timing Outputs ───────────────────────────────────────────────
    output logic        hblank,
    output logic        vblank,
    output logic        hsync,
    output logic        vsync,
    output logic [ 9:0] hpos,
    output logic [ 8:0] vpos,
    output logic        pixel_active,
    output logic        hblank_fall,
    output logic        vblank_fall,

    // ── Decoded Register Outputs ───────────────────────────────────────────
    output logic [3:0][15:0] bgscrollx,
    output logic [3:0][15:0] bgscrolly,
    output logic [3:0][15:0] bgzoom,
    output logic [3:0][ 7:0] bg_dx,
    output logic [3:0][ 7:0] bg_dy,
    output logic [15:0] text_scrollx,
    output logic [15:0] text_scrolly,
    output logic        dblwidth,
    output logic        flipscreen,
    output logic [ 2:0] priority_order,
    output logic        rowzoom_en  [2:3],
    output logic [15:0] bg_priority,

    // ── GFX ROM interface (Steps 4+) — 4 independent read ports (one per BG) ─
    // Each BG engine gets its own address and data bus so simultaneous GFX
    // fetches from different engines never collide.
    // gfx_addr uses 32-bit elements (upper 11 bits unused) for clean C++ WData
    // access: dut->gfx_addr[n] == engine n's 21-bit address.
    output logic [3:0][31:0] gfx_addr,
    input  logic [3:0][31:0] gfx_data,
    output logic [3:0]       gfx_rd,

    // ── Pixel Output ──────────────────────────────────────────────────────
    output logic [15:0] pixel_out,
    output logic        pixel_valid_out
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

// ── LAYER_CTRL decode ─────────────────────────────────────────────────────
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
// VRAM wiring signals
// =============================================================================
// The VRAM has independent read ports for each BG engine (tile-fetch + scroll)
// and for the text layer (map + gfx).  This eliminates all port-contention
// between engines — each engine always reads its own correct data regardless
// of what any other engine is doing.  Hblank stagger is still used to ensure
// sc reads don't happen simultaneously (the sc output register is per-engine,
// so stagger prevents stale data issues with BG2/3 colscroll ordering).

// ── BG engine VRAM tile connections (tf port, 4 independent) ──────────────
logic [3:0][14:0] bg_vram_addr;
logic [3:0]       bg_vram_rd;
logic [3:0][15:0] bg_vram_q;

// ── BG engine SCRAM connections (sc port, 4 independent) ──────────────────
logic [3:0][14:0] bg_scram_addr;
logic [3:0]       bg_scram_rd;
logic [3:0][15:0] bg_scram_q;

// ── Text layer VRAM connections ───────────────────────────────────────────
logic [14:0] text_map_addr;
logic        text_map_rd;
logic [15:0] text_map_q;
logic [14:0] text_gfx_addr;
logic        text_gfx_rd;
logic [15:0] text_gfx_q;

// =============================================================================
// VRAM instance
// =============================================================================
tc0480scp_vram u_vram (
    .clk            (clk),
    .rst_n          (rst_n),

    // CPU port
    .cpu_cs         (vram_cs),
    .cpu_we         (vram_we),
    .cpu_addr       (vram_addr),
    .cpu_din        (vram_din),
    .cpu_be         (vram_be),
    .cpu_dout       (vram_dout),

    // BG tile-fetch ports (4 independent)
    .bg_tf_rd       (bg_vram_rd),
    .bg_tf_addr     (bg_vram_addr),
    .bg_tf_data     (bg_vram_q),

    // BG scroll/colscroll/rowzoom ports (4 independent)
    .bg_sc_rd       (bg_scram_rd),
    .bg_sc_addr     (bg_scram_addr),
    .bg_sc_data     (bg_scram_q),

    // Text layer map port
    .text_map_rd    (text_map_rd),
    .text_map_addr  (text_map_addr),
    .text_map_data  (text_map_q),

    // Text layer gfx port
    .text_gfx_rd    (text_gfx_rd),
    .text_gfx_addr  (text_gfx_addr),
    .text_gfx_data  (text_gfx_q)
);

// =============================================================================
// Text Layer (Step 3)
// =============================================================================
logic [ 9:0] text_pixel_raw;   // {color[5:0], pen[3:0]}

tc0480scp_textlayer u_text (
    .clk            (clk),
    .rst_n          (rst_n),
    .hblank         (hblank),
    .hpos           (hpos),
    .vpos           (vpos),
    .text_scrollx   (text_scrollx),
    .text_scrolly   (text_scrolly),
    // VRAM map port (sc port)
    .vram_map_addr  (text_map_addr),
    .vram_map_rd    (text_map_rd),
    .vram_map_q     (text_map_q),
    // VRAM gfx port (sc port)
    .vram_gfx_addr  (text_gfx_addr),
    .vram_gfx_rd    (text_gfx_rd),
    .vram_gfx_q     (text_gfx_q),
    // Output
    .text_pixel     (text_pixel_raw)
);

// =============================================================================
// BG Engines (Steps 4–8) — BG0, BG1, BG2, BG3
// =============================================================================
// Hblank stagger: each BG engine is delayed by 4 more cycles than the previous.
// This ensures sc port reads do not overlap (BG0/1 need 2 reads; BG2/3 need 4).
// With 4-cycle spacing: BG0 reads at t=0..1, BG1 at t=4..5, BG2 at t=8..11,
// BG3 at t=12..15. No overlap regardless of rowzoom_en state.
//
// hblank_bg[0] = hblank (undelayed → 2-FF internal detect inside engine)
// hblank_bg[1] = hblank delayed 4 cycles
// hblank_bg[2] = hblank delayed 8 cycles
// hblank_bg[3] = hblank delayed 12 cycles
// =============================================================================
logic [3:0][11:0] bg_pixel_raw;    // {color[7:0], pen[3:0]}
logic [3:0]       bg_valid_raw;
// bg_gfx_addr and bg_gfx_rd are now the top-level ports directly (no arbiter needed).

// Staggered hblank signals (4-cycle spacing between engines).
// Implemented as shift registers: hblank_dly[n][N-1] = hblank delayed N cycles.
// BG1 delay: 4 cycles, BG2 delay: 8 cycles, BG3 delay: 12 cycles.
logic [3:0] hblank_dly1;   // 4-element shift: [3] = 4-cycle delayed hblank
logic [7:0] hblank_dly2;   // 8-element shift: [7] = 8-cycle delayed hblank
logic [11:0] hblank_dly3;  // 12-element shift: [11] = 12-cycle delayed hblank

always_ff @(posedge clk) begin
    if (!rst_n) begin
        hblank_dly1 <= 4'b0;
        hblank_dly2 <= 8'b0;
        hblank_dly3 <= 12'b0;
    end else begin
        hblank_dly1 <= {hblank_dly1[2:0], hblank};
        hblank_dly2 <= {hblank_dly2[6:0], hblank};
        hblank_dly3 <= {hblank_dly3[10:0], hblank};
    end
end

logic hblank_bg1;
logic hblank_bg2;
logic hblank_bg3;
assign hblank_bg1 = hblank_dly1[3];
assign hblank_bg2 = hblank_dly2[7];
assign hblank_bg3 = hblank_dly3[11];

// BG0 — hblank undelayed
tc0480scp_bg #(.LAYER(0)) u_bg0 (
    .clk        (clk),
    .rst_n      (rst_n),
    .hblank     (hblank),
    .hpos       (hpos),
    .vpos       (vpos),
    .bgscrollx  (bgscrollx[0]),
    .bgscrolly  (bgscrolly[0]),
    .bgzoom     (bgzoom[0]),
    .bg_dx      (bg_dx[0]),
    .bg_dy      (bg_dy[0]),
    .dblwidth   (dblwidth),
    .flipscreen (flipscreen),
    .rowzoom_en (1'b0),
    .vram_addr  (bg_vram_addr[0]),
    .vram_rd    (bg_vram_rd[0]),
    .vram_q     (bg_vram_q[0]),
    .scram_addr (bg_scram_addr[0]),
    .scram_rd   (bg_scram_rd[0]),
    .scram_q    (bg_scram_q[0]),
    .gfx_addr   (gfx_addr[0][20:0]),
    .gfx_data   (gfx_data[0]),
    .gfx_rd     (gfx_rd[0]),
    .bg_pixel   (bg_pixel_raw[0]),
    .bg_valid   (bg_valid_raw[0])
);

// BG1 — hblank delayed 2 cycles
tc0480scp_bg #(.LAYER(1)) u_bg1 (
    .clk        (clk),
    .rst_n      (rst_n),
    .hblank     (hblank_bg1),
    .hpos       (hpos),
    .vpos       (vpos),
    .bgscrollx  (bgscrollx[1]),
    .bgscrolly  (bgscrolly[1]),
    .bgzoom     (bgzoom[1]),
    .bg_dx      (bg_dx[1]),
    .bg_dy      (bg_dy[1]),
    .dblwidth   (dblwidth),
    .flipscreen (flipscreen),
    .rowzoom_en (1'b0),
    .vram_addr  (bg_vram_addr[1]),
    .vram_rd    (bg_vram_rd[1]),
    .vram_q     (bg_vram_q[1]),
    .scram_addr (bg_scram_addr[1]),
    .scram_rd   (bg_scram_rd[1]),
    .scram_q    (bg_scram_q[1]),
    .gfx_addr   (gfx_addr[1][20:0]),
    .gfx_data   (gfx_data[1]),
    .gfx_rd     (gfx_rd[1]),
    .bg_pixel   (bg_pixel_raw[1]),
    .bg_valid   (bg_valid_raw[1])
);

// BG2 — hblank delayed 4 cycles
tc0480scp_bg #(.LAYER(2)) u_bg2 (
    .clk        (clk),
    .rst_n      (rst_n),
    .hblank     (hblank_bg2),
    .hpos       (hpos),
    .vpos       (vpos),
    .bgscrollx  (bgscrollx[2]),
    .bgscrolly  (bgscrolly[2]),
    .bgzoom     (bgzoom[2]),
    .bg_dx      (bg_dx[2]),
    .bg_dy      (bg_dy[2]),
    .dblwidth   (dblwidth),
    .flipscreen (flipscreen),
    .rowzoom_en (rowzoom_en[2]),
    .vram_addr  (bg_vram_addr[2]),
    .vram_rd    (bg_vram_rd[2]),
    .vram_q     (bg_vram_q[2]),
    .scram_addr (bg_scram_addr[2]),
    .scram_rd   (bg_scram_rd[2]),
    .scram_q    (bg_scram_q[2]),
    .gfx_addr   (gfx_addr[2][20:0]),
    .gfx_data   (gfx_data[2]),
    .gfx_rd     (gfx_rd[2]),
    .bg_pixel   (bg_pixel_raw[2]),
    .bg_valid   (bg_valid_raw[2])
);

// BG3 — hblank delayed 6 cycles
tc0480scp_bg #(.LAYER(3)) u_bg3 (
    .clk        (clk),
    .rst_n      (rst_n),
    .hblank     (hblank_bg3),
    .hpos       (hpos),
    .vpos       (vpos),
    .bgscrollx  (bgscrollx[3]),
    .bgscrolly  (bgscrolly[3]),
    .bgzoom     (bgzoom[3]),
    .bg_dx      (bg_dx[3]),
    .bg_dy      (bg_dy[3]),
    .dblwidth   (dblwidth),
    .flipscreen (flipscreen),
    .rowzoom_en (rowzoom_en[3]),
    .vram_addr  (bg_vram_addr[3]),
    .vram_rd    (bg_vram_rd[3]),
    .vram_q     (bg_vram_q[3]),
    .scram_addr (bg_scram_addr[3]),
    .scram_rd   (bg_scram_rd[3]),
    .scram_q    (bg_scram_q[3]),
    .gfx_addr   (gfx_addr[3][20:0]),
    .gfx_data   (gfx_data[3]),
    .gfx_rd     (gfx_rd[3]),
    .bg_pixel   (bg_pixel_raw[3]),
    .bg_valid   (bg_valid_raw[3])
);

// GFX ROM: each BG engine has a dedicated port — no arbitration needed.

// =============================================================================
// Color Compositor (tc0480scp_colmix)
// =============================================================================
logic [3:0][ 3:0] colmix_bg_pixel;
logic [3:0][ 7:0] colmix_bg_color;
logic [3:0]       colmix_bg_valid;

always_comb begin
    for (int n = 0; n < 4; n++) begin
        colmix_bg_pixel[n] = bg_pixel_raw[n][3:0];
        colmix_bg_color[n] = bg_pixel_raw[n][11:4];
        colmix_bg_valid[n] = bg_valid_raw[n];
    end
end

tc0480scp_colmix u_colmix (
    .clk            (clk),
    .rst_n          (rst_n),
    .pixel_active   (pixel_active),
    .bg_pixel       (colmix_bg_pixel),
    .bg_color       (colmix_bg_color),
    .bg_valid       (colmix_bg_valid),
    .bg_priority    (bg_priority),
    .text_pen       (text_pixel_raw[3:0]),
    .text_color     (text_pixel_raw[9:4]),
    .text_valid     (1'b1),
    .pixel_out      (pixel_out),
    .pixel_valid_out(pixel_valid_out)
);

endmodule
