#!/usr/bin/env python3
"""
generate_step12_vectors.py — Step 12 test vector generator for tc0630fdp.

Produces step12_vectors.jsonl: Clip Planes.

Test cases (per section3_rtl_plan.md Step 12):
  1. Enable clip plane 0 for PF1, left=50, right=200. Verify PF1 visible only in x∈[50,200].
     Test pixels: x=49 (clipped), x=50 (visible, left edge), x=125 (visible, mid),
                  x=200 (visible, right edge), x=201 (clipped).
  2. Two clip planes both enabled for PF2. Verify intersection: only inside BOTH windows.
  3. Invert mode on one plane: verify pixels inside window are blanked, outside visible.
  4. PF3 with clip, PF4 without clip: verify clip does not affect PF4.
  5. Clip with layer = priority 15 sprite: verify sprite is also clipped.
  6. Alt-clip (clip_invert sense reversal): test pbobble4/commandw inversion sense bit.
  7. Clip boundary edge: pixel at exactly left boundary. Verify included (left is inclusive).

Additional tests:
  8. All planes disabled: no clip, full layer visible.
  9. Clip plane 2 and 3 enabled for PF3. Intersection window.
 10. Sprite with no clip (spr_clip_en=0): sprite always visible.
 11. Multiple PFs, only one clipped: verify correct isolation.
 12. Invert + sense bit: double negation restores normal behavior.

Line RAM address map (word addresses):
  §9.3 Clip plane data:
    Plane 0: word 0x2800 + scan,  bits[15:8]=right, bits[7:0]=left
    Plane 1: word 0x2900 + scan
    Plane 2: word 0x2A00 + scan
    Plane 3: word 0x2B00 + scan
  §9.12 PF mix/priority (pp_word) — also contains clip config:
    PF1: word 0x5800 + scan
    PF2: word 0x5900 + scan
    PF3: word 0x5A00 + scan
    PF4: word 0x5B00 + scan
    bits[3:0]  = priority
    bits[7:4]  = clip invert per plane
    bits[11:8] = clip enable per plane
    bit[12]    = inversion sense
  §9.7 Sprite mix/clip:
    word 0x3A00 + scan
    bits[11:8] = spr clip enable, bits[7:4] = spr clip invert, bit[0] = sense
  Priority enables:
    word 0x0700 + scan,  bit[n] = enable PF(n+1)
  Sprite priority:
    word 0x3B00 + scan
"""

import json
import os
from fdp_model import TaitoF3Model, V_START, V_END, H_START

vectors = []


def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
m = TaitoF3Model()


def model_reset():
    """Reset transient state (GFX ROM and Char RAM preserved)."""
    m.ctrl     = [0] * 16
    m.pf_ram   = [[0] * m.PF_RAM_WORDS for _ in range(4)]
    m.text_ram = [0] * m.TEXT_RAM_WORDS
    m.line_ram = [0] * m.LINE_RAM_WORDS
    m.spr_ram  = [0] * m.SPR_RAM_WORDS


# ---------------------------------------------------------------------------
LINE_BASE = 0x10000
SPR_BASE  = 0x20000


def write_line(word_offset: int, data: int, note: str = "") -> None:
    """Emit a write_line op AND mirror to model."""
    chip_addr = LINE_BASE + word_offset
    emit({"op": "write_line",
          "addr": chip_addr,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"line_ram[{word_offset:#06x}] = {data:#06x}"})
    m.write_line_ram(word_offset, data)


def clear_scanline_effects(render_scan: int, note_pfx: str = "") -> None:
    """Zero all Line RAM effect words for render_scan (including Step 12 clip data)."""
    s = render_scan & 0xFF
    tag = note_pfx or f"clear scan={render_scan}"

    # Enable words
    write_line(0x0000 + s, 0, f"{tag} clear colscroll/alt-tmap enable")
    write_line(0x0400 + s, 0, f"{tag} clear zoom enable")
    write_line(0x0500 + s, 0, f"{tag} clear pal-add enable")
    write_line(0x0600 + s, 0, f"{tag} clear rowscroll enable")
    write_line(0x0700 + s, 0, f"{tag} clear pf-priority enable")

    # Data words
    for n in range(4):
        write_line(0x5000 + n * 0x100 + s, 0, f"{tag} clear rowscroll PF{n+1}")
        write_line(0x2000 + n * 0x100 + s, 0, f"{tag} clear colscroll PF{n+1}")
        write_line(0x4800 + n * 0x100 + s, 0, f"{tag} clear pal-add PF{n+1}")
        # pp_word (priority + clip config) for each PF
        write_line(0x5800 + n * 0x100 + s, 0, f"{tag} clear pf-prio+clip PF{n+1}")

    # Zoom data defaults
    write_line(0x4000 + s, 0x8000, f"{tag} clear zoom PF1")
    write_line(0x4100 + s, 0x8000, f"{tag} clear zoom PF3")
    write_line(0x4200 + s, 0x8000, f"{tag} clear zoom PF2/PF4-Y")
    write_line(0x4300 + s, 0x8000, f"{tag} clear zoom PF4/PF2-Y")

    # Sprite priority + sprite mix/clip
    write_line(0x3B00 + s, 0, f"{tag} clear spr-prio")
    write_line(0x3A00 + s, 0, f"{tag} clear spr-clip §9.7")

    # Clip plane data (default: left=0, right=0xFF — full window = no restriction)
    for p in range(4):
        base = [0x2800, 0x2900, 0x2A00, 0x2B00]
        write_line(base[p] + s, 0xFF00, f"{tag} clear clip plane {p} (l=0,r=255)")


def write_spr_word(word_offset: int, data: int, note: str = "") -> None:
    chip_addr = SPR_BASE + word_offset
    emit({"op": "write_sprite",
          "addr": chip_addr,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"spr_ram[{word_offset:#06x}] = {data:#06x}"})


def clear_sprite_entry(idx: int, note: str = "") -> None:
    """Zero sprite entry idx (8 words)."""
    base = idx * 8
    tag = note or f"clear spr[{idx}]"
    for w in range(8):
        write_spr_word(base + w, 0, f"{tag} word{w}")


def write_sprite_entry(idx: int, tile_code: int, sx: int, sy: int,
                       color: int, flipx: bool = False, flipy: bool = False,
                       x_zoom: int = 0x00, y_zoom: int = 0x00,
                       note: str = "") -> None:
    """Write a full sprite entry (words 0..6) to Sprite RAM (emit + model)."""
    base = idx * 8
    tile_lo = tile_code & 0xFFFF
    tile_hi = (tile_code >> 16) & 0x1
    sx_12   = sx & 0xFFF
    sy_12   = sy & 0xFFF
    w1      = ((y_zoom & 0xFF) << 8) | (x_zoom & 0xFF)
    w4      = color & 0xFF
    if flipx: w4 |= (1 << 9)
    if flipy: w4 |= (1 << 10)
    tag = note or f"spr[{idx}]"
    write_spr_word(base + 0, tile_lo,  f"{tag} word0=tile_lo")
    write_spr_word(base + 1, w1,       f"{tag} word1=zoom")
    write_spr_word(base + 2, sx_12,    f"{tag} word2=sx={sx}")
    write_spr_word(base + 3, sy_12,    f"{tag} word3=sy={sy}")
    write_spr_word(base + 4, w4,       f"{tag} word4=ctrl color={color:#04x}")
    write_spr_word(base + 5, tile_hi,  f"{tag} word5=tile_hi")
    write_spr_word(base + 6, 0,        f"{tag} word6=no_jump")
    m.write_sprite_entry(idx, tile_code, sx, sy, color, flipx, flipy,
                         x_zoom=x_zoom, y_zoom=y_zoom)


def write_gfx_word(word_addr: int, data: int, note: str = "") -> None:
    emit({"op": "write_gfx",
          "gfx_addr": word_addr,
          "gfx_data": data & 0xFFFFFFFF,
          "note": note or f"gfx[{word_addr:#06x}] = {data:#010x}"})
    if word_addr < m.GFX_ROM_WORDS:
        m.gfx_rom[word_addr] = data & 0xFFFFFFFF


def write_gfx_solid_tile(tile_code: int, pen: int, note: str = "") -> None:
    """Fill all 16 rows of a 16×16 tile with a solid pen value."""
    n = pen & 0xF
    word = 0
    for _ in range(8):
        word = (word << 4) | n
    for row in range(16):
        base = tile_code * 32 + row * 2
        write_gfx_word(base,     word, note or f"gfx tile={tile_code} row={row} pen={pen:#x} L")
        write_gfx_word(base + 1, word, note or f"gfx tile={tile_code} row={row} pen={pen:#x} R")


def clear_pf_row(render_scan: int, note: str = "") -> None:
    """Clear all tiles (all 4 PF planes, all 20 column positions) on the tile row
    that corresponds to render_scan. This prevents BRAM contamination from prior tests.

    tile_y = render_scan // 16.  All tile_x 0..19 are cleared (transparent code=0).
    """
    tile_y = render_scan // 16
    tag = note or f"clear_pf_row tile_y={tile_y} for scan={render_scan}"
    for _plane in range(4):
        for _tx in range(20):
            tile_idx = tile_y * 32 + _tx
            word_base = tile_idx * 2
            chip_base = 0x04000 + _plane * 0x2000
            emit({"op": "write_pf",
                  "addr": chip_base + word_base,
                  "data": 0,
                  "be": 3,
                  "plane": _plane,
                  "note": f"{tag} pl={_plane} tx={_tx} attr=0"})
            emit({"op": "write_pf",
                  "addr": chip_base + word_base + 1,
                  "data": 0,
                  "be": 3,
                  "plane": _plane,
                  "note": f"{tag} pl={_plane} tx={_tx} code=0"})
            m.pf_ram[_plane][word_base]     = 0
            m.pf_ram[_plane][word_base + 1] = 0


def write_pf_tile(plane: int, tile_x: int, tile_y: int,
                  tile_code: int, palette: int = 0,
                  flipx: bool = False, flipy: bool = False) -> None:
    """Write a single PF tile entry to PF RAM."""
    tile_idx = tile_y * 32 + tile_x
    word_base = tile_idx * 2
    attr = palette & 0x1FF
    if flipx: attr |= (1 << 14)
    if flipy: attr |= (1 << 15)
    chip_base = 0x04000 + plane * 0x2000
    emit({"op": "write_pf",
          "addr": chip_base + word_base,
          "data": attr,
          "be": 3,
          "plane": plane,
          "note": f"pf{plane+1} tile({tile_x},{tile_y}) attr={attr:#06x}"})
    emit({"op": "write_pf",
          "addr": chip_base + word_base + 1,
          "data": tile_code & 0xFFFF,
          "be": 3,
          "plane": plane,
          "note": f"pf{plane+1} tile({tile_x},{tile_y}) code={tile_code:#06x}"})
    m.pf_ram[plane][word_base]     = attr
    m.pf_ram[plane][word_base + 1] = tile_code & 0xFFFF


def set_pf_priority(plane: int, scan: int, prio: int) -> None:
    """Enable and set PF priority for one scanline (writes enable + low 4 bits of pp_word)."""
    en_word = m.line_ram[0x0700 + (scan & 0xFF)]
    en_word |= (1 << plane)
    write_line(0x0700 + (scan & 0xFF), en_word, f"pf_prio_en scan={scan} plane={plane}")
    # pp_word: preserve existing clip config bits, update priority in bits[3:0]
    pp_word = m.line_ram[0x5800 + plane * 0x100 + (scan & 0xFF)]
    pp_word = (pp_word & 0xFFF0) | (prio & 0xF)
    write_line(0x5800 + plane * 0x100 + (scan & 0xFF), pp_word,
               f"pf_prio data scan={scan} plane={plane} prio={prio}")


def set_pf_clip(plane: int, scan: int, prio: int,
                clip_en: int, clip_inv: int = 0, clip_sense: int = 0) -> None:
    """Write full pp_word for a PF plane with priority + clip configuration.

    pp_word bits:
      [3:0]  = priority
      [7:4]  = clip invert per plane (4 bits)
      [11:8] = clip enable per plane (4 bits)
      [12]   = inversion sense
    Also enables the priority enable bit in 0x0700+scan.
    """
    s = scan & 0xFF
    # Enable priority for this PF
    en_word = m.line_ram[0x0700 + s]
    en_word |= (1 << plane)
    write_line(0x0700 + s, en_word, f"set_pf_clip enable prio plane={plane} scan={scan}")
    # Build pp_word
    pp_word = (prio & 0xF) | ((clip_inv & 0xF) << 4) | ((clip_en & 0xF) << 8) | \
              ((clip_sense & 0x1) << 12)
    write_line(0x5800 + plane * 0x100 + s, pp_word,
               f"set_pf_clip pp_word scan={scan} plane={plane} prio={prio} "
               f"clip_en={clip_en:#03x} clip_inv={clip_inv:#03x} sense={clip_sense}")


def set_clip_plane(plane_idx: int, scan: int, left: int, right: int) -> None:
    """Write clip plane left/right boundaries for one scanline.

    §9.3 format: bits[7:0]=left, bits[15:8]=right (8-bit values).
    """
    s = scan & 0xFF
    base = [0x2800, 0x2900, 0x2A00, 0x2B00]
    word = ((right & 0xFF) << 8) | (left & 0xFF)
    write_line(base[plane_idx] + s, word,
               f"clip_plane[{plane_idx}] scan={scan} left={left} right={right}")


def set_spr_priority(scan: int,
                     prio_g0: int = 0, prio_g1: int = 0,
                     prio_g2: int = 0, prio_g3: int = 0) -> None:
    """Set sprite group priorities for one scanline."""
    sp_word = ((prio_g3 & 0xF) << 12) | ((prio_g2 & 0xF) << 8) | \
              ((prio_g1 & 0xF) << 4)  | (prio_g0 & 0xF)
    write_line(0x3B00 + (scan & 0xFF), sp_word,
               f"spr_prio scan={scan} g0={prio_g0} g1={prio_g1} g2={prio_g2} g3={prio_g3}")


def set_spr_clip(scan: int, clip_en: int, clip_inv: int = 0, clip_sense: int = 0) -> None:
    """Write sprite mix/clip word for one scanline (§9.7).

    §9.7 sm_word bits:
      [11:8] = clip enable per plane
      [7:4]  = clip invert per plane
      [0]    = inversion sense
    """
    s = scan & 0xFF
    sm_word = ((clip_en & 0xF) << 8) | ((clip_inv & 0xF) << 4) | (clip_sense & 0x1)
    write_line(0x3A00 + s, sm_word,
               f"spr_clip scan={scan} en={clip_en:#03x} inv={clip_inv:#03x} sense={clip_sense}")


def check_colmix(target_vpos: int, screen_col: int,
                 exp_pixel: int, note: str) -> None:
    emit({"op": "check_colmix_pixel",
          "vpos":       target_vpos,
          "screen_col": screen_col,
          "exp_pixel":  exp_pixel & 0x1FFF,
          "note":       note})


def model_colmix_pixel(vpos: int, col: int, spr_linebuf: list = None) -> int:
    """Query composite model pixel at (vpos+1, col)."""
    result = m.composite_scanline(vpos, spr_linebuf)
    return result[col]


# ===========================================================================
# Pre-load GFX ROM with solid tiles (persistent across resets)
# ===========================================================================
# Re-initialize the same tiles as step11 to be safe (BRAM persists across tests)
GFX_TRANSPARENT = 0x00
for tc in range(1, 16):
    write_gfx_solid_tile(tc, tc, f"init: solid tile {tc:#x} pen={tc:#x}")
write_gfx_solid_tile(0x00, 0, "init: tile 0x00 pen=0 (transparent)")
write_gfx_solid_tile(0x10, 1, "init: tile 0x10 pen=1")
write_gfx_solid_tile(0x11, 2, "init: tile 0x11 pen=2")
write_gfx_solid_tile(0x12, 3, "init: tile 0x12 pen=3")
write_gfx_solid_tile(0x13, 4, "init: tile 0x13 pen=4")


# ===========================================================================
# Test 1: Single clip plane on PF1. Verify boundary behavior.
#
# Setup:
#   Clip plane 0: left=50, right=200 (screen X coordinates)
#   PF1 enabled for clip plane 0 (clip_en=0b0001=1)
#   PF1: opaque tile (pen=1) at every column
#   No other layers active
#
# Check columns:
#   col=49  → screen_x=49 < 50  → clipped → pen=0
#   col=50  → screen_x=50 == 50 → visible  → pen=1
#   col=125 → screen_x=125       → visible  → pen=1
#   col=200 → screen_x=200 == 200→ visible  → pen=1
#   col=201 → screen_x=201 > 200 → clipped → pen=0
# ===========================================================================
emit({"op": "reset", "note": "reset for test1 single clip plane PF1"})
model_reset()

SCAN1    = 30   # target_vpos (renders scan 31)
# Clear stale line RAM from prior steps and all PF tiles at tile_y=1
clear_scanline_effects(SCAN1 + 1, "test1")
clear_pf_row(31, "test1")
# PF tile at every screen column on scan 31
# screen_x = col = hpos - H_START. Tile row=31//16=1, tile columns cover 0-19
# Write solid opaque tiles for all columns 0-19 of tile_y=1
for _tx in range(20):
    write_pf_tile(0, _tx, 31 // 16, 0x10, palette=0x010)  # PF1: pen=1, pal=0x10

# Set clip plane 0: left=50, right=200 for scan 31
set_clip_plane(0, 31, left=50, right=200)

# Set PF1 clip config: enable plane 0 (clip_en=1), no invert, prio=5
set_pf_clip(0, 31, prio=5, clip_en=0b0001, clip_inv=0, clip_sense=0)

# Check 5 boundary columns
test1_checks = [
    (49,  0,          "test1 col=49 left-of-window → clipped"),
    (50,  (0x010 << 4) | 1, "test1 col=50 left-boundary inclusive → visible"),
    (125, (0x010 << 4) | 1, "test1 col=125 mid-window → visible"),
    (200, (0x010 << 4) | 1, "test1 col=200 right-boundary inclusive → visible"),
    (201, 0,          "test1 col=201 right-of-window → clipped"),
]
for col, exp, note in test1_checks:
    model_val = model_colmix_pixel(SCAN1, col)
    assert model_val == exp, f"test1 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN1, col, exp, note)


# ===========================================================================
# Test 2: Two clip planes for PF2. Intersection — visible inside BOTH.
#
# Setup:
#   Clip plane 0: left=40, right=100
#   Clip plane 1: left=80, right=180
#   Intersection: [80, 100]
#   PF2: opaque, clip_en = 0b0011 (planes 0 and 1 active), no invert
#
# Check columns:
#   col=39   → outside plane0 → clipped
#   col=40   → in plane0, outside plane1 → clipped (NOT in intersection)
#   col=79   → in plane0, outside plane1 → clipped
#   col=80   → in both planes → visible
#   col=90   → in both planes → visible
#   col=100  → right edge of plane0, in plane1 → visible
#   col=101  → outside plane0 → clipped
#   col=180  → outside plane0 → clipped
# ===========================================================================
emit({"op": "reset", "note": "reset for test2 two clip planes intersection"})
model_reset()

SCAN2 = 40   # render scan 41
clear_scanline_effects(SCAN2 + 1, "test2")
clear_pf_row(41, "test2")
for _tx in range(20):
    write_pf_tile(1, _tx, 41 // 16, 0x11, palette=0x011)  # PF2: pen=2, pal=0x11

set_clip_plane(0, 41, left=40, right=100)
set_clip_plane(1, 41, left=80, right=180)
# PF2: enable planes 0 and 1 (clip_en=0b0011=3), no invert, prio=5
set_pf_clip(1, 41, prio=5, clip_en=0b0011, clip_inv=0, clip_sense=0)
clear_sprite_entry(0, "test2 no-sprite clear")

test2_checks = [
    (39,  0,          "test2 col=39 outside plane0 → clipped"),
    (40,  0,          "test2 col=40 in plane0 only → clipped (not in plane1)"),
    (79,  0,          "test2 col=79 in plane0 only → clipped"),
    (80,  (0x011 << 4) | 2, "test2 col=80 in both → visible"),
    (90,  (0x011 << 4) | 2, "test2 col=90 in both → visible"),
    (100, (0x011 << 4) | 2, "test2 col=100 right of plane0, in plane1 → visible"),
    (101, 0,          "test2 col=101 outside plane0 → clipped"),
]
for col, exp, note in test2_checks:
    model_val = model_colmix_pixel(SCAN2, col)
    assert model_val == exp, f"test2 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN2, col, exp, note)


# ===========================================================================
# Test 3: Invert mode on one plane — pixels INSIDE window are blanked.
#
# Setup:
#   Clip plane 0: left=60, right=150
#   PF3: opaque, clip_en=0b0001 (plane 0), clip_inv=0b0001 (plane 0 inverted), no sense
#
# Invert mode: show content OUTSIDE window. Inside [60,150] → clipped.
#
# Check columns:
#   col=59  → outside window → visible (invert mode: show outside)
#   col=60  → left boundary → clipped (inside window → blanked)
#   col=100 → inside window → clipped
#   col=150 → right boundary → clipped
#   col=151 → outside window → visible
# ===========================================================================
emit({"op": "reset", "note": "reset for test3 invert mode clip"})
model_reset()

SCAN3 = 50   # render scan 51
clear_scanline_effects(SCAN3 + 1, "test3")
clear_pf_row(51, "test3")
for _tx in range(20):
    write_pf_tile(2, _tx, 51 // 16, 0x12, palette=0x012)  # PF3: pen=3, pal=0x12

set_clip_plane(0, 51, left=60, right=150)
# PF3: plane 0 enabled + inverted (clip_en=0b0001, clip_inv=0b0001, sense=0)
set_pf_clip(2, 51, prio=5, clip_en=0b0001, clip_inv=0b0001, clip_sense=0)
clear_sprite_entry(0, "test3 no-sprite clear")

test3_checks = [
    (59,  (0x012 << 4) | 3, "test3 col=59 outside window → visible (invert)"),
    (60,  0,                "test3 col=60 left boundary (inside) → clipped (invert)"),
    (100, 0,                "test3 col=100 inside window → clipped (invert)"),
    (150, 0,                "test3 col=150 right boundary (inside) → clipped (invert)"),
    (151, (0x012 << 4) | 3, "test3 col=151 outside window → visible (invert)"),
]
for col, exp, note in test3_checks:
    model_val = model_colmix_pixel(SCAN3, col)
    assert model_val == exp, f"test3 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN3, col, exp, note)


# ===========================================================================
# Test 4: PF3 with clip, PF4 without clip. Verify clip does not affect PF4.
#
# Setup:
#   Clip plane 0: left=70, right=140
#   PF3: opaque pen=3, clip_en=0b0001 (plane 0 active), prio=5
#   PF4: opaque pen=4, clip_en=0b0000 (no clip), prio=3
#
# At col=100 (inside window): PF3 passes clip (visible), prio=5 > PF4 prio=3 → PF3 wins.
# At col=50  (outside window): PF3 is clipped (pen→0), PF4 unclipped prio=3 → PF4 wins.
# At col=200 (outside window): PF3 is clipped, PF4 visible → PF4 wins.
# ===========================================================================
emit({"op": "reset", "note": "reset for test4 PF3 clipped PF4 unclipped"})
model_reset()

SCAN4 = 60   # render scan 61
clear_scanline_effects(SCAN4 + 1, "test4")
clear_pf_row(61, "test4")
for _tx in range(20):
    write_pf_tile(2, _tx, 61 // 16, 0x12, palette=0x012)  # PF3: pen=3
    write_pf_tile(3, _tx, 61 // 16, 0x13, palette=0x013)  # PF4: pen=4

set_clip_plane(0, 61, left=70, right=140)
# PF3: clip_en=0b0001 (plane 0), prio=5
set_pf_clip(2, 61, prio=5, clip_en=0b0001, clip_inv=0, clip_sense=0)
# PF4: no clip (clip_en=0), prio=3
set_pf_clip(3, 61, prio=3, clip_en=0b0000, clip_inv=0, clip_sense=0)
clear_sprite_entry(0, "test4 no-sprite clear")

test4_checks = [
    (100, (0x012 << 4) | 3, "test4 col=100 inside window: PF3(5) beats PF4(3)"),
    (50,  (0x013 << 4) | 4, "test4 col=50 outside window: PF3 clipped, PF4 wins"),
    (200, (0x013 << 4) | 4, "test4 col=200 outside window: PF3 clipped, PF4 wins"),
]
for col, exp, note in test4_checks:
    model_val = model_colmix_pixel(SCAN4, col)
    assert model_val == exp, f"test4 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN4, col, exp, note)


# ===========================================================================
# Test 5: Sprite clipped by clip plane.
#
# Setup:
#   Clip plane 0: left=90, right=160
#   Sprite: at col=100 (inside window), group 0x00, prio=10
#   PF1: opaque pen=1 prio=5 (always visible, no clip)
#   Sprite clip: spr_clip_en=0b0001 (plane 0), no invert
#
# col=100: sprite is inside clip window → visible. sprite prio=10 > PF1 prio=5 → sprite wins.
# col=85:  sprite is outside window (col < 90) → sprite clipped → PF1 wins.
# col=161: sprite is outside window (col > 160) → sprite clipped → PF1 wins.
# ===========================================================================
emit({"op": "reset", "note": "reset for test5 sprite clipped"})
model_reset()

SCAN5 = 70    # render scan 71
clear_scanline_effects(SCAN5 + 1, "test5")
clear_pf_row(71, "test5")
# PF1 visible at all columns (no clip, full tile row)
for _tx in range(20):
    write_pf_tile(0, _tx, 71 // 16, 0x10, palette=0x010)  # PF1: pen=1, pal=0x10

set_pf_clip(0, 71, prio=5, clip_en=0b0000, clip_inv=0, clip_sense=0)  # PF1: no clip

# Sprite at col=100, scan 70. color=0x02 (grp0x00, palette=2)
SPR5_COLOR = 0x02
write_sprite_entry(0, 0x02, 100, SCAN5, SPR5_COLOR, note="test5 sprite at col=100")
set_spr_priority(71, prio_g0=10)

# Clip plane 0: left=90, right=160
set_clip_plane(0, 71, left=90, right=160)
# Sprite clip: plane 0 enabled, no invert
set_spr_clip(71, clip_en=0b0001, clip_inv=0, clip_sense=0)

slist5 = m.scan_sprites()
spr5_buf = m.render_sprite_scanline(SCAN5, slist5)

test5_checks = [
    (100, None, "test5 col=100 sprite inside clip → sprite wins (prio=10)"),
    (85,  None, "test5 col=85 sprite outside clip → sprite clipped, PF1 wins"),
    (161, None, "test5 col=161 sprite outside clip → sprite clipped, PF1 wins"),
]
for col, _, note in test5_checks:
    model_val = model_colmix_pixel(SCAN5, col, spr5_buf)
    check_colmix(SCAN5, col, model_val, note)

# Validate expected behavior
spr_in  = model_colmix_pixel(SCAN5, 100, spr5_buf)
spr_out = model_colmix_pixel(SCAN5, 85,  spr5_buf)
assert (spr_in & 0xF)  == 2, f"test5: col=100 expected spr pen=2, got {spr_in & 0xF}"
assert (spr_out & 0xF) == 1, f"test5: col=85 expected PF1 pen=1, got {spr_out & 0xF}"


# ===========================================================================
# Test 6: Inversion sense bit (pbobble4 / commandw quirk).
#
# When clip_sense=1, the clip_inv bits are effectively flipped.
# So a plane with clip_inv=0b0001 and clip_sense=1 behaves as clip_inv=0b0000 (normal).
# A plane with clip_inv=0b0001 and clip_sense=0 behaves as invert (show outside).
#
# Setup:
#   Clip plane 0: left=100, right=200
#   PF1: clip_en=0b0001, clip_inv=0b0001 (inverted), clip_sense=1
#   With sense=1: eff_inv = clip_inv XOR sense = 1 XOR 1 = 0 → NORMAL mode
#   So: inside [100,200] → visible.
#
# Verify: col=150 (inside) → visible; col=50 (outside) → clipped.
# ===========================================================================
emit({"op": "reset", "note": "reset for test6 inversion sense bit"})
model_reset()

SCAN6 = 80    # render scan 81
clear_scanline_effects(SCAN6 + 1, "test6")
clear_pf_row(81, "test6")
for _tx in range(20):
    write_pf_tile(0, _tx, 81 // 16, 0x10, palette=0x010)  # PF1: pen=1

set_clip_plane(0, 81, left=100, right=200)
# PF1: plane 0 inverted but sense=1 → double negation → normal clip
# eff_inv = 1 XOR 1 = 0 → normal mode → show INSIDE [100,200]
set_pf_clip(0, 81, prio=5, clip_en=0b0001, clip_inv=0b0001, clip_sense=1)
clear_sprite_entry(0, "test6 no-sprite clear")

test6_checks = [
    (150, (0x010 << 4) | 1, "test6 col=150 inside window, sense=1 double-neg → visible"),
    (50,  0,                "test6 col=50 outside window, sense=1 double-neg → clipped"),
    (200, (0x010 << 4) | 1, "test6 col=200 right boundary, sense=1 → visible"),
    (201, 0,                "test6 col=201 outside, sense=1 → clipped"),
]
for col, exp, note in test6_checks:
    model_val = model_colmix_pixel(SCAN6, col)
    assert model_val == exp, f"test6 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN6, col, exp, note)


# ===========================================================================
# Test 7: Clip boundary exact values.
#
# Test 7a: pixel at exactly left boundary (col=left) → visible (inclusive).
# Test 7b: pixel at col=left-1 → clipped.
# (Already tested in test1, but test with a different boundary to be explicit.)
#
# Setup: clip plane 0: left=10, right=250. PF2: opaque pen=2.
# col=10 → visible; col=9 → clipped; col=250 → visible; col=251 → clipped.
# ===========================================================================
emit({"op": "reset", "note": "reset for test7 boundary inclusivity"})
model_reset()

SCAN7 = 90    # render scan 91
clear_scanline_effects(SCAN7 + 1, "test7")
clear_pf_row(91, "test7")
for _tx in range(20):
    write_pf_tile(1, _tx, 91 // 16, 0x11, palette=0x011)  # PF2: pen=2

set_clip_plane(0, 91, left=10, right=250)
set_pf_clip(1, 91, prio=5, clip_en=0b0001, clip_inv=0, clip_sense=0)
clear_sprite_entry(0, "test7 no-sprite clear")

test7_checks = [
    (9,   0,          "test7 col=9 < left=10 → clipped"),
    (10,  (0x011 << 4) | 2, "test7 col=10 == left (inclusive) → visible"),
    (130, (0x011 << 4) | 2, "test7 col=130 inside → visible"),
    (250, (0x011 << 4) | 2, "test7 col=250 == right (inclusive) → visible"),
    (251, 0,          "test7 col=251 > right=250 → clipped"),
]
for col, exp, note in test7_checks:
    model_val = model_colmix_pixel(SCAN7, col)
    assert model_val == exp, f"test7 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN7, col, exp, note)


# ===========================================================================
# Test 8: All planes disabled → no clip, full layer visible.
#
# Setup: PF1 opaque pen=1, clip_en=0b0000 (no planes active). prio=5.
# Result: all columns visible.
# ===========================================================================
emit({"op": "reset", "note": "reset for test8 all planes disabled no clip"})
model_reset()

SCAN8 = 110   # render scan 111
clear_scanline_effects(SCAN8 + 1, "test8")
clear_pf_row(111, "test8")
for _tx in range(20):
    write_pf_tile(0, _tx, 111 // 16, 0x01, palette=0x001)  # PF1: pen=1

# Clip plane 0 is set to a narrow window, but clip_en=0 means it won't apply
set_clip_plane(0, 111, left=100, right=150)
set_pf_clip(0, 111, prio=5, clip_en=0b0000, clip_inv=0, clip_sense=0)
clear_sprite_entry(0, "test8 no-sprite clear")

test8_checks = [
    (0,   (0x001 << 4) | 1, "test8 col=0 no clip → visible"),
    (80,  (0x001 << 4) | 1, "test8 col=80 no clip → visible"),
    (125, (0x001 << 4) | 1, "test8 col=125 inside disabled window → visible"),
    (200, (0x001 << 4) | 1, "test8 col=200 no clip → visible"),
    (319, (0x001 << 4) | 1, "test8 col=319 no clip → visible"),
]
for col, exp, note in test8_checks:
    model_val = model_colmix_pixel(SCAN8, col)
    assert model_val == exp, f"test8 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN8, col, exp, note)


# ===========================================================================
# Test 9: Clip planes 2 and 3 for PF3. Intersection.
#
# Setup:
#   Clip plane 2: left=30, right=100
#   Clip plane 3: left=60, right=200
#   Intersection: [60, 100]
#   PF3: opaque pen=3, clip_en=0b1100 (planes 2 and 3)
#
# col=59  → in plane2, outside plane3 left boundary → clipped
# col=60  → in both → visible
# col=80  → in both → visible
# col=100 → in both → visible
# col=101 → outside plane2 → clipped
# ===========================================================================
emit({"op": "reset", "note": "reset for test9 clip planes 2+3 intersection"})
model_reset()

SCAN9 = 120   # render scan 121
clear_scanline_effects(SCAN9 + 1, "test9")
clear_pf_row(121, "test9")
for _tx in range(20):
    write_pf_tile(2, _tx, 121 // 16, 0x12, palette=0x012)  # PF3: pen=3

set_clip_plane(2, 121, left=30, right=100)
set_clip_plane(3, 121, left=60, right=200)
# PF3: planes 2 and 3 enabled (clip_en=0b1100=12), no invert, prio=5
set_pf_clip(2, 121, prio=5, clip_en=0b1100, clip_inv=0, clip_sense=0)
clear_sprite_entry(0, "test9 no-sprite clear")

test9_checks = [
    (59,  0,          "test9 col=59 in plane2 only → clipped"),
    (60,  (0x012 << 4) | 3, "test9 col=60 in both planes → visible"),
    (80,  (0x012 << 4) | 3, "test9 col=80 in both → visible"),
    (100, (0x012 << 4) | 3, "test9 col=100 right of plane2, in plane3 → visible"),
    (101, 0,          "test9 col=101 outside plane2 → clipped"),
]
for col, exp, note in test9_checks:
    model_val = model_colmix_pixel(SCAN9, col)
    assert model_val == exp, f"test9 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN9, col, exp, note)


# ===========================================================================
# Test 10: Sprite with no clip (spr_clip_en=0) — always visible.
#
# Setup:
#   Sprite at col=100, scan=130. prio=8. group 0x00.
#   spr_clip_en=0 → no clip planes active for sprite.
#   Clip plane 0: left=110, right=200 (would clip if enabled)
#
# Result: sprite visible at col=100 even though col=100 < left=110.
# ===========================================================================
emit({"op": "reset", "note": "reset for test10 sprite no clip always visible"})
model_reset()

SCAN10 = 130   # render scan 131
clear_scanline_effects(SCAN10 + 1, "test10")
clear_pf_row(131, "test10")
# PF1 as background (prio=3, no clip)
for _tx in range(20):
    write_pf_tile(0, _tx, 131 // 16, 0x10, palette=0x010)  # PF1: pen=1
set_pf_clip(0, 131, prio=3, clip_en=0b0000, clip_inv=0, clip_sense=0)

# Set clip plane 0 (but sprite won't use it)
set_clip_plane(0, 131, left=110, right=200)

# Sprite at col=100 (outside [110,200] plane0 window, but clip disabled)
SPR10_COLOR = 0x05   # grp 0x00, palette=5
write_sprite_entry(0, 0x05, 100, SCAN10, SPR10_COLOR, note="test10 sprite prio=8")
set_spr_priority(131, prio_g0=8)
# spr_clip_en=0 → no clip
set_spr_clip(131, clip_en=0b0000, clip_inv=0, clip_sense=0)

slist10 = m.scan_sprites()
spr10_buf = m.render_sprite_scanline(SCAN10, slist10)

model_val10 = model_colmix_pixel(SCAN10, 100, spr10_buf)
assert (model_val10 & 0xF) == 5, f"test10 model: pen={model_val10&0xF} expected 5 (sprite)"
check_colmix(SCAN10, 100, model_val10,
             f"test10 col=100 sprite prio=8 no clip → visible exp={model_val10:#06x}")


# ===========================================================================
# Test 11: Multiple PFs, only one clipped. Verify isolation.
#
# Setup:
#   PF1: prio=8, clip_en=0b0001 (plane 0), left=120, right=200
#   PF2: prio=5, clip_en=0b0000 (no clip), opaque pen=2
#
# col=100 (outside plane0 [120,200]):
#   PF1 clipped → pen=0. PF2 visible prio=5 → PF2 wins.
# col=150 (inside plane0):
#   PF1 visible prio=8 > PF2 prio=5 → PF1 wins.
# ===========================================================================
emit({"op": "reset", "note": "reset for test11 only PF1 clipped PF2 unclipped"})
model_reset()

SCAN11 = 140   # render scan 141
clear_scanline_effects(SCAN11 + 1, "test11")
clear_pf_row(141, "test11")
for _tx in range(20):
    write_pf_tile(0, _tx, 141 // 16, 0x01, palette=0x001)  # PF1: pen=1
    write_pf_tile(1, _tx, 141 // 16, 0x02, palette=0x002)  # PF2: pen=2

set_clip_plane(0, 141, left=120, right=200)
set_pf_clip(0, 141, prio=8, clip_en=0b0001, clip_inv=0, clip_sense=0)  # PF1: clip
set_pf_clip(1, 141, prio=5, clip_en=0b0000, clip_inv=0, clip_sense=0)  # PF2: no clip
clear_sprite_entry(0, "test11 no-sprite clear")

test11_checks = [
    (100, (0x002 << 4) | 2, "test11 col=100 PF1 clipped, PF2 wins prio=5"),
    (150, (0x001 << 4) | 1, "test11 col=150 PF1 inside window prio=8 > PF2 prio=5"),
]
for col, exp, note in test11_checks:
    model_val = model_colmix_pixel(SCAN11, col)
    assert model_val == exp, f"test11 model sanity col={col}: {model_val:#06x} != {exp:#06x}"
    check_colmix(SCAN11, col, exp, note)


# ===========================================================================
# Test 12: Invert + sense = double negation → normal clip behavior.
#
# clip_inv=0b0001, clip_sense=1 → eff_inv = 1 XOR 1 = 0 (normal mode).
# Verified in test6. Additional variant: clip_inv=0b0000, clip_sense=0 → also normal.
# Here test the sprite layer with inverted clip + sense=1.
#
# Setup:
#   Clip plane 0: left=80, right=180
#   Sprite: col=120 (inside window). spr_clip_en=0b0001, clip_inv=0b0001, sense=1
#   eff_inv = 1 XOR 1 = 0 → NORMAL → show inside [80,180].
#   col=120: inside → sprite visible.
#   col=50:  outside → sprite clipped.
# ===========================================================================
emit({"op": "reset", "note": "reset for test12 sprite clip invert+sense double-negation"})
model_reset()

SCAN12 = 150   # render scan 151
clear_scanline_effects(SCAN12 + 1, "test12")
clear_pf_row(151, "test12")
# PF1 as background (prio=3)
for _tx in range(20):
    write_pf_tile(0, _tx, 151 // 16, 0x10, palette=0x010)  # PF1: pen=1
set_pf_clip(0, 151, prio=3, clip_en=0b0000, clip_inv=0, clip_sense=0)

set_clip_plane(0, 151, left=80, right=180)

# Sprite at col=120. clip_inv=0b0001, clip_sense=1 → eff_inv=0 (normal)
SPR12_COLOR = 0x03   # grp 0x00, palette=3
write_sprite_entry(0, 0x03, 120, SCAN12, SPR12_COLOR, note="test12 sprite double-neg clip")
set_spr_priority(151, prio_g0=10)
set_spr_clip(151, clip_en=0b0001, clip_inv=0b0001, clip_sense=1)

slist12 = m.scan_sprites()
spr12_buf = m.render_sprite_scanline(SCAN12, slist12)

test12_checks = [
    (120, None, "test12 col=120 sprite inside window clip_inv+sense=normal → visible"),
    (50,  None, "test12 col=50 sprite outside window → clipped"),
]
for col, _, note in test12_checks:
    model_val = model_colmix_pixel(SCAN12, col, spr12_buf)
    check_colmix(SCAN12, col, model_val, note)

spr12_in  = model_colmix_pixel(SCAN12, 120, spr12_buf)
spr12_out = model_colmix_pixel(SCAN12, 50,  spr12_buf)
assert (spr12_in & 0xF)  == 3, f"test12: col=120 expected spr pen=3, got {spr12_in & 0xF}"
assert (spr12_out & 0xF) == 1, f"test12: col=50 expected PF1 pen=1, got {spr12_out & 0xF}"


# ===========================================================================
# Write vectors
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step12_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors -> {out_path}")
