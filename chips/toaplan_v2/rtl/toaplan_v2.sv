// =============================================================================
// toaplan_v2.sv — Toaplan V2 System Board Top-Level Integration
// =============================================================================
//
// Implements the Toaplan V2 arcade board (Batsugun target).
//
// Instantiates and wires:
//   GP9001    — graphics processor (tilemaps + sprites + priority mixer)
//   Work RAM  — 64KB at 0x100000–0x10FFFF
//   Palette RAM — 512 × 16-bit at 0x500000–0x5003FF (RGB555 format)
//   I/O regs  — joysticks, coins, DIP switches at 0x700000–0x700FFF
//
// Stubs (silence output, no logic):
//   Z80 sound CPU
//   YM2151 + OKI M6295 audio
//
// Address map (byte addresses, from MAME toaplan2.cpp):
//   0x000000–0x0FFFFF   1MB     Program ROM (from SDRAM)
//   0x100000–0x10FFFF   64KB    Work RAM
//   0x400000–0x40FFFF   64KB    GP9001 (registers + sprite RAM + VRAM)
//   0x500000–0x5003FF   1KB     Palette RAM (512 × 16-bit, R5G5B5)
//   0x700000–0x700FFF   4KB     I/O registers
//
// IRQ assignment (from MAME):
//   IRQ2 (IPL = 3'b101) — VBLANK
//   IRQ1 (IPL = 3'b110) — GP9001 sprite scan complete
//
// Video timing: 320×240, standard arcade horizontal/vertical rates.
// Palette format: 0xRRRRRGGGGGBBBBB (standard GP9001 5-5-5 RGB).
//
// Reference: MAME src/mame/toaplan/toaplan2.cpp, batsugun driver
//            chips/gp9001/rtl/gp9001.sv
//            chips/toaplan/README.md
//
// =============================================================================
`default_nettype none

/* verilator lint_off SYNCASYNCNET */
module toaplan_v2 #(
    // ── Address decode parameters (WORD addresses = byte_addr >> 1) ────────────
    // GP9001 chip select: byte 0x400000–0x40FFFF → word base 0x200000
    //   11-bit window: addr[10:0] are chip-relative (gp9001 addr input)
    parameter logic [23:1] GP9001_BASE = 23'h200000,  // byte 0x400000 >> 1
    // Palette RAM: byte 0x500000–0x5003FF → word base 0x280000
    //   9-bit window (512 words = 1KB)
    parameter logic [23:1] PALRAM_BASE = 23'h280000,  // byte 0x500000 >> 1
    // I/O: byte 0x700000–0x700FFF → word base 0x380000
    //   11-bit window
    parameter logic [23:1] IO_BASE     = 23'h380000,  // byte 0x700000 >> 1
    // Work RAM: byte 0x100000–0x10FFFF → word base 0x080000
    //   15-bit window (32K words = 64KB)
    parameter logic [23:1] WRAM_BASE   = 23'h080000,  // byte 0x100000 >> 1
    parameter int WRAM_WORDS = 32768                    // 64KB / 2 = 32K words

) (
    input  logic        clk_sys,
    input  logic        clk_pix,         // pixel clock enable (1-cycle pulse, sys-domain)
    input  logic        reset_n,

    // ── CPU bus (from fx68k_adapter) ───────────────────────────────────────────
    input  logic [23:1] cpu_addr,
    input  logic [15:0] cpu_dout,        // data FROM cpu (write path)
    output logic [15:0] cpu_din,         // data TO cpu (read path mux)
    input  logic        cpu_rw,          // 1=read, 0=write
    input  logic        cpu_as_n,        // address strobe (active low)
    input  logic        cpu_uds_n,       // upper data strobe (active low)
    input  logic        cpu_lds_n,       // lower data strobe (active low)
    output logic        cpu_dtack_n,     // data transfer acknowledge (active low)
    output logic [2:0]  cpu_ipl_n,       // interrupt priority level (active low encoded)

    // ── Program ROM (from SDRAM) ───────────────────────────────────────────────
    // prog_rom_addr is a WORD address (byte_addr[19:1]).
    output logic [19:1] prog_rom_addr,
    input  logic [15:0] prog_rom_data,
    output logic        prog_rom_req,
    input  logic        prog_rom_ack,

    // ── GFX ROM (sprite + BG tiles, from SDRAM) ────────────────────────────────
    // 32-bit wide for tile fetch efficiency (GP9001 reads 4bpp packed bytes).
    // gfx_rom_addr is a WORD address (byte_addr >> 1).
    output logic [21:0] gfx_rom_addr,
    input  logic [31:0] gfx_rom_data,
    output logic        gfx_rom_req,
    input  logic        gfx_rom_ack,

    // ── Video output ───────────────────────────────────────────────────────────
    output logic [7:0]  rgb_r,
    output logic [7:0]  rgb_g,
    output logic [7:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Player inputs ──────────────────────────────────────────────────────────
    // Active-low convention.
    // [7]=BTN3 [6]=BTN2 [5]=BTN1 [4]=START [3]=RIGHT [2]=LEFT [1]=DOWN [0]=UP
    input  logic [7:0]  joystick_p1,
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,            // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service,         // service button (active low)
    input  logic [7:0]  dipsw1,          // DIP switch bank 1
    input  logic [7:0]  dipsw2           // DIP switch bank 2
);

// =============================================================================
// Local parameters
// =============================================================================

localparam int WRAM_ABITS = $clog2(WRAM_WORDS);   // 15

// =============================================================================
// Video Timing Generator — 320×240 standard arcade
// =============================================================================
//
// Horizontal: 320 active, 24 front porch, 32 sync, 40 back porch = 416 total
// Vertical:   240 active, 12 front porch, 4  sync,  8 back porch = 264 total
//
// These match the GP9001 internal timing used in MAME toaplan2.cpp.
// Pixel clock enable (clk_pix) drives hpos/vpos advancement.
//
localparam int H_ACTIVE = 320;
localparam int H_FP     = 24;
localparam int H_SYNC   = 32;
localparam int H_BP     = 40;
localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 416

localparam int V_ACTIVE = 240;
localparam int V_FP     = 12;
localparam int V_SYNC   = 4;
localparam int V_BP     = 8;
localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;    // 264

logic [8:0] hpos_r;    // 0..415
logic [8:0] vpos_r;    // 0..263
logic       hsync_r, vsync_r, hblank_r, vblank_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        hpos_r   <= 9'h000;
        vpos_r   <= 9'h000;
        hsync_r  <= 1'b1;
        vsync_r  <= 1'b1;
        hblank_r <= 1'b0;
        vblank_r <= 1'b0;
    end else if (clk_pix) begin
        // Horizontal counter
        if (hpos_r == 9'(H_TOTAL - 1))
            hpos_r <= 9'h000;
        else
            hpos_r <= hpos_r + 9'd1;

        // Vertical counter (increment at end of each line)
        if (hpos_r == 9'(H_TOTAL - 1)) begin
            if (vpos_r == 9'(V_TOTAL - 1))
                vpos_r <= 9'h000;
            else
                vpos_r <= vpos_r + 9'd1;
        end

        // HSync: asserted during sync pulse
        hsync_r <= ~((hpos_r >= 9'(H_ACTIVE + H_FP)) && (hpos_r < 9'(H_ACTIVE + H_FP + H_SYNC)));
        // VSync: asserted during sync pulse
        vsync_r <= ~((vpos_r >= 9'(V_ACTIVE + V_FP)) && (vpos_r < 9'(V_ACTIVE + V_FP + V_SYNC)));
        // HBlank: asserted during horizontal blanking
        hblank_r <= (hpos_r >= 9'(H_ACTIVE));
        // VBlank: asserted during vertical blanking
        vblank_r <= (vpos_r >= 9'(V_ACTIVE));
    end
end

assign hsync_n = hsync_r;
assign vsync_n = vsync_r;
assign hblank  = hblank_r;
assign vblank  = vblank_r;

// Active pixel positions fed to GP9001 (within visible area only)
wire [8:0] pix_hpos = (hpos_r < 9'(H_ACTIVE)) ? hpos_r : 9'h000;
wire [8:0] pix_vpos = (vpos_r < 9'(V_ACTIVE)) ? vpos_r : 9'h000;

// VBLANK edge detection for sprite scanner trigger
logic vblank_prev;
logic vblank_rising;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) vblank_prev <= 1'b0;
    else          vblank_prev <= vblank_r;
end

assign vblank_rising = vblank_r & ~vblank_prev;

// =============================================================================
// Chip-Select Decode
// =============================================================================

// Program ROM: 0x000000–0x0FFFFF (byte), word 0x000000–0x07FFFF
//   20-bit window: cpu_addr[19:0] within 1MB
logic prog_rom_cs;
assign prog_rom_cs = (cpu_addr[23:20] == 4'b0000) && !cpu_as_n;

// Work RAM: byte 0x100000–0x10FFFF → word 0x080000–0x087FFF (15-bit)
logic wram_cs;
assign wram_cs = (cpu_addr[23:WRAM_ABITS] == WRAM_BASE[23:WRAM_ABITS]) && !cpu_as_n;

// GP9001: byte 0x400000–0x40FFFF → word 0x200000–0x2007FF
//   11-bit chip-relative window (gp9001 addr[10:0])
logic gp9001_cs_n;
assign gp9001_cs_n = !((cpu_addr[23:11] == GP9001_BASE[23:11]) && !cpu_as_n);

// Palette RAM: byte 0x500000–0x5003FF → word 0x280000–0x2801FF (9-bit window)
logic palram_cs;
assign palram_cs = (cpu_addr[23:9] == PALRAM_BASE[23:9]) && !cpu_as_n;

// I/O: byte 0x700000–0x700FFF → word 0x380000–0x3807FF (11-bit window)
logic io_cs;
assign io_cs = (cpu_addr[23:11] == IO_BASE[23:11]) && !cpu_as_n;

// =============================================================================
// GP9001 — Graphics Processor
// =============================================================================

logic [15:0] gp9001_dout;
logic        gp9001_irq_sprite;

// GP9001 GFX ROM bridge signals
logic [19:0] bg_rom_addr_raw;    // from GP9001 Gate 3
logic [7:0]  bg_rom_data_r;      // fed back to GP9001
logic [3:0]  bg_layer_sel;       // one-hot layer select from GP9001

logic [20:0] spr_rom_addr_raw;   // from GP9001 Gate 4 (21-bit byte address)
logic        spr_rom_rd;         // GP9001 read strobe
logic [7:0]  spr_rom_data_r;     // fed back to GP9001

// Gate 3/4 BG and sprite outputs (unused in stub — silence)
logic [3:0]  bg_pix_valid_w;
logic [7:0]  bg_pix_color_w [0:3];
logic        bg_pix_priority_w [0:3];
logic [15:0] vram_dout_w;

// Gate 4 sprite outputs
logic [8:0]  spr_rd_addr_w;
logic [7:0]  spr_rd_color_w;
logic        spr_rd_valid_w;
logic        spr_rd_priority_w;
logic        spr_render_done_w;

// Gate 5 pixel output
logic [7:0]  final_color_w;
logic        final_valid_w;

// Scan trigger: pulse at hblank falling edge during active display
logic hblank_prev;
logic scan_trigger_w;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) hblank_prev <= 1'b0;
    else          hblank_prev <= hblank_r;
end

// Falling edge of hblank (transition active→display) triggers scanline render
assign scan_trigger_w = hblank_prev & ~hblank_r;

// GP9001 display-list outputs (not used in system integration yet)
/* verilator lint_off UNUSED */
sprite_entry_t display_list_w [0:255];
logic [7:0]    display_list_count_w;
logic          display_list_ready_w;
/* verilator lint_on UNUSED */

// GP9001 register outputs (not needed at integration level)
logic [15:0] scroll_w [0:7];
logic [15:0] scroll0_x_w, scroll0_y_w, scroll1_x_w, scroll1_y_w;
logic [15:0] scroll2_x_w, scroll2_y_w, scroll3_x_w, scroll3_y_w;
logic [15:0] rowscroll_ctrl_w, layer_ctrl_w, sprite_ctrl_w;
logic [15:0] layer_size_w, color_key_w, blend_ctrl_w;
logic [1:0]  num_layers_active_w, bg0_priority_w, bg1_priority_w, bg23_priority_w;
logic [3:0]  sprite_list_len_code_w;
logic [1:0]  sprite_sort_mode_w, sprite_prefetch_mode_w;
logic        sprite_en_w;
logic [9:0]  scan_addr_w;
logic [15:0] scan_dout_w;

assign scan_addr_w = 10'h000;   // tie off debug port

gp9001 #(
    .NUM_LAYERS (2)    // Batsugun: 2 active BG layers (BG0 + BG1)
) u_gp9001 (
    .clk        (clk_sys),
    .rst_n      (reset_n),

    // CPU interface — chip-relative 11-bit word address: cpu_addr[11:1]
    .addr       (cpu_addr[11:1]),
    .din        (cpu_dout),
    .dout       (gp9001_dout),
    .cs_n       (gp9001_cs_n),
    .rd_n       (cpu_rw  ? 1'b0 : 1'b1),   // rd_n active low when cpu reads
    .wr_n       (!cpu_rw ? 1'b0 : 1'b1),   // wr_n active low when cpu writes

    // Video timing
    .vsync      (~vsync_r),     // active-high for GP9001 (vsync_r is active-low)
    .vblank     (vblank_r),

    // Interrupt output
    .irq_sprite (gp9001_irq_sprite),

    // Register outputs (tie to local wires; unused at integration level)
    .scroll             (scroll_w),
    .scroll0_x          (scroll0_x_w),
    .scroll0_y          (scroll0_y_w),
    .scroll1_x          (scroll1_x_w),
    .scroll1_y          (scroll1_y_w),
    .scroll2_x          (scroll2_x_w),
    .scroll2_y          (scroll2_y_w),
    .scroll3_x          (scroll3_x_w),
    .scroll3_y          (scroll3_y_w),
    .rowscroll_ctrl     (rowscroll_ctrl_w),
    .layer_ctrl         (layer_ctrl_w),
    .num_layers_active  (num_layers_active_w),
    .bg0_priority       (bg0_priority_w),
    .bg1_priority       (bg1_priority_w),
    .bg23_priority      (bg23_priority_w),
    .sprite_ctrl        (sprite_ctrl_w),
    .sprite_list_len_code (sprite_list_len_code_w),
    .sprite_sort_mode   (sprite_sort_mode_w),
    .sprite_prefetch_mode (sprite_prefetch_mode_w),
    .layer_size         (layer_size_w),
    .color_key          (color_key_w),
    .blend_ctrl         (blend_ctrl_w),
    .sprite_en          (sprite_en_w),

    // Sprite RAM debug scan port
    .scan_addr  (scan_addr_w),
    .scan_dout  (scan_dout_w),

    // Gate 2: Display list
    .display_list       (display_list_w),
    .display_list_count (display_list_count_w),
    .display_list_ready (display_list_ready_w),

    // Gate 3: Tilemap pixel pipeline
    .hpos           (pix_hpos),
    .vpos           (pix_vpos),
    .hblank         (hblank_r),
    .vblank_in      (vblank_r),
    .bg_pix_valid   (bg_pix_valid_w),
    .bg_pix_color   (bg_pix_color_w),
    .bg_pix_priority (bg_pix_priority_w),
    .bg_rom_addr    (bg_rom_addr_raw),
    .bg_rom_data    (bg_rom_data_r),
    .bg_layer_sel   (bg_layer_sel),
    .vram_dout      (vram_dout_w),

    // Gate 4: Sprite rasterizer
    .scan_trigger      (scan_trigger_w),
    .current_scanline  (pix_vpos),
    .spr_rom_addr      (spr_rom_addr_raw),
    .spr_rom_rd        (spr_rom_rd),
    .spr_rom_data      (spr_rom_data_r),
    .spr_rd_addr       (spr_rd_addr_w),
    .spr_rd_color      (spr_rd_color_w),
    .spr_rd_valid      (spr_rd_valid_w),
    .spr_rd_priority   (spr_rd_priority_w),
    .spr_render_done   (spr_render_done_w),

    // Gate 5: Priority mixer outputs
    .final_color    (final_color_w),
    .final_valid    (final_valid_w)
);

// Feed current pixel X back to Gate 4 scanline buffer read port
assign spr_rd_addr_w = pix_hpos;

// =============================================================================
// GFX ROM SDRAM Bridge — time-multiplexed BG tile + Sprite tile access
// =============================================================================
//
// GP9001 Gate 3 (BG tiles) and Gate 4 (sprite tiles) each produce byte
// addresses into the GFX ROM.  For now, a simple arbitration: bg_rom
// has lower priority, spr_rom wins when spr_rom_rd is asserted.
//
// gfx_rom_addr is a WORD address (byte_addr[21:1]).
// gfx_rom_data is 32-bit; we select the correct byte lane from bit[1:0]
// of the original byte address.
//
// SDRAM base layout for Batsugun GFX ROM:
//   - BG tiles start at SDRAM offset 0x000000 (gfx_rom_addr is direct)
//   - Sprite tiles are appended after BG tiles; offset added externally
//     via emu.sv (caller passes the correct SDRAM base in the ROM loader).
//
// Current implementation: round-robin request toggle per chip.
// bg_rom_data: GP9001 Gate 3 byte fetch — select from 32-bit word
// spr_rom_data: GP9001 Gate 4 byte fetch — select from 32-bit word

logic        gfx_pending;
logic [21:0] gfx_pending_addr;
logic [1:0]  gfx_pending_byte_sel;
logic        gfx_is_sprite;   // 1=sprite request, 0=bg request

// Byte-lane mux (combinational, outside always_ff to avoid Verilator complaints)
logic [7:0] gfx_byte_out;
always_comb begin
    unique case (gfx_pending_byte_sel)
        2'b00: gfx_byte_out = gfx_rom_data[7:0];
        2'b01: gfx_byte_out = gfx_rom_data[15:8];
        2'b10: gfx_byte_out = gfx_rom_data[23:16];
        2'b11: gfx_byte_out = gfx_rom_data[31:24];
    endcase
end

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        gfx_rom_req          <= 1'b0;
        gfx_pending          <= 1'b0;
        gfx_pending_addr     <= 22'b0;
        gfx_pending_byte_sel <= 2'b0;
        gfx_is_sprite        <= 1'b0;
        bg_rom_data_r        <= 8'h00;
        spr_rom_data_r       <= 8'h00;
    end else begin
        if (!gfx_pending) begin
            if (spr_rom_rd) begin
                // Sprite tile ROM request — higher priority
                gfx_pending_addr     <= {1'b0, spr_rom_addr_raw[20:0]};
                gfx_pending_byte_sel <= spr_rom_addr_raw[1:0];
                gfx_is_sprite        <= 1'b1;
                gfx_pending          <= 1'b1;
                gfx_rom_req          <= ~gfx_rom_req;
            end else begin
                // BG tile ROM request (GP9001 Gate 3 always requesting)
                gfx_pending_addr     <= {2'b0, bg_rom_addr_raw};
                gfx_pending_byte_sel <= bg_rom_addr_raw[1:0];
                gfx_is_sprite        <= 1'b0;
                gfx_pending          <= 1'b1;
                gfx_rom_req          <= ~gfx_rom_req;
            end
        end else if (gfx_rom_req == gfx_rom_ack) begin
            // SDRAM has returned data; latch selected byte lane
            if (gfx_is_sprite)
                spr_rom_data_r <= gfx_byte_out;
            else
                bg_rom_data_r  <= gfx_byte_out;
            gfx_pending <= 1'b0;
        end
    end
end

assign gfx_rom_addr = gfx_pending_addr;

// =============================================================================
// Work RAM — 64KB synchronous block RAM
// =============================================================================

logic [15:0] work_ram [0:WRAM_WORDS-1];
logic [15:0] wram_dout_r;

always_ff @(posedge clk_sys) begin
    if (wram_cs && !cpu_rw) begin
        if (!cpu_uds_n) work_ram[cpu_addr[WRAM_ABITS:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) work_ram[cpu_addr[WRAM_ABITS:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (wram_cs) wram_dout_r <= work_ram[cpu_addr[WRAM_ABITS:1]];
end

// =============================================================================
// Palette RAM — 512 × 16-bit synchronous block RAM
// =============================================================================
// Format: 0bRRRRRGGGGGBBBBB (bit 15 unused / transparent flag)
// CPU accesses palette at byte 0x500000–0x5003FF.
// During active display, final_color from GP9001 Gate 5 (8-bit palette index)
// indexes into this RAM to produce RGB output.

logic [15:0] palette_ram [0:511];
logic [15:0] palram_cpu_dout;

always_ff @(posedge clk_sys) begin
    if (palram_cs && !cpu_rw) begin
        if (!cpu_uds_n) palette_ram[cpu_addr[9:1]][15:8] <= cpu_dout[15:8];
        if (!cpu_lds_n) palette_ram[cpu_addr[9:1]][ 7:0] <= cpu_dout[ 7:0];
    end
end

always_ff @(posedge clk_sys) begin
    if (palram_cs) palram_cpu_dout <= palette_ram[cpu_addr[9:1]];
end

// Pixel-domain palette lookup: final_color_w[7:0] → palette_ram entry
// GP9001 final_color is 8-bit {palette[3:0], index[3:0]}, giving 256 entries.
// Palette RAM has 512 entries; index sits in [8:0] with MSB = 0 for standard entries.
// Pipelined 1 cycle with clk_pix to stay aligned with pixel stream.
logic [15:0] pal_entry_r;
always_ff @(posedge clk_sys) begin
    if (clk_pix) pal_entry_r <= palette_ram[{1'b0, final_color_w}];
end

// Expand R5G5B5 → R8G8B8 (replicate 3 MSBs into low 3 bits).
// Bit [15] of palette entry is unused (transparent flag, not needed here).
assign rgb_r = {pal_entry_r[14:10], pal_entry_r[14:12]};
assign rgb_g = {pal_entry_r[9:5],   pal_entry_r[9:7]};
assign rgb_b = {pal_entry_r[4:0],   pal_entry_r[4:2]};

// =============================================================================
// I/O Registers
// =============================================================================
// Batsugun I/O map (byte addresses within 0x700000 window, from MAME):
//   0x700000 — Player 1 joystick + buttons (read)
//   0x700002 — Player 2 joystick + buttons (read)
//   0x700004 — Coins + service (read)
//   0x700006 — DIP switch bank 1 (read)
//   0x700008 — DIP switch bank 2 (read)
//   0x70000E — Z80 sound command (write only — stub, ignored)
//
// All registers are byte-wide on the lower byte (D[7:0]).
// Word reads return the active byte in [7:0], [15:8] = 0xFF.

logic [7:0] io_dout_byte;

always_comb begin
    io_dout_byte = 8'hFF;   // default: open bus
    case (cpu_addr[3:1])   // A[3:1] selects register
        3'h0: io_dout_byte = joystick_p1;
        3'h1: io_dout_byte = joystick_p2;
        3'h2: io_dout_byte = {2'b11, service, 1'b1, coin[1], coin[0], 2'b11};
        3'h3: io_dout_byte = dipsw1;
        3'h4: io_dout_byte = dipsw2;
        default: io_dout_byte = 8'hFF;
    endcase
end

// =============================================================================
// Program ROM Request Bridge
// =============================================================================
// Simple toggle-handshake to SDRAM.
// CPU stalls via cpu_dtack_n until prog_rom_ack toggles back.

logic prog_req_pending;
logic [19:1] prog_req_addr_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        prog_rom_req      <= 1'b0;
        prog_req_pending  <= 1'b0;
        prog_req_addr_r   <= 19'b0;
    end else begin
        if (prog_rom_cs && cpu_rw && !prog_req_pending) begin
            prog_req_addr_r  <= cpu_addr[19:1];
            prog_req_pending <= 1'b1;
            prog_rom_req     <= ~prog_rom_req;
        end else if (prog_req_pending && (prog_rom_req == prog_rom_ack)) begin
            prog_req_pending <= 1'b0;
        end
    end
end

assign prog_rom_addr = prog_req_addr_r;

// =============================================================================
// CPU Data Bus Read Mux
// =============================================================================
// Priority: GP9001 > palette RAM > I/O > WRAM > prog ROM > open bus

always_comb begin
    if (!gp9001_cs_n)
        cpu_din = gp9001_dout;
    else if (palram_cs)
        cpu_din = palram_cpu_dout;
    else if (io_cs)
        cpu_din = {8'hFF, io_dout_byte};
    else if (wram_cs)
        cpu_din = wram_dout_r;
    else if (prog_rom_cs)
        cpu_din = prog_rom_data;
    else
        cpu_din = 16'hFFFF;   // open bus
end

// =============================================================================
// DTACK Generation
// =============================================================================
// Prog ROM: stall until SDRAM ack (prog_req_pending goes low)
// All other devices: 1-cycle DTACK

logic any_fast_cs;
logic dtack_r;

assign any_fast_cs = !gp9001_cs_n | palram_cs | io_cs | wram_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) dtack_r <= 1'b0;
    else          dtack_r <= any_fast_cs;
end

always_comb begin
    if (cpu_as_n)
        cpu_dtack_n = 1'b1;
    else if (prog_rom_cs)
        cpu_dtack_n = prog_req_pending;   // 0 when SDRAM returns data
    else
        cpu_dtack_n = !dtack_r;
end

// =============================================================================
// Interrupt (IPL) Generation
// =============================================================================
// IRQ2 = VBLANK   → IPL 3'b101 (level 2, active-low encoded: ~2 = 3'b101)
// IRQ1 = irq_sprite (sprite scan complete from GP9001) → IPL 3'b110 (level 1)

logic ipl_vbl_active;
logic [15:0] ipl_vbl_timer;
logic ipl_spr_active;
logic [15:0] ipl_spr_timer;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl_vbl_active <= 1'b0;
        ipl_vbl_timer  <= 16'b0;
        ipl_spr_active <= 1'b0;
        ipl_spr_timer  <= 16'b0;
    end else begin
        // VBLANK → IRQ2
        if (vblank_rising) begin
            ipl_vbl_active <= 1'b1;
            ipl_vbl_timer  <= 16'hFFFF;
        end else if (ipl_vbl_active) begin
            if (ipl_vbl_timer == 16'b0)
                ipl_vbl_active <= 1'b0;
            else
                ipl_vbl_timer <= ipl_vbl_timer - 16'd1;
        end

        // Sprite scan complete → IRQ1
        if (gp9001_irq_sprite) begin
            ipl_spr_active <= 1'b1;
            ipl_spr_timer  <= 16'hFFFF;
        end else if (ipl_spr_active) begin
            if (ipl_spr_timer == 16'b0)
                ipl_spr_active <= 1'b0;
            else
                ipl_spr_timer <= ipl_spr_timer - 16'd1;
        end
    end
end

// Encode IPL: higher level wins; cpu_ipl_n is active-low encoded
always_comb begin
    if (ipl_vbl_active)       cpu_ipl_n = 3'b101;   // ~2 = level 2 VBLANK
    else if (ipl_spr_active)  cpu_ipl_n = 3'b110;   // ~1 = level 1 sprite
    else                      cpu_ipl_n = 3'b111;   // no interrupt
end

// =============================================================================
// Lint suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = &{
    1'b0,
    // GP9001 register outputs not used at integration level
    scroll_w[0], scroll_w[1], scroll_w[2], scroll_w[3],
    scroll_w[4], scroll_w[5], scroll_w[6], scroll_w[7],
    scroll0_x_w, scroll0_y_w, scroll1_x_w, scroll1_y_w,
    scroll2_x_w, scroll2_y_w, scroll3_x_w, scroll3_y_w,
    rowscroll_ctrl_w, layer_ctrl_w, sprite_ctrl_w,
    layer_size_w, color_key_w, blend_ctrl_w,
    num_layers_active_w, bg0_priority_w, bg1_priority_w, bg23_priority_w,
    sprite_list_len_code_w, sprite_sort_mode_w, sprite_prefetch_mode_w,
    sprite_en_w, scan_dout_w,
    display_list_count_w, display_list_ready_w,
    bg_pix_valid_w,
    bg_pix_color_w[0], bg_pix_color_w[1], bg_pix_color_w[2], bg_pix_color_w[3],
    bg_pix_priority_w[0], bg_pix_priority_w[1],
    bg_pix_priority_w[2], bg_pix_priority_w[3],
    vram_dout_w,
    bg_layer_sel,
    spr_rd_color_w, spr_rd_valid_w, spr_rd_priority_w,
    spr_render_done_w, spr_rom_rd,
    final_valid_w,
    pal_entry_r[15]         // transparent/unused bit in R5G5B5 palette entry
};
/* verilator lint_on UNUSED */

endmodule
