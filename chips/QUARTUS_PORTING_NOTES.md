# Quartus 17.0 Porting Notes

Lessons learned porting SystemVerilog RTL to Quartus 17.0.2 Lite Edition on Cyclone V (DE-10 Nano).
Every item here was a real synthesis failure encountered during the MiSTer Pipeline CI bring-up.

---

## 1. Edition-Specific QSF Assignments

**`TIMING_ANALYZER_MULTICORNER_ANALYSIS` is Standard/Pro-only.**

Quartus Lite Edition refuses to open projects that include this assignment:
```
set_global_assignment -name TIMING_ANALYZER_MULTICORNER_ANALYSIS ON   ← DELETE THIS
```
Also update the version string in QSF files:
```
set_global_assignment -name LAST_QUARTUS_VERSION "17.0.2 Lite Edition"
```

Reference: compare any new QSF against the Arcade-Galaga template QSF to catch other invalid-in-Lite assignments.

---

## 2. `altpll` vs `altera_pll` — Cyclone V Requires `altera_pll`

`altpll` is Cyclone II–IV only. Cyclone V (DE-10 Nano) requires `altera_pll` with string-format frequency parameters.

**Correct for Cyclone V:**
```verilog
altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .number_of_clocks(2),
    .output_clock_frequency0("48.000000 MHz"),
    .output_clock_frequency1("96.000000 MHz")
) pll_inst ( ... );
```

The canonical Quartus 17.0 PLL IP structure is **3 files**:
- `pll.v` — wrapper with `altera_pll` instantiation
- `pll/pll_0002.v` — Quartus-generated atom file
- `pll.qip` — IP descriptor listing both files

Do NOT use inline `altera_pll` instantiation in RTL files — always generate via IP catalog and include via `.qip`.

---

## 3. `sys/` Directory Location

Quartus `sys.tcl` uses paths relative to the QPF (project file) location.
The `sys/` directory **must be inside `quartus/`**, not at the chip root:

```
chips/my_chip/quartus/sys/    ← CORRECT (sys.tcl finds it)
chips/my_chip/sys/            ← WRONG (sys.tcl can't find it)
```

Required files in `quartus/sys/`:
- `sys.tcl`
- `build_id.tcl`
- Any other TCL scripts referenced from the QSF

When adding a new chip, copy `sys/` from an existing chip's `quartus/` directory.

---

## 4. `QUARTUS=1` Macro — Required for All Synthesis Targets

Add to every QSF **before** the `source files.qip` line:
```
set_global_assignment -name VERILOG_MACRO "QUARTUS=1"
```

RTL uses this to switch between simulation-friendly constructs and Quartus-compatible equivalents:
```verilog
`ifndef QUARTUS
    // Simulation path: flat arrays, behavioral 3-port RAM, 3D arrays
    logic [7:0] my_ram [0:1023];
    assign q = my_ram[addr];
`else
    // Synthesis path: altsyncram instantiation
    altsyncram #(...) ram_inst (...);
`endif
```

Without `QUARTUS=1`, any 3D array or large flat array in the RTL will reach the synthesizer and OOM quartus_map.

---

## 5. `altsyncram` Parameter Requirements

### ⚠️ DO NOT USE `BIDIR_DUAL_PORT` — Use Two `DUAL_PORT` Instances Instead

`BIDIR_DUAL_PORT` mode in Quartus 17.0 triggers a cascade of errors (272006, 287078)
that are extremely difficult to fully resolve because of undocumented requirements around
`byteena_b`, the "clear box" feature, and port-B clock domain consistency. **Do not use it.**

**The correct approach** (from `tc0110pcr.sv`) is to use **two `DUAL_PORT` instances**:
- Instance 1 (`_pxl`): port A = CPU write, port B = display read
- Instance 2 (`_cpu`): port A = CPU write, port B = CPU readback (same address_b as CPU)

This splits the true-dual-port semantics into two simple-dual-port instances, which Quartus
17.0 handles perfectly with no clock-domain errors.

**Template (copy this — it works):**
```verilog
logic [15:0] ram_pxl_q;  // display read result
logic [15:0] ram_cpu_q;  // CPU readback result

// ── Display pixel read ─────────────────────────────────────────────────────
altsyncram #(
    .operation_mode              ("DUAL_PORT"),
    .width_a                     (W), .widthad_a (N), .numwords_a (1<<N),
    .width_b                     (W), .widthad_b (N), .numwords_b (1<<N),
    .outdata_reg_b               ("CLOCK1"),
    .address_reg_b               ("CLOCK1"),
    .clock_enable_input_a        ("BYPASS"),
    .clock_enable_input_b        ("BYPASS"),
    .clock_enable_output_b       ("BYPASS"),
    .intended_device_family      ("Cyclone V"),
    .lpm_type                    ("altsyncram"),
    .ram_block_type              ("M10K"),
    .width_byteena_a             (2),          // omit if no byte enables
    .power_up_uninitialized      ("FALSE"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ")
) ram_pxl_inst (
    .clock0         ( clk           ),  .clock1         ( clk     ),
    .address_a      ( cpu_addr      ),  .data_a         ( cpu_din ),
    .wren_a         ( cpu_we        ),  .byteena_a      ( cpu_be  ),
    .address_b      ( pxl_addr      ),  .q_b            ( ram_pxl_q ),
    .wren_b         ( 1'b0          ),  .data_b         ( {W{1'b0}} ),
    .q_a            (               ),
    .aclr0          ( 1'b0 ), .aclr1          ( 1'b0 ),
    .addressstall_a ( 1'b0 ), .addressstall_b ( 1'b0 ),
    .byteena_b      ( {(W/8){1'b1}} ),
    .clocken0       ( 1'b1 ), .clocken1       ( 1'b1 ),
    .clocken2       ( 1'b1 ), .clocken3       ( 1'b1 ),
    .eccstatus      (      ), .rden_a         (      ),
    .rden_b         ( 1'b1 )
);

// ── CPU readback ──────────────────────────────────────────────────────────
altsyncram #(
    // ... identical params ...
) ram_cpu_inst (
    .clock0         ( clk           ),  .clock1         ( clk     ),
    .address_a      ( cpu_addr      ),  .data_a         ( cpu_din ),
    .wren_a         ( cpu_we        ),  .byteena_a      ( cpu_be  ),
    .address_b      ( cpu_addr      ),  .q_b            ( ram_cpu_q ),  // same address!
    // ... identical port connects ...
);
```

**Key points:**
- `clock0` and `clock1` are BOTH connected to `clk` (same signal, different port names)
- Port B is on `CLOCK1` (even though it's the same clock) — this satisfies Quartus 17.0
- ALL optional ports must be connected explicitly: `aclr0`, `aclr1`, `addressstall_a/b`,
  `byteena_b`, `clocken0-3`, `eccstatus`, `rden_a`, `rden_b`
- CPU readback uses `address_b = cpu_addr` (same as port A) to mirror the write address
- 1-cycle registered read latency: address_reg_b("CLOCK1") + outdata_reg_b("CLOCK1")
  are the M10K internal address+output registers, not two separate pipeline stages

### SINGLE_PORT — Must specify `numwords_a`

```verilog
altsyncram #(
    .operation_mode     ("SINGLE_PORT"),
    .width_a            (W),
    .widthad_a          (N),
    .numwords_a         (1 << N),   // REQUIRED
    ...
) inst ( ... );
```

### Rule of thumb for `numwords`:
`numwords = 2 ^ widthad` — always set it explicitly.

---

## 6. No Unpacked Arrays as Module Ports

Quartus 17.0 does not support unpacked arrays in module port connections.
The synthesizer generates phantom `<auto-generated>` signals and throws multi-driver errors.

**Wrong (fails Quartus 17.0):**
```verilog
output logic [7:0]  data_out [0:255],   // unpacked — FAILS
output logic        valid    [0:255],   // unpacked — FAILS
```

**Correct (packed multidimensional):**
```verilog
output logic [255:0][7:0]  data_out,    // packed — OK
output logic [255:0]       valid,       // packed — OK
```

Indexing syntax in the module body is unchanged — `data_out[i]` and `valid[i]` work the same for both forms.

**All callers** (instantiation sites) must also use packed declarations for the connecting wires:
```verilog
// Caller must declare:
logic [255:0][7:0]  data_out;
logic [255:0]       valid;
// Then connect:
.data_out (data_out),
.valid    (valid),
```

Affected modules found so far: `nmk16`, `gp9001`, `kaneko16`, `psikyo` (display_list ports).

---

## 7. No Inline Bit-Select on Function Return Values

Quartus 17.0 rejects bit-selects applied directly to function call results:

```verilog
// FAILS:
my_reg <= my_function(arg)[7:0];

// OK — rely on implicit truncation (if target is [7:0]):
my_reg <= my_function(arg);   // my_reg declared logic [7:0]

// Also OK — intermediate variable:
logic [9:0] tmp;
tmp = my_function(arg);
my_reg <= tmp[7:0];
```

---

## 8. No Inline `genvar` Declaration

Quartus 17.0 does not allow `genvar` declared inside a `for` loop header:

```verilog
// FAILS:
for (genvar k = 0; k < N; k++) begin ...

// Correct:
genvar k;
for (k = 0; k < N; k++) begin ...
```

---

## 9. 3D Arrays OOM quartus_map

Quartus 17.0 cannot infer BRAM from 3D arrays and runs out of memory trying to synthesize them as registers:

```verilog
// FAILS — OOMs quartus_map:
logic [7:0] fb [0:1][0:255][0:511];

// OK — guard with ifndef QUARTUS, stub in else:
`ifndef QUARTUS
    logic [7:0] fb [0:1][0:255][0:511];
    assign fb_dout = fb[page][y][x];
`else
    assign fb_dout = 8'b0;  // stub for synthesis
`endif
```

Note: Large 2D arrays also OOM if they are too big for register synthesis and not shaped for BRAM inference.
Use `altsyncram` (SINGLE_PORT or DUAL_PORT) for any RAM >4KB in the synthesis path.

---

## 10. Multi-Driver: All Writes to a Signal Must Be in ONE `always_ff` Block

Quartus 17.0 errors (10028 / 10029) if the same signal is written in two separate `always_ff` blocks, even at the same clock edge:

```verilog
// FAILS — two blocks write to sprite_ram:
always_ff @(posedge clk) begin
    if (cpu_wr) sprite_ram[cpu_addr] <= cpu_data;
end
always_ff @(posedge clk) begin
    if (dma_wr) sprite_ram[dma_addr] <= dma_data;
end

// Correct — one block with priority:
always_ff @(posedge clk) begin
    if (cpu_wr)       sprite_ram[cpu_addr] <= cpu_data;
    else if (dma_wr)  sprite_ram[dma_addr] <= dma_data;
end
```

Same rule applies to control registers like `ref_req` in SDRAM controllers — if a refresh counter block and the main FSM both write `ref_req`, merge into one block.

---

## 11. Out-of-Range Bit-Select on Unusual Address Bus Declarations

68000 CPU cores (fx68k) often declare the address bus as `[23:1]` (word-aligned, bit 0 absent).
If you write `cpu_addr[8:0]`, bit 0 is out of range → Quartus error 10232.

```verilog
// cpu_addr declared [23:1]:
// WRONG — bit 0 doesn't exist:
if (cpu_addr[8:0] < 9'h180)

// Correct — shift the window up by 1:
if (cpu_addr[9:1] < 9'h180)
```

---

## 12. GitHub Push Failures — Check Disk Space First

A full `/private/tmp` filesystem causes `git push` to fail with a 403 error that looks like a PAT auth failure. Before debugging tokens, check disk space:
```bash
df -h /private/tmp
```
Also: Fine-grained GitHub PATs can have `push: true` in the API response but still be read-only for certain repos if the repo permission wasn't explicitly granted. If auth looks right, try a classic PAT.

---

## 13. Non-Constant Variable Initializers (Error 10748)

Quartus 17.0 does NOT support initializing a `logic` variable with a non-constant expression at declaration:

```verilog
// FAILS — Quartus Error 10748:
logic _unused = &{lds_n, uds_n, 1'b0};
logic write_strobe = ~wr_n & ~cs_n;
logic vsync_rise = vsync_n_r & ~vsync_n;
```

**Fix: separate declaration from assignment:**
```verilog
// Correct:
logic _unused;
assign _unused = &{lds_n, uds_n, 1'b0};

logic write_strobe;
assign write_strobe = ~wr_n & ~cs_n;

logic vsync_rise;
assign vsync_rise = vsync_n_r & ~vsync_n;
```

This affects both lint-suppression dummies (`_unused`) and functional combinational signals.

---

## 14. `always_comb` Loop Driving Packed Output Array (Error 10028 / `<auto-generated>`)

Driving a packed output array from an `always_comb` for-loop causes Quartus to generate
phantom `<auto-generated>` signals and report a multi-driver error:

```verilog
// FAILS — generates <auto-generated> multi-driver error:
output logic [255:0][9:0] display_list_x,
logic [255:0][9:0] _dl_x;  // internal

always_comb begin
    for (int k = 0; k < 256; k++)
        display_list_x[k] = _dl_x[k];  // ← Quartus can't handle this
end
```

**Fix: replace the always_comb copy loop with a direct `assign`:**
```verilog
// Correct:
assign display_list_x = _dl_x;  // whole-array assign — Quartus handles this fine
```

This only works when the internal array `_dl_x` has the same packed type as the output.
Convert the internal array from unpacked to packed first if needed.

---

## 15. Reset Loop >5000 Iterations (Error 10106)

Quartus 17.0 refuses to synthesize reset initialization loops with more than 5000 iterations:
```
Error (10106): Design contains 8192 always constructs that are too complex to synthesize
```

```verilog
// FAILS — loop iterates 8192 times:
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < 8192; i++) sprite_ram[i] <= 16'h01FF;
    end else ...
end
```

**Fix: remove the reset initialization loop.** The CPU or game code initializes the RAM before
use; hardware reset of BRAM contents is unnecessary for synthesis correctness:
```verilog
// Correct: no reset loop (Cyclone V M10K power-up initializes to 0 anyway)
always_ff @(posedge clk) begin
    if (cpu_wr) sprite_ram[cpu_addr] <= cpu_data;
end
```

The 5000-iteration limit applies per-loop, not per-array. If you must initialize on reset,
use a counter FSM instead of a for-loop.

---

## 16. CI Lint Gate: Verilator Flag Compatibility

The CI uses Verilator for strict lint. Flag support varies by Verilator version:

| Flag | Supported Since | Notes |
|------|----------------|-------|
| `-Wno-MODMISSING` | Verilator 4.038+ | Not available in Ubuntu apt Verilator |
| `-Wno-PINMISSING` | Older versions | Use this for CI compatibility |

If CI fails with `%Error: Unknown warning specified: -Wno-MODMISSING`, the CI Verilator
is too old. Change the synthesis.yml flag to `-Wno-PINMISSING`.

**IMPORTANT:** Pushing `.github/workflows/` changes requires a PAT with `workflow` scope.
Fine-grained PATs with only `contents: write` cannot push workflow files. Create a new
classic PAT with `workflow` scope or update the existing fine-grained PAT.

---

## Systematic Error Peeling

Each Quartus synthesis run reveals one layer of errors. Typical order for a new chip:

1. **QSF errors** — invalid assignments (TIMING_ANALYZER, wrong edition string)
2. **IP / file-not-found** — missing `sys/build_id.tcl`, PLL IP files
3. **OOM (quartus_map)** — 3D arrays or large unguarded arrays; fix by adding `QUARTUS=1` guards
4. **Multi-driver errors** — multiple `always_ff` blocks writing same signal
5. **Port errors** — unpacked arrays as ports, `HEIGHT` parameter on `arcade_video`, out-of-range bit-selects
6. **altsyncram parameter errors** — missing `numwords_a/b`, missing `address_reg_b`
7. **Inline expression errors** — `func()[n:m]`, inline `genvar`
8. **Timing / fitter errors** — only seen after map passes clean

Run synthesis after each commit to expose the next layer.
