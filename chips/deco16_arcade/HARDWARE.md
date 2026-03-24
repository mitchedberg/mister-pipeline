# DECO 16-bit (dec0) — Hardware Profile

*Expanded from MAME `dataeast/dec0.cpp`, `dataeast/dec0.h`, `dataeast/dec0_v.cpp`,
`dataeast/dec0_m.cpp`, and PCB layout documentation by Guru — 2026-03-22*

---

## Overview

Data East's primary 16-bit arcade platform, nicknamed "dec0" in MAME, covers 1987–1990.
The platform uses a Motorola 68000 main CPU backed by various sound co-processors and two custom
Data East graphics ASICs (BAC06 tile generator, MXC06 sprite generator). Several games share the
"MEC-M1" motherboard while others are standalone single-PCBs.

**Two motherboard configurations:**

- **MEC-M1 (modular):** Heavy Barrel, Bad Dudes, Robocop, Birdie Try, Hippodrome, Bandit — main
  board (`DE-0297-3` / `DE-0295-1`) + plug-in game ROM board. Main board holds all the custom ICs;
  ROM boards differ per game.
- **Single-PCB (unified):** Sly Spy, Midnight Resistance, Boulder Dash — same custom chips on one
  PCB with different clock/memory arrangements.

**Audio CPU evolution:** Early games use a 6502 (`M6502` / `RP65C02A`) as audio CPU. Later games
(Robocop, Hippodrome, Sly Spy, Midnight Resistance) disguise a Hudson HuC6280 as a Data East
custom chip (`DEC-01`, `DEC-01`, chip `45`).

**MCU:** Intel 8751 (i8751) security MCU on ROM boards for Heavy Barrel, Bad Dudes, Robocop,
Birdie Try, Bandit. Hippodrome uses a proprietary HuC6280-based sub-CPU architecture.
MCU is NOT used in Sly Spy, Midnight Resistance, or Boulder Dash.

---

## Games Table

| MAME Romset | Title | Year | PCB | Audio CPU | MCU | Notes |
|-------------|-------|------|-----|-----------|-----|-------|
| `hbarrel` | Heavy Barrel | 1987 | MEC-M1 + DE-0293-x | M6502 | i8751 | 12-way rotary joysticks |
| `baddudes` | Bad Dudes vs. DragonNinja | 1988 | MEC-M1 + DE-0299-2 | M6502 | i8751 | US title; "Dragonninja" in JP |
| `birdtry` | Birdie Try | 1988 | MEC-M1 + DE-0293-x | M6502 | i8751 | Trackball golf |
| `robocop` | RoboCop | 1988 | MEC-M1 + DE-0316-4 | HuC6280 | none (HuC6280 sub-CPU) | MB8421 dual-port RAM |
| `bandit` | Bandit | 1989 | MEC-M1 + DE-0293-x | M6502 | i8751 | Field test prototype |
| `hippodrm` | Hippodrome (Fighting Fantasy) | 1989 | MEC-M1 + DE-0318-4 | HuC6280 | none (HuC6280 sub-CPU) | |
| `secretag` | Secret Agent (Sly Spy) | 1989 | Single PCB | HuC6280 | none | Memory-map protection state machine |
| `midres` | Midnight Resistance | 1989 | Single PCB (DE-0323-4) | HuC6280 | none | 12-way rotary joystick |
| `bouldash` | Boulder Dash | 1990 | Single PCB | HuC6280 | none | Licensed from First Star |

**Total unique games:** 9 (39 ROM variants including bootlegs and regional versions)

---

## CPU Section

### Main CPU — All Games

| CPU | Clock | Source |
|-----|-------|--------|
| Motorola MC68000 (`68000P10`) | 10 MHz (20 MHz XTAL / 2) | Verified on PCB |

**MiSTer:** Use **fx68k** (JTFPGA fork at `chips/m68000/hdl/fx68k/`). See COMMUNITY_PATTERNS.md
Section 1 for mandatory integration pattern (enPhi1/enPhi2, IACK-based IPL clear, VPAn).

### Audio CPU — Two Variants

| CPU | Tag | Clock | Games |
|-----|-----|-------|-------|
| M6502 (RP65C02A) | `audiocpu` | 1.5 MHz (12 MHz / 8) | hbarrel, baddudes, birdtry, bandit, midresb (bootleg) |
| HuC6280 (disguised as `DEC-01`/`45`) | `audiocpu` | 6 MHz (21.4772 MHz / ~3.5 or 24 MHz / 4) | robocop, hippodrm, secretag/slyspy, midres, bouldash |

**Clock details (PCB-verified):**
- Robocop: HuC6280 @ `21.4772 MHz / 16` ≈ 1.342 MHz internal (but 21.4772 MHz on pin 10 = 6 MHz effective)
- Hippodrm: same as Robocop
- Sly Spy: HuC6280 @ `12 MHz / 2 / 2 = 3 MHz` (6 MHz XIN on pin 10, PCB-verified)
- Midnight Resistance: HuC6280 @ `24 MHz / 4 / 3 ≈ 2 MHz` (6 MHz XIN on pin 10, PCB-verified)

### Sub-CPU (Robocop and Hippodrome only)

| CPU | Tag | Clock | Role |
|-----|-----|-------|------|
| HuC6280 (as `DEC-01`/`45`) | `subcpu` | 21.4772 MHz / 16 ≈ 1.342 MHz | Sub-game logic, communicates with main via MB8421 dual-port RAM |

Robocop's `DEM-01` custom chip is a Fujitsu MB8421 dual-port SRAM in disguise. IRQs fire on both
sides when the opposite port writes, enabling synchronised 68000 ↔ HuC6280 messaging.

### MCU (i8751 — Heavy Barrel, Bad Dudes, Birdie Try, Bandit only)

| Chip | Clock | ROM size | Notes |
|------|-------|----------|-------|
| Intel i8751 | 8 MHz | 4 KB (0x1000) | Security MCU; game-specific dump required |

MCU implements commands: sync ($0B), reset-if-param ($01), table-index lookup ($07), table-reset
($09). In practice, games only use ~4 commands. MAME emulates per-game MCU behavior in `dec0_m.cpp`.

**MiSTer MCU strategy:** Emulate MCU responses in RTL via a small state machine (similar to jotego
approach for DECO games). Full i8751 core is impractical for FPGA; per-game MCU tables are small.

---

## Sound Hardware

### dec0 family (hbarrel, baddudes, birdtry, robocop, bandit, hippodrm)

| Chip | Tag | Clock | Role | MiSTer |
|------|-----|-------|------|--------|
| YM2203 OPN | `ym1` | 1.5 MHz (12 MHz / 8) | FM synthesis (3 op) + SSG | HAVE (jt2203 or equivalent) |
| YM3812 OPL2 | `ym2` | 3.0 MHz (12 MHz / 4) | FM synthesis (2 op) | HAVE (jt3812 or equivalent) |
| OKI M6295 | `oki` | 1.0 MHz (20 MHz / 2 / 10) | 4-channel ADPCM | HAVE (jt6295) |

**IRQ routing (dec0 family):**
- YM2203 IRQ → Audio CPU IRQ line 0 (only used in Bandit; most games don't enable)
- YM3812 IRQ → Audio CPU IRQ line 0
- Sound latch data-pending → Audio CPU NMI

**M6502 sound address map (`dec0_s_map`):**
```
0x0000–0x07FF  RAM (2 KB)
0x0800–0x0801  YM2203 (ym1)
0x1000–0x1001  YM3812 (ym2)
0x3000         Sound latch read (from main CPU)
0x3800         OKI M6295 R/W
0x8000–0xFFFF  ROM (32 KB)
```

### Sly Spy / Secret Agent (secretag)

Same chips as dec0 family (YM2203 + YM3812 + OKI M6295) but the HuC6280 sound CPU uses a
**4-state memory-map protection machine** — address decoding cycles through 4 different views
(`m_sndview[0..3]`) advanced by reading `0x0A0000` and reset by `0x0D0000`. RTL must implement
this state machine.

### Midnight Resistance (midres)

Same chips (YM2203 + YM3812 + OKI M6295). OKI clock changes to **1.056 MHz** (not 1.0 MHz).

**Midnight Resistance sound map (`midres_s_map`):**
```
0x000000–0x00FFFF  ROM
0x108000–0x108001  YM3812
0x118000–0x118001  YM2203
0x130000–0x130001  OKI M6295
0x138000–0x138001  Sound latch read
0x1F0000–0x1F1FFF  RAM (8 KB)
```

### Automat bootleg variants (secretab, automat)

Bootleg circuit replaces sound CPU with M6502 + dual YM2203 + MSM5205 (instead of YM3812 + OKI):

| Chip | Tag | Clock | Notes |
|------|-----|-------|-------|
| YM2203 | `2203a` | — | First FM chip |
| YM2203 | `2203b` | — | Second FM chip |
| MSM5205 | `msm1`, `msm2` | — | Dual ADPCM; selectable via LS157 mux |

---

## Video Hardware

### Custom Chip: BAC06 (L7B0072 DATAEAST) — Tile Generator

**Chip ID:** L7B0072 (QFP160 or PGA package)
**MAME device:** `deco_bac06_device` (in `video/decbac06.cpp`)
**Instances:** Up to 3 per board (tilegen[0], tilegen[1], tilegen[2])

Each BAC06 implements one scrollable tilemap plane with the following features:

- **Tile sizes:** 8×8 or 16×16 pixels (software-selectable per instance)
- **Tilemap dimensions:** Configurable, typically 64×32 or 32×32 tiles
- **Color depth:** 4 bpp (16 colors per tile from 1024-color palette)
- **Features:** Row scroll, column scroll, flip-screen, per-tile priority

**BAC06 Register Map (per instance, accessed at control_0 and control_1 offsets):**
```
pf_control_0[0]  = tile size / mode select (bit 1: 16x16, bit 7: enable 16x16 wide)
pf_control_0[1]  = color bank select
pf_control_0[2]  = x scroll offset (global)
pf_control_0[3]  = playfield dimensions

pf_control_1[0]  = x scroll (fine)
pf_control_1[1]  = y scroll (fine)
pf_control_1[2]  = row/column scroll enables
pf_control_1[3]  = row/column scroll mode
```

**Scroll RAM (per instance):**
- Column scroll RAM: 0x80 bytes (128 bytes = one value per column)
- Row scroll RAM: 0x400 bytes (one value per row)
- Tile data RAM: varies (0x800–0x2000 bytes depending on plane)

**Per-game assignment:**
| Game | tilegen[0] (text/fg) | tilegen[1] (pf1) | tilegen[2] (pf2) |
|------|----------------------|------------------|------------------|
| hbarrel | 8×8 foreground | 16×16 BG far | 16×16 BG near |
| baddudes | 8×8 foreground | 16×16 BG1 | 16×16 BG2 |
| robocop | 8×8 foreground | 16×16 BG1 | 16×16 BG2 |
| midres | 16×16 BG1 | 16×16 BG2 | 8×8 text layer |

### Custom Chip: MXC06 (L7B0073 DATAEAST) — Sprite Generator

**Chip ID:** L7B0073 (QFP160 or PGA package)
**MAME device:** `deco_mxc06_device` (in `video/decmxc06.cpp`)
**Instances:** 1 per board (m_spritegen)

- **Buffered sprite RAM:** 0x800 bytes (1 KB) — double-buffered (write to `ffc000`, display from buffer)
- **Sprite DMA:** Triggered by writing to `0x30c012` (main control register offset 2)
- **Sprite format:** Each sprite = 8 bytes (4 words)

**Sprite attribute format (4 words per sprite, 0x800 bytes = 256 sprites):**
```
Word 0:  [15:8] Y position, [7:0] sprite number high bits
Word 1:  [15:8] X position, [7:0] sprite number low bits
Word 2:  [15:8] color / priority, [7:0] size / flip
Word 3:  [15:8] reserved, [7:0] zoom
```

**Priority control:** Per-sprite bit determines sprite-above-tilemap or sprite-below-foreground.
Games use `m_pri` register (written to `0x30c010`) to control global sprite/tilemap priority.

### Palette

- **Size:** 1024 colors
- **Format:** `xBGR_888` (dec0 family) or `xBGR_444` (dec1/slyspy family)
- **Location:** `0x310000–0x3107FF` (main palette) + `0x314000–0x3147FF` (extended palette)
- **Total:** 1024 entries × 2 banks

### Screen Parameters

```
Pixel clock:    12 MHz / 2 = 6 MHz
Total width:    384 pixels
Visible width:  256 pixels
Total height:   272 lines
Visible height: 240 lines (8..248)
VSync:          57.416 Hz (measured on Heavy Barrel, Midnight Resistance PCBs)
HSync:          15.617 kHz (Heavy Barrel) / 15.144 kHz (Midnight Resistance)
```

### Layer Priority (screen_update variants)

**Heavy Barrel (`screen_update_hbarrel`):**
```
1. tilegen[2] (BG far, opaque)       priority=1
2. tilegen[1] (BG near)              priority=2
3. tilegen[0] (FG text)              priority=4
4. Sprites (above layer 2 unless color bit 3 set → behind layer 1)
```

**Bad Dudes / Robocop (`screen_update_baddudes` / `screen_update_robocop`):**
```
Priority register (0x30c010, bit 0) swaps BG layers:
bit0=0: tilegen[1]=BG, tilegen[2]=FG
bit0=1: tilegen[2]=BG, tilegen[1]=FG
bit1/2 = sprite priority relative to FG layer
tilegen[0] always on top (8x8 text/HUD)
```

**Midnight Resistance:**
Inverted priority semantics vs. Bad Dudes — `m_pri` bit0 interpretation flipped.
See `midres_colpri_cb` in `dec0_v.cpp`.

---

## Memory Maps

### Standard dec0 map (`dec0_map`) — Heavy Barrel, Bad Dudes, Birdie Try, Hippodrome, Bandit

```
0x000000–0x05FFFF   ROM (6 × 64 KB = 384 KB program ROM)
0x240000–0x240007   BAC06[0] control_0 (text layer)
0x240010–0x240017   BAC06[0] control_1
0x242000–0x24207F   BAC06[0] column scroll RAM (0x80 bytes)
0x242400–0x2427FF   BAC06[0] row scroll RAM (0x400 bytes)
0x242800–0x243FFF   RAM (Robocop only)
0x244000–0x245FFF   BAC06[0] tile data RAM (0x2000 bytes)
0x246000–0x246007   BAC06[1] control_0 (BG layer 1)
0x246010–0x246017   BAC06[1] control_1
0x248000–0x24807F   BAC06[1] column scroll RAM
0x248400–0x2487FF   BAC06[1] row scroll RAM
0x24A000–0x24A7FF   BAC06[1] tile data RAM
0x24C000–0x24C007   BAC06[2] control_0 (BG layer 2)
0x24C010–0x24C017   BAC06[2] control_1
0x24C800–0x24C87F   BAC06[2] column scroll RAM
0x24CC00–0x24CFFF   BAC06[2] row scroll RAM
0x24D000–0x24D7FF   BAC06[2] tile data RAM
0x300000–0x300001   Rotary joystick P1 (AN0) [hbarrel, bandit only]
0x300008–0x300009   Rotary joystick P2 (AN1) [hbarrel, bandit only]
0x30C000–0x30C00B   Controls read (dec0_controls_r):
                      +0: INPUTS (P1+P2 joystick + buttons)
                      +2: SYSTEM (coins, start, VBLANK)
                      +4: DSW (dipswitches)
                      +8: i8751 MCU return value
0x30C010–0x30C01F   Control write (dec0_control_w):
                      +0: Priority register (sprite/tile priority)
                      +2: Sprite DMA trigger (copy spriteram buffer)
                      +4: Sound latch write (to audio CPU)
                      +6: i8751 MCU write
                      +8: IRQ acknowledge (VBL IRQ 6 clear)
                      +C: Coin blockout
                      +E: i8751 MCU reset
0x310000–0x3107FF   Palette RAM (1024 × 16-bit entries)
0x314000–0x3147FF   Palette RAM extended
0x318000–0x31BFFF   Main RAM (16 KB) [mirrors at some addresses]
0x31C000–0x31C7FF   Sprite RAM (2 KB, write buffer)
0xFF8000–0xFFBFFF   Main RAM mirror (16 KB)
0xFFC000–0xFFC7FF   Sprite RAM mirror
```

### Robocop additions (`robocop_state::main_map`)

```
0x180000–0x180FFF   MB8421 dual-port RAM (left side, byte access)
                    — shared with HuC6280 sub-CPU at its 0x1F2000
```

### Hippodrome additions (`hippodrm_state::main_map`)

```
0x180000–0x18003F   Shared RAM (HuC6280 communication)
```

### Sly Spy / Secret Agent (`slyspy_state::main_map`)

Significant memory map differences — protection state machine remaps tilegen registers:

```
0x000000–0x05FFFF   ROM
0x240000–0x24FFFF   Tilegen area (4 states, software-remapped by protection)
0x300000–0x3007FF   BAC06[2] control + tile data (unaffected by protection)
0x304000–0x307FFF   Main RAM (16 KB)
0x308000–0x3087FF   Sprite RAM
0x310000–0x3107FF   Palette RAM
0x314001            Sound latch write
0x314002–0x314003   Priority register
0x314008–0x31400F   Controls read (slyspy_controls_r)
0x31C000–0x31C00F   Protection read (pseudo-RNG / timer counter)
```

### Midnight Resistance (`dec0_state::midres_map`)

```
0x000000–0x07FFFF   ROM (512 KB)
0x100000–0x103FFF   Main RAM (16 KB)
0x120000–0x1207FF   Sprite RAM
0x140000–0x1407FF   Palette RAM
0x160000–0x160001   Priority register
0x180000–0x18000F   Controls read (midres_controls_r):
                      +0: INPUTS + P1/P2 start
                      +2: DSW dipswitches
                      +4: P1 rotary (AN0)
                      +6: P2 rotary (AN1)
                      +8: SYSTEM (coins, VBLANK)
0x1A0001            Sound latch write
0x200000–0x200007   BAC06[1] control_0 (BG near)
0x200010–0x200017   BAC06[1] control_1
0x220000–0x2207FF   BAC06[1] tile data RAM
0x240000–0x24007F   BAC06[1] column scroll RAM
0x240400–0x2407FF   BAC06[1] row scroll RAM
0x280000–0x280007   BAC06[2] control_0 (BG far)
0x280010–0x280017   BAC06[2] control_1
0x2A0000–0x2A07FF   BAC06[2] tile data RAM
0x2C0000–0x2C007F   BAC06[2] column scroll RAM
0x2C0400–0x2C07FF   BAC06[2] row scroll RAM
0x300000–0x300007   BAC06[0] control_0 (text/FG)
0x300010–0x300017   BAC06[0] control_1
0x320000–0x321FFF   BAC06[0] tile data RAM
0x340000–0x34007F   BAC06[0] column scroll RAM
0x340400–0x3407FF   BAC06[0] row scroll RAM
```

---

## Interrupt Routing

### Main CPU (68000) — All Games

| Event | IRQ Level | Ack Method |
|-------|-----------|------------|
| VBlank | IRQ 6 | Write to 0x30C018 (dec0_map) or auto-acks (slyspy/midres) |
| MB8421 write (Robocop only) | IRQ 4 | Hardware auto-clear on MB8421 |

**VBL IRQ pattern:**
- `dec0`: `irq6_line_assert` — asserts IRQ6 on VBLANK, CPU must write 0x30C018 to clear
- `slyspy`, `midres`, `hippodrm`: `irq6_line_hold` — IRQ6 auto-acks (write to address clears itself)

**RTL pattern (COMMUNITY_PATTERNS.md Section 1.2):**
```verilog
wire inta_n = ~&{FC[2], FC[1], FC[0], ~ASn};
always @(posedge clk) begin
    if (rst)         ipl6 <= 1'b1;
    else if (!inta_n) ipl6 <= 1'b1;   // IACK clears
    else if (vblank_falling) ipl6 <= 1'b0; // VBL sets
end
fx68k u_cpu (.IPL2n(1'b1), .IPL1n(ipl6), .IPL0n(1'b1), .VPAn(inta_n), ...);
```

### Audio CPU — M6502 (hbarrel/baddudes family)

| Source | Line | Notes |
|--------|------|-------|
| YM3812 IRQ | IRQ | Primary FM IRQ |
| YM2203 IRQ | IRQ | Secondary (only used by Bandit) |
| Sound latch data-pending | NMI | Main CPU → audio CPU communication |

### Audio CPU — HuC6280 (robocop/slyspy/midres family)

| Source | Line | Notes |
|--------|------|-------|
| YM3812 IRQ | IRQ1 | dec1 config only |
| YM2203 IRQ | IRQ0 | secondary (infrequently used) |
| Sound latch data-pending | NMI | |

### Sub-CPU HuC6280 (Robocop, Hippodrome)

| Source | Line | Notes |
|--------|------|-------|
| MB8421 write from main | IRQ0 | Robocop shared RAM sync |
| VBlank | IRQ1 | Hippodrome only |

---

## I/O and Controls

### Standard Joystick Layout (dec0 INPUT_PORTS)

| Address | Offset | Contents |
|---------|--------|----------|
| 0x30C000 | +0 | `INPUTS`: P1[7:0] + P2[15:8] — UP/DOWN/LEFT/RIGHT/B1/B2/B3/B4 (active low) |
| 0x30C002 | +2 | `SYSTEM`: B5[0], B5-P2[1], START1[2], START2[3], COIN1[4], COIN2[5], SERVICE[6], VBLANK[7] |
| 0x30C004 | +4 | `DSW`: DIP bank 2 [15:8] + DIP bank 1 [7:0] |
| 0x30C008 | +8 | i8751 MCU return value (hbarrel/baddudes/birdtry/bandit only) |

**MiSTer I/O mapping:**
- P1 Start = bit [2] of SYSTEM (active low → `~joy[7]` in MiSTer convention)
- Coin = bit [4] of SYSTEM (active low → `~joy[8]`)
- Joystick directions and fire buttons in standard 8-way + 4-button layout

### Heavy Barrel / Midnight Resistance — Rotary Joystick

12-position rotary encoded as a 16-bit one-hot value via uPD4701 encoder counter chip.
The encoder is read at `0x300000` (P1) and `0x300008` (P2).

One-hot table:
```
Pos 0=0xFFFE, 1=0xFFFD, 2=0xFFFB, 3=0xFFF7, 4=0xFFEF, 5=0xFFDF,
    6=0xFFBF, 7=0xFF7F, 8=0xFEFF, 9=0xFDFF, 10=0xFBFF, 11=0xF7FF
```

### Birdie Try — Trackball

uPD4701 quad encoder at `0x300010–0x30001F` (P1 X/Y) and `0x300018–0x30001F` (P2 X/Y).

---

## ROM Layout

### MEC-M1 Games (hbarrel, baddudes, birdtry, bandit)

All ROMs on the ROM board. Program ROMs are 68000 byte-interleaved pairs:

```
Region "maincpu" (68000) — 0x60000 (384 KB):
  ROM pairs interleaved: even byte at 3C/4C/6C, odd byte at 3A/4A/6A
  Load: ROM_LOAD16_BYTE for each pair

Region "audiocpu" (6502) — 0x10000 (64 KB):
  ROM at 0x8000 (upper 32 KB)

Region "mcu" (i8751) — 0x1000 (4 KB)

Region "gfx1" (BAC06 tile graphics)
Region "gfx2" (BAC06 tile graphics)
Region "gfx3" (BAC06 tile graphics, if tilegen[2] populated)
Region "sprites" (MXC06 sprite graphics)
Region "oki" (OKI M6295 ADPCM samples)
```

### Midnight Resistance

```
Region "maincpu" — 0x80000 (512 KB): 27C010 EPROMs
Region "audiocpu" — 0x20000: FK series EPROMs (HuC6280)
Region "gfx1/2/3", "sprites", "oki"
```

---

## Chip Status Table

| Chip | Type | MiSTer Status | Notes |
|------|------|---------------|-------|
| MC68000 | Main CPU | **HAVE** (fx68k) | JTFPGA fork, COMMUNITY_PATTERNS.md Section 1 |
| M6502 (RP65C02A) | Audio CPU (early games) | **HAVE** (T65 or similar) | Standard 6502 |
| HuC6280 | Audio/Sub CPU (later games) | **NEED** | Disguised as DEC-01/chip45; not in factory yet |
| BAC06 (L7B0072) | Tile Generator | **NEED** | 3 instances; 8×8+16×16, row/col scroll |
| MXC06 (L7B0073) | Sprite Generator | **NEED** | Buffered spriteram, priority, zoom |
| YM2203 OPN | FM Sound | **HAVE** (jt2203) | jotego core, 1.5 MHz |
| YM3812 OPL2 | FM Sound | **HAVE** (jtopl2 or jt3812) | jotego core, 3.0 MHz |
| OKI M6295 | ADPCM | **HAVE** (jt6295) | jotego core |
| i8751 MCU | Security MCU | **NEED** (per-game sim) | Emulate via state machine, not full CPU |
| MB8421 | Dual-port SRAM | **NEED** (or BRAM) | Robocop/Hippodrome only; implement as M10K |
| MSM5205 | ADPCM (automat bootleg) | **HAVE** (jt5205) | Bootleg only — not needed for real PCB |

**Chip summary:**
- **HAVE:** 6
- **NEED:** 5 (BAC06, MXC06, HuC6280, i8751 sim, MB8421)
- **COMMUNITY:** 0
- **INFEASIBLE:** 0

**Feasibility:** YES — BAC06 and MXC06 are the critical path. HuC6280 needed for later games.

---

## Implementation Strategy

### Phase 1 — Recommended First Target: Bad Dudes / baddudes

**Why:** Uses M6502 audio CPU (simpler than HuC6280), i8751 MCU (simple command set), well-documented,
single-PCB-compatible memory map, 2-player action game (easy frame validation).

**Skip for Phase 1:** Sly Spy (protection state machine), Robocop (dual-CPU complexity), Midnight
Resistance (different address map). Target these after BAC06/MXC06 are proven.

### Phase 2 — Hardware Abstraction Notes

**BAC06 RTL requirements:**
- Two tile size modes (8×8 and 16×16), software-selectable
- Per-plane row scroll and column scroll
- Flip-screen support
- Priority output per tile (bit 3 of color attribute → priority group)
- 4 bpp color, 16 colors/tile, palette bank select
- SDRAM backed tile ROM (read during scan-out)

**MXC06 RTL requirements:**
- DMA-triggered double buffer (copy on control write)
- 256 sprites × 8 bytes each
- Per-sprite color/priority
- Horizontal and vertical flip
- SDRAM backed sprite ROM

### SDRAM Layout (proposed 5-channel plan)

```
Bank 0:  Program ROM (maincpu)     — 68000 reads
Bank 1:  BAC06[0] Tile ROM (gfx0)  — tile pixel fetch
Bank 2:  BAC06[1] Tile ROM (gfx1)  — tile pixel fetch
Bank 3:  BAC06[2] Tile ROM (gfx2)  — tile pixel fetch
Bank 4:  MXC06 Sprite ROM          — sprite pixel fetch
```

OKI M6295 ADPCM samples can go in a 6th channel or be loaded into dedicated M10K block RAM
(samples are typically 256 KB or less for dec0 family).

---

## Protection Notes

### Sly Spy / Secret Agent — Tilegen Map Protection

4-state machine: current state stored at `0x1F0045` (audio RAM mirror). Each read of `0x244000`
advances state (0→1→2→3→0). Write to `0x24A000` resets to state 0. RTL must replicate this
state machine to correctly route tilegen addresses.

### Sly Spy — Sound CPU Protection

Parallel 4-state machine: reads `0x0A0000` advance audio state; reads `0x0D0000` reset it.
Each state remaps the sound chip I/O addresses (YM3812, YM2203, OKI, sound latch).
Total 4 sound memory map views.

### HuC6280 decrypt

The HuC6280 internal ROM uses a scrambled opcode table (`h6280_decrypt` in `dec0_m.cpp`).
When emulating HuC6280 in RTL this can be pre-applied to the ROM image at load time.

---

## Gate Pipeline Status

| Gate | Status | Notes |
|------|--------|-------|
| Gate 1: Verilator sim | NOT STARTED | BAC06 + MXC06 RTL required first |
| Gate 2: RTL lint | NOT STARTED | |
| Gate 3: Standalone synthesis | NOT STARTED | |
| Gate 4: Full system synthesis | NOT STARTED | |
| Gate 5: MAME golden comparison | NOT STARTED | MAME Lua scripts in `sim/mame_scripts/` |
| Gate 6: Opus RTL review | NOT STARTED | |
| Gate 7: Hardware test | NOT STARTED | |

**Blocking issues:**
1. BAC06 tile generator RTL — critical path; no existing MiSTer implementation found
2. MXC06 sprite generator RTL — required for all games
3. HuC6280 CPU core — required for Robocop, Hippodrome, Sly Spy, Midnight Resistance

**Unblocked work (can start now):**
- M6502 audio CPU integration (M6502-based games: hbarrel, baddudes, birdtry, bandit)
- i8751 MCU command table emulation (small; per-game, ~4 commands each)
- Memory map RTL (address decoder, palette, sprite RAM, main RAM)
- Sim harness skeleton (CPU boots from ROM without video subsystem)

---

## References

- MAME source: `mamedev/mame/src/mame/dataeast/dec0.cpp`
- MAME source: `mamedev/mame/src/mame/dataeast/dec0_v.cpp` (video update functions)
- MAME source: `mamedev/mame/src/mame/dataeast/dec0_m.cpp` (controls, MCU, protection)
- MAME source: `mamedev/mame/src/mame/dataeast/dec0.h`
- MAME device: `mamedev/mame/src/mame/dataeast/decbac06.cpp` (BAC06 tile generator)
- MAME device: `mamedev/mame/src/mame/dataeast/decmxc06.cpp` (MXC06 sprite generator)
- Local copies: `/Volumes/2TB_20260220/Projects/jtcores/cores/cop/doc/dec0*.cpp`
- PCB layouts by Guru: see top of `dec0.cpp` — extensive component-level documentation
- jotego COP core: `/Volumes/2TB_20260220/Projects/jtcores/cores/cop/` — community reference
- `chips/COMMUNITY_PATTERNS.md` — fx68k integration (mandatory before any RTL)
- `chips/GUARDRAILS.md` — synthesis and simulation rules (mandatory)
