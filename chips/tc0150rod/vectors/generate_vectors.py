#!/usr/bin/env python3
"""
generate_vectors.py — TC0150ROD test vector generator

Produces JSONL files for each step:
  step1_vectors.jsonl — RAM write/read, CPU byte-enable
  step2_vectors.jsonl — Control word decode, bank select
  step3_vectors.jsonl — Road A/B rendering, priority arbitration
  step4_vectors.jsonl — ROM pre-fetch (tile cache load + render)
  step5_vectors.jsonl — Scanline output, line_priority switching
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from rod_model import (RoadRAM, RoadROM, render_road, lookup_2bpp, pal_color,
                        W, xoffset_for_center, road_center_from_xoffset)

HERE = os.path.dirname(__file__)

def write_jsonl(name, records):
    path = os.path.join(HERE, name)
    with open(path, 'w') as f:
        for r in records:
            f.write(json.dumps(r) + '\n')
    print(f"  {name}: {len(records)} vectors")

def zero_ram():
    return {"op": "zero_ram", "base": 0, "count": 0x1000}

def zero_cache():
    return {"op": "zero_cache"}

# =============================================================================
# Step 1 — RAM write/read, byte enables
# =============================================================================

def gen_step1():
    vecs = []

    # ── Test group 1a: Simple word write and read back ──
    vecs.append(zero_ram())
    test_cases = [
        (0x000, 0x1234),
        (0x001, 0xABCD),
        (0x0FF, 0xFFFF),
        (0x100, 0x5A5A),
        (0x7FF, 0x0001),
        (0x800, 0xDEAD),
        (0xFFE, 0xBEEF),
        (0xFFF, 0xC042),
    ]
    for addr, data in test_cases:
        vecs.append({"op": "ram_write", "addr": addr, "data": data, "be": 3})
        vecs.append({"op": "ram_read",  "addr": addr, "exp": data})

    # ── Test group 1b: Byte-enable upper byte only ──
    vecs.append(zero_ram())
    vecs.append({"op": "ram_write", "addr": 0x010, "data": 0xABCD, "be": 3})
    vecs.append({"op": "ram_write", "addr": 0x010, "data": 0xFF00, "be": 2})
    vecs.append({"op": "ram_read",  "addr": 0x010, "exp": 0xFFCD})

    # ── Test group 1c: Byte-enable lower byte only ──
    vecs.append(zero_ram())
    vecs.append({"op": "ram_write", "addr": 0x020, "data": 0x1234, "be": 3})
    vecs.append({"op": "ram_write", "addr": 0x020, "data": 0x00FF, "be": 1})
    vecs.append({"op": "ram_read",  "addr": 0x020, "exp": 0x12FF})

    # ── Test group 1d: Full range address boundary ──
    vecs.append(zero_ram())
    for addr in [0x000, 0x001, 0x0FE, 0x0FF, 0x7FE, 0x7FF, 0xFFE, 0xFFF]:
        pat = (addr ^ 0xA5A5) & 0xFFFF
        vecs.append({"op": "ram_write", "addr": addr, "data": pat, "be": 3})
        vecs.append({"op": "ram_read",  "addr": addr, "exp": pat})

    # ── Test group 1e: Internal read port ──
    vecs.append(zero_ram())
    vecs.append({"op": "ram_write", "addr": 0x042, "data": 0xCAFE, "be": 3})
    vecs.append({"op": "ram_write", "addr": 0x043, "data": 0xBABE, "be": 3})
    vecs.append({"op": "int_rd",    "addr": 0x042, "exp": 0xCAFE})
    vecs.append({"op": "int_rd",    "addr": 0x043, "exp": 0xBABE})

    write_jsonl("step1_vectors.jsonl", vecs)

# =============================================================================
# Step 2 — Control decode + RAM reader + geometry
# =============================================================================

def make_road_entry(xoffset, clipl_w, clipr_w, tile, colbank,
                    bg_fill_l=False, bg_fill_r=False,
                    pal_offs_l=0, pal_offs_r=0,
                    body_pm=False, body_po=0,
                    clipl_pm=False, clipr_pm=False):
    """Build 4-word road RAM entry."""
    clipr = clipr_w & 0x3ff
    if bg_fill_r:  clipr |= 0x8000
    if pal_offs_r: clipr |= 0x1000
    if clipr_pm:   clipr |= 0x2000

    clipl = clipl_w & 0x3ff
    if bg_fill_l:  clipl |= 0x8000
    if pal_offs_l: clipl |= 0x1000
    if clipl_pm:   clipl |= 0x2000

    body = xoffset & 0x7ff
    body |= (body_po & 3) << 11
    if body_pm: body |= 0x2000

    gfx  = tile & 0x3ff
    gfx |= (colbank & 0x3f) << 10

    return [clipr, clipl, body, gfx]

def gen_step2():
    vecs = []
    ram = RoadRAM()

    # ── Test group 2a: Control word decode with bank select ──
    vecs.append(zero_ram())

    # road_ctrl = 0x0542:
    # ctrl&0x0300=0x0100 → road_A bank: y*4 + 0x400
    # ctrl&0x0c00=0x0400 → road_B bank: y*4 + 0x400
    # bits[7:0]=0x42 → priority_switch_line = 0x42 - y_offs
    road_ctrl = 0x0542
    ram.write16(0xFFF, road_ctrl)
    vecs.append({"op": "ram_write", "addr": 0xFFF, "data": road_ctrl, "be": 3})

    y_offs_test = -1
    ctrl = 0x0542
    road_a_base = (y_offs_test * 4 + ((ctrl & 0x0300) << 2)) & 0xfff
    road_b_base = (y_offs_test * 4 + ((ctrl & 0x0c00) << 0)) & 0xfff

    # Use xoffset that centers road on screen at x=159
    xoff_a = xoffset_for_center(159)
    cl_a, cr_a = 80, 80
    entry_a = make_road_entry(xoff_a, cl_a, cr_a, tile=5, colbank=2)
    for i, w in enumerate(entry_a):
        idx = (road_a_base + 0 * 4 + i) & 0xfff
        ram.write16(idx, w)
        vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})

    entry_b = make_road_entry(xoffset_for_center(159), 40, 40, tile=7, colbank=4)
    for i, w in enumerate(entry_b):
        idx = (road_b_base + 0 * 4 + i) & 0xfff
        ram.write16(idx, w)
        vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})

    road_center_a = road_center_from_xoffset(xoff_a)
    left_edge_a   = road_center_a - cl_a
    right_edge_a  = road_center_a + 1 + cr_a

    vecs.append({
        "op": "check_geometry",
        "vpos": 0,
        "y_offs": y_offs_test,
        "exp_road_a_base": road_a_base,
        "exp_road_b_base": road_b_base,
        "exp_left_edge_a": left_edge_a,
        "exp_right_edge_a": right_edge_a,
        "exp_priority_switch_line": (ctrl & 0xff) - y_offs_test,
    })

    # ── Test group 2b: Different bank selections ──
    for bank_a in range(4):
        for bank_b in range(4):
            vecs.append(zero_ram())
            ctrl2 = (bank_b << 10) | (bank_a << 8) | 0x10
            ram2 = RoadRAM()
            ram2.write16(0xFFF, ctrl2)
            vecs.append({"op": "ram_write", "addr": 0xFFF, "data": ctrl2, "be": 3})
            a_base = (-1 * 4 + ((ctrl2 & 0x0300) << 2)) & 0xfff
            b_base = (-1 * 4 + ((ctrl2 & 0x0c00) << 0)) & 0xfff
            vecs.append({
                "op": "check_ctrl_decode",
                "ctrl": ctrl2,
                "y_offs": -1,
                "exp_road_a_base": a_base,
                "exp_road_b_base": b_base,
                "exp_psl": (ctrl2 & 0xff) - (-1),
            })

    write_jsonl("step2_vectors.jsonl", vecs)

# =============================================================================
# Step 3 — Line renderer
# =============================================================================

def make_solid_tile(pixel_val):
    """256-word tile cache where all pixels are pixel_val (0..3)."""
    b1 = 0xff if (pixel_val & 2) else 0x00
    b0 = 0xff if (pixel_val & 1) else 0x00
    w  = (b1 << 8) | b0
    return [w] * 256

def gen_step3():
    vecs = []

    y_offs = -1
    palette_offs = 0xc0
    road_type = 0
    road_trans = False

    def run_scanline_test(label, vpos, ctrl, entry_a, entry_b,
                          tile_a_cache, tile_b_cache):
        nonlocal vecs
        vecs.append(zero_ram())
        vecs.append(zero_cache())

        ram2 = RoadRAM()
        ram2.write16(0xFFF, ctrl)
        vecs.append({"op": "ram_write", "addr": 0xFFF, "data": ctrl, "be": 3})

        a_base = (y_offs * 4 + ((ctrl & 0x0300) << 2)) & 0xfff
        b_base = (y_offs * 4 + ((ctrl & 0x0c00) << 0)) & 0xfff

        for i, w in enumerate(entry_a):
            idx = (a_base + vpos * 4 + i) & 0xfff
            ram2.write16(idx, w)
            vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})

        for i, w in enumerate(entry_b):
            idx = (b_base + vpos * 4 + i) & 0xfff
            ram2.write16(idx, w)
            vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})

        tile_a = entry_a[3] & 0x3ff
        tile_b = entry_b[3] & 0x3ff
        vecs.append({"op": "load_cache_a", "tile": tile_a, "words": tile_a_cache[:256]})
        vecs.append({"op": "load_cache_b", "tile": tile_b, "words": tile_b_cache[:256]})

        # Populate ROM too (for any ROM-based fetch)
        for i, w in enumerate(tile_a_cache[:256]):
            pass  # no ROM op needed for load_cache_a (cache is pre-loaded)
        for i, w in enumerate(tile_b_cache[:256]):
            pass

        # Get expected scanline from model
        rom2 = RoadROM()
        for i, w in enumerate(tile_a_cache[:256]):
            rom2.write16((tile_a << 8) + i, w)
        for i, w in enumerate(tile_b_cache[:256]):
            rom2.write16((tile_b << 8) + i, w)

        scanline = render_road(ram2, rom2, vpos,
                                y_offs=y_offs, palette_offs=palette_offs,
                                road_type=road_type, road_trans=road_trans)

        vecs.append({"op": "run_scanline", "vpos": vpos, "label": label})

        # Check pixels across full width
        for x in range(0, W, 16):
            vecs.append({
                "op": "check_pixel",
                "x": x,
                "vpos": vpos,
                "exp": scanline[x],
                "label": f"{label} x={x}",
            })

    # ── Test 3a: Road A centered at x=159, solid pixel=1 ──
    xoff_a = xoffset_for_center(159)  # road_center=159
    tile_a = 1
    entry_a = make_road_entry(xoff_a, 80, 80, tile=tile_a, colbank=0)
    entry_b = make_road_entry(xoffset_for_center(159), 0, 0, tile=0, colbank=0)
    run_scanline_test("road_a_solid_1", vpos=20,
                      ctrl=0x0000,
                      entry_a=entry_a, entry_b=entry_b,
                      tile_a_cache=make_solid_tile(1),
                      tile_b_cache=[0] * 256)

    # ── Test 3b: Road A at different center, solid pixel=2 ──
    xoff_a2 = xoffset_for_center(100)  # road_center=100
    entry_a2 = make_road_entry(xoff_a2, 60, 80, tile=tile_a, colbank=3)
    run_scanline_test("road_a_solid_2", vpos=50,
                      ctrl=0x0000,
                      entry_a=entry_a2, entry_b=entry_b,
                      tile_a_cache=make_solid_tile(2),
                      tile_b_cache=[0] * 256)

    # ── Test 3c: Road A + Road B (B in center, A wider) ──
    xoff_c = xoffset_for_center(159)
    entry_a3 = make_road_entry(xoff_c, 80, 80, tile=1, colbank=1)
    entry_b3 = make_road_entry(xoff_c, 30, 30, tile=2, colbank=2)
    run_scanline_test("road_ab_overlay", vpos=80,
                      ctrl=0x0800,  # road_B_en=1
                      entry_a=entry_a3, entry_b=entry_b3,
                      tile_a_cache=make_solid_tile(1),
                      tile_b_cache=make_solid_tile(3))

    # ── Test 3d: Background fill on edges (pixel=0, bg_fill=True) ──
    xoff_d = xoffset_for_center(159)
    entry_a4 = make_road_entry(xoff_d, 60, 60, tile=tile_a, colbank=0,
                                bg_fill_l=True, bg_fill_r=True)
    entry_b4 = make_road_entry(xoff_d, 0, 0, tile=0, colbank=0)
    run_scanline_test("road_a_bgfill", vpos=100,
                      ctrl=0x0000,
                      entry_a=entry_a4, entry_b=entry_b4,
                      tile_a_cache=make_solid_tile(0),
                      tile_b_cache=[0] * 256)

    # ── Test 3e: Priority modifier bits ──
    xoff_e = xoffset_for_center(159)
    entry_a5 = make_road_entry(xoff_e, 80, 80, tile=1, colbank=0, body_pm=True)
    entry_b5 = make_road_entry(xoff_e, 80, 80, tile=2, colbank=1)
    run_scanline_test("road_pri_modifier", vpos=120,
                      ctrl=0x0800,
                      entry_a=entry_a5, entry_b=entry_b5,
                      tile_a_cache=make_solid_tile(1),
                      tile_b_cache=make_solid_tile(2))

    # ── Test 3f: Wide road (edge fill visible on both sides) ──
    xoff_f = xoffset_for_center(159)
    entry_a6 = make_road_entry(xoff_f, 100, 140, tile=1, colbank=2)
    run_scanline_test("road_a_wide", vpos=140,
                      ctrl=0x0000,
                      entry_a=entry_a6, entry_b=entry_b,
                      tile_a_cache=make_solid_tile(3),
                      tile_b_cache=[0] * 256)

    # ── Test 3g: Road offset to left (center at x=50) ──
    xoff_g = xoffset_for_center(50)
    entry_a7 = make_road_entry(xoff_g, 40, 40, tile=1, colbank=0)
    run_scanline_test("road_a_left", vpos=160,
                      ctrl=0x0000,
                      entry_a=entry_a7, entry_b=entry_b,
                      tile_a_cache=make_solid_tile(1),
                      tile_b_cache=[0] * 256)

    # ── Test 3h: Road offset to right (center at x=270) ──
    xoff_h = xoffset_for_center(270)
    entry_a8 = make_road_entry(xoff_h, 40, 40, tile=1, colbank=0)
    run_scanline_test("road_a_right", vpos=180,
                      ctrl=0x0000,
                      entry_a=entry_a8, entry_b=entry_b,
                      tile_a_cache=make_solid_tile(2),
                      tile_b_cache=[0] * 256)

    write_jsonl("step3_vectors.jsonl", vecs)

# =============================================================================
# Step 4 — ROM pre-fetch (tile cache loading via toggle-req/ack)
# =============================================================================

def make_checker_tile(seed=0):
    """Build a non-uniform tile for ROM fetch testing."""
    tile = []
    for i in range(256):
        b1 = 0
        b0 = 0
        for bit in range(8):
            pix = (i * 8 + bit + seed) % 4
            b1 |= ((pix >> 1) & 1) << (7 - bit)
            b0 |= ((pix & 1)      ) << (7 - bit)
        tile.append((b1 << 8) | b0)
    return tile

def gen_step4():
    vecs = []

    y_offs = -1
    palette_offs = 0xc0

    tile_a_id = 10
    tile_b_id = 15
    tile_a_cache = make_checker_tile(0)
    tile_b_cache = make_checker_tile(1)

    # ── Test 4a: Single tile A from ROM ──
    vecs.append(zero_ram())
    vecs.append(zero_cache())

    ram3 = RoadRAM()
    ctrl = 0x0000
    ram3.write16(0xFFF, ctrl)
    vecs.append({"op": "ram_write", "addr": 0xFFF, "data": ctrl, "be": 3})
    vecs.append({"op": "set_rom_tile", "tile": tile_a_id, "words": tile_a_cache})

    a_base = (y_offs * 4 + ((ctrl & 0x0300) << 2)) & 0xfff
    b_base = (y_offs * 4 + ((ctrl & 0x0c00))) & 0xfff

    xoff_4a = xoffset_for_center(159)
    entry_a = make_road_entry(xoff_4a, 100, 100, tile=tile_a_id, colbank=0)
    entry_b_no = make_road_entry(0, 0, 0, tile=0, colbank=0)

    for i, w in enumerate(entry_a):
        idx = (a_base + 30 * 4 + i) & 0xfff
        ram3.write16(idx, w)
        vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})
    for i, w in enumerate(entry_b_no):
        idx = (b_base + 30 * 4 + i) & 0xfff
        ram3.write16(idx, w)
        vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})

    rom3 = RoadROM()
    for i, w in enumerate(tile_a_cache):
        rom3.write16((tile_a_id << 8) + i, w)

    scanline3 = render_road(ram3, rom3, 30, y_offs=y_offs, palette_offs=palette_offs)
    vecs.append({"op": "run_scanline_rom", "vpos": 30, "label": "tile_a_from_rom"})
    for x in range(0, W, 8):
        vecs.append({
            "op": "check_pixel", "x": x, "vpos": 30,
            "exp": scanline3[x], "label": f"rom_fetch x={x}"
        })

    # ── Test 4b: Two different tiles A and B ──
    vecs.append(zero_ram())
    vecs.append(zero_cache())

    ctrl4 = 0x0800
    ram4 = RoadRAM()
    ram4.write16(0xFFF, ctrl4)
    vecs.append({"op": "ram_write", "addr": 0xFFF, "data": ctrl4, "be": 3})
    vecs.append({"op": "set_rom_tile", "tile": tile_a_id, "words": tile_a_cache})
    vecs.append({"op": "set_rom_tile", "tile": tile_b_id, "words": tile_b_cache})

    a_base4 = (y_offs * 4 + ((ctrl4 & 0x0300) << 2)) & 0xfff
    b_base4 = (y_offs * 4 + ((ctrl4 & 0x0c00))) & 0xfff
    xoff_4b = xoffset_for_center(159)
    entry_a4 = make_road_entry(xoff_4b, 100, 100, tile=tile_a_id, colbank=1)
    entry_b4 = make_road_entry(xoff_4b, 50,  50,  tile=tile_b_id, colbank=2)
    for i, w in enumerate(entry_a4):
        idx = (a_base4 + 50 * 4 + i) & 0xfff
        ram4.write16(idx, w)
        vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})
    for i, w in enumerate(entry_b4):
        idx = (b_base4 + 50 * 4 + i) & 0xfff
        ram4.write16(idx, w)
        vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})

    rom4 = RoadROM()
    for i, w in enumerate(tile_a_cache):
        rom4.write16((tile_a_id << 8) + i, w)
    for i, w in enumerate(tile_b_cache):
        rom4.write16((tile_b_id << 8) + i, w)

    scanline4 = render_road(ram4, rom4, 50, y_offs=y_offs, palette_offs=palette_offs)
    vecs.append({"op": "run_scanline_rom", "vpos": 50, "label": "two_tiles_ab"})
    for x in range(0, W, 8):
        vecs.append({
            "op": "check_pixel", "x": x, "vpos": 50,
            "exp": scanline4[x], "label": f"two_tiles x={x}"
        })

    # ── Test 4c: Same tile A and B ──
    vecs.append(zero_ram())
    vecs.append(zero_cache())

    ctrl5 = 0x0800
    ram5 = RoadRAM()
    ram5.write16(0xFFF, ctrl5)
    vecs.append({"op": "ram_write", "addr": 0xFFF, "data": ctrl5, "be": 3})
    vecs.append({"op": "set_rom_tile", "tile": tile_a_id, "words": tile_a_cache})

    a_base5 = (y_offs * 4 + ((ctrl5 & 0x0300) << 2)) & 0xfff
    b_base5 = (y_offs * 4 + ((ctrl5 & 0x0c00))) & 0xfff
    xoff_5 = xoffset_for_center(159)
    entry_a5 = make_road_entry(xoff_5, 80, 80, tile=tile_a_id, colbank=0)
    entry_b5 = make_road_entry(xoff_5, 40, 40, tile=tile_a_id, colbank=1)
    for i, w in enumerate(entry_a5):
        idx = (a_base5 + 60 * 4 + i) & 0xfff
        ram5.write16(idx, w)
        vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})
    for i, w in enumerate(entry_b5):
        idx = (b_base5 + 60 * 4 + i) & 0xfff
        ram5.write16(idx, w)
        vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})

    rom5 = RoadROM()
    for i, w in enumerate(tile_a_cache):
        rom5.write16((tile_a_id << 8) + i, w)

    scanline5 = render_road(ram5, rom5, 60, y_offs=y_offs, palette_offs=palette_offs)
    vecs.append({"op": "run_scanline_rom", "vpos": 60, "label": "same_tile_ab"})
    for x in range(0, W, 8):
        vecs.append({
            "op": "check_pixel", "x": x, "vpos": 60,
            "exp": scanline5[x], "label": f"same_tile x={x}"
        })

    write_jsonl("step4_vectors.jsonl", vecs)

# =============================================================================
# Step 5 — Scanline output (pix_out, pix_valid, pix_transp, line_priority)
# =============================================================================

def gen_step5():
    vecs = []

    y_offs = -1
    palette_offs = 0xc0
    low_pri = 1
    high_pri = 2

    vecs.append(zero_ram())
    vecs.append(zero_cache())

    # priority_switch_line = (road_ctrl & 0xff) - y_offs
    # With road_ctrl[7:0] = 0x80: psl = 0x80 - (-1) = 0x81 = 129
    # vpos=100 <= 129 → low_priority
    # vpos=140 >  129 → high_priority
    road_ctrl = 0x0080
    ram_s = RoadRAM()
    ram_s.write16(0xFFF, road_ctrl)
    vecs.append({"op": "ram_write", "addr": 0xFFF, "data": road_ctrl, "be": 3})

    ctrl = road_ctrl
    a_base = (y_offs * 4 + ((ctrl & 0x0300) << 2)) & 0xfff

    tile_id = 3
    tile_cache = make_solid_tile(2)
    vecs.append({"op": "set_rom_tile", "tile": tile_id, "words": tile_cache})

    xoff_s = xoffset_for_center(159)
    psl = (ctrl & 0xff) - y_offs   # = 0x80 + 1 = 129

    for vpos in [100, 140]:
        entry = make_road_entry(xoff_s, 100, 100, tile=tile_id, colbank=0)
        entry_no = make_road_entry(0, 0, 0, tile=0, colbank=0)
        b_base = a_base
        for i, w in enumerate(entry):
            idx = (a_base + vpos * 4 + i) & 0xfff
            ram_s.write16(idx, w)
            vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})
        for i, w in enumerate(entry_no):
            idx = (b_base + vpos * 4 + i) & 0xfff
            ram_s.write16(idx, w)
            vecs.append({"op": "ram_write", "addr": idx, "data": w, "be": 3})

    rom_s = RoadROM()
    for i, w in enumerate(tile_cache):
        rom_s.write16((tile_id << 8) + i, w)

    for vpos in [100, 140]:
        scanline_s = render_road(ram_s, rom_s, vpos,
                                  y_offs=y_offs, palette_offs=palette_offs)
        expected_line_prio = low_pri if vpos <= psl else high_pri

        vecs.append({
            "op": "run_scanline_rom", "vpos": vpos,
            "label": f"prio_check_vpos{vpos}"
        })
        vecs.append({
            "op": "check_line_priority",
            "vpos": vpos,
            "exp": expected_line_prio,
            "label": f"line_prio vpos={vpos}"
        })
        for x in [0, 80, 159, 240, 319]:
            pw = scanline_s[x]
            is_transp = bool(pw & 0x8000) or (pw & 0x7fff) == 0x7000
            vecs.append({
                "op": "check_pix_transp",
                "x": x, "vpos": vpos,
                "exp_transp": int(is_transp),
                "exp_pix": pw & 0x7fff,
                "label": f"transp vpos={vpos} x={x}"
            })

    write_jsonl("step5_vectors.jsonl", vecs)

# =============================================================================
# Main
# =============================================================================

if __name__ == "__main__":
    print("Generating TC0150ROD test vectors...")
    gen_step1()
    gen_step2()
    gen_step3()
    gen_step4()
    gen_step5()
    print("Done.")
