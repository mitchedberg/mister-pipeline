#!/usr/bin/env python3
"""
generate_gate3.py — GP9001 Gate 3 test vector generator.

Produces gate3_vectors.jsonl covering:

  1. VRAM write + read-back via CPU port
  2. Single tile rendering: one tile in layer 0, verify pixel output
  3. Scroll: write tile at (0,0), apply X scroll, verify pixel shifts
  4. Flip-X and Flip-Y attributes
  5. Transparency: palette_index=0 → bg_pix_valid=0
  6. Two layers: verify layer 0 and layer 1 produce independent output
  7. Priority bit pass-through
  8. Blanking suppresses output

Target: 50+ checks.

Vector operations:
  reset                   — DUT reset
  vram_sel        layer   — write VRAM_SEL register (reg 0x0F)
  write_vram      addr, data — write VRAM word (addr[9:0] within layer)
  read_vram       addr, exp  — read back VRAM (registered, 1-cycle latency)
  write_scroll    layer, axis ("x"|"y"), data — write scroll register + vsync_pulse
  set_pixel       hpos, vpos, hblank, vblank  — drive pixel coordinates
  write_rom_byte  addr, data — write tile ROM byte in TB
  clock_n         n           — advance n clock cycles
  check_bg_valid  layer, exp  — check bg_pix_valid[layer]
  check_bg_color  layer, exp  — check bg_pix_color[layer]
  check_bg_prio   layer, exp  — check bg_pix_priority[layer]
  vsync_pulse                 — pulse vsync for shadow→active staging
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate3_model import GP9001TilemapModel, BgPixel

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate3_vectors.jsonl')


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

    def vram_sel(layer: int):
        add({"op": "vram_sel", "layer": layer})

    def write_vram(addr_low: int, data: int):
        add({"op": "write_vram", "addr": addr_low, "data": data})

    def read_vram(addr_low: int, exp: int):
        chk({"op": "read_vram", "addr": addr_low, "exp": exp})

    def write_scroll(layer: int, axis: str, data: int):
        add({"op": "write_scroll", "layer": layer, "axis": axis, "data": data})

    def vsync_pulse():
        add({"op": "vsync_pulse"})

    def write_rom_byte(addr: int, data: int):
        add({"op": "write_rom_byte", "addr": addr, "data": data})

    def set_pixel(hpos: int, vpos: int, hblank: int = 0, vblank: int = 0):
        add({"op": "set_pixel", "hpos": hpos, "vpos": vpos,
             "hblank": hblank, "vblank": vblank})

    def clock_n(n: int):
        add({"op": "clock_n", "n": n})

    def check_pixel(layer: int, pix: BgPixel):
        """Emit checks for valid, color, priority for one layer's pixel."""
        chk({"op": "check_bg_valid", "layer": layer, "exp": int(pix.valid)})
        if pix.valid:
            chk({"op": "check_bg_color",  "layer": layer, "exp": pix.color})
            chk({"op": "check_bg_prio",   "layer": layer, "exp": int(pix.priority)})

    def write_cell(m: GP9001TilemapModel, layer: int, cell: int,
                   tile_num: int, palette: int,
                   flip_x: int = 0, flip_y: int = 0, prio: int = 0):
        """Write one VRAM cell (code+attr) to both DUT and model."""
        code_word = tile_num & 0xFFF
        attr_word = (palette & 0xF) | ((flip_x & 1) << 4) | ((flip_y & 1) << 5) | ((prio & 1) << 6)
        addr_code = cell * 2 + 0
        addr_attr = cell * 2 + 1
        vram_sel(layer)
        write_vram(addr_code, code_word)
        write_vram(addr_attr, attr_word)
        m.write_vram(layer, cell, code_word, attr_word)

    def write_tile_solid(m: GP9001TilemapModel, tile_num: int, nybble: int):
        """Write solid tile (all pixels same nybble) to both DUT ROM and model."""
        byte_val = (nybble << 4) | nybble
        base = tile_num * 32
        for b in range(32):
            write_rom_byte(base + b, byte_val)
        m.write_solid_tile(tile_num, nybble)

    def write_tile_row(m: GP9001TilemapModel, tile_num: int, py: int, nybbles: list):
        """Write one row of a tile."""
        assert len(nybbles) == 8
        base = tile_num * 32 + py * 4
        for b in range(4):
            hi = nybbles[b * 2 + 1]
            lo = nybbles[b * 2]
            byte_val = (hi << 4) | lo
            write_rom_byte(base + b, byte_val)
        m.write_tile_row(tile_num, py, nybbles)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 1: VRAM write + read-back via CPU port
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    # Write several VRAM cells across layers and read them back
    test_cells = [
        (0, 0, 0x0000, 0xABCD),   # layer 0, cell 0 code, addr 0
        (0, 1, 0x0001, 0x1234),   # layer 0, cell 0 attr, addr 1
        (1, 0, 0x0002, 0xDEAD),   # layer 1, cell 0 code
        (1, 1, 0x0003, 0xBEEF),   # layer 1, cell 0 attr
        (2, 0, 0x0004, 0x1111),   # layer 2 code
        (3, 0, 0x0006, 0x2222),   # layer 3 code
    ]
    for (layer, addr_low, _, data) in test_cells:
        vram_sel(layer)
        write_vram(addr_low, data)

    # Read back: registered 1-cycle latency
    for (layer, addr_low, _, exp) in test_cells:
        vram_sel(layer)
        read_vram(addr_low, exp)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 2: Single tile rendering — layer 0, no scroll, pixel (4,4)
    # Tile 0x001 at cell (0,0) (row=0, col=0), palette=5, nybble=0xA
    # pixel(hpos=4, vpos=4) → tile (0,0), px=4, py=4
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_num = 0x001
    palette  = 5
    nybble   = 0xA
    write_tile_solid(m, tile_num, nybble)
    write_cell(m, 0, 0, tile_num, palette)   # layer=0, cell=0

    vsync_pulse()
    set_pixel(4, 4)   # hpos=4, vpos=4 → col=0, row=0, px=4, py=4
    clock_n(3)        # wait for pipeline: mux_layer cycles 0→1→2→3 then back

    # Advance enough cycles for all 4 layers to complete at least 1 pass
    # Layer 0 is processed when mux_layer=0 (every 4 clocks).
    # After set_pixel + 3 clocks, we've seen mux_layer=0 at least once.
    # Wait one more full cycle (4 clocks) to ensure layer 0 output is settled.
    clock_n(4)

    pix = m.get_pixel(0, 4, 4)
    check_pixel(0, pix)   # expect valid=1, color={(palette=5),(nybble=0xA)}=0x5A

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 3: Scroll — tile at (0,0), apply X scroll = 8 → pixel shifts left
    # With scroll_x=8: tile_x = hpos + 8 → pixel(hpos=0) maps to tile_x=8 → col=1
    # Tile at cell (0,0) NOT visible at hpos=0 with scroll_x=8.
    # Tile at cell (0,1) (col=1, row=0) IS visible at hpos=0.
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_a = 0x002   # tile at cell (row=0, col=0)
    tile_b = 0x003   # tile at cell (row=0, col=1) — should be visible at hpos=0 after scroll

    nybble_a = 0x3
    nybble_b = 0x7

    write_tile_solid(m, tile_a, nybble_a)
    write_tile_solid(m, tile_b, nybble_b)
    write_cell(m, 0, 0, tile_a, 2)   # cell 0: col=0, row=0
    write_cell(m, 0, 1, tile_b, 3)   # cell 1: col=1, row=0

    # Set scroll_x = 8 → any pixel at hpos H maps to tile column (H+8)/8
    write_scroll(0, "x", 8)
    m.set_scroll(0, 8, 0)
    vsync_pulse()

    # hpos=0 with scroll_x=8 → tile_x=8 → col=1 → tile_b
    set_pixel(0, 0)
    clock_n(8)

    pix = m.get_pixel(0, 0, 0)
    check_pixel(0, pix)   # tile_b nybble=7, palette=3 → color=0x37, valid=1

    # hpos=8 with scroll_x=8 → tile_x=16 → col=2 → empty tile (nybble=0) → transparent
    set_pixel(8, 0)
    clock_n(8)

    pix2 = m.get_pixel(0, 8, 0)
    chk({"op": "check_bg_valid", "layer": 0, "exp": int(pix2.valid)})

    # hpos=0 without scroll (layer 1) → col=0 → tile_a (but nothing in layer 1)
    pix3 = m.get_pixel(1, 0, 0)
    chk({"op": "check_bg_valid", "layer": 1, "exp": int(pix3.valid)})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 4: Flip-X
    # Tile 0x004: column pattern [1,2,3,4,5,6,7,8] (px=0..7, py=0)
    # With flip_x=1: px=0 should map to ROM px=7 → nybble=8
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_flip = 0x004
    palette_f = 6
    row_nybbles = [1, 2, 3, 4, 5, 6, 7, 8]  # px 0..7
    write_tile_row(m, tile_flip, 0, row_nybbles)

    # Write cell (0,0) with flip_x=1
    write_cell(m, 0, 0, tile_flip, palette_f, flip_x=1, flip_y=0, prio=0)

    vsync_pulse()
    set_pixel(0, 0)   # px=0, py=0
    clock_n(8)

    pix = m.get_pixel(0, 0, 0)   # with flip_x: fpx=7 → nybble=8
    check_pixel(0, pix)   # valid=1, color={6, 8}=0x68

    # px=7 with flip_x → fpx=0 → nybble=1
    set_pixel(7, 0)
    clock_n(8)
    pix2 = m.get_pixel(0, 7, 0)
    check_pixel(0, pix2)  # color={6, 1}=0x61

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 5: Flip-Y
    # Tile 0x005: row 0 = nybble 0xA, row 7 = nybble 0xB
    # With flip_y=1: vpos=0 maps to py=7 → nybble=0xB
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_flipy = 0x005
    palette_fy = 7

    # Write tile: row 0 all 0xA, row 7 all 0xB
    for px_i in range(8):
        m.write_tile_pixel(tile_flipy, 0, px_i, 0xA)
        write_rom_byte(tile_flipy * 32 + 0 * 4 + px_i // 2,
                       (0xA << 4 | 0xA) if px_i % 2 == 1 else (0xA << 4 | 0xA))
    for px_i in range(8):
        m.write_tile_pixel(tile_flipy, 7, px_i, 0xB)

    # Rewrite rows 0 and 7 cleanly via write_tile_row
    write_tile_row(m, tile_flipy, 0, [0xA, 0xA, 0xA, 0xA, 0xA, 0xA, 0xA, 0xA])
    write_tile_row(m, tile_flipy, 7, [0xB, 0xB, 0xB, 0xB, 0xB, 0xB, 0xB, 0xB])

    write_cell(m, 0, 0, tile_flipy, palette_fy, flip_x=0, flip_y=1, prio=0)

    vsync_pulse()
    set_pixel(0, 0)   # py=0 with flip_y → fpy=7 → nybble=0xB
    clock_n(8)

    pix = m.get_pixel(0, 0, 0)
    check_pixel(0, pix)   # valid=1, color={7, 0xB}=0x7B

    set_pixel(0, 7)   # py=7 with flip_y → fpy=0 → nybble=0xA
    clock_n(8)
    pix2 = m.get_pixel(0, 0, 7)
    check_pixel(0, pix2)  # valid=1, color={7, 0xA}=0x7A

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 6: Transparency — palette_index=0 → bg_pix_valid=0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_trans = 0x006
    # Write all pixels as 0 (transparent)
    for b in range(32):
        write_rom_byte(tile_trans * 32 + b, 0x00)
    # Model: all zero → stays as initialized

    write_cell(m, 0, 0, tile_trans, 4)

    vsync_pulse()
    set_pixel(0, 0)
    clock_n(8)

    pix = m.get_pixel(0, 0, 0)   # nybble=0 → transparent
    chk({"op": "check_bg_valid", "layer": 0, "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 7: Two independent layers
    # Layer 0: tile 0x007, palette=1, nybble=0x5 at cell 0
    # Layer 1: tile 0x008, palette=2, nybble=0xC at cell 0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_l0 = 0x007
    tile_l1 = 0x008

    write_tile_solid(m, tile_l0, 0x5)
    write_tile_solid(m, tile_l1, 0xC)
    write_cell(m, 0, 0, tile_l0, 1)   # layer 0
    write_cell(m, 1, 0, tile_l1, 2)   # layer 1

    vsync_pulse()
    set_pixel(0, 0)
    clock_n(8)

    pix0 = m.get_pixel(0, 0, 0)
    pix1 = m.get_pixel(1, 0, 0)
    check_pixel(0, pix0)   # {1, 5} = 0x15
    check_pixel(1, pix1)   # {2, C} = 0x2C

    # Verify they're different (integrity check)
    chk({"op": "check_bg_color", "layer": 0, "exp": 0x15})
    chk({"op": "check_bg_color", "layer": 1, "exp": 0x2C})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 8: Priority bit pass-through
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_prio = 0x009
    write_tile_solid(m, tile_prio, 0x3)

    # Write with prio=1
    write_cell(m, 0, 0, tile_prio, 8, flip_x=0, flip_y=0, prio=1)

    vsync_pulse()
    set_pixel(0, 0)
    clock_n(8)

    pix = m.get_pixel(0, 0, 0)
    chk({"op": "check_bg_valid", "layer": 0, "exp": 1})
    chk({"op": "check_bg_prio",  "layer": 0, "exp": 1})

    # Repeat with prio=0
    reset()
    m = GP9001TilemapModel()
    write_tile_solid(m, tile_prio, 0x3)
    write_cell(m, 0, 0, tile_prio, 8, flip_x=0, flip_y=0, prio=0)

    vsync_pulse()
    set_pixel(0, 0)
    clock_n(8)

    pix2 = m.get_pixel(0, 0, 0)
    chk({"op": "check_bg_valid", "layer": 0, "exp": 1})
    chk({"op": "check_bg_prio",  "layer": 0, "exp": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 9: Blanking suppresses output
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_blank = 0x00A
    write_tile_solid(m, tile_blank, 0xF)
    write_cell(m, 0, 0, tile_blank, 9)

    vsync_pulse()

    # During hblank: pixel should be invalid even though tile is opaque
    set_pixel(0, 0, hblank=1, vblank=0)
    clock_n(8)
    chk({"op": "check_bg_valid", "layer": 0, "exp": 0})

    # During vblank
    set_pixel(0, 0, hblank=0, vblank=1)
    clock_n(8)
    chk({"op": "check_bg_valid", "layer": 0, "exp": 0})

    # Active (not blanking) — should be valid
    set_pixel(0, 0, hblank=0, vblank=0)
    clock_n(8)
    pix = m.get_pixel(0, 0, 0)
    chk({"op": "check_bg_valid", "layer": 0, "exp": int(pix.valid)})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 10: Y scroll
    # Tile at cell (row=1, col=0). With scroll_y=8: vpos=0 → tile_y=8 → row=1.
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_yscroll = 0x00B
    write_tile_solid(m, tile_yscroll, 0xE)
    write_cell(m, 0, 64, tile_yscroll, 0xC)  # cell 64 = row=1, col=0

    write_scroll(0, "y", 8)
    m.set_scroll(0, 0, 8)
    vsync_pulse()

    set_pixel(0, 0)   # vpos=0 + scroll_y=8 → tile_y=8 → row=1, col=0 → tile_yscroll
    clock_n(8)

    pix = m.get_pixel(0, 0, 0)
    check_pixel(0, pix)   # nybble=0xE, palette=0xC → color=0xCE

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 11: Scroll wrap-around (mod 512)
    # tile at (0,0) cell 0. scroll_x=504 → tile_x=(hpos=8)+504=512≡0 → col=0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_wrap = 0x00C
    write_tile_solid(m, tile_wrap, 0x9)
    write_cell(m, 0, 0, tile_wrap, 0xA)

    write_scroll(0, "x", 504)
    m.set_scroll(0, 504, 0)
    vsync_pulse()

    set_pixel(8, 0)   # tile_x = (8 + 504) & 0x1FF = 512 & 0x1FF = 0 → col=0
    clock_n(8)
    pix = m.get_pixel(0, 8, 0)
    check_pixel(0, pix)   # nybble=9, palette=A → color=0xA9

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 12: Layer 2 and Layer 3 outputs
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    m = GP9001TilemapModel()

    tile_l2 = 0x010
    tile_l3 = 0x011
    write_tile_solid(m, tile_l2, 0x2)
    write_tile_solid(m, tile_l3, 0x4)
    write_cell(m, 2, 0, tile_l2, 0x3)
    write_cell(m, 3, 0, tile_l3, 0x6)

    vsync_pulse()
    set_pixel(0, 0)
    clock_n(8)

    pix2 = m.get_pixel(2, 0, 0)
    pix3 = m.get_pixel(3, 0, 0)
    check_pixel(2, pix2)   # {3, 2}=0x32
    check_pixel(3, pix3)   # {6, 4}=0x64

    # ──────────────────────────────────────────────────────────────────────────
    # Write output
    # ──────────────────────────────────────────────────────────────────────────
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate3: {check_count} checks → {OUT_PATH}")
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
