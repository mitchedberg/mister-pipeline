#!/usr/bin/env python3
"""
generate_step3_vectors.py — Step 3 test vector generator for tc0630fdp.

Produces step3_vectors.jsonl: BG tilemap layers (PF1–PF4), global scroll only.

Test groups:
  1. PF RAM write/readback (all 4 planes)
  2. Single solid-fill tile on PF1 — verify 16 pixels at known palette+pen
  3. Transparent pen 0 — verify pixel stored as palette|0
  4. Nibble order verification — verify px0..px15 decode correctly
  5. flipX — verify pixel order reversal within each 8-px fetch half
  6. flipY — verify correct tile row selection
  7. X scroll — shift by 16px, verify tile appears at expected screen columns
  8. Y scroll — verify correct tile row via yscroll
  9. Tile boundary — verify pixels straddle 16-px tile boundaries correctly
  10. Multiple PF planes independent — PF1 and PF2 with different tile content
  11. Python model cross-check — render_bg_scanline() vs RTL for 20 pixels

Addressing conventions:
  PF1 CPU addr base: 0x04000  (word address in chip window)
  PF2 CPU addr base: 0x06000
  PF3 CPU addr base: 0x08000
  PF4 CPU addr base: 0x0A000
  Ctrl regs: word address 0..15

  GFX ROM: written via write_gfx op (word address, 32-bit data).

  PF RAM word layout per tile:
    word_base = (tile_y * map_width + tile_x) * 2
    word_base+0 = attr word (palette, flipX, flipY)
    word_base+1 = tile code

  GFX ROM layout:
    tile_code * 32 + row * 2     = left-8px 32-bit word
    tile_code * 32 + row * 2 + 1 = right-8px 32-bit word
    Within word: bits[31:28]=px0, [27:24]=px1, ..., [3:0]=px7.
"""

import json
import os
from fdp_model import TaitoF3Model

vectors = []

def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
# CPU address bases
# ---------------------------------------------------------------------------
PF_BASE = [0x04000, 0x06000, 0x08000, 0x0A000]   # PF1–PF4 base word addresses

H_START  = 46
MAP_WIDTH_STD = 32    # tiles, standard mode (extend_mode=0)


# ---------------------------------------------------------------------------
# Helper: write ctrl register (e.g., scroll)
# word_addr 0–15; data 16-bit.
# ---------------------------------------------------------------------------
def write_ctrl(word_addr: int, data: int, note: str = ""):
    emit({"op": "write", "addr": word_addr, "data": data & 0xFFFF, "be": 3,
          "note": note or f"ctrl[{word_addr}] = {data:#06x}"})


# ---------------------------------------------------------------------------
# Helper: write PF RAM word (two words per tile: attr then code)
# plane: 0..3; word_idx: offset within PF RAM; data: 16-bit.
# ---------------------------------------------------------------------------
def write_pf(plane: int, word_idx: int, data: int, note: str = ""):
    cpu_addr = PF_BASE[plane] + word_idx
    emit({"op": "write_pf", "addr": cpu_addr, "data": data & 0xFFFF, "be": 3,
          "note": note or f"pf{plane+1}_ram[{word_idx:#06x}] = {data:#06x}"})


# ---------------------------------------------------------------------------
# Helper: write tile entry (attr + code) to PF RAM
# tile_x, tile_y: tile coordinates; map_width: tiles per row (32 or 64)
# attr: attribute word (palette, flipX, flipY, etc.)
# code: tile code (0..65535)
# ---------------------------------------------------------------------------
def write_tile(plane: int, tile_x: int, tile_y: int, attr: int, code: int,
               map_width: int = MAP_WIDTH_STD):
    tile_idx  = tile_y * map_width + tile_x
    word_base = tile_idx * 2
    write_pf(plane, word_base,     attr & 0xFFFF,
             f"pf{plane+1} tile({tile_x},{tile_y}) attr={attr:#06x}")
    write_pf(plane, word_base + 1, code & 0xFFFF,
             f"pf{plane+1} tile({tile_x},{tile_y}) code={code:#06x}")


# ---------------------------------------------------------------------------
# Helper: encode attribute word
# ---------------------------------------------------------------------------
def make_attr(palette: int, flipx: bool = False, flipy: bool = False,
              blend: bool = False, extra_planes: int = 0) -> int:
    val  = palette & 0x1FF
    val |= (1 << 9)  if blend        else 0
    val |= (extra_planes & 3) << 10
    val |= (1 << 14) if flipx        else 0
    val |= (1 << 15) if flipy        else 0
    return val


# ---------------------------------------------------------------------------
# Helper: encode a 32-bit GFX ROM word from 8 nibble pens.
# pens[0..7]: px0=bits[31:28], px1=bits[27:24], ..., px7=bits[3:0].
# ---------------------------------------------------------------------------
def encode_gfx_word(pens: list) -> int:
    assert len(pens) == 8
    val = 0
    for i, p in enumerate(pens):
        shift = (7 - i) * 4
        val |= ((p & 0xF) << shift)
    return val & 0xFFFFFFFF


# ---------------------------------------------------------------------------
# Helper: write one GFX ROM word
# ---------------------------------------------------------------------------
def write_gfx(word_addr: int, data: int, note: str = ""):
    emit({"op": "write_gfx",
          "gfx_addr": word_addr,
          "gfx_data": data & 0xFFFFFFFF,
          "note": note or f"gfx_rom[{word_addr:#06x}] = {data:#010x}"})


# ---------------------------------------------------------------------------
# Helper: write all 32 words for a tile's row (left + right for all 16 rows)
# Fills the entire tile with a uniform pen for all rows.
# ---------------------------------------------------------------------------
def write_tile_gfx_solid(tile_code: int, pen: int):
    """Write GFX ROM for tile_code, all rows, uniform pen."""
    word = encode_gfx_word([pen] * 8)
    for row in range(16):
        left_addr  = tile_code * 32 + row * 2
        right_addr = left_addr + 1
        write_gfx(left_addr,  word, f"gfx tile{tile_code} row{row} left  pen={pen}")
        write_gfx(right_addr, word, f"gfx tile{tile_code} row{row} right pen={pen}")


# ---------------------------------------------------------------------------
# Helper: write GFX for a specific row with known per-pixel pens (16 pixels)
# pens_left: list of 8 pens for pixels 0..7
# pens_right: list of 8 pens for pixels 8..15
# ---------------------------------------------------------------------------
def write_tile_row_gfx(tile_code: int, row: int, pens_left: list, pens_right: list):
    left_addr  = tile_code * 32 + row * 2
    right_addr = left_addr + 1
    write_gfx(left_addr,  encode_gfx_word(pens_left),
              f"gfx tile{tile_code} row{row} left  pens={pens_left}")
    write_gfx(right_addr, encode_gfx_word(pens_right),
              f"gfx tile{tile_code} row{row} right pens={pens_right}")


# ---------------------------------------------------------------------------
# Helper: check BG pixel at (vpos, screen_col) on given plane
# exp_pixel: 13-bit {palette[8:0], pen[3:0]}
# ---------------------------------------------------------------------------
def check_bg(vpos: int, screen_col: int, plane: int, exp_pixel: int, note: str):
    emit({"op": "check_bg_pixel",
          "vpos":       vpos,
          "screen_col": screen_col,
          "plane":      plane,
          "exp_pixel":  exp_pixel & 0x1FFF,
          "note":       note})


# ===========================================================================
# Setup: initial reset
# ===========================================================================
emit({"op": "reset", "note": "reset before step3 tests"})


# ===========================================================================
# Test group 1: PF RAM write/readback (all 4 planes)
# ===========================================================================
emit({"op": "reset", "note": "reset: PF RAM R/W test"})

PF_RW_CASES = [
    (0, 0,     0x1234, "PF1 word 0"),
    (0, 1,     0x5678, "PF1 word 1"),
    (1, 0,     0xABCD, "PF2 word 0"),
    (2, 0x100, 0x9999, "PF3 word 0x100"),
    (3, 0x17FE, 0xFFFF, "PF4 last attr word"),
    (3, 0x17FF, 0x1234, "PF4 last code word"),
]

for plane, word_idx, val, note in PF_RW_CASES:
    cpu_addr = PF_BASE[plane] + word_idx
    emit({"op": "write_pf", "addr": cpu_addr, "data": val, "be": 3,
          "note": f"write pf{plane+1}[{word_idx}] = {val:#06x}"})
    emit({"op": "read_pf", "addr": cpu_addr, "exp_dout": val,
          "note": f"readback pf{plane+1}[{word_idx}] == {val:#06x}: {note}"})


# ===========================================================================
# Test group 2: Solid-fill tile on PF1 — verify 16 pixels
# ===========================================================================
# Setup:
#   scroll = 0 (no scroll)
#   Tile (0,0) in PF1 RAM: palette=5, code=1
#   Tile code 1: all rows, all pens = 0xA
#   vpos=23 → fetch_vpos=24 → canvas_y=24 (yscroll=0)
#     fetch_py = 24 & 0xF = 8
#     fetch_ty = 24 >> 4  = 1
#   So we need a tile at tile_y=1, tile_x=0: tile_idx=1*32+0=32, word_base=64

emit({"op": "reset", "note": "reset: solid-fill tile test"})

VPOS_T2   = 23     # fetch_vpos=24, py=8, ty=1
FV_T2     = (VPOS_T2 + 1) & 0x1FF   # 24
FPY_T2    = FV_T2 & 0xF              # 8
FTY_T2    = (FV_T2 >> 4) & 0x1F     # 1
FTX_T2    = 0                        # screen col 0 → canvas_x=0 → tile_x=0
PALETTE_T2 = 5
CODE_T2   = 1
PEN_T2    = 0xA

# Set ctrl scroll registers to 0 (already 0 after reset, but be explicit)
write_ctrl(0, 0, "PF1 xscroll = 0")
write_ctrl(4, 0, "PF1 yscroll = 0")

# Write tile entry at (tile_x=0, tile_y=1)
write_tile(plane=0, tile_x=0, tile_y=1,
           attr=make_attr(PALETTE_T2), code=CODE_T2)

# Write all rows of tile code 1 with pen=PEN_T2
write_tile_gfx_solid(CODE_T2, PEN_T2)

exp_T2 = (PALETTE_T2 << 4) | PEN_T2
for px in range(16):
    check_bg(VPOS_T2, px, plane=0, exp_pixel=exp_T2,
             note=f"solid-fill pf1 px{px}: palette={PALETTE_T2} pen={PEN_T2:#x}")


# ===========================================================================
# Test group 3: Transparent pen 0
# ===========================================================================
# Pen 0 is transparent in compositing, but the BG engine writes the pixel
# with pen=0 anyway (compositing is not implemented yet in Step 3).
# Verify that the pixel has pen=0.
#   vpos=39 → fetch_vpos=40, py=8, ty=2
#   Tile (2,2) on PF1 with pen=0.

emit({"op": "reset", "note": "reset: transparent pen test"})

VPOS_T3   = 39
FV_T3     = (VPOS_T3 + 1) & 0x1FF   # 40
FPY_T3    = FV_T3 & 0xF              # 8
FTY_T3    = (FV_T3 >> 4) & 0x1F     # 2
PALETTE_T3 = 7
CODE_T3   = 3   # tile code 3

write_ctrl(0, 0, "PF1 xscroll=0 for transparent test")
write_ctrl(4, 0, "PF1 yscroll=0 for transparent test")

# Tile at (tile_x=2, tile_y=2): screen columns 32..47
write_tile(plane=0, tile_x=2, tile_y=2,
           attr=make_attr(PALETTE_T3), code=CODE_T3)

# All pens = 0
write_tile_gfx_solid(CODE_T3, 0)

exp_T3 = (PALETTE_T3 << 4) | 0   # pen=0, palette preserved
for px in range(8):
    check_bg(VPOS_T3, 32 + px, plane=0, exp_pixel=exp_T3,
             note=f"pen=0 pf1 screen_col={32+px}: palette={PALETTE_T3}")


# ===========================================================================
# Test group 4: Nibble order — px0..px15 with distinct pens
# ===========================================================================
# Use 16 distinct pens (1..15 + back to 0 for px15? No: 1..14 then cycle).
# Actually use pens 1..15 for px0..px14, pen=0 for px15 (to test boundary).
#   vpos=55 → fetch_vpos=56, py=8, ty=3; tile at (0,3), code=5

emit({"op": "reset", "note": "reset: nibble order test"})

VPOS_T4   = 55
FV_T4     = (VPOS_T4 + 1) & 0x1FF   # 56
FPY_T4    = FV_T4 & 0xF              # 8
FTY_T4    = (FV_T4 >> 4) & 0x1F     # 3
PALETTE_T4 = 2
CODE_T4   = 5

PENS_T4 = [(i + 1) & 0xF for i in range(16)]   # [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,0]

write_ctrl(0, 0, "PF1 xscroll=0 for nibble-order test")
write_ctrl(4, 0, "PF1 yscroll=0 for nibble-order test")
write_tile(plane=0, tile_x=0, tile_y=3, attr=make_attr(PALETTE_T4), code=CODE_T4)

# Write only the specific row (FPY_T4 = 8) with known pens; other rows 0
write_tile_row_gfx(CODE_T4, FPY_T4,
                   pens_left=PENS_T4[:8], pens_right=PENS_T4[8:])

for px in range(16):
    exp = (PALETTE_T4 << 4) | PENS_T4[px]
    check_bg(VPOS_T4, px, plane=0, exp_pixel=exp,
             note=f"nibble-order px{px}: exp pen={PENS_T4[px]:#x}")


# ===========================================================================
# Test group 5: flipX
# ===========================================================================
# Tile with flipX=1: px0 should come from nibble 7 (rightmost) of left word.
# Same pens as T4 but flipped: px0 = pen[7], px1 = pen[6], ..., px15 = pen[0].
#   (where pen[i] = left pens [0..7] and right pens [8..15] for normal order)
# Expected output for screen col 0 = pen[7] = PENS_T4[7] = 8.
#   vpos=71 → fetch_vpos=72, py=8, ty=4

emit({"op": "reset", "note": "reset: flipX test"})

VPOS_T5   = 71
FV_T5     = (VPOS_T5 + 1) & 0x1FF   # 72
FPY_T5    = FV_T5 & 0xF              # 8
FTY_T5    = (FV_T5 >> 4) & 0x1F     # 4
PALETTE_T5 = 3
CODE_T5   = 7

write_ctrl(0, 0, "PF1 xscroll=0 for flipX test")
write_ctrl(4, 0, "PF1 yscroll=0 for flipX test")
# Tile with flipX=True
write_tile(plane=0, tile_x=0, tile_y=4,
           attr=make_attr(PALETTE_T5, flipx=True), code=CODE_T5)

# Write same pens as T4 for this tile
write_tile_row_gfx(CODE_T5, FPY_T5,
                   pens_left=PENS_T4[:8], pens_right=PENS_T4[8:])

# With flipX, screen px0 = tile pixel 7 (nibble index 7 → from left word reversed)
# flipX in left half:  ni = 7 - (px & 7) → px0 → ni=7 → pen[7]=8
#                      px1 → ni=6 → pen[6]=7, ..., px7 → ni=0 → pen[0]=1
# flipX in right half: px8 → ni=7 → pen[15]=0, px9 → ni=6 → pen[14]=15, ...
#                      Actually: right word: px8→ni=7→right_word nibble7=PENS_T4[15]=0
#                                           px9→ni=6→PENS_T4[14]=15, etc.
pens_flipped = []
for px in range(16):
    ni = 7 - (px & 7)
    if px < 8:
        pens_flipped.append(PENS_T4[ni])       # from left word
    else:
        pens_flipped.append(PENS_T4[8 + ni])   # from right word

for px in range(16):
    exp = (PALETTE_T5 << 4) | pens_flipped[px]
    check_bg(VPOS_T5, px, plane=0, exp_pixel=exp,
             note=f"flipX px{px}: exp pen={pens_flipped[px]:#x}")


# ===========================================================================
# Test group 6: flipY
# ===========================================================================
# Tile with flipY=1: row = 15 - fetch_py.
# We'll write distinct pens for two different rows and verify row selection.
# fetch_py = 8 (for vpos=71..79 range), but with flipY: reads row 15-8=7.
# Write row 7 of tile with uniform pen=0xC, row 8 with pen=0x3.
# Without flipY: expect pen=0x3. With flipY: expect pen=0xC.
#   vpos=71 same as T5 (py=8); reuse vpos.

emit({"op": "reset", "note": "reset: flipY test"})

PALETTE_T6 = 4
CODE_T6A   = 9   # no-flipY tile
CODE_T6B   = 10  # flipY tile

PEN_ROW7  = 0xC  # pen for row 7
PEN_ROW8  = 0x3  # pen for row 8

write_ctrl(0, 0, "PF1 xscroll=0 for flipY test")
write_ctrl(4, 0, "PF1 yscroll=0 for flipY test")

# Tile A: no flip — should read row 8
write_tile(plane=0, tile_x=0, tile_y=4, attr=make_attr(PALETTE_T6, flipy=False), code=CODE_T6A)
# Tile B: flipY — should read row 7
write_tile(plane=0, tile_x=2, tile_y=4, attr=make_attr(PALETTE_T6, flipy=True),  code=CODE_T6B)

# Write rows 7 and 8 for both tile codes
for code in (CODE_T6A, CODE_T6B):
    write_tile_row_gfx(code, 7,  [PEN_ROW7] * 8, [PEN_ROW7] * 8)
    write_tile_row_gfx(code, 8,  [PEN_ROW8] * 8, [PEN_ROW8] * 8)

# Tile A (no flip): reads row 8 → pen = PEN_ROW8
exp_nf = (PALETTE_T6 << 4) | PEN_ROW8
check_bg(VPOS_T5, 0, plane=0, exp_pixel=exp_nf,
         note=f"flipY=0: tile reads row {FPY_T5} → pen={PEN_ROW8:#x}")

# Tile B (flipY): reads row 15-8=7 → pen = PEN_ROW7
exp_fy = (PALETTE_T6 << 4) | PEN_ROW7
check_bg(VPOS_T5, 32, plane=0, exp_pixel=exp_fy,
         note=f"flipY=1: tile reads row {15-FPY_T5} → pen={PEN_ROW7:#x}")


# ===========================================================================
# Test group 7: X scroll
# ===========================================================================
# Set PF1_XSCROLL so that canvas_x at screen col 0 = 16 (shift one tile right).
# xscroll raw = 16 << 6 = 0x0400  (pf_xscroll[15:6] = 16).
# With xscroll=16: canvas_x at screen 0 = 16 → tile_x=1 of the tilemap.
# So tile at map (1, ty) should appear at screen col 0..15.
# And tile at map (0, ty) should appear at screen col ... 496..511 (off-screen left).
#   vpos=87 → fetch_vpos=88, py=8, ty=5

emit({"op": "reset", "note": "reset: X scroll test"})

VPOS_T7   = 87
FV_T7     = (VPOS_T7 + 1) & 0x1FF   # 88
FPY_T7    = FV_T7 & 0xF              # 8
FTY_T7    = (FV_T7 >> 4) & 0x1F     # 5

XSCROLL_T7 = 16                      # integer pixel offset
XSCROLL_REG = (XSCROLL_T7 << 6) & 0xFFFF   # = 0x0400

PALETTE_T7A = 8   # tile at map_x=0
PALETTE_T7B = 9   # tile at map_x=1
CODE_T7A   = 11
CODE_T7B   = 12
PEN_T7A    = 0xE
PEN_T7B    = 0x5

write_ctrl(0, XSCROLL_REG, f"PF1 xscroll = {XSCROLL_T7} px (reg={XSCROLL_REG:#06x})")
write_ctrl(4, 0, "PF1 yscroll=0 for X scroll test")

# Tile at (map_x=0, map_y=5) and (map_x=1, map_y=5)
write_tile(plane=0, tile_x=0, tile_y=5, attr=make_attr(PALETTE_T7A), code=CODE_T7A)
write_tile(plane=0, tile_x=1, tile_y=5, attr=make_attr(PALETTE_T7B), code=CODE_T7B)
write_tile_gfx_solid(CODE_T7A, PEN_T7A)
write_tile_gfx_solid(CODE_T7B, PEN_T7B)

# With xscroll=16: canvas_x at screen 0 = 16 → within tile_x=1, pixel offset 0.
# So screen cols 0..15 should show tile_x=1 pixels.
exp_T7B = (PALETTE_T7B << 4) | PEN_T7B
for px in range(8):   # check first 8 pixels of tile_x=1
    check_bg(VPOS_T7, px, plane=0, exp_pixel=exp_T7B,
             note=f"xscroll={XSCROLL_T7}: screen{px} → tile_x=1 pen={PEN_T7B:#x}")


# ===========================================================================
# Test group 8: Y scroll
# ===========================================================================
# Set PF1_YSCROLL so that the effective tile row changes.
# Normal (yscroll=0): vpos=87 → canvas_y=88 → ty=5.
# With yscroll=16 (one tile down): canvas_y = 88+16 = 104 → ty=6.
# So tile at map_ty=6 should appear.
#   yscroll raw = 16 << 7 = 0x0800

emit({"op": "reset", "note": "reset: Y scroll test"})

YSCROLL_T8 = 16
YSCROLL_REG = (YSCROLL_T8 << 7) & 0xFFFF   # = 0x0800

PALETTE_T8_5 = 0x10   # tile at ty=5 (5 × 16 = 80 is the Y base)
PALETTE_T8_6 = 0x11   # tile at ty=6
CODE_T8_5    = 14
CODE_T8_6    = 15
PEN_T8_5     = 0x1
PEN_T8_6     = 0x2

write_ctrl(0, 0,            "PF1 xscroll=0 for Y scroll test")
write_ctrl(4, YSCROLL_REG,  f"PF1 yscroll={YSCROLL_T8} px (reg={YSCROLL_REG:#06x})")

write_tile(plane=0, tile_x=0, tile_y=5, attr=make_attr(PALETTE_T8_5), code=CODE_T8_5)
write_tile(plane=0, tile_x=0, tile_y=6, attr=make_attr(PALETTE_T8_6), code=CODE_T8_6)
write_tile_gfx_solid(CODE_T8_5, PEN_T8_5)
write_tile_gfx_solid(CODE_T8_6, PEN_T8_6)

# vpos=87: canvas_y = 88 + 16 = 104; ty=6, py=8.
# Screen col 0 should show tile at (0,6) with pen=PEN_T8_6.
exp_T8 = (PALETTE_T8_6 << 4) | PEN_T8_6
check_bg(VPOS_T7, 0, plane=0, exp_pixel=exp_T8,
         note=f"yscroll={YSCROLL_T8}: screen0 → tile_ty=6 pen={PEN_T8_6:#x}")


# ===========================================================================
# Test group 9: Tile boundary (pixel straddles 16-px boundary)
# ===========================================================================
# Two adjacent tiles: tile_x=3 (screen cols 48..63) and tile_x=4 (cols 64..79).
# No scroll.
#   vpos=103 → fetch_vpos=104, py=8, ty=6

emit({"op": "reset", "note": "reset: tile boundary test"})

VPOS_T9   = 103
FV_T9     = (VPOS_T9 + 1) & 0x1FF   # 104
FPY_T9    = FV_T9 & 0xF              # 8
FTY_T9    = (FV_T9 >> 4) & 0x1F     # 6

PALETTE_T9A = 0x12
PALETTE_T9B = 0x13
CODE_T9A   = 16
CODE_T9B   = 17
PEN_T9A    = 0x7
PEN_T9B    = 0xD

write_ctrl(0, 0, "PF1 xscroll=0 for boundary test")
write_ctrl(4, 0, "PF1 yscroll=0 for boundary test")

write_tile(plane=0, tile_x=3, tile_y=6, attr=make_attr(PALETTE_T9A), code=CODE_T9A)
write_tile(plane=0, tile_x=4, tile_y=6, attr=make_attr(PALETTE_T9B), code=CODE_T9B)
write_tile_gfx_solid(CODE_T9A, PEN_T9A)
write_tile_gfx_solid(CODE_T9B, PEN_T9B)

# Last pixel of tile 3: screen_col = 63
check_bg(VPOS_T9, 63, plane=0, exp_pixel=(PALETTE_T9A << 4) | PEN_T9A,
         note=f"boundary: last px of tile_x=3 (scol=63) pen={PEN_T9A:#x}")
# First pixel of tile 4: screen_col = 64
check_bg(VPOS_T9, 64, plane=0, exp_pixel=(PALETTE_T9B << 4) | PEN_T9B,
         note=f"boundary: first px of tile_x=4 (scol=64) pen={PEN_T9B:#x}")


# ===========================================================================
# Test group 10: Multiple PF planes independent
# ===========================================================================
# PF1 and PF2 with different tile content at the same screen position.
# Verify each plane produces its own independent pixel.
#   vpos=119 → fetch_vpos=120, py=8, ty=7

emit({"op": "reset", "note": "reset: multi-plane independence test"})

VPOS_T10  = 119
FTY_T10   = ((VPOS_T10 + 1) >> 4) & 0x1F   # 7

PALETTE_P1 = 0x01A
PALETTE_P2 = 0x01B
CODE_P1    = 18
CODE_P2    = 19
PEN_P1     = 0xF
PEN_P2     = 0x6

write_ctrl(0, 0, "PF1 xscroll=0 multi-plane")
write_ctrl(4, 0, "PF1 yscroll=0 multi-plane")
write_ctrl(1, 0, "PF2 xscroll=0 multi-plane")
write_ctrl(5, 0, "PF2 yscroll=0 multi-plane")

write_tile(plane=0, tile_x=0, tile_y=7, attr=make_attr(PALETTE_P1), code=CODE_P1)
write_tile(plane=1, tile_x=0, tile_y=7, attr=make_attr(PALETTE_P2), code=CODE_P2)
write_tile_gfx_solid(CODE_P1, PEN_P1)
write_tile_gfx_solid(CODE_P2, PEN_P2)

# Both planes cover screen cols 0..15
for px in range(4):
    check_bg(VPOS_T10, px, plane=0, exp_pixel=(PALETTE_P1 << 4) | PEN_P1,
             note=f"plane0 independent px{px}")
    check_bg(VPOS_T10, px, plane=1, exp_pixel=(PALETTE_P2 << 4) | PEN_P2,
             note=f"plane1 independent px{px}")


# ===========================================================================
# Test group 11: Model cross-check — render_bg_scanline() vs RTL
# ===========================================================================
# Build a known state with a 2-tile-wide checkerboard pattern on PF1.
# Use the Python model to compute expected pixels, then check 20 representative
# screen columns against the RTL output.
#   vpos=135 → fetch_vpos=136, py=8, ty=8

emit({"op": "reset", "note": "reset: model cross-check"})

VPOS_MC   = 135
FV_MC     = (VPOS_MC + 1) & 0x1FF   # 136
FPY_MC    = FV_MC & 0xF              # 8
FTY_MC    = (FV_MC >> 4) & 0x1F     # 8

XSCROLL_MC = 0
YSCROLL_MC = 0

m = TaitoF3Model()

# Checkerboard: even tile_x → code=20 (pen 0x5), odd tile_x → code=21 (pen 0xA)
CODE_EVEN_MC = 20
CODE_ODD_MC  = 21
PAL_EVEN_MC  = 0x050
PAL_ODD_MC   = 0x051
PEN_EVEN_MC  = 5
PEN_ODD_MC   = 10

write_ctrl(0, XSCROLL_MC, "PF1 xscroll=0 model-check")
write_ctrl(4, YSCROLL_MC, "PF1 yscroll=0 model-check")

# Write GFX ROM for codes 20 and 21 (only need row FPY_MC=8)
write_tile_row_gfx(CODE_EVEN_MC, FPY_MC, [PEN_EVEN_MC]*8, [PEN_EVEN_MC]*8)
write_tile_row_gfx(CODE_ODD_MC,  FPY_MC, [PEN_ODD_MC]*8,  [PEN_ODD_MC]*8)

m.write_gfx_rom(CODE_EVEN_MC * 32 + FPY_MC * 2,     CODE_EVEN_MC * 32 + FPY_MC * 2)
# We need to also update model's gfx_rom
gfx_word_even = encode_gfx_word([PEN_EVEN_MC]*8)
gfx_word_odd  = encode_gfx_word([PEN_ODD_MC]*8)
for tile_code, gfx_word, pal, code in [(CODE_EVEN_MC, gfx_word_even, PAL_EVEN_MC, CODE_EVEN_MC),
                                        (CODE_ODD_MC,  gfx_word_odd,  PAL_ODD_MC,  CODE_ODD_MC)]:
    m.write_gfx_rom(code * 32 + FPY_MC * 2,     gfx_word)
    m.write_gfx_rom(code * 32 + FPY_MC * 2 + 1, gfx_word)

# Write all 32 tile columns in row 8 of PF1 tilemap
for tx in range(32):
    if tx % 2 == 0:
        attr = make_attr(PAL_EVEN_MC)
        code = CODE_EVEN_MC
    else:
        attr = make_attr(PAL_ODD_MC)
        code = CODE_ODD_MC
    write_tile(plane=0, tile_x=tx, tile_y=8, attr=attr, code=code)
    m.write_pf_ram(0, (8 * 32 + tx) * 2,     attr)
    m.write_pf_ram(0, (8 * 32 + tx) * 2 + 1, code)

# Get Python model expected scanline
expected = m.render_bg_scanline(VPOS_MC, plane=0,
                                xscroll=XSCROLL_MC, yscroll=YSCROLL_MC,
                                extend_mode=False)

# Check 20 representative pixels (every 16 columns)
for scol in range(0, 320, 16):
    exp_px = expected[scol]
    check_bg(VPOS_MC, scol, plane=0, exp_pixel=exp_px,
             note=f"model-check: scol={scol} exp={exp_px:#06x}")


# ===========================================================================
# Test group 12: Scroll wrap-around
# ===========================================================================
# Set xscroll so canvas_x = 512 - 8 (last 8 pixels of last tile row wrap).
# Tile (31, ty) should appear at screen cols 0..7 and tile (0, ty) at 8..15.
#   vpos=143 → fetch_vpos=144, py=0, ty=9

emit({"op": "reset", "note": "reset: scroll wrap-around test"})

VPOS_T12  = 143
FV_T12    = (VPOS_T12 + 1) & 0x1FF   # 144
FPY_T12   = FV_T12 & 0xF              # 0
FTY_T12   = (FV_T12 >> 4) & 0x1F     # 9

# xscroll = 512 - 8 = 504 pixels → canvas_x at screen 0 = 504
# tile_x = 504 // 16 = 31; xoff within tile = 504 & 15 = 8
# So screen col 0 maps to tile 31, pixel 8; screen col 8 maps to tile 0, pixel 0.
XSCROLL_T12 = 504
XSCROLL_REG12 = (XSCROLL_T12 << 6) & 0xFFFF

PALETTE_T12_0  = 0x1C
PALETTE_T12_31 = 0x1D
CODE_T12_0     = 22
CODE_T12_31    = 23
PEN_T12_0      = 0x4
PEN_T12_31     = 0xB

write_ctrl(0, XSCROLL_REG12, f"PF1 xscroll={XSCROLL_T12} (wrap test)")
write_ctrl(4, 0, "PF1 yscroll=0 for wrap test")

write_tile(plane=0, tile_x=0,  tile_y=9, attr=make_attr(PALETTE_T12_0),  code=CODE_T12_0)
write_tile(plane=0, tile_x=31, tile_y=9, attr=make_attr(PALETTE_T12_31), code=CODE_T12_31)
write_tile_gfx_solid(CODE_T12_0,  PEN_T12_0)
write_tile_gfx_solid(CODE_T12_31, PEN_T12_31)

# Screen cols 0..7: canvas_x = 504..511 → tile_x=31, right half
exp_wrap_31 = (PALETTE_T12_31 << 4) | PEN_T12_31
check_bg(VPOS_T12, 0, plane=0, exp_pixel=exp_wrap_31,
         note=f"wrap: scol=0 → tile_x=31 pen={PEN_T12_31:#x}")
check_bg(VPOS_T12, 7, plane=0, exp_pixel=exp_wrap_31,
         note=f"wrap: scol=7 → tile_x=31 pen={PEN_T12_31:#x}")

# Screen col 8: canvas_x = 512 → wraps to 0 → tile_x=0, pixel 0
exp_wrap_0 = (PALETTE_T12_0 << 4) | PEN_T12_0
check_bg(VPOS_T12, 8, plane=0, exp_pixel=exp_wrap_0,
         note=f"wrap: scol=8 → tile_x=0 (wrap) pen={PEN_T12_0:#x}")


# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "step3_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
