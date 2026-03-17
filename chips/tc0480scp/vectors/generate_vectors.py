#!/usr/bin/env python3
"""
TC0480SCP — Step 1 vector generator.

Generates step1_vectors.jsonl covering:
  1.  BG0–BG3 X scroll with stagger (non-flip)          — tests 1–4
  2.  BG0–BG3 Y scroll pass-through (non-flip)          — tests 5–8
  3.  LAYER_CTRL dblwidth / flipscreen flags             — tests 9–11
  4.  X scroll sign inversion under flipscreen           — tests 12–15
  5.  Y scroll sign inversion under flipscreen           — tests 16–19
  6.  bg_priority LUT: all 8 indices                     — tests 20–27
  7.  rowzoom_en bits 0 and 1                            — tests 28–30
  8.  Video timing frame: pixel_active count             — test  31
  9.  hblank_fall / pixel_active at boundary positions   — tests 32–36
 10.  Zoom register round-trip                           — tests 37–40
 11.  DX/DY sub-pixel byte extraction                   — tests 41–44
 12.  Text scroll round-trip                             — tests 45–46
 13.  Byte-enable writes to ctrl registers               — tests 47–48
 14.  Register readback after reset                      — test  49
 15.  Unknown word 14 writes/reads (no effect on decode) — test  50

Total: 50 test entries.

Output: step1_vectors.jsonl (one JSON object per line).
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from scp_model import TC0480SCPModel, H_TOTAL, H_END, V_TOTAL, V_START, V_END, ACTIVE_PIXELS

OUTFILE = os.path.join(os.path.dirname(__file__), "step1_vectors.jsonl")

# ── Timing constants for testbench (must match RTL localparam) ────────────────
H_SYNC_S = 336
H_SYNC_E = 368
V_SYNC_S = 0
V_SYNC_E = 4

records = []


def rec(**kw):
    records.append(kw)


def ctrl_word_addr(word_idx):
    """CPU word address for a control register word index 0–23."""
    # The testbench drives cpu_addr[4:0] directly as the word index.
    return word_idx


# ── 0. Reset ──────────────────────────────────────────────────────────────────
rec(op="reset", note="power-on reset")

# ── Fresh model ───────────────────────────────────────────────────────────────
m = TC0480SCPModel()

# =============================================================================
# 1. BG X scroll with stagger (non-flip)
# =============================================================================
# Section1 §3.4: BG0: -(ctrl[0]), BG1: -(ctrl[1]+4), BG2: -(ctrl[2]+8), BG3: -(ctrl[3]+12)
stagger = [0, 4, 8, 12]
for layer in range(4):
    raw_val = 0x0010
    m.write_ctrl(layer, raw_val)
    rec(op="write", addr=ctrl_word_addr(layer), data=raw_val, be=3,
        note=f"BG{layer}_XSCROLL write 0x{raw_val:04X}")
    exp = m.bgscrollx(layer)
    rec(op="check_bgscrollx", layer=layer, exp=exp,
        note=f"BG{layer} bgscrollx stagger check: expect 0x{exp:04X} (=-(0x{raw_val:04X}+{stagger[layer]}))")

# =============================================================================
# 2. BG Y scroll pass-through (non-flip)
# =============================================================================
for layer in range(4):
    raw_val = 0x0020 + layer
    m.write_ctrl(4 + layer, raw_val)
    rec(op="write", addr=ctrl_word_addr(4 + layer), data=raw_val, be=3,
        note=f"BG{layer}_YSCROLL write 0x{raw_val:04X}")
    exp = m.bgscrolly(layer)
    rec(op="check_bgscrolly", layer=layer, exp=exp,
        note=f"BG{layer} bgscrolly pass-through: expect 0x{exp:04X}")

# =============================================================================
# 3. LAYER_CTRL dblwidth (bit 7 of word 15)
# =============================================================================
# Write 0x0080 to word 15 → dblwidth=1, flipscreen=0
m.write_ctrl(15, 0x0080)
rec(op="write", addr=ctrl_word_addr(15), data=0x0080, be=3,
    note="LAYER_CTRL=0x0080: dblwidth=1")
rec(op="check_dblwidth", exp=1,
    note="dblwidth=1 after writing 0x0080")
rec(op="check_flipscreen", exp=0,
    note="flipscreen=0 after writing 0x0080")

# =============================================================================
# 4. LAYER_CTRL flipscreen (bit 6)
# =============================================================================
m.write_ctrl(15, 0x0040)
rec(op="write", addr=ctrl_word_addr(15), data=0x0040, be=3,
    note="LAYER_CTRL=0x0040: flipscreen=1")
rec(op="check_dblwidth",  exp=0, note="dblwidth=0 after writing 0x0040")
rec(op="check_flipscreen", exp=1, note="flipscreen=1 after writing 0x0040")

# =============================================================================
# 5. X scroll sign inversion under flipscreen
# =============================================================================
# With flipscreen=1: bgscrollx[n] = +(ctrl[n] + stagger[n])  (not negated)
for layer in range(4):
    raw_val = 0x0010
    m.write_ctrl(layer, raw_val)  # keep ctrl[0..3] from test 1
    exp = m.bgscrollx(layer)       # flipscreen is still on
    rec(op="check_bgscrollx", layer=layer, exp=exp,
        note=f"BG{layer} bgscrollx (flipscreen=1): expect 0x{exp:04X} (positive)")

# =============================================================================
# 6. Y scroll sign inversion under flipscreen
# =============================================================================
for layer in range(4):
    exp = m.bgscrolly(layer)
    rec(op="check_bgscrolly", layer=layer, exp=exp,
        note=f"BG{layer} bgscrolly (flipscreen=1): expect 0x{exp:04X} (negated)")

# =============================================================================
# 7. bg_priority LUT: all 8 indices
# =============================================================================
# Clear flipscreen first
m.write_ctrl(15, 0x0000)
rec(op="write", addr=ctrl_word_addr(15), data=0x0000, be=3,
    note="LAYER_CTRL=0x0000: clear all flags")

pri_lut = [0x0123, 0x1230, 0x2301, 0x3012, 0x3210, 0x2103, 0x1032, 0x0321]
for idx in range(8):
    layer_ctrl = (idx << 2) & 0x1C   # bits [4:2]
    m.write_ctrl(15, layer_ctrl)
    rec(op="write", addr=ctrl_word_addr(15), data=layer_ctrl, be=3,
        note=f"LAYER_CTRL priority_order={idx}")
    exp_pri = m.bg_priority()
    rec(op="check_bg_priority", exp=exp_pri,
        note=f"bg_priority idx={idx}: expect 0x{exp_pri:04X}")
    assert exp_pri == pri_lut[idx], f"Model LUT mismatch at idx={idx}"

# =============================================================================
# 8. rowzoom_en bits
# =============================================================================
m.write_ctrl(15, 0x0001)   # bit0 = BG2 rowzoom enable
rec(op="write", addr=ctrl_word_addr(15), data=0x0001, be=3,
    note="LAYER_CTRL=0x0001: rowzoom_en[2]=1")
rec(op="check_rowzoom_en", layer=2, exp=1,
    note="rowzoom_en[2]=1")
rec(op="check_rowzoom_en", layer=3, exp=0,
    note="rowzoom_en[3]=0 (bit1 clear)")

m.write_ctrl(15, 0x0002)   # bit1 = BG3 rowzoom enable
rec(op="write", addr=ctrl_word_addr(15), data=0x0002, be=3,
    note="LAYER_CTRL=0x0002: rowzoom_en[3]=1")
rec(op="check_rowzoom_en", layer=2, exp=0,
    note="rowzoom_en[2]=0 after bit0 clear")
rec(op="check_rowzoom_en", layer=3, exp=1,
    note="rowzoom_en[3]=1")

m.write_ctrl(15, 0x0003)   # both
rec(op="write", addr=ctrl_word_addr(15), data=0x0003, be=3,
    note="LAYER_CTRL=0x0003: rowzoom_en[2]=1, rowzoom_en[3]=1")
rec(op="check_rowzoom_en", layer=2, exp=1, note="rowzoom_en[2]=1 (both set)")
rec(op="check_rowzoom_en", layer=3, exp=1, note="rowzoom_en[3]=1 (both set)")

# Clear LAYER_CTRL for remaining tests
m.write_ctrl(15, 0x0000)
rec(op="write", addr=ctrl_word_addr(15), data=0x0000, be=3,
    note="LAYER_CTRL=0x0000: reset for timing tests")

# =============================================================================
# 9. Video timing: pixel_active count over one full frame
# =============================================================================
# pixel_active should be high for exactly H_END × (V_END - V_START) cycles
rec(op="timing_frame",
    exp_pv=ACTIVE_PIXELS,
    note=f"timing: pixel_active count = {ACTIVE_PIXELS} (320×240)")

# =============================================================================
# 10. hblank / pixel_active boundary checks
# =============================================================================
# pixel_active=1 at first visible pixel: hpos=0, vpos=V_START
rec(op="timing_check", hpos=0, vpos=V_START,
    exp_hblank=0, exp_vblank=0, exp_pixel_active=1,
    note="timing: hpos=0 vpos=16 → active")

# pixel_active=0 just before visible area: hpos=0, vpos=V_START-1
rec(op="timing_check", hpos=0, vpos=V_START - 1,
    exp_hblank=0, exp_vblank=1, exp_pixel_active=0,
    note="timing: hpos=0 vpos=15 → vblank (not yet active)")

# pixel_active=0 at last hblank column of active line: hpos=H_END, vpos=V_START
rec(op="timing_check", hpos=H_END, vpos=V_START,
    exp_hblank=1, exp_vblank=0, exp_pixel_active=0,
    note=f"timing: hpos={H_END} vpos={V_START} → hblank start")

# pixel_active=1 at last visible pixel column of active line: hpos=H_END-1, vpos=V_START
rec(op="timing_check", hpos=H_END - 1, vpos=V_START,
    exp_hblank=0, exp_vblank=0, exp_pixel_active=1,
    note=f"timing: hpos={H_END - 1} vpos={V_START} → last active pixel of row")

# hblank_fall fires exactly at hpos=H_END (registered, so seen on next clock)
rec(op="timing_check", hpos=H_END, vpos=V_START,
    exp_hblank=1, exp_vblank=0, exp_pixel_active=0,
    note=f"timing: hpos={H_END} vpos={V_START} → hblank asserted")

# =============================================================================
# 11. Zoom register round-trip
# =============================================================================
zoom_vals = [0x8040, 0x0080, 0xFF7F, 0x1234]
for layer in range(4):
    m.write_ctrl(8 + layer, zoom_vals[layer])
    rec(op="write", addr=ctrl_word_addr(8 + layer), data=zoom_vals[layer], be=3,
        note=f"BG{layer}_ZOOM write 0x{zoom_vals[layer]:04X}")
    rec(op="read", addr=ctrl_word_addr(8 + layer), exp_dout=zoom_vals[layer],
        note=f"BG{layer}_ZOOM readback 0x{zoom_vals[layer]:04X}")

# =============================================================================
# 12. DX/DY sub-pixel byte extraction
# =============================================================================
dx_vals = [0x12, 0x34, 0x56, 0x78]
dy_vals = [0xAB, 0xCD, 0xEF, 0x01]
for layer in range(4):
    # Write full 16-bit with junk in high byte; only low byte matters
    m.write_ctrl(16 + layer, 0xBE00 | dx_vals[layer])
    rec(op="write", addr=ctrl_word_addr(16 + layer), data=0xBE00 | dx_vals[layer],
        be=3, note=f"BG{layer}_DX write (low byte=0x{dx_vals[layer]:02X})")
    rec(op="check_bg_dx", layer=layer, exp=dx_vals[layer],
        note=f"BG{layer} bg_dx=0x{dx_vals[layer]:02X}")

    m.write_ctrl(20 + layer, 0xBE00 | dy_vals[layer])
    rec(op="write", addr=ctrl_word_addr(20 + layer), data=0xBE00 | dy_vals[layer],
        be=3, note=f"BG{layer}_DY write (low byte=0x{dy_vals[layer]:02X})")
    rec(op="check_bg_dy", layer=layer, exp=dy_vals[layer],
        note=f"BG{layer} bg_dy=0x{dy_vals[layer]:02X}")

# =============================================================================
# 13. Text scroll round-trip
# =============================================================================
m.write_ctrl(12, 0x0100)
rec(op="write", addr=ctrl_word_addr(12), data=0x0100, be=3,
    note="TEXT_XSCROLL write 0x0100")
rec(op="read", addr=ctrl_word_addr(12), exp_dout=0x0100,
    note="TEXT_XSCROLL readback")

m.write_ctrl(13, 0x0200)
rec(op="write", addr=ctrl_word_addr(13), data=0x0200, be=3,
    note="TEXT_YSCROLL write 0x0200")
rec(op="read", addr=ctrl_word_addr(13), exp_dout=0x0200,
    note="TEXT_YSCROLL readback")

# =============================================================================
# 14. Byte-enable partial writes
# =============================================================================
# Write known value, then overwrite only high byte
m.write_ctrl(0, 0x0000)
rec(op="write", addr=ctrl_word_addr(0), data=0x0000, be=3,
    note="BG0_XSCROLL clear to 0")
# Write low byte only (be=1)
m.write_ctrl(0, 0x00AB, be=0x1)
rec(op="write", addr=ctrl_word_addr(0), data=0x00AB, be=1,
    note="BG0_XSCROLL write low byte 0xAB only (be=1)")
rec(op="read", addr=ctrl_word_addr(0), exp_dout=m.read_ctrl(0),
    note=f"BG0_XSCROLL readback after low-byte-only write: expect 0x{m.read_ctrl(0):04X}")

# Write high byte only (be=2) on top of that
m.write_ctrl(0, 0xCD00, be=0x2)
rec(op="write", addr=ctrl_word_addr(0), data=0xCD00, be=2,
    note="BG0_XSCROLL write high byte 0xCD only (be=2)")
rec(op="read", addr=ctrl_word_addr(0), exp_dout=m.read_ctrl(0),
    note=f"BG0_XSCROLL readback after high-byte-only write: expect 0x{m.read_ctrl(0):04X}")

# =============================================================================
# 15. Register readback after reset — all ctrl regs should be 0
# =============================================================================
rec(op="reset", note="reset before register-zero check")
m2 = TC0480SCPModel()   # fresh model mirrors the reset
rec(op="read", addr=ctrl_word_addr(0),  exp_dout=0x0000, note="ctrl[0]=0 after reset")
rec(op="read", addr=ctrl_word_addr(15), exp_dout=0x0000, note="ctrl[15]=0 after reset")
rec(op="read", addr=ctrl_word_addr(23), exp_dout=0x0000, note="ctrl[23]=0 after reset")

# =============================================================================
# 16. Unknown word 14 — should write/read back (no functional decode)
# =============================================================================
rec(op="write", addr=ctrl_word_addr(14), data=0xDEAD, be=3,
    note="ctrl[14] (unused) write 0xDEAD")
rec(op="read",  addr=ctrl_word_addr(14), exp_dout=0xDEAD,
    note="ctrl[14] (unused) readback 0xDEAD")

# =============================================================================
# Write output
# =============================================================================
total = len(records)
print(f"Generating {total} test vectors → {OUTFILE}")
with open(OUTFILE, "w") as f:
    for r in records:
        f.write(json.dumps(r) + "\n")
print("Done.")
