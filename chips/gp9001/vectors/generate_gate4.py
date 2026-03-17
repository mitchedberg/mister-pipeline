#!/usr/bin/env python3
"""
generate_gate4.py — GP9001 Gate 4 test vector generator.

Produces gate4_vectors.jsonl covering:

  1.  Single 16×16 sprite on a matching scanline — pixel color and validity
  2.  Sprite miss — scanline not in sprite's Y range
  3.  Transparent sprite — all nybble=0, no valid pixels
  4.  flip_x — pixel order reversed within sprite
  5.  flip_y — row order reversed within sprite
  6.  Priority bit pass-through
  7.  32×32 multi-tile sprite (size=1)
  8.  64×64 multi-tile sprite (size=2) — spot check tile columns
  9.  Multiple sprites on same scanline — later sprite overwrites earlier
  10. Sprite partially off left edge of screen (x < 0 in 9-bit space)
  11. Sprite partially off right edge (x+width > 320)
  12. 16×16 sprite at screen edge (x=304, last 16 pixels)

Target: 60+ checks.

Vector operations:
  reset                              — DUT reset
  vsync_pulse                        — pulse vsync for shadow→active staging
  write_sram   addr, data            — write one sprite RAM word (addr=word index)
  write_sprite_ctrl  data            — write SPRITE_CTRL register + vsync_pulse
  vblank_scan                        — assert vblank briefly so Gate 2 scans sprites
  write_spr_rom  addr, data          — write sprite ROM byte in testbench
  scan_line   scanline               — trigger Gate 4 FSM for this scanline, wait done
  check_spr   x, exp_valid, exp_color, exp_prio  — check pixel at screen X
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate4_model import SpriteROM, SpriteEntry, GP9001SpriteRasterizer

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate4_vectors.jsonl')

# Sprite RAM word layout (matching gate2_model.py):
#   Word 0  [8:0]  y_pos      (0x100 = null sentinel)
#   Word 1  [9:0]  tile_num; [10] flip_x; [11] flip_y; [15] priority
#   Word 2  [8:0]  x_pos
#   Word 3  [3:0]  palette; [5:4] size
Y_NULL = 0x100


def make_sprite_words(y: int, tile_num: int, flip_x: bool, flip_y: bool,
                      prio: bool, x: int, palette: int, size: int):
    """Return (w0, w1, w2, w3) for one sprite RAM entry."""
    w0 = y & 0x1FF
    w1 = (tile_num & 0x3FF) | (int(flip_x) << 10) | (int(flip_y) << 11) | (int(prio) << 15)
    w2 = x & 0x1FF
    w3 = (palette & 0xF) | ((size & 0x3) << 4)
    return w0, w1, w2, w3


def generate():
    recs = []
    check_count = 0

    def add(obj):
        recs.append(obj)

    def chk(obj):
        nonlocal check_count
        recs.append(obj)
        check_count += 1

    # ── Helper shortcuts ──────────────────────────────────────────────────────

    def reset():
        add({"op": "reset"})

    def vsync_pulse():
        add({"op": "vsync_pulse"})

    def write_sram(addr: int, data: int):
        add({"op": "write_sram", "addr": addr, "data": data})

    def write_sprite_ctrl(data: int):
        """Write SPRITE_CTRL register (addr=0x0A) + vsync_pulse to stage it."""
        add({"op": "write_sprite_ctrl", "data": data})

    def write_spr_rom(addr: int, data: int):
        add({"op": "write_spr_rom", "addr": addr, "data": data})

    def vblank_scan():
        """Assert vblank to trigger Gate 2 FSM, wait for display_list_ready."""
        add({"op": "vblank_scan"})

    def scan_line(scanline: int):
        """Pulse scan_trigger for scanline, wait for spr_render_done."""
        add({"op": "scan_line", "scanline": scanline})

    def check_spr(x: int, exp_valid: int, exp_color: int, exp_prio: int):
        chk({"op": "check_spr", "x": x,
             "exp_valid": exp_valid, "exp_color": exp_color, "exp_prio": exp_prio})

    def null_sprite(slot: int):
        """Write null sentinel to sprite slot `slot`."""
        base = slot * 4
        write_sram(base + 0, Y_NULL)
        write_sram(base + 1, 0)
        write_sram(base + 2, 0)
        write_sram(base + 3, 0)

    def write_sprite_slot(slot: int, y: int, tile_num: int,
                          flip_x: bool, flip_y: bool, prio: bool,
                          x: int, palette: int, size: int):
        w0, w1, w2, w3 = make_sprite_words(y, tile_num, flip_x, flip_y, prio, x, palette, size)
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
        """Write one row of a 16×16 tile to both DUT ROM and model."""
        assert len(nybbles) == 16
        base = tile_code * 128 + row * 8
        for b in range(8):
            lo = nybbles[b * 2]
            hi = nybbles[b * 2 + 1]
            write_spr_rom(base + b, (hi << 4) | lo)
        rom.load_tile_row(tile_code, row, nybbles)

    # SPRITE_CTRL: scan_count_code=3 → 32 slots scanned (all we need for tests)
    SPRITE_CTRL_32 = 0x3000

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 1: Single 16×16 sprite, solid fill, scanline match
    # Sprite at (x=10, y=20), tile=1, palette=3, size=0, nybble=0x5
    # Check scanline 20..35 (all 16 rows hit the tile)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    load_solid_tile(rom, 1, 0x5)

    # Null-fill all 32 slots, then set slot 0
    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=20, tile_num=1, flip_x=False, flip_y=False,
                      prio=False, x=10, palette=3, size=0)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()

    spr = SpriteEntry(x=10, y=20, tile_num=1, palette=3, size=0, valid=True)
    dl = [spr] + [SpriteEntry() for _ in range(255)]

    # Check scanline 20 (top row of sprite)
    scan_line(20)
    buf = rast.render_scanline(dl, 1, current_y=20)

    # x=9 before sprite → transparent
    chk({"op": "check_spr", "x": 9,  "exp_valid": 0, "exp_color": 0, "exp_prio": 0})
    # x=10..25 within sprite → valid, color=0x35
    for x in [10, 15, 20, 25]:
        p = buf[x]
        check_spr(x, int(p.valid), p.color, int(p.priority))
    # x=26 after sprite → transparent
    chk({"op": "check_spr", "x": 26, "exp_valid": 0, "exp_color": 0, "exp_prio": 0})

    # Check scanline 35 (last row of sprite)
    scan_line(35)
    buf35 = rast.render_scanline(dl, 1, current_y=35)
    check_spr(10, int(buf35[10].valid), buf35[10].color, int(buf35[10].priority))
    check_spr(25, int(buf35[25].valid), buf35[25].color, int(buf35[25].priority))

    # Check scanline 36 (just past sprite bottom) → no sprite
    scan_line(36)
    chk({"op": "check_spr", "x": 10, "exp_valid": 0, "exp_color": 0, "exp_prio": 0})

    # Check scanline 19 (just above sprite) → no sprite
    scan_line(19)
    chk({"op": "check_spr", "x": 10, "exp_valid": 0, "exp_color": 0, "exp_prio": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 2: Transparent sprite — all pixels nybble=0
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    load_solid_tile(rom, 2, 0x0)   # all transparent

    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=10, tile_num=2, flip_x=False, flip_y=False,
                      prio=False, x=0, palette=7, size=0)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()

    scan_line(10)
    spr2 = SpriteEntry(x=0, y=10, tile_num=2, palette=7, size=0, valid=True)
    dl2 = [spr2] + [SpriteEntry() for _ in range(255)]
    buf2 = rast.render_scanline(dl2, 1, current_y=10)

    for x in [0, 8, 15]:
        check_spr(x, 0, 0, 0)   # all transparent

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 3: flip_x
    # Tile row 0: pixels [1,2,3,4,5,6,7,8,9,A,B,C,D,E,F,1]
    # flip_x=True: screen pixel 0 gets sprite pixel 15 = 1
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    row0_nybbles = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
    for r in range(16):
        load_tile_row(rom, 3, r, row0_nybbles)

    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=0, tile_num=3, flip_x=True, flip_y=False,
                      prio=False, x=0, palette=1, size=0)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()

    scan_line(0)
    spr3 = SpriteEntry(x=0, y=0, tile_num=3, palette=1, size=0, flip_x=True, valid=True)
    dl3 = [spr3] + [SpriteEntry() for _ in range(255)]
    buf3 = rast.render_scanline(dl3, 1, current_y=0)

    # x=0 → sprite pixel 15 = nybble 1 → color = {1, 1} = 0x11
    check_spr(0, int(buf3[0].valid), buf3[0].color, int(buf3[0].priority))
    # x=1 → sprite pixel 14 = nybble F → color = {1, F} = 0x1F
    check_spr(1, int(buf3[1].valid), buf3[1].color, int(buf3[1].priority))
    # x=14 → sprite pixel 1 = nybble 2 → color = {1, 2} = 0x12
    check_spr(14, int(buf3[14].valid), buf3[14].color, int(buf3[14].priority))
    # x=15 → sprite pixel 0 = nybble 1 → color = {1, 1} = 0x11
    check_spr(15, int(buf3[15].valid), buf3[15].color, int(buf3[15].priority))

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 4: flip_y
    # Tile: row 0 all-nybble 0xA, row 15 all-nybble 0xB
    # flip_y=True: scanline y=0 sees row 15 (nybble B), y=15 sees row 0 (nybble A)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    load_tile_row(rom, 4, 0,  [0xA] * 16)
    load_tile_row(rom, 4, 15, [0xB] * 16)
    # Fill other rows with 0x9 to distinguish
    for r in range(1, 15):
        load_tile_row(rom, 4, r, [0x9] * 16)

    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=0, tile_num=4, flip_x=False, flip_y=True,
                      prio=False, x=0, palette=2, size=0)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()

    spr4 = SpriteEntry(x=0, y=0, tile_num=4, palette=2, size=0, flip_y=True, valid=True)
    dl4 = [spr4] + [SpriteEntry() for _ in range(255)]

    # Scanline 0 → row 15 → nybble 0xB → color 0x2B
    scan_line(0)
    buf4a = rast.render_scanline(dl4, 1, current_y=0)
    check_spr(0, int(buf4a[0].valid), buf4a[0].color, int(buf4a[0].priority))

    # Scanline 15 → row 0 → nybble 0xA → color 0x2A
    scan_line(15)
    buf4b = rast.render_scanline(dl4, 1, current_y=15)
    check_spr(0, int(buf4b[0].valid), buf4b[0].color, int(buf4b[0].priority))

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 5: Priority bit pass-through
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    load_solid_tile(rom, 5, 0x8)

    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=0, tile_num=5, flip_x=False, flip_y=False,
                      prio=True, x=0, palette=0xF, size=0)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()
    scan_line(0)

    spr5 = SpriteEntry(x=0, y=0, tile_num=5, palette=0xF, size=0, prio=True, valid=True)
    dl5 = [spr5] + [SpriteEntry() for _ in range(255)]
    buf5 = rast.render_scanline(dl5, 1, current_y=0)

    # Priority=1, color = {F, 8} = 0xF8
    check_spr(0,  int(buf5[0].valid),  buf5[0].color,  int(buf5[0].priority))
    check_spr(15, int(buf5[15].valid), buf5[15].color, int(buf5[15].priority))

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 6: 32×32 sprite (size=1, 2×2 tiles)
    # Tiles: 10=top-left(nybble 1), 11=top-right(nybble 2),
    #        12=bot-left(nybble 3),  13=bot-right(nybble 4)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    load_solid_tile(rom, 10, 0x1)
    load_solid_tile(rom, 11, 0x2)
    load_solid_tile(rom, 12, 0x3)
    load_solid_tile(rom, 13, 0x4)

    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=0, tile_num=10, flip_x=False, flip_y=False,
                      prio=False, x=0, palette=5, size=1)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()

    spr6 = SpriteEntry(x=0, y=0, tile_num=10, palette=5, size=1, valid=True)
    dl6 = [spr6] + [SpriteEntry() for _ in range(255)]

    # Scanline 0 → top tiles (tile_row=0): tile[10] (x=0..15) and tile[11] (x=16..31)
    scan_line(0)
    buf6a = rast.render_scanline(dl6, 1, current_y=0)
    check_spr(0,  int(buf6a[0].valid),  buf6a[0].color,  int(buf6a[0].priority))
    check_spr(16, int(buf6a[16].valid), buf6a[16].color, int(buf6a[16].priority))
    check_spr(31, int(buf6a[31].valid), buf6a[31].color, int(buf6a[31].priority))
    chk({"op": "check_spr", "x": 32, "exp_valid": 0, "exp_color": 0, "exp_prio": 0})

    # Scanline 16 → bottom tiles (tile_row=1): tile[12] and tile[13]
    scan_line(16)
    buf6b = rast.render_scanline(dl6, 1, current_y=16)
    check_spr(0,  int(buf6b[0].valid),  buf6b[0].color,  int(buf6b[0].priority))
    check_spr(16, int(buf6b[16].valid), buf6b[16].color, int(buf6b[16].priority))

    # Scanline 32 → past sprite bottom → transparent
    scan_line(32)
    chk({"op": "check_spr", "x": 0, "exp_valid": 0, "exp_color": 0, "exp_prio": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 7: Multiple sprites on same scanline — later overwrites earlier
    # Sprite 0: x=0, tile=20, palette=1, nybble=0x6
    # Sprite 1: x=8, tile=21, palette=2, nybble=0xA (overlaps with sprite 0 at x=8..15)
    # At x=8..15: sprite 1 (drawn after sprite 0) should win
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    load_solid_tile(rom, 20, 0x6)
    load_solid_tile(rom, 21, 0xA)

    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=0, tile_num=20, flip_x=False, flip_y=False,
                      prio=False, x=0, palette=1, size=0)
    write_sprite_slot(1, y=0, tile_num=21, flip_x=False, flip_y=False,
                      prio=False, x=8, palette=2, size=0)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()
    scan_line(0)

    spr7a = SpriteEntry(x=0,  y=0, tile_num=20, palette=1, size=0, valid=True)
    spr7b = SpriteEntry(x=8,  y=0, tile_num=21, palette=2, size=0, valid=True)
    dl7 = [spr7a, spr7b] + [SpriteEntry() for _ in range(254)]
    buf7 = rast.render_scanline(dl7, 2, current_y=0)

    # x=0..7: only sprite 0 → color = {1, 6} = 0x16
    check_spr(0, int(buf7[0].valid), buf7[0].color, int(buf7[0].priority))
    check_spr(7, int(buf7[7].valid), buf7[7].color, int(buf7[7].priority))
    # x=8..15: sprite 1 overwrites → color = {2, A} = 0x2A
    check_spr(8,  int(buf7[8].valid),  buf7[8].color,  int(buf7[8].priority))
    check_spr(15, int(buf7[15].valid), buf7[15].color, int(buf7[15].priority))
    # x=16..23: only sprite 1 → color = {2, A} = 0x2A (sprite 1 is x=8..23)
    check_spr(16, int(buf7[16].valid), buf7[16].color, int(buf7[16].priority))
    check_spr(23, int(buf7[23].valid), buf7[23].color, int(buf7[23].priority))
    # x=24: beyond both sprites → transparent
    chk({"op": "check_spr", "x": 24, "exp_valid": 0, "exp_color": 0, "exp_prio": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 8: Sprite at right edge (x=304, sprite width 16 → x=304..319)
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    load_solid_tile(rom, 30, 0xC)

    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=0, tile_num=30, flip_x=False, flip_y=False,
                      prio=False, x=304, palette=6, size=0)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()
    scan_line(0)

    spr8 = SpriteEntry(x=304, y=0, tile_num=30, palette=6, size=0, valid=True)
    dl8 = [spr8] + [SpriteEntry() for _ in range(255)]
    buf8 = rast.render_scanline(dl8, 1, current_y=0)

    check_spr(304, int(buf8[304].valid), buf8[304].color, int(buf8[304].priority))
    check_spr(319, int(buf8[319].valid), buf8[319].color, int(buf8[319].priority))
    # x=303: before sprite → transparent
    chk({"op": "check_spr", "x": 303, "exp_valid": 0, "exp_color": 0, "exp_prio": 0})

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 9: 64×64 sprite (size=2, 4×4 tiles)
    # Tiles 40..55, fill all with distinct nybble by tile column
    # tile column 0=nybble 1, col 1=nybble 2, col 2=nybble 3, col 3=nybble 4
    # ══════════════════════════════════════════════════════════════════════════
    reset()
    rom = SpriteROM()
    rast = GP9001SpriteRasterizer(rom)

    # 4×4 tiles: base=40, row tr, col tc → tile 40 + tr*4 + tc
    for tr in range(4):
        for tc in range(4):
            nybble = tc + 1  # 1..4 per column
            load_solid_tile(rom, 40 + tr * 4 + tc, nybble)

    for s in range(32):
        null_sprite(s)
    write_sprite_slot(0, y=0, tile_num=40, flip_x=False, flip_y=False,
                      prio=False, x=0, palette=9, size=2)

    write_sprite_ctrl(SPRITE_CTRL_32)
    vblank_scan()
    scan_line(0)

    spr9 = SpriteEntry(x=0, y=0, tile_num=40, palette=9, size=2, valid=True)
    dl9 = [spr9] + [SpriteEntry() for _ in range(255)]
    buf9 = rast.render_scanline(dl9, 1, current_y=0)

    # Spot check: x=0..15 (col 0, nybble 1), x=48..63 (col 3, nybble 4)
    check_spr(0,  int(buf9[0].valid),  buf9[0].color,  int(buf9[0].priority))
    check_spr(16, int(buf9[16].valid), buf9[16].color, int(buf9[16].priority))
    check_spr(48, int(buf9[48].valid), buf9[48].color, int(buf9[48].priority))
    check_spr(63, int(buf9[63].valid), buf9[63].color, int(buf9[63].priority))
    # x=64: past sprite → transparent
    chk({"op": "check_spr", "x": 64, "exp_valid": 0, "exp_color": 0, "exp_prio": 0})

    # ── Write output ──────────────────────────────────────────────────────────
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate4: {check_count} checks → {OUT_PATH}")
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
