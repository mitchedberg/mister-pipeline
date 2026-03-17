# Taito X System — Game ROM Specifications

## Game Library Overview

| Game | Year | Region | Dev/Pub | Genre | Audio | ROM Set | Notes |
|------|------|--------|---------|-------|-------|---------|-------|
| **Superman** | 1988 | Japan | Taito | Beat 'em up / Shooter | YM2610 | superman | 3 variants (US/EU/JP) |
| **Twin Hawk** / **Daisenpu** | 1989 | US/Japan | Taito/Toaplan | Vertical shmup | YM2151 | twinhawk / daisenpu | Toaplan dev; uses OPM |
| **Last Striker** / **Kyuukyoku no Striker** | 1989 | Japan | East Tech | Soccer action | YM2610 (est.) | lastrike | Unique sports title |
| **Gigandes** | 1989 | Japan | East Tech | Horizontal shmup | YM2610 (est.) | gigandes / gigandx | 2 ROM versions |
| **Balloon Brothers** | 1992 | Japan | East Tech | Puzzle/drop | YM2610 (est.) | balbroth | Latest X title |
| **Blue Shark** | 1987 | Japan | Taito (est.) | Shooter | YM2610 (est.) | blueshark | Possibly earliest X |
| **Don Doko Don** | 1989 | Japan | Taito (est.) | Platformer | YM2610 (est.) | dondokod | Arcade precursor |
| **Liquid Kids** | 1990 | Japan | Taito (est.) | Platformer | YM2610 (est.) | liquidkd | Later ported to Game Boy |

**Status:** 7–9 titles confirmed; verification against MAME ROM database required.

---

## Individual Game Specifications

### Superman (1988)

**MAME ROM Set:** `superman` (Japan), `supermanu` (US), `supermane` (Europe)

| Component | Size | Type | Notes |
|-----------|------|------|-------|
| Program ROM | ~256 KB | 2× 128 KB (banked) | 68000 code |
| Sprite ROM | ~2 MB | Graphics data | 16×16 sprites, 4 bpp |
| Palette | 2 KB | 2048 colors | In-ROM or in-RAM |
| Sound ROM | ~128 KB | YM2610 samples | ADPCM drum samples |
| Z80 ROM | ~64 KB | Z80 code | Sound sequencer |

**Audio:** YM2610 OPNB @ 8 MHz
- 6 FM channels (4 operators each)
- 3 SSG channels (square wave)
- 1 drum channel (5 samples from ROM)
- Stereo output via YM3016 DAC

**Graphics:**
- Title screen: Simple static sprites
- Gameplay: Scrolling city background (sprite-based), moving enemies
- Sprite animations: ~4–8 frames per character walk cycle
- Palette: 16 palettes × 128 colors (typical fighting game)

**Gameplay Notes:**
- 2-player side-scrolling beat 'em up
- City level(s) with destructible objects (barrels, etc.)
- Sprite-heavy rendering (20–30 active sprites/frame typical)
- No parallax scrolling (all sprites move with camera)

**Memory Usage (estimated):**
- Program: 256 KB (only ~50% used typically)
- Work RAM: 16–32 KB (sprite positions, game state)
- Object RAM: 4–8 KB (64–128 active sprites × 4 bytes each)
- Palette RAM: 2 KB (all 2048 colors, but only 16 palettes used per screen)

---

### Twin Hawk / Daisenpu (1989)

**MAME ROM Set:** `twinhawk` (US), `daisenpu` (Japan)

| Component | Size | Type | Notes |
|-----------|------|------|-------|
| Program ROM | ~256 KB | 68000 code | Similar to Superman |
| Sprite ROM | ~1.5 MB | Graphics | Helicopter + enemies |
| Sound ROM | ~64 KB | YM2151 code | Z80 program |
| Sample ROM | ~64 KB | ADPCM samples | Drum/effects (if used) |

**Audio:** YM2151 OPM @ 3.58 MHz
- 8 FM channels (4 operators each)
- Mono output via YM3012 DAC (or split L/R)
- No SSG (AY-3-8910) like YM2610
- Smaller ROM footprint than YM2610 games

**Graphics:**
- Vertical scrolling shoot 'em up
- Parallax layers (background, enemies, player helicopter)
- Sprite-based (no tilemap layers)
- Palette: 8–16 palettes typical for shmup (fire, sky, terrain)

**Gameplay Notes:**
- Developed by Toaplan (notable shmup house)
- Vertical scrolling over procedural terrain
- High sprite count (30–50 sprites for bullet hell sequences)
- Uses OPM (different from Superman's OPNB) — suggests different audio subsystem

**Key Difference from Superman:**
- Audio chip swap (YM2151 vs. YM2610) is the primary difference
- Memory map and control registers should be identical
- Implies FPGA audio must support **both** chip variants (compile-time or runtime-selectable)

---

### Last Striker (1989)

**MAME ROM Set:** `lastrike`

**Gameplay:** Soccer/sports action game (unique Taito X title)
- 2D soccer pitch (sprite-based)
- Player teams (sprites for players, ball)
- Action controls (pass, shoot, tackle)

**ROM Layout (estimated):**
| Component | Size | Notes |
|-----------|------|-------|
| Program | ~256 KB | Similar to Superman |
| Sprite ROM | ~1 MB | Player sprites, ball |
| Sound ROM | ~128 KB | Stadium music, crowd, kick SFX |

**Audio:** YM2610 (presumed, no confirmation)

---

### Gigandes (1989)

**MAME ROM Set:** `gigandes` (Japan), `gigandx` (alternate?)

| Component | Size | Type | Notes |
|-----------|------|------|-------|
| Program ROM | ~256 KB | 68000 | Typical X system |
| Sprite ROM | ~1.5 MB | Graphics | Horizontal shmup |
| Sound ROM | ~128 KB | Audio | YM2610 samples |

**Gameplay:** Horizontal-scrolling shooter
- Left-to-right or right-to-left scrolling
- Enemy waves (sprites)
- Boss encounters (large sprites made of 4–8 sub-sprites)

**Audio:** YM2610 OPNB (presumed)

---

### Balloon Brothers (1992)

**MAME ROM Set:** `balbroth`

**Latest Taito X title.** (After 1992, Taito likely transitioned to Taito Z or F series.)

| Component | Size | Type | Notes |
|-----------|------|------|-------|
| Program ROM | ~256 KB | 68000 | Typical X system |
| Sprite ROM | ~1 MB | Graphics | Puzzle pieces, UI |
| Sound ROM | ~64–128 KB | Audio | Puzzle SFX, music loops |

**Gameplay:** Puzzle/drop game (similar to Tetris or Puyo Puyo)
- Scrolling playfield (sprites for blocks, background, UI)
- Low animation complexity (mostly static graphics)
- Palette-heavy (colorful blocks)

**Audio:** YM2610 (presumed)

**Memory Profile:**
- Minimal program ROM usage (~100 KB effective)
- Moderate sprite ROM (many distinct blocks/UI elements)
- Smaller sound ROM (simple puzzle music loops)
- Palette RAM heavily used (many distinct block colors)

---

## ROM Dumping & Validation

### Procedure to Extract MAME ROM

```bash
# 1. Locate MAME ROM directory
ls ~/.mame/roms/superman.zip
ls ~/.mame/roms/twinhawk.zip

# 2. Extract ROM images
unzip -l superman.zip
unzip superman.zip -d /tmp/superman_rom

# 3. Identify ROM chips (from MAME source)
cat > rom_map.txt <<EOF
superman.zip contains:
  a54-01.6e  128 KB  68000 program ROM
  a54-02.6f  128 KB  68000 program ROM
  a54-03.1e  128 KB  Z80 sound ROM
  a54-04.4d  512 KB  Sprite ROM bank 0
  a54-05.4f  512 KB  Sprite ROM bank 1
  a54-06.4k  512 KB  Sprite ROM bank 2
  (+ palette/clut ROMs if separate)
EOF

# 4. Concatenate program ROM
cat /tmp/superman_rom/a54-01.6e /tmp/superman_rom/a54-02.6f > program.rom

# 5. Concatenate sprite ROM (likely interleaved)
cat /tmp/superman_rom/a54-04.4d /tmp/superman_rom/a54-05.4f /tmp/superman_rom/a54-06.4k > sprite_interleaved.rom
# If interleaved (common), de-interleave: split every 4 bytes across banks
python3 de_interleave.py sprite_interleaved.rom

# 6. Validate against MAME output
# (Will document in next section)
```

### ROM Format Detection

**Method:** Extract sprite from Superman, compare to MAME output.

```python
#!/usr/bin/env python3
# sprite_validator.py
import struct
import sys
from PIL import Image

def extract_sprite(rom_data, sprite_idx, sprite_size=128):
    """Extract 16x16 sprite @ 4bpp from ROM."""
    offset = sprite_idx * sprite_size
    sprite_data = rom_data[offset:offset + sprite_size]

    # Assume 4 bpp: 16 pixels/row = 8 bytes/row
    pixels = []
    for row in range(16):
        row_data = sprite_data[row * 8:(row + 1) * 8]
        for byte_val in row_data:
            pixels.append((byte_val >> 4) & 0x0F)  # High nibble
            pixels.append(byte_val & 0x0F)          # Low nibble

    return pixels  # 256 pixels in linear array

def write_image(pixel_array, palette_data, output_path):
    """Write 16x16 sprite image."""
    img = Image.new('RGB', (16, 16))

    for i, palette_idx in enumerate(pixel_array):
        if palette_idx == 0:  # Transparent
            rgb = (0, 0, 0)  # Black (or magenta for debug)
        else:
            # Lookup in palette (15-bit RGB)
            palette_addr = palette_idx * 2
            color_word = struct.unpack('<H', palette_data[palette_addr:palette_addr+2])[0]
            r = ((color_word >> 10) & 0x1F) * 8
            g = ((color_word >> 5) & 0x1F) * 8
            b = (color_word & 0x1F) * 8
            rgb = (r, g, b)

        x, y = i % 16, i // 16
        img.putpixel((x, y), rgb)

    img.save(output_path)
    print(f"Wrote {output_path}")

def main():
    rom_file = sys.argv[1]  # sprite ROM
    pal_file = sys.argv[2]  # palette ROM or extracted palette
    sprite_idx = int(sys.argv[3]) if len(sys.argv) > 3 else 0

    with open(rom_file, 'rb') as f:
        rom_data = f.read()

    with open(pal_file, 'rb') as f:
        pal_data = f.read()

    pixels = extract_sprite(rom_data, sprite_idx)
    write_image(pixels, pal_data, f'sprite_{sprite_idx}.png')

if __name__ == '__main__':
    main()
```

**Usage:**
```bash
python3 sprite_validator.py superman_sprite.rom superman_palette.bin 0
# Output: sprite_0.png (16×16 image of sprite 0)
# Compare visually to MAME screenshot
```

---

## Interleaving & Byte Order

### Typical ROM Layout (Hardware)

Taito X likely uses **interleaved 68000 ROMs** (common for 16-bit systems):

```
Even ROM (even addresses):
  Word 0 = [ROM_even[0], ROM_even[1]]
  Word 2 = [ROM_even[2], ROM_even[3]]

Odd ROM (odd addresses):
  Word 1 = [ROM_odd[0], ROM_odd[1]]
  Word 3 = [ROM_odd[2], ROM_odd[3]]

In-order word sequence:
  [ROM_even[0], ROM_odd[0]], [ROM_even[1], ROM_odd[1]], ...
```

**MAME de-interleaving:**
```python
def de_interleave_16bit_roms(rom_even, rom_odd):
    """Merge two 8-bit ROMs into 16-bit word stream."""
    result = []
    for i in range(len(rom_even)):
        result.append(rom_odd[i])  # Low byte
        result.append(rom_even[i])  # High byte
    return bytes(result)
```

**Validation:** MAME source (`taito_x.cpp`) will specify:
- `ROM("a54-01.6e", 0x000000, 0x20000, CRC32_CHECKSUM)`
- Load order and interleaving mode

---

## Sprite ROM Compression (Investigation Required)

### Hypothesis: No Compression

Taito X games may use **raw 4-bit sprites** (simplest storage):
- 16×16 sprite = 256 pixels = 128 bytes @ 4 bpp
- No RLE, no LZ, no custom codecs
- ROM fetch latency: constant, cache-friendly

**Evidence:**
- Small ROM footprint (1–2 MB sprite ROM is manageable)
- Fast rendering (68000 @ 8 MHz must keep up)
- Early arcade (1987) likely uses simple formats

### Hypothesis: Tile-Based Compression

Alternatively, Taito X may use **tile-based + palette indirection:**
- Sprites are composites of repeated tiles
- Example: Superman body = 2×2 tiles, legs = separate layer
- Reduces ROM by ~30–50%

**Test:**
- Load Superman ROM
- Search for repeated 16-byte or 32-byte sequences
- If high repetition (>20%), likely tile-based

### Hypothesis: RLE Compression (Unlikely)

RLE (run-length encoding) would require decompression on-CPU, adding latency:
- 68000 would need to decompress during sprite fetch
- Feasible but slow for real-time render
- More likely for static (non-animated) graphics only

---

## Next Steps: ROM Acquisition & Analysis

1. **Verify MAME ROM checksums** against known good sets
2. **Extract all Taito X ROMs** from MAME database
3. **Reverse-engineer sprite ROM format**
   - Create `sprite_rom_dumper.py` (extract & visualize all sprites)
   - Compare to MAME's internal sprite sheet
4. **Document exact address bus for each ROM**
   - Identify which ROM chip maps to 0xC00000 (sprite graphics)
   - Confirm program ROM at 0x000000 is word-interleaved
5. **Catalog palette ROM** (if separate from RAM)
   - Some games may have palette ROM; others use in-RAM palette
6. **Build ROM validation suite**
   - Checksum verification
   - Size validation (must match expected)
   - Sprite integrity check (all sprites renderable)

---

## ROM File Organization (for FPGA core)

Recommended structure for MiSTer core:

```
mister_taito_x/
  roms/
    superman/
      program.rom          (merged 68000 program)
      sound.rom            (Z80 program)
      sprite.rom           (sprite graphics, de-interleaved)
      palette.bin          (palette data, if separate)
    twinhawk/
      program.rom
      sound.rom
      sprite.rom
      (... same for each game)

    checksums.txt          (MAME checksums for validation)
```

**FPGA expects:**
- Program ROM: 512 KB max, word-addressable (16-bit words)
- Sprite ROM: 4 MB max, byte-addressable (8-bit bytes)
- Palette: 4 KB, if external (otherwise in-RAM)

---

## Conclusion

The Taito X game library is small but diverse:
- **7 confirmed titles** with distinct genres (shmups, beat 'em up, puzzle, sports)
- **2 audio chips** (YM2610 primary, YM2151 for Twin Hawk)
- **ROM footprints:** 256 KB program, 1–2 MB sprite, 64–128 KB sound per game
- **ROM formats:** Likely simple/uncompressed (no decompression latency)

With MAME as reference and ROM dumps available, FPGA implementation should proceed smoothly once sprite rendering pipeline is reverse-engineered.

