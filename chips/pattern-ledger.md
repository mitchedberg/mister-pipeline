# MiSTer FPGA Synthesis Pattern Ledger

**Source**: Diff of `my_jts16_scr.sv` (from-scratch, MAME reference only) vs.
`jotego/jtcores/cores/s16/hdl/jts16_scr.v` (10+ years synthesis-validated).
**Date**: 2026-03-18
**Purpose**: Enumerate the delta between naive-but-correct RTL and synthesis-clean RTL.
Fold each item into `check_rtl.sh` where automatable.

---

## PATTERN 1 — Asynchronous Reset

**Naive (mine):**
```systemverilog
always @(posedge clk) begin
    if (rst) begin ...
```

**jotego:**
```verilog
always @(posedge clk, posedge rst) begin
    if( rst ) begin ...
```

**Why it matters:** Synchronous reset in FPGA creates a reset-enable mux on every LUT output,
consuming an extra LUT layer and degrading timing. Asynchronous reset uses the dedicated CLR
pin on every flip-flop — no logic overhead, better Fmax.
Quartus 17.0 infers synchronous reset as logic, not dedicated clear. Use `posedge rst` in the
sensitivity list.

**check_rtl.sh rule:** Warn when `always @(posedge clk)` with `if (rst)` body found but `rst` is
NOT in the sensitivity list. (Check 9 — to add.)

---

## PATTERN 2 — Two Clock Enables (pxl_cen + pxl2_cen)

**Naive (mine):** Single `pxl_cen` gating everything.

**jotego:**
```verilog
// Linebuf writes and pixel shift use pxl2_cen (2× pixel rate)
pxl_data[23:16] <= pxl_data[23:16]<<1;  // on pxl2_cen && scr_good
we <= busy[7] & pxl2_cen;               // linebuf write enable
// Map state machine uses pxl_cen implicitly (runs once per pixel)
```

**Why it matters:** SDRAM bandwidth is finite. Running the pixel shift register at 2× pixel rate
allows each SDRAM word (4 pixels) to be consumed smoothly over 8 pxl2_cen ticks. Using only
pxl_cen would require consuming 4 pixels instantly, stressing SDRAM arbitration.
Comment in jts16_scr.v: *"This could work without pxl2_cen, but it stresses the SDRAM too much,
causing glitches in the char layer."*

**check_rtl.sh rule:** Not automatable — architectural review only. Add to GUARDRAILS.md.

---

## PATTERN 3 — Shift Register Pixel Queue (NOT case statement)

**Naive (mine):**
```systemverilog
case (latch_px_x)
    3'd0: raw_pixel <= scr_data[31:28];
    3'd1: raw_pixel <= scr_data[27:24];
    // ...
endcase
```

**jotego:**
```verilog
reg [23:0] pxl_data;  // 3 bytes = 3 bitplanes, 8 pixels each
// Load: pxl_data <= scr_data[23:0]  (one 32-bit word from SDRAM)
// Shift each clock: pxl_data[23:16] <<= 1; etc.
// Extract: bit [23], [15], [7] = current pixel's 3 bitplanes
assign buf_data = { attr, pxl_data[23], pxl_data[15], pxl_data[7] };
```

**Why it matters:**
- Case on pixel-X creates a 3-bit barrel shifter inference → 3 mux layers, ~1-2 LUT layers deep
- Shift register approach: single-bit MSB extraction = zero LUT depth, pure flip-flop propagation
- Shift registers map directly to FPGA routing fabric; barrel shifters create timing pressure
- Jotego's 4bpp encoding in 3 bitplane bytes (not nibbles) enables the shift-register trick

**check_rtl.sh rule:** Not automatable. Document as preferred pattern in GUARDRAILS.md.

---

## PATTERN 4 — Tile Coordinate Overflow Tracking (4-Quadrant Page Wrapping)

**Naive (mine):**
```systemverilog
wire [9:0] sx = hdump[8:0] + eff_hscr;  // truncated — WRONG for page select
wire [8:0] sy = vrender[8:0] + eff_vscr[8:0];
```

**jotego:**
```verilog
{hov, hpos} = {1'b1, hscan} - eff_hscr[9:0] - hscr_adj + eff_hdly[9:0];  // 10-bit with overflow
{vov, vpos} = vscan + eff_vscr[8:0];  // 9-bit with overflow

case( {vov, hov} )
    2'b10: page = pages[15:12];   // upper-left quadrant
    2'b11: page = pages[11: 8];   // upper-right quadrant
    2'b00: page = pages[ 7: 4];   // lower-left quadrant
    2'b01: page = pages[ 3: 0];   // lower-right quadrant
endcase
```

**Why it matters:** System 16 has 16 tilemap pages. The active page depends on which 256×256 quadrant
the scroll-adjusted coordinate falls in. Truncating to 9 bits loses the overflow bits needed for page
selection. Without proper overflow, the page is always wrong when scroll wraps around the 512-pixel
boundary.

**check_rtl.sh rule:** Not automatable. Document overflow requirement in GUARDRAILS.md.

---

## PATTERN 5 — SDRAM Stall State Machine (Not Simple ok Gating)

**Naive (mine):**
```systemverilog
always @(posedge clk) begin
    if (pxl_cen && map_ok) begin
        tile_index <= map_data[12:0];
        // ...
    end
end
```

**jotego:**
```verilog
always @(posedge clk, posedge rst) begin
    map_st <= map_st + 1'd1;  // auto-advance
    case( map_st )
        1: if( colscr_en && busy!=0 ) map_st <= 1;  // stall on column scroll
           else map_addr <= { page, scan_addr };
        3: if( !map_ok || busy!=0 || !scr_ok )
               map_st <= 3;              // stall until SDRAM ready
           else draw <= 1;
    endcase
end
```

**Why it matters:** Simple `if (map_ok)` assumes data arrives in a fixed latency. Real SDRAM
arbitration can delay responses (another channel is active, refresh cycle, etc.). Jotego's stall
pattern (`map_st <= same_state`) allows the pipeline to wait without corrupting tile fetch. Without
this, a slow SDRAM response skips a tile entirely, causing rendering glitches.

**check_rtl.sh rule:** Not automatable. Note: any pixel pipeline that doesn't have stall logic on
SDRAM fetch is architecturally suspect. Document in GUARDRAILS.md.

---

## PATTERN 6 — Line Buffer (Display vs. Render Separation)

**Naive (mine):** Output pixel directly — no scanline buffering.

**jotego:**
```verilog
jtframe_linebuf #(.DW(11), .AW(9)) u_linebuf(
    .clk      ( clk      ),
    .wr_addr  ( hscan    ),    // write: render address (one scanline ahead)
    .wr_data  ( buf_data ),
    .we       ( busy[7] & pxl2_cen ),
    .rd_addr  ( hdly     ),    // read: display address (current scanline)
    .rd_data  ( pxl      )
);
```

**Why it matters:** Tilemap rendering requires 8+ SDRAM access cycles per tile (map fetch + gfx fetch).
This is more time than is available inline during the display of each pixel. Jotego renders one
scanline AHEAD into a line buffer, then reads back the previous scanline for display. Without this,
you cannot keep up with pixel clock at 6.25 MHz with SDRAM at ~50 MHz shared across all channels.

**Synthesis impact:** `jtframe_linebuf` is a 512×11-bit BRAM. It maps to M10K in Quartus with
asynchronous read port (MLAB-mode) or registered (M10K-mode depending on read timing). Jotego's
linebuf uses async read — check that `jtframe_linebuf` maps correctly in standalone synthesis.

**check_rtl.sh rule:** Not automatable. Mandatory architecture for any scroll layer > char layer.

---

## PATTERN 7 — always @(*) for Combinational Logic (NOT wire/assign in always)

**Naive (mine):**
```systemverilog
wire [9:0] eff_hscr = row_scroll_en ? rowscr_data[9:0] : hscr[9:0];
```

**jotego:**
```verilog
always @(*) begin
    eff_hscr = rowscr_en ? rowscr : hscr[9:0];
    if( MODEL==0 ) begin
        {hov, hpos} = ...
    end else begin
        {hov, hpos} = ...
    end
end
```

**Why it matters:** `always @(*)` ensures complete sensitivity list — Verilog tools infer it
automatically. For Model-conditional logic, `always @(*)` allows if/else to choose between two
computation paths cleanly. Wire assignments work too but `always @(*)` is more readable and less
prone to sensitivity list omission bugs. Latch inference risk: all outputs must be assigned on every
path — jotego ensures this via else branches.

**check_rtl.sh rule:** Not automatable. Style preference — both are synthesis-equivalent.

---

## PATTERN 8 — Packed Pixel Bus (Not Separate Output Ports)

**Naive (mine):**
```systemverilog
output reg  [3:0] pxl_color,
output reg  [6:0] pxl_pal,
output reg        pxl_prio,
output reg        pxl_valid
```

**jotego:**
```verilog
output [10:0] pxl  // { priority[1], palette[6:0], color[2:0] }
```

**Why it matters:** Packed pixel bus reduces port count in the priority/compositor module. All pixel
data travels together through the pipeline as a single vector — one output, one connection. Makes
`jtframe_prio` and `jtframe_linebuf` generic across all cores. Jotego uses 11-bit (not 12 or 16)
to match exact DE-10 Nano jtframe convention.

**check_rtl.sh rule:** Not automatable. Convention note: use 11-bit packed pixel bus matching
`{ prio, pal[6:0], col[2:0] }` for all scroll/char/obj pixel outputs feeding line buffers or prio.

---

## PATTERN 9 — Verilog NOT SystemVerilog (Quartus 17.0 Compatibility)

**Naive (mine):** `.sv` extension, `logic` type, `default_nettype none`, `always_comb`, `always_ff`.

**jotego:** `.v` extension, `reg`/`wire` only, no SystemVerilog keywords.

**Why it matters:** Quartus 17.0 has limited SystemVerilog support. Specifically:
- `always_comb` / `always_ff`: supported but generates confusing Warning 10230 in some cases
- `logic` type: supported but may interact poorly with `(* ramstyle *)` pragma inference
- `default_nettype none`: strongly recommended (catches missing declarations) — jotego uses it
  via `jtframe` wrapper convention, not per-file
- Safest: `.sv` is fine for Quartus 17.0; avoid `interface`, `struct`, `enum`, `unique case`

**check_rtl.sh rule:** Check 3 already catches 3D arrays. Add check for `interface`/`struct`/
`enum` keywords in RTL (Check 10 — to add).

---

## PATTERN 10 — bytemux() Function for Partial Register Writes

**Naive (mine):** Assumed full 16-bit writes to registers.

**jotego:**
```verilog
function [15:0] bytemux( input [15:0] old );
    bytemux = { dswn[1] ? old[15:8] : cpu_dout[15:8],
                dswn[0] ? old[7:0]  : cpu_dout[ 7:0] };
endfunction
// Usage:
scr1_pages <= bytemux( scr1_pages );
```

**Why it matters:** 68000 bus supports byte and word writes. `dswn[1:0]` are data strobe negated
(byte enables). If only one byte is written, the other half must be preserved. The `bytemux` pattern
handles this cleanly without an extra case statement at every register. This is architecturally
required for correct 68000 I/O — without it, byte writes corrupt the upper/lower half.

**check_rtl.sh rule:** Not automatable. Document as required for any 68000 I/O register bank.

---

## PATTERN 11 — generate for Model-Dependent Logic

**Naive (mine):** `if (MODEL == 1) begin ...` inside always block (correct but less clear).

**jotego:**
```verilog
generate
    if( MODEL==1 ) begin
        assign rowscr1_en = scr1_hpos[15];
        assign colscr1_en = scr1_vpos[15];
    end
endgenerate
```

**Why it matters:** Generate blocks are elaboration-time constructs — completely eliminated for the
non-matching MODEL. Inside an always block, `if (MODEL==0)` is also eliminated by synthesis but
the always block itself remains. For assigns that drive inout/output ports, generate is the only
way to conditionally create/remove the driver entirely. Prevents undriven output warnings.

**check_rtl.sh rule:** Not automatable. Generate is preferred over always-if for port-driving logic.

---

## Summary — What check_rtl.sh Should Add

| Check # | Pattern | Rule |
|---------|---------|------|
| 9 | Async reset | Warn: `always @(posedge clk)` with `if (rst/reset)` body but rst not in sensitivity list |
| 10 | SV keywords | Warn: `interface`, `struct`, `enum`, `unique case`, `priority case` in synthesized RTL |
| (existing) | byteena_b width | Already in Check 2 |
| (existing) | 3D arrays | Already in Check 3 |
| (existing) | Byte-slice RAM | Already in Check 1 |

## Summary — GUARDRAILS.md Additions

1. **Asynchronous reset**: Always `always @(posedge clk, posedge rst)` — not synchronous
2. **Two-rate CEN**: Pixel pipeline needs pxl_cen AND pxl2_cen for SDRAM stability
3. **Shift register pixels**: Preferred over case-on-column for 4bpp tile pixel extraction
4. **Overflow tracking**: 10-bit H, 9-bit V arithmetic with `{hov, hpos}` for page wrapping
5. **SDRAM stall states**: State machine with conditional rollback — not simple `if (ok)` gating
6. **Line buffer mandatory**: Every scroll layer needs scanline-ahead line buffer
7. **Packed pixel bus**: 11-bit `{prio, pal[6:0], col[2:0]}` for all pixel outputs
8. **68000 register banks**: Use bytemux() for byte-enable-correct register writes
9. **generate for port drivers**: Prefer generate over always-if for conditional port assigns
