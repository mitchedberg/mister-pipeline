# MiSTer Pipeline — Synthesis Guardrails

**READ THIS BEFORE TOUCHING ANY RTL OR RUNNING SYNTHESIS.**

Small wins beat ocean-boiling 10x. One chip at a time. Test. Verify. Move on.

---

## The Iron Laws

### 1. `check_rtl.sh` gates every synthesis run

Run `chips/check_rtl.sh` before any Quartus job. If it fails, fix it. Don't submit failing RTL to a 30-90 min synthesis queue.

```bash
cd /Volumes/2TB_20260220/Projects/MiSTer_Pipeline
bash chips/check_rtl.sh
```

### 2. Every chip needs a standalone synthesis harness

Located at `chips/CHIP/standalone_synth/`. A chip is not done until it has a passing standalone synthesis run. Standalone runs in 5-15 min. Full-system runs in 30-90 min. Debug at chip level, not system level.

### 3. Explicit altsyncram for every RAM > ~32 entries

`(* ramstyle = "M10K" *)` is a hint. It is ignored for byte-enable writes. Use explicit `altsyncram` with `byteena_a`. No behavioral inference for anything real.

### 4. Register every RAM output before use

M10K has 1-cycle output latency. All pipelines account for this. Combinational reads from M10K cause timing violations at >60 MHz.

### 5. Every module needs a `cen` clock enable port

Subsystems run at divided rates via clock enables from a single master PLL. Not via multiple PLLs, not via gated clocks.

### 6. byteena_b = 1'b1 on read-only DUAL_PORT ports

Formal width is 1 bit. Multi-bit connections cause Warning 12020.

### 7. Asynchronous reset everywhere

`always @(posedge clk, posedge rst)` — not `always @(posedge clk)` with `if (rst)`.
Synchronous reset creates a mux on every flip-flop output, costs a LUT layer, and degrades Fmax.
Async reset maps to the dedicated CLR pin. From `pattern-ledger.md` Pattern 1.

### 8. Pixel pipeline: use shift-register extraction, not case-on-column

For 4bpp scroll tiles: load 3 bytes (3 bitplanes × 8 pixels) into a shift register.
Left-shift all bytes each `pxl2_cen`; extract `pxl_data[23]`, `[15]`, `[7]` = current pixel.
Avoids barrel shifter inference. Cheaper than `case (pixel_x)` selecting nibbles.
From `pattern-ledger.md` Pattern 3.

### 9. Scroll tile arithmetic: track overflow bits for 4-quadrant page wrapping

System 16 (and similar) has 16 tilemap pages in a 2×2 grid. Horizontal position arithmetic
must be 10-bit (`{hov, hpos}`) and vertical 9-bit (`{vov, vpos}`) to produce overflow bits.
`case ({vov, hov})` selects the active page. Truncating to 9 bits loses page selection.
From `pattern-ledger.md` Pattern 4.

### 10. SDRAM fetch state machine: stall, don't assume fixed latency

State machines that handshake with SDRAM must use conditional rollback:
`if (!map_ok || busy != 0) map_st <= same_state;` — not bare `if (map_ok)` capture.
SDRAM latency varies with refresh cycles and arbiter contention. Without stall logic,
tile fetches get dropped under load causing rendering glitches. From `pattern-ledger.md` Pattern 5.

### 11. Every scroll layer needs a line buffer (render one scanline ahead)

Tile map + graphics fetch requires 8+ SDRAM cycles per tile. This exceeds per-pixel time.
Use `jtframe_linebuf` or equivalent: write to scanline N+1 while displaying scanline N.
Without a line buffer, you cannot sustain pixel clock throughput. From `pattern-ledger.md` Pattern 6.

### 12. Packed pixel bus convention

All scroll/char/obj pixel outputs feeding line buffers or priority mixers use:
`output [10:0] pxl` = `{ prio[0], pal[6:0], col[2:0] }`. Match `jtframe_linebuf` DW=11.
From `pattern-ledger.md` Pattern 8.

### 13. No unique case / priority case (Quartus 17.0 warnings)

Use plain `case`. `unique case` and `priority case` generate Warning 10280 in Quartus 17.0.
`check_rtl.sh` Check 10 catches these. All RTL currently clean (2026-03-18).
From `pattern-ledger.md` Pattern 9.

---

## Assembly Line Rules (Iron Law — do not violate)

1. **One chip at a time through the CI queue.** Do not push RTL changes for multiple chips in the same commit. Each commit should touch exactly ONE chip directory.
2. **Never push `.github/workflows/` changes with `chips/` RTL changes in the same commit.** Workflow changes need `workflow` PAT scope; RTL changes don't. They must be separate.
3. **Queue discipline:** Only advance the next chip when the current chip is green (CI pass or known-deferred). Don't start new work until current work exits the queue.
4. **check_rtl.sh PASS before commit.** Not before push — before commit. If check_rtl.sh warns, either fix the warn or document why it's a false positive before committing.
5. **Quartus exit code 2 = fits device (timing violations).** This is a WARNING state — CI is configured to pass on exit 2. A chip in exit-2 state needs SDC work but is otherwise valid hardware.

## CI Queue (2026-03-18)

| Position | Chip | CI Status | Next Action |
|----------|------|-----------|-------------|
| **DONE** | nmk_arcade | ✅ GREEN (run #23269331071, exit 0, setup -17.859ns, 10,937/41,910 ALMs 26%) | SDC timing work; improvement from baseline -18ns (stable) |
| **DONE** | psikyo_arcade | ✅ GREEN (run #23260684856, exit 0) | — |
| **DONE** | taito_b | ✅ GREEN (run #23263937572, exit 0, setup -56.224ns, 11,460/41,910 ALMs 27%) | SDC timing work (regression from baseline -59.685ns → -56.224ns, slight improvement) |
| **DONE** | toaplan_v2 | ❌ FAIL (run #23267780482, exit 1) — Fitter: Can't fit device (27,542/41,910 ALMs 66% — routing/placement congestion from GP9001 Gates 3-5 added ~12K ALMs after last green run #23260684816). QSF updated 2026-03-23: AGGRESSIVE AREA + AGGRESSIVE FIT + disabled register duplication. Pending re-run. MLAB→M10K VRAM restructure (saves ~800 ALMs) needs Opus review. | Re-run CI after QSF changes. If still fails, Opus review for VRAM pipeline restructure. |
| **DONE** | taito_x | ✅ GREEN (run #23260684796, exit 0, RBF 2.9M) | SDC timing work (setup -47.934ns) |
| **DONE** | kaneko_arcade | ✅ GREEN (run #23260684782, exit 0, RBF 3.4M) | SDC timing work (setup -42.461ns) |
| **FROZEN** | taito_f3 | ❌ 53% over budget (TC0630FDP) | Architecture decision |
| **FROZEN** | taito_z | ❌ 386% over budget (2× fx68k) | Architecture decision |

**Do not touch FROZEN chips.**

**5/8 chips GREEN with RBF bitstreams as of 2026-03-18. toaplan_v2 regressed: Fitter Can't fit (66% ALMs, routing/placement congestion). Root cause identified 2026-03-23: GP9001 Gates 3-5 added ~12K ALMs after last green run.**
**QSF updated 2026-03-23 to AGGRESSIVE AREA optimization + disabled register duplication. CI re-run pending. If still fails: Opus review for MLAB→M10K VRAM pipeline restructure (~800 ALM savings).**
**Taito B COMPLETE: 2299/2299 frames 100% WRAM match. All tasks done.**

## Chip Status (component chips — run standalone after system chips pass)

| Chip | Standalone Harness | Last Standalone Synth | Notes |
|------|-------------------|-----------------------|-------|
| tc0630fdp | ✅ `chips/tc0630fdp/standalone_synth/` | Not yet run | Taito F3 component — deferred with F3 |
| tc0480scp | ✅ `chips/tc0480scp/standalone_synth/` | Not yet run | Taito Z component |
| tc0370mso | ✅ `chips/tc0370mso/standalone_synth/` | Not yet run | Taito Z component |
| tc0150rod | ✅ `chips/tc0150rod/standalone_synth/` | Not yet run | Taito Z component |
| tc0180vcu | ✅ `chips/tc0180vcu/standalone_synth/` | Not yet run | Taito B component |
| tc0650fda | ✅ `chips/tc0650fda/standalone_synth/` | Not yet run | Taito B/F3 component |

---

## Open Architecture Issues

### Taito Z — CPU ALM overflow
2× fx68k before any GPU logic. TG68K is NOT a resource-saver (15-20% larger than fx68k) and is NOT a drop-in replacement (completely different adapter interface). Options:
1. Profile real ALM cost via standalone synthesis of fx68k_adapter alone first
2. Accept Taito Z needs HDMI + audio disabled (jotego pattern for tight designs)
3. Defer — Taito Z is architecturally the most complex system in the pipeline

### GP9001 VRAM — MLAB inference (resolved for now)
Warning 10999: `gp9001.sv:680` vram (32K×16) could not be inferred as MLAB — Quartus used M10K instead.
Chip STILL FITTED (exit 0, RBF produced). M10K synthesis is acceptable for now.
If device utilization becomes tight, revisit synchronous read pre-fetch pipeline to free M10K blocks.
No action required before kaneko_arcade.

### Taito F3 — ALM overflow
**Real measured numbers (run #23263701073, 2026-03-18):** 193,341 / 41,910 ALMs = **461% over capacity**.
- Total registers: 265,988
- Total RAM Blocks: 0 / 553 (Fitter couldn't even place M10K before ALM exhaustion)
- 3 Fitter errors: device physically cannot fit this design
Root cause: TC0630FDP alone is enormous. TC0630FDP is the Taito F3 background processor with 32 independent tilemap sections. This is fundamentally too large for DE-10 Nano without major stubbing.

---

## Calibration Diff — COMPLETE (2026-03-18)

`chips/jts16_scr_calibration/my_jts16_scr.sv` = from-scratch S16 scroll implementation.
`chips/pattern-ledger.md` = 11 patterns derived from diff against `jotego/jts16_scr.v`.
Key patterns folded into Iron Laws 7-13 above and `check_rtl.sh` Checks 9-10.

---

## Workflow

```
write RTL
  ↓
bash chips/check_rtl.sh          ← 10 seconds, catch known-bad patterns
  ↓ passes
standalone synthesis (5-15 min)  ← chips/CHIP/standalone_synth/
  ↓ passes
commit chip
  ↓
integration synthesis             ← only after ALL chips pass standalone
```

Never skip steps. Never run integration synthesis to find bugs that standalone would catch.

---

## Assembly Line Reset (established after nmk_arcade debug debt)

### Freeze rule
No new cores advance to CI until the current ACTIVE core simulation is green.
Current gate: nmk_arcade simulation must produce non-black frames before kaneko_arcade
or taito_x synthesis work resumes.

### Sim-before-CI rule
For every new core: verify simulation (Verilator testbench) with a NOP ROM before
committing RTL to the synthesis CI queue. A CPU that executes 6 bus cycles and halts
gives no signal in synthesis — only in simulation.

### Opus-first rule
For each new chip FAMILY (new CPU or GPU not yet seen), one Opus session writes:
- Integration spec (clocks, resets, memory map, interrupt wiring from MAME driver)
- Testbench structure and first assertions
- Known gotchas GUARDRAILS entry
Then Sonnet/Haiku execute.

### One-core-at-a-time rule
Never load more than one core's simulation context simultaneously. Each sim debug
session starts with: read this GUARDRAILS.md, read the chip-specific sim/GUARDRAILS.md,
then dispatch agents. Do not read RTL files inline — delegate to Explore agents.

### VCD script rule
Each chip family gets one reusable VCD extraction script in sim/vcd_extract.py.
Write it once with all relevant signal paths. Reuse across sessions. Never write
throwaway VCD parsing scripts inline.

---

## fx68k Integration Rules (from audit of 10+ production MiSTer cores — jotego, va7deo, Cave, Raizing)

These rules apply to every core that instantiates fx68k. Violating any of them produces silent
CPU failures (hang, wrong data, unstable ISR entry) that do not surface until simulation.

### Rule 1 — VPAn: NEVER tie to 1'b1

```verilog
// WRONG — CPU hangs on every interrupt acknowledge cycle
assign VPAn = 1'b1;

// CORRECT — IACK detection
assign inta_n = ~&{FC2, FC1, FC0, ~ASn};
assign VPAn   = inta_n;
```

**Why:** VPA (Valid Peripheral Address) signals the CPU to use auto-vectored interrupt
acknowledgement. When VPAn is permanently deasserted (1'b1 = inactive), the CPU stalls
indefinitely waiting for DTACK during every IACK cycle. The interrupt is never acknowledged,
IPL remains asserted, and the CPU is permanently wedged. Fixed in `fx68k_adapter.sv`.

### Rule 2 — DTACKn: drive between enPhi1 and enPhi2

fx68k samples DTACKn on the enPhi2 (falling edge phase). DTACK must be stable by that
edge. Drive DTACK combinatorially from CS/ROM-ok signals between enPhi1 and enPhi2, or
register it one enPhi1 before the enPhi2 it must appear on.

**Why:** fx68k's internal pipeline reads the bus on enPhi2. A DTACK that arrives after enPhi2
is invisible for that cycle; the state machine waits one extra E-clock phase, corrupting
bus timing and potentially dropping the transfer entirely.

### Rule 3 — IPLn[2:0]: must be stable at enPhi2

Sample the raw interrupt request into a registered IPLn synchronized to enPhi2. Do NOT drive
IPLn directly from asynchronous VBlank or other raw signals.

**Why:** fx68k samples IPLn on enPhi2. A glitch or late-arriving edge between enPhi2 samples
causes phantom interrupt detection or missed interrupt detection. IPL changes must be committed
before enPhi2 arrives.

### Rule 4 — Address bus eab is [23:1] (word address only)

```verilog
// fx68k output
output [23:1] eab,   // word address — A[0] does not exist

// Convert to byte address for memory decode
wire [23:0] cpu_addr = {eab, 1'b0};
```

**Why:** The 68000 address bus is byte-addressed but pin A1 is the LSB output. A[0] is encoded
in UDS/LDS strobe pairs, not the address bus. fx68k follows this convention exactly. Any memory
decoder that treats eab as a 23-bit quantity without appending `1'b0` accesses even addresses
correctly but silently doubles all odd-byte offsets.

### Rule 5 — enPhi1 and enPhi2 must never both be high in the same cycle

The clock enable generator must be mutually exclusive:

```verilog
// Correct two-phase enable generation (example)
always @(posedge clk) begin
    enPhi1 <= phase;
    enPhi2 <= ~phase;
    phase  <= ~phase;
end
// enPhi1 and enPhi2 are always complementary — never simultaneously high
```

The first enable after reset must be enPhi1 (rising phase), not enPhi2.

**Why:** fx68k's internal state machine expects strict two-phase clocking. Simultaneous enPhi1
+ enPhi2 is undefined and causes the CPU FSM to advance two states in one clock, producing
bus glitches and incorrect instruction timing.

### Rule 6 — CS signals must be registered and gated with BGACKn

```verilog
// Combinatorial CS — WRONG
assign rom_cs = (cpu_addr[23:16] == 8'h00) & ~ASn & BGACKn;

// Registered CS — CORRECT
always @(posedge clk) begin
    rom_cs <= (cpu_addr[23:16] == 8'h00) & ~ASn & BGACKn;
end
```

`jtframe_68kdtack`'s `wait1` state compensates for the 1-cycle pipeline delay introduced by
registering CS. All jtframe-based designs assume this 1-cycle delay. Combinatorial CS will
fire one cycle early and race SDRAM requests.

**Why:** BGACKn (Bus Grant Acknowledge) signals that the DMA device has released the bus.
Without gating, CS can assert while DMA still owns the bus, causing two bus masters to drive
simultaneously. The registered pattern also eliminates glitches from address bus settling after
ASn falls.

### Rule 7 — Open bus must return 16'hFFFF, not 16'h0000

```verilog
// Data bus mux — open bus default
assign cpu_din =
    rom_cs  ? rom_data  :
    ram_cs  ? ram_data  :
    io_cs   ? io_data   :
    16'hFFFF;            // open bus — 68k sees pulled-up data lines
```

**Why:** Real 68000 hardware has pull-ups on the data bus. Unselected addresses read 0xFFFF.
Many game ROMs probe hardware presence by reading an unmapped address and checking for the
pull-up pattern. Returning 0x0000 causes detection logic to report wrong hardware version or
trigger spurious soft-reset paths.

### Rule 8 — dsn_dly pattern for DS-qualified CS signals

When CS decoding uses DS (data strobe) in addition to AS, add a one-cycle delay:

```verilog
reg dsn_dly;
always @(posedge clk) dsn_dly <= &{UDSn, LDSn};  // 1 when both inactive

// Gate SDRAM request with dsn_dly, not raw DS
assign sdram_req = rom_cs & ~dsn_dly;
```

**Why:** At the end of a write cycle, AS falls before DS. Without `dsn_dly`, the CS re-asserts
for one spurious cycle as DS deasserts, triggering a phantom SDRAM read or write. The delay
masks this glitch window.

### Rule 9 — Verilator MULTIDRIVEN: merge uaddrPla always_comb blocks

`fx68k/uaddrPla.sv` contains multiple `always_comb` blocks that drive overlapping signal ranges.
Verilator (≥4.x) reports `MULTIDRIVEN` and generates a scheduling graph where some signals are
never updated.

```bash
# -Wno-MULTIDRIVEN does NOT fix this — it only suppresses the warning while the bug remains
# CORRECT FIX: merge all always_comb blocks into a single block in uaddrPla.sv
```

**Why:** Verilator's static scheduling pass assigns each signal to exactly one always block
for update ordering. When a signal is driven by two blocks, Verilator picks one and silently
ignores the other. The PLA output is then stuck at reset value regardless of input, causing
completely wrong 68k microcode dispatch. Suppressing the warning leaves the scheduling bug
in place.

### Rule 10 — SDRAM toggle handshake protocol

```verilog
// Issue a request: toggle req
always @(posedge clk)
    if (new_request) req <= ~req;

// rom_ok: request has been served
assign rom_ok   = (req == ack);     // ack mirrors req when done
assign bus_busy = rom_cs & ~rom_ok; // stall the CPU while waiting
```

**Why:** Level-based req/ack would require the SDRAM controller to deassert ack before the
next request, introducing a mandatory dead cycle. Toggle handshake allows back-to-back requests
without a dead cycle between them, and is immune to reset-state ambiguity (req==ack==0 at
power-on means "idle," which is correct).

### Rule 11 — VBlank interrupt: clear on IACK, not on timer

```verilog
// CORRECT pattern — clear IPL on IACK cycle
always @(posedge clk) begin
    if (LVBL_falling)   ipl_n <= 3'b110;  // assert IPL1 (level 2 interrupt)
    else if (~inta_n)   ipl_n <= 3'b111;  // deassert on IACK
end
```

Do NOT hold IPL low for a fixed number of cycles via a counter. Do NOT clear on the next
VBlank edge.

**Why:** Real 68000 hardware clears IPL when the CPU executes the IACK bus cycle. Holding IPL
low beyond that point causes the CPU to re-enter the ISR immediately after RTI (double-interrupt
storm). Clearing early (before IACK) causes a spurious auto-vector and ISR entry corruption.
The IACK-based clear is the only correct mechanism.

### Rule 12 — Write byte-mask: derive from RnW + UDS/LDS

```verilog
// SDRAM byte enables for writes
assign UDSWn = RnW | UDSn;   // write upper byte only when RnW=0 AND UDSn=0
assign LDSWn = RnW | LDSn;   // write lower byte only when RnW=0 AND LDSn=0
```

Pass `{~UDSWn, ~LDSWn}` as the SDRAM byte-enable for write operations, not raw `{~UDSn, ~LDSn}`.

**Why:** UDSn and LDSn are active during reads as well as writes (they qualify which bytes are
driven on the bus). Using raw UDSn/LDSn for SDRAM byte-enable causes spurious byte writes on
every read cycle. The RnW gate ensures byte-enables are only active during actual write cycles.

### Rule 13 — Verilator sim: enPhi1/enPhi2 MUST be driven from C++, not RTL

In Verilator simulation, fx68k's `enPhi1`/`enPhi2` clock enables must be driven from the C++
testbench BEFORE `eval()`, not generated by RTL `always_ff`/`assign` blocks.

When phi enables are generated in RTL (e.g., `assign enPhi1 = ~phi_toggle & clk_sys`), Verilator's
scheduling evaluates the phi change and the clock edge in the same delta cycle. This creates a
race condition where fx68k's instruction decoder misfires — the CPU double-faults after the first
instruction despite receiving correct data.

**Working pattern (from C++ testbench):**
```cpp
if (top->clk_sys == 1) {  // rising edge
    top->enPhi1 = phi_toggle ? 0 : 1;
    top->enPhi2 = phi_toggle ? 1 : 0;
    phi_toggle = !phi_toggle;
} else {  // falling edge
    top->enPhi1 = 0;
    top->enPhi2 = 0;
}
top->eval();
```

**Why:** This was the root cause of a multi-day debug. Both JTFPGA and stock fx68k produce the
same failure. The fix applies to ALL fx68k Verilator simulations. For synthesis (Quartus), RTL
phi generation works correctly — this is purely a Verilator scheduling artifact.

### Rule 14 — Use JTFPGA/fx68k fork for Verilator simulation

Stock ijor/fx68k has known Verilator incompatibilities (mixed blocking/non-blocking assignments,
unsupported struct types). Use the `JTFPGA/fx68k` fork (`hdl/verilator/` subdirectory) which
removes structs and fixes assignment patterns. Source: https://github.com/JTFPGA/fx68k

**Why:** Stock fx68k compiles in Verilator but produces incorrect behavior. The JTFPGA fork is
used by all jotego cores and is the only version validated for Verilator simulation.

---

## Known Bugs Found in Audit (2026-03-18)

These bugs were identified during the community-core audit pass. Each represents a core that
synthesizes clean but cannot execute game code at runtime.

### ~~taito_b — CPU ROM SDRAM channel wired but unused~~ ✅ FIXED (commit 5696c7d)

### ~~taito_x — CPU ROM SDRAM channel driven as zero~~ ✅ FIXED (commit 64c35a4)

### ~~taito_x — Z80 WAIT_n permanently asserted~~ ✅ FIXED (commit 64c35a4)

### toaplan_v2 / kaneko — GFX SDRAM upper 16 bits always zero

`chips/toaplan_v2/` and `chips/kaneko_arcade/`: The GFX SDRAM data path concatenates upper
and lower 16-bit words, but the upper word appears to be always zero in the current wiring.
All GFX tiles will display with missing bitplanes. Requires verification against MAME GFX ROM
layout and SDRAM word-swap conventions before declaring either core playable.
