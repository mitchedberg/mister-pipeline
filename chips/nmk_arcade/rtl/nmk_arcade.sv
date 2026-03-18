// =============================================================================
// nmk_arcade.sv — NMK16 System Board Top-Level Integration
// =============================================================================
//
// Instantiates and wires:
//   nmk16      — graphics subsystem (registers + sprite scanner + BG tilemaps
//                + sprite rasterizer + priority mixer)
//
// Plus local block RAMs:
//   work_ram   — 64KB at 0x080000–0x08FFFF (MC68000 general-purpose)
//   palette_ram — 512 entries × 16-bit at 0x0E0000–0x0E03FF (CPU-writable)
//
// Z80 sound CPU: T80s core, 8 MHz, drives YM2203 and OKI M6295
//
// Target game: Thunder Dragon (nmk16 hardware variant)
//   MC68000 @ 10 MHz, VBLANK IRQ = level 4
//
// Memory map (byte addresses):
//   0x000000–0x07FFFF  Program ROM (512KB, SDRAM)
//   0x080000–0x08FFFF  Work RAM (64KB, BRAM)
//   0x0C0000–0x0CFFFF  NMK16 chip (registers, sprite RAM, tilemap VRAM)
//   0x0E0000–0x0E03FF  Palette RAM (512 entries × 16-bit, BRAM)
//   0x0E8000–0x0E8FFF  I/O registers (joystick, coin, DIP)
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
    parameter int unsigned WRAM_ABITS = 15,

    // ── Palette RAM ────────────────────────────────────────────────────────────
    // 512 entries × 16-bit: 9-bit word address
    parameter int unsigned PAL_ABITS  = 9,

    // ── GFX ROM SDRAM base ─────────────────────────────────────────────────────
    // Sprite ROM base address in SDRAM (byte address, stored at SDRAM offset)
    parameter logic [26:0] SPR_ROM_BASE = 27'h0C0000,

    // BG tile ROM base in SDRAM
    parameter logic [26:0] BG_ROM_BASE  = 27'h140000
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

// Program ROM: upper 7 bits = 0 → 0x000000–0x07FFFF
logic prog_rom_cs;
assign prog_rom_cs = (cpu_addr[23:17] == 7'b0) && !cpu_as_n;

// Work RAM: 64KB at 0x080000–0x08FFFF
logic wram_cs;
assign wram_cs = (cpu_addr[23:16] == 8'h04) && !cpu_as_n;
// Note: byte_addr = cpu_addr[23:1] << 1; top byte = cpu_addr[23:17] << 1.
// 0x080000 >> 1 = 0x040000; cpu_addr[23:16] for word addr: 0x040000 >> 8 = 0x04 ✓

// NMK16 chip: 0x0C0000–0x0CFFFF → word base 0x060000
logic nmk_cs_n;
assign nmk_cs_n = !((cpu_addr[23:16] == 8'h06) && !cpu_as_n);

// Palette RAM: 0x0E0000–0x0E03FF → word base 0x070000, top 9 bits word addr[23:9]
// 0x0E0000 >> 1 = 0x070000; cpu_addr[23:9] == {8'h07, 7'b0} ? No —
// 0x070000 in 23-bit word space: cpu_addr[23:16]=8'h07, cpu_addr[15:9]=7'b0
logic pal_cs;
assign pal_cs = (cpu_addr[23:16] == 8'h07) && (cpu_addr[15:9] == 7'b0) && !cpu_as_n;

// I/O: 0x0E8000–0x0E8FFF → word base 0x074000
// 0x0E8000 >> 1 = 0x074000; cpu_addr[23:12] == 12'h074
logic io_cs;
assign io_cs  = (cpu_addr[23:12] == 12'h074) && !cpu_as_n;

// =============================================================================
// NMK16 Chip Instance
// =============================================================================
// The NMK16 chip addr port is [ADDR_WIDTH-1:1] = [20:1] (21-bit word addr).
// The chip uses bit [20:16] for range decode internally.
// We pass cpu_addr[21:1] — enough to cover 0x0C0000–0x0CFFFF inside the chip
// (chip sees bit [20:16] patterns for its own sub-ranges; the full byte address
// 0x0C0000 >> 1 = 0x060000, so within the chip window we pass the low bits).

// NMK16 chip internal sub-range decode uses addr[20:16]:
//   Tilemap RAM: addr[20:16]=5'b10001 → 0x110000 in chip's 21-bit space
//   GPU regs:    addr[20:16]=5'b10010 → 0x120000 in chip's 21-bit space
//   Sprite RAM:  addr[20:16]=5'b10011 → 0x130000 in chip's 21-bit space
//   Palette:     addr[20:16]=5'b10100 → 0x140000 in chip's 21-bit space
//
// When the system CS window is 0x0C0000–0x0CFFFF (64KB), internal offsets
// map directly: cpu_addr[16:1] → chip addr[16:1].
// We tie the top bits to select the correct sub-window:
//   chip_addr[20:17] = 4'b1000 | (cpu_addr[16:16] = 0) → addr[20:16]=5'b10000
// This means the 64KB window maps to chip addr 0x100000–0x10FFFF.
// That doesn't match the chip's internal decode pattern.
//
// SOLUTION: Use the chip's full 21-bit address space and pass the offset within
// the 0x0C0000 window by constructing:
//   chip_addr[20:1] = {4'b0001, cpu_addr[16:1]}  → maps 0x0C0000 to chip 0x010000
// But the chip's decode uses specific top-bit patterns.
//
// Simplest approach: pass the raw cpu_addr lower bits and set the top bits
// so the chip sees 0x110000–0x13FFFF range from the CPU perspective.
// The outer CS gate (nmk_cs_n) already qualifies accesses to 0x0C0000–0x0CFFFF.
// We remap: chip_addr = {5'b10000, cpu_addr[16:1]} giving chip range 0x100000–0x10FFFF
// Then add per-sub-region offsets to hit 0x110000/0x120000/0x130000/0x140000.
//
// Better: connect chip addr[20:1] directly to {cpu_addr[20:1]} — the chip will
// decode based on addr[20:16]. For the window 0x0C0000–0x0CFFFF, those bits are:
//   cpu_addr[23:1]  for 0x0C0000 byte = 0x060000 word: bits[23:20]=4'b0000, [19:16]=4'b0110
// So addr[20:16] = 5'b00110 from the CPU word address. That matches none of the
// chip's internal patterns (which expect 5'b10001 etc.).
//
// CORRECT APPROACH: The chip's internal address decode was designed for an NMK board
// where the full 21-bit address bus is used (chip sits at system base 0x000000).
// Since we use it as a peripheral chip at 0x0C0000, we simply pass the OFFSET within
// the chip's window and prepend the required range prefix bits manually.
//
// Tile/Sprite/GPU sub-ranges within 0x0C0000 block:
//   0x0C0000 + offset: we pick three 64KB sub-windows by the caller's design.
//   The GATE_PLAN uses a flat 0x0C0000–0x0CFFFF window for NMK16.
//   We break this up by asserting cs_n only when in that range, and passing
//   addr[20:1] = {5'b10001, cpu_addr[15:1]} for tilemap (first 32KB of window),
//   etc. But 64KB isn't enough for all three ranges at native addresses.
//
// PRACTICAL IMPLEMENTATION: Use cpu_addr[15:14] to select sub-range offset:
//   cpu_addr[15:14]=2'b00 → tilemap  → chip sees addr[20:16]=5'b10001
//   cpu_addr[15:14]=2'b01 → GPU regs → chip sees addr[20:16]=5'b10010
//   cpu_addr[15:14]=2'b10 → sprites  → chip sees addr[20:16]=5'b10011
//   (palette handled externally)
//
// So the system byte map within 0x0C0000 window:
//   0x0C0000–0x0C3FFF → tilemap RAM  (16KB, chip 0x110000–0x113FFF)
//   0x0C4000–0x0C7FFF → GPU regs    (16KB, chip 0x120000–0x123FFF)
//   0x0C8000–0x0CBFFF → sprite RAM  (16KB, chip 0x130000–0x133FFF)
//   0x0CC000–0x0CFFFF → (unused)

// Construct chip address: remap cpu_addr offset into chip's 21-bit space
logic [20:1] chip_addr;
always_comb begin
    case (cpu_addr[15:14])
        2'b00:   chip_addr = {5'b10001, cpu_addr[15:1]};   // tilemap RAM
        2'b01:   chip_addr = {5'b10010, cpu_addr[15:1]};   // GPU registers
        2'b10:   chip_addr = {5'b10011, cpu_addr[15:1]};   // sprite RAM
        default: chip_addr = {5'b10001, cpu_addr[15:1]};   // fallback: tilemap
    endcase
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
    .sprite_addr_rd (9'b0),
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
    .scan_trigger     (1'b0),          // stub — no rasterizer pump
    .current_scanline (9'b0),
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
// Sprite ROM SDRAM Bridge
// spr_rom_addr_w is a 21-bit BYTE address into sprite ROM.
// SDRAM uses 16-bit word access: SDRAM_word_addr = SPR_ROM_BASE + byte_addr[20:1]
// =============================================================================
logic        spr_req_pending;
logic        spr_byte_sel;
logic [26:0] spr_req_addr;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        spr_rom_sdram_req <= 1'b0;
        spr_req_pending   <= 1'b0;
        spr_byte_sel      <= 1'b0;
        spr_req_addr      <= 27'b0;
    end else begin
        if (spr_rom_rd_w && !spr_req_pending) begin
            spr_req_addr      <= SPR_ROM_BASE + {6'b0, spr_rom_addr_w[20:1]};
            spr_byte_sel      <= spr_rom_addr_w[0];
            spr_req_pending   <= 1'b1;
            spr_rom_sdram_req <= ~spr_rom_sdram_req;
        end else if (spr_req_pending && (spr_rom_sdram_req == spr_rom_sdram_ack)) begin
            spr_req_pending <= 1'b0;
        end
    end
end

assign spr_rom_sdram_addr = spr_req_addr;
// Big-endian: even byte → data[15:8], odd → data[7:0]
assign spr_rom_data_w = spr_byte_sel ? spr_rom_sdram_data[7:0]
                                     : spr_rom_sdram_data[15:8];

// =============================================================================
// BG Tile ROM SDRAM Bridge
// bg_rom_addr_w is a 22-bit BYTE address into BG tile ROM.
// =============================================================================
logic        bg_req_pending;
logic        bg_byte_sel;
logic [26:0] bg_req_addr;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        bg_rom_sdram_req <= 1'b0;
        bg_req_pending   <= 1'b0;
        bg_byte_sel      <= 1'b0;
        bg_req_addr      <= 27'b0;
    end else begin
        if (!bg_pix_valid[0] && !bg_pix_valid[1] && !bg_req_pending) begin
            // Opportunistically prefetch; actual demand is implicit from nmk16
            // In practice Gate 4 drives bg_rom_addr combinationally; we just
            // latch it when there is no valid pixel (conservative stub).
            bg_req_addr      <= BG_ROM_BASE + {5'b0, bg_rom_addr_w[21:1]};
            bg_byte_sel      <= bg_rom_addr_w[0];
            bg_req_pending   <= 1'b1;
            bg_rom_sdram_req <= ~bg_rom_sdram_req;
        end else if (bg_req_pending && (bg_rom_sdram_req == bg_rom_sdram_ack)) begin
            bg_req_pending <= 1'b0;
        end
    end
end

assign bg_rom_sdram_addr = bg_req_addr;
assign bg_rom_data_w     = bg_byte_sel ? bg_rom_sdram_data[7:0]
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
        if (prog_rom_cs && cpu_rw && !prog_req_pending) begin
            // New ROM read request
            prog_req_addr_r  <= {5'b0, cpu_addr[22:1]};   // word addr in SDRAM (27-bit)
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
    .byteena_b(2'h3), .clocken0(1'b1), .clocken1(1'b1),
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
    .byteena_b(2'h3), .clocken0(1'b1), .clocken1(1'b1),
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
    .byteena_b(2'h3), .clocken0(1'b1), .clocken1(1'b1),
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
// I/O Register File
// 0x0E8000–0x0E8FFF: read-only input ports
//   +0x00: P1 joystick [7:0] (active low)
//   +0x02: P2 joystick [7:0] (active low)
//   +0x04: {coin[1], coin[0], service, 5'b11111} (active low)
//   +0x06: DIP switch bank 1
//   +0x08: DIP switch bank 2
// Sound latch: 0x0E8002 byte write (lower byte) → sound_cmd
// =============================================================================
logic [15:0] io_dout;

// Sound command latch — captured when M68000 writes to 0x0E8002 (lower byte)
logic [7:0] sound_cmd;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        sound_cmd <= 8'h00;
    else if (io_cs && !cpu_rw && (cpu_addr[4:1] == 4'h1) && !cpu_lds_n)
        sound_cmd <= cpu_din[7:0];   // Z80 polls this via sound_cmd latch
end

always_comb begin
    io_dout = 16'hFFFF;
    if (io_cs) begin
        case (cpu_addr[4:1])
            4'h0: io_dout = {8'hFF, joystick_p1};
            4'h1: io_dout = {8'hFF, joystick_p2};
            4'h2: io_dout = {8'hFF, coin[1], coin[0], service, 5'b11111};
            4'h3: io_dout = {8'hFF, dipsw1};
            4'h4: io_dout = {8'hFF, dipsw2};
            default: io_dout = 16'hFFFF;
        endcase
    end
end

// =============================================================================
// CPU Data Bus Read Mux
// Priority: prog_rom > NMK16 > work_ram > palette_ram > io > open-bus
// =============================================================================
always_comb begin
    if (prog_rom_cs)
        cpu_dout = prog_rom_data_r;
    else if (!nmk_cs_n)
        cpu_dout = nmk_dout;
    else if (wram_cs)
        cpu_dout = wram_dout_r;
    else if (pal_cs)
        cpu_dout = pal_dout_r;
    else if (io_cs)
        cpu_dout = io_dout;
    else
        cpu_dout = 16'hFFFF;   // open bus
end

// =============================================================================
// DTACK Generation
// All regions: 1-cycle registered DTACK.
// =============================================================================
logic any_cs;
logic dtack_r;

assign any_cs = prog_rom_cs | !nmk_cs_n | wram_cs | pal_cs | io_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        dtack_r <= 1'b0;
    else
        dtack_r <= any_cs;
end

assign cpu_dtack_n = cpu_as_n ? 1'b1 : !dtack_r;

// =============================================================================
// Interrupt (IPL) Generation — VBLANK at level 4
// =============================================================================
logic        ipl4_active;
logic [15:0] ipl4_timer;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl4_active <= 1'b0;
        ipl4_timer  <= 16'b0;
    end else begin
        if (nmk_irq_vblank_pulse) begin
            ipl4_active <= 1'b1;
            ipl4_timer  <= 16'hFFFF;
        end else if (ipl4_active) begin
            if (ipl4_timer == 16'b0)
                ipl4_active <= 1'b0;
            else
                ipl4_timer <= ipl4_timer - 16'd1;
        end
    end
end

// IPL4 encoding: level 4 = ~4 = 3'b011 (active low)
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
            adpcm_rom_addr  <= {6'b0, oki_rom_addr_w[17:1]} + ADPCM_ROM_BASE[23:0];
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
    chip_addr,
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
