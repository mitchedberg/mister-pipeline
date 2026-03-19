# Simulation Harness Build — Task Board

Two Claude Code agents are working in parallel. Check this file before starting work.
Update your task status as you go. Never touch directories owned by the other agent.

## Agent 1 (Opus, master branch)
| Core | Status | Directory | Machine |
|------|--------|-----------|---------|
| NMK16 / Thunder Dragon | DONE | chips/nmk_arcade/ | Mac Mini 3 |
| Toaplan V2 / Batsugun | IN PROGRESS | chips/toaplan_v2/ | Mac Mini 3 |
| Psikyo / Gunbird | IN PROGRESS | chips/psikyo_arcade/ + chips/psikyo/ | iMac |

## Agent 2 (branch: sim-batch2)
| Core | Status | Directory | Machine |
|------|--------|-----------|---------|
| Kaneko / Blood Warrior | AVAILABLE | chips/kaneko_arcade/ + chips/kaneko/ | — |
| Taito B / Nastar | AVAILABLE | chips/taito_b/ | — |
| Taito X / Gigandes | AVAILABLE | chips/taito_x/ | — |

## Shared (DO NOT EDIT without checking with other agent)
- chips/m68000/ — fx68k CPU files (read-only, both agents use)
- chips/GUARDRAILS.md — integration rules (Agent 1 owns edits)
- chips/fx68k_integration_reference.md — reference doc (read-only)
- chips/TASK_BOARD.md — this file (both agents read/write their own section)

## Rules
1. Read GUARDRAILS.md Rules 13-14 before building any sim harness
2. Use JTFPGA fx68k at chips/m68000/hdl/fx68k/
3. enPhi1/enPhi2 MUST be C++-driven inputs, not RTL-generated
4. Copy NMK sim pattern: chips/nmk_arcade/sim/ is the reference
5. ROMs at /Volumes/2TB_20260220/Projects/ROMs_Claude/Roms/
6. iMac worker: ssh imac (Verilator at ~/tools/verilator/bin/)
7. Commit to YOUR branch only — never force-push master

## Available ROMs
- batsugun.zip (Toaplan V2) — Agent 1
- gunbird.zip (Psikyo) — Agent 1
- crimec.zip, nastar.zip, pbobble.zip (Taito B)
- gigandes.zip, superman.zip, twinhawk.zip (Taito X)
- No bloodwar.zip (Kaneko) — check Roms/ for alternatives
