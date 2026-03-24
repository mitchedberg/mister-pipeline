# MiSTer Pipeline — Factory Operating System

## Mission
AI-driven MiSTer FPGA arcade core factory. Goal: systematically fill genuine gaps in MiSTer's
arcade library by building bulletproof cores, one hardware family at a time, with maximum reuse.

**North star:** Come back in two weeks and find two dozen cores perfect and ready for prime time.

---

## MANDATORY READS — Before Touching ANYTHING

| File | What | When |
|------|------|------|
| This file | Operating rules, factory architecture | Every session start |
| `chips/COMMUNITY_PATTERNS.md` | 400+ lines of community-validated RTL patterns | Before writing ANY RTL |
| `chips/GUARDRAILS.md` | 14 synthesis + 14 fx68k + sim rules | Before any synthesis or sim work |
| `.shared/failure_catalog.md` | Error signature → root cause → fix | Before debugging ANY issue |
| `.shared/task_queue.md` | Task claiming board | Before starting ANY work |
| `.shared/findings.md` | Cross-agent bug discoveries | Before starting ANY work |
| `.shared/agent_comms.md` | Agent-to-agent messages | Check for messages to you |

**If you skip these reads, you WILL re-derive something that took days to discover.**

---

## Factory Architecture

### Roles

**Orchestrator (Opus)** — periodic audits, architectural decisions, ecosystem checks, Delphi
consultations. Does NOT write RTL. Does NOT run simulations. Reads dashboards, dispatches
work, resolves blockers, updates factory docs.

**Foreman A: Synthesis & RTL** — owns the path from MAME reference → RTL → synthesis → bitstream.
Delegates RTL generation and lint fixes to Sonnet/Haiku workers. Reviews synthesis reports.
Maintains GUARDRAILS.md.

**Foreman B: Simulation & Validation** — owns the path from RTL → Verilator sim → MAME comparison
→ bug reports. Delegates harness building and dump generation to workers. Maintains sim
infrastructure.

**Workers (Sonnet/Haiku)** — execute discrete, bounded tasks. Never make architectural decisions.
Never work on more than one chip at a time. Always write findings to `.shared/` before finishing.

### Iron Rules

1. **Foremen delegate, workers execute.** A foreman that writes RTL directly is drifting.
   A worker that makes an architectural decision is drifting. Stay in your lane.

2. **Never fill your own context with work you should delegate.** If a task requires reading
   more than 3 files or running more than 2 commands, it's a subagent task.

3. **Write findings BEFORE context compacts.** Every discovery goes to `.shared/findings.md`
   or `.shared/failure_catalog.md` IMMEDIATELY. Not "at the end of the session." Now.

4. **Two-strike escalation.** If the same error appears twice, STOP. Add it to failure_catalog.md
   and escalate to the other foreman or the orchestrator. Do not retry a third time.

5. **Check failure_catalog.md before debugging.** Every time. The fix may already be documented.

6. **Check COMMUNITY_PATTERNS.md before writing RTL.** Every time. The pattern may already exist.

7. **One chip at a time through the pipeline.** Don't start chip B's synthesis until chip A
   passes. Context switching between failing chips is the #1 cause of drift.

8. **Never work on a core that already exists.** Check `project_mister_ecosystem_definitive.md`
   in memory AND search GitHub before starting any new system. Duplicating community work
   wastes weeks.

---

## Gate Pipeline

```
gate1: Verilator behavioral sim (lint + build)
  → gate2: check_rtl.sh (10 static checks)
    → gate3: Standalone synthesis (5-15 min, Quartus 17.0)
      → gate4: Full system synthesis (30-90 min, produces RBF)
        → gate5: MAME golden dump comparison (RAM byte-by-byte)
          → gate6: Opus RTL logic review (cross-reference vs MAME driver)
            → gate7: Hardware test on DE-10 Nano
```

**Never skip gates.** If gate N fails, fix it before proceeding to gate N+1.

---

## Directory Conventions

```
chips/
  <SYSTEM>/                    # Full arcade system (e.g., nmk_arcade, psikyo_arcade)
    rtl/                       # System RTL (emu.sv, memory map, I/O)
    quartus/                   # Quartus project (QSF, QIP, SDC, sys/, MRA)
    sim/                       # Verilator testbench (tb_top.sv, tb_system.cpp, Makefile)
    standalone_synth/          # Minimal synthesis harness (5-15 min)
    mra/                       # MiSTer ROM descriptors
  <CHIP>/                      # Individual chip (e.g., tc0180vcu, gp9001)
    rtl/                       # Chip RTL
    vectors/                   # Test vectors
    standalone_synth/          # Chip-only synthesis harness
  m68000/                      # Shared CPU (fx68k) — DO NOT MODIFY without foreman approval
  COMMUNITY_PATTERNS.md        # Community-validated patterns — READ FIRST
  GUARDRAILS.md                # Synthesis + sim rules — READ FIRST
  check_rtl.sh                 # Pre-synthesis static checker
  pattern-ledger.md            # jotego vs naive pattern comparison
  dashboard/                   # Web dashboard (port 5200)
.shared/                       # Outside git — instant sync across worktrees
  task_queue.md                # Task claiming board
  findings.md                  # Cross-agent discoveries
  failure_catalog.md           # Error signature → fix mapping
  agent_comms.md               # Agent messages
  heartbeat.md                 # Agent liveness tracking
```

---

## Shared Coordination Protocol

### Task Queue Format

Each task in `.shared/task_queue.md` must have:
```markdown
### TASK-NNN: <short description>
- **Status:** AVAILABLE | CLAIMED:<agent-name> | IN_PROGRESS | BLOCKED:<reason> | DONE | FAILED
- **Claimed at:** <ISO timestamp or "—">
- **Depends on:** TASK-NNN (or "none")
- **Error fingerprints:** <list of seen error hashes, or "none">
- **Retry count:** N
- **Assigned to:** foreman-a | foreman-b | worker | any
- **Checklist:**
  - [ ] Step 1
  - [ ] Step 2
  - ...
```

### Claiming Protocol
1. Read task_queue.md
2. Find task with status AVAILABLE (or ABANDONED) that you're qualified for
3. Change status to CLAIMED:<your-name>, set claimed_at to current ISO time
4. Do the work
5. If done: mark DONE, write results to appropriate file
6. If blocked: mark BLOCKED:<reason>, write to agent_comms.md
7. If failed: mark FAILED, add error to failure_catalog.md, increment retry_count

### Stale Claim Detection
If a task has been CLAIMED for >45 minutes with no heartbeat update, any agent may
mark it ABANDONED and re-claim it. Write a note in agent_comms.md explaining the takeover.

### Heartbeat
Every 15 minutes during long-running tasks (synthesis, simulation), write to
`.shared/heartbeat.md`:
```
<agent-name>: <ISO timestamp> — <what you're doing> — <% complete or ETA>
```

---

## Simulation Harness Rules

Every Verilator sim harness MUST follow `chips/nmk_arcade/sim/` as the reference.

### fx68k CPU — Non-Negotiable

1. **enPhi1/enPhi2 from C++, NEVER from RTL** — Verilator delta-cycle race (GUARDRAILS Rule 13)
2. **Use JTFPGA/fx68k fork** at `chips/m68000/hdl/fx68k/`
3. **Merge uaddrPla.sv always blocks** for Verilator (7 blocks → 1 block with case(line))
4. **VPAn = IACK detection** (`~&{FC2,FC1,FC0,~ASn}`), NEVER tied to 1'b1
5. **IPL cleared on IACK only** — NEVER use a timer. Use set/clear latch pattern.
6. **Register IPL through synchronizer FF** — prevents Verilator scheduling late-sample

See `chips/COMMUNITY_PATTERNS.md` Section 1 for the complete pattern with code.

### Harness Structure
- **tb_top.sv**: fx68k direct instantiation, enPhi1/enPhi2 as top-level inputs
- **tb_system.cpp**: Phi BEFORE eval on rising edge. `Verilated::fatalOnError(false)`.
- **Makefile**: `--trace -Wno-fatal`. JTFPGA fx68k sources.

### Validation Sequence (in order, never skip)
1. CPU boots (reset vector, first instructions) — bus cycle count > 0
2. RAM matches MAME after N frames — byte-by-byte comparison
3. VRAM/palette/scroll match — isolates graphics bugs to specific subsystem
4. Pixel comparison LAST — confirmation only, never primary debug tool

### Progressive Frame Validation (don't waste sim time)
Most arcade games spend 20-60 frames on ROM checksums and boot screens before reaching
gameplay. Start wider than you think:

Sim 50 frames → compare. Clean? Sim to 200. Clean? Sim to 500. Clean? Sim to 1000.
If first 50 are all-black/init, that's normal — extend to 200 before concluding anything.

**Stop at first GAMEPLAY divergence.** Boot-screen differences may be harmless timing.
Fix the earliest gameplay-affecting divergence first, always.

Do NOT sim 1000 frames and then look at the diff. If frame 60 is wrong, frames 61-1000
are cascading garbage that tells you nothing.

### CPU Bring-Up: Feature Gate First
When building a new core's sim harness, compile with `NOSOUND` and `NOVIDEO` defines.
Get the CPU booting and executing ROM code correctly BEFORE adding video/audio.
This is 2-3x faster compile and 5-10x faster simulation.
Add subsystems back one at a time: RAM first, then video, then audio, then I/O.

### Disk Hygiene (iMac has 228GB, fills up fast)
- Delete VCD traces after debugging (`rm *.vcd`) — they're 400MB+ each
- Delete PPM frame dumps after visual inspection — keep only the ones that show bugs
- Don't write debug logs to /tmp larger than 100MB — use `| tail -1000` or write to the sim dir
- The factory auto-cleans VCDs and old PPMs every 5 cycles, but don't rely on it

---

## Multi-Agent Coordination

Use **git worktrees** (`claude --worktree <name>`) for file isolation between sessions.

### Before starting work
<<<<<<< HEAD
1. Read `.shared/task_queue.md` — task claiming (OUTSIDE git, instant visibility)
2. Read `.shared/findings.md` — bugs found by OTHER agents that affect YOUR cores
3. Find a task with status AVAILABLE, change it to CLAIMED:<your-worktree>
4. Do the work following the checklist in task_queue.md
5. When done, change status to DONE, pick next AVAILABLE task
6. Never edit files in a directory another agent has claimed

### When you find a cross-cutting bug
Append to `.shared/findings.md` with: date, who found it, which cores are affected, the fix, and what action other agents should take. This is the broadcast channel.
=======
1. Read ALL mandatory files listed at top of this document
2. Check `.shared/task_queue.md` for your next task
3. Check `.shared/agent_comms.md` for messages to you
4. Check `.shared/failure_catalog.md` for known issues
5. Claim a task, do the work, report findings
>>>>>>> sim-batch2

### Never
- Edit files in a directory another agent has claimed
- Modify `chips/m68000/` without foreman approval (shared across all cores)
- Skip reading COMMUNITY_PATTERNS.md before writing RTL
- Debug an issue without checking failure_catalog.md first
- Re-derive something that's already documented in findings.md
- Start a new core without checking the ecosystem audit (memory file)

### Compute Resources
| Machine | SSH | Verilator | Notes |
|---------|-----|-----------|-------|
<<<<<<< HEAD
| Mac Mini 3 | local | /opt/homebrew/bin/ | 10-core M4, orchestrator |
| iMac-Garage | `ssh imac` | ~/tools/verilator/bin/ | 8-core M4, sim worker |
| RP's Mac Mini | `ssh rpmini` | needs install | 10-core M4, MAME ROM library |
| GPU PC | `ssh gpu` | No (Windows) | RTX 4070 Super, MAME reference frames |
=======
| Mac Mini 3 | local | /opt/homebrew/bin/ | 10-core M4, primary |
| iMac-Garage | `ssh imac` | ~/tools/verilator/bin/ | 8-core M4, sim worker |
| RP's Mac Mini | `ssh rpmini` | — | 13,954 ROMs, MAME golden dumps |
| GPU PC | `ssh gpu` | No (Windows) | RTX 4070 Super, MAME, parallel sim |
>>>>>>> sim-batch2

### ROMs
`/Volumes/2TB_20260220/Projects/ROMs_Claude/Roms/` — tdragon, batsugun, gunbird, etc.
Full MAME library on rpmini: `/Volumes/Game Drive/MAME 0 245 ROMs (merged)/`

---

## MAME Ground Truth

MAME source is the authoritative behavioral reference.

1. Check MAME source for the chip's emulation logic FIRST
2. Check COMMUNITY_PATTERNS.md for the integration pattern SECOND
3. Write RTL LAST

When gate5 (MAME comparison) shows discrepancies:
1. Check failure_catalog.md — is this a known issue?
2. Check MAME source for the chip's behavior
3. If RTL and MAME disagree, RTL is wrong — fix it
4. Add the fix to failure_catalog.md so no one re-derives it

---

## Anti-Drift Checklist

If you notice ANY of these, STOP and correct course:

- [ ] You've been working on the same file for >30 minutes → delegate to a worker
- [ ] You're reading diff output and guessing at fixes → check failure_catalog.md
- [ ] You're writing experimental code and running tests in a loop → stop, consult docs
- [ ] You're making architectural decisions as a worker → escalate to foreman
- [ ] You're writing RTL as a foreman → delegate to a worker
- [ ] You can't remember what task you're working on → re-read task_queue.md
- [ ] You're about to start a new core → check ecosystem audit first
- [ ] You've hit the same error twice → add to failure_catalog.md, escalate

---

## New Core Onboarding Checklist

Before starting ANY new arcade system:

1. **Ecosystem check:** Search GitHub (MiSTer-devel, jotego, va7deo, atrac17, Coin-Op).
   If it exists, skip it. If it's in development, evaluate whether our work adds value.

2. **MAME reference:** Find the driver `.cpp` in `mamedev/mame/src/mame/MANUFACTURER/`.
   Read the memory map, interrupt routing, and video timing. This is ground truth.

3. **Component inventory:** List CPU, sound chips, custom chips. Check which we already have
   (fx68k, T80, jt51, jt6295, jt10, jt03, jt49). Only build what's genuinely new.

4. **SDRAM layout:** Plan which bank holds which ROM region. Use the 5-channel pattern
   from existing cores. Document in the system's README.

5. **Reuse RTL:** Copy the closest existing system's directory structure. Modify, don't
   rewrite from scratch. `nmk_arcade` is the reference template.

6. **Sim first:** Build the Verilator harness BEFORE writing game-specific RTL.
   Verify CPU boots from ROM before adding graphics/audio.

7. **MAME golden dumps:** Generate frame-by-frame RAM dumps from MAME Lua on rpmini.
   Store as static golden reference files. This is the validation oracle.

---

## Quality Gates for "Done"

A core is NOT done until ALL of these pass:

- [ ] check_rtl.sh passes (0 warnings)
- [ ] Standalone synthesis fits DE-10 Nano (ALMs < 41,910)
- [ ] Full system synthesis produces RBF bitstream
- [ ] SDC timing constraints present (fx68k + T80 multicycle, clock groups)
- [ ] Verilator sim boots CPU from ROM
- [ ] MAME RAM comparison passes for 1000+ frames
- [ ] Opus RTL review completed (cross-reference vs MAME driver)
- [ ] MRA file has correct ROM CRCs from `mame -listxml`
- [ ] Audio wired (FM + ADPCM + Z80)
- [ ] Joystick I/O correct (Start=[7], Coin=[8])
