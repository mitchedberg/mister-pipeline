# TC0180VCU — Taito B Video Controller

## Status: RESEARCH COMPLETE — RTL NOT STARTED

**System:** Taito B (1988–1994)
**Games:** Ninja Warriors, Crime City, Rastan Saga II / Nastar, Thunder Fox, Rambo III, Ashura Blaster, Hit the Ice, Violence Fight, Space Invaders DX, Master of Weapon

## Why This Chip

- **Zero existing FPGA implementations** (confirmed 2026-03 GitHub search)
- All Taito F2 chips covered by wickerwaka's Arcade-TaitoF2_MiSTer (parked)
- TC0180VCU is the sole differentiating chip for Taito B — all other chips are reusable:
  - TC0260DAR (DAC) — reuse from TaitoF2_MiSTer
  - TC0220IOC (I/O) — reuse from TaitoF2_MiSTer
  - TC0140SYT (sound) — reuse from TaitoF2_MiSTer

## Documentation

- `section1_registers.md` — Complete register map, memory layout, sprite format
- `section2_behavior.md` — Behavioral description, FPGA decomposition, Gate 4 strategy

## Complexity: Tier 3 (Highest So Far)

TC0180VCU integrates what Taito F2 spreads across 4 chips:
- BG + FG + TX tilemaps (64×64 / 64×32 tile maps, 16×16 / 8×8 tiles)
- Per-line scroll RAM (variable block size)
- Sprite engine: zoom + big sprite groups (up to 256 tiles per group)
- Double-buffered sprite framebuffer (requires SDRAM)
- Layer compositor with two priority modes

## Implementation Plan

See `section2_behavior.md §6` for module decomposition and `§8` for recommended build order.

Implement incrementally: register bank → TX tilemap → BG/FG → sprite (unzoomed) → full zoom → big sprite.

## MAME Reference

`src/mame/taito/tc0180vcu.cpp` (Nicola Salmoria, Jarek Burczynski)
`src/mame/taito/taito_b.cpp`
