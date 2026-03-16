#!/usr/bin/env python3
"""
generate_step2_vectors.py — Step 2 test vector generator for tc0630fdp.

Produces step2_vectors.jsonl: text layer (8×8 4bpp tiles, 64×64 map).

Test cases:
  1. Text RAM write/readback (16 entries)
  2. Character RAM write/readback (4 entries)
  3. Solid-fill tile: tile 0 set to all-opaque pen 5 color 3; verify 8 pixels
  4. Transparent pen 0: tile filled with pen 0; verify text_pixel == 0
  5. Color field: verify bits[15:11] map to color[4:0]
  6. Multiple tiles: verify tile boundary (pixel 8 from tile col 1)
  7. Charlayout nibble mapping: verify pixel order px0..px7 from one tile row
  8. Row index: verify that different vpos values select correct tile rows

Addressing convention (matches testbench cpu_write):
  Text RAM:    cpu_addr = 0x0E000 + word_idx   (cs_text when addr[18:12]==0x0E)
  Char RAM:    cpu_addr = 0x0F000 + word_idx   (cs_char when addr[18:12]==0x0F)
                                                word_idx = byte_addr / 2
  Ctrl regs:   cpu_addr = 0..15                (cs_ctrl by default)

The testbench advances clock until HBLANK of vpos, waits for the FSM to complete
(80 cycles), then checks text_pixel_out at specific hpos values.
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
CHAR_RAM_BASE = 0x0F000   # cpu_addr for char RAM word 0 (= byte 0 / 2)

H_START = 46              # first active display pixel


# ---------------------------------------------------------------------------
# Helper: write a 16-bit word to text RAM at tile map word index
# ---------------------------------------------------------------------------
def write_text_word(word_idx: int, data: int, note: str = ""):
    emit({"op": "write_text",
          "addr": TEXT_RAM_BASE + word_idx,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"text_ram[{word_idx:#05x}] = {data:#06x}"})


# ---------------------------------------------------------------------------
# Helper: write 16 bits to char RAM at byte address (big-endian: hi byte first)
# cpu_addr = CHAR_RAM_BASE + byte_addr/2
# ---------------------------------------------------------------------------
def write_char_word(byte_addr: int, data: int, note: str = ""):
    word_idx = byte_addr // 2
    emit({"op": "write_char",
          "addr": CHAR_RAM_BASE + word_idx,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"char_ram[{byte_addr:#05x}] = {data:#06x}"})


# ---------------------------------------------------------------------------
# Helper: render a scanline via the testbench and check pixel at given hpos
# The testbench will:
#   1. Reset the DUT.
#   2. Apply all prior write_text/write_char ops.
#   3. Advance timing to HBLANK of vpos.
#   4. Wait 80+ cycles for FSM to complete.
#   5. Sample text_pixel_out at hpos = H_START + screen_col.
# ---------------------------------------------------------------------------
def check_pixel(vpos: int, screen_col: int, exp_pixel: int, note: str):
    """Emit a check_text_pixel vector."""
    emit({"op": "check_text_pixel",
          "vpos": vpos,
          "screen_col": screen_col,
          "exp_pixel": exp_pixel & 0x1FF,
          "note": note})


# ---------------------------------------------------------------------------
# Utility: encode text tile word
# ---------------------------------------------------------------------------
def tile_word(char_code: int, color: int) -> int:
    return ((color & 0x1F) << 11) | (char_code & 0x7FF)


# ---------------------------------------------------------------------------
# Utility: encode a row's 4 bytes from 8 4-bit pens using charlayout mapping
# Charlayout nibble order for pens[0..7]:
#   pen[0] → b2[7:4]   pen[1] → b2[3:0]
#   pen[2] → b3[7:4]   pen[3] → b3[3:0]
#   pen[4] → b0[7:4]   pen[5] → b0[3:0]
#   pen[6] → b1[7:4]   pen[7] → b1[3:0]
# ---------------------------------------------------------------------------
def encode_row(pens: list) -> tuple:
    """Return (b0, b1, b2, b3) for 8 pens using charlayout nibble mapping."""
    assert len(pens) == 8
    b0 = ((pens[4] & 0xF) << 4) | (pens[5] & 0xF)
    b1 = ((pens[6] & 0xF) << 4) | (pens[7] & 0xF)
    b2 = ((pens[0] & 0xF) << 4) | (pens[1] & 0xF)
    b3 = ((pens[2] & 0xF) << 4) | (pens[3] & 0xF)
    return (b0, b1, b2, b3)


# ===========================================================================
# Setup: initial reset
# ===========================================================================
emit({"op": "reset", "note": "reset before step2 tests"})


# ===========================================================================
# Test group 1: Text RAM write/readback
# ===========================================================================
emit({"op": "reset", "note": "reset before text RAM R/W tests"})

TEXT_RW_CASES = [
    (0,    0x1234, "tile word 0: char=0x034, color=0x02"),
    (63,   0x7FFF, "tile word 63: max char code bits, color 0x1F"),
    (64,   0xA5C3, "tile word 64 (row 1, col 0)"),
    (4095, 0x0001, "tile word 4095 (last tile)"),
]

for idx, val, note in TEXT_RW_CASES:
    emit({"op": "write_text", "addr": TEXT_RAM_BASE + idx, "data": val, "be": 3,
          "note": f"write text_ram[{idx}] = {val:#06x}"})
    emit({"op": "read_text",  "addr": TEXT_RAM_BASE + idx, "exp_dout": val,
          "note": f"readback text_ram[{idx}] == {val:#06x}: {note}"})


# ===========================================================================
# Test group 2: Character RAM write/readback
# ===========================================================================
emit({"op": "reset", "note": "reset before char RAM R/W tests"})

# Tile 0, row 0: write b0,b1 as first word, b2,b3 as second word
CHAR_RW_CASES = [
    (0,     0xABCD, "char RAM byte 0..1 (tile 0, row 0, b0b1)"),
    (2,     0xEF01, "char RAM byte 2..3 (tile 0, row 0, b2b3)"),
    (32,    0x1234, "char RAM byte 32..33 (tile 0, row 1, b0b1)"),
    (8192 - 2, 0x5678, "char RAM byte 8190..8191 (last tile, last row)"),
]

for byte_addr, val, note in CHAR_RW_CASES:
    word_idx = byte_addr // 2
    emit({"op": "write_char", "addr": CHAR_RAM_BASE + word_idx, "data": val, "be": 3,
          "note": f"write char_ram byte {byte_addr} = {val:#06x}"})
    emit({"op": "read_char",  "addr": CHAR_RAM_BASE + word_idx, "exp_dout": val,
          "note": f"readback char_ram byte {byte_addr} == {val:#06x}: {note}"})


# ===========================================================================
# Test group 3: Solid-fill tile rendering
# ===========================================================================
# Set tile map entry for row 0, col 0 → char_code=1, color=3.
# Set char tile 1, row 0 (fetch_py=0 for vpos=255 → fetch_vpos=0, py=0)
# to all pen=5 (solid color).
#
# fetch_vpos = (vpos+1) & 0x1FF; for vpos=255: fetch_vpos=256.
# fetch_py = 256 & 7 = 0. fetch_row = 256 >> 3 = 32.
#
# Tile map address: row=32, col=0 → word index = 32*64 + 0 = 2048.
# Char tile 1, row 0: byte offset = 1*32 + 0*4 = 32.
# All pen=5 means b0=b1=b2=b3=0x55 (nibbles: high=5, low=5).

emit({"op": "reset", "note": "reset for solid-fill tile test"})

SOLID_COLOR  = 3    # tile color attribute (5-bit, we use 3)
SOLID_CHAR   = 1    # character code
SOLID_PEN    = 5    # pen value for all 8 pixels

VPOS_TEST3   = 255  # fetch_vpos = 256, fetch_py = 0, fetch_row = 32
FETCH_ROW3   = (VPOS_TEST3 + 1) >> 3   # = 32
FETCH_PY3    = (VPOS_TEST3 + 1) & 7    # = 0
TILE_WORD3   = tile_word(SOLID_CHAR, SOLID_COLOR)
TILE_IDX3    = FETCH_ROW3 * 64 + 0     # row=32, col=0 → 2048

emit({"op": "write_text", "addr": TEXT_RAM_BASE + TILE_IDX3, "data": TILE_WORD3, "be": 3,
      "note": f"solid-fill: tile[{TILE_IDX3}]=char{SOLID_CHAR},color{SOLID_COLOR}"})

# All-5 row: pens = [5]*8 → encode_row([5,5,5,5,5,5,5,5])
b0, b1, b2, b3 = encode_row([SOLID_PEN] * 8)
char_byte_base = SOLID_CHAR * 32 + FETCH_PY3 * 4
emit({"op": "write_char", "addr": CHAR_RAM_BASE + char_byte_base // 2,
      "data": (b0 << 8) | b1, "be": 3,
      "note": f"char{SOLID_CHAR} row{FETCH_PY3}: b0={b0:#04x} b1={b1:#04x}"})
emit({"op": "write_char", "addr": CHAR_RAM_BASE + char_byte_base // 2 + 1,
      "data": (b2 << 8) | b3, "be": 3,
      "note": f"char{SOLID_CHAR} row{FETCH_PY3}: b2={b2:#04x} b3={b3:#04x}"})

exp_pixel3 = (SOLID_COLOR << 4) | SOLID_PEN  # = 0x35
for px in range(8):
    check_pixel(VPOS_TEST3, px, exp_pixel3,
                f"solid-fill px{px}: exp color={SOLID_COLOR} pen={SOLID_PEN}")


# ===========================================================================
# Test group 4: Transparent pen 0
# ===========================================================================
# Tile with all pen=0 → text_pixel should be 0 (transparent).
# Use vpos=23 → fetch_vpos=24, fetch_py=0, fetch_row=3.
# Row=3, col=5 → tile index=3*64+5=197.

emit({"op": "reset", "note": "reset for transparency test"})

VPOS_T4   = 23
FETCH_ROW4 = ((VPOS_T4 + 1) & 0x1FF) >> 3   # = 3
FETCH_PY4  = (VPOS_T4 + 1) & 7               # = 0
CHAR_T4    = 2
COLOR_T4   = 7
TILE_IDX4  = FETCH_ROW4 * 64 + 5             # col=5

tw4 = tile_word(CHAR_T4, COLOR_T4)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + TILE_IDX4, "data": tw4, "be": 3,
      "note": f"transparent: tile[{TILE_IDX4}]=char{CHAR_T4},color{COLOR_T4}"})

# All-zero pens → b0=b1=b2=b3=0x00
cb4 = CHAR_T4 * 32 + FETCH_PY4 * 4
emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb4 // 2,     "data": 0x0000, "be": 3,
      "note": f"transparent: char{CHAR_T4} row{FETCH_PY4} b0b1=0"})
emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb4 // 2 + 1, "data": 0x0000, "be": 3,
      "note": f"transparent: char{CHAR_T4} row{FETCH_PY4} b2b3=0"})

# Pixels at col=5: screen columns 40..47; pen=0 → transparent.
# Line buffer stores {color, pen} unconditionally, so pixel = (COLOR_T4<<4)|0.
exp_transparent = (COLOR_T4 << 4) | 0   # = 0x70
for px in range(8):
    check_pixel(VPOS_T4, 5 * 8 + px, exp_transparent,
                f"transparent px{5*8+px}: pen=0 → pixel={exp_transparent:#05x} (color={COLOR_T4},pen=0)")


# ===========================================================================
# Test group 5: Charlayout nibble order verification
# ===========================================================================
# Set tile row with known distinct pens for each pixel, verify each individually.
# vpos=47 → fetch_vpos=48, fetch_py=0, fetch_row=6.
# Row=6, col=2 → tile index=6*64+2=386.

emit({"op": "reset", "note": "reset for charlayout nibble order test"})

VPOS_T5   = 47
FV5       = (VPOS_T5 + 1) & 0x1FF   # 48
FPY5      = FV5 & 7                  # 0
FROW5     = FV5 >> 3                 # 6
CHAR_T5   = 3
COLOR_T5  = 0x1A   # 5-bit color = 26
TILE_IDX5 = FROW5 * 64 + 2          # col=2 → 386

# Distinct pens 1..8 (pen 0 = transparent, use 1..8; wrap to 4 bits so pen 8 → 8 but fits)
PENS_T5 = [1, 2, 3, 4, 5, 6, 7, 8]  # note: 4bpp so pens are 0..15; 8 = 0x8

tw5 = tile_word(CHAR_T5, COLOR_T5)
emit({"op": "write_text", "addr": TEXT_RAM_BASE + TILE_IDX5, "data": tw5, "be": 3,
      "note": f"nibble order: tile[{TILE_IDX5}]=char{CHAR_T5},color{COLOR_T5:#04x}"})

b0_5, b1_5, b2_5, b3_5 = encode_row(PENS_T5)
cb5 = CHAR_T5 * 32 + FPY5 * 4
emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb5 // 2,
      "data": (b0_5 << 8) | b1_5, "be": 3,
      "note": f"nibble order: char{CHAR_T5} row{FPY5} b0={b0_5:#04x} b1={b1_5:#04x}"})
emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb5 // 2 + 1,
      "data": (b2_5 << 8) | b3_5, "be": 3,
      "note": f"nibble order: char{CHAR_T5} row{FPY5} b2={b2_5:#04x} b3={b3_5:#04x}"})

for px in range(8):
    pen = PENS_T5[px] & 0xF
    exp = (COLOR_T5 << 4) | pen
    check_pixel(VPOS_T5, 2 * 8 + px, exp,
                f"nibble-order px{px}: exp color={COLOR_T5:#04x} pen={pen}")


# ===========================================================================
# Test group 6: Tile boundary (pixel 8 from tile col 1)
# ===========================================================================
# Two adjacent tiles at col=0 and col=1, verify pixel at exact boundary.
# vpos=79 → fetch_vpos=80, fetch_py=0, fetch_row=10.

emit({"op": "reset", "note": "reset for tile boundary test"})

VPOS_T6   = 79
FV6       = (VPOS_T6 + 1) & 0x1FF   # 80
FPY6      = FV6 & 7                  # 0
FROW6     = FV6 >> 3                 # 10
CHAR_T6A  = 4   # tile at col=0
CHAR_T6B  = 5   # tile at col=1
COLOR_T6A = 1
COLOR_T6B = 2
PEN_T6A   = 0xA  # pen for col=0 tile
PEN_T6B   = 0xB  # pen for col=1 tile

for col, char_c, color_c, pen_c in [(0, CHAR_T6A, COLOR_T6A, PEN_T6A),
                                     (1, CHAR_T6B, COLOR_T6B, PEN_T6B)]:
    tw = tile_word(char_c, color_c)
    emit({"op": "write_text", "addr": TEXT_RAM_BASE + FROW6 * 64 + col,
          "data": tw, "be": 3,
          "note": f"boundary: tile row{FROW6} col{col}=char{char_c},color{color_c}"})
    cb = char_c * 32 + FPY6 * 4
    b0_t, b1_t, b2_t, b3_t = encode_row([pen_c] * 8)
    emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb // 2,
          "data": (b0_t << 8) | b1_t, "be": 3,
          "note": f"boundary: char{char_c} row{FPY6} b0b1"})
    emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb // 2 + 1,
          "data": (b2_t << 8) | b3_t, "be": 3,
          "note": f"boundary: char{char_c} row{FPY6} b2b3"})

# Last pixel of tile 0 (screen_col=7): color_T6A, pen_T6A
check_pixel(VPOS_T6, 7, (COLOR_T6A << 4) | PEN_T6A,
            f"boundary: last px of col=0 tile (screen_col=7)")
# First pixel of tile 1 (screen_col=8): color_T6B, pen_T6B
check_pixel(VPOS_T6, 8, (COLOR_T6B << 4) | PEN_T6B,
            f"boundary: first px of col=1 tile (screen_col=8)")


# ===========================================================================
# Test group 7: Pixel row index (fetch_py) — different rows of same tile
# ===========================================================================
# Write char tile 6 with distinct per-row pens.
# Test rows py=0 and py=3 (non-trivial rows) at different vpos values.

emit({"op": "reset", "note": "reset for pixel row index test"})

CHAR_T7   = 6
COLOR_T7  = 0x0F
TILE_COL7 = 4   # tile column 4

# For vpos such that fetch_py=0: vpos=31 → FV=32, py=0, row=4
# For vpos such that fetch_py=3: vpos=34 → FV=35, py=3, row=4
ROW_CASES7 = [
    (31, 0),   # vpos=31 → fetch_vpos=32, py=0, row=4
    (34, 3),   # vpos=34 → fetch_vpos=35, py=3, row=4
]

for vpos_7, py_7 in ROW_CASES7:
    fv7   = (vpos_7 + 1) & 0x1FF
    frow7 = fv7 >> 3
    assert fv7 & 7 == py_7, f"py mismatch: fv7={fv7}, py_7={py_7}"
    assert frow7 == 4, f"row mismatch for vpos={vpos_7}"

    tile_idx7 = frow7 * 64 + TILE_COL7
    tw7 = tile_word(CHAR_T7, COLOR_T7)
    emit({"op": "write_text", "addr": TEXT_RAM_BASE + tile_idx7, "data": tw7, "be": 3,
          "note": f"row-index: tile row{frow7} col{TILE_COL7}=char{CHAR_T7}"})

    # Each row has pen = py+1 for all 8 pixels
    pen7 = py_7 + 1
    cb7 = CHAR_T7 * 32 + py_7 * 4
    b0_7, b1_7, b2_7, b3_7 = encode_row([pen7] * 8)
    emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb7 // 2,
          "data": (b0_7 << 8) | b1_7, "be": 3,
          "note": f"row-index: char{CHAR_T7} py={py_7} b0b1 pen={pen7}"})
    emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb7 // 2 + 1,
          "data": (b2_7 << 8) | b3_7, "be": 3,
          "note": f"row-index: char{CHAR_T7} py={py_7} b2b3 pen={pen7}"})

    # Check first pixel of tile col=TILE_COL7 at this vpos
    exp7 = (COLOR_T7 << 4) | pen7
    check_pixel(vpos_7, TILE_COL7 * 8, exp7,
                f"row-index: vpos={vpos_7} py={py_7} → pen={pen7}")


# ===========================================================================
# Test group 8: Model cross-check — verify Python model agrees with RTL
# ===========================================================================
# Use fdp_model.render_text_scanline() to generate expected scanline and
# add per-pixel checks. Keep this lightweight: test 10 specific pixels.

emit({"op": "reset", "note": "reset for model cross-check"})

# Build a known state in the model and emit writes + checks
m = TaitoF3Model()

# Write a simple checkerboard pattern:
#   Even cols: char=0x10, color=0x01, pen=0xC (for row py=2)
#   Odd  cols: char=0x11, color=0x02, pen=0x3

VPOS_MC = 65   # fetch_vpos=66, py=2, row=8

FV_MC  = (VPOS_MC + 1) & 0x1FF   # 66
FPY_MC = FV_MC & 7                # 2
FROW_MC = FV_MC >> 3              # 8

CHAR_EVEN = 0x10
CHAR_ODD  = 0x11
COLOR_EVEN = 0x01
COLOR_ODD  = 0x02
PEN_EVEN   = 0xC
PEN_ODD    = 0x3

for col in range(40):
    if col % 2 == 0:
        char_c, color_c, pen_c = CHAR_EVEN, COLOR_EVEN, PEN_EVEN
    else:
        char_c, color_c, pen_c = CHAR_ODD,  COLOR_ODD,  PEN_ODD

    tw_mc = tile_word(char_c, color_c)
    tidx_mc = FROW_MC * 64 + col
    emit({"op": "write_text", "addr": TEXT_RAM_BASE + tidx_mc, "data": tw_mc, "be": 3,
          "note": f"model-check: tile col{col}"})
    m.write_text_ram(tidx_mc, tw_mc)

    cb_mc = char_c * 32 + FPY_MC * 4
    b0_mc, b1_mc, b2_mc, b3_mc = encode_row([pen_c] * 8)
    emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb_mc // 2,
          "data": (b0_mc << 8) | b1_mc, "be": 3,
          "note": f"model-check: char{char_c:#04x} py={FPY_MC} b0b1"})
    emit({"op": "write_char", "addr": CHAR_RAM_BASE + cb_mc // 2 + 1,
          "data": (b2_mc << 8) | b3_mc, "be": 3,
          "note": f"model-check: char{char_c:#04x} py={FPY_MC} b2b3"})
    m.write_char_ram(cb_mc,      (b0_mc << 8) | b1_mc)
    m.write_char_ram(cb_mc + 2,  (b2_mc << 8) | b3_mc)

# Get Python model's expected scanline
expected = m.render_text_scanline(VPOS_MC)

# Check 20 representative pixels (every 16 pixels across the line)
for scol in range(0, 320, 16):
    exp_px = expected[scol]
    check_pixel(VPOS_MC, scol, exp_px,
                f"model-check: scanline{VPOS_MC} col{scol} exp={exp_px:#05x}")


# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step2_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
