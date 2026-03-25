# Midway Y-Unit FPGA Analysis — March 24, 2026

## Overview

This directory contains comprehensive research on the Midway Y-Unit arcade hardware and FPGA implementation feasibility for MiSTer.

## Key Findings

1. **Source Code Status**: Coin-Op Collection's FPGA source is closed-source. Only comprehensive technical documentation is public.

2. **Scanline Buffer Approach**: **Not feasible for general Y-Unit games.** Only works for Smash TV + Total Carnage (staging-free architecture).

3. **Bandwidth Problem**: Pramod's MiSTer attempt failed because most Y-Unit games use hidden VRAM rows for sprite staging/animation prep. Scanline buffer breaks this.

4. **Full Y-Unit Feasibility**: Possible but difficult. Coin-Op Collection uses 128 MHz SDRAM + careful arbitration. Requires either:
   - Larger FPGA (Analogue Pocket, 52K ALM vs. DE10-Nano's 40K ALM)
   - Or accept 2-game subset (Smash TV + Total Carnage)

## Documents in This Package

### Core Analysis
- **2026-03-24_midway-source-analysis.md** (comprehensive, 300+ lines)
  - Architecture overview
  - DMA blitter system
  - VRAM management & arbitration
  - Why scanline buffer fails (detailed)
  - Technical feasibility assessment
  - Actionable recommendations

- **2026-03-24_scanline-buffer-feasibility.md** (focused analysis)
  - Theorerical vs. practical scanline buffering
  - Staging RAM problem explained
  - Bandwidth math
  - Game-by-game feasibility matrix
  - Recommendations for MiSTer

### Reference Materials
- **midway-y-unit-source/Midway/** (downloaded from Coin-Op Collection)
  - Y-Unit/midway_yunit.md (technical overview)
  - Y-Unit/public_documents/ (service manuals + schematics for all 8 Y-Unit games)
  - Z-Unit/midway_zunit.md (predecessor system, useful for context)

## Quick Links

### Documentation
- [Coin-Op Collection Development-Documentation](https://github.com/Coin-OpCollection/Development-Documentation) — Primary source
- [Pramod's Engineering Blog](https://www.pram0d.com) — TMS34010 implementation details
- [MiSTer FPGA Forum: Y-Unit Discussion](https://misterfpga.org/viewtopic.php?t=7542) — Community experience

### Service Manuals
All 8 Y-Unit games have schematics in `midway-y-unit-source/Midway/Y-Unit/public_documents/`:
- Smash TV (16-3044-K-101)
- Trog (16-40003A-101)
- High Impact Football (16-40104-101)
- Strike Force (16-42413-101)
- Super High Impact Football (16-43117-101)
- Terminator 2: Judgment Day (16-40009-101)
- Total Carnage (16-40010-101)
- Mortal Kombat (16-43125-101)

## Executive Recommendations

### Option A: Quick Win (Smash TV Only)
- **Scope**: Single game, scanline buffer architecture works
- **Effort**: 4–6 weeks
- **Risk**: Low
- **Path**: Implement TMS34010 core + DMA blitter + line buffer

### Option B: Conservative (Smash TV + Total Carnage)
- **Scope**: Two games, both staging-free
- **Effort**: 6–8 weeks
- **Risk**: Low
- **Path**: Extend Option A with autoerase/bulk-clear variations

### Option C: Full Y-Unit (High Risk)
- **Scope**: All 8 games
- **Effort**: 14–20 weeks
- **Risk**: High (may hit SDRAM bandwidth wall)
- **Path**: Full VRAM in SDRAM + 128 MHz SDRAM controller

## Technical Snapshot

### TMS34010 CPU Core
- 32-bit internal, 16-bit external (CPU-to-RAM)
- 1-bit addressing scheme (converts to byte addresses)
- Integrated memory controller + shift buffer
- Integrated GPU (FILL, MOVE, transparency)
- ~7000 lines Verilog (Pramod's implementation)

### Y-Unit Memory Architecture
- **VRAM**: 512 KB (256 KB Palette + 256 KB Bitmap), unified address space
- **DMA**: 32-bit ROM fetch, 9 drawing modes, 41ns/pixel throughput requirement
- **Autoerase**: Hardware PLD (most games) OR GPU FILL instruction (Strike Force, T2)
- **Image ROM**: 6-bit (or 4-bit) pixels, live deswizzling during DMA

### Bandwidth Reality
- Peak demand: 65–95 MB/s (DMA + CPU + Autoerase + line output)
- MiSTer SDRAM @ 125 MHz: ~200 MB/s achievable
- **Looks OK on paper, but contention issues in practice** (Pramod's experience)

## Why Scanline Buffer Fails

Games with staging VRAM (6 of 8 Y-Unit games) assume:
1. Hidden VRAM rows (256–511) for sprite composition off-screen
2. Simultaneous CPU reads from staging + DMA writes to visible framebuffer
3. Unified coherent address space

Scanline buffer breaks assumption #2 (only shows rows 0–1 in BRAM, rest in SDRAM):
- CPU reads from row 300 get stale data
- Game logic corrupts
- Animation frames misaligned

**Only Smash TV + Total Carnage work** because they write directly to visible framebuffer (no staging stage).

## Implementation Checklist (If Proceeding)

- [ ] Obtain service manuals for target game(s)
- [ ] Study Pramod's blog posts (TMS34010 + FPGA methodology)
- [ ] Implement TMS34010 core with microcode engine
- [ ] Build DMA blitter (32-bit ROM fetch + 6bpp deswizzle)
- [ ] Add memory controller (arbitration for 4 sources)
- [ ] Implement VRAM control + shift buffer
- [ ] Add line buffer + CRT output
- [ ] Build TAS validation harness (frame-by-frame vs. MAME)
- [ ] Test Smash TV boot (HBlank detection, autoerase)
- [ ] Extend to Total Carnage (bulk FILL variant)
- [ ] (Optional) Attempt Mortal Kombat (hit SDRAM limits)

## Community Resources

### Related Projects
- [jtcores](https://github.com/jotego/jtcores) — Jotego's arcade cores (has some TMS34010 work)
- [Raizing FPGA](https://github.com/psomashekar/Raizing_FPGA) — Pramod's SHMUP cores
- [Coin-Op Collection Distribution](https://github.com/Coin-OpCollection/Distribution-MiSTerFPGA) — Compiled cores (no source)

### MiSTer Arcade Cores
- Analogue Pocket Y-Unit core (RC6) — Reference for register mapping
- MAME Y-Unit emulation — Frame-by-frame validation reference

## Contacts for Further Research

- **Pramod Somashekar** (pram0d): Author of MiSTer Y-Unit alpha + TMS34010 core
  - Blog: https://www.pram0d.com
  - GitHub: https://github.com/psomashekar
  
- **Coin-Op Collection**: Maintainers of Development-Documentation
  - GitHub: https://github.com/Coin-OpCollection
  - Patreon: https://www.patreon.com/coin_opcollection

## Next Steps

1. **Review both analysis documents** (start with executive summary in midway-source-analysis.md Part 1–3)
2. **Download service manuals** from midway-y-unit-source/ for your target game
3. **Study Pramod's blog** for TMS34010 implementation patterns
4. **Reach out to community** (MiSTer forum, Coin-Op Patreon) for guidance
5. **Start with Smash TV** prototype (4-week milestone for TMS34010 core validation)

---

**Last Updated**: March 24, 2026  
**Status**: Research complete. Awaiting direction on scope (Smash TV only vs. full Y-Unit).
