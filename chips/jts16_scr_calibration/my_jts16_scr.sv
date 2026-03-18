// my_jts16_scr.sv — Sega System 16 scroll layer engine
// Written from scratch based on MAME hardware description (segaic16.cpp).
// NO REFERENCE to jotego's jts16_scr.v during authorship.
// Purpose: calibration diff against jts16_scr.v to build pattern ledger.
//
// Hardware: Sega 315-5197 (S16B) / 315-5049 (S16A) scroll plane logic.
// Two instances per game: SCR1 (foreground) + SCR2 (background).
//
// Scroll register layout (S16B):
//   hscr[15:0] = horizontal scroll (pixel offset, applied to hdump)
//   vscr[15:0] = vertical scroll (pixel offset, applied to vrender)
//   col_scroll_en = bit 15 of hscr => per-column vertical scroll mode
//   row_scroll_en = bit 15 of vscr => per-row horizontal scroll mode
//
// Tile map:
//   64 columns × 32 rows per page, 16 pages, 8×8 tiles = 512×256 logical surface
//   Tile map word [S16B]: [15]=priority, [14:6]=palette (9b but only 7 used), [12:0]=tile_index
//   Tile graphics: 8×8 pixels, 4bpp packed. 8 bytes per row × 8 rows = 64 bytes per tile.
//
// SDRAM interface model (same as jotego jtframe pattern):
//   Tile map fetch: addr driven N cycles before data needed; ok pulsed when data valid.
//   Graphics fetch: same.
//
// Pipeline stages:
//   T0: compute tilemap address from (hdump+hscr, vrender+vscr)
//   T1: tilemap SDRAM request issued
//   T2-T3: tilemap SDRAM latency
//   T4: tilemap data arrives; decode tile_index, palette, priority
//         compute tile graphics address
//   T5: graphics SDRAM request issued
//   T6-T7: graphics SDRAM latency
//   T8: graphics data arrives; select pixel column bits
//   T9: output pixel

`default_nettype none

module my_jts16_scr #(
    parameter MODEL = 1   // 0 = S16A, 1 = S16B
) (
    input  wire        clk,
    input  wire        pxl_cen,     // pixel clock enable (≈6.25 MHz)
    input  wire        rst,

    // Video timing
    input  wire  [8:0] hdump,       // horizontal dot counter 0–339 (active 0–319)
    input  wire  [8:0] vrender,     // scanline being rendered (one line ahead)
    input  wire        hstart,      // pulses at start of each line
    input  wire        vs,          // vertical sync

    // Scroll registers
    input  wire [15:0] hscr,        // horizontal scroll (pixels)
    input  wire [15:0] vscr,        // vertical scroll (pixels)

    // Per-row horizontal scroll table (row_scroll_en mode)
    // Index = vrender[7:0], data = h-scroll override for that row
    input  wire [15:0] rowscr_data, // row scroll value read from text RAM
    input  wire        row_scroll_en,

    // Per-column vertical scroll table (col_scroll_en mode)
    input  wire [15:0] colscr_data, // col scroll value for current hdump column
    input  wire        col_scroll_en,

    // Tile map SDRAM port
    output reg  [14:0] map_addr,    // word address into tilemap VRAM
    input  wire [15:0] map_data,
    input  wire        map_ok,

    // Tile graphics SDRAM port
    output reg  [17:0] scr_addr,    // byte address into SCR tile ROM/RAM
    input  wire [31:0] scr_data,    // 32 bits = 4 rows × 8 pixels × 4bpp = 2 rows
    input  wire        scr_ok,

    // Output pixel
    output reg   [3:0] pxl_color,   // 4-bit color within palette
    output reg   [6:0] pxl_pal,     // 7-bit palette index
    output reg         pxl_prio,    // priority flag
    output reg         pxl_valid    // transparent = color[2:0] == 0
);

// ─────────────────────────────────────────────────────────
// Effective scroll coordinates
// ─────────────────────────────────────────────────────────
wire [9:0] eff_hscr = row_scroll_en ? rowscr_data[9:0] : hscr[9:0];
wire [9:0] eff_vscr = col_scroll_en ? colscr_data[9:0] : vscr[9:0];

// ─────────────────────────────────────────────────────────
// Pixel coordinates in scroll-space
// Tile map is 512 wide × 256 tall (modulo)
// ─────────────────────────────────────────────────────────
wire [9:0] sx = hdump[8:0] + eff_hscr;       // horizontal pixel in scroll plane
wire [8:0] sy = vrender[8:0] + eff_vscr[8:0]; // vertical pixel in scroll plane

wire [5:0] tile_col  = sx[9:3];   // which tile column (0-63)
wire [4:0] tile_row  = sy[7:3];   // which tile row (0-31)
wire [2:0] tile_px_x = sx[2:0];   // pixel within tile, X
wire [2:0] tile_px_y = sy[2:0];   // pixel within tile, Y

// ─────────────────────────────────────────────────────────
// Stage 1: Tile map address
// Map layout: 64 cols × 32 rows, word-addressed
// Address = tile_row * 64 + tile_col (within selected page)
// ─────────────────────────────────────────────────────────
always @(posedge clk) begin
    if (pxl_cen) begin
        // Issue tile map read; 15-bit word address
        // bits[14:11] = page select (from mmr), using vscr[15:12] as page hint
        // For calibration simplicity: page from upper vscr bits
        map_addr <= { vscr[15:12], 1'b0, tile_row, tile_col };
    end
end

// ─────────────────────────────────────────────────────────
// Stage 2: Tile map data decode (after SDRAM returns)
// ─────────────────────────────────────────────────────────
reg  [12:0] tile_index;
reg  [6:0]  tile_palette;
reg         tile_prio;
reg  [2:0]  latch_px_x;
reg  [2:0]  latch_px_y;

always @(posedge clk) begin
    if (pxl_cen && map_ok) begin
        if (MODEL == 1) begin  // S16B
            tile_index   <= map_data[12:0];
            tile_palette <= map_data[12:6];   // 7 bits
            tile_prio    <= map_data[15];
        end else begin          // S16A
            // S16A: 12-bit index with bank bit in bit 12
            tile_index   <= { map_data[12], map_data[11:0] };
            tile_palette <= { 1'b0, map_data[11:5] };
            tile_prio    <= map_data[15];
        end
        latch_px_x <= tile_px_x;
        latch_px_y <= tile_px_y;
    end
end

// ─────────────────────────────────────────────────────────
// Stage 3: Tile graphics address
// 8×8 tile, 4bpp, 4 bytes per row (8 pixels × 4bpp = 32 bits = 4 bytes)
// Byte address = tile_index * 32 + tile_px_y * 4
// We fetch 4 bytes (one full row) per access; select column nibble in stage 4
// ─────────────────────────────────────────────────────────
always @(posedge clk) begin
    if (pxl_cen && map_ok) begin
        scr_addr <= { tile_index, latch_px_y, 2'b00 };  // 18-bit byte addr
    end
end

// ─────────────────────────────────────────────────────────
// Stage 4: Pixel extraction from graphics data
// scr_data[31:0] = 8 pixels × 4bpp, packed as nibbles
// pixel 0 = scr_data[31:28], pixel 7 = scr_data[3:0]
// ─────────────────────────────────────────────────────────
reg [3:0] raw_pixel;
reg [6:0] r_palette;
reg       r_prio;

always @(posedge clk) begin
    if (pxl_cen && scr_ok) begin
        // Select nibble based on pixel X
        case (latch_px_x)
            3'd0: raw_pixel <= scr_data[31:28];
            3'd1: raw_pixel <= scr_data[27:24];
            3'd2: raw_pixel <= scr_data[23:20];
            3'd3: raw_pixel <= scr_data[19:16];
            3'd4: raw_pixel <= scr_data[15:12];
            3'd5: raw_pixel <= scr_data[11: 8];
            3'd6: raw_pixel <= scr_data[ 7: 4];
            3'd7: raw_pixel <= scr_data[ 3: 0];
        endcase
        r_palette <= tile_palette;
        r_prio    <= tile_prio;
    end
end

// ─────────────────────────────────────────────────────────
// Output
// Transparency: color bits [2:0] == 0 (3-bit color = black/transparent)
// ─────────────────────────────────────────────────────────
always @(posedge clk) begin
    if (rst) begin
        pxl_color <= 4'd0;
        pxl_pal   <= 7'd0;
        pxl_prio  <= 1'b0;
        pxl_valid <= 1'b0;
    end else if (pxl_cen) begin
        pxl_color <= raw_pixel;
        pxl_pal   <= r_palette;
        pxl_prio  <= r_prio;
        pxl_valid <= |raw_pixel[2:0];   // transparent when low 3 bits zero
    end
end

endmodule
`default_nettype wire
