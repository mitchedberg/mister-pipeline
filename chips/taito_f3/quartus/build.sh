#!/bin/bash
#
# Taito F3 MiSTer Core — Local Quartus Synthesis Build Script
#
# Usage:
#   ./build.sh                    # Uses default Quartus path
#   ./build.sh ~/intelFPGA_lite   # Uses custom Quartus installation path
#   ./build.sh --clean            # Clean output_files/ before building
#   ./build.sh --help             # Show usage
#
# Prerequisites:
#   - Quartus Prime Lite 17.0.2 installed (standard for MiSTer Cyclone V)
#   - This script runs from chips/taito_f3/quartus/ directory
#

set -e

# Default Quartus installation path (Intel/Altera standard on Linux)
QUARTUS_HOME="${1:-$HOME/intelFPGA_lite}"

# Handle special options
case "$1" in
  --help)
    head -n 20 "$0" | grep -E "^#|^$"
    echo ""
    echo "Environment: QUARTUS_HOME=$QUARTUS_HOME"
    exit 0
    ;;
  --clean)
    echo "Cleaning output_files/ directory..."
    rm -rf output_files/
    exit 0
    ;;
esac

# Find Quartus version (17.0 or 17.0.2)
if [ -d "$QUARTUS_HOME/quartus/bin" ]; then
  QUARTUS_BIN="$QUARTUS_HOME/quartus/bin"
elif [ -d "$QUARTUS_HOME/17.0std/quartus/bin" ]; then
  QUARTUS_BIN="$QUARTUS_HOME/17.0std/quartus/bin"
elif [ -d "$QUARTUS_HOME/17.0.2/quartus/bin" ]; then
  QUARTUS_BIN="$QUARTUS_HOME/17.0.2/quartus/bin"
else
  echo "ERROR: Quartus not found at $QUARTUS_HOME"
  echo "Install Quartus 17.0.2 Lite from:"
  echo "  https://www.intel.com/content/www/us/en/software/programmable/quartus/prime/download.html"
  exit 1
fi

# Add Quartus to PATH
export PATH="$QUARTUS_BIN:$PATH"

# Verify quartus_sh is available
if ! command -v quartus_sh &> /dev/null; then
  echo "ERROR: quartus_sh not found in PATH"
  echo "Tried: $QUARTUS_BIN"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Taito F3 MiSTer Core — Quartus Synthesis"
echo "=========================================="
echo "Quartus:     $(quartus_sh --version 2>&1 | head -1)"
echo "Directory:   $(pwd)"
echo "Top entity: sys_top"
echo "Device:     Cyclone V (5CSEBA6U23I7)"
echo ""

# Clean previous synthesis if requested via env var
if [ "$CLEAN_BUILD" = "1" ]; then
  echo "Cleaning old build artifacts..."
  rm -rf output_files/
fi

# Run Quartus full compile flow
echo "Starting synthesis flow..."
echo ""

if quartus_sh --flow compile taito_f3; then
  echo ""
  echo "=========================================="
  echo "✓ Synthesis SUCCESSFUL"
  echo "=========================================="

  # Check if RBF was generated
  if [ -f output_files/taito_f3.rbf ]; then
    RBF_SIZE=$(stat -f%z output_files/taito_f3.rbf 2>/dev/null || stat -c%s output_files/taito_f3.rbf 2>/dev/null)
    echo "RBF Output:  output_files/taito_f3.rbf ($(numfmt --to=iec-i --suffix=B $RBF_SIZE 2>/dev/null || echo $RBF_SIZE bytes))"
  else
    echo "WARNING: RBF file not generated"
  fi

  # Show utilization summary
  if [ -f output_files/taito_f3.fit.rpt ]; then
    echo ""
    echo "Device Utilization:"
    grep -E "Total logic elements|Total memory bits|Total pins used" \
      output_files/taito_f3.fit.rpt | sed 's/^/  /' || true
  fi

  exit 0
else
  echo ""
  echo "=========================================="
  echo "✗ Synthesis FAILED"
  echo "=========================================="
  echo "Check logs in output_files/ for details"
  exit 1
fi
