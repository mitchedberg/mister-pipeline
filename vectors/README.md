# Test Vector Strategy — 3-Tier Approach

This directory contains shared vector tooling. Per-chip vectors live in:
```
chips/<CHIPNAME>/vectors/
```

## Tier 1 — Reset and Power-On

**File:** `tier1_reset.jsonl`
**Purpose:** Minimum viable gate1 check. Verifies the module comes out of reset
correctly and initial state is well-defined.

**Required coverage:**
- Assert reset (rst_n = 0) for at least 4 cycles
- Deassert reset and verify output goes to known initial value
- Verify no X/Z propagation after reset release

**Example pass criterion:** After reset, count = 0, all outputs at power-on defaults.

---

## Tier 2 — Functional State Coverage

**File:** `tier2_functional.jsonl`
**Purpose:** Cover all documented behavioral states from the chip spec.

**Required coverage:**
- Every state in the state machine (IDLE, FETCH, WAIT, OUTPUT, etc.)
- All state transitions (including error/recovery paths)
- Full horizontal line cycle (hcount 0 → H_TOTAL) if video chip
- Full vertical frame cycle (vcount 0 → V_TOTAL) — can abbreviate mid-frame
- Counter wraparound behavior
- Simultaneous enable + reset behavior
- Edge: last pixel before hblank, first pixel after hblank
- Edge: last line before vblank, first line after vblank

---

## Tier 3 — MAME Ground Truth

**File:** `tier3_mame.jsonl`
**Purpose:** Cycle-accurate functional validation against MAME emulator output.

**Generation process:**
1. Run MAME with the target ROM in a headless logging mode
2. Instrument the MAME device source file to log all chip pin values per cycle
3. Convert the log to JSONL format using `tools/mame_to_jsonl.py` (TBD)
4. These vectors represent the ground truth that gate4 compares against

**Expected first-pass pass rate:** 65–75%
A 25–35% failure rate is normal for first-pass AI-generated RTL.
Failure modes to investigate:
- Timing offset (RTL output is 1–2 cycles shifted from MAME)
- State machine state count mismatch (wrong number of wait cycles)
- Missing case in a state machine (hits default instead of intended state)
- Wrong arithmetic (off-by-one in counter wrap)
- Missing a registered stage (combinational where registered was expected)

---

## Vector Format

See `templates/section6_vector_format.md` for the full JSON Lines schema.

Quick reference:
```json
{"t": 0, "inputs": {"rst_n": 0, "en": 0}, "outputs": {"count": 0}, "flags": {"reset": true}}
{"t": 5, "inputs": {"rst_n": 1, "en": 1}, "outputs": {"count": 0}}
{"t": 6, "inputs": {}, "outputs": {"count": 1}}
```

## Adding Vectors for a New Chip

```bash
mkdir -p chips/<CHIPNAME>/vectors
# Generate RTL via generation_prompt.md
# Run gate1 (will skip vectors if none found):
gates/gate1_verilator.sh chips/<CHIPNAME>/<CHIPNAME>.sv chips/<CHIPNAME>/vectors
# Add tier1 vectors, re-run gate1
# Add tier2 vectors, re-run gate1
# MAME-derive tier3 vectors
```
