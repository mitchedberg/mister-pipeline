# TC0650FDA — Section 1: Register Map, Palette Format, Color Output Spec, Alpha Interface

**Source:** MAME `src/mame/taito/taito_f3_v.cpp` (Bryan McPhail, ywy, 12Me21)
**Status:** Research complete — RTL not yet written

---

## 1. CPU Address Mapping

TC0650FDA occupies the palette RAM window in the F3 CPU address map:

```
CPU Address     Size    Description
--------------------------------------------------------------
0x440000        32KB    Palette RAM (32-bit writes, 0x2000 entries)
  to 0x447FFF           Each 32-bit longword = one palette entry
```

The CPU (68EC020, 32-bit bus) writes 32-bit longwords directly. There is no documented read
path in MAME — palette RAM appears to be write-only from the CPU's perspective.

**Internal address:** 13-bit (0x0000–0x1FFF), selecting one of 8192 palette entries.

---

## 2. Palette Entry Format

### 2a. Standard mode (most F3 games — all games from D77/F3 Package System onward)

```
Bits [31:24]  = (unused / don't care in standard use)
Bits [23:16]  = Red   [7:0]   (8-bit, 0x00 = black, 0xFF = full)
Bits [15:8]   = Green [7:0]
Bits [7:0]    = Blue  [7:0]
```

MAME decodes as: `rgb_t(color).set_a(255)` — the lower 24 bits are a direct `0xRRGGBB` value.

### 2b. Early / 12-bit mode (RINGRAGE, ARABIANM, RIDINGF, SPCINVDX only)

```
Bits [15:12]  = Red   [3:0]   (4-bit, expanded to 8-bit as: R4 * 16)
Bits [11:8]   = Green [3:0]
Bits [7:4]    = Blue  [3:0]
```

The MAME note says this is selectable per-scanline via line RAM `0x6400` bits `[15:12]`, but
that path is unemulated — currently done with a static game-type check.

Line RAM `0x6400` bits for palette format (unemulated):
```
Bit 15 = ? (possibly "interpret this line's entries as 21-bit palette")
Bit 14 = w — 1 = interpret entries as 12-bit RGB; 0 = 24-bit
Bit 13 = B — 0 = enable horizontal forward blur; 1 = no blur
Bit 12 = u — unknown (normally 1)
```

---

## 3. Palette Index Formation

The TC0630FDP supplies palette indices to TC0650FDA. The index is the `color` field from the
rendered pixel. For playfields, this is:

```
src_pal = tile_color_field + pal_add
```

Where `pal_add` (from line RAM `0x9000`–`0x9600`, one per playfield per scanline) is:
```
pal_add = line_ram[9000 + pf_offset + scanline_y] * 16
```

The `color` field for tiles is 9 bits (bits `[8:0]` of the tilemap word), giving entries
into a 512-entry window. With `pal_add` up to 15 × 16 = 240, the effective range is up to
`0x1EF` — well within the 8192-entry palette.

**Palette OR quirk (PR #11788):** For 5/6 bpp tiles, the high graphic plane bits overlap the
low bits of the palette color field. These are combined by bitwise OR at the TC0630FDP output,
not by addition. This affects how palette indices for multi-plane tiles are formed:
```
palette_index = (tile_color_base | tile_extra_planes) + pal_add
```

For sprites, the palette index is 8 bits from the sprite color field (`cccc cccc` in word 4),
forming palette entries in the range 0x000–0x1FF (with 4 priority groups each claiming
2 bits of the color field: bits `[9:8]` select one of 4 sprite groups, bits `[7:0]` are
the palette within that group).

---

## 4. Alpha Blend Interface (TC0630FDP → TC0650FDA)

TC0650FDA receives per-pixel blend data alongside palette indices. The signals (inferred from
MAME's `mix_pix` struct and `render_line` function) are:

```
src_pal[x]   — 13-bit   Source layer palette index for pixel x
dst_pal[x]   — 13-bit   Destination (lower priority) palette index for pixel x
src_blend[x] — 4-bit    Source contribution factor (0–8, fixed3: 8 = 1.0)
dst_blend[x] — 4-bit    Destination contribution factor (0–8)
```

These are set up by the TC0630FDP's layer compositor on a per-pixel, per-scanline basis, then
passed to TC0650FDA for the final RGB multiply-accumulate step.

---

## 5. Blend Contribution Values (Line RAM 0x6200)

One 16-bit register per scanline, latched at the start of each line:

```
Bits [15:12] = B  (blend value B for SOURCE, normal blend mode)
Bits [11:8]  = A  (blend value A for SOURCE, normal blend mode)
Bits [7:4]   = b  (blend value b for DEST, normal blend mode)
Bits [3:0]   = a  (blend value a for DEST, normal blend mode)

Contribution factor = (15 - N) / 8,  range: 0.0 (N=15) to 1.0 (N=7) to >1.0 (N<7)
MAME implements as: blend_val = min(8, 15 - N)   [clamps at 8 = 1.0]
```

The 4 stored values (a, b, A, B) are selected per-pixel based on blend mode and blend_select:

| Layer blend mode | src blend value | dst blend value |
|------------------|-----------------|-----------------|
| Normal (01)      | A or B          | a or b          |
| Reverse (10)     | a or b          | A or B          |
| Opaque (00/11)   | A or B          | a or b          |

The "blend value select" bit (per-tile for playfields, per-line for sprites/pivot) selects
between the two pairs: `(a, A)` vs `(b, B)`.

---

## 6. Blend Computation (render_line equivalent)

Per pixel, after both src and dst palette indices and contribution factors are resolved:

```
R_src = palette[src_pal].R;    // 8-bit from 0xRRGGBB entry
G_src = palette[src_pal].G;
B_src = palette[src_pal].B;

R_dst = palette[dst_pal].R;
G_dst = palette[dst_pal].G;
B_dst = palette[dst_pal].B;

R_out = clamp((R_src * src_blend + R_dst * dst_blend) >> 3, 0, 255)
G_out = clamp((G_src * src_blend + G_dst * dst_blend) >> 3, 0, 255)
B_out = clamp((B_src * src_blend + B_dst * dst_blend) >> 3, 0, 255)
```

The `>>3` is because blend values have fixed3 precision (8 = 1.0 = 0b1_000). The multiply
intermediate is at most `255 * 8 + 255 * 8 = 4080`, which fits in 12 bits. After the shift,
the result is 9 bits wide before clamp, clamped to 8 bits for DAC output.

**Opaque case:** When a layer is opaque (blend_mode = 00 or 11), both src_blend and dst_blend
are non-zero simultaneously (e.g., `A*src + a*dst`). The blend values can be set to `8/8`
(1.0 + 1.0) for an "over-bright additive" effect, or `8/0` for standard opaque.

---

## 7. Background Palette Entry (Line RAM 0x6600)

One 16-bit register per scanline sets the palette index used as the initial `dst_pal` value
(the "background" behind all layers). It participates in alpha blending just like any other
layer's destination.

```
Line RAM 0x6600 = bg_palette index (typically 0 in all known games)
Initial: dst_pal[x] = bg_palette, dst_blend[x] = 8 (100%)
```

---

## 8. Sprite Blend Modes (Line RAM 0x6004 and 0x7400)

Sprites are divided into 4 priority groups (indexed by sprite color bits `[9:8]`). Each group
has an independent blend mode:

```
Line RAM 0x6004 bits [7:0]:
  Bits [7:6] = Alpha mode for sprite group pri=0xC0  (Dd)
  Bits [5:4] = Alpha mode for sprite group pri=0x80  (Cc)
  Bits [3:2] = Alpha mode for sprite group pri=0x40  (Bb)
  Bits [1:0] = Alpha mode for sprite group pri=0x00  (Aa)

  Each 2-bit alpha mode:
    00 = opaque
    01 = normal blend (blend enable)
    10 = reverse blend
    11 = opaque (same as 00)
```

Line RAM `0x7400` carries the blend_select bit for each sprite group (bits `[15:12]`, one per
group), and also enables/disables layers, clip planes, etc.

---

## 9. Playfield Blend Modes (Line RAM 0xB000–0xB600)

One 16-bit word per scanline per playfield:

```
Bits [15:14] = BA — blend mode (A=blend enable, B=reverse blend)
Bit  [13]    = E  — layer enable
Bit  [12]    = I  — clip inverse mode
Bits [11:8]  = cccc — clip plane enable (one bit per clip plane)
Bits [7:4]   = iiii — clip plane inverse
Bits [3:0]   = pppp — layer priority (0 = lowest)
```

Blend value select for playfields is **per-tile** (bit 9 of the tilemap word), not per-line.

---

## 10. Horizontal Blur (Unemulated)

Line RAM `0x6400` bit 13 (`B`): when 0, enables a horizontal forward-blur effect. MAME notes
this as "0 = enable horizontal forward blur (1 = don't blur)" but does not implement it.
Physically this likely averages `pixel[x]` with `pixel[x+1]` (or the previous pixel) before
or after the palette lookup. Low priority for initial implementation.

---

## 11. RTL Design Notes

### Block structure for TC0650FDA RTL:

```
                 [CPU 32-bit bus]
                       |
              [Palette RAM (BRAM 8192×32)]
                  |           |
              [Video]   [CPU write port]
                  |
          [Palette Lookup × 2]
           src_pal → src_rgb
           dst_pal → dst_rgb
                  |
          [Blend Multiply-Accumulate]
           out_R = (src_R*src_blend + dst_R*dst_blend) >> 3
           out_G = (src_G*src_blend + dst_G*dst_blend) >> 3
           out_B = (src_B*src_blend + dst_B*dst_blend) >> 3
                  |
          [8-bit Saturate]
                  |
          [VIDEO_R, VIDEO_G, VIDEO_B out]
```

### Key RTL parameters:
- `PALETTE_DEPTH = 13` (address bits, 8192 entries)
- `ENTRY_WIDTH = 32` (bits per entry)
- `BLEND_WIDTH = 4` (blend factor precision)
- `RGB_OUT = 8` (bits per channel output)

### Port list (draft):
```systemverilog
module TC0650FDA (
    input  logic        clk,
    input  logic        ce_pixel,

    // CPU Interface (32-bit, write-only)
    input  logic [31:0] cpu_data,
    input  logic [12:0] cpu_addr,     // 0x0000-0x1FFF
    input  logic        cpu_we,       // write enable

    // Video Input (from TC0630FDP, per-pixel)
    input  logic [12:0] src_pal,      // source palette index
    input  logic [12:0] dst_pal,      // destination palette index
    input  logic [3:0]  src_blend,    // source contribution (0-8, fixed3)
    input  logic [3:0]  dst_blend,    // destination contribution (0-8, fixed3)
    input  logic        pixel_valid,  // asserted during active display pixels

    // Video Output
    output logic [7:0]  video_r,
    output logic [7:0]  video_g,
    output logic [7:0]  video_b
);
```

Note: True dual-port BRAM is required — CPU writes on one port while video reads on the other.
On F3 hardware, blanking periods gate CPU access; in FPGA implementation a simple dual-port
BRAM handles this without explicit arbitration (no pixel-rate conflicts during active display
as long as CPU writes happen during blanking or use a separate BRAM port).

---

## References

- MAME `taito_f3_v.cpp`: `palette_24bit_w()` (lines 664–679), `render_line()` (lines 1083–1119),
  `mix_line()` (lines 994–1082), `read_line_ram()` (lines 684–860)
- MAME `taito_f3_v.cpp` header comment (lines 1–305): full line RAM register map
- MAME `taito_f3.h`: `mix_pix` struct, `playfield_inf::pal_add`, blend mode bitfield definitions
- MAME PR #11788: palette OR vs ADD quirk explanation
- MAME PR #10920: earlier palette hack (superseded by #11788)
