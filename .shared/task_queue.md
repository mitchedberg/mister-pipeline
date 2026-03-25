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

| Core | Owner | CPU | IRQ | Rendering | Attract | Next Action |
|------|-------|-----|-----|-----------|---------|-------------|
| NMK16 / Thunder Dragon | Agent 1 | ✅ | ✅ IACK fix | ✅ 100% f40+ | ✅ | MAME RAM comparison (running) |
| Toaplan V2 / Batsugun | Agent 1 | ✅ | 🔧 IACK dispatched | ✅ palette | ❌ | IACK fix should unblock |
| Psikyo / Gunbird | Agent 1 | ✅ | ✅ IACK fix applied | ❓ | ❌ | MAME RAM comparison next |
| Kaneko / Berlin Wall | Agent 2 | ✅ | ✅ IACK works | ✅ GPU tiles | ⚠️ static | Game state counter at $200000=0 doesn't advance |
| Taito B / Nastar | Agent 2 | ✅ | ✅ IACK applied | ⚠️ black (self-test loop) | ❌ | Gate-5: frames 30-90 = 0 diffs ✅; frames 91+ = 0.4% drift (audio stub) |
| Taito X / Gigandes | Agent 2 | ✅ | ❌ | ✅ BG tiles | ❌ | CLAIMED: Apply IACK fix |

### Agent 2 execution plan (NOW):
1. **Taito X IACK fix** → rebuild → test (BG tiles should animate)
2. **Taito B IACK fix** → rebuild → test (VCU should start outputting)
3. **berlwall state debug** → find what advances $200000 from 0

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


---

## Phase 0 Tasks (added 2026-03-20 21:17)

### TASK-100: Fix IPL timer->IACK clear in NMK arcade
- **Status:** DONE
- **Claimed at:** 2026-03-25T03:22:44Z
- **Completed at:** 2026-03-24T05:30:00Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [x] Read chips/COMMUNITY_PATTERNS.md Section 1.2
  - [x] Replace timer-based IPL in chips/nmk_arcade/rtl/nmk_arcade.sv:850-865 — RTL already had correct IACK-based latch pattern; root bug was missing cpu_inta_n wiring
  - [x] Use IACK-based set/clear latch pattern (inta_n = ~&{FC,FC,FC,~ASn}) — confirmed present
  - [x] Add IPL synchronizer FF — confirmed present (ipl_sync register, lines 891-898)
  - [x] Verify CPU takes interrupts in Verilator sim — 10 frames, 286K bus cycles, TOPSTK/STKTOP (SR=D0C4, IPL4) confirmed per frame
- **Result:** Three-file fix applied: fx68k_adapter.sv (add cpu_inta_n output port), emu.sv (declare wire cpu_inta_n, connect to fx68k_adapter and nmk_arcade). check_rtl.sh passes. Sim confirms interrupt handlers execute each frame.


### TASK-101: Fix IPL timer->IACK clear in Toaplan V2
- **Status:** DONE
- **Claimed at:** 2026-03-24T21:46:22Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] Read chips/COMMUNITY_PATTERNS.md Section 1.2
  - [ ] Replace timer-based IPL in chips/toaplan_v2/rtl/toaplan_v2.sv:806-834
  - [ ] Use IACK-based set/clear latch pattern
  - [ ] Add IPL synchronizer FF
  - [ ] Verify CPU takes interrupts in Verilator sim


### TASK-102: Fix IPL timer->IACK clear in Psikyo arcade
- **Status:** DONE
- **Claimed at:** 2026-03-24T21:46:22Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [x] Read chips/COMMUNITY_PATTERNS.md Section 1.2
  - [x] Replace timer-based IPL in chips/psikyo_arcade/rtl/psikyo_arcade.sv:1390-1405 (RTL was already IACK-based; root bug was missing cpu_inta_n wiring in emu.sv and tb_top.sv)
  - [x] Use IACK-based set/clear latch pattern (confirmed present in psikyo_arcade.sv lines 1421-1438)
  - [x] Add IPL synchronizer FF (confirmed present in psikyo_arcade.sv lines 1434-1437)
  - [x] Verify CPU takes interrupts in Verilator sim (sim builds clean, 10 frames complete, ~30K instructions)


### TASK-103: Add fx68k SDC multicycle paths to all synthesis SDC files
- **Status:** DONE
- **Claimed at:** 2026-03-24T05:15:56Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [x] Read chips/COMMUNITY_PATTERNS.md Section 1.7
  - [x] Add Ir->microAddr/nanoAddr multicycle paths to every .sdc file
  - [x] Add nanoLatch->pswCcr and oper->pswCcr multicycle paths
  - [x] Add T80 Z80 multicycle path (setup 2, hold 1)
  - [x] Verify: grep all .sdc files for multicycle_path presence


### TASK-104: Fix IPL timer->IACK clear in Kaneko arcade
- **Status:** DONE
- **Claimed at:** 2026-03-24T21:46:22Z
- **Completed at:** 2026-03-24T22:10:00Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [x] Read chips/COMMUNITY_PATTERNS.md Section 1.2
  - [x] Check chips/kaneko_arcade/rtl/kaneko_arcade.sv for timer-based IPL
  - [x] Replace with IACK-based set/clear latch pattern (already done — fixed multi-level IACK bug instead)
  - [x] Add IPL synchronizer FF (already present)
- **Result:** IPL latches were already IACK-based (not timer). Fixed two related bugs:
  1. Multi-level IACK: shared inta_n cleared all three latches on any IACK — replaced with
     level-specific iack3/4/5_n decode using cpu_addr[3:1] (per failure_catalog).
  2. cpu_fc unconnected in emu.sv: kaneko_arcade.sv derives inta_n from cpu_fc but emu.sv
     never wired cpu_fc from fx68k_adapter. Added cpu_fc output to fx68k_adapter.sv and
     wired .cpu_fc(cpu_fc) in emu.sv for both fx68k_adapter and kaneko_arcade instantiations.
  check_rtl.sh: all checks passed.


### TASK-105: Fix IPL timer->IACK clear in Taito B
- **Status:** DONE
- **Claimed at:** 2026-03-25T03:12:40Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] Read chips/COMMUNITY_PATTERNS.md Section 1.2
  - [ ] Check chips/taito_b/rtl/taito_b.sv for timer-based IPL
  - [ ] Replace with IACK-based set/clear latch pattern


### TASK-106: Fix IPL timer->IACK clear in Taito X
- **Status:** DONE
- **Claimed at:** 2026-03-25T03:12:40Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] Read chips/COMMUNITY_PATTERNS.md Section 1.2
  - [ ] Check chips/taito_x/rtl/taito_x.sv for timer-based IPL
  - [ ] Replace with IACK-based set/clear latch pattern


### TASK-110: Generate MAME golden RAM dumps for Thunder Dragon (NMK)
- **Status:** DONE
- **Claimed at:** 2026-03-25T03:12:40Z
- **Completed at:** 2026-03-24T22:30:00Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [x] SSH to rpmini: ssh rpmini (prior TASK-070 work)
  - [x] Find tdragon ROM in /Volumes/Game Drive/MAME 0 245 ROMs (merged)/ (verified available)
  - [x] Write MAME Lua script (clone chips/nmk_arcade/sim/mame_ram_dump.lua) (completed in TASK-070)
  - [x] Run: mame tdragon -autoboot_script dump.lua -nothrottle -str 3000 (completed 2026-03-22)
  - [x] Copy dumps back to chips/nmk_arcade/sim/golden/ (completed, verified at 92 MB, 1124 frames)
- **Result:** Golden dumps verified at chips/nmk_arcade/sim/golden/tdragon_frames.bin — 1124 frames, 92 MB, WRAM base corrected to 0x0B0000 per COMMUNITY_PATTERNS analysis. File format: 4B LE frame number + 65536B MainRAM + 2048B Palette + 16384B BGVRAM + 2048B TXVRAM + 8B ScrollRegs per frame.


### TASK-111: Generate MAME golden RAM dumps for Batsugun (Toaplan V2)
- **Status:** DONE
- **Claimed at:** 2026-03-25T03:13:40Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] SSH to rpmini: ssh rpmini
  - [ ] Find batsugun ROM
  - [ ] Write MAME Lua script for batsugun memory map
  - [ ] Run: mame batsugun -autoboot_script dump.lua -nothrottle -str 3000
  - [ ] Copy dumps to chips/toaplan_v2/sim/golden/


---

## Phase 1 Tasks (added 2026-03-20 21:17)

### TASK-200: Raizing/Battle Garegga: GAL banking for GP9001 variant
- **Status:** DONE
- **Claimed at:** 2026-03-25T03:13:40Z
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] Read MAME raizing.cpp for GAL banking differences vs batsugun
  - [ ] Read psomashekar/Raizing_FPGA raizing_gcu.v for reference
  - [ ] Implement GAL bank switching in GP9001 module
  - [ ] Add game-specific MRA for Battle Garegga


### TASK-201: Batrider/Bakraid: Object bank switching + YMZ280B audio
- **Status:** DONE
- **Claimed at:** 2026-03-25T03:13:40Z
- **Depends on:** TASK-200
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] Read MAME raizing_batrider.cpp for object bank switching
  - [ ] Implement 8-slot object bank register (GP9001_OP_OBJECTBANK_WR)
  - [ ] Add YMZ280B audio chip (check jotego jtcores for existing impl)
  - [ ] Add ExtraText DMA layer (TVRMCTL7)
  - [ ] Add MRAs for Batrider and Battle Bakraid


### TASK-202: Dual GP9001: Batsugun/Dogyuun priority mixing
- **Status:** DONE
- **Claimed at:** 2026-03-25T03:14:42Z
- **Depends on:** TASK-200
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] Read MAME batsugun.cpp — dual VDP instantiation
  - [ ] Instantiate second GP9001 module
  - [ ] Implement priority mixing between dual VDPs
  - [ ] Add MRAs for Batsugun, Dogyuun, V-Five, Knuckle Bash, Snow Bros 2


---

## Phase 2 Tasks (added 2026-03-20 21:17)

### TASK-300: Afega: NMK16 derivative, minimal address map changes
- **Status:** DONE
- **Claimed at:** —
- **Depends on:** TASK-100
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] Read MAME nmk16.cpp Afega variants
  - [ ] Copy NMK16 system, adjust address map per Afega games
  - [ ] Add MRAs for Red Hawk, Stagger I, Sen Jin
  - [ ] Run check_rtl.sh


### TASK-301: ESD 16-bit: Simple 68K arcade, 8-12 games
- **Status:** DONE
- **Claimed at:** —
- **Depends on:** none
- **Error fingerprints:** none
- **Retry count:** 0
- **Assigned to:** worker
- **Checklist:**
  - [ ] Read MAME esd16.cpp for memory map and hardware
  - [ ] Check ecosystem audit — verify no existing core
  - [ ] Scaffold new system: chips/esd_arcade/
  - [ ] Implement memory map, video, I/O from MAME reference
  - [ ] Add MRAs for Multi Champ, Head Panic, etc.
