# MiSTer Pipeline — Release Checklist

A core must satisfy every item on this list before advancing to `published` state.
The `prepare_release` agent evaluates these automatically, but a human must review
the agent's report before running `--publish`.

Items marked **HARD BLOCKER** will cause the `prepare_release` agent to refuse to
advance state. Items marked **SOFT** are documented but do not block publication.

---

## 1. Correctness

- [ ] **HARD** All gate tests pass: `make test` exits 0 in `chips/<chip>/vectors/`
  - gate1: CPU interface register read/write round-trip
  - gate2.5: Verilator lint, zero warnings with `-Wall`
  - gate3a: Yosys structural synthesis passes without errors
  - gate4: Functional regression against MAME behavioral reference vectors
  - gate5 (if applicable): Full composite frame matches MAME output

- [ ] **HARD** No known game-breaking divergence from MAME behavior
  - Pixel-perfect accuracy is ideal but not required
  - Gameplay-breaking bugs (wrong sprite position, missing inputs, corrupted palettes) block release
  - Cosmetic differences (1-2 pixel sprite boundary, minor timing jitter) are acceptable with documentation

---

## 2. Synthesis

- [ ] **HARD** Synthesis completes without errors on Cyclone V (DE-10 Nano)
  - GitHub Actions workflow passes
  - `output_files/<chip>.rbf` is generated

- [ ] **SOFT** Synthesis completes without warnings (document all warnings)
  - Timing warnings: acceptable if they are in uncritical paths (async SDRAM, HPS bus)
  - Logic utilization < 80% of Cyclone V resources (110K LUTs, 4600KB BRAM)
  - If utilization > 80%, note it — MiSTer system overhead may push it over

---

## 3. Hardware Validation

- [ ] **HARD** At least one representative game boots to gameplay on real DE-10 Nano hardware
  - Verified by: `chips/<chip>/HARDWARE_VALIDATED` file in repo (committed)
  - The file should contain a brief note: who tested, which game, which DE-10 board revision

- [ ] **SOFT** Multiple games tested (at least 2 of the listed representative games)

- [ ] **SOFT** Audio confirmed working on hardware

- [ ] **SOFT** ROM loading confirmed working for all listed games

---

## 4. Legal / Attribution

- [ ] **HARD** `LICENSE` file present at `chips/<chip>/LICENSE` (or integration dir)
  - Must be GPL-2.0 full text (not a URL, not a summary — the actual license text)

- [ ] **HARD** `CREDITS.md` lists all dependencies with links and license identifiers
  - Any RTL copied or adapted from another source: listed with URL + license
  - Any research from community disassemblies: listed with author + URL
  - Any jotego sound IP: listed with repo link
  - MAME contributors whose behavioral research was used: acknowledged

- [ ] **HARD** No borrowed RTL without attribution
  - Do not copy RTL from closed-source or non-GPL-compatible projects
  - Fork and adapt GPL-2.0 code is allowed; must be noted in CREDITS.md
  - jotego cores: GPL-2.0 compatible, attribution required

- [ ] **SOFT** `CREDITS.md` formatted consistently with other cores in this pipeline

---

## 5. MRA Files

- [ ] **HARD** MRA files present for all representative games in `chips/<chip>/mra/` or `integration_dir/mra/`

- [ ] **HARD** Each MRA `<rom>` entry `name` attribute matches the MAME ROM set filename
  - Verify against `mame/hash/<driver>.xml`
  - Wrong filenames = core silently fails to load on production MiSTer systems

- [ ] **SOFT** MRA files include correct `rbf` attribute pointing to the core name

- [ ] **SOFT** DIP switch settings documented in MRA comments for games that use them

---

## 6. Documentation

- [ ] **SOFT** `README.md` present with:
  - Supported games list
  - Hardware notes (original PCB description)
  - Build instructions
  - Known issues / limitations section
  - Credits reference

- [ ] **SOFT** Known divergences from original hardware documented in README

- [ ] **SOFT** Any unimplemented features (e.g., rowscroll, zoom effects) noted

---

## 7. Repository Health

- [ ] **SOFT** No generated files committed that can be regenerated (no `obj_dir/`, no `*.o`)
- [ ] **SOFT** `.gitignore` excludes Verilator build artifacts and Quartus output files
- [ ] **SOFT** All source files have a header comment: chip name, author, date, license SPDX

---

## Sign-off Procedure

When all HARD items are PASS and SOFT items are reviewed:

```bash
# 1. Create release marker
touch chips/<chip>/RELEASE
echo "v1.0.0 — released $(date -I) — all gates pass, hardware validated" > chips/<chip>/RELEASE

# 2. Commit
git add chips/<chip>/RELEASE chips/<chip>/README.md chips/<chip>/CREDITS.md chips/<chip>/LICENSE
git commit -m "Release <chip> v1.0.0"

# 3. Tag
git tag -a v1.0.0 -m "<chip> initial public release"

# 4. Mark in orchestrator
node pipeline/orchestrator/orchestrator.js --publish <chip>
```

The `--publish` flag runs the `prepare_release` agent, which does a final check
and writes a release summary. Only then does state advance to `published`.

---

## Rollback

If a post-release hardware defect is discovered:
1. Delete `chips/<chip>/RELEASE`
2. Re-run orchestrator — it will detect state rollback to `validated`
3. Fix the issue, re-test, re-synthesize as needed
4. Re-run `--publish` to create a new release (v1.0.1, etc.)
