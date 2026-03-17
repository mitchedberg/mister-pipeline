# ES5506 — Ensoniq Wavetable Synthesizer (Taito F3 Audio)

## Status: RESEARCH COMPLETE — RTL NOT STARTED

**System:** Taito F3 (1992–1997)
**Chip:** Ensoniq ES5506 (32-voice stereo wavetable synthesizer)

---

## ES550x Family Differences

| Chip | Voices | Output | Notes |
|------|--------|--------|-------|
| ES5503 | 32 | Mono | Apple IIGS (1986). 8-bit samples only. |
| ES5505 | 32 | Stereo | Arcade/synth boards. 16-bit samples + u-law. |
| ES5506 | 32 | Stereo | ES5505 + enhanced 4-pole filters (K1/K2 per voice). Used in Taito F3. |

**Taito F3 uses ES5506** — not ES5503 or ES5505. The TC0630FDP research incorrectly noted ES5505; confirmed ES5506 from MAME `taito_f3.cpp` device configuration.

---

## What Taito F3 Uses

- 32 voices, all potentially active simultaneously
- Stereo output (separate L/R volume per voice)
- Sample ROM interface: 16-bit samples or 8-bit u-law compressed
- 4-pole digital filter per voice (2× lowpass or lowpass+highpass, K1/K2 coefficients)
- Per-voice IRQ on loop end
- Clocked at ~16 MHz → sample output rate ~31.25 KHz (16M / 512)
- CPU interface: 8-bit data bus, 8-bit address (mapped through TC0400YSC sound comms chip)

---

## Existing FPGA Implementations

**None found.** Exhaustive search of:
- MiSTer-devel GitHub org
- jotego/jtcores
- OpenCores
- GitHub search for `es5506`, `es5505`, `es5503` HDL

No Apple IIGS MiSTer core with ES5503 HDL exists either. This chip must be built from scratch.

---

## MAME Reference

`src/devices/sound/es5506.cpp` — shared `es550x_device` base class covering ES5503/5505/5506.
ES5506-specific subclass: `es5506_device`.

Key MAME structures:
- `es550x_voice`: per-voice state (accum, start, end, lvol, rvol, k1, k2, o1n1..o4n2 filter history, control)
- `compute_tables()`: builds u-law decode table + volume lookup table
- `apply_filters()`: 4-pole filter using K1/K2
- `interpolate()`: linear interpolation between adjacent samples

---

## Build Strategy

**Not blocking for video work.** TC0180VCU and TC0630FDP gate 4 validation tests operate on palette indices — audio is entirely separate. ES5506 only needed for a complete playable Taito B/F3 core.

**Recommended path:**
1. Build after TC0180VCU and TC0630FDP RTL are complete
2. Use MAME `es5506.cpp` as behavioral ground truth (same MAME-comparison methodology as video chips)
3. Stage A: 1-voice, no filter, linear samples → gate 1-3
4. Stage B: 32 voices + u-law decode → gate 4 audio comparison
5. Stage C: full 4-pole filter per voice

**Effort estimate:** Significant (~Tier 3). The DSP math (filter poles, u-law, interpolation) is well-documented in MAME but nontrivial to synthesize efficiently.
