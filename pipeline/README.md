# MiSTer FPGA Arcade Pipeline — Repository Strategy & Release Infrastructure

## Overview

This directory contains the complete strategy and automation for managing the private development-to-public-release pipeline for MiSTer FPGA arcade cores. It documents the two-tier repository structure, release criteria, community engagement guidelines, and attribution policies.

---

## Core Documents (Read in This Order)

### 1. **REPO_STRATEGY.md** (13 KB, 356 lines)
   - **Audience**: Project leads, contributors
   - **Purpose**: Complete two-tier repository strategy
   - **Contents**:
     - Tier 1 (Private): `MiSTer_Pipeline` — development, gates, research, all artifacts
     - Tier 2 (Public): `Arcade-SystemName_MiSTer` — release-only, GPL-2.0, community
     - Repository structure, git configuration, release criteria checklist
     - Relationship to MiSTer-devel and future expansion

### 2. **PUBLIC_RELEASE_PLAN.md** (15 KB, 460 lines)
   - **Audience**: Project leads, community managers
   - **Purpose**: Phased release timeline and announcement strategy
   - **Contents**:
     - Phase 1: Private development (Jan–Mar 2026, complete)
     - Phase 2: Hardware validation (Mar–Apr 2026, in progress)
     - Phase 3: Beta release (Apr–Jun 2026, upcoming)
     - Phase 4: Stable v1.0 (Jun 2026+, scheduled)
     - Announcement language (what to say, what NOT to say)
     - Quality gates, success metrics, risk mitigation

### 3. **ATTRIBUTION_POLICY.md** (19 KB, 583 lines)
   - **Audience**: All contributors, compliance leads
   - **Purpose**: Attribution, licensing, community coordination
   - **Contents**:
     - GPL-2.0 licensing framework (when/why it applies)
     - Attribution categories (MAME, decap data, existing FPGA work)
     - Community coordination ("surfing etiquette" with Jotego)
     - Special cases (proprietary IP, code porting, bug contributions)
     - Handling attribution corrections, licensing edge cases
     - CREDITS.md template

---

## Automation Scripts

### **prepare_release.sh** (437 lines, executable)

Creates/updates public release repositories from private development code.

**Usage**:
```bash
./scripts/prepare_release.sh taito_f3 "Taito F3"
./scripts/prepare_release.sh psikyo "Psikyo"
```

**What It Does**:
1. Creates `../Arcade-{Name}_MiSTer/` directory
2. Copies release artifacts only:
   - `rtl/*.sv` → `rtl/`
   - `quartus/*.qsf|.sdc|.qip|.rbf` → `quartus/`
   - `mra/*.mra` → `mra/`
3. Creates LICENSE (GPL-2.0), CREDITS.md template, README.md template
4. Initializes git repository with initial commit
5. Prints instructions for GitHub setup and tagging

**Output**: Fully structured, git-initialized public release repo ready for GitHub push.

### **validate_release_checklist.sh** (343 lines, executable)

Verifies all release conditions before public release.

**Usage**:
```bash
./scripts/validate_release_checklist.sh taito_f3
./scripts/validate_release_checklist.sh taito_f3 verbose  # Runs tests
```

**What It Checks**:
- ✅ RTL files present (*.sv in rtl/)
- ✅ Quartus project complete (.qsf, .sdc, .qip)
- ✅ RBF bitstream generated
- ✅ LICENSE file (GPL-2.0)
- ✅ CREDITS.md filled out
- ✅ README.md with game list
- ✅ At least 5 MRA files
- ✅ Test suite passes (if `verbose` flag)

**Output**: Colored PASS/FAIL/WARN per check, summary, next steps recommendations.

---

## Directory Structure

```
MiSTer_Pipeline/
├── pipeline/                         # This directory
│   ├── README.md                     # This file
│   ├── REPO_STRATEGY.md              # Two-tier strategy
│   ├── PUBLIC_RELEASE_PLAN.md        # Release timeline
│   ├── ATTRIBUTION_POLICY.md         # Attribution & licensing
│   └── scripts/
│       ├── prepare_release.sh        # Create public release repos
│       └── validate_release_checklist.sh  # Verify readiness
├── chips/                            # All custom chip RTL
│   ├── taito_f3/                     # Per-system subdirectory
│   │   ├── rtl/                      # RTL source files (.sv)
│   │   ├── quartus/                  # Quartus IDE projects
│   │   ├── mra/                      # ROM auto-launcher files
│   │   ├── vectors/                  # Test vectors, Makefile
│   │   ├── README.md                 # Chip documentation
│   │   └── integration_plan.md       # Development notes
│   ├── taito_b/
│   ├── taito_x/
│   ├── taito_z/
│   └── [future systems]
├── research/                         # Hardware research artifacts
├── gates/                            # Quality gate scripts
├── templates/                        # Code generation templates
├── CLAUDE.md                         # Development rules
├── ARCADE_TARGETS_RANKED.md          # Strategic roadmap
├── LICENSE                           # GPL-2.0 (private repo)
└── .github/workflows/                # CI/CD automation
```

---

## Workflow: From Development to Public Release

### Step 1: Development (Private Repo)

Develop RTL, test vectors, MRA files in `MiSTer_Pipeline/chips/[system]/`.

Run gates: `gates/run_gates.sh chips/[system]/[system].sv chips/[system]/vectors`

Iterate until all gates pass (behavioral sim, lint, structural synthesis, functional regression).

### Step 2: Hardware Validation (Closed Beta)

1. Synthesize in Quartus → generates `.rbf` bitstream
2. Boot on real DE-10 Nano, test at least 5 games
3. Validate against TAS data (frame-perfect if available)
4. Fix any issues, document known limitations
5. Share with closed beta testers (trusted community members)

### Step 3: Pre-Release Quality Check

Before creating public repo:

```bash
./pipeline/scripts/validate_release_checklist.sh taito_f3 verbose
```

Verify all checks pass. If warnings, address them before proceeding.

### Step 4: Create Public Release Repository

```bash
./pipeline/scripts/prepare_release.sh taito_f3 "Taito F3"
```

This creates `../Arcade-TaitoF3_MiSTer/` with:
- Clean rtl/, quartus/, mra/ subdirectories
- LICENSE, CREDITS.md, README.md templates
- .gitignore and initial git commit

### Step 5: Finalize & Publish

1. **Fill out templates**:
   - Edit `CREDITS.md`: Add actual contributor names, decap sources
   - Edit `README.md`: Add supported game list, known issues

2. **Create GitHub repository**:
   ```bash
   cd ../Arcade-TaitoF3_MiSTer
   git remote add origin git@github.com:MiSTer-devel/Arcade-TaitoF3_MiSTer.git
   git branch -M main
   git push -u origin main
   ```

3. **Create release tag**:
   ```bash
   git tag v0.1.0-beta -m "Initial beta release"
   git push origin v0.1.0-beta
   ```

4. **Announce** (MiSTer forum, GitHub Releases, with clear "BETA/TESTING" label)

### Step 6: Ongoing Support

- Respond to GitHub Issues (bug reports, MRA requests)
- Merge community contributions (with proper attribution)
- Release patches (v0.2.0, v0.3.0) for critical fixes
- Promote to v1.0 stable when ready (typically 2–3 months)

---

## Key Decision Points

### Who Decides Release Readiness?

**Tier 1 → 2 Decision**: Project lead + one reviewer minimum
- Review: REPO_STRATEGY.md compliance
- Verify: `validate_release_checklist.sh` all-pass
- Ensure: CREDITS.md properly filled out, no attribution missing

### What's The Minimum Game Coverage?

**Beta (v0.x)**: At least 5 games with MRA files
**Stable (v1.0)**: At least 10 games fully validated, no critical bugs

### Can We Fork/Extend Existing FPGA Work?

**Yes**, if:
- ✅ Original work is GPL-compatible (GPL-2.0, MIT, Apache-2.0, etc.)
- ✅ You cite original author clearly in README + CREDITS.md
- ✅ You preserve git history showing original author
- ✅ Your derivative remains GPL-2.0

Example: Toaplan V2 extending va7deo's V1 core.

### What If Jotego Has Announced The Same System?

**Don't start**. Check:
- jtcores GitHub README (122 cores listed)
- Jotego's MiSTer forum posts
- His GitHub issues/roadmap

If conflict: Email Jotego with 3-sentence coordination note. Respect his leadership.

---

## System Release Status (as of 2026-03-17)

| System | Phase | Status | Est. Release |
|--------|-------|--------|--------------|
| **Taito F3** | 2 | Hardware validating | Apr 15, 2026 |
| **Taito B** | 2 | Hardware validating | Apr 15, 2026 |
| **Taito X** | 2 | Hardware validating | Apr 15, 2026 |
| **Taito Z** | 2 | Hardware validating | Apr 15, 2026 |
| **GP9001** | 1 | Development (90%) | Jun 2026 |
| **Toaplan V2** | 0 | Planned | Jun–Jul 2026 |
| **NMK16** | 0 | Planned | Jul–Sep 2026 |
| **Psikyo** | 0 | Planned | Oct–Dec 2026 |

See ARCADE_TARGETS_RANKED.md for detailed roadmap.

---

## Common Tasks

### I'm Adding a New Game MRA File

1. Test ROM set boots in DE-10 Nano
2. Generate MRA using `mra_generator.js` or manually edit existing
3. Verify MRA points to correct ROM files
4. Add to `chips/[system]/mra/`
5. Commit: "Add MRA for [game name]"
6. Next public release will include in release repo

### I Found A Bug in Released Code

1. Reproduce in private `MiSTer_Pipeline` repo
2. Fix RTL or test vector
3. Re-run gates: `gates/run_gates.sh ...`
4. Verify fix resolves issue (resynthesize if needed)
5. Commit to private repo
6. Decide: Release patch (v0.2.0) or defer to v1.0?
7. If patch: Re-run `validate_release_checklist.sh`, re-sync to public repo

### I Want To Contribute (External)

1. Fork public release repo (e.g., `Arcade-TaitoF3_MiSTer`)
2. Create feature branch: `git checkout -b feature/your-idea`
3. Test thoroughly
4. Submit pull request with description
5. Maintainer reviews, merges with proper attribution

**Note**: Private `MiSTer_Pipeline` is not open for external contributions (internal development only). All public contributions go through public release repos.

### I Want To Request Attribution

1. Check CREDITS.md in public release repo
2. If missing: Open GitHub Issue with:
   - Your contribution (measurement, decap, etc.)
   - How to attribute you (name, email, website, anonymous?)
   - Link to original work if available
3. Maintainer updates CREDITS.md, merges in next patch release

---

## Files Created Summary

| File | Size | Purpose |
|------|------|---------|
| `REPO_STRATEGY.md` | 13 KB | Two-tier strategy, git config, release criteria |
| `PUBLIC_RELEASE_PLAN.md` | 15 KB | Timeline, announcements, phased release |
| `ATTRIBUTION_POLICY.md` | 19 KB | GPL-2.0, decap credits, community coordination |
| `prepare_release.sh` | 13 KB | Automation: create public release repos |
| `validate_release_checklist.sh` | 12 KB | Automation: verify release readiness |
| **Total** | **72 KB** | Complete release infrastructure |

---

## Next Steps

1. **Review** REPO_STRATEGY.md and PUBLIC_RELEASE_PLAN.md with team
2. **Assign** release manager (responsible for scripts, announcements)
3. **Test** scripts on a non-critical system first (e.g., Taito Z)
4. **Schedule** hardware validation for Taito systems (Phase 2)
5. **Plan** Phase 3 announcements (April 15 target)

---

## References

- **REPO_STRATEGY.md** — Complete strategy (read first)
- **PUBLIC_RELEASE_PLAN.md** — Announcement timeline and community engagement
- **ATTRIBUTION_POLICY.md** — Licensing, attribution, and coordination rules
- **CLAUDE.md** — Development rules and gate pipeline
- **ARCADE_TARGETS_RANKED.md** — Strategic roadmap for next systems
- **MiSTer Documentation** — https://github.com/MiSTer-devel/Main_MiSTer
- **MAME Project** — https://www.mamedev.org/

---

**Last Updated**: 2026-03-17
**Status**: Ready for Phase 2 (Hardware Validation)
**Release Manager**: [Assign]
