# TC0630FDP — Taito F3 Display Processor

**Status:** Research complete — RTL not started (greenfield)
**Research date:** 2026-03-16
**MAME sources:** `src/mame/taito/taito_f3.cpp`, `taito_f3_v.cpp`, `taito_f3.h`
**Key MAME PRs:** #10920 (line clip fixes), #11788 (palette OR fix), #11811 (major rewrite)

---

## Chip Overview

The TC0630FDP is a Toshiba channel-less gate array (>10K gates) that serves as the sole
display processor for the Taito F3 Package System arcade board (1992–1997).

It integrates:
- 4 scrolling 16×16 tilemap layers (playfields PF1–PF4), 512×512 or 1024×512, 4/5/6bpp
- 1 CPU-writable text layer (8×8 characters, 64×64 tile map)
- 1 CPU-writable pivot/pixel layer (8×8 tiles, 64×32, column-major)
- Sprite engine: 17-bit tile codes, per-sprite zoom, multi-tile blocks, jump chains
- Per-scanline Line RAM: rowscroll, colscroll, zoom, palette add, 4 clip planes, alpha blend
- Hardware alpha blending with 4 modes and per-scanline coefficient registers
- Mosaic (X-sample) effect for sprites, pivot, and playfields

---

## Game List (30+ titles on Taito F3)

| Year | Title | MAME ID | Notes |
|------|-------|---------|-------|
| 1992 | Ring Rage | ringrage | Launch title |
| 1992 | Arabian Magic | arabianm | |
| 1992 | Riding Fight | ridingf | |
| 1993 | RayForce / Gunlock | rayforce / gunlock | Classic shmup |
| 1993 | Kaiser Knuckle | kaiserkn | Large zoomed fighters |
| 1993 | Dungeon Magic | dungmgic | |
| 1993 | Space Invaders DX | spacedxo | |
| 1993 | Grid Seeker: Project Storm Hammer | gseeker | |
| 1993 | Gekirindan | gekirind | Per-scanline zoom BG |
| 1994 | Darius Gaiden | dariusg | Sprite trails, alpha blend |
| 1994 | Elevator Action Returns | elvactr | Brightness/alpha per scanline |
| 1994 | Bubble Symphony | bubsym | Bubble Bobble sequel |
| 1994 | Light Bringer | lightbr | |
| 1994 | Cleopatra Fortune | cleopatr | Clip-plane gem effects |
| 1994 | Night Striker S | nstriker | |
| 1994 | Twin Cobra II | twinqix | |
| 1994 | Kyukyoku Tiger 2 (Twin Cobra II) | twinqix | |
| 1994 | Bubble Memories | bubblem | Alt line RAM, 5bpp sprites |
| 1995 | Puzzle Bobble 2 | pbobble2 | |
| 1995 | Space Invaders '95 | spcinvdx | |
| 1995 | Qix Neo | qixml | |
| 1995 | Puchi Carat | puchicra | |
| 1995 | Arkanoid Returns | arkretrn | |
| 1995 | Landmaker | landmakr | |
| 1995 | Puzzle Bobble 3 | pbobble3 | |
| 1996 | Moriguchi Hiroko no Quiz de Hyuu!Hyuu! | quizhuhu | |
| 1996 | Panic Bomber World | pabball | |
| 1996 | Puzzle Bobble 4 | pbobble4 | Reversed clip inversion |
| 1996 | Lunar Park Buster | | |
| 1997 | Command War | commandw | Reversed clip inversion |
| 1997 | Two Minute Drill | 2mindril | |

---

## Custom Chip Summary

| Chip | Name | Function | FPGA Status |
|------|------|----------|-------------|
| **TC0630FDP** | Display Processor | All video (this chip) | **To build** |
| TC0650FDA | Digital-to-Analog | Palette DAC, RGB output | To build (template from TC0260DAR) |
| TC0640FIO | I/O Controller | Inputs, EEPROM, watchdog | To build (reference TC0220IOC) |
| TC0660FCM | Control Module | Misc control/comms | TBD (possibly trivial) |

**Note:** The TC0260DAR palette chip from TaitoF2_MiSTer is **not present** on F3 boards.
The F3 uses TC0650FDA instead, which performs the same palette-RAM-to-RGB-DAC function but
with F3's specific 24-bit palette format.

---

## Audio Subsystem (not part of this chip's scope)

- **Sound CPU:** MC68000 @ 16 MHz (separate from main 68EC020)
- **Audio chip:** Ensoniq ES5506 wavetable synthesizer (most games)
  - Note: Some early F3 games may use ES5505 (the older variant)
  - The Apple IIGS MiSTer core targets ES5503; the ES5506 is a distinct chip requiring
    its own FPGA implementation. Check community efforts before starting from scratch.
- **Audio DSP:** ES5510 (some titles)
- **Interface:** TC0660FCM / TC0400YSC dual-port RAM bridge (0xC00000–0xC007FF)

---

## Reuse Potential

The TC0630FDP is highly F3-specific. However, its sub-components have reuse potential:

| Sub-module | Reuse Opportunity |
|-----------|------------------|
| 16×16 tilemap engine | Taito F2 games use similar (but smaller) TC0100SCN approach |
| Alpha blend compositor | Reusable for any future Taito system with alpha |
| Line RAM parser framework | Reusable for any system with per-scanline effect registers |
| 17-bit sprite engine | Closest analog: TC0200OBJ (Taito F2); different format |
| Clip plane logic | F3-unique, but design pattern reusable |

---

## Key Hardware Facts

- **Pixel clock:** 26.686 MHz XTAL / 4 = 6.6715 MHz
- **Resolution:** 320×232 active (some games: 320×224 via clip planes)
- **H/V total:** 432 × 262, ~58.97 Hz refresh
- **Palette:** 32,768 entries × 16 colors = 524K addressable colors
- **Palette format:** 24-bit RGB packed in 32-bit longword; high planes bitwise OR into
  palette address (not added — critical MAME accuracy fix PR #11788)
- **Sprite tile codes:** 17-bit (0–131071), 16×16 px, 4/5/6bpp
- **Sprite banks:** Dual-banked with configurable frame lag (0, 1, or 2 frames)
- **Associated RAM:** 4 × Sanyo LC321664AM-80 (1M×16 DRAM, 80ns) adjacent on PCB

---

## Document Index

| File | Contents |
|------|----------|
| `section1_registers.md` | CPU address map, VRAM layout, control registers, all memory formats |
| `section2_behavior.md` | Video timing, rendering pipeline, FPGA plan, gate 4 strategy |
| `README.md` | This file — status, game list, chip overview |

---

## Research Sources

- MAME `src/mame/taito/taito_f3.cpp` — driver, memory map, screen timing, GFX decode
- MAME `src/mame/taito/taito_f3_v.cpp` — full video implementation (tile info, sprite walk, compositing)
- MAME `src/mame/taito/taito_f3.h` — struct definitions, constants, layer configuration
- MAME PR #10920 — line clip fixes, clip plane format documentation
- MAME PR #11788 — palette OR vs ADD correction
- MAME PR #11811 — major video rewrite, mosaic, sprite trails, blend conflict
- MAME Discussion #27 (mamedev/mame) — line clip notes, clipping window details
- MAME Issue #10033 — unemulated per-line brightness alpha
- Neo-Arcadia forum thread #58246 — TC0630FDP PCB context (adjacent RAM identification)
- System16.com hardware.php?id=665 — chip list, hardware overview
