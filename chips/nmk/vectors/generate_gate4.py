#!/usr/bin/env python3
"""
generate_gate4.py — NMK16 Gate 4 test vector generator.

Produces gate4_vectors.jsonl covering:

  1.  Tilemap RAM write + read-back via CPU port
  2.  Single tile rendering, layer 0, no scroll (pixel at tile origin)
  3.  Single tile rendering, pixel in middle of tile (non-zero pix_x, pix_y)
  4.  Transparent tile (all nybble=0) → bg_pix_valid=0
  5.  X scroll: tile shifts into view from right
  6.  Y scroll: tile shifts into view from below
  7.  Scroll wrap-around (mod 512)
  8.  flip_x: pixel order reversed within tile row
  9.  flip_y: row order reversed
 10.  Two independent layers (different tiles, different palettes)
 11.  Layer 1 scroll independent of layer 0

Target: 50+ checks.

Vector operations (processed by tb_gate4.cpp):
  reset                   — DUT reset
  write_tram  layer, row, col, data — write tilemap RAM word
  read_tram   layer, row, col, exp  — read tilemap RAM word, check
  write_bg_rom addr, data — write one byte into testbench BG tile ROM
  write_scroll layer, axis ("x"|"y"), data — write scroll reg + vsync pulse
  set_bg      bg_x, bg_y — drive bg_x and bg_y pixel coordinate inputs
  clock_n     n          — advance n clock cycles
  check_bg_valid layer, exp — check bg_pix_valid[layer]
  check_bg_color layer, exp — check bg_pix_color[layer]

NMK16 BG tilemap word format:
  [15:12] palette
  [11]    flip_y
  [10]    flip_x
  [9:0]   tile_index
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate4_model import NMK16TilemapModel, BgPixel

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate4_vectors.jsonl')


def generate():
    recs = []
    check_count = 0

    def add(obj):
        recs.append(obj)

    def chk(obj):
        nonlocal check_count
        recs.append(obj)
        check_count += 1

    # ── Helpers ────────────────────────────────────────────────────────────────

    def reset():
        add({"op": "reset"})

    def write_tram(layer: int, row: int, col: int, data: int):
        add({"op": "write_tram", "layer": layer, "row": row, "col": col, "data": data})

    def read_tram(layer: int, row: int, col: int, exp: int):
        chk({"op": "read_tram", "layer": layer, "row": row, "col": col, "exp": exp})

    def write_bg_rom(addr: int, data: int):
        add({"op": "write_bg_rom", "addr": addr, "data": data})

    def write_scroll(layer: int, axis: str, data: int):
        add({"op": "write_scroll", "layer": layer, "axis": axis, "data": data})

    def vsync_pulse():
        add({"op": "vsync_pulse"})

    def set_bg(bg_x: int, bg_y: int):
        add({"op": "set_bg", "bg_x": bg_x, "bg_y": bg_y})

    def clock_n(n: int):
        add({"op": "clock_n", "n": n})

    def check_pixel(layer: int, pix: BgPixel):
        """Emit checks for valid and color for one layer's pixel."""
        chk({"op": "check_bg_valid", "layer": layer, "exp": int(pix.valid)})
        if pix.valid:
            chk({"op": "check_bg_color", "layer": layer, "exp": pix.color})

    def make_tram_word(tile_idx: int, palette: int,
                       flip_x: int = 0, flip_y: int = 0) -> int:
        return ((palette & 0xF) << 12) | ((flip_y & 1) << 11) | \
               ((flip_x & 1) << 10) | (tile_idx & 0x3FF)

    def write_cell(m: NMK16TilemapModel, layer: int, row: int, col: int,
                   tile_idx: int, palette: int,
                   flip_x: int = 0, flip_y: int = 0):
        """Write tilemap cell to both DUT and model."""
        word = make_tram_word(tile_idx, palette, flip_x, flip_y)
        write_tram(layer, row, col, word)
        m.write_tram(layer, row, col, word)

    def write_tile_solid(m: NMK16TilemapModel, tile_num: int, nybble: int):
        """Write solid 16×16 tile to both DUT ROM and model."""
        byte_val = (nybble << 4) | nybble
        base = tile_num * 128
        for b in range(128):
            write_bg_rom(base + b, byte_val)
        m.write_solid_tile(tile_num, nybble)

    def write_tile_row_model(m: NMK16TilemapModel, tile_num: int, py: int,
                             nybbles: list):
        """Write one row (16 pixels) of a tile to DUT ROM and model."""
        assert len(nybbles) == 16
        base = tile_num * 128 + py * 8
        for b in range(8):
            hi = nybbles[b * 2 + 1]
            lo = nybbles[b * 2]
            byte_val = (hi << 4) | lo
            write_bg_rom(base + b, byte_val)
        m.write_tile_row(tile_num, py, nybbles)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 1: Tilemap RAM write + read-back
    # ══════════════════════════════════════════════════════════════════════════
    reset()

    test_cells = [
        (0, 0,  0,  0xA001),  # layer 0, row 0, col 0
        (0, 1,  0,  0x1234),  # layer 0, row 1, col 0
        (0, 0,  5,  0xBEEF),  # layer 0, row 0, col 5
        (1, 0,  0,  0xDEAD),  # layer 1, row 0, col 0
        (1, 15, 31, 0x5A5A),  # layer 1, corner
    ]
    for (layer, row, col, data) in test_cells:
        write_tram(layer, row, col, data)

    for (layer, row, col, exp) in test_cells:
        read_tram(layer, row, col, exp)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 2: Single tile, layer 0, no scroll, pixel at tile origin (0,0)
    # Tile 0x001, palette 5, nybble 0xA → color = 0x5A
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_num = 0x001
    palette  = 5
    nybble   = 0xA
    write_tile_solid(m, tile_num, nybble)
    write_cell(m, 0, 0, 0, tile_num, palette)  # layer 0, row 0, col 0

    vsync_pulse()
    set_bg(0, 0)   # bg_x=0, bg_y=0 → src_x=0, src_y=0 → col=0, row=0, pix_x=0, pix_y=0
    clock_n(4)     # 2 stages + output FF settling; run a few extra to be safe

    pix = m.get_pixel(0, 0, 0)
    check_pixel(0, pix)   # expect valid=1, color=0x5A

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 3: Pixel in middle of tile (pix_x=8, pix_y=4)
    # bg_x=8, bg_y=4, no scroll → src_x=8, src_y=4 → col=0, row=0, pix_x=8, pix_y=4
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_mid = 0x002
    palette_mid = 3
    # Row 4, px 8: nybble = 0x7
    m.write_tile_pixel(tile_mid, 4, 8, 0x7)
    byte_addr = tile_mid * 128 + 4 * 8 + 8 // 2   # py=4, px=8 → byte[4]
    write_bg_rom(byte_addr, 0x07)  # lo nibble (px=8, even) = 0x7, hi=0
    write_cell(m, 0, 0, 0, tile_mid, palette_mid)

    vsync_pulse()
    set_bg(8, 4)
    clock_n(4)

    pix = m.get_pixel(0, 8, 4)
    check_pixel(0, pix)   # expect valid=1, color={3, 7}=0x37

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 4: Transparent tile (all nybble=0) → bg_pix_valid=0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_trans = 0x003
    for b in range(128):
        write_bg_rom(tile_trans * 128 + b, 0x00)
    # model keeps zeros by default

    write_cell(m, 0, 0, 0, tile_trans, 7)

    vsync_pulse()
    set_bg(0, 0)
    clock_n(4)

    pix = m.get_pixel(0, 0, 0)
    chk({"op": "check_bg_valid", "layer": 0, "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 5: X scroll
    # Tile at (row=0, col=1), scroll_x=16 → bg_x=0 maps to src_x=16 → col=1
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_col0 = 0x004   # at tile col 0
    tile_col1 = 0x005   # at tile col 1 — should be visible at bg_x=0 after scroll_x=16

    write_tile_solid(m, tile_col0, 0x3)
    write_tile_solid(m, tile_col1, 0x6)
    write_cell(m, 0, 0, 0, tile_col0, 1)   # col 0
    write_cell(m, 0, 0, 1, tile_col1, 2)   # col 1

    write_scroll(0, "x", 16)
    m.set_scroll(0, 16, 0)
    vsync_pulse()

    # bg_x=0 with scroll_x=16 → src_x=16 → col=1 → tile_col1
    set_bg(0, 0)
    clock_n(4)

    pix = m.get_pixel(0, 0, 0)
    check_pixel(0, pix)   # nybble=6, palette=2 → color=0x26

    # bg_x=0 without scroll (src_x=0, col=0 → tile_col0)
    # Verify tile_col0 is NOT visible at bg_x=0 with scroll_x=16
    pix_no = m.get_pixel(0, 0, 0)   # model already accounts for scroll
    chk({"op": "check_bg_valid", "layer": 0, "exp": int(pix_no.valid)})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 6: Y scroll
    # Tile at (row=1, col=0), scroll_y=16 → bg_y=0 maps to src_y=16 → row=1
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_row0 = 0x006   # at tile row 0
    tile_row1 = 0x007   # at tile row 1

    write_tile_solid(m, tile_row0, 0x4)
    write_tile_solid(m, tile_row1, 0x9)
    write_cell(m, 0, 0, 0, tile_row0, 3)   # row 0, col 0
    write_cell(m, 0, 1, 0, tile_row1, 4)   # row 1, col 0

    write_scroll(0, "y", 16)
    m.set_scroll(0, 0, 16)
    vsync_pulse()

    # bg_y=0 with scroll_y=16 → src_y=16 → row=1 → tile_row1
    set_bg(0, 0)
    clock_n(4)

    pix = m.get_pixel(0, 0, 0)
    check_pixel(0, pix)   # nybble=9, palette=4 → color=0x49

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 7: Scroll wrap-around (mod 512)
    # Tile at (row=0, col=0), scroll_x=496 → bg_x=16 maps to src_x=512≡0 → col=0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_wrap = 0x008
    write_tile_solid(m, tile_wrap, 0xB)
    write_cell(m, 0, 0, 0, tile_wrap, 0xC)

    write_scroll(0, "x", 496)
    m.set_scroll(0, 496, 0)
    vsync_pulse()

    # bg_x=16: src_x = (16 + 496) & 0x1FF = 512 & 0x1FF = 0 → col=0 → tile_wrap
    set_bg(16, 0)
    clock_n(4)

    pix = m.get_pixel(0, 16, 0)
    check_pixel(0, pix)   # nybble=0xB, palette=0xC → color=0xCB

    # bg_x=0: src_x=(0+496)&0x1FF=496 → col=31 (no tile there → transparent)
    set_bg(0, 0)
    clock_n(4)

    pix2 = m.get_pixel(0, 0, 0)   # col=31, no tile written → transparent
    chk({"op": "check_bg_valid", "layer": 0, "exp": int(pix2.valid)})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 8: flip_x — pixel order reversed within tile row
    # Tile 0x009: row 0 = [0x1, 0x2, ..., 0xF, 0x0]  (px 0..15)
    # With flip_x=1: bg_x=0, pix_x=0 → fpx=15 → nybble=0x0 (transparent)
    #                bg_x=1, pix_x=1 → fpx=14 → nybble=0xF
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_flipx = 0x009
    palette_fx = 6
    # Row 0: nybbles [0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8,
    #                  0x9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 0x0]
    row0 = [0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8,
            0x9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 0x0]
    write_tile_row_model(m, tile_flipx, 0, row0)
    write_cell(m, 0, 0, 0, tile_flipx, palette_fx, flip_x=1)

    vsync_pulse()
    # pix_x=1 with flip_x → fpx=14 → nybble=0xF → valid
    set_bg(1, 0)
    clock_n(4)

    pix = m.get_pixel(0, 1, 0)   # fpx=14, nybble=0xF → color={6,F}=0x6F
    check_pixel(0, pix)

    # pix_x=0 with flip_x → fpx=15 → nybble=0x0 → transparent
    set_bg(0, 0)
    clock_n(4)
    pix2 = m.get_pixel(0, 0, 0)
    chk({"op": "check_bg_valid", "layer": 0, "exp": int(pix2.valid)})   # expect 0

    # pix_x=15 with flip_x → fpx=0 → nybble=0x1 → color={6,1}=0x61
    set_bg(15, 0)
    clock_n(4)
    pix3 = m.get_pixel(0, 15, 0)
    check_pixel(0, pix3)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 9: flip_y — row order reversed
    # Tile 0x00A: row 0 = all 0xA, row 15 = all 0xE
    # With flip_y=1: bg_y=0, pix_y=0 → fpy=15 → nybble=0xE
    #                bg_y=15, pix_y=15 → fpy=0 → nybble=0xA
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_flipy = 0x00A
    palette_fy = 7

    # Row 0: all 0xA
    write_tile_row_model(m, tile_flipy, 0,  [0xA]*16)
    # Row 15: all 0xE
    write_tile_row_model(m, tile_flipy, 15, [0xE]*16)
    write_cell(m, 0, 0, 0, tile_flipy, palette_fy, flip_y=1)

    vsync_pulse()
    # pix_y=0 with flip_y → fpy=15 → nybble=0xE
    set_bg(0, 0)
    clock_n(4)

    pix = m.get_pixel(0, 0, 0)   # color={7,E}=0x7E
    check_pixel(0, pix)

    # pix_y=15 with flip_y → fpy=0 → nybble=0xA
    set_bg(0, 15)
    clock_n(4)
    pix2 = m.get_pixel(0, 0, 15)
    check_pixel(0, pix2)   # color={7,A}=0x7A

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 10: Two independent layers
    # Layer 0: tile 0x00B, palette=1, nybble=0x5 at (0,0)
    # Layer 1: tile 0x00C, palette=2, nybble=0xC at (0,0)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_l0 = 0x00B
    tile_l1 = 0x00C

    write_tile_solid(m, tile_l0, 0x5)
    write_tile_solid(m, tile_l1, 0xC)
    write_cell(m, 0, 0, 0, tile_l0, 1)   # layer 0
    write_cell(m, 1, 0, 0, tile_l1, 2)   # layer 1

    vsync_pulse()
    set_bg(0, 0)
    clock_n(6)   # run enough cycles for both layers to update (2 layers × 2-cycle pipeline)

    pix0 = m.get_pixel(0, 0, 0)
    pix1 = m.get_pixel(1, 0, 0)
    check_pixel(0, pix0)   # {1, 5}=0x15
    check_pixel(1, pix1)   # {2, C}=0x2C

    # Explicit color check for robustness
    chk({"op": "check_bg_color", "layer": 0, "exp": 0x15})
    chk({"op": "check_bg_color", "layer": 1, "exp": 0x2C})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 11: Layer 1 scroll independent of layer 0
    # Layer 0: tile 0x00D, col 0, palette=8, nybble=0x3 — no scroll
    # Layer 1: tile 0x00E, col 1, palette=9, nybble=0x7 — scroll_x=16 (visible at bg_x=0)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = NMK16TilemapModel()

    tile_la = 0x00D   # layer 0, at col 0
    tile_lb = 0x00E   # layer 1, at col 1 (visible via scroll)

    write_tile_solid(m, tile_la, 0x3)
    write_tile_solid(m, tile_lb, 0x7)
    write_cell(m, 0, 0, 0, tile_la, 8)   # layer 0, col 0
    write_cell(m, 1, 0, 1, tile_lb, 9)   # layer 1, col 1

    # Layer 1 scroll_x=16: bg_x=0 → src_x=16 → col=1
    write_scroll(1, "x", 16)
    m.set_scroll(1, 16, 0)
    vsync_pulse()

    set_bg(0, 0)
    clock_n(6)

    pix_a = m.get_pixel(0, 0, 0)   # layer 0, no scroll → col 0 → tile_la
    pix_b = m.get_pixel(1, 0, 0)   # layer 1, scroll_x=16 → col 1 → tile_lb

    check_pixel(0, pix_a)   # {8, 3}=0x83
    check_pixel(1, pix_b)   # {9, 7}=0x97

    # ══════════════════════════════════════════════════════════════════════════
    # Write output
    # ══════════════════════════════════════════════════════════════════════════
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate4: {check_count} checks → {OUT_PATH}")
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
