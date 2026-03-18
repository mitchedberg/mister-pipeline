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

// TC0180VCU: 512KB window (19-bit word offset → top 5 bits of 23-bit word addr)
//   nastar byte 0x400000–0x47FFFF → word 0x200000–0x23FFFF
//   Top 5 bits: cpu_addr[23:19] == VCU_BASE[23:19]
logic vcu_cs;
assign vcu_cs = (cpu_addr[23:19] == VCU_BASE[23:19]) && !cpu_as_n;

// TC0260DAR: 8KB window (8K × 16-bit words = palette RAM)
//   nastar byte 0x200000–0x201FFF → word 0x100000–0x100FFF
//   Top 12 bits: cpu_addr[23:12] == DAR_BASE[23:12]
logic dar_cs;
assign dar_cs = (cpu_addr[23:12] == DAR_BASE[23:12]) && !cpu_as_n;

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
logic wram_cs;
assign wram_cs = (cpu_addr[23:WRAM_ABITS] == WRAM_BASE[23:WRAM_ABITS]) && !cpu_as_n;

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
logic [15:0] pal_ram [0:8191];

always_ff @(posedge clk_sys) begin
    if (!pal_ram_wel_n) pal_ram[pal_ram_addr[12:0]][7:0]  <= pal_ram_din[7:0];
    if (!pal_ram_weh_n) pal_ram[pal_ram_addr[12:0]][15:8] <= pal_ram_din[15:8];
end
assign pal_ram_dout = pal_ram[pal_ram_addr[12:0]];

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
//   0x0000–0x7FFF  Z80 ROM (from SDRAM 0x080000; TODO: add Z80 ROM SDRAM channel)
//   0x8000–0xBFFF  banked ROM (via TC0140SYT ROMCS1n / ROMA14-15)
//   0xC000–0xDFFF  Z80 work RAM (2KB, internal BRAM — mirrors to fill 8KB)
//   0xE000–0xE0FF  YM2610 registers (TC0140SYT decodes → z80_opx_n)
//   0xE200         TC0140SYT comm register (decoded by TC0140SYT itself)
//
// TODO: Add a Z80 ROM SDRAM read channel. For now the Z80 ROM path is stubbed
// (reads return 0xFF = NOP equivalent). The TC0140SYT sound comms will still
// work once a real Z80 ROM is loaded, so this is a correct-if-silent skeleton.
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

// Z80 data input mux:
//   SYT lower nibble | YM2610 dout | RAM dout | open bus (0xFF)
logic [7:0] z80_cpu_din;
always_comb begin
    if (!z80_opx_n)
        z80_cpu_din = ym_dout;
    else if (!z80_ram_cs_n)
        z80_cpu_din = z80_ram_dout;
    else
        z80_cpu_din = {4'hF, syt_z80_dout};  // SYT nibble in lower 4 bits
end

// Z80 CPU — T80s (Verilog-synthesised T80)
logic z80_m1_n, z80_rfsh_n, z80_halt_n, z80_busak_n;

T80s u_z80 (
    .RESET_n (z80_reset_n),
    .CLK     (clk_sys),
    .CEN     (clk_sound),
    .WAIT_n  (1'b1),               // no wait states
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

// =============================================================================
// CPU Data Bus Read Mux
// =============================================================================
// Priority: VCU > DAR > IOC > SYT > WRAM > default open-bus
//
// IOC data is byte-wide; expand to 16-bit word on the correct byte lane.
// SYT data is 4-bit nibble; place on D[4:1] of lower byte.
logic [15:0] ioc_dout_word;
logic [15:0] syt_dout_word;

assign ioc_dout_word = IOC_UPPER_BYTE ? {ioc_dout, 8'hFF}    : {8'hFF, ioc_dout};
assign syt_dout_word = {11'b0, syt_mdout, 1'b0};  // nibble in D[4:1], rest open

always_comb begin
    if (vcu_cs)
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
// All other chips are synchronous with 1-cycle latency; DTACK asserted after
// one clock (2-cycle total: AS_N falls → CS decode → DTACK next cycle).
//
// Simple implementation:
//   - DAR: use dar_dtack_n directly (it handles palette RAM busy stalls)
//   - VCU: registered 1-cycle DTACK
//   - IOC/SYT/WRAM: registered 1-cycle DTACK
//   - Any CS → generate DTACK; active-low AND of all chip DTACKs
//
// A 2-cycle pipeline: register the chip-select one cycle after AS_N falls,
// then assert DTACK.

logic any_cs;
logic dtack_r;

assign any_cs = vcu_cs | dar_cs | !ioc_cs_n | !syt_mcs_n | wram_cs;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)
        dtack_r <= 1'b0;
    else
        dtack_r <= any_cs;
end

// cpu_dtack_n: assert (low) when either registered fast-DTACK or DAR's DTACK
// DAR DTACKn: 0 = ready (active low), 1 = stalling
// cpu_dtack_n = 0 means CPU can proceed:
//   - DAR selected and DAR is ready (!dar_dtack_n)
//   - OR non-DAR chip selected and one cycle has passed (dtack_r)
//   - Active while AS is asserted (clear when AS_N rises)
assign cpu_dtack_n = cpu_as_n ? 1'b1
                   : dar_cs   ? dar_dtack_n
                   :            !dtack_r;

// =============================================================================
// Interrupt (IPL) Generation
// =============================================================================
// int_h and int_l from TC0180VCU are single-cycle pulses (registered, cleared
// next cycle) per tc0180vcu.sv lines 524–534.
//
// HOLD_LINE semantics: assert IPL for the duration of the interrupt window.
// We latch each pulse and hold until the 68000 performs an IACK cycle.
// IACK detection: cpu_as_n=0 AND cpu_fc==3'b111 (function codes).
// Since FC is not a top-level port here (the CPU is external), we use a simpler
// self-clearing approach: hold for a fixed window (one vblank line ≈ 256 pixels
// = 256 clk_sys cycles at one pixel per cycle), then release.
// The 68000 should respond well within this window.
//
// Window timer: 9-bit counter (512 cycles ≈ 2 scanlines at 48 MHz/48 ns per clk
// and 320-pixel lines = 320 clk_pix pulses per line; at 48MHz master with 4MHz
// pixel CE, 48/4=12 clk_sys per pixel → 512 cycles ≈ 42 pixels = sufficient).
// In practice, use a 16-bit counter for safety (65536 cycles).

logic        ipl_h_active, ipl_l_active;
logic [15:0] ipl_h_timer,  ipl_l_timer;

always_ff @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ipl_h_active <= 1'b0;
        ipl_l_active <= 1'b0;
        ipl_h_timer  <= 16'b0;
        ipl_l_timer  <= 16'b0;
    end else begin
        // int_h: latch on pulse, hold for timer
        if (vcu_int_h) begin
            ipl_h_active <= 1'b1;
            ipl_h_timer  <= 16'hFFFF;
        end else if (ipl_h_active) begin
            if (ipl_h_timer == 16'b0)
                ipl_h_active <= 1'b0;
            else
                ipl_h_timer <= ipl_h_timer - 16'd1;
        end

        // int_l: latch on pulse, hold for timer
        if (vcu_int_l) begin
            ipl_l_active <= 1'b1;
            ipl_l_timer  <= 16'hFFFF;
        end else if (ipl_l_active) begin
            if (ipl_l_timer == 16'b0)
                ipl_l_active <= 1'b0;
            else
                ipl_l_timer <= ipl_l_timer - 16'd1;
        end
    end
end

// IPL encoding: highest pending level wins (HOLD_LINE semantics)
// cpu_ipl_n is active-low encoded: 3'b111 = no interrupt, ~level = interrupt
// If both active, higher level takes priority.
always_comb begin
    if      (ipl_h_active && (INT_H_LEVEL >= INT_L_LEVEL || !ipl_l_active))
        cpu_ipl_n = ~INT_H_LEVEL;
    else if (ipl_l_active)
        cpu_ipl_n = ~INT_L_LEVEL;
    else
        cpu_ipl_n = 3'b111;   // no interrupt
end

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
                   z80_rfsh_n, z80_halt_n, z80_busak_n, z80_m1_n};
/* verilator lint_on UNUSED */

endmodule
