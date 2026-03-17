`default_nettype none
// =============================================================================
// TC0630FDP — Layer Compositor / Color Mixer (Step 12: +Clip Planes)
// =============================================================================
// Implements a 6-layer priority mux with per-layer clip plane evaluation:
//   - 4 PF tilemap layers (PF1–PF4): variable priority 0–15 from Line RAM §9.12
//   - Text layer: fixed highest priority (always on top, overrides all)
//   - Sprite layer: 4 priority groups (0x00/0x40/0x80/0xC0), priority 0–15 from §9.8
//
// Priority rules (Step 11, no alpha blend):
//   1. Text layer wins over everything if pen != 0.
//   2. Among PF and sprite layers, higher numeric priority wins.
//   3. Equal-priority tie: sprite wins over PF.
//   4. Transparent pixels (pen == 0) are skipped.
//   5. If all layers are transparent, output pen=0 (background).
//
// Clip plane evaluation (Step 12):
//   For each PF layer n and sprite layer:
//     For each enabled clip plane p (ls_pf_clip_en[n][p] or ls_spr_clip_en[p]):
//       inside_p = (screen_x >= ls_clip_left[p]) && (screen_x <= ls_clip_right[p])
//     Normal mode (clip_inv[p]==0): pixel visible if inside ALL enabled planes.
//       visible = AND of all enabled inside_p
//     Invert mode (clip_inv[p]==1): pixel blanked if inside that plane (complement).
//       For each plane independently: if clip_inv[p] set, flip inside_p.
//     Inversion sense bit: if set, invert the overall clip_invert interpretation.
//   If layer is clipped (not visible): treat pen as 0 (transparent) for that layer.
//   Text layer has no clip planes.
//
// Output:
//   colmix_pixel_out[12:0] = {palette[8:0], pen[3:0]}
//     pen==0 means all layers transparent.
//     Text layer stores color[4:0] in palette[4:0] (bits[8:5] are 0).
//
// Screen X coordinate: hpos - H_START  (valid during active display, hpos in [46,366))
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
    input  logic [12:0] bg_pixel  [0:3],

    // Sprite: {prio_group[1:0], palette[5:0], pen[3:0]}.  pen==0 → transparent.
    input  logic [11:0] spr_pixel,

    // ── Per-scanline priority values ──────────────────────────────────────────
    // PF priority: ls_pf_prio[n] = priority for PF(n+1).
    input  logic [ 3:0] ls_pf_prio  [0:3],
    // Sprite group priorities: [0]=group0x00, [1]=group0x40, [2]=group0x80, [3]=group0xC0.
    input  logic [ 3:0] ls_spr_prio [0:3],

    // ── Step 12: Clip plane inputs ─────────────────────────────────────────────
    // Clip plane boundaries (8-bit, one per plane 0–3):
    input  logic [ 7:0] ls_clip_left   [0:3],
    input  logic [ 7:0] ls_clip_right  [0:3],

    // PF clip configuration (per PF layer):
    //   ls_pf_clip_en[n]      = 4-bit enable mask (one bit per clip plane)
    //   ls_pf_clip_inv[n]     = 4-bit invert mask (per clip plane)
    //   ls_pf_clip_sense[n]   = inversion sense bit
    input  logic [ 3:0] ls_pf_clip_en   [0:3],
    input  logic [ 3:0] ls_pf_clip_inv  [0:3],
    input  logic        ls_pf_clip_sense[0:3],

    // Sprite clip configuration:
    input  logic [ 3:0] ls_spr_clip_en,
    input  logic [ 3:0] ls_spr_clip_inv,
    input  logic        ls_spr_clip_sense,

    // ── Composited output ─────────────────────────────────────────────────────
    output logic [12:0] colmix_pixel_out
);

// ── Screen X coordinate ──────────────────────────────────────────────────────
// screen_x is valid during active display (when pixel_valid is asserted).
// hpos is 10-bit; H_START=46; active region [46,366). screen_x = hpos - H_START.
// Active area is 320 pixels (0–319), which fits in 9 bits; clip boundaries are
// 8-bit (0–255) so we use the lower 8 bits for comparison.
// screen_x_9[8] is unused because clip boundaries are 8-bit (0–255 max).
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
// Evaluate 4 clip planes for a layer. Returns 1 if the pixel is VISIBLE.
// Parameters:
//   clip_en    : 4-bit enable mask
//   clip_inv   : 4-bit invert mask (per-plane inversion)
//   clip_sense : inversion sense (when 1, flip invert interpretation)
//   sx         : 9-bit screen X
//   left[0..3] : clip plane left boundaries
//   right[0..3]: clip plane right boundaries
//
// Algorithm (per section1 §12.3):
//   For each enabled plane p:
//     inside_p = (sx >= left[p]) && (sx <= right[p])
//     effective_inv_p = clip_inv[p] XOR clip_sense
//     if effective_inv_p: visible_p = !inside_p  (invert mode — blank inside)
//     else:               visible_p = inside_p   (normal mode — show inside)
//   If no planes enabled: visible = 1 (no clip).
//   Intersect all enabled plane visibility: visible = AND of all visible_p.
//
// Result: 1 = pixel passes clip (visible), 0 = pixel clipped (blanked).

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
            // Select boundaries for plane p
            unique case (p)
                0: begin lp = l0; rp = r0; end
                1: begin lp = l1; rp = r1; end
                2: begin lp = l2; rp = r2; end
                3: begin lp = l3; rp = r3; end
                default: begin lp = 8'h00; rp = 8'hFF; end
            endcase
            // inside_p: left is inclusive, right is inclusive
            inside_p = (sx >= lp) && (sx <= rp);
            // effective invert: per-plane invert XOR sense bit
            eff_inv = clip_inv[p] ^ clip_sense;
            // visible_p: in normal mode show inside; in invert mode show outside
            vis_p = eff_inv ? ~inside_p : inside_p;
            // Intersect: pixel visible only if ALL enabled planes pass
            result = result & vis_p;
        end
    end
    // If no planes enabled, no clip (always visible)
    if (!any_en) result = 1'b1;
    return result;
endfunction

// ── Sprite group index and resolved priority ─────────────────────────────────
logic [1:0] spr_grp;
logic [3:0] spr_prio_val;

assign spr_grp = spr_pixel[11:10];

always_comb begin
    unique case (spr_grp)
        2'd0:    spr_prio_val = ls_spr_prio[0];
        2'd1:    spr_prio_val = ls_spr_prio[1];
        2'd2:    spr_prio_val = ls_spr_prio[2];
        2'd3:    spr_prio_val = ls_spr_prio[3];
        default: spr_prio_val = 4'd0;
    endcase
end

// ── Per-layer clipped pen values ─────────────────────────────────────────────
// Apply clip plane evaluation: if clipped, force pen to 0.

logic [3:0] pf_pen_clipped  [0:3];
logic [3:0] spr_pen_clipped;

// Per-PF clip evaluation
logic pf_vis [0:3];
genvar gi;
generate
    for (gi = 0; gi < 4; gi++) begin : gen_pf_clip
        always_comb begin
            pf_vis[gi] = eval_clip(
                ls_pf_clip_en[gi],
                ls_pf_clip_inv[gi],
                ls_pf_clip_sense[gi],
                screen_x,
                ls_clip_left[0], ls_clip_left[1], ls_clip_left[2], ls_clip_left[3],
                ls_clip_right[0], ls_clip_right[1], ls_clip_right[2], ls_clip_right[3]
            );
            pf_pen_clipped[gi] = (pf_vis[gi]) ? bg_pixel[gi][3:0] : 4'd0;
        end
    end
endgenerate

// Sprite clip evaluation
logic spr_vis;
always_comb begin
    spr_vis = eval_clip(
        ls_spr_clip_en,
        ls_spr_clip_inv,
        ls_spr_clip_sense,
        screen_x,
        ls_clip_left[0], ls_clip_left[1], ls_clip_left[2], ls_clip_left[3],
        ls_clip_right[0], ls_clip_right[1], ls_clip_right[2], ls_clip_right[3]
    );
    spr_pen_clipped = spr_vis ? spr_pixel[3:0] : 4'd0;
end

// ── Combinational winner selection ────────────────────────────────────────────
// Variables for the rolling best-candidate.
// 5-bit priority: 0–15 for PF/sprite layers, 16 for text (always top).
// We initialize with pen=0 (transparent) meaning "no winner yet".
// Any opaque layer beats "no winner" regardless of its priority value.

logic [4:0]  win_prio;
logic [8:0]  win_pal;
logic [3:0]  win_pen;

// Per-PF intermediate candidates (unrolled to avoid generate issues)
// pf_beats[n] is 1 when PFn should update the current winner.
logic [3:0]  pf_pen  [0:3];
logic [8:0]  pf_pal  [0:3];
logic [4:0]  pf_prio [0:3];

generate
    for (gi = 0; gi < 4; gi++) begin : gen_pf_fields
        assign pf_pen[gi]  = pf_pen_clipped[gi];      // clipped pen (0 if outside clip)
        assign pf_pal[gi]  = bg_pixel[gi][12:4];
        assign pf_prio[gi] = {1'b0, ls_pf_prio[gi]};
    end
endgenerate

logic [4:0]  spr_prio5;
logic [8:0]  spr_pal9;
logic [3:0]  spr_pen;

assign spr_prio5 = {1'b0, spr_prio_val};
assign spr_pal9  = {3'b0, spr_pixel[9:4]};
assign spr_pen   = spr_pen_clipped;                   // clipped pen

logic [3:0]  text_pen_w;
logic [4:0]  text_color;
logic [8:0]  text_pal9;

assign text_pen_w  = text_pixel[3:0];
assign text_color  = text_pixel[8:4];
assign text_pal9   = {4'b0, text_color};

// Rolling arbitration across 6 layers
// Unrolled manually to keep Verilator happy with no variable declarations in always_comb.

// After PF0:
logic [4:0]  w0_prio;  logic [8:0]  w0_pal;  logic [3:0]  w0_pen;
// After PF1:
logic [4:0]  w1_prio;  logic [8:0]  w1_pal;  logic [3:0]  w1_pen;
// After PF2:
logic [4:0]  w2_prio;  logic [8:0]  w2_pal;  logic [3:0]  w2_pen;
// After PF3:
logic [4:0]  w3_prio;  logic [8:0]  w3_pal;  logic [3:0]  w3_pen;
// After sprite:
logic [4:0]  w4_prio;  logic [8:0]  w4_pal;  logic [3:0]  w4_pen;
// After text (final):
//   text_pen_w, text_pal9, 16 always win

// PF0 — first layer, initializes from "no winner" (pen=0)
always_comb begin
    if (pf_pen[0] != 4'd0) begin
        w0_prio = pf_prio[0];
        w0_pal  = pf_pal[0];
        w0_pen  = pf_pen[0];
    end else begin
        w0_prio = 5'd0;
        w0_pal  = 9'd0;
        w0_pen  = 4'd0;
    end
end

// PF1 — wins only if pen!=0 AND (no winner yet OR strictly higher priority)
always_comb begin
    if (pf_pen[1] != 4'd0 && (w0_pen == 4'd0 || pf_prio[1] > w0_prio)) begin
        w1_prio = pf_prio[1];
        w1_pal  = pf_pal[1];
        w1_pen  = pf_pen[1];
    end else begin
        w1_prio = w0_prio;
        w1_pal  = w0_pal;
        w1_pen  = w0_pen;
    end
end

// PF2
always_comb begin
    if (pf_pen[2] != 4'd0 && (w1_pen == 4'd0 || pf_prio[2] > w1_prio)) begin
        w2_prio = pf_prio[2];
        w2_pal  = pf_pal[2];
        w2_pen  = pf_pen[2];
    end else begin
        w2_prio = w1_prio;
        w2_pal  = w1_pal;
        w2_pen  = w1_pen;
    end
end

// PF3
always_comb begin
    if (pf_pen[3] != 4'd0 && (w2_pen == 4'd0 || pf_prio[3] > w2_prio)) begin
        w3_prio = pf_prio[3];
        w3_pal  = pf_pal[3];
        w3_pen  = pf_pen[3];
    end else begin
        w3_prio = w2_prio;
        w3_pal  = w2_pal;
        w3_pen  = w2_pen;
    end
end

// Sprite — wins on tie (>=) over PF at same priority
always_comb begin
    if (spr_pen != 4'd0 && (w3_pen == 4'd0 || spr_prio5 >= w3_prio)) begin
        w4_prio = spr_prio5;
        w4_pal  = spr_pal9;
        w4_pen  = spr_pen;
    end else begin
        w4_prio = w3_prio;
        w4_pal  = w3_pal;
        w4_pen  = w3_pen;
    end
end

// Text — always wins over any priority-0–15 layer
always_comb begin
    if (text_pen_w != 4'd0) begin
        win_prio = 5'd16;
        win_pal  = text_pal9;
        win_pen  = text_pen_w;
    end else begin
        win_prio = w4_prio;
        win_pal  = w4_pal;
        win_pen  = w4_pen;
    end
end

// Suppress unused win_prio
/* verilator lint_off UNUSED */
logic _unused_winprio;
assign _unused_winprio = ^win_prio;
/* verilator lint_on UNUSED */

// ── Registered output ─────────────────────────────────────────────────────────
always_ff @(posedge clk) begin
    if (!rst_n)
        colmix_pixel_out <= 13'b0;
    else
        colmix_pixel_out <= {win_pal, win_pen};
end

// ── Suppress unused-signal warnings ──────────────────────────────────────────
/* verilator lint_off UNUSED */
logic _unused_colmix;
assign _unused_colmix = ^{vpos, pixel_valid};
/* verilator lint_on UNUSED */

endmodule
