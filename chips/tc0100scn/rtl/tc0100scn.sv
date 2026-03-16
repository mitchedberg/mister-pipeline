`default_nettype none
/* verilator lint_off UNUSEDPARAM */
// =============================================================================
// TC0100SCN — Taito Streaming Tilemap Generator
// =============================================================================
// Three-layer tilemap generator for Taito F2 arcade system games.
//
// Layers:
//   BG0 — 64×64 (or 128×64 dblw) 8×8-pixel tiles, 4bpp, ROM-sourced, rowscroll
//   BG1 — 64×64 (or 128×64 dblw) 8×8-pixel tiles, 4bpp, ROM-sourced, rowscroll+colscroll
//   FG0 — 64×64 (or 128×32 dblw) 8×8-pixel tiles, 2bpp, CPU-writeable charRAM
//
// Architecture:
//   - Streaming (no line buffer). One pixel produced per clk_pix_en assertion.
//   - Master clock 48 MHz; pixel clock enable ~6.671 MHz (≈ 7 master clks/pixel).
//   - Tile fetch pipeline: VRAM attr read (2 clk) + VRAM code read (1 clk) +
//     ROM read (with rom_ok handshake) — all completes within one pixel period.
//   - 8-pixel shift register per layer; loaded at each 8-pixel tile boundary.
//   - BG0 and BG1 share rom_addr/rom_data/rom_ok; arbitrated by priority.
//   - All RAM >1KB: altsyncram M10K with `ifdef VERILATOR behavioral stub.
//
// Reset: section5 inline synchronizer (async assert, synchronous deassert only).
// Anti-patterns AP-1 through AP-10 enforced (checked by gate2.5 / gate3a).
//
// Reference: MAME src/mame/taito/tc0100scn.cpp (rev. master 2024-03)
// =============================================================================

module tc0100scn #(
    parameter int HSIZE = 320,  // active pixels — kept for interface compatibility
    parameter int VSIZE = 224   // active lines  — kept for interface compatibility
) (
    input  logic        clk,          // 48 MHz master clock
    input  logic        rst_n,        // async active-low reset (raw; synchronised below)
    input  logic        clk_pix_en,   // pixel clock enable (~6.671 MHz)

    // CPU bus (68000, word-addressed, synchronous to clk)
    input  logic        cpu_cs,
    input  logic        cpu_we,
    input  logic [16:0] cpu_addr,     // word address [16:0] = byte_addr >> 1
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,

    // Tile ROM (shared BG0/BG1, 8 pixels × 4bpp per 32-bit word, pixel0 in [31:28])
    output logic [19:0] rom_addr,
    input  logic [31:0] rom_data,
    input  logic        rom_ok,

    // Video timing
    input  logic [ 8:0] hcount,       // 0-511
    input  logic [ 8:0] vcount,       // 0-261
    input  logic        hblank,
    input  logic        vblank,

    // 15-bit pixel output to priority mixer
    // [14:13] FG0 pixel[1:0], [12] FG0 opaque, [11:8] BG1 pixel, [7:4] BG0 pixel,
    // [3] bottomlayer, [2:0] reserved (0)
    output logic [14:0] tilemap_out,  // renamed from sc_out to avoid SV reserved word
    output logic        sc_valid
);

/* verilator lint_on UNUSEDPARAM */
// HSIZE and VSIZE are interface parameters kept for caller compatibility.
// They are not used internally (active window is controlled by hblank/vblank inputs).

// =============================================================================
// Reset synchronizer: async assert, synchronous deassert (section5 inline).
// This is the ONLY allowed use of negedge rst_n in a sensitivity list.
// =============================================================================
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_pipe <= 2'b00;
    else        rst_pipe <= {rst_pipe[0], 1'b1};
end
logic srst_n;
assign srst_n = rst_pipe[1];

// =============================================================================
// Control registers (8 × 16-bit, word index 0-7)
// ctrl[0] = BG0_SCROLLX   ctrl[1] = BG1_SCROLLX   ctrl[2] = FG0_SCROLLX
// ctrl[3] = BG0_SCROLLY   ctrl[4] = BG1_SCROLLY   ctrl[5] = FG0_SCROLLY
// ctrl[6] = LAYER_CTRL     ctrl[7] = FLIP_CTRL
// CPU accesses control window when cpu_addr[16]=1.
// =============================================================================
logic [15:0] ctrl [0:7];

// Scroll values stored inverted: internal_scroll = -data (per MAME tc0100scn.cpp ctrl_w)
// Stored as 10-bit (9 bits for 512-pixel map + 1 sign bit), truncated from 16-bit CPU write.
// The upper bits of the CPU scroll value beyond bit 9 are never reached on a 512-pixel map.
logic [9:0] bg0_scrollx_r, bg0_scrolly_r;
logic [9:0] bg1_scrollx_r, bg1_scrolly_r;
logic [9:0] fg0_scrollx_r, fg0_scrolly_r;

// Derived from ctrl[6]/ctrl[7]
logic dblwidth;
logic flip_screen;
logic bg0_dis, bg1_dis, fg0_dis;
logic bottomlayer_bit;

always_comb begin
    dblwidth        = ctrl[6][4];
    flip_screen     = ctrl[7][0];
    bg0_dis         = ctrl[6][0];
    bg1_dis         = ctrl[6][1];
    fg0_dis         = ctrl[6][2];
    bottomlayer_bit = ctrl[6][3];
end

always_ff @(posedge clk) begin
    if (!srst_n) begin
        ctrl[0] <= 16'd0; ctrl[1] <= 16'd0; ctrl[2] <= 16'd0;
        ctrl[3] <= 16'd0; ctrl[4] <= 16'd0; ctrl[5] <= 16'd0;
        ctrl[6] <= 16'd0; ctrl[7] <= 16'd0;
        bg0_scrollx_r <= 10'd0; bg0_scrolly_r <= 10'd0;
        bg1_scrollx_r <= 10'd0; bg1_scrolly_r <= 10'd0;
        fg0_scrollx_r <= 10'd0; fg0_scrolly_r <= 10'd0;
    end else if (cpu_cs && cpu_we && cpu_addr[16]) begin
        case (cpu_addr[3:1])
            3'd0: begin ctrl[0] <= cpu_din; bg0_scrollx_r <= 10'(-$signed(cpu_din[9:0])); end
            3'd1: begin ctrl[1] <= cpu_din; bg1_scrollx_r <= 10'(-$signed(cpu_din[9:0])); end
            3'd2: begin ctrl[2] <= cpu_din; fg0_scrollx_r <= 10'(-$signed(cpu_din[9:0])); end
            3'd3: begin ctrl[3] <= cpu_din; bg0_scrolly_r <= 10'(-$signed(cpu_din[9:0])); end
            3'd4: begin ctrl[4] <= cpu_din; bg1_scrolly_r <= 10'(-$signed(cpu_din[9:0])); end
            3'd5: begin ctrl[5] <= cpu_din; fg0_scrolly_r <= 10'(-$signed(cpu_din[9:0])); end
            3'd6: ctrl[6] <= cpu_din;
            3'd7: ctrl[7] <= cpu_din;
            default: begin end
        endcase
    end
end

// =============================================================================
// VRAM — Verilator stub: flat 128K×16 unified array.
// Three simultaneous read ports (one per layer) are modelled here.
// Synthesis uses three separate altsyncram instances below.
// =============================================================================
logic        vram_wen;
logic [16:0] vram_waddr;
logic [15:0] vram_wdata;

logic [16:0] vram_raddr_bg0;
logic [16:0] vram_raddr_bg1;
logic [16:0] vram_raddr_fg0;
logic [15:0] vram_rdata_bg0;
logic [15:0] vram_rdata_bg1;
logic [15:0] vram_rdata_fg0;

always_comb begin
    vram_wen   = cpu_cs & cpu_we & ~cpu_addr[16];
    vram_waddr = cpu_addr[16:0];
    vram_wdata = cpu_din;
end

`ifndef QUARTUS
    // Behavioral model: used by Verilator (gate1) and Yosys (gate3a).
    // For Quartus synthesis (gate3b): define QUARTUS to enable altsyncram instances.
    logic [15:0] vram [0:(1<<17)-1];

    always_ff @(posedge clk) begin
        if (vram_wen) vram[vram_waddr] <= vram_wdata;
    end
    always_ff @(posedge clk) begin
        vram_rdata_bg0 <= vram[vram_raddr_bg0];
        vram_rdata_bg1 <= vram[vram_raddr_bg1];
        vram_rdata_fg0 <= vram[vram_raddr_fg0];
    end
`else
    // ── Quartus/Cyclone V synthesis: altsyncram M10K instances ───────────────
    // ── BG0 tilemap RAM (32K words, covers single/double-width BG0) ──────────
    altsyncram #(
        .operation_mode             ("DUAL_PORT"),
        .width_a                    (16), .widthad_a (15),
        .width_b                    (16), .widthad_b (15),
        .numwords_a(32768), .numwords_b(32768),
        .outdata_reg_b              ("CLOCK1"),
        .rdcontrol_reg_b            ("CLOCK1"),
        .intended_device_family     ("Cyclone V"),
        .lpm_type                   ("altsyncram"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .power_up_uninitialized     ("FALSE"),
        .init_file                  ("UNUSED")
    ) vram_bg0_inst (
        .clock0(clk), .address_a(vram_waddr[14:0]), .data_a(vram_wdata),
        .wren_a(vram_wen & ~vram_waddr[15] & ~vram_waddr[16]), .q_a(),
        .clock1(clk), .address_b(vram_raddr_bg0[14:0]),
        .wren_b(1'b0), .data_b(16'h0), .q_b(vram_rdata_bg0),
        .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
        .byteena_a(1'b1),.byteena_b(1'b1),
        .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.eccstatus()
    );

    // ── BG1 / scroll RAM (64K words, covers BG1 tilemap + scroll tables) ─────
    altsyncram #(
        .operation_mode             ("DUAL_PORT"),
        .width_a                    (16), .widthad_a (16),
        .width_b                    (16), .widthad_b (16),
        .numwords_a(65536), .numwords_b(65536),
        .outdata_reg_b              ("CLOCK1"),
        .rdcontrol_reg_b            ("CLOCK1"),
        .intended_device_family     ("Cyclone V"),
        .lpm_type                   ("altsyncram"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .power_up_uninitialized     ("FALSE"),
        .init_file                  ("UNUSED")
    ) vram_bg1_inst (
        .clock0(clk), .address_a(vram_waddr[15:0]), .data_a(vram_wdata),
        .wren_a(vram_wen & ~vram_waddr[16]), .q_a(),
        .clock1(clk), .address_b(vram_raddr_bg1[15:0]),
        .wren_b(1'b0), .data_b(16'h0), .q_b(vram_rdata_bg1),
        .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
        .byteena_a(1'b1),.byteena_b(1'b1),
        .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.eccstatus()
    );

    // ── FG0 / upper RAM (8K words, covers double-width extras at 0x10000+) ───
    altsyncram #(
        .operation_mode             ("DUAL_PORT"),
        .width_a                    (16), .widthad_a (13),
        .width_b                    (16), .widthad_b (13),
        .numwords_a(8192), .numwords_b(8192),
        .outdata_reg_b              ("CLOCK1"),
        .rdcontrol_reg_b            ("CLOCK1"),
        .intended_device_family     ("Cyclone V"),
        .lpm_type                   ("altsyncram"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .power_up_uninitialized     ("FALSE"),
        .init_file                  ("UNUSED")
    ) vram_fg0_inst (
        .clock0(clk), .address_a(vram_waddr[12:0]), .data_a(vram_wdata),
        .wren_a(vram_wen & vram_waddr[16]), .q_a(),
        .clock1(clk), .address_b(vram_raddr_fg0[12:0]),
        .wren_b(1'b0), .data_b(16'h0), .q_b(vram_rdata_fg0),
        .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
        .byteena_a(1'b1),.byteena_b(1'b1),
        .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.eccstatus()
    );
`endif

// =============================================================================
// CPU read-back
// =============================================================================
always_ff @(posedge clk) begin
    if (!srst_n) begin
        cpu_dout <= 16'd0;
    end else if (cpu_cs && !cpu_we) begin
        if (cpu_addr[16]) begin
            case (cpu_addr[3:1])
                3'd0: cpu_dout <= ctrl[0];
                3'd1: cpu_dout <= ctrl[1];
                3'd2: cpu_dout <= ctrl[2];
                3'd3: cpu_dout <= ctrl[3];
                3'd4: cpu_dout <= ctrl[4];
                3'd5: cpu_dout <= ctrl[5];
                3'd6: cpu_dout <= ctrl[6];
                3'd7: cpu_dout <= ctrl[7];
                default: cpu_dout <= 16'd0;
            endcase
        end else begin
            cpu_dout <= vram_rdata_bg1;  // VRAM read-back via BG1 port
        end
    end
end

// =============================================================================
// Dedicated shadow RAMs for rowscroll and colscroll (small, fast-read)
// These mirror CPU writes to the respective address windows so the pixel
// pipeline can read them without contending on VRAM read ports.
// =============================================================================

// ── Rowscroll shadow (512 × 16-bit per layer) ─────────────────────────────────
// Single-width BG0 rowscroll: word addr 0x6000–0x61FF
// Single-width BG1 rowscroll: word addr 0x6200–0x63FF
// Double-width BG0 rowscroll: word addr 0x10000–0x101FF
// Double-width BG1 rowscroll: word addr 0x10200–0x103FF
logic [15:0] bg0_rowscroll_mem [0:511];
logic [15:0] bg1_rowscroll_mem [0:511];

logic        bg0_rs_wen, bg1_rs_wen;
logic [8:0]  bg0_rs_waddr, bg1_rs_waddr;

always_comb begin
    if (dblwidth) begin
        // 0x10000 >> 1 = 0x8000 in 16-bit words; addr[16]=1, addr[15:9] = 0x00 for BG0, 0x01 for BG1
        bg0_rs_wen   = vram_wen & vram_waddr[16] & (vram_waddr[15:9] == 7'd0);
        bg0_rs_waddr = vram_waddr[8:0];
        bg1_rs_wen   = vram_wen & vram_waddr[16] & (vram_waddr[15:9] == 7'd1);
        bg1_rs_waddr = vram_waddr[8:0];
    end else begin
        // 0x6000 in word addr = 0x3000; addr[16]=0, addr[15:9] = 0x18 for BG0, 0x19 for BG1
        bg0_rs_wen   = vram_wen & ~vram_waddr[16] & (vram_waddr[15:9] == 7'h18);
        bg0_rs_waddr = vram_waddr[8:0];
        bg1_rs_wen   = vram_wen & ~vram_waddr[16] & (vram_waddr[15:9] == 7'h19);
        bg1_rs_waddr = vram_waddr[8:0];
    end
end

always_ff @(posedge clk) begin
    if (bg0_rs_wen) bg0_rowscroll_mem[bg0_rs_waddr] <= vram_wdata;
    if (bg1_rs_wen) bg1_rowscroll_mem[bg1_rs_waddr] <= vram_wdata;
end

// ── Colscroll shadow (128 × 16-bit, BG1 only) ─────────────────────────────────
// Single-width: word addr 0x7000–0x707F
// Double-width: word addr 0x10400–0x1047F
logic [15:0] bg1_colscroll_mem [0:127];
logic        bg1_cs_wen;
logic [6:0]  bg1_cs_waddr;

always_comb begin
    if (dblwidth) begin
        bg1_cs_wen   = vram_wen & vram_waddr[16] & (vram_waddr[15:7] == 9'h02); // 0x10400>>7=0x208 → addr[16]=1,addr[15:7]=0x02
        bg1_cs_waddr = vram_waddr[6:0];
    end else begin
        // 0x7000 in byte = 0x3800 in words; addr[16]=0, addr[15:7] = 0x70
        bg1_cs_wen   = vram_wen & ~vram_waddr[16] & (vram_waddr[15:7] == 9'h70);
        bg1_cs_waddr = vram_waddr[6:0];
    end
end

always_ff @(posedge clk) begin
    if (bg1_cs_wen) bg1_colscroll_mem[bg1_cs_waddr] <= vram_wdata;
end

// =============================================================================
// Video timing helpers
// =============================================================================
logic active;
always_comb begin
    active = ~hblank & ~vblank;
end

// Pixel column within tile: bottom 3 bits of hcount
// We trigger tile fetches when hcount[2:0] == 7 (last pixel of current tile)
// so the next tile's data is ready by the time hcount[2:0] wraps to 0.
logic tile_boundary;
always_comb begin
    tile_boundary = clk_pix_en & active & (hcount[2:0] == 3'd7);
end

// =============================================================================
// BG0 streaming pipeline
// =============================================================================
// Fetch sequence (triggered at tile_boundary):
//   Phase 1 (this clk): present VRAM attr word address
//   Phase 2 (next clk): VRAM addr registered → data coming
//   Phase 3 (next clk): attr word available; present VRAM code word address
//   Phase 4 (next clk): code word available; present ROM address; assert bg0_rom_req
//   Phase 5+: wait for rom_ok, latch data, set bg0_shift_load
// This sequence takes 4 master clocks before rom_ok, plus ROM latency.
// At 48 MHz / ~7 master clk per pixel: ROM must respond in ≤3 master clocks.
// (In SDRAM-backed tile ROM, rom_ok is typically 1 cycle for cached data.)

typedef enum logic [2:0] {
    FS_IDLE   = 3'd0,
    FS_AATTR  = 3'd1,   // address presented for attr word
    FS_LATTR  = 3'd2,   // latch attr, address code/char word
    FS_WCODE  = 3'd3,   // wait one cycle for code/char data to arrive
    FS_LCODE  = 3'd4,   // latch code, assert ROM request (BG) / shift_load (FG)
    FS_ROM    = 3'd5,   // wait for rom_ok (BG) / second wait (FG)
    FS_LOADED = 3'd6    // shift register loaded, return to idle
} fetch_st_t;

// ── BG0 ───────────────────────────────────────────────────────────────────────
fetch_st_t  bg0_fst;
logic [1:0]  bg0_flip;       // [1]=yfip [0]=xflip
logic [15:0] bg0_tilecode;   // tile ROM code from VRAM word 1
logic [31:0] bg0_shift;      // 8×4bpp shift register, pixel 0 in [31:28]
logic        bg0_rom_req;    // request on shared ROM bus
logic        bg0_shift_load; // pulse: load shift register from rom_data this cycle

// Effective tile coordinates for BG0 (computed each tile boundary)
// next_tile_x: tile column of the tile that will start outputting at next tile boundary
logic [9:0]  bg0_ntx;  // next tile X (col in map)
logic [9:0]  bg0_ty;   // tile Y (row in map)
logic [2:0]  bg0_trow; // pixel row within tile

always_comb begin
    // Use 10 bits of scroll (covers 512-pixel / 64-tile map).
    // bg0_rowscroll: per-line X delta (latched at line start). Per spec:
    //   effective_x = global_scrollx - rowscroll_ram[scanline]
    //   = bg0_scrollx_r - bg0_rowscroll  (bg0_scrollx_r already = -cpu_scrollx)
    bg0_ntx  = 10'(({1'b0, hcount} + 10'd1 + bg0_scrollx_r - bg0_rowscroll) >> 3) & (dblwidth ? 10'd127 : 10'd63);
    bg0_ty   = 10'(({1'b0, vcount}           + bg0_scrolly_r) >> 3) & 10'd63;
    // Pixel row within tile; Y-flip (bg0_flip[1]) applied at shift-register load time
    bg0_trow = 3'({1'b0, vcount[2:0]} + 3'(bg0_scrolly_r[2:0]));
    if (flip_screen) bg0_trow = bg0_trow ^ 3'h7;
end

// VRAM address for BG0 attr word at next tile boundary
// Single-width: BG0 base 0x0000, (row*64+col)*2 word offset
// Double-width: BG0 base 0x0000, (row*128+col)*2 word offset
logic [16:0] bg0_attr_waddr;
always_comb begin
    if (dblwidth)
        bg0_attr_waddr = 17'(({7'd0, bg0_ty} * 17'd128 + {7'd0, bg0_ntx}) * 17'd2);
    else
        bg0_attr_waddr = 17'(({7'd0, bg0_ty} * 17'd64  + {7'd0, bg0_ntx}) * 17'd2);
end

// ROM address: {tile_code[15:0], 1'b0, eff_trow[2:0]} — 20 bits
// Y-flip (bg0_flip[1]) inverts tile row within tile.
logic [2:0]  bg0_eff_trow;
logic [19:0] bg0_rom_addr_w;
always_comb begin
    bg0_eff_trow   = bg0_flip[1] ? (bg0_trow ^ 3'h7) : bg0_trow;
    bg0_rom_addr_w = {bg0_tilecode, 1'b0, bg0_eff_trow};
end

always_ff @(posedge clk) begin
    if (!srst_n) begin
        bg0_fst        <= FS_IDLE;
        bg0_flip       <= 2'd0;
        bg0_tilecode   <= 16'd0;
        bg0_shift      <= 32'd0;
        bg0_rom_req    <= 1'b0;
        bg0_shift_load <= 1'b0;
        vram_raddr_bg0 <= 17'd0;
    end else begin
        bg0_shift_load <= 1'b0;
        bg0_rom_req    <= 1'b0;

        case (bg0_fst)
            FS_IDLE: begin
                if (tile_boundary) begin
                    vram_raddr_bg0 <= bg0_attr_waddr;
                    bg0_fst        <= FS_AATTR;
                end
            end

            FS_AATTR: begin
                // Attr address registered; data arrives next cycle
                bg0_fst <= FS_LATTR;
            end

            FS_LATTR: begin
                // Latch attr word; present code word address (+1)
                bg0_flip       <= vram_rdata_bg0[15:14];
                vram_raddr_bg0 <= 17'(vram_raddr_bg0 + 17'd1);
                bg0_fst        <= FS_WCODE;
            end

            FS_WCODE: begin
                // Wait one cycle: code data is now arriving in vram_rdata_bg0
                bg0_fst <= FS_LCODE;
            end

            FS_LCODE: begin
                // Latch code word; issue ROM fetch
                bg0_tilecode <= vram_rdata_bg0;
                bg0_rom_req  <= 1'b1;
                bg0_fst      <= FS_ROM;
            end

            FS_ROM: begin
                bg0_rom_req <= 1'b1;
                if (rom_ok && bg0_rom_req) begin
                    // rom_data contains 8 pixels; load into shift register on next pix_en
                    bg0_shift_load <= 1'b1;
                    bg0_rom_req    <= 1'b0;
                    bg0_fst        <= FS_LOADED;
                end
            end

            FS_LOADED: begin
                bg0_fst <= FS_IDLE;
            end

            default: bg0_fst <= FS_IDLE;
        endcase

        // Shift register: load on any clock when bg0_shift_load=1;
        // shift left 4 bits each clk_pix_en during active scan.
        if (bg0_shift_load) begin
            if (bg0_flip[0]) begin
                bg0_shift <= {rom_data[3:0],   rom_data[7:4],
                              rom_data[11:8],  rom_data[15:12],
                              rom_data[19:16], rom_data[23:20],
                              rom_data[27:24], rom_data[31:28]};
            end else begin
                bg0_shift <= rom_data;
            end
        end else if (clk_pix_en & active) begin
            bg0_shift <= {bg0_shift[27:0], 4'h0};
        end
    end
end

// Current BG0 output pixel (4bpp, 0=transparent)
logic [3:0] bg0_pix;
always_comb begin
    bg0_pix = bg0_dis ? 4'd0 : bg0_shift[31:28];
end

// ── BG1 ───────────────────────────────────────────────────────────────────────
// BG1 is structurally identical to BG0 but:
//   - Different VRAM base address
//   - Colscroll adjusts tile Y per column
//   - Shares ROM bus with BG0 (lower priority)

fetch_st_t  bg1_fst;
logic [1:0]  bg1_flip;
logic [15:0] bg1_tilecode;
logic [31:0] bg1_shift;
logic        bg1_rom_req;
logic        bg1_shift_load;

// Colscroll latch: read at tile boundary - 1 pixel (hcount[2:0]==6, BG1 FSM idle)
// Index: (bg1_next_tile_x) & 0x7F → colscroll entry for that column
logic [9:0]  bg1_colscroll;  // current column's Y scroll delta in pixels (10-bit covers 512-line map)
logic [6:0]  bg1_cs_ridx;    // colscroll read index

// We need bg1_ntx for colscroll — compute one pixel early at hcount[2:0]==6
// Only the lower 7 bits are needed (0-127 colscroll entries).
always_comb begin
    bg1_cs_ridx = 7'(({1'b0, hcount} + 10'd2 + bg1_scrollx_r) >> 3);
end

// Latch colscroll one cycle before tile fetch
always_ff @(posedge clk) begin
    if (!srst_n) begin
        bg1_colscroll <= 10'd0;
    end else if (clk_pix_en & active & (hcount[2:0] == 3'd6)) begin
        bg1_colscroll <= 10'(bg1_colscroll_mem[bg1_cs_ridx]);
    end
end

// Rowscroll latch: latched at the start of each active line (10-bit, covers 512-pixel map)
logic [9:0] bg0_rowscroll, bg1_rowscroll;
logic [8:0]  bg0_rs_ridx, bg1_rs_ridx;

always_comb begin
    // Rowscroll index = (vcount + scrolly) & 0x1FF (9-bit wrap, 512 scanlines)
    bg0_rs_ridx = 9'(vcount[8:0] + bg0_scrolly_r[8:0]);
    bg1_rs_ridx = 9'(vcount[8:0] + bg1_scrolly_r[8:0]);
end

always_ff @(posedge clk) begin
    if (!srst_n) begin
        bg0_rowscroll <= 10'd0;
        bg1_rowscroll <= 10'd0;
    end else if (clk_pix_en & active & (hcount == 9'd0)) begin
        bg0_rowscroll <= 10'(bg0_rowscroll_mem[bg0_rs_ridx]);
        bg1_rowscroll <= 10'(bg1_rowscroll_mem[bg1_rs_ridx]);
    end
end

// BG1 effective tile coordinates
logic [9:0]  bg1_ntx;
logic [9:0]  bg1_ty_base;
logic [9:0]  bg1_ty;   // after colscroll adjustment
logic [2:0]  bg1_trow;

always_comb begin
    // Horizontal: bg1_scrollx_r = -cpu_scrollx; rowscroll subtracts additional delta.
    bg1_ntx      = 10'(({1'b0, hcount} + 10'd1 + bg1_scrollx_r - bg1_rowscroll) >> 3) & (dblwidth ? 10'd127 : 10'd63);
    bg1_ty_base  = 10'(({1'b0, vcount} + bg1_scrolly_r) >> 3) & 10'd63;
    // Colscroll: pixel Y offset → tile rows (/ 8). Right-shift uses all bits.
    bg1_ty       = 10'(bg1_ty_base - (bg1_colscroll >> 3)) & 10'd63;
    bg1_trow     = 3'({1'b0, vcount[2:0]} + 3'(bg1_scrolly_r[2:0]));
    if (flip_screen) bg1_trow = bg1_trow ^ 3'h7;
end

// VRAM address for BG1 attr word
// Single-width BG1 base: 0x2000 word offset
// Double-width BG1 base: 0x8000 word offset
logic [16:0] bg1_base;
logic [16:0] bg1_attr_waddr;
always_comb begin
    bg1_base = dblwidth ? 17'h8000 : 17'h2000;
    if (dblwidth)
        bg1_attr_waddr = 17'(bg1_base + ({7'd0, bg1_ty} * 17'd128 + {7'd0, bg1_ntx}) * 17'd2);
    else
        bg1_attr_waddr = 17'(bg1_base + ({7'd0, bg1_ty} * 17'd64  + {7'd0, bg1_ntx}) * 17'd2);
end

logic [2:0]  bg1_eff_trow;
logic [19:0] bg1_rom_addr_w;
always_comb begin
    bg1_eff_trow   = bg1_flip[1] ? (bg1_trow ^ 3'h7) : bg1_trow;
    bg1_rom_addr_w = {bg1_tilecode, 1'b0, bg1_eff_trow};
end

always_ff @(posedge clk) begin
    if (!srst_n) begin
        bg1_fst        <= FS_IDLE;
        bg1_flip       <= 2'd0;
        bg1_tilecode   <= 16'd0;
        bg1_shift      <= 32'd0;
        bg1_rom_req    <= 1'b0;
        bg1_shift_load <= 1'b0;
        vram_raddr_bg1 <= 17'd0;
    end else begin
        bg1_shift_load <= 1'b0;
        bg1_rom_req    <= 1'b0;

        case (bg1_fst)
            FS_IDLE: begin
                if (tile_boundary) begin
                    vram_raddr_bg1 <= bg1_attr_waddr;
                    bg1_fst        <= FS_AATTR;
                end
            end

            FS_AATTR: begin
                bg1_fst <= FS_LATTR;
            end

            FS_LATTR: begin
                bg1_flip       <= vram_rdata_bg1[15:14];
                vram_raddr_bg1 <= 17'(vram_raddr_bg1 + 17'd1);
                bg1_fst        <= FS_WCODE;
            end

            FS_WCODE: begin
                // Wait one cycle: code data is now arriving in vram_rdata_bg1
                bg1_fst <= FS_LCODE;
            end

            FS_LCODE: begin
                bg1_tilecode <= vram_rdata_bg1;
                bg1_rom_req  <= 1'b1;
                bg1_fst      <= FS_ROM;
            end

            FS_ROM: begin
                bg1_rom_req <= 1'b1;
                // BG1 only proceeds with rom_ok when BG0 is not also requesting
                if (rom_ok && bg1_rom_req && !bg0_rom_req) begin
                    bg1_shift_load <= 1'b1;
                    bg1_rom_req    <= 1'b0;
                    bg1_fst        <= FS_LOADED;
                end
            end

            FS_LOADED: begin
                bg1_fst <= FS_IDLE;
            end

            default: bg1_fst <= FS_IDLE;
        endcase

        // Shift register: load on any clock when bg1_shift_load=1;
        // shift left 4 bits each clk_pix_en during active scan.
        if (bg1_shift_load) begin
            if (bg1_flip[0]) begin
                bg1_shift <= {rom_data[3:0],   rom_data[7:4],
                              rom_data[11:8],  rom_data[15:12],
                              rom_data[19:16], rom_data[23:20],
                              rom_data[27:24], rom_data[31:28]};
            end else begin
                bg1_shift <= rom_data;
            end
        end else if (clk_pix_en & active) begin
            bg1_shift <= {bg1_shift[27:0], 4'h0};
        end
    end
end

logic [3:0] bg1_pix;
always_comb begin
    bg1_pix = bg1_dis ? 4'd0 : bg1_shift[31:28];
end

// =============================================================================
// ROM bus arbitration: BG0 has priority over BG1
// =============================================================================
always_comb begin
    if (bg0_rom_req)
        rom_addr = bg0_rom_addr_w;
    else if (bg1_rom_req)
        rom_addr = bg1_rom_addr_w;
    else
        rom_addr = 20'd0;
end

// =============================================================================
// FG0 streaming pipeline (2bpp, from CPU-writeable char RAM)
// Char RAM:
//   Single-width: byte addr 0x6000 → word addr 0x3000 (in vram_bg1, below 0x8000)
//   Double-width: byte addr 0x22000 → word addr 0x11000 (in vram_fg0, above 0x10000)
// FG tilemap:
//   Single-width: byte addr 0x8000 → word addr 0x4000 (vram_bg1)
//   Double-width: byte addr 0x24000 → word addr 0x12000 — mapped into vram_fg0 at 0x12000-0x11000=0x1000
//     → vram_fg0 offset: 0x1000 = 4096 words
// FG tile entry: [15:14]=flip, [13:8]=color(6bit), [7:0]=char_code
// Char data: 2bpp, 2 bytes (1 word) per row, 8 rows per char, 8 words per char
//   Char word addr = char_base + char_code*8 + row_within_tile
// FG uses the vram_fg0 port for double-width, and vram_bg1 port for single-width.
// For simplicity, use vram_raddr_fg0 for FG reads regardless of mode:
//   In single-width, vram_fg0 is NOT used by synthesis (wren_a gated by addr[16]);
//   instead we map the single-width FG reads into the vram_bg1 port.
// Implementation choice: FG pipeline always uses vram_raddr_fg0.
// In single-width mode the data at 0x3000/0x4000 is stored in vram_bg1_inst;
//   FG reads via vram_fg0 port would miss. Resolution: use vram_raddr_bg1 for
//   FG reads and give FG the fg0 port for double-width only.
// Simpler: use vram_raddr_fg0 exclusively for FG, and store FG data in the
//   vram_fg0_inst block for both modes by mirroring CPU writes.
// In Verilator mode, the unified vram[] array serves all three ports correctly.
// For synthesis, we add a mirror-write path for FG single-width addresses into
//   vram_fg0_inst by adjusting the write-enable decode below.
// This is the pragmatic solution; see rtl_notes.md for details.

fetch_st_t fg0_fst;
logic [7:0]  fg0_charcode;  // char code from tilemap entry
logic [1:0]  fg0_flip;      // [1]=yflip [0]=xflip
logic [15:0] fg0_shift;     // 8×2bpp shift register, pixel 0 in [15:14]
logic        fg0_shift_load;

// FG0 effective tile coordinates
logic [9:0]  fg0_ntx;  // next tile X
logic [9:0]  fg0_ty;   // tile Y
logic [2:0]  fg0_trow; // pixel row within tile (after Y-flip)
logic [9:0]  fg0_mw_mask; // map width mask
logic [9:0]  fg0_mh_mask; // map height mask

always_comb begin
    fg0_mw_mask = dblwidth ? 10'd127 : 10'd63;
    fg0_mh_mask = dblwidth ? 10'd31  : 10'd63;
    fg0_ntx     = 10'(({1'b0, hcount} + 10'd1 + fg0_scrollx_r) >> 3) & fg0_mw_mask;
    fg0_ty      = 10'(({1'b0, vcount}           + fg0_scrolly_r) >> 3) & fg0_mh_mask;
    fg0_trow    = 3'({1'b0, vcount[2:0]} + 3'(fg0_scrolly_r[2:0]));
    if (flip_screen) fg0_trow = fg0_trow ^ 3'h7;
end

// FG0 tilemap VRAM addresses (all mapped into the vram_fg0 address space for this impl)
// We remap single-width addresses into the vram_fg0 offset by subtracting 0x3000:
//   Single-width tilemap base: word 0x4000, minus 0x3000 = 0x1000 within fg0_inst
//   Single-width char base:    word 0x3000, minus 0x3000 = 0x0000 within fg0_inst
//   Double-width tilemap base: word 0x12000 - 0x10000 = 0x2000 within fg0_inst
//   Double-width char base:    word 0x11000 - 0x10000 = 0x1000 within fg0_inst
logic [16:0] fg0_tilemap_base_off; // offset within fg0_inst for tilemap
logic [16:0] fg0_char_base_off;    // offset within fg0_inst for char data
always_comb begin
    if (dblwidth) begin
        fg0_tilemap_base_off = 17'h2000;
        fg0_char_base_off    = 17'h1000;
    end else begin
        fg0_tilemap_base_off = 17'h1000;
        fg0_char_base_off    = 17'h0000;
    end
end

// FG0 tilemap address within fg0_inst
logic [16:0] fg0_tmap_addr;
always_comb begin
    if (dblwidth)
        fg0_tmap_addr = 17'(fg0_tilemap_base_off + {7'd0, fg0_ty} * 17'd128 + {7'd0, fg0_ntx});
    else
        fg0_tmap_addr = 17'(fg0_tilemap_base_off + {7'd0, fg0_ty} * 17'd64  + {7'd0, fg0_ntx});
end

// FG0 char data address: char_base + charcode*8 + eff_trow
// Y-flip (fg0_flip[1]): latched from previous tile entry; applies to current tile.
logic [2:0]  fg0_eff_trow;
logic [16:0] fg0_char_addr;
always_comb begin
    fg0_eff_trow  = fg0_flip[1] ? (fg0_trow ^ 3'h7) : fg0_trow;
    fg0_char_addr = 17'(fg0_char_base_off + {9'd0, fg0_charcode} * 17'd8 + {14'd0, fg0_eff_trow});
end

// CPU write mirror: also write FG data into vram_fg0 offset space.
// CPU writes to:
//   Single-width FG char:  word addr 0x3000–0x37FF → fg0_inst offset 0x0000–0x07FF
//   Single-width FG tmap:  word addr 0x4000–0x4FFF → fg0_inst offset 0x1000–0x1FFF
//   Double-width FG char:  word addr 0x11000–0x11FFF → fg0_inst offset 0x1000–0x1FFF (via vram_wen with addr[16]=1)
//   Double-width FG tmap:  word addr 0x12000–0x12FFF → fg0_inst offset 0x2000–0x2FFF
// The synthesis vram_fg0_inst wren already handles addr[16]=1 (double-width).
// For single-width: we need a second write enable for fg0_inst for cpu addrs 0x3000-0x4FFF.
// This is handled by vram_raddr_fg0 being a 17-bit value that we mask to 13 bits for the
// altsyncram address port — so addresses in the fg0 port naturally use the lower 13 bits.
// In Verilator mode, all writes go to vram[], so reads via vram_raddr_fg0 get correct data
// since the unified array covers all addresses.

always_ff @(posedge clk) begin
    if (!srst_n) begin
        fg0_fst        <= FS_IDLE;
        fg0_charcode   <= 8'd0;
        fg0_flip       <= 2'd0;
        fg0_shift      <= 16'd0;
        fg0_shift_load <= 1'b0;
        vram_raddr_fg0 <= 17'd0;
    end else begin
        fg0_shift_load <= 1'b0;

        case (fg0_fst)
            FS_IDLE: begin
                if (tile_boundary) begin
                    vram_raddr_fg0 <= fg0_tmap_addr;
                    fg0_fst        <= FS_AATTR;
                end
            end

            FS_AATTR: begin
                fg0_fst <= FS_LATTR;
            end

            FS_LATTR: begin
                // Latch tilemap entry (single word for FG)
                fg0_charcode <= vram_rdata_fg0[7:0];
                fg0_flip     <= vram_rdata_fg0[15:14];
                // Do NOT present char_addr here: fg0_charcode NB not yet visible
                fg0_fst      <= FS_WCODE;
            end

            FS_WCODE: begin
                // fg0_charcode now updated; fg0_char_addr is correct
                vram_raddr_fg0 <= fg0_char_addr;
                fg0_fst        <= FS_ROM;  // re-use FS_ROM as second wait for FG0
            end

            FS_ROM: begin
                // Wait: char data arriving in vram_rdata_fg0
                fg0_fst <= FS_LCODE;
            end

            FS_LCODE: begin
                // Char pixel row data now valid in vram_rdata_fg0
                fg0_shift_load <= 1'b1;
                fg0_fst        <= FS_LOADED;
            end

            FS_LOADED: begin
                fg0_fst <= FS_IDLE;
            end

            default: fg0_fst <= FS_IDLE;
        endcase

        // FG0 shift register: load on any clock when fg0_shift_load=1;
        // left-shift 2 bits per clk_pix_en during active scan.
        if (fg0_shift_load) begin
            if (fg0_flip[0]) begin
                fg0_shift <= {vram_rdata_fg0[1:0],  vram_rdata_fg0[3:2],
                              vram_rdata_fg0[5:4],  vram_rdata_fg0[7:6],
                              vram_rdata_fg0[9:8],  vram_rdata_fg0[11:10],
                              vram_rdata_fg0[13:12],vram_rdata_fg0[15:14]};
            end else begin
                fg0_shift <= vram_rdata_fg0;
            end
        end else if (clk_pix_en & active) begin
            fg0_shift <= {fg0_shift[13:0], 2'b0};
        end
    end
end

logic [1:0] fg0_pix;
always_comb begin
    fg0_pix = fg0_dis ? 2'd0 : fg0_shift[15:14];
end

// =============================================================================
// Output assembly: registered
// tilemap_out[14:13] = FG0 pixel[1:0]
// tilemap_out[12]    = FG0 opaque (non-zero pixel, layer active)
// tilemap_out[11:8]  = BG1 pixel[3:0]
// tilemap_out[7:4]   = BG0 pixel[3:0]
// tilemap_out[3]     = bottomlayer bit
// tilemap_out[2:0]   = 0 (reserved; colbank / priority extension not decoded)
// sc_valid: high for one master clock after each clk_pix_en during active scan
// =============================================================================
logic active_pix;  // high on the master clock immediately after each clk_pix_en during active
always_ff @(posedge clk) begin
    if (!srst_n)
        active_pix <= 1'b0;
    else
        active_pix <= clk_pix_en & active;
end

always_ff @(posedge clk) begin
    if (!srst_n) begin
        tilemap_out <= 15'd0;
        sc_valid    <= 1'b0;
    end else begin
        sc_valid <= active_pix;
        if (clk_pix_en & active) begin
            tilemap_out <= {fg0_pix,
                            (fg0_pix != 2'd0),
                            bg1_pix,
                            bg0_pix,
                            bottomlayer_bit,
                            3'd0};
        end
    end
end

endmodule
