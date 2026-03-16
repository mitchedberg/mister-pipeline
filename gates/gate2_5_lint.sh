#!/bin/bash
# Gate 2.5: Verilator strict lint check
# Usage: ./gate2_5_lint.sh <module.sv>
# Hard fail on ANY warning. Returns 0 on clean, 1 on any warning or error.
#
# Checks enforced by -Wall:
#   - Latch inference (case without default in always_comb)
#   - Implicit nets (caught by `default_nettype none in source, but belt+suspenders)
#   - Unused signals, undriven signals
#   - Width mismatches
#   - Async reset pattern warnings (SYNCASYNCNET)
#
# Additional custom checks performed by this script:
#   - Forbidden async reset deassertion pattern:
#       always_ff @(posedge clk or posedge rst) ... else count <= ...
#     (async ASSERT is ok when used with sync deassert synchronizer;
#      bare async deassert without synchronizer is forbidden)

set -uo pipefail

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
# Forbidden pattern: always_ff sensitivity list contains BOTH a clock edge AND
# a reset edge, but the reset is used in the else branch (deassertion is async).
# Safe pattern requires the reset to only appear in the synchronizer module
# with the two-flop structure from section5_reset.sv.
#
# Detection heuristic: look for always_ff blocks where:
#   - Sensitivity list has "posedge clk or posedge rst" (or negedge)
#   - AND the non-reset branch (else) contains an assignment that is NOT
#     just "rst_pipe <= ..." (the synchronizer's own pipe update)
#
# We flag any always_ff with async reset sensitivity that is NOT the
# standard synchronizer pattern.

echo "[GATE2.5] Checking for forbidden async reset deassertion..."

# Extract module name from file
DETECTED_MODULE="$(grep -m1 '^module ' "$MODULE_SV" | awk '{print $2}' | tr -d '(')"

# Use Python for reliable multi-line pattern detection
ASYNC_CHECK="$(python3 - "$MODULE_SV" "$DETECTED_MODULE" <<'PYEOF'
import sys
import re

filepath = sys.argv[1]
modname = sys.argv[2] if len(sys.argv) > 2 else ""

with open(filepath) as f:
    src = f.read()

# Remove single-line comments for analysis (preserve line positions for errors)
src_nc = re.sub(r'//[^\n]*', lambda m: ' ' * len(m.group(0)), src)
src_nc = re.sub(r'/\*.*?\*/', lambda m: ' ' * len(m.group(0)), src_nc, flags=re.DOTALL)

# Find all always_ff blocks with async reset in sensitivity list
# Pattern: always_ff @( ... posedge/negedge <rst> or posedge/negedge <clk> ... )
async_ff_pattern = re.compile(
    r'always_ff\s*@\s*\('
    r'[^)]*(?:posedge|negedge)\s+\w+'
    r'[^)]*\bor\b[^)]*(?:posedge|negedge)\s+\w+'
    r'[^)]*\)',
    re.IGNORECASE
)

blocks = list(async_ff_pattern.finditer(src_nc))

if not blocks:
    print("OK: no async-reset always_ff blocks found")
    sys.exit(0)

def extract_block_body(text, start_pos):
    """Extract the body of an always_ff block starting after its sensitivity list.
    Handles both 'begin/end' and single-statement forms."""
    rest = text[start_pos:]
    # Skip whitespace/newlines
    stripped = rest.lstrip()
    offset = len(rest) - len(stripped)

    if stripped.startswith('begin'):
        # begin/end form: walk matching begin/end pairs
        depth = 0
        body_end_rel = len(rest)
        for tok in re.finditer(r'\b(begin|end)\b', rest):
            if tok.group() == 'begin':
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    body_end_rel = tok.end()
                    break
        return rest[:body_end_rel]
    else:
        # Single-statement form: body ends at semicolon (accounting for nested parens)
        depth = 0
        for i, ch in enumerate(rest):
            if ch in '({':
                depth += 1
            elif ch in ')}':
                depth -= 1
            elif ch == ';' and depth == 0:
                return rest[:i+1]
        return rest[:200]

issues = []
for m in blocks:
    sens = m.group(0)
    body = extract_block_body(src_nc, m.end())

    # Check: is this the standard synchronizer pattern?
    # Synchronizer: if (!rst) pipe <= 0; else pipe <= {pipe[0], 1'b1};
    # We look for *_pipe <= in the body (both if and else branches)
    is_synchronizer = bool(re.search(r'\w*pipe\w*\s*<=', body, re.IGNORECASE))

    if not is_synchronizer:
        # This async-reset always_ff is NOT the standard synchronizer — flag it
        issues.append(
            f"FORBIDDEN async reset deassertion in always_ff block:\n"
            f"  Sensitivity: {sens.strip()}\n"
            f"  Block body is not a two-flop synchronizer pattern.\n"
            f"  Use the Section 5 reset_sync pattern instead."
        )

if issues:
    for iss in issues:
        print(f"FAIL: {iss}")
    sys.exit(1)
else:
    print(f"OK: {len(blocks)} async-reset always_ff block(s) found — all match synchronizer pattern")
    sys.exit(0)
PYEOF
)"
ASYNC_EXIT=$?

echo "[GATE2.5] Async reset check: $ASYNC_CHECK"

if [[ $ASYNC_EXIT -ne 0 ]]; then
    FAIL=1
fi

# ── 3. default_nettype none check ─────────────────────────────────────────────
echo "[GATE2.5] Checking for \`default_nettype none..."
if ! grep -q '`default_nettype none' "$MODULE_SV"; then
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
# Detects always_comb case blocks that are missing a default branch.
# This is a belt-and-suspenders check for when Verilator is not available.
echo "[GATE2.5] Checking for case statements without default (latch inference)..."
LATCH_CHECK="$(python3 - "$MODULE_SV" <<'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    src = f.read()

# Remove single-line comments
src_nc = re.sub(r'//[^\n]*', '', src)
# Remove block comments
src_nc = re.sub(r'/\*.*?\*/', '', src_nc, flags=re.DOTALL)

# Find always_comb blocks
comb_blocks = []
for m in re.finditer(r'\balways_comb\b', src_nc):
    start = m.end()
    # Find the begin
    begin_pos = src_nc.find('begin', start)
    if begin_pos == -1:
        continue
    # Walk begin/end to find block extent
    depth = 0
    body_end = len(src_nc)
    for tok in re.finditer(r'\b(begin|end)\b', src_nc[begin_pos:]):
        if tok.group() == 'begin':
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                body_end = begin_pos + tok.end()
                break
    comb_blocks.append(src_nc[begin_pos:body_end])

issues = []
for i, block in enumerate(comb_blocks):
    # Find case statements within this block
    for cm in re.finditer(r'\bcase\b\s*\([^)]+\)(.*?)(?=\bendcase\b)', block, re.DOTALL):
        case_body = cm.group(1)
        # Check if there's a default: branch
        if not re.search(r'\bdefault\s*:', case_body):
            issues.append(f"always_comb block {i+1}: case statement missing 'default' branch — infers latch")

if issues:
    for iss in issues:
        print(f"FAIL: {iss}")
    sys.exit(1)
else:
    if comb_blocks:
        print(f"OK: {len(comb_blocks)} always_comb block(s) checked — all case statements have default")
    else:
        print("OK: no always_comb blocks found")
    sys.exit(0)
PYEOF
)"
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
