#!/usr/bin/env bash
# =============================================================================
# check_rtl.sh — Pre-synthesis static check for MiSTer Pipeline RTL
# =============================================================================
# Run this before every Quartus synthesis run. Catches known-bad patterns
# that cause Warning 10999, MAP OOM, Warning 12020, and ALM overflow.
# Exits 1 if any check fails.
#
# Usage:
#   bash chips/check_rtl.sh              # check all chips
#   bash chips/check_rtl.sh tc0630fdp    # check one chip
# =============================================================================

set -euo pipefail

CHIPS_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-}"
FAIL=0

# Colors
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
NC='\033[0m'

fail() { echo -e "${RED}FAIL${NC} $1"; FAIL=1; }
warn() { echo -e "${YEL}WARN${NC} $1"; }
pass() { echo -e "${GRN}PASS${NC} $1"; }

# Select which RTL files to check
if [[ -n "$TARGET" ]]; then
    RTL_FILES=$(find "$CHIPS_DIR/$TARGET" -name "*.sv" -o -name "*.v" 2>/dev/null | sort)
    if [[ -z "$RTL_FILES" ]]; then
        echo "No RTL files found for target: $TARGET"
        exit 1
    fi
else
    RTL_FILES=$(find "$CHIPS_DIR" -path "*/rtl/*.sv" -o -path "*/rtl/*.v" | sort)
fi

echo "=== MiSTer Pipeline RTL Pre-Synthesis Check ==="
echo "Checking $(echo "$RTL_FILES" | wc -l | tr -d ' ') files..."
echo ""

# =============================================================================
# CHECK 1: Byte-slice writes into arrays (causes MAP OOM / Warning 10999)
# Only flags writes NOT already inside `else (simulation) blocks after `ifdef QUARTUS
# =============================================================================
echo "--- Check 1: Byte-slice writes to inferred RAM arrays ---"
BYTE_SLICE_HITS=$(python3 - $RTL_FILES << 'PYEOF' 2>/dev/null || true
import sys, re

for path in sys.argv[1:]:
    try:
        with open(path) as f:
            lines = f.readlines()
    except:
        continue

    # Pass 1: build map of unpacked array name -> depth (entry count)
    # Only unpacked arrays > 32 entries can be inferred as M10K — smaller ones
    # synthesize as MLAB/flip-flops and byte-slice writes are fine there.
    array_depths = {}
    for line in lines:
        m = re.search(r'logic\s*\[[^\]]+\]\s*(\w+)\s*\[\s*0\s*:\s*(\d+)\s*\]', line)
        if m:
            array_depths[m.group(1)] = int(m.group(2)) + 1

    # Pass 2: scan for byte-slice writes outside simulation-only blocks
    in_sim = False
    ifdepth = 0

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('`ifdef QUARTUS') or stripped.startswith('`ifndef QUARTUS'):
            in_sim = stripped.startswith('`ifndef')
            ifdepth += 1
        elif stripped.startswith('`else') and ifdepth > 0:
            in_sim = not in_sim
        elif stripped.startswith('`endif') and ifdepth > 0:
            ifdepth -= 1
            if ifdepth == 0:
                in_sim = False

        if in_sim or stripped.startswith('//'):
            continue

        # Use bracket depth counting to find arr[idx][hi:lo] <= patterns.
        # Distinguishes arr[complex[sub][8:0]] (index-slice, OK) from
        # arr[idx][15:8] (element byte-slice, BAD for M10K-targeted arrays).
        for m in re.finditer(r'\b(\w+)\[', line):
            arr_name = m.group(1)
            start = m.end() - 1
            bdepth = 0
            j = start
            while j < len(line):
                c = line[j]
                if c == '[':
                    bdepth += 1
                elif c == ']':
                    bdepth -= 1
                    if bdepth == 0:
                        # End of outermost index bracket — check for [hi:lo] <=
                        rest = line[j+1:].lstrip()
                        inner = re.match(r'\[\s*([\w]+)\s*:\s*([\w]+)\s*\]', rest)
                        if inner:
                            after = rest[inner.end():].lstrip()
                            if after.startswith('<='):
                                # Skip full-word writes like [N:0]
                                if inner.group(2) == '0':
                                    break
                                # Skip small arrays and packed arrays (safe as flip-flops)
                                # Default 0: packed arrays and unknown decls are not in the map
                                decl_depth = array_depths.get(arr_name, 0)
                                if decl_depth > 32:
                                    print(f"{path}:{i}: {stripped}")
                        break
                j += 1
PYEOF
)
if [[ -n "$BYTE_SLICE_HITS" ]]; then
    while IFS= read -r line; do
        fail "Byte-slice write (unguarded): $line"
    done <<< "$BYTE_SLICE_HITS"
else
    pass "No unguarded byte-slice writes to arrays"
fi
echo ""

# =============================================================================
# CHECK 2: byteena_b not 1'b1 (causes Warning 12020 in DUAL_PORT altsyncram)
# In DUAL_PORT mode, read-only port B byteena_b formal width = 1 bit
# =============================================================================
echo "--- Check 2: byteena_b width in DUAL_PORT altsyncram ---"
HITS=$(echo "$RTL_FILES" | xargs grep -n '\.byteena_b\s*(' 2>/dev/null \
    | grep -v "1'b1\|1'b0" \
    | grep -v '^\s*//' \
    || true)
if [[ -n "$HITS" ]]; then
    while IFS= read -r line; do
        fail "byteena_b not 1'b1: $line"
    done <<< "$HITS"
else
    pass "All byteena_b connections use 1'b1"
fi
echo ""

# =============================================================================
# CHECK 3: 3D arrays (Quartus 17.0 cannot infer M10K from multi-dimensional arrays)
# Skips declarations inside simulation-only `else blocks
# =============================================================================
echo "--- Check 3: 3D arrays ---"
ARRAY_3D_HITS=$(python3 - $RTL_FILES << 'PYEOF' 2>/dev/null || true
import sys, re

for path in sys.argv[1:]:
    try:
        with open(path) as f:
            lines = f.readlines()
    except:
        continue

    in_sim = False
    depth = 0

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('`ifdef QUARTUS') or stripped.startswith('`ifndef QUARTUS'):
            in_sim = stripped.startswith('`ifndef')
            depth += 1
        elif stripped.startswith('`else') and depth > 0:
            in_sim = not in_sim
        elif stripped.startswith('`endif') and depth > 0:
            depth -= 1
            if depth == 0:
                in_sim = False

        if in_sim or stripped.startswith('//'):
            continue

        # Match: logic [W:0] name [D1:0][D2:0] (two unpacked dimensions)
        if re.search(r'logic\s*\[.+\]\s*\w+\s*\[.+\]\s*\[.+\]', line):
            print(f"{path}:{i}: {stripped}")
PYEOF
)
if [[ -n "$ARRAY_3D_HITS" ]]; then
    while IFS= read -r line; do
        fail "3D array (cannot infer M10K): $line"
    done <<< "$ARRAY_3D_HITS"
else
    pass "No unguarded 3D arrays"
fi
echo ""

# =============================================================================
# CHECK 4: Arrays inside reset blocks (M10K has no hardware reset)
# Pattern: array assignment inside if (!reset_n) or if (reset)
# =============================================================================
echo "--- Check 4: Array assignments inside reset clauses ---"
# Look for files where reset assignments mention array-looking LHS
HITS=$(echo "$RTL_FILES" | xargs grep -n 'if\s*(!*\s*reset\|if\s*(!*\s*rst' 2>/dev/null \
    | grep -v '^\s*//' \
    || true)
# For each hit, check if the surrounding context has array writes
RESET_ARRAY_HITS=""
while IFS= read -r line; do
    FILE=$(echo "$line" | cut -d: -f1)
    LINENO=$(echo "$line" | cut -d: -f2)
    # Check the next 10 lines for array writes
    CONTEXT=$(awk "NR>=$LINENO && NR<=$((LINENO+10))" "$FILE" 2>/dev/null || true)
    if echo "$CONTEXT" | grep -qE '\w+\[.*\]\s*<='; then
        RESET_ARRAY_HITS="$RESET_ARRAY_HITS\n  $FILE:$LINENO"
    fi
done <<< "$HITS"
if [[ -n "$RESET_ARRAY_HITS" ]]; then
    warn "Possible array writes inside reset (M10K has no hardware reset — verify these use altsyncram):"
    echo -e "$RESET_ARRAY_HITS"
else
    pass "No array writes detected inside reset clauses"
fi
echo ""

# =============================================================================
# CHECK 5: Modules missing cen (clock enable) port
# jotego pattern: every module has cen threaded through for clock-enable hierarchy
# Only flag TOP-LEVEL integration modules (not sub-modules instantiated elsewhere)
# Strategy: Pass 1 — collect all instantiated module names
#           Pass 2 — only flag modules NOT in that instantiated set
# =============================================================================
echo "--- Check 5: Modules missing cen port ---"

# Pass 1: Collect all instantiated module names from all RTL files
INSTANTIATED_MODULES=$(python3 - $RTL_FILES << 'PYEOF' 2>/dev/null || true
import sys, re

instantiated = set()
for path in sys.argv[1:]:
    try:
        with open(path) as f:
            content = f.read()
    except:
        continue

    # Match instantiation patterns: module_name u_instance (#|()
    # Examples: tc0480scp_bg u_bg(, my_module #( u_inst
    for m in re.finditer(r'^\s*(\w+)\s+u_\w+\s*[#(]', content, re.MULTILINE):
        instantiated.add(m.group(1))

# Print all instantiated module names (one per line)
for name in sorted(instantiated):
    print(name)
PYEOF
)

# Convert to space-separated set for bash lookup
INST_SET=" $(echo "$INSTANTIATED_MODULES" | tr '\n' ' ') "

MISSING_CEN=""
for f in $RTL_FILES; do
    # Only check files that look like chip-level modules (have always_ff or always @)
    if grep -q 'always_ff\|always @' "$f" 2>/dev/null; then
        # Skip known utility files, wrappers, altsyncram wrappers
        BASENAME=$(basename "$f")
        case "$BASENAME" in
            pll*.sv|*_top.sv|*_harness.sv|sdram*.sv|hps_io*.sv|sys_*.sv|altsyncram*.sv)
                continue ;;
        esac

        # Extract the module name from this file
        # Look for: module module_name(
        MODULE_NAME=$(grep -m1 '^\s*module\s\+\(\w\+\)\s*[#(]' "$f" 2>/dev/null | sed 's/.*module\s\+\(\w\+\).*/\1/' || true)

        # Only flag if module is NOT in the instantiated set (i.e., it's top-level)
        if [[ -n "$MODULE_NAME" ]]; then
            if [[ ! "$INST_SET" =~ " $MODULE_NAME " ]]; then
                if ! grep -q '\bcen\b' "$f" 2>/dev/null; then
                    MISSING_CEN="$MISSING_CEN\n  $f"
                fi
            fi
        fi
    fi
done
if [[ -n "$MISSING_CEN" ]]; then
    warn "Top-level modules without cen clock-enable port (structural divergence from jtframe pattern):"
    echo -e "$MISSING_CEN"
else
    pass "All top-level modules have cen port"
fi
echo ""

# =============================================================================
# CHECK 6: Large behavioral arrays without ifdef QUARTUS guard
# Arrays > 64 entries outside a simulation-only branch will MAP OOM in Quartus
# Skip arrays that already have (* ramstyle = ... *) pragma on the same line
# =============================================================================
echo "--- Check 6: Large behavioral arrays without QUARTUS guard ---"
LARGE_ARRAY_HITS=$(python3 - $RTL_FILES << 'PYEOF' 2>/dev/null || true
import sys, re

for path in sys.argv[1:]:
    try:
        with open(path) as f:
            lines = f.readlines()
    except:
        continue

    in_sim = False
    depth = 0

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith('`ifdef QUARTUS') or stripped.startswith('`ifndef QUARTUS'):
            in_sim = stripped.startswith('`ifndef')
            depth += 1
        elif stripped.startswith('`else') and depth > 0:
            in_sim = not in_sim
        elif stripped.startswith('`endif') and depth > 0:
            depth -= 1
            if depth == 0:
                in_sim = False

        if in_sim or stripped.startswith('//'):
            continue

        # Find unpacked array declarations: logic [W:0] name [0:N]
        m = re.search(r'logic\s*\[.+\]\s*\w+\s*\[\s*0\s*:\s*(\d+)\s*\]', line)
        if m:
            depth_val = int(m.group(1)) + 1
            if depth_val > 64:
                # Skip if the line already has ramstyle pragma
                if re.search(r'\(\*\s*ramstyle\s*=', line):
                    continue
                print(f"{path}:{i}: depth={depth_val}: {stripped}")
PYEOF
)
if [[ -n "$LARGE_ARRAY_HITS" ]]; then
    warn "Large behavioral arrays possibly missing QUARTUS guard (verify these have altsyncram):"
    while IFS= read -r line; do
        echo "  $line"
    done <<< "$LARGE_ARRAY_HITS"
else
    pass "Large arrays appear to have QUARTUS guards or use altsyncram"
fi
echo ""

# =============================================================================
# CHECK 7: Resource estimation — M10K and MLAB usage
# DE-10 Nano limits: 553 M10K blocks, 397 MLABs
# =============================================================================
echo "--- Check 7: Resource estimation ---"

M10K_ESTIMATE=0
MLAB_ESTIMATE=0

for f in $RTL_FILES; do
    # Count altsyncram instances with ram_block_type
    M10K_INSTANCES=$(grep -c 'ram_block_type.*M10K\|ram_block_type.*"M10K"' "$f" 2>/dev/null || true)
    MLAB_INSTANCES=$(grep -c 'ram_block_type.*MLAB\|ram_block_type.*"MLAB"\|ramstyle.*MLAB' "$f" 2>/dev/null || true)

    # Rough estimate: each altsyncram instance uses at least 1 M10K block
    # (actual usage depends on depth×width / 10240 bits per M10K)
    M10K_ESTIMATE=$((M10K_ESTIMATE + M10K_INSTANCES))
    MLAB_ESTIMATE=$((MLAB_ESTIMATE + MLAB_INSTANCES))
done

M10K_PCT=$((M10K_ESTIMATE * 100 / 553))
MLAB_PCT=$((MLAB_ESTIMATE * 100 / 397))

echo "  Estimated M10K instances: $M10K_ESTIMATE / 553 (~${M10K_PCT}%)"
echo "  Estimated MLAB instances: $MLAB_ESTIMATE / 397 (~${MLAB_PCT}%)"

if [[ "$M10K_ESTIMATE" -gt 480 ]]; then
    warn "M10K usage approaching limit (>87%) — check for redundant RAM instances"
fi
if [[ "$MLAB_ESTIMATE" -gt 350 ]]; then
    fail "MLAB usage critical (>88%) — convert MLABs to M10K or reduce RAM"
fi
if [[ "$M10K_ESTIMATE" -le 480 ]] && [[ "$MLAB_ESTIMATE" -le 350 ]]; then
    pass "Resource estimates within limits"
fi
echo ""

# =============================================================================
# CHECK 8: altsyncram parameter consistency
# Validates that byteena_a width matches (width_a / 8)
# =============================================================================
echo "--- Check 8: altsyncram byteena_a width consistency ---"
HITS=""
for f in $RTL_FILES; do
    # Find altsyncram instances and check byteena width
    if grep -q 'altsyncram' "$f" 2>/dev/null; then
        # Extract width_a and width_byteena_a from each instance
        # Simple check: if width_a=16 then width_byteena_a should be 2
        # if width_a=32 then width_byteena_a should be 4
        python3 - "$f" << 'PYEOF' 2>/dev/null || true
import sys, re

with open(sys.argv[1]) as fp:
    content = fp.read()

# Find all altsyncram parameter blocks
instances = re.finditer(r'altsyncram\s*#\s*\((.*?)\)', content, re.DOTALL)
for inst in instances:
    params = inst.group(1)
    w = re.search(r'\.width_a\s*\(\s*(\d+)\s*\)', params)
    b = re.search(r'\.width_byteena_a\s*\(\s*(\d+)\s*\)', params)
    if w and b:
        width_a = int(w.group(1))
        byteena = int(b.group(1))
        expected = width_a // 8
        if byteena != expected:
            # Find line number
            pos = content.find(inst.group(0))
            lineno = content[:pos].count('\n') + 1
            print(f"  {sys.argv[1]}:{lineno}: width_a={width_a} but width_byteena_a={byteena} (expected {expected})")
PYEOF
    fi
done

# Capture output from loop
BYTEENA_HITS=$(for f in $RTL_FILES; do
    if grep -q 'altsyncram' "$f" 2>/dev/null; then
        python3 - "$f" << 'PYEOF' 2>/dev/null || true
import sys, re
with open(sys.argv[1]) as fp:
    content = fp.read()
instances = re.finditer(r'altsyncram\s*#\s*\((.*?)\)', content, re.DOTALL)
for inst in instances:
    params = inst.group(1)
    w = re.search(r'\.width_a\s*\(\s*(\d+)\s*\)', params)
    b = re.search(r'\.width_byteena_a\s*\(\s*(\d+)\s*\)', params)
    if w and b:
        width_a = int(w.group(1))
        byteena = int(b.group(1))
        expected = width_a // 8
        if byteena != expected:
            pos = content.find(inst.group(0))
            lineno = content[:pos].count('\n') + 1
            print(f"  {sys.argv[1]}:{lineno}: width_a={width_a} but width_byteena_a={byteena} (expected {expected})")
PYEOF
    fi
done)

if [[ -n "$BYTEENA_HITS" ]]; then
    while IFS= read -r line; do
        fail "byteena_a width mismatch: $line"
    done <<< "$BYTEENA_HITS"
else
    pass "All altsyncram byteena_a widths consistent"
fi
echo ""

# =============================================================================
# CHECK 9: Synchronous reset (should be asynchronous for FPGA flip-flop CLR pins)
# Flags: always @(posedge clk) with if(rst) body but rst NOT in sensitivity list
# Pattern-ledger: Pattern 1 — async reset maps to dedicated CLR pin, saves LUT layer
# =============================================================================
echo "--- Check 9: Synchronous reset (should be async posedge rst) ---"
SYNC_RST_HITS=$(python3 - $RTL_FILES << 'PYEOF' 2>/dev/null || true
import sys, re

RESET_NAMES = {'rst', 'reset', 'rst_n', 'reset_n', 'arst', 'arst_n'}

for filepath in sys.argv[1:]:
    try:
        with open(filepath) as fp:
            content = fp.read()
    except Exception:
        continue

    lines = content.split('\n')
    for i, line in enumerate(lines):
        # Match always @(posedge clk) or always @(posedge clk_N)
        if not re.search(r'always\s*@\s*\(\s*posedge\s+\w+\s*\)', line):
            continue
        # Check: no 'posedge rst' / 'negedge rst_n' in sensitivity list
        sens = re.search(r'always\s*@\s*\(([^)]*)\)', line)
        if not sens:
            continue
        sens_list = sens.group(1).lower()
        has_rst_in_sens = any(name in sens_list for name in RESET_NAMES)
        if has_rst_in_sens:
            continue  # already async — good
        # Now look in next ~5 lines for if(rst) / if(!rst_n)
        block = '\n'.join(lines[i:i+6])
        rst_match = re.search(r'if\s*\(\s*(!?\s*\w+)\s*\)', block)
        if rst_match:
            cond = rst_match.group(1).strip().lstrip('!')
            if cond.lower() in RESET_NAMES:
                print(f"  {filepath}:{i+1}: synchronous reset '{cond}' — add 'posedge {cond}' to sensitivity list")
PYEOF
)

if [[ -n "$SYNC_RST_HITS" ]]; then
    while IFS= read -r line; do
        warn "sync-reset: $line"
    done <<< "$SYNC_RST_HITS"
    echo "  (sync reset works but wastes LUTs — use async: always @(posedge clk, posedge rst))"
else
    pass "All reset styles are asynchronous or not applicable"
fi
echo ""

# =============================================================================
# CHECK 10: SystemVerilog keywords that Quartus 17.0 may not handle correctly
# Flags: interface, struct, enum, unique case, priority case in synthesized RTL
# Pattern-ledger: Pattern 9 — Quartus 17.0 limited SV; use reg/wire only for RAM
# =============================================================================
echo "--- Check 10: Quartus 17.0 incompatible SystemVerilog constructs ---"
SV_HITS=""
for f in $RTL_FILES; do
    # Only .sv files can have SV-specific constructs
    [[ "$f" == *.sv ]] || continue
    # Check for known-problematic SV constructs
    matches=$(python3 - "$f" << 'PYEOF' 2>/dev/null || true
import sys, re

# Only hard-fails in Quartus 17.0 — struct packed and enum are supported in .sv
# interface declarations (as modules) and modport are not supported
BANNED = [
    (r'\binterface\b\s+\w+\s*[;(#]', 'interface module declaration (Quartus 17.0 unsupported)'),
    (r'\bmodport\b',                  'modport (requires interface, Quartus 17.0 unsupported)'),
    (r'\bunique\s+case\b',            'unique case (may warn in Q17.0 — use plain case)'),
    (r'\bpriority\s+case\b',          'priority case (use plain case)'),
    (r'\bunique\s+if\b',              'unique if'),
]

with open(sys.argv[1]) as fp:
    lines = fp.readlines()

in_sim_block = False
for i, line in enumerate(lines):
    stripped = line.strip()
    if '`ifdef SIMULATION' in stripped or ('`ifndef QUARTUS' in stripped):
        in_sim_block = True
    if in_sim_block and '`endif' in stripped:
        in_sim_block = False
        continue
    if in_sim_block:
        continue
    # Strip line comments before checking
    code = re.sub(r'//.*$', '', line)
    for pattern, label in BANNED:
        if re.search(pattern, code):
            print(f"  {sys.argv[1]}:{i+1}: {label} — may fail Quartus 17.0")
PYEOF
    )
    [[ -n "$matches" ]] && SV_HITS+="$matches"$'\n'
done

if [[ -n "$SV_HITS" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && warn "sv-compat: $line"
    done <<< "$SV_HITS"
else
    pass "No Quartus 17.0-incompatible SV constructs found"
fi
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
echo "=== Summary ==="
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GRN}All checks passed. Safe to run synthesis.${NC}"
    exit 0
else
    echo -e "${RED}Checks FAILED. Fix issues above before running Quartus.${NC}"
    exit 1
fi
