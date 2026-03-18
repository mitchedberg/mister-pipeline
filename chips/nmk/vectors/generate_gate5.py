#!/usr/bin/env python3
"""
generate_gate5.py — NMK16 Gate 5 test vector generator.

Produces gate5_vectors.jsonl covering all priority scenarios:

  1.  All layers transparent → final_valid=0
  2.  BG1 only → BG1 wins
  3.  BG0 wins over BG1 (BG0 higher priority)
  4.  Sprite prio=0 below BG0: BG0 opaque → BG0 wins
  5.  Sprite prio=0 below BG0: BG0 transparent → sprite wins over BG1
  6.  Sprite prio=1 above all: BG0+BG1 opaque → sprite wins
  7.  Sprite prio=1 transparent → BG0 shows through
  8.  Only BG0 opaque → BG0 wins
  9.  Only sprite prio=1, BG transparent → sprite wins
  10. BG1 only (no BG0, no sprite)
  11. Sprite prio=0, BG1 only (BG0 transparent) → sprite beats BG1
  12. Multiple transparent layers → invalid output
  13. BG0 transparent, sprite prio=0 and BG1 all valid → sprite beats BG1, loses to nothing
  14. All combinations: BG0+BG1+spr prio=0: BG0 wins
  15. All combinations: BG0+BG1+spr prio=1: spr wins

Strategy:
  Gate 5 is purely combinational, driven directly from sprite scanline buffer
  read-back (spr_rd_color/spr_rd_valid/spr_rd_priority) and BG pipe outputs
  (bg_pix_color/bg_pix_valid).

  The testbench (tb_gate5.cpp) uses a direct injection approach:
    - Write a solid sprite tile, place sprite at x=0, rasterize scanline 0,
      then read back spr_rd_addr=0 to get spr_rd_color/spr_rd_valid.
    - Write BG tilemap cells and tile ROM data so Gate 4 produces known
      bg_pix_color/bg_pix_valid values.
    - Check final_color / final_valid after settling.

  To keep vectors simple, each scenario:
    1. reset
    2. Set up sprite and BG state to produce known inputs to Gate 5
    3. check_final  exp_valid, exp_color

Vector operations (processed by tb_gate5.cpp):
  reset                          — DUT reset
  vsync_pulse                    — latch shadow → active registers
  write_tram  layer, row, col, data  — write tilemap RAM word
  write_bg_rom addr, data        — write BG tile ROM byte
  write_spr_rom addr, data       — write sprite ROM byte
  write_sram  addr, data         — write sprite RAM word
  vblank_scan                    — run sprite scanner (VBLANK phase)
  scan_line   scanline           — rasterize one scanline (Gate 3)
  set_spr_rd_addr  x             — set spr_rd_addr for Gate 5 read
  set_bg      bg_x, bg_y        — drive bg pixel coordinate
  clock_n     n                  — advance n clock cycles
  check_final exp_valid, exp_color — check Gate 5 output

NMK16 sprite RAM layout (4 words per sprite, word-addressed):
  Word 0: X position [8:0] in bits [8:0]
  Word 1: Y position [8:0] in bits [8:0]
  Word 2: Tile code [11:0] in bits [11:0]
  Word 3: ATTR — [15:14]=size, [13]=flip_y, [12]=flip_x, [11]=priority,
                 [7:4]=palette[3:0], [3:0]=unused

NMK16 BG tilemap word format:
  [15:12] palette
  [11]    flip_y
  [10]    flip_x
  [9:0]   tile_index

NMK16 sprite ROM layout (4bpp packed):
  One 16x16 tile = 128 bytes
  byte_addr = tile_code * 128 + pix_y * 8 + pix_x // 2
  nibble = rom_byte[7:4] if pix_x is odd, else rom_byte[3:0]
  Transparent = nybble 0x0

Color encoding: {palette[3:0], index[3:0]}
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gate5_model import NMK16ColMix, SprPixel, BgPixel

VEC_DIR  = os.path.dirname(os.path.abspath(__file__))
OUT_PATH = os.path.join(VEC_DIR, 'gate5_vectors.jsonl')

mixer = NMK16ColMix()


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

    def vsync_pulse():
        add({"op": "vsync_pulse"})

    def write_tram(layer, row, col, data):
        add({"op": "write_tram", "layer": layer, "row": row,
             "col": col, "data": data})

    def write_bg_rom(addr, data):
        add({"op": "write_bg_rom", "addr": addr, "data": data})

    def write_spr_rom(addr, data):
        add({"op": "write_spr_rom", "addr": addr, "data": data})

    def write_sram(addr, data):
        add({"op": "write_sram", "addr": addr, "data": data})

    def vblank_scan():
        add({"op": "vblank_scan"})

    def scan_line(scanline):
        add({"op": "scan_line", "scanline": scanline})

    def set_spr_rd_addr(x):
        add({"op": "set_spr_rd_addr", "x": x})

    def set_bg(bg_x, bg_y):
        add({"op": "set_bg", "bg_x": bg_x, "bg_y": bg_y})

    def clock_n(n):
        add({"op": "clock_n", "n": n})

    def check_final(exp_valid, exp_color=0):
        chk({"op": "check_final",
             "exp_valid": int(exp_valid),
             "exp_color": exp_color})

    # ── BG tile helpers ────────────────────────────────────────────────────────

    def make_tram_word(tile_idx, palette, flip_x=0, flip_y=0):
        return ((palette & 0xF) << 12) | ((flip_y & 1) << 11) | \
               ((flip_x & 1) << 10) | (tile_idx & 0x3FF)

    def write_solid_bg_tile(tile_num, nybble):
        """Write a solid 16x16 BG tile (all pixels same nybble)."""
        byte_val = ((nybble & 0xF) << 4) | (nybble & 0xF)
        base = tile_num * 128
        for b in range(128):
            write_bg_rom(base + b, byte_val)

    def setup_bg_layer(layer, tile_num, palette, nybble):
        """Write a solid tile into tilemap row 0 col 0 for the given layer."""
        write_solid_bg_tile(tile_num, nybble)
        word = make_tram_word(tile_num, palette)
        write_tram(layer, 0, 0, word)

    def clear_bg_layer(layer, tile_num):
        """Write a transparent tile (nybble=0) for the given layer."""
        # tile ROM already 0 by default after reset; just write transparent tile
        base = tile_num * 128
        for b in range(128):
            write_bg_rom(base + b, 0x00)
        word = make_tram_word(tile_num, 0)
        write_tram(layer, 0, 0, word)

    # ── Sprite helpers ─────────────────────────────────────────────────────────

    SPRITE_SLOT = 0  # always use slot 0 for Gate 5 tests

    def make_attr(priority_bit, palette, size=1, flip_x=0, flip_y=0):
        """Build sprite ATTR word (word 3)."""
        return ((size & 0x3) << 14) | ((flip_y & 1) << 13) | \
               ((flip_x & 1) << 12) | ((priority_bit & 1) << 11) | \
               ((palette & 0xF) << 4)

    def write_solid_spr_tile(tile_num, nybble):
        """Write a solid 16x16 sprite tile (all pixels same nybble)."""
        byte_val = ((nybble & 0xF) << 4) | (nybble & 0xF)
        base = tile_num * 128
        for b in range(128):
            write_spr_rom(base + b, byte_val)

    def place_sprite(tile_num, palette, priority_bit, x=0, y=0, size=1):
        """Write sprite slot 0 to sprite RAM (4 words)."""
        base = SPRITE_SLOT * 4
        write_sram(base + 0, x & 0x1FF)         # word 0: X
        write_sram(base + 1, y & 0x1FF)         # word 1: Y
        write_sram(base + 2, tile_num & 0xFFF)  # word 2: tile code
        write_sram(base + 3, make_attr(priority_bit, palette))  # word 3: attr

    def clear_sprite():
        """Write sprite slot 0 with off-screen Y (so it doesn't rasterize)."""
        base = SPRITE_SLOT * 4
        write_sram(base + 0, 0)
        write_sram(base + 1, 0xFF)  # Y off-screen
        write_sram(base + 2, 0)
        write_sram(base + 3, 0)

    def rasterize(scanline=0, rd_x=0):
        """Scan + rasterize scanline, then point spr_rd_addr at rd_x."""
        vblank_scan()
        scan_line(scanline)
        set_spr_rd_addr(rd_x)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 1: All transparent → final_valid=0
    # No sprite, no BG (all zero tiles → nybble=0 → transparent)
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 1: all transparent"})
    reset()

    # Clear sprites: off-screen Y
    clear_sprite()
    # BG layers: tile 0 all zeros (transparent) — ROM is zeroed at reset
    write_tram(0, 0, 0, make_tram_word(0, 0))
    write_tram(1, 0, 0, make_tram_word(0, 0))
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    r = mixer.mix(SprPixel(), BgPixel(), BgPixel())
    check_final(r.valid)   # expect 0

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 2: BG1 only opaque → BG1 wins
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 2: BG1 only"})
    reset()

    # Tile 0x001, palette=2, nybble=0x3 → color=0x23
    BG1_TILE = 0x001; BG1_PAL = 2; BG1_NYB = 0x3
    setup_bg_layer(1, BG1_TILE, BG1_PAL, BG1_NYB)
    # BG0: transparent (tile 0 = zeros)
    write_tram(0, 0, 0, make_tram_word(0, 0))
    # No sprite
    clear_sprite()
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg1 = BgPixel(valid=True,  color=(BG1_PAL << 4) | BG1_NYB)
    bg0 = BgPixel(valid=False)
    r = mixer.mix(SprPixel(), bg0, bg1)
    check_final(r.valid, r.color)   # expect valid=1, color=0x23

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 3: BG0 wins over BG1
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 3: BG0 wins over BG1"})
    reset()

    BG0_TILE = 0x002; BG0_PAL = 5; BG0_NYB = 0xA   # color=0x5A
    BG1_TILE = 0x003; BG1_PAL = 2; BG1_NYB = 0x3   # color=0x23 (should lose)
    setup_bg_layer(0, BG0_TILE, BG0_PAL, BG0_NYB)
    setup_bg_layer(1, BG1_TILE, BG1_PAL, BG1_NYB)
    clear_sprite()
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg0 = BgPixel(valid=True, color=(BG0_PAL << 4) | BG0_NYB)
    bg1 = BgPixel(valid=True, color=(BG1_PAL << 4) | BG1_NYB)
    r = mixer.mix(SprPixel(), bg0, bg1)
    check_final(r.valid, r.color)   # expect valid=1, color=0x5A

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 4: Sprite prio=0 below BG0 — BG0 opaque → BG0 wins
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 4: sprite prio=0 loses to opaque BG0"})
    reset()

    BG0_TILE = 0x004; BG0_PAL = 0xA; BG0_NYB = 0x5   # color=0xA5
    SPR_TILE = 0x010; SPR_PAL = 0x3; SPR_NYB = 0xF    # color=0x3F
    setup_bg_layer(0, BG0_TILE, BG0_PAL, BG0_NYB)
    write_tram(1, 0, 0, make_tram_word(0, 0))   # BG1 transparent
    write_solid_spr_tile(SPR_TILE, SPR_NYB)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=0, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg0 = BgPixel(valid=True, color=(BG0_PAL << 4) | BG0_NYB)
    spr = SprPixel(valid=True, color=(SPR_PAL << 4) | SPR_NYB, priority=False)
    r = mixer.mix(spr, bg0, BgPixel())
    check_final(r.valid, r.color)   # expect valid=1, color=0xA5 (BG0 wins)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 5: Sprite prio=0, BG0 transparent → sprite beats BG1
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 5: sprite prio=0 beats BG1 when BG0 transparent"})
    reset()

    BG1_TILE = 0x005; BG1_PAL = 0x1; BG1_NYB = 0x7   # color=0x17
    SPR_TILE = 0x011; SPR_PAL = 0x4; SPR_NYB = 0x8    # color=0x48
    write_tram(0, 0, 0, make_tram_word(0, 0))           # BG0 transparent (tile 0)
    setup_bg_layer(1, BG1_TILE, BG1_PAL, BG1_NYB)
    write_solid_spr_tile(SPR_TILE, SPR_NYB)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=0, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg1 = BgPixel(valid=True, color=(BG1_PAL << 4) | BG1_NYB)
    spr = SprPixel(valid=True, color=(SPR_PAL << 4) | SPR_NYB, priority=False)
    r = mixer.mix(spr, BgPixel(), bg1)
    check_final(r.valid, r.color)   # expect valid=1, color=0x48 (sprite wins)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 6: Sprite prio=1 above all — BG0 and BG1 opaque → sprite wins
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 6: sprite prio=1 above all layers"})
    reset()

    BG0_TILE = 0x006; BG0_PAL = 0xB; BG0_NYB = 0x2   # color=0xB2
    BG1_TILE = 0x007; BG1_PAL = 0x9; BG1_NYB = 0x4   # color=0x94
    SPR_TILE = 0x012; SPR_PAL = 0xE; SPR_NYB = 0xD    # color=0xED
    setup_bg_layer(0, BG0_TILE, BG0_PAL, BG0_NYB)
    setup_bg_layer(1, BG1_TILE, BG1_PAL, BG1_NYB)
    write_solid_spr_tile(SPR_TILE, SPR_NYB)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=1, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg0 = BgPixel(valid=True, color=(BG0_PAL << 4) | BG0_NYB)
    bg1 = BgPixel(valid=True, color=(BG1_PAL << 4) | BG1_NYB)
    spr = SprPixel(valid=True, color=(SPR_PAL << 4) | SPR_NYB, priority=True)
    r = mixer.mix(spr, bg0, bg1)
    check_final(r.valid, r.color)   # expect valid=1, color=0xED (sprite wins)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 7: Sprite prio=1 transparent → BG0 shows through
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 7: transparent sprite prio=1 falls through to BG0"})
    reset()

    BG0_TILE = 0x008; BG0_PAL = 0x6; BG0_NYB = 0xC   # color=0x6C
    # Sprite tile with all nybble=0 (transparent)
    SPR_TILE = 0x013; SPR_PAL = 0x7
    write_tram(0, 0, 0, make_tram_word(BG0_TILE, BG0_PAL))
    write_solid_bg_tile(BG0_TILE, BG0_NYB)
    write_tram(1, 0, 0, make_tram_word(0, 0))           # BG1 transparent
    # Sprite tile all zeros (transparent)
    for b in range(128):
        write_spr_rom(SPR_TILE * 128 + b, 0x00)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=1, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg0 = BgPixel(valid=True, color=(BG0_PAL << 4) | BG0_NYB)
    spr_trans = SprPixel(valid=False, priority=True)  # transparent
    r = mixer.mix(spr_trans, bg0, BgPixel())
    check_final(r.valid, r.color)   # expect valid=1, color=0x6C (BG0 shows)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 8: Only BG0 opaque (no sprite, BG1 transparent)
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 8: only BG0 opaque"})
    reset()

    BG0_TILE = 0x009; BG0_PAL = 0x3; BG0_NYB = 0x6   # color=0x36
    setup_bg_layer(0, BG0_TILE, BG0_PAL, BG0_NYB)
    write_tram(1, 0, 0, make_tram_word(0, 0))
    clear_sprite()
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg0 = BgPixel(valid=True, color=(BG0_PAL << 4) | BG0_NYB)
    r = mixer.mix(SprPixel(), bg0, BgPixel())
    check_final(r.valid, r.color)   # expect valid=1, color=0x36

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 9: Only sprite prio=1, both BG transparent → sprite wins
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 9: only sprite prio=1, BG transparent"})
    reset()

    SPR_TILE = 0x014; SPR_PAL = 0xF; SPR_NYB = 0xA   # color=0xFA
    write_tram(0, 0, 0, make_tram_word(0, 0))
    write_tram(1, 0, 0, make_tram_word(0, 0))
    write_solid_spr_tile(SPR_TILE, SPR_NYB)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=1, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    spr = SprPixel(valid=True, color=(SPR_PAL << 4) | SPR_NYB, priority=True)
    r = mixer.mix(spr, BgPixel(), BgPixel())
    check_final(r.valid, r.color)   # expect valid=1, color=0xFA

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 10: Sprite prio=0 only (no BG) → sprite wins
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 10: sprite prio=0 only, BG transparent"})
    reset()

    SPR_TILE = 0x015; SPR_PAL = 0x2; SPR_NYB = 0xB   # color=0x2B
    write_tram(0, 0, 0, make_tram_word(0, 0))
    write_tram(1, 0, 0, make_tram_word(0, 0))
    write_solid_spr_tile(SPR_TILE, SPR_NYB)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=0, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    spr = SprPixel(valid=True, color=(SPR_PAL << 4) | SPR_NYB, priority=False)
    r = mixer.mix(spr, BgPixel(), BgPixel())
    check_final(r.valid, r.color)   # expect valid=1, color=0x2B

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 11: BG1 + sprite prio=0 (BG0 transparent) → sprite beats BG1
    # (same logic as scenario 5, explicit model cross-check)
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 11: BG1 + sprite prio=0 (cross-check)"})
    reset()

    BG1_TILE = 0x00A; BG1_PAL = 0xD; BG1_NYB = 0x1   # color=0xD1
    SPR_TILE = 0x016; SPR_PAL = 0x8; SPR_NYB = 0xE    # color=0x8E
    write_tram(0, 0, 0, make_tram_word(0, 0))
    setup_bg_layer(1, BG1_TILE, BG1_PAL, BG1_NYB)
    write_solid_spr_tile(SPR_TILE, SPR_NYB)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=0, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg1 = BgPixel(valid=True, color=(BG1_PAL << 4) | BG1_NYB)
    spr = SprPixel(valid=True, color=(SPR_PAL << 4) | SPR_NYB, priority=False)
    r = mixer.mix(spr, BgPixel(), bg1)
    check_final(r.valid, r.color)   # expect valid=1, color=0x8E

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 12: Multiple transparent layers → invalid
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 12: multiple transparent layers → invalid"})
    reset()

    # All tiles transparent, sprite off-screen
    write_tram(0, 0, 0, make_tram_word(0, 0))
    write_tram(1, 0, 0, make_tram_word(0, 0))
    clear_sprite()
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    r = mixer.mix(SprPixel(), BgPixel(), BgPixel())
    check_final(r.valid)   # expect 0

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 13: All layers opaque with sprite prio=0 — BG0 final winner
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 13: all opaque, sprite prio=0 → BG0 wins"})
    reset()

    BG0_TILE = 0x00B; BG0_PAL = 0x5; BG0_NYB = 0x9   # color=0x59
    BG1_TILE = 0x00C; BG1_PAL = 0x3; BG1_NYB = 0x2   # color=0x32
    SPR_TILE = 0x017; SPR_PAL = 0xC; SPR_NYB = 0x7    # color=0xC7
    setup_bg_layer(0, BG0_TILE, BG0_PAL, BG0_NYB)
    setup_bg_layer(1, BG1_TILE, BG1_PAL, BG1_NYB)
    write_solid_spr_tile(SPR_TILE, SPR_NYB)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=0, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg0 = BgPixel(valid=True, color=(BG0_PAL << 4) | BG0_NYB)
    bg1 = BgPixel(valid=True, color=(BG1_PAL << 4) | BG1_NYB)
    spr = SprPixel(valid=True, color=(SPR_PAL << 4) | SPR_NYB, priority=False)
    r = mixer.mix(spr, bg0, bg1)
    check_final(r.valid, r.color)   # expect valid=1, color=0x59 (BG0 wins)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 14: All layers opaque with sprite prio=1 — sprite final winner
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 14: all opaque, sprite prio=1 → sprite wins"})
    reset()

    BG0_TILE = 0x00D; BG0_PAL = 0x7; BG0_NYB = 0x3   # color=0x73
    BG1_TILE = 0x00E; BG1_PAL = 0x6; BG1_NYB = 0x5   # color=0x65
    SPR_TILE = 0x018; SPR_PAL = 0x1; SPR_NYB = 0xF    # color=0x1F
    setup_bg_layer(0, BG0_TILE, BG0_PAL, BG0_NYB)
    setup_bg_layer(1, BG1_TILE, BG1_PAL, BG1_NYB)
    write_solid_spr_tile(SPR_TILE, SPR_NYB)
    place_sprite(SPR_TILE, SPR_PAL, priority_bit=1, x=0, y=0)
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg0 = BgPixel(valid=True, color=(BG0_PAL << 4) | BG0_NYB)
    bg1 = BgPixel(valid=True, color=(BG1_PAL << 4) | BG1_NYB)
    spr = SprPixel(valid=True, color=(SPR_PAL << 4) | SPR_NYB, priority=True)
    r = mixer.mix(spr, bg0, bg1)
    check_final(r.valid, r.color)   # expect valid=1, color=0x1F (sprite wins)

    # ══════════════════════════════════════════════════════════════════════════
    # Scenario 15: Only BG1 opaque — different palette, verify color encoding
    # ══════════════════════════════════════════════════════════════════════════
    add({"op": "comment", "text": "Scenario 15: BG1 various palette/color values"})
    reset()

    BG1_TILE = 0x00F; BG1_PAL = 0xE; BG1_NYB = 0xB   # color=0xEB
    setup_bg_layer(1, BG1_TILE, BG1_PAL, BG1_NYB)
    write_tram(0, 0, 0, make_tram_word(0, 0))
    clear_sprite()
    vsync_pulse()
    set_bg(0, 0)
    rasterize(0, 0)
    clock_n(4)

    bg1 = BgPixel(valid=True, color=(BG1_PAL << 4) | BG1_NYB)
    r = mixer.mix(SprPixel(), BgPixel(), bg1)
    check_final(r.valid, r.color)   # expect valid=1, color=0xEB

    # ══════════════════════════════════════════════════════════════════════════
    # Write output
    # ══════════════════════════════════════════════════════════════════════════
    with open(OUT_PATH, 'w') as f:
        for r in recs:
            f.write(json.dumps(r) + '\n')

    print(f"gate5: {check_count} checks → {OUT_PATH}")
    return check_count


if __name__ == '__main__':
    n = generate()
    print(f"Total: {n} test checks generated.")
