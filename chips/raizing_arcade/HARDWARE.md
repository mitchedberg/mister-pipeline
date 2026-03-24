# Raizing — Hardware Profile

*Corrected from MAME `toaplan/raizing.cpp` — 2026-03-22*
*Previous version was WRONG: it referenced `twincobr.cpp` (Twin Cobra / Flying Shark, 1987),
 which is a completely different Toaplan hardware family with no GP9001 and no relation to Raizing.*

---

## Overview

The **Raizing** arcade hardware family was developed by Raizing/8ing, using the Toaplan GP9001 VDP.
All three boards share the same core architecture (MC68000 + Z80 + GP9001) but differ in audio
subsystem and GP9001 configuration.

MAME driver: `src/mame/toaplan/raizing.cpp`
Driver classes: `bgaregga_state`, `batrider_state`, `bbakraid_state`

---

## Games: 3 Boards, 10+ ROM Sets

### Board RA9503 — Battle Garegga (1996)

| MAME set | Title | Year | Notes |
|----------|-------|------|-------|
| bgaregga | Battle Garegga (World) | 1996 | Reference set |
| bgareggahk | Battle Garegga (Hong Kong) | 1996 | Region variant |
| bgareggat | Battle Garegga (Taiwan) | 1996 | Region variant |
| bgareggaj | Battle Garegga (Japan) | 1996 | Region variant |
| bgareggaa | Battle Garegga (Austria) | 1996 | Region variant |

### Board RA9704 — Armed Police Batrider (1998)

| MAME set | Title | Year | Notes |
|----------|-------|------|-------|
| batrider | Armed Police Batrider (World Ver. B) | 1998 | Reference set |
| batriderb | Armed Police Batrider (World Ver. B alt) | 1998 | Alt set |
| batrideru | Armed Police Batrider (USA Ver. B) | 1998 | Region variant |
| batriderj | Armed Police Batrider (Japan Ver. B) | 1998 | Region variant |
| batriderk | Armed Police Batrider (Korea Ver. B) | 1998 | Region variant |

### Board RA9903 — Battle Bakraid (1999)

| MAME set | Title | Year | Notes |
|----------|-------|------|-------|
| bbakraid | Battle Bakraid (International) | 1999 | Reference set |
| bbakradu | Battle Bakraid (Unlimited Version) | 1999 | Alt set |
| bbakraidj | Battle Bakraid (Japan) | 1999 | Region variant |

---

## CPUs (all boards)

| Type | Tag | Clock | Notes | Status |
|------|-----|-------|-------|--------|
| MC68000 | maincpu | 16 MHz (32 MHz XTAL / 2) | Main CPU | HAVE |
| Z80 | audiocpu | 4 MHz (32 MHz XTAL / 8) | Sound CPU | HAVE |

---

## Sound Chips — differs by board

### Battle Garegga (RA9503)

| Type | Tag | Clock | Notes | Status |
|------|-----|-------|-------|--------|
| YM2151 | ymsnd | 3.375 MHz (27 MHz / 8) | FM synthesis | HAVE (jt51) |
| OKI M6295 | oki | 1 MHz (32 MHz / 32) | ADPCM samples | HAVE (jt6295) |

### Batrider / Battle Bakraid (RA9704 / RA9903)

| Type | Tag | Clock | Notes | Status |
|------|-----|-------|-------|--------|
| YMZ280B | ymsnd | 16.9344 MHz | 8-channel ADPCM/PCM | NEED |

Note: The task checklist referenced "ym3812" — this is INCORRECT for all Raizing boards.
Battle Garegga uses YM2151 (not YM3812). Batrider and Bakraid use YMZ280B. There is NO
ym3812 chip on any Raizing board. The ym3812 is found on twincobr.cpp boards (Flying Shark /
Twin Cobra), which is what the previous HARDWARE.md was accidentally documenting.

---

## Video Chip (all boards)

| Type | Tag | Config | Notes | Status |
|------|-----|--------|-------|--------|
| GP9001 VDP | gp9001 | see below | Custom Toaplan tile+sprite processor | HAVE |

### GP9001 Configuration Differences

| Board | OBJECTBANK_EN | Tile ROM Size | Notes |
|-------|--------------|---------------|-------|
| RA9503 (bgaregga) | 0 (disabled) | 8MB (4 × 2MB) | Standard 10-bit tile codes, no banking |
| RA9704 (batrider) | 1 (enabled) | 12MB (6 × 2MB) | 8-slot bank table, 14-bit effective tile codes |
| RA9903 (bbakraid) | 1 (enabled) | 14MB (7 × 2MB) | 8-slot bank table, 14-bit effective tile codes |

---

## Other Hardware

| Type | Notes | Board | Status |
|------|-------|-------|--------|
| GAL16V8 × 5 | OKI ADPCM ROM bank switching | RA9503, RA9704 | HAVE (gal_oki_bank.sv) |
| ExtraText DMA | Batch text tile DMA (TVRMCTL7 at 0x300030) | RA9704, RA9903 | NEED |
| EEPROM | Stores settings (replaces DIP switches) | RA9903 only | NEED |
| toaplan_txtilemap | Separate 8×8 text tilemap layer | all | NEED |

---

## Memory Map: Battle Garegga (bgaregga_state)

### 68000 Main CPU

| Start | End | Size | Access | Description |
|-------|-----|------|--------|-------------|
| 0x000000 | 0x0FFFFF | 1MB | R | Program ROM (SDRAM bank 0) |
| 0x100000 | 0x10FFFF | 64KB | RW | Work RAM |
| 0x218000 | 0x21BFFF | 16KB | RW | Z80 shared RAM (byte-wide, even bytes) |
| 0x21C01D | 0x21C01D | 1B | W | Coin counter write |
| 0x21C020 | 0x21C021 | 2B | R | IN1 (joystick 1) |
| 0x21C024 | 0x21C025 | 2B | R | IN2 (joystick 2) |
| 0x21C028 | 0x21C029 | 2B | R | SYS (coin, start, service) |
| 0x21C02C | 0x21C02D | 2B | R | DSWA (DIP switch A) |
| 0x21C030 | 0x21C031 | 2B | R | DSWB (DIP switch B) |
| 0x21C034 | 0x21C035 | 2B | R | JMPR (jumper/region select) |
| 0x21C03C | 0x21C03D | 2B | R | GP9001 scanline counter (vdpcount_r) |
| 0x300000 | 0x30000D | 14B | RW | GP9001 VDP registers |
| 0x400000 | 0x400FFF | 4KB | RW | Palette RAM |
| 0x500000 | 0x501FFF | 8KB | RW | Text tilemap VRAM |
| 0x502000 | 0x502FFF | 4KB | RW | Text line select RAM |
| 0x503000 | 0x5031FF | 512B | RW | Text line scroll RAM |
| 0x600001 | 0x600001 | 1B | W | Sound latch write (byte, to Z80) |

### Z80 Sound CPU

| Start | End | Size | Access | Description |
|-------|-----|------|--------|-------------|
| 0x0000 | 0x7FFF | 32KB | R | Sound ROM (fixed) |
| 0x8000 | 0xBFFF | 16KB | R | Sound ROM (banked, 4-bit reg at 0xE00A, 8 × 16KB pages) |
| 0xC000 | 0xDFFF | 8KB | RW | Shared RAM (with 68K at 0x218000) |
| 0xE000 | 0xE001 | 2B | RW | YM2151 address/data ports |
| 0xE004 | 0xE004 | 1B | RW | OKI M6295 data port |
| 0xE006 | 0xE008 | 3B | W | GAL OKI bank registers |
| 0xE00A | 0xE00A | 1B | W | Z80 ROM bank register (4-bit, selects 16KB page) |
| 0xE00C | 0xE00C | 1B | W | Sound latch acknowledge |
| 0xE01C | 0xE01C | 1B | R | Sound latch read (from 68K) |
| 0xE01D | 0xE01D | 1B | R | IRQ pending status |

---

## Memory Map: Batrider / Battle Bakraid (batrider_state / bbakraid_state)

### 68000 Main CPU

| Start | End | Size | Access | Description |
|-------|-----|------|--------|-------------|
| 0x000000 | 0x1FFFFF | 2MB | R | Program ROM (SDRAM bank 0) |
| 0x200000 | 0x20FFFF | 64KB | RW | Work RAM |
| 0x300000 | 0x30000D | 14B | RW | GP9001 VDP registers (read/write) |
| 0x300014 | 0x300014 | 1B | R | Sound latch read (byte, from Z80) |
| 0x300018 | 0x300019 | 2B | R | GP9001 scanline counter (vdpcount_r) |
| 0x30001A | 0x30001A | 1B | W | Coin counter / IO write |
| 0x30001C | 0x30001D | 2B | R | IN1 (joystick 1) |
| 0x30001E | 0x30001F | 2B | R | IN2 (joystick 2) |
| 0x300020 | 0x300021 | 2B | R | SYS (coin, start, service) |
| 0x300022 | 0x300023 | 2B | R | DSWA (DIP switch A) |
| 0x300024 | 0x300025 | 2B | R | DSWB (DIP switch B) |
| 0x300026 | 0x300027 | 2B | R | JMPR (jumper/region select) |
| 0x300030 | 0x300031 | 2B | W | ExtraText DMA address register (TVRMCTL7) |
| 0x400000 | 0x400FFF | 4KB | RW | Palette RAM |
| 0x500000 | 0x50000F | 16B | W | Object bank registers (GP9001_OP_OBJECTBANK_WR) |
| 0x600001 | 0x600001 | 1B | W | Sound latch write (byte, to Z80) |
| 0x700000 | 0x703FFF | 16KB | RW | Text tilemap VRAM (ExtraText DMA destination) |

Note: bbakraid_state (Battle Bakraid) also adds EEPROM at 0x300028–0x30002B (93C66A).

### Z80 Sound CPU (Batrider)

| Start | End | Size | Access | Description |
|-------|-----|------|--------|-------------|
| 0x0000 | 0x7FFF | 32KB | R | Sound ROM (fixed) |
| 0x8000 | 0xBFFF | 16KB | R | Sound ROM (banked, 4-bit reg at 0xE00A) |
| 0xC000 | 0xCFFF | 4KB | RW | Shared RAM (with 68K at 0x300014/0x600001) |
| 0xE000 | 0xE001 | 2B | RW | YMZ280B address/data ports |
| 0xE002 | 0xE003 | 2B | RW | YMZ280B data port (alt) |
| 0xE004 | 0xE006 | 3B | W | GAL OKI bank registers (batrider only) |
| 0xE00A | 0xE00A | 1B | W | Z80 ROM bank register (write, 4-bit) |
| 0xE00C | 0xE00C | 1B | W | Sound latch acknowledge |
| 0xE01C | 0xE01C | 1B | R | Sound latch read (from 68K) |

---

## SDRAM Layout

### Battle Garegga (bgaregga)

| ROM Index | SDRAM Offset | Size | Contents |
|-----------|-------------|------|----------|
| 0 (CPU) | 0x000000 | 1MB | 68K program ROM (prg0.bin [even] + prg1.bin [odd]) |
| 1 (GFX) | 0x100000 | 8MB | GP9001 tile ROMs (rom4, rom3, rom2, rom1 — each 2MB) |
| 2 (SND) | 0x900000 | 128KB | Z80 audio ROM (snd.bin) |
| 3 (OKI) | 0x920000 | 1MB | OKI M6295 ADPCM samples (rom5.bin) |
| 4 (TXT) | 0xA20000 | 32KB | Text tilemap ROM (text.u81) |

### Batrider (batrider)

| ROM Index | SDRAM Offset | Size | Contents |
|-----------|-------------|------|----------|
| 0 (CPU) | 0x000000 | 2MB | 68K program ROM |
| 1 (GFX) | 0x200000 | 12MB | GP9001 tile ROMs (6 × 2MB) |
| 2 (SND) | 0xE00000 | 256KB | Z80 audio ROM |
| 3 (PCM) | 0xE40000 | 1MB | YMZ280B ADPCM sample ROM |
| 4 (TXT) | 0xF40000 | 32KB | Text tilemap ROM |

### Battle Bakraid (bbakraid)

| ROM Index | SDRAM Offset | Size | Contents |
|-----------|-------------|------|----------|
| 0 (CPU) | 0x000000 | 2MB | 68K program ROM |
| 1 (GFX) | 0x200000 | 14MB | GP9001 tile ROMs (7 × 2MB) |
| 2 (SND) | 0x1000000 | 256KB | Z80 audio ROM (exceeds 24-bit; needs extended bank) |
| 3 (PCM) | 0x1040000 | 2MB | YMZ280B ADPCM sample ROM |
| 4 (TXT) | 0x1240000 | 32KB | Text tilemap ROM |

---

## Chip Status Summary

### Battle Garegga (bgaregga_state)

| Chip | Status | Notes |
|------|--------|-------|
| MC68000 (fx68k) | HAVE | Production-quality, shared across all cores |
| Z80 (T80) | HAVE | Shared across all cores |
| GP9001 VDP | HAVE | `chips/gp9001/rtl/gp9001.sv`, OBJECTBANK_EN=0 |
| YM2151 | HAVE | `jtcores/modules/jt51` |
| OKI M6295 | HAVE | `jtcores/modules/jt6295` |
| GAL OKI banking | HAVE | `chips/raizing_arcade/rtl/gal_oki_bank.sv` |
| toaplan_txtilemap | NEED | Separate 8×8 text layer, not part of GP9001 |

### Batrider / Battle Bakraid (batrider_state / bbakraid_state)

| Chip | Status | Notes |
|------|--------|-------|
| MC68000 (fx68k) | HAVE | Shared |
| Z80 (T80) | HAVE | Shared |
| GP9001 VDP | HAVE | `chips/gp9001/rtl/gp9001.sv`, OBJECTBANK_EN=1 |
| YMZ280B | NEED | 8-channel ADPCM; stub in `ymz280b.sv` (incomplete) |
| GAL OKI banking | HAVE | `chips/raizing_arcade/rtl/gal_oki_bank.sv` (Batrider only) |
| ExtraText DMA | NEED | TVRMCTL7 batch text DMA |
| toaplan_txtilemap | NEED | Separate 8×8 text layer |
| EEPROM (93C66A) | NEED | Battle Bakraid only |

**Feasibility: YES** — Most chips already available. YMZ280B is the only major missing core
component. Battle Garegga is more feasible near-term (uses jt51 + jt6295, both available).

---

## Interrupt Routing (all boards)

| Level | Source | Notes |
|-------|--------|-------|
| IPL2 (level 6) | GP9001 VBLANK | Primary game interrupt; use IACK-based clear pattern |
| IPL1 (level 4) | GP9001 HBLANK / scanline | Secondary; some games may not use |

Z80 interrupts are driven by the YM2151 (bgaregga) or YMZ280B (batrider/bakraid) timer output.

---

## Key Implementation Notes

1. **Not twincobr.cpp** — Twin Cobra / Flying Shark use MC6809 + Z80 + custom Toaplan2 video
   (not GP9001) + YM3812. Completely different family. The previous HARDWARE.md was auto-generated
   from the wrong driver.

2. **Two distinct RTL modules** in this directory:
   - `raizing_arcade.sv` — Battle Garegga (bgaregga_state)
   - `batrider_arcade.sv` — Batrider + Battle Bakraid (batrider_state / bbakraid_state)

3. **GP9001 reuse** — The GP9001 implementation at `chips/gp9001/rtl/gp9001.sv` is shared with
   `toaplan_v2`. The OBJECTBANK_EN parameter must be set correctly (0 for bgaregga, 1 for others).

4. **YMZ280B stub** — `chips/raizing_arcade/rtl/ymz280b.sv` exists but is a stub. The full
   8-channel ADPCM core is needed before Batrider/Bakraid can produce audio.

5. **GAL OKI banking** — The `gal_oki_bank.sv` module is complete and implements the same
   function as the NMK112 chip, but using discrete GAL16V8 logic as done on real PCBs.
