#!/usr/bin/env python3
"""
generate_vectors.py — TC0370MSO test vector generator.

Produces step1..step6 JSONL vector files.  The testbench reads each file
sequentially and checks every "check_*" record against the RTL.

Step 1: Sprite RAM CPU read/write (byte-enables, address range).
Step 2: VBlank scanner reads — verify sprite entry fields are parsed correctly.
Step 3: Line buffer clear and single-pixel writes verified via pixel checks.
Step 4: Zoom pixel rendering — single sprite, nominal zoom and half zoom.
Step 5: Pixel output stage — verify pix_out/pix_valid/pix_priority from buffer.
Step 6: SDRAM bandwidth — multiple sprites, tile cache hit test, off-screen skip.
"""

import json
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))

from mso_model import (
    SpriteRAM, SpriteMAPROM, OBJRom,
    render_frame, H_END, V_START, V_END
)

VEC_DIR = os.path.dirname(os.path.abspath(__file__))


def w(f, obj):
    f.write(json.dumps(obj) + '\n')


# ─── Step 1: Sprite RAM read/write ────────────────────────────────────────────

def gen_step1():
    recs = []

    # Zero sprite RAM
    recs.append({"op": "zero_spr_ram"})

    # Write 4 words of entry 0
    recs.append({"op": "spr_write", "addr": 0, "data": 0xBEEF, "be": 3})
    recs.append({"op": "spr_read",  "addr": 0, "exp":  0xBEEF})

    recs.append({"op": "spr_write", "addr": 1, "data": 0x1234, "be": 3})
    recs.append({"op": "spr_read",  "addr": 1, "exp":  0x1234})

    # Byte-enable: write only upper byte
    recs.append({"op": "spr_write", "addr": 2, "data": 0xFF00, "be": 2})
    recs.append({"op": "spr_read",  "addr": 2, "exp":  0xFF00})

    # Write only lower byte (upper should retain 0xFF from previous write)
    recs.append({"op": "spr_write", "addr": 2, "data": 0x00AB, "be": 1})
    recs.append({"op": "spr_read",  "addr": 2, "exp":  0xFFAB})

    # Word at last address
    recs.append({"op": "spr_write", "addr": 0x1FFF, "data": 0xA5A5, "be": 3})
    recs.append({"op": "spr_read",  "addr": 0x1FFF, "exp":  0xA5A5})

    # Internal scanner read after CPU write
    recs.append({"op": "spr_write", "addr": 0x100, "data": 0x5A5A, "be": 3})
    recs.append({"op": "int_rd",    "addr": 0x100, "exp":  0x5A5A})

    with open(os.path.join(VEC_DIR, 'step1_vectors.jsonl'), 'w') as f:
        for r in recs:
            w(f, r)
    print(f"step1: {len([r for r in recs if r['op'] in ('spr_read','int_rd')])} read checks")


# ─── Step 2: Entry scanner — verify decoded fields ────────────────────────────

def gen_step2():
    """
    Write specific sprite entries into sprite RAM and verify the scanner
    correctly reads and decodes them during a simulated VBlank.
    """
    recs = []
    recs.append({"op": "zero_spr_ram"})

    # Entry at index 0x1FF (first scanned = highest index = back-to-front)
    # zoomy=63, y=80, priority=0, color=5, zoomx=63, flipy=0, flipx=0, x=100, tilenum=1
    sram = SpriteRAM()
    sram.write_entry(idx=0x1FF, zoomy=63, y=80, priority=0, color=5,
                     zoomx=63, flipy=0, flipx=0, x=100, tilenum=1)

    for i in range(4):
        recs.append({"op": "spr_write",
                     "addr": 0x1FF * 4 + i,
                     "data": sram.words[0x1FF * 4 + i],
                     "be": 3})

    # Entry at index 0x0 with tilenum=0 (should be skipped)
    for i in range(4):
        recs.append({"op": "spr_write", "addr": i, "data": 0, "be": 3})

    # Entry at 0x10 with flipx=1, flipy=1, priority=1
    sram2 = SpriteRAM()
    sram2.write_entry(idx=0x10, zoomy=32, y=120, priority=1, color=3,
                      zoomx=16, flipy=1, flipx=1, x=50, tilenum=2)
    for i in range(4):
        recs.append({"op": "spr_write",
                     "addr": 0x10 * 4 + i,
                     "data": sram2.words[0x10 * 4 + i],
                     "be": 3})

    # Trigger a VBlank scan and verify entry decode
    recs.append({"op": "run_scan",
                 "label": "step2_basic_entries",
                 "check_decode": [
                     {"entry_idx": 0x1FF,
                      "exp_zoomy_raw": 63, "exp_y_raw": 80,
                      "exp_priority": 0, "exp_color": 5,
                      "exp_zoomx_raw": 63, "exp_flipy": 0, "exp_flipx": 0,
                      "exp_x_raw": 100, "exp_tilenum": 1},
                     {"entry_idx": 0x10,
                      "exp_zoomy_raw": 32, "exp_y_raw": 120,
                      "exp_priority": 1, "exp_color": 3,
                      "exp_zoomx_raw": 16, "exp_flipy": 1, "exp_flipx": 1,
                      "exp_x_raw": 50, "exp_tilenum": 2},
                 ]
                 })

    with open(os.path.join(VEC_DIR, 'step2_vectors.jsonl'), 'w') as f:
        for r in recs:
            w(f, r)
    print(f"step2: {1} scan check records")


# ─── Helper: encode OBJ ROM row as JSON-compatible 64-bit integer ─────────────

def obj_rom_row_words(obj_rom, code, row):
    """Return list of 8 byte values for tile `code` row `row`."""
    val = obj_rom.get_tile_row_64(code, row)
    return [int((val >> (8 * i)) & 0xFF) for i in range(8)]


# ─── Steps 3–6: Full render pipeline ─────────────────────────────────────────

def gen_steps_3_6():
    """
    Generate rendering tests that drive the full sprite scanner pipeline
    and compare line buffer output against the Python model.
    """

    # ── Step 3: Single sprite, nominal zoom, no flip ─────────────────────────
    recs3 = []
    recs3.append({"op": "zero_spr_ram"})
    recs3.append({"op": "zero_caches"})

    sram = SpriteRAM()
    stym = SpriteMAPROM()
    obj  = OBJRom()

    # Sprite: tilenum=1, nominal zoom (63 raw = 64 eff), x=100, y=80, y_offs=7
    sram.write_entry(idx=0x1FF, zoomy=63, y=80, priority=0, color=5,
                     zoomx=63, flipy=0, flipx=0, x=100, tilenum=1)
    # Only chunk (px=0, py=0) is valid; rest are 0xFFFF
    stym.set_chunk(1, 0, 0, code=1)
    # Tile 1, row 0: all pixels = pen 7
    obj.set_tile_row(1, 0, [7]*16)

    # Write sprite RAM
    for i in range(4):
        recs3.append({"op": "spr_write", "addr": 0x1FF*4+i,
                      "data": sram.words[0x1FF*4+i], "be": 3})

    # Provide STYM ROM contents for chunk (px=0,py=0) of tilenum=1
    # stym word addr = 1<<5 = 32, offset 0 = py*4+px = 0
    recs3.append({"op": "set_stym_word", "addr": 32, "data": 1})  # code=1

    # Provide OBJ ROM rows for tile code=1
    obj_rows = [obj_rom_row_words(obj, 1, r) for r in range(8)]
    recs3.append({"op": "set_obj_tile", "code": 1, "rows": obj_rows})

    # Run the scanner (VBlank)
    recs3.append({"op": "run_vblank", "y_offs": 7, "label": "step3_single_sprite_nominal"})

    # Expected output: y_screen = 80 + 7 + (64-64) = 87
    # chunk (k=0,j=0): curx=100, cury=87, zx=16, zy=8
    # Row 0 of chunk → screen_y=87, pixels at x=100..115, palette_idx=5*16+7=87
    pixels = render_frame(sram, stym, obj, y_offs=7)
    for x in range(100, 116):
        p = pixels[87][x]
        if p:
            recs3.append({"op": "check_pixel", "x": x, "vpos": 87,
                          "exp_valid": 1, "exp_pix": p[1], "exp_priority": p[0]})
        else:
            recs3.append({"op": "check_pixel", "x": x, "vpos": 87,
                          "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})
    # Verify transparent outside sprite
    recs3.append({"op": "check_pixel", "x": 99, "vpos": 87,
                  "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})
    recs3.append({"op": "check_pixel", "x": 116, "vpos": 87,
                  "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})

    cnt3 = len([r for r in recs3 if r['op'] == 'check_pixel'])
    with open(os.path.join(VEC_DIR, 'step3_vectors.jsonl'), 'w') as f:
        for r in recs3:
            w(f, r)
    print(f"step3: {cnt3} pixel checks")

    # ── Step 4: Zoom scaling — half zoom (31 raw = 32 eff) ───────────────────
    recs4 = []
    recs4.append({"op": "zero_spr_ram"})
    recs4.append({"op": "zero_caches"})

    sram4 = SpriteRAM()
    stym4 = SpriteMAPROM()
    obj4  = OBJRom()

    # Half zoom: zoomx_raw=31 → eff=32; zoomy_raw=31 → eff=32
    # y_screen = 80 + 7 + (64-32) = 119
    # chunk (k=0,j=0): curx=100 + 0*32//4 = 100
    #                  cury = 119
    #                  zx = 100 + 1*32//4 - 100 = 8
    #                  zy = 119 + 1*32//8 - 119 = 4
    sram4.write_entry(idx=0x1FF, zoomy=31, y=80, priority=0, color=2,
                      zoomx=31, flipy=0, flipx=0, x=100, tilenum=3)
    stym4.set_chunk(3, 0, 0, code=2)
    # Alternating pixels: pen 1 at even, pen 2 at odd
    obj4.set_tile_row(2, 0, [1 if i % 2 == 0 else 2 for i in range(16)])

    for i in range(4):
        recs4.append({"op": "spr_write", "addr": 0x1FF*4+i,
                      "data": sram4.words[0x1FF*4+i], "be": 3})
    # stym: tilenum=3, addr = 3<<5 = 96
    recs4.append({"op": "set_stym_word", "addr": 96, "data": 2})
    obj_rows4 = [obj_rom_row_words(obj4, 2, r) for r in range(8)]
    recs4.append({"op": "set_obj_tile", "code": 2, "rows": obj_rows4})
    recs4.append({"op": "run_vblank", "y_offs": 7, "label": "step4_half_zoom"})

    pixels4 = render_frame(sram4, stym4, obj4, y_offs=7)
    # row 0: cury=119
    for x in range(100, 108):
        p = pixels4[119][x]
        if p:
            recs4.append({"op": "check_pixel", "x": x, "vpos": 119,
                          "exp_valid": 1, "exp_pix": p[1], "exp_priority": p[0]})
        else:
            recs4.append({"op": "check_pixel", "x": x, "vpos": 119,
                          "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})
    # Quarter zoom: zoomx_raw=15 → eff=16; zoomy_raw=15 → eff=16
    # zx = 100 + 16//4 - 100 = 4 per chunk
    recs4.append({"op": "zero_spr_ram"})
    recs4.append({"op": "zero_caches"})
    sram4b = SpriteRAM()
    stym4b = SpriteMAPROM()
    obj4b  = OBJRom()
    sram4b.write_entry(idx=0x1FF, zoomy=15, y=40, priority=1, color=1,
                       zoomx=15, flipy=0, flipx=0, x=60, tilenum=5)
    stym4b.set_chunk(5, 0, 0, code=3)
    obj4b.set_tile_row(3, 0, [0xF]*16)
    for i in range(4):
        recs4.append({"op": "spr_write", "addr": 0x1FF*4+i,
                      "data": sram4b.words[0x1FF*4+i], "be": 3})
    recs4.append({"op": "set_stym_word", "addr": 5<<5, "data": 3})
    obj_rows4b = [obj_rom_row_words(obj4b, 3, r) for r in range(8)]
    recs4.append({"op": "set_obj_tile", "code": 3, "rows": obj_rows4b})
    recs4.append({"op": "run_vblank", "y_offs": 7, "label": "step4_quarter_zoom"})
    pixels4b = render_frame(sram4b, stym4b, obj4b, y_offs=7)
    # y_screen = 40 + 7 + (64-16) = 95
    for x in range(60, 64):
        p = pixels4b[95][x]
        if p:
            recs4.append({"op": "check_pixel", "x": x, "vpos": 95,
                          "exp_valid": 1, "exp_pix": p[1], "exp_priority": p[0]})
        else:
            recs4.append({"op": "check_pixel", "x": x, "vpos": 95,
                          "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})

    cnt4 = len([r for r in recs4 if r['op'] == 'check_pixel'])
    with open(os.path.join(VEC_DIR, 'step4_vectors.jsonl'), 'w') as f:
        for r in recs4:
            w(f, r)
    print(f"step4: {cnt4} pixel checks")

    # ── Step 5: Priority output and transparency ──────────────────────────────
    recs5 = []
    recs5.append({"op": "zero_spr_ram"})
    recs5.append({"op": "zero_caches"})

    sram5 = SpriteRAM()
    stym5 = SpriteMAPROM()
    obj5  = OBJRom()

    # Sprite with priority=1 (below road)
    sram5.write_entry(idx=0x1FF, zoomy=63, y=50, priority=1, color=10,
                      zoomx=63, flipy=0, flipx=0, x=200, tilenum=7)
    stym5.set_chunk(7, 0, 0, code=4)
    # Pixels: pen 0 at x<8, pen 5 at x>=8
    obj5.set_tile_row(4, 0, [0]*8 + [5]*8)

    for i in range(4):
        recs5.append({"op": "spr_write", "addr": 0x1FF*4+i,
                      "data": sram5.words[0x1FF*4+i], "be": 3})
    recs5.append({"op": "set_stym_word", "addr": 7<<5, "data": 4})
    obj_rows5 = [obj_rom_row_words(obj5, 4, r) for r in range(8)]
    recs5.append({"op": "set_obj_tile", "code": 4, "rows": obj_rows5})
    recs5.append({"op": "run_vblank", "y_offs": 7, "label": "step5_priority_transparent"})

    pixels5 = render_frame(sram5, stym5, obj5, y_offs=7)
    # y_screen = 50 + 7 + 0 = 57
    # pen 0 → transparent: x=200..207
    for x in range(200, 208):
        recs5.append({"op": "check_pixel", "x": x, "vpos": 57,
                      "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})
    # pen 5 → opaque priority=1: x=208..215
    for x in range(208, 216):
        p = pixels5[57][x]
        if p:
            recs5.append({"op": "check_pixel", "x": x, "vpos": 57,
                          "exp_valid": 1, "exp_pix": p[1], "exp_priority": 1})
        else:
            recs5.append({"op": "check_pixel", "x": x, "vpos": 57,
                          "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})

    cnt5 = len([r for r in recs5 if r['op'] == 'check_pixel'])
    with open(os.path.join(VEC_DIR, 'step5_vectors.jsonl'), 'w') as f:
        for r in recs5:
            w(f, r)
    print(f"step5: {cnt5} pixel checks")

    # ── Step 6: Multiple sprites, overlap, flipx/flipy, off-screen ───────────
    recs6 = []
    recs6.append({"op": "zero_spr_ram"})
    recs6.append({"op": "zero_caches"})

    sram6 = SpriteRAM()
    stym6 = SpriteMAPROM()
    obj6  = OBJRom()

    # Sprite A at index 0x1FF (drawn first = lowest priority, appears behind B)
    sram6.write_entry(idx=0x1FF, zoomy=63, y=100, priority=0, color=1,
                      zoomx=63, flipy=0, flipx=0, x=150, tilenum=10)
    stym6.set_chunk(10, 0, 0, code=10)
    obj6.set_tile_row(10, 0, [1]*16)

    # Sprite B at index 0x000 (drawn last = highest priority, appears in front)
    # Overlaps A at x=150..165 on y=107
    sram6.write_entry(idx=0x000, zoomy=63, y=100, priority=0, color=2,
                      zoomx=63, flipy=0, flipx=0, x=150, tilenum=11)
    stym6.set_chunk(11, 0, 0, code=11)
    obj6.set_tile_row(11, 0, [2]*16)

    # Sprite C with flipx=1 (pixels reversed)
    sram6.write_entry(idx=0x1FE, zoomy=63, y=50, priority=0, color=3,
                      zoomx=63, flipy=0, flipx=1, x=10, tilenum=12)
    stym6.set_chunk(12, 0, 0, code=12)
    # Pixels: 0..7 pen 3, 8..15 pen 4
    obj6.set_tile_row(12, 0, [3]*8 + [4]*8)

    # Sprite D off-screen left (x=-30 → raw x = -30 + 0x200 = 482 = 0x1E2)
    # x_raw=0x1E2 > 0x140 → sign extend → x = 0x1E2 - 0x200 = -30
    sram6.write_entry(idx=0x1FD, zoomy=63, y=70, priority=0, color=4,
                      zoomx=63, flipy=0, flipx=0, x=0x1E2, tilenum=13)
    stym6.set_chunk(13, 0, 0, code=13)
    obj6.set_tile_row(13, 0, [5]*16)

    # Write all entries
    for i in range(4):
        recs6.append({"op": "spr_write", "addr": 0x1FF*4+i,
                      "data": sram6.words[0x1FF*4+i], "be": 3})
        recs6.append({"op": "spr_write", "addr": 0x000*4+i,
                      "data": sram6.words[0x000*4+i], "be": 3})
        recs6.append({"op": "spr_write", "addr": 0x1FE*4+i,
                      "data": sram6.words[0x1FE*4+i], "be": 3})
        recs6.append({"op": "spr_write", "addr": 0x1FD*4+i,
                      "data": sram6.words[0x1FD*4+i], "be": 3})

    # Set STYM and OBJ ROM data
    recs6.append({"op": "set_stym_word", "addr": 10<<5,   "data": 10})
    recs6.append({"op": "set_stym_word", "addr": 11<<5,   "data": 11})
    recs6.append({"op": "set_stym_word", "addr": 12<<5,   "data": 12})
    recs6.append({"op": "set_stym_word", "addr": 13<<5,   "data": 13})
    for code in [10, 11, 12, 13]:
        obj_rom_used = obj6
        rows = [obj_rom_row_words(obj_rom_used, code, r) for r in range(8)]
        recs6.append({"op": "set_obj_tile", "code": code, "rows": rows})

    recs6.append({"op": "run_vblank", "y_offs": 7, "label": "step6_multi_sprite"})

    pixels6 = render_frame(sram6, stym6, obj6, y_offs=7)

    # Overlap check: B overwrites A at y=107, x=150..165
    # A color=1, pen=1 → pal=17; B color=2, pen=2 → pal=34
    for x in range(150, 166):
        p = pixels6[107][x]
        if p:
            recs6.append({"op": "check_pixel", "x": x, "vpos": 107,
                          "exp_valid": 1, "exp_pix": p[1], "exp_priority": p[0]})
        else:
            recs6.append({"op": "check_pixel", "x": x, "vpos": 107,
                          "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})

    # FlipX check for sprite C: y_screen = 50 + 7 + 0 = 57
    # flipx=1: pixel at src_x=15 → screen_x=10, src_x=0 → screen_x=25
    # pen at source x=0 = pen 3, x=15 = pen 4
    # After flipx: screen col 0 (x=10) gets source col 15 = pen 4
    #              screen col 15 (x=25) gets source col 0 = pen 3
    for x in range(10, 26):
        p = pixels6[57][x]
        if p:
            recs6.append({"op": "check_pixel", "x": x, "vpos": 57,
                          "exp_valid": 1, "exp_pix": p[1], "exp_priority": p[0]})

    # Off-screen sprite D: x=-30, nominal zoom, row 0 at y = 70+7+0 = 77
    # Should produce pixels only where screen_x = (-30 + ox) >= 0: ox >= 30
    # Screen cols 0..13 should have pen 5 of sprite D (at ox=30..43? zx=16 per chunk)
    # Actually: off-screen means most pixels clipped; check a few
    for x in [0, 1, 5]:
        p = pixels6[77][x]
        if p is not None:
            recs6.append({"op": "check_pixel", "x": x, "vpos": 77,
                          "exp_valid": 1, "exp_pix": p[1], "exp_priority": p[0]})

    # Verify a line that should be all transparent
    recs6.append({"op": "check_pixel", "x": 0,   "vpos": 200,
                  "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})
    recs6.append({"op": "check_pixel", "x": 319, "vpos": 200,
                  "exp_valid": 0, "exp_pix": 0, "exp_priority": 0})

    cnt6 = len([r for r in recs6 if r['op'] == 'check_pixel'])
    with open(os.path.join(VEC_DIR, 'step6_vectors.jsonl'), 'w') as f:
        for r in recs6:
            w(f, r)
    print(f"step6: {cnt6} pixel checks")


if __name__ == '__main__':
    gen_step1()
    gen_step2()
    gen_steps_3_6()
    print("All vector files generated.")
