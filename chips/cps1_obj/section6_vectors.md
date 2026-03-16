# CPS1 OBJ Chip — Section 6: Test Vector Generation Notes

---

## 1. Overview

This document describes how to generate test vectors specifically suited to verifying a CPS1 OBJ chip RTL implementation. The chip under test accepts: an OBJ RAM shadow buffer (latched at VBLANK), scanline number, and graphics ROM data; and produces per-pixel output for each scanline. Test vectors should cover all documented behaviors.

The primary test harness model is:
1. Load an OBJ RAM snapshot (256 entries × 8 bytes).
2. For each scanline (0–239 active), apply the ROM data that would result from the chip's fetch requests.
3. Capture the 512-pixel line buffer output.
4. Compare against a reference (MAME-rendered output or analytical reference).

---

## 2. Single-Tile Sprite Sweeps

### 2.1 X Position Sweep
- Fix: Y=0, CODE=any valid tile, ATTR=0x0000 (no flip, color 0, 1×1 block).
- Sweep X from 0 to 511 in steps of 1 (test all 9-bit positions).
- Verify: sprite appears at expected X position; wrap at 512; clipping at X < 64 and X > 447.

Key boundary cases:
- `X = 0`: sprite straddles the left edge, 16 pixels split across wrap.
- `X = 63`: leftmost pixel at 63 (hidden), rightmost at 78 (visible).
- `X = 64`: sprite fully at left visible boundary.
- `X = 432`: sprite at right edge, last column at X=447 visible.
- `X = 448`: sprite fully clipped (no visible pixels).
- `X = 497`: sprite wraps, right edge appears at X=1 (visible), left at 497 (hidden).
- `X = 511`: maximum value; wrap to 0-15 range.

### 2.2 Y Position Sweep
- Fix: X=64, CODE=valid, ATTR=0x0000.
- Sweep Y from 0 to 511 in steps of 1.
- Verify: sprite appears on the 16 expected scanlines; wrap at 512.

Key boundary cases:
- `Y = 0`: sprite on scanlines 0–15.
- `Y = 224`: sprite spans scanlines 224–239 (last visible scanlines).
- `Y = 225`: top of sprite is on scanline 225 (one invisible line), bottom visible.
- `Y = 240`: sprite starts at VBLANK; first line visible at Y=240 is not displayed; test that no rendering occurs.
- `Y = 497`: sprite wraps; bottom rows appear on scanlines 1–9 (visible).
- `Y = 0xF0` (240): border condition — verify inzone logic handles Y>0xF0 sprites that span scanline 0.

### 2.3 Pixel Color Sweep
- Fix X=64, Y=0, ATTR=0x0000.
- Sweep COLOR (ATTR bits 4:0) from 0 to 31.
- For each: provide tile data with all pixels = 0x5 (arbitrary non-transparent, non-0xF).
- Verify that the 5-bit palette index in line buffer output matches COLOR field.

### 2.4 Transparency
- Provide tile ROM data = 0xFFFFFFFF (all pixels transparent = 0xF).
- Verify zero pixels written to line buffer for this tile; no corruption of adjacent entries.

---

## 3. Flip Modes

### 3.1 FLIPX Only (ATTR bit 5 set)
- 1×1 sprite with asymmetric tile data (e.g., first 8 pixels = 0x1, last 8 = 0x2).
- Render without flip, capture output. Render with FLIPX, capture output.
- Verify pixel order is horizontally reversed.

### 3.2 FLIPY Only (ATTR bit 6 set)
- Sprite spanning multiple scanlines with distinct tile row data per row.
- Render without flip, render with FLIPY.
- Verify tile row fetch order is reversed: vsub for the top visible row fetches the bottom ROM row.

### 3.3 Both FLIPX and FLIPY
- Combine both flips; verify 180-degree rotation of the tile data.

### 3.4 Flip Screen (VIDEOCONTROL bit 15)
- Render scene normally, capture output.
- Enable flip screen, render same scene.
- Verify each sprite appears at mirrored coordinates: `X' = 512 - 16 - X`, `Y' = 256 - 16 - Y`.
- Verify FLIPX and FLIPY are inverted when flip screen is active.

---

## 4. Multi-Tile Block Sprites

### 4.1 Width Sweep
- Fix Y=0, X=64, CODE=base, ATTR with NX=0 through NX=15 (block widths 1–16 tiles).
- Verify that exactly `(NX+1) × 16` pixels are rendered horizontally.
- Verify tile code increments correctly across columns.

### 4.2 Height Sweep
- Fix X=64, Y=0, CODE=base, ATTR with NY=0 through NY=15.
- Verify sprite occupies `(NY+1) × 16` scanlines.
- Verify tile code for row `r` = base + `r × 0x10`.

### 4.3 Maximum Block (NX=15, NY=15)
- 16×16 tile block = 256 tiles = 256×256 pixel sprite.
- Fill with distinctive per-tile data.
- Verify all 256 unique tile codes are requested, in correct order.
- Test with FLIPX and FLIPY to verify reversal logic at maximum dimensions.

### 4.4 Block X Wrap
- Position a 2×1 block at X=440 (first tile visible, second wraps to X=0).
- Verify both tiles render at correct wrapped positions.

### 4.5 Block Y Wrap
- Position a 1×2 block at Y=232 (first tile rows visible, second wraps past Y=240).
- Verify only the scanlines in range 0–239 receive pixels.

---

## 5. Priority and Ordering

### 5.1 Sprite-Over-Sprite
- Place two single-tile sprites at the same X,Y coordinates. Entry A at table index 0, entry B at index 1.
- Use different tile colors (tile A = color 1, tile B = color 2).
- Verify: entry A (lower index) is visible; entry B is hidden beneath A.
- Repeat with order reversed; verify dominant entry changes.

### 5.2 Render Order from Table End
- Populate table with 10 entries, each with distinct non-overlapping X positions.
- Verify that entry at index 0 renders on top of entry at index 9 when they are moved to the same position.

### 5.3 Table Terminator
- Place ATTR = 0xFF00 at entry index 5.
- Entries 6–255 have valid coordinates and tile data.
- Verify no pixels from entries 6–255 appear in output.
- Move terminator to index 0; verify no sprites rendered at all.
- Remove terminator entirely (ATTR never reaches 0xFF00); verify all 256 entries processed.

---

## 6. OBJ RAM Latching

### 6.1 Write-After-VBLANK
- Write sprite at position A before VBLANK.
- At VBLANK: latch occurs.
- Write sprite at position B after VBLANK (during active video).
- Verify frame N+1 shows sprite at position A (the pre-VBLANK write).
- Verify frame N+2 shows sprite at position B (the post-VBLANK write, latched at second VBLANK).

### 6.2 OBJ_BASE Relocation
- Write sprites to GFX RAM at base 0x9200.
- Set OBJ_BASE = 0x9200. Trigger VBLANK. Verify sprites appear.
- Write different sprites to GFX RAM at base 0x9000.
- Set OBJ_BASE = 0x9000. Trigger VBLANK. Verify new sprite data appears.

---

## 7. Boundary Conditions for vsub Computation

### 7.1 vsub at Tile Top Row (vsub = 0)
- Place sprite at Y = vrender. Verify vsub = 0, correct ROM row fetched.

### 7.2 vsub at Tile Bottom Row (vsub = 15)
- Place sprite at Y = vrender - 15. Verify vsub = 15.

### 7.3 FLIPY vsub Inversion
- With FLIPY=1, vsub should be `15 - vsub_normal`. Verify at vsub=0 (fetches row 15), vsub=15 (fetches row 0), and vsub=7 (fetches row 8).

### 7.4 Multi-Tile Vertical Sub-Row Selection
- For a 1×2 block, the second tile row (m=1) should use vsub relative to the second tile's top.
- Verify `code_mn = base + 0x10` for m=1 tile.

---

## 8. ROM Interface Edge Cases

### 8.1 All-Transparent Tile
- Return 0xFFFFFFFF from ROM. Verify no pixels written to line buffer.
- Verify chip advances correctly to next tile (no hang on transparent tiles).

### 8.2 Mixed Transparent / Opaque Pixels
- First half of tile: mixed data. Second half: all 0xF (transparent).
- Verify first 8 pixels written, second 8 not written.

### 8.3 rom_ok Delayed
- Assert rom_ok late (simulate slow ROM). Verify chip waits and correctly latches data when rom_ok rises.
- Verify no pixel output corruption from the wait state.

---

## 9. Game Traces for Real-World Coverage

The following CPS1 titles are recommended for extracting OBJ RAM traces that exercise maximum chip functionality:

| Game Title             | OBJ Coverage Focus                                                                |
|------------------------|-----------------------------------------------------------------------------------|
| **Street Fighter II** (sf2, sf2ce) | Large multi-tile character sprites (typically 2×4 or 3×4 blocks). Row-scroll + sprite interaction. High sprite density during fights. |
| **Final Fight** (ffight)      | Multi-tile enemy characters, simultaneous large player sprites. Good Y-position range coverage. |
| **Ghouls'n Ghosts** (ghouls)  | Many small sprites, vertical wrap (sprites walking off bottom). Starfield + sprite layering. |
| **1941: Counter Attack** (1941) | Many overlapping small sprites (bullets, aircraft). Tests priority for dense sprite scenes. |
| **Magic Sword** (msword)      | Tall multi-tile sprites, large boss characters. Tests maximum NY values. |
| **Captain Commando** (captcomm) | 4-player co-op with maximum simultaneous sprite count. Tests near-table-limit scanning. |
| **Cadillacs and Dinosaurs** (dino) | Large enemy sprites with frequent flip transitions. Tests FLIPX/FLIPY toggling. |
| **Varth** (varth)             | Heavy use of small sprites + row scroll on scroll layers. Tests sprite/tilemap priority. |

For each game, capture OBJ RAM contents at VBLANK for frames during active gameplay. Capture 100–200 frames for statistical coverage of all on-screen sprite positions.

---

## 10. Code Paths from MAME Driver Comments

The following items are called out explicitly in the MAME driver source as edge cases:

1. **captcommb kludge**: The bootleg Captain Commando uses a different end-of-table marker convention (ATTR high bit `0x8000` instead of `0xFF00`). This is a game-specific variant; the standard OBJ chip uses `0xFF00`. Test vectors should cover both conventions if the target RTL must support both.

2. **Sprite rendering direction**: Some SF2 hacks render the sprite table in reverse order (last entry first). The standard CPS1 hardware renders from last valid entry toward entry 0 to establish the priority ordering. Test vectors must assume standard ordering unless testing the specific hack path.

3. **Duplicate sprite detection (jotego)**: The jotego reference implementation includes logic to skip sprite entries that are exact duplicates of the previous entry (same X, Y, CODE, ATTR). This is an optimization. Test vectors should include duplicate-entry cases to verify whether the target RTL skips or renders them.

4. **Out-of-range tile codes**: The B-board PAL suppresses ROM access for tile codes outside the game's valid range, forcing transparent output. Test vectors can simulate this by returning 0xFFFFFFFF for designated "out of range" codes.

5. **OBJ_BASE alignment**: The hardware masks `OBJ_BASE × 256` to the nearest 0x0800-byte boundary. Test vectors should verify that misaligned writes to OBJ_BASE are silently corrected to the next valid boundary.

---

## 11. Suggested Test Vector Format

Each test vector record:
```
FRAME_ID   : 32-bit frame counter
OBJ_RAM[]  : 2048 bytes (256 × 8-byte entries), latched at VBLANK
ROM_DATA[] : per-fetch: {rom_addr[19:0], rom_half, rom_data[31:0], rom_ok}
SCANLINE   : 0–239
EXPECTED_LINE_BUF[] : 512 × 9-bit entries {pal[4:0], color[3:0]}
```

Minimal vector set:
- 10 single-tile X-sweep vectors (X = 0, 64, 200, 432, 448, 511, plus wraps)
- 10 single-tile Y-sweep vectors
- 4 flip mode vectors (no flip, X only, Y only, both)
- 4 multi-tile block vectors (1×2, 2×1, 4×4, 16×16)
- 3 priority vectors (two overlapping sprites, ordering variants)
- 2 terminator vectors (early terminate, no terminate)
- 2 transparency vectors (full transparent tile, mixed)
- 20 game trace frames from Street Fighter II attract mode

Total minimum: ~55 vectors. A production test suite should include at least 500 vectors from real game traces.
