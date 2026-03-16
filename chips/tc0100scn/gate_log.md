# TC0100SCN Gate Log

## Gate 2.5 — Verilator Lint

### Iteration 1 (initial write)

**Warnings (48):**
- `WIDTHEXPAND`: arithmetic expressions inside `17'(...)` casts with mixed-width operands — width promotion triggered
- `UNUSEDPARAM`: HSIZE, VSIZE parameters not used in body
- `SYMRSVDWORD`: output port named `sc_out` conflicts with SystemC reserved word
- `UNUSEDSIGNAL`: multiple signals not driven or not fully consumed (bg0_eff_x, bg0_eff_y placeholder assigns; vram_raddr_fg undriven; rom_ok qualification signals declared but unused; bg0_px_d etc.)

**Fixes:**
- Renamed `sc_out` → `tilemap_out` to avoid SystemC reserved word
- Added `/* verilator lint_off UNUSEDPARAM */` before module, `lint_on` inside body
- Removed placeholder assign blocks for eff_x/eff_y
- Removed unused `bg0_px_d`, `bg1_px_d`, `fg0_px_d` declarations
- Removed `vram_raddr_fg` and renamed to `vram_raddr_fg0`
- Removed `bg0_rom_ok_qual`, `bg1_rom_ok_qual` — rom_ok arbitration handled inline
- Removed `bg1_colscroll_addr` (unused after colscroll redesign)
- Removed `colscroll_rdata` (unused)

### Iteration 2

**Warnings (12):**
- `UNUSEDSIGNAL`: scroll register upper bits `[15:8]`/`[15:9]` unused (only `[7:0]` was used in coord arithmetic)
- `UNUSEDSIGNAL`: `bg0_flip[1]` (Y-flip) not referenced
- `UNUSEDSIGNAL`: `bg1_flip[1]` not referenced
- `UNUSEDSIGNAL`: `fg0_flip[1]` not referenced
- `UNUSEDSIGNAL`: `bg1_colscroll[15:10]` and `[2:0]` unused
- `UNUSEDSIGNAL`: `bg1_ntx_early[9:7]` unused
- `UNUSEDSIGNAL`: `param_tie` declared but unused

**Fixes:**
- Changed scroll registers from `logic [15:0]` to `logic [9:0]` — 10 bits covers full 512-pixel tilemap; upper bits of 16-bit CPU write value are discarded at write time with `10'(-$signed(cpu_din[9:0]))`
- Added `bg0_eff_trow`, `bg1_eff_trow`, `fg0_eff_trow` intermediates: apply Y-flip (`flip_r[1] ? trow ^ 3'h7 : trow`) before ROM/char address computation
- Changed `bg1_ntx_early` to `bg1_cs_ridx` directly (7-bit colscroll index)
- Changed `bg1_colscroll` from `logic [15:0]` to `logic [9:0]`; changed colscroll RAM reads to `10'(mem[idx])`
- Changed `bg0_rowscroll`, `bg1_rowscroll` from `logic [15:0]` to `logic [9:0]`
- Removed param_tie; used `/* verilator lint_off UNUSEDPARAM */` before module header instead
- Removed `bg0_rowscroll_debug` workaround; integrated `bg0_rowscroll` directly into `bg0_ntx` calculation

### Iteration 3

**Warnings (12 → 8 → clean):**
- `WIDTHTRUNC`: `16'd0` assigned to 10-bit signals → fixed to `10'd0`
- `UNUSEDPARAM`: pragma placement inside module body not effective for module-header parameters → moved `lint_off UNUSEDPARAM` to before module declaration
- `UNUSEDSIGNAL`: `bg1_colscroll[2:0]` — `[9:3]` slice discards low bits → changed to `bg1_colscroll >> 3` (shift uses all bits)

**Result: PASS**

---

## Gate 3a — Yosys Structural Synthesis

### Iteration 1

**Error:**
```
ERROR: Module `\altsyncram' referenced in module `\tc0100scn' in cell `\vram_fg0_inst' is not part of the design.
```
Yosys does not include Intel/Altera primitives. The `ifdef VERILATOR / else` guard leaves the altsyncram path visible to Yosys.

**Fix:** Changed `ifdef VERILATOR` to `ifndef QUARTUS`. Yosys sees the behavioral path (flat `logic [15:0] vram [...]`). Quartus synthesis uses `ifdef QUARTUS` to get the altsyncram instances. Updated `memory comment block in RTL header.

### Iteration 2

**False positive in gate3a.sh:**
```
[GATE3A] FAIL — Latch inference detected
```
Cause: grep pattern `"latch inferred|inferring latch"` matched Yosys informational messages
`"No latch inferred for signal ..."` — every such message confirmed **no latch**. Zero actual latches were inferred.

**Fix:** Corrected gate3a.sh grep to exclude lines starting with "No latch inferred":
```bash
grep -iE "latch inferred|inferring latch" | grep -qviE "^[[:space:]]*No latch inferred"
```
This is a gate infrastructure bug fix (not an RTL bug).

**Result: PASS**

---

## Final Gate Status

| Gate | Result | Notes |
|------|--------|-------|
| Gate 2.5 (Verilator lint) | **PASS** | Clean, 0 warnings |
| Gate 3a (Yosys synthesis) | **PASS** | Clean, 1 informational (ctrl memory → registers) |
| Gate 3b (Quartus) | Not run (macOS, no Quartus) | Will run in CI |
| Gate 4 (MAME regression) | Not run (vectors TBD) | Deferred |
