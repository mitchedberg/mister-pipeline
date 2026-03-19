# Task Board — Multi-Agent Coordination

## How This Works
1. **Before starting**: pull master, read this file, claim tasks in your section
2. **Commit your claims to master** before creating your worktree
3. Work in your worktree, commit there
4. When done: update PROJECT_STATUS.md, merge worktree branch to master
5. Check this file again for next available tasks

## Active Agents

### Agent 1 (master branch, Mac Mini 3)
| Task | Status | Directory |
|------|--------|-----------|
| NMK16 sim harness | DONE | chips/nmk_arcade/ |
| Toaplan V2 sim harness | IN PROGRESS | chips/toaplan_v2/ |
| Psikyo sim harness | IN PROGRESS | chips/psikyo_arcade/ + chips/psikyo/ |

### Agent 2 (worktree: sim-batch2)
| Task | Status | Directory |
|------|--------|-----------|
| (unclaimed) | | |

## Available Tasks
Claim by moving to your agent section above.

| Task | Directory | ROM Available | Notes |
|------|-----------|---------------|-------|
| Kaneko sim harness | chips/kaneko_arcade/ + chips/kaneko/ | No bloodwar.zip — check for alternatives | GFX 32-bit just fixed |
| Taito B sim harness | chips/taito_b/ | crimec.zip, nastar.zip, pbobble.zip | CPU ROM just wired |
| Taito X sim harness | chips/taito_x/ | gigandes.zip, superman.zip, twinhawk.zip | CPU ROM + Z80 just fixed |
| NMK sprite investigation | chips/nmk_arcade/ | tdragon.zip | Blocked by nmk004.bin MCU ROM |

## Shared Resources (read-only, do not claim)
- chips/m68000/ — fx68k CPU files
- chips/nmk_arcade/sim/ — reference harness (copy, don't modify)
- chips/GUARDRAILS.md, chips/fx68k_integration_reference.md
