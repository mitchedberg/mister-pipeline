`default_nettype none
// =============================================================================
// taito_z_compositor.sv — Taito Z Priority Compositor
// =============================================================================
//
// Resolves per-pixel priority across three sources and outputs a 12-bit
// palette index to the palette RAM lookup.
//
// Sources (bottom to top):
//   1. TC0480SCP  — BG0–BG3 + text (5 layers, already composited internally)
//   2. TC0150ROD  — Road layer (per-scanline fill, between BG2 and sprites)
//   3. TC0370MSO  — Sprites (priority 0 = above road, priority 1 = below road)
//
// Priority rules derived from MAME screen_update_dblaxle / screen_update_racingb:
//
//   Step 1: Start with TC0480SCP tile output (BG0–BG3 + text composite).
//           SCP pixel is always the base — it is opaque (TILEMAP_DRAW_OPAQUE
//           at BG0 means there is always a background pixel from SCP).
//
//   Step 2: Road (TC0150ROD) — draws over the SCP base when pix_transp=0.
//           Road is between BG2 and BG3/text in the real hardware, but since
//           TC0480SCP composites all BG layers internally we treat road as
//           drawing over the full SCP output. This is a known limitation when
//           BG3/text does not export per-layer priority; it matches the
//           visual result in the common case where BG3 tiles are sparse.
//
//   Step 3: Sprites below road (pix_priority=1, primask=0xfc in MAME).
//           Draws over SCP only when road is transparent at this pixel.
//           If road is visible, road takes precedence over below-road sprites.
//
//   Step 4: Sprites above road (pix_priority=0, primask=0xf0 in MAME).
//           Draws over both road and SCP.
//
// Note: BG3 and text are hardest to prioritize correctly without per-layer
// pixel feeds from TC0480SCP. Current implementation composites them as part
// of the SCP output (they appear above road and sprites). A future enhancement
// could split them using an additional TC0480SCP priority output port.
//
// Inputs/outputs are all in the pixel-clock domain (clk_pix).
// The compositor is purely combinational — all registered outputs are in
// the consumer (palette module).
//
// Reference: MAME src/mame/taito/taito_z_v.cpp screen_update_dblaxle
//            chips/tc0370mso/section1_registers.md §7 (Priority System)
//            chips/taito_z/integration_plan.md §11 (Priority Mixing)
// =============================================================================

module taito_z_compositor (
    // ── TC0480SCP output (BG0–BG3 + text, composited) ───────────────────────
    // pixel_out[15:0]: {4'b0, color_bank[7:0], pen[3:0]}
    // palette_index = pixel_out[11:0]  (color_bank<<4 | pen)
    input  logic [15:0] scp_pixel_out,
    input  logic        scp_pixel_valid,

    // ── TC0150ROD road output ─────────────────────────────────────────────────
    // pix_out[14:0]: road palette index (15-bit, only [11:0] used for lookup)
    // pix_transp=1 → transparent (road not visible here)
    input  logic [14:0] rod_pix_out,
    input  logic        rod_pix_valid,
    input  logic        rod_pix_transp,

    // ── TC0370MSO sprite output ───────────────────────────────────────────────
    // pix_out[11:0]: sprite palette index (0=transparent per TC0370MSO logic)
    // pix_priority: 0 = above road, 1 = below road
    input  logic [11:0] mso_pix_out,
    input  logic        mso_pix_valid,
    input  logic        mso_pix_priority,

    // ── Compositor output ─────────────────────────────────────────────────────
    output logic [11:0] comp_pix_index,  // 12-bit palette index → palette RAM
    output logic        comp_pix_valid   // pixel valid (same as scp_pixel_valid)
);

// =============================================================================
// Priority resolution (combinational)
// =============================================================================
//
// Priority from lowest to highest:
//   SCP (base, always present when scp_pixel_valid)
//   Road (when not transparent) — overwrites SCP base
//   Sprites prio=1 (below road) — overwrites SCP if road transparent
//   Sprites prio=0 (above road) — overwrites everything
//
// Implementation: start with lowest priority layer and overwrite upward.

/* verilator lint_off UNUSED */
logic _unused_comp;
assign _unused_comp = ^{scp_pixel_out[15:12], rod_pix_out[14:12]};
/* verilator lint_on UNUSED */

always_comb begin
    // Default: transparent/background (index 0)
    comp_pix_index = 12'd0;
    comp_pix_valid = 1'b0;

    if (scp_pixel_valid) begin
        comp_pix_valid = 1'b1;

        // Layer 1 (base): SCP tile output — bits [11:0] are the palette index
        comp_pix_index = scp_pixel_out[11:0];

        // Layer 2: Road — draws over SCP when not transparent
        if (rod_pix_valid && !rod_pix_transp)
            comp_pix_index = rod_pix_out[11:0];

        // Layer 3: Sprites below road (prio=1)
        // Only visible where road is transparent; road already won above,
        // so check road transparency condition here.
        if (mso_pix_valid && mso_pix_priority == 1'b1) begin
            if (!rod_pix_valid || rod_pix_transp)
                comp_pix_index = mso_pix_out[11:0];
        end

        // Layer 4: Sprites above road (prio=0) — always on top of road+SCP
        if (mso_pix_valid && mso_pix_priority == 1'b0)
            comp_pix_index = mso_pix_out[11:0];
    end
end

endmodule
