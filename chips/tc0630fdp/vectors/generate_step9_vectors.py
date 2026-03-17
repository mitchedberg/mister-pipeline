#!/usr/bin/env python3
"""
generate_step9_vectors.py — Step 9 test vector generator for tc0630fdp.

Produces step9_vectors.jsonl: Sprite Zoom (per-sprite x_zoom + y_zoom).

Test cases (per section3_rtl_plan.md Step 9):
  1. x_zoom = 0x00 (full size): 16 wide pixels rendered. Matches Step 8 behavior.
  2. x_zoom = 0x80 (half size): 8 output pixels from a 16-pixel tile.
  3. x_zoom = 0xFF (near-zero): rendered_width = (16 * 1) >> 8 = 0. No pixels written.
  4. y_zoom = 0x80 (half height): rendered_height = 8. Check that scanline sy+8 is blank.
  5. y_zoom = 0x00 (full height): sprite occupies rows sy..sy+15.
  6. Asymmetric zoom: x_zoom=0x40, y_zoom=0x80 — verify width and height independently.
  7. x_zoom = 0x80 + flipX: verify mirrored output at half width.
  8. y_zoom = 0x80 + flipY: verify source row reversal with half height.
  9. zoom=0x00 baseline regression: confirm unzoomed behavior unchanged from Step 8.
 10. Pixel-accurate zoom at x_zoom=0xC0: rendered_width = (16 * 0x40) >> 8 = 4.

Zoom formula (RTL + model):
  scale_x       = 0x100 - x_zoom
  rendered_width = (16 * scale_x) >> 8  = scale_x >> 4
  For dst_x in 0..rendered_width-1:
    src_x = (dst_x * scale_x) >> 8

  scale_y        = 0x100 - y_zoom
  rendered_height = (16 * scale_y) >> 8
  For dst_row in 0..rendered_height-1:
    src_row = (dst_row * scale_y) >> 8

Sprite RAM word 1: [15:8]=y_zoom, [7:0]=x_zoom
"""

import json
import os
from fdp_model import TaitoF3Model

# ---------------------------------------------------------------------------
V_START = 24
V_END   = 256
H_START = 46

vectors = []


def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
m = TaitoF3Model()


def model_reset():
    """Reset transient state; preserve GFX ROM across tests."""
    m.ctrl     = [0] * 16
    m.pf_ram   = [[0] * m.PF_RAM_WORDS for _ in range(4)]
    m.text_ram = [0] * m.TEXT_RAM_WORDS
    m.char_ram = [0] * m.CHAR_RAM_BYTES
    m.line_ram = [0] * m.LINE_RAM_WORDS
    m.spr_ram  = [0] * m.SPR_RAM_WORDS


# ---------------------------------------------------------------------------
SPR_BASE_CHIP = 0x20000


def write_spr_word(word_offset: int, data: int, note: str = "") -> None:
    chip_addr = SPR_BASE_CHIP + word_offset
    emit({"op": "write_sprite",
          "addr": chip_addr,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"spr_ram[{word_offset:#06x}] = {data:#06x}"})


def write_sprite_entry(idx: int, tile_code: int, sx: int, sy: int,
                       color: int, flipx: bool = False, flipy: bool = False,
                       x_zoom: int = 0x00, y_zoom: int = 0x00,
                       note: str = "") -> None:
    """Write a full sprite entry (words 0,1,2,3,4,5) to Sprite RAM."""
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
    write_spr_word(base + 1, w1,       f"{tag} word1=zoom y={y_zoom:#04x} x={x_zoom:#04x}")
    write_spr_word(base + 2, sx_12,    f"{tag} word2=sx")
    write_spr_word(base + 3, sy_12,    f"{tag} word3=sy")
    write_spr_word(base + 4, w4,       f"{tag} word4=ctrl")
    write_spr_word(base + 5, tile_hi,  f"{tag} word5=tile_hi")

    m.write_sprite_entry(idx, tile_code, sx, sy, color, flipx, flipy,
                         x_zoom=x_zoom, y_zoom=y_zoom)


def write_gfx_word(word_addr: int, data: int, note: str = "") -> None:
    emit({"op": "write_gfx",
          "gfx_addr": word_addr,
          "gfx_data": data & 0xFFFFFFFF,
          "note": note or f"gfx[{word_addr:#06x}] = {data:#010x}"})
    if word_addr < m.GFX_ROM_WORDS:
        m.gfx_rom[word_addr] = data & 0xFFFFFFFF


def write_gfx_row(tile_code: int, row: int, left_word: int, right_word: int,
                  note: str = "") -> None:
    base = tile_code * 32 + row * 2
    write_gfx_word(base,     left_word,  note or f"gfx tile={tile_code} row={row} left")
    write_gfx_word(base + 1, right_word, note or f"gfx tile={tile_code} row={row} right")


def write_gfx_solid_row(tile_code: int, row: int, pen: int) -> None:
    n = pen & 0xF
    word = 0
    for _ in range(8):
        word = (word << 4) | n
    write_gfx_row(tile_code, row, word, word,
                  f"gfx solid tile={tile_code} row={row} pen={pen:#x}")


def write_gfx_solid_tile(tile_code: int, pen: int) -> None:
    for row in range(16):
        write_gfx_solid_row(tile_code, row, pen)


def write_gfx_gradient_row(tile_code: int, row: int) -> None:
    """px0..7 = 0..7 (left half), px8..15 = 8..15 (right half)."""
    left_word = 0
    for px in range(8):
        left_word = (left_word << 4) | px
    right_word = 0
    for px in range(8):
        right_word = (right_word << 4) | (px + 8)
    write_gfx_row(tile_code, row, left_word, right_word,
                  f"gfx gradient tile={tile_code} row={row}")


def check_spr(target_vpos: int, screen_col: int, exp_pixel: int, note: str) -> None:
    emit({"op": "check_sprite_pixel",
          "vpos":       target_vpos,
          "screen_col": screen_col,
          "exp_pixel":  exp_pixel & 0xFFF,
          "note":       note})


def model_spr_pixel(vpos: int, screen_col: int) -> int:
    slist = m.scan_sprites()
    linebuf = m.render_sprite_scanline(vpos, slist)
    return linebuf[screen_col]


# ===========================================================================
# Test group 1: x_zoom = 0x00 (full size — baseline, confirms zoom=0 = Step 8)
# Sprite at (100, 60): solid pen=5, palette=7
# x_zoom=0x00 → scale_x=0x100 → rendered_width=16 (same as no-zoom)
# ===========================================================================
emit({"op": "reset", "note": "reset for zoom=0x00 full-size baseline"})
model_reset()

TC1 = 0x01
PAL1 = 0x07
SPR1_SX = 100
SPR1_SY = 60

write_gfx_solid_tile(TC1, 5)
write_sprite_entry(0, TC1, SPR1_SX, SPR1_SY, PAL1,
                   x_zoom=0x00, y_zoom=0x00, note="spr[0] zoom=0 (full size)")

VPOS1 = SPR1_SY - 1  # renders scan 60
for col_off in range(16):
    exp = model_spr_pixel(VPOS1, SPR1_SX + col_off)
    check_spr(VPOS1, SPR1_SX + col_off, exp,
              f"zoom0 full col+{col_off} exp={exp:#05x}")

# Columns just outside should be transparent
for sc in [SPR1_SX - 1, SPR1_SX + 16]:
    if 0 <= sc < 320:
        exp = model_spr_pixel(VPOS1, sc)
        check_spr(VPOS1, sc, exp,
                  f"zoom0 outside col={sc} exp={exp:#05x} (transparent)")


# ===========================================================================
# Test group 2: x_zoom = 0x80 (half X size)
# rendered_width = (16 * (0x100 - 0x80)) >> 8 = (16 * 128) >> 8 = 8
# Gradient tile: src px 0..7 map to output columns 0..7
# ===========================================================================
emit({"op": "reset", "note": "reset for x_zoom=0x80 half-width test"})
model_reset()

TC2 = 0x02
PAL2 = 0x0A
SPR2_SX = 80
SPR2_SY = 70

write_gfx_gradient_row(TC2, 0)
for row in range(1, 16):
    write_gfx_solid_row(TC2, row, 1)

write_sprite_entry(0, TC2, SPR2_SX, SPR2_SY, PAL2,
                   x_zoom=0x80, y_zoom=0x00, note="spr[0] x_zoom=0x80 half-width")

VPOS2 = SPR2_SY - 1  # renders scan 70
# Columns 0..7 visible (rendered_width=8)
for col_off in range(8):
    exp = model_spr_pixel(VPOS2, SPR2_SX + col_off)
    check_spr(VPOS2, SPR2_SX + col_off, exp,
              f"x_zoom80 col+{col_off} exp={exp:#05x}")

# Columns 8..15 must be transparent (outside rendered width)
for col_off in range(8, 16):
    exp = model_spr_pixel(VPOS2, SPR2_SX + col_off)
    check_spr(VPOS2, SPR2_SX + col_off, exp,
              f"x_zoom80 col+{col_off} (should be transparent) exp={exp:#05x}")


# ===========================================================================
# Test group 3: x_zoom = 0xFF (near-zero width)
# rendered_width = (16 * 1) >> 8 = 0 — no pixels rendered
# ===========================================================================
emit({"op": "reset", "note": "reset for x_zoom=0xFF zero-width test"})
model_reset()

TC3 = 0x03
PAL3 = 0x15
SPR3_SX = 100
SPR3_SY = 80

write_gfx_solid_tile(TC3, 7)
write_sprite_entry(0, TC3, SPR3_SX, SPR3_SY, PAL3,
                   x_zoom=0xFF, y_zoom=0x00, note="spr[0] x_zoom=0xFF (invisible)")

VPOS3 = SPR3_SY - 1
for col_off in range(16):
    sc = SPR3_SX + col_off
    if 0 <= sc < 320:
        exp = model_spr_pixel(VPOS3, sc)
        check_spr(VPOS3, sc, exp,
                  f"x_zoom_FF col+{col_off} (all transparent) exp={exp:#05x}")


# ===========================================================================
# Test group 4: y_zoom = 0x80 (half Y height)
# rendered_height = (16 * 128) >> 8 = 8
# Scanlines sy..sy+7 visible; sy+8..sy+15 transparent.
# ===========================================================================
emit({"op": "reset", "note": "reset for y_zoom=0x80 half-height test"})
model_reset()

TC4 = 0x04
PAL4 = 0x1F
SPR4_SX = 120
SPR4_SY = 90

write_gfx_solid_tile(TC4, 0xB)
write_sprite_entry(0, TC4, SPR4_SX, SPR4_SY, PAL4,
                   x_zoom=0x00, y_zoom=0x80, note="spr[0] y_zoom=0x80 half-height")

# Scanlines sy..sy+7: sprite visible (vpos = sy-1 to sy+6, renders sy..sy+7)
for row_off in range(8):
    vpos_r = SPR4_SY - 1 + row_off  # renders scan SPR4_SY + row_off
    exp = model_spr_pixel(vpos_r, SPR4_SX)
    check_spr(vpos_r, SPR4_SX, exp,
              f"y_zoom80 row+{row_off} visible exp={exp:#05x}")

# Scanline sy+8..sy+15: sprite transparent (rendered_height=8, row 8+ out of range)
for row_off in range(8, 16):
    vpos_r = SPR4_SY - 1 + row_off  # renders scan SPR4_SY + row_off
    if vpos_r + 1 < V_END:
        exp = model_spr_pixel(vpos_r, SPR4_SX)
        check_spr(vpos_r, SPR4_SX, exp,
                  f"y_zoom80 row+{row_off} should_be_transparent exp={exp:#05x}")


# ===========================================================================
# Test group 5: y_zoom = 0x00 (full height — 16 rows all visible)
# Verify top row (sy) and bottom row (sy+15) are both present.
# ===========================================================================
emit({"op": "reset", "note": "reset for y_zoom=0x00 full-height test"})
model_reset()

TC5 = 0x05
PAL5 = 0x05
SPR5_SX = 60
SPR5_SY = 100

# row 0 = pen 3, row 15 = pen 9, rest = pen 1
for row in range(16):
    if   row == 0:  write_gfx_solid_row(TC5, row, 3)
    elif row == 15: write_gfx_solid_row(TC5, row, 9)
    else:           write_gfx_solid_row(TC5, row, 1)

write_sprite_entry(0, TC5, SPR5_SX, SPR5_SY, PAL5,
                   x_zoom=0x00, y_zoom=0x00, note="spr[0] y_zoom=0 full height")

VPOS5a = SPR5_SY - 1         # renders row 0 (pen=3)
exp5a = model_spr_pixel(VPOS5a, SPR5_SX)
check_spr(VPOS5a, SPR5_SX, exp5a, f"y_zoom00 top row (pen=3) exp={exp5a:#05x}")

VPOS5b = SPR5_SY + 14        # renders row 15 (pen=9)
exp5b = model_spr_pixel(VPOS5b, SPR5_SX)
check_spr(VPOS5b, SPR5_SX, exp5b, f"y_zoom00 bot row (pen=9) exp={exp5b:#05x}")


# ===========================================================================
# Test group 6: Asymmetric zoom x_zoom=0x40, y_zoom=0x80
# scale_x = 0x100 - 0x40 = 0xC0 → rendered_width  = (16 * 0xC0) >> 8 = 12
# scale_y = 0x100 - 0x80 = 0x80 → rendered_height = (16 * 0x80) >> 8 = 8
# ===========================================================================
emit({"op": "reset", "note": "reset for asymmetric zoom x=0x40 y=0x80"})
model_reset()

TC6 = 0x06
PAL6 = 0x12
SPR6_SX = 140
SPR6_SY = 50

write_gfx_solid_tile(TC6, 0xD)
write_sprite_entry(0, TC6, SPR6_SX, SPR6_SY, PAL6,
                   x_zoom=0x40, y_zoom=0x80, note="spr[0] asym zoom x=0x40 y=0x80")

# Verify rendered_width=12: columns 0..11 visible, 12..15 transparent
VPOS6 = SPR6_SY - 1
for col_off in range(12):
    exp = model_spr_pixel(VPOS6, SPR6_SX + col_off)
    check_spr(VPOS6, SPR6_SX + col_off, exp,
              f"asym_zoom col+{col_off} (visible) exp={exp:#05x}")
for col_off in range(12, 16):
    exp = model_spr_pixel(VPOS6, SPR6_SX + col_off)
    check_spr(VPOS6, SPR6_SX + col_off, exp,
              f"asym_zoom col+{col_off} (transparent) exp={exp:#05x}")

# Verify rendered_height=8: rows 8..15 transparent
for row_off in range(8, 16):
    vpos_r = SPR6_SY - 1 + row_off
    if vpos_r + 1 < V_END:
        exp = model_spr_pixel(vpos_r, SPR6_SX)
        check_spr(vpos_r, SPR6_SX, exp,
                  f"asym_zoom y row+{row_off} (transparent) exp={exp:#05x}")


# ===========================================================================
# Test group 7: x_zoom = 0x80 + flipX
# Gradient tile row 0: src px 0..7 → output cols 0..7 (half width)
# With flipX: src nibble order reversed within each 8-px half
# Expected: col+0 gets src_x=0 → with flipX: nibble 7 of left half = pen 7
#           col+7 gets src_x=7 → with flipX: nibble 0 of left half = pen 0 (transparent)
# ===========================================================================
emit({"op": "reset", "note": "reset for x_zoom=0x80 + flipX test"})
model_reset()

TC7 = 0x07
PAL7 = 0x0E
SPR7_SX = 60
SPR7_SY = 110

write_gfx_gradient_row(TC7, 0)
for row in range(1, 16):
    write_gfx_solid_row(TC7, row, 2)

write_sprite_entry(0, TC7, SPR7_SX, SPR7_SY, PAL7,
                   x_zoom=0x80, flipx=True, note="spr[0] x_zoom=0x80+flipX")

VPOS7 = SPR7_SY - 1
for col_off in range(8):
    exp = model_spr_pixel(VPOS7, SPR7_SX + col_off)
    check_spr(VPOS7, SPR7_SX + col_off, exp,
              f"zoom80_flipX col+{col_off} exp={exp:#05x}")
# Columns 8..15 transparent (rendered_width=8)
for col_off in range(8, 16):
    exp = model_spr_pixel(VPOS7, SPR7_SX + col_off)
    check_spr(VPOS7, SPR7_SX + col_off, exp,
              f"zoom80_flipX col+{col_off} (transparent) exp={exp:#05x}")


# ===========================================================================
# Test group 8: y_zoom = 0x80 + flipY
# Row 0 = pen 4, row 15 = pen 9, rest = pen 2.
# With flipY + y_zoom=0x80 (8 rows rendered):
#   dst_row 0..7 → src_row = (dst_row * 0x80) >> 8 = 0..7
#   flipY applies: fetch_row = 15 - src_row = 15..8
#   So: dst_row=0 → src_row=0 → fetch_row=15 (pen=9)
#       dst_row=7 → src_row=7 → fetch_row=8  (pen=2)
# ===========================================================================
emit({"op": "reset", "note": "reset for y_zoom=0x80 + flipY test"})
model_reset()

TC8 = 0x08
PAL8 = 0x1B
SPR8_SX = 150
SPR8_SY = 130

for row in range(16):
    if   row == 0:  write_gfx_solid_row(TC8, row, 4)
    elif row == 15: write_gfx_solid_row(TC8, row, 9)
    else:           write_gfx_solid_row(TC8, row, 2)

write_sprite_entry(0, TC8, SPR8_SX, SPR8_SY, PAL8,
                   y_zoom=0x80, flipy=True, note="spr[0] y_zoom=0x80+flipY")

# dst_row=0: scan=SPR8_SY, vpos=SPR8_SY-1
VPOS8a = SPR8_SY - 1  # renders scan SPR8_SY (dst_row=0 → src_row=0 → flipY → row15 → pen=9)
exp8a = model_spr_pixel(VPOS8a, SPR8_SX)
check_spr(VPOS8a, SPR8_SX, exp8a, f"yzoom80_flipY row0 exp={exp8a:#05x} (expect pen=9)")

# dst_row=7: scan=SPR8_SY+7, vpos=SPR8_SY+6
VPOS8b = SPR8_SY + 6  # renders scan SPR8_SY+7 (dst_row=7 → src_row=7 → flipY → row8 → pen=2)
exp8b = model_spr_pixel(VPOS8b, SPR8_SX)
check_spr(VPOS8b, SPR8_SX, exp8b, f"yzoom80_flipY row7 exp={exp8b:#05x} (expect pen=2)")

# dst_row=8+: transparent (rendered_height=8)
VPOS8c = SPR8_SY + 7  # renders scan SPR8_SY+8 → dst_row=8 → out of rendered_height
if VPOS8c + 1 < V_END:
    exp8c = model_spr_pixel(VPOS8c, SPR8_SX)
    check_spr(VPOS8c, SPR8_SX, exp8c, f"yzoom80_flipY row8 transparent exp={exp8c:#05x}")


# ===========================================================================
# Test group 9: x_zoom = 0xC0 (quarter size)
# scale_x = 0x100 - 0xC0 = 0x40 → rendered_width = (16 * 0x40) >> 8 = 4
# Gradient tile: output cols 0..3 only
# ===========================================================================
emit({"op": "reset", "note": "reset for x_zoom=0xC0 quarter-width test"})
model_reset()

TC9 = 0x09
PAL9 = 0x03
SPR9_SX = 200
SPR9_SY = 160

write_gfx_gradient_row(TC9, 0)
for row in range(1, 16):
    write_gfx_solid_row(TC9, row, 3)

write_sprite_entry(0, TC9, SPR9_SX, SPR9_SY, PAL9,
                   x_zoom=0xC0, y_zoom=0x00, note="spr[0] x_zoom=0xC0 (4px wide)")

VPOS9 = SPR9_SY - 1
# Visible: cols 0..3
for col_off in range(4):
    exp = model_spr_pixel(VPOS9, SPR9_SX + col_off)
    check_spr(VPOS9, SPR9_SX + col_off, exp,
              f"x_zoomC0 col+{col_off} (visible) exp={exp:#05x}")

# Transparent: cols 4..15
for col_off in range(4, 16):
    exp = model_spr_pixel(VPOS9, SPR9_SX + col_off)
    check_spr(VPOS9, SPR9_SX + col_off, exp,
              f"x_zoomC0 col+{col_off} (transparent) exp={exp:#05x}")


# ===========================================================================
# Test group 10: y_zoom = 0xC0 (quarter height)
# scale_y = 0x100 - 0xC0 = 0x40 → rendered_height = (16 * 0x40) >> 8 = 4
# Distinct rows: row 0=pen_A, row 3=pen_B, row 4+ = pen_1
# Verify rows 0..3 visible; rows 4..15 transparent.
# ===========================================================================
emit({"op": "reset", "note": "reset for y_zoom=0xC0 quarter-height test"})
model_reset()

TC10 = 0x0A
PAL10 = 0x1C
SPR10_SX = 50
SPR10_SY = 40

for row in range(16):
    if   row == 0: write_gfx_solid_row(TC10, row, 0xA)
    elif row == 3: write_gfx_solid_row(TC10, row, 0xB)
    else:          write_gfx_solid_row(TC10, row, 1)

write_sprite_entry(0, TC10, SPR10_SX, SPR10_SY, PAL10,
                   y_zoom=0xC0, note="spr[0] y_zoom=0xC0 (4 rows)")

# Rows 0..3 visible
for row_off in range(4):
    vpos_r = SPR10_SY - 1 + row_off  # renders scan SPR10_SY + row_off
    exp = model_spr_pixel(vpos_r, SPR10_SX)
    check_spr(vpos_r, SPR10_SX, exp,
              f"y_zoomC0 row+{row_off} visible exp={exp:#05x}")

# Rows 4..15 transparent
for row_off in range(4, 16):
    vpos_r = SPR10_SY - 1 + row_off
    if vpos_r + 1 < V_END:
        exp = model_spr_pixel(vpos_r, SPR10_SX)
        check_spr(vpos_r, SPR10_SX, exp,
                  f"y_zoomC0 row+{row_off} transparent exp={exp:#05x}")


# ===========================================================================
# Test group 11: Two zoomed sprites at same position — lower-address wins
# sprite 0: x_zoom=0x80 (8 wide), palette=5, pen=3
# sprite 1: x_zoom=0x00 (16 wide), palette=2, pen=7
# col 0..7: both sprites present → sprite 0 (lower address, drawn last) wins
# col 8..15: only sprite 1 visible (sprite 0 too narrow)
# ===========================================================================
emit({"op": "reset", "note": "reset for zoom overlap priority test"})
model_reset()

TC11A = 0x0B  # sprite 0: half-width, pen=3
TC11B = 0x0C  # sprite 1: full-width, pen=7
PAL11A = 0x05
PAL11B = 0x02
SPR11_SX = 130
SPR11_SY = 170

write_gfx_solid_tile(TC11A, 3)
write_gfx_solid_tile(TC11B, 7)

write_sprite_entry(0, TC11A, SPR11_SX, SPR11_SY, PAL11A,
                   x_zoom=0x80, note="spr[0] zoom half-width pen=3 (top)")
write_sprite_entry(1, TC11B, SPR11_SX, SPR11_SY, PAL11B,
                   x_zoom=0x00, note="spr[1] full-width pen=7 (bottom)")

VPOS11 = SPR11_SY - 1
# Cols 0..7: sprite 0 on top (lower addr, last written)
for col_off in range(8):
    exp = model_spr_pixel(VPOS11, SPR11_SX + col_off)
    check_spr(VPOS11, SPR11_SX + col_off, exp,
              f"zoom_overlap col+{col_off} (spr0 wins) exp={exp:#05x}")

# Cols 8..15: only sprite 1 (sprite 0 not wide enough)
for col_off in range(8, 16):
    exp = model_spr_pixel(VPOS11, SPR11_SX + col_off)
    check_spr(VPOS11, SPR11_SX + col_off, exp,
              f"zoom_overlap col+{col_off} (spr1 only) exp={exp:#05x}")


# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step9_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors -> {out_path}")
