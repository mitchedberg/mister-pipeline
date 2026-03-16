"""
CPS1 OBJ Gate 4 — Tier-1 test vector generator.

Outputs two files:
  tier1_vectors.jsonl   — one record per (test, scanline) with expected pixel map
  tier1_obj_ram.jsonl   — OBJ RAM contents per test (1024 words each)

tier1_vectors.jsonl record format (one per test-case per scanline):
  {
    "test_name":  str,
    "scanline":   int,         # 0..239
    "flip_screen": bool,
    "pixels":     {str(x): int, ...}  # only non-transparent pixels; 9-bit value
  }

tier1_obj_ram.jsonl record format (one per test-case):
  {
    "test_name": str,
    "obj_ram":   [int, ...]   # 1024 16-bit words
  }
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from obj_model import (
    CPS1OBJModel, build_obj_ram, TRANSPARENT,
    rom_lookup, make_rom
)

VECFILE  = os.path.join(os.path.dirname(__file__), "tier1_vectors.jsonl")
RAMFILE  = os.path.join(os.path.dirname(__file__), "tier1_obj_ram.jsonl")

ACTIVE_SCANLINES = list(range(0, 240))


# ---------------------------------------------------------------------------
# Helper: run model, return per-scanline pixel maps and OBJ RAM
# ---------------------------------------------------------------------------

def run_test(test_name, sprites, flip_screen=False, rom=None,
             only_scanlines=None, no_terminator=False,
             ram_override=None):
    """
    Build OBJ RAM, run vblank(), return:
      vec_records: list of {"test_name", "scanline", "flip_screen", "pixels"}
      ram_record:  {"test_name", "obj_ram": [...1024 words...]}
    """
    model = CPS1OBJModel(flip_screen=flip_screen, rom=rom)

    if ram_override is not None:
        ram = ram_override
    else:
        ram = build_obj_ram(sprites, terminator=(not no_terminator))

    for addr, word in enumerate(ram):
        model.write_obj_ram(addr, word)
    model.vblank()

    scan_range = only_scanlines if only_scanlines is not None else ACTIVE_SCANLINES

    vec_records = []
    for sl in scan_range:
        if sl < 0 or sl >= 262:
            continue
        line = model.get_line(sl)
        pixels = {}
        for px, val in enumerate(line):
            # Only check the visible window: X = 64..447 (hardware active display)
            if px < 64 or px > 447:
                continue
            if val != TRANSPARENT:
                pixels[str(px)] = val
        vec_records.append({
            "test_name":   test_name,
            "scanline":    sl,
            "flip_screen": flip_screen,
            "pixels":      pixels,
        })

    ram_record = {"test_name": test_name, "obj_ram": ram}
    return vec_records, ram_record


# ---------------------------------------------------------------------------
# Collect all test cases
# ---------------------------------------------------------------------------

all_vecs = []
all_rams = []


def add_test(*args, **kwargs):
    vecs, ram = run_test(*args, **kwargs)
    all_vecs.extend(vecs)
    all_rams.append(ram)


# ── 1. Single sprite at various X positions ──────────────────────────────────
# Y=16: sprite on scanlines 16-31.
for x_pos in [0, 64, 127, 128, 256, 383, 384, 447, 448, 511]:
    name = f"x_sweep_x{x_pos}"
    sprites = [{'x': x_pos, 'y': 16, 'code': 0x0001, 'nx': 0, 'ny': 0,
                'flipx': False, 'flipy': False, 'color': 3}]
    add_test(name, sprites, only_scanlines=range(16, 32))

# ── 2. Single sprite at various Y positions ──────────────────────────────────
for y_pos in [0, 16, 112, 224, 239, 255]:
    name = f"y_sweep_y{y_pos}"
    sprites = [{'x': 64, 'y': y_pos, 'code': 0x0002, 'nx': 0, 'ny': 0,
                'flipx': False, 'flipy': False, 'color': 5}]
    # Compute which scanlines this sprite touches in active area
    scan_set = set()
    for vsub in range(16):
        sl = (y_pos + vsub) & 0xFF
        if sl < 240:
            scan_set.add(sl)
    # If no active scanlines, still test the range around y_pos
    if not scan_set:
        scan_set = set(range(max(0, y_pos - 2), min(240, y_pos + 18)))
    add_test(name, sprites, only_scanlines=sorted(scan_set))

# ── 3. All 4 flip combinations ───────────────────────────────────────────────
for flipx, flipy in [(False, False), (True, False), (False, True), (True, True)]:
    name = f"flip_fx{int(flipx)}_fy{int(flipy)}"
    sprites = [{'x': 64, 'y': 32, 'code': 0x0100, 'nx': 0, 'ny': 0,
                'flipx': flipx, 'flipy': flipy, 'color': 7}]
    add_test(name, sprites, only_scanlines=range(32, 48))

# ── 4. Multi-tile blocks ─────────────────────────────────────────────────────

# 2×2 block
add_test("block_2x2",
         [{'x': 64, 'y': 32, 'code': 0x0200, 'nx': 1, 'ny': 1,
           'flipx': False, 'flipy': False, 'color': 2}],
         only_scanlines=range(32, 64))

# 4×4 block
add_test("block_4x4",
         [{'x': 64, 'y': 48, 'code': 0x0300, 'nx': 3, 'ny': 3,
           'flipx': False, 'flipy': False, 'color': 4}],
         only_scanlines=range(48, 112))

# 8×8 block
add_test("block_8x8",
         [{'x': 64, 'y': 64, 'code': 0x0400, 'nx': 7, 'ny': 7,
           'flipx': False, 'flipy': False, 'color': 6}],
         only_scanlines=range(64, 192))

# 2×2 block with FLIPX+FLIPY
add_test("block_2x2_flip",
         [{'x': 64, 'y': 32, 'code': 0x0200, 'nx': 1, 'ny': 1,
           'flipx': True, 'flipy': True, 'color': 9}],
         only_scanlines=range(32, 64))

# ── 5. Two overlapping sprites testing priority (entry 0 wins) ───────────────
add_test("priority_entry0_wins",
         [
             {'x': 128, 'y': 64, 'code': 0x0010, 'nx': 0, 'ny': 0,
              'flipx': False, 'flipy': False, 'color': 1},   # entry 0 = top
             {'x': 128, 'y': 64, 'code': 0x0010, 'nx': 0, 'ny': 0,
              'flipx': False, 'flipy': False, 'color': 2},   # entry 1 = bottom
         ],
         only_scanlines=range(64, 80))

add_test("priority_non_overlap",
         [
             {'x': 200, 'y': 64, 'code': 0x0011, 'nx': 0, 'ny': 0,
              'flipx': False, 'flipy': False, 'color': 5},   # entry 0
             {'x': 220, 'y': 64, 'code': 0x0011, 'nx': 0, 'ny': 0,
              'flipx': False, 'flipy': False, 'color': 8},   # entry 1, 20px away
         ],
         only_scanlines=range(64, 80))

# ── 6. Table with 256 sprites (full capacity) ─────────────────────────────────
sprites_256 = []
for i in range(256):
    row = i // 16
    col = i % 16
    sprites_256.append({
        'x': 64 + col * 20,
        'y': row * 14,
        'code': i & 0xFFFF,
        'nx': 0, 'ny': 0,
        'flipx': False, 'flipy': False,
        'color': (i % 31) + 1,
    })
add_test("full_table_256", sprites_256, no_terminator=True,
         only_scanlines=ACTIVE_SCANLINES)

# ── 7. Table end marker at entry 0 (empty frame) ─────────────────────────────
# Build OBJ RAM manually: entry 0 ATTR = 0xFF00 (terminator)
ram_empty = [0] * 1024
ram_empty[3] = 0xFF00    # entry 0 ATTR = terminator
# entry 1: looks valid but must be ignored
ram_empty[4] = 128       # x
ram_empty[5] = 64        # y
ram_empty[6] = 0x0050    # code
ram_empty[7] = 0x0003    # color=3, 1x1
add_test("empty_table_terminator_at_0", [],
         only_scanlines=range(60, 76),
         ram_override=ram_empty)

# ── 8. Transparency: all-transparent tile ────────────────────────────────────
trans_rom = {(0x00AA, vsub): [0xF]*16 for vsub in range(16)}
add_test("transparent_tile",
         [{'x': 128, 'y': 64, 'code': 0x00AA, 'nx': 0, 'ny': 0,
           'flipx': False, 'flipy': False, 'color': 10}],
         rom=trans_rom,
         only_scanlines=range(64, 80))

# ── 9. X-wrap: sprite at X=504 ───────────────────────────────────────────────
add_test("x_wrap_504",
         [{'x': 504, 'y': 80, 'code': 0x0060, 'nx': 0, 'ny': 0,
           'flipx': False, 'flipy': False, 'color': 11}],
         only_scanlines=range(80, 96))

# ── 10. Y-wrap: sprite at Y=232 ──────────────────────────────────────────────
add_test("y_wrap_232",
         [{'x': 200, 'y': 232, 'code': 0x0070, 'nx': 0, 'ny': 0,
           'flipx': False, 'flipy': False, 'color': 12}],
         only_scanlines=list(range(232, 240)) + list(range(0, 8)))

# ── 11. Flip screen ───────────────────────────────────────────────────────────
add_test("flip_screen_basic",
         [{'x': 64, 'y': 32, 'code': 0x0080, 'nx': 0, 'ny': 0,
           'flipx': False, 'flipy': False, 'color': 13}],
         flip_screen=True,
         only_scanlines=range(0, 240))

# ── 12. 2×1 block at X=440 (X-wrap for second tile) ─────────────────────────
add_test("block_2x1_x_wrap",
         [{'x': 440, 'y': 100, 'code': 0x0090, 'nx': 1, 'ny': 0,
           'flipx': False, 'flipy': False, 'color': 14}],
         only_scanlines=range(100, 116))

# ── 13. 1×2 block at Y=232 (Y-wrap for second tile row) ─────────────────────
add_test("block_1x2_y_wrap",
         [{'x': 200, 'y': 232, 'code': 0x00A0, 'nx': 0, 'ny': 1,
           'flipx': False, 'flipy': False, 'color': 15}],
         only_scanlines=list(range(232, 240)) + list(range(0, 8)))

# ── 14. Early terminator mid-table ───────────────────────────────────────────
sprites_early = [
    {'x': 64,  'y': 80, 'code': 0x00B0, 'nx': 0, 'ny': 0,
     'flipx': False, 'flipy': False, 'color': 16},
    {'x': 84,  'y': 80, 'code': 0x00B1, 'nx': 0, 'ny': 0,
     'flipx': False, 'flipy': False, 'color': 17},
    {'x': 104, 'y': 80, 'code': 0x00B2, 'nx': 0, 'ny': 0,
     'flipx': False, 'flipy': False, 'color': 18},
]
# build_obj_ram with terminator places 0xFF00 at entry[3]
# We manually place a decoy after that
ram_early = build_obj_ram(sprites_early, terminator=True)
# Entry 4 (word 16) should be ignored (after the terminator at entry 3)
ram_early[4*4 + 0] = 200   # x
ram_early[4*4 + 1] = 80    # y
ram_early[4*4 + 2] = 0x00FF
ram_early[4*4 + 3] = 0x0005  # NOT a terminator
add_test("terminator_mid_table", [],
         only_scanlines=range(80, 96),
         ram_override=ram_early)

# ── 15. vsub boundary: sprite at Y = scanline (vsub=0) ───────────────────────
add_test("vsub_0",
         [{'x': 128, 'y': 100, 'code': 0x00C0, 'nx': 0, 'ny': 0,
           'flipx': False, 'flipy': False, 'color': 20}],
         only_scanlines=[100])

add_test("vsub_15",
         [{'x': 128, 'y': 85, 'code': 0x00C1, 'nx': 0, 'ny': 0,
           'flipx': False, 'flipy': False, 'color': 21}],
         only_scanlines=[100])

# ── 16. FLIPY vsub inversion ─────────────────────────────────────────────────
add_test("flipy_vsub_inversion",
         [{'x': 128, 'y': 100, 'code': 0x00D0, 'nx': 0, 'ny': 0,
           'flipx': False, 'flipy': True, 'color': 22}],
         only_scanlines=range(100, 116))

# ── 17. Multi-tile 1×2 with FLIPY (row order reversal) ───────────────────────
add_test("block_1x2_flipy",
         [{'x': 128, 'y': 100, 'code': 0x00E0, 'nx': 0, 'ny': 1,
           'flipx': False, 'flipy': True, 'color': 23}],
         only_scanlines=range(100, 132))

# ── 18. 2×2 block with FLIPX only ────────────────────────────────────────────
add_test("block_2x2_flipx",
         [{'x': 64, 'y': 32, 'code': 0x0200, 'nx': 1, 'ny': 1,
           'flipx': True, 'flipy': False, 'color': 24}],
         only_scanlines=range(32, 64))

# ---------------------------------------------------------------------------
# Write output files
# ---------------------------------------------------------------------------

with open(VECFILE, 'w') as f:
    for rec in all_vecs:
        f.write(json.dumps(rec) + '\n')

with open(RAMFILE, 'w') as f:
    for rec in all_rams:
        f.write(json.dumps(rec) + '\n')

print(f"Generated {len(all_vecs)} scanline records in {VECFILE}")
print(f"Generated {len(all_rams)} OBJ RAM records in {RAMFILE}")

# Summary
tests_seen = {}
for r in all_vecs:
    n = r['test_name']
    if n not in tests_seen:
        tests_seen[n] = {'scanlines': 0, 'pixels': 0}
    tests_seen[n]['scanlines'] += 1
    tests_seen[n]['pixels'] += len(r['pixels'])

print(f"\nTest cases: {len(tests_seen)}")
total_px = 0
for name, stats in tests_seen.items():
    total_px += stats['pixels']
    print(f"  {name}: {stats['scanlines']} scanlines, {stats['pixels']} pixels")
print(f"\nTotal non-transparent pixel vectors: {total_px}")
