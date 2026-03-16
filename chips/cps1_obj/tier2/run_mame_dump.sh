#!/bin/bash
# =============================================================================
# run_mame_dump.sh  —  Run MAME to dump Final Fight OBJ RAM + GFX tile data
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROM_PATH="/Volumes/2TB_20260220/Projects/ROMs_Claude/CPS1_Roms"
MAME="/opt/homebrew/bin/mame"

echo "=== Running MAME Final Fight dump ==="
echo "ROM path: $ROM_PATH"
echo "Output:   $SCRIPT_DIR/"
echo ""

# Run MAME headless:
#   -nothrottle: run as fast as possible (reaches frame 200 in ~seconds)
#   -video none: no display (macOS may need -video bgfx if this fails)
#   -sound none: no audio
#   -autoboot_delay 0: start Lua script immediately
#   -autoboot_script: our dump script
"$MAME" ffight \
    -rompath "$ROM_PATH" \
    -nothrottle \
    -video none \
    -sound none \
    -skip_gameinfo \
    -autoboot_delay 0 \
    -autoboot_script "$SCRIPT_DIR/dump_ffight.lua" \
    2>&1 | tee "$SCRIPT_DIR/mame_dump.log" || {
    echo ""
    echo "MAME exited (expected after script calls machine:exit())"
}

echo ""
echo "=== MAME dump complete ==="

# Check output
OBJ_FILE=$(ls "$SCRIPT_DIR"/frame*_obj_ram.json 2>/dev/null | tail -1)
GFX_FILE=$(ls "$SCRIPT_DIR"/frame*_gfx.json 2>/dev/null | tail -1)

if [ -z "$OBJ_FILE" ]; then
    echo "ERROR: No OBJ RAM dump found in $SCRIPT_DIR"
    echo "Check mame_dump.log for errors"
    exit 1
fi

echo "OBJ RAM dump: $OBJ_FILE"
if [ -n "$GFX_FILE" ]; then
    echo "GFX dump:     $GFX_FILE"
else
    echo "WARNING: No GFX dump found (gfx:pixel() may not be available)"
fi

echo ""
echo "=== Generating tier-2 vectors ==="
python3 "$SCRIPT_DIR/generate_tier2.py" "$OBJ_FILE" ${GFX_FILE:+"$GFX_FILE"}

echo ""
echo "=== Done! ==="
echo "Tier-2 vectors: $SCRIPT_DIR/tier2_vectors.jsonl"
echo "Tier-2 OBJ RAM: $SCRIPT_DIR/tier2_obj_ram.jsonl"
if [ -f "$SCRIPT_DIR/tier2_rom.json" ]; then
    echo "ROM lookup:     $SCRIPT_DIR/tier2_rom.json"
fi
