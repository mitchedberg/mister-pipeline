"""
Generate tier1_vectors.jsonl for TC0110PCR Gate 4 testbench.

Each line: {"addr": N, "data": N, "exp_r": N, "exp_g": N, "exp_b": N,
            "exp_cpu_dout": N, "note": "..."}

The testbench sequence per vector:
  tick 1: addr_write (cpu_cs=1, cpu_we=1, cpu_addr=0, cpu_din=addr<<1)
  tick 2: data_write (cpu_cs=1, cpu_we=1, cpu_addr=1, cpu_din=data)
  tick 3: idle — pal_ram_cpu_rd captures new data
  tick 4: idle — cpu_dout captures pal_ram_cpu_rd  → READ cpu_dout
  tick 5: pxl_in=addr, pxl_valid=1 — pal_ram_pxl_rd captures data
  tick 6: pxl_in=addr, pxl_valid=1 — color_reg captures pal_ram_pxl_rd → READ r/g/b
"""

import json
import random
import sys
import os

sys.path.insert(0, os.path.dirname(__file__))
from pcr_model import TC0110PCR

random.seed(0xC0FFEE)

model = TC0110PCR(step_mode=0)
vectors = []

def add_vec(addr: int, data: int, note: str = "") -> None:
    r, g, b = TC0110PCR.decode_color(data)
    vectors.append({
        "addr": addr,
        "data": data,
        "exp_r": r,
        "exp_g": g,
        "exp_b": b,
        "exp_cpu_dout": data & 0xFFFF,
        "note": note
    })

# ── Basic entries at address 0 ─────────────────────────────────────────────
add_vec(0x000, 0x0000, "zero entry")
add_vec(0x000, 0x7FFF, "all channels max (addr 0)")

# ── Individual channel tests ───────────────────────────────────────────────
add_vec(0x001, 0x001F, "R=31 only (addr 1)")
add_vec(0x002, 0x03E0, "G=31 only (addr 2)")
add_vec(0x003, 0x7C00, "B=31 only (addr 3)")
add_vec(0x004, 0x0001, "R=1 only")
add_vec(0x005, 0x0020, "G=1 only")
add_vec(0x006, 0x0400, "B=1 only")
add_vec(0x007, 0x0010, "R=16 only")
add_vec(0x008, 0x0200, "G=16 only")
add_vec(0x009, 0x4000, "B=16 only")

# ── Bit 15 stored but not reflected in R/G/B ──────────────────────────────
add_vec(0x00A, 0x8000, "bit15 set only — all DAC outputs zero")
add_vec(0x00B, 0x801F, "bit15 set + R=31")
add_vec(0x00C, 0xFFFF, "all bits set — R=31 G=31 B=31 (bit15 ignored)")

# ── Two-bit alternating patterns ─────────────────────────────────────────
add_vec(0x010, 0x5555, "alternating bits 0xAAAA→R/G/B split check")
add_vec(0x011, 0x2AAA, "alternating bits")
add_vec(0x012, 0x1555, "pattern 0x1555")
add_vec(0x013, 0x6318, "pattern R=24 G=24 B=24")

# ── Boundary addresses ────────────────────────────────────────────────────
add_vec(0x000, 0x0001, "addr 0x000 minimum")
add_vec(0xFFF, 0x7FFF, "addr 0xFFF maximum")
add_vec(0x800, 0x4210, "addr 0x800 midpoint")
add_vec(0x7FF, 0x3DEF, "addr 0x7FF")

# ── Sparse writes to verify no cross-contamination ───────────────────────
SPARSE_ADDRS = [0x100, 0x101, 0x1FF, 0x200, 0x3FF, 0x400, 0x7FE, 0x7FF]
for addr in SPARSE_ADDRS:
    data = random.randint(0, 0x7FFF)
    add_vec(addr, data, f"sparse addr 0x{addr:03X}")

# ── Sequential block: addr 0x500..0x51F ───────────────────────────────────
for i in range(32):
    addr = 0x500 + i
    data = (i * 0x421) & 0x7FFF   # walks through R/G/B
    add_vec(addr, data, f"sequential block 0x{addr:03X}")

# ── Random palette entries across full address space ─────────────────────
for _ in range(120):
    addr = random.randint(0, 0xFFF)
    data = random.randint(0, 0xFFFF)  # include bit 15
    add_vec(addr, data, f"random addr=0x{addr:03X}")

# ── Re-verify that overwriting an entry works ─────────────────────────────
add_vec(0x000, 0x0000, "overwrite addr 0 with 0")
add_vec(0x000, 0x1234, "overwrite addr 0 with 0x1234")
add_vec(0x001, 0x0000, "overwrite addr 1 with 0")
add_vec(0x001, 0x5678, "overwrite addr 1 with 0x5678")

# ── Pure color ramp: R 0..31 at addrs 0x200..0x21F ───────────────────────
for v in range(32):
    add_vec(0x200 + v, v, f"R ramp v={v}")

# ── Pure color ramp: G 0..31 at addrs 0x220..0x23F ───────────────────────
for v in range(32):
    add_vec(0x220 + v, v << 5, f"G ramp v={v}")

# ── Pure color ramp: B 0..31 at addrs 0x240..0x25F ───────────────────────
for v in range(32):
    add_vec(0x240 + v, v << 10, f"B ramp v={v}")

# Write JSONL
out_path = os.path.join(os.path.dirname(__file__), "tier1_vectors.jsonl")
with open(out_path, "w") as f:
    for v in vectors:
        f.write(json.dumps(v) + "\n")

print(f"Generated {len(vectors)} vectors → {out_path}")
