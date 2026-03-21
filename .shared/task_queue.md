# Task Queue — Shared Across All Agents
#
# This file lives OUTSIDE git (.gitignore'd) so all agents see changes
# instantly regardless of which worktree they're in.
#
# Protocol:
#   1. Read this file before starting work
#   2. Find a task with status AVAILABLE
#   3. Change its status to CLAIMED:<your-worktree-name>
#   4. Do the work
#   5. Change status to DONE
#   6. Pick the next AVAILABLE task
#
# If a task is CLAIMED by another agent, skip it.

## Sim Harness Build Queue

| Core | Status | Worktree | ROM | Notes |
|------|--------|----------|-----|-------|
| NMK16 / Thunder Dragon | DONE | master | tdragon.zip | Reference harness |
| Toaplan V2 / Batsugun | DONE | master | batsugun.zip | CPU runs 1.38M cycles, V25 shared RAM added |
| Psikyo / Gunbird | DONE | master | gunbird.zip | CPU boots, 5 frames captured |
| Kaneko / Berlin Wall | DONE | sim-batch2 | berlwall.zip | GPU renders 2 frames of colored backgrounds. Correct address map found (BerlwallInit, NOT GtmrMachineInit). AY8910 DIP stub added. Game stuck in init loop — needs VBlank handler tracing. Commits d6a35a5→4c178c8→52ae22a |
| Taito B / Nastar | DONE | sim-batch2 | nastar.zip | CPU runs 82K+ bus cycles, 300 frames. Pixel capture fix applied (clk_pix gating). ALL frames black — TC0180VCU not producing visible output. Needs VCU register debug. |
| Taito X / Gigandes | DONE | sim-batch2 | gigandes.zip | CPU runs, 300 frames, 4 distinct states. Garbled sprites — X1-001A GFX ROM addressing wrong. NOT a CPU stall. |

## Process Per Core (copy-paste checklist)

Each core follows identical steps:
1. Read `chips/<CORE>/rtl/<core>.sv` — understand port interface
2. Read `chips/<CORE>/quartus/emu.sv` — understand SDRAM layout, video timing
3. Create `chips/<CORE>/rtl/tb_top.sv` — copy NMK pattern, adjust ports
4. Create `chips/<CORE>/sim/tb_system.cpp` — copy NMK pattern, adjust SDRAM/video/ROM
5. Create `chips/<CORE>/sim/Makefile` — adjust source paths
6. Create `chips/<CORE>/sim/run_sim.py` — adjust ROM extraction
7. Build: `make -j8`
8. Run: `python3 run_sim.py --<game>-zip <rom.zip> --frames 30`
9. Report: does CPU boot? (>6 bus cycles) Any non-black frames?
10. If CPU boots but black frames: check GFX ROM bridge (use combinational read)
11. Update PROJECT_STATUS.md
12. Commit to worktree branch, push

## Validation Queue — Get to 100% (or near)

Each core needs to reach "attract mode renders correctly" before moving to new cores.

| Core | CPU Boot | Frames | Rendering | Attract Mode | Blocker |
|------|----------|--------|-----------|-------------|---------|
| NMK16 / Thunder Dragon | ✅ | ✅ 3000+ | ✅ game graphics | ❓ | Need MAME comparison |
| Toaplan V2 / Batsugun | ✅ | ✅ | ✅ partial | ❓ | V25 sound CPU vs Z80 |
| Psikyo / Gunbird | ✅ | ✅ 5 | ❓ | ❌ | Need more frames |
| Kaneko / Berlin Wall | ✅ | ✅ 600 | ✅ 2 frames | ❌ | Game init loop doesn't exit — VBlank handler tracing needed |
| Taito B / Nastar | ✅ | ✅ 300 | ❌ all black | ❌ | TC0180VCU not producing output — VCU register config? |
| Taito X / Gigandes | ✅ | ✅ 300 | ⚠️ garbled | ❌ | X1-001A GFX ROM address mapping |

### Priority order for getting to 100%:
1. **Kaneko** — closest to working (GPU renders, just needs init loop fix)
2. **Gigandes** — CPU runs, just needs GFX address fix
3. **Nastar** — needs deeper VCU investigation
4. **Master branch cores** — need validation runs with MAME comparison

## Optimization Tasks

| Core | Status | Notes |
|------|--------|-------|
| Taito F3 ALM reduction | AUDIT DONE | Root cause: 4x BG engines + lineram parallelism = 461% ALM. Needs Opus architectural review — time-multiplexed rendering pipeline (1 shared BG engine cycling at 4x clock). See chips/taito_f3/OPTIMIZATION_AUDIT.md and memory/project_taito_f3_optimization.md |
| Taito Z dual-68k | AVAILABLE | 2x fx68k instances = too many ALMs. Time-share one fx68k between main+sub CPUs (they alternate bus access). Opus arch review recommended. |
| Opus architectural review | AVAILABLE | Run Opus review on Taito F3 and Taito Z — design time-multiplexed architectures that fit DE-10 Nano (49K ALMs). N64 core proves much more complex designs can fit with proper multiplexing. |

## Future Cores (not started — for when current queue is green)

These require new RTL, not just sim harnesses:
- Konami System GX
- Video System / Aero Fighters
- SETA 1
- Sega X Board / Y Board
