"""
Analyze Gate 4 failure patterns by running the Python model and the simulation
binary side by side.
"""
import json
import subprocess
import os
import sys
from collections import defaultdict

# Run simulation and capture stdout
SIM = os.path.join(os.path.dirname(__file__), 'obj_dir/Vcps1_obj')
VECFILE = os.path.join(os.path.dirname(__file__), 'tier1_vectors.jsonl')
RAMFILE = os.path.join(os.path.dirname(__file__), 'tier1_obj_ram.jsonl')

if not os.path.exists(SIM):
    print("Simulation binary not found. Run 'make build' first.")
    sys.exit(1)

# We need to capture all failures, not just first 20.
# Modify approach: load vectors and OBJ RAMs, then run DUT test-by-test.
# Since we can't easily instrument the C++ binary further without recompile,
# we instead analyze the patterns from the first-20 failures and known test structure.

# Load vectors
test_cases = {}  # test_name → {"scanlines": {sl: {x: exp}}}
with open(VECFILE) as f:
    for line in f:
        r = json.loads(line)
        tn = r['test_name']
        sl = r['scanline']
        if tn not in test_cases:
            test_cases[tn] = {}
        if sl not in test_cases[tn]:
            test_cases[tn][sl] = {}
        for x_str, val in r['pixels'].items():
            test_cases[tn][sl][int(x_str)] = val

# Summary per test
print("Per-test pixel vector counts:")
for tn, sls in test_cases.items():
    total = sum(len(v) for v in sls.values())
    print(f"  {tn}: {total} pixels across {len(sls)} scanlines")

# Categories of tests
flip_tests = [t for t in test_cases if 'flip' in t]
block_tests = [t for t in test_cases if 'block' in t]
sweep_tests = [t for t in test_cases if 'sweep' in t]
priority_tests = [t for t in test_cases if 'priority' in t]
other_tests = [t for t in test_cases if t not in flip_tests + block_tests + sweep_tests + priority_tests]

print("\nTest categories:")
print(f"  Flip tests: {flip_tests}")
print(f"  Block tests: {block_tests}")
print(f"  Sweep tests: {sweep_tests}")
print(f"  Priority tests: {priority_tests}")
print(f"  Other: {other_tests}")
