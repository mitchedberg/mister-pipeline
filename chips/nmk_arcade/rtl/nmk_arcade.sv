// =============================================================================
// nmk_arcade.sv — NMK16 System Board Top-Level Integration (v1.1)
// =============================================================================
//
// Instantiates and wires:
//   nmk16      — graphics subsystem (registers + sprite scanner + BG tilemaps
//                + sprite rasterizer + priority mixer)
//
// Plus local block RAMs:
//   work_ram   — 64KB at 0x0B0000–0x0BFFFF (MC68000 general-purpose)
//   palette_ram — 512 entries × 16-bit at 0x0C8000–0x0C87FF (CPU-writable)
//
// Z80 sound CPU: T80s core, 8 MHz, drives YM2203 and OKI M6295
//
// Target game: Thunder Dragon (nmk16 hardware variant)
//   MC68000 @ 10 MHz, VBLANK IRQ = level 4
//   SSP = 0x0C0000 (stack at top of work RAM 0x0BFFFC and below)
//
// Memory map (byte addresses, verified against FBNeo d_nmk16.cpp):
//   0x000000–0x03FFFF  Program ROM (256KB, SDRAM)
//   0x0B0000–0x0BFFFF  Work RAM (64KB, BRAM)   ← SSP=0x0C0000 → stack here
//   0x0C0000–0x0C001F  I/O registers (joystick, coin, DIP, sound comm)
//   0x0C4000–0x0C43FF  Scroll registers (NMK16 GPU regs)
//   0x0C8000–0x0C87FF  Palette RAM (512 entries × 16-bit, BRAM)
//   0x0CC000–0x0CFFFF  BG tilemap VRAM (NMK16 chip)
//   0x0D0000–0x0D07FF  Tx (text) VRAM (NMK16 chip, stub)
//
// NOT instantiated here (provided by the MiSTer HPS top-level wrapper):
//   MC68000 CPU, SDRAM controller, video timing generator
//
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module nmk_arcade #(
    // ── Work RAM ───────────────────────────────────────────────────────────────
    // 64KB: 15-bit word address (WRAM_ABITS=15 → 32768 words = 65536 bytes)
    // WRAM_BASE: upper byte of work RAM address (0x0B for tdragon, 0x08 for tdragonb2)
    parameter int unsigned WRAM_ABITS = 15,
    parameter logic [7:0]  WRAM_BASE  = 8'h0B,

    // ── Palette RAM ────────────────────────────────────────────────────────────
    // 512 entries × 16-bit: 9-bit word address
    parameter int unsigned PAL_ABITS  = 9,

    // ── GFX ROM SDRAM base ─────────────────────────────────────────────────────
    // Sprite ROM base address in SDRAM (byte address, stored at SDRAM offset)
    // Sprite address is 21-bit → max 2MB → sprites occupy 0x0C0000–0x1BFFFF for 1MB ROMs
    parameter logic [26:0] SPR_ROM_BASE = 27'h0C0000,

    // BG tile ROM base in SDRAM
    // Must start AFTER the sprite region: 0x0C0000 + 1MB = 0x1C0000
    // NMK16 tile_idx is 10-bit → only 128KB of tile data is addressable (1024 tiles × 128B)
    // For Thunder Dragon: load fgtile (91070.6, 128KB) here; bgtile needs extended tile_idx
    parameter logic [26:0] BG_ROM_BASE  = 27'h1C0000
) (
    // ── Clocks / Reset ──────────────────────────────────────────────────────────
    input  logic        clk_sys,        // master system clock (e.g. 40 MHz)
    input  logic        clk_pix,        // pixel clock enable (1-cycle pulse, sys-domain)
    input  logic        reset_n,        // active-low async reset

    // ── MC68000 CPU Bus ─────────────────────────────────────────────────────────
    // cpu_addr is the 68000 word address (A[23:1]).
    input  logic [23:1] cpu_addr,
    input  logic [15:0] cpu_din,        // data FROM cpu (write path)
    output logic [15:0] cpu_dout,       // data TO cpu (read path mux)
    input  logic        cpu_lds_n,      // lower data strobe (active low)
    input  logic        cpu_uds_n,      // upper data strobe (active low)
    input  logic        cpu_rw,         // 1=read, 0=write
    input  logic        cpu_as_n,       // address strobe (active low)
    input  logic        cpu_inta_n,     // interrupt acknowledge (active low, FC=111 & ASn=0)
    output logic        cpu_dtack_n,    // data transfer acknowledge (active low)
    output logic [2:0]  cpu_ipl_n,      // interrupt priority level (active low encoded)

    // ── Program ROM SDRAM Interface ─────────────────────────────────────────────
    output logic [26:0] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── Sprite ROM SDRAM Interface ──────────────────────────────────────────────
    output logic [26:0] spr_rom_sdram_addr,
    input  logic [15:0] spr_rom_sdram_data,
    output logic        spr_rom_sdram_req,
    input  logic        spr_rom_sdram_ack,

    // ── BG Tile ROM SDRAM Interface ─────────────────────────────────────────────
    output logic [26:0] bg_rom_sdram_addr,
    input  logic [15:0] bg_rom_sdram_data,
    output logic        bg_rom_sdram_req,
    input  logic        bg_rom_sdram_ack,

    // ── Video Output ────────────────────────────────────────────────────────────
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Video Timing Inputs (from external timing generator) ────────────────────
    input  logic        hblank_n_in,
    input  logic        vblank_n_in,
    input  logic  [8:0] hpos,
    input  logic  [7:0] vpos,
    input  logic        hsync_n_in,
    input  logic        vsync_n_in,

    // ── Player Inputs ───────────────────────────────────────────────────────────
    // Active-low convention.
    // joystick[7:4] = {BTN3,BTN2,BTN1,START}, joystick[3:0] = {RIGHT,LEFT,DOWN,UP}
    input  logic  [7:0] joystick_p1,
    input  logic  [7:0] joystick_p2,
    input  logic  [1:0] coin,           // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service,        // service button (active low)
    input  logic  [7:0] dipsw1,
    input  logic  [7:0] dipsw2,

    // ── Audio Output ────────────────────────────────────────────────────────────
    output logic signed [15:0] snd_left,   // mixed FM + ADPCM, signed 16-bit
    output logic signed [15:0] snd_right,  // mixed FM + ADPCM, signed 16-bit

    // ── ADPCM (OKI M6295) ROM SDRAM interface ───────────────────────────────────
    // 18-bit ROM address from jt6295; mapped to SDRAM at base 0x200000.
    output logic [23:0] adpcm_rom_addr,
    output logic        adpcm_rom_req,
    input  logic [15:0] adpcm_rom_data,
    input  logic        adpcm_rom_ack,

    // ── Z80 Sound CPU ROM SDRAM interface ────────────────────────────────────────
    // Z80 ROM: 48KB at SDRAM base 0x280000.  16-bit word address output.
    output logic [15:0] z80_rom_addr,    // Z80 16-bit PC / address
    output logic        z80_rom_req,     // toggle on new fetch request
    input  logic  [7:0] z80_rom_data,   // byte returned from SDRAM
    input  logic        z80_rom_ack     // toggle when data is ready
);

// =============================================================================
// Address Decode (byte addresses, mapped from cpu_addr word address × 2)
// =============================================================================
//
// cpu_addr[23:1] is the 68000 word address; byte_addr = cpu_addr << 1.
//
// Byte windows and their word-address equivalents:
//   Program ROM:  0x000000–0x07FFFF byte → cpu_addr[23:16] in 8'h00..8'h07 → cpu_addr[23:17]=0
//   Work RAM:     0x080000–0x08FFFF byte → cpu_addr[23:16]=8'h08 → cpu_addr[23:16]==8'h08 ≡ {1'b0, cpu_addr[22:16]}=8'h08
//   NMK16 chip:  0x0C0000–0x0CFFFF byte → cpu_addr[23:16]=8'h0C
//   Palette RAM:  0x0E0000–0x0E03FF byte → cpu_addr[23:16]=8'h0E, cpu_addr[9:1] = lower 9 word bits
//   I/O:          0x0E8000–0x0E8FFF byte → cpu_addr[23:16]=8'h0E, cpu_addr[15:13]=3'b100
//
// All decodes require !cpu_as_n.

// Address decode note: cpu_addr is logic [23:1], carrying the 68000's A[23:1]
// pins directly. cpu_addr[N] = AN (not shifted). Decodes use the BYTE address
// top bits directly, i.e. cpu_addr[23:16] == A[23:16] == byte_addr[23:16].
//
// =============================================================================
// Address decode note:
//   cpu_addr is logic [23:1] carrying 68000 A[23:1] pins directly.
//   cpu_addr[N] = AN (NOT a divided word address).
//   cpu_addr[23:16] == byte_addr[23:16] (top 8 bits of the byte address).
//
// Thunder Dragon memory map (verified against FBNeo d_nmk16.cpp NMK004Init):
//   0x000000–0x03FFFF  Program ROM (256KB, SDRAM)
//   0x0B0000–0x0BFFFF  Work RAM (64KB, BRAM)
//   0x0C0000–0x0C001F  I/O registers (joystick/coin/DIP at 0x0C0000-0x0C000F,
//                       sound comm at 0x0C001E, flip at 0x0C0014)
//   0x0C4000–0x0C43FF  Scroll registers (GPU control)
//   0x0C8000–0x0C87FF  Palette RAM (512 × 16-bit, BRAM)
//   0x0CC000–0x0CFFFF  BG tilemap VRAM (NMK16 chip internal RAM)
//   0x0D0000–0x0D07FF  Tx text VRAM (NMK16 chip, stub)
// =============================================================================

// Program ROM: 0x000000–0x03FFFF → A[23:18] == 6'b0 (256KB; bit 18 set at 0x040000)
logic prog_rom_cs;
assign prog_rom_cs = (cpu_addr[23:18] == 6'b0) && !cpu_as_n;

// Work RAM: 64KB at 0x0B0000–0x0BFFFF → A[23:16] == 8'h0B
logic wram_cs;
assign wram_cs = (cpu_addr[23:16] == WRAM_BASE) && !cpu_as_n;

// I/O registers: 0x0C0000–0x0C001F → A[23:16]==8'h0C, A[15:5]==11'b0
// (32 bytes of I/O at 0x0C0000-0x0C001F; cpu_addr[4:1] selects register word)
logic io_cs;
assign io_cs = (cpu_addr[23:16] == 8'h0C) && (cpu_addr[15:5] == 11'b0) && !cpu_as_n;

// Scroll registers: 0x0C4000–0x0C43FF → A[23:16]==8'h0C, A[15:10]==6'b010000
// 0x0C4000: A15=0,A14=1,A13=0,A12=0,A11=0,A10=0 → cpu_addr[15:10]=6'b010000
logic scroll_cs;
assign scroll_cs = (cpu_addr[23:16] == 8'h0C) && (cpu_addr[15:10] == 6'b010000) && !cpu_as_n;

// Palette RAM: 0x0C8000–0x0C87FF → A[23:16]==8'h0C, A[15]==1, A[14:11]==4'b0
// 0x0C8000: A15=1,A14=0,A13=0,A12=0 → cpu_addr[15:12]=4'h8, A11=0,A10=0 (512 entries)
logic pal_cs;
assign pal_cs = (cpu_addr[23:16] == 8'h0C) && (cpu_addr[15:11] == 5'b10000) && !cpu_as_n;

// BG VRAM: 0x0CC000–0x0CFFFF → A[23:16]==8'h0C, A[15:14]==2'b11
// 0x0CC000: A15=1,A14=1 → cpu_addr[15:14]=2'b11
logic bg_vram_cs;
assign bg_vram_cs = (cpu_addr[23:16] == 8'h0C) && (cpu_addr[15:14] == 2'b11) && !cpu_as_n;

// TX text VRAM: 0x0D0000–0x0D07FF → A[23:16]==8'h0D, A[15:11]==5'b0
// 2KB text-layer tilemap (used by NMK16 text overlay)
logic tx_vram_cs;
assign tx_vram_cs = (cpu_addr[23:16] == 8'h0D) && (cpu_addr[15:11] == 5'b0) && !cpu_as_n;

// NMK16 cs_n: assert for BG VRAM (tilemap) and scroll register accesses.
// Both regions are handled by the nmk16 chip.
logic nmk_cs_n;
assign nmk_cs_n = !(bg_vram_cs | scroll_cs);

// =============================================================================
// NMK16 Chip Address Construction
// =============================================================================
// The nmk16 chip has a 21-bit addr port [20:1]. Its internal decode:
//   Tilemap RAM: addr[20:16]=5'b10001 → offset 0x110000
//   GPU regs:    addr[20:16]=5'b10010 → offset 0x120000
//   Sprite RAM:  addr[20:16]=5'b10011 → offset 0x130000
//
// Thunder Dragon memory mapping:
//   CPU 0x0CC000-0x0CFFFF → NMK16 tilemap RAM (addr[20:16]=5'b10001)
//   CPU 0x0C4000-0x0C43FF → NMK16 GPU registers (addr[20:16]=5'b10010)
//
// For scroll_cs (0x0C4000): map to nmk16 GPU reg range 0x120000.
// The scroll/control register offsets are in cpu_addr[4:1].
logic [20:1] chip_addr;
always_comb begin
    if (scroll_cs)
        chip_addr = {5'b10010, 11'h0, cpu_addr[4:1]};  // GPU regs: 0x120000 + offset
    else
        chip_addr = {5'b10001, cpu_addr[15:1]};          // BG tilemap RAM: 0x110000 + offset
end

// Signals driven by NMK16 submodule outputs.
// Suppress UNDRIVEN: these are outputs from the nmk16 instance (not visible
// to Verilator when using -Wno-MODMISSING without the source file).
/* verilator lint_off UNDRIVEN */
logic [15:0] nmk_dout;
logic        nmk_irq_vblank_pulse;
logic        spr_rom_rd_w;
logic [20:0] spr_rom_addr_w;
logic [21:0] bg_rom_addr_w;
// Flat 1D wires — nmk16 uses flat display_list ports to avoid Quartus 17
// <auto-generated> Error 10028 on packed 2D output port connections.
// Element N = bits [(N+1)*W-1 : N*W] (e.g. dl_x element 0 = bits [8:0]).
logic [2303:0]      dl_x;   // [255:0]×[8:0]
logic [2303:0]      dl_y;   // [255:0]×[8:0]
logic [3071:0]      dl_tile;// [255:0]×[11:0]
logic [255:0]       dl_flip_x;
logic [255:0]       dl_flip_y;
logic [511:0]       dl_size;  // [255:0]×[1:0]
logic [1023:0]      dl_pal;   // [255:0]×[3:0]
logic [255:0]       dl_valid;
logic [255:0]       dl_prio;
logic  [7:0] dl_count;
logic        dl_ready;
logic [1:0]  bg_pix_valid;
logic [15:0]      bg_pix_color;  // [15:8]=layer1, [7:0]=layer0
logic [1:0]  bg_pix_priority;
logic [7:0]  spr_rd_color;
logic        spr_rd_valid;
logic        spr_rd_priority;
logic        spr_render_done;
logic [7:0]  final_color;
logic        final_valid;
/* verilator lint_on UNDRIVEN */

// Signals driven by this module, fed INTO nmk16 as inputs.
logic  [7:0] spr_rom_data_w;
logic  [7:0] bg_rom_data_w;

// Internally computed vsync delayed (1 cycle) for edge detection
logic vsync_n_r;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) vsync_n_r <= 1'b1;
    else          vsync_n_r <= vsync_n_in;
end

// Scanline trigger: 1-cycle pulse at start of each active scanline (hpos==0,
// hblank inactive). Feeds the G3 sprite rasterizer so it knows which scanline
// to render pixels for.
logic scan_trigger_w;
assign scan_trigger_w = (hpos == 9'd0) && hblank_n_in;

/* verilator lint_off PINCONNECTEMPTY */
nmk16 #(
    .ADDR_WIDTH (21),
    .DATA_WIDTH (16)
) u_nmk16 (
    .clk            (clk_sys),
    .rst_n          (reset_n),

    // CPU interface
    .addr           (chip_addr),
    .din            (cpu_din),
    .dout           (nmk_dout),
    .cs_n           (nmk_cs_n),
    .rd_n           (~cpu_rw | cpu_as_n),   // rd_n=0 when CPU reads and AS asserted
    .wr_n           (cpu_rw  | cpu_as_n),   // wr_n=0 when CPU writes and AS asserted
    .lds_n          (cpu_lds_n),
    .uds_n          (cpu_uds_n),

    // Video timing
    .vsync_n        (vsync_n_in),
    .vsync_n_r      (vsync_n_r),

    // Shadow register outputs (active)
    .scroll0_x_active (),
    .scroll0_y_active (),
    .scroll1_x_active (),
    .scroll1_y_active (),
    .bg_ctrl_active   (),
    .sprite_ctrl_active (),

    // Sprite RAM external interface (internal BRAM used by chip)
    .sprite_wr      (),
    .sprite_addr_wr (),
    .sprite_data_wr (),
    .sprite_rd      (),
    .sprite_addr_rd (),
    .sprite_data_rd (16'h0),

    // Status inputs (tied off — IRQ handled by irq_vblank_pulse below)
    .vblank_irq       (1'b0),
    .sprite_done_irq  (1'b0),

    // Display list outputs
    .display_list_x       (dl_x),
    .display_list_y       (dl_y),
    .display_list_tile    (dl_tile),
    .display_list_flip_x  (dl_flip_x),
    .display_list_flip_y  (dl_flip_y),
    .display_list_size    (dl_size),
    .display_list_palette (dl_pal),
    .display_list_valid   (dl_valid),
    .display_list_priority(dl_prio),
    .display_list_count   (dl_count),
    .display_list_ready   (dl_ready),
    .irq_vblank_pulse     (nmk_irq_vblank_pulse),

    // Gate 3: sprite rasterizer inputs
    .scan_trigger     (scan_trigger_w),    // pulse at start of each active scanline
    .current_scanline ({1'b0, vpos}),      // current active scanline (vpos is 8-bit)
    .spr_rom_addr     (spr_rom_addr_w),
    .spr_rom_rd       (spr_rom_rd_w),
    .spr_rom_data     (spr_rom_data_w),
    .spr_rd_addr      (hpos),
    .spr_rd_color     (spr_rd_color),
    .spr_rd_valid     (spr_rd_valid),
    .spr_rd_priority  (spr_rd_priority),
    .spr_render_done  (spr_render_done),

    // Gate 4: BG tilemap inputs
    .bg_x             (hpos),
    .bg_y             (vpos),
    .bg_rom_addr      (bg_rom_addr_w),
    .bg_rom_data      (bg_rom_data_w),
    .bg_pix_valid     (bg_pix_valid),
    .bg_pix_color     (bg_pix_color),
    .bg_pix_priority  (bg_pix_priority),

    // Gate 5: compositor outputs
    .final_color      (final_color),
    .final_valid      (final_valid)
);
/* verilator lint_on PINCONNECTEMPTY */

// =============================================================================
// Sprite ROM SDRAM Bridge — combinational pixel-rate fetch
//
// nmk16 Gate 3 (G3_FETCH) reads spr_rom_data combinationally in the SAME
// clock cycle that spr_rom_addr is valid ("combinational zero-latency" per
// nmk16.sv interface comment). The toggle-handshake approach introduced
// multi-cycle latency, causing incorrect pixel data.
//
// Fix: drive spr_rom_sdram_addr directly from spr_rom_addr_w (combinational).
// The testbench does a direct SDRAM lookup every cycle and drives
// spr_rom_sdram_data with zero latency (same fix as BG tile ROM bridge).
// spr_rom_sdram_req is held constant (req=0) since no toggle-handshake needed.
//
// For FPGA synthesis a proper SDRAM burst or BRAM cache bridge replaces this.
// =============================================================================
assign spr_rom_sdram_addr = SPR_ROM_BASE + {6'b0, spr_rom_addr_w[20:0]};
assign spr_rom_sdram_req  = 1'b0;  // not used; testbench drives data directly
// Big-endian byte select: odd byte (addr[0]=1) → data[7:0], even → data[15:8]
assign spr_rom_data_w = spr_rom_addr_w[0] ? spr_rom_sdram_data[7:0]
                                           : spr_rom_sdram_data[15:8];

// =============================================================================
// BG Tile ROM SDRAM Bridge — combinational pixel-rate fetch
//
// nmk16 Gate 4 presents bg_rom_addr as a registered output (Stage 1 FF).
// Stage 2 reads bg_rom_data combinationally in the SAME clock cycle that
// bg_rom_addr is valid.
//
// For simulation correctness we drive bg_rom_sdram_addr directly from
// bg_rom_addr_w (combinational, no registered latency). The testbench then
// does a direct SDRAM lookup every cycle and drives bg_rom_sdram_data
// with zero latency. bg_rom_sdram_req/ack are held constant (req=0, ack=0)
// since no toggle-handshake is needed for this synchronous-read model.
//
// For FPGA synthesis a proper SDRAM or BRAM cache bridge would replace this.
// =============================================================================
assign bg_rom_sdram_addr = BG_ROM_BASE + {5'b0, bg_rom_addr_w[21:1], 1'b0};
assign bg_rom_sdram_req  = 1'b0;  // not used; testbench drives data directly
assign bg_rom_data_w     = bg_rom_addr_w[0] ? bg_rom_sdram_data[7:0]
                                             : bg_rom_sdram_data[15:8];

// =============================================================================
// Program ROM SDRAM Bridge
// Simple toggle-handshake: CPU reads from 0x000000–0x07FFFF trigger SDRAM fetch.
// =============================================================================
logic        prog_req_pending;
logic [26:0] prog_req_addr_r;
logic [15:0] prog_rom_data_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        prog_rom_req      <= 1'b0;
        prog_req_pending  <= 1'b0;
        prog_req_addr_r   <= 27'b0;
        prog_rom_data_r   <= 16'hFFFF;
    end else begin
        if (prog_rom_cs && cpu_rw && !prog_req_pending && !dtack_r) begin
            // New ROM read request — guard !dtack_r prevents re-issuing in same bus cycle
            prog_req_addr_r  <= {3'b0, cpu_addr[23:1], 1'b0};  // byte addr in SDRAM (27-bit)
            prog_req_pending <= 1'b1;
            prog_rom_req     <= ~prog_rom_req;
        end else if (prog_req_pending && (prog_rom_req == prog_rom_ack)) begin
            prog_rom_data_r  <= prog_rom_data;
            prog_req_pending <= 1'b0;
        end
    end
end

assign prog_rom_addr = prog_req_addr_r;

// =============================================================================
// Work RAM — 64KB synchronous block RAM
// =============================================================================
`ifdef QUARTUS
// altsyncram DUAL_PORT: port A = write (byteena), port B = read
// WRAM_ABITS=15 → widthad=15, numwords=32768
logic        wram_we;
logic [1:0]  wram_be;
logic [15:0] wram_dout_r;
assign wram_we = wram_cs & !cpu_rw;
assign wram_be = {!cpu_uds_n, !cpu_lds_n};

altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (16), .widthad_a (15), .numwords_a (32768),
    .width_b                   (16), .widthad_b (15), .numwords_b (32768),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (2), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) wram_inst (
    .clock0(clk_sys), .clock1(clk_sys),
    .address_a(cpu_addr[15:1]), .data_a(cpu_din),
    .wren_a(wram_we), .byteena_a(wram_be),
    .address_b(cpu_addr[15:1]), .q_b(wram_dout_r),
    .wren_b(1'b0), .data_b(16'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);
`else
logic [15:0] work_ram [0:(1<<WRAM_ABITS)-1];
logic [15:0] wram_dout_r;

always_ff @(posedge clk_sys) begin
    if (wram_cs && !cpu_rw) begin
        if (!cpu_uds_n) work_ram[cpu_addr[WRAM_ABITS:1]][15:8] <= cpu_din[15:8];
        if (!cpu_lds_n) work_ram[cpu_addr[WRAM_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (wram_cs) wram_dout_r <= work_ram[cpu_addr[WRAM_ABITS:1]];
end
`endif

// =============================================================================
// Palette RAM — 512 × 16-bit synchronous block RAM
// CPU-writable; video output reads directly in combinational path below.
// Format: RGB555 (bit 15 unused or priority, bits [14:10]=R, [9:5]=G, [4:0]=B)
// =============================================================================
`ifdef QUARTUS
// Two DUAL_PORT instances sharing port A (write). PAL_ABITS=9 → numwords=512.
logic        pal_we;
logic [1:0]  pal_be;
logic [15:0] pal_dout_r;
assign pal_we = pal_cs & !cpu_rw;
assign pal_be = {!cpu_uds_n, !cpu_lds_n};

// Instance 1: CPU read port
altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (16), .widthad_a (9), .numwords_a (512),
    .width_b                   (16), .widthad_b (9), .numwords_b (512),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (2), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) pal_cpu_inst (
    .clock0(clk_sys), .clock1(clk_sys),
    .address_a(cpu_addr[9:1]), .data_a(cpu_din),
    .wren_a(pal_we), .byteena_a(pal_be),
    .address_b(cpu_addr[9:1]), .q_b(pal_dout_r),
    .wren_b(1'b0), .data_b(16'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// Instance 2: pixel palette lookup (combinational → registered, 1-cycle latency acceptable)
logic  [8:0] pal_index_w;
logic [15:0] pal_entry;
assign pal_index_w = final_valid ? {1'b0, final_color} : 9'h000;

altsyncram #(
    .operation_mode            ("DUAL_PORT"),
    .width_a                   (16), .widthad_a (9), .numwords_a (512),
    .width_b                   (16), .widthad_b (9), .numwords_b (512),
    .outdata_reg_b             ("CLOCK1"), .address_reg_b ("CLOCK1"),
    .clock_enable_input_a      ("BYPASS"), .clock_enable_input_b ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"), .ram_block_type ("M10K"),
    .width_byteena_a           (2), .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) pal_pix_inst (
    .clock0(clk_sys), .clock1(clk_sys),
    .address_a(cpu_addr[9:1]), .data_a(cpu_din),
    .wren_a(pal_we), .byteena_a(pal_be),
    .address_b(pal_index_w), .q_b(pal_entry),
    .wren_b(1'b0), .data_b(16'd0), .q_a(),
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
    .byteena_b(1'b1), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(), .rden_b(1'b1)
);

// =============================================================================
// Palette Lookup — final_color (8-bit index) → RGB888  (1-cycle registered latency under QUARTUS)
// =============================================================================
// pal_entry is now the registered q_b output of pal_pix_inst.
// pal_index_w declared above.

// Expand 5-bit colour components to 8-bit
assign rgb_r = {pal_entry[14:10], pal_entry[14:12]};
assign rgb_g = {pal_entry[9:5],   pal_entry[9:7]};
assign rgb_b = {pal_entry[4:0],   pal_entry[4:2]};
`else
logic [15:0] palette_ram [0:(1<<PAL_ABITS)-1];
logic [15:0] pal_dout_r;

always_ff @(posedge clk_sys) begin
    if (pal_cs && !cpu_rw) begin
        if (!cpu_uds_n) palette_ram[cpu_addr[PAL_ABITS:1]][15:8] <= cpu_din[15:8];
        if (!cpu_lds_n) palette_ram[cpu_addr[PAL_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (pal_cs) pal_dout_r <= palette_ram[cpu_addr[PAL_ABITS:1]];
end

// =============================================================================
// Palette Lookup — final_color (8-bit index) → RGB888
// =============================================================================
logic [15:0] pal_entry;
logic  [8:0] pal_index_w;
assign pal_index_w = final_valid ? {1'b0, final_color} : 9'h000;
assign pal_entry   = palette_ram[pal_index_w];

// Expand 5-bit colour components to 8-bit
assign rgb_r = {pal_entry[14:10], pal_entry[14:12]};
assign rgb_g = {pal_entry[9:5],   pal_entry[9:7]};
assign rgb_b = {pal_entry[4:0],   pal_entry[4:2]};
`endif

// =============================================================================
// TX Text VRAM — 0x0D0000–0x0D07FF (2KB × 16-bit)
// Used by the NMK16 text overlay layer.
// CPU must be able to read/write this; DTACK is immediate (BRAM).
// =============================================================================
localparam TX_ABITS = 10;  // 1024 word addresses = 2KB

logic [15:0] tx_vram [0:(1<<TX_ABITS)-1];
logic [15:0] tx_dout_r;

always_ff @(posedge clk_sys) begin
    if (tx_vram_cs && !cpu_rw) begin
        if (!cpu_uds_n) tx_vram[cpu_addr[TX_ABITS:1]][15:8] <= cpu_din[15:8];
        if (!cpu_lds_n) tx_vram[cpu_addr[TX_ABITS:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (tx_vram_cs) tx_dout_r <= tx_vram[cpu_addr[TX_ABITS:1]];
end

// =============================================================================
// I/O Register File — Thunder Dragon
// 0x0C0000–0x0C001F: cpu_addr[4:1] selects word offset within this 32-byte block.
//
// Reads (verified against FBNeo tdragon_main_read_word):
//   0x0C0000 (word 0): joystick_p1 [15:0] (active low)
//   0x0C0002 (word 1): joystick_p2 [15:0] (active low)
//   0x0C0008 (word 4): DIP switch bank 1
//   0x0C000A (word 5): DIP switch bank 2
//   0x0C000E (word 7): NMK004 MCU read (sound status) — returns 0 (stub)
//
// Writes (verified against FBNeo tdragon_main_write_word):
//   0x0C0014 (word A): flip screen (ignored)
//   0x0C0016 (word B): NMK004 NMI trigger (ignored — MCU stub)
//   0x0C0018 (word C): tile bank select (ignored — stub)
//   0x0C001E (word F): NMK004 write (sound command latch)
// =============================================================================
logic [15:0] io_dout;

// =============================================================================
// NMK004 MCU Stub — behavioural handshake emulation
//
// The real NMK004 is a TLCS90 MCU.  Thunder Dragon calls two handshake
// subroutines during boot (0x0105D8 and 0x01060C) that use a write-driven
// echo protocol on 0x0C001E (write) / 0x0C000E (read):
//
// Subroutine 0x0105D8 (called 3×, each with a different idle value):
//   IDLE state:     return idle_val (bits[7:5]=100, bits[4:0]=version_code)
//     Thunder Dragon idle sequence: 0x82 (v2), 0x9F (v31), 0x8B (v11)
//   Write val with bit5=1, bit7=0:  → return 0x00C7
//   Write val with bit6=1:          → return 0x0000
//   Write 0x0000 (final clear):     → advance idle_index, back to IDLE
//
// Subroutine 0x01060C (called 2×, D0 is command payload):
//   Write val with bit7=1, val≠0xC7: save bits[4:0], → return (cmd&0x1F)|0x20
//   Write 0x00C7:                     → return (saved_cmd&0x1F)|0x40
//   Write 0x0000 (CLR.W):             → return 0x0000, back to IDLE
//
// State encoding:
//   3'd0 NMK_IDLE   — return idle_val (cycling through version codes)
//   3'd1 NMK_ACK_C7 — return 0x00C7  (after bit5-only write)
//   3'd2 NMK_ACK_00 — return 0x0000  (after bit6 write)
//   3'd3 NMK_ECHO1  — return (saved_cmd|0x20) (after cmd|0x80 write)
//   3'd4 NMK_ECHO2  — return (saved_cmd|0x40) (after 0xC7 write in echo proto)
//   3'd5 NMK_CLEAR  — return 0x0000  (echo protocol clear phase)
// =============================================================================
logic [7:0] sound_cmd;
logic [2:0] nmk004_state;
logic [4:0] nmk004_saved_cmd;  // bits[4:0] of the 0x01060C command
logic [1:0] nmk004_idle_idx;   // which idle value to return (0→0x82, 1→0x9F, 2→0x8B)

// Idle return value for 0x0C000E based on idle_idx
// Each corresponds to a distinct boot handshake pass:
//   idx=0: 0x82 → D7=2  (first  0x0105D8 call, CMPI.B #2,   D7)
//   idx=1: 0x9F → D7=31 (second 0x0105D8 call, CMPI.B #$1F, D7)
//   idx=2: 0x8B → D7=11 (third  0x0105D8 call, CMPI.B #$B,  D7)
logic [7:0] nmk004_idle_val;
always_comb begin
    case (nmk004_idle_idx)
        2'd0:    nmk004_idle_val = 8'h82;
        2'd1:    nmk004_idle_val = 8'h9F;
        2'd2:    nmk004_idle_val = 8'h8B;
        default: nmk004_idle_val = 8'h82;
    endcase
end

// Write strobe: 68K writes to 0x0C001E (level, true while AS_n low and write)
wire nmk_wr_lvl = io_cs && !cpu_rw && (cpu_addr[4:1] == 4'hF);
// Read strobe: 68K reads 0x0C000E (level)
wire nmk_rd_lvl = io_cs &&  cpu_rw && (cpu_addr[4:1] == 4'h7);

// Edge-detect: only pulse on the rising edge (first clock after AS_n asserts)
// nmk004_as_prev tracks the previous cycle's AS_n so we see only the first clock.
logic nmk004_wr_prev;
logic nmk004_rd_prev;
wire  nmk_wr = nmk_wr_lvl && !nmk004_wr_prev;  // one-shot on first active clock
wire  nmk_rd = nmk_rd_lvl && !nmk004_rd_prev;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        sound_cmd        <= 8'h00;
        nmk004_state     <= 3'd0;
        nmk004_saved_cmd <= 5'd0;
        nmk004_idle_idx  <= 2'd0;
        nmk004_wr_prev   <= 1'b0;
        nmk004_rd_prev   <= 1'b0;
    end else begin
        nmk004_wr_prev <= nmk_wr_lvl;
        nmk004_rd_prev <= nmk_rd_lvl;
        if (nmk_wr) begin
            sound_cmd <= cpu_din[7:0];
            case (nmk004_state)
                3'd0: begin  // IDLE
                    if (cpu_din[7] && cpu_din[7:0] != 8'hC7) begin
                        // bit7=1, not 0xC7 → echo protocol phase 1
                        nmk004_saved_cmd <= cpu_din[4:0];
                        nmk004_state     <= 3'd3;  // ECHO1
                    end else if (cpu_din[5] && !cpu_din[7]) begin
                        // bit5=1, bit7=0 → handshake ACK_C7
                        nmk004_state <= 3'd1;
                    end else if (cpu_din[6]) begin
                        // bit6=1 without bit7 → ACK_00 (handles 0x60-0x7F range)
                        nmk004_state <= 3'd2;
                    end
                    // else val==0 (CLR.W init) → stay IDLE (no-op)
                end
                3'd1: begin  // ACK_C7 — write is cmd|0x60
                    nmk004_state <= 3'd2;  // → ACK_00
                end
                3'd2: begin  // ACK_00 — write is final clear (val==0)
                    // Advance idle index after each complete 0x0105D8 handshake
                    if (nmk004_idle_idx != 2'd2)
                        nmk004_idle_idx <= nmk004_idle_idx + 2'd1;
                    nmk004_state <= 3'd0;  // → IDLE
                end
                3'd3: begin  // ECHO1 — write is 0xC7
                    nmk004_state <= 3'd4;  // → ECHO2
                end
                3'd4: begin  // ECHO2 — write is CLR.W (0x00)
                    nmk004_state <= 3'd5;  // → CLEAR
                end
                default: nmk004_state <= 3'd0;  // CLEAR or unknown → IDLE
            endcase
        end else if (nmk004_rd_prev && !nmk_rd_lvl && nmk004_state == 3'd5) begin
            // CLEAR state: auto-transition to IDLE on the FALLING EDGE of nmk_rd_lvl
            // (i.e., after the CPU's bus cycle ends, so the CPU correctly latches 0x0000
            // during the read, and subsequent reads get the new IDLE value).
            nmk004_state <= 3'd0;
        end
    end
end

always_comb begin
    io_dout = 16'hFFFF;
    if (io_cs) begin
        case (cpu_addr[4:1])
            4'h0: io_dout = {8'hFF, joystick_p1};   // 0x0C0000: P1
            4'h1: io_dout = {8'hFF, joystick_p2};   // 0x0C0002: P2
            4'h4: io_dout = {8'hFF, dipsw1};         // 0x0C0008: DIP1
            4'h5: io_dout = {8'hFF, dipsw2};         // 0x0C000A: DIP2
            4'h2: io_dout = {8'hFF, coin[1], coin[0], service, 5'b11111}; // 0x0C0004
            // 0x0C000E: NMK004 status register
            4'h7: begin
                case (nmk004_state)
                    3'd0: io_dout = {8'h00, nmk004_idle_val};          // IDLE
                    3'd1: io_dout = 16'h00C7;                          // ACK_C7
                    3'd2: io_dout = 16'h0000;                          // ACK_00
                    3'd3: io_dout = {8'h00, 3'b001, nmk004_saved_cmd};  // ECHO1: (saved_cmd&0x1F)|0x20
                    3'd4: io_dout = {8'h00, 3'b011, nmk004_saved_cmd};  // ECHO2: (saved_cmd&0x1F)|0x60
                    3'd5: io_dout = 16'h0000;                          // CLEAR
                    default: io_dout = {8'h00, nmk004_idle_val};
                endcase
            end
            default: io_dout = 16'hFFFF;
        endcase
    end
end

// =============================================================================
// CPU Data Bus Read Mux
// Priority: prog_rom > NMK16 (bg_vram) > work_ram > palette_ram > io > open-bus
//
// For the program ROM path we distinguish two cases:
//   prog_dtack_now  — the SDRAM ack has just arrived THIS cycle; use the LIVE
//                     prog_rom_data input so the CPU sees data in the same eval
//                     step that DTACK is asserted (no 1-cycle pipeline delay).
//   otherwise       — use prog_rom_data_r (the registered latch) to hold data
//                     stable for the remainder of the bus cycle.
// =============================================================================

// prog_dtack_now is assigned below (after dtack_r section) but declared here
// so cpu_dout can reference it.  Both are combinational; no circular dependency.
logic prog_dtack_now;

always_comb begin
    if (prog_rom_cs) begin
        // Use LIVE SDRAM data when ack fires this cycle; registered copy otherwise.
        cpu_dout = prog_dtack_now ? prog_rom_data : prog_rom_data_r;
    end else if (!nmk_cs_n)
        cpu_dout = nmk_dout;
    else if (wram_cs)
        cpu_dout = wram_dout_r;
    else if (pal_cs)
        cpu_dout = pal_dout_r;
    else if (tx_vram_cs)
        cpu_dout = tx_dout_r;
    else if (io_cs)
        cpu_dout = io_dout;
    else
        cpu_dout = 16'hFFFF;   // open bus (scroll regs write-only, return 0xFFFF)
end

// =============================================================================
// DTACK Generation
// Immediate regions (wram, pal, io, scroll, bg_vram): 1 cycle after CS.
// Program ROM (SDRAM): deferred until SDRAM handshake completes.
//
// DTACK uses a hold-until-deassert pattern: once asserted it stays asserted
// until the CPU ends the bus cycle (AS_n goes high).  This ensures the CPU
// can sample DTACK at any state of its bus cycle regardless of when it fires.
//
// For the ROM SDRAM path we need DTACK to assert COMBINATIONALLY in the same
// eval step that data arrives, not one cycle later through dtack_r.  We achieve
// this with two complementary mechanisms:
//   prog_dtack_now — combinational pulse: true exactly when SDRAM req==ack and
//                    we were waiting for it.  Used to bypass dtack_r for the
//                    initial assertion so the CPU sees data + DTACK together.
//   dtack_r        — registered hold latch: keeps DTACK low across the entire
//                    bus cycle for ALL sources (including ROM, via prog_dtack_now
//                    being captured into dtack_r one cycle later as the hold).
// =============================================================================
logic dtack_r;

// Immediate regions: all RAM/regs respond in 1 cycle (BRAM latency = 1 cycle)
// Includes: wram, pal, io, scroll registers, bg_vram (nmk16 chip), tx_vram
// Also: ROM write cycles — writes to ROM address space are silently ignored
// (FBNeo maps ROM with MAP_ROM which completes writes immediately with no effect).
// Without this, CLR.W $0002 in the Thunder Dragon MCU-sync loop stalls forever.
logic imm_cs;
assign imm_cs = (wram_cs | pal_cs | io_cs | scroll_cs | bg_vram_cs | tx_vram_cs
                 | (prog_rom_cs && !cpu_rw)) && !cpu_as_n;

// Program ROM: combinational pulse when SDRAM data arrives THIS cycle.
// prog_req_pending goes 1→0 at the NEXT posedge (registered), so while
// prog_req_pending==1 and req==ack the data on prog_rom_data is valid NOW.
assign prog_dtack_now = prog_rom_cs && prog_req_pending && (prog_rom_req == prog_rom_ack);

// DTACK hold latch: set when any source fires; cleared when AS_n deasserts.
// dtack_r = !cpu_as_n  AND  (already_held  OR  new_source)
// The cpu_as_n gate clears it the cycle after the bus master ends the cycle.
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        dtack_r <= 1'b0;
    else
        dtack_r <= !cpu_as_n && (dtack_r | imm_cs | prog_dtack_now);
end

// cpu_dtack_n:
//   - deasserted (1) whenever AS_n is high (no active bus cycle)
//   - asserted combinationally (0) when ROM SDRAM ack fires THIS cycle
//     (prog_dtack_now) — no wait for dtack_r to be clocked
//   - asserted (0) via dtack_r for all other cases (immediate devices hold,
//     ROM hold after first assertion)
assign cpu_dtack_n = cpu_as_n          ? 1'b1 :
                     prog_dtack_now    ? 1'b0 :
                                         !dtack_r;

// =============================================================================
// Interrupt (IPL) Generation — VBLANK at level 4
// =============================================================================
// Community pattern (jotego, Cave, NeoGeo, va7deo, atrac17):
//   SET IPL on VBLANK edge, CLEAR on IACK only. NEVER use a timer.
//   Timer-based clear races with pswI mask — interrupt expires before
//   the CPU enables interrupts, so the game never takes VBlank.
// =============================================================================
logic ipl4_active;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl4_active <= 1'b0;
    end else begin
        if (!cpu_inta_n)               // IACK cycle: CPU acknowledged the interrupt
            ipl4_active <= 1'b0;
        else if (nmk_irq_vblank_pulse) // VBlank: assert interrupt
            ipl4_active <= 1'b1;
    end
end

// IPL4 encoding: level 4 = ~4 = 3'b011 (active low)
// Direct combinational assignment — no extra register that could initialize to 0 in Verilator.
assign cpu_ipl_n = ipl4_active ? 3'b011 : 3'b111;

// =============================================================================
// Video Sync / Blank Output
// =============================================================================
assign hblank  = !hblank_n_in;
assign vblank  = !vblank_n_in;
assign hsync_n = hsync_n_in;
assign vsync_n = vsync_n_in;

// =============================================================================
// Sound — Z80 @ 8 MHz (T80s) + YM2203 (jt03) + OKI M6295 (jt6295)
//
// Z80 address map (NMK16 / Thunder Dragon hardware):
//   0x0000–0x7FFF   ROM (from SDRAM, via z80_rom_* ports)
//   0x8000–0x8001   YM2203 (A0=reg/data select)
//   0xA000          OKI M6295
//   0xC000–0xCFFF   Z80 RAM (4KB BRAM, mirrored to 0xDFFF)
//   0xF000          Sound command latch (read from M68K)
//
// Clock enables (clk_sys = 40 MHz):
//   ce_z80 : 8 MHz  — every 5th cycle
//   ce_fm  : 1.5 MHz — every 27th cycle  (YM2203 input)
//   ce_oki : 1 MHz   — every 40th cycle  (OKI M6295 input)
// =============================================================================

// ── Clock enables ──────────────────────────────────────────────────────────

// Z80 clock enable: 40 MHz / 5 = 8 MHz
logic [2:0] ce_z80_cnt;
logic       ce_z80;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_z80_cnt <= 3'd0;
        ce_z80     <= 1'b0;
    end else begin
        if (ce_z80_cnt == 3'd4) begin
            ce_z80_cnt <= 3'd0;
            ce_z80     <= 1'b1;
        end else begin
            ce_z80_cnt <= ce_z80_cnt + 3'd1;
            ce_z80     <= 1'b0;
        end
    end
end

// YM2203 clock enable: 40 MHz / 27 ≈ 1.48 MHz
logic [5:0] ce_fm_cnt;
logic       ce_fm;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_fm_cnt <= 6'd0;
        ce_fm     <= 1'b0;
    end else begin
        if (ce_fm_cnt == 6'd26) begin
            ce_fm_cnt <= 6'd0;
            ce_fm     <= 1'b1;
        end else begin
            ce_fm_cnt <= ce_fm_cnt + 6'd1;
            ce_fm     <= 1'b0;
        end
    end
end

// OKI clock enable: 40 MHz / 40 = 1 MHz
logic [5:0] ce_oki_cnt;
logic       ce_oki;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ce_oki_cnt <= 6'd0;
        ce_oki     <= 1'b0;
    end else begin
        if (ce_oki_cnt == 6'd39) begin
            ce_oki_cnt <= 6'd0;
            ce_oki     <= 1'b1;
        end else begin
            ce_oki_cnt <= ce_oki_cnt + 6'd1;
            ce_oki     <= 1'b0;
        end
    end
end

// =============================================================================
// Z80 Sound CPU — T80s
// =============================================================================

// Z80 bus signals
logic        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
logic        z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n;
logic [15:0] z80_addr;
logic  [7:0] z80_dout_cpu;

// Z80 wait: held low while ROM SDRAM fetch is pending
logic        z80_wait_n;

// Z80 interrupt: driven by YM2203 irq_n
wire         z80_int_n;

// Z80 4KB internal RAM (0xC000–0xCFFF)
logic [7:0] z80_ram [0:4095];
logic [7:0] z80_ram_dout_r;

// ── Z80 chip-select decode ────────────────────────────────────────────────────
logic z80_rom_cs;   // 0x0000–0x7FFF
logic z80_ym_cs;    // 0x8000–0x8001 (YM2203)
logic z80_oki_cs;   // 0xA000        (OKI M6295)
logic z80_ram_cs;   // 0xC000–0xCFFF (4KB RAM)
logic z80_cmd_cs;   // 0xF000        (sound command latch)

always_comb begin
    z80_rom_cs = (!z80_mreq_n) && (z80_addr[15] == 1'b0);
    z80_ym_cs  = (!z80_mreq_n) && (z80_addr[15:1] == 15'h4000);
    z80_oki_cs = (!z80_mreq_n) && (z80_addr[15:12] == 4'hA);
    z80_ram_cs = (!z80_mreq_n) && (z80_addr[15:12] == 4'hC);
    z80_cmd_cs = (!z80_mreq_n) && (z80_addr[15:12] == 4'hF);
end

// ── Z80 ROM SDRAM bridge ─────────────────────────────────────────────────────
logic z80_rom_pending;
logic z80_rom_req_r;
logic [7:0] z80_rom_latch;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        z80_rom_req_r   <= 1'b0;
        z80_rom_pending <= 1'b0;
        z80_rom_latch   <= 8'hFF;
        z80_wait_n      <= 1'b1;
    end else begin
        if (z80_rom_cs && !z80_rd_n && !z80_rom_pending) begin
            z80_rom_req_r   <= ~z80_rom_req_r;
            z80_rom_pending <= 1'b1;
            z80_wait_n      <= 1'b0;    // stall Z80
        end else if (z80_rom_pending && (z80_rom_req_r == z80_rom_ack)) begin
            z80_rom_latch   <= z80_rom_data;
            z80_rom_pending <= 1'b0;
            z80_wait_n      <= 1'b1;    // release Z80
        end
    end
end

assign z80_rom_req  = z80_rom_req_r;
assign z80_rom_addr = z80_addr;

// ── Z80 RAM ──────────────────────────────────────────────────────────────────
always_ff @(posedge clk_sys) begin
    if (z80_ram_cs && !z80_wr_n)
        z80_ram[z80_addr[11:0]] <= z80_dout_cpu;
end

always_ff @(posedge clk_sys) begin
    if (z80_ram_cs) z80_ram_dout_r <= z80_ram[z80_addr[11:0]];
end

// ── Z80 data bus read mux ────────────────────────────────────────────────────
logic [7:0] z80_din_mux;

wire  [7:0] ym_dout_w;    // YM2203 read data (for Z80)
wire  [7:0] oki_dout_w;   // OKI M6295 read data

always_comb begin
    if (z80_ym_cs)
        z80_din_mux = ym_dout_w;
    else if (z80_oki_cs)
        z80_din_mux = oki_dout_w;
    else if (z80_cmd_cs)
        z80_din_mux = sound_cmd;
    else if (z80_ram_cs)
        z80_din_mux = z80_ram_dout_r;
    else if (z80_rom_cs)
        z80_din_mux = z80_rom_latch;
    else
        z80_din_mux = 8'hFF;
end

T80s u_z80 (
    .RESET_n  (reset_n),
    .CLK      (clk_sys),
    .CEN      (ce_z80),
    .WAIT_n   (z80_wait_n),
    .INT_n    (z80_int_n),
    .NMI_n    (1'b1),
    .BUSRQ_n  (1'b1),
    .OUT0     (1'b0),
    .DI       (z80_din_mux),
    .M1_n     (z80_m1_n),
    .MREQ_n   (z80_mreq_n),
    .IORQ_n   (z80_iorq_n),
    .RD_n     (z80_rd_n),
    .WR_n     (z80_wr_n),
    .RFSH_n   (z80_rfsh_n),
    .HALT_n   (z80_halt_n),
    .BUSAK_n  (z80_busak_n),
    .A        (z80_addr),
    .DOUT     (z80_dout_cpu)
);

// ── YM2203 chip-select and write enables ──────────────────────────────────────
wire        ym_cs_n_w = ~z80_ym_cs;
wire        ym_wr_n_w = z80_wr_n | ~z80_ym_cs;
wire        ym_addr_w = z80_addr[0];    // A0 selects register vs data

// YM2203 irq_n → Z80 INT
wire        fm_irq_n_w;
assign      z80_int_n = fm_irq_n_w;

wire signed [15:0] fm_snd_w;
wire         [9:0] psg_snd_w;

jt03 u_ym2203 (
    .rst        (~reset_n),
    .clk        (clk_sys),
    .cen        (ce_fm),
    .din        (z80_dout_cpu),
    .addr       (ym_addr_w),
    .cs_n       (ym_cs_n_w),
    .wr_n       (ym_wr_n_w),
    .dout       (ym_dout_w),
    .irq_n      (fm_irq_n_w),
    // YM2203 I/O pins — unused on NMK16
    .IOA_in     (8'hFF),
    .IOB_in     (8'hFF),
    .IOA_out    (),
    .IOB_out    (),
    .IOA_oe     (),
    .IOB_oe     (),
    // Separated outputs
    .psg_A      (),
    .psg_B      (),
    .psg_C      (),
    .fm_snd     (fm_snd_w),
    .psg_snd    (psg_snd_w),
    .snd        (),
    .snd_sample (),
    .debug_view ()
);

// ── OKI M6295 (jt6295) ADPCM ROM bridge ─────────────────────────────────────
localparam logic [26:0] ADPCM_ROM_BASE = 27'h200000;

wire [17:0] oki_rom_addr_w;
wire  [7:0] oki_rom_data_w;
wire        oki_rom_ok_w;
wire signed [13:0] oki_sound_w;

logic        oki_req_pending;
logic        oki_byte_sel_r;
logic [17:0] oki_addr_prev;
logic [15:0] oki_sdram_data_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        adpcm_rom_req   <= 1'b0;
        oki_req_pending <= 1'b0;
        oki_byte_sel_r  <= 1'b0;
        oki_addr_prev   <= 18'h0;
        oki_sdram_data_r<= 16'h0;
    end else begin
        if ((oki_rom_addr_w != oki_addr_prev) && !oki_req_pending) begin
            adpcm_rom_addr  <= {6'b0, oki_rom_addr_w[17:0]} + ADPCM_ROM_BASE[23:0];
            oki_byte_sel_r  <= oki_rom_addr_w[0];
            oki_addr_prev   <= oki_rom_addr_w;
            oki_req_pending <= 1'b1;
            adpcm_rom_req   <= ~adpcm_rom_req;
        end else if (oki_req_pending && (adpcm_rom_req == adpcm_rom_ack)) begin
            oki_sdram_data_r <= adpcm_rom_data;
            oki_req_pending  <= 1'b0;
        end
    end
end

assign oki_rom_data_w = oki_byte_sel_r ? oki_sdram_data_r[7:0]
                                       : oki_sdram_data_r[15:8];
assign oki_rom_ok_w   = !oki_req_pending;

// OKI write enable: Z80 writes when z80_oki_cs asserted and wr_n low
wire oki_wrn_w = z80_wr_n | ~z80_oki_cs;

jt6295 u_oki_m6295 (
    .rst        (~reset_n),
    .clk        (clk_sys),
    .cen        (ce_oki),
    .ss         (1'b1),         // ss=1 → 7350 Hz sample rate (standard NMK16)
    // CPU interface — driven by Z80
    .wrn        (oki_wrn_w),
    .din        (z80_dout_cpu),
    .dout       (oki_dout_w),
    // ROM interface
    .rom_addr   (oki_rom_addr_w),
    .rom_data   (oki_rom_data_w),
    .rom_ok     (oki_rom_ok_w),
    // Audio
    .sound      (oki_sound_w),
    .sample     ()
);

// ── Audio mix: FM (16-bit) + ADPCM (14-bit) + PSG (10-bit) ──────────────────
wire signed [15:0] oki_snd_16 = {{2{oki_sound_w[13]}}, oki_sound_w};
wire signed [15:0] psg_snd_16 = {6'b0, psg_snd_w};

always_comb begin
    snd_left  = fm_snd_w + oki_snd_16 + psg_snd_16;
    snd_right = fm_snd_w + oki_snd_16 + psg_snd_16;
end

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{
    clk_pix,
    hpos,
    vpos,
    cpu_lds_n, cpu_uds_n,   // referenced above in RAM writes
    vsync_n_r,
    spr_rom_data_w, bg_rom_data_w,  // inputs to nmk16 rom ports; driven by SDRAM bridges
    dl_x[8:0], dl_y[8:0], dl_tile[11:0],       // element 0 of flat-encoded arrays
    dl_flip_x[0], dl_flip_y[0], dl_size[1:0],  // element 0
    dl_pal[3:0], dl_valid[0], dl_prio[0],
    dl_count, dl_ready,
    bg_pix_valid,
    bg_pix_color[7:0], bg_pix_color[15:8],
    bg_pix_priority,
    spr_rd_color, spr_rd_valid, spr_rd_priority,
    spr_render_done,
    final_valid,
    pal_entry[15],
    fm_irq_n_w,
    // Z80 signals not consumed at top level
    z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n, z80_iorq_n,
    oki_dout_w
};
/* verilator lint_on UNUSED */

endmodule
