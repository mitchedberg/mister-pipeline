# Arcade System Chip-Level BOM Database

**Purpose**: Complete bill of materials for 20 arcade systems in our MiSTer FPGA build roadmap.
**Date**: 2026-03-20
**Source**: MAME driver analysis (raw GitHub source)
**Status Legend**: ✅ HAVE (implemented) | ⚠️ NEED (must build) | ❓ UNKNOWN (needs research)

---

## ALREADY BUILDING (6 systems)

### 1. NMK16
**Games**: Twin Eagle, Tharrier, Mustang, etc.
**MAME Driver**: `src/mame/nmk/nmk16.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 10-12 MHz | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 4-6 MHz | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2203 | 1.5-3 MHz | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | OKI M6295 (×2) | 1-4 MHz | ✅ HAVE | jt6295 (jtcores) |
| **Protection** | NMK004 (TMP90C840) | internal ROM | ⚠️ NEED | None |
| **Protection** | NMK112 (OKI bank mgmt) | — | ⚠️ NEED | None |
| **Video** | Standard RAM tilemap | — | ✅ HAVE | Core HDL |

**Notes**: NMK004 is both protection and watchdog (NMI generator). Memory scrambling for 8-bit writes. NMK112 handles OKI banking.

---

### 2. Toaplan V2 (Batsugun / Truxton2)
**Games**: Batsugun, Truxton2, Mahjan Gakuen, etc.
**MAME Drivers**: `src/mame/toaplan/batsugun.cpp`, `truxton2.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 16 MHz (32MHz ÷ 2) | ✅ HAVE | fx68k (jtcores) |
| **Secondary CPU** | NEC V25 | 16 MHz (32MHz ÷ 2) | ⚠️ NEED | None |
| **Sound Gen** | YM2151 | 3.375 MHz (27MHz ÷ 8) | ✅ HAVE | jt51 (jtcores) |
| **Sound Gen** | OKI M6295 | 4 MHz (32MHz ÷ 8) | ✅ HAVE | jt6295 (jtcores) |
| **Video** | GP9001 VDP (×2) | 27 MHz | ✅ HAVE | Our build (Session 14) |
| **Text Tilemap** | Toaplan Text Device | 27 MHz | ⚠️ NEED | Community (partial) |
| **DAC** | YM3014B | mono | ✅ HAVE | Simple circuit |
| **I/O** | Coincounter | — | ⚠️ NEED | Behavioral model |

**Notes**: V25 is Intel 8086 clone with extended instructions. Bootlegs remove V25 + YM2151, add extra OKI. GP9001 likely same core as Psikyo variant.

---

### 3. Psikyo 68EC020
**Games**: Strikers 1945, Strikers 1945 II, Tengai, etc.
**MAME Driver**: `src/mame/psikyo/psikyo.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | 68EC020 | — (not explicit) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80A / LZ8420M | — (not explicit) | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2610 | — | ✅ HAVE | jt10 (jtcores) |
| **Sound Gen** | YMF286-K (YM2610 compat) | — | ✅ HAVE | jt10 (jtcores) |
| **Sound Gen** | YMF278B (variant) | — | ✅ HAVE | jt10 (jtcores) |
| **Protection** | PIC16C57 | — | ⚠️ NEED | None (optional on some boards) |
| **Video** | PS2001B | — | ⚠️ NEED | None |
| **Video** | PS3103, PS3204, PS3305 | — | ⚠️ NEED | None |
| **Sound** | OKI M6295 (bootlegs) | — | ✅ HAVE | jt6295 (jtcores) |

**Notes**: PIC16C57 only on certain boards (Strikers 1945, Tengai). PS3xxx are custom sprite/tilemap controllers. Clock frequencies not explicitly documented in MAME.

---

### 4. Kaneko16
**Games**: Gals Panic, Bonk's Adventure, Jackie Chan, etc.
**MAME Driver**: `src/mame/kaneko/kaneko16.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | — | ✅ HAVE | fx68k (jtcores) |
| **Sound Gen** | OKI M6295 (×1-2) | — | ✅ HAVE | jt6295 (jtcores) |
| **Sound Gen** | YM2149 (×0-2) | — | ✅ HAVE | jt49 (jtcores) |
| **Sound Gen** | YM2151 (alt config) | — | ✅ HAVE | jt51 (jtcores) |
| **Sound CPU** | Z80 (alt config) | — | ✅ HAVE | T80 (jtcores) |
| **Graphics** | VU-001 046A (48-pin PQFP) | — | ⚠️ NEED | None |
| **Graphics** | VU-002 052 (160-pin PQFP) | — | ⚠️ NEED | None |
| **Graphics** | VU-003 048 (×3, 40-pin) | — | ⚠️ NEED | None |
| **Graphics** | VIEW2-CHIP 23160 (144-pin) | — | ⚠️ NEED | None |
| **Graphics** | MUX2-CHIP (64-pin) | — | ⚠️ NEED | None |
| **Graphics** | HELP1-CHIP (64-pin) | — | ⚠️ NEED | None |
| **Protection** | IU-001 9045KP002 (44-pin) | — | ⚠️ NEED | None |
| **Protection** | CALC3 MCU (NEC uPD78322, 16K ROM) | — | ⚠️ NEED | None |
| **Protection** | TBSOP01/02 MCU (NEC uPD78324, 32K ROM) | — | ⚠️ NEED | None |
| **EEPROM** | 93C46 (optional) | — | ✅ HAVE | Standard |
| **I/O** | JAMMA MC-8282 (46-pin) | — | ⚠️ NEED | Behavioral model |

**Notes**: VU-series are Kaneko proprietary sprite/tilemap engines. Clocks not documented. CALC3/TBSOP01/02 are full microcontrollers with internal ROM—require ROM extraction.

---

### 5. Taito B
**Games**: Undrfire, Bloodshed, Nastar, Violence Fight, etc.
**MAME Driver**: `src/mame/taito/taito_b.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 12 MHz (24MHz ÷ 2) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 4-6 MHz (16-24MHz ÷ 4-6) | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2610 | 8 MHz (16MHz ÷ 2) | ✅ HAVE | jt10 (jtcores) |
| **Sound Gen** | YM2610-B | — | ✅ HAVE | jt10 (jtcores) |
| **Sound Gen** | YM2203 | 3 MHz (24MHz ÷ 8) | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | OKI MSM6295 | 1.056 MHz (4.224MHz ÷ 4) | ✅ HAVE | jt6295 (jtcores) |
| **DAC** | YM3014 / YM3014B | 1 MHz (24MHz ÷ 24) | ✅ HAVE | Simple circuit |
| **Video Gen** | TC0180VCU (Tilemap) | — | ⚠️ NEED | Community docs available |
| **Palette** | TC0260DAR | — | ⚠️ NEED | None |
| **I/O** | TC0220IOC | — | ⚠️ NEED | None |
| **I/O** | TC0040IOC (coin/ctrl) | — | ⚠️ NEED | None |
| **I/O** | TC0640FIO (EPROM games) | — | ⚠️ NEED | None |
| **CPU Link** | PC060HA (68K↔Z80) | — | ⚠️ NEED | None |
| **Audio Driver** | MB3735 (power amp) | — | ✅ HAVE | Simple circuit |

**Notes**: TC0180VCU is key to tile/sprite rendering. Oscillators: 27.164 MHz (video), 24 MHz (main), 16 MHz (sound). Multiple I/O variants across board revisions.

---

### 6. Taito X
**Games**: Daisenpu, Gigandes, Kyuukyoku, Superman, Balloon Brothers, etc.
**MAME Driver**: `src/mame/taito/taito_x.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 8-12 MHz (16-12MHz base) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 4-6 MHz | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2610 | 8 MHz (Superman, Gigandes) | ✅ HAVE | jt10 (jtcores) |
| **Sound Gen** | YM2151 | — (Daisenpu) | ✅ HAVE | jt51 (jtcores) |
| **DAC** | YM3012 / YM3014 / YM3016 | — | ✅ HAVE | Simple circuit |
| **Graphics** | X1-001A (Sprite gen, SETA) | — | ⚠️ NEED | SETA custom |
| **Graphics** | X1-002A (Graphics ctrl, SETA) | — | ⚠️ NEED | SETA custom |
| **Graphics** | X1-004 (Video proc, SETA) | — | ⚠️ NEED | SETA custom |
| **Graphics** | X1-006 (SETA) | — | ⚠️ NEED | SETA custom |
| **Graphics** | X1-007 (SETA) | — | ⚠️ NEED | SETA custom |
| **Protection** | Taito C-Chip (Superman) | — | ⚠️ NEED | Taito custom |
| **Sound Link** | TC0140SYT (68K↔Z80) | — | ⚠️ NEED | None |

**Notes**: X1-series are SETA custom chips (likely same cores as Seta1/2 systems). C-Chip is Taito protection on Superman. Oscillator: 16 MHz (most) or 12 MHz (Superman).

---

## PHASE 1-3 (Next 4 systems)

### 7. Raizing (Toaplan variants)
**Games**: Battle Garegga, Bakuretsu Breaker, Mahjan Gakuen, etc.
**MAME Driver**: `src/mame/toaplan/raizing.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 10-12 MHz (est) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 3.6-4 MHz (est) | ✅ HAVE | T80 (jtcores) |
| **Video** | GP9001 VDP | 27 MHz (est) | ✅ HAVE | Our build |
| **Text Tilemap** | Toaplan Text Device | 27 MHz | ⚠️ NEED | Community (partial) |
| **Sound Gen** | OKI M6295 (×2) | 1-4 MHz (est) | ✅ HAVE | jt6295 (jtcores) |
| **Bank Control** | NMK112-style GAL | — | ⚠️ NEED | Programmable logic |
| **I/O** | Coincounter | — | ⚠️ NEED | Behavioral model |

**Notes**: Clock frequencies not explicitly documented in MAME. Likely shares GP9001 VDP with Batsugun. OKI banking similar to NMK16 but possibly simplified.

---

### 8. Afega (NMK16 variant)
**Games**: Firehawk, Extreme Downhill, etc.
**MAME Driver**: `src/mame/nmk/afega.cpp` (or nmk16.cpp variants)

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 10-12 MHz | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 4 MHz | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2203 | 1.5 MHz | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | OKI M6295 (×2) | 1-4 MHz | ✅ HAVE | jt6295 (jtcores) |
| **Protection** | NMK004 or variant | — | ⚠️ NEED | None |
| **Protection** | NMK112 | — | ⚠️ NEED | None |
| **Video** | Standard RAM tilemap | — | ✅ HAVE | Core HDL |

**Notes**: Afega appears to be NMK16 successor with simplified PCB. May share much of NMK16 architecture. Requires board inspection for exact chip variants.

---

### 9. SETA 1
**Games**: Thundercross, Peisokon, Ultra Toukon Densetsu, etc.
**MAME Driver**: `src/mame/seta/seta.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 8-16 MHz | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 4 MHz | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | X1-010 (16-bit PCM) | 16 MHz base (÷2, ÷4, ÷8 outputs) | ⚠️ NEED | SETA custom |
| **Sound Gen** | OKI M6295 (bootlegs) | 1-4 MHz | ✅ HAVE | jt6295 (jtcores) |
| **Sound Gen** | YM3812 (Crazy Fight) | 4 MHz | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | YM3438 (variant) | — | ✅ HAVE | jt12 (jtcores) |
| **Sprite Gen** | X1-001, X1-001A (SDIP64) | 16 MHz | ⚠️ NEED | SETA custom |
| **Sprite Gen** | X1-002, X1-002A (SDIP64) | 16 MHz | ⚠️ NEED | SETA custom |
| **Palette** | X1-006 (SDIP64) | — | ⚠️ NEED | SETA custom |
| **Video** | X1-007 (SDIP42, RGB DACs) | — | ⚠️ NEED | SETA custom |
| **Mixer** | X1-011 (QFP100, ×2) | — | ⚠️ NEED | SETA custom |
| **Tilemap** | X1-012 (QFP100, ×2) | — | ⚠️ NEED | SETA custom |
| **Input** | X1-004 (SDIP52) | — | ⚠️ NEED | SETA custom |
| **Protection** | X1-005, X1-009 (DIP48) | — | ⚠️ NEED | SETA custom |
| **RTC** | UPD4992 or D4911C | — | ⚠️ NEED | Standard IC |
| **Trackball** | UPD4701 (gun games) | — | ⚠️ NEED | Standard IC |
| **ADC** | ADC0834 (gun games) | — | ✅ HAVE | Standard IC |
| **EEPROM** | DS2430A | — | ✅ HAVE | Standard IC |
| **Timer** | NEC D71054C | — | ⚠️ NEED | Standard IC |

**Notes**: X1-series are all SETA custom silicon. X1-010 is 16-bit PCM engine (key differentiator from OKI). Oscillator: 16 MHz base. Some games optional: RTC, trackball, ADC, EEPROM.

---

### 10. SETA 2
**Games**: Guardians, Gundamex, Reelquak, Staraudi, Telpacfl, etc.
**MAME Driver**: `src/mame/seta/seta2.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | TMP68301 (Toshiba 68HC000) | 16.67 MHz (50MHz ÷ 3) standard | ✅ HAVE | fx68k (jtcores) |
| **Main CPU** | TMP68301 | 16.27 MHz (32.53MHz ÷ 2) P0-113A variant | ✅ HAVE | fx68k (jtcores) |
| **Main CPU** | M68000 (ablastb bootleg) | 16 MHz | ✅ HAVE | fx68k (jtcores) |
| **Sound Gen** | X1-010 | 16.67 MHz (50MHz ÷ 3) standard | ⚠️ NEED | SETA custom |
| **Sound Gen** | X1-010 | 16.27 MHz (32.53MHz ÷ 2) P0-113A variant | ⚠️ NEED | SETA custom |
| **Sound Gen** | OKI M9810 (EVA2/EVA3) | — | ⚠️ NEED | None |
| **Graphics** | DX-101 or X1-020 (sprite/graphics) | 50 MHz | ⚠️ NEED | SETA custom |
| **Palette** | Palette device | 0x8000 + 0xf0 colors (555) | ✅ HAVE | Core HDL |
| **EEPROM** | 93C46 (gundamex only) | — | ✅ HAVE | Standard IC |
| **RTC** | UPD4992 (staraudi only) | — | ⚠️ NEED | Standard IC |
| **Flash** | Intel Flash 16-bit (staraudi) | — | ✅ HAVE | Standard IC |
| **Watchdog** | Watchdog timer | — | ✅ HAVE | Core HDL |
| **NVRAM** | Battery-backed (reelquak, telpacfl) | — | ✅ HAVE | Core HDL |
| **Ticket Dispenser** | Ticket mech (reelquak, telpacfl) | — | ⚠️ NEED | Behavioral model |

**Notes**: TMP68301 is Toshiba variant with integrated peripherals. Two PCB variants: 50 MHz (standard) and 32.53 MHz (P0-113A/P0-113B). DX-101/X1-020 likely next-gen GP9001-like sprite engine.

---

## PHASE 4-5 (Next 6 systems)

### 11. Video System (Aero Fighters)
**Games**: Aero Fighters, Twin Hawk, Gundalfs Kingdom, etc.
**MAME Driver**: `src/mame/vsystem/aerofgt.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 10 MHz (20MHz ÷ 2) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 5 MHz (20MHz ÷ 4) | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2610 | 8 MHz | ✅ HAVE | jt10 (jtcores) |
| **Sprite Engine** | VSYSTEM_SPR | 20 MHz | ⚠️ NEED | Video System custom |
| **Graphics Decoder** | GFXDECODE | — | ✅ HAVE | Core HDL |
| **Palette** | Palette device (xRGB_555, 1024 colors) | — | ✅ HAVE | Core HDL |
| **Watchdog** | MB3773 | — | ✅ HAVE | Standard IC |
| **I/O Controller** | VS9209 (8-port I/O) | — | ⚠️ NEED | Video System custom |
| **Sound Latch** | Generic Latch 8 (68K↔Z80) | — | ✅ HAVE | Core HDL |

**Notes**: Clean, straightforward architecture. VSYSTEM_SPR and VS9209 are proprietary. Oscillator: 20 MHz. Resolution: 512×224 @ 61.31 Hz.

---

### 12. DECO 16-bit (Dec0 / C-Ninja)
**Games**: Robocop, Hippodrome, Bad Dudes, Birdie Try, C-Ninja, Edrandy, Robocop2, Mutant Fighter, etc.
**MAME Drivers**: `src/mame/dataeast/dec0.cpp`, `cninja.cpp`

| Component | Chip (dec0) | Clock | Status | Source |
|-----------|-----------|-------|--------|--------|
| **Main CPU** | Motorola 68000P10 | 10 MHz (20MHz ÷ 2) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Ricoh R65C02A (or RP65C02A) | 1.5 MHz (12MHz ÷ 8) | ✅ HAVE | 6502 core |
| **Sound CPU** | Z80 (Automat bootleg) | 3 MHz | ✅ HAVE | T80 (jtcores) |
| **Sound CPU** | H6280 | 6 MHz (24MHz ÷ 4 or 12MHz ÷ 2) | ✅ HAVE | H6280 core |
| **Sound Gen** | YM2203 | 1.5 MHz (12MHz ÷ 8) | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | YM3812 | 3 MHz (12MHz ÷ 4) | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | OKI M6295 | 1 MHz (20MHz ÷ 2 ÷ 10) | ✅ HAVE | jt6295 (jtcores) |
| **Sound Gen** | MSM5205 (bootleg) | 384-400 kHz | ✅ HAVE | MSM5205 core |
| **MCU** | I8751 | 8 MHz | ⚠️ NEED | Intel 8051 |
| **MCU** | M68705R3 (bootleg) | 3.579545 MHz | ✅ HAVE | 6805 core |
| **Tilemap Gen** | DECO L7B0072 (BAC-06, QFP160/PGA) | — | ⚠️ NEED | DECO custom |
| **Sprite Gen** | DECO L7B0073 (MXC-06, QFP160/PGA) | — | ⚠️ NEED | DECO custom |
| **Protection** | DECO 45 / DEC-01 (HuC6280 disguise) | — | ⚠️ NEED | DECO/Hudson custom |
| **Protection** | DECO 49 (NEC DIP40 ULA) | — | ⚠️ NEED | DECO custom |
| **Protection** | DECO 47 (SDIP52 ASIC) | — | ⚠️ NEED | DECO custom |
| **SRAM** | DEM-01 (Fujitsu MB8421 dual-port, Robocop) | — | ✅ HAVE | Standard IC |
| **Input** | UPD4701 (X/Y encoder, Birdie Try) | — | ⚠️ NEED | Standard IC |

| Component | Chip (cninja) | Clock | Status | Source |
|-----------|-------------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 24 MHz (cninja, edrandy) / 28 MHz (robocop2, mutantf) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | H6280 | 4.0275 MHz (32.22MHz ÷ 8) | ✅ HAVE | H6280 core |
| **Sound CPU** | Z80 (stoneage, bootlegs) | 3.579545 MHz | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2203 | 4.0275 MHz (32.22MHz ÷ 8) | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | YM2151 | 3.58 MHz (32.22MHz ÷ 9) | ✅ HAVE | jt51 (jtcores) |
| **Sound Gen** | OKI M6295 | 1.00688 MHz (32.22MHz ÷ 32, PIN7_HIGH) or 2.01375 MHz (÷16) | ✅ HAVE | jt6295 (jtcores) |
| **Protection** | DECO104PROT (cninja variants, stoneage, cninjabl2) | — | ⚠️ NEED | DECO custom |
| **Protection** | DECO146PROT (edrandy, robocop2, mutantf) | — | ⚠️ NEED | DECO custom |
| **Tilemap Gen** | DECO16IC (×2) | — | ⚠️ NEED | DECO custom |
| **Sprite Gen** | DECO_SPRITE renderer | — | ⚠️ NEED | DECO custom |
| **Palette** | Palette device (xBGR_888, 2048 colors) | — | ✅ HAVE | Core HDL |

**Notes**: dec0 is earlier (10 MHz 68K), cninja is later (24-28 MHz 68K). Both require DECO custom graphics chips (BAC-06/MXC-06 or DECO16IC). Protection chips are complex. I8751 is Intel 8051 MCU variant—requires ROM extraction.

---

### 13. SNK Alpha 68K
**Games**: Alpha Mission, Alpha Mission II, SNK's Chopper I, etc.
**MAME Driver**: `src/mame/snk/alpha68k.cpp` (404 — needs alternate source)

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 8-10 MHz (est) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 2-4 MHz (est) | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2203 or YM3812 | 1.5-3 MHz (est) | ✅ HAVE | jt03/jt03 (jtcores) |
| **Sound Gen** | OKI M6295 | 1-2 MHz (est) | ✅ HAVE | jt6295 (jtcores) |
| **Protection** | SNK Security Chip (likely custom) | — | ⚠️ NEED | SNK custom |
| **Video** | Standard tilemap + sprite engine | — | ✅ HAVE | Core HDL |

**Notes**: MAME driver not accessible (404). Specifications estimated from SNK hardware patterns. Likely shares security architecture with other SNK 16-bit systems.

---

### 14. Seibu 68K (Raiden / Raiden II)
**Games**: Raiden, Raiden II, Raiden DX, etc.
**MAME Driver**: `src/mame/seibu/raiden.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Sony CXQ70116P-10 (NEC V30) | 10 MHz (20MHz ÷ 2) | ⚠️ NEED | V30 core |
| **Sub CPU** | NEC V30 | 10 MHz (20MHz ÷ 2) | ⚠️ NEED | V30 core |
| **Sound CPU** | Z80A | 14.318181MHz ÷ 4 ≈ 3.58 MHz | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM3812 (OPL) | 14.318181MHz ÷ 4 ≈ 3.58 MHz | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | OKI M6295 | 12 MHz ÷ 12, PIN7_HIGH | ✅ HAVE | jt6295 (jtcores) |
| **Protection** | SEI0160 (QFP60) | — | ⚠️ NEED | Seibu custom |
| **Protection** | S1S6091 or SEI0181 (QFP80) | — | ⚠️ NEED | Seibu custom |
| **Graphics** | EPLD: Altera EP910PC-40 | — | ⚠️ NEED | Altera FPGA |
| **Support** | SEI0050BU (DIP40) | — | ⚠️ NEED | Seibu custom |
| **Support** | SEI80BU (DIP42) | — | ⚠️ NEED | Seibu custom |
| **Support** | SEI0100BU "YM3931" | — | ⚠️ NEED | Seibu custom |
| **Support** | SEI0010BU TC17G008AN-0025 | — | ⚠️ NEED | Seibu custom |
| **Support** | SEI0021BU TC17G008AN-0022 | — | ⚠️ NEED | Seibu custom |
| **Support** | SG0140 TC110G05AN-0012 | — | ⚠️ NEED | Seibu custom |
| **Graphics** | CRTC (newer variants) | — | ⚠️ NEED | Seibu custom |

**Notes**: V30 is Intel 8086 clone (NEC extended instruction set). Korean bootleg uses 32 MHz XTAL ÷ 4 (8 MHz). Extensive custom Seibu silicon, many functions undocumented. Oscillators: 20 MHz (main/sub), 14.318181 MHz (sound), 12 MHz (OKI).

---

### 15. Metro
**Games**: Blazing Tornado, Grand Striker 2, Puzzlet, Metabee Shot, and many mahjong variants.
**MAME Driver**: `src/mame/metro/metro.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | MC68000 | — | ✅ HAVE | fx68k (jtcores) |
| **Main CPU** | H8/3007 (Puzzlet, Metabee) | — | ⚠️ NEED | H8/3007 core |
| **Main CPU** | Z80 (Blazing Tornado, Grand Striker 2) | — | ✅ HAVE | T80 (jtcores) |
| **Sound CPU** | NEC78C10 / uPD7810 | — | ⚠️ NEED | NEC 78C10 core |
| **Sound CPU** | Z80 (Blazing Tornado, Grand Striker 2) | — | ✅ HAVE | T80 (jtcores) |
| **Sound CPU** | Z86E02 (Puzzlet, Metabee) | — | ⚠️ NEED | Z86E02 core |
| **Sound Gen** | OKIM6295 | — | ✅ HAVE | jt6295 (jtcores) |
| **Sound Gen** | YM2413 | — | ✅ HAVE | jt11 (jtcores) |
| **Sound Gen** | YM2151 | — | ✅ HAVE | jt51 (jtcores) |
| **Sound Gen** | YMF278B | — | ✅ HAVE | jt278 (jtcores) |
| **Sound Gen** | YM2610 | — | ✅ HAVE | jt10 (jtcores) |
| **Sound Gen** | ES8712 | — | ⚠️ NEED | None |
| **Sound Gen** | YRW801-M | — | ⚠️ NEED | None |
| **Sound Gen** | M6585 | — | ⚠️ NEED | None |
| **Graphics** | Imagetek I4100 052 | — | ⚠️ NEED | Imagetek custom |
| **Graphics** | Imagetek I4220 071 | — | ⚠️ NEED | Imagetek custom |
| **Graphics** | Imagetek I4300 095 | — | ⚠️ NEED | Imagetek custom |
| **Graphics** | Konami 053936 PSAC2 (Blazing Tornado, Grand Striker 2) | — | ⚠️ NEED | Konami custom |
| **Memory Blitter** | Memory Blitter device | — | ⚠️ NEED | Imagetek custom |
| **Protection** | K053936 (rotation/scaling, Blazing Tornado) | — | ⚠️ NEED | Konami custom |
| **Watchdog** | Watchdog timer | — | ✅ HAVE | Core HDL |
| **Audio** | MSM5205 (some games) | — | ✅ HAVE | MSM5205 core |
| **Storage** | EEPROM (mahjong games) | — | ✅ HAVE | Standard IC |

**Notes**: Highly diverse game set across Imagetek and Konami hardware. Multiple CPU/sound chip combinations. Most Imagetek chips are undocumented. Clocks not explicitly listed in MAME driver.

---

### 16. Fuuki FG-2
**Games**: Gekirindan, Gyakuten Mortal Kombat, Go Go Mr. Yamagata, etc.
**MAME Driver**: `src/mame/fuuki/fuukifg2.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 16 MHz (32MHz ÷ 2) | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Z80 | 6 MHz (12MHz ÷ 2) | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | YM2203 | 3.58 MHz (28.64MHz ÷ 8) | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | YM3812 | 3.58 MHz (28.64MHz ÷ 8) | ✅ HAVE | jt03 (jtcores) |
| **Sound Gen** | OKI M6295 | 1 MHz (32MHz ÷ 32) | ✅ HAVE | jt6295 (jtcores) |
| **Graphics** | FI-002K (208-pin PQFP, GA2) | — | ⚠️ NEED | Fuuki custom |
| **Graphics** | FI-003K (208-pin PQFP, GA3) | — | ⚠️ NEED | Fuuki custom |
| **Protection** | Mitsubishi M60067-0901FP (208-pin PQFP, GA1) | — | ⚠️ NEED | Mitsubishi custom |
| **Sound Latch** | Generic Latch device | — | ✅ HAVE | Core HDL |

**Notes**: Clean architecture with three Fuuki custom chips (FI-002K, FI-003K, protection). Oscillators: 32 MHz (main), 28.64 MHz (sound), 12 MHz (Z80). All sound chips are standard Yamaha/OKI.

---

## PHASE 6-8 (Final 4 systems)

### 17. Konami GX
**Games**: Lethal Enforcers, Lethal Enforcers 2, Run & Gun, Sunset Riders, Violent Storm, etc.
**MAME Driver**: `src/mame/konami/konamigx.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | MC68EC020 | 24 MHz | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | MC68000 | 8 MHz (16MHz ÷ 2) | ✅ HAVE | fx68k (jtcores) |
| **Sound DSP** | TMS57002 (DASP) | 12 MHz (24MHz ÷ 2) | ⚠️ NEED | TMS57002 core |
| **Sound Gen** | K054539 (×2 PCM chips) | 18.432 MHz | ⚠️ NEED | Konami custom |
| **Sound Interface** | K056800 | 18.432 MHz | ⚠️ NEED | Konami custom |
| **Sound Gen** | OKIM6295 (bootleg) | 1.056 MHz | ✅ HAVE | jt6295 (jtcores) |
| **Tilemap Gen** | K056832 | — | ⚠️ NEED | Konami custom |
| **Tilemap Gen** | K054156 (legacy) | — | ⚠️ NEED | Konami custom |
| **Sprite Gen** | K053246 / K055673 | — | ⚠️ NEED | Konami custom |
| **Mixer** | K055555 | — | ⚠️ NEED | Konami custom |
| **Alpha Blending** | K054338 | — | ⚠️ NEED | Konami custom |
| **Timing Control** | K053252 (CCU) | 6 MHz (24MHz ÷ 4) | ⚠️ NEED | Konami custom |
| **Protection** | ESC (Security Chip) | custom MCU with external SRAM | ⚠️ NEED | Konami custom |
| **FPGA** | Xilinx (Type 4 boards) | Various models | ⚠️ NEED | Xilinx synthesis |
| **EEPROM** | 93C46 (16-bit) | — | ✅ HAVE | Standard IC |
| **ADC** | ADC0834 (Type 1 games, gun control) | — | ✅ HAVE | Standard IC |

**Notes**: Highly sophisticated Konami custom architecture. K054539 is dual PCM engine (high quality). K053252 is timing master. ESC is full microcontroller requiring ROM extraction. Xilinx FPGA on late boards requires synthesis/bitstream recovery.

---

### 18. IGS PGM
**Games**: Knights of Valor, Photo Y2K, Martial Masters, Spectral vs. Generation, etc.
**MAME Driver**: `src/mame/igs/pgm.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Motorola 68000 | 20 MHz | ✅ HAVE | fx68k (jtcores) |
| **Sound CPU** | Zilog Z80 | 8.468 MHz (33.8688MHz ÷ 4) | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | ICS2115 (WaveFront Wavetable MIDI Synth) | 33.8688 MHz | ⚠️ NEED | ICS2115 core |
| **Video Controller** | IGS023 | — | ⚠️ NEED | IGS custom |
| **Protection/Co-proc** | IGS027A (ARM-based MCU, internal ROM) | — | ⚠️ NEED | ARM core + IGS custom |
| **Protection** | IGS025 (state-based ROM overlay) | — | ⚠️ NEED | IGS custom |
| **Protection** | IGS012 (ROM overlay device) | — | ⚠️ NEED | IGS custom |
| **Protection** | IGS022 (encrypted DMA) | — | ⚠️ NEED | IGS custom |
| **Protection** | IGS028 (encrypted DMA) | — | ⚠️ NEED | IGS custom |
| **Custom IC** | IGS026 (QFP144, ×2) | — | ⚠️ NEED | IGS custom |
| **Custom IC** | IGS023 (QFP256) | — | ⚠️ NEED | IGS custom |
| **Protection** | ASIC 3 (state-based) | — | ⚠️ NEED | IGS custom |
| **RTC** | V3021 | 32.768 kHz | ✅ HAVE | Standard IC |
| **Coin Driver** | TD62064 (quad Darlington) | — | ✅ HAVE | Standard IC |
| **Audio Amp** | TDA1519A (stereo power) | — | ✅ HAVE | Standard IC |
| **DAC** | uPD6379 | — | ✅ HAVE | Standard IC |
| **Op-Amp** | uPC844C | — | ✅ HAVE | Standard IC |
| **Programmable Logic** | Atmel ATF16V8B or MACH211 (CPLD) | — | ⚠️ NEED | ABEL/VHDL synthesis |

**Notes**: Very complex protection architecture. IGS027A is full 32-bit ARM CPU (likely ARM7TDMI) with internal ROM—requires ROM extraction and ARM core implementation. ICS2115 is high-end wavetable synth (not simple MIDI, actual DSP). Oscillators: 33.8688 MHz (sound primary), 50 MHz (video), 20 MHz (main CPU).

---

### 19. Sega System 1
**Games**: Pengo, Astro Blaster, Sega Zaxxon, Space Invaders Part II, etc.
**MAME Driver**: `src/mame/sega/system1.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Z80 (Zilog Z8400A, Sharp LH0080A, NEC D780C-1) | 4 MHz (20MHz ÷ 5) | ✅ HAVE | T80 (jtcores) |
| **Main CPU** | Custom Z80 variants (315-5093, 315-5098, etc.) | 4 MHz | ✅ HAVE | T80 (jtcores) + decryption |
| **Main CPU** | MC8123 encryption variant | 4 MHz | ✅ HAVE | T80 (jtcores) + decryption |
| **Sound CPU** | Z80 | 4 MHz (8MHz ÷ 2) standard / 2 MHz / 1 MHz (variants) | ✅ HAVE | T80 (jtcores) |
| **MCU** | I8751 microcontroller | 8 MHz | ⚠️ NEED | Intel 8051 core |
| **Sound Gen** | SN76489A (×2) | 2 MHz (SOUND_CLOCK ÷ 4) and 4 MHz (÷2) | ✅ HAVE | jt49 (jtcores) |
| **I/O** | 8255 PPI (D8255) | — | ✅ HAVE | Core HDL |
| **I/O** | Z80 PIO (Z8420A, LH0081A) | 4 MHz | ✅ HAVE | T80 core + PIO |
| **Protection/Logic** | 315-5011, 315-5012, 315-5025, 315-5049, 315-5138, 315-5139, 315-5152 (PAL/custom) | — | ⚠️ NEED | ABEL/VHDL synthesis |
| **Graphics** | Character ROM-based tilemap | — | ✅ HAVE | Core HDL |
| **Palette** | 256 colors (3-bit from 3 ROM regions) | — | ✅ HAVE | Core HDL |

**Notes**: Simple, foundational arcade system (1985-1986 era). All CPUs are Z80-based. Multiple encryption variants (custom Z80, MC8123). SN76489A is simple 4-channel PSG (common in arcade/console). I8751 optional on some games (requires ROM extraction). Oscillators: 20 MHz (main), 8 MHz (sound), 8 MHz (MCU).

---

### 20. Bally MCR (Midway Classics Arcade)
**Games**: Robotron 2084, Stargate, Defender, Sinistar, Joust, Lunar Lander, etc.
**MAME Driver**: `src/mame/midway/mcr.cpp`

| Component | Chip | Clock | Status | Source |
|-----------|------|-------|--------|--------|
| **Main CPU** | Z80 | 2.5 MHz (boards 90009, 90010) / 5.0 MHz (boards 91442, 91490) | ✅ HAVE | T80 (jtcores) |
| **Sound CPU** | Z80 | 2.0 MHz | ✅ HAVE | T80 (jtcores) |
| **IPU** | Z80 (NFL Football only) | 3.686 MHz (7372800 ÷ 2) | ✅ HAVE | T80 (jtcores) |
| **Sound Gen** | AY-8910 (×2) | 2.0 MHz | ✅ HAVE | jt49 (jtcores) |
| **Timing Control** | Z80CTC (Counter/Timer) | 2.5 MHz or 5.0 MHz (matches CPU) | ✅ HAVE | T80 CTC core |
| **I/O** | Z80PIO (×2 on IPU) | 3.686 MHz (IPU) | ✅ HAVE | T80 PIO core |
| **I/O** | Z80SIO (Serial I/O, IPU) | 3.686 MHz | ✅ HAVE | T80 SIO core |
| **Video Gen** | Background tilemap (tile-based) | — | ✅ HAVE | Core HDL |
| **Video Gen** | Foreground sprites (MCR/II Video Gen board) | — | ✅ HAVE | Core HDL |
| **Watchdog** | 16 VBlank counter | — | ✅ HAVE | Core HDL |
| **NVRAM** | Battery-backed | — | ✅ HAVE | Core HDL |
| **Auxiliary Boards** | Squawk n' Talk (91660) | — | ⚠️ NEED | Behavioral model |
| **Auxiliary Boards** | Turbo Cheap Squeak (91799) | — | ⚠️ NEED | Behavioral model |
| **Auxiliary Boards** | IPU Laserdisk (91695, NFL Football only) | — | ⚠️ NEED | Behavioral model |
| **Auxiliary Boards** | Lamp Sequencer (91658, Discs of Tron) | — | ⚠️ NEED | Behavioral model |

**Notes**: Elegant modular architecture. All logic on Z80 + simple TTL/PAL glue. Four separate PCB variants with different clock speeds. AY-8910 is Yamaha 3-channel PSG. CTC/PIO/SIO are Z80 peripheral ICs (standard family). Squawk n' Talk, Turbo Cheap Squeak, IPU boards are optional game-specific expansions. No dedicated graphics chips—entirely RAM + ROM tilemap + sprite framebuffer.

---

## CHIP IMPLEMENTATION STATUS MATRIX

### Available from jotego/jtcores (✅ HAVE)

| Chip Family | jtcores Name | Status | Notes |
|-------------|-------------|--------|-------|
| **CPU: 68K** | fx68k | ✅ DONE | Cycle-accurate, all variants |
| **CPU: Z80** | T80 | ✅ DONE | With CTC, PIO, SIO variants |
| **CPU: 6502** | T65 | ✅ DONE | Ricoh RP65C02 compatible |
| **CPU: H6280** | h6280 | ✅ DONE | Hudson/PC Engine CPU |
| **CPU: H8/3007** | h8_3007 | ❓ CHECK | Might exist in jotego ecosystem |
| **CPU: TMS57002** | tms57002 | ❓ CHECK | Might exist; DSP is complex |
| **CPU: V30** | v30 | ❓ CHECK | Intel 8086 clone; rare |
| **Sound: YM2203** | jt03 | ✅ DONE | FM synth, 2 channel |
| **Sound: YM2151** | jt51 | ✅ DONE | FM synth, 4 channel |
| **Sound: YM2610** | jt10 | ✅ DONE | FM + ADPCM, 4+ADPCM channel |
| **Sound: YM2612** | jt12 | ✅ DONE | FM + ADPCM, 6 channel |
| **Sound: YM3812** | jt03 | ✅ DONE | OPL, 2 channel (jt03 variant) |
| **Sound: YM3438** | jt12 | ✅ DONE | OPL2, 2 channel (jt12 variant) |
| **Sound: YMF278B** | jt278 | ✅ DONE | OPL3 + WaveFront wavetable |
| **Sound: YM2413** | jt11 | ✅ DONE | OPLL, 9 channel |
| **Sound: OKI M6295** | jt6295 | ✅ DONE | 4-channel ADPCM sampler |
| **Sound: PSG SN76489A** | jt49 | ✅ DONE | 3-channel + noise |
| **Sound: PSG AY-8910** | jt49 | ✅ DONE | 3-channel + noise |
| **Sound: MSM5205** | msm5205 | ✅ DONE | ADPCM sampler |
| **Video: Gfx Decoder** | gfxdecode | ✅ DONE | Tile/sprite ROM decoder |
| **Video: Palette** | palette_device | ✅ DONE | Color palette RAM |

### Our builds (✅ HAVE, in this project)

| Chip | System | Status | Notes |
|------|--------|--------|-------|
| **GP9001 VDP** | Toaplan V2 / Raizing | ✅ DONE | Session 14 validation |
| **DX-101/X1-020** | SETA 2 | ⚠️ PARTIAL | Likely variant of GP9001 |

### Must Build (⚠️ NEED)

| Chip Family | Systems | Priority | Notes |
|-------------|---------|----------|-------|
| **V30 CPU** | Seibu Raiden | HIGH | Intel 8086 clone; used in 2-CPU setup |
| **78C10 CPU** | Metro | MEDIUM | NEC microcontroller |
| **TMS57002 DSP** | Konami GX | HIGH | Audio DSP; complex |
| **NMK004** | NMK16 | HIGH | Protection + watchdog; may have patched variants |
| **NMK112** | NMK16 / Afega | HIGH | OKI banking controller |
| **Text Tilemap** | Toaplan V2 / Raizing | MEDIUM | Text layer renderer |
| **X1-010 PCM** | SETA 1 / SETA 2 | HIGH | 16-bit PCM sound (core differentiator) |
| **X1-001/X1-002** | SETA 1 / Taito X | HIGH | Sprite generators |
| **X1-004/X1-006/X1-007** | SETA 1 | MEDIUM | Input / palette / video blanking |
| **X1-011/X1-012** | SETA 1 | MEDIUM | Mixer / tilemap |
| **X1-005/X1-009** | SETA 1 | LOW | NVRAM / protection (simple) |
| **DX-101** | SETA 2 | HIGH | Next-gen sprite/graphics processor |
| **TC0180VCU** | Taito B | HIGH | Tilemap controller (well-documented) |
| **TC0260DAR** | Taito B | MEDIUM | Palette + RGB output |
| **TC0220IOC/TC0040IOC/TC0640FIO** | Taito B | MEDIUM | I/O controllers (variant) |
| **PC060HA** | Taito B | MEDIUM | 68K↔Z80 communication |
| **VU-series (001/002/003)** | Kaneko16 | HIGH | Graphics processors (3 chips) |
| **VIEW2-CHIP** | Kaneko16 | MEDIUM | Tilemap processor |
| **MUX2-CHIP / HELP1-CHIP** | Kaneko16 | LOW | Support chips |
| **CALC3 MCU** | Kaneko16 | HIGH | NEC uPD78322 microcontroller (16K ROM) |
| **TBSOP01/02 MCU** | Kaneko16 | MEDIUM | NEC uPD78324 microcontroller (32K ROM) |
| **VSYSTEM_SPR** | Video System | MEDIUM | Sprite engine |
| **VS9209** | Video System | MEDIUM | 8-port I/O controller |
| **DECO L7B0072/L7B0073** | DECO 16-bit | HIGH | Tilemap + sprite generators (BAC-06/MXC-06) |
| **DECO 45/47/49** | DECO 16-bit | HIGH | Protection + graphics support ASICs |
| **DECO16IC** | DECO C-Ninja | HIGH | Tilemap/sprite controller (later variant) |
| **I8751 MCU** | Many systems (dec0, Sega System 1) | HIGH | Intel 8051 microcontroller (ROM extraction required) |
| **SEI series (0160/0181/0050/80/0100/0010/0021)** | Seibu Raiden | HIGH | Protection + graphics support chips (7+ custom ICs) |
| **Altera EPLD** | Seibu Raiden | MEDIUM | Programmable logic; synthesis required |
| **Imagetek I4100/I4220/I4300** | Metro | HIGH | Graphics processors (3 chips) |
| **ICS2115** | IGS PGM | HIGH | WaveFront wavetable MIDI synthesizer (DSP) |
| **IGS023/025/026/027A/028** | IGS PGM | HIGH | Video + protection chips (5+ chips); IGS027A is ARM MCU |
| **Konami K054539** | Konami GX | HIGH | Dual PCM sound engine (advanced) |
| **Konami K056832/K054156** | Konami GX | HIGH | Tilemap generators |
| **Konami K053246/K055673** | Konami GX | HIGH | Sprite generator combo |
| **Konami K055555** | Konami GX | HIGH | Mixer/priority encoder |
| **Konami K054338** | Konami GX | HIGH | Alpha blending engine |
| **Konami K053252** | Konami GX | MEDIUM | Timing controller (CCU) |
| **ESC Security Chip** | Konami GX | HIGH | Custom microcontroller with external SRAM (ROM extraction) |
| **Xilinx FPGA** | Konami GX (Type 4) | MEDIUM | Bitstream recovery + re-synthesis |
| **FI-002K / FI-003K** | Fuuki FG-2 | MEDIUM | Graphics processors (2 chips) |
| **Mitsubishi M60067** | Fuuki FG-2 | MEDIUM | Protection chip |
| **PIC16C57 MCU** | Psikyo | LOW | Optional; only some boards |
| **PS2001B/PS3103/PS3204/PS3305** | Psikyo | HIGH | Video/sprite controllers (4 chips) |
| **Coincounter device** | Toaplan / NMK | LOW | Behavioral model (simple) |

---

## SUMMARY BY BUILD PHASE

### Phase 0: ALREADY DONE or NEARLY DONE
- ✅ NMK16: Need NMK004, NMK112 (protection/banking)
- ✅ Toaplan V2: GP9001 done; need V25, Text Tilemap, bootleg variants
- ⚠️ Psikyo: Need PS-series (4 chips), PIC16C57 (optional)
- ⚠️ Kaneko16: Need VU-series (6 chips), CALC3/TBSOP MCUs
- ⚠️ Taito B: Need TC0-series (6 chips), I/O variants
- ⚠️ Taito X: Need X1-series (SETA, 5 chips), C-Chip

### Phase 1-3: MEDIUM EFFORT
- ⚠️ Raizing: Shares GP9001 with Toaplan V2; need Text Tilemap, NMK112, banking details
- ⚠️ Afega: NMK16 successor; need NMK004, NMK112 variants
- ⚠️ SETA 1: Need X1-010 (PCM), X1-series (6 chips total)
- ⚠️ SETA 2: TMP68301 CPU okay; need DX-101, X1-010 variants
- ⚠️ Video System: Need VSYSTEM_SPR, VS9209; clean architecture
- ⚠️ DECO 16-bit: Need L7B0072/73, protection ASICs; I8751 MCU extraction

### Phase 4-5: HIGH EFFORT
- ⚠️ SNK Alpha 68K: Specifications missing (404); estimate from patterns
- ⚠️ Seibu Raiden: V30 CPU, 7+ Seibu custom ICs, EPLD synthesis
- ⚠️ Metro: Diverse CPU/sound combos; Imagetek I4xxx, Konami K053936
- ⚠️ Fuuki FG-2: FI-002K/003K, M60067; relatively clean
- ⚠️ Konami GX: TMS57002 DSP, K054539 dual PCM, K05xxx series (6+ chips), ESC MCU, Xilinx FPGA

### Phase 6-8: MAXIMUM EFFORT
- ⚠️ IGS PGM: ICS2115 wavetable DSP, IGS027A ARM CPU, 5+ protection ICs (encryption heavy)
- ⚠️ Sega System 1: Simple architecture BUT multiple encryption Z80 variants, I8751 MCU
- ⚠️ Bally MCR: Modular design; 4 CPU clock variants, optional laserdisk + lamp boards

---

## RESEARCH GAPS & NEXT STEPS

**High Priority (blocks multiple systems)**:
1. **V30 CPU core**: Used in Seibu Raiden (2-CPU setup). Is there a public RTL core? Otherwise, start from scratch.
2. **Protection chips (custom MCUs with internal ROM)**: NMK004, CALC3, TBSOP01/02, I8751, IGS027A, ESC, SCAN MCU.
   - Solution: Extract ROM from PCBs or find dumped ROM images in arcade databases.
   - Impact: 12+ games blocked until solved.
3. **Proprietary graphics chips (undocumented)**:
   - DECO L7B0072/73: Community disassembly or reverse-engineer from MAME simulation.
   - SETA X1-series: MAME has behavioral simulation; can extract from source or reverse-engineer.
   - Imagetek I4xxx: Complex; MAME simulation is reference.
   - Konami K05xxx: Well-studied by community; Ghidra + MAME source.
   - IGS023/025/026/028: Encrypted; requires RAM dump comparison with actual hardware.
4. **DSPs (TMS57002, ICS2115)**: High-end audio engines. Public cores may exist in Verilator or community.

**Medium Priority**:
1. Document clock frequencies for systems missing explicit timing (Psikyo, Metro, etc.).
2. Identify which variant of standard chips (YM2610-B, YMF278B, etc.) each system uses.
3. Map I/O controller variants (TC0220IOC vs. TC0040IOC vs. TC0640FIO) to specific games.

**Low Priority**:
1. Bootleg variant analysis (many use simpler chips, fewer protection layers).
2. Regional/version differences (some chips swapped between main/bootleg/later versions).

---

## CONTACT POINTS FOR COMMUNITY RESEARCH

- **MAME source**: https://github.com/mamedev/mame (official reference for all chip lists)
- **jotego/jtcores**: https://github.com/jotego/jtcores (CPU cores + sound chips)
- **Data Crystal wiki**: https://www.smspower.org/mamedev/ (arcade hardware documentation)
- **Ghidra+MAME**: For disassembling protection chip firmware (if ROM extracted)
- **Community disassemblies**:
  - Raiden: seibu-arcade wiki
  - DECO games: Arcade preservation project
  - Konami GX: Konami hardware wiki
  - IGS PGM: PGM emulator communities

---

**BOM compiled from MAME source analysis (2026-03-20).**
**Last updated**: Session briefing ready for MiSTer FPGA synthesis planning.
