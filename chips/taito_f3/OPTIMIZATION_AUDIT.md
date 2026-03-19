# Taito F3 — ALM Optimization Audit

**Date:** 2026-03-19
**Current:** 193,341 / 41,910 ALMs = 461% over capacity
**Target:** <41,910 ALMs (Cyclone V 5CSEBA6U23I7 DE-10 Nano)

## Root Cause Analysis

The TC0630FDP display processor is the dominant consumer. It has:
- 4 parallel BG tilemap engines (tc0630fdp_bg.sv × 4)
- Per-scanline sprite list pre-computation (232 × 64 × 72-bit = ~1 Mbit)
- 4 parallel lineram decoders for rowscroll/zoom/palette/clip
- 4-way parallel alpha blending in compositor

## Module Size Breakdown

| Module | Lines | Instances | Est. ALMs | % of Total |
|--------|-------|-----------|-----------|------------|
| tc0630fdp_lineram.sv | 1,364 | 1 | 40K–50K | ~25% |
| tc0630fdp_bg.sv | 630 | 4 (×4) | 60K–80K | ~40% |
| tc0630fdp_colmix.sv | 671 | 1 | 25K–35K | ~16% |
| tc0630fdp_sprite_render.sv | 445 | 1 | 15K–20K | ~10% |
| tc0630fdp_sprite_scan.sv | 477 | 1 | 8K–12K | ~5% |
| taito_f3.sv (top) | 865 | 1 | 5K–8K | ~3% |
| Other (text, pivot, arbiter) | ~500 | 1 | 3K–5K | ~2% |
| **Total** | **~5,600** | | **~160K–190K** | |

## Tier 1 — High Impact (saves ~60K–75K ALMs)

### 1. Time-multiplex lineram decoders (saves ~25K–30K ALMs)
**Current:** 4 parallel decoders for PF1–PF4, each with full rowscroll/colscroll/zoom/blend pipeline (1,364 lines total).
**Proposal:** Single decoder processes one PF per cycle; register outputs; mux into BG engine. Decode order (PF1→PF4) over 4 HBLANK cycles.
**Trade-off:** Requires careful pipelining during HBLANK; must complete before active display.

### 2. Eliminate per-scanline sprite list BRAM (saves ~32K–40K ALMs)
**Current:** Pre-compute all 232 sprite lists during VBLANK (14,848 × 72-bit = ~1 Mbit BRAM).
**Proposal:** Sprite scanner emits list on-demand during rendering; read sprite entries from Line RAM during HBLANK.
**Trade-off:** Higher Line RAM read bandwidth (manageable with dual-port).

### 3. Share BG line buffers (saves ~4K–8K ALMs)
**Current:** 4 × 320 × 13-bit static line buffers (one per BG layer).
**Proposal:** Single 320 × 13-bit shared line buffer; 4-way round-robin scheduling during HBLANK.
**Trade-off:** All 4 BGs must complete rendering within HBLANK (112 pixel clocks at 8 MHz).

## Tier 2 — Medium Impact (saves ~18K–25K ALMs)

### 4. Serialize sprite renderer (saves ~10K–15K ALMs)
**Current:** Full 64-sprite per-scanline pipeline with parallel tile-fetch.
**Proposal:** 32 sprites per scanline + 2-cycle pipeline. Real F3 games rarely use >32 visible sprites per line.

### 5. Serialize compositor alpha blend (saves ~8K–10K ALMs)
**Current:** 4-way parallel alpha blending for every pixel.
**Proposal:** Single 2-stage MAC unit processing layers sequentially (4 cycles per pixel).

## Tier 3 — Incremental (saves ~5K–10K ALMs)

### 6. Remove debug output ports (saves ~2K–3K ALMs)
Several pixel-out ports exist for testbench only.

### 7. Distributed RAM for small tables (saves ~1K–2K ALMs)
Zoom/palette lookup tables can use LUTRAM instead of block RAM.

## Summary

| Tier | Combined Savings | Running Total |
|------|-----------------|---------------|
| Tier 1 (1+2+3) | 61K–78K | 61K–78K |
| Tier 2 (4+5) | 18K–25K | 79K–103K |
| Tier 3 (6+7) | 3K–5K | 82K–108K |

**Feasibility:** Tier 1 alone should bring the design from ~190K to ~115K–130K ALMs. Adding Tier 2 brings it to ~90K–110K. Still 2–3× over budget.

**Conclusion:** Even with aggressive time-multiplexing, TC0630FDP may remain ~2× over the DE-10 Nano's capacity. The 4 parallel BG engines (each ~15K–20K ALMs) are fundamental to F3's architecture. **Consider**: stubbing 2 of 4 BG layers (PF3/PF4 are lower-priority backgrounds in most F3 games) to cut another ~30K–40K ALMs. This would be game-specific but could make titles like Darius Gaiden playable with 2 background + sprite + text layers.

## Community Reference

No public FPGA implementations of TC0630FDP or Taito F3 exist. The closest community reference is CPS1/CPS2 (jotego), which handles 4 tilemap layers via time-multiplexed tile ROM access — validating the approach proposed here.
