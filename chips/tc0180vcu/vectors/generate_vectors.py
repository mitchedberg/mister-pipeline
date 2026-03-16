"""
Generate tier1_vectors.jsonl for TC0180VCU Gate 4 testbench.

Tests cover:
  1. Control register read/write (all 16 registers, both byte lanes)
  2. VRAM access: write/read at boundary addresses
  3. Sprite RAM access
  4. Scroll RAM access
  5. Control register bank-select fields (fg_bank0/1, bg_bank0/1)
  6. TX rampage field
  7. Video control byte
  8. Region isolation (write one region, verify no cross-contamination)

Each vector:
  {"op": "write"|"read",
   "addr": N,          <- 19-bit word address
   "data": N,          <- 16-bit write data (or 0 for reads)
   "be": N,            <- byte enables (3=both, 2=high only, 1=low only)
   "exp_dout": N,      <- expected cpu_dout on next cycle after read
   "note": "..."}
"""

import json
import os
import random

random.seed(0xB0B0_F2)

sys_path_dir = os.path.dirname(__file__)
import sys; sys.path.insert(0, sys_path_dir)
from vcu_model import TC0180VCU

m = TC0180VCU()
vectors = []


def w(addr, data, be=3, note=""):
    m.write(addr, data, be)
    vectors.append({"op": "write", "addr": addr, "data": data, "be": be,
                    "exp_dout": 0, "note": note})


def r(addr, note=""):
    exp = m.read(addr)
    vectors.append({"op": "read",  "addr": addr, "data": 0, "be": 3,
                    "exp_dout": exp, "note": note})


# ── Address constants ───────────────────────────────────────────────────────
VRAM_BASE    = 0x00000   # word addr 0
SPRITE_BASE  = 0x08000   # word addr 0x8000 = byte 0x10000
SCROLL_BASE  = 0x09C00   # word addr 0x9C00 = byte 0x13800
CTRL_BASE    = 0x0C000   # word addr 0xC000 = byte 0x18000
# (framebuffer at 0x20000+ — not tested in this tier)

# ──────────────────────────────────────────────────────────────────────────────
# 1. Control registers — write all 16, read back
# ──────────────────────────────────────────────────────────────────────────────
test_ctrl_vals = [
    0xA500, 0x1200, 0xFF00, 0x0100, 0x3F00, 0x2000, 0x0F00, 0x9800,
    0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
]
for i, val in enumerate(test_ctrl_vals):
    w(CTRL_BASE + i, val, be=3, note=f"ctrl[{i}] write {val:#06x}")
for i, val in enumerate(test_ctrl_vals):
    r(CTRL_BASE + i, note=f"ctrl[{i}] readback")

# ── Ctrl byte-lane: high byte only ──
w(CTRL_BASE + 0, 0x5500, be=2, note="ctrl[0] high-byte write 0x55")
r(CTRL_BASE + 0, note="ctrl[0] after high-byte write")

# ── Ctrl byte-lane: low byte only ──
w(CTRL_BASE + 1, 0x00AA, be=1, note="ctrl[1] low-byte write 0xAA")
r(CTRL_BASE + 1, note="ctrl[1] after low-byte write")

# ── All ctrl zeros (reset state) ──
for i in range(16):
    w(CTRL_BASE + i, 0x0000, be=3, note=f"ctrl[{i}] clear")
for i in range(16):
    r(CTRL_BASE + i, note=f"ctrl[{i}] zero check")

# ──────────────────────────────────────────────────────────────────────────────
# 2. VRAM — boundary addresses
# ──────────────────────────────────────────────────────────────────────────────
vram_addrs = [
    (VRAM_BASE + 0x0000, 0xABCD, "vram[0] first"),
    (VRAM_BASE + 0x0001, 0x1234, "vram[1]"),
    (VRAM_BASE + 0x0FFF, 0x5678, "vram[0xFFF] bank boundary"),
    (VRAM_BASE + 0x1000, 0x9ABC, "vram[0x1000]"),
    (VRAM_BASE + 0x3FFF, 0xDEAD, "vram[0x3FFF] tile map boundary"),
    (VRAM_BASE + 0x4000, 0xBEEF, "vram[0x4000] BG bank start"),
    (VRAM_BASE + 0x7FFE, 0xCAFE, "vram[0x7FFE] near end"),
    (VRAM_BASE + 0x7FFF, 0xF00D, "vram[0x7FFF] last word"),
]
for addr, data, note in vram_addrs:
    w(addr, data, be=3, note=note + " write")
for addr, data, note in vram_addrs:
    r(addr, note=note + " readback")

# ── VRAM byte-lane writes ──
w(VRAM_BASE + 0x100, 0xFF00, be=2, note="vram high byte only write")
r(VRAM_BASE + 0x100, note="vram after high byte write")
w(VRAM_BASE + 0x100, 0x00FF, be=1, note="vram low byte only write")
r(VRAM_BASE + 0x100, note="vram after low byte write")

# ── VRAM bank-select test: write different words to two banks ──
# Set fg_bank0=0, fg_bank1=2 → tile codes at [0x000], attrs at [0x2000]
w(CTRL_BASE + 0, 0x2000, be=2, note="ctrl[0]: fg_bank0=0, fg_bank1=2")
w(VRAM_BASE + 0x000, 0x0042, be=3, note="vram: fg tile code at bank0")
w(VRAM_BASE + 0x2000, 0x001F, be=3, note="vram: fg attr at bank1")
r(VRAM_BASE + 0x000, note="vram: fg tile code bank0 readback")
r(VRAM_BASE + 0x2000, note="vram: fg attr bank1 readback")

# Verify model decoded FG tile correctly
code, color, flipx, flipy = m.fg_tile(0, 0)
assert code == 0x0042, f"fg_tile code mismatch: {code:#x}"
assert color == 0x1F,  f"fg_tile color mismatch: {color:#x}"

# ── BG bank test ──
w(CTRL_BASE + 1, 0x4100, be=2, note="ctrl[1]: bg_bank0=1, bg_bank1=4")
w(VRAM_BASE + 0x1000, 0x7FFF, be=3, note="vram: bg tile at bank0=1")
w(VRAM_BASE + 0x4000, 0xC000, be=3, note="vram: bg attr at bank1=4 (flipx+flipy)")
r(VRAM_BASE + 0x1000, note="vram: bg tile readback")
r(VRAM_BASE + 0x4000, note="vram: bg attr readback")

code, color, flipx, flipy = m.bg_tile(0, 0)
assert code == 0x7FFF
assert flipx is True
assert flipy is True

# ── TX tile test ──
w(CTRL_BASE + 6, 0x0200, be=2, note="ctrl[6]: tx_rampage=2 → tx_base=0x1000")
w(CTRL_BASE + 4, 0x0100, be=2, note="ctrl[4]: tx_bank0=1 → gfx prefix=0x800")
# TX at (0,0): vram[0x1000] = tile word
w(VRAM_BASE + 0x1000, 0x50FF, be=3,
  note="vram: tx tile (color=5, bank_sel=1, idx=0x0FF)")
gfx_code, color = m.tx_tile(0, 0)
tx_bank1 = m.tx_bank1  # =0 (not written)
# bank_sel=1 → uses tx_bank1=0 → gfx_code = 0<<11 | 0xFF = 0xFF
r(VRAM_BASE + 0x1000, note="tx tile readback")

# ──────────────────────────────────────────────────────────────────────────────
# 3. Sprite RAM — boundary + all fields
# ──────────────────────────────────────────────────────────────────────────────
def sp_base(idx):
    return SPRITE_BASE + idx * 8

# Sprite 0 — first (highest priority)
w(sp_base(0)+0, 0x1234, note="spr[0] code=0x1234")
w(sp_base(0)+1, 0x801F, note="spr[0] flipy=1, color=0x1F")
w(sp_base(0)+2, 0x0050, note="spr[0] x=80")
w(sp_base(0)+3, 0x0040, note="spr[0] y=64")
w(sp_base(0)+4, 0x4020, note="spr[0] zoomx=0x40, zoomy=0x20")
w(sp_base(0)+5, 0x0000, note="spr[0] single tile")
for i in range(6):
    r(sp_base(0)+i, note=f"spr[0] word{i} readback")

# Sprite 407 — last (lowest priority)
w(sp_base(407)+0, 0x7FFF, note="spr[407] code=0x7FFF (max)")
w(sp_base(407)+1, 0x403F, note="spr[407] flipx=1, color=0x3F")
w(sp_base(407)+2, 0x01FF, note="spr[407] x=0x1FF (511)")
w(sp_base(407)+3, 0x01FF, note="spr[407] y=511")
w(sp_base(407)+4, 0x8080, note="spr[407] zoom 50% both")
w(sp_base(407)+5, 0x0303, note="spr[407] big sprite 4×4")
for i in range(6):
    r(sp_base(407)+i, note=f"spr[407] word{i} readback")

# Sprite with negative X/Y coordinates
w(sp_base(10)+2, 0x03FF, note="spr[10] x=0x3FF (-1 signed)")
w(sp_base(10)+3, 0x03FF, note="spr[10] y=-1")
for i in range(3):
    r(sp_base(10)+i, note=f"spr[10] word{i}")

# Verify model sprite decode
s = m.sprite(0)
assert s['code'] == 0x1234
assert s['color'] == 0x1F
assert s['flipy'] is True
assert s['flipx'] is False
assert s['x'] == 80
assert s['y'] == 64
assert s['zoomx'] == 0x40
assert s['zoomy'] == 0x20
assert s['is_big'] is False

s407 = m.sprite(407)
assert s407['is_big'] is True
assert s407['x_num'] == 3
assert s407['y_num'] == 3

# ──────────────────────────────────────────────────────────────────────────────
# 4. Scroll RAM
# ──────────────────────────────────────────────────────────────────────────────
# FG scroll (plane 0) at offset 0
w(SCROLL_BASE + 0, 0x00A0, note="fg scrollX block0 = 0x00A0")
w(SCROLL_BASE + 1, 0x0010, note="fg scrollY block0 = 0x0010")
r(SCROLL_BASE + 0, note="fg scrollX readback")
r(SCROLL_BASE + 1, note="fg scrollY readback")

# BG scroll (plane 1) at offset 0x200
w(SCROLL_BASE + 0x200, 0x01F0, note="bg scrollX block0")
w(SCROLL_BASE + 0x201, 0x00F0, note="bg scrollY block0")
r(SCROLL_BASE + 0x200, note="bg scrollX readback")
r(SCROLL_BASE + 0x201, note="bg scrollY readback")

# Set ctrl[2] for multi-block FG scroll: lpb=16 (ctrl=0xF000 → N=0xF0=240 → lpb=16)
w(CTRL_BASE + 2, 0xF000, be=2, note="ctrl[2]: fg lpb=16 (N=0xF0)")
assert m.fg_lpb == 16, f"fg_lpb={m.fg_lpb}"
# Write scrollX for block 1 (at word index 1*2*16=32)
w(SCROLL_BASE + 32, 0x0200, note="fg scrollX block1 (lpb=16)")
w(SCROLL_BASE + 33, 0x0080, note="fg scrollY block1")
r(SCROLL_BASE + 32, note="fg block1 scrollX readback")
r(SCROLL_BASE + 33, note="fg block1 scrollY readback")

# Verify scroll decode
sx, sy = m.fg_scroll(0)   # scanline 0 → block 0
assert sx == 0x00A0
assert sy == 0x0010
sx, sy = m.fg_scroll(16)  # scanline 16 → block 1
assert sx == 0x0200
assert sy == 0x0080

# ──────────────────────────────────────────────────────────────────────────────
# 5. Region isolation — write VRAM, verify sprite/scroll/ctrl unchanged
# ──────────────────────────────────────────────────────────────────────────────
# Clear ctrl, write distinctive pattern to VRAM only
for i in range(16):
    w(CTRL_BASE + i, 0x0000, note=f"isolation: clear ctrl[{i}]")
w(VRAM_BASE + 0x500, 0xAAAA, note="isolation: write vram[0x500]")
w(VRAM_BASE + 0x501, 0x5555, note="isolation: write vram[0x501]")
# Verify ctrl registers still zero
for i in range(8):
    r(CTRL_BASE + i, note=f"isolation: ctrl[{i}] still 0")
# Verify sprite area at known-written offset unchanged
r(sp_base(0)+0, note="isolation: spr[0] code unchanged")

# ──────────────────────────────────────────────────────────────────────────────
# 6. Video control byte fields
# ──────────────────────────────────────────────────────────────────────────────
# screen_flip=1
w(CTRL_BASE + 7, 0x1000, be=2, note="video_ctrl: screen_flip=1")
r(CTRL_BASE + 7, note="video_ctrl readback flip=1")
assert m.video_ctrl & 0x10, "screen_flip not set"

# sprite priority mode 1
w(CTRL_BASE + 7, 0x0800, be=2, note="video_ctrl: sprite_priority=1")
r(CTRL_BASE + 7, note="video_ctrl readback priority=1")

# manual FB + page select
w(CTRL_BASE + 7, 0xC000, be=2, note="video_ctrl: fb_manual=1, fb_page=1")
r(CTRL_BASE + 7, note="video_ctrl fb manual")

# all video ctrl bits
w(CTRL_BASE + 7, 0xB900, be=2, note="video_ctrl: all bits")
r(CTRL_BASE + 7, note="video_ctrl all bits readback")

# ──────────────────────────────────────────────────────────────────────────────
# 7. Random VRAM / Sprite / Scroll access
# ──────────────────────────────────────────────────────────────────────────────
for _ in range(50):
    addr = random.randint(0, 0x7FFF)
    val  = random.randint(0, 0xFFFF)
    w(VRAM_BASE + addr, val, note="random vram write")
    r(VRAM_BASE + addr, note="random vram readback")

for _ in range(30):
    idx  = random.randint(0, 407)
    word = random.randint(0, 7)
    val  = random.randint(0, 0xFFFF)
    w(sp_base(idx) + word, val, note="random sprite write")
    r(sp_base(idx) + word, note="random sprite readback")

for _ in range(20):
    idx = random.randint(0, 0x3FF)
    val = random.randint(0, 0xFFFF)
    w(SCROLL_BASE + idx, val, note="random scroll write")
    r(SCROLL_BASE + idx, note="random scroll readback")

# ──────────────────────────────────────────────────────────────────────────────
# Write output
# ──────────────────────────────────────────────────────────────────────────────
out_path = os.path.join(os.path.dirname(__file__), "tier1_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
