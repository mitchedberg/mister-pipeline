# chips/ — Per-Chip RTL Directory

One subdirectory per chip target. Each directory contains:

```
chips/<CHIPNAME>/
  <CHIPNAME>.sv         ← generated RTL (top-level module)
  <CHIPNAME>_tb.sv      ← optional SV testbench (for gate1)
  vectors/
    tier1_reset.jsonl   ← reset/power-on vectors (gate1)
    tier2_functional.jsonl  ← state coverage vectors (gate1)
    tier3_mame.jsonl    ← MAME-derived ground truth (gate4)
  quartus/              ← Quartus project files (gate3b, Linux only)
  notes.md              ← chip research notes, MAME source refs, quirks
```

## Adding a New Chip

1. Research the chip: find MAME source, datasheet, schematic
2. Fill in Sections 1 and 2 of `templates/generation_prompt.md`
3. Run the filled prompt through the AI (Claude Opus/Sonnet recommended)
4. Save output to `chips/<CHIPNAME>/<CHIPNAME>.sv`
5. Run gates: `gates/run_gates.sh chips/<CHIPNAME>/<CHIPNAME>.sv chips/<CHIPNAME>/vectors`
6. Fix failures by updating the prompt or templates — never hand-patch RTL
7. Add tier3 MAME vectors and run gate4

## Naming Convention

Use the chip part number as the directory name where possible:
- `mc6845/` — Motorola MC6845 CRTC
- `ay8910/` — General Instrument AY-3-8910 PSG
- `namco_wsg/` — Namco WSG (custom, use function name)
- `z80_cpm/` — test board (use descriptive name)

## Current Chips

*(none yet — first chip is added after gate infrastructure is validated)*
