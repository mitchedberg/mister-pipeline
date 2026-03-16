#!/usr/bin/env python3
"""
generate_step7_vectors.py — Step 7 test vector generator for tc0630fdp.

Produces step7_vectors.jsonl: Colscroll and Palette Addition (Plan Step 7).

Test cases (per section3_rtl_plan.md Step 7):
  1. PF3 colscroll: set colscroll = 64 for scanlines 10–30. Verify horizontal
     offset applies to PF3 on those scanlines only. Verify PF4 is not affected.
  2. PF4 colscroll independence from PF3.
  3. PF1 palette addition: set pal_add = 16 for all scanlines. Verify every
     tile's palette index is incremented by 1 (pal_add / 16 = 1 palette line).
  4. Palette cycling: write a sequence of increasing pal_add values per scanline
     (0, 16, 32...). Verify a color-gradient band effect across the screen.
  5. Colscroll + rowscroll simultaneously active on PF3. Verify additive effect.

Line RAM address layout for Step 7:
  Colscroll enable  : byte 0x0000 → BRAM word 0x0000  (bits[3:0] = en per PF for colscroll)
  Colscroll data    : byte 0x4000 → BRAM word 0x2000  (stride 0x100 per PF)
                      Format: bits[8:0] = colscroll pixel offset
  Pal-add enable    : byte 0x0A00 → BRAM word 0x0500  (bits[3:0] = en per PF)
  Pal-add data      : byte 0x9000 → BRAM word 0x4800  (stride 0x100 per PF)
                      Format: raw 16-bit value = palette_line_offset * 16

Note: colscroll enable shares the 0x0000 word with alt-tilemap enable.
  bits[3:0] = colscroll enable (PF1=bit0..PF4=bit3) — this is the colscroll path
  bits[7:4] = alt-tilemap enable (PF1=bit4..PF4=bit7)
"""

import json
import os
from fdp_model import TaitoF3Model

vectors = []


def emit(v: dict):
    vectors.append(v)


# ---------------------------------------------------------------------------
# Address constants (match prior generators)
# ---------------------------------------------------------------------------
PF1_BASE = 0x04000
PF2_BASE = 0x06000
PF3_BASE = 0x08000
PF4_BASE = 0x0A000
PF_BASES = [PF1_BASE, PF2_BASE, PF3_BASE, PF4_BASE]

LINE_BASE = 0x10000   # chip word addr for Line RAM BRAM offset 0


# ---------------------------------------------------------------------------
# Single persistent model — GFX ROM state survives across resets.
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
# Low-level helpers
# ---------------------------------------------------------------------------

def write_line_word(bram_offset: int, data: int, note: str = "") -> None:
    emit({"op": "write_line",
          "addr": LINE_BASE + bram_offset,
          "data": data & 0xFFFF,
          "be": 3,
          "note": note or f"line_ram[{bram_offset:#06x}] = {data:#06x}"})


def write_colscroll_enable(scan: int, en_mask: int, note: str = "") -> None:
    """Write colscroll enable bits for one scanline.

    en_mask bits[3:0]: PF1=bit0 .. PF4=bit3 (colscroll enable).
    BRAM addr = 0x0000 + scan.
    Note: this word is shared with alt-tilemap enable (bits[7:4]).
    """
    write_line_word(0x0000 + scan, en_mask & 0xFF,
                    note or f"colscroll_en scan={scan:#04x} mask={en_mask:#03x}")


def write_colscroll_data(plane: int, scan: int, colscroll: int,
                          note: str = "") -> None:
    """Write colscroll data for one PF/scanline.

    plane: 0..3 (PF1..PF4)
    colscroll: 9-bit pixel offset (0..511)
    BRAM addr = 0x2000 + plane*0x100 + scan
    Format: bits[8:0] = colscroll. Also set bit[9]=0 (no alt-tilemap).
    """
    base = [0x2000, 0x2100, 0x2200, 0x2300][plane]
    write_line_word(base + scan, colscroll & 0x1FF,
                    note or f"colscroll pf={plane+1} scan={scan:#04x} val={colscroll:#05x}")


def write_pal_add_enable(scan: int, en_mask: int, note: str = "") -> None:
    """Write palette addition enable bits for one scanline.

    en_mask bits[3:0]: PF1=bit0 .. PF4=bit3.
    BRAM addr = 0x0500 + scan.
    """
    write_line_word(0x0500 + scan, en_mask & 0xF,
                    note or f"pal_add_en scan={scan:#04x} mask={en_mask:#03x}")


def write_pal_add_data(plane: int, scan: int, pal_lines: int,
                        note: str = "") -> None:
    """Write palette addition data for one PF/scanline.

    plane: 0..3
    pal_lines: palette-line offset (0..511) — stored as pal_lines * 16 in Line RAM.
    BRAM addr = 0x4800 + plane*0x100 + scan
    Format: raw 16-bit value = pal_lines * 16.
    """
    base = [0x4800, 0x4900, 0x4A00, 0x4B00][plane]
    raw = (pal_lines & 0x1FF) * 16
    write_line_word(base + scan, raw,
                    note or f"pal_add pf={plane+1} scan={scan:#04x} lines={pal_lines} raw={raw:#06x}")


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
    """Fill one GFX ROM row with a solid pen value."""
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


def write_gfx_solid_model(tile_code: int, row: int, pen: int) -> None:
    """Write GFX ROM row in model only (no vector emit)."""
    nibble = pen & 0xF
    word = 0
    for _ in range(8):
        word = (word << 4) | nibble
    for wa in [tile_code * 32 + row * 2, tile_code * 32 + row * 2 + 1]:
        m.gfx_rom[wa] = word


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
# Test group 1: PF3 colscroll = 64 pixels for scanlines 10–30
# colscroll shifts the effective_x of PF3 by 64 pixels on those scanlines.
# PF4 has no colscroll — must remain unaffected.
# ===========================================================================
emit({"op": "reset", "note": "reset for PF3 colscroll=64 scanlines 10-30 test"})
model_reset()

# Alternating tile pattern on PF3 and PF4 (distinct pen/palette per PF)
PF3_PAL_EVEN = 0x030;  PF3_PEN_EVEN = 0x3;  PF3_TC_EVEN = 0x02
PF3_PAL_ODD  = 0x031;  PF3_PEN_ODD  = 0xC;  PF3_TC_ODD  = 0x03
PF4_PAL_EVEN = 0x040;  PF4_PEN_EVEN = 0x5;  PF4_TC_EVEN = 0x04
PF4_PAL_ODD  = 0x041;  PF4_PEN_ODD  = 0xA;  PF4_TC_ODD  = 0x05

for ty in range(32):
    for tx in range(32):
        t3 = PF3_TC_EVEN if (tx % 2 == 0) else PF3_TC_ODD
        p3 = PF3_PAL_EVEN if (tx % 2 == 0) else PF3_PAL_ODD
        t4 = PF4_TC_EVEN if (tx % 2 == 0) else PF4_TC_ODD
        p4 = PF4_PAL_EVEN if (tx % 2 == 0) else PF4_PAL_ODD
        tidx = ty * 32 + tx
        write_pf_tile(PF3_BASE, tidx, p3, t3)
        m.write_pf_ram(2, tidx * 2, p3)
        m.write_pf_ram(2, tidx * 2 + 1, t3)
        write_pf_tile(PF4_BASE, tidx, p4, t4)
        m.write_pf_ram(3, tidx * 2, p4)
        m.write_pf_ram(3, tidx * 2 + 1, t4)

for row_r in range(16):
    write_gfx_solid(PF3_TC_EVEN, row_r, PF3_PEN_EVEN)
    write_gfx_solid(PF3_TC_ODD,  row_r, PF3_PEN_ODD)
    write_gfx_solid(PF4_TC_EVEN, row_r, PF4_PEN_EVEN)
    write_gfx_solid(PF4_TC_ODD,  row_r, PF4_PEN_ODD)
    write_gfx_solid_model(PF3_TC_EVEN, row_r, PF3_PEN_EVEN)
    write_gfx_solid_model(PF3_TC_ODD,  row_r, PF3_PEN_ODD)
    write_gfx_solid_model(PF4_TC_EVEN, row_r, PF4_PEN_EVEN)
    write_gfx_solid_model(PF4_TC_ODD,  row_r, PF4_PEN_ODD)

# Set colscroll = 64 pixels for PF3 (plane=2) on scanlines 10–30
CS3_VAL = 64
CS3_SCAN_START = 10
CS3_SCAN_END   = 30

for scan in range(CS3_SCAN_START, CS3_SCAN_END + 1):
    write_colscroll_enable(scan, 0x4)   # bit[2] = PF3 colscroll enable
    write_colscroll_data(2, scan, CS3_VAL,
                          f"colscroll PF3 scan={scan} val={CS3_VAL}")
    m.write_line_ram(0x0000 + scan, 0x4)
    m.write_line_ram(0x2200 + scan, CS3_VAL)

# vpos = 9  → next_scan = 10 (first colscrolled scanline)
# vpos = 30 → next_scan = 31 (first un-colscrolled scanline after range)
VPOS_CS_IN  = 9
VPOS_CS_OUT = 30

for scol in [0, 8, 16, 24, 32, 48, 64, 96, 128, 160, 192, 256]:
    exp_pf3_in  = model_bg(VPOS_CS_IN,  2, 0, 0, scol)
    exp_pf3_out = model_bg(VPOS_CS_OUT, 2, 0, 0, scol)
    exp_pf4_in  = model_bg(VPOS_CS_IN,  3, 0, 0, scol)
    exp_pf4_out = model_bg(VPOS_CS_OUT, 3, 0, 0, scol)
    check_bg(VPOS_CS_IN,  scol, 2, exp_pf3_in,
             f"colscroll PF3 in-range  scol={scol:3d} exp={exp_pf3_in:#06x}")
    check_bg(VPOS_CS_OUT, scol, 2, exp_pf3_out,
             f"colscroll PF3 out-range scol={scol:3d} exp={exp_pf3_out:#06x}")
    check_bg(VPOS_CS_IN,  scol, 3, exp_pf4_in,
             f"colscroll PF4 unaffected in-range  scol={scol:3d} exp={exp_pf4_in:#06x}")
    check_bg(VPOS_CS_OUT, scol, 3, exp_pf4_out,
             f"colscroll PF4 unaffected out-range scol={scol:3d} exp={exp_pf4_out:#06x}")


# ===========================================================================
# Test group 2: PF4 colscroll independence from PF3
# PF3 has colscroll=32, PF4 has colscroll=128, both enabled separately.
# Verify each PF only shifts by its own amount.
# ===========================================================================
emit({"op": "reset", "note": "reset for PF3/PF4 independent colscroll test"})
model_reset()

# Reuse same tile data (GFX ROM persistent, re-write PF RAMs)
for ty in range(32):
    for tx in range(32):
        t3 = PF3_TC_EVEN if (tx % 2 == 0) else PF3_TC_ODD
        p3 = PF3_PAL_EVEN if (tx % 2 == 0) else PF3_PAL_ODD
        t4 = PF4_TC_EVEN if (tx % 2 == 0) else PF4_TC_ODD
        p4 = PF4_PAL_EVEN if (tx % 2 == 0) else PF4_PAL_ODD
        tidx = ty * 32 + tx
        write_pf_tile(PF3_BASE, tidx, p3, t3)
        m.write_pf_ram(2, tidx * 2, p3)
        m.write_pf_ram(2, tidx * 2 + 1, t3)
        write_pf_tile(PF4_BASE, tidx, p4, t4)
        m.write_pf_ram(3, tidx * 2, p4)
        m.write_pf_ram(3, tidx * 2 + 1, t4)

CS3_INDEP = 32
CS4_INDEP = 128
VPOS_INDEP = 50
SCAN_INDEP = 51

# Enable colscroll for both PF3 (bit2) and PF4 (bit3): mask = 0b1100 = 0xC
write_colscroll_enable(SCAN_INDEP, 0xC)
write_colscroll_data(2, SCAN_INDEP, CS3_INDEP,
                      f"indep colscroll PF3 val={CS3_INDEP}")
write_colscroll_data(3, SCAN_INDEP, CS4_INDEP,
                      f"indep colscroll PF4 val={CS4_INDEP}")
m.write_line_ram(0x0000 + SCAN_INDEP, 0xC)
m.write_line_ram(0x2200 + SCAN_INDEP, CS3_INDEP)
m.write_line_ram(0x2300 + SCAN_INDEP, CS4_INDEP)

for scol in [0, 16, 32, 64, 96, 128, 160, 192, 256]:
    exp_pf3 = model_bg(VPOS_INDEP, 2, 0, 0, scol)
    exp_pf4 = model_bg(VPOS_INDEP, 3, 0, 0, scol)
    check_bg(VPOS_INDEP, scol, 2, exp_pf3,
             f"indep colscroll PF3 val={CS3_INDEP} scol={scol:3d} exp={exp_pf3:#06x}")
    check_bg(VPOS_INDEP, scol, 3, exp_pf4,
             f"indep colscroll PF4 val={CS4_INDEP} scol={scol:3d} exp={exp_pf4:#06x}")


# ===========================================================================
# Test group 3: PF1 palette addition = 16 (palette_offset = 1 line)
# All tiles on affected scanlines shift their palette index by +1.
# ===========================================================================
emit({"op": "reset", "note": "reset for PF1 palette addition test"})
model_reset()

# Distinctive tiles: each tile column has a unique palette so the shift is visible.
# Use tile codes 0x10..0x1F with pen=7, palettes 0x00..0x0F per tile column.
PA_TC = 0x10   # single tile code, all rows pen=7
PA_PEN = 0x7

for row_w in range(16):
    write_gfx_solid(PA_TC, row_w, PA_PEN)
    write_gfx_solid_model(PA_TC, row_w, PA_PEN)

# Fill PF1 with tiles: palette = tx & 0xFF (distinct per column)
for ty in range(32):
    for tx in range(32):
        pal = tx & 0x1FF   # palette 0..31, cycling
        tidx = ty * 32 + tx
        write_pf_tile(PF1_BASE, tidx, pal, PA_TC)
        m.write_pf_ram(0, tidx * 2, pal)
        m.write_pf_ram(0, tidx * 2 + 1, PA_TC)

# PF1 pal_add = 1 palette line (raw = 16) for all scanlines.
# Also clear rowscroll enable (0x0600+scan) for all scans to neutralise any
# residual rowscroll written by earlier test steps that persists across resets
# (BRAM is not cleared by the RTL reset signal).
PAL_ADD_LINES = 1
PAL_ADD_RAW   = PAL_ADD_LINES * 16   # = 16

for scan in range(256):
    write_line_word(0x0600 + scan, 0,
                    f"clear rowscroll_en scan={scan:#04x} (neutralise prior step residue)")
    write_pal_add_enable(scan, 0x1)   # bit[0] = PF1
    write_pal_add_data(0, scan, PAL_ADD_LINES,
                        f"pal_add PF1 scan={scan} lines={PAL_ADD_LINES}")
    m.write_line_ram(0x0600 + scan, 0)   # model already 0; keep in sync
    m.write_line_ram(0x0500 + scan, 0x1)
    m.write_line_ram(0x4800 + scan, PAL_ADD_RAW)

# Check: all scanlines should have palette shifted by +1
# Expected: pixel at (scol) has palette = (original_palette + 1) & 0x1FF
# original_palette = tx & 0x1FF where tx = scol // 16 (tile column)
for vpos_p in [23, 40, 80, 120, 160]:
    for scol in [0, 16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 256]:
        exp = model_bg(vpos_p, 0, 0, 0, scol)
        check_bg(vpos_p, scol, 0, exp,
                 f"pal_add PF1 +1 vpos={vpos_p} scol={scol:3d} exp={exp:#06x}")


# ===========================================================================
# Test group 4: Palette cycling — increasing pal_add per scanline
# Write pal_add values 0, 1, 2, ..., N for scanlines 24..80.
# Each scanline shifts the palette by a different amount.
# ===========================================================================
emit({"op": "reset", "note": "reset for palette cycling test"})
model_reset()

# Use same PA_TC tile code (already in GFX ROM)
# Refill PF1 with the same column-distinct palette tiles
for ty in range(32):
    for tx in range(32):
        pal = tx & 0x1FF
        tidx = ty * 32 + tx
        write_pf_tile(PF1_BASE, tidx, pal, PA_TC)
        m.write_pf_ram(0, tidx * 2, pal)
        m.write_pf_ram(0, tidx * 2 + 1, PA_TC)

CYCLE_SCAN_START = 24
CYCLE_SCAN_END   = 80

# Also clear rowscroll enable for the tested scanline range to neutralise any
# residual rowscroll from prior steps (BRAM persists across RTL resets).
for scan in range(CYCLE_SCAN_START, CYCLE_SCAN_END + 1):
    pal_lines = scan - CYCLE_SCAN_START   # 0, 1, 2, ...
    write_line_word(0x0600 + scan, 0,
                    f"clear rowscroll_en scan={scan:#04x}")
    write_pal_add_enable(scan, 0x1)
    write_pal_add_data(0, scan, pal_lines,
                        f"pal_cycle scan={scan} lines={pal_lines}")
    m.write_line_ram(0x0600 + scan, 0)   # model already 0; keep in sync
    m.write_line_ram(0x0500 + scan, 0x1)
    m.write_line_ram(0x4800 + scan, pal_lines * 16)

# Sample a few scanlines to verify different shift amounts
for vpos_c, expected_shift in [(23, 0), (24, 1), (35, 12), (55, 32), (79, 56)]:
    for scol in [0, 32, 96, 192]:
        exp = model_bg(vpos_c, 0, 0, 0, scol)
        check_bg(vpos_c, scol, 0, exp,
                 f"pal_cycle vpos={vpos_c} shift={expected_shift} scol={scol:3d} exp={exp:#06x}")


# ===========================================================================
# Test group 5: Colscroll + rowscroll simultaneously on PF3
# Verify that both offsets add together to produce the final effective_x.
# colscroll=32 + rowscroll=48 → total shift = 80 pixels
# ===========================================================================
emit({"op": "reset", "note": "reset for colscroll + rowscroll simultaneous test"})
model_reset()

# Reuse PF3 alternating tiles
for ty in range(32):
    for tx in range(32):
        t3 = PF3_TC_EVEN if (tx % 2 == 0) else PF3_TC_ODD
        p3 = PF3_PAL_EVEN if (tx % 2 == 0) else PF3_PAL_ODD
        tidx = ty * 32 + tx
        write_pf_tile(PF3_BASE, tidx, p3, t3)
        m.write_pf_ram(2, tidx * 2, p3)
        m.write_pf_ram(2, tidx * 2 + 1, t3)

COMB_CS  = 32    # colscroll pixels
COMB_RS  = 48    # rowscroll pixels (as 10.6 fixed-point: val = pixels << 6)
COMB_RS_RAW = COMB_RS << 6   # raw rowscroll register value

COMB_SCAN = 70
COMB_VPOS = 69   # next_scan = 70

# Enable colscroll for PF3 (bit2) + rowscroll for PF3 (bit2)
write_colscroll_enable(COMB_SCAN, 0x4)   # colscroll en PF3
write_colscroll_data(2, COMB_SCAN, COMB_CS,
                      f"combined: colscroll PF3 = {COMB_CS} pixels")
# Rowscroll enable at 0x0600 + scan, rowscroll data at 0x5200 + scan
write_line_word(0x0600 + COMB_SCAN, 0x4,
                f"combined: rowscroll en PF3")
write_line_word(0x5200 + COMB_SCAN, COMB_RS_RAW,
                f"combined: rowscroll PF3 = {COMB_RS} px (raw={COMB_RS_RAW:#06x})")

m.write_line_ram(0x0000 + COMB_SCAN, 0x4)
m.write_line_ram(0x2200 + COMB_SCAN, COMB_CS)
m.write_line_ram(0x0600 + COMB_SCAN, 0x4)
m.write_line_ram(0x5200 + COMB_SCAN, COMB_RS_RAW)

# Also test colscroll-only and rowscroll-only as reference points
# colscroll-only scanline
CS_ONLY_SCAN = 72
CS_ONLY_VPOS = 71
write_colscroll_enable(CS_ONLY_SCAN, 0x4)
write_colscroll_data(2, CS_ONLY_SCAN, COMB_CS,
                      f"cs-only PF3 = {COMB_CS} px")
m.write_line_ram(0x0000 + CS_ONLY_SCAN, 0x4)
m.write_line_ram(0x2200 + CS_ONLY_SCAN, COMB_CS)

# rowscroll-only scanline
RS_ONLY_SCAN = 74
RS_ONLY_VPOS = 73
write_line_word(0x0600 + RS_ONLY_SCAN, 0x4,
                f"rs-only: rowscroll en PF3")
write_line_word(0x5200 + RS_ONLY_SCAN, COMB_RS_RAW,
                f"rs-only: rowscroll PF3 = {COMB_RS} px")
m.write_line_ram(0x0600 + RS_ONLY_SCAN, 0x4)
m.write_line_ram(0x5200 + RS_ONLY_SCAN, COMB_RS_RAW)

for scol in [0, 8, 16, 24, 32, 48, 64, 96, 128, 160, 192, 256]:
    exp_comb    = model_bg(COMB_VPOS,    2, 0, 0, scol)
    exp_cs_only = model_bg(CS_ONLY_VPOS, 2, 0, 0, scol)
    exp_rs_only = model_bg(RS_ONLY_VPOS, 2, 0, 0, scol)
    check_bg(COMB_VPOS,    scol, 2, exp_comb,
             f"cs+rs combined  PF3 scol={scol:3d} exp={exp_comb:#06x}")
    check_bg(CS_ONLY_VPOS, scol, 2, exp_cs_only,
             f"cs-only         PF3 scol={scol:3d} exp={exp_cs_only:#06x}")
    check_bg(RS_ONLY_VPOS, scol, 2, exp_rs_only,
             f"rs-only         PF3 scol={scol:3d} exp={exp_rs_only:#06x}")


# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step7_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors -> {out_path}")
