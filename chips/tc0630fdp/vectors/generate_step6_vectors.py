#!/usr/bin/env python3
"""
generate_step6_vectors.py — Step 6 test vector generator for tc0630fdp.

Produces step6_vectors.jsonl: Per-Scanline Zoom (Plan Step 6).

Test cases (per section3_rtl_plan.md Step 6):
  1. PF1 X zoom = 0x40 for scanlines 100–120. Verify those scanlines show
     the tilemap at higher horizontal density.
  2. X zoom = 0x00 (no zoom / 1:1) — verify no change from unzoomed output.
  3. PF2 Y-zoom swap: write PF2 Y-zoom into the PF4 Line RAM address range
     (word 0x4300+scan) and verify it applies to PF2. Write to PF2 address
     (word 0x4200+scan) and verify it applies to PF4.
  4. Y-zoom on PF1: Set Y scale = 0x40 (zoom out). Verify source tilemap rows
     are sampled at half rate (canvas_y shrinks).
  5. Simultaneous X and Y zoom on PF3. Verify both axes scale independently.

IMPORTANT: GFX ROM is persistent across resets (write-once from CPU side).
We use a single model object and reset only the mutable state (ctrl, PF RAM,
Line RAM) between groups to match RTL behaviour.

Line RAM address layout for zoom (§9.9):
  Zoom enable base : byte 0x0800 → BRAM word 0x0400  (bits[3:0] = en per PF)
  PF1 zoom data    : BRAM word 0x4000 + scan
  PF3 zoom data    : BRAM word 0x4100 + scan
  PF2 zoom data    : BRAM word 0x4200 + scan  (PF4 Y-zoom physically here)
  PF4 zoom data    : BRAM word 0x4300 + scan  (PF2 Y-zoom physically here)
  Format: bits[15:8] = Y_scale, bits[7:0] = X_scale
"""

import json
import os
from fdp_model import TaitoF3Model

vectors = []

def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
# Address constants (match generate_step5_vectors.py)
# ---------------------------------------------------------------------------
PF1_BASE  = 0x04000   # chip word addr for PF1 RAM word 0
PF2_BASE  = 0x06000
PF3_BASE  = 0x08000
PF4_BASE  = 0x0A000
PF_BASES  = [PF1_BASE, PF2_BASE, PF3_BASE, PF4_BASE]

LINE_BASE = 0x10000   # chip word addr for Line RAM BRAM offset 0


# ---------------------------------------------------------------------------
# Single persistent model — GFX ROM state survives across resets.
# Call model_reset() to zero PF RAM, ctrl, and Line RAM (matching RTL reset).
# ---------------------------------------------------------------------------
m = TaitoF3Model()

def model_reset():
    """Reset model state that the RTL reset clears (ctrl, PF RAM, Line RAM).
    GFX ROM is NOT cleared — it persists like the RTL.
    """
    m.ctrl     = [0] * 16
    m.pf_ram   = [[0] * m.PF_RAM_WORDS for _ in range(4)]
    m.text_ram = [0] * m.TEXT_RAM_WORDS
    m.char_ram = [0] * m.CHAR_RAM_BYTES
    m.line_ram = [0] * m.LINE_RAM_WORDS


# ---------------------------------------------------------------------------
# Low-level helpers (mirrors step5 generator)
# ---------------------------------------------------------------------------

def write_line_word(bram_offset: int, data: int, note: str = "") -> None:
    emit({"op": "write_line",
          "addr": LINE_BASE + bram_offset,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"line_ram[{bram_offset:#06x}] = {data:#06x}"})


def write_zoom_enable(scan: int, en_mask: int, note: str = "") -> None:
    """Write zoom enable bits for one scanline.

    en_mask bits[3:0]: PF1=bit0 .. PF4=bit3.
    BRAM addr = 0x0400 + scan.
    """
    write_line_word(0x0400 + scan, en_mask & 0xF,
                    note or f"zoom_en scan={scan:#04x} mask={en_mask:#03x}")


def write_zoom_data_bram(bram_offset: int, zoom_x: int, zoom_y: int,
                          note: str = "") -> None:
    """Write one zoom data word at a specific BRAM offset.

    format: bits[15:8] = zoom_y, bits[7:0] = zoom_x
    """
    word = ((zoom_y & 0xFF) << 8) | (zoom_x & 0xFF)
    write_line_word(bram_offset, word,
                    note or f"zoom bram[{bram_offset:#06x}] y={zoom_y:#04x} x={zoom_x:#04x}")


def write_pf_tile(pf_base: int, tile_idx: int, palette: int, tile_code: int,
                  flip_x: bool = False, flip_y: bool = False) -> None:
    """Write one tile entry (attr+code) to a PF RAM."""
    attr = palette & 0x1FF
    if flip_x: attr |= (1 << 14)
    if flip_y: attr |= (1 << 15)
    word_base = tile_idx * 2
    emit({"op": "write_pf",
          "addr": pf_base + word_base,
          "data": attr,
          "be": 3,
          "note": f"pf_base={pf_base:#06x} tile[{tile_idx}] attr={attr:#06x}"})
    emit({"op": "write_pf",
          "addr": pf_base + word_base + 1,
          "data": tile_code & 0xFFFF,
          "be": 3,
          "note": f"pf_base={pf_base:#06x} tile[{tile_idx}] code={tile_code:#06x}"})


def write_gfx_solid(tile_code: int, row: int, pen: int) -> None:
    """Fill one GFX ROM row with a solid pen value (all 16 pixels same pen)."""
    nibble = pen & 0xF
    word = 0
    for _ in range(8):
        word = (word << 4) | nibble
    base_addr = tile_code * 32 + row * 2
    emit({"op": "write_gfx", "gfx_addr": base_addr,
          "gfx_data": word & 0xFFFFFFFF,
          "note": f"gfx tile={tile_code:#04x} row={row} pen={pen:#x} left"})
    emit({"op": "write_gfx", "gfx_addr": base_addr + 1,
          "gfx_data": word & 0xFFFFFFFF,
          "note": f"gfx tile={tile_code:#04x} row={row} pen={pen:#x} right"})


def gfx_solid_word(pen: int) -> int:
    """Return a 32-bit GFX word with all 8 nibbles = pen."""
    w = 0
    for _ in range(8):
        w = (w << 4) | (pen & 0xF)
    return w


def write_gfx_solid_model(tile_code: int, row: int, pen: int) -> None:
    """Write GFX ROM row in model only (no vector emit). For pre-filling."""
    w = gfx_solid_word(pen)
    for wa in [tile_code * 32 + row * 2, tile_code * 32 + row * 2 + 1]:
        m.gfx_rom[wa] = w


def check_bg(vpos: int, screen_col: int, plane: int, exp: int, note: str) -> None:
    emit({"op": "check_bg_pixel",
          "vpos": vpos,
          "screen_col": screen_col,
          "plane": plane,
          "exp_pixel": exp & 0x1FFF,
          "note": note})


def model_bg(vpos: int, plane: int, xscroll: int, yscroll: int,
              screen_col: int, extend_mode: bool = False) -> int:
    line = m.render_bg_scanline(vpos, plane, xscroll, yscroll, extend_mode)
    return line[screen_col]


# ===========================================================================
# Test group 1: PF1 X zoom = 0x40 for scanlines 100–120
# zoom_step = 0x100 + 0x40 = 0x140 (source tiles traversed faster → higher density)
# Unzoomed scanlines use zoom_x = 0x00 (zoom_step = 0x100 = 1:1).
# ===========================================================================
emit({"op": "reset", "note": "reset for PF1 X-zoom=0x40 scanlines 100-120 test"})
model_reset()

# Simple alternating tile pattern: even tx → TC_EVEN (pen 0x5, pal 0x010)
#                                   odd  tx → TC_ODD  (pen 0x9, pal 0x020)
PAL_EVEN = 0x010
PAL_ODD  = 0x020
PEN_EVEN = 0x5
PEN_ODD  = 0x9
TC_EVEN  = 0x00
TC_ODD   = 0x01

for ty in range(32):
    for tx in range(32):
        tc  = TC_EVEN if (tx % 2 == 0) else TC_ODD
        pal = PAL_EVEN if (tx % 2 == 0) else PAL_ODD
        tile_idx = ty * 32 + tx
        write_pf_tile(PF1_BASE, tile_idx, pal, tc)
        m.write_pf_ram(0, tile_idx * 2,     pal)
        m.write_pf_ram(0, tile_idx * 2 + 1, tc)

for row_r in range(16):
    write_gfx_solid(TC_EVEN, row_r, PEN_EVEN)
    write_gfx_solid(TC_ODD,  row_r, PEN_ODD)
    write_gfx_solid_model(TC_EVEN, row_r, PEN_EVEN)
    write_gfx_solid_model(TC_ODD,  row_r, PEN_ODD)

# Global scroll: 0 for PF1
XSCROLL1 = 0
YSCROLL1 = 0

# Program zoom enable + data for PF1 on scanlines 100–120
ZOOM_X_VAL  = 0x40   # X zoom value
ZOOM_Y_NONE = 0x80   # Y zoom = 1:1

ZOOM_SCAN_START = 100
ZOOM_SCAN_END   = 120

for scan in range(ZOOM_SCAN_START, ZOOM_SCAN_END + 1):
    write_zoom_enable(scan, 0x1)
    write_zoom_data_bram(0x4000 + scan, ZOOM_X_VAL, ZOOM_Y_NONE,
                          f"zoom data PF1 scan={scan} x={ZOOM_X_VAL:#04x} y={ZOOM_Y_NONE:#04x}")
    m.write_line_ram(0x0400 + scan, 0x1)
    m.write_line_ram(0x4000 + scan, (ZOOM_Y_NONE << 8) | ZOOM_X_VAL)

# vpos = 99 → next_scan = 100 (first zoomed scanline)
# vpos = 121 → next_scan = 122 (first unzoomed scanline after range)
VPOS_ZOOM_IN  = 99    # inside zoom range (next_scan = 100)
VPOS_ZOOM_OUT = 121   # outside zoom range (next_scan = 122)

for scol in [0, 8, 16, 24, 32, 48, 64, 96, 128, 160, 200, 256]:
    exp_in  = model_bg(VPOS_ZOOM_IN,  0, XSCROLL1, YSCROLL1, scol)
    exp_out = model_bg(VPOS_ZOOM_OUT, 0, XSCROLL1, YSCROLL1, scol)
    check_bg(VPOS_ZOOM_IN,  scol, 0, exp_in,
             f"X-zoom PF1 in-range  scol={scol:3d} exp={exp_in:#06x}")
    check_bg(VPOS_ZOOM_OUT, scol, 0, exp_out,
             f"X-zoom PF1 out-range scol={scol:3d} exp={exp_out:#06x}")


# ===========================================================================
# Test group 2: zoom_x = 0x00 (no zoom) — identical to unzoomed output
# This verifies that zoom_enable=1 with zoom_x=0 does not disturb rendering.
# ===========================================================================
emit({"op": "reset", "note": "reset for zoom_x=0x00 (no change) test"})
model_reset()

# Same alternating tile pattern (GFX ROM already written above — persistent)
for ty in range(32):
    for tx in range(32):
        tc  = TC_EVEN if (tx % 2 == 0) else TC_ODD
        pal = PAL_EVEN if (tx % 2 == 0) else PAL_ODD
        tile_idx = ty * 32 + tx
        write_pf_tile(PF1_BASE, tile_idx, pal, tc)
        m.write_pf_ram(0, tile_idx * 2,     pal)
        m.write_pf_ram(0, tile_idx * 2 + 1, tc)
# No GFX writes needed — TC_EVEN and TC_ODD already in RTL GFX ROM from group 1.

# Enable zoom with zoom_x=0x00, zoom_y=0x80 for scanlines 40–55
NOZOOM_SCAN_START = 40
NOZOOM_SCAN_END   = 55

for scan in range(NOZOOM_SCAN_START, NOZOOM_SCAN_END + 1):
    write_zoom_enable(scan, 0x1)
    write_zoom_data_bram(0x4000 + scan, 0x00, 0x80,
                          f"zoom_x=0 zoom_y=1:1 scan={scan}")
    m.write_line_ram(0x0400 + scan, 0x1)
    m.write_line_ram(0x4000 + scan, (0x80 << 8) | 0x00)

# vpos = 39 → next_scan=40 (zoom enabled, zoom_x=0 → 1:1)
# vpos = 56 → next_scan=57 (zoom disabled → unzoomed)
VPOS_NZ_IN  = 39
VPOS_NZ_OUT = 56

# Both should produce identical results (zoom_x=0x00 means step=256=1:1)
for scol in [0, 16, 32, 64, 128, 200, 256]:
    exp_in  = model_bg(VPOS_NZ_IN,  0, 0, 0, scol)
    exp_out = model_bg(VPOS_NZ_OUT, 0, 0, 0, scol)
    check_bg(VPOS_NZ_IN,  scol, 0, exp_in,
             f"zoom_x=0 in-range  scol={scol:3d} exp={exp_in:#06x}")
    check_bg(VPOS_NZ_OUT, scol, 0, exp_out,
             f"zoom_x=0 out-range scol={scol:3d} exp={exp_out:#06x}")
    assert exp_in == exp_out, \
        f"zoom_x=0 mismatch at scol={scol}: in={exp_in:#06x} out={exp_out:#06x}"


# ===========================================================================
# Test group 3: PF2/PF4 Y-zoom swap
# Hardware quirk (§9.9): PF2's Y-zoom is stored at PF4's BRAM address (0x4300+scan)
#                        PF4's Y-zoom is stored at PF2's BRAM address (0x4200+scan)
# ===========================================================================
emit({"op": "reset", "note": "reset for PF2/PF4 Y-zoom swap test"})
model_reset()

# vpos=69 → next_scan=70
VPOS_SWAP = 69
SCAN_SWAP  = 70

# canvas_y_raw = 70; with zoom_y=0x40: canvas_y = (70 * 64) >> 7 = 35 → fetch_ty=2, fetch_py=3
# canvas_y_raw = 70; with zoom_y=0x60: canvas_y = (70 * 96) >> 7 = 52 → fetch_ty=3, fetch_py=4
# canvas_y_raw = 70; no zoom (0x80):   canvas_y = (70 * 128) >> 7 = 70 → fetch_ty=4, fetch_py=6

PF2_PAL = 0x040;  PF2_PEN = 0x6;  PF2_TC = 0x0A
PF4_PAL = 0x080;  PF4_PEN = 0xD;  PF4_TC = 0x0B

# PF2: write tiles at ALL ty rows 0..31 (to cover any zoomed fetch_ty)
for ty in range(32):
    for tx in range(32):
        tidx = ty * 32 + tx
        write_pf_tile(PF2_BASE, tidx, PF2_PAL, PF2_TC)
        m.write_pf_ram(1, tidx * 2,     PF2_PAL)
        m.write_pf_ram(1, tidx * 2 + 1, PF2_TC)

# PF4: write tiles at ALL ty rows 0..31
for ty in range(32):
    for tx in range(32):
        tidx = ty * 32 + tx
        write_pf_tile(PF4_BASE, tidx, PF4_PAL, PF4_TC)
        m.write_pf_ram(3, tidx * 2,     PF4_PAL)
        m.write_pf_ram(3, tidx * 2 + 1, PF4_TC)

# GFX ROM: PF2_TC and PF4_TC — all rows solid (persistent)
for row_w in range(16):
    write_gfx_solid(PF2_TC, row_w, PF2_PEN)
    write_gfx_solid_model(PF2_TC, row_w, PF2_PEN)
    write_gfx_solid(PF4_TC, row_w, PF4_PEN)
    write_gfx_solid_model(PF4_TC, row_w, PF4_PEN)

# --- Check 1: without zoom, PF2 and PF4 render normally ---
exp_pf2_nozoom = model_bg(VPOS_SWAP, 1, 0, 0, 0)
exp_pf4_nozoom = model_bg(VPOS_SWAP, 3, 0, 0, 0)
check_bg(VPOS_SWAP, 0, 1, exp_pf2_nozoom,
         f"Y-swap: PF2 no-zoom baseline scol=0 exp={exp_pf2_nozoom:#06x}")
check_bg(VPOS_SWAP, 0, 3, exp_pf4_nozoom,
         f"Y-swap: PF4 no-zoom baseline scol=0 exp={exp_pf4_nozoom:#06x}")

# --- Now apply Y-zoom via the SWAPPED addresses ---
# PF2's Y-zoom is written to PF4's BRAM address (0x4300+scan).
# PF4's Y-zoom is written to PF2's BRAM address (0x4200+scan).
# Enable zoom for both PF2 (bit1) and PF4 (bit3): mask = 0b1010 = 0xA
PF2_ZOOM_Y_VAL = 0x40   # PF2's Y zoom value → written at 0x4300+scan
PF4_ZOOM_Y_VAL = 0x60   # PF4's Y zoom value → written at 0x4200+scan

write_zoom_enable(SCAN_SWAP, 0xA)
# word at 0x4200+scan: bits[15:8] = PF4_ZOOM_Y_VAL, bits[7:0] = PF2 X-zoom (0x00)
write_zoom_data_bram(0x4200 + SCAN_SWAP, 0x00, PF4_ZOOM_Y_VAL,
                      f"Y-swap: 0x4200 PF4-Y={PF4_ZOOM_Y_VAL:#04x} PF2-X=0x00")
# word at 0x4300+scan: bits[15:8] = PF2_ZOOM_Y_VAL, bits[7:0] = PF4 X-zoom (0x00)
write_zoom_data_bram(0x4300 + SCAN_SWAP, 0x00, PF2_ZOOM_Y_VAL,
                      f"Y-swap: 0x4300 PF2-Y={PF2_ZOOM_Y_VAL:#04x} PF4-X=0x00")

m.write_line_ram(0x0400 + SCAN_SWAP, 0xA)
m.write_line_ram(0x4200 + SCAN_SWAP, (PF4_ZOOM_Y_VAL << 8) | 0x00)
m.write_line_ram(0x4300 + SCAN_SWAP, (PF2_ZOOM_Y_VAL << 8) | 0x00)

# Expected: PF2 gets zoom_y=PF2_ZOOM_Y_VAL (from 0x4300), PF4 gets zoom_y=PF4_ZOOM_Y_VAL (from 0x4200)
exp_pf2_yswap = model_bg(VPOS_SWAP, 1, 0, 0, 0)
exp_pf4_yswap = model_bg(VPOS_SWAP, 3, 0, 0, 0)

check_bg(VPOS_SWAP, 0, 1, exp_pf2_yswap,
         f"Y-swap: PF2 zoom_y={PF2_ZOOM_Y_VAL:#04x} applied scol=0 exp={exp_pf2_yswap:#06x}")
check_bg(VPOS_SWAP, 0, 3, exp_pf4_yswap,
         f"Y-swap: PF4 zoom_y={PF4_ZOOM_Y_VAL:#04x} applied scol=0 exp={exp_pf4_yswap:#06x}")

for scol in [0, 32, 64, 128, 192, 256]:
    exp_pf2 = model_bg(VPOS_SWAP, 1, 0, 0, scol)
    exp_pf4 = model_bg(VPOS_SWAP, 3, 0, 0, scol)
    check_bg(VPOS_SWAP, scol, 1, exp_pf2, f"Y-swap: PF2 scol={scol:3d} exp={exp_pf2:#06x}")
    check_bg(VPOS_SWAP, scol, 3, exp_pf4, f"Y-swap: PF4 scol={scol:3d} exp={exp_pf4:#06x}")


# ===========================================================================
# Test group 4: Y-zoom on PF1 — zoom_y = 0x40 (zoom out)
# canvas_y = (canvas_y_raw * 0x40) >> 7 = canvas_y_raw / 2
# Rows appear stretched: source row 0 fills 2 output scanlines.
# ===========================================================================
emit({"op": "reset", "note": "reset for PF1 Y-zoom=0x40 test"})
model_reset()

# Distinctive tiles: tile code TC_BASE + (ty & 0xF) per row.
# pen = (ty & 0xF) + 1  (1..15, then wrap).
# Use small tile codes 0x00..0x0F (tc*32 max = 15*32+31 = 511 < 4096 GFX ROM).
TC_BASE_Y = 0x00

for ty in range(32):
    tc  = TC_BASE_Y + (ty & 0xF)
    pal = (ty & 0xF) * 0x10
    for tx in range(32):
        tile_idx = ty * 32 + tx
        write_pf_tile(PF1_BASE, tile_idx, pal, tc)
        m.write_pf_ram(0, tile_idx * 2,     pal)
        m.write_pf_ram(0, tile_idx * 2 + 1, tc)

# GFX ROM: solid tiles for codes 0x00..0x0F (all rows, pen = tc + 1)
for ti in range(16):
    tc_w  = TC_BASE_Y + ti
    pen_w = (ti + 1) & 0xF
    for row_w in range(16):
        write_gfx_solid(tc_w, row_w, pen_w)
        write_gfx_solid_model(tc_w, row_w, pen_w)

Y_ZOOM_VAL        = 0x40
Y_ZOOM_SCAN_START = 48
Y_ZOOM_SCAN_END   = 79

for scan in range(Y_ZOOM_SCAN_START, Y_ZOOM_SCAN_END + 1):
    write_zoom_enable(scan, 0x1)
    write_zoom_data_bram(0x4000 + scan, 0x00, Y_ZOOM_VAL,
                          f"zoom_y={Y_ZOOM_VAL:#04x} PF1 scan={scan}")
    m.write_line_ram(0x0400 + scan, 0x1)
    m.write_line_ram(0x4000 + scan, (Y_ZOOM_VAL << 8) | 0x00)

for vpos_y in [47, 55, 63, 71, 77]:
    for scol in [0, 64, 160, 256]:
        exp_yz = model_bg(vpos_y, 0, 0, 0, scol)
        check_bg(vpos_y, scol, 0, exp_yz,
                 f"Y-zoom vpos={vpos_y} scol={scol:3d} exp={exp_yz:#06x}")

# Out-of-range unzoomed reference
for scol in [0, 64, 160, 256]:
    exp_unz = model_bg(80, 0, 0, 0, scol)   # vpos=80 → next_scan=81 (no zoom)
    check_bg(80, scol, 0, exp_unz,
             f"Y-zoom out-of-range vpos=80 scol={scol:3d} exp={exp_unz:#06x}")

# Same-canvas_y property: two consecutive scanlines with zoom_y=0x40 should
# produce the same pixel when they map to the same zoomed canvas_y.
# vpos=47 → next_scan=48 → raw=48 → zoomed=(48*64)>>7=24
# vpos=48 → next_scan=49 → raw=49 → zoomed=(49*64)>>7=24
def zoomed_cy(vpos_v, zoom_y_v):
    return ((vpos_v + 1) * zoom_y_v) >> 7

for scol in [0, 128]:
    vy_a = 47;  vy_b = 48
    cy_a = zoomed_cy(vy_a, Y_ZOOM_VAL)
    cy_b = zoomed_cy(vy_b, Y_ZOOM_VAL)
    if cy_a == cy_b:
        exp_a = model_bg(vy_a, 0, 0, 0, scol)
        exp_b = model_bg(vy_b, 0, 0, 0, scol)
        assert exp_a == exp_b, \
            f"Y-zoom same canvas_y mismatch: vpos={vy_a} vs {vy_b} at scol={scol}"
        check_bg(vy_a, scol, 0, exp_a, f"Y-zoom same-cy vpos={vy_a} scol={scol}")
        check_bg(vy_b, scol, 0, exp_b, f"Y-zoom same-cy vpos={vy_b} scol={scol}")


# ===========================================================================
# Test group 5: Simultaneous X and Y zoom on PF3
# Use zoom_x=0x20, zoom_y=0x60 for scanlines 130–145.
# ===========================================================================
emit({"op": "reset", "note": "reset for simultaneous X+Y zoom on PF3 test"})
model_reset()

PF3_PAL_EVEN = 0x200;  PF3_PEN_EVEN = 0x3;  PF3_TC_EVEN = 0x10
PF3_PAL_ODD  = 0x300;  PF3_PEN_ODD  = 0xB;  PF3_TC_ODD  = 0x11

for ty in range(32):
    for tx in range(32):
        tc  = PF3_TC_EVEN if (tx % 2 == 0) else PF3_TC_ODD
        pal = PF3_PAL_EVEN if (tx % 2 == 0) else PF3_PAL_ODD
        tile_idx = ty * 32 + tx
        write_pf_tile(PF3_BASE, tile_idx, pal, tc)
        m.write_pf_ram(2, tile_idx * 2,     pal)
        m.write_pf_ram(2, tile_idx * 2 + 1, tc)

for row_r in range(16):
    write_gfx_solid(PF3_TC_EVEN, row_r, PF3_PEN_EVEN)
    write_gfx_solid(PF3_TC_ODD,  row_r, PF3_PEN_ODD)
    write_gfx_solid_model(PF3_TC_EVEN, row_r, PF3_PEN_EVEN)
    write_gfx_solid_model(PF3_TC_ODD,  row_r, PF3_PEN_ODD)

XY_ZOOM_X     = 0x20
XY_ZOOM_Y     = 0x60
XY_SCAN_START = 130
XY_SCAN_END   = 145

for scan in range(XY_SCAN_START, XY_SCAN_END + 1):
    write_zoom_enable(scan, 0x4)   # bit[2] = PF3
    write_zoom_data_bram(0x4100 + scan, XY_ZOOM_X, XY_ZOOM_Y,
                          f"zoom_xy PF3 scan={scan} x={XY_ZOOM_X:#04x} y={XY_ZOOM_Y:#04x}")
    m.write_line_ram(0x0400 + scan, 0x4)
    m.write_line_ram(0x4100 + scan, (XY_ZOOM_Y << 8) | XY_ZOOM_X)

VPOS_XY_IN  = 129   # next_scan=130 (first XY-zoom scanline)
VPOS_XY_OUT = 146   # next_scan=147 (first unzoomed scanline after range)

for scol in [0, 8, 16, 24, 32, 48, 64, 96, 128, 160, 200, 256]:
    exp_xy_in  = model_bg(VPOS_XY_IN,  2, 0, 0, scol)
    exp_xy_out = model_bg(VPOS_XY_OUT, 2, 0, 0, scol)
    check_bg(VPOS_XY_IN,  scol, 2, exp_xy_in,
             f"XY-zoom PF3 in-range  scol={scol:3d} exp={exp_xy_in:#06x}")
    check_bg(VPOS_XY_OUT, scol, 2, exp_xy_out,
             f"XY-zoom PF3 out-range scol={scol:3d} exp={exp_xy_out:#06x}")


# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step6_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors -> {out_path}")
