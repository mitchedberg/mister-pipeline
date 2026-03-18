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

## Calibration Diff (schedule after check_rtl.sh)

Implement jts16 scroll chip from scratch (MAME source only), then diff against jotego's implementation. Produce `chips/pattern-ledger.md`. Fold ledger items into `check_rtl.sh`. Purpose: calibrate against 10 years of synthesis-validated RTL patterns.

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
