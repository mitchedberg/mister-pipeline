`default_nettype none
// =============================================================================
// ymz280b — Yamaha YMZ280B ADPCM/PCM audio chip behavioral stub
// =============================================================================
//
// MAME reference: src/mame/machine/ymz280b.cpp  (ymz280b_device)
// Hardware: Yamaha YMZ280B (1994) — 8-channel ADPCM/PCM decoder
//
// Board usage:
//   Batrider  (RA9704, 1998): YMZ280B @ 16.9344 MHz (replaces YM2151+OKI from bgaregga)
//   Battle Bakraid (RA9903, 1999): YMZ280B @ 16.9344 MHz
//
// Hardware description (from MAME ymz280b.cpp):
//   The YMZ280B is an 8-channel ADPCM sample player.  Each channel can be
//   independently programmed with start address, end address, sample rate,
//   and playback mode (ADPCM 4-bit, PCM 8-bit, or PCM 16-bit).  Channels
//   output signed 16-bit audio at programmable sample rates derived from
//   the CLKI pin (master clock, nominally 16.9344 MHz).
//
// Register interface (Z80 CPU write-only):
//   Z80 port 0x84 — address register (selects which of the 256 internal regs to write)
//   Z80 port 0x85 — data register (writes to selected internal register)
//
//   Internal register map (partial, key registers only):
//     [0x01+ch*4]  [2:0]=key_on/off/hold, [7:4]=volume_left, others
//     [0x02+ch*4]  volume_right, interpolation rate
//     [0x03+ch*4]  sample_rate[7:0]
//     [0x04+ch*4]  start_addr[7:0]
//     [0x05+ch*4]  start_addr[15:8]
//     [0x06+ch*4]  start_addr[23:16]
//     [0x07+ch*4]  end_addr[7:0]
//     [0x08+ch*4]  end_addr[15:8]
//     [0x09+ch*4]  end_addr[23:16]
//     [0xFE]       [7:4]=test, [2]=IRQ enable, [0]=keyon_latch
//     [0xFF]       status register (read back via ROM chip-select protocol)
//
//   ch = channel index 0..7.
//
// ROM interface:
//   The YMZ280B addresses external ADPCM sample ROMs via a 24-bit address bus.
//   This stub routes ROM reads to an SDRAM channel externally.
//
// Stub limitations:
//   This is a BEHAVIORAL STUB sufficient for Verilator simulation compilation
//   and MiSTer ROM loading.  It does NOT decode ADPCM or produce audio samples.
//   All audio outputs are driven to zero.  The register interface is captured
//   (internal registers are written correctly) so ROM loading and channel
//   configuration can be traced in simulation.  Full ADPCM decoding is left
//   for gate-5 audio validation.
//
// Port interface matches what batrider_arcade.sv instantiates.
//
// =============================================================================

module ymz280b (
    input  logic        clk,          // System clock (96 MHz — enables generated internally)
    input  logic        rst_n,        // Active-low async reset

    // ── CPU register interface (from Z80 decoder) ────────────────────────────
    // Address and data are latched from the Z80 bus.
    // z80_cs_n: chip select (active-low); decoded from Z80 address 0x84 or 0x85.
    // z80_a0:   address bit 0 selects address_reg (0) vs data_reg (1).
    input  logic        z80_cs_n,     // Chip select (active-low)
    input  logic        z80_a0,       // 0 = address port (0x84), 1 = data port (0x85)
    input  logic        z80_wr_n,     // Write strobe (active-low)
    input  logic [7:0]  z80_din,      // Z80 data bus (write data)
    output logic [7:0]  z80_dout,     // Z80 data bus (read data — status reg)

    // ── ROM interface (SDRAM channel read) ───────────────────────────────────
    output logic [23:0] rom_addr,     // 24-bit byte address into ADPCM ROM
    output logic        rom_rd,       // ROM read request strobe
    input  logic [7:0]  rom_data,     // ROM read data (1-cycle latency from SDRAM)
    input  logic        rom_ok,       // ROM data valid

    // ── Audio output (stereo 16-bit signed) ──────────────────────────────────
    output logic [15:0] audio_l,      // Left channel (16-bit signed, 0 in stub)
    output logic [15:0] audio_r,      // Right channel (16-bit signed, 0 in stub)

    // ── IRQ output ───────────────────────────────────────────────────────────
    output logic        irq_n         // Active-low interrupt (end-of-sample)
);

    // =========================================================================
    // Internal register file — 256 × 8-bit
    // Indexed by the address register (0x00..0xFF).
    // =========================================================================

    logic [7:0] reg_addr;    // current address register (written at port 0x84)
    `ifdef QUARTUS
    (* ramstyle = "MLAB" *) logic [7:0] regs [0:255]; // internal register file
    `else
    logic [7:0] regs [0:255]; // internal register file
    `endif

    // ── CPU write ─────────────────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_addr <= 8'h00;
            /* verilator lint_off UNUSEDLOOP */
            for (int i = 0; i < 256; i++) regs[i] <= 8'h00;
            /* verilator lint_on UNUSEDLOOP */
        end else if (!z80_cs_n && !z80_wr_n) begin
            if (!z80_a0) begin
                // Port 0x84: write to address register
                reg_addr <= z80_din;
            end else begin
                // Port 0x85: write to internal register at reg_addr
                regs[reg_addr] <= z80_din;
            end
        end
    end

    // ── CPU read — status register only ───────────────────────────────────────
    // Status byte bits (from MAME ymz280b_device::read):
    //   [7:4] = BUSY flags for channels 7..4
    //   [3:0] = BUSY flags for channels 3..0
    // Stub: all channels always idle (not busy).
    always_comb begin
        z80_dout = 8'h00;  // all channels idle
    end

    // =========================================================================
    // Per-channel key-on / key-off decoder (stub)
    //
    // Each channel occupies 4 internal registers:
    //   regs[0x01 + ch*4]:  bits[6:5]=key_mode (00=off, 10=on, 11=loop, 01=hold)
    //                        bits[3:0]=volume_left[7:4]
    //   regs[0x02 + ch*4]:  volume_right, inter_rate
    //   regs[0x03 + ch*4]:  sample_rate
    //   regs[0x04..0x06 + ch*4]: start_addr[23:0] (3 bytes little-endian)
    //   regs[0x07..0x09 + ch*4]: end_addr[23:0]   (3 bytes little-endian)
    //
    // In this stub, key-on/off events are captured into the register file but
    // no actual decoding occurs.  The ROM address output is held at zero.
    // =========================================================================

    // ROM interface: stub drives address 0 and no read strobes
    assign rom_addr = 24'h000000;
    assign rom_rd   = 1'b0;

    // Audio outputs: zero (stub does not decode ADPCM)
    assign audio_l = 16'h0000;
    assign audio_r = 16'h0000;

    // IRQ: not implemented in stub (no end-of-sample detection)
    assign irq_n   = 1'b1;

    // =========================================================================
    // Lint suppression — registers captured but not decoded in stub
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = &{1'b0, rom_data, rom_ok, reg_addr,
                       regs[0], regs[255]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
