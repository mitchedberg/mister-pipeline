// Psikyo Gate 3 — Per-scanline Sprite Rasterizer
// Processes the display_list produced by Gate 2 (PS2001B sprite scanner)
// and renders all intersecting sprites into a 320-pixel scanline buffer.
//
// Sprite tile format: 16×16 px, 4bpp, 128 bytes/tile (identical to NMK16 / GP9001).
//   One tile row = 8 bytes, 2 pixels/byte.
//   Byte b: low nibble [3:0] = left pixel, high nibble [7:4] = right pixel.
//   ROM byte address: tile * 128 + row_in_tile * 8 + byte_idx
//
// Sprite size encoding (display_list_size [2:0]):
//   size=0: 1×1 tiles  = 16×16 px
//   size=1: 2×2 tiles  = 32×32 px
//   size=2: 4×4 tiles  = 64×64 px
//   size=3: 8×8 tiles  = 128×128 px
//   size=4: 16×16 tiles = 256×256 px  (fits in 9-bit X/Y)
//   (sizes 5-7 treated as 1×1 for safety)
//
// Multi-tile row-major layout:
//   full_tile = tile_num + tile_row * tiles_wide + tile_col
//
// Flip semantics:
//   flip_y: row_in_sprite = (sprite_height - 1) - raw_row
//   flip_x: pixels mirrored horizontally within sprite width
//
// Transparency: nibble == 0 → pixel not written (transparent).
//
// Priority: each pixel stores the sprite's 2-bit priority field.
//
// State machine:
//   G3_IDLE  — wait for scan_trigger, clear pixel buffer
//   G3_CHECK — test if display_list[spr_idx] intersects current_scanline
//   G3_FETCH — read one ROM byte/cycle, unpack 2 pixels, advance counters
//
// Date: 2026-03-17

/* verilator lint_off UNUSEDSIGNAL */
module psikyo_gate3 (
    input  logic        clk,
    input  logic        rst_n,

    // ── Gate 2 display list (from PS2001B sprite scanner) ─────────────────
    input  logic [9:0]  display_list_x       [0:255],
    input  logic [9:0]  display_list_y       [0:255],
    input  logic [15:0] display_list_tile    [0:255],
    input  logic [3:0]  display_list_palette [0:255],
    input  logic        display_list_flip_x  [0:255],
    input  logic        display_list_flip_y  [0:255],
    input  logic [1:0]  display_list_priority[0:255],
    input  logic [2:0]  display_list_size    [0:255],
    input  logic        display_list_valid   [0:255],
    input  logic [7:0]  display_list_count,           // number of entries to render

    // ── Rasterizer control ────────────────────────────────────────────────
    input  logic        scan_trigger,       // 1-cycle pulse: start scanline render
    input  logic [8:0]  current_scanline,   // scanline to render (0..239)

    // ── Sprite ROM interface (4bpp packed, byte-addressed) ─────────────────
    // One 16×16 tile = 128 bytes (16 rows × 8 bytes/row, 2 pixels/byte)
    output logic [23:0] spr_rom_addr,       // sprite ROM byte address
    output logic        spr_rom_rd,         // ROM read strobe
    input  logic [7:0]  spr_rom_data,       // ROM data (combinational, zero latency)

    // ── Scanline pixel buffer read-back (combinational, valid after spr_render_done) ─
    input  logic [9:0]  spr_rd_addr,        // pixel X to read (0..319)
    output logic [7:0]  spr_rd_color,       // {palette[3:0], nybble[3:0]}
    output logic        spr_rd_valid,       // 1 = opaque sprite pixel
    output logic [1:0]  spr_rd_priority,    // sprite priority at this pixel

    // ── Done strobe ───────────────────────────────────────────────────────
    output logic        spr_render_done     // 1-cycle pulse when scanline render complete
);

    // ── FSM state encoding ────────────────────────────────────────────────

    typedef enum logic [1:0] {
        G3_IDLE  = 2'd0,
        G3_CHECK = 2'd1,
        G3_FETCH = 2'd2,
        G3_DONE  = 2'd3   // unused, avoids Verilator warning
    } g3_state_t;

    g3_state_t g3_state;

    // ── Counters / working registers ──────────────────────────────────────

    logic [7:0]  g3_spr_idx;       // current display_list index (0..255)
    logic [4:0]  g3_tile_col;      // current tile column within sprite (0..15)
    logic [3:0]  g3_byte_idx;      // current byte within tile row (0..7)

    // Saved fields from current display_list entry
    logic [9:0]  g3_spr_x;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [9:0]  g3_spr_y;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] g3_tile_base;     // sprite.tile_num (16-bit)
    logic        g3_flip_x;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        g3_flip_y_saved;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0]  g3_palette;
    logic [1:0]  g3_priority;
    logic [2:0]  g3_size;          // 0=16px, 1=32px, ..., 4=256px

    // Derived geometry (registered when entering G3_FETCH)
    logic [7:0]  g3_row_in_spr;    // row within sprite (after flip_y)

    // Combinational geometry
    logic [4:0]  g3_tiles_wide;    // 1 << g3_size  (capped at 16)
    logic [9:0]  g3_px_width;      // tiles_wide * 16
    logic [3:0]  g3_tile_row;      // g3_row_in_spr[7:4]
    logic [3:0]  g3_rit;           // row in tile = g3_row_in_spr[3:0]
    logic [19:0] g3_full_tile;     // tile_base + tile_row*tiles_wide + tile_col

    // ── Scanline pixel buffer (320 entries) ───────────────────────────────

    logic [7:0]  spr_pix_color    [0:319];
    logic        spr_pix_valid    [0:319];
    logic [1:0]  spr_pix_priority [0:319];

    // ── Read-back port (combinational) ────────────────────────────────────

    always_comb begin
        spr_rd_color    = spr_pix_color[spr_rd_addr[8:0]];
        spr_rd_valid    = spr_pix_valid[spr_rd_addr[8:0]];
        spr_rd_priority = spr_pix_priority[spr_rd_addr[8:0]];
    end

    // ── ROM address drive (combinational) ─────────────────────────────────

    always_comb begin
        // Clamp size to 4 (max 16×16 tiles = 256×256 px)
        g3_tiles_wide = (g3_size <= 3'd4) ? 5'(1 << g3_size) : 5'd1;
        g3_px_width   = 10'(g3_tiles_wide) * 10'd16;
        g3_rit        = g3_row_in_spr[3:0];
        g3_tile_row   = g3_row_in_spr[7:4];
        g3_full_tile  = 20'(g3_tile_base)
                      + 20'(g3_tile_row)  * 20'(g3_tiles_wide)
                      + 20'(g3_tile_col);
        spr_rom_addr  = 24'(g3_full_tile) * 24'd128
                      + 24'(g3_rit)       * 24'd8
                      + 24'(g3_byte_idx);
        spr_rom_rd    = (g3_state == G3_FETCH);
    end

    // ── FSM ───────────────────────────────────────────────────────────────

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g3_state        <= G3_IDLE;
            g3_spr_idx      <= 8'h00;
            g3_tile_col     <= 5'h00;
            g3_byte_idx     <= 4'h0;
            g3_spr_x        <= 10'h000;
            g3_spr_y        <= 10'h000;
            g3_tile_base    <= 16'h0000;
            g3_flip_x       <= 1'b0;
            g3_flip_y_saved <= 1'b0;
            g3_palette      <= 4'h0;
            g3_priority     <= 2'h0;
            g3_size         <= 3'h0;
            g3_row_in_spr   <= 8'h00;
            spr_render_done <= 1'b0;
            for (int i = 0; i < 320; i++) begin
                spr_pix_color[i]    <= 8'h00;
                spr_pix_valid[i]    <= 1'b0;
                spr_pix_priority[i] <= 2'h0;
            end
        end else begin
            spr_render_done <= 1'b0;   // default: not done

            case (g3_state)

                // ── IDLE: wait for trigger, clear pixel buffer ───────────
                G3_IDLE: begin
                    if (scan_trigger) begin
                        for (int i = 0; i < 320; i++) begin
                            spr_pix_color[i]    <= 8'h00;
                            spr_pix_valid[i]    <= 1'b0;
                            spr_pix_priority[i] <= 2'h0;
                        end
                        g3_spr_idx <= 8'h00;
                        g3_state   <= G3_CHECK;
                    end
                end

                // ── CHECK: test if display_list[spr_idx] intersects scanline
                G3_CHECK: begin
                    if (g3_spr_idx >= display_list_count) begin
                        // All sprites processed — done
                        spr_render_done <= 1'b1;
                        g3_state        <= G3_IDLE;
                    end else begin
                        begin
                            automatic logic [9:0]  e_y      = display_list_y[g3_spr_idx];
                            automatic logic [9:0]  e_x      = display_list_x[g3_spr_idx];
                            automatic logic [15:0] e_tile   = display_list_tile[g3_spr_idx];
                            automatic logic        e_flip_x = display_list_flip_x[g3_spr_idx];
                            automatic logic        e_flip_y = display_list_flip_y[g3_spr_idx];
                            automatic logic [2:0]  e_size   = display_list_size[g3_spr_idx];
                            automatic logic [3:0]  e_pal    = display_list_palette[g3_spr_idx];
                            automatic logic [1:0]  e_prio   = display_list_priority[g3_spr_idx];
                            automatic logic        e_valid  = display_list_valid[g3_spr_idx];

                            if (e_valid) begin
                                automatic logic [4:0]  tw    = (e_size <= 3'd4) ? 5'(1 << e_size) : 5'd1;
                                automatic logic [9:0]  spr_h = 10'(tw) * 10'd16;
                                if (current_scanline >= e_y[8:0] &&
                                    current_scanline < (e_y[8:0] + spr_h[8:0])) begin
                                    // Intersects — save fields, start fetch
                                    g3_spr_x        <= e_x;
                                    g3_spr_y        <= e_y;
                                    g3_tile_base    <= e_tile;
                                    g3_flip_x       <= e_flip_x;
                                    g3_flip_y_saved <= e_flip_y;
                                    g3_palette      <= e_pal;
                                    g3_priority     <= e_prio;
                                    g3_size         <= e_size;

                                    // Row within sprite (with flip_y)
                                    begin
                                        /* verilator lint_off UNUSEDSIGNAL */
                                        automatic logic [8:0] raw_row =
                                            9'(current_scanline) - 9'(e_y[8:0]);
                                        /* verilator lint_on UNUSEDSIGNAL */
                                        if (e_flip_y)
                                            g3_row_in_spr <= 8'(spr_h - 9'd1) - raw_row[7:0];
                                        else
                                            g3_row_in_spr <= raw_row[7:0];
                                    end

                                    g3_tile_col <= 5'h00;
                                    g3_byte_idx <= 4'h0;
                                    g3_state    <= G3_FETCH;
                                end else begin
                                    // No intersection — advance
                                    g3_spr_idx <= g3_spr_idx + 8'h01;
                                end
                            end else begin
                                // Invalid entry — advance
                                g3_spr_idx <= g3_spr_idx + 8'h01;
                            end
                        end
                    end
                end

                // ── FETCH: read one ROM byte, unpack 2 pixels ────────────
                G3_FETCH: begin
                    begin
                        automatic logic [3:0]  nib_lo = spr_rom_data[3:0];   // left pixel
                        automatic logic [3:0]  nib_hi = spr_rom_data[7:4];   // right pixel

                        automatic logic [10:0] base_x;
                        automatic logic [10:0] px_lo_x, px_hi_x;
                        automatic logic [3:0]  eff_nib_lo, eff_nib_hi;

                        if (g3_flip_x) begin
                            // flip_x: sprite pixel P → screen X = spr_x + (px_width - 1 - P)
                            // Byte b, tile_col tc:
                            //   P_lo = tc*16 + 2*b   → screen = spr_x + px_w - 1 - P_lo
                            //   P_hi = tc*16 + 2*b+1 → screen = spr_x + px_w - 2 - 2*b - tc*16
                            base_x     = 11'(g3_spr_x)
                                       + 11'(g3_px_width)
                                       - 11'd2
                                       - 11'(g3_tile_col) * 11'd16
                                       - 11'(g3_byte_idx) * 11'd2;
                            px_hi_x    = base_x;          // nib_hi → lower screen X
                            px_lo_x    = base_x + 11'd1;  // nib_lo → higher screen X
                            eff_nib_hi = nib_hi;
                            eff_nib_lo = nib_lo;
                        end else begin
                            base_x     = 11'(g3_spr_x)
                                       + 11'(g3_tile_col) * 11'd16
                                       + 11'(g3_byte_idx) * 11'd2;
                            px_lo_x    = base_x;
                            px_hi_x    = base_x + 11'd1;
                            eff_nib_lo = nib_lo;
                            eff_nib_hi = nib_hi;
                        end

                        /* verilator lint_off WIDTHTRUNC */
                        // Write low pixel
                        if (px_lo_x < 11'd320 && eff_nib_lo != 4'h0) begin
                            spr_pix_color[px_lo_x[8:0]]    <= {g3_palette, eff_nib_lo};
                            spr_pix_valid[px_lo_x[8:0]]    <= 1'b1;
                            spr_pix_priority[px_lo_x[8:0]] <= g3_priority;
                        end
                        // Write high pixel
                        if (px_hi_x < 11'd320 && eff_nib_hi != 4'h0) begin
                            spr_pix_color[px_hi_x[8:0]]    <= {g3_palette, eff_nib_hi};
                            spr_pix_valid[px_hi_x[8:0]]    <= 1'b1;
                            spr_pix_priority[px_hi_x[8:0]] <= g3_priority;
                        end
                        /* verilator lint_on WIDTHTRUNC */
                    end

                    // Advance counters
                    if (g3_byte_idx == 4'd7) begin
                        g3_byte_idx <= 4'd0;
                        if (g3_tile_col == (5'(g3_tiles_wide) - 5'd1)) begin
                            g3_tile_col <= 5'h00;
                            // Move to next sprite
                            g3_spr_idx <= g3_spr_idx + 8'd1;
                            g3_state   <= G3_CHECK;
                        end else begin
                            g3_tile_col <= g3_tile_col + 5'd1;
                        end
                    end else begin
                        g3_byte_idx <= g3_byte_idx + 4'd1;
                    end
                end

                G3_DONE: begin
                    // Unused state — included to avoid Verilator incomplete-case warning
                    g3_state <= G3_IDLE;
                end

                default: g3_state <= G3_IDLE;

            endcase
        end
    end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
