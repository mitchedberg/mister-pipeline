#!/usr/bin/env python3
"""
generate_gate4.py — Kaneko16 Gate 4 test vector generator.

Produces gate4_vectors.jsonl covering:

  1.  Single tile, solid fill, no scroll — basic pixel hit and miss
  2.  Scroll X: tile column wrap via scroll register
  3.  Scroll Y: tile row wrap via scroll register
  4.  512px scroll wrap-around (both axes)
  5.  HFLIP — pixel order reversed within tile
  6.  VFLIP — row order reversed within tile
  7.  HFLIP + VFLIP combined
  8.  Transparent tile (all nybble=0) — no valid pixels
  9.  Palette field — different palette banks
  10. Layer independence — BG0 and BG1 independent tiles/scroll

Target: 60+ checks.

Vector operations (processed by tb_gate4.cpp):
  reset                             — DUT reset
  vsync_pulse                       — pulse vsync_n low (shadow→active latch)
  write_tilemap  layer,row,col,data — write one 16-bit VRAM word to tilemap
  write_scroll   layer,axis,data    — write scroll register (axis: "x" or "y")
  write_bg_rom   addr,data          — write one byte into testbench BG tile ROM
  set_pixel      layer,hpos,vpos    — set hpos/vpos/layer_sel inputs, clock once
  check_bg_valid layer,exp          — check bg_pix_valid[layer]
  check_bg_color layer,exp          — check bg_pix_color[layer]
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate4_model import Kaneko16TilemapModel

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate4_vectors.jsonl')


# ─────────────────────────────────────────────────────────────────────────────
# Generator
# ─────────────────────────────────────────────────────────────────────────────

def generate():
    recs = []
    check_count = 0

    def add(obj):
        recs.append(obj)

    def chk(obj):
        nonlocal check_count
        recs.append(obj)
        check_count += 1

    # ── Shortcut helpers ─────────────────────────────────────────────────────

    def reset():
        add({"op": "reset"})

    def vsync_pulse():
        add({"op": "vsync_pulse"})

    def write_tilemap(layer: int, row: int, col: int, data: int):
        add({"op": "write_tilemap", "layer": layer, "row": row, "col": col, "data": data})

    def write_scroll(layer: int, axis: str, data: int):
        add({"op": "write_scroll", "layer": layer, "axis": axis, "data": data})

    def write_bg_rom(addr: int, data: int):
        add({"op": "write_bg_rom", "addr": addr, "data": data})

    def set_pixel(layer: int, hpos: int, vpos: int):
        add({"op": "set_pixel", "layer": layer, "hpos": hpos, "vpos": vpos})

    def check_valid(layer: int, exp: int):
        chk({"op": "check_bg_valid", "layer": layer, "exp": exp})

    def check_color(layer: int, exp: int):
        chk({"op": "check_bg_color", "layer": layer, "exp": exp})

    def load_solid_tile(model: Kaneko16TilemapModel, tile_num: int, nybble: int):
        """Write solid-fill tile to both DUT BG ROM and model."""
        byte_val = (nybble << 4) | nybble
        base = tile_num * 128
        for b in range(128):
            write_bg_rom(base + b, byte_val)
        model.write_solid_tile(tile_num, nybble)

    def load_tile_row(model: Kaneko16TilemapModel, tile_num: int,
                      py: int, nybbles: list):
        """Write one tile row (16 pixels) to both DUT BG ROM and model."""
        assert len(nybbles) == 16
        base = tile_num * 128 + py * 8
        for b in range(8):
            lo = nybbles[b * 2]     & 0xF
            hi = nybbles[b * 2 + 1] & 0xF
            write_bg_rom(base + b, (hi << 4) | lo)
        model.write_tile_row(tile_num, py, nybbles)

    def write_tile_to_dut(model: Kaneko16TilemapModel,
                          layer: int, row: int, col: int,
                          tile_num: int, palette: int,
                          hflip: bool = False, vflip: bool = False):
        """Write a tile VRAM entry to both DUT and model."""
        word = model.make_vram_word(tile_num, palette, hflip, vflip)
        write_tilemap(layer, row, col, word)
        model.write_vram(layer, row, col, word)

    def set_scroll_both(model: Kaneko16TilemapModel,
                        layer: int, sx: int, sy: int):
        """Write scroll registers to DUT and model."""
        write_scroll(layer, "x", sx)
        write_scroll(layer, "y", sy)
        vsync_pulse()
        model.set_scroll(layer, sx, sy)

    def query(model: Kaneko16TilemapModel,
              layer: int, hpos: int, vpos: int):
        """Drive a pixel query and verify against model."""
        set_pixel(layer, hpos, vpos)
        p = model.get_pixel(layer, hpos, vpos)
        check_valid(layer, int(p.valid))
        if p.valid:
            check_color(layer, p.color)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 1: Single tile, solid fill, no scroll — hit and miss
    # Tile 1 (nybble=5, palette=3) at BG0 row=0, col=0.
    # Pixel (0,0)..(15,15) → inside → valid, color=0x35
    # Pixel (16,0) → next tile (empty) → invalid
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_solid_tile(m, 1, 0x5)
    write_tile_to_dut(m, layer=0, row=0, col=0, tile_num=1, palette=3)
    set_scroll_both(m, 0, 0, 0)

    # Top-left corner of tile
    query(m, 0, hpos=0,  vpos=0)
    # Inside tile (mid-X, mid-Y)
    query(m, 0, hpos=8,  vpos=8)
    # Bottom-right corner of tile
    query(m, 0, hpos=15, vpos=15)
    # Just past right edge → next tile (empty) → transparent
    query(m, 0, hpos=16, vpos=0)
    # Just past bottom edge → next tile row (empty) → transparent
    query(m, 0, hpos=0,  vpos=16)
    # Left of first tile → transparent (col wraps to 31, empty)
    # hpos=-1 not valid; skip

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 2: Scroll X — shift tiles right so col=1 appears at hpos=0
    # Tile 2 (nybble=7, palette=1) at BG1 row=0, col=1
    # scroll_x=16 → tile_x=(0+16)&0x1FF=16 → col=1 → hits tile 2
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_solid_tile(m, 2, 0x7)
    write_tile_to_dut(m, layer=1, row=0, col=1, tile_num=2, palette=1)
    set_scroll_both(m, 1, 16, 0)

    query(m, 1, hpos=0, vpos=0)   # → col=1, valid, 0x17
    query(m, 1, hpos=15, vpos=0)  # → col=1 (px=31 → byte boundary), valid
    query(m, 1, hpos=16, vpos=0)  # → col=2, empty → transparent

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 3: Scroll Y — shift tiles down so row=1 appears at vpos=0
    # Tile 3 (nybble=9, palette=2) at BG2 row=1, col=0
    # scroll_y=16 → tile_y=(0+16)&0x1FF=16 → row=1 → hits tile 3
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_solid_tile(m, 3, 0x9)
    write_tile_to_dut(m, layer=2, row=1, col=0, tile_num=3, palette=2)
    set_scroll_both(m, 2, 0, 16)

    query(m, 2, hpos=0, vpos=0)   # → row=1, valid, 0x29
    query(m, 2, hpos=0, vpos=15)  # → row=1 (py=31), valid
    query(m, 2, hpos=0, vpos=16)  # → row=2, empty → transparent

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 4: 512px scroll wrap-around
    # Tile at BG3 row=0, col=0.  scroll_x=0x1F0 → tile_x=(16+0x1F0)&0x1FF=0 → col=0 wraps
    # hpos=16: tile_x=(16+0x1F0)&0x1FF = 0x200 & 0x1FF = 0 → col=0 → hits tile
    # hpos=0:  tile_x=(0+0x1F0)&0x1FF  = 0x1F0 → col=31 → empty
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_solid_tile(m, 4, 0xC)
    write_tile_to_dut(m, layer=3, row=0, col=0, tile_num=4, palette=6)
    set_scroll_both(m, 3, 0x1F0, 0)

    query(m, 3, hpos=0,  vpos=0)   # col=31, empty → transparent
    query(m, 3, hpos=16, vpos=0)   # wraps to col=0 → valid, 0x6C

    # Also test Y wrap
    write_tile_to_dut(m, layer=3, row=0, col=0, tile_num=4, palette=6)  # same tile
    set_scroll_both(m, 3, 0, 0x1F0)

    query(m, 3, hpos=0, vpos=0)    # tile_y=(0+0x1F0) → row=31, empty → transparent
    query(m, 3, hpos=0, vpos=16)   # tile_y=(16+0x1F0)&0x1FF=0 → row=0 → valid, 0x6C

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 5: HFLIP — pixel order reversed within tile
    # Tile row: [1,2,3,4,5,6,7,8,9,A,B,C,D,E,F,1]
    # hflip=True: screen px 0 → tile px 15 → nybble 1 → color {1,1}=0x11
    #             screen px 1 → tile px 14 → nybble F → color {1,F}=0x1F
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    row0 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
    for r in range(16):
        load_tile_row(m, 5, r, row0)
    write_tile_to_dut(m, layer=0, row=0, col=0, tile_num=5, palette=1, hflip=True)
    set_scroll_both(m, 0, 0, 0)

    query(m, 0, hpos=0,  vpos=0)   # 0x11
    query(m, 0, hpos=1,  vpos=0)   # 0x1F
    query(m, 0, hpos=14, vpos=0)   # 0x12
    query(m, 0, hpos=15, vpos=0)   # 0x11

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 6: VFLIP — row order reversed within tile
    # Tile: row 0 all-0xA, row 15 all-0xB, others 0x9
    # vflip=True: vpos=0 → py=0 → fpy=15 → nybble 0xB → color {2,B}=0x2B
    #             vpos=15 → py=15 → fpy=0 → nybble 0xA → color {2,A}=0x2A
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_tile_row(m, 6, 0,  [0xA] * 16)
    load_tile_row(m, 6, 15, [0xB] * 16)
    for r in range(1, 15):
        load_tile_row(m, 6, r, [0x9] * 16)
    write_tile_to_dut(m, layer=1, row=0, col=0, tile_num=6, palette=2, vflip=True)
    set_scroll_both(m, 1, 0, 0)

    query(m, 1, hpos=0, vpos=0)    # fpy=15 → 0xB → 0x2B
    query(m, 1, hpos=0, vpos=15)   # fpy=0  → 0xA → 0x2A
    query(m, 1, hpos=0, vpos=7)    # fpy=8  → 0x9 → 0x29
    query(m, 1, hpos=15, vpos=0)   # last X in tile, vflip=15 → 0x2B

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 7: HFLIP + VFLIP combined
    # Tile: same as scenario 5 row0 pattern + vflip row layout
    # tile_num=7, palette=4: row 0 = [1..F,1], row 15 = [F..1,F] reversed
    # hflip+vflip: screen (0,0) → tile px=(15,15) → row 15, px 15
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    row_asc  = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
    row_desc = [1, 0xF, 0xE, 0xD, 0xC, 0xB, 0xA, 9, 8, 7, 6, 5, 4, 3, 2, 1]
    load_tile_row(m, 7, 0,  row_asc)
    load_tile_row(m, 7, 15, row_desc)
    for r in range(1, 15):
        load_tile_row(m, 7, r, [0x9] * 16)
    write_tile_to_dut(m, layer=2, row=0, col=0, tile_num=7, palette=4,
                      hflip=True, vflip=True)
    set_scroll_both(m, 2, 0, 0)

    # hflip+vflip: (hpos=0,vpos=0) → fpx=15, fpy=15 → row_desc[15]=1 → {4,1}=0x41
    query(m, 2, hpos=0, vpos=0)
    # (hpos=0, vpos=15) → fpx=15, fpy=0 → row_asc[15]=1 → {4,1}=0x41
    query(m, 2, hpos=0, vpos=15)
    # (hpos=1, vpos=0) → fpx=14, fpy=15 → row_desc[14]=2 → {4,2}=0x42
    query(m, 2, hpos=1, vpos=0)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 8: Transparent tile — all nybble=0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_solid_tile(m, 8, 0)
    write_tile_to_dut(m, layer=0, row=0, col=0, tile_num=8, palette=7)
    set_scroll_both(m, 0, 0, 0)

    query(m, 0, hpos=0,  vpos=0)   # transparent
    query(m, 0, hpos=8,  vpos=8)   # transparent
    query(m, 0, hpos=15, vpos=15)  # transparent

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 9: Palette field — four different palette banks
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_solid_tile(m, 9, 0x6)  # same tile, different palettes per layer

    write_tile_to_dut(m, layer=0, row=0, col=0, tile_num=9, palette=0x0)
    write_tile_to_dut(m, layer=1, row=0, col=0, tile_num=9, palette=0x5)
    write_tile_to_dut(m, layer=2, row=0, col=0, tile_num=9, palette=0xA)
    write_tile_to_dut(m, layer=3, row=0, col=0, tile_num=9, palette=0xF)
    set_scroll_both(m, 0, 0, 0)
    set_scroll_both(m, 1, 0, 0)
    set_scroll_both(m, 2, 0, 0)
    set_scroll_both(m, 3, 0, 0)

    query(m, 0, hpos=0, vpos=0)   # palette=0, nybble=6 → 0x06
    query(m, 1, hpos=0, vpos=0)   # palette=5 → 0x56
    query(m, 2, hpos=0, vpos=0)   # palette=A → 0xA6
    query(m, 3, hpos=0, vpos=0)   # palette=F → 0xF6

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 10: Layer independence — BG0 and BG1 see different tiles
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_solid_tile(m, 10, 0x3)
    load_solid_tile(m, 11, 0xE)

    write_tile_to_dut(m, layer=0, row=0, col=0, tile_num=10, palette=1)
    write_tile_to_dut(m, layer=1, row=0, col=0, tile_num=11, palette=2)
    set_scroll_both(m, 0, 0, 0)
    set_scroll_both(m, 1, 0, 0)

    query(m, 0, hpos=0, vpos=0)   # layer0: 0x13
    query(m, 1, hpos=0, vpos=0)   # layer1: 0x2E

    # Layer 2 and 3 should be empty (never written)
    query(m, 2, hpos=0, vpos=0)   # transparent
    query(m, 3, hpos=0, vpos=0)   # transparent

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 11: Scroll affects only the target layer
    # BG0 scroll_x=32, BG1 scroll_x=0.  Tile at BG0 col=2, BG1 col=0.
    # hpos=0: BG0 sees col=2 (tile 12, 0x44), BG1 sees col=0 (tile 13, 0x5B)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = Kaneko16TilemapModel()

    load_solid_tile(m, 12, 0x4)
    load_solid_tile(m, 13, 0xB)

    write_tile_to_dut(m, layer=0, row=0, col=2, tile_num=12, palette=4)
    write_tile_to_dut(m, layer=1, row=0, col=0, tile_num=13, palette=5)
    set_scroll_both(m, 0, 32, 0)   # scroll BG0 by 2 tiles
    set_scroll_both(m, 1, 0,  0)

    query(m, 0, hpos=0, vpos=0)   # BG0 col=2 → 0x44
    query(m, 1, hpos=0, vpos=0)   # BG1 col=0 → 0x5B

    # ── Write output ──────────────────────────────────────────────────────────
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate4: {check_count} checks → {OUT_PATH}", file=sys.stderr)
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
