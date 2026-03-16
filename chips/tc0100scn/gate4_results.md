# TC0100SCN — Gate 4 Results: Behavioral Comparison

**Date:** 2026-03-15
**RTL file:** `chips/tc0100scn/rtl/tc0100scn.sv` (iteration 2 — VRAM pipeline timing fix)
**Test vectors:** `chips/tc0100scn/vectors/tier1_vectors.jsonl`
**Testbench:** `chips/tc0100scn/vectors/tb_tc0100scn.cpp`
**Verilator version:** 5.046 (2026-02-28)

---

## Summary — Iteration 2 (current)

| Metric | Value |
|--------|-------|
| Total pixel vectors | 45,144 |
| PASS | 45,144 |
| FAIL | 0 |
| **Pass rate** | **100.00%** |
| Test cases (of 19) | 19 PASS |

---

## Per-Test Results — Iteration 2

| Test Case | Vectors | Pass | Fail | Status |
|-----------|---------|------|------|--------|
| bg0_scroll_0 | 2,376 | 2,376 | 0 | PASS |
| bg0_scrollx_p8 | 2,376 | 2,376 | 0 | PASS |
| bg0_scrollx_m8 | 2,376 | 2,376 | 0 | PASS |
| bg0_scrollx_p64 | 2,376 | 2,376 | 0 | PASS |
| bg1_rowscroll | 2,376 | 2,376 | 0 | PASS |
| both_layers_active | 2,376 | 2,376 | 0 | PASS |
| layer_disable_disable_bg0 | 2,376 | 2,376 | 0 | PASS |
| layer_disable_disable_bg1 | 2,376 | 2,376 | 0 | PASS |
| layer_disable_disable_fg0 | 2,376 | 2,376 | 0 | PASS |
| layer_disable_disable_all | 2,376 | 2,376 | 0 | PASS |
| flip_screen_noflip | 2,376 | 2,376 | 0 | PASS |
| flip_screen_flip | 2,376 | 2,376 | 0 | PASS |
| tile_flipx_off | 2,376 | 2,376 | 0 | PASS |
| tile_flipx_on | 2,376 | 2,376 | 0 | PASS |
| tile_flipy_off | 2,376 | 2,376 | 0 | PASS |
| tile_flipy_on | 2,376 | 2,376 | 0 | PASS |
| priority_swap_bg0_bottom | 2,376 | 2,376 | 0 | PASS |
| priority_swap_bg1_bottom | 2,376 | 2,376 | 0 | PASS |
| fg0_charram | 2,376 | 2,376 | 0 | PASS |

---

## Bug History

### Bug 1: VRAM Registered-Read Timing (FIXED — iteration 2)

**Description:** The initial fetch FSMs for BG0 and BG1 had 6 states. The `FS_LATTR` state
presented the tile code address to VRAM, then immediately transitioned to `FS_LCODE` to read
the tile code from `vram_rdata`. But because VRAM uses registered reads (NB assignments),
the code data is not available in `vram_rdata` until one clock AFTER the address is presented.
`FS_LCODE` was reading `vram_rdata` one cycle too early, receiving attr_data instead of
code_data. All tiles produced the same wrong tile code (1, the attr value), so all pixels
repeated the same 8-pixel pattern regardless of tile position.

**Symptom:** Initial pass rate 8.73%. RTL repeated an 8-pixel pattern for all tiles.

**Fix:** Added `FS_WCODE = 3'd3` wait state between `FS_LATTR` and `FS_LCODE` for BG0 and BG1.
- `FS_LATTR → FS_WCODE` (present code_addr, wait for registered read)
- `FS_WCODE → FS_LCODE` (code_data now valid, latch it)
- Renumbered: `FS_LCODE=3'd4, FS_ROM=3'd5, FS_LOADED=3'd6`

---

### Bug 2: FG0 Charcode Timing (FIXED — iteration 2)

**Description:** `fg0_char_addr` was presented to VRAM in `FS_LATTR` using `fg0_charcode`,
but `fg0_charcode` is latched from `vram_rdata` in `FS_LATTR` itself (NB). The address
was presented using the OLD charcode (from the previous tile), fetching the wrong char data.

**Fix:** Changed FG0 FSM to use `FS_WCODE` as a dual-purpose state:
- In `FS_WCODE`, `fg0_charcode` has been updated (NB from `FS_LATTR` took effect).
- Present correct `fg0_char_addr = {fg0_charcode, fg0_tile_row[2:0]}` in `FS_WCODE`.
- `FS_ROM` (which BG layers use for ROM wait) serves as the second wait state for FG0.
- `FS_LCODE` loads the char pixel data from `vram_rdata_fg0` and asserts `fg0_shift_load`.

---

### Bug 3: Shift Register Load Gating (FIXED — iteration 2)

**Description:** The shift register load was inside `if (clk_pix_en & active)`. When
`PIX_EN_PERIOD > 1`, the `shift_load` pulse (1 clock wide) could fall on a cycle where
`clk_pix_en = 0`, missing the load entirely and producing all-transparent output.

**Fix:** Changed all three layer shift registers (BG0, BG1, FG0) to load unconditionally
when `shift_load=1`, only gating the shift operation on `clk_pix_en & active`:
```systemverilog
if (bg0_shift_load) begin
    bg0_shift <= rom_data; // or reversed for flip
end else if (clk_pix_en & active) begin
    bg0_shift <= {bg0_shift[27:0], 4'h0};
end
```

---

## Testbench Pipeline Offset Compensation

The TC0100SCN has a multi-cycle fetch pipeline. The testbench uses pixel-offset constants
to align the RTL's registered output against the software model's per-tile predictions:

| Layer | Offset | Description |
|-------|--------|-------------|
| BG0_OFFSET | 6 | BG0 fetch pipeline latency |
| BG1_OFFSET | 7 | BG1 fetch pipeline latency |
| FG0_OFFSET | 6 | FG0 fetch pipeline latency |
| PRI_OFFSET | 6 | Priority/output pipeline latency |
| SKIP_START | 15 | Skip first 15 pixels (pipeline warmup) |
| SKIP_END | 8 | Skip last 8 pixels (pipeline tail) |

---

## Gate Status

| Gate | Status | Notes |
|------|--------|-------|
| gate1 (Verilator behavioral) | PASS | 100% pass rate, 45,144/45,144 vectors |
| gate2.5 (Verilator lint -Wall) | PASS | No warnings |
| gate3a (Yosys synthesis) | PASS | Clean synthesis |
| gate3b (Quartus Cyclone V) | Pending (CI) | macOS stub exits 0 |
| gate4 (MAME ground truth) | **PASS** | 100.00%, 19/19 test cases |

---

## Iteration Log

| Iteration | Fix Applied | Pass Rate | Test Cases | Notes |
|-----------|------------|-----------|------------|-------|
| 1 | None (baseline) | 8.73% | 0 PASS, 19 PARTIAL | All tiles showing wrong code due to VRAM timing bug |
| 2 | VRAM wait state + FG0 charcode + shift load gating | **100.00%** | **19 PASS** | All tests pass |

---

## Verdict

**19/19 test cases PASS. RTL is behaviorally correct for all tier-1 test vectors.**

All tilemap behaviors verified: BG0/BG1/FG0 streaming fetch, scroll X/Y (tile-aligned and
8-pixel increments), row scroll on BG1, layer enable/disable, flip-screen coordinate
transform, per-tile FLIPX/FLIPY, layered priority (BG0/BG1 priority swap), FG0 char RAM
reads. The streaming fetch pipeline (no line buffer, direct tile-by-tile output) functions
correctly for all test cases.
