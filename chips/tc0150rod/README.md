# TC0150ROD — Taito Road Chip

## Status: COMPLETE — All 329 vectors pass

**System:** Taito Z (1987–1992)
**Games:** Continental Circus, Aquajack, Double Axle (Power Wheels), Racing Beat

## What This Chip Does

TC0150ROD is Taito's per-scanline road rasterizer. Each HBlank it reads 8 words of
RAM (4 per road layer), computes edge geometry, fetches a 256-word tile cache from
GFX ROM, and rasterizes one scanline of road A + road B into a 320-pixel buffer.

- Two road layers (A and B) with independent tile, color bank, edge width, and X offset
- Body region and left/right edge regions, each with separate palette offset
- Per-layer priority table with 6-entry default {1,1,2,3,3,4} and bit-level modifiers
- Road B body only renders for xi > 0x1ff (prevents tile-wrap artifacts)
- Toggle-req/ack ROM interface for shared SDRAM arbitration
- Scanline output: 15-bit palette index + pix_valid + pix_transp + line_priority

## Chip Interface

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| clk / rst_n | in | 1 | Clock / active-low reset |
| cpu_cs/we/addr/din/dout/be | in/out | — | CPU B-bus (word addressed, byte-enable) |
| cpu_dtack_n | out | 1 | Bus acknowledge (1 cycle) |
| rom_addr / rom_data / rom_req / rom_ack | out/in | 18/16/1/1 | Toggle-req/ack ROM |
| hblank / vblank / hpos / vpos | in | — | Video timing |
| y_offs | in | 8s | Signed vertical offset (typically -1) |
| palette_offs | in | 8 | Global palette base (0xC0 for Double Axle) |
| road_type | in | 2 | 0=standard, 1=contcirc, 2=aquajack |
| road_trans | in | 1 | Transparent road body on pixel=0 |
| low_priority / high_priority | in | 8 | Line priority below/above switch line |
| pix_out / pix_valid / pix_transp | out | 15/1/1 | Pixel output during active display |
| line_priority | out | 8 | Priority for current scanline |
| render_done | out | 1 | Pulses one cycle when scanline buffer ready |

## Implementation

`rtl/tc0150rod.sv` — single module, ~750 lines.

Key design decisions:
- Road RAM uses combinational read port (no register stage) to avoid BRAM latency in FSM
- Pixel geometry computed in `always_comb` using `road_x = W-1 - render_x` for coordinate
  axis inversion (ROM tile space is left-to-right, screen write is right-to-left)
- Body word index: `(xi | 0x200) >> 3` using full 11-bit xi to correctly handle xi >= 0x400
- Left edge xi: `(0x1ff - (left_edge - road_x)) & 0x1ff` — counts down from 0x1ff at boundary
- Right edge xi: `(0x200 + (road_x - right_edge)) & 0x3ff` — counts up from 0x200 at boundary
- colbank from GFX word: `{gfx[15:12], 2'b00}` — bits[15:12] × 4

## Test Vectors

`vectors/` — 5-step incremental test suite, 329 vectors total.

| File | Tests | Coverage |
|------|-------|----------|
| step1_vectors.jsonl | RAM write/read, byte-enable, internal read port | 56 |
| step2_vectors.jsonl | Control word decode, bank select, geometry | 34 |
| step3_vectors.jsonl | Road A/B rendering with solid tiles (pre-loaded cache) | 160 |
| step4_vectors.jsonl | ROM fetch (toggle-req/ack), checker tiles, two-tile and same-tile | 54 |
| step5_vectors.jsonl | Scanline output, pix_transp, line_priority switching | 25 |

Run with: `cd vectors && make`

## MAME Reference

`src/mame/taito/tc0150rod.cpp` (Nicola Salmoria)
`src/mame/taito/taito_z.cpp`
