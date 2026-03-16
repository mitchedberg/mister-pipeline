#!/bin/bash
# Master gate runner
# Usage: ./run_gates.sh <module.sv> [vectors_dir]
# Runs all gates in sequence, stops on first failure.
# Prints clear PASS/FAIL per gate and overall result.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODULE_SV="${1:-}"
VECTORS_DIR="${2:-}"

usage() {
    echo "Usage: $0 <module.sv> [vectors_dir]"
    echo ""
    echo "  module.sv   — SystemVerilog module to run through the gate pipeline"
    echo "  vectors_dir — test vectors directory (used by gate1)"
    echo ""
    echo "Gates run in order:"
    echo "  Gate 1   — Verilator behavioral simulation"
    echo "  Gate 2.5 — Verilator strict lint (-Wall, hard fail)"
    echo "  Gate 3a  — Yosys structural synthesis + check"
    echo "  Gate 3b  — Quartus map (Linux/CI only, stub on macOS)"
    exit 1
}

if [[ -z "$MODULE_SV" ]]; then
    usage
fi

if [[ ! -f "$MODULE_SV" ]]; then
    echo "ERROR: Module file not found: $MODULE_SV"
    exit 1
fi

MODULE_SV="$(realpath "$MODULE_SV")"
MODULE_NAME="$(basename "$MODULE_SV" .sv)"

# Color codes (disabled if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    BOLD=''
    RESET=''
fi

echo ""
echo "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo "${BOLD}║     MiSTer Pipeline — Gate Runner            ║${RESET}"
echo "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo "  Module:  $MODULE_SV"
echo "  Vectors: ${VECTORS_DIR:-(none)}"
echo ""

GATE_RESULTS=()
OVERALL_PASS=true
STOP_GATE=""

print_summary() {
    echo ""
    echo "${BOLD}════════════════════════════════════════════════${RESET}"
    echo "${BOLD}Gate Results:${RESET}"
    for r in "${GATE_RESULTS[@]}"; do
        if [[ "$r" == *PASS* || "$r" == *SKIP* ]]; then
            echo "  ${GREEN}✓ $r${RESET}"
        elif [[ "$r" == *FAIL* ]]; then
            echo "  ${RED}✗ $r${RESET}"
        else
            echo "  ${YELLOW}~ $r${RESET}"
        fi
    done
    echo ""
}

run_gate() {
    local gate_id="$1"
    local gate_name="$2"
    local gate_script="$3"
    shift 3
    local gate_args=("$@")

    echo "${BOLD}── ${gate_id}: ${gate_name} ──────────────────────────────${RESET}"

    if [[ ! -x "$gate_script" ]]; then
        echo "${YELLOW}[SKIP] Gate script not executable: $gate_script${RESET}"
        GATE_RESULTS+=("${gate_id}: SKIP (not executable)")
        echo ""
        return 0
    fi

    # Run gate, capture output and exit code
    local output
    local exit_code
    output="$("$gate_script" "${gate_args[@]}" 2>&1)"
    exit_code=$?

    echo "$output"
    echo ""

    if [[ $exit_code -eq 0 ]]; then
        echo "  ${GREEN}✓ ${gate_id} PASS${RESET}"
        GATE_RESULTS+=("${gate_id}: PASS")
    else
        echo "  ${RED}✗ ${gate_id} FAIL${RESET}"
        GATE_RESULTS+=("${gate_id}: FAIL")
        OVERALL_PASS=false
        STOP_GATE="$gate_id"
        return 1
    fi
    echo ""
}

# ── Gate 1: Verilator behavioral sim ─────────────────────────────────────────
if [[ -n "$VECTORS_DIR" ]]; then
    run_gate "Gate 1" "Verilator behavioral simulation" \
        "$SCRIPT_DIR/gate1_verilator.sh" \
        "$MODULE_SV" "$VECTORS_DIR" || true
else
    run_gate "Gate 1" "Verilator behavioral simulation" \
        "$SCRIPT_DIR/gate1_verilator.sh" \
        "$MODULE_SV" || true
fi

if [[ "$OVERALL_PASS" == false ]]; then
    print_summary
    echo "${RED}${BOLD}OVERALL: FAIL — stopped at $STOP_GATE${RESET}"
    exit 1
fi

# ── Gate 2.5: Strict lint ─────────────────────────────────────────────────────
run_gate "Gate 2.5" "Verilator strict lint (-Wall)" \
    "$SCRIPT_DIR/gate2_5_lint.sh" \
    "$MODULE_SV" || true

if [[ "$OVERALL_PASS" == false ]]; then
    print_summary
    echo "${RED}${BOLD}OVERALL: FAIL — stopped at $STOP_GATE${RESET}"
    exit 1
fi

# ── Gate 3a: Yosys ────────────────────────────────────────────────────────────
run_gate "Gate 3a" "Yosys structural synthesis + check" \
    "$SCRIPT_DIR/gate3a_yosys.sh" \
    "$MODULE_SV" || true

if [[ "$OVERALL_PASS" == false ]]; then
    print_summary
    echo "${RED}${BOLD}OVERALL: FAIL — stopped at $STOP_GATE${RESET}"
    exit 1
fi

# ── Gate 3b: Quartus (stub on macOS) ─────────────────────────────────────────
run_gate "Gate 3b" "Quartus map (Linux/CI only)" \
    "$SCRIPT_DIR/gate3b_quartus.sh" \
    "$MODULE_SV" || true

if [[ "$OVERALL_PASS" == false ]]; then
    print_summary
    echo "${RED}${BOLD}OVERALL: FAIL — stopped at $STOP_GATE${RESET}"
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary

if [[ "$OVERALL_PASS" == true ]]; then
    echo "${GREEN}${BOLD}OVERALL: PASS — module cleared all gates${RESET}"
    exit 0
else
    echo "${RED}${BOLD}OVERALL: FAIL — stopped at $STOP_GATE${RESET}"
    exit 1
fi
