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
| **DONE** | nmk_arcade | ✅ GREEN (run #23260684835, exit 0) | — |
| **DONE** | psikyo_arcade | ✅ GREEN (run #23260684856, exit 0) | — |
| **DONE** | taito_b | ✅ GREEN (run #23260684817, exit 0, RBF 3.0M) | SDC timing work (setup -59.685ns) |
| **DONE** | toaplan_v2 | ✅ GREEN (run #23260684816, exit 0, RBF 3.1M) | SDC timing work (setup -56.398ns); gp9001 MLAB warning (see below) |
| **DONE** | taito_x | ✅ GREEN (run #23260684796, exit 0, RBF 2.9M) | SDC timing work (setup -47.934ns) |
| **DONE** | kaneko_arcade | ✅ GREEN (run #23260684782, exit 0, RBF 3.4M) | SDC timing work (setup -42.461ns) |
| **FROZEN** | taito_f3 | ❌ 53% over budget (TC0630FDP) | Architecture decision |
| **FROZEN** | taito_z | ❌ 386% over budget (2× fx68k) | Architecture decision |

**Do not touch FROZEN chips.**

**6/8 chips GREEN with RBF bitstreams as of 2026-03-18. All non-frozen systems produce flashable cores.**
**Next priority: SDC timing closure for all 6 GREEN chips, then Taito Z standalone profiling.**

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
