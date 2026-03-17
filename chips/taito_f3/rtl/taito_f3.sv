`default_nettype none
// =============================================================================
// taito_f3.sv — Taito F3 System Board Top-Level Integration
// =============================================================================
//
// Instantiates and wires:
//   tg68k_adapter   — MC68EC020 CPU (TG68K wrapped, 16→32-bit bus coalescer)
//   tc0630fdp       — F3 Display Processor (includes TC0650FDA palette DAC)
//   tc0640fio       — F3 I/O controller (joysticks, coins, EEPROM)
//   mb8421          — Dual-port RAM for main↔sound CPU communication
//
// Plus local block RAMs:
//   main_ram        — 128KB work RAM at 0x400000–0x41FFFF
//
// Clock domains:
//   clk_sys         — system clock (26.686 MHz), drives CPU bus + all digital logic
//   clk_pix         — pixel clock enable (1-cycle pulse in clk_sys domain, ÷4 ≈ 6.67 MHz)
//                     TC0630FDP uses its own internal timing; it receives clk_sys and
//                     generates pixel timing internally via the ce_pixel concept.
//
// Address map (68EC020 byte addresses, cpu_addr is word address [23:1]):
//   0x000000–0x1FFFFF: 68EC020 program ROM (SDRAM, via sdr_addr/sdr_data)
//   0x400000–0x41FFFF: Main work RAM (128KB BRAM, mirror at 0x420000)
//   0x440000–0x447FFF: TC0650FDA palette RAM (inside TC0630FDP; via fda_cpu_* ports)
//   0x4A0000–0x4A001F: TC0640FIO I/O registers
//   0x4C0000–0x4C0003: Timer control (stub — write-only, not stored)
//   0x600000–0x63FFFF: TC0630FDP video RAM (sprite, PF, text, char, line, pivot)
//   0x660000–0x66001F: TC0630FDP display control registers
//   0xC00000–0xC007FF: MB8421 dual-port RAM (sound communication)
//   0xC80000–0xC80003: Sound CPU reset assert
//   0xC80100–0xC80103: Sound CPU reset deassert
//
// Interrupt levels (fixed for all F3 titles):
//   IRQ2 = VBLANK  (TC0630FDP int_vblank → ipl_n = 3'b101)
//   IRQ3 = software timer ~10K CPU cycles after VBLANK (TC0630FDP int_hblank → ipl_n = 3'b100)
//
// Reference:
//   chips/taito_f3/integration_plan.md
//   chips/taito_b/rtl/taito_b.sv  (pattern reference)
//   src/mame/taito/taito_f3.cpp   (f3_map, interrupt2, trigger_int3)
//
// NOT instantiated here (provided by MiSTer HPS wrapper or stub):
//   SDRAM controller, Taito EN sound module (ES5505 + 68000), EEPROM 93C46
//
// =============================================================================
/* verilator lint_off SYNCASYNCNET */
module taito_f3 (
    // ── Clocks / Reset ────────────────────────────────────────────────────────
    input  logic        clk_sys,        // 26.686 MHz system clock
    input  logic        clk_pix,        // pixel clock enable (1-pulse per clk_sys, ÷4)
    input  logic        reset_n,        // active-low async reset

    // ── 68EC020 CPU Bus (driven from tg68k_adapter) ──────────────────────────
    // These signals connect taito_f3 ↔ tg68k_adapter internally.
    // Exposed as top-level ports so the HPS wrapper can observe/override.
    // In a fully self-contained system the tg68k_adapter is instantiated here.
    // (See CPU instantiation below; these are adapter ↔ system bus wires.)

    // ── Sound 68000 Bus ────────────────────────────────────────────────────────
    // The Taito EN sound module connects here.  Stub for initial integration.
    input  logic [15:0] snd_addr,       // sound CPU byte address [15:0]
    input  logic [15:0] snd_din,        // sound CPU write data
    output logic [15:0] snd_dout,       // sound CPU read data (from MB8421)
    input  logic        snd_rw,         // 1=read, 0=write
    input  logic        snd_as_n,       // address strobe
    output logic        snd_dtack_n,    // DTACK to sound CPU
    output logic        snd_reset_n,    // sound CPU reset (from main CPU writes)

    // ── GFX ROM Streams (4 independent, toggle-handshake) ─────────────────────
    // TC0630FDP exposes byte-address read strobes internally (gfx_lo_rd/gfx_hi_rd).
    // These are bridged to SDRAM arbiter toggle-handshake ports here.
    // spr_lo  → sprite low 4bpp planes
    // spr_hi  → sprite high 2bpp planes
    // tile_lo → tilemap low 4bpp planes
    // tile_hi → tilemap high 2bpp planes
    output logic [26:0] gfx_slo_addr,   // SDRAM word address (sprites lo)
    input  logic [31:0] gfx_slo_data,   // SDRAM read data
    output logic        gfx_slo_req,    // toggle-handshake request
    input  logic        gfx_slo_ack,    // toggle-handshake acknowledge

    output logic [26:0] gfx_shi_addr,   // SDRAM word address (sprites hi)
    input  logic [31:0] gfx_shi_data,   // SDRAM read data
    output logic        gfx_shi_req,
    input  logic        gfx_shi_ack,

    output logic [26:0] gfx_tlo_addr,   // SDRAM word address (tilemap lo)
    input  logic [31:0] gfx_tlo_data,   // SDRAM read data
    output logic        gfx_tlo_req,
    input  logic        gfx_tlo_ack,

    output logic [26:0] gfx_thi_addr,   // SDRAM word address (tilemap hi)
    input  logic [31:0] gfx_thi_data,   // SDRAM read data
    output logic        gfx_thi_req,
    input  logic        gfx_thi_ack,

    // ── SDRAM (program ROM + sound ROM) ───────────────────────────────────────
    output logic [26:0] sdr_addr,
    input  logic [31:0] sdr_data,
    output logic        sdr_req,
    input  logic        sdr_ack,

    // ── Video Output ─────────────────────────────────────────────────────────
    output logic [7:0]  rgb_r,
    output logic [7:0]  rgb_g,
    output logic [7:0]  rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Player Inputs (active-low) ────────────────────────────────────────────
    // joystick_p1[7:0]: bit layout per TC0640FIO IN.1:
    //   [3:0] = P1: bit0=UP, bit1=DOWN, bit2=LEFT, bit3=RIGHT
    //   [7:4] = P1 buttons [3:0]
    input  logic [7:0]  joystick_p1,
    input  logic [7:0]  joystick_p2,
    input  logic [1:0]  coin,           // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service         // service button (active low)
);

// =============================================================================
// SDRAM base addresses (fixed F3 layout)
// =============================================================================
localparam logic [26:0] GFX_SPR_LO_BASE  = 27'h0200000;  // 2MB: sprites lo 4bpp
localparam logic [26:0] GFX_SPR_HI_BASE  = 27'h0A00000;  // 8MB+: sprites hi 2bpp
localparam logic [26:0] GFX_TILE_LO_BASE = 27'h0E00000;  // tilemap lo
localparam logic [26:0] GFX_TILE_HI_BASE = 27'h1200000;  // tilemap hi
localparam logic [26:0] PROG_ROM_BASE    = 27'h0000000;  // 68EC020 program ROM

// =============================================================================
// Internal CPU Bus Signals (tg68k_adapter → system)
// =============================================================================
logic [23:1] cpu_addr;
logic [31:0] cpu_dout;        // CPU write data
logic [31:0] cpu_din;         // CPU read data (mux output → adapter)
logic        cpu_rw;          // 1=read, 0=write
logic        cpu_as_n;        // address strobe
logic [3:0]  cpu_be_n;        // byte enables (active low)
logic        cpu_dtack_n;     // DTACK to CPU adapter
logic [2:0]  cpu_ipl_n;       // interrupt priority level (active low)
logic        cpu_reset_n_out; // CPU reset output (drives sound module)

// =============================================================================
// Chip-Select Decode
// =============================================================================
// All comparisons on cpu_addr[23:1] (word address).
// AS_N qualification: include !cpu_as_n to prevent spurious decodes.

// Program ROM: 0x000000–0x1FFFFF → cpu_addr[23:21] == 3'b000
logic prog_rom_cs;
assign prog_rom_cs = (cpu_addr[23:21] == 3'b000) && !cpu_as_n;

// Main RAM: 0x400000–0x41FFFF (128KB) + mirror 0x420000–0x43FFFF
// cpu_addr[23:17] == 7'b001_0000 → 0x400000–0x41FFFF
// Mirror: ignore cpu_addr[17], so decode on [23:18]:
//   byte 0x400000 = word 0x200000 → cpu_addr[23:18] == 6'b001_000
//   byte 0x420000 = word 0x210000 → cpu_addr[23:18] == 6'b001_000 (same upper bits if A17 ignored)
// Actually simpler: cpu_addr[23:18] == 6'b001_000 covers both 0x400000 and 0x420000.
logic main_ram_cs;
assign main_ram_cs = (cpu_addr[23:18] == 6'b001_000) && !cpu_as_n;

// Palette RAM (TC0650FDA, inside TC0630FDP): 0x440000–0x447FFF
// cpu_addr[23:14] word == { 0x440000>>1 }[23:14] = { 0x220000 }[23:14] = 14'b00_1000_1000_00
// Simpler: byte addr 0x440000 → word 0x220000 → cpu_addr[23:15] = 9'b0_0100_0100
logic palette_cs;
assign palette_cs = (cpu_addr[23:15] == 9'b010001000) && !cpu_as_n;

// TC0640FIO: 0x4A0000–0x4A001F (32 bytes)
// Word base: 0x250000. Compare [23:5] == (0x4A0000>>1)[23:5] = 0x250000[23:5] = 19'h25000
logic ioc_cs_n;
assign ioc_cs_n = !((cpu_addr[23:5] == 19'h25000) && !cpu_as_n);

// Timer control: 0x4C0000–0x4C0003 (write-only stub)
// Word base: 0x260000. cpu_addr[23:2] == 22'h130000
logic timer_cs;
assign timer_cs = (cpu_addr[23:2] == 22'h130000) && !cpu_as_n;

// TC0630FDP video RAM: 0x600000–0x63FFFF (256KB)
// cpu_addr[23:18] word == 0x600000>>1 = 0x300000 → [23:18] = 6'b110_000
// 0x600000–0x63FFFF covers 256KB → [23:18] == 6'b11_0000 (top 6 bits)
logic fdp_video_cs;
assign fdp_video_cs = (cpu_addr[23:18] == 6'b110000) && !cpu_as_n;

// TC0630FDP control registers: 0x660000–0x66001F
// cpu_addr[23:5] == (0x660000>>1)[23:5] = 0x330000[23:5] = 19'h33000
logic fdp_ctrl_cs;
assign fdp_ctrl_cs = (cpu_addr[23:5] == 19'h33000) && !cpu_as_n;

// Combined TC0630FDP chip select (video RAM OR control registers)
logic fdp_cs;
assign fdp_cs = fdp_video_cs | fdp_ctrl_cs;

// MB8421 dual-port RAM: 0xC00000–0xC007FF (2KB)
// cpu_addr[23:10] == (0xC00000>>1)[23:10] = 0x600000[23:10] = 14'h1800
logic dpram_cs;
assign dpram_cs = (cpu_addr[23:10] == 14'h1800) && !cpu_as_n;

// Sound CPU reset: 0xC80000 (assert) and 0xC80100 (deassert)
// Word addr 0xC80000>>1 = 0x640000. cpu_addr[23:2] == 22'h320000
logic snd_rst0_cs;
assign snd_rst0_cs = (cpu_addr[23:2] == 22'h320000) && !cpu_as_n;
// Word addr 0xC80100>>1 = 0x640080. cpu_addr[23:2] == 22'h320040
logic snd_rst1_cs;
assign snd_rst1_cs = (cpu_addr[23:2] == 22'h320040) && !cpu_as_n;

// =============================================================================
// TC0630FDP — F3 Display Processor (includes TC0650FDA DAC)
// =============================================================================
// TC0630FDP uses the pixel clock domain internally.  On the FPGA the module
// runs at clk_sys and uses the clk_pix clock-enable for pixel-domain logic.
// The CPU interface of TC0630FDP is clocked at pixel rate (its posedge clk).
// The wrapper generates a 16-bit access from the 32-bit CPU bus.
//
// NOTE: TC0630FDP cpu_addr is [18:1] (chip-relative word address).
//       The FDP window starts at 0x600000 for video RAM and 0x660000 for ctrl.
//       Chip word addr = (byte_addr - 0x600000) >> 1.
//       For video:   chip_word = cpu_addr[18:1] - (0x600000>>1)[18:1]
//                              = cpu_addr[18:1]  (bits [18:1] within window)
//       For ctrl:    chip_word = 0x30000 (ctrl offset within FDP) + cpu_addr[4:1]
//                   The ctrl regs live at chip word 0x30000 which is outside the
//                   FDP video window mapping.  The FDP decodes ctrl internally
//                   when cs is asserted and addr[18:16]==3'b11.
//       Simplest: pass cpu_addr[18:1] directly; FDP uses its own internal decode.
//       For 0x660000: cpu_addr[18:1] = (0x660000>>1) & 0x3FFFF = 0x30000 [18:1].
//                     i.e., cpu_addr[18:1] when byte_addr=0x660000 is bits 18:1
//                     of the full word address 0x330000 → lower 18 bits = 0x30000.
//       This maps correctly into FDP's ctrl decode (case 3'b11 at [18:16]).
//
// TC0630FDP has a 16-bit CPU data bus.  For 32-bit CPU accesses, the upper
// word is accessed when cpu_addr[1]=0 (addr[1]=0→D31:D16), lower when [1]=1.
// The tg68k_adapter presents 32-bit data; we must pass the correct 16-bit half
// based on the current TG68K addr[1] bit.
// The FDP drives cpu_lds_n/cpu_uds_n for byte-lane select from cpu_be_n.
//
// Clock domain note: TC0630FDP is driven by clk_sys here; the pixel clock is
// provided as clk_pix (clock enable) for the FDA pipeline inside the FDP.
// The FDP's own timing counters use clk_sys directly.

logic [15:0] fdp_dout;
logic        fdp_dtack_n;
logic        fdp_int_vblank;
logic        fdp_int_hblank;

// FDP video output
logic [23:0] fdp_rgb_out;
logic        fdp_pixel_valid;
logic [7:0]  fdp_video_r;
logic [7:0]  fdp_video_g;
logic [7:0]  fdp_video_b;
logic [2:0]  fdp_pixel_valid_d;

// FDP timing outputs
logic [9:0]  fdp_hpos;
logic [8:0]  fdp_vpos;
logic        fdp_hblank;
logic        fdp_vblank;
logic        fdp_hsync;
logic        fdp_vsync;

// GFX ROM stub connections (byte-address interface from FDP)
// These are the FDP's internal byte-address ROM ports.  The SDRAM bridge
// below translates these to toggle-handshake SDRAM requests.
logic [24:0] fdp_gfx_lo_addr;
logic        fdp_gfx_lo_rd;
logic [7:0]  fdp_gfx_lo_data;
logic [24:0] fdp_gfx_hi_addr;
logic        fdp_gfx_hi_rd;
logic [7:0]  fdp_gfx_hi_data;

// Palette address from FDP (stub port — not used in integration; FDA is inside FDP)
logic [14:0] fdp_pal_addr;
logic        fdp_pal_rd;
logic [15:0] fdp_pal_data;

// 16-bit slice of CPU data for the FDP (word-addressed)
// addr[1]=0 → upper word D[31:16]; addr[1]=1 → lower word D[15:0]
logic [15:0] fdp_cpu_din_16;
assign fdp_cpu_din_16 = (cpu_addr[1] == 1'b0) ? cpu_dout[31:16] : cpu_dout[15:0];

// Byte enables for FDP (16-bit bus, 2 enables from 4)
logic fdp_cpu_uds_n;
logic fdp_cpu_lds_n;
always_comb begin
    if (cpu_addr[1] == 1'b0) begin
        // upper 16-bit word: be_n[3]=UDS, be_n[2]=LDS
        fdp_cpu_uds_n = cpu_be_n[3];
        fdp_cpu_lds_n = cpu_be_n[2];
    end else begin
        // lower 16-bit word: be_n[1]=UDS, be_n[0]=LDS
        fdp_cpu_uds_n = cpu_be_n[1];
        fdp_cpu_lds_n = cpu_be_n[0];
    end
end

// Expand 16-bit FDP read data to 32-bit based on which word was accessed
logic [31:0] fdp_dout_32;
assign fdp_dout_32 = (cpu_addr[1] == 1'b0) ? {fdp_dout, 16'hFFFF}
                                             : {16'hFFFF, fdp_dout};

// FDA CPU interface (palette writes, 32-bit, directly decoded at top level)
// TC0630FDP exposes fda_cpu_* ports for direct palette RAM access.
// cpu_addr[13:1] = 13-bit palette index for the 0x440000–0x447FFF window.
// Word address: (0x440000>>1) = 0x220000; index = cpu_addr[13:1].
logic fda_cpu_cs;
assign fda_cpu_cs = palette_cs && !cpu_as_n;

tc0630fdp u_fdp (
    .clk             (clk_sys),
    .async_rst_n     (reset_n),

    // CPU interface (16-bit, pixel-clock domain within FDP)
    .cpu_cs          (fdp_cs),
    .cpu_rw          (cpu_rw),
    .cpu_addr        (cpu_addr[18:1]),  // chip-relative word address
    .cpu_din         (fdp_cpu_din_16),
    .cpu_uds_n       (fdp_cpu_uds_n),
    .cpu_lds_n       (fdp_cpu_lds_n),
    .cpu_dout        (fdp_dout),
    .cpu_dtack_n     (fdp_dtack_n),

    // Video timing outputs
    .hblank          (fdp_hblank),
    .vblank          (fdp_vblank),
    .hsync           (fdp_hsync),
    .vsync           (fdp_vsync),
    .hpos            (fdp_hpos),
    .vpos            (fdp_vpos),

    // Interrupt outputs
    .int_vblank      (fdp_int_vblank),
    .int_hblank      (fdp_int_hblank),

    // GFX ROM byte-address interface (stub ports; bridged to SDRAM below)
    .gfx_lo_addr     (fdp_gfx_lo_addr),
    .gfx_lo_rd       (fdp_gfx_lo_rd),
    .gfx_lo_data     (fdp_gfx_lo_data),
    .gfx_hi_addr     (fdp_gfx_hi_addr),
    .gfx_hi_rd       (fdp_gfx_hi_rd),
    .gfx_hi_data     (fdp_gfx_hi_data),

    // Palette stub (not used externally; FDA is inside FDP)
    .pal_addr        (fdp_pal_addr),
    .pal_rd          (fdp_pal_rd),
    .pal_data        (fdp_pal_data),

    // Video output (stub — FDA outputs used below)
    .rgb_out         (fdp_rgb_out),
    .pixel_valid     (fdp_pixel_valid),

    // Testbench / step-validation outputs — tied or left open
    /* verilator lint_off PINCONNECTEMPTY */
    .text_pixel_out  (),
    .bg_pixel_out    (),
    .spr_pixel_out   (),
    .colmix_pixel_out(),
    .blend_rgb_out   (),
    .pivot_pixel_out (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Testbench write ports — tied off (not used at top level)
    .gfx_wr_addr     (22'b0),
    .gfx_wr_data     (32'b0),
    .gfx_wr_en       (1'b0),
    .spr_wr_addr     (15'b0),
    .spr_wr_data     (16'b0),
    .spr_wr_en       (1'b0),
    .pal_wr_addr     (13'b0),
    .pal_wr_data     (16'b0),
    .pal_wr_en       (1'b0),
    .pvt_wr_addr     (14'b0),
    .pvt_wr_data     (32'b0),
    .pvt_wr_en       (1'b0),

    // TC0650FDA CPU interface (palette writes, 32-bit direct)
    .fda_cpu_cs      (fda_cpu_cs),
    .fda_cpu_we      (!cpu_rw),
    .fda_cpu_addr    (cpu_addr[13:1]),  // 13-bit palette index
    .fda_cpu_din     (cpu_dout),        // 32-bit longword write
    .fda_cpu_be      (~cpu_be_n),       // active-high byte enables
    .fda_mode_12bit  (1'b0),            // RGB888 mode (hardwired; set 1 for 4 early games)

    // TC0650FDA video output
    .fda_video_r     (fdp_video_r),
    .fda_video_g     (fdp_video_g),
    .fda_video_b     (fdp_video_b),
    .fda_pixel_valid_d (fdp_pixel_valid_d)
);

// =============================================================================
// GFX ROM SDRAM Bridge (FDP byte-address → toggle-handshake)
// =============================================================================
// The FDP exposes TWO byte-address read strobes:
//   gfx_lo_rd + gfx_lo_addr[24:0] → sprite lo 4bpp planes
//   gfx_hi_rd + gfx_hi_addr[24:0] → sprite hi 2bpp (also used for tiles hi)
//
// NOTE: The current TC0630FDP stub has only gfx_lo and gfx_hi ports, shared
// for both sprites and tilemap.  Full 4-stream arbitration will be needed when
// the sprite/tile engines are active.  For now:
//   gfx_lo → spr_lo stream (GFX_SPR_LO_BASE)
//   gfx_hi → spr_hi stream (GFX_SPR_HI_BASE)
//   tile streams (gfx_tlo, gfx_thi): driven from GFX_TILE_LO_BASE / GFX_TILE_HI_BASE
//   (stub: no current FDP port for separate tile ROM — tile lo/hi held inactive)
//
// Each bridge: detect rising edge of rd strobe → compute SDRAM word addr →
// toggle req → wait for ack → present byte from 32-bit SDRAM word.

// ── GFX Lo (sprites lo 4bpp) ────────────────────────────────────────────────
logic       slo_rd_r;
logic       slo_pending;
logic [1:0] slo_byte_sel;  // which byte of 32-bit SDRAM word

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        gfx_slo_req  <= 1'b0;
        slo_pending  <= 1'b0;
        slo_rd_r     <= 1'b0;
        gfx_slo_addr <= 27'b0;
        slo_byte_sel <= 2'b0;
    end else begin
        slo_rd_r <= fdp_gfx_lo_rd;
        if (fdp_gfx_lo_rd && !slo_rd_r && !slo_pending) begin
            // Rising edge of gfx_lo_rd: issue new request
            gfx_slo_addr <= GFX_SPR_LO_BASE + {4'b0, fdp_gfx_lo_addr[24:2]};  // 32-bit word addr
            slo_byte_sel <= fdp_gfx_lo_addr[1:0];
            slo_pending  <= 1'b1;
            gfx_slo_req  <= ~gfx_slo_req;   // toggle to request
        end else if (slo_pending && (gfx_slo_req == gfx_slo_ack)) begin
            slo_pending <= 1'b0;
        end
    end
end

// Select byte from 32-bit SDRAM word (big-endian: byte 0 = bits[31:24])
always_comb begin
    case (slo_byte_sel)
        2'b00: fdp_gfx_lo_data = gfx_slo_data[31:24];
        2'b01: fdp_gfx_lo_data = gfx_slo_data[23:16];
        2'b10: fdp_gfx_lo_data = gfx_slo_data[15:8];
        2'b11: fdp_gfx_lo_data = gfx_slo_data[7:0];
    endcase
end

// ── GFX Hi (sprites hi 2bpp) ─────────────────────────────────────────────────
logic       shi_rd_r;
logic       shi_pending;
logic [1:0] shi_byte_sel;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        gfx_shi_req  <= 1'b0;
        shi_pending  <= 1'b0;
        shi_rd_r     <= 1'b0;
        gfx_shi_addr <= 27'b0;
        shi_byte_sel <= 2'b0;
    end else begin
        shi_rd_r <= fdp_gfx_hi_rd;
        if (fdp_gfx_hi_rd && !shi_rd_r && !shi_pending) begin
            gfx_shi_addr <= GFX_SPR_HI_BASE + {4'b0, fdp_gfx_hi_addr[24:2]};
            shi_byte_sel <= fdp_gfx_hi_addr[1:0];
            shi_pending  <= 1'b1;
            gfx_shi_req  <= ~gfx_shi_req;
        end else if (shi_pending && (gfx_shi_req == gfx_shi_ack)) begin
            shi_pending <= 1'b0;
        end
    end
end

always_comb begin
    case (shi_byte_sel)
        2'b00: fdp_gfx_hi_data = gfx_shi_data[31:24];
        2'b01: fdp_gfx_hi_data = gfx_shi_data[23:16];
        2'b10: fdp_gfx_hi_data = gfx_shi_data[15:8];
        2'b11: fdp_gfx_hi_data = gfx_shi_data[7:0];
    endcase
end

// ── Tile Lo / Hi — stub (no FDP port yet; hold inactive) ────────────────────
// These will be activated when TC0630FDP tilemap engine gets separate GFX ROM ports.
assign gfx_tlo_addr = GFX_TILE_LO_BASE;
assign gfx_tlo_req  = 1'b0;
assign gfx_thi_addr = GFX_TILE_HI_BASE;
assign gfx_thi_req  = 1'b0;

// Palette stub (pal_data fed back to FDP; FDA handles palette internally)
assign fdp_pal_data = 16'hFFFF;

// =============================================================================
// TC0640FIO — I/O Controller
// =============================================================================
logic [31:0] fio_dout;

// Build IN.0 (buttons + test + service + EEPROM DOUT):
//   bits[7:0]  = P1 buttons (active-low)
//   bits[15:8] = P2 buttons (active-low)
//   bits[23:16] = test/service/EEPROM DOUT
//   P1 buttons embedded in upper nibble of joystick_p1[7:4]
logic [31:0] fio_in0;
logic [31:0] fio_in1;
// IN.0 bit layout (from MAME f3_control_r):
//   bits[23:16]: EEPROM_DOUT, test, service, coin[1:0], START2, START1 (active-low)
//   bits[15:8]:  P2 buttons [3:0] active-low
//   bits[7:0]:   P1 buttons [3:0] active-low
assign fio_in0 = {8'hFF,                         // bits[31:24]: unused/open
                  2'b11, service, coin[1], coin[0], 3'b111, // bits[23:16]: service, coins, start(tied)
                  joystick_p2[7:4], 4'hF,         // bits[15:8]:  P2 buttons [3:0] active-low
                  joystick_p1[7:4], 4'hF};         // bits[7:0]:   P1 buttons [3:0] active-low

// IN.1: joystick directions (active-low)
//   [3:0] = P1: UP/DOWN/LEFT/RIGHT
//   [7:4] = P2: UP/DOWN/LEFT/RIGHT
assign fio_in1 = {16'hFFFF,                 // upper 16 bits unused
                  joystick_p2[3:0], 4'hF,   // bits[15:8]: P2 directions, upper nibble open
                  joystick_p1[3:0], 4'hF};  // bits[7:0]:  P1 directions, upper nibble open

logic fio_eeprom_do;   // EEPROM data out (to be routed into in0 bit by caller)
logic fio_eeprom_di;
logic fio_eeprom_clk;
logic fio_eeprom_cs;

tc0640fio u_fio (
    .clk        (clk_sys),
    .rst_n      (reset_n),

    .cs_n       (ioc_cs_n),
    .we         (!cpu_rw),
    .addr       (cpu_addr[4:1]),
    .din        (cpu_dout),
    .dout       (fio_dout),

    .in0        (fio_in0),
    .in1        (fio_in1),
    .in2        (32'hFFFF_FFFF),    // analog 1: inactive (all high = no input)
    .in3        (32'hFFFF_FFFF),    // analog 2: inactive
    .in4        (32'hFFFF_FFFF),    // P3+P4 buttons: inactive
    .in5        (32'hFFFF_FFFF),    // P3+P4 joy: inactive

    .eeprom_do  (fio_eeprom_do),
    .eeprom_di  (fio_eeprom_di),
    .eeprom_clk (fio_eeprom_clk),
    .eeprom_cs  (fio_eeprom_cs),

    /* verilator lint_off PINCONNECTEMPTY */
    .coin_lock  (),
    .coin_ctr   ()
    /* verilator lint_on PINCONNECTEMPTY */
);

// EEPROM stub: tie eeprom_do low (no external EEPROM in this integration)
assign fio_eeprom_do = 1'b0;

// =============================================================================
// MB8421 — Dual-Port RAM (main ↔ sound CPU)
// =============================================================================
logic [31:0] dpram_dout;

// Sound CPU side address decode (from snd_addr bus)
// Sound CPU maps MB8421 at 0x140000–0x1407FF (per MAME taito_en.cpp)
// snd_addr[15:0] is the sound CPU byte address.
// Since snd_addr[15:11] == 5'b0001_0 at 0x1400, but snd_addr is [15:0] here
// covering only the lower 16 bits of the 68000's 24-bit address space.
// We assume the HPS wrapper provides only the lower 16 bits, and CS decode
// was done externally.  For simplicity: right_cs = !snd_as_n (caller pre-decoded).
// right_addr[9:0] = snd_addr[10:1]

logic [15:0] dpram_right_dout;

mb8421 u_mb8421 (
    .clk         (clk_sys),

    // Left port: main 68EC020
    .left_cs     (dpram_cs),
    .left_we     (!cpu_rw),
    .left_addr   (cpu_addr[9:1]),    // 9-bit: 512 longwords = 2KB
    .left_din    (cpu_dout),
    .left_be_n   (cpu_be_n),
    .left_dout   (dpram_dout),

    // Right port: sound 68000
    .right_cs    (!snd_as_n),
    .right_we    (!snd_rw),
    .right_addr  (snd_addr[10:1]),
    .right_din   (snd_din),
    .right_be_n  ({!snd_din[15], !snd_din[0]}),   // approximate; caller should provide proper UDS/LDS
    .right_dout  (dpram_right_dout)
);

assign snd_dout   = dpram_right_dout;
assign snd_dtack_n = 1'b0;   // BRAM always ready

// =============================================================================
// Main Work RAM — 128KB (64K × 16-bit words = 32K × 32-bit)
// =============================================================================
// 32-bit wide, byte-enabled, synchronous.
// Main RAM covers 0x400000–0x41FFFF (128KB) + mirror 0x420000–0x43FFFF.
// cpu_addr[16:1] selects the 32-bit longword (2^16 = 64K words × 4 bytes = 256KB;
// but the physical RAM is 128KB so cpu_addr[16] is the mirror bit, ignored).

logic [31:0] work_ram [0:32767];   // 32K × 32-bit = 128KB
logic [31:0] wram_dout_r;
logic [14:0] wram_idx;
assign wram_idx = cpu_addr[15:1];  // 15-bit longword index into 128KB

always_ff @(posedge clk_sys) begin
    if (main_ram_cs && !cpu_rw) begin
        if (!cpu_be_n[3]) work_ram[wram_idx][31:24] <= cpu_dout[31:24];
        if (!cpu_be_n[2]) work_ram[wram_idx][23:16] <= cpu_dout[23:16];
        if (!cpu_be_n[1]) work_ram[wram_idx][15:8]  <= cpu_dout[15:8];
        if (!cpu_be_n[0]) work_ram[wram_idx][7:0]   <= cpu_dout[7:0];
    end
    if (main_ram_cs) wram_dout_r <= work_ram[wram_idx];
end

// =============================================================================
// Program ROM SDRAM Bridge
// =============================================================================
// Simple 1-cycle registered DTACK for ROM (SDRAM must be pre-loaded and
// ready within 1 cycle — typical MiSTer zero-wait-state ROM arbiter pattern).
// Full SDRAM request/ack is handled by the HPS wrapper; here we expose the
// SDRAM port and trust the wrapper to provide data within 1 cycle.
// For correctness: use a toggle-handshake similar to GFX ROM bridges.

logic       rom_pending;
logic [31:0] rom_data_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        sdr_req      <= 1'b0;
        rom_pending  <= 1'b0;
        sdr_addr     <= 27'b0;
        rom_data_r   <= 32'b0;
    end else begin
        if (prog_rom_cs && cpu_rw && !rom_pending && !cpu_as_n) begin
            // New program ROM read: issue SDRAM request
            sdr_addr    <= PROG_ROM_BASE + {4'b0, cpu_addr[22:1]};  // 32-bit word addr
            sdr_req     <= ~sdr_req;
            rom_pending <= 1'b1;
        end else if (rom_pending && (sdr_req == sdr_ack)) begin
            rom_data_r  <= sdr_data;
            rom_pending <= 1'b0;
        end
    end
end

// =============================================================================
// CPU Read Data Mux
// =============================================================================
// Priority: FDP (video) > palette (FDA, inside FDP) > FIO > DPRAM > RAM > ROM
// All return 32-bit data; 0xFFFFFFFF for open-bus.

always_comb begin
    if (fdp_cs)
        cpu_din = fdp_dout_32;
    else if (palette_cs)
        cpu_din = 32'hFFFF_FFFF;   // FDA is write-only from CPU (no read path in TC0650FDA)
    else if (!ioc_cs_n)
        cpu_din = fio_dout;
    else if (dpram_cs)
        cpu_din = dpram_dout;
    else if (main_ram_cs)
        cpu_din = wram_dout_r;
    else if (prog_rom_cs)
        cpu_din = rom_data_r;
    else
        cpu_din = 32'hFFFF_FFFF;   // open bus
end

// =============================================================================
// DTACK Generation
// =============================================================================
// TC0630FDP drives its own dtack (registered 1-cycle pipeline inside FDP).
// All other regions: 1-cycle registered DTACK.

logic any_fast_cs;
logic dtack_r;

// Fast-DTACK regions: everything except FDP and ROM (which use their own dtack)
assign any_fast_cs = main_ram_cs | palette_cs | !ioc_cs_n | dpram_cs | timer_cs |
                     snd_rst0_cs | snd_rst1_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        dtack_r <= 1'b0;
    else
        dtack_r <= any_fast_cs;
end

// ROM DTACK: ready when SDRAM ack received
logic rom_dtack;
assign rom_dtack = prog_rom_cs && !rom_pending && (sdr_req == sdr_ack) && cpu_rw;

// Combined DTACK mux:
//   FDP: use FDP's internal dtack (already 1-cycle registered internally)
//   Palette (FDA): zero-wait (tc0650fda.cpu_dtack_n is permanently 0, so treat as ready)
//   Fast regions: dtack_r (1-cycle registered)
//   ROM: rom_dtack (toggle-handshake)
assign cpu_dtack_n = cpu_as_n     ? 1'b1
                   : fdp_cs       ? fdp_dtack_n
                   : palette_cs   ? 1'b0           // FDA always ready
                   : prog_rom_cs  ? !rom_dtack
                   :                !dtack_r;

// =============================================================================
// Interrupt Controller
// =============================================================================
// TC0630FDP outputs int_vblank (IRQ2) and int_hblank (IRQ3) as single-cycle
// pulses.  HOLD_LINE semantics: latch and hold until CPU acknowledges.
// Self-clearing: use a 16-bit timer (65536 sys clocks ~ 2.4ms >> one frame).

logic        irq2_active, irq3_active;
logic [15:0] irq2_timer,  irq3_timer;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        irq2_active <= 1'b0;
        irq3_active <= 1'b0;
        irq2_timer  <= 16'b0;
        irq3_timer  <= 16'b0;
    end else begin
        // IRQ2 = VBLANK
        if (fdp_int_vblank) begin
            irq2_active <= 1'b1;
            irq2_timer  <= 16'hFFFF;
        end else if (irq2_active) begin
            if (irq2_timer == 16'b0)
                irq2_active <= 1'b0;
            else
                irq2_timer <= irq2_timer - 16'd1;
        end

        // IRQ3 = software timer (~10K CPU cycles after VBLANK)
        if (fdp_int_hblank) begin
            irq3_active <= 1'b1;
            irq3_timer  <= 16'hFFFF;
        end else if (irq3_active) begin
            if (irq3_timer == 16'b0)
                irq3_active <= 1'b0;
            else
                irq3_timer <= irq3_timer - 16'd1;
        end
    end
end

// IPL encoding (active-low, IRQ3 > IRQ2):
always_comb begin
    if      (irq3_active) cpu_ipl_n = 3'b100;  // IRQ3: ipl_n = ~3 = 100
    else if (irq2_active) cpu_ipl_n = 3'b101;  // IRQ2: ipl_n = ~2 = 101
    else                  cpu_ipl_n = 3'b111;  // no interrupt
end

// =============================================================================
// Sound CPU Reset Control
// =============================================================================
// 0xC80000 write → assert reset (snd_reset_n = 0)
// 0xC80100 write → deassert reset (snd_reset_n = 1)

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        snd_reset_n <= 1'b0;   // hold sound CPU in reset at power-on
    else begin
        if (snd_rst0_cs && !cpu_rw)
            snd_reset_n <= 1'b0;   // assert reset
        else if (snd_rst1_cs && !cpu_rw)
            snd_reset_n <= 1'b1;   // deassert reset
    end
end

// =============================================================================
// TG68K CPU Adapter
// =============================================================================

tg68k_adapter u_cpu (
    .clk            (clk_sys),
    .reset_n        (reset_n),
    .ipl_n          (cpu_ipl_n),

    // 32-bit system bus
    .cpu_addr       (cpu_addr),
    .cpu_dout       (cpu_dout),
    .cpu_din        (cpu_din),
    .cpu_rw         (cpu_rw),
    .cpu_as_n       (cpu_as_n),
    .cpu_be_n       (cpu_be_n),
    .cpu_dtack_n    (cpu_dtack_n),
    .cpu_reset_n_out(cpu_reset_n_out)
);

// =============================================================================
// Video Output
// =============================================================================
// TC0650FDA (inside TC0630FDP) outputs fda_video_r/g/b with a 3-pixel-clock
// pipeline delay.  The FDP also outputs hblank/vblank/hsync/vsync.
// Use the FDA's pixel_valid_d[2] to generate aligned blanking if needed.
// For now: pass FDP sync/blank directly (3-cycle delay from FDA is small).

assign rgb_r   = fdp_video_r;
assign rgb_g   = fdp_video_g;
assign rgb_b   = fdp_video_b;
assign hsync_n = !fdp_hsync;
assign vsync_n = !fdp_vsync;
assign hblank  = fdp_hblank;
assign vblank  = fdp_vblank;

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{clk_pix, gfx_tlo_data, gfx_thi_data, gfx_tlo_ack, gfx_thi_ack,
                   fdp_rgb_out, fdp_pixel_valid, fdp_hpos, fdp_vpos,
                   fdp_pal_addr, fdp_pal_rd, fdp_pixel_valid_d,
                   cpu_reset_n_out, fio_eeprom_di, fio_eeprom_clk, fio_eeprom_cs,
                   snd_addr[15:11], snd_addr[0], snd_din[14:1]};
/* verilator lint_on UNUSED */

endmodule
