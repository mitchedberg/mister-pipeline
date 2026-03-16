# CPS1 OBJ Blind Test — Gate Run Log

Generated: 2026-03-15
RTL file: `chips/cps1_obj/rtl/cps1_obj.sv`

---

## Gate 2.5 (Verilator Lint) — Iterations

### Iteration 1 — FAIL (13 warnings)

**Warnings encountered:**

| Warning | Line | Description |
|---------|------|-------------|
| WIDTHTRUNC | 394 | `9'd512` overflows 9-bit literal — used in flip_screen coordinate arithmetic |
| UNUSEDPARAM | 31 | `MAX_SPRITES` parameter not referenced in any logic |
| UNUSEDSIGNAL | 195 | `last_entry` declared but never read |
| UNUSEDSIGNAL | 202 | `tile_x` declared but never read (was overridden by `pix_x_base`) |
| UNUSEDSIGNAL | 203 | `tile_y_base` declared but never read |
| UNUSEDSIGNAL | 230 | `rom_addr_r` duplicate of `rom_addr`, never read |
| UNUSEDSIGNAL | 231 | `rom_half_r` duplicate of `rom_half`, never read |
| UNUSEDSIGNAL | 419 | `col_idx[3]` MSB unused (only bits 2:0 used in code calculation) |
| UNUSEDSIGNAL | 425 | `code_col[4]` MSB unused |
| UNUSEDSIGNAL | 429 | `dy` declared but never driven or used |
| UNUSEDSIGNAL | 430 | `vsub_raw` declared but never driven or used |
| UNUSEDSIGNAL | 465 | `tyend10` declared but never used |
| UNUSEDSIGNAL | 555 | `pi` declared but never driven or used |

**Root causes:**
- Width issue: used `9'd512` (overflows 9-bit container) in flip_screen transform; needed 10-bit subtraction
- Many leftover intermediate signals from `begin..end` blocks with nested `logic` declarations
- Copied `rom_addr`/`rom_half` into shadow registers that were then unused
- `tile_x` / `tile_y_base` were computed separately from `pix_x_base`
- Prototype code artifacts: `dy`, `vsub_raw`, `pi`, `tyend10` were placeholders never wired

**Fix applied:** Complete rewrite of the sprite scan state machine. Eliminated all inner `begin..end` logic declarations in favor of module-level `always_comb` signals (`eff_col`, `eff_row`, `cur_tile_x`, `cur_tile_y`, `cur_tile_vis`, `cur_vsub`, `cur_tile_code`). Removed all redundant/unused signals. Fixed flip_screen arithmetic to use 10-bit operands with explicit truncation.

### Iteration 2 — FAIL (3 warnings)

**Warnings encountered:**

| Warning | Line | Description |
|---------|------|-------------|
| UNUSEDPARAM | 63 | `SPR_IDX_W` localparam never used in any width declaration |
| UNUSEDSIGNAL | 216 | `last_valid` assigned in 3 places but never read |
| UNUSEDSIGNAL | 261 | `eff_col[3]` MSB unused (tile code column only used bits 2:0) |

**Root causes:**
- `SPR_IDX_W` was a documentation-only constant not actually used for any port width
- `last_valid` was correctly tracking the last valid entry but `scan_idx` was set directly from `find_idx` computations so `last_valid` was write-only
- `eff_col` was 4-bit but tile code nibble addition `base_nibble + {1'b0, eff_col[2:0]}` only consumed 3 bits of it

**Fixes applied:**
1. Removed `SPR_IDX_W` localparam
2. Removed `last_valid` declaration and all 3 write assignments
3. Changed tile code column addition to use all 4 bits: `base_nibble + eff_col` (both 4-bit, result wraps in nibble naturally)

### Iteration 3 — PASS

```
[GATE2.5] Verilator lint: clean
[GATE2.5] Async reset check: OK: 1 async-reset always_ff block(s) found — all match synchronizer pattern
[GATE2.5] default_nettype: OK
[GATE2.5] reg/wire check: OK
[GATE2.5] Latch check: OK: 12 always_comb block(s) checked — all case statements have default
[GATE2.5] PASS — all lint checks clean
```

**Gate 2.5: PASS in 3 iterations**

---

## Gate 3a (Yosys Synthesis) — Iterations

### Iteration 1 — PASS (first attempt, run after gate 2.5 pass)

Yosys 0.63 synthesized the module without errors or warnings.

Key stats from Yosys stat output:
- 3 memories (obj_ram_live, obj_ram_shadow, linebuf arrays)
- 41984 memory bits total
- 465 cells synthesized
- No latches inferred (confirmed: 14 "No latch inferred" messages, all combinational signals)
- No multi-driver signals detected
- No hierarchy errors

```
[GATE3A] PASS — Yosys synthesis and check clean
```

**Gate 3a: PASS in 1 iteration**

---

## Gate 3b (Quartus) — CI Only

Gate 3b requires Quartus Lite on Linux. Runs in GitHub Actions CI only. Not blocked on macOS.
Expected to trigger on push to master.

---

## Summary

| Gate | Result | Iterations |
|------|--------|------------|
| Gate 2.5 (Verilator lint) | PASS | 3 |
| Gate 3a (Yosys) | PASS | 1 |
| Gate 3b (Quartus) | CI pending | — |

Total warnings encountered: 16
Total fixes applied: 8 (grouped into 2 revision passes)
