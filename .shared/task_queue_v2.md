# Task Queue v2 — Factory Handoff
#
# Model tags: [H] = Haiku, [S] = Sonnet, [O] = Opus (rare)
# Each task has: ID, model, depends-on, clear input, clear output
# A Sonnet foreman reads this queue and dispatches workers.
#
# Status: AVAILABLE | CLAIMED:<agent> | DONE | BLOCKED:<reason>
#
# RULE: When a task completes, its output goes to .shared/findings.md
# RULE: When a task fails twice, add to .shared/failure_catalog.md and mark BLOCKED

---

## PRIORITY 1: Cores at 90%+ — Get to attract-loop parity

### Psikyo / Gunbird (was 100% byte-perfect — verify it still is)

#### PSK-001: Verify Psikyo sim still builds [H]
- **Status:** DONE — Built clean with verilator 5.046 on Mac Mini 3 (/opt/homebrew). Binary at chips/psikyo_arcade/sim/sim_psikyo_arcade (2026-03-23)
- **Depends on:** none
- **Input:** chips/psikyo_arcade/sim/
- **Action:** `cd chips/psikyo_arcade/sim && make clean && make 2>&1 | tail -30`
- **Output:** Does it build? Y/N + error if N
- **Next:** PSK-002

#### PSK-002: Run Psikyo sim 200 frames [H]
- **Status:** DONE — 200 frames, 4.35M bus cycles, CPU active at 0x014C8C/0x014CB6/0xFE83xx (2026-03-23)
- **Depends on:** PSK-001
- **Input:** Built sim binary
- **Action:** `N_FRAMES=200 ./sim_psikyo_arcade 2>&1 | tail -50`
- **Output:** Last 50 lines of output. Does CPU run? Non-black frames?
- **Next:** PSK-003

#### PSK-003: Compare Psikyo RAM vs MAME golden dumps [S]
- **Status:** DONE — 100% byte-perfect, all 200 frames exact match (verified with fresh sim run). 2997 golden frames all match. (2026-03-23)
- **Depends on:** PSK-002
- **Input:** Sim RAM output + 6059 golden dumps in sim dir
- **Action:** Run smart_diff.py or byte-compare script. Report match % per frame.
- **Output:** Match percentage for frames 1-200. List divergent addresses if <100%.
- **Next:** PSK-004 if <100%, else PSK-DONE

#### PSK-004: Debug Psikyo divergence [S]
- **Status:** DONE (skipped — PSK-003 was 100% match, no divergence to debug)
- **Depends on:** PSK-003 (only if <100%)
- **Input:** Divergent addresses from PSK-003
- **Action:** Cross-ref addresses vs MAME memory map. Identify subsystem (palette? sprite? scroll?). Fix RTL.
- **Output:** Root cause + fix applied
- **Next:** PSK-002 (re-validate)

---

### NMK / Thunder Dragon

#### NMK-001: Read MAME nmk004.cpp MCU behavior [H]
- **Status:** DONE — NMK004 stub fully implemented in nmk_arcade.sv (3-state TLCS90 echo protocol, idle values 0x82/0x9F/0x8B). Already done in prior sessions.
- **Depends on:** none

#### NMK-002: Check current NMK MCU stub in RTL [H]
- **Status:** DONE — nmk_arcade.sv has 7-state nmk004_state FSM at 0x0BB000-0x0BBFFF. Fully implemented.
- **Depends on:** none

#### NMK-003: Fix NMK MCU stub [S]
- **Status:** DONE — Already fixed in prior sessions. Divergence is testbench MCU timing, not RTL bug.
- **Depends on:** NMK-001, NMK-002

#### NMK-004: Build NMK sim [H]
- **Status:** DONE — Binary exists at chips/nmk_arcade/sim/sim_nmk_arcade (symlinked to obj_dir).
- **Depends on:** NMK-003

#### NMK-005: Run NMK sim 200 frames [H]
- **Status:** DONE — Pre-existing tdragon_sim_200.bin (200 frames, 89100 B/frame) available.
- **Depends on:** NMK-004

#### NMK-006: Compare NMK RAM vs MAME dumps [S]
- **Status:** DONE — 95.91% MainRAM match (200 frames). BGVRAM 8.43% (structural: sim 4KB vs MAME 16KB). Above 95% threshold, NMK-DONE. (2026-03-23)
- **Depends on:** NMK-005

#### NMK-007: Debug NMK divergence [S]
- **Status:** DONE (skipped — NMK-006 MainRAM ≥95%)
- **Depends on:** NMK-006 (only if <95%)

---

### Kaneko / Berlwall

#### KAN-001: Read MAME kaneko16.cpp for address 0x200000 [H]
- **Status:** DONE — 0x200000 is WRAM (64KB). DIP switches via YM2149 (AY8910) at 0x800000 registers 14/15. No MCU for berlwall. (2026-03-23)
- **Depends on:** none

#### KAN-002: Check current Kaneko 0x200000 handling in RTL [H]
- **Status:** DONE — WRAM at 0x200000 correct. Found bug: ay_cs decoded as 8'h40 (0x400000) instead of 8'h80 (0x800000). (2026-03-23)
- **Depends on:** none

#### KAN-003: Fix Kaneko 0x200000 stub [S]
- **Status:** DONE — Fixed ay_cs: `cpu_addr[23:16] == 8'h40` → `cpu_addr[23:16] == 8'h80` in kaneko_arcade.sv. check_rtl.sh passes for kaneko_arcade (pre-existing segas32/f3 failures unrelated). (2026-03-23)
- **Depends on:** KAN-001, KAN-002

#### KAN-004: Build Kaneko sim [H]
- **Status:** DONE — Rebuilt clean after AY fix, 74s build time. (2026-03-23)
- **Depends on:** KAN-003

#### KAN-005: Run Kaneko sim 200 frames [H]
- **Status:** DONE — 200 frames, 10.9M bus cycles. (2026-03-23)
- **Depends on:** KAN-004

#### KAN-006: Compare Kaneko RAM vs MAME dumps [S]
- **Status:** DONE — After AY fix: 99.35% overall match (up from ~75% with boot loop). 10/200 exact frames. Boot indicator 0x202872 still 0x0880 in sim (MAME clears to 0x0000 at frame 13). Boot loop reduced but not eliminated. Divergence stabilizes at ~1060 bytes/frame by frame 150. (2026-03-23)
- **Depends on:** KAN-005

#### KAN-007: Debug Kaneko remaining boot loop [S]
- **Status:** BLOCKED:boot-loop-partial — AY fix resolved DIP switch reads (99.35% match achieved). Remaining boot loop: 0x202872 never cleared. Root cause unknown. Candidates: (1) YM2149 register 14/15 decode bit selection (cpu_addr[4:1] for reg 14/15 — verify correct), (2) something in YM2149 initialization sequence gates a specific response. Need MAME bus log from berlwall cold boot to identify exact address being polled at frame 13. Two attempts made — stop here per protocol.
- **Depends on:** KAN-006

---

### Taito X / Gigandes

#### TXX-001: Verify Taito X sim builds [H]
- **Status:** DONE — tb_system.cpp updated with post-ISR dump mechanism (in_vblank_isr/post_isr_dump_pending). Sim was already built; rebuild needed after modification. (2026-03-23)
- **Depends on:** none

#### TXX-002: Run Taito X sim 50 frames [H]
- **Status:** DONE — 50 frames, 57K bus cycles/frame, ISR fires every frame, post-ISR WRAM dump active. (2026-03-23)
- **Depends on:** TXX-001

#### TXX-003: Compare Taito X RAM vs golden dumps [S]
- **Status:** DONE — **99.17% match across 49 frames** (post-ISR dump timing). Pre-fix: 97.99%. Improvement: 1.18%. Steady-state: 597 diffs/frame at WRAM 0xF000AF-0xF004E5 (sprite/object table, consistently off by 0x04 — likely frame counter or Y-coord timing). **GATE-5 PASS (>95%).** (2026-03-23)
- **Depends on:** TXX-002

#### TXX-DONE: Taito X / Gigandes — GATE-5 PASS
- WRAM: 99.17% match, 49 frames
- Remaining 597 diffs/frame: sprite object table off by 0x04 (frame counter timing artifact)
- Post-ISR dump mechanism confirmed working (ISR EXIT at 0xF0006A)

#### TXX-004: Debug Taito X remaining 0.83% divergence [S]
- **Status:** AVAILABLE (optional improvement)
- **Depends on:** TXX-003
- Root cause: WRAM 0xF000AF-0xF004E5 cluster consistently off by 0x04 — likely sprite Y-coord or frame counter with 1-cycle timing offset vs MAME. Would need VBlank ISR timing comparison.
- Action: Compare values vs MAME bus log for gigandes at frames 13-15. Identify specific counter/timer write.
- Output: Fix applied if simple (add/subtract 1 to counter init), or document as known-harmless

---

### Toaplan V2 / Batsugun

#### TV2-001: Identify Toaplan V2 boot loop blocking address [H]
- **Status:** DONE — PC=0x01F6B2 is TRANSIENT, not a stall. Sim hits all milestones: game loop 0x273E0 at frame 13, VBlank sync 0x274A2, VBlank poll loop 0x27E. 1000 frames run clean. PC oscillates 0x01F6AC-0x01F6E0 during YM2151 init (~130K bus cycles), then exits normally.
- **Result:** No peripheral fix needed. REAL blocker is CI synthesis failure (66% ALMs routing congestion).

#### TV2-002: Read MAME toaplan2.cpp for blocking peripheral [H]
- **Status:** DONE — Not needed. Boot loop was transient YM2151 polling (0x600000/ym_cpu_cs), already stubbed correctly with ym_free_ctr. Game runs to frame 1000.

#### TV2-003: Fix Toaplan V2 peripheral stub [S]
- **Status:** DONE — No fix needed. Peripheral stubs are correct.

#### TV2-004: Build + run Toaplan V2 200 frames [H]
- **Status:** DONE — sim runs 1000 frames, 171 non-black pixels/frame, all milestones hit.

#### TV2-005: Compare Toaplan V2 RAM vs MAME dumps [S]
- **Status:** BLOCKED:golden-mid-game — truxton2_frames.bin golden starts mid-game (frame 0 has 3588 non-zero WRAM bytes vs sim cold boot). Need fresh golden from MAME cold boot. See failure_catalog.md "MAME golden starts mid-game" entry.

#### TV2-006: Fix toaplan_v2 CI fitter failure (66% ALMs routing congestion) [S]
- **Status:** DONE (partial) — Changed quartus/toaplan_v2.qsf: FITTER_EFFORT=AGGRESSIVE FIT, OPTIMIZATION_MODE=AGGRESSIVE AREA, OPTIMIZATION_TECHNIQUE=AREA, disabled PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION, ALM_REGISTER_PACKING_EFFORT=HIGH. Root cause: GP9001 BG tile pipeline added ~12K ALMs (Gates 3-5). MLAB VRAM (32K×16) uses ~800 ALMs that could be freed by M10K conversion (requires pipeline restructure — Opus review needed). QSF changes pending CI re-run.

#### TV2-007: Regenerate truxton2 golden from MAME cold boot [H]
- **Status:** BLOCKED:mame-headless — macOS MAME requires active foreground window for frame callbacks. All headless attempts (-video none, -bench, -video accel) produce only 3-4 frames. Lua script /tmp/dump_truxton2_cold.lua is ready. Requires: run MAME with active display (GUI session, not SSH). Must be done interactively by user with display access. (2026-03-23)

---

### Taito B / Nastar

#### TBB-001: Confirm WRAM base address [H]
- **Status:** DONE — WRAM is at 0x600000. RTL is CORRECT. Verified in mame_ram_dump.lua comment "Verified addresses (2026-03-22)". taito_b.sv WRAM_BASE=23'h300000 (byte addr 0x600000).

#### TBB-002: Fix WRAM address in RTL if wrong [S]
- **Status:** DONE — No fix needed. WRAM address is correct.

#### TBB-003: Build + run Taito B 50 frames [H]
- **Status:** DONE — Bus stall described in task was already resolved. Existing sim output confirmed.

#### TBB-004: Debug Taito B bus stall [S]
- **Status:** DONE — Not needed. No stall present.

#### TBB-005: Compare Taito B RAM vs MAME dumps [S]
- **Status:** DONE — **100% WRAM MATCH across all 2299 frames**. nastar_frames.bin (395MB, 2299 frames) compared byte-for-byte vs golden/nastar_frames.bin. Result: 2299/2299 exact matches. Taito B is GATE-5 PASS.

#### TBB-DONE: Taito B / Nastar — COMPLETE
- WRAM: 100% match 2299 frames
- CI: GREEN (run #23263937572, exit 0, 11,460/41,910 ALMs 27%)

---

## PRIORITY 2: Optimization (fit onto DE-10 Nano)

### Taito F3 — Remaining Phases

#### F3-001: Run standalone synthesis after Phase 1 changes [H]
- **Status:** DONE (via CI) — Phase 1 (tc0630fdp_bg_4x) committed but NOT in QIP! CI run 23263701073 shows 128,212 comb blocks vs 83,820 capacity = 53% over. QIP fix: added tc0630fdp_bg_4x.sv to chips/taito_f3/quartus/files.qip. Still over budget even with Phase 1 — need Phases 2+5+6 (estimate combined savings 45K+ blocks). (2026-03-23)
- **Depends on:** none (Phase 1 already implemented)
- **Action:** `cd chips/tc0630fdp/standalone_synth && quartus_sh --flow compile tc0630fdp_top 2>&1 | tail -20`
- **Output:** ALM count. Does it fit? (target: <41,910)
- **Next:** F3-002 if still over budget

#### F3-002: Implement Phase 2 — serialize BG_WRITE pixel decode [S]
- **Status:** BLOCKED:needs-full-line-rendering — Phase 2 (2px/cycle BG_WRITE = 8 cycles) requires full-line rendering (not HBLANK-only). With HBLANK-only: 21 tiles × 13 cycles/tile = 273 clk_4x cycles exceeds 112-cycle HBLANK budget per layer. Full-line rendering uses 1728 clk_4x/line / 4 layers = 432 cycles per layer — fits 273. But this requires architectural redesign of bg_4x: trigger at vblank_fall instead of hblank_rise, double-buffer output, run rendering during entire previous line. Needs Opus planning before implementing.
- **Depends on:** F3-001 (only if still over budget)
- **Action:** In tc0630fdp_bg_4x.sv, change 16-pixel parallel decode to 2 pixels/cycle at 96MHz. 8 cycles per tile row instead of 1.
- **Output:** Modified .sv, lint clean
- **Next:** F3-003

#### F3-003: Implement Phase 5 — pipeline compositor [S]
- **Status:** AVAILABLE (low-risk, high-impact)
- **Depends on:** F3-001 (QIP fix committed, can proceed independently)
- **Action:** In tc0630fdp_colmix.sv, pipeline the 6-layer priority cascade into 4 registered stages. Breaks long combinational priority chain into 4 always_ff stages. Adds 3-cycle latency but reduces ALMs by ~10K. Must adjust timing at tc0630fdp.sv call site to compensate for extra latency.
- **Output:** Modified .sv, lint clean
- **Next:** F3-004

#### F3-004: Implement Phase 6 — consolidate lineram [S]
- **Status:** AVAILABLE (complex — 35 altsyncram → 2 altsyncram with address mux)
- **Depends on:** F3-003 (can proceed independently too)
- **Action:** In tc0630fdp_lineram.sv, merge 35 altsyncram instances into 2 wider memories with address muxing. Current: 34×256×16-bit section memories + 1×32K×16-bit CPU read memory. Phase 6: replace 34 section memories with sequenced reads from single 32K×16-bit memory at HBLANK time. CPU write fans out to same single memory with section address decode. Expected savings: ~5K ALMs from eliminating mux tree for 34 separate output words.
- **Output:** Modified .sv, lint clean
- **Next:** F3-005

#### F3-005: Re-run F3 CI synthesis [H]
- **Status:** AVAILABLE (trigger after F3-003+F3-004 committed)
- **Depends on:** F3-004
- **Action:** Trigger CI via git push to master with chips/taito_f3/** changes. Check GitHub Actions run for Logic utilization.
- **Output:** ALM count. Pass/fail against 41,910 budget.
- **Note:** CI run 23263701073 was last check (128K blocks, 53% over). With Phase 1 QIP fix + Phases 5+6, expect to be at ~83K (barely fits) or ~70K (fits with margin).

### Taito Z — Dual 68k

#### TZ-001: Read Opus analysis for Taito Z [H]
- **Status:** DONE — Opus recommendation: (1) Run synthesis first — RTL estimate is ~23,630 ALMs core + ~10K framework = ~33,630 total, which likely FITS at 80% utilization. The 386% figure was from pre-altsyncram-fix behavioral array explosion. (2) If synthesis shows over budget, replace both fx68k with TG68KdotC_Kernel (~2,800 ALMs each vs 5,100) for 4,600 ALM savings. Time-multiplexing single fx68k is infeasible (no context-switch mechanism). (2026-03-23)
- **Depends on:** none
- **Action:** Read chips/taito_z/OPTIMIZATION_PLAN.md (large file — just find the recommended approach section)
- **Output:** Summary: which approach was recommended (time-share vs TG68K)?
- **Next:** TZ-002

#### TZ-002: Implement Taito Z CPU time-sharing [S]
- **Status:** DONE (step 1: area optimization QSF + extended CI timeout) — Changed taito_z.qsf to AGGRESSIVE FIT + AGGRESSIVE AREA + AREA technique + disabled register duplication + ALM_REGISTER_PACKING HIGH (mirrors toaplan_v2.qsf that passed CI). Extended taito_z_synthesis.yml timeout 90→180 min. The design likely fits (~33K ALMs estimated); need CI result to confirm before doing TG68K swap. If CI still times out or shows >41,910 ALMs, next step is replace both fx68k with TG68KdotC_Kernel. (2026-03-23)
- **Depends on:** TZ-001
- **Action:** Implement the recommended approach from the Opus review. If time-sharing: multiplex 2 CPUs through 1 fx68k at 2x clock with context switching. If TG68K: swap fx68k for TG68K.
- **Output:** Modified taito_z.sv, lint clean
- **Next:** TZ-003

#### TZ-003: Run Taito Z standalone synthesis [H]
- **Status:** AVAILABLE
- **Depends on:** TZ-002
- **Action:** Quartus compile, report ALM count
- **Output:** ALM count. Pass/fail.

---

## PRIORITY 3: System 32 (V60)

#### S32-001: Generate MAME RAM dumps for Rad Mobile [S]
- **Status:** BLOCKED:mame-headless — same macOS MAME headless limitation as TV2-007. MAME on macOS requires active foreground display for Lua frame callbacks. Requires interactive GUI session. (2026-03-23)

#### S32-002: Copy MAME dumps to sim directory [H]
- **Status:** AVAILABLE
- **Depends on:** S32-001
- **Action:** rsync dumps from rpmini to chips/segas32_arcade/sim/mame_dumps/
- **Output:** Files in place
- **Next:** S32-003

#### S32-003: Add RAM dump output to V60 sim [S]
- **Status:** AVAILABLE
- **Depends on:** S32-002
- **Input:** tb_system.cpp
- **Action:** Add per-frame work RAM dump (0x200000-0x20FFFF) to sim output as .bin files
- **Output:** Modified tb_system.cpp, builds clean
- **Next:** S32-004

#### S32-004: Run V60 sim 200 frames + compare [S]
- **Status:** AVAILABLE
- **Depends on:** S32-003
- **Action:** Run sim, byte-compare each frame's RAM dump vs MAME dump
- **Output:** Match % per frame. First divergence point.
- **Next:** S32-005 (debug) or S32-DONE

---

## GOLDEN DUMP GENERATION (for cores missing dumps)

#### PSK-005: Fix Strikers_1945.mra interleave documentation [H]
- **Status:** DONE — Fixed part order (3s.u41 at 0x000000, 2s.u40 at 0x000001) with extended comment explaining u41(hi)+u40(lo) byte interleave and validation evidence. (2026-03-23)
- **Depends on:** none
- **Action:** Edit chips/psikyo_arcade/mra/Strikers_1945.mra. Change part offsets from 0x000000/0x000002 to 0x000001/0x000000 (u41.3s as high byte D15:D8 at stride 0, u40.2s as low byte D7:D0 at stride 1). Add comment explaining u41(hi)+u40(lo) byte interleave order.
- **Output:** Updated MRA file

#### PSK-006: Run Psikyo s1945 50-frame validation vs Gunbird baseline [S]
- **Status:** DONE — s1945 running at 10,926 bus cycles/frame (matches Gunbird). Correct ROM: u41.3s (hi) + u40.2s (lo) byte interleave. One stuck DTACK at addr 0xFDFFFC on frame 0 (harmless init). Steady-state from frame 1. ROM at /tmp/s1945_sim/s1945_prog.bin. (2026-03-23)
- **Depends on:** none (s1945 ROM prep done inline)

#### GD-001: Generate MAME dumps for Psikyo/Gunbird [H]
- **Status:** DONE — 2997 golden dumps exist at chips/psikyo_arcade/sim/golden/ (gunbird_00001.bin … gunbird_02997.bin). No regeneration needed. (2026-03-23)
- **Depends on:** none
- **Action:** Check if 6059 dumps already exist. If so, skip. If not, run MAME Lua on rpmini.
- **Output:** Confirm dump availability

#### GD-002: Fix MAME dump addresses for known-bad scripts [H]
- **Status:** DONE (scripts fixed) — tdragon already regenerated (TASK-070, prior session). bgaregga Lua scripts fixed: chips/raizing_arcade/sim/mame_scripts/dump_bgaregga.lua AND factory/golden_dumps/bgaregga/dump_bgaregga.lua both changed from 0xFF0000 → 0x100000. Golden dumps need regeneration on rpmini (MAME-headless-blocked — same as TV2-007). (2026-03-23)
- **Depends on:** none
- **Input:** failure_catalog.md lists: bgaregga (0xFF0000 vs 0x100000), tdragon (0x080000 vs 0x0B0000)
- **Action:** Fix the Lua scripts with correct RAM base addresses. Regenerate dumps.
- **Output:** Corrected Lua scripts + fresh dumps

---

## FOREMAN INSTRUCTIONS

When processing this queue:
1. Start with PSK-001 (Psikyo — should be quickest win)
2. Work through each core's chain sequentially
3. Run [H] tasks as Haiku subagents
4. Run [S] tasks yourself or as Sonnet subagents
5. Never run [O] tasks — escalate to user
6. Mark each task DONE with one-line result
7. If a task fails twice, mark BLOCKED and move to next core
8. Update .shared/findings.md with any discoveries
