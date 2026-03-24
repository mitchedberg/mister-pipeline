// segas32_top.sv — Sega System 32 System-Level Integration
//
// Wires the NEC V60 CPU core to the Sega System 32 video hardware.
// Implements the address decoder, ROM interface, work RAM, and
// VBLANK interrupt generation.
//
// ── System Memory Map ────────────────────────────────────────────────────────
//   0x000000–0x0FFFFF   Program ROM (1 MB, external SRAM/ROM model)
//   0x200000–0x20FFFF   Work RAM (64 KB, internal SRAM)
//   0x300000–0x31FFFF   Video RAM → segas32_video cpu_vram
//   0x400000–0x41FFFF   Sprite RAM → segas32_video cpu_spr
//   0x500000–0x50000F   Sprite Control → segas32_video cpu_sprctl
//   0x600000–0x60FFFF   Palette RAM → segas32_video cpu_pal
//   0x610000–0x61007F   Mixer Control → segas32_video cpu_mix
//   0x700000–0x70001F   Layer scroll (I/O stub — real: 315-5641)
//   0xC00000–0xC0007F   315-5296 I/O chip (stub)
//   0xD00000–0xD0000F   V60 interrupt controller (internal)
//   0xE00000–0xE0000F   ASIC control (stub)
//   0xF00000–0xFFFFFF   ROM mirror (same as 0x000000–0x0FFFFF)
//
// ── Clock Domains ────────────────────────────────────────────────────────────
//   clk_cpu   : V60 system clock (16 MHz or as driven by top level)
//   clk_pix   : pixel clock for segas32_video (~6.14 MHz for 320-mode)
//
// ── VBLANK Interrupt ─────────────────────────────────────────────────────────
//   The video module asserts vblank at the end of the active area (vpos=224).
//   On the rising edge of vblank the interrupt controller sets the pending bit
//   for source 0 (VBLANK_START) and asserts irq_n to the V60.
//   The interrupt is cleared when the CPU writes to the interrupt controller's
//   pending register (offset 7, bit 0).
//
// ── GFX ROM ──────────────────────────────────────────────────────────────────
//   The sprite/tilemap GFX ROM is NOT part of the program ROM.  The video
//   module drives gfx_addr/gfx_rd and expects gfx_data back.  In this top
//   level the GFX ROM is a separate port so the testbench can supply it.
//
// Reference: MAME src/mame/sega/segas32.cpp, segas32_v.cpp
// ============================================================================

`default_nettype none
`timescale 1ns/1ps

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module segas32_top (
    // ── Clocks and Reset ─────────────────────────────────────────────────────
    input  logic        clk_cpu,        // V60 system clock
    input  logic        clk_pix,        // pixel clock for video hardware
    input  logic        rst_n,

    // ── Program ROM interface (external) ────────────────────────────────────
    // Byte-addressed; top provides ROM data.  Read-only.
    output logic [23:0] rom_addr,       // byte address into program ROM
    input  logic [15:0] rom_data,       // little-endian 16-bit word
    output logic        rom_rd,         // 1 = active read cycle

    // ── GFX ROM interface (external, for segas32_video tile renderer) ────────
    input  logic [31:0] gfx_data,       // tile/sprite data from GFX ROM
    output logic [21:0] gfx_addr,       // byte address into GFX ROM
    output logic        gfx_rd,

    // ── Video outputs ─────────────────────────────────────────────────────────
    output logic        hsync,
    output logic        vsync,
    output logic        hblank,
    output logic        vblank,
    output logic [9:0]  hpos,
    output logic [8:0]  vpos,
    output logic        pixel_active,
    output logic [7:0]  pixel_r,
    output logic [7:0]  pixel_g,
    output logic [7:0]  pixel_b,
    output logic        pixel_de,

    // ── NMI (test / debug injection) ──────────────────────────────────────────
    // Tie to 1'b1 in normal operation; assert low for 1+ cycles to force NMI.
    input  logic        nmi_n,

    // ── Debug / test ports ────────────────────────────────────────────────────
    output logic [31:0] dbg_pc,
    output logic [31:0] dbg_psw,
    output logic [31:0] dbg_sp,
    output logic        dbg_halted,
    output logic        dbg_trapped,
    output logic [7:0]  dbg_opcode,

    // ── Bus monitor (for testbench diagnostics) ────────────────────────────────
    output logic [23:0] dbg_cpu_addr,    // V60 bus address (all cycles)
    output logic [15:0] dbg_cpu_data_o,  // V60 bus write data
    output logic [15:0] dbg_cpu_data_i,  // V60 bus read data (to CPU)
    output logic        dbg_cpu_as_n,    // address strobe (active low)
    output logic        dbg_cpu_rw,      // 1=read, 0=write

    // ── EEPROM interface (93C46) ───────────────────────────────────────────────
    // The 315-5296 port D drives CS/CLK/DI; port F bit 7 is EEPROM DO.
    // These ports allow the testbench to implement the 93C46 state machine.
    output logic [7:0]  io_portd,        // last written value to C00006 (port D)
    input  logic        eeprom_do        // EEPROM serial output (→ port F bit 7)
);

// =============================================================================
// SECTION 1: V60 CPU bus signals
// =============================================================================

logic [23:0] cpu_addr;
logic [15:0] cpu_data_i;   // data to CPU
logic [15:0] cpu_data_o;   // data from CPU
logic        cpu_as_n;     // address strobe (active low)
logic        cpu_rw;       // 1=read, 0=write
logic [1:0]  cpu_ds_n;     // byte enables (active low)
logic        cpu_dtack_n;  // transfer ack (0=done)
logic        cpu_irq_n;
logic [7:0]  cpu_irq_vec;

// =============================================================================
// SECTION 2: V60 CPU Instantiation
// =============================================================================

v60_core u_v60 (
    .clk         (clk_cpu),
    .rst_n       (rst_n),

    .addr_o      (cpu_addr),
    .data_i      (cpu_data_i),
    .data_o      (cpu_data_o),
    .as_n        (cpu_as_n),
    .rw          (cpu_rw),
    .ds_n        (cpu_ds_n),
    .dtack_n     (cpu_dtack_n),

    .irq_n       (cpu_irq_n),
    .irq_vector  (cpu_irq_vec),
    .nmi_n       (nmi_n),

    .dbg_pc      (dbg_pc),
    .dbg_psw     (dbg_psw),
    .dbg_sp      (dbg_sp),
    .dbg_halted  (dbg_halted),
    .dbg_trapped (dbg_trapped),
    .dbg_opcode  (dbg_opcode)
);

// =============================================================================
// SECTION 3: Work RAM (64 KB at 0x200000–0x20FFFF)
// =============================================================================

// Byte-addressable 64KB = 32K × 16-bit words.
// Address index: cpu_addr[16:1] (bits 16 down to 1, bit 0 = byte select).
logic [15:0] work_ram [0:32767];  // 32K words

// Pre-initialize work RAM to simulate Z80 boot initialization (simulation only).
// The V60 boot loop at 0x7F938-0x7F9B6 compares:
//   [R25]=[0x208000] (work_ram word 0x4000) vs [R11+0x1A]=[0x20F02A] (work_ram word 0x7815)
// The loop exits when work_ram[0x4000] < work_ram[0x7815] (unsigned 16-bit compare).
// In MAME, the Z80 increments 0x208000; we stub this by setting the threshold > 0.
// Setting work_ram[0x7815]=1 ensures the V60 exits the boot wait on its first pass.
// NOTE: Quartus cannot unroll 32K-iteration loops at synthesis time; this block is
// excluded from synthesis. Hardware RAM starts undefined — game software initializes it.
/* synthesis translate_off */
initial begin
    for (int i = 0; i < 32768; i++) work_ram[i] = 16'h0000;
    // Boot loop exit condition analysis (from V60 bootrom trace):
    //   MOV.W R0, [R25 + 0x7050]  where R25=0x208000 → reads addr 0x20F050 = work_ram[0x7828]
    //   CMP.W R0, [R11 + 0x1A]    where R11=0x20F010 → reads addr 0x20F02A = work_ram[0x7815]
    //   BL8 +6                     → exits if R0 (unsigned) < [R11+0x1A]
    // With work_ram[0x7828]=0 (R0=0) and work_ram[0x7815]=1 (threshold=1):
    //   0 < 1 → BL8 fires → boot loop exits on first pass.
    work_ram[16'h7815] = 16'h0001;   // threshold = 1
    // work_ram[0x7828] stays 0 (R0 will be 0, < threshold=1)
end
/* synthesis translate_on */

logic        wram_cs;
logic [15:0] wram_rdata;

assign wram_cs = (cpu_addr[23:17] == 7'b001_0000);  // 0x200000–0x21FFFF (covers 0x200000-0x21FFFF)
// Mask to 64KB: cpu_addr[16:1] gives word address

// =============================================================================
// SECTION 3b: Shared RAM (8 KB at 0x700000–0x701FFF)
// =============================================================================
// V60↔Z80 communication RAM. The V60 CRC boot check reads/writes this area.
// MAME: map(0x700000,0x701fff).mirror(0x0fe000).rw(shared_ram_r, shared_ram_w)
// This region is PURELY shared RAM — no scroll registers or I/O here.
// Scroll registers live in VRAM space at 0x31FF00–0x31FF8E.
// 8KB = 4K × 16-bit words. Address bits [12:1] index the word array.

logic [15:0] shared_ram [0:4095];  // 4K words (8KB byte-addressed)

// Shared RAM boot-time state: all zeros.
//
// The IC21 boot ROM expects SRAM to be fully zeroed at power-on.
// MAME Lua tap (mame_combined.log frame 1) confirms: all of 0x701F00-0x701F81
// read as 0x0000 when the V60 first checks the CRC. The CRC therefore fails
// (computed CRC ≠ 0x0000), triggering the IC21 "first boot" error path at
// 0x7F8E7/0x7F91B which copies default data from IC21 ROM into SRAM and
// writes 0xFFFF to 0x701F24/0x701F26 itself. Starting with any non-zero
// value at 0x701F00 (e.g. 0x286C) causes the IC21 to take the "already
// initialized" path, which gets stuck waiting for SRAM data that never
// arrives without a running Z80.
initial begin
    for (int i = 0; i < 4096; i++) shared_ram[i] = 16'h0000;
end

logic        sram_cs;
logic [15:0] sram_rdata;

// Chip select: 0x700000–0x701FFF
// cpu_addr[23:20] == 4'h7 AND cpu_addr[19:13] == 7'b000_0000 (bits 19-13 = 0)
assign sram_cs = (cpu_addr[23:20] == 4'h7) && (cpu_addr[19:13] == 7'h00);

// =============================================================================
// SECTION 4: Address Decoder — Chip Select Signals
// =============================================================================

logic rom_cs;        // 0x0xxxxx or 0xFxxxxx
logic vram_cs;       // 0x3xxxxx  → Video RAM
logic spr_cs;        // 0x4xxxxx  → Sprite RAM
logic sprctl_cs;     // 0x5xxxxx  → Sprite Control
logic pal_cs;        // 0x6xxxxx  → Palette RAM
logic mix_cs;        // 0x610000–0x61007F (within pal range, decoded finer below)
logic scroll_cs;     // 0x7xxxxx except sram range → Layer scroll / I/O stub
logic io_cs;         // 0xCxxxxx  → 315-5296 I/O chip stub
logic irqctrl_cs;    // 0xDxxxxx  → V60 Interrupt controller
logic asic_cs;       // 0xExxxxx  → ASIC control stub

always_comb begin
    rom_cs     = 1'b0;
    vram_cs    = 1'b0;
    spr_cs     = 1'b0;
    sprctl_cs  = 1'b0;
    pal_cs     = 1'b0;
    mix_cs     = 1'b0;
    scroll_cs  = 1'b0;
    io_cs      = 1'b0;
    irqctrl_cs = 1'b0;
    asic_cs    = 1'b0;

    case (cpu_addr[23:20])
        4'h0,
        4'h1: rom_cs     = 1'b1;   // 0x000000–0x1FFFFF program ROM
        4'h3: begin                 // 0x300000–0x3FFFFF
            // Sprite control lives within 0x5xxxxx in the full map but
            // video hardware accepts $1FF00–$1FF8E as VRAM registers.
            vram_cs = 1'b1;
        end
        4'h4: spr_cs     = 1'b1;   // 0x400000–0x4FFFFF sprite RAM
        4'h5: sprctl_cs  = 1'b1;   // 0x500000–0x5FFFFF sprite control
        4'h6: begin                 // 0x600000–0x6FFFFF palette + mixer
            if (cpu_addr[16]) begin
                // 0x610000–0x61FFFF → mixer control
                mix_cs = 1'b1;
            end else begin
                // 0x600000–0x60FFFF → palette RAM
                pal_cs = 1'b1;
            end
        end
        4'h7: begin                 // 0x700000–0x7FFFFF
            // 0x700000–0x701FFF: shared RAM (sram_cs decoded separately above)
            // 0x702000–0x7FFFFF: layer scroll registers and I/O stub
            if (!sram_cs)
                scroll_cs = 1'b1;
        end
        4'hC: io_cs      = 1'b1;   // 0xC00000–0xCFFFFF I/O chip stub
        4'hD: irqctrl_cs = 1'b1;   // 0xD00000–0xDFFFFF interrupt ctrl
        4'hE: asic_cs    = 1'b1;   // 0xE00000–0xEFFFFF ASIC stub
        4'hF: rom_cs     = 1'b1;   // 0xF00000–0xFFFFFF ROM mirror
        default: ;
    endcase

    // Work RAM check overrides (0x200000–0x20FFFF)
    // This fires for 0x2xxxxx (upper nybble = 2) regardless of above
end

// =============================================================================
// SECTION 5: segas32_video Instantiation
// =============================================================================

// CPU→video control signals
logic        vid_vram_cs,  vid_vram_we;
logic [15:0] vid_vram_addr;
logic [15:0] vid_vram_din;
logic [1:0]  vid_vram_be;
logic [15:0] vid_vram_dout;

logic        vid_spr_cs,   vid_spr_we;
logic [15:0] vid_spr_addr;
logic [15:0] vid_spr_din;
logic [1:0]  vid_spr_be;
logic [15:0] vid_spr_dout;

logic        vid_sprctl_cs, vid_sprctl_we;
logic [3:0]  vid_sprctl_addr;
logic [7:0]  vid_sprctl_din;
logic [7:0]  vid_sprctl_dout;

logic        vid_pal_cs,   vid_pal_we;
logic [13:0] vid_pal_addr;
logic [15:0] vid_pal_din;
logic [1:0]  vid_pal_be;
logic [15:0] vid_pal_dout;

logic        vid_mix_cs,   vid_mix_we;
logic [5:0]  vid_mix_addr;
logic [15:0] vid_mix_din;
logic [1:0]  vid_mix_be;
logic [15:0] vid_mix_dout;

segas32_video #(
    .H_TOTAL  (528),
    .H_ACTIVE (320),
    .H_SYNC_S (336),
    .H_SYNC_E (392),
    .V_TOTAL  (262),
    .V_ACTIVE (224),
    .V_SYNC_S (234),
    .V_SYNC_E (238)
) u_video (
    .clk           (clk_pix),
    .clk_sys       (clk_cpu),
    .rst_n         (rst_n),

    // VRAM
    .cpu_vram_cs   (vid_vram_cs),
    .cpu_vram_we   (vid_vram_we),
    .cpu_vram_addr (vid_vram_addr[15:0]),
    .cpu_vram_din  (vid_vram_din),
    .cpu_vram_be   (vid_vram_be),
    .cpu_vram_dout (vid_vram_dout),

    // Sprite RAM
    .cpu_spr_cs    (vid_spr_cs),
    .cpu_spr_we    (vid_spr_we),
    .cpu_spr_addr  (vid_spr_addr[15:0]),
    .cpu_spr_din   (vid_spr_din),
    .cpu_spr_be    (vid_spr_be),
    .cpu_spr_dout  (vid_spr_dout),

    // Sprite Control
    .cpu_sprctl_cs   (vid_sprctl_cs),
    .cpu_sprctl_we   (vid_sprctl_we),
    .cpu_sprctl_addr (vid_sprctl_addr),
    .cpu_sprctl_din  (vid_sprctl_din),
    .cpu_sprctl_dout (vid_sprctl_dout),

    // Palette RAM
    .cpu_pal_cs    (vid_pal_cs),
    .cpu_pal_we    (vid_pal_we),
    .cpu_pal_addr  (vid_pal_addr),
    .cpu_pal_din   (vid_pal_din),
    .cpu_pal_be    (vid_pal_be),
    .cpu_pal_dout  (vid_pal_dout),

    // Mixer Control
    .cpu_mix_cs    (vid_mix_cs),
    .cpu_mix_we    (vid_mix_we),
    .cpu_mix_addr  (vid_mix_addr),
    .cpu_mix_din   (vid_mix_din),
    .cpu_mix_be    (vid_mix_be),
    .cpu_mix_dout  (vid_mix_dout),

    // GFX ROM
    .gfx_addr      (gfx_addr),
    .gfx_data      (gfx_data),
    .gfx_rd        (gfx_rd),

    // Video outputs
    .hsync         (hsync),
    .vsync         (vsync),
    .hblank        (hblank),
    .vblank        (vblank),
    .hpos          (hpos),
    .vpos          (vpos),
    .pixel_active  (pixel_active),
    .pixel_r       (pixel_r),
    .pixel_g       (pixel_g),
    .pixel_b       (pixel_b),
    .pixel_de      (pixel_de)
);

// =============================================================================
// SECTION 6a: VBLANK rising-edge detector (on clk_cpu domain)
// =============================================================================
// Must be declared before the interrupt controller which uses vblank_rise_cpu.

logic vblank_prev_cpu;
logic vblank_rise_cpu;

always_ff @(posedge clk_cpu or negedge rst_n) begin
    if (!rst_n) begin
        vblank_prev_cpu <= 1'b0;
    end else begin
        vblank_prev_cpu <= vblank;
    end
end

assign vblank_rise_cpu = vblank && !vblank_prev_cpu;

// =============================================================================
// SECTION 6: V60 Interrupt Controller
// =============================================================================
//
// System 32 interrupt controller at 0xD00000–0xD0000F (8 × 16-bit registers).
// MAME: map(0xd00000,0xd0000f).mirror(0x07fff0).rw(int_control_r, int_control_w)
//
// MAME's int_control_r returns 0xFF for all offsets (except timer countdown
// at offsets 8 and 10 which are not implemented). Our register-based read is
// compatible: after reset irq_ctrl[] = 0xFF, and the game writes to configure.
//
// NOTE: There is NO dedicated VBLANK status read register in System 32.
// VBLANK notification is interrupt-only (IRQ on rising vblank edge).
// The game does NOT poll a status register to detect vblank.
//
// Register layout (byte offsets, 8-bit each, read/written as byte pairs):
//   [0..4]  ext_vec[0..4] : external vector number for each IRQ source slot
//           System 32 ROM maps:
//             irq_ctrl[0] = 0  → VBLANK_START at ext_vec[0]
//             irq_ctrl[1] = 1  → VBLANK_END
//             irq_ctrl[2] = 2  → SOUND
//   [5]     (unused / reserved)
//   [6]     irq_mask   : bit-per-source, 1 = masked (disabled)
//   [7]     irq_pending: bit-per-source (write to clear bits = acknowledge)
//
// When pending & ~mask != 0:
//   Find lowest set bit N.
//   Assert irq_n = 0 with vector = ext_vec[N].
//   CPU receives vector on irq_vector bus (adds 0x40 internally for V60 vector table).
//
// VBLANK_START source = bit 0 (irq_ctrl[0] = 0 in ROM init).
// =============================================================================

logic [7:0] irq_ctrl [0:15];   // 16 bytes, covers 0xD00000–0xD0000F

// Interrupt controller state machine
logic        irq_pending_any;  // combinational: any unmasked pending IRQ
logic [3:0]  irq_active_bit;   // which bit is active (lowest set unmasked)
logic        irq_asserted;     // IRQ currently asserted to CPU

// Combinational priority encoder: find lowest set bit in (pending & ~mask)
logic [7:0] irq_unmasked;
assign irq_unmasked = irq_ctrl[7] & ~irq_ctrl[6];

always_comb begin
    irq_pending_any = (irq_unmasked != 8'h00);
    irq_active_bit  = 4'd0;
    if      (irq_unmasked[0]) irq_active_bit = 4'd0;
    else if (irq_unmasked[1]) irq_active_bit = 4'd1;
    else if (irq_unmasked[2]) irq_active_bit = 4'd2;
    else if (irq_unmasked[3]) irq_active_bit = 4'd3;
    else if (irq_unmasked[4]) irq_active_bit = 4'd4;
    else if (irq_unmasked[5]) irq_active_bit = 4'd5;
    else if (irq_unmasked[6]) irq_active_bit = 4'd6;
    else                      irq_active_bit = 4'd7;
end

// IRQ controller reads/writes from CPU
logic [7:0] irqctrl_rdata_lo, irqctrl_rdata_hi;

always_ff @(posedge clk_cpu or negedge rst_n) begin
    if (!rst_n) begin
        integer k;
        for (k = 0; k < 16; k = k + 1)
            irq_ctrl[k] <= 8'hFF;  // reset: all sources masked, no pending
        irq_asserted <= 1'b0;
    end else begin
        // CPU write to interrupt controller
        if (irqctrl_cs && !cpu_as_n && !cpu_rw) begin
            if (!cpu_ds_n[0])
                irq_ctrl[{cpu_addr[3:1], 1'b0}] <= cpu_data_o[7:0];
            if (!cpu_ds_n[1])
                irq_ctrl[{cpu_addr[3:1], 1'b1}] <= cpu_data_o[15:8];
        end

        // VBLANK edge detection: assert pending bit 0 on VBLANK rising edge
        // vblank_prev registered on clk_cpu domain (cross-clock note:
        // for a real design, synchronize vblank across domains; here we
        // use it directly since the testbench can run clk_cpu = clk_pix)
        if (vblank_rise_cpu) begin
            irq_ctrl[7] <= irq_ctrl[7] | 8'h01;  // set bit 0 = VBLANK_START pending
        end

        // Update irq_asserted: assert when any unmasked pending, deassert
        // when CPU acknowledges (clears pending bits by writing to ctrl[7]).
        irq_asserted <= irq_pending_any;
    end
end

// Interrupt controller read data
always_comb begin
    irqctrl_rdata_lo = irq_ctrl[{cpu_addr[3:1], 1'b0}];
    irqctrl_rdata_hi = irq_ctrl[{cpu_addr[3:1], 1'b1}];
end

// IRQ outputs to V60
assign cpu_irq_n   = irq_asserted ? 1'b0 : 1'b1;
assign cpu_irq_vec = irq_ctrl[irq_active_bit];   // ext_vec[active_bit]

// =============================================================================
// SECTION 6b: 315-5296 Port D output latch (C00006)
// =============================================================================
// Port D is the general-purpose output port of the 315-5296 I/O chip.
// Rad Mobile uses it to drive:
//   Bit 5 = EEPROM CS  (93C46 chip select)
//   Bit 6 = EEPROM CLK (serial clock)
//   Bit 7 = EEPROM DI  (serial data in)
//   Bits 0-4 = lamp/motor outputs
// The testbench reads io_portd and implements the 93C46 EEPROM protocol.
// Port F bit 7 (read from C0000A) is supplied back as eeprom_do.

logic [7:0] portd_latch;  // last written value to C00006

always_ff @(posedge clk_cpu or negedge rst_n) begin
    if (!rst_n) begin
        portd_latch <= 8'h00;
    end else if (io_cs && !cpu_as_n && !cpu_rw) begin
        // Port D is at byte offset 6 = cpu_addr[3:1] = 3'd3 (offset 6/2=3 word)
        // C00006 in byte addressing: cpu_addr[5:0] = 6'd6
        if (cpu_addr[5:1] == 5'd3 && !cpu_ds_n[0])
            portd_latch <= cpu_data_o[7:0];
    end
end

assign io_portd = portd_latch;

// =============================================================================
// SECTION 7: Bus Mux — Route CPU data_i from the selected slave
// =============================================================================

// ROM read enable
assign rom_addr = cpu_addr;
assign rom_rd   = rom_cs && !cpu_as_n && cpu_rw;

// Video subsystem control signals (driven from address decoder)
always_comb begin
    // Defaults (all deasserted)
    vid_vram_cs     = 1'b0;
    vid_vram_we     = 1'b0;
    vid_vram_addr   = 16'h0000;
    vid_vram_din    = 16'h0000;
    vid_vram_be     = 2'b00;

    vid_spr_cs      = 1'b0;
    vid_spr_we      = 1'b0;
    vid_spr_addr    = 16'h0000;
    vid_spr_din     = 16'h0000;
    vid_spr_be      = 2'b00;

    vid_sprctl_cs   = 1'b0;
    vid_sprctl_we   = 1'b0;
    vid_sprctl_addr = 4'h0;
    vid_sprctl_din  = 8'h00;

    vid_pal_cs      = 1'b0;
    vid_pal_we      = 1'b0;
    vid_pal_addr    = 14'h0000;
    vid_pal_din     = 16'h0000;
    vid_pal_be      = 2'b00;

    vid_mix_cs      = 1'b0;
    vid_mix_we      = 1'b0;
    vid_mix_addr    = 6'h00;
    vid_mix_din     = 16'h0000;
    vid_mix_be      = 2'b00;

    if (!cpu_as_n) begin
        if (vram_cs) begin
            vid_vram_cs   = 1'b1;
            vid_vram_we   = !cpu_rw;
            vid_vram_addr = cpu_addr[16:1];    // word address from byte address
            vid_vram_din  = cpu_data_o;
            vid_vram_be   = ~cpu_ds_n;
        end
        if (spr_cs) begin
            vid_spr_cs    = 1'b1;
            vid_spr_we    = !cpu_rw;
            vid_spr_addr  = cpu_addr[16:1];
            vid_spr_din   = cpu_data_o;
            vid_spr_be    = ~cpu_ds_n;
        end
        if (sprctl_cs) begin
            vid_sprctl_cs   = 1'b1;
            vid_sprctl_we   = !cpu_rw;
            vid_sprctl_addr = cpu_addr[4:1];   // 16 byte-regs; CPU addr[4:1] = reg index
            vid_sprctl_din  = cpu_data_o[7:0]; // 8-bit register
        end
        if (pal_cs) begin
            vid_pal_cs    = 1'b1;
            vid_pal_we    = !cpu_rw;
            vid_pal_addr  = cpu_addr[14:1];   // 16K word address
            vid_pal_din   = cpu_data_o;
            vid_pal_be    = ~cpu_ds_n;
        end
        if (mix_cs) begin
            vid_mix_cs    = 1'b1;
            vid_mix_we    = !cpu_rw;
            vid_mix_addr  = cpu_addr[6:1];    // 64-word mix register space
            vid_mix_din   = cpu_data_o;
            vid_mix_be    = ~cpu_ds_n;
        end
    end
end

// Work RAM: synchronous write, combinational read (zero-latency for testbench correctness)
always_ff @(posedge clk_cpu) begin
    if (wram_cs && !cpu_as_n && !cpu_rw) begin
        if (!cpu_ds_n[0]) work_ram[cpu_addr[15:1]][7:0]  <= cpu_data_o[7:0];
        if (!cpu_ds_n[1]) work_ram[cpu_addr[15:1]][15:8] <= cpu_data_o[15:8];
        // Debug: trace writes near 0x20F02A (work_ram[0x7815]) - boot loop threshold
        if (cpu_addr[15:1] >= 16'h7800 && cpu_addr[15:1] <= 16'h7830)
            $display("[WRAM WR] addr=0x%06X idx=0x%04X data=0x%04X ds=%b",
                     {8'h20, cpu_addr[15:0]}, cpu_addr[15:1], cpu_data_o, ~cpu_ds_n);
    end
end

// Combinational read: data available same cycle as address (matches ROM timing)
assign wram_rdata = work_ram[cpu_addr[15:1]];

// Shared RAM: synchronous write, combinational read
// 0x700000–0x701FFF: 8KB V60↔Z80 communication RAM
// Word address = cpu_addr[12:1] (4K words, bit 0 = byte select)
// Writes are transparent (CPU can write and read back normally).
// The initial block pre-fills to the post-Z80-init state (see above).

always_ff @(posedge clk_cpu) begin
    if (sram_cs && !cpu_as_n && !cpu_rw) begin
        if (!cpu_ds_n[0]) shared_ram[cpu_addr[12:1]][7:0]  <= cpu_data_o[7:0];
        if (!cpu_ds_n[1]) shared_ram[cpu_addr[12:1]][15:8] <= cpu_data_o[15:8];
    end
end

// Read mux: return actual shared RAM content.
// The Z80 stub pre-fills specific locations (see initial block above and
// z80_ready logic) to simulate Z80 initialization:
//   - Z80 fills all of 0xE000-0xFFFF with 0x00 → shared_ram stays 0x0000
//   - Z80 writes 0x80 to 0xE00F → shared_ram[0x0007] = 0x0080 (word, byte offset 0xF)
// The V60 boot loop at 0x7F95C sums 64 bytes at 0x701F02-0x701F41 (Z80 0xFF02-0xFF41).
// The Z80 leaves those bytes 0x00, so the checksum=0 and the V60 proceeds.
// Returning 0xFFFF caused sum overflow and infinite loop.
assign sram_rdata = shared_ram[cpu_addr[12:1]];

// Data mux: select which slave drives cpu_data_i
always_comb begin
    cpu_data_i  = 16'hDEAD;   // default: undefined (catches decoder bugs)
    cpu_dtack_n = 1'b1;        // default: not ready

    if (!cpu_as_n) begin
        if (rom_cs && cpu_rw) begin
            cpu_data_i  = rom_data;
            cpu_dtack_n = 1'b0;
        end else if (wram_cs) begin
            cpu_data_i  = wram_rdata;
            cpu_dtack_n = 1'b0;
        end else if (sram_cs) begin
            cpu_data_i  = sram_rdata;
            cpu_dtack_n = 1'b0;
        end else if (vram_cs) begin
            cpu_data_i  = vid_vram_dout;
            cpu_dtack_n = 1'b0;
        end else if (spr_cs) begin
            cpu_data_i  = vid_spr_dout;
            cpu_dtack_n = 1'b0;
        end else if (sprctl_cs && cpu_rw) begin
            cpu_data_i  = {8'h00, vid_sprctl_dout};
            cpu_dtack_n = 1'b0;
        end else if (pal_cs) begin
            cpu_data_i  = vid_pal_dout;
            cpu_dtack_n = 1'b0;
        end else if (mix_cs) begin
            cpu_data_i  = vid_mix_dout;
            cpu_dtack_n = 1'b0;
        end else if (scroll_cs) begin
            // Layer scroll stub: always returns 0
            cpu_data_i  = 16'h0000;
            cpu_dtack_n = 1'b0;
        end else if (io_cs) begin
            // 315-5296 I/O chip stub (MAME: 0xC00000–0xC0001F, umask16(0x00ff))
            // Only the LOW byte is connected (umask 0x00FF).
            // Register layout (byte offsets):
            //   0x00 = Port A (P1 buttons, active-low, 0xFF = no press)
            //   0x02 = Port B (P2 buttons)
            //   0x04 = Port C (misc inputs)
            //   0x06 = Port D (output latch: EEPROM CS/CLK/DI + lamp outputs)
            //   0x08 = Port E (SERVICE12_A: service/coin inputs, active-low)
            //   0x0A = Port F (SERVICE34_A: DIP switches + EEPROM DO at bit 7)
            //   0x0C = Port G (output)
            //   0x0E = Port H (output)
            //   0x10-0x1F = direction registers
            //   0x40-0x7F = direction/control
            // The high byte is unconnected (umask 0x00FF) — always 0x00.
            if (cpu_addr[6])
                // 0xC00040–0xC0007F: direction and control registers → 0x0000
                cpu_data_i = 16'h0000;
            else if (cpu_addr[5:1] == 5'd5) begin
                // 0xC0000A: Port F (SERVICE34_A)
                // Bit 7 = EEPROM DO (active-HIGH, from 93C46 serial output)
                // Bits 6:0 = DIP switches + test buttons (active-low, 0x7F = all off)
                cpu_data_i = {8'h00, eeprom_do, 7'h7F};
            end else
                // All other input ports: 0xFF (all inactive, active-low)
                cpu_data_i = 16'h00FF;
            cpu_dtack_n = 1'b0;
        end else if (irqctrl_cs) begin
            cpu_data_i  = {irqctrl_rdata_hi, irqctrl_rdata_lo};
            cpu_dtack_n = 1'b0;
        end else if (asic_cs) begin
            // ASIC control stub
            cpu_data_i  = 16'h0000;
            cpu_dtack_n = 1'b0;
        end else begin
            // Unmapped: return 0 with ack to prevent CPU hang
            cpu_data_i  = 16'h0000;
            cpu_dtack_n = 1'b0;
        end
    end
end

// Bus monitor outputs
assign dbg_cpu_addr   = cpu_addr;
assign dbg_cpu_data_o = cpu_data_o;
assign dbg_cpu_data_i = cpu_data_i;
assign dbg_cpu_as_n   = cpu_as_n;
assign dbg_cpu_rw     = cpu_rw;

endmodule : segas32_top
