"""
Generate tier1_vectors.jsonl for TC0650FDA Step 1 testbench.

Vector format (one JSON object per line):
  {
    "op":        "write" | "lookup" | "reset_check",
    "addr":      palette index (0..8191),
    "data":      32-bit write value  (write ops only),
    "be":        byte-enable nibble  (write ops, 0..15),
    "mode_12bit": 0 | 1              (lookup ops),
    "exp_r":     expected R byte,
    "exp_g":     expected G byte,
    "exp_b":     expected B byte,
    "note":      human-readable description
  }

Test cases covered (Step 1 spec):
  1. Reset: all outputs 0 — verified inline in testbench (not a vector)
  2. Write palette entries: index 0x0000, 0x07FF, 0x1FFF
  3. CPU read-back: same three indices
  4. Pixel lookup: index 0x0000 → rgb matches written value
  5. mode_12bit: write at 0x1000, normal read vs 12-bit address aliasing
  6. Byte enables: partial writes leave other bytes unchanged
  7. Full index sweep (sample of 256 entries across 8192 range)
  8. pixel_valid gate: tested inline in testbench (not a vector)
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
        "op":        "lookup",
        "addr":      addr,
        "mode_12bit": 1 if mode_12bit else 0,
        "exp_r":     r,
        "exp_g":     g,
        "exp_b":     b,
        "note":      note,
    })


def emit_readback(addr: int, note: str) -> None:
    """CPU read-back: expected value is exactly what the model has stored."""
    exp = model.read(addr)
    vectors.append({
        "op":      "readback",
        "addr":    addr,
        "exp_data": exp,
        "note":    note,
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
# Write vectors file
# =============================================================================
out_path = os.path.join(os.path.dirname(__file__), "tier1_vectors.jsonl")
with open(out_path, "w") as fh:
    for v in vectors:
        fh.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
