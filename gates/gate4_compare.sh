#!/bin/bash
# Gate 4: Behavioral comparison — AI-generated RTL vs MAME behavioral model
#
# Usage:
#   ./gate4_compare.sh <chip_dir>
#
# Where <chip_dir> is e.g. chips/cps1_obj
#
# Steps:
#   1. Run generate_vectors.py to produce tier1_vectors.jsonl + tier1_obj_ram.jsonl
#   2. Build Verilator testbench (Makefile in chip_dir/vectors/)
#   3. Run simulation and report PASS/FAIL
#
# Exit codes:
#   0 = all vectors PASS
#   1 = one or more vector FAIL
#   2 = build or setup error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <chip_dir>"
    echo "  e.g.: $0 chips/cps1_obj"
    exit 2
fi

CHIP_DIR="$REPO_ROOT/$1"
VEC_DIR="$CHIP_DIR/vectors"
RTL_DIR="$CHIP_DIR/rtl"

if [ ! -d "$CHIP_DIR" ]; then
    echo "[GATE4] ERROR: chip directory not found: $CHIP_DIR"
    exit 2
fi

if [ ! -d "$VEC_DIR" ]; then
    echo "[GATE4] ERROR: vectors directory not found: $VEC_DIR"
    exit 2
fi

CHIP_NAME="$(basename "$CHIP_DIR")"
echo "[GATE4] Behavioral comparison for: $CHIP_NAME"
echo "[GATE4] Chip directory: $CHIP_DIR"
echo "[GATE4] Vectors directory: $VEC_DIR"

# ── Step 1: Generate test vectors ────────────────────────────────────────────
echo ""
echo "[GATE4] Step 1: Generating test vectors..."
if [ ! -f "$VEC_DIR/generate_vectors.py" ]; then
    echo "[GATE4] ERROR: generate_vectors.py not found in $VEC_DIR"
    exit 2
fi

cd "$VEC_DIR"
python3 generate_vectors.py
if [ ! -f "$VEC_DIR/tier1_vectors.jsonl" ]; then
    echo "[GATE4] ERROR: tier1_vectors.jsonl not generated"
    exit 2
fi
echo "[GATE4] Vectors generated:"
echo "  tier1_vectors.jsonl: $(wc -l < tier1_vectors.jsonl) scanline records"
echo "  tier1_obj_ram.jsonl: $(wc -l < tier1_obj_ram.jsonl) OBJ RAM records"

# ── Step 2: Build Verilator testbench ────────────────────────────────────────
echo ""
echo "[GATE4] Step 2: Building Verilator testbench..."
if [ ! -f "$VEC_DIR/Makefile" ]; then
    echo "[GATE4] ERROR: Makefile not found in $VEC_DIR"
    exit 2
fi

if ! make -C "$VEC_DIR" build 2>&1; then
    echo "[GATE4] ERROR: Verilator build failed"
    exit 2
fi
echo "[GATE4] Build complete"

# ── Step 3: Run simulation ────────────────────────────────────────────────────
echo ""
echo "[GATE4] Step 3: Running behavioral comparison simulation..."
SIM="$VEC_DIR/obj_dir/Vcps1_obj"
if [ ! -f "$SIM" ]; then
    echo "[GATE4] ERROR: simulation binary not found: $SIM"
    exit 2
fi

# Capture simulation output
SIM_OUT=$("$SIM" "$VEC_DIR/tier1_vectors.jsonl" "$VEC_DIR/tier1_obj_ram.jsonl" 2>/dev/null)
SIM_EXIT=$?

echo "$SIM_OUT"

# ── Report ────────────────────────────────────────────────────────────────────
echo ""
echo "[GATE4] ============================================================"
if [ $SIM_EXIT -eq 0 ]; then
    echo "[GATE4] RESULT: PASS"
    echo "[GATE4] All behavioral vectors match."
    exit 0
else
    echo "[GATE4] RESULT: FAIL"
    echo "[GATE4] One or more behavioral vectors do not match."
    echo "[GATE4] See $CHIP_DIR/gate4_results.md for analysis."
    exit 1
fi
