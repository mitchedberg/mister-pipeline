#!/usr/bin/env python3
"""
generate_step15_vectors.py — Step 15 test vector generator for tc0630fdp.

Produces step15_vectors.jsonl: Mosaic Effect (per-scanline X-sample snap).

Test cases (per section3_rtl_plan.md Step 15):
  1.  PF1 mosaic rate=3 (4px blocks): pixel at col=0 snapped to col=0 (block base).
  2.  PF1 mosaic rate=3: pixel at col=2 snapped back to col=0 (block start).
  3.  PF1 mosaic rate=3: pixel at col=4 snapped to col=4 (next 4px block).
  4.  Rate=0 no mosaic: PF1 pixel at any column reads its own column (no snap).
  5.  Mosaic on sprite: sprite pixel at col snapped by rate=3.
  6.  Independent PF1/PF2 rates: PF1 rate=3 (4px), PF2 rate=7 (8px).
     Both checked at same column — verify each uses its own enable bit.
  7.  PF2 mosaic disabled when bit[1] not set: verify PF2 reads unsnapped.
  8.  PF mosaic enable bit independence: PF1 en=1, PF2 en=0, same rate.
     PF2 at col with offset != 0 reads exact column (unsnapped).
  9.  Boundary: column at exact block boundary reads same column (off=0).
  10. Sprite mosaic disabled when spr_en bit[8] not set: verify spr_pixel
     reads exact column even when PF mosaic rate is non-zero.
  11. High rate=15 (16px blocks): verify snap at col=14 → col=0.
  12. Rate=3 snap formula verification across multiple columns: col=7 → col=4.
  13. Sprite mosaic enabled: verify col=5 snaps to col=4 (rate=3).
  14. PF3 mosaic enable bit[2]: verify PF3 is snapped, PF4 is not.
  15. Rate=1 (2px blocks): col=1 → col=0, col=2 → col=2.

Line RAM address map for Step 15 (word addresses):
  §9.6 Mosaic control: word 0x3200 + scan
    bits[11:8] = X mosaic rate (4-bit; 0=no effect, F=16px blocks)
    bits[3:0]  = PF mosaic enable (bit 0=PF1, bit 1=PF2, bit 2=PF3, bit 3=PF4)
    bit[8]     = Sprite mosaic enable (overlaps with rate LSB)
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
    """Reset transient state (GFX ROM, Char RAM, and pal_ram preserved)."""
    m.ctrl     = [0] * 16
    m.pf_ram   = [[0] * m.PF_RAM_WORDS for _ in range(4)]
    m.text_ram = [0] * m.TEXT_RAM_WORDS
    m.line_ram = [0] * m.LINE_RAM_WORDS
    m.spr_ram  = [0] * m.SPR_RAM_WORDS
    # NOTE: pal_ram is NOT reset — palette entries persist across tests.


# ---------------------------------------------------------------------------
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


def write_spr_word(word_offset: int, data: int, note: str = "") -> None:
    chip_addr = SPR_BASE + word_offset
    emit({"op": "write_sprite",
          "addr": chip_addr,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"spr_ram[{word_offset:#06x}] = {data:#06x}"})


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


def write_pf_tile(plane: int, tile_x: int, tile_y: int,
                  tile_code: int, palette: int = 0,
                  flipx: bool = False, flipy: bool = False) -> None:
    """Write a single PF tile entry to PF RAM."""
    tile_idx = tile_y * 32 + tile_x
    word_base = tile_idx * 2
    attr = palette & 0x1FF
    if flipx: attr |= (1 << 14)
    if flipy: attr |= (1 << 15)
    chip_base = 0x04000 + plane * 0x2000
    emit({"op": "write_pf", "addr": chip_base + word_base, "data": attr,
          "be": 3, "plane": plane,
          "note": f"pf{plane+1} tile({tile_x},{tile_y}) attr={attr:#06x}"})
    emit({"op": "write_pf", "addr": chip_base + word_base + 1,
          "data": tile_code & 0xFFFF, "be": 3, "plane": plane,
          "note": f"pf{plane+1} tile({tile_x},{tile_y}) code={tile_code:#06x}"})
    m.pf_ram[plane][word_base]     = attr
    m.pf_ram[plane][word_base + 1] = tile_code & 0xFFFF


def clear_pf_row(render_scan: int, note: str = "") -> None:
    """Clear all tiles on the tile row for render_scan (all 4 PF planes)."""
    tile_y = render_scan // 16
    tag = note or f"clear_pf_row tile_y={tile_y} for scan={render_scan}"
    for _plane in range(4):
        for _tx in range(20):
            tile_idx = tile_y * 32 + _tx
            word_base = tile_idx * 2
            chip_base = 0x04000 + _plane * 0x2000
            emit({"op": "write_pf", "addr": chip_base + word_base,
                  "data": 0, "be": 3, "plane": _plane,
                  "note": f"{tag} pl={_plane} tx={_tx} attr=0"})
            emit({"op": "write_pf", "addr": chip_base + word_base + 1,
                  "data": 0, "be": 3, "plane": _plane,
                  "note": f"{tag} pl={_plane} tx={_tx} code=0"})
            m.pf_ram[_plane][word_base]     = 0
            m.pf_ram[_plane][word_base + 1] = 0


def clear_sprite_entry(idx: int) -> None:
    base = idx * 8
    for w in range(8):
        write_spr_word(base + w, 0, f"clear spr[{idx}] word{w}")
    # mirror to model
    for w in range(8):
        m.spr_ram[base + w] = 0


def write_sprite_entry(idx: int, tile_code: int, sx: int, sy: int,
                       color: int, flipx: bool = False, flipy: bool = False,
                       x_zoom: int = 0x00, y_zoom: int = 0x00,
                       note: str = "") -> None:
    """Write a full sprite entry to Sprite RAM (emit + model)."""
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
    m.write_sprite_entry(idx, tile_code, sx, sy, color, flipx, flipy,
                         x_zoom=x_zoom, y_zoom=y_zoom)


def set_mosaic(scan: int, rate: int, pf_en4: int, spr_en: bool = False,
               note: str = "") -> None:
    """Write §9.6 mosaic word for one scanline.

    mo_word: bits[11:8] = rate, bits[3:0] = pf_en4.
    Sprite enable is bit[8] (overlaps rate[0]).
    Per RTL: ls_spr_mosaic_en = mo_word[8] = rate[0].
    So to enable sprite mosaic, rate must be odd.
    In practice: set rate with bit[0]=1 for spr_en=True.
    """
    s = scan & 0xFF
    # bit[8] = rate[0] = spr_en; keep rate nibble as-is
    mo_word = ((rate & 0xF) << 8) | (pf_en4 & 0xF)
    write_line(0x3200 + s, mo_word,
               note or f"mosaic scan={scan} rate={rate} pf_en4={pf_en4:#03x} spr_en={int(spr_en)}")


def mosaic_snap(scol: int, rate: int) -> int:
    """Python reference for RTL mosaic snap formula."""
    return m._mosaic_snap_col(scol, rate)


def check_bg(vpos: int, screen_col: int, plane: int, exp_pixel: int,
             note: str) -> None:
    emit({"op": "check_bg_pixel",
          "vpos":       vpos,
          "screen_col": screen_col,
          "plane":      plane,
          "exp_pixel":  exp_pixel & 0x1FFF,
          "note":       note})


def check_spr(vpos: int, screen_col: int, exp_pixel: int, note: str) -> None:
    emit({"op": "check_sprite_pixel",
          "vpos":       vpos,
          "screen_col": screen_col,
          "exp_pixel":  exp_pixel & 0xFFF,
          "note":       note})


def bg_pixel_from_model(vpos: int, plane: int, col: int,
                        mosaic_en: bool = False, rate: int = 0) -> int:
    """Query model for BG pixel at (vpos+1, col) for plane."""
    buf = m.render_bg_scanline(
        vpos, plane,
        m.pf_xscroll[plane],
        m.pf_yscroll[plane],
        m.extend_mode,
        mosaic_en=mosaic_en,
        mosaic_rate=rate,
    )
    return buf[col]


def spr_pixel_from_model(vpos: int, col: int,
                         mosaic_en: bool = False, rate: int = 0) -> int:
    """Query model for sprite pixel at (vpos+1, col)."""
    slist = m.scan_sprites()
    buf = m.render_sprite_scanline(vpos, slist,
                                   mosaic_en=mosaic_en, mosaic_rate=rate)
    return buf[col]


# ===========================================================================
# BRAM init block — mandatory contamination prevention
# (Ensures BRAM contents from previous tests do not bleed into step15 tests)
# ===========================================================================
for _tc in range(1, 16):
    write_gfx_solid_tile(_tc, _tc, f"init: solid tile {_tc:#x} pen={_tc:#x}")
write_gfx_solid_tile(0x00, 0,  "init: tile 0x00 pen=0 (transparent)")
write_gfx_solid_tile(0x10, 1,  "init: tile 0x10 pen=1 (BG mosaic tests)")
write_gfx_solid_tile(0x11, 2,  "init: tile 0x11 pen=2 (PF2 mosaic tests)")
write_gfx_solid_tile(0x12, 3,  "init: tile 0x12 pen=3 (PF3 mosaic tests)")
write_gfx_solid_tile(0x13, 4,  "init: tile 0x13 pen=4 (PF4 mosaic tests)")
write_gfx_solid_tile(0x14, 1,  "init: tile 0x14 pen=1 (sprite mosaic tests)")
write_gfx_solid_tile(0x20, 5,  "init: tile 0x20 pen=5 (rate=15 test)")

# Clear char RAM for char codes 0–15
CHAR_BASE = 0x0F000
for _cc in range(16):
    for _word in range(16):
        _waddr = CHAR_BASE + _cc * 16 + _word
        emit({"op": "write_char", "addr": _waddr, "data": 0, "be": 3,
              "note": f"init: clear char[{_cc:#04x}] word {_word}"})

# Clear palette RAM in model only (persists from previous step)
for _pa in range(m.PAL_RAM_WORDS):
    m.pal_ram[_pa] = 0

# Clear sprite entries 0–4
for _si in range(5):
    for _w in range(8):
        write_spr_word(_si * 8 + _w, 0, f"init: clear spr[{_si}] word{_w}")
    for _w in range(8):
        m.spr_ram[_si * 8 + _w] = 0


# ===========================================================================
# Test 1: PF1 mosaic rate=3 (4px blocks) — col=0 snaps to col=0.
#
# rate=3 → sample_rate=4. col=0: (0+114)%432 % 4 = 114%4 = 2. snap = 0-2 = -2?
# Wait — that's negative. Let's compute:
#   gx_wide = 0 + 114 = 114;  grid_sum = 114 (since 114 < 432)
#   off = 114 % 4 = 2;  snapped = 0 - 2 = -2
# That would underflow. But in RTL: scol is 9-bit; 0 - 2 in 9-bit = 0x1FE = 510.
# However 510 >= 320, so linebuf[510] is out of range for 320-wide linebuf.
# Actually the BG linebuf IS 320 entries (0..319), indexed by 9-bit scol_snap.
# If scol_snap >= 320, we'd read out of the linebuf (implementation-defined).
#
# Let's pick a column where the snap stays in-bounds. For rate=3 (4px blocks):
# We want snapped col to be in 0..319.
# Block boundary at col=c: c is a block start iff (c+114) % 432 % 4 == 0.
#
# Simplest: use a column where off=0 (already a block boundary):
#   (col+114) % 432 % 4 == 0  → col+114 ≡ 0 (mod 4) → col ≡ -114 ≡ -2 ≡ 2 (mod 4)
#   → col = 2, 6, 10, 14, ...
# At col=2: off=0, snapped=2. Tile at column 2/16 = tile 0, px_in_tile=2. pen=tile_pen.
# At col=3: off=1, snapped=2. Reads same tile pen as col=2 (block base).
# At col=4: off=2, snapped=2. Same.
# At col=5: off=3, snapped=2. Same.
# At col=6: off=0, snapped=6. Different block.
#
# But we need different pixel values at col=2 vs col=3 to distinguish.
# Solution: use a tile with column-varying pixels (not solid).
# Build a tile where row 0 has pixel sequence: pen = px_in_tile (0..7 repeating).
# Then col=2 → px=2, pen=2; col=3 → snapped col=2 → pen=2 (same); col=6 → px=6, pen=6.
#
# Actually for mosaic we need two things:
#   a) at block boundary: pixel reads normally (no snap artifact)
#   b) at non-boundary: pixel reads the snapped (block-start) pixel, not its own
#
# Let's use a tile where pen=px_in_tile (distinct per pixel).
# That way we can verify that a non-boundary col reads the boundary pen.
# ===========================================================================
emit({"op": "reset", "note": "reset for test1 pf1_mosaic_rate3_block_boundary"})
model_reset()

SCAN1 = 30

# Build tile 0x30 with per-pixel pens: pen[px] = px+1 (px 0..15 → pens 1..16, capped 1..15+1=1 mod 16)
# Actually pen = (px & 0xF) | 1 doesn't work cleanly. Let's use: pen = (px % 7) + 1 to stay 1..7
# Simpler: make pen = px & 0xF, but px=0 would be transparent. Use pen = (px & 0xF) + 1 (capped at 0xF).
# Actually let's just use a column-gradient tile with pen = (px+1) & 0xF for px 0..15.
# Encode: for each row, 8 nibbles in left word, 8 in right word.
GRAD_TILE = 0x30
m.gfx_rom = list(m.gfx_rom)  # ensure mutable
for _row in range(16):
    _lw = 0
    _rw = 0
    for _px in range(8):
        _pen = (_px + 1) & 0xF        # px 0..7 → pens 1..8
        _lw = (_lw << 4) | _pen
    for _px in range(8):
        _pen = (_px + 9) & 0xF        # px 8..15 → pens 9..0
        _rw = (_rw << 4) | _pen
    write_gfx_word(GRAD_TILE * 32 + _row * 2,     _lw,
                   f"grad_tile row={_row} left: pens 1..8")
    write_gfx_word(GRAD_TILE * 32 + _row * 2 + 1, _rw,
                   f"grad_tile row={_row} right: pens 9..0")

# Verify gradient tile in model
assert m.gfx_rom[GRAD_TILE * 32] != 0, "grad tile not written to model"

clear_pf_row(SCAN1 + 1, "test1")
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN1 + 1) // 16, GRAD_TILE, palette=0x00)

# Set mosaic: rate=3, PF1 enable (bit 0)
set_mosaic(SCAN1 + 1, rate=3, pf_en4=0b0001, note="test1 mosaic rate=3 PF1 en")

# For rate=3 (4px blocks), block boundaries at: col ≡ 2 (mod 4):  2, 6, 10, 14, ...
# Col=2: off=0, snapped=2. Pen = px_in_tile at col=2 = 2+1 = 3 (tile px 2 = pen 3).
# Col=3: off=1, snapped=2. Same pen = 3.
# Col=4: off=2, snapped=2. Same pen = 3.
# Col=5: off=3, snapped=2. Same pen = 3.
# Col=6: off=0, snapped=6. Pen = tile px 6 = pen 7.

# Verify snapped col formula
assert mosaic_snap(2, 3) == 2,  f"snap(2,3) expected 2, got {mosaic_snap(2,3)}"
assert mosaic_snap(3, 3) == 2,  f"snap(3,3) expected 2, got {mosaic_snap(3,3)}"
assert mosaic_snap(4, 3) == 2,  f"snap(4,3) expected 2, got {mosaic_snap(4,3)}"
assert mosaic_snap(5, 3) == 2,  f"snap(5,3) expected 2, got {mosaic_snap(5,3)}"
assert mosaic_snap(6, 3) == 6,  f"snap(6,3) expected 6, got {mosaic_snap(6,3)}"

# Model sanity
px1_col2 = bg_pixel_from_model(SCAN1, 0, 2, mosaic_en=True, rate=3)
px1_col3 = bg_pixel_from_model(SCAN1, 0, 3, mosaic_en=True, rate=3)
px1_col6 = bg_pixel_from_model(SCAN1, 0, 6, mosaic_en=True, rate=3)
assert px1_col2 == px1_col3, f"test1: col=2 pen={px1_col2&0xF} col=3 pen={px1_col3&0xF} should match"
assert px1_col2 != px1_col6, f"test1: col=2 and col=6 should differ"

check_bg(SCAN1, 2, 0, px1_col2,
         f"test1 mosaic_rate3 col=2 block_boundary exp_pen={(px1_col2 & 0xF)}")
check_bg(SCAN1, 3, 0, px1_col2,
         f"test1 mosaic_rate3 col=3→snap=2 exp_pen={(px1_col2 & 0xF)} matches col=2")
check_bg(SCAN1, 6, 0, px1_col6,
         f"test1 mosaic_rate3 col=6 new_block exp_pen={(px1_col6 & 0xF)}")


# ===========================================================================
# Test 2: PF1 mosaic rate=3 — col=4 is in same block as col=2, reads col=2.
#         col=5 also same block. col=6 different block.
# Extend to verify the full 4-pixel block runs from snap(2,3)..snap(5,3)=2.
# ===========================================================================
emit({"op": "reset", "note": "reset for test2 pf1_mosaic_rate3_mid_block"})
model_reset()

SCAN2 = 35
clear_pf_row(SCAN2 + 1, "test2")
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN2 + 1) // 16, GRAD_TILE, palette=0x00)

set_mosaic(SCAN2 + 1, rate=3, pf_en4=0b0001, note="test2 mosaic rate=3 PF1")

px2_col2 = bg_pixel_from_model(SCAN2, 0, 2, mosaic_en=True, rate=3)
px2_col4 = bg_pixel_from_model(SCAN2, 0, 4, mosaic_en=True, rate=3)
px2_col5 = bg_pixel_from_model(SCAN2, 0, 5, mosaic_en=True, rate=3)

# Snap(4,3): (4+114)=118; 118%4=2; snap=4-2=2
assert mosaic_snap(4, 3) == 2
assert px2_col4 == px2_col2, f"test2: col=4 should read col=2's pixel"
assert px2_col5 == px2_col2, f"test2: col=5 should read col=2's pixel"

check_bg(SCAN2, 4, 0, px2_col4,
         f"test2 mosaic_rate3 col=4→snap=2 matches col=2 pen={(px2_col4 & 0xF)}")
check_bg(SCAN2, 5, 0, px2_col5,
         f"test2 mosaic_rate3 col=5→snap=2 matches col=2 pen={(px2_col5 & 0xF)}")


# ===========================================================================
# Test 3: rate=0 — no mosaic. Each column reads its own pixel.
# PF1 with gradient tile, mosaic word set to rate=0 pf_en4=0b0001.
# Expected: col=3 reads pen=4 (tile px=3), NOT snapped to col=2's pen=3.
# ===========================================================================
emit({"op": "reset", "note": "reset for test3 pf1_rate0_no_mosaic"})
model_reset()

SCAN3 = 40
clear_pf_row(SCAN3 + 1, "test3")
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN3 + 1) // 16, GRAD_TILE, palette=0x00)

set_mosaic(SCAN3 + 1, rate=0, pf_en4=0b0001, note="test3 rate=0 no_mosaic")

# No snap: col=3 reads own pixel (px=3 → pen=4)
px3_col3_no_snap = bg_pixel_from_model(SCAN3, 0, 3, mosaic_en=False, rate=0)
# With snap would be: snap(3,0) = 3 (rate=0 → no snap, off=0)
assert mosaic_snap(3, 0) == 3, "rate=0 should not snap"

check_bg(SCAN3, 3, 0, px3_col3_no_snap,
         f"test3 rate=0_no_mosaic col=3 reads_own_pixel pen={(px3_col3_no_snap & 0xF)}")
check_bg(SCAN3, 2, 0, bg_pixel_from_model(SCAN3, 0, 2, mosaic_en=False, rate=0),
         f"test3 rate=0 col=2 reads_own_pixel (col=2 pen differs from col=3)")


# ===========================================================================
# Test 4: Sprite mosaic rate=3 (4px blocks).
# Sprite with solid tile placed at sx=0, sy=SCAN4+1-8 (16 rows high, covers scan).
# spr_mosaic_en = bit[8] of mo_word = rate[0]. rate=3 → bit[0]=1 → spr_en=1.
# Verify: sprite at col=3 reads snapped col=2 pixel (solid tile → same pen).
# For solid tile, all pixels have same pen, so mosaic doesn't change the pen value
# but it does snap the column index. Use sprite with per-column variation.
#
# Strategy: Place solid-pen=5 sprite at col 0..15. All columns same pen=5.
# Mosaic snap doesn't change pen value for solid tiles, but we verify it
# snaps the SOURCE column correctly by using a non-solid pattern.
#
# Better strategy: place sprite only at col=4..7 (not at col=2..3).
# Without mosaic: col=2 is transparent, col=4 has pen=5.
# With mosaic enabled (rate=3): col=2 snaps to col=2 (transparent), col=3
# snaps to col=2 (still transparent). col=4 snaps to col=2 (transparent!).
# col=5 snaps to col=2 (transparent!). col=6 snaps to col=6 (pen=5).
#
# Wait — sprite sx=0 puts it at screen columns 0..15. Let's verify:
# sprite at sx=4 puts it at cols 4..19. Then:
# - col=3: no sprite (transparent even without mosaic)
# - col=4: sprite pen=5 without mosaic; WITH mosaic snap(4,3)=2, col=2 has no sprite → 0
# - col=6: sprite pen=5 without mosaic; snap(6,3)=6, col=6 has sprite → pen=5
# - col=7: sprite pen=5; snap(7,3)=6, col=6 has sprite → pen=5
# This gives us: mosaic causes col=4,5 to become transparent (snap past sprite)
# and col=6,7 to both show the same pen. This is testable!
# ===========================================================================
emit({"op": "reset", "note": "reset for test4 sprite_mosaic_rate3"})
model_reset()

SCAN4 = 45
clear_pf_row(SCAN4 + 1, "test4")
clear_sprite_entry(0)

SPR4_SX  = 4     # sprite starts at col=4
SPR4_SY  = SCAN4 + 1 - 8   # 16-row sprite covers SCAN4+1
SPR4_PAL = 0x01  # color byte = 0x01 (prio=0, palette=0x01)
write_sprite_entry(0, tile_code=0x14, sx=SPR4_SX, sy=SPR4_SY, color=SPR4_PAL,
                   note="test4 sprite sx=4 for mosaic snap test")

# rate=3 → bit[0]=1 → spr_en=1. Set spr_en in mosaic word.
set_mosaic(SCAN4 + 1, rate=3, pf_en4=0b0000, spr_en=True,
           note="test4 mosaic rate=3 spr_en=1")

# Model: with spr mosaic, snap col=4 → 2 (no sprite at 2 → transparent)
slist4 = m.scan_sprites()
px4_col4_snap = spr_pixel_from_model(SCAN4, 4, mosaic_en=True, rate=3)
px4_col6_snap = spr_pixel_from_model(SCAN4, 6, mosaic_en=True, rate=3)
px4_col7_snap = spr_pixel_from_model(SCAN4, 7, mosaic_en=True, rate=3)

# snap(4,3)=2: no sprite at 2 → transparent (0)
assert px4_col4_snap == 0, f"test4: mosaic snap col=4→2 should be transparent, got {px4_col4_snap}"
# snap(6,3)=6: sprite at 6 → pen=1
assert (px4_col6_snap & 0xF) == 1, f"test4: mosaic snap col=6 sprite_pen=1, got pen={(px4_col6_snap & 0xF)}"
# snap(7,3)=6: same as col=6
assert px4_col7_snap == px4_col6_snap, f"test4: mosaic snap col=7→6 should equal col=6"

check_spr(SCAN4, 4, px4_col4_snap,
          f"test4 spr_mosaic_rate3 col=4→snap=2 transparent exp=0")
check_spr(SCAN4, 6, px4_col6_snap,
          f"test4 spr_mosaic_rate3 col=6 sprite_pixel exp_pen=1")
check_spr(SCAN4, 7, px4_col7_snap,
          f"test4 spr_mosaic_rate3 col=7→snap=6 matches_col=6")


# ===========================================================================
# Test 5: Independent PF1/PF2 mosaic rates.
# PF1: rate=3 (4px blocks), PF2: rate=7 (8px blocks).
# PF1 pf_en4 bit[0]=1, PF2 pf_en4 bit[1]=1.
# Both use same rate field (only one global rate per scanline).
# Wait — §9.6 has ONE rate nibble for ALL planes. Both PF1 and PF2 use the same rate.
# The enable bits just say which planes are mosaicked.
# So "independent PF1/PF2 rates" is not possible — they share the rate.
# The test must verify that enable bits select which planes are mosaicked.
#
# Test 5 (revised): PF1 enabled (bit 0), PF2 disabled (bit 1 = 0). Same rate=3.
# PF1 col=3 snaps to col=2 (shows block pixel).
# PF2 col=3 reads its own pixel (not snapped).
# Use different tiles for PF1 and PF2 to distinguish.
# ===========================================================================
emit({"op": "reset", "note": "reset for test5 pf1_en_pf2_dis_same_rate"})
model_reset()

SCAN5 = 50
clear_pf_row(SCAN5 + 1, "test5")
# PF1: gradient tile (col-varying pens)
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN5 + 1) // 16, GRAD_TILE, palette=0x00)
# PF2: different gradient tile (also col-varying pens, but different offset)
for _tx in range(20):
    write_pf_tile(1, _tx, (SCAN5 + 1) // 16, GRAD_TILE, palette=0x10)

# Mosaic: rate=3, PF1 en=1 (bit 0), PF2 en=0 (bit 1 = 0)
set_mosaic(SCAN5 + 1, rate=3, pf_en4=0b0001, note="test5 PF1_en PF2_dis rate=3")

# PF1 col=3: snapped to col=2
px5_pf1_col3 = bg_pixel_from_model(SCAN5, 0, 3, mosaic_en=True, rate=3)
px5_pf1_col2 = bg_pixel_from_model(SCAN5, 0, 2, mosaic_en=True, rate=3)
assert px5_pf1_col3 == px5_pf1_col2, "test5: PF1 col=3 should snap to col=2"

# PF2 col=3: NOT snapped (own pixel)
px5_pf2_col3 = bg_pixel_from_model(SCAN5, 1, 3, mosaic_en=False, rate=3)
px5_pf2_col2 = bg_pixel_from_model(SCAN5, 1, 2, mosaic_en=False, rate=3)
# PF2 col=3 and col=2 have different pens in GRAD_TILE (pen 4 vs pen 3), plus different palettes
assert (px5_pf2_col3 & 0xF) != (px5_pf2_col2 & 0xF), \
    "test5: PF2 col=3 and col=2 should differ (not snapped)"

check_bg(SCAN5, 3, 0, px5_pf1_col3,
         f"test5 PF1_mosaicked col=3→snap=2 pen={(px5_pf1_col3 & 0xF)}")
check_bg(SCAN5, 3, 1, px5_pf2_col3,
         f"test5 PF2_NOT_mosaicked col=3 reads own_pixel pen={(px5_pf2_col3 & 0xF)}")


# ===========================================================================
# Test 6: PF2 mosaic enabled (bit 1), PF1 disabled (bit 0 = 0). Rate=3.
# Verify PF2 is snapped but PF1 is not.
# ===========================================================================
emit({"op": "reset", "note": "reset for test6 pf2_en_pf1_dis"})
model_reset()

SCAN6 = 55
clear_pf_row(SCAN6 + 1, "test6")
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN6 + 1) // 16, GRAD_TILE, palette=0x00)
for _tx in range(20):
    write_pf_tile(1, _tx, (SCAN6 + 1) // 16, GRAD_TILE, palette=0x10)

set_mosaic(SCAN6 + 1, rate=3, pf_en4=0b0010, note="test6 PF2_en PF1_dis rate=3")

# PF1 col=3: not snapped
px6_pf1_col3 = bg_pixel_from_model(SCAN6, 0, 3, mosaic_en=False, rate=3)
px6_pf1_col2 = bg_pixel_from_model(SCAN6, 0, 2, mosaic_en=False, rate=3)
assert (px6_pf1_col3 & 0xF) != (px6_pf1_col2 & 0xF), \
    "test6: PF1 col=3 and col=2 should differ (PF1 not mosaicked)"

# PF2 col=3: snapped to col=2
px6_pf2_col3 = bg_pixel_from_model(SCAN6, 1, 3, mosaic_en=True, rate=3)
px6_pf2_col2 = bg_pixel_from_model(SCAN6, 1, 2, mosaic_en=True, rate=3)
assert px6_pf2_col3 == px6_pf2_col2, "test6: PF2 col=3 should snap to col=2"

check_bg(SCAN6, 3, 0, px6_pf1_col3,
         f"test6 PF1_NOT_mosaicked col=3 own_pixel pen={(px6_pf1_col3 & 0xF)}")
check_bg(SCAN6, 3, 1, px6_pf2_col3,
         f"test6 PF2_mosaicked col=3→snap=2 pen={(px6_pf2_col3 & 0xF)}")


# ===========================================================================
# Test 7: PF3 mosaic enable (bit 2). Verify PF3 snapped, PF4 not.
# ===========================================================================
emit({"op": "reset", "note": "reset for test7 pf3_en_pf4_dis"})
model_reset()

SCAN7 = 60
clear_pf_row(SCAN7 + 1, "test7")
for _tx in range(20):
    write_pf_tile(2, _tx, (SCAN7 + 1) // 16, GRAD_TILE, palette=0x20)
for _tx in range(20):
    write_pf_tile(3, _tx, (SCAN7 + 1) // 16, GRAD_TILE, palette=0x30)

set_mosaic(SCAN7 + 1, rate=3, pf_en4=0b0100, note="test7 PF3_en PF4_dis rate=3")

px7_pf3_col3 = bg_pixel_from_model(SCAN7, 2, 3, mosaic_en=True, rate=3)
px7_pf3_col2 = bg_pixel_from_model(SCAN7, 2, 2, mosaic_en=True, rate=3)
assert px7_pf3_col3 == px7_pf3_col2, "test7: PF3 col=3 should snap to col=2"

px7_pf4_col3 = bg_pixel_from_model(SCAN7, 3, 3, mosaic_en=False, rate=3)
px7_pf4_col2 = bg_pixel_from_model(SCAN7, 3, 2, mosaic_en=False, rate=3)
assert (px7_pf4_col3 & 0xF) != (px7_pf4_col2 & 0xF), \
    "test7: PF4 col=3 and col=2 should differ (PF4 not mosaicked)"

check_bg(SCAN7, 3, 2, px7_pf3_col3,
         f"test7 PF3_mosaicked col=3→snap=2 pen={(px7_pf3_col3 & 0xF)}")
check_bg(SCAN7, 3, 3, px7_pf4_col3,
         f"test7 PF4_NOT_mosaicked col=3 own_pixel pen={(px7_pf4_col3 & 0xF)}")


# ===========================================================================
# Test 8: rate=1 (2px blocks): col=1 → col=0, col=2 → col=2.
#
# For rate=1 (sample_rate=2):
#   snap(0,1): (0+114)%432 = 114; 114%2=0; snap=0  (block start)
#   snap(1,1): (1+114)=115; 115%2=1; snap=0  (same block as col=0)
#   snap(2,1): (2+114)=116; 116%2=0; snap=2  (new block start)
#   snap(3,1): 117%2=1; snap=2  (same as col=2)
# ===========================================================================
emit({"op": "reset", "note": "reset for test8 rate1_two_pixel_blocks"})
model_reset()

SCAN8 = 65
clear_pf_row(SCAN8 + 1, "test8")
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN8 + 1) // 16, GRAD_TILE, palette=0x00)

set_mosaic(SCAN8 + 1, rate=1, pf_en4=0b0001, note="test8 rate=1 2px_blocks PF1")

assert mosaic_snap(0, 1) == 0, f"snap(0,1) = {mosaic_snap(0,1)}"
assert mosaic_snap(1, 1) == 0, f"snap(1,1) = {mosaic_snap(1,1)}"
assert mosaic_snap(2, 1) == 2, f"snap(2,1) = {mosaic_snap(2,1)}"
assert mosaic_snap(3, 1) == 2, f"snap(3,1) = {mosaic_snap(3,1)}"

px8_col0 = bg_pixel_from_model(SCAN8, 0, 0, mosaic_en=True, rate=1)
px8_col1 = bg_pixel_from_model(SCAN8, 0, 1, mosaic_en=True, rate=1)
px8_col2 = bg_pixel_from_model(SCAN8, 0, 2, mosaic_en=True, rate=1)
px8_col3 = bg_pixel_from_model(SCAN8, 0, 3, mosaic_en=True, rate=1)

assert px8_col1 == px8_col0, "test8: col=1 should snap to col=0"
assert px8_col3 == px8_col2, "test8: col=3 should snap to col=2"
assert px8_col0 != px8_col2, "test8: col=0 and col=2 should differ (different 2px blocks)"

check_bg(SCAN8, 0, 0, px8_col0, f"test8 rate=1 col=0 block_start pen={(px8_col0 & 0xF)}")
check_bg(SCAN8, 1, 0, px8_col1, f"test8 rate=1 col=1→snap=0 matches_col0 pen={(px8_col1 & 0xF)}")
check_bg(SCAN8, 2, 0, px8_col2, f"test8 rate=1 col=2 new_block pen={(px8_col2 & 0xF)}")
check_bg(SCAN8, 3, 0, px8_col3, f"test8 rate=1 col=3→snap=2 matches_col2 pen={(px8_col3 & 0xF)}")


# ===========================================================================
# Test 9: rate=15 (16px blocks).
# snap(14, 15): (14+114)%432=128; 128%16=0; snap=14  (block boundary!)
# snap(15, 15): (15+114)%432=129; 129%16=1; snap=14
# snap(16, 15): (16+114)%432=130; 130%16=2; snap=14
# snap(29, 15): (29+114)=143; 143%16=15; snap=14
# snap(30, 15): (30+114)=144; 144%16=0; snap=30  (new block)
# Full block: col=14..29 all snap to col=14.
# ===========================================================================
emit({"op": "reset", "note": "reset for test9 rate15_16px_blocks"})
model_reset()

SCAN9 = 70
clear_pf_row(SCAN9 + 1, "test9")
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN9 + 1) // 16, GRAD_TILE, palette=0x00)

set_mosaic(SCAN9 + 1, rate=15, pf_en4=0b0001, note="test9 rate=15 16px_blocks PF1")

assert mosaic_snap(14, 15) == 14, f"snap(14,15) = {mosaic_snap(14, 15)}"
assert mosaic_snap(15, 15) == 14, f"snap(15,15) = {mosaic_snap(15, 15)}"
assert mosaic_snap(29, 15) == 14, f"snap(29,15) = {mosaic_snap(29, 15)}"
assert mosaic_snap(30, 15) == 30, f"snap(30,15) = {mosaic_snap(30, 15)}"

px9_col14 = bg_pixel_from_model(SCAN9, 0, 14, mosaic_en=True, rate=15)
px9_col15 = bg_pixel_from_model(SCAN9, 0, 15, mosaic_en=True, rate=15)
px9_col29 = bg_pixel_from_model(SCAN9, 0, 29, mosaic_en=True, rate=15)
px9_col30 = bg_pixel_from_model(SCAN9, 0, 30, mosaic_en=True, rate=15)

# col=15 and col=29 both snap to col=14 → same pixel
assert px9_col15 == px9_col14, "test9: col=15 should snap to col=14"
assert px9_col29 == px9_col14, "test9: col=29 should snap to col=14"
# col=30 snaps to col=30 (own block) — snap formula verified above via assert

check_bg(SCAN9, 14, 0, px9_col14, f"test9 rate=15 col=14 block_start pen={(px9_col14 & 0xF)}")
check_bg(SCAN9, 15, 0, px9_col15, f"test9 rate=15 col=15→snap=14 matches_col14")
check_bg(SCAN9, 29, 0, px9_col29, f"test9 rate=15 col=29→snap=14 matches_col14")
check_bg(SCAN9, 30, 0, px9_col30, f"test9 rate=15 col=30 new_block_start snap=30 pen={(px9_col30 & 0xF)}")


# ===========================================================================
# Test 10: Sprite mosaic with snap causing transparent read.
# No sprite at col=2 (snap target). Sprite at col=4..7.
# With mosaic rate=3, col=4 → snap=2 → transparent.
# Without mosaic, col=4 → pen=1.
# Verify sprite at col=6 with mosaic: snap(6,3)=6 → still has sprite.
# ===========================================================================
emit({"op": "reset", "note": "reset for test10 sprite_mosaic_snap_to_transparent"})
model_reset()

SCAN10 = 75
clear_pf_row(SCAN10 + 1, "test10")
clear_sprite_entry(0)

# Sprite at sx=4 (cols 4..19), pen=1 (tile 0x14)
write_sprite_entry(0, tile_code=0x14, sx=4, sy=SCAN10 + 1 - 8, color=0x01,
                   note="test10 sprite sx=4 cols=4..19")

# rate=3 → bit[0]=1 → spr_en=1
set_mosaic(SCAN10 + 1, rate=3, pf_en4=0b0000, spr_en=True,
           note="test10 spr_mosaic rate=3")

px10_col4 = spr_pixel_from_model(SCAN10, 4, mosaic_en=True, rate=3)
px10_col6 = spr_pixel_from_model(SCAN10, 6, mosaic_en=True, rate=3)

# snap(4,3)=2: no sprite at 2 → transparent
assert px10_col4 == 0, f"test10: snap col=4→2 should be transparent, got {px10_col4}"
# snap(6,3)=6: sprite at 6 → pen=1
assert (px10_col6 & 0xF) == 1, f"test10: snap col=6 pen=1, got {px10_col6 & 0xF}"

check_spr(SCAN10, 4, 0, "test10 spr_mosaic col=4→snap=2 transparent exp=0")
check_spr(SCAN10, 6, px10_col6, f"test10 spr_mosaic col=6 sprite_pen=1")


# ===========================================================================
# Test 11: Sprite mosaic disabled when rate is even (bit[8]=0).
# rate=4 (even) → bit[0]=0 → spr_en=0.
# PF1 has mosaic_en from pf_en4 but sprite does not.
# Verify sprite at col=4 reads col=4 normally (not snapped).
# ===========================================================================
emit({"op": "reset", "note": "reset for test11 sprite_mosaic_dis_even_rate"})
model_reset()

SCAN11 = 80
clear_pf_row(SCAN11 + 1, "test11")
clear_sprite_entry(0)

# Sprite at sx=0 (cols 0..15)
write_sprite_entry(0, tile_code=0x14, sx=0, sy=SCAN11 + 1 - 8, color=0x01,
                   note="test11 sprite sx=0 cols=0..15")

# rate=4 (even) → spr_en = rate[0] = 0 → sprite not mosaicked
set_mosaic(SCAN11 + 1, rate=4, pf_en4=0b0001, note="test11 rate=4_even spr_en=0")

# With even rate, sprite reads its own column (no snap)
px11_col4_no_snap = spr_pixel_from_model(SCAN11, 4, mosaic_en=False, rate=4)
assert (px11_col4_no_snap & 0xF) == 1, \
    f"test11: col=4 sprite pen=1 no_snap, got {px11_col4_no_snap & 0xF}"

check_spr(SCAN11, 4, px11_col4_no_snap,
          f"test11 even_rate4 spr_not_mosaicked col=4 reads_own pen=1")


# ===========================================================================
# Test 12: All 4 PF planes mosaicked simultaneously (pf_en4=0b1111).
# All planes use same rate=3. Verify each plane's col=3 snaps to col=2.
# ===========================================================================
emit({"op": "reset", "note": "reset for test12 all4_pf_mosaicked"})
model_reset()

SCAN12 = 85
clear_pf_row(SCAN12 + 1, "test12")
for _pl in range(4):
    for _tx in range(20):
        write_pf_tile(_pl, _tx, (SCAN12 + 1) // 16, GRAD_TILE,
                      palette=_pl * 0x10)

set_mosaic(SCAN12 + 1, rate=3, pf_en4=0b1111, note="test12 all4_PF_en rate=3")

for _pl in range(4):
    px_col3 = bg_pixel_from_model(SCAN12, _pl, 3, mosaic_en=True, rate=3)
    px_col2 = bg_pixel_from_model(SCAN12, _pl, 2, mosaic_en=True, rate=3)
    assert px_col3 == px_col2, f"test12: PF{_pl+1} col=3 should snap to col=2"
    check_bg(SCAN12, 3, _pl, px_col3,
             f"test12 all4_PF_en PF{_pl+1} col=3→snap=2 pen={(px_col3 & 0xF)}")


# ===========================================================================
# Test 13: Mosaic off for all planes (pf_en4=0b0000) — verify all columns
# read normally when mosaic word exists but enables are cleared.
# ===========================================================================
emit({"op": "reset", "note": "reset for test13 pf_en4_zero_no_mosaic"})
model_reset()

SCAN13 = 90
clear_pf_row(SCAN13 + 1, "test13")
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN13 + 1) // 16, GRAD_TILE, palette=0x00)

# rate=3 but pf_en4=0 (no planes enabled)
set_mosaic(SCAN13 + 1, rate=3, pf_en4=0b0000, note="test13 rate=3 pf_en4=0 no_mosaic")

px13_col3 = bg_pixel_from_model(SCAN13, 0, 3, mosaic_en=False, rate=3)
px13_col2 = bg_pixel_from_model(SCAN13, 0, 2, mosaic_en=False, rate=3)
assert (px13_col3 & 0xF) != (px13_col2 & 0xF), \
    "test13: col=3 and col=2 should differ when mosaic disabled"

check_bg(SCAN13, 3, 0, px13_col3,
         f"test13 pf_en4=0 no_mosaic col=3 reads_own_pixel pen={(px13_col3 & 0xF)}")
check_bg(SCAN13, 2, 0, px13_col2,
         f"test13 pf_en4=0 no_mosaic col=2 reads_own_pixel pen={(px13_col2 & 0xF)}")


# ===========================================================================
# Test 14: Mosaic with non-zero xscroll — verify snap still works correctly.
# xscroll places the tile grid shifted; column-to-tile mapping changes.
# The snap formula always uses screen column (hpos - H_START), not canvas_x.
# So snap(3, 3) = 2 regardless of xscroll.
# ===========================================================================
emit({"op": "reset", "note": "reset for test14 mosaic_with_xscroll"})
model_reset()

SCAN14 = 95
clear_pf_row(SCAN14 + 1, "test14")
# Use solid tiles for simplicity; xscroll shifts which tile is visible
# Write tiles for the scrolled range
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN14 + 1) // 16, GRAD_TILE, palette=0x00)
# Also write tiles in the scroll-shifted area
for _tx in range(20, 32):
    write_pf_tile(0, _tx, (SCAN14 + 1) // 16, GRAD_TILE, palette=0x00)

# Set xscroll to 64 (integer part = 64>>6 = 1 pixel) — minimal scroll
m.ctrl[0] = 64   # PF1 xscroll raw = 64 → xscroll_int = 1
emit({"op": "write", "word_addr": 0, "data": 64, "be": 3,
      "note": "test14 PF1 xscroll=64 (1px shift)"})

set_mosaic(SCAN14 + 1, rate=3, pf_en4=0b0001, note="test14 mosaic rate=3 with xscroll")

# With xscroll, the linebuf is filled differently, but mosaic snap is still
# snap(col, rate) applied to the already-filled linebuf. The snap formula
# is purely screen-coordinate based.
px14_col3 = bg_pixel_from_model(SCAN14, 0, 3, mosaic_en=True, rate=3)
px14_col2 = bg_pixel_from_model(SCAN14, 0, 2, mosaic_en=True, rate=3)
# snap(3,3)=2 → col=3 reads col=2's pixel
assert px14_col3 == px14_col2, "test14: xscroll doesn't affect mosaic snap"

check_bg(SCAN14, 3, 0, px14_col3,
         f"test14 mosaic_with_xscroll col=3→snap=2 pen={(px14_col3 & 0xF)}")
check_bg(SCAN14, 2, 0, px14_col2,
         f"test14 mosaic_with_xscroll col=2 block_start pen={(px14_col2 & 0xF)}")


# ===========================================================================
# Test 15: Boundary verification — col=319 (rightmost active pixel).
# snap(319, 3): (319+114)=433; 433>=432 → 433-432=1; 1%4=1; snap=318.
# snap(318, 3): (318+114)=432; 432>=432 → 432-432=0; 0%4=0; snap=318.
# ===========================================================================
emit({"op": "reset", "note": "reset for test15 right_boundary_col319"})
model_reset()

SCAN15 = 100
clear_pf_row(SCAN15 + 1, "test15")
for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN15 + 1) // 16, GRAD_TILE, palette=0x00)

set_mosaic(SCAN15 + 1, rate=3, pf_en4=0b0001, note="test15 mosaic rate=3 right_boundary")

assert mosaic_snap(318, 3) == 318, f"snap(318,3) = {mosaic_snap(318, 3)}"
assert mosaic_snap(319, 3) == 318, f"snap(319,3) = {mosaic_snap(319, 3)}"

px15_col318 = bg_pixel_from_model(SCAN15, 0, 318, mosaic_en=True, rate=3)
px15_col319 = bg_pixel_from_model(SCAN15, 0, 319, mosaic_en=True, rate=3)
assert px15_col319 == px15_col318, "test15: col=319 should snap to col=318"

check_bg(SCAN15, 318, 0, px15_col318,
         f"test15 right_boundary col=318 block_start pen={(px15_col318 & 0xF)}")
check_bg(SCAN15, 319, 0, px15_col319,
         f"test15 right_boundary col=319→snap=318 matches_col318")


# ===========================================================================
# Write vectors
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step15_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
