#!/usr/bin/env python3
"""
generate_gate4.py — Gate4 integration test vector generator.

Produces gate4_integration_vectors.jsonl with 5 test cases:
  1. Simple sprite: single 16×16 sprite at center
  2. Multi-sprite: 2 overlapping sprites with priority
  3. Clipped sprite: sprite at screen edge
  4. Palette check: sprite with color attribute
  5. Transparent pixels: sprite with pen=0 pixels, BG underneath

Each vector contains:
  - Setup ops: yram_write, cram_write, ctrl_write, load_gfx_word, palette_write
  - Execution: render_frame
  - Validation: check_pixel ops with expected (r, g, b) tuples

Output format: JSONL (one JSON object per line).
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate4_model import Gate4Model, SCREEN_H, SCREEN_W, FG_NOFLIP_YOFFS

VEC_DIR = os.path.dirname(os.path.abspath(__file__))


def w(f, obj):
    """Write JSON object as one line."""
    f.write(json.dumps(obj) + '\n')


def raw_y_for_screen_y(screen_y_top, yoffs=FG_NOFLIP_YOFFS, screen_h=SCREEN_H):
    """Compute raw Y byte so that sprite top row is at screen_y_top."""
    return (screen_h - screen_y_top - yoffs) & 0xFF


def gen_gate4():
    """Generate gate4 integration test vectors."""
    m = Gate4Model(color_base=0)
    recs = []

    # ─────────────────────────────────────────────────────────────────────────────
    # Test 1: Simple sprite at center
    # ─────────────────────────────────────────────────────────────────────────────
    print("Generating gate4 test 1: Simple sprite...")

    recs.append({"op": "reset"})
    m.reset()

    # Load tile 1: solid color 7 (all 16×16 pixels = nibble 7)
    tile_1_code = 1
    for row in range(16):
        for wrd in range(4):
            addr = tile_1_code * 64 + row * 4 + wrd
            data = 0x7777  # all nibbles = 7
            recs.append({"op": "load_gfx_word", "addr": addr, "data": data})
            m.load_gfx_word(addr, data)

    # Set palette: color_idx[5:0]_pen[3:0]
    # For sprite color=5, pen=7: palette address = 5*16 + 7 = 87
    # Set to cyan xRGB_555: R=0, G=31, B=31 = 0x03FF
    pal_addr_1 = 5 * 16 + 7
    recs.append({"op": "palette_write", "addr": pal_addr_1, "data": 0x03FF, "be": 3})
    m.palette_write(pal_addr_1, 0x03FF, be=3)

    # Set control: no flip, frame_bank=0
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x00, "be": 1})
    recs.append({"op": "ctrl_write", "addr": 1, "data": 0x40, "be": 1})
    m.ctrl_write(0, 0x00, be=1)
    m.ctrl_write(1, 0x40, be=1)

    # Sprite 0: tile=1, color=5, sx=100, sy_raw=~100 (top row at y=112)
    sx_1 = 100
    sy_top_1 = 112
    sy_raw_1 = raw_y_for_screen_y(sy_top_1)
    recs.append({"op": "cram_write", "addr": 0, "data": tile_1_code, "be": 3})
    recs.append({"op": "cram_write", "addr": 0x200, "data": (5 << 11) | sx_1, "be": 3})
    recs.append({"op": "yram_write", "addr": 0, "data": sy_raw_1, "be": 1})
    m.cram_write(0, tile_1_code, be=3)
    m.cram_write(0x200, (5 << 11) | sx_1, be=3)
    m.yram_write(0, sy_raw_1, be=1)

    # Render
    recs.append({"op": "render_frame"})
    m.render_frame()

    # Check top-left, center, and bottom-right pixels of sprite
    # Sprite covers sx_1..sx_1+15, sy_top_1..sy_top_1+15
    for dx, dy in [(0, 0), (8, 8), (15, 15)]:
        px = sx_1 + dx
        py = sy_top_1 + dy
        rgb = m.get_pixel_rgb(px, py)
        if rgb:
            r, g, b = rgb
            recs.append({"op": "check_pixel", "x": px, "y": py,
                         "exp_r": r, "exp_g": g, "exp_b": b})
        else:
            print(f"  Warning: pixel at ({px}, {py}) is None")

    # ─────────────────────────────────────────────────────────────────────────────
    # Test 2: Multi-sprite with priority
    # ─────────────────────────────────────────────────────────────────────────────
    print("Generating gate4 test 2: Multi-sprite priority...")

    recs.append({"op": "reset"})
    m.reset()

    # Load tiles: tile 1 (solid 7), tile 2 (solid 11)
    for tid, nibble in [(1, 7), (2, 11)]:
        word = (nibble << 12) | (nibble << 8) | (nibble << 4) | nibble
        for row in range(16):
            for wrd in range(4):
                addr = tid * 64 + row * 4 + wrd
                recs.append({"op": "load_gfx_word", "addr": addr, "data": word})
                m.load_gfx_word(addr, word)

    # Palette: color 3 → red, color 4 → blue
    # Color 3, pen 7: palette addr = 3*16 + 7 = 55 → red (R=31, G=0, B=0)
    # Color 4, pen 11: palette addr = 4*16 + 11 = 75 → blue (R=0, G=0, B=31)
    recs.append({"op": "palette_write", "addr": 55, "data": 0x7C00, "be": 3})
    recs.append({"op": "palette_write", "addr": 75, "data": 0x001F, "be": 3})
    m.palette_write(55, 0x7C00, be=3)  # Red
    m.palette_write(75, 0x001F, be=3)  # Blue

    # Control
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x00, "be": 1})
    recs.append({"op": "ctrl_write", "addr": 1, "data": 0x40, "be": 1})
    m.ctrl_write(0, 0x00, be=1)
    m.ctrl_write(1, 0x40, be=1)

    # Sprite 0 (high priority): tile 1, color 3, at (50, 100)
    sx_2a = 50
    sy_top_2a = 100
    sy_raw_2a = raw_y_for_screen_y(sy_top_2a)
    recs.append({"op": "cram_write", "addr": 0, "data": 1, "be": 3})
    recs.append({"op": "cram_write", "addr": 0x200, "data": (3 << 11) | sx_2a, "be": 3})
    recs.append({"op": "yram_write", "addr": 0, "data": sy_raw_2a, "be": 1})
    m.cram_write(0, 1, be=3)
    m.cram_write(0x200, (3 << 11) | sx_2a, be=3)
    m.yram_write(0, sy_raw_2a, be=1)

    # Sprite 1 (lower priority): tile 2, color 4, at (60, 105) — overlaps sprite 0
    sx_2b = 60
    sy_top_2b = 105
    sy_raw_2b = raw_y_for_screen_y(sy_top_2b)
    recs.append({"op": "cram_write", "addr": 1, "data": 2, "be": 3})
    recs.append({"op": "cram_write", "addr": 0x201, "data": (4 << 11) | sx_2b, "be": 3})
    recs.append({"op": "yram_write", "addr": 0, "data": (sy_raw_2b << 8), "be": 2})
    m.cram_write(1, 2, be=3)
    m.cram_write(0x201, (4 << 11) | sx_2b, be=3)
    m.yram_write(0, (sy_raw_2b << 8), be=2)

    # Render
    recs.append({"op": "render_frame"})
    m.render_frame()

    # Check overlap region: should see sprite 0's color (higher priority)
    overlap_x = max(sx_2a, sx_2b)
    overlap_y = max(sy_top_2a, sy_top_2b)
    if overlap_x < min(sx_2a + 16, sx_2b + 16) and overlap_y < min(sy_top_2a + 16, sy_top_2b + 16):
        rgb = m.get_pixel_rgb(overlap_x, overlap_y)
        if rgb:
            r, g, b = rgb
            recs.append({"op": "check_pixel", "x": overlap_x, "y": overlap_y,
                         "exp_r": r, "exp_g": g, "exp_b": b})

    # ─────────────────────────────────────────────────────────────────────────────
    # Test 3: Clipped sprite (screen edge)
    # ─────────────────────────────────────────────────────────────────────────────
    print("Generating gate4 test 3: Clipped sprite...")

    recs.append({"op": "reset"})
    m.reset()

    # Load tile 3: gradient (row r → color r+1)
    for row in range(16):
        nibble = (row + 1) & 0xF
        word = (nibble << 12) | (nibble << 8) | (nibble << 4) | nibble
        for wrd in range(4):
            addr = 3 * 64 + row * 4 + wrd
            recs.append({"op": "load_gfx_word", "addr": addr, "data": word})
            m.load_gfx_word(addr, word)

    # Palette: each color 0..15 to unique shade
    for c in range(16):
        pal_addr = c * 16 + 8  # pen=8
        # Create gradient: brighter for higher color
        gray = (c * 2) & 0x1F
        rgb_word = (gray << 10) | (gray << 5) | gray  # gray xRGB_555
        recs.append({"op": "palette_write", "addr": pal_addr, "data": rgb_word, "be": 3})
        m.palette_write(pal_addr, rgb_word, be=3)

    # Control
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x00, "be": 1})
    recs.append({"op": "ctrl_write", "addr": 1, "data": 0x40, "be": 1})
    m.ctrl_write(0, 0x00, be=1)
    m.ctrl_write(1, 0x40, be=1)

    # Sprite at left edge: sx = -4 (clipped)
    sx_3 = SCREEN_W - 8  # right edge, clipped
    sy_top_3 = 50
    sy_raw_3 = raw_y_for_screen_y(sy_top_3)
    recs.append({"op": "cram_write", "addr": 0, "data": 3, "be": 3})
    recs.append({"op": "cram_write", "addr": 0x200, "data": (7 << 11) | (sx_3 & 0x1FF), "be": 3})
    recs.append({"op": "yram_write", "addr": 0, "data": sy_raw_3, "be": 1})
    m.cram_write(0, 3, be=3)
    m.cram_write(0x200, (7 << 11) | (sx_3 & 0x1FF), be=3)
    m.yram_write(0, sy_raw_3, be=1)

    # Render
    recs.append({"op": "render_frame"})
    m.render_frame()

    # Check visible pixels near the edge
    if sx_3 + 8 < SCREEN_W:
        rgb = m.get_pixel_rgb(sx_3 + 8, sy_top_3)
        if rgb:
            r, g, b = rgb
            recs.append({"op": "check_pixel", "x": sx_3 + 8, "y": sy_top_3,
                         "exp_r": r, "exp_g": g, "exp_b": b})

    # ─────────────────────────────────────────────────────────────────────────────
    # Test 4: Palette check
    # ─────────────────────────────────────────────────────────────────────────────
    print("Generating gate4 test 4: Palette check...")

    recs.append({"op": "reset"})
    m.reset()

    # Load tile 4: striped (each column = column number)
    stripe_colors = [i + 1 for i in range(16)]
    for row in range(16):
        for wrd in range(4):
            word = 0
            for n in range(4):
                px = wrd * 4 + n
                word = (word << 4) | stripe_colors[px]
            addr = 4 * 64 + row * 4 + wrd
            recs.append({"op": "load_gfx_word", "addr": addr, "data": word})
            m.load_gfx_word(addr, word)

    # Palette: each color to distinct RGB
    colors_lut = [
        (0, 0, 0),      # 0: black
        (31, 0, 0),     # 1: red
        (0, 31, 0),     # 2: green
        (0, 0, 31),     # 3: blue
        (31, 31, 0),    # 4: yellow
        (31, 0, 31),    # 5: magenta
        (0, 31, 31),    # 6: cyan
        (31, 31, 31),   # 7: white
        # ... rest default
    ]
    for pen in range(16):
        for color in range(8):
            pal_addr = color * 16 + pen
            if color < len(colors_lut):
                r, g, b = colors_lut[color]
            else:
                r = g = b = 0
            rgb_word = (r << 10) | (g << 5) | b
            recs.append({"op": "palette_write", "addr": pal_addr, "data": rgb_word, "be": 3})
            m.palette_write(pal_addr, rgb_word, be=3)

    # Control
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x00, "be": 1})
    recs.append({"op": "ctrl_write", "addr": 1, "data": 0x40, "be": 1})
    m.ctrl_write(0, 0x00, be=1)
    m.ctrl_write(1, 0x40, be=1)

    # Sprite: tile 4, color 2 (green palette), at (80, 80)
    sx_4 = 80
    sy_top_4 = 80
    sy_raw_4 = raw_y_for_screen_y(sy_top_4)
    recs.append({"op": "cram_write", "addr": 0, "data": 4, "be": 3})
    recs.append({"op": "cram_write", "addr": 0x200, "data": (2 << 11) | sx_4, "be": 3})
    recs.append({"op": "yram_write", "addr": 0, "data": sy_raw_4, "be": 1})
    m.cram_write(0, 4, be=3)
    m.cram_write(0x200, (2 << 11) | sx_4, be=3)
    m.yram_write(0, sy_raw_4, be=1)

    # Render
    recs.append({"op": "render_frame"})
    m.render_frame()

    # Check striped pixels (should vary by column)
    for col in range(0, 16, 4):
        px = sx_4 + col
        py = sy_top_4
        rgb = m.get_pixel_rgb(px, py)
        if rgb:
            r, g, b = rgb
            recs.append({"op": "check_pixel", "x": px, "y": py,
                         "exp_r": r, "exp_g": g, "exp_b": b})

    # ─────────────────────────────────────────────────────────────────────────────
    # Test 5: Transparent pixels (pen=0)
    # ─────────────────────────────────────────────────────────────────────────────
    print("Generating gate4 test 5: Transparent pixels...")

    recs.append({"op": "reset"})
    m.reset()

    # Load tile 5: checkerboard (alternating pen=0 and pen=15)
    for row in range(16):
        for wrd in range(4):
            word = 0
            for n in range(4):
                px = wrd * 4 + n
                pen = 15 if ((row + px) & 1) else 0  # checkerboard
                word = (word << 4) | pen
            addr = 5 * 64 + row * 4 + wrd
            recs.append({"op": "load_gfx_word", "addr": addr, "data": word})
            m.load_gfx_word(addr, word)

    # Palette: pen 15 = bright magenta
    pal_addr = 6 * 16 + 15
    recs.append({"op": "palette_write", "addr": pal_addr, "data": 0x7C1F, "be": 3})
    m.palette_write(pal_addr, 0x7C1F, be=3)  # Magenta

    # Control
    recs.append({"op": "ctrl_write", "addr": 0, "data": 0x00, "be": 1})
    recs.append({"op": "ctrl_write", "addr": 1, "data": 0x40, "be": 1})
    m.ctrl_write(0, 0x00, be=1)
    m.ctrl_write(1, 0x40, be=1)

    # Sprite: tile 5, color 6, at (120, 120)
    sx_5 = 120
    sy_top_5 = 120
    sy_raw_5 = raw_y_for_screen_y(sy_top_5)
    recs.append({"op": "cram_write", "addr": 0, "data": 5, "be": 3})
    recs.append({"op": "cram_write", "addr": 0x200, "data": (6 << 11) | sx_5, "be": 3})
    recs.append({"op": "yram_write", "addr": 0, "data": sy_raw_5, "be": 1})
    m.cram_write(0, 5, be=3)
    m.cram_write(0x200, (6 << 11) | sx_5, be=3)
    m.yram_write(0, sy_raw_5, be=1)

    # Render
    recs.append({"op": "render_frame"})
    m.render_frame()

    # Check checkerboard: even pixels should show magenta, odd pixels should be transparent (BG)
    for row in range(0, 16, 2):
        for col in range(0, 16, 2):
            px = sx_5 + col
            py = sy_top_5 + row
            rgb = m.get_pixel_rgb(px, py)
            if rgb:
                r, g, b = rgb
                recs.append({"op": "check_pixel", "x": px, "y": py,
                             "exp_r": r, "exp_g": g, "exp_b": b})

    # ─────────────────────────────────────────────────────────────────────────────
    # Write output file
    # ─────────────────────────────────────────────────────────────────────────────

    path = os.path.join(VEC_DIR, 'gate4_integration_vectors.jsonl')
    with open(path, 'w') as f:
        for r in recs:
            w(f, r)

    checks = sum(1 for r in recs if r.get('op') == 'check_pixel')
    print(f"gate4_integration: {checks} pixel checks → {path}")


if __name__ == '__main__':
    gen_gate4()
