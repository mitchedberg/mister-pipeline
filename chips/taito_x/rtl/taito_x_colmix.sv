`default_nettype none
// =============================================================================
// taito_x_colmix.sv — Taito X Color Mixer / Priority Compositor
// =============================================================================
//
// Resolves per-pixel priority between the background tilemap and the foreground
// sprite layer (X1-001A), then performs palette lookup in the 2048-entry
// xRGB_555 palette BRAM.
//
// Priority (from lowest to highest):
//   1. BG tilemap pixel  — drawn when sprite is transparent
//   2. FG sprite pixel   — from X1-001A; wins whenever pix_valid=1
//
// Priority model:
//   Taito X has a sprite-over-BG model with transparency via pen 0.
//   X1-001A outputs a 9-bit palette index (spr_pix_pal_index[8:0] =
//   {color[4:0], pen[3:0]}) and pix_valid=1 when the pixel is opaque (pen ≠ 0).
//   When pix_valid=0 the BG tile pixel is used.
//
// Palette format: xRGB_555  (from README.md §Core Specifications)
//   bit [15]   = unused (x)
//   bits[14:10] = R[4:0]
//   bits[ 9: 5] = G[4:0]
//   bits[ 4: 0] = B[4:0]
//
// Palette index construction:
//   Sprite pixel:
//     index = {spr_color[4:0], pix_nibble[3:0]}
//     (5-bit palette selector from X1-001A color attribute × 16 pens per palette)
//     Total: 9-bit index (0..511), into 2048-entry table.
//     colorbase (game-specific MAME offset) is applied via the COLOR_BASE parameter.
//
//   BG tile pixel:
//     index = {tile_color[4:0], tile_pen[3:0]}
//     Same construction as sprite, 9-bit into palette table.
//
//   Final 11-bit palette address = COLOR_BASE + 9-bit index.
//   With COLOR_BASE=0 this covers the first 512 entries; games use up to 2048.
//
// Palette BRAM:
//   2048 × 16-bit synchronous BRAM.
//   CPU write port: 68000 writes at 0xB00000–0xB00FFF (2048 words × 16-bit).
//   Pixel read port: 11-bit index; 1-cycle registered read latency.
//
// Output:
//   rgb_r[4:0], rgb_g[4:0], rgb_b[4:0]  — 5-bit per channel, 1 cycle latency.
//   Valid when in_active_display=1 (must be pipelined by caller for 1-cycle delay).
//
// Blanking:
//   When hblank or vblank is asserted the compositor outputs index 0 (palette[0]
//   = border/blank color, matching X1-001A behavior per ARCHITECTURE.md §Video
//   Timing). The 1-cycle palette read latency means the caller must delay sync
//   signals by one cycle relative to rgb output.
//
// Reference:
//   chips/taito_x/section2_x1001a_detail.md §7 (Palette / Color System)
//   chips/taito_x/README.md §Color Palette (2048 entries, xRGB_555)
//   MAME src/devices/video/x1_001.cpp draw_foreground() color computation
// =============================================================================

module taito_x_colmix #(
    // Palette color base offset (game-specific MAME colorbase + colorbase).
    // Added to the 9-bit sprite/tile color index before palette lookup.
    // Default 0: index[10:0] = {2'b0, color[4:0], pen[3:0]}.
    parameter int unsigned COLOR_BASE = 0
) (
    input  logic        clk,
    input  logic        rst_n,

    // ── Active-display / blanking ─────────────────────────────────────────────
    input  logic        hblank,
    input  logic        vblank,

    // ── X1-001A foreground sprite output ─────────────────────────────────────
    // pix_valid=1: sprite pixel is opaque — pen != 0.
    // pix_pal_index[8:0]: full 9-bit palette index = {color[4:0], pen[3:0]}.
    //   [8:4] = 5-bit palette selector from x_pointer[15:11].
    //   [3:0] = 4-bit pen within selected palette (from GFX ROM nibble).
    input  logic        spr_pix_valid,
    input  logic [8:0]  spr_pix_pal_index,  // full 9-bit palette index

    // ── Background tilemap pixel ───────────────────────────────────────────────
    // tile_valid=1: there is an active tilemap pixel at this position.
    // tile_color[4:0]: 5-bit palette selector from spritecode tile color word.
    // tile_pen[3:0]:   4-bit pen from GFX ROM nibble (0 = transparent).
    input  logic        tile_pix_valid,
    input  logic [4:0]  tile_pix_color,
    input  logic [3:0]  tile_pix_pen,

    // ── CPU palette RAM write port ─────────────────────────────────────────────
    // 68000 bus, byte address 0xB00000–0xB00FFF → word address [10:0].
    input  logic        cpu_pal_cs,
    input  logic        cpu_pal_we,
    input  logic [10:0] cpu_pal_addr,   // 11-bit word address (0..2047)
    input  logic [15:0] cpu_pal_din,
    output logic [15:0] cpu_pal_dout,
    input  logic [ 1:0] cpu_pal_be,     // [1]=UDS, [0]=LDS

    // ── RGB output (5-bit per channel, 1-cycle latency from inputs) ───────────
    output logic [4:0]  rgb_r,
    output logic [4:0]  rgb_g,
    output logic [4:0]  rgb_b
);

// =============================================================================
// Palette BRAM — 2048 × 16-bit
// xRGB_555: [15]=x, [14:10]=R, [9:5]=G, [4:0]=B
// =============================================================================

`ifndef QUARTUS
logic [15:0] pal_ram [0:2047];

// CPU write
always_ff @(posedge clk) begin
    if (cpu_pal_cs && cpu_pal_we) begin
        if (cpu_pal_be[1]) pal_ram[cpu_pal_addr][15:8] <= cpu_pal_din[15:8];
        if (cpu_pal_be[0]) pal_ram[cpu_pal_addr][ 7:0] <= cpu_pal_din[ 7:0];
    end
end

// CPU read (registered, 1-cycle latency)
always_ff @(posedge clk) begin
    if (cpu_pal_cs && !cpu_pal_we)
        cpu_pal_dout <= pal_ram[cpu_pal_addr];
    else
        cpu_pal_dout <= 16'hFFFF;
end
`else
// Quartus: infer M10K via altsyncram BIDIR_DUAL_PORT
// Port A: CPU read/write (synchronous, byte-enabled)
// Port B: display pixel read (synchronous, read-only)
logic [15:0] pal_ram_cpu_q;
logic [15:0] pal_ram_pix_q;

altsyncram #(
    .operation_mode         ("BIDIR_DUAL_PORT"),
    .width_a                (16),
    .widthad_a              (11),
    .numwords_a             (2048),
    .width_b                (16),
    .widthad_b              (11),
    .numwords_b             (2048),
    .intended_device_family ("Cyclone V"),
    .lpm_type               ("altsyncram"),
    .ram_block_type         ("M10K"),
    .width_byteena_a        (2),
    .outdata_reg_a          ("CLOCK0"),
    .outdata_reg_b          ("CLOCK0"),
    .address_reg_b          ("CLOCK0"),
    .rdcontrol_reg_b        ("CLOCK0")
) pal_ram_inst (
    // Port A — CPU
    .clock0     (clk),
    .address_a  (cpu_pal_addr[10:0]),
    .data_a     (cpu_pal_din),
    .wren_a     (cpu_pal_cs && cpu_pal_we),
    .byteena_a  (cpu_pal_be),
    .q_a        (pal_ram_cpu_q),
    // Port B — pixel display read (all port B regs on CLOCK0 via address_reg_b)
    .address_b  (win_index[10:0]),
    .data_b     (16'b0),
    .wren_b     (1'b0),
    .byteena_b  (2'b11),
    .q_b        (pal_ram_pix_q)
);

always_ff @(posedge clk) begin
    if (cpu_pal_cs && !cpu_pal_we)
        cpu_pal_dout <= pal_ram_cpu_q;
    else
        cpu_pal_dout <= 16'hFFFF;
end
`endif

// =============================================================================
// Priority resolution (combinational)
// =============================================================================
//
// Winner selection:
//   FG sprite wins when spr_pix_valid=1 (pen != 0 already guaranteed by X1-001A).
//   BG tile wins otherwise, when tile_pix_valid=1 and tile_pix_pen != 0.
//   If neither: use index 0 (palette entry 0 = border / transparent black).

logic [10:0] win_index;    // 11-bit palette index for the winning pixel
logic        in_display;   // 1 when inside active display area

assign in_display = ~hblank & ~vblank;

always_comb begin
    // Default: border color (palette entry 0)
    win_index = 11'd0;

    if (in_display) begin
        if (spr_pix_valid) begin
            // Sprite wins: index = COLOR_BASE + {color[4:0], pen[3:0]}
            win_index = 11'(COLOR_BASE) + 11'(spr_pix_pal_index);
        end else if (tile_pix_valid && (tile_pix_pen != 4'd0)) begin
            // Tile wins: same construction
            win_index = 11'(COLOR_BASE) + 11'({tile_pix_color, tile_pix_pen});
        end
        // else: stays at 0 (border / transparent)
    end
end

// =============================================================================
// Palette lookup (registered, 1-cycle latency)
// =============================================================================

`ifndef QUARTUS
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rgb_r <= 5'd0;
        rgb_g <= 5'd0;
        rgb_b <= 5'd0;
    end else begin
        // xRGB_555: [15]=x, [14:10]=R, [9:5]=G, [4:0]=B
        /* verilator lint_off UNUSED */
        logic [15:0] color;
        /* verilator lint_on UNUSED */
        color = pal_ram[win_index];
        rgb_r <= color[14:10];
        rgb_g <= color[ 9: 5];
        rgb_b <= color[ 4: 0];
    end
end
`else
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rgb_r <= 5'd0;
        rgb_g <= 5'd0;
        rgb_b <= 5'd0;
    end else begin
        // Quartus: palette data arrives from altsyncram port B (pal_ram_pix_q)
        // xRGB_555: [15]=x, [14:10]=R, [9:5]=G, [4:0]=B
        rgb_r <= pal_ram_pix_q[14:10];
        rgb_g <= pal_ram_pix_q[ 9: 5];
        rgb_b <= pal_ram_pix_q[ 4: 0];
    end
end
`endif

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
`ifndef QUARTUS
assign _unused = ^{pal_ram[0][15]};   // bit 15 of each entry is x (unused)
`else
assign _unused = ^{pal_ram_pix_q[15]}; // bit 15 is x (unused); suppress via pix port
`endif
/* verilator lint_on UNUSED */

endmodule
