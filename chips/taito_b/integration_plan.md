# Taito B System — MiSTer Core Integration Plan

**Date:** 2026-03-16
**Status:** Pre-RTL (TC0180VCU research complete; support chips audited)
**Reference:** MAME `src/mame/taito/taito_b.cpp`, `src/mame/taito/tc0180vcu.cpp`

---

## 1. System Architecture Diagram

```
                         ┌──────────────────────────────────────────────────────┐
                         │                  Taito B System Board                │
                         │                                                      │
    ┌────────────────┐   │   ┌──────────────────────────────────────────────┐   │
    │   MiSTer HPS   │   │   │         MC68000 @ 12 MHz                     │   │
    │  (ARM, Linux)  │   │   │  Data[15:0]  Addr[23:1]  AS/DS/RW/DTACK     │   │
    │                │   │   └──────────┬───────────────────────────────────┘   │
    │  ROM images    │   │              │ 68000 bus                              │
    │  loaded into   │   │   ┌──────────┼──────────────────────────────────┐    │
    │  SDRAM         │   │   │          │     Address Decode / PAL          │    │
    └────────┬───────┘   │   └──────────┬──────┬──────┬──────┬─────────────┘    │
             │           │              │      │      │      │                   │
             │           │              │      │      │      │                   │
    ┌────────┴───────┐   │   ┌──────────┤   ┌──┴──┐ ┌┴────┐ ┌┴──────────────┐  │
    │   SDRAM 32MB   │   │   │          │   │IOC  │ │DAR  │ │  TC0140SYT    │  │
    │                │   │   │TC0180VCU │   │     │ │     │ │  (68000 side) │  │
    │ [68K prog ROM] │◄──┼───┤(512KB at │   │0x30 │ │0x20 │ │  0x10 / 0x12 │  │
    │ [Z80 prog ROM] │   │   │ 0x400000)│   │0000 │ │0000 │ └──────┬────────┘  │
    │ [GFX ROM]      │◄──┼───┤          │   └──┬──┘ └──┬──┘        │           │
    │ [ADPCM-A ROM]  │◄──┼───┤          │      │      │(palette     │Z80 reset  │
    │ [ADPCM-B ROM]  │◄──┼───┤          │      │      │ index)      │           │
    │                │   │   │          │   ┌──┴──────────────────┐ │           │
    └────────────────┘   │   │ CPU bus  │   │   TC0260DAR (DAC)   │ │           │
                         │   │ (19-bit  │   │   palette RAM       │ │           │
                         │   │  word    │   │   RGB output        │ │           │
                         │   │  addr)   │   └──────────┬──────────┘ │           │
                         │   │          │              │             │           │
                         │   │ pixel_   │           VIDEOR/G/B      │           │
                         │   │ out[12:0]│                           │           │
                         │   │ →DAR.IM  │   ┌─────────────────────────────────┐ │
                         │   │          │   │         Z80 @ 4 MHz             │ │
                         │   │ int_h/l  │   │  (sound CPU)                   │ │
                         │   │ →CPU IPL │   │                                 │ │
                         │   │          │   │  A[15:0]  D[7:0]               │ │
                         │   └──────────┘   │  MREQn/RDn/WRn/M1n             │ │
                         │                  └──────┬───────────────────────────┘ │
                         │                         │                              │
                         │                  ┌──────┴──────────────────────────┐  │
                         │                  │         TC0140SYT                │  │
                         │                  │         (Z80 side decode)        │  │
                         │                  │                                  │  │
                         │                  │  0xE000: work RAM                │  │
                         │                  │  0xE200: SYT slave regs          │  │
                         │                  │  0xE000: OPX (YM2610 CS)         │  │
                         │                  │  0x4000: switchable ROM bank     │  │
                         │                  │  0x0000: fixed ROM (bank 0)      │  │
                         │                  └──────┬──────────────────────────-┘  │
                         │                         │                              │
                         │                  ┌──────┴──────────────────────────┐  │
                         │                  │       YM2610 / YM2151           │  │
                         │                  │  (OPN2 + ADPCM-A + ADPCM-B)     │  │
                         │                  │  YAA[23:0] / YBA[23:0]          │  │
                         │                  │  YAOEn / YBOEn                  │  │
                         │                  │  YAD[7:0] / YBD[7:0]            │  │
                         │                  └─────────────────────────────────┘  │
                         └──────────────────────────────────────────────────────┘
```

---

## 2. Port-by-Port Wiring Table

### 2.1 TC0180VCU

| Port | Direction | Width | Connects To |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System pixel clock (13.333 MHz or master clock with CE) |
| `async_rst_n` | in | 1 | System reset (active low) |
| `cpu_cs` | in | 1 | Address decode: asserted when 68000 address is in 0x400000–0x47FFFF |
| `cpu_we` | in | 1 | 68000 R/Wn (active high write) |
| `cpu_addr[18:0]` | in | 19 | 68000 A[19:1] — word address within 512KB window (A[20] selects chip) |
| `cpu_din[15:0]` | in | 16 | 68000 data bus (write path) |
| `cpu_be[1:0]` | in | 2 | `{~UDSn, ~LDSn}` — byte enables from 68000 |
| `cpu_dout[15:0]` | out | 16 | 68000 data bus (read path, mux with other chips) |
| `int_h` | out | 1 | 68000 IPL interrupt (VBLANK, level 5) — through PAL |
| `int_l` | out | 1 | 68000 IPL interrupt (~8 lines post-VBLANK, level 4) — through PAL |
| `hblank_n` | in | 1 | Video timing generator HBlank |
| `vblank_n` | in | 1 | Video timing generator VBlank |
| `hpos[8:0]` | in | 9 | Horizontal pixel counter from video timing |
| `vpos[7:0]` | in | 8 | Vertical line counter from video timing |
| `gfx_addr[22:0]` | out | 23 | GFX ROM byte address → SDRAM arbitrator |
| `gfx_data[7:0]` | in | 8 | GFX ROM read data ← SDRAM |
| `gfx_rd` | out | 1 | GFX ROM read strobe → SDRAM arbitrator |
| `pixel_out[12:0]` | out | 13 | Palette index → TC0260DAR `IM[12:0]` (13-bit palette address) |
| `pixel_valid` | out | 1 | High during active display → TC0260DAR blanking qualifier |

**Note on `pixel_out` to `IM` width:** TC0260DAR has a 14-bit `IM` port. The TC0180VCU produces a 13-bit index (`pixel_out[12:0]`). Wire `IM[12:0] = pixel_out[12:0]; IM[13] = 1'b0` (palette RAM is 8K entries for a 13-bit index; top bit unused).

---

### 2.2 TC0260DAR

| Port | Direction | Width | Connects To |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `ce_pixel` | in | 1 | Pixel clock enable (1× pixel rate) |
| `ce_double` | in | 1 | Double pixel clock enable (2× pixel rate) |
| `bpp15` | in | 1 | Tie to `1'b0` (Taito B uses RGB444 mode) |
| `bppmix` | in | 1 | Tie to `1'b0` (unused when bpp15=0) |
| `MDin[15:0]` | in | 16 | 68000 data bus (write path) |
| `MDout[15:0]` | out | 16 | 68000 data bus (read path, mux with other chips) |
| `CS` | in | 1 | Address decode: asserted when 68000 address is in 0x200000–0x20FFFF (Nastar) |
| `MA[13:0]` | in | 14 | 68000 A[14:1] — word address within DAR window |
| `RWn` | in | 1 | 68000 R/Wn |
| `UDSn` | in | 1 | 68000 UDSn |
| `LDSn` | in | 1 | 68000 LDSn |
| `DTACKn` | out | 1 | Routed to 68000 DTACK (ANDed with other chip DTACKs) |
| `ACCMODE` | in | 1 | Tie to `1'b0` (normal mode; set 1 for direct CPU access bypass) |
| `HBLANKn` | in | 1 | Video timing HBlank |
| `VBLANKn` | in | 1 | Video timing VBlank |
| `OHBLANKn` | out | 1 | Delayed HBlank (3-cycle pipeline) — drive display blanking |
| `OVBLANKn` | out | 1 | Delayed VBlank — drive display blanking |
| `IM[13:0]` | in | 14 | `{1'b0, pixel_out[12:0]}` from TC0180VCU |
| `VIDEOR[7:0]` | out | 8 | Red output → video DAC / HDMI encoder |
| `VIDEOG[7:0]` | out | 8 | Green output → video DAC / HDMI encoder |
| `VIDEOB[7:0]` | out | 8 | Blue output → video DAC / HDMI encoder |
| `RA[13:0]` | out | 14 | Palette RAM address → external block RAM port A address |
| `RDin[15:0]` | in | 16 | Palette RAM read data ← external block RAM port A data out |
| `RDout[15:0]` | out | 16 | Palette RAM write data → external block RAM port A data in |
| `RWELn` | out | 1 | Palette RAM low-byte write enable (active low) |
| `RWEHn` | out | 1 | Palette RAM high-byte write enable (active low) |

**Palette RAM instantiation (top level):** Instantiate a 16KB (8K × 16-bit) single-port synchronous block RAM. Connect RA, RDin/RDout, RWELn/RWEHn directly. Use BRAM (no SDRAM needed — fits in a few M10K blocks).

---

### 2.3 TC0220IOC

| Port | Direction | Width | Connects To |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `RES_CLK_IN` | in | 1 | Tie to `1'b0` (watchdog unimplemented) |
| `RES_INn` | in | 1 | Tie to `1'b1` (no external reset input) |
| `RES_OUTn` | out | 1 | Leave unconnected or tie off (watchdog output unimplemented) |
| `A[3:0]` | in | 4 | 68000 A[4:1] — 4-bit register select within IOC window |
| `WEn` | in | 1 | Invert of 68000 R/Wn: `~RWn` |
| `CSn` | in | 1 | Address decode (active low): asserted when 68000 address is in 0x300000–0x30000F |
| `OEn` | in | 1 | Tie to `1'b0` (unused in module logic) |
| `Din[7:0]` | in | 8 | 68000 D[7:0] (lower byte of data bus) |
| `Dout[7:0]` | out | 8 | 68000 data bus (read path, lower byte) |
| `COIN_LOCK_A` | out | 1 | Coin lockout solenoid A — tie to open (no physical output needed) |
| `COIN_LOCK_B` | out | 1 | Coin lockout solenoid B — tie to open |
| `COINMETER_A` | out | 1 | Coin meter A — tie to open |
| `COINMETER_B` | out | 1 | Coin meter B — tie to open |
| `INB[7:0]` | in | 8 | Second input bank: `{2'b11, TILT, SERVICE, COIN2, COIN1, START2, START1}` |
| `IN[31:0]` | in | 32 | Main input bus, packed as four bytes — see §4.1 input mapping |
| `rotary_inc` | in | 1 | Tie to `1'b0` (no rotary encoders on standard Taito B games) |
| `rotary_abs` | in | 1 | Tie to `1'b0` |
| `rotary_a[7:0]` | in | 8 | Tie to `8'b0` |
| `rotary_b[7:0]` | in | 8 | Tie to `8'b0` |

**IN[31:0] packing (addr 0–3 reads, 8 bits each):**
```
IN[7:0]   (addr 0): P1 joystick + buttons: {2'b11, P1_BTN3, P1_BTN2, P1_BTN1, P1_RIGHT, P1_LEFT, P1_DOWN, P1_UP} — active low
IN[15:8]  (addr 1): P2 joystick + buttons: same layout for P2
IN[23:16] (addr 2): DIP switch bank 1 (8 bits)
IN[31:24] (addr 3): DIP switch bank 2 (8 bits)
```

---

### 2.4 TC0140SYT

| Port | Direction | Width | Connects To |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `ce_12m` | in | 1 | Tie to `1'b0` (unused in module logic) |
| `ce_4m` | in | 1 | Tie to `1'b0` (unused in module logic) |
| `RESn` | in | 1 | System reset (active low) |
| `MDin[3:0]` | in | 4 | 68000 D[4:1] — 4-bit data from 68000 (nibble protocol) |
| `MDout[3:0]` | out | 4 | 68000 data bus (read path, bits [4:1]) |
| `MA1` | in | 1 | 68000 A[1] — selects index vs data register |
| `MCSn` | in | 1 | Address decode (active low): asserted when 68000 at 0x100000–0x100003 |
| `MWRn` | in | 1 | 68000 R/Wn (1=read, 0=write) |
| `MRDn` | in | 1 | `~RWn` gated with chip select read cycle |
| `MREQn` | in | 1 | Z80 MREQn |
| `RDn` | in | 1 | Z80 RDn |
| `WRn` | in | 1 | Z80 WRn |
| `A[15:0]` | in | 16 | Z80 address bus |
| `Din[3:0]` | in | 4 | Z80 D[3:0] (lower nibble of Z80 data bus) |
| `Dout[3:0]` | out | 4 | Z80 data bus (lower nibble, read path) |
| `ROUTn` | out | 1 | Z80 reset output (active low) — drives Z80 RESETn pin |
| `ROMCS0n` | out | 1 | Z80 ROM CS0 — fixed bank / bank bit 2=0 |
| `ROMCS1n` | out | 1 | Z80 ROM CS1 — bank bit 2=1 (high ROM half) |
| `RAMCSn` | out | 1 | Z80 work RAM chip select — drives SRAM or BRAM at 0xE000–0xFFFF |
| `ROMA14` | out | 1 | Z80 ROM address bit 14 (bank select low bit) |
| `ROMA15` | out | 1 | Z80 ROM address bit 15 (bank select high bit) |
| `OPXn` | out | 1 | YM2610 chip select (active low) — A[15:8]==0xE0 |
| `YAOEn` | in | 1 | YM2610 ADPCM-A ROM output enable (falling edge = new address) |
| `YBOEn` | in | 1 | YM2610 ADPCM-B ROM output enable |
| `YAA[23:0]` | in | 24 | YM2610 ADPCM-A ROM address |
| `YBA[23:0]` | in | 24 | YM2610 ADPCM-B ROM address |
| `YAD[7:0]` | out | 8 | ADPCM-A ROM data → YM2610 |
| `YBD[7:0]` | out | 8 | ADPCM-B ROM data → YM2610 |
| `CSAn` | out | 1 | Leave unconnected (undriven in module — synthesizes to Z) |
| `CSBn` | out | 1 | Leave unconnected |
| `IOA[2:0]` | out | 3 | Leave unconnected |
| `IOC` | out | 1 | Leave unconnected |
| `sdr_address[26:0]` | out | 27 | SDRAM address for ADPCM ROM fetch |
| `sdr_data[15:0]` | in | 16 | SDRAM read data (16-bit word) |
| `sdr_req` | out | 1 | SDRAM request toggle |
| `sdr_ack` | in | 1 | SDRAM acknowledge toggle |

---

## 3. TC0140SYT Adaptation: SDRAM Base Address Constants

### The Problem

In the TaitoF2 source, `tc0140syt.sv` uses two package-level constants defined in `system_consts.sv`:

```systemverilog
// system_consts.sv (TaitoF2-specific)
parameter bit [31:0] ADPCMA_ROM_SDR_BASE = 32'h00B0_0000;
parameter bit [31:0] ADPCMB_ROM_SDR_BASE = 32'h00D0_0000;
```

These are referenced in the SDRAM fetch state machine at lines 269 and 274 of `tc0140syt.sv`:

```systemverilog
sdr_address <= ADPCMA_ROM_SDR_BASE[26:0] + { 3'd0, cha_addr[23:1], 1'b0 };
// ...
sdr_address <= ADPCMB_ROM_SDR_BASE[26:0] + { 3'd0, chb_addr[23:1], 1'b0 };
```

These are F2-specific SDRAM layout values. The Taito B SDRAM memory map will be different (different ROM sizes, different program ROM sizes).

### Required Change

Convert from package-scoped parameters to module parameters with F2 values as defaults:

```systemverilog
module TC0140SYT #(
    parameter bit [31:0] ADPCMA_ROM_SDR_BASE = 32'h00B0_0000,  // F2 default
    parameter bit [31:0] ADPCMB_ROM_SDR_BASE = 32'h00D0_0000   // F2 default
) (
    // ... all ports unchanged ...
);
```

The Taito B top-level then overrides at instantiation:

```systemverilog
TC0140SYT #(
    .ADPCMA_ROM_SDR_BASE(32'hXXXX_XXXX),  // Taito B SDRAM map value TBD
    .ADPCMB_ROM_SDR_BASE(32'hXXXX_XXXX)   // Taito B SDRAM map value TBD
) u_syt (
    ...
);
```

**Important:** The exact Taito B SDRAM base addresses are open questions (see §5). They depend on the complete SDRAM memory map for the Taito B top level, which must account for: 68000 program ROM, Z80 program ROM, GFX ROM, ADPCM-A ROM, ADPCM-B ROM, and sprite framebuffer.

### Minor Issues to Address at Instantiation (not requiring module changes)

| Issue | Fix |
|-------|-----|
| `nmi_enabled` tracked but NMI output port absent | For most Taito B games NMI is not needed from SYT; tie off if required |
| `CSAn, CSBn, IOA, IOC` undriven (synthesize to Z) | Leave unconnected in top-level |
| `ce_12m, ce_4m` unused | Tie to `1'b0` |

---

## 4. Address Decode

### 4.1 68000 Address Map (Nastar / Rastan Saga II — representative Taito B game)

| Address Range | Size | Chip / Resource | Notes |
|---------------|------|-----------------|-------|
| 0x000000–0x07FFFF | 512KB | 68000 Program ROM | Fixed ROM in SDRAM |
| 0x100000–0x100003 | 4B | TC0140SYT (master) | A[1] = MA1; D[4:1] = MDin/MDout |
| 0x200000–0x20FFFF | 64KB | TC0260DAR (palette RAM) | A[14:1] = MA[13:0] |
| 0x300000–0x30000F | 16B | TC0220IOC | A[4:1] = A[3:0]; D[7:0] = Din/Dout |
| 0x400000–0x47FFFF | 512KB | TC0180VCU | A[19:1] = cpu_addr[18:0] |
| 0x600000–0x60FFFF | 64KB | Work RAM (68000) | General purpose CPU RAM |

**Chip select generation (top-level logic):**
```
tc0180vcu_cs = (A[23:19] == 5'b00100)                   // 0x400000–0x47FFFF
tc0260dar_cs = (A[23:15] == 9'b000100000)                // 0x200000–0x20FFFF
tc0220ioc_csn = ~(A[23:16] == 8'h30 && A[15:4] == 12'h000)  // 0x300000–0x30000F
tc0140syt_mcsn = ~(A[23:2] == 22'h040000)               // 0x100000–0x100003
```

**DTACK handling:**
- TC0180VCU: no DTACK port — 68000 inserts wait states via bus cycle logic or DTACK is external; VRAM access is synchronous (1 clock)
- TC0260DAR: asserts `DTACKn` to stall CPU during active display when palette RAM is busy
- TC0220IOC: no DTACK — synchronous, assume 0 wait states
- TC0140SYT: no DTACK — synchronous, nibble handshake is software-polled

**68000 interrupt decode (through PAL, approximate):**
```
TC0180VCU int_h → IPL[2:0] = 3'b101  (Level 5 VBLANK)
TC0180VCU int_l → IPL[2:0] = 3'b100  (Level 4 raster)
```

### 4.2 Z80 Address Map

| Address Range | Size | Chip / Resource | Notes |
|---------------|------|-----------------|-------|
| 0x0000–0x3FFF | 16KB | Z80 ROM (fixed, bank 0) | ROMCS0n low when A[15:14]=00 |
| 0x4000–0x7FFF | 16KB | Z80 ROM (switchable bank) | ROMCS0n/ROMCS1n + ROMA14/ROMA15 from SYT |
| 0x8000–0xDFFF | 24KB | (unmapped or ROM continuation) | Verify per-game from MAME |
| 0xE000–0xE0FF | 256B | YM2610 registers | OPXn asserted (A[15:8]==0xE0) |
| 0xE200–0xE2FF | 256B | TC0140SYT slave regs | slave_access (A[15:8]==0xE2) |
| 0xE000–0xFFFF | 8KB | Z80 Work RAM | RAMCSn asserted (A[15:13]==111) |

**Note:** The YM2610 at 0xE0xx and Z80 RAM at 0xE000 overlap in the above table. Hardware resolves priority: OPXn is checked first; RAMCSn covers 0xE000–0xFFFF but YM2610 at 0xE000–0xE0FF takes priority via OPXn. The bank register write is at 0xF200 (A[15:8]==0xF2), outside both the YM and SYT windows.

### 4.3 SDRAM Memory Map (proposed — base addresses TBD)

The SDRAM layout must accommodate all ROM regions. A provisional layout for Taito B (to be finalized against actual game ROM sizes from MAME):

| Region | Size | Proposed Base | Contents |
|--------|------|---------------|----------|
| 68K Program ROM | 512KB | 0x000000 | `taito_b_68k.bin` |
| Z80 Program ROM | 32KB | 0x080000 | `taito_b_z80.bin` |
| GFX ROM | varies | 0x100000 | Tile + sprite pixels (up to 4MB for large games) |
| ADPCM-A ROM | varies | ADPCMA_ROM_SDR_BASE | YM2610 ADPCM-A samples |
| ADPCM-B ROM | varies | ADPCMB_ROM_SDR_BASE | YM2610 ADPCM-B samples |

The actual values for `ADPCMA_ROM_SDR_BASE` and `ADPCMB_ROM_SDR_BASE` depend on the GFX ROM size, which varies by game. This is a key open question (see §5).

---

## 5. Open Questions

These require MAME source consultation (`taito_b.cpp`, hardware schematics, or per-game ROM manifests) before final integration can proceed.

### Critical (blocks code)

| # | Question | Where to Look |
|---|----------|---------------|
| 1 | **Exact 68000 address map** — the Nastar map above is from MAME comments; verify base addresses for all chips across games (some games may vary). Are TC0260DAR and TC0220IOC always at 0x200000 and 0x300000? | `taito_b.cpp` memory maps for each `ADDRESS_MAP_START` block |
| 2 | **SDRAM layout for GFX ROM** — GFX ROM size varies by game (Ninja Warriors is large; Hit the Ice is small). The TC0180VCU `gfx_addr[22:0]` is a byte address within GFX ROM; the SDRAM base for GFX must be set correctly. | MAME ROM load sequences in each game driver |
| 3 | **ADPCM-A and ADPCM-B ROM sizes and SDRAM bases** — required to set TC0140SYT parameters. These change the values of `ADPCMA_ROM_SDR_BASE` and `ADPCMB_ROM_SDR_BASE`. | Per-game ROM manifests in `taito_b.cpp`; YM2610 sample ROM entries |
| 4 | **TC0180VCU `pixel_out` width** — currently 13-bit (8192 palette entries). TC0260DAR `IM` is 14-bit (16384 entries). Confirm whether Taito B uses 13 or 14 palette address bits. | MAME palette size in `tc0180vcu.cpp`; `machine().total_colors()` |
| 5 | **Interrupt decode PAL** — `int_h` and `int_l` from TC0180VCU are pulse outputs that go through a PAL to generate 68000 IPL encoding. Exact PAL equations are unknown. Do both pulses hit the same IPL level or different levels? Is there an interrupt acknowledge cycle the chip must see? | `taito_b.cpp` interrupt handler registration; possibly `machine().cpu->set_irq_callback` |

### Important (affects behavior)

| # | Question | Where to Look |
|---|----------|---------------|
| 6 | **TC0220IOC input packing** — the exact bit mapping of joystick/button inputs into `IN[31:0]` varies per game. Active-low vs active-high polarity must be confirmed. | `taito_b.cpp` port definitions (`PORT_BIT` entries) |
| 7 | **TC0180VCU DTACKn** — the tc0180vcu.sv module has no DTACK output port. The 68000 bus interface is registered (1-clock latency). Confirm whether the real hardware inserts wait states for TC0180VCU accesses, and if so, how (external logic, PAL, or built into the chip). | Timing diagrams, `taito_b.cpp` for any `waitstate_r` callbacks |
| 8 | **Z80 ROM banking detail** — the TC0140SYT bank register is at A[15:8]==0xF2 and assigns `rom_bank[2:0]`. With ROMA14/ROMA15 + ROMCS0n/ROMCS1n, this provides up to 8 × 16KB banks = 128KB. Confirm Z80 ROM sizes match this; some games may use fewer banks. | Z80 ROM load entries in `taito_b.cpp` |
| 9 | **YM2610 vs YM2151** — some Taito B games use YM2151 (no built-in ADPCM) instead of YM2610. If YM2151 is used, the SYT's YAA/YBA sample address ports go unused (or a separate ADPCM chip is present). Identify which games use which sound chip. | Sound chip declarations in each game entry in `taito_b.cpp` |
| 10 | **Framebuffer in SDRAM vs BRAM** — tc0180vcu.sv currently uses on-chip BRAM under `ifndef QUARTUS` and stubs SDRAM under `else`. For the real MiSTer core, the 256KB framebuffer needs SDRAM. The SDRAM arbitration interface and address allocation must be designed. | MiSTer SDRAM controller interface; no MAME reference needed |

### Minor / Can defer

| # | Question |
|---|----------|
| 11 | Does any Taito B game use the TC0220IOC rotary encoder inputs? (Probably not — those are F2-era trackball games.) |
| 12 | Does any Taito B game require TC0140SYT NMI output to Z80? If so, the port must be added. |
| 13 | Are `CSAn/CSBn/IOA/IOC` outputs on TC0140SYT connected to anything on the Taito B PCB, or are they always pulled high? |

---

## 6. Summary: What Is Ready vs What Is Needed

| Component | Status | Action |
|-----------|--------|--------|
| `tc0180vcu.sv` | RTL exists (partial — Gate 1-3 incomplete) | Continue implementation per section2_behavior.md order |
| `tc0260dar.sv` | DROP-IN ready | Wire up at top level |
| `tc0220ioc.sv` | DROP-IN ready | Wire up at top level |
| `tc0140syt.sv` | One change needed | Add `#(parameter ...)` block; remove package dependency |
| Top-level `taito_b.sv` | Does not exist | Create after open questions §5 items 1–5 are resolved |
| SDRAM memory map | Not defined | Resolve after game-specific ROM audit |
| Palette RAM (block RAM) | Not instantiated | Simple 8K×16 BRAM in top level |
| Z80 work RAM (block RAM) | Not instantiated | Simple 2K×8 BRAM in top level |
| Video timing generator | Not defined | Standard 320×240 arcade timing; same as F2 timing can be reused |
| YM2610 / YM2151 core | Not researched | Check jotego/jtcores for existing YM IP |
