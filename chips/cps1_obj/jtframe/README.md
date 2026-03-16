# CPS1 OBJ — jtframe Integration

## What's Here

`cps1_obj_adapter.sv` — Drop-in replacement for `jtcps1_obj.v` in jotego's CPS1 core.

Wraps our AI-generated `cps1_obj.sv` to match the `jtcps1_obj.v` interface exactly.

## How to Use

### Step 1: Copy files to jtcores CPS1 core

```bash
cp cps1_obj_adapter.sv  /path/to/jtcores/cores/cps1/hdl/
cp ../rtl/cps1_obj.sv   /path/to/jtcores/cores/cps1/hdl/
```

### Step 2: Replace jtcps1_obj in jtcps1_video.v

In `jtcores/cores/cps1/hdl/jtcps1_video.v`, find:
```verilog
jtcps1_obj u_obj(
```
Change to:
```verilog
cps1_obj_adapter u_obj(
```
All port connections stay the same — the interface is identical.

### Step 3: Add to build file list

In the core's `.qip` or Makefile/filelist, add before `jtcps1_obj.v`:
```
cps1_obj_adapter.sv
cps1_obj.sv
```
Remove or comment out `jtcps1_obj.v`, `jtcps1_obj_line_table.v`, and `jtcps1_obj_draw.v` —
our adapter replaces all three.

## Interface Differences vs jtcps1_obj.v

None — identical external ports. See `cps1_obj_adapter.sv` header for full translation details.

## What the Adapter Does

**OBJ RAM Loading (per frame, during VBLANK):**
1. Detects VBLANK start (vdump > 237 or vdump < 14)
2. Reads all 1024 words from jotego's DMA frame cache via `frame_addr`/`frame_data`
3. Writes each word to our chip's live OBJ RAM via `cpu_we`
4. Asserts `vblank_n=0` to our chip, triggering internal DMA → FES → SIB
5. Releases `vblank_n=1` when jotego's VBLANK ends

**Timing:**
- jotego VBLANK: ~38 lines × 512 = ~19,456 cycles at 48 MHz
- OBJ RAM load: 1,026 cycles (pipelined)
- Chip internal (at 48 MHz): ≤11,520 cycles worst case
- Margin: ~6,000+ cycles

**ROM Address Banking:**
- Instantiates `jtcps1_gfx_mappers` (same as original)
- Applies `mapped_addr[19:16] = (raw_addr[19:16] & mask) | offset`
- 1-cycle pipeline latency (same as jotego's original)

**Clock:**
- Our chip runs at 48 MHz (full master clock, not gated by pxl_cen)
- All internal processing completes 6× faster than 8 MHz design target
- Pixel output: repeats same value 6× per pixel; jotego's colmix only samples on pxl_cen

## Lint / Gate Pipeline Notes

The adapter is **not run through the chip gate pipeline** (which targets `chips/*/rtl/*.sv`).
It is integration glue that belongs in jotego's build.

When linting with `verilator -Wall` including `jtcps1_gfx_mappers.v`:
- `EOFNEWLINE`, `UNUSEDSIGNAL` warnings appear — these are pre-existing in jotego's file
- Our adapter itself is clean (no warnings in `cps1_obj_adapter.sv`)
- jotego's build system (Quartus + jtframe scripts) does not use Verilator -Wall

## Known Gaps

1. **`start` signal is not used.** Our chip derives all timing from hcount/vcount/hblank_n/vblank_n.
   jotego's `start` (line_start) triggers per-line rendering. Not needed for our architecture.

2. **`vrender` is not used.** Our chip uses vcount (= vdump) directly.
   Rendering targets vcount+1 internally.

3. **Gate 3b (Quartus CI) not yet run on adapter.** Run via GitHub Actions CI.

4. **Simulation not yet set up.** The adapter should be verified in a jtcores simulation
   environment before running on hardware.

## Validation Status

| Component      | Status                              |
|---------------|-------------------------------------|
| cps1_obj.sv   | Gate 1/2.5/3a PASS. Gate 4: 100%  |
| Tier-1 vectors | 88,000/88,000 PASS (40/40 tests)  |
| Tier-2 vectors | 24,064/24,064 PASS (Final Fight)  |
| Adapter        | Written; not yet simulated         |
| Gate 3b (CI)   | Pending push to GitHub             |
| Hardware test  | Pending jtcores build              |
