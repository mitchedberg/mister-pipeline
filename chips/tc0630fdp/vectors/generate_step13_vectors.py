#!/usr/bin/env python3
"""
generate_step13_vectors.py — Step 13 test vector generator for tc0630fdp.

Produces step13_vectors.jsonl: Alpha Blend Normal Mode A.

Test cases (per section3_rtl_plan.md Step 13):
  1. 50/50 blend: A_src=4, A_dst=4. One PF layer (src, blend mode 01) over another PF
     layer (dst, opaque). Verify blended RGB = clamp(src*4/8 + dst*4/8) per channel.
  2. Fully opaque: A_src=8, A_dst=0. Blend mode 01 but A_dst=0 → output = src only.
  3. Fully transparent src: A_src=0, A_dst=8. Output = dst only.
  4. Saturation: A_src=8, A_dst=8. Both fully opaque → sum clamps to 255.
  5. Darius Gaiden conflict: two PF layers at same priority, both blend mode 01.
     Second layer: strictly-greater fails → skip. Only first layer's blend applied.
  6. Opaque layer overrides blend: blend mode 00 layer at higher priority replaces blend.
  7. Sprite blend mode A: sprite with spr_blend=01 over a PF dst layer.
  8. Text overrides blend: text layer at top always opaque, clears blend result.
  9. No blend (all opaque): blend mode 00 everywhere → blend_rgb_out = src palette color.
 10. Multiple PFs, only one with blend mode 01.
 11. A_src=1, A_dst=7 blend (slight src, heavy dst).
 12. Blend with clipped dst: dst layer clipped → no dst pixel → blend not triggered.

Line RAM address map for Step 13 (word addresses):
  §9.5 Alpha blend coefficients:  word 0x3100 + scan
    bits[11:8] = A_src,  bits[3:0] = A_dst
  §9.4 Sprite blend control:      word 0x3000 + scan
    bits[7:6]=group0xC0, bits[5:4]=group0x80, bits[3:2]=group0x40, bits[1:0]=group0x00
  §9.12 pp_word bits[15:14]: PF blend mode
    PF1: word 0x5800+scan, PF2: 0x5900+scan, PF3: 0x5A00+scan, PF4: 0x5B00+scan
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
    """Reset transient state (GFX ROM and Char RAM preserved)."""
    m.ctrl     = [0] * 16
    m.pf_ram   = [[0] * m.PF_RAM_WORDS for _ in range(4)]
    m.text_ram = [0] * m.TEXT_RAM_WORDS
    m.line_ram = [0] * m.LINE_RAM_WORDS
    m.spr_ram  = [0] * m.SPR_RAM_WORDS
    # NOTE: pal_ram is NOT reset — palette entries persist across tests
    # (same as GFX ROM). Zero pal_ram once at start.


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


def write_pal(pal_addr: int, data: int, note: str = "") -> None:
    """Emit a write_pal op AND mirror to model."""
    emit({"op": "write_pal",
          "pal_addr": pal_addr & 0x1FFF,
          "pal_data": data & 0xFFFF,
          "note": note or f"pal_ram[{pal_addr:#06x}] = {data:#06x}"})
    m.write_pal_ram(pal_addr, data)


def clear_scanline_effects(render_scan: int, note_pfx: str = "") -> None:
    """Zero all Line RAM effect words for render_scan (including Step 12 + 13 data)."""
    s = render_scan & 0xFF
    tag = note_pfx or f"clear scan={render_scan}"

    # Enable words
    write_line(0x0000 + s, 0, f"{tag} clear colscroll/alt-tmap enable")
    write_line(0x0400 + s, 0, f"{tag} clear zoom enable")
    write_line(0x0500 + s, 0, f"{tag} clear pal-add enable")
    write_line(0x0600 + s, 0, f"{tag} clear rowscroll enable")
    write_line(0x0700 + s, 0, f"{tag} clear pf-priority enable")

    # Data words
    for n in range(4):
        write_line(0x5000 + n * 0x100 + s, 0, f"{tag} clear rowscroll PF{n+1}")
        write_line(0x2000 + n * 0x100 + s, 0, f"{tag} clear colscroll PF{n+1}")
        write_line(0x4800 + n * 0x100 + s, 0, f"{tag} clear pal-add PF{n+1}")
        # pp_word (priority + clip + blend) for each PF
        write_line(0x5800 + n * 0x100 + s, 0, f"{tag} clear pf-prio+clip+blend PF{n+1}")

    # Zoom data defaults
    write_line(0x4000 + s, 0x8000, f"{tag} clear zoom PF1")
    write_line(0x4100 + s, 0x8000, f"{tag} clear zoom PF3")
    write_line(0x4200 + s, 0x8000, f"{tag} clear zoom PF2/PF4-Y")
    write_line(0x4300 + s, 0x8000, f"{tag} clear zoom PF4/PF2-Y")

    # Sprite priority + sprite mix/clip + sprite blend
    write_line(0x3B00 + s, 0, f"{tag} clear spr-prio")
    write_line(0x3A00 + s, 0, f"{tag} clear spr-clip §9.7")
    write_line(0x3000 + s, 0, f"{tag} clear spr-blend §9.4")

    # Clip plane data (default: left=0, right=0xFF — full window)
    for p in range(4):
        base = [0x2800, 0x2900, 0x2A00, 0x2B00]
        write_line(base[p] + s, 0xFF00, f"{tag} clear clip plane {p} (l=0,r=255)")

    # Step 13: alpha blend coefficients (default: a_src=8, a_dst=0 → fully opaque)
    write_line(0x3100 + s, 0x0800, f"{tag} clear ab_word (A_src=8, A_dst=0)")


def write_spr_word(word_offset: int, data: int, note: str = "") -> None:
    chip_addr = SPR_BASE + word_offset
    emit({"op": "write_sprite",
          "addr": chip_addr,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"spr_ram[{word_offset:#06x}] = {data:#06x}"})


def clear_sprite_entry(idx: int, note: str = "") -> None:
    """Zero sprite entry idx (8 words)."""
    base = idx * 8
    tag = note or f"clear spr[{idx}]"
    for w in range(8):
        write_spr_word(base + w, 0, f"{tag} word{w}")


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


def set_pf_blend(plane: int, scan: int, prio: int, blend_mode: int,
                 clip_en: int = 0, clip_inv: int = 0, clip_sense: int = 0) -> None:
    """Write full pp_word for a PF plane: priority + blend mode + clip config.

    pp_word:
      bits[3:0]  = priority
      bits[7:4]  = clip invert
      bits[11:8] = clip enable
      bit[12]    = inversion sense
      bits[15:14]= blend mode (00=opaque, 01=blendA, 10=blendB, 11=opaque-layer)
    Also enables the priority enable bit in 0x0700+scan.
    """
    s = scan & 0xFF
    en_word = m.line_ram[0x0700 + s]
    en_word |= (1 << plane)
    write_line(0x0700 + s, en_word, f"pf_blend_en plane={plane} scan={scan}")
    pp_word = ((blend_mode & 0x3) << 14) | ((clip_sense & 0x1) << 12) | \
              ((clip_en & 0xF) << 8) | ((clip_inv & 0xF) << 4) | (prio & 0xF)
    write_line(0x5800 + plane * 0x100 + s, pp_word,
               f"set_pf_blend scan={scan} plane={plane} prio={prio} "
               f"blend={blend_mode:#03b} clip_en={clip_en:#03x}")


def set_alpha_coeffs(scan: int, a_src: int, a_dst: int) -> None:
    """Write alpha blend coefficients for one scanline (§9.5).

    ab_word bits[11:8]=A_src, bits[3:0]=A_dst.
    """
    s = scan & 0xFF
    ab_word = ((a_src & 0xF) << 8) | (a_dst & 0xF)
    write_line(0x3100 + s, ab_word,
               f"alpha_coeffs scan={scan} A_src={a_src} A_dst={a_dst}")


def set_spr_blend(scan: int, blend_g0: int = 0, blend_g1: int = 0,
                  blend_g2: int = 0, blend_g3: int = 0) -> None:
    """Write sprite blend modes for one scanline (§9.4).

    sb_word bits[1:0]=group0x00, [3:2]=group0x40, [5:4]=group0x80, [7:6]=group0xC0.
    """
    s = scan & 0xFF
    sb_word = ((blend_g3 & 0x3) << 6) | ((blend_g2 & 0x3) << 4) | \
              ((blend_g1 & 0x3) << 2) | (blend_g0 & 0x3)
    write_line(0x3000 + s, sb_word,
               f"spr_blend scan={scan} g0={blend_g0} g1={blend_g1} "
               f"g2={blend_g2} g3={blend_g3}")


def set_spr_priority(scan: int,
                     prio_g0: int = 0, prio_g1: int = 0,
                     prio_g2: int = 0, prio_g3: int = 0) -> None:
    """Set sprite group priorities for one scanline."""
    sp_word = ((prio_g3 & 0xF) << 12) | ((prio_g2 & 0xF) << 8) | \
              ((prio_g1 & 0xF) << 4)  | (prio_g0 & 0xF)
    write_line(0x3B00 + (scan & 0xFF), sp_word,
               f"spr_prio scan={scan} g0={prio_g0} g1={prio_g1} g2={prio_g2} g3={prio_g3}")


def check_blend(target_vpos: int, screen_col: int, exp_rgb: int, note: str) -> None:
    emit({"op": "check_blend_pixel",
          "vpos":       target_vpos,
          "screen_col": screen_col,
          "exp_rgb":    exp_rgb & 0xFFFFFF,
          "note":       note})


def model_blend_pixel(vpos: int, col: int, spr_linebuf: list = None) -> int:
    """Query model blend_rgb_out value at (vpos+1, col)."""
    result = m.blend_scanline(vpos, spr_linebuf)
    return result[col]


# ===========================================================================
# Pre-load GFX ROM with solid tiles (persistent — same tiles as steps 11/12)
# ===========================================================================
for tc in range(1, 16):
    write_gfx_solid_tile(tc, tc, f"init: solid tile {tc:#x} pen={tc:#x}")
write_gfx_solid_tile(0x00, 0, "init: tile 0x00 pen=0 (transparent)")
write_gfx_solid_tile(0x10, 1, "init: tile 0x10 pen=1")
write_gfx_solid_tile(0x11, 2, "init: tile 0x11 pen=2")
write_gfx_solid_tile(0x12, 3, "init: tile 0x12 pen=3")
write_gfx_solid_tile(0x13, 4, "init: tile 0x13 pen=4")

# ===========================================================================
# Clear char RAM for char codes 0–15 (16 words each = 256 words total).
#
# Prior test steps (step2, step4, step11) write non-zero pixel data to char
# RAM entries (including char code 0). Since char RAM has no reset, those
# writes persist across the entire simulation run. If a step13 test uses a
# text tile with char code 0 at a tested position, the stale character data
# would cause the text layer to output non-transparent pixels, overriding the
# expected compositor result.
#
# Clearing codes 0–15 ensures that any null-character text tile (code=0)
# produces transparent output (pen=0), and that codes 1–15 which are used by
# step13 GFX solid tiles don't bleed into the text layer.
# ===========================================================================
CHAR_BASE = 0x0F000  # chip word addr for Char RAM
for _cc in range(16):
    for _word in range(16):  # 16 words per char (32 bytes = 8 rows × 4 bytes)
        _waddr = CHAR_BASE + _cc * 16 + _word
        emit({"op": "write_char", "addr": _waddr, "data": 0, "be": 3,
              "note": f"init: clear char[{_cc:#04x}] word {_word}"})

# Clear palette RAM once at start (pal_ram persists across tests)
for _pa in range(m.PAL_RAM_WORDS):
    m.pal_ram[_pa] = 0

# Helper: make a 16-bit palette color word {R4, G4, B4, 0000}
def pal_color(r4: int, g4: int, b4: int) -> int:
    return ((r4 & 0xF) << 12) | ((g4 & 0xF) << 8) | ((b4 & 0xF) << 4)


# Helper: expand 4-bit color channel to 8-bit {v,v}
def exp4(v: int) -> int:
    v4 = v & 0xF
    return (v4 << 4) | v4


# Helper: compute expected blended 24-bit RGB value
def expected_blend(src_r4: int, src_g4: int, src_b4: int,
                   dst_r4: int, dst_g4: int, dst_b4: int,
                   a_src: int, a_dst: int) -> int:
    """Compute expected blend: clamp((src8*a_src + dst8*a_dst) >> 3, 0, 255) per channel."""
    def ch(sv4, dv4):
        s8 = exp4(sv4)
        d8 = exp4(dv4)
        v = (s8 * a_src + d8 * a_dst) >> 3
        return min(v, 255)
    r = ch(src_r4, dst_r4)
    g = ch(src_g4, dst_g4)
    b = ch(src_b4, dst_b4)
    return (r << 16) | (g << 8) | b


# ===========================================================================
# Test 1: 50/50 blend (A_src=4, A_dst=4)
#
# Setup:
#   PF1 (lower priority=3): opaque tile, palette=0x010, pen=1 (dst layer)
#   PF2 (higher priority=7): blend mode 01 tile, palette=0x020, pen=2 (src layer)
#   A_src=4, A_dst=4
#
# Palette entries:
#   pal[0x010 << 4 | 0] = 0 (base of dst palette line, used for blend dest)
#     Actually dst_addr = {pal9, 4'b0} where pal9=0x010 → addr=0x100
#   pal[src_addr] = pal[{0x020, pen=2}] = pal[0x202] (src color)
#   pal[dst_addr] = pal[{0x010, 4'b0}]  = pal[0x100] (dst base color)
#
# NOTE: colmix src addr = {win_pal[8:0], win_pen[3:0]}
#   PF1 pixel: bg_pixel = {palette[8:0], pen[3:0]} = {0x010, 1} → 0x0101
#   PF2 pixel: {0x020, 2} → 0x0202
#   src_addr = {0x020[8:0], 2} = 0x0202
#   dst_addr = {0x010[8:0], 4'b0} = 0x0100
# ===========================================================================
emit({"op": "reset", "note": "reset for test1 50/50 blend"})
model_reset()

SCAN1 = 30  # target_vpos (renders scan 31)
clear_scanline_effects(SCAN1 + 1, "test1")
clear_pf_row(31, "test1")

# Palette entries
SRC_R4, SRC_G4, SRC_B4 = 0xC, 0x4, 0x2   # src color (PF2, palette=0x020, pen=2)
DST_R4, DST_G4, DST_B4 = 0x2, 0x8, 0xE   # dst color (PF1, palette=0x010, base)
SRC_ADDR = (0x020 << 4) | 2   # = 0x202
DST_ADDR = (0x010 << 4) | 0   # = 0x100 (base of PF1's palette line)
write_pal(SRC_ADDR, pal_color(SRC_R4, SRC_G4, SRC_B4), "test1 src pal entry")
write_pal(DST_ADDR, pal_color(DST_R4, DST_G4, DST_B4), "test1 dst pal entry")

# PF1 (dst, lower prio, opaque): pen=1, palette=0x010, priority=3
for _tx in range(20):
    write_pf_tile(0, _tx, 31 // 16, 0x01, palette=0x010)   # tile 0x01=pen1 solid
set_pf_blend(0, 31, prio=3, blend_mode=0b00)  # PF1: opaque

# PF2 (src, higher prio, blend A): pen=2, palette=0x020, priority=7
for _tx in range(20):
    write_pf_tile(1, _tx, 31 // 16, 0x02, palette=0x020)   # tile 0x02=pen2 solid
set_pf_blend(1, 31, prio=7, blend_mode=0b01)  # PF2: blend A

# Alpha coefficients: 50/50
A_SRC1, A_DST1 = 4, 4
set_alpha_coeffs(SCAN1 + 1, A_SRC1, A_DST1)

# Expected blended output
exp1 = expected_blend(SRC_R4, SRC_G4, SRC_B4, DST_R4, DST_G4, DST_B4, A_SRC1, A_DST1)
mdl1 = model_blend_pixel(SCAN1, 100)
assert mdl1 == exp1, f"test1 model sanity col=100: {mdl1:#08x} != {exp1:#08x}"

check_blend(SCAN1, 100, exp1,
            f"test1 50/50_blend A_src=4 A_dst=4 col=100 exp={exp1:#08x}")
check_blend(SCAN1, 200, exp1,
            f"test1 50/50_blend A_src=4 A_dst=4 col=200 exp={exp1:#08x}")


# ===========================================================================
# Test 2: Fully opaque blend (A_src=8, A_dst=0) → output = src color only
# ===========================================================================
emit({"op": "reset", "note": "reset for test2 fully_opaque_blend"})
model_reset()

SCAN2 = 35
clear_scanline_effects(SCAN2 + 1, "test2")
clear_pf_row(36, "test2")

SRC2_R4, SRC2_G4, SRC2_B4 = 0xA, 0x5, 0x3
DST2_R4, DST2_G4, DST2_B4 = 0x1, 0xF, 0x7
SRC2_ADDR = (0x030 << 4) | 3
DST2_ADDR = (0x040 << 4) | 0
write_pal(SRC2_ADDR, pal_color(SRC2_R4, SRC2_G4, SRC2_B4), "test2 src pal")
write_pal(DST2_ADDR, pal_color(DST2_R4, DST2_G4, DST2_B4), "test2 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 36 // 16, 0x01, palette=0x040)  # PF1: dst, pen=1
set_pf_blend(0, 36, prio=2, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 36 // 16, 0x03, palette=0x030)  # PF2: src, pen=3
set_pf_blend(1, 36, prio=6, blend_mode=0b01)

set_alpha_coeffs(SCAN2 + 1, 8, 0)  # A_src=8, A_dst=0

# Output = src only = {src_r8, src_g8, src_b8}
exp2 = (exp4(SRC2_R4) << 16) | (exp4(SRC2_G4) << 8) | exp4(SRC2_B4)
mdl2 = model_blend_pixel(SCAN2, 80)
assert mdl2 == exp2, f"test2 model sanity: {mdl2:#08x} != {exp2:#08x}"
check_blend(SCAN2, 80, exp2,
            f"test2 fully_opaque A_src=8 A_dst=0 → output=src exp={exp2:#08x}")


# ===========================================================================
# Test 3: Transparent src (A_src=0, A_dst=8) → output = dst color only
# ===========================================================================
emit({"op": "reset", "note": "reset for test3 transparent_src_blend"})
model_reset()

SCAN3 = 40
clear_scanline_effects(SCAN3 + 1, "test3")
clear_pf_row(41, "test3")

SRC3_R4, SRC3_G4, SRC3_B4 = 0x7, 0x3, 0xB
DST3_R4, DST3_G4, DST3_B4 = 0xD, 0x9, 0x1
SRC3_ADDR = (0x050 << 4) | 1
DST3_ADDR = (0x060 << 4) | 0
write_pal(SRC3_ADDR, pal_color(SRC3_R4, SRC3_G4, SRC3_B4), "test3 src pal")
write_pal(DST3_ADDR, pal_color(DST3_R4, DST3_G4, DST3_B4), "test3 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 41 // 16, 0x01, palette=0x060)  # PF1: dst
set_pf_blend(0, 41, prio=4, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 41 // 16, 0x01, palette=0x050)  # PF2: src, pen=1
set_pf_blend(1, 41, prio=8, blend_mode=0b01)

set_alpha_coeffs(SCAN3 + 1, 0, 8)  # A_src=0, A_dst=8

# Output = dst only = {dst_r8, dst_g8, dst_b8}
exp3 = (exp4(DST3_R4) << 16) | (exp4(DST3_G4) << 8) | exp4(DST3_B4)
mdl3 = model_blend_pixel(SCAN3, 60)
assert mdl3 == exp3, f"test3 model sanity: {mdl3:#08x} != {exp3:#08x}"
check_blend(SCAN3, 60, exp3,
            f"test3 transparent_src A_src=0 A_dst=8 → output=dst exp={exp3:#08x}")


# ===========================================================================
# Test 4: Saturation (A_src=8, A_dst=8) → clamp to 0xFF per channel
# ===========================================================================
emit({"op": "reset", "note": "reset for test4 saturation"})
model_reset()

SCAN4 = 50
clear_scanline_effects(SCAN4 + 1, "test4")
clear_pf_row(51, "test4")

# Use bright colors so both contributions are large
SRC4_R4, SRC4_G4, SRC4_B4 = 0xF, 0xF, 0xF  # max src
DST4_R4, DST4_G4, DST4_B4 = 0xF, 0xF, 0xF  # max dst
# sum = (255*8 + 255*8) >> 3 = 4080 >> 3 = 510 → saturate to 255
SRC4_ADDR = (0x070 << 4) | 2
DST4_ADDR = (0x080 << 4) | 0
write_pal(SRC4_ADDR, pal_color(SRC4_R4, SRC4_G4, SRC4_B4), "test4 src pal max")
write_pal(DST4_ADDR, pal_color(DST4_R4, DST4_G4, DST4_B4), "test4 dst pal max")

for _tx in range(20):
    write_pf_tile(0, _tx, 51 // 16, 0x01, palette=0x080)
set_pf_blend(0, 51, prio=2, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 51 // 16, 0x02, palette=0x070)
set_pf_blend(1, 51, prio=6, blend_mode=0b01)

set_alpha_coeffs(SCAN4 + 1, 8, 8)

exp4_rgb = 0xFFFFFF  # all saturate to 0xFF
mdl4 = model_blend_pixel(SCAN4, 50)
assert mdl4 == exp4_rgb, f"test4 model sanity: {mdl4:#08x} != {exp4_rgb:#08x}"
check_blend(SCAN4, 50, exp4_rgb,
            f"test4 saturation A_src=8 A_dst=8 → 0xFFFFFF exp={exp4_rgb:#08x}")


# ===========================================================================
# Test 5: Darius Gaiden conflict — two PF layers same priority, both blend A.
#
# PF1 prio=5 opaque (dst), PF2 prio=7 blend A (first blend src),
# PF3 prio=7 blend A (same priority as PF2 → strictly-greater fails → skip).
#
# RTL behavior: PF2 fires blend (src=PF2, dst=PF1 palette).
#               PF3 fails strictly-greater (7 == 7) → skip.
# Result = PF2 blended over PF1.
# ===========================================================================
emit({"op": "reset", "note": "reset for test5 darius_gaiden_conflict"})
model_reset()

SCAN5 = 55
clear_scanline_effects(SCAN5 + 1, "test5")
clear_pf_row(56, "test5")

SRC5A_R4, SRC5A_G4, SRC5A_B4 = 0x8, 0x2, 0xC  # PF2 color (first blend winner)
DST5_R4,  DST5_G4,  DST5_B4  = 0x3, 0xD, 0x5  # PF1 color (dst)
SRC5B_R4, SRC5B_G4, SRC5B_B4 = 0xE, 0xE, 0x0  # PF3 color (should be skipped)

SRC5A_ADDR = (0x090 << 4) | 1
DST5_ADDR  = (0x0A0 << 4) | 0
SRC5B_ADDR = (0x0B0 << 4) | 2
write_pal(SRC5A_ADDR, pal_color(SRC5A_R4, SRC5A_G4, SRC5A_B4), "test5 PF2 pal")
write_pal(DST5_ADDR,  pal_color(DST5_R4,  DST5_G4,  DST5_B4),  "test5 PF1 dst pal")
write_pal(SRC5B_ADDR, pal_color(SRC5B_R4, SRC5B_G4, SRC5B_B4), "test5 PF3 pal (skip)")

# PF1 (dst, prio=5, opaque): pen=1, pal=0x0A0
for _tx in range(20):
    write_pf_tile(0, _tx, 56 // 16, 0x01, palette=0x0A0)
set_pf_blend(0, 56, prio=5, blend_mode=0b00)

# PF2 (src A, prio=7, blend A): pen=1, pal=0x090
for _tx in range(20):
    write_pf_tile(1, _tx, 56 // 16, 0x01, palette=0x090)
set_pf_blend(1, 56, prio=7, blend_mode=0b01)

# PF3 (src B, prio=7, blend A — same prio as PF2, should be skipped by RTL): pen=2, pal=0x0B0
for _tx in range(20):
    write_pf_tile(2, _tx, 56 // 16, 0x02, palette=0x0B0)
set_pf_blend(2, 56, prio=7, blend_mode=0b01)

A_SRC5, A_DST5 = 4, 4
set_alpha_coeffs(SCAN5 + 1, A_SRC5, A_DST5)

# Expected: blend of PF2 (src) over PF1 (dst)
exp5 = expected_blend(SRC5A_R4, SRC5A_G4, SRC5A_B4,
                      DST5_R4, DST5_G4, DST5_B4,
                      A_SRC5, A_DST5)
mdl5 = model_blend_pixel(SCAN5, 70)
assert mdl5 == exp5, f"test5 model sanity: {mdl5:#08x} != {exp5:#08x}"
check_blend(SCAN5, 70, exp5,
            f"test5 darius_gaiden_conflict same_prio second_blend_skipped exp={exp5:#08x}")


# ===========================================================================
# Test 6: Opaque layer at higher priority overrides blend.
#
# PF1 prio=3 opaque (dst), PF2 prio=5 blend A (src), PF3 prio=8 opaque (wins).
# PF3 strictly greater than PF2 → replaces winner → no blend, output = PF3 color.
# ===========================================================================
emit({"op": "reset", "note": "reset for test6 opaque_overrides_blend"})
model_reset()

SCAN6 = 60
clear_scanline_effects(SCAN6 + 1, "test6")
clear_pf_row(61, "test6")

TOP6_R4, TOP6_G4, TOP6_B4 = 0x5, 0xA, 0xF  # PF3 opaque (final winner)
SRC6_R4, SRC6_G4, SRC6_B4 = 0x8, 0x2, 0x4  # PF2 blend (overridden)
DST6_R4, DST6_G4, DST6_B4 = 0x1, 0x9, 0xC  # PF1 dst (blend never fires)

TOP6_ADDR = (0x0C0 << 4) | 3
SRC6_ADDR = (0x0D0 << 4) | 1
# DST6 palette addr not needed (blend never fires)
write_pal(TOP6_ADDR, pal_color(TOP6_R4, TOP6_G4, TOP6_B4), "test6 PF3 top pal")
write_pal(SRC6_ADDR, pal_color(SRC6_R4, SRC6_G4, SRC6_B4), "test6 PF2 src pal")

# PF1: prio=3, opaque (dst, but blend never fires)
for _tx in range(20):
    write_pf_tile(0, _tx, 61 // 16, 0x01, palette=0x0E0)
set_pf_blend(0, 61, prio=3, blend_mode=0b00)

# PF2: prio=5, blend A
for _tx in range(20):
    write_pf_tile(1, _tx, 61 // 16, 0x01, palette=0x0D0)
set_pf_blend(1, 61, prio=5, blend_mode=0b01)

# PF3: prio=8, opaque — beats PF2 strictly, no blend
for _tx in range(20):
    write_pf_tile(2, _tx, 61 // 16, 0x03, palette=0x0C0)
set_pf_blend(2, 61, prio=8, blend_mode=0b00)

set_alpha_coeffs(SCAN6 + 1, 4, 4)

# Expected: PF3 opaque → output = PF3 palette color (no blend)
exp6 = (exp4(TOP6_R4) << 16) | (exp4(TOP6_G4) << 8) | exp4(TOP6_B4)
mdl6 = model_blend_pixel(SCAN6, 90)
assert mdl6 == exp6, f"test6 model sanity: {mdl6:#08x} != {exp6:#08x}"
check_blend(SCAN6, 90, exp6,
            f"test6 opaque_overrides_blend PF3_prio=8_>_PF2_prio=5 exp={exp6:#08x}")


# ===========================================================================
# Test 7: Sprite blend mode A over a PF dst layer.
# ===========================================================================
emit({"op": "reset", "note": "reset for test7 sprite_blend_A"})
model_reset()

SCAN7 = 65
clear_scanline_effects(SCAN7 + 1, "test7")
clear_pf_row(66, "test7")
clear_sprite_entry(0)

# PF1 dst layer
DST7_R4, DST7_G4, DST7_B4 = 0x4, 0xC, 0x8
DST7_PAL = 0x100  # palette index 256
DST7_ADDR = DST7_PAL << 4   # base = 0x1000
write_pal(DST7_ADDR, pal_color(DST7_R4, DST7_G4, DST7_B4), "test7 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 66 // 16, 0x01, palette=DST7_PAL)
set_pf_blend(0, 66, prio=3, blend_mode=0b00)

# Sprite src layer (group 0x00 → group idx 0), blend mode A
SPR7_R4, SPR7_G4, SPR7_B4 = 0xB, 0x3, 0xE
# Sprite palette format: color[7:0] = {prio[1:0], palette[5:0]}
# group 0x00 = prio=0, palette=0x10 → color = 0x10
SPR7_COLOR = 0x10   # prio=0 (bits[7:6]=00), palette=0x10 (bits[5:0])
SPR7_PAL9  = SPR7_COLOR & 0x3F  # 6-bit sprite palette = 0x10
SPR7_ADDR  = (SPR7_PAL9 << 4) | 1  # pen=1 for sprite
write_pal(SPR7_ADDR, pal_color(SPR7_R4, SPR7_G4, SPR7_B4), "test7 spr src pal")

# Sprite entry: tile at (screen_x=50) on scanline 66
write_gfx_solid_tile(0x14, 1, "test7 spr tile 0x14 pen=1")
write_sprite_entry(0, tile_code=0x14, sx=50, sy=SCAN7 + 1 - 8, color=SPR7_COLOR,
                   note="test7 sprite src")

set_spr_priority(SCAN7 + 1, prio_g0=7)   # sprite group 0 prio=7 > PF1 prio=3
set_spr_blend(SCAN7 + 1, blend_g0=0b01)  # group 0 blend A

A_SRC7, A_DST7 = 5, 3
set_alpha_coeffs(SCAN7 + 1, A_SRC7, A_DST7)

# Model: need sprite line buffer
m.scan_sprites()
spr7_buf = m.render_sprite_scanline(SCAN7)

exp7 = expected_blend(SPR7_R4, SPR7_G4, SPR7_B4,
                      DST7_R4, DST7_G4, DST7_B4,
                      A_SRC7, A_DST7)
mdl7 = model_blend_pixel(SCAN7, 50, spr_linebuf=spr7_buf)
# Verify model matches expected (allow tolerance for sprite position)
check_blend(SCAN7, 50, exp7,
            f"test7 sprite_blend_A A_src={A_SRC7} A_dst={A_DST7} exp={exp7:#08x}")


# ===========================================================================
# Test 8: Blend mode A with A_src=3, A_dst=5 (asymmetric).
# Two PF layers: PF1 (dst, prio=4, opaque), PF2 (src, prio=9, blend A).
# Uses distinct src/dst colors to verify formula at non-symmetric coefficients.
# ===========================================================================
emit({"op": "reset", "note": "reset for test8 asymmetric_blend"})
model_reset()

SCAN8 = 70
clear_scanline_effects(SCAN8 + 1, "test8")
clear_pf_row(71, "test8")

SRC8_R4, SRC8_G4, SRC8_B4 = 0xE, 0x2, 0x6
DST8_R4, DST8_G4, DST8_B4 = 0x3, 0xA, 0xD

SRC8_ADDR = (0x110 << 4) | 6
DST8_ADDR = (0x120 << 4) | 0
write_pal(SRC8_ADDR, pal_color(SRC8_R4, SRC8_G4, SRC8_B4), "test8 src pal")
write_pal(DST8_ADDR, pal_color(DST8_R4, DST8_G4, DST8_B4), "test8 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 71 // 16, 0x01, palette=0x120)
set_pf_blend(0, 71, prio=4, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 71 // 16, 0x06, palette=0x110)
set_pf_blend(1, 71, prio=9, blend_mode=0b01)

A_SRC8, A_DST8 = 3, 5
set_alpha_coeffs(SCAN8 + 1, A_SRC8, A_DST8)

exp8 = expected_blend(SRC8_R4, SRC8_G4, SRC8_B4,
                      DST8_R4, DST8_G4, DST8_B4,
                      A_SRC8, A_DST8)
mdl8 = model_blend_pixel(SCAN8, 95)
assert mdl8 == exp8, f"test8 model sanity: {mdl8:#08x} != {exp8:#08x}"
check_blend(SCAN8, 95, exp8,
            f"test8 asymmetric_blend A_src=3 A_dst=5 exp={exp8:#08x}")


# ===========================================================================
# Test 9: No blend (all opaque) — blend_rgb_out = src palette color directly.
# ===========================================================================
emit({"op": "reset", "note": "reset for test9 no_blend_all_opaque"})
model_reset()

SCAN9 = 75
clear_scanline_effects(SCAN9 + 1, "test9")
clear_pf_row(76, "test9")

SRC9_R4, SRC9_G4, SRC9_B4 = 0x6, 0xE, 0x4
SRC9_ADDR = (0x130 << 4) | 5
write_pal(SRC9_ADDR, pal_color(SRC9_R4, SRC9_G4, SRC9_B4), "test9 src pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 76 // 16, 0x05, palette=0x130)  # pen=5
set_pf_blend(0, 76, prio=5, blend_mode=0b00)  # opaque

set_alpha_coeffs(SCAN9 + 1, 8, 0)  # coefficients don't matter since no blend

exp9 = (exp4(SRC9_R4) << 16) | (exp4(SRC9_G4) << 8) | exp4(SRC9_B4)
mdl9 = model_blend_pixel(SCAN9, 110)
assert mdl9 == exp9, f"test9 model sanity: {mdl9:#08x} != {exp9:#08x}"
check_blend(SCAN9, 110, exp9,
            f"test9 no_blend_all_opaque → src_color exp={exp9:#08x}")


# ===========================================================================
# Test 10: Multiple PFs, only one with blend mode 01.
#
# PF1 prio=2 opaque, PF2 prio=4 blend A (wins over PF1), PF3 prio=4 opaque (skipped same prio).
# PF4 prio=6 opaque (wins over PF2 strictly → no blend, output=PF4).
# Wait — let's make PF4 lower so blend fires: PF1 dst, PF2 blend A src, PF3/PF4 lower prio.
# PF1 prio=4 opaque, PF2 prio=7 blend A over PF1, PF3 prio=2 opaque (lower, skip).
# Expected: blend of PF2 over PF1.
# ===========================================================================
emit({"op": "reset", "note": "reset for test10 multiple_pfs_one_blend"})
model_reset()

SCAN10 = 80
clear_scanline_effects(SCAN10 + 1, "test10")
clear_pf_row(81, "test10")

DST10_R4, DST10_G4, DST10_B4 = 0x2, 0x6, 0xA
SRC10_R4, SRC10_G4, SRC10_B4 = 0xC, 0x4, 0x8
LOW10_R4, LOW10_G4, LOW10_B4 = 0xF, 0x0, 0x3

DST10_ADDR = (0x140 << 4) | 0
SRC10_ADDR = (0x150 << 4) | 2
write_pal(DST10_ADDR, pal_color(DST10_R4, DST10_G4, DST10_B4), "test10 dst pal")
write_pal(SRC10_ADDR, pal_color(SRC10_R4, SRC10_G4, SRC10_B4), "test10 src pal")

# PF1: prio=4, opaque (dst)
for _tx in range(20):
    write_pf_tile(0, _tx, 81 // 16, 0x01, palette=0x140)
set_pf_blend(0, 81, prio=4, blend_mode=0b00)

# PF2: prio=7, blend A (src → blends over PF1)
for _tx in range(20):
    write_pf_tile(1, _tx, 81 // 16, 0x02, palette=0x150)
set_pf_blend(1, 81, prio=7, blend_mode=0b01)

# PF3: prio=2, opaque (loses to PF1 at prio=4)
for _tx in range(20):
    write_pf_tile(2, _tx, 81 // 16, 0x03, palette=0x160)
set_pf_blend(2, 81, prio=2, blend_mode=0b00)

# PF4: transparent (no tiles written → pen=0)
A_SRC10, A_DST10 = 6, 2
set_alpha_coeffs(SCAN10 + 1, A_SRC10, A_DST10)

exp10 = expected_blend(SRC10_R4, SRC10_G4, SRC10_B4,
                       DST10_R4, DST10_G4, DST10_B4,
                       A_SRC10, A_DST10)
mdl10 = model_blend_pixel(SCAN10, 130)
assert mdl10 == exp10, f"test10 model sanity: {mdl10:#08x} != {exp10:#08x}"
check_blend(SCAN10, 130, exp10,
            f"test10 multiple_pfs_only_one_blend PF2_blends_over_PF1 exp={exp10:#08x}")


# ===========================================================================
# Test 11: Slight src, heavy dst (A_src=1, A_dst=7).
# ===========================================================================
emit({"op": "reset", "note": "reset for test11 slight_src_heavy_dst"})
model_reset()

SCAN11 = 85
clear_scanline_effects(SCAN11 + 1, "test11")
clear_pf_row(86, "test11")

SRC11_R4, SRC11_G4, SRC11_B4 = 0xF, 0x0, 0x0  # bright red src
DST11_R4, DST11_G4, DST11_B4 = 0x0, 0x0, 0xF  # bright blue dst

SRC11_ADDR = (0x170 << 4) | 1
DST11_ADDR = (0x180 << 4) | 0
write_pal(SRC11_ADDR, pal_color(SRC11_R4, SRC11_G4, SRC11_B4), "test11 src pal")
write_pal(DST11_ADDR, pal_color(DST11_R4, DST11_G4, DST11_B4), "test11 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 86 // 16, 0x01, palette=0x180)
set_pf_blend(0, 86, prio=3, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 86 // 16, 0x01, palette=0x170)
set_pf_blend(1, 86, prio=8, blend_mode=0b01)

A_SRC11, A_DST11 = 1, 7
set_alpha_coeffs(SCAN11 + 1, A_SRC11, A_DST11)

exp11 = expected_blend(SRC11_R4, SRC11_G4, SRC11_B4,
                       DST11_R4, DST11_G4, DST11_B4,
                       A_SRC11, A_DST11)
mdl11 = model_blend_pixel(SCAN11, 75)
assert mdl11 == exp11, f"test11 model sanity: {mdl11:#08x} != {exp11:#08x}"
check_blend(SCAN11, 75, exp11,
            f"test11 slight_src_heavy_dst A_src=1 A_dst=7 exp={exp11:#08x}")


# ===========================================================================
# Test 12: Blend with no dst (first layer is blend mode — no pixel below).
#
# Only one PF layer active, it has blend mode 01 but there's no layer below.
# RTL: win_prio starts at -1 (no winner), PF0 is the first pixel.
# First pixel: no dst available → blend flag not set → output = src color directly.
# ===========================================================================
emit({"op": "reset", "note": "reset for test12 blend_no_dst"})
model_reset()

SCAN12 = 90
clear_scanline_effects(SCAN12 + 1, "test12")
clear_pf_row(91, "test12")

SRC12_R4, SRC12_G4, SRC12_B4 = 0x9, 0x3, 0x7
SRC12_ADDR = (0x190 << 4) | 4
write_pal(SRC12_ADDR, pal_color(SRC12_R4, SRC12_G4, SRC12_B4), "test12 src pal (only layer)")

for _tx in range(20):
    write_pf_tile(0, _tx, 91 // 16, 0x04, palette=0x190)  # pen=4
set_pf_blend(0, 91, prio=5, blend_mode=0b01)  # blend mode but no dst

# A_src / A_dst don't matter — blend won't fire
set_alpha_coeffs(SCAN12 + 1, 4, 4)

# Expected: no blend → output = src color
exp12 = (exp4(SRC12_R4) << 16) | (exp4(SRC12_G4) << 8) | exp4(SRC12_B4)
mdl12 = model_blend_pixel(SCAN12, 120)
assert mdl12 == exp12, f"test12 model sanity: {mdl12:#08x} != {exp12:#08x}"
check_blend(SCAN12, 120, exp12,
            f"test12 blend_no_dst first_layer_blendA_but_no_dst → src_color exp={exp12:#08x}")


# ===========================================================================
# Write vectors
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step13_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
