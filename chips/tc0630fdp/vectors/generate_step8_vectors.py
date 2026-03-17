#!/usr/bin/env python3
"""
generate_step8_vectors.py — Step 8 test vector generator for tc0630fdp.

Produces step8_vectors.jsonl: Simple Sprites (No Zoom, No Block, No Jump).

Test cases (per section3_rtl_plan.md Step 8):
  1. Single sprite at (100, 80): verify pixels appear at correct screen position.
  2. flipX on sprite: verify horizontal mirror.
  3. flipY on sprite: verify vertical mirror.
  4. Transparent pen (pen=0): verify sprite pixel not written (zero output).
  5. Two sprites at overlapping positions: lower-address sprite drawn last = on top.
  6. Off-screen sprite (sx=-20): verify partial clip at left edge.
  7. Sprite at right edge (sx=310): verify partial clip at right edge.
  8. Sprite near top (sy=24): verify topmost row visible.
  9. Sprite near bottom (sy=240): only rows within V_END visible.
 10. All 16 distinct pen values in a single tile row.

Sprite RAM word address mapping:
  entry N base = N * 8  (chip word address within Sprite RAM)
  Chip-window word address = 0x20000 + word_offset.
  RTL Sprite RAM is indexed by cpu_addr[15:1], covering 0x20000–0x27FFF.
  Word offset within entry: 0=tile_lo, 2=sx, 3=sy, 4=ctrl, 5=tile_hi.

check_sprite_pixel op:
  target_vpos : scanline whose HBLANK triggers the renderer (renders vpos+1)
  screen_col  : column 0..319 in active display
  exp_pixel   : expected spr_pixel_out (12-bit: {prio[1:0],palette[5:0],pen[3:0]})
                exp_pixel = 0 means "no sprite pixel (transparent)"
"""

import json
import os
from fdp_model import TaitoF3Model

# ---------------------------------------------------------------------------
# Timing constants
# ---------------------------------------------------------------------------
V_START = 24
V_END   = 256
H_START = 46

vectors = []


def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
# Single persistent model
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
# Low-level helpers
# ---------------------------------------------------------------------------
SPR_BASE_CHIP = 0x20000   # chip window word address of Sprite RAM start


def write_spr_word(word_offset: int, data: int, note: str = "") -> None:
    """Write one 16-bit word to Sprite RAM via CPU write op."""
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
    """Write a complete 8-word sprite entry to Sprite RAM (words 0,1,2,3,4,5).

    idx       : sprite entry index (0..255 for Step 8/9)
    tile_code : 17-bit tile code
    sx        : screen X signed (12-bit)
    sy        : screen Y signed (12-bit)
    color     : 8-bit: [7:6]=priority_group, [5:0]=palette
    flipx     : horizontal flip
    flipy     : vertical flip
    x_zoom    : 8-bit X zoom (0x00=full, 0x80=half; Step 9)
    y_zoom    : 8-bit Y zoom (0x00=full, 0x80=half; Step 9)
    """
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

    # Mirror to model
    m.write_sprite_entry(idx, tile_code, sx, sy, color, flipx, flipy,
                         x_zoom=x_zoom, y_zoom=y_zoom)


def write_gfx_word(word_addr: int, data: int, note: str = "") -> None:
    """Write one 32-bit word to GFX ROM."""
    emit({"op": "write_gfx",
          "gfx_addr": word_addr,
          "gfx_data": data & 0xFFFFFFFF,
          "note": note or f"gfx[{word_addr:#06x}] = {data:#010x}"})
    if word_addr < m.GFX_ROM_WORDS:
        m.gfx_rom[word_addr] = data & 0xFFFFFFFF


def write_gfx_row(tile_code: int, row: int, left_word: int, right_word: int,
                  note: str = "") -> None:
    """Write one tile row (16 pixels) to GFX ROM."""
    base = tile_code * 32 + row * 2
    write_gfx_word(base,     left_word,  note or f"gfx tile={tile_code} row={row} left")
    write_gfx_word(base + 1, right_word, note or f"gfx tile={tile_code} row={row} right")


def write_gfx_solid_row(tile_code: int, row: int, pen: int) -> None:
    """Write a solid-color row (all pixels = pen) to GFX ROM."""
    n = pen & 0xF
    word = 0
    for _ in range(8):
        word = (word << 4) | n
    write_gfx_row(tile_code, row, word, word,
                  f"gfx solid tile={tile_code} row={row} pen={pen:#x}")


def write_gfx_solid_tile(tile_code: int, pen: int) -> None:
    """Write all 16 rows of a tile with solid pen value."""
    for row in range(16):
        write_gfx_solid_row(tile_code, row, pen)


def write_gfx_gradient_row(tile_code: int, row: int) -> None:
    """Write a row where left half has pen=px (0..7) and right half has pen=px+8."""
    left_word = 0
    for px in range(8):
        left_word = (left_word << 4) | px
    right_word = 0
    for px in range(8):
        right_word = (right_word << 4) | (px + 8)
    write_gfx_row(tile_code, row, left_word, right_word,
                  f"gfx gradient tile={tile_code} row={row}")


def check_spr(target_vpos: int, screen_col: int, exp_pixel: int, note: str) -> None:
    """Emit a check_sprite_pixel test vector."""
    emit({"op": "check_sprite_pixel",
          "vpos":       target_vpos,
          "screen_col": screen_col,
          "exp_pixel":  exp_pixel & 0xFFF,
          "note":       note})


def model_spr_pixel(vpos: int, screen_col: int) -> int:
    """Query the model's sprite pixel at screen_col for scanline vpos+1."""
    slist = m.scan_sprites()
    linebuf = m.render_sprite_scanline(vpos, slist)
    return linebuf[screen_col]


# ===========================================================================
# Test group 1: Single sprite at (100, 80) — solid pen=5 tile
# The sprite occupies screen columns 100..115, rows 80..95.
# Target HBLANK: vpos=79 (renders scanline 80)
# ===========================================================================
emit({"op": "reset", "note": "reset for single sprite position test"})
model_reset()

TC1 = 0x01   # tile code for test group 1
PEN1 = 5
PAL1 = 0x07   # palette 7, priority group 0 (color[7:6]=00)
SPR1_SX = 100
SPR1_SY = 80

write_gfx_solid_tile(TC1, PEN1)
write_sprite_entry(0, TC1, SPR1_SX, SPR1_SY, PAL1, note="spr[0] solid pen=5 at (100,80)")

# Row at sy=80 (vpos=79 → renders scan 80)
VPOS1 = SPR1_SY - 1   # = 79
for col_off in [0, 4, 7, 8, 12, 15]:
    exp = model_spr_pixel(VPOS1, SPR1_SX + col_off)
    check_spr(VPOS1, SPR1_SX + col_off, exp,
              f"spr_pos row0 col+{col_off} exp={exp:#05x}")

# Row at sy+8 (vpos=87 → renders scan 88)
VPOS1B = SPR1_SY + 7   # = 87
for col_off in [0, 7, 8, 15]:
    exp = model_spr_pixel(VPOS1B, SPR1_SX + col_off)
    check_spr(VPOS1B, SPR1_SX + col_off, exp,
              f"spr_pos row8 col+{col_off} exp={exp:#05x}")

# Verify columns just outside sprite are transparent
for col_off in [-1, 16]:
    sc = SPR1_SX + col_off
    if 0 <= sc < 320:
        exp = model_spr_pixel(VPOS1, sc)
        check_spr(VPOS1, sc, exp,
                  f"spr_pos outside col={sc} (expect transparent)")


# ===========================================================================
# Test group 2: flipX — sprite mirrored horizontally
# tile has ascending pen pattern so flip is detectable
# ===========================================================================
emit({"op": "reset", "note": "reset for flipX test"})
model_reset()

TC2 = 0x02
PAL2 = 0x0A   # palette 10, priority group 0
SPR2_SX = 60
SPR2_SY = 50

# Row 0: left=[0,1,2,3,4,5,6,7], right=[8,9,10,11,12,13,14,15]
write_gfx_gradient_row(TC2, 0)
# Fill remaining rows with solid pen=1
for row in range(1, 16):
    write_gfx_solid_row(TC2, row, 1)

write_sprite_entry(0, TC2, SPR2_SX, SPR2_SY, PAL2, flipx=True, note="spr[0] flipX gradient")

VPOS2 = SPR2_SY - 1  # renders scan SPR2_SY
for col_off in [0, 1, 7, 8, 14, 15]:
    exp = model_spr_pixel(VPOS2, SPR2_SX + col_off)
    check_spr(VPOS2, SPR2_SX + col_off, exp,
              f"flipX col+{col_off} exp={exp:#05x}")


# ===========================================================================
# Test group 3: flipY — sprite mirrored vertically
# tile has row 0 = solid pen=3, row 15 = solid pen=7; other rows pen=1
# With flipY, row 15 renders at sy, row 0 renders at sy+15
# ===========================================================================
emit({"op": "reset", "note": "reset for flipY test"})
model_reset()

TC3 = 0x03
PAL3 = 0x15   # palette 21, priority group 0
SPR3_SX = 80
SPR3_SY = 100

# row 0 = pen 3, row 15 = pen 7, rest = pen 1
for row in range(16):
    if   row == 0:  write_gfx_solid_row(TC3, row, 3)
    elif row == 15: write_gfx_solid_row(TC3, row, 7)
    else:           write_gfx_solid_row(TC3, row, 1)

write_sprite_entry(0, TC3, SPR3_SX, SPR3_SY, PAL3, flipy=True, note="spr[0] flipY")

# With flipY: render_scan=SPR3_SY (vpos=SPR3_SY-1) → tile row 15 (pen=7)
VPOS3a = SPR3_SY - 1
exp_top = model_spr_pixel(VPOS3a, SPR3_SX)
check_spr(VPOS3a, SPR3_SX, exp_top, f"flipY top row (expect pen=7) exp={exp_top:#05x}")
check_spr(VPOS3a, SPR3_SX + 8, exp_top, f"flipY top row col+8 exp={exp_top:#05x}")

# render_scan=SPR3_SY+15 (vpos=SPR3_SY+14) → tile row 0 (pen=3)
VPOS3b = SPR3_SY + 14
exp_bot = model_spr_pixel(VPOS3b, SPR3_SX)
check_spr(VPOS3b, SPR3_SX, exp_bot, f"flipY bottom row (expect pen=3) exp={exp_bot:#05x}")

# Middle row (tile row 7 → render row 8 when flipped): pen=1
VPOS3c = SPR3_SY + 7
exp_mid = model_spr_pixel(VPOS3c, SPR3_SX)
check_spr(VPOS3c, SPR3_SX, exp_mid, f"flipY mid row (expect pen=1) exp={exp_mid:#05x}")


# ===========================================================================
# Test group 4: transparent pen (pen=0) — sprite pixel must be zero
# tile row 0: mixed with pen=0 in some positions
# ===========================================================================
emit({"op": "reset", "note": "reset for transparent pen test"})
model_reset()

TC4 = 0x04
PAL4 = 0x1F   # palette 31, priority group 0
SPR4_SX = 140
SPR4_SY = 70

# row 0: alternating pen=0 (transparent) and pen=6
# nibble pattern: 0x06060606 for left half, 0x06060606 for right half
#   px0=0,px1=6,px2=0,px3=6,px4=0,px5=6,px6=0,px7=6 → 0x00060006...
# left_word: bits[31:28]=px0=0, [27:24]=px1=6, [23:20]=px2=0, [19:16]=px3=6,
#            [15:12]=px4=0, [11:8]=px5=6, [7:4]=px6=0, [3:0]=px7=6 → 0x06060606
TRANSP_ROW = 0x06060606
for row in range(16):
    write_gfx_row(TC4, row, TRANSP_ROW, TRANSP_ROW,
                  f"transparent row={row} pattern=0x06060606")
    if row < m.GFX_ROM_WORDS // 32:
        base = TC4 * 32 + row * 2
        m.gfx_rom[base]     = TRANSP_ROW
        m.gfx_rom[base + 1] = TRANSP_ROW

write_sprite_entry(0, TC4, SPR4_SX, SPR4_SY, PAL4, note="spr[0] transparent pen test")

VPOS4 = SPR4_SY - 1
# px0=transparent(0), px1=pen6, px2=transparent(0), px3=pen6...
for col_off, expected_opaque in [(0, False), (1, True), (2, False), (3, True),
                                  (8, False), (9, True), (14, False), (15, True)]:
    exp = model_spr_pixel(VPOS4, SPR4_SX + col_off)
    check_spr(VPOS4, SPR4_SX + col_off, exp,
              f"transparent col+{col_off} opaque={expected_opaque} exp={exp:#05x}")


# ===========================================================================
# Test group 5: Two overlapping sprites — lower-address wins (drawn last)
# Sprite 0 at (120, 90): solid pen=3, palette=5
# Sprite 1 at (120, 90): solid pen=9, palette=2
# Lower address = sprite 0; RTL draws sprite 0 LAST → sprite 0 wins (on top)
# ===========================================================================
emit({"op": "reset", "note": "reset for overlapping sprites test"})
model_reset()

TC5A = 0x05   # sprite 0 tile
TC5B = 0x06   # sprite 1 tile
PAL5A = 0x05  # palette 5, prio group 0
PAL5B = 0x02  # palette 2, prio group 0
SPR5_SX = 120
SPR5_SY = 90

write_gfx_solid_tile(TC5A, 3)   # sprite 0: pen=3
write_gfx_solid_tile(TC5B, 9)   # sprite 1: pen=9

write_sprite_entry(0, TC5A, SPR5_SX, SPR5_SY, PAL5A, note="spr[0] pen=3 (top)")
write_sprite_entry(1, TC5B, SPR5_SX, SPR5_SY, PAL5B, note="spr[1] pen=9 (bottom)")

VPOS5 = SPR5_SY - 1
for col_off in [0, 4, 7, 8, 12, 15]:
    exp = model_spr_pixel(VPOS5, SPR5_SX + col_off)
    check_spr(VPOS5, SPR5_SX + col_off, exp,
              f"overlap col+{col_off} (spr0 wins) exp={exp:#05x}")


# ===========================================================================
# Test group 6: Priority groups — sprite with prio=1 (color[7:6]=01)
# spr_pixel_out bit format: {prio[1:0], palette[5:0], pen[3:0]}
# Verify prio bits are correctly propagated in spr_pixel_out.
# ===========================================================================
emit({"op": "reset", "note": "reset for priority group test"})
model_reset()

TC6 = 0x07
# color[7:6]=01 → priority group 1; color[5:0]=0x17 (palette 23)
COLOR6 = (1 << 6) | 0x17   # = 0x57
SPR6_SX = 50
SPR6_SY = 120

write_gfx_solid_tile(TC6, 0xC)
write_sprite_entry(0, TC6, SPR6_SX, SPR6_SY, COLOR6, note="spr[0] prio_group=1")

VPOS6 = SPR6_SY - 1
for col_off in [0, 8, 15]:
    exp = model_spr_pixel(VPOS6, SPR6_SX + col_off)
    check_spr(VPOS6, SPR6_SX + col_off, exp,
              f"prio_group=1 col+{col_off} exp={exp:#05x} (prio bits=[11:10]={1})")


# ===========================================================================
# Test group 7: Maximum priority sprite (prio=3, color[7:6]=11)
# color[7:6]=11 → priority group 3 (0xC0); palette[5:0]=0x3F
# ===========================================================================
emit({"op": "reset", "note": "reset for max priority sprite test"})
model_reset()

TC7 = 0x08
COLOR7 = 0xFF   # color[7:6]=11, palette=0x3F
SPR7_SX = 200
SPR7_SY = 150

write_gfx_solid_tile(TC7, 0xE)
write_sprite_entry(0, TC7, SPR7_SX, SPR7_SY, COLOR7, note="spr[0] max priority (prio=3)")

VPOS7 = SPR7_SY - 1
for col_off in [0, 7, 8, 15]:
    exp = model_spr_pixel(VPOS7, SPR7_SX + col_off)
    check_spr(VPOS7, SPR7_SX + col_off, exp,
              f"max_prio col+{col_off} exp={exp:#05x}")


# ===========================================================================
# Test group 8: Partial clip — sprite extends past left screen edge (sx=-4)
# Columns -4..-1 off screen, columns 0..11 visible.
# ===========================================================================
emit({"op": "reset", "note": "reset for left-edge clip test"})
model_reset()

TC8 = 0x09
PAL8 = 0x08
SPR8_SX = -4   # 4 pixels off-screen left
SPR8_SY = 60

write_gfx_gradient_row(TC8, 0)
for row in range(1, 16):
    write_gfx_solid_row(TC8, row, 2)

write_sprite_entry(0, TC8, SPR8_SX, SPR8_SY, PAL8, note="spr[0] left-edge clip sx=-4")

VPOS8 = SPR8_SY - 1
# col 0..11 should be visible (sprite px 4..15)
for screen_col, col_off in [(0, 4), (4, 8), (11, 15)]:
    exp = model_spr_pixel(VPOS8, screen_col)
    check_spr(VPOS8, screen_col, exp,
              f"left_clip screen_col={screen_col} (tile_px={col_off}) exp={exp:#05x}")


# ===========================================================================
# Test group 9: Partial clip — sprite extends past right screen edge (sx=312)
# Columns 312..319 visible (px 0..7), columns 320..327 off screen.
# ===========================================================================
emit({"op": "reset", "note": "reset for right-edge clip test"})
model_reset()

TC9 = 0x0A
PAL9 = 0x09
SPR9_SX = 312   # 8 pixels off-screen right
SPR9_SY = 130

write_gfx_gradient_row(TC9, 0)
for row in range(1, 16):
    write_gfx_solid_row(TC9, row, 3)

write_sprite_entry(0, TC9, SPR9_SX, SPR9_SY, PAL9, note="spr[0] right-edge clip sx=312")

VPOS9 = SPR9_SY - 1
for screen_col in [312, 315, 319]:
    exp = model_spr_pixel(VPOS9, screen_col)
    check_spr(VPOS9, screen_col, exp,
              f"right_clip screen_col={screen_col} exp={exp:#05x}")


# ===========================================================================
# Test group 10: All 16 distinct pen values in a single tile row
# Use gradient tile (px0=0..px15=15); pen=0 → transparent
# ===========================================================================
emit({"op": "reset", "note": "reset for all-pen-values test"})
model_reset()

TC10 = 0x0B
PAL10 = 0x1A
SPR10_SX = 50
SPR10_SY = 40

write_gfx_gradient_row(TC10, 0)
for row in range(1, 16):
    write_gfx_solid_row(TC10, row, 1)

write_sprite_entry(0, TC10, SPR10_SX, SPR10_SY, PAL10, note="spr[0] all pens 0..15")

VPOS10 = SPR10_SY - 1
for col_off in range(16):
    exp = model_spr_pixel(VPOS10, SPR10_SX + col_off)
    check_spr(VPOS10, SPR10_SX + col_off, exp,
              f"allpens col+{col_off} (pen={col_off}) exp={exp:#05x}")


# ===========================================================================
# Test group 11: flipX + flipY combined
# ===========================================================================
emit({"op": "reset", "note": "reset for flipX+flipY combined test"})
model_reset()

TC11 = 0x0C
PAL11 = 0x11
SPR11_SX = 160
SPR11_SY = 110

# row 0: gradient; row 15: solid pen=E; rest: solid pen=2
write_gfx_gradient_row(TC11, 0)
for row in range(1, 15):
    write_gfx_solid_row(TC11, row, 2)
write_gfx_solid_row(TC11, 15, 0xE)

write_sprite_entry(0, TC11, SPR11_SX, SPR11_SY, PAL11,
                  flipx=True, flipy=True, note="spr[0] flipX+flipY")

VPOS11 = SPR11_SY - 1   # renders row 15 (flipY) from right (flipX)
for col_off in [0, 7, 8, 15]:
    exp = model_spr_pixel(VPOS11, SPR11_SX + col_off)
    check_spr(VPOS11, SPR11_SX + col_off, exp,
              f"flipXY top col+{col_off} exp={exp:#05x}")

VPOS11b = SPR11_SY + 14  # renders row 0 (flipY from bottom) with flipX
for col_off in [0, 7, 8, 15]:
    exp = model_spr_pixel(VPOS11b, SPR11_SX + col_off)
    check_spr(VPOS11b, SPR11_SX + col_off, exp,
              f"flipXY bot col+{col_off} exp={exp:#05x}")


# ===========================================================================
# Test group 12: Slot overflow — fill 64 sprites on one scanline;
# sprite at slot 64 must NOT appear (silently dropped).
# Uses a unique tile to distinguish overflow sprite.
# ===========================================================================
emit({"op": "reset", "note": "reset for slot overflow test"})
model_reset()

TC_OVER = 0x0D   # tile for overflowing sprite
PAL_OVER = 0x3E
SPR_OVER_SX = 180
SPR_OVER_SY = 200

TC_FILL = 0x0E   # tile for filler sprites (non-overlapping, different X)
PAL_FILL = 0x01

write_gfx_solid_tile(TC_OVER, 0xF)
write_gfx_solid_tile(TC_FILL, 0x1)

# Write 64 filler sprites occupying scan 200 (sy=200..200 or sy=200..215).
# Place them at non-overlapping X positions (outside 180..195).
for i in range(64):
    sx_fill = (i * 16) % 320
    # Keep them away from the overflow sprite column to avoid mix-up in check
    # Alternate: use sy=200 for all, and place at x positions 0, 16, 32, ...
    # Ensure none overlap with SPR_OVER_SX=180
    if sx_fill == 176 or sx_fill == 192:
        sx_fill = 250   # move out of the way
    write_sprite_entry(i, TC_FILL, sx_fill, SPR_OVER_SY, PAL_FILL,
                       note=f"slot_fill[{i}] sx={sx_fill}")

# Entry 64 = the overflow sprite at column 180 — must be silently dropped
write_sprite_entry(64, TC_OVER, SPR_OVER_SX, SPR_OVER_SY, PAL_OVER,
                   note="spr[64] OVERFLOW should be invisible")

VPOS_OVER = SPR_OVER_SY - 1
# The column at 180 should show NO sprite pixel (overflow slot dropped)
exp_over = model_spr_pixel(VPOS_OVER, SPR_OVER_SX)
check_spr(VPOS_OVER, SPR_OVER_SX, exp_over,
          f"overflow spr[64] at col=180 exp={exp_over:#05x} (transparent=0)")


# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step8_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors -> {out_path}")
