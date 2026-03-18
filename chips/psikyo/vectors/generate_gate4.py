#!/usr/bin/env python3
"""
generate_gate4.py — Psikyo Gate 4 test vector generator.

Produces gate4_vectors.jsonl consumed by tb_gate4.cpp.

Supported ops:
  reset              — pulse rst_n low then high
  write_vram         — layer, cell, data: write VRAM entry
  write_rom_byte     — addr, data: write tile ROM byte
  set_scroll         — layer, sx, sy: set scroll registers (integer, 0..255)
  set_pixel          — hpos, vpos, hblank, vblank: drive pixel coords
  clock_n            — n: advance n clock cycles
  check_bg_valid     — layer, exp: check bg_pix_valid[layer]
  check_bg_color     — layer, exp: check bg_pix_color[layer]
  check_bg_prio      — layer, exp: check bg_pix_priority[layer]
  comment            — text: section marker

Test scenarios:
  1.  Solid tile, no scroll, pixel at (0,0)
  2.  Solid tile, no scroll, pixel at (15,15) within same tile
  3.  Transparent tile (all-zero nybbles)
  4.  X scroll: verify tile column shifts
  5.  Y scroll: verify tile row shifts
  6.  flip_x: gradient row, verify pixel mirroring
  7.  flip_y: distinct rows, verify row mirroring
  8.  Layer independence: BG0 and BG1 have different tiles
  9.  Priority bit: entry[15]=1 → bg_pix_priority[layer]=1
  10. Blanking: hblank/vblank suppresses valid output
  11. Scroll wrap: scroll_x=240 + hpos=16 → tile col wraps
  12. Pixel at tile boundary (hpos=16, col=1)
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate4_model import PsikyoBGTilemapModel, BgPixel

OUTPUT_FILE = os.path.join(os.path.dirname(__file__), "gate4_vectors.jsonl")

# Pipeline latency from set_pixel to valid output:
#   - mux_layer advances every clock → layer 0 is processed on clocks 0,2,4,...
#   - Stage 0→1: 1 clock (ROM address registered)
#   - Stage 1→2→output: 1 clock (output registered)
#   - Total: 2 clocks after set_pixel for the layer to update
# To be safe, we clock 4 times after setting hpos/vpos before checking.
PIPELINE_LATENCY = 4


def emit(f, obj: dict) -> None:
    f.write(json.dumps(obj) + "\n")


def section(f, name: str) -> None:
    emit(f, {"op": "comment", "text": name})


def write_rom_byte(f, model: PsikyoBGTilemapModel, addr: int, data: int) -> None:
    model.write_tile_rom_byte(addr, data)
    emit(f, {"op": "write_rom_byte", "addr": addr, "data": data})


def write_solid_tile(f, model: PsikyoBGTilemapModel, tile_num: int, nybble: int) -> None:
    """Write solid 16×16 tile to model + emit ops."""
    from gate4_model import TILE_BYTES
    byte_val = ((nybble & 0xF) << 4) | (nybble & 0xF)
    base = tile_num * TILE_BYTES
    for i in range(TILE_BYTES):
        write_rom_byte(f, model, base + i, byte_val)
    model.write_solid_tile(tile_num, nybble)  # ensure model is consistent


def write_tile_row(f, model: PsikyoBGTilemapModel, tile_num: int, py: int,
                   nybbles: list) -> None:
    """Write one row (16 pixels) of a tile."""
    from gate4_model import TILE_BYTES
    base = tile_num * TILE_BYTES + py * 8
    for b in range(8):
        lo = nybbles[b * 2] & 0xF
        hi = nybbles[b * 2 + 1] & 0xF
        byte_val = (hi << 4) | lo
        write_rom_byte(f, model, base + b, byte_val)
    model.write_tile_row(tile_num, py, nybbles)


def write_vram(f, model: PsikyoBGTilemapModel, layer: int, cell: int,
               entry: int) -> None:
    model.write_vram(layer, cell, entry)
    emit(f, {"op": "write_vram", "layer": layer, "cell": cell, "data": entry})


def set_scroll(f, model: PsikyoBGTilemapModel, layer: int, sx: int, sy: int) -> None:
    model.set_scroll(layer, sx, sy)
    emit(f, {"op": "set_scroll", "layer": layer, "sx": sx, "sy": sy})


def set_pixel(f, hpos: int, vpos: int, hblank: int = 0, vblank: int = 0) -> None:
    emit(f, {"op": "set_pixel", "hpos": hpos, "vpos": vpos,
             "hblank": hblank, "vblank": vblank})


def clock_n(f, n: int) -> None:
    emit(f, {"op": "clock_n", "n": n})


def check_layer(f, model: PsikyoBGTilemapModel, layer: int,
                hpos: int, vpos: int,
                hblank: bool = False, vblank: bool = False) -> None:
    """Emit set_pixel + pipeline clocks + checks for one layer."""
    pix = model.get_pixel(layer, hpos, vpos, hblank, vblank)
    set_pixel(f, hpos, vpos, int(hblank), int(vblank))
    clock_n(f, PIPELINE_LATENCY)
    emit(f, {"op": "check_bg_valid", "layer": layer, "exp": int(pix.valid)})
    if pix.valid:
        emit(f, {"op": "check_bg_color", "layer": layer, "exp": pix.color})
        emit(f, {"op": "check_bg_prio",  "layer": layer, "exp": int(pix.priority)})


# ─────────────────────────────────────────────────────────────────────────────
# Main vector generation
# ─────────────────────────────────────────────────────────────────────────────

def generate():
    model = PsikyoBGTilemapModel()

    with open(OUTPUT_FILE, "w") as f:
        emit(f, {"op": "reset"})

        # ═══════════════════════════════════════════════════════════════════════
        # Test 1: Solid tile at cell(0,0), no scroll, pixel (0,0)
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test1: solid tile, no scroll, pixel(0,0)")

        write_solid_tile(f, model, tile_num=100, nybble=0x5)
        # entry: palette=3, flip_y=0, flip_x=0, tile_num=100 → (3<<12)|100 = 0x3064
        write_vram(f, model, layer=0, cell=0, entry=0x3064)
        set_scroll(f, model, 0, 0, 0)

        check_layer(f, model, layer=0, hpos=0, vpos=0)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 2: Pixel at (15,15) — last pixel in same tile cell
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test2: pixel(15,15) still in cell(0,0)")

        check_layer(f, model, layer=0, hpos=15, vpos=15)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 3: Transparent tile (all-zero nybbles → no pixel written)
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test3: transparent tile (nybble=0)")

        # Tile 0 is all zeros (ROM initialized to 0) → all pixels transparent
        write_vram(f, model, layer=0, cell=0, entry=0x7000)   # palette=7, tile_num=0

        check_layer(f, model, layer=0, hpos=0, vpos=0)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 4: X scroll
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test4: X scroll=32, hpos=0 hits col=2")

        write_solid_tile(f, model, tile_num=101, nybble=0x7)
        # cell(0,2): row=0, col=2 → cell=2
        write_vram(f, model, layer=0, cell=2, entry=0x2065)   # palette=2, tile_num=101
        set_scroll(f, model, 0, sx=32, sy=0)   # tx=(0+32)=32 → col=2

        check_layer(f, model, layer=0, hpos=0, vpos=0)

        # Also check hpos=15 with scroll=32: tx=47 → col=2, same tile
        check_layer(f, model, layer=0, hpos=15, vpos=0)

        # Reset scroll for subsequent tests
        set_scroll(f, model, 0, sx=0, sy=0)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 5: Y scroll
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test5: Y scroll=16, vpos=0 hits row=1")

        write_solid_tile(f, model, tile_num=102, nybble=0x9)
        # cell(1,0): row=1, col=0 → cell=64
        write_vram(f, model, layer=0, cell=64, entry=0x5066)  # palette=5, tile_num=102
        set_scroll(f, model, 0, sx=0, sy=16)   # ty=(0+16)=16 → row=1

        check_layer(f, model, layer=0, hpos=0, vpos=0)

        set_scroll(f, model, 0, sx=0, sy=0)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 6: flip_x — gradient row, verify mirroring
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test6: flip_x, gradient row")

        # Write row 0 of tile 103 with pixels 1..15,0 (index 15 is transparent)
        row0_nybbles = list(range(1, 16)) + [0]   # [1,2,...,15,0]
        write_tile_row(f, model, tile_num=103, py=0, nybbles=row0_nybbles)
        # entry: palette=1, flip_x=1 (bit10), tile_num=103
        # bit10=1: entry[10]=1 → 0x0400 | (1<<12) | 103 = 0x1467
        write_vram(f, model, layer=0, cell=0, entry=0x1467)  # palette=1, flip_x=1, tile=103
        set_scroll(f, model, 0, sx=0, sy=0)

        # hpos=0: fpx=15 → pixel[15]=0 → transparent
        check_layer(f, model, layer=0, hpos=0, vpos=0)

        # hpos=1: fpx=14 → pixel[14]=15 (nybble=15=0xF)
        check_layer(f, model, layer=0, hpos=1, vpos=0)

        # hpos=14: fpx=1 → pixel[1]=2 (nybble=2)
        check_layer(f, model, layer=0, hpos=14, vpos=0)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 7: flip_y — distinct rows, verify mirroring
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test7: flip_y, row0=0xA row15=0xB")

        write_tile_row(f, model, tile_num=104, py=0,  nybbles=[0xA] * 16)
        write_tile_row(f, model, tile_num=104, py=15, nybbles=[0xB] * 16)
        # entry: palette=0, flip_y=1 (bit11), tile_num=104
        # bit11=1 → 0x0800 | (0<<12) | 104 = 0x0868
        write_vram(f, model, layer=0, cell=0, entry=0x0868)  # palette=0, flip_y=1, tile=104
        set_scroll(f, model, 0, sx=0, sy=0)

        # vpos=0 with flip_y: fpy=15 → reads row 15 → nybble=0xB
        check_layer(f, model, layer=0, hpos=0, vpos=0)

        # vpos=15 with flip_y: fpy=0 → reads row 0 → nybble=0xA
        check_layer(f, model, layer=0, hpos=0, vpos=15)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 8: Layer independence (BG0 and BG1 have different content)
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test8: layer independence")

        write_solid_tile(f, model, tile_num=105, nybble=0x3)
        write_solid_tile(f, model, tile_num=106, nybble=0xC)

        # Layer 0, cell 0: tile 105, palette 2
        write_vram(f, model, layer=0, cell=0, entry=0x2069)  # palette=2, tile=105
        # Layer 1, cell 0: tile 106, palette 7
        write_vram(f, model, layer=1, cell=0, entry=0x706A)  # palette=7, tile=106

        set_scroll(f, model, 0, sx=0, sy=0)
        set_scroll(f, model, 1, sx=0, sy=0)

        check_layer(f, model, layer=0, hpos=0, vpos=0)
        check_layer(f, model, layer=1, hpos=0, vpos=0)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 9: Priority bit
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test9: priority bit (entry[15]=1)")

        write_solid_tile(f, model, tile_num=107, nybble=0xE)
        # entry[15]=1 means priority=1.  entry[15:12]=palette=8(1000b) → prio=1
        # entry = (8<<12) | 107 = 0x806B
        write_vram(f, model, layer=0, cell=0, entry=0x806B)  # palette=8, prio=1, tile=107
        set_scroll(f, model, 0, sx=0, sy=0)

        check_layer(f, model, layer=0, hpos=0, vpos=0)

        # Also verify non-priority tile (entry[15]=0 → palette=7=0111b)
        write_solid_tile(f, model, tile_num=108, nybble=0x2)
        write_vram(f, model, layer=0, cell=0, entry=0x706C)  # palette=7, prio=0, tile=108
        check_layer(f, model, layer=0, hpos=0, vpos=0)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 10: Blanking suppresses output
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test10: hblank/vblank suppress output")

        # Layer 0 still has tile 108 solid at cell 0
        check_layer(f, model, layer=0, hpos=0, vpos=0, hblank=True)
        check_layer(f, model, layer=0, hpos=0, vpos=0, vblank=True)

        # ═══════════════════════════════════════════════════════════════════════
        # Test 11: Tile boundary crossing (hpos=16 → col=1, new cell)
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test11: tile boundary at hpos=16 (col=1 empty)")

        # cell(0,0) has tile 108 (solid 0x2); cell(0,1) has default tile_num=0 (transparent)
        write_vram(f, model, layer=0, cell=0, entry=0x706C)   # palette=7, tile=108
        # cell(0,1): entry=0 → tile_num=0 (all zeros = transparent)
        set_scroll(f, model, 0, sx=0, sy=0)

        check_layer(f, model, layer=0, hpos=0,  vpos=0)   # hit cell(0,0) → valid
        check_layer(f, model, layer=0, hpos=15, vpos=0)   # still cell(0,0) → valid
        check_layer(f, model, layer=0, hpos=16, vpos=0)   # cell(0,1) → transparent

        # ═══════════════════════════════════════════════════════════════════════
        # Test 12: Scroll wrap-around at tilemap boundary (1024 px wide)
        # ═══════════════════════════════════════════════════════════════════════
        section(f, "Test12: X scroll wrap (scroll_x=240+hpos=0 → col=15)")

        # col 15, row 0: cell=15
        write_solid_tile(f, model, tile_num=110, nybble=0x4)
        write_vram(f, model, layer=0, cell=15, entry=0x106E)  # palette=1, tile=110

        set_scroll(f, model, 0, sx=240, sy=0)
        # hpos=0 → tx=(0+240)&0x3FF=240 → col=15 → should hit tile 110
        check_layer(f, model, layer=0, hpos=0, vpos=0)

        # hpos=16 → tx=256 → col=16 → cell=16, no tile → transparent
        check_layer(f, model, layer=0, hpos=16, vpos=0)

        set_scroll(f, model, 0, sx=0, sy=0)

    # Count check ops
    with open(OUTPUT_FILE) as fin:
        lines = [json.loads(l) for l in fin if l.strip()]
    checks = sum(1 for l in lines
                 if l.get("op") in ("check_bg_valid", "check_bg_color", "check_bg_prio"))
    ops = len(lines)
    print(f"Generated {OUTPUT_FILE}")
    print(f"Total ops: {ops}, checks: {checks}")


if __name__ == '__main__':
    generate()
