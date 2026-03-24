`default_nettype none
// =============================================================================
// TC0630FDP — Layer Compositor / Color Mixer (Step 16: +Pivot Layer)
// =============================================================================
// Implements a 6-layer priority mux with per-layer clip plane evaluation and
// alpha blending (Normal Mode A and Reverse Mode B).
//
// Priority rules:
//   1. Text layer wins over everything if pen != 0 (always opaque).
//   2. Among PF and sprite layers, higher numeric priority wins (strictly >).
//   3. Equal-priority tie: sprite wins over PF (>=).
//   4. Transparent pixels (pen == 0) are skipped.
//   5. If all layers are transparent, output pen=0 (background).
//
// Clip plane evaluation (Step 12): per-layer clip windows evaluated per pixel.
//   Text layer has no clip planes.
//
// Alpha blend (Steps 13+14):
//   Blend mode per layer from §9.12 pp_word bits[15:14] (PF) / §9.4 (sprite):
//     00      = opaque (winner replaces dst entirely)
//     01      = normal blend A: out = clamp(src*A_src/8 + dst*A_dst/8, 0, 255)
//     10      = reverse blend B: out = clamp(src*B_src/8 + dst*B_dst/8, 0, 255)
//     11      = opaque layer (same as 00 — winner replaces dst entirely)
//
//   win_blend_mode encodes the active blend mode (2 bits, registered with palette
//   addresses). In cycle N+1: if mode==01 → use A coefficients; if mode==10 → use B.
//
//   Darius Gaiden conflict (Test 5 from Step 13):
//     Two layers at same priority, both blend modes.
//     Second layer: layer_prio == src_prio → strictly-greater fails → skip.
//     Only the first layer's blend is applied.
//
//   Opaque layer beats blend destination:
//     An opaque layer at higher priority replaces the blend result entirely.
//
// Palette and RGB output:
//   colmix identifies src and dst palette indices.
//   Two palette read addresses are output: pal_addr_src, pal_addr_dst.
//   Top-level provides two registered palette read data words: pal_rdata_src, pal_rdata_dst.
//   Blend computation uses 4-bit R/G/B channels from each, expanded to 8-bit.
//   blend_rgb_out[23:0] = 24-bit blended RGB (available 1 cycle after colmix_pixel_out).
//
// Pipeline timing:
//   Cycle N:   Combinational: compute win_pal, win_dst, win_blend_mode.
//              Registered: colmix_pixel_out = {win_pal, win_pen}.
//              Output: pal_addr_src = {win_pal[8:0], win_pen[3:0]}, pal_addr_dst = {win_dst[8:0], 4'b0}.
//              Register: blend_mode_r, a_src_r, a_dst_r, b_src_r, b_dst_r for use in cycle N+1.
//   Cycle N+1: pal_rdata_src / pal_rdata_dst arrive (from top-level BRAM registered at N).
//              blend_rgb_out computed and registered.
//
// Output:
//   colmix_pixel_out[12:0] = {palette[8:0], pen[3:0]}
//   blend_rgb_out[23:0]    = blended 24-bit RGB
// =============================================================================

localparam int COLMIX_H_START = 46;

module tc0630fdp_colmix (
    input  logic        clk,
    input  logic        rst_n,

    // ── Video timing ──────────────────────────────────────────────────────────
    input  logic [ 9:0] hpos,
    input  logic [ 8:0] vpos,
    input  logic        pixel_valid,

    // ── Layer pixel inputs ────────────────────────────────────────────────────
    // Text: {color[4:0], pen[3:0]}.  pen==0 → transparent.
    input  logic [ 8:0] text_pixel,

    // BG PF1–PF4: {palette[8:0], pen[3:0]}.  pen==0 → transparent.
    input  logic [3:0][12:0] bg_pixel,

    // Sprite: {prio_group[1:0], palette[5:0], pen[3:0]}.  pen==0 → transparent.
    input  logic [11:0] spr_pixel,

    // Pivot: {color[3:0], pen[3:0]}.  pen==0 → transparent.  color always 4'b0.
    // Fixed priority: 8 (0–15 range; beats PF at prio<8, loses to sprite at prio>=8).
    input  logic [ 7:0] pivot_pixel,
    input  logic        ls_pivot_blend,   // 0=opaque, 1=blend A

    // ── Per-scanline priority values ──────────────────────────────────────────
    input  logic [3:0][ 3:0] ls_pf_prio,
    input  logic [3:0][ 3:0] ls_spr_prio,

    // ── Step 12: Clip plane inputs ─────────────────────────────────────────────
    input  logic [3:0][ 7:0] ls_clip_left,
    input  logic [3:0][ 7:0] ls_clip_right,
    input  logic [3:0][ 3:0] ls_pf_clip_en,
    input  logic [3:0][ 3:0] ls_pf_clip_inv,
    input  logic [3:0]        ls_pf_clip_sense,
    input  logic [ 3:0] ls_spr_clip_en,
    input  logic [ 3:0] ls_spr_clip_inv,
    input  logic        ls_spr_clip_sense,

    // ── Step 13: Alpha blend inputs ───────────────────────────────────────────
    input  logic [ 3:0] ls_a_src,          // A_src coefficient (0–8)
    input  logic [ 3:0] ls_a_dst,          // A_dst coefficient (0–8)
    input  logic [3:0][ 1:0] ls_pf_blend,   // PF blend modes (bits[15:14] of pp_word)
    input  logic [3:0][ 1:0] ls_spr_blend,  // Sprite blend modes (2 bits per group)

    // ── Step 14: Reverse blend B coefficients ─────────────────────────────────
    input  logic [ 3:0] ls_b_src,          // B_src coefficient for reverse blend (0–8)
    input  logic [ 3:0] ls_b_dst,          // B_dst coefficient for reverse blend (0–8)

    // ── Step 13: Palette RAM interface (two read ports) ────────────────────────
    // Src palette address (current winner's palette index, combinational output):
    output logic [12:0] pal_addr_src,
    // Dst palette address (blend destination's palette index, combinational output):
    output logic [12:0] pal_addr_dst,
    // Palette data arrives registered (1-cycle latency from top-level BRAM):
    input  logic [15:0] pal_rdata_src,     // palette[pal_addr_src] registered
    input  logic [15:0] pal_rdata_dst,     // palette[pal_addr_dst] registered

    // ── Composited output ─────────────────────────────────────────────────────
    output logic [12:0] colmix_pixel_out,
    // ── Step 13: Blended RGB output ───────────────────────────────────────────
    // Registered 1 cycle after colmix_pixel_out.
    output logic [23:0] blend_rgb_out,

    // ── TC0650FDA blend interface ─────────────────────────────────────────────
    // Registered 1 cycle after the combinational priority outputs (same timing as
    // colmix_pixel_out).  TC0650FDA uses these to perform its own palette lookup
    // and alpha-blend MAC instead of relying on blend_rgb_out.
    output logic [12:0] src_pal,        // source palette index (winner of priority)
    output logic [12:0] dst_pal,        // destination palette index (previous frame's pixel at same column)
    output logic [ 3:0] src_blend,      // src alpha coefficient (0–8)
    output logic [ 3:0] dst_blend,      // dst alpha coefficient (0–8)
    output logic        do_blend,       // 1 = alpha blend this pixel, 0 = opaque
    output logic        pixel_valid_out // pixel on active display (registered to match src_pal timing)
);

// ── Screen X coordinate ──────────────────────────────────────────────────────
/* verilator lint_off UNUSEDSIGNAL */
logic [8:0] screen_x_9;
/* verilator lint_on UNUSEDSIGNAL */
logic [7:0] screen_x;
always_comb begin
    if (hpos >= 10'(COLMIX_H_START))
        screen_x_9 = 9'(hpos - 10'(COLMIX_H_START));
    else
        screen_x_9 = 9'b0;
    screen_x = screen_x_9[7:0];
end

// ── Clip plane evaluation function ───────────────────────────────────────────
function automatic logic eval_clip(
    input logic [ 3:0] clip_en,
    input logic [ 3:0] clip_inv,
    input logic        clip_sense,
    input logic [ 7:0] sx,
    input logic [ 7:0] l0, l1, l2, l3,
    input logic [ 7:0] r0, r1, r2, r3
);
    logic inside_p;
    logic eff_inv;
    logic vis_p;
    logic any_en;
    logic result;
    logic [7:0] lp, rp;
    result = 1'b1;
    any_en = 1'b0;
    for (int p = 0; p < 4; p++) begin
        if (clip_en[p]) begin
            any_en = 1'b1;
            case (p)
                0: begin lp = l0; rp = r0; end
                1: begin lp = l1; rp = r1; end
                2: begin lp = l2; rp = r2; end
                3: begin lp = l3; rp = r3; end
                default: begin lp = 8'h00; rp = 8'hFF; end
            endcase
            inside_p = (sx >= lp) && (sx <= rp);
            eff_inv  = clip_inv[p] ^ clip_sense;
            vis_p    = eff_inv ? ~inside_p : inside_p;
            result   = result & vis_p;
        end
    end
    if (!any_en) result = 1'b1;
    return result;
endfunction

// ── Sprite group index and resolved priority / blend mode ─────────────────────
logic [1:0] spr_grp;
logic [3:0] spr_prio_val;
logic [1:0] spr_blend_val;

assign spr_grp = spr_pixel[11:10];

always_comb begin
    case (spr_grp)
        2'd0:    begin spr_prio_val = ls_spr_prio[0]; spr_blend_val = ls_spr_blend[0]; end
        2'd1:    begin spr_prio_val = ls_spr_prio[1]; spr_blend_val = ls_spr_blend[1]; end
        2'd2:    begin spr_prio_val = ls_spr_prio[2]; spr_blend_val = ls_spr_blend[2]; end
        2'd3:    begin spr_prio_val = ls_spr_prio[3]; spr_blend_val = ls_spr_blend[3]; end
        default: begin spr_prio_val = 4'd0;           spr_blend_val = 2'b00;          end
    endcase
end

// ── Per-layer clipped pen values ─────────────────────────────────────────────
logic [3:0][3:0] pf_pen_clipped;
logic [3:0] spr_pen_clipped;

logic [3:0] pf_vis;
genvar gi;
generate
    for (gi = 0; gi < 4; gi++) begin : gen_pf_clip
        always_comb begin
            pf_vis[gi] = eval_clip(
                ls_pf_clip_en[gi], ls_pf_clip_inv[gi], ls_pf_clip_sense[gi],
                screen_x,
                ls_clip_left[0], ls_clip_left[1], ls_clip_left[2], ls_clip_left[3],
                ls_clip_right[0], ls_clip_right[1], ls_clip_right[2], ls_clip_right[3]
            );
            pf_pen_clipped[gi] = pf_vis[gi] ? bg_pixel[gi][3:0] : 4'd0;
        end
    end
endgenerate

logic spr_vis;
always_comb begin
    spr_vis = eval_clip(
        ls_spr_clip_en, ls_spr_clip_inv, ls_spr_clip_sense,
        screen_x,
        ls_clip_left[0], ls_clip_left[1], ls_clip_left[2], ls_clip_left[3],
        ls_clip_right[0], ls_clip_right[1], ls_clip_right[2], ls_clip_right[3]
    );
    spr_pen_clipped = spr_vis ? spr_pixel[3:0] : 4'd0;
end

// ── Layer field extraction ────────────────────────────────────────────────────
logic [3:0][3:0]  pf_pen;
logic [3:0][8:0]  pf_pal;
logic [3:0][4:0]  pf_prio;
logic [3:0][1:0]  pf_bmode;

generate
    for (gi = 0; gi < 4; gi++) begin : gen_pf_fields
        assign pf_pen[gi]   = pf_pen_clipped[gi];
        assign pf_pal[gi]   = bg_pixel[gi][12:4];
        assign pf_prio[gi]  = {1'b0, ls_pf_prio[gi]};
        assign pf_bmode[gi] = ls_pf_blend[gi];
    end
endgenerate

logic [4:0]  spr_prio5;
logic [8:0]  spr_pal9;
logic [3:0]  spr_pen;
logic [1:0]  spr_bmode;

assign spr_prio5 = {1'b0, spr_prio_val};
assign spr_pal9  = {3'b0, spr_pixel[9:4]};
assign spr_pen   = spr_pen_clipped;
assign spr_bmode = spr_blend_val;

logic [3:0]  text_pen_w;
logic [4:0]  text_color;
logic [8:0]  text_pal9;

assign text_pen_w = text_pixel[3:0];
assign text_color = text_pixel[8:4];
assign text_pal9  = {4'b0, text_color};

// =============================================================================
// Phase 5: Pipelined compositor — 2-stage registered arbitration to reduce
// combinational depth.  Original 6-deep cascade (PF0→PF1→PF2→PF3→SPR→PVT→TXT)
// is split into:
//   Sub-stage A (combinational): PF0 vs PF1  → pipeline register p01_*
//                                 PF2 vs PF3  → pipeline register p23_*
//                                 SPR/PVT/TXT → 1-cycle delay registers
//   Sub-stage B (combinational, next cycle): p01 vs p23 → vs spr → vs pvt → vs txt → win_*
//   Final register: colmix_pixel_out = {win_pal, win_pen}  (+1 cycle total latency)
//
// Net latency: +1 pixel clock cycle on top of existing 1-cycle register.
// All downstream consumers (pal_addr_src/dst, blend pipeline, TC0650FDA) are
// driven from sub-stage B combinational nets and are self-consistent.
// =============================================================================

// ── Sub-stage A: PF0 vs PF1 (combinational) ──────────────────────────────────
logic [4:0]  a01_prio; logic [8:0] a01_pal; logic [3:0] a01_pen;
logic [8:0]  a01_dst;  logic [1:0] a01_bmode;

always_comb begin
    automatic logic [4:0] w0p; automatic logic [8:0] w0l; automatic logic [3:0] w0n;
    automatic logic [8:0] w0d; automatic logic [1:0] w0b;
    if (pf_pen[0] != 4'd0) begin
        w0p = pf_prio[0]; w0l = pf_pal[0]; w0n = pf_pen[0]; w0d = 9'b0; w0b = 2'b00;
    end else begin
        w0p = 5'd0; w0l = 9'd0; w0n = 4'd0; w0d = 9'd0; w0b = 2'b00;
    end
    if (pf_pen[1] != 4'd0 && (w0n == 4'd0 || pf_prio[1] > w0p)) begin
        a01_prio = pf_prio[1]; a01_pal = pf_pal[1]; a01_pen = pf_pen[1];
        if ((pf_bmode[1] == 2'b01 || pf_bmode[1] == 2'b10) && w0n != 4'd0) begin
            a01_dst = w0l; a01_bmode = pf_bmode[1];
        end else begin
            a01_dst = 9'b0; a01_bmode = 2'b00;
        end
    end else begin
        a01_prio = w0p; a01_pal = w0l; a01_pen = w0n; a01_dst = w0d; a01_bmode = w0b;
    end
end

// ── Sub-stage A: PF2 vs PF3 (combinational) ──────────────────────────────────
logic [4:0]  a23_prio; logic [8:0] a23_pal; logic [3:0] a23_pen;
logic [8:0]  a23_dst;  logic [1:0] a23_bmode;

always_comb begin
    automatic logic [4:0] w2p; automatic logic [8:0] w2l; automatic logic [3:0] w2n;
    automatic logic [8:0] w2d; automatic logic [1:0] w2b;
    if (pf_pen[2] != 4'd0) begin
        w2p = pf_prio[2]; w2l = pf_pal[2]; w2n = pf_pen[2]; w2d = 9'b0; w2b = 2'b00;
    end else begin
        w2p = 5'd0; w2l = 9'd0; w2n = 4'd0; w2d = 9'd0; w2b = 2'b00;
    end
    if (pf_pen[3] != 4'd0 && (w2n == 4'd0 || pf_prio[3] > w2p)) begin
        a23_prio = pf_prio[3]; a23_pal = pf_pal[3]; a23_pen = pf_pen[3];
        if ((pf_bmode[3] == 2'b01 || pf_bmode[3] == 2'b10) && w2n != 4'd0) begin
            a23_dst = w2l; a23_bmode = pf_bmode[3];
        end else begin
            a23_dst = 9'b0; a23_bmode = 2'b00;
        end
    end else begin
        a23_prio = w2p; a23_pal = w2l; a23_pen = w2n; a23_dst = w2d; a23_bmode = w2b;
    end
end

// ── Sub-stage A pipeline registers ───────────────────────────────────────────
// Register PF01/PF23 sub-winners and delay all other inputs by 1 cycle.
logic [4:0]  p01_prio; logic [8:0] p01_pal; logic [3:0] p01_pen;
logic [8:0]  p01_dst;  logic [1:0] p01_bmode;
logic [4:0]  p23_prio; logic [8:0] p23_pal; logic [3:0] p23_pen;
logic [8:0]  p23_dst;  logic [1:0] p23_bmode;
// Delayed sprite signals (1 cycle) for sub-stage B alignment
logic [4:0]  spr_prio5_d;
logic [8:0]  spr_pal9_d;
logic [3:0]  spr_pen_d;
logic [1:0]  spr_bmode_d;
// Delayed pivot/text pixels
logic [7:0]  pivot_pixel_d;
logic        ls_pivot_blend_d;
logic [8:0]  text_pixel_d;
// Delayed blend coefficients (aligned with sub-stage B win_bmode)
logic [3:0]  a_src_d, a_dst_d, b_src_d, b_dst_d;
// Delayed pixel_valid and hpos for TC0650FDA timing
logic        pixel_valid_d;
logic [9:0]  hpos_d;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        p01_prio <= 5'b0;  p01_pal <= 9'b0;  p01_pen <= 4'b0;
        p01_dst  <= 9'b0;  p01_bmode <= 2'b0;
        p23_prio <= 5'b0;  p23_pal <= 9'b0;  p23_pen <= 4'b0;
        p23_dst  <= 9'b0;  p23_bmode <= 2'b0;
        spr_prio5_d     <= 5'b0;
        spr_pal9_d      <= 9'b0;
        spr_pen_d       <= 4'b0;
        spr_bmode_d     <= 2'b0;
        pivot_pixel_d   <= 8'b0;
        ls_pivot_blend_d<= 1'b0;
        text_pixel_d    <= 9'b0;
        a_src_d         <= 4'd8;
        a_dst_d         <= 4'd0;
        b_src_d         <= 4'd8;
        b_dst_d         <= 4'd0;
        pixel_valid_d   <= 1'b0;
        hpos_d          <= 10'b0;
    end else begin
        p01_prio <= a01_prio;  p01_pal <= a01_pal;  p01_pen <= a01_pen;
        p01_dst  <= a01_dst;   p01_bmode <= a01_bmode;
        p23_prio <= a23_prio;  p23_pal <= a23_pal;  p23_pen <= a23_pen;
        p23_dst  <= a23_dst;   p23_bmode <= a23_bmode;
        spr_prio5_d     <= spr_prio5;
        spr_pal9_d      <= spr_pal9;
        spr_pen_d       <= spr_pen_clipped;
        spr_bmode_d     <= spr_bmode;
        pivot_pixel_d   <= pivot_pixel;
        ls_pivot_blend_d<= ls_pivot_blend;
        text_pixel_d    <= text_pixel;
        a_src_d         <= ls_a_src;
        a_dst_d         <= ls_a_dst;
        b_src_d         <= ls_b_src;
        b_dst_d         <= ls_b_dst;
        pixel_valid_d   <= pixel_valid;
        hpos_d          <= hpos;
    end
end

// ── Sub-stage B: p01 vs p23 → spr → pvt → txt → win_* (combinational) ────────
logic [4:0]  win_prio;
logic [8:0]  win_pal;
logic [3:0]  win_pen;
logic [8:0]  win_dst;
logic [1:0]  win_bmode;

always_comb begin
    automatic logic [4:0] wm_prio; automatic logic [8:0] wm_pal; automatic logic [3:0] wm_pen;
    automatic logic [8:0] wm_dst;  automatic logic [1:0] wm_bmode;
    automatic logic [4:0] ws_prio; automatic logic [8:0] ws_pal; automatic logic [3:0] ws_pen;
    automatic logic [8:0] ws_dst;  automatic logic [1:0] ws_bmode;
    automatic logic [4:0] wp_prio; automatic logic [8:0] wp_pal; automatic logic [3:0] wp_pen;
    automatic logic [8:0] wp_dst;  automatic logic [1:0] wp_bmode;
    automatic logic [3:0] pvt_pen_b;  automatic logic [8:0] pvt_pal9_b;
    automatic logic [3:0] txt_pen_b;  automatic logic [4:0] txt_col_b;
    automatic logic [8:0] txt_pal9_b;

    // Merge p01 vs p23
    if (p23_pen != 4'd0 && (p01_pen == 4'd0 || p23_prio > p01_prio)) begin
        wm_prio = p23_prio; wm_pal = p23_pal; wm_pen = p23_pen;
        if ((p23_bmode == 2'b01 || p23_bmode == 2'b10) && p23_dst != 9'b0) begin
            wm_dst = p23_dst; wm_bmode = p23_bmode;   // PF3 beat PF2 within pair
        end else if ((p23_bmode == 2'b01 || p23_bmode == 2'b10) && p01_pen != 4'd0) begin
            wm_dst = p01_pal; wm_bmode = p23_bmode;   // PF23 winner blends against PF01
        end else begin
            wm_dst = 9'b0; wm_bmode = 2'b00;
        end
    end else begin
        wm_prio = p01_prio; wm_pal = p01_pal; wm_pen = p01_pen;
        wm_dst  = p01_dst;  wm_bmode = p01_bmode;
    end

    // Sprite (wins on tie >=)
    if (spr_pen_d != 4'd0 && (wm_pen == 4'd0 || spr_prio5_d >= wm_prio)) begin
        ws_prio = spr_prio5_d; ws_pal = spr_pal9_d; ws_pen = spr_pen_d;
        if ((spr_bmode_d == 2'b01 || spr_bmode_d == 2'b10) && wm_pen != 4'd0) begin
            ws_dst = wm_pal; ws_bmode = spr_bmode_d;
        end else begin
            ws_dst = 9'b0; ws_bmode = 2'b00;
        end
    end else begin
        ws_prio = wm_prio; ws_pal = wm_pal; ws_pen = wm_pen;
        ws_dst  = wm_dst;  ws_bmode = wm_bmode;
    end

    // Pivot — fixed priority 8
    pvt_pen_b  = pivot_pixel_d[3:0];
    pvt_pal9_b = {5'b0, pivot_pixel_d[7:4]};
    if (pvt_pen_b != 4'd0 && (ws_pen == 4'd0 || 5'd8 > ws_prio)) begin
        wp_prio = 5'd8; wp_pal = pvt_pal9_b; wp_pen = pvt_pen_b;
        if (ls_pivot_blend_d && ws_pen != 4'd0) begin
            wp_dst = ws_pal; wp_bmode = 2'b01;
        end else begin
            wp_dst = 9'b0; wp_bmode = 2'b00;
        end
    end else begin
        wp_prio = ws_prio; wp_pal = ws_pal; wp_pen = ws_pen;
        wp_dst  = ws_dst;  wp_bmode = ws_bmode;
    end

    // Text — always opaque, always wins
    txt_pen_b  = text_pixel_d[3:0];
    txt_col_b  = text_pixel_d[8:4];
    txt_pal9_b = {4'b0, txt_col_b};
    if (txt_pen_b != 4'd0) begin
        win_prio = 5'd16; win_pal = txt_pal9_b; win_pen = txt_pen_b;
        win_dst  = 9'b0;  win_bmode = 2'b00;
    end else begin
        win_prio = wp_prio; win_pal = wp_pal; win_pen = wp_pen;
        win_dst  = wp_dst;  win_bmode = wp_bmode;
    end
end

// Suppress unused win_prio
/* verilator lint_off UNUSED */
logic _unused_winprio;
assign _unused_winprio = ^win_prio;
/* verilator lint_on UNUSED */

/* verilator lint_off UNUSED */
logic win_do_blend;
/* verilator lint_on UNUSED */
assign win_do_blend = (win_bmode == 2'b01) || (win_bmode == 2'b10);

// ── Registered colmix_pixel_out ───────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n)
        colmix_pixel_out <= 13'b0;
    else
        colmix_pixel_out <= {win_pal, win_pen};
end

// ── Palette address outputs ────────────────────────────────────────────────────
// Driven from sub-stage B combinational nets (1 cycle later than original).
// Palette BRAM registers them → pal_rdata_src/dst arrive 1 cycle after win_*.
assign pal_addr_src = {win_pal, win_pen};    // 9+4 = 13 bits
assign pal_addr_dst = {win_dst, 4'b0};       // 9+4 = 13 bits

// ── Step 13: Blend pipeline (1-cycle palette latency) ─────────────────────────
// Stage 0 (this cycle):
//   - win_blend, ls_a_src, ls_a_dst are combinational inputs
//   - We register them for use in stage 1
//   - pal_addr_src/dst are combinational outputs → top-level registers them into BRAM
// Stage 1 (next cycle):
//   - pal_rdata_src arrives = palette[pal_addr_src from prev cycle]
//   - pal_rdata_dst arrives = palette[pal_addr_dst from prev cycle]
//   - Compute blend: out = clamp(src*A_src/8 + dst*A_dst/8)
//   - Register into blend_rgb_out

// Stage 0 pipeline registers
// Blend coefficients (a_src_d etc.) are already 1-cycle delayed in sub-stage A
// registers, keeping them aligned with win_bmode from sub-stage B.
logic [1:0]  blend_mode_r;   // registered blend mode (00=opaque, 01=A, 10=B, 11=opaque)
logic [ 3:0] a_src_r;
logic [ 3:0] a_dst_r;
logic [ 3:0] b_src_r;
logic [ 3:0] b_dst_r;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        blend_mode_r <= 2'b00;
        a_src_r      <= 4'd8;
        a_dst_r      <= 4'd0;
        b_src_r      <= 4'd8;
        b_dst_r      <= 4'd0;
    end else begin
        blend_mode_r <= win_bmode;
        a_src_r      <= a_src_d;   // 1-cycle delayed, aligned with sub-stage B
        a_dst_r      <= a_dst_d;
        b_src_r      <= b_src_d;
        b_dst_r      <= b_dst_d;
    end
end

// ── Palette color decode ──────────────────────────────────────────────────────
// Format: bits[15:12]=R(4-bit), bits[11:8]=G(4-bit), bits[7:4]=B(4-bit), bits[3:0]=don't care
// Expand 4-bit to 8-bit: v * 17 = {v, v} (concatenation)
function automatic logic [7:0] expand4to8(input logic [3:0] v);
    return {v, v};
endfunction

// Src color channels (from pal_rdata_src)
logic [7:0] src_r, src_g, src_b;
always_comb begin
    src_r = expand4to8(pal_rdata_src[15:12]);
    src_g = expand4to8(pal_rdata_src[11:8]);
    src_b = expand4to8(pal_rdata_src[7:4]);
end

// Dst color channels (from pal_rdata_dst)
logic [7:0] dst_r, dst_g, dst_b;
always_comb begin
    dst_r = expand4to8(pal_rdata_dst[15:12]);
    dst_g = expand4to8(pal_rdata_dst[11:8]);
    dst_b = expand4to8(pal_rdata_dst[7:4]);
end

// ── Alpha blend computation ────────────────────────────────────────────────────
// Formula: out = clamp(src * A_src/8 + dst * A_dst/8, 0, 255)
// A_src / A_dst are 4-bit (0–8).
// 8-bit color * 4-bit coeff = 12-bit product; sum = 13-bit; saturate to 8-bit.
//
// Note: multiply width in SV = max of operand widths.
// To get correct 12-bit products: 16'(src_r) * 16'(a_src_r) → 16-bit result >> 3.
// We actually need: (src_r * a_src_r) >> 3 with saturation.
// Using 12-bit intermediates: 8'b * 4'b = 12'b; sum = 13-bit.

function automatic logic [7:0] blend_channel(
    input logic [7:0] src,
    input logic [7:0] dst,
    input logic [3:0] a_s,  // A_src (0–8)
    input logic [3:0] a_d   // A_dst (0–8)
);
    logic [11:0] prod_src;
    logic [11:0] prod_dst;
    logic [12:0] sum13;
    prod_src = 12'(src) * 12'(a_s);   // 8 * 4 = at most 255*8=2040, fits in 12 bits
    prod_dst = 12'(dst) * 12'(a_d);
    sum13    = 13'(prod_src) + 13'(prod_dst);  // sum >> 3 needed; sum13 is (sum*8)
    // sum13 = (src*a_s + dst*a_d); we want (src*a_s + dst*a_d) / 8
    // Divide by 8 by right-shifting 3:
    if (sum13 >= 13'h7F8) begin  // saturate: if sum13/8 >= 255 then 255
        return 8'hFF;
    end else begin
        return 8'(sum13 >> 3);
    end
endfunction

// Stage 1: compute blend_rgb_out
always_ff @(posedge clk) begin
    if (!rst_n) begin
        blend_rgb_out <= 24'b0;
    end else begin
        case (blend_mode_r)
            2'b01: begin
                // Normal blend A: src*A_src/8 + dst*A_dst/8
                blend_rgb_out <= {
                    blend_channel(src_r, dst_r, a_src_r, a_dst_r),
                    blend_channel(src_g, dst_g, a_src_r, a_dst_r),
                    blend_channel(src_b, dst_b, a_src_r, a_dst_r)
                };
            end
            2'b10: begin
                // Reverse blend B: src*B_src/8 + dst*B_dst/8
                blend_rgb_out <= {
                    blend_channel(src_r, dst_r, b_src_r, b_dst_r),
                    blend_channel(src_g, dst_g, b_src_r, b_dst_r),
                    blend_channel(src_b, dst_b, b_src_r, b_dst_r)
                };
            end
            default: begin
                // Opaque (modes 00 and 11): output src color directly
                blend_rgb_out <= {src_r, src_g, src_b};
            end
        endcase
    end
end

// =============================================================================
// TC0650FDA blend interface outputs
// =============================================================================
// Per-column destination palette buffer: stores the src_pal output for each
// active display column so that the next frame can use it as dst_pal (the
// previously rendered pixel at the same screen position).
logic [12:0] dst_pal_buf [0:319];

// Registered column index (tracks screen_x_9 one cycle after the combinational
// priority outputs — matches the registered src_pal timing).
logic [8:0] screen_col_r;

// Combinational blend coefficients for TC0650FDA: use delayed coefficients
// (a_src_d etc.) which are aligned with sub-stage B win_bmode.
logic [3:0] win_src_coeff;
logic [3:0] win_dst_coeff;
logic       win_do_blend_c;

always_comb begin
    win_do_blend_c = (win_bmode == 2'b01) || (win_bmode == 2'b10);
    case (win_bmode)
        2'b01: begin
            win_src_coeff = a_src_d;   // aligned with sub-stage B
            win_dst_coeff = a_dst_d;
        end
        2'b10: begin
            win_src_coeff = b_src_d;
            win_dst_coeff = b_dst_d;
        end
        default: begin
            win_src_coeff = 4'd8;
            win_dst_coeff = 4'd0;
        end
    endcase
end

// Delayed screen_x_9 (1 cycle, for TC0650FDA dst_pal_buf lookup aligned with sub-stage B)
logic [8:0] screen_x_9_d;
always_comb begin
    if (hpos_d >= 10'(COLMIX_H_START))
        screen_x_9_d = 9'(hpos_d - 10'(COLMIX_H_START));
    else
        screen_x_9_d = 9'b0;
end

// Register all TC0650FDA outputs on posedge clk (1 cycle after sub-stage B).
always_ff @(posedge clk) begin
    if (!rst_n) begin
        src_pal         <= 13'b0;
        dst_pal         <= 13'b0;
        src_blend       <= 4'd8;
        dst_blend       <= 4'd0;
        do_blend        <= 1'b0;
        pixel_valid_out <= 1'b0;
        screen_col_r    <= 9'b0;
    end else begin
        src_pal         <= {win_pal, win_pen};
        dst_pal         <= (screen_x_9_d < 9'd320) ? dst_pal_buf[screen_x_9_d] : 13'b0;
        src_blend       <= win_src_coeff;
        dst_blend       <= win_dst_coeff;
        do_blend        <= win_do_blend_c;
        pixel_valid_out <= pixel_valid_d;  // 1-cycle delayed
        screen_col_r    <= screen_x_9_d;
    end
end

// Update dst_pal_buf with the just-registered src_pal value for use next frame.
// The write uses screen_col_r (the column registered alongside src_pal) so the
// write address matches the registered output.  Only write during active display
// (pixel_valid_out guards against writing stale data during blanking).
always_ff @(posedge clk) begin
    if (pixel_valid_out && screen_col_r < 9'd320)
        dst_pal_buf[screen_col_r] <= src_pal;
end

// ── Suppress unused-signal warnings ──────────────────────────────────────────
/* verilator lint_off UNUSED */
logic _unused_colmix;
// vpos: timing input not needed in compositor
// win_dst: used in blend tracking but Verilator sees intermediate net as unused
// pal_rdata[3:0]: palette format has don't-care bits[3:0] (color uses bits[15:4] only)
assign _unused_colmix = ^{vpos, win_dst,
                           pal_rdata_src[3:0], pal_rdata_dst[3:0]};
/* verilator lint_on UNUSED */

endmodule
