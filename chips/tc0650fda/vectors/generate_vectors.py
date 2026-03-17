"""
Generate tier1_vectors.jsonl for TC0650FDA Steps 1–4 testbench.

Vector format (one JSON object per line):
  {
    "op":         "write" | "readback" | "lookup" | "blend" | "reset_check",
    "addr":       palette index (0..8191)  — src_pal for blend ops,
    "dst_addr":   palette index for dst_pal (blend ops only),
    "data":       32-bit write value  (write ops only),
    "be":         byte-enable nibble  (write ops, 0..15),
    "mode_12bit": 0 | 1              (lookup/blend ops),
    "src_blend":  0..15              (blend ops, default 8),
    "dst_blend":  0..15              (blend ops, default 0),
    "do_blend":   0 | 1              (1=use MAC formula, 0=opaque passthrough),
    "exp_r":      expected R byte,
    "exp_g":      expected G byte,
    "exp_b":      expected B byte,
    "note":       human-readable description
  }

Test cases covered:
  Step 1 (Groups 1–8): palette write/readback/lookup, 12-bit mode, byte enables,
    index sweep, random entries, 12-bit nibble sweep, overwrite test.
  Step 2 / Step 4 (Groups 9–12): alpha blend MAC, saturation, opaque passthrough,
    asymmetric coefficients, zero-blend, full sweep of blend values.
"""

import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from fda_model import TC0650FDA

random.seed(0xF3_FDA0)

model = TC0650FDA()
vectors: list[dict] = []


def emit_write(addr: int, data: int, be: int, note: str) -> None:
    vectors.append({
        "op":   "write",
        "addr": addr,
        "data": data,
        "be":   be,
        "note": note,
    })
    model.write(addr, data, be)


def emit_lookup(addr: int, mode_12bit: bool, note: str) -> None:
    r, g, b = model.lookup(addr, mode_12bit)
    vectors.append({
        "op":         "lookup",
        "addr":       addr,
        "mode_12bit": 1 if mode_12bit else 0,
        "exp_r":      r,
        "exp_g":      g,
        "exp_b":      b,
        "note":       note,
    })


def emit_blend(src_addr: int, dst_addr: int,
               src_blend: int, dst_blend: int,
               do_blend: bool,
               mode_12bit: bool, note: str) -> None:
    r, g, b = model.blend(src_addr, dst_addr, src_blend, dst_blend,
                          do_blend=do_blend, mode_12bit=mode_12bit)
    vectors.append({
        "op":         "blend",
        "addr":       src_addr,
        "dst_addr":   dst_addr,
        "mode_12bit": 1 if mode_12bit else 0,
        "src_blend":  src_blend,
        "dst_blend":  dst_blend,
        "do_blend":   1 if do_blend else 0,
        "exp_r":      r,
        "exp_g":      g,
        "exp_b":      b,
        "note":       note,
    })


def emit_readback(addr: int, note: str) -> None:
    """CPU read-back: expected value is exactly what the model has stored."""
    exp = model.read(addr)
    vectors.append({
        "op":       "readback",
        "addr":     addr,
        "exp_data": exp,
        "note":     note,
    })


# =============================================================================
# Test group 1 — Write + readback at three boundary indices
# =============================================================================
for addr, r, g, b, tag in [
    (0x0000, 0x12, 0x34, 0x56, "index 0x0000"),
    (0x07FF, 0xDE, 0xAD, 0xBE, "index 0x07FF"),
    (0x1FFF, 0xCA, 0xFE, 0x00, "index 0x1FFF (max)"),
]:
    data = (r << 16) | (g << 8) | b
    emit_write(addr, data, be=0xF, note=f"write {tag} R={r:#04x} G={g:#04x} B={b:#04x}")
    emit_readback(addr, note=f"readback {tag}")

# =============================================================================
# Test group 2 — Pixel lookup: verify BRAM output matches written value
# =============================================================================
emit_lookup(0x0000, mode_12bit=False, note="lookup index 0x0000 standard mode")
emit_lookup(0x07FF, mode_12bit=False, note="lookup index 0x07FF standard mode")
emit_lookup(0x1FFF, mode_12bit=False, note="lookup index 0x1FFF standard mode")

# =============================================================================
# Test group 3 — mode_12bit
#   Write a full 24-bit entry at 0x1000 (accessible only in standard mode).
#   Write a 12-bit-packed entry at 0x0000 (accessible in both modes).
#   Verify:
#     a) 0x1000 read in standard mode → correct RGB888
#     b) 0x1000 read in 12-bit mode → reads from effective index 0x0000 (not 0x1000)
#     c) 12-bit entry at 0x0000 with known nibbles → expanded correctly
# =============================================================================
# 3a: write at 0x1000 in standard mode
emit_write(0x1000, 0x00_11_22_33, be=0xF, note="12bit-test: write 0x112233 at index 0x1000")
emit_lookup(0x1000, mode_12bit=False, note="12bit-test: lookup 0x1000 standard → 0x112233")

# 3b: write 12-bit-packed value at 0x0000 (bits[15:12]=A, [11:8]=5, [7:4]=C)
#   R nibble=0xA → R8=0xAA, G nibble=0x5 → G8=0x55, B nibble=0xC → B8=0xCC
emit_write(0x0000, 0x0000_A5C0, be=0xF,
           note="12bit-test: write 0x0000A5C0 at index 0x0000")
emit_lookup(0x0000, mode_12bit=True,
            note="12bit-test: lookup 0x0000 mode_12bit=1 → R=0xAA G=0x55 B=0xCC")

# 3c: in 12-bit mode, index 0x1000 → effective index 0x0000 (MSB zeroed)
#   So it should return the same 12-bit entry we wrote above
emit_lookup(0x1000, mode_12bit=True,
            note="12bit-test: lookup 0x1000 mode_12bit=1 → aliases to 0x0000")

# =============================================================================
# Test group 4 — Byte enables
#   Write full entry 0xAABBCCDD to index 0x0010 first.
#   Then partial-write with be=0b1100 (only bytes 3 and 2 = bits[31:16]).
#   Verify bits[15:0] (G, B) are unchanged.
#   Then partial-write with be=0b0010 (only byte 1 = G byte).
#   Verify R and B unchanged.
# =============================================================================
emit_write(0x0010, 0xAA_BB_CC_DD, be=0xF,
           note="be-test: full write 0xAABBCCDD at index 0x0010")
emit_readback(0x0010, note="be-test: readback full write")

# Write only high 2 bytes (be=0b1100 = 0xC): bits[31:24] and [23:16]
# New R=0x11, keep G=0xCC, B=0xDD
emit_write(0x0010, 0xFF_11_00_00, be=0xC,
           note="be-test: partial write be=0xC (R byte only effective)")
emit_readback(0x0010, note="be-test: readback after partial write be=0xC")
emit_lookup(0x0010, mode_12bit=False,
            note="be-test: lookup after be=0xC write → G=0xCC B=0xDD unchanged")

# Write only G byte (be=0b0010 = 0x2)
emit_write(0x0010, 0x00_00_77_00, be=0x2,
           note="be-test: partial write be=0x2 (G byte only)")
emit_readback(0x0010, note="be-test: readback after partial write be=0x2")
emit_lookup(0x0010, mode_12bit=False,
            note="be-test: lookup after be=0x2 write → G=0x77, R and B unchanged")

# Write only B byte (be=0b0001 = 0x1)
emit_write(0x0010, 0x00_00_00_88, be=0x1,
           note="be-test: partial write be=0x1 (B byte only)")
emit_readback(0x0010, note="be-test: readback after partial write be=0x1")
emit_lookup(0x0010, mode_12bit=False,
            note="be-test: lookup after be=0x1 write → B=0x88, R and G unchanged")

# =============================================================================
# Test group 5 — Index sweep: 64 evenly spaced entries across full 8192 range
# =============================================================================
STEP = 8192 // 64
for i in range(64):
    addr = i * STEP
    r = (i * 4) & 0xFF
    g = (i * 5 + 1) & 0xFF
    b = (i * 7 + 3) & 0xFF
    data = (r << 16) | (g << 8) | b
    emit_write(addr, data, be=0xF, note=f"sweep write idx={addr:#06x}")

# Fresh model pass: look them all up
for i in range(64):
    addr = i * STEP
    emit_lookup(addr, mode_12bit=False, note=f"sweep lookup idx={addr:#06x}")

# =============================================================================
# Test group 6 — Random entries across full address space
# =============================================================================
for _ in range(80):
    addr = random.randint(0, 0x1FFF)
    data = random.randint(0, 0x00FF_FFFF)  # keep bits[31:24]=0 for standard mode
    be   = random.choice([0xF, 0x7, 0xE, 0x3, 0xC, 0x6])
    emit_write(addr, data, be=be, note=f"random write addr={addr:#06x} be={be:#03x}")

for _ in range(40):
    addr = random.randint(0, 0x1FFF)
    emit_lookup(addr, mode_12bit=False, note=f"random lookup addr={addr:#06x}")

# =============================================================================
# Test group 7 — 12-bit palette: all 16 nibble values
# =============================================================================
for nib in range(16):
    packed = (nib << 12) | (nib << 8) | (nib << 4)
    addr = 0x0100 + nib
    emit_write(addr, packed, be=0xF,
               note=f"12bit nib=0x{nib:X} packed=0x{packed:04X} at idx {addr:#06x}")
    emit_lookup(addr, mode_12bit=True,
                note=f"12bit nib=0x{nib:X} lookup → R=G=B=0x{(nib<<4)|nib:02X}")

# =============================================================================
# Test group 8 — Overwrite: verify later write takes effect
# =============================================================================
emit_write(0x0200, 0x00_FF_00_00, be=0xF, note="overwrite first write R=0xFF G=0 B=0")
emit_lookup(0x0200, mode_12bit=False, note="overwrite verify R=0xFF before overwrite")
emit_write(0x0200, 0x00_00_FF_00, be=0xF, note="overwrite second write R=0 G=0xFF B=0")
emit_lookup(0x0200, mode_12bit=False, note="overwrite verify G=0xFF after overwrite")

# =============================================================================
# Test group 9 — Alpha blend: basic blend formula verification
# Formula: out = clamp((src * sb + dst * db) >> 3, 0, 255)
# =============================================================================

# 9a: src_blend=8, dst_blend=0 → output = src_R exactly (opaque src)
emit_write(0x0300, 0x00_80_40_FF, be=0xF, note="blend9a src R=0x80 G=0x40 B=0xFF")
emit_write(0x0301, 0x00_FF_FF_FF, be=0xF, note="blend9a dst white (should be zeroed out)")
emit_blend(0x0300, 0x0301, src_blend=8, dst_blend=0, do_blend=True, mode_12bit=False,
           note="blend9a sb=8 db=0 → output = src exactly")

# 9b: src_blend=0, dst_blend=8 → output = dst_R exactly (transparent src)
emit_blend(0x0301, 0x0300, src_blend=0, dst_blend=8, do_blend=True, mode_12bit=False,
           note="blend9b sb=0 db=8 → output = dst exactly (R=0x80 G=0x40 B=0xFF)")

# 9c: half blend (sb=4, db=4)
# src R=0x80(128), dst R=0x40(64) → (128*4 + 64*4)>>3 = (512+256)/8 = 96 = 0x60
emit_write(0x0302, 0x00_80_80_80, be=0xF, note="blend9c src gray 0x80")
emit_write(0x0303, 0x00_40_40_40, be=0xF, note="blend9c dst gray 0x40")
emit_blend(0x0302, 0x0303, src_blend=4, dst_blend=4, do_blend=True, mode_12bit=False,
           note="blend9c sb=4 db=4 → (0x80*4+0x40*4)>>3 = 96 = 0x60 per channel")

# =============================================================================
# Test group 10 — Saturation tests
# =============================================================================

# 10a: src R=0x80, dst R=0xA0, both sb=db=8 → (128*8 + 160*8)>>3 = (1024+1280)/8 = 288 → 0xFF
emit_write(0x0310, 0x00_80_00_00, be=0xF, note="blend10a src R=0x80")
emit_write(0x0311, 0x00_A0_00_00, be=0xF, note="blend10a dst R=0xA0")
emit_blend(0x0310, 0x0311, src_blend=8, dst_blend=8, do_blend=True, mode_12bit=False,
           note="blend10a sb=db=8 R=0x80+0xA0 → saturate 288→0xFF")

# 10b: both channels 0xFF, sb=db=8 → saturate to 0xFF
emit_write(0x0312, 0x00_FF_FF_FF, be=0xF, note="blend10b src all=0xFF")
emit_write(0x0313, 0x00_FF_FF_FF, be=0xF, note="blend10b dst all=0xFF")
emit_blend(0x0312, 0x0313, src_blend=8, dst_blend=8, do_blend=True, mode_12bit=False,
           note="blend10b sb=db=8 0xFF+0xFF → saturate 0xFF each channel")

# 10c: no overflow — src R=0x40, dst R=0x20, sb=db=8 → (64*8+32*8)/8 = (512+256)/8 = 96 = 0x60
emit_write(0x0314, 0x00_40_00_00, be=0xF, note="blend10c src R=0x40")
emit_write(0x0315, 0x00_20_00_00, be=0xF, note="blend10c dst R=0x20")
emit_blend(0x0314, 0x0315, src_blend=8, dst_blend=8, do_blend=True, mode_12bit=False,
           note="blend10c sb=db=8 0x40+0x20 → 96=0x60 no overflow")

# =============================================================================
# Test group 11 — Opaque passthrough (do_blend=0)
# =============================================================================

# 11a: do_blend=0 → dst values ignored, output = src exactly
emit_write(0x0320, 0x00_C8_64_32, be=0xF, note="blend11a src R=200 G=100 B=50")
emit_write(0x0321, 0x00_FF_FF_FF, be=0xF, note="blend11a dst white (must be ignored)")
emit_blend(0x0320, 0x0321, src_blend=8, dst_blend=8, do_blend=False, mode_12bit=False,
           note="blend11a do_blend=0 → output=src regardless of dst and coefficients")

# 11b: do_blend=0 with zero coefficients — still passes src through
emit_blend(0x0320, 0x0321, src_blend=0, dst_blend=0, do_blend=False, mode_12bit=False,
           note="blend11b do_blend=0 coeff=0 → still output=src")

# =============================================================================
# Test group 12 — Asymmetric blends and edge cases
# =============================================================================

# 12a: asymmetric — sb=2, db=6
# src R=0x80(128), dst R=0x40(64): (128*2+64*6)>>3 = (256+384)/8 = 80
emit_write(0x0330, 0x00_80_00_00, be=0xF, note="blend12a src R=0x80")
emit_write(0x0331, 0x00_40_00_00, be=0xF, note="blend12a dst R=0x40")
emit_blend(0x0330, 0x0331, src_blend=2, dst_blend=6, do_blend=True, mode_12bit=False,
           note="blend12a sb=2 db=6 → (128*2+64*6)>>3=80")

# 12b: zero blend (sb=0, db=0) → black
emit_blend(0x0330, 0x0331, src_blend=0, dst_blend=0, do_blend=True, mode_12bit=False,
           note="blend12b sb=0 db=0 → all zeros (black)")

# 12c: reverse blend — sb=6, db=2
emit_blend(0x0330, 0x0331, src_blend=6, dst_blend=2, do_blend=True, mode_12bit=False,
           note="blend12c sb=6 db=2 → (128*6+64*2)>>3=(768+128)/8=112")

# 12d: full sweep of src_blend values 0–8 with fixed dst=0
emit_write(0x0340, 0x00_80_40_20, be=0xF, note="blend12d src R=128 G=64 B=32")
emit_write(0x0341, 0x00_40_20_10, be=0xF, note="blend12d dst R=64 G=32 B=16")
for sb in range(9):
    for db in range(9):
        emit_blend(0x0340, 0x0341, src_blend=sb, dst_blend=db, do_blend=True,
                   mode_12bit=False,
                   note=f"blend12d sweep sb={sb} db={db}")

# =============================================================================
# Write vectors file
# =============================================================================
out_path = os.path.join(os.path.dirname(__file__), "tier1_vectors.jsonl")
with open(out_path, "w") as fh:
    for v in vectors:
        fh.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
