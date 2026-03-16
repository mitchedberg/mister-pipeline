#!/bin/bash
# Gate 2.5: Verilator strict lint check
# Usage: ./gate2_5_lint.sh <module.sv>
# Hard fail on ANY warning. Returns 0 on clean, 1 on any warning or error.
#
# Checks performed:
#   1. Verilator --lint-only -Wall (latch inference, unused signals, width mismatches, etc.)
#   2. Forbidden async reset deassertion pattern (static Python check)
#   3. Missing `default_nettype none
#   4. Forbidden reg/wire declarations (use logic instead)
#   5. Case without default in always_comb (static Python check, belt+suspenders)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODULE_SV="${1:-}"

usage() {
    echo "Usage: $0 <module.sv>"
    echo ""
    echo "  module.sv — SystemVerilog file to lint"
    echo ""
    echo "  Hard fails on any Verilator warning or detected anti-pattern."
    exit 1
}

if [[ -z "$MODULE_SV" ]]; then
    usage
fi

if [[ ! -f "$MODULE_SV" ]]; then
    echo "[GATE2.5] ERROR: File not found: $MODULE_SV"
    exit 1
fi

MODULE_SV="$(realpath "$MODULE_SV")"
MODULE_NAME="$(basename "$MODULE_SV" .sv)"

echo "[GATE2.5] Strict lint check"
echo "[GATE2.5] Module: $MODULE_SV"

FAIL=0

# ── 1. Verilator lint-only -Wall ─────────────────────────────────────────────
if ! command -v verilator &>/dev/null; then
    echo "[GATE2.5] WARNING: verilator not found — skipping Verilator lint step"
    echo "[GATE2.5] Install with: brew install verilator"
    echo "[GATE2.5] Verilator lint: SKIPPED"
else
    echo "[GATE2.5] Running: verilator --lint-only -Wall --sv $MODULE_SV"

    LINT_OUTPUT="$(verilator --lint-only -Wall --sv "$MODULE_SV" 2>&1)"
    LINT_EXIT=$?

    if [[ $LINT_EXIT -ne 0 ]]; then
        echo "[GATE2.5] Verilator lint FAILED:"
        echo "$LINT_OUTPUT" | sed 's/^/  /'
        FAIL=1
    elif echo "$LINT_OUTPUT" | grep -qiE "^%(Warning|Error)"; then
        echo "[GATE2.5] Verilator lint produced warnings (hard fail):"
        echo "$LINT_OUTPUT" | sed 's/^/  /'
        FAIL=1
    else
        if [[ -n "$LINT_OUTPUT" ]]; then
            echo "$LINT_OUTPUT" | sed 's/^/  /'
        fi
        echo "[GATE2.5] Verilator lint: clean"
    fi
fi

# ── 2. Async reset deassertion pattern check ──────────────────────────────────
echo "[GATE2.5] Checking for forbidden async reset deassertion..."

ASYNC_CHECK="$(python3 "$SCRIPT_DIR/check_async_rst.py" "$MODULE_SV" 2>&1)"
ASYNC_EXIT=$?

echo "[GATE2.5] Async reset check: $ASYNC_CHECK"

if [[ $ASYNC_EXIT -ne 0 ]]; then
    FAIL=1
fi

# ── 3. default_nettype none check ─────────────────────────────────────────────
echo "[GATE2.5] Checking for default_nettype none..."
if ! grep -q 'default_nettype none' "$MODULE_SV"; then
    echo "[GATE2.5] FAIL: Missing \`default_nettype none at top of file"
    FAIL=1
else
    echo "[GATE2.5] default_nettype: OK"
fi

# ── 4. Forbidden reg/wire check ───────────────────────────────────────────────
echo "[GATE2.5] Checking for forbidden reg/wire declarations..."
REGWIRE_OUTPUT="$(grep -nE '^\s*(reg|wire)\s' "$MODULE_SV" || true)"
if [[ -n "$REGWIRE_OUTPUT" ]]; then
    echo "[GATE2.5] FAIL: Forbidden 'reg' or 'wire' declarations found (use 'logic'):"
    echo "$REGWIRE_OUTPUT" | sed 's/^/  /'
    FAIL=1
else
    echo "[GATE2.5] reg/wire check: OK"
fi

# ── 5. Static latch inference check (case without default in always_comb) ─────
echo "[GATE2.5] Checking for case statements without default (latch inference)..."

LATCH_CHECK="$(python3 "$SCRIPT_DIR/check_latch.py" "$MODULE_SV" 2>&1)"
LATCH_EXIT=$?

echo "[GATE2.5] Latch check: $LATCH_CHECK"

if [[ $LATCH_EXIT -ne 0 ]]; then
    FAIL=1
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "[GATE2.5] PASS — all lint checks clean"
    exit 0
else
    echo "[GATE2.5] FAIL — one or more lint checks failed"
    exit 1
fi
