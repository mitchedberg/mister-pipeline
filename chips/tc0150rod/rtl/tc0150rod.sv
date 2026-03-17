`default_nettype none
// =============================================================================
// TC0150ROD — Taito Road Chip
// =============================================================================
// Step 1: Road RAM (0x1000 × 16-bit) + CPU interface + control-word decode.
// Step 2: RAM reader — 8-word fetch per HBlank, geometry & priority compute.
// Step 3: Line renderer — Road A + Road B body/edge fill, arbitration.
// Step 4: ROM pre-fetcher — tile cache (2 × 256 words) via toggle-req/ack.
// Step 5: Scanline output — pix_out/pix_valid/pix_transp during active display.
//
// Video timing (same as TC0480SCP):
//   H_TOTAL=424, H_END=320, V_TOTAL=262, V_START=16, V_END=256
//
// MAME source: src/mame/taito/tc0150rod.cpp (Nicola Salmoria)
// FBNeo source: src/burn/drv/taito/tc0150rod.cpp
// =============================================================================

module tc0150rod (
    input  logic        clk,
    input  logic        rst_n,

    // ── CPU B bus interface ──────────────────────────────────────────────────
    input  logic        cpu_cs,
    input  logic        cpu_we,
    input  logic [11:0] cpu_addr,     // word address [0..0xFFF]
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input  logic  [1:0] cpu_be,       // UDS=be[1], LDS=be[0]
    output logic        cpu_dtack_n,

    // ── GFX ROM interface (toggle-req/ack SDRAM arbiter) ────────────────────
    output logic [17:0] rom_addr,     // word address into 512KB GFX ROM
    input  logic [15:0] rom_data,
    output logic        rom_req,
    input  logic        rom_ack,

    // ── Video timing inputs ──────────────────────────────────────────────────
    input  logic        hblank,
    input  logic        vblank,
    input  logic  [8:0] hpos,
    input  logic  [7:0] vpos,

    // ── Game-specific rendering parameters ──────────────────────────────────
    input  logic signed [7:0] y_offs,
    input  logic  [7:0] palette_offs,
    input  logic  [1:0] road_type,
    input  logic        road_trans,
    input  logic  [7:0] low_priority,
    input  logic  [7:0] high_priority,

    // ── Scanline pixel output ────────────────────────────────────────────────
    output logic [14:0] pix_out,
    output logic        pix_valid,
    output logic        pix_transp,
    output logic  [7:0] line_priority,

    // ── Testbench / status outputs ────────────────────────────────────────
    output logic        render_done    // pulses for one cycle when scanline[] is ready
);

// =============================================================================
// Video timing constants
// =============================================================================
localparam int H_END   = 320;
localparam int V_START = 16;
localparam int W       = 320;

// =============================================================================
// Step 1 — Road RAM (0x1000 × 16-bit)
// =============================================================================

logic [15:0] road_ram [0:4095];

// CPU port — byte-enable write, 1-cycle DTACK
always_ff @(posedge clk) begin
    cpu_dtack_n <= 1'b0;
    if (cpu_cs && cpu_we) begin
        if (cpu_be[1]) road_ram[cpu_addr][15:8] <= cpu_din[15:8];
        if (cpu_be[0]) road_ram[cpu_addr][ 7:0] <= cpu_din[ 7:0];
    end
end

always_ff @(posedge clk) begin
    if (cpu_cs && !cpu_we)
        cpu_dout <= road_ram[cpu_addr];
end

// Internal read port — combinational (address-to-data with no register stage)
// Each FSM state sets ram_rd_addr; the data appears immediately on ram_rd_data
// for the NEXT state to latch, since the NBA for ram_rd_addr commits between cycles.
logic [11:0] ram_rd_addr;
wire  [15:0] ram_rd_data = road_ram[ram_rd_addr];

// =============================================================================
// Step 2 — Control-word decode + RAM-reader FSM state signals
// =============================================================================

logic  [7:0] priority_switch_line;
logic [11:0] road_a_base;
logic [11:0] road_b_base;

// Per-scanline road control fields (only bits used by renderer)
// clip word: bit15=bg_fill, bit13=pri_mod, bit12=pal_offs, bits9:0=edge_width
// body word: bit15=bg_flag, bit13=pri_mod, bits12:11=pal_offs, bits10:0=xoffset
logic        roada_clipr_bg,  roada_clipr_pm, roada_clipr_po;
logic  [9:0] roada_clipr_w;
logic        roada_clipl_bg,  roada_clipl_pm, roada_clipl_po;
logic  [9:0] roada_clipl_w;
logic        roada_body_pm;
logic  [1:0] roada_body_po;
logic [10:0] roada_xoff;
logic  [9:0] tile_a;
logic  [5:0] colbank_a;

logic        roadb_clipr_bg,  roadb_clipr_pm, roadb_clipr_po;
logic  [9:0] roadb_clipr_w;
logic        roadb_clipl_bg,  roadb_clipl_pm, roadb_clipl_po;
logic  [9:0] roadb_clipl_w;
logic        roadb_body_pm;
logic  [1:0] roadb_body_po;
logic [10:0] roadb_xoff;
logic  [9:0] tile_b;
logic  [5:0] colbank_b;

// Geometry
logic [10:0] left_edge_a, right_edge_a;
logic [10:0] left_edge_b, right_edge_b;
logic [10:0] xoffset_a, xoffset_b;

// Priority table
logic [2:0] priorities [0:5];

// Misc
logic road_b_en;

// Merged scanline buffer
logic [15:0] scanline [0:319];
logic  [7:0] scanline_priority;

// HBlank rising edge
logic hblank_d;
wire  hblank_rise = hblank && !hblank_d;
always_ff @(posedge clk) hblank_d <= hblank;

// =============================================================================
// Step 4 — ROM tile cache (2 × 256 × 16-bit)
// =============================================================================

logic [15:0] cache_a [0:255];
logic [15:0] cache_b [0:255];
logic  [9:0] cached_tile_a;
logic  [9:0] cached_tile_b;
logic        cache_ready;

typedef enum logic [2:0] {
    RF_IDLE   = 3'd0,
    RF_LOAD_A = 3'd1,
    RF_WAIT_A = 3'd2,
    RF_LOAD_B = 3'd3,
    RF_WAIT_B = 3'd4,
    RF_DONE   = 3'd5
} rfst_t;

rfst_t rfst;
logic [7:0] rf_idx;
logic       rom_req_r;

assign rom_req = rom_req_r;

// =============================================================================
// Main rendering FSM
// =============================================================================

typedef enum logic [3:0] {
    ST_IDLE      = 4'd0,
    ST_WAIT_CTRL = 4'd1,
    ST_READ_CTRL = 4'd2,
    ST_READ_A0   = 4'd3,
    ST_READ_A1   = 4'd4,
    ST_READ_A2   = 4'd5,
    ST_READ_A3   = 4'd6,
    ST_READ_B0   = 4'd7,
    ST_READ_B1   = 4'd8,
    ST_READ_B2   = 4'd9,
    ST_READ_B3   = 4'd10,
    ST_COMPUTE   = 4'd11,
    ST_RENDER    = 4'd12,
    ST_OUTPUT    = 4'd13
} fsm_t;

fsm_t fsm;
logic [8:0] render_x;

// =============================================================================
// Pixel computation helpers
// =============================================================================

// 2bpp lookup: High byte = bit-1, Low byte = bit-0, pixel 7 at MSB of each byte
// shift = 7 - xi_low (0..7), result selects bit from high and low bytes
function automatic logic [1:0] lookup_2bpp(
    input logic [15:0] word,
    input logic  [2:0] xi_low
);
    logic [3:0] sh;
    sh = 4'd7 - {1'b0, xi_low};
    return { word[8 + sh], word[sh] };
endfunction

// Palette index computation (12-bit result)
function automatic logic [11:0] pal_color(
    input logic [7:0] p_offs,
    input logic [5:0] cbank,
    input logic [1:0] e_offs,   // 0 or 2 from clip bit12; body: 0,2,4,6 from bits12:11
    input logic [1:0] pix,
    input logic [1:0] rtype
);
    logic [1:0]  pix_r;
    logic [7:0]  base_col;
    logic [3:0]  base_ent;
    if (rtype != 2'd0)
        pix_r = (pix - 2'd1) & 2'd3;
    else
        pix_r = pix;
    base_ent = (rtype == 2'd0) ? 4'd4 : 4'd1;
    base_col = p_offs + {2'b00, cbank} + {6'b000000, e_offs};
    return {base_col, base_ent} + {10'd0, pix_r};
endfunction

// =============================================================================
// Per-pixel section decode (combinatorial)
// =============================================================================

logic        ra_in_body, ra_in_ledge, ra_in_redge;
logic  [7:0] xi_a_body_wi, xi_a_ledge_wi, xi_a_redge_wi;   // word index into cache
logic  [2:0] xi_a_body_lo, xi_a_ledge_lo, xi_a_redge_lo;   // xi[2:0]
logic        xi_b_body_valid;   // Road B body: xi_b > 0x1ff
logic        rb_in_body, rb_in_ledge, rb_in_redge;
logic  [7:0] xi_b_body_wi, xi_b_ledge_wi, xi_b_redge_wi;
logic  [2:0] xi_b_body_lo, xi_b_ledge_lo, xi_b_redge_lo;

always_comb begin
    // All xi values: body xi is 11-bit (0..0x7ff); edge xi is 9/10-bit.
    // Body word index = (xi | 0x200) >> 3, giving cache words 0x40..0xFF.
    // Edge word index = xi >> 3, giving words 0x00..0x3F.
    logic [10:0] x11;
    logic [10:0] road_x;                // road-coordinate pixel (W-1 - render_x)
    logic [10:0] xi_a_full, xi_b_full;  // 11-bit body xi (0..0x7ff)
    /* verilator lint_off UNUSEDSIGNAL */
    logic [10:0] xi_a_body_11;          // xi_a_full | 0x200 (bits 2:0 unused)
    logic [10:0] xi_b_body_11;          // xi_b_full | 0x200 (bits 2:0 unused)
    /* verilator lint_on UNUSEDSIGNAL */
    logic  [9:0] xi_a, xi_b;            // 10-bit edge xi

    x11    = {2'b00, render_x};
    road_x = 11'(W - 1) - x11;

    // ── Road A sections ──────────────────────────────────────────────────────
    ra_in_body  = ($signed(road_x) > $signed(left_edge_a)) && (road_x < right_edge_a);
    ra_in_ledge = ($signed(road_x) <= $signed(left_edge_a));
    ra_in_redge = (road_x >= right_edge_a) && !ra_in_body;

    // Body: xi in [0..0x7ff]; body section = (xi | 0x200), word = (xi|0x200)>>3
    xi_a_full    = 11'((11'h0a7 - xoffset_a + road_x) & 11'h7ff);
    xi_a_body_11 = xi_a_full | 11'h200;
    xi_a_body_wi = xi_a_body_11[10:3];  // 8-bit word index 0x40..0xFF
    xi_a_body_lo = xi_a_full[2:0];

    // Left edge: xi = 0x1ff - (left_edge_a - road_x); xi in [0..0x1ff]; words 0x00..0x3f
    xi_a          = 10'((11'h1ff - (11'(signed'(left_edge_a)) - road_x)) & 11'h1ff);
    xi_a_ledge_wi = {1'b0, xi_a[9:3]};
    xi_a_ledge_lo = xi_a[2:0];

    // Right edge: xi in [0x200..0x3ff]; words 0x40..0x7f
    xi_a          = 10'((11'h200 + road_x - right_edge_a) & 11'h3ff);
    xi_a_redge_wi = {1'b0, xi_a[9:3]};
    xi_a_redge_lo = xi_a[2:0];

    // ── Road B sections ──────────────────────────────────────────────────────
    rb_in_body  = ($signed(road_x) > $signed(left_edge_b)) && (road_x < right_edge_b);
    rb_in_ledge = ($signed(road_x) <= $signed(left_edge_b));
    rb_in_redge = (road_x >= right_edge_b) && !rb_in_body;

    // Body: xi > 0x1ff → valid body pixel; word = (xi | 0x200) >> 3
    xi_b_full        = 11'((11'h0a7 - xoffset_b + road_x) & 11'h7ff);
    xi_b_body_valid  = (xi_b_full > 11'h1ff);   // xi > 0x1ff
    xi_b_body_11     = xi_b_full | 11'h200;
    xi_b_body_wi     = xi_b_body_11[10:3];       // 8-bit word index 0x40..0xFF
    xi_b_body_lo     = xi_b_full[2:0];

    // Left edge: xi = 0x1ff - (left_edge_b - road_x)
    xi_b          = 10'((11'h1ff - (11'(signed'(left_edge_b)) - road_x)) & 11'h1ff);
    xi_b_ledge_wi = {1'b0, xi_b[9:3]};
    xi_b_ledge_lo = xi_b[2:0];

    xi_b          = 10'((11'h200 + road_x - right_edge_b) & 11'h3ff);
    xi_b_redge_wi = {1'b0, xi_b[9:3]};
    xi_b_redge_lo = xi_b[2:0];
end

// =============================================================================
// ROM pre-fetch sub-FSM
// =============================================================================

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rfst          <= RF_IDLE;
        rf_idx        <= 8'd0;
        rom_req_r     <= 1'b0;
        rom_addr      <= 18'd0;
        cached_tile_a <= 10'h3ff;
        cached_tile_b <= 10'h3fe;
        cache_ready   <= 1'b0;
    end else begin
        case (rfst)
            RF_IDLE: ;

            RF_LOAD_A: begin
                rom_addr  <= {tile_a, rf_idx};
                rom_req_r <= ~rom_req_r;
                rfst      <= RF_WAIT_A;
            end

            RF_WAIT_A: begin
                if (rom_ack == rom_req_r) begin
                    cache_a[rf_idx] <= rom_data;
                    if (&rf_idx) begin
                        cached_tile_a <= tile_a;
                        if (tile_b == tile_a) begin
                            cached_tile_b <= tile_b;
                            rfst <= RF_DONE;
                        end else begin
                            rf_idx <= 8'd0;
                            rfst   <= RF_LOAD_B;
                        end
                    end else begin
                        rf_idx <= rf_idx + 8'd1;
                        rfst   <= RF_LOAD_A;
                    end
                end
            end

            RF_LOAD_B: begin
                rom_addr  <= {tile_b, rf_idx};
                rom_req_r <= ~rom_req_r;
                rfst      <= RF_WAIT_B;
            end

            RF_WAIT_B: begin
                if (rom_ack == rom_req_r) begin
                    cache_b[rf_idx] <= rom_data;
                    if (&rf_idx) begin
                        cached_tile_b <= tile_b;
                        rfst <= RF_DONE;
                    end else begin
                        rf_idx <= rf_idx + 8'd1;
                        rfst   <= RF_LOAD_B;
                    end
                end
            end

            RF_DONE: begin
                cache_ready <= 1'b1;
                rfst        <= RF_IDLE;
            end

            default: rfst <= RF_IDLE;
        endcase
    end
end

// =============================================================================
// Main FSM (Steps 2, 3)
// =============================================================================

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fsm               <= ST_IDLE;
        ram_rd_addr       <= 12'd0;
        road_a_base       <= 12'd0;
        road_b_base       <= 12'd0;
        priority_switch_line <= 8'd0;
        road_b_en         <= 1'b0;
        roada_clipr_bg    <= 1'b0; roada_clipr_pm <= 1'b0; roada_clipr_po <= 1'b0;
        roada_clipr_w     <= 10'd0;
        roada_clipl_bg    <= 1'b0; roada_clipl_pm <= 1'b0; roada_clipl_po <= 1'b0;
        roada_clipl_w     <= 10'd0;
        roada_body_pm     <= 1'b0; roada_body_po <= 2'd0;
        roada_xoff        <= 11'd0;
        tile_a            <= 10'd0; colbank_a <= 6'd0;
        roadb_clipr_bg    <= 1'b0; roadb_clipr_pm <= 1'b0; roadb_clipr_po <= 1'b0;
        roadb_clipr_w     <= 10'd0;
        roadb_clipl_bg    <= 1'b0; roadb_clipl_pm <= 1'b0; roadb_clipl_po <= 1'b0;
        roadb_clipl_w     <= 10'd0;
        roadb_body_pm     <= 1'b0; roadb_body_po <= 2'd0;
        roadb_xoff        <= 11'd0;
        tile_b            <= 10'd0; colbank_b <= 6'd0;
        left_edge_a       <= 11'd0; right_edge_a <= 11'd0; xoffset_a <= 11'd0;
        left_edge_b       <= 11'd0; right_edge_b <= 11'd0; xoffset_b <= 11'd0;
        for (int i = 0; i < 6; i++) priorities[i] <= 3'd0;
        scanline_priority <= 8'd0;
        render_x          <= 9'd0;
        render_done       <= 1'b0;
    end else begin
        case (fsm)
            // ── Wait for HBlank ──────────────────────────────────────────
            ST_IDLE: begin
                render_done <= 1'b0;
                if (hblank_rise && !vblank) begin
                    ram_rd_addr  <= 12'hfff;
                    fsm          <= ST_WAIT_CTRL;
                end
            end

            ST_WAIT_CTRL: fsm <= ST_READ_CTRL;

            // ── Latch control word, compute base addresses ───────────────
            ST_READ_CTRL: begin
                begin
                    logic signed [12:0] y_base_s;
                    logic [12:0]        y_base, a_off, b_off;
                    y_base_s = 13'(signed'(y_offs)) * 13'sd4;
                    y_base   = 13'(y_base_s);
                    // road_A_base = y_offs*4 + ((ctrl & 0x0300) << 2)
                    // ctrl[9:8] << 4 = 13-bit value with bits [5:4] set
                    a_off = 13'({11'b00000000000, ram_rd_data[9:8]} << 4);
                    road_a_base <= 12'((y_base + a_off) & 13'h0fff);
                    // road_B_base = y_offs*4 + ((ctrl & 0x0c00) << 0)
                    // ctrl[11:10] << 10 = 13-bit value with bits [11:10] set
                    b_off = 13'({11'b00000000000, ram_rd_data[11:10]} << 10);
                    road_b_base <= 12'((y_base + b_off) & 13'h0fff);
                    priority_switch_line <= ram_rd_data[7:0] - 8'(signed'(y_offs));
                    road_b_en <= ram_rd_data[11] | (road_type == 2'd2);
                end
                begin
                    logic [11:0] idx;
                    idx = 12'((12'(road_a_base) + {4'b0, vpos} * 12'd4) & 12'hfff);
                    ram_rd_addr <= idx;
                end
                fsm <= ST_READ_A0;
            end

            // ── Road A word 0: clipr ──────────────────────────────────────
            ST_READ_A0: begin
                roada_clipr_bg <= ram_rd_data[15];
                roada_clipr_pm <= ram_rd_data[13];
                roada_clipr_po <= ram_rd_data[12];
                roada_clipr_w  <= ram_rd_data[9:0];
                begin
                    logic [11:0] idx;
                    idx = 12'((12'(road_a_base) + {4'b0, vpos} * 12'd4 + 12'd1) & 12'hfff);
                    ram_rd_addr <= idx;
                end
                fsm <= ST_READ_A1;
            end

            // ── Road A word 1: clipl ──────────────────────────────────────
            ST_READ_A1: begin
                roada_clipl_bg <= ram_rd_data[15];
                roada_clipl_pm <= ram_rd_data[13];
                roada_clipl_po <= ram_rd_data[12];
                roada_clipl_w  <= ram_rd_data[9:0];
                begin
                    logic [11:0] idx;
                    idx = 12'((12'(road_a_base) + {4'b0, vpos} * 12'd4 + 12'd2) & 12'hfff);
                    ram_rd_addr <= idx;
                end
                fsm <= ST_READ_A2;
            end

            // ── Road A word 2: bodyctrl ───────────────────────────────────
            ST_READ_A2: begin
                roada_body_pm <= ram_rd_data[13];
                roada_body_po <= ram_rd_data[12:11];
                roada_xoff    <= ram_rd_data[10:0];
                begin
                    logic [11:0] idx;
                    idx = 12'((12'(road_a_base) + {4'b0, vpos} * 12'd4 + 12'd3) & 12'hfff);
                    ram_rd_addr <= idx;
                end
                fsm <= ST_READ_A3;
            end

            // ── Road A word 3: gfx ────────────────────────────────────────
            ST_READ_A3: begin
                tile_a    <= ram_rd_data[9:0];
                colbank_a <= {ram_rd_data[15:12], 2'b00};
                begin
                    logic [11:0] idx;
                    idx = 12'((12'(road_b_base) + {4'b0, vpos} * 12'd4) & 12'hfff);
                    ram_rd_addr <= idx;
                end
                fsm <= ST_READ_B0;
            end

            // ── Road B words 0..3 ─────────────────────────────────────────
            ST_READ_B0: begin
                roadb_clipr_bg <= ram_rd_data[15];
                roadb_clipr_pm <= ram_rd_data[13];
                roadb_clipr_po <= ram_rd_data[12];
                roadb_clipr_w  <= ram_rd_data[9:0];
                begin
                    logic [11:0] idx;
                    idx = 12'((12'(road_b_base) + {4'b0, vpos} * 12'd4 + 12'd1) & 12'hfff);
                    ram_rd_addr <= idx;
                end
                fsm <= ST_READ_B1;
            end

            ST_READ_B1: begin
                roadb_clipl_bg <= ram_rd_data[15];
                roadb_clipl_pm <= ram_rd_data[13];
                roadb_clipl_po <= ram_rd_data[12];
                roadb_clipl_w  <= ram_rd_data[9:0];
                begin
                    logic [11:0] idx;
                    idx = 12'((12'(road_b_base) + {4'b0, vpos} * 12'd4 + 12'd2) & 12'hfff);
                    ram_rd_addr <= idx;
                end
                fsm <= ST_READ_B2;
            end

            ST_READ_B2: begin
                roadb_body_pm <= ram_rd_data[13];
                roadb_body_po <= ram_rd_data[12:11];
                roadb_xoff    <= ram_rd_data[10:0];
                begin
                    logic [11:0] idx;
                    idx = 12'((12'(road_b_base) + {4'b0, vpos} * 12'd4 + 12'd3) & 12'hfff);
                    ram_rd_addr <= idx;
                end
                fsm <= ST_READ_B3;
            end

            ST_READ_B3: begin
                tile_b    <= ram_rd_data[9:0];
                colbank_b <= {ram_rd_data[15:12], 2'b00};
                fsm       <= ST_COMPUTE;
            end

            // ── Compute geometry and kick ROM fetch ───────────────────────
            ST_COMPUTE: begin
                // Road A geometry
                begin
                    logic [10:0] rc;
                    rc = 11'h5ff - ((11'h0a7 - roada_xoff) & 11'h7ff);
                    xoffset_a   <= roada_xoff;
                    left_edge_a <= rc - {1'b0, roada_clipl_w};
                    right_edge_a <= rc + 11'd1 + {1'b0, roada_clipr_w};
                end
                // Road B geometry
                begin
                    logic [10:0] rc;
                    rc = 11'h5ff - ((11'h0a7 - roadb_xoff) & 11'h7ff);
                    xoffset_b   <= roadb_xoff;
                    left_edge_b <= rc - {1'b0, roadb_clipl_w};
                    right_edge_b <= rc + 11'd1 + {1'b0, roadb_clipr_w};
                end

                // Priority table defaults {1,1,2,3,3,4} + modifiers
                begin
                    logic [2:0] p0,p1,p2,p3,p4,p5;
                    p0=3'd1; p1=3'd1; p2=3'd2; p3=3'd3; p4=3'd3; p5=3'd4;
                    if (roada_body_pm) p2 = p2 + 3'd2;
                    if (roadb_body_pm) p2 = p2 + 3'd1;
                    if (roada_clipl_pm) p3 = p3 - 3'd1;
                    if (roadb_clipl_pm) p3 = p3 - 3'd2;
                    if (roada_clipr_pm) p4 = p4 - 3'd1;
                    if (roadb_clipr_pm) p4 = p4 - 3'd2;
                    if (p4 == 3'd0)     p4 = 3'd1;
                    priorities[0] <= p0; priorities[1] <= p1; priorities[2] <= p2;
                    priorities[3] <= p3; priorities[4] <= p4; priorities[5] <= p5;
                end

                scanline_priority <= (vpos > priority_switch_line) ? high_priority : low_priority;

                // Kick ROM pre-fetch (Step 4)
                cache_ready <= 1'b0;
                if (cached_tile_a == tile_a && cached_tile_b == tile_b) begin
                    cache_ready <= 1'b1;
                end else if (cached_tile_a == tile_a) begin
                    rf_idx <= 8'd0;
                    rfst   <= RF_LOAD_B;
                end else begin
                    rf_idx <= 8'd0;
                    rfst   <= RF_LOAD_A;
                end

                render_x <= 9'd0;
                fsm      <= ST_RENDER;
            end

            // ── Line renderer (Step 3) ────────────────────────────────────
            ST_RENDER: begin
                if (!cache_ready) begin
                    // Spin waiting for ROM fetch
                end else begin
                    begin
                        logic [15:0] pa, pb, merged;
                        logic [1:0]  pix_a, pix_b;
                        logic [15:0] wrd;
                        logic [11:0] col;

                        // ── Road A ──────────────────────────────────
                        pa = 16'h8000;
                        if (tile_a != 10'd0) begin
                            if (ra_in_body) begin
                                wrd   = cache_a[xi_a_body_wi];
                                pix_a = lookup_2bpp(wrd, xi_a_body_lo);
                                if (pix_a != 2'd0 || !road_trans) begin
                                    col = pal_color(palette_offs, colbank_a,
                                                    roada_body_po,
                                                    pix_a, road_type);
                                    pa = {1'b0, priorities[2], col};
                                end else
                                    pa = 16'hf000;
                            end else if (ra_in_ledge) begin
                                wrd   = cache_a[xi_a_ledge_wi];
                                pix_a = lookup_2bpp(wrd, xi_a_ledge_lo);
                                if (pix_a != 2'd0 || roada_clipl_bg) begin
                                    col = pal_color(palette_offs, colbank_a,
                                                    {1'b0, roada_clipl_po},
                                                    pix_a, road_type);
                                    pa = {1'b0, priorities[0], col};
                                end
                            end else if (ra_in_redge) begin
                                wrd   = cache_a[xi_a_redge_wi];
                                pix_a = lookup_2bpp(wrd, xi_a_redge_lo);
                                if (pix_a != 2'd0 || roada_clipr_bg) begin
                                    col = pal_color(palette_offs, colbank_a,
                                                    {1'b0, roada_clipr_po},
                                                    pix_a, road_type);
                                    pa = {1'b0, priorities[1], col};
                                end
                            end
                        end

                        // ── Road B ──────────────────────────────────
                        pb = 16'h8000;
                        if (road_b_en && tile_b != 10'd0) begin
                            if (rb_in_body) begin
                                if (xi_b_body_valid) begin
                                    wrd   = (tile_a == tile_b) ? cache_a[xi_b_body_wi]
                                                               : cache_b[xi_b_body_wi];
                                    pix_b = lookup_2bpp(wrd, xi_b_body_lo);
                                    if (pix_b != 2'd0 || !road_trans) begin
                                        col = pal_color(palette_offs, colbank_b,
                                                        roadb_body_po,
                                                        pix_b, road_type);
                                        pb = {1'b0, priorities[5], col};
                                    end else
                                        pb = 16'hf000;
                                end
                            end else if (rb_in_ledge) begin
                                wrd   = (tile_a == tile_b) ? cache_a[xi_b_ledge_wi]
                                                           : cache_b[xi_b_ledge_wi];
                                pix_b = lookup_2bpp(wrd, xi_b_ledge_lo);
                                if (pix_b != 2'd0 || roadb_clipl_bg) begin
                                    col = pal_color(palette_offs, colbank_b,
                                                    {1'b0, roadb_clipl_po},
                                                    pix_b, road_type);
                                    pb = {1'b0, priorities[3], col};
                                end
                            end else if (rb_in_redge) begin
                                wrd   = (tile_a == tile_b) ? cache_a[xi_b_redge_wi]
                                                           : cache_b[xi_b_redge_wi];
                                pix_b = lookup_2bpp(wrd, xi_b_redge_lo);
                                if (pix_b != 2'd0 || roadb_clipr_bg) begin
                                    col = pal_color(palette_offs, colbank_b,
                                                    {1'b0, roadb_clipr_po},
                                                    pix_b, road_type);
                                    pb = {1'b0, priorities[4], col};
                                end
                            end
                        end

                        // ── Arbitrate A vs B ─────────────────────────
                        if (pa == 16'h8000)
                            merged = pb & 16'h8fff;
                        else if (pb == 16'h8000)
                            merged = pa & 16'h8fff;
                        else if ((pb & 16'h7000) > (pa & 16'h7000))
                            merged = pb & 16'h8fff;
                        else
                            merged = pa & 16'h8fff;

                        // road_x = W-1 - render_x already handles axis inversion;
                        // write at render_x directly.
                        scanline[render_x] <= merged;
                    end

                    if (render_x == 9'(W - 1))
                        fsm <= ST_OUTPUT;
                    else
                        render_x <= render_x + 9'd1;
                end
            end

            ST_OUTPUT: begin
                render_done <= 1'b1;
                fsm         <= ST_IDLE;
            end

            default: fsm <= ST_IDLE;
        endcase
    end
end

// =============================================================================
// Step 5 — Scanline output during active display
// =============================================================================

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pix_out       <= 15'd0;
        pix_valid     <= 1'b0;
        pix_transp    <= 1'b0;
        line_priority <= 8'd0;
    end else begin
        if (!hblank && !vblank
                    && vpos >= 8'(V_START)
                    && hpos[8:0] < 9'(H_END)) begin
            logic [15:0] pw;
            pw            = scanline[hpos[8:0]];
            pix_transp    <= pw[15] | (pw[14:0] == 15'h7000);
            pix_out       <= pw[14:0];
            pix_valid     <= 1'b1;
            line_priority <= scanline_priority;
        end else begin
            pix_valid <= 1'b0;
        end
    end
end

endmodule
