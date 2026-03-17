#!/usr/bin/env python3
"""
generate_gate3.py — NMK16 Gate 3 test vector generator.

Produces gate3_vectors.jsonl covering:

  1.  Single 16×16 sprite, solid fill, scanline match (Y hit)
  2.  Single 16×16 sprite, scanline miss (Y does not hit)
  3.  Transparent sprite — all nybble=0, no valid pixels
  4.  flip_x — pixel order reversed within sprite
  5.  flip_y — row order reversed within sprite
  6.  32×32 multi-tile sprite (size=1, 2×2 tiles)
  7.  Multiple sprites on same scanline — later sprite overwrites earlier
  8.  Sprite at right screen edge (x=304, width=16 → x=304..319)
  9.  64×64 multi-tile sprite (size=2, 4×4 tiles) — spot check columns

Target: 50+ checks.

Vector operations (processed by tb_gate3.cpp):
  reset                   — DUT reset
  vblank_scan             — run Gate 2 VBLANK scan to build display_list
  write_sram  addr, data  — write sprite RAM word (word index)
  write_spr_rom addr, data — write one byte into testbench sprite ROM
  scan_line   scanline    — pulse scan_trigger for scanline, wait spr_render_done
  check_spr   x, exp_valid, exp_color — check pixel at screen X

NMK16 sprite RAM word layout (word index = sprite_idx*4 + word_offset):
  Word 0: Y position [8:0]  — 0x1FF = inactive sentinel
  Word 1: X position [8:0]
  Word 2: Tile code  [11:0]
  Word 3: Attributes
    [7:4]   palette[3:0]
    [9]     flip_y
    [10]    flip_x
    [15:14] size[1:0]
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate3_model import SpriteROM, NMK16SpriteEntry, NMK16SpriteRasterizer

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate3_vectors.jsonl')

Y_NULL = 0x1FF   # inactive sentinel


# ─────────────────────────────────────────────────────────────────────────────
# Word builders
# ─────────────────────────────────────────────────────────────────────────────

def make_sprite_words(y: int, x: int, tile_code: int,
                      flip_x: bool, flip_y: bool,
                      palette: int, size: int):
    """Return (w0, w1, w2, w3) for one NMK16 sprite RAM entry."""
    w0 = y & 0x1FF
    w1 = x & 0x1FF
    w2 = tile_code & 0x0FFF
    w3 = ((palette & 0xF) << 4) | (int(flip_y) << 9) | (int(flip_x) << 10) | ((size & 0x3) << 14)
    return w0, w1, w2, w3


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

    def write_sram(addr: int, data: int):
        add({"op": "write_sram", "addr": addr, "data": data})

    def write_spr_rom(addr: int, data: int):
        add({"op": "write_spr_rom", "addr": addr, "data": data})

    def vblank_scan():
        add({"op": "vblank_scan"})

    def scan_line(scanline: int):
        add({"op": "scan_line", "scanline": scanline})

    def check_spr(x: int, exp_valid: int, exp_color: int):
        chk({"op": "check_spr", "x": x,
             "exp_valid": exp_valid, "exp_color": exp_color})

    def null_sprite(slot: int):
        """Write inactive sentinel to sprite slot."""
        base = slot * 4
        write_sram(base + 0, Y_NULL)
        write_sram(base + 1, 0)
        write_sram(base + 2, 0)
        write_sram(base + 3, 0)

    def write_sprite(slot: int, y: int, x: int, tile_code: int,
                     flip_x: bool, flip_y: bool, palette: int, size: int):
        w0, w1, w2, w3 = make_sprite_words(y, x, tile_code, flip_x, flip_y, palette, size)
        base = slot * 4
        write_sram(base + 0, w0)
        write_sram(base + 1, w1)
        write_sram(base + 2, w2)
        write_sram(base + 3, w3)

    def load_solid_tile(rom: SpriteROM, tile_code: int, nybble: int):
        """Write solid-fill tile to both DUT ROM and model."""
        byte_val = (nybble << 4) | nybble
        base = tile_code * 128
        for b in range(128):
            write_spr_rom(base + b, byte_val)
        rom.load_solid_tile(tile_code, nybble)

    def load_tile_row(rom: SpriteROM, tile_code: int, row: int, nybbles: list):
        """Write one tile row to both DUT ROM and model."""
        assert len(nybbles) == 16
        base = tile_code * 128 + row * 8
        for b in range(8):
            lo = nybbles[b * 2]
            hi = nybbles[b * 2 + 1]
            write_spr_rom(base + b, (hi << 4) | lo)
        rom.load_tile_row(tile_code, row, nybbles)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 1: Single 16×16 sprite, solid fill, scanline hit and miss
    # Sprite at (x=10, y=20), tile=1, palette=3, size=0, nybble=0x5
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    load_solid_tile(rom, 1, 0x5)

    for s in range(32):
        null_sprite(s)
    write_sprite(0, y=20, x=10, tile_code=1, flip_x=False, flip_y=False, palette=3, size=0)

    vblank_scan()

    spr = NMK16SpriteEntry(x=10, y=20, tile_code=1, palette=3, size=0, valid=True)
    dl  = [spr] + [NMK16SpriteEntry() for _ in range(255)]

    # Scanline 20 — top row of sprite
    scan_line(20)
    buf = rast.render_scanline(dl, 1, current_y=20)

    check_spr(9,  0, 0)                                      # before sprite
    for x in [10, 15, 20, 25]:
        p = buf[x]
        check_spr(x, int(p.valid), p.color)
    check_spr(26, 0, 0)                                      # after sprite

    # Scanline 35 — last row of sprite
    scan_line(35)
    buf35 = rast.render_scanline(dl, 1, current_y=35)
    check_spr(10, int(buf35[10].valid), buf35[10].color)
    check_spr(25, int(buf35[25].valid), buf35[25].color)

    # Scanline 36 — just past sprite bottom → no sprite
    scan_line(36)
    check_spr(10, 0, 0)

    # Scanline 19 — just above sprite → no sprite
    scan_line(19)
    check_spr(10, 0, 0)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 2: Transparent sprite — all nybble=0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    load_solid_tile(rom, 2, 0x0)

    for s in range(32):
        null_sprite(s)
    write_sprite(0, y=10, x=0, tile_code=2, flip_x=False, flip_y=False, palette=7, size=0)

    vblank_scan()
    scan_line(10)

    spr2 = NMK16SpriteEntry(x=0, y=10, tile_code=2, palette=7, size=0, valid=True)
    dl2  = [spr2] + [NMK16SpriteEntry() for _ in range(255)]
    rast.render_scanline(dl2, 1, current_y=10)

    for x in [0, 8, 15]:
        check_spr(x, 0, 0)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 3: flip_x
    # Tile row 0: pixels [1,2,3,4,5,6,7,8,9,A,B,C,D,E,F,1]
    # flip_x=True: screen px 0 gets sprite px 15 = nybble 1 → color {1,1}=0x11
    #              screen px 1 gets sprite px 14 = nybble F → color {1,F}=0x1F
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    row0_nybs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
    for r in range(16):
        load_tile_row(rom, 3, r, row0_nybs)

    for s in range(32):
        null_sprite(s)
    write_sprite(0, y=0, x=0, tile_code=3, flip_x=True, flip_y=False, palette=1, size=0)

    vblank_scan()
    scan_line(0)

    spr3 = NMK16SpriteEntry(x=0, y=0, tile_code=3, palette=1, size=0, flip_x=True, valid=True)
    dl3  = [spr3] + [NMK16SpriteEntry() for _ in range(255)]
    buf3 = rast.render_scanline(dl3, 1, current_y=0)

    check_spr(0,  int(buf3[0].valid),  buf3[0].color)    # 0x11
    check_spr(1,  int(buf3[1].valid),  buf3[1].color)    # 0x1F
    check_spr(14, int(buf3[14].valid), buf3[14].color)   # 0x12
    check_spr(15, int(buf3[15].valid), buf3[15].color)   # 0x11

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 4: flip_y
    # Tile: row 0 all-nybble 0xA, row 15 all-nybble 0xB
    # flip_y=True: scanline y=0 sees row 15 (nybble B) → color 0x2B
    #              scanline y=15 sees row 0  (nybble A) → color 0x2A
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    load_tile_row(rom, 4, 0,  [0xA] * 16)
    load_tile_row(rom, 4, 15, [0xB] * 16)
    for r in range(1, 15):
        load_tile_row(rom, 4, r, [0x9] * 16)

    for s in range(32):
        null_sprite(s)
    write_sprite(0, y=0, x=0, tile_code=4, flip_x=False, flip_y=True, palette=2, size=0)

    vblank_scan()

    spr4 = NMK16SpriteEntry(x=0, y=0, tile_code=4, palette=2, size=0, flip_y=True, valid=True)
    dl4  = [spr4] + [NMK16SpriteEntry() for _ in range(255)]

    scan_line(0)
    buf4a = rast.render_scanline(dl4, 1, current_y=0)
    check_spr(0, int(buf4a[0].valid), buf4a[0].color)    # 0x2B

    scan_line(15)
    buf4b = rast.render_scanline(dl4, 1, current_y=15)
    check_spr(0, int(buf4b[0].valid), buf4b[0].color)    # 0x2A

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 5: 32×32 multi-tile sprite (size=1, 2×2 tiles)
    # tile_code=10: [10]=TL(nybble 1), [11]=TR(2), [12]=BL(3), [13]=BR(4)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    load_solid_tile(rom, 10, 0x1)   # top-left
    load_solid_tile(rom, 11, 0x2)   # top-right
    load_solid_tile(rom, 12, 0x3)   # bottom-left
    load_solid_tile(rom, 13, 0x4)   # bottom-right

    for s in range(32):
        null_sprite(s)
    write_sprite(0, y=0, x=0, tile_code=10, flip_x=False, flip_y=False, palette=5, size=1)

    vblank_scan()

    spr5 = NMK16SpriteEntry(x=0, y=0, tile_code=10, palette=5, size=1, valid=True)
    dl5  = [spr5] + [NMK16SpriteEntry() for _ in range(255)]

    # Scanline 0 → top tiles
    scan_line(0)
    buf5a = rast.render_scanline(dl5, 1, current_y=0)
    check_spr(0,  int(buf5a[0].valid),  buf5a[0].color)   # 0x51
    check_spr(16, int(buf5a[16].valid), buf5a[16].color)  # 0x52
    check_spr(31, int(buf5a[31].valid), buf5a[31].color)  # 0x52
    chk({"op": "check_spr", "x": 32, "exp_valid": 0, "exp_color": 0})

    # Scanline 16 → bottom tiles
    scan_line(16)
    buf5b = rast.render_scanline(dl5, 1, current_y=16)
    check_spr(0,  int(buf5b[0].valid),  buf5b[0].color)   # 0x53
    check_spr(16, int(buf5b[16].valid), buf5b[16].color)  # 0x54

    # Scanline 32 → past sprite bottom → transparent
    scan_line(32)
    chk({"op": "check_spr", "x": 0, "exp_valid": 0, "exp_color": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 6: Multiple sprites on same scanline — later overwrites earlier
    # Sprite 0: x=0, tile=20, palette=1, nybble=0x6
    # Sprite 1: x=8, tile=21, palette=2, nybble=0xA (overlaps at x=8..15)
    # At x=8..15: sprite 1 (drawn after) wins
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    load_solid_tile(rom, 20, 0x6)
    load_solid_tile(rom, 21, 0xA)

    for s in range(32):
        null_sprite(s)
    write_sprite(0, y=0, x=0,  tile_code=20, flip_x=False, flip_y=False, palette=1, size=0)
    write_sprite(1, y=0, x=8,  tile_code=21, flip_x=False, flip_y=False, palette=2, size=0)

    vblank_scan()
    scan_line(0)

    spr6a = NMK16SpriteEntry(x=0, y=0, tile_code=20, palette=1, size=0, valid=True)
    spr6b = NMK16SpriteEntry(x=8, y=0, tile_code=21, palette=2, size=0, valid=True)
    dl6   = [spr6a, spr6b] + [NMK16SpriteEntry() for _ in range(254)]
    buf6  = rast.render_scanline(dl6, 2, current_y=0)

    check_spr(0,  int(buf6[0].valid),  buf6[0].color)   # 0x16 (sprite 0)
    check_spr(7,  int(buf6[7].valid),  buf6[7].color)   # 0x16 (sprite 0)
    check_spr(8,  int(buf6[8].valid),  buf6[8].color)   # 0x2A (sprite 1 overwrites)
    check_spr(15, int(buf6[15].valid), buf6[15].color)  # 0x2A (sprite 1)
    check_spr(16, int(buf6[16].valid), buf6[16].color)  # 0x2A (sprite 1 extends to x=23)
    check_spr(23, int(buf6[23].valid), buf6[23].color)  # 0x2A
    chk({"op": "check_spr", "x": 24, "exp_valid": 0, "exp_color": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 7: Sprite at right screen edge (x=304, width=16 → x=304..319)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    load_solid_tile(rom, 30, 0xC)

    for s in range(32):
        null_sprite(s)
    write_sprite(0, y=0, x=304, tile_code=30, flip_x=False, flip_y=False, palette=6, size=0)

    vblank_scan()
    scan_line(0)

    spr7 = NMK16SpriteEntry(x=304, y=0, tile_code=30, palette=6, size=0, valid=True)
    dl7  = [spr7] + [NMK16SpriteEntry() for _ in range(255)]
    buf7 = rast.render_scanline(dl7, 1, current_y=0)

    check_spr(304, int(buf7[304].valid), buf7[304].color)  # valid
    check_spr(319, int(buf7[319].valid), buf7[319].color)  # last pixel — valid
    chk({"op": "check_spr", "x": 303, "exp_valid": 0, "exp_color": 0})  # before sprite

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 8: 64×64 sprite (size=2, 4×4 tiles)
    # Base tile=40; col 0=nybble 1, col 1=nybble 2, col 2=nybble 3, col 3=nybble 4
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom  = SpriteROM()
    rast = NMK16SpriteRasterizer(rom)

    for tr in range(4):
        for tc in range(4):
            nybble = tc + 1   # 1..4 per column
            load_solid_tile(rom, 40 + tr * 4 + tc, nybble)

    for s in range(32):
        null_sprite(s)
    write_sprite(0, y=0, x=0, tile_code=40, flip_x=False, flip_y=False, palette=9, size=2)

    vblank_scan()
    scan_line(0)

    spr8 = NMK16SpriteEntry(x=0, y=0, tile_code=40, palette=9, size=2, valid=True)
    dl8  = [spr8] + [NMK16SpriteEntry() for _ in range(255)]
    buf8 = rast.render_scanline(dl8, 1, current_y=0)

    check_spr(0,  int(buf8[0].valid),  buf8[0].color)   # col 0: {9,1}=0x91
    check_spr(16, int(buf8[16].valid), buf8[16].color)  # col 1: {9,2}=0x92
    check_spr(32, int(buf8[32].valid), buf8[32].color)  # col 2: {9,3}=0x93
    check_spr(48, int(buf8[48].valid), buf8[48].color)  # col 3: {9,4}=0x94
    check_spr(63, int(buf8[63].valid), buf8[63].color)  # last pixel col 3
    chk({"op": "check_spr", "x": 64, "exp_valid": 0, "exp_color": 0})

    # ── Write output ──────────────────────────────────────────────────────────
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate3: {check_count} checks → {OUT_PATH}")
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
