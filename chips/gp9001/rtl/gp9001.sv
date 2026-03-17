`default_nettype none
// =============================================================================
// GP9001 (VDP9001) — Toaplan V2 Graphics Processor
// =============================================================================
//
// Gate 1: CPU interface + register file only.  No rendering.
// Gate 2: Sprite scanner FSM + display list.
//
// Architecture (from MAME src/mame/toaplan/gp9001.cpp, gp9001.h):
//
//   Chip-relative word address space:
//     addr[9:8] == 2'b00  →  control registers  (addr[3:0] selects reg 0–15)
//     addr[9:8] == 2'b01  →  sprite RAM         (addr[9:0] = word index 0–1023)
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
//     0x0F  (reserved)
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
    //   addr[9:8] = 2'b00  → control registers (addr[3:0] selects)
    //   addr[9:8] = 2'b01  → sprite RAM (addr[9:0] = word index 0..1023)
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
    output logic [7:0]    display_list_count,  // number of valid entries (0..255; 256 entries = count wraps — see note)
    output logic          display_list_ready    // 1-cycle pulse when scan done
);

    // =========================================================================
    // Address decode
    // =========================================================================

    logic active_cs;
    logic sel_ctrl;
    logic sel_sram;

    always_comb begin
        active_cs = !cs_n;
        sel_ctrl  = active_cs && (addr[9:8] == 2'b00);
        sel_sram  = active_cs && (addr[9:8] == 2'b01);
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
                // 0xF = reserved
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
        // Default: high-impedance / zero
        dout = 16'h0000;

        if (sel_sram_rd_r) begin
            // Sprite RAM read (registered data, available cycle after request)
            dout = sram_rddata;
        end else if (sel_ctrl && !rd_n) begin
            // Control register read (combinational from shadow)
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
    //
    // Runs during VBLANK.  Reads sprite RAM combinationally (4 words per slot,
    // one slot per clock cycle), builds display_list[], then pulses
    // display_list_ready and irq_sprite.
    //
    // Sprite RAM word layout used by scanner:
    //   Word 0  [8:0]   y_pos       (9-bit; 9'h100 = null/invisible)
    //   Word 1  [9:0]   tile_num;  [10] flip_x;  [11] flip_y;  [15] priority
    //   Word 2  [8:0]   x_pos       (9-bit)
    //   Word 3  [3:0]   palette;   [5:4] size
    //
    // Scan count encoding (sprite_list_len_code = SPRITE_CTRL[15:12]):
    //   0 → 256 slots, 1 → 128, 2 → 64, 3 → 32, ≥4 → 16
    //
    // Sort mode (SPRITE_CTRL[6]):
    //   0 = forward (slot 0 first)
    //   1 = reverse (slot N-1 first → back-to-front priority)
    // =========================================================================

    // FSM state encoding
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

    // ── Number of sprites to scan ─────────────────────────────────────────────
    // The CPU address decode (addr[9:8]==2'b01) makes sprite RAM accessible
    // at sram[256..511], giving 256 words = 64 sprites × 4 words.
    // scan_max is therefore capped at 64.
    //
    // sprite_list_len_code (SPRITE_CTRL[15:12]) encodes the scan count:
    //   0 → 64 (capped at max accessible), 1 → 64, 2 → 64, 3 → 32, ≥4 → 16
    logic [6:0] scan_max;   // 7-bit: max value 64
    always_comb begin
        case (active_sprite_ctrl_r[15:12])
            4'd0:    scan_max = 7'd64;
            4'd1:    scan_max = 7'd64;
            4'd2:    scan_max = 7'd64;
            4'd3:    scan_max = 7'd32;
            default: scan_max = 7'd16;
        endcase
    end

    // ── Scanner state registers ───────────────────────────────────────────────
    logic [5:0]  scan_slot;    // current sprite slot (0..63, 6-bit)
    logic [7:0]  scan_count;   // number of visible entries collected (0..64 max)
    logic        scan_reverse; // latched sort mode

    // ── Combinational reads of current scan_slot's 4 words ───────────────────
    // The CPU writes sprite data to sram[256 + slot*4 + word] (via addr[9:8]=01).
    // The scanner reads from the same addresses:
    //   sram_addr = {2'b01, scan_slot[5:0], 2'b00..11}
    //             = 10'h100 + scan_slot*4 + word
    // This correctly aliases with CPU writes for slots 0..63.
    //
    // Some bits of slot_w0..w3 are not decoded (reserved fields in the sprite
    // format).  Suppress UNUSEDSIGNAL for these upper bits.
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

    // ── Decoded fields from current slot (combinational) ─────────────────────
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
        slot_y        = slot_w0[8:0];
        slot_tile     = slot_w1[9:0];
        slot_flip_x   = slot_w1[10];
        slot_flip_y   = slot_w1[11];
        slot_prio = slot_w1[15];
        slot_x        = slot_w2[8:0];
        slot_palette  = slot_w3[3:0];
        slot_size     = slot_w3[5:4];
        slot_visible  = (slot_y != 9'h100);
    end

    // ── Display list storage (registered) ────────────────────────────────────
    sprite_entry_t display_list_r [0:255];
    logic [7:0]  display_list_count_r;
    logic        display_list_ready_r;

    // Output assignments
    always_comb begin
        for (int i = 0; i < 256; i++) display_list[i] = display_list_r[i];
    end
    assign display_list_count = display_list_count_r;
    assign display_list_ready = display_list_ready_r;

    // ── Scanner FSM ──────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_state           <= S_IDLE;
            scan_slot            <= 6'h00;
            scan_count           <= 8'h00;
            scan_reverse         <= 1'b0;
            display_list_count_r <= 8'h00;
            display_list_ready_r <= 1'b0;
            irq_sprite           <= 1'b0;
            for (int i = 0; i < 256; i++) begin
                display_list_r[i] <= '0;
            end
        end else begin
            // Default: deassert pulse signals every cycle
            display_list_ready_r <= 1'b0;
            irq_sprite           <= 1'b0;

            case (scan_state)

                // ── IDLE: wait for vblank rising edge ─────────────────────
                S_IDLE: begin
                    if (vblank_rise) begin
                        // Clear display list so entries beyond the new count
                        // have valid=0 after this scan completes.
                        for (int i = 0; i < 256; i++) begin
                            display_list_r[i] <= '0;
                        end
                        // Latch sort mode and determine start slot
                        scan_reverse <= active_sprite_ctrl_r[6]; // sprite_sort_mode[0]
                        scan_count   <= 8'h00;
                        if (active_sprite_ctrl_r[6]) begin
                            // Reverse: start from slot scan_max-1
                            scan_slot <= scan_max[5:0] - 6'd1;
                        end else begin
                            // Forward: start from slot 0
                            scan_slot <= 6'h00;
                        end
                        scan_state <= S_SCAN;
                    end
                end

                // ── SCAN: process one slot per clock cycle ────────────────
                // scan_count is at most scan_max (≤64); no overflow possible.
                S_SCAN: begin
                    // Collect visible sprite
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

                    // Advance slot or transition to DONE
                    if (scan_reverse) begin
                        // Reverse: decrement; done when slot 0 has been processed
                        if (scan_slot == 6'h00) begin
                            scan_state <= S_DONE;
                        end else begin
                            scan_slot <= scan_slot - 6'd1;
                        end
                    end else begin
                        // Forward: done when current slot == scan_max - 1
                        if ({1'b0, scan_slot} == (scan_max - 7'd1)) begin
                            scan_state <= S_DONE;
                        end else begin
                            scan_slot <= scan_slot + 6'd1;
                        end
                    end
                end

                // ── DONE: pulse outputs, commit count, return to IDLE ─────
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
    // Lint suppression — tie off unused stub signals
    // =========================================================================
    // addr[10] is reserved for future address space expansion.
    // NUM_LAYERS is documentation-only in Gate 1/2.
    logic _unused;
    assign _unused = &{1'b0, NUM_LAYERS[0], addr[10]};

endmodule
