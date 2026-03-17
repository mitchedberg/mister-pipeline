#!/usr/bin/env python3
"""
generate_step14_vectors.py — Step 14 test vector generator for tc0630fdp.

Produces step14_vectors.jsonl: Alpha Blend Reverse Mode B.

Test cases (per section3_rtl_plan.md Step 14):
  1. Mode 10 basic: B_src=6, B_dst=2 — verify result differs from mode 01 with same coefficients.
  2. Mode 01 vs mode 10 at adjacent columns — verify each uses correct coefficient set.
  3. Mode 11 = opaque: same output as mode 00 (no blend), src palette color directly.
  4. B_src=8, B_dst=0 → fully opaque (src only) using B coefficients.
  5. B_src=0, B_dst=8 → fully transparent src (dst only) using B coefficients.
  6. B_src=8, B_dst=8 → saturation to 0xFFFFFF using B coefficients.
  7. B coefficients asymmetric: B_src=3, B_dst=5 — verify formula.
  8. Mode 10 sprite: sprite with spr_blend=10 over PF dst layer.
  9. Mode 10 no dst: single layer with blend B — no pixel below → output = src color.
 10. Mode 10 at same priority (strictly-greater): second mode-10 layer skipped.
 11. A and B coefficients independent: set A_src=4/A_dst=4 and B_src=7/B_dst=1.
     Layer with mode 01 uses A; verify B does NOT influence it.
 12. Layer with mode 10 uses B; verify A does NOT influence it.
 13. B_src=4, B_dst=4 (50/50 blend B): mid-range coefficients verify formula.
 14. Mode 11 with blend layer below: opaque-layer (11) beats a blend destination.

Line RAM address map for Step 14 (word addresses):
  §9.5 Alpha blend coefficients:  word 0x3100 + scan
    bits[15:12] = B_src,  bits[11:8] = A_src,  bits[7:4] = B_dst,  bits[3:0] = A_dst
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


def write_pal(pal_addr: int, data: int, note: str = "") -> None:
    """Emit a write_pal op AND mirror to model."""
    emit({"op": "write_pal",
          "pal_addr": pal_addr & 0x1FFF,
          "pal_data": data & 0xFFFF,
          "note": note or f"pal_ram[{pal_addr:#06x}] = {data:#06x}"})
    m.write_pal_ram(pal_addr, data)


def clear_scanline_effects(render_scan: int, note_pfx: str = "") -> None:
    """Zero all Line RAM effect words for render_scan (including Steps 12–14 data)."""
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

    # Step 14: alpha blend coefficients (default: B_src=8, A_src=8, B_dst=0, A_dst=0)
    write_line(0x3100 + s, 0x8800, f"{tag} clear ab_word (B_src=8,A_src=8,B_dst=0,A_dst=0)")


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


def set_alpha_coeffs(scan: int, a_src: int, a_dst: int,
                     b_src: int = 8, b_dst: int = 0) -> None:
    """Write alpha blend coefficients for one scanline (§9.5).

    ab_word: bits[15:12]=B_src, bits[11:8]=A_src, bits[7:4]=B_dst, bits[3:0]=A_dst.
    Defaults: b_src=8 (fully opaque), b_dst=0 (no dest contribution).
    """
    s = scan & 0xFF
    ab_word = ((b_src & 0xF) << 12) | ((a_src & 0xF) << 8) | \
              ((b_dst & 0xF) <<  4) | (a_dst & 0xF)
    write_line(0x3100 + s, ab_word,
               f"alpha_coeffs scan={scan} B_src={b_src} A_src={a_src} "
               f"B_dst={b_dst} A_dst={a_dst}")


def set_spr_blend(scan: int, blend_g0: int = 0, blend_g1: int = 0,
                  blend_g2: int = 0, blend_g3: int = 0) -> None:
    """Write sprite blend modes for one scanline (§9.4)."""
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


# Helper: make a 16-bit palette color word {R4, G4, B4, 0000}
def pal_color(r4: int, g4: int, b4: int) -> int:
    return ((r4 & 0xF) << 12) | ((g4 & 0xF) << 8) | ((b4 & 0xF) << 4)


# Helper: expand 4-bit color channel to 8-bit {v,v}
def exp4(v: int) -> int:
    v4 = v & 0xF
    return (v4 << 4) | v4


# Helper: compute expected blended 24-bit RGB value using explicit coefficients
def expected_blend(src_r4: int, src_g4: int, src_b4: int,
                   dst_r4: int, dst_g4: int, dst_b4: int,
                   coeff_src: int, coeff_dst: int) -> int:
    """Compute expected blend: clamp((src8*coeff_src + dst8*coeff_dst) >> 3, 0, 255)."""
    def ch(sv4, dv4):
        s8 = exp4(sv4)
        d8 = exp4(dv4)
        v = (s8 * coeff_src + d8 * coeff_dst) >> 3
        return min(v, 255)
    r = ch(src_r4, dst_r4)
    g = ch(src_g4, dst_g4)
    b = ch(src_b4, dst_b4)
    return (r << 16) | (g << 8) | b


# ===========================================================================
# Pre-load GFX ROM with solid tiles (persistent — same tiles as steps 11–13)
# ===========================================================================
for tc in range(1, 16):
    write_gfx_solid_tile(tc, tc, f"init: solid tile {tc:#x} pen={tc:#x}")
write_gfx_solid_tile(0x00, 0, "init: tile 0x00 pen=0 (transparent)")
write_gfx_solid_tile(0x10, 1, "init: tile 0x10 pen=1")
write_gfx_solid_tile(0x11, 2, "init: tile 0x11 pen=2")
write_gfx_solid_tile(0x12, 3, "init: tile 0x12 pen=3")
write_gfx_solid_tile(0x13, 4, "init: tile 0x13 pen=4")
write_gfx_solid_tile(0x14, 1, "init: tile 0x14 pen=1 (sprite)")
write_gfx_solid_tile(0x15, 2, "init: tile 0x15 pen=2 (sprite)")

# ===========================================================================
# Clear char RAM for char codes 0–15 (prevents stale text pixel interference)
# ===========================================================================
CHAR_BASE = 0x0F000  # chip word addr for Char RAM
for _cc in range(16):
    for _word in range(16):
        _waddr = CHAR_BASE + _cc * 16 + _word
        emit({"op": "write_char", "addr": _waddr, "data": 0, "be": 3,
              "note": f"init: clear char[{_cc:#04x}] word {_word}"})

# Clear palette RAM once at start (pal_ram persists across tests)
for _pa in range(m.PAL_RAM_WORDS):
    m.pal_ram[_pa] = 0

# ===========================================================================
# Clear Line RAM entries (sprite and pf entries) to prevent stale bleed
# ===========================================================================
for _si in range(4):
    # Zero sprite entry (8 words each)
    for _w in range(8):
        write_spr_word(_si * 8 + _w, 0, f"init: clear spr[{_si}] word{_w}")

# ===========================================================================
# Test 1: Mode 10 basic — B_src=6, B_dst=2
#
# PF1 prio=3 opaque (dst), PF2 prio=7 blend mode B (src).
# B_src=6, B_dst=2, A_src=4, A_dst=4.
#
# Verify: result uses B coefficients (6/2), NOT A coefficients (4/4).
# ===========================================================================
emit({"op": "reset", "note": "reset for test1 mode_10_basic B_src=6 B_dst=2"})
model_reset()

SCAN1 = 30
clear_scanline_effects(SCAN1 + 1, "test1")
clear_pf_row(31, "test1")

SRC1_R4, SRC1_G4, SRC1_B4 = 0xC, 0x4, 0x2   # src color (PF2, blend B winner)
DST1_R4, DST1_G4, DST1_B4 = 0x2, 0x8, 0xE   # dst color (PF1, opaque below)
SRC1_ADDR = (0x020 << 4) | 2   # pal_addr = {0x020, pen=2}
DST1_ADDR = (0x010 << 4) | 0   # pal_addr = {0x010, 4'b0} (dst base)
write_pal(SRC1_ADDR, pal_color(SRC1_R4, SRC1_G4, SRC1_B4), "test1 src pal entry")
write_pal(DST1_ADDR, pal_color(DST1_R4, DST1_G4, DST1_B4), "test1 dst pal entry")

for _tx in range(20):
    write_pf_tile(0, _tx, 31 // 16, 0x01, palette=0x010)  # PF1: pen=1, pal=0x010
set_pf_blend(0, 31, prio=3, blend_mode=0b00)  # PF1: opaque

for _tx in range(20):
    write_pf_tile(1, _tx, 31 // 16, 0x02, palette=0x020)  # PF2: pen=2, pal=0x020
set_pf_blend(1, 31, prio=7, blend_mode=0b10)  # PF2: blend B (mode 10)

# Set both A and B coefficients — blend B should use B only
B_SRC1, B_DST1 = 6, 2
A_SRC1_CTRL, A_DST1_CTRL = 4, 4  # A coefficients set but NOT used for mode 10
set_alpha_coeffs(SCAN1 + 1, a_src=A_SRC1_CTRL, a_dst=A_DST1_CTRL,
                 b_src=B_SRC1, b_dst=B_DST1)

# Expected: blend using B coefficients
exp1_b = expected_blend(SRC1_R4, SRC1_G4, SRC1_B4,
                        DST1_R4, DST1_G4, DST1_B4, B_SRC1, B_DST1)
# Sanity: verify B result != A result (they should differ at these coefficients)
exp1_a = expected_blend(SRC1_R4, SRC1_G4, SRC1_B4,
                        DST1_R4, DST1_G4, DST1_B4, A_SRC1_CTRL, A_DST1_CTRL)
assert exp1_b != exp1_a, (
    f"test1: B blend == A blend — choose different coefficients to test distinction "
    f"B={exp1_b:#08x} A={exp1_a:#08x}")
mdl1 = model_blend_pixel(SCAN1, 100)
assert mdl1 == exp1_b, f"test1 model sanity col=100: {mdl1:#08x} != {exp1_b:#08x}"

check_blend(SCAN1, 100, exp1_b,
            f"test1 mode10_B_blend B_src=6 B_dst=2 col=100 exp={exp1_b:#08x}")
check_blend(SCAN1, 200, exp1_b,
            f"test1 mode10_B_blend B_src=6 B_dst=2 col=200 exp={exp1_b:#08x}")


# ===========================================================================
# Test 2: Mode 01 vs mode 10 on adjacent scanlines — verify coefficient selection.
#
# Scanline A: blend mode 01, A_src=4 A_dst=4 → result uses A
# Scanline B: blend mode 10, B_src=6 B_dst=2 → result uses B (different result)
#
# Both scanlines share same src/dst palette entries.
# ===========================================================================
emit({"op": "reset", "note": "reset for test2 mode01_vs_mode10"})
model_reset()

# Palette entries shared between both scanlines
SRC2_R4, SRC2_G4, SRC2_B4 = 0xA, 0x3, 0x7
DST2_R4, DST2_G4, DST2_B4 = 0x1, 0xD, 0x5
SRC2_ADDR = (0x030 << 4) | 3
DST2_ADDR = (0x040 << 4) | 0
write_pal(SRC2_ADDR, pal_color(SRC2_R4, SRC2_G4, SRC2_B4), "test2 src pal")
write_pal(DST2_ADDR, pal_color(DST2_R4, DST2_G4, DST2_B4), "test2 dst pal")

# --- Scanline A: blend mode 01 ---
SCAN2A = 35
clear_scanline_effects(SCAN2A + 1, "test2A")
clear_pf_row(36, "test2A")

for _tx in range(20):
    write_pf_tile(0, _tx, 36 // 16, 0x01, palette=0x040)  # PF1: pen=1, dst
set_pf_blend(0, 36, prio=3, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 36 // 16, 0x03, palette=0x030)  # PF2: pen=3, src
set_pf_blend(1, 36, prio=7, blend_mode=0b01)  # mode A

A2_SRC, A2_DST = 4, 4
B2_SRC, B2_DST = 6, 2
set_alpha_coeffs(SCAN2A + 1, a_src=A2_SRC, a_dst=A2_DST, b_src=B2_SRC, b_dst=B2_DST)

exp2a = expected_blend(SRC2_R4, SRC2_G4, SRC2_B4,
                       DST2_R4, DST2_G4, DST2_B4, A2_SRC, A2_DST)
mdl2a = model_blend_pixel(SCAN2A, 80)
assert mdl2a == exp2a, f"test2A model sanity: {mdl2a:#08x} != {exp2a:#08x}"
check_blend(SCAN2A, 80, exp2a,
            f"test2 mode01 A_src=4 A_dst=4 → uses A coefficients exp={exp2a:#08x}")

# --- Scanline B: blend mode 10 ---
SCAN2B = 40
clear_scanline_effects(SCAN2B + 1, "test2B")
clear_pf_row(41, "test2B")

for _tx in range(20):
    write_pf_tile(0, _tx, 41 // 16, 0x01, palette=0x040)  # same dst palette
set_pf_blend(0, 41, prio=3, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 41 // 16, 0x03, palette=0x030)  # same src palette
set_pf_blend(1, 41, prio=7, blend_mode=0b10)  # mode B (different from scan2A)

set_alpha_coeffs(SCAN2B + 1, a_src=A2_SRC, a_dst=A2_DST, b_src=B2_SRC, b_dst=B2_DST)

exp2b = expected_blend(SRC2_R4, SRC2_G4, SRC2_B4,
                       DST2_R4, DST2_G4, DST2_B4, B2_SRC, B2_DST)
assert exp2a != exp2b, (
    f"test2: mode01 and mode10 produce same result with chosen coefficients — "
    f"pick different values. A={exp2a:#08x} B={exp2b:#08x}")
mdl2b = model_blend_pixel(SCAN2B, 80)
assert mdl2b == exp2b, f"test2B model sanity: {mdl2b:#08x} != {exp2b:#08x}"
check_blend(SCAN2B, 80, exp2b,
            f"test2 mode10 B_src=6 B_dst=2 → uses B coefficients exp={exp2b:#08x} "
            f"(differs from mode01={exp2a:#08x})")


# ===========================================================================
# Test 3: Mode 11 = opaque layer — output = src palette color (same as mode 00).
#
# PF1 prio=3 opaque (dst), PF2 prio=7 blend mode 11 (src).
# Expected: no blend, output = PF2's src palette color directly.
# ===========================================================================
emit({"op": "reset", "note": "reset for test3 mode11_opaque_layer"})
model_reset()

SCAN3 = 45
clear_scanline_effects(SCAN3 + 1, "test3")
clear_pf_row(46, "test3")

SRC3_R4, SRC3_G4, SRC3_B4 = 0x8, 0x5, 0xC   # PF2 src (mode 11 winner)
DST3_R4, DST3_G4, DST3_B4 = 0x3, 0xA, 0x2   # PF1 dst (irrelevant — mode 11 is opaque)

SRC3_ADDR = (0x050 << 4) | 1
DST3_ADDR = (0x060 << 4) | 0
write_pal(SRC3_ADDR, pal_color(SRC3_R4, SRC3_G4, SRC3_B4), "test3 src pal mode11")
write_pal(DST3_ADDR, pal_color(DST3_R4, DST3_G4, DST3_B4), "test3 dst pal (unused)")

for _tx in range(20):
    write_pf_tile(0, _tx, 46 // 16, 0x01, palette=0x060)  # PF1 dst
set_pf_blend(0, 46, prio=3, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 46 // 16, 0x01, palette=0x050)  # PF2 src, mode 11
set_pf_blend(1, 46, prio=7, blend_mode=0b11)  # mode 11 = opaque layer

# Set non-trivial A and B coefficients to prove they are NOT used for mode 11
set_alpha_coeffs(SCAN3 + 1, a_src=4, a_dst=4, b_src=5, b_dst=3)

# Expected: mode 11 → opaque → output = src palette color (no blend at all)
exp3 = (exp4(SRC3_R4) << 16) | (exp4(SRC3_G4) << 8) | exp4(SRC3_B4)
mdl3 = model_blend_pixel(SCAN3, 90)
assert mdl3 == exp3, f"test3 model sanity: {mdl3:#08x} != {exp3:#08x}"
check_blend(SCAN3, 90, exp3,
            f"test3 mode11_opaque_layer → src_color_no_blend exp={exp3:#08x}")


# ===========================================================================
# Test 4: B_src=8, B_dst=0 → fully opaque src (using B coefficients)
# ===========================================================================
emit({"op": "reset", "note": "reset for test4 mode10_B_fully_opaque"})
model_reset()

SCAN4 = 50
clear_scanline_effects(SCAN4 + 1, "test4")
clear_pf_row(51, "test4")

SRC4_R4, SRC4_G4, SRC4_B4 = 0xE, 0x7, 0x3
DST4_R4, DST4_G4, DST4_B4 = 0x1, 0xB, 0xF

SRC4_ADDR = (0x070 << 4) | 4
DST4_ADDR = (0x080 << 4) | 0
write_pal(SRC4_ADDR, pal_color(SRC4_R4, SRC4_G4, SRC4_B4), "test4 src pal")
write_pal(DST4_ADDR, pal_color(DST4_R4, DST4_G4, DST4_B4), "test4 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 51 // 16, 0x01, palette=0x080)  # PF1 dst
set_pf_blend(0, 51, prio=2, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 51 // 16, 0x04, palette=0x070)  # PF2 src, blend B
set_pf_blend(1, 51, prio=6, blend_mode=0b10)  # blend B

set_alpha_coeffs(SCAN4 + 1, a_src=4, a_dst=4, b_src=8, b_dst=0)  # B_src=8, B_dst=0

# Expected: src*8/8 + dst*0/8 = src only
exp4_rgb = (exp4(SRC4_R4) << 16) | (exp4(SRC4_G4) << 8) | exp4(SRC4_B4)
mdl4 = model_blend_pixel(SCAN4, 60)
assert mdl4 == exp4_rgb, f"test4 model sanity: {mdl4:#08x} != {exp4_rgb:#08x}"
check_blend(SCAN4, 60, exp4_rgb,
            f"test4 mode10 B_src=8 B_dst=0 → src_only exp={exp4_rgb:#08x}")


# ===========================================================================
# Test 5: B_src=0, B_dst=8 → fully transparent src (dst color via B coefficients)
# ===========================================================================
emit({"op": "reset", "note": "reset for test5 mode10_B_transparent_src"})
model_reset()

SCAN5 = 55
clear_scanline_effects(SCAN5 + 1, "test5")
clear_pf_row(56, "test5")

SRC5_R4, SRC5_G4, SRC5_B4 = 0x5, 0xC, 0x9
DST5_R4, DST5_G4, DST5_B4 = 0xF, 0x2, 0x6

SRC5_ADDR = (0x090 << 4) | 2
DST5_ADDR = (0x0A0 << 4) | 0
write_pal(SRC5_ADDR, pal_color(SRC5_R4, SRC5_G4, SRC5_B4), "test5 src pal")
write_pal(DST5_ADDR, pal_color(DST5_R4, DST5_G4, DST5_B4), "test5 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 56 // 16, 0x01, palette=0x0A0)  # PF1 dst
set_pf_blend(0, 56, prio=4, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 56 // 16, 0x02, palette=0x090)  # PF2 src, blend B
set_pf_blend(1, 56, prio=8, blend_mode=0b10)  # blend B

set_alpha_coeffs(SCAN5 + 1, a_src=4, a_dst=4, b_src=0, b_dst=8)  # B_src=0, B_dst=8

# Expected: src*0/8 + dst*8/8 = dst only
exp5 = (exp4(DST5_R4) << 16) | (exp4(DST5_G4) << 8) | exp4(DST5_B4)
mdl5 = model_blend_pixel(SCAN5, 70)
assert mdl5 == exp5, f"test5 model sanity: {mdl5:#08x} != {exp5:#08x}"
check_blend(SCAN5, 70, exp5,
            f"test5 mode10 B_src=0 B_dst=8 → dst_only exp={exp5:#08x}")


# ===========================================================================
# Test 6: B_src=8, B_dst=8 → saturation to 0xFFFFFF
# ===========================================================================
emit({"op": "reset", "note": "reset for test6 mode10_B_saturation"})
model_reset()

SCAN6 = 60
clear_scanline_effects(SCAN6 + 1, "test6")
clear_pf_row(61, "test6")

# Use maximum color values so both terms saturate
SRC6_ADDR = (0x0B0 << 4) | 1
DST6_ADDR = (0x0C0 << 4) | 0
write_pal(SRC6_ADDR, pal_color(0xF, 0xF, 0xF), "test6 src pal max white")
write_pal(DST6_ADDR, pal_color(0xF, 0xF, 0xF), "test6 dst pal max white")

for _tx in range(20):
    write_pf_tile(0, _tx, 61 // 16, 0x01, palette=0x0C0)
set_pf_blend(0, 61, prio=2, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 61 // 16, 0x01, palette=0x0B0)
set_pf_blend(1, 61, prio=6, blend_mode=0b10)  # blend B

set_alpha_coeffs(SCAN6 + 1, a_src=4, a_dst=4, b_src=8, b_dst=8)  # B saturates

# Expected: (255*8 + 255*8) >> 3 = 510 → saturate to 255 per channel = 0xFFFFFF
exp6 = 0xFFFFFF
mdl6 = model_blend_pixel(SCAN6, 50)
assert mdl6 == exp6, f"test6 model sanity: {mdl6:#08x} != {exp6:#08x}"
check_blend(SCAN6, 50, exp6,
            f"test6 mode10 B_src=8 B_dst=8 → 0xFFFFFF saturation exp={exp6:#08x}")


# ===========================================================================
# Test 7: Asymmetric B coefficients B_src=3, B_dst=5
# ===========================================================================
emit({"op": "reset", "note": "reset for test7 mode10_B_asymmetric"})
model_reset()

SCAN7 = 110
clear_scanline_effects(SCAN7 + 1, "test7")
clear_pf_row(SCAN7 + 1, "test7")

SRC7_R4, SRC7_G4, SRC7_B4 = 0xE, 0x2, 0x6   # bright red src
DST7_R4, DST7_G4, DST7_B4 = 0x3, 0xA, 0xD   # teal dst

SRC7_ADDR = (0x0D0 << 4) | 6
DST7_ADDR = (0x0E0 << 4) | 0
write_pal(SRC7_ADDR, pal_color(SRC7_R4, SRC7_G4, SRC7_B4), "test7 src pal")
write_pal(DST7_ADDR, pal_color(DST7_R4, DST7_G4, DST7_B4), "test7 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, (SCAN7 + 1) // 16, 0x01, palette=0x0E0)  # PF1 dst
set_pf_blend(0, SCAN7 + 1, prio=4, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, (SCAN7 + 1) // 16, 0x06, palette=0x0D0)  # PF2 src, pen=6
set_pf_blend(1, SCAN7 + 1, prio=9, blend_mode=0b10)  # blend B

B7_SRC, B7_DST = 3, 5
set_alpha_coeffs(SCAN7 + 1, a_src=8, a_dst=0, b_src=B7_SRC, b_dst=B7_DST)

exp7 = expected_blend(SRC7_R4, SRC7_G4, SRC7_B4,
                      DST7_R4, DST7_G4, DST7_B4, B7_SRC, B7_DST)
mdl7 = model_blend_pixel(SCAN7, 95)
assert mdl7 == exp7, f"test7 model sanity: {mdl7:#08x} != {exp7:#08x}"
check_blend(SCAN7, 95, exp7,
            f"test7 mode10 asymmetric B_src=3 B_dst=5 exp={exp7:#08x}")


# ===========================================================================
# Test 8: Sprite blend mode B over PF dst layer.
#
# Sprite group 0x00 with spr_blend=10 (mode B) over PF1 dst.
# ===========================================================================
emit({"op": "reset", "note": "reset for test8 sprite_blend_B"})
model_reset()

SCAN8 = 70
clear_scanline_effects(SCAN8 + 1, "test8")
clear_pf_row(71, "test8")
clear_sprite_entry(0)

# PF1 dst
DST8_R4, DST8_G4, DST8_B4 = 0x4, 0xC, 0x8
DST8_PAL = 0x100
DST8_ADDR = DST8_PAL << 4   # base = 0x1000
write_pal(DST8_ADDR, pal_color(DST8_R4, DST8_G4, DST8_B4), "test8 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 71 // 16, 0x01, palette=DST8_PAL)
set_pf_blend(0, 71, prio=3, blend_mode=0b00)

# Sprite src (group 0x00), blend mode B
SPR8_R4, SPR8_G4, SPR8_B4 = 0xB, 0x3, 0xE
# group 0x00 → prio=0, palette=0x10 → color byte = 0x10
SPR8_COLOR = 0x10
SPR8_PAL9  = SPR8_COLOR & 0x3F   # = 0x10
SPR8_ADDR  = (SPR8_PAL9 << 4) | 1  # pen=1
write_pal(SPR8_ADDR, pal_color(SPR8_R4, SPR8_G4, SPR8_B4), "test8 spr src pal")

write_sprite_entry(0, tile_code=0x14, sx=60, sy=SCAN8 + 1 - 8, color=SPR8_COLOR,
                   note="test8 sprite blend B")

set_spr_priority(SCAN8 + 1, prio_g0=7)   # sprite group 0 prio=7 > PF1 prio=3
set_spr_blend(SCAN8 + 1, blend_g0=0b10)  # group 0 blend B (mode 10)

B8_SRC, B8_DST = 5, 3
set_alpha_coeffs(SCAN8 + 1, a_src=2, a_dst=6, b_src=B8_SRC, b_dst=B8_DST)

# Model: need sprite line buffer
m.scan_sprites()
spr8_buf = m.render_sprite_scanline(SCAN8)

exp8 = expected_blend(SPR8_R4, SPR8_G4, SPR8_B4,
                      DST8_R4, DST8_G4, DST8_B4, B8_SRC, B8_DST)
mdl8 = model_blend_pixel(SCAN8, 60, spr_linebuf=spr8_buf)
assert mdl8 == exp8, f"test8 model sanity: {mdl8:#08x} != {exp8:#08x}"
check_blend(SCAN8, 60, exp8,
            f"test8 sprite_blend_B B_src={B8_SRC} B_dst={B8_DST} exp={exp8:#08x}")


# ===========================================================================
# Test 9: Mode 10 no dst — single layer with blend B, no pixel below.
#
# Only PF0 active, blend mode 10, but it's the first pixel (no layer below).
# Expected: no blend → output = src color directly.
# ===========================================================================
emit({"op": "reset", "note": "reset for test9 mode10_no_dst"})
model_reset()

SCAN9 = 75
clear_scanline_effects(SCAN9 + 1, "test9")
clear_pf_row(76, "test9")

SRC9_R4, SRC9_G4, SRC9_B4 = 0x9, 0x3, 0x7
SRC9_ADDR = (0x110 << 4) | 4
write_pal(SRC9_ADDR, pal_color(SRC9_R4, SRC9_G4, SRC9_B4), "test9 src pal (only layer)")

for _tx in range(20):
    write_pf_tile(0, _tx, 76 // 16, 0x04, palette=0x110)  # pen=4
set_pf_blend(0, 76, prio=5, blend_mode=0b10)  # blend B but no dst

set_alpha_coeffs(SCAN9 + 1, a_src=4, a_dst=4, b_src=4, b_dst=4)  # irrelevant

# Expected: no blend (first layer = no dst) → src color
exp9 = (exp4(SRC9_R4) << 16) | (exp4(SRC9_G4) << 8) | exp4(SRC9_B4)
mdl9 = model_blend_pixel(SCAN9, 120)
assert mdl9 == exp9, f"test9 model sanity: {mdl9:#08x} != {exp9:#08x}"
check_blend(SCAN9, 120, exp9,
            f"test9 mode10_no_dst first_layer_blendB_but_no_dst → src_color exp={exp9:#08x}")


# ===========================================================================
# Test 10: Mode 10 strictly-greater skip — second blend B layer at same priority skipped.
#
# PF1 prio=5 opaque (dst), PF2 prio=7 blend B (fires), PF3 prio=7 blend B (skipped).
# Expected: blend of PF2 over PF1 using B coefficients.
# ===========================================================================
emit({"op": "reset", "note": "reset for test10 mode10_same_prio_skip"})
model_reset()

SCAN10 = 80
clear_scanline_effects(SCAN10 + 1, "test10")
clear_pf_row(81, "test10")

SRC10A_R4, SRC10A_G4, SRC10A_B4 = 0x8, 0x2, 0xC  # PF2 (first blend B winner)
DST10_R4,  DST10_G4,  DST10_B4  = 0x3, 0xD, 0x5  # PF1 (dst)
SRC10B_R4, SRC10B_G4, SRC10B_B4 = 0xE, 0xE, 0x0  # PF3 (skipped)

SRC10A_ADDR = (0x120 << 4) | 1
DST10_ADDR  = (0x130 << 4) | 0
SRC10B_ADDR = (0x140 << 4) | 2
write_pal(SRC10A_ADDR, pal_color(SRC10A_R4, SRC10A_G4, SRC10A_B4), "test10 PF2 pal")
write_pal(DST10_ADDR,  pal_color(DST10_R4, DST10_G4, DST10_B4),   "test10 PF1 dst pal")
write_pal(SRC10B_ADDR, pal_color(SRC10B_R4, SRC10B_G4, SRC10B_B4), "test10 PF3 pal (skip)")

# PF1: prio=5, opaque (dst)
for _tx in range(20):
    write_pf_tile(0, _tx, 81 // 16, 0x01, palette=0x130)
set_pf_blend(0, 81, prio=5, blend_mode=0b00)

# PF2: prio=7, blend B (first wins)
for _tx in range(20):
    write_pf_tile(1, _tx, 81 // 16, 0x01, palette=0x120)
set_pf_blend(1, 81, prio=7, blend_mode=0b10)

# PF3: prio=7, blend B (same priority as PF2 → strictly-greater fails → skipped)
for _tx in range(20):
    write_pf_tile(2, _tx, 81 // 16, 0x02, palette=0x140)
set_pf_blend(2, 81, prio=7, blend_mode=0b10)

B10_SRC, B10_DST = 4, 4
set_alpha_coeffs(SCAN10 + 1, a_src=4, a_dst=4, b_src=B10_SRC, b_dst=B10_DST)

# Expected: blend of PF2 (src) over PF1 (dst) using B coefficients
exp10 = expected_blend(SRC10A_R4, SRC10A_G4, SRC10A_B4,
                       DST10_R4, DST10_G4, DST10_B4, B10_SRC, B10_DST)
mdl10 = model_blend_pixel(SCAN10, 70)
assert mdl10 == exp10, f"test10 model sanity: {mdl10:#08x} != {exp10:#08x}"
check_blend(SCAN10, 70, exp10,
            f"test10 mode10_same_prio_skip second_blendB_skipped exp={exp10:#08x}")


# ===========================================================================
# Test 11: A and B coefficients are independent (mode 01 uses A, ignores B).
#
# Mode 01 layer with A_src=4, A_dst=4 and different B_src=7, B_dst=1.
# Expected: blend uses A coefficients ONLY.
# ===========================================================================
emit({"op": "reset", "note": "reset for test11 mode01_ignores_B_coeffs"})
model_reset()

SCAN11 = 85
clear_scanline_effects(SCAN11 + 1, "test11")
clear_pf_row(86, "test11")

SRC11_R4, SRC11_G4, SRC11_B4 = 0xD, 0x4, 0x9
DST11_R4, DST11_G4, DST11_B4 = 0x2, 0xB, 0x4

SRC11_ADDR = (0x150 << 4) | 5
DST11_ADDR = (0x160 << 4) | 0
write_pal(SRC11_ADDR, pal_color(SRC11_R4, SRC11_G4, SRC11_B4), "test11 src pal")
write_pal(DST11_ADDR, pal_color(DST11_R4, DST11_G4, DST11_B4), "test11 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 86 // 16, 0x01, palette=0x160)  # PF1 dst
set_pf_blend(0, 86, prio=3, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 86 // 16, 0x05, palette=0x150)  # PF2 src mode A
set_pf_blend(1, 86, prio=7, blend_mode=0b01)  # mode A

A11_SRC, A11_DST = 4, 4
B11_SRC, B11_DST = 7, 1  # deliberately different from A
set_alpha_coeffs(SCAN11 + 1, a_src=A11_SRC, a_dst=A11_DST, b_src=B11_SRC, b_dst=B11_DST)

exp11_a = expected_blend(SRC11_R4, SRC11_G4, SRC11_B4,
                         DST11_R4, DST11_G4, DST11_B4, A11_SRC, A11_DST)
exp11_b = expected_blend(SRC11_R4, SRC11_G4, SRC11_B4,
                         DST11_R4, DST11_G4, DST11_B4, B11_SRC, B11_DST)
assert exp11_a != exp11_b, (
    f"test11: A blend == B blend — pick different A/B coefficients for this test")
mdl11 = model_blend_pixel(SCAN11, 75)
assert mdl11 == exp11_a, f"test11 model sanity: {mdl11:#08x} != {exp11_a:#08x}"
check_blend(SCAN11, 75, exp11_a,
            f"test11 mode01_uses_A_only A_src=4 A_dst=4 (B_src=7 B_dst=1 ignored) "
            f"exp={exp11_a:#08x}")


# ===========================================================================
# Test 12: A and B coefficients are independent (mode 10 uses B, ignores A).
#
# Mode 10 layer with A_src=7, A_dst=1 and different B_src=2, B_dst=6.
# Expected: blend uses B coefficients ONLY.
# ===========================================================================
emit({"op": "reset", "note": "reset for test12 mode10_ignores_A_coeffs"})
model_reset()

SCAN12 = 90
clear_scanline_effects(SCAN12 + 1, "test12")
clear_pf_row(91, "test12")

SRC12_R4, SRC12_G4, SRC12_B4 = 0x6, 0xE, 0x1
DST12_R4, DST12_G4, DST12_B4 = 0xC, 0x3, 0xA

SRC12_ADDR = (0x170 << 4) | 3
DST12_ADDR = (0x180 << 4) | 0
write_pal(SRC12_ADDR, pal_color(SRC12_R4, SRC12_G4, SRC12_B4), "test12 src pal")
write_pal(DST12_ADDR, pal_color(DST12_R4, DST12_G4, DST12_B4), "test12 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 91 // 16, 0x01, palette=0x180)  # PF1 dst
set_pf_blend(0, 91, prio=3, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 91 // 16, 0x03, palette=0x170)  # PF2 src mode B
set_pf_blend(1, 91, prio=7, blend_mode=0b10)  # mode B

A12_SRC, A12_DST = 7, 1  # deliberately different from B
B12_SRC, B12_DST = 2, 6
set_alpha_coeffs(SCAN12 + 1, a_src=A12_SRC, a_dst=A12_DST, b_src=B12_SRC, b_dst=B12_DST)

exp12_b = expected_blend(SRC12_R4, SRC12_G4, SRC12_B4,
                         DST12_R4, DST12_G4, DST12_B4, B12_SRC, B12_DST)
exp12_a = expected_blend(SRC12_R4, SRC12_G4, SRC12_B4,
                         DST12_R4, DST12_G4, DST12_B4, A12_SRC, A12_DST)
assert exp12_b != exp12_a, (
    f"test12: A blend == B blend — pick different A/B coefficients for this test")
mdl12 = model_blend_pixel(SCAN12, 100)
assert mdl12 == exp12_b, f"test12 model sanity: {mdl12:#08x} != {exp12_b:#08x}"
check_blend(SCAN12, 100, exp12_b,
            f"test12 mode10_uses_B_only B_src=2 B_dst=6 (A_src=7 A_dst=1 ignored) "
            f"exp={exp12_b:#08x}")


# ===========================================================================
# Test 13: B_src=4, B_dst=4 (50/50 blend B) — mid-range coefficients.
# ===========================================================================
emit({"op": "reset", "note": "reset for test13 mode10_50_50_B"})
model_reset()

SCAN13 = 95
clear_scanline_effects(SCAN13 + 1, "test13")
clear_pf_row(96, "test13")

SRC13_R4, SRC13_G4, SRC13_B4 = 0xF, 0x0, 0x4
DST13_R4, DST13_G4, DST13_B4 = 0x0, 0xF, 0xC

SRC13_ADDR = (0x190 << 4) | 2
DST13_ADDR = (0x1A0 << 4) | 0
write_pal(SRC13_ADDR, pal_color(SRC13_R4, SRC13_G4, SRC13_B4), "test13 src pal")
write_pal(DST13_ADDR, pal_color(DST13_R4, DST13_G4, DST13_B4), "test13 dst pal")

for _tx in range(20):
    write_pf_tile(0, _tx, 96 // 16, 0x01, palette=0x1A0)  # PF1 dst
set_pf_blend(0, 96, prio=3, blend_mode=0b00)

for _tx in range(20):
    write_pf_tile(1, _tx, 96 // 16, 0x02, palette=0x190)  # PF2 src blend B
set_pf_blend(1, 96, prio=7, blend_mode=0b10)  # blend B

B13_SRC, B13_DST = 4, 4
set_alpha_coeffs(SCAN13 + 1, a_src=8, a_dst=0, b_src=B13_SRC, b_dst=B13_DST)

exp13 = expected_blend(SRC13_R4, SRC13_G4, SRC13_B4,
                       DST13_R4, DST13_G4, DST13_B4, B13_SRC, B13_DST)
mdl13 = model_blend_pixel(SCAN13, 110)
assert mdl13 == exp13, f"test13 model sanity: {mdl13:#08x} != {exp13:#08x}"
check_blend(SCAN13, 110, exp13,
            f"test13 mode10 50/50_B B_src=4 B_dst=4 exp={exp13:#08x}")


# ===========================================================================
# Test 14: Mode 11 with non-trivial blend layer below — opaque-layer wins.
#
# PF1 prio=3 blend B (has a dst below? No — PF1 is first).
# PF2 prio=7 mode 11 (opaque layer) — beats PF1, no blend, output = PF2 src.
# Even though PF1 has blend mode, PF2's mode 11 overrides everything.
# ===========================================================================
emit({"op": "reset", "note": "reset for test14 mode11_overrides_blend_below"})
model_reset()

SCAN14 = 100
clear_scanline_effects(SCAN14 + 1, "test14")
clear_pf_row(101, "test14")

# We need three layers: lowest opaque dst (pf0), middle blend B (pf1), top mode 11 (pf2).
# pf0 prio=2 opaque, pf1 prio=5 blend B (src over pf0 as dst), pf2 prio=9 mode 11 (overrides all).
DST14_R4, DST14_G4, DST14_B4 = 0x2, 0x6, 0xA   # PF0 (beneath pf1)
MID14_R4, MID14_G4, MID14_B4 = 0x7, 0xE, 0x3   # PF1 blend B (overridden by pf2)
TOP14_R4, TOP14_G4, TOP14_B4 = 0xD, 0x1, 0x8   # PF2 mode 11 (final winner)

DST14_ADDR = (0x1B0 << 4) | 0
MID14_ADDR = (0x1C0 << 4) | 3
TOP14_ADDR = (0x1D0 << 4) | 1
write_pal(DST14_ADDR, pal_color(DST14_R4, DST14_G4, DST14_B4), "test14 dst pal PF0")
write_pal(MID14_ADDR, pal_color(MID14_R4, MID14_G4, MID14_B4), "test14 mid pal PF1")
write_pal(TOP14_ADDR, pal_color(TOP14_R4, TOP14_G4, TOP14_B4), "test14 top pal PF2")

# PF0: prio=2, opaque (dst)
for _tx in range(20):
    write_pf_tile(0, _tx, 101 // 16, 0x01, palette=0x1B0)
set_pf_blend(0, 101, prio=2, blend_mode=0b00)

# PF1: prio=5, blend B (would blend over PF0, but PF2 overrides)
for _tx in range(20):
    write_pf_tile(1, _tx, 101 // 16, 0x03, palette=0x1C0)
set_pf_blend(1, 101, prio=5, blend_mode=0b10)  # blend B

# PF2: prio=9, mode 11 = opaque layer (highest priority, overrides blend)
for _tx in range(20):
    write_pf_tile(2, _tx, 101 // 16, 0x01, palette=0x1D0)
set_pf_blend(2, 101, prio=9, blend_mode=0b11)  # mode 11 = opaque layer

set_alpha_coeffs(SCAN14 + 1, a_src=4, a_dst=4, b_src=4, b_dst=4)

# Expected: mode 11 at highest prio → opaque → output = PF2 src color (no blend)
exp14 = (exp4(TOP14_R4) << 16) | (exp4(TOP14_G4) << 8) | exp4(TOP14_B4)
mdl14 = model_blend_pixel(SCAN14, 80)
assert mdl14 == exp14, f"test14 model sanity: {mdl14:#08x} != {exp14:#08x}"
check_blend(SCAN14, 80, exp14,
            f"test14 mode11_overrides_blend PF2_mode11_beats_PF1_blendB exp={exp14:#08x}")


# ===========================================================================
# Write vectors
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step14_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
