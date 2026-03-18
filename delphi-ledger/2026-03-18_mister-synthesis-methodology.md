# Delphi Consultation: MiSTer Core Synthesis Methodology
**Date**: 2026-03-18
**Mode**: TECHNICAL
**Problem**: After 24 hours of iterative one-bug-per-synthesis-run failures on Quartus 17.0 Cyclone V cores (Taito, Toaplan, Kaneko, NMK, Psikyo), what is the most robust path forward?

**Three sub-questions:**
1. What pre-synthesis checklist/methodology catches issues before running Quartus?
2. Should chips be validated one-at-a-time (standalone harnesses) before integration?
3. Should we clone a mature jotego core, implement it ourselves, diff against jotego's, and use it as calibration?

---

## Panel

| Expert | Domain | Stance | Model |
|--------|--------|--------|-------|
| Expert 1 | FPGA synthesis methodology | Argue from correctness and tool compliance | Opus |
| Expert 2 | RTL architecture and jotego patterns | Argue from verified working community patterns | Sonnet |
| Expert 3 | Engineering workflow and operational reality | Argue from feedback loop speed and maintainability | Sonnet |

---

## Expert 1: Synthesis Methodology (Opus)

### Q1: Pre-Synthesis Static Checks

**Core principle**: Quartus 17.0's RAM inference engine has a narrow recognition grammar (~12 canonical patterns from Handbook Vol 1, Chapter 12). Anything outside it either falls back to ALM registers silently or fails MAP. Stop relying on inference for anything complex.

**Six grep-level patterns to check before every synthesis run:**

1. **Bit-slice writes to inferred RAM**: `arr[addr][N:M] <=` on any array > ~64 entries → must convert to altsyncram SINGLE_PORT with byteena_a. The `(* ramstyle *)` attribute is a *hint*, not a guarantee — for byte-enable specifically, it is ignored.

2. **byteena_b width mismatch**: In DUAL_PORT altsyncram, read-only port B's `byteena_b` formal width is 1 bit. Connecting 2-bit or 4-bit values triggers Warning 12020. Always `1'b1` for read-only port B.

3. **Arrays inside reset clauses**: M10K blocks have no hardware reset. If RTL implies synchronous/async clear of a RAM array, Quartus falls back to flip-flops. For 4K×16 = 65,536 FFs → instant ALM exhaustion.

4. **Mixed read-before-write / write-before-read in same block**: M10K supports either "old data" or "new data" mode, but inference determines this from code structure. Ambiguous ordering → Warning 10858 or register fallback. Use explicit `read_during_write_mode_port_a = "OLD_DATA"` or `"NEW_DATA_NO_NBE_READ"`.

5. **Unregistered RAM output feeding combinational logic**: M10K has mandatory output register for timing closure. Combinational use of RAM output in same cycle → either extra latency you didn't account for, or ALM routing path → timing violation (root cause of -17ns and -42ns failures).

6. **Modules without clock enable ports**: Jotego threads `cen` through every module. If your modules don't have `cen` ports, you're structurally divergent from the pattern that synthesizes reliably.

**Dangerous altsyncram parameter combinations (Quartus 17.0):**

| Parameter | Dangerous Value | Consequence |
|-----------|----------------|-------------|
| `intended_device_family` | Omitted | Falls back to generic, inefficient M10K use |
| `read_during_write_mode_port_a` | `"DONT_CARE"` | Non-deterministic per synthesis run |
| `byteena_a` width | Not matching `width_a / 8` | Truncation or MAP failure |
| `numwords_a` × `width_a` | Not matching actual depth × width | Silent address aliasing |
| `clock_enable_input_a` | `"BYPASS"` with enable logic | Enable logic ignored, RAM writes every cycle |
| `init_file` | Path >64 chars or with spaces | Silently ignored, RAM zeros |
| `width_byteena_a` | Inconsistent with `width_a` | Warning 12020 at best |

**jotego code review checklist (patterns he always uses):**

1. Every RAM is explicit — `jtframe_ram`, `jtframe_dual_ram`, or direct altsyncram. Never behavioral inference for anything > ~32 entries.
2. Every module has a `cen` clock enable port threaded through.
3. No combinational RAM reads — every RAM output registered before use.
4. `localparam` for FSM states, not `enum` (Quartus 17.0 enum-to-binary encoding not always optimal).
5. No `always_comb` blocks with side effects on RAM — all RAM in `always_ff`.
6. Explicit width on every signal — no implicit 32-bit integers.

### Q2: Standalone Chip Synthesis

**Yes, absolutely — but understand exactly what it buys and what it misses.**

**What it buys:**
- RAM inference/instantiation correctness (bugs #1, #2) — entirely local to module
- Accurate per-chip resource footprint (essential for ALM overflow planning)
- Internal timing floor (if chip fails timing alone, integration will only be worse)
- Fast iteration: 5-15 min runs = 4-8 fix-synthesize-verify cycles/hour

**What it misses:**
- Cross-module signal timing (critical path often crosses module boundaries)
- Resource contention with SDRAM controller after P&R placement
- Clock domain crossing issues involving HPS/hps_io
- I/O standard conflicts

**Standalone wrapper structure** (expose real chip interface, no logic added, pure wiring):
```systemverilog
module chip_synth_harness (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] cpu_din,
    output logic [15:0] cpu_dout,
    input  logic [23:1] cpu_addr,
    input  logic        cpu_rw,
    // ... real chip interface ...
    output logic  [7:0] red, green, blue,
    output logic        hsync, vsync, hblank, vblank
);
    chip_under_test dut ( .* );
endmodule
```

With SDC: `create_clock -period 10.000 [get_ports clk]` + `set_input_delay`/`set_output_delay` 3ns on all chip I/O to approximate real integration timing environment.

**Integration sequence:**
1. Synthesize each chip standalone — fix all resource and timing issues
2. Synthesize CPUs standalone — know their ALM footprint
3. Check arithmetic: if chips + CPUs + framework > 38K ALMs (leaving 10% margin), redesign before integrating
4. Full integration synthesis — expect only cross-module timing issues, not RAM or resource surprises

### Q3: Diff Against jotego

**The single highest-value activity you can do. Do it systematically.**

**Signal differences (real bugs):**
- You use `jtframe_dual_ram` → he uses behavioral `logic [15:0] mem[0:4095]` → he's wrong, you're right (or vice versa — always his pattern wins)
- Pipeline depth difference → maps directly to whether M10K output registers are being used
- Clock enable threading — if his has `cen` on every module and yours doesn't → architectural divergence
- Resource sharing (N× RAM instances where he uses 1 time-multiplexed instance → M10K exhaustion path)
- Missing multicycle SDC constraints for CPU-rate paths
- Frame buffer where he uses line buffer → 10-20× M10K difference

**Noise differences (style only):**
- Naming conventions
- Module hierarchy granularity (unless it crosses RAM inference boundaries)
- Comment density
- Specific LUT/constant values (game-specific data)

**Meta-insight**: The diff reveals *convergent evolution under selection pressure*. Jotego has been selected by thousands of synthesis runs. The diff reveals which of your patterns haven't been tested yet — and those patterns statistically contain bugs.

---

## Expert 2: RTL Architecture (Sonnet)

### Q1: Patterns Jotego Would Never Write

| Anti-pattern | jotego's substitution |
|---|---|
| Byte-slice writes `arr[addr][7:0] <=` | Single altsyncram with `BYTEENA_A`, full-word writes, masking internal to primitive |
| Wide bus combinational decode → async RAM select | Registered decode: latch address on clock edge, decode stable for full cycle, registered consumer |
| 3D arrays `logic [7:0] t [15:0][15:0]` | Flat 1D `logic [7:0] t [255:0]` with explicit index arithmetic `row*16 + col` |
| Async combinational sprite lookup feeding pixel output same cycle | 2-cycle pipeline: cycle 0 = address to BRAM, cycle 1 = registered output at consumer |
| Multi-cycle paths without SDC constraints | Explicit `set_multicycle_path -from [get_registers {*cpu_en*}] -setup 2` for every subsystem at divided rate |
| Direct wire across clock domains | Two-flop synchronizer or handshake FIFO; jtframe enforces this structurally |

**Key**: Jotego uses a single PLL with a clock-enable hierarchy. Any design with multiple PLLs or gated clocks instead of clock enables is structurally divergent in a way that creates CDC bugs that pass simulation and fail on hardware.

### Q2: System-Level vs. Chip-at-a-Time

**The false confidence problem is real and specific.** A sprite engine synthesizes clean at 96 MHz in isolation. Integrated, Quartus places the sprite BRAM adjacent to scroll engine logic to minimize wire length for a *different* critical path. The sprite-to-mixer path is now 1.2ns longer. Timing fails. Neither chip had a bug — integration created the violation.

**Jotego's actual approach (inferred from published cores + SDC):**
- Phase 1: Functional simulation per chip (Icarus/Verilator, seconds). 90% of functional bugs.
- Phase 2: System-level synthesis with a *representative* top (real jtframe-connected top, SDRAM controller, HDMI, all subsystems at final clock enables) from *day one* at target frequency with full SDC.
- Phase 3: Per-chip isolation only when debugging a specific known path violation.

**Resolution**: Jotego builds integration-first because he has 10 years of battle-tested RTL. For a project without that track record, chip-at-a-time is correct *precisely because* each chip hasn't been validated yet. Once a chip's pattern library is proven, shift to integration-first.

### Q3: Clone-and-Diff — What's Signal vs. Noise

**Signal (real structural problems):**
- Your top-level has >1 PLL instantiation → wrong
- SDRAM controller burst length or latency model differs from jts16 → needs his exact SDC constraint work
- Frame buffer where jts16 uses line buffer → 10-20× M10K budget difference
- Color mixer has combinational path palette RAM → pixel output spanning > 1 registered stage → timing fails above ~60 MHz
- SDC file missing multicycle constraints for CPU-rate paths

**Noise (style only):** Naming, FSM encoding choices (Quartus chooses anyway), `always_ff` vs `always @(posedge clk)`, module hierarchy depth

**The concrete calibration value**: If your implementation uses 30% more M10K than jts16 for equivalent functionality, the delta is structural — frame buffer vs line buffer, byte-slice vs wide-word RAM, 3D arrays. The diff pinpoints exactly where. This calibration, run once, is worth more than any static analysis because it's ground truth against shipped hardware-validated RTL.

---

## Expert 3: Engineering Workflow (Sonnet)

### Q1: Static Check Suite

**Tier 1 — grep patterns (10 seconds, catches known-bad patterns):**

```bash
#!/bin/bash
# check_rtl.sh — run before any synthesis

# Bug 1: byte-slice writes to arrays
echo "=== Byte-slice writes ==="
grep -rn '\w\+\[.*\]\[.*:.*\] *<=' chips/*/rtl/*.sv

# Bug 2: byteena_b not 1'b1 in DUAL_PORT altsyncram
echo "=== byteena_b width ==="
grep -n 'byteena_b' chips/*/rtl/*.sv | grep -v "1'b1"

# Bug 5: 3D arrays
echo "=== 3D arrays ==="
grep -rn 'logic\s*\[.*\]\s*\w\+\s*\[.*\]\s*\[.*\]' chips/*/rtl/*.sv

# Loop-reset explosion
echo "=== Loop reset ==="
grep -B2 -A5 'for.*i.*reset\|for.*i.*<=' chips/*/rtl/*.sv | grep -E 'for|reset|clear'

# Missing clock enable ports (structural divergence from jtframe pattern)
echo "=== Modules without cen port ==="
for f in chips/*/rtl/*.sv; do
  grep -q 'input.*cen' "$f" || echo "MISSING cen: $f"
done
```

**Tier 2 — Python estimator (30 seconds, resource predictions):**
- Parse all `logic [W:0] name [D:0]` declarations → estimate M10K/MLAB usage
- Parse all altsyncram instances → validate parameter consistency (byteena width, depth×width match)
- Rough ALM estimate: count unique flop declarations + case arms + N-bit adders
- Compare against device limits (553 M10K, 397 MLAB, 41,910 ALMs)

**What it catches vs. misses:**

| Bug type | grep | Python | Synthesis |
|---|---|---|---|
| Byte-slice MLAB write | ✓ | ✓ | ✓ |
| byteena width mismatch | Partial | ✓ | ✓ |
| 3D arrays | ✓ | ✓ | ✓ |
| Loop reset explosion | Partial | ✓ | ✓ |
| ALM overflow (2×+) | ✗ | Rough | ✓ |
| Timing violations | ✗ | ✗ | ✓ |

**Hard limit**: Timing violations require P&R. Static checks buy the first 60% of bugs.

### Q2: Chip-at-a-Time Velocity

**The velocity difference is not marginal — it's an order of magnitude.**

Current workflow: implement N chips → integrate → synthesize → discover M bugs → fix one → re-synthesize. Per-bug cost: 30-90 min, serialized.

Chip-at-a-time: implement chip → standalone synthesis (5-15 min) → fix until clean → integrate. Per-bug cost: 5-15 min, parallelizable.

**Retrospective on the 5 bugs:**
- Bug 1 (byte-slice MLAB): chip-level, caught in ~10 min instead of ~45 min
- Bug 2 (byteena width, 21 instances): chip-level, caught in ~10 min instead of ~30 min
- Bug 3 (ALM overflow): chip-level resource check, caught in ~10 min instead of ~60 min
- Bug 4 (timing violations): requires P&R regardless, but isolation reduces iteration to 5-15 min
- Bug 5 (MLAB capacity GP9001): chip-level capacity estimate, caught before synthesis

**Estimate**: 4-5 hours under current workflow → 45-90 minutes under chip-at-a-time + static checks.

**Operational mandates:**
- Every new chip gets a standalone harness at creation time (20 min, pays back on first debug)
- CI: chip-level synthesis on chip-path changes (5-15 min each, parallelized); integration synthesis on main-branch merge only
- No chip is "done" without a passing standalone synthesis harness

### Q3: Clone-and-Diff Calibration

**Do it once, bounded to 4 hours, produce a specific deliverable: the pattern ledger.**

**Workflow:**
1. Pick one small chip (tile fetcher or sprite table chip — complex enough to be interesting, small enough to diff manually)
2. Implement from scratch (datasheet + MAME source only, no peeking at jts16)
3. Standalone synthesis — record ALM, M10K, MLAB, worst timing slack
4. Clone jts16, find equivalent module, wrap in harness, synthesize — record same metrics
5. Structural diff (not line diff): extract memory declarations + access patterns, always block sensitivity lists, parameter-driven widths, reset strategies
6. For each pattern difference: note which version has better synthesis metrics

**Artifacts produced:**
- **Pattern ledger** (markdown table): our pattern / jotego pattern / synthesis delta / recommendation
- **New linting rules**: every ledger row where jotego is strictly better → new rule in `check_rtl.sh`
- **Memory inference template**: if his RAM style consistently wins → copy-paste template with parameter hooks

**Scope discipline**: One chip, one diff, 4 hours maximum. If no populated ledger at hour 4, stop. The value is the ledger, not the exploration.

---

## Panel Agreement

All three experts converged on these points without prompting:

1. **Build `check_rtl.sh` immediately.** Catches the bugs we've been hitting in 10 seconds instead of 30-90 minutes. Highest single ROI item. Build it before the next synthesis run.

2. **Standalone harnesses for every chip, mandated at creation.** Not optional, not retrofitted only when bugs appear. Every chip without a harness is not done.

3. **Diff against jotego is worth doing — once, bounded, with a specific deliverable.** The ledger then drives new linting rules. Not open-ended exploration.

4. **Explicit altsyncram for every RAM > ~32 entries, no behavioral inference exceptions.** The `(* ramstyle *)` attribute is a hint, not a guarantee. Stop relying on it.

## Panel Disagreement

**Expert 2 vs. Experts 1 & 3 on workflow sequencing:**

Expert 2 argues jotego builds integration-first (system-level synthesis from day one). Experts 1 and 3 argue chip-at-a-time is essential.

**Resolution**: Both are correct in their context. Jotego does integration-first *because* he has a proven RTL pattern library (jtframe) and 10 years of synthesis calibration. For this project, chip-at-a-time is correct *because* the pattern library isn't proven yet. Once `check_rtl.sh` + the calibration diff have established a reliable pattern library, shift toward integration-first for new systems.

---

## Recommended Path Forward

### Immediate (next session)

1. **Write `check_rtl.sh`** — 6 grep patterns + Python estimator (2-3 hours). Gate all future synthesis on it passing.

2. **Create standalone harnesses for remaining chips** — tc0630fdp, tc0480scp, tc0370mso already done. Need: taito_b, taito_f3, taito_z, taito_x, toaplan_v2, nmk_arcade, psikyo_arcade, kaneko_arcade (20 min each, delegate to agents in parallel).

### Near-term (1-2 sessions)

3. **Run the jts16 calibration diff** — pick one chip (recommend: jts16 scroll layer), implement from scratch, diff, produce pattern ledger, fold ledger into `check_rtl.sh`.

4. **Thread clock enables through all chip modules** — any module without a `cen` port is structurally divergent from jtframe. This is both a correctness requirement and a timing requirement.

### Structural (architecture)

5. **Register every RAM output before use** — eliminates the root cause of timing violations. Non-negotiable for closure above ~60 MHz on Cyclone V.

6. **Adopt line buffers, not frame buffers, for sprite rendering** — 10-20× M10K savings. Critical for chips approaching M10K budget.

---

## Open Questions for User

1. **Which jotego chip to use for the calibration diff?** Recommend: a scroll/tilemap chip from jts16 (System 16 hardware). Alternatives: jtcps1 scroll layer, jtoutrun road chip.

2. **Do the calibration diff before or after finishing current synthesis queue?** Expert 3 says before — it informs all future synthesis work. Expert 1 says the static check script is more urgent. **Recommendation: build `check_rtl.sh` first (1 session), then do the calibration diff (1 session).**

3. **PAT `workflow` scope** — `chip_synthesis.yml` CI workflow is blocked pending this. User action required.

4. **Taito Z ALM overflow** — 2× fx68k CPUs = ~18K ALMs before any GPU logic. Options: (a) replace one fx68k with a lighter 68K core, (b) accept that Taito Z needs a separate build config with HDMI/audio disabled, (c) defer Taito Z. What's the priority?
