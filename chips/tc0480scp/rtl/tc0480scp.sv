`default_nettype none
// =============================================================================
// TC0480SCP — Taito Scrolling/Coloring Processor
// =============================================================================
// Step 1: Video timing + control register bank.
// Step 2: 64KB dual-port VRAM (tc0480scp_vram) wired in.
// Step 3: FG0 text layer (tc0480scp_textlayer) + compositor stub
//         (tc0480scp_colmix) wired in. pixel_out = text layer only.
// Step 4: BG0+BG1 tile engines (tc0480scp_bg) wired in.
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
//   Port B (tf port): text layer map reads, BG0–BG3 tile attribute/code reads.
//   Port C (sc port): text layer gfx reads, BG0–BG3 VRAM read requests.
//   Since text layer map reads (TL_MAP) and text layer gfx reads (TL_GFX0/GFX1)
//   never happen simultaneously, the same port serves both via the text layer.
//   BG engines get the same port; arbitration added in Step 9.
//
// GFX ROM interface:
//   The tc0480scp_bg modules output gfx_addr/gfx_rd.
//   Testbench drives gfx_data combinationally (as async ROM).
//   In Steps 3–4, gfx_addr is driven from BG0/BG1 directly.
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
    output logic [15:0] bgscrollx [0:3],
    output logic [15:0] bgscrolly [0:3],
    output logic [15:0] bgzoom    [0:3],
    output logic [ 7:0] bg_dx     [0:3],
    output logic [ 7:0] bg_dy     [0:3],
    output logic [15:0] text_scrollx,
    output logic [15:0] text_scrolly,
    output logic        dblwidth,
    output logic        flipscreen,
    output logic [ 2:0] priority_order,
    output logic        rowzoom_en  [2:3],
    output logic [15:0] bg_priority,

    // ── GFX ROM interface (Steps 4+) ──────────────────────────────────────
    output logic [20:0] gfx_addr,
    input  logic [31:0] gfx_data,
    output logic        gfx_rd,

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
// VRAM — internal wiring signals
// =============================================================================
// Port B (tf port) arbitration:
//   Exclusively used by BG engines (BG0 > BG1 priority).
//   Text layer does NOT use the tf port to avoid contention.
//
// Port C (sc port) arbitration:
//   Used by the text layer for BOTH map reads (TL_MAP) and gfx reads
//   (TL_GFX0/TL_GFX1). These never overlap within the text FSM.
//   In Step 9+ the sc port will also serve BG scroll/colscroll reads.

// Text layer VRAM connections
logic [14:0] text_map_addr;
logic        text_map_rd;
logic [15:0] text_map_q;
logic [14:0] text_gfx_addr;
logic        text_gfx_rd;
logic [15:0] text_gfx_q;

// BG engine VRAM connections (Step 4)
logic [14:0] bg_vram_addr [0:1];
logic        bg_vram_rd   [0:1];
logic [15:0] bg_vram_q    [0:1];

// VRAM port B (tf): BG0 > BG1 only
logic [14:0] tf_addr_mux;
logic        tf_rd_mux;
logic [15:0] tf_data_vram;

always_comb begin
    if (bg_vram_rd[0]) begin
        tf_addr_mux = bg_vram_addr[0];
        tf_rd_mux   = 1'b1;
    end else begin
        tf_addr_mux = bg_vram_addr[1];
        tf_rd_mux   = bg_vram_rd[1];
    end
end

assign bg_vram_q[0] = tf_data_vram;
assign bg_vram_q[1] = tf_data_vram;

// VRAM port C (sc): text layer map reads OR gfx reads (never simultaneous)
// text_map_rd and text_gfx_rd are mutually exclusive by FSM design:
//   TL_MAP drives text_map_rd; TL_GFX0/GFX1 drive text_gfx_rd.
logic [14:0] sc_addr_mux;
logic        sc_rd_mux;
logic [15:0] sc_data_vram;

always_comb begin
    if (text_map_rd) begin
        sc_addr_mux = text_map_addr;
        sc_rd_mux   = 1'b1;
    end else begin
        sc_addr_mux = text_gfx_addr;
        sc_rd_mux   = text_gfx_rd;
    end
end

// Both text_map_q and text_gfx_q come from the sc port result (broadcast)
assign text_map_q  = sc_data_vram;
assign text_gfx_q  = sc_data_vram;

// =============================================================================
// VRAM instance
// =============================================================================
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

    // Tile-fetch port (text map + BG tile reads)
    .tf_rd    (tf_rd_mux),
    .tf_addr  (tf_addr_mux),
    .tf_data  (tf_data_vram),

    // Scroll-read port (text gfx reads; BG scroll reads added later)
    .sc_rd    (sc_rd_mux),
    .sc_addr  (sc_addr_mux),
    .sc_data  (sc_data_vram)
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
    // VRAM map port (tf port)
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
// BG Engines (Step 4) — BG0 and BG1
// =============================================================================
// Each BG engine uses the tf VRAM port.  To avoid port contention, engines
// are staggered by 1 cycle each: BG0 fires first, BG1 fires 1 cycle later.
// In BG_CODE (VRAM read) BG0 occupies the port; in BG_GFX0/GFX1 BG0 does
// not use the VRAM port, so BG1 can use it.  The stagger is achieved by
// registering the hblank signal one extra time before feeding it to BG1.
// This adds only 1 cycle of hblank budget but ensures no simultaneous reads.
//
// Hblank pipeline for stagger:
//   hblank_bg[0] = hblank (direct output — one registered stage inside each engine)
//   hblank_bg[1] = hblank delayed 1 extra cycle
// =============================================================================
logic [11:0] bg_pixel_raw [0:3];   // {color[7:0], pen[3:0]}
logic        bg_valid_raw  [0:3];
logic [20:0] bg_gfx_addr  [0:1];
logic        bg_gfx_rd    [0:1];

// BG1 needs a 2-cycle stagger relative to BG0 to avoid both VRAM and GFX ROM
// port conflicts.  Each BG engine has an internal 2-FF hblank_rise detector, so
// a 2-cycle delay on the input hblank shifts hblank_rise by exactly 2 cycles.
//
// VRAM accesses per tile (offset from hblank_rise): 0,1, 4,5, 8,9, ...  (pairs)
// GFX ROM accesses per tile:                        2,3, 6,7, 10,11, ... (pairs)
// With 2-cycle stagger BG1 VRAM lands on 2,3,6,7,... and GFX on 4,5,8,9,...
// — no overlap with BG0 at any cycle.
logic hblank_bg1_r;   // hblank delayed 1 cycle
logic hblank_bg1;     // hblank delayed 2 cycles for BG1 stagger
always_ff @(posedge clk) begin
    if (!rst_n) begin
        hblank_bg1_r <= 1'b0;
        hblank_bg1   <= 1'b0;
    end else begin
        hblank_bg1_r <= hblank;
        hblank_bg1   <= hblank_bg1_r;
    end
end

// BG2 and BG3 tied off for now
assign bg_pixel_raw[2] = 12'b0;
assign bg_valid_raw[2] = 1'b1;
assign bg_pixel_raw[3] = 12'b0;
assign bg_valid_raw[3] = 1'b1;

// BG0 — fires on hblank (undelayed)
tc0480scp_bg #(.LAYER(0)) u_bg0 (
    .clk        (clk),
    .rst_n      (rst_n),
    .hblank     (hblank),
    .hpos       (hpos),
    .vpos       (vpos),
    .bgscrollx  (bgscrollx[0]),
    .bgscrolly  (bgscrolly[0]),
    .dblwidth   (dblwidth),
    .vram_addr  (bg_vram_addr[0]),
    .vram_rd    (bg_vram_rd[0]),
    .vram_q     (bg_vram_q[0]),
    .gfx_addr   (bg_gfx_addr[0]),
    .gfx_data   (gfx_data),
    .gfx_rd     (bg_gfx_rd[0]),
    .bg_pixel   (bg_pixel_raw[0]),
    .bg_valid   (bg_valid_raw[0])
);

// BG1 — fires on hblank delayed 1 cycle, ensuring no VRAM port conflict with BG0
tc0480scp_bg #(.LAYER(1)) u_bg1 (
    .clk        (clk),
    .rst_n      (rst_n),
    .hblank     (hblank_bg1),
    .hpos       (hpos),
    .vpos       (vpos),
    .bgscrollx  (bgscrollx[1]),
    .bgscrolly  (bgscrolly[1]),
    .dblwidth   (dblwidth),
    .vram_addr  (bg_vram_addr[1]),
    .vram_rd    (bg_vram_rd[1]),
    .vram_q     (bg_vram_q[1]),
    .gfx_addr   (bg_gfx_addr[1]),
    .gfx_data   (gfx_data),
    .gfx_rd     (bg_gfx_rd[1]),
    .bg_pixel   (bg_pixel_raw[1]),
    .bg_valid   (bg_valid_raw[1])
);

// GFX ROM arbitration: BG0 has priority over BG1 (they run on different tiles)
always_comb begin
    if (bg_gfx_rd[0]) begin
        gfx_addr = bg_gfx_addr[0];
        gfx_rd   = 1'b1;
    end else begin
        gfx_addr = bg_gfx_addr[1];
        gfx_rd   = bg_gfx_rd[1];
    end
end

// =============================================================================
// Color Compositor (tc0480scp_colmix)
// =============================================================================
// Expand layer pixel formats for colmix:
//   BG:   {color[7:0], pen[3:0]} → bg_color[7:0], bg_pen[3:0]
//   Text: {color[5:0], pen[3:0]} → text_color[5:0], text_pen[3:0]

logic [ 3:0] colmix_bg_pixel [0:3];
logic [ 7:0] colmix_bg_color [0:3];
logic        colmix_bg_valid [0:3];

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
