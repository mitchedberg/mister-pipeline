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

---

## Simulation Harness Rules (2026-03-19)

Every Verilator sim harness MUST follow the NMK reference at `chips/nmk_arcade/sim/`.

### fx68k CPU — Non-Negotiable (learned from multi-day debug)
1. **enPhi1/enPhi2 from C++, NEVER from RTL** — Verilator scheduling race causes CPU double-fault. See GUARDRAILS Rule 13.
2. **Use JTFPGA/fx68k fork** at `chips/m68000/hdl/fx68k/` — stock ijor/fx68k has Verilator incompatibilities. See GUARDRAILS Rule 14.
3. **VPAn = autovector IACK detection** (`~&{FC2,FC1,FC0,~ASn}`), NEVER tied to 1'b1. CPU hangs on interrupt acknowledge without this.

### Harness structure
- **tb_top.sv**: fx68k directly instantiated, enPhi1/enPhi2 as top-level inputs, bypass_en/bypass_data/bypass_dtack_n for C++ bus driving, all SDRAM/video/audio as top-level ports.
- **tb_system.cpp**: Single eval per clock toggle (not two evals per cycle). Phi set BEFORE eval on rising edge, cleared on falling edge. `Verilated::fatalOnError(false)`. SDRAM toggle-handshake for CPU ROM, direct combinational read for GFX ROM.
- **Makefile**: `--trace -Wno-fatal`. Source the JTFPGA fx68k files.

### Read before building
- `chips/GUARDRAILS.md` — 14 rules, all learned the hard way
- `chips/fx68k_integration_reference.md` — consensus patterns from 10+ community cores

---

## Multi-Agent Coordination

Multiple Claude Code sessions may work on this repo simultaneously.

### Setup
Use **git worktrees** for file isolation:
```bash
claude --worktree sim-kaneko    # Session gets its own branch + files
claude --worktree sim-taito-b   # Another session, no conflicts
```

### Task board
Check `chips/TASK_BOARD.md` before starting work:
- See what's claimed by other agents
- Update YOUR section when claiming/completing tasks
- Never edit files in a directory another agent has claimed

### Shared resources (read-only)
- `chips/m68000/` — fx68k CPU files
- `chips/GUARDRAILS.md` — integration rules
- `chips/fx68k_integration_reference.md` — reference doc
- `chips/nmk_arcade/sim/` — reference sim harness (copy, don't modify)

### Compute resources
| Machine | SSH | Verilator | Notes |
|---------|-----|-----------|-------|
| Mac Mini 3 | local | /opt/homebrew/bin/ | 10-core M4, orchestrator |
| iMac-Garage | `ssh imac` | ~/tools/verilator/bin/ | 8-core M4, sim worker |
| GPU PC | `ssh gpu` | No (Windows) | RTX 4070 Super, MAME |

### ROMs
All at `/Volumes/2TB_20260220/Projects/ROMs_Claude/Roms/`. Available: tdragon, batsugun, gunbird, crimec, nastar, pbobble, gigandes, superman, twinhawk, daisenpu.

---

## Project Status (2026-03-19)

| Core | Synthesis | Sim | Notes |
|------|-----------|-----|-------|
| NMK16 | GREEN | Game screens rendering | BG tiles + palette; sprites need NMK004 MCU |
| Toaplan V2 | GREEN | Harness being built | GP9001, GFX 32-bit fixed |
| Psikyo | GREEN | Harness being built | |
| Kaneko | GREEN | Available | GFX 32-bit fixed |
| Taito B | GREEN | Available | CPU ROM just wired |
| Taito X | GREEN | Available | CPU ROM + Z80 WAIT_n just fixed |
| Taito F3 | FROZEN | — | Won't fit DE-10 Nano (461% ALM) |
| Taito Z | FROZEN | — | Won't fit (2x fx68k) |
