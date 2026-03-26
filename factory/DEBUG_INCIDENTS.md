# Structured Debug Incidents

Purpose: make the factory self-improving by recording not just what worked, but what was tried,
why it was tried, and why it failed.

Storage:
- append-only JSONL file: `.shared/debug_incidents.jsonl`

Use cases:
- stop new agents from retrying the same dead paths
- capture assumptions that led to wasted synthesis cycles
- make later summarization / de-duplication mechanical instead of memory-based
- promote recurring lessons into `GUARDRAILS.md`, `COMMUNITY_PATTERNS.md`, and `failure_catalog.md`

## Logging rule

Log an incident whenever any of these happens:
- a hardware-only bug is isolated
- a synthesis failure is explained
- a hypothesis is tested and rejected
- a fix is validated or invalidated

Do not wait for the end of the session.

## Query first

Before debugging a core:

```bash
python3 factory/query_debug_incidents.py --core taito_b --limit 10
python3 factory/query_debug_incidents.py --tag hardware --tag gfx
```

## Log an incident

Minimal example:

```bash
python3 factory/log_debug_incident.py \
  --core taito_b \
  --chip tc0180vcu \
  --stage hardware \
  --status partial \
  --summary "Shared gfx return path can misdeliver bytes on MiSTer" \
  --assumption "Live *_gfx_rd-based ack routing was safe because only one external request is outstanding" \
  --attempt "Qualified gfx_ok by current requester" \
  --attempt "Latched arbiter owner until gfx_ok return" \
  --evidence "Remote screenshots changed from partial-object stripes to stable full-field speckle" \
  --evidence "Steady-state sim remained ~99.9% after owner-latch fix" \
  --next-step "Run Quartus and retest on MiSTer"
```

## Field meaning

- `status`
  - `open`: hypothesis or bug still unproven
  - `partial`: useful lead or incomplete fix
  - `resolved`: root cause fixed
  - `dead_end`: attempted path did not solve the issue

- `assumptions`
  - what the agent believed when it chose the path

- `attempts`
  - the concrete fixes or probes that were tried

- `evidence`
  - screenshots, logs, sim percentages, Quartus metrics, run IDs, commits

- `next_step`
  - the best immediate continuation from this incident

## Promotion rule

When the same incident pattern appears twice:
1. add or update a `failure_catalog.md` entry
2. decide if `check_rtl.sh` should warn on it
3. decide if `GUARDRAILS.md` or `COMMUNITY_PATTERNS.md` should teach it

That is how the factory improves itself instead of accumulating folklore.
