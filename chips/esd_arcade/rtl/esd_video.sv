// =============================================================================
// esd_video.sv — ESD 16-bit Video Subsystem
// =============================================================================
//
// Hardware reference: MAME src/mame/misc/esd16.cpp
//
// BG layer map layout:
//   8x8 mode:   128 tiles wide x 64 tall (1024x512 pixel map, wraps)
//   16x16 mode:  64 tiles wide x 64 tall (1024x1024 pixel map, wraps)
//   Map entry:   tile_code[15:0] — just the code, color from layer0_color or 0
//
// GFX ROM layout (bgs region, 8bpp):
//   gfx_8x8x8_raw:    8 bytes/row x 8 rows = 64 bytes per tile
//   hedpanic_layout_16x16x8: 8 planes interleaved across 256 bytes per tile
//
// Sprite layout (5bpp hedpanic_sprite_16x16x5):
//   3 ROM regions interleaved, 5 bitplanes, 16x16 pixels = 160 bytes/sprite
//
// Priority: layer 0 (back) -> layer 1 -> sprites (front unless sprite[15]=1)
//
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module esd_video #(
    parameter int unsigned VRAM_ABITS = 15,  // 2 layers × 16K = 32K words → 15-bit
    parameter int unsigned PAL_ABITS  = 9,
    parameter int unsigned SPR_ABITS  = 10
) (
    input  logic        clk_sys,
    input  logic        clk_pix,
    input  logic        rst,

    // Video timing
    input  logic  [9:0] hcnt,
    input  logic  [8:0] vcnt,
    input  logic        hblank,
    input  logic        vblank,
    input  logic        flip_screen,

    // Layer control
    input  logic [15:0] scroll0_x,
    input  logic [15:0] scroll0_y,
    input  logic  [1:0] layer0_color,
    input  logic [15:0] layersize,      // [0]=layer0 16x16, [1]=layer1 16x16
    input  logic [15:0] scroll1_x,
    input  logic [15:0] scroll1_y,

    // VRAM read (registered output from parent dual-port BRAM)
    output logic [VRAM_ABITS-1:0] vram_addr,
    input  logic          [15:0]  vram_data,

    // Palette read (registered output from parent dual-port BRAM)
    output logic [PAL_ABITS-1:0] pal_addr,
    input  logic         [15:0]  pal_data,

    // Sprite RAM read (registered output from parent dual-port BRAM)
    output logic [SPR_ABITS-1:0] spr_addr,
    input  logic         [15:0]  spr_data,

    // Sprite ROM SDRAM
    output logic [26:0] spr_rom_addr,
    input  logic [15:0] spr_rom_data,
    output logic        spr_rom_req,
    input  logic        spr_rom_ack,

    // BG tile ROM SDRAM
    output logic [26:0] bg_rom_addr,
    input  logic [15:0] bg_rom_data,
    output logic        bg_rom_req,
    input  logic        bg_rom_ack,

    // RGB output
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b
);

// =============================================================================
// Line Buffers (ping-pong)
// Each pixel stores palette index [8:0] (0=transparent for sprites)
// Packed: {is_sprite[0], pal_idx[8:0]}
// =============================================================================

logic [9:0] linebuf_a [0:319];
logic [9:0] linebuf_b [0:319];
logic        linebuf_sel;   // which buffer is being written this HBlank

logic [9:0]  lbuf_wr_data;
logic [8:0]  lbuf_wr_addr;
logic         lbuf_wr_en;
logic [9:0]  lbuf_rd_data;
logic [8:0]  lbuf_rd_addr;

// Write port
always_ff @(posedge clk_sys) begin
    if (lbuf_wr_en) begin
        if (!linebuf_sel)
            linebuf_a[lbuf_wr_addr] <= lbuf_wr_data;
        else
            linebuf_b[lbuf_wr_addr] <= lbuf_wr_data;
    end
end

// Read port (reads opposite buffer from writer)
always_ff @(posedge clk_sys) begin
    if (!linebuf_sel)
        lbuf_rd_data <= linebuf_b[lbuf_rd_addr];
    else
        lbuf_rd_data <= linebuf_a[lbuf_rd_addr];
end

// Swap on HBlank rising edge
logic hblank_prev;
always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        linebuf_sel <= 1'b0;
        hblank_prev <= 1'b0;
    end else if (clk_pix) begin
        hblank_prev <= hblank;
        if (hblank && !hblank_prev)
            linebuf_sel <= ~linebuf_sel;
    end
end

// =============================================================================
// BG Layer Renderer (8x8 mode, runs during HBlank to pre-fill next line)
// Renders layer0 only (gate2 scope — layer1 + sprites in gate4+)
//
// Algorithm (8x8 mode):
//   For each pixel px=0..319:
//     gx = px + scroll0_x + SCROLL0_DX (= -0x5E)   (wrap mod 1024)
//     gy = (next_vcnt) + scroll0_y                   (wrap mod 512)
//     tile_x = gx >> 3   (0..127)
//     tile_y = gy >> 3   (0..63)
//     tile_code = vram[tile_y * 128 + tile_x]
//     pixel_col = gx & 7
//     pixel_row = gy & 7
//     gfx_byte_addr = tile_code * 64 + pixel_row * 8 + pixel_col
//     pal_index = gfx_byte (from BG ROM)
//     linebuf[px] = {layer0_color, pal_index}  (9-bit palette entry)
//
// SDRAM fetch: one 16-bit word = 2 pixels, so fetch 4 words per tile row
// For gate2: use combinational palette-index-zero fill (stub) to verify pipeline
// =============================================================================

// BG render state machine
typedef enum logic [2:0] {
    BG_IDLE,
    BG_FETCH_TILE,
    BG_WAIT_TILE,
    BG_FETCH_PIX,
    BG_WAIT_PIX,
    BG_WRITE_PIX
} bg_state_t;

bg_state_t bg_state;

logic [8:0]  bg_px;          // current pixel being rendered (0..319)
logic [9:0]  bg_gx;          // global X = px + scrollX + offset
logic [8:0]  bg_gy;          // global Y = next_vcnt + scrollY
logic [15:0] bg_tile_code;   // fetched tile code from VRAM
logic [7:0]  bg_pix_byte;    // fetched pixel byte from BG ROM
logic [26:0] bg_rom_fetch_addr;
logic        bg_rom_pending;

// Scroll with hardware offset: -0x5E = -94 (see MAME tilemap[0]->set_scrolldx(-0x60+2))
localparam signed [9:0] SCROLL0_DX = -10'sd94;
localparam signed [9:0] SCROLL1_DX = -10'sd96;

logic [8:0] render_vcnt;   // vcnt of line being rendered = current vcnt + 1

// Combinational helpers to avoid bitslice-on-expression (not supported by all tools)
wire [8:0]  bg_tile_y_raw = render_vcnt + scroll0_y[8:0];
wire [5:0]  bg_tile_row   = bg_tile_y_raw[8:3];
wire [9:0]  bg_tile_x_raw = (10'(bg_px) + scroll0_x[9:0] + 10'(SCROLL0_DX)) & 10'h3FF;
wire [6:0]  bg_tile_col   = bg_tile_x_raw[9:3];

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        bg_state       <= BG_IDLE;
        bg_px          <= '0;
        bg_gx          <= '0;
        bg_gy          <= '0;
        bg_tile_code   <= '0;
        bg_pix_byte    <= '0;
        bg_rom_pending <= 1'b0;
        lbuf_wr_en     <= 1'b0;
        lbuf_wr_addr   <= '0;
        lbuf_wr_data   <= '0;
        render_vcnt    <= '0;
        vram_addr      <= '0;
        bg_rom_req     <= 1'b0;
        bg_rom_addr    <= '0;
    end else begin
        lbuf_wr_en <= 1'b0;
        bg_rom_req <= 1'b0;

        case (bg_state)
            BG_IDLE: begin
                // Wait for HBlank start
                if (hblank && !hblank_prev) begin
                    bg_px       <= '0;
                    render_vcnt <= vcnt[8:0] + 1'b1;
                    bg_state    <= BG_FETCH_TILE;
                end
            end

            BG_FETCH_TILE: begin
                if (bg_px >= 9'd320) begin
                    bg_state <= BG_IDLE;
                end else begin
                    // Compute global coordinates
                    bg_gx <= (10'(bg_px) + scroll0_x[9:0] + 10'(SCROLL0_DX)) & 10'h3FF;
                    bg_gy <= (render_vcnt + scroll0_y[8:0]) & 9'h1FF;
                    // Issue VRAM read for tile code
                    // 8x8 mode: tile index = tile_y * 128 + tile_x
                    // tile_x = gx[9:3], tile_y = gy[8:3]
                    // vram address: {layer0=0, tile_y[5:0], tile_x[6:0]}
                    // For now: issue address, wait 1 cycle for registered read
                    vram_addr <= {1'b0, bg_tile_row, bg_tile_col};
                    bg_state  <= BG_WAIT_TILE;
                end
            end

            BG_WAIT_TILE: begin
                // vram_data is now valid (1-cycle registered BRAM read)
                bg_tile_code <= vram_data;
                bg_state     <= BG_FETCH_PIX;
            end

            BG_FETCH_PIX: begin
                // Fetch pixel byte from BG ROM via SDRAM
                // 8x8 tile: 64 bytes. pixel_row = gy[2:0], pixel_col = gx[2:0]
                // byte address = tile_code * 64 + pixel_row * 8 + pixel_col
                bg_rom_addr    <= 27'h280000 +
                                  27'({bg_tile_code[12:0], 6'b0}) +
                                  27'({bg_gy[2:0], 3'b0}) +
                                  27'(bg_gx[2:0]);
                bg_rom_req     <= 1'b1;
                bg_rom_pending <= 1'b1;
                bg_state       <= BG_WAIT_PIX;
            end

            BG_WAIT_PIX: begin
                if (bg_rom_ack) begin
                    bg_rom_req     <= 1'b0;
                    bg_rom_pending <= 1'b0;
                    // Extract byte based on byte-within-word alignment
                    bg_pix_byte <= bg_rom_addr[0] ? bg_rom_data[15:8] : bg_rom_data[7:0];
                    bg_state    <= BG_WRITE_PIX;
                end else begin
                    bg_rom_req <= bg_rom_pending;  // hold request
                end
            end

            BG_WRITE_PIX: begin
                // Write palette index to line buffer
                // palette index = {layer0_color[1:0], bg_pix_byte[7:0]} = 10-bit?
                // ESD16 palette: 512 entries (9-bit). layer0_color selects bank of 256.
                lbuf_wr_en   <= 1'b1;
                lbuf_wr_addr <= bg_px[8:0];
                // Palette index: bit8 = layer0_color[0] (bank), bits[7:0] = pixel
                lbuf_wr_data <= {1'b0, layer0_color[0], bg_pix_byte};
                bg_px        <= bg_px + 1'b1;
                bg_state     <= BG_FETCH_TILE;
            end

            default: bg_state <= BG_IDLE;
        endcase
    end
end

// Sprite RAM and spr_rom ports not connected yet (stub)
assign spr_addr    = '0;
assign spr_rom_req = 1'b0;
assign spr_rom_addr = '0;

// =============================================================================
// Pixel Output — Read from line buffer during active scan
// =============================================================================

always_ff @(posedge clk_sys or posedge rst) begin
    if (rst)
        lbuf_rd_addr <= '0;
    else if (clk_pix)
        lbuf_rd_addr <= hcnt[8:0];
end

// Palette lookup
assign pal_addr = lbuf_rd_data[PAL_ABITS-1:0];

// RGB expansion from xRGB_555
// Format: [14:10]=R, [9:5]=G, [4:0]=B, bit15 unused
logic [15:0] pal_r1;
always_ff @(posedge clk_sys or posedge rst) begin
    if (rst) begin
        pal_r1 <= '0;
        rgb_r  <= '0;
        rgb_g  <= '0;
        rgb_b  <= '0;
    end else if (clk_pix) begin
        pal_r1 <= pal_data;
        if (hblank || vblank) begin
            rgb_r <= 8'h00;
            rgb_g <= 8'h00;
            rgb_b <= 8'h00;
        end else begin
            rgb_r <= {pal_r1[14:10], pal_r1[14:12]};
            rgb_g <= {pal_r1[9:5],   pal_r1[9:7]};
            rgb_b <= {pal_r1[4:0],   pal_r1[4:2]};
        end
    end
end

endmodule
