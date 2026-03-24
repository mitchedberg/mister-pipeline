// =============================================================================
// gp9001_priority_mix.sv — Dual GP9001 Inter-VDP Priority Mixer
// =============================================================================
//
// Used by Batsugun, Dogyuun, V-Five, Knuckle Bash, Snow Bros 2 — all games on
// the Toaplan V2 board that carry two GP9001 VDP chips.
//
// Hardware context (from MAME toaplan/batsugun.cpp, gp9001.cpp):
//
//   Each GP9001 produces an 8-layer pixel stream:
//     - 4 BG tilemap layers (BG0..BG3) with per-pixel priority bits
//     - 1 sprite layer with per-pixel priority bit
//   GP9001 internal priority mixer (Gate 5) selects the winning pixel from
//   its own 5 layers and emits:
//     final_color[7:0]  — 8-bit palette index {palette[3:0], color_idx[3:0]}
//     final_valid       — opaque pixel present
//
//   When two GP9001s are cascaded, a second priority stage arbitrates between
//   the two VDPs.  The priority value exposed per chip is stored in the
//   internal LAYER_CTRL register bits [14:11] of the winning pixel.
//
//   Arbitration rule (from hardware analysis, matches atrac17/Toaplan2):
//     1. If exactly one VDP has a valid pixel, it wins unconditionally.
//     2. If both VDPs have valid pixels, compare 4-bit priority fields:
//        higher numeric value wins.
//     3. On a tie, VDP#0 wins (it is the "front" chip in hardware).
//     4. If neither VDP has a valid pixel, output transparent (final_valid=0).
//
//   Priority field source:
//     Each GP9001 Gate-5 winner carries the priority nibble of the winning
//     internal layer. The priority nibble is bits [3:0] of the layer's
//     attribute word where the GP9001 encodes priority as a 4-bit value
//     derived from LAYER_CTRL register (see gp9001.sv Gate-5 comment).
//
//   For the external mixer we use the per-layer pixel outputs exposed on the
//   gp9001 module ports rather than just final_color, because the Gate-5
//   internal mixer in gp9001.sv does not expose the winning priority nibble
//   as a separate signal.  Instead, we reconstruct the full priority-sorted
//   8-layer competition directly in this module using the individual BG and
//   sprite pixel ports that each GP9001 exposes.
//
// Port design:
//   This module takes the raw per-layer outputs of two GP9001 instances and
//   runs the full 8-layer priority tournament (4 BG + sprite from each VDP).
//   Output is the winning 8-bit palette index for lookup in the shared palette
//   RAM, plus a valid flag.
//
// Priority encoding (from COMMUNITY_PATTERNS.md §7 and gp9001.sv header):
//   "pixel format in line buffers: [14:11]=priority, [10:4]=palette, [3:0]=color"
//   Internal per-layer priority nibble is the bg_pix_priority bit from each
//   BG layer OR the spr_rd_priority bit for the sprite layer.
//
//   In this external mixer we use a richer scheme: for each layer we assign a
//   5-bit composite key = {vdp_idx[0], priority_4bit[3:0]} where vdp_idx=0
//   means VDP#0.  That gives VDP#0 the tiebreaker at every priority level.
//
//   The 8 layers are:
//     Slot 0: VDP0 sprite   — priority from spr_rd_priority0 (1-bit, mapped to 4'hF or 4'h0)
//     Slot 1: VDP0 BG0      — priority from bg0_prio0 (1-bit, mapped similarly)
//     Slot 2: VDP0 BG1      — priority from bg1_prio0
//     Slot 3: VDP0 BG2      — priority from bg2_prio0
//     Slot 4: VDP1 sprite   — priority from spr_rd_priority1
//     Slot 5: VDP1 BG0      — priority from bg0_prio1
//     Slot 6: VDP1 BG1      — priority from bg1_prio1
//     Slot 7: VDP1 BG2      — priority from bg2_prio1
//
//   Standard Toaplan layer ordering (highest priority first):
//     sprite_above_all > BG0 > sprite_below_bg0 > BG1 > BG2 > BG3 > transparent
//
//   We model this with a 4-bit priority value per layer derived from the
//   priority bit: prio_bit=1 → value 4'hF, prio_bit=0 → value 4'h7.
//   Sprites with prio_bit=1 beat all BG layers; sprites with prio_bit=0 sit
//   between BG0 and BG1.  BG layers use descending fixed values 4'hE..4'hC.
//
// Synthesis notes:
//   - Fully combinational — no registered state
//   - Instantiated by toaplan_v2.sv when DUAL_VDP=1
//   - Does NOT replace the GP9001 internal Gate-5 mixer; each GP9001 still
//     runs its own Gate-5.  This module is an ADDITIONAL outer stage.
//   - When DUAL_VDP=0, toaplan_v2.sv bypasses this module and uses the
//     single GP9001's final_color / final_valid directly.
//
// ALM budget:
//   8-way priority comparator tree ≈ 20-30 ALMs (Cyclone V 4-LUT).
//   Negligible compared to GP9001 instance cost (~12K ALMs each).
//
// =============================================================================
`default_nettype none

module gp9001_priority_mix (
    // ── VDP#0 pixel inputs (from gp9001 u_gp9001_0 Gate-3/4 outputs) ─────────

    // BG layer pixel outputs — valid[i] asserted when layer i has an opaque pixel
    // color[i] is 8-bit {palette[3:0], index[3:0]}
    // priority_bit[i] is the per-layer priority bit from LAYER_CTRL
    input  logic [3:0]       vdp0_bg_valid,      // one bit per BG layer (4 max)
    input  logic [3:0][7:0]  vdp0_bg_color,      // 8-bit color per BG layer
    input  logic [3:0]       vdp0_bg_prio,       // priority bit per BG layer

    // Sprite layer pixel (from Gate-4 scanline buffer read-back)
    input  logic             vdp0_spr_valid,
    input  logic [7:0]       vdp0_spr_color,
    input  logic             vdp0_spr_prio,      // 1 = sprite above all BG

    // ── VDP#1 pixel inputs (from gp9001 u_gp9001_1 Gate-3/4 outputs) ─────────

    input  logic [3:0]       vdp1_bg_valid,
    input  logic [3:0][7:0]  vdp1_bg_color,
    input  logic [3:0]       vdp1_bg_prio,

    input  logic             vdp1_spr_valid,
    input  logic [7:0]       vdp1_spr_color,
    input  logic             vdp1_spr_prio,

    // ── Output — winning pixel for palette RAM lookup ─────────────────────────
    output logic [7:0]       final_color,        // 8-bit palette index
    output logic             final_valid         // 1 = at least one opaque pixel
);

// =============================================================================
// Priority assignment
// =============================================================================
//
// We assign each of the 8 candidate layers a 5-bit priority key:
//   key[4]   = VDP index (0 = VDP#0, 1 = VDP#1)
//              Used as the LOW bit of the comparator so that when two layers
//              have identical priority fields, VDP#0 wins (lower key[4]).
//   key[3:0] = 4-bit priority value derived from the layer's priority bit
//              and its layer type:
//
//   Priority mapping (matching hardware-observed layer ordering):
//     Sprite with prio_bit=1  → 4'hF  (highest)
//     BG0                     → 4'hE
//     BG1                     → 4'hC
//     Sprite with prio_bit=0  → 4'hA  (between BG1 and BG2)
//     BG2                     → 4'h8
//     BG3                     → 4'h6  (lowest tilemap layer)
//
//   With VDP index as the tiebreaker low bit, the final comparison key is:
//     key = {prio_4bit, vdp_idx}
//   A HIGHER key value wins (combinational max-tree).
//
// The winner among valid layers is selected by iterating all 8 candidates and
// tracking the running maximum key.

// ─── Candidate struct (combinational, not synthesized as struct) ──────────────
// Each candidate is described by: valid, key[4:0], color[7:0]

// Layer indices
//  0: vdp0_spr
//  1: vdp0_bg[0]
//  2: vdp0_bg[1]
//  3: vdp0_bg[2]
//  4: vdp0_bg[3]
//  5: vdp1_spr
//  6: vdp1_bg[0]
//  7: vdp1_bg[1]
//  8: vdp1_bg[2]
//  9: vdp1_bg[3]
// Total: 10 candidates

localparam int NUM_CAND = 10;

// ─── Priority key computation (combinational function) ────────────────────────
// For VDP#0 layers, vdp_idx_bit = 0  → key = {prio_4bit, 1'b0}
// For VDP#1 layers, vdp_idx_bit = 1  → key = {prio_4bit, 1'b1}
// Max key wins. On equal prio_4bit, VDP#0 (key LSB=0) < VDP#1 (key LSB=1)...
//
// Wait — we want VDP#0 to WIN on ties. Since we track the MAXIMUM key, a LOWER
// key value for VDP#0 means it loses ties. We must invert the VDP index bit:
//   vdp_idx_bit = 0 for VDP#0 → use key LSB = 1'b1 (wins ties)
//   vdp_idx_bit = 1 for VDP#1 → use key LSB = 1'b0 (loses ties)
// This ensures: same prio → VDP#0 key = {..., 1} > VDP#1 key = {..., 0}.

function automatic logic [4:0] make_key;
    input logic       is_sprite;
    input logic       prio_bit;   // layer priority bit from LAYER_CTRL / sprite word
    input logic       layer_idx;  // 2-bit layer index within the VDP (BG0=0..BG3=3, ignored for spr)
    input logic [1:0] bg_idx;     // BG layer index 0..3 (only used when is_sprite=0)
    input logic       vdp_tiebreak; // 1 = VDP#0 (wins ties), 0 = VDP#1
    logic [3:0] p4;
    begin
        if (is_sprite) begin
            // Sprite: prio_bit=1 → front-of-all (4'hF), prio_bit=0 → mid-stack (4'hA)
            p4 = prio_bit ? 4'hF : 4'hA;
        end else begin
            // BG layer: each layer has a fixed base priority, modulated by prio_bit
            // BG0 base = 4'hE, BG1 base = 4'hC, BG2 base = 4'h8, BG3 base = 4'h6
            // prio_bit=1 raises by 1, prio_bit=0 leaves at base
            case (bg_idx)
                2'd0: p4 = prio_bit ? 4'hF : 4'hE;  // BG0: 0xE or 0xF (may compete with spr)
                2'd1: p4 = prio_bit ? 4'hD : 4'hC;  // BG1: 0xC or 0xD
                2'd2: p4 = prio_bit ? 4'h9 : 4'h8;  // BG2: 0x8 or 0x9
                2'd3: p4 = prio_bit ? 4'h7 : 4'h6;  // BG3: 0x6 or 0x7 (lowest)
            endcase
        end
        make_key = {p4, vdp_tiebreak};
    end
endfunction

// ─── Build candidate arrays ───────────────────────────────────────────────────

logic [NUM_CAND-1:0]       cand_valid;
logic [NUM_CAND-1:0][4:0]  cand_key;
logic [NUM_CAND-1:0][7:0]  cand_color;

always_comb begin : build_candidates
    // VDP#0 sprite (candidate 0)
    cand_valid[0] = vdp0_spr_valid;
    cand_key  [0] = make_key(1'b1, vdp0_spr_prio, 1'b0, 2'b00, 1'b1); // vdp0=tiebreak=1
    cand_color[0] = vdp0_spr_color;

    // VDP#0 BG0 (candidate 1)
    cand_valid[1] = vdp0_bg_valid[0];
    cand_key  [1] = make_key(1'b0, vdp0_bg_prio[0], 1'b0, 2'd0, 1'b1);
    cand_color[1] = vdp0_bg_color[0];

    // VDP#0 BG1 (candidate 2)
    cand_valid[2] = vdp0_bg_valid[1];
    cand_key  [2] = make_key(1'b0, vdp0_bg_prio[1], 1'b0, 2'd1, 1'b1);
    cand_color[2] = vdp0_bg_color[1];

    // VDP#0 BG2 (candidate 3)
    cand_valid[3] = vdp0_bg_valid[2];
    cand_key  [3] = make_key(1'b0, vdp0_bg_prio[2], 1'b0, 2'd2, 1'b1);
    cand_color[3] = vdp0_bg_color[2];

    // VDP#0 BG3 (candidate 4)
    cand_valid[4] = vdp0_bg_valid[3];
    cand_key  [4] = make_key(1'b0, vdp0_bg_prio[3], 1'b0, 2'd3, 1'b1);
    cand_color[4] = vdp0_bg_color[3];

    // VDP#1 sprite (candidate 5)
    cand_valid[5] = vdp1_spr_valid;
    cand_key  [5] = make_key(1'b1, vdp1_spr_prio, 1'b0, 2'b00, 1'b0); // vdp1=tiebreak=0
    cand_color[5] = vdp1_spr_color;

    // VDP#1 BG0 (candidate 6)
    cand_valid[6] = vdp1_bg_valid[0];
    cand_key  [6] = make_key(1'b0, vdp1_bg_prio[0], 1'b0, 2'd0, 1'b0);
    cand_color[6] = vdp1_bg_color[0];

    // VDP#1 BG1 (candidate 7)
    cand_valid[7] = vdp1_bg_valid[1];
    cand_key  [7] = make_key(1'b0, vdp1_bg_prio[1], 1'b0, 2'd1, 1'b0);
    cand_color[7] = vdp1_bg_color[1];

    // VDP#1 BG2 (candidate 8)
    cand_valid[8] = vdp1_bg_valid[2];
    cand_key  [8] = make_key(1'b0, vdp1_bg_prio[2], 1'b0, 2'd2, 1'b0);
    cand_color[8] = vdp1_bg_color[2];

    // VDP#1 BG3 (candidate 9)
    cand_valid[9] = vdp1_bg_valid[3];
    cand_key  [9] = make_key(1'b0, vdp1_bg_prio[3], 1'b0, 2'd3, 1'b0);
    cand_color[9] = vdp1_bg_color[3];
end

// =============================================================================
// Priority tournament — combinational max-key selection
// =============================================================================
//
// Linear scan over all 10 candidates.  Each step keeps the running winner if
// it has a higher or equal key (higher key wins; equal key already resolved by
// tiebreaker bit).  Only valid candidates participate.
//
// Implements: winner = argmax over {i : cand_valid[i]} of cand_key[i]

logic [4:0] best_key;
logic [7:0] best_color;
logic       best_valid;

always_comb begin : priority_tournament
    best_key   = 5'd0;
    best_color = 8'd0;
    best_valid = 1'b0;

    for (int i = 0; i < NUM_CAND; i++) begin
        if (cand_valid[i]) begin
            if (!best_valid || (cand_key[i] > best_key)) begin
                best_key   = cand_key[i];
                best_color = cand_color[i];
                best_valid = 1'b1;
            end
        end
    end
end

assign final_color = best_color;
assign final_valid = best_valid;

endmodule
`default_nettype wire
