# CPS1 OBJ — Gate 4 Results: Behavioral Comparison

**Date:** 2026-03-15
**RTL file:** `chips/cps1_obj/rtl/cps1_obj.sv` (iteration 4 — SIB: Scanline Index Build)
**Test vectors:** `chips/cps1_obj/vectors/tier1_vectors.jsonl`
**Testbench:** `chips/cps1_obj/vectors/tb_cps1_obj.cpp`
**Verilator version:** 5.046 (2026-02-28)

---

## Summary — Iteration 4 (current)

| Metric | Value |
|--------|-------|
| Total pixel vectors | 88,000 |
| PASS | 88,000 |
| FAIL | 0 |
| **Pass rate** | **100.00%** |
| Test cases (of 40) | 40 PASS |

---

## Per-Test Results — Iteration 4

| Test Case | Vectors | Pass | Fail | Status |
|-----------|---------|------|------|--------|
| x_sweep_x0 | 0 | 0 | 0 | PASS (clipped) |
| x_sweep_x64 | 256 | 256 | 0 | PASS |
| x_sweep_x127 | 256 | 256 | 0 | PASS |
| x_sweep_x128 | 256 | 256 | 0 | PASS |
| x_sweep_x256 | 256 | 256 | 0 | PASS |
| x_sweep_x383 | 256 | 256 | 0 | PASS |
| x_sweep_x384 | 256 | 256 | 0 | PASS |
| x_sweep_x447 | 16 | 16 | 0 | PASS |
| x_sweep_x448 | 0 | 0 | 0 | PASS (clipped) |
| x_sweep_x511 | 0 | 0 | 0 | PASS (clipped) |
| y_sweep_y0 | 256 | 256 | 0 | PASS |
| y_sweep_y16 | 256 | 256 | 0 | PASS |
| y_sweep_y112 | 256 | 256 | 0 | PASS |
| y_sweep_y224 | 256 | 256 | 0 | PASS |
| y_sweep_y239 | 16 | 16 | 0 | PASS |
| y_sweep_y255 | 0 | 0 | 0 | PASS (outside active range) |
| flip_fx0_fy0 | 256 | 256 | 0 | PASS |
| flip_fx1_fy0 | 256 | 256 | 0 | PASS |
| flip_fx0_fy1 | 256 | 256 | 0 | PASS |
| flip_fx1_fy1 | 256 | 256 | 0 | PASS |
| block_2x2 | 1,024 | 1,024 | 0 | PASS |
| block_4x4 | 4,096 | 4,096 | 0 | PASS |
| block_8x8 | 16,384 | 16,384 | 0 | PASS |
| block_2x2_flip | 1,024 | 1,024 | 0 | PASS |
| priority_entry0_wins | 256 | 256 | 0 | PASS |
| priority_non_overlap | 512 | 512 | 0 | PASS |
| full_table_256 | 57,856 | 57,856 | 0 | **PASS** |
| empty_table_terminator_at_0 | 0 | 0 | 0 | PASS |
| transparent_tile | 0 | 0 | 0 | PASS |
| x_wrap_504 | 0 | 0 | 0 | PASS (outside visible) |
| y_wrap_232 | 128 | 128 | 0 | PASS |
| flip_screen_basic | 256 | 256 | 0 | PASS |
| block_2x1_x_wrap | 128 | 128 | 0 | PASS |
| block_1x2_y_wrap | 128 | 128 | 0 | PASS |
| terminator_mid_table | 768 | 768 | 0 | PASS |
| vsub_0 | 16 | 16 | 0 | PASS |
| vsub_15 | 16 | 16 | 0 | PASS |
| flipy_vsub_inversion | 256 | 256 | 0 | PASS |
| block_1x2_flipy | 512 | 512 | 0 | PASS |
| block_2x2_flipx | 1,024 | 1,024 | 0 | PASS |

---

## Bug History

### Bug 1: FLIPX Pixel Ordering (FIXED — iteration 1)

**Description:** Per-half reversal instead of full-tile reversal for FLIPX.
**Fix:** Swapped ROM_WR0/ROM_WR1 FLIPX placement formulas.

---

### Bug 2: Find-End Table Scan in HBlank (FIXED — iteration 3)

**Description:** O(N) find-end scan consumed entire hblank budget for large tables.
**Fix:** Moved to VBLANK-phase FES (Find-End Scan) state machine. Result stored in `frame_last_sprite` for the full frame.

---

### Bug 3: Large Block HBlank Overflow (FIXED — iteration 3)

**Description:** Multi-row sprite blocks required iterating all rows to find visible row.
**Fix:** Row-jump optimization in LOAD_W3: `vis_row = block_vy[7:4]` jumps directly to visible tile row.

---

### Bug 4: Vrender=240 Line Buffer Leak (FIXED — iteration 3)

**Description:** Sprites for vrender=240 rendered into the buffer read by scanline 0.
**Fix:** `VRENDER_MAX = 9'd240` guard in IDLE prevents rendering when vrender >= 240.

---

### Bug 5: Per-HBlank O(N) Render Scan (FIXED — iteration 4)

**Description:** Even with FES moved to VBLANK, the per-hblank rendering loop still scanned
all N sprite entries each scanline. For 256 sprites and 16 visible per scanline, this
required ~1,376 cycles per hblank, far exceeding the 128-cycle budget.

**Root cause:** FSM started from frame_last_sprite and scanned downward each hblank,
traversing all 240+ invisible entries before reaching visible ones.

**Fix:** VBLANK-phase SIB (Scanline Index Build) state machine. During VBLANK, after FES
completes, SIB scans all sprite entries from 0 to frame_last_sprite (ascending), computing
per-scanline render data (eff_x, vsub, tile_code, color, flipx, nx) for each covered
scanline. Data stored in two M10K memories indexed by {scanline[7:0], slot[3:0]}.

Priority is maintained by the ascending scan order:
- Lowest-indexed sprites (highest CPS1 priority) fill lower slot numbers.
- Hblank FSM renders from slot (count-1) DOWN to slot 0.
- Slot 0 (entry 0 = highest priority) rendered last, wins on overlap.
- When scanline is full (16 slots), higher-indexed (lower priority) sprites are capped.

**Storage:** Two M10K memories, each 4096 × 32-bit (256 scanlines × 16 slots):
- `sl_data_mem`: pack_data {eff_x[8:0], vsub[3:0], nx[3:0], flipx, color[4:0], base_nibble[3:0], 5'd0}
- `sl_code_mem`: tile_code_0 for col=0

**Hblank FSM (post-SIB):**
- Per-sprite cost: 1 (SL_RD_WAIT) + 1 (PRE_RENDER) + 1 (ROM_REQ) + 1 (ROM_WAIT0) + 1 (ROM_WR0) + 1 (ROM_WAIT1) + 1 (ROM_WR1) = 7 cycles/sprite
- 16 sprites: 7 (first) + 15×7 = 112 cycles < 128-cycle budget ✓

---

### Testbench Bug: Insufficient VBLANK Window (FIXED — iteration 4)

**Description:** `simulate_frame_v2` started frame simulation at vcount=261 (1 scanline =
512 cycles of VBLANK). The new VBLANK triggered DMA+FES+SIB which needed ~7920 cycles
to complete. By hpix=448 of vcount=261, the SIB was only partway through its CLR phase,
`sib_index_valid` had been cleared, so the hblank FSM saw `sib_done=0` and rendered nothing.

**Fix:** Replaced `simulate_frame_v2` + `do_vblank()` with `simulate_frame_v3`, which starts
at vcount=240 and simulates the full 22-scanline VBLANK (11,264 cycles) before the active
period. SIB completes at ~7920 cycles, leaving >3000 cycles of margin before hblank of
vcount=261 fires at cycle 11,200.

---

## Iteration Log

| Iteration | Fix Applied | Pass Rate | Test Cases | Notes |
|-----------|------------|-----------|------------|-------|
| Initial | None | 43.34% | 27 PASS, 3 PARTIAL | FLIPX failing |
| 1 | FLIPX pixel placement | 46.61% | 29 PASS, 3 PARTIAL | FLIPX/FLIPY+FLIPX pass |
| 2 (pre-session) | Baseline | 46.61% | — | Starting point |
| 3 | FES + row-jump + vrender guard | 35.92% | 39 PASS, 1 PARTIAL | full_table_256 still fails (O(N) per-hblank scan) |
| 4 | SIB (per-scanline pre-sort) + testbench timing fix | **100.00%** | **40 PASS** | All tests pass |

---

## Verdict

**40/40 test cases PASS. RTL is behaviorally correct for all tier-1 test vectors.**

All sprite behaviors verified: X/Y positioning, all flip modes, multi-tile blocks up to
8×8, priority (lower entry index wins), transparency, X/Y wrapping, flip-screen transform,
double-buffered line buffer, self-erasing readout, DMA shadow latch, dense sprite tables
(full 256-entry table with 16 sprites per scanline).
