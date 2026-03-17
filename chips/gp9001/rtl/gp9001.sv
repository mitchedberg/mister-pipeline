`default_nettype none
// =============================================================================
// GP9001 (VDP9001) — Toaplan V2 Graphics Processor
// =============================================================================
//
// Gate 1: CPU interface + register file only.  No rendering.
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
// =============================================================================

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
    output logic        irq_sprite,  // pulsed when sprite list is ready (Gate 2+)

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

    // ── Sprite RAM scanner read port (tied off for Gate 1) ───────────────────
    input  logic [9:0]  scan_addr,
    output logic [15:0] scan_dout
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

    // ── irq_sprite — Gate 2+ only, drive low for now ─────────────────────────
    assign irq_sprite = 1'b0;

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

    // Scanner read port — combinational async
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
    // Lint suppression — tie off unused stub signals
    // =========================================================================
    // addr[10] is reserved for future address space expansion (not decoded in Gate 1).
    // NUM_LAYERS is a parameter used for documentation purposes only in Gate 1.
    logic _unused;
    assign _unused = &{1'b0, NUM_LAYERS[0], addr[10]};

endmodule
