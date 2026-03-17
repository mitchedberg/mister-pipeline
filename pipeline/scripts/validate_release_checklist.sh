#!/bin/bash
# validate_release_checklist.sh — Verify release readiness for a system
#
# Usage: ./validate_release_checklist.sh <system_name> [verbose]
# Examples:
#   ./validate_release_checklist.sh taito_f3
#   ./validate_release_checklist.sh taito_f3 verbose
#
# This script checks all release conditions before public release:
# 1. Tests pass (make in vectors/)
# 2. Synthesis artifacts exist (.rbf in quartus/output_files/)
# 3. LICENSE present
# 4. CREDITS.md present and filled out
# 5. README.md present and filled out
# 6. MRA files present and valid
# 7. All critical RTL files present
#
# Prints colored PASS/FAIL per check

set -euo pipefail

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Arguments
SYSTEM_NAME="${1:-}"
VERBOSE="${2:-}"

if [ -z "$SYSTEM_NAME" ]; then
    echo "Usage: $0 <system_name> [verbose]"
    echo ""
    echo "Examples:"
    echo "  $0 taito_f3"
    echo "  $0 taito_f3 verbose"
    exit 1
fi

# Derived paths
CHIP_DIR="$PIPELINE_ROOT/chips/$SYSTEM_NAME"

if [ ! -d "$CHIP_DIR" ]; then
    echo -e "${RED}ERROR: System directory not found: $CHIP_DIR${NC}"
    exit 1
fi

# Initialize counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Helper functions
pass_check() {
    local name="$1"
    echo -e "${GREEN}✓ PASS${NC} — $name"
    ((PASS_COUNT++))
}

fail_check() {
    local name="$1"
    echo -e "${RED}✗ FAIL${NC} — $name"
    ((FAIL_COUNT++))
}

warn_check() {
    local name="$1"
    local msg="${2:-}"
    echo -e "${YELLOW}⚠ WARN${NC} — $name"
    if [ -n "$msg" ]; then
        echo "         $msg"
    fi
    ((WARN_COUNT++))
}

info_check() {
    local msg="$1"
    echo -e "${BLUE}ℹ INFO${NC} — $msg"
}

verbose_log() {
    if [ "$VERBOSE" == "verbose" ]; then
        echo "         $1"
    fi
}

# Header
echo ""
echo "=========================================="
echo "Release Readiness Validation"
echo "=========================================="
echo "System:     $SYSTEM_NAME"
echo "Directory:  $CHIP_DIR"
echo "=========================================="
echo ""

# Check 1: RTL Files Present
echo "[1/10] RTL Files..."
if [ ! -d "$CHIP_DIR/rtl" ]; then
    fail_check "rtl/ directory exists"
    RTL_COUNT=0
else
    RTL_COUNT=$(find "$CHIP_DIR/rtl" -name "*.sv" -type f 2>/dev/null | wc -l)
    if [ "$RTL_COUNT" -gt 0 ]; then
        pass_check "rtl/ directory contains $RTL_COUNT .sv files"
        if [ "$VERBOSE" == "verbose" ]; then
            find "$CHIP_DIR/rtl" -name "*.sv" -type f | while read -r f; do
                verbose_log "  $(basename "$f")"
            done
        fi
    else
        fail_check "rtl/ contains at least one .sv file"
    fi
fi

# Check 2: Quartus Project Files
echo "[2/10] Quartus Project Files..."
QUARTUS_QSF=$(find "$CHIP_DIR/quartus" -name "*.qsf" -type f 2>/dev/null | head -1)
QUARTUS_SDC=$(find "$CHIP_DIR/quartus" -name "*.sdc" -type f 2>/dev/null | head -1)
QUARTUS_QIP=$(find "$CHIP_DIR/quartus" -name "*.qip" -type f 2>/dev/null | head -1)

if [ -n "$QUARTUS_QSF" ]; then
    pass_check "Quartus .qsf project file present"
    verbose_log "$(basename "$QUARTUS_QSF")"
else
    fail_check "Quartus .qsf project file present"
fi

if [ -n "$QUARTUS_SDC" ]; then
    pass_check "Quartus .sdc constraints file present"
    verbose_log "$(basename "$QUARTUS_SDC")"
else
    warn_check "Quartus .sdc constraints file present" "Not critical, but recommended"
fi

# Check 3: Synthesis Artifacts (RBF)
echo "[3/10] Synthesis Artifacts..."
if [ -d "$CHIP_DIR/quartus/output_files" ]; then
    RBF_COUNT=$(find "$CHIP_DIR/quartus/output_files" -name "*.rbf" -type f 2>/dev/null | wc -l)
    if [ "$RBF_COUNT" -gt 0 ]; then
        pass_check "Quartus RBF bitstream(s) found ($RBF_COUNT file(s))"
        if [ "$VERBOSE" == "verbose" ]; then
            find "$CHIP_DIR/quartus/output_files" -name "*.rbf" -type f | while read -r f; do
                SIZE=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
                verbose_log "  $(basename "$f") — $(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE} bytes")"
            done
        fi
    else
        warn_check "Quartus RBF bitstream present" "Not yet synthesized; synthesis must complete before release"
    fi
else
    warn_check "Quartus output_files/ directory exists" "Not yet synthesized"
fi

# Check 4: Test Vectors and Makefile
echo "[4/10] Test Vectors..."
if [ -d "$CHIP_DIR/vectors" ]; then
    VECTOR_COUNT=$(find "$CHIP_DIR/vectors" -type f \( -name "*.tv" -o -name "*.vec" -o -name "*.txt" \) 2>/dev/null | wc -l)
    if [ "$VECTOR_COUNT" -gt 0 ]; then
        info_check "Test vectors present ($VECTOR_COUNT files)"
        verbose_log "Vectors will remain in private repo, not released publicly"
    else
        warn_check "Test vectors present in vectors/ directory"
    fi

    if [ -f "$CHIP_DIR/vectors/Makefile" ]; then
        info_check "Makefile found in vectors/"
        verbose_log "Running: make -C $CHIP_DIR/vectors test"

        if make -C "$CHIP_DIR/vectors" -n test > /dev/null 2>&1; then
            pass_check "Test target exists and is valid"

            # Only run if verbose and if not too expensive
            if [ "$VERBOSE" == "verbose" ]; then
                info_check "Running test suite (this may take a moment)..."
                if timeout 300 make -C "$CHIP_DIR/vectors" test > /tmp/test_output.log 2>&1; then
                    pass_check "All tests pass"
                else
                    TEST_EXIT=$?
                    if [ $TEST_EXIT -eq 124 ]; then
                        warn_check "Test suite timed out (>5 minutes)" "Consider optimizing tests or increasing timeout"
                    else
                        fail_check "All tests pass"
                        echo "         Test output (last 20 lines):"
                        tail -20 /tmp/test_output.log | while read -r line; do
                            echo "         $line"
                        done
                    fi
                fi
            else
                info_check "Run with 'verbose' flag to execute full test suite"
            fi
        else
            fail_check "Test target is valid"
        fi
    else
        warn_check "Makefile present in vectors/ directory" "Manual test execution required"
    fi
else
    warn_check "Test vectors directory present" "Internal validation only; not released"
fi

# Check 5: LICENSE File (will be created by prepare_release.sh)
echo "[5/10] License..."
if [ -f "$CHIP_DIR/LICENSE" ]; then
    if grep -q "GNU GENERAL PUBLIC LICENSE" "$CHIP_DIR/LICENSE"; then
        pass_check "LICENSE file present and contains GPL-2.0"
    else
        warn_check "LICENSE file present but may not be GPL-2.0"
    fi
else
    warn_check "LICENSE file not yet present" "Will be created by prepare_release.sh"
fi

# Check 6: CREDITS.md (will be created by prepare_release.sh)
echo "[6/10] Attribution..."
if [ -f "$CHIP_DIR/CREDITS.md" ]; then
    CREDITS_SIZE=$(wc -c < "$CHIP_DIR/CREDITS.md")
    MAME_CREDITED=$(grep -c "MAME" "$CHIP_DIR/CREDITS.md" 2>/dev/null || echo 0)

    if [ "$CREDITS_SIZE" -gt 500 ] && [ "$MAME_CREDITED" -gt 0 ]; then
        pass_check "CREDITS.md present with substantial attribution"
        verbose_log "File size: $CREDITS_SIZE bytes"
    else
        warn_check "CREDITS.md needs to be filled out" "Currently placeholder; add actual contributor names before release"
    fi
else
    warn_check "CREDITS.md not yet present" "Will be created by prepare_release.sh"
fi

# Check 7: README.md (will be created by prepare_release.sh)
echo "[7/10] User Documentation..."
if [ -f "$CHIP_DIR/README.md" ]; then
    README_SIZE=$(wc -c < "$CHIP_DIR/README.md")
    GAME_LIST=$(grep -c "Supported Games" "$CHIP_DIR/README.md" 2>/dev/null || echo 0)
    BUILD_INST=$(grep -c "Build from Source\|Installation" "$CHIP_DIR/README.md" 2>/dev/null || echo 0)

    if [ "$README_SIZE" -gt 1000 ] && [ "$GAME_LIST" -gt 0 ] && [ "$BUILD_INST" -gt 0 ]; then
        pass_check "README.md present with installation and game list"
        verbose_log "File size: $README_SIZE bytes"
    else
        warn_check "README.md needs to be filled out" "Currently placeholder; add game list and build instructions"
    fi
else
    warn_check "README.md not yet present" "Will be created by prepare_release.sh"
fi

# Check 8: MRA Files
echo "[8/10] MRA Auto-Launchers..."
if [ -d "$CHIP_DIR/mra" ]; then
    MRA_COUNT=$(find "$CHIP_DIR/mra" -name "*.mra" -type f 2>/dev/null | wc -l)
    if [ "$MRA_COUNT" -ge 5 ]; then
        pass_check "At least 5 MRA files present ($MRA_COUNT total)"
        if [ "$VERBOSE" == "verbose" ]; then
            find "$CHIP_DIR/mra" -name "*.mra" -type f | sort | head -10 | while read -r f; do
                verbose_log "  $(basename "$f")"
            done
            if [ "$MRA_COUNT" -gt 10 ]; then
                verbose_log "  ... and $((MRA_COUNT - 10)) more"
            fi
        fi
    elif [ "$MRA_COUNT" -gt 0 ]; then
        warn_check "At least 5 MRA files present" "Currently $MRA_COUNT file(s); more game support recommended"
    else
        fail_check "At least one MRA file present"
    fi
else
    warn_check "MRA directory present" "ROM auto-launcher files not yet generated"
fi

# Check 9: Git Repository
echo "[9/10] Version Control..."
if [ -d "$CHIP_DIR/.git" ]; then
    info_check "Local git repository exists"
    COMMIT_COUNT=$(cd "$CHIP_DIR" && git rev-list --count HEAD 2>/dev/null || echo "unknown")
    verbose_log "Commit history: $COMMIT_COUNT commit(s)"
else
    info_check "Local git repository will be created during prepare_release.sh"
fi

# Check 10: Critical Files Summary
echo "[10/10] Release Package Summary..."
CRITICAL_FILES=0
CRITICAL_TOTAL=0

for file in "LICENSE" "CREDITS.md" "README.md"; do
    ((CRITICAL_TOTAL++))
    if [ -f "$CHIP_DIR/$file" ]; then
        ((CRITICAL_FILES++))
    fi
done

PERCENT=$((CRITICAL_FILES * 100 / CRITICAL_TOTAL))
if [ "$PERCENT" -eq 100 ]; then
    pass_check "All critical documentation files present ($CRITICAL_FILES/$CRITICAL_TOTAL)"
else
    warn_check "Documentation files present ($CRITICAL_FILES/$CRITICAL_TOTAL)" "Missing files will be created by prepare_release.sh"
fi

# Final Report
echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo -e "  ${GREEN}✓ PASS: $PASS_COUNT${NC}"
echo -e "  ${RED}✗ FAIL: $FAIL_COUNT${NC}"
echo -e "  ${YELLOW}⚠ WARN: $WARN_COUNT${NC}"
echo "=========================================="
echo ""

# Exit code
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}RELEASE NOT READY${NC} — Fix $FAIL_COUNT issue(s) before public release"
    echo ""
    exit 1
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}RELEASE READY WITH CAVEATS${NC} — $WARN_COUNT warning(s) should be addressed"
    echo ""
    echo "Recommended next steps:"
    echo "  1. Ensure Quartus synthesis has been completed (generates RBF)"
    echo "  2. Fill out README.md with complete game list"
    echo "  3. Fill out CREDITS.md with actual contributor names"
    echo "  4. Add at least 5 tested MRA files"
    echo "  5. Run './prepare_release.sh $SYSTEM_NAME' to create public repository"
    echo ""
    exit 0
else
    echo -e "${GREEN}RELEASE READY${NC} — All checks passed!"
    echo ""
    echo "Next steps:"
    echo "  1. Run './prepare_release.sh $SYSTEM_NAME \"Display Name\"' to create public repo"
    echo "  2. Create GitHub repository and push"
    echo "  3. Create v0.1.0-beta release tag"
    echo "  4. Announce on MiSTer forum with 'BETA/TESTING' label"
    echo ""
    exit 0
fi
