# TC0200OBJ — Research Docs Only

**Status: PARKED — working implementation already exists**

Martin Donlon (wickerwaka) has a complete, actively maintained implementation at:
https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer/blob/master/rtl/tc0200obj.sv

License: GPL-2.0. 14+ Taito F2 games running with TC0200OBJ + TC0360PRI + TC0480SCP + TC0430GRW.

## What's Here

`section1_registers.md` — Sprite RAM format reverse-engineered from MAME `taito_f2_v.cpp`:
- Exact 8-word/16-byte sprite entry layout
- Zoom calculation formulas
- BigSprite multi-tile group encoding
- Scroll latch mechanism
- Control entry format

`section2_behavior.md` — Full behavioral specification for the chip's three pipeline phases
(VBLANK parse → HBLANK render → active output).

## Potential Future Work

1. Apply our gate-4 MAME comparison pipeline to wickerwaka's implementation → find accuracy gaps
2. If a standalone chip model is needed for another system (Taito F2 variant), use these docs
3. TC0540OBN is the later-variant sprite chip for newer F2 boards — also in wickerwaka's repo

## References

- MAME source: `src/mame/taito/taito_f2_v.cpp` (draw_sprites function)
- Wickerwaka core: `https://github.com/MiSTer-devel/Arcade-TaitoF2_MiSTer`
