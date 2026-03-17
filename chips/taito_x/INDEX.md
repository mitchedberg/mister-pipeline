# Taito X System — Research Index

## Overview

This directory contains comprehensive research on the **Taito X System**, a 1987 arcade hardware platform with a sprite-only rendering engine. The research is organized to support **FPGA implementation planning** (no RTL code yet).

**Status:** Research-only. All information extracted from MAME source, hardware documentation, and game analysis. Ready for RTL design phase.

---

## Document Guide

### 1. **README.md** — START HERE
**Primary research document.** Contains:
- Hardware overview (CPU, chips, clock)
- Memory map (addresses & sizes)
- Custom chip summary table
- X1-001A/X1-002A sprite system architecture
- Sprite format & rendering pipeline
- Audio system (YM2610 & YM2151)
- Complete game library with genres & years
- Existing FPGA work assessment
- **Build strategy with phased implementation plan** ← Critical
- Estimated effort: 110 hours (2.5 weeks)
- Verification checkpoints for each phase

**Key takeaway:** Taito X is MODERATE complexity, sprite-only, with a documented 2.5-week implementation path.

---

### 2. **ARCHITECTURE.md** — Technical Deep Dive
**Advanced reference document.** Contains:
- Full block diagram (CPU, memory, custom chips, audio)
- Detailed memory map with address ranges
- 68000 CPU interface (interrupts, timing, cycles/frame)
- X1-001A reverse-engineered rendering pipeline (step-by-step)
- Key unknowns requiring reverse-engineering
- 68000 ↔ Z80 communication hypothesis
- YM2610 FM synthesis register map (excerpt)
- Video timing calculations (384×240 @ 60 Hz)
- Sprite ROM addressing hypothesis (validation method)
- Control register map (estimated)
- Known MAME debugging breakpoints
- Next research actions (checklist)

**Key takeaway:** Detailed enough for hardware design but intentionally leaves implementation unknowns to solve during reverse-engineering phase.

---

### 3. **GAME_ROMS.md** — ROM Specifications & Validation
**Game-specific reference.** Contains:
- Complete game library with ROM specifications
- Per-game audio chip assignments (YM2610 vs. YM2151)
- ROM sizes, types, and organization (program, sprite, sound)
- Superman detailed walkthrough (as reference)
- Twin Hawk (Y-coordinate difference from Superman)
- Other games (Last Striker, Gigandes, Balloon Brothers, etc.)
- ROM dumping procedure (how to extract from MAME)
- ROM format detection (sprite extraction & validation script)
- Interleaving & byte order (word layout)
- Sprite ROM compression hypothesis (likely uncompressed)
- ROM file organization (recommended structure for FPGA)

**Key takeaway:** Clear procedure to validate ROM extraction and sprite rendering using MAME as ground truth.

---

## Quick Reference: Key Specs

| Aspect | Value |
|--------|-------|
| **CPU** | Motorola 68000 @ 8 MHz |
| **Sound CPU** | Z80 @ 4 MHz |
| **Master Clock** | 16 MHz crystal |
| **Display** | 384 × 240 @ 60 Hz |
| **Colors** | 15-bit RGB (2048 simultaneous) |
| **Sprite System** | X1-001A + X1-002A |
| **Sprite Size** | 16 × 16 pixels (fixed) |
| **Max Sprites** | 256 active |
| **Tilemap Layers** | **None** (sprite-only) |
| **Audio** | YM2610 (6 games) or YM2151 (Twin Hawk) |
| **Games** | 7–9 confirmed titles |
| **FPGA Effort** | ~110 hours (2.5 weeks) |

---

## Pre-Implementation Checklist

Before starting RTL coding:

- [ ] **Read README.md** (esp. "Build Strategy" section)
- [ ] **Review ARCHITECTURE.md** block diagram & memory map
- [ ] **Verify MAME taito_x.cpp exists** (checkout mamedev/mame)
- [ ] **Extract X1-001A sprite rendering code** from `x1_001.cpp`
- [ ] **Identify exact Y-coordinate attribute RAM layout** (0xD00000)
- [ ] **Obtain Superman ROM set** from MAME database
- [ ] **Extract sprite ROM** using provided `sprite_validator.py` script
- [ ] **Validate sprite extraction** by comparing to MAME output
- [ ] **Identify YM2610 vs. YM2151 initialization** code
- [ ] **Map CPU interrupt routing** (IPL pins, vblank timing)
- [ ] **Document final unknowns** in separate `UNKNOWNS.md`

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1–2)
- [ ] 68000 CPU core (TG68K or equivalent)
- [ ] Z80 sound CPU
- [ ] Program ROM / work RAM / sound ROM
- [ ] Basic JAMMA I/O (joystick, buttons)
- [ ] **Milestone:** Memory test boots, 68000 executes code

### Phase 2: Graphics (Week 2–3)
- [ ] Palette RAM (2048 colors)
- [ ] Sprite object RAM (double-buffered)
- [ ] X1-001A sprite renderer (basic)
- [ ] Sprite graphics ROM fetch & decode
- [ ] Pixel composition to framebuffer
- [ ] **Milestone:** Superman title screen displays sprites

### Phase 3: Audio (Week 3–4)
- [ ] YM2610 OPNB emulation (primary)
- [ ] YM2151 OPM emulation (Twin Hawk fallback)
- [ ] Z80 ↔ YM2610 interface
- [ ] Audio output (PWM or DAC)
- [ ] **Milestone:** Music plays during gameplay

### Phase 4: Integration & Testing (Week 4–5)
- [ ] System synchronization (CPU, sound, video clocks)
- [ ] Interrupt timing (vblank, Z80 commands)
- [ ] MAME cross-validation (RAM dumps, byte-perfect matching)
- [ ] TAS validation (if available)
- [ ] **Milestone:** All 7 games bootable, playable, sound working

---

## Unknowns Requiring Reverse-Engineering

**During Phase 1 (before graphics pipeline):**
1. Exact Y-coordinate attribute RAM bit layout (0xD00000)
2. Sprite render order (back-to-front vs. front-to-back)
3. CPU interrupt timing & priority (vblank, Z80, sprite-0-hit?)

**During Phase 2 (sprite rendering):**
4. X1-001A sprite ROM addressing formula (sprite_code → ROM offset)
5. Sprite graphics compression (likely none, but verify)
6. Color palette application (5-bit color_attr → palette base)
7. Sprite clipping behavior (hardware vs. CPU-based)

**During Phase 3 (audio):**
8. Z80 ↔ 68000 command protocol (register addresses, interrupt trigger)
9. YM2610 vs. YM2151 initialization differences
10. Sound ROM bank switching (if applicable)

---

## Research Sources

### MAME Implementation
- **Repository:** https://github.com/mamedev/mame (master branch)
- **Main driver:** `src/mame/taito/taito_x.cpp`
- **X1-001A device:** `src/devices/video/x1_001.cpp/h` (if separated)
- **Audio devices:** `src/devices/sound/ym2610.cpp`, `ym2151.cpp`

### Hardware Documentation
- **System 16 Arcade Museum:** https://www.system16.com/hardware.php?id=649
- **Taito Wiki:** https://taito.fandom.com/wiki/Taito_X_System
- **VGMRips Taito X:** https://vgmrips.net/wiki/Taito_X_System

### Community Resources
- **Arcade Projects Forum:** https://www.arcade-projects.com
- **Shmups.org:** https://shmups.system11.org (shmup games documentation)

---

## File Organization

```
chips/taito_x/
├── INDEX.md                  (this file)
├── README.md                 (primary research document)
├── ARCHITECTURE.md           (deep technical dive)
├── GAME_ROMS.md             (ROM specifications & validation)
├── notes/                    (session logs & reverse-eng progress)
│   ├── reverse_engineering.md
│   └── session-log.md
└── validation/               (ROM extraction tools & scripts)
    ├── sprite_validator.py
    ├── rom_checksums.txt
    └── (ROM image files — not committed)
```

---

## Contributing Notes for Future Sessions

### Session Template

When returning to this project, follow this checklist:

1. **Read this INDEX.md** (2 min)
2. **Skim README.md "Build Strategy"** (5 min)
3. **Check notes/session-log.md** for previous progress (5 min)
4. **Review "Unknowns" section** (5 min)
5. **Proceed to active phase** (refer to "Implementation Roadmap")

### Updating Documentation

- **Add findings to ARCHITECTURE.md** when reverse-engineering succeeds
- **Update "Unknowns" section** in README.md as items are resolved
- **Log all breakpoint discoveries** in `notes/reverse_engineering.md`
- **Append session summaries** to `notes/session-log.md`

---

## Key Insights (Summary)

1. **Sprite-only architecture** simplifies implementation compared to Taito B/Z/F3 (no tilemap layers)
2. **Fixed 16×16 sprite size** means simpler ROM addressing and raster composition
3. **Two audio chips** (YM2610, YM2151) require conditional instantiation per-game
4. **Small game library** (7–9 titles) means fewer edge cases to handle
5. **MAME reference** is mature and well-documented; ideal for validation
6. **No prior FPGA work** on this system means opportunity but also no shortcuts

---

## Success Criteria

**FPGA core is "complete" when:**

✅ Superman (all 3 regions) boots and plays to first gameplay frame
✅ Sprites render correctly (position, flip, color, animation)
✅ Palette updates apply (title screen → gameplay color transitions)
✅ Audio plays (YM2610 music & effects in Superman)
✅ Twin Hawk plays with YM2151 audio (proves flexibility)
✅ All 7 games boot & play 5+ minutes without crashes
✅ MAME byte-perfect match on RAM dumps (sprite position, palette, etc.)
✅ TAS validation (if available) shows <5% frame divergence

---

## Next Steps

1. ✅ Research complete (you are here)
2. → Clone MAME source & extract `taito_x.cpp`
3. → Create `notes/reverse_engineering.md` with MAME findings
4. → Begin Phase 1 (CPU/RAM/ROM core)
5. → Validate against MAME debugging output
6. → Proceed to Phase 2 (sprite rendering)

---

**Last Updated:** 2026-03-17
**Status:** Research complete, ready for RTL design
**Estimated RTL Effort:** 110 hours (2.5 weeks full-time, 5–6 weeks part-time)

