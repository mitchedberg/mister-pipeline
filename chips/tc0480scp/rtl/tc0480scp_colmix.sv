`default_nettype none
// =============================================================================
// TC0480SCP — Five-Layer Compositor  (Step 3: text layer; Step 4: BG0+BG1)
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
// pixel_out is registered (1-cycle latency after linebuf read).
// The testbench capture_pixel does one extra tick after finding hpos/vpos,
// so pixel_out reflects the pixel computed one cycle earlier (linebuf[hpos-1]).
// This matches the expected screen_x offset in the testbench.
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

    // ── Pixel output (registered) ─────────────────────────────────────────
    output logic [15:0] pixel_out,
    output logic        pixel_valid_out
);

// =============================================================================
// Compositor (combinational)
// =============================================================================
logic [15:0] result_c;

always_comb begin
    logic [ 1:0] layer;
    result_c = 16'h0000;

    // BG layers in priority order (bottom to top)
    for (int i = 0; i < 4; i++) begin
        layer = 2'(bg_priority >> (12 - i*4));
        if (bg_valid[layer] && bg_pixel[layer] != 4'h0)
            result_c = {4'b0, bg_color[layer], bg_pixel[layer]};
    end

    // Text always topmost
    if (text_valid && text_pen != 4'h0)
        result_c = {6'b0, text_color, text_pen};
end

// =============================================================================
// Register pixel output (1-cycle latency)
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        pixel_out       <= 16'h0000;
        pixel_valid_out <= 1'b0;
    end else begin
        pixel_out       <= result_c;
        pixel_valid_out <= pixel_active;
    end
end

// Suppress unused warnings (bg inputs unused until Step 4)
/* verilator lint_off UNUSED */
logic _unused_colmix;
assign _unused_colmix = ^{bg_valid[0], bg_valid[1], bg_valid[2], bg_valid[3]};
/* verilator lint_on UNUSED */

endmodule
