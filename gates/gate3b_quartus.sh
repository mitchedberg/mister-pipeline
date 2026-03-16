#!/bin/bash
# Gate 3b: Quartus map (Linux/CI only)
# Usage: ./gate3b_quartus.sh <module.sv> [project_dir]
# Returns 0 on macOS (stub), 0 on Quartus pass, 1 on Quartus fail
#
# Full Quartus synthesis targets Cyclone V (5CSEBA6U23I7) — the DE10-Nano.
# This gate requires Quartus Lite installed and on PATH.
# On macOS: prints informational message and exits 0 (non-blocking).

set -uo pipefail

MODULE_SV="${1:-}"
PROJECT_DIR="${2:-}"

usage() {
    echo "Usage: $0 <module.sv> [project_dir]"
    echo ""
    echo "  module.sv   — top-level SystemVerilog file"
    echo "  project_dir — optional Quartus project directory (default: alongside module)"
    exit 1
}

if [[ -z "$MODULE_SV" ]]; then
    usage
fi

if [[ ! -f "$MODULE_SV" ]]; then
    echo "[GATE3B] ERROR: File not found: $MODULE_SV"
    exit 1
fi

MODULE_SV="$(realpath "$MODULE_SV")"
MODULE_NAME="$(basename "$MODULE_SV" .sv)"

echo "[GATE3B] Quartus synthesis gate"
echo "[GATE3B] Module: $MODULE_SV"

# ── macOS stub ───────────────────────────────────────────────────────────────
if [[ "$(uname)" == "Darwin" ]]; then
    echo "[GATE3B] STUB — Quartus is not available on macOS"
    echo "[GATE3B] Run this gate in Linux CI (GitHub Actions or dedicated Linux box)"
    echo "[GATE3B] Target device: Cyclone V 5CSEBA6U23I7 (DE10-Nano)"
    echo "[GATE3B] Exit 0 (non-blocking on macOS)"
    exit 0
fi

# ── Linux: check for Quartus ─────────────────────────────────────────────────
if ! command -v quartus_map &>/dev/null; then
    echo "[GATE3B] ERROR: quartus_map not found in PATH"
    echo "[GATE3B] Install Quartus Lite from: https://www.intel.com/quartus"
    echo "[GATE3B] Add Quartus bin directory to PATH"
    exit 1
fi

QUARTUS_VER="$(quartus_map --version 2>&1 | head -1)"
echo "[GATE3B] Quartus: $QUARTUS_VER"

# ── Set up project directory ──────────────────────────────────────────────────
if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(dirname "$MODULE_SV")/quartus_${MODULE_NAME}"
fi
mkdir -p "$PROJECT_DIR"

DEVICE="5CSEBA6U23I7"
FAMILY="Cyclone V"

echo "[GATE3B] Project dir: $PROJECT_DIR"
echo "[GATE3B] Target: $FAMILY $DEVICE"

# Generate minimal QSF
QSF_FILE="$PROJECT_DIR/${MODULE_NAME}.qsf"
cat > "$QSF_FILE" <<QSF
set_global_assignment -name FAMILY "$FAMILY"
set_global_assignment -name DEVICE $DEVICE
set_global_assignment -name TOP_LEVEL_ENTITY $MODULE_NAME
set_global_assignment -name SYSTEMVERILOG_FILE "$MODULE_SV"
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name ERROR_CHECK_FREQUENCY_DIVISOR 256
QSF

echo "[GATE3B] Running quartus_map..."
if quartus_map --read_settings_files=on --write_settings_files=off \
    "$PROJECT_DIR/$MODULE_NAME" 2>&1; then
    echo "[GATE3B] PASS — Quartus map succeeded"
    exit 0
else
    echo "[GATE3B] FAIL — Quartus map failed"
    echo "[GATE3B] Check output_files/*.map.rpt for details"
    exit 1
fi
