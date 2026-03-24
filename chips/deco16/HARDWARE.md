# DECO 16-bit Arcade — Hardware Profile

*Generated from MAME `dataeast/dec0.cpp`, `dataeast/cninja.cpp`, PCB documentation by Guru,
and MAME device sources `decbac06.cpp`, `decmxc06.cpp`, `deco16ic.cpp` — 2026-03-22*

**See also:** `chips/deco16_arcade/HARDWARE.md` for deep-dive on the earlier dec0 family (1987–1990).

---

## System Overview

Data East's 16-bit arcade platform spans two overlapping hardware generations:

| Family | Years | MAME driver | Key Custom Chips | Notable Games |
|--------|-------|-------------|-----------------|---------------|
| **dec0** | 1987–1990 | `dataeast/dec0.cpp` | BAC06 + MXC06 | Heavy Barrel, Bad Dudes, RoboCop, Sly Spy, Midnight Resistance |
| **dec1 / cninja** | 1990–1994 | `dataeast/cninja.cpp` | DECO16IC (chip 45/56/74) | Caveman Ninja, Midnight Resistance (rev), Funky Jet, Nitro Ball |

Both families share the same Motorola 68000 main CPU, similar memory maps, and the same
sound subsystem (YM2203 + YM3812 + OKI M6295). The key evolution from dec0 to dec1/cninja
is the replacement of separate BAC06 tile generators with the unified **DECO16IC** multi-plane
graphics ASIC.

---

## Games Table (10 Key Titles)

| MAME Romset | Title | Year | Family | Audio CPU | MCU/Protection | Notes |
|-------------|-------|------|--------|-----------|----------------|-------|
| `hbarrel` | Heavy Barrel | 1987 | dec0 | M6502 | i8751 | 12-way rotary joystick |
| `baddudes` | Bad Dudes vs. DragonNinja | 1988 | dec0 | M6502 | i8751 | US/JP versions |
| `robocop` | RoboCop | 1988 | dec0 | HuC6280 | HuC6280 sub-CPU + MB8421 | Dual-port shared RAM |
| `hippodrm` | Hippodrome (Fighting Fantasy) | 1989 | dec0 | HuC6280 | HuC6280 sub-CPU | |
| `secretag` | Sly Spy (Secret Agent) | 1989 | dec0 | HuC6280 | 4-state map protection | Memory map state machine |
| `midres` | Midnight Resistance | 1989 | dec0 | HuC6280 | none | 12-way rotary joystick |
| `cninja` | Caveman Ninja | 1991 | cninja | HuC6280 | DECO56 (chip 56) | DECO16IC video, 4 layers |
| `nitrobal` | Nitro Ball (Gun Ball) | 1992 | cninja | HuC6280 | none | Isometric ball game |
| `fghthist` | Fighter's History | 1993 | cninja | HuC6280 | DECO146 | 6-button fighter |
| `funkyjet` | Funky Jet | 1992 | cninja | HuC6280 | DECO56 | Platform shooter |

**Vigilante (1988)** is an Irem game (M72 hardware), NOT a Data East game — not covered here.
**Atomic Point (1990)** appears to be a puzzle game on different hardware — verify before targeting.

---

## CPU Architecture

### Main CPU — All Games

| CPU | Clock | Crystal | Notes |
|-----|-------|---------|-------|
| Motorola MC68000 | 10 MHz | 20 MHz XTAL / 2 | dec0 family |
| Motorola MC68000 | 12 MHz | 24 MHz XTAL / 2 | cninja family (some games) |

**MiSTer:** Use **fx68k** (JTFPGA fork at `chips/m68000/hdl/fx68k/`).
See `chips/COMMUNITY_PATTERNS.md` Section 1 for mandatory integration:
enPhi1/enPhi2 from C++ testbench, IACK-based IPL clear, VPAn autovector.

### Audio CPU

| CPU | Tag | Clock | Games | Notes |
|-----|-----|-------|-------|-------|
| MOS/Rockwell M6502 (RP65C02A) | `audiocpu` | 1.5 MHz (12 MHz / 8) | hbarrel, baddudes, birdtry, bandit | Early dec0 only |
| Hudson HuC6280 (disguised as `DEC-01`/chip 45) | `audiocpu` | ~6 MHz XIN | robocop, hippodrm, slyspy, midres, cninja, funkyjet, nitrobal, fghthist | All cninja games |

**HuC6280 clock details (PCB-verified):**
- Robocop/Hippodrome: 21.4772 MHz / 16 ≈ 1.342 MHz internal (6 MHz effective on XIN pin 10)
- Sly Spy: 12 MHz / 2 / 2 = 3 MHz XIN (6 MHz effective)
- Midnight Resistance: 24 MHz / 4 / 3 ≈ 2 MHz XIN (6 MHz effective)
- cninja family: 32 MHz / ~5.3 = 6 MHz (varies per game)

### Sub-CPU (RoboCop and Hippodrome only)

| CPU | Tag | Clock | Role |
|-----|-----|-------|------|
| HuC6280 (DEC-01/chip 45) | `subcpu` | ~1.342 MHz | Game logic; communicates via MB8421 dual-port RAM |

---

## Memory Map

### dec0 Standard Map — Heavy Barrel, Bad Dudes, RoboCop, Hippodrome, Bandit

```
0x000000–0x05FFFF   Program ROM (384 KB)
0x240000–0x24FFFF   BAC06[0..2] tile generator control + scroll RAM + tile data RAM
0x30C000–0x30C00B   Controls read (INPUTS, SYSTEM, DSW, i8751)
0x30C010–0x30C01F   Control write (priority, sprite DMA, sound latch, MCU, IRQ ack)
0x310000–0x3107FF   Palette RAM (1024 × 16-bit entries)
0x314000–0x3147FF   Palette RAM extended
0x318000–0x31BFFF   Main RAM (16 KB)
0x31C000–0x31C7FF   Sprite RAM write buffer (MXC06)
0xFFC000–0xFFC7FF   Sprite RAM mirror
```

**RoboCop additions:**
```
0x180000–0x180FFF   MB8421 dual-port RAM (shared with HuC6280 sub-CPU)
```

### dec0 Sly Spy / Secret Agent — 4-State Protection

```
0x000000–0x05FFFF   ROM
0x240000–0x24FFFF   Tilegen area (4 views, software-remapped by protection state machine)
0x304000–0x307FFF   Main RAM (16 KB)
0x308000–0x3087FF   Sprite RAM
0x310000–0x3107FF   Palette RAM
```

### dec0 Midnight Resistance

```
0x000000–0x07FFFF   Program ROM (512 KB)
0x100000–0x103FFF   Main RAM (16 KB)
0x120000–0x1207FF   Sprite RAM
0x140000–0x1407FF   Palette RAM
0x200000–0x3407FF   BAC06[0..2] distributed across three 0x20000 windows
0x180000–0x18000F   Controls read (includes rotary encoder inputs)
```

### cninja / DECO16IC Map — Caveman Ninja, Funky Jet, Nitro Ball

```
0x000000–0x07FFFF   Program ROM (512 KB)
0x100000–0x103FFF   Main RAM (16 KB)
0x104000–0x104FFF   Sprite RAM (DECO16IC sprites)
0x120000–0x1207FF   Palette RAM
0x148000–0x148FFF   DECO16IC chip[0] control registers
0x14A000–0x14AFFF   DECO16IC chip[1] control registers
0x14C000–0x14C7FF   DECO16IC pf1 tile RAM (chip 0)
0x14E000–0x14E7FF   DECO16IC pf2 tile RAM (chip 0)
0x150000–0x1507FF   DECO16IC pf3 tile RAM (chip 1)
0x152000–0x1527FF   DECO16IC pf4 tile RAM (chip 1)
0x160000–0x163FFF   Text/FG tile RAM (fixed BAC06-style)
0x170000            Sound latch write
0x180000–0x18000F   Controls read (INPUTS, SYSTEM, DSW)
0x190000            Priority register / control
```

---

## Video Hardware

### dec0 Family Custom Chips

#### BAC06 (L7B0072) — Tile Generator

- **MAME device:** `deco_bac06_device` (`video/decbac06.cpp`)
- **Instances per board:** 3 (tilegen[0]=text/FG, tilegen[1]=BG near, tilegen[2]=BG far)
- **Tile sizes:** 8×8 or 16×16, software-selectable per plane
- **Color depth:** 4 bpp, 16 colors/tile, 1024-color palette
- **Features:** Global X/Y scroll, per-row row-scroll, per-column column-scroll, flip-screen
- **Tile RAM size:** 0x800–0x2000 bytes per instance depending on map size
- **MiSTer status:** NEED (no community FPGA implementation found)

**BAC06 control registers (per instance):**
```
control_0[0] = tile size / mode select (bit1: 16x16, bit7: wide 16x16 mode)
control_0[1] = color bank
control_0[2] = X scroll (global)
control_0[3] = playfield dimensions
control_1[0] = X scroll fine
control_1[1] = Y scroll fine
control_1[2] = row/column scroll enables
control_1[3] = row/column scroll mode select
```

#### MXC06 (L7B0073) — Sprite Generator

- **MAME device:** `deco_mxc06_device` (`video/decmxc06.cpp`)
- **Instances:** 1 per board
- **Sprite RAM:** 0x800 bytes = 256 sprites × 8 bytes (double-buffered)
- **DMA trigger:** Write to control register offset +2 copies write buffer to active buffer
- **Features:** Per-sprite priority, horizontal/vertical flip, zoom
- **MiSTer status:** NEED (no community FPGA implementation found)

**Sprite attribute format (8 bytes = 4 words per sprite):**
```
Word 0: [15:8]=Y position,  [7:0]=sprite number high
Word 1: [15:8]=X position,  [7:0]=sprite number low
Word 2: [15:8]=color/priority, [7:0]=size/flip
Word 3: [15:8]=reserved,   [7:0]=zoom factor
```

### cninja Family — DECO16IC Unified Graphics

The cninja family replaces three separate BAC06 chips with one unified **DECO16IC** ASIC
that handles two pairs of background planes (chip 0 = pf1+pf2, chip 1 = pf3+pf4) plus sprites.

#### DECO16IC (chip 45 / chip 56 / chip 74) — Unified BG+Sprite Engine

- **MAME device:** `deco16ic_device` (`video/deco16ic.cpp`)
- **Instances:** 2 per board (chip[0] and chip[1]), each managing 2 BG planes
- **Total BG layers:** 4 (pf1, pf2 from chip[0]; pf3, pf4 from chip[1])
- **Tile sizes:** 8×8 and 16×16, independently selectable per plane
- **Color:** 4 bpp, 16 colors/tile from 1024-entry palette
- **Sprite handling:** Integrated into same chip (chip[0] handles sprites for most games)
- **Features:** Row scroll, column scroll, flip-screen, per-tile priority

**DECO16IC register interface:**
```
pf_control[0] = mode (tile size, enable)
pf_control[1] = X scroll
pf_control[2] = Y scroll
pf_control[3] = color bank / priority
pf_rowscroll   = 0x200 bytes row scroll RAM
pf_colscroll   = 0x200 bytes column scroll RAM
pf_data        = tile RAM
```

- **MiSTer status:** NEED (no community FPGA implementation found)

### Palette

- **Size:** 1024 entries (dec0) / 2048 entries (cninja)
- **Format:** `xBGR_888` (dec0) — `xBGR_444` (cninja/dec1 family, 12-bit)
- **Address:** 0x310000–0x3107FF (dec0) / 0x120000–0x1207FF (cninja)

### Screen Parameters

```
Pixel clock:    12 MHz / 2 = 6 MHz (dec0)  /  24 MHz / 4 = 6 MHz (cninja)
Total width:    384 pixels
Visible width:  256 pixels
Total height:   272 lines
Visible height: 240 lines (rows 8..248)
VSync:          57.416 Hz (measured on real PCBs — NOT 60 Hz)
HSync:          15.617 kHz (Heavy Barrel) / 15.144 kHz (Midnight Resistance)
```

### Layer Priority

**dec0 Heavy Barrel:**
```
1. tilegen[2] BG far (opaque)
2. tilegen[1] BG near
3. tilegen[0] FG text
4. Sprites (above layer 2 unless color bit 3 set → behind BG)
```

**cninja / Caveman Ninja:**
```
1. pf4 (DECO16IC chip[1] plane B) — far background
2. pf3 (DECO16IC chip[1] plane A) — near background
3. pf2 (DECO16IC chip[0] plane B) — midground
4. pf1 (DECO16IC chip[0] plane A) — foreground/text
5. Sprites — priority via per-sprite bit vs. pf1/pf2
```

---

## Audio Hardware

### dec0 Family Sound System (all dec0 games — M6502 or HuC6280 as audio CPU)

| Chip | Clock | Role | MiSTer |
|------|-------|------|--------|
| YM2203 OPN | 1.5 MHz (12 MHz / 8) | FM synthesis (3 op) + SSG | HAVE (jt2203) |
| YM3812 OPL2 | 3.0 MHz (12 MHz / 4) | FM synthesis (2 op) | HAVE (jtopl2/jt3812) |
| OKI M6295 | 1.0 MHz (20 MHz / 2 / 10) | 4-channel ADPCM | HAVE (jt6295) |

**M6502 sound address map (`dec0_s_map`):**
```
0x0000–0x07FF  2 KB RAM
0x0800–0x0801  YM2203
0x1000–0x1001  YM3812
0x3000         Sound latch (from main CPU)
0x3800         OKI M6295
0x8000–0xFFFF  ROM (32 KB)
```

### cninja Family Sound System

Same chips (YM2203 + YM3812 + OKI M6295), but now driven by HuC6280 as audio CPU.
Some later cninja games (Fighter's History) add YM2151 (OPM) replacing or supplementing YM2203.

**Midnight Resistance:** OKI clock = 1.056 MHz (not 1.0 MHz — slight pitch difference).

**Funky Jet sound map (HuC6280-based):**
```
0x000000–0x00FFFF  ROM
0x110000–0x110001  YM2203
0x120000–0x120001  YM3812 or YM2151 (game-dependent)
0x130000           OKI M6295
0x140000           Sound latch
0x1F0000–0x1F1FFF  RAM
```

---

## Custom Chips Summary

| Chip Name | Chip ID | Family | Function | MAME Source |
|-----------|---------|--------|----------|-------------|
| BAC06 | L7B0072 | dec0 | Tile generator (one plane each) | `video/decbac06.cpp` |
| MXC06 | L7B0073 | dec0 | Sprite generator | `video/decmxc06.cpp` |
| DECO16IC | chip 45/56/74 | cninja | Unified BG + sprite engine (4 planes) | `video/deco16ic.cpp` |
| DEC-01 / chip 45 | internal | all | HuC6280 audio CPU (disguised) | CPU hardware |
| DECO56 | chip 56 | cninja | Protection/IO chip | `machine/deco56.cpp` |
| DECO146 | chip 146 | cninja (late) | Input protection | `machine/deco146.cpp` |
| MB8421 | Fujitsu | dec0 | Dual-port SRAM (Robocop/Hippodrome) | dual-port RAM |
| i8751 | Intel | dec0 (early) | Security MCU | `machine/` |

---

## Chip Status for MiSTer

| Chip | Type | MiSTer Status | Notes |
|------|------|---------------|-------|
| MC68000 | Main CPU | **HAVE** (fx68k) | JTFPGA fork; `chips/m68000/hdl/fx68k/` |
| M6502 / RP65C02A | Audio CPU (early dec0) | **HAVE** (T65) | Standard 6502 implementation |
| HuC6280 (DEC-01) | Audio/Sub CPU (all cninja) | **NEED** | No FPGA HuC6280 core in factory |
| BAC06 (L7B0072) | Tile generator (dec0) | **NEED** | 3 instances; 8×8+16×16, row/col scroll |
| MXC06 (L7B0073) | Sprite generator (dec0) | **NEED** | Double-buffered; 256 sprites; zoom |
| DECO16IC (chip 45/56/74) | Unified BG+sprite (cninja) | **NEED** | 4 BG planes + sprites |
| YM2203 OPN | FM sound | **HAVE** (jt2203) | jotego core |
| YM3812 OPL2 | FM sound | **HAVE** (jtopl2) | jotego core |
| OKI M6295 | ADPCM | **HAVE** (jt6295) | jotego core |
| i8751 | Security MCU (early dec0) | **NEED** (per-game sim) | Emulate via FSM, not full CPU |
| MB8421 | Dual-port SRAM | **NEED** (or BRAM) | Robocop/Hippodrome only; M10K |
| DECO56 | I/O protection | **NEED** (simple) | Straightforward input latch |
| MSM5205 | ADPCM (bootlegs) | **HAVE** (jt5205) | Bootleg variants only |

**Summary:**
- HAVE: 6 chips (68K, 6502, YM2203, YM3812, OKI M6295, MSM5205)
- NEED: 7 (HuC6280, BAC06, MXC06, DECO16IC, i8751 sim, MB8421, DECO56)
- INFEASIBLE: 0

**Critical path:** BAC06 + MXC06 (dec0) or DECO16IC (cninja) — video is the blocker.
HuC6280 is secondary blocker for audio on all cninja games and later dec0 games.

---

## Input / Controls

### Standard dec0 I/O Ports

| Address | Contents |
|---------|----------|
| 0x30C000 | INPUTS: P1[7:0] + P2[15:8] — UP/DOWN/LEFT/RIGHT/B1/B2/B3 (active low) |
| 0x30C002 | SYSTEM: B4/5, START1[2], START2[3], COIN1[4], COIN2[5], SERVICE[6], VBLANK[7] |
| 0x30C004 | DSW: DIP bank 2 [15:8] + DIP bank 1 [7:0] |
| 0x30C008 | i8751 MCU return value (hbarrel/baddudes only) |

**MiSTer mapping:** P1 Start = SYSTEM bit[2] (active low = `~joy[7]`); Coin = bit[4] (`~joy[8]`).

### Heavy Barrel / Midnight Resistance — 12-Way Rotary Joystick

uPD4701 encoder at 0x300000 (P1) and 0x300008 (P2). One-hot 16-bit encoding:
```
Pos 0=0xFFFE, 1=0xFFFD, 2=0xFFFB, 3=0xFFF7, 4=0xFFEF, 5=0xFFDF,
    6=0xFFBF, 7=0xFF7F, 8=0xFEFF, 9=0xFDFF, 10=0xFBFF, 11=0xF7FF
```

### cninja / Caveman Ninja — Standard 8-way + 2 buttons

No special encoder. Controls at 0x180000 (INPUTS), 0x180002 (SYSTEM), 0x180004 (DSW).

---

## Interrupt Routing

### Main CPU (68000) — All Games

| Event | IRQ Level | Ack Method |
|-------|-----------|------------|
| VBlank | IRQ 6 | Write to 0x30C018 (dec0) or auto-ack (slyspy/midres/cninja) |
| MB8421 write from sub-CPU | IRQ 4 | Hardware auto-clear (Robocop only) |

**RTL VBL IRQ pattern (COMMUNITY_PATTERNS.md Section 1.2):**
```verilog
wire inta_n = ~&{FC[2], FC[1], FC[0], ~ASn};
always @(posedge clk) begin
    if (rst)              ipl6 <= 1'b1;
    else if (!inta_n)     ipl6 <= 1'b1;   // IACK clears
    else if (vblank_fall) ipl6 <= 1'b0;   // VBL asserts
end
fx68k u_cpu (.IPL2n(1'b1), .IPL1n(ipl6), .IPL0n(1'b1), .VPAn(inta_n), ...);
```

### Audio CPU (HuC6280) — cninja family

| Source | Line |
|--------|------|
| YM3812 IRQ | IRQ1 |
| Sound latch data-pending | NMI |

---

## ROM Layout

### dec0 MEC-M1 Games (hbarrel, baddudes)

```
"maincpu" 68000 ROM: 0x60000 (384 KB) — byte-interleaved pairs (ROM_LOAD16_BYTE)
"audiocpu" 6502 ROM: 0x10000 (64 KB) at 0x8000
"mcu" i8751: 0x1000 (4 KB)
"gfx1/2/3" BAC06 tile data (separate regions per tilegen)
"sprites"  MXC06 sprite data
"oki"      OKI M6295 ADPCM samples
```

### cninja Games (cninja, funkyjet, nitrobal)

```
"maincpu" 68000 ROM: 0x80000–0x100000 (512 KB – 1 MB)
"audiocpu" HuC6280 ROM: 0x20000 (128 KB)
"gfx1/2"  DECO16IC pf1/pf2 tile data (chip[0])
"gfx3/4"  DECO16IC pf3/pf4 tile data (chip[1])
"sprites"  DECO16IC sprite data
"oki"      OKI M6295 ADPCM samples
```

---

## Protection Notes

### Sly Spy / Secret Agent — 4-State Tilegen Map Protection

State stored at audio RAM mirror `0x1F0045`. Advances on reads of `0x244000` (0→1→2→3→0).
Reset by read of `0x24A000`. Each state remaps the BAC06 control registers to different offsets.
Parallel 4-state machine remaps sound chip addresses (YM3812, YM2203, OKI, sound latch).

### DECO56 (cninja family) — Input I/O

DECO56 is a latched input/output chip — not a complex encryption device. Each game's I/O
accesses go through DECO56 which acts as a transparent register file with optional port enables.
Implement as simple address-decoded register bank in RTL.

### HuC6280 Opcode Decrypt

HuC6280 internal ROM uses a scrambled opcode table (`h6280_decrypt` in `dec0_m.cpp`).
This can be pre-applied to ROM images at load time — no real-time decryption needed in RTL.

---

## SDRAM Layout (Proposed 5-Channel Plan)

```
Bank 0:  Program ROM (maincpu)       — 68000 reads via SDRAM
Bank 1:  BAC06/DECO16IC pf1 tile ROM — tile pixel fetch at scan rate
Bank 2:  BAC06/DECO16IC pf2 tile ROM — tile pixel fetch
Bank 3:  BAC06/DECO16IC pf3/pf4 ROM  — cninja BG planes 3+4 (multiplexed)
Bank 4:  Sprite ROM (MXC06/DECO16IC) — sprite pixel fetch
```

OKI ADPCM samples (typically 256–512 KB) can be placed in M10K block RAM
or multiplexed onto Bank 0 during audio-only accesses.

---

## Implementation Strategy

### Recommended First Target: Bad Dudes (baddudes)

**Why:** M6502 audio CPU (simpler than HuC6280), i8751 MCU with small command set,
standard 2-player layout, well-documented dec0 memory map. No sub-CPU, no protection
state machine. Validates BAC06 + MXC06 with minimal complexity.

**Skip for Phase 1:**
- Sly Spy — 4-state protection machine doubles RTL complexity
- RoboCop — dual HuC6280 CPUs + MB8421 dual-port RAM
- Caveman Ninja — requires DECO16IC (different chip family from dec0)

### Phase 2 Target: Caveman Ninja (cninja)

After BAC06 + MXC06 are proven in baddudes, port to DECO16IC for cninja. The DECO16IC
is architecturally similar to BAC06 (same scroll/priority model) but unified into one chip
with 4 planes. Parameterize BAC06 → DECO16IC upgrade path.

---

## Gate Pipeline Status

| Gate | dec0 (baddudes) | cninja (caveman ninja) | Notes |
|------|-----------------|----------------------|-------|
| Gate 1: Verilator sim | NOT STARTED | NOT STARTED | BAC06 / DECO16IC RTL required first |
| Gate 2: RTL lint | NOT STARTED | NOT STARTED | |
| Gate 3: Standalone synthesis | NOT STARTED | NOT STARTED | |
| Gate 4: Full system synthesis | NOT STARTED | NOT STARTED | |
| Gate 5: MAME comparison | NOT STARTED | NOT STARTED | |
| Gate 6: Opus RTL review | NOT STARTED | NOT STARTED | |
| Gate 7: Hardware test | NOT STARTED | NOT STARTED | |

**Blockers:**
1. BAC06 tile generator — no community FPGA implementation; build from MAME `decbac06.cpp`
2. MXC06 sprite generator — no community implementation; build from MAME `decmxc06.cpp`
3. HuC6280 CPU core — needed for audio on all post-1988 games
4. DECO16IC — required for all cninja-era games (later, after dec0 proven)

**Unblocked work (start now):**
- Memory map address decoder RTL (palette, sprite RAM, main RAM, control registers)
- Sim harness skeleton: CPU boots from ROM, no video (use `NOSOUND`/`NOVIDEO` feature gates)
- i8751 MCU command-table emulation (~4 commands per game, state machine approach)
- OKI M6295 + YM2203 + YM3812 audio integration (all three cores available)

---

## MAME Driver Notes

### dec0.cpp Key Implementation Details

- `screen_update_hbarrel()`: tilegen[2] rendered first (opaque BG), then [1], then [0] (text), then sprites
- `screen_update_baddudes()`: Priority register at 0x30C010 bit 0 swaps tilegen[1] vs [2]
- `dec0_controls_r()`: Returns P1+P2, SYSTEM (includes VBLANK bit), DSW, MCU in 3 reads
- `dec0_control_w()`: Sprite DMA trigger at offset +2; sound latch at +4; IRQ ack at +8
- Robocop MB8421: Both CPUs get an IRQ when the other side writes (hardware synchronization)
- Hippodrome sub-CPU: Shares 0x40-byte RAM window; sub-CPU gets VBlank IRQ1

### cninja.cpp Key Implementation Details

- `cninja_map`: Extended ROM space to 0x80000+; different RAM layout vs dec0
- DECO16IC accessed via `chip[0]` and `chip[1]` objects; each handles 2 BG planes
- `screen_update_cninja()`: 4 layers + sprites; priority via DECO priority mixer
- DECO56 protection: Implemented as simple I/O latch in `machine/deco56.cpp`
- Funky Jet uses identical hardware to Caveman Ninja — same RTL should cover both

---

## References

- MAME source: `mamedev/mame/src/mame/dataeast/dec0.cpp` (dec0 hardware)
- MAME source: `mamedev/mame/src/mame/dataeast/cninja.cpp` (cninja/dec1 hardware)
- MAME source: `mamedev/mame/src/mame/dataeast/dec0.h` (shared types)
- MAME device: `mamedev/mame/src/mame/video/decbac06.cpp` (BAC06 tile generator)
- MAME device: `mamedev/mame/src/mame/video/decmxc06.cpp` (MXC06 sprite generator)
- MAME device: `mamedev/mame/src/mame/video/deco16ic.cpp` (DECO16IC unified graphics)
- MAME device: `mamedev/mame/src/mame/machine/deco56.cpp` (DECO56 I/O protection)
- See also: `chips/deco16_arcade/HARDWARE.md` — deep-dive on dec0 family (1987–1990)
- `chips/COMMUNITY_PATTERNS.md` — fx68k integration (mandatory before any RTL)
- `chips/GUARDRAILS.md` — synthesis and simulation rules (mandatory)
- PCB layout notes: `dec0.cpp` header comment by Guru (extensive component documentation)
