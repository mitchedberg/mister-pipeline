#!/usr/bin/env python3
"""
Check for forbidden async reset deassertion patterns in SystemVerilog files.

Prints FAIL: <reason> and exits 1 if found.
Prints OK: <summary> and exits 0 if clean.

Usage: python3 check_async_rst.py <module.sv>
"""
import sys
import re

filepath = sys.argv[1]

with open(filepath) as f:
    src = f.read()

# Remove single-line comments (preserve line structure)
src_nc = re.sub(r'//[^\n]*', lambda m: ' ' * len(m.group(0)), src)
# Remove block comments
src_nc = re.sub(r'/\*.*?\*/', lambda m: ' ' * len(m.group(0)), src_nc, flags=re.DOTALL)

# Find all always_ff blocks with async reset in sensitivity list
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
    Handles both begin/end and single-statement forms.
    For single-statement if-else, returns through the else branch.
    """
    rest = text[start_pos:]
    stripped = rest.lstrip()

    if stripped.startswith('begin'):
        # begin/end form: find matching end
        depth = 0
        for tok in re.finditer(r'\b(begin|end)\b', rest):
            if tok.group() == 'begin':
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    return rest[:tok.end()]
        return rest[:200]
    else:
        # Single-statement form: scan char by char
        # Track paren/brace depth; stop at ';' at depth 0
        # UNLESS followed by 'else' (if-else chain without begin)
        i = 0
        lead = len(rest) - len(stripped)
        i = lead
        paren_depth = 0
        brace_depth = 0
        while i < len(rest):
            ch = rest[i]
            if ch == '(':
                paren_depth += 1
            elif ch == ')':
                paren_depth -= 1
            elif ch == '{':
                brace_depth += 1
            elif ch == '}':
                brace_depth -= 1
            elif ch == ';' and paren_depth == 0 and brace_depth == 0:
                # Check if followed by 'else'
                after = rest[i+1:].lstrip()
                if after.startswith('else'):
                    i += 1
                    continue
                return rest[:i+1]
            i += 1
        return rest[:min(200, len(rest))]


issues = []
for m in blocks:
    sens = m.group(0)
    body = extract_block_body(src_nc, m.end())

    # Check: is this the standard synchronizer pattern?
    # Synchronizer must have *pipe* signal being assigned
    is_synchronizer = bool(re.search(r'\w*pipe\w*\s*<=', body, re.IGNORECASE))

    if not is_synchronizer:
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
