`default_nettype none
// =============================================================================
// TC0480SCP — FG0 Text Layer Engine  (Step 3)
// =============================================================================
// 64×64 tile map of 8×8 4bpp tiles uploaded by CPU to VRAM 0xE000–0xFFFF.
// Global scroll only. No zoom, no rowscroll.
// Always composited as the topmost layer.
//
// Tile map VRAM layout (FG0):
//   Word address 0x6000–0x6FFF (byte 0xC000–0xDFFF): 4096 tiles = 64×64 map.
//   Map word address = (tile_row * 64 + tile_col) + 0x6000.
//
// FG0 tile word format (section1 §4.2):
//   bits[15:14] = flipY, flipX
//   bits[13:8]  = color (6-bit palette bank)
//   bits[7:0]   = tile index (0–255, indexes into 256-tile gfx data)
//
// FG0 gfx data VRAM layout (section1 §4.3):
//   Word address 0x7000–0x7FFF (byte 0xE000–0xFFFF): 256 tiles × 32 bytes.
//   Each tile: 8×8 pixels, 4bpp, 32 bytes = 16 × 16-bit words.
//   Row base (word address): tile_idx * 16 + fetch_py * 2  (+ 0x7000 offset).
//   Each row = 2 × 16-bit words = 32 bits total for 8 pixels × 4bpp.
//
//   Pixel layout (section1 §4.3 — same as TC0100SCN):
//     Bit planes: {0,1,2,3} (4bpp interleaved)
//     Column order: {3*4, 2*4, 1*4, 0*4, 7*4, 6*4, 5*4, 4*4} (nibbles reversed per group)
//     As 32-bit row word [b3,b2,b1,b0] where word0[15:0]=b1b0, word1[15:0]=b3b2:
//       px0 → bits[19:16] = b1[3:0]  (x_off=16: nibble index 4 from 32-bit base)
//       px1 → bits[23:20] = b2[7:4]  Wait — need to derive from section1 §4.3 carefully.
//
// Section1 §4.3 exact layout:
//   Columns: {3*4, 2*4, 1*4, 0*4, 7*4, 6*4, 5*4, 4*4}
//   These are BIT offsets: px0=offset 12, px1=offset 8, px2=offset 4, px3=offset 0,
//                           px4=offset 28, px5=offset 24, px6=offset 20, px7=offset 16
//   Each 4bpp pixel at bit_offset b = bits [b+3:b] of the 32-bit row word.
//
//   32-bit row word assembled as: { word1[15:0], word0[15:0] }
//     where word0 = vram[gfx_base + fetch_py*2]
//           word1 = vram[gfx_base + fetch_py*2 + 1]
//
//   Pixel extraction:
//     row32 = {word1, word0}
//     px0 = row32[15:12]   (bit offset 12)
//     px1 = row32[11:8]    (bit offset 8)
//     px2 = row32[ 7: 4]   (bit offset 4)
//     px3 = row32[ 3: 0]   (bit offset 0)
//     px4 = row32[31:28]   (bit offset 28)
//     px5 = row32[27:24]   (bit offset 24)
//     px6 = row32[23:20]   (bit offset 20)
//     px7 = row32[19:16]   (bit offset 16)
//
//   FlipX: reverse px order within tile row.
//   FlipY: use row (7 - fetch_py) instead of fetch_py.
//
// Scroll:
//   text_scrollx / text_scrolly from ctrl regs (words 12–13, raw 16-bit).
//   canvas_x = (hpos + text_scrollx) & 0x1FF   → tile_col = canvas_x >> 3
//   canvas_y = (vpos_next + text_scrolly) & 0x1FF → tile_row = canvas_y >> 3
//
// FSM (HBLANK fill):
//   TL_IDLE → TL_MAP → TL_GFX0 → TL_GFX1 → TL_WRITE → next tile or TL_IDLE
//   5 states × 41 tiles = 205 cycles < 424-cycle HBLANK (plenty of budget).
//   (41 tiles = ceil(320/8) + 1 overlap tile for partial left tile)
//
// VRAM access: both map and gfx data are in the same VRAM array.
//   Use tf_addr/tf_data port for map reads; sc_addr/sc_data for gfx reads.
//   (Step 2: these ports are both registered with 1-cycle latency.)
//
// Output: text_pixel[9:0] = {color[5:0], pen[3:0]}; pen==0 → transparent.
// =============================================================================

module tc0480scp_textlayer (
    input  logic        clk,
    input  logic        rst_n,

    // ── Video timing ──────────────────────────────────────────────────────
    input  logic        hblank,
    input  logic [ 9:0] hpos,
    input  logic [ 8:0] vpos,

    // ── Scroll registers ──────────────────────────────────────────────────
    input  logic [15:0] text_scrollx,
    input  logic [15:0] text_scrolly,

    // ── VRAM tile map read port (tf port) — registered 1-cycle latency ───
    output logic [14:0] vram_map_addr,
    output logic        vram_map_rd,
    input  logic [15:0] vram_map_q,

    // ── VRAM gfx data read port (sc port) — registered 1-cycle latency ──
    // Two reads per tile (word0 + word1 of the pixel row).
    output logic [14:0] vram_gfx_addr,
    output logic        vram_gfx_rd,
    input  logic [15:0] vram_gfx_q,

    // ── Pixel output ──────────────────────────────────────────────────────
    // Format: {color[5:0], pen[3:0]}; pen==0 → transparent.
    output logic [ 9:0] text_pixel
);

// =============================================================================
// HBLANK rising-edge detect (delayed 1 cycle — same as tc0630fdp_bg)
// Fire FSM one cycle AFTER hblank first goes high so that vpos is stable.
// =============================================================================
logic hblank_r, hblank_r2;
always_ff @(posedge clk) begin
    if (!rst_n) begin
        hblank_r  <= 1'b0;
        hblank_r2 <= 1'b0;
    end else begin
        hblank_r  <= hblank;
        hblank_r2 <= hblank_r;
    end
end
logic hblank_rise;
assign hblank_rise = hblank_r & ~hblank_r2;

// =============================================================================
// Fetch geometry: computed combinationally from vpos/scroll, latched at hblank_rise.
// Using combinational canvas_y avoids the 1-cycle stale-register issue where
// two always_ff blocks both trigger on hblank_rise but one reads the other's output.
// =============================================================================
logic [8:0] canvas_y_c;    // combinational canvas Y (used this cycle by hblank_rise)
logic [5:0] fetch_row;     // tile row in 64×64 map (0..63) — latched at hblank_rise
logic [8:0] fetch_xstart;  // first canvas X pixel (for left-edge tile) — latched
logic [2:0] fetch_xoff;    // pixel offset within first tile — latched

// Compute canvas Y combinationally so TL_IDLE can latch run_py_r correctly.
// V_START=16: hblank fires at vpos=15 for screen_y=0 → canvas_y = (15-15+scroll) = scroll.
assign canvas_y_c = (vpos - 9'd15 + text_scrolly[8:0]) & 9'h1FF;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        fetch_row    <= 6'b0;
        fetch_xstart <= 9'b0;
        fetch_xoff   <= 3'b0;
    end else if (hblank_rise) begin
        fetch_row    <= canvas_y_c[8:3];
        fetch_xstart <= text_scrollx[8:0];
        fetch_xoff   <= text_scrollx[2:0];
    end
end

// =============================================================================
// FSM states
// =============================================================================
typedef enum logic [2:0] {
    TL_IDLE  = 3'd0,
    TL_MAP   = 3'd1,   // issue map read; wait 1 cycle (registered VRAM)
    TL_WAIT  = 3'd2,   // latch map result; issue gfx word0 read
    TL_GFX0  = 3'd3,   // wait for gfx word0; issue word1 read
    TL_GFX1  = 3'd4,   // wait for gfx word1; latch both; write pixels
    TL_WRITE = 3'd5    // write pixels to linebuf; advance
} tl_state_t;

tl_state_t  state;
logic [5:0] tile_slot;    // tile slot 0..40 (41 tiles covers 320+7 pixels)
logic [5:0] run_tile_col; // current map tile column (0..63)

// Tile attribute registers (latched in TL_WAIT)
logic [5:0] tile_color_r;
logic       tile_flipx_r;
logic       tile_flipy_r;

// GFX word latches
logic [15:0] gfx_w0_r;   // first word of the tile pixel row
// gfx word1 is read directly from vram_gfx_q in TL_WRITE (no latch needed)

// GFX base address for the current tile (computed in TL_WAIT)
logic [14:0] gfx_base_r; // = 0x7000 + tile_idx * 16 + fetch_py_r * 2
logic [2:0]  run_py_r;   // snapshotted fetch_py for flipY

// =============================================================================
// VRAM address outputs (combinational, state-driven)
// =============================================================================
// Map address: 0x6000 + (fetch_row * 64 + run_tile_col) = word 0x6000–0x6FFF
// Gfx address: 0x7000 + tile_idx * 16 + py * 2 + word_sel

logic [14:0] map_addr_c;
logic [14:0] gfx0_addr_c;  // gfx row word 0
logic [14:0] gfx1_addr_c;  // gfx row word 1
logic [ 2:0] gfx_ry_c;     // flipY-adjusted row index

always_comb begin
    map_addr_c  = 15'h6000 + {3'b0, fetch_row, run_tile_col};
    // flipY applied to row index
    gfx_ry_c    = tile_flipy_r ? (3'd7 - run_py_r) : run_py_r;
    gfx0_addr_c = 15'(gfx_base_r + {12'b0, gfx_ry_c, 1'b0});
    gfx1_addr_c = 15'(gfx_base_r + {12'b0, gfx_ry_c, 1'b0} + 15'd1);
end

always_comb begin
    vram_map_rd   = 1'b0;
    vram_map_addr = 15'b0;
    vram_gfx_rd   = 1'b0;
    vram_gfx_addr = 15'b0;
    unique case (state)
        TL_MAP:  begin vram_map_addr = map_addr_c;  vram_map_rd  = 1'b1; end
        TL_GFX0: begin vram_gfx_addr = gfx0_addr_c; vram_gfx_rd = 1'b1; end
        TL_GFX1: begin vram_gfx_addr = gfx1_addr_c; vram_gfx_rd = 1'b1; end
        default: begin end
    endcase
end

// =============================================================================
// Line buffer: 320 × 10-bit {color[5:0], pen[3:0]}
// =============================================================================
`ifdef QUARTUS
(* ramstyle = "MLAB" *) logic [9:0] linebuf [0:319];
`else
logic [9:0] linebuf [0:319];
`endif

// Output: screen column from hpos (active area starts at hpos=0)
logic [8:0] scol;
always_comb begin
    if (hpos < 10'd320)
        scol = hpos[8:0];
    else
        scol = 9'd0;
end
assign text_pixel = linebuf[scol];

// =============================================================================
// FSM
// =============================================================================
always_ff @(posedge clk) begin
    if (!rst_n) begin
        state         <= TL_IDLE;
        tile_slot     <= 6'b0;
        run_tile_col  <= 6'b0;
        tile_color_r  <= 6'b0;
        tile_flipx_r  <= 1'b0;
        tile_flipy_r  <= 1'b0;
        gfx_w0_r      <= 16'b0;
        gfx_base_r    <= 15'b0;
        run_py_r      <= 3'b0;
    end else begin
        unique case (state)

            TL_IDLE: begin
                if (hblank_rise) begin
                    tile_slot    <= 6'd0;
                    // First tile column: canvas_x at output pixel 0 >> 3
                    run_tile_col <= fetch_xstart[8:3] & 6'h3F;
                    // Use canvas_y_c directly (combinational) — fetch_py updates on
                    // the same posedge, so reading fetch_py here would get the stale value.
                    run_py_r     <= canvas_y_c[2:0];
                    state        <= TL_MAP;
                end
            end

            // Issue map read (registered → result available next cycle in TL_WAIT)
            TL_MAP: begin
                state <= TL_WAIT;
            end

            // Latch map result; set up gfx address; issue gfx word0 read
            TL_WAIT: begin
                // vram_map_q is registered result of TL_MAP cycle address
                tile_color_r  <= vram_map_q[13:8];
                tile_flipx_r  <= vram_map_q[14];
                tile_flipy_r  <= vram_map_q[15];
                // Gfx base: 0x7000 + tile_idx * 16 (each tile = 16 words = 8 rows × 2)
                gfx_base_r    <= 15'h7000 + {3'b0, vram_map_q[7:0], 4'b0};
                state         <= TL_GFX0;
            end

            // Issue gfx word0 read; no latch yet (result available next cycle in TL_GFX1)
            TL_GFX0: begin
                state <= TL_GFX1;
            end

            // Latch gfx word0 (result of TL_GFX0 addr); issue gfx word1 read
            TL_GFX1: begin
                gfx_w0_r <= vram_gfx_q;  // sc_data = result of TL_GFX0's read = word0
                state    <= TL_WRITE;
            end

            // Write 8 pixels; advance tile slot
            TL_WRITE: begin
                begin
                    // row32 = {gfx_w1_r, gfx_w0_r} (gfx word1 is MS, word0 is LS)
                    // Pixel layout (section1 §4.3):
                    //   px0 = row32[15:12], px1=row32[11:8], px2=row32[7:4], px3=row32[3:0]
                    //   px4 = row32[31:28], px5=row32[27:24], px6=row32[23:20], px7=row32[19:16]
                    // (Already latched flipY into gfx address. FlipX reverses px order.)
                    logic [31:0] row32;
                    logic [3:0]  raw_px [0:7];
                    logic [3:0]  px     [0:7];

                    row32 = {vram_gfx_q, gfx_w0_r};
                    // Extract raw pixels in canonical order
                    raw_px[0] = row32[15:12];
                    raw_px[1] = row32[11: 8];
                    raw_px[2] = row32[ 7: 4];
                    raw_px[3] = row32[ 3: 0];
                    raw_px[4] = row32[31:28];
                    raw_px[5] = row32[27:24];
                    raw_px[6] = row32[23:20];
                    raw_px[7] = row32[19:16];

                    // Apply flipX: if set, reverse the order
                    for (int p = 0; p < 8; p++) begin
                        px[p] = tile_flipx_r ? raw_px[7-p] : raw_px[p];
                    end

                    // Write to linebuf at the correct screen column.
                    // tile_slot 0: columns 0..7 starting at -(fetch_xoff) (may be negative)
                    // tile_slot k: columns (k*8 - fetch_xoff) .. (k*8 - fetch_xoff + 7)
                    for (int p = 0; p < 8; p++) begin
                        automatic int scol_int;
                        scol_int = (int'(tile_slot) * 8) + p - int'(fetch_xoff);
                        if (scol_int >= 0 && scol_int < 320)
                            linebuf[scol_int] <= {tile_color_r, px[p]};
                    end
                end

                // Advance to next tile
                if (tile_slot == 6'd40) begin
                    state <= TL_IDLE;
                end else begin
                    tile_slot    <= tile_slot + 6'd1;
                    run_tile_col <= (run_tile_col + 6'd1) & 6'h3F;
                    state        <= TL_MAP;
                end
            end

            default: state <= TL_IDLE;
        endcase
    end
end

// =============================================================================
// Suppress unused warnings
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused_tl;
assign _unused_tl = ^{hblank_r2, fetch_xstart[2:0],
                      text_scrollx[15:9], text_scrolly[15:9]};
/* verilator lint_on UNUSED */

endmodule
