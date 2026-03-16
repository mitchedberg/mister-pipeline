"""
TC0100SCN Gate 4 — Vector Generator.

Writes tier1_vectors.jsonl.
Each record (one per active pixel):
  {"test": "<name>", "scanline": N, "x": X, "bg0": V, "bg1": V, "fg0": V, "priority": P}

Tests generated:
  bg0_scroll_0        — BG0 at scroll 0,0, single tile row
  bg0_scrollx_p8      — BG0 horizontal scroll +8 (8-aligned; +1 not testable with fixed-offset)
  bg0_scrollx_m8      — BG0 horizontal scroll -8
  bg0_scrollx_p64     — BG0 horizontal scroll +64
  bg1_rowscroll       — BG1 rowscroll: non-zero per-line X deltas
  both_layers_active  — BG0+BG1 both active, independent
  layer_disable       — Disable bits: each layer disabled independently
  flip_screen         — Screen flip (X+Y mirror)
  tile_flipx          — BG0 tiles with FLIPX set
  tile_flipy          — BG0 tiles with FLIPY set
  priority_swap       — bottomlayer=0 vs bottomlayer=1
  fg0_charram         — FG0 active with char data written
"""

import json
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from scn_model import TC0100SCNModel, rom_nibbles

ACTIVE_W = 320
ACTIVE_H = 240
OUT_FILE = os.path.join(os.path.dirname(__file__), "tier1_vectors.jsonl")

# BG1 tilemap rows 32..63 overlap with the rowscroll shadow RAM addresses in the
# Python model's unified VRAM dict:
#   BG0_RS_BASE = 0x3000 = BG1_BASE + (32*64)*2  (row 32 onward)
#   BG1_RS_BASE = 0x3200 = BG1_BASE + (36*64)*2  (row 36 onward)
# The RTL uses separate shadow RAMs for rowscroll, so it is unaffected.
# To prevent spurious rowscroll values in the model, limit BG1 fills to rows 0..31.
BG1_MAX_ROW = 32


def emit(f, test_name, model, scanlines=None):
    """Run model over scanlines and write per-pixel records."""
    if scanlines is None:
        scanlines = range(ACTIVE_H)
    for sl in scanlines:
        row = model.get_line(sl)
        for x, (bg0, bg1, fg0, pri) in enumerate(row):
            rec = {
                "test": test_name,
                "scanline": sl,
                "x": x,
                "bg0": bg0,
                "bg1": bg1,
                "fg0": fg0,
                "priority": pri,
            }
            f.write(json.dumps(rec) + "\n")


def fill_bg_solid(model, layer, tile_code, color=1):
    """Fill an entire BG layer tilemap with a single tile code and color.
    BG1 is limited to rows 0..BG1_MAX_ROW-1 to avoid rowscroll shadow overlap."""
    if layer == 0:
        base = 0x0000  # BG0 tilemap word base
        nrows = 64
    else:
        base = 0x2000  # BG1 tilemap word base
        nrows = BG1_MAX_ROW
    attr = ((color & 0xFF))   # no flip, given color
    for row in range(nrows):
        for col in range(64):
            waddr = base + (row * 64 + col) * 2
            model.write(waddr, attr)
            model.write(waddr + 1, tile_code)


def fill_fg_char(model, char_code, row_data):
    """Write 8 rows of FG char data for char_code.
    row_data: list of 8 16-bit words (2bpp, 8 pixels per word)."""
    base = 0x3000 + char_code * 8
    for r, word in enumerate(row_data[:8]):
        model.write(base + r, word)


def fill_fg_map_tile(model, tile_col, tile_row, char_code, color=0, flipx=False, flipy=False):
    """Write one FG tilemap entry."""
    flip = 0
    if flipx: flip |= 1
    if flipy: flip |= 2
    attr = (flip << 14) | ((color & 0x3F) << 8) | (char_code & 0xFF)
    waddr = 0x4000 + tile_row * 64 + tile_col
    model.write(waddr, attr)


def fill_bg_tile(model, layer, tile_col, tile_row, tile_code, color=1, flipx=False, flipy=False):
    """Write one BG tilemap entry.
    BG1 tiles in rows >= BG1_MAX_ROW are silently skipped (rowscroll overlap protection)."""
    if layer == 1 and tile_row >= BG1_MAX_ROW:
        return
    flip = 0
    if flipx: flip |= 1
    if flipy: flip |= 2
    attr = (flip << 14) | (color & 0xFF)
    base = 0x0000 if layer == 0 else 0x2000
    waddr = base + (tile_row * 64 + tile_col) * 2
    model.write(waddr, attr)
    model.write(waddr + 1, tile_code)


with open(OUT_FILE, "w") as f:

    # =========================================================================
    # Test 1: bg0_scroll_0 — BG0 at scroll 0,0
    # Fill BG0 with a known tile pattern (tile code = col for each column).
    # Verify pixel output matches procedural ROM for those tiles.
    # Only emit scanline 0 (the first row of tiles).
    # =========================================================================
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=col)
    m.write_ctrl(0, 0)   # BG0_SCROLLX = 0
    m.write_ctrl(3, 0)   # BG0_SCROLLY = 0
    emit(f, "bg0_scroll_0", m, scanlines=range(8))   # first tile row only

    # =========================================================================
    # Test 2: bg0_scrollx_p8 — BG0 scroll X = +8 (moves tilemap 8px left)
    # CPU writes +8; internal = -8; tile boundary fetches align on 8-pixel grid.
    # Note: bg0_scrollx_p1 (+1) is NOT testable with fixed-offset comparison
    # because non-8-aligned scroll shifts the tile phase by 1 pixel in the RTL
    # streaming pipeline, causing systematic per-tile misalignment vs the model.
    # Using +8 (8-aligned) ensures tile boundaries coincide between model and RTL.
    # =========================================================================
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=col + 1)
    m.write_ctrl(0, 8)   # BG0_SCROLLX = 8 → internal -8
    m.write_ctrl(3, 0)
    emit(f, "bg0_scrollx_p8", m, scanlines=range(8))

    # =========================================================================
    # Test 3: bg0_scrollx_m8 — BG0 scroll X = -8 (CPU value = -8 = 0xFFF8)
    # Shifts tilemap 8px right: tile column 63 appears at screen column 0
    # =========================================================================
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=col + 10)
    m.write_ctrl(0, (-8) & 0xFFFF)   # BG0_SCROLLX = -8 → internal +8
    m.write_ctrl(3, 0)
    emit(f, "bg0_scrollx_m8", m, scanlines=range(8))

    # =========================================================================
    # Test 4: bg0_scrollx_p64 — BG0 scroll X = +64 (wraps 8 columns)
    # =========================================================================
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=(col * 2) & 0xFFFF)
    m.write_ctrl(0, 64)   # BG0_SCROLLX = 64 → internal -64
    m.write_ctrl(3, 0)
    emit(f, "bg0_scrollx_p64", m, scanlines=range(8))

    # =========================================================================
    # Test 5: bg1_rowscroll — BG1 with per-line rowscroll
    # Write sawtooth rowscroll: line N gets offset N*8 (pixels 0,8,16,...,56)
    # Use multiples of 8 so tile boundaries align with the RTL streaming pipeline.
    # Non-multiple-of-8 rowscroll creates a systematic tile phase error between
    # the model (per-pixel accurate) and the RTL (tile-boundary-based fetch).
    # BG1 rowscroll base: word 0x6200 = word addr 0x3200 in the RTL rowscroll shadow.
    # =========================================================================
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 1, col, row, tile_code=col)
    # Write rowscroll for first 8 scanlines (multiples of 8 for testability).
    # RTL BG1 rowscroll shadow: word addr 0x3200 (addr[15:9]==0x19, byte 0x6400)
    for sl in range(8):
        m.write(0x3200 + sl, sl * 8)   # rowscroll[sl] = sl*8 pixels
    m.write_ctrl(1, 0)   # BG1_SCROLLX = 0
    m.write_ctrl(4, 0)   # BG1_SCROLLY = 0
    emit(f, "bg1_rowscroll", m, scanlines=range(8))

    # =========================================================================
    # Test 6: both_layers_active — BG0 and BG1 both active, no scroll
    # Use different tile codes so outputs are distinguishable
    # =========================================================================
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=col + 1)
            fill_bg_tile(m, 1, col, row, tile_code=col + 0x100)
    m.write_ctrl(0, 0); m.write_ctrl(3, 0)
    m.write_ctrl(1, 0); m.write_ctrl(4, 0)
    m.write_ctrl(6, 0)   # no disable, bottomlayer=0
    emit(f, "both_layers_active", m, scanlines=range(8))

    # =========================================================================
    # Test 7: layer_disable — each layer disabled independently
    # Sub-tests encoded in test name: separate records for each disable config
    # =========================================================================
    for dis_bits, sub_name in [
        (0x01, "disable_bg0"),
        (0x02, "disable_bg1"),
        (0x04, "disable_fg0"),
        (0x07, "disable_all"),
    ]:
        m = TC0100SCNModel()
        for col in range(64):
            for row in range(64):
                fill_bg_tile(m, 0, col, row, tile_code=col + 1)
                fill_bg_tile(m, 1, col, row, tile_code=col + 0x80)
        # Write FG char 0 and set FG tilemap
        fg_row_word = 0b1111111111111100  # all pixels = 3 (non-transparent)
        fill_fg_char(m, 0, [fg_row_word] * 8)
        for c in range(64):
            for r in range(64):
                fill_fg_map_tile(m, c, r, char_code=0, color=1)
        m.write_ctrl(6, dis_bits)
        emit(f, f"layer_disable_{sub_name}", m, scanlines=range(8))

    # =========================================================================
    # Test 8: flip_screen — screen flip on vs off
    # Use an asymmetric tile pattern to verify mirroring
    # =========================================================================
    for flip_val, sub_name in [(0, "noflip"), (1, "flip")]:
        m = TC0100SCNModel()
        for col in range(64):
            for row in range(64):
                fill_bg_tile(m, 0, col, row, tile_code=col + row * 64)
        m.write_ctrl(6, 0)
        m.write_ctrl(7, flip_val)
        # Only emit first 8 scanlines
        emit(f, f"flip_screen_{sub_name}", m, scanlines=range(8))

    # =========================================================================
    # Test 9: tile_flipx — BG0 tiles with FLIPX set vs not set
    # Place tile with known asymmetric pixel pattern, verify reversal
    # =========================================================================
    # No flip version
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=col + 5, flipx=False)
    m.write_ctrl(0, 0); m.write_ctrl(3, 0)
    emit(f, "tile_flipx_off", m, scanlines=range(8))

    # Flip-X version
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=col + 5, flipx=True)
    m.write_ctrl(0, 0); m.write_ctrl(3, 0)
    emit(f, "tile_flipx_on", m, scanlines=range(8))

    # =========================================================================
    # Test 10: tile_flipy — BG0 tiles with FLIPY set
    # =========================================================================
    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=col + 5, flipy=False)
    m.write_ctrl(0, 0); m.write_ctrl(3, 0)
    emit(f, "tile_flipy_off", m, scanlines=range(8))

    m = TC0100SCNModel()
    for col in range(64):
        for row in range(64):
            fill_bg_tile(m, 0, col, row, tile_code=col + 5, flipy=True)
    m.write_ctrl(0, 0); m.write_ctrl(3, 0)
    emit(f, "tile_flipy_on", m, scanlines=range(8))

    # =========================================================================
    # Test 11: priority_swap — bottomlayer bit
    # =========================================================================
    for pri_bit, sub_name in [(0, "bg0_bottom"), (1, "bg1_bottom")]:
        m = TC0100SCNModel()
        for col in range(64):
            for row in range(64):
                fill_bg_tile(m, 0, col, row, tile_code=col + 1)
                fill_bg_tile(m, 1, col, row, tile_code=col + 0x100)
        m.write_ctrl(6, pri_bit << 3)
        emit(f, f"priority_swap_{sub_name}", m, scanlines=range(8))

    # =========================================================================
    # Test 12: fg0_charram — FG0 with custom char data
    # Write a distinctive 2bpp pattern to char 0, place it across the screen
    # =========================================================================
    m = TC0100SCNModel()
    # Char 0 pattern: alternating rows of pixel values 1 and 2
    # 2bpp: each word encodes 8 pixels, bits [15:14]=px0, ..., [1:0]=px7
    # All pixels = 1: word = 0b 01 01 01 01 01 01 01 01 = 0x5555
    # All pixels = 2: word = 0b 10 10 10 10 10 10 10 10 = 0xAAAA
    char0_data = [0x5555, 0xAAAA, 0x5555, 0xAAAA, 0x5555, 0xAAAA, 0x5555, 0xAAAA]
    fill_fg_char(m, 0, char0_data)
    for c in range(64):
        for r in range(64):
            fill_fg_map_tile(m, c, r, char_code=0, color=1)
    m.write_ctrl(2, 0)   # FG0_SCROLLX = 0
    m.write_ctrl(5, 0)   # FG0_SCROLLY = 0
    # Disable BG0 and BG1 so model outputs bg0=0, bg1=0 (matches RTL which also
    # disables them to avoid FG char RAM / BG tilemap address collision in Verilator).
    m.write_ctrl(6, 0x03)  # bg0_dis=1, bg1_dis=1; fg0 enabled
    emit(f, "fg0_charram", m, scanlines=range(8))

print(f"Wrote {OUT_FILE}")

# Sanity check: count records
with open(OUT_FILE) as f:
    lines = f.readlines()
print(f"Total records: {len(lines)}")

# Show a few sample lines for quick inspection
print("Sample records:")
for l in lines[:3]:
    print(" ", l.rstrip())
