# MiSTer Pipeline Orchestrator

Automates the workflow from "target identified" to "synthesis-ready core."

The orchestrator reads `targets.json`, checks real filesystem state per system,
and dispatches Claude API agents to advance each target through the pipeline.
The quality gate is strict: nothing advances past `rtl_started` without passing
MAME behavioral tests.

---

## Quick Start

```bash
cd pipeline/orchestrator

# Show current pipeline state
node orchestrator.js --status

# Advance a single target (dry run first)
node orchestrator.js --target gp9001 --dry-run
node orchestrator.js --target gp9001

# Advance all targets by priority order (skips terminals, pauses at human gates)
node orchestrator.js --all --dry-run
node orchestrator.js --all

# Publish a validated core (requires explicit flag)
node orchestrator.js --publish gp9001
```

Requires `@anthropic-ai/sdk` and `ANTHROPIC_API_KEY` in environment:

```bash
npm install @anthropic-ai/sdk
export ANTHROPIC_API_KEY=sk-ant-...
```

---

## State Machine

```
unresearched
      │  agent: haiku / task: research
      ▼
  researched
      │  agent: sonnet / task: write_rtl
      ▼
 rtl_started  ──── tests FAIL ──→ agent: sonnet / task: fix_tests ──┐
      │                                                               │
      │  tests PASS (make test exits 0)                              │
      ▼                                                              │
tests_passing ◄──────────────────────────────────────────────────────┘
      │  agent: haiku / task: integrate
      ▼
  integrated
      │  agent: haiku / task: synthesis_infra
      ▼
 synthesized
      │  *** HUMAN GATE: flash to DE-10 Nano, verify game boots ***
      │  touch <integration_dir>/HARDWARE_VALIDATED
      ▼
  validated
      │  agent: haiku / task: prepare_release
      │  requires explicit --publish flag
      ▼
  published
```

The `synthesized → validated` transition is intentionally manual. No agent can
verify that a game boots on real silicon. The orchestrator will pause and print
instructions when it hits this gate.

The `validated → published` transition requires `--publish <id>`. It will never
happen automatically, even with `--all`.

---

## Commands

### `--status`

Prints a one-line state bar for every target. Also shows if the JSON state
is behind the filesystem (stale).

```
taito_b     synthesized     [████████░]
taito_f3    synthesized     [████████░]
taito_z     synthesized     [████████░]
taito_x     synthesized     [████████░]
gp9001      researched      [██░░░░░░░]
nmk16       researched      [██░░░░░░░]
psikyo      researched      [██░░░░░░░]
kaneko16    researched      [██░░░░░░░]
deco32      researched      [██░░░░░░░]
```

### `--target <id>`

Advance a single target by one step. Shows what agent will be called, then
calls it (unless `--dry-run`).

### `--all`

Advance all non-terminal targets in priority order. Skips targets that need
human intervention. Continues on single-target errors.

### `--dry-run`

Can be combined with any command. Shows what would happen without:
- Making any API calls
- Writing any files
- Changing any state

### `--publish <id>`

Advance a `validated` target to `published` by running the `prepare_release`
agent. This is the only way to reach `published` state.

---

## State Detection

The orchestrator infers state from the filesystem, not just the JSON record.
This means it self-heals after manual work:

| Evidence | Inferred state |
|----------|---------------|
| `<integration_dir>/RELEASE` exists | published |
| `<integration_dir>/HARDWARE_VALIDATED` exists | validated |
| `<quartus_dir>/output_files/*.rbf` exists | synthesized |
| `<quartus_dir>/emu.sv` exists | integrated |
| RTL `.sv` files + test `.jsonl` files exist | rtl_started |
| Research `.md` files exist | researched |
| Nothing | unresearched |

If filesystem state is ahead of JSON state, the JSON is updated automatically.

---

## Agent Dispatch

Each state transition calls a Claude model via the Anthropic SDK:

| Task | Model | Prompt template | Est. cost |
|------|-------|-----------------|-----------|
| research | claude-haiku-4-5 | `prompts/research.md` | ~$0.04 |
| write_rtl | claude-sonnet-4-5 | `prompts/write_rtl.md` | ~$0.90 |
| fix_tests | claude-sonnet-4-5 | `prompts/fix_tests.md` | ~$0.80 |
| integrate | claude-haiku-4-5 | `prompts/integrate.md` | ~$0.02 |
| synthesis_infra | claude-haiku-4-5 | `prompts/synthesis_infra.md` | ~$0.02 |
| prepare_release | claude-haiku-4-5 | `prompts/prepare_release.md` | ~$0.01 |

Cost estimates are rough averages. `write_rtl` and `fix_tests` can exceed $1
for complex chips with many submodules.

Agent responses are saved to `<research_dir>/orchestrator_outputs/<task>_<timestamp>.md`.

---

## Logging

All operations are logged to `pipeline/orchestrator/orchestrator.log`.
The log is append-only — safe to tail during a run:

```bash
tail -f pipeline/orchestrator/orchestrator.log
```

---

## Adding a New Target

1. Add an entry to `targets.json` with `state: "unresearched"` (or the correct current state)
2. Assign the next priority number
3. Run `node orchestrator.js --target <new_id>`

The orchestrator will dispatch the research agent and create `chips/<id>/section3_rtl_plan.md`
and related documents.

---

## Test Infrastructure

Tests are run via `make test` in `chips/<chip>/vectors/Makefile`. The Makefile
must support these targets (see `chips/taito_x/vectors/Makefile` as reference):

```makefile
all: vectors build run
test: all
vectors: # regenerate JSONL test vectors from Python model
build:   # compile RTL with Verilator
run:     # run simulation, compare against vectors
clean:   # remove obj_dir and JSONL files
```

The orchestrator checks `make test` exit code. Exit 0 = tests pass.
Any non-zero exit = tests fail, `fix_tests` agent is dispatched.

---

## Gate Pipeline (from CLAUDE.md)

The orchestrator's `tests_passing` gate maps to the project's full gate pipeline:

```
gate1  (Verilator behavioral sim)
  → gate2.5 (Verilator lint, -Wall, hard fail on warnings)
    → gate3a (Yosys structural synthesis)
      → gate3b (Quartus map, Linux/CI only)
        → gate4 (functional regression vs MAME ground truth)
```

The `make test` in each chip's vectors directory must run all applicable gates.

---

## Hardware Validation Sign-off

When a target reaches `synthesized`:

1. Download the `.rbf` from the GitHub Actions artifact
2. Copy to `/media/fat/Games/<SystemName>/` on the DE-10 Nano SD card
3. Launch via the MiSTer menu
4. Verify at least one representative game boots to gameplay
5. Run `touch chips/<chip>/HARDWARE_VALIDATED` in the repo root
6. Commit the file: `git add chips/<chip>/HARDWARE_VALIDATED && git commit -m "Validate <chip> on hardware"`
7. Re-run `node orchestrator.js --target <chip>` — it will detect the file and advance state

---

## Release Checklist

See `release_checklist.md` for the complete pre-publish requirements.
The `prepare_release` agent runs this checklist and blocks on any FAIL items.
