"""
Generate tier1_vectors.jsonl for TC0360PRI Gate 4 testbench.

Each line:
  {"regs": [...16 bytes...],
   "in0": N, "in1": N, "in2": N,   <- 15-bit color inputs
   "exp_out": N,                     <- expected 13-bit output
   "note": "..."}

The testbench:
  1. Writes all 16 register bytes via CPU bus
  2. Presents color_in0/1/2
  3. Checks color_out (combinational, sampled 1 cycle later)
"""

import json
import random
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from pri_model import TC0360PRI

random.seed(0xDEAD_F2)

vectors = []

def make_color(sel: int, pidx: int) -> int:
    """Pack sel[1:0] + pidx[12:0] into 15-bit color word."""
    return ((sel & 0x3) << 13) | (pidx & 0x1FFF)

def add_vec(regs, in0, in1, in2, note=""):
    m = TC0360PRI()
    for i, v in enumerate(regs):
        m.write(i, v)
    exp = m.mix(in0, in1, in2)
    vectors.append({
        "regs": list(regs),
        "in0": in0, "in1": in1, "in2": in2,
        "exp_out": exp,
        "note": note
    })

# ── Default registers: all zeros → no priority table entry → all output 0 ──
add_vec([0]*16, make_color(0,0x100), make_color(0,0x200), make_color(0,0x300),
        "zero regs → all inputs pri=0 → output 0")

# ── All transparent inputs ────────────────────────────────────────────────
base_regs = [0]*16
base_regs[4] = 0x54; base_regs[5] = 0x32   # in0: pri 4,5,3,2
base_regs[6] = 0x54; base_regs[7] = 0x32   # in1: pri 4,5,3,2
base_regs[8] = 0x54; base_regs[9] = 0x32   # in2: pri 4,5,3,2
add_vec(base_regs, make_color(0,0), make_color(0,0), make_color(0,0),
        "all transparent → output 0")

# ── Input 0 only ──────────────────────────────────────────────────────────
r = [0]*16
r[4] = 0x50  # in0 sel0=5, sel1=0
add_vec(r, make_color(0, 0x042), make_color(0, 0), make_color(0, 0),
        "in0 opaque (sel=0,pri=5), in1/in2 transparent → out=in0")

# ── Input 1 only ──────────────────────────────────────────────────────────
r = [0]*16
r[6] = 0x70  # in1 sel0=7
add_vec(r, make_color(0, 0), make_color(0, 0x123), make_color(0, 0),
        "in1 opaque (sel=0,pri=7), in0/in2 transparent → out=in1")

# ── Input 2 only ──────────────────────────────────────────────────────────
r = [0]*16
r[8] = 0xA0  # in2 sel0=10
add_vec(r, make_color(0,0), make_color(0,0), make_color(0, 0x555),
        "in2 opaque (sel=0,pri=10) → out=in2")

# ── In0 beats in1 (higher priority) ──────────────────────────────────────
r = [0]*16
r[4] = 0x80; r[6] = 0x50  # in0 pri0=8, in1 pri0=5
add_vec(r, make_color(0,0x100), make_color(0,0x200), make_color(0,0),
        "in0 pri=8 > in1 pri=5 → out=in0")

# ── In1 beats in0 (higher priority) ──────────────────────────────────────
r = [0]*16
r[4] = 0x50; r[6] = 0x80  # in0 pri0=5, in1 pri0=8
add_vec(r, make_color(0,0x100), make_color(0,0x200), make_color(0,0),
        "in1 pri=8 > in0 pri=5 → out=in1")

# ── Tie: in0 beats in1 (same priority, in0 wins) ─────────────────────────
r = [0]*16
r[4] = 0x70; r[6] = 0x70  # both pri0=7
add_vec(r, make_color(0,0x111), make_color(0,0x222), make_color(0,0),
        "tie pri=7, in0 wins by position")

# ── All three inputs, varying priorities ─────────────────────────────────
r = [0]*16
r[4] = 0x30  # in0 pri0=3
r[6] = 0x70  # in1 pri0=7
r[8] = 0x50  # in2 pri0=5
add_vec(r, make_color(0,0x100), make_color(0,0x200), make_color(0,0x300),
        "3-way: in1 pri=7 wins")

# ── Priority selector sweep: all 4 selectors for each input ──────────────
r = [0]*16
r[4] = 0xBA; r[5] = 0xDC   # in0: sel0=A,sel1=B,sel2=C,sel3=D (10,11,12,13)
r[6] = 0x22; r[7] = 0x22   # in1: all sel → pri=2
r[8] = 0x11; r[9] = 0x11   # in2: all sel → pri=1

for sel in range(4):
    add_vec(r, make_color(sel, 0x100), make_color(sel, 0x200), make_color(sel, 0x300),
            f"in0 sel={sel} → pri={[0xA,0xB,0xC,0xD][sel]}, in1/in2 lower → out=in0")

# ── Input with sel, in2 wins when in0/in1 transparent ────────────────────
r = [0]*16
r[4] = 0x50; r[6] = 0x50  # in0/in1 pri=5
r[8] = 0x50               # in2 pri=5 (same but all transparent so in2 gets no chance...
# actually let's make in2 win: in0/in1 transparent
add_vec(r, make_color(0,0), make_color(0,0), make_color(0, 0x400),
        "in0/in1 transparent, in2 opaque → out=in2")

# ── Large sweep: random register configs and random colors ───────────────
for _ in range(200):
    r = [0]*16
    # Randomize only priority registers 4..9
    for i in [4,5,6,7,8,9]:
        r[i] = random.randint(0, 0xFF)
    # Random 15-bit inputs (mix transparent and opaque)
    def rand_color():
        sel  = random.randint(0, 3)
        pidx = random.choice([0, 0, random.randint(1, 0x1FFF)])  # 33% transparent
        return make_color(sel, pidx)
    add_vec(r, rand_color(), rand_color(), rand_color(), "random")

# ── Priority value 0 in table = effectively disabled ─────────────────────
r = [0]*16
r[4] = 0x00  # in0 all zeros
r[6] = 0x30  # in1 sel0=3 only
add_vec(r, make_color(0, 0x100), make_color(0, 0x200), make_color(0, 0),
        "in0 pri=0 → disabled even if opaque; in1 pri=3 → wins")

# ── All inputs opaque but all priorities zero → output 0 ─────────────────
add_vec([0]*16, make_color(0,0x100), make_color(0,0x200), make_color(0,0x300),
        "all pri=0 (regs zero) → output 0 even if opaque")

# ── Exhaustive sel coverage: in2 uses all 4 selectors ────────────────────
r = [0]*16
r[8] = 0xFE; r[9] = 0xDC   # in2: sel0=E,sel1=F,sel2=C,sel3=D (14,15,12,13)
for sel in range(4):
    add_vec(r, make_color(0,0), make_color(0,0), make_color(sel, 0x700),
            f"in2 sel={sel} only active")

# ── Boundary palette index values ─────────────────────────────────────────
r = [0]*16
r[4] = 0x10; r[6] = 0x20; r[8] = 0x30  # in0=1,in1=2,in2=3
for pidx in [1, 0x7FF, 0xFFF, 0x1FFF]:
    add_vec(r, make_color(0,pidx), make_color(0,0), make_color(0,0),
            f"in0 wins with pidx=0x{pidx:04X}")

out_path = os.path.join(os.path.dirname(__file__), "tier1_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
