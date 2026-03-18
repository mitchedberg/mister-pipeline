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

## Chip Status

| Chip | Standalone Harness | Last Standalone Synth | Notes |
|------|-------------------|-----------------------|-------|
| tc0630fdp | ✅ `chips/tc0630fdp/standalone_synth/` | Not yet run | |
| tc0480scp | ✅ `chips/tc0480scp/standalone_synth/` | Not yet run | |
| tc0370mso | ✅ `chips/tc0370mso/standalone_synth/` | Not yet run | |
| tc0150rod | ✅ `chips/tc0150rod/standalone_synth/` | Not yet run | |
| tc0180vcu | ✅ `chips/tc0180vcu/standalone_synth/` | Not yet run | |
| tc0650fda | ✅ `chips/tc0650fda/standalone_synth/` | Not yet run | |
| nmk_arcade | ✅ `chips/nmk_arcade/standalone_synth/` | Not yet run | Full system FITS, SDC multicycle added |
| psikyo_arcade | ✅ `chips/psikyo_arcade/standalone_synth/` | Not yet run | Full system FITS, SDC multicycle added |
| kaneko_arcade | ✅ `chips/kaneko_arcade/standalone_synth/` | Not yet run | |
| toaplan_v2 | ✅ `chips/toaplan_v2/standalone_synth/` | Not yet run | GP9001 VRAM deferred (32K MLAB→M10K) |
| taito_b | ✅ `chips/taito_b/standalone_synth/` | Not yet run | Full system: ~165% ALM est. |
| taito_f3 | ✅ `chips/taito_f3/standalone_synth/` | Not yet run | Full system: 128K/83K nodes |
| taito_z | ✅ `chips/taito_z/standalone_synth/` | Not yet run | Full system: 386% ALM overflow |
| taito_x | ✅ `chips/taito_x/standalone_synth/` | Not yet run | |

---

## Open Architecture Issues

### Taito Z — CPU ALM overflow
2× fx68k before any GPU logic. TG68K is NOT a resource-saver (15-20% larger than fx68k) and is NOT a drop-in replacement (completely different adapter interface). Options:
1. Profile real ALM cost via standalone synthesis of fx68k_adapter alone first
2. Accept Taito Z needs HDMI + audio disabled (jotego pattern for tight designs)
3. Defer — Taito Z is architecturally the most complex system in the pipeline

### GP9001 VRAM — MLAB capacity
32K×16 MLAB needs 819 MLABs vs 397 available. Requires pre-fetch pipeline restructure to M10K synchronous reads. Documented in `COMMUNITY_SYNTHESIS_GUIDE.md` Appendix C. Deferred until other chips are clean.

### Taito F3 — ALM overflow
128K logic nodes vs 83K device capacity. 53% over budget even with all M10K fixes. Root cause: TC0630FDP is extremely complex. Options: stub non-critical layers, defer.

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
