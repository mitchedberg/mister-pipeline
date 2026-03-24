// =============================================================================
// taito_b.sv — Taito B System Board Top-Level Integration
// =============================================================================
//
// Instantiates and wires:
//   TC0180VCU  — video controller (tilemaps + sprites + framebuffer)
//   TC0260DAR  — palette DAC (RGB444/RGB555)
//   TC0220IOC  — I/O controller (joysticks, coins, DIP switches)
//   TC0140SYT  — 68000↔Z80 sound communication + ADPCM ROM arbiter
//
// Plus local block RAMs:
//   palette_ram — 8K×16-bit (TC0260DAR external palette RAM)
//   work_ram    — parameterized (68000 general-purpose work RAM)
//
// Parameterized for per-game address map differences; default = nastar
// (Rastan Saga II / Nastar Warrior).
//
// Reference: chips/taito_b/integration_plan.md
//            chips/taito_b/mame_research.md
//
// NOT instantiated here (provided by the MiSTer HPS top-level wrapper):
//   MC68000 CPU, Z80 CPU, YM2610/YM2151, SDRAM controller, video timing gen
//
// =============================================================================
`default_nettype none

// reset_n is used async in taito_b always_ff blocks and sync inside TC0140SYT (RESn).
// This is correct for the hardware; suppress the mixed-sensitivity Verilator warning.
/* verilator lint_off SYNCASYNCNET */
module taito_b #(
    // ── Address decode parameters (WORD addresses = byte_addr >> 1) ────────
    // nastar (rastsag2) defaults:
    //   TC0180VCU: 0x400000–0x47FFFF byte  →  word base 0x200000, 19-bit window
    //   TC0260DAR: 0x200000–0x201FFF byte  →  word base 0x100000, 13-bit window
    //   TC0220IOC: 0xA00000–0xA0000F byte  →  word base 0x500000, 4-bit window
    //   TC0140SYT: 0x800000–0x800003 byte  →  word base 0x400000, 2-bit window
    parameter logic [23:1] VCU_BASE    = 23'h200000,   // 0x400000 byte / 2
    parameter logic [23:1] DAR_BASE    = 23'h100000,   // 0x200000 byte / 2
    parameter logic [23:1] IOC_BASE    = 23'h500000,   // 0xA00000 byte / 2
    parameter logic [23:1] SYT_BASE    = 23'h400000,   // 0x800000 byte / 2
    parameter logic [23:1] WRAM_BASE   = 23'h300000,   // 0x600000 byte / 2  (nastar 32KB)
    parameter int unsigned  WRAM_ABITS = 14,            // 2^14 = 16K words = 32KB

    // ── Interrupt level assignments (game-specific, nastar defaults) ────────
    // nastar: int_h → M68K_IRQ_4, int_l → M68K_IRQ_2
    parameter logic [2:0]  INT_H_LEVEL = 3'd4,
    parameter logic [2:0]  INT_L_LEVEL = 3'd2,

    // ── TC0220IOC data-bus byte position ───────────────────────────────────
    // nastar uses umask 0xFF00 → IOC is on cpu_din/dout[15:8] (upper byte)
    // Some games (spacedxo, silentd) use umask 0x00FF → lower byte
    // Set 1 for upper byte (D[15:8]), 0 for lower byte (D[7:0])
    parameter logic        IOC_UPPER_BYTE = 1'b1,

    // ── SDRAM base addresses for TC0140SYT ADPCM ROM fetches ───────────────
    // nastar: 1MB GFX @ 0x200000, ADPCM-A 512KB @ 0x300000, ADPCM-B 512KB @ 0x380000
    // (Using the worst-case SDRAM layout from mame_research.md §Q2)
    parameter logic [26:0] ADPCMA_ROM_BASE = 27'h200000,
    parameter logic [26:0] ADPCMB_ROM_BASE = 27'h280000,

    // ── GFX ROM SDRAM base address ─────────────────────────────────────────
    // TC0180VCU gfx_addr[22:0] is a byte offset within GFX ROM.
    // SDRAM address = GFX_ROM_BASE + { gfx_addr[22:1], 1'b0 }  (16-bit word access)
    // nastar: 1MB GFX at SDRAM offset 0x100000
    parameter logic [26:0] GFX_ROM_BASE    = 27'h100000
) (
    // ── Clocks / Reset ──────────────────────────────────────────────────────
    input  logic        clk_sys,         // master system clock (e.g. 48 MHz)
    input  logic        clk_pix,         // pixel clock enable (1-cycle pulse, sys-domain)
    input  logic        clk_pix2x,       // 2× pixel clock enable (TC0260DAR ce_double)
    input  logic        reset_n,         // active-low async reset

    // ── MC68000 CPU Bus ─────────────────────────────────────────────────────
    // All signals are in the clk_sys domain.
    // cpu_addr is the 68000 word address (A[23:1]).
    input  logic [23:1] cpu_addr,
    input  logic [15:0] cpu_din,         // data FROM cpu (write path)
    output logic [15:0] cpu_dout,        // data TO cpu (read path mux)
    input  logic        cpu_lds_n,       // lower data strobe (active low)
    input  logic        cpu_uds_n,       // upper data strobe (active low)
    input  logic        cpu_rw,          // 1=read, 0=write
    input  logic        cpu_as_n,        // address strobe (active low)
    output logic        cpu_dtack_n,     // data transfer acknowledge (active low)
    output logic [2:0]  cpu_ipl_n,       // interrupt priority level (active low encoded)
    input  logic        iack_cycle,      // IACK detection from tb_top (FC=111, ASn=0)

    // ── Z80 Sound CPU Bus ───────────────────────────────────────────────────
    // Z80 CPU is now instantiated inside taito_b (T80s u_z80).
    // These ports are outputs for external debug probing only.
    output logic [15:0] z80_addr,
    output logic  [7:0] z80_din,         // data driven by Z80 (write to bus)
    output logic  [7:0] z80_dout,        // data read by Z80 (from peripheral mux)
    output logic        z80_rd_n,
    output logic        z80_wr_n,
    output logic        z80_mreq_n,
    output logic        z80_iorq_n,      // IORQ (not used by hardware but exported)
    output logic        z80_int_n,       // YM2610 /IRQ → Z80 /INT

    // Z80 decoded outputs (drive Z80 peripheral chip selects directly)
    output logic        z80_rom_cs0_n,   // ROM bank 0/1 CS (A[15:14]=00 or banked even)
    output logic        z80_rom_cs1_n,   // ROM bank CS (banked odd)
    output logic        z80_ram_cs_n,    // Z80 work RAM CS (0xE000–0xFFFF)
    output logic        z80_rom_a14,     // ROM address bit 14 (bank low)
    output logic        z80_rom_a15,     // ROM address bit 15 (bank high)
    output logic        z80_opx_n,       // YM2610 chip select (0xE000–0xE0FF)
    output logic        z80_reset_n,     // Z80 CPU reset (from SYT reset register)

    // ── CPU Program ROM SDRAM Interface ─────────────────────────────────────
    // 68000 reads from 0x000000–0x07FFFF (512KB) are served from SDRAM CH1.
    // SDRAM word address = cpu_addr[22:1] (byte addr shifted right by 1).
    // Toggle handshake: core toggles prog_rom_req; SDRAM mirrors ack when done.
    output logic [26:0] prog_rom_addr,   // SDRAM word address
    input  logic [15:0] prog_rom_data,   // SDRAM read data (16-bit word)
    output logic        prog_rom_req,    // request toggle
    input  logic        prog_rom_ack,    // acknowledge toggle

    // ── GFX ROM SDRAM Interface ─────────────────────────────────────────────
    // 16-bit word access; gfx_rom_addr is a word address in SDRAM.
    output logic [26:0] gfx_rom_addr,    // SDRAM word address for GFX ROM
    input  logic [15:0] gfx_rom_data,    // SDRAM read data (16-bit word)
    output logic        gfx_rom_req,     // request toggle (toggle to request)
    input  logic        gfx_rom_ack,     // acknowledge toggle

    // ── SDRAM Interface (TC0140SYT ADPCM) ───────────────────────────────────
    output logic [26:0] sdr_addr,
    input  logic [15:0] sdr_data,
    output logic        sdr_req,
    input  logic        sdr_ack,

    // ── Z80 ROM SDRAM Interface ──────────────────────────────────────────────
    // SDRAM base 0x080000 (word addr 0x040000); Z80 sees 64KB at 0x0000-0xFFFF.
    // Word address = 27'h040000 + z80_addr[15:1]
    output logic [26:0] z80_rom_addr,    // SDRAM word address
    input  logic [15:0] z80_rom_data,    // SDRAM read data (16-bit word)
    output logic        z80_rom_req,     // request toggle
    input  logic        z80_rom_ack,     // acknowledge toggle

    // ── Video Output ────────────────────────────────────────────────────────
    // TC0260DAR produces 8-bit per channel (expanded from 4-bit palette entries).
    output logic  [7:0] rgb_r,
    output logic  [7:0] rgb_g,
    output logic  [7:0] rgb_b,
    output logic        hsync_n,
    output logic        vsync_n,
    output logic        hblank,
    output logic        vblank,

    // ── Video Timing Inputs (from external timing generator) ────────────────
    // Standard 320×240 arcade timing; must be generated by top-level wrapper.
    input  logic        hblank_n_in,     // horizontal blank (active low, into VCU)
    input  logic        vblank_n_in,     // vertical blank   (active low, into VCU)
    input  logic  [8:0] hpos,            // horizontal pixel counter
    input  logic  [7:0] vpos,            // vertical scanline counter
    input  logic        hsync_n_in,      // hsync from timing generator
    input  logic        vsync_n_in,      // vsync from timing generator

    // ── Sound Clock ─────────────────────────────────────────────────────────
    input  logic        clk_sound,       // ~4 MHz clock enable for YM2610 / Z80

    // ── Audio Output ─────────────────────────────────────────────────────────
    output logic signed [15:0] snd_left,
    output logic signed [15:0] snd_right,

    // ── Player Inputs ───────────────────────────────────────────────────────
    // Active-low convention matching Taito B hardware (joy[0]=UP, etc.)
    // Bit layout per TC0220IOC IN[7:0] format:
    //   [7:6]=11 (unused/high), [5]=BTN3, [4]=BTN2, [3]=BTN1,
    //   [2]=RIGHT, [1]=LEFT, [0]=UP+DOWN packed — see integration_plan §2.3
    // Caller maps MiSTer joystick bits into this format.
    input  logic  [7:0] joystick_p1,
    input  logic  [7:0] joystick_p2,
    input  logic  [1:0] coin,            // [0]=COIN1, [1]=COIN2 (active low)
    input  logic        service,         // service button (active low)
    input  logic  [7:0] dipsw1,          // DIP switch bank 1
    input  logic  [7:0] dipsw2           // DIP switch bank 2
);

// =============================================================================
// Chip-Select Decode
// =============================================================================
// All comparisons use cpu_addr[23:1] (word address).
// AS_N qualification omitted here — the caller (or a registered CS pipeline)
// must ensure cpu_addr is stable when these selects are used.

// CPU Program ROM: 0x000000–0x07FFFF byte (512KB)
//   Word address range: 0x000000–0x03FFFF → top 9 bits [23:15] = 9'h000..9'h001
//   Simpler: top 9 bits [23:15] == 0 (i.e. cpu_addr[23:15] == 0 covers 0x000000–0x007FFF word = 0x000000–0x00FFFF byte — too narrow)
//   Correct: byte 0x000000–0x07FFFF → word 0x000000–0x03FFFF → bits [23:18] == 6'b000000
//   (top 6 bits zero means the address is in the first 256KB×2 = bottom 512KB)
logic prog_rom_cs;
assign prog_rom_cs = (cpu_addr[23:18] == 6'b000000) && !cpu_as_n;

// TC0180VCU: 512KB window (19-bit word offset → top 5 bits of 23-bit word addr)
//   nastar byte 0x400000–0x47FFFF → word 0x200000–0x23FFFF
//   Top 5 bits: cpu_addr[23:19] == VCU_BASE[23:19]
logic vcu_cs;
assign vcu_cs = (cpu_addr[23:19] == VCU_BASE[23:19]) && !cpu_as_n;

// TC0260DAR: 8KB byte window (4096 words, 12-bit word address A[12:1] free)
//   nastar byte 0x200000–0x201FFF → word 0x100000–0x100FFF
//   CS compares top 11 bits [23:13] so A[12:1] (12 bits) are free to index 4K words.
//   Bug fix: was [23:12] which included A12 in comparison → addr 0x201000+ missed CS.
logic dar_cs;
assign dar_cs = (cpu_addr[23:13] == DAR_BASE[23:13]) && !cpu_as_n;

// TC0220IOC: 16 registers max (4-bit word offset → cpu_addr[4:1])
//   nastar byte 0xA00000–0xA0001F → word 0x500000–0x50000F
//   Compare top 19 bits [23:5]: allows cpu_addr[4:1] = A[3:0] to vary freely.
//   This gives a 32-byte / 16-word window, covering all 16 IOC register addresses
//   including paddle registers (12-15 need A[3]=1, cpu_addr[4]=1).
//   For nastar (no paddles) only regs 0-7 are used; upper half is harmless.
logic ioc_cs_n;
assign ioc_cs_n = !((cpu_addr[23:5] == IOC_BASE[23:5]) && !cpu_as_n);

// TC0140SYT master: 2 byte addresses (port @ +0, comm @ +2)
//   nastar byte 0x800000–0x800003 → word 0x400000–0x400001
//   cpu_addr[23:2] == SYT_BASE[23:2]  (A[1] = MA1, selects port vs comm)
logic syt_mcs_n;
assign syt_mcs_n = !((cpu_addr[23:2] == SYT_BASE[23:2]) && !cpu_as_n);

// Work RAM: parameterized window
//   nastar byte 0x600000–0x607FFF → word 0x300000–0x303FFF (14-bit word addr)
<<<<<<< HEAD
//   CS compare uses bits above the RAM index: [23:WRAM_ABITS+1] so that all
//   WRAM_ABITS address bits (the RAM index) are free to vary.
//   WRAM_ABITS=14 → compare cpu_addr[23:15] vs WRAM_BASE[23:15] (9 bits).
=======
//
// Note on [23:1] indexing: cpu_addr is declared logic [23:1], so index N corresponds
// to bit (N-1) of the underlying value. To match a 2^WRAM_ABITS word window, we need
// to compare bits above position WRAM_ABITS of the word address. In [23:1] notation,
// the bit at index (WRAM_ABITS+1) corresponds to bit WRAM_ABITS of the word address.
// Therefore the tag comparison must use [23:WRAM_ABITS+1], not [23:WRAM_ABITS].
>>>>>>> sim-batch2
logic wram_cs;
assign wram_cs = (cpu_addr[23:WRAM_ABITS+1] == WRAM_BASE[23:WRAM_ABITS+1]) && !cpu_as_n;

// =============================================================================
// TC0180VCU
// =============================================================================
logic [15:0] vcu_dout;
logic        vcu_int_h, vcu_int_l;
logic [22:0] vcu_gfx_addr;
logic  [7:0] vcu_gfx_data;
logic        vcu_gfx_rd;
logic [12:0] vcu_pixel_out;
logic        vcu_pixel_valid;

tc0180vcu u_vcu (
    .clk         (clk_sys),
    .async_rst_n (reset_n),

    // CPU interface
    .cpu_cs      (vcu_cs),
    .cpu_we      (!cpu_rw),                         // active high write
    .cpu_addr    (cpu_addr[19:1]),                  // 19-bit word address within 512KB window
    .cpu_din     (cpu_din),
    .cpu_be      ({!cpu_uds_n, !cpu_lds_n}),        // [1]=UDS active, [0]=LDS active
    .cpu_dout    (vcu_dout),

    // Interrupts
    .int_h       (vcu_int_h),
    .int_l       (vcu_int_l),

    // Video timing
    .hblank_n    (hblank_n_in),
    .vblank_n    (vblank_n_in),
    .hpos        (hpos),
    .vpos        (vpos),

    // GFX ROM (byte interface — mux from 16-bit SDRAM word below)
    .gfx_addr    (vcu_gfx_addr),
    .gfx_data    (vcu_gfx_data),
    .gfx_rd      (vcu_gfx_rd),

    // Pixel output → TC0260DAR
    .pixel_out   (vcu_pixel_out),
    .pixel_valid (vcu_pixel_valid)
);

// =============================================================================
// CPU Program ROM SDRAM Bridge
// =============================================================================
// The 68000 reads program ROM from 0x000000–0x07FFFF (512KB).
// SDRAM word address = cpu_addr[22:1] (word-addressed; top bit [23] is always 0
// in this range, and the SDRAM layout places CPU ROM at byte offset 0x000000).
//
// Toggle-handshake protocol (same as GFX and Z80 ROM bridges above):
//   1. When prog_rom_cs asserts for a CPU read (!cpu_as_n && cpu_rw), toggle
//      prog_rom_req to initiate an SDRAM fetch.
//   2. Wait for prog_rom_ack == prog_rom_req (SDRAM controller has returned data).
//   3. Latch prog_rom_data into prog_rom_data_r.
//   4. Assert prog_dtack_now combinationally the cycle ack arrives; this feeds
//      directly into cpu_dtack_n so no extra cycle of latency is added.
//
// Guard condition !dtack_r prevents re-issuing a request during the same
// bus cycle once DTACK has already been asserted (same guard as nmk_arcade).
// =============================================================================
logic        prog_req_pending;
logic [26:0] prog_req_addr_r;
logic [15:0] prog_rom_data_r;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        prog_rom_req     <= 1'b0;
        prog_req_pending <= 1'b0;
        prog_req_addr_r  <= 27'b0;
        prog_rom_data_r  <= 16'hFFFF;
    end else begin
        if (prog_rom_cs && cpu_rw && !prog_req_pending && !dtack_r) begin
            // New CPU ROM read — issue SDRAM request
            // Word address: cpu_addr[23:1] is already a word address;
            // SDRAM expects a 27-bit word address (base 0 for CPU ROM).
            prog_req_addr_r  <= {3'b0, cpu_addr[23:1], 1'b0};  // 27-bit byte addr
            prog_req_pending <= 1'b1;
            prog_rom_req     <= ~prog_rom_req;
        end else if (prog_req_pending && (prog_rom_req == prog_rom_ack)) begin
            // SDRAM returned data — latch and release pending
            prog_rom_data_r  <= prog_rom_data;
            prog_req_pending <= 1'b0;
        end
    end
end

assign prog_rom_addr = prog_req_addr_r;

// prog_dtack_now: combinational — true the exact cycle SDRAM ack arrives.
// Used to assert cpu_dtack_n without waiting for dtack_r to register.
// (Pattern from nmk_arcade prog_dtack_now / fx68k_integration_reference §3B)
logic prog_dtack_now;
assign prog_dtack_now = prog_rom_cs && prog_req_pending && (prog_rom_req == prog_rom_ack);

// =============================================================================
// GFX ROM SDRAM Bridge
// TC0180VCU outputs a 23-bit BYTE address (gfx_addr[22:0]).
// SDRAM uses 16-bit word access: SDRAM_word_addr = GFX_ROM_BASE + byte_addr[22:1]
// The byte lane is selected by gfx_addr[0].
//
// Simple request-acknowledge bridge using a toggle handshake:
//   - When vcu_gfx_rd rises, compute word address and toggle gfx_rom_req
//   - When gfx_rom_ack == gfx_rom_req, data is ready; select byte lane
//   - Feed result to vcu_gfx_data
//
// NOTE: TC0180VCU's gfx_rd is a combinational strobe (not registered), so
// this bridge registers the request on gfx_rd rising edge.
// =============================================================================
logic        gfx_req_pending;
logic        gfx_byte_sel;    // which byte of the 16-bit SDRAM word to return
logic [26:0] gfx_req_addr;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        gfx_rom_req     <= 1'b0;
        gfx_req_pending <= 1'b0;
        gfx_byte_sel    <= 1'b0;
        gfx_req_addr    <= 27'b0;
    end else begin
        if (vcu_gfx_rd && !gfx_req_pending) begin
            // New GFX ROM request from VCU
            gfx_req_addr    <= GFX_ROM_BASE + {4'b0, vcu_gfx_addr[22:1]};
            gfx_byte_sel    <= vcu_gfx_addr[0];
            gfx_req_pending <= 1'b1;
            gfx_rom_req     <= ~gfx_rom_req;   // toggle to request
        end else if (gfx_req_pending && (gfx_rom_req == gfx_rom_ack)) begin
            gfx_req_pending <= 1'b0;
        end
    end
end

assign gfx_rom_addr = gfx_req_addr;
// Select the correct byte from the 16-bit SDRAM word
// Taito GFX ROMs are big-endian: even byte addr → data[15:8], odd → data[7:0]
assign vcu_gfx_data = gfx_byte_sel ? gfx_rom_data[7:0] : gfx_rom_data[15:8];

// =============================================================================
// Palette RAM — 8K × 16-bit synchronous block RAM
// Controlled by TC0260DAR (RA, RDout, RWELn, RWEHn)
// =============================================================================
logic [13:0] pal_ram_addr;
logic [15:0] pal_ram_din;
logic [15:0] pal_ram_dout;
logic        pal_ram_wel_n;
logic        pal_ram_weh_n;

// TC0260DAR drives RA[13:0] for both CPU and pixel access (muxed internally)
`ifdef QUARTUS
// Two 8-bit MLABs (one per byte lane).  Byte-slice writes to a 16-bit MLAB
// trigger Warning 10999 and fall back to flip-flops.  With per-lane arrays
// each array has a full-byte write-enable — the pattern Quartus 17.0 infers
// cleanly as MLAB.  Combinational read reconstructed from {hi, lo}.
(* ramstyle = "MLAB" *) logic [7:0] pal_ram_hi [0:8191]; // [15:8]
(* ramstyle = "MLAB" *) logic [7:0] pal_ram_lo [0:8191]; // [ 7:0]
`else
logic [15:0] pal_ram [0:8191];
`endif

always_ff @(posedge clk_sys) begin
`ifdef QUARTUS
    if (!pal_ram_weh_n) pal_ram_hi[pal_ram_addr[12:0]] <= pal_ram_din[15:8];
    if (!pal_ram_wel_n) pal_ram_lo[pal_ram_addr[12:0]] <= pal_ram_din[ 7:0];
`else
    if (!pal_ram_wel_n) pal_ram[pal_ram_addr[12:0]][7:0]  <= pal_ram_din[7:0];
    if (!pal_ram_weh_n) pal_ram[pal_ram_addr[12:0]][15:8] <= pal_ram_din[15:8];
`endif
end
`ifdef QUARTUS
assign pal_ram_dout = {pal_ram_hi[pal_ram_addr[12:0]], pal_ram_lo[pal_ram_addr[12:0]]};
`else
assign pal_ram_dout = pal_ram[pal_ram_addr[12:0]];
`endif

// =============================================================================
// TC0260DAR — Palette DAC
// =============================================================================
logic [15:0] dar_dout;
logic        dar_dtack_n;
logic        ohblank_n;
logic        ovblank_n;

TC0260DAR u_dar (
    .clk        (clk_sys),
    .ce_pixel   (clk_pix),
    .ce_double  (clk_pix2x),

    // RGB444 mode (bpp15=0, bppmix=0)
    .bpp15      (1'b0),
    .bppmix     (1'b0),

    // CPU interface
    .MDin       (cpu_din),
    .MDout      (dar_dout),
    .CS         (dar_cs),
    .MA         (cpu_addr[14:1]),   // 14-bit word address within DAR window
    .RWn        (cpu_rw),
    .UDSn       (cpu_uds_n),
    .LDSn       (cpu_lds_n),
    .DTACKn     (dar_dtack_n),
    .ACCMODE    (1'b0),

    // Video timing
    .HBLANKn    (hblank_n_in),
    .VBLANKn    (vblank_n_in),
    .OHBLANKn   (ohblank_n),
    .OVBLANKn   (ovblank_n),

    // Pixel index from VCU: 13-bit index, IM[13] tied 0
    .IM         ({1'b0, vcu_pixel_out}),

    // Video output
    .VIDEOR     (rgb_r),
    .VIDEOG     (rgb_g),
    .VIDEOB     (rgb_b),

    // External palette RAM
    .RA         (pal_ram_addr),
    .RDin       (pal_ram_dout),
    .RDout      (pal_ram_din),
    .RWELn      (pal_ram_wel_n),
    .RWEHn      (pal_ram_weh_n)
);

// =============================================================================
// TC0220IOC — I/O Controller
// =============================================================================
// nastar: IOC is on upper byte (D[15:8]), umask 0xFF00
// other games: may use lower byte (D[7:0]), controlled by IOC_UPPER_BYTE parameter
//
// IN[31:0] packing per integration_plan §2.3:
//   IN[7:0]   = P1 joystick + buttons (active low)
//   IN[15:8]  = P2 joystick + buttons (active low)
//   IN[23:16] = DIP switch bank 1
//   IN[31:24] = DIP switch bank 2
//
// INB[7:0] = {2'b11, TILT, SERVICE, COIN2, COIN1, START2, START1}
// (TILT tied high = inactive, START extracted from joystick_p1/p2 bit 4 if present)
logic [7:0] ioc_dout;

TC0220IOC u_ioc (
    .clk          (clk_sys),

    .RES_CLK_IN   (1'b0),
    .RES_INn      (1'b1),
    /* verilator lint_off PINCONNECTEMPTY */
    .RES_OUTn     (),               // unconnected — watchdog not implemented
    /* verilator lint_on PINCONNECTEMPTY */

    // Address: A[3:0] = cpu_addr[4:1] (4-bit register select)
    .A            (cpu_addr[4:1]),
    // WEn: TC0220IOC uses WEn=1 for reads (chip outputs), WEn=0 for writes (chip captures)
    // This matches 68000 R/W polarity directly (cpu_rw=1=read, cpu_rw=0=write)
    .WEn          (cpu_rw),
    .CSn          (ioc_cs_n),
    .OEn          (1'b0),

    // Data bus: select byte lane based on IOC_UPPER_BYTE parameter
    .Din          (IOC_UPPER_BYTE ? cpu_din[15:8]  : cpu_din[7:0]),
    .Dout         (ioc_dout),

    // Physical outputs — not used in MiSTer (no solenoids)
    /* verilator lint_off PINCONNECTEMPTY */
    .COIN_LOCK_A  (),
    .COIN_LOCK_B  (),
    .COINMETER_A  (),
    .COINMETER_B  (),
    /* verilator lint_on PINCONNECTEMPTY */

    // Input buses
    // INB: {2'b11, TILT(tied hi), SERVICE, COIN2, COIN1, START2, START1}
    // START buttons are typically in joystick byte bits (game-specific);
    // pulling TILT high (inactive) and mapping coin/service directly.
    .INB          ({2'b11, 1'b1, service, coin[1], coin[0], 1'b1, 1'b1}),
    .IN           ({dipsw2, dipsw1, joystick_p2, joystick_p1}),

    // Rotary/trackball — not used on standard Taito B games
    .rotary_inc   (1'b0),
    .rotary_abs   (1'b0),
    .rotary_a     (8'b0),
    .rotary_b     (8'b0)
);

// =============================================================================
// TC0140SYT — Sound Communication
// =============================================================================
// nastar: SYT master at 0x800000–0x800003 byte (word 0x400000–0x400001)
//   cpu_addr[1] = MA1 (selects port register vs comm register)
//   Data nibble: MDin[3:0] = cpu_din[4:1] (D[4:1] of lower byte)
//
// The SYT uses a nibble (4-bit) protocol on D[4:1]:
//   MDin[3:0] = cpu_din[4:1]
//   MDout[3:0] → drive cpu_dout[4:1] when SYT is selected for read
//
// MWRn: active-low write  → = cpu_rw (0=write, so MWRn=cpu_rw is wrong — needs inversion)
//   cpu_rw=0 means CPU writes → MWRn should be 0 → MWRn = cpu_rw is WRONG
//   MWRn = cpu_rw: when cpu_rw=1 (read), MWRn=1 (write inactive) ✓
//                  when cpu_rw=0 (write), MWRn=0 (write active) ✓
//   So MWRn = cpu_rw is CORRECT for active-low-write semantics.
//
// MRDn: active-low read → MRDn = ~cpu_rw (0 when CPU reads)
//   cpu_rw=1 (read) → MRDn=0 (read active) ✓
//   cpu_rw=0 (write) → MRDn=1 (read inactive) ✓
logic [3:0] syt_mdout;

// Z80 lower nibble from SYT
logic [3:0] syt_z80_dout;

// ADPCM data buses: SYT fetches ROM bytes for the YM2610
logic [7:0] ym_ya_dout;    // ADPCM-A ROM byte from SYT → jt10
logic [7:0] ym_yb_dout;    // ADPCM-B ROM byte from SYT → jt10

// YM2610 (jt10) ADPCM ROM address outputs → into SYT
logic [19:0] ym_adpcma_addr;
logic  [3:0] ym_adpcma_bank;
logic        ym_adpcma_roe_n;
logic [23:0] ym_adpcmb_addr;
logic        ym_adpcmb_roe_n;

// Construct the 24-bit YAA / YBA addresses that TC0140SYT expects:
// ADPCM-A: 20-bit addr + 4-bit bank → 24-bit: {bank[3:0], addr[19:0]}
logic [23:0] syt_yaa, syt_yba;
assign syt_yaa = { ym_adpcma_bank, ym_adpcma_addr };
assign syt_yba = { 4'b0,           ym_adpcmb_addr[23:4] };  // YM2610 ADPCM-B is 24-bit

TC0140SYT #(
    .ADPCMA_ROM_BASE (ADPCMA_ROM_BASE),
    .ADPCMB_ROM_BASE (ADPCMB_ROM_BASE)
) u_syt (
    .clk     (clk_sys),
    .ce_12m  (1'b0),
    .ce_4m   (1'b0),
    .RESn    (reset_n),

    // 68000 master interface
    .MDin    (cpu_din[4:1]),        // D[4:1] nibble
    .MDout   (syt_mdout),           // D[4:1] nibble (read path)
    .MA1     (cpu_addr[1]),         // A[1]: port vs comm register
    .MCSn    (syt_mcs_n),
    .MWRn    (cpu_rw),              // active-low write: 0 when cpu_rw=0 (write cycle)
    .MRDn    (~cpu_rw),             // active-low read: 0 when cpu_rw=1 (read cycle)

    // Z80 slave interface
    .MREQn   (z80_mreq_n),
    .RDn     (z80_rd_n),
    .WRn     (z80_wr_n),
    .A       (z80_addr),
    .Din     (z80_din[3:0]),        // Z80 data lower nibble
    .Dout    (syt_z80_dout),        // Z80 data lower nibble (read)

    // Z80 control outputs
    .ROUTn   (z80_reset_n),
    .ROMCS0n (z80_rom_cs0_n),
    .ROMCS1n (z80_rom_cs1_n),
    .RAMCSn  (z80_ram_cs_n),
    .ROMA14  (z80_rom_a14),
    .ROMA15  (z80_rom_a15),
    .OPXn    (z80_opx_n),

    // ADPCM ROM: YM2610 drives OEn + address, SYT fetches bytes from SDRAM
    .YAOEn   (ym_adpcma_roe_n),    // ADPCM-A output-enable from jt10
    .YBOEn   (ym_adpcmb_roe_n),    // ADPCM-B output-enable from jt10
    .YAA     (syt_yaa),             // ADPCM-A address (24-bit to SYT)
    .YBA     (ym_adpcmb_addr),      // ADPCM-B address (24-bit to SYT)
    .YAD     (ym_ya_dout),          // ADPCM-A data byte → jt10 adpcma_data
    .YBD     (ym_yb_dout),          // ADPCM-B data byte → jt10 adpcmb_data

    /* verilator lint_off PINCONNECTEMPTY */
    // Unused peripheral outputs
    .CSAn    (),
    .CSBn    (),
    .IOA     (),
    .IOC     (),
    /* verilator lint_on PINCONNECTEMPTY */

    // SDRAM for ADPCM ROM
    .sdr_address (sdr_addr),
    .sdr_data    (sdr_data),
    .sdr_req     (sdr_req),
    .sdr_ack     (sdr_ack)
);

// =============================================================================
// YM2610 (jt10) — FM synthesis + ADPCM-A + ADPCM-B
// =============================================================================
// jt10 is the YM2610 wrapper in the JT12 library.
// Clock: clk_sound (~4 MHz, provided by emu.sv clock divider).
// Bus: Z80 drives addr[1:0] + din + cs_n + wr_n; jt10 outputs dout.
// ADPCM ROM: addresses sent to TC0140SYT; byte data returned via YAD/YBD.
// Audio: snd_left/snd_right are 16-bit signed PCM at the jt10 sample rate.
//
// z80_opx_n is the YM2610 chip-select decoded by TC0140SYT.
// z80_addr[1:0] selects the YM2610 register address port.
logic [7:0] ym_dout;

/* verilator lint_off PINCONNECTEMPTY */
jt10 u_ym2610 (
    .rst          (~z80_reset_n),
    .clk          (clk_sys),
    .cen          (clk_sound),
    .din          (z80_din),
    .addr         (z80_addr[1:0]),
    .cs_n         (z80_opx_n),
    .wr_n         (z80_wr_n),

    .dout         (ym_dout),
    .irq_n        (z80_int_n),      // YM2610 /IRQ → Z80 /INT

    // ADPCM-A ROM interface (TC0140SYT handles SDRAM fetches)
    .adpcma_addr  (ym_adpcma_addr),
    .adpcma_bank  (ym_adpcma_bank),
    .adpcma_roe_n (ym_adpcma_roe_n),
    .adpcma_data  (ym_ya_dout),

    // ADPCM-B ROM interface
    .adpcmb_addr  (ym_adpcmb_addr),
    .adpcmb_roe_n (ym_adpcmb_roe_n),
    .adpcmb_data  (ym_yb_dout),

    // Audio output
    .snd_left     (snd_left),
    .snd_right    (snd_right),
    .snd_sample   (),

    // Separated outputs (unused — combined output used)
    .psg_A        (),
    .psg_B        (),
    .psg_C        (),
    .psg_snd      (),
    .fm_snd       (),

    // ADPCM-A channel enable: all 6 channels active
    .ch_enable    (6'h3f)
);
/* verilator lint_on PINCONNECTEMPTY */

// =============================================================================
// Z80 Sound CPU (T80s)
// =============================================================================
// The Z80 runs at ~4 MHz (clk_sound clock enable) and accesses:
//   0x0000–0x7FFF  Z80 ROM bank 0 (SDRAM 0x080000–0x087FFF; 32KB fixed)
//   0x8000–0xBFFF  banked ROM (via TC0140SYT ROMCS1n / ROMA14-15)
//   0xC000–0xDFFF  Z80 work RAM (2KB, internal BRAM — mirrors to fill 8KB)
//   0xE000–0xE0FF  YM2610 registers (TC0140SYT decodes → z80_opx_n)
//   0xE200         TC0140SYT comm register (decoded by TC0140SYT itself)
//
// Z80 ROM SDRAM reads: when z80_rom_cs0_n or z80_rom_cs1_n is active and the
// Z80 asserts RD_n (memory read), we toggle z80_rom_req to the SDRAM CH4 and
// hold WAIT_n low until z80_rom_ack toggles back to match.
// Word address: 27'h040000 + {z80_rom_a15, z80_rom_a14, z80_addr[13:1]}
// (SDRAM base 0x080000 = word 0x040000; ROM is 16-bit word-organised)
//
// Z80 internal 2KB work RAM (0xC000–0xC7FF, mirrored to 0xDFFF).
logic [7:0] z80_ram [0:2047];
logic [7:0] z80_ram_dout;

always_ff @(posedge clk_sys) begin
    if (!z80_ram_cs_n && !z80_wr_n && clk_sound)
        z80_ram[z80_addr[10:0]] <= z80_din;
end

always_ff @(posedge clk_sys) begin
    if (!z80_ram_cs_n)
        z80_ram_dout <= z80_ram[z80_addr[10:0]];
end

// Z80 ROM chip-select: active when either ROM CS is asserted by TC0140SYT
logic z80_rom_cs;
assign z80_rom_cs = !z80_rom_cs0_n | !z80_rom_cs1_n;

// Z80 ROM SDRAM request/stall logic
// Toggle z80_rom_req on each new ROM read; hold WAIT_n=0 until ack matches req.
logic z80_rom_req_r;       // current req toggle value
logic z80_rom_pending;     // read in flight
logic z80_rom_byte_sel;    // which byte of the returned word (z80_addr[0])
logic z80_wait_n;          // WAIT_n driven into T80s

// Registered prev-cycle ROM CS to detect new accesses
logic z80_rom_cs_prev;
logic z80_rd_n_prev;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        z80_rom_req_r   <= 1'b0;
        z80_rom_pending <= 1'b0;
        z80_rom_byte_sel<= 1'b0;
        z80_wait_n      <= 1'b1;
        z80_rom_cs_prev <= 1'b1;
        z80_rd_n_prev   <= 1'b1;
    end else begin
        z80_rom_cs_prev <= !z80_rom_cs;   // track negated (cs_n sense)
        z80_rd_n_prev   <= z80_rd_n;

        if (z80_rom_cs && !z80_rd_n && !z80_mreq_n && !z80_rom_pending) begin
            // New Z80 ROM read — issue SDRAM request
            z80_rom_req_r    <= ~z80_rom_req_r;
            z80_rom_pending  <= 1'b1;
            z80_rom_byte_sel <= z80_addr[0];
            z80_wait_n       <= 1'b0;   // stall Z80
        end else if (z80_rom_pending && (z80_rom_req_r == z80_rom_ack)) begin
            // SDRAM returned data
            z80_rom_pending <= 1'b0;
            z80_wait_n      <= 1'b1;   // release Z80
        end
    end
end

assign z80_rom_req  = z80_rom_req_r;
assign z80_rom_addr = 27'h040000 + {z80_rom_a15, z80_rom_a14, z80_addr[13:1]};

// Z80 data input mux:
//   ROM data | YM2610 dout | RAM dout | SYT nibble | open bus (0xFF)
logic [7:0] z80_cpu_din;
always_comb begin
    if (!z80_opx_n)
        z80_cpu_din = ym_dout;
    else if (!z80_ram_cs_n)
        z80_cpu_din = z80_ram_dout;
    else if (z80_rom_cs)
        // Select byte lane: even address → word[15:8], odd → word[7:0]
        z80_cpu_din = z80_rom_byte_sel ? z80_rom_data[7:0] : z80_rom_data[15:8];
    else
        z80_cpu_din = {4'hF, syt_z80_dout};  // SYT nibble in lower 4 bits
end

// Z80 CPU — T80s (Verilog-synthesised T80)
logic z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n;

T80s u_z80 (
    .RESET_n (z80_reset_n),
    .CLK     (clk_sys),
    .CEN     (clk_sound),
    .WAIT_n  (z80_wait_n),         // stall during SDRAM ROM fetches
    .INT_n   (z80_int_n),          // from jt10 irq_n
    .NMI_n   (1'b1),               // no NMI
    .BUSRQ_n (1'b1),               // no bus request
    .OUT0    (1'b0),
    .DI      (z80_cpu_din),
    .M1_n    (z80_m1_n),
    .MREQ_n  (z80_mreq_n),
    .IORQ_n  (z80_iorq_n),
    .RD_n    (z80_rd_n),
    .WR_n    (z80_wr_n),
    .RFSH_n  (z80_rfsh_n),
    .HALT_n  (z80_halt_n),
    .BUSAK_n (z80_busak_n),
    .A       (z80_addr),
    .DOUT    (z80_din)
);

// z80_dout is what the Z80 reads (the input mux above feeds DI on T80s).
// The taito_b port z80_dout is legacy — it was the output before the Z80
// was instantiated internally. We keep it driven for external debug probing.
assign z80_dout    = z80_cpu_din;

// =============================================================================
// Work RAM — synchronous block RAM (68000 general purpose)
// Width: 16-bit words; depth: 2^WRAM_ABITS words
// nastar: 32KB (14-bit word addr, WRAM_ABITS=14)
// =============================================================================
`ifdef QUARTUS
// altsyncram SINGLE_PORT with byteena_a=2 (one bit per byte lane).
// The M10K hint + conditional byte-slice writes causes MAP OOM (Error 293007)
// in Quartus 17.0 because the synthesizer expands to flip-flops when it
// cannot infer byteena from conditional slice assignments.
logic [15:0] wram_dout_r;
altsyncram #(
    .operation_mode         ("SINGLE_PORT"),
    .width_a                (16),
    .widthad_a              (WRAM_ABITS),
    .numwords_a             (1 << WRAM_ABITS),
    .outdata_reg_a          ("CLOCK0"),
    .clock_enable_input_a   ("BYPASS"),
    .clock_enable_output_a  ("BYPASS"),
    .intended_device_family ("Cyclone V"),
    .lpm_type               ("altsyncram"),
    .ram_block_type         ("M10K"),
    .width_byteena_a        (2),
    .power_up_uninitialized ("FALSE"),
    .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ")
) work_ram_inst (
    .clock0     (clk_sys),
    .address_a  (cpu_addr[WRAM_ABITS:1]),
    .data_a     (cpu_din),
    .wren_a     (wram_cs && !cpu_rw),
    .byteena_a  ({~cpu_uds_n, ~cpu_lds_n}),
    .q_a        (wram_dout_r),
    .aclr0(1'b0), .addressstall_a(1'b0), .clocken0(1'b1), .clocken1(1'b1),
    .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1)
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
`endif

`ifndef QUARTUS
// In QUARTUS path wram_dout_r is driven directly by altsyncram q_a output.
always_ff @(posedge clk_sys) begin
    if (wram_cs) wram_dout_r <= work_ram[cpu_addr[WRAM_ABITS:1]];
end
`endif

// =============================================================================
// CPU Data Bus Read Mux
// =============================================================================
// Priority: ROM > VCU > DAR > IOC > SYT > WRAM > default open-bus
//
// ROM data: when prog_dtack_now pulses (SDRAM ack just arrived), forward the
// live prog_rom_data directly.  Once latched into prog_rom_data_r the next
// cycle, the bus cycle is already terminating (dtack_r will be high), so only
// the live-forwarding path is needed for correct data to the CPU.
//
// IOC data is byte-wide; expand to 16-bit word on the correct byte lane.
// SYT data is 4-bit nibble; place on D[4:1] of lower byte.
logic [15:0] ioc_dout_word;
logic [15:0] syt_dout_word;

assign ioc_dout_word = IOC_UPPER_BYTE ? {ioc_dout, 8'hFF}    : {8'hFF, ioc_dout};
assign syt_dout_word = {11'b0, syt_mdout, 1'b0};  // nibble in D[4:1], rest open

always_comb begin
    if (prog_rom_cs)
        // Forward live data when ack arrives; fall back to latched data while stalling.
        // prog_dtack_now selects the live word; before ack, prog_rom_data_r holds 0xFFFF.
        cpu_dout = prog_dtack_now ? prog_rom_data : prog_rom_data_r;
    else if (vcu_cs)
        cpu_dout = vcu_dout;
    else if (dar_cs)
        cpu_dout = dar_dout;
    else if (!ioc_cs_n)
        cpu_dout = ioc_dout_word;
    else if (!syt_mcs_n)
        cpu_dout = syt_dout_word;
    else if (wram_cs)
        cpu_dout = wram_dout_r;
    else
        cpu_dout = 16'hFFFF;   // open bus
end

// =============================================================================
// DTACK Generation
// =============================================================================
// TC0260DAR has its own DTACKn output (stalls CPU during active display).
// CPU ROM reads stall until SDRAM ack returns (prog_dtack_now).
// All other chips are synchronous with 1-cycle latency; DTACK asserted after
// one clock (2-cycle total: AS_N falls → CS decode → DTACK next cycle).
//
// Implementation:
//   - ROM:          prog_dtack_now (combinational ack) — no latency after SDRAM
//   - DAR:          dar_dtack_n directly (handles palette RAM busy stalls)
//   - VCU/IOC/SYT/WRAM: registered 1-cycle DTACK via dtack_r
//
// dtack_r latches the OR of all fast chip-selects (including prog_dtack_now so
// that dtack_r holds DTACK asserted across the remainder of the ROM bus cycle).
// cpu_dtack_n priority: ROM > DAR > fast DTACK.

logic any_cs;
logic dtack_r;

// imm_cs: all chip selects except ROM (which has its own slow path) and DAR
assign any_cs = vcu_cs | !ioc_cs_n | !syt_mcs_n | wram_cs;

// dtack_r: hold DTACK for the duration of fast-device and ROM bus cycles.
// prog_dtack_now feeds in so that once the ROM ack arrives, dtack_r latches it.
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        dtack_r <= 1'b0;
    else
        dtack_r <= !cpu_as_n && (dtack_r | any_cs | prog_dtack_now);
end

// ── Open-bus fallback DTACK ────────────────────────────────────────────────
// On real hardware, unmapped addresses get DTACK from a system bus timer
// (typically a 1-shot or the bus-cycle watchdog). Without this, unselected
// addresses cause the CPU to stall forever in simulation.
//
// Implementation: 2-stage shift register; dtack fires 2 cycles after AS_N
// goes low when no device is selected. Cleared immediately on AS_N deassert.
//
// "No device" covers:
//   - Truly unmapped addresses (!any_cs && !dar_cs && !prog_rom_cs)
//   - Writes to ROM space (prog_rom_cs=1 but cpu_rw=0 → ROM write, no DTACK normally)
logic open_bus;
assign open_bus = !cpu_as_n && !any_cs && !dar_cs &&
                  (!prog_rom_cs || !cpu_rw);  // !prog_rom_cs = unmapped, !cpu_rw = ROM write

logic open_dtack_1, open_dtack_2;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        open_dtack_1 <= 1'b0;
        open_dtack_2 <= 1'b0;
    end else begin
        open_dtack_1 <= open_bus;
        open_dtack_2 <= open_dtack_1 & open_bus;  // 2 cycles = bus hold
    end
end

// cpu_dtack_n:
//   - High (1) while AS is deasserted — no bus cycle in progress
//   - Low  (0) immediately when prog_dtack_now fires (ROM data ready this cycle)
//   - Low  (0) via dar_dtack_n when palette DAC is selected
//   - Low  (0) via dtack_r for all other fast devices (and ROM hold after ack)
//   - Low  (0) via open_dtack_2 for unmapped/open-bus addresses (fallback)
assign cpu_dtack_n = cpu_as_n       ? 1'b1
                   : prog_dtack_now ? 1'b0
                   : dar_cs         ? dar_dtack_n
                   : open_dtack_2   ? 1'b0
                   :                  !dtack_r;

// =============================================================================
// Interrupt (IPL) Generation — IACK-based clear
// =============================================================================
// int_h and int_l from TC0180VCU are single-cycle pulses (registered, cleared
// next cycle) per tc0180vcu.sv lines 569–589.
//
// Fix: IACK-based clear (replaces timer-based clear).
// Community pattern (jotego/cave/neogeo): interrupt stays asserted until CPU
// acknowledges (FC=111, ASn=0). Timer-based clear was WRONG: if pswI=7 during
// init, the timer expires before the CPU can see the interrupt. IACK-based
// clear holds the interrupt indefinitely until the CPU actually acknowledges it.
//
// iack_cycle is passed from tb_top.sv where FC signals are available.
// On IACK, we clear the HIGHEST active interrupt (the one being acknowledged).

logic ipl_h_active, ipl_l_active;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl_h_active <= 1'b0;
        ipl_l_active <= 1'b0;
    end else begin
        // int_h: latch on VCU pulse, clear on IACK when int_h is the active level
        if (vcu_int_h)
            ipl_h_active <= 1'b1;
        else if (iack_cycle && ipl_h_active &&
                 (INT_H_LEVEL >= INT_L_LEVEL || !ipl_l_active))
            ipl_h_active <= 1'b0;

        // int_l: latch on VCU pulse, clear on IACK when int_l is the active level
        if (vcu_int_l)
            ipl_l_active <= 1'b1;
        else if (iack_cycle && ipl_l_active &&
                 (INT_L_LEVEL > INT_H_LEVEL || !ipl_h_active))
            ipl_l_active <= 1'b0;
    end
end

// IPL encoding: highest pending level wins (HOLD_LINE semantics)
// cpu_ipl_n is active-low encoded: 3'b111 = no interrupt, ~level = interrupt
// If both active, higher level takes priority.
//
// Register IPL through synchronizer FF to ensure stable sampling
// by fx68k's two-stage pipeline (rIpl → iIpl → iplStable check).
logic [2:0] ipl_raw;
always_comb begin
    if      (ipl_h_active && (INT_H_LEVEL >= INT_L_LEVEL || !ipl_l_active))
        ipl_raw = ~INT_H_LEVEL;
    else if (ipl_l_active)
        ipl_raw = ~INT_L_LEVEL;
    else
        ipl_raw = 3'b111;   // no interrupt
end

reg [2:0] ipl_sync;
always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        ipl_sync <= 3'b111;
    else
        ipl_sync <= ipl_raw;
end

assign cpu_ipl_n = ipl_sync;

// =============================================================================
// Video Sync / Blank Output
// =============================================================================
// TC0260DAR produces delayed OHBLANKn / OVBLANKn (3-cycle pipeline).
// Use DAR's pipelined blanks for the final output to the video encoder.
assign hblank   = !ohblank_n;
assign vblank   = !ovblank_n;
assign hsync_n  = hsync_n_in;
assign vsync_n  = vsync_n_in;

// =============================================================================
// Unused signal suppression
// =============================================================================
/* verilator lint_off UNUSED */
logic _unused;
assign _unused = ^{vcu_pixel_valid, pal_ram_addr[13],
                   z80_rfsh_n, z80_halt_n, z80_busak_n, z80_m1_n,
                   z80_rom_cs_prev, z80_rd_n_prev};
/* verilator lint_on UNUSED */

endmodule
