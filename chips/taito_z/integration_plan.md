# Taito Z System — MiSTer Core Integration Plan

**Date:** 2026-03-17
**Status:** Pre-RTL (research complete; no RTL written yet)
**Reference:** MAME `src/mame/taito/taito_z.cpp`, `taito_z_v.cpp`, `taito_z.h`
**Primary target games:** Double Axle (dblaxle), Racing Beat (racingb)

---

## 1. System Architecture Diagram

```
                    ┌─────────────────────────────────────────────────────────────────┐
                    │                      Taito Z System                             │
                    │                                                                 │
  ┌──────────────┐  │  ┌─────────────────────────────────────────────────────────┐   │
  │  MiSTer HPS  │  │  │          CPU A — MC68000 @ 16 MHz (32 MHz / 2)          │   │
  │  (ROM loader)│  │  │  Addr[23:1]  Data[15:0]  AS/DS/RW/DTACK  IPL[2:0]      │   │
  └──────┬───────┘  │  └───────────────────┬────────────────────────────────────┘   │
         │          │                      │ CPU A bus                               │
  ┌──────┴───────┐  │     ┌────────────────┼───────┬──────────────┬──────────────┐  │
  │   SDRAM 32MB │  │     │  Address Decode│  PAL  │              │              │  │
  │              │  │     └────┬─────┬─────┴───┬───┴─────┬────────┴─────┐        │  │
  │ [CPU A ROM]  │  │          │     │         │         │              │        │  │
  │ [CPU B ROM]  │  │     ┌────┴──┐ ┌┴──────┐ ┌┴──────┐ ┌┴────────┐  ┌┴──────┐ │  │
  │ [Z80 ROM]    │  │     │TC0480 │ │ TC0510│ │ Sprite│ │TC0140SYT│  │ Work  │ │  │
  │ [SCR ROM]    │◄─┼─────┤ SCP   │ │  NIO  │ │  RAM  │ │(68K side│  │  RAM  │ │  │
  │ [OBJ ROM]    │◄─┼──   │(tilemap│ │(I/O)  │ │  +    │ │0x620000 │  │0x2000 │ │  │
  │ [ROD ROM]    │  │     │ engine)│ │0x4000 │ │ STY   │ │)        │  │ 00    │ │  │
  │ [STY ROM]    │◄─┼──   │0xa0000 │ │ 00    │ │ map   │ └────┬────┘  └───────┘ │  │
  │ [ADPCM-A]    │◄─┼──   │        │ │       │ │0xc000 │      │                  │  │
  │ [ADPCM-B]    │◄─┼──   │+ctrl at│ └───────┘ │  00   │      │Z80 reset/NMI    │  │
  └──────────────┘  │     │0xa30000│           └───────┘      │                  │  │
                    │     │        │                           │                  │  │
                    │     │pixel_  │  ┌────────────────────────┼─────────────────┐  │
                    │     │out[?]  │  │     Palette RAM (xBGR_555, 4096 entries)  │  │
                    │     │→palette│  │     0x800000–0x801FFF (dblaxle)          │  │
                    │     │ RAM    │  │     (plain RAM + MAME palette_device,    │  │
                    │     │        │  │      NOT TC0260DAR in dblaxle/racingb)   │  │
                    │     └────────┘  └────────────┬────────────────────────────┘  │
                    │                              │                                │
                    │     ┌────────────────────────┴────────────────────────────┐  │
                    │     │              TC0150ROD — Road Generator               │  │
                    │     │     (on CPU B bus, not CPU A)                        │  │
                    │     └─────────────────────────────────────────────────────┘  │
                    │                                                               │
                    │  ┌──────────────────────────────────────────────────────┐    │
                    │  │     CPU B — MC68000 @ 16 MHz (32 MHz / 2)            │    │
                    │  │  ROM: 0x000000–0x03FFFF                               │    │
                    │  │  Shared RAM (share1): 0x110000–0x11FFFF               │    │
                    │  │  TC0150ROD: 0x300000–0x301FFF                        │    │
                    │  │  Network RAM: 0x500000–0x503FFF                      │    │
                    │  └──────────────────────────────────────────────────────┘    │
                    │                                                               │
                    │  ┌──────────────────────────────────────────────────────┐    │
                    │  │     Z80 @ 4 MHz (32 MHz / 8) — Sound CPU             │    │
                    │  │     YM2610 @ 8 MHz (32 MHz / 4)                      │    │
                    │  └──────────────────────────────────────────────────────┘    │
                    └─────────────────────────────────────────────────────────────┘
```

---

## 2. Q1: CPU Setup

### CPU types

Both CPUs are **MC68000** (not 68020). All Taito Z games use 68000.

> Note: MAME driver comments mention that "The hardware for Taito's Super Chase was a further development of this, with a 68020 for main CPU and Ensoniq sound — standard features of Taito's F3 system." Super Chase / Under Fire are NOT Taito Z — they are Taito F3 (or F3-adjacent). Double Axle and Racing Beat are pure Taito Z with dual 68000.

### Clock speeds (dblaxle / racingb)

| CPU | Frequency | Derivation |
|-----|-----------|------------|
| CPU A (maincpu) | 16 MHz | `XTAL(32'000'000)/2` |
| CPU B (subcpu) | 16 MHz | `XTAL(32'000'000)/2` |
| Z80 (audiocpu) | 4 MHz | `XTAL(32'000'000)/8` |
| YM2610 | 8 MHz | `XTAL(32'000'000)/4` |

Earlier Taito Z games (contcirc, chasehq) used 12 MHz (24 MHz XTAL / 2) for both 68000s.

### CPU A → CPU B reset (the synchronization gate)

CPU A holds CPU B in reset via a write-only control register:

```
cpua_ctrl_w:  bit 0 = 0 → assert RESET on CPU B (hold in reset)
              bit 0 = 1 → clear RESET on CPU B (run)
```

dblaxle: control register at `0x600000` (CPU A address map)
racingb:  control register at `0x500002` (CPU A address map)

MAME implementation:
```cpp
void taitoz_state::parse_cpu_control()
{
    /* bit 0 enables cpu B */
    m_subcpu->set_input_line(INPUT_LINE_RESET,
        (m_cpua_ctrl & 0x1) ? CLEAR_LINE : ASSERT_LINE);
}
```

CPU B starts in reset; CPU A releases it after its own initialization.

---

## 3. Q2: Sprite Chip

**Taito Z does NOT use a dedicated sprite chip IC visible from the address map.** There is no TC0170ABT register window, no TC0370MSO register window. The sprite subsystem is purely:

1. **Sprite RAM** — written by CPU A, a plain shared RAM region
2. **STY spritemap ROM** — a lookup table ROM that maps logical sprite numbers to tile chunk sequences
3. **TC0170ABT / TC0370MSO / TC0300FLA** — hardware sprite scanners/renderers on the video PCB that DMA from sprite RAM and spritemap ROM directly, producing a scanline pixel stream

From the CPU's perspective there are only two registers:

- **Sprite RAM** (`0xC00000–0xC03FFF` in dblaxle, `0xB00000–0xB03FFF` in racingb) — plain R/W RAM, no chip-select decode complexity
- **Sprite frame toggle** (`0xC08000`/`0xB08000`, SCI/racingb only) — `sci_spriteframe_r/w`, alternates which half of spriteram is displayed (double-buffered frame; commented out in dblaxle)

### Sprite chips on PCB (passive from CPU A's view):

| Chip | Role |
|------|------|
| TC0170ABT | Motion Object Generator (CPU PCB, between CPU A and TC0140SYT) |
| TC0370MSO | Motion Objects (video PCB, next to spritemap ROM) |
| TC0300FLA | Line buffer / output stage (video PCB, next to TC0370MSO) |

These chips scan sprite RAM + spritemap ROM autonomously each scanline. The CPU just writes sprite entries and they are rendered without further CPU involvement.

### Sprite RAM entry format (dblaxle uses bshark_draw_sprites_16x8, 4 words per sprite):

```
Word +0:  [15:9] ZoomY (0–63)   [8:0] Y position (signed: >0x140 → -0x200)
Word +1:  [15]   Priority (0=above road, 1=below)
          [14:7] Color palette bank
          [5:0]  ZoomX (0–63)
Word +2:  [15]   FlipY  [14] FlipX   [8:0] X position (signed)
Word +3:  [12:0] Tile number (indexes STY spritemap ROM: entry × 32 = chunk table)

Sprite dimensions: 64×64 pixels (4 chunks wide × 8 chunks tall)
Each chunk: 16×8 pixels from OBJ GFX ROM
```

### racingb uses sci_draw_sprites_16x8 (same format, double-buffered):

Same 4-word layout. The sci_spriteframe register at `0xB08000` selects which 0x800-word half of spriteram is "current display" frame, enabling double buffering.

### FPGA strategy for sprites:

Because TC0370MSO/TC0300FLA have no documented RTL and no FPGA implementation exists anywhere, the approach is:

1. Implement the sprite scanner in RTL as a self-contained module (no chip shell needed)
2. Read sprite RAM (4K × 16-bit) each frame
3. For each sprite entry: look up 32 chunk codes from spritemap ROM, render each 16×8 tile from OBJ ROM with zoom, write to line buffer
4. Mix line buffer output with TC0480SCP output and TC0150ROD output at final priority stage

This is the standard approach for FPGA arcade cores — implement the scanner's *behavior* without trying to replicate the exact chip die.

---

## 4. Q3: Address Maps

### 4.1 Double Axle — CPU A (`dblaxle_map`)

```
0x000000–0x07FFFF   ROM (512KB, CPU A program)
0x200000–0x203FFF   Work RAM (private to CPU A, 16KB)
0x210000–0x21FFFF   Shared RAM / share1 (64KB, accessible from both CPUs)
0x400000–0x40000F   TC0510NIO (I/O, halfword_wordswap access — note: NOT TC0220IOC)
0x400010–0x40001F   Steering analog input (read only, special handler)
0x600000–0x600001   CPU A control register (write: bit 0 releases CPU B reset)
0x620001            TC0140SYT master_port_w (byte, odd address)
0x620003            TC0140SYT master_comm_r/w (byte, odd address)
0x800000–0x801FFF   Palette RAM (4KB × 16-bit, xBGR_555, 4096 colors)
0x900000–0x90FFFF   TC0480SCP RAM mirror (same as 0xA00000)
0xA00000–0xA0FFFF   TC0480SCP RAM (64KB tilemap + scroll + FG gfx data)
0xA30000–0xA3002F   TC0480SCP control registers (0x30 bytes = 24 × 16-bit words)
0xC00000–0xC03FFF   Sprite RAM (16KB, CPU A writes, TC0370MSO reads autonomously)
```

### 4.2 Double Axle — CPU B (`dblaxle_cpub_map`)

```
0x000000–0x03FFFF   ROM (256KB, CPU B program)
0x100000–0x103FFF   Work RAM (private to CPU B, 16KB)
0x110000–0x11FFFF   Shared RAM / share1 (same 64KB block as CPU A 0x210000)
0x300000–0x301FFF   TC0150ROD (road generator RAM, 8KB)
0x500000–0x503FFF   Network RAM (for linked-cabinet operation, 16KB)
```

### 4.3 Racing Beat — CPU A (`racingb_map`)

```
0x000000–0x07FFFF   ROM (512KB, CPU A program)
0x100000–0x103FFF   Work RAM (16KB)
0x110000–0x11FFFF   Shared RAM / share1 (64KB)
0x300000–0x30000F   TC0510NIO (I/O)
0x300010–0x30001F   Steering analog input
0x500002–0x500003   CPU A control register
0x520001            TC0140SYT master_port_w
0x520003            TC0140SYT master_comm_r/w
0x700000–0x701FFF   Palette RAM (4KB × 16-bit, xBGR_555, 4096 colors)
0x900000–0x90FFFF   TC0480SCP RAM (no mirror in racingb)
0x930000–0x93002F   TC0480SCP control registers
0xB00000–0xB03FFF   Sprite RAM
0xB08000–0xB08001   Sprite frame toggle (sci_spriteframe_r/w)
```

### 4.4 Racing Beat — CPU B (`racingb_cpub_map`)

```
0x000000–0x03FFFF   ROM (256KB)
0x400000–0x403FFF   Work RAM (16KB)
0x410000–0x41FFFF   Shared RAM / share1 (maps to CPU A 0x110000)
0xA00000–0xA01FFF   TC0150ROD
0xD00000–0xD03FFF   Network RAM
```

### 4.5 I/O chip variant: TC0510NIO

Both dblaxle and racingb use **TC0510NIO** (not TC0220IOC or TC0040IOC). This is the same chip as on late Taito B boards (sbm used TC0510NIO). It is already present in the pipeline as part of the Taito B effort.

Access pattern: `halfword_wordswap_r/w` — the MAME device swaps the byte order vs TC0220IOC. The RTL interface may differ from TC0220IOC; verify against `tc0510nio.cpp` when implementing.

Earlier Taito Z games used different I/O chips:
- contcirc / enforce: **TC0040IOC**
- chasehq / bshark: **TC0040IOC** (chasehq), **TC0220IOC** (bshark)

---

## 5. Q4: Interrupt Levels

### Double Axle

```
CPU A VBL → IRQ4  (set_vblank_int → irq4_line_hold, HOLD_LINE)
CPU B VBL → IRQ4  (set_vblank_int → irq4_line_hold, HOLD_LINE)
```

No secondary interrupt (no IRQ6 timer in dblaxle).

### Racing Beat

```
CPU A VBL → sci_interrupt callback:
    - Always fires IRQ4 (HOLD_LINE)
    - Every other frame: schedules IRQ6 timer (200000 - 500 CPU A cycles later)
    - IRQ6 fires: m_maincpu->set_input_line(6, HOLD_LINE)
    Comment: "Need 2 int4's per int6 else sprites vanish"

CPU B VBL → IRQ4  (irq4_line_hold, HOLD_LINE)
```

The IRQ6 in racingb drives the sprite system double-buffer swap — it needs to fire at roughly half the frame rate of IRQ4 to match sprite RAM double-buffering.

### Interrupt table across all Taito Z games:

| Game | CPU A VBL | CPU A extra | CPU B VBL |
|------|-----------|-------------|-----------|
| contcirc / enforce | IRQ6 | — | IRQ6 |
| chasehq / nightstr | IRQ4 | — | IRQ4 |
| bshark | IRQ4 | IRQ6 via ADC EOC | IRQ4 |
| sci | IRQ4 | IRQ6 (timer, every other VBL) | IRQ4 |
| aquajack | IRQ4 | — | IRQ4 |
| spacegun | IRQ4 | — | IRQ4 |
| dblaxle | IRQ4 | — | IRQ4 |
| racingb | IRQ4 | IRQ6 (timer, every other VBL) | IRQ4 |

**Conclusion:** For dblaxle FPGA target, both CPUs get a single IRQ4 at VBL. For racingb, CPU A gets IRQ4 at every VBL plus IRQ6 fired at 200000-cycle offset on alternating frames.

---

## 6. Q5: Dual-CPU Synchronization

### Primary mechanism: shared RAM

The two CPUs communicate exclusively through shared RAM ("share1"). There is no hardware semaphore register, no spinlock chip, and no mailbox hardware — it is all pure software protocol over shared DRAM.

| Game | CPU A shared address | CPU B shared address | Size |
|------|---------------------|---------------------|------|
| dblaxle | 0x210000–0x21FFFF | 0x110000–0x11FFFF | 64KB |
| racingb | 0x110000–0x11FFFF | 0x410000–0x41FFFF | 64KB |
| contcirc | 0x084000–0x087FFF | 0x084000–0x087FFF | 16KB |
| chasehq | 0x108000–0x10BFFF | 0x108000–0x10BFFF | 16KB |
| bshark | 0x110000–0x113FFF | 0x110000–0x113FFF | 16KB |

The MAME source comment explicitly notes: "Typically they share $4000 bytes, but Spacegun / Dbleaxle share $10000."

### CPU B reset gate

CPU A releases CPU B from reset via the `cpua_ctrl_w` register (bit 0). This is the only hardware gate — there are no other inter-CPU hardware signals.

### Quantum (interleave requirement)

| Game | MAME quantum | Interpretation |
|------|-------------|----------------|
| contcirc | 600 Hz | Very coarse (1x real-time at 60 fps) |
| chasehq / bshark | 6000 Hz | 100x per frame |
| sci | 3000 Hz | ~50x per frame |
| nightstr | 6000 Hz | — |
| aquajack | 30000 Hz | Very tight |
| dblaxle | `32MHz/1024 ≈ 31250 Hz` | **Tight — "fixes road layer stuck on continue"** |
| racingb | 600 Hz | Same as contcirc — surprisingly coarse |

**dblaxle requires tight interleaving** — the comment says 32MHz/1024 prevents road layer synchronization failure. In FPGA this translates to: the two 68000 cores must be time-sliced at sub-scanline granularity, not just once per frame.

### FPGA dual-CPU sync RTL sketch

The simplest correct approach for FPGA:

```
// Both CPUs share the same clock domain (clk_sys).
// CPU B is gated by the reset signal from CPU A's control register.
// Shared RAM is a single true dual-port BRAM with independent ports for each CPU.
// No additional arbitration needed (each CPU has its own port; simultaneous
//   access to the same address is a software race condition, same as real hardware).

module taito_z_cpu_sync (
    input  logic        clk_sys,
    input  logic        reset_n,

    // CPU A control register (from cpua_ctrl_w)
    input  logic        cpua_ctrl_bit0,   // 1 = run CPU B, 0 = reset CPU B

    // CPU B reset output
    output logic        cpub_reset_n,     // active-low reset to CPU B core

    // Shared RAM — True dual-port BRAM
    // Port A (CPU A)
    input  logic [15:0] shared_addr_a,    // word address within 64KB = 15-bit
    input  logic [15:0] shared_wdata_a,
    output logic [15:0] shared_rdata_a,
    input  logic        shared_we_a,
    input  logic  [1:0] shared_be_a,      // byte enables

    // Port B (CPU B)
    input  logic [15:0] shared_addr_b,
    input  logic [15:0] shared_wdata_b,
    output logic [15:0] shared_rdata_b,
    input  logic        shared_we_b,
    input  logic  [1:0] shared_be_b
);

    // CPU B reset: CPU A holds bit 0 = 0 until it's ready to run CPU B
    assign cpub_reset_n = reset_n && cpua_ctrl_bit0;

    // Shared RAM: 32K × 16-bit true dual-port BRAM (64KB)
    logic [15:0] shared_ram [0:32767];

    always_ff @(posedge clk_sys) begin
        if (shared_we_a) begin
            if (shared_be_a[1]) shared_ram[shared_addr_a][15:8] <= shared_wdata_a[15:8];
            if (shared_be_a[0]) shared_ram[shared_addr_a][ 7:0] <= shared_wdata_a[ 7:0];
        end
        shared_rdata_a <= shared_ram[shared_addr_a];
    end

    always_ff @(posedge clk_sys) begin
        if (shared_we_b) begin
            if (shared_be_b[1]) shared_ram[shared_addr_b][15:8] <= shared_wdata_b[15:8];
            if (shared_be_b[0]) shared_ram[shared_addr_b][ 7:0] <= shared_wdata_b[ 7:0];
        end
        shared_rdata_b <= shared_ram[shared_addr_b];
    end

endmodule
```

**Key insight for FPGA timing:** The dblaxle quantum of 32MHz/1024 means MAME interleaves the CPUs every 31.25 µs. At a 32 MHz system clock that is ~1000 clock cycles per interleave slice. In FPGA, running both CPUs from the same clock with cycle-accurate bus arbitration naturally provides sub-cycle interleaving — no special handling needed. The road-layer issue MAME workarounds for is a simulation artifact, not a real hardware problem.

---

## 7. Q6: ROM Layout

### 7.1 Double Axle ROM regions

| Region name (MAME) | Contents | Size | Notes |
|-------------------|----------|------|-------|
| `maincpu` | CPU A 68000 program | 0x80000 (512KB) | 4× 128KB ROMs, interleaved byte |
| `sub` | CPU B 68000 program | 0x40000 (256KB) | 2× 128KB ROMs, interleaved byte |
| `audiocpu` | Z80 program | 0x20000 (128KB) | 1× ROM, banked by TC0140SYT |
| `tc0480scp` | BG tilemap GFX (SCR) | 0x100000 (1MB) | 2× 512KB ROMs, 32-bit interleave (ROM_LOAD32_WORD) |
| `sprites` | OBJ sprite GFX | 0x400000 (4MB) | 4× 1MB ROMs, 64-bit interleave (ROM_LOAD64_WORD_SWAP) |
| `tc0150rod` | Road line data | 0x80000 (512KB) | 1× ROM, 16-bit words (ROM_LOAD16_WORD) |
| `spritemap` | STY spritemap lookup | 0x80000 (512KB) | 1× ROM, 16-bit words |
| `ymsnd:adpcma` | ADPCM-A samples | 0x180000 (1.5MB) | 2 ROMs: 1MB + 512KB |
| `ymsnd:adpcmb` | ADPCM-B samples | 0x80000 (512KB) | 1× ROM |
| `user2` | Priority PROMs (unused) | 0x10000 + PROMs | 2× 256-byte priority PROMs; 2× 1KB PROMs |

**Total ROM budget: ~8.7 MB** (fits in 16MB SDRAM with room for RAM).

### 7.2 Racing Beat ROM regions (identical structure to Double Axle)

| Region | Size | Notes |
|--------|------|-------|
| `maincpu` | 0x80000 (512KB) | |
| `sub` | 0x40000 (256KB) | |
| `audiocpu` | 0x20000 (128KB) | |
| `tc0480scp` | 0x100000 (1MB) | Same format as dblaxle |
| `sprites` | 0x400000 (4MB) | Same format |
| `tc0150rod` | 0x80000 (512KB) | |
| `spritemap` | 0x80000 (512KB) | |
| `ymsnd:adpcma` | 0x180000 (1.5MB) | |
| `ymsnd:adpcmb` | 0x80000 (512KB) | |

### 7.3 Comparison with earlier Taito Z games

| Game | Tilemap chip | Tilemap GFX | Sprite GFX | Total approx |
|------|-------------|-------------|------------|-------------|
| contcirc | TC0100SCN | 0x80000 (512KB) | 0x200000 (2MB) | ~4MB |
| chasehq | TC0100SCN | 0x80000 (512KB) | 2×0x200000 (4MB) | ~8MB |
| bshark | TC0100SCN | 0x80000 (512KB) | 0x200000 (2MB) | ~4MB |
| dblaxle | **TC0480SCP** | 0x100000 (1MB) | 0x400000 (4MB) | ~8.7MB |
| racingb | **TC0480SCP** | 0x100000 (1MB) | 0x400000 (4MB) | ~8.7MB |

### 7.4 Proposed SDRAM layout (dblaxle target)

```
SDRAM offset    Size     Region
──────────────────────────────────────────────────────────────
0x000000        512KB    CPU A program ROM (maincpu)
0x080000        256KB    CPU B program ROM (sub)
0x0C0000        128KB    Z80 audio program (audiocpu)
0x0E0000        128KB    (pad to 1MB boundary)
0x100000        1MB      TC0480SCP SCR GFX ROM (tc0480scp)
0x200000        4MB      Sprite OBJ GFX ROM (sprites)
0x600000        512KB    TC0150ROD road data
0x680000        512KB    STY spritemap ROM
0x700000        1.5MB    ADPCM-A samples (ymsnd:adpcma)
0x880000        512KB    ADPCM-B samples (ymsnd:adpcmb)
──────────────────────────────────────────────────────────────
Total:          ~9MB  (fits in 16MB SDRAM)
```

### 7.5 GFX ROM interleave formats

**TC0480SCP SCR ROMs (16×16 tilemap tiles):**
```
ROM_LOAD32_WORD( "c78-10.12", 0x00000, 0x80000, ... )  // lower 16 bits of 32-bit word
ROM_LOAD32_WORD( "c78-11.11", 0x00002, 0x80000, ... )  // upper 16 bits of 32-bit word
→ Two 512KB ROMs, byte-interleaved to form 32-bit wide × 256K word ROM
→ Matches TC0480SCP's 32-bit tile fetch bus (RD0–RD31)
```

**OBJ sprite ROMs (16×8 sprite tiles):**
```
ROM_LOAD64_WORD_SWAP( "c78-08.25", 0x000000, 0x100000 )  // bits [15:0]
ROM_LOAD64_WORD_SWAP( "c78-07.33", 0x000002, 0x100000 )  // bits [31:16]
ROM_LOAD64_WORD_SWAP( "c78-06.23", 0x000004, 0x100000 )  // bits [47:32]
ROM_LOAD64_WORD_SWAP( "c78-05.31", 0x000006, 0x100000 )  // bits [63:48]
→ Four 1MB ROMs forming a 64-bit wide sprite ROM
```

---

## 8. TC0480SCP Wiring (Port-by-Port)

The TC0480SCP is already RTL-complete in this pipeline. Wiring for Taito Z differs from Taito F3 primarily in the CPU address mapping and the absence of TC0260DAR.

### 8.1 CPU interface

| TC0480SCP signal | Taito Z connection | Notes |
|-----------------|-------------------|-------|
| VA[16:1] | cpu_addr[16:1] | 16-bit word address within 64KB RAM window |
| VD[15:0] | cpu_data[15:0] | CPU data bus |
| /VCS (RAM) | `cpu_addr[23:16] == 8'hA0 && !cpu_as_n` | dblaxle: 0xA00000–0xA0FFFF |
| /VCS (CTRL) | `cpu_addr[23:8] == 16'hA300 && !cpu_as_n` | dblaxle: 0xA30000–0xA3002F |
| R/W | cpu_rw | 1=read, 0=write |
| UDS/LDS | cpu_uds_n, cpu_lds_n | byte enables |
| DTACK | → cpu_dtack_n | can be 1-cycle fast DTACK (no VBL stall needed) |

Mirror at 0x900000 in dblaxle: decode both ranges to same chip select. In racingb, no mirror — only 0x900000.

### 8.2 Tile ROM interface

| TC0480SCP signal | FPGA connection | Notes |
|-----------------|----------------|-------|
| CH[20:0] | sdram_scr_addr[20:0] | 21-bit byte address into SCR GFX region |
| RD[31:0] | sdram_scr_data[31:0] | 32-bit tile data (one full tile pixel row) |
| /CHRD | sdram_scr_req | Request pulse → toggle-req SDRAM bridge |

The chip fetches 32 bits at a time. SDRAM is 16-bit wide, so each TC0480SCP fetch requires 2 consecutive SDRAM reads. The SDRAM arbiter returns a 32-bit word composed from the two reads.

### 8.3 Pixel output → palette

Unlike Taito B which uses TC0260DAR:
- Taito Z (dblaxle/racingb) uses **plain palette RAM** (not TC0260DAR)
- Palette format: `xBGR_555` (16-bit, 1 unused + 5B + 5G + 5R, per MAME `palette_device::xBGR_555`)
- 4096 palette entries × 16-bit = 8KB palette RAM at 0x800000

TC0480SCP pixel output (palette index) feeds directly into a palette RAM lookup:

```
pixel_index → palette_ram[pixel_index] → {R,G,B} output
```

No TC0260DAR intermediate DAC needed. The RTL palette lookup is a simple synchronous ROM/RAM read.

**Pixel index width:** TC0480SCP output is at minimum 12 bits (4096 palette entries). Verify exact width from `chips/tc0480scp/` RTL — likely 12 or 13 bits, same as TC0180VCU's 12-bit effective range.

### 8.4 Video timing

TC0480SCP requires standard arcade sync signals:
- HSYNC, HBLANK, VSYNC, VBLANK (same as TC0180VCU / Taito B)
- Screen dimensions from MAME: `screen_config(config, 16, 256)` → `vdisp_start=16, vdisp_end=256`
- This means active display rows 16–255 (240 lines), same as Taito B

---

## 9. Palette Architecture (dblaxle/racingb — no TC0260DAR)

**Key difference from Taito B:** Taito B used TC0260DAR as a palette DAC chip. Taito Z (dblaxle, racingb) does NOT use TC0260DAR — palette RAM is directly mapped to the 68000 address space as plain write16 RAM, and the MAME `palette_device` handles the color lookup natively.

Evidence from PCB notes:
- Racing Beat VIDEO PCB shows `TC0260DAR` present (visible in PCB diagram at upper right)
- dblaxle MAME driver uses `palette_device::write16` with `xBGR_555` format
- There is NO `TC0260DAR` device instantiation in dblaxle or racingb machine_config

**Interpretation:** The TC0260DAR is present as a physical chip on the PCB but MAME does not emulate it as a separate device — it simply exposes its palette RAM directly. The chip acts as a transparent palette DAC: CPU writes xBGR_555 values to its internal RAM (which appears directly in the 68000 address map), and the chip outputs R/G/B video. There is no busy/stall mechanism like in Taito B's TC0260DAR implementation.

**FPGA implementation:**
```
// Simple xBGR_555 palette lookup — no TC0260DAR device needed
logic [15:0] palette_ram [0:4095];

// CPU write path (from CPU A bus, 0x800000–0x801FFF)
always_ff @(posedge clk_sys) begin
    if (pal_cs && !cpu_rw) begin
        if (!cpu_uds_n) palette_ram[cpu_addr[12:1]][15:8] <= cpu_din[15:8];
        if (!cpu_lds_n) palette_ram[cpu_addr[12:1]][ 7:0] <= cpu_din[ 7:0];
    end
end

// Pixel lookup path (registered, 1-cycle latency)
always_ff @(posedge clk_sys) begin
    if (pix_valid) begin
        logic [15:0] color = palette_ram[pix_index[11:0]];
        // xBGR_555: [14:10]=R, [9:5]=G, [4:0]=B, [15]=unused
        video_r <= {color[14:10], color[14:12]};  // 5→8 bit expand
        video_g <= {color[ 9: 5], color[ 9: 7]};
        video_b <= {color[ 4: 0], color[ 4: 2]};
    end
end
```

The TC0260DAR.sv from Taito B can be reused IF the ACCMODE=1 path is used (which disables the busy/stall logic). However, it is simpler to bypass it entirely for Taito Z.

---

## 10. TC0150ROD — Road Generator

The TC0150ROD is a dedicated road-rendering chip. It is on **CPU B's bus** (not CPU A's), which is architecturally significant:

- CPU B handles all road state writes to TC0150ROD
- CPU A does NOT have TC0150ROD in its address map
- The road layer is composited into the final output at priority level between the BG layers and sprites

From screen_update_dblaxle:
```cpp
m_tc0150rod->draw(bitmap, cliprect, -1, 0xc0, 0, 0, screen.priority(), 1, 2);
```
Priority value `1` and blend `2` — road draws over BG layers 0–2 (priority bits 0 and 1), under sprites (priority bit 2) and BG layer 3.

The TC0150ROD chip is not yet implemented in this pipeline. It needs its own RTL module. Key facts:
- 8KB RAM at CPU B 0x300000–0x301FFF (dblaxle) / 0xA00000–0xA01FFF (racingb)
- Receives road line data from a ROM (512KB `tc0150rod` region)
- Generates a scanline road strip with perspective scaling
- Outputs a 1D scanline buffer consumed by the final priority mixer

---

## 11. Priority Mixing

Taito Z does NOT use TC0360PRI. Priority is handled through a combination of:

1. **TC0480SCP internal priority** — the `layer[0..4]` order from `get_bg_priority()` determines BG layer draw order
2. **MAME priority bitmap system** — sprites and road use `prio_zoom_transpen` with `primasks[priority]` (0xf0 = above road, 0xfc = below road)
3. **Two priority PROMs** on PCB:
   - `c78-15`: road A/B internal priority (256 bytes)
   - `c78-21`: road/sprite priority and palette select (256 bytes)

The PROMs are listed as `user2` "unused ROMs" in MAME — meaning MAME implements the priority logic in software rather than reading the PROMs. For FPGA, the same software priority logic can be implemented in RTL:

```
Priority layers (bottom to top, typical dblaxle):
  BG0 (tilemap layer 0 from TC0480SCP)
  BG1 (tilemap layer 1)
  TC0150ROD road (between BG2 and sprites)
  Sprites (priority=0: above road; priority=1: below road via primasks)
  BG3 (tilemap layer 3, used for big numeric displays)
  FG/Text (always top)
```

The actual layer order is programmable via TC0480SCP LAYER_CTRL register — see `chips/tc0480scp/section1_registers.md` §3.2 for the full priority lookup table.

---

## 12. Sound Architecture

### Sound chip: YM2610 (same as Taito B)

Both dblaxle and racingb use YM2610 @ 8 MHz. Sound comms via TC0140SYT (same chip as Taito B).

**Difference from Taito B:** In Taito B, the Z80 drives YM2610. In dblaxle:

```
CPU A → TC0140SYT (at 0x620000) → Z80 → YM2610
```

The TC0140SYT.sv is parameterized with `ADPCMA_ROM_BASE` / `ADPCMB_ROM_BASE` — drop-in reuse. Wire ADPCM-A and ADPCM-B ROM to SDRAM at the layout offsets from §7.4.

**bshark note** (historical, not the FPGA target): bshark has no Z80 and no TC0140SYT. CPU B writes directly to YM2610. TC0400YSC is mentioned in PCB notes as a substitute when 68K writes directly to YM2610. This is only relevant if bshark is ever targeted.

---

## 13. Chip Reuse vs New Work Summary

| Component | Status | Source |
|-----------|--------|--------|
| TC0480SCP | RTL complete | `chips/tc0480scp/` |
| TC0260DAR | Not needed for dblaxle/racingb | Present in `chips/taito_support/` for other games |
| TC0220IOC | Not needed for dblaxle/racingb | Present in `chips/taito_support/` (dblaxle uses TC0510NIO) |
| TC0140SYT | Drop-in reuse | `chips/taito_support/tc0140syt.sv` |
| TC0510NIO | Need to verify RTL vs TC0220IOC | Used in late Taito B (sbm) — may already exist |
| Palette lookup | Trivial new RTL (10 lines) | No chip, just palette_device behavior |
| Sprite scanner | **New RTL required** | TC0370MSO/TC0300FLA behavior in RTL |
| Spritemap ROM | Plain SDRAM region | No chip, just ROM fetch |
| TC0150ROD | **New RTL required** | Not yet implemented |
| Shared RAM (64KB) | Trivial new RTL (dual-port BRAM) | No chip wrapper needed |
| CPU B reset gate | Trivial (1 flip-flop) | Part of cpua_ctrl register |
| YM2610 | External core | Use existing MiSTer YM2610 core |
| Dual 68000 | Two instances | Use existing MiSTer 68000 core ×2 |

---

## 14. Open Questions

1. **TC0510NIO vs TC0220IOC:** Does the existing TC0510NIO implementation (if any) match the `halfword_wordswap_r/w` access pattern? The `wordswap` in the MAME function name implies byte order is swapped relative to TC0220IOC. Verify `src/mame/taito/taitoio.cpp` before wiring.

2. **TC0480SCP pixel index width:** Confirm the output bus width from the TC0480SCP RTL. The Taito B system uses TC0180VCU with a 13-bit pixel_out; TC0480SCP likely outputs 12–13 bits. The 4096-entry palette (12-bit) with xBGR_555 suggests 12-bit is sufficient.

3. **TC0150ROD interface:** The road chip needs its own research pass. Questions: What is the RAM write format? What does the scanline output look like — palette index? RGB directly? What are the priority bits? The MAME device `tc0150rod.cpp` is the source.

4. **Sprite line buffer architecture:** The TC0370MSO renders sprites into a line buffer autonomously. For FPGA, this needs to be a scanline-parallel process. Key question: does the hardware use one or two line buffers (ping-pong)? The sci_spriteframe double-buffer mechanism in SCI/racingb suggests at minimum two sprite RAM frames, but the line buffer itself may still be single (one buffer per active scanline, alternating).

5. **Priority PROM contents:** The 256-byte PROMs (`c78-15`, `c78-21`) are marked "unused" in MAME. If the real hardware reads them for priority decisions, the FPGA must replicate their contents. Extract the actual PROM data from the ROM files and verify whether any game behavior differs from MAME's soft priority implementation.

6. **TC0480SCP double-width mode:** dblaxle uses double-width tilemaps (64×32 BG tiles). Verify the TC0480SCP RTL correctly implements the double-width RAM layout from `chips/tc0480scp/section1_registers.md` §2 before connecting.

7. **Network RAM (0x500000 in dblaxle, 0xD00000 in racingb):** The "Version Without Communication" ROMs are used in MAME. The network RAM exists but is inert unless two cabinets are linked. For single-cabinet FPGA: map to plain RAM, no external interface needed.

8. **Clock domain for dual 68000:** Both CPUs run at 16 MHz from the same 32 MHz source. In the FPGA, if the system clock is 48 MHz (standard MiSTer), a 3x clock enable (CE) will give 16 MHz effective for each CPU. Alternatively, 32 MHz CE from a 64 MHz system clock. The two 68000s can share the same clock with alternating CEs for tighter interleave, or run independently with shared-RAM as the synchronization boundary.

---

## 15. Implementation Sequence

Recommended build order for dblaxle as first target:

1. **TC0480SCP wiring** — already RTL-complete; connect to dblaxle CPU A address map, SCR ROM SDRAM bridge, and palette RAM lookup (replacing TC0260DAR)
2. **Palette RAM** — trivial 8KB block RAM + xBGR_555 expansion
3. **Dual 68000 + shared RAM** — two CPU instances, 64KB dual-port shared RAM, CPU B reset gate
4. **TC0140SYT + Z80 + YM2610** — direct reuse from Taito B, new address map parameters
5. **TC0510NIO** — verify or implement halfword_wordswap I/O
6. **TC0150ROD** — new chip research + RTL (required for road layer)
7. **Sprite scanner RTL** — new implementation (TC0370MSO behavior)
8. **Priority mixer** — final compositing: BG0→BG1→road→sprites→BG3→text
9. **TAS validation** — build emu-dump + tas_validate framework before debugging anything visually

The TC0480SCP work (step 1) can begin immediately. Steps 6–7 are the longest poles.
