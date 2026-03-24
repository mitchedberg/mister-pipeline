`default_nettype none
// =============================================================================
// TC0630FDP — Sprite Renderer  (Step 15: +mosaic X-snap at read time)
// =============================================================================
// Ping-pong line buffer renderer: during HBLANK for scanline N, renders the
// sprite list for scanline N+1 into the back buffer; during active scan N+1,
// pixel output comes from the front buffer.
//
// 72-bit sprite list descriptor:
//   [71:55] tile_code[16:0]
//   [54:43] sx[11:0]   (signed; screen X of tile left edge)
//   [42:31] sy[11:0]   (signed; screen Y of tile top edge)
//   [30:25] palette[5:0]
//   [24:23] priority[1:0]
//   [22]    flipY
//   [21]    flipX
//   [20:13] y_zoom[7:0]  (0x00=full size, 0x80=half, 0xFF=invisible)
//   [12:5]  x_zoom[7:0]  (0x00=full size, 0x80=half, 0xFF=invisible)
//   [4:0]   (unused, zero)
//
// Line buffer entry: 12-bit {priority[1:0], palette[5:0], pen[3:0]}
//   pen==0 → transparent (do not overwrite)
//
// GFX ROM (32-bit, nibble-packed 4bpp, §11.3):
//   word addr = tile_code*32 + row*2       (left 8 pixels)
//             = tile_code*32 + row*2 + 1   (right 8 pixels)
//   bits[31:28]=px0, ..., bits[3:0]=px7
//   flipX: reverse nibble order within 8px half
//   flipY: row = 15 - row
//
// Zoom (Step 9, §8.1 + section2_behavior §3.3):
//   scale_x = 0x100 - x_zoom   (0x100 = 1:1, 0x80 = half, 0x00 → full scale)
//   scale_y = 0x100 - y_zoom
//   Rendered width  = (16 * scale_x) >> 8  (max 16, min 0)
//   Rendered height = (16 * scale_y) >> 8
//   Source pixel mapping (fixed-point accumulator):
//     For output column dst_x (0..rendered_width-1):
//       src_x = (dst_x * (0x100 - x_zoom)) >> 8   (integer part = source pixel 0..15)
//     For output row dst_row (0..rendered_height-1):
//       src_row = (dst_row * (0x100 - y_zoom)) >> 8 (integer, then apply flipY)
//
// BRAM latency: synchronous (addr on cycle N → data on cycle N+1).
//
// Render FSM per sprite:
//   S_IDLE  : idle
//   S_CNT   : wait for scount BRAM (1 cycle)
//   S_ADDR  : drive slist addr, wait 1 cycle
//   S_LATCH : latch entry; compute src_row; issue gfx_left addr
//   S_GFX_L : gfx left data arrives; latch it; issue gfx_right addr
//   S_GFX_R : gfx right data arrives; write zoomed pixels; advance
// =============================================================================

module tc0630fdp_sprite_render (
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        clk,      // pixel clock (unused in this module; kept for port compatibility)
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        clk_4x,   // 4× pixel clock for serialized pixel writes
    input  logic        rst_n,

    input  logic        hblank,
    input  logic        hblank_fall,   // hblank rising edge: start rendering
    input  logic [ 8:0] vpos,
    input  logic [ 9:0] hpos,

    // ── Step 15: Mosaic ───────────────────────────────────────────────────
    // ls_spr_mosaic_en: when 1, apply X-snap to sprite line buffer read.
    // ls_mosaic_rate: 4-bit rate; sample_rate = rate + 1.
    input  logic        ls_spr_mosaic_en,
    input  logic [ 3:0] ls_mosaic_rate,

    output logic [ 7:0] scount_rd_addr,
    input  logic [ 6:0] scount_rd_data,

    output logic [13:0] slist_rd_addr,
    input  logic [71:0] slist_rd_data,

    output logic [21:0] gfx_addr,
    input  logic [31:0] gfx_data,

    output logic [11:0] spr_pixel
);

// ---------------------------------------------------------------------------
localparam int V_START = 24;
localparam int H_START = 46;
localparam int H_END   = 366;

// ---------------------------------------------------------------------------
// Dual ping-pong line buffers
// ---------------------------------------------------------------------------
// Declared as two separate 2D arrays instead of one 3D array.
// Quartus 17 OOM-crashes (quartus_map) when a 3D array's first dimension
// is selected by a variable at runtime (e.g. lbuf[front_buf][col]).
// Two independent 2D arrays avoid that elaboration explosion.
// FPGAs power up BRAM contents to 0, so no reset initialisation loop is needed.
//
// Phase 4 (explicit): Sprite line buffers → altsyncram (MLAB) megafunction.
// Quartus 17.0 Lite ignores (* ramstyle = "MLAB" *) attributes; explicit
// altsyncram instantiation is required to force MLAB block type.
//   Dual-port: port A = sync write (clk_4x), port B = async read (UNREGISTERED).
//   Read and write addresses differ each cycle → dual-port required.
// MLAB: 2×320×12=7680 bits ≈ 12 MLABs vs 7680 FFs. Saves ~380 ALMs.
// (True M10K conversion requires Phase 0+2 serialization at 96MHz — serial write only.)

// Write-side signals (one set per buffer)
logic [11:0] lbuf0_wdata, lbuf1_wdata;
logic  [8:0] lbuf0_waddr, lbuf1_waddr;
logic        lbuf0_wen,   lbuf1_wen;
// Read-side signals (one set per buffer)
logic [11:0] lbuf0_rdata, lbuf1_rdata;

`ifdef QUARTUS
// ── lbuf0 — explicit altsyncram dual-port MLAB ───────────────────────────
altsyncram #(
    .width_a            (12),
    .widthad_a          (9),
    .numwords_a         (512),
    .width_b            (12),
    .widthad_b          (9),
    .numwords_b         (512),
    .operation_mode     ("DUAL_PORT"),
    .ram_block_type     ("MLAB"),
    .outdata_reg_a      ("UNREGISTERED"),
    .outdata_reg_b      ("UNREGISTERED"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .intended_device_family ("Cyclone V")
) u_lbuf0 (
    .clock0  (clk_4x),
    .address_a (lbuf0_waddr),
    .data_a    (lbuf0_wdata),
    .wren_a    (lbuf0_wen),
    .address_b (spr_scol_snap),
    .q_b       (lbuf0_rdata),
    // unused ports
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({12{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
    .wren_b(1'b0)
);
// ── lbuf1 — explicit altsyncram dual-port MLAB ───────────────────────────
altsyncram #(
    .width_a            (12),
    .widthad_a          (9),
    .numwords_a         (512),
    .width_b            (12),
    .widthad_b          (9),
    .numwords_b         (512),
    .operation_mode     ("DUAL_PORT"),
    .ram_block_type     ("MLAB"),
    .outdata_reg_a      ("UNREGISTERED"),
    .outdata_reg_b      ("UNREGISTERED"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .intended_device_family ("Cyclone V")
) u_lbuf1 (
    .clock0  (clk_4x),
    .address_a (lbuf1_waddr),
    .data_a    (lbuf1_wdata),
    .wren_a    (lbuf1_wen),
    .address_b (spr_scol_snap),
    .q_b       (lbuf1_rdata),
    // unused ports
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_a(1'b1), .byteena_b(1'b1), .clock1(1'b0), .clocken0(1'b1),
    .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({12{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1),
    .wren_b(1'b0)
);
`else
// Simulation: plain register arrays (async read via always_comb access)
logic [11:0] lbuf0 [0:511];
logic [11:0] lbuf1 [0:511];
always_ff @(posedge clk_4x) begin
    if (lbuf0_wen) lbuf0[lbuf0_waddr] <= lbuf0_wdata;
    if (lbuf1_wen) lbuf1[lbuf1_waddr] <= lbuf1_wdata;
end
assign lbuf0_rdata = lbuf0[spr_scol_snap];
assign lbuf1_rdata = lbuf1[spr_scol_snap];
`endif
logic back_buf;
logic front_buf;

// Counter used to sequentially clear the new back buffer after ping-pong swap.
// Runs 0→319 over 320 cycles starting at the hblank_end event.
logic        lbuf_clr_active;
logic [8:0]  lbuf_clr_idx;

// Pre-active edge: fires one cycle before H_START (hpos == H_START-1 = 45).
logic hblank_end;
assign hblank_end = (hpos == 10'(H_START - 1));

// =============================================================================
// Cross-domain synchronizers: clk → clk_4x
// hblank_fall and hblank_end are single-cycle pulses in clk domain.
// Synchronize via 2-FF synchronizer into clk_4x domain.
// =============================================================================
logic [1:0] hfall_sync_4x;
logic [1:0] hend_sync_4x;

always_ff @(posedge clk_4x) begin
    if (!rst_n) begin
        hfall_sync_4x <= 2'b00;
        hend_sync_4x  <= 2'b00;
    end else begin
        hfall_sync_4x <= {hfall_sync_4x[0], hblank_fall};
        hend_sync_4x  <= {hend_sync_4x[0],  hblank_end};
    end
end

logic hblank_fall_4x;
logic hblank_end_4x;
assign hblank_fall_4x = hfall_sync_4x[1];
assign hblank_end_4x  = hend_sync_4x[1];

// Capture vpos into clk_4x domain (stable during HBLANK)
logic [8:0] vpos_4x;
always_ff @(posedge clk_4x) begin
    if (!rst_n) vpos_4x <= 9'b0;
    else        vpos_4x <= vpos;
end

// Step 15: Mosaic snap for sprite line buffer read
// Same formula as BG: snapped_col = col - ((col + 114) % 432 % sample_rate)
logic [8:0] spr_scol_raw;
logic [8:0] spr_scol_snap;

always_comb begin
    automatic logic [9:0] gx_wide;
    automatic logic [8:0] grid_sum;
    automatic logic [8:0] sr;
    automatic logic [4:0] off;

    // Raw column from hpos
    if (hpos >= 10'(H_START) && hpos < 10'(H_END))
        spr_scol_raw = hpos[8:0] - 9'(H_START);
    else
        spr_scol_raw = 9'd0;

    gx_wide  = {1'b0, spr_scol_raw} + 10'd114;
    grid_sum = (gx_wide >= 10'd432) ? gx_wide[8:0] - 9'd432 : gx_wide[8:0];
    sr       = 9'd1 + {5'b0, ls_mosaic_rate};
    // Modulo via subtraction chain (avoids combinational divider)
    // sr ranges 1..16; grid_sum max 431. sr*16 max = 256; all fit in 9 bits.
    begin
        automatic logic [8:0] sr16, sr8, sr4, sr2, rem;
        sr16 = sr << 4;
        sr8  = sr << 3;
        sr4  = sr << 2;
        sr2  = sr << 1;
        rem = grid_sum;
        if (rem >= sr16) rem = rem - sr16;  // sr*16
        if (rem >= sr8)  rem = rem - sr8;   // sr*8
        if (rem >= sr4)  rem = rem - sr4;   // sr*4
        if (rem >= sr2)  rem = rem - sr2;   // sr*2
        if (rem >= sr)   rem = rem - sr;    // sr*1
        off = 5'(rem);
    end

    if (ls_spr_mosaic_en && ls_mosaic_rate != 4'd0)
        spr_scol_snap = 9'(spr_scol_raw - {5'b0, off});
    else
        spr_scol_snap = spr_scol_raw;
end

always_comb begin
    if (hpos >= 10'(H_START) && hpos < 10'(H_END))
        spr_pixel = front_buf ? lbuf1_rdata : lbuf0_rdata;
    else
        spr_pixel = 12'd0;
end

// ---------------------------------------------------------------------------
// FSM
// ---------------------------------------------------------------------------
// S_NEXT replaced by S_PIXEL: serializes 16-pixel writes at clk_4x rate.
// At 4×pixel clock (96 MHz), 16 pixels take 16 clk_4x cycles = 4 pixel clocks.
// Per-sprite budget at clk_4x: S_CNT(1)+S_ADDR(1)+S_LATCH(1)+S_GFX_L(1)+
//   S_GFX_R(1)+S_PIXEL(up to 16) = up to 21 clk_4x cycles.
// HBLANK budget: 448 clk_4x cycles → 448/21 = 21 sprites max.  Sufficient.
typedef enum logic [2:0] {
    S_IDLE   = 3'd0,
    S_CNT    = 3'd1,
    S_ADDR   = 3'd2,
    S_LATCH  = 3'd3,
    S_GFX_L  = 3'd4,
    S_GFX_R  = 3'd5,
    S_PIXEL  = 3'd6   // serialized pixel write (replaces S_NEXT)
} state_t;

state_t state;

// ---------------------------------------------------------------------------
logic [ 7:0] render_scan;
logic [ 6:0] spr_count;
logic [ 5:0] spr_slot;

logic [16:0] r_tile;
logic [11:0] r_sx;
logic [11:0] r_sy;
logic [ 5:0] r_palette;
logic [ 1:0] r_prio;
logic        r_flipy, r_flipx;
logic [ 7:0] r_x_zoom;   // Step 9: x_zoom byte
logic [ 7:0] r_y_zoom;   // Step 9: y_zoom byte
logic [ 4:0] r_dst_row;  // Step 9: registered dst_row for this sprite/scanline
logic [31:0] gfx_left_r;

// Registered slist address (scan + slot portions stored separately)
logic [ 7:0] addr_scan;
logic [ 5:0] addr_slot;
assign slist_rd_addr = {addr_scan, addr_slot};

// ---------------------------------------------------------------------------
// Zoom: rendered dimensions and source row computation
//
// Step 9 zoom formula (section2 §3.3):
//   scale_x = 0x100 - x_zoom  (8-bit; 0x100 → handled as 9-bit)
//   rendered_width  = (16 * scale_x) >> 8 = 16 - (16 * x_zoom) >> 8
//   scale_y = 0x100 - y_zoom
//   rendered_height = (16 * scale_y) >> 8
//
// Source row selection:
//   dst_row = render_scan - abs_sy (0..rendered_height-1)
//   src_row = (dst_row * scale_y) >> 8  (integer tile row 0..15)
//   with flipY: src_row = 15 - src_row
//
// Source column selection (per-pixel):
//   src_x = (dst_x * scale_x) >> 8  (integer pixel 0..15)
// ---------------------------------------------------------------------------

// Compute scale values (9-bit to handle 0x100 case for no-zoom)
logic [8:0] scale_x;   // 0x100 - x_zoom  (0x100 = full, 0x80 = half, 0x00 → 0 pixels)
logic [8:0] scale_y;
assign scale_x = 9'h100 - {1'b0, r_x_zoom};
assign scale_y = 9'h100 - {1'b0, r_y_zoom};

// Rendered width = (16 * scale_x) >> 8 = scale_x >> 4 (5-bit max 16)
logic [4:0] render_w;
assign render_w = scale_x[8:4];  // bits [8:4] = (scale_x * 16) >> 8

// Rendered height = scale_y >> 4 (5-bit max 16)
logic [4:0] render_h;
assign render_h = scale_y[8:4];

// ---------------------------------------------------------------------------
// Source row: dst_row_val = (render_scan + V_START) - abs(sy)
// abs_sy = sign-extended sy (12→13 bit)
// dst_row = (abs_scan - r_sy) masked to rendered_height range
// src_row = (dst_row * scale_y) >> 8
// ---------------------------------------------------------------------------
// abs_scan = render_scan + V_START (9-bit)
logic [8:0] abs_scan;
assign abs_scan = {1'b0, render_scan} + 9'(V_START);

// dst_row = abs_scan - sy (integer part; valid sprites have sy in screen range so
// abs_scan[7:0] - r_sy[7:0] gives a result in 0..15, never wrapping for valid entries)
logic [7:0] dst_row_full;
assign dst_row_full = abs_scan[7:0] - r_sy[7:0];

// src_row = (dst_row * scale_y) >> 8 : dst_row is 4-bit (0..15), scale_y 9-bit.
// Product is 13-bit max (15*256=3840).  Explicit lpm_mult (combinational, pipeline=0)
// forces DSP block use in Quartus 17.0 Lite (multstyle attribute is ignored).
logic [4:0] src_row_zoom;
`ifdef QUARTUS
logic [12:0] src_row_zoom_prod;
lpm_mult #(
    .lpm_widtha         (4),
    .lpm_widthb         (9),
    .lpm_widthp         (13),
    .lpm_representation ("UNSIGNED"),
    .lpm_pipeline       (0)
) u_src_row_mult (
    .dataa  (dst_row_full[3:0]),
    .datab  (scale_y[8:0]),
    .result (src_row_zoom_prod),
    .clock  (1'b0),
    .clken  (1'b0),
    .aclr   (1'b0),
    .sum    ({13{1'b0}})
);
assign src_row_zoom = 5'(src_row_zoom_prod >> 8);
`else
assign src_row_zoom = 5'((13'(dst_row_full[3:0]) * 13'(scale_y)) >> 8);
`endif

// fetch_row with flipY
logic [3:0] fetch_row;
assign fetch_row = r_flipy ? (4'd15 - src_row_zoom[3:0]) : src_row_zoom[3:0];

// GFX addresses
logic [21:0] gfx_left_addr;
logic [21:0] gfx_right_addr;
assign gfx_left_addr  = 22'(22'(r_tile) * 22'd32 + {18'd0, fetch_row, 1'b0});
assign gfx_right_addr = gfx_left_addr + 22'd1;

// ---------------------------------------------------------------------------
// Pixel decode function
// ---------------------------------------------------------------------------
function automatic logic [3:0] decode_pen(
    input logic [31:0] word,
    input logic [2:0]  px_idx,
    input logic        flip
);
    logic [2:0] ni;
    logic [4:0] sh;
    ni = flip ? (3'd7 - px_idx) : px_idx;
    sh = 5'd28 - {ni, 2'b00};
    decode_pen = 4'((word >> sh) & 32'hF);
endfunction

// ---------------------------------------------------------------------------
// Serialized pixel write: single px_idx counter iterates 0..render_w-1 in
// S_PIXEL state (one pixel per clk_4x cycle).  Eliminates the 16-wide
// combinational src_x_of/pen_of/scol_of arrays and their associated mux trees
// (saves ~15,000–20,000 ALMs).
// ---------------------------------------------------------------------------

// Current pixel index in S_PIXEL state (0..15)
logic [3:0] px_idx;

// Per-pixel combinational decode (single instance, not 16×)
logic [3:0]          px_src_x;
logic [3:0]          px_pen;
logic signed [12:0]  px_scol;

always_comb begin
    px_src_x = 4'((13'(px_idx) * 13'(scale_x)) >> 8);
    px_scol  = $signed({{1{r_sx[11]}}, r_sx}) + 13'(px_idx);
    if (px_src_x < 4'd8)
        px_pen = decode_pen(gfx_left_r, px_src_x[2:0], r_flipx);
    else
        px_pen = decode_pen(gfx_data,   px_src_x[2:0], r_flipx);
end

// ---------------------------------------------------------------------------
// Combinational write-port drivers for lbuf altsyncram instances.
// Priority: clear takes precedence over pixel write (they never overlap in
// practice — clear runs after HBLANK swap, pixel write runs during HBLANK).
// altsyncram captures waddr/wdata/wen on the rising edge of clock0 (clk_4x).
// ---------------------------------------------------------------------------
logic        px_write_valid;
assign px_write_valid = (state == S_PIXEL) &&
                        (r_dst_row < render_h) &&
                        (5'(px_idx) < render_w) &&
                        (px_scol >= 13'sd0) &&
                        (px_scol <  13'sd320) &&
                        (px_pen  != 4'd0);

// lbuf0 write port
always_comb begin
    lbuf0_wen   = 1'b0;
    lbuf0_waddr = 9'd0;
    lbuf0_wdata = 12'd0;
    if (lbuf_clr_active && !back_buf) begin
        lbuf0_wen   = 1'b1;
        lbuf0_waddr = lbuf_clr_idx;
        lbuf0_wdata = 12'd0;
    end else if (px_write_valid && !back_buf) begin
        lbuf0_wen   = 1'b1;
        lbuf0_waddr = px_scol[8:0];
        lbuf0_wdata = {r_prio, r_palette, px_pen};
    end
end

// lbuf1 write port
always_comb begin
    lbuf1_wen   = 1'b0;
    lbuf1_waddr = 9'd0;
    lbuf1_wdata = 12'd0;
    if (lbuf_clr_active && back_buf) begin
        lbuf1_wen   = 1'b1;
        lbuf1_waddr = lbuf_clr_idx;
        lbuf1_wdata = 12'd0;
    end else if (px_write_valid && back_buf) begin
        lbuf1_wen   = 1'b1;
        lbuf1_waddr = px_scol[8:0];
        lbuf1_wdata = {r_prio, r_palette, px_pen};
    end
end

// ---------------------------------------------------------------------------
// FSM + ping-pong clear in a single always_ff block.
// ---------------------------------------------------------------------------
// The line buffer clear uses a sequential counter (lbuf_clr_active / lbuf_clr_idx)
// rather than a 320-iteration for-loop.  A for-loop inside always_ff creates
// 320 enable muxes and explodes Quartus 17 elaboration memory (OOM crash).
// The counter-based approach synthesises to a simple increment chain.
// ---------------------------------------------------------------------------
// FSM runs at clk_4x: serialized pixel writes, 1 pixel per clk_4x cycle.
// hblank_fall_4x / hblank_end_4x are the synchronized versions of the clk
// domain pulses.  All BRAM reads (scount, slist, gfx) have 1-cycle latency
// and are also driven by clk_4x — the BRAMs must accept either clk or clk_4x
// as read clock (they are registered in the clk domain in tc0630fdp.sv but
// the address is updated at clk_4x rate; this is safe because all BRAM reads
// complete within the clk_4x period and the data is stable at the next edge).
always_ff @(posedge clk_4x) begin
    if (!rst_n) begin
        state           <= S_IDLE;
        back_buf        <= 1'b0;
        front_buf       <= 1'b1;
        render_scan     <= 8'd0;
        spr_count       <= 7'd0;
        spr_slot        <= 6'd0;
        scount_rd_addr  <= 8'd0;
        addr_scan       <= 8'd0;
        addr_slot       <= 6'd0;
        gfx_addr        <= 22'd0;
        r_tile          <= 17'd0;
        r_sx            <= 12'd0;
        r_sy            <= 12'd0;
        r_palette       <= 6'd0;
        r_prio          <= 2'd0;
        r_flipy         <= 1'b0;
        r_flipx         <= 1'b0;
        r_x_zoom        <= 8'd0;
        r_y_zoom        <= 8'd0;
        r_dst_row       <= 5'd0;
        gfx_left_r      <= 32'd0;
        px_idx          <= 4'd0;
        // lbuf0/lbuf1 BRAM powers up to 0 — no reset loop needed.
        lbuf_clr_active <= 1'b0;
        lbuf_clr_idx    <= 9'd0;
    end else begin
        // ── Sequential back-buffer clear (runs after each ping-pong swap) ─
        if (lbuf_clr_active) begin
            // Write enables driven combinationally below (lbuf0_wen/lbuf1_wen).
            if (lbuf_clr_idx == 9'd319)
                lbuf_clr_active <= 1'b0;
            else
                lbuf_clr_idx <= lbuf_clr_idx + 9'd1;
        end

        if (hblank_end_4x) begin
        // End of HBLANK: swap front/back so the just-rendered back becomes
        // the new front, visible during the upcoming active display.
        front_buf       <= back_buf;
        back_buf        <= front_buf;
        // Kick off sequential clear of the new back (old front) buffer.
        lbuf_clr_active <= 1'b1;
        lbuf_clr_idx    <= 9'd0;
    end else if (hblank_fall_4x) begin
        // Start of HBLANK: begin rendering sprite list for (vpos_4x+1).
        render_scan    <= vpos_4x[7:0] - 8'(V_START) + 8'd1;
        scount_rd_addr <= vpos_4x[7:0] - 8'(V_START) + 8'd1;
        state          <= S_CNT;
    end else begin
        case (state)

            S_IDLE: begin end

            // 1-cycle wait for scount BRAM
            S_CNT: begin
                spr_count  <= scount_rd_data;
                spr_slot   <= 6'd0;
                if (scount_rd_data == 7'd0) begin
                    state <= S_IDLE;
                end else begin
                    addr_scan <= render_scan;
                    addr_slot <= 6'd0;
                    state     <= S_ADDR;
                end
            end

            // 1-cycle wait for slist BRAM
            S_ADDR: begin
                state <= S_LATCH;
            end

            // Latch slist entry fields (72-bit descriptor)
            S_LATCH: begin
                r_tile    <= slist_rd_data[71:55];
                r_sx      <= slist_rd_data[54:43];
                r_sy      <= slist_rd_data[42:31];
                r_palette <= slist_rd_data[30:25];
                r_prio    <= slist_rd_data[24:23];
                r_flipy   <= slist_rd_data[22];
                r_flipx   <= slist_rd_data[21];
                r_y_zoom  <= slist_rd_data[20:13];   // Step 9
                r_x_zoom  <= slist_rd_data[12:5];    // Step 9
                state     <= S_GFX_L;
            end

            // Issue GFX left read (r_tile, r_sy, zoom regs now stable)
            // Also register dst_row and render_h for this sprite/scanline.
            S_GFX_L: begin
                gfx_addr    <= gfx_left_addr;
                r_dst_row   <= {1'b0, dst_row_full[3:0]};
                state       <= S_GFX_R;
            end

            // Latch left data, issue right; initialize px_idx for S_PIXEL
            S_GFX_R: begin
                gfx_left_r <= gfx_data;
                gfx_addr   <= gfx_right_addr;
                px_idx     <= 4'd0;
                state      <= S_PIXEL;
            end

            // Serialized pixel write: one pixel per clk_4x cycle.
            // Replaces the 16-wide for-loop in S_NEXT.
            // Saves ~15,000 ALMs (16× write mux elimination + 16× multiply removal).
            S_PIXEL: begin
                // Guard: only write pixels when scanline falls within rendered height.
                // Write enables and data driven combinationally below (lbuf0_wen/lbuf1_wen).
                // No NBA here — altsyncram captures waddr/wdata/wen on the clock edge.

                // Advance pixel or move to next sprite
                if (px_idx == 4'd15 || 5'(px_idx) + 5'd1 >= render_w) begin
                    // Done with this sprite
                    if (7'(spr_slot) + 7'd1 >= spr_count) begin
                        state <= S_IDLE;
                    end else begin
                        spr_slot  <= spr_slot + 6'd1;
                        addr_slot <= spr_slot + 6'd1;
                        state     <= S_ADDR;
                    end
                end else begin
                    px_idx <= px_idx + 4'd1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end  // else (not hblank_end_4x, not hblank_fall_4x)
    end  // else begin (!rst_n)
end  // always_ff @(posedge clk_4x)

/* verilator lint_off UNUSED */
/* verilator lint_off UNUSEDSIGNAL */
logic _unused;
assign _unused = ^{hblank,
                   vpos[8],
                   vpos_4x[8],
                   slist_rd_data[4:0],
                   dst_row_full[7:4],
                   r_sy[11:8],
                   src_row_zoom[4],
                   abs_scan[8],
                   hfall_sync_4x[0],
                   hend_sync_4x[0]};
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSED */

endmodule
