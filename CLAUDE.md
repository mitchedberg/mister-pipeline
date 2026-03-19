# MiSTer Pipeline — Project Rules

## Purpose

AI-driven MiSTer FPGA arcade core generation pipeline.

## Key Files — Read Before Working
- `chips/GUARDRAILS.md` — 14 synthesis + simulation rules, every one learned the hard way
- `chips/fx68k_integration_reference.md` — consensus fx68k patterns from 10+ community cores
- `chips/PROJECT_STATUS.md` — living status of every core (updated continuously)
- `chips/TASK_BOARD.md` — multi-agent task claiming (check before starting work)
- `chips/nmk_arcade/sim/` — reference sim harness (copy this pattern for new cores)

## Gate Pipeline Order

```
gate1 (Verilator behavioral sim)
  → gate2.5 (Verilator lint, -Wall, hard fail on any warning)
    → gate3a (Yosys structural synthesis + check)
      → gate3b (Quartus map — Linux/CI only)
        → gate4 (functional regression vs MAME ground truth)
```

**Never skip gates.** Even if a gate seems redundant for a given change.

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

## Simulation Harness Rules

Every Verilator sim harness MUST follow `chips/nmk_arcade/sim/`:

### fx68k CPU — Non-Negotiable
1. **enPhi1/enPhi2 from C++, NEVER from RTL** — Verilator scheduling race → CPU double-fault (GUARDRAILS Rule 13)
2. **Use JTFPGA/fx68k fork** at `chips/m68000/hdl/fx68k/` (GUARDRAILS Rule 14)
3. **VPAn = IACK detection** (`~&{FC2,FC1,FC0,~ASn}`), NEVER tied to 1'b1

### Harness structure
- **tb_top.sv**: fx68k direct instantiation, enPhi1/enPhi2 as top-level inputs, bypass ports, SDRAM/video/audio as top-level ports
- **tb_system.cpp**: Single eval per clock toggle. Phi BEFORE eval on rising edge, cleared on falling edge. `Verilated::fatalOnError(false)`. Toggle-handshake for CPU ROM, combinational read for GFX ROM.
- **Makefile**: `--trace -Wno-fatal`. JTFPGA fx68k sources.

## Multi-Agent Coordination

Use **git worktrees** (`claude --worktree <name>`) for file isolation between sessions.

### Before starting work
1. Read `.shared/task_queue.md` — this is OUTSIDE git, shared instantly across all worktrees
2. Find a task with status AVAILABLE, change it to CLAIMED:<your-worktree>
3. Do the work following the checklist in task_queue.md
4. When done, change status to DONE, pick next AVAILABLE task
5. Never edit files in a directory another agent has claimed

### Shared (read-only)
`chips/m68000/`, `chips/GUARDRAILS.md`, `chips/fx68k_integration_reference.md`, `chips/nmk_arcade/sim/`

### Compute resources
| Machine | SSH | Verilator | Notes |
|---------|-----|-----------|-------|
| Mac Mini 3 | local | /opt/homebrew/bin/ | 10-core M4 |
| iMac-Garage | `ssh imac` | ~/tools/verilator/bin/ | 8-core M4 |
| GPU PC | `ssh gpu` | No (Windows) | RTX 4070 Super, MAME |

### ROMs
`/Volumes/2TB_20260220/Projects/ROMs_Claude/Roms/` — tdragon, batsugun, gunbird, crimec, nastar, pbobble, gigandes, superman, twinhawk, daisenpu

## MAME Ground Truth

MAME source is the authoritative behavioral reference. When gate4 discrepancies arise:
1. Check MAME source for the chip's emulation logic
2. Update test vectors to match MAME behavior
3. If RTL and MAME disagree, RTL is wrong — fix the prompt
