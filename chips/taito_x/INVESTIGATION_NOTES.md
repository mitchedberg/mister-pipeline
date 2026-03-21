# Sprite Rendering Investigation Notes

## Root Cause Analysis (Session 2026-03-20)

### What We Observe
- Simulation: 3577 non-black pixels in rows 0-19 and 228-239
- MAME reference: 13,735 non-black pixels in rows 28-239 (title logo rows 55-95 at ~220px/row)
- 4× pixel count gap, wrong Y positions

### The BG Tilemap Hypothesis (MOST LIKELY ROOT CAUSE)

After detailed CRAM write analysis:

1. **ALL non-zero CRAM writes go to `0xE00800-0xE00FFF`** = cram words 0x0400-0x07FF
   - These are the BG tilemap tile code and color regions (per architecture doc)
   - `0xE00800-0xE00BFF` (cram 0x0400-0x05FF) = BG tile codes
   - `0xE00C00-0xE00FFF` (cram 0x0600-0x07FF) = BG tile colors

2. **ALL sprite char_pointer writes (cram 0x0000-0x11FF) are ZERO**
   - Game writes 0x0000 to entire cram 0x1000-0x1FFF range = all FG sprites get tile 0

3. **MAME title screen uses BG TILEMAP, not FG sprites**
   - The Gigandes title logo at rows 55-95 is rendered by the BG tilemap layer
   - FG sprites at title screen are all transparent (tile 0, color 0)
   - The BG layer is NOT implemented in the current RTL!

### FG Sprite Scanner Issues (Secondary)

Even if we fixed the BG layer, the FG scanner has issues:

1. **xptr_base wrong for bank B**: RTL uses 0x0400, MAME uses 0x1200
   - RTL is actually READING BG tile data (0x0400) as sprite X+color
   - This causes garbage X/color values for FG sprites

2. **frame_bank_latch timing**: Scanner latches at vblank_RISE
   - Game typically sets ctrl2=0x20 just BEFORE vblank_rise
   - Then sets ctrl2=0x60 (bank B) DURING VBlank
   - Scanner latches the pre-vblank value (0x20 = bank A) at the FIRST scan
   - Subsequent SCAN RESTARTs (at next vblank_rise) correctly pick up bank B
   - Fix: The SCAN RESTART mechanism correctly handles this for frames 1+

3. **Frame 0 is always blank** - expected behavior (game initialization)

### Control Register Sequence (per frame)
```
End of active display: ctrl2 = 0x20 (bank A)
VBlank start: ctrl2 = 0x60 (bank B) ← game writes sprite data to bank B char
VBlank end: frame_bank_latch captures 0x60 → bank_base = 0x1000 at SCAN RESTART
Next vblank_rise: SCAN RESTART reads cram[0x1000+] = all zeros (FG sprites)
```

### What's Actually Rendering in the Simulation

The 3577 pixels in rows 0-19 come from:
- FG scanner reading cram[0x1000+scan_idx] = 0 → tile code = 0
- Tile 0 GFX data (non-zero: 0xFFFF, 0x33C6, 0xF800) → visible pixels
- xptr reads from cram[0x0400+scan_idx] = BG tile codes → garbage color/X values
- sy_byte = 0xFA (YRAM init value) → ytop = 0 → sprites in rows 0-15

The 393 pixels in rows 228-239 (odd frames, linebuf bank 0):
- Different scan results visible in alternate frames (linebuf ping-pong)

### Required Fix: BG Tilemap Rendering

To match MAME output, the RTL needs a BG tilemap renderer that:
1. Reads BG tile codes from cram[0x0400 + sprite_i] (bank A, no bank offset for BG)
2. Reads BG colors from cram[0x0600 + sprite_i]
3. Reads scrollX/scrollY from spriteylow[0x200-0x2FF] (YRAM BG scroll region)
4. Renders 16 columns × 32 rows × 16×16 tiles to the frame buffer

### YRAM Address Map
```
yram_addr 0x000-0x1FF: FG sprite Y positions (spriteylow[0..511])
yram_addr 0x200-0x2FF: BG scroll RAM (16 columns × 16 bytes each)
  scroll[col*0x10 + 0] = scrollY for column col
  scroll[col*0x10 + 4] = scrollX for column col
```

### Immediate Fixes for FG Sprite Scanner

Fix xptr_base for bank B: change from 0x0400 to 0x1200:
```sv
// In x1_001a.sv:
// WRONG: wire [12:0] xptr_base = frame_bank_latch ? 13'h0400 : 13'h0200;
// CORRECT (per MAME):
wire [12:0] xptr_base = frame_bank_latch ? 13'h1200 : 13'h0200;
```

However, since all FG sprites at title screen have tile=0 and color=0, this fix
alone won't show the title logo - that requires the BG tilemap renderer.

### Files Modified This Session

- `rtl/tb_top.sv`: Added `.FG_NOFLIP_YOFFS(-10)` for Gigandes
- `rtl/x1_001a.sv`: Fixed YRAM indexing (1 sprite per word), added diagnostics
- `sim/tb_system.cpp`: Improved CRAM/CTRL logging; ctrl_wr now logs all D00602 writes
