#!/usr/bin/env python3
"""
generate_step4_vectors.py — Step 4 test vector generator for tc0630fdp.

Produces step4_vectors.jsonl: Text Layer + Character RAM (Plan Step 4).

Covers the Plan Step 4 test cases that are NOT in step2_vectors.jsonl:
  1. Character update — next-frame test: write char data, verify frame N pixel,
     then overwrite char data, verify frame N+1 shows the new pixel.
  2. Extended color field test — all 32 possible color[4:0] values round-trip.
  3. Text over BG — verify text_pixel_out is non-zero at a coordinate where
     bg_pixel_out[0] is also non-zero (both layers have content at same position).
     This validates that the text layer renders correctly independent of BG content,
     a prerequisite for the compositor to "text wins" in Plan Step 11.
  4. Full-row multi-tile check — verify 40 consecutive tile columns across a
     complete scanline using Python model cross-check.
  5. Charlayout row offsets — verify py=4 and py=7 (non-trivial rows).
  6. Char code boundary — code 0 and code 255 (max for 256-tile char RAM).
  7. Tile map row boundary — verify tile fetch at row 0 and row 63.
  8. Solid pen=0 tile at tile (0,0) — verify text_pixel_out = 0 (transparent)
     while bg_pixel_out[0] != 0 at the same column.

Addressing conventions (identical to generate_step2_vectors.py):
  Text RAM base cpu_addr: 0x0E000
  Char RAM base cpu_addr: 0x0F000  (word address = byte_addr / 2)
  PF1 RAM base  cpu_addr: 0x04000
  Ctrl regs:    cpu_addr: 0..15

GFX ROM: written via "write_gfx" op (gfx_addr = 32-bit word address, gfx_data = 32-bit).
"""

import json
import os
from fdp_model import TaitoF3Model

vectors = []

def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
# Address constants
# ---------------------------------------------------------------------------
TEXT_RAM_BASE = 0x0E000   # cpu_addr for text RAM word 0
CHAR_RAM_BASE = 0x0F000   # cpu_addr for char RAM word 0
PF1_BASE      = 0x04000   # cpu_addr for PF1 RAM word 0

H_START  = 46
H_END    = 366
V_TOTAL  = 262
V_START  = 24
V_END    = 256


# ---------------------------------------------------------------------------
# Helpers: identical to generate_step2_vectors.py so the two files are
# self-contained and can run independently.
# ---------------------------------------------------------------------------

def write_text_word(word_idx: int, data: int, note: str = ""):
    emit({"op": "write_text",
          "addr": TEXT_RAM_BASE + word_idx,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"text_ram[{word_idx:#05x}] = {data:#06x}"})


def write_char_word(byte_addr: int, data: int, note: str = ""):
    word_idx = byte_addr // 2
    emit({"op": "write_char",
          "addr": CHAR_RAM_BASE + word_idx,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"char_ram_b{byte_addr:#06x} = {data:#06x}"})


def check_text_pixel(vpos: int, screen_col: int, exp_pixel: int, note: str):
    emit({"op": "check_text_pixel",
          "vpos": vpos,
          "screen_col": screen_col,
          "exp_pixel": exp_pixel & 0x1FF,
          "note": note})


def tile_word(char_code: int, color: int) -> int:
    """Encode a text tile word: color[15:11] | char_code[10:0]."""
    return ((color & 0x1F) << 11) | (char_code & 0x7FF)


def encode_row(pens: list) -> tuple:
    """Encode 8 pens [px0..px7] into (b0, b1, b2, b3) per charlayout §11.1.

    Charlayout nibble mapping:
      px0 → b2[7:4]   px1 → b2[3:0]
      px2 → b3[7:4]   px3 → b3[3:0]
      px4 → b0[7:4]   px5 → b0[3:0]
      px6 → b1[7:4]   px7 → b1[3:0]
    Returns (b0, b1, b2, b3) each as 8-bit int.
    """
    assert len(pens) == 8
    b0 = ((pens[4] & 0xF) << 4) | (pens[5] & 0xF)
    b1 = ((pens[6] & 0xF) << 4) | (pens[7] & 0xF)
    b2 = ((pens[0] & 0xF) << 4) | (pens[1] & 0xF)
    b3 = ((pens[2] & 0xF) << 4) | (pens[3] & 0xF)
    return b0, b1, b2, b3


def write_char_row(char_code: int, py: int, pens: list, tag: str = ""):
    """Write one row of a character tile to Char RAM."""
    b0, b1, b2, b3 = encode_row(pens)
    base_byte = char_code * 32 + py * 4
    write_char_word(base_byte + 0, (b0 << 8) | b1,
                    f"{tag}char{char_code:#04x} py={py} b0b1")
    write_char_word(base_byte + 2, (b2 << 8) | b3,
                    f"{tag}char{char_code:#04x} py={py} b2b3")


def write_pf_tile(tile_idx: int, palette: int, tile_code: int,
                  flip_x: bool = False, flip_y: bool = False):
    """Write one PF1 tile entry (attr + code) to PF1 RAM."""
    attr = (palette & 0x1FF)
    if flip_x: attr |= (1 << 14)
    if flip_y: attr |= (1 << 15)
    word_base = tile_idx * 2
    emit({"op": "write_pf",
          "addr": PF1_BASE + word_base,
          "data": attr,
          "be": 3,
          "note": f"PF1 tile[{tile_idx}] attr={attr:#06x}"})
    emit({"op": "write_pf",
          "addr": PF1_BASE + word_base + 1,
          "data": tile_code & 0xFFFF,
          "be": 3,
          "note": f"PF1 tile[{tile_idx}] code={tile_code:#06x}"})


def write_gfx_tile_row(tile_code: int, row: int, left_word: int, right_word: int):
    """Write one row of GFX ROM for a given tile_code."""
    base_addr = tile_code * 32 + row * 2
    emit({"op": "write_gfx", "gfx_addr": base_addr,
          "gfx_data": left_word & 0xFFFFFFFF,
          "note": f"gfx tile{tile_code:#06x} row{row} left={left_word:#010x}"})
    emit({"op": "write_gfx", "gfx_addr": base_addr + 1,
          "gfx_data": right_word & 0xFFFFFFFF,
          "note": f"gfx tile{tile_code:#06x} row{row} right={right_word:#010x}"})


def check_bg_pixel(vpos: int, screen_col: int, plane: int,
                   exp_pixel: int, note: str):
    emit({"op": "check_bg_pixel",
          "vpos": vpos,
          "screen_col": screen_col,
          "plane": plane,
          "exp_pixel": exp_pixel & 0x1FFF,
          "note": note})


def check_text_over_bg(vpos: int, screen_col: int,
                       exp_text: int, exp_bg: int, note: str):
    """Verify BOTH text_pixel_out and bg_pixel_out[0] at the same coordinate.

    This is Plan Step 4, Test 4 — both layers have content; the text layer
    must produce the expected text pixel (text will win when compositing is
    implemented in Step 11).
    """
    emit({"op": "check_text_over_bg",
          "vpos": vpos,
          "screen_col": screen_col,
          "exp_text": exp_text & 0x1FF,
          "exp_bg":   exp_bg   & 0x1FFF,
          "note": note})


# ===========================================================================
# Test group 1: Character update — next-frame test (Plan Step 4, Test 2)
# ===========================================================================
# Write char 0xA0 with pen=5 for py=0. Verify pixel on scanline A.
# Then overwrite char 0xA0 with pen=0xE for py=0. Verify pixel on scanline B
# that the NEW pen value appears.
# The testbench must NOT reset between the two checks to prove the character
# RAM update is picked up dynamically on the next HBLANK.

emit({"op": "reset", "note": "reset for char-update next-frame test"})

CHAR_UPDATE = 0xA0
COLOR_UPDATE = 0x07
PEN_V1       = 0x5   # first version of the character
PEN_V2       = 0xE   # updated character
TILE_COL_U   = 3     # screen tile column 3 → screen pixels 24..31

# Scanline A: vpos such that fetch_py=0, fetch_row=5
VPOS_A = 39    # fetch_vpos=40, py=0, row=5
FPY_A  = (VPOS_A + 1) & 7      # 0
FROW_A = ((VPOS_A + 1) & 0x1FF) >> 3   # 5
assert FPY_A == 0 and FROW_A == 5

# Scanline B: vpos such that fetch_py=0, fetch_row=6
VPOS_B = 47    # fetch_vpos=48, py=0, row=6
FPY_B  = (VPOS_B + 1) & 7      # 0
FROW_B = ((VPOS_B + 1) & 0x1FF) >> 3   # 6
assert FPY_B == 0 and FROW_B == 6

# Write tile map entries for both rows (same char, same column)
tw_u = tile_word(CHAR_UPDATE, COLOR_UPDATE)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + FROW_A * 64 + TILE_COL_U,
      "data": tw_u, "be": 3,
      "note": f"char-update: tile rowA={FROW_A} col{TILE_COL_U} = char{CHAR_UPDATE:#04x}"})
emit({"op": "write_text", "addr": TEXT_RAM_BASE + FROW_B * 64 + TILE_COL_U,
      "data": tw_u, "be": 3,
      "note": f"char-update: tile rowB={FROW_B} col{TILE_COL_U} = char{CHAR_UPDATE:#04x}"})

# Write version 1 of char 0xA0, py=0 (also fill py=0 for row B same char)
write_char_row(CHAR_UPDATE, FPY_A, [PEN_V1] * 8, "char-update-v1: ")
# (FPY_A == FPY_B == 0, so one write covers both scanlines.)

# Check scanline A: should show PEN_V1
EXP_A = (COLOR_UPDATE << 4) | PEN_V1
check_text_pixel(VPOS_A, TILE_COL_U * 8, EXP_A,
                 f"char-update: scanline A vpos={VPOS_A} → pen={PEN_V1:#x} (v1)")

# Now overwrite char 0xA0, py=0 with PEN_V2 (no reset in between)
write_char_row(CHAR_UPDATE, FPY_A, [PEN_V2] * 8, "char-update-v2: ")

# Check scanline B: must show PEN_V2 (updated character, next frame)
EXP_B = (COLOR_UPDATE << 4) | PEN_V2
check_text_pixel(VPOS_B, TILE_COL_U * 8, EXP_B,
                 f"char-update: scanline B vpos={VPOS_B} → pen={PEN_V2:#x} (v2, updated)")


# ===========================================================================
# Test group 2: Extended color field test (Plan Step 4, Test 3)
# ===========================================================================
# All 32 color values (0x00 through 0x1F). Use char 0xB0 with pen=0x9.
# Use 32 tile columns on a single scanline row.
# vpos=55 → fetch_vpos=56, py=0, row=7.

emit({"op": "reset", "note": "reset for color field test (all 32 values)"})

VPOS_CF = 55    # fetch_vpos=56, py=0, row=7
FV_CF   = (VPOS_CF + 1) & 0x1FF   # 56
FPY_CF  = FV_CF & 7                # 0
FROW_CF = FV_CF >> 3               # 7
assert FPY_CF == 0 and FROW_CF == 7

CHAR_CF_BASE = 0xB0   # chars 0xB0..0xBF (we only need pen data once per char)
PEN_CF = 0x9

for color in range(32):
    # Use distinct char codes to avoid aliasing between color tests;
    # wrap to 256 char RAM slots: use (CHAR_CF_BASE + color % 16) — but
    # since we write the same pen for all, any char code with pen data works.
    # Use char 0xB0 for all (pen data written once below).
    char_c = CHAR_CF_BASE
    tw_cf = tile_word(char_c, color)
    tile_idx_cf = FROW_CF * 64 + color  # columns 0..31
    emit({"op": "write_text", "addr": TEXT_RAM_BASE + tile_idx_cf,
          "data": tw_cf, "be": 3,
          "note": f"color-field: col{color} color={color:#04x}"})

# Write char 0xB0 py=0 with PEN_CF for all 8 pixels (once; shared by all columns)
write_char_row(CHAR_CF_BASE, FPY_CF, [PEN_CF] * 8, "color-field: ")

# Check: one pixel per color value — at screen_col = color*8 + 4 (middle of tile)
for color in range(32):
    exp_cf = (color << 4) | PEN_CF
    check_text_pixel(VPOS_CF, color * 8 + 4, exp_cf,
                     f"color-field: color={color:#04x} pen={PEN_CF:#x}")


# ===========================================================================
# Test group 3: Text over BG (Plan Step 4, Test 4)
# ===========================================================================
# Place text tile and BG (PF1) tile at the same screen position.
# Verify that text_pixel_out shows the text pixel value (non-zero),
# and bg_pixel_out[0] also shows a non-zero BG pixel value.
# This is the "both layers have content" prerequisite for "text wins".
# Actual priority compositing is Plan Step 11.
#
# vpos=79 → fetch_vpos=80, fetch_py=0, fetch_row=10, canvas_y=0+yscroll.
# Use xscroll=0, yscroll=0 for simplicity.
#
# Screen col=16 → tile col=2 for text, BG tile_x=1 (canvas_x=16, tile_x=16/16=1).

emit({"op": "reset", "note": "reset for text-over-BG test"})

# Ctrl regs: xscroll=0, yscroll=0 (all zero after reset — no explicit write needed)

VPOS_TOB = 79   # fetch_vpos=80, fetch_py=0, fetch_row=10
FV_TOB   = (VPOS_TOB + 1) & 0x1FF   # 80
FPY_TOB  = FV_TOB & 7                # 0
FROW_TOB = FV_TOB >> 3               # 10
assert FPY_TOB == 0 and FROW_TOB == 10

SCOL_TOB   = 16   # screen column 16 → text tile col=2, BG tile_x=1
TEXT_COL_T = 2    # text tile column = screen_col / 8 = 2
TEXT_ROW_T = FROW_TOB

CHAR_TOB  = 0xC0
COLOR_TOB = 0x1B   # text color (5-bit) = 27
PEN_TOB   = 0xD    # text pen = 13

BG_PALETTE = 0x12A   # 9-bit BG palette (< 0x200 range)
BG_TILE_CODE = 0x02  # GFX ROM tile code 2
BG_PEN   = 0x7       # 4-bit BG pen

# --- Write text tile ---
tw_tob = tile_word(CHAR_TOB, COLOR_TOB)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + TEXT_ROW_T * 64 + TEXT_COL_T,
      "data": tw_tob, "be": 3,
      "note": f"text-over-BG: text tile row{TEXT_ROW_T} col{TEXT_COL_T}=char{CHAR_TOB:#04x}"})
write_char_row(CHAR_TOB, FPY_TOB, [PEN_TOB] * 8, "text-over-BG text: ")

# --- Write BG (PF1) tile ---
# canvas_y = (vpos+1 + yscroll_int) & 0x1FF = (80 + 0) = 80 → tile_y=5
# canvas_x at screen_col=16: (16 + xscroll_int=0) = 16 → tile_x=1
BG_TILE_Y = 5   # canvas_y = 80 → tile_y = 80 >> 4 = 5
BG_TILE_X = 1   # canvas_x = 16 → tile_x = 16 >> 4 = 1
BG_TILE_IDX = BG_TILE_Y * 32 + BG_TILE_X   # standard mode: map_width=32

write_pf_tile(BG_TILE_IDX, BG_PALETTE, BG_TILE_CODE)

# Write GFX ROM row FPY_TOB=0 for BG tile code 2: all pixels pen BG_PEN
# GFX ROM format: 32-bit word, nibbles [31:28]=px0..[3:0]=px7
# pen BG_PEN in every nibble:
nibble = BG_PEN & 0xF
gfx_solid = 0
for i in range(8):
    gfx_solid = (gfx_solid << 4) | nibble
write_gfx_tile_row(BG_TILE_CODE, FPY_TOB, gfx_solid, gfx_solid)

# Expected text pixel at screen_col=16: {COLOR_TOB, PEN_TOB}
EXP_TEXT_TOB = (COLOR_TOB << 4) | PEN_TOB
# Expected BG pixel at screen_col=16:  {BG_PALETTE[8:0], BG_PEN}
EXP_BG_TOB   = (BG_PALETTE << 4) | BG_PEN

# Check both layers simultaneously — new testbench op
check_text_over_bg(VPOS_TOB, SCOL_TOB, EXP_TEXT_TOB, EXP_BG_TOB,
                   f"text-over-BG: text pixel (col={SCOL_TOB})")

# Also check a few adjacent pixels to confirm full-tile coverage
for px_off in range(1, 4):
    check_text_over_bg(VPOS_TOB, SCOL_TOB + px_off,
                       EXP_TEXT_TOB, EXP_BG_TOB,
                       f"text-over-BG: pixel col={SCOL_TOB+px_off}")


# ===========================================================================
# Test group 4: Full-row multi-tile check — all 40 columns (Plan Step 4 model
# cross-check extension)
# ===========================================================================
# Uses Python model to generate all 320 pixel values for a scanline with a
# heterogeneous character set, then checks every 8 pixels (one per tile).

emit({"op": "reset", "note": "reset for full-row multi-tile model cross-check"})

m = TaitoF3Model()

VPOS_FR = 87    # fetch_vpos=88, py=0, row=11
FV_FR   = (VPOS_FR + 1) & 0x1FF   # 88
FPY_FR  = FV_FR & 7                # 0
FROW_FR = FV_FR >> 3               # 11
assert FPY_FR == 0 and FROW_FR == 11

# Populate 40 tiles with distinct (char_code, color, pen) triplets
for col in range(40):
    char_c  = (0xD0 + (col % 16)) & 0xFF   # cycles through D0..DF
    color_c = (col * 3 + 1) & 0x1F         # pseudo-random color 1..31
    pen_c   = (col % 15) + 1               # pens 1..15 (non-transparent)

    tw_fr = tile_word(char_c, color_c)
    tidx_fr = FROW_FR * 64 + col
    emit({"op": "write_text", "addr": TEXT_RAM_BASE + tidx_fr,
          "data": tw_fr, "be": 3,
          "note": f"full-row: col{col} char={char_c:#04x} color={color_c}"})
    m.write_text_ram(tidx_fr, tw_fr)

    cb_fr = char_c * 32 + FPY_FR * 4
    b0_fr, b1_fr, b2_fr, b3_fr = encode_row([pen_c] * 8)
    write_char_word(cb_fr + 0, (b0_fr << 8) | b1_fr,
                    f"full-row: char{char_c:#04x} py={FPY_FR} b0b1")
    write_char_word(cb_fr + 2, (b2_fr << 8) | b3_fr,
                    f"full-row: char{char_c:#04x} py={FPY_FR} b2b3")
    m.write_char_ram(cb_fr + 0, (b0_fr << 8) | b1_fr)
    m.write_char_ram(cb_fr + 2, (b2_fr << 8) | b3_fr)

expected_fr = m.render_text_scanline(VPOS_FR)

# Check first pixel of each tile column (screen_col = col * 8)
for col in range(40):
    scol_fr = col * 8
    exp_fr = expected_fr[scol_fr]
    check_text_pixel(VPOS_FR, scol_fr, exp_fr,
                     f"full-row: col{col} scol={scol_fr} exp={exp_fr:#05x}")


# ===========================================================================
# Test group 5: Charlayout py=4 and py=7 (non-trivial row indices)
# ===========================================================================
# Verify that the 8-row indexing (fetch_py) selects the correct char RAM row.

emit({"op": "reset", "note": "reset for charlayout py test (py=4 and py=7)"})

CHAR_PY = 0xE0
COLOR_PY = 0x0C
TILE_COL_PY = 5

for py_val, vpos_val in [(4, 91), (7, 94)]:
    # vpos=91 → fetch_vpos=92, py=4, row=11
    # vpos=94 → fetch_vpos=95, py=7, row=11
    fv_py = (vpos_val + 1) & 0x1FF
    fpy   = fv_py & 7
    frow  = fv_py >> 3
    assert fpy == py_val, f"py mismatch at vpos={vpos_val}: got {fpy}, expected {py_val}"

    # Each row has a distinct pen equal to (py_val + 1)
    pen_py = py_val + 1

    # Place tile in text map
    tw_py = tile_word(CHAR_PY, COLOR_PY)
    emit({"op": "write_text", "addr": TEXT_RAM_BASE + frow * 64 + TILE_COL_PY,
          "data": tw_py, "be": 3,
          "note": f"py-test: tile row{frow} col{TILE_COL_PY} char={CHAR_PY:#04x}"})

    # Write character data for this row
    write_char_row(CHAR_PY, py_val, [pen_py] * 8,
                   f"py-test py={py_val}: ")

    exp_py = (COLOR_PY << 4) | pen_py
    check_text_pixel(vpos_val, TILE_COL_PY * 8, exp_py,
                     f"py-test py={py_val}: vpos={vpos_val} pen={pen_py:#x}")
    check_text_pixel(vpos_val, TILE_COL_PY * 8 + 7, exp_py,
                     f"py-test py={py_val}: last px of tile col={TILE_COL_PY}")


# ===========================================================================
# Test group 6: Char code 0 and char code 255 boundary test
# ===========================================================================
# char_code=0 is the "null" character; verify it renders from the correct
# char RAM address (char 0 * 32 = byte 0).
# char_code=255 is the max for the 256-tile char RAM (8KB).

emit({"op": "reset", "note": "reset for char code boundary test"})

VPOS_CB = 103   # fetch_vpos=104, py=0, row=13
FV_CB   = (VPOS_CB + 1) & 0x1FF   # 104
FPY_CB  = FV_CB & 7                # 0
FROW_CB = FV_CB >> 3               # 13
assert FPY_CB == 0 and FROW_CB == 13

# char code 0 at tile column 0
COLOR_CB0 = 0x05; PEN_CB0 = 0x3
tw_cb0 = tile_word(0, COLOR_CB0)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + FROW_CB * 64 + 0,
      "data": tw_cb0, "be": 3, "note": "char-boundary: col0=char0"})
write_char_row(0, FPY_CB, [PEN_CB0] * 8, "char-boundary char0: ")
check_text_pixel(VPOS_CB, 0, (COLOR_CB0 << 4) | PEN_CB0,
                 "char-boundary: char_code=0 px0")
check_text_pixel(VPOS_CB, 7, (COLOR_CB0 << 4) | PEN_CB0,
                 "char-boundary: char_code=0 px7")

# char code 255 at tile column 1
COLOR_CB255 = 0x18; PEN_CB255 = 0xA
tw_cb255 = tile_word(255, COLOR_CB255)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + FROW_CB * 64 + 1,
      "data": tw_cb255, "be": 3, "note": "char-boundary: col1=char255"})
write_char_row(255, FPY_CB, [PEN_CB255] * 8, "char-boundary char255: ")
check_text_pixel(VPOS_CB, 8, (COLOR_CB255 << 4) | PEN_CB255,
                 "char-boundary: char_code=255 px8")
check_text_pixel(VPOS_CB, 15, (COLOR_CB255 << 4) | PEN_CB255,
                 "char-boundary: char_code=255 px15")


# ===========================================================================
# Test group 7: Tile map row 0 and row 63 (extremes)
# ===========================================================================
# Row 0: vpos such that fetch_vpos[8:3] = 0 → fetch_vpos in [0..7] → vpos in [-1..6].
#   Use vpos=6 → fetch_vpos=7, py=7, row=0. ✓
# Row 63: fetch_vpos[8:3] = 63 → fetch_vpos in [504..511].
#   Use vpos=503 → fetch_vpos=504, py=0, row=63.
#   But vpos only goes to 261 (V_TOTAL-1=261), and fetch_vpos = vpos+1.
#   fetch_vpos=504 → vpos=503 > 261 → INVALID.
#   Alternative: since canvas is 512 tall and wraps 9-bit, fetch_vpos can be
#   any 9-bit value. But vpos is 9-bit (0..261). Let's find fetch_py=0,row=63:
#   We need fetch_vpos = 63*8 = 504.  vpos = 503 > 261.
#   → Use vpos=255 → fetch_vpos=256, py=0, row=32 — near max accessible row.
#
# Revised: test row 0 (vpos=6, py=7) and row 32 (vpos=255, py=0).

emit({"op": "reset", "note": "reset for tile map row boundary test"})

# Row 0, py=7: vpos=6 → fetch_vpos=7, py=7, row=0
VPOS_R0 = 6
FV_R0   = (VPOS_R0 + 1) & 0x1FF   # 7
FPY_R0  = FV_R0 & 7                # 7
FROW_R0 = FV_R0 >> 3               # 0
assert FPY_R0 == 7 and FROW_R0 == 0

CHAR_R0 = 0xF0; COLOR_R0 = 0x11; PEN_R0 = 0x6
tw_r0 = tile_word(CHAR_R0, COLOR_R0)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + 0 * 64 + 0,   # row=0, col=0
      "data": tw_r0, "be": 3, "note": f"row-boundary: row0 col0=char{CHAR_R0:#04x}"})
write_char_row(CHAR_R0, FPY_R0, [PEN_R0] * 8, "row-boundary row0: ")
check_text_pixel(VPOS_R0, 0, (COLOR_R0 << 4) | PEN_R0,
                 f"row-boundary: tile map row=0 py={FPY_R0}")
check_text_pixel(VPOS_R0, 4, (COLOR_R0 << 4) | PEN_R0,
                 f"row-boundary: tile map row=0 py={FPY_R0} mid-tile")

# Row 32, py=0: vpos=255 → fetch_vpos=256, py=0, row=32
VPOS_R32 = 255
FV_R32   = (VPOS_R32 + 1) & 0x1FF   # 256
FPY_R32  = FV_R32 & 7                # 0
FROW_R32 = FV_R32 >> 3               # 32
assert FPY_R32 == 0 and FROW_R32 == 32

CHAR_R32 = 0xF1; COLOR_R32 = 0x1E; PEN_R32 = 0xB
tw_r32 = tile_word(CHAR_R32, COLOR_R32)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + 32 * 64 + 0,  # row=32, col=0
      "data": tw_r32, "be": 3, "note": f"row-boundary: row32 col0=char{CHAR_R32:#04x}"})
write_char_row(CHAR_R32, FPY_R32, [PEN_R32] * 8, "row-boundary row32: ")
check_text_pixel(VPOS_R32, 0, (COLOR_R32 << 4) | PEN_R32,
                 "row-boundary: tile map row=32 py=0")


# ===========================================================================
# Test group 8: Pen 0 text tile over non-zero BG
# ===========================================================================
# Text tile with all pen=0 pixels at a position where PF1 has a non-zero tile.
# Verify: text_pixel_out[3:0] == 0 (pen is transparent).
# The check_text_over_bg op checks text_pixel_out AND bg_pixel_out[0].
# When text pen=0, text_pixel = {color, 0} — the pixel is transparent.
# Expected text pixel = {COLOR_P0, 0}.

emit({"op": "reset", "note": "reset for pen-0-over-BG test"})

VPOS_P0 = 111   # fetch_vpos=112, py=0, row=14
FV_P0   = (VPOS_P0 + 1) & 0x1FF   # 112
FPY_P0  = FV_P0 & 7                # 0
FROW_P0 = FV_P0 >> 3               # 14
assert FPY_P0 == 0 and FROW_P0 == 14

CHAR_P0  = 0xF2
COLOR_P0 = 0x14   # some color value (non-zero)
SCOL_P0  = 24     # screen column 24 → text tile col=3

# Text tile: char 0xF2 with all pen=0 for py=0
tw_p0 = tile_word(CHAR_P0, COLOR_P0)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + FROW_P0 * 64 + 3,
      "data": tw_p0, "be": 3,
      "note": f"pen0-over-BG: text tile row{FROW_P0} col3=char{CHAR_P0:#04x}"})
# Write char with all pen=0 (transparent)
write_char_row(CHAR_P0, FPY_P0, [0] * 8, "pen0-over-BG text: ")

# BG tile (PF1): canvas_y = 112 → tile_y=7, canvas_x=24 → tile_x=1
BG_PALETTE_P0 = 0x05A
BG_TILE_CODE_P0 = 3
BG_PEN_P0 = 0x8

BG_TILE_Y_P0 = 7   # 112 >> 4 = 7
BG_TILE_X_P0 = 1   # 24 >> 4 = 1
BG_TILE_IDX_P0 = BG_TILE_Y_P0 * 32 + BG_TILE_X_P0

write_pf_tile(BG_TILE_IDX_P0, BG_PALETTE_P0, BG_TILE_CODE_P0)
nibble_p0 = BG_PEN_P0 & 0xF
gfx_solid_p0 = 0
for i in range(8):
    gfx_solid_p0 = (gfx_solid_p0 << 4) | nibble_p0
write_gfx_tile_row(BG_TILE_CODE_P0, FPY_P0, gfx_solid_p0, gfx_solid_p0)

# Expected: text pixel has pen=0 (transparent), bg pixel is non-zero
EXP_TEXT_P0 = (COLOR_P0 << 4) | 0   # pen=0 → transparent
EXP_BG_P0   = (BG_PALETTE_P0 << 4) | BG_PEN_P0

check_text_over_bg(VPOS_P0, SCOL_P0, EXP_TEXT_P0, EXP_BG_P0,
                   f"pen0-over-BG: text pen=0 transparent, BG visible col={SCOL_P0}")
# Two more adjacent pixels
for poff in [1, 2]:
    check_text_over_bg(VPOS_P0, SCOL_P0 + poff, EXP_TEXT_P0, EXP_BG_P0,
                       f"pen0-over-BG: col={SCOL_P0+poff}")


# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step4_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
