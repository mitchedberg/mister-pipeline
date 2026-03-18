# MiSTer FPGA Synthesis Guide — Community Patterns & Quartus 17.0 Rules

*Compiled from: our synthesis runs (Taito B/F3/Z/X, NMK16, Psikyo, Toaplan V2)
+ community core study (jotego jtcps1/jtcps2/jtoutrun/jts16, Cave MiSTer, atrac17/Toaplan2)*

---

## 1. DE-10 Nano Resource Budget

**Device:** Intel Cyclone V 5CSEBA6U23I7 (SoC FPGA, UFBGA-672)

| Resource | Total | Practical Budget | Notes |
|----------|-------|-----------------|-------|
| ALMs | 41,910 | ~35,000 | ~83% utilization before routing congestion |
| Logic Elements (LE equiv) | 83,820 | ~70,000 | Each ALM = 2 LEs |
| M10K blocks | 553 | ~480 | Leave ~70 for sys/ framework |
| MLABs | 397 | ~350 | 640 bits each (sync write, async read) |
| PLLs | 6 | 4 usable | sys/ framework uses 3-4 (audio, HDMI, SDRAM) |

**sys/ framework overhead (MiSTer DE-10 Nano):**
- ~3,000–5,000 ALMs for HPS bridge, scaler, OSD, audio, HDMI
- ~70 M10K blocks for framebuffer (when `MISTER_FB=1`; 0 when disabled)
- 3 PLLs: audio (12.288 MHz), HDMI (various), config

**Remaining budget for your arcade core:**
- ALMs: ~30,000–32,000 (worst case with full scaler)
- M10K: ~480

### Component ALM estimates from our synthesis runs

| Component | ALMs (approx) | Notes |
|-----------|--------------|-------|
| fx68k (68000) | 7,000–9,000 | Per CPU instance |
| T80s (Z80) | 500–800 | |
| TC0630FDP (F3 GPU) | 15,000–20,000 | Before sprite_render fix; TBD after |
| TC0480SCP (scrolling) | 3,000–5,000 | Mostly VRAM + tile fetch FSMs |
| TC0370MSO (road sprites) | 4,000–6,000 | Fbuf altsyncram + scanner |
| NMK16 system (no CPU) | ~18,000 | Fits with timing violations |
| Psikyo system (1×68K + Z80) | ~25,000 | Fits but routing congested |
| Taito Z (2×68K + TC0480SCP + TC0370MSO) | 323K LEs → DNF | 2 fx68k = fundamental overflow |

---

## 2. Quartus 17.0 RTL Rules (Hard-Won from Synthesis Failures)

### 2.1 RAM Inference — The Cardinal Rules

**Rule: NEVER use `(* ramstyle = "M10K" *)` with conditional byte-enable writes.**

Quartus 17.0 synthesizer cannot map conditional bit-field writes to M10K byteena:
```systemverilog
// WRONG — causes MAP OOM (Error 293007) — Quartus expands to flip-flops:
(* ramstyle = "M10K" *) logic [15:0] mem [0:8191];
always_ff @(posedge clk)
    if (we && be[1]) mem[addr][15:8] <= din[15:8];  // conditional byte slice = ERROR
    if (we && be[0]) mem[addr][ 7:0] <= din[ 7:0];
```

```systemverilog
// CORRECT — explicit altsyncram with byteena_a:
altsyncram #(
    .operation_mode   ("SINGLE_PORT"),
    .width_a          (16), .widthad_a (13), .numwords_a (8192),
    .width_byteena_a  (2),
    .ram_block_type   ("M10K"),
    .outdata_reg_a    ("CLOCK0"),
    ...
) inst (.clock0(clk), .address_a(addr), .data_a(din),
        .wren_a(we), .byteena_a(be), .q_a(dout), ...);
```

**Rule: Use `altsyncram` for any array > 512 bits that has byte-enable writes.**

**Rule: 3D arrays with runtime variable first-dimension index → OOM explosion.**
```systemverilog
// WRONG — Quartus builds full MUX tree across all banks → massive logic:
logic [11:0] lbuf [0:1][0:319];
always_ff @(posedge clk)
    lbuf[front_buf][x] <= data;  // runtime index on first dim = MUX over all banks
```
```systemverilog
// CORRECT — split into separate flat arrays, select with if/else:
logic [11:0] lbuf0 [0:319];
logic [11:0] lbuf1 [0:319];
always_ff @(posedge clk)
    if (front_buf) lbuf1[x] <= data;
    else           lbuf0[x] <= data;
```

**Rule: Loop-based combinational reset = combinational node explosion.**
```systemverilog
// WRONG — 640 iterations × 12 enable muxes = 7,680 mux nodes:
always_ff @(posedge clk)
    if (clear) for (int i=0; i<320; i++) begin
        lbuf0[i] <= '0;
        lbuf1[i] <= '0;
    end
```
```systemverilog
// CORRECT — counter-based sequential clear:
logic [8:0] clr_idx;
logic       clr_active;
always_ff @(posedge clk) begin
    if (start_clear) begin clr_active <= 1'b1; clr_idx <= '0; end
    else if (clr_active) begin
        lbuf0[clr_idx] <= '0;
        lbuf1[clr_idx] <= '0;
        if (clr_idx == 9'd319) clr_active <= 1'b0;
        else                   clr_idx <= clr_idx + 1'b1;
    end
end
```

### 2.2 Module Ports — Quartus 17.0 Restrictions

**Rule: No unpacked array ports.**
```systemverilog
// WRONG — Quartus 17.0 rejects unpacked array ports:
module foo (output logic [7:0] data [0:3]);   // ERROR

// CORRECT — packed multidimensional:
module foo (output logic [3:0][7:0] data);    // OK
```

**Rule: No non-constant variable initializers.**
```systemverilog
// WRONG:
logic [7:0] x = some_parameter + 1;   // elaborate-time expression rejected

// CORRECT:
logic [7:0] x;
assign x = some_parameter + 1;
```

### 2.3 PLL Frequencies

Quartus 17.0 Fitter rejects PLL output frequencies that aren't achievable from the reference:

```
50 MHz × M / (N × C) — M, N, C must be integers

50 MHz → 53.333 MHz = 50 × 16 / (1 × 15) = 800 / 15 ✓
50 MHz → 53.500 MHz = not achievable from 50 MHz integer division ✗  ERROR
50 MHz → 133.333 MHz = 50 × 8 / (1 × 3) ✓
50 MHz → 143.000 MHz = 50 × 143 / (1 × 50) ✓ (high VCO)
```

### 2.4 MLAB vs M10K — When to Use Each

| Scenario | Use | Bits per block |
|----------|-----|----------------|
| ≤ 640 bits, async read (combinational), no byteena | MLAB | 640 |
| > 640 bits, sync read, byteena needed | M10K via altsyncram | 10,240 |
| True dual-port (two independent read+write ports) | M10K DUAL_PORT altsyncram | 10,240 |
| Single-port with byteena | M10K SINGLE_PORT altsyncram | 10,240 |
| CPU ↔ GPU dual-port (mixed width, 2 read ports) | Two DUAL_PORT altsyncram instances | 10,240 each |

**MLAB byteena limitation:** MLABs do not support byteena. If you need byte-enable writes to small RAM, use two separate MLABs (one per byte) or fall back to M10K.

### 2.5 altsyncram Patterns

**Two-read-port pattern** (CPU read + GPU read, common in palette RAM):
```systemverilog
// Shared write port A; port B = CPU read; port C via second instance = GPU read
// Both instances get the same write: wren_a, address_a, data_a, byteena_a
altsyncram #(.operation_mode("DUAL_PORT"), ...) cpu_inst (
    .clock0(clk), .clock1(clk),
    .address_a(wr_addr), .data_a(wr_data), .wren_a(we), .byteena_a(be),
    .address_b(cpu_rd_addr), .q_b(cpu_rd_data), .wren_b(1'b0), ...
);
altsyncram #(.operation_mode("DUAL_PORT"), ...) gpu_inst (
    .clock0(clk), .clock1(clk),
    .address_a(wr_addr), .data_a(wr_data), .wren_a(we), .byteena_a(be),
    .address_b(gpu_rd_addr), .q_b(gpu_rd_data), .wren_b(1'b0), ...
);
```

**byteena_b in DUAL_PORT:** formal width is always 1. Use `1'b1`, never `2'h3`.

**outdata_reg_b:** Use `"CLOCK1"` for synchronous read (1 cycle latency). Use `"UNREGISTERED"` for async read (MLAB-like — only for small RAMs in MLAB mode).

### 2.6 CPU Selection

| CPU | ALMs (approx) | Notes |
|-----|--------------|-------|
| fx68k (68000) | 7,000–9,000 | Best-accuracy 68K for MiSTer; expensive |
| TG68K (68K) | 5,000–7,000 | Less accurate but smaller; used in some jotego cores |
| fx68k_68020 | 10,000–14,000 | 68EC020 variant; very large |
| T80s (Z80) | 500–800 | Standard choice; jotego uses this too |

**Two-68K budget problem:** 2× fx68k ≈ 18,000 ALMs before any GPU logic. On 41,910 total ALMs with sys/ overhead, this leaves ~12,000 for the graphics system. TC0480SCP + TC0370MSO alone likely exceed that.

**Options when a design is too large:**
1. Replace fx68k with TG68K for one CPU (saves 2,000–3,000 ALMs per CPU)
2. Stub the second CPU (return NOP / frozen state) — breaks 2-player or sub-CPU functionality
3. Share a single CPU instance with bank-switched execution — complex, rarely done
4. Target a larger FPGA (5CEBA9F31I7 = 301K ALMs) — breaks DE-10 Nano compatibility

---

## 3. Community Core Patterns

### 3.1 jotego jtframe Architecture

*(Filled from research — see below)*

**Key insight:** jotego uses a shared framework (`jtframe`) that handles:
- Clock generation (PLL, clock enables)
- SDRAM controller (multi-bank, burst-mode)
- ROM download protocol (HPS → FPGA)
- OSD/menu integration
- Audio mixing

All game cores implement a standard interface to jtframe. This means **game RTL never deals with PLLs, SDRAM timing, or MiSTer I/O** — only the game logic. Our approach mirrors this with `sys/`.

**jtframe clocking pattern:**
```
50 MHz → PLL → clk_sys (48/53/96 MHz main)
                clk_rom (96+ MHz for SDRAM)
                clk_aud (49.152 MHz)
Game logic uses: clk_sys + clock-enable (cen) signals
```

Rather than multiple clock domains, jotego derives slower clocks via **clock enables**:
```verilog
// 6 MHz pixel clock from 48 MHz system clock:
always @(posedge clk_sys) cen_6 <= cen_6 + 1'b1; // 3-bit counter
assign pix_cen = (cen_6 == 3'd0);                  // 1-cycle pulse every 8 clocks
```
This keeps everything synchronous to one clock, eliminating CDC issues and timing problems.

### 3.2 jotego jtcps1 (CPS-1: 68K + Capcom custom GPU)

*(Research agent findings — to be filled in)*

**Estimated resources:**
- TODO: from research agent

**How they fit a large 68K + GPU:**
- TODO

**Key QSF flags:**
- TODO

**SDC approach:**
- TODO

### 3.3 jotego jtoutrun / jts16 / jts18 (Sega 16-bit: 68K + Z80 + Sega GPU)

*(Research agent findings — to be filled in)*

**Estimated resources:**
- TODO

**How they handle dual 68K (OutRun has 2x 68K):**
- TODO

### 3.4 Cave MiSTer (Cave 68K: 68K + Cave sprite engine)

*(Research agent findings — to be filled in)*

**Language:** Scala/Chisel (compiled to Verilog)
**Estimated resources:**
- TODO

### 3.5 atrac17/Toaplan2 (GP9001 GPU — directly overlaps our work)

*(Research agent findings — to be filled in)*

**Status vs our implementation:**
- TODO

---

## 4. Per-Chip Standalone Synthesis Workflow

### Why Per-Chip Synthesis

Full system synthesis (30–90 min per run) is too slow for debugging. Per-chip synthesis (5–15 min) lets you:
1. Verify a chip fits before integrating into the full system
2. Get accurate ALM/M10K numbers per component
3. Catch Quartus elaboration errors early
4. Tune altsyncram patterns without waiting for full system P&R

### Standalone Synthesis Harnesses

Pre-built for the three largest individual chips:

| Chip | Directory | Est. synth time |
|------|-----------|----------------|
| TC0630FDP (F3 GPU) | `chips/tc0630fdp/standalone_synth/` | 10–20 min |
| TC0480SCP (Z tilemap) | `chips/tc0480scp/standalone_synth/` | 5–10 min |
| TC0370MSO (Z road sprites) | `chips/tc0370mso/standalone_synth/` | 5–10 min |

**To run (from inside the standalone_synth/ directory):**
```bash
quartus_sh --flow compile standalone.qsf 2>&1 | tee synth.log
# Then check resource usage:
grep "Logic utilization" output_files/*.fit.rpt
grep "Total block memory" output_files/*.fit.rpt
grep "Total ALMs" output_files/*.fit.rpt
```

**What to look for in the fit report:**
```
; ALMs needed [=]                 ; 12,345 ;   <- your chip's ALM count
; Total block memory bits         ; 1,234,567 ; <- M10K usage
; Total dedicated logic registers ; 67,890 ;
; Timing: Worst-case Fmax         ; 53.4 MHz ; <- compare to your clock
```

**Interpreting results:**
- If ALMs > 30,000: chip alone is too large; look for 3D arrays, unguarded for loops
- If "Error (293007)" in MAP: altsyncram conversion needed (see Section 2.1)
- If "Error (10028)" in FIT: multiple-driver issue; two always blocks writing same signal
- If Fmax < 53.333 MHz: timing violation; add false/multi-cycle paths in SDC

### Building a Per-Chip CI Job

Add to `.github/workflows/synthesis_chips.yml`:
```yaml
jobs:
  tc0630fdp:
    runs-on: ubuntu-latest
    container: raetro/quartus:17.0
    steps:
      - uses: actions/checkout@v3
      - name: Synthesize TC0630FDP standalone
        working-directory: chips/tc0630fdp/standalone_synth
        run: quartus_sh --flow compile standalone.qsf
      - name: Report resources
        run: grep -E "ALMs needed|block memory bits" chips/tc0630fdp/standalone_synth/output_files/*.fit.rpt
```

---

## 5. SDC Timing Closure Patterns

### 5.1 Minimum SDC for a MiSTer Core

```tcl
# Reference clock
create_clock -period "20.0 ns" -name {FPGA_CLK1_50} [get_ports {FPGA_CLK1_50}]
create_clock -period "20.0 ns" -name {FPGA_CLK2_50} [get_ports {FPGA_CLK2_50}]
create_clock -period "20.0 ns" -name {FPGA_CLK3_50} [get_ports {FPGA_CLK3_50}]

# Derive all PLL outputs automatically
derive_pll_clocks

# Apply setup/hold margins across corners
derive_clock_uncertainty

# Clock domain isolation (prevents bogus cross-domain paths)
set_clock_groups -exclusive \
    -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk }] \
    -group [get_clocks { *pll_hdmi* }] \
    -group [get_clocks { *pll_audio* }] \
    -group [get_clocks { FPGA_CLK1_50 FPGA_CLK2_50 FPGA_CLK3_50 }]

# False paths on all I/O (not in timing-critical path)
set_false_path -from [get_ports {KEY*}]
set_false_path -to   [get_ports {LED_*}]
set_false_path -to   [get_ports {VGA_*}]
set_false_path -to   [get_ports {AUDIO_*}]
set_false_path -from [get_ports {SW[*]}]
```

### 5.2 Fixing -17ns Setup Slack (NMK16 pattern)

When Quartus reports "not fully constrained" with large negative slack:
1. Add explicit false paths for slow control signals:
   ```tcl
   set_false_path -to {dip_sw[*] game_id[*]}
   ```
2. Add multi-cycle paths for paths that cross clock-enable domains:
   ```tcl
   # Pixel pipeline: data valid for 8 sys_clk cycles
   set_multicycle_path -from {*sprite_scan*} -to {*line_buffer*} -setup 4
   set_multicycle_path -from {*sprite_scan*} -to {*line_buffer*} -hold  3
   ```
3. Try SEED values 2–5 (Quartus P&R is PRNG-seeded; different seeds = different routing):
   ```
   set_global_assignment -name SEED 3
   ```

### 5.3 Fixing -42ns Setup Slack + Routing Congestion (Psikyo pattern)

Severe negative slack with routing congestion means the design is near device capacity:
1. Check "Routing utilization" in fit report — if > 90%, congestion is the root cause
2. Try `OPTIMIZATION_TECHNIQUE AREA` instead of `SPEED` to reduce register duplication
3. Add logic to reduce: look for large register arrays that can be M10K instead
4. Add `ROUTER_EFFORT_MULTIPLIER 2.0` to the QSF for aggressive routing effort

---

## 6. What to Stub vs Implement

### 6.1 Safe to Stub (no gameplay impact)

| Feature | Stub | Impact |
|---------|------|--------|
| YC/composite video encoder | `MISTER_DISABLE_YC=1` | No CRT-composite output |
| ALSA audio | `MISTER_DISABLE_ALSA=1` | No S/PDIF audio |
| HDMI scaler framebuffer | `MISTER_FB=0` (default) | No integer scale modes |
| Second CPU (if used only for sound) | Return NOP | Silent sound |
| Ensoniq ES5505 (Taito F3 audio) | Return 0 | Silent audio, correct otherwise |

### 6.2 Must Implement (breaks gameplay if missing)

- Main CPU (all game logic runs here)
- Primary GPU / sprite engine (display nothing without it)
- VRAM / sprite RAM (sprites/tiles won't render)
- SDRAM controller (ROM loading required)
- Joystick I/O (no input without it)

### 6.3 Can Simplify (reduces ALMs, minor visual impact)

| Feature | Simplification | ALM savings |
|---------|---------------|-------------|
| Sprite scaling | Nearest-neighbor instead of bilinear | 500–1000 |
| Layer priority | Fixed priority vs programmable | 200–500 |
| Rowscroll/colscroll | Disable rowscroll | 500–1000 |
| Color palette blending | Skip color math | 200–500 |
| Rotation chip (TC0280GRD etc.) | Output unrotated | 2000–5000 |

---

## 7. Decision Matrix: Will It Fit?

Quick estimate: add up components and compare to DE-10 Nano budget.

```
Budget:              ~30,000 ALMs (leaving room for sys/)

Your design estimate:
  sys/ framework:         4,000 ALMs (fixed overhead)
  CPU(s):                 _____ ALMs × ___ CPUs
  Primary GPU chip:       _____ ALMs
  Secondary GPU chips:    _____ ALMs
  SDRAM controller:         500 ALMs
  Audio (jt10/jt51):      2,000 ALMs
  I/O / misc:               500 ALMs
  ─────────────────────────────────
  Total:                  _____ ALMs

If total > 35,000: design will NOT fit. Must reduce.
If total > 30,000: borderline — try AREA optimization and SEED sweep.
If total < 28,000: comfortable fit, focus on timing closure.
```

**Rule of thumb from community cores:**
- 1× 68K CPU + 1× Z80 + medium GPU + audio = ~18,000–22,000 ALMs → fits
- 1× 68K CPU + 1× Z80 + large GPU (TC0630FDP-scale) = ~28,000–32,000 ALMs → tight
- 2× 68K CPU + large GPU = ~35,000+ ALMs → likely won't fit, need simplification

---

## Appendix A: Useful Quartus Report Grep Patterns

```bash
# Resource usage summary
grep -E "Total ALMs|Logic utilization|block memory bits|Total registers" *.fit.rpt

# Timing summary
grep -E "Fmax|slack|setup|hold" *.sta.rpt | head -30

# Check for MAP OOM (Error 293007)
grep "293007" *.map.rpt

# Check for doesn't-fit (Error 170011)
grep "170011" *.fit.rpt

# Find which nodes are causing timing failures
grep -A5 "Critical Path" *.sta.rpt | head -50

# Routing utilization (congestion indicator)
grep "Routing utilization" *.fit.rpt
```

## Appendix B: CI Failure Quick Reference

| Error | Cause | Fix |
|-------|-------|-----|
| Error 293007 (MAP OOM) | Large behavioral array with byte-enable writes | Convert to altsyncram with byteena_a |
| Error 170011 (doesn't fit) | Too many logic cells | Check 3D arrays, loop resets, consider TG68K |
| Error 10028 (multiple drivers) | Two always blocks writing same signal | Merge into single always block |
| Warning 12020 (byteena_b width) | `byteena_b(2'h3)` on DUAL_PORT | Change to `byteena_b(1'b1)` |
| Fitter rejects PLL frequency | Non-integer PLL divider | Use exact frequency: 53.333333 not 53.5 |
| `T80pa` not found | Wrong T80 variant | Use `T80s` with `OUT0`, `CEN_p`→`CEN`, `DO`→`DOUT` |
| Unpacked array port error | Quartus 17.0 limitation | Use packed multidimensional syntax |
| `-Wno-MODMISSING` in Verilator | Old flag name | Use `-Wno-PINMISSING` (needs workflow PAT scope) |
