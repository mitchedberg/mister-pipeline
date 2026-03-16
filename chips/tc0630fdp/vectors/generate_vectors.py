#!/usr/bin/env python3
"""
generate_vectors.py — Step 1 test vector generator for tc0630fdp.

Produces step1_vectors.jsonl: one JSON object per line, each describing
one test operation to be executed by the C++ testbench.

Vector object fields:
  op:        "write" | "read" | "timing"
  addr:      word address within ctrl window (0–15)
  data:      16-bit write data (for "write" ops)
  be:        byte enables: 0x3=both, 0x2=high only, 0x1=low only
  exp_dout:  expected cpu_dout value (for "read" ops)
  note:      human-readable description

For "timing" ops (run the full-frame timing test):
  op:         "timing"
  frames:     number of frames to simulate
  exp_pv:     expected pixel_valid count per frame
  exp_hb:     expected hblank cycles per frame  (complementary to pv + overlap)
  exp_vb:     expected vblank cycles per frame
"""

import json
import os
from fdp_model import TaitoF3Model, VideoTiming
from fdp_model import (H_TOTAL, H_START, H_END, H_SYNC_S, H_SYNC_E,
                       V_TOTAL, V_START, V_END, V_SYNC_S, V_SYNC_E)

vectors = []

def emit(v: dict):
    vectors.append(v)


# ===========================================================================
# Helper: write then read a register, verify readback
# ===========================================================================
def rw_test(idx: int, value: int, be: int, note: str, *, exp_value: int = None):
    """Emit a write then a read for register idx."""
    emit({"op": "write", "addr": idx, "data": value, "be": be, "note": f"write {note}"})
    expected = exp_value if exp_value is not None else value
    # Mask expected to reflect byte-enable masking (previous value is 0 from reset)
    emit({"op": "read",  "addr": idx, "exp_dout": expected, "note": f"read  {note}"})


# ===========================================================================
# Section 1: Reset clears all registers
# ===========================================================================
# These come first so we can verify clean state before any writes.
# The testbench issues a hardware reset before running this test group.
emit({"op": "reset", "note": "assert reset — all regs should be 0 after"})
for i in range(16):
    emit({"op": "read", "addr": i, "exp_dout": 0,
          "note": f"post-reset readback ctrl[{i}] == 0"})


# ===========================================================================
# Section 2: Write/readback each of the 16 display control registers
# ===========================================================================
# Use distinctive values so a stuck-at or wiring error is immediately visible.
# Values are designed to differ in both bytes and to cover all bit positions.

REGISTER_TEST_VALUES = {
    0:  0x0040,   # PF1_XSCROLL   — scroll position (10.6 fp)
    1:  0x0180,   # PF2_XSCROLL
    2:  0x5500,   # PF3_XSCROLL
    3:  0xAA80,   # PF4_XSCROLL
    4:  0x0020,   # PF1_YSCROLL   — scroll position (9.7 fp)
    5:  0x00C0,   # PF2_YSCROLL
    6:  0x3300,   # PF3_YSCROLL
    7:  0xCC40,   # PF4_YSCROLL
    8:  0xDEAD,   # unused — write is silently ignored, reads as 0
    9:  0xBEEF,   # unused
    10: 0x1234,   # unused
    11: 0x5678,   # unused
    12: 0x0060,   # PIXEL_XSCROLL
    13: 0x0070,   # PIXEL_YSCROLL
    14: 0xFACE,   # unused
    15: 0x0080,   # EXTEND_MODE   — bit7=1 → 1024px wide
}

for idx, val in REGISTER_TEST_VALUES.items():
    is_unused = idx in {8, 9, 10, 11, 14}
    exp = 0 if is_unused else val
    rw_test(idx, val, 0x3, f"ctrl[{idx}]=0x{val:04X}",
            exp_value=exp)


# ===========================================================================
# Section 3: Byte-lane enable tests
# ===========================================================================
# Reset first, then test that cpu_be masks correctly.

emit({"op": "reset", "note": "reset before byte-lane tests"})

# Write upper byte only to PF1_XSCROLL (idx=0)
emit({"op": "write", "addr": 0, "data": 0xABCD, "be": 0x2,
      "note": "be=0x2 (upper only): ctrl[0] should be 0xAB00"})
emit({"op": "read",  "addr": 0, "exp_dout": 0xAB00,
      "note": "readback after upper-byte-only write"})

# Write lower byte only to PF1_XSCROLL (idx=0) — upper byte retains 0xAB
emit({"op": "write", "addr": 0, "data": 0x1234, "be": 0x1,
      "note": "be=0x1 (lower only): ctrl[0] should be 0xAB34"})
emit({"op": "read",  "addr": 0, "exp_dout": 0xAB34,
      "note": "readback after lower-byte-only write"})

# Write both bytes to PF2_XSCROLL (idx=1), confirm full word
emit({"op": "write", "addr": 1, "data": 0x5A5A, "be": 0x3,
      "note": "be=0x3 (both bytes): ctrl[1] should be 0x5A5A"})
emit({"op": "read",  "addr": 1, "exp_dout": 0x5A5A,
      "note": "readback after full-word write"})


# ===========================================================================
# Section 4: EXTEND_MODE bit decode test
# ===========================================================================
emit({"op": "reset", "note": "reset before extend_mode test"})

# Write EXTEND_MODE=0 (bit7=0)
emit({"op": "write", "addr": 15, "data": 0x0000, "be": 0x3,
      "note": "EXTEND_MODE=0 (512px wide)"})
emit({"op": "read",  "addr": 15, "exp_dout": 0x0000,
      "note": "readback EXTEND_MODE=0"})
emit({"op": "check_extend_mode", "exp": 0,
      "note": "extend_mode output should be 0"})

# Write EXTEND_MODE=1 (bit7=1)
emit({"op": "write", "addr": 15, "data": 0x0080, "be": 0x3,
      "note": "EXTEND_MODE=1 (1024px wide, bit7=1)"})
emit({"op": "read",  "addr": 15, "exp_dout": 0x0080,
      "note": "readback EXTEND_MODE=1"})
emit({"op": "check_extend_mode", "exp": 1,
      "note": "extend_mode output should be 1"})

# Bit 7 set, other bits also set — extend_mode should still be 1
emit({"op": "write", "addr": 15, "data": 0xFFFF, "be": 0x3,
      "note": "ctrl[15]=0xFFFF (all bits set)"})
emit({"op": "read",  "addr": 15, "exp_dout": 0xFFFF,
      "note": "readback ctrl[15]=0xFFFF"})
emit({"op": "check_extend_mode", "exp": 1,
      "note": "extend_mode output should still be 1"})

# Bit 7 clear, other bits set — extend_mode should be 0
emit({"op": "write", "addr": 15, "data": 0xFF7F, "be": 0x3,
      "note": "ctrl[15]=0xFF7F (bit7=0, others set)"})
emit({"op": "read",  "addr": 15, "exp_dout": 0xFF7F,
      "note": "readback ctrl[15]=0xFF7F"})
emit({"op": "check_extend_mode", "exp": 0,
      "note": "extend_mode output should be 0 again"})


# ===========================================================================
# Section 5: Video timing frame test
# ===========================================================================
# Reset before the timing test to ensure int3_cnt is clear and vblank_r
# is in a known state, avoiding spurious int_hblank pulses from prior state.

emit({"op": "reset", "note": "reset before timing frame test"})

# Use the Python model to compute expected counts, then emit a timing vector
# that the C++ testbench will verify by actually running the simulation.

timing = VideoTiming()
stats  = timing.run_frame()

# Expected counts:
exp_pv = 320 * 232        # 74240 — exactly H_active × V_active
exp_hb = H_TOTAL * V_TOTAL - exp_pv   # total blank cycles (includes overlap region)
# Note: hblank and vblank overlap in corners; pixel_valid = !hblank && !vblank

assert stats['pixel_valid_count'] == exp_pv, \
    f"Model pixel_valid count {stats['pixel_valid_count']} != expected {exp_pv}"

# int_vblank and int_hblank counts: both the model and RTL start at (0,0) after
# reset (in the vblank region), so one vblank_rise fires immediately and another
# fires when vpos wraps at the end of the frame — giving 2 each per frame run.
exp_ivb = stats['int_vblank_count']   # 2 (immediate + end-of-frame wrap)
exp_ihb = stats['int_hblank_count']   # 2 (2500 clocks after each vblank_rise)

emit({
    "op": "timing_frame",
    "frames": 1,
    "exp_pv": exp_pv,
    "exp_int_vblank": exp_ivb,
    "exp_int_hblank": exp_ihb,
    "note": (f"full frame: expect {exp_pv} pixel_valid cycles, "
             f"{exp_ivb} int_vblank, {exp_ihb} int_hblank")
})

# Verify hblank/vblank transition timing by walking a specific frame region.
# Emit spot-check vectors: at specific (hpos, vpos) coordinates check which
# signals should be asserted.
TIMING_CHECKS = [
    # (hpos, vpos, hblank_exp, vblank_exp, pixel_valid_exp)
    # Definitely in active region
    (H_START,     V_START,     False, False, True),
    (H_END - 1,   V_START,     False, False, True),
    (H_START,     V_END - 1,   False, False, True),
    (H_END - 1,   V_END - 1,   False, False, True),
    # Boundary: first pixel of hblank
    (H_END,       V_START,     True,  False, False),
    (H_START - 1, V_START,     True,  False, False),
    # Boundary: first line of vblank
    (H_START,     V_END,       False, True,  False),
    (H_START,     V_START - 1, False, True,  False),
    # Corner: simultaneous hblank + vblank
    (0,           0,           True,  True,  False),
    # Sync region
    (H_SYNC_S,    V_SYNC_S,    True,  True,  False),
]

for hc, vc, hb_exp, vb_exp, pv_exp in TIMING_CHECKS:
    emit({
        "op": "timing_check",
        "hpos": hc,
        "vpos": vc,
        "exp_hblank": int(hb_exp),
        "exp_vblank": int(vb_exp),
        "exp_pv": int(pv_exp),
        "note": f"timing at ({hc},{vc}): hb={int(hb_exp)} vb={int(vb_exp)} pv={int(pv_exp)}"
    })

# ===========================================================================
# Write vectors file
# ===========================================================================
out_path = os.path.join(os.path.dirname(__file__), "step1_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
