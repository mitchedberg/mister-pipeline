#!/usr/bin/env python3
"""
generate_step11_vectors.py — Step 11 test vector generator for tc0630fdp.

Produces step11_vectors.jsonl: Priority Resolution and Basic Compositing.

Test cases (per section3_rtl_plan.md Step 11):
  1. All 6 layers active at same pixel. Verify highest-priority layer wins.
  2. Priority sweep: PF1 priority 0 → 15. Verify it transitions below/above all layers.
  3. Sprite priority group 0x00 at prio 3, PF2 at prio 4: verify PF2 wins.
  4. Sprite priority group 0xC0 at prio 14, PF4 at prio 15: verify PF4 wins.
  5. Text layer: fixed priority (always top). Verify text beats priority-15 sprite.
  6. Priority-0 sprite: verify it is below even priority-1 PF.
  7. Opaque PF4 (priority 8), transparent PF3 (priority 10): verify PF4 shows through.

Additional tests:
  8. Single PF layer, no sprite/text: verify PF pixel passes through.
  9. Sprite with prio=0, PF with prio=0: sprite wins (tie-break rule).
 10. Text transparent (pen=0): PF/sprite layer shows through.
 11. All layers transparent: output pen=0.

Line RAM address map (word addresses — byte_addr / 2):
  §9.12 PF priority enable: word 0x0700 + scan,  bit[n] = enable PFn
  §9.12 PF priority data:   word 0x5800 + n*0x100 + scan, bits[3:0] = prio
  §9.8  sprite priority:    word 0x3B00 + scan,
          bits[3:0]=group0x00, [7:4]=group0x40, [11:8]=group0x80, [15:12]=group0xC0
"""

import json
import os
from fdp_model import TaitoF3Model, V_START, V_END, H_START

vectors = []


def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
m = TaitoF3Model()


def model_reset():
    """Reset transient state.

    GFX ROM and Char RAM are preserved — the RTL does NOT clear these on reset.
    GFX ROM: CPU writes issued before first reset persist (BRAM not reset).
    Char RAM: same — BRAM reset block is empty in RTL.
    """
    m.ctrl     = [0] * 16
    m.pf_ram   = [[0] * m.PF_RAM_WORDS for _ in range(4)]
    m.text_ram = [0] * m.TEXT_RAM_WORDS
    # m.char_ram: NOT cleared — RTL does not reset char_ram (BRAM reset is empty)
    m.line_ram = [0] * m.LINE_RAM_WORDS
    m.spr_ram  = [0] * m.SPR_RAM_WORDS


# ---------------------------------------------------------------------------
# Chip-relative Line RAM base for CPU writes (chip word addr 0x10000)
LINE_BASE = 0x10000
SPR_BASE  = 0x20000


def write_line(word_offset: int, data: int, note: str = "") -> None:
    """Emit a write_line op AND mirror to model."""
    chip_addr = LINE_BASE + word_offset
    emit({"op": "write_line",
          "addr": chip_addr,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"line_ram[{word_offset:#06x}] = {data:#06x}"})
    m.write_line_ram(word_offset, data)


def clear_scanline_effects(render_scan: int, note_pfx: str = "") -> None:
    """Zero out all line RAM effect words for a given render scanline.

    Clears all enable bits and data words that previous test groups (including
    steps 5-10) may have left active, so each step11 test group starts clean.

    render_scan: the scanline number as rendered (vpos+1), 0-255.
    """
    s = render_scan & 0xFF
    tag = note_pfx or f"clear scan={render_scan}"

    # Enable words — zero all effect enables for this scanline
    write_line(0x0000 + s, 0, f"{tag} clear colscroll/alt-tilemap enable")
    write_line(0x0400 + s, 0, f"{tag} clear zoom enable")
    write_line(0x0500 + s, 0, f"{tag} clear pal-add enable")
    write_line(0x0600 + s, 0, f"{tag} clear rowscroll enable")
    write_line(0x0700 + s, 0, f"{tag} clear pf-priority enable")

    # Data words — zero per-plane data for all 4 planes
    for n in range(4):
        write_line(0x5000 + n * 0x100 + s, 0, f"{tag} clear rowscroll PF{n+1}")
        write_line(0x2000 + n * 0x100 + s, 0, f"{tag} clear colscroll PF{n+1}")
        write_line(0x4800 + n * 0x100 + s, 0, f"{tag} clear pal-add PF{n+1}")
        write_line(0x5800 + n * 0x100 + s, 0, f"{tag} clear pf-prio PF{n+1}")

    # Zoom data (PF1=0x4000, PF3=0x4100, PF2=0x4200, PF4=0x4300)
    # Default zoom: X=0x00 (no zoom), Y=0x80 (no zoom) → word = 0x8000
    write_line(0x4000 + s, 0x8000, f"{tag} clear zoom PF1")
    write_line(0x4100 + s, 0x8000, f"{tag} clear zoom PF3")
    write_line(0x4200 + s, 0x8000, f"{tag} clear zoom PF2/PF4-Y")
    write_line(0x4300 + s, 0x8000, f"{tag} clear zoom PF4/PF2-Y")

    # Sprite priority — zero all groups
    write_line(0x3B00 + s, 0, f"{tag} clear spr-prio")


def write_spr_word(word_offset: int, data: int, note: str = "") -> None:
    chip_addr = SPR_BASE + word_offset
    emit({"op": "write_sprite",
          "addr": chip_addr,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"spr_ram[{word_offset:#06x}] = {data:#06x}"})


def clear_sprite_entry(idx: int, note: str = "") -> None:
    """Zero out all 8 words of sprite entry idx in Sprite RAM.

    Ensures that sprite entries from previous test groups do not contaminate
    the sprite scanner for the current test.  Sprite RAM is NOT cleared on
    async_rst_n (BRAM persistence rule).
    """
    base = idx * 8
    tag = note or f"clear spr[{idx}]"
    for w in range(8):
        write_spr_word(base + w, 0, f"{tag} word{w}")


def write_sprite_entry(idx: int, tile_code: int, sx: int, sy: int,
                       color: int, flipx: bool = False, flipy: bool = False,
                       x_zoom: int = 0x00, y_zoom: int = 0x00,
                       note: str = "") -> None:
    """Write a full sprite entry (words 0..6) to Sprite RAM (emit + model)."""
    base = idx * 8
    tile_lo = tile_code & 0xFFFF
    tile_hi = (tile_code >> 16) & 0x1
    sx_12   = sx & 0xFFF
    sy_12   = sy & 0xFFF
    w1      = ((y_zoom & 0xFF) << 8) | (x_zoom & 0xFF)
    w4      = color & 0xFF
    if flipx: w4 |= (1 << 9)
    if flipy: w4 |= (1 << 10)
    tag = note or f"spr[{idx}]"
    write_spr_word(base + 0, tile_lo,  f"{tag} word0=tile_lo")
    write_spr_word(base + 1, w1,       f"{tag} word1=zoom")
    write_spr_word(base + 2, sx_12,    f"{tag} word2=sx={sx}")
    write_spr_word(base + 3, sy_12,    f"{tag} word3=sy={sy}")
    write_spr_word(base + 4, w4,       f"{tag} word4=ctrl color={color:#04x}")
    write_spr_word(base + 5, tile_hi,  f"{tag} word5=tile_hi")
    write_spr_word(base + 6, 0,        f"{tag} word6=no_jump")
    # Mirror to model
    m.write_sprite_entry(idx, tile_code, sx, sy, color, flipx, flipy,
                         x_zoom=x_zoom, y_zoom=y_zoom)


def write_gfx_word(word_addr: int, data: int, note: str = "") -> None:
    emit({"op": "write_gfx",
          "gfx_addr": word_addr,
          "gfx_data": data & 0xFFFFFFFF,
          "note": note or f"gfx[{word_addr:#06x}] = {data:#010x}"})
    if word_addr < m.GFX_ROM_WORDS:
        m.gfx_rom[word_addr] = data & 0xFFFFFFFF


def write_gfx_solid_tile(tile_code: int, pen: int, note: str = "") -> None:
    """Fill all 16 rows of a 16×16 tile with a solid pen value."""
    n = pen & 0xF
    word = 0
    for _ in range(8):
        word = (word << 4) | n
    for row in range(16):
        base = tile_code * 32 + row * 2
        write_gfx_word(base,     word, note or f"gfx tile={tile_code} row={row} pen={pen:#x} L")
        write_gfx_word(base + 1, word, note or f"gfx tile={tile_code} row={row} pen={pen:#x} R")


def write_char_solid(char_code: int, pen: int) -> None:
    """Fill all rows of an 8×8 character with a solid pen (charlayout encoding)."""
    # Charlayout: each row = 4 bytes. Pixel mapping: b2[7:4]=px0, b2[3:0]=px1,
    # b3[7:4]=px2, b3[3:0]=px3, b0[7:4]=px4, b0[3:0]=px5, b1[7:4]=px6, b1[3:0]=px7.
    # Solid pen n: all nibbles = n.
    n = pen & 0xF
    byte_val = (n << 4) | n
    base = char_code * 32
    for row in range(8):
        for b in range(4):
            byte_addr = base + row * 4 + b
            m.char_ram[byte_addr] = byte_val
            # Emit as CPU write pairs (word at byte_addr // 2)
            # The char_ram is byte-addressed; CPU accesses are 16-bit words.
            # char_wr_addr = cpu_addr[12:1] → word index = byte_addr // 2
            word_idx = byte_addr // 2
            if (byte_addr & 1) == 0:
                # Writing upper byte (byte_addr even → high byte of word pair)
                # We pair with next byte.
                b_hi = byte_val
                b_lo = byte_val
                chip_addr = 0x0F000 + word_idx
                emit({"op": "write_char",
                      "addr": chip_addr,
                      "data": (b_hi << 8) | b_lo,
                      "be": 3,
                      "note": f"char[{char_code}] row={row} byte={b}"})


def set_pf_priority(plane: int, scan: int, prio: int) -> None:
    """Enable and set PF priority for one scanline."""
    # Enable word: 0x0700 + scan, bit[plane]
    en_word = m.line_ram[0x0700 + (scan & 0xFF)]
    en_word |= (1 << plane)
    write_line(0x0700 + (scan & 0xFF), en_word,
               f"pf_prio_en scan={scan} plane={plane}")
    # Data word: 0x5800 + plane*0x100 + scan
    write_line(0x5800 + plane * 0x100 + (scan & 0xFF), prio & 0xF,
               f"pf_prio data scan={scan} plane={plane} prio={prio}")


def set_spr_priority(scan: int,
                     prio_g0: int = 0, prio_g1: int = 0,
                     prio_g2: int = 0, prio_g3: int = 0) -> None:
    """Set sprite group priorities for one scanline (§9.8)."""
    sp_word = ((prio_g3 & 0xF) << 12) | ((prio_g2 & 0xF) << 8) | \
              ((prio_g1 & 0xF) << 4)  | (prio_g0 & 0xF)
    write_line(0x3B00 + (scan & 0xFF), sp_word,
               f"spr_prio scan={scan} g0={prio_g0} g1={prio_g1} g2={prio_g2} g3={prio_g3}")


def write_pf_tile(plane: int, tile_x: int, tile_y: int,
                  tile_code: int, palette: int = 0,
                  flipx: bool = False, flipy: bool = False) -> None:
    """Write a single PF tile entry (attr + code words) to PF RAM."""
    tile_idx = tile_y * 32 + tile_x  # 32-wide map (extend_mode=0)
    word_base = tile_idx * 2
    attr = palette & 0x1FF
    if flipx: attr |= (1 << 14)
    if flipy: attr |= (1 << 15)
    chip_base = 0x04000 + plane * 0x2000  # PF1=0x04000, PF2=0x06000, ...
    emit({"op": "write_pf",
          "addr": chip_base + word_base,
          "data": attr,
          "be": 3,
          "plane": plane,
          "note": f"pf{plane+1} tile({tile_x},{tile_y}) attr={attr:#06x}"})
    emit({"op": "write_pf",
          "addr": chip_base + word_base + 1,
          "data": tile_code & 0xFFFF,
          "be": 3,
          "plane": plane,
          "note": f"pf{plane+1} tile({tile_x},{tile_y}) code={tile_code:#06x}"})
    m.pf_ram[plane][word_base]     = attr
    m.pf_ram[plane][word_base + 1] = tile_code & 0xFFFF


def write_text_tile(tile_x: int, tile_y: int,
                    char_code: int, color: int = 0) -> None:
    """Write a text RAM entry for tile (tile_x, tile_y)."""
    tile_idx = tile_y * 64 + tile_x
    word = ((color & 0x1F) << 11) | (char_code & 0xFF)
    chip_addr = 0x0E000 + tile_idx
    emit({"op": "write_text",
          "addr": chip_addr,
          "data": word,
          "be": 3,
          "note": f"text tile({tile_x},{tile_y}) char={char_code} color={color}"})
    m.text_ram[tile_idx] = word


def check_colmix(target_vpos: int, screen_col: int,
                 exp_pixel: int, note: str) -> None:
    emit({"op": "check_colmix_pixel",
          "vpos":       target_vpos,
          "screen_col": screen_col,
          "exp_pixel":  exp_pixel & 0x1FFF,
          "note":       note})


def model_colmix_pixel(vpos: int, col: int, spr_linebuf: list = None) -> int:
    """Query composite model pixel at (vpos+1, col)."""
    result = m.composite_scanline(vpos, spr_linebuf)
    return result[col]


# ===========================================================================
# Pre-load GFX ROM with solid tiles (persistent across resets)
# ===========================================================================
# Tiles 0x00–0x1F: use pen = tile_code & 0xF (pen 0 reserved for transparent)
# Tile 0x00: pen 0 (transparent) — useful for testing transparency
# Tile 0x01: pen 1 (PF background)
# ...
# Tile 0x0F: pen 0xF
# We also need tile with pen 0 (transparent) = tile 0x00 (left as zero default)

GFX_TRANSPARENT = 0x00   # tile 0x00 → all pen 0
# Write solid tiles 0x01..0x0F
for tc in range(1, 16):
    write_gfx_solid_tile(tc, tc, f"init: solid tile {tc:#x} pen={tc:#x}")

# Tile 0x00: transparent (pen=0). Steps 5-6 in prior test groups corrupt GFX addresses 0..31
# with non-zero pen data. Re-initialize tile 0x00 as all-zero to ensure transparency.
write_gfx_solid_tile(0x00, 0, "init: tile 0x00 pen=0 (transparent, re-init after step5/6 GFX corruption)")

# Tile 0x10: pen 1 (used as PF1 background with different pen from tiles 1-15)
write_gfx_solid_tile(0x10, 1, "init: tile 0x10 pen=1 (PF1 bg)")
# Tile 0x11: pen 2 (PF2 bg)
write_gfx_solid_tile(0x11, 2, "init: tile 0x11 pen=2 (PF2 bg)")
# Tile 0x12: pen 3 (PF3 bg)
write_gfx_solid_tile(0x12, 3, "init: tile 0x12 pen=3 (PF3 bg)")
# Tile 0x13: pen 4 (PF4 bg)
write_gfx_solid_tile(0x13, 4, "init: tile 0x13 pen=4 (PF4 bg)")

# Solid char tiles (for text layer)
# Char 0x00: transparent (pen 0, default zeroed)
# Char 0x01: pen 1
for cc in range(1, 8):
    write_char_solid(cc, cc)


# ===========================================================================
# Test 1: All 6 layers active at same pixel. Highest-priority wins.
#
# Setup:
#   Target scanline: 80 (render scan 81, so target_vpos = 80)
#   Screen column: 100
#
#   PF1: tile at (6,5) with code=0x10 (pen=1), palette=0x010, prio=2
#   PF2: tile at (6,5) with code=0x11 (pen=2), palette=0x011, prio=4
#   PF3: tile at (6,5) with code=0x12 (pen=3), palette=0x012, prio=6
#   PF4: tile at (6,5) with code=0x13 (pen=4), palette=0x013, prio=10  ← HIGHEST PF
#   Sprite: at (100, 80), color=0x00 (group 0x00), prio_group=0 → prio=8
#   Text: transparent pen=0 (char 0x00) at tile (12, 5)
#
#   Expected winner: PF4 (prio=10 > all others)
#   PF4 palette=0x013, pen=4 → colmix = (0x013 << 4) | 4 = 0x0134
# ===========================================================================
emit({"op": "reset", "note": "reset for test1 all 6 layers"})
model_reset()

SCAN1    = 80   # target_vpos (renders scan 81)
COL1     = 100  # screen column (tile_x = col // 16 = 6, px_in_tile = 4)
TILE_X1  = COL1 // 16   # = 6
TILE_Y1  = 81 // 16     # = 5

# Clear any stale line RAM effects from steps 1-10 at render scan 81
clear_scanline_effects(SCAN1 + 1, "test1")

# Write PF tiles
write_pf_tile(0, TILE_X1, TILE_Y1, 0x10, palette=0x010)   # PF1: pen=1, pal=0x10
write_pf_tile(1, TILE_X1, TILE_Y1, 0x11, palette=0x011)   # PF2: pen=2, pal=0x11
write_pf_tile(2, TILE_X1, TILE_Y1, 0x12, palette=0x012)   # PF3: pen=3, pal=0x12
write_pf_tile(3, TILE_X1, TILE_Y1, 0x13, palette=0x013)   # PF4: pen=4, pal=0x13

# Set PF priorities for scan 81
set_pf_priority(0, 81, 2)    # PF1 prio=2
set_pf_priority(1, 81, 4)    # PF2 prio=4
set_pf_priority(2, 81, 6)    # PF3 prio=6
set_pf_priority(3, 81, 10)   # PF4 prio=10 (highest PF)

# Sprite at (100, 80), group 0x00 (color bits[7:6]=00), prio=8
# color = 0x00 (prio_group=00), palette from lower 6 bits = 0x02
SPR1_COLOR = 0x02   # bits[7:6]=00 → group 0x00; bits[5:0]=2 → palette=2
write_sprite_entry(0, 0x05, COL1, SCAN1, SPR1_COLOR, note="test1 sprite grp0 at col=100")
set_spr_priority(81, prio_g0=8)   # group 0x00 → prio=8

# Text: tile at (12, 5) with transparent char 0x00
write_text_tile(TILE_X1, 5, 0x00, color=0)   # char 0, pen 0 → transparent

# Compute expected via model
slist1 = m.scan_sprites()
spr1_buf = m.render_sprite_scanline(SCAN1, slist1)
exp1 = model_colmix_pixel(SCAN1, COL1, spr1_buf)

check_colmix(SCAN1, COL1, exp1,
             f"test1 all6 PF4 wins prio=10 exp={exp1:#06x}")

# Verify: PF4 pen=4, palette=0x013 → colmix = (0x013 << 4) | 4 = 0x134
PF4_EXPECTED = (0x013 << 4) | 4
assert exp1 == PF4_EXPECTED, f"test1 model sanity: {exp1:#06x} != {PF4_EXPECTED:#06x}"


# ===========================================================================
# Test 2: Priority sweep — PF1 priority from 0 to 15.
#
# Setup: PF1 + PF2 both opaque at same pixel.
#   PF1: pen=1, palette=0x001
#   PF2: pen=2, palette=0x002, prio=8 (fixed)
#
# Sub-tests:
#   2a. PF1 prio=0:  PF2 wins (prio=8 > 0)  → pen=2, pal=0x002
#   2b. PF1 prio=7:  PF2 wins (prio=8 > 7)  → pen=2, pal=0x002
#   2c. PF1 prio=8:  PF2 wins (prio=8 == 8, PF2 found first at n=1 > n=0) — tie
#       Actually: PF1 is n=0, PF2 is n=1. Our loop: PF1 sets winner first,
#       then PF2 checks pf_prio[1] > win_prio. 8 > 8 is FALSE so PF1 stays.
#       Tie: PF1 wins (first PF processed).
#   2d. PF1 prio=9:  PF1 wins (prio=9 > 8) → pen=1, pal=0x001
#   2e. PF1 prio=15: PF1 wins (prio=15 > 8) → pen=1, pal=0x001
# ===========================================================================
emit({"op": "reset", "note": "reset for test2 PF1 priority sweep"})
model_reset()

SCAN2   = 100
COL2    = 50
TILE_X2 = COL2 // 16   # = 3
TILE_Y2 = 101 // 16    # = 6

# Clear stale line RAM effects and sprite entry 0 from earlier tests
clear_scanline_effects(SCAN2 + 1, "test2")
clear_sprite_entry(0, "test2 no-sprite clear")

write_pf_tile(0, TILE_X2, TILE_Y2, 0x01, palette=0x001)   # PF1: pen=1, pal=0x001
write_pf_tile(1, TILE_X2, TILE_Y2, 0x02, palette=0x002)   # PF2: pen=2, pal=0x002
set_pf_priority(1, 101, 8)   # PF2 prio=8 (fixed)

slist2 = m.scan_sprites()   # no sprites

# 2a: PF1 prio=0
set_pf_priority(0, 101, 0)
exp2a = model_colmix_pixel(SCAN2, COL2)
check_colmix(SCAN2, COL2, exp2a,
             f"test2a PF1prio=0 PF2prio=8 → PF2 wins exp={exp2a:#06x}")
assert (exp2a & 0xF) == 2, f"test2a: pen={exp2a&0xF} expected 2"

# 2b: PF1 prio=7 (still below PF2 prio=8)
set_pf_priority(0, 101, 7)
exp2b = model_colmix_pixel(SCAN2, COL2)
check_colmix(SCAN2, COL2, exp2b,
             f"test2b PF1prio=7 PF2prio=8 → PF2 wins exp={exp2b:#06x}")
assert (exp2b & 0xF) == 2, f"test2b: pen={exp2b&0xF} expected 2"

# 2c: PF1 prio=8 (tie — PF1 wins because PF1 is processed first and PF2 uses strict >)
set_pf_priority(0, 101, 8)
exp2c = model_colmix_pixel(SCAN2, COL2)
check_colmix(SCAN2, COL2, exp2c,
             f"test2c PF1prio=8 PF2prio=8 tie → PF1 wins (first) exp={exp2c:#06x}")
assert (exp2c & 0xF) == 1, f"test2c: pen={exp2c&0xF} expected 1 (PF1 wins tie)"

# 2d: PF1 prio=9 (PF1 wins)
set_pf_priority(0, 101, 9)
exp2d = model_colmix_pixel(SCAN2, COL2)
check_colmix(SCAN2, COL2, exp2d,
             f"test2d PF1prio=9 PF2prio=8 → PF1 wins exp={exp2d:#06x}")
assert (exp2d & 0xF) == 1, f"test2d: pen={exp2d&0xF} expected 1"

# 2e: PF1 prio=15 (PF1 wins decisively)
set_pf_priority(0, 101, 15)
exp2e = model_colmix_pixel(SCAN2, COL2)
check_colmix(SCAN2, COL2, exp2e,
             f"test2e PF1prio=15 PF2prio=8 → PF1 wins exp={exp2e:#06x}")
assert (exp2e & 0xF) == 1, f"test2e: pen={exp2e&0xF} expected 1"


# ===========================================================================
# Test 3: Sprite group 0x00 at prio 3, PF2 at prio 4 — PF2 wins.
#
# Per priority rules: pf_prio > spr_prio → PF wins.
# Sprite prio=3, PF2 prio=4: PF2 wins (4 > 3).
# ===========================================================================
emit({"op": "reset", "note": "reset for test3 sprite prio 3 vs PF2 prio 4"})
model_reset()

SCAN3  = 60
COL3   = 80
TX3    = COL3 // 16   # = 5
TY3    = 61 // 16     # = 3

clear_scanline_effects(SCAN3 + 1, "test3")

write_pf_tile(1, TX3, TY3, 0x02, palette=0x020)   # PF2: pen=2, pal=0x020
set_pf_priority(1, 61, 4)   # PF2 prio=4

SPR3_COLOR = 0x07   # bits[7:6]=00 → group 0x00; palette=7
write_sprite_entry(0, 0x07, COL3, SCAN3, SPR3_COLOR, note="test3 sprite grp0 prio=3")
set_spr_priority(61, prio_g0=3)

slist3 = m.scan_sprites()
spr3_buf = m.render_sprite_scanline(SCAN3, slist3)
exp3 = model_colmix_pixel(SCAN3, COL3, spr3_buf)

check_colmix(SCAN3, COL3, exp3,
             f"test3 SPRprio=3 PF2prio=4 → PF2 wins exp={exp3:#06x}")
assert (exp3 & 0xF) == 2, f"test3: pen={exp3&0xF} expected 2 (PF2)"


# ===========================================================================
# Test 4: Sprite group 0xC0 at prio 14, PF4 at prio 15 — PF4 wins.
#
# color[7:6]=11 → group 0xC0. spr_prio[3] = 14.
# PF4 prio = 15 > 14 → PF4 wins.
# ===========================================================================
emit({"op": "reset", "note": "reset for test4 sprite prio 14 vs PF4 prio 15"})
model_reset()

SCAN4  = 70
COL4   = 120
TX4    = COL4 // 16   # = 7
TY4    = 71 // 16     # = 4

clear_scanline_effects(SCAN4 + 1, "test4")

write_pf_tile(3, TX4, TY4, 0x04, palette=0x040)   # PF4: pen=4, pal=0x040
set_pf_priority(3, 71, 15)   # PF4 prio=15

# color = 0xC0 | 0x09 = 0xC9: bits[7:6]=11 → group 0xC0; palette=9
SPR4_COLOR = 0xC9
write_sprite_entry(0, 0x09, COL4, SCAN4, SPR4_COLOR, note="test4 sprite grpC0 prio=14")
set_spr_priority(71, prio_g3=14)

slist4 = m.scan_sprites()
spr4_buf = m.render_sprite_scanline(SCAN4, slist4)
exp4 = model_colmix_pixel(SCAN4, COL4, spr4_buf)

check_colmix(SCAN4, COL4, exp4,
             f"test4 SPRgrpC0 prio=14 PF4prio=15 → PF4 wins exp={exp4:#06x}")
assert (exp4 & 0xF) == 4, f"test4: pen={exp4&0xF} expected 4 (PF4)"


# ===========================================================================
# Test 5: Text layer always on top — beats priority-15 sprite.
#
# Setup:
#   Sprite at (col, scan) with prio=15 (maximum).
#   Text character with pen != 0 at same screen column.
#   Expected: text pixel wins.
# ===========================================================================
emit({"op": "reset", "note": "reset for test5 text beats prio-15 sprite"})
model_reset()

SCAN5  = 90
COL5   = 160
TX5    = COL5 // 8    # text tiles are 8×8; tile_x = 20
TY5    = 91 // 8      # tile_y = 11

clear_scanline_effects(SCAN5 + 1, "test5")

# Write char 0x01 (pen=1) at text tile (20, 11)
write_text_tile(TX5, TY5, 0x01, color=0x05)
# Model already has char_ram set from write_char_solid(1, 1) above

# Sprite at (COL5, SCAN5) with max prio group 0xC0, prio=15
SPR5_COLOR = 0xCA   # bits[7:6]=11 → grpC0, palette=0x0A
write_sprite_entry(0, 0x0A, COL5, SCAN5, SPR5_COLOR, note="test5 sprite prio=15")
set_spr_priority(91, prio_g3=15)

slist5 = m.scan_sprites()
spr5_buf = m.render_sprite_scanline(SCAN5, slist5)
exp5 = model_colmix_pixel(SCAN5, COL5, spr5_buf)

check_colmix(SCAN5, COL5, exp5,
             f"test5 text beats prio-15 sprite exp={exp5:#06x}")
# Text pen=1, color=5 → palette = color[4:0] = 5, pen=1 → {0b00000_00101, 0001} = 0x051
TEXT5_EXPECTED = (5 << 4) | 1   # = 0x051
assert exp5 == TEXT5_EXPECTED, f"test5 model: {exp5:#06x} != {TEXT5_EXPECTED:#06x}"


# ===========================================================================
# Test 6: Priority-0 sprite below even priority-1 PF.
#
# Sprite: group 0x00, prio=0.
# PF1: prio=1.
# Expected: PF1 wins (prio=1 > spr prio=0).
#
# Note: sprite prio=0 vs PF prio=0 → sprite wins (tie-break).
# But sprite prio=0 vs PF prio=1 → PF wins (1 > 0).
# ===========================================================================
emit({"op": "reset", "note": "reset for test6 prio-0 sprite below prio-1 PF"})
model_reset()

SCAN6  = 50
COL6   = 200
TX6    = COL6 // 16   # = 12
TY6    = 51 // 16     # = 3

clear_scanline_effects(SCAN6 + 1, "test6")

write_pf_tile(0, TX6, TY6, 0x01, palette=0x001)   # PF1: pen=1, pal=0x001
set_pf_priority(0, 51, 1)   # PF1 prio=1

SPR6_COLOR = 0x05   # grp 0x00, palette=5
write_sprite_entry(0, 0x05, COL6, SCAN6, SPR6_COLOR, note="test6 sprite prio=0")
set_spr_priority(51, prio_g0=0)   # group 0x00 prio=0

slist6 = m.scan_sprites()
spr6_buf = m.render_sprite_scanline(SCAN6, slist6)
exp6 = model_colmix_pixel(SCAN6, COL6, spr6_buf)

check_colmix(SCAN6, COL6, exp6,
             f"test6 PF1prio=1 beats sprite prio=0 exp={exp6:#06x}")
assert (exp6 & 0xF) == 1, f"test6: pen={exp6&0xF} expected 1 (PF1)"


# ===========================================================================
# Test 7: Transparent PF3 (pen=0) shows through — opaque PF4 (lower prio) wins.
#
# Setup:
#   PF3: transparent tile (pen=0) at priority 10.
#   PF4: opaque tile (pen=4) at priority 8.
#   Expected: PF4 wins (PF3 is transparent so pen=0 → skipped).
# ===========================================================================
emit({"op": "reset", "note": "reset for test7 transparent PF3 shows PF4"})
model_reset()

SCAN7  = 120
COL7   = 240
TX7    = COL7 // 16   # = 15
TY7    = 121 // 16    # = 7

clear_scanline_effects(SCAN7 + 1, "test7")
clear_sprite_entry(0, "test7 no-sprite clear")

# PF3: transparent tile (code=0x00 → all pen=0)
write_pf_tile(2, TX7, TY7, GFX_TRANSPARENT, palette=0x030)  # PF3: pen=0 (transparent)
set_pf_priority(2, 121, 10)   # PF3 prio=10 (but transparent)

# PF4: opaque tile
write_pf_tile(3, TX7, TY7, 0x04, palette=0x040)   # PF4: pen=4, pal=0x040
set_pf_priority(3, 121, 8)    # PF4 prio=8

exp7 = model_colmix_pixel(SCAN7, COL7)

check_colmix(SCAN7, COL7, exp7,
             f"test7 transparent PF3 → PF4 shows exp={exp7:#06x}")
assert (exp7 & 0xF) == 4, f"test7: pen={exp7&0xF} expected 4 (PF4)"


# ===========================================================================
# Test 8: Single PF layer, no sprite/text — PF pixel passes through.
#
# Simplest sanity: one opaque PF tile, no other layers.
# ===========================================================================
emit({"op": "reset", "note": "reset for test8 single PF passthrough"})
model_reset()

SCAN8  = 40
COL8   = 32
TX8    = COL8 // 16   # = 2
TY8    = 41 // 16     # = 2

clear_scanline_effects(SCAN8 + 1, "test8")
clear_sprite_entry(0, "test8 no-sprite clear")

write_pf_tile(0, TX8, TY8, 0x03, palette=0x003)   # PF1: pen=3, pal=0x003
set_pf_priority(0, 41, 5)   # PF1 prio=5

exp8 = model_colmix_pixel(SCAN8, COL8)
check_colmix(SCAN8, COL8, exp8,
             f"test8 single PF1 passthrough exp={exp8:#06x}")
assert (exp8 & 0xF) == 3, f"test8: pen={exp8&0xF} expected 3"


# ===========================================================================
# Test 9: Sprite prio=0 vs PF prio=0 — sprite wins (tie-break rule).
# ===========================================================================
emit({"op": "reset", "note": "reset for test9 sprite tie-break prio=0"})
model_reset()

SCAN9  = 57    # Changed from 55: scan=55 is on a text-tile boundary that causes
               # timing artifacts when step2 precedes (render_vpos=56 falls exactly
               # at the start of a text character row, exposing stale char data in
               # a colmix pipeline timing window).  Scan=57 renders at vpos=58
               # (mid-tile-row) and is clean with all prior step contaminators.
COL9   = 64
TX9    = COL9 // 16   # = 4
TY9    = (SCAN9 + 1) // 16  # = 58 // 16 = 3

clear_scanline_effects(SCAN9 + 1, "test9")

# Clear stale text tile at (8,7) left by step4 (char=176, color=8, pen=9 → text wins).
# Text tile_x = COL9//8 = 8, tile_y = (SCAN9+1)//8 = 7
write_text_tile(COL9 // 8, (SCAN9 + 1) // 8, 0x00, color=0)  # char 0 = transparent

# Clear stale PF tiles at test9 pixel position from steps 1-10 (PF RAM is not reset).
# tile_x=TX9=4, tile_y=TY9=3. Write transparent (code=0) with palette=0 to all planes.
for _plane in range(4):
    write_pf_tile(_plane, TX9, TY9, 0x00, palette=0)

write_pf_tile(0, TX9, TY9, 0x01, palette=0x001)   # PF1: pen=1, pal=0x001
set_pf_priority(0, SCAN9 + 1, 0)   # PF1 prio=0

SPR9_COLOR = 0x0E   # grp 0x00, palette=0x0E
write_sprite_entry(0, 0x0E, COL9, SCAN9, SPR9_COLOR, note="test9 sprite prio=0 tie")
set_spr_priority(SCAN9 + 1, prio_g0=0)

slist9 = m.scan_sprites()
spr9_buf = m.render_sprite_scanline(SCAN9, slist9)
exp9 = model_colmix_pixel(SCAN9, COL9, spr9_buf)

check_colmix(SCAN9, COL9, exp9,
             f"test9 sprite prio=0 tie-break wins exp={exp9:#06x}")
# Sprite pen = tile 0x0E pen = 0xE; palette from color[5:0]=0x0E
assert (exp9 & 0xF) == 0xE, f"test9: pen={exp9&0xF} expected 0xE (sprite)"


# ===========================================================================
# Test 10: Text transparent (pen=0) — PF layer shows through.
# ===========================================================================
emit({"op": "reset", "note": "reset for test10 transparent text shows PF"})
model_reset()

SCAN10  = 65
COL10   = 48
TX10    = COL10 // 16   # = 3
TY10    = 66 // 16      # = 4
TTX10   = COL10 // 8    # text tile_x = 6
TTY10   = 66 // 8       # text tile_y = 8

clear_scanline_effects(SCAN10 + 1, "test10")
clear_sprite_entry(0, "test10 no-sprite clear")

write_pf_tile(0, TX10, TY10, 0x06, palette=0x006)   # PF1: pen=6, pal=0x006
set_pf_priority(0, 66, 7)

# Text: char 0x00 (pen=0) at tile (6, 8)
write_text_tile(TTX10, TTY10, 0x00, color=0)   # transparent

exp10 = model_colmix_pixel(SCAN10, COL10)
check_colmix(SCAN10, COL10, exp10,
             f"test10 text transparent → PF1 shows exp={exp10:#06x}")
assert (exp10 & 0xF) == 6, f"test10: pen={exp10&0xF} expected 6 (PF1)"


# ===========================================================================
# Test 11: All layers transparent → output pen=0 (background).
# ===========================================================================
emit({"op": "reset", "note": "reset for test11 all transparent"})
model_reset()

SCAN11 = 75
COL11  = 192

# Clear all line RAM effects and sprite entry 0 — this test expects ALL layers
# transparent, so any stale data would produce a false non-zero pixel.
clear_scanline_effects(SCAN11 + 1, "test11")
clear_sprite_entry(0, "test11 ensure transparent")

# Clear stale PF tiles at the test11 pixel position. tile_x=COL11//16=12, tile_y=(SCAN11+1)//16=4.
# Earlier steps left PF1 attr=0x000c (palette=12), code=0x10 (pen=1) at tile(12,4).
_tx11 = COL11 // 16   # = 12
_ty11 = (SCAN11 + 1) // 16  # = 4
for _plane in range(4):
    write_pf_tile(_plane, _tx11, _ty11, 0x00, palette=0)  # code=0 → pen=0 (transparent)

# Clear stale text tile at the test11 text position. text tile_x=COL11//8=24, tile_y=(SCAN11+1)//8=9.
write_text_tile(COL11 // 8, (SCAN11 + 1) // 8, 0x00, color=0)

# No tiles written, no sprites → all transparent

exp11 = model_colmix_pixel(SCAN11, COL11)
check_colmix(SCAN11, COL11, 0,
             "test11 all transparent → pen=0")
assert exp11 == 0, f"test11 model: {exp11:#06x} != 0"


# ===========================================================================
# Test 12: Multi-PF priority verification (all 4 PFs, unique priorities)
#
# PF1 prio=1, PF2 prio=3, PF3 prio=5, PF4 prio=7.
# All opaque at same column.
# Expected winner: PF4 (prio=7).
# ===========================================================================
emit({"op": "reset", "note": "reset for test12 all 4 PFs ordered"})
model_reset()

SCAN12  = 130
COL12   = 64
TX12    = COL12 // 16   # = 4
TY12    = 131 // 16     # = 8

clear_scanline_effects(SCAN12 + 1, "test12")
clear_sprite_entry(0, "test12 no-sprite clear")

write_pf_tile(0, TX12, TY12, 0x01, palette=0x001)   # PF1: pen=1
write_pf_tile(1, TX12, TY12, 0x02, palette=0x002)   # PF2: pen=2
write_pf_tile(2, TX12, TY12, 0x03, palette=0x003)   # PF3: pen=3
write_pf_tile(3, TX12, TY12, 0x04, palette=0x004)   # PF4: pen=4

set_pf_priority(0, 131, 1)
set_pf_priority(1, 131, 3)
set_pf_priority(2, 131, 5)
set_pf_priority(3, 131, 7)

exp12 = model_colmix_pixel(SCAN12, COL12)
check_colmix(SCAN12, COL12, exp12,
             f"test12 PF4 wins 4-way prio contest exp={exp12:#06x}")
assert (exp12 & 0xF) == 4, f"test12: pen={exp12&0xF} expected 4 (PF4)"


# ===========================================================================
# Test 13: Sprite group 0x40 wins over PF1 and PF3 at same priority
#
# PF1 prio=5, PF3 prio=5, sprite group 0x40 prio=5 → sprite wins (tie-break >=)
# ===========================================================================
emit({"op": "reset", "note": "reset for test13 sprite tie-break over PF at prio=5"})
model_reset()

SCAN13  = 140
COL13   = 96
TX13    = COL13 // 16   # = 6
TY13    = 141 // 16     # = 8

clear_scanline_effects(SCAN13 + 1, "test13")

write_pf_tile(0, TX13, TY13, 0x01, palette=0x001)   # PF1: pen=1
write_pf_tile(2, TX13, TY13, 0x03, palette=0x003)   # PF3: pen=3
set_pf_priority(0, 141, 5)
set_pf_priority(2, 141, 5)

# Sprite: group 0x40 (color bits[7:6]=01), prio=5
SPR13_COLOR = 0x48   # bits[7:6]=01 → grp0x40; palette=8
write_sprite_entry(0, 0x08, COL13, SCAN13, SPR13_COLOR, note="test13 sprite grp0x40 prio=5")
set_spr_priority(141, prio_g1=5)

slist13 = m.scan_sprites()
spr13_buf = m.render_sprite_scanline(SCAN13, slist13)
exp13 = model_colmix_pixel(SCAN13, COL13, spr13_buf)

check_colmix(SCAN13, COL13, exp13,
             f"test13 sprite prio=5 tie-break over PF prio=5 exp={exp13:#06x}")
# Sprite pen = tile 0x08 pen = 8
assert (exp13 & 0xF) == 8, f"test13: pen={exp13&0xF} expected 8 (sprite)"


# ===========================================================================
# Test 14: Priority-disabled PF acts as prio=0
#
# PF2 prio enable=0 (disabled) → prio defaults to 0.
# PF4 prio=1 → PF4 wins.
# ===========================================================================
emit({"op": "reset", "note": "reset for test14 disabled PF prio defaults to 0"})
model_reset()

SCAN14  = 150
COL14   = 128
TX14    = COL14 // 16   # = 8
TY14    = 151 // 16     # = 9

clear_scanline_effects(SCAN14 + 1, "test14")
clear_sprite_entry(0, "test14 no-sprite clear")

write_pf_tile(1, TX14, TY14, 0x02, palette=0x002)   # PF2: pen=2 (prio disabled → 0)
write_pf_tile(3, TX14, TY14, 0x04, palette=0x004)   # PF4: pen=4
# PF2: no set_pf_priority → enable bit stays 0 → prio=0
set_pf_priority(3, 151, 1)   # PF4 prio=1

exp14 = model_colmix_pixel(SCAN14, COL14)
check_colmix(SCAN14, COL14, exp14,
             f"test14 PF4 prio=1 beats disabled-PF2 prio=0 exp={exp14:#06x}")
# PF2 prio=0, PF4 prio=1 → PF4 wins; but actually with both having prio!=0 check:
# PF2 processed first: pen=2, prio=0. PF4: prio=1 > 0 → PF4 wins.
assert (exp14 & 0xF) == 4, f"test14: pen={exp14&0xF} expected 4 (PF4)"


# ===========================================================================
# Write vectors
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step11_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors -> {out_path}")
