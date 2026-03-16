# MiSTer Pipeline — Project Rules

## Purpose

AI-driven MiSTer FPGA arcade core generation pipeline.
Track B: gate infrastructure is validated against positive and negative test cases before any AI-generated RTL enters the loop.

## Gate Pipeline Order

```
gate1 (Verilator behavioral sim)
  → gate2.5 (Verilator lint, -Wall, hard fail on any warning)
    → gate3a (Yosys structural synthesis + check)
      → gate3b (Quartus map — Linux/CI only)
        → gate4 (functional regression vs MAME ground truth)
```

**Never skip gates.** Even if a gate seems redundant for a given change.

**Never patch generated RTL by hand.** If RTL fails a gate, fix the generation prompt or the template files, then regenerate. Hand-patched RTL hides systematic prompt problems.

## Directory Conventions

- All custom chip RTL: `chips/<CHIPNAME>/`
- Test vectors per chip: `chips/<CHIPNAME>/vectors/`
- Gate scripts: `gates/`
- Shared templates: `templates/`
- Cross-chip test modules: `test_modules/`

## RTL Style Rules (enforced by gates)

- First line of every `.sv` file: `` `default_nettype none ``
- Use `always_ff`, `always_comb`, `logic` — never `reg`, `wire`, `always @(*)`
- No latch inference: every `case` must have a `default`
- No async reset deassertion — use the section5_reset.sv synchronizer pattern
- No multi-driver signals
- No unclocked logic-gated clocks (use synchronous enable instead)
- All memory inferred via altsyncram with M10K targeting (see section4b_memory.sv)
- CDC crossings must be commented with `// CDC:` warning

## Reset Pattern (mandatory)

Use the two-flop synchronizer from `templates/section5_reset.sv`:
- Async assert (safe: clears immediately on reset)
- Synchronous deassert (safe: avoids metastability at deassert edge)

## Quartus Gates

Gates 3b, 3b-pre, and 3c require Quartus Lite on Linux or in CI.
On macOS: gate3b.sh stubs out gracefully with exit 0, no blocking.
Document Quartus failures but don't let them block macOS development loops.

## First-Pass Failure Rate

Expected first-pass failure rate at gate4: **25–35%**. This is normal.
Iterate: analyze the failure mode, update the generation prompt or template, regenerate.

## Adding a New Chip

1. `mkdir -p chips/<CHIPNAME>/vectors`
2. Generate RTL via the master prompt template (`templates/generation_prompt.md`)
3. Run `gates/run_gates.sh chips/<CHIPNAME>/<CHIPNAME>.sv chips/<CHIPNAME>/vectors`
4. Iterate until all gates pass
5. Commit passing RTL + vectors together

## MAME Ground Truth

MAME source is the authoritative behavioral reference. When gate4 discrepancies arise:
1. Check MAME source for the chip's emulation logic
2. Update test vectors to match MAME behavior
3. If RTL and MAME disagree, RTL is wrong — fix the prompt
