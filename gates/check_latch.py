#!/usr/bin/env python3
"""
Check for latch inference: always_comb case statements without a default branch.

Prints FAIL: <reason> and exits 1 if found.
Prints OK: <summary> and exits 0 if clean.

Usage: python3 check_latch.py <module.sv>
"""
import sys
import re

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
    rest = src_nc[start:]
    begin_pos = rest.find('begin')
    if begin_pos == -1:
        continue
    abs_begin = start + begin_pos
    # Walk begin/end to find block extent
    depth = 0
    body_end = len(src_nc)
    for tok in re.finditer(r'\b(begin|end)\b', src_nc[abs_begin:]):
        if tok.group() == 'begin':
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                body_end = abs_begin + tok.end()
                break
    comb_blocks.append(src_nc[abs_begin:body_end])

issues = []
for i, block in enumerate(comb_blocks):
    # Find case statements within this block
    for cm in re.finditer(r'\bcase\b\s*\([^)]+\)(.*?)(?=\bendcase\b)', block, re.DOTALL):
        case_body = cm.group(1)
        if not re.search(r'\bdefault\s*:', case_body):
            issues.append(
                f"always_comb block {i+1}: case statement missing 'default' branch — infers latch"
            )

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
