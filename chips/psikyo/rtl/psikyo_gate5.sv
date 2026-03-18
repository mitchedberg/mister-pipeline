// Psikyo Gate 5 — Priority Mixer / Color Compositor
// Purely combinational priority compositor for 2 BG layers + sprites.
//
// Priority rules (painter's algorithm, lowest → highest):
//   1. BG1  (bottom background)
//   2. Sprites with priority=0
//   3. BG0  (foreground)
//   4. Sprites with priority=1
//   5. Sprites with priority=2  (above foreground)
//   6. Sprites with priority=3  (topmost)
//
// Transparency: valid=0 or color=0 → pixel is transparent and falls through.
//
// Inputs from Gate 3 (sprite rasterizer read-back):
//   spr_rd_color    — {palette[3:0], nybble[3:0]} for the sprite pixel at this X
//   spr_rd_valid    — 1 = opaque sprite pixel present
//   spr_rd_priority — 2-bit sprite priority field (0–3)
//
// Inputs from Gate 4 (BG tilemap renderer):
//   bg_pix_color[0] — BG0 (foreground layer) pixel color
//   bg_pix_color[1] — BG1 (background layer) pixel color
//   bg_pix_valid    — one bit per layer: [0]=BG0, [1]=BG1
//   bg_pix_priority — 2-bit priority field per layer (from tilemap entry / tile attrib)
//                     (not used for inter-layer ordering here; carried through for
//                      upstream use but does not affect the Gate 5 composition order)
//
// Date: 2026-03-17

/* verilator lint_off UNUSEDSIGNAL */
module psikyo_gate5 (
    // ── Sprite pixel (from Gate 3 scanline buffer read-back) ─────────────────
    input  logic [7:0] spr_rd_color,       // {palette[3:0], nybble[3:0]}
    input  logic       spr_rd_valid,       // 1 = opaque sprite pixel
    input  logic [1:0] spr_rd_priority,    // sprite priority field (0–3)

    // ── BG layer pixels (from Gate 4 tilemap renderer) ───────────────────────
    // Index 0 = BG0 (foreground), index 1 = BG1 (background)
    input  logic [1:0][7:0] bg_pix_color,         // {palette[3:0], nybble[3:0]}
    input  logic [1:0] bg_pix_valid,              // [0]=BG0 valid, [1]=BG1 valid
    input  logic [1:0][1:0] bg_pix_priority,      // per-layer priority attribute

    // ── Compositor output ────────────────────────────────────────────────────
    output logic [7:0] final_color,    // 8-bit palette index of winning pixel
    output logic       final_valid     // 1 = at least one layer contributed
);

    // ── Unused: bg_pix_priority is carried through for upstream use only ─────
    logic _unused_bg_prio;
    assign _unused_bg_prio = &{bg_pix_priority[0], bg_pix_priority[1], 1'b0};

    // ── Priority mixer (painter's algorithm) ─────────────────────────────────
    //
    // Apply layers from lowest to highest priority.  Each opaque pixel
    // overwrites the current winner.  Because this is purely combinational,
    // all paths are evaluated in parallel and the last opaque assignment wins.

    always_comb begin : gate5_colmix
        // Default: transparent output
        final_color = 8'h00;
        final_valid = 1'b0;

        // ── Step 1: BG1 (bottom background, always active) ───────────────────
        if (bg_pix_valid[1] && (bg_pix_color[1] != 8'h00)) begin
            final_color = bg_pix_color[1];
            final_valid = 1'b1;
        end

        // ── Step 2: Sprites with priority=0 (above BG1, below BG0) ──────────
        if (spr_rd_valid && (spr_rd_priority == 2'd0) && (spr_rd_color != 8'h00)) begin
            final_color = spr_rd_color;
            final_valid = 1'b1;
        end

        // ── Step 3: BG0 (foreground, always active) ──────────────────────────
        if (bg_pix_valid[0] && (bg_pix_color[0] != 8'h00)) begin
            final_color = bg_pix_color[0];
            final_valid = 1'b1;
        end

        // ── Step 4: Sprites with priority=1 (above BG0) ──────────────────────
        if (spr_rd_valid && (spr_rd_priority == 2'd1) && (spr_rd_color != 8'h00)) begin
            final_color = spr_rd_color;
            final_valid = 1'b1;
        end

        // ── Step 5: Sprites with priority=2 (above all BG, below prio=3) ─────
        if (spr_rd_valid && (spr_rd_priority == 2'd2) && (spr_rd_color != 8'h00)) begin
            final_color = spr_rd_color;
            final_valid = 1'b1;
        end

        // ── Step 6: Sprites with priority=3 (topmost) ────────────────────────
        if (spr_rd_valid && (spr_rd_priority == 2'd3) && (spr_rd_color != 8'h00)) begin
            final_color = spr_rd_color;
            final_valid = 1'b1;
        end
    end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
