# Section 4 — RTL Anti-Pattern List

The following patterns are **forbidden** in all MiSTer pipeline RTL.
Gate 2.5 (lint) and Gate 3a (Yosys) enforce these automatically.
Never hand-patch generated RTL to work around a gate failure — fix the prompt.

---

## Anti-Pattern 1: Latch Inference via Incomplete Case

**Forbidden:**
```systemverilog
always_comb begin
    case (sel)
        2'b00: out = 8'hAA;
        2'b01: out = 8'hBB;
        // missing 2'b10, 2'b11 → infers latch
    endcase
end
```

**Required:** Every `case` in `always_comb` must have a `default` branch.

```systemverilog
always_comb begin
    case (sel)
        2'b00: out = 8'hAA;
        2'b01: out = 8'hBB;
        default: out = 8'h00;   // explicit default, no latch
    endcase
end
```

---

## Anti-Pattern 2: Async Reset Deassertion Without Synchronizer

**Forbidden:**
```systemverilog
// Async deassert — metastability risk at reset release
always_ff @(posedge clk or posedge rst) begin
    if (rst) count <= 0;
    else     count <= count + 1;
end
```

**Required:** Use the two-flop synchronizer from `section5_reset.sv`.
Async ASSERT is safe. Async DEASSERT is the hazard.

---

## Anti-Pattern 3: Multi-Driver Signal

**Forbidden:**
```systemverilog
always_ff @(posedge clk) if (a) out <= 1'b1;
always_ff @(posedge clk) if (b) out <= 1'b0;  // ERROR: two drivers
```

**Required:** One always block per signal, with full priority encoding.

---

## Anti-Pattern 4: Logic-Gated Clock

**Forbidden:**
```systemverilog
wire gated_clk = clk & enable;   // creates clock glitches
always_ff @(posedge gated_clk) ...
```

**Required:** Use synchronous enable on data path. Never gate the clock signal.

```systemverilog
always_ff @(posedge clk) begin
    if (enable) q <= d;   // synchronous enable
end
```

---

## Anti-Pattern 5: `reg` or `wire` Declarations

**Forbidden:**
```systemverilog
reg  [7:0] count;    // legacy Verilog
wire [7:0] bus;      // legacy Verilog
```

**Required:** Use `logic` for all signals.

```systemverilog
logic [7:0] count;
logic [7:0] bus;
```

---

## Anti-Pattern 6: Missing `default_nettype none

**Forbidden:** Any `.sv` file that does not begin with:
```systemverilog
`default_nettype none
```

Without this, implicit `wire` declarations hide typos and cause silent multi-driver bugs.

---

## Anti-Pattern 7: Combinational Feedback Loop

**Forbidden:**
```systemverilog
always_comb begin
    a = b & c;
    b = a | d;   // 'a' feeds back into 'b' — combinational loop
end
```

**Required:** Break all combinational loops with registered stages.

---

## Anti-Pattern 8: Unregistered Output to Top-Level Port

**Forbidden:**
```systemverilog
assign pixel_out = ram_data ^ lut_data;  // combinational output — timing path
```

**Required:** Register all top-level outputs. Combinational outputs on timing-critical paths cause Fmax degradation.

```systemverilog
always_ff @(posedge clk) pixel_out <= ram_data ^ lut_data;
```

---

## Anti-Pattern 9: CDC Without Synchronizer

**Forbidden:**
```systemverilog
// Signal crosses from CPU clock domain to pixel clock domain with no sync
assign pixel_clk_signal = cpu_clk_signal;
```

**Required:** Any cross-domain signal must go through a two-flop synchronizer (for single-bit) or a handshake / gray-coded FIFO (for multi-bit). Mark all CDCs with a `// CDC:` comment.

```systemverilog
// CDC: cpu_clk → pixel_clk, single-bit flag
logic [1:0] flag_sync;
always_ff @(posedge pixel_clk or negedge rst_n)
    if (!rst_n) flag_sync <= 2'b00;
    else        flag_sync <= {flag_sync[0], cpu_flag};
```

---

## Anti-Pattern 10: Blocking Assignment in always_ff

**Forbidden:**
```systemverilog
always_ff @(posedge clk) begin
    a = b + 1;   // blocking assignment in sequential block
    c = a & d;   // order-dependent — synthesis may not match simulation
end
```

**Required:** Use non-blocking assignments (`<=`) exclusively in `always_ff`.

```systemverilog
always_ff @(posedge clk) begin
    a <= b + 1;
    c <= a & d;   // 'a' is the OLD value — well-defined behavior
end
```

---

*Gate 2.5 checks: Anti-Patterns 1, 2, 5, 6*
*Gate 3a checks: Anti-Patterns 1, 3, 7*
*Manual review required: Anti-Patterns 4, 8, 9, 10*
