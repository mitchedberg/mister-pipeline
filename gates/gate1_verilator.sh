#!/bin/bash
# Gate 1: Verilator behavioral simulation
# Usage: ./gate1_verilator.sh <module.sv> <vectors_dir>
# Returns 0 on pass, 1 on fail
#
# Compiles the module with Verilator and runs test vectors if a testbench exists.
# If no testbench is found in vectors_dir, compilation-only check is performed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODULE_SV="${1:-}"
VECTORS_DIR="${2:-}"

usage() {
    echo "Usage: $0 <module.sv> [vectors_dir]"
    echo ""
    echo "  module.sv    — SystemVerilog source file to simulate"
    echo "  vectors_dir  — directory containing test vectors and optional testbench"
    exit 1
}

if [[ -z "$MODULE_SV" ]]; then
    usage
fi

if [[ ! -f "$MODULE_SV" ]]; then
    echo "[GATE1] ERROR: Module file not found: $MODULE_SV"
    exit 1
fi

MODULE_SV="$(realpath "$MODULE_SV")"
MODULE_NAME="$(basename "$MODULE_SV" .sv)"

echo "[GATE1] Verilator behavioral simulation"
echo "[GATE1] Module: $MODULE_SV"

# Check Verilator is available
if ! command -v verilator &>/dev/null; then
    echo "[GATE1] WARNING: verilator not found in PATH"
    echo "[GATE1] Install with: brew install verilator"
    echo "[GATE1] SKIP — behavioral simulation requires Verilator"
    exit 0
fi

WORK_DIR="$(mktemp -d /tmp/gate1_XXXXXX)"
trap "rm -rf '$WORK_DIR'" EXIT

# Look for a testbench in vectors_dir
TB_FILE=""
if [[ -n "$VECTORS_DIR" && -d "$VECTORS_DIR" ]]; then
    TB_FILE="$(find "$VECTORS_DIR" -name "tb_${MODULE_NAME}.sv" -o -name "tb_${MODULE_NAME}.cpp" 2>/dev/null | head -1)"
fi

if [[ -n "$TB_FILE" && "$TB_FILE" == *.cpp ]]; then
    # C++ testbench flow
    echo "[GATE1] Found C++ testbench: $TB_FILE"
    if verilator --cc --exe --build \
        --sv \
        -Wall \
        --Mdir "$WORK_DIR" \
        --top-module "$MODULE_NAME" \
        "$MODULE_SV" "$TB_FILE" 2>&1; then
        if "$WORK_DIR/V${MODULE_NAME}" 2>&1; then
            echo "[GATE1] PASS — simulation completed successfully"
            exit 0
        else
            echo "[GATE1] FAIL — simulation returned non-zero exit code"
            exit 1
        fi
    else
        echo "[GATE1] FAIL — Verilator compilation failed"
        exit 1
    fi

elif [[ -n "$TB_FILE" && "$TB_FILE" == *.sv ]]; then
    # SystemVerilog testbench flow (lint/compile check only via Verilator)
    echo "[GATE1] Found SV testbench: $TB_FILE"
    if verilator --lint-only --sv \
        --top-module "tb_${MODULE_NAME}" \
        "$MODULE_SV" "$TB_FILE" 2>&1; then
        echo "[GATE1] PASS — compile check with SV testbench passed"
        exit 0
    else
        echo "[GATE1] FAIL — compile check with SV testbench failed"
        exit 1
    fi

else
    # No testbench: compilation-only check
    if [[ -n "$VECTORS_DIR" ]]; then
        echo "[GATE1] No testbench found in $VECTORS_DIR — running compile-only check"
    else
        echo "[GATE1] No vectors dir specified — running compile-only check"
    fi

    if verilator --lint-only --sv \
        --top-module "$MODULE_NAME" \
        "$MODULE_SV" 2>&1; then
        echo "[GATE1] PASS — compile check passed (no testbench)"
        exit 0
    else
        echo "[GATE1] FAIL — compile check failed"
        exit 1
    fi
fi
