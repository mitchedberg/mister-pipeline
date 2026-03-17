#!/usr/bin/env python3
"""
generate_gate3.py — Psikyo Gate 3 test vector generator.

Produces gate3_vectors.jsonl, a sequence of JSONL operations consumed by
tb_gate3.cpp.  Each line is one JSON object with an "op" field.

Supported ops:
  reset             — pulse rst_n low then high
  write_spr_rom     — addr, data: write one byte into testbench sprite ROM
  load_display_list — count, entries[]: inject display_list into DUT arrays
  scan_line         — scanline: pulse scan_trigger for 1 cycle, wait for done
  check_spr         — x, exp_valid, exp_color, exp_priority: verify pixel
  comment           — section marker (ignored by testbench)

Test scenarios:
  1.  Y-hit:        sprite intersects scanline
  2.  Y-miss:       sprite does not intersect scanline
  3.  transparent:  tile with all-zero nybbles → no pixels written
  4.  flip_x:       sprite with flip_x=1
  5.  flip_y:       sprite with flip_y=1
  6.  multi-tile 2×2: size=1 (32×32 px)
  7.  overlapping:  two sprites on same scanline
  8.  edge-of-screen: sprite at x=304 (rightmost 16 pixels)
  9.  priority:     prio field stored per pixel
  10. invalid entry: valid=0 → skipped
  11. multi-tile 4×4: size=2 (64×64 px)
  12. flip_x + flip_y combined
"""

import json
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from gate3_model import PsikyoSpriteRasterizer, PsikyoSpriteEntry, SpriteROM

OUTPUT_FILE = os.path.join(os.path.dirname(__file__), "gate3_vectors.jsonl")


def emit(f, obj: dict) -> None:
    f.write(json.dumps(obj) + "\n")


def solid_tile_bytes(nybble: int) -> list:
    """Return 128 bytes encoding a solid-fill 16×16 tile."""
    b = ((nybble & 0xF) << 4) | (nybble & 0xF)
    return [b] * 128


def tile_row_bytes(nybbles: list) -> list:
    """Pack 16 nybbles into 8 bytes (lo nybble = left pixel)."""
    assert len(nybbles) == 16
    return [((nybbles[i * 2 + 1] & 0xF) << 4) | (nybbles[i * 2] & 0xF) for i in range(8)]


def write_tile(f, rom: SpriteROM, tile_code: int, data_bytes: list) -> None:
    """Write tile to model ROM and emit write_spr_rom ops."""
    base = tile_code * 128
    for i, b in enumerate(data_bytes):
        rom.write_byte(base + i, b)
        emit(f, {"op": "write_spr_rom", "addr": base + i, "data": b})


def write_tile_solid(f, rom: SpriteROM, tile_code: int, nybble: int) -> None:
    """Write solid tile to model ROM and emit ops."""
    write_tile(f, rom, tile_code, solid_tile_bytes(nybble))


def write_tile_row(f, rom: SpriteROM, tile_code: int, row: int, nybbles: list) -> None:
    """Write one tile row to model ROM and emit ops."""
    base = tile_code * 128 + row * 8
    packed = tile_row_bytes(nybbles)
    for i, b in enumerate(packed):
        rom.write_byte(base + i, b)
        emit(f, {"op": "write_spr_rom", "addr": base + i, "data": b})


def load_display_list(f, entries: list, count: int = None) -> None:
    """Emit a load_display_list op."""
    if count is None:
        count = len(entries)
    normalised = []
    for e in entries:
        if isinstance(e, PsikyoSpriteEntry):
            normalised.append({
                "x":        e.x,
                "y":        e.y,
                "tile_num": e.tile_num,
                "palette":  e.palette,
                "flip_x":   int(e.flip_x),
                "flip_y":   int(e.flip_y),
                "prio":     e.prio,
                "size":     e.size,
                "valid":    int(e.valid),
            })
        else:
            normalised.append(e)
    emit(f, {"op": "load_display_list", "count": count, "entries": normalised})


def check_pixel(f, x: int, exp_valid: int, exp_color: int = 0,
                exp_priority: int = 0) -> None:
    emit(f, {
        "op":          "check_spr",
        "x":           x,
        "exp_valid":   exp_valid,
        "exp_color":   exp_color,
        "exp_priority": exp_priority,
    })


def section(f, name: str) -> None:
    emit(f, {"op": "comment", "text": name})


# ─────────────────────────────────────────────────────────────────────────────
# Main vector generation — single shared ROM/rasterizer throughout
# ─────────────────────────────────────────────────────────────────────────────

def generate():
    rom  = SpriteROM()
    rast = PsikyoSpriteRasterizer(rom)

    with open(OUTPUT_FILE, "w") as f:

        emit(f, {"op": "reset"})

        # ═════════════════════════════════════════════════════════════════
        # Test 1: Y-hit — sprite at y=20, scanline=20
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test1: Y-hit (sprite at y=20, scanline=20)")

        write_tile_solid(f, rom, 0, 0x5)

        spr1 = PsikyoSpriteEntry(x=10, y=20, tile_num=0, palette=3, size=0, valid=True)
        load_display_list(f, [spr1])
        emit(f, {"op": "scan_line", "scanline": 20})

        buf = rast.render_scanline([spr1], 1, 20)
        check_pixel(f, 10, 1, buf[10].color, buf[10].priority)
        check_pixel(f, 25, 1, buf[25].color, buf[25].priority)
        check_pixel(f, 9,  0)
        check_pixel(f, 26, 0)

        # ═════════════════════════════════════════════════════════════════
        # Test 2: Y-miss — sprite at y=50, scanline=20
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test2: Y-miss (sprite at y=50, scanline=20)")

        spr2 = PsikyoSpriteEntry(x=0, y=50, tile_num=0, palette=3, size=0, valid=True)
        load_display_list(f, [spr2])
        emit(f, {"op": "scan_line", "scanline": 20})

        for x in range(16):
            check_pixel(f, x, 0)

        # ═════════════════════════════════════════════════════════════════
        # Test 3: Transparent tile (all nybbles = 0)
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test3: Transparent tile (nybble=0)")

        write_tile_solid(f, rom, 1, 0)

        spr3 = PsikyoSpriteEntry(x=0, y=0, tile_num=1, palette=7, size=0, valid=True)
        load_display_list(f, [spr3])
        emit(f, {"op": "scan_line", "scanline": 0})

        buf3 = rast.render_scanline([spr3], 1, 0)
        for x in range(16):
            check_pixel(f, x, 0)

        # ═════════════════════════════════════════════════════════════════
        # Test 4: flip_x
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test4: flip_x")

        row0_nybbles = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
        write_tile_row(f, rom, 2, 0, row0_nybbles)

        spr4 = PsikyoSpriteEntry(x=0, y=0, tile_num=2, palette=1, size=0,
                                  flip_x=True, valid=True)
        load_display_list(f, [spr4])
        emit(f, {"op": "scan_line", "scanline": 0})

        buf4 = rast.render_scanline([spr4], 1, 0)
        check_pixel(f, 0,  1, buf4[0].color,  buf4[0].priority)
        check_pixel(f, 1,  1, buf4[1].color,  buf4[1].priority)
        check_pixel(f, 14, 1, buf4[14].color, buf4[14].priority)
        check_pixel(f, 15, 1, buf4[15].color, buf4[15].priority)

        # ═════════════════════════════════════════════════════════════════
        # Test 5: flip_y
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test5: flip_y")

        write_tile_row(f, rom, 3, 0,  [0xA] * 16)
        write_tile_row(f, rom, 3, 15, [0xB] * 16)

        spr5 = PsikyoSpriteEntry(x=0, y=0, tile_num=3, palette=2, size=0,
                                  flip_y=True, valid=True)

        # scanline=0 with flip_y: should read original row 15 (nybble 0xB)
        load_display_list(f, [spr5])
        emit(f, {"op": "scan_line", "scanline": 0})
        buf5a = rast.render_scanline([spr5], 1, 0)
        check_pixel(f, 0, 1, buf5a[0].color, buf5a[0].priority)

        # scanline=15 with flip_y: should read original row 0 (nybble 0xA)
        load_display_list(f, [spr5])
        emit(f, {"op": "scan_line", "scanline": 15})
        buf5b = rast.render_scanline([spr5], 1, 15)
        check_pixel(f, 0, 1, buf5b[0].color, buf5b[0].priority)

        # ═════════════════════════════════════════════════════════════════
        # Test 6: 32×32 multi-tile (size=1)
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test6: multi-tile 32x32 (size=1)")

        write_tile_solid(f, rom, 4, 0x1)   # top-left
        write_tile_solid(f, rom, 5, 0x2)   # top-right
        write_tile_solid(f, rom, 6, 0x3)   # bottom-left
        write_tile_solid(f, rom, 7, 0x4)   # bottom-right

        spr6 = PsikyoSpriteEntry(x=0, y=0, tile_num=4, palette=5, size=1, valid=True)

        load_display_list(f, [spr6])
        emit(f, {"op": "scan_line", "scanline": 0})
        buf6a = rast.render_scanline([spr6], 1, 0)
        check_pixel(f, 0,  1, buf6a[0].color,  0)
        check_pixel(f, 16, 1, buf6a[16].color, 0)
        check_pixel(f, 32, 0)

        load_display_list(f, [spr6])
        emit(f, {"op": "scan_line", "scanline": 16})
        buf6b = rast.render_scanline([spr6], 1, 16)
        check_pixel(f, 0,  1, buf6b[0].color,  0)
        check_pixel(f, 16, 1, buf6b[16].color, 0)

        # ═════════════════════════════════════════════════════════════════
        # Test 7: Overlapping sprites (last written wins)
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test7: overlapping sprites")

        write_tile_solid(f, rom, 20, 0x6)
        write_tile_solid(f, rom, 21, 0xA)

        spr7a = PsikyoSpriteEntry(x=0, y=0, tile_num=20, palette=1, size=0, valid=True)
        spr7b = PsikyoSpriteEntry(x=8, y=0, tile_num=21, palette=2, size=0, valid=True)
        load_display_list(f, [spr7a, spr7b], count=2)
        emit(f, {"op": "scan_line", "scanline": 0})

        buf7 = rast.render_scanline([spr7a, spr7b], 2, 0)
        check_pixel(f, 0,  1, buf7[0].color,  0)
        check_pixel(f, 7,  1, buf7[7].color,  0)
        check_pixel(f, 8,  1, buf7[8].color,  0)   # spr7b overwrites spr7a
        check_pixel(f, 15, 1, buf7[15].color, 0)
        check_pixel(f, 16, 1, buf7[16].color, 0)   # still inside spr7b (x=8..23)
        check_pixel(f, 23, 1, buf7[23].color, 0)   # last pixel of spr7b
        check_pixel(f, 24, 0)                        # outside both sprites

        # ═════════════════════════════════════════════════════════════════
        # Test 8: Right screen edge (x=304, width=16 → pixels 304..319)
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test8: sprite at right screen edge (x=304)")

        write_tile_solid(f, rom, 30, 0xC)

        spr8 = PsikyoSpriteEntry(x=304, y=0, tile_num=30, palette=6, size=0, valid=True)
        load_display_list(f, [spr8])
        emit(f, {"op": "scan_line", "scanline": 0})

        buf8 = rast.render_scanline([spr8], 1, 0)
        check_pixel(f, 304, 1, buf8[304].color, 0)
        check_pixel(f, 319, 1, buf8[319].color, 0)
        check_pixel(f, 303, 0)

        # ═════════════════════════════════════════════════════════════════
        # Test 9: Priority field stored per pixel
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test9: priority field")

        write_tile_solid(f, rom, 40, 0x7)

        spr9 = PsikyoSpriteEntry(x=0, y=0, tile_num=40, palette=0, prio=3, size=0, valid=True)
        load_display_list(f, [spr9])
        emit(f, {"op": "scan_line", "scanline": 0})

        buf9 = rast.render_scanline([spr9], 1, 0)
        check_pixel(f, 0,  1, buf9[0].color,  3)
        check_pixel(f, 15, 1, buf9[15].color, 3)

        # ═════════════════════════════════════════════════════════════════
        # Test 10: Invalid entry (valid=0) is skipped
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test10: invalid entry skipped")

        spr10 = PsikyoSpriteEntry(x=0, y=0, tile_num=0, palette=0, size=0, valid=False)
        load_display_list(f, [spr10])
        emit(f, {"op": "scan_line", "scanline": 0})

        for x in range(16):
            check_pixel(f, x, 0)

        # ═════════════════════════════════════════════════════════════════
        # Test 11: 64×64 multi-tile (size=2) — 4×4 grid of tiles
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test11: multi-tile 64x64 (size=2)")

        # Tiles 8..23: row-major 4×4 grid with distinct nybbles
        tile_nybbles_11 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1]
        for i in range(16):
            write_tile_solid(f, rom, 8 + i, tile_nybbles_11[i])

        spr11 = PsikyoSpriteEntry(x=0, y=0, tile_num=8, palette=4, size=2, valid=True)

        load_display_list(f, [spr11])
        emit(f, {"op": "scan_line", "scanline": 0})
        buf11a = rast.render_scanline([spr11], 1, 0)
        check_pixel(f, 0,  1, buf11a[0].color,  0)
        check_pixel(f, 16, 1, buf11a[16].color, 0)
        check_pixel(f, 32, 1, buf11a[32].color, 0)
        check_pixel(f, 48, 1, buf11a[48].color, 0)
        check_pixel(f, 64, 0)

        load_display_list(f, [spr11])
        emit(f, {"op": "scan_line", "scanline": 48})
        buf11b = rast.render_scanline([spr11], 1, 48)
        check_pixel(f, 0,  1, buf11b[0].color,  0)
        check_pixel(f, 48, 1, buf11b[48].color, 0)

        # ═════════════════════════════════════════════════════════════════
        # Test 12: flip_x + flip_y combined on 2×2 sprite
        # ═════════════════════════════════════════════════════════════════
        section(f, "Test12: flip_x + flip_y combined")

        write_tile_solid(f, rom, 50, 0x1)   # top-left
        write_tile_solid(f, rom, 51, 0x2)   # top-right
        write_tile_solid(f, rom, 52, 0x3)   # bottom-left
        write_tile_solid(f, rom, 53, 0x4)   # bottom-right

        spr12 = PsikyoSpriteEntry(x=0, y=0, tile_num=50, palette=9, size=1,
                                   flip_x=True, flip_y=True, valid=True)
        load_display_list(f, [spr12])
        emit(f, {"op": "scan_line", "scanline": 0})

        buf12 = rast.render_scanline([spr12], 1, 0)
        check_pixel(f, 0,  1, buf12[0].color,  0)
        check_pixel(f, 16, 1, buf12[16].color, 0)
        check_pixel(f, 31, 1, buf12[31].color, 0)
        check_pixel(f, 32, 0)

    print(f"Generated {OUTPUT_FILE}")

    # Count check ops
    with open(OUTPUT_FILE) as fin:
        lines = [json.loads(l) for l in fin if l.strip()]
    checks = sum(1 for l in lines if l.get("op") == "check_spr")
    ops    = len(lines)
    print(f"Total ops: {ops}, check_spr: {checks}")


if __name__ == '__main__':
    generate()
