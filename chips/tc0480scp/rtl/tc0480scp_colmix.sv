`default_nettype none
// =============================================================================
// TC0480SCP — Five-Layer Compositor  (Step 3 stub: text pass-through only)
// =============================================================================
// Composites five layers: BG0–BG3 (added in Steps 4+) and FG0 text (Step 3).
// Text is always topmost. Transparent pen = 0.
//
// Layer priority:
//   BG layers ordered by bg_priority[15:0] (4 nibbles bottom→top).
//   Text always drawn last (always on top).
//
// pixel_out[15:0] format:
//   bits[15:4] = color (8-bit palette bank for BG, 6-bit for text zero-padded)
//   bits[ 3:0] = pen
//   Result = (color << 4) | pen.   All-zero = transparent/background.
//
// Steps added to this module:
//   Step 3: text pass-through only. BG inputs all zero.
//   Step 4: add BG0, BG1.
//   Step 9: add BG2, BG3 + dynamic priority order.
// =============================================================================

module tc0480scp_colmix (
    input  logic        clk,
    input  logic        rst_n,

    // ── Video timing ──────────────────────────────────────────────────────
    input  logic        pixel_active,

    // ── BG layer pixels (Steps 4+; tied to zero until then) ──────────────
    input  logic [ 3:0] bg_pixel [0:3],    // 4-bit pen (0=transparent)
    input  logic [ 7:0] bg_color [0:3],    // 8-bit palette bank
    input  logic        bg_valid [0:3],

    // ── Priority control (Steps 9+) ───────────────────────────────────────
    input  logic [15:0] bg_priority,

    // ── Text layer (Step 3) ───────────────────────────────────────────────
    input  logic [ 3:0] text_pen,          // pen[3:0] from text engine
    input  logic [ 5:0] text_color,        // 6-bit palette bank
    input  logic        text_valid,

    // ── Pixel output ──────────────────────────────────────────────────────
    output logic [15:0] pixel_out,
    output logic        pixel_valid_out
);

// =============================================================================
// Compositor (combinational)
// Priority order: bg_priority nibbles [15:12]=bottom, [3:0]=top BG.
// Text always topmost.
// =============================================================================
always_comb begin
    logic [15:0] result;
    result = 16'h0000;

    // BG layers in priority order (bottom to top)
    // bg_priority nibble 3 (bits[15:12]) = bottom BG index
    // bg_priority nibble 0 (bits[3:0])   = top BG index
    for (int i = 0; i < 4; i++) begin
        automatic int layer;
        layer = int'((bg_priority >> (12 - i*4)) & 4'hF);
        if (bg_valid[layer] && bg_pixel[layer] != 4'h0)
            result = {bg_color[layer], bg_pixel[layer]};
    end

    // Text always topmost
    if (text_valid && text_pen != 4'h0)
        result = {2'b00, text_color, text_pen};

    pixel_out = result;
end

assign pixel_valid_out = pixel_active;

// Suppress unused warnings (bg inputs unused until Step 4)
/* verilator lint_off UNUSED */
logic _unused_colmix;
assign _unused_colmix = ^{rst_n, bg_valid[0], bg_valid[1], bg_valid[2], bg_valid[3]};
/* verilator lint_on UNUSED */

endmodule
