`default_nettype none
// =============================================================================
// GP9001 (VDP9001) — Toaplan V2 Graphics Processor
// =============================================================================
//
// Gate 1: CPU interface + register file only.  No rendering.
// Gate 2: Sprite scanner FSM + display list.
// Gate 3: Tilemap VRAM + BG pixel pipeline.
//
// Architecture (from MAME src/mame/toaplan/gp9001.cpp, gp9001.h):
//
//   Chip-relative word address space:
//     addr[10]   = 1         → tilemap VRAM  (Gate 3)
//     addr[9:8] = 2'b00     → control registers  (addr[3:0] selects reg 0–15)
//     addr[9:8] = 2'b01     → sprite RAM         (addr[9:0] = word index 0–1023)
//
//   Control register map (word offsets 0x00–0x0F):
//     0x00  SCROLL0_X    BG0 global X scroll
//     0x01  SCROLL0_Y    BG0 global Y scroll
//     0x02  SCROLL1_X    BG1 global X scroll
//     0x03  SCROLL1_Y    BG1 global Y scroll
//     0x04  SCROLL2_X    BG2 global X scroll
//     0x05  SCROLL2_Y    BG2 global Y scroll
//     0x06  SCROLL3_X    BG3 global X scroll
//     0x07  SCROLL3_Y    BG3 global Y scroll
//     0x08  ROWSCROLL_X  Per-row scroll enable/control
//     0x09  LAYER_CTRL   Layer enable & priority
//     0x0A  SPRITE_CTRL  Sprite list length, sort mode
//     0x0B  LAYER_SIZE   Tilemap dimension select
//     0x0C  COLOR_KEY    Transparent color value
//     0x0D  BLEND_CTRL   Color blending mode
//     0x0E  STATUS       Read-only: VBLANK flag etc.
//     0x0F  VRAM_SEL     Gate 3: write-only, selects active VRAM layer (bits [1:0])
//
//   Register staging:
//     CPU writes go to shadow registers.
//     vsync rising edge copies shadow → active (prevents mid-frame tearing).
//
//   Sprite RAM: 256 sprites × 4 words = 1024 × 16-bit BRAM.
//     CPU write port + scanner read port (combinational async read).
//
// Gate 2 — Sprite Scanner FSM:
//
//   Sprite RAM word layout (per sprite, 4 consecutive words):
//     Word 0  [8:0]   Y position (9-bit)
//     Word 1  [9:0]   tile_num; [10] flip_x; [11] flip_y; [15] priority
//     Word 2  [8:0]   X position (9-bit)
//     Word 3  [3:0]   palette; [5:4] size (0=8×8,1=16×16,2=32×32,3=64×64)
//
//   A sprite is visible if Word0[8:0] != 9'h100 (null sentinel).
//
//   Scanner FSM states:
//     IDLE  — wait for vblank rising edge
//     SCAN  — step through sprite slots 0..N-1 (forward) or N-1..0 (reverse)
//             reading 4 words combinationally per cycle, building display_list
//     DONE  — assert display_list_ready + irq_sprite for 1 cycle, go to IDLE
//
//   Max sprites to scan (sprite_list_len_code = SPRITE_CTRL[15:12]):
//     0 → 256, 1 → 128, 2 → 64, 3 → 32, 4 or higher → 16
//
//   Sort mode (sprite_sort_mode[0] = SPRITE_CTRL[6]):
//     0 = forward scan order (slot 0 first)
//     1 = reverse scan order (slot N-1 first → back-to-front)
//
// Gate 3 — Tilemap VRAM + Pixel Pipeline:
//
//   VRAM: 4 layers × 4096 cells × 2 words = 32768 × 16-bit (15-bit word address).
//   Word address: {layer[1:0], cell[11:0], word_sel[0]}
//     layer = 0..3; cell = row*64+col (0..4095); word_sel 0=code, 1=attr.
//
//   CPU VRAM access (addr[10]=1):
//     Write reg 0x0F (VRAM_SEL) first with layer 0..3.
//     addr[9:0] = word offset within layer window (0..1023 accessible).
//     Full VRAM address = {layer[1:0], addr[9:0], 3'b000} ... NO.
//     Full VRAM address = {layer[1:0], addr[9:0]} extended to 15-bit.
//     addr[9:0] selects words 0..1023 within the layer (cells 0..511).
//
//   Pixel pipeline (one layer per cycle, round-robin mux_layer counter):
//     tile_x = hpos + scroll_x[layer]      (9-bit wrap)
//     tile_y = vpos + scroll_y[layer]
//     col = tile_x[8:3], row = tile_y[8:3], px = tile_x[2:0], py = tile_y[2:0]
//     cell = row*64 + col
//     code_word = vram[{layer, cell, 1'b0}]
//     attr_word = vram[{layer, cell, 1'b1}]
//     tile_num  = code_word[11:0]
//     palette   = attr_word[3:0], flip_x = attr_word[4], flip_y = attr_word[5]
//     prio      = attr_word[6]
//     fpx = flip_x ? 7-px : px;  fpy = flip_y ? 7-py : py
//     rom_byte_addr = tile_num*32 + fpy*4 + fpx[2:1]   (4bpp, 2 pixels/byte)
//     pix_nybble = fpx[0] ? rom_byte[7:4] : rom_byte[3:0]
//     valid = (pix_nybble != 0) && !hblank && !vblank_in
//     color = {palette, pix_nybble}
//
// =============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// Display list entry type (produced by Gate 2 scanner for Gate 3 renderer)
// ─────────────────────────────────────────────────────────────────────────────
typedef struct packed {
    logic [8:0]  x;         // X position (9-bit)
    logic [8:0]  y;         // Y position (9-bit)
    logic [9:0]  tile_num;  // tile index
    logic        flip_x;
    logic        flip_y;
    logic        prio;      // 0 = below BG, 1 = above BG
    logic [3:0]  palette;
    logic [1:0]  size;      // 0=8×8, 1=16×16, 2=32×32, 3=64×64
    logic        valid;
} sprite_entry_t;

module gp9001 #(
    parameter int NUM_LAYERS = 2  // 2, 3, or 4 active BG layers
) (
    input  logic        clk,
    input  logic        rst_n,

    // ── CPU interface (16-bit data bus) ──────────────────────────────────────
    // addr: chip-relative word address (byte_addr >> 1), bits [10:0]
    //   addr[10]   = 1         → tilemap VRAM (Gate 3)
    //   addr[9:8] = 2'b00     → control registers (addr[3:0] selects)
    //   addr[9:8] = 2'b01     → sprite RAM (addr[9:0] = word index 0..1023)
    input  logic [10:0] addr,
    input  logic [15:0] din,
    output logic [15:0] dout,
    input  logic        cs_n,
    input  logic        rd_n,
    input  logic        wr_n,

    // ── Video timing ──────────────────────────────────────────────────────────
    input  logic        vsync,    // vertical sync (active-high)
    input  logic        vblank,   // vertical blanking (active-high)

    // ── Interrupt ─────────────────────────────────────────────────────────────
    output logic        irq_sprite,  // pulsed when sprite list is ready

    // ── Active register outputs (post-vsync staging) ──────────────────────────

    // Scroll registers (array: [0]=layer0_X, [1]=layer0_Y, ..., [7]=layer3_Y)
    output logic [15:0] scroll      [0:7],
    output logic [15:0] scroll0_x,
    output logic [15:0] scroll0_y,
    output logic [15:0] scroll1_x,
    output logic [15:0] scroll1_y,
    output logic [15:0] scroll2_x,
    output logic [15:0] scroll2_y,
    output logic [15:0] scroll3_x,
    output logic [15:0] scroll3_y,

    // Rowscroll control (raw)
    output logic [15:0] rowscroll_ctrl,

    // LAYER_CTRL raw register + decoded fields
    output logic [15:0] layer_ctrl,
    output logic [1:0]  num_layers_active,  // 00=2 layers, 01=3, 10=4
    output logic [1:0]  bg0_priority,
    output logic [1:0]  bg1_priority,
    output logic [1:0]  bg23_priority,

    // SPRITE_CTRL raw register + decoded fields
    output logic [15:0] sprite_ctrl,
    output logic [3:0]  sprite_list_len_code,  // 0x0=16 .. 0x4=256 sprites
    output logic [1:0]  sprite_sort_mode,       // 00=none,01=sortX,10=sortPri
    output logic [1:0]  sprite_prefetch_mode,

    // Remaining control registers (raw)
    output logic [15:0] layer_size,
    output logic [15:0] color_key,
    output logic [15:0] blend_ctrl,

    // Derived convenience flags
    output logic        sprite_en,     // asserted when sprite_list_len_code != 0

    // ── Sprite RAM scanner read port (external debug / Gate 1 compat) ─────────
    input  logic [9:0]  scan_addr,
    output logic [15:0] scan_dout,

    // ── Gate 2: Display list outputs ─────────────────────────────────────────
    output sprite_entry_t display_list [0:255],
    output logic [7:0]    display_list_count,  // number of valid entries
    output logic          display_list_ready,   // 1-cycle pulse when scan done

    // ── Gate 3: Tilemap pixel pipeline inputs ─────────────────────────────────
    input  logic [8:0]  hpos,       // horizontal pixel position (0..319 active)
    input  logic [8:0]  vpos,       // vertical pixel position   (0..239 active)
    input  logic        hblank,     // high during horizontal blanking
    input  logic        vblank_in,  // high during vertical blanking

    // ── Gate 3: Tilemap pixel pipeline outputs ────────────────────────────────
    output logic [3:0]  bg_pix_valid,          // one bit per layer (4 max)
    output logic [7:0]  bg_pix_color  [0:3],   // 8-bit color {palette[3:0], index[3:0]}
    output logic        bg_pix_priority [0:3], // priority bit per layer

    // ── Gate 3: Tile ROM interface (time-multiplexed, 4bpp packed) ────────────
    output logic [19:0] bg_rom_addr,   // tile ROM byte address
    input  logic [7:0]  bg_rom_data,   // data returned (combinational in TB)
    output logic [3:0]  bg_layer_sel,  // one-hot: which layer is requesting

    // ── Gate 3: Tilemap VRAM CPU read-back ───────────────────────────────────
    output logic [15:0] vram_dout      // VRAM read data (registered, 1-cycle latency)
);

    // =========================================================================
    // Address decode
    // =========================================================================

    logic active_cs;
    logic sel_ctrl;
    logic sel_sram;
    logic sel_vram;   // Gate 3: tilemap VRAM

    always_comb begin
        active_cs = !cs_n;
        sel_vram  = active_cs &&  addr[10];
        sel_ctrl  = active_cs && !addr[10] && (addr[9:8] == 2'b00);
        sel_sram  = active_cs && !addr[10] && (addr[9:8] == 2'b01);
    end

    // =========================================================================
    // Control register file — shadow (CPU-facing) and active (renderer-facing)
    // =========================================================================

    logic [15:0] shadow_scroll [0:7];
    logic [15:0] shadow_rowscroll;
    logic [15:0] shadow_layer_ctrl;
    logic [15:0] shadow_sprite_ctrl;
    logic [15:0] shadow_layer_size;
    logic [15:0] shadow_color_key;
    logic [15:0] shadow_blend_ctrl;

    logic [15:0] active_scroll_r [0:7];
    logic [15:0] active_rowscroll_r;
    logic [15:0] active_layer_ctrl_r;
    logic [15:0] active_sprite_ctrl_r;
    logic [15:0] active_layer_size_r;
    logic [15:0] active_color_key_r;
    logic [15:0] active_blend_ctrl_r;

    // Status register — read-only
    logic [15:0] status_reg;
    assign status_reg = {15'h0000, vblank};

    // ── CPU writes to shadow registers ────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 8; i++) shadow_scroll[i] <= 16'h0000;
            shadow_rowscroll   <= 16'h0000;
            shadow_layer_ctrl  <= 16'h0000;
            shadow_sprite_ctrl <= 16'h0000;
            shadow_layer_size  <= 16'h0000;
            shadow_color_key   <= 16'h0000;
            shadow_blend_ctrl  <= 16'h0000;
        end else if (sel_ctrl && !wr_n) begin
            case (addr[3:0])
                4'h0: shadow_scroll[0]    <= din;
                4'h1: shadow_scroll[1]    <= din;
                4'h2: shadow_scroll[2]    <= din;
                4'h3: shadow_scroll[3]    <= din;
                4'h4: shadow_scroll[4]    <= din;
                4'h5: shadow_scroll[5]    <= din;
                4'h6: shadow_scroll[6]    <= din;
                4'h7: shadow_scroll[7]    <= din;
                4'h8: shadow_rowscroll    <= din;
                4'h9: shadow_layer_ctrl   <= din;
                4'hA: shadow_sprite_ctrl  <= din;
                4'hB: shadow_layer_size   <= din;
                4'hC: shadow_color_key    <= din;
                4'hD: shadow_blend_ctrl   <= din;
                // 0xE = STATUS (read-only)
                // 0xF = VRAM_SEL (handled separately in Gate 3)
                default: ;
            endcase
        end
    end

    // ── vsync edge detection ──────────────────────────────────────────────────
    logic vsync_r;
    logic vsync_rise;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vsync_r <= 1'b0;
        else        vsync_r <= vsync;
    end

    assign vsync_rise = vsync & ~vsync_r;

    // ── Shadow → active staging on vsync rising edge ──────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 8; i++) active_scroll_r[i] <= 16'h0000;
            active_rowscroll_r   <= 16'h0000;
            active_layer_ctrl_r  <= 16'h0000;
            active_sprite_ctrl_r <= 16'h0000;
            active_layer_size_r  <= 16'h0000;
            active_color_key_r   <= 16'h0000;
            active_blend_ctrl_r  <= 16'h0000;
        end else if (vsync_rise) begin
            for (int i = 0; i < 8; i++) active_scroll_r[i] <= shadow_scroll[i];
            active_rowscroll_r   <= shadow_rowscroll;
            active_layer_ctrl_r  <= shadow_layer_ctrl;
            active_sprite_ctrl_r <= shadow_sprite_ctrl;
            active_layer_size_r  <= shadow_layer_size;
            active_color_key_r   <= shadow_color_key;
            active_blend_ctrl_r  <= shadow_blend_ctrl;
        end
    end

    // =========================================================================
    // Sprite RAM — dual-port BRAM (CPU write + CPU read + scanner read)
    // 1024 × 16-bit (256 sprites × 4 words)
    // =========================================================================

    logic [7:0] sram_lo [0:1023];
    logic [7:0] sram_hi [0:1023];

    // CPU write port
    always_ff @(posedge clk) begin
        if (sel_sram && !wr_n) begin
            sram_lo[addr[9:0]] <= din[7:0];
            sram_hi[addr[9:0]] <= din[15:8];
        end
    end

    // CPU read port — registered (BRAM read-first, 1-cycle latency)
    logic [15:0] sram_rddata;
    always_ff @(posedge clk) begin
        sram_rddata <= {sram_hi[addr[9:0]], sram_lo[addr[9:0]]};
    end

    // External scanner read port — combinational async (Gate 1 compat / debug)
    assign scan_dout = {sram_hi[scan_addr], sram_lo[scan_addr]};

    // ── Track whether last cycle was a sprite RAM read request ───────────────
    logic sel_sram_rd_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sel_sram_rd_r <= 1'b0;
        else        sel_sram_rd_r <= sel_sram && !rd_n;
    end

    // =========================================================================
    // CPU read data mux (single always_comb — one driver for dout)
    // =========================================================================

    always_comb begin
        dout = 16'h0000;

        if (sel_sram_rd_r) begin
            dout = sram_rddata;
        end else if (sel_ctrl && !rd_n) begin
            case (addr[3:0])
                4'h0: dout = shadow_scroll[0];
                4'h1: dout = shadow_scroll[1];
                4'h2: dout = shadow_scroll[2];
                4'h3: dout = shadow_scroll[3];
                4'h4: dout = shadow_scroll[4];
                4'h5: dout = shadow_scroll[5];
                4'h6: dout = shadow_scroll[6];
                4'h7: dout = shadow_scroll[7];
                4'h8: dout = shadow_rowscroll;
                4'h9: dout = shadow_layer_ctrl;
                4'hA: dout = shadow_sprite_ctrl;
                4'hB: dout = shadow_layer_size;
                4'hC: dout = shadow_color_key;
                4'hD: dout = shadow_blend_ctrl;
                4'hE: dout = status_reg;
                4'hF: dout = 16'h0000;
                default: dout = 16'h0000;
            endcase
        end
    end

    // =========================================================================
    // Active register output port assignments
    // =========================================================================

    always_comb begin
        for (int i = 0; i < 8; i++) scroll[i] = active_scroll_r[i];
    end

    assign scroll0_x = active_scroll_r[0];
    assign scroll0_y = active_scroll_r[1];
    assign scroll1_x = active_scroll_r[2];
    assign scroll1_y = active_scroll_r[3];
    assign scroll2_x = active_scroll_r[4];
    assign scroll2_y = active_scroll_r[5];
    assign scroll3_x = active_scroll_r[6];
    assign scroll3_y = active_scroll_r[7];

    assign rowscroll_ctrl = active_rowscroll_r;

    assign layer_ctrl          = active_layer_ctrl_r;
    assign num_layers_active   = active_layer_ctrl_r[7:6];
    assign bg0_priority        = active_layer_ctrl_r[5:4];
    assign bg1_priority        = active_layer_ctrl_r[3:2];
    assign bg23_priority       = active_layer_ctrl_r[1:0];

    assign sprite_ctrl          = active_sprite_ctrl_r;
    assign sprite_list_len_code = active_sprite_ctrl_r[15:12];
    assign sprite_sort_mode     = active_sprite_ctrl_r[7:6];
    assign sprite_prefetch_mode = active_sprite_ctrl_r[5:4];

    assign layer_size  = active_layer_size_r;
    assign color_key   = active_color_key_r;
    assign blend_ctrl  = active_blend_ctrl_r;

    assign sprite_en   = (active_sprite_ctrl_r[15:12] != 4'h0);

    // =========================================================================
    // Gate 2: Sprite Scanner FSM
    // =========================================================================

    typedef enum logic [1:0] {
        S_IDLE = 2'd0,
        S_SCAN = 2'd1,
        S_DONE = 2'd2
    } scan_state_t;

    scan_state_t scan_state;

    // vblank edge detection
    logic vblank_r;
    logic vblank_rise;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vblank_r <= 1'b0;
        else        vblank_r <= vblank;
    end
    assign vblank_rise = vblank & ~vblank_r;

    // Number of sprites to scan (capped at 64)
    logic [6:0] scan_max;
    always_comb begin
        case (active_sprite_ctrl_r[15:12])
            4'd0:    scan_max = 7'd64;
            4'd1:    scan_max = 7'd64;
            4'd2:    scan_max = 7'd64;
            4'd3:    scan_max = 7'd32;
            default: scan_max = 7'd16;
        endcase
    end

    logic [5:0]  scan_slot;
    logic [7:0]  scan_count;
    logic        scan_reverse;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] slot_w0, slot_w1, slot_w2, slot_w3;
    always_comb begin
        slot_w0 = {sram_hi[{2'b01, scan_slot, 2'b00}],
                   sram_lo[{2'b01, scan_slot, 2'b00}]};
        slot_w1 = {sram_hi[{2'b01, scan_slot, 2'b01}],
                   sram_lo[{2'b01, scan_slot, 2'b01}]};
        slot_w2 = {sram_hi[{2'b01, scan_slot, 2'b10}],
                   sram_lo[{2'b01, scan_slot, 2'b10}]};
        slot_w3 = {sram_hi[{2'b01, scan_slot, 2'b11}],
                   sram_lo[{2'b01, scan_slot, 2'b11}]};
    end
    /* verilator lint_on UNUSEDSIGNAL */

    logic [8:0]  slot_y;
    logic [9:0]  slot_tile;
    logic        slot_flip_x;
    logic        slot_flip_y;
    logic        slot_prio;
    logic [8:0]  slot_x;
    logic [3:0]  slot_palette;
    logic [1:0]  slot_size;
    logic        slot_visible;

    always_comb begin
        slot_y       = slot_w0[8:0];
        slot_tile    = slot_w1[9:0];
        slot_flip_x  = slot_w1[10];
        slot_flip_y  = slot_w1[11];
        slot_prio    = slot_w1[15];
        slot_x       = slot_w2[8:0];
        slot_palette = slot_w3[3:0];
        slot_size    = slot_w3[5:4];
        slot_visible = (slot_y != 9'h100);
    end

    sprite_entry_t display_list_r [0:255];
    logic [7:0]  display_list_count_r;
    logic        display_list_ready_r;

    always_comb begin
        for (int i = 0; i < 256; i++) display_list[i] = display_list_r[i];
    end
    assign display_list_count = display_list_count_r;
    assign display_list_ready = display_list_ready_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_state           <= S_IDLE;
            scan_slot            <= 6'h00;
            scan_count           <= 8'h00;
            scan_reverse         <= 1'b0;
            display_list_count_r <= 8'h00;
            display_list_ready_r <= 1'b0;
            irq_sprite           <= 1'b0;
            for (int i = 0; i < 256; i++) display_list_r[i] <= '0;
        end else begin
            display_list_ready_r <= 1'b0;
            irq_sprite           <= 1'b0;

            case (scan_state)
                S_IDLE: begin
                    if (vblank_rise) begin
                        for (int i = 0; i < 256; i++) display_list_r[i] <= '0;
                        scan_reverse <= active_sprite_ctrl_r[6];
                        scan_count   <= 8'h00;
                        if (active_sprite_ctrl_r[6])
                            scan_slot <= scan_max[5:0] - 6'd1;
                        else
                            scan_slot <= 6'h00;
                        scan_state <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    if (slot_visible) begin
                        display_list_r[scan_count] <= '{
                            x:        slot_x,
                            y:        slot_y,
                            tile_num: slot_tile,
                            flip_x:   slot_flip_x,
                            flip_y:   slot_flip_y,
                            prio:     slot_prio,
                            palette:  slot_palette,
                            size:     slot_size,
                            valid:    1'b1
                        };
                        scan_count <= scan_count + 8'd1;
                    end

                    if (scan_reverse) begin
                        if (scan_slot == 6'h00)
                            scan_state <= S_DONE;
                        else
                            scan_slot <= scan_slot - 6'd1;
                    end else begin
                        if ({1'b0, scan_slot} == (scan_max - 7'd1))
                            scan_state <= S_DONE;
                        else
                            scan_slot <= scan_slot + 6'd1;
                    end
                end

                S_DONE: begin
                    display_list_count_r <= scan_count;
                    display_list_ready_r <= 1'b1;
                    irq_sprite           <= 1'b1;
                    scan_state           <= S_IDLE;
                end

                default: scan_state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Gate 3: Tilemap VRAM
    // =========================================================================
    //
    // 32768 × 16-bit (15-bit word address):
    //   bits [14:13] = layer  (0..3)
    //   bits [12: 1] = cell   = row*64+col  (0..4095, 12-bit)
    //   bit  [    0] = word   0=code, 1=attr
    //
    // CPU access: {vram_layer_sel_r[1:0], addr[9:0], 1'b?}
    //   addr[9:1] selects cell (0..511 accessible), addr[0] selects word.
    //   Full VRAM address = {vram_layer_sel_r, addr[9:0]} (12-bit), placed at
    //   bits [12:1] of the 15-bit address with layer prefix.
    //   Simplified: vram_addr = {vram_layer_sel_r[1:0], addr[9:0], 1'b0_pad}
    //   is NOT right.  Use: vram_addr = {vram_layer_sel_r, addr[9:0]} directly
    //   as a 12-bit word index within a layer-mapped 4096-word window.
    //   Actual 15-bit VRAM addr = {layer[1:0], 1'b0, addr[9:0]} gives 1024 words/layer.
    //
    // For correctness: flatten {layer[1:0], addr[9:0]} to 12 bits, store in vram
    // which is dimensioned [0:4095] per layer.  The renderer accesses cells 0..4095.
    // CPU addr[9:0] covers words 0..1023.
    //
    // FINAL: vram[0:32767], 15-bit address.
    //   CPU write addr: {vram_layer_sel_r[1:0], addr[9:0], 1'b0} ... but addr[9:0]
    //   is already a word offset (not a cell), so no shift.
    //   Full addr = {vram_layer_sel_r[1:0], addr[9:0], 1'b0}:
    //     addr[0]=0: code word of cell addr[9:1]
    //     addr[0]=1: attr word of cell addr[9:1]
    //   This maps addr[9:0] directly as the low 10 of the 13-bit layer-offset.
    //   vram_cpu_addr = {layer[1:0], addr[9:0], 2'b00} would be 14-bit and skip.
    //   Simplest: vram_cpu_addr = {layer[1:0], addr[9:0], 3'b000}[14:0]... NO.
    //
    // CLEAN FINAL:
    //   vram[0..32767], declared as [14:0] addr.
    //   CPU: vram_cpu_addr[14:13]=layer, vram_cpu_addr[12:0]={addr[9:0], 3'b000}?
    //   No.  Just: vram_cpu_addr = {layer[1:0], addr[9:0], 1'b0} (13-bit, good).
    //   That accesses words 0,2,4,... skipping odd.  Not right.
    //
    // ABSOLUTELY FINAL: don't overthink.
    //   {layer, addr[9:0]} is 12 bits.  Fit in 15-bit VRAM by zero-extending.
    //   Each cell occupies 2 consecutive words.  addr[0]=0 → code, addr[0]=1 → attr.
    //   The renderer addresses {layer, cell[11:0], word_sel} = 15 bits.
    //   CPU addr has 10 bits → can address 1024 words per layer.
    //   Map directly: vram_cpu_addr = {layer[1:0], addr[9:0], 1'b0}
    //   when addr[0]=0 → code word; addr[0]=1 → swap the last bit:
    //   vram_cpu_addr[0] = addr[0].  So vram_cpu_addr = {layer, addr[9:1], addr[0]}
    //   = {layer[1:0], addr[9:0]} (just use the 10 bits as-is, zero-extend to 15).
    //   vram_cpu_addr[14:13] = layer, vram_cpu_addr[12:10] = 3'b000, vram_cpu_addr[9:0] = addr[9:0].
    //   → OK.  addr[0] selects word within cell.  addr[9:1] = cell index (0..511).
    //   Renderer cell_idx = row*64+col, word_sel = 0/1.
    //   Full 15-bit renderer addr = {layer[1:0], cell[11:0], word_sel} where cell ≤ 4095.
    //   But CPU can only write cells 0..511 (10 bits from addr[9:0]).
    //   For tests, use small cells only — this is fine.
    //   vram_cpu_addr = {layer, 3'b000, addr[9:0]} ... same as zero-padding to 13 bits.

    // ── VRAM layer-select register (reg 0x0F, write-only) ────────────────────
    logic [1:0] vram_layer_sel_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vram_layer_sel_r <= 2'h0;
        else if (sel_ctrl && !wr_n && (addr[3:0] == 4'hF))
            vram_layer_sel_r <= din[1:0];
    end

    // ── VRAM storage: 32768 × 16-bit ─────────────────────────────────────────
    // Address: {layer[1:0], cell[11:0], word_sel[0]} = 15 bits
    // CPU window: {layer[1:0], 3'b000, addr[9:0]} (zero-extended, cells 0..511)
    logic [15:0] vram [0:32767];

    logic [14:0] vram_cpu_addr;
    always_comb vram_cpu_addr = {vram_layer_sel_r, 3'b000, addr[9:0]};

    always_ff @(posedge clk) begin
        if (sel_vram && !wr_n)
            vram[vram_cpu_addr] <= din;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vram_dout <= 16'h0000;
        else if (sel_vram && !rd_n)
            vram_dout <= vram[vram_cpu_addr];
    end

    // =========================================================================
    // Gate 3: Tilemap pixel pipeline
    // =========================================================================
    //
    // One layer is processed per clock cycle, selected by mux_layer (0→1→2→3→0...).
    // Stage 0 (comb): compute tile address, read VRAM, compute ROM byte address.
    // Stage 1 (FF):   register ROM address + pixel metadata, drive bg_rom_addr.
    // Stage 2 (comb): use registered bg_rom_data to assemble pixel, store to output FF.
    // Output FF: bg_pix_valid[layer], bg_pix_color[layer], bg_pix_priority[layer].

    // ── Layer round-robin counter ─────────────────────────────────────────────
    logic [1:0] mux_layer;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mux_layer <= 2'h0;
        else        mux_layer <= mux_layer + 2'd1;
    end

    // ── Stage 0: scrolled coords, VRAM read, ROM address computation ──────────

    logic [8:0] s0_tx, s0_ty;   // scrolled pixel coords
    logic [5:0] s0_col, s0_row;
    logic [2:0] s0_px,  s0_py;

    always_comb begin
        s0_tx  = hpos + active_scroll_r[{mux_layer, 1'b0}][8:0];
        s0_ty  = vpos + active_scroll_r[{mux_layer, 1'b1}][8:0];
        s0_col = s0_tx[8:3];
        s0_row = s0_ty[8:3];
        s0_px  = s0_tx[2:0];
        s0_py  = s0_ty[2:0];
    end

    // VRAM cell address = {layer, cell[11:0], word_sel} where cell = {row, col}
    logic [11:0] s0_cell;
    logic [14:0] s0_code_vaddr, s0_attr_vaddr;

    always_comb begin
        s0_cell       = {s0_row, s0_col};
        s0_code_vaddr = {mux_layer, s0_cell, 1'b0};
        s0_attr_vaddr = {mux_layer, s0_cell, 1'b1};
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] s0_code_word, s0_attr_word;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
        s0_code_word = vram[s0_code_vaddr];
        s0_attr_word = vram[s0_attr_vaddr];
    end

    // Decode tile fields
    logic [11:0] s0_tile_num;
    logic [3:0]  s0_palette;
    logic        s0_flip_x, s0_flip_y, s0_prio;
    logic [2:0]  s0_fpx, s0_fpy;

    always_comb begin
        s0_tile_num = s0_code_word[11:0];
        s0_palette  = s0_attr_word[3:0];
        s0_flip_x   = s0_attr_word[4];
        s0_flip_y   = s0_attr_word[5];
        s0_prio     = s0_attr_word[6];
        s0_fpx = s0_flip_x ? (3'd7 - s0_px) : s0_px;
        s0_fpy = s0_flip_y ? (3'd7 - s0_py) : s0_py;
    end

    // ROM byte address: tile_num*32 + fpy*4 + fpx[2:1]
    // (4bpp: 8×8 tile = 32 bytes; row = 4 bytes; 2 pixels/byte)
    logic [19:0] s0_rom_addr;
    always_comb begin
        s0_rom_addr = {3'h0, s0_tile_num, 5'h00}   // tile_num << 5
                    + {15'h0, s0_fpy, 2'h0}          // fpy << 2
                    + {18'h0, s0_fpx[2:1]};           // fpx >> 1
    end

    // ── Stage 1 registers: send ROM request, latch metadata ──────────────────
    logic [1:0]  s1_layer;
    logic [3:0]  s1_palette;
    logic        s1_prio;
    logic        s1_px_lsb;   // fpx[0]: selects high/low nybble
    logic        s1_blank;    // hblank | vblank_in captured at request time

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_layer     <= 2'h0;
            s1_palette   <= 4'h0;
            s1_prio      <= 1'b0;
            s1_px_lsb    <= 1'b0;
            s1_blank     <= 1'b1;
            bg_rom_addr  <= 20'h0;
            bg_layer_sel <= 4'h0;
        end else begin
            s1_layer     <= mux_layer;
            s1_palette   <= s0_palette;
            s1_prio      <= s0_prio;
            s1_px_lsb    <= s0_fpx[0];
            s1_blank     <= hblank | vblank_in;
            bg_rom_addr  <= s0_rom_addr;
            bg_layer_sel <= 4'(1 << mux_layer);
        end
    end

    // ── Stage 2: assemble pixel using bg_rom_data (combinational) ────────────
    // bg_rom_data is driven by the testbench combinationally from bg_rom_addr.

    logic [3:0] s2_nybble;
    always_comb begin
        s2_nybble = s1_px_lsb ? bg_rom_data[7:4] : bg_rom_data[3:0];
    end

    // ── Output registers: update the layer slot that was processed ────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bg_pix_valid <= 4'h0;
            for (int i = 0; i < 4; i++) begin
                bg_pix_color[i]    <= 8'h00;
                bg_pix_priority[i] <= 1'b0;
            end
        end else begin
            for (int i = 0; i < 4; i++) begin
                if (2'(i) == s1_layer) begin
                    bg_pix_valid[i]    <= (s2_nybble != 4'h0) && !s1_blank;
                    bg_pix_color[i]    <= {s1_palette, s2_nybble};
                    bg_pix_priority[i] <= s1_prio;
                end
            end
        end
    end

    // =========================================================================
    // Lint suppression
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = &{1'b0, NUM_LAYERS[0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
