// Psikyo Gate 4 — BG Tilemap Renderer (PS3103)
// Standalone module: per-pixel BG color output for 2 BG layers (BG0, BG1).
//
// Architecture (from GATE_PLAN.md, psikyo.sv, MAME psikyo_gfx.cpp):
//
//   Tile format: 16×16 px, 4bpp, 128 bytes/tile
//     One tile row = 8 bytes (16 pixels, 2 per byte).
//     Byte b: low nibble [3:0] = left pixel, high nibble [7:4] = right pixel.
//     ROM byte addr = tile_num*128 + fpy*8 + fpx[3:1]
//     Nybble select  = fpx[0]  (0=low, 1=high)
//
//   Tilemap: 64×64 tile cells per layer.
//     cell = (row << 6) | col   (12-bit, 0..4095)
//     VRAM word address: {layer[1:0], cell[11:0]}  (14-bit, 16384 words)
//
//   Tilemap entry (single 16-bit word):
//     [15:12] palette    (0..15)
//     [11]    flip_y
//     [10]    flip_x
//     [9:0]   tile_num   (0..1023)
//
//   Scroll registers (from Gate 1 active regs, 16-bit each):
//     [15:8] integer scroll (0..255)
//     [7:0]  fraction (ignored here — integer-only scroll)
//   Scroll range: 0..1023 pixels wrapping (10-bit)
//   Pixel coord wrapping: (hpos + scroll_x) & 0x3FF, same for Y.
//
// Pipeline (2-stage, matching GP9001 Gate 3 structure):
//   Stage 0 (comb): apply scroll, compute tile col/row, pixel-in-tile,
//                   read VRAM, decode tile entry, compute ROM byte address.
//   Stage 1 (FF):   latch ROM address + pixel metadata, drive bg_rom_addr.
//   Stage 2 (comb): apply bg_rom_data → nybble → assemble pixel color.
//   Output FF:      register bg_pix_valid, bg_pix_color, bg_pix_priority.
//
//   One layer processed per clock cycle (round-robin mux_layer 0→1→0...).
//   For 2 layers: update rate = once every 2 clocks per layer (sufficient
//   for per-pixel output when hpos advances 1 pixel per 2+ clocks).
//
// VRAM dual-port:
//   Write port: CPU writes tilemap entries (one word per clock).
//   Read port:  Pixel pipeline reads cells combinationally.
//
// Date: 2026-03-17

/* verilator lint_off UNUSEDSIGNAL */
module psikyo_gate4 (
    input  logic        clk,
    input  logic        rst_n,

    // ── Pixel position (from video timing) ───────────────────────────────────
    input  logic [9:0]  hpos,          // current horizontal pixel (0..319)
    input  logic [8:0]  vpos,          // current vertical pixel  (0..239)
    input  logic        hblank,        // horizontal blanking
    input  logic        vblank,        // vertical blanking

    // ── Scroll registers (from Gate 1 active register file) ──────────────────
    // bg_scroll_x[L][15:8] = integer X scroll for layer L (0..255)
    // bg_scroll_y[L][15:8] = integer Y scroll for layer L (0..255)
    input  logic [1:0][15:0] scroll_x,
    input  logic [1:0][15:0] scroll_y,

    // ── Tilemap VRAM write port (CPU access) ──────────────────────────────────
    // 14-bit address (only [12:0] used; bit 13 selects TileRAM[2] which is ignored here)
    input  logic [13:0] vram_wr_addr,
    input  logic [15:0] vram_wr_data,
    input  logic        vram_wr_en,

    // ── BG tile ROM read port (combinational, zero latency) ───────────────────
    // One 16×16 tile = 128 bytes.
    // Byte addr = tile_num*128 + fpy*8 + fpx[3:1]
    output logic [23:0] bg_rom_addr,   // tile ROM byte address
    output logic        bg_rom_rd,     // read strobe (1 = valid address)
    input  logic [7:0]  bg_rom_data,   // ROM data (combinational, zero latency)

    // ── Layer select output (which layer's ROM request is on bus) ─────────────
    output logic [1:0]  bg_layer_sel,  // one-hot or index: which layer owns bus

    // ── Per-layer pixel outputs ───────────────────────────────────────────────
    output logic [1:0]  bg_pix_valid,          // one bit per layer (2 layers)
    output logic [1:0][7:0]  bg_pix_color,       // {palette[3:0], nybble[3:0]}
    output logic [1:0]  bg_pix_priority        // priority bit per layer
);

    // ── VRAM: 8192 × 16-bit (13-bit address: {layer[0], cell[11:0]}) ───────────
    // 2 layers × 4096 cells = 8192 words.
    // The vram_wr_addr input is 14 bits wide for forward compatibility, but only
    // the lower 13 bits are used.

`ifdef QUARTUS
    // altsyncram DUAL_PORT: write port A = vram_wr_en, read port B = s0_vaddr (registered)
    // Adds 1 pipeline stage to tile fetch (acceptable for synthesis CI).
    logic [15:0] s0_entry;
    altsyncram #(
        .operation_mode            ("DUAL_PORT"),
        .width_a                   (16), .widthad_a (13), .numwords_a (8192),
        .width_b                   (16), .widthad_b (13), .numwords_b (8192),
        .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
        .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
        .clock_enable_output_b     ("BYPASS"),
        .intended_device_family    ("Cyclone V"),
        .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
        .power_up_uninitialized    ("FALSE"),
        .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
    ) vram_inst (
        .clock0(clk), .clock1(clk),
        .address_a(vram_wr_addr[12:0]), .data_a(vram_wr_data), .wren_a(vram_wr_en),
        .address_b(s0_vaddr), .q_b(s0_entry),
        .wren_b(1'b0), .data_b(16'd0), .q_a(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
    );
`else
    logic [15:0] vram [0:8191];

    // Write port (synchronous): only [12:0] used; bit 13 selects TileRAM[2] (ignored)
    always_ff @(posedge clk) begin
        if (vram_wr_en && !vram_wr_addr[13])
            vram[vram_wr_addr[12:0]] <= vram_wr_data;
    end
`endif

    // ── Layer round-robin counter (0 → 1 → 0 → ...) ──────────────────────────

    logic mux_layer;   // 1-bit: 0 or 1

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mux_layer <= 1'b0;
        else        mux_layer <= ~mux_layer;
    end

    // ── Stage 0: scrolled coordinates, VRAM read, ROM address ────────────────

    // Scroll: integer part is [15:8]; tile coord wraps in 10-bit space (64×16=1024).
    logic [9:0] s0_tx, s0_ty;   // scrolled pixel coords (10-bit, wrapping 0..1023)
    logic [5:0] s0_col, s0_row; // tile column/row (0..63)
    logic [3:0] s0_px,  s0_py;  // pixel within tile (0..15)

    always_comb begin
        s0_tx  = (10'(hpos) + 10'(scroll_x[mux_layer][15:8])) & 10'h3FF;
        s0_ty  = (10'(vpos) + 10'(scroll_y[mux_layer][15:8])) & 10'h3FF;
        s0_col = s0_tx[9:4];    // tile column = scrolled_x >> 4
        s0_row = s0_ty[9:4];    // tile row    = scrolled_y >> 4
        s0_px  = s0_tx[3:0];    // pixel X within tile (0..15)
        s0_py  = s0_ty[3:0];    // pixel Y within tile (0..15)
    end

    // VRAM cell address: {layer[0], row[5:0], col[5:0]} = 1+6+6 = 13 bits
    // Full VRAM address: {layer, cell[11:0]} where cell = {row, col}
    logic [11:0] s0_cell;
    logic [12:0] s0_vaddr;
`ifndef QUARTUS
    logic [15:0] s0_entry;
`endif

    always_comb begin
        s0_cell  = {s0_row, s0_col};
        s0_vaddr = {mux_layer, s0_cell};
`ifndef QUARTUS
        s0_entry = vram[s0_vaddr];
`endif
    end

    // Decode tilemap entry: [15:12]=palette, [11]=flip_y, [10]=flip_x, [9:0]=tile_num
    logic [3:0]  s0_palette;
    logic        s0_flip_y, s0_flip_x;
    logic        s0_prio;     // priority bit: use palette[3] as a proxy or define separately
    logic [9:0]  s0_tile_num;
    logic [3:0]  s0_fpx, s0_fpy;

    always_comb begin
        s0_palette  = s0_entry[15:12];
        s0_flip_y   = s0_entry[11];
        s0_flip_x   = s0_entry[10];
        // Priority: use bit [12] of palette field (palette[0] MSB) as priority,
        // or derive from the layer's bg_priority register.  For standalone module,
        // expose a simple priority: palette[3] (the MSB of palette).
        // This matches GATE_PLAN: priority[5:4] = layer priority bits.
        s0_prio     = s0_entry[15];   // palette[3] = MSB of palette field
        s0_tile_num = s0_entry[9:0];

        // Apply flip
        s0_fpx = s0_flip_x ? (4'd15 - s0_px) : s0_px;
        s0_fpy = s0_flip_y ? (4'd15 - s0_py) : s0_py;
    end

    // ROM byte address for a 16×16 tile (128 bytes/tile):
    //   addr = tile_num * 128 + fpy * 8 + fpx[3:1]
    //   nybble select = fpx[0]
    logic [23:0] s0_rom_addr;
    always_comb begin
        s0_rom_addr = 24'(s0_tile_num) * 24'd128   // tile_num << 7
                    + 24'(s0_fpy)       * 24'd8     // fpy << 3
                    + 24'(s0_fpx[3:1]);              // fpx >> 1
    end

    // ── Stage 1 registers: drive ROM address, latch pixel metadata ───────────

    logic        s1_layer;
    logic [3:0]  s1_palette;
    logic        s1_prio;
    logic        s1_px_lsb;   // fpx[0]: selects high/low nybble in ROM byte
    logic        s1_blank;    // blanking captured at request time

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_layer    <= 1'b0;
            s1_palette  <= 4'h0;
            s1_prio     <= 1'b0;
            s1_px_lsb   <= 1'b0;
            s1_blank    <= 1'b1;
            bg_rom_addr <= 24'h0;
            bg_layer_sel <= 2'h0;
        end else begin
            s1_layer     <= mux_layer;
            s1_palette   <= s0_palette;
            s1_prio      <= s0_prio;
            s1_px_lsb    <= s0_fpx[0];
            s1_blank     <= hblank | vblank;
            bg_rom_addr  <= s0_rom_addr;
            bg_layer_sel <= 2'(1 << mux_layer);
        end
    end

    // ROM read strobe: always active (pipeline always running)
    assign bg_rom_rd = 1'b1;

    // ── Stage 2: assemble pixel from ROM data (combinational) ─────────────────

    logic [3:0] s2_nybble;
    always_comb begin
        // fpx[0]=0 → low nybble = left pixel; fpx[0]=1 → high nybble = right pixel
        s2_nybble = s1_px_lsb ? bg_rom_data[7:4] : bg_rom_data[3:0];
    end

    // ── Output registers: update the layer slot that was processed ────────────

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bg_pix_valid <= 2'h0;
            bg_pix_color[0]    <= 8'h00;
            bg_pix_color[1]    <= 8'h00;
            bg_pix_priority[0] <= 1'b0;
            bg_pix_priority[1] <= 1'b0;
        end else begin
            // Update whichever layer slot Stage 1 was processing
            if (s1_layer == 1'b0) begin
                bg_pix_valid[0]    <= (s2_nybble != 4'h0) && !s1_blank;
                bg_pix_color[0]    <= {s1_palette, s2_nybble};
                bg_pix_priority[0] <= s1_prio;
            end else begin
                bg_pix_valid[1]    <= (s2_nybble != 4'h0) && !s1_blank;
                bg_pix_color[1]    <= {s1_palette, s2_nybble};
                bg_pix_priority[1] <= s1_prio;
            end
        end
    end

endmodule
/* verilator lint_on UNUSEDSIGNAL */
