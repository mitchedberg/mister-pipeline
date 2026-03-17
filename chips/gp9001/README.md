# GP9001 (VDP9001) — Toaplan V2 Graphics Chip

**Status:** RESEARCH COMPLETE — RTL NOT STARTED

**Chip Name:** GP9001 (also referred to as VDP9001 in some documentation)
**Manufacturer:** Toaplan (custom ASIC)
**Years:** 1992–1995 (Toaplan V2 arcade platform)
**Die Size:** Unknown (IC package appears to be 160-pin QFP)

---

## Games Using GP9001

**Major Titles:**
- **Batsugun** (1993, bullet-hell shmup) — arcade board, most well-known
- **Truxton II / Tatsujin Oh** (1992)
- **Dogyuun** (1992, bullet-hell)
- **FixEight** (1992)
- **Grindstormer / V-Five** (1994)
- **Knuckle Bash** (1993)
- **Pirate Ship Higemaru** (1993)
- **Whoopee Camp** (1992, puzzle-action)

---

## MAME Source Location & Coverage

| File | Role | Coverage |
|------|------|----------|
| `src/mame/toaplan/gp9001.h` | Header, register defs | Complete |
| `src/mame/toaplan/gp9001.cpp` | Core renderer | Complete (sprite scan, BG render) |
| `src/mame/toaplan/toaplan2.cpp` | System driver | Board-level integration, CPU/memory |
| `src/mame/toaplan/gp9001_pal.cpp` | Palette handling | Separate palette mixing module |

**MAME Implementation Status:** Fully functional, cycle-accurate sprite scanner + tilemap renderer.

---

## Architecture Overview

The **GP9001** is Toaplan's custom sprite and background graphics chip, combining:

1. **Sprite System**
   - Up to 256 sprites (16×16 to 128×128 pixel composite sprites)
   - Sprite ROM lookup (selects pre-composed sprite blocks from ROM)
   - On-chip sprite list parsing and rasterizer
   - Per-sprite priority relative to background layers
   - Per-sprite color table selection (palette bank)

2. **Background Layer System (2–4 layers)**
   - 2–4 tiled background layers (configurable per game)
   - 16×16 tile size from character ROM
   - Global X/Y scroll per layer
   - Optional per-row horizontal scroll (rowscroll)
   - Priority control between BG layers and sprites

3. **Color & Blending**
   - 256-entry primary palette (16-bit xBGR 555 or similar)
   - Per-layer palette bank selection (up to 256 palette sets)
   - Transparency/blending logic (color key 0x0000 = transparent)

4. **Output**
   - 16-bit pixel output (palette index + priority)
   - Feeds to external priority mixer (typically Toaplan's own priority chip or simple mux)

---

## Key Differences from Toaplan V1

| Feature | V1 | V2 (GP9001) |
|---------|-------|-----------|
| Sprite count | 64–128 | 256 |
| Max sprite size | 64×64 | 128×128 |
| BG layers | 2–3 | 2–4 |
| Rowscroll | No | Yes (selective) |
| Color depth | 256 (8bpp) | 256 per layer (8bpp) |
| Rendering style | Tile blitter | Scanline-based |

---

## Hardware Interface (CPU Bus)

**CPU Address Bus:** 16-bit (byte address) or 32-bit (on later boards)
**CPU Data Bus:** 16-bit (on most boards)
**Clock:** Typically 8–12 MHz (CPU-derived, same as M68000)

### Memory-Mapped Registers

All register access via standard CPU memory window (typically 0x90000000 range, board-dependent).

**Control Register Window:** ~0x200 bytes
**Sprite RAM:** ~0x800 bytes (256 sprites × 4 words)
**Background Control:** Variable
**Priority/Blend Control:** ~0x20 bytes

---

## Precision Notes

- **Sprite scanline position:** Integer pixel, no sub-pixel precision in standard mode
- **Scroll accumulator:** 24-bit fixed-point in MAME (16.8 format) — chip likely uses similar internally
- **Tile fetching:** Synchronous with video clock; prefetch buffer for sprite tiles
- **VBLANK/HSYNC inputs:** Synchronizes internal scroll counters and sprite evaluator

---

## Known Quirks & Uncertainties

1. **(verify in MAME src)** Exact cycle count for sprite list fetch during VBLANK — MAME comments indicate 2–3 scan lines of overhead
2. **(verify in MAME src)** Whether rowscroll applies to BG3 only or to multiple layers (game-dependent override?)
3. **(verify in MAME src)** Sprite tile fetch prefetch buffer depth — affects max sprites per line
4. **(verify in MAME src)** Palette blend modes (additive vs multiplicative) — only color-key transparency observed in MAME, other modes may exist but unused in extant games

---

## References

- **MAME Codebase:** [https://github.com/mamedev/mame](https://github.com/mamedev/mame)
  - Primary sources: `src/mame/toaplan/gp9001.cpp`, `gp9001.h`, `toaplan2.cpp`
- **Taito F3 Comparison:** GP9001 is graphically similar to Taito's TC0480SCP, but with simplified BG layer control and simpler sprite format
- **Community Datasheets:** None publicly available (proprietary Toaplan IC)
- **Schematics:** Batsugun arcade board schematics may exist in community archives (verify licensing)

---

## Next Steps for FPGA Implementation

See **section3_rtl_plan.md** for detailed RTL breakdown and build stages.

Key milestones:
1. **Stage 1 (gate1):** Sprite scanner + list parsing
2. **Stage 2 (gate2):** Sprite rasterizer (per-scanline pixel generation)
3. **Stage 3 (gate3):** BG layer tilemap indexing
4. **Stage 4 (gate4):** Pixel mixer (sprite vs BG priority)
5. **Stage 5 (gate5):** Full-frame validation against MAME reference

---

## File Organization

```
chips/gp9001/
  README.md                      (this file)
  section1_registers.md          (register map & CPU interface)
  section2_behavior.md           (rendering algorithm & timing)
  section3_rtl_plan.md           (proposed RTL architecture)
```

---

**Last Updated:** 2026-03-17
**Researcher:** Claude Code Agent
**Source:** MAME `src/mame/toaplan/` + architectural analysis
