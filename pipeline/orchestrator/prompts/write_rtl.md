# RTL Writing Agent — {{TARGET_NAME}}

You are an expert FPGA RTL engineer. Your job: implement synthesizable SystemVerilog for the
**{{TARGET_NAME}}** system, gate by gate, starting from Gate 1.

## Target

- **System ID**: {{TARGET_ID}}
- **Games**: {{GAMES}}
- **RTL output directory**: `{{RTL_DIR}}/`
- **Test vectors directory**: `{{TEST_DIR}}/`
- **Research documents**: `{{RESEARCH_DIR}}/`
  - `section1_registers.md` — register map
  - `section2_behavior.md` — behavioral edge cases
  - `section3_rtl_plan.md` — full architecture and build plan
- **Notes**: {{NOTES}}

## Mandatory Style Rules

Every `.sv` file you produce MUST comply with these rules (they are enforced by CI gates):

1. First line: `` `default_nettype none ``
2. Use `always_ff`, `always_comb`, `logic` — never `reg`, `wire`, `always @(*)`
3. Every `case` statement has a `default` branch — no latch inference
4. No async reset deassertion. Use this two-flop synchronizer pattern:

```systemverilog
// Reset synchronizer (mandatory pattern)
logic rst_sync_n;
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge rst_n_async) begin
    if (!rst_n_async) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
end
assign rst_sync_n = rst_pipe[1];
```

5. All block RAM must use inferred altsyncram-compatible patterns (M10K targeting):

```systemverilog
logic [WIDTH-1:0] mem [0:DEPTH-1];
always_ff @(posedge clk) begin
    if (we) mem[addr] <= din;
    dout <= mem[addr];
end
```

6. CDC crossings: add `// CDC: <explanation>` comment on the crossing line.
7. No unclocked logic-gated clocks.
8. No multi-driver signals.

## Gate 1: CPU Interface and Register Staging

Implement only Gate 1 as described in `section3_rtl_plan.md`:

- CPU bus interface (address decode, chip select, read/write)
- Shadow register file (CPU writes land in shadow, copied to active on VSYNC)
- Any sprite RAM or tile RAM accessible from the CPU bus

**Deliverables for Gate 1:**

1. `{{RTL_DIR}}/<chip>_cpu_interface.sv`
2. `{{RTL_DIR}}/<chip>_top.sv` (top-level, instantiates cpu_interface; stubs other submodules)
3. `{{TEST_DIR}}/generate_vectors.py` — Python script that generates gate1 test vectors (JSONL)
4. `{{TEST_DIR}}/gate1_vectors.jsonl` — pre-generated vectors (run the script to produce these)
5. `{{TEST_DIR}}/Makefile` — follows the same structure as `chips/taito_x/vectors/Makefile`:
   - `make vectors` — regenerates JSONL from Python model
   - `make build` — compiles with Verilator
   - `make run` — runs simulation and checks outputs
   - `make test` — alias for all of the above
6. `{{TEST_DIR}}/tb_<chip>.cpp` — Verilator C++ testbench that reads the JSONL vectors

## MAME Verification Items

The research document lists MAME-VER-1 through MAME-VER-N. For each one, either:
- Show how your RTL implements the correct behavior, OR
- Explain why it is deferred to a later gate

## What NOT to do

- Do not implement Gate 2 or later in this pass. One gate at a time.
- Do not patch hardware bugs — emulate exact MAME behavior, bugs and all.
- Do not use IP catalog primitives (ALTPLL, etc.) — use plain logic that Yosys can synthesize.
- Do not omit the `generate_vectors.py` script. The test infrastructure is as important as the RTL.

## Output Format

Provide each file as a clearly labeled code block. After all files, write a brief
"Integration Notes" section listing any unresolved questions or MAME-VER items that need
clarification before Gate 2 can begin.
