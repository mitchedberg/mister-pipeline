# TC0650FDA — Palette RAM + DAC + Alpha Blending

**Status:** Not started — research complete, RTL design pending
**System:** Taito F3 Package System (1992–1997)
**Role on PCB:** "Digital to Analog" — palette SRAM controller, alpha blend mixer, RGB888 DAC output
**Source:** MAME `src/mame/taito/taito_f3.cpp` + `taito_f3_v.cpp` + `taito_f3.h`
(Primary authors: Bryan McPhail, ywy, 12Me21)

---

## 1. Does TC0650FDA Appear Explicitly in MAME Source?

**Partially.** MAME names the chip in a header comment and in two PCB layout ASCII diagrams but does
not implement it as a separate device class. Its behavior is folded directly into the F3 driver:

- `palette_24bit_w()` — the CPU-facing palette RAM write handler (in `taito_f3_v.cpp`)
- `render_line()` — the per-scanline alpha blend and DAC-equivalent output (in `taito_f3_v.cpp`)
- `mix_line()` — the layer compositing logic that feeds `render_line()` (in `taito_f3_v.cpp`)

The chip is described as `TC0650FDA "Digital to Analog" - Blending and RGB output` in the driver
comment. On the motherboard PCB (both the early cartridge board and the later "F3 Package System"
board) it sits adjacent to the TC0630FDP display processor and directly drives the RGB output.

---

## 2. What TC0650FDA Does That TC0260DAR Does Not

### 2a. Palette size and bit depth

| Chip       | Entries | Format per entry     | Total RAM  |
|------------|---------|----------------------|------------|
| TC0260DAR  | 4096    | 16-bit (RGB444 or xRGB555) | 8KB  |
| TC0650FDA  | 8192    | 32-bit (RGB888, native) | 32KB   |

F3 palette RAM occupies `0x440000–0x447FFF` (32KB, 0x2000 × 32-bit longwords). MAME configures
`PALETTE(config, m_palette).set_entries(0x2000)` — 8192 entries, double the TC0260DAR capacity.

The primary format for most F3 games is **RGB888** stored as a 32-bit longword. The MAME
`palette_24bit_w` handler decodes it as: `rgb_t(color).set_a(255)` — i.e., the lower 24 bits of
the 32-bit word hold `0xRRGGBB` directly. This is a straightforward 8-bit-per-channel format.

**Exception — early F3 games (12-bit mode):** Four early games (SPCINVDX, RIDINGF, ARABIANM,
RINGRAGE) use a packed 12-bit format in the 32-bit word:
```
Bits [15:12] = R[3:0],  Bits [11:8] = G[3:0],  Bits [7:4] = B[3:0]
(upper 16 bits of longword hold extended bits in later 24-bit interpretation)
```
This is consistent with those titles being early F3 hardware revisions. The line RAM register
at `0x6400` has a `w` bit (bit 13) that selects 12-bit vs 24-bit interpretation per scanline,
but this is currently **unemulated** in MAME — it uses a game-specific static switch instead.

### 2b. Alpha blending — the defining difference

TC0260DAR has no blending capability. It is a palette lookup table and DAC; it outputs RGB pixels
based on a palette index. TC0650FDA does all of this AND performs per-pixel alpha compositing
before DAC output.

**F3 alpha blend system (implemented in TC0650FDA):**

The chip receives two palette indices per pixel (`src_pal` and `dst_pal`) plus two 4-bit blend
contribution values (`src_blend` and `dst_blend`), and computes:

```
output_R = min(255, (src_R * src_blend + dst_R * dst_blend) >> 3)
output_G = min(255, (src_G * src_blend + dst_G * dst_blend) >> 3)
output_B = min(255, (src_B * src_blend + dst_B * dst_blend) >> 3)
```

Where `blend` values are 4-bit quantities from line RAM at `0x6200`:
```
Bits: [BBBB AAAA bbbb aaaa]
opacity = (15 - N) / 8, range 0.0 to 1.0
```
`src_blend` and `dst_blend` are integers 0–8 (fixed3 precision). A value of 8 means 100%
contribution; 0 means transparent.

**4 blend modes per layer (encoded in 2 bits, set per-scanline via line RAM):**
```
00 / 11 = opaque        (no alpha; two contribution values used: e.g., A*src + a*dst)
01      = normal blend  (src contributes at A or B rate; dst at a or b rate)
10      = reverse blend (src/dst contribution values swapped)
```

The blend mode and a per-tile/per-line "blend value select" bit determine which of the four
stored contribution values (a, b, A, B) applies to src and dst. This allows F3 games to produce
effects including additive blending (for fire/explosions), subtractive-equivalent, and standard
alpha.

### 2c. Palette ADD ("palette addition" / pal_add)

Line RAM section `0x9000–0x9600` provides a per-scanline palette offset for each of the 4
playfields. MAME implements this as:

```cpp
line.pf[i].pal_add = pf_pal_add * 16;   // read from line RAM
// ...
inline u16 playfield_inf::palette_adjust(u16 pal) const { return pal + pal_add; }
```

This is an **additive palette index offset** — it shifts a playfield's entire palette window by
up to 15 × 16 = 240 entries each scanline. TC0260DAR has no equivalent feature. Whether
TC0650FDA performs this addition internally (receiving the offset from the TC0630FDP) or whether
the TC0630FDP passes pre-adjusted palette indices is not definitively documented, but the logical
boundary is that the TC0630FDP outputs palette indices and blend control signals to the TC0650FDA,
which then performs the add + lookup + blend + DAC.

### 2d. Palette OR quirk (MAME PR #11788)

In F3 tilemap hardware, the high-bit planes of 5/6 bpp tiles share address bits with the low bits
of the palette "color" field. In MAME's palette_device, these are combined by addition, but the
actual hardware behavior is bitwise OR. MAME PR #11788 corrected this in `get_tile_info` rather
than in the DAC chip itself — but it confirms that the color address into TC0650FDA is formed by
OR-ing tile graphic bits with palette select bits, not by adding them.

### 2e. Background palette entry

Line RAM at `0x6600` sets a background palette entry (the color shown "under" all layers). This
feeds the `dst_pal` initial value and participates in alpha blending — a feature TC0260DAR does
not have.

### 2f. Horizontal blur

Line RAM `0x6400` bit `B` enables a horizontal forward blur pass ("don't blur" when bit = 1).
This is **unemulated** in MAME but is noted as a TC0650FDA feature: it averages adjacent pixel
colors before or after palette lookup, presumably a hardware post-processing step in the DAC path.

---

## 3. CPU Interface

TC0260DAR (from this pipeline's implementation) exposes:
- 16-bit data bus (MDin/MDout)
- 14-bit address (MA)
- Standard 68K bus control signals (CS, UDSn, LDSn, RWn, DTACKn)
- Video input: 14-bit palette index (IM), HBLANK, VBLANK
- Video output: VIDEOR/G/B (8-bit each)
- RAM interface: separate 16-bit bus to external SRAM

TC0650FDA interface (inferred from MAME memory map and PCB layout):
- **Data bus:** 32-bit (F3 uses a 68EC020 with 32-bit bus; palette writes are 32-bit longwords)
- **Address:** CPU address `0x440000–0x447FFF` decoded externally, 13-bit internal index (0x2000 entries)
- **CPU writes:** 32-bit palette entry writes; no documented read path (write-only in MAME)
- **Video input:** Palette index from TC0630FDP — likely 13-bit (log2(8192)); plus blend mode
  signals and contribution values from TC0630FDP line RAM decode logic
- **Video output:** Analog RGB (8-bit per channel per MAME model, likely actual DAC precision
  is 6 or 8 bits on physical hardware)
- **No external SRAM bus:** Unlike TC0260DAR, palette RAM access appears to be CPU-bus direct
  (MAME maps paletteram32 as a shared_ptr — no separate RAM chip interface visible in source)

---

## 4. Can TC0260DAR Be Used as a Starting Point?

**No — the architectures are too different for a meaningful code reuse.** The 95-line TC0260DAR
module is essentially: palette index in → SRAM lookup → bit-shuffle to RGB888 out. It has no
blend logic, no pal_add, no dual-source compositing.

TC0650FDA requires:

1. A 32-bit-wide, 8192-entry palette SRAM (or block RAM)
2. Per-pixel dual palette lookup (src_pal + dst_pal, both 13-bit)
3. Per-pixel blend contribution multipliers (4-bit × 4, applied per channel)
4. Saturating 8-bit RGB adder/accumulator
5. Optional horizontal blur pass (unemulated, low priority)
6. Optional 12-bit legacy palette decode mode (only 4 early games need it)

**Reuse assessment:** The TC0260DAR module provides zero reusable RTL. The only conceptual
similarity is "palette index in, RGB out" — but even the data path width, SRAM interface, bus
width, and output path are completely different. TC0650FDA is a clean-sheet design.

The TC0260DAR module can be kept as a reference for how the external SRAM interface pattern
works, but its logic does not transfer.

---

## 5. Does TC0650FDA Need to Be Built Before F3 Gate 4?

**No. F3 tiles can be tested with a stub palette passthrough through at least Gate 3.**

Recommended stub for Gate 2–3 (tile render validation):
- Map palette index bits [7:0] directly to `{R[7:0], G[7:0], B[7:0]}` using a simple identity
  or color-band mapping. This lets you verify tile geometry, scroll, and priority behavior
  visually without needing correct colors.
- Alternatively, implement the 32-bit SRAM lookup without blending first (palette-only stub),
  which gives correct colors but no transparency/alpha — enough for tile/scroll/priority work.

**TC0650FDA needs to be complete before Gate 4** (full frame comparison / TAS validation), because:
- Alpha blending affects which pixels are written to the framebuffer
- Transparent pixel handling (color index 0 = transparent for all layers) is part of the
  TC0650FDA's "blank pixel" detection
- pal_add affects palette correctness on scrolling levels

**Recommendation:** Build TC0650FDA in two stages:
1. **Stage A (before Gate 3):** Palette-only — 32-bit SRAM, single palette lookup, RGB888 output,
   no blending, no pal_add. Sufficient for tile geometry validation.
2. **Stage B (before Gate 4):** Full blend circuit — dual palette lookup, contribution multipliers,
   saturating add, pal_add offset.

---

## 6. Summary Comparison Table

| Feature                         | TC0260DAR (F2)      | TC0650FDA (F3)           |
|---------------------------------|---------------------|--------------------------|
| Palette entries                 | 4096                | 8192                     |
| Entry format                    | 16-bit (RGB444/555) | 32-bit (RGB888)          |
| CPU bus width                   | 16-bit              | 32-bit                   |
| External SRAM                   | Yes (separate bus)  | No (CPU bus direct)      |
| Alpha blending                  | None                | Full (src+dst blend)     |
| Blend modes                     | —                   | 4 (opaque/normal/reverse)|
| Blend values                    | —                   | 4-bit × 4 (a/b/A/B)     |
| Palette add (per-scanline)      | No                  | Yes (per playfield)      |
| Background palette entry        | No                  | Yes (line RAM 0x6600)    |
| Horizontal blur                 | No                  | Yes (unemulated)         |
| 12-bit legacy mode              | No                  | Yes (4 early games)      |
| RTL reuse from TC0260DAR        | n/a                 | Zero                     |
| MAME separate device class      | No (folded in)      | No (folded in)           |

---

## References

- MAME `src/mame/taito/taito_f3.cpp` — memory map, PCB layouts, chip names
- MAME `src/mame/taito/taito_f3_v.cpp` — `palette_24bit_w`, `render_line`, `mix_line`, register docs
- MAME `src/mame/taito/taito_f3.h` — struct definitions for blend/mix/layer data
- MAME PR #11788 — palette OR vs ADD clarification
- `../tc0260dar.sv` — TC0260DAR reference (conceptual only; no code reuse)
