# MiSTer Pipeline — Master Generation Prompt Template

This is the master prompt template for AI-driven RTL generation of MiSTer FPGA arcade cores.
Sections 1 and 2 are filled per chip target. Sections 3–6 are constant boilerplate.

Copy this entire file into the AI prompt, filling in the FILL PER CHIP sections.

---

## SECTION 1 — Chip Target (FILL PER CHIP)

```
Target chip:       [CHIP NAME AND PART NUMBER]
Arcade system:     [ARCADE BOARD / GAME TITLE]
Chip function:     [e.g., "tile map generator", "sprite engine", "sound PSG"]
Clock frequency:   [e.g., "6 MHz pixel clock, 3 MHz CPU clock"]
Package / process: [e.g., "40-pin DIP, NMOS, ~1982"]
MAME source file:  [e.g., "src/devices/video/mc6845.cpp"]
MiSTer top module: [e.g., "Galaga_MiSTer/rtl/galaga.sv"]
```

Known signals (from schematic / MAME source / datasheet):
```
[List each pin: name, direction, width, function]
[Example:]
  - CLK (in, 1-bit): master pixel clock
  - /RES (in, 1-bit): active-low async reset
  - D[7:0] (in/out, 8-bit): CPU data bus
  - MA[13:0] (out, 14-bit): VRAM address output
  - RA[4:0] (out, 5-bit): row address within character
  - HSYNC (out, 1-bit): horizontal sync, active-low
  - VSYNC (out, 1-bit): vertical sync, active-low
  - DE (out, 1-bit): display enable
```

Timing parameters (from datasheet or MAME register writes):
```
[Fill in horizontal/vertical timing from CRTC registers or datasheet]
[Example:]
  - Horizontal total: 56 characters (448 pixels at 8px/char)
  - Horizontal displayed: 40 characters (320 pixels)
  - Horizontal sync position: 44
  - Horizontal sync width: 8
  - Vertical total: 32 lines (adjust field)
  - Vertical displayed: 25 lines
  - Vertical sync position: 28
  - Interlace: none
```

---

## SECTION 2 — Behavioral Spec (FILL PER CHIP)

```
[Write a precise behavioral description of what this chip does.]
[Reference the MAME source file — quote key logic blocks where helpful.]
[Include:]
  - Internal state machine states and transitions
  - Memory access patterns (when does it drive MA vs when is it in CPU mode)
  - All output signal timing relative to clock edges
  - Any documented quirks or undocumented behaviors known from MAME
  - How the chip interacts with adjacent chips (CPU, VRAM, palette, sprite engine)
]
```

---

## SECTION 3 — RTL Generation Rules

Generate a complete, synthesizable SystemVerilog module for the chip described in Sections 1 and 2.

**Mandatory style rules — gate 2.5 (lint) will hard-fail on violations:**

1. First line of the file MUST be: `` `default_nettype none ``
2. Use `always_ff`, `always_comb`, `logic` exclusively. Never `reg`, `wire`, `always @(*)`.
3. Every `case` statement in `always_comb` MUST have a `default` branch.
4. No logic-gated clocks. Use synchronous enable on the data path.
5. One always block per signal — no multi-driver signals.
6. All top-level outputs must be registered (no combinational output paths).
7. Use non-blocking assignments (`<=`) in `always_ff` exclusively.
8. Use blocking assignments (`=`) in `always_comb` exclusively.

**Pipeline structure:**
- Implement as a single flat module where possible. Avoid deep hierarchy for the first pass.
- If memory is needed, use the `ifdef VERILATOR behavioral stub pattern from Section 4b.
- The reset synchronizer from Section 5 MUST be instantiated inline or as a submodule.

**Deliverable format:**
Return ONLY the SystemVerilog code, no prose explanation. Start with `` `default_nettype none ``.

---

## SECTION 4 — Anti-Pattern List (DO NOT GENERATE THESE)

The following patterns will cause gate failures. Do not generate them.

### AP-1: Latch inference (case without default)
```systemverilog
// FORBIDDEN:
always_comb begin
    case (sel)
        2'b00: out = A;
        2'b01: out = B;
        // missing default → LATCH
    endcase
end
// REQUIRED: add default: out = '0; (or appropriate safe value)
```

### AP-2: Async reset deassertion without synchronizer
```systemverilog
// FORBIDDEN:
always_ff @(posedge clk or posedge rst) begin
    if (rst) out <= 0;
    else out <= next;   // async deassert — metastability hazard
end
// REQUIRED: use the Section 5 synchronizer; then use synchronous reset only
```

### AP-3: Multi-driver signal
```systemverilog
// FORBIDDEN:
always_ff @(posedge clk) if (a) out <= 1;
always_ff @(posedge clk) if (b) out <= 0;  // two drivers — synthesis error
// REQUIRED: one always_ff per signal, with full priority mux
```

### AP-4: Logic-gated clock
```systemverilog
// FORBIDDEN:
wire gated_clk = clk & en;             // glitch hazard
always_ff @(posedge gated_clk) ...
// REQUIRED: always_ff @(posedge clk) if (en) ...
```

### AP-5: reg/wire declarations
```systemverilog
// FORBIDDEN:
reg  [7:0] count;
wire [7:0] bus;
// REQUIRED:
logic [7:0] count;
logic [7:0] bus;
```

### AP-6: Missing `default_nettype none
```systemverilog
// FORBIDDEN: any file that does not start with `default_nettype none
// REQUIRED: `default_nettype none must be line 1
```

### AP-7: Combinational feedback loop
```systemverilog
// FORBIDDEN:
always_comb begin
    a = b & c;
    b = a | d;  // 'a' feeds back → combinational loop
end
// REQUIRED: break with registered stage
```

### AP-8: Unregistered combinational output on timing-critical port
```systemverilog
// FORBIDDEN (for pixel/sync outputs):
assign hsync = (hcount == H_SYNC_END);  // combinational glitch path
// REQUIRED:
always_ff @(posedge clk) hsync <= (hcount == H_SYNC_END);
```

### AP-9: CDC without synchronizer
```systemverilog
// FORBIDDEN:
assign pixel_clk_domain_signal = cpu_clk_domain_signal; // no sync
// REQUIRED: two-flop synchronizer, marked with // CDC: comment
```

### AP-10: Blocking assignment in always_ff
```systemverilog
// FORBIDDEN:
always_ff @(posedge clk) begin
    a = b + 1;   // blocking in sequential block — order-dependent
end
// REQUIRED:
always_ff @(posedge clk) begin
    a <= b + 1;  // non-blocking
end
```

---

## SECTION 4b — Memory Templates

For any internal VRAM, character ROM, sprite ROM, or palette RAM, use these patterns:

### Dual-Port VRAM (write: CPU domain, read: pixel domain)
```systemverilog
`ifdef VERILATOR
    // Behavioral stub (used by gate1 simulation)
    logic [DATA_W-1:0] vram [0:(1<<ADDR_W)-1];
    always_ff @(posedge cpu_clk) if (wr_en) vram[wr_addr] <= wr_data;
    always_ff @(posedge pix_clk) rd_data <= vram[rd_addr];
`else
    // Synthesis: altsyncram M10K
    // MANDATORY: outdata_reg_b("CLOCK1") for M10K inference
    altsyncram #(
        .operation_mode("DUAL_PORT"),
        .width_a(DATA_W), .widthad_a(ADDR_W),
        .width_b(DATA_W), .widthad_b(ADDR_W),
        .outdata_reg_b("CLOCK1"),    // DO NOT REMOVE — required for M10K
        .intended_device_family("Cyclone V"),
        ...
    ) vram_inst ( ... );
`endif
// CDC WARNING: cpu_clk and pix_clk are different domains — see section4b_memory.sv
```

### Single-Port ROM (from .mif or initialized at synthesis)
```systemverilog
`ifdef VERILATOR
    logic [DATA_W-1:0] rom [0:ROM_DEPTH-1];
    initial $readmemh("rom_file.hex", rom);
    always_ff @(posedge clk) rd_data <= rom[rd_addr];
`else
    altsyncram #(
        .operation_mode("ROM"),
        .width_a(DATA_W), .widthad_a(ADDR_W),
        .outdata_reg_a("CLOCK0"),
        .init_file("rom_file.mif"),
        .intended_device_family("Cyclone V"),
        ...
    ) rom_inst ( ... );
`endif
```

---

## SECTION 5 — Required Reset Pattern

Every module MUST include this reset synchronizer (either inline or as a submodule).
Do NOT use async reset deassertion anywhere except in this pattern.

```systemverilog
// Reset synchronizer: async assert, synchronous deassert
// ONLY acceptable use of async reset in sensitivity list
logic [1:0] rst_pipe;
always_ff @(posedge clk or negedge async_rst_n)
    if (!async_rst_n) rst_pipe <= 2'b00;
    else              rst_pipe <= {rst_pipe[0], 1'b1};
logic rst_n;
assign rst_n = rst_pipe[1];

// ALL subsequent always_ff blocks use rst_n (synchronous):
always_ff @(posedge clk) begin
    if (!rst_n) my_signal <= '0;
    else        my_signal <= next_value;
end
```

---

## SECTION 6 — Test Vector Requirements

After generating the RTL, also generate tier1 and tier2 test vectors in the JSON Lines format below.

**File:** `chips/<CHIPNAME>/vectors/tier1_reset.jsonl`
**File:** `chips/<CHIPNAME>/vectors/tier2_functional.jsonl`

### JSON Lines Schema (one object per clock cycle):
```json
{
  "t":       <int>,              // clock cycle from reset release (t=0)
  "comment": <string>,           // optional human-readable label
  "inputs":  { "<port>": <val> },  // DUT inputs this cycle (sticky)
  "outputs": { "<port>": <val> },  // expected DUT outputs this cycle
  "mask":    { "<port>": <val> },  // optional: bitmask for don't-care bits
  "flags":   { "reset": <bool>, "skip": <bool>, "stop": <bool> }
}
```

Value encoding: integer (decimal), `"0xHH"` (hex), or `"0bBBBB"` (binary).

**Tier 1 must cover:**
- Reset assertion (rst_n = 0) and deassertion
- First valid output after reset
- Counter/pointer reset to initial state

**Tier 2 must cover:**
- All documented operational states
- All state transitions from the Section 2 behavioral spec
- At least one full horizontal line / vertical frame cycle if applicable
- Edge cases: counter wraparound, simultaneous control signals

**Tier 3 (MAME-derived):**
- Generated separately from MAME run — do not include in this prompt response.
- Will be added to `chips/<CHIPNAME>/vectors/tier3_mame.jsonl` by the pipeline tool.
