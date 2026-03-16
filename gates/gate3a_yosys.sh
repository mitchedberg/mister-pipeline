#!/bin/bash
# Gate 3a: Yosys structural synthesis + check
# Usage: ./gate3a_yosys.sh <module.sv>
# Returns 0 on clean synthesis, 1 on any error.
#
# Checks performed by Yosys:
#   - Multi-driver signals (two always blocks driving the same net)
#   - Unresolved module references
#   - Latch inference (additional confirmation beyond gate2.5)
#   - General synthesis errors

set -uo pipefail

MODULE_SV="${1:-}"

usage() {
    echo "Usage: $0 <module.sv>"
    echo ""
    echo "  module.sv — SystemVerilog file to synthesize and check"
    exit 1
}

if [[ -z "$MODULE_SV" ]]; then
    usage
fi

if [[ ! -f "$MODULE_SV" ]]; then
    echo "[GATE3A] ERROR: File not found: $MODULE_SV"
    exit 1
fi

MODULE_SV="$(realpath "$MODULE_SV")"
MODULE_NAME="$(basename "$MODULE_SV" .sv)"

echo "[GATE3A] Yosys structural synthesis + check"
echo "[GATE3A] Module: $MODULE_SV"

FAIL=0

# Check Yosys is available
if ! command -v yosys &>/dev/null; then
    echo "[GATE3A] WARNING: yosys not found — skipping Yosys synthesis step"
    echo "[GATE3A] Install with: brew install yosys"
    echo "[GATE3A] NOTE: Multi-driver, latch, and hierarchy checks require Yosys."
    echo "[GATE3A] Yosys synthesis: SKIPPED"
    echo ""
    echo "[GATE3A] SKIP — install Yosys for full structural check (brew install yosys)"
    # Exit 0 on macOS without yosys: don't block the pipeline for missing tool
    # gate2_5 already catches the most common static issues
    exit 0
fi

# Build Yosys script
YOSYS_SCRIPT="
read_verilog -sv \"${MODULE_SV}\";
hierarchy -check -top ${MODULE_NAME};
proc;
opt;
check -assert;
stat;
"

echo "[GATE3A] Running Yosys synthesis..."

YOSYS_OUTPUT="$(yosys -p "$YOSYS_SCRIPT" 2>&1)"
YOSYS_EXIT=$?

# Show output
echo "$YOSYS_OUTPUT" | sed 's/^/  /'

if [[ $YOSYS_EXIT -ne 0 ]]; then
    echo "[GATE3A] FAIL — Yosys returned non-zero exit code ($YOSYS_EXIT)"
    FAIL=1
fi

# Check for specific failure patterns in output
if echo "$YOSYS_OUTPUT" | grep -qiE "^ERROR:"; then
    echo "[GATE3A] FAIL — Yosys reported ERROR(s)"
    FAIL=1
fi

if echo "$YOSYS_OUTPUT" | grep -qiE "Warning.*multiple drivers|Warning.*multi-driver|ERROR.*multiple drivers"; then
    echo "[GATE3A] FAIL — Multi-driver signal detected (Yosys warning)"
    FAIL=1
fi

# Detect multiple always blocks creating registers for the same signal
# Pattern: "Creating register for signal `\module.\signame'" appearing more than once for same signame
DUPLICATE_REGS="$(echo "$YOSYS_OUTPUT" | grep -oE "Creating register for signal [^ ]+" | sort | uniq -d || true)"
if [[ -n "$DUPLICATE_REGS" ]]; then
    echo "[GATE3A] FAIL — Multi-driver detected: same signal registered by multiple always blocks:"
    echo "$DUPLICATE_REGS" | sed 's/^/  /'
    FAIL=1
fi

# "No latch inferred" messages are informational (Yosys confirming no latch).
# Only fail if a latch IS inferred (without the "No" prefix).
if echo "$YOSYS_OUTPUT" | grep -iE "latch inferred|inferring latch" | grep -qviE "^[[:space:]]*No latch inferred"; then
    echo "[GATE3A] FAIL — Latch inference detected"
    FAIL=1
fi

if echo "$YOSYS_OUTPUT" | grep -qiE "Module .* not found|hierarchy check failed"; then
    echo "[GATE3A] FAIL — Unresolved module reference or hierarchy error"
    FAIL=1
fi

# Check for the Yosys "check" command assertions
if echo "$YOSYS_OUTPUT" | grep -qiE "found and reported [1-9][0-9]* problems"; then
    echo "[GATE3A] FAIL — Yosys check found problems"
    FAIL=1
fi

# Look for multiple drivers specifically via wire output
if echo "$YOSYS_OUTPUT" | grep -qiE "^Warning.*always_ff.*driven.*multiple"; then
    echo "[GATE3A] FAIL — Multiple drivers on always_ff signal"
    FAIL=1
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "[GATE3A] PASS — Yosys synthesis and check clean"
    exit 0
else
    echo "[GATE3A] FAIL — Yosys synthesis or check failed"
    exit 1
fi
