# Taito Support Chips — Audit for Taito B MiSTer Core

Source: wickerwaka's Arcade-TaitoF2_MiSTer (GPL-2.0)
https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer

These three chips are shared across Taito B, F2, F3, and Z systems. This audit assesses each
one for drop-in reuse in a new Taito B core.

Files copied verbatim to this directory:
- tc0260dar.sv  — Palette RAM + DAC
- tc0220ioc.sv  — I/O controller
- tc0140syt.sv  — Sound interface (68000 <-> Z80)

---

## TC0260DAR — Palette RAM + DAC

### License
GPL-2.0 (repo-level LICENSE file; no per-file header in source).

### Functional Description
The TC0260DAR is the palette RAM arbitrator and color DAC. It sits between the CPU (which
writes palette entries), an external palette RAM block, and the video pipeline (which reads
palette entries during active display).

Functional behavior:
- During blanking (HBLANKn/VBLANKn asserted low), the CPU can freely write or read palette RAM
  via the CPU interface (MA, MDin/MDout, RWn, UDSn/LDSn).
- During active video, the display pipeline presents a 14-bit index (IM) and the chip muxes the
  RAM address to IM, capturing the palette entry for that pixel.
- ACCMODE=1 bypasses the busy check and always allows CPU access (used for direct-access mode).
- Three color modes are supported:
  - RGB444 (bpp15=0): bits [15:12]/[11:8]/[7:4] -> 8-bit R/G/B by duplicating the nibble.
  - RGB555 (bpp15=1, bppmix=0): bits [14:10]/[9:5]/[4:0] -> 8-bit by repeating MSBs.
  - RGB555+mix (bpp15=1, bppmix=1): same but LSB is taken from bits [3:1] instead of MSBs,
    giving slightly more color accuracy.
- Output RGB is zeroed during CPU access cycles or outside active display.
- The RAM interface is 16-bit (comment in source notes original hardware was 8-bit at 2x pixel
  clock; this implementation uses 16-bit to be compatible with TC0100PR block RAM).
- DTACKn acknowledge is generated for CPU bus cycles.
- OHBLANKn/OVBLANKn are delayed versions of the input blanking signals (3-cycle pipeline).

### Lines of Code
~95 lines total. Single always_ff block plus combinational assigns.

### Module Declaration

```systemverilog
module TC0260DAR(
    input clk,
    input ce_pixel,
    input ce_double,

    // RGB555 vs RGB444
    input bpp15,
    // LSB color in [3:1]
    input bppmix,

    // CPU Interface
    input [15:0] MDin,
    output reg [15:0] MDout,

    input        CS,
    input [13:0] MA,
    input RWn,
    input UDSn,
    input LDSn,

    output DTACKn,

    input ACCMODE,

    // Video Input
    input HBLANKn,
    input VBLANKn,

    output OHBLANKn,
    output OVBLANKn,

    input [13:0] IM,
    output reg [7:0] VIDEOR,
    output reg [7:0] VIDEOG,
    output reg [7:0] VIDEOB,

    // RAM Interface
    output [13:0] RA,
    input [15:0] RDin,
    output [15:0] RDout,
    output reg RWELn,
    output reg RWEHn
);
```

### Hardcoded Assumptions / F2-Specific Issues
None. The module is completely self-contained. All configuration comes in through ports (bpp15,
bppmix, ACCMODE). The RAM interface is abstract — the top-level instantiator wires up whatever
block RAM or SDRAM slice it wants. Color mode selection via bpp15/bppmix is orthogonal to which
Taito system is using it; Taito B simply needs to drive those ports with the correct values for
its color format.

### Reuse Verdict: DROP-IN

No changes required. Instantiate as-is and wire up the appropriate clock enables and RAM.

---

## TC0220IOC — I/O Controller

### License
GPL-2.0 (repo-level LICENSE file; no per-file header in source).

### Functional Description
The TC0220IOC is the I/O controller that interfaces the 68000 to cabinet inputs, coin
mechanisms, and rotary encoders (used in games like Midnight Landing / Top Landing).

Functional behavior:
- Register map (4-bit address bus, 8-bit data):
  - Addr 0-3: Read 32-bit IN port in 8-bit chunks (general purpose inputs: joystick, buttons,
    service, tilt, DIP switches).
  - Addr 7:   Read 8-bit INB port (second general-purpose input bank).
  - Addr 4:   Read: returns coin lock/meter state and zero-reset flags.
              Write: sets COIN_LOCK_A/B, COINMETER_A/B, and zero_a/zero_b reset flags.
  - Addr 12-15: Read rotary/paddle position (two 16-bit signed accumulators, low/high byte each).
- Rotary encoder logic:
  - rotary_abs=1: set paddle_a/b directly to signed 8-bit rotary_a/b values.
  - rotary_inc=1: accumulate signed 8-bit delta into paddle_a/b. If zero flag was just set,
    reset accumulator before adding.
  - The zero flags (written by CPU via addr 4) handle the "reset to zero" protocol that real
    hardware does differently (it drives the counter to zero while the flag is high; this
    implementation catches the edge to avoid dropping input deltas).
- RES_CLK_IN, RES_INn, RES_OUTn: reset/watchdog pins — noted as TODO in source, currently
  unimplemented (no logic for these ports).
- OEn port declared but not used in logic.

### Lines of Code
~80 lines total. Single always_ff block.

### Module Declaration

```systemverilog
module TC0220IOC(
    input clk,

    input             RES_CLK_IN,
    input             RES_INn,
    output            RES_OUTn,

    input       [3:0] A,
    input             WEn,
    input             CSn,
    input             OEn,

    input       [7:0] Din,
    output reg  [7:0] Dout,

    output reg        COIN_LOCK_A,
    output reg        COIN_LOCK_B,
    output reg        COINMETER_A,
    output reg        COINMETER_B,

    input       [7:0] INB,
    input      [31:0] IN,

    input             rotary_inc,
    input             rotary_abs,
    input       [7:0] rotary_a,
    input       [7:0] rotary_b
);
```

### Hardcoded Assumptions / F2-Specific Issues

1. Rotary encoder inputs (rotary_inc, rotary_abs, rotary_a, rotary_b): present as ports, so the
   Taito B top level just needs to tie these to 0 if no rotary is used. Not a problem.

2. RES_CLK_IN, RES_INn, RES_OUTn: watchdog/reset logic is unimplemented (TODO comment in
   source). RES_OUTn is undriven — it will synthesize to Z or 0 depending on tools. If the
   Taito B core needs a real watchdog reset, this needs to be implemented, but for initial
   bring-up tying RES_OUTn high (inactive) is fine.

3. OEn is declared but not used. Harmless.

4. IN[31:0]: the F2 core maps 4 bytes of cabinet inputs into a flat 32-bit bus. Taito B uses
   the same chip and same register map, so the input packing is identical.

These are all minor wiring issues, not logic changes.

### Reuse Verdict: DROP-IN

The register map and I/O logic are correct for Taito B. Wire rotary inputs to 0 if unused.
If a live watchdog is required, implement RES_OUTn logic, but that's an addition not a
modification.

---

## TC0140SYT — Sound Interface (68000 <-> Z80)

### License
GPL-2.0 (repo-level LICENSE file; no per-file header in source).

### Functional Description
The TC0140SYT (Sound YM Transfer) manages all communication between the main 68000 CPU and
the Z80 sound CPU, and also handles the Z80's ROM banking and ADPCM sample ROM fetches for the
YM2610 (or compatible) sound chip.

Functional behavior:

**68000 (master) side:**
- 4-bit data bus (MDin/MDout), 1-bit address (MA1), chip select/read/write (MCSn/MRDn/MWRn).
- MA1=0, MWRn=0: write master_idx register (sets the communication channel index, 0-4).
- MA1=1, MWRn=0: write to slave_data[master_idx nibble], advancing master_idx. Sets
  status_reg[0] after nibble 1, status_reg[1] after nibble 3.
- MA1=1, MRDn=0: read master_data[master_idx nibble] (data written by Z80). Clears
  status_reg[2] after nibble 1, status_reg[3] after nibble 3.
- master_idx=4 write: sets reset_reg, which holds ROUTn low (Z80 reset).
- master_idx=4 read: reads status_reg.

**Z80 (slave) side:**
- 4-bit data bus (Din/Dout), 16-bit address bus (A), standard Z80 bus (MREQn/RDn/WRn).
- Slave registers are mapped at A[15:8]==0xE2.
- A[0]=0: write slave_idx (channel index).
- A[0]=1, WRn=0: write to master_data[slave_idx nibble]. Sets status_reg[2/3].
- A[0]=1, RDn=0: read slave_data[slave_idx nibble] (data written by 68000). Clears
  status_reg[0/1].
- slave_idx=4 read: read status_reg.
- slave_idx=5/6 write: disable/enable NMI (nmi_enabled tracked but NMI output not driven —
  this is a gap, see below).
- Bank register at A[15:8]==0xF2: Z80 writes Din[2:0] -> rom_bank[2:0].

**ROM/bank decode:**
- A[15:14]==01 is the switchable bank region. ROMCS0n/ROMCS1n/ROMA14/ROMA15 select which
  physical ROM bank is active based on rom_bank.
- RAMCSn active for A[15:14:13]==111 (0xE000-0xFFFF range, Z80 work RAM).
- OPXn: YM2610 chip select at A[15:8]==0xE0.

**ADPCM sample fetch (YM2610 channels A and B):**
- The module services sample ROM reads for YM channel A (YAA address, YAOEn strobe) and
  channel B (YBA address, YBOEn strobe).
- On a falling OEn edge, if the word address changed, a 16-bit SDRAM fetch is issued via
  sdr_req/sdr_ack handshake.
- Fetched 16-bit word is returned on YAD/YBD, byte-selected by addr[0].
- SDRAM base addresses for the two sample ROM regions are taken from package-level parameters:
  ADPCMA_ROM_SDR_BASE and ADPCMB_ROM_SDR_BASE, defined in system_consts.sv as:
    ADPCMA_ROM_SDR_BASE = 32'h00B0_0000
    ADPCMB_ROM_SDR_BASE = 32'h00D0_0000
  These are the F2 SDRAM memory map values and WILL differ for Taito B.

**Undriven outputs:**
- CSAn, CSBn, IOA[2:0], IOC: declared as outputs but never assigned. Will synthesize to Z.
  These connect to external peripherals on some configurations.

### Lines of Code
~220 lines total. Two always_ff blocks (main communication logic + SDRAM fetch state machine).

### Module Declaration

```systemverilog
module TC0140SYT(
    input             clk,
    input             ce_12m,
    input             ce_4m,

    input             RESn,

    // 68000 interface
    input       [3:0] MDin,
    output reg  [3:0] MDout,

    input             MA1,

    input             MCSn,
    input             MWRn,
    input             MRDn,

    // Z80 interface
    input             MREQn,
    input             RDn,
    input             WRn,

    input      [15:0] A,
    input       [3:0] Din,
    output reg  [3:0] Dout,

    output            ROUTn,
    output            ROMCS0n,
    output            ROMCS1n,
    output            RAMCSn,
    output            ROMA14,
    output            ROMA15,

    // YM
    output            OPXn,
    input             YAOEn,
    input             YBOEn,
    input      [23:0] YAA,
    input      [23:0] YBA,
    output      [7:0] YAD,
    output      [7:0] YBD,

    // Peripheral?
    output            CSAn,
    output            CSBn,

    output      [2:0] IOA,
    output            IOC,

    // ROM interface
    output reg [26:0] sdr_address,
    input      [15:0] sdr_data,
    output reg        sdr_req,
    input             sdr_ack
);
```

### Hardcoded Assumptions / F2-Specific Issues

1. **ADPCMA_ROM_SDR_BASE / ADPCMB_ROM_SDR_BASE** (CRITICAL): These are package-level
   parameters from system_consts.sv, not module parameters. They encode the F2-specific SDRAM
   memory map positions for the two ADPCM sample ROM regions. Taito B will have a different
   SDRAM layout and different base addresses.

   Fix: Convert to module parameters:
   ```systemverilog
   module TC0140SYT #(
       parameter bit [31:0] ADPCMA_ROM_SDR_BASE = 32'h00B0_0000,
       parameter bit [31:0] ADPCMB_ROM_SDR_BASE = 32'h00D0_0000
   ) (
       ...
   );
   ```
   Then the Taito B top level overrides them at instantiation.

2. **nmi_enabled** (minor): The Z80 NMI enable/disable flag (slave_idx 5/6) is tracked in
   nmi_enabled but there is no NMI output port and no NMI generation logic. If the Taito B Z80
   sound CPU relies on NMI from this chip, an output port and edge-detect logic must be added.
   For many games this is not needed (NMI is generated by the YM timer instead).

3. **CSAn, CSBn, IOA, IOC** (minor): Undriven outputs. Add
   `assign CSAn = 1; assign CSBn = 1; assign IOA = 3'b0; assign IOC = 1'b0;` or leave
   unconnected in the Taito B top level.

4. **ce_12m, ce_4m** (informational): Declared as inputs but not used in any logic. The module
   runs purely off posedge clk with edge detection on access strobes. These can be tied to 0.

### Reuse Verdict: DROP-IN (parameterized SDRAM base addresses)

The system_consts.sv package dependency has been removed. ADPCMA_ROM_BASE and ADPCMB_ROM_BASE
are now module parameters (logic [26:0], default 27'h0). Override at instantiation with the
correct SDRAM base addresses for the target system.

Optional/minor:
- Drive the unassigned outputs (CSAn, CSBn, IOA, IOC) to safe inactive values.
- Add NMI output port if needed for target games.

---

## Summary Table

| Chip       | Lines | Verdict          | Change Required |
|------------|-------|------------------|-----------------|
| TC0260DAR  |  ~95  | DROP-IN          | None |
| TC0220IOC  |  ~80  | DROP-IN          | None (tie rotary to 0 if unused; watchdog is already a no-op) |
| TC0140SYT  | ~220  | DROP-IN (parameterized SDRAM base addresses) | None (ADPCMA/B_ROM_BASE are now module parameters; override at instantiation) |

Total RTL to audit/adapt: ~395 lines. All three chips are now drop-in. No logic changes were
required in any of the three chips; the only edit to TC0140SYT was replacing the two implicit
system_consts.sv package references with module parameters.
