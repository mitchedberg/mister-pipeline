`default_nettype none
// =============================================================================
// batrider_arcade — Armed Police Batrider / Battle Bakraid System Top Level
// =============================================================================
//
// MAME driver: src/mame/toaplan/raizing.cpp  (batrider_state / bbakraid_state)
// Board:       RA9704 (Batrider, 1998), RA9903 (Battle Bakraid, 1999)
//
// Hardware:
//   MC68000 @ 16 MHz (32 MHz XTAL / 2)
//   Z80     @  4 MHz (32 MHz XTAL / 8 — for audio)
//   GP9001 VDP (single chip, OBJECTBANK_EN=1 — 8-slot tile bank table)
//   YMZ280B @ 16.9344 MHz (replaces YM2151+OKI from Battle Garegga)
//   GAL16V8 × 5 (audio ROM banking — same gal_oki_bank.sv mechanism as bgaregga)
//   ExtraText DMA (TVRMCTL7 register at 0x300030 — batch text tile DMA)
//
// ── Key differences vs Battle Garegga (raizing_arcade.sv) ──────────────────
//
//   1. OBJECTBANK_EN=1 on GP9001:
//      The game uses more sprite tiles than fit in a 10-bit tile code (1024 tiles).
//      An 8-slot bank table extends tile codes to 14 bits (4 bank bits + 10 tile bits).
//      CPU writes to 0x500000-0x50000F program the 8-slot bank table:
//        byte offset 0x00 (addr 0x500000): data[7:0] = {bank[1][3:0], bank[0][3:0]}
//        byte offset 0x02 (addr 0x500002): data[7:0] = {bank[3][3:0], bank[2][3:0]}
//        byte offset 0x04 (addr 0x500004): data[7:0] = {bank[5][3:0], bank[4][3:0]}
//        byte offset 0x06 (addr 0x500006): data[7:0] = {bank[7][3:0], bank[6][3:0]}
//      Each 16-bit write packs two 4-bit bank values in the low byte.
//      Reference: MAME toaplan2_state::batrider_objectbank_w (toaplan2.cpp)
//
//   2. YMZ280B audio:
//      8-channel ADPCM/PCM, addressed via Z80 ports 0x84 (address) and 0x85 (data).
//      No YM2151 or OKI M6295.
//      ROM interface: 24-bit external ROM address → SDRAM channel.
//
//   3. ExtraText DMA (TVRMCTL7 at 0x300030):
//      Batrider uses a DMA mechanism to transfer text tile attributes from a work
//      buffer to the GP9001 VRAM text layer in bulk during HBlank.
//      The 68K writes the DMA base address to 0x300030.
//      The DMA controller reads 512 words from that address and copies them
//      to text VRAM starting at the beginning of the frame.
//      MAME reference: toaplan2_state::batrider_textdma_w (toaplan2.cpp line ~670).
//      This stub captures the DMA register and signals a DMA start pulse.
//
// ── Memory map (68000) — from MAME batrider_68k_mem ─────────────────────────
//   0x000000 - 0x1FFFFF   2MB    Program ROM (SDRAM bank 0)
//   0x200000 - 0x20FFFF  64KB    Work RAM
//   0x300000 - 0x30000D          GP9001 VDP registers (read/write)
//   0x300014                     Sound latch read (byte, from Z80)
//   0x300018 - 0x300019          GP9001 scanline counter (vdpcount_r)
//   0x30001A                     Coin counter / IO write
//   0x30001C - 0x30001D          IN1 (joystick 1)
//   0x30001E - 0x30001F          IN2 (joystick 2)
//   0x300020 - 0x300021          SYS (coin, start, service)
//   0x300022 - 0x300023          DSWA
//   0x300024 - 0x300025          DSWB
//   0x300026 - 0x300027          JMPR (jumper/region)
//   0x300030 - 0x300031          ExtraText DMA address register (TVRMCTL7)
//   0x400000 - 0x400FFF  4KB     Palette RAM
//   0x500000 - 0x50000F  16B     Object bank registers (GP9001_OP_OBJECTBANK_WR)
//   0x600001                     Sound latch write (byte, to Z80)
//   0x700000 - 0x703FFF  16KB    Text tilemap VRAM (ExtraText DMA destination)
//
// ── Memory map (Z80 sound CPU) ──────────────────────────────────────────────
//   0x0000 - 0x7FFF   32KB   Sound ROM (fixed)
//   0x8000 - 0xBFFF   16KB   Sound ROM (banked via z80_audiobank, 4-bit, 8 × 16KB pages)
//   0xC000 - 0xCFFF    4KB   Shared RAM (with 68K at 0x300014/0x600001)
//   0xE000 - 0xE001          YMZ280B address port (read/write)
//   0xE002 - 0xE003          YMZ280B data port (read/write)
//   0xE004 - 0xE006          GAL OKI bank registers (batrider only; not used in bbakraid)
//   0xE00A                   Z80 ROM bank register (write, 4-bit, selects 16KB audio ROM page)
//   0xE00C                   Sound latch acknowledge (write)
//   0xE01C                   Sound latch read (read from 68K)
//
// ── SDRAM layout (for MiSTer ioctl ROM loading) ─────────────────────────────
//   ROM index 0 (CPU):  0x000000 - 0x1FFFFF  2MB   68K program ROM
//   ROM index 1 (GFX):  0x200000 - 0xDFFFFF  12MB  GP9001 tile ROM (6 × 2MB, Batrider)
//                       0x200000 - 0xFFFFFF  14MB  GP9001 tile ROM (7 × 2MB, Bakraid)
//   ROM index 2 (SND):  varies                      Z80 audio ROM (bank-selected)
//   ROM index 3 (PCM):  varies                      YMZ280B ADPCM sample ROM
//   ROM index 4 (TXT):  varies                      Text tilemap ROM
//
// =============================================================================

module batrider_arcade #(
    parameter int CLK_FREQ_HZ     = 96_000_000,
    parameter bit IS_BAKRAID       = 0          // 1 = Battle Bakraid (different ROMs/regs)
) (
    input  logic        clk,            // 96 MHz system clock
    input  logic        rst_n,          // active-low reset

    // ── MiSTer HPS I/O ────────────────────────────────────────────────────────
    input  logic        ioctl_wr,       // ROM loading write strobe
    input  logic [24:0] ioctl_addr,     // ROM loading address
    input  logic [15:0] ioctl_dout,     // ROM loading data (16-bit)
    input  logic [7:0]  ioctl_index,    // ROM region index
    output logic        ioctl_wait,     // Stall HPS while SDRAM busy

    // ── Video output ─────────────────────────────────────────────────────────
    output logic [7:0]  red,
    output logic [7:0]  green,
    output logic [7:0]  blue,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,
    output logic        ce_pixel,

    // ── Audio output ─────────────────────────────────────────────────────────
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    // ── Cabinet I/O ──────────────────────────────────────────────────────────
    input  logic [9:0]  joystick_0,     // P1: [9:8]=coin/start, [5:0]=UDLRBA
    input  logic [9:0]  joystick_1,     // P2
    input  logic [7:0]  dipsw_a,        // DIP switch A
    input  logic [7:0]  dipsw_b,        // DIP switch B

    // ── SDRAM interface ───────────────────────────────────────────────────────
    output logic [12:0] sdram_a,
    output logic [1:0]  sdram_ba,
    inout  logic [15:0] sdram_dq,
    output logic        sdram_cas_n,
    output logic        sdram_ras_n,
    output logic        sdram_we_n,
    output logic        sdram_cs_n,
    output logic [1:0]  sdram_dqm,
    output logic        sdram_cke
);

    // =========================================================================
    // Clock enable generation (identical to raizing_arcade.sv)
    // 96 MHz → 16 MHz (68K, div 6) → 4 MHz (Z80, div 24)
    // =========================================================================

    // 16 MHz enable for 68000
    logic [2:0] cpu_div;
    logic       cpu_cen;    // enPhi1 — rising phase
    logic       cpu_cenb;   // enPhi2 — falling phase, one cycle later
    logic       cpu_phi;    // toggles at 8 MHz

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_div  <= 3'd0;
            cpu_phi  <= 1'b0;
            cpu_cen  <= 1'b0;
            cpu_cenb <= 1'b0;
        end else begin
            cpu_cen  <= 1'b0;
            cpu_cenb <= 1'b0;
            if (cpu_div == 3'd5) begin
                cpu_div  <= 3'd0;
                cpu_phi  <= ~cpu_phi;
                if (!cpu_phi) cpu_cen  <= 1'b1;
                else          cpu_cenb <= 1'b1;
            end else begin
                cpu_div <= cpu_div + 3'd1;
            end
        end
    end

    // 4 MHz enable for Z80
    logic [4:0] z80_div;
    logic       z80_cen;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            z80_div <= 5'd0;
            z80_cen <= 1'b0;
        end else begin
            z80_cen <= 1'b0;
            if (z80_div == 5'd23) begin
                z80_div <= 5'd0;
                z80_cen <= 1'b1;
            end else begin
                z80_div <= z80_div + 5'd1;
            end
        end
    end

    // =========================================================================
    // Object bank register write decoder
    //
    // The 68K writes to addresses 0x500000–0x50000F to program the 8-slot
    // GP9001 object bank table.  Each 16-bit write packs two 4-bit bank values:
    //   addr 0x500000: din[3:0]  → bank slot 0,  din[7:4]  → bank slot 1
    //   addr 0x500002: din[3:0]  → bank slot 2,  din[7:4]  → bank slot 3
    //   addr 0x500004: din[3:0]  → bank slot 4,  din[7:4]  → bank slot 5
    //   addr 0x500006: din[3:0]  → bank slot 6,  din[7:4]  → bank slot 7
    //
    // Reference: MAME toaplan2_state::batrider_objectbank_w (raizing.cpp)
    //   void toaplan2_state::batrider_objectbank_w(offs_t offset, u8 data)
    //   {
    //       m_gp9001vdp[0]->set_global_object_bank(offset * 2,   data & 0x0f);
    //       m_gp9001vdp[0]->set_global_object_bank(offset * 2 + 1, data >> 4);
    //   }
    //   Called at offset 0..3 (byte address = 2*offset within 0x500000–0x500007).
    //   Each byte write sets two consecutive bank slots.
    //
    // In the 16-bit 68K bus, each 16-bit word access to 0x500000 sets 4 slots
    // (2 from lower byte, 2 from upper byte).
    //
    // This decoder operates on the 68K word bus: addr[2:1] selects the pair,
    // din[7:0] is the byte that contains two 4-bit bank values.
    //
    // We generate two single-cycle obj_bank_wr pulses per write (one per nibble).
    // To keep the GP9001 interface simple (one slot per write pulse), we use
    // a two-step sequencer that fires on consecutive cycles.
    // =========================================================================

    // Inputs from 68K address decoder (wired internally in this scaffold)
    logic        objbank_cs;        // 0x500000–0x50000F chip select
    logic [3:1]  cpu_addr_objbank;  // CPU address bits [3:1] (word address within bank region)
    logic [7:0]  cpu_din_lo;        // CPU low byte (drives bank slots 2*offset, 2*offset+1)

    // Two-cycle sequencer: issue slot-A then slot-B on consecutive cycles
    logic        objbank_wr_pending; // slot-B write is pending
    logic [2:0]  objbank_slot_b;     // slot index for pending second write
    logic [3:0]  objbank_val_b;      // bank value for pending second write

    // GP9001 object bank write interface
    logic        obj_bank_wr;
    logic [2:0]  obj_bank_slot;
    logic [3:0]  obj_bank_val;

    // Registered chip select for address decode
    logic        objbank_wr_strobe;

    // Address decode: 0x500000–0x50000F
    // 68K bus word address: 0x280000–0x280007 (byte addr >> 1)
    // Detect write to this region (wired from CPU bus, see _unused suppression below)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            objbank_wr_pending <= 1'b0;
            objbank_slot_b     <= 3'h0;
            objbank_val_b      <= 4'h0;
            obj_bank_wr        <= 1'b0;
            obj_bank_slot      <= 3'h0;
            obj_bank_val       <= 4'h0;
        end else if (objbank_wr_pending) begin
            // Cycle 2: issue the second (hi-nibble) slot write
            obj_bank_wr    <= 1'b1;
            obj_bank_slot  <= objbank_slot_b;
            obj_bank_val   <= objbank_val_b;
            objbank_wr_pending <= 1'b0;
        end else if (objbank_wr_strobe) begin
            // Cycle 1: issue first (lo-nibble) slot write; schedule second
            // Slot indices: pair_index * 2 and pair_index * 2 + 1
            // cpu_addr_objbank[2:1] = pair index (0..3)
            obj_bank_wr   <= 1'b1;
            obj_bank_slot <= {cpu_addr_objbank[2:1], 1'b0};  // even slot
            obj_bank_val  <= cpu_din_lo[3:0];                  // lo nibble
            // Stage second write for next cycle
            objbank_slot_b     <= {cpu_addr_objbank[2:1], 1'b1};  // odd slot
            objbank_val_b      <= cpu_din_lo[7:4];                  // hi nibble
            objbank_wr_pending <= 1'b1;
        end else begin
            obj_bank_wr <= 1'b0;
        end
    end

    // =========================================================================
    // ExtraText DMA controller (TVRMCTL7)
    //
    // The batrider/bbakraid hardware has a DMA mechanism that copies text tile
    // data from a 68K work RAM buffer to the text VRAM during HBlank.
    //
    // CPU interface:
    //   68K writes the DMA source base address (word address) to 0x300030.
    //   Writing triggers a DMA transfer: 512 words copied from that work RAM
    //   region to the text VRAM starting at tile row 0, column 0.
    //   Transfer completes in 512 bus cycles (one word per cycle).
    //
    // MAME reference: toaplan2_state::batrider_textdma_w (raizing.cpp ~line 670):
    //   void toaplan2_state::batrider_textdma_w(u16 data)
    //   {
    //       // data = base address of text buffer in 68K address space (word addr)
    //       m_textdma_src = data;
    //       m_textdma_pending = true;
    //   }
    //   The DMA is serviced by the video device (GP9001 text layer).
    //
    // This implementation:
    //   1. Captures the DMA address written to 0x300030.
    //   2. On write, asserts textdma_start for 1 cycle.
    //   3. textdma_src_addr holds the word address of the source buffer.
    //   Full DMA sequencing (reading work RAM and writing text VRAM) is left
    //   to a subsequent implementation step; here we just capture the trigger.
    //
    // =========================================================================

    logic        tvrmctl7_cs;       // chip select for 0x300030 (wired from address decoder)
    logic        textdma_start;     // 1-cycle pulse on DMA trigger
    logic [15:0] textdma_src_addr;  // DMA source word address (from 68K write)

    // DMA register latch
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            textdma_start    <= 1'b0;
            textdma_src_addr <= 16'h0000;
        end else begin
            textdma_start <= 1'b0;  // pulse for 1 cycle only
            if (tvrmctl7_cs) begin
                // 68K writes DMA source address to 0x300030
                // cpu_din is the 16-bit write data from the 68K bus
                // (mapped from internal cpu_dout signal — see scaffold)
                textdma_start    <= 1'b1;
                textdma_src_addr <= 16'h0000;  // placeholder: wire to cpu_dout in full impl
            end
        end
    end

    // =========================================================================
    // GAL OKI bank switching (Batrider only — not Bakraid)
    //
    // Batrider retains the same GAL-based OKI ROM banking as Battle Garegga,
    // even though it primarily uses YMZ280B.  The GAL bank registers are at
    // Z80 I/O ports 0xE004–0xE006.
    //
    // Battle Bakraid (IS_BAKRAID=1) removes OKI entirely; Z80 ports 0xE004–
    // 0xE006 are not connected.  IS_BAKRAID parameter suppresses the GAL.
    // =========================================================================

    logic       z80_gal_bank_wr;       // Z80 write strobe for gal_oki_bank
    logic [1:0] z80_gal_bank_addr;     // port offset (0=e004, 1=e005, 2=e006)
    logic [7:0] z80_gal_bank_din;      // Z80 data
    logic [17:0] oki_rom_addr_in;      // from OKI (if present)
    logic [21:0] oki_rom_addr_out;     // to SDRAM (if present)
    logic [7:0][3:0] oki_bank_regs;    // debug

    generate
        if (!IS_BAKRAID) begin : gen_gal_bank
            gal_oki_bank u_gal_oki_bank (
                .clk         (clk),
                .rst_n       (rst_n),
                .z80_wr      (z80_gal_bank_wr),
                .z80_addr    (z80_gal_bank_addr),
                .z80_din     (z80_gal_bank_din),
                .oki_addr    (oki_rom_addr_in),
                .rom_addr    (oki_rom_addr_out),
                .bank_regs   (oki_bank_regs)
            );
        end else begin : gen_gal_bank_tie
            assign oki_rom_addr_out = 22'h000000;
            assign oki_bank_regs = '0;
        end
    endgenerate

    // =========================================================================
    // Z80 audio bank register (same mechanism as bgaregga)
    // Z80 writes to 0xE00A to select 16KB page of audio ROM (4-bit, 8 pages).
    // =========================================================================

    logic [3:0] z80_audio_bank;  // selects 16KB page from Z80 audio ROM

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            z80_audio_bank <= 4'd0;
        end
        // Placeholder: wire z80_audiobank_wr from Z80 address decoder in full impl
    end

    // =========================================================================
    // YMZ280B ADPCM audio chip
    //
    // The YMZ280B replaces YM2151+OKI from Battle Garegga.
    // Z80 accesses YMZ280B at:
    //   Port 0xE000 (a0=0): address register
    //   Port 0xE001 (a0=1): data register
    //
    // (Batrider uses 0xE000/0xE001; some docs say 0x84/0x85 — Z80 I/O port
    //  mirrors mean both work.  We use the batrider-specific mapping.)
    // =========================================================================

    // Z80→YMZ280B bus signals (from Z80 address decoder in full impl)
    logic        ymz_cs_n;     // chip select (active-low)
    logic        ymz_a0;       // address bit 0: 0=addr port, 1=data port
    logic        ymz_wr_n;     // write strobe (active-low)
    logic [7:0]  ymz_din;      // write data
    logic [7:0]  ymz_dout;     // read data (status)

    // YMZ280B ROM interface (24-bit ADPCM sample ROM)
    logic [23:0] ymz_rom_addr;
    logic        ymz_rom_rd;
    logic [7:0]  ymz_rom_data;
    logic        ymz_rom_ok;

    // YMZ280B audio outputs
    logic [15:0] ymz_audio_l;
    logic [15:0] ymz_audio_r;
    logic        ymz_irq_n;

    ymz280b u_ymz280b (
        .clk        (clk),
        .rst_n      (rst_n),
        // CPU interface
        .z80_cs_n   (ymz_cs_n),
        .z80_a0     (ymz_a0),
        .z80_wr_n   (ymz_wr_n),
        .z80_din    (ymz_din),
        .z80_dout   (ymz_dout),
        // ROM interface
        .rom_addr   (ymz_rom_addr),
        .rom_rd     (ymz_rom_rd),
        .rom_data   (ymz_rom_data),
        .rom_ok     (ymz_rom_ok),
        // Audio
        .audio_l    (ymz_audio_l),
        .audio_r    (ymz_audio_r),
        .irq_n      (ymz_irq_n)
    );

    // =========================================================================
    // Output assignments — safe defaults for scaffold stage
    //
    // In the complete implementation these signals are wired to the GP9001,
    // line buffer, video timing generator, and SDRAM controller.
    // =========================================================================

    assign ioctl_wait  = 1'b0;

    // Video — tied off pending GP9001 integration
    assign red         = 8'h00;
    assign green       = 8'h00;
    assign blue        = 8'h00;
    assign hsync_n     = 1'b1;
    assign vsync_n     = 1'b1;
    assign hblank      = 1'b0;
    assign vblank      = 1'b0;
    assign ce_pixel    = 1'b0;

    // Audio — YMZ280B output (stub outputs zero)
    assign audio_l     = ymz_audio_l;
    assign audio_r     = ymz_audio_r;

    // SDRAM — tri-stated pending controller integration
    assign sdram_a     = 13'h0;
    assign sdram_ba    = 2'b00;
    assign sdram_cas_n = 1'b1;
    assign sdram_ras_n = 1'b1;
    assign sdram_we_n  = 1'b1;
    assign sdram_cs_n  = 1'b1;
    assign sdram_dqm   = 2'b11;
    assign sdram_cke   = 1'b1;

    // =========================================================================
    // Scaffold wiring — internal signals not yet connected to real decoders
    //
    // These are tied to safe values here.  When the full CPU + address decoder
    // is instantiated, these ties are removed and real connections made.
    // =========================================================================

    assign objbank_cs         = 1'b0;
    assign objbank_wr_strobe  = 1'b0;
    assign cpu_addr_objbank   = 3'h0;
    assign cpu_din_lo         = 8'h00;
    assign tvrmctl7_cs        = 1'b0;
    assign z80_gal_bank_wr    = 1'b0;
    assign z80_gal_bank_addr  = 2'h0;
    assign z80_gal_bank_din   = 8'h00;
    assign oki_rom_addr_in    = 18'h00000;
    assign ymz_cs_n           = 1'b1;
    assign ymz_a0             = 1'b0;
    assign ymz_wr_n           = 1'b1;
    assign ymz_din            = 8'h00;
    assign ymz_rom_data       = 8'h00;
    assign ymz_rom_ok         = 1'b1;

    // =========================================================================
    // Lint suppression
    // =========================================================================
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = &{1'b0,
        ioctl_wr, ioctl_addr, ioctl_dout, ioctl_index,
        joystick_0, joystick_1, dipsw_a, dipsw_b,
        cpu_cen, cpu_cenb, z80_cen,
        obj_bank_wr, obj_bank_slot, obj_bank_val,
        textdma_start, textdma_src_addr,
        z80_audio_bank,
        ymz_dout, ymz_rom_addr, ymz_rom_rd, ymz_irq_n,
        oki_bank_regs,
        oki_rom_addr_out,
        objbank_cs,
        IS_BAKRAID[0]
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
