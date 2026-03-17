# TC0480SCP — Taito Tilemap Generator (Second Generation)

## Status

**Greenfield — no FPGA implementation exists.**
Documentation complete. RTL not started.

## What This Chip Does

The TC0480SCP is Taito's second-generation tilemap generator chip. It manages four 16×16-tile background layers and one 8×8 text overlay, with the following capabilities per layer:

- BG0–BG3: global X/Y scroll, global X/Y zoom, per-row horizontal scroll (rowscroll)
- BG2–BG3 additionally: per-row horizontal zoom, per-column vertical scroll (colscroll)
- FG0 (text): CPU-uploaded 8×8 tile graphics, global scroll, no zoom, always on top
- Programmable layer draw order (8 possible BG priority sequences)
- Double-width tilemap mode (32×32 → 64×32, togglable mid-game)
- Full screen flip

It supersedes the TC0100SCN (used in earlier Taito Z games) with double the layers and added zoom/column scroll capability.

## Chip Interfaces

- CPU bus: 17-bit address, 16-bit data (64KB RAM + 0x30-byte control window)
- GFX ROM bus: 21-bit address, 32-bit data (up to 8MB ROM; typically 1–4MB used)
- Pixel output: 16-bit palette index (SD0–SD15) to TC0360PRI
- Video sync: HSYNC, HBLANK, VSYNC, VBLANK inputs

## Target Games (Taito Z Core)

| Game | Year | Notes |
|------|------|-------|
| Double Axle (Power Wheels) | 1991 | Primary target; dual 68K @ 16 MHz, 32MHz OSC |
| Racing Beat | 1991 | Same board variant as Double Axle |

Other systems also use this chip (Gunbuster, Ground Effects, Under Fire, Galastrm, Footchamp, Metalb, Slapshot, Deadconx) — the RTL module will be reusable for those cores.

## Reusable Components from This Pipeline

| Chip | File | Reuse Status | Notes |
|------|------|--------------|-------|
| TC0360PRI | `rtl/tc0360pri.sv` | Ready — 225/225 tests pass | Priority mixer between TC0480SCP and sprites |
| TC0260DAR | `rtl/tc0260dar.sv` | Ready | Palette DAC; some TC0480SCP games use raw palette RAM |
| TC0150ROD | (separate module) | Not started | Road generator — parallel development |

## What Is Novel (Needs RTL)

1. **tc0480scp.sv** — the entire chip is new. No prior FPGA implementation exists.

The complexity breakdown:
- Five tilemap layers with simultaneous per-scanline rendering
- Two-tier zoom (global + per-row for BG2/BG3)
- Colscroll (BG2/BG3): second-order indirection — colscroll-adjusted Y selects which row's scroll/zoom values to use
- Double-width mode: VRAM layout changes; one known game (Slapshot) changes this mid-game
- Dynamic priority order (8 combinations, actively used)
- GFX ROM is 32-bit wide; tile cache needed in FPGA due to SDRAM latency
- Screen flip with per-layer stagger offsets

## Document Index

| File | Contents |
|------|----------|
| `section1_registers.md` | CPU address map, all control registers (with bit fields), VRAM layout, tile entry format, rowscroll/rowzoom/colscroll RAM formats, GFX ROM format, sprite system (external), layer priority |
| `section2_behavior.md` | Video timing, full rendering algorithm (verbatim from MAME), FPGA module decomposition, memory requirements, 8-step build order, Gate 4 test strategy, complexity tier rating |

## Source References

- MAME: `src/mame/taito/tc0480scp.cpp` — primary behavioral reference
- MAME: `src/mame/taito/tc0480scp.h` — interface and internal state
- MAME: `src/mame/taito/taito_z.cpp` — Double Axle / Racing Beat driver (memory maps, machine config)
- MAME: `src/mame/taito/taito_z_v.cpp` — screen update functions showing how TC0480SCP integrates with TC0150ROD and sprites
- Gunbustr schematics: cited in MAME tc0480scp.cpp header for pin list

## Complexity Tier

**Tier 4** (highest in this pipeline).
Estimated Gate 4 first-pass rate: **30–40%**.

Primary risk: zoom accumulator precision and row-zoom x_origin formula (MAME itself acknowledges imperfect emulation of these on some games). Target is MAME-equivalent accuracy, not cycle-accurate hardware reproduction of edge cases.
