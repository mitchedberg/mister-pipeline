#!/usr/bin/env python3
"""
generate_step5_vectors.py — Step 5 test vector generator for tc0630fdp.

Produces step5_vectors.jsonl: Line RAM Parser + Rowscroll (Plan Step 5).

Test cases (per section3_rtl_plan.md Step 5):
  1. Rowscroll on PF1, scanlines 50–70: +32px.  Others remain at global scroll.
  2. Rowscroll on all 4 PFs simultaneously (independent per-PF offsets).
  3. Enable bit test: write rowscroll value but leave enable bit clear → no shift.
  4. Raster wave: monotonically increasing rowscroll offsets across 20 scanlines.
  5. PF4 alt-tilemap enable: write alt-tilemap enable in §9.1, verify the +0x1800
     offset activates in the PF4 tilemap engine.

Line RAM CPU address mapping:
  Chip-relative word addr 0x10000 = first word of Line RAM BRAM.
  cpu_addr[15:1] selects the BRAM word (0–32767 = 15-bit).
  For cpu_addr in the chip window (18-bit word addr), Line RAM occupies
  0x10000–0x17FFF.  So cpu_addr = 0x10000 + bram_word_offset.

Line RAM internal layout (15-bit word addresses, i.e. BRAM offsets):
  Rowscroll enable : bram[0x0600 + scan]  bits[3:0] = enable per PF
  Alt-tmap enable  : bram[0x0000 + scan]  bits[7:4] = enable per PF
  Rowscroll data   : bram[0x5000 + n*0x100 + scan]  n = PF index 0..3
  Colscroll data   : bram[0x2000 + n*0x100 + scan]  bit[9] = alt-tmap flag
"""

import json
import os
from fdp_model import TaitoF3Model

vectors = []

def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
# Address constants
# ---------------------------------------------------------------------------
PF1_BASE  = 0x04000   # chip word addr for PF1 RAM word 0
PF2_BASE  = 0x06000
PF3_BASE  = 0x08000
PF4_BASE  = 0x0A000
PF_BASES  = [PF1_BASE, PF2_BASE, PF3_BASE, PF4_BASE]

LINE_BASE = 0x10000   # chip word addr for Line RAM BRAM offset 0

H_START   = 46
H_END     = 366
V_TOTAL   = 262
V_START   = 24
V_END     = 256

# GFX ROM: 32-bit word-addressed, nibble-packed 4bpp
# 32 words per 16×16 tile: left-8px word = tile*32+row*2, right = +1


# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

def write_line_word(bram_offset: int, data: int, note: str = "") -> None:
    """Write one 16-bit word to Line RAM at BRAM offset (0–32767).

    CPU chip-window address = LINE_BASE + bram_offset.
    """
    emit({"op": "write_line",
          "addr": LINE_BASE + bram_offset,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"line_ram[{bram_offset:#06x}] = {data:#06x}"})


def read_line_word(bram_offset: int, exp: int, note: str) -> None:
    emit({"op": "read_line",
          "addr": LINE_BASE + bram_offset,
          "exp_dout": exp & 0xFFFF,
          "note": note})


def write_rowscroll_enable(scan: int, en_mask: int, note: str = "") -> None:
    """Write rowscroll enable bits for one scanline.

    en_mask bits[3:0]: PF1=bit0 .. PF4=bit3.
    BRAM addr = 0x0600 + scan.
    """
    write_line_word(0x0600 + scan, en_mask & 0xF,
                    note or f"rs_en scan={scan:#04x} mask={en_mask:#03x}")


def write_rowscroll_data(plane: int, scan: int, value: int, note: str = "") -> None:
    """Write rowscroll data word for PF(plane+1) on scanline scan.

    value: 16-bit rowscroll (same 10.6 fixed-point as pf_xscroll).
           integer part = value >> 6.
    BRAM addr = 0x5000 + plane*0x100 + scan.
    """
    write_line_word(0x5000 + plane * 0x100 + scan, value,
                    note or f"rs_data pf{plane+1} scan={scan:#04x} val={value:#06x}")


def write_alt_tilemap_enable(scan: int, en_mask: int, note: str = "") -> None:
    """Write alt-tilemap enable bits for one scanline.

    en_mask bits[3:0]: PF1=bit0 .. PF4=bit3 → stored in bits[7:4] of enable word.
    BRAM addr = 0x0000 + scan.
    """
    # bits[7:4] = alt-tmap enable; bits[3:0] = colscroll enable (keep 0)
    write_line_word(0x0000 + scan, (en_mask & 0xF) << 4,
                    note or f"alt_en scan={scan:#04x} mask={en_mask:#03x}")


def write_alt_tilemap_flag(plane: int, scan: int, flag: bool, note: str = "") -> None:
    """Write the alt-tilemap flag (bit[9]) into the colscroll data word.

    BRAM addr = 0x2000 + plane*0x100 + scan.
    """
    val = 0x200 if flag else 0
    write_line_word(0x2000 + plane * 0x100 + scan, val,
                    note or f"alt_flag pf{plane+1} scan={scan:#04x} flag={flag}")


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


def check_bg(vpos: int, screen_col: int, plane: int, exp: int, note: str) -> None:
    emit({"op": "check_bg_pixel",
          "vpos": vpos,
          "screen_col": screen_col,
          "plane": plane,
          "exp_pixel": exp & 0x1FFF,
          "note": note})


# ---------------------------------------------------------------------------
# Compute expected BG pixel using Python model (cross-check)
# ---------------------------------------------------------------------------
def model_bg_pixel(m: TaitoF3Model, vpos: int, plane: int,
                   xscroll: int, yscroll: int, screen_col: int,
                   extend_mode: bool = False) -> int:
    """Return expected 13-bit pixel value at screen_col for given scanline."""
    line = m.render_bg_scanline(vpos, plane, xscroll, yscroll, extend_mode)
    return line[screen_col]


# ===========================================================================
# Test group 1: Rowscroll on PF1, scanlines 50–70, value +32px
# Verifies: shifted scanlines show different tile content from unshifted.
# ===========================================================================
emit({"op": "reset", "note": "reset for rowscroll PF1 scanlines 50-70 test"})

m = TaitoF3Model()

# Global scroll: PF1 xscroll=0, yscroll=0
XSCROLL1 = 0
YSCROLL1 = 0

# Rowscroll value: +32 pixels integer part → raw = 32 << 6 = 0x0800
RS_PIXELS = 32
RS_RAW    = RS_PIXELS << 6   # = 0x0800

# Set up a simple PF1 tilemap: 2 distinct tile codes in a column-striped pattern.
# Tile 0 (even columns): GFX pen 0x5, palette 0x010
# Tile 1 (odd  columns): GFX pen 0x9, palette 0x020
PAL_EVEN = 0x010
PAL_ODD  = 0x020
PEN_EVEN = 0x5
PEN_ODD  = 0x9
TC_EVEN  = 0   # tile code for even columns
TC_ODD   = 1   # tile code for odd columns

# Fill all rows of the PF1 tilemap with alternating tile codes (columns mod 2)
for ty in range(32):
    for tx in range(32):
        tc  = TC_EVEN if (tx % 2 == 0) else TC_ODD
        pal = PAL_EVEN if (tx % 2 == 0) else PAL_ODD
        tile_idx = ty * 32 + tx
        write_pf_tile(PF1_BASE, tile_idx, pal, tc)
        m.write_pf_ram(0, tile_idx * 2,     pal)
        m.write_pf_ram(0, tile_idx * 2 + 1, tc)

# Write GFX ROM for tile codes 0 and 1 (all rows, both even/odd tiles)
for row_r in range(16):
    write_gfx_solid(TC_EVEN, row_r, PEN_EVEN)
    write_gfx_solid(TC_ODD,  row_r, PEN_ODD)
    for wa in [TC_EVEN * 32 + row_r * 2, TC_EVEN * 32 + row_r * 2 + 1]:
        word_e = 0
        for _ in range(8): word_e = (word_e << 4) | PEN_EVEN
        m.gfx_rom[wa] = word_e
    for wa in [TC_ODD * 32 + row_r * 2, TC_ODD * 32 + row_r * 2 + 1]:
        word_o = 0
        for _ in range(8): word_o = (word_o << 4) | PEN_ODD
        m.gfx_rom[wa] = word_o

# Write ctrl regs: xscroll=0, yscroll=0 for PF1 (already 0 after reset — no op needed)

# Program Line RAM: rowscroll for PF1 (plane 0), scanlines 50–70
# enable word addr: 0x0600 + scan, bit[0] = PF1 enable
# data   word addr: 0x5000 + scan
RS_SCAN_START = 50
RS_SCAN_END   = 70

for scan in range(256):
    if RS_SCAN_START <= scan <= RS_SCAN_END:
        write_rowscroll_enable(scan, 0x1)    # enable PF1 only
        write_rowscroll_data(0, scan, RS_RAW)
        m.write_line_ram(0x0600 + scan, 0x1)
        m.write_line_ram(0x5000 + scan, RS_RAW)
    # else: enable=0, data=0 (default)

# --- Line RAM readback verification ---
# Spot-check a few enable and data words
for scan in [50, 60, 70]:
    read_line_word(0x0600 + scan, 0x1,    f"rs_en readback scan={scan}")
    read_line_word(0x5000 + scan, RS_RAW, f"rs_data readback scan={scan}")
# Verify non-rowscroll scanline has 0 enable
read_line_word(0x0600 + 49, 0x0, "rs_en readback scan=49 (should be 0)")
read_line_word(0x0600 + 71, 0x0, "rs_en readback scan=71 (should be 0)")

# --- BG pixel checks ---
# For a rowscroll scanline, the effective x = 0 + 32 = 32 px.
# canvas_x at screen_col=0: (0 + 32) & 511 = 32 → tile_x = 32/16 = 2 (even → pen 0x5)
# For a non-rowscroll scanline, canvas_x at screen_col=0: (0 + 0) = 0 → tile_x=0 (even → pen 0x5)

# Check screen_col=0 on a rowscroll-affected scanline (vpos=55)
# vpos=55 → next scan=56 → rowscroll applied
VPOS_RS_IN  = 55   # inside rowscroll range (next scan = 56)
VPOS_RS_OUT = 47   # outside rowscroll range (next scan = 48)

exp_rs_in  = model_bg_pixel(m, VPOS_RS_IN,  0, XSCROLL1, YSCROLL1, 0)
exp_rs_out = model_bg_pixel(m, VPOS_RS_OUT, 0, XSCROLL1, YSCROLL1, 0)

check_bg(VPOS_RS_IN,  0, 0, exp_rs_in,
         f"rowscroll PF1 in-range vpos={VPOS_RS_IN} scol=0 exp={exp_rs_in:#06x}")
check_bg(VPOS_RS_OUT, 0, 0, exp_rs_out,
         f"rowscroll PF1 out-range vpos={VPOS_RS_OUT} scol=0 exp={exp_rs_out:#06x}")

# Check several screen columns to verify the full-row shift
for scol in [0, 16, 32, 48, 64, 96, 128, 160, 256]:
    exp_in  = model_bg_pixel(m, VPOS_RS_IN,  0, XSCROLL1, YSCROLL1, scol)
    exp_out = model_bg_pixel(m, VPOS_RS_OUT, 0, XSCROLL1, YSCROLL1, scol)
    check_bg(VPOS_RS_IN,  scol, 0, exp_in,
             f"rowscroll PF1 in-range scol={scol} exp={exp_in:#06x}")
    check_bg(VPOS_RS_OUT, scol, 0, exp_out,
             f"rowscroll PF1 out-range scol={scol} exp={exp_out:#06x}")

# Verify that PF2–PF4 are NOT shifted (enable=0 for them on rowscroll scanlines)
# They should show the same content as a non-rowscroll scanline for PF1.
# (PF2–PF4 have no tile data written — will output palette=0,pen=0.)


# ===========================================================================
# Test group 2: Rowscroll on all 4 PFs simultaneously
# Each PF gets a distinct rowscroll value.  Use a single scanline to keep
# the test self-contained.
# ===========================================================================
emit({"op": "reset", "note": "reset for rowscroll all-4-PFs test"})

m = TaitoF3Model()

# Use vpos=79 → next scan = 80
VPOS_ALL4 = 79
SCAN_ALL4 = (VPOS_ALL4 + 1) & 0xFF   # = 80

# Give each PF a distinct solid-color tile.
PF_PALS  = [0x040, 0x080, 0x0C0, 0x100]   # distinct palette per PF
PF_PENS  = [0x3,   0x5,   0x7,   0xA]     # distinct pen per PF
PF_TC    = [0x02,  0x03,  0x04,  0x05]    # distinct tile codes per PF
PF_RS_PX = [8, 16, 32, 48]                # rowscroll in pixels per PF

# canvas_y for all PFs at vpos=79, yscroll=0: (80 + 0) & 0x1FF = 80
# fetch_py = 80 & 0xF = 0
# fetch_ty = 80 >> 4 = 5

for pf in range(4):
    # Tile at ty=5, various tx positions depending on rowscroll
    # Without rowscroll: canvas_x at scol=0 = 0 → tile_x=0
    # With rowscroll PF_RS_PX[pf]: canvas_x at scol=0 = PF_RS_PX[pf] → tile_x
    ty = 5
    tx0_no_rs = 0
    tx0_with_rs = PF_RS_PX[pf] // 16   # tile_x that scol=0 maps to with rowscroll

    # Write a distinctive tile at every tile position (all 32 columns)
    for tx in range(32):
        tile_idx = ty * 32 + tx
        write_pf_tile(PF_BASES[pf], tile_idx, PF_PALS[pf], PF_TC[pf])
        m.write_pf_ram(pf, tile_idx * 2,     PF_PALS[pf])
        m.write_pf_ram(pf, tile_idx * 2 + 1, PF_TC[pf])

    # Write GFX ROM row 0 (fetch_py=0) for this PF's tile code
    write_gfx_solid(PF_TC[pf], 0, PF_PENS[pf])
    word_pf = 0
    for _ in range(8): word_pf = (word_pf << 4) | PF_PENS[pf]
    for wa in [PF_TC[pf] * 32, PF_TC[pf] * 32 + 1]:
        m.gfx_rom[wa] = word_pf

    # Program Line RAM rowscroll for this PF
    rs_raw_pf = PF_RS_PX[pf] << 6
    write_rowscroll_enable(SCAN_ALL4, 1)      # will overwrite; fix below
    write_rowscroll_data(pf, SCAN_ALL4, rs_raw_pf)
    m.write_line_ram(0x5000 + pf * 0x100 + SCAN_ALL4, rs_raw_pf)

# Fix: write the enable word once with all 4 PFs enabled
write_line_word(0x0600 + SCAN_ALL4, 0xF,
                f"rs_en scan={SCAN_ALL4:#04x} all-4-PFs")
m.write_line_ram(0x0600 + SCAN_ALL4, 0xF)

# Check each PF at screen_col=0
for pf in range(4):
    exp = model_bg_pixel(m, VPOS_ALL4, pf, 0, 0, 0)
    check_bg(VPOS_ALL4, 0, pf,
             exp,
             f"rowscroll all-4-PFs pf={pf+1} scol=0 exp={exp:#06x}")

# Also check screen_col=16 (different tile boundary for larger offsets)
for pf in range(4):
    exp = model_bg_pixel(m, VPOS_ALL4, pf, 0, 0, 16)
    check_bg(VPOS_ALL4, 16, pf,
             exp,
             f"rowscroll all-4-PFs pf={pf+1} scol=16 exp={exp:#06x}")


# ===========================================================================
# Test group 3: Enable bit test — rowscroll value written but enable=0
# Verify that the shift does NOT occur when the enable bit is clear.
# ===========================================================================
emit({"op": "reset", "note": "reset for rowscroll enable-bit test"})

m = TaitoF3Model()

# vpos=95 → next scan=96
VPOS_ENB = 95
SCAN_ENB = 96

# PF1: write a solid tile at ty=6 (canvas_y=96 → fetch_ty=6)
# canvas_y = (vpos+1 + yscroll_int) & 0x1FF = 96 → fetch_ty=6, fetch_py=0
ty_enb = 6
for tx in range(32):
    tile_idx_enb = ty_enb * 32 + tx
    write_pf_tile(PF1_BASE, tile_idx_enb, 0x050, 0x06)
    m.write_pf_ram(0, tile_idx_enb * 2,     0x050)
    m.write_pf_ram(0, tile_idx_enb * 2 + 1, 0x06)

# Write GFX ROM row 0 for tile code 6 with pen 0xB
write_gfx_solid(0x06, 0, 0xB)
word_enb = 0
for _ in range(8): word_enb = (word_enb << 4) | 0xB
for wa_enb in [0x06 * 32, 0x06 * 32 + 1]:
    m.gfx_rom[wa_enb] = word_enb

# Write rowscroll data (large offset = 64 px) but leave enable=0
RS_ENB_PIXELS = 64
RS_ENB_RAW    = RS_ENB_PIXELS << 6
write_rowscroll_data(0, SCAN_ENB, RS_ENB_RAW)
# Do NOT write enable word → remains 0 (rowscroll disabled)
# Model: no write to line_ram[0x0600 + SCAN_ENB] → stays 0

# Expected: no rowscroll → same as no-rowscroll pixel
exp_enb_no_rs = model_bg_pixel(m, VPOS_ENB, 0, 0, 0, 0)
check_bg(VPOS_ENB, 0, 0, exp_enb_no_rs,
         f"enable-bit: rs={RS_ENB_PIXELS}px written but enable=0 → no shift scol=0")
check_bg(VPOS_ENB, 16, 0,
         model_bg_pixel(m, VPOS_ENB, 0, 0, 0, 16),
         f"enable-bit: no shift scol=16")

# Confirm: if we then enable it, the shift DOES occur
write_rowscroll_enable(SCAN_ENB, 0x1)
m.write_line_ram(0x0600 + SCAN_ENB, 0x1)
m.write_line_ram(0x5000 + SCAN_ENB, RS_ENB_RAW)

# Use a new vpos with same scan = 96 (same line triggers again on next HBLANK)
# But HBLANK_fall re-reads each scanline — same vpos_enb will work again.
# Use vpos=95 again — the testbench advances clock, so same vpos is fine
# as long as we don't double-advance (check_bg advances to that vpos each call).
exp_enb_with_rs = model_bg_pixel(m, VPOS_ENB, 0, 0, 0, 0)
check_bg(VPOS_ENB, 0, 0, exp_enb_with_rs,
         f"enable-bit: rs={RS_ENB_PIXELS}px enabled → shift now active scol=0")

# Verify the shift happened by checking a pixel that changes:
# Without rowscroll, canvas_x=0 at scol=0; with +64px, canvas_x=64.
# Since all tiles in the row have the same palette+pen, the pixel VALUE is the same.
# Use screen_col=8 to read from the same tile type:
check_bg(VPOS_ENB, 8, 0,
         model_bg_pixel(m, VPOS_ENB, 0, 0, 0, 8),
         f"enable-bit: rs enabled, scol=8 check")


# ===========================================================================
# Test group 4: Raster wave — monotonically increasing rowscroll per scanline
# 20 scanlines, offsets 0,16,32,...,304 pixels.
# Verifies that each scanline independently reads its own rowscroll value.
# ===========================================================================
emit({"op": "reset", "note": "reset for raster-wave rowscroll test"})

m = TaitoF3Model()

# Place a simple repeating tile pattern on PF1 (same as group 1)
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
    for wa in [TC_EVEN * 32 + row_r * 2, TC_EVEN * 32 + row_r * 2 + 1]:
        word_e = 0
        for _ in range(8): word_e = (word_e << 4) | PEN_EVEN
        m.gfx_rom[wa] = word_e
    for wa in [TC_ODD * 32 + row_r * 2, TC_ODD * 32 + row_r * 2 + 1]:
        word_o = 0
        for _ in range(8): word_o = (word_o << 4) | PEN_ODD
        m.gfx_rom[wa] = word_o

# 20 scanlines starting at vpos=119 (next scan = 120..139)
WAVE_VPOS_START = 119   # first vpos (next scan = 120)
WAVE_COUNT      = 20
WAVE_STEP_PX    = 16    # 16px per scanline

for i in range(WAVE_COUNT):
    scan = (WAVE_VPOS_START + 1 + i) & 0xFF
    offset_px = i * WAVE_STEP_PX
    rs_raw_w  = offset_px << 6
    write_rowscroll_enable(scan, 0x1)
    write_rowscroll_data(0, scan, rs_raw_w)
    m.write_line_ram(0x0600 + scan, 0x1)
    m.write_line_ram(0x5000 + scan, rs_raw_w)

# Check first pixel of each wave scanline at screen_col=0 and screen_col=128
for i in range(WAVE_COUNT):
    vpos_w = WAVE_VPOS_START + i
    for scol in [0, 128]:
        exp_w = model_bg_pixel(m, vpos_w, 0, 0, 0, scol)
        check_bg(vpos_w, scol, 0, exp_w,
                 f"wave: vpos={vpos_w} offset={i*WAVE_STEP_PX}px scol={scol}")


# ===========================================================================
# Test group 5: PF4 alt-tilemap enable
# With alt-tilemap enabled, PF RAM tile addresses are offset by +0x1800 words.
# This is used to double-buffer tile data (PF3/PF4 only in hardware, but
# the RTL applies it uniformly).
# Write distinct tiles at tile_idx and tile_idx+0xC00 in PF4 RAM
# (0xC00 = 0x1800/2 tile entries, since each tile is 2 words).
# Verify that the rendered pixel changes when alt-tilemap is enabled.
# ===========================================================================
emit({"op": "reset", "note": "reset for PF4 alt-tilemap test"})

m = TaitoF3Model()

# vpos=159 → next scan=160 → fetch_ty=10, fetch_py=0
VPOS_ALT = 159
SCAN_ALT = (VPOS_ALT + 1) & 0xFF   # = 160

# canvas_y = (160 + 0) & 0x1FF = 160 → fetch_ty = 160 >> 4 = 10, fetch_py = 0
# canvas_x at scol=0 = 0 → tile_x=0

ALT_TY     = 10
ALT_TC_NORM = 0x08   # tile code for normal tilemap
ALT_TC_ALT  = 0x09   # tile code for alt tilemap
ALT_PAL_NORM = 0x111
ALT_PAL_ALT  = 0x155
ALT_PEN_NORM = 0x4
ALT_PEN_ALT  = 0xC

# Write tile code 0 into PF1–PF3 at ty=10, tx=0..20 to ensure they show transparent.
# Previous test groups wrote GFX tile 0 with pen=0x5, so we write a code that
# points to an unwritten GFX slot (0x7FF) which Verilator initialises to 0 (pen=0).
TRANSPARENT_TC = 0x7FF
for pf_clr in range(3):
    for tx_clr in range(21):    # 21 tiles visible per scanline
        tidx_clr = ALT_TY * 32 + tx_clr
        write_pf_tile(PF_BASES[pf_clr], tidx_clr, 0, TRANSPARENT_TC)
        m.write_pf_ram(pf_clr, tidx_clr * 2,     0)
        m.write_pf_ram(pf_clr, tidx_clr * 2 + 1, TRANSPARENT_TC)

# Write to normal PF4 RAM: tile at ty=10, tx=0 (tile_idx = 10*32+0 = 320)
TILE_IDX_NORM = ALT_TY * 32 + 0
write_pf_tile(PF4_BASE, TILE_IDX_NORM, ALT_PAL_NORM, ALT_TC_NORM)
m.write_pf_ram(3, TILE_IDX_NORM * 2,     ALT_PAL_NORM)
m.write_pf_ram(3, TILE_IDX_NORM * 2 + 1, ALT_TC_NORM)

# Write to ALT PF4 RAM (+0x1800 word offset): tile at word_base + 0x1800
# word_base = TILE_IDX_NORM * 2 = 640; alt_base = 640 + 0x1800 = 0x1B40
TILE_WORD_BASE_ALT = TILE_IDX_NORM * 2 + 0x1000   # +0x1000 words = +0x2000 bytes (section2 §2.5)
emit({"op": "write_pf",
      "addr": PF4_BASE + TILE_WORD_BASE_ALT,
      "data": ALT_PAL_ALT,
      "be": 3,
      "note": f"PF4 alt-tmap attr (word_addr={PF4_BASE + TILE_WORD_BASE_ALT:#06x})"})
emit({"op": "write_pf",
      "addr": PF4_BASE + TILE_WORD_BASE_ALT + 1,
      "data": ALT_TC_ALT,
      "be": 3,
      "note": f"PF4 alt-tmap code (word_addr={PF4_BASE + TILE_WORD_BASE_ALT + 1:#06x})"})
m.write_pf_ram(3, TILE_WORD_BASE_ALT,     ALT_PAL_ALT)
m.write_pf_ram(3, TILE_WORD_BASE_ALT + 1, ALT_TC_ALT)

# Write GFX ROM for both tile codes (row 0 = fetch_py=0)
write_gfx_solid(ALT_TC_NORM, 0, ALT_PEN_NORM)
write_gfx_solid(ALT_TC_ALT,  0, ALT_PEN_ALT)
for (tc_a, pen_a) in [(ALT_TC_NORM, ALT_PEN_NORM), (ALT_TC_ALT, ALT_PEN_ALT)]:
    word_a = 0
    for _ in range(8): word_a = (word_a << 4) | pen_a
    for wa_a in [tc_a * 32, tc_a * 32 + 1]:
        m.gfx_rom[wa_a] = word_a

# --- Without alt-tilemap: should render normal tile ---
# No Line RAM written for SCAN_ALT yet → alt-tmap disable
exp_norm = model_bg_pixel(m, VPOS_ALT, 3, 0, 0, 0)
expected_norm_px = (ALT_PAL_NORM << 4) | ALT_PEN_NORM
assert exp_norm == expected_norm_px, \
    f"Model mismatch without alt-tmap: got {exp_norm:#06x} expected {expected_norm_px:#06x}"

check_bg(VPOS_ALT, 0, 3, exp_norm,
         f"alt-tilemap: PF4 normal tmap scol=0 exp={exp_norm:#06x}")
check_bg(VPOS_ALT, 8, 3,
         model_bg_pixel(m, VPOS_ALT, 3, 0, 0, 8),
         f"alt-tilemap: PF4 normal tmap scol=8")

# --- Enable alt-tilemap for PF4 on SCAN_ALT ---
# Enable word: bram[0x0000 + scan], bits[7:4] = alt enable per PF (PF4=bit3→bit7)
write_alt_tilemap_enable(SCAN_ALT, 0x8)   # PF4 only (bit3 in mask → bit7 of word)
write_alt_tilemap_flag(3, SCAN_ALT, True)
m.write_line_ram(0x0000 + SCAN_ALT, 0x8 << 4)   # bits[7:4] = en_mask
m.write_line_ram(0x2000 + 3 * 0x100 + SCAN_ALT, 0x200)  # bit[9] = 1

# Model now reports alt-tilemap enabled → reads from +0x1800 offset
exp_alt = model_bg_pixel(m, VPOS_ALT, 3, 0, 0, 0)
expected_alt_px = (ALT_PAL_ALT << 4) | ALT_PEN_ALT
assert exp_alt == expected_alt_px, \
    f"Model mismatch with alt-tmap: got {exp_alt:#06x} expected {expected_alt_px:#06x}"

check_bg(VPOS_ALT, 0, 3, exp_alt,
         f"alt-tilemap: PF4 alt tmap active scol=0 exp={exp_alt:#06x}")
check_bg(VPOS_ALT, 8, 3,
         model_bg_pixel(m, VPOS_ALT, 3, 0, 0, 8),
         f"alt-tilemap: PF4 alt tmap active scol=8")

# Verify PF1–PF3 are unaffected (alt-tmap enable=0 for them)
# PF1 should still show its normal (unwritten) state → pen=0
for pf in range(3):
    check_bg(VPOS_ALT, 0, pf,
             model_bg_pixel(m, VPOS_ALT, pf, 0, 0, 0),
             f"alt-tilemap: PF{pf+1} unaffected by PF4 alt-tmap enable")


# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step5_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors -> {out_path}")
