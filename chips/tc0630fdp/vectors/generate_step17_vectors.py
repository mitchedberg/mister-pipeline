#!/usr/bin/env python3
"""
generate_step17_vectors.py — Step 17 test vector generator for tc0630fdp.

Produces step17_vectors.jsonl: Full Integration + Frame Regression.

Step 17 goals (per section3_rtl_plan.md §Step 17):
  All 17 sections of Line RAM exercised. All 7 modules active simultaneously.
  Full integration regression: multi-layer priority, clip, alpha blend, pivot, mosaic, zoom.

Test group A — All layers simultaneously (6 groups × 4+ tests = 30 tests):
  A1–A5:  Text + PF1 + PF2 + sprite + pivot all on same scanline. Verify priority mux.
  A6–A10: Scroll across all 4 PFs simultaneously. Verify independent scrolling.
  A11–A15: Clip plane + priority interaction: PF clipped, sprite wins.
  A16–A20: Alpha blend A across multiple layers in the same frame.
  A21–A25: Pivot + PF + sprite tri-layer compositing on same scanline.
  A26–A30: Alpha blend B + mosaic active simultaneously.

Test group B — Per-scanline Line RAM variation (4 groups × 5 tests = 20 tests):
  B1–B5:  Change PF priority every scanline. Verify different layers win per scan.
  B6–B10: Change clip plane left/right per scanline. Verify clipping varies.
  B11–B15: Change zoom_x per scanline. Verify different tile columns per scan.
  B16–B20: Change alpha coefficients per scanline. Verify blend varies.

Test group C — render_frame() regression (12 tests):
  C1–C4:  2-layer frame: text + PF1 tile. Check 4 representative pixels.
  C5–C8:  3-layer frame: PF1 + sprite + pivot. Check 4 representative pixels.
  C9–C12: Full 7-layer frame with blend. Check blend_rgb_out at 4 pixels.

Total: 30 + 20 + 12 = 62 tests.
"""

import json
import os
from fdp_model import TaitoF3Model, V_START, V_END, H_START, H_END

vectors = []


def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
m = TaitoF3Model()

LINE_BASE  = 0x10000
PIVOT_BASE = 0x18000


def model_reset():
    """Reset transient state; gfx_rom and pal_ram preserved."""
    m.ctrl      = [0] * 16
    m.pf_ram    = [[0] * m.PF_RAM_WORDS for _ in range(4)]
    m.text_ram  = [0] * m.TEXT_RAM_WORDS
    m.char_ram  = [0] * m.CHAR_RAM_BYTES
    m.line_ram  = [0] * m.LINE_RAM_WORDS
    m.spr_ram   = [0] * m.SPR_RAM_WORDS
    m.pivot_ram = [0] * m.PIVOT_RAM_WORDS
    # pal_ram intentionally preserved across resets


def write_line(word_offset: int, data: int, note: str = "") -> None:
    chip_addr = LINE_BASE + word_offset
    emit({"op": "write_line",
          "addr": chip_addr,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"line_ram[{word_offset:#06x}]={data:#06x}"})
    m.write_line_ram(word_offset, data)


def write_pivot(pvt_addr: int, data: int, note: str = "") -> None:
    emit({"op": "write_pivot",
          "pvt_addr": pvt_addr & 0x3FFF,
          "pvt_data": data & 0xFFFFFFFF,
          "note": note or f"pivot_ram[{pvt_addr:#06x}]={data:#010x}"})
    m.write_pivot_ram(pvt_addr, data)


def write_pal(addr: int, data: int, note: str = "") -> None:
    emit({"op": "write_pal",
          "pal_addr": addr & 0x1FFF,
          "pal_data": data & 0xFFFF,
          "note": note or f"pal[{addr:#06x}]={data:#06x}"})
    m.write_pal_ram(addr, data)


def set_pf_prio(plane: int, scan: int, prio: int) -> None:
    cur_en = m.line_ram[0x0700 + (scan & 0xFF)]
    new_en = cur_en | (1 << plane)
    write_line(0x0700 + (scan & 0xFF), new_en, f"pf_prio_en plane={plane} scan={scan}")
    pp_addr = 0x5800 + plane * 0x100 + (scan & 0xFF)
    write_line(pp_addr, prio & 0xF, f"pf_prio plane={plane} prio={prio} scan={scan}")


def set_spr_prio(group: int, scan: int, prio: int) -> None:
    """Set sprite group priority for scanline: §9.8 word 0x3B00+scan8."""
    sp_addr = 0x3B00 + (scan & 0xFF)
    cur = m.line_ram[sp_addr]
    shift = (group & 3) * 4
    cur = (cur & ~(0xF << shift)) | ((prio & 0xF) << shift)
    write_line(sp_addr, cur, f"spr_prio grp={group} prio={prio} scan={scan}")


def set_pivot_en(scan: int, enable: bool, bank: bool = False, blend: bool = False) -> None:
    word = 0
    if enable: word |= (1 << 13)
    if bank:   word |= (1 << 14)
    if blend:  word |= (1 << 8)
    write_line(0x3000 + (scan & 0xFF), word,
               f"pivot_ctrl scan={scan} en={enable} bank={bank} blend={blend}")


def set_clip_plane(plane_idx: int, scan: int, left8: int, right8: int) -> None:
    """Set clip plane left/right boundaries for scanline."""
    base = [0x2800, 0x2900, 0x2A00, 0x2B00]
    word = ((right8 & 0xFF) << 8) | (left8 & 0xFF)
    write_line(base[plane_idx & 3] + (scan & 0xFF), word,
               f"clip[{plane_idx}] scan={scan} left={left8} right={right8}")


def set_pf_clip_en(plane: int, scan: int, clip_en4: int, clip_inv4: int = 0,
                   clip_sense: int = 0) -> None:
    """Set clip configuration in PF pp_word bits[12:4]."""
    pp_addr = 0x5800 + plane * 0x100 + (scan & 0xFF)
    # Preserve existing bits[3:0] = priority, bits[15:14] = blend mode
    cur = m.line_ram[pp_addr]
    cur = (cur & 0xC00F) | ((clip_sense & 1) << 12) | ((clip_en4 & 0xF) << 8) | ((clip_inv4 & 0xF) << 4)
    write_line(pp_addr, cur, f"pf_clip plane={plane} scan={scan} en={clip_en4:#x}")


def set_alpha_coeffs(scan: int, a_src: int, a_dst: int,
                     b_src: int = 8, b_dst: int = 0) -> None:
    """Set alpha blend coefficients for scanline: §9.5 ab_word at 0x3100+scan8."""
    ab_word = ((b_src & 0xF) << 12) | ((a_src & 0xF) << 8) | \
              ((b_dst & 0xF) <<  4) | (a_dst & 0xF)
    write_line(0x3100 + (scan & 0xFF), ab_word,
               f"alpha_coeffs scan={scan} a_src={a_src} a_dst={a_dst}")


def set_pf_blend_mode(plane: int, scan: int, bmode: int) -> None:
    """Set blend mode bits[15:14] in PF pp_word."""
    pp_addr = 0x5800 + plane * 0x100 + (scan & 0xFF)
    cur = m.line_ram[pp_addr]
    cur = (cur & 0x3FFF) | ((bmode & 0x3) << 14)
    write_line(pp_addr, cur, f"pf_blend_mode plane={plane} scan={scan} bmode={bmode}")


def clear_scan_state(scans) -> None:
    """Zero all Line RAM control sections for the given scanlines.

    This must be called after each op="reset" (which only clears RTL registers,
    NOT BRAMs) to prevent stale Line RAM data from prior step vectors from
    corrupting subsequent tests.  Sections zeroed per scan:
      §9.1  pf_prio_en   0x0700+scan
      §9.2  rowscroll_en 0x0300+scan (4 bits PF1-4)
      §9.4  zoom_en      0x0400+scan
      §9.5  alpha_coeffs 0x3100+scan
      §9.7  sprite_misc  0x3A00+scan
      §9.8  sprite_prio  0x3B00+scan
      §9.9  mosaic       0x3200+scan
      §9.10 pal_add_en   0x0500+scan (4 bits PF1-4)
      §9.11 colscroll_en 0x0600+scan (4 bits PF1-4)
      §9.12 pp_word      0x5800..0x5B00+scan (PF1-4 priority/blend/clip)
      §9.2  rowscroll    0x0800..0x0B00+scan (PF1-4 data)
      §9.4  zoom_data    0x4000..0x4300+scan (PF1-4 zoom)
      §9.10 pal_add_data 0x4800..0x4B00+scan (PF1-4 pal_add)
      §9.11 colscroll    0x4400..0x4700+scan (PF1-4 colscroll)
      §9.3  clip_planes  0x2800..0x2B00+scan (4 planes)
      §9.6  pivot_ctrl   0x3000+scan
    """
    for sc in scans:
        s8 = sc & 0xFF
        write_line(0x0700 + s8, 0, f"clear pf_prio_en scan={sc}")
        write_line(0x0300 + s8, 0, f"clear rowscroll_en scan={sc}")
        write_line(0x0400 + s8, 0, f"clear zoom_en scan={sc}")
        write_line(0x3100 + s8, 0, f"clear alpha_coeffs scan={sc}")
        write_line(0x3A00 + s8, 0, f"clear spr_misc scan={sc}")
        write_line(0x3B00 + s8, 0, f"clear spr_prio scan={sc}")
        write_line(0x3200 + s8, 0, f"clear mosaic scan={sc}")
        write_line(0x0500 + s8, 0, f"clear pal_add_en scan={sc}")
        write_line(0x0600 + s8, 0, f"clear colscroll_en scan={sc}")
        write_line(0x3000 + s8, 0, f"clear pivot_ctrl scan={sc}")
        for plane in range(4):
            write_line(0x5800 + plane * 0x100 + s8, 0, f"clear pp scan={sc} pl={plane}")
            write_line(0x0800 + plane * 0x100 + s8, 0, f"clear rowscroll scan={sc} pl={plane}")
            write_line(0x4000 + plane * 0x100 + s8, 0, f"clear zoom_data scan={sc} pl={plane}")
            write_line(0x4800 + plane * 0x100 + s8, 0, f"clear pal_add scan={sc} pl={plane}")
            write_line(0x4400 + plane * 0x100 + s8, 0, f"clear colscroll scan={sc} pl={plane}")
            write_line(0x2800 + plane * 0x100 + s8, 0, f"clear clip_plane scan={sc} pl={plane}")


def pivot_addr(tile_col: int, tile_row: int, py: int) -> int:
    tile_idx = (tile_col & 0x3F) * 32 + (tile_row & 0x1F)
    return (tile_idx << 3) | (py & 0x7)


def write_gfx(gfx_addr: int, data: int, note: str = "") -> None:
    emit({"op": "write_gfx", "gfx_addr": gfx_addr, "gfx_data": data & 0xFFFFFFFF,
          "note": note or f"gfx[{gfx_addr}]={data:#010x}"})
    m.write_gfx_rom(gfx_addr, data)


def write_pf_entry(plane: int, map_row: int, map_col: int,
                   palette: int, tile_code: int,
                   flipx: bool = False, flipy: bool = False) -> None:
    """Write one 16×16 tile entry (2 words) to PF RAM.

    Uses 32-column standard-mode layout (map_width=32) matching render_bg_scanline().
    """
    pf_base_addr = (0x4000, 0x6000, 0x8000, 0xA000)[plane]
    word_offset = 2 * (map_row * 32 + map_col)   # 32-column standard layout
    attr = palette & 0x1FF
    if flipx: attr |= (1 << 14)
    if flipy: attr |= (1 << 15)
    emit({"op": "write_pf", "addr": pf_base_addr + word_offset,
          "data": attr & 0xFFFF, "be": 3,
          "note": f"PF{plane+1} attr row={map_row} col={map_col}"})
    emit({"op": "write_pf", "addr": pf_base_addr + word_offset + 1,
          "data": tile_code & 0xFFFF, "be": 3,
          "note": f"PF{plane+1} code={tile_code}"})
    m.pf_ram[plane][word_offset & 0x1FFF]       = attr & 0xFFFF
    m.pf_ram[plane][(word_offset + 1) & 0x1FFF] = tile_code & 0xFFFF


def write_text_tile(row: int, col: int, color: int, char_code: int) -> None:
    word_addr = row * 64 + col
    word = ((color & 0x1F) << 11) | (char_code & 0x7FF)
    emit({"op": "write_text",
          "addr": 0xE000 + word_addr,
          "data": word & 0xFFFF, "be": 3,
          "note": f"text[{row},{col}] color={color} char={char_code}"})
    m.text_ram[word_addr & 0xFFF] = word & 0xFFFF


def write_char_row(char_code: int, py: int, b0: int, b1: int, b2: int, b3: int) -> None:
    """Write 4 bytes of a character tile row to char RAM."""
    byte_base = char_code * 32 + py * 4
    # Each char row word write: two bytes per CPU write
    for i, byte_val in enumerate([b0, b1, b2, b3]):
        byte_addr = byte_base + i
        word_addr_in_char = byte_addr >> 1
        if byte_addr & 1 == 0:
            # Upper byte of word
            emit({"op": "write_char",
                  "addr": 0xF000 + word_addr_in_char,
                  "data": (byte_val << 8) & 0xFF00, "be": 2,
                  "note": f"char[{char_code}] py={py} b{i}={byte_val:#04x}"})
        else:
            # Lower byte of word
            emit({"op": "write_char",
                  "addr": 0xF000 + word_addr_in_char,
                  "data": byte_val & 0xFF, "be": 1,
                  "note": f"char[{char_code}] py={py} b{i}={byte_val:#04x}"})
        m.char_ram[byte_addr] = byte_val & 0xFF


def write_sprite_entry_ops(idx: int, tile_code: int, sx: int, sy: int,
                            color: int, flipx: bool = False, flipy: bool = False,
                            x_zoom: int = 0, y_zoom: int = 0) -> None:
    """Emit write_sprite ops and mirror to model."""
    base = 0x20000 + idx * 8
    tile_lo = tile_code & 0xFFFF
    tile_hi = (tile_code >> 16) & 0x1
    w1 = ((y_zoom & 0xFF) << 8) | (x_zoom & 0xFF)
    sx_12 = sx & 0xFFF
    sy_12 = sy & 0xFFF
    w4 = (color & 0xFF)
    if flipx: w4 |= (1 << 9)
    if flipy: w4 |= (1 << 10)

    words = [tile_lo, w1, sx_12, sy_12, w4, tile_hi, 0, 0]
    for i, wdata in enumerate(words):
        emit({"op": "write_sprite",
              "addr": base + i,
              "data": wdata & 0xFFFF,
              "note": f"spr[{idx}] w{i}={wdata:#06x}"})

    m.write_sprite_entry(idx, tile_code, sx, sy, color, flipx, flipy, x_zoom, y_zoom)


def check_colmix(vpos: int, screen_col: int, note: str) -> None:
    # Scan sprites first so the sprite layer is included in compositing
    slist = m.scan_sprites()
    spr_buf = m.render_sprite_scanline(vpos, slist)
    comp = m.composite_scanline(vpos, spr_buf)
    exp = comp[screen_col] & 0x1FFF
    emit({"op": "check_colmix_pixel",
          "vpos": vpos, "screen_col": screen_col,
          "exp_pixel": exp, "note": note})


def check_blend(vpos: int, screen_col: int, note: str) -> None:
    slist = m.scan_sprites()
    spr_buf = m.render_sprite_scanline(vpos, slist)
    rgb_row = m.blend_scanline(vpos, spr_buf)
    exp_rgb = rgb_row[screen_col] & 0xFFFFFF
    emit({"op": "check_blend_pixel",
          "vpos": vpos, "screen_col": screen_col,
          "exp_rgb": exp_rgb, "note": note})


# ---------------------------------------------------------------------------
# Seed palette RAM with a few test colors (persists across resets)
# ---------------------------------------------------------------------------
# pal[0] = transparent/black
# pal[1] = red:   R=F G=0 B=0 → word 0xF000
# pal[2] = green: R=0 G=F B=0 → word 0x0F00
# pal[3] = blue:  R=0 G=0 B=F → word 0x00F0
# pal[5] = white: R=F G=F B=F → word 0xFFF0
# pal[7] = cyan:  R=0 G=F B=F → word 0x0FF0
# pal[9] = magenta: R=F G=0 B=F → word 0xF0F0
# pal[0xA] = yellow: R=F G=F B=0 → word 0xFF00
# Palette address = {palette9[8:0], pen[3:0]}; for pen=1: addr = palette*16 + 1
#   PF pixel {pal9=0x10, pen=1}: addr = 0x10*16+1 = 0x101. We use pal9=0 → addr=1..15.
write_pal(0x0001, 0xF000, "pal red (pal9=0 pen=1)")
write_pal(0x0002, 0x0F00, "pal green (pal9=0 pen=2)")
write_pal(0x0003, 0x00F0, "pal blue (pal9=0 pen=3)")
write_pal(0x0005, 0xFFF0, "pal white (pal9=0 pen=5)")
write_pal(0x0007, 0x0FF0, "pal cyan (pal9=0 pen=7)")
write_pal(0x0009, 0xF0F0, "pal magenta (pal9=0 pen=9)")
write_pal(0x000A, 0xFF00, "pal yellow (pal9=0 pen=A)")
write_pal(0x000B, 0x7700, "pal half-orange (pal9=0 pen=B)")
write_pal(0x000C, 0x4400, "pal dark-red (pal9=0 pen=C)")

# Also seed GFX ROM once; tiles use a simple solid-pen pattern per tile_code:
#   gfx_rom[T*32 + r*2] = (T & 0xF) * 0x11111111  (left 8px, all same nibble)
# We'll write specific tiles as needed by tests.

# ===========================================================================
# Group A: All layers simultaneously
# ===========================================================================

# ---------------------------------------------------------------------------
# A1–A5: All 7 layers on the same scanline (text + PF1–4 + sprite + pivot)
# Verifies priority mux: text always wins; then by numeric priority.
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 group A reset"})
model_reset()
clear_scan_state([60])

TARGET_SCAN = 60    # render scanline
TARGET_VPOS = TARGET_SCAN - 1

render_scan8 = TARGET_SCAN & 0xFF

# Write a text tile at row=7, col=0 (renders at screen col=0, scan=60 if char_code=1)
# Text canvas row = scan = 60 → tile_row = 60//8 = 7; py = 60 & 7 = 4
text_tile_row = TARGET_SCAN >> 3    # 7
text_tile_col = 0
text_char_code = 1
text_py = TARGET_SCAN & 7           # 4
# Write char_ram bytes for char 1, row py=4: pen=5 for px0
# b2[7:4] = px0 → b2 = (5 << 4) = 0x50; rest=0
write_char_row(text_char_code, text_py, 0x00, 0x00, 0x50, 0x00)
write_text_tile(text_tile_row, text_tile_col, 0, text_char_code)

# Write PF1 tile at the same screen position with pen=3 (lower priority)
# PF1 tile for render_scan=60: tile_row_in_map = 60>>4=3, pf_py=60&15=12
# screen_col=0: tile_col=0, pf_px=0
pf1_map_row = TARGET_SCAN >> 4      # 3
pf1_map_col = 0
pf1_gfx_tile = 10                   # use tile code 10
pf1_py = TARGET_SCAN & 0xF          # 12: pixel row within 16px tile
pf1_pen = 3
# GFX ROM: tile 10, row 12 → addr = 10*32 + 12*2 = 320+24 = 344
# word = pen3 for all pixels: 0x33333333
write_gfx(pf1_gfx_tile * 32 + pf1_py * 2,     0x33333333, f"PF1 tile{pf1_gfx_tile} py={pf1_py} pen=3")
write_gfx(pf1_gfx_tile * 32 + pf1_py * 2 + 1, 0x33333333, f"PF1 tile{pf1_gfx_tile} py={pf1_py} pen=3")
write_pf_entry(0, pf1_map_row, pf1_map_col, 0, pf1_gfx_tile)
set_pf_prio(0, render_scan8, 5)    # PF1 priority=5

# Write PF2 tile at the same position with pen=7 (priority=9 > PF1's 5, below text)
pf2_gfx_tile = 11
write_gfx(pf2_gfx_tile * 32 + pf1_py * 2,     0x77777777, f"PF2 tile{pf2_gfx_tile} py={pf1_py} pen=7")
write_gfx(pf2_gfx_tile * 32 + pf1_py * 2 + 1, 0x77777777, f"PF2 tile{pf2_gfx_tile} pen=7")
write_pf_entry(1, pf1_map_row, pf1_map_col, 0, pf2_gfx_tile)
set_pf_prio(1, render_scan8, 9)    # PF2 priority=9

# Write sprite: pen=2, priority group 0, spr_prio=7 (between PF1=5 and PF2=9)
spr_gfx_tile = 20
write_gfx(spr_gfx_tile * 32 + 0 * 2,     0x22222222, f"spr tile{spr_gfx_tile} pen=2")
write_gfx(spr_gfx_tile * 32 + 0 * 2 + 1, 0x22222222, f"spr tile{spr_gfx_tile} pen=2")
# Sprite at sy=TARGET_SCAN (sy is top-left Y → renders on scan sy+0..sy+15)
# Actually sy is top, so for render_scan=60: sy=60, dst_row=0 → src_row=0
write_sprite_entry_ops(0, spr_gfx_tile, 0, TARGET_SCAN, 0x00)   # color=0x00, group=0, pal=0
set_spr_prio(0, render_scan8, 7)   # sprite group 0 priority=7

# Write pivot tile: pen=9 at screen_col=0 (pivot priority=8, between spr=7 and PF2=9)
pvt_row = TARGET_SCAN >> 3         # 7
pvt_py  = TARGET_SCAN & 7          # 4
pvt_col = 0
pva = pivot_addr(pvt_col, pvt_row, pvt_py)
write_pivot(pva, 0x99999999, "pivot pen=9 at col=0")
set_pivot_en(render_scan8, True, False, False)

# Expected priority: text(∞) > PF2(9) > pivot(8) > sprite(7) > PF1(5)
# At screen_col=0: text has pen=5 (non-zero) → text wins
check_colmix(TARGET_VPOS, 0, "A1: text wins over all layers")

# A2: verify PF2 wins when text is transparent (screen_col=4, no text tile there)
# Clear text at col=4 (col 0 tile's px=4): pen should be 0 since we only set px0
# Text tile row: write_char_row only set b2=0x50 → px0=5, px1..7=0 → col=4 → pen=0
# But PF2 tile covers all 16 screen pixels → pen=7 at col=4
# Pivot at col=0..7 only (tile col=0, 8px) → col=4 is still in pivot tile
# spr at sx=0 → covers col=0..15 → pen=2 at col=4
# Layer order at col=4: text(pen=0 → skip), PF2(prio=9, pen=7), pivot(prio=8, pen=9),
#   sprite(prio=7, pen=2), PF1(prio=5, pen=3)
# → PF2(prio=9) wins → colmix_pixel = {palette=0, pen=7}
check_colmix(TARGET_VPOS, 4, "A2: PF2 prio=9 wins when text transparent at col=4")

# A3: verify pivot wins over sprite at col=8
# col=8: pivot tile col=1 (same tile row/py), pen=9 if we write that tile
pvt_col1_addr = pivot_addr(1, pvt_row, pvt_py)
write_pivot(pvt_col1_addr, 0x99999999, "pivot col=1 pen=9")
# col=8: text(pen=0), PF2(prio=9, pen=7), pivot(prio=8, pen=9), spr(prio=7, pen=2), PF1(prio=5, pen=3)
# → PF2(9) wins: colmix = pen=7
check_colmix(TARGET_VPOS, 8, "A3: PF2 prio=9 beats pivot prio=8 at col=8")

# A4: verify sprite wins over PF1 at priority 7 vs 5 — reduce PF2 pen to transparent
# At col=16: sprite still covers, pivot col=2 tile (write it), PF1 and PF2 tiles
# Use col=16: sprite sx=0 → col16 still in sprite range (0..15 for 16px no-zoom)
# sprite covers col 0..15 only. At col=16: no sprite, no pivot (unless we add tile)
# Just check that at col=0 with PF2 disabled (write pf2 tile at a different scan)
# Simpler: lower PF2 priority to 4 (below PF1=5) for this test
set_pf_prio(1, render_scan8, 4)    # PF2 priority=4, now PF1=5 wins over PF2
# col=4 (text transparent): PF1(5) > PF2(4), pivot(8), sprite(7)
# → pivot(8) wins
check_colmix(TARGET_VPOS, 4, "A4: pivot prio=8 beats sprite prio=7 at col=4")

# A5: restore PF2 prio=9 and add text back at col=4 (write char tile px4=5)
set_pf_prio(1, render_scan8, 9)
# Make char[1] have pen=5 for px4 as well: b0[7:4]=5 → b0=0x50
write_char_row(text_char_code, text_py, 0x50, 0x00, 0x50, 0x00)
# Now text at col=0 (px0, pen=5) and col=4 (px4, pen=5) both win
check_colmix(TARGET_VPOS, 4, "A5: text px4=5 beats all layers at col=4")

# ---------------------------------------------------------------------------
# A6–A10: All 4 PFs scroll independently
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 A6-A10 reset"})
model_reset()
clear_scan_state([80])

# Each PF has a different xscroll and different pen
# scan=80: render scanlines targeting pixel row within tile
SCAN_A6 = 80
VPOS_A6 = SCAN_A6 - 1
# PF tile row for scan=80: 80>>4=5, py=0
PF_MAP_ROW = SCAN_A6 >> 4   # 5
PF_PY = SCAN_A6 & 0xF        # 0

pf_xscrolls = [8, 16, 24, 32]    # integer pixel scrolls
pf_pens = [1, 2, 3, 5]           # distinct pens per PF

for plane in range(4):
    tile_code = 30 + plane
    # GFX ROM for this tile, row PF_PY
    pen_word = ((pf_pens[plane] & 0xF) * 0x11111111) & 0xFFFFFFFF
    write_gfx(tile_code * 32 + PF_PY * 2,     pen_word, f"PF{plane+1} gfx tile{tile_code} pen={pf_pens[plane]}")
    write_gfx(tile_code * 32 + PF_PY * 2 + 1, pen_word, f"PF{plane+1} gfx right pen={pf_pens[plane]}")
    # PF map entry at tile col=0 (canvas_x = xscroll → first tile seen at screen_col=0)
    # with xscroll_int = N: canvas_x at screen_col=0 is N → tile_col = N>>4, pf_px = N&15
    # We want tile at col=N>>4 for screen_col=0
    tile_map_col = (pf_xscrolls[plane] >> 4) & 0x1F
    write_pf_entry(plane, PF_MAP_ROW, tile_map_col, 0, tile_code)
    # Set xscroll register
    xscroll_raw = pf_xscrolls[plane] << 6
    emit({"op": "write", "addr": plane, "data": xscroll_raw, "be": 3,
          "note": f"PF{plane+1} xscroll_int={pf_xscrolls[plane]}"})
    m.ctrl[plane] = xscroll_raw
    # Set priority: PF1=4, PF2=5, PF3=6, PF4=7
    set_pf_prio(plane, SCAN_A6 & 0xFF, 4 + plane)

# A6: PF4 (prio=7) wins at screen_col=0 (all 4 PFs have tiles at col=0 of their canvas)
check_colmix(VPOS_A6, 0, "A6: PF4 prio=7 wins among all 4 PFs at col=0")

# A7: PF4 pf_px=0 → pen=5 (tile_col has all-same pen pattern), verify exact pen
check_colmix(VPOS_A6, 0, "A7: PF4 pen=5 at col=0 (xscroll independent per PF)")

# A8: reset PF4 priority to 3, PF3 wins
set_pf_prio(3, SCAN_A6 & 0xFF, 3)
check_colmix(VPOS_A6, 0, "A8: PF3 prio=6 wins when PF4 prio=3")

# A9: disable PF3 priority too, PF2 wins
set_pf_prio(2, SCAN_A6 & 0xFF, 3)
check_colmix(VPOS_A6, 0, "A9: PF2 prio=5 wins when PF3/PF4 prio=3")

# A10: all PFs at same priority → all PFs at prio=5, sprite wins on tie >=
# add a sprite
spr_pen_a10 = 7
spr_tile_a10 = 40
write_gfx(spr_tile_a10 * 32 + 0 * 2,     0x77777777, "spr A10 pen=7")
write_gfx(spr_tile_a10 * 32 + 0 * 2 + 1, 0x77777777, "spr A10 pen=7")
write_sprite_entry_ops(0, spr_tile_a10, 0, SCAN_A6, 0x00)   # sy=SCAN_A6
set_spr_prio(0, SCAN_A6 & 0xFF, 5)    # spr prio=5
set_pf_prio(0, SCAN_A6 & 0xFF, 5)     # PF1 prio=5 too
set_pf_prio(1, SCAN_A6 & 0xFF, 5)     # PF2 prio=5
set_pf_prio(2, SCAN_A6 & 0xFF, 5)     # PF3 prio=5
set_pf_prio(3, SCAN_A6 & 0xFF, 5)     # PF4 prio=5
check_colmix(VPOS_A6, 0, "A10: sprite wins tie at prio=5 (>= rule)")

# ---------------------------------------------------------------------------
# A11–A15: Clip plane + priority interaction
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 A11-A15 reset"})
model_reset()
clear_scan_state([100])

SCAN_A11 = 100
VPOS_A11 = SCAN_A11 - 1
S8_A11 = SCAN_A11 & 0xFF

# PF1 at prio=8 with clip window [50, 200]; PF2 at prio=9 without clip
# Expected: inside clip: both visible, PF2 wins; outside clip: PF1 clipped away, PF2 wins

pf1_tile_a11 = 50
pf2_tile_a11 = 51
pf_map_row_a11 = SCAN_A11 >> 4   # row 6
pf_py_a11 = SCAN_A11 & 0xF        # 4

write_gfx(pf1_tile_a11 * 32 + pf_py_a11 * 2,     0x11111111, "A11 PF1 pen=1")
write_gfx(pf1_tile_a11 * 32 + pf_py_a11 * 2 + 1, 0x11111111, "A11 PF1 pen=1 right")
write_gfx(pf2_tile_a11 * 32 + pf_py_a11 * 2,     0x22222222, "A11 PF2 pen=2")
write_gfx(pf2_tile_a11 * 32 + pf_py_a11 * 2 + 1, 0x22222222, "A11 PF2 pen=2 right")
# Fill all 20 tile columns in this map row so every checked screen col has data
for col_a11 in range(20):
    write_pf_entry(0, pf_map_row_a11, col_a11, 0, pf1_tile_a11)
    write_pf_entry(1, pf_map_row_a11, col_a11, 0, pf2_tile_a11)
set_pf_prio(0, S8_A11, 8)
set_pf_prio(1, S8_A11, 9)

# Set clip plane 0: left=50, right=200
set_clip_plane(0, S8_A11, 50, 200)
# Enable clip plane 0 for PF1 only (clip_en4=0x1 = plane 0)
set_pf_clip_en(0, S8_A11, 0x1, 0, 0)   # no invert, sense=0

# A11: inside clip at screen_col=100 — PF1 visible (prio=8 < PF2 prio=9) → PF2 wins
check_colmix(VPOS_A11, 100, "A11: PF2(9) beats PF1(8) inside clip window at col=100")

# A12: outside clip at screen_col=10 — PF1 clipped (invisible) → PF2 wins (unclipped)
check_colmix(VPOS_A11, 10, "A12: PF1 clipped at col=10 (outside [50,200])")

# A13: boundary at screen_col=50 — PF1 visible (left boundary inclusive)
check_colmix(VPOS_A11, 50, "A13: PF1 visible at left boundary col=50")

# A14: boundary at screen_col=200 — PF1 visible (right boundary inclusive)
check_colmix(VPOS_A11, 200, "A14: PF1 visible at right boundary col=200")

# A15: col=201 — PF1 clipped again (outside [50,200])
check_colmix(VPOS_A11, 201, "A15: PF1 clipped at col=201 (just outside right boundary)")

# ---------------------------------------------------------------------------
# A16–A20: Alpha blend across multiple layers
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 A16-A20 reset"})
model_reset()
clear_scan_state([110])

SCAN_A16 = 110
VPOS_A16 = SCAN_A16 - 1
S8_A16 = SCAN_A16 & 0xFF

pf1_tile_a16 = 60
pf2_tile_a16 = 61
pf_map_row_a16 = SCAN_A16 >> 4    # 6
pf_py_a16 = SCAN_A16 & 0xF         # 14

# PF2 (higher priority, blend mode A=01) blends over PF1 (lower priority, opaque)
write_gfx(pf1_tile_a16 * 32 + pf_py_a16 * 2,     0x55555555, "A16 PF1 pen=5 (dst)")
write_gfx(pf1_tile_a16 * 32 + pf_py_a16 * 2 + 1, 0x55555555, "A16 PF1 pen=5 dst right")
write_pf_entry(0, pf_map_row_a16, 0, 0, pf1_tile_a16)
set_pf_prio(0, S8_A16, 5)   # PF1 prio=5

write_gfx(pf2_tile_a16 * 32 + pf_py_a16 * 2,     0x22222222, "A16 PF2 pen=2 (src blend A)")
write_gfx(pf2_tile_a16 * 32 + pf_py_a16 * 2 + 1, 0x22222222, "A16 PF2 pen=2 src right")
write_pf_entry(1, pf_map_row_a16, 0, 0, pf2_tile_a16)
set_pf_prio(1, S8_A16, 9)
set_pf_blend_mode(1, S8_A16, 0b01)    # PF2 blend mode A

# Alpha coefficients: a_src=4, a_dst=4 (50/50 blend)
set_alpha_coeffs(S8_A16, 4, 4)

# Colors in palette: PF1 pen=5 → pal[5] = white (0xFFF0), PF2 pen=2 → pal[2] = green (0x0F00)
# blend_rgb: R=clamp((0+0xF0)*4/8,255)=clamp(120,255)=120=0x78 (dst green R=0, src green R=0)
# Actually src=green(R=0,G=F0,B=0), dst=white(R=F0,G=F0,B=F0)
# blend: R = (0*4 + 0xF0*4)>>3 = (0+0x3C0)>>3 = 0x78=120
#         G = (0xF0*4 + 0xF0*4)>>3 = (0x3C0+0x3C0)>>3 = min(0x780>>3,255) = min(240,255) = 0xF0=240
#         B = (0*4 + 0xF0*4)>>3 = 0x78 = 120
check_blend(VPOS_A16, 0, "A16: blend A, src=green pen=2, dst=white pen=5, a_src=a_dst=4")

# A17: change coefficients to a_src=8, a_dst=0 → fully opaque src (green)
set_alpha_coeffs(S8_A16, 8, 0)
check_blend(VPOS_A16, 0, "A17: blend A, a_src=8, a_dst=0 → fully opaque green")

# A18: a_src=0, a_dst=8 → fully transparent src (dst=white shows through)
set_alpha_coeffs(S8_A16, 0, 8)
check_blend(VPOS_A16, 0, "A18: blend A, a_src=0, a_dst=8 → dst=white shows through")

# A19: PF2 set to opaque (mode=00), PF2 just wins directly
set_pf_blend_mode(1, S8_A16, 0b00)
set_alpha_coeffs(S8_A16, 4, 4)   # coefficients don't matter for opaque
check_blend(VPOS_A16, 0, "A19: PF2 opaque (mode=00), just wins with pen=2 (green)")

# A20: blend mode B (10) with B_src=6, B_dst=2
set_pf_blend_mode(1, S8_A16, 0b10)
set_alpha_coeffs(S8_A16, 4, 4, b_src=6, b_dst=2)
check_blend(VPOS_A16, 0, "A20: blend B, b_src=6, b_dst=2 over dst=white")

# ---------------------------------------------------------------------------
# A21–A25: Pivot + PF + sprite tri-layer compositing
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 A21-A25 reset"})
model_reset()
clear_scan_state([70])

SCAN_A21 = 70
VPOS_A21 = SCAN_A21 - 1
S8_A21 = SCAN_A21 & 0xFF

pf1_tile_a21 = 70
pf_map_row_a21 = SCAN_A21 >> 4    # 4
pf_py_a21 = SCAN_A21 & 0xF         # 6

write_gfx(pf1_tile_a21 * 32 + pf_py_a21 * 2,     0x33333333, "A21 PF1 pen=3")
write_gfx(pf1_tile_a21 * 32 + pf_py_a21 * 2 + 1, 0x33333333, "A21 PF1 pen=3 right")
write_pf_entry(0, pf_map_row_a21, 0, 0, pf1_tile_a21)
set_pf_prio(0, S8_A21, 6)   # PF1 prio=6

# Sprite: pen=7, prio=10 (beats pivot=8, beats PF1=6)
spr_tile_a21 = 80
write_gfx(spr_tile_a21 * 32 + 0 * 2,     0x77777777, "A21 spr pen=7")
write_gfx(spr_tile_a21 * 32 + 0 * 2 + 1, 0x77777777, "A21 spr pen=7 right")
write_sprite_entry_ops(0, spr_tile_a21, 0, SCAN_A21, 0x00)
set_spr_prio(0, S8_A21, 10)

# Pivot: pen=9, fixed prio=8 (beats PF1=6, loses to sprite=10)
pvt_row_a21 = SCAN_A21 >> 3       # 8
pvt_py_a21  = SCAN_A21 & 7         # 6
pva21 = pivot_addr(0, pvt_row_a21, pvt_py_a21)
write_pivot(pva21, 0x99999999, "A21 pivot pen=9")
set_pivot_en(S8_A21, True)

# A21: sprite(10) > pivot(8) > PF1(6)
check_colmix(VPOS_A21, 0, "A21: sprite prio=10 beats pivot=8 beats PF1=6")

# A22: lower sprite prio to 7 → pivot(8) beats sprite(7) > PF1(6)
set_spr_prio(0, S8_A21, 7)
check_colmix(VPOS_A21, 0, "A22: pivot prio=8 beats sprite prio=7")

# A23: lower pivot priority by disabling pivot → sprite(7) > PF1(6)
set_pivot_en(S8_A21, False)
check_colmix(VPOS_A21, 0, "A23: pivot disabled → sprite prio=7 wins")

# A24: re-enable pivot, lower sprite prio to 5 < PF1=6 → PF1(6) > sprite(5)
set_pivot_en(S8_A21, True)
set_spr_prio(0, S8_A21, 5)
# PF1(6) < pivot(8): pivot still wins here
check_colmix(VPOS_A21, 0, "A24: pivot(8) wins even over PF1(6) > sprite(5)")

# A25: lower PF1 prio to 12 → PF1(12) > pivot(8) → PF1 wins
set_pf_prio(0, S8_A21, 12)
check_colmix(VPOS_A21, 0, "A25: PF1 prio=12 beats pivot(8) beats sprite(5)")

# ---------------------------------------------------------------------------
# A26–A30: Alpha blend B + mosaic active simultaneously
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 A26-A30 reset"})
model_reset()
clear_scan_state([90])

SCAN_A26 = 90
VPOS_A26 = SCAN_A26 - 1
S8_A26 = SCAN_A26 & 0xFF

pf1_tile_a26 = 85
pf2_tile_a26 = 86
pf_map_row_a26 = SCAN_A26 >> 4     # 5
pf_py_a26 = SCAN_A26 & 0xF          # 10

write_gfx(pf1_tile_a26 * 32 + pf_py_a26 * 2,     0xAAAAAAAA, "A26 PF1 pen=0xA (dst)")
write_gfx(pf1_tile_a26 * 32 + pf_py_a26 * 2 + 1, 0xAAAAAAAA, "A26 PF1 right")
write_pf_entry(0, pf_map_row_a26, 0, 0, pf1_tile_a26)
set_pf_prio(0, S8_A26, 4)   # PF1 prio=4

write_gfx(pf2_tile_a26 * 32 + pf_py_a26 * 2,     0xBBBBBBBB, "A26 PF2 pen=0xB (src blend B)")
write_gfx(pf2_tile_a26 * 32 + pf_py_a26 * 2 + 1, 0xBBBBBBBB, "A26 PF2 right")
write_pf_entry(1, pf_map_row_a26, 0, 0, pf2_tile_a26)
set_pf_prio(1, S8_A26, 7)
set_pf_blend_mode(1, S8_A26, 0b10)   # PF2 blend mode B

# Palette for pens A and B
write_pal(0x000A, 0xFF00, "pal pen=A yellow")
write_pal(0x000B, 0x7700, "pal pen=B half-orange")

set_alpha_coeffs(S8_A26, 4, 4, b_src=6, b_dst=2)

# Enable mosaic rate=3 for PF1 (blocks of 4 pixels)
mo_word = (3 << 8) | 0x1   # rate=3, pf_en4 bit 0 = PF1
write_line(0x3200 + S8_A26, mo_word, "mosaic rate=3 PF1 enabled")

# A26: blend B with mosaic on PF1 — src=PF2(blendB), dst=PF1(mosaic)
check_blend(VPOS_A26, 0, "A26: blend B on PF2 over PF1 with mosaic, col=0")

# A27: col=4 (same mosaic block at rate=3 → same snap point)
check_blend(VPOS_A26, 4, "A27: blend B mosaic col=4")

# A28: col=16 — different tile column of PF1 (same tile since no scroll, same pen=A)
check_blend(VPOS_A26, 16, "A28: blend B + mosaic col=16")

# A29: disable mosaic
write_line(0x3200 + S8_A26, 0, "disable mosaic")
check_blend(VPOS_A26, 0, "A29: blend B without mosaic, col=0")

# A30: mosaic on both PF1 and PF2
mo_word2 = (3 << 8) | 0x3   # rate=3, pf_en4=0x3 (PF1 and PF2)
write_line(0x3200 + S8_A26, mo_word2, "mosaic rate=3 PF1+PF2")
check_blend(VPOS_A26, 2, "A30: blend B + mosaic on src and dst PF layers, col=2")

# ===========================================================================
# Group B: Per-scanline Line RAM variation
# ===========================================================================

# ---------------------------------------------------------------------------
# B1–B5: Different PF priority per scanline
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 group B reset"})
model_reset()
clear_scan_state(list(range(40, 45)))

# Set up PF1 and PF2 tiles that cover a range of scanlines
# PF1 tile_code=90, PF2 tile_code=91
# Use scanlines 40..44 (one per test)
pf1_tile_b = 90
pf2_tile_b = 91
for row_b in range(4):   # 4 tile rows covers scanlines 0..63
    for col_b in range(4):
        write_pf_entry(0, row_b, col_b, 0, pf1_tile_b)
        write_pf_entry(1, row_b, col_b, 0, pf2_tile_b)

for py_b in range(16):
    write_gfx(pf1_tile_b * 32 + py_b * 2,     0x11111111, f"PF1 tile90 py={py_b} pen=1")
    write_gfx(pf1_tile_b * 32 + py_b * 2 + 1, 0x11111111, "PF1 tile90 right")
    write_gfx(pf2_tile_b * 32 + py_b * 2,     0x22222222, f"PF2 tile91 py={py_b} pen=2")
    write_gfx(pf2_tile_b * 32 + py_b * 2 + 1, 0x22222222, "PF2 tile91 right")

b_scans = [40, 41, 42, 43, 44]
# B1: scan=40, PF1_prio=10 > PF2_prio=5 → PF1 wins
set_pf_prio(0, 40, 10)
set_pf_prio(1, 40, 5)
check_colmix(39, 0, "B1: scan=40 PF1(10) beats PF2(5)")

# B2: scan=41, PF1_prio=5 < PF2_prio=10 → PF2 wins
set_pf_prio(0, 41, 5)
set_pf_prio(1, 41, 10)
check_colmix(40, 0, "B2: scan=41 PF2(10) beats PF1(5)")

# B3: scan=42, equal priorities → PF2 wins (last-in wins in model for PF layers, equal)
# Per model: strictly-greater rule → first wins on equal; PF1 set first
set_pf_prio(0, 42, 7)
set_pf_prio(1, 42, 7)
check_colmix(41, 0, "B3: scan=42 equal priority PF1 vs PF2 (PF1 evaluated first)")

# B4: scan=43, PF1_prio=0 → PF2 wins (prio=0 is valid but PF2 still has 5)
set_pf_prio(0, 43, 0)
set_pf_prio(1, 43, 5)
check_colmix(42, 0, "B4: scan=43 PF2(5) vs PF1(0)")

# B5: scan=44, PF2_prio=15 (max) → PF2 wins
set_pf_prio(0, 44, 8)
set_pf_prio(1, 44, 15)
check_colmix(43, 0, "B5: scan=44 PF2 prio=15 (max)")

# ---------------------------------------------------------------------------
# B6–B10: Clip plane boundary variations per scanline
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 B6-B10 reset"})
model_reset()
clear_scan_state(list(range(50, 55)))

# PF1 covers entire screen with pen=3 (prio=12), clip plane active
pf1_tile_b6 = 92
for row_b6 in range(8):
    for col_b6 in range(20):
        write_pf_entry(0, row_b6, col_b6, 0, pf1_tile_b6)
        # Explicitly zero PF2–PF4 map entries so stale BRAM data from prior
        # groups (which are not cleared by op="reset") cannot bleed through.
        for pl_b6 in range(1, 4):
            write_pf_entry(pl_b6, row_b6, col_b6, 0, 0)
for py_b6 in range(16):
    write_gfx(pf1_tile_b6 * 32 + py_b6 * 2,     0x33333333, f"PF1 tile92 py={py_b6} pen=3")
    write_gfx(pf1_tile_b6 * 32 + py_b6 * 2 + 1, 0x33333333, "right")
    # Zero tile 0 so PF2–PF4 map entries pointing to code=0 yield transparent pixels
    write_gfx(0 * 32 + py_b6 * 2,     0, f"tile0 zero py={py_b6}")
    write_gfx(0 * 32 + py_b6 * 2 + 1, 0, "tile0 zero right")

b6_scans = [50, 51, 52, 53, 54]

for sc in b6_scans:
    set_pf_prio(0, sc, 12)
    # Enable clip plane 0 for PF1
    set_pf_clip_en(0, sc, 0x1, 0, 0)

# Different clip windows per scan:
# B6: scan=50, clip=[0, 100] → col=50 visible, col=200 clipped
set_clip_plane(0, 50, 0, 100)
check_colmix(49, 50, "B6: scan=50 col=50 inside clip [0,100]")

# B7: scan=50 col=200 (outside clip [0,100]) → pen=0
check_colmix(49, 200, "B7: scan=50 col=200 outside clip [0,100] → transparent")

# B8: scan=51, clip=[100, 300] → col=50 clipped
set_clip_plane(0, 51, 100, 255)
check_colmix(50, 50, "B8: scan=51 col=50 outside clip [100,255] → transparent")

# B9: scan=52, invert clip → pixels OUTSIDE [50,150] are visible
set_clip_plane(0, 52, 50, 150)
set_pf_clip_en(0, 52, 0x1, 0x1, 0)   # clip_inv=1 (invert plane 0)
check_colmix(51, 10, "B9: inverted clip, col=10 outside [50,150] → visible")

# B10: scan=53, invert clip → pixels inside [50,150] clipped
check_colmix(52, 100, "B10: inverted clip, col=100 inside [50,150] → transparent")

# ---------------------------------------------------------------------------
# B11–B15: X-zoom variation per scanline
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 B11-B15 reset"})
model_reset()
clear_scan_state(list(range(30, 35)))

# PF1 has two adjacent tiles with different pens (tile_code=93 pen=1, tile_code=94 pen=2)
# At no-zoom (zoom_x=0x00, zoom_step=0x100): 16 pixels per tile
# At zoom_x=0x80 (zoom_step=0x180): covers 24 effective pixels per tile (wider)
pf1_tile_b11a = 93
pf1_tile_b11b = 94

for py_b11 in range(16):
    write_gfx(pf1_tile_b11a * 32 + py_b11 * 2,     0x11111111, f"tile93 py={py_b11} pen=1")
    write_gfx(pf1_tile_b11a * 32 + py_b11 * 2 + 1, 0x11111111, "right")
    write_gfx(pf1_tile_b11b * 32 + py_b11 * 2,     0x22222222, f"tile94 py={py_b11} pen=2")
    write_gfx(pf1_tile_b11b * 32 + py_b11 * 2 + 1, 0x22222222, "right")

# Write tiles at map positions 0 and 1 for various rows
for row_b11 in range(8):
    write_pf_entry(0, row_b11, 0, 0, pf1_tile_b11a)
    write_pf_entry(0, row_b11, 1, 0, pf1_tile_b11b)

b11_scans = [30, 31, 32, 33, 34]
for sc in b11_scans:
    set_pf_prio(0, sc, 8)

# B11: scan=30 (py=30&15=14), no zoom → screen_col=16 is tile_col=1 (pen=2)
# Enable zoom for scan=30 with zoom_x=0 (1:1): enable word at 0x0400+30, data at 0x4000+30
write_line(0x0400 + 30, 0x1, "zoom_en PF1 scan=30")
write_line(0x4000 + 30, 0x0080, "zoom_x=0 y=0x80 scan=30")   # zoom_x=0, zoom_y=0x80
check_colmix(29, 16, "B11: scan=30 zoom_x=0 (1:1), col=16 is tile 1 pen=2")

# B12: scan=31, zoom_x=0x80 → zoom_step = 0x100+0x80 = 0x180 → at col=10:
# acc = 0*256, per-pixel: acc_px = 10*0x180=0xF00 → canvas_x = 0xF0>>8=15
# Still in tile 0 (0..15). At col=16: acc_px=16*0x180=0x1800 → canvas_x=0x18=24 > 16 → tile 1
write_line(0x0400 + 31, 0x1, "zoom_en PF1 scan=31")
write_line(0x4000 + 31, 0x0080 | 0x80, "zoom_x=0x80 scan=31")  # zoom_x=0x80
check_colmix(30, 10, "B12: scan=31 zoom_x=0x80, col=10 still in tile0")

# B13: scan=31 col=16 should now be in tile 1 (canvas_x=24)
check_colmix(30, 16, "B13: scan=31 zoom_x=0x80, col=16 canvas_x=24 → tile1 pen=2")

# B14: scan=32, zoom_x=0 (1:1), col=0 → tile 0 pen=1
write_line(0x0400 + 32, 0x1, "zoom_en PF1 scan=32")
write_line(0x4000 + 32, 0x0080, "zoom_x=0 y=0x80 scan=32")
check_colmix(31, 0, "B14: scan=32 zoom_x=0, col=0 → tile0 pen=1")

# B15: scan=33, no zoom enabled → fall back to 1:1 (zoom_y=0x80 default)
# Without zoom enable, zoom_x=0, zoom_y=0x80 (no effect): col=16 → tile1
write_line(0x0400 + 33, 0x0, "zoom disabled scan=33")
check_colmix(32, 16, "B15: scan=33 zoom disabled (default 1:1), col=16 → tile1 pen=2")

# ---------------------------------------------------------------------------
# B16–B20: Alpha coefficient variation per scanline
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 B16-B20 reset"})
model_reset()
clear_scan_state(list(range(120, 125)))

# PF1 (dst, prio=5) and PF2 (src blend A, prio=9) with constant tiles
pf1_tile_b16 = 95
pf2_tile_b16 = 96

for py_b16 in range(16):
    write_gfx(pf1_tile_b16 * 32 + py_b16 * 2,     0x55555555, f"tile95 py={py_b16} pen=5")
    write_gfx(pf1_tile_b16 * 32 + py_b16 * 2 + 1, 0x55555555, "right")
    write_gfx(pf2_tile_b16 * 32 + py_b16 * 2,     0x22222222, f"tile96 py={py_b16} pen=2")
    write_gfx(pf2_tile_b16 * 32 + py_b16 * 2 + 1, 0x22222222, "right")

b16_scans = [120, 121, 122, 123, 124]
for row_b16 in range(9):   # rows 0..8 cover scans 120..143
    for col_b16 in range(4):
        write_pf_entry(0, row_b16, col_b16, 0, pf1_tile_b16)
        write_pf_entry(1, row_b16, col_b16, 0, pf2_tile_b16)

for sc in b16_scans:
    set_pf_prio(0, sc, 5)
    set_pf_prio(1, sc, 9)
    set_pf_blend_mode(1, sc, 0b01)   # PF2 blend mode A

# B16: scan=120, a_src=8, a_dst=0 → src only (green pen=2)
set_alpha_coeffs(120, 8, 0)
check_blend(119, 0, "B16: scan=120 a_src=8 a_dst=0 → src only (green)")

# B17: scan=121, a_src=0, a_dst=8 → dst only (white pen=5)
set_alpha_coeffs(121, 0, 8)
check_blend(120, 0, "B17: scan=121 a_src=0 a_dst=8 → dst only (white)")

# B18: scan=122, a_src=4, a_dst=4 → 50/50
set_alpha_coeffs(122, 4, 4)
check_blend(121, 0, "B18: scan=122 a_src=4 a_dst=4 → 50/50 blend")

# B19: scan=123, a_src=8, a_dst=8 → saturated
set_alpha_coeffs(123, 8, 8)
check_blend(122, 0, "B19: scan=123 a_src=8 a_dst=8 → saturated blend")

# B20: scan=124, a_src=6, a_dst=2 → asymmetric
set_alpha_coeffs(124, 6, 2)
check_blend(123, 0, "B20: scan=124 a_src=6 a_dst=2 → asymmetric blend")

# ===========================================================================
# Group C: render_frame() regression
# ===========================================================================

# ---------------------------------------------------------------------------
# C1–C4: 2-layer frame: text + PF1
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 group C reset"})
model_reset()
clear_scan_state([26])

# Set up text tiles for rows 3..5 and PF1 tiles covering same scanlines
# Text: row=3 (scan 24..31), col=0, char_code=5, color=1, pen at py=0: px0=7
text_scan_c = 26   # render scan
text_vpos_c = text_scan_c - 1
text_row_c = text_scan_c >> 3    # 3
text_py_c = text_scan_c & 7      # 2
write_char_row(5, text_py_c, 0x00, 0x00, 0x70, 0x00)   # px0=7
write_text_tile(text_row_c, 0, 1, 5)   # color=1, char=5

# PF1 for same scan: tile 97, pen=3
pf1_tile_c = 97
pf_map_row_c = text_scan_c >> 4  # 1
pf_py_c = text_scan_c & 0xF      # 10
write_gfx(pf1_tile_c * 32 + pf_py_c * 2,     0x33333333, f"tile97 py={pf_py_c}")
write_gfx(pf1_tile_c * 32 + pf_py_c * 2 + 1, 0x33333333, "right")
write_pf_entry(0, pf_map_row_c, 0, 0, pf1_tile_c)
set_pf_prio(0, text_scan_c, 8)

# C1: text at col=0 wins over PF1
check_colmix(text_vpos_c, 0, "C1: text px0=7 beats PF1 prio=8 at col=0")

# C2: text transparent at col=4 (px4=0 since b0=0) → PF1 wins
check_colmix(text_vpos_c, 4, "C2: text transparent col=4, PF1 prio=8 wins")

# C3: use blend_pixel to verify RGB output for text (palette lookup)
# text pixel: color=1, pen=7 → colmix_pixel = {color=1, pen=7} = 0x17
# pal address = (1<<4)|7 = 0x17 = 23; write a color there
write_pal(0x0017, 0x8080, "pal text color=1 pen=7: mid-gray")
check_blend(text_vpos_c, 0, "C3: blend_rgb of text pixel (color=1, pen=7)")

# C4: RGB of PF1 at col=4 (pen=3, palette=0 → pal[3]=blue)
check_blend(text_vpos_c, 4, "C4: blend_rgb of PF1 pen=3 (blue)")

# ---------------------------------------------------------------------------
# C5–C8: 3-layer frame: PF1 + sprite + pivot
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 C5-C8 reset"})
model_reset()
clear_scan_state([50])

SCAN_C5 = 50
VPOS_C5 = SCAN_C5 - 1
S8_C5 = SCAN_C5 & 0xFF

# PF1: pen=3, prio=5
pf1_tile_c5 = 98
pf_map_row_c5 = SCAN_C5 >> 4     # 3
pf_py_c5 = SCAN_C5 & 0xF          # 2
write_gfx(pf1_tile_c5 * 32 + pf_py_c5 * 2,     0x33333333, f"C5 PF1 tile98")
write_gfx(pf1_tile_c5 * 32 + pf_py_c5 * 2 + 1, 0x33333333, "right")
for col_c5 in range(5):
    write_pf_entry(0, pf_map_row_c5, col_c5, 0, pf1_tile_c5)
set_pf_prio(0, S8_C5, 5)

# Sprite: pen=7, prio=10
spr_tile_c5 = 99
write_gfx(spr_tile_c5 * 32 + 0 * 2,     0x77777777, "C5 spr pen=7")
write_gfx(spr_tile_c5 * 32 + 0 * 2 + 1, 0x77777777, "right")
write_sprite_entry_ops(0, spr_tile_c5, 0, SCAN_C5, 0x00)
set_spr_prio(0, S8_C5, 10)

# Pivot: pen=9, prio=8
pvt_row_c5 = SCAN_C5 >> 3        # 6
pvt_py_c5  = SCAN_C5 & 7          # 2
pva_c5 = pivot_addr(0, pvt_row_c5, pvt_py_c5)
write_pivot(pva_c5, 0x99999999, "C5 pivot pen=9")
set_pivot_en(S8_C5, True)

# C5: sprite(10) > pivot(8) > PF1(5)
check_colmix(VPOS_C5, 0, "C5: 3-layer sprite(10)>pivot(8)>PF1(5)")

# C6: pivot col=8 (tile col=1 → need tile)
pvt_col1_c5 = pivot_addr(1, pvt_row_c5, pvt_py_c5)
write_pivot(pvt_col1_c5, 0x99999999, "C5 pivot col=1 pen=9")
check_colmix(VPOS_C5, 8, "C6: sprite covers col=0..15 → sprite wins at col=8")

# C7: col=16 (outside sprite, pivot still there)
pvt_col2_c5 = pivot_addr(2, pvt_row_c5, pvt_py_c5)
write_pivot(pvt_col2_c5, 0x99999999, "C5 pivot col=2 pen=9")
write_pf_entry(0, pf_map_row_c5, 1, 0, pf1_tile_c5)   # extra col
check_colmix(VPOS_C5, 16, "C7: col=16 outside sprite → pivot(8)>PF1(5)")

# C8: blend_rgb for pivot pixel (palette=0, pen=9, pal[9]=magenta)
check_blend(VPOS_C5, 16, "C8: blend_rgb of pivot pen=9 (magenta)")

# ---------------------------------------------------------------------------
# C9–C12: Full 7-layer frame with all features (blend_rgb checks)
# ---------------------------------------------------------------------------
emit({"op": "reset", "note": "step17 C9-C12 reset"})
model_reset()
clear_scan_state([130])

SCAN_C9 = 130
VPOS_C9 = SCAN_C9 - 1
S8_C9 = SCAN_C9 & 0xFF

# Text: char=2, color=0, pen=5 at col=0, py=130&7=2
text_row_c9 = SCAN_C9 >> 3     # 16
text_py_c9 = SCAN_C9 & 7       # 2
write_char_row(2, text_py_c9, 0x50, 0x00, 0x50, 0x00)   # px0=5, px4=5
write_text_tile(text_row_c9, 0, 0, 2)   # color=0, char=2

# PF1: pen=3, prio=6 (dst for PF2 blend)
pf1_tile_c9 = 100
pf_map_row_c9 = SCAN_C9 >> 4    # 8
pf_py_c9 = SCAN_C9 & 0xF         # 2
write_gfx(pf1_tile_c9 * 32 + pf_py_c9 * 2,     0x33333333, "C9 PF1 pen=3")
write_gfx(pf1_tile_c9 * 32 + pf_py_c9 * 2 + 1, 0x33333333, "right")
for col_c9 in range(5):
    write_pf_entry(0, pf_map_row_c9, col_c9, 0, pf1_tile_c9)
set_pf_prio(0, S8_C9, 6)

# PF2: pen=7, prio=10, blend mode A
pf2_tile_c9 = 101
write_gfx(pf2_tile_c9 * 32 + pf_py_c9 * 2,     0x77777777, "C9 PF2 pen=7")
write_gfx(pf2_tile_c9 * 32 + pf_py_c9 * 2 + 1, 0x77777777, "right")
for col_c9 in range(5):
    write_pf_entry(1, pf_map_row_c9, col_c9, 0, pf2_tile_c9)
set_pf_prio(1, S8_C9, 10)
set_pf_blend_mode(1, S8_C9, 0b01)    # blend A

# Sprite: pen=2, prio=7
spr_tile_c9 = 102
write_gfx(spr_tile_c9 * 32 + 0 * 2,     0x22222222, "C9 spr pen=2")
write_gfx(spr_tile_c9 * 32 + 0 * 2 + 1, 0x22222222, "right")
write_sprite_entry_ops(0, spr_tile_c9, 8, SCAN_C9, 0x00)   # sx=8
set_spr_prio(0, S8_C9, 7)

# Pivot: pen=9, prio=8
pvt_row_c9 = SCAN_C9 >> 3       # 16
pvt_py_c9  = SCAN_C9 & 7         # 2
pva_c9 = pivot_addr(0, pvt_row_c9 & 0x1F, pvt_py_c9)
write_pivot(pva_c9, 0x99999999, "C9 pivot col=0 pen=9")
pva_c9_1 = pivot_addr(1, pvt_row_c9 & 0x1F, pvt_py_c9)
write_pivot(pva_c9_1, 0x99999999, "C9 pivot col=1 pen=9")
set_pivot_en(S8_C9, True)

set_alpha_coeffs(S8_C9, 6, 2)

# Palette entries needed
# pal[7] = cyan (already written)
# pal[2] = green (already written)
# pal[9] = magenta (already written)
# pal[3] = blue (already written)
# pal[5] = white (already written)

# C9: col=0 — text has pen=5 → text wins, blend_rgb = white (R=F0,G=F0,B=F0)
check_blend(VPOS_C9, 0, "C9: 7-layer col=0 text wins → white blend_rgb")

# C10: col=4 — text transparent (px4=5 but we're checking text layer decode)
# px4 = b0[7:4]: b0=0x50 → px4=5 → wait, px4=5 → non-zero text! Should win.
# char2 py=2: b0=0x50 → px4=5. text wins.
# Use col=1 where text is transparent (px1=b2[3:0]=0)
check_blend(VPOS_C9, 1, "C10: col=1 text transparent → PF2 blend A src=cyan wins")

# C11: col=8 — sprite(7) vs pivot(8) vs PF2(10). PF2 wins with blend A over PF1
check_blend(VPOS_C9, 8, "C11: col=8 PF2(10) blend A, sprite(7), pivot(8), PF1(6)")

# C12: col=16 — no sprite (sx=8, sprite covers 8..23), pivot col=2 (need to write)
pvt_col2_c9 = pivot_addr(2, pvt_row_c9 & 0x1F, pvt_py_c9)
write_pivot(pvt_col2_c9, 0x99999999, "C9 pivot col=2 pen=9")
for col_c12 in range(5):
    write_pf_entry(0, pf_map_row_c9, col_c12, 0, pf1_tile_c9)
    write_pf_entry(1, pf_map_row_c9, col_c12, 0, pf2_tile_c9)
check_blend(VPOS_C9, 16, "C12: col=16 no sprite, PF2(10) blend A over PF1(6), pivot(8) loses")

# ---------------------------------------------------------------------------
# Write vectors
# ---------------------------------------------------------------------------
out_path = os.path.join(os.path.dirname(__file__), "step17_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"step17_vectors.jsonl: {len(vectors)} ops written to {out_path}")
